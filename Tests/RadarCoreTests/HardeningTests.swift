import Foundation
import Testing
@testable import RadarCore

// Regression tests for the security review of 1 Nov 2026 (H1, H2, M1, M2).

private func hardeningConfig(_ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig {
        $0.push.enabled = true
        $0.push.topic = "de.example.app"
        $0.push.environments = [.sandbox, .production]
        edit(&$0)
    }
}

private let secret = String(repeating: "a", count: 40)
private let otherSecret = String(repeating: "b", count: 40)
private let token = String(repeating: "ab", count: 32)
private func newID() -> String { UUID().uuidString.lowercased() }
private func hash(_ value: String) -> String { Hashing.sha256Hex(Array(value.utf8)) }
private func json(_ object: [String: Any]) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
private let installBody = json(["token": token, "env": "sandbox", "locale": "de"])
private func subBody(_ extra: [String: Any] = [:]) -> [UInt8] {
    var o: [String: Any] = ["grid_version": 1, "cell_x": 10, "cell_y": 20, "threshold": 3, "lead_minutes": 20]
    o.merge(extra) { $1 }
    return json(o)
}
private func text(_ r: ApiResponse?) -> String { String(decoding: r?.body ?? [], as: UTF8.self) }

// MARK: M1 rate limiter

@Suite("Hardening: rate limiter")
struct RateLimiterHardeningTests {
    @Test func randomKeyFloodDoesNotLockOutNewKeys() {
        let limiter = RateLimiter(maxKeys: 100)
        for _ in 0..<5_000 { _ = limiter.allow("i:" + newID(), limit: 60, window: 60, now: run0) }
        // The table is full of live entries, a new (real) user is still served instead of rejected.
        #expect(limiter.allow("i:" + newID(), limit: 60, window: 60, now: run0))
    }

    @Test func evictionKeepsTheTableBounded() {
        let limiter = RateLimiter(maxKeys: 100)
        for _ in 0..<5_000 { _ = limiter.allow("i:" + newID(), limit: 60, window: 60, now: run0) }
        #expect(limiter.keyCount <= 100)
    }

    @Test func globalCountersSurviveAFlood() {
        let limiter = RateLimiter(maxKeys: 100)
        for _ in 0..<3 { _ = limiter.allow("global:put", limit: 3, window: 60, now: run0) }
        for _ in 0..<5_000 { _ = limiter.allow("i:" + newID(), limit: 60, window: 60, now: run0) }
        #expect(!limiter.allow("global:put", limit: 3, window: 60, now: run0), "a flood must not reset the global counter")
    }

    @Test func windowStillCountsPerKey() {
        let limiter = RateLimiter(maxKeys: 100)
        #expect(limiter.allow("i:a", limit: 2, window: 60, now: run0))
        #expect(limiter.allow("i:a", limit: 2, window: 60, now: run0))
        #expect(!limiter.allow("i:a", limit: 2, window: 60, now: run0))
        #expect(limiter.allow("i:a", limit: 2, window: 60, now: run0.addingTimeInterval(61)))
    }

    @Test func totalRequestRateIsLimitedBeforeAnyLookup() async {
        let api = PushApi(repo: MemoryRepo(), config: hardeningConfig(), globalRequestLimit: 5, clock: { run0 })
        var statuses: [Int] = []
        for _ in 0..<8 {
            statuses.append(await api.handle(method: "GET", path: "/v1/push/installations/\(newID())/subscriptions", secret: secret, body: [])?.status ?? 0)
        }
        #expect(statuses == [401, 401, 401, 401, 401, 429, 429, 429])
    }

    @Test func repeatedWrongSecretsAreBlockedWithoutFurtherLookups() async throws {
        let repo = MemoryRepo()
        let api = PushApi(repo: repo, config: hardeningConfig(), clock: { run0 })
        let base = "/v1/push/installations/\(newID())"
        let id = String(base.dropFirst("/v1/push/installations/".count))
        _ = try await repo.upsertInstallation(id: id, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0)
        for _ in 0..<PushApi.failedAuthLimit {
            #expect(await api.handle(method: "GET", path: base + "/subscriptions", secret: otherSecret, body: [])?.status == 401)
        }
        let blocked = await api.handle(method: "GET", path: base + "/subscriptions", secret: otherSecret, body: [])
        #expect(blocked?.status == 429 && text(blocked) == #"{"error":"rate_limited"}"#)
    }

