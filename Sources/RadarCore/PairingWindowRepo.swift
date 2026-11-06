import Foundation
import MySQLKit

/// Pairing window (decision 6.11.2026): the operator opens it in the dashboard, only then does the app route hand out link codes.
/// Stored in `push_state` (`device_pairing_until`, UTC, no new table), so every replica sees it. An expired window counts as closed;
/// the comparison uses the caller's clock (replica clock skew of a few seconds moves the end by that much, nothing more).
public protocol PairingWindowRepo: Sendable {
    /// End of the open window; nil when none is open or it has expired.
    func pairingWindowEnd(now: Date) async throws -> Date?
    func openPairingWindow(until: Date) async throws
    /// True when a still-open window was closed.
    @discardableResult func closePairingWindow(now: Date) async throws -> Bool
}

extension MemoryRepo: PairingWindowRepo {
    public func pairingWindowEnd(now: Date) async throws -> Date? { deviceStore.pairingUntil.flatMap { $0 > now ? $0 : nil } }
    public func openPairingWindow(until: Date) async throws { deviceStore.pairingUntil = until }
    public func closePairingWindow(now: Date) async throws -> Bool {
        defer { deviceStore.pairingUntil = nil }
        return deviceStore.pairingUntil.map { $0 > now } ?? false
    }
}

extension MariaRepo: PairingWindowRepo {
    public func pairingWindowEnd(now: Date) async throws -> Date? {
        try await connection { conn in
            try await query(conn, "SELECT value FROM push_state WHERE name='device_pairing_until'").rows.first?.column("value")?.string
                .flatMap(TimeUtil.fromSQL).flatMap { $0 > now ? $0 : nil }
        }
    }

    public func openPairingWindow(until: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "INSERT INTO push_state (name, value) VALUES ('device_pairing_until', ?) ON DUPLICATE KEY UPDATE value=VALUES(value)",
                                [MySQLData(string: TimeUtil.toSQL(until))])
        }
    }

    public func closePairingWindow(now: Date) async throws -> Bool {
        try await transaction { conn in
            let value = try await query(conn, "SELECT value FROM push_state WHERE name='device_pairing_until' FOR UPDATE").rows.first?.column("value")?.string
            _ = try await query(conn, "DELETE FROM push_state WHERE name='device_pairing_until'")
            return value.flatMap(TimeUtil.fromSQL).map { $0 > now } ?? false
        }
    }
}
