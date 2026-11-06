import Foundation

/// One dashboard request, independent of the HTTP framework (the Vapor listener in `main.swift` only translates).
public struct DashboardHTTPRequest: Sendable {
    public var method: String
    /// Path without query string.
    public var path: String
    public var query: [String: String]
    public var body: [UInt8]
    public var info: DashboardRequestInfo
    public init(method: String, path: String, query: [String: String] = [:], body: [UInt8] = [], info: DashboardRequestInfo) {
        self.method = method; self.path = path; self.query = query; self.body = body; self.info = info
    }
}

/// Router of the dashboard listener (docs/dashboard-plan.md 2.2, docs-site/content/dashboard-api.md): auth routes, statistics,
/// configuration register, restart, static files. Every answer is JSON with `no-store` (API) or static with security headers.
/// Errors are `{"error":"<code>"}`; database errors never leak details (`data_unavailable`).
public final class DashboardApi: Sendable {
    public static let apiPrefix = "/dash/api"
    public static let maxBodyBytes = 32 * 1024

    public let auth: DashboardAuth
    let repo: any Repo
    let devices: DashboardDevices
    let pushActions: DashboardPushActions
    let store: ConfigStore
    let env: [String: String]
    let site: StaticSite
    let restartPolicy: RestartPolicy
    let clock: @Sendable () -> Date
    /// Extension point for further route families (WP11 to WP13): returns nil when the path is not theirs.
    let extra: (@Sendable (DashboardHTTPRequest, DashboardSessionInfo) async throws -> ApiResponse?)?

    public init(auth: DashboardAuth, repo: any Repo, store: ConfigStore,
                env: [String: String] = ProcessInfo.processInfo.environment, staticRoot: String = "/app/dashboard",
                restartPolicy: RestartPolicy = RestartPolicy(), clock: @escaping @Sendable () -> Date = { Date() },
                extra: (@Sendable (DashboardHTTPRequest, DashboardSessionInfo) async throws -> ApiResponse?)? = nil) {
        self.auth = auth; self.repo = repo; self.store = store; self.env = env; self.site = StaticSite(root: staticRoot)
        self.restartPolicy = restartPolicy; self.clock = clock; self.extra = extra
        pushActions = DashboardPushActions(repo: repo)
        devices = DashboardDevices(repo: repo, config: { store.snapshot() }, clock: clock)
    }

    private var sessions: DashboardSessions { auth.sessions }

    // MARK: entry point

    public func handle(_ req: DashboardHTTPRequest) async -> ApiResponse {
        let path = req.path
        let isAPI = path == Self.apiPrefix || path.hasPrefix(Self.apiPrefix + "/")
        guard isAPI || path == "/dash" || path.hasPrefix("/dash/") else { return Self.empty(404) }
        do {
            try sessions.checkHost(req.info)
            if !isAPI {
                guard req.method == "GET" || req.method == "HEAD" else { return Self.error(405, "not_found") }
                return site.response(path: path)
            }
            guard req.body.count <= Self.maxBodyBytes else { return Self.error(413, "validation") }
            return try await route(req, String(path.dropFirst(Self.apiPrefix.count)))
        } catch let error as DashboardAuthError {
            return Self.authError(error)
        } catch let error as ConfigWriteError {
            switch error {
            case .unknownKey: return Self.error(404, "not_found")
            case .notEditable, .lockedByEnv: return Self.error(409, "locked_by_env")
            case .invalid: return Self.error(400, "validation")
            }
        } catch {
            return Self.error(503, "data_unavailable")
        }
    }

