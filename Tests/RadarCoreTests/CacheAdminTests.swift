import Foundation
import Testing
@testable import RadarCore

// Operator cache tools and device subscriptions (Erweiterung 6. November 2026): contract shape against docs/fixtures/dashboard,
// refresh jobs with the replica worker, privacy of the answers. Memory repository, no network.
private let origin = "https://dash.example.test"
private let installID = "11111111-1111-4111-8111-111111111111"
private let secretHash = Hashing.sha256Hex(Array(String(repeating: "a", count: 40).utf8))
private let deviceToken = String(repeating: "ab", count: 32)
private let subID = "33333333-3333-4333-8333-333333333333"
private let circleID = "44444444-4444-4444-8444-444444444444"
private let cell = (x: 40, y: 50)

private func fixture(_ name: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "docs/fixtures/dashboard/" + name)))) ?? "missing fixture \(name)"
}

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

private struct Rig {
    let api: DashboardApi
    let repo: MemoryRepo
    let config: Config
    let cookie: String
    let csrf: String
    let auth: DashboardAuth

    init(layers: [String] = ["lightning"], replica: Bool = true, snapshot: SlotCacheSnapshot? = nil) async throws {
        var c = smallConfig {
            $0.width = 64; $0.layers = layers
            $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox, .production]
            $0.deviceLink.enabled = true; $0.deviceLink.maxDevices = 3
        }
        c.push.keyID = "K"; c.push.teamID = "T"
        config = c
        repo = MemoryRepo()
        auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        api = DashboardApi(auth: auth, repo: repo, store: ConfigStore(fixed: c), staticRoot: "/nonexistent", processCache: { snapshot })
        if replica { try await repo.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: PushReplicaReport(enabled: true, environments: "both", liveActivity: true), now: Date()) }
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        cookie = "__Host-dash_session=" + created.cookieValue
        csrf = created.csrfToken
    }

    func call(_ method: String, _ path: String, query: [String: String] = [:], body: String = "{}", session: Bool = true) async -> (status: Int, json: Any, response: ApiResponse) {
        let write = method != "GET"
        let info = DashboardRequestInfo(method: method, cookieHeader: session ? cookie : nil, origin: write ? origin : nil, host: "dash.example.test",
                                        contentType: write ? "application/json" : nil, csrfToken: session ? csrf : nil)
        let r = await api.handle(DashboardHTTPRequest(method: method, path: path, query: query, body: Array(body.utf8), info: info))
        return (r.status, (try? JSONSerialization.jsonObject(with: Data(r.body))) ?? NSNull(), r)
    }

    func header(_ r: ApiResponse, _ name: String) -> String? { r.headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

    func publishRadar(_ nominal: Date, owner: String = "t", slotsPerRun: Int = TimeUtil.forecastSlots, type: String = "image/webp", size: Int = 100) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: owner, leaseSeconds: 60, maxAttempts: 2))
        for (index, slot) in TimeUtil.slots(of: nominal).prefix(slotsPerRun).enumerated() {
            try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot), contentType: type, data: [UInt8](repeating: UInt8(index), count: size))
        }
        #expect(try await repo.publish(runID: id, owner: owner, expectedSlots: slotsPerRun))
    }

    func publishLayerSlot(_ layer: String, _ slot: Date, type: String = "image/webp", size: Int = 80) async throws {
        let id = TimeUtil.toID(slot)
        #expect(try await repo.layerTryClaim(layer: layer, runID: id, nominal: slot, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        try await repo.layerPutSlot(layer: layer, SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: slot), contentType: type, data: [UInt8](repeating: 7, count: size))
        #expect(try await repo.layerPublish(layer: layer, runID: id, owner: "t", expectedSlots: 1))
    }

    /// A radar run in which the test cell turns wet at slot `onset` (nil = dry), with `level` as intensity class.
    func publishWet(_ nominal: Date, onset: Int?, wetNow: Bool = false, level: Int = 3) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        let color = PushIntensity.palette[level - 1]
        for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
            var image = makeImage(width: config.width, height: config.height, seed: 200 + index)
            if (index == 0 && wetNow) || (onset.map { index >= $0 } ?? false) {
                let o = (cell.y * config.width + cell.x) * 4
                var pixels = image.pixels
                pixels[o] = UInt8(color.r); pixels[o + 1] = UInt8(color.g); pixels[o + 2] = UInt8(color.b); pixels[o + 3] = 255
                image = RGBAImage(width: image.width, height: image.height, pixels: pixels)
            }
            try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot), contentType: "image/webp", data: try cachedWebP(image))
        }
        #expect(try await repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
    }

    @discardableResult func linkDevice() async throws -> String {
        _ = try await repo.upsertInstallation(id: installID, secretHash: secretHash, token: deviceToken, env: .sandbox, locale: "de", now: Date(), maxInstallations: 10)
        let hash = LinkCode.hash("2345ABCD")
        #expect(try await repo.createLinkCode(installationID: installID, codeHash: hash, attested: true, now: Date(), ttl: 600, maxDevices: 9) == .created)
        let id = UUID().uuidString.lowercased()
        guard case .paired = try await repo.pairDevice(codeHash: hash, label: "Mein iPhone", deviceID: id, now: Date(), maxDevices: 9, ttlDays: 0) else { Issue.record("pairing failed"); return id }
        return id
    }
}

