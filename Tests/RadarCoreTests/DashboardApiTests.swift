import Foundation
import Testing
@testable import RadarCore

// Dashboard router (WP5): guards, config, audit, restart, statistics, static files. Memory repository, no network.
private let origin = "https://dash.example.test"

private struct Harness {
    let api: DashboardApi
    let repo: MemoryRepo
    let store: ConfigStore
    let cookie: String
    let csrf: String
    let root: String

    init(env: [String: String] = [:]) async throws {
        repo = MemoryRepo()
        store = try await ConfigStore(env: env, repo: repo)
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        let dir = NSTemporaryDirectory() + "dash-static-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/_app/immutable", withIntermediateDirectories: true)
        try "<html><script>start()</script></html>".write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
        try "console.log(1)".write(toFile: dir + "/_app/immutable/a.js", atomically: true, encoding: .utf8)
        root = dir
        api = DashboardApi(auth: auth, repo: repo, store: store, env: env, staticRoot: dir)
        _ = try await repo.insertCredential(credentialID: [1, 2, 3], publicKey: [4], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        cookie = "__Host-dash_session=" + created.cookieValue
        csrf = created.csrfToken
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: String = "{}", session: Bool = true,
                 csrf: Bool = true, host: String = "dash.example.test", origin: String? = origin) -> DashboardHTTPRequest {
        let write = method != "GET"
        let info = DashboardRequestInfo(method: method, cookieHeader: session ? cookie : nil, origin: write ? origin : nil, host: host,
                                        contentType: write ? "application/json" : nil, csrfToken: csrf ? self.csrf : nil)
        return DashboardHTTPRequest(method: method, path: path, query: query, body: Array(body.utf8), info: info)
    }

    func call(_ method: String, _ path: String, query: [String: String] = [:], body: String = "{}", session: Bool = true,
              csrf: Bool = true, host: String = "dash.example.test") async -> (status: Int, json: [String: Any], response: ApiResponse) {
        let r = await api.handle(request(method, path, query: query, body: body, session: session, csrf: csrf, host: host))
        let json = (try? JSONSerialization.jsonObject(with: Data(r.body))) as? [String: Any] ?? [:]
        return (r.status, json, r)
    }
}

@Suite("Dashboard API")
struct DashboardApiTests {
    @Test func guardsHostSessionAndCSRF() async throws {
        let h = try await Harness()
        #expect(await h.call("GET", "/dash/api/session", host: "evil.test").status == 403)
        #expect(await h.call("GET", "/dash/api/config", session: false).status == 401)
        #expect(await h.call("GET", "/elsewhere").status == 404)
        let noCSRF = await h.call("PUT", "/dash/api/config/HISTORY_HOURS", body: "{\"value\":24}", csrf: false)
        #expect(noCSRF.status == 403 && noCSRF.json["error"] as? String == "forbidden")
        let badOrigin = h.request("PUT", "/dash/api/config/HISTORY_HOURS", body: "{\"value\":24}", origin: "https://evil.test")
        #expect(await h.api.handle(badOrigin).status == 403)
        #expect(await h.call("POST", "/dash/api/restart", csrf: false).status == 403)
        #expect(await h.call("POST", "/dash/api/restart", session: false).status == 401)
        let session = await h.call("GET", "/dash/api/session")
        #expect(session.json["state"] as? String == "authenticated" && session.json["csrfToken"] as? String == h.csrf)
        #expect(session.response.headers.contains { $0.0 == "Cache-Control" && $0.1 == "no-store" })
    }

    @Test func configRoundTripAndAudit() async throws {
        let h = try await Harness(env: ["HISTORY_HOURS": "10"])
        let list = await h.call("GET", "/dash/api/config")
        let entries = try #require(list.json["entries"] as? [[String: Any]])
        let secret = try #require(entries.first { $0["key"] as? String == "DB_PASSWORD" })
        #expect(secret["value"] is NSNull && secret["locked"] as? Bool == true)
        let locked = await h.call("PUT", "/dash/api/config/HISTORY_HOURS", body: "{\"value\":24}")
        #expect(locked.status == 409 && locked.json["error"] as? String == "locked_by_env")

        let put = await h.call("PUT", "/dash/api/config/RETENTION_RUNS", body: "{\"value\":20}")
        #expect(put.status == 200)
        let entry = try #require(put.json["entry"] as? [String: Any])
        #expect(entry["value"] as? Int == 20 && entry["source"] as? String == "dashboard" && entry["apply"] as? String == "live")
        #expect(h.store.snapshot().retentionRuns == 20)
        #expect(await h.call("PUT", "/dash/api/config/RETENTION_RUNS", body: "{\"value\":1}").status == 400)
        #expect(await h.call("PUT", "/dash/api/config/RETENTION_RUNS", body: "{}").status == 400)
        #expect(await h.call("PUT", "/dash/api/config/NOPE", body: "{\"value\":1}").status == 404)
        #expect(await h.call("PUT", "/dash/api/config/DB_PASSWORD", body: "{\"value\":\"x\"}").status == 409)

        let reset = await h.call("DELETE", "/dash/api/config/RETENTION_RUNS")
        #expect(reset.status == 200 && (reset.json["entry"] as? [String: Any])?["source"] as? String == "default")

        let audit = await h.call("GET", "/dash/api/config/audit", query: ["limit": "10", "action": "set"])
        let rows = try #require(audit.json["entries"] as? [[String: Any]])
        #expect(rows.count == 1 && rows[0]["configKey"] as? String == "RETENTION_RUNS" && rows[0]["deviceRef"] is NSNull)
        #expect(await h.call("GET", "/dash/api/config/audit", query: ["limit": "0"]).status == 400)
        #expect(await h.call("GET", "/dash/api/config/audit", query: ["action": "bogus"]).status == 400)
    }