    private func route(_ req: DashboardHTTPRequest, _ sub: String) async throws -> ApiResponse {
        let now = clock()
        let m = req.method
        // Public routes (no session yet).
        switch (m, sub) {
        case ("GET", "/session"):
            try auth.limits.check(.session, now: now)
            return Self.json(200, try await auth.sessionState(cookieHeader: req.info.cookieHeader))
        case ("POST", "/setup/begin"):
            try sessions.checkWriteOrigin(req.info)
            return Self.json(200, try await auth.beginSetup())
        case ("POST", "/setup/finish"):
            try sessions.checkWriteOrigin(req.info)
            return Self.cookie(try await auth.finishSetup(body: req.body).setCookie)
        case ("POST", "/login/begin"):
            try sessions.checkWriteOrigin(req.info)
            return Self.json(200, try await auth.beginLogin())
        case ("POST", "/login/finish"):
            try sessions.checkWriteOrigin(req.info)
            return Self.cookie(try await auth.finishLogin(body: req.body).setCookie)
        default: break
        }

        // Everything else needs a session (and CSRF for writes).
        let session = try await sessions.authenticate(req.info)
        if req.info.isWrite { try sessions.authorizeWrite(req.info, session: session) }
        try auth.limits.check(.other, now: now)

        switch (m, sub) {
        case ("POST", "/logout"):
            return Self.cookie(try await auth.logout(cookieHeader: req.info.cookieHeader))
        case ("GET", "/stats/overview"):
            let days = try Self.days(req.query)
            return Self.json(200, try await StatsQuery(repo: repo).overview(from: now.addingTimeInterval(-Double(days - 1) * 86400), to: now))
        case ("GET", "/stats/daily"):
            let days = try Self.days(req.query)
            return Self.json(200, try await StatsQuery(repo: repo).trafficSeries(from: now.addingTimeInterval(-Double(days - 1) * 86400), to: now))
        case ("GET", "/config"):
            await store.refresh()
            return Self.object(200, ["revision": store.revision, "entries": store.entries().map(Self.entryJSON)])
        case ("GET", "/config/audit"):
            return try await audit(req.query)
        case ("GET", "/restart"):
            return try await restartState()
        case ("POST", "/restart"):
            return try await restart(now: now)
        default: break
        }
        if sub.hasPrefix("/config/"), m == "PUT" || m == "DELETE" {
            let key = String(sub.dropFirst("/config/".count))
            try auth.limits.check(.configWrite, now: now)
            return try await writeConfig(key: key, put: m == "PUT", body: req.body, now: now)
        }
        if let response = try await devices.handle(req, sub, now: now, audit: repo) { return response }
        if let response = try await pushActions.handle(req, sub, now: now) { return response }
        if let extra, let response = try await extra(req, session) { return response }
        return Self.error(404, "not_found")
    }

    // MARK: statistics

    static func days(_ query: [String: String]) throws -> Int {
        guard let raw = query["days"] else { return 30 }
        guard let n = Int(raw), (1...DashboardRetention.statsDays).contains(n) else { throw DashboardAuthError.validation }
        return n
    }

    // MARK: configuration

