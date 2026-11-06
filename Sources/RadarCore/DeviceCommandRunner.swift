import Foundation

/// Remembers the last APNs answer of a command so that its result can report it (the normal send paths only return counters).
final class RecordingSender: ApnsSender, @unchecked Sendable {
    private let inner: any ApnsSender
    private let lock = NSLock()
    private var results: [ApnsResult] = []
    init(_ inner: any ApnsSender) { self.inner = inner }
    func send(_ request: ApnsRequest) async -> ApnsResult {
        let result = await inner.send(request)
        lock.withLock { results.append(result) }
        return result
    }
    var last: ApnsResult? { lock.withLock { results.last } }
}

enum DeviceOutcome {
    /// (outcome, apnsStatus, reason) of an APNs answer, using the contract's fixed words.
    static func describe(_ result: ApnsResult?) -> (outcome: String, status: Int?, reason: String?) {
        switch result {
        case .delivered: return ("delivered", 200, nil)
        case .unregistered: return ("rejected", 410, "Unregistered")
        case .badToken(let r): return ("rejected", 400, String(r.prefix(64)))
        case .rejected(let r): return ("rejected", nil, String(r.prefix(64)))
        case .retry(let r): return ("retry", nil, String(r.prefix(64)))
        case nil: return ("dropped", nil, nil)
        }
    }
}

