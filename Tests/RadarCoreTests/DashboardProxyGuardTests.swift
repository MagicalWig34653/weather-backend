import Foundation
import Testing
@testable import RadarCore

private let tokenA = "AbCdEfGhIjKlMnOpQrStUvWxYz012345-_AbCdEfG"
private let tokenB = "ZyXwVuTsRqPoNmLkJiHgFeDcBa987654_-ZyXwVuT"

private func makeApi(guardian: DashboardProxyGuard?) async throws -> (DashboardApi, MemoryRepo, DashboardAuth) {
    let repo = MemoryRepo()
    let store = try await ConfigStore(env: [:], repo: repo)
    let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: "https://dash.example.test", rpID: "dash.example.test"), log: { _ in })
    let dir = NSTemporaryDirectory() + "dash-guard-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "<html>app</html>".write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
    return (DashboardApi(auth: auth, repo: repo, store: store, staticRoot: dir, proxyGuard: guardian), repo, auth)
}

private func req(_ method: String = "GET", _ path: String, token: String?) -> DashboardHTTPRequest {
    DashboardHTTPRequest(method: method, path: path, info: DashboardRequestInfo(method: method, host: "dash.example.test", proxyToken: token))
}

@Suite("Dashboard proxy guard")
struct DashboardProxyGuardTests {
    @Test func comparesTokens() throws {
        let g = try DashboardProxyGuard(tokens: [tokenA])
        #expect(g.admits(tokenA))
        #expect(!g.admits(tokenB))
        #expect(!g.admits(nil))
        #expect(!g.admits(""))
        #expect(!g.admits(tokenA + "x"))
        #expect(!g.admits(String(tokenA.dropLast())))
        #expect(!g.admits(String(repeating: "A", count: 100_000)))
        #expect(!g.admits(tokenA + "\n"))
        #expect(!g.admits("\u{0}\u{1F600}\r\n \t;\"'"))
        #expect(g.rejectCount == 8)
    }

    @Test func rotationAcceptsBothTokens() throws {
        let g = try DashboardProxyGuard(tokens: [tokenA, tokenB])
        #expect(g.admits(tokenA) && g.admits(tokenB))
        #expect(!g.admits(tokenA + tokenB))
    }

    @Test func rejectsWeakTokens() {
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard(tokens: ["short"]) }
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard(tokens: [String(repeating: "a", count: 31)]) }
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard(tokens: [String(repeating: "a", count: 300)]) }
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard(tokens: [String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)]) }
    }

    @Test func guardRunsBeforeEverything() async throws {
        let (api, _, auth) = try await makeApi(guardian: DashboardProxyGuard(tokens: [tokenA]))
        let paths = ["/dash/", "/dash/index.html", "/dash/api/session", "/dash/api/setup/begin", "/dash/api/login/begin",
                     "/dash/api/insights", "/dash/api/stats/overview", "/unknown", "/"]
        for method in ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"] {
            for path in paths {
                let bad = await api.handle(req(method, path, token: nil))
                let wrong = await api.handle(req(method, path, token: tokenB))
                #expect(bad.status == 404 && bad.body.isEmpty, "\(method) \(path)")
                #expect(wrong.status == bad.status && wrong.body == bad.body && wrong.headers.count == bad.headers.count)
            }
        }
        // The static page is served with the right token (and the guard did not hide it permanently).
        #expect(await api.handle(req("GET", "/dash/", token: tokenA)).status == 200)
        // Rejected requests never feed the operator login limits.
        for _ in 0..<2000 { _ = await api.handle(req("GET", "/dash/api/session", token: nil)) }
        try auth.limits.checkNotBlocked(now: Date())
        try auth.limits.check(.other, now: Date())
        let ok = await api.handle(req("GET", "/dash/api/session", token: tokenA))
        #expect(ok.status == 200)
    }

    @Test func disabledGuardAdmitsAll() async throws {
        let (api, _, _) = try await makeApi(guardian: DashboardProxyGuard(tokens: []))
        #expect(await api.handle(req("GET", "/dash/", token: nil)).status == 200)
    }

    @Test func loadsFromEnvironmentAndFile() throws {
        let file = NSTemporaryDirectory() + "proxy-token-" + UUID().uuidString
        try (tokenA + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let fromFile = try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN_FILE": file, "DASH_PROXY_TOKEN": tokenB])
        #expect(fromFile.admits(tokenA) && !fromFile.admits(tokenB), "file wins over environment")
        let rotating = try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN": tokenA, "DASH_PROXY_TOKEN_PREVIOUS": tokenB])
        #expect(rotating.admits(tokenA) && rotating.admits(tokenB))
    }

    @Test func startupFailsClosedWithoutToken() throws {
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard.loadForStartup(env: [:]) }
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN": ""]) }
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN_REQUIRED": "true"]) }
        #expect(throws: (any Error).self) { try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN_FILE": "/nonexistent/secret"]) }
        // An invalid token aborts even with required=false.
        #expect(throws: DashboardProxyGuardError.self) { try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN": "short", "DASH_PROXY_TOKEN_REQUIRED": "false"]) }
        let open = try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN_REQUIRED": "false"])
        #expect(!open.isEnabled && open.admits(nil))
    }

    @Test func errorsNeverContainTokens() {
        let bad = "tooShortSecret-xyz"
        do { _ = try DashboardProxyGuard.loadForStartup(env: ["DASH_PROXY_TOKEN": bad]) } catch {
            #expect(!"\(error)".contains(bad))
        }
    }

    @Test func registerMasksSecrets() throws {
        for key in ["DASH_PROXY_TOKEN", "DASH_PROXY_TOKEN_PREVIOUS"] {
            let setting = try #require(ConfigRegistry.settings.first { $0.key == key })
            #expect(setting.secret && setting.envOnly && !setting.editable)
        }
        let required = try #require(ConfigRegistry.settings.first { $0.key == "DASH_PROXY_TOKEN_REQUIRED" })
        #expect(required.envOnly && required.defaultValue == "true")
    }

    @Test func tokenNeverInConfigApiAnswer() async throws {
        let repo = MemoryRepo()
        let env = ["DASH_PROXY_TOKEN": tokenA, "DASH_PROXY_TOKEN_PREVIOUS": tokenB]
        let store = try await ConfigStore(env: env, repo: repo)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: store.entries().map { DashboardApi.entryJSON($0) }), as: UTF8.self)
        #expect(!text.contains(tokenA) && !text.contains(tokenB))
    }

    @Test func rootRedirectsOnlyBehindGuard() async throws {
        let (api, _, _) = try await makeApi(guardian: DashboardProxyGuard(tokens: [tokenA]))
        for method in ["GET", "HEAD"] {
            let hidden = await api.handle(req(method, "/", token: nil))
            #expect(hidden.status == 404 && hidden.body.isEmpty && !hidden.headers.contains { $0.0.lowercased() == "location" })
            let redirect = await api.handle(req(method, "/", token: tokenA))
            #expect(redirect.status == 302 && redirect.body.isEmpty)
            #expect(redirect.headers.contains { $0.0 == "Location" && $0.1 == "/dash/" })
            #expect(redirect.headers.contains { $0.0.lowercased() == "cache-control" && $0.1.contains("no-store") })
        }
        for path in ["/unknown", "/dash-x", "/index.html", "//"] {
            let r = await api.handle(req("GET", path, token: tokenA))
            #expect(r.status == 404 && r.body.isEmpty, "\(path)")
        }
        #expect(await api.handle(req("POST", "/", token: tokenA)).status == 404)
    }
}