    @Test func restartRequestIsGatedAndAudited() async throws {
        let h = try await Harness()
        let state = await h.call("GET", "/dash/api/restart")
        #expect(state.status == 200 && state.json["generation"] as? Int == 0)
        try await h.repo.heartbeat(replicaID: "host-1", slot: 1, appliedGeneration: 0, now: Date())
        let first = await h.call("POST", "/dash/api/restart")
        #expect(first.status == 202 && first.json["generation"] as? Int == 1)
        let again = await h.call("POST", "/dash/api/restart")
        #expect(again.status == 429 && again.response.headers.contains { $0.0 == "Retry-After" })
        let after = await h.call("GET", "/dash/api/restart")
        let replicas = try #require(after.json["replicas"] as? [[String: Any]])
        #expect(replicas.count == 1 && replicas[0]["state"] as? String == "waiting" && (replicas[0]["id"] as? String)?.count == 8)
        let audit = try await h.repo.auditEntries(limit: 5)
        #expect(audit.contains { $0.action == .restart })
    }

    @Test func statisticsRoutes() async throws {
        let h = try await Harness()
        try await h.repo.addStats(day: Date(), [StatDelta(metric: "requests", label: "healthz:2xx", value: 3)])
        let overview = await h.call("GET", "/dash/api/stats/overview", query: ["days": "7"])
        #expect(overview.status == 200 && overview.json["requests"] as? Int == 3)
        #expect(await h.call("GET", "/dash/api/stats/daily").status == 200)
        #expect(await h.call("GET", "/dash/api/stats/overview", query: ["days": "99"]).status == 400)
    }

    @Test func logoutClearsSession() async throws {
        let h = try await Harness()
        let out = await h.call("POST", "/dash/api/logout")
        #expect(out.status == 204 && out.response.headers.contains { $0.0 == "Set-Cookie" })
        #expect(await h.call("GET", "/dash/api/config").status == 401)
    }

    @Test func staticFilesAreContainedAndHardened() async throws {
        let h = try await Harness()
        let index = await h.call("GET", "/dash/", session: false)
        #expect(index.status == 200)
        let csp = try #require(index.response.headers.first { $0.0 == "Content-Security-Policy" }?.1)
        #expect(csp.contains("script-src 'self' 'sha256-") && csp.contains("frame-ancestors 'none'"))
        #expect(index.response.headers.contains { $0.0 == "X-Content-Type-Options" && $0.1 == "nosniff" })
        #expect(index.response.headers.contains { $0.0 == "Cache-Control" && $0.1 == "no-cache" })
        let spa = await h.call("GET", "/dash/settings/page", session: false)
        #expect(spa.status == 200 && spa.response.body == index.response.body)
        let asset = await h.call("GET", "/dash/_app/immutable/a.js", session: false)
        #expect(asset.status == 200 && asset.response.headers.contains { $0.0 == "Cache-Control" && $0.1.contains("immutable") })
        for bad in ["/dash/../x.txt", "/dash/%2e%2e/x.txt", "/dash/_app/../../x.txt", "/dash/a\\b.js", "/dash/.env", "/dash/missing.js", "/dash/a%00.js"] {
            #expect(await h.call("GET", bad, session: false).status == 404, "\(bad)")
        }
        #expect(await h.call("POST", "/dash/index.html").status == 405)
        // Symlink out of the root is refused.
        try FileManager.default.createSymbolicLink(atPath: h.root + "/leak.txt", withDestinationPath: "/etc/hosts")
        #expect(await h.call("GET", "/dash/leak.txt", session: false).status == 404)
    }
}
