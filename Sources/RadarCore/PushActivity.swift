import Foundation

/// ActivityKit wire contract: content dates use Swift Codable Date's reference epoch (2001).
/// APS timestamp/stale-date/dismissal-date use UNIX seconds, as required by APNs.
public enum PushActivityPayload {
    public static func content(classes: [Int], threshold: Int, reference: Date) -> [String: Any] {
        // `PushIntensity.unknown` (-1) is neither wet nor dry: it never ends rain and never fixes an end time.
        let wet = classes.map { $0 >= threshold }
        var phase = "dry"
        var event: Date?
        if wet.first == true {
            if let end = wet.firstIndex(of: false) {
                if classes[end] >= 0 { phase = "endsIn"; event = reference.addingTimeInterval(Double(end * 300)) } else { phase = "raining" }
            } else { phase = "raining" }
        } else if let start = wet.firstIndex(of: true) {
            phase = "startsIn"; event = reference.addingTimeInterval(Double(start * 300))
        }
        return ["phase": phase, "eventDate": event.map { $0.timeIntervalSinceReferenceDate } ?? NSNull(),
                "intensityClass": max(0, classes.max() ?? 0), "referenceTime": reference.timeIntervalSinceReferenceDate,
                "staleDate": reference.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSinceReferenceDate]
    }

    public static func encode(event: PushActivityEvent, subscriptionID: String, content: [String: Any], now: Date, locale: String = "de") throws -> [UInt8] {
        let state = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        guard state.count <= 4096 else { throw PayloadError.tooLarge }
        var aps: [String: Any] = ["timestamp": Int(now.timeIntervalSince1970), "event": event.rawValue, "content-state": content,
                                  "stale-date": Int(now.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSince1970)]
        if event == .start {
            aps["attributes-type"] = "RainActivityAttributes"
            // No name is uploaded/stored. The app can resolve the subscription locally.
            aps["attributes"] = ["displayName": "", "subscriptionID": subscriptionID]
            // Apple requires an alert for push-to-start. If it already rains (phase endsIn/raining), "starting soon" would be wrong.
            let phase = content["phase"] as? String
            let rainingNow = phase == "endsIn" || phase == "raining"
            let en = locale == "en"
            aps["alert"] = ["title": "Showers", "body": rainingNow ? (en ? "It is raining right now" : "Es regnet gerade")
                                                                    : (en ? "Rain starting soon" : "Regen beginnt bald")]
        }
        if event == .end { aps["dismissal-date"] = Int(now.timeIntervalSince1970) }
        return Array(try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys]))
    }
    public enum PayloadError: Error { case tooLarge }
}

/// Per-tick budget of the Live Activity work: counted sends/endings and wall-clock time, whichever ends first.
struct ActivityBudget {
    var remaining: Int
    let deadline: ContinuousClock.Instant
    init(sends: Int, seconds: Double) {
        remaining = sends
        deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
    }
    var available: Bool { remaining > 0 && ContinuousClock.now < deadline }
    mutating func spend() -> Bool {
        guard available else { return false }
        remaining -= 1
        return true
    }
}

extension PushService {
    /// Never delays alerts: runs after `dispatch`, drains the queue of the last committed run, then ends due activities.
    func processActivities(_ result: inout PushTick) async throws {
        var budget = ActivityBudget(sends: activitySendsPerTick, seconds: activitySecondsPerTick)
        while budget.available, result.isLeader {
            // Take one slice off the queue; the rest stays for the next tick when the budget runs out.
            let work: ActivityWork? = activityQueue.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let work else { break }
            _ = budget.spend()
            let now = clock()
            try await evaluateActivity(target: work.target, classes: work.classes, notify: work.notify, reference: work.reference, now: now, result: &result)
        }
        guard result.isLeader, budget.available else { return }
        try await expireActivities(&result, budget: &budget)
    }

    /// Convenience for a single subscription (tests, tools): looks the target up, then evaluates it.
    func evaluateActivity(sub: PushSubscription, classes: [Int], notify: Bool, reference: Date, now: Date,
                          result: inout PushTick) async throws {
        guard let target = try await repo.activityTarget(subscriptionID: sub.id) else { return }
        try await evaluateActivity(target: target, classes: classes, notify: notify, reference: reference, now: now, result: &result)
    }

