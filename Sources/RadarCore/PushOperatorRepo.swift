import Foundation

/// Operator switches that live in the database (`push_state`, no migration): push pause and the cache-clear generation.
public struct CacheClearState: Sendable, Equatable {
    public var generation: Int
    /// `all`, `radar` or a layer id.
    public var scope: String
    public init(generation: Int, scope: String) { self.generation = generation; self.scope = scope }
}

/// Counts only (no ids, tokens or cells): the outbox as seen right now.
public struct OutboxGauge: Sendable, Equatable {
    public var waiting = 0
    /// Pending items that have already failed at least once.
    public var retrying = 0
    public var oldestAgeSeconds: Int?
    /// Items finished as `dropped` or still pending past their expiry in the last 24 hours.
    public var droppedOrExpired24h = 0
    public init(waiting: Int = 0, retrying: Int = 0, oldestAgeSeconds: Int? = nil, droppedOrExpired24h: Int = 0) {
        self.waiting = waiting; self.retrying = retrying; self.oldestAgeSeconds = oldestAgeSeconds; self.droppedOrExpired24h = droppedOrExpired24h
    }
}

public protocol PushOperatorRepo: Sendable {
    /// Since when the operator paused sending; nil = not paused.
    func pushPausedSince() async throws -> Date?
    /// Idempotent: pausing while paused keeps the original time. Returns the state afterwards.
    @discardableResult func setPushPaused(_ paused: Bool, now: Date) async throws -> Date?
    func cacheClearState() async throws -> CacheClearState
    /// Increases the generation by one and remembers the scope; returns the new generation.
    func requestCacheClear(scope: String) async throws -> Int
    func outboxGauge(now: Date) async throws -> OutboxGauge
}

/// Valid `layer` values of `POST /dash/api/cache/clear`.
public enum CacheClearScope {
    public static var valid: Set<String> { Set(["all", "radar"] + LayerCatalog.order) }
}
