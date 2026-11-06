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
    /// The operator paused sending: evaluation ran, nothing was sent.
    public var paused = false
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
    /// Rain-now start attempts (first try included) before the 60-minute lock takes over for good.
    public static let maxStartAttempts = 3
    let stats: any StatsSink
    /// Dashboard probe: the start alert reads "Live-Activity-Test" (docs-site dashboard-api.md).
    let probeAlert: Bool
    let observer: any PushObserver

    public init(config: Config, repo: any Repo, sender: any ApnsSender, owner: String, evaluationPageSize: Int = 2000,
                activitySendsPerTick: Int = 200, activitySecondsPerTick: Double = 8,
                clock: @escaping @Sendable () -> Date = { Date() }, stats: any StatsSink = NoStatsSink(), probeAlert: Bool = false,
                observer: (any PushObserver)? = nil) {
        self.probeAlert = probeAlert
        self.observer = observer ?? StatsPushObserver(stats: stats)
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
        // Operator pause: evaluation keeps running (states advance), but nothing is sent. The outbox keeps its items and they
        // expire on their own; operator probes (device commands) are not affected.
        result.paused = try await repo.pushPausedSince() != nil
        try await evaluate(&result)
        if result.paused {
            let waiting = try await !repo.dueOutbox(now: clock(), limit: 1).isEmpty
            if waiting || !activityQueue.withLock({ $0.isEmpty }) { observer.skipped(nil, .paused, by: 1) }
        } else {
            try await dispatch(&result)
            // Alerts first; Live Activity sends and endings only use the remaining per-tick budget.
            if result.isLeader { try await processActivities(&result) }
        }
        let now = clock()
        if purgeState.withLock({ last in
            guard now.timeIntervalSince(last) >= Self.purgeInterval else { return false }
            last = now
            return true
        }) {
            result.purged = try await repo.purgePush(
                inactiveBefore: now.addingTimeInterval(-Double(Self.inactivityDays) * 86400),
                outboxBefore: now.addingTimeInterval(-Self.outboxKeepSeconds), now: now)
            // Janitor for device links: used/expired codes, links past an optional TTL. All links go only when the operator set
            // DEVICE_LINK_ENABLED=false explicitly: a service that merely lacks the variable (drift, overlay) must not wipe them.
            _ = try? await repo.purgeLinks(now: now, removeAll: config.deviceLink.explicitlyDisabled)
            try? await repo.purgeDeviceOps(now: now)
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
        var events = PushEventBuffer()
        var belowThreshold = 0
        let fresh = now.timeIntervalSince(run.nominal) <= PushEvaluator.maxRunAge
        var firstPage = fresh ? try await repo.evaluationSubscriptions(gridVersion: PushGrid.version, after: nil, limit: evaluationPageSize) : []
        if !fresh { events.skip(nil, .noFreshRun) }
        let slots = firstPage.isEmpty ? [] : try await repo.publishedSlots(runID: run.runID)
        if !firstPage.isEmpty, slots.count != TimeUtil.forecastSlots { events.skip(nil, .incompleteRun) }
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
                    let isLA = sub.liveActivity && sub.kind == .point
                    if let minutes = step.notifyMinutes {
                        events.trigger(.rainStart)
                        if isLA { events.trigger(.laRainStart) }
                        sentAt = now
                        outbox.append(NewOutboxItem(
                            subID: sub.id, dedupeKey: "\(sub.id):\(run.runID)", collapseID: sub.id,
                            payloadJSON: PushEvaluator.payload(minutes: minutes, subscriptionID: sub.id, timeSensitive: sub.timeSensitive, region: sub.kind == .circle),
                            expiresAt: now.addingTimeInterval(PushEvaluator.maxRunAge)))
                    } else if sub.state == .pending, step.state == .pending {
                        // Rain is beginning but the 60-minute repeat lock (shared with the Live Activity start) holds the start back.
                        events.skip(.rainStart, .lock60min)
                        if isLA { events.skip(.laRainStart, .lock60min) }
                    } else if sub.state == .notified, PushEvaluator.isBeginning(threshold: sub.threshold, leadMinutes: sub.leadMinutes, classes: classes[index]) {
                        // Rain would begin again, but the rule is not re-armed yet (needs 30 dry minutes).
                        events.skip(.rainStart, .hysteresis)
                        if isLA { events.skip(.laRainStart, .hysteresis) }
                    } else if sub.state == .dry, step.state == .dry {
                        belowThreshold += 1
                    }
                    if isLA {
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
                        // Decision 6 Nov 2026: an armed immediate start (activation, or a start still in flight) needs only this
                        // one wet run and ignores the 60-minute lock; failed attempts are counted in `startAttempts`.
                        let wetNow = entry.classes.first.map { $0 >= sub.threshold } ?? false
                        var wetStart = false
                        if let target = targets[sub.id] {
                            let hasToken = target.installation.liveActivityStartToken != nil
                            let unlocked = sub.instantStart || (sentAt.map({ now.timeIntervalSince($0) >= PushEvaluator.repeatLock }) ?? true)
                            if wetNow, sub.wetSeen || sub.instantStart, !entry.notify, sub.enabled, target.activity == nil, hasToken, unlocked {
                                wetStart = true
                                sentAt = now
                                events.trigger(.laRainingNow)
                            }
                            // Why no start: reasons are only counted where a start was actually wanted.
                            if entry.notify {
                                if let activity = target.activity { events.skip(.laRainStart, activity.activityToken == nil ? .reservationPending : .activitySlotBusy) }
                                else if !hasToken { events.skip(.laRainStart, .noStartToken) }
                            } else if entry.classes.first == PushIntensity.unknown {
                                events.skip(.laRainingNow, .unknownPixel)
                            } else if wetNow, target.activity == nil, !wetStart {
                                if !sub.wetSeen { events.skip(.laRainingNow, .hysteresis) }
                                else if !hasToken { events.skip(.laRainingNow, .noStartToken) }
                                else if !unlocked { events.skip(.laRainingNow, .lock60min) }
                            }
                            if target.activity != nil || ((entry.notify || wetStart) && hasToken) {
                                activityWork.append(ActivityWork(target: target, classes: entry.classes, notify: entry.notify || wetStart,
                                                                 reference: run.nominal, trigger: wetStart ? .laRainingNow : .laRainStart))
                            }
                        }
                        // The bit stays set while a start is in flight (cleared by the send outcome); any run without a start clears it.
                        if entry.state != sub.state || sentAt != sub.lastSentAt || wetNow != sub.wetSeen || wetStart != sub.instantStart
                            || (!wetStart && sub.startAttempts != 0) {
                            updates.append(SubscriptionUpdate(id: sub.id, state: entry.state, lastSentAt: sentAt, wetSeen: wetNow,
                                                              instantStart: wetStart, startAttempts: wetStart ? sub.startAttempts : 0))
                        }
                    }
                }
                guard page.count >= evaluationPageSize, let last = page.last?.id else { break }
                page = try await repo.evaluationSubscriptions(gridVersion: PushGrid.version, after: last, limit: evaluationPageSize)
            }
            if !complete { updates = []; outbox = []; activityWork = []; events.discard(); events.skip(nil, .incompleteRun) }
            else if belowThreshold > 0 { events.skip(.rainStart, .belowThreshold, by: belowThreshold) }
        }
        // Stale or incomplete runs are marked as seen without any state change, so they are never replayed later.
        if try await repo.commitEvaluation(runID: run.runID, updates: updates, outbox: outbox, now: now) {
            result.evaluatedRun = run.runID
            result.queued = outbox.count
            let replaced = activityQueue.withLock { queue -> [ActivityWork] in defer { queue = activityWork }; return queue }
            // Starts that never got their turn within the per-tick budget are lost with the next run (the lock stays).
            for work in replaced where work.notify { events.skip(work.trigger, .budgetExhausted) }
            events.emit(to: observer)
            observer.outboxCreated(outbox.count)
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
                    if !allowed.contains(item.env) { observer.skipped(.rainStart, .envNotAllowed, by: 1) }
                    observer.alertDropped()
                    try await repo.finishOutbox(id: item.id, .dropped, now: now)
                    result.dropped += 1; progressed = true
                    continue
                }
                let request = ApnsRequest(tokenHex: item.token, env: item.env, topic: config.push.topic, payload: Array(item.payloadJSON.utf8),
                                          collapseID: item.collapseID, expiration: Int(item.expiresAt.timeIntervalSince1970))
                observer.alertAttempt()
                switch await sender.send(request) {
                case .delivered:
                    try await repo.finishOutbox(id: item.id, .sent, now: now); result.sent += 1; progressed = true
                    observer.sent(kind: .alert, env: item.env, outcome: .delivered, reason: nil)
                case .unregistered:
                    _ = try await repo.deleteInstallations(token: item.token, env: item.env); result.unregistered += 1; progressed = true
                    observer.sent(kind: .alert, env: item.env, outcome: .rejected, reason: "Unregistered")
                    observer.tokenInvalidated(.device, .gone)
                case .badToken(let reason), .rejected(let reason):
                    result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
                    try await repo.finishOutbox(id: item.id, .dropped, now: now); result.dropped += 1; progressed = true
                    observer.sent(kind: .alert, env: item.env, outcome: .rejected, reason: reason)
                case .retry(let reason):
                    result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
                    observer.sent(kind: .alert, env: item.env, outcome: .retry, reason: reason)
                    let attempts = item.attempts + 1
                    let delay = Self.retryBackoffSeconds[min(attempts - 1, Self.retryBackoffSeconds.count - 1)] * (1 + Double.random(in: 0..<0.3))
                    let next = now.addingTimeInterval(delay)
                    if attempts >= Self.maxAttempts || next >= item.expiresAt {
                        observer.alertDropped()
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
    /// What started this work (for skip reasons found when the start is attempted).
    var trigger: PushTrigger = .laRainStart
}

final class PushGuarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
