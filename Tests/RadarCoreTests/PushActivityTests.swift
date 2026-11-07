import Crypto
import Foundation
import Testing
@testable import RadarCore

// Synthetic identifiers, raster cell and tokens only. No APNs/DWD/network access.
private enum ActivityFixture {
    static let installation = "11111111-1111-4111-8111-111111111111"
    static let subscription = "33333333-3333-4333-8333-333333333333"
    static let otherSubscription = "44444444-4444-4444-8444-444444444444"
    static let secret = String(repeating: "a", count: 40)
    static let device = String(repeating: "ab", count: 32)
    static let start = String(repeating: "cd", count: 32)
    static let activity = String(repeating: "ef", count: 32)
    static let rotated = String(repeating: "12", count: 32)
    static let base = "/v1/push/installations/" + installation
    static let route = "/v1/push/subscriptions/" + subscription + "/activity"

    static func config() -> Config {
        smallConfig {
            $0.width = 64
            $0.push.enabled = true
            $0.push.topic = "de.example.app"
            $0.push.environments = [.sandbox, .production]
        }
    }
    static func input(live: Bool = true, kind: PushKind = .point, enabled: Bool = true) -> PushSubscriptionInput {
        .init(gridVersion: 1, cellX: 10, cellY: 20, threshold: 3, leadMinutes: 20, enabled: enabled,
              kind: kind, radiusCells: kind == .circle ? 3 : nil, minSharePercent: kind == .circle ? 10 : nil, liveActivity: live)
    }
    static func json(_ value: Any) throws -> [UInt8] { Array(try JSONSerialization.data(withJSONObject: value)) }
    static func object(_ bytes: [UInt8]) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
    }
    static func aps(_ request: ApnsRequest) throws -> [String: Any] {
        try #require(try object(request.payload)["aps"] as? [String: Any])
    }
    static func body(_ extra: [String: Any] = [:]) throws -> [UInt8] {
        var value: [String: Any] = ["grid_version": 1, "cell_x": 10, "cell_y": 20, "threshold": 3, "lead_minutes": 20]
        value.merge(extra) { _, new in new }
        return try json(value)
    }
    /// `armed: false` simulates a subscription that was activated long ago (no immediate start pending).
    static func prepared(env: PushEnvironment = .sandbox, live: Bool = true, armed: Bool = false) async throws -> MemoryRepo {
        let repo = MemoryRepo(clock: { run0 })
        _ = try await repo.upsertInstallation(id: installation, secretHash: Hashing.sha256Hex(Array(secret.utf8)),
                                             token: device, env: env, locale: "de", now: run0)
        try await repo.setLiveActivityStartToken(installationID: installation, token: start)
        #expect(try await repo.addSubscription(installationID: installation, id: subscription, input(live: live),
                                              maxPerInstallation: 10, now: run0) == .created)
        if !armed { try await repo.setStartRetry(subscriptionID: subscription, armed: false, attempts: 0) }
        return repo
    }
    static func target(_ repo: MemoryRepo) async throws -> PushActivityTarget {
        try #require(try await repo.activityTarget(subscriptionID: subscription))
    }
    static func wet(onset: Int = 2) -> [Int] {
        (0..<TimeUtil.forecastSlots).map { $0 >= onset ? 3 : 0 }
    }
    static func publish(_ repo: MemoryRepo, config: Config, at date: Date, classes: [Int]) async throws {
        let id = TimeUtil.toID(date)
        #expect(try await repo.tryClaim(runID: id, nominal: date, owner: "fixture", leaseSeconds: 60, maxAttempts: 2))
        for (index, slot) in TimeUtil.slots(of: date).enumerated() {
            var pixels = [UInt8](repeating: 0, count: config.width * config.height * 4)
            if classes[index] < 0 {
                // "No data" mask colour: classifies as unknown.
                let offset = (20 * config.width + 10) * 4
                pixels[offset] = 0x7D; pixels[offset + 1] = 0x7D; pixels[offset + 2] = 0x7D; pixels[offset + 3] = 76
            } else if classes[index] > 0 {
                let color = PushIntensity.palette[classes[index] - 1]
                let offset = (20 * config.width + 10) * 4
                pixels[offset] = UInt8(color.r); pixels[offset + 1] = UInt8(color.g)
                pixels[offset + 2] = UInt8(color.b); pixels[offset + 3] = 255
            }
            let image = RGBAImage(width: config.width, height: config.height, pixels: pixels)
            try await repo.putSlot(.init(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot),
                                   contentType: "image/webp", data: cachedWebP(image))
        }
        #expect(try await repo.publish(runID: id, owner: "fixture", expectedSlots: TimeUtil.forecastSlots))
    }
}

@Suite("Live Activity lifecycle with fake sender")
struct PushActivityLifecycleTests {
    private typealias F = ActivityFixture

    @Test func realRunLeavesATraceWithTheReasonOfEachDecision() async throws {
        let repo = try await F.prepared()           // activated long ago: no immediate start pending
        let sender = FakeApnsSender()
        let now = Locked(run0)
        let config = F.config()
        let service = PushService(config: config, repo: repo, sender: sender, owner: "trace-test", clock: { now.withLock { $0 } })
        func run(_ index: Int, _ classes: [Int]) async throws -> EvalTrace? {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await F.publish(repo, config: config, at: date, classes: classes)
            _ = try await service.tick()
            return try await repo.subscriptions(installationID: F.installation).first?.trace
        }
        let dry = [Int](repeating: 0, count: TimeUtil.forecastSlots)
        var trace = try await run(0, dry)
        #expect(trace?.reason == "dry" && trace?.cls == 0 && trace?.run == TimeUtil.toID(run0))
        trace = try await run(1, dry.enumerated().map { $0.offset == 0 ? 2 : 0 })       // rain below the threshold class 3
        #expect(trace?.reason == "below_threshold" && trace?.cls == 2)
        trace = try await run(2, F.wet(onset: 0))                                         // first wet run: hysteresis, no start
        #expect(trace?.reason == "hysteresis" && trace?.cls == 3)
        #expect(await sender.requests.isEmpty)
        let sub = try #require(try await repo.subscriptions(installationID: F.installation).first)
        #expect(sub.wetSeen && sub.state == .dry)       // the automaton stays "dry" while it rains: this is not "no rain"
        trace = try await run(3, F.wet(onset: 0))                                         // second wet run: start
        #expect(trace?.reason == "started_now")
        #expect(await sender.requests.contains { $0.activityEvent == .start })
        // Unchanged result writes nothing new: the run of the trace is the run in which the reason last changed.
        trace = try await run(4, F.wet(onset: 0))
        #expect(trace?.run == TimeUtil.toID(run0.addingTimeInterval(1200)) || trace?.reason == "activity_running")
    }

