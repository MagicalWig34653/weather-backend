import Foundation

/// Adapter of the insights engine onto the existing repositories: daily and hourly counters (`StatsQuery`), published runs,
/// ingest lag per layer, replica heartbeats and the push leader lease, push gauges and the push counters of WP11.
/// Not collected anywhere (stays `nil`): APNs send timing and evaluation duration (`timing`), registration series
/// (`registrations`), pool usage and database error counts, leader changes. See `docs/status.md`.
public final class RepoInsightsDataSource: InsightsDataSource {
    let repo: any Repo
    let enabledLayers: [String]
    let contextProvider: @Sendable () async -> InsightsContext
    let gaugeProvider: (@Sendable (Date) async throws -> InsightsPushGauges)?
    let cacheProvider: (@Sendable () async -> SlotCacheSnapshot?)?
    let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - enabledLayers: ids of `LAYERS` (the radar always runs).
    ///   - context: current configuration state (thresholds from the register, push switches, caps); called per request.
    ///   - pushGauges: override for tests; by default `MariaRepo`/`MemoryRepo` provide the gauges.
    ///   - cache: fill level of the slot cache of this process (nil result or no provider = not collected).
    public init(repo: any Repo, enabledLayers: [String], context: @escaping @Sendable () async -> InsightsContext,
                pushGauges: (@Sendable (Date) async throws -> InsightsPushGauges)? = nil,
                cache: (@Sendable () async -> SlotCacheSnapshot?)? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repo = repo; self.enabledLayers = enabledLayers; self.contextProvider = context
        self.cacheProvider = cache; self.clock = clock
        if let pushGauges { gaugeProvider = pushGauges }
        else if let maria = repo as? MariaRepo { gaugeProvider = { try await maria.insightsPushGauges(now: $0) } }
        else if let memory = repo as? MemoryRepo { gaugeProvider = { await memory.insightsPushGauges(now: $0) } }
        else { gaugeProvider = nil }
    }

    /// Configuration of this process, with the push facts replaced by what the radar replicas report in the database: the
    /// dashboard service runs with `PUSH_ENABLED=false` and no APNs secret by design.
    public func context() async -> InsightsContext {
        await contextProvider().applying(await PushTruth.resolve(repo: repo, now: clock()))
    }

    public func dailyStats(from: Date, to: Date) async throws -> [StatRow] { try await repo.stats(from: from, to: to) }

    public func layers(now: Date) async throws -> [InsightsLayerState] {
        var out: [InsightsLayerState] = []
        // Runs and lag come from the hourly counters; a missing table or no data leaves them `nil` (never an invented value).
        let from = TimeUtil.floor(now, to: 3600).addingTimeInterval(-23 * 3600)
        let runRows = (try? await repo.statsHourly(from: from, to: now))?.filter { $0.metric == "ingest_run" }
        let query = StatsQuery(repo: repo)
        let lagReport = try? await query.distribution(metric: "ingest_lag", from: from, to: now)
        func lag(_ id: String) async -> InsightsLayerLag? {
            guard let entry = lagReport?.entries.first(where: { $0.key == id }), entry.count > 0 else { return nil }
            var series: InsightsSeries?
            if let s = try? await query.distributionSeries(metric: "ingest_lag", key: id, from: from, to: now) {
                series = InsightsSeries(resolution: "hour", points: s.points.enumerated().map { i, p in
                    InsightsSeries.Point(t: from.addingTimeInterval(Double(i) * 3600), v: p.count > 0 ? p.p95 : nil)
                })
            }
            return InsightsLayerLag(p50Seconds: entry.p50.map { Int($0) }, p95Seconds: entry.p95.map { Int($0) }, series: series)
        }
        func runs(_ id: String) -> [InsightsLayerRun]? {
            guard let runRows else { return nil }
            var byHour: [Date: [String: Int]] = [:]
            for r in runRows where r.label.hasPrefix(id + ":") { byHour[r.hour, default: [:]][String(r.label.dropFirst(id.count + 1)), default: 0] += r.value }
            // One entry per hour with ingest activity: `error` if every run of the hour failed, `missed` if only slots were missed,
            // otherwise `ok` (hour resolution, not per slot).
            return byHour.keys.sorted().map { hour in
                let c = byHour[hour] ?? [:]
                let result = (c["ok"] ?? 0) > 0 ? "ok" : ((c["error"] ?? 0) > 0 ? "error" : "missed")
                return InsightsLayerRun(slot: hour, result: result)
            }
        }
        let radar = try await repo.latestPublished()
        out.append(InsightsLayerState(id: "radar", enabled: true, latestRun: radar?.runID, publishedAt: radar?.publishedAt, cadenceSeconds: 300,
                                      runs: runs("radar"), lag: await lag("radar")))
        for id in LayerCatalog.order {
            guard let spec = LayerCatalog.specs[id] else { continue }
            let enabled = enabledLayers.contains(id)
            let run = enabled ? try await repo.layerLatestPublished(layer: id) : nil
            out.append(InsightsLayerState(id: id, enabled: enabled, latestRun: run?.runID, publishedAt: run?.publishedAt, cadenceSeconds: spec.publishCadenceSeconds,
                                          runs: enabled ? runs(id) : nil, lag: enabled ? await lag(id) : nil))
        }
        return out
    }

    public func hourlyStats(from: Date, to: Date) async throws -> [HourlyStatRow]? {
        // No hourly row at all (fresh start, table not yet written): not collected, the ranges fall back to day resolution.
        let rows = try await repo.statsHourly(from: from, to: to)
        return rows.isEmpty ? nil : rows.map { HourlyStatRow(hour: $0.hour, metric: $0.metric, label: $0.label, value: $0.value) }
    }

