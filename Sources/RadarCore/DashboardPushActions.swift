import Foundation

/// Global operator actions (docs-site/content/dashboard-api.md "Aktionen (global)"): push pause and cache clear.
/// Session, CSRF and the general limit are checked by `DashboardApi` before; here: body validation, own rate limit, audit.
/// The state lives in the database (`push_state`), so every replica sees it; nothing here touches tokens, ids or cells.
final class DashboardPushActions: Sendable {
    let repo: any Repo
    private let limiter = RateLimiter()
    static let pauseLimitPerMinute = 6
    static let cacheLimitPerMinute = 2

    init(repo: any Repo) { self.repo = repo }

    /// nil: not an action route.
    func handle(_ req: DashboardHTTPRequest, _ sub: String, now: Date) async throws -> ApiResponse? {
        switch (req.method, sub) {
        case ("PUT", "/push/pause"):
            guard limiter.allow("pause", limit: Self.pauseLimitPerMinute, window: 60, now: now) else {
                return DashboardApi.error(429, "rate_limited", retryAfter: 60)
            }
            guard let object = Self.object(req.body), object.count == 1, let paused = object["paused"] as? Bool else {
                return DashboardApi.error(400, "validation")
            }
            let since = try await repo.setPushPaused(paused, now: now)
            try await repo.appendDeviceAudit(action: .pushPause, deviceRef: nil, outcome: paused ? "paused" : "resumed", now: now)
            return DashboardApi.object(200, ["paused": since != nil, "since": since.map { TimeUtil.toISO($0) } ?? NSNull()])
        case ("POST", "/cache/clear"):
            guard limiter.allow("cache", limit: Self.cacheLimitPerMinute, window: 60, now: now) else {
                return DashboardApi.error(429, "rate_limited", retryAfter: 60)
            }
            guard let object = Self.object(req.body), object.count == 1, let layer = object["layer"] as? String,
                  CacheClearScope.valid.contains(layer) else { return DashboardApi.error(400, "validation") }
            let generation = try await repo.requestCacheClear(scope: layer)
            try await repo.appendDeviceAudit(action: .cacheClear, deviceRef: nil, outcome: layer, now: now)
            return DashboardApi.object(202, ["generation": generation, "layer": layer])
        case (_, "/push/pause"), (_, "/cache/clear"):
            return DashboardApi.error(405, "not_found")
        default:
            return nil
        }
    }

    static func object(_ body: [UInt8]) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }
}

/// Replica side of "cache clear": remembers the last applied generation and clears the in-process slot cache when it moved.
/// The first observation after a start only records the generation (a fresh process has an empty cache anyway).
public final class CacheClearWatcher: Sendable {
    private let repo: any Repo
    private let cache: SlotCache
    private let applied = PushGuarded<Int?>(nil)

    public init(repo: any Repo, cache: SlotCache) { self.repo = repo; self.cache = cache }

    /// Returns true when the cache was cleared.
    @discardableResult
    public func poll() async -> Bool {
        guard let state = try? await repo.cacheClearState() else { return false }
        let previous = applied.withLock { value -> Int? in defer { value = state.generation }; return value }
        guard let previous, previous != state.generation else { return false }
        await cache.clear(scope: state.scope)
        return true
    }

    /// Poll loop (30 seconds, as the contract says); cancelled on shutdown.
    public func run(interval: TimeInterval = 30) async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
        }
    }
}