    @Test func committedRunsStartUpdateEndAndPreserveRepeatLock() async throws {
        let repo = try await F.prepared()
        let sender = FakeApnsSender()
        let now = Locked(run0)
        let config = F.config()
        let service = PushService(config: config, repo: repo, sender: sender, owner: "activity-test", clock: { now.withLock { $0 } })
        func tick(_ index: Int, _ classes: [Int]) async throws {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await F.publish(repo, config: config, at: date, classes: classes)
            _ = try await service.tick()
        }
        try await tick(0, F.wet(onset: 3))
        #expect(await sender.requests.isEmpty) // first run only arms the existing rule
        try await tick(1, F.wet())
        var requests = await sender.requests
        #expect(requests.filter { $0.activityEvent == .start }.count == 1)
        #expect(requests.filter { $0.activityEvent == nil }.count == 1) // ordinary alert still sent
        let start = try #require(requests.first { $0.activityEvent == .start })
        #expect(start.tokenHex == F.start && start.env == .sandbox)
        #expect(try F.aps(start)["event"] as? String == "start")
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity,
                                               now: run0.addingTimeInterval(300)) == .updated)
        let deadline = try await F.target(repo).activity?.endsAt
        _ = try await service.tick() // same run must not send another start or update
        #expect(await sender.requests.count == requests.count)
        try await tick(2, F.wet(onset: 0))
        requests = await sender.requests
        let update = try #require(requests.last { $0.activityEvent == .update })
        #expect(update.tokenHex == F.activity)
        let updateContent = try #require(try F.aps(update)["content-state"] as? [String: Any])
        #expect(updateContent["phase"] as? String == "raining")
        try await tick(3, [Int](repeating: 0, count: TimeUtil.forecastSlots))
        #expect(try await F.target(repo).activity == nil)
        let end = try #require(await sender.requests.last { $0.activityEvent == .end })
        #expect(try F.aps(end)["dismissal-date"] as? Int == Int(run0.addingTimeInterval(900).timeIntervalSince1970))
        try await tick(4, F.wet())
        try await tick(5, F.wet()) // two wet forecasts within 60 min cannot start again
        requests = await sender.requests
        #expect(requests.filter { $0.activityEvent == .start }.count == 1)
        #expect(requests.filter { $0.activityEvent == nil }.count == 1)
        #expect(deadline == run0.addingTimeInterval(300 + 8 * 3600))
    }

    @Test func eightHourEndWithoutNewRadarRunAndRotationDoesNotExtendDeadline() async throws {
        let repo = try await F.prepared(env: .production)
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .updated)
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.rotated, now: run0.addingTimeInterval(3600)) == .updated)
        let activity = try #require(try await F.target(repo).activity)
        #expect(activity.startedAt == run0 && activity.endsAt == run0.addingTimeInterval(8 * 3600))
        let sender = FakeApnsSender()
        let now = Locked(activity.endsAt.addingTimeInterval(-1))
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "expiry", clock: { now.withLock { $0 } })
        _ = try await service.tick()
        #expect(await sender.requests.isEmpty)
        now.withLock { $0 = activity.endsAt }
        _ = try await service.tick()
        let end = try #require(await sender.requests.first)
        #expect(end.activityEvent == .end && end.tokenHex == F.rotated && end.env == .production)
        #expect(try await F.target(repo).activity == nil)
        _ = try await service.tick()
        #expect(await sender.requests.count == 1)
    }

    @Test func activity410DeletesOnlyActivityToken() async throws {
        let repo = try await F.prepared()
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        let sender = FakeApnsSender(script: [.unregistered])
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "410", clock: { run0 })
        let target = try await F.target(repo)
        var result = PushTick()
        try await service.evaluateActivity(sub: target.subscription, classes: F.wet(), notify: false, reference: run0, now: run0, result: &result)
        #expect(result.unregistered == 1)
        #expect(try await F.target(repo).activity == nil)
        let installation = try #require(try await repo.installation(id: F.installation))
        #expect(installation.token == F.device && installation.liveActivityStartToken == F.start)
    }

    @Test func start410ClearsStartTokenAndReservationOnly() async throws {
        let repo = try await F.prepared()
        let sender = FakeApnsSender(script: [.unregistered])
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "410-start", clock: { run0 })
        let target = try await F.target(repo)
        var result = PushTick()
        try await service.evaluateActivity(sub: target.subscription, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        #expect(result.unregistered == 1)
        #expect(try await F.target(repo).activity == nil)
        let installation = try #require(try await repo.installation(id: F.installation))
        #expect(installation.token == F.device && installation.liveActivityStartToken == nil)
    }

    @Test func late410CannotEraseRotatedTokens() async throws {
        let repo = try await F.prepared()
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        let old = try await F.target(repo)
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.rotated, now: run0)
        try await repo.setLiveActivityStartToken(installationID: F.installation, token: F.rotated)
        try await repo.clearLiveActivityStartToken(installationID: F.installation, matchingToken: F.start)
        let sender = FakeApnsSender(script: [.unregistered])
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "rotation", clock: { run0 })
        var result = PushTick()
        try await service.sendActivity(target: old, event: .update, content: PushActivityPayload.content(classes: F.wet(), threshold: 3, reference: run0), now: run0, result: &result)
        #expect(try await F.target(repo).activity?.activityToken == F.rotated)
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == F.rotated)
    }

    @Test func ambiguousStartIsReservedAndEndRetriesOnNextTick() async throws {
        let repo = try await F.prepared()
        let sender = FakeApnsSender(script: [.retry("synthetic"), .retry("synthetic"), .delivered])
        let now = Locked(run0)
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "retry", clock: { now.withLock { $0 } })
        var result = PushTick()
        let sub = try await F.target(repo).subscription
        try await service.evaluateActivity(sub: sub, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        try await service.evaluateActivity(sub: sub, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        #expect(await sender.requests.count == 1) // pending token prevents duplicate push-to-start
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        now.withLock { $0 = run0.addingTimeInterval(8 * 3600) }
        _ = try await service.tick()
        #expect(try await F.target(repo).activity != nil)
        _ = try await service.tick()
        #expect(try await F.target(repo).activity == nil)
        #expect(await sender.requests.map(\.activityEvent) == [.start, .end, .end])
    }
}

@Suite("Live Activity repository invariants")
struct PushActivityRepositoryTests {
    private typealias F = ActivityFixture

    @Test func pendingAndRegisteredActivitiesShareOneInstallationSlot() async throws {
        let repo = try await F.prepared()
        _ = try await repo.addSubscription(installationID: F.installation, id: F.otherSubscription, F.input(), maxPerInstallation: 10, now: run0)
        #expect(try await repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        #expect(try await !repo.reserveActivity(subscriptionID: F.otherSubscription, now: run0))
        #expect(try await repo.setActivityToken(subscriptionID: F.otherSubscription, token: F.activity, now: run0) == .activityLimit)
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .updated)
        #expect(try await repo.setActivityToken(subscriptionID: F.otherSubscription, token: F.rotated, now: run0) == .activityLimit)
        #expect(try await !repo.deleteActivity(subscriptionID: F.subscription, matchingToken: F.rotated))
        #expect(try await repo.deleteActivity(subscriptionID: F.subscription, matchingToken: F.activity))
        #expect(try await repo.setActivityToken(subscriptionID: F.otherSubscription, token: F.rotated, now: run0) == .updated)
    }

    @Test func concurrentReservationsProduceExactlyOneWinner() async throws {
        let repo = try await F.prepared()
        _ = try await repo.addSubscription(installationID: F.installation, id: F.otherSubscription, F.input(), maxPerInstallation: 10, now: run0)
        async let first = repo.reserveActivity(subscriptionID: F.subscription, now: run0)
        async let second = repo.reserveActivity(subscriptionID: F.otherSubscription, now: run0)
        let (firstResult, secondResult) = try await (first, second)
        #expect([firstResult, secondResult].filter { $0 }.count == 1)
    }

    @Test func ineligibleSubscriptionsAndExpiredActivityCannotRegister() async throws {
        let repo = try await F.prepared(live: false)
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .notEligible)
        #expect(try await !repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        // Circles are eligible as soon as they opt in (decision 7 Nov 2026); without the opt-in they are not.
        #expect(try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input(live: false, kind: .circle)))
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .notEligible)
        #expect(try await !repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        #expect(try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input(enabled: false)))
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .notEligible)
        #expect(try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input()))
        #expect(try await repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0.addingTimeInterval(8 * 3600)) == .notEligible)
    }

    @Test func subscriptionAndInstallationDeletionCascadeToActivity() async throws {
        let repo = try await F.prepared()
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        #expect(try await repo.deleteSubscription(installationID: F.installation, id: F.subscription))
        #expect(try await repo.activityTargets(subscriptionIDs: [F.subscription]).isEmpty)
        _ = try await repo.addSubscription(installationID: F.installation, id: F.subscription, F.input(), maxPerInstallation: 10, now: run0)
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.rotated, now: run0)
        try await repo.deleteInstallation(id: F.installation)
        #expect(try await repo.installation(id: F.installation) == nil)
        #expect(try await repo.activityTargets(subscriptionIDs: [F.subscription]).isEmpty)
    }

    @Test func optingOutEndsOnNextTick() async throws {
        let repo = try await F.prepared()
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        _ = try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input(live: false))
        let sender = FakeApnsSender()
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "opt-out", clock: { run0 })
        _ = try await service.tick()
        #expect(await sender.requests.map(\.activityEvent) == [.end])
        #expect(try await F.target(repo).activity == nil)
    }
}

@Suite("Live Activity API compatibility and validation")
struct PushActivityApiTests {
    private typealias F = ActivityFixture

