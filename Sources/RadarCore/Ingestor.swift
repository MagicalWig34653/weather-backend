import Foundation

public struct RunUnavailable: Error, CustomStringConvertible {
    public let description: String
}

struct LeaseLost: Error {}

/// Ingest of one run (claim -> fetch -> validate -> store -> publish).
/// DWD-friendly: one request chain per 5-minute run across ALL replicas (DB claim), few parallel requests,
/// bounded retries with exponential backoff and jitter, no retry storm.
public final class Ingestor: Sendable {
    /// The DWD answers roughly every third GetMap with an XML InvalidDimensionValue error (measured), also for
    /// published runs: generous but bounded retries. The probe also covers a run that is not published yet.
    public static let probeBackoffSeconds: [Double] = [5, 10, 20, 40, 60, 90]
    public static let slotAttempts = 6
    public static let slotBackoffSeconds: [Double] = [3, 6, 12, 20, 20]
    public static let failCooldownSeconds = 240
    public static let staleAfter: TimeInterval = 3600

    let configProvider: ConfigProvider
    var config: Config { configProvider() }
    let repo: any Repo
    let fetch: Fetch
    let owner: String
    let sleep: @Sendable (Double) async -> Void
    let stats: any StatsSink
    let clock: @Sendable () -> Date
    let transcode: Transcode

    /// Validates a fetched PNG and turns it into the stored WebP. Tests may memoize it (same bytes, same result).
    public typealias Transcode = @Sendable (_ bytes: [UInt8], _ width: Int, _ height: Int) throws -> [UInt8]

    public static let productionTranscode: Transcode = { bytes, width, height in
        try ImagePipeline.toWebP(try ImagePipeline.validatePNG(bytes, width: width, height: height))
    }

    public convenience init(config: Config, repo: any Repo, fetch: @escaping Fetch, owner: String,
                            sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                            stats: any StatsSink = NoStatsSink(), clock: @escaping @Sendable () -> Date = { Date() },
                            transcode: @escaping Transcode = Ingestor.productionTranscode) {
        self.init(configProvider: ConfigProvider(config), repo: repo, fetch: fetch, owner: owner, sleep: sleep, stats: stats, clock: clock,
                  transcode: transcode)
    }

    public init(configProvider: ConfigProvider, repo: any Repo, fetch: @escaping Fetch, owner: String,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                stats: any StatsSink = NoStatsSink(), clock: @escaping @Sendable () -> Date = { Date() },
                transcode: @escaping Transcode = Ingestor.productionTranscode) {
        self.configProvider = configProvider; self.repo = repo; self.fetch = fetch; self.owner = owner; self.sleep = sleep; self.stats = stats
        self.clock = clock; self.transcode = transcode
    }

    private func renew(_ runID: String) async throws {
        guard try await repo.renew(runID: runID, owner: owner, leaseSeconds: config.leaseSeconds) else { throw LeaseLost() }
    }

    private func fetchWebP(runID: String, run: Date, slot: Date, attempts: Int, backoffs: [Double]) async throws -> [UInt8] {
        let url = DWD.buildURL(config: config, run: run, slot: slot)
        var last: Error?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try await renew(runID)
            do {
                let bytes = try await fetch(url)
                return try transcode(bytes, config.width, config.height)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = error
                if attempt + 1 < attempts {
                    await sleep(backoffs[min(attempt, backoffs.count - 1)] * (1 + Double.random(in: 0..<0.5)))
                }
            }
        }
        throw RunUnavailable(description: "slot \(TimeUtil.toID(slot)) failed: \(last.map { String(describing: type(of: $0)) } ?? "unknown")")
    }

    /// Returns true when this replica published the run, false when another replica owns it or it is done.
    public func process(run: Date) async throws -> Bool {
        let runID = TimeUtil.toID(run)
        if try await repo.isPublished(runID: runID) { return false }
        guard try await repo.tryClaim(runID: runID, nominal: run, owner: owner, leaseSeconds: config.leaseSeconds,
                                      maxAttempts: config.maxRunAttempts) else { return false }
        let slots = TimeUtil.slots(of: run)
        let started = clock()
        do {
            func store(_ index: Int, _ slot: Date, _ data: [UInt8]) async throws {
                try await repo.putSlot(SlotRef(runID: runID, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot),
                                       contentType: Manifest.contentType, data: data)
            }
            try await store(0, slots[0], try await fetchWebP(
                runID: runID, run: run, slot: slots[0], attempts: Self.probeBackoffSeconds.count + 1, backoffs: Self.probeBackoffSeconds))
            let pending = Array(slots.enumerated().dropFirst())
            try await withThrowingTaskGroup(of: (Int, Date, [UInt8]).self) { group in
                var next = 0
                func addNext() {
                    guard next < pending.count else { return }
                    let (index, slot) = pending[next]
                    next += 1
                    group.addTask {
                        (index, slot, try await self.fetchWebP(runID: runID, run: run, slot: slot,
                                                               attempts: Self.slotAttempts, backoffs: Self.slotBackoffSeconds))
                    }
                }
                for _ in 0..<min(config.workers, pending.count) { addNext() }
                while let (index, slot, data) = try await group.next() {
                    try await store(index, slot, data)
                    addNext()
                }
            }
            guard try await repo.publish(runID: runID, owner: owner, expectedSlots: slots.count) else { throw LeaseLost() }
        } catch is LeaseLost {
            return false
        } catch is CancellationError {
            // Shutdown (e.g. rolling update): hand the run over immediately instead of holding it for the cooldown.
            try? await repo.fail(runID: runID, owner: owner, cooldownSeconds: 0)
            throw CancellationError()
        } catch {
            try? await repo.fail(runID: runID, owner: owner, cooldownSeconds: Self.failCooldownSeconds)
            stats.record("ingest_run", label: error is RunUnavailable ? "radar:missed" : "radar:error")
            throw error
        }
        // Analysis slots stay for HISTORY_HOURS plus 15 minutes of slack (derived from the run time, same on all replicas).
        let keepSince = run.addingTimeInterval(-(Double(config.historyHours) * 3600 + 900))
        _ = try? await repo.retain(keepPublished: config.retentionRuns, keepAnalysisSince: keepSince, staleAfter: Self.staleAfter)
        stats.record("ingest_run", label: "radar:ok")
        let published = clock()
        // Lag: nominal run time to availability; duration: claim to publish of this replica's run.
        stats.observe("ingest_lag", key: "radar", seconds: published.timeIntervalSince(run))
        stats.observe("ingest_dur", key: "radar", seconds: published.timeIntervalSince(started))
        return true
    }
}
