import Foundation
import Testing
@testable import RadarCore

// Insights adapter on the counters of WP11 (hourly stats, push counters, leader lease, cache fill) and the live threshold lookup.
extension DatabaseSuites {
@Suite("Insights wiring", .serialized)
struct InsightsWiringTests {
    private func source(_ repo: any Repo, now: Date, push: Bool = true, cache: SlotCacheSnapshot? = nil) -> RepoInsightsDataSource {
        var config = Config(); config.push.enabled = push; config.push.topic = "de.example.app"; config.push.keyPEM = "x"
        return RepoInsightsDataSource(repo: repo, enabledLayers: ["pressure"], context: { [config = config] in .make(config: config) },
                                      cache: cache.map { c in { @Sendable in c } }, clock: { now })
    }

    private func hourly(_ repo: any Repo, _ hour: Date, _ rows: [(String, String, Int)]) async throws {
        try await repo.addStatsHourly(hour: hour, rows.map { StatDelta(metric: $0.0, label: $0.1, value: $0.2) })
    }

    @Test(arguments: RepoKind.allCases) func hourlyLatencyLagCacheAndLeader(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 3600).addingTimeInterval(1800)
        let hour = TimeUtil.floor(now, to: 3600)
        try await hourly(repo, hour, [("latency", "radar_image:lt10ms", 90), ("latency", "radar_image:lt50ms", 8), ("latency", "radar_image:ge1s", 2),
                                      ("ingest_lag", "radar:lt5m", 3), ("ingest_lag", "radar:lt10m", 1), ("ingest_run", "radar:ok", 4), ("ingest_run", "radar:error", 1),
                                      ("ingest_run", "pressure:error", 2), ("cache_evict", "radar", 5), ("requests", "radar_image:2xx", 100)])
        try await hourly(repo, hour.addingTimeInterval(-3600), [("ingest_run", "radar:ok", 6)])
        _ = try await repo.acquireLeader(name: PushService.leaderName, owner: "leader-replica", leaseSeconds: 30)
        let src = source(repo, now: now, cache: SlotCacheSnapshot(bytes: 1000, entries: 3, maxBytes: 4000))
        let engine = InsightsEngine(source: src, clock: { now })

        let ops = try await engine.ops(range: .h24)
        let latency = try #require((ops["latency"] as? [[String: Any]])?.first)
        #expect(latency["route"] as? String == "radar_image" && latency["p50Ms"] as? Int == 10 && latency["p99Ms"] as? Int == 1000)
        #expect((latency["buckets"] as? [[String: Any]])?.map { $0["le"] as? String } == ["10ms", "50ms", "200ms", "1s", "inf"])
        let cache = ops["cache"] as? [String: Any]
        let fill = cache?["fill"] as? [String: Any]
        #expect(fill?["bytes"] as? Int == 1000 && fill?["maxBytes"] as? Int == 4000 && fill?["evictions"] as? Int == 5 && fill?["scope"] as? String == "thisReplica")
        let leader = ops["leader"] as? [String: Any]
        #expect(leader?["holder"] as? String == DashboardApi.shortID("leader-replica") && (leader?["leaseSecondsLeft"] as? Int ?? 0) > 20)
        #expect(leader?["changes24h"] is NSNull)
        let layers = try #require(ops["layers"] as? [[String: Any]])
        let radar = try #require(layers.first { $0["id"] as? String == "radar" })
        let runs = radar["runs"] as? [[String: Any]] ?? []
        #expect(runs.count == 2 && runs.allSatisfy { $0["result"] as? String == "ok" })
        let lag = radar["lag"] as? [String: Any]
        #expect(lag?["p50Seconds"] as? Int == 300 && lag?["p95Seconds"] as? Int == 600)
        let pressure = try #require(layers.first { $0["id"] as? String == "pressure" })
        #expect((pressure["runs"] as? [[String: Any]])?.first?["result"] as? String == "error" && (pressure["lag"] as? [String: Any])?["p50Seconds"] is NSNull)
        let disabled = try #require(layers.first { $0["id"] as? String == "lightning" })
        #expect((disabled["runs"] as? [Any])?.isEmpty == true)
    }