    @Test func installationTokenOmissionNullRotationAndValidation() async throws {
        let repo = MemoryRepo(clock: { run0 })
        let api = PushApi(repo: repo, config: F.config(), clock: { run0 })
        func put(_ extra: [String: Any] = [:], secret: String = F.secret) async throws -> ApiResponse {
            var body: [String: Any] = ["token": F.device, "env": "sandbox", "locale": "de"]
            body.merge(extra) { _, new in new }
            return try #require(await api.handle(method: "PUT", path: F.base, secret: secret, body: try F.json(body)))
        }
        #expect(try await put().status == 201) // unchanged old registration body
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == nil)
        #expect(try await put(["live_activity_start_token": F.start.uppercased()]).status == 204)
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == F.start)
        #expect(try await put().status == 204) // old app update preserves the optional token
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == F.start)
        #expect(try await put(["live_activity_start_token": F.rotated]).status == 204)
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == F.rotated)
        #expect(try await put(["live_activity_start_token": F.start], secret: String(repeating: "b", count: 40)).status == 401)
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == F.rotated)
        let invalidTokens: [Any] = ["", "not-hex", String(repeating: "a", count: 33), String(repeating: "ab", count: 101), 123, true]
        for invalid in invalidTokens {
            #expect(try await put(["live_activity_start_token": invalid]).status == 400)
        }
        #expect(try await put(["live_activity_start_token": NSNull()]).status == 204)
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == nil)
    }

    @Test func defaultFalseRoundTripReplacementAndPointOnlyValidation() async throws {
        let repo = try await F.prepared(live: false)
        let api = PushApi(repo: repo, config: F.config(), clock: { run0 })
        let path = F.base + "/subscriptions/" + F.subscription
        func put(_ extra: [String: Any] = [:]) async throws -> ApiResponse {
            try #require(await api.handle(method: "PUT", path: path, secret: F.secret, body: try F.body(extra)))
        }
        #expect(F.input(live: false).liveActivity == false)
        let oldInput = PushSubscriptionInput(gridVersion: 1, cellX: 10, cellY: 20, threshold: 3, leadMinutes: 20, enabled: true)
        #expect(oldInput.liveActivity == false)
        let oldSub = PushSubscription(id: F.subscription, gridVersion: 1, cellX: 10, cellY: 20, threshold: 3, leadMinutes: 20, enabled: true)
        #expect(oldSub.liveActivity == false)
        #expect(try await put(["live_activity": true]).status == 204)
        #expect(try await F.target(repo).subscription.liveActivity)
        let response = try #require(await api.handle(method: "GET", path: F.base + "/subscriptions", secret: F.secret, body: []))
        let list = try #require(try JSONSerialization.jsonObject(with: Data(response.body)) as? [[String: Any]])
        #expect(list.first?["live_activity"] as? Bool == true)
        #expect(!String(decoding: response.body, as: UTF8.self).contains(F.start))
        #expect(try await put().status == 204)
        #expect(try await F.target(repo).subscription.liveActivity == false)
        #expect(try await put(["live_activity": NSNull()]).status == 204)
        let invalidFlags: [Any] = ["true", 1, [true]]
        for invalid in invalidFlags {
            #expect(try await put(["live_activity": invalid]).status == 400)
        }
        // Circle + live_activity is valid since the capability `live_activity_regions` (7 Nov 2026); it still needs the start token.
        let region: [String: Any] = ["kind": "circle", "radius_cells": 3, "live_activity": true]
        #expect(try await put(region).status == 204)
        #expect(await api.handle(method: "POST", path: F.base + "/subscriptions", secret: F.secret, body: try F.body(region))?.status == 201)
        #expect(try await put(["kind": "circle", "radius_cells": 3, "live_activity": "yes"]).status == 400)
        #expect(try await put(["kind": "circle", "radius_cells": 3]).status == 204) // old region requests work
    }

    @Test func subscriptionCreationDefaultsFalseAndAcceptsExplicitOptIn() async throws {
        let repo = try await F.prepared(live: false)
        let api = PushApi(repo: repo, config: F.config(), clock: { run0 })
        let variants: [([String: Any], Bool)] = [([:], false), (["live_activity": true], true), (["live_activity": NSNull()], false)]
        for (fields, expected) in variants {
            let response = try #require(await api.handle(method: "POST", path: F.base + "/subscriptions", secret: F.secret, body: try F.body(fields)))
            #expect(response.status == 201)
            let id = try #require(try F.object(response.body)["id"] as? String)
            let target = try #require(try await repo.activityTarget(subscriptionID: id))
            #expect(target.subscription.liveActivity == expected && target.subscription.kind == .point)
        }
        // Valid boundaries normalize to lowercase, just like the existing installation device token.
        for count in [32, 200] {
            let token = String(repeating: "A", count: count)
            #expect(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: try F.json(["activity_token": token]))?.status == 409) // opted out
        }
        _ = try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input())
        for count in [32, 200] {
            let token = String(repeating: "A", count: count)
            #expect(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: try F.json(["activity_token": token]))?.status == 204)
            #expect(try await F.target(repo).activity?.activityToken == token.lowercased())
        }
    }

    @Test func activityEndpointRotatesMatchesDeleteAndEnforcesOwnerAndLimit() async throws {
        let repo = try await F.prepared()
        _ = try await repo.addSubscription(installationID: F.installation, id: F.otherSubscription, F.input(), maxPerInstallation: 10, now: run0)
        let api = PushApi(repo: repo, config: F.config(), clock: { run0 })
        func request(_ method: String, token: String, path: String = F.route, secret: String? = F.secret) async throws -> ApiResponse {
            try #require(await api.handle(method: method, path: path, secret: secret, body: try F.json(["activity_token": token])))
        }
        #expect(try await request("PUT", token: F.activity, secret: nil).status == 401)
        #expect(try await request("PUT", token: F.activity).status == 204)
        let first = try #require(try await F.target(repo).activity)
        #expect(try await request("PUT", token: F.rotated).status == 204)
        let rotated = try #require(try await F.target(repo).activity)
        #expect(rotated.activityToken == F.rotated && rotated.endsAt == first.endsAt && rotated.startedAt == first.startedAt)
        let other = "/v1/push/subscriptions/" + F.otherSubscription + "/activity"
        let limited = try await request("PUT", token: F.activity, path: other)
        #expect(limited.status == 409)
        #expect(try F.object(limited.body)["error"] as? String == "activity_limit")
        #expect(try await request("DELETE", token: F.activity).status == 204) // old token cannot delete rotation
        #expect(try await F.target(repo).activity?.activityToken == F.rotated)
        #expect(try await request("DELETE", token: F.rotated).status == 204)
        #expect(try await F.target(repo).activity == nil)
        #expect(try await request("PUT", token: F.activity, path: other).status == 204)
        #expect(try await request("POST", token: F.activity).status == 405)
        // A different valid installation cannot operate on this subscription through the nested form.
        let foreign = "22222222-2222-4222-8222-222222222222"
        _ = try await repo.upsertInstallation(id: foreign, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
        let nested = "/v1/push/installations/" + foreign + "/subscriptions/" + F.subscription + "/activity"
        #expect(try await request("PUT", token: F.activity, path: nested).status == 404)
    }

    @Test func activityEndpointValidatesTokensBodiesEligibilityAndRate() async throws {
        let repo = try await F.prepared()
        let api = PushApi(repo: repo, config: F.config(), clock: { run0 })
        let invalidTokens: [Any] = ["", String(repeating: "a", count: 31), String(repeating: "ab", count: 101), "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", true, NSNull()]
        for value in invalidTokens {
            #expect(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: try F.json(["activity_token": value]))?.status == 400)
        }
        #expect(await api.handle(method: "DELETE", path: F.route, secret: F.secret, body: [])?.status == 204) // no token: only frees a reservation (A7)
        #expect(await api.handle(method: "DELETE", path: F.route, secret: F.secret, body: try F.json(["activity_token": NSNull()]))?.status == 400)
        #expect(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: [UInt8](repeating: 0, count: 2049))?.status == 413)
        _ = try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input(live: false))
        let notEligible = try #require(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: try F.json(["activity_token": F.activity])))
        #expect(notEligible.status == 409)
        #expect(try F.object(notEligible.body)["error"] as? String == "activity_not_eligible")
        let limitedApi = PushApi(repo: repo, config: F.config(), clock: { run0 })
        for _ in 0..<PushApi.perInstallationLimit {
            #expect(await limitedApi.handle(method: "DELETE", path: F.route, secret: F.secret, body: try F.json(["activity_token": F.activity]))?.status == 204)
        }
        #expect(await limitedApi.handle(method: "DELETE", path: F.route, secret: F.secret, body: try F.json(["activity_token": F.activity]))?.status == 429)
        var disabled = F.config(); disabled.push.enabled = false
        #expect(await PushApi(repo: repo, config: disabled).handle(method: "PUT", path: F.route, secret: F.secret, body: []) == nil)
    }

    @Test func capabilitiesOnlyAdvertisedWhenPushEnabled() async throws {
        for enabled in [false, true] {
            var config = F.config(); config.push.enabled = enabled
            let response = try await Api(repo: MemoryRepo(), config: config).handle(path: "/v1/status", ifNoneMatch: nil)
            let capabilities = try #require(try F.object(response.body)["capabilities"] as? [String])
            #expect(capabilities == (enabled ? ["regions", "live_activity", "live_activity_regions"] : []))
        }
    }
}

@Suite("Live Activity APNs wire contract")
struct PushActivityWireTests {
    private typealias F = ActivityFixture
    private struct Transport: ApnsTransport {
        let status: Int
        func perform(_ request: ApnsHTTPRequest) async throws -> ApnsHTTPResponse {
            .init(status: status, body: status == 410 ? Array("{\"reason\":\"Unregistered\"}".utf8) : [])
        }
    }
    private func client(status: Int = 200) throws -> ApnsClient {
        try ApnsClient(keyPEM: P256.Signing.PrivateKey().pemRepresentation, keyID: "ABCDE12345", teamID: "TEAM123456",
                       topic: "de.example.app", transport: Transport(status: status), clock: { run0 })
    }

