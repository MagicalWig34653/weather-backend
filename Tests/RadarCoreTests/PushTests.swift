import Crypto
import Foundation
import Testing
@testable import RadarCore

private func pushConfig(_ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig {
        $0.push.enabled = true
        $0.push.topic = "de.example.app"
        $0.push.environments = [.sandbox, .production]
        edit(&$0)
    }
}

private let installA = "11111111-1111-4111-8111-111111111111"
private let installB = "22222222-2222-4222-8222-222222222222"
private let secretA = String(repeating: "a", count: 40)
private let secretB = String(repeating: "b", count: 40)
private let tokenA = String(repeating: "ab", count: 32)
private let tokenB = String(repeating: "cd", count: 32)

private func hash(_ secret: String) -> String { Hashing.sha256Hex(Array(secret.utf8)) }

private func input(x: Int = 10, y: Int = 20, threshold: Int = 3, lead: Int = 20, enabled: Bool = true) -> PushSubscriptionInput {
    PushSubscriptionInput(gridVersion: PushGrid.version, cellX: x, cellY: y, threshold: threshold, leadMinutes: lead, enabled: enabled)
}

@discardableResult
private func register(_ repo: any Repo, id: String = installA, secret: String = secretA, token: String = tokenA,
                      env: PushEnvironment = .sandbox, now: Date = run0) async throws -> UpsertResult {
    try await repo.upsertInstallation(id: id, secretHash: hash(secret), token: token, env: env, locale: "de", now: now)
}

private func newID() -> String { UUID().uuidString.lowercased() }

// MARK: pure logic

@Suite("Push intensity and automaton")
struct PushLogicTests {
    @Test func legendColoursMapToTheirClass() {
        for (index, color) in PushIntensity.palette.enumerated() {
            #expect(PushIntensity.classify(r: UInt8(color.r), g: UInt8(color.g), b: UInt8(color.b), a: 255) == index + 1)
        }
        #expect(PushIntensity.palette.count == 15)
        #expect(PushIntensity.lowerBoundsMMPerHour.count == 15)
    }

    @Test func backgroundMaskAndUnknownColoursAreDry() {
        #expect(PushIntensity.classify(r: 0x7D, g: 0x7D, b: 0x7D, a: 77) == 0)   // "no data" class of the style
        #expect(PushIntensity.classify(r: 0x01, g: 0x99, b: 0x34, a: 10) == 0)   // transparent
        #expect(PushIntensity.classify(r: 255, g: 255, b: 255, a: 255) == 0)     // white mask
        #expect(PushIntensity.classify(r: 247, g: 0, b: 255, a: 223) == 0)       // magenta marker, not in the legend
        #expect(PushIntensity.classify(r: 0x02, g: 0x98, b: 0x35, a: 255) == 3)  // small deviation still matches
    }

    private func slots(_ onset: Int?, wetNow: Bool = false, level: Int = 5) -> [Int] {
        var c = [Int](repeating: 0, count: TimeUtil.forecastSlots)
        if wetNow { c[0] = level }
        if let onset { for i in onset..<c.count { c[i] = level } }
        return c
    }

    @Test func needsTwoConsecutiveRunsThenNotifiesOnce() {
        let now = run0
        let one = PushEvaluator.step(state: .dry, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(3), now: now)
        #expect(one == .init(state: .pending, notifyMinutes: nil))
        let two = PushEvaluator.step(state: .pending, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(2), now: now)
        #expect(two == .init(state: .notified, notifyMinutes: 10))
        let again = PushEvaluator.step(state: .notified, threshold: 3, leadMinutes: 20, lastSentAt: now, classes: slots(1), now: now)
        #expect(again == .init(state: .notified, notifyMinutes: nil))
    }

    @Test func forecastJumpBackResetsAndRainBeyondLeadIsIgnored() {
        let now = run0
        #expect(PushEvaluator.step(state: .pending, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(nil), now: now).state == .dry)
        #expect(PushEvaluator.step(state: .dry, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(5), now: now).state == .dry)  // 25 min > 20
        #expect(PushEvaluator.step(state: .dry, threshold: 3, leadMinutes: 30, lastSentAt: nil, classes: slots(6), now: now).state == .pending)
        #expect(PushEvaluator.step(state: .dry, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(2, level: 2), now: now).state == .dry)  // below threshold
    }

    @Test func alreadyRainingDoesNotNotify() {
        let now = run0
        #expect(PushEvaluator.step(state: .dry, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(1, wetNow: true), now: now).state == .dry)
        #expect(PushEvaluator.step(state: .pending, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: slots(1, wetNow: true), now: now) == .init(state: .dry, notifyMinutes: nil))
    }

    @Test func repeatLockHoldsBackAndRearmNeedsDryHalfHour() {
        let now = run0
        let recent = now.addingTimeInterval(-30 * 60)
        #expect(PushEvaluator.step(state: .pending, threshold: 3, leadMinutes: 20, lastSentAt: recent, classes: slots(2), now: now) == .init(state: .pending, notifyMinutes: nil))
        let old = now.addingTimeInterval(-61 * 60)
        #expect(PushEvaluator.step(state: .pending, threshold: 3, leadMinutes: 20, lastSentAt: old, classes: slots(2), now: now).notifyMinutes == 10)
        #expect(PushEvaluator.step(state: .notified, threshold: 3, leadMinutes: 20, lastSentAt: recent, classes: slots(7), now: now).state == .dry)
        #expect(PushEvaluator.step(state: .notified, threshold: 3, leadMinutes: 20, lastSentAt: recent, classes: slots(6), now: now).state == .notified)
    }

    @Test func incompleteSlotsChangeNothing() {
        #expect(PushEvaluator.step(state: .pending, threshold: 3, leadMinutes: 20, lastSentAt: nil, classes: [0, 3], now: run0) == .init(state: .pending, notifyMinutes: nil))
    }

    @Test func payloadHasNoPlaceNameOrCoordinates() throws {
        let text = PushEvaluator.payload(minutes: 15, subscriptionID: installA)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["loc-key"] as? String == "RAIN_STARTS_IN")
        #expect(alert["loc-args"] as? [String] == ["15"])
        #expect(text.utf8.count < 4096)
    }

    @Test func gridCellFromMercatorCorners() {
        let b = RadarConstants.bbox
        #expect(PushGrid.cell(mercatorX: b[0], mercatorY: b[3], width: 1024)! == (0, 0))
        let last = PushGrid.cell(mercatorX: b[2] - 1, mercatorY: b[1] + 1, width: 1024)!
        #expect(last == (1023, RadarConstants.imageHeight(width: 1024) - 1))
        #expect(PushGrid.cell(mercatorX: 0, mercatorY: 0, width: 1024) == nil)
    }

    @Test func configRequiresKeyWhenEnabled() throws {
        let off = try Config.fromEnvironment([:])
        #expect(!off.push.enabled)
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["PUSH_ENABLED": "true"]) }
        let on = try Config.fromEnvironment(["PUSH_ENABLED": "true", "APNS_KEY": "pem", "APNS_KEY_ID": "ABCDEFGHIJ", "APNS_TEAM_ID": "TEAMID1234",
                                             "APNS_TOPIC": "de.example.app", "APNS_ENV": "both"])
        #expect(on.push.enabled && on.push.environments == [.sandbox, .production])
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["APNS_ENV": "mars"]) }
        #expect(throws: ConfigError.self) {
            try Config.fromEnvironment(["PUSH_ENABLED": "true", "APNS_KEY": "pem", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "APNS_TOPIC": "t", "IMAGE_WIDTH": "512"])
        }
    }
}

// MARK: repo contract (memory and, if available, MariaDB)

extension DatabaseSuites {
@Suite("Push repo contract", .serialized)
struct PushRepoTests {
    @Test(arguments: RepoKind.allCases)
    func installationOwnershipAndCascade(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await register(repo) == .created)
        #expect(try await register(repo, token: tokenB) == .updated)
        #expect(try await register(repo, secret: secretB) == .forbidden)
        #expect(try await repo.authenticate(id: installA, secretHash: hash(secretA), now: run0))
        #expect(try await !repo.authenticate(id: installA, secretHash: hash(secretB), now: run0))
        #expect(try await !repo.authenticate(id: installB, secretHash: hash(secretA), now: run0))
        let sub = newID()
        #expect(try await repo.addSubscription(installationID: installA, id: sub, input(), maxPerInstallation: 10, now: run0) == .created)
        #expect(try await repo.subscriptions(installationID: installA).map(\.id) == [sub])
        try await repo.deleteInstallation(id: installA)
        #expect(try await repo.subscriptions(installationID: installA).isEmpty)
        #expect(try await repo.evaluationSubscriptions(gridVersion: PushGrid.version).isEmpty)
    }