    public func cacheFill() async throws -> InsightsCacheFill? {
        guard let snap = await cacheProvider?() else { return nil }
        let now = clock()
        let rows = try await repo.statsHourly(from: TimeUtil.floor(now, to: 3600).addingTimeInterval(-23 * 3600), to: now)
        let evictions = rows.filter { $0.metric == "cache_evict" }.reduce(0) { $0 + $1.value }
        return InsightsCacheFill(bytes: snap.bytes, maxBytes: snap.maxBytes, entries: snap.entries, evictions: evictions, scope: "thisReplica")
    }

    public func latency(range: InsightsRange, now: Date) async throws -> [InsightsLatencyRoute]? {
        // Hourly counters are kept for 72 hours; longer ranges show those 72 hours.
        let hours = min(range.hours, 72)
        let from = TimeUtil.floor(now, to: 3600).addingTimeInterval(-Double(hours - 1) * 3600)
        let report = try await StatsQuery(repo: repo).distribution(metric: "latency", from: from, to: now)
        let names = StatsBuckets.latency.names, les = ["10ms", "50ms", "200ms", "1s", "inf"]
        let routes = report.entries.filter { $0.count > 0 }.map { e in
            func ms(_ v: Double?) -> Int? { v.map { Int(($0 * 1000).rounded()) } }
            let counts = Dictionary(e.buckets.map { ($0.bucket, $0.count) }, uniquingKeysWith: { $1 })
            return InsightsLatencyRoute(route: e.key, buckets: zip(les, names).map { (le: $0, count: counts[$1] ?? 0) },
                                        p50Ms: ms(e.p50), p95Ms: ms(e.p95), p99Ms: ms(e.p99))
        }
        return routes.isEmpty ? nil : routes
    }

    public func databaseInfo() async throws -> InsightsDatabaseInfo? {
        guard let maria = repo as? MariaRepo else { return nil }
        return InsightsDatabaseInfo(poolUsage: nil, errors24h: nil, migration: try await maria.latestMigration())
    }

    public func replicaInfo(now: Date) async throws -> InsightsReplicaInfo {
        let generation = try await repo.generation().generation
        let replicas = try await repo.replicas(now: now).map {
            InsightsReplica(replicaID: $0.replicaID, startedAt: $0.startedAt, appliedGeneration: $0.appliedGeneration)
        }
        // The push leader lease; without push there is no leader and none is expected.
        var leader: InsightsLeader?
        if await context().pushEnabled {
            let lease = try await repo.leaderLease(name: PushService.leaderName)
            leader = InsightsLeader(holder: lease?.owner, leaseSecondsLeft: lease.map { max(0, $0.secondsLeft) }, changes24h: nil)
        }
        return InsightsReplicaInfo(replicas: replicas, generation: generation, leader: leader)
    }

    public func pushGauges(now: Date) async throws -> InsightsPushGauges? {
        guard let gaugeProvider else { return nil }
        return try await gaugeProvider(now)
    }
}

public extension InsightsContext {
    /// Push state from the replicas. An active replica only starts with key and topic set (`Config.validated`), so both count as present.
    func applying(_ truth: PushTruth) -> InsightsContext {
        var c = self
        c.pushEnabled = truth.enabled
        c.pushUnknown = truth.status == .unknown
        guard truth.enabled else { c.setup = InsightsPushSetup(apnsEnv: nil, topicSet: false, keyPresent: false, liveActivityCapability: false); return c }
        let envs = truth.environments
        c.setup = InsightsPushSetup(apnsEnv: envs?.count == 1 ? envs?.first?.rawValue : nil, topicSet: true, keyPresent: true,
                                    liveActivityCapability: truth.liveActivity || envs == nil)
        return c
    }

    /// Context from the effective configuration. `lookup` reads `DASH_WARN_*` and `DASH_MIN_GROUP` (live register or ENV).
    static func make(config: Config, pushPaused: Bool = false, expectedReplicas: Int? = nil, lookup: (String) -> String? = { _ in nil }) -> InsightsContext {
        let p = config.push
        let limits = p.regionLimits
        return InsightsContext(
            pushEnabled: p.enabled, pushPaused: pushPaused, thresholds: InsightsThresholds(lookup: lookup),
            setup: InsightsPushSetup(apnsEnv: p.environments.count == 1 ? p.environments.first?.rawValue : nil, topicSet: !p.topic.isEmpty,
                                     keyPresent: !p.keyPEM.isEmpty, liveActivityCapability: p.enabled && !p.topic.isEmpty),
            caps: InsightsCapLimits(installations: p.maxInstallations, subscriptions: limits.maxSubscriptionsServerwide,
                                    regionCells: limits.maxCellsServerwide, activitySubscriptions: limits.maxLiveActivitySubscriptions),
            expectedReplicas: expectedReplicas)
    }
}

public extension InsightsThresholds {
    /// Lookup for `init(lookup:)`: an environment value wins, otherwise the live dashboard value (validated against the register
    /// limits; invalid stored values are ignored). Only `DASH_WARN_*` and `DASH_MIN_GROUP` are answered.
    static func lookup(env: [String: String], stored: [String: String]) -> (String) -> String? {
        let valid = ConfigRegistry.effectiveOverrides(env: env, stored: stored.filter { $0.key.hasPrefix("DASH_WARN_") || $0.key == "DASH_MIN_GROUP" })
        return { key in
            guard key.hasPrefix("DASH_WARN_") || key == "DASH_MIN_GROUP" else { return nil }
            if let e = env[key], !e.isEmpty { return e }
            return valid[key]
        }
    }
}
