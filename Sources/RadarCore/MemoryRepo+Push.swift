import Foundation

/// In-memory push storage with the same semantics as the MariaDB tables (state lives inside `MemoryRepo`).
struct MemoryPushStore {
    struct Install {
        var secretHash: String
        var token: String
        var env: PushEnvironment
        var locale: String
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
    }
    var installs: [String: Install] = [:]
    var subs: [String: Sub] = [:]
    var outbox: [Int: Outbox] = [:]
    var nextOutboxID = 1
    var lastRun: String?

    mutating func removeInstall(_ id: String) {
        installs[id] = nil
        for (subID, sub) in subs where sub.installID == id { removeSub(subID) }
    }

    mutating func removeSub(_ id: String) {
        subs[id] = nil
        for (outID, item) in outbox where item.subID == id { outbox[outID] = nil }
    }
}

extension MemoryRepo {
    public func upsertInstallation(id: String, secretHash: String, token: String, env: PushEnvironment, locale: String, now: Date) async throws -> UpsertResult {
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
        install.lastSeenAt = now
        push.installs[id] = install
        return true
    }

    public func deleteInstallation(id: String) async throws { push.removeInstall(id) }

    public func addSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, maxPerInstallation: Int, now: Date) async throws -> AddSubscriptionResult {
        guard push.installs[installationID] != nil else { return .unknownInstallation }
        guard push.subs.values.filter({ $0.installID == installationID }).count < maxPerInstallation else { return .limitReached }
        push.subs[id] = .init(installID: installationID, value: PushSubscription(
            id: id, gridVersion: input.gridVersion, cellX: input.cellX, cellY: input.cellY, threshold: input.threshold,
            leadMinutes: input.leadMinutes, enabled: input.enabled, timeSensitive: input.timeSensitive), createdAt: now)
        return .created
    }

    public func updateSubscription(installationID: String, id: String, _ input: PushSubscriptionInput) async throws -> Bool {
        guard var sub = push.subs[id], sub.installID == installationID else { return false }
        sub.value = PushSubscription(id: id, gridVersion: input.gridVersion, cellX: input.cellX, cellY: input.cellY,
                                     threshold: input.threshold, leadMinutes: input.leadMinutes, enabled: input.enabled,
                                     state: .dry, lastSentAt: sub.value.lastSentAt, timeSensitive: input.timeSensitive)
        push.subs[id] = sub
        return true
    }

    public func deleteSubscription(installationID: String, id: String) async throws -> Bool {
        guard let sub = push.subs[id], sub.installID == installationID else { return false }
        push.removeSub(id)
        return true
    }

    public func subscriptions(installationID: String) async throws -> [PushSubscription] {
        push.subs.values.filter { $0.installID == installationID }.sorted { $0.createdAt == $1.createdAt ? $0.value.id < $1.value.id : $0.createdAt < $1.createdAt }
            .map(\.value)
    }

    public func installation(id: String) async throws -> PushInstallation? {
        push.installs[id].map { PushInstallation(token: $0.token, env: $0.env, locale: $0.locale) }
    }

    public func evaluationSubscriptions(gridVersion: Int) async throws -> [PushSubscription] {
        push.subs.values.map(\.value).filter { $0.enabled && $0.gridVersion == gridVersion }.sorted { $0.id < $1.id }
    }

    public func lastEvaluatedRun() async throws -> String? { push.lastRun }

    public func commitEvaluation(runID: String, updates: [SubscriptionUpdate], outbox: [NewOutboxItem], now: Date) async throws -> Bool {
        if let last = push.lastRun, last >= runID { return false }
        push.lastRun = runID
        for update in updates {
            guard var sub = push.subs[update.id] else { continue }
            sub.value.state = update.state
            sub.value.lastSentAt = update.lastSentAt
            push.subs[update.id] = sub
        }
        for item in outbox where push.subs[item.subID] != nil && !push.outbox.values.contains(where: { $0.dedupeKey == item.dedupeKey }) {
            let id = push.nextOutboxID
            push.nextOutboxID += 1
            push.outbox[id] = .init(id: id, subID: item.subID, dedupeKey: item.dedupeKey, collapseID: item.collapseID,
                                    payload: item.payloadJSON, expiresAt: item.expiresAt, attempts: 0, nextAttemptAt: now,
                                    status: "pending", finishedAt: nil)
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