    @Test(arguments: RepoKind.allCases)
    func subscriptionLimitAndOwnership(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo); try await register(repo, id: installB, secret: secretB, token: tokenB)
        for _ in 0..<3 { #expect(try await repo.addSubscription(installationID: installA, id: newID(), input(), maxPerInstallation: 3, now: run0) == .created) }
        #expect(try await repo.addSubscription(installationID: installA, id: newID(), input(), maxPerInstallation: 3, now: run0) == .limitReached)
        #expect(try await repo.addSubscription(installationID: "33333333-3333-4333-8333-333333333333", id: newID(), input(), maxPerInstallation: 3, now: run0) == .unknownInstallation)
        let mine = try #require(try await repo.subscriptions(installationID: installA).first)
        #expect(try await !repo.updateSubscription(installationID: installB, id: mine.id, input(threshold: 9)))
        #expect(try await !repo.deleteSubscription(installationID: installB, id: mine.id))
        #expect(try await repo.updateSubscription(installationID: installA, id: mine.id, input(threshold: 9, enabled: false)))
        let changed = try #require(try await repo.subscriptions(installationID: installA).first { $0.id == mine.id })
        #expect(changed.threshold == 9 && !changed.enabled && changed.state == .dry)
        #expect(try await repo.evaluationSubscriptions(gridVersion: PushGrid.version).count == 2)  // the disabled one is skipped
        #expect(try await repo.deleteSubscription(installationID: installA, id: mine.id))
    }

    @Test(arguments: RepoKind.allCases)
    func evaluationCommitIsAtomicOnceAndDeduplicated(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let sub = newID()
        _ = try await repo.addSubscription(installationID: installA, id: sub, input(), maxPerInstallation: 10, now: run0)
        let item = NewOutboxItem(subID: sub, dedupeKey: "\(sub):20261030T1105Z", collapseID: sub, payloadJSON: "{}", expiresAt: run0.addingTimeInterval(1200))
        #expect(try await repo.commitEvaluation(runID: "20261030T1105Z", updates: [SubscriptionUpdate(id: sub, state: .notified, lastSentAt: run0)], outbox: [item], now: run0))
        #expect(try await !repo.commitEvaluation(runID: "20261030T1105Z", updates: [], outbox: [item], now: run0))  // same run: no second commit
        #expect(try await !repo.commitEvaluation(runID: "20261030T1100Z", updates: [], outbox: [], now: run0))  // older run
        #expect(try await repo.lastEvaluatedRun() == "20261030T1105Z")
        // Same dedupe key in a later commit does not create a second outbox row.
        #expect(try await repo.commitEvaluation(runID: "20261030T1110Z", updates: [], outbox: [item], now: run0))
        let due = try await repo.dueOutbox(now: run0, limit: 10)
        #expect(due.count == 1 && due[0].token == tokenA && due[0].env == .sandbox && due[0].collapseID == sub)
        let stored = try #require(try await repo.subscriptions(installationID: installA).first)
        #expect(stored.state == .notified && stored.lastSentAt == run0)
        // Items of a vanished subscription are skipped.
        _ = try await repo.deleteSubscription(installationID: installA, id: sub)
        #expect(try await repo.dueOutbox(now: run0, limit: 10).isEmpty)
    }

    @Test(arguments: RepoKind.allCases)
    func outboxRetryAndFinish(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let sub = newID()
        _ = try await repo.addSubscription(installationID: installA, id: sub, input(), maxPerInstallation: 10, now: run0)
        _ = try await repo.commitEvaluation(runID: "20261030T1105Z", updates: [], outbox: [
            NewOutboxItem(subID: sub, dedupeKey: "k1", collapseID: sub, payloadJSON: "{}", expiresAt: run0.addingTimeInterval(1200))], now: run0)
        let first = try #require(try await repo.dueOutbox(now: run0, limit: 10).first)
        try await repo.finishOutbox(id: first.id, .retry(attempts: 1, at: run0.addingTimeInterval(60)), now: run0)
        #expect(try await repo.dueOutbox(now: run0, limit: 10).isEmpty)
        let later = try #require(try await repo.dueOutbox(now: run0.addingTimeInterval(61), limit: 10).first)
        #expect(later.attempts == 1)
        try await repo.finishOutbox(id: later.id, .sent, now: run0.addingTimeInterval(61))
        #expect(try await repo.dueOutbox(now: run0.addingTimeInterval(9999), limit: 10).isEmpty)
    }

    @Test(arguments: RepoKind.allCases)
    func timeSensitiveFlagAndInstallationLookup(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo, token: tokenA, env: .production)
        #expect(try await repo.installation(id: installA) == PushInstallation(token: tokenA, env: .production, locale: "de"))
        #expect(try await repo.installation(id: installB) == nil)
        let plain = newID(), urgent = newID()
        _ = try await repo.addSubscription(installationID: installA, id: plain, input(), maxPerInstallation: 10, now: run0)
        var flagged = input(); flagged.timeSensitive = true
        _ = try await repo.addSubscription(installationID: installA, id: urgent, flagged, maxPerInstallation: 10, now: run0)
        var byID = Dictionary(uniqueKeysWithValues: try await repo.subscriptions(installationID: installA).map { ($0.id, $0.timeSensitive) })
        #expect(byID[plain] == false && byID[urgent] == true)
        #expect(try await repo.evaluationSubscriptions(gridVersion: PushGrid.version).first { $0.id == urgent }?.timeSensitive == true)
        #expect(try await repo.updateSubscription(installationID: installA, id: urgent, input()))
        #expect(try await repo.updateSubscription(installationID: installA, id: plain, flagged))
        byID = Dictionary(uniqueKeysWithValues: try await repo.subscriptions(installationID: installA).map { ($0.id, $0.timeSensitive) })
        #expect(byID[plain] == true && byID[urgent] == false)
    }

    @Test(arguments: RepoKind.allCases)
    func tokenDeletionAndRetention(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo, now: run0.addingTimeInterval(-61 * 86400))                       // inactive for 61 days
        try await register(repo, id: installB, secret: secretB, token: tokenB, env: .production, now: run0.addingTimeInterval(-59 * 86400))
        let purged = try await repo.purgePush(inactiveBefore: run0.addingTimeInterval(-60 * 86400), outboxBefore: run0.addingTimeInterval(-3600), now: run0)
        #expect(purged.installations == 1)
        #expect(try await !repo.authenticate(id: installA, secretHash: hash(secretA), now: run0))
        #expect(try await repo.authenticate(id: installB, secretHash: hash(secretB), now: run0))
        #expect(try await repo.deleteInstallations(token: tokenB, env: .sandbox) == 0)  // other environment: untouched
        #expect(try await repo.deleteInstallations(token: tokenB, env: .production) == 1)
    }
}
}

// MARK: registration API

@Suite("Push API")
struct PushApiTests {
    private func api(_ edit: (inout Config) -> Void = { _ in }) -> (PushApi, MemoryRepo, Config) {
        let config = pushConfig(edit)
        let repo = MemoryRepo()
        return (PushApi(repo: repo, config: config, clock: { run0 }), repo, config)
    }