    @Test func otherInstallationsAreNotAffectedByFailures() async throws {
        let repo = MemoryRepo()
        let api = PushApi(repo: repo, config: hardeningConfig(), clock: { run0 })
        let victim = newID(), bystander = newID()
        _ = try await repo.upsertInstallation(id: bystander, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0)
        for _ in 0..<(PushApi.failedAuthLimit + 2) {
            _ = await api.handle(method: "GET", path: "/v1/push/installations/\(victim)/subscriptions", secret: otherSecret, body: [])
        }
        #expect(await api.handle(method: "GET", path: "/v1/push/installations/\(bystander)/subscriptions", secret: secret, body: [])?.status == 200)
    }
}

// MARK: H1 / H2 server-wide limits

extension DatabaseSuites {
@Suite("Hardening: server-wide limits", .serialized)
struct ServerLimitTests {
    @Test(arguments: RepoKind.allCases) func installationCapIsEnforcedOnlyForNewInstallations(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.purgePush(inactiveBefore: Date(timeIntervalSince1970: 4_000_000_000), outboxBefore: Date(timeIntervalSince1970: 4_000_000_000), now: run0)
        let (a, b, c) = (newID(), newID(), newID())
        #expect(try await repo.upsertInstallation(id: a, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0, maxInstallations: 2) == .created)
        #expect(try await repo.upsertInstallation(id: b, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0, maxInstallations: 2) == .created)
        #expect(try await repo.upsertInstallation(id: c, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0, maxInstallations: 2) == .serverFull)
        #expect(try await repo.upsertInstallation(id: a, secretHash: hash(secret), token: token, env: .sandbox, locale: "en", now: run0, maxInstallations: 2) == .updated)
        #expect(try await repo.installation(id: c) == nil)
        try await repo.deleteInstallation(id: a)
        #expect(try await repo.upsertInstallation(id: c, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0, maxInstallations: 2) == .created)
        try await repo.deleteInstallation(id: b)
        try await repo.deleteInstallation(id: c)
    }

    @Test func apiAnswers503ServerFullAndKeepsExistingUsersWorking() async throws {
        let repo = MemoryRepo()
        let api = PushApi(repo: repo, config: hardeningConfig { $0.push.maxInstallations = 1 }, clock: { run0 })
        let first = newID(), second = newID()
        #expect(await api.handle(method: "PUT", path: "/v1/push/installations/\(first)", secret: secret, body: installBody)?.status == 201)
        let full = await api.handle(method: "PUT", path: "/v1/push/installations/\(second)", secret: secret, body: installBody)
        #expect(full?.status == 503 && text(full) == #"{"error":"server_full"}"#)
        #expect(await api.handle(method: "PUT", path: "/v1/push/installations/\(first)", secret: secret, body: installBody)?.status == 204)
        #expect(await api.handle(method: "GET", path: "/v1/push/installations/\(first)/subscriptions", secret: secret, body: [])?.status == 200)
    }

    @Test(arguments: RepoKind.allCases) func subscriptionCapIsServerWide(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.purgePush(inactiveBefore: Date(timeIntervalSince1970: 4_000_000_000), outboxBefore: Date(timeIntervalSince1970: 4_000_000_000), now: run0)
        let (a, b) = (newID(), newID())
        for id in [a, b] { _ = try await repo.upsertInstallation(id: id, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0) }
        let limits = RegionLimits(maxSubscriptionsServerwide: 2)
        func add(_ install: String) async throws -> AddSubscriptionResult {
            try await repo.addSubscription(installationID: install, id: newID(),
                                           PushSubscriptionInput(gridVersion: 1, cellX: 5, cellY: 5, threshold: 3, leadMinutes: 20, enabled: true),
                                           maxPerInstallation: 10, regionLimits: limits, now: run0)
        }
        #expect(try await add(a) == .created)
        #expect(try await add(b) == .created)
        #expect(try await add(a) == .serverFull)
        try await repo.deleteInstallation(id: a)
        try await repo.deleteInstallation(id: b)
    }

    @Test func apiAnswers503WhenSubscriptionCapIsReached() async throws {
        let repo = MemoryRepo()
        let api = PushApi(repo: repo, config: hardeningConfig { $0.push.regionLimits.maxSubscriptionsServerwide = 1 }, clock: { run0 })
        let base = "/v1/push/installations/\(newID())"
        _ = await api.handle(method: "PUT", path: base, secret: secret, body: installBody)
        #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secret, body: subBody())?.status == 201)
        let full = await api.handle(method: "POST", path: base + "/subscriptions", secret: secret, body: subBody())
        #expect(full?.status == 503 && text(full) == #"{"error":"server_full"}"#)
    }

