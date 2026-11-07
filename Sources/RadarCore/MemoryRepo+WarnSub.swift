import Foundation

extension MemoryRepo {
    private func ownWarnSubs(_ installationID: String) -> [String] {
        push.subs.filter { $0.value.installID == installationID && $0.value.value.kind == .warning }.map(\.key)
    }

    private func unknownCell(_ ids: [String]) -> String? {
        guard warn.known.count >= WarnCellCatalog.minimumSeed else { return nil }
        return ids.first { !warn.known.contains($0) }
    }

    private func cellCount(_ installationID: String, excluding id: String?) -> Int {
        ownWarnSubs(installationID).filter { $0 != id }.reduce(0) { $0 + (warn.subs[$1]?.warncellIDs.count ?? 0) }
    }

    public func addWarnSubscription(installationID: String, id: String, _ input: WarnSubscriptionInput, now: Date) async throws -> WarnAddResult {
        guard push.installs[installationID] != nil else { return .unknownInstallation }
        guard ownWarnSubs(installationID).count < WarnLimits.maxSubscriptionsPerInstallation,
              cellCount(installationID, excluding: nil) + input.warncellIDs.count <= WarnLimits.maxCellsPerInstallation else { return .limit }
        if let bad = unknownCell(input.warncellIDs) { return .unknownCell(bad) }
        push.subs[id] = .init(installID: installationID, value: PushSubscription(
            id: id, gridVersion: 1, cellX: 0, cellY: 0, threshold: 1, leadMinutes: 10, enabled: input.enabled,
            timeSensitive: input.timeSensitive, kind: .warning), createdAt: now)
        push.subs[id]?.value.createdAt = now
        warn.subs[id] = input
        return .added
    }

    public func updateWarnSubscription(installationID: String, id: String, _ input: WarnSubscriptionInput) async throws -> WarnUpdateResult {
        guard let sub = push.subs[id], sub.installID == installationID, sub.value.kind == .warning else { return .notFound }
        guard cellCount(installationID, excluding: id) + input.warncellIDs.count <= WarnLimits.maxCellsPerInstallation else { return .limit }
        if let bad = unknownCell(input.warncellIDs) { return .unknownCell(bad) }
        push.subs[id]?.value.enabled = input.enabled
        push.subs[id]?.value.timeSensitive = input.timeSensitive
        warn.subs[id] = input
        return .updated
    }

    public func deleteWarnSubscription(installationID: String, id: String) async throws -> Bool {
        guard let sub = push.subs[id], sub.installID == installationID, sub.value.kind == .warning else { return false }
        push.removeSub(id)
        warn.subs[id] = nil
        warn.sent[id] = nil
        return true
    }

    private func warnSub(_ id: String) -> WarnSubscription? {
        guard let sub = push.subs[id], sub.value.kind == .warning, let input = warn.subs[id] else { return nil }
        return WarnSubscription(id: id, installationID: sub.installID, input: input)
    }

    public func warnSubscriptions(installationID: String) async throws -> [WarnSubscription] {
        ownWarnSubs(installationID).compactMap { push.subs[$0] }.sorted { ($0.createdAt, $0.value.id) < ($1.createdAt, $1.value.id) }
            .compactMap { warnSub($0.value.id) }
    }

    public func warnSubscriptions(matching warncellIDs: [String]) async throws -> [WarnSubscription] {
        let wanted = Set(warncellIDs)
        return warn.subs.keys.sorted().compactMap { warnSub($0) }
            .filter { $0.input.enabled && !wanted.isDisjoint(with: $0.input.warncellIDs) }
    }

    public func warnSent(subID: String) async throws -> [WarnSentRecord] {
        guard push.subs[subID] != nil else { return [] }
        return (warn.sent[subID] ?? [:]).values.sorted { $0.chainID < $1.chainID }
    }

    public func commitWarnSend(_ items: [WarnSendItem], now: Date) async throws -> Int {
        var added = 0
        for item in items {
            guard push.subs[item.subID] != nil, !push.outbox.values.contains(where: { $0.dedupeKey == item.outbox.dedupeKey }) else { continue }
            let id = push.nextOutboxID
            push.nextOutboxID += 1
            push.outbox[id] = .init(id: id, subID: item.subID, dedupeKey: item.outbox.dedupeKey, collapseID: item.outbox.collapseID,
                                    payload: item.outbox.payloadJSON, expiresAt: item.outbox.expiresAt, attempts: 0, nextAttemptAt: now,
                                    status: "pending", finishedAt: nil, createdAt: now)
            warn.sent[item.subID, default: [:]][item.record.chainID] = item.record
            added += 1
        }
        return added
    }

    public func seedKnownWarnCells(_ ids: [String]) async throws { warn.known.formUnion(ids) }

    @discardableResult
    public func purgeWarnSent(before: Date) async throws -> Int {
        var removed = 0
        for (sub, chains) in warn.sent {
            let keep = chains.filter { $0.value.lastSentAt >= before }
            removed += chains.count - keep.count
            warn.sent[sub] = keep
        }
        return removed
    }
}
