import Foundation

/// In-memory push storage with the same semantics as the MariaDB tables (state lives inside `MemoryRepo`).
struct MemoryPushStore {
    struct Install {
        var secretHash: String
        var token: String
        var env: PushEnvironment
        var locale: String
        var liveActivityStartToken: String?
        var createdAt: Date
        var lastSeenAt: Date
    }
    struct Sub {
        var installID: String
        var value: PushSubscription
        var createdAt: Date
    }
    struct Outbox {
        var id: Int
        var subID: String
        var dedupeKey: String
        var collapseID: String
        var payload: String
        var expiresAt: Date
        var attempts: Int
        var nextAttemptAt: Date
        var status: String
        var finishedAt: Date?
        var createdAt = Date.distantPast
    }
    var installs: [String: Install] = [:]
    var subs: [String: Sub] = [:]
    var outbox: [Int: Outbox] = [:]
    var activities: [String: PushActivity] = [:]
    var nextOutboxID = 1
    var lastRun: String?
    var pausedSince: Date?
    var cacheGeneration = 0
    var cacheScope = "all"

    mutating func removeInstall(_ id: String) {
        installs[id] = nil
        for (subID, sub) in subs where sub.installID == id { removeSub(subID) }
    }

    mutating func removeSub(_ id: String) {
        subs[id] = nil
        activities[id] = nil
        for (outID, item) in outbox where item.subID == id { outbox[outID] = nil }
    }
}

extension MemoryRepo {
    public func upsertInstallation(id: String, secretHash: String, token: String, env: PushEnvironment, locale: String, now: Date,
                                   maxInstallations: Int) async throws -> UpsertResult {
        if push.installs[id] == nil, push.installs.count >= maxInstallations { return .serverFull }
        if var existing = push.installs[id] {
            guard existing.secretHash == secretHash else { return .forbidden }
            existing.token = token; existing.env = env; existing.locale = locale; existing.lastSeenAt = now
            push.installs[id] = existing
            return .updated
        }
        push.installs[id] = .init(secretHash: secretHash, token: token, env: env, locale: locale, createdAt: now, lastSeenAt: now)
        return .created
    }

    public func authenticate(id: String, secretHash: String, now: Date) async throws -> Bool {
        guard var install = push.installs[id], install.secretHash == secretHash else { return false }
        if now.timeIntervalSince(install.lastSeenAt) >= PushGrid.lastSeenRefreshSeconds {
            install.lastSeenAt = now
            push.installs[id] = install
        }
        return true
    }

    public func deleteInstallation(id: String) async throws { push.removeInstall(id) }

    /// Radii of the regions of an installation (excluding `excluding`) and cells of all other regions on the server.
    private func regionUsage(installationID: String, excluding id: String) -> (own: [Int], serverCells: Int) {
        var own: [Int] = [], server = 0
        for (subID, sub) in push.subs where subID != id && sub.value.kind == .circle {
            let radius = sub.value.radiusCells ?? 0
            server += PushRegion.cellCount(radius: radius)
            if sub.installID == installationID { own.append(radius) }
        }
        return (own, server)
    }

