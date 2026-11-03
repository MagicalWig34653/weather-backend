import Foundation
import MySQLKit

/// Binary values travel as hex (`UNHEX(?)` / `HEX(col)`), times as UTC strings.
extension MariaRepo: DashboardRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private func hex(_ bytes: [UInt8]) -> MySQLData { MySQLData(string: DashboardValidation.hex(bytes)) }
    private func opt(_ value: String?) -> MySQLData { value.map { MySQLData(string: $0) } ?? .null }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"

    // MARK: credential

    public func insertCredential(credentialID: [UInt8], publicKey: [UInt8], signCount: Int, now: Date) async throws -> Bool {
        try await connection { conn in
            // Fixed primary key 1: the check and the insert are one statement; a parallel insert waits and then loses.
            let result = try await query(conn,
                "INSERT IGNORE INTO dashboard_credential (id, credential_id, public_key, sign_count, created_at) VALUES (1, UNHEX(?), UNHEX(?), ?, ?)",
                [hex(credentialID), hex(publicKey), MySQLData(int: signCount), ts(now)])
            return result.affected == 1
        }
    }

    public func credential() async throws -> DashboardCredential? {
        try await connection { conn in
            let rows = try await query(conn,
                "SELECT HEX(credential_id) AS cid, HEX(public_key) AS pk, sign_count, DATE_FORMAT(created_at, \(Self.dateOut)) AS created_s, "
                + "DATE_FORMAT(last_used_at, \(Self.dateOut)) AS used_s FROM dashboard_credential WHERE id=1").rows
            guard let row = rows.first else { return nil }
            return DashboardCredential(
                credentialID: DashboardValidation.bytes(hex: row.column("cid")?.string ?? ""),
                publicKey: DashboardValidation.bytes(hex: row.column("pk")?.string ?? ""),
                signCount: row.column("sign_count")?.int ?? 0, createdAt: Self.time(row, "created_s"),
                lastUsedAt: row.column("used_s")?.string.flatMap { TimeUtil.fromSQL($0) })
        }
    }

    public func updateCredentialUse(credentialID: [UInt8], signCount: Int, now: Date) async throws -> Bool {
        try await connection { conn in
            // Affected rows count changed rows; last_used_at changes whenever the second does, so compare by existence as a fallback.
            let result = try await query(conn,
                "UPDATE dashboard_credential SET sign_count=?, last_used_at=? WHERE id=1 AND credential_id=UNHEX(?)",
                [MySQLData(int: signCount), ts(now), hex(credentialID)])
            if result.affected > 0 { return true }
            return !(try await query(conn, "SELECT 1 AS ok FROM dashboard_credential WHERE id=1 AND credential_id=UNHEX(?)", [hex(credentialID)])).rows.isEmpty
        }
    }

    public func resetCredential() async throws -> Bool {
        try await transaction { conn in
            _ = try await query(conn, "DELETE FROM dashboard_session")
            _ = try await query(conn, "DELETE FROM dashboard_challenge")
            return try await query(conn, "DELETE FROM dashboard_credential").affected > 0
        }
    }

    // MARK: challenges

    public func putChallenge(id: [UInt8], kind: DashboardChallengeKind, challenge: [UInt8], expiresAt: Date, now: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "DELETE FROM dashboard_challenge WHERE expires_at <= ?", [ts(now)])
            _ = try await query(conn,
                "INSERT INTO dashboard_challenge (id, kind, challenge, expires_at) VALUES (UNHEX(?), ?, UNHEX(?), ?) "
                + "ON DUPLICATE KEY UPDATE kind=VALUES(kind), challenge=VALUES(challenge), expires_at=VALUES(expires_at)",
                [hex(id), str(kind.rawValue), hex(challenge), ts(expiresAt)])
        }
    }

    public func consumeChallenge(id: [UInt8], kind: DashboardChallengeKind, now: Date) async throws -> [UInt8]? {
        try await transaction { conn in
            let rows = try await query(conn,
                "SELECT HEX(challenge) AS ch, (expires_at > ?) AS valid FROM dashboard_challenge WHERE id=UNHEX(?) AND kind=? FOR UPDATE",
                [ts(now), hex(id), str(kind.rawValue)]).rows
            guard let row = rows.first else { return nil }
            // Used or expired, the row is gone afterwards; only the caller that deletes it receives the challenge.
            let deleted = try await query(conn, "DELETE FROM dashboard_challenge WHERE id=UNHEX(?)", [hex(id)]).affected
            guard deleted == 1, (row.column("valid")?.int ?? 0) == 1 else { return nil }
            return DashboardValidation.bytes(hex: row.column("ch")?.string ?? "")
        }
    }

    // MARK: sessions

    public func createSession(idHash: [UInt8], csrfHash: [UInt8], now: Date, expiresAt: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "DELETE FROM dashboard_session WHERE expires_at <= ?", [ts(now)])
            _ = try await query(conn,
                "INSERT INTO dashboard_session (id_hash, csrf_hash, created_at, last_seen_at, expires_at) VALUES (UNHEX(?), UNHEX(?), ?, ?, ?) "
                + "ON DUPLICATE KEY UPDATE csrf_hash=VALUES(csrf_hash), created_at=VALUES(created_at), last_seen_at=VALUES(last_seen_at), expires_at=VALUES(expires_at)",
                [hex(idHash), hex(csrfHash), ts(now), ts(now), ts(expiresAt)])
        }
    }

    public func session(idHash: [UInt8], now: Date) async throws -> DashboardSessionRecord? {
        try await connection { conn in
            let rows = try await query(conn,
                "SELECT HEX(csrf_hash) AS csrf, DATE_FORMAT(created_at, \(Self.dateOut)) AS created_s, DATE_FORMAT(last_seen_at, \(Self.dateOut)) AS seen_s, "
                + "DATE_FORMAT(expires_at, \(Self.dateOut)) AS expires_s FROM dashboard_session WHERE id_hash=UNHEX(?)", [hex(idHash)]).rows
            guard let row = rows.first else { return nil }
            let expires = Self.time(row, "expires_s")
            if expires <= now {
                _ = try await query(conn, "DELETE FROM dashboard_session WHERE id_hash=UNHEX(?) AND expires_at <= ?", [hex(idHash), ts(now)])
                return nil
            }
            return DashboardSessionRecord(idHash: idHash, csrfHash: DashboardValidation.bytes(hex: row.column("csrf")?.string ?? ""),
                                          createdAt: Self.time(row, "created_s"), lastSeenAt: Self.time(row, "seen_s"), expiresAt: expires)
        }
    }

    public func touchSession(idHash: [UInt8], now: Date, expiresAt: Date?) async throws -> Bool {
        try await connection { conn in
            let result: (rows: [MySQLRow], affected: UInt64)
            if let expiresAt {
                result = try await query(conn, "UPDATE dashboard_session SET last_seen_at=?, expires_at=? WHERE id_hash=UNHEX(?) AND expires_at > ?",
                                         [ts(now), ts(expiresAt), hex(idHash), ts(now)])
            } else {
                result = try await query(conn, "UPDATE dashboard_session SET last_seen_at=? WHERE id_hash=UNHEX(?) AND expires_at > ?",
                                         [ts(now), hex(idHash), ts(now)])
            }
            if result.affected > 0 { return true }
            // Unchanged values report 0 affected rows: decide by existence.
            return !(try await query(conn, "SELECT 1 AS ok FROM dashboard_session WHERE id_hash=UNHEX(?) AND expires_at > ?", [hex(idHash), ts(now)])).rows.isEmpty
        }
    }

    public func deleteSession(idHash: [UInt8]) async throws -> Bool {
        try await connection { conn in
            try await query(conn, "DELETE FROM dashboard_session WHERE id_hash=UNHEX(?)", [hex(idHash)]).affected > 0
        }
    }

    // MARK: statistics

    public func addStats(day: Date, _ deltas: [StatDelta]) async throws {
        guard deltas.allSatisfy(DashboardValidation.isValid) else { throw DashboardRepoError.invalidStat }
        // Merge duplicate (metric, label) pairs so one statement never touches a key twice.
        var merged: [String: StatDelta] = [:]
        for delta in deltas where delta.value > 0 {
            let key = delta.metric + "\u{0}" + delta.label
            merged[key] = StatDelta(metric: delta.metric, label: delta.label, value: (merged[key]?.value ?? 0) + delta.value)
        }
        let items = merged.values.sorted { ($0.metric, $0.label) < ($1.metric, $1.label) }
        guard !items.isEmpty else { return }
        let dayText = DashboardValidation.day(day)
        try await transaction { conn in
            for chunk in stride(from: 0, to: items.count, by: 100).map({ Array(items[$0..<min($0 + 100, items.count)]) }) {
                var binds: [MySQLData] = []
                for item in chunk { binds += [str(dayText), str(item.metric), str(item.label), MySQLData(int: item.value)] }
                _ = try await query(conn,
                    "INSERT INTO stats_daily (day, metric, label, value) VALUES " + Array(repeating: "(?,?,?,?)", count: chunk.count).joined(separator: ",")
                    + " ON DUPLICATE KEY UPDATE value = value + VALUES(value)", binds)
            }
        }
    }

    public func stats(from: Date, to: Date) async throws -> [StatRow] {
        try await connection { conn in
            try await query(conn,
                "SELECT DATE_FORMAT(day, '%Y-%m-%d') AS day_s, metric, label, value FROM stats_daily WHERE day >= ? AND day <= ? ORDER BY day, metric, label",
                [str(DashboardValidation.day(from)), str(DashboardValidation.day(to))]).rows.map {
                StatRow(day: DashboardValidation.date(day: $0.column("day_s")?.string ?? ""), metric: $0.column("metric")?.string ?? "",
                        label: $0.column("label")?.string ?? "", value: $0.column("value")?.int ?? 0)
            }
        }
    }

    public func purgeStats(now: Date) async throws -> Int {
        try await connection { conn in
            Int(try await query(conn, "DELETE FROM stats_daily WHERE day < ?", [str(DashboardValidation.statsCutoffDay(now: now))]).affected)
        }
    }

    // MARK: configuration

    private func override(_ row: MySQLRow) -> DashboardOverride {
        DashboardOverride(key: row.column("config_key")?.string ?? "", value: row.column("value")?.string ?? "",
                             updatedAt: Self.time(row, "updated_s"), revision: row.column("revision")?.int ?? 0)
    }

    public func configState() async throws -> DashboardConfigState {
        // One transaction with a consistent snapshot of revision and rows.
        try await transaction { conn in
            let revision = try await query(conn, "SELECT config_revision FROM config_generation WHERE id=1").rows.first?.column("config_revision")?.int ?? 0
            let rows = try await query(conn,
                "SELECT config_key, value, revision, DATE_FORMAT(updated_at, \(Self.dateOut)) AS updated_s FROM config_override ORDER BY config_key").rows
            return DashboardConfigState(revision: revision, overrides: rows.map(override))
        }
    }

    public func configRevision() async throws -> Int {
        try await connection { conn in
            try await query(conn, "SELECT config_revision FROM config_generation WHERE id=1").rows.first?.column("config_revision")?.int ?? 0
        }
    }

    private func bumpRevision(_ conn: MySQLConnection) async throws -> Int {
        // The row lock of this UPDATE serializes writers; the following read sees our own increment.
        _ = try await query(conn, "UPDATE config_generation SET config_revision = config_revision + 1 WHERE id=1")
        return try await query(conn, "SELECT config_revision FROM config_generation WHERE id=1").rows.first?.column("config_revision")?.int ?? 0
    }

    private func audit(_ conn: MySQLConnection, _ action: DashboardAuditAction, key: String?, old: String?, new: String?, now: Date) async throws {
        _ = try await query(conn, "INSERT INTO config_audit (at, action, config_key, old_value, new_value) VALUES (?,?,?,?,?)",
                            [ts(now), str(action.rawValue), opt(key), opt(DashboardValidation.clip(old)), opt(DashboardValidation.clip(new))])
    }

    public func setConfigOverride(key: String, value: String, audit mode: ConfigAuditMode, now: Date) async throws -> Int {
        try await transaction { conn in
            let revision = try await bumpRevision(conn)
            let old = try await query(conn, "SELECT value FROM config_override WHERE config_key=? FOR UPDATE", [str(key)]).rows.first?.column("value")?.string
            _ = try await query(conn,
                "INSERT INTO config_override (config_key, value, updated_at, revision) VALUES (?,?,?,?) "
                + "ON DUPLICATE KEY UPDATE value=VALUES(value), updated_at=VALUES(updated_at), revision=VALUES(revision)",
                [str(key), str(value), ts(now), MySQLData(int: revision)])
            let texts = DashboardValidation.auditValues(old: old, new: value, mode: mode)
            try await audit(conn, .set, key: key, old: texts.old, new: texts.new, now: now)
            return revision
        }
    }

    public func resetConfigOverride(key: String, audit mode: ConfigAuditMode, now: Date) async throws -> Int? {
        try await transaction { conn in
            guard let old = try await query(conn, "SELECT value FROM config_override WHERE config_key=? FOR UPDATE", [str(key)]).rows.first?.column("value")?.string
            else { return nil }
            _ = try await query(conn, "DELETE FROM config_override WHERE config_key=?", [str(key)])
            let revision = try await bumpRevision(conn)
            let texts = DashboardValidation.auditValues(old: old, new: nil, mode: mode)
            try await audit(conn, .reset, key: key, old: texts.old, new: texts.new, now: now)
            return revision
        }
    }

    public func appendAudit(action: DashboardAuditAction, key: String?, oldValue: String?, newValue: String?, now: Date) async throws {
        try await connection { conn in try await audit(conn, action, key: key, old: oldValue, new: newValue, now: now) }
    }

    public func auditEntries(limit: Int) async throws -> [DashboardAuditEntry] {
        try await connection { conn in
            try await query(conn,
                "SELECT id, DATE_FORMAT(at, \(Self.dateOut)) AS at_s, action, config_key, old_value, new_value FROM config_audit ORDER BY id DESC LIMIT ?",
                [MySQLData(int: max(0, limit))]).rows.map {
                DashboardAuditEntry(id: $0.column("id")?.int ?? 0, at: Self.time($0, "at_s"),
                                 action: DashboardAuditAction(rawValue: $0.column("action")?.string ?? "") ?? .set,
                                 key: $0.column("config_key")?.string, oldValue: $0.column("old_value")?.string,
                                 newValue: $0.column("new_value")?.string)
            }
        }
    }

    public func purgeAudit(now: Date) async throws -> Int {
        try await connection { conn in
            Int(try await query(conn, "DELETE FROM config_audit WHERE at < ?",
                                [ts(now.addingTimeInterval(-Double(DashboardRetention.auditDays) * 86400))]).affected)
        }
    }

    // MARK: generation and replicas

    public func generation() async throws -> GenerationState {
        try await connection { conn in
            let row = try await query(conn, "SELECT generation, DATE_FORMAT(requested_at, \(Self.dateOut)) AS req_s FROM config_generation WHERE id=1").rows.first
            return GenerationState(generation: row?.column("generation")?.int ?? 0, requestedAt: row?.column("req_s")?.string.flatMap { TimeUtil.fromSQL($0) })
        }
    }

    public func requestRestart(minInterval: TimeInterval, now: Date) async throws -> Int? {
        try await transaction { conn in
            // Single statement: the interval check and the increment cannot be split by a parallel click.
            let changed = try await query(conn,
                "UPDATE config_generation SET generation = generation + 1, requested_at = ? WHERE id=1 AND (requested_at IS NULL OR requested_at <= ?)",
                [ts(now), ts(now.addingTimeInterval(-minInterval))]).affected
            guard changed == 1 else { return nil }
            let next = try await query(conn, "SELECT generation FROM config_generation WHERE id=1").rows.first?.column("generation")?.int ?? 0
            try await audit(conn, .restart, key: nil, old: String(next - 1), new: String(next), now: now)
            return next
        }
    }

    public func heartbeat(replicaID: String, slot: Int?, appliedGeneration: Int, now: Date) async throws {
        try await connection { conn in
            _ = try await query(conn,
                "INSERT INTO config_replica (replica_id, slot, applied_generation, started_at, last_seen_at) VALUES (?,?,?,?,?) "
                + "ON DUPLICATE KEY UPDATE slot=VALUES(slot), applied_generation=VALUES(applied_generation), last_seen_at=VALUES(last_seen_at)",
                [str(replicaID), slot.map { MySQLData(int: $0) } ?? .null, MySQLData(int: appliedGeneration), ts(now), ts(now)])
        }
    }

    public func replicas(now: Date) async throws -> [ReplicaRecord] {
        try await connection { conn in
            try await query(conn,
                "SELECT replica_id, slot, applied_generation, DATE_FORMAT(started_at, \(Self.dateOut)) AS started_s, DATE_FORMAT(last_seen_at, \(Self.dateOut)) AS seen_s "
                + "FROM config_replica WHERE last_seen_at > ? ORDER BY slot IS NULL, slot, replica_id",
                [ts(now.addingTimeInterval(-DashboardRetention.replicaStale))]).rows.map {
                ReplicaRecord(replicaID: $0.column("replica_id")?.string ?? "", slot: $0.column("slot")?.int,
                              appliedGeneration: $0.column("applied_generation")?.int ?? 0,
                              startedAt: Self.time($0, "started_s"), lastSeenAt: Self.time($0, "seen_s"))
            }
        }
    }

    public func removeReplica(replicaID: String) async throws {
        try await connection { conn in _ = try await query(conn, "DELETE FROM config_replica WHERE replica_id=?", [str(replicaID)]) }
    }

    // MARK: retention

    public func purgeDashboard(now: Date) async throws -> DashboardPurgeResult {
        var result = DashboardPurgeResult()
        try await connection { conn in
            result.sessions = Int(try await query(conn, "DELETE FROM dashboard_session WHERE expires_at <= ?", [ts(now)]).affected)
            result.challenges = Int(try await query(conn, "DELETE FROM dashboard_challenge WHERE expires_at <= ?", [ts(now)]).affected)
            result.replicas = Int(try await query(conn, "DELETE FROM config_replica WHERE last_seen_at <= ?",
                                                  [ts(now.addingTimeInterval(-DashboardRetention.replicaStale))]).affected)
        }
        result.stats = try await purgeStats(now: now)
        result.audit = try await purgeAudit(now: now)
        return result
    }
}
