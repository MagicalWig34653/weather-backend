import Foundation

public struct PushTick: Sendable, Equatable {
    public var isLeader = false
    public var evaluatedRun: String?
    public var queued = 0
    public var sent = 0
    public var dropped = 0
    public var retried = 0
    public var unregistered = 0
    /// Apple reason strings (e.g. `BadDeviceToken`, `InvalidProviderToken`) of failed sends, counted; never tokens.
    public var apnsReasons: [String: Int] = [:]
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
    /// Subscriptions loaded per evaluation page (bounded memory).
    let evaluationPageSize: Int
    /// Activity work is subordinate to alert delivery: at most this many activity sends and this many seconds per tick (review A1).
    let activitySendsPerTick: Int
    let activitySecondsPerTick: Double
    /// Work of the last committed run that has not been sent yet; replaced by the next run, drained within each tick's budget.
    let activityQueue = PushGuarded<[ActivityWork]>([])
    public static let reservationTimeout: TimeInterval = 15 * 60
    let stats: any StatsSink

    public init(config: Config, repo: any Repo, sender: any ApnsSender, owner: String, evaluationPageSize: Int = 2000,
                activitySendsPerTick: Int = 200, activitySecondsPerTick: Double = 8,
                clock: @escaping @Sendable () -> Date = { Date() }, stats: any StatsSink = NoStatsSink()) {
        self.config = config; self.repo = repo; self.sender = sender; self.owner = owner; self.clock = clock; self.stats = stats
        self.evaluationPageSize = max(1, evaluationPageSize)
        self.activitySendsPerTick = max(1, activitySendsPerTick); self.activitySecondsPerTick = max(0.1, activitySecondsPerTick)
    }

    public func release() async { try? await repo.releaseLeader(name: Self.leaderName, owner: owner) }

    public func tick() async throws -> PushTick {
        var result = PushTick()
        guard config.push.enabled else { return result }
        guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else { return result }
        result.isLeader = true
        try await evaluate(&result)
        try await dispatch(&result)
        // Alerts first; Live Activity sends and endings only use the remaining per-tick budget.
        if result.isLeader { try await processActivities(&result) }
        let now = clock()
        if purgeState.withLock({ last in
            guard now.timeIntervalSince(last) >= Self.purgeInterval else { return false }
            last = now
            return true
        }) {
            result.purged = try await repo.purgePush(
                inactiveBefore: now.addingTimeInterval(-Double(Self.inactivityDays) * 86400),
                outboxBefore: now.addingTimeInterval(-Self.outboxKeepSeconds), now: now)
            // Janitor for device links: used/expired codes, links past an optional TTL; all links while the switch is off.
            _ = try? await repo.purgeLinks(now: now, removeAll: !config.deviceLink.enabled)
        }
        return result
    }

    // MARK: evaluation