    private func json(_ object: [String: Any]) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
    private var installBody: [UInt8] { json(["token": tokenA.uppercased(), "env": "sandbox", "locale": "de"]) }
    private func subBody(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [UInt8] {
        var o: [String: Any] = ["grid_version": 1, "cell_x": 10, "cell_y": 20, "threshold": 3, "lead_minutes": 20]
        edit(&o)
        return json(o)
    }
    private func text(_ r: ApiResponse?) -> String { String(decoding: r?.body ?? [], as: UTF8.self) }

    @Test func disabledMeansNotFound() async {
        let (api, _, _) = api { $0.push.enabled = false }
        #expect(await api.handle(method: "PUT", path: "/v1/push/installations/\(installA)", secret: secretA, body: installBody) == nil)
    }

    @Test func fullLifecycle() async throws {
        let (api, repo, _) = api()
        let base = "/v1/push/installations/\(installA)"
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: installBody)?.status == 201)
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: installBody)?.status == 204)
        #expect(await api.handle(method: "PUT", path: base, secret: secretB, body: installBody)?.status == 401)
        let created = try #require(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: subBody()))
        #expect(created.status == 201)
        let id = try #require((try JSONSerialization.jsonObject(with: Data(created.body)) as? [String: Any])?["id"] as? String)
        let list = try #require(await api.handle(method: "GET", path: base + "/subscriptions", secret: secretA, body: []))
        #expect(list.status == 200 && !text(list).contains("token"))
        #expect(await api.handle(method: "PUT", path: base + "/subscriptions/\(id)", secret: secretA, body: subBody { $0["threshold"] = 7 })?.status == 204)
        #expect(try await repo.subscriptions(installationID: installA).first?.threshold == 7)
        #expect(await api.handle(method: "DELETE", path: base + "/subscriptions/\(id)", secret: secretA, body: [])?.status == 204)
        #expect(await api.handle(method: "DELETE", path: base + "/subscriptions/\(id)", secret: secretA, body: [])?.status == 404)
        #expect(await api.handle(method: "DELETE", path: base, secret: secretA, body: [])?.status == 204)
        #expect(await api.handle(method: "GET", path: base + "/subscriptions", secret: secretA, body: [])?.status == 401)
        // Token is stored normalized (lower case hex).
        #expect(try await repo.deleteInstallations(token: tokenA, env: .sandbox) == 0)
    }

    @Test func authenticationIsRequired() async {
        let (api, _, _) = api()
        let base = "/v1/push/installations/\(installA)"
        _ = await api.handle(method: "PUT", path: base, secret: secretA, body: installBody)
        for method in ["GET", "POST"] {
            #expect(await api.handle(method: method, path: base + "/subscriptions", secret: nil, body: subBody())?.status == 401)
            #expect(await api.handle(method: method, path: base + "/subscriptions", secret: secretB, body: subBody())?.status == 401)
            #expect(await api.handle(method: method, path: base + "/subscriptions", secret: "short", body: subBody())?.status == 401)
        }
        #expect(await api.handle(method: "DELETE", path: base, secret: secretB, body: [])?.status == 401)
    }

    @Test func inputValidation() async {
        let (api, _, config) = api()
        let base = "/v1/push/installations/\(installA)"
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: json(["token": "zz", "env": "sandbox", "locale": "de"]))?.status == 400)
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: json(["token": tokenA, "env": "dev", "locale": "de"]))?.status == 400)
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: json(["token": tokenA, "env": "sandbox", "locale": "fr"]))?.status == 400)
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: Array("nope".utf8))?.status == 400)
        #expect(await api.handle(method: "PUT", path: "/v1/push/installations/not-a-uuid", secret: secretA, body: installBody)?.status == 400)
        #expect(await api.handle(method: "PUT", path: base, secret: secretA, body: [UInt8](repeating: 0x20, count: 3000))?.status == 413)
        _ = await api.handle(method: "PUT", path: base, secret: secretA, body: installBody)
        let bad: [(String, Any)] = [("grid_version", 2), ("cell_x", -1), ("cell_x", config.width), ("cell_y", config.height), ("threshold", 0),
                                    ("threshold", 16), ("lead_minutes", 15), ("lead_minutes", 60)]
        for (key, value) in bad {
            #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: subBody { $0[key] = value })?.status == 400, "\(key)=\(value)")
        }
        #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: Array("{}".utf8))?.status == 400)
        #expect(await api.handle(method: "GET", path: "/v1/push/other", secret: secretA, body: []) == nil)
        #expect(await api.handle(method: "PATCH", path: base, secret: secretA, body: [])?.status == 405)
    }

    @Test func subscriptionLimitPerInstallation() async {
        let (api, _, _) = api()
        let base = "/v1/push/installations/\(installA)"
        _ = await api.handle(method: "PUT", path: base, secret: secretA, body: installBody)
        for _ in 0..<PushGrid.maxSubscriptionsPerInstallation {
            #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: subBody())?.status == 201)
        }
        #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: subBody())?.status == 409)
    }

    @Test func rateLimitPerInstallation() async {
        let (api, _, _) = api()
        let base = "/v1/push/installations/\(installA)"
        var statuses: [Int] = []
        // Registered first (one request), so that the requests are authenticated and failed-auth blocking does not interfere.
        _ = await api.handle(method: "PUT", path: base, secret: secretA, body: installBody)
        for _ in 0..<(PushApi.perInstallationLimit - 1 + 5) {
            statuses.append(await api.handle(method: "GET", path: base + "/subscriptions", secret: secretA, body: [])?.status ?? 0)
        }
        #expect(statuses.filter { $0 == 429 }.count == 5)
        // Another installation is not affected.
        #expect(await api.handle(method: "GET", path: "/v1/push/installations/\(installB)/subscriptions", secret: secretB, body: [])?.status == 401)
    }

    @Test func responsesCarryNoCookiesAndAreNotCacheable() async throws {
        let (api, _, _) = api()
        let r = try #require(await api.handle(method: "PUT", path: "/v1/push/installations/\(installA)", secret: secretA, body: installBody))
        #expect(r.headers.contains { $0.0 == "Cache-Control" && $0.1 == "no-store" })
        #expect(!r.headers.contains { $0.0.lowercased() == "set-cookie" })
    }
}

// MARK: APNs client

