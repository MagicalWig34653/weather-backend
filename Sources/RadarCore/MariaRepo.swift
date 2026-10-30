import AsyncKit
import Foundation
import Logging
import MySQLKit
import MySQLNIO
import NIOCore
import NIOPosix

/// Production repo on MariaDB/InnoDB through mysql-nio. Lease times come from the DB clock (UTC_TIMESTAMP()).
public final class MariaRepo: Repo, @unchecked Sendable {
    private let pool: EventLoopGroupConnectionPool<MySQLConnectionSource>
    private let migrationsDirectory: String
    private let group: MultiThreadedEventLoopGroup

    public init(config: Config) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let configuration = MySQLConfiguration(
            hostname: config.dbHost, port: config.dbPort, username: config.dbUser,
            password: config.dbPassword, database: config.dbName, tlsConfiguration: nil)
        pool = EventLoopGroupConnectionPool(
            source: MySQLConnectionSource(configuration: configuration),
            maxConnectionsPerEventLoop: max(1, config.dbPoolSize / 2),
            requestTimeout: .seconds(30), pruneInterval: .seconds(30),
            logger: Logger(label: "radar.db"), on: group)
        migrationsDirectory = config.migrationsDirectory
    }

    public func shutdown() async {
        try? await pool.shutdownAsync()
        try? await group.shutdownGracefully()
    }

    // MARK: connection helpers

    private func connection<T>(_ body: (MySQLConnection) async throws -> T) async throws -> T {
        let conn = try await pool.requestConnection().get()
        do {
            _ = try await conn.simpleQuery("SET time_zone='+00:00'").get()
            let result = try await body(conn)
            pool.releaseConnection(conn)
            return result
        } catch {
            pool.releaseConnection(conn)
            throw error
        }
    }

    /// Runs `body` in a transaction (commit on success, rollback on error).
    private func transaction<T>(_ body: (MySQLConnection) async throws -> T) async throws -> T {
        try await connection { conn in
            _ = try await conn.simpleQuery("START TRANSACTION").get()
            do {
                let result = try await body(conn)
                _ = try await conn.simpleQuery("COMMIT").get()
                return result
            } catch {
                _ = try? await conn.simpleQuery("ROLLBACK").get()
                throw error
            }
        }
    }

    private func query(_ conn: MySQLConnection, _ sql: String, _ binds: [MySQLData] = []) async throws
        -> (rows: [MySQLRow], affected: UInt64) {
        nonisolated(unsafe) var affected: UInt64 = 0
        let rows = try await conn.query(sql, binds, onMetadata: { affected = $0.affectedRows }).get()
        return (rows, affected)
    }

    private static func time(_ row: MySQLRow, _ column: String) -> Date {
        TimeUtil.fromSQL(row.column(column)?.string ?? "") ?? Date(timeIntervalSince1970: 0)
    }

    private static func refs(_ rows: [MySQLRow]) -> [SlotRef] {
        rows.map {
            SlotRef(runID: $0.column("run_id")?.string ?? "", slotID: $0.column("slot_id")?.string ?? "",
                    slotIndex: $0.column("slot_index")?.int ?? 0, slotTime: time($0, "slot_time_s"))
        }
    }

    func rawExecute(_ sql: String) async throws {
        try await connection { conn in _ = try await query(conn, sql) }
    }

    // MARK: Repo

    public func ping() async throws {
        try await connection { conn in _ = try await query(conn, "SELECT 1") }
    }

    /// Versioned SQL files (additive only), serialized across replicas with an advisory lock.
    public func migrate() async throws {
        try await connection { conn in
            let lock = try await query(conn, "SELECT GET_LOCK('showernow_migrate', 60) AS l")
            guard lock.rows.first?.column("l")?.int == 1 else { throw ConfigError(description: "could not obtain migration lock") }
            do {
                _ = try await query(conn, "CREATE TABLE IF NOT EXISTS schema_migration ("
                    + "version VARCHAR(64) PRIMARY KEY, applied_at DATETIME NOT NULL DEFAULT UTC_TIMESTAMP()) ENGINE=InnoDB")
                let done = Set(try await query(conn, "SELECT version FROM schema_migration").rows.compactMap { $0.column("version")?.string })
                let files = try FileManager.default.contentsOfDirectory(atPath: migrationsDirectory)
                    .filter { $0.hasSuffix(".sql") }.sorted()
                for file in files {
                    let stem = String(file.dropLast(4))
                    if done.contains(stem) { continue }
                    let text = try String(contentsOfFile: migrationsDirectory + "/" + file, encoding: .utf8)
                    for statement in text.components(separatedBy: ";\n") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await query(conn, statement)
                    }
                    _ = try await query(conn, "INSERT INTO schema_migration (version) VALUES (?)", [MySQLData(string: stem)])
                }
            } catch {
                _ = try? await query(conn, "SELECT RELEASE_LOCK('showernow_migrate')")
                throw error
            }
            _ = try await query(conn, "SELECT RELEASE_LOCK('showernow_migrate')")
        }
    }

    public func tryClaim(runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool {
        do {
            return try await transaction { conn in
                let inserted = try await query(conn,
                    "INSERT IGNORE INTO radar_run (run_id, nominal_time, status, claimed_by, lease_until, attempts) "
                    + "VALUES (?, ?, 'claimed', ?, UTC_TIMESTAMP() + INTERVAL ? SECOND, 1)",
                    [MySQLData(string: runID), MySQLData(string: TimeUtil.toSQL(nominal)), MySQLData(string: owner), MySQLData(int: leaseSeconds)])
                if inserted.affected == 1 { return true }
                let current = try await query(conn,
                    "SELECT status, lease_until < UTC_TIMESTAMP() AS expired, attempts FROM radar_run WHERE run_id = ? FOR UPDATE",
                    [MySQLData(string: runID)])
                guard let row = current.rows.first else { return false }
                let expired = (row.column("expired")?.int ?? 0) == 1
                let attempts = row.column("attempts")?.int ?? 0
                if row.column("status")?.string == "published" || !expired || attempts >= maxAttempts { return false }
                _ = try await query(conn,
                    "UPDATE radar_run SET status='claimed', claimed_by=?, attempts=attempts+1, "
                    + "lease_until = UTC_TIMESTAMP() + INTERVAL ? SECOND WHERE run_id=?",
                    [MySQLData(string: owner), MySQLData(int: leaseSeconds), MySQLData(string: runID)])
                return true
            }
        } catch MySQLError.server(let packet) where packet.errorCode.rawValue == 1205 || packet.errorCode.rawValue == 1213 {
            return false  // lock wait/deadlock: a concurrent claimer won
        }
    }

    public func renew(runID: String, owner: String, leaseSeconds: Int) async throws -> Bool {
        try await connection { conn in
            let result = try await query(conn,
                "UPDATE radar_run SET lease_until = UTC_TIMESTAMP() + INTERVAL ? SECOND "
                + "WHERE run_id=? AND claimed_by=? AND status='claimed'",
                [MySQLData(int: leaseSeconds), MySQLData(string: runID), MySQLData(string: owner)])
            if result.affected >= 1 { return true }
            let check = try await query(conn, "SELECT 1 AS ok FROM radar_run WHERE run_id=? AND claimed_by=? AND status='claimed'",
                                        [MySQLData(string: runID), MySQLData(string: owner)])
            return !check.rows.isEmpty
        }
    }

    public func putSlot(_ ref: SlotRef, contentType: String, data: [UInt8]) async throws {
        try await connection { conn in
            _ = try await query(conn,
                "INSERT INTO radar_slot (run_id, slot_id, slot_index, slot_time, content_type, sha256, size, bytes) "
                + "VALUES (?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE "
                + "content_type=VALUES(content_type), sha256=VALUES(sha256), size=VALUES(size), bytes=VALUES(bytes)",
                [MySQLData(string: ref.runID), MySQLData(string: ref.slotID), MySQLData(int: ref.slotIndex),
                 MySQLData(string: TimeUtil.toSQL(ref.slotTime)), MySQLData(string: contentType),
                 MySQLData(string: Hashing.sha256Hex(data)), MySQLData(int: data.count),
                 MySQLData(type: .blob, buffer: ByteBuffer(bytes: data))])
        }
    }

    public func publish(runID: String, owner: String, expectedSlots: Int) async throws -> Bool {
        try await transaction { conn in
            let run = try await query(conn, "SELECT status, claimed_by FROM radar_run WHERE run_id=? FOR UPDATE", [MySQLData(string: runID)])
            guard let row = run.rows.first, row.column("status")?.string == "claimed", row.column("claimed_by")?.string == owner else {
                return false
            }
            let count = try await query(conn, "SELECT COUNT(*) AS n FROM radar_slot WHERE run_id=?", [MySQLData(string: runID)])
            guard count.rows.first?.column("n")?.int == expectedSlots else { return false }
            _ = try await query(conn, "UPDATE radar_run SET status='published', published_at=UTC_TIMESTAMP() WHERE run_id=?",
                                [MySQLData(string: runID)])
            return true
        }
    }

    public func fail(runID: String, owner: String, cooldownSeconds: Int) async throws {
        try await connection { conn in
            _ = try await query(conn,
                "UPDATE radar_run SET status='failed', lease_until = UTC_TIMESTAMP() + INTERVAL ? SECOND "
                + "WHERE run_id=? AND claimed_by=? AND status='claimed'",
                [MySQLData(int: cooldownSeconds), MySQLData(string: runID), MySQLData(string: owner)])
        }
    }

    public func isPublished(runID: String) async throws -> Bool {
        try await connection { conn in
            !(try await query(conn, "SELECT 1 AS ok FROM radar_run WHERE run_id=? AND status='published'", [MySQLData(string: runID)])).rows.isEmpty
        }
    }

    public func latestPublished() async throws -> PublishedRun? {
        try await connection { conn in
            let result = try await query(conn,
                "SELECT run_id, DATE_FORMAT(nominal_time,'%Y-%m-%d %H:%i:%s') AS nominal_s, "
                + "DATE_FORMAT(published_at,'%Y-%m-%d %H:%i:%s') AS published_s FROM radar_run "
                + "WHERE status='published' ORDER BY nominal_time DESC LIMIT 1")
            guard let row = result.rows.first, let id = row.column("run_id")?.string else { return nil }
            return PublishedRun(runID: id, nominal: Self.time(row, "nominal_s"), publishedAt: Self.time(row, "published_s"))
        }
    }

    private static let slotColumns = "s.run_id, s.slot_id, s.slot_index, DATE_FORMAT(s.slot_time,'%Y-%m-%d %H:%i:%s') AS slot_time_s"

    public func publishedSlots(runID: String) async throws -> [SlotRef] {
        try await connection { conn in
            Self.refs(try await query(conn,
                "SELECT \(Self.slotColumns) FROM radar_slot s JOIN radar_run r ON r.run_id = s.run_id "
                + "WHERE r.status='published' AND s.run_id=? ORDER BY s.slot_index", [MySQLData(string: runID)]).rows)
        }
    }

    public func historySlots(since: Date, before: Date) async throws -> [SlotRef] {
        try await connection { conn in
            Self.refs(try await query(conn,
                "SELECT \(Self.slotColumns) FROM radar_slot s JOIN radar_run r ON r.run_id = s.run_id "
                + "WHERE r.status='published' AND s.slot_index=0 AND r.nominal_time >= ? AND r.nominal_time < ? "
                + "ORDER BY s.slot_time", [MySQLData(string: TimeUtil.toSQL(since)), MySQLData(string: TimeUtil.toSQL(before))]).rows)
        }
    }

    public func getSlot(runID: String, slotID: String) async throws -> SlotBlob? {
        try await connection { conn in
            let result = try await query(conn,
                "SELECT s.content_type, s.sha256, s.bytes FROM radar_slot s JOIN radar_run r ON r.run_id = s.run_id "
                + "WHERE r.status='published' AND s.run_id=? AND s.slot_id=?", [MySQLData(string: runID), MySQLData(string: slotID)])
            guard let row = result.rows.first, let type = row.column("content_type")?.string,
                  let sha = row.column("sha256")?.string, let buffer = row.column("bytes")?.buffer else { return nil }
            return SlotBlob(contentType: type, sha256: sha, data: Array(buffer.readableBytesView))
        }
    }

    public func retain(keepPublished: Int, staleAfter: TimeInterval) async throws -> Int {
        try await connection { conn in
            var doomed = try await query(conn,
                "SELECT run_id FROM radar_run WHERE status='published' ORDER BY nominal_time DESC LIMIT 18446744073709551615 OFFSET ?",
                [MySQLData(int: keepPublished)]).rows.compactMap { $0.column("run_id")?.string }
            doomed += try await query(conn,
                "SELECT run_id FROM radar_run WHERE status<>'published' AND lease_until < UTC_TIMESTAMP() - INTERVAL ? SECOND",
                [MySQLData(int: Int(staleAfter))]).rows.compactMap { $0.column("run_id")?.string }
            for id in doomed {
                _ = try await query(conn, "DELETE FROM radar_slot WHERE run_id=?", [MySQLData(string: id)])
                _ = try await query(conn, "DELETE FROM radar_run WHERE run_id=?", [MySQLData(string: id)])
            }
            return doomed.count
        }
    }
}

extension MariaRepo {
    /// Test helper for disposable databases only.
    public func dropAllForTests() async throws {
        for table in ["radar_slot", "radar_run", "schema_migration"] {
            try await rawExecute("DROP TABLE IF EXISTS \(table)")
        }
    }
}
