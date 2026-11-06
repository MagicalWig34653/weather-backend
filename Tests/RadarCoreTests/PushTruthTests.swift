import Foundation
import Testing
@testable import RadarCore

// The dashboard process may run with PUSH_ENABLED=false (separate service); the truth about push comes from the radar replicas
// through the shared database (replica heartbeat, push leader lease), never from the dashboard's own configuration.
extension DatabaseSuites {
@Suite("Push truth", .serialized)
struct PushTruthTests {
    /// Dashboard-only process: push off in its own config.
    private func dashboardEngine(_ repo: any Repo, now: Date) -> InsightsEngine {
        var config = Config(); config.push.enabled = false
        let source = RepoInsightsDataSource(repo: repo, enabledLayers: ["pressure"], context: { [config = config] in .make(config: config) }, clock: { now })
        return InsightsEngine(source: source, clock: { now })
    }

    @Test(arguments: RepoKind.allCases) func leaderLeaseOverridesDashboardConfig(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date()
        _ = try await repo.acquireLeader(name: PushService.leaderName, owner: "radar-1", leaseSeconds: 30)
        let overview = try await dashboardEngine(repo, now: now).overview(range: .h24)
        #expect(overview["pushEnabled"] as? Bool == true)
        let push = try await dashboardEngine(repo, now: now).push(range: .h24)
        let prerequisites = push["prerequisites"] as? [[String: Any]] ?? []
        #expect(prerequisites.first { $0["key"] as? String == "push_enabled" }?["ok"] as? Bool == true)
    }

    private func report(_ on: Bool, _ env: String? = "production", la: Bool = true) -> PushReplicaReport { .init(enabled: on, environments: env, liveActivity: la) }

    @Test(arguments: RepoKind.allCases) func replicaReportOverridesDashboardConfig(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date()
        try await repo.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: report(true, "sandbox"), now: now)
        let engine = dashboardEngine(repo, now: now)
        let overview = try await engine.overview(range: .h24)
        #expect(overview["pushEnabled"] as? Bool == true && overview["pushState"] as? String == "on")
        let push = try await engine.push(range: .h24)
        let pre = Dictionary(uniqueKeysWithValues: (push["prerequisites"] as? [[String: Any]] ?? []).map { ($0["key"] as! String, $0["ok"] as? Bool) })
        // Key and topic live only in the radar replicas; an active replica proves them.
        #expect(pre["push_enabled"] == true && pre["apns_topic_set"] == true && pre["apns_key_present"] == true && pre["capability_live_activity"] == true)
    }

    @Test(arguments: RepoKind.allCases) func oneReplicaOnOneOffIsOn(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date()
        try await repo.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: report(false, nil, la: false), now: now)
        try await repo.heartbeat(replicaID: "radar-2", slot: 2, appliedGeneration: 0, push: report(true, "both"), now: now)
        let truth = await PushTruth.resolve(repo: repo, now: now)
        #expect(truth.status == .on && truth.environments == [.production, .sandbox] && truth.liveActivity)
    }

    // `kind.make()` resets the shared database, so every case builds and checks its repo in turn.
    @Test(arguments: RepoKind.allCases) func offVersusUnknown(kind: RepoKind) async throws {
        let now = Date()
        let empty = try await kind.make()
        #expect(await PushTruth.resolve(repo: empty, now: now).status == .unknown)
        let engine = dashboardEngine(empty, now: now)
        let overview = try await engine.overview(range: .h24)
        #expect(overview["pushEnabled"] as? Bool == false && overview["pushState"] as? String == "unknown")
        let push = try await engine.push(range: .h24)
        let first = (push["prerequisites"] as? [[String: Any]])?.first
        #expect(first?["ok"] as? Bool == false && first?["detail"] as? String == "unknown")

        let off = try await kind.make()
        try await off.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: report(false, nil), now: now)
        #expect(await PushTruth.resolve(repo: off, now: now).status == .off)
        #expect(try await dashboardEngine(off, now: now).overview(range: .h24)["pushState"] as? String == "off")

        // Heartbeat without a report (older replica): not evidence for "off".
        let old = try await kind.make()
        try await old.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, now: now)
        #expect(await PushTruth.resolve(repo: old, now: now).status == .unknown)
    }

    @Test func freshnessBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func replica(_ age: TimeInterval, _ push: PushReplicaReport?) -> ReplicaRecord {
            ReplicaRecord(replicaID: "r", slot: 1, appliedGeneration: 0, startedAt: now.addingTimeInterval(-1000), lastSeenAt: now.addingTimeInterval(-age), push: push)
        }
        let limit = PushTruth.freshSeconds
        #expect(PushTruth.resolve(replicas: [replica(limit, report(true))], leaderSecondsLeft: nil, now: now).status == .on)
        #expect(PushTruth.resolve(replicas: [replica(limit + 1, report(true))], leaderSecondsLeft: nil, now: now).status == .unknown)
        // Stale "on" report does not count, but a fresh "off" replica plus no leader is "off".
        #expect(PushTruth.resolve(replicas: [replica(limit + 1, report(true)), replica(5, report(false, nil))], leaderSecondsLeft: nil, now: now).status == .off)
        // A valid leader lease proves push even when no replica reports it.
        #expect(PushTruth.resolve(replicas: [replica(5, report(false, nil))], leaderSecondsLeft: 12, now: now).status == .on)
        #expect(PushTruth.resolve(replicas: [], leaderSecondsLeft: 0, now: now).status == .unknown)
    }

    @Test func reportCarriesOnlyFixedLabels() {
        var c = Config(); c.push.enabled = true; c.push.topic = "de.secret.topic"; c.push.keyPEM = "PRIVATE-KEY"; c.push.keyID = "KEYID12345"; c.push.teamID = "TEAM123456"
        c.push.environments = [.sandbox, .production]
        let r = PushReplicaReport(config: c)
        #expect(r == PushReplicaReport(enabled: true, environments: "both", liveActivity: true))
        let text = "\(r)"
        #expect(!text.contains("secret") && !text.contains("PRIVATE") && !text.contains("KEYID") && !text.contains("TEAM1"))
        c.push.enabled = false
        #expect(PushReplicaReport(config: c) == PushReplicaReport(enabled: false, environments: nil, liveActivity: false))
    }

    @Test(arguments: RepoKind.allCases) func heartbeatKeepsReportAndUpdates(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date()
        try await repo.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: report(true, "sandbox", la: false), now: now)
        #expect(try await repo.replicas(now: now).first?.push == report(true, "sandbox", la: false))
        try await repo.heartbeat(replicaID: "radar-1", slot: 1, appliedGeneration: 0, push: report(false, nil, la: false), now: now.addingTimeInterval(5))
        #expect(try await repo.replicas(now: now).first?.push == report(false, nil, la: false))
    }
}
}