    @Test func fakeInstallationsCannotExhaustTheCellBudgetForRealUsers() async throws {
        // Old budget: 2 Mio. cells = 400 radius-40 regions from 400 anonymous installations blocked everybody.
        let repo = MemoryRepo()
        let api = PushApi(repo: repo, config: hardeningConfig(), clock: { run0 })
        for _ in 0..<400 {
            let id = newID()
            _ = try await repo.upsertInstallation(id: id, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0)
            let result = try await repo.addSubscription(
                installationID: id, id: newID(),
                PushSubscriptionInput(gridVersion: 1, cellX: 40, cellY: 50, threshold: 3, leadMinutes: 20, enabled: true,
                                      kind: .circle, radiusCells: 40, minSharePercent: 10),
                maxPerInstallation: 10, regionLimits: PushSettings().regionLimits, now: run0)
            #expect(result == .created)
        }
        let real = "/v1/push/installations/\(newID())"
        _ = await api.handle(method: "PUT", path: real, secret: secret, body: installBody)
        let created = await api.handle(method: "POST", path: real + "/subscriptions", secret: secret,
                                       body: subBody(["kind": "circle", "radius_cells": 14]))
        #expect(created?.status == 201)
    }

    @Test func limitsAreConfigurableFromTheEnvironment() throws {
        let c = try Config.fromEnvironment(["PUSH_MAX_INSTALLATIONS": "7", "PUSH_MAX_SUBSCRIPTIONS": "9", "PUSH_MAX_REGION_CELLS": "123"])
        #expect(c.push.maxInstallations == 7 && c.push.regionLimits.maxSubscriptionsServerwide == 9 && c.push.regionLimits.maxCellsServerwide == 123)
        let d = Config().push
        #expect(d.maxInstallations == 100_000 && d.regionLimits.maxSubscriptionsServerwide == 400_000)
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["PUSH_MAX_INSTALLATIONS": "0"]) }
    }

    @Test(arguments: RepoKind.allCases) func evaluationPagesCoverAllSubscriptionsInIDOrder(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.purgePush(inactiveBefore: Date(timeIntervalSince1970: 4_000_000_000), outboxBefore: Date(timeIntervalSince1970: 4_000_000_000), now: run0)
        let install = newID()
        _ = try await repo.upsertInstallation(id: install, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0)
        var ids: [String] = []
        for i in 0..<7 {
            let id = newID(); ids.append(id)
            _ = try await repo.addSubscription(installationID: install, id: id,
                                               PushSubscriptionInput(gridVersion: 1, cellX: i, cellY: 5, threshold: 3, leadMinutes: 20, enabled: true),
                                               maxPerInstallation: 10, now: run0)
        }
        var seen: [String] = []
        var after: String?
        var pages = 0
        while true {
            let page = try await repo.evaluationSubscriptions(gridVersion: 1, after: after, limit: 3)
            if page.isEmpty { break }
            #expect(page.count <= 3)
            seen += page.map(\.id)
            after = page.last?.id
            pages += 1
        }
        #expect(seen == ids.sorted() && pages == 3)
        try await repo.deleteInstallation(id: install)
    }
}
}

// MARK: M2 cheap requests

@Suite("Hardening: cheap requests")
struct CheapRequestTests {
    @Test func statusIsMemoizedForTheManifestTTL() async throws {
        let now = Locked(run0)
        let api = Api(repo: MemoryRepo(), config: smallConfig(), clock: { now.withLock { $0 } })
        let first = try await api.handle(path: "/v1/status", ifNoneMatch: nil)
        now.withLock { $0 = run0.addingTimeInterval(2) }
        let second = try await api.handle(path: "/v1/status", ifNoneMatch: nil)
        #expect(first.body == second.body, "within the TTL the memo answers, no new queries")
        now.withLock { $0 = run0.addingTimeInterval(Api.manifestTTL + 1) }
        let third = try await api.handle(path: "/v1/status", ifNoneMatch: nil)
        #expect(third.status == 200 && third.body != first.body)
    }

