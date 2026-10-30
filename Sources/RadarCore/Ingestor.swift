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

    let config: Config
    let repo: any Repo
    let fetch: Fetch
    let owner: String
    let sleep: @Sendable (Double) async -> Void

    public init(config: Config, repo: any Repo, fetch: @escaping Fetch, owner: String,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.config = config; self.repo = repo; self.fetch = fetch; self.owner = owner; self.sleep = sleep
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
                let image = try ImagePipeline.validatePNG(bytes, width: config.width, height: config.height)
                return try ImagePipeline.toWebP(image)
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
            throw error
        }
        // Analysis slots stay for HISTORY_HOURS plus 15 minutes of slack (derived from the run time, same on all replicas).
        let keepSince = run.addingTimeInterval(-(Double(config.historyHours) * 3600 + 900))
        _ = try? await repo.retain(keepPublished: config.retentionRuns, keepAnalysisSince: keepSince, staleAfter: Self.staleAfter)
        return true
    }
}