    @Test func eventHeadersUseDedicatedTopicTypePriorityAndEnvironment() async throws {
        let client = try client()
        for env in PushEnvironment.allCases {
            for event in [PushActivityEvent.start, .update, .end] {
                let request = ApnsRequest(tokenHex: F.activity, env: env, topic: "de.example.app", payload: [],
                                          collapseID: "activity-" + F.subscription, expiration: 1_800_000_000, activityEvent: event)
                let http = client.httpRequest(request, jwt: "synthetic")
                let headers = Dictionary(uniqueKeysWithValues: http.headers)
                #expect(headers["apns-push-type"] == "liveactivity")
                #expect(headers["apns-topic"] == "de.example.app.push-type.liveactivity")
                #expect(headers["apns-priority"] == (event == .update ? "5" : "10"))
                #expect(headers["apns-expiration"] == "1800000000")
                #expect(http.url == ApnsClient.host(env) + "/3/device/" + F.activity)
            }
            let ordinary = ApnsRequest(tokenHex: F.device, env: env, topic: "de.example.app", payload: [], collapseID: F.subscription, expiration: 1)
            let headers = Dictionary(uniqueKeysWithValues: client.httpRequest(ordinary, jwt: "synthetic").headers)
            #expect(headers["apns-topic"] == "de.example.app")
            #expect(headers["apns-push-type"] == "alert" && headers["apns-priority"] == "10")
        }
    }

    @Test func http410MapsToUnregisteredForActivityRequests() async throws {
        let sender = try client(status: 410)
        let request = ApnsRequest(tokenHex: F.activity, env: .production, topic: "de.example.app", payload: [],
                                  collapseID: F.subscription, expiration: 1, activityEvent: .update)
        #expect(await sender.send(request) == .unregistered)
    }

    @Test func contentPhasesDatesAndStartUpdateEndPayloads() throws {
        struct Content: Decodable {
            var phase: String
            var eventDate: Date?
            var intensityClass: Int
            var referenceTime: Date
            var staleDate: Date?
        }
        let starts = PushActivityPayload.content(classes: F.wet(), threshold: 3, reference: run0)
        let decoded = try JSONDecoder().decode(Content.self, from: Data(F.json(starts)))
        #expect(decoded.phase == "startsIn" && decoded.eventDate == run0.addingTimeInterval(600))
        #expect(decoded.intensityClass == 3 && decoded.referenceTime == run0)
        #expect(decoded.staleDate == run0.addingTimeInterval(PushEvaluator.maxRunAge))
        let raining = PushActivityPayload.content(classes: F.wet(onset: 0), threshold: 3, reference: run0)
        #expect(raining["phase"] as? String == "raining")
        let ending = PushActivityPayload.content(classes: [3, 3, 0, 0], threshold: 3, reference: run0)
        #expect(ending["phase"] as? String == "endsIn")
        #expect(ending["eventDate"] as? Double == run0.addingTimeInterval(600).timeIntervalSinceReferenceDate)
        let dry = PushActivityPayload.content(classes: [0, 0], threshold: 3, reference: run0)
        #expect(dry["phase"] as? String == "dry" && dry["eventDate"] is NSNull)
        for event in [PushActivityEvent.start, .update, .end] {
            let bytes = try PushActivityPayload.encode(event: event, subscriptionID: F.subscription, content: starts, now: run0)
            let aps = try #require(try F.object(bytes)["aps"] as? [String: Any])
            #expect(aps["event"] as? String == event.rawValue)
            #expect(aps["timestamp"] as? Int == Int(run0.timeIntervalSince1970))
            #expect(aps["stale-date"] as? Int == Int(run0.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSince1970))
            let state = try #require(aps["content-state"] as? [String: Any])
            #expect(try F.json(state).count <= 4096)
            if event == .start {
                #expect(aps["attributes-type"] as? String == "RainActivityAttributes")
                let attributes = try #require(aps["attributes"] as? [String: String])
                #expect(attributes == ["displayName": "", "subscriptionID": F.subscription])
                #expect(aps["alert"] != nil)
                // iOS 18+: without input-push-token the app never receives the update token of a remotely started activity.
                #expect(aps["input-push-token"] as? Int == 1)
            } else {
                #expect(aps["attributes-type"] == nil && aps["attributes"] == nil && aps["alert"] == nil && aps["input-push-token"] == nil)
            }
            if event == .end { #expect(aps["dismissal-date"] as? Int == Int(run0.timeIntervalSince1970)) }
            else { #expect(aps["dismissal-date"] == nil) }
            #expect(!String(decoding: bytes, as: UTF8.self).contains(F.start))
        }
    }

    @Test func contentStateAllowsExactlyFourKiBRejectsLargerAndCountsUTF8Bytes() throws {
        let overhead = try F.json(["x": ""]).count
        let atLimit: [String: Any] = ["x": String(repeating: "a", count: 4096 - overhead)]
        #expect(try F.json(atLimit).count == 4096)
        _ = try PushActivityPayload.encode(event: .update, subscriptionID: F.subscription, content: atLimit, now: run0)
        for oversized in [["x": String(repeating: "a", count: 4097 - overhead)], ["x": String(repeating: "ä", count: 2100)]] {
            #expect(try F.json(oversized).count > 4096)
            #expect(throws: PushActivityPayload.PayloadError.self) {
                try PushActivityPayload.encode(event: .update, subscriptionID: F.subscription, content: oversized, now: run0)
            }
        }
    }
}

// MARK: Review A1, A6, A7, A8 (3 Nov 2026)

@Suite("Live Activity hardening: evaluation, budget, limits")
struct PushActivityHardeningTests {
    private typealias F = ActivityFixture

    private func newInstall(_ repo: MemoryRepo, startToken: Bool = true) async throws -> String {
        let id = UUID().uuidString.lowercased()
        _ = try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
        if startToken { try await repo.setLiveActivityStartToken(installationID: id, token: F.start) }
        return id
    }

    /// A1: with many opt-in subscriptions the repository is asked a constant number of questions per page, never per subscription.
    @Test func manyOptInSubscriptionsNeedOneBulkQueryPerPageAndAlertsGoFirst() async throws {
        let repo = MemoryRepo(clock: { run0 })
        let installs = 40, perInstall = 10, pageSize = 100
        for _ in 0..<installs {
            let id = try await newInstall(repo)
            for _ in 0..<perInstall {
                #expect(try await repo.addSubscription(installationID: id, id: UUID().uuidString.lowercased(), F.input(), maxPerInstallation: 10, now: run0) == .created)
            }
        }
        let sender = FakeApnsSender()
        let now = Locked(run0)
        let config = F.config()
        let service = PushService(config: config, repo: repo, sender: sender, owner: "bulk", evaluationPageSize: pageSize,
                                  activitySendsPerTick: 10_000, clock: { now.withLock { $0 } })
        func publishAndTick(_ index: Int, _ classes: [Int]) async throws {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await F.publish(repo, config: config, at: date, classes: classes)
            _ = try await service.tick()
        }
        try await publishAndTick(0, F.wet(onset: 3))
        let before = (single: await repo.callCount("activityTarget"), bulk: await repo.callCount("activityTargets"),
                      pages: await repo.callCount("evaluationSubscriptions"), endable: await repo.callCount("endableActivities"))
        try await publishAndTick(1, F.wet())
        let pages = installs * perInstall / pageSize + 1 // full pages plus the final empty page
        let afterSingle = await repo.callCount("activityTarget"), afterBulk = await repo.callCount("activityTargets")
        let afterPages = await repo.callCount("evaluationSubscriptions"), afterEndable = await repo.callCount("endableActivities")
        #expect(afterSingle - before.single == 0)
        #expect(afterBulk - before.bulk == installs * perInstall / pageSize)
        #expect(afterPages - before.pages == pages)
        #expect(afterEndable - before.endable <= 1)
        let requests = await sender.requests
        let alerts = requests.indices.filter { requests[$0].activityEvent == nil }
        let starts = requests.indices.filter { requests[$0].activityEvent == .start }
        #expect(alerts.count == installs * perInstall)
        #expect(starts.count == installs) // one activity slot per installation
        #expect(try #require(alerts.last) < #require(starts.first)) // alerts are never behind activity sends
    }

    @Test func activityBudgetLimitsSendsPerTickAndCarriesTheRestOver() async throws {
        let repo = MemoryRepo(clock: { run0 })
        for _ in 0..<12 {
            let id = try await newInstall(repo)
            _ = try await repo.addSubscription(installationID: id, id: UUID().uuidString.lowercased(), F.input(), maxPerInstallation: 10, now: run0)
        }
        let sender = FakeApnsSender()
        let now = Locked(run0)
        let config = F.config()
        let service = PushService(config: config, repo: repo, sender: sender, owner: "budget", activitySendsPerTick: 5, clock: { now.withLock { $0 } })
        for (index, classes) in [F.wet(onset: 3), F.wet()].enumerated() {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await F.publish(repo, config: config, at: date, classes: classes)
            _ = try await service.tick()
        }
        func starts() async -> Int { await sender.requests.filter { $0.activityEvent == .start }.count }
        #expect(await sender.requests.filter { $0.activityEvent == nil }.count == 12) // alerts complete in the first tick
        #expect(await starts() == 5)
        _ = try await service.tick()
        #expect(await starts() == 10)
        _ = try await service.tick()
        #expect(await starts() == 12)
        _ = try await service.tick()
        #expect(await starts() == 12)
    }