    @Test func missingSlotsAreRememberedBrieflyAndRetriedLater() async throws {
        let now = Locked(run0)
        let cache = SlotCache(maxBytes: 1_000_000, missingTTL: 10, clock: { now.withLock { $0 } })
        let reads = Locked(0)
        let loader: @Sendable () async throws -> SlotBlob? = { reads.withLock { $0 += 1 }; return nil }
        #expect(try await cache.load("a/b", loader) == nil)
        #expect(try await cache.load("a/b", loader) == nil)
        #expect(reads.withLock { $0 } == 1)
        now.withLock { $0 = run0.addingTimeInterval(11) }
        #expect(try await cache.load("a/b", loader) == nil)
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func negativeEntriesAreBounded() async throws {
        let cache = SlotCache(maxBytes: 1_000_000, missingTTL: 10, missingMax: 50, clock: { run0 })
        for i in 0..<500 { _ = try await cache.load("k\(i)", { nil }) }
        #expect(await cache.missingCount <= 50)
    }

    @Test func authenticationRefreshesLastSeenAtMostHourly() async throws {
        let repo = MemoryRepo()
        let id = newID()
        _ = try await repo.upsertInstallation(id: id, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0)
        #expect(try await repo.authenticate(id: id, secretHash: hash(secret), now: run0.addingTimeInterval(600)))
        #expect(await repo.push.installs[id]?.lastSeenAt == run0)
        #expect(try await repo.authenticate(id: id, secretHash: hash(secret), now: run0.addingTimeInterval(2 * 3600)))
        #expect(await repo.push.installs[id]?.lastSeenAt == run0.addingTimeInterval(2 * 3600))
        #expect(try await !repo.authenticate(id: id, secretHash: hash(otherSecret), now: run0.addingTimeInterval(3 * 3600)))
    }

    @Test func wrongSecretFormatNeverReachesTheRepository() async {
        let api = PushApi(repo: MemoryRepo(), config: hardeningConfig(), clock: { run0 })
        for bad in [nil, "short", String(repeating: "!", count: 40)] {
            #expect(await api.handle(method: "GET", path: "/v1/push/installations/\(newID())/subscriptions", secret: bad, body: [])?.status == 401)
        }
    }
}

// MARK: H1 paged evaluation

@Suite("Hardening: paged evaluation")
struct PagedEvaluationTests {
    @Test func everySubscriptionIsEvaluatedAcrossPages() async throws {
        let config = hardeningConfig()
        let repo = MemoryRepo()
        let install = newID()
        _ = try await repo.upsertInstallation(id: install, secretHash: hash(secret), token: token, env: .sandbox, locale: "de", now: run0)
        var ids: [String] = []
        for _ in 0..<5 {
            let id = newID(); ids.append(id)
            _ = try await repo.addSubscription(installationID: install, id: id, PushSubscriptionInput(gridVersion: 1, cellX: 40, cellY: 50, threshold: 3, leadMinutes: 20, enabled: true),
                                               maxPerInstallation: 10, now: run0)
        }
        func publish(_ nominal: Date, onset: Int) async throws {
            let id = TimeUtil.toID(nominal)
            #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
            let color = PushIntensity.palette[2]
            for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
                var image = makeImage(width: config.width, height: config.height, seed: 200 + index)
                if index >= onset {
                    var pixels = image.pixels
                    let o = (50 * config.width + 40) * 4
                    pixels[o] = UInt8(color.r); pixels[o + 1] = UInt8(color.g); pixels[o + 2] = UInt8(color.b); pixels[o + 3] = 255
                    image = RGBAImage(width: image.width, height: image.height, pixels: pixels)
                }
                try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot),
                                       contentType: "image/webp", data: try ImagePipeline.toWebP(image))
            }
            #expect(try await repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
        }
        let now = Locked(run0.addingTimeInterval(240))
        let service = PushService(config: config, repo: repo, sender: FakeApnsSender(), owner: "a", evaluationPageSize: 2, clock: { now.withLock { $0 } })
        try await publish(run0, onset: 3)
        _ = try await service.tick()
        #expect(try await repo.subscriptions(installationID: install).allSatisfy { $0.state == .pending })
        let run1 = run0.addingTimeInterval(300)
        now.withLock { $0 = run1.addingTimeInterval(240) }
        try await publish(run1, onset: 2)
        let tick = try await service.tick()
        #expect(tick.queued == 5 && tick.sent == 5)
    }
}
