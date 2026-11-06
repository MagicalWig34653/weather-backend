import Foundation
import Testing
@testable import RadarCore

// Pairing window (decision 6.11.2026): link codes only while the operator's window is open; the window closes after the first redemption.
private let installA = "11111111-1111-4111-8111-111111111111"
private let secret = String(repeating: "a", count: 40)
private let token = String(repeating: "ab", count: 32)
private let origin = "https://dash.example.test"
private let base = "/v1/push/installations/"

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private func config(requireTestFlight: Bool = false, enabled: Bool = true) -> Config {
    var c = smallConfig { $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.deviceLink.enabled = enabled; $0.deviceLink.requireTestFlight = requireTestFlight }
    c.width = 64
    return c
}

private func t0() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

private func json(_ r: ApiResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any]) ?? [:] }

private func fixture(_ name: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "docs/fixtures/" + name)))) ?? "missing fixture \(name)"
}

private func keys(_ o: Any) -> Set<String> { Set((o as? [String: Any])?.keys.map { $0 } ?? []) }

@Suite("Pairing window")
struct PairingWindowTests {
    private func setup(_ repo: MemoryRepo, clock: TestClock, requireTestFlight: Bool = false, installs: [String] = [installA]) async throws -> PushApi {
        for id in installs {
            _ = try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array(secret.utf8)), token: token + id.prefix(2), env: .sandbox, locale: "de", now: clock.now, maxInstallations: 100)
        }
        return PushApi(repo: repo, configProvider: ConfigProvider(config(requireTestFlight: requireTestFlight)), clock: { clock.now }, stats: StatsCollector())
    }

    private func linkCode(_ api: PushApi, _ id: String = installA, body: String = "{}") async -> ApiResponse {
        await api.handle(method: "POST", path: base + id + "/link-code", secret: secret, body: Array(body.utf8))!
    }

    @Test func closedWindowRefusesEverythingUniformly() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let api = try await setup(repo, clock: clock)
        for body in ["{}", "", #"{"app_transaction":"garbage"}"#, "not json"] {
            let r = await linkCode(api, body: body)
            #expect(r.status == 403 && json(r)["error"] as? String == "pairing_closed")
        }
        #expect(json(await linkCode(api))["error"] as? String == "pairing_closed")
        // Wrong secret is still 401 (no information about the window for strangers), feature off is 404.
        #expect(await api.handle(method: "POST", path: base + installA + "/link-code", secret: String(repeating: "b", count: 40), body: [])!.status == 401)
        let off = PushApi(repo: repo, configProvider: ConfigProvider(config(enabled: false)), clock: { clock.now }, stats: StatsCollector())
        #expect(await off.handle(method: "POST", path: base + installA + "/link-code", secret: secret, body: []) == nil)
    }

    @Test func openWindowAllowsCodeWithoutProofAndExpires() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let api = try await setup(repo, clock: clock)
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(300))
        let ok = await linkCode(api)
        #expect(ok.status == 201 && json(ok)["ttl_seconds"] as? Int == 600)
        // app_transaction is ignored when sent, an empty body works, a non-object body is a 400.
        #expect(await linkCode(api, body: #"{"app_transaction":"garbage"}"#).status == 201)
        #expect(await linkCode(api, body: "").status == 201)
        #expect(await linkCode(api, body: "[1]").status == 400)
        // Expiry: closed again, including at the exact end.
        clock.advance(300)
        #expect(await linkCode(api).status == 403)
        #expect(try await repo.pairingWindowEnd(now: clock.now) == nil)
    }

    @Test func codeIssuedInWindowStaysRedeemableAfterItCloses() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let api = try await setup(repo, clock: clock)
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(60))
        let code = try #require(json(await linkCode(api))["code"] as? String)
        clock.advance(120)
        #expect(await linkCode(api).status == 403)
        let hash = LinkCode.hash(try #require(LinkCode.normalize(code)))
        guard case .paired = try await repo.pairDevice(codeHash: hash, label: "x", deviceID: UUID().uuidString.lowercased(), now: clock.now, maxDevices: 3, ttlDays: 0) else {
            Issue.record("issued code must stay redeemable"); return
        }
    }

    @Test func floodLimitPerWindowAndPerInstallationLimit() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let installs = (0..<6).map { String(format: "%08d-0000-4000-8000-000000000000", $0 + 10) }
        let api = try await setup(repo, clock: clock, installs: installs)
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(300))
        // One installation: 6 per hour, the 7th is 429.
        for _ in 0..<6 { #expect(await linkCode(api, installs[0]).status == 201) }
        let per = await linkCode(api, installs[0])
        #expect(per.status == 429 && per.headers.contains { $0.0 == "Retry-After" && $0.1 == "3600" })
        // Window flood: 30 codes in total (6 used above), then 429 for everybody until the window ends.
        var issued = 6
        for i in 1..<5 { for _ in 0..<6 where issued < 30 { if await linkCode(api, installs[i]).status == 201 { issued += 1 } } }
        #expect(issued == 30)
        let flood = await linkCode(api, installs[5])
        #expect(flood.status == 429 && json(flood)["error"] as? String == "link_code_rate_limited" && flood.headers.contains { $0.0 == "Retry-After" && $0.1 == "300" })
        // A new window (new end) has its own budget.
        clock.advance(10)
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(300))
        #expect(await linkCode(api, installs[5]).status == 201)
    }

    @Test func requireTestFlightStillDemandsProof() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let api = try await setup(repo, clock: clock, requireTestFlight: true)
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(300))
        #expect(await linkCode(api, body: "{}").status == 400)
        let bad = await linkCode(api, body: #"{"app_transaction":"garbage"}"#)
        #expect(bad.status == 403 && json(bad)["error"] as? String == "not_testflight")
        // Closed window wins over the proof check.
        try await repo.closePairingWindow(now: clock.now)
        #expect(json(await linkCode(api, body: #"{"app_transaction":"garbage"}"#))["error"] as? String == "pairing_closed")
    }

    @Test func statusShowsWindowAndRespectsMemo() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let api = Api(repo: repo, config: config(), clock: { clock.now })
        func status() async throws -> [String: Any] { json(try await api.handle(path: "/v1/status", ifNoneMatch: nil)) }
        let closed = try await status()
        #expect(closed["device_link_window"] == nil && keys(closed) == keys(fixture("app/status.device_link.json")))
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(300))
        #expect(try await status()["device_link_window"] == nil, "memo of 5 s may still show the old state")
        clock.advance(6)
        let open = try await status()
        #expect(keys(open) == keys(fixture("app/status.device_link_window.json")))
        #expect((open["device_link_window"] as? [String: Any])?["ends_at"] as? String == TimeUtil.toISO(clock.now.addingTimeInterval(300 - 6)))
        clock.advance(300)   // window over, memo over
        #expect(try await status()["device_link_window"] == nil)
        // Feature off: never shown.
        try await repo.openPairingWindow(until: clock.now.addingTimeInterval(300))
        let off = Api(repo: repo, config: config(enabled: false), clock: { clock.now })
        #expect(json(try await off.handle(path: "/v1/status", ifNoneMatch: nil))["device_link_window"] == nil)
    }

    @Test func twoReplicasShareTheWindow() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let a = try await setup(repo, clock: clock)
        let b = PushApi(repo: repo, configProvider: ConfigProvider(config()), clock: { clock.now }, stats: StatsCollector())
        let dash = try await DashHarness(repo: repo, clock: clock)
        #expect(await linkCode(b).status == 403)
        #expect(await dash.call("POST", "/dash/api/devices/pairing", body: #"{"minutes":2}"#).status == 200)
        let fromA = await linkCode(a).status, fromB = await linkCode(b).status
        #expect(fromA == 201 && fromB == 201)
    }

    @Test func dashboardOpenCloseAutoCloseAndAudit() async throws {
        let clock = TestClock(t0()); let repo = MemoryRepo()
        let app = try await setup(repo, clock: clock)
        let dash = try await DashHarness(repo: repo, clock: clock)
        let initial = await dash.call("GET", "/dash/api/devices")
        #expect(keys(initial.json) == keys(fixture("dashboard/devices.200.json")))
        let pairing = (initial.json as? [String: Any])?["pairing"] as? [String: Any]
        #expect(pairing?["open"] as? Bool == false && pairing?["defaultMinutes"] as? Int == 5 && pairing?["maxMinutes"] as? Int == 15 && pairing?["endsAt"] is NSNull)
        // Validation.
        for body in [#"{"minutes":0}"#, #"{"minutes":16}"#, #"{"minutes":2.5}"#, #"{"minutes":"5"}"#, #"{"minutes":true}"#, "[1]"] {
            #expect(await dash.call("POST", "/dash/api/devices/pairing", body: body).status == 400, "\(body)")
        }
        clock.advance(61)   // the 6 per minute limit counts invalid requests too
        // Default 5 minutes with {} and with an empty body.
        let open = await dash.call("POST", "/dash/api/devices/pairing", body: "{}")
        #expect(open.status == 200 && keys(open.json) == keys(fixture("dashboard/pairing-open.200.json")))
        #expect((open.json as? [String: Any])?["endsAt"] as? String == TimeUtil.toISO(clock.now.addingTimeInterval(300)))
        #expect((await dash.call("POST", "/dash/api/devices/pairing", body: #"{"minutes":15}"#).json as? [String: Any])?["endsAt"] as? String == TimeUtil.toISO(clock.now.addingTimeInterval(900)))
        let listed = await dash.call("GET", "/dash/api/devices")
        #expect(keys(listed.json) == keys(fixture("dashboard/devices.pairing-open.json")) && ((listed.json as? [String: Any])?["pairing"] as? [String: Any])?["open"] as? Bool == true)
        // Manual close, idempotent.
        let closed = await dash.call("DELETE", "/dash/api/devices/pairing")
        #expect(closed.status == 200 && keys(closed.json) == keys(fixture("dashboard/pairing-close.200.json")) && (closed.json as? [String: Any])?["open"] as? Bool == false)
        #expect(await dash.call("DELETE", "/dash/api/devices/pairing").status == 200)
        #expect(await linkCode(app).status == 403)
        // Redemption closes the window.
        #expect(await dash.call("POST", "/dash/api/devices/pairing", body: #"{"minutes":5}"#).status == 200)
        let code = try #require(json(await linkCode(app))["code"] as? String)
        let paired = await dash.call("POST", "/dash/api/devices/pair", body: "{\"code\":\"\(code)\",\"label\":\"Mein iPhone\"}")
        #expect(paired.status == 201)
        #expect(try await repo.pairingWindowEnd(now: clock.now) == nil)
        #expect(await linkCode(app).status == 403)
        // Audit: names only, no personal data, no code, no ids.
        let audit = try await repo.auditEntries(limit: 20)
        let pairingEntries = audit.filter { $0.action == .devicePairingOpen || $0.action == .devicePairingClose }
        #expect(pairingEntries.map(\.outcome).sorted { ($0 ?? "") < ($1 ?? "") } == ["manual", "minutes:15", "minutes:5", "minutes:5", "redeemed"].sorted() .map { Optional($0) })
        #expect(pairingEntries.allSatisfy { $0.deviceRef == nil && $0.key == nil && $0.oldValue == nil && $0.newValue == nil })
        let text = String(describing: audit)
        #expect(!text.contains(code) && !text.contains(installA) && !text.contains("Mein iPhone"))
        // Disabled feature: cannot be opened.
        let off = try await DashHarness(repo: repo, clock: clock, enabled: false)
        #expect(await off.call("POST", "/dash/api/devices/pairing", body: "{}").status == 409)
        #expect(keys(await off.call("GET", "/dash/api/devices").json) == keys(fixture("dashboard/devices.disabled.json")))
    }

    @Test func dashboardPairingRateLimit() async throws {
        let clock = TestClock(t0())
        let dash = try await DashHarness(repo: MemoryRepo(), clock: clock)
        var last = 0
        for _ in 0..<7 { last = await dash.call("POST", "/dash/api/devices/pairing", body: "{}").status }
        #expect(last == 429)
    }

    @Test(arguments: RepoKind.allCases) func repoContract(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        #expect(try await repo.pairingWindowEnd(now: now) == nil)
        #expect(try await repo.closePairingWindow(now: now) == false)
        try await repo.openPairingWindow(until: now.addingTimeInterval(300))
        #expect(try await repo.pairingWindowEnd(now: now) == now.addingTimeInterval(300))
        try await repo.openPairingWindow(until: now.addingTimeInterval(60))   // reopening replaces the end
        #expect(try await repo.pairingWindowEnd(now: now) == now.addingTimeInterval(60))
        #expect(try await repo.pairingWindowEnd(now: now.addingTimeInterval(60)) == nil)   // expired = closed
        #expect(try await repo.closePairingWindow(now: now) == true)
        #expect(try await repo.pairingWindowEnd(now: now) == nil)
        try await repo.appendDeviceAudit(action: .devicePairingOpen, deviceRef: nil, outcome: "minutes:5", now: now)
        try await repo.appendDeviceAudit(action: .devicePairingClose, deviceRef: nil, outcome: "redeemed", now: now)
        #expect(try await repo.auditEntries(limit: 2).map(\.action) == [.devicePairingClose, .devicePairingOpen])
    }
}

/// Dashboard API over a given repository and clock (session with CSRF).
private struct DashHarness {
    let api: DashboardApi; let cookie: String; let csrf: String
    init(repo: MemoryRepo, clock: TestClock, enabled: Bool = true) async throws {
        let c = config(enabled: enabled)
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        api = DashboardApi(auth: auth, repo: repo, store: ConfigStore(fixed: c), staticRoot: "/nonexistent", clock: { clock.now })
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: clock.now)
        let created = try await auth.sessions.create()
        cookie = "__Host-dash_session=" + created.cookieValue; csrf = created.csrfToken
    }

    func call(_ method: String, _ path: String, body: String = "{}") async -> (status: Int, json: Any) {
        let write = method != "GET"
        let info = DashboardRequestInfo(method: method, cookieHeader: cookie, origin: write ? origin : nil, host: "dash.example.test",
                                        contentType: write ? "application/json" : nil, csrfToken: csrf)
        let r = await api.handle(DashboardHTTPRequest(method: method, path: path, query: [:], body: Array(body.utf8), info: info))
        return (r.status, (try? JSONSerialization.jsonObject(with: Data(r.body))) ?? NSNull())
    }
}