private func recent(_ minutesAgo: Int = 12) -> Date { TimeUtil.floorStep(Date().addingTimeInterval(-Double(minutesAgo) * 60)) }

@Suite("Dashboard subscriptions of a device")
struct DeviceSubscriptionsTests {
    @Test func unknownDeviceAndNoSession() async throws {
        let rig = try await Rig()
        #expect(await rig.call("GET", "/dash/api/devices/\(UUID().uuidString.lowercased())/subscriptions").status == 404)
        let id = try await rig.linkDevice()
        #expect(await rig.call("GET", "/dash/api/devices/\(id)/subscriptions", session: false).status == 401)
    }

    @Test func emptyAndRadarMissing() async throws {
        let rig = try await Rig()
        let id = try await rig.linkDevice()
        let empty = await rig.call("GET", "/dash/api/devices/\(id)/subscriptions")
        #expect(empty.status == 200)
        #expect(sameShape(empty.json, fixture("device-subscriptions.empty.json")).isEmpty)
        _ = try await rig.repo.addSubscription(installationID: installID, id: subID, .init(gridVersion: 1, cellX: cell.x, cellY: cell.y, threshold: 3, leadMinutes: 20, enabled: true), maxPerInstallation: 10, now: Date())
        let r = await rig.call("GET", "/dash/api/devices/\(id)/subscriptions")
        let json = try #require(r.json as? [String: Any])
        #expect((json["radar"] as? [String: Any])?["status"] as? String == "no_slot")
        let sub = try #require((json["subscriptions"] as? [[String: Any]])?.first)
        #expect(sub["cell"] as? String == "unknown" && sub["leadCell"] as? String == "unknown")
        #expect(sameShape(r.json, fixture("device-subscriptions.radar-unknown.json")).isEmpty)
    }

    @Test func cellStateFollowsRadarAndShapeMatchesFixture() async throws {
        let rig = try await Rig()
        let id = try await rig.linkDevice()
        try await rig.repo.setLiveActivityStartToken(installationID: installID, token: String(repeating: "cd", count: 32))
        _ = try await rig.repo.addSubscription(installationID: installID, id: subID, .init(gridVersion: 1, cellX: cell.x, cellY: cell.y, threshold: 3, leadMinutes: 20, enabled: true, liveActivity: true), maxPerInstallation: 10, now: Date())
        _ = try await rig.repo.addSubscription(installationID: installID, id: circleID, .init(gridVersion: 1, cellX: 10, cellY: 10, threshold: 3, leadMinutes: 30, enabled: true, timeSensitive: true, kind: .circle, radiusCells: 6, minSharePercent: 20), maxPerInstallation: 10, now: Date())
        try await rig.publishWet(recent(), onset: 2)        // dry now, wet within 10 minutes -> inside the 20 minute lead
        var r = await rig.call("GET", "/dash/api/devices/\(id)/subscriptions")
        var json = try #require(r.json as? [String: Any])
        #expect((json["radar"] as? [String: Any])?["status"] as? String == "ok")
        var subs = try #require(json["subscriptions"] as? [[String: Any]])
        #expect(subs.count == 2)
        #expect(subs[0]["cell"] as? String == "dry" && subs[0]["leadCell"] as? String == "wet")
        #expect(subs[0]["kind"] as? String == "point" && subs[0]["radiusCells"] is NSNull)
        #expect(subs[1]["kind"] as? String == "circle" && subs[1]["radiusCells"] as? Int == 6 && subs[1]["minSharePercent"] as? Int == 20)
        #expect(sameShape(r.json, fixture("device-subscriptions.200.json")).isEmpty)
        try await rig.publishWet(recent(7), onset: nil, wetNow: true)
        r = await rig.call("GET", "/dash/api/devices/\(id)/subscriptions")
        json = try #require(r.json as? [String: Any])
        subs = try #require(json["subscriptions"] as? [[String: Any]])
        #expect(subs[0]["cell"] as? String == "wet")
    }

