import Foundation
import Testing
@testable import RadarCore

private let install = "11111111-1111-4111-8111-111111111111"
private let secret = String(repeating: "a", count: 40)
private let token = String(repeating: "ab", count: 32)
private let now = Date(timeIntervalSince1970: 1_794_000_000)

private func obj(_ r: ApiResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any]) ?? [:] }
private func body(_ object: [String: Any]) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
private func header(_ r: ApiResponse, _ name: String) -> String? { r.headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

@Suite("Warn API")
struct WarnApiTests {
    func config(ingest: Bool = true, warnPush: Bool = true, push: Bool = true) -> Config {
        smallConfig { $0.push.enabled = push; $0.push.topic = "de.example.app"; $0.warn.ingestEnabled = ingest; $0.warn.pushEnabled = warnPush }
    }

    func make(_ cfg: Config? = nil) async throws -> (Api, MemoryRepo) {
        let repo = MemoryRepo()
        let api = Api(repo: repo, config: cfg ?? config(), clock: { now })
        _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array(secret.utf8)), token: token, env: .sandbox, locale: "de", now: now)
        return (api, repo)
    }

    func seedAlert(_ repo: MemoryRepo) async throws {
        _ = try await repo.upsertAlert(warnTestAlert("K1.DEU", sent: now.addingTimeInterval(-300), cells: ["814522510", "814522500"], text: "Deutsch"), now: now)
        _ = try await repo.upsertAlert(warnTestAlert("K1.ENG", lang: "en", sent: now.addingTimeInterval(-300), cells: ["814522510", "814522500"], text: "English"), now: now)
        try await repo.setWarnFetchedAt(now.addingTimeInterval(-30))
    }

    // MARK: GET /v1/warnings/active

    @Test func activeIsNotFoundWithoutTheFlag() async throws {
        let (api, _) = try await make(config(ingest: false))
        let r = try await api.handle(path: "/v1/warnings/active", ifNoneMatch: nil)
        #expect(r.status == 404 && obj(r)["error"] as? String == "not_found")
    }

    @Test func activeIsUnavailableBeforeTheFirstSync() async throws {
        let (api, _) = try await make()
        let r = try await api.handle(path: "/v1/warnings/active", ifNoneMatch: nil)
        #expect(r.status == 503 && obj(r)["error"] as? String == "warnings_unavailable")
    }

    @Test func activeHasTheContractShapeAndCacheHeader() async throws {
        let (api, repo) = try await make()
        try await seedAlert(repo)
        let r = try await api.handle(path: "/v1/warnings/active", ifNoneMatch: nil)
        #expect(r.status == 200 && header(r, "Cache-Control") == "public, max-age=30" && header(r, "Content-Type") == "application/json")
        let o = obj(r)
        #expect(o["schema"] as? Int == 1 && o["source"] as? String == "dwd" && o["fetched_at"] as? String == TimeUtil.toISO(now.addingTimeInterval(-30)))
        let list = try #require(o["warnings"] as? [[String: Any]])
        #expect(list.count == 1)
        // The keys equal the contract fixture.
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "docs/fixtures/warnings/active.200.json"))
        let expected = try #require(((JSONSerialization.jsonObject(with: fixture) as? [String: Any])?["warnings"] as? [[String: Any]])?.first)
        #expect(Set(list[0].keys) == Set(expected.keys))
        let fixtureTop = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        #expect(Set(fixtureTop.keys) == Set(o.keys))
        #expect(list[0]["id"] as? String == "K1.DEU" && list[0]["lang"] as? String == "de" && list[0]["text"] as? String == "Deutsch")
        #expect(list[0]["kind"] as? String == "frost" && list[0]["severity"] as? Int == 1 && (list[0]["warncell_ids"] as? [String])?.sorted() == ["814522500", "814522510"])
    }

    @Test func activeFollowsAcceptLanguage() async throws {
        let (api, repo) = try await make()
        try await seedAlert(repo)
        let en = try await api.handle(path: "/v1/warnings/active", ifNoneMatch: nil, acceptLanguage: "en-US,en;q=0.9")
        let first = (obj(en)["warnings"] as? [[String: Any]])?.first
        #expect(first?["lang"] as? String == "en" && first?["text"] as? String == "English")
        let fr = try await api.handle(path: "/v1/warnings/active", ifNoneMatch: nil, acceptLanguage: "fr")
        #expect((obj(fr)["warnings"] as? [[String: Any]])?.first?["lang"] as? String == "de")
    }

    @Test func activeOmitsCancelledAndExpired() async throws {
        let (api, repo) = try await make()
        try await seedAlert(repo)
        try await repo.cancelAlerts(identifiers: ["K1.DEU"], now: now)
        let r = try await api.handle(path: "/v1/warnings/active", ifNoneMatch: nil)
        #expect((obj(r)["warnings"] as? [Any])?.isEmpty == true)
    }

    // MARK: capabilities

    @Test func capabilitiesFollowTheFlags() async throws {
        func caps(_ cfg: Config) async throws -> [String] {
            let (api, _) = try await make(cfg)
            return obj(try await api.handle(path: "/v1/status", ifNoneMatch: nil))["capabilities"] as? [String] ?? []
        }
        #expect(try await caps(config(ingest: false, warnPush: false)) == ["regions", "live_activity", "live_activity_regions"])
        #expect(try await caps(config(ingest: true, warnPush: false)) == ["regions", "live_activity", "live_activity_regions", "warnings"])
        #expect(try await caps(config(ingest: true, warnPush: true)) == ["regions", "live_activity", "live_activity_regions", "warnings", "warnings_push"])
        #expect(try await caps(config(ingest: false, warnPush: true)) == ["regions", "live_activity", "live_activity_regions"])
        // Display works without push; the push capability needs all three switches.
        #expect(try await caps(config(ingest: true, warnPush: true, push: false)) == ["warnings"])
        #expect(try await caps(config(ingest: false, warnPush: false, push: false)).isEmpty)
    }

    // MARK: warn subscriptions

    let base = "/v1/push/installations/\(install)/warn-subscriptions"
    func valid(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [UInt8] {
        var o: [String: Any] = ["warncell_ids": ["814522510"], "types": ["severe_weather", "frost", "ice"], "min_severity": ["severe_weather": 3, "frost": 1, "ice": 2], "enabled": true, "time_sensitive": false]
        edit(&o)
        return body(o)
    }

    @Test func crudRoundTrip() async throws {
        let (api, _) = try await make()
        let created = await api.handlePush(method: "POST", path: base, secret: secret, body: valid())
        #expect(created.status == 201)
        let id = try #require(obj(created)["id"] as? String)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(await api.handlePush(method: "GET", path: base, secret: secret, body: []).body)) as? [[String: Any]])
        #expect(list.count == 1 && list[0]["id"] as? String == id && list[0]["warncell_ids"] as? [String] == ["814522510"])
        #expect(Set(list[0]["types"] as? [String] ?? []) == ["severe_weather", "frost", "ice"] && list[0]["min_severity"] as? [String: Int] == ["severe_weather": 3, "frost": 1, "ice": 2])
        #expect(list[0]["enabled"] as? Bool == true && list[0]["time_sensitive"] as? Bool == false)
        let put = await api.handlePush(method: "PUT", path: base + "/" + id, secret: secret, body: valid { $0["types"] = ["ice"]; $0["time_sensitive"] = true; $0["enabled"] = false; $0["min_severity"] = ["ice": 3] })
        #expect(put.status == 204)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(await api.handlePush(method: "GET", path: base, secret: secret, body: []).body)) as? [[String: Any]])
        #expect(after[0]["types"] as? [String] == ["ice"] && after[0]["time_sensitive"] as? Bool == true && after[0]["enabled"] as? Bool == false)
        #expect((after[0]["min_severity"] as? [String: Int])?["ice"] == 3 && (after[0]["min_severity"] as? [String: Int])?["frost"] == 1)
        #expect(await api.handlePush(method: "DELETE", path: base + "/" + id, secret: secret, body: []).status == 204)
        #expect(await api.handlePush(method: "DELETE", path: base + "/" + id, secret: secret, body: []).status == 404)
        #expect(await api.handlePush(method: "PUT", path: base + "/" + id, secret: secret, body: valid()).status == 404)
    }

    @Test func routesAreNotFoundWithoutTheSwitches() async throws {
        for cfg in [config(warnPush: false), config(push: false)] {
            let (api, _) = try await make(cfg)
            for method in ["GET", "POST"] { #expect(await api.handlePush(method: method, path: base, secret: secret, body: valid()).status == 404) }
        }
    }

    @Test func authenticationIsUniform() async throws {
        let (api, _) = try await make()
        for method in ["GET", "POST"] {
            #expect(await api.handlePush(method: method, path: base, secret: nil, body: valid()).status == 401)
            #expect(await api.handlePush(method: method, path: base, secret: String(repeating: "b", count: 40), body: valid()).status == 401)
        }
        #expect(await api.handlePush(method: "DELETE", path: base + "/" + UUID().uuidString.lowercased(), secret: nil, body: []).status == 401)
    }

    @Test func validationRejectsBadBodies() async throws {
        let (api, _) = try await make()
        let bad: [(String, (inout [String: Any]) -> Void)] = [
            ("no cells", { $0["warncell_ids"] = [String]() }),
            ("short id", { $0["warncell_ids"] = ["81452251"] }),
            ("letters", { $0["warncell_ids"] = ["81452251x"] }),
            ("duplicate", { $0["warncell_ids"] = ["814522510", "814522510"] }),
            ("65 cells", { $0["warncell_ids"] = (0..<65).map { String(800_000_000 + $0) } }),
            ("number id", { $0["warncell_ids"] = [814522510] }),
            ("no types", { $0["types"] = [String]() }),
            ("unknown type", { $0["types"] = ["heat"] }),
            ("severity 0", { $0["min_severity"] = ["frost": 0] }),
            ("severity 5", { $0["min_severity"] = ["frost": 5] }),
            ("severity key", { $0["min_severity"] = ["heat": 2] }),
            ("enabled type", { $0["enabled"] = "yes" }),
            ("switch type", { $0["time_sensitive"] = 1.5 }),
            ("missing cells", { $0["warncell_ids"] = nil }),
        ]
        for (name, edit) in bad {
            let r = await api.handlePush(method: "POST", path: base, secret: secret, body: valid(edit))
            #expect(r.status == 400 && obj(r)["error"] as? String == "invalid_warn_subscription", Comment(rawValue: name))
        }
        #expect(await api.handlePush(method: "POST", path: base, secret: secret, body: Array("nope".utf8)).status == 400)
        let defaults = await api.handlePush(method: "POST", path: base, secret: secret, body: body(["warncell_ids": ["814522510"], "types": ["frost"]]))
        #expect(defaults.status == 201)
    }

    @Test func largeBodyIsRefused() async throws {
        let (api, _) = try await make()
        let r = await api.handlePush(method: "POST", path: base, secret: secret, body: valid { $0["pad"] = String(repeating: "x", count: 5000) })
        #expect(r.status == 413 && obj(r)["error"] as? String == "too_large")
    }

    @Test func limitsAnswerConflict() async throws {
        let (api, _) = try await make()
        for i in 0..<WarnLimits.maxSubscriptionsPerInstallation {
            #expect(await api.handlePush(method: "POST", path: base, secret: secret, body: valid { $0["warncell_ids"] = [String(800_000_000 + i)] }).status == 201)
        }
        let r = await api.handlePush(method: "POST", path: base, secret: secret, body: valid())
        #expect(r.status == 409 && obj(r)["error"] as? String == "warn_limit")
    }

    @Test func unknownCellAnswersConflictOnceSeeded() async throws {
        let (api, repo) = try await make()
        try await repo.seedKnownWarnCells((0..<WarnCellCatalog.minimumSeed).map { String(800_000_000 + $0) })
        let r = await api.handlePush(method: "POST", path: base, secret: secret, body: valid { $0["warncell_ids"] = ["999999999"] })
        #expect(r.status == 409 && obj(r)["error"] as? String == "warncell_unknown")
    }

    @Test func rainRoutesAreUnchanged() async throws {
        let (api, _) = try await make()
        _ = await api.handlePush(method: "POST", path: base, secret: secret, body: valid())
        let list = await api.handlePush(method: "GET", path: "/v1/push/installations/\(install)/subscriptions", secret: secret, body: [])
        #expect(list.status == 200 && String(decoding: list.body, as: UTF8.self) == "[]")
    }

    @Test func flagsDefaultToOffAndReadFromTheEnvironment() throws {
        let off = try Config.fromEnvironment([:])
        #expect(!off.warn.ingestEnabled && !off.warn.pushEnabled)
        let on = try Config.fromEnvironment(["WARN_INGEST_ENABLED": "true", "WARN_PUSH_ENABLED": "TRUE"])
        #expect(on.warn.ingestEnabled && on.warn.pushEnabled)
        #expect(!on.warn.pushCapability(pushEnabled: false) && on.warn.pushCapability(pushEnabled: true))
    }
}
