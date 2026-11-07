import Foundation

/// In-memory warning storage with the same semantics as the `warn_*` tables (state lives inside `MemoryRepo`).
struct MemoryWarnStore {
    struct Row {
        var alert: WarnAlert
        var chainID: String
        var status: String
        var updatedAt: Date
    }
    var rows: [String: Row] = [:]   // key: identifier (language is part of the CAP identifier suffix; lang stored in the alert)
    var fetchedAt: Date?
    // Warning subscriptions (their push_sub row lives in `push.subs` with kind .warning), sent-state per sub and chain, known cell ids.
    var subs: [String: WarnSubscriptionInput] = [:]
    var sent: [String: [String: WarnSentRecord]] = [:]
    var known: Set<String> = []

    func rowKey(_ alert: WarnAlert) -> String { alert.lang + "|" + alert.identifier }
}

extension MemoryRepo {
    public func upsertAlert(_ input: WarnAlert, now: Date) async throws -> WarnStoredAlert {
        let alert = input.clippedForStorage()
        if alert.msgType == .cancel {
            try await cancelAlerts(identifiers: alert.references, now: now)
            return WarnStoredAlert(alert: alert, chainID: alert.alertKey, status: "cancelled")
        }
        let key = warn.rowKey(alert)
        let refKeys = Set(alert.references.map { WarnAlert.alertKey(identifier: $0) })
        let chain = alert.references.lazy.compactMap { ref in
            self.warn.rows.values.first { $0.alert.alertKey == WarnAlert.alertKey(identifier: ref) }?.chainID
        }.first ?? alert.alertKey
        var status = "active"
        if let existing = warn.rows[key] { status = existing.status }
        else if warn.rows.values.contains(where: { $0.chainID == chain && $0.alert.alertKey != alert.alertKey && $0.alert.sent > alert.sent }) {
            status = "superseded"
        }
        warn.rows[key] = .init(alert: alert, chainID: chain, status: status, updatedAt: now)
        for (k, var row) in warn.rows where row.status == "active" && refKeys.contains(row.alert.alertKey) && row.alert.alertKey != alert.alertKey {
            row.status = "superseded"; row.updatedAt = now; warn.rows[k] = row
        }
        return WarnStoredAlert(alert: alert, chainID: chain, status: status)
    }

    public func cancelAlerts(identifiers: [String], now: Date) async throws {
        let keys = Set(identifiers.map { WarnAlert.alertKey(identifier: $0) })
        for (k, var row) in warn.rows where keys.contains(row.alert.alertKey) && row.status != "cancelled" {
            row.status = "cancelled"; row.updatedAt = now; warn.rows[k] = row
        }
    }

    public func activeAlerts(now: Date, lang: String) async throws -> [WarnStoredAlert] {
        var best: [String: MemoryWarnStore.Row] = [:]
        for row in warn.rows.values where row.status == "active" && row.alert.expires > now {
            let k = row.alert.alertKey
            if let current = best[k] {
                if row.alert.lang == lang && current.alert.lang != lang { best[k] = row }
                else if current.alert.lang != lang && row.alert.lang != lang && row.alert.lang == "de" { best[k] = row }
            } else { best[k] = row }
        }
        return best.values.sorted { ($0.alert.sent, $0.alert.identifier) < ($1.alert.sent, $1.alert.identifier) }
            .map { WarnStoredAlert(alert: $0.alert, chainID: $0.chainID, status: $0.status) }
    }

    public func alert(identifier: String) async throws -> WarnStoredAlert? {
        warn.rows.values.first { $0.alert.identifier == identifier }.map { WarnStoredAlert(alert: $0.alert, chainID: $0.chainID, status: $0.status) }
    }

    @discardableResult
    public func purgeWarnings(now: Date, retention: TimeInterval) async throws -> Int {
        let cutoff = now.addingTimeInterval(-retention)
        let drop = warn.rows.filter { $0.value.alert.expires <= cutoff || ($0.value.status != "active" && $0.value.updatedAt <= cutoff) }.keys
        for k in drop { warn.rows[k] = nil }
        return drop.count
    }

    public func setWarnFetchedAt(_ date: Date) async throws { warn.fetchedAt = date }
    public func warnFetchedAt() async throws -> Date? { warn.fetchedAt }
}