    @Test func answerHasNoIdentifiersTokensOrCells() async throws {
        let rig = try await Rig()
        let id = try await rig.linkDevice()
        _ = try await rig.repo.addSubscription(installationID: installID, id: subID, .init(gridVersion: 1, cellX: 41, cellY: 52, threshold: 3, leadMinutes: 20, enabled: true), maxPerInstallation: 10, now: Date())
        let body = String(decoding: await rig.call("GET", "/dash/api/devices/\(id)/subscriptions").response.body, as: UTF8.self)
        for secret in [installID, subID, deviceToken, "cellX", "cellY", "latitude", "longitude"] { #expect(!body.contains(secret)) }
        // The place of the operator's own linked device is shown as a rounded cell centre and the cell indices (decisions.md, 7 Nov 2026).
        let place = try #require(((await rig.call("GET", "/dash/api/devices/\(id)/subscriptions").json as? [String: Any])?["subscriptions"] as? [[String: Any]])?.first?["place"] as? [String: Any])
        #expect(place["x"] as? Int == 41 && place["y"] as? Int == 52 && place["lat"] is Double && place["lon"] is Double)
    }
}

@Suite("Dashboard cache tools")
struct CacheToolsTests {
    @Test func inventoryPerLayerWithStatesAndProcessCache() async throws {
        let rig = try await Rig(layers: ["lightning", "pressure"], snapshot: SlotCacheSnapshot(bytes: 1000, entries: 5, maxBytes: 5000))
        try await rig.publishRadar(recent(), slotsPerRun: TimeUtil.forecastSlots, size: 10)
        try await rig.publishLayerSlot("lightning", recent(30))
        try await rig.publishLayerSlot("lightning", recent(25))
        try await rig.repo.reportCacheFill(replicaID: "radar-1", fill: ReplicaCacheFill(bytes: 300, entries: 2, maxBytes: 9000), now: Date())
        let r = await rig.call("GET", "/dash/api/cache")
        #expect(r.status == 200)
        #expect(sameShape(r.json, fixture("cache.200.json")).isEmpty)
        let json = try #require(r.json as? [String: Any])
        let layers = try #require(json["layers"] as? [[String: Any]])
        #expect(layers.map { $0["id"] as? String } == ["radar", "pressure", "pressure_eu", "lightning", "clouds", "cloudmask", "cloudmask_vis", "cloudmask_vis_eu"])
        let radar = layers[0], lightning = layers.first { $0["id"] as? String == "lightning" }!
        #expect(radar["runs"] as? Int == 1 && radar["slots"] as? Int == TimeUtil.forecastSlots && radar["bytes"] as? Int == TimeUtil.forecastSlots * 10)
        #expect(radar["state"] as? String == "current" && radar["lastAttemptResult"] as? String == "ok")
        #expect(lightning["runs"] as? Int == 2 && lightning["slots"] as? Int == 2 && lightning["bytes"] as? Int == 160)
        #expect(lightning["spanSeconds"] as? Int == 300)
        #expect(layers.first { $0["id"] as? String == "pressure" }?["state"] as? String == "empty")
        #expect(layers.first { $0["id"] as? String == "clouds" }?["state"] as? String == "disabled")
        let process = try #require(json["process"] as? [String: Any])
        #expect(process["bytes"] as? Int == 1000 && process["scope"] as? String == "thisReplica")
        let replica = try #require((json["replicas"] as? [[String: Any]])?.first)
        #expect(replica["cacheBytes"] as? Int == 300 && replica["id"] as? String == DashboardApi.shortID("radar-1"))
        #expect(!String(decoding: r.response.body, as: UTF8.self).contains("radar-1"))
    }

    @Test func stateRule() {
        func s(_ age: Int?, failed: Bool = false, enabled: Bool = true, data: Bool = true) -> String {
            DashboardCache.state(enabled: enabled, hasData: data, ageSeconds: age, cadence: 300, lastAttemptFailed: failed)
        }
        #expect(s(100) == "current" && s(900) == "current" && s(901) == "stale" && s(901, failed: true) == "failed")
        #expect(s(3600) == "stale" && s(3600, failed: true) == "failed" && s(3601) == "failed" && s(4000, failed: false) == "failed")
        #expect(s(nil, data: false) == "empty" && s(nil, enabled: false, data: false) == "disabled" && s(10, enabled: false) == "disabled")
    }

