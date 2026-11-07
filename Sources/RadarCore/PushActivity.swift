import Foundation

/// ActivityKit wire contract: content dates use Swift Codable Date's reference epoch (2001).
/// APS timestamp/stale-date/dismissal-date use UNIX seconds, as required by APNs.
public enum PushActivityPayload {
    /// `region`: Live Activity of a circle subscription. Its keys `wetSharePercent`, `peakSharePercent` and `regionRadiusKm` are only present
    /// then (a point payload stays byte-identical to the old contract); `intensityClass` is the highest class inside the disc.
    public static func content(classes: [Int], threshold: Int, reference: Date, region: RegionActivityContent? = nil) -> [String: Any] {
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
        var content: [String: Any] = ["phase": phase, "eventDate": event.map { $0.timeIntervalSinceReferenceDate } ?? NSNull(),
                "intensityClass": max(0, region?.maxClass ?? classes.max() ?? 0), "referenceTime": reference.timeIntervalSinceReferenceDate,
                "staleDate": reference.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSinceReferenceDate]
        if let region {
            content["wetSharePercent"] = region.wetSharePercent
            content["peakSharePercent"] = region.peakSharePercent
            if let km = region.radiusKm { content["regionRadiusKm"] = km }
        }
        return content
    }

    public static func encode(event: PushActivityEvent, subscriptionID: String, content: [String: Any], now: Date, locale: String = "de", probe: Bool = false) throws -> [UInt8] {
        let state = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        guard state.count <= 4096 else { throw PayloadError.tooLarge }
        var aps: [String: Any] = ["timestamp": Int(now.timeIntervalSince1970), "event": event.rawValue, "content-state": content,
                                  "stale-date": Int(now.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSince1970)]
        if event == .start {
            aps["attributes-type"] = "RainActivityAttributes"
            // Apple (iOS 18+): required so the system hands the app an update push token for this activity.
            aps["input-push-token"] = 1
            // No name is uploaded/stored. The app can resolve the subscription locally.
            aps["attributes"] = ["displayName": "", "subscriptionID": subscriptionID]
            // Apple requires an alert for push-to-start. If it already rains (phase endsIn/raining), "starting soon" would be wrong.
            let phase = content["phase"] as? String
            let rainingNow = phase == "endsIn" || phase == "raining"
            let en = locale == "en"
            if probe {
                aps["alert"] = ["title": "Showers", "body": en ? "Live Activity test" : "Live-Activity-Test"]
            } else {
            aps["alert"] = ["title": "Showers", "body": rainingNow ? (en ? "It is raining right now" : "Es regnet gerade")
                                                                    : (en ? "Rain starting soon" : "Regen beginnt bald")]
            }
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
            // A point has taken the slot from this region since the run was evaluated: its activity is gone (the end was sent), nothing to update.
            if displacedRegions.withLock({ $0.contains(work.target.subscription.id) }) { continue }
            _ = budget.spend()
            let now = clock()
            try await evaluateActivity(target: work.target, classes: work.classes, notify: work.notify, reference: work.reference, now: now, result: &result,
                                       trigger: work.trigger, region: work.region)
        }
        guard result.isLeader, budget.available else { return }
        try await expireActivities(&result, budget: &budget)
    }

    /// Convenience for a single subscription (tests, tools): looks the target up, then evaluates it.
    func evaluateActivity(sub: PushSubscription, classes: [Int], notify: Bool, reference: Date, now: Date,
                          result: inout PushTick, region: RegionActivityContent? = nil) async throws {
        guard let target = try await repo.activityTarget(subscriptionID: sub.id) else { return }
        try await evaluateActivity(target: target, classes: classes, notify: notify, reference: reference, now: now, result: &result, region: region)
    }

