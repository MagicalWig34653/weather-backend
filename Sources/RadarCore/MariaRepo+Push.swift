import Foundation
import MySQLKit

extension MariaRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"

    private static func subscription(_ row: MySQLRow) -> PushSubscription {
        PushSubscription(
            id: row.column("id")?.string ?? "", gridVersion: row.column("grid_version")?.int ?? 0,
            cellX: row.column("cell_x")?.int ?? 0, cellY: row.column("cell_y")?.int ?? 0,
            threshold: row.column("threshold")?.int ?? 0, leadMinutes: row.column("lead_min")?.int ?? 0,
            enabled: (row.column("enabled")?.int ?? 0) == 1, state: PushState(rawValue: row.column("state")?.int ?? 0) ?? .dry,
            lastSentAt: row.column("last_sent_s")?.string.flatMap { TimeUtil.fromSQL($0) })
    }

    private static let subColumns = "id, grid_version, cell_x, cell_y, threshold, lead_min, enabled, state, "
        + "DATE_FORMAT(last_sent_at, \(dateOut)) AS last_sent_s"

    public func upsertInstallation(id: String, secretHash: String, token: String, env: PushEnvironment, locale: String, now: Date) async throws -> UpsertResult {
        try await transaction { conn in
            let inserted = try await query(conn,
                "INSERT IGNORE INTO push_install (id, secret_hash, token, env, locale, created_at, last_seen_at, token_updated_at) "
                + "VALUES (?,?,?,?,?,?,?,?)",
                [str(id), str(secretHash), str(token), str(env.rawValue), str(locale), ts(now), ts(now), ts(now)])
            if inserted.affected == 1 { return .created }
            let current = try await query(conn, "SELECT secret_hash FROM push_install WHERE id=? FOR UPDATE", [str(id)])
            guard current.rows.first?.column("secret_hash")?.string == secretHash else { return .forbidden }
            _ = try await query(conn,
                "UPDATE push_install SET token=?, env=?, locale=?, last_seen_at=?, token_updated_at=? WHERE id=?",
                [str(token), str(env.rawValue), str(locale), ts(now), ts(now), str(id)])
            return .updated
        }
    }

    public func authenticate(id: String, secretHash: String, now: Date) async throws -> Bool {
        try await connection { conn in
            _ = try await query(conn, "UPDATE push_install SET last_seen_at=? WHERE id=? AND secret_hash=?", [ts(now), str(id), str(secretHash)])
            return !(try await query(conn, "SELECT 1 AS ok FROM push_install WHERE id=? AND secret_hash=?", [str(id), str(secretHash)])).rows.isEmpty
        }
    }

    public func deleteInstallation(id: String) async throws {
        try await connection { conn in _ = try await query(conn, "DELETE FROM push_install WHERE id=?", [str(id)]) }
    }

    public func addSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, maxPerInstallation: Int, now: Date) async throws -> AddSubscriptionResult {
        try await transaction { conn in
            // The installation row lock serializes concurrent additions, so the limit cannot be exceeded.
            guard !(try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(installationID)])).rows.isEmpty else {
                return .unknownInstallation
            }
            let count = try await query(conn, "SELECT COUNT(*) AS n FROM push_sub WHERE install_id=?", [str(installationID)])
            guard (count.rows.first?.column("n")?.int ?? 0) < maxPerInstallation else { return .limitReached }
            _ = try await query(conn,
                "INSERT INTO push_sub (id, install_id, grid_version, cell_x, cell_y, threshold, lead_min, enabled, state, created_at) "
                + "VALUES (?,?,?,?,?,?,?,?,0,?)",
                [str(id), str(installationID), MySQLData(int: input.gridVersion), MySQLData(int: input.cellX), MySQLData(int: input.cellY),
                 MySQLData(int: input.threshold), MySQLData(int: input.leadMinutes), MySQLData(int: input.enabled ? 1 : 0), ts(now)])
            return .created
        }
    }

    public func updateSubscription(installationID: String, id: String, _ input: PushSubscriptionInput) async throws -> Bool {
        try await connection { conn in
            _ = try await query(conn,
                "UPDATE push_sub SET grid_version=?, cell_x=?, cell_y=?, threshold=?, lead_min=?, enabled=?, state=0 WHERE id=? AND install_id=?",
                [MySQLData(int: input.gridVersion), MySQLData(int: input.cellX), MySQLData(int: input.cellY), MySQLData(int: input.threshold),
                 MySQLData(int: input.leadMinutes), MySQLData(int: input.enabled ? 1 : 0), str(id), str(installationID)])
            return !(try await query(conn, "SELECT 1 AS ok FROM push_sub WHERE id=? AND install_id=?", [str(id), str(installationID)])).rows.isEmpty
        }
    }

    public func deleteSubscription(installationID: String, id: String) async throws -> Bool {
        try await connection { conn in
            try await query(conn, "DELETE FROM push_sub WHERE id=? AND install_id=?", [str(id), str(installationID)]).affected >= 1
        }
    }

    public func subscriptions(installationID: String) async throws -> [PushSubscription] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.subColumns) FROM push_sub WHERE install_id=? ORDER BY created_at, id", [str(installationID)])
                .rows.map(Self.subscription)
        }
    }

    public func evaluationSubscriptions(gridVersion: Int) async throws -> [PushSubscription] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.subColumns) FROM push_sub WHERE enabled=1 AND grid_version=? ORDER BY id",
                            [MySQLData(int: gridVersion)]).rows.map(Self.subscription)
        }
    }

    public func lastEvaluatedRun() async throws -> String? {
        try await connection { conn in
            try await query(conn, "SELECT value FROM push_state WHERE name='last_run'").rows.first?.column("value")?.string
        }
    }

    public func commitEvaluation(runID: String, updates: [SubscriptionUpdate], outbox: [NewOutboxItem], now: Date) async throws -> Bool {
        try await transaction { conn in
            _ = try await query(conn, "INSERT IGNORE INTO push_state (name, value) VALUES ('last_run', '')")
            let last = try await query(conn, "SELECT value FROM push_state WHERE name='last_run' FOR UPDATE").rows.first?.column("value")?.string ?? ""
            guard last < runID else { return false }
            _ = try await query(conn, "UPDATE push_state SET value=? WHERE name='last_run'", [str(runID)])
            for update in updates {
                _ = try await query(conn, "UPDATE push_sub SET state=?, last_sent_at=? WHERE id=?",
                                    [MySQLData(int: update.state.rawValue), update.lastSentAt.map { ts($0) } ?? .null, str(update.id)])
            }
            for item in outbox {
                // INSERT ... SELECT skips subscriptions that were deleted meanwhile; the unique key ignores duplicates.
                _ = try await query(conn,
                    "INSERT IGNORE INTO push_outbox (sub_id, dedupe_key, collapse_id, payload_json, expires_at, next_attempt_at, created_at) "
                    + "SELECT id, ?, ?, ?, ?, ?, ? FROM push_sub WHERE id=?",
                    [str(item.dedupeKey), str(item.collapseID), str(item.payloadJSON), ts(item.expiresAt), ts(now), ts(now), str(item.subID)])
            }
            return true
        }
    }

    public func dueOutbox(now: Date, limit: Int) async throws -> [OutboxItem] {
        try await connection { conn in
            try await query(conn,
                "SELECT o.id, i.token, i.env, o.collapse_id, o.payload_json, DATE_FORMAT(o.expires_at, \(Self.dateOut)) AS expires_s, o.attempts "
                + "FROM push_outbox o JOIN push_sub s ON s.id = o.sub_id JOIN push_install i ON i.id = s.install_id "
                + "WHERE o.status='pending' AND o.next_attempt_at <= ? ORDER BY o.id LIMIT \(max(1, limit))", [ts(now)]).rows.compactMap { row in
                guard let id = row.column("id")?.int, let token = row.column("token")?.string,
                      let env = row.column("env")?.string.flatMap(PushEnvironment.init(rawValue:)) else { return nil }
                return OutboxItem(id: id, token: token, env: env, collapseID: row.column("collapse_id")?.string ?? "",
                                  payloadJSON: row.column("payload_json")?.string ?? "", expiresAt: Self.time(row, "expires_s"),
                                  attempts: row.column("attempts")?.int ?? 0)
            }
        }
    }

    public func finishOutbox(id: Int, _ outcome: OutboxOutcome, now: Date) async throws {
        try await connection { conn in
            switch outcome {
            case .sent:
                _ = try await query(conn, "UPDATE push_outbox SET status='sent', finished_at=? WHERE id=?", [ts(now), MySQLData(int: id)])
            case .dropped:
                _ = try await query(conn, "UPDATE push_outbox SET status='dropped', finished_at=? WHERE id=?", [ts(now), MySQLData(int: id)])
            case .retry(let attempts, let at):
                _ = try await query(conn, "UPDATE push_outbox SET attempts=?, next_attempt_at=? WHERE id=?",
                                    [MySQLData(int: attempts), ts(at), MySQLData(int: id)])
            }
        }
    }

    public func deleteInstallations(token: String, env: PushEnvironment) async throws -> Int {
        try await connection { conn in
            Int(try await query(conn, "DELETE FROM push_install WHERE token=? AND env=?", [str(token), str(env.rawValue)]).affected)
        }
    }

    public func purgePush(inactiveBefore: Date, outboxBefore: Date, now: Date) async throws -> PushPurgeResult {
        try await connection { conn in
            let installs = try await query(conn, "DELETE FROM push_install WHERE last_seen_at < ?", [ts(inactiveBefore)]).affected
            let outbox = try await query(conn,
                "DELETE FROM push_outbox WHERE (status<>'pending' AND finished_at < ?) OR (status='pending' AND expires_at < ?)",
                [ts(outboxBefore), ts(outboxBefore)]).affected
            return PushPurgeResult(installations: Int(installs), outbox: Int(outbox))
        }
    }
}