    @Test func slotListPagesWithoutLosingTies() async throws {
        let rig = try await Rig()
        // Two radar runs five minutes apart share their slot times (slot k of run B = slot k+1 of run A).
        let a = recent(60), b = a.addingTimeInterval(300)
        try await rig.publishRadar(a, size: 5)
        try await rig.publishRadar(b, size: 6)
        var seen: [String] = []
        var before: String?
        var pages = 0
        while pages < 40 {
            var query = ["limit": "7"]
            if let before { query["before"] = before }
            let r = await rig.call("GET", "/dash/api/cache/radar/slots", query: query)
            #expect(r.status == 200)
            let json = try #require(r.json as? [String: Any])
            for row in try #require(json["slots"] as? [[String: Any]]) { seen.append("\(row["slot"]!)|\(row["run"]!)") }
            pages += 1
            guard let next = json["next"] as? String else { break }
            before = next
        }
        #expect(seen.count == TimeUtil.forecastSlots * 2)
        #expect(Set(seen).count == seen.count)
        let first = await rig.call("GET", "/dash/api/cache/radar/slots", query: ["limit": "2"])
        #expect(sameShape(first.json, fixture("cache-slots.200.json")).isEmpty)
        let last = await rig.call("GET", "/dash/api/cache/lightning/slots")
        #expect(sameShape(last.json, fixture("cache-slots.last-page.json")).isEmpty)
        #expect(await rig.call("GET", "/dash/api/cache/nope/slots").status == 404)
        #expect(await rig.call("GET", "/dash/api/cache/radar/slots", query: ["limit": "0"]).status == 400)
        #expect(await rig.call("GET", "/dash/api/cache/radar/slots", query: ["before": "gestern"]).status == 400)
    }

    @Test func previewServesOnlyOwnImagesWithSafeHeaders() async throws {
        let rig = try await Rig()
        let nominal = recent()
        try await rig.publishRadar(nominal, size: 50)
        let slot = TimeUtil.toISO(TimeUtil.slots(of: nominal)[3])
        let ok = await rig.call("GET", "/dash/api/cache/radar/preview", query: ["slot": slot])
        #expect(ok.status == 200 && ok.response.body.count == 50 && ok.response.body.allSatisfy { $0 == 3 })
        #expect(rig.header(ok.response, "Content-Type") == "image/webp")
        #expect(rig.header(ok.response, "Cache-Control") == "private, no-store")
        #expect(rig.header(ok.response, "X-Content-Type-Options") == "nosniff")
        #expect(rig.header(ok.response, "Content-Security-Policy") == "default-src 'none'")
        let withRun = await rig.call("GET", "/dash/api/cache/radar/preview", query: ["slot": slot, "run": TimeUtil.toISO(nominal)])
        #expect(withRun.status == 200)
        #expect(await rig.call("GET", "/dash/api/cache/radar/preview", query: ["slot": slot], session: false).status == 401)
        #expect(await rig.call("GET", "/dash/api/cache/radar/preview").status == 400)
        #expect(await rig.call("GET", "/dash/api/cache/radar/preview", query: ["slot": "x"]).status == 400)
        #expect(await rig.call("GET", "/dash/api/cache/bogus/preview", query: ["slot": slot]).status == 404)
        #expect(await rig.call("GET", "/dash/api/cache/radar/preview", query: ["slot": TimeUtil.toISO(nominal.addingTimeInterval(-86400))]).status == 404)
        #expect(await rig.call("GET", "/dash/api/cache/radar/preview", query: ["slot": slot, "run": TimeUtil.toISO(nominal.addingTimeInterval(-300))]).status == 404)
    }

    @Test func previewRejectsForeignTypesAndHugeImages() async throws {
        let rig = try await Rig()
        let html = recent(40), big = recent(35), unpublished = recent(30)
        try await rig.publishLayerSlot("lightning", html, type: "text/html")
        try await rig.publishLayerSlot("lightning", big, size: DashboardCache.previewMaxBytes + 1)
        let id = TimeUtil.toID(unpublished)
        _ = try await rig.repo.layerTryClaim(layer: "lightning", runID: id, nominal: unpublished, owner: "t", leaseSeconds: 60, maxAttempts: 2)
        try await rig.repo.layerPutSlot(layer: "lightning", SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: unpublished), contentType: "image/webp", data: [1])
        func status(_ d: Date) async -> Int { await rig.call("GET", "/dash/api/cache/lightning/preview", query: ["slot": TimeUtil.toISO(d)]).status }
        #expect(await status(html) == 415)
        #expect(await status(big) == 413)
        #expect(await status(unpublished) == 404)
        // The list still shows the unpublished slot, flagged.
        let list = try #require((await rig.call("GET", "/dash/api/cache/lightning/slots").json as? [String: Any])?["slots"] as? [[String: Any]])
        #expect(list.first { $0["slot"] as? String == TimeUtil.toISO(unpublished) }?["published"] as? Bool == false)
    }
}

@Suite("Dashboard cache refresh")
struct CacheRefreshTests {
    private func body(_ layer: String) -> String { "{\"layer\":\"\(layer)\"}" }

