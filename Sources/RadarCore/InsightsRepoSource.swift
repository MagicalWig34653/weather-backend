import Foundation

/// Adapter of the insights engine onto the existing repositories. Reads what exists today (daily counters, published runs,
/// replica heartbeats, push gauges); everything WP11 will deliver later (hourly counters, latency, ingest lag, per-slot runs,
/// APNs reasons, triggers, Live-Activity lifecycle, leader lease) stays `nil` here and is filled by extending this type or a
/// wrapper around it.
public final class RepoInsightsDataSource: InsightsDataSource {
    let repo: any Repo
    let enabledLayers: [String]
    let contextProvider: @Sendable () async -> InsightsContext
    let gaugeProvider: (@Sendable (Date) async throws -> InsightsPushGauges)?

    /// - Parameters:
    ///   - enabledLayers: ids of `LAYERS` (the radar always runs).
    ///   - context: current configuration state (thresholds from the register, push switches, caps); called per request.
    ///   - pushGauges: override for tests; by default `MariaRepo`/`MemoryRepo` provide the gauges.
    public init(repo: any Repo, enabledLayers: [String], context: @escaping @Sendable () async -> InsightsContext,
                pushGauges: (@Sendable (Date) async throws -> InsightsPushGauges)? = nil) {
        self.repo = repo; self.enabledLayers = enabledLayers; self.contextProvider = context
        if let pushGauges { gaugeProvider = pushGauges }
        else if let maria = repo as? MariaRepo { gaugeProvider = { try await maria.insightsPushGauges(now: $0) } }
        else if let memory = repo as? MemoryRepo { gaugeProvider = { await memory.insightsPushGauges(now: $0) } }
        else { gaugeProvider = nil }
    }

    public func context() async -> InsightsContext { await contextProvider() }

    public func dailyStats(from: Date, to: Date) async throws -> [StatRow] { try await repo.stats(from: from, to: to) }

    public func layers(now: Date) async throws -> [InsightsLayerState] {
        var out: [InsightsLayerState] = []
        let radar = try await repo.latestPublished()
        out.append(InsightsLayerState(id: "radar", enabled: true, latestRun: radar?.runID, publishedAt: radar?.publishedAt, cadenceSeconds: 300))
        for id in LayerCatalog.order {
            guard let spec = LayerCatalog.specs[id] else { continue }
            let enabled = enabledLayers.contains(id)
            let run = enabled ? try await repo.layerLatestPublished(layer: id) : nil
            out.append(InsightsLayerState(id: id, enabled: enabled, latestRun: run?.runID, publishedAt: run?.publishedAt, cadenceSeconds: Int(spec.stepSeconds)))
        }
        return out
    }

    public func replicaInfo(now: Date) async throws -> InsightsReplicaInfo {
        let generation = try await repo.generation().generation
        let replicas = try await repo.replicas(now: now).map {
            InsightsReplica(replicaID: $0.replicaID, startedAt: $0.startedAt, appliedGeneration: $0.appliedGeneration)
        }
        return InsightsReplicaInfo(replicas: replicas, generation: generation, leader: nil)
    }

    public func pushGauges(now: Date) async throws -> InsightsPushGauges? {
        guard let gaugeProvider else { return nil }
        return try await gaugeProvider(now)
    }
}

public extension InsightsContext {
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