    func evaluateActivity(target: PushActivityTarget, classes: [Int], notify: Bool, reference: Date, now: Date,
                          result: inout PushTick) async throws {
        let sub = target.subscription
        guard config.push.environments.contains(target.installation.env) else { return }
        let content = PushActivityPayload.content(classes: classes, threshold: sub.threshold, reference: reference)
        if let activity = target.activity {
            // Only known-dry slots end an activity; unknown pixels keep it running (it still ends at its deadline).
            let window = classes.prefix(7)
            let dry = !window.contains { $0 >= sub.threshold || $0 < 0 }
            let event: PushActivityEvent = dry || activity.endsAt <= now ? .end : .update
            try await sendActivity(target: target, event: event, content: content, now: now, result: &result)
        } else if notify, sub.enabled, sub.liveActivity, sub.kind == .point,
                  target.installation.liveActivityStartToken != nil,
                  try await repo.reserveActivity(subscriptionID: sub.id, now: now) {
            try await sendActivity(target: target, event: .start, content: content, now: now, result: &result)
        }
    }

    /// Enforces the eight-hour deadline even without fresh radar runs, ends opted-out activities and frees stale reservations.
    /// One query per page of `batchSize` rows that actually need an ending; subscriptions without an activity are never read.
    func expireActivities(_ result: inout PushTick, budget: inout ActivityBudget) async throws {
        var after: String?
        while budget.available {
            guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else { result.isLeader = false; return }
            let now = clock()
            let page = try await repo.endableActivities(now: now, reservationTimeout: Self.reservationTimeout, after: after, limit: Self.batchSize)
            for target in page {
                guard budget.spend() else { return }
                let content = PushActivityPayload.content(classes: [], threshold: target.subscription.threshold, reference: now)
                try await sendActivity(target: target, event: .end, content: content, now: now, result: &result)
            }
            guard page.count == Self.batchSize, let last = page.last else { return }
            after = last.subscription.id
        }
    }

    func sendActivity(target: PushActivityTarget, event: PushActivityEvent, content: [String: Any], now: Date,
                      result: inout PushTick) async throws {
        guard config.push.environments.contains(target.installation.env) else { return }
        let subID = target.subscription.id
        let token = event == .start ? target.installation.liveActivityStartToken : target.activity?.activityToken
        guard let token else {
            if event == .end {
                // Only a still tokenless reservation is deleted. If the app registered a token meanwhile, end it via APNs.
                if try await repo.deleteReservation(subscriptionID: subID) { return }
                if let fresh = try await repo.activityTarget(subscriptionID: subID), fresh.activity?.activityToken != nil {
                    try await sendActivity(target: fresh, event: .end, content: content, now: now, result: &result)
                }
            }
            return
        }
        guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else { result.isLeader = false; return }
        let request = ApnsRequest(tokenHex: token, env: target.installation.env, topic: config.push.topic,
                                  payload: try PushActivityPayload.encode(event: event, subscriptionID: subID, content: content, now: now, locale: target.installation.locale == "en" ? "en" : "de"),
                                  collapseID: "activity-" + subID,
                                  expiration: Int(now.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSince1970), activityEvent: event)
        switch await sender.send(request) {
        case .delivered:
            result.sent += 1
            if event == .end { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        case .unregistered:
            result.unregistered += 1
            if event == .start {
                try await repo.clearLiveActivityStartToken(installationID: target.installationID, matchingToken: token)
                _ = try await repo.deleteReservation(subscriptionID: subID)
            } else { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        case .retry:
            // Keep the reservation on ambiguous start failure: never accidentally create a second activity.
            // Updates retry with the next run; end retries on the next tick. A reservation without token expires after
            // `reservationTimeout` (review A7), so a transient failure cannot block the slot for hours.
            result.retried += 1
        case .badToken(let reason):
            // BadDeviceToken on the push-to-start token: the token is unusable, drop it with the reservation (review A8).
            result.dropped += 1
            result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
            if event == .start {
                try await repo.clearLiveActivityStartToken(installationID: target.installationID, matchingToken: token)
                _ = try await repo.deleteReservation(subscriptionID: subID)
            } else if event == .end { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        case .rejected(let reason):
            result.dropped += 1
            result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
            if event == .start { _ = try await repo.deleteReservation(subscriptionID: subID) }
            else if event == .end { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        }
    }
}