    private struct JSONScalar: Decodable {
        let text: String
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
            else if let i = try? c.decode(Int.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(d) }
            else if let s = try? c.decode(String.self) { text = s }
            else if let a = try? c.decode([String].self) { text = a.joined(separator: ",") }
            else { throw DashboardAuthError.validation }
        }
    }
    private struct ValueBody: Decodable { let value: JSONScalar }

    private func writeConfig(key: String, put: Bool, body: [UInt8], now: Date) async throws -> ApiResponse {
        var raw: String?
        if put {
            guard let parsed = try? JSONDecoder().decode(ValueBody.self, from: Data(body)) else { throw DashboardAuthError.validation }
            raw = parsed.value.text
        }
        do {
            try await ConfigRegistry.write(key: key, raw: raw, env: env, store: DashboardConfigStore(repo: repo), now: now)
        } catch let error as ConfigWriteError { throw error }
        await store.refresh()
        guard let entry = store.entries().first(where: { $0.key == key }) else { throw ConfigWriteError.unknownKey }
        return Self.object(200, ["entry": Self.entryJSON(entry)])
    }

    /// Contract form of a register row (`dashboard-api.md`, ConfigEntry): typed `default`/`value`, `null` for secrets.
    static func entryJSON(_ e: ConfigEntry) -> [String: Any] {
        let null = NSNull()
        func typed(_ text: String?) -> Any {
            guard let text else { return null }
            switch e.type {
            case "int": return Int(text).map { $0 as Any } ?? text
            case "number": return Double(text).map { $0 as Any } ?? text
            case "bool":
                if text == "true" { return true }
                if text == "false" { return false }
                return text
            case "layers": return text.isEmpty ? [String]() : text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            default: return text
            }
        }
        func bound(_ v: Double?) -> Any {
            guard let v else { return null }
            return e.type == "int" ? Int(v) : v
        }
        let type: String
        switch e.type {
        case "number": type = "double"
        case "choice": type = "enum"
        case "layers": type = "list"
        case "text", "url", "secret": type = "string"
        default: type = e.type
        }
        return ["key": e.key, "group": e.group, "type": type, "default": e.secret ? "" : typed(e.defaultValue),
                "min": bound(e.minimum), "max": bound(e.maximum), "unit": e.unit as Any? ?? null, "description": e.summary,
                "apply": e.apply == .live ? "live" : "restart", "source": e.source.rawValue,
                "locked": e.lockedByEnv || !e.editable, "value": e.secret ? null : typed(e.value), "restartPending": e.restartPending]
    }

    private func audit(_ query: [String: String]) async throws -> ApiResponse {
        var limit = 50
        if let raw = query["limit"] {
            guard let n = Int(raw), (1...200).contains(n) else { throw DashboardAuthError.validation }
            limit = n
        }
        var action: DashboardAuditAction?
        if let raw = query["action"] {
            guard let a = DashboardAuditAction(rawValue: raw) else { throw DashboardAuthError.validation }
            action = a
        }
        var rows = try await repo.auditEntries(limit: action == nil ? limit : 1000)
        if let action { rows = Array(rows.filter { $0.action == action }.prefix(limit)) }
        let entries: [[String: Any]] = rows.map { r in
            ["id": r.id, "at": TimeUtil.toISO(r.at), "action": r.action.rawValue, "configKey": r.key as Any? ?? NSNull(),
             "oldValue": r.oldValue as Any? ?? NSNull(), "newValue": r.newValue as Any? ?? NSNull(),
             "deviceRef": r.deviceRef as Any? ?? NSNull(), "outcome": r.outcome as Any? ?? NSNull()]
        }
        return Self.object(200, ["entries": entries])
    }

    // MARK: restart (plan 5.3)

    /// First 8 hex characters of SHA-256(replica id): no host names in answers.
    static func shortID(_ id: String) -> String { String(Hashing.sha256Hex(Array(id.utf8)).prefix(8)) }

    private func restartState() async throws -> ApiResponse {
        let generation = try await repo.generation().generation
        let replicas = try await repo.replicas(now: clock()).map { r -> [String: Any] in
            ["id": Self.shortID(r.replicaID), "appliedGeneration": r.appliedGeneration, "startedAt": TimeUtil.toISO(r.startedAt),
             "state": r.appliedGeneration >= generation ? "current" : "waiting"]
        }
        return Self.object(200, ["generation": generation, "pending": store.restartPendingKeys(), "replicas": replicas])
    }

    private func restart(now: Date) async throws -> ApiResponse {
        try auth.limits.check(.restart, now: now)
        if let generation = try await repo.requestRestart(minInterval: restartPolicy.minimumIntervalSeconds, now: now) {
            return Self.object(202, ["generation": generation])
        }
        var retry = Int(restartPolicy.minimumIntervalSeconds)
        if case .tooSoon(let seconds) = restartPolicy.trigger(lastRequestedAt: try await repo.generation().requestedAt, now: now) { retry = seconds }
        throw DashboardAuthError.rateLimited(retry)
    }

    // MARK: response helpers

    static let apiHeaders: [(String, String)] = [("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]

    static func empty(_ status: Int) -> ApiResponse { ApiResponse(status: status, headers: apiHeaders, body: []) }

    public static func error(_ status: Int, _ code: String, retryAfter: Int? = nil) -> ApiResponse {
        var headers = apiHeaders + [("Content-Type", "application/json")]
        if let retryAfter { headers.append(("Retry-After", String(retryAfter))) }
        return ApiResponse(status: status, headers: headers, body: Array("{\"error\":\"\(code)\"}".utf8))
    }

    public static func authError(_ error: DashboardAuthError) -> ApiResponse {
        Self.error(error.status, error.code, retryAfter: error.retryAfter)
    }

    static func json<T: Encodable>(_ status: Int, _ value: T) -> ApiResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return error(503, "data_unavailable") }
        return ApiResponse(status: status, headers: apiHeaders + [("Content-Type", "application/json")], body: Array(data))
    }

    static func object(_ status: Int, _ value: [String: Any]) -> ApiResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return error(503, "data_unavailable") }
        return ApiResponse(status: status, headers: apiHeaders + [("Content-Type", "application/json")], body: Array(data))
    }

    static func cookie(_ setCookie: String) -> ApiResponse {
        ApiResponse(status: 204, headers: apiHeaders + [("Set-Cookie", setCookie)], body: [])
    }
}