    @Test func createsJobAuditsAndPolls() async throws {
        let rig = try await Rig()
        let r = await rig.call("POST", "/dash/api/cache/refresh", body: body("radar"))
        #expect(r.status == 202)
        #expect(sameShape(r.json, fixture("cache-refresh.202.json")).isEmpty)
        let job = try #require(((r.json as? [String: Any])?["jobs"] as? [[String: Any]])?.first)
        let id = try #require(job["id"] as? String)
        #expect(job["layer"] as? String == "radar" && job["status"] as? String == "queued")
        let one = await rig.call("GET", "/dash/api/cache/refresh/\(id)")
        #expect(one.status == 200 && (one.json as? [String: Any])?["status"] as? String == "queued")
        let list = await rig.call("GET", "/dash/api/cache/refresh")
        #expect(sameShape(list.json, fixture("cache-refresh-list.200.json")).isEmpty)
        let audit = try await rig.repo.auditEntries(limit: 5)
        #expect(audit.first?.action == .cacheRefresh && audit.first?.outcome == "radar")
        #expect(await rig.call("GET", "/dash/api/cache/refresh/not-a-uuid").status == 404)
        #expect(await rig.call("GET", "/dash/api/cache/refresh/\(UUID().uuidString.lowercased())").status == 404)
        #expect(await rig.call("GET", "/dash/api/cache/refresh", query: ["limit": "31"]).status == 400)
    }

    @Test func validationConflictsAndMissingReplica() async throws {
        let bad = try await Rig(layers: ["lightning"])
        #expect(await bad.call("POST", "/dash/api/cache/refresh", body: "{}").status == 400)
        #expect(await bad.call("POST", "/dash/api/cache/refresh", body: "{\"layer\":\"nope\"}").status == 400)
        #expect(await bad.call("POST", "/dash/api/cache/refresh", body: "{\"layer\":\"radar\",\"x\":1}").status == 400)
        #expect(await bad.call("POST", "/dash/api/cache/refresh", body: "{\"layer\":5}").status == 400)
        let rig = try await Rig(layers: ["lightning"])
        let disabled = await rig.call("POST", "/dash/api/cache/refresh", body: body("clouds"))
        #expect(disabled.status == 409 && (disabled.json as? [String: String])?["error"] == "layer_disabled")
        #expect(await rig.call("POST", "/dash/api/cache/refresh", body: body("lightning")).status == 202)
        let pending = await rig.call("POST", "/dash/api/cache/refresh", body: body("lightning"))
        #expect(pending.status == 409 && (pending.json as? [String: String])?["error"] == "refresh_pending")
        // "all": radar is new, lightning is pending and skipped.
        let all = await rig.call("POST", "/dash/api/cache/refresh", body: body("all"))
        #expect(all.status == 202 && ((all.json as? [String: Any])?["jobs"] as? [[String: Any]])?.map { $0["layer"] as? String } == ["radar"])
        #expect(await rig.call("POST", "/dash/api/cache/refresh", body: body("all")).status == 409)
        // CSRF and session are required.
        #expect(await rig.call("POST", "/dash/api/cache/refresh", body: body("radar"), session: false).status == 401)
        let none = try await Rig(replica: false)
        let down = await none.call("POST", "/dash/api/cache/refresh", body: body("radar"))
        #expect(down.status == 503 && (down.json as? [String: String])?["error"] == "ingest_unavailable")
    }

    @Test func allCoversRadarAndEnabledLayers() async throws {
        let rig = try await Rig(layers: ["lightning", "pressure"])
        let r = await rig.call("POST", "/dash/api/cache/refresh", body: body("all"))
        let layers = ((r.json as? [String: Any])?["jobs"] as? [[String: Any]])?.compactMap { $0["layer"] as? String }
        #expect(layers == ["radar", "pressure", "lightning"])
    }

    @Test func rateLimitSixPerMinute() async throws {
        let rig = try await Rig()
        var statuses: [Int] = []
        for _ in 0..<8 {
            let r = await rig.call("POST", "/dash/api/cache/refresh", body: "{\"layer\":\"nope\"}")   // 400 counts, nothing is created
            statuses.append(r.status)
        }
        #expect(statuses.prefix(6).allSatisfy { $0 == 400 } && statuses.suffix(2).allSatisfy { $0 == 429 })
    }