@Suite("APNs client")
struct ApnsClientTests {
    final class RecordingTransport: ApnsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [ApnsHTTPRequest] = []
        var response: ApnsHTTPResponse
        var fail = false
        init(_ response: ApnsHTTPResponse) { self.response = response }
        func perform(_ request: ApnsHTTPRequest) async throws -> ApnsHTTPResponse {
            lock.withLock { requests.append(request) }
            if fail { throw FakeDwd.NetworkError() }
            return response
        }
    }

    private func client(_ transport: RecordingTransport, key: P256.Signing.PrivateKey, clock: @escaping @Sendable () -> Date = { run0 }) throws -> ApnsClient {
        try ApnsClient(keyPEM: key.pemRepresentation, keyID: "ABCDE12345", teamID: "TEAM123456", topic: "de.example.app", transport: transport, clock: clock)
    }

    private let request = ApnsRequest(tokenHex: tokenA, env: .sandbox, topic: "ignored", payload: Array("{}".utf8), collapseID: installA, expiration: 1_800_000_000)

    @Test func requestFollowsAppleSpecAndJWTIsValid() async throws {
        let key = P256.Signing.PrivateKey()
        let transport = RecordingTransport(.init(status: 200, body: []))
        let client = try client(transport, key: key)
        #expect(await client.send(request) == .delivered)
        let http = try #require(transport.requests.first)
        #expect(http.url == "https://api.sandbox.push.apple.com/3/device/\(tokenA)")
        let headers = Dictionary(uniqueKeysWithValues: http.headers)
        #expect(headers["apns-topic"] == "de.example.app" && headers["apns-push-type"] == "alert" && headers["apns-priority"] == "10")
        #expect(headers["apns-expiration"] == "1800000000" && headers["apns-collapse-id"] == installA)
        let bearer = try #require(headers["authorization"]?.split(separator: " ").last.map(String.init))
        let parts = bearer.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ s: String) -> Data { Data(base64Encoded: s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - s.count % 4) % 4))! }
        let header = try #require(JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any])
        let claims = try #require(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
        #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "ABCDE12345")
        #expect(claims["iss"] as? String == "TEAM123456" && claims["iat"] as? Int == Int(run0.timeIntervalSince1970))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Array((parts[0] + "." + parts[1]).utf8)))
        var production = request; production.env = .production
        _ = await client.send(production)
        #expect(transport.requests.last?.url.hasPrefix("https://api.push.apple.com/3/device/") == true)
    }

    @Test func tokenIsReusedAndRefreshedAfterLifetime() async throws {
        let key = P256.Signing.PrivateKey()
        let now = Locked(run0)
        let transport = RecordingTransport(.init(status: 200, body: []))
        let client = try client(transport, key: key, clock: { now.withLock { $0 } })
        _ = await client.send(request); _ = await client.send(request)
        now.withLock { $0 = run0.addingTimeInterval(ApnsClient.tokenLifetime + 1) }
        _ = await client.send(request)
        let tokens = transport.requests.map { Dictionary(uniqueKeysWithValues: $0.headers)["authorization"] }
        #expect(tokens[0] == tokens[1] && tokens[1] != tokens[2])
    }

    @Test func statusMapping() async throws {
        func result(_ status: Int, _ reason: String) async throws -> ApnsResult {
            let transport = RecordingTransport(.init(status: status, body: Array(#"{"reason":"\#(reason)"}"#.utf8)))
            return await (try client(transport, key: P256.Signing.PrivateKey())).send(request)
        }
        #expect(try await result(410, "Unregistered") == .unregistered)
        #expect(try await result(400, "BadDeviceToken") == .badToken("BadDeviceToken"))
        #expect(try await result(400, "DeviceTokenNotForTopic") == .badToken("DeviceTokenNotForTopic"))
        #expect(try await result(400, "PayloadEmpty") == .rejected("400 PayloadEmpty"))
        #expect(try await result(403, "ExpiredProviderToken") == .retry("ExpiredProviderToken"))
        #expect(try await result(429, "TooManyRequests") == .retry("TooManyRequests"))
        #expect(try await result(503, "ServiceUnavailable") == .retry("ServiceUnavailable"))
        let down = RecordingTransport(.init(status: 200, body: []))
        down.fail = true
        #expect(await (try client(down, key: P256.Signing.PrivateKey())).send(request) == .retry("transport"))
    }

    @Test func expiredProviderTokenForcesNewJWT() async throws {
        let transport = RecordingTransport(.init(status: 403, body: Array(#"{"reason":"ExpiredProviderToken"}"#.utf8)))
        let now = Locked(run0)
        let client = try client(transport, key: P256.Signing.PrivateKey(), clock: { now.withLock { $0 } })
        _ = await client.send(request)
        now.withLock { $0 = run0.addingTimeInterval(1) }
        _ = await client.send(request)
        let tokens = transport.requests.map { Dictionary(uniqueKeysWithValues: $0.headers)["authorization"] }
        #expect(tokens[0] != tokens[1])
    }
}

// MARK: evaluation + delivery end to end (Fake-APNs, MemoryRepo)

@Suite("Push service")
struct PushServiceTests {
    static let cell = (x: 40, y: 50)

    /// Publishes a run whose cell turns wet from slot `onset` on (nil = stays dry).
    private func publish(_ repo: any Repo, _ config: Config, nominal: Date, onset: Int?, level: Int = 3, wetNow: Bool = false) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        let color = PushIntensity.palette[level - 1]
        for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
            var image = makeImage(width: config.width, height: config.height, seed: 200 + index)  // contains grey/magenta markers elsewhere
            let wet = (index == 0 && wetNow) || (onset.map { index >= $0 } ?? false)
            if wet {
                let o = (Self.cell.y * config.width + Self.cell.x) * 4
                var pixels = image.pixels
                pixels[o] = UInt8(color.r); pixels[o + 1] = UInt8(color.g); pixels[o + 2] = UInt8(color.b); pixels[o + 3] = 255
                image = RGBAImage(width: image.width, height: image.height, pixels: pixels)
            }
            try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot),
                                   contentType: "image/webp", data: try ImagePipeline.toWebP(image))
        }
        #expect(try await repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
    }

    private func setup(env: PushEnvironment = .sandbox) async throws -> (MemoryRepo, Config, String) {
        let config = pushConfig()
        let repo = MemoryRepo()
        try await register(repo, env: env)
        let sub = newID()
        _ = try await repo.addSubscription(installationID: installA, id: sub, input(x: Self.cell.x, y: Self.cell.y), maxPerInstallation: 10, now: run0)
        return (repo, config, sub)
    }

    @Test func rainStartNotifiesAfterTwoRunsOnceOnly() async throws {
        let (repo, config, sub) = try await setup()
        let sender = FakeApnsSender()
        let now = Locked(run0.addingTimeInterval(240))
        let service = PushService(config: config, repo: repo, sender: sender, owner: "a", clock: { now.withLock { $0 } })
        try await publish(repo, config, nominal: run0, onset: 3)
        let t1 = try await service.tick()
        #expect(t1.isLeader && t1.evaluatedRun == TimeUtil.toID(run0) && t1.queued == 0)
        #expect(try await repo.subscriptions(installationID: installA).first?.state == .pending)
        let repeatedRun = try await service.tick()
        #expect(repeatedRun.evaluatedRun == nil)  // same run is not evaluated twice

        let run1 = run0.addingTimeInterval(300)
        now.withLock { $0 = run1.addingTimeInterval(240) }
        try await publish(repo, config, nominal: run1, onset: 2)
        let t2 = try await service.tick()
        #expect(t2.queued == 1 && t2.sent == 1)
        let sent = await sender.requests
        #expect(sent.count == 1 && sent[0].tokenHex == tokenA && sent[0].env == .sandbox && sent[0].collapseID == sub && sent[0].topic == "de.example.app")
        #expect(String(decoding: sent[0].payload, as: UTF8.self).contains(#""loc-args":["10"]"#))
        #expect(sent[0].expiration == Int(now.withLock { $0 }.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSince1970))

        let run2 = run1.addingTimeInterval(300)
        now.withLock { $0 = run2.addingTimeInterval(240) }
        try await publish(repo, config, nominal: run2, onset: 1)
        let t3 = try await service.tick()
        #expect(t3.queued == 0 && t3.sent == 0)
        #expect(await sender.requests.count == 1)
    }

    @Test func dryOrAlreadyRainingNeverNotifies() async throws {
        let (repo, config, _) = try await setup()
        let sender = FakeApnsSender()
        let now = Locked(run0.addingTimeInterval(240))
        let service = PushService(config: config, repo: repo, sender: sender, owner: "a", clock: { now.withLock { $0 } })
        var nominal = run0
        for (onset, wetNow) in [(nil, false), (nil, true), (1, true), (2, true)] as [(Int?, Bool)] {
            try await publish(repo, config, nominal: nominal, onset: onset, wetNow: wetNow)
            _ = try await service.tick()
            nominal = nominal.addingTimeInterval(300)
            now.withLock { $0 = nominal.addingTimeInterval(240) }
        }
        #expect(await sender.requests.isEmpty)
    }

    @Test func staleRunIsSkippedAndNeverReplayed() async throws {
        let (repo, config, _) = try await setup()
        let sender = FakeApnsSender()
        let service = PushService(config: config, repo: repo, sender: sender, owner: "a", clock: { run0.addingTimeInterval(21 * 60) })
        try await publish(repo, config, nominal: run0, onset: 2)
        let t = try await service.tick()
        #expect(t.evaluatedRun == TimeUtil.toID(run0) && t.queued == 0)
        #expect(try await repo.subscriptions(installationID: installA).first?.state == .dry)
    }

    @Test func onlyTheLeaderEvaluatesAndSends() async throws {
        let (repo, config, _) = try await setup()
        let senderA = FakeApnsSender(), senderB = FakeApnsSender()
        let now = Locked(run0.addingTimeInterval(240))
        let a = PushService(config: config, repo: repo, sender: senderA, owner: "a", clock: { now.withLock { $0 } })
        let b = PushService(config: config, repo: repo, sender: senderB, owner: "b", clock: { now.withLock { $0 } })
        try await publish(repo, config, nominal: run0, onset: 3)
        #expect(try await a.tick().isLeader)
        let other = try await b.tick()
        #expect(!other.isLeader && other.evaluatedRun == nil)
        await a.release()  // leader gone -> the other replica takes over
        #expect(try await b.tick().isLeader)
    }

    private func armed(_ repo: MemoryRepo, _ config: Config, sender: FakeApnsSender, now: Locked<Date>) async throws -> PushService {
        let service = PushService(config: config, repo: repo, sender: sender, owner: "a", clock: { now.withLock { $0 } })
        try await publish(repo, config, nominal: run0, onset: 3)
        _ = try await service.tick()
        let run1 = run0.addingTimeInterval(300)
        now.withLock { $0 = run1.addingTimeInterval(240) }
        try await publish(repo, config, nominal: run1, onset: 2)
        return service
    }

    @Test func unregisteredTokenDeletesInstallation() async throws {
        let (repo, config, _) = try await setup()
        let sender = FakeApnsSender(script: [.unregistered])
        let service = try await armed(repo, config, sender: sender, now: Locked(run0.addingTimeInterval(240)))
        let t = try await service.tick()
        #expect(t.unregistered == 1)
        #expect(try await repo.subscriptions(installationID: installA).isEmpty)
        #expect(try await !repo.authenticate(id: installA, secretHash: hash(secretA), now: run0))
    }

    @Test func transientErrorsRetryWithBackoffThenSucceed() async throws {
        let (repo, config, _) = try await setup()
        let sender = FakeApnsSender(script: [.retry("503")])
        let now = Locked(run0.addingTimeInterval(240))
        let service = try await armed(repo, config, sender: sender, now: now)
        let first = try await service.tick()
        #expect(first.retried == 1 && first.sent == 0)
        let immediately = try await service.tick()
        #expect(immediately.sent == 0 && immediately.retried == 0)  // backoff not elapsed
        now.withLock { $0 = $0.addingTimeInterval(PushService.retryBackoffSeconds[0] * 1.3 + 1) }
        let later = try await service.tick()
        #expect(later.sent == 1)
        #expect(await sender.requests.count == 2)
    }

    @Test func permanentErrorsAndExpiryDropTheMessage() async throws {
        let (repo, config, _) = try await setup()
        let sender = FakeApnsSender(script: [.badToken("BadDeviceToken")])
        let service = try await armed(repo, config, sender: sender, now: Locked(run0.addingTimeInterval(240)))
        let t = try await service.tick()
        #expect(t.dropped == 1 && t.unregistered == 0)
        #expect(try await repo.subscriptions(installationID: installA).count == 1)  // BadDeviceToken is not blindly deleted
        #expect(try await repo.dueOutbox(now: run0.addingTimeInterval(9999), limit: 10).isEmpty)
    }

    @Test func disallowedEnvironmentIsDroppedWithoutSending() async throws {
        let (repo, _, _) = try await setup(env: .sandbox)
        let config = pushConfig { $0.push.environments = [.production] }
        let sender = FakeApnsSender()
        let service = try await armed(repo, config, sender: sender, now: Locked(run0.addingTimeInterval(240)))
        let t = try await service.tick()
        #expect(t.dropped == 1 && t.sent == 0)
        #expect(await sender.requests.isEmpty)
    }

    @Test func retentionRunsInTheLeaderTick() async throws {
        let (repo, config, _) = try await setup()
        try await register(repo, id: installB, secret: secretB, token: tokenB, now: run0.addingTimeInterval(-90 * 86400))
        let service = PushService(config: config, repo: repo, sender: FakeApnsSender(), owner: "a", clock: { run0 })
        #expect(try await service.tick().purged.installations == 1)
        #expect(try await service.tick().purged.installations == 0)
        #expect(try await repo.authenticate(id: installA, secretHash: hash(secretA), now: run0))
    }

    @Test func disabledPushDoesNothing() async throws {
        let (repo, _, _) = try await setup()
        let service = PushService(config: pushConfig { $0.push.enabled = false }, repo: repo, sender: FakeApnsSender(), owner: "a")
        #expect(try await service.tick() == PushTick())
    }
}


// MARK: test notification, time sensitive, per-installation environment

@Suite("Push test notification")
struct PushTestNotificationTests {
    private func api(sender: (any ApnsSender)?, _ edit: (inout Config) -> Void = { _ in }, clock: @escaping @Sendable () -> Date = { run0 })
        -> (PushApi, MemoryRepo) {
        let repo = MemoryRepo()
        return (PushApi(repo: repo, config: pushConfig(edit), sender: sender, clock: clock), repo)
    }
    private func json(_ object: [String: Any]) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
    private func install(_ api: PushApi, env: String = "sandbox", locale: String = "de", id: String = installA, secret: String = secretA) async {
        _ = await api.handle(method: "PUT", path: "/v1/push/installations/\(id)", secret: secret,
                             body: json(["token": tokenA, "env": env, "locale": locale]))
    }
    private func test(_ api: PushApi, id: String = installA, secret: String? = secretA, method: String = "POST") async -> ApiResponse? {
        await api.handle(method: method, path: "/v1/push/installations/\(id)/test", secret: secret, body: [])
    }
    private func text(_ r: ApiResponse?) -> String { String(decoding: r?.body ?? [], as: UTF8.self) }

    @Test func sendsLabelledTestToOwnTokenOnly() async throws {
        let sender = FakeApnsSender()
        let (api, repo) = api(sender: sender)
        await install(api)
        _ = await api.handle(method: "PUT", path: "/v1/push/installations/\(installB)", secret: secretB,
                             body: json(["token": tokenB, "env": "production", "locale": "en"]))
        let response = try #require(await test(api))
        #expect(response.status == 200 && text(response) == #"{"environment":"sandbox","sent":true}"#)
        let sent = await sender.requests
        #expect(sent.count == 1 && sent[0].tokenHex == tokenA && sent[0].env == .sandbox && sent[0].topic == "de.example.app")
        let payload = String(decoding: sent[0].payload, as: UTF8.self)
        #expect(payload.contains("ShowerNow Testmeldung") && payload.contains(#""type":"test""#))
        #expect(!payload.contains("interruption-level") && !payload.contains("loc-key"))
        #expect(sent[0].expiration == Int(run0.addingTimeInterval(PushApi.testExpirySeconds).timeIntervalSince1970))
        // The test stores nothing: no subscription, no outbox entry.
        #expect(try await repo.subscriptions(installationID: installA).isEmpty)
        #expect(try await repo.dueOutbox(now: run0.addingTimeInterval(9999), limit: 10).isEmpty)
        // Second installation: English text and its own token/environment.
        _ = try #require(await test(api, id: installB, secret: secretB))
        let second = await sender.requests[1]
        #expect(second.tokenHex == tokenB && second.env == .production && String(decoding: second.payload, as: UTF8.self).contains("test notification"))
    }

    @Test func requiresAuthenticationAndPostAndPush() async {
        let sender = FakeApnsSender()
        let (api, _) = api(sender: sender)
        await install(api)
        #expect(await test(api, secret: nil)?.status == 401)
        #expect(await test(api, secret: secretB)?.status == 401)
        #expect(await test(api, id: installB, secret: secretA)?.status == 401)
        #expect(await test(api, method: "GET")?.status == 405)
        #expect(await api.handle(method: "POST", path: "/v1/push/installations/\(installA)/other", secret: secretA, body: []) == nil)
        #expect(await sender.requests.isEmpty)
        let (off, _) = self.api(sender: sender) { $0.push.enabled = false }
        #expect(await test(off) == nil)  // push inactive: 404 like every push route
    }

    @Test func rateLimitIsThreePerHourPerInstallation() async {
        let sender = FakeApnsSender()
        let now = Locked(run0)
        let (api, _) = api(sender: sender, clock: { now.withLock { $0 } })
        await install(api)
        _ = await api.handle(method: "PUT", path: "/v1/push/installations/\(installB)", secret: secretB,
                             body: json(["token": tokenB, "env": "sandbox", "locale": "de"]))
        for _ in 0..<3 { #expect(await test(api)?.status == 200) }
        let limited = await test(api)
        #expect(limited?.status == 429 && text(limited) == #"{"error":"test_rate_limited"}"#)
        #expect(limited?.headers.contains { $0.0 == "Retry-After" } == true)
        #expect(await test(api, id: installB, secret: secretB)?.status == 200)  // limit is per installation
        #expect(await sender.requests.count == 4)
        now.withLock { $0 = run0.addingTimeInterval(3601) }
        #expect(await test(api)?.status == 200)
    }

    @Test func environmentNotAllowedAndNoSenderGiveClearErrors() async {
        let sender = FakeApnsSender()
        let (production, _) = api(sender: sender) { $0.push.environments = [.production] }
        await install(production, env: "sandbox")
        let r = await test(production)
        #expect(r?.status == 409 && text(r) == #"{"error":"environment_not_allowed"}"#)
        #expect(await sender.requests.isEmpty)
        let (nokey, _) = api(sender: nil)
        await install(nokey)
        let r2 = await test(nokey)
        #expect(r2?.status == 503 && text(r2) == #"{"error":"apns_unavailable"}"#)
    }

    @Test func apnsErrorsAreMappedWithoutLeakingSecrets() async throws {
        let sender = FakeApnsSender(script: [.badToken("BadDeviceToken"), .retry("InvalidProviderToken"), .retry("503"),
                                             .rejected("400 PayloadTooLarge"), .unregistered])
        let now = Locked(run0)
        let (api, repo) = api(sender: sender, { $0.push.keyPEM = "-----BEGIN PRIVATE KEY-----SECRET"; $0.push.keyID = "KEYID12345" },
                              clock: { now.withLock { $0 } })
        await install(api)
        var bodies: [String] = []
        for _ in 0..<5 {
            bodies.append(text(await test(api)))
            now.withLock { $0 = $0.addingTimeInterval(3601) }  // stay below the hourly test limit
        }
        #expect(bodies[0].contains("apns_bad_device_token") && bodies[0].contains("BadDeviceToken"))
        #expect(bodies[1].contains("apns_key_rejected") && bodies[1].contains("InvalidProviderToken"))
        #expect(bodies[2].contains("apns_unavailable"))
        #expect(bodies[3].contains("apns_rejected"))
        #expect(bodies[4].contains("token_unregistered"))
        for body in bodies { #expect(!body.contains(tokenA) && !body.contains("SECRET") && !body.contains("KEYID12345")) }
        // Only 410 removes the installation (same behaviour as the normal sender).
        #expect(try await repo.installation(id: installA) == nil)
    }

    @Test func statusCodesOfFailedTests() async {
        let sender = FakeApnsSender(script: [.badToken("BadDeviceToken"), .unregistered], defaultResult: .delivered)
        let (api, _) = api(sender: sender)
        await install(api)
        #expect(await test(api)?.status == 502)
        #expect(await test(api)?.status == 410)
    }
}

@Suite("Push time sensitive")
struct PushTimeSensitiveTests {
    private func api() -> (PushApi, MemoryRepo) {
        let repo = MemoryRepo()
        return (PushApi(repo: repo, config: pushConfig(), clock: { run0 }), repo)
    }
    private func json(_ object: [String: Any]) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
    private func body(_ extra: [String: Any]) -> [UInt8] {
        var o: [String: Any] = ["grid_version": 1, "cell_x": 10, "cell_y": 20, "threshold": 3, "lead_minutes": 20]
        o.merge(extra) { $1 }
        return json(o)
    }

    @Test func defaultsToFalseAcceptsBoolAndRejectsOtherTypes() async throws {
        let (api, repo) = api()
        let base = "/v1/push/installations/\(installA)"
        _ = await api.handle(method: "PUT", path: base, secret: secretA, body: json(["token": tokenA, "env": "sandbox", "locale": "de"]))
        let plain = try #require(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body([:])))
        #expect(plain.status == 201)
        #expect(try await repo.subscriptions(installationID: installA).first?.timeSensitive == false)
        for bad in [["time_sensitive": "true"], ["time_sensitive": 1], ["time_sensitive": NSNull()] as [String: Any]] {
            let r = await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(bad))
            // JSON null is "absent" (false); strings and numbers are invalid.
            #expect(r?.status == (bad["time_sensitive"] is NSNull ? 201 : 400), "\(bad)")
        }
        let created = try #require(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(["time_sensitive": true])))
        let id = try #require((try JSONSerialization.jsonObject(with: Data(created.body)) as? [String: Any])?["id"] as? String)
        let list = try #require(await api.handle(method: "GET", path: base + "/subscriptions", secret: secretA, body: []))
        let items = try #require(try JSONSerialization.jsonObject(with: Data(list.body)) as? [[String: Any]])
        #expect(items.first { $0["id"] as? String == id }?["time_sensitive"] as? Bool == true)
        #expect(items.allSatisfy { $0["time_sensitive"] is Bool })
        // PUT replaces the fields: omitting the flag resets it to false.
        #expect(await api.handle(method: "PUT", path: base + "/subscriptions/\(id)", secret: secretA, body: body([:]))?.status == 204)
        #expect(try await repo.subscriptions(installationID: installA).first { $0.id == id }?.timeSensitive == false)
    }

    @Test func payloadCarriesInterruptionLevelOnlyWhenSet() throws {
        let plain = PushEvaluator.payload(minutes: 10, subscriptionID: "s")
        let urgent = PushEvaluator.payload(minutes: 10, subscriptionID: "s", timeSensitive: true)
        #expect(!plain.contains("interruption-level"))
        let aps = try #require((try JSONSerialization.jsonObject(with: Data(urgent.utf8)) as? [String: Any])?["aps"] as? [String: Any])
        #expect(aps["interruption-level"] as? String == "time-sensitive" && aps["thread-id"] as? String == "s")
        #expect(urgent.replacingOccurrences(of: #","interruption-level":"time-sensitive""#, with: "") == plain)
    }
}

@Suite("Push APNs environment per installation")
struct PushEnvironmentTests {
    @Test func bothEnvironmentsRouteEachInstallationToItsHost() async throws {
        let config = pushConfig { $0.push.environments = [.sandbox, .production] }
        let repo = MemoryRepo()
        try await register(repo, env: .sandbox)
        try await register(repo, id: installB, secret: secretB, token: tokenB, env: .production)
        let flagged = newID()
        for (install, sub) in [(installA, newID()), (installB, flagged)] {
            var i = input(x: 40, y: 50); i.timeSensitive = install == installB
            _ = try await repo.addSubscription(installationID: install, id: sub, i, maxPerInstallation: 10, now: run0)
        }
        // Deliver directly through the outbox: one item per installation.
        let subs = try await repo.evaluationSubscriptions(gridVersion: 1)
        let out = subs.map { NewOutboxItem(subID: $0.id, dedupeKey: "\($0.id):r", collapseID: $0.id,
                                           payloadJSON: PushEvaluator.payload(minutes: 5, subscriptionID: $0.id, timeSensitive: $0.timeSensitive),
                                           expiresAt: run0.addingTimeInterval(900)) }
        _ = try await repo.commitEvaluation(runID: "r", updates: [], outbox: out, now: run0)
        let sender = FakeApnsSender()
        let service = PushService(config: config, repo: repo, sender: sender, owner: "a", clock: { run0 })
        var tick = PushTick()
        try await service.dispatch(&tick)
        let sent = await sender.requests
        #expect(tick.sent == 2)
        #expect(Set(sent.map { "\($0.env.rawValue):\($0.tokenHex)" }) == ["sandbox:\(tokenA)", "production:\(tokenB)"])
        #expect(ApnsClient.host(.sandbox) == "https://api.sandbox.push.apple.com" && ApnsClient.host(.production) == "https://api.push.apple.com")
        let levels = sent.map { String(decoding: $0.payload, as: UTF8.self).contains("time-sensitive") }
        #expect(levels.filter { $0 }.count == 1)
    }

    @Test func rejectedReasonsAreCountedForOperators() async throws {
        let config = pushConfig()
        let repo = MemoryRepo()
        try await register(repo, env: .sandbox)
        let sub = newID()
        _ = try await repo.addSubscription(installationID: installA, id: sub, input(), maxPerInstallation: 10, now: run0)
        _ = try await repo.commitEvaluation(runID: "r", updates: [], outbox: [
            NewOutboxItem(subID: sub, dedupeKey: "k", collapseID: sub, payloadJSON: "{}", expiresAt: run0.addingTimeInterval(900))], now: run0)
        let service = PushService(config: config, repo: repo, sender: FakeApnsSender(script: [.badToken("BadDeviceToken")]), owner: "a", clock: { run0 })
        var tick = PushTick()
        try await service.dispatch(&tick)
        #expect(tick.dropped == 1 && tick.apnsReasons == ["BadDeviceToken": 1])
    }
}

// MARK: regions (circle around a coarse centre cell)

private func circle(x: Int = 40, y: Int = 50, radius: Int = 5, share: Int = 10, threshold: Int = 3) -> PushSubscriptionInput {
    PushSubscriptionInput(gridVersion: PushGrid.version, cellX: x, cellY: y, threshold: threshold, leadMinutes: 20, enabled: true,
                          kind: .circle, radiusCells: radius, minSharePercent: share)
}

@Suite("Push region geometry")
struct PushRegionGeometryTests {
    @Test func cellCountsGrowWithTheRadius() {
        #expect(PushRegion.cellCount(radius: 3) == 29)
        #expect(PushRegion.cellCount(radius: 7) == 149)
        // Within 1 % of pi * r^2 for the large presets.
        for r in [14, 36, 40] {
            let exact = Double.pi * Double(r * r)
            #expect(abs(Double(PushRegion.cellCount(radius: r)) - exact) / exact < 0.01, "r=\(r)")
        }
    }

    @Test func centreIsSnappedToTheMiddleOfItsThreeByThreeBlock() {
        #expect(PushRegion.snapCenter(x: 0, y: 0, width: 256, height: 327) == (1, 1))
        #expect(PushRegion.snapCenter(x: 2, y: 5, width: 256, height: 327) == (1, 4))
        #expect(PushRegion.snapCenter(x: 3, y: 3, width: 256, height: 327) == (4, 4))
        #expect(PushRegion.snapCenter(x: 255, y: 326, width: 256, height: 327).x <= 255)
        #expect(PushRegion.snapCenter(x: 255, y: 326, width: 256, height: 327).y <= 326)
        // A cell and its block neighbours land on the same centre: the stored centre is only about 2 km exact.
        #expect(PushRegion.snapCenter(x: 39, y: 50, width: 256, height: 327) == PushRegion.snapCenter(x: 41, y: 49, width: 256, height: 327))
    }

    @Test func triggerNeedsShareAndThreeCellsExceptInTinyRegions() {
        #expect(PushRegion.requiredWet(cells: 29, sharePercent: 25) == 1)
        #expect(PushRegion.requiredWet(cells: 81, sharePercent: 1) == 3)
        #expect(PushRegion.requiredWet(cells: 81, sharePercent: 10) == 9)
        #expect(PushRegion.requiredWet(cells: 81, sharePercent: 25) == 21)
        #expect(PushRegion.requiredWet(cells: 4_000, sharePercent: 1) == 40)
    }

    @Test func pseudoClassCountsOnlyCellsAtOrAboveTheThreshold() {
        let w = 64, h = 64
        var map = [UInt8](repeating: 0, count: w * h)
        func fill(_ n: Int, _ cls: UInt8) { for i in 0..<n { map[30 * w + 20 + i] = cls } }
        func value(_ share: Int = 10) -> Int {
            PushRegion.pseudoClass(classMap: map, width: w, height: h, cx: 24, cy: 30, radius: 5, threshold: 4, sharePercent: share)
        }
        fill(8, 4); #expect(value() == 0)               // 8 of 81 cells (need 9)
        fill(9, 4); #expect(value() == 4)               // 9 of 81
        map = [UInt8](repeating: 0, count: w * h); fill(9, 3); #expect(value() == 0)  // below the threshold class
        map = [UInt8](repeating: 0, count: w * h); fill(3, 7); #expect(value(1) == 4)  // 1 %: 3 cells are enough, class above threshold counts
        map = [UInt8](repeating: 0, count: w * h); fill(2, 7); #expect(value(1) == 0)  // single/double pixels never trigger
        // Clipped at the corner: only the cells inside the raster count, no crash.
        let corner = [UInt8](repeating: 9, count: w * h)
        #expect(PushRegion.pseudoClass(classMap: corner, width: w, height: h, cx: 0, cy: 0, radius: 40, threshold: 4, sharePercent: 25) == 4)
    }

    @Test func limitsAreCheckedFromRadiiOnly() {
        let limits = RegionLimits(maxCellsServerwide: 2_000_000)
        #expect(limits.violation(otherRadii: [], serverCells: 0, newRadius: 40) == nil)
        #expect(limits.violation(otherRadii: [40], serverCells: 0, newRadius: 40) == .perInstallation)  // 2 x 5026 > 8000
        #expect(limits.violation(otherRadii: [5, 5, 5], serverCells: 0, newRadius: 5) == .perInstallation)  // fourth region
        #expect(limits.violation(otherRadii: [], serverCells: 1_999_900, newRadius: 7) == .capacity)
    }
}

extension DatabaseSuites {
@Suite("Push region repo contract", .serialized)
struct PushRegionRepoTests {
    @Test(arguments: RepoKind.allCases)
    func regionFieldsRoundTripAndPointsStayPoints(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let point = newID(), region = newID()
        #expect(try await repo.addSubscription(installationID: installA, id: point, input(), maxPerInstallation: 10, now: run0) == .created)
        #expect(try await repo.addSubscription(installationID: installA, id: region, circle(radius: 14, share: 25), maxPerInstallation: 10, now: run0) == .created)
        let subs = try await repo.subscriptions(installationID: installA)
        let p = try #require(subs.first { $0.id == point }), r = try #require(subs.first { $0.id == region })
        #expect(p.kind == .point && p.radiusCells == nil && p.minSharePercent == nil)
        #expect(r.kind == .circle && r.radiusCells == 14 && r.minSharePercent == 25 && r.cellX == 40 && r.cellY == 50)
        #expect(try await repo.evaluationSubscriptions(gridVersion: PushGrid.version).count == 2)
        // A region can be turned into a point and back; the update re-arms it.
        #expect(try await repo.updateSubscription(installationID: installA, id: region, input()))
        #expect(try await repo.subscriptions(installationID: installA).first { $0.id == region }?.kind == .point)
        #expect(try await repo.updateSubscription(installationID: installA, id: region, circle(radius: 7, share: 1)))
        #expect(try await repo.subscriptions(installationID: installA).first { $0.id == region }?.radiusCells == 7)
    }

    @Test(arguments: RepoKind.allCases)
    func regionLimitsPerInstallationAndServerwide(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo); try await register(repo, id: installB, secret: secretB, token: tokenB)
        let limits = RegionLimits(maxRegionsPerInstallation: 3, maxCellsPerInstallation: 8_000, maxCellsServerwide: 400)
        let ids = (0..<4).map { _ in newID() }
        // 149 cells each (radius 7): A holds two (298), the third would exceed the server budget of 400.
        for id in ids[0..<2] { #expect(try await repo.addSubscription(installationID: installA, id: id, circle(radius: 7), maxPerInstallation: 10, regionLimits: limits, now: run0) == .created) }
        #expect(try await repo.addSubscription(installationID: installB, id: ids[2], circle(radius: 7), maxPerInstallation: 10, regionLimits: limits, now: run0) == .regionCapacity)
        #expect(try await repo.addSubscription(installationID: installB, id: ids[2], input(), maxPerInstallation: 10, regionLimits: limits, now: run0) == .created)  // points are not counted
        #expect(try await repo.subscriptions(installationID: installB).count == 1)
        // Per installation: A holds two radius-7 regions (298 cells); a radius-40 region (5026) still fits, a fourth region does not.
        let roomy = RegionLimits(maxRegionsPerInstallation: 3, maxCellsPerInstallation: 8_000, maxCellsServerwide: 2_000_000)
        #expect(try await repo.addSubscription(installationID: installA, id: ids[3], circle(radius: 40), maxPerInstallation: 10, regionLimits: roomy, now: run0) == .created)
        #expect(try await repo.addSubscription(installationID: installA, id: newID(), circle(radius: 7), maxPerInstallation: 10, regionLimits: roomy, now: run0) == .regionLimit)
        // Updating counts the other regions only: growing one past the cell budget throws, a small change does not.
        await #expect(throws: PushRegionLimitError.perInstallation) {
            _ = try await repo.updateSubscription(installationID: installA, id: ids[0], circle(radius: 40), regionLimits: roomy)
        }
        await #expect(throws: PushRegionLimitError.capacity) {
            _ = try await repo.updateSubscription(installationID: installA, id: ids[0], circle(radius: 14), regionLimits: limits)
        }
        #expect(try await repo.updateSubscription(installationID: installA, id: ids[0], circle(radius: 10, share: 25), regionLimits: roomy))
        // Deleting frees the budget.
        #expect(try await repo.deleteSubscription(installationID: installA, id: ids[3]))
        #expect(try await repo.addSubscription(installationID: installA, id: newID(), circle(radius: 7), maxPerInstallation: 10, regionLimits: roomy, now: run0) == .created)
    }
}
}

