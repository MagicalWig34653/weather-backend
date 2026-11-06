import Foundation

// Controlled restart of the radar replicas (docs/dashboard-plan.md, 5.3). Pure logic with injected clock and closures (no database,
// no Docker): the dashboard raises a generation counter, every replica compares it with the value it started with, and leaves
// in a staggered order (leader last). Swarm (`restart_policy: any`) starts the process again; the new process reads the current
// generation as its starting value, so it never restarts again for the same request.

public struct RestartPolicy: Sendable, Equatable {
    /// Wait per replica slot: (slot - 1) x stagger (`RESTART_STAGGER_SECONDS`, 15 to 300).
    public var staggerSeconds: Double = 45
    /// Minimum time between two restart requests (the dashboard answers 429 before that).
    public var minimumIntervalSeconds: Double = 300
    /// Generation check interval and its random addition (0...pollJitter).
    public var pollSeconds: Double = 30
    public var pollJitterSeconds: Double = 5
    /// Random addition to the stagger, drawn once when the change is first seen (0...exitJitter).
    public var exitJitterSeconds: Double = 5
    /// The leader waits at most this long for the others (a non-leader for its predecessors), then leaves anyway.
    public var maxWaitSeconds: Double = 600
    public init() {}

    /// `RESTART_STAGGER_SECONDS`; empty or invalid values give the default, out-of-range values are clamped to 15...300.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RestartPolicy {
        var p = RestartPolicy()
        if let raw = env["RESTART_STAGGER_SECONDS"], let value = Double(raw) { p.staggerSeconds = min(300, max(15, value)) }
        return p
    }

    /// Slot from `REPLICA_SLOT` (Swarm template `{{.Task.Slot}}`); nil/invalid -> 1 (a single replica).
    public static func slot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        env["REPLICA_SLOT"].flatMap(Int.init).map { max(1, $0) } ?? 1
    }

    public enum TriggerDecision: Equatable, Sendable {
        case allowed
        case tooSoon(retryAfterSeconds: Int)
    }

    /// Gate for the dashboard button (429 with `Retry-After` when `.tooSoon`).
    public func trigger(lastRequestedAt: Date?, now: Date) -> TriggerDecision {
        guard let last = lastRequestedAt else { return .allowed }
        let remaining = minimumIntervalSeconds - now.timeIntervalSince(last)
        return remaining > 0 ? .tooSoon(retryAfterSeconds: Int(remaining.rounded(.up))) : .allowed
    }
}

/// What a replica sees of the others (fresh heartbeats only; stale rows of dead replicas must be filtered out by the caller).
public struct RestartPeer: Sendable, Equatable {
    public var slot: Int
    public var isLeader: Bool
    public var appliedGeneration: Int
    public init(slot: Int, isLeader: Bool, appliedGeneration: Int) {
        self.slot = slot; self.isLeader = isLeader; self.appliedGeneration = appliedGeneration
    }
}

public enum RestartDecision: Equatable, Sendable {
    /// Nothing to do (generation unchanged).
    case none
    /// Restart needed, not our turn yet.
    case waiting
    /// Start the graceful shutdown now and exit with code 0.
    case exit
}

/// State machine of one replica. All time comes in through `now`.
public struct RestartState: Sendable {
    public let policy: RestartPolicy
    public let slot: Int
    /// Generation read at process start; the only generation this process considers "current" until it exits.
    public let startGeneration: Int
    public private(set) var detectedAt: Date?
    public private(set) var exitJitter: Double = 0
    public private(set) var targetGeneration: Int?

    public init(policy: RestartPolicy, slot: Int, startGeneration: Int) {
        self.policy = policy; self.slot = slot; self.startGeneration = startGeneration
    }

    /// "Restart required" state for the process (banner/health detail).
    public var restartRequired: Bool { targetGeneration != nil }

    /// Replicas ever seen (slot -> is leader). A replica that is down right now has no fresh heartbeat, but must still count:
    /// otherwise the leader would leave while the last other replica is restarting.
    public private(set) var known: [Int: Bool] = [:]

    /// Remember the replicas seen in a (fresh) peer list; call on every check, also while nothing is pending.
    public mutating func observe(_ peers: [RestartPeer]) {
        for peer in peers where peer.slot != slot { known[peer.slot] = peer.isLeader }
    }