    @Test func expiryReadsOnlyActivityRowsNotAllOptInSubscriptions() async throws {
        let repo = MemoryRepo(clock: { run0 })
        for _ in 0..<50 {
            let id = try await newInstall(repo)
            _ = try await repo.addSubscription(installationID: id, id: UUID().uuidString.lowercased(), F.input(), maxPerInstallation: 10, now: run0)
        }
        let service = PushService(config: F.config(), repo: repo, sender: FakeApnsSender(), owner: "expiry-scan", clock: { run0 })
        _ = try await service.tick()
        let endable = await repo.callCount("endableActivities"), single = await repo.callCount("activityTarget"), bulk = await repo.callCount("activityTargets")
        #expect(endable == 1 && single == 0 && bulk == 0)
    }

    @Test func liveActivityRequiresStartTokenAndIsCapped() async throws {
        let repo = MemoryRepo(clock: { run0 })
        let id = try await newInstall(repo, startToken: false)
        var config = F.config()
        config.push.regionLimits.maxLiveActivitySubscriptions = 2
        let api = PushApi(repo: repo, config: config, clock: { run0 })
        let path = "/v1/push/installations/" + id + "/subscriptions"
        func post(_ live: Bool) async throws -> ApiResponse {
            try #require(await api.handle(method: "POST", path: path, secret: F.secret, body: try F.body(["live_activity": live])))
        }
        let refused = try await post(true)
        #expect(refused.status == 409)
        #expect(try F.object(refused.body)["error"] as? String == "start_token_required")
        #expect(try await post(false).status == 201) // opt-out stays possible without a token
        try await repo.setLiveActivityStartToken(installationID: id, token: F.start)
        #expect(try await post(true).status == 201)
        #expect(try await post(true).status == 201)
        let full = try await post(true)
        #expect(full.status == 503)
        #expect(try F.object(full.body)["error"] as? String == "activity_full")
        #expect(try await post(false).status == 201) // non-live subscriptions are not capped by it
        // Switching an existing subscription to live hits the cap as well; keeping a live one live does not.
        let listed = try #require(await api.handle(method: "GET", path: path, secret: F.secret, body: []))
        let items = try #require(try JSONSerialization.jsonObject(with: Data(listed.body)) as? [[String: Any]])
        let plain = try #require(items.first { $0["live_activity"] as? Bool == false }?["id"] as? String)
        let live = try #require(items.first { $0["live_activity"] as? Bool == true }?["id"] as? String)
        let toLive = await api.handle(method: "PUT", path: path + "/" + plain, secret: F.secret, body: try F.body(["live_activity": true]))
        #expect(toLive?.status == 503)
        #expect(await api.handle(method: "PUT", path: path + "/" + live, secret: F.secret, body: try F.body(["live_activity": true]))?.status == 204)
        try await repo.setLiveActivityStartToken(installationID: id, token: nil)
        let noToken = await api.handle(method: "PUT", path: path + "/" + live, secret: F.secret, body: try F.body(["live_activity": true]))
        #expect(noToken?.status == 409)
    }

    @Test func capIsConfigurableFromTheEnvironment() throws {
        #expect(Config().push.regionLimits.maxLiveActivitySubscriptions == 5_000)
        #expect(try Config.fromEnvironment(["PUSH_MAX_ACTIVITY_SUBSCRIPTIONS": "12"]).push.regionLimits.maxLiveActivitySubscriptions == 12)
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["PUSH_MAX_ACTIVITY_SUBSCRIPTIONS": "0"]) }
    }

    /// A6: format checks and the global limit come before any database access; unknown subscriptions cost one cheap query.
    @Test func shortRouteChecksLimitsAndFormatBeforeTheDatabase() async throws {
        let repo = try await F.prepared()
        let api = PushApi(repo: repo, config: F.config(), globalRequestLimit: 3, clock: { run0 })
        let body = try F.json(["activity_token": F.activity])
        #expect(await api.handle(method: "PUT", path: F.route, secret: "short", body: body)?.status == 401)
        #expect(await api.handle(method: "PUT", path: F.route, secret: nil, body: body)?.status == 401)
        var owner = await repo.callCount("subscriptionOwner"), single = await repo.callCount("activityTarget")
        #expect(owner == 0 && single == 0)
        // Third request still passes (global:any counted once each), the fourth is refused before the lookup.
        #expect(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: body)?.status == 204)
        owner = await repo.callCount("subscriptionOwner")
        #expect(owner == 1)
        #expect(await api.handle(method: "PUT", path: F.route, secret: F.secret, body: body)?.status == 429)
        owner = await repo.callCount("subscriptionOwner"); single = await repo.callCount("activityTarget")
        #expect(owner == 1 && single == 0)
        let unknown = PushApi(repo: repo, config: F.config(), clock: { run0 })
        #expect(await unknown.handle(method: "PUT", path: "/v1/push/subscriptions/55555555-5555-4555-8555-555555555555/activity", secret: F.secret, body: body)?.status == 404)
        single = await repo.callCount("activityTarget")
        #expect(single == 0)
    }

    /// A7: owner can free a token-less reservation; a stale reservation also frees itself.
    @Test func reservationWithoutTokenCanBeDeletedAndTimesOut() async throws {
        let repo = try await F.prepared()
        let api = PushApi(repo: repo, config: F.config(), clock: { run0 })
        #expect(try await repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        #expect(await api.handle(method: "DELETE", path: F.route, secret: F.secret, body: [])?.status == 204)
        #expect(try await F.target(repo).activity == nil)
        // A registered activity is not removed by the token-less form.
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        #expect(await api.handle(method: "DELETE", path: F.route, secret: F.secret, body: [])?.status == 204)
        #expect(try await F.target(repo).activity?.activityToken == F.activity)
        _ = try await repo.deleteActivity(subscriptionID: F.subscription, matchingToken: nil)
        // Automatic timeout after a transient APNs failure.
        let sender = FakeApnsSender(script: [.retry("synthetic")])
        let now = Locked(run0)
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "timeout", clock: { now.withLock { $0 } })
        var result = PushTick()
        try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        #expect(result.retried == 1)
        #expect(try await F.target(repo).activity != nil)
        now.withLock { $0 = run0.addingTimeInterval(PushService.reservationTimeout - 60) }
        _ = try await service.tick()
        #expect(try await F.target(repo).activity != nil)
        now.withLock { $0 = run0.addingTimeInterval(PushService.reservationTimeout + 60) }
        _ = try await service.tick()
        #expect(try await F.target(repo).activity == nil)
        #expect(await sender.requests.count == 1) // the timeout needs no APNs request
    }

    /// A8: BadDeviceToken on the push-to-start token removes the token and the reservation, nothing else.
    @Test func badDeviceTokenOnStartClearsStartTokenAndReservation() async throws {
        let repo = try await F.prepared()
        let sender = FakeApnsSender(script: [.badToken("BadDeviceToken")])
        let service = PushService(config: F.config(), repo: repo, sender: sender, owner: "bad-start", clock: { run0 })
        var result = PushTick()
        try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        #expect(result.dropped == 1 && result.apnsReasons["BadDeviceToken"] == 1)
        #expect(try await F.target(repo).activity == nil)
        let installation = try #require(try await repo.installation(id: F.installation))
        #expect(installation.liveActivityStartToken == nil && installation.token == F.device)
        // No further start attempt without a (new) start token.
        try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        #expect(await sender.requests.count == 1)
        // A different rejection keeps the start token (only the reservation goes).
        try await repo.setLiveActivityStartToken(installationID: F.installation, token: F.start)
        let other = FakeApnsSender(script: [.rejected("400 PayloadTooLarge")])
        let service2 = PushService(config: F.config(), repo: repo, sender: other, owner: "bad-start", clock: { run0 })
        try await service2.evaluateActivity(sub: try await F.target(repo).subscription, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
        #expect(try await repo.installation(id: F.installation)?.liveActivityStartToken == F.start)
        #expect(await other.requests.count == 1)
        #expect(try await F.target(repo).activity == nil)
    }
}

extension DatabaseSuites {
@Suite("Live Activity repository: bulk lookup, endable page, caps", .serialized)
struct PushActivityBulkRepoTests {
    private typealias F = ActivityFixture

    private func seed(_ repo: any Repo, count: Int) async throws -> [String] {
        var subs: [String] = []
        for _ in 0..<count {
            let install = UUID().uuidString.lowercased(), sub = UUID().uuidString.lowercased()
            _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
            try await repo.setLiveActivityStartToken(installationID: install, token: F.start)
            #expect(try await repo.addSubscription(installationID: install, id: sub, F.input(), maxPerInstallation: 10, now: run0) == .created)
            subs.append(sub)
        }
        return subs.sorted()
    }