    func evaluateActivity(target: PushActivityTarget, classes: [Int], notify: Bool, reference: Date, now: Date,
                          result: inout PushTick, trigger: PushTrigger = .laRainStart, region: RegionActivityContent? = nil) async throws {
        let sub = target.subscription
        guard config.push.environments.contains(target.installation.env) else {
            if notify { observer.skipped(trigger, .envNotAllowed, by: 1) }
            if trigger == .laRainingNow, notify { try await repo.setStartRetry(subscriptionID: sub.id, armed: false, attempts: 0) }
            return
        }
        let content = PushActivityPayload.content(classes: classes, threshold: sub.threshold, reference: reference, region: region)
        if let activity = target.activity {
            // Only known-dry slots end an activity; unknown pixels (and unknown cells of a region) keep it running (it still ends at its deadline).
            let window = classes.prefix(7)
            let dry = !window.contains { $0 >= sub.threshold || $0 < 0 }
            let event: PushActivityEvent = dry || activity.endsAt <= now ? .end : .update
            try await sendActivity(target: target, event: event, content: content, now: now, result: &result)
        } else if notify, sub.enabled, sub.liveActivity, target.installation.liveActivityStartToken != nil {
            // Slot conflict (decision 7 Nov 2026): a point beats a region. For a point the reservation is atomic and may take the slot
            // from a running region activity (its row is deleted in the same transaction); a region never displaces anything.
            let reservation = try await repo.reserveActivity(subscriptionID: sub.id, now: now, displacingRegion: sub.kind == .point)
            var reserved = false
            var skip = PushSkipReason.activitySlotBusy
            switch reservation {
            case .reserved: reserved = true
            case .displaced(let heldID, let heldToken):
                reserved = true
                await endDisplacedRegion(subscriptionID: heldID, token: heldToken, now: now, result: &result)
            case .regionReservationPending: skip = .reservationPending
            case .busy: break
            }
            if reserved {
                try await sendActivity(target: target, event: .start, content: content, now: now, result: &result,
                                       retryable: trigger == .laRainingNow)
            } else {
                // Another subscription of the same installation holds the one activity slot; the start is lost (lock stays).
                // Exception: a rain-now start behind a region start still in flight keeps its armed bit and tries again with the next run.
                observer.skipped(trigger, skip, by: 1)
                if trigger == .laRainingNow, skip == .activitySlotBusy { try await repo.setStartRetry(subscriptionID: sub.id, armed: false, attempts: 0) }
            }
        }
    }