@Suite("Push region API")
struct PushRegionApiTests {
    private func api(_ edit: (inout Config) -> Void = { _ in }) -> (PushApi, MemoryRepo) {
        let repo = MemoryRepo()
        return (PushApi(repo: repo, config: pushConfig(edit), clock: { run0 }), repo)
    }
    private func json(_ object: [String: Any]) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
    private func body(_ extra: [String: Any] = [:]) -> [UInt8] {
        var o: [String: Any] = ["grid_version": 1, "cell_x": 40, "cell_y": 50, "threshold": 3, "lead_minutes": 20]
        o.merge(extra) { $1 }
        return json(o)
    }
    private let base = "/v1/push/installations/\(installA)"
    private func prepared() async -> (PushApi, MemoryRepo) {
        let (api, repo) = api()
        _ = await api.handle(method: "PUT", path: base, secret: secretA, body: json(["token": tokenA, "env": "sandbox", "locale": "de"]))
        return (api, repo)
    }

    @Test func circleIsStoredWithSnappedCentreAndDefaultShare() async throws {
        let (api, repo) = await prepared()
        let r = try #require(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA,
                                              body: body(["kind": "circle", "radius_cells": 14, "cell_x": 41, "cell_y": 52])))
        #expect(r.status == 201)
        let sub = try #require(try await repo.subscriptions(installationID: installA).first)
        #expect(sub.kind == .circle && sub.radiusCells == 14 && sub.minSharePercent == 10)
        #expect(sub.cellX == 40 && sub.cellY == 52)  // 41 -> block 39...41 -> centre 40; 52 -> block 51...53 -> centre 52
        let list = try #require(await api.handle(method: "GET", path: base + "/subscriptions", secret: secretA, body: []))
        let entry = try #require((try JSONSerialization.jsonObject(with: Data(list.body)) as? [[String: Any]])?.first)
        #expect(entry["kind"] as? String == "circle" && entry["radius_cells"] as? Int == 14 && entry["min_share_percent"] as? Int == 10)
    }

    @Test func subscriptionsWithoutNewFieldsStayPoints() async throws {
        let (api, repo) = await prepared()
        #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body())?.status == 201)
        let sub = try #require(try await repo.subscriptions(installationID: installA).first)
        #expect(sub.kind == .point && sub.cellX == 40 && sub.cellY == 50 && sub.radiusCells == nil)
        let list = try #require(await api.handle(method: "GET", path: base + "/subscriptions", secret: secretA, body: []))
        let entry = try #require((try JSONSerialization.jsonObject(with: Data(list.body)) as? [[String: Any]])?.first)
        #expect(entry["kind"] as? String == "point" && entry["radius_cells"] == nil && entry["min_share_percent"] == nil)
    }

    @Test func regionInputIsValidatedServerSide() async {
        let (api, _) = await prepared()
        let bad: [[String: Any]] = [
            ["kind": "circle"], ["kind": "circle", "radius_cells": 2], ["kind": "circle", "radius_cells": 41],
            ["kind": "circle", "radius_cells": 7, "min_share_percent": 5], ["kind": "circle", "radius_cells": "7"],
            ["kind": "polygon"], ["kind": "circle", "radius_cells": 7, "cell_x": -1],
            ["radius_cells": 7], ["kind": "point", "min_share_percent": 10], ["kind": 1],
            ["kind": "circle", "radius_cells": 7, "min_share_percent": 3],
        ]
        for extra in bad {
            #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(extra))?.status == 400, "\(extra)")
        }
        for (r, s) in [(3, 1), (7, 10), (14, 25)] {
            let ok = await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(["kind": "circle", "radius_cells": r, "min_share_percent": s]))
            #expect(ok?.status == 201 || r == 14, "r=\(r)")  // the fourth region of this installation would hit the limit
        }
    }

    @Test func limitsAnswer409WithDistinctCodes() async throws {
        let (api, _) = await prepared()
        func add(_ r: Int) async -> ApiResponse? {
            await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(["kind": "circle", "radius_cells": r]))
        }
        #expect(await add(40)?.status == 201)               // 5026 cells
        let second = try #require(await add(40))            // 10052 > 8000
        #expect(second.status == 409 && String(decoding: second.body, as: UTF8.self).contains("region_limit"))
        let tenA = await add(10), tenB = await add(10)
        #expect(tenA?.status == 201 && tenB?.status == 201)
        #expect(await add(3)?.status == 409)                // fourth region
        // Points are unaffected by the region limit.
        #expect(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body())?.status == 201)
    }

    @Test func updateEnforcesTheSameLimits() async throws {
        let (api, _) = await prepared()
        let a = try #require(await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(["kind": "circle", "radius_cells": 40])))
        _ = await api.handle(method: "POST", path: base + "/subscriptions", secret: secretA, body: body(["kind": "circle", "radius_cells": 20]))
        let id = try #require((try JSONSerialization.jsonObject(with: Data(a.body)) as? [String: Any])?["id"] as? String)
        // 40 + 40 would not fit next to the other region (1256 cells): 5026 + 1256 is fine, 2 x 5026 is not.
        #expect(await api.handle(method: "PUT", path: base + "/subscriptions/\(id)", secret: secretA, body: body(["kind": "circle", "radius_cells": 30]))?.status == 204)
        #expect(await api.handle(method: "PUT", path: base + "/subscriptions/\(id)", secret: secretA, body: body(["kind": "circle", "radius_cells": 40]))?.status == 204)
    }

    @Test func statusAnnouncesRegionCapabilityOnlyWithPush() async throws {
        for enabled in [true, false] {
            let config = pushConfig { $0.push.enabled = enabled }
            let res = try await Api(repo: MemoryRepo(), config: config).handle(path: "/v1/status", ifNoneMatch: nil)
            let doc = try #require(try JSONSerialization.jsonObject(with: Data(res.body)) as? [String: Any])
            #expect(doc["capabilities"] as? [String] == (enabled ? ["regions"] : []))
        }
    }
}