    @Test(arguments: RepoKind.allCases) func pushCountersSections(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.heartbeat(replicaID: "replica-one", slot: 1, appliedGeneration: 0,
                                 push: PushReplicaReport(enabled: true, environments: "production", liveActivity: true), now: Date())
        let now = TimeUtil.floor(Date(), to: 3600).addingTimeInterval(600)
        let hour = TimeUtil.floor(now, to: 3600)
        try await hourly(repo, hour, [
            ("push_trigger", "rain_start", 7), ("push_trigger", "la_rain_start", 3),
            ("push_skipped", "la_rain_start:no_start_token", 2), ("push_skipped", "run:paused", 4), ("push_skipped", "rain_start:env_not_allowed", 1),
            ("push_created", "", 20), ("push_attempt", "", 22), ("push_sent", "delivered", 12), ("push_failed", "rejected", 3), ("push_failed", "unregistered", 1),
            ("push_failed", "dropped", 2), ("push_failed", "retry", 2), ("la_event", "start:delivered", 2), ("la_event", "start:rejected", 1),
            ("la_event", "update:delivered", 9), ("apns_error", "alert:BadDeviceToken:production", 3), ("apns_error", "start:InvalidProviderToken:sandbox", 1),
            ("token_invalidated", "device:410", 1), ("push_api_reject", "server_full", 5), ("la_reservation", "expired", 1)])
        let src = source(repo, now: now)
        let engine = InsightsEngine(source: src, clock: { now })
        let push = try await engine.push(range: .h24)
        func list(_ key: String) -> [[String: Any]] { push[key] as? [[String: Any]] ?? [] }
        #expect(list("triggers").map { "\($0["trigger"] as? String ?? ""):\($0["count"] as? Int ?? -1)" } == ["la_rain_start:3", "rain_start:7"])
        let skipped = list("skipped")
        #expect(skipped.contains { $0["trigger"] as? String == "run" && $0["reason"] as? String == "paused" && $0["count"] as? Int == 4 })
        #expect(skipped.contains { $0["reason"] as? String == "env_not_allowed" } && skipped.count == 3)
        let delivery = try #require(push["delivery"] as? [String: Any])
        #expect(delivery["created"] as? Int == 20 && delivery["sent"] as? Int == 12 && delivery["rejected"] as? Int == 4 && delivery["dropped"] as? Int == 2 && delivery["retry"] as? Int == 2)
        #expect(delivery["ratio"] as? Double == 0.67 || delivery["ratio"] as? Double == 0.6667)
        #expect(list("apnsErrors").count == 2 && list("tokenInvalidations").first?["cause"] as? String == "410")
        #expect(list("rejects").first?["code"] as? String == "server_full")
        let events = (push["lifecycle"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
        #expect(events.count == 3)
        #expect(push["timing"] is NSNull && push["registrations"] is NSNull)

        // Critical APNs reason in the last hour -> finding.
        let findings = try await engine.findings()
        let codes = (findings["findings"] as? [[String: Any]] ?? []).map { $0["code"] as? String }
        #expect(codes.contains("apns_rejection"))
    }

    @Test(arguments: RepoKind.allCases) func noLeaderWhenPushIsOffAndPausedAndNoFalseZero(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 60)
        try await repo.heartbeat(replicaID: "replica-one", slot: 1, appliedGeneration: 0, now: now)
        let off = source(repo, now: now, push: false)
        #expect(try await off.replicaInfo(now: now).leader == nil)
        let on = source(repo, now: now)
        let info = try await on.replicaInfo(now: now)
        #expect(info.leader?.holder == nil)   // push on, nobody holds the lease -> leader_missing
        #expect(try await on.pushCounters(range: .d7, now: now)?.delivery?.ratio == nil)
        #expect(try await on.latency(range: .h24, now: now) == nil)
    }

    @Test func everyFixedStatsLabelIsAcceptedByTheStorage() {
        var checked = 0
        for (metric, rule) in StatsCollector.labelRules {
            guard case .fixed(let labels) = rule else { continue }
            for label in labels { #expect(DashboardValidation.isValid(StatDelta(metric: metric, label: label, value: 1)), "\(metric) \(label)"); checked += 1 }
        }
        #expect(checked > 300)
    }

    @Test func thresholdLookupPrefersEnvironmentThenDashboardValue() {
        let lookup = InsightsThresholds.lookup(env: ["DASH_MIN_GROUP": "7"], stored: ["DASH_MIN_GROUP": "9", "DASH_WARN_CACHE_HIT_YELLOW": "0.9",
                                                                                       "DASH_WARN_CACHE_HIT_RED": "2", "DB_HOST": "x"])
        let t = InsightsThresholds(lookup: lookup)
        #expect(t.minGroup == 7 && t.cacheHit.yellow == 0.9 && t.cacheHit.red == 0.5)   // invalid stored value (above 1) ignored
        #expect(lookup("DB_HOST") == nil)
    }
}
}
