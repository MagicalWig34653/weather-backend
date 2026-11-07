import Foundation

/// APNs payload of a warning push. Own short notice only (type and level via `title-loc-key`/`loc-key`, German fallback text):
/// no DWD headline, no DWD description, no source line. The unchanged official warning is only available via
/// `GET /v1/warnings/active` (app warning view). Keys and argument order match `WARN_PUSH_*` in the app's Localizable.strings.
public enum WarnPayload {
    public static let maxPayloadBytes = 1900
    static let bodyKey = "WARN_PUSH_BODY"
    static let bodyFallback = "Tippen für Details."

    /// Localization key and German fallback title format (`%d` = level) per kind.
    static func titleKey(_ kind: WarnKind) -> (key: String, fallback: String) {
        switch kind {
        case .severeWeather: return ("WARN_PUSH_TITLE_SEVERE", "Unwetterhinweis, Stufe")
        case .frost: return ("WARN_PUSH_TITLE_FROST", "Frosthinweis, Stufe")
        case .ice: return ("WARN_PUSH_TITLE_ICE", "Glättehinweis, Stufe")
        }
    }

    /// nil when the size limit cannot be met (cannot happen with the fixed alert).
    public static func make(alert: WarnAlert, subID: String, timeSensitive: Bool) -> String? {
        let t = titleKey(alert.kind)
        let level = String(alert.severity)
        let alertDict: [String: Any] = ["title": "\(t.fallback) \(level)", "body": bodyFallback,
                                        "title-loc-key": t.key, "title-loc-args": [level], "loc-key": bodyKey]
        var aps: [String: Any] = ["alert": alertDict, "sound": "default", "thread-id": subID, "mutable-content": 1]
        if timeSensitive || alert.severity >= 4 { aps["interruption-level"] = "time-sensitive" }
        let object: [String: Any] = ["aps": aps, "type": "warning", "kind": alert.kind.rawValue, "severity": alert.severity,
                                     "sent": TimeUtil.toISO(alert.sent), "warning_id": alert.identifier]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8),
              json.utf8.count <= maxPayloadBytes else { return nil }
        return json
    }

    public static func dedupeKey(subID: String, alertKey: String) -> String { Hashing.sha256Hex(Array((subID + "|" + alertKey).utf8)) }

    public static func collapseID(subID: String, kind: WarnKind) -> String {
        let id = subID + ":" + kind.rawValue
        return id.utf8.count <= 64 ? id : String(id.suffix(64))
    }

    /// Shortens at a character boundary to at most `maxBytes` UTF-8 bytes; a shortened text ends with "…".
    public static func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        let ellipsis = "…"
        let room = maxBytes - ellipsis.utf8.count
        guard room >= 0 else { return "" }
        var out = "", used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > room { break }
            out.append(ch); used += n
        }
        return out + ellipsis
    }
}
