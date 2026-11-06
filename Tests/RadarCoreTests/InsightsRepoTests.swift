import Foundation
import Testing
@testable import RadarCore

// Insights adapter on the real repositories: Memory always, MariaDB when RADAR_TEST_DB_HOST is set (disposable database only).
// Nested in DatabaseSuites like the other database suites (one shared test database, never overlapping).
extension DatabaseSuites {
@Suite("Insights repo", .serialized)
struct InsightsRepoTests {
    private func hex(_ i: Int) -> String { String(repeating: String(format: "%02x", i), count: 32) }

    private func seed(_ repo: any Repo, now: Date) async throws -> (ids: [String], subs: [String]) {
        var ids: [String] = [], subs: [String] = []
        for i in 0..<9 {
            let id = UUID().uuidString.lowercased()
            ids.append(id)
            #expect(try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array("s\(i)".utf8)), token: hex(i + 1),
                                                      env: i < 2 ? .sandbox : .production, locale: "de", now: now) == .created)
        }
        for i in 0..<3 {
            let sub = UUID().uuidString.lowercased()
            subs.append(sub)
            let input = PushSubscriptionInput(gridVersion: PushGrid.version, cellX: 10 + i, cellY: 20, threshold: 3, leadMinutes: 20, enabled: true,
                                              timeSensitive: i == 1, liveActivity: i == 0)
            if i == 0 { try await repo.setLiveActivityStartToken(installationID: ids[2], token: String(repeating: "ab", count: 32)) }
            #expect(try await repo.addSubscription(installationID: ids[2 + i], id: sub, input, maxPerInstallation: 10, now: now) == .created)
        }
        #expect(try await repo.reserveActivity(subscriptionID: subs[0], now: now))
        _ = try await repo.setActivityToken(subscriptionID: subs[0], token: String(repeating: "cd", count: 32), now: now)
        _ = try await repo.commitEvaluation(runID: "r1", updates: [],
                                            outbox: [NewOutboxItem(subID: subs[1], dedupeKey: "k1", collapseID: "c1", payloadJSON: "{}", expiresAt: now.addingTimeInterval(3600))], now: now)
        try await repo.addStats(day: now, [StatDelta(metric: "requests", label: "radar_image:2xx", value: 90), StatDelta(metric: "requests", label: "radar_image:304", value: 10),
                                           StatDelta(metric: "errors_5xx", label: "radar_image", value: 1), StatDelta(metric: "cache_hit", label: "radar:memory", value: 80),
                                           StatDelta(metric: "cache_miss", label: "radar:db", value: 20), StatDelta(metric: "page_view", label: "landing_de", value: 4)])
        try await repo.heartbeat(replicaID: "replica-one", slot: 1, appliedGeneration: 0,
                                 push: PushReplicaReport(enabled: true, environments: "production", liveActivity: true), now: now)
        return (ids, subs)
    }

    @Test(arguments: RepoKind.allCases) func gaugesAndRoutesOnRealRepo(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 60)
        let (ids, subs) = try await seed(repo, now: now)
        var config = Config(); config.push.enabled = true; config.push.topic = "de.example.app"; config.push.keyPEM = "x"
        config.push.environments = [.production]
        let source = RepoInsightsDataSource(repo: repo, enabledLayers: [], context: { [config = config] in .make(config: config) })
        let engine = InsightsEngine(source: source, clock: { now })

        let g = try #require(try await source.pushGauges(now: now))
        #expect(g.installationsTotal == 9 && g.byEnv == ["sandbox": 2, "production": 7] && g.byLocale == ["de": 9])
        #expect(g.withDeviceToken == 9 && g.withStartToken == 1 && g.active1d == 9)
        #expect(g.subscriptionsTotal == 3 && g.subscriptionsEnabled == 3 && g.subscriptionsLiveActivity == 1 && g.subscriptionsLiveActivityWithStartToken == 1)
        #expect(g.subscriptionsTimeSensitive == 1)
        #expect(g.subscriptionsPerInstallation["0"] == 6 && g.subscriptionsPerInstallation["1"] == 3)
        #expect(g.regionsPerInstallation["0"] == 9)
        #expect(g.activeActivities == 1 && g.reservationsOpen == 0 && g.outboxWaiting == 1 && g.outboxRetrying == 0)
        #expect(g.threshold == ["3": 3] && g.lead == ["20": 3])

        let push = try await engine.push(range: .h24)
        let funnel = push["funnel"] as? [String: Any]
        let env = (funnel?["installations"] as? [String: Any])?["byEnv"] as? [[String: Any]] ?? []
        // sandbox 2 < 5 is suppressed; as the only one it drags production (7, smallest remaining) with it.
        #expect(env.map { $0["suppressed"] as? Bool } == [true, true] && env.allSatisfy { $0["count"] is NSNull })
        let prereq = push["prerequisites"] as? [[String: Any]] ?? []
        #expect(prereq.first { $0["key"] as? String == "apns_env_match" }?["ok"] as? Bool == false)
        #expect(prereq.first { $0["key"] as? String == "apns_env_match" }?["detail"] as? String == "sandbox_installs_with_production_env")
        #expect((push["triggers"] as? [Any])?.isEmpty == true && (push["delivery"] as? [String: Any])?["ratio"] is NSNull)   // counters exist, nothing counted yet

        let dist = try await engine.distribution()
        let per = dist["subscriptionsPerInstallation"] as? [[String: Any]] ?? []
        #expect(per.first { $0["key"] as? String == "1" }?["suppressed"] as? Bool == true)
        #expect(dist["liveActivityShare"] is NSNull)   // 3 subscriptions < k

        let ops = try await engine.ops(range: .d7)
        let layers = ops["layers"] as? [[String: Any]] ?? []
        #expect(layers.count == 1 + LayerCatalog.order.count && layers.first?["id"] as? String == "radar" && layers.first?["hasData"] as? Bool == false)
        #expect((ops["replicas"] as? [[String: Any]])?.first?["id"] as? String == DashboardApi.shortID("replica-one"))
        // Push is on but nobody holds the leader lease: the leader is reported as missing (holder null), not as unknown.
        #expect(ops["generation"] as? Int == 0 && (ops["leader"] as? [String: Any])?["holder"] is NSNull && ops["latency"] is NSNull)
        let cache = ops["cache"] as? [String: Any]
        #expect(cache?["hitRatio"] as? Double == 0.8 && cache?["dbReads"] as? Int == 20)

        let overview = try await engine.overview(range: .h24)
        let requests = (overview["kpis"] as? [String: Any])?["requests"] as? [String: Any]
        #expect(requests?["value"] as? Int == 100)

        // No identifier of any kind in any answer.
        var all: [[String: Any]] = [push, dist, ops, overview, try await engine.traffic(range: .h24), try await engine.findings()]
        all.append(try await engine.push(range: .d30))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: all), as: UTF8.self)
        for secret in ids + subs + [hex(1), String(repeating: "ab", count: 32), "replica-one"] { #expect(!text.contains(secret)) }
    }

    @Test(arguments: RepoKind.allCases) func emptyDatabaseGivesEmptyNotZeroAnswers(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 60)
        try await repo.heartbeat(replicaID: "replica-one", slot: 1, appliedGeneration: 0, now: now)
        var config = Config(); config.push.enabled = true
        _ = try await repo.acquireLeader(name: PushService.leaderName, owner: "replica-one", leaseSeconds: 30)
        let source = RepoInsightsDataSource(repo: repo, enabledLayers: [], context: { [config = config] in .make(config: config) })
        let engine = InsightsEngine(source: source, clock: { now })
        let g = try #require(try await source.pushGauges(now: now))
        #expect(g.installationsTotal == 0 && g.subscriptionsTotal == 0 && g.outboxOldestAgeSeconds == nil)
        let overview = try await engine.overview(range: .h24)
        #expect((overview["status"] as? [String: Any])?["level"] as? String == "unknown")
        let dist = try await engine.distribution()
        #expect((dist["lead"] as? [Any])?.isEmpty == true && dist["timeSensitiveShare"] is NSNull)
        let traffic = try await engine.traffic(range: .h24)
        #expect(traffic["hourly"] is NSNull && ((traffic["requests"] as? [String: Any])?["byStatusClass"] as? [Any])?.isEmpty == true)
    }
}
}