    @Test(arguments: RepoKind.allCases) func bulkLookupReturnsInstallationAndActivityForEveryId(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let subs = try await seed(repo, count: 7)
        _ = try await repo.setActivityToken(subscriptionID: subs[2], token: F.activity, now: run0)
        _ = try await repo.reserveActivity(subscriptionID: subs[4], now: run0)
        let targets = try await repo.activityTargets(subscriptionIDs: subs + ["00000000-0000-4000-8000-000000000000"])
        #expect(Set(targets.map(\.subscription.id)) == Set(subs))
        for target in targets {
            #expect(target.installation.liveActivityStartToken == F.start && target.installation.token == F.device && target.subscription.liveActivity)
            let expectedToken: String? = target.subscription.id == subs[2] ? F.activity : nil
            #expect(target.activity?.activityToken == expectedToken)
            #expect((target.activity != nil) == (target.subscription.id == subs[2] || target.subscription.id == subs[4]))
        }
        #expect(try await repo.activityTargets(subscriptionIDs: []).isEmpty)
        let single = try #require(try await repo.activityTarget(subscriptionID: subs[2]))
        #expect(single.activity == targets.first { $0.subscription.id == subs[2] }?.activity)
    }

    @Test(arguments: RepoKind.allCases) func endablePageSelectsOnlyRowsThatMustEndAndPages(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let subs = try await seed(repo, count: 5)
        // 0: running, 1: reached its deadline, 2: stale reservation, 3: fresh reservation, 4: opted out.
        _ = try await repo.setActivityToken(subscriptionID: subs[0], token: F.activity, now: run0.addingTimeInterval(7 * 3600))
        _ = try await repo.setActivityToken(subscriptionID: subs[1], token: F.activity, now: run0)
        _ = try await repo.reserveActivity(subscriptionID: subs[2], now: run0)
        _ = try await repo.reserveActivity(subscriptionID: subs[3], now: run0.addingTimeInterval(8 * 3600 - 60))
        _ = try await repo.setActivityToken(subscriptionID: subs[4], token: F.activity, now: run0.addingTimeInterval(7 * 3600))
        let optedOut = try #require(try await repo.activityTarget(subscriptionID: subs[4]))
        _ = try await repo.updateSubscription(installationID: optedOut.installationID, id: subs[4], F.input(live: false))
        let now = run0.addingTimeInterval(8 * 3600)
        let all = try await repo.endableActivities(now: now, reservationTimeout: 900, after: nil, limit: 50)
        #expect(all.map(\.subscription.id) == [subs[1], subs[2], subs[4]].sorted())
        var seen: [String] = []
        var after: String?
        while true {
            let page = try await repo.endableActivities(now: now, reservationTimeout: 900, after: after, limit: 2)
            seen += page.map(\.subscription.id)
            guard page.count == 2 else { break }
            after = page.last?.subscription.id
        }
        #expect(seen == all.map(\.subscription.id))
        #expect(try await repo.endableActivities(now: run0, reservationTimeout: 900, after: nil, limit: 50).map(\.subscription.id) == [subs[4]])
    }

    @Test(arguments: RepoKind.allCases) func liveActivityCapAndReservationDeletion(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let limits = RegionLimits(maxLiveActivitySubscriptions: 2)
        let subs = try await seed(repo, count: 2)
        let install = UUID().uuidString.lowercased()
        _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
        let extra = UUID().uuidString.lowercased()
        #expect(try await repo.addSubscription(installationID: install, id: extra, F.input(), maxPerInstallation: 10, regionLimits: limits, now: run0) == .activityCapacity)
        #expect(try await repo.addSubscription(installationID: install, id: extra, F.input(live: false), maxPerInstallation: 10, regionLimits: limits, now: run0) == .created)
        await #expect(throws: PushRegionLimitError.activityCapacity) {
            _ = try await repo.updateSubscription(installationID: install, id: extra, F.input(), regionLimits: limits)
        }
        let first = try #require(try await repo.activityTarget(subscriptionID: subs[0]))
        #expect(try await repo.updateSubscription(installationID: first.installationID, id: subs[0], F.input(), regionLimits: limits)) // stays live
        _ = try await repo.updateSubscription(installationID: first.installationID, id: subs[0], F.input(live: false), regionLimits: limits)
        #expect(try await repo.updateSubscription(installationID: install, id: extra, F.input(), regionLimits: limits))
        // Reservation deletion leaves registered activities alone.
        #expect(try await repo.reserveActivity(subscriptionID: subs[1], now: run0))
        #expect(try await repo.deleteReservation(subscriptionID: subs[1]))
        #expect(try await repo.deleteReservation(subscriptionID: subs[1]) == false)
        _ = try await repo.setActivityToken(subscriptionID: subs[1], token: F.activity, now: run0)
        #expect(try await repo.deleteReservation(subscriptionID: subs[1]) == false)
        #expect(try await repo.activityTarget(subscriptionID: subs[1])?.activity?.activityToken == F.activity)
        #expect(try await repo.subscriptionOwner(subscriptionID: subs[1]) == (try await repo.activityTarget(subscriptionID: subs[1]))?.installationID)
        #expect(try await repo.subscriptionOwner(subscriptionID: UUID().uuidString.lowercased()) == nil)
    }
}
}

private enum ReviewFixture {
    typealias F = ActivityFixture
    static func service(_ repo: MemoryRepo, sender: FakeApnsSender) -> PushService {
        PushService(config: F.config(), repo: repo, sender: sender, owner: "review", clock: { run0 })
    }
}

@Suite("Live Activity review round 3: unknown pixels, tokenless end, locale")
struct PushActivityReviewTests {
    private typealias F = ActivityFixture

    @Test func unknownPixelsAreNeitherDryNorWet() {
        #expect(PushIntensity.classifyOrUnknown(r: 0, g: 0, b: 0, a: 0) == 0) // transparent background = dry
        #expect(PushIntensity.classifyOrUnknown(r: 0x7D, g: 0x7D, b: 0x7D, a: 76) == PushIntensity.unknown) // "no data" mask
        #expect(PushIntensity.classifyOrUnknown(r: 0x20, g: 0x20, b: 0x20, a: 255) == PushIntensity.unknown) // unknown colour
        let first = PushIntensity.palette[0]
        #expect(PushIntensity.classifyOrUnknown(r: UInt8(first.r), g: UInt8(first.g), b: UInt8(first.b), a: 255) == 1)
        // The ordinary automaton keeps its behaviour: classify() still maps both to 0.
        #expect(PushIntensity.classify(r: 0x20, g: 0x20, b: 0x20, a: 255) == 0)
        let step = PushEvaluator.step(state: .notified, threshold: 3, leadMinutes: 20, lastSentAt: nil,
                                      classes: [Int](repeating: -1, count: TimeUtil.forecastSlots), now: run0)
        #expect(step.state == .dry && step.notifyMinutes == nil)
    }

    @Test func unknownNeverConfirmsRainEndOrSetsEndTime() {
        let unknownEnd = PushActivityPayload.content(classes: [3, 3, -1, 0], threshold: 3, reference: run0)
        #expect(unknownEnd["phase"] as? String == "raining" && unknownEnd["eventDate"] is NSNull)
        let knownEnd = PushActivityPayload.content(classes: [3, 3, 0, -1], threshold: 3, reference: run0)
        #expect(knownEnd["phase"] as? String == "endsIn")
        let allUnknown = PushActivityPayload.content(classes: [-1, -1], threshold: 3, reference: run0)
        #expect(allUnknown["intensityClass"] as? Int == 0)
    }

    @Test func unknownSlotsKeepTheActivityRunningButKnownDryEndsIt() async throws {
        let repo = try await F.prepared()
        _ = try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        let sender = FakeApnsSender()
        let service = ReviewFixture.service(repo, sender: sender)
        var result = PushTick()
        var classes = [Int](repeating: 0, count: TimeUtil.forecastSlots)
        classes[3] = -1
        try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: classes, notify: false, reference: run0, now: run0, result: &result)
        #expect(await sender.requests.map(\.activityEvent) == [.update])
        #expect(try await F.target(repo).activity != nil)
        classes[3] = 0
        try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: classes, notify: false, reference: run0, now: run0, result: &result)
        #expect(await sender.requests.map(\.activityEvent) == [.update, .end])
        #expect(try await F.target(repo).activity == nil)
    }

    @Test func staleTokenlessEndDoesNotDeleteALaterRegisteredToken() async throws {
        let repo = try await F.prepared()
        #expect(try await repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        let stale = try await F.target(repo) // snapshot: reservation without token
        #expect(stale.activity?.activityToken == nil)
        #expect(try await repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .updated)
        let sender = FakeApnsSender()
        let service = ReviewFixture.service(repo, sender: sender)
        var result = PushTick()
        let content = PushActivityPayload.content(classes: [], threshold: 3, reference: run0)
        try await service.sendActivity(target: stale, event: .end, content: content, now: run0, result: &result)
        let requests = await sender.requests
        #expect(requests.count == 1 && requests[0].activityEvent == .end && requests[0].tokenHex == F.activity)
        #expect(try await F.target(repo).activity == nil) // removed after the APNs ending, not before

        // A genuinely tokenless reservation is still dropped silently.
        #expect(try await repo.reserveActivity(subscriptionID: F.subscription, now: run0))
        let tokenless = try await F.target(repo)
        try await service.sendActivity(target: tokenless, event: .end, content: content, now: run0, result: &result)
        #expect(await sender.requests.count == 1)
        #expect(try await F.target(repo).activity == nil)
    }

    @Test func startAlertFollowsInstallationLocale() async throws {
        for (locale, text) in [("en", "Rain starting soon"), ("de", "Regen beginnt bald"), ("fr", "Regen beginnt bald")] {
            let repo = MemoryRepo(clock: { run0 })
            _ = try await repo.upsertInstallation(id: F.installation, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)),
                                                 token: F.device, env: .sandbox, locale: locale, now: run0)
            try await repo.setLiveActivityStartToken(installationID: F.installation, token: F.start)
            _ = try await repo.addSubscription(installationID: F.installation, id: F.subscription, F.input(), maxPerInstallation: 10, now: run0)
            let sender = FakeApnsSender()
            let service = ReviewFixture.service(repo, sender: sender)
            var result = PushTick()
            try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: F.wet(), notify: true, reference: run0, now: run0, result: &result)
            let start = try #require(await sender.requests.first { $0.activityEvent == .start })
            let alert = try #require(try F.aps(start)["alert"] as? [String: String])
            #expect(alert["body"] == text)
        }
    }
}