    @Test func workerRunsJobsAndReportsFixedCodes() async throws {
        let rig = try await Rig(layers: ["lightning"])
        let outcomes = Locked<[String: Result<CacheRefreshWorker.Outcome, Error>]>([
            "radar": .success(.init(stored: 25, failed: 0, published: true)),
            "lightning": .failure(RunUnavailable(description: "x")),
        ])
        let worker = CacheRefreshWorker(repo: rig.repo, configProvider: ConfigProvider(rig.config), fetch: { _ in [] }, owner: "radar-1",
                                        executor: { layer in try outcomes.withLock { $0[layer]! }.get() })
        _ = await rig.call("POST", "/dash/api/cache/refresh", body: body("all"))
        await worker.processJobs(maxJobs: 5)
        let jobs = try #require((await rig.call("GET", "/dash/api/cache/refresh").json as? [String: Any])?["jobs"] as? [[String: Any]])
        let radar = try #require(jobs.first { $0["layer"] as? String == "radar" })
        let lightning = try #require(jobs.first { $0["layer"] as? String == "lightning" })
        #expect(radar["status"] as? String == "ok" && (radar["result"] as? [String: Any])?["stored"] as? Int == 25)
        #expect(sameShape(radar, fixture("cache-refresh.done-ok.json")).isEmpty)
        #expect(lightning["status"] as? String == "failed" && lightning["error"] as? String == "source_unavailable")
        #expect(sameShape(lightning, fixture("cache-refresh.failed.json")).isEmpty)
        // Free again afterwards.
        #expect(await rig.call("POST", "/dash/api/cache/refresh", body: body("lightning")).status == 202)
    }

    @Test func tickThatOnlyFailedSlotsFailsAndImageErrorsAreIncomplete() async throws {
        let rig = try await Rig(layers: ["lightning"])
        let mode = Locked(0)
        let worker = CacheRefreshWorker(repo: rig.repo, configProvider: ConfigProvider(rig.config), fetch: { _ in [] }, owner: "radar-1",
                                        executor: { _ in
            if mode.withLock({ $0 }) == 0 { return .init(stored: 0, failed: 3, published: false) }
            if mode.withLock({ $0 }) == 1 { throw ImageError.invalid("incomplete image") }
            return .init(stored: 0, failed: 0, published: false)
        })
        func run() async throws -> [String: Any] {
            let r = await rig.call("POST", "/dash/api/cache/refresh", body: body("lightning"))
            let id = try #require(((r.json as? [String: Any])?["jobs"] as? [[String: Any]])?.first?["id"] as? String)
            await worker.processJobs()
            return try #require(await rig.call("GET", "/dash/api/cache/refresh/\(id)").json as? [String: Any])
        }
        #expect(try await run()["error"] as? String == "source_unavailable")
        mode.withLock { $0 = 1 }
        #expect(try await run()["error"] as? String == "incomplete")
        mode.withLock { $0 = 2 }
        let nothing = try await run()
        #expect(nothing["status"] as? String == "ok" && (nothing["result"] as? [String: Any])?["stored"] as? Int == 0)
    }

    @Test func layerJobWaitsForTheLeaderAndDisabledLayerFails() async throws {
        let rig = try await Rig(layers: ["lightning"])
        let ran = Locked<[String]>([])
        func worker(_ owner: String, layers: [String]) -> CacheRefreshWorker {
            var c = rig.config; c.layers = layers
            return CacheRefreshWorker(repo: rig.repo, configProvider: ConfigProvider(c), fetch: { _ in [] }, owner: owner,
                                      executor: { layer in ran.withLock { $0.append(layer) }; return .init(stored: 1, failed: 0, published: true) })
        }
        _ = try await rig.repo.acquireLeader(name: "layer:lightning", owner: "other", leaseSeconds: 600)
        _ = await rig.call("POST", "/dash/api/cache/refresh", body: body("lightning"))
        await worker("me", layers: ["lightning"]).processJobs()
        #expect(ran.withLock { $0 }.isEmpty)       // not the leader: left for the leader
        try await rig.repo.releaseLeader(name: "layer:lightning", owner: "other")
        await worker("me", layers: ["lightning"]).processJobs()
        #expect(ran.withLock { $0 } == ["lightning"])
        // A replica whose configuration switched the layer off fails the job with a clear code.
        _ = await rig.call("POST", "/dash/api/cache/refresh", body: body("lightning"))
        await worker("me", layers: []).processJobs()
        let jobs = try #require((await rig.call("GET", "/dash/api/cache/refresh").json as? [String: Any])?["jobs"] as? [[String: Any]])
        #expect(jobs.first?["error"] as? String == "layer_disabled" && ran.withLock { $0 } == ["lightning"])
    }