    /// Ends the region activity that a point has just displaced (the slot row is already gone). Best effort: the end is sent once, whatever APNs
    /// answers is only counted (an end that fails is not retried; the region activity then ends with its own deadline or the app's guard).
    /// The region keeps its automaton state and 60-minute lock and may start again once the slot is free and its own rules allow.
    func endDisplacedRegion(subscriptionID: String, token: String, now: Date, result: inout PushTick) async {
        displacedRegions.withLock { _ = $0.insert(subscriptionID) }
        guard var held = try? await repo.activityTarget(subscriptionID: subscriptionID) else { return }
        held.activity = PushActivity(subscriptionID: subscriptionID, activityToken: token, startedAt: now, endsAt: now)
        let content = PushActivityPayload.content(classes: [], threshold: held.subscription.threshold, reference: now)
        try? await sendActivity(target: held, event: .end, content: content, now: now, result: &result)
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
                try await sendActivity(target: target, event: .end, content: content, now: now, result: &result, expire: true)
            }
            guard page.count == Self.batchSize, let last = page.last else { return }
            after = last.subscription.id
        }
    }

    func sendActivity(target: PushActivityTarget, event: PushActivityEvent, content: [String: Any], now: Date,
                      result: inout PushTick, expire: Bool = false, retryable: Bool = false) async throws {
        guard config.push.environments.contains(target.installation.env) else { return }
        let subID = target.subscription.id
        let token = event == .start ? target.installation.liveActivityStartToken : target.activity?.activityToken
        guard let token else {
            if event == .end {
                // Only a still tokenless reservation is deleted. If the app registered a token meanwhile, end it via APNs.
                if try await repo.deleteReservation(subscriptionID: subID) { observer.reservationExpired(); return }
                if let fresh = try await repo.activityTarget(subscriptionID: subID), fresh.activity?.activityToken != nil {
                    try await sendActivity(target: fresh, event: .end, content: content, now: now, result: &result, expire: expire)
                }
            }
            return
        }
        guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else { result.isLeader = false; return }
        let request = ApnsRequest(tokenHex: token, env: target.installation.env, topic: config.push.topic,
                                  payload: try PushActivityPayload.encode(event: event, subscriptionID: subID, content: content, now: now, locale: target.installation.locale == "en" ? "en" : "de", probe: probeAlert),
                                  collapseID: "activity-" + subID,
                                  expiration: Int(now.addingTimeInterval(PushEvaluator.maxRunAge).timeIntervalSince1970), activityEvent: event)
        let env = target.installation.env
        let kind: PushSendKind = event == .start ? .start : (event == .update ? .update : .end)
        let outcome = await sender.send(request)
        // A rain-now start in flight (bit set at commit) is settled here: success and final failures clear it, `retry` re-arms it.
        if event == .start, retryable {
            var again = false
            if case .retry = outcome { again = target.subscription.startAttempts + 1 < Self.maxStartAttempts }
            if again {
                // Transient failure: free the reservation so the next run may start again without the lock (small duplicate risk,
                // bounded by `maxStartAttempts`). Final failure keeps the old behaviour (reservation stays, lock holds).
                _ = try await repo.deleteReservation(subscriptionID: subID)
            }
            try await repo.setStartRetry(subscriptionID: subID, armed: again, attempts: again ? target.subscription.startAttempts + 1 : 0)
        }
        switch outcome {
        case .delivered:
            result.sent += 1
            observer.sent(kind: kind, env: env, outcome: .delivered, reason: nil, expire: expire)
            if event == .end { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        case .unregistered:
            result.unregistered += 1
            observer.sent(kind: kind, env: env, outcome: .rejected, reason: "Unregistered", expire: expire)
            observer.tokenInvalidated(event == .start ? .start : .activity, .gone)
            if event == .start {
                try await repo.clearLiveActivityStartToken(installationID: target.installationID, matchingToken: token)
                _ = try await repo.deleteReservation(subscriptionID: subID)
            } else { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        case .retry(let reason):
            // Keep the reservation on ambiguous start failure: never accidentally create a second activity.
            // Updates retry with the next run; end retries on the next tick. A reservation without token expires after
            // `reservationTimeout` (review A7), so a transient failure cannot block the slot for hours.
            // Rain-now starts are retried (see `retryable`, at most `maxStartAttempts` attempts); other starts are not.
            result.retried += 1
            observer.sent(kind: kind, env: env, outcome: .retry, reason: reason, expire: expire)
        case .badToken(let reason):
            // BadDeviceToken on the push-to-start token: the token is unusable, drop it with the reservation (review A8).
            result.dropped += 1
            result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
            observer.sent(kind: kind, env: env, outcome: .rejected, reason: reason, expire: expire)
            if event != .update { observer.tokenInvalidated(event == .start ? .start : .activity, .badDeviceToken) }
            if event == .start {
                try await repo.clearLiveActivityStartToken(installationID: target.installationID, matchingToken: token)
                _ = try await repo.deleteReservation(subscriptionID: subID)
            } else if event == .end { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        case .rejected(let reason):
            result.dropped += 1
            result.apnsReasons[String(reason.prefix(64)), default: 0] += 1
            observer.sent(kind: kind, env: env, outcome: .rejected, reason: reason, expire: expire)
            if event == .start { _ = try await repo.deleteReservation(subscriptionID: subID) }
            else if event == .end { _ = try await repo.deleteActivity(subscriptionID: subID, matchingToken: token) }
        }
    }
}