    public func addSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, maxPerInstallation: Int,
                                regionLimits: RegionLimits, now: Date) async throws -> AddSubscriptionResult {
        guard push.installs[installationID] != nil else { return .unknownInstallation }
        guard push.subs.values.filter({ $0.installID == installationID && $0.value.kind != .warning }).count < maxPerInstallation else { return .limitReached }
        guard push.subs.values.filter({ $0.value.kind != .warning }).count < regionLimits.maxSubscriptionsServerwide else { return .serverFull }
        if input.liveActivity, push.subs.values.filter({ $0.value.liveActivity }).count >= regionLimits.maxLiveActivitySubscriptions { return .activityCapacity }
        if input.kind == .circle {
            let usage = regionUsage(installationID: installationID, excluding: id)
            switch regionLimits.violation(otherRadii: usage.own, serverCells: usage.serverCells, newRadius: input.radiusCells ?? 0) {
            case .perInstallation?: return .regionLimit
            case .capacity?: return .regionCapacity
            case .activityCapacity?: return .activityCapacity
            case nil: break
            }
        }
        push.subs[id] = .init(installID: installationID, value: PushSubscription(
            id: id, gridVersion: input.gridVersion, cellX: input.cellX, cellY: input.cellY, threshold: input.threshold,
            leadMinutes: input.leadMinutes, enabled: input.enabled, timeSensitive: input.timeSensitive,
            kind: input.kind, radiusCells: input.radiusCells, minSharePercent: input.minSharePercent, liveActivity: input.liveActivity), createdAt: now)
        push.subs[id]?.value.instantStart = input.liveActivity && input.enabled
        push.subs[id]?.value.createdAt = now
        return .created
    }

    public func updateSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, regionLimits: RegionLimits) async throws -> Bool {
        guard var sub = push.subs[id], sub.installID == installationID, sub.value.kind != .warning else { return false }
        if input.liveActivity, !sub.value.liveActivity,
           push.subs.values.filter({ $0.value.liveActivity }).count >= regionLimits.maxLiveActivitySubscriptions { throw PushRegionLimitError.activityCapacity }
        if input.kind == .circle {
            let usage = regionUsage(installationID: installationID, excluding: id)
            if let violation = regionLimits.violation(otherRadii: usage.own, serverCells: usage.serverCells, newRadius: input.radiusCells ?? 0) { throw violation }
        }
        sub.value = PushSubscription(id: id, gridVersion: input.gridVersion, cellX: input.cellX, cellY: input.cellY,
                                     threshold: input.threshold, leadMinutes: input.leadMinutes, enabled: input.enabled,
                                     state: .dry, lastSentAt: sub.value.lastSentAt, timeSensitive: input.timeSensitive,
                                     kind: input.kind, radiusCells: input.radiusCells, minSharePercent: input.minSharePercent, liveActivity: input.liveActivity)
        sub.value.instantStart = input.liveActivity && input.enabled
        sub.value.createdAt = sub.createdAt
        sub.value.changedAt = Date()
        push.subs[id] = sub
        return true
    }

    public func deleteSubscription(installationID: String, id: String) async throws -> Bool {
        guard let sub = push.subs[id], sub.installID == installationID, sub.value.kind != .warning else { return false }
        push.removeSub(id)
        return true
    }

    public func subscriptions(installationID: String) async throws -> [PushSubscription] {
        push.subs.values.filter { $0.installID == installationID && $0.value.kind != .warning }.sorted { $0.createdAt == $1.createdAt ? $0.value.id < $1.value.id : $0.createdAt < $1.createdAt }
            .map(\.value)
    }

    public func installation(id: String) async throws -> PushInstallation? {
        push.installs[id].map { PushInstallation(token: $0.token, env: $0.env, locale: $0.locale, liveActivityStartToken: $0.liveActivityStartToken) }
    }

    public func evaluationSubscriptions(gridVersion: Int, after: String?, limit: Int) async throws -> [PushSubscription] {
        note("evaluationSubscriptions")
        return Array(push.subs.values.map(\.value).filter { $0.enabled && $0.kind != .warning && $0.gridVersion == gridVersion && (after == nil || $0.id > after!) }
            .sorted { $0.id < $1.id }.prefix(max(1, limit)))
    }

    public func lastEvaluatedRun() async throws -> String? { push.lastRun }

    public func commitEvaluation(runID: String, updates: [SubscriptionUpdate], outbox: [NewOutboxItem], now: Date) async throws -> Bool {
        if let last = push.lastRun, last >= runID { return false }
        push.lastRun = runID
        for update in updates {
            guard var sub = push.subs[update.id] else { continue }
            sub.value.state = update.state
            sub.value.wetSeen = update.wetSeen
            sub.value.instantStart = update.instantStart
            sub.value.startAttempts = update.startAttempts & 3
            sub.value.lastSentAt = update.lastSentAt
            if let trace = update.trace { sub.value.trace = trace }
            push.subs[update.id] = sub
        }
        for item in outbox where push.subs[item.subID] != nil && !push.outbox.values.contains(where: { $0.dedupeKey == item.dedupeKey }) {
            let id = push.nextOutboxID
            push.nextOutboxID += 1
            push.outbox[id] = .init(id: id, subID: item.subID, dedupeKey: item.dedupeKey, collapseID: item.collapseID,
                                    payload: item.payloadJSON, expiresAt: item.expiresAt, attempts: 0, nextAttemptAt: now,
                                    status: "pending", finishedAt: nil, createdAt: now)
        }
        return true
    }

    public func dueOutbox(now: Date, limit: Int) async throws -> [OutboxItem] {
        push.outbox.values.filter { $0.status == "pending" && $0.nextAttemptAt <= now }.sorted { $0.id < $1.id }.prefix(limit).compactMap { item in
            guard let sub = push.subs[item.subID], let install = push.installs[sub.installID] else { return nil }
            return OutboxItem(id: item.id, token: install.token, env: install.env, collapseID: item.collapseID,
                              payloadJSON: item.payload, expiresAt: item.expiresAt, attempts: item.attempts)
        }
    }

    public func finishOutbox(id: Int, _ outcome: OutboxOutcome, now: Date) async throws {
        guard var item = push.outbox[id] else { return }
        switch outcome {
        case .sent: item.status = "sent"; item.finishedAt = now
        case .dropped: item.status = "dropped"; item.finishedAt = now
        case .retry(let attempts, let at): item.attempts = attempts; item.nextAttemptAt = at
        }
        push.outbox[id] = item
    }

    public func deleteInstallations(token: String, env: PushEnvironment) async throws -> Int {
        let ids = push.installs.filter { $0.value.token == token && $0.value.env == env }.map(\.key)
        for id in ids { push.removeInstall(id) }
        return ids.count
    }

    public func purgePush(inactiveBefore: Date, outboxBefore: Date, now: Date) async throws -> PushPurgeResult {
        var result = PushPurgeResult()
        for (id, install) in push.installs where install.lastSeenAt < inactiveBefore { push.removeInstall(id); result.installations += 1 }
        for (id, item) in push.outbox where (item.status != "pending" && (item.finishedAt ?? item.expiresAt) < outboxBefore)
            || (item.status == "pending" && item.expiresAt < outboxBefore) {
            push.outbox[id] = nil
            result.outbox += 1
        }
        return result
    }
}