    @Test func staleJobsExpireAndTimeOut() async throws {
        let repo = MemoryRepo()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let created = try await repo.createRefreshJobs(layers: ["radar", "clouds"], now: t0)
        #expect(created.created.count == 2)
        // radar is taken and never finished; clouds is never taken.
        _ = try await repo.claimRefreshJob(layer: "radar", now: t0.addingTimeInterval(1))
        #expect(try await repo.queuedRefreshLayers(now: t0.addingTimeInterval(130)) == [])
        #expect(try await repo.refreshJob(id: created.created[1].id)?.status == .expired)
        #expect(try await repo.refreshJob(id: created.created[1].id)?.error == "no_ingest_replica")
        let again = try await repo.createRefreshJobs(layers: ["radar"], now: t0.addingTimeInterval(200))
        #expect(again.pending == ["radar"])      // still running within 300 seconds
        let later = try await repo.createRefreshJobs(layers: ["radar"], now: t0.addingTimeInterval(320))
        #expect(later.created.count == 1)
        #expect(try await repo.refreshJob(id: created.created[0].id)?.status == .failed)
        #expect(try await repo.refreshJob(id: created.created[0].id)?.error == "timeout")
    }
}

// MARK: Insights error behaviour (stale-while-error, single flight)

private struct FlakySource: InsightsDataSource {
    let failing: Locked<Bool>
    let calls: Locked<Int>
    let delay: UInt64
    func context() async -> InsightsContext { InsightsContext(pushEnabled: false, caps: InsightsCapLimits(installations: 1, subscriptions: 1, regionCells: 1, activitySubscriptions: 1)) }
    func dailyStats(from: Date, to: Date) async throws -> [StatRow] {
        calls.withLock { $0 += 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failing.withLock({ $0 }) { throw NSError(domain: "db", code: 1) }
        return []
    }
    func layers(now: Date) async throws -> [InsightsLayerState] { [] }
    func replicaInfo(now: Date) async throws -> InsightsReplicaInfo { InsightsReplicaInfo(replicas: [], generation: 0) }
    func pushGauges(now: Date) async throws -> InsightsPushGauges? { nil }
}

@Suite("Insights error behaviour")
struct InsightsStaleTests {
    private func rig(_ source: FlakySource, time: Locked<Date>) async throws -> (DashboardApi, String) {
        let repo = MemoryRepo()
        let store = try await ConfigStore(env: [:], repo: repo)
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        let clock: @Sendable () -> Date = { time.withLock { $0 } }
        let api = DashboardApi(auth: auth, repo: repo, store: store, env: [:], staticRoot: NSTemporaryDirectory(), clock: clock,
                               extra: registerInsightsRoutes(engine: InsightsEngine(source: source, clock: clock), clock: clock))
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        return (api, "__Host-dash_session=" + created.cookieValue)
    }
    private func get(_ r: (DashboardApi, String), _ path: String) async -> (Int, [String: Any], ApiResponse) {
        let resp = await r.0.handle(DashboardHTTPRequest(method: "GET", path: path, info: DashboardRequestInfo(method: "GET", cookieHeader: r.1, host: "dash.example.test")))
        return (resp.status, (try? JSONSerialization.jsonObject(with: Data(resp.body))) as? [String: Any] ?? [:], resp)
    }

    @Test func lastGoodAnswerSurvivesFailureForTenMinutes() async throws {
        let time = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let failing = Locked(false)
        let r = try await rig(FlakySource(failing: failing, calls: Locked(0), delay: 0), time: time)
        let first = await get(r, "/dash/api/insights/ops")
        #expect(first.0 == 200 && first.1["stale"] == nil)
        failing.withLock { $0 = true }
        time.withLock { $0 = $0.addingTimeInterval(30) }
        let stale = await get(r, "/dash/api/insights/ops")
        #expect(stale.0 == 200 && stale.1["stale"] as? Bool == true && stale.1["staleSeconds"] as? Int == 30)
        #expect(stale.1["generatedAt"] as? String == first.1["generatedAt"] as? String)
        time.withLock { $0 = $0.addingTimeInterval(600) }
        let gone = await get(r, "/dash/api/insights/ops")
        #expect(gone.0 == 503 && gone.1["error"] as? String == "data_unavailable")
        #expect(gone.2.headers.contains { $0.0 == "Retry-After" && $0.1 == "5" })
        failing.withLock { $0 = false }
        #expect(await get(r, "/dash/api/insights/ops").0 == 200)
    }