    /// `generation` is the current database value; `jitter` supplies a random value for the exit jitter (called at most once
    /// per detected generation).
    public mutating func evaluate(now: Date, generation: Int, isLeader: Bool, peers: [RestartPeer], jitter: () -> Double) -> RestartDecision {
        observe(peers)
        guard generation != startGeneration else { targetGeneration = nil; detectedAt = nil; return .none }
        if detectedAt == nil || targetGeneration != generation {
            detectedAt = now
            targetGeneration = generation
            exitJitter = min(policy.exitJitterSeconds, max(0, jitter()))
        }
        let waited = now.timeIntervalSince(detectedAt ?? now)
        let onNew = Set(peers.filter { $0.slot != slot && $0.appliedGeneration == generation }.map(\.slot))

        if isLeader {
            // Last: wait until every other known replica is present on the new generation (or the upper limit is reached).
            if known.keys.allSatisfy(onNew.contains) { return .exit }
            return waited >= policy.maxWaitSeconds ? .exit : .waiting
        }
        let turn = Double(max(0, slot - 1)) * policy.staggerSeconds + exitJitter
        guard waited >= turn else { return .waiting }
        // Never take down another serving replica while an earlier non-leader is still coming back: every known non-leader with a
        // smaller slot must already run the new generation. (Safety valve: after maxWaitSeconds go anyway.)
        let predecessorsBack = known.filter { !$0.value && $0.key < slot }.keys.allSatisfy(onNew.contains)
        return (predecessorsBack || waited >= turn + policy.maxWaitSeconds) ? .exit : .waiting
    }
}

/// Periodic driver around `RestartState`. Closures replace the database: they are bound to `DashboardRepo` in main.swift.
public actor RestartCoordinator {
    private var state: RestartState
    private let now: @Sendable () -> Date
    private let readGeneration: @Sendable () async throws -> Int
    private let readPeers: @Sendable () async throws -> [RestartPeer]
    private let isLeader: @Sendable () async -> Bool
    private let shutdown: @Sendable () async -> Void
    private let random: @Sendable (ClosedRange<Double>) -> Double
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    public private(set) var exited = false

    public init(policy: RestartPolicy = RestartPolicy(), slot: Int, startGeneration: Int,
                now: @escaping @Sendable () -> Date = { Date() },
                readGeneration: @escaping @Sendable () async throws -> Int,
                readPeers: @escaping @Sendable () async throws -> [RestartPeer],
                isLeader: @escaping @Sendable () async -> Bool,
                shutdown: @escaping @Sendable () async -> Void,
                random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        state = RestartState(policy: policy, slot: slot, startGeneration: startGeneration)
        self.now = now; self.readGeneration = readGeneration; self.readPeers = readPeers
        self.isLeader = isLeader; self.shutdown = shutdown; self.random = random; self.sleep = sleep
    }

    public var restartRequired: Bool { state.restartRequired }

    /// One check. A database error counts as "no decision" (the replica keeps serving).
    @discardableResult
    public func tick() async -> RestartDecision {
        guard !exited else { return .none }
        let generation: Int
        do { generation = try await readGeneration() } catch { return .none }
        // Peers are read on every check (also while nothing is pending) so that replicas are known before one of them goes down.
        let loaded = try? await readPeers()
        let peers = loaded ?? []
        if generation != state.startGeneration, loaded == nil { return .waiting }
        let leader = generation != state.startGeneration ? await isLeader() : false
        let ceiling = state.policy.exitJitterSeconds
        let decision = state.evaluate(now: now(), generation: generation, isLeader: leader, peers: peers,
                                      jitter: { random(0...max(ceiling, 0)) })
        if decision == .exit {
            exited = true
            await shutdown()
        }
        return decision
    }

    /// Runs until the replica has left (or the task is cancelled): check, sleep 30 s plus 0...5 s jitter.
    public func run() async {
        while !exited, !Task.isCancelled {
            await tick()
            if exited { break }
            let p = state.policy
            do { try await sleep(p.pollSeconds + random(0...max(p.pollJitterSeconds, 0))) } catch { break }
        }
    }
}

extension RestartCoordinator {
    /// Coordinator bound to the dashboard repo. Reads `generation()` as the process's starting value once (call at startup, before
    /// serving), writes a heartbeat with the applied generation on every check, and derives peers from fresh `replicas(now:)` rows
    /// (leader = `leaderSlot()` or the replica holding the ingest lock, decided by the caller).
    public static func make(repo: any DashboardRepo, replicaID: String, slot: Int, policy: RestartPolicy = RestartPolicy(),
                            push: PushReplicaReport? = nil,
                            isLeader: @escaping @Sendable () async -> Bool,
                            leaderSlot: @escaping @Sendable () async -> Int?,
                            shutdown: @escaping @Sendable () async -> Void,
                            now: @escaping @Sendable () -> Date = { Date() }) async throws -> RestartCoordinator {
        let start = try await repo.generation().generation
        try await repo.heartbeat(replicaID: replicaID, slot: slot, appliedGeneration: start, push: push, now: now())
        return RestartCoordinator(
            policy: policy, slot: slot, startGeneration: start, now: now,
            readGeneration: {
                try await repo.heartbeat(replicaID: replicaID, slot: slot, appliedGeneration: start, push: push, now: now())
                return try await repo.generation().generation
            },
            readPeers: {
                let leader = await leaderSlot()
                return try await repo.replicas(now: now()).compactMap { r in
                    guard let s = r.slot, r.replicaID != replicaID else { return nil }
                    return RestartPeer(slot: s, isLeader: s == leader, appliedGeneration: r.appliedGeneration)
                }
            },
            isLeader: isLeader, shutdown: shutdown)
    }
}
