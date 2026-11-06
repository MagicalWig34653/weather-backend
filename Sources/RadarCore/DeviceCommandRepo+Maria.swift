import Foundation
import MySQLKit

extension MariaRepo: DeviceCommandRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private func opt(_ value: String?) -> MySQLData { value.map { MySQLData(string: $0) } ?? .null }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"
    private static let columns = "id, device_id, kind, dry_run, status, DATE_FORMAT(created_at, \(dateOut)) AS created_s, "
        + "DATE_FORMAT(started_at, \(dateOut)) AS started_s, DATE_FORMAT(finished_at, \(dateOut)) AS finished_s, result, error"

    private static func command(_ row: MySQLRow) -> DeviceCommand? {
        guard let kind = row.column("kind")?.string.flatMap(DeviceCommandKind.init(rawValue:)),
              let status = row.column("status")?.string.flatMap(DeviceCommandStatus.init(rawValue:)) else { return nil }
        return DeviceCommand(id: row.column("id")?.string ?? "", deviceID: row.column("device_id")?.string ?? "", kind: kind,
                             dryRun: row.column("dry_run")?.int.map { $0 != 0 }, status: status, createdAt: time(row, "created_s"),
                             startedAt: row.column("started_s")?.string.flatMap(TimeUtil.fromSQL),
                             finishedAt: row.column("finished_s")?.string.flatMap(TimeUtil.fromSQL),
                             result: row.column("result")?.string, error: row.column("error")?.string)
    }

    public func createCommand(deviceID: String, kind: DeviceCommandKind, dryRun: Bool?, now: Date) async throws -> CreateCommandResult {
        try await transaction { conn in
            guard try await query(conn, "SELECT id FROM dashboard_device WHERE id=? FOR UPDATE", [str(deviceID)]).rows.first != nil else { return .deviceGone }
            if try await query(conn, "SELECT id FROM dashboard_command WHERE device_id=? AND kind=? AND status IN ('queued','running') LIMIT 1",
                               [str(deviceID), str(kind.rawValue)]).rows.first != nil { return .pending }
            let id = UUID().uuidString.lowercased()
            _ = try await query(conn, "INSERT INTO dashboard_command (id, device_id, kind, dry_run, status, created_at) VALUES (?, ?, ?, ?, 'queued', ?)",
                                [str(id), str(deviceID), str(kind.rawValue), dryRun.map { MySQLData(int: $0 ? 1 : 0) } ?? .null, ts(now)])
            // Keep the newest 50 per device.
            _ = try await query(conn, "DELETE FROM dashboard_command WHERE device_id=? AND id NOT IN (SELECT id FROM (SELECT id FROM dashboard_command WHERE device_id=? ORDER BY created_at DESC, id DESC LIMIT ?) keep)",
                                [str(deviceID), str(deviceID), MySQLData(int: DeviceRetention.maxCommandsPerDevice)])
            _ = try await query(conn, "UPDATE dashboard_device SET last_action_at=? WHERE id=?", [ts(now), str(deviceID)])
            return .created(DeviceCommand(id: id, deviceID: deviceID, kind: kind, dryRun: dryRun, status: .queued, createdAt: now))
        }
    }

    public func command(id: String, deviceID: String) async throws -> DeviceCommand? {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.columns) FROM dashboard_command WHERE id=? AND device_id=?", [str(id), str(deviceID)]).rows.first.flatMap(Self.command)
        }
    }

    public func commands(deviceID: String, limit: Int) async throws -> [DeviceCommand] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.columns) FROM dashboard_command WHERE device_id=? ORDER BY created_at DESC, id DESC LIMIT ?",
                            [str(deviceID), MySQLData(int: max(0, limit))]).rows.compactMap(Self.command)
        }
    }

    public func claimNextCommand(now: Date) async throws -> DeviceCommand? {
        try await connection { conn in
            _ = try await query(conn, "UPDATE dashboard_command SET status='expired', finished_at=? WHERE status='queued' AND created_at < ?",
                                [ts(now), ts(now.addingTimeInterval(-DeviceRetention.commandExpirySeconds))])
            for _ in 0..<3 {
                guard let row = try await query(conn, "SELECT \(Self.columns) FROM dashboard_command WHERE status='queued' ORDER BY created_at, id LIMIT 1").rows.first,
                      let command = Self.command(row) else { return nil }
                // Only one leader wins the transition.
                if try await query(conn, "UPDATE dashboard_command SET status='running', started_at=? WHERE id=? AND status='queued'", [ts(now), str(command.id)]).affected == 1 {
                    var running = command; running.status = .running; running.startedAt = now
                    return running
                }
            }
            return nil
        }
    }

    public func finishCommand(id: String, status: DeviceCommandStatus, result: String?, error: String?, now: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "UPDATE dashboard_command SET status=?, finished_at=?, result=?, error=? WHERE id=?",
                                [str(status.rawValue), ts(now), opt(result), opt(error), str(id)])
        }
    }

    public func appendDeviceEvent(installationID: String, kind: String, outcome: String, reason: String?, now: Date) async throws {
        try await connection { conn in
            guard let device = try await query(conn, "SELECT id FROM dashboard_device WHERE install_id=?", [str(installationID)]).rows.first?.column("id")?.string else { return }
            _ = try await query(conn, "INSERT INTO dashboard_device_event (device_id, at, kind, outcome, reason) VALUES (?, ?, ?, ?, ?)",
                                [str(device), ts(now), str(kind), str(outcome), opt(reason.map { String($0.prefix(64)) })])
            _ = try await query(conn, "DELETE FROM dashboard_device_event WHERE device_id=? AND id NOT IN (SELECT id FROM (SELECT id FROM dashboard_device_event WHERE device_id=? ORDER BY id DESC LIMIT ?) keep)",
                                [str(device), str(device), MySQLData(int: DeviceRetention.maxEventsPerDevice)])
        }
    }

    public func deviceEvents(deviceID: String, limit: Int) async throws -> [DeviceEvent] {
        try await connection { conn in
            try await query(conn, "SELECT DATE_FORMAT(at, \(Self.dateOut)) AS at_s, kind, outcome, reason FROM dashboard_device_event WHERE device_id=? ORDER BY id DESC LIMIT ?",
                            [str(deviceID), MySQLData(int: max(0, limit))]).rows.map {
                DeviceEvent(at: Self.time($0, "at_s"), kind: $0.column("kind")?.string ?? "", outcome: $0.column("outcome")?.string ?? "",
                            reason: $0.column("reason")?.string)
            }
        }
    }

    public func purgeDeviceOps(now: Date) async throws {
        let cutoff = ts(now.addingTimeInterval(-Double(DeviceRetention.commandHours) * 3600))
        try await connection { conn in
            _ = try await query(conn, "DELETE FROM dashboard_command WHERE created_at < ?", [cutoff])
            _ = try await query(conn, "DELETE FROM dashboard_device_event WHERE at < ?", [cutoff])
        }
    }
}
