import Foundation

/// Replica side of "Ebene neu abrufen" (docs-site/content/dashboard-api.md): takes queued `dashboard_refresh` jobs and runs the
/// normal ingest code for the layer once, outside the schedule. Radar jobs may run on any replica (the run claim keeps them apart);
/// a layer job only on the replica that holds (or can take) the layer's leader lease, exactly like the regular loop.
/// Results carry fixed fields and codes only.
public final class CacheRefreshWorker: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var stored: Int
        public var failed: Int
        public var published: Bool
        public init(stored: Int, failed: Int, published: Bool) { self.stored = stored; self.failed = failed; self.published = published }
    }

    public typealias Executor = @Sendable (String) async throws -> Outcome

    let repo: any Repo
    let configProvider: ConfigProvider
    let owner: String
    let clock: @Sendable () -> Date
    let executor: Executor

    /// `executor` replaces the real ingest (tests).
    public init(repo: any Repo, configProvider: ConfigProvider, fetch: @escaping Fetch, owner: String, stats: any StatsSink = NoStatsSink(),
                clock: @escaping @Sendable () -> Date = { Date() }, executor: Executor? = nil) {
        self.repo = repo; self.configProvider = configProvider; self.owner = owner; self.clock = clock
        self.executor = executor ?? { layer in
            let config = configProvider()
            if layer == "radar" {
                let ingestor = Ingestor(configProvider: configProvider, repo: repo, fetch: fetch, owner: owner, stats: stats)
                let run = TimeUtil.latestRun(now: clock(), availabilityDelay: config.availabilityDelaySeconds)
                let published = try await ingestor.process(run: run)
                return Outcome(stored: published ? TimeUtil.slots(of: run).count : 0, failed: 0, published: published)
            }
            guard let spec = LayerCatalog.specs[layer] else { throw CacheRefreshError.disabled }
            let ingestor = LayerIngestor(spec: spec, configProvider: configProvider, repo: repo, fetch: fetch, owner: owner, stats: stats)
            let result = try await ingestor.tick()
            if !result.isLeader { throw CacheRefreshError.notLeader }
            return Outcome(stored: result.stored, failed: result.failed, published: result.published != nil)
        }
    }

    enum CacheRefreshError: Error { case disabled, notLeader }

    /// Error code of the contract for a failed ingest.
    static func code(for error: Error) -> String {
        switch error {
        case is RunUnavailable: return "source_unavailable"
        case is ImageError: return "incomplete"
        case CacheRefreshError.disabled: return "layer_disabled"
        default: return "internal"
        }
    }

    /// Called about every 2 seconds by the ingest replica. Runs at most `maxJobs` jobs, one after the other.
    public func processJobs(maxJobs: Int = 1) async {
        var done = 0
        guard let queued = try? await repo.queuedRefreshLayers(now: clock()) else { return }
        let enabled = Set(configProvider().layers)
        for layer in queued where done < maxJobs {
            let isLayer = layer != "radar"
            if isLayer, enabled.contains(layer),
               (try? await repo.acquireLeader(name: "layer:\(layer)", owner: owner, leaseSeconds: LayerIngestor.leaderLeaseSeconds)) != true { continue }
            guard let job = try? await repo.claimRefreshJob(layer: layer, now: clock()) else { continue }
            done += 1
            if isLayer, !enabled.contains(layer) {
                try? await repo.finishRefreshJob(id: job.id, status: .failed, result: nil, error: "layer_disabled", now: clock())
                continue
            }
            do {
                let outcome = try await executor(layer)
                // A tick that stored nothing and only failed slots means the source did not deliver.
                if outcome.stored == 0, outcome.failed > 0, !outcome.published {
                    try? await repo.finishRefreshJob(id: job.id, status: .failed, result: nil, error: "source_unavailable", now: clock())
                } else {
                    let result = "{\"failed\":\(outcome.failed),\"published\":\(outcome.published),\"stored\":\(outcome.stored)}"
                    try? await repo.finishRefreshJob(id: job.id, status: .ok, result: result, error: nil, now: clock())
                }
            } catch is CancellationError {
                try? await repo.finishRefreshJob(id: job.id, status: .failed, result: nil, error: "internal", now: clock())
                return
            } catch CacheRefreshError.notLeader {
                // Lost the lease between the check and the tick: hand the job back by failing it softly (another run can be requested).
                try? await repo.finishRefreshJob(id: job.id, status: .failed, result: nil, error: "internal", now: clock())
            } catch {
                try? await repo.finishRefreshJob(id: job.id, status: .failed, result: nil, error: Self.code(for: error), now: clock())
            }
        }
    }
}