    func evaluate(_ result: inout PushTick) async throws {
        guard let run = try await repo.latestPublished() else { return }
        if let last = try await repo.lastEvaluatedRun(), last >= run.runID { return }
        let now = clock()
        var activityWork: [ActivityWork] = []
        var updates: [SubscriptionUpdate] = []
        var outbox: [NewOutboxItem] = []
        let fresh = now.timeIntervalSince(run.nominal) <= PushEvaluator.maxRunAge
        var firstPage = fresh ? try await repo.evaluationSubscriptions(gridVersion: PushGrid.version, after: nil, limit: evaluationPageSize) : []
        let slots = firstPage.isEmpty ? [] : try await repo.publishedSlots(runID: run.runID)
        if !firstPage.isEmpty, slots.count == TimeUtil.forecastSlots {
            let ordered = slots.sorted(by: { $0.slotIndex < $1.slotIndex })
            var complete = true
            // Subscriptions are processed page by page (memory stays bounded); the slot images are decoded once per page.
            var page = firstPage
            firstPage = []
            while !page.isEmpty, complete {
                var classes = [[Int]](repeating: [], count: page.count)
                let hasRegions = page.contains { $0.kind == .circle }
                for slot in ordered {
                    guard let blob = try await repo.getSlot(runID: run.runID, slotID: slot.slotID),
                          let image = try? ImagePipeline.decodeWebP(blob.data), image.width == config.width, image.height == config.height else {
                        complete = false
                        break
                    }
                    // One class map per slot (only when regions exist); a region becomes a pseudo class: threshold if wet, else 0.
                    let classMap = hasRegions ? PushIntensity.classMap(image) : []
                    for (index, sub) in page.enumerated() {
                        if sub.kind == .circle, let radius = sub.radiusCells {
                            classes[index].append(PushRegion.pseudoClass(
                                classMap: classMap, width: image.width, height: image.height, cx: sub.cellX, cy: sub.cellY, radius: radius,
                                threshold: sub.threshold, sharePercent: sub.minSharePercent ?? PushRegion.defaultShare))
                        } else {
                            // Live Activities need "unknown" (-1) apart from "dry"; the alert automaton treats both as dry.
                            classes[index].append(sub.liveActivity ? PushIntensity.classifyOrUnknown(image, x: sub.cellX, y: sub.cellY)
                                                                   : PushIntensity.classify(image, x: sub.cellX, y: sub.cellY))
                        }
                    }
                }
                guard complete else { break }
                var live: [(sub: PushSubscription, classes: [Int], notify: Bool, state: PushState, sentAt: Date?)] = []
                for (index, sub) in page.enumerated() {
                    let step = PushEvaluator.step(state: sub.state, threshold: sub.threshold, leadMinutes: sub.leadMinutes,
                                                  lastSentAt: sub.lastSentAt, classes: classes[index], now: now)
                    var sentAt = sub.lastSentAt
                    if let minutes = step.notifyMinutes {
                        sentAt = now
                        outbox.append(NewOutboxItem(
                            subID: sub.id, dedupeKey: "\(sub.id):\(run.runID)", collapseID: sub.id,
                            payloadJSON: PushEvaluator.payload(minutes: minutes, subscriptionID: sub.id, timeSensitive: sub.timeSensitive, region: sub.kind == .circle),
                            expiresAt: now.addingTimeInterval(PushEvaluator.maxRunAge)))
                    }
                    if sub.liveActivity, sub.kind == .point {
                        // Update (incl. the wet hysteresis) is decided below, once the activity target is known.
                        live.append((sub, classes[index], step.notifyMinutes != nil, step.state, sentAt))
                    } else if step.state != sub.state || sentAt != sub.lastSentAt {
                        updates.append(SubscriptionUpdate(id: sub.id, state: step.state, lastSentAt: sentAt))
                    }
                }
                // One bulk lookup per page; only subscriptions with a running activity or a start to send stay in memory.
                if !live.isEmpty {
                    let targets = Dictionary(uniqueKeysWithValues: try await repo.activityTargets(subscriptionIDs: live.map(\.sub.id)).map { ($0.subscription.id, $0) })
                    for entry in live {
                        let sub = entry.sub
                        var sentAt = entry.sentAt
                        // Rain already running: a known wet slot 0 in two consecutive complete runs starts the activity
                        // (unknown pixels reset the streak). The 60-minute repeat lock is shared with the rain-start alert
                        // via `lastSentAt`, so both start paths can never fire twice.
                        let wetNow = entry.classes.first.map { $0 >= sub.threshold } ?? false
                        var wetStart = false
                        if let target = targets[sub.id] {
                            if wetNow, sub.wetSeen, !entry.notify, sub.enabled, target.activity == nil,
                               target.installation.liveActivityStartToken != nil,
                               sentAt.map({ now.timeIntervalSince($0) >= PushEvaluator.repeatLock }) ?? true {
                                wetStart = true
                                sentAt = now
                            }
                            if target.activity != nil || ((entry.notify || wetStart) && target.installation.liveActivityStartToken != nil) {
                                activityWork.append(ActivityWork(target: target, classes: entry.classes, notify: entry.notify || wetStart, reference: run.nominal))
                            }
                        }
                        if entry.state != sub.state || sentAt != sub.lastSentAt || wetNow != sub.wetSeen {
                            updates.append(SubscriptionUpdate(id: sub.id, state: entry.state, lastSentAt: sentAt, wetSeen: wetNow))
                        }
                    }
                }
                guard page.count >= evaluationPageSize, let last = page.last?.id else { break }
                page = try await repo.evaluationSubscriptions(gridVersion: PushGrid.version, after: last, limit: evaluationPageSize)
            }
            if !complete { updates = []; outbox = []; activityWork = [] }
        }
        // Stale or incomplete runs are marked as seen without any state change, so they are never replayed later.
        if try await repo.commitEvaluation(runID: run.runID, updates: updates, outbox: outbox, now: now) {
            result.evaluatedRun = run.runID
            result.queued = outbox.count
            activityQueue.withLock { $0 = activityWork }
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
                    stats.record("push_sent", label: "delivered")
                case .unregistered:
                    _ = try await repo.deleteInstallations(token: item.token, env: item.env); result.unregistered += 1; progressed = true
                    stats.record("push_failed", label: "unregistered")
                case .badToken(let reason), .rejected(let reason):
                    result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
                    try await repo.finishOutbox(id: item.id, .dropped, now: now); result.dropped += 1; progressed = true
                    stats.record("push_failed", label: "rejected")
                case .retry(let reason):
                    result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
                    stats.record("push_failed", label: "retry")
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

struct ActivityWork: Sendable {
    var target: PushActivityTarget
    var classes: [Int]
    var notify: Bool
    var reference: Date
}

final class PushGuarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
