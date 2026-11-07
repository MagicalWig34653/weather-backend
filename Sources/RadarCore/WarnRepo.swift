import Foundation

public struct WarnStoredAlert: Sendable, Equatable {
    public var alert: WarnAlert
    public var chainID: String
    public var status: String   // "active" | "cancelled" | "superseded"
    public init(alert: WarnAlert, chainID: String, status: String) { self.alert = alert; self.chainID = chainID; self.status = status }
}

public extension WarnAlert {
    /// Identifier without the language suffix (`...DEU` / `...ENG`): shared by the German and English message of one warning.
    var alertKey: String { Self.alertKey(identifier: identifier) }

    static func alertKey(identifier: String) -> String {
        guard let dot = identifier.lastIndex(of: "."), identifier.distance(from: dot, to: identifier.endIndex) == 4 else { return identifier }
        let suffix = identifier[identifier.index(after: dot)...]
        return suffix.allSatisfy({ $0.isASCII && $0.isUppercase }) ? String(identifier[..<dot]) : identifier
    }

    /// Longest value that fits the database column; the DWD texts themselves are not shortened beyond this.
    func clippedForStorage() -> WarnAlert {
        var copy = self
        copy.headline = String(headline.prefix(256)); copy.event = String(event.prefix(64))
        return copy
    }
}

/// Warning storage. Times are passed in by the caller (UTC, second resolution). No coordinates, no place names.
public protocol WarnRepo: Sendable {
    /// Idempotent: stores/updates the message and its warning cells (languages separately). `chainID` = chain of the first known
    /// referenced message, else its own key. A message never revives a cancelled or superseded one; referenced messages become
    /// `superseded`. A `Cancel` message stores nothing and cancels its references (result status `cancelled`).
    func upsertAlert(_ alert: WarnAlert, now: Date) async throws -> WarnStoredAlert
    /// Marks the referenced identifiers (both languages) as cancelled.
    func cancelAlerts(identifiers: [String], now: Date) async throws
    /// Active (not expired, not cancelled, not superseded) warnings, one per warning: the requested language, else the other one.
    func activeAlerts(now: Date, lang: String) async throws -> [WarnStoredAlert]
    func alert(identifier: String) async throws -> WarnStoredAlert?
    /// Removes messages that have been expired or cancelled/superseded for longer than `retention`, with their cells.
    @discardableResult func purgeWarnings(now: Date, retention: TimeInterval) async throws -> Int
    func setWarnFetchedAt(_ date: Date) async throws
    func warnFetchedAt() async throws -> Date?
}
