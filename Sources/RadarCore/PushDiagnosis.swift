import Foundation

/// Current radar situation of the subscriptions of one device, derived from the latest published run.
public struct DeviceRadarView: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case ok, noSlot, staleRun }
    public var status: Status
    /// Per subscription id: classes of the forecast slots (-1 = unknown pixel for live activity subscriptions).
    public var classes: [String: [Int]]
    public init(status: Status, classes: [String: [Int]] = [:]) { self.status = status; self.classes = classes }

    /// Decodes the slots of the latest run once and classifies every given point/region subscription. On demand only (no cache).
    public static func load(repo: any Repo, config: Config, subs: [PushSubscription], now: Date) async -> DeviceRadarView {
        guard let run = try? await repo.latestPublished(), let slots = try? await repo.publishedSlots(runID: run.runID),
              slots.count == TimeUtil.forecastSlots else { return DeviceRadarView(status: .noSlot) }
        if now.timeIntervalSince(run.nominal) > PushEvaluator.maxRunAge { return DeviceRadarView(status: .staleRun) }
        var classes: [String: [Int]] = [:]
        for slot in slots.sorted(by: { $0.slotIndex < $1.slotIndex }) {
            guard let blob = try? await repo.getSlot(runID: run.runID, slotID: slot.slotID),
                  let image = try? ImagePipeline.decodeWebP(blob.data), image.width == config.width, image.height == config.height else {
                return DeviceRadarView(status: .noSlot)
            }
            let map = subs.contains { $0.kind == .circle } ? PushIntensity.classMap(image) : []
            for sub in subs {
                let value: Int
                if sub.kind == .circle, let radius = sub.radiusCells {
                    value = PushRegion.pseudoClass(classMap: map, width: image.width, height: image.height, cx: sub.cellX, cy: sub.cellY, radius: radius,
                                                   threshold: sub.threshold, sharePercent: sub.minSharePercent ?? PushRegion.defaultShare)
                } else {
                    value = sub.liveActivity ? PushIntensity.classifyOrUnknown(image, x: sub.cellX, y: sub.cellY) : PushIntensity.classify(image, x: sub.cellX, y: sub.cellY)
                }
                classes[sub.id, default: []].append(value)
            }
        }
        return DeviceRadarView(status: .ok, classes: classes)
    }
}

public enum DiagnosisLevel: String, Sendable, Equatable { case ok, warning, critical, unknown }

public struct DiagnosisCheck: Sendable, Equatable {
    public let order: Int
    public let code: String
    public var level: DiagnosisLevel
    public var reason: String
    /// Fixed keys, values String/Int/Bool; never tokens or cells.
    public var params: [String: DiagnosisValue]
}

public enum DiagnosisValue: Sendable, Equatable { case string(String), int(Int), bool(Bool), null
    var json: Any {
        switch self { case .string(let s): return s; case .int(let i): return i; case .bool(let b): return b; case .null: return NSNull() }
    }
}

/// Pure function (no network): the nine checks of docs/dashboard-insights-plan.md 4.5 in fixed order.
public enum PushDiagnosis {
    public struct Input: Sendable {
        public var pushEnabled: Bool
        /// Push is not known to be off but unknown (no radar replica reported recently). Only with `pushEnabled == false`.
        public var pushUnknown = false
        public var pushPaused: Bool
        public var allowedEnvironments: Set<PushEnvironment>
        public var install: DeviceInstallInfo
        public var subs: [PushSubscription]
        public var activities: [String: PushActivity]
        public var recentEvents: [DeviceEvent]
        public var radar: DeviceRadarView
        public var now: Date
        public init(pushEnabled: Bool, pushPaused: Bool = false, allowedEnvironments: Set<PushEnvironment>, install: DeviceInstallInfo,
                    subs: [PushSubscription], activities: [String: PushActivity], recentEvents: [DeviceEvent], radar: DeviceRadarView, now: Date) {
            self.pushEnabled = pushEnabled; self.pushPaused = pushPaused; self.allowedEnvironments = allowedEnvironments; self.install = install
            self.subs = subs; self.activities = activities; self.recentEvents = recentEvents; self.radar = radar; self.now = now
        }
    }

    public static let deviceTokenOldDays = 30

    static func days(_ from: Date?, _ now: Date) -> Int? { from.map { max(0, Int(now.timeIntervalSince($0) / 86400)) } }