@Suite("Live Activity start while it already rains")
struct PushActivityRainingStartTests {
    private typealias F = ActivityFixture

    /// Wet until slot `end` (exclusive), then dry.
    private static func raining(until end: Int) -> [Int] { (0..<TimeUtil.forecastSlots).map { $0 < end ? 3 : 0 } }

    private final class Harness: @unchecked Sendable {
        let repo: MemoryRepo, sender = FakeApnsSender(), config = F.config(), now = Locked(run0)
        let service: PushService
        init(repo: MemoryRepo) {
            self.repo = repo
            let now = self.now
            service = PushService(config: config, repo: repo, sender: sender, owner: "raining-test", clock: { now.withLock { $0 } })
        }
        func tick(_ index: Int, _ classes: [Int]) async throws {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await F.publish(repo, config: config, at: date, classes: classes)
            _ = try await service.tick()
        }
        func starts() async -> [ApnsRequest] { await sender.requests.filter { $0.activityEvent == .start } }
    }

    @Test func twoConsecutiveWetRunsStartWithEndsInAndRainingAlert() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: 4))
        #expect(await h.sender.requests.isEmpty) // one run is not enough
        try await h.tick(1, Self.raining(until: 4))
        let requests = await h.sender.requests
        #expect(requests.count == 1) // exactly one start, no rain-start alert
        let start = try #require(await h.starts().first)
        #expect(start.tokenHex == F.start)
        let aps = try F.aps(start)
        let content = try #require(aps["content-state"] as? [String: Any])
        #expect(content["phase"] as? String == "endsIn")
        let reference = run0.addingTimeInterval(300)
        #expect(content["eventDate"] as? Double == reference.addingTimeInterval(20 * 60).timeIntervalSinceReferenceDate)
        #expect((aps["alert"] as? [String: String])?["body"] == "Es regnet gerade")
        // Same run again: no second start.
        _ = try await h.service.tick()
        #expect(await h.starts().count == 1)
    }

    @Test func oneWetRunOrInterruptedStreakNeverStarts() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: 4))
        try await h.tick(1, Self.raining(until: 0)) // dry resets the streak
        try await h.tick(2, Self.raining(until: 4))
        #expect(await h.sender.requests.isEmpty)
        try await h.tick(3, Self.raining(until: 4))
        #expect(await h.starts().count == 1)
    }

    @Test func unknownPixelsConfirmNeitherWetNorDry() async throws {
        var unknownNow = Self.raining(until: 4)
        unknownNow[0] = -1
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: 4))
        try await h.tick(1, unknownNow) // unknown slot 0 does not confirm wet
        #expect(await h.sender.requests.isEmpty)
        try await h.tick(2, Self.raining(until: 4))
        #expect(await h.sender.requests.isEmpty)
        try await h.tick(3, Self.raining(until: 4))
        #expect(await h.starts().count == 1)
    }

    @Test func endUncertainOrBeyondWindowIsRainingWithoutEventDate() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: TimeUtil.forecastSlots))
        try await h.tick(1, Self.raining(until: TimeUtil.forecastSlots))
        var startRequest = try #require(await h.starts().first)
        var content = try #require(try F.aps(startRequest)["content-state"] as? [String: Any])
        #expect(content["phase"] as? String == "raining" && content["eventDate"] is NSNull)
        // Unknown slot right after the wet part: end is not certain either.
        let h2 = Harness(repo: try await F.prepared())
        var uncertain = Self.raining(until: 4)
        uncertain[4] = -1
        try await h2.tick(0, uncertain)
        try await h2.tick(1, uncertain)
        startRequest = try #require(await h2.starts().first)
        content = try #require(try F.aps(startRequest)["content-state"] as? [String: Any])
        #expect(content["phase"] as? String == "raining" && content["eventDate"] is NSNull)
    }

    @Test func sharedRepeatLockAndRestartAfterEnd() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: 4))
        try await h.tick(1, Self.raining(until: 4)) // start at +5 min, lock from here
        #expect(try await h.repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0) == .updated)
        try await h.tick(2, Self.raining(until: 0)) // known dry ends the activity
        #expect(try await F.target(h.repo).activity == nil)
        try await h.tick(3, Self.raining(until: 4))
        try await h.tick(4, Self.raining(until: 4))
        try await h.tick(12, Self.raining(until: 4)) // +60 min, only 55 min since the start
        #expect(await h.starts().count == 1)
        try await h.tick(13, Self.raining(until: 4)) // lock over: startable again
        #expect(await h.starts().count == 2)
    }

    @Test func rainStartAlertStartAndRainingStartNeverDouble() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, F.wet(onset: 3))
        try await h.tick(1, F.wet()) // rain-start alert + activity start (existing path)
        #expect(await h.starts().count == 1)
        // The reservation exists (token not yet registered): rain arrives, still no second start.
        try await h.tick(2, Self.raining(until: 4))
        try await h.tick(3, Self.raining(until: 4))
        #expect(await h.starts().count == 1)
        let first = try #require(await h.starts().first)
        #expect((try F.aps(first)["alert"] as? [String: String])?["body"] == "Regen beginnt bald")
    }

    @Test func noStartTokenOrNoOptInStartsNothingAndKeepsAlertLockFree() async throws {
        let repo = try await F.prepared()
        try await repo.setLiveActivityStartToken(installationID: F.installation, token: nil)
        let h = Harness(repo: repo)
        try await h.tick(0, Self.raining(until: 4))
        try await h.tick(1, Self.raining(until: 4))
        #expect(await h.sender.requests.isEmpty)
        #expect(try await F.target(repo).subscription.lastSentAt == nil) // no lock consumed without a start
        let off = Harness(repo: try await F.prepared(live: false))
        try await off.tick(0, Self.raining(until: 4))
        try await off.tick(1, Self.raining(until: 4))
        #expect(await off.sender.requests.isEmpty)
    }

    @Test func staleRunDoesNotStart() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: 4))
        // Second run arrives 25 minutes after its nominal time: nothing may be triggered.
        let date = run0.addingTimeInterval(300)
        try await F.publish(h.repo, config: h.config, at: date, classes: Self.raining(until: 4))
        h.now.withLock { $0 = date.addingTimeInterval(25 * 60) }
        _ = try await h.service.tick()
        #expect(await h.sender.requests.isEmpty)
    }

    @Test func wetStartAlertFollowsInstallationLocale() async throws {
        for (locale, text) in [("en", "It is raining right now"), ("de", "Es regnet gerade"), ("fr", "Es regnet gerade")] {
            let repo = MemoryRepo(clock: { run0 })
            _ = try await repo.upsertInstallation(id: F.installation, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)),
                                                 token: F.device, env: .sandbox, locale: locale, now: run0)
            try await repo.setLiveActivityStartToken(installationID: F.installation, token: F.start)
            _ = try await repo.addSubscription(installationID: F.installation, id: F.subscription, F.input(), maxPerInstallation: 10, now: run0)
            let sender = FakeApnsSender()
            let service = ReviewFixture.service(repo, sender: sender)
            var result = PushTick()
            try await service.evaluateActivity(sub: try await F.target(repo).subscription, classes: Self.raining(until: 4), notify: true, reference: run0, now: run0, result: &result)
            let start = try #require(await sender.requests.first { $0.activityEvent == .start })
            #expect((try F.aps(start)["alert"] as? [String: String])?["body"] == text)
            #expect((try F.aps(start)["alert"] as? [String: String])?["title"] == "Showers")
        }
    }
}

extension DatabaseSuites {
@Suite("Live Activity limit under concurrency (real database)", .serialized)
struct PushActivityConcurrencyTests {
    private typealias F = ActivityFixture

