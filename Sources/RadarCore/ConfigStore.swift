import Foundation

/// Read access to the effective configuration for consumers: either a fixed `Config` (tests, start-time use) or the live
/// snapshot of a `ConfigStore`. Consumers call it once per tick/request, never cache the result.
public struct ConfigProvider: Sendable {
    private let read: @Sendable () -> Config
    public init(_ config: Config) { read = { config } }
    public init(_ read: @escaping @Sendable () -> Config) { self.read = read }
    public func callAsFunction() -> Config { read() }
}

/// Effective configuration of the running process (docs/dashboard-plan.md 5.1): ENV > dashboard value > default.
///
/// - `snapshot()` is cheap and thread-safe (lock); `live` values follow dashboard changes within one polling interval.
/// - Values of `restart` settings stay at what the process started with: a changed dashboard value only shows up as
///   `restartPendingKeys()` until the controlled restart (plan 5.3).
/// - A failing database never changes the snapshot.
public final class ConfigStore: @unchecked Sendable {
    public static let pollSeconds: Double = 30
    public static let pollJitterSeconds: Double = 5

    private struct State {
        var config: Config
        var stored: [String: String]
        var revision: Int
    }

    private let lock = NSLock()
    private var state: State
    private let env: [String: String]
    private let loadState: (@Sendable () async throws -> DashboardConfigState)?
    private let loadRevision: (@Sendable () async throws -> Int)?
    private let warn: @Sendable (String) -> Void
    /// Effective dashboard values at process start (the "loaded" values; what `restart` settings run with).
    public let startOverrides: [String: String]
    public let startRevision: Int

    /// Loads ENV and, if `repo` is given, the dashboard values. A broken or unreachable database at start gives ENV + defaults
    /// (never a startup abort because of a dashboard value); invalid ENV still throws (as before).
    public convenience init(env: [String: String] = ProcessInfo.processInfo.environment, repo: (any DashboardRepo)? = nil,
                            warn: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        var state: (@Sendable () async throws -> DashboardConfigState)?
        var revision: (@Sendable () async throws -> Int)?
        if let repo {
            state = { try await repo.configState() }
            revision = { try await repo.configRevision() }
        }
        try await self.init(env: env, state: state, revision: revision, warn: warn)
    }

    /// Same with the two reads as closures (bound to `DashboardRepo.configState/configRevision`; also used by tests).
    public init(env: [String: String] = ProcessInfo.processInfo.environment,
                state loadState: (@Sendable () async throws -> DashboardConfigState)?,
                revision loadRevision: (@Sendable () async throws -> Int)?,
                warn: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        self.env = env; self.loadState = loadState; self.loadRevision = loadRevision; self.warn = warn
        var stored: [String: String] = [:]
        var revision = 0
        if let loadState {
            do {
                let loaded = try await loadState()
                stored = Dictionary(loaded.overrides.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
                revision = loaded.revision
            } catch { warn("config overrides not loaded (database): using environment and defaults") }
        }
        let config = try ConfigRegistry.resolve(env: env, stored: stored, warn: warn)
        startOverrides = ConfigRegistry.effectiveOverrides(env: env, stored: stored)
        startRevision = revision
        state = State(config: config, stored: stored, revision: revision)
    }

    /// Fixed configuration without database (tests, tools).
    public init(fixed config: Config) {
        env = [:]; loadState = nil; loadRevision = nil; warn = { _ in }
        startOverrides = [:]; startRevision = 0
        state = State(config: config, stored: [:], revision: 0)
    }

    public func snapshot() -> Config { lock.withLock { state.config } }
    public var revision: Int { lock.withLock { state.revision } }
    public var provider: ConfigProvider { ConfigProvider { [self] in snapshot() } }

    /// Dashboard values as last loaded (raw, unvalidated).
    public func storedValues() -> [String: String] { lock.withLock { state.stored } }

    /// Keys of `restart` settings whose current dashboard value differs from the start value (banner and confirmation dialog).
    public func restartPendingKeys() -> [String] {
        let (stored, _) = lock.withLock { (state.stored, state.revision) }
        return ConfigRegistry.restartPendingKeys(env: env, stored: stored, startOverrides: startOverrides)
    }

    /// Register rows for the dashboard with the current state.
    public func entries() -> [ConfigEntry] {
        ConfigRegistry.entries(env: env, stored: storedValues(), startOverrides: startOverrides)
    }

    /// One poll: compares the cheap revision, reloads on change. Returns true if the snapshot was replaced.
    @discardableResult
    public func refresh() async -> Bool {
        guard let loadState, let loadRevision else { return false }
        do {
            let current = try await loadRevision()
            guard current != revision else { return false }
            let loaded = try await loadState()
            let stored = Dictionary(loaded.overrides.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            // Only live settings follow the database; restart settings keep their start value.
            var merged = startOverrides.filter { ConfigRegistry.setting($0.key)?.apply == .restart }
            for (key, value) in stored where ConfigRegistry.setting(key)?.apply == .live { merged[key] = value }
            let config = try ConfigRegistry.resolve(env: env, stored: merged, warn: warn)
            lock.withLock { state = State(config: config, stored: stored, revision: loaded.revision) }
            return true
        } catch {
            return false
        }
    }

    /// Polls every 30 s plus 0...5 s jitter until cancelled.
    public func run() async {
        while !Task.isCancelled {
            let wait = Self.pollSeconds + Double.random(in: 0...Self.pollJitterSeconds)
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } catch { return }
            await refresh()
        }
    }
}
