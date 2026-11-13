import Foundation
import Testing
@testable import RadarCore

extension DatabaseSuites {
/// The server-wide region cell budget must hold under concurrent registrations of different installations,
/// also across replicas (separate processes, each with its own memo). Real database, no mock.
@Suite("Region cell budget under concurrency (real database)", .serialized)
struct RegionBudgetConcurrencyTests {
    private static let radius = 3
    private static let allowedRegions = 3
    private static let racers = 8

    private static func region(_ x: Int) -> PushSubscriptionInput {
        PushSubscriptionInput(gridVersion: 1, cellX: 40 + x, cellY: 50, threshold: 3, leadMinutes: 20, enabled: true,
                              kind: .circle, radiusCells: radius, minSharePercent: 10)
    }

    /// A second MariaRepo on the same database stands in for another replica.
    private static func replica() -> MariaRepo? {
        guard let env = RepoKind.dbEnv else { return nil }
        var c = smallConfig()
        c.dbHost = env["RADAR_TEST_DB_HOST"]!
        c.dbPort = Int(env["RADAR_TEST_DB_PORT"] ?? "3306")!
        c.dbName = env["RADAR_TEST_DB_NAME"] ?? "radar_test"
        c.dbUser = env["RADAR_TEST_DB_USER"] ?? "root"
        c.dbPassword = env["RADAR_TEST_DB_PASSWORD"] ?? ""
        c.migrationsDirectory = "migrations"
        return MariaRepo(config: c)
    }

    @Test(arguments: RepoKind.allCases) func concurrentRegionsOfDifferentInstallationsNeverExceedTheServerBudget(kind: RepoKind) async throws {
        let cells = PushRegion.cellCount(radius: Self.radius)
        let limits = RegionLimits(maxCellsServerwide: cells * Self.allowedRegions)
        let other = kind == .maria ? Self.replica() : nil
        for round in 0..<10 {
            let repo = try await kind.make()
            (repo as? MariaRepo)?.regionCellsMemo.withLock { $0 = nil }
            other?.regionCellsMemo.withLock { $0 = nil }
            var installs: [String] = []
            for _ in 0..<Self.racers {
                let id = UUID().uuidString.lowercased()
                installs.append(id)
                _ = try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array("s".utf8)), token: String(repeating: "a", count: 64),
                                                      env: .sandbox, locale: "de", now: run0)
            }
            let results = try await withThrowingTaskGroup(of: AddSubscriptionResult.self) { group in
                for (index, install) in installs.enumerated() {
                    let target: any Repo = index % 2 == 1 ? (other ?? repo) : repo
                    group.addTask {
                        try await target.addSubscription(installationID: install, id: UUID().uuidString.lowercased(), Self.region(index),
                                                         maxPerInstallation: 10, regionLimits: limits, now: run0)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            let created = results.filter { $0 == .created }.count
            #expect(created == Self.allowedRegions, "round \(round): \(results)")
            #expect(results.allSatisfy { $0 == .created || $0 == .regionCapacity }, "round \(round): \(results)")
            var stored = 0
            for install in installs { stored += try await repo.subscriptions(installationID: install).filter { $0.kind == .circle }.count }
            #expect(stored == Self.allowedRegions, "round \(round)")
        }
        await other?.shutdown()
    }

    /// Same lock for the Live Activity cap (`503 activity_full`): point subscriptions with `live_activity` across installations.
    @Test(arguments: RepoKind.allCases) func concurrentActivityOptInsNeverExceedTheServerCap(kind: RepoKind) async throws {
        let limits = RegionLimits(maxLiveActivitySubscriptions: Self.allowedRegions)
        let other = kind == .maria ? Self.replica() : nil
        for round in 0..<10 {
            let repo = try await kind.make()
            var installs: [String] = []
            for _ in 0..<Self.racers {
                let id = UUID().uuidString.lowercased()
                installs.append(id)
                _ = try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array("s".utf8)), token: String(repeating: "a", count: 64),
                                                      env: .sandbox, locale: "de", now: run0)
            }
            let results = try await withThrowingTaskGroup(of: AddSubscriptionResult.self) { group in
                for (index, install) in installs.enumerated() {
                    let target: any Repo = index % 2 == 1 ? (other ?? repo) : repo
                    group.addTask {
                        try await target.addSubscription(installationID: install, id: UUID().uuidString.lowercased(),
                                                         PushSubscriptionInput(gridVersion: 1, cellX: 40 + index, cellY: 50, threshold: 3, leadMinutes: 20,
                                                                               enabled: true, liveActivity: true),
                                                         maxPerInstallation: 10, regionLimits: limits, now: run0)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.filter { $0 == .created }.count == Self.allowedRegions, "round \(round): \(results)")
        }
        await other?.shutdown()
    }
}
}
