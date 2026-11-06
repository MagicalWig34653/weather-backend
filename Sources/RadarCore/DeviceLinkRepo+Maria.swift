import Foundation
import MySQLKit

extension MariaRepo: DeviceLinkRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private func hex(_ bytes: [UInt8]) -> MySQLData { MySQLData(string: DashboardValidation.hex(bytes)) }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"
    private static let deviceColumns = "id, install_id, label, DATE_FORMAT(paired_at, \(dateOut)) AS paired_s, "
        + "DATE_FORMAT(expires_at, \(dateOut)) AS expires_s, DATE_FORMAT(last_action_at, \(dateOut)) AS action_s"

    private static func device(_ row: MySQLRow) -> LinkedDevice {
        LinkedDevice(id: row.column("id")?.string ?? "", installID: row.column("install_id")?.string ?? "",
                     label: row.column("label")?.string ?? "", pairedAt: time(row, "paired_s"),
                     expiresAt: row.column("expires_s")?.string.flatMap(TimeUtil.fromSQL),
                     lastActionAt: row.column("action_s")?.string.flatMap(TimeUtil.fromSQL))
    }

    public func createLinkCode(installationID: String, codeHash: [UInt8], attested: Bool, now: Date, ttl: TimeInterval, maxDevices: Int) async throws -> CreateLinkCodeResult {
        try await transaction { conn in
            // The installation row is locked: no parallel code or pairing for the same installation.
            guard try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(installationID)]).rows.first != nil else {
                return .unknownInstallation
            }
            if try await query(conn, "SELECT id FROM dashboard_device WHERE install_id=?", [str(installationID)]).rows.first != nil { return .alreadyLinked }
            let count = try await query(conn, "SELECT COUNT(*) AS c FROM dashboard_device").rows.first?.column("c")?.int ?? 0
            if count >= maxDevices { return .linkFull }
            _ = try await query(conn, "DELETE FROM push_link_code WHERE install_id=? OR expires_at < ?", [str(installationID), ts(now)])
            _ = try await query(conn, "INSERT INTO push_link_code (code_hash, install_id, attested, created_at, expires_at) VALUES (UNHEX(?), ?, ?, ?, ?)",
                                [hex(codeHash), str(installationID), MySQLData(int: attested ? 1 : 0), ts(now), ts(now.addingTimeInterval(ttl))])
            return .created
        }
    }

    public func linkState(installationID: String, now: Date) async throws -> DeviceLinkState {
        try await connection { conn in
            if let row = try await query(conn, "SELECT \(Self.deviceColumns) FROM dashboard_device WHERE install_id=?", [str(installationID)]).rows.first {
                let device = Self.device(row)
                let pending = try await query(conn, "SELECT COUNT(*) AS c FROM dashboard_command WHERE device_id=? AND status IN ('queued','running')",
                                              [str(device.id)]).rows.first?.column("c")?.int ?? 0
                return DeviceLinkState(kind: .linked, linkedAt: device.pairedAt, expiresAt: device.expiresAt,
                                       lastActionAt: device.lastActionAt, pendingCommands: min(pending, 5))
            }
            if let row = try await query(conn, "SELECT DATE_FORMAT(expires_at, \(Self.dateOut)) AS e FROM push_link_code WHERE install_id=? AND used_at IS NULL AND expires_at > ?",
                                         [str(installationID), ts(now)]).rows.first {
                return DeviceLinkState(kind: .codeOpen, codeExpiresAt: Self.time(row, "e"))
            }
            return DeviceLinkState(kind: .none)
        }
    }

    public func unlink(installationID: String) async throws {
        try await connection { conn in
            _ = try await query(conn, "DELETE FROM dashboard_device WHERE install_id=?", [str(installationID)])   // events and commands cascade
            _ = try await query(conn, "DELETE FROM push_link_code WHERE install_id=?", [str(installationID)])
        }
    }

    public func pairDevice(codeHash: [UInt8], label: String, deviceID: String, now: Date, maxDevices: Int, ttlDays: Int) async throws -> PairDeviceResult {
        // The device limit spans installations: redemptions are serialized with an advisory lock (rare path, no table or gap locks).
        try await connection { conn in
            guard try await query(conn, "SELECT GET_LOCK('showernow_device_pair', 10) AS l").rows.first?.column("l")?.int == 1 else {
                throw ConfigError(description: "could not obtain pairing lock")
            }
            do {
                let result = try await pairLocked(conn, codeHash: codeHash, label: label, deviceID: deviceID, now: now, maxDevices: maxDevices, ttlDays: ttlDays)
                _ = try? await query(conn, "SELECT RELEASE_LOCK('showernow_device_pair')")
                return result
            } catch {
                _ = try? await query(conn, "SELECT RELEASE_LOCK('showernow_device_pair')")
                throw error
            }
        }
    }

    private func pairLocked(_ conn: MySQLConnection, codeHash: [UInt8], label: String, deviceID: String, now: Date, maxDevices: Int, ttlDays: Int) async throws -> PairDeviceResult {
        guard let row = try await query(conn,
            "SELECT install_id FROM push_link_code WHERE code_hash=UNHEX(?) AND attested=1 AND used_at IS NULL AND expires_at > ?",
            [hex(codeHash), ts(now)]).rows.first, let installID = row.column("install_id")?.string else { return .codeUnknown }
        if try await query(conn, "SELECT id FROM dashboard_device WHERE install_id=?", [str(installID)]).rows.first != nil { return .codeUnknown }
        let count = try await query(conn, "SELECT COUNT(*) AS c FROM dashboard_device").rows.first?.column("c")?.int ?? 0
        guard count < maxDevices else { return .deviceLimit }
        // Insert and consume the code together; a vanished installation (cascade) makes the insert fail and the code unusable.
        _ = try await query(conn, "START TRANSACTION")
        do {
            let result = try await insertPaired(conn, installID: installID, codeHash: codeHash, label: label, deviceID: deviceID, now: now, ttlDays: ttlDays)
            _ = try await query(conn, "COMMIT")
            return result
        } catch {
            _ = try? await query(conn, "ROLLBACK")
            throw error
        }
    }

    private func insertPaired(_ conn: MySQLConnection, installID: String, codeHash: [UInt8], label: String, deviceID: String, now: Date, ttlDays: Int) async throws -> PairDeviceResult {
        let expires: Date? = ttlDays > 0 ? now.addingTimeInterval(Double(ttlDays) * 86400) : nil
        _ = try await query(conn, "INSERT INTO dashboard_device (id, install_id, label, paired_at, expires_at) VALUES (?, ?, ?, ?, ?)",
                            [str(deviceID), str(installID), str(label), ts(now), expires.map(ts) ?? .null])
        _ = try await query(conn, "UPDATE push_link_code SET used_at=? WHERE code_hash=UNHEX(?)", [ts(now), hex(codeHash)])
        return .paired(LinkedDevice(id: deviceID, installID: installID, label: label, pairedAt: now, expiresAt: expires, lastActionAt: nil))
    }

    public func devices() async throws -> [LinkedDevice] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.deviceColumns) FROM dashboard_device ORDER BY paired_at, id").rows.map(Self.device)
        }
    }

    public func device(id: String) async throws -> LinkedDevice? {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.deviceColumns) FROM dashboard_device WHERE id=?", [str(id)]).rows.first.map(Self.device)
        }
    }

    public func deleteDevice(id: String) async throws -> Bool {
        try await connection { conn in
            let rows = try await query(conn, "SELECT install_id FROM dashboard_device WHERE id=?", [str(id)]).rows
            guard let install = rows.first?.column("install_id")?.string else { return false }
            _ = try await query(conn, "DELETE FROM dashboard_device WHERE id=?", [str(id)])
            _ = try await query(conn, "DELETE FROM push_link_code WHERE install_id=?", [str(install)])
            return true
        }
    }

    public func purgeLinks(now: Date, removeAll: Bool) async throws -> Int {
        try await connection { conn in
            _ = try await query(conn, "DELETE FROM push_link_code WHERE used_at IS NOT NULL OR expires_at < ?", [ts(now)])
            let removed = removeAll
                ? try await query(conn, "DELETE FROM dashboard_device").affected
                : try await query(conn, "DELETE FROM dashboard_device WHERE expires_at IS NOT NULL AND expires_at <= ?", [ts(now)]).affected
            return Int(removed)
        }
    }

    public func deviceInstallInfo(id: String) async throws -> DeviceInstallInfo? {
        try await connection { conn in
            guard let row = try await query(conn,
                "SELECT i.id AS iid, i.env AS env, i.locale AS locale, i.la_start_token IS NOT NULL AS has_start, DATE_FORMAT(i.created_at, \(Self.dateOut)) AS created_s, "
                + "DATE_FORMAT(i.last_seen_at, \(Self.dateOut)) AS seen_s, DATE_FORMAT(i.token_updated_at, \(Self.dateOut)) AS token_s FROM dashboard_device d JOIN push_install i ON i.id=d.install_id WHERE d.id=?",
                [str(id)]).rows.first, let env = row.column("env")?.string.flatMap(PushEnvironment.init(rawValue:)) else { return nil }
            return DeviceInstallInfo(installID: row.column("iid")?.string ?? "", env: env, locale: row.column("locale")?.string ?? "de", createdAt: Self.time(row, "created_s"),
                                     lastSeenAt: row.column("seen_s")?.string.flatMap(TimeUtil.fromSQL),
                                     tokenUpdatedAt: row.column("token_s")?.string.flatMap(TimeUtil.fromSQL), hasStartToken: (row.column("has_start")?.int ?? 0) != 0)
        }
    }
}
