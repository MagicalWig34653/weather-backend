import Foundation

public enum WarnMsgType: String, Sendable { case alert = "Alert", update = "Update", cancel = "Cancel" }

/// One DWD CAP message (one language). Contains no coordinates and no place names: only warning cell ids.
public struct WarnAlert: Sendable, Equatable {
    public var identifier: String
    public var kind: WarnKind
    public var severity: Int            // 1...4
    public var event: String
    public var msgType: WarnMsgType
    public var references: [String]     // identifiers from <references> ("sender,identifier,sent"), identifier only
    public var sent: Date, onset: Date, expires: Date
    public var headline: String, text: String, instruction: String
    public var lang: String             // "de" | "en"
    public var warncellIDs: [String]    // 9 digits each

    public init(identifier: String, kind: WarnKind, severity: Int, event: String, msgType: WarnMsgType = .alert, references: [String] = [],
                sent: Date, onset: Date, expires: Date, headline: String, text: String, instruction: String = "", lang: String = "de",
                warncellIDs: [String]) {
        self.identifier = identifier; self.kind = kind; self.severity = severity; self.event = event; self.msgType = msgType
        self.references = references; self.sent = sent; self.onset = onset; self.expires = expires; self.headline = headline
        self.text = text; self.instruction = instruction; self.lang = lang; self.warncellIDs = warncellIDs
    }
}

public struct WarnParseResult: Sendable, Equatable {
    public var alerts: [WarnAlert]
    public var ignoredEvents: [String: Int]   // events that are not stored -> count
    public var rejected: Int                  // unreadable / invalid
    public init(alerts: [WarnAlert] = [], ignoredEvents: [String: Int] = [:], rejected: Int = 0) {
        self.alerts = alerts; self.ignoredEvents = ignoredEvents; self.rejected = rejected
    }
}