extension MemoryRepo {
    public func setLiveActivityStartToken(installationID: String, token: String?) async throws {
        let old = push.installs[installationID]?.liveActivityStartToken
        push.installs[installationID]?.liveActivityStartToken = token
        if token != nil, token != old {
            for (id, sub) in push.subs where sub.installID == installationID && sub.value.liveActivity { push.subs[id]?.value.instantStart = true; push.subs[id]?.value.startAttempts = 0 }
        }
    }

    public func setStartRetry(subscriptionID: String, armed: Bool, attempts: Int) async throws {
        push.subs[subscriptionID]?.value.instantStart = armed
        push.subs[subscriptionID]?.value.startAttempts = attempts & 3
    }

    public func clearLiveActivityStartToken(installationID: String, matchingToken: String) async throws {
        if push.installs[installationID]?.liveActivityStartToken == matchingToken {
            push.installs[installationID]?.liveActivityStartToken = nil
        }
    }

    public func activityTarget(subscriptionID: String) async throws -> PushActivityTarget? {
        note("activityTarget")
        guard let sub = push.subs[subscriptionID], let install = try await installation(id: sub.installID) else { return nil }
        return PushActivityTarget(installationID: sub.installID, installation: install, subscription: sub.value,
                                  activity: push.activities[subscriptionID])
    }

    public func subscriptionOwner(subscriptionID: String) async throws -> String? {
        note("subscriptionOwner")
        return push.subs[subscriptionID]?.installID
    }

    public func activityTargets(subscriptionIDs: [String]) async throws -> [PushActivityTarget] {
        note("activityTargets")
        return targets(subscriptionIDs)
    }

    private func targets(_ subscriptionIDs: [String]) -> [PushActivityTarget] {
        subscriptionIDs.compactMap { id in
            guard let sub = push.subs[id], let install = push.installs[sub.installID] else { return nil }
            return PushActivityTarget(
                installationID: sub.installID,
                installation: PushInstallation(token: install.token, env: install.env, locale: install.locale, liveActivityStartToken: install.liveActivityStartToken),
                subscription: sub.value, activity: push.activities[id])
        }
    }

    public func endableActivities(now: Date, reservationTimeout: TimeInterval, after: String?, limit: Int) async throws -> [PushActivityTarget] {
        note("endableActivities")
        let ids = push.activities.values.filter { activity in
            guard after == nil || activity.subscriptionID > after!, let sub = push.subs[activity.subscriptionID] else { return false }
            return activity.endsAt <= now || !sub.value.enabled || !sub.value.liveActivity
                || (activity.activityToken == nil && activity.startedAt <= now.addingTimeInterval(-reservationTimeout))
        }.map(\.subscriptionID).sorted().prefix(max(1, limit))
        return targets(Array(ids)).sorted { $0.subscription.id < $1.subscription.id }
    }