    @Test(arguments: RepoKind.allCases) func instantBitAndAttemptsPersistAndKeepTheAutomaton(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let install = UUID().uuidString.lowercased(), sub = UUID().uuidString.lowercased()
        _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
        #expect(try await repo.addSubscription(installationID: install, id: sub, F.input(), maxPerInstallation: 10, now: run0) == .created)
        func stored() async throws -> PushSubscription { try #require(try await repo.activityTargets(subscriptionIDs: [sub]).first?.subscription) }
        #expect(try await stored().instantStart)
        #expect(try await repo.commitEvaluation(runID: "20261103T1000Z", updates: [.init(id: sub, state: .notified, lastSentAt: run0, wetSeen: true, instantStart: true, startAttempts: 2)], outbox: [], now: run0))
        var row = try await stored()
        #expect(row.state == .notified && row.wetSeen && row.instantStart && row.startAttempts == 2)
        try await repo.setStartRetry(subscriptionID: sub, armed: false, attempts: 0)
        row = try await stored()
        #expect(row.state == .notified && row.wetSeen && !row.instantStart && row.startAttempts == 0)
        try await repo.setLiveActivityStartToken(installationID: install, token: F.start)
        row = try await stored()
        #expect(row.instantStart && row.state == .notified && row.wetSeen)
        #expect(try await repo.updateSubscription(installationID: install, id: sub, F.input(live: false)))
        #expect(try await !stored().instantStart)
    }

    @Test(arguments: RepoKind.allCases) func wetHysteresisBitSurvivesCommitAndLeavesStateIntact(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let install = UUID().uuidString.lowercased(), sub = UUID().uuidString.lowercased()
        _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
        #expect(try await repo.addSubscription(installationID: install, id: sub, F.input(), maxPerInstallation: 10, now: run0) == .created)
        func stored() async throws -> PushSubscription {
            let targets = try await repo.activityTargets(subscriptionIDs: [sub])
            return try #require(targets.first?.subscription)
        }
        #expect(try await stored().wetSeen == false)
        #expect(try await repo.commitEvaluation(runID: "20261103T1000Z", updates: [.init(id: sub, state: .notified, lastSentAt: run0, wetSeen: true)], outbox: [], now: run0))
        var row = try await stored()
        #expect(row.state == .notified && row.wetSeen && row.lastSentAt == run0)
        #expect(try await repo.commitEvaluation(runID: "20261103T1005Z", updates: [.init(id: sub, state: .pending, lastSentAt: run0, wetSeen: false)], outbox: [], now: run0))
        row = try await stored()
        #expect(row.state == .pending && !row.wetSeen)
    }

    @Test(arguments: RepoKind.allCases) func twoSubscriptionsOfOneInstallationNeverBothGetAnActivity(kind: RepoKind) async throws {
        let repo = try await kind.make()
        for round in 0..<40 {
            let install = UUID().uuidString.lowercased()
            let subs = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
            _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array(F.secret.utf8)), token: F.device, env: .sandbox, locale: "de", now: run0)
            try await repo.setLiveActivityStartToken(installationID: install, token: F.start)
            for sub in subs { #expect(try await repo.addSubscription(installationID: install, id: sub, F.input(), maxPerInstallation: 10, now: run0) == .created) }
            let results = try await withThrowingTaskGroup(of: PushActivityRegistrationResult.self) { group in
                for (index, sub) in subs.enumerated() {
                    group.addTask {
                        index == 0 && round % 2 == 0 ? try await repo.setActivityToken(subscriptionID: sub, token: F.activity, now: run0)
                            : (try await repo.reserveActivity(subscriptionID: sub, now: run0) ? .updated : .activityLimit)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.filter { $0 == .updated }.count == 1, "round \(round): \(results)")
            let rows = try await repo.activityTargets(subscriptionIDs: subs).filter { $0.activity != nil }
            #expect(rows.count == 1, "round \(round)")
        }
    }
}
}


@Suite("Live Activity immediate start on activation (decision 6 Nov 2026)")
struct PushImmediateStartTests {
    private typealias F = ActivityFixture
    private static func raining(until end: Int) -> [Int] { (0..<TimeUtil.forecastSlots).map { $0 < end ? 3 : 0 } }

    private final class Harness: @unchecked Sendable {
        let repo: MemoryRepo, sender: FakeApnsSender, config = F.config(), now = Locked(run0)
        let service: PushService
        init(repo: MemoryRepo, script: [ApnsResult] = []) {
            self.repo = repo
            sender = FakeApnsSender(script: script)
            let now = self.now
            service = PushService(config: config, repo: repo, sender: sender, owner: "instant-test", clock: { now.withLock { $0 } })
        }
        func tick(_ index: Int, _ classes: [Int]) async throws {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await F.publish(repo, config: config, at: date, classes: classes)
            _ = try await service.tick()
        }
        func starts() async -> Int { await sender.requests.filter { $0.activityEvent == .start }.count }
        func stored() async throws -> PushSubscription { try await F.target(repo).subscription }
    }

    @Test func activationWhileRainingStartsWithTheFirstWetRun() async throws {
        let h = Harness(repo: try await F.prepared(armed: true))
        #expect(try await h.stored().instantStart)
        try await h.tick(0, Self.raining(until: 4))
        #expect(await h.starts() == 1)
        let row = try await h.stored()
        #expect(!row.instantStart && row.startAttempts == 0 && row.wetSeen)
    }

    @Test func activationIgnoresTheAlertLockAndAnEarlierAlert() async throws {
        let repo = try await F.prepared()
        // An alert was sent 5 minutes before the activation: the 60-minute lock would hold the start back for 55 minutes.
        #expect(try await repo.commitEvaluation(runID: "20200101T0000Z", updates: [.init(id: F.subscription, state: .notified, lastSentAt: run0.addingTimeInterval(-300))], outbox: [], now: run0))
        #expect(try await repo.updateSubscription(installationID: F.installation, id: F.subscription, F.input()))
        let h = Harness(repo: repo)
        try await h.tick(0, Self.raining(until: 4))
        #expect(await h.starts() == 1)
    }

    @Test func withoutActivationTwoRunsAndTheLockStillApply() async throws {
        let h = Harness(repo: try await F.prepared())
        try await h.tick(0, Self.raining(until: 4))
        #expect(await h.starts() == 0)
        try await h.tick(1, Self.raining(until: 4))
        #expect(await h.starts() == 1)
    }

    @Test func dryOrUnknownRunDisarmsSoALaterRainNeedsTwoRuns() async throws {
        let h = Harness(repo: try await F.prepared(armed: true))
        try await h.tick(0, Self.raining(until: 0))
        #expect(try await !h.stored().instantStart)
        try await h.tick(1, Self.raining(until: 4))
        #expect(await h.starts() == 0)
        try await h.tick(2, Self.raining(until: 4))
        #expect(await h.starts() == 1)
    }

    @Test func newStartTokenArmsTheImmediateStart() async throws {
        let repo = try await F.prepared()
        try await repo.setLiveActivityStartToken(installationID: F.installation, token: F.start) // unchanged
        #expect(try await !F.target(repo).subscription.instantStart)
        try await repo.setLiveActivityStartToken(installationID: F.installation, token: F.rotated)
        #expect(try await F.target(repo).subscription.instantStart)
    }

    @Test func transientFailureRetriesWithoutLockAndStopsAfterThreeAttempts() async throws {
        let h = Harness(repo: try await F.prepared(armed: true), script: [.retry("transport"), .retry("503"), .retry("503"), .delivered])
        try await h.tick(0, Self.raining(until: 4))
        #expect(await h.starts() == 1)
        var row = try await h.stored()
        #expect(row.instantStart && row.startAttempts == 1)
        #expect(try await F.target(h.repo).activity == nil) // reservation freed for the retry
        try await h.tick(1, Self.raining(until: 4))
        #expect(await h.starts() == 2)
        try await h.tick(2, Self.raining(until: 4))
        #expect(await h.starts() == 3)
        row = try await h.stored()
        #expect(!row.instantStart && row.startAttempts == 0) // third failure: give up, the 60-minute lock holds
        try await h.tick(3, Self.raining(until: 4))
        try await h.tick(4, Self.raining(until: 4))
        #expect(await h.starts() == 3)
    }

    @Test func retryThenSuccessClearsTheBitAndNeverStartsTwice() async throws {
        let h = Harness(repo: try await F.prepared(armed: true), script: [.retry("transport"), .delivered])
        try await h.tick(0, Self.raining(until: 4))
        try await h.tick(1, Self.raining(until: 4))
        try await h.tick(2, Self.raining(until: 4))
        #expect(await h.starts() == 2) // failed + delivered
        #expect(try await !h.stored().instantStart)
    }

    @Test func rejectedStartIsNotRetried() async throws {
        let h = Harness(repo: try await F.prepared(armed: true), script: [.rejected("PayloadTooLarge")])
        try await h.tick(0, Self.raining(until: 4))
        try await h.tick(1, Self.raining(until: 4))
        #expect(await h.starts() == 1)
        #expect(try await !h.stored().instantStart)
    }

    @Test func runningActivityBlocksAnImmediateStart() async throws {
        let h = Harness(repo: try await F.prepared(armed: true))
        _ = try await h.repo.setActivityToken(subscriptionID: F.subscription, token: F.activity, now: run0)
        try await h.tick(0, Self.raining(until: 4))
        #expect(await h.starts() == 0)
    }
}
