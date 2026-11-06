import Foundation
import Testing
@testable import RadarCore

// Dashboard device routes, command execution by the leader, diagnosis. Memory repository, fake APNs sender, no network.
private let origin = "https://dash.example.test"
private let installID = "11111111-1111-4111-8111-111111111111"
private let secretHash = Hashing.sha256Hex(Array(String(repeating: "a", count: 40).utf8))
private let deviceToken = String(repeating: "ab", count: 32)
private let startToken = String(repeating: "cd", count: 32)
private let subID = "33333333-3333-4333-8333-333333333333"

private func fixture(_ name: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "docs/fixtures/dashboard/" + name)))) ?? "missing fixture \(name)"
}

/// Same keys and JSON types as the fixture (null on either side matches anything; arrays compare their first elements).
private func sameShape(_ actual: Any, _ expected: Any, path: String = "$") -> [String] {
    if expected is NSNull || actual is NSNull { return [] }
    if let e = expected as? [String: Any] {
        guard let a = actual as? [String: Any] else { return ["\(path): expected object"] }
        var problems: [String] = []
        for key in Set(a.keys).symmetricDifference(e.keys) { problems.append("\(path).\(key): key set differs") }
        for key in Set(a.keys).intersection(e.keys) { problems += sameShape(a[key]!, e[key]!, path: path + "." + key) }
        return problems
    }
    if let e = expected as? [Any] {
        guard let a = actual as? [Any] else { return ["\(path): expected array"] }
        if let x = a.first, let y = e.first { return sameShape(x, y, path: path + "[0]") }
        return []
    }
    func kind(_ v: Any) -> String {
        if let n = v as? NSNumber { return isJSONBool(n) ? "bool" : "number" }
        return v is String ? "string" : "other"
    }
    return kind(actual) == kind(expected) ? [] : ["\(path): \(kind(actual)) vs \(kind(expected))"]
}

private struct Harness {
    let api: DashboardApi
    let repo: MemoryRepo
    let sender: FakeApnsSender
    let service: PushService
    let cookie: String
    let csrf: String
    let config: Config

    init(linkEnabled: Bool = true, sender: FakeApnsSender = FakeApnsSender(), maxDevices: Int = 3) async throws {
        var c = smallConfig {
            $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox, .production]
            $0.deviceLink.enabled = linkEnabled; $0.deviceLink.maxDevices = maxDevices
        }
        c.push.keyID = "K"; c.push.teamID = "T"
        config = c
        repo = MemoryRepo()
        self.sender = sender
        service = PushService(config: c, repo: repo, sender: sender, owner: "test")
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        api = DashboardApi(auth: auth, repo: repo, store: ConfigStore(fixed: c), staticRoot: "/nonexistent")
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        cookie = "__Host-dash_session=" + created.cookieValue
        csrf = created.csrfToken
        _ = try await repo.upsertInstallation(id: installID, secretHash: secretHash, token: deviceToken, env: .sandbox, locale: "de", now: Date(), maxInstallations: 10)
    }

    func call(_ method: String, _ path: String, query: [String: String] = [:], body: String = "{}") async -> (status: Int, json: Any, response: ApiResponse) {
        let write = method != "GET"
        let info = DashboardRequestInfo(method: method, cookieHeader: cookie, origin: write ? origin : nil, host: "dash.example.test",
                                        contentType: write ? "application/json" : nil, csrfToken: csrf)
        let r = await api.handle(DashboardHTTPRequest(method: method, path: path, query: query, body: Array(body.utf8), info: info))
        return (r.status, (try? JSONSerialization.jsonObject(with: Data(r.body))) ?? NSNull(), r)
    }

    /// Links the default installation; returns the linking ID.
    @discardableResult func link(label: String = "Mein iPhone", install: String = installID, code: String = "2345ABCD") async throws -> String {
        let hash = LinkCode.hash(code)
        #expect(try await repo.createLinkCode(installationID: install, codeHash: hash, attested: true, now: Date(), ttl: 600, maxDevices: 9) == .created)
        let id = UUID().uuidString.lowercased()
        guard case .paired = try await repo.pairDevice(codeHash: hash, label: label, deviceID: id, now: Date(), maxDevices: 9, ttlDays: 0) else { Issue.record("pairing failed"); return id }
        return id
    }

    func liveSubscription(start: Bool = true) async throws {
        if start { try await repo.setLiveActivityStartToken(installationID: installID, token: startToken) }
        _ = try await repo.addSubscription(installationID: installID, id: subID,
                                           .init(gridVersion: 1, cellX: 10, cellY: 20, threshold: 3, leadMinutes: 20, enabled: true, liveActivity: true),
                                           maxPerInstallation: 10, now: Date())
    }

    func runCommand(_ id: String, _ action: String, body: String = "{}") async throws -> [String: Any] {
        let queued = await call("POST", "/dash/api/devices/\(id)/actions/\(action)", body: body)
        #expect(queued.status == 202)
        let commandID = try #require((queued.json as? [String: Any])?["commandId"] as? String)
        await service.processCommands()
        return try #require(await call("GET", "/dash/api/devices/\(id)/commands/\(commandID)").json as? [String: Any])
    }
}

