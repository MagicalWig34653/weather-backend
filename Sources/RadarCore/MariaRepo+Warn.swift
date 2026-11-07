import Foundation
import MySQLKit

extension MariaRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"
    private static let columns = "identifier, lang, alert_key, chain_id, kind, severity, event, status, headline, body, instruction, "
        + "DATE_FORMAT(sent, \(dateOut)) AS sent_s, DATE_FORMAT(onset, \(dateOut)) AS onset_s, DATE_FORMAT(expires, \(dateOut)) AS expires_s"

    private func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }

    private func stored(_ row: MySQLRow, cells: [String]) -> WarnStoredAlert {
        let t = { (c: String) in TimeUtil.fromSQL(row.column(c)?.string ?? "") ?? Date(timeIntervalSince1970: 0) }
        let alert = WarnAlert(
            identifier: row.column("identifier")?.string ?? "", kind: WarnKind(rawValue: row.column("kind")?.string ?? "") ?? .severeWeather,
            severity: row.column("severity")?.int ?? 1, event: row.column("event")?.string ?? "", msgType: .alert, references: [],
            sent: t("sent_s"), onset: t("onset_s"), expires: t("expires_s"), headline: row.column("headline")?.string ?? "",
            text: row.column("body")?.string ?? "", instruction: row.column("instruction")?.string ?? "",
            lang: row.column("lang")?.string ?? "de", warncellIDs: cells)
        return WarnStoredAlert(alert: alert, chainID: row.column("chain_id")?.string ?? "", status: row.column("status")?.string ?? "active")
    }

    private func cells(_ conn: MySQLConnection, identifiers: [String]) async throws -> [String: [String]] {
        guard !identifiers.isEmpty else { return [:] }
        var out: [String: [String]] = [:]
        for chunk in stride(from: 0, to: identifiers.count, by: 500).map({ Array(identifiers[$0..<min($0 + 500, identifiers.count)]) }) {
            let rows = try await query(conn, "SELECT identifier, warncell_id FROM warn_alert_cell WHERE identifier IN (\(placeholders(chunk.count))) "
                + "ORDER BY identifier, warncell_id", chunk.map(str)).rows
            for r in rows { out[r.column("identifier")?.string ?? "", default: []].append(r.column("warncell_id")?.string ?? "") }
        }
        return out
    }

    private func cancel(_ conn: MySQLConnection, keys: [String], now: Date) async throws {
        guard !keys.isEmpty else { return }
        _ = try await query(conn, "UPDATE warn_alert SET status='cancelled', updated_at=? WHERE alert_key IN (\(placeholders(keys.count))) AND status<>'cancelled'",
                            [ts(now)] + keys.map(str))
    }

    public func upsertAlert(_ input: WarnAlert, now: Date) async throws -> WarnStoredAlert {
        let alert = input.clippedForStorage()
        let refKeys = Array(Set(alert.references.map { WarnAlert.alertKey(identifier: $0) })).sorted()
        if alert.msgType == .cancel {
            try await transaction { conn in try await cancel(conn, keys: refKeys, now: now) }
            return WarnStoredAlert(alert: alert, chainID: alert.alertKey, status: "cancelled")
        }
        return try await transaction { conn in
            var chain = alert.alertKey
            for ref in alert.references {
                let hit = try await query(conn, "SELECT chain_id FROM warn_alert WHERE alert_key=? LIMIT 1", [str(WarnAlert.alertKey(identifier: ref))]).rows.first
                if let id = hit?.column("chain_id")?.string { chain = id; break }
            }
            let existing = try await query(conn, "SELECT status FROM warn_alert WHERE identifier=? AND lang=? FOR UPDATE", [str(alert.identifier), str(alert.lang)]).rows.first
            var status = existing?.column("status")?.string ?? "active"
            if existing == nil {
                let newer = try await query(conn, "SELECT 1 AS n FROM warn_alert WHERE chain_id=? AND alert_key<>? AND sent>? LIMIT 1",
                                            [str(chain), str(alert.alertKey), ts(alert.sent)]).rows
                if !newer.isEmpty { status = "superseded" }
            }
            _ = try await query(conn,
                "INSERT INTO warn_alert (identifier, lang, alert_key, chain_id, kind, severity, event, sent, onset, expires, headline, body, instruction, status, updated_at) "
                + "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE chain_id=VALUES(chain_id), kind=VALUES(kind), severity=VALUES(severity), "
                + "event=VALUES(event), sent=VALUES(sent), onset=VALUES(onset), expires=VALUES(expires), headline=VALUES(headline), body=VALUES(body), "
                + "instruction=VALUES(instruction), updated_at=VALUES(updated_at)",
                [str(alert.identifier), str(alert.lang), str(alert.alertKey), str(chain), str(alert.kind.rawValue), MySQLData(int: alert.severity),
                 str(alert.event), ts(alert.sent), ts(alert.onset), ts(alert.expires), str(alert.headline), str(alert.text),
                 str(alert.instruction), str(status), ts(now)])
            _ = try await query(conn, "DELETE FROM warn_alert_cell WHERE identifier=?", [str(alert.identifier)])
            for chunk in stride(from: 0, to: alert.warncellIDs.count, by: 500).map({ Array(alert.warncellIDs[$0..<min($0 + 500, alert.warncellIDs.count)]) }) {
                _ = try await query(conn, "INSERT IGNORE INTO warn_alert_cell (identifier, warncell_id) VALUES "
                    + Array(repeating: "(?,?)", count: chunk.count).joined(separator: ","),
                    chunk.flatMap { [str(alert.identifier), str($0)] })
            }
            let others = refKeys.filter { $0 != alert.alertKey }
            if !others.isEmpty {
                _ = try await query(conn, "UPDATE warn_alert SET status='superseded', updated_at=? WHERE alert_key IN (\(placeholders(others.count))) AND status='active'",
                                    [ts(now)] + others.map(str))
            }
            return WarnStoredAlert(alert: alert, chainID: chain, status: status)
        }
    }

    public func cancelAlerts(identifiers: [String], now: Date) async throws {
        let keys = Array(Set(identifiers.map { WarnAlert.alertKey(identifier: $0) })).sorted()
        try await transaction { conn in try await cancel(conn, keys: keys, now: now) }
    }

    public func activeAlerts(now: Date, lang: String) async throws -> [WarnStoredAlert] {
        try await connection { conn in
            let rows = try await query(conn, "SELECT \(Self.columns) FROM warn_alert WHERE status='active' AND expires>? ORDER BY sent, identifier", [ts(now)]).rows
            let cellMap = try await cells(conn, identifiers: rows.compactMap { $0.column("identifier")?.string })
            var best: [String: WarnStoredAlert] = [:]
            var order: [String] = []
            for row in rows {
                let item = stored(row, cells: cellMap[row.column("identifier")?.string ?? ""] ?? [])
                let key = item.alert.alertKey
                if let current = best[key] {
                    if item.alert.lang == lang && current.alert.lang != lang { best[key] = item }
                    else if current.alert.lang != lang && item.alert.lang != lang && item.alert.lang == "de" { best[key] = item }
                } else { best[key] = item; order.append(key) }
            }
            return order.compactMap { best[$0] }
        }
    }

    public func alert(identifier: String) async throws -> WarnStoredAlert? {
        try await connection { conn in
            guard let row = try await query(conn, "SELECT \(Self.columns) FROM warn_alert WHERE identifier=? LIMIT 1", [str(identifier)]).rows.first else { return nil }
            let cellMap = try await cells(conn, identifiers: [identifier])
            return stored(row, cells: cellMap[identifier] ?? [])
        }
    }

    @discardableResult
    public func purgeWarnings(now: Date, retention: TimeInterval) async throws -> Int {
        let cutoff = ts(now.addingTimeInterval(-retention))
        return try await transaction { conn in
            _ = try await query(conn, "DELETE c FROM warn_alert_cell c JOIN warn_alert a ON a.identifier=c.identifier "
                + "WHERE a.expires<=? OR (a.status<>'active' AND a.updated_at<=?)", [cutoff, cutoff])
            return Int(try await query(conn, "DELETE FROM warn_alert WHERE expires<=? OR (status<>'active' AND updated_at<=?)", [cutoff, cutoff]).affected)
        }
    }

    public func setWarnFetchedAt(_ date: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "INSERT INTO warn_state (name, value_at) VALUES ('fetched_at', ?) ON DUPLICATE KEY UPDATE value_at=VALUES(value_at)", [ts(date)])
        }
    }

    public func warnFetchedAt() async throws -> Date? {
        try await connection { conn in
            try await query(conn, "SELECT DATE_FORMAT(value_at, \(Self.dateOut)) AS v FROM warn_state WHERE name='fetched_at'").rows.first?.column("v")?.string
                .flatMap { TimeUtil.fromSQL($0) }
        }
    }
}