    public func deleteReservation(subscriptionID: String) async throws -> Bool {
        guard let activity = push.activities[subscriptionID], activity.activityToken == nil else { return false }
        push.activities[subscriptionID] = nil
        return true
    }

    public func reserveActivity(subscriptionID: String, now: Date) async throws -> Bool {
        guard let sub = push.subs[subscriptionID], sub.value.enabled, sub.value.liveActivity,
              !push.activities.keys.contains(where: { push.subs[$0]?.installID == sub.installID }) else { return false }
        push.activities[subscriptionID] = PushActivity(subscriptionID: subscriptionID, activityToken: nil, startedAt: now,
                                                       endsAt: now.addingTimeInterval(8 * 3600))
        return true
    }

    public func reserveActivity(subscriptionID: String, now: Date, displacingRegion: Bool) async throws -> ActivityReservation {
        note("reserveActivityDisplacing")
        guard let sub = push.subs[subscriptionID], sub.value.enabled, sub.value.liveActivity else { return .busy }
        var displaced: ActivityReservation?
        if let held = push.activities.values.first(where: { push.subs[$0.subscriptionID]?.installID == sub.installID }) {
            // Only a point displaces, and only a region.
            guard displacingRegion, sub.value.kind == .point, push.subs[held.subscriptionID]?.value.kind == .circle, held.subscriptionID != subscriptionID else { return .busy }
            guard let token = held.activityToken else { return .regionReservationPending }
            push.activities[held.subscriptionID] = nil
            displaced = .displaced(subscriptionID: held.subscriptionID, activityToken: token)
        }
        push.activities[subscriptionID] = PushActivity(subscriptionID: subscriptionID, activityToken: nil, startedAt: now, endsAt: now.addingTimeInterval(8 * 3600))
        return displaced ?? .reserved
    }

    public func setActivityToken(subscriptionID: String, token: String, now: Date) async throws -> PushActivityRegistrationResult {
        guard let sub = push.subs[subscriptionID] else { return .notFound }
        guard sub.value.enabled, sub.value.liveActivity else { return .notEligible }
        if var activity = push.activities[subscriptionID] {
            guard activity.endsAt > now else { return .notEligible }
            activity.activityToken = token
            push.activities[subscriptionID] = activity
            return .updated
        }
        guard !push.activities.keys.contains(where: { push.subs[$0]?.installID == sub.installID }) else { return .activityLimit }
        push.activities[subscriptionID] = PushActivity(subscriptionID: subscriptionID, activityToken: token, startedAt: now,
                                                       endsAt: now.addingTimeInterval(8 * 3600))
        return .updated
    }

    public func deleteActivity(subscriptionID: String, matchingToken: String?) async throws -> Bool {
        guard let activity = push.activities[subscriptionID], matchingToken == nil || activity.activityToken == matchingToken else { return false }
        push.activities[subscriptionID] = nil
        return true
    }
}

extension MemoryRepo: PushOperatorRepo {
    public func pushPausedSince() async throws -> Date? { push.pausedSince }

    @discardableResult public func setPushPaused(_ paused: Bool, now: Date) async throws -> Date? {
        if !paused { push.pausedSince = nil } else if push.pausedSince == nil { push.pausedSince = now }
        return push.pausedSince
    }

    public func cacheClearState() async throws -> CacheClearState { CacheClearState(generation: push.cacheGeneration, scope: push.cacheScope) }

    public func requestCacheClear(scope: String) async throws -> Int {
        push.cacheGeneration += 1
        push.cacheScope = scope
        return push.cacheGeneration
    }

    public func outboxGauge(now: Date) async throws -> OutboxGauge {
        var gauge = OutboxGauge()
        var oldest: Date?
        for item in push.outbox.values {
            if item.status == "pending", item.expiresAt > now {
                gauge.waiting += 1
                if item.attempts > 0 { gauge.retrying += 1 }
                oldest = min(oldest ?? item.createdAt, item.createdAt)
            }
            let since = now.addingTimeInterval(-86400)
            if item.status == "dropped", (item.finishedAt ?? item.expiresAt) >= since { gauge.droppedOrExpired24h += 1 }
            else if item.status == "pending", item.expiresAt <= now, item.expiresAt >= since { gauge.droppedOrExpired24h += 1 }
        }
        gauge.oldestAgeSeconds = oldest.map { max(0, Int(now.timeIntervalSince($0))) }
        return gauge
    }
}
