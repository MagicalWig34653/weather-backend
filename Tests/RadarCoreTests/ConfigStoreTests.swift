import Foundation
import Testing
@testable import RadarCore

// ConfigStore, the DashboardRepo adapter and the live consumers. Memory and MariaDB (RADAR_TEST_DB_HOST) share the contract.
extension DatabaseSuites {
@Suite("ConfigStore and live configuration", .serialized)
struct ConfigStoreTests {
    @Test(arguments: RepoKind.allCases) func liveFollowsDashboardRestartDoesNot(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let dashboard = DashboardConfigStore(repo: repo)
        _ = try await ConfigRegistry.write(key: "FETCH_WORKERS", raw: "2", env: [:], store: dashboard)
        let store = try await ConfigStore(env: [:], repo: repo)
        let start = store.snapshot()
        #expect(start.workers == 2 && start.historyHours == 48)
        #expect(store.restartPendingKeys().isEmpty)
        #expect(await store.refresh() == false)               // unchanged revision

        _ = try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: "24", env: [:], store: dashboard)   // live
        _ = try await ConfigRegistry.write(key: "FETCH_WORKERS", raw: "4", env: [:], store: dashboard)    // restart
        _ = try await ConfigRegistry.write(key: "PUSH_RATE_PER_INSTALLATION", raw: "100", env: [:], store: dashboard)
        #expect(await store.refresh() == true)
        let now = store.snapshot()
        #expect(now.historyHours == 24)
        #expect(now.push.rateLimits.perInstallation == 100)
        #expect(now.workers == 2)                              // still the start value
        #expect(store.restartPendingKeys() == ["FETCH_WORKERS"])
        let row = try #require(store.entries().first { $0.key == "FETCH_WORKERS" })
        #expect(row.restartPending && row.value == "4")
        #expect(store.provider().historyHours == 24)

        // Reset removes the live value again; a new process (store) starts with the stored restart value and nothing pending.
        _ = try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: nil, env: [:], store: dashboard)
        #expect(await store.refresh() == true && store.snapshot().historyHours == 48)
        let next = try await ConfigStore(env: [:], repo: repo)
        #expect(next.snapshot().workers == 4 && next.restartPendingKeys().isEmpty)
    }

    @Test(arguments: RepoKind.allCases) func envWinsAndEmptyEnvDoesNot(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let dashboard = DashboardConfigStore(repo: repo)
        _ = try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: "10", env: [:], store: dashboard)
        _ = try await ConfigRegistry.write(key: "RETENTION_RUNS", raw: "20", env: [:], store: dashboard)
        let store = try await ConfigStore(env: ["HISTORY_HOURS": "12", "RETENTION_RUNS": ""], repo: repo)
        #expect(store.snapshot().historyHours == 12 && store.snapshot().retentionRuns == 20)
        let hist = try #require(store.entries().first { $0.key == "HISTORY_HOURS" })
        #expect(hist.source == .env && hist.lockedByEnv)
    }

    @Test func databaseFailureKeepsSnapshot() async throws {
        let repo = MemoryRepo()
        let failing = Locked(false)
        struct Down: Error {}
        let state: @Sendable () async throws -> DashboardConfigState = {
            if failing.withLock({ $0 }) { throw Down() }
            return try await repo.configState()
        }
        let revision: @Sendable () async throws -> Int = {
            if failing.withLock({ $0 }) { throw Down() }
            return try await repo.configRevision()
        }
        _ = try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: "10", env: [:], store: DashboardConfigStore(repo: repo))
        let store = try await ConfigStore(state: state, revision: revision)
        #expect(store.snapshot().historyHours == 10)
        failing.withLock { $0 = true }
        #expect(await store.refresh() == false && store.snapshot().historyHours == 10)
        // A database that is down at start gives environment and defaults instead of an abort.
        let cold = try await ConfigStore(state: state, revision: revision)
        #expect(cold.snapshot().historyHours == 48)
    }

    @Test(arguments: RepoKind.allCases) func invalidStoredValueIsIgnoredAtStart(kind: RepoKind) async throws {
        let repo = try await kind.make()
        _ = try await repo.setConfigOverride(key: "RETENTION_RUNS", value: "3", audit: .values, now: run0)       // below the limit
        _ = try await repo.setConfigOverride(key: "JITTER_SECONDS", value: "30", audit: .values, now: run0)
        let warnings = Locked<[String]>([])
        let store = try await ConfigStore(env: [:], repo: repo, warn: { w in warnings.withLock { $0.append(w) } })
        #expect(store.snapshot().retentionRuns == 16 && store.snapshot().jitterSeconds == 30)
        #expect(warnings.withLock { $0 }.count == 1)
    }

    @Test(arguments: RepoKind.allCases) func restartCoordinatorOnRepo(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let exited = Locked(false)
        let a = try await RestartCoordinator.make(repo: repo, replicaID: "r1", slot: 1, isLeader: { true }, leaderSlot: { 1 },
                                                  shutdown: { exited.withLock { $0 = true } })
        #expect(await a.tick() == .none)
        #expect(try await repo.requestRestart(minInterval: 300, now: Date()) != nil)
        #expect(await a.tick() == .exit && exited.withLock { $0 })
        let b = try await RestartCoordinator.make(repo: repo, replicaID: "r1", slot: 1, isLeader: { true }, leaderSlot: { 1 }, shutdown: {})
        #expect(await b.tick() == .none)                       // new process: no loop
    }

    @Test func liveRateLimitsReachThePushApi() async throws {
        let config = Locked(hardeningLikeConfig())
        let api = PushApi(repo: MemoryRepo(), configProvider: ConfigProvider { config.withLock { $0 } }, clock: { run0 })
        let id = UUID().uuidString.lowercased()
        let secret = String(repeating: "a", count: 40)
        func call() async -> Int {
            await api.handle(method: "GET", path: "/v1/push/installations/\(id)/subscriptions", secret: secret, body: [])?.status ?? 0
        }
        config.withLock { $0.push.rateLimits.perInstallation = 10; $0.push.rateLimits.failedAuth = 60 }
        var statuses: [Int] = []
        for _ in 0..<12 { statuses.append(await call()) }
        #expect(!statuses.contains(429) || statuses.firstIndex(of: 429)! >= 10)
        // Lowering the limit takes effect on the very next request, without a new PushApi.
        config.withLock { $0.push.rateLimits.perInstallation = 10 }
        #expect(await call() == 429)
    }
}
}

private func hardeningLikeConfig() -> Config {
    smallConfig { $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox, .production] }
}

