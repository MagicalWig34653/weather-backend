import Foundation

/// True while the regular 5-minute ingest of this replica is working; the backfill pauses meanwhile.
public final class ActivityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    public init() {}
    public var isBusy: Bool { lock.withLock { busy } }
    public func set(_ value: Bool) { lock.withLock { busy = value } }
}

/// Spacing and hard request budget of one backfill tick (shared by all workers).
actor RequestPacer {
    private let spacing: Double
    private var remaining: Int
    private var next: Date?

    init(spacing: Double, budget: Int) { self.spacing = spacing; remaining = budget }

    /// Seconds to wait before the next request, or nil when the budget of this tick is used up.
    func reserve(now: Date) -> Double? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        let start = max(now, next ?? now)
        next = start.addingTimeInterval(spacing)
        return start.timeIntervalSince(now)
    }

    var budgetLeft: Int { remaining }
}

/// Counters and stop conditions of one tick.
actor TickState {
    private var cursor = 0
    private(set) var stored = 0
    private(set) var failed = 0
    private var failuresInARow = 0
    private(set) var stop = false
    private(set) var lostLeadership = false
    private(set) var errorStop = false

    func nextIndex(limit: Int) -> Int? {
        guard !stop, cursor < limit else { return nil }
        defer { cursor += 1 }
        return cursor
    }

    func record(success: Bool, errorLimit: Int) {
        if success { stored += 1; failuresInARow = 0 } else {
            failed += 1; failuresInARow += 1
            if failuresInARow >= errorLimit { stop = true; errorStop = true }
        }
    }

    func halt(lostLeadership lost: Bool = false) { stop = true; if lost { lostLeadership = true } }
}

public struct BackfillResult: Sendable, Equatable {
    public var isLeader: Bool
    public var stored: Int
    public var failed: Int
    /// Missing slots still open after this tick.
    public var remaining: Int
    /// Too many consecutive failures: the caller should pause for a longer time.
    public var errorPause: Bool
}

/// Fills gaps in the analysis history (last HISTORY_HOURS) from the DWD WMS time dimension.
/// Only the leader replica works (lease in the DB), each slot is claimed like a run, so the backfill is idempotent
/// and resumable: slots that already exist are never fetched again. Low priority and DWD-friendly: it pauses while the
/// regular ingest of this replica runs, uses a small worker pool, a fixed request spacing, a hard per-tick request budget,
/// bounded retries for the known HTTP-200 InvalidDimensionValue error and a pause after consecutive failures.
public final class Backfiller: Sendable {
    public static let leaderName = "backfill"
    public static let leaderLeaseSeconds = 180
    public static let workers = 2
    /// 3 s between request starts: at most 20 requests per minute across both workers.
    public static let requestSpacingSeconds = 3.0
    public static let maxRequestsPerTick = 20
    public static let slotAttempts = 3
    public static let slotBackoffSeconds: [Double] = [3, 8]
    /// Claim attempts per slot; budget exhaustion mid-slot also burns an attempt.
    public static let claimAttempts = 4
    public static let failCooldownSeconds = 600
    public static let consecutiveFailureLimit = 6
    /// The newest runs belong to the regular ingest.
    public static let guardSteps = 2

    let config: Config
    let repo: any Repo
    let fetch: Fetch
    let owner: String
    let isBusy: @Sendable () -> Bool
    let sleep: @Sendable (Double) async -> Void
    let clock: @Sendable () -> Date

    public init(config: Config, repo: any Repo, fetch: @escaping Fetch, owner: String,
                isBusy: @escaping @Sendable () -> Bool = { false },
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.repo = repo; self.fetch = fetch; self.owner = owner
        self.isBusy = isBusy; self.sleep = sleep; self.clock = clock
    }

    /// Missing nominal times, newest first.
    func missing(now: Date) async throws -> [Date] {
        let latest = TimeUtil.latestRun(now: now, availabilityDelay: config.availabilityDelaySeconds)
        let end = latest.addingTimeInterval(-Double(Self.guardSteps) * TimeUtil.step)
        let first = latest.addingTimeInterval(-Double(config.historyHours) * 3600 + TimeUtil.step)
        guard end >= first else { return [] }
        let settled = try await repo.settledRunTimes(since: first, until: end, maxAttempts: Self.claimAttempts)
        var out: [Date] = []
        var t = end
        while t >= first {
            if !settled.contains(t) { out.append(t) }
            t = t.addingTimeInterval(-TimeUtil.step)
        }
        return out
    }

