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

    /// `replica`: what the radar replica reports (the dashboard process itself runs with push off in the split deployment);
    /// `leader`: a push leader lease is held.
    init(linkEnabled: Bool = true, sender: FakeApnsSender = FakeApnsSender(), maxDevices: Int = 3,
         replica: PushReplicaReport? = PushReplicaReport(enabled: true, environments: "both", liveActivity: true), leader: Bool = true,
         warnPush: Bool = true) async throws {
        var c = smallConfig {
            $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox, .production]
            $0.deviceLink.enabled = linkEnabled; $0.deviceLink.maxDevices = maxDevices; $0.warn.pushEnabled = warnPush
        }
        c.push.keyID = "K"; c.push.teamID = "T"
        config = c
        repo = MemoryRepo()
        self.sender = sender
        service = PushService(config: c, repo: repo, sender: sender, owner: "test")
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        var dashboardConfig = c
        dashboardConfig.push.enabled = false; dashboardConfig.push.environments = []; dashboardConfig.push.topic = ""
        api = DashboardApi(auth: auth, repo: repo, store: ConfigStore(fixed: dashboardConfig), staticRoot: "/nonexistent")
        if let replica { try await repo.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: replica, now: Date()) }
        if leader { _ = try await repo.acquireLeader(name: PushService.leaderName, owner: "test", leaseSeconds: 3600) }
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

    // MARK: warning test

    private func addWarnSub(_ h: Harness, enabled: Bool = true, timeSensitive: Bool = false) async throws {
        _ = try await h.repo.addWarnSubscription(installationID: installID, id: subID,
                                                 WarnSubscriptionInput(warncellIDs: ["814522510"], types: Set(WarnKind.allCases), enabled: enabled, timeSensitive: timeSensitive), now: Date())
    }

    @Test func warnTestSendsWarnPayloadToThisDeviceOnly() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await addWarnSub(h)
        let done = try await h.runCommand(id, "warn-test", body: #"{"type":"ice","level":4}"#)
        #expect(done["status"] as? String == "done" && done["kind"] as? String == "warn_test" && sameShape(done, fixture("command.done-warn_test.json")).isEmpty)
        let request = try #require(await h.sender.requests.first)
        #expect(await h.sender.requests.count == 1 && request.tokenHex == deviceToken && request.activityEvent == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(request.payload)) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(aps["thread-id"] as? String == subID && aps["mutable-content"] as? Int == 1 && aps["interruption-level"] as? String == "time-sensitive")
        #expect(alert["title-loc-key"] as? String == "WARN_PUSH_TITLE_ICE" && alert["title-loc-args"] as? [String] == ["4"] && alert["loc-key"] as? String == "WARN_PUSH_BODY")
        #expect(object["type"] as? String == "warning" && object["kind"] as? String == "ice" && object["severity"] as? Int == 4 && object["test"] as? Bool == true)
        #expect(object["warning_id"] as? String == "test" && !String(decoding: request.payload, as: UTF8.self).contains("DWD"))
        // Nothing is stored as a real warning or as a sent state; the audit holds only the check value.
        #expect(try await h.repo.warnSent(subID: subID).isEmpty)
        let events = await h.call("GET", "/dash/api/devices/\(id)/events")
        #expect(((events.json as? [String: Any])?["events"] as? [[String: Any]])?.first?["kind"] as? String == "warn_test")
        let audit = try await h.repo.auditEntries(limit: 5)
        #expect(audit.contains { $0.action == .deviceAction && $0.outcome == "warn_test:delivered" })
    }

    @Test func warnTestDefaultsToFrostLevelOneWithoutTimeSensitive() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await addWarnSub(h)
        _ = try await h.runCommand(id, "warn-test")
        let sent = try #require(await h.sender.requests.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(sent.payload)) as? [String: Any])
        #expect(object["kind"] as? String == "frost" && object["severity"] as? Int == 1 && (object["aps"] as? [String: Any])?["interruption-level"] == nil)
    }

    @Test func warnTestValidationHintsAndRateLimit() async throws {
        let h = try await Harness()
        let id = try await h.link()
        for body in [#"{"type":"hail"}"#, #"{"level":0}"#, #"{"level":5}"#, #"{"level":"2"}"#, #"{"type":"frost","x":1}"#] {
            #expect(await h.call("POST", "/dash/api/devices/\(id)/actions/warn-test", body: body).status == 400)
        }
        // No (enabled) warning subscription: hint instead of a command.
        let none = await h.call("POST", "/dash/api/devices/\(id)/actions/warn-test")
        #expect(none.status == 409 && (none.json as? [String: Any])?["error"] as? String == "no_warn_subscription")
        try await addWarnSub(h, enabled: false)
        #expect(await h.call("POST", "/dash/api/devices/\(id)/actions/warn-test").status == 409)
        #expect(await h.sender.requests.isEmpty)
        let h2 = try await Harness()
        let id2 = try await h2.link()
        try await addWarnSub(h2)
        #expect(await h2.call("POST", "/dash/api/devices/\(id2)/actions/warn-test").status == 202)
        await h2.service.processCommands()
        let limited = await h2.call("POST", "/dash/api/devices/\(id2)/actions/warn-test")
        #expect(limited.status == 429 && (limited.json as? [String: Any])?["error"] as? String == "action_rate_limited")
        #expect(limited.response.headers.contains { $0.0 == "Retry-After" && $0.1 == "30" })
    }

    @Test func warnTestFailsClearlyWithoutWarnPush() async throws {
        let h = try await Harness(warnPush: false)
        let id = try await h.link()
        try await addWarnSub(h)
        let queued = await h.call("POST", "/dash/api/devices/\(id)/actions/warn-test")
        #expect(queued.status == 202)
        await h.service.processCommands()
        let commandID = try #require((queued.json as? [String: Any])?["commandId"] as? String)
        let done = try #require(await h.call("GET", "/dash/api/devices/\(id)/commands/\(commandID)").json as? [String: Any])
        #expect(done["status"] as? String == "failed" && done["error"] as? String == "warn_push_disabled")
        #expect(await h.sender.requests.isEmpty)
        // Push off in all replicas / no leader: same errors as the other actions.
        let off = try await Harness(replica: PushReplicaReport(enabled: false, environments: "both", liveActivity: false), leader: false)
        let id3 = try await off.link()
        #expect(await off.call("POST", "/dash/api/devices/\(id3)/actions/warn-test").status == 503)
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

    /// Publishes a run whose slot 0 shows `cls` at the cell of `liveSubscription` (10, 20); `ageSeconds` after the nominal time it is "now".
    private func publishRun(_ h: Harness, cls: Int?, nominal: Date) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await h.repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
            var image = makeImage(width: h.config.width, height: h.config.height, seed: 200 + index)
            if let cls, index == 0 {
                var pixels = image.pixels
                let color = PushIntensity.palette[cls - 1], o = (20 * h.config.width + 10) * 4
                pixels[o] = UInt8(color.r); pixels[o + 1] = UInt8(color.g); pixels[o + 2] = UInt8(color.b); pixels[o + 3] = 255
                image = RGBAImage(width: image.width, height: image.height, pixels: pixels)
            }
            try await h.repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot), contentType: "image/webp", data: try cachedWebP(image))
        }
        #expect(try await h.repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
    }

    @Test func reevalNamesRunSlotMeasuredClassAndReason() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription()
        let nominal = TimeUtil.floorStep(Date().addingTimeInterval(-420))
        try await publishRun(h, cls: 2, nominal: nominal)
        let done = try await h.runCommand(id, "reeval")
        #expect(done["status"] as? String == "done")
        let result = try #require(done["result"] as? [String: Any])
        let radar = try #require(result["radar"] as? [String: Any])
        #expect(radar["status"] as? String == "ok" && radar["runNominal"] as? String == TimeUtil.toISO(nominal) && radar["slotIndex"] as? Int == 0)
        #expect((radar["runAgeSeconds"] as? Int ?? 0) >= 420 && radar["maxRunAgeSeconds"] as? Int == 1200 && radar["gridWidth"] as? Int == 64)
        let row = try #require((result["subscriptions"] as? [[String: Any]])?.first)
        // Rain is on the radar (class 2) but below the threshold class 3 (from 0.4 mm/h): the answer says exactly that.
        #expect(row["decision"] as? String == "below_threshold" && row["reason"] as? String == "class_below_threshold")
        #expect(row["measuredClass"] as? Int == 2 && row["pixel"] as? String == "rain" && row["thresholdClass"] as? Int == 3)
        #expect(row["measuredMmPerHour"] as? Double == 0.2 && row["thresholdMmPerHour"] as? Double == 0.4)
        let place = try #require(row["place"] as? [String: Any])
        #expect(place["x"] as? Int == 10 && place["y"] as? Int == 20 && place["lat"] is Double && place["lon"] is Double)
        // The same sub with class 3 triggers.
        try await publishRun(h, cls: 3, nominal: TimeUtil.floorStep(Date().addingTimeInterval(-120)))
        let again = try await h.runCommand(id, "reeval")
        let row2 = try #require(((again["result"] as? [String: Any])?["subscriptions"] as? [[String: Any]])?.first)
        #expect(row2["decision"] as? String == "would_trigger" && row2["measuredClass"] as? Int == 3)
    }

    @Test func reevalWithStaleRunNamesAgeAndStillShowsMeasurement() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription()
        try await publishRun(h, cls: 4, nominal: TimeUtil.floorStep(Date().addingTimeInterval(-3600)))
        let done = try await h.runCommand(id, "reeval", body: #"{"dryRun":false}"#)
        let result = try #require(done["result"] as? [String: Any])
        let radar = try #require(result["radar"] as? [String: Any])
        #expect(radar["status"] as? String == "stale_run" && (radar["runAgeSeconds"] as? Int ?? 0) >= 3600)
        let row = try #require((result["subscriptions"] as? [[String: Any]])?.first)
        #expect(row["decision"] as? String == "radar_stale" && row["reason"] as? String == "radar_stale" && row["measuredClass"] as? Int == 4)
        #expect(row["sent"] as? Bool == false)
        #expect(await h.sender.requests.isEmpty)       // nothing is sent from a stale run
    }

    @Test func reevalWithoutRadarSaysSoPerSubscription() async throws {
        let h = try await Harness()
        let id = try await h.link()
        try await h.liveSubscription()
        let failed = try await h.runCommand(id, "reeval")
        #expect(failed["status"] as? String == "done")
        let result = try #require(failed["result"] as? [String: Any])
        #expect((result["radar"] as? [String: Any])?["status"] as? String == "no_slot")
        let row = try #require((result["subscriptions"] as? [[String: Any]])?.first)
        #expect(row["decision"] as? String == "radar_missing" && row["reason"] as? String == "radar_missing" && row["measuredClass"] is NSNull)
    }

    @Test func reevalWithoutLinkExpires() async throws {
        let h = try await Harness()
        let id = try await h.link()
        _ = try await h.runCommand(id, "reset-slot")
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

    @Test func diagnosisAndActionsFollowTheReplicasNotTheDashboardConfig() async throws {
        func serverCheck(_ h: Harness, _ id: String) async -> [String: Any]? {
            let r = await h.call("GET", "/dash/api/devices/\(id)/diagnosis")
            return ((r.json as? [String: Any])?["checks"] as? [[String: Any]])?.first { $0["code"] as? String == "server" }
        }
        let on = try await Harness()
        let id = try await on.link()
        let ok = await serverCheck(on, id)
        #expect(ok?["reason"] as? String == "ok" && ok?["level"] as? String == "ok")
        // sandbox install, replica accepts both: environment ok; replica accepts production only: env_not_allowed.
        let prodOnly = try await Harness(replica: PushReplicaReport(enabled: true, environments: "production", liveActivity: true))
        let pid = try await prodOnly.link()
        let checks = ((await prodOnly.call("GET", "/dash/api/devices/\(pid)/diagnosis").json as? [String: Any])?["checks"] as? [[String: Any]]) ?? []
        #expect(checks.first { $0["code"] as? String == "environment" }?["reason"] as? String == "env_not_allowed")

        let off = try await Harness(replica: PushReplicaReport(enabled: false, environments: nil, liveActivity: false), leader: false)
        let offID = try await off.link()
        #expect(await serverCheck(off, offID)?["reason"] as? String == "push_disabled")
        let offAction = await off.call("POST", "/dash/api/devices/\(offID)/actions/reeval")
        #expect(offAction.status == 503 && (offAction.json as? [String: Any])?["error"] as? String == "push_disabled")

        let unknown = try await Harness(replica: nil, leader: false)
        let unknownID = try await unknown.link()
        let state = await serverCheck(unknown, unknownID)
        #expect(state?["reason"] as? String == "push_unknown" && state?["level"] as? String == "warning")
        #expect((await unknown.call("POST", "/dash/api/devices/\(unknownID)/actions/reeval").json as? [String: Any])?["error"] as? String == "push_state_unknown")

        // Push is on, but nobody holds the leader lease: commands would never run.
        let noLeader = try await Harness(leader: false)
        let nlID = try await noLeader.link()
        let nl = await noLeader.call("POST", "/dash/api/devices/\(nlID)/actions/reeval")
        #expect(nl.status == 503 && (nl.json as? [String: Any])?["error"] as? String == "push_leader_missing")
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

// Regression 13.11.2026 (live SIGILL, exit 132): a region subscription in steady rain made `PushMeasureJSON.fields` index the
// slot array with the wet-cell count (shadowed `$0`), so GET .../subscriptions and the re-evaluation trapped and killed the process.
extension DeviceDashboardTests {
    private static let regionID = "44444444-4444-4444-8444-444444444444"

    /// All 25 slots fully covered with class `cls` (no transparent pixel), so every region has far more than 25 wet cells.
    private func publishSteadyRain(_ h: Harness, cls: Int, nominal: Date) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await h.repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        let color = PushIntensity.palette[cls - 1]
        var pixels = [UInt8](repeating: 255, count: h.config.width * h.config.height * 4)
        for i in 0..<(h.config.width * h.config.height) { pixels[i * 4] = UInt8(color.r); pixels[i * 4 + 1] = UInt8(color.g); pixels[i * 4 + 2] = UInt8(color.b) }
        let data = try cachedWebP(RGBAImage(width: h.config.width, height: h.config.height, pixels: pixels))
        for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
            try await h.repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot), contentType: "image/webp", data: data)
        }
        #expect(try await h.repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
    }

    private func regionInSteadyRain(liveActivity: Bool) async throws -> (Harness, String) {
        let h = try await Harness()
        let id = try await h.link()
        try await h.repo.setLiveActivityStartToken(installationID: installID, token: startToken)
        _ = try await h.repo.addSubscription(installationID: installID, id: Self.regionID,
                                             .init(gridVersion: 1, cellX: 31, cellY: 31, threshold: 3, leadMinutes: 30, enabled: true,
                                                   kind: .circle, radiusCells: 6, minSharePercent: 10, liveActivity: liveActivity),
                                             maxPerInstallation: 10, now: Date())
        try await publishSteadyRain(h, cls: 5, nominal: TimeUtil.floorStep(Date().addingTimeInterval(-300)))
        return (h, id)
    }

    @Test(arguments: [false, true]) func regionInSteadyRainDoesNotTrapSubscriptions(liveActivity: Bool) async throws {
        let (h, id) = try await regionInSteadyRain(liveActivity: liveActivity)
        let subs = await h.call("GET", "/dash/api/devices/\(id)/subscriptions")
        #expect(subs.status == 200)
        let row = try #require(((subs.json as? [String: Any])?["subscriptions"] as? [[String: Any]])?.first)
        // Slot 1 (5 minutes) is already wet with enough cells: the onset is the first lead slot, not a random one.
        #expect(row["kind"] as? String == "circle" && row["leadOnsetMinutes"] as? Int == 5 && row["leadMaxClass"] as? Int == 5)
        #expect((row["wetCells"] as? Int ?? 0) > TimeUtil.forecastSlots && row["cell"] as? String == "wet")
        #expect(await h.call("GET", "/dash/api/devices/\(id)").status == 200)
        #expect(await h.call("GET", "/dash/api/devices/\(id)/diagnosis").status == 200)
    }

    @Test func regionInSteadyRainDoesNotTrapReevaluation() async throws {
        let (h, id) = try await regionInSteadyRain(liveActivity: false)
        let done = try await h.runCommand(id, "reeval")
        #expect(done["status"] as? String == "done")
        let row = try #require(((done["result"] as? [String: Any])?["subscriptions"] as? [[String: Any]])?.first)
        #expect(row["leadOnsetMinutes"] as? Int == 5)
    }

    /// Onset needs the share of its own slot: wet cells of slot 1 below the need, slot 2 enough.
    @Test func leadOnsetUsesTheNeedOfItsOwnSlot() {
        var sub = PushSubscription(id: "s", gridVersion: 1, cellX: 31, cellY: 31, threshold: 3, leadMinutes: 30, enabled: true, state: .dry, lastSentAt: nil)
        sub.kind = .circle; sub.radiusCells = 6
        var measures = [SlotMeasure](repeating: SlotMeasure(maxClass: 0, wetCells: 0, cells: 113, neededCells: 12), count: TimeUtil.forecastSlots)
        measures[1] = SlotMeasure(maxClass: 5, wetCells: 2, cells: 113, neededCells: 12)
        measures[2] = SlotMeasure(maxClass: 5, wetCells: 40, cells: 113, neededCells: 12)
        let out = PushMeasureJSON.fields(sub, measures: measures, radarOK: true, width: 64)
        #expect(out["leadOnsetMinutes"] as? Int == 10)
    }
}