@Suite("Push region evaluation")
struct PushRegionServiceTests {
    static let center = (x: 40, y: 50)

    /// Publishes a run whose slots from `onset` on contain `wet` coloured cells (class 3) in a row inside the 5-cell circle.
    private func publish(_ repo: any Repo, _ config: Config, nominal: Date, onset: Int?, wet: Int) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        let color = PushIntensity.palette[2]
        for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
            var image = makeImage(width: config.width, height: config.height, seed: 200 + index)
            if let onset, index >= onset {
                var pixels = image.pixels
                for i in 0..<wet {
                    let o = (Self.center.y * config.width + Self.center.x - 4 + i) * 4
                    pixels[o] = UInt8(color.r); pixels[o + 1] = UInt8(color.g); pixels[o + 2] = UInt8(color.b); pixels[o + 3] = 255
                }
                image = RGBAImage(width: image.width, height: image.height, pixels: pixels)
            }
            try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot),
                                   contentType: "image/webp", data: try ImagePipeline.toWebP(image))
        }
        #expect(try await repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
    }

    private func run(share: Int, wet: Int, locale: String = "de") async throws -> (sent: [ApnsRequest], state: PushState?) {
        let config = pushConfig()
        let repo = MemoryRepo()
        try await register(repo)
        _ = try await repo.addSubscription(installationID: installA, id: newID(), circle(x: Self.center.x, y: Self.center.y, radius: 5, share: share), maxPerInstallation: 10, now: run0)
        let sender = FakeApnsSender()
        let now = Locked(run0.addingTimeInterval(240))
        let service = PushService(config: config, repo: repo, sender: sender, owner: "a", clock: { now.withLock { $0 } })
        try await publish(repo, config, nominal: run0, onset: 3, wet: wet)
        _ = try await service.tick()
        let run1 = run0.addingTimeInterval(300)
        now.withLock { $0 = run1.addingTimeInterval(240) }
        try await publish(repo, config, nominal: run1, onset: 2, wet: wet)
        _ = try await service.tick()
        return (await sender.requests, try await repo.subscriptions(installationID: installA).first?.state)
    }

    @Test func regionNotifiesWhenTheWetShareIsReachedAfterTwoRuns() async throws {
        let result = try await run(share: 10, wet: 9)  // 9 of 81 cells = 11 %
        #expect(result.sent.count == 1)
        let payload = String(decoding: result.sent[0].payload, as: UTF8.self)
        #expect(payload.contains("RAIN_REGION_STARTS_IN") && payload.contains(#""loc-args":["10"]"#) && payload.contains(#""region":true"#))
        #expect(result.state == .notified)
    }

    @Test func tooFewWetCellsNeverNotify() async throws {
        let result = try await run(share: 10, wet: 8)  // 8 of 81 cells < 10 %
        #expect(result.sent.isEmpty && result.state == .dry)
        let tiny = try await run(share: 1, wet: 2)     // below the three-cell minimum
        #expect(tiny.sent.isEmpty)
        let lowShare = try await run(share: 1, wet: 3)
        #expect(lowShare.sent.count == 1)
    }

    @Test func regionPayloadHasNoPlaceOrCoordinates() throws {
        let text = PushEvaluator.payload(minutes: 15, subscriptionID: installA, timeSensitive: true, region: true)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["aps", "type", "minutes", "region"])
        #expect(!text.contains("lat") && !text.contains("lon") && !text.contains("cell"))
        #expect(PushEvaluator.payload(minutes: 15, subscriptionID: installA).contains("RAIN_STARTS_IN"))  // unchanged for places
    }
}