    public static func run(_ input: Input) -> (verdict: DiagnosisCheck?, checks: [DiagnosisCheck]) {
        let now = input.now
        var checks: [DiagnosisCheck] = []
        func add(_ code: String, _ level: DiagnosisLevel, _ reason: String, _ params: [String: DiagnosisValue] = [:]) {
            checks.append(DiagnosisCheck(order: checks.count + 1, code: code, level: level, reason: reason, params: params))
        }
        // 1 server
        if !input.pushEnabled { input.pushUnknown ? add("server", .warning, "push_unknown") : add("server", .critical, "push_disabled") }
        else if input.pushPaused { add("server", .warning, "push_paused") }
        else { add("server", .ok, "ok") }
        // 2 environment
        add("environment", input.allowedEnvironments.contains(input.install.env) ? .ok : .critical,
            input.allowedEnvironments.contains(input.install.env) ? "ok" : "env_not_allowed", ["env": .string(input.install.env.rawValue)])
        // 3 device token
        let tokenAge = days(input.install.tokenUpdatedAt, now)
        let invalidated = input.recentEvents.contains { $0.kind == "token" && now.timeIntervalSince($0.at) < 86400 }
        let ageParam: DiagnosisValue = tokenAge.map { .int($0) } ?? .null
        if invalidated { add("device_token", .warning, "invalidated_recently", ["ageDays": ageParam]) }
        else if let tokenAge, tokenAge >= deviceTokenOldDays { add("device_token", .warning, "old", ["ageDays": ageParam]) }
        else { add("device_token", .ok, "ok", ["ageDays": ageParam]) }
        // 4 start token (age is not recorded: ageDays stays null)
        add("start_token", input.install.hasStartToken ? .ok : .critical, input.install.hasStartToken ? "ok" : "missing", ["ageDays": .null])
        // 5 subscription
        let live = input.subs.filter { $0.kind == .point && $0.liveActivity }
        if input.subs.isEmpty { add("subscription", .critical, "no_subscription") }
        else if !input.subs.contains(where: \.enabled) { add("subscription", .critical, "disabled") }
        else if !live.contains(where: \.enabled) { add("subscription", .warning, "live_activity_off") }
        else { add("subscription", .ok, "ok") }
        // 6 slot
        let running = input.activities.values.filter { $0.activityToken != nil && $0.endsAt > now }
        let reservations = input.activities.values.filter { $0.activityToken == nil }
        if let r = reservations.first {
            let age = Int(now.timeIntervalSince(r.startedAt))
            add("slot", age >= Int(PushService.reservationTimeout) ? .critical : .warning, "reservation_open", ["ageSeconds": .int(age)])
        } else if !running.isEmpty { add("slot", .warning, "activity_running") }
        else { add("slot", .ok, "ok") }
        // 7 lock and hysteresis (first live subscription that shows one)
        let lockUntil = live.filter { !$0.instantStart }.compactMap { s in s.lastSentAt.map { $0.addingTimeInterval(PushEvaluator.repeatLock) } }.filter { $0 > now }.max()
        if let lockUntil { add("lock", .warning, "lock_active", ["lockUntil": .string(TimeUtil.toISO(lockUntil))]) }
        else if live.contains(where: { s in !s.wetSeen && !s.instantStart && (input.radar.classes[s.id]?.first ?? -1) >= s.threshold }) { add("lock", .warning, "hysteresis") }
        else { add("lock", .ok, "ok") }
        // 8 trigger: the first enabled live subscription, else the first enabled one
        let subject = live.first(where: \.enabled) ?? input.subs.first(where: \.enabled)
        switch input.radar.status {
        case .noSlot: add("trigger", .unknown, "no_slot")
        case .staleRun: add("trigger", .warning, "stale_run")
        case .ok:
            if let subject, let classes = input.radar.classes[subject.id], classes.count == TimeUtil.forecastSlots {
                let lead = max(1, min(subject.leadMinutes / 5, classes.count - 1))
                let wet = classes[0] >= subject.threshold || classes[1...lead].contains { $0 >= subject.threshold }
                add("trigger", .ok, wet ? "would_trigger" : "below_threshold",
                    ["thresholdClass": .int(subject.threshold), "currentMaxClass": .int(max(0, classes.max() ?? 0))])
            } else { add("trigger", .unknown, "no_slot") }
        }
        // 9 last result from the event log
        if let last = input.recentEvents.first(where: { $0.kind != "token" }) {
            switch last.outcome {
            case "delivered": add("last_result", .ok, "delivered")
            case "rejected": add("last_result", .critical, "rejected", ["apnsReason": last.reason.map { .string($0) } ?? .null])
            case "retry": add("last_result", .warning, "retry", ["apnsReason": last.reason.map { .string($0) } ?? .null])
            case "dropped": add("last_result", .warning, "dropped", ["apnsReason": last.reason.map { .string($0) } ?? .null])
            default: add("last_result", .unknown, last.outcome == "unregistered" ? "unregistered" : "none")
            }
        } else { add("last_result", .unknown, "none") }
        let verdict = checks.first { $0.level == .critical } ?? checks.first { $0.level == .warning }
        return (verdict, checks)
    }

    /// Summary for the device list: level and the code of the worst check, `unknown` when nothing is known.
    public static func summaryCode(_ verdict: DiagnosisCheck?, install: DeviceInstallInfo) -> (level: DiagnosisLevel, code: String) {
        guard let verdict else { return (.ok, "ok") }
        let code: String
        switch (verdict.code, verdict.reason) {
        case ("start_token", _): code = "no_start_token"
        case ("device_token", "missing"): code = "no_device_token"
        case ("environment", _): code = "env_mismatch"
        case ("subscription", _): code = "no_live_activity_sub"
        default: code = "unknown"
        }
        return (verdict.level, code)
    }
}
