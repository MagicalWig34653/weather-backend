import Foundation
import MySQLKit

/// `push_state` rows `push_paused` (value = UTC time of the pause) and `cache_clear` (value = `<generation>:<scope>`).
/// No schema change: the table is a generic name/value store (migration 003).
extension MariaRepo: PushOperatorRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }

    public func pushPausedSince() async throws -> Date? {
        try await connection { conn in
            try await query(conn, "SELECT value FROM push_state WHERE name='push_paused'").rows.first?.column("value")?.string
                .flatMap(TimeUtil.fromSQL)
        }
    }

    @discardableResult public func setPushPaused(_ paused: Bool, now: Date) async throws -> Date? {
        try await transaction { conn in
            if paused {
                _ = try await query(conn, "INSERT IGNORE INTO push_state (name, value) VALUES ('push_paused', ?)", [ts(now)])
            } else {
                _ = try await query(conn, "DELETE FROM push_state WHERE name='push_paused'")
            }
            return try await query(conn, "SELECT value FROM push_state WHERE name='push_paused'").rows.first?.column("value")?.string
                .flatMap(TimeUtil.fromSQL)
        }
    }

    private static func parse(_ value: String?) -> CacheClearState {
        guard let value, let colon = value.firstIndex(of: ":"), let generation = Int(value[..<colon]) else { return CacheClearState(generation: 0, scope: "all") }
        return CacheClearState(generation: generation, scope: String(value[value.index(after: colon)...]))
    }

    public func cacheClearState() async throws -> CacheClearState {
        try await connection { conn in
            Self.parse(try await query(conn, "SELECT value FROM push_state WHERE name='cache_clear'").rows.first?.column("value")?.string)
        }
    }

    public func requestCacheClear(scope: String) async throws -> Int {
        try await transaction { conn in
            _ = try await query(conn, "INSERT IGNORE INTO push_state (name, value) VALUES ('cache_clear', '0:all')")
            let current = Self.parse(try await query(conn, "SELECT value FROM push_state WHERE name='cache_clear' FOR UPDATE").rows.first?.column("value")?.string)
            let next = current.generation + 1
            _ = try await query(conn, "UPDATE push_state SET value=? WHERE name='cache_clear'", [MySQLData(string: "\(next):\(scope)")])
            return next
        }
    }

    public func outboxGauge(now: Date) async throws -> OutboxGauge {
        try await connection { conn in
            let live = try await query(conn,
                "SELECT COUNT(*) AS n, COALESCE(SUM(attempts > 0), 0) AS r, DATE_FORMAT(MIN(created_at), '%Y-%m-%d %H:%i:%s') AS m FROM push_outbox WHERE status='pending' AND expires_at > ?", [ts(now)]).rows.first
            let since = ts(now.addingTimeInterval(-86400))
            let lost = try await query(conn,
                "SELECT COUNT(*) AS n FROM push_outbox WHERE (status='dropped' AND finished_at >= ?) OR (status='pending' AND expires_at <= ? AND expires_at >= ?)",
                [since, ts(now), since]).rows.first?.column("n")?.int ?? 0
            var gauge = OutboxGauge(waiting: live?.column("n")?.int ?? 0, retrying: live?.column("r")?.int ?? 0, droppedOrExpired24h: lost)
            if gauge.waiting > 0, let oldest = live?.column("m")?.string.flatMap(TimeUtil.fromSQL) {
                gauge.oldestAgeSeconds = max(0, Int(now.timeIntervalSince(oldest)))
            }
            return gauge
        }
    }
}