extension PushService {
    /// Leader work between ticks (called about every 2 seconds): runs queued dashboard commands of linked devices.
    /// Only the push leader acts; other replicas leave the queue alone. Uses the same dispatch code as normal operation.
    public func processCommands(maxCommands: Int = 5) async {
        guard config.push.enabled, config.deviceLink.enabled else { return }
        guard (try? await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds)) == true else { return }
        for _ in 0..<maxCommands {
            guard let command = try? await repo.claimNextCommand(now: clock()) else { return }
            let (result, error) = await execute(command)
            let status: DeviceCommandStatus = error == nil ? .done : .failed
            try? await repo.finishCommand(id: command.id, status: status, result: result, error: error, now: clock())
            if let device = try? await repo.device(id: command.deviceID) {
                let outcome = error ?? (((try? JSONSerialization.jsonObject(with: Data((result ?? "{}").utf8))) as? [String: Any])?["outcome"] as? String ?? "done")
                try? await repo.appendDeviceAudit(action: .deviceAction, deviceRef: DashboardValidation.deviceRef(device.id),
                                                  outcome: "\(command.kind.rawValue):\(outcome)", now: clock())
            }
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// (result JSON, error code). Exactly one is set.
    func execute(_ command: DeviceCommand) async -> (String?, String?) {
        guard let device = try? await repo.device(id: command.deviceID), let install = try? await repo.installation(id: device.installID) else {
            return (nil, "device_gone")
        }
        let now = clock()
        let recorder = RecordingSender(sender)
        let worker = PushService(config: config, repo: repo, sender: recorder, owner: owner, clock: clock, stats: stats,
                                 probeAlert: command.kind == .laProbe, observer: NoPushObserver())
        do {
            switch command.kind {
            case .test:
                guard config.push.environments.contains(install.env) else { return (nil, "environment_not_allowed") }
                let request = ApnsRequest(tokenHex: install.token, env: install.env, topic: config.push.topic,
                                          payload: Array(PushEvaluator.testPayload(locale: install.locale).utf8),
                                          collapseID: "test-" + device.installID, expiration: Int(now.addingTimeInterval(PushApi.testExpirySeconds).timeIntervalSince1970))
                let answer = await recorder.send(request)
                if case .unregistered = answer { _ = try await repo.deleteInstallations(token: install.token, env: install.env) }
                let d = DeviceOutcome.describe(answer)
                try await repo.appendDeviceEvent(installationID: device.installID, kind: "test", outcome: d.outcome, reason: d.reason, now: now)
                return (Self.json(["outcome": d.outcome, "apnsStatus": d.status as Any? ?? NSNull(), "reason": d.reason as Any? ?? NSNull()]), nil)
            case .laProbe:
                return try await probe(worker, recorder, device: device, install: install, now: now)
            case .laEnd:
                return try await endActivities(worker, recorder, device: device, now: now)
            case .reeval:
                return try await reevaluate(worker, command: command, device: device, install: install, now: now)
            case .resetSlot:
                var cleared = "none"
                for sub in try await repo.subscriptions(installationID: device.installID) {
                    if let target = try await repo.activityTarget(subscriptionID: sub.id), let activity = target.activity {
                        cleared = activity.activityToken != nil ? "activity" : (cleared == "activity" ? cleared : "reservation")
                        _ = try await repo.deleteActivity(subscriptionID: sub.id, matchingToken: nil)
                    }
                }
                return (Self.json(["cleared": cleared]), nil)
            }
        } catch {
            return (nil, "internal")
        }
    }

    private func probe(_ worker: PushService, _ recorder: RecordingSender, device: LinkedDevice, install: PushInstallation, now: Date) async throws -> (String?, String?) {
        guard config.push.environments.contains(install.env) else { return (nil, "environment_not_allowed") }
        func skipped(_ reason: String) async throws -> (String?, String?) {
            try await repo.appendDeviceEvent(installationID: device.installID, kind: "probe", outcome: "skipped", reason: reason, now: now)
            return (Self.json(["outcome": "dropped", "apnsStatus": NSNull(), "reason": NSNull(), "skipped": reason]), nil)
        }
        let subs = try await repo.subscriptions(installationID: device.installID)
        guard install.liveActivityStartToken != nil, let sub = subs.first(where: { $0.enabled && $0.liveActivity && $0.kind == .point }) else {
            return try await skipped("no_start_token")
        }
        guard let target = try await repo.activityTarget(subscriptionID: sub.id) else { return (nil, "internal") }
        if let activity = target.activity { return try await skipped(activity.activityToken == nil ? "reservation_pending" : "activity_slot_busy") }
        // Another subscription of the installation may hold the single slot.
        let all = try await repo.activityTargets(subscriptionIDs: subs.map(\.id))
        if let busy = all.first(where: { $0.activity != nil })?.activity { return try await skipped(busy.activityToken == nil ? "reservation_pending" : "activity_slot_busy") }
        guard try await repo.reserveActivity(subscriptionID: sub.id, now: now) else { return try await skipped("activity_slot_busy") }
        let view = await DeviceRadarView.load(repo: repo, config: config, subs: [sub], now: now)
        let classes = view.classes[sub.id] ?? [Int](repeating: 0, count: TimeUtil.forecastSlots)
        let content = PushActivityPayload.content(classes: classes, threshold: sub.threshold, reference: now)
        var tick = PushTick(); tick.isLeader = true
        try await worker.sendActivity(target: target, event: .start, content: content, now: now, result: &tick)
        let d = DeviceOutcome.describe(recorder.last)
        try await repo.appendDeviceEvent(installationID: device.installID, kind: "probe", outcome: d.outcome, reason: d.reason, now: now)
        return (Self.json(["outcome": d.outcome, "apnsStatus": d.status as Any? ?? NSNull(), "reason": d.reason as Any? ?? NSNull(), "skipped": NSNull()]), nil)
    }

    private func endActivities(_ worker: PushService, _ recorder: RecordingSender, device: LinkedDevice, now: Date) async throws -> (String?, String?) {
        let subs = try await repo.subscriptions(installationID: device.installID)
        var had = false, reservationCleared = false
        var outcome = "dropped", reason: String?
        for target in try await repo.activityTargets(subscriptionIDs: subs.map(\.id)) {
            guard let activity = target.activity else { continue }
            had = true
            if activity.activityToken == nil {
                reservationCleared = try await repo.deleteReservation(subscriptionID: target.subscription.id) || reservationCleared
                continue
            }
            guard config.push.environments.contains(target.installation.env) else { return (nil, "environment_not_allowed") }
            var tick = PushTick(); tick.isLeader = true
            let content = PushActivityPayload.content(classes: [], threshold: target.subscription.threshold, reference: now)
            try await worker.sendActivity(target: target, event: .end, content: content, now: now, result: &tick)
            let d = DeviceOutcome.describe(recorder.last)
            outcome = d.outcome; reason = d.reason
        }
        if had { try await repo.appendDeviceEvent(installationID: device.installID, kind: "la_end", outcome: outcome, reason: reason, now: now) }
        return (Self.json(["outcome": outcome, "hadActivity": had, "reservationCleared": reservationCleared]), nil)
    }

    private func reevaluate(_ worker: PushService, command: DeviceCommand, device: LinkedDevice, install: PushInstallation, now: Date) async throws -> (String?, String?) {
        let dryRun = command.dryRun ?? true
        let subs = try await repo.subscriptions(installationID: device.installID)
        let view = await DeviceRadarView.load(repo: repo, config: config, subs: subs, now: now)
        guard view.status == .ok, let run = try await repo.latestPublished() else { return (nil, "internal") }
        let targets = Dictionary(uniqueKeysWithValues: try await repo.activityTargets(subscriptionIDs: subs.map(\.id)).map { ($0.subscription.id, $0) })
        var rows: [[String: Any]] = []
        for (index, sub) in subs.enumerated() {
            let classes = view.classes[sub.id] ?? []
            let decision = Self.decide(sub: sub, classes: classes, hasStartToken: install.liveActivityStartToken != nil,
                                       activity: targets[sub.id]?.activity, now: now)
            var sent: Any = NSNull()
            if !dryRun {
                sent = false
                if decision == "would_trigger", sub.liveActivity, sub.kind == .point, let target = targets[sub.id] {
                    var tick = PushTick(); tick.isLeader = true
                    try await worker.evaluateActivity(target: target, classes: classes, notify: true, reference: run.nominal, now: now, result: &tick)
                    sent = tick.sent > 0
                }
            }
            rows.append(["index": index, "decision": decision, "sent": sent])
        }
        return (Self.json(["dryRun": dryRun, "subscriptions": rows]), nil)
    }

    /// Decision of the evaluation for one subscription, without side effects. Locks only matter when the rule would otherwise fire.
    static func decide(sub: PushSubscription, classes: [Int], hasStartToken: Bool, activity: PushActivity?, now: Date) -> String {
        guard sub.enabled else { return "not_enabled" }
        guard classes.count == TimeUtil.forecastSlots else { return "below_threshold" }
        let live = sub.liveActivity && sub.kind == .point
        let wetNow = classes[0] >= sub.threshold
        let lead = max(1, min(sub.leadMinutes / 5, classes.count - 1))
        let beginning = !wetNow && classes[1...lead].contains { $0 >= sub.threshold }
        let wetStart = live && wetNow && (sub.wetSeen || sub.instantStart)
        guard beginning || wetStart else { return live && wetNow && !sub.wetSeen && !sub.instantStart ? "hysteresis" : "below_threshold" }
        if live {
            if !hasStartToken { return "no_start_token" }
            if let activity { return activity.activityToken == nil ? "reservation_pending" : "activity_slot_busy" }
        }
        if let sent = sub.lastSentAt, now.timeIntervalSince(sent) < PushEvaluator.repeatLock { return "lock" }
        return "would_trigger"
    }
}
