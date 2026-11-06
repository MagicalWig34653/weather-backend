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
        // Single flight: parallel identical requests share one computation (the dashboard polls six routes every 30 seconds).
        let engine = self.engine
        let rangeCopy = range
        let task = cache.flight(key) {
            switch name {
            case "overview": return try await engine.overview(range: rangeCopy)
            case "ops": return try await engine.ops(range: rangeCopy)
            case "traffic": return try await engine.traffic(range: rangeCopy)
            case "push": return try await engine.push(range: rangeCopy)
            case "distribution": return try await engine.distribution()
            default: return try await engine.findings()
            }
        }
        do {
            let body = try await task.value.value
            cache.land(key)
            let response = DashboardApi.object(200, body)
            cache.put(key, response, now: now, ttl: Self.cacheSeconds)
            cache.remember(key, body: body, at: now)
            return response
        } catch {
            cache.land(key)
            // stale-while-error: the last good answer (at most 10 minutes old) beats an error.
            if let last = cache.lastGood(key, now: clock(), maxAge: Self.staleMaxSeconds) {
                var body = last.body
                body["stale"] = true
                body["staleSeconds"] = max(0, Int(clock().timeIntervalSince(last.at)))
                return DashboardApi.object(200, body)
            }
            return DashboardApi.error(503, "data_unavailable", retryAfter: 5)
        }
    }

    public static let computeTimeout: TimeInterval = 10
    public static let staleMaxSeconds: TimeInterval = 600

    struct TimedOut: Error {}
    static func withTimeout(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> [String: Any]) async throws -> SendableBody {
        try await withThrowingTaskGroup(of: SendableBody.self) { group in
            group.addTask { SendableBody(value: try await work()) }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); throw TimedOut() }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
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

struct SendableBody: @unchecked Sendable { let value: [String: Any] }

private final class InsightsAnswerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var good: [String: (at: Date, body: [String: Any])] = [:]
    private var flights: [String: Task<SendableBody, Error>] = [:]

    func flight(_ key: String, _ work: @escaping @Sendable () async throws -> [String: Any]) -> Task<SendableBody, Error> {
        lock.withLock {
            if let t = flights[key] { return t }
            let t = Task { try await InsightsRoutes.withTimeout(InsightsRoutes.computeTimeout, work) }
            flights[key] = t
            return t
        }
    }
    func land(_ key: String) { lock.withLock { flights[key] = nil } }
    func remember(_ key: String, body: [String: Any], at: Date) { lock.withLock { good[key] = (at, body) } }
    func lastGood(_ key: String, now: Date, maxAge: TimeInterval) -> (at: Date, body: [String: Any])? {
        lock.withLock { good[key].flatMap { now.timeIntervalSince($0.at) <= maxAge ? $0 : nil } }
    }
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