    @Test func parallelIdenticalRequestsShareOneComputation() async throws {
        let calls = Locked(0)
        let r = try await rig(FlakySource(failing: Locked(false), calls: calls, delay: 200_000_000), time: Locked(Date(timeIntervalSince1970: 1_800_000_000)))
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<6 { group.addTask { await self.get(r, "/dash/api/insights/ops").0 } }
            for await s in group { #expect(s == 200) }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func authenticatedReadsAllowThreeThousandPerMinute() {
        #expect(DashboardRateLimits.Bucket.other.perMinute == 3000 && DashboardRateLimits.Bucket.session.perMinute == 600)
    }
}

extension DatabaseSuites {
@Suite("Cache admin repo", .serialized)
struct CacheAdminRepoTests {
    @Test(arguments: RepoKind.allCases) func repoContract(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let a = TimeUtil.floorStep(now.addingTimeInterval(-3600)), b = a.addingTimeInterval(300)
        for nominal in [a, b] {
            let id = TimeUtil.toID(nominal)
            #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
            for (i, slot) in TimeUtil.slots(of: nominal).prefix(3).enumerated() {
                try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: i, slotTime: slot), contentType: "image/webp", data: [UInt8](repeating: UInt8(i + 1), count: 10))
            }
            #expect(try await repo.publish(runID: id, owner: "t", expectedSlots: 3))
        }
        let l = a.addingTimeInterval(600), lid = TimeUtil.toID(l)
        #expect(try await repo.layerTryClaim(layer: "lightning", runID: lid, nominal: l, owner: "t", leaseSeconds: 60, maxAttempts: 2))
        try await repo.layerPutSlot(layer: "lightning", SlotRef(runID: lid, slotID: lid, slotIndex: 0, slotTime: l), contentType: "image/png", data: [9, 9])
        let inv = try await repo.cacheInventory(layers: ["radar", "lightning", "clouds"], now: now)
        #expect(inv[0].runs == 2 && inv[0].slots == 6 && inv[0].bytes == 60 && inv[0].oldestNominal == a && inv[0].newestNominal == b)
        #expect(inv[0].lastAttemptStatus == "published")
        #expect(inv[1].runs == 0 && inv[1].lastAttemptStatus == "claimed")      // not published yet: not counted, but a running attempt
        #expect(inv[2].runs == 0 && inv[2].lastAttemptStatus == nil)
        let page = try await repo.cacheSlotPage(layer: "radar", before: now, limit: 2)
        #expect(page.rows.count >= 2 && page.next != nil)
        #expect(page.rows.map(\.slot) == page.rows.map(\.slot).sorted(by: >))
        let blob = try #require(try await repo.cacheSlotBlob(layer: "radar", slot: b, run: nil))
        #expect(blob.data == [UInt8](repeating: 2, count: 10) || blob.data == [UInt8](repeating: 1, count: 10))
        #expect(try await repo.cacheSlotBlob(layer: "lightning", slot: l, run: nil) == nil)   // unpublished
        // refresh jobs
        let created = try await repo.createRefreshJobs(layers: ["radar", "clouds"], now: now)
        #expect(created.created.count == 2)
        #expect(try await repo.createRefreshJobs(layers: ["radar"], now: now).pending == ["radar"])
        // Both jobs share one created_at second; the id tiebreak (random UUID) makes the order arbitrary on MariaDB.
        #expect(Set(try await repo.queuedRefreshLayers(now: now)) == ["radar", "clouds"])
        let job = try #require(try await repo.claimRefreshJob(layer: "radar", now: now))
        #expect(try await repo.claimRefreshJob(layer: "radar", now: now) == nil)
        try await repo.finishRefreshJob(id: job.id, status: .ok, result: "{\"stored\":1}", error: nil, now: now)
        #expect(try await repo.refreshJob(id: job.id)?.status == .ok)
        #expect(try await repo.queuedRefreshLayers(now: now.addingTimeInterval(130)) == [])
        #expect(try await repo.refreshJob(id: created.created[1].id)?.error == "no_ingest_replica")
        // replica fill
        try await repo.heartbeat(replicaID: "r1", slot: 1, appliedGeneration: 0, push: nil, now: now)
        try await repo.reportCacheFill(replicaID: "r1", fill: ReplicaCacheFill(bytes: 5, entries: 1, maxBytes: 9), now: now)
        #expect(try await repo.replicaCacheFills(now: now)["r1"] == ReplicaCacheFill(bytes: 5, entries: 1, maxBytes: 9))
    }
}
}

extension DatabaseSuites {
@Suite("Dead pooled connection", .serialized)
struct DeadConnectionTests {
    @Test(arguments: RepoKind.allCases.filter { $0 == .maria }) func idleConnectionKilledByServerIsReplaced(kind: RepoKind) async throws {
        let repo = try await kind.make() as! MariaRepo
        try await repo.ping()
        try await repo.rawExecute("SET GLOBAL wait_timeout = 2")
        defer { Task { try? await repo.rawExecute("SET GLOBAL wait_timeout = 28800") } }
        try await Task.sleep(nanoseconds: 3_500_000_000)
        for _ in 0..<4 { try await repo.ping() }     // every pooled connection was closed by the server meanwhile
        _ = try await repo.cacheInventory(layers: ["radar"], now: Date())
    }
}
}
