import Foundation

public struct PushTick: Sendable, Equatable {
    public var isLeader = false
    public var evaluatedRun: String?
    public var queued = 0
    public var sent = 0
    public var dropped = 0
    public var retried = 0
    public var unregistered = 0
    public var purged = PushPurgeResult()
}

/// Leader-only push work after each radar run: evaluation -> outbox -> APNs, plus retention.
/// Only the replica that holds the `push` leader lease evaluates and sends (see `Repo.acquireLeader`).
public final class PushService: Sendable {
    public static let leaderName = "push"
    public static let leaseSeconds = 60
    public static let batchSize = 50
    public static let maxAttempts = 5
    public static let retryBackoffSeconds: [Double] = [30, 60, 120, 300, 600]
    public static let inactivityDays = 60
    public static let outboxKeepSeconds: TimeInterval = 6 * 3600
    public static let purgeInterval: TimeInterval = 3600

    let config: Config
    let repo: any Repo
    let sender: any ApnsSender
    let owner: String
    let clock: @Sendable () -> Date
    private let purgeState = PushGuarded(Date.distantPast)

    public init(config: Config, repo: any Repo, sender: any ApnsSender, owner: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.repo = repo; self.sender = sender; self.owner = owner; self.clock = clock
    }

    public func release() async { try? await repo.releaseLeader(name: Self.leaderName, owner: owner) }

    public func tick() async throws -> PushTick {
        var result = PushTick()
        guard config.push.enabled else { return result }
        guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else { return result }
        result.isLeader = true
        try await evaluate(&result)
        try await dispatch(&result)
        let now = clock()
        if purgeState.withLock({ last in
            guard now.timeIntervalSince(last) >= Self.purgeInterval else { return false }
            last = now
            return true
        }) {
            result.purged = try await repo.purgePush(
                inactiveBefore: now.addingTimeInterval(-Double(Self.inactivityDays) * 86400),
                outboxBefore: now.addingTimeInterval(-Self.outboxKeepSeconds), now: now)
        }
        return result
    }

    // MARK: evaluation

    func evaluate(_ result: inout PushTick) async throws {
        guard let run = try await repo.latestPublished() else { return }
        if let last = try await repo.lastEvaluatedRun(), last >= run.runID { return }
        let now = clock()
        var updates: [SubscriptionUpdate] = []
        var outbox: [NewOutboxItem] = []
        let fresh = now.timeIntervalSince(run.nominal) <= PushEvaluator.maxRunAge
        let subs = fresh ? try await repo.evaluationSubscriptions(gridVersion: PushGrid.version) : []
        let slots = subs.isEmpty ? [] : try await repo.publishedSlots(runID: run.runID)
        if !subs.isEmpty, slots.count == TimeUtil.forecastSlots {
            var classes = [[Int]](repeating: [], count: subs.count)
            var complete = true
            for slot in slots.sorted(by: { $0.slotIndex < $1.slotIndex }) {
                guard let blob = try await repo.getSlot(runID: run.runID, slotID: slot.slotID),
                      let image = try? ImagePipeline.decodeWebP(blob.data), image.width == config.width, image.height == config.height else {
                    complete = false
                    break
                }
                for (index, sub) in subs.enumerated() { classes[index].append(PushIntensity.classify(image, x: sub.cellX, y: sub.cellY)) }
            }
            if complete {
                for (index, sub) in subs.enumerated() {
                    let step = PushEvaluator.step(state: sub.state, threshold: sub.threshold, leadMinutes: sub.leadMinutes,
                                                  lastSentAt: sub.lastSentAt, classes: classes[index], now: now)
                    var sentAt = sub.lastSentAt
                    if let minutes = step.notifyMinutes {
                        sentAt = now
                        outbox.append(NewOutboxItem(
                            subID: sub.id, dedupeKey: "\(sub.id):\(run.runID)", collapseID: sub.id,
                            payloadJSON: PushEvaluator.payload(minutes: minutes, subscriptionID: sub.id),
                            expiresAt: now.addingTimeInterval(PushEvaluator.maxRunAge)))
                    }
                    if step.state != sub.state || sentAt != sub.lastSentAt { updates.append(SubscriptionUpdate(id: sub.id, state: step.state, lastSentAt: sentAt)) }
                }
            }
        }
        // Stale or incomplete runs are marked as seen without any state change, so they are never replayed later.
        if try await repo.commitEvaluation(runID: run.runID, updates: updates, outbox: outbox, now: now) {
            result.evaluatedRun = run.runID
            result.queued = outbox.count
        }
    }

    // MARK: delivery

    func dispatch(_ result: inout PushTick) async throws {
        let allowed: Set<PushEnvironment> = config.push.environments
        while true {
            let now = clock()
            // Renew the lease before every batch; stop at once when it is lost.
            guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else {
                result.isLeader = false
                return
            }
            let items = try await repo.dueOutbox(now: now, limit: Self.batchSize)
            if items.isEmpty { return }
            var progressed = false
            for item in items {
                let now = clock()
                if item.expiresAt <= now || !allowed.contains(item.env) {
                    try await repo.finishOutbox(id: item.id, .dropped, now: now)
                    result.dropped += 1; progressed = true
                    continue
                }
                let request = ApnsRequest(tokenHex: item.token, env: item.env, topic: config.push.topic, payload: Array(item.payloadJSON.utf8),
                                          collapseID: item.collapseID, expiration: Int(item.expiresAt.timeIntervalSince1970))
                switch await sender.send(request) {
                case .delivered:
                    try await repo.finishOutbox(id: item.id, .sent, now: now); result.sent += 1; progressed = true
                case .unregistered:
                    _ = try await repo.deleteInstallations(token: item.token, env: item.env); result.unregistered += 1; progressed = true
                case .badToken, .rejected:
                    try await repo.finishOutbox(id: item.id, .dropped, now: now); result.dropped += 1; progressed = true
                case .retry:
                    let attempts = item.attempts + 1
                    let delay = Self.retryBackoffSeconds[min(attempts - 1, Self.retryBackoffSeconds.count - 1)] * (1 + Double.random(in: 0..<0.3))
                    let next = now.addingTimeInterval(delay)
                    if attempts >= Self.maxAttempts || next >= item.expiresAt {
                        try await repo.finishOutbox(id: item.id, .dropped, now: now); result.dropped += 1; progressed = true
                    } else {
                        try await repo.finishOutbox(id: item.id, .retry(attempts: attempts, at: next), now: now); result.retried += 1
                    }
                }
            }
            if !progressed || items.count < Self.batchSize { return }
        }
    }
}

final class PushGuarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