// MARK: benchmark of the region evaluation (opt-in: RADAR_BENCH=1; prints timings, asserts only a generous bound)

@Suite("Push region benchmark")
struct PushRegionBenchmark {
    /// Full-size synthetic radar image: smooth rain blobs in legend colours on a transparent background, `wetShare` of the pixels covered.
    private func image(seed: Int, wetShare: Double) -> RGBAImage {
        let w = PushGrid.width, h = RadarConstants.imageHeight(width: w)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        func rnd() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 33) / Double(1 << 31) }
        var covered = 0
        let target = Int(Double(w * h) * wetShare)
        while covered < target {
            let cx = Int(rnd() * Double(w)), cy = Int(rnd() * Double(h)), r = 10 + Int(rnd() * 60)
            let level = Int(rnd() * 15)
            for y in max(0, cy - r)..<min(h, cy + r) {
                for x in max(0, cx - r)..<min(w, cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                    let c = PushIntensity.palette[max(0, level - (abs(x - cx) + abs(y - cy)) / 25)]
                    let o = (y * w + x) * 4
                    if pixels[o + 3] == 0 { covered += 1 }
                    pixels[o] = UInt8(c.r); pixels[o + 1] = UInt8(c.g); pixels[o + 2] = UInt8(c.b); pixels[o + 3] = 255
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RADAR_BENCH"] != nil))
    func evaluationCostForTheLimits() throws {
        let w = PushGrid.width, h = RadarConstants.imageHeight(width: w)
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        let img = image(seed: 1, wetShare: 0.15)
        let webp = try ImagePipeline.toWebP(img)
        var decodeTime = 0.0, mapTime = 0.0
        var map: [UInt8] = []
        decodeTime = seconds(try clock.measure { _ = try ImagePipeline.decodeWebP(webp) })
        mapTime = seconds(clock.measure { map = PushIntensity.classMap(img) })
        var out = "bench: webp \(webp.count / 1024) KB, decode \(Int(decodeTime * 1000)) ms, classMap \(Int(mapTime * 1000)) ms per slot\n"
        // Scenarios at the server-wide budget (2 Mio. cells), thresholds 1 (many wet) and 12 (nearly dry = worst case: no early exit).
        for (name, radius, count) in [("r40 x400", 40, 400), ("r14 x3260", 14, 3260), ("r7 x13400", 7, 13_400)] {
            var rng = SystemRandomNumberGenerator()
            let centres = (0..<count).map { _ in (Int.random(in: 0..<w, using: &rng), Int.random(in: 0..<h, using: &rng)) }
            for threshold in [1, 12] {
                var wet = 0
                let t = seconds(clock.measure {
                    for c in centres where PushRegion.pseudoClass(classMap: map, width: w, height: h, cx: c.0, cy: c.1, radius: radius,
                                                                   threshold: threshold, sharePercent: 10) > 0 { wet += 1 }
                })
                out += "bench: \(name) threshold \(threshold): \(Int(t * 1000)) ms per slot, x25 = \(Int(t * 25 * 1000)) ms, wet regions \(wet)\n"
                #expect(t * 25 < 30)
            }
        }
        out += "bench: fixed part per run = 25 x (decode + classMap) = \(Int(25 * (decodeTime + mapTime) * 1000)) ms\n"
        print(out)
    }
}
