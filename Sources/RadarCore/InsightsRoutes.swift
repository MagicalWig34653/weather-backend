import Foundation

/// The six `GET /dash/api/insights/*` routes as an extension handler of `DashboardApi` (parameter `extra`).
/// Session, host and rate limit are already enforced by the router before `extra` is called. Answers are cached for 5 seconds
/// per route and range (docs-site/content/dashboard-api.md, "Konventionen").
public final class InsightsRoutes: Sendable {
    public static let prefix = "/dash/api/insights/"
    public static let cacheSeconds: TimeInterval = 5

    let engine: InsightsEngine
    let clock: @Sendable () -> Date
    private let cache = InsightsAnswerCache()

    public init(engine: InsightsEngine, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine; self.clock = clock
    }

    /// Router extension: nil when the path is not an insights route.
    public func handle(_ req: DashboardHTTPRequest, _ session: DashboardSessionInfo) async throws -> ApiResponse? {
        guard req.path.hasPrefix(Self.prefix) else { return nil }
        let name = String(req.path.dropFirst(Self.prefix.count))
        guard ["overview", "ops", "traffic", "push", "distribution", "findings"].contains(name) else { return nil }
        guard req.method == "GET" else { return DashboardApi.error(405, "not_found") }

        var range = InsightsRange.h24
        if name != "findings", let raw = req.query["range"] {
            guard let r = InsightsRange(rawValue: raw) else { return DashboardApi.error(400, "validation") }
            range = r
        }
        let key = name + ":" + (name == "findings" || name == "distribution" ? "-" : range.rawValue)
        let now = clock()
        if let hit = cache.get(key, now: now) { return hit }
        do {
            let body: [String: Any]
            switch name {
            case "overview": body = try await engine.overview(range: range)
            case "ops": body = try await engine.ops(range: range)
            case "traffic": body = try await engine.traffic(range: range)
            case "push": body = try await engine.push(range: range)
            case "distribution": body = try await engine.distribution()
            default: body = try await engine.findings()
            }
            let response = DashboardApi.object(200, body)
            cache.put(key, response, now: now, ttl: Self.cacheSeconds)
            return response
        } catch {
            return DashboardApi.error(503, "data_unavailable")
        }
    }
}

/// Hook for `DashboardApi(extra:)`: `DashboardApi(..., extra: registerInsightsRoutes(engine: engine))`. If further route families
/// exist, call the handlers one after the other and return the first non-nil answer.
public func registerInsightsRoutes(engine: InsightsEngine, clock: @escaping @Sendable () -> Date = { Date() })
    -> @Sendable (DashboardHTTPRequest, DashboardSessionInfo) async throws -> ApiResponse? {
    let routes = InsightsRoutes(engine: engine, clock: clock)
    return { req, session in try await routes.handle(req, session) }
}

private final class InsightsAnswerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (until: Date, response: ApiResponse)] = [:]

    func get(_ key: String, now: Date) -> ApiResponse? {
        lock.withLock { entries[key].flatMap { $0.until > now ? $0.response : nil } }
    }

    func put(_ key: String, _ response: ApiResponse, now: Date, ttl: TimeInterval) {
        lock.withLock {
            if entries.count > 64 { entries = entries.filter { $0.value.until > now } }
            entries[key] = (now.addingTimeInterval(ttl), response)
        }
    }
}