    public func release() async { try? await repo.releaseLeader(name: Self.leaderName, owner: owner) }

    public func tick() async throws -> BackfillResult {
        guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaderLeaseSeconds) else {
            return BackfillResult(isLeader: false, stored: 0, failed: 0, remaining: 0, errorPause: false)
        }
        let candidates = try await missing(now: clock())
        guard !candidates.isEmpty else { return BackfillResult(isLeader: true, stored: 0, failed: 0, remaining: 0, errorPause: false) }
        let pacer = RequestPacer(spacing: Self.requestSpacingSeconds, budget: Self.maxRequestsPerTick)
        let state = TickState()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.workers {
                group.addTask {
                    while !Task.isCancelled, let index = await state.nextIndex(limit: candidates.count) {
                        guard let leader = try? await self.repo.acquireLeader(
                            name: Self.leaderName, owner: self.owner, leaseSeconds: Self.leaderLeaseSeconds), leader else {
                            await state.halt(lostLeadership: true); return
                        }
                        switch await self.fill(candidates[index], pacer: pacer) {
                        case .stored: await state.record(success: true, errorLimit: Self.consecutiveFailureLimit)
                        case .failed: await state.record(success: false, errorLimit: Self.consecutiveFailureLimit)
                        case .skipped: break
                        case .budgetExhausted: await state.halt(); return
                        }
                    }
                }
            }
        }
        let stored = await state.stored, failed = await state.failed
        let errorStop = await state.errorStop
        return BackfillResult(isLeader: !(await state.lostLeadership), stored: stored, failed: failed,
                              remaining: max(0, candidates.count - stored), errorPause: errorStop)
    }

    enum FillOutcome { case stored, failed, skipped, budgetExhausted }

    /// Waits for the regular ingest (never competes with it), then for the pacing slot. nil: budget used up.
    private func admission(_ pacer: RequestPacer) async -> Bool? {
        while isBusy(), !Task.isCancelled { await sleep(2) }
        guard let delay = await pacer.reserve(now: clock()) else { return nil }
        let wait = delay + Double.random(in: 0..<0.5)
        await sleep(wait)
        return Task.isCancelled ? nil : true
    }

    func fill(_ time: Date, pacer: RequestPacer) async -> FillOutcome {
        let id = TimeUtil.toID(time)
        guard await pacer.budgetLeft > 0 else { return .budgetExhausted }
        let claimed = (try? await repo.tryClaim(runID: id, nominal: time, owner: owner, leaseSeconds: config.leaseSeconds,
                                                maxAttempts: Self.claimAttempts, backfill: true)) ?? false
        guard claimed else { return .skipped }
        let url = DWD.buildURL(config: config, run: time, slot: time)
        for attempt in 0..<Self.slotAttempts {
            guard await admission(pacer) != nil else {
                try? await repo.fail(runID: id, owner: owner, cooldownSeconds: 0)
                return Task.isCancelled ? .skipped : .budgetExhausted
            }
            _ = try? await repo.renew(runID: id, owner: owner, leaseSeconds: config.leaseSeconds)
            do {
                let bytes = try await fetch(url)
                let image = try ImagePipeline.validatePNG(bytes, width: config.width, height: config.height)
                let webp = try ImagePipeline.toWebP(image)
                try await repo.putSlot(SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: time),
                                       contentType: Manifest.contentType, data: webp)
                if try await repo.publish(runID: id, owner: owner, expectedSlots: 1) { return .stored }
                return .skipped  // lease lost: another replica owns the slot now
            } catch {
                if Task.isCancelled { break }
                if attempt + 1 < Self.slotAttempts {
                    await sleep(Self.slotBackoffSeconds[min(attempt, Self.slotBackoffSeconds.count - 1)] * (1 + Double.random(in: 0..<0.5)))
                }
            }
        }
        try? await repo.fail(runID: id, owner: owner, cooldownSeconds: Task.isCancelled ? 0 : Self.failCooldownSeconds)
        return Task.isCancelled ? .skipped : .failed
    }
}