@Suite("Dashboard devices")
struct DeviceDashboardTests {
    @Test func disabledSwitch() async throws {
        let h = try await Harness(linkEnabled: false)
        let list = await h.call("GET", "/dash/api/devices")
        #expect(list.status == 200 && sameShape(list.json, fixture("devices.disabled.json")).isEmpty)
        let pair = await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"ABCD-EFGH","label":"x"}"#)
        #expect(pair.status == 409 && (pair.json as? [String: Any])?["error"] as? String == "link_disabled")
        #expect(await h.call("GET", "/dash/api/devices/\(UUID().uuidString.lowercased())").status == 404)
    }

    @Test func pairingListDetailAndRevocation() async throws {
        let h = try await Harness(maxDevices: 1)
        let hash = LinkCode.hash("2345ABCD")
        _ = try await h.repo.createLinkCode(installationID: installID, codeHash: hash, attested: false, now: Date(), ttl: 600, maxDevices: 9)
        // Not attested (cannot be created via the app route) -> same answer as unknown.
        let bad = await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"2345-ABCD","label":"Mein iPhone"}"#)
        #expect(bad.status == 404 && (bad.json as? [String: Any])?["error"] as? String == "code_unknown")
        #expect(await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"zz","label":"x"}"#).status == 400)
        #expect(await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"2345ABCD","label":"   "}"#).status == 400)
        #expect(await h.call("POST", "/dash/api/devices/pair", body: "{\"code\":\"2345ABCD\",\"label\":\"\(String(repeating: "x", count: 41))\"}").status == 400)
        _ = try await h.repo.createLinkCode(installationID: installID, codeHash: hash, attested: true, now: Date(), ttl: 600, maxDevices: 9)
        let ok = await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"2345 -abcd","label":" Mein iPhone "}"#)
        #expect(ok.status == 201 && sameShape(ok.json, fixture("devices-pair.201.json")).isEmpty, "\(sameShape(ok.json, fixture("devices-pair.201.json")))")
        let id = try #require((ok.json as? [String: Any])?["id"] as? String)
        let again = await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"2345ABCD","label":"x"}"#)
        #expect(again.status == 404)

        try await h.liveSubscription(start: false)
        let list = await h.call("GET", "/dash/api/devices")
        #expect(sameShape(list.json, fixture("devices.200.json")).isEmpty, "\(sameShape(list.json, fixture("devices.200.json")))")
        let device = try #require(((list.json as? [String: Any])?["devices"] as? [[String: Any]])?.first)
        #expect(device["label"] as? String == "Mein iPhone" && (device["summary"] as? [String: Any])?["code"] as? String == "no_start_token")
        let detail = await h.call("GET", "/dash/api/devices/\(id)")
        #expect(detail.status == 200 && sameShape(detail.json, fixture("device.200.json")).isEmpty, "\(sameShape(detail.json, fixture("device.200.json")))")
        // No identifiers in any device answer.
        for text in [String(decoding: detail.response.body, as: UTF8.self), String(decoding: list.response.body, as: UTF8.self)] {
            #expect(!text.contains(installID) && !text.contains(subID) && !text.contains(deviceToken))
        }
        // Device limit (1) reached: a second installation cannot be linked.
        let other = "22222222-2222-4222-8222-222222222222"
        _ = try await h.repo.upsertInstallation(id: other, secretHash: secretHash, token: deviceToken + "00", env: .sandbox, locale: "en", now: Date(), maxInstallations: 10)
        #expect(try await h.repo.createLinkCode(installationID: other, codeHash: LinkCode.hash("ZZZZ0000"), attested: true, now: Date(), ttl: 600, maxDevices: 9) == .created)
        let limit = await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"ZZZZ0000","label":"zweites"}"#)
        #expect(limit.status == 409 && (limit.json as? [String: Any])?["error"] as? String == "device_limit")
        // Revocation is idempotent; unknown non-UUID ids are 404.
        #expect(await h.call("DELETE", "/dash/api/devices/\(id)").status == 204)
        #expect(await h.call("DELETE", "/dash/api/devices/\(id)").status == 204)
        #expect(await h.call("DELETE", "/dash/api/devices/nope").status == 404)
        #expect(await h.call("GET", "/dash/api/devices/\(id)").status == 404)
        let audit = try await h.repo.auditEntries(limit: 10)
        #expect(audit.contains { $0.action == .devicePair && $0.deviceRef?.count == 8 } && audit.contains { $0.action == .deviceUnpair })
    }

    @Test func failedRedemptionsAreThrottled() async throws {
        let h = try await Harness()
        for _ in 0..<5 { #expect(await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"ABCDEFGH","label":"x"}"#).status == 404) }
        let blocked = await h.call("POST", "/dash/api/devices/pair", body: #"{"code":"ABCDEFGH","label":"x"}"#)
        #expect(blocked.status == 429 && blocked.response.headers.contains { $0.0 == "Retry-After" })
    }

    @Test func actionsQueueLimitAndValidate() async throws {
        let h = try await Harness()
        let id = try await h.link()
        let queued = await h.call("POST", "/dash/api/devices/\(id)/actions/test")
        #expect(queued.status == 202 && sameShape(queued.json, fixture("action.202.json")).isEmpty)
        let pending = await h.call("POST", "/dash/api/devices/\(id)/actions/test")
        #expect(pending.status == 409 && (pending.json as? [String: Any])?["error"] as? String == "command_pending")
        #expect(await h.call("POST", "/dash/api/devices/\(id)/actions/bogus").status == 400)
        #expect(await h.call("POST", "/dash/api/devices/\(id)/actions/reeval", body: #"{"dryRun":"yes"}"#).status == 400)
        #expect(await h.call("POST", "/dash/api/devices/\(UUID().uuidString.lowercased())/actions/test").status == 404)
        // Hourly limit of `test`: 3 per hour.
        var statuses: [Int] = []
        for _ in 0..<4 {
            await h.service.processCommands()
            statuses.append(await h.call("POST", "/dash/api/devices/\(id)/actions/test").status)
        }
        #expect(statuses == [202, 202, 429, 429] || statuses.contains(429))
        let limited = await h.call("POST", "/dash/api/devices/\(id)/actions/test")
        #expect(limited.status == 429 && (limited.json as? [String: Any])?["error"] as? String == "action_rate_limited")
        #expect(limited.response.headers.contains { $0.0 == "Retry-After" })
    }

    @Test func leaderRunsTestAndRecordsEventAndAudit() async throws {
        let h = try await Harness()
        let id = try await h.link()
        let done = try await h.runCommand(id, "test")
        #expect(done["status"] as? String == "done" && sameShape(done, fixture("command.done-test.json")).isEmpty)
        #expect((done["result"] as? [String: Any])?["outcome"] as? String == "delivered")
        let requests = await h.sender.requests
        #expect(requests.count == 1 && requests[0].tokenHex == deviceToken)
        let events = await h.call("GET", "/dash/api/devices/\(id)/events")
        #expect(sameShape(events.json, fixture("device-events.200.json")).isEmpty)
        #expect(((events.json as? [String: Any])?["events"] as? [[String: Any]])?.first?["kind"] as? String == "test")
        let audit = try await h.repo.auditEntries(limit: 5)
        #expect(audit.contains { $0.action == .deviceAction && $0.outcome == "test:delivered" })
        let list = await h.call("GET", "/dash/api/devices/\(id)/commands")
        // `result` differs per kind (compared in the per-kind fixtures above); everything else must match the list fixture.
        var listed = try #require((list.json as? [String: Any])?["commands"] as? [[String: Any]])
        listed = listed.map { var c = $0; c["result"] = NSNull(); return c }
        #expect(sameShape(["commands": listed], fixture("commands.200.json")).isEmpty)
    }

    @Test func rejectedAndUnregisteredTests() async throws {
        let h = try await Harness(sender: FakeApnsSender(script: [.badToken("BadDeviceToken")]))
        let id = try await h.link()
        let r = try await h.runCommand(id, "test")
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["outcome"] as? String == "rejected" && result["reason"] as? String == "BadDeviceToken" && result["apnsStatus"] as? Int == 400)
    }

    @Test func probeUsesRealStartPathWithTestAlert() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription()
        let done = try await h.runCommand(id, "la-probe")
        #expect(done["status"] as? String == "done")
        let result = try #require(done["result"] as? [String: Any])
        #expect(result["outcome"] as? String == "delivered" && result["skipped"] is NSNull)
        let request = try #require(await h.sender.requests.first)
        #expect(request.tokenHex == startToken && request.activityEvent == .start)
        let aps = try #require((try JSONSerialization.jsonObject(with: Data(request.payload)) as? [String: Any])?["aps"] as? [String: Any])
        #expect((aps["alert"] as? [String: Any])?["body"] as? String == "Live-Activity-Test" && aps["attributes-type"] as? String == "RainActivityAttributes")
        // The single slot is now reserved: a second probe is skipped, nothing is sent.
        let second = try await h.runCommand(id, "la-probe")
        let skipped = try #require(second["result"] as? [String: Any])
        #expect(skipped["skipped"] as? String == "reservation_pending" && skipped["outcome"] as? String == "dropped")
        #expect(await h.sender.requests.count == 1)
        // reset-slot clears the reservation; la-end afterwards has nothing to end.
        let reset = try await h.runCommand(id, "reset-slot")
        #expect((reset["result"] as? [String: Any])?["cleared"] as? String == "reservation")
        let end = try await h.runCommand(id, "la-end")
        #expect((end["result"] as? [String: Any])?["hadActivity"] as? Bool == false)
    }

    @Test func probeWithoutStartTokenIsSkipped() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription(start: false)
        let done = try await h.runCommand(id, "la-probe")
        #expect((done["result"] as? [String: Any])?["skipped"] as? String == "no_start_token" && sameShape(done, fixture("command.done-la_probe_skipped.json")).isEmpty)
        #expect(await h.sender.requests.isEmpty)
    }

    @Test func endSendsEndToRunningActivity() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription()
        #expect(try await h.repo.reserveActivity(subscriptionID: subID, now: Date()))
        _ = try await h.repo.setActivityToken(subscriptionID: subID, token: String(repeating: "ef", count: 32), now: Date())
        let done = try await h.runCommand(id, "la-end")
        let result = try #require(done["result"] as? [String: Any])
        #expect(result["outcome"] as? String == "delivered" && result["hadActivity"] as? Bool == true)
        #expect(await h.sender.requests.first?.activityEvent == .end)
    }

    @Test func reevalWithoutRadarFailsAndWithoutLinkExpires() async throws {
        let h = try await Harness()
        let id = try await h.link()
        let failed = try await h.runCommand(id, "reeval")
        #expect(failed["status"] as? String == "failed" && failed["error"] as? String == "internal")
        // A queued command that nobody processes expires after 120 seconds.
        let cmds = try await h.repo.commands(deviceID: id, limit: 1)
        let cmd = try #require(cmds.first)
        let later = cmd.createdAt.addingTimeInterval(121)
        let created = try await h.repo.createCommand(deviceID: id, kind: .resetSlot, dryRun: nil, now: cmd.createdAt)
        #expect(created != .pending)
        let claimed = try await h.repo.claimNextCommand(now: later)
        #expect(claimed == nil)
        let expired = try await h.repo.commands(deviceID: id, limit: 5).filter { $0.status == .expired }
        #expect(expired.count == 1)
    }

    @Test func decisionTable() {
        let now = Date()
        func sub(live: Bool = true, enabled: Bool = true, wetSeen: Bool = false, last: Date? = nil) -> PushSubscription {
            PushSubscription(id: subID, gridVersion: 1, cellX: 1, cellY: 1, threshold: 3, leadMinutes: 20, enabled: enabled, lastSentAt: last, liveActivity: live).with(wetSeen: wetSeen)
        }
        func classes(_ values: [Int]) -> [Int] { values + [Int](repeating: values.last ?? 0, count: TimeUtil.forecastSlots - values.count) }
        let dry = classes([0]), onset = classes([0, 0, 0, 4]), wet = classes([4])
        #expect(PushService.decide(sub: sub(enabled: false), classes: onset, hasStartToken: true, activity: nil, now: now) == "not_enabled")
        #expect(PushService.decide(sub: sub(), classes: dry, hasStartToken: true, activity: nil, now: now) == "below_threshold")
        #expect(PushService.decide(sub: sub(), classes: onset, hasStartToken: true, activity: nil, now: now) == "would_trigger")
        #expect(PushService.decide(sub: sub(), classes: onset, hasStartToken: false, activity: nil, now: now) == "no_start_token")
        #expect(PushService.decide(sub: sub(), classes: onset, hasStartToken: true, activity: PushActivity(subscriptionID: subID, activityToken: nil, startedAt: now, endsAt: now), now: now) == "reservation_pending")
        #expect(PushService.decide(sub: sub(), classes: onset, hasStartToken: true, activity: PushActivity(subscriptionID: subID, activityToken: "t", startedAt: now, endsAt: now), now: now) == "activity_slot_busy")
        #expect(PushService.decide(sub: sub(last: now.addingTimeInterval(-600)), classes: onset, hasStartToken: true, activity: nil, now: now) == "lock")
        #expect(PushService.decide(sub: sub(), classes: wet, hasStartToken: true, activity: nil, now: now) == "hysteresis")
        #expect(PushService.decide(sub: sub(wetSeen: true), classes: wet, hasStartToken: true, activity: nil, now: now) == "would_trigger")
        #expect(PushService.decide(sub: sub(live: false), classes: wet, hasStartToken: false, activity: nil, now: now) == "below_threshold")
    }

    @Test func diagnosisChecksAndVerdict() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription(start: false)
        let r = await h.call("GET", "/dash/api/devices/\(id)/diagnosis")
        #expect(r.status == 200 && sameShape(r.json, fixture("diagnosis.start_token_missing.json")).isEmpty, "\(sameShape(r.json, fixture("diagnosis.start_token_missing.json")))")
        let body = try #require(r.json as? [String: Any])
        let checks = try #require(body["checks"] as? [[String: Any]])
        #expect(checks.map { $0["order"] as? Int } == Array(1...9) && checks.map { $0["code"] as? String } ==
                ["server", "environment", "device_token", "start_token", "subscription", "slot", "lock", "trigger", "last_result"])
        #expect((body["verdict"] as? [String: Any])?["code"] as? String == "start_token")
        // Environment not allowed wins as the first critical check.
        var restricted = h.config; restricted.push.environments = [.production]
        let ok = try await Harness()
        _ = ok
        let info = try #require(try await h.repo.deviceInstallInfo(id: id))
        let input = PushDiagnosis.Input(pushEnabled: true, allowedEnvironments: restricted.push.environments, install: info,
                                        subs: try await h.repo.subscriptions(installationID: installID), activities: [:], recentEvents: [],
                                        radar: DeviceRadarView(status: .noSlot), now: Date())
        #expect(PushDiagnosis.run(input).verdict?.code == "environment")
        var disabled = input; disabled.pushEnabled = false
        #expect(PushDiagnosis.run(disabled).verdict?.code == "server")
        var rejected = input
        rejected.recentEvents = [DeviceEvent(at: Date(), kind: "probe", outcome: "rejected", reason: "BadDeviceToken")]
        let last = try #require(PushDiagnosis.run(rejected).checks.last)
        #expect(last.reason == "rejected" && last.params["apnsReason"] == .string("BadDeviceToken"))
    }

    @Test func unlinkingFromTheAppDeletesCommandsAndEvents() async throws {
        let h = try await Harness()
        let id = try await h.link()
        _ = try await h.runCommand(id, "test")
        try await h.repo.unlink(installationID: installID)
        let leftCommands = try await h.repo.commands(deviceID: id, limit: 5)
        let leftEvents = try await h.repo.deviceEvents(deviceID: id, limit: 5)
        #expect(leftCommands.isEmpty && leftEvents.isEmpty)
        // Events are not written for anybody who is not linked.
        try await h.repo.appendDeviceEvent(installationID: installID, kind: "test", outcome: "delivered", reason: nil, now: Date())
        let after = try await h.repo.deviceEvents(deviceID: id, limit: 5)
        #expect(after.isEmpty)
    }
}

extension PushSubscription {
    func with(wetSeen: Bool) -> PushSubscription { var copy = self; copy.wetSeen = wetSeen; return copy }
}
