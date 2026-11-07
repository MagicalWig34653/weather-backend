import Foundation
import MySQLKit

extension MariaRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private func int(_ value: Int) -> MySQLData { MySQLData(int: value) }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"
    private static let typeBits: [WarnKind: Int] = [.severeWeather: 1, .frost: 2, .ice: 4]

    private func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }

    private func mask(_ types: Set<WarnKind>) -> Int { types.reduce(0) { $0 | (Self.typeBits[$1] ?? 0) } }

    private func severity(_ input: WarnSubscriptionInput, _ kind: WarnKind) -> Int {
        input.minSeverity[kind] ?? WarnEvaluator.defaultMinSeverity[kind] ?? 1
    }

    /// First id that is not in the known list; nil while the list is not seeded far enough (check disabled).
    private func firstUnknown(_ conn: MySQLConnection, _ ids: [String]) async throws -> String? {
        let known = try await query(conn, "SELECT COUNT(*) AS n FROM warn_cell_known").rows.first?.column("n")?.int ?? 0
        guard known >= WarnCellCatalog.minimumSeed, !ids.isEmpty else { return nil }
        let found = Set(try await query(conn, "SELECT warncell_id FROM warn_cell_known WHERE warncell_id IN (\(placeholders(ids.count)))", ids.map(str))
            .rows.compactMap { $0.column("warncell_id")?.string })
        return ids.first { !found.contains($0) }
    }

    private func storeDetails(_ conn: MySQLConnection, id: String, _ input: WarnSubscriptionInput) async throws {
        _ = try await query(conn, "DELETE FROM warn_sub_cell WHERE sub_id=?", [str(id)])
        _ = try await query(conn,
            "INSERT INTO warn_sub (sub_id, types_mask, min_sev_weather, min_sev_frost, min_sev_ice, time_sensitive) VALUES (?,?,?,?,?,?) "
            + "ON DUPLICATE KEY UPDATE types_mask=VALUES(types_mask), min_sev_weather=VALUES(min_sev_weather), min_sev_frost=VALUES(min_sev_frost), "
            + "min_sev_ice=VALUES(min_sev_ice), time_sensitive=VALUES(time_sensitive)",
            [str(id), int(mask(input.types)), int(severity(input, .severeWeather)), int(severity(input, .frost)), int(severity(input, .ice)),
             int(input.timeSensitive ? 1 : 0)])
        for chunk in stride(from: 0, to: input.warncellIDs.count, by: 100).map({ Array(input.warncellIDs[$0..<min($0 + 100, input.warncellIDs.count)]) }) {
            _ = try await query(conn, "INSERT IGNORE INTO warn_sub_cell (sub_id, warncell_id) VALUES " + Array(repeating: "(?,?)", count: chunk.count).joined(separator: ","),
                                chunk.flatMap { [str(id), str($0)] })
        }
    }

    private func cellCount(_ conn: MySQLConnection, installationID: String, excluding id: String) async throws -> Int {
        try await query(conn, "SELECT COUNT(*) AS n FROM warn_sub_cell c JOIN push_sub s ON s.id=c.sub_id WHERE s.install_id=? AND s.id<>?",
                        [str(installationID), str(id)]).rows.first?.column("n")?.int ?? 0
    }

    public func addWarnSubscription(installationID: String, id: String, _ input: WarnSubscriptionInput, now: Date) async throws -> WarnAddResult {
        try await transaction { conn in
            guard !(try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(installationID)])).rows.isEmpty else { return .unknownInstallation }
            let count = try await query(conn, "SELECT COUNT(*) AS n FROM push_sub WHERE install_id=? AND kind=2", [str(installationID)]).rows.first?.column("n")?.int ?? 0
            guard count < WarnLimits.maxSubscriptionsPerInstallation,
                  try await cellCount(conn, installationID: installationID, excluding: id) + input.warncellIDs.count <= WarnLimits.maxCellsPerInstallation else { return .limit }
            if let bad = try await firstUnknown(conn, input.warncellIDs) { return .unknownCell(bad) }
            _ = try await query(conn,
                "INSERT INTO push_sub (id, install_id, grid_version, cell_x, cell_y, threshold, lead_min, enabled, state, time_sensitive, live_activity, kind, radius_cells, min_share, created_at) "
                + "VALUES (?,?,1,0,0,1,10,?,0,?,0,2,NULL,NULL,?)",
                [str(id), str(installationID), int(input.enabled ? 1 : 0), int(input.timeSensitive ? 1 : 0), ts(now)])
            try await storeDetails(conn, id: id, input)
            return .added
        }
    }

    public func updateWarnSubscription(installationID: String, id: String, _ input: WarnSubscriptionInput) async throws -> WarnUpdateResult {
        try await transaction { conn in
            guard !(try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(installationID)])).rows.isEmpty,
                  !(try await query(conn, "SELECT 1 AS ok FROM push_sub WHERE id=? AND install_id=? AND kind=2", [str(id), str(installationID)])).rows.isEmpty
            else { return .notFound }
            guard try await cellCount(conn, installationID: installationID, excluding: id) + input.warncellIDs.count <= WarnLimits.maxCellsPerInstallation else { return .limit }
            if let bad = try await firstUnknown(conn, input.warncellIDs) { return .unknownCell(bad) }
            _ = try await query(conn, "UPDATE push_sub SET enabled=?, time_sensitive=?, changed_at=UTC_TIMESTAMP() WHERE id=? AND install_id=? AND kind=2",
                                [int(input.enabled ? 1 : 0), int(input.timeSensitive ? 1 : 0), str(id), str(installationID)])
            try await storeDetails(conn, id: id, input)
            return .updated
        }
    }

    public func deleteWarnSubscription(installationID: String, id: String) async throws -> Bool {
        try await connection { conn in
            try await query(conn, "DELETE FROM push_sub WHERE id=? AND install_id=? AND kind=2", [str(id), str(installationID)]).affected >= 1
        }
    }

    private func subscriptions(_ conn: MySQLConnection, where clause: String, _ binds: [MySQLData]) async throws -> [WarnSubscription] {
        let rows = try await query(conn,
            "SELECT s.id, s.install_id, s.enabled, w.types_mask, w.min_sev_weather, w.min_sev_frost, w.min_sev_ice, w.time_sensitive "
            + "FROM push_sub s JOIN warn_sub w ON w.sub_id = s.id WHERE s.kind=2 AND \(clause) ORDER BY s.created_at, s.id", binds).rows
        guard !rows.isEmpty else { return [] }
        var cells: [String: [String]] = [:]
        let ids = rows.compactMap { $0.column("id")?.string }
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            for r in try await query(conn, "SELECT sub_id, warncell_id FROM warn_sub_cell WHERE sub_id IN (\(placeholders(chunk.count))) ORDER BY sub_id, warncell_id",
                                     chunk.map(str)).rows {
                cells[r.column("sub_id")?.string ?? "", default: []].append(r.column("warncell_id")?.string ?? "")
            }
        }
        return rows.map { r in
            let id = r.column("id")?.string ?? ""
            let bits = r.column("types_mask")?.int ?? 0
            let types = Set(WarnKind.allCases.filter { bits & (Self.typeBits[$0] ?? 0) != 0 })
            return WarnSubscription(id: id, installationID: r.column("install_id")?.string ?? "", input: WarnSubscriptionInput(
                warncellIDs: cells[id] ?? [], types: types,
                minSeverity: [.severeWeather: r.column("min_sev_weather")?.int ?? 3, .frost: r.column("min_sev_frost")?.int ?? 1, .ice: r.column("min_sev_ice")?.int ?? 2],
                enabled: (r.column("enabled")?.int ?? 0) == 1, timeSensitive: (r.column("time_sensitive")?.int ?? 0) == 1))
        }
    }

    public func warnSubscriptions(installationID: String) async throws -> [WarnSubscription] {
        try await connection { conn in try await subscriptions(conn, where: "s.install_id=?", [str(installationID)]) }
    }

    public func warnSubscriptions(matching warncellIDs: [String]) async throws -> [WarnSubscription] {
        let ids = Array(Set(warncellIDs)).sorted()
        guard !ids.isEmpty else { return [] }
        return try await connection { conn in
            var found: [String: WarnSubscription] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let subIDs = try await query(conn, "SELECT DISTINCT c.sub_id FROM warn_sub_cell c JOIN push_sub s ON s.id=c.sub_id WHERE s.enabled=1 AND s.kind=2 "
                    + "AND c.warncell_id IN (\(placeholders(chunk.count)))", chunk.map(str)).rows.compactMap { $0.column("sub_id")?.string }
                for group in stride(from: 0, to: subIDs.count, by: 500).map({ Array(subIDs[$0..<min($0 + 500, subIDs.count)]) }) {
                    for sub in try await subscriptions(conn, where: "s.id IN (\(placeholders(group.count)))", group.map(str)) { found[sub.id] = sub }
                }
            }
            return found.values.sorted { $0.id < $1.id }
        }
    }

    public func warnSent(subID: String) async throws -> [WarnSentRecord] {
        try await connection { conn in
            try await query(conn, "SELECT chain_id, kind, last_severity, DATE_FORMAT(last_onset, \(Self.dateOut)) AS onset_s, DATE_FORMAT(last_sent_at, \(Self.dateOut)) AS sent_s "
                + "FROM warn_sent WHERE sub_id=? ORDER BY chain_id", [str(subID)]).rows.map { r in
                WarnSentRecord(chainID: r.column("chain_id")?.string ?? "", kind: WarnKind(rawValue: r.column("kind")?.string ?? "") ?? .severeWeather,
                               lastSeverity: r.column("last_severity")?.int ?? 1, lastOnset: Self.time(r, "onset_s"), lastSentAt: Self.time(r, "sent_s"))
            }
        }
    }

    public func commitWarnSend(_ items: [WarnSendItem], now: Date) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        return try await transaction { conn in
            var added = 0
            for item in items {
                // INSERT ... SELECT skips subscriptions deleted meanwhile; the unique dedupe key ignores duplicates.
                let inserted = try await query(conn,
                    "INSERT IGNORE INTO push_outbox (sub_id, dedupe_key, collapse_id, payload_json, expires_at, next_attempt_at, created_at) "
                    + "SELECT id, ?, ?, ?, ?, ?, ? FROM push_sub WHERE id=? AND kind=2",
                    [str(item.outbox.dedupeKey), str(item.outbox.collapseID), str(item.outbox.payloadJSON), ts(item.outbox.expiresAt), ts(now), ts(now), str(item.subID)])
                guard inserted.affected == 1 else { continue }
                added += 1
                _ = try await query(conn,
                    "INSERT INTO warn_sent (sub_id, chain_id, kind, last_severity, last_onset, last_sent_at) VALUES (?,?,?,?,?,?) "
                    + "ON DUPLICATE KEY UPDATE kind=VALUES(kind), last_severity=VALUES(last_severity), last_onset=VALUES(last_onset), last_sent_at=VALUES(last_sent_at)",
                    [str(item.subID), str(item.record.chainID), str(item.record.kind.rawValue), int(item.record.lastSeverity), ts(item.record.lastOnset), ts(item.record.lastSentAt)])
            }
            return added
        }
    }

    public func seedKnownWarnCells(_ ids: [String]) async throws {
        try await connection { conn in
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                _ = try await query(conn, "INSERT IGNORE INTO warn_cell_known (warncell_id) VALUES " + Array(repeating: "(?)", count: chunk.count).joined(separator: ","), chunk.map(str))
            }
        }
    }

    @discardableResult
    public func purgeWarnSent(before: Date) async throws -> Int {
        try await connection { conn in Int(try await query(conn, "DELETE FROM warn_sent WHERE last_sent_at < ?", [ts(before)]).affected) }
    }
}
