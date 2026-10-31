import Foundation
import MySQLKit
import NIOCore

extension MariaRepo {
    private func str(_ v: String) -> MySQLData { MySQLData(string: v) }

    public func layerTryClaim(layer: String, runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool {
        do {
            return try await transaction { conn in
                let inserted = try await query(conn,
                    "INSERT IGNORE INTO layer_run (layer, run_id, nominal_time, status, claimed_by, lease_until, attempts) "
                    + "VALUES (?, ?, ?, 'claimed', ?, UTC_TIMESTAMP() + INTERVAL ? SECOND, 1)",
                    [str(layer), str(runID), str(TimeUtil.toSQL(nominal)), str(owner), MySQLData(int: leaseSeconds)])
                if inserted.affected == 1 { return true }
                let current = try await query(conn,
                    "SELECT status, lease_until < UTC_TIMESTAMP() AS expired, attempts FROM layer_run WHERE layer=? AND run_id=? FOR UPDATE",
                    [str(layer), str(runID)])
                guard let row = current.rows.first else { return false }
                let expired = (row.column("expired")?.int ?? 0) == 1
                let attempts = row.column("attempts")?.int ?? 0
                if row.column("status")?.string == "published" || !expired || attempts >= maxAttempts { return false }
                _ = try await query(conn,
                    "UPDATE layer_run SET status='claimed', claimed_by=?, attempts=attempts+1, "
                    + "lease_until = UTC_TIMESTAMP() + INTERVAL ? SECOND WHERE layer=? AND run_id=?",
                    [str(owner), MySQLData(int: leaseSeconds), str(layer), str(runID)])
                return true
            }
        } catch MySQLError.server(let packet) where packet.errorCode.rawValue == 1205 || packet.errorCode.rawValue == 1213 {
            return false
        }
    }

    public func layerRenew(layer: String, runID: String, owner: String, leaseSeconds: Int) async throws -> Bool {
        try await connection { conn in
            let result = try await query(conn,
                "UPDATE layer_run SET lease_until = UTC_TIMESTAMP() + INTERVAL ? SECOND "
                + "WHERE layer=? AND run_id=? AND claimed_by=? AND status='claimed'",
                [MySQLData(int: leaseSeconds), str(layer), str(runID), str(owner)])
            if result.affected >= 1 { return true }
            return !(try await query(conn, "SELECT 1 AS ok FROM layer_run WHERE layer=? AND run_id=? AND claimed_by=? AND status='claimed'",
                                     [str(layer), str(runID), str(owner)])).rows.isEmpty
        }
    }

    public func layerPutSlot(layer: String, _ ref: SlotRef, contentType: String, data: [UInt8]) async throws {
        try await connection { conn in
            _ = try await query(conn,
                "INSERT INTO layer_slot (layer, run_id, slot_id, slot_index, slot_time, content_type, sha256, size, bytes) "
                + "VALUES (?,?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE "
                + "content_type=VALUES(content_type), sha256=VALUES(sha256), size=VALUES(size), bytes=VALUES(bytes)",
                [str(layer), str(ref.runID), str(ref.slotID), MySQLData(int: ref.slotIndex), str(TimeUtil.toSQL(ref.slotTime)),
                 str(contentType), str(Hashing.sha256Hex(data)), MySQLData(int: data.count),
                 MySQLData(type: .blob, buffer: ByteBuffer(bytes: data))])
        }
    }

    public func layerPublish(layer: String, runID: String, owner: String, expectedSlots: Int) async throws -> Bool {
        try await transaction { conn in
            let run = try await query(conn, "SELECT status, claimed_by FROM layer_run WHERE layer=? AND run_id=? FOR UPDATE", [str(layer), str(runID)])
            guard let row = run.rows.first, row.column("status")?.string == "claimed", row.column("claimed_by")?.string == owner else { return false }
            let count = try await query(conn, "SELECT COUNT(*) AS n FROM layer_slot WHERE layer=? AND run_id=?", [str(layer), str(runID)])
            guard count.rows.first?.column("n")?.int == expectedSlots else { return false }
            _ = try await query(conn, "UPDATE layer_run SET status='published', published_at=UTC_TIMESTAMP() WHERE layer=? AND run_id=?",
                                [str(layer), str(runID)])
            return true
        }
    }

    public func layerFail(layer: String, runID: String, owner: String, cooldownSeconds: Int) async throws {
        try await connection { conn in
            _ = try await query(conn,
                "UPDATE layer_run SET status='failed', lease_until = UTC_TIMESTAMP() + INTERVAL ? SECOND "
                + "WHERE layer=? AND run_id=? AND claimed_by=? AND status='claimed'",
                [MySQLData(int: cooldownSeconds), str(layer), str(runID), str(owner)])
        }
    }

    public func layerIsPublished(layer: String, runID: String) async throws -> Bool {
        try await connection { conn in
            !(try await query(conn, "SELECT 1 AS ok FROM layer_run WHERE layer=? AND run_id=? AND status='published'",
                              [str(layer), str(runID)])).rows.isEmpty
        }
    }

    public func layerLatestPublished(layer: String) async throws -> PublishedRun? {
        try await connection { conn in
            let result = try await query(conn,
                "SELECT run_id, DATE_FORMAT(nominal_time,'%Y-%m-%d %H:%i:%s') AS nominal_s, "
                + "DATE_FORMAT(published_at,'%Y-%m-%d %H:%i:%s') AS published_s FROM layer_run "
                + "WHERE layer=? AND status='published' ORDER BY nominal_time DESC LIMIT 1", [str(layer)])
            guard let row = result.rows.first, let id = row.column("run_id")?.string else { return nil }
            return PublishedRun(runID: id, nominal: Self.time(row, "nominal_s"), publishedAt: Self.time(row, "published_s"))
        }
    }

    private static let layerSlotColumns = "s.run_id, s.slot_id, s.slot_index, DATE_FORMAT(s.slot_time,'%Y-%m-%d %H:%i:%s') AS slot_time_s"

    private static func layerRefs(_ rows: [MySQLRow]) -> [SlotRef] {
        rows.map {
            SlotRef(runID: $0.column("run_id")?.string ?? "", slotID: $0.column("slot_id")?.string ?? "",
                    slotIndex: $0.column("slot_index")?.int ?? 0, slotTime: time($0, "slot_time_s"))
        }
    }

    public func layerPublishedSlots(layer: String, runID: String) async throws -> [SlotRef] {
        try await connection { conn in
            Self.layerRefs(try await query(conn,
                "SELECT \(Self.layerSlotColumns) FROM layer_slot s JOIN layer_run r ON r.layer = s.layer AND r.run_id = s.run_id "
                + "WHERE r.status='published' AND s.layer=? AND s.run_id=? ORDER BY s.slot_index", [str(layer), str(runID)]).rows)
        }
    }

    public func layerFirstSlots(layer: String, since: Date, before: Date) async throws -> [SlotRef] {
        try await connection { conn in
            Self.layerRefs(try await query(conn,
                "SELECT \(Self.layerSlotColumns) FROM layer_slot s JOIN layer_run r ON r.layer = s.layer AND r.run_id = s.run_id "
                + "WHERE r.status='published' AND s.layer=? AND s.slot_index=0 AND r.nominal_time >= ? AND r.nominal_time < ? "
                + "ORDER BY s.slot_time", [str(layer), str(TimeUtil.toSQL(since)), str(TimeUtil.toSQL(before))]).rows)
        }
    }

    public func layerGetSlot(layer: String, runID: String, slotID: String) async throws -> SlotBlob? {
        try await connection { conn in
            let result = try await query(conn,
                "SELECT s.content_type, s.sha256, s.bytes FROM layer_slot s JOIN layer_run r ON r.layer = s.layer AND r.run_id = s.run_id "
                + "WHERE r.status='published' AND s.layer=? AND s.run_id=? AND s.slot_id=?", [str(layer), str(runID), str(slotID)])
            guard let row = result.rows.first, let type = row.column("content_type")?.string,
                  let sha = row.column("sha256")?.string, let buffer = row.column("bytes")?.buffer else { return nil }
            return SlotBlob(contentType: type, sha256: sha, data: Array(buffer.readableBytesView))
        }
    }

    public func layerRetain(layer: String, keepNewest: Int, keepSince: Date, staleAfter: TimeInterval) async throws -> Int {
        try await connection { conn in
            var doomed: [String] = []
            let keep = try await query(conn,
                "SELECT run_id FROM layer_run WHERE layer=? AND status='published' ORDER BY nominal_time DESC LIMIT ?",
                [str(layer), MySQLData(int: max(0, keepNewest))]).rows.compactMap { $0.column("run_id")?.string }
            let old = try await query(conn,
                "SELECT run_id FROM layer_run WHERE layer=? AND status='published' AND nominal_time < ?",
                [str(layer), str(TimeUtil.toSQL(keepSince))]).rows.compactMap { $0.column("run_id")?.string }
            doomed += old.filter { !keep.contains($0) }
            doomed += try await query(conn,
                "SELECT run_id FROM layer_run WHERE layer=? AND status<>'published' AND lease_until < UTC_TIMESTAMP() - INTERVAL ? SECOND",
                [str(layer), MySQLData(int: Int(staleAfter))]).rows.compactMap { $0.column("run_id")?.string }
            for id in doomed {
                _ = try await query(conn, "DELETE FROM layer_slot WHERE layer=? AND run_id=?", [str(layer), str(id)])
                _ = try await query(conn, "DELETE FROM layer_run WHERE layer=? AND run_id=?", [str(layer), str(id)])
            }
            return doomed.count
        }
    }
}
