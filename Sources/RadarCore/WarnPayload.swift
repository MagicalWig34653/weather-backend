import Foundation

/// APNs payload of a warning push. DWD text unchanged (only shortened), no place name, no coordinates.
public enum WarnPayload {
    public static let maxBodyBytes = 900
    public static let maxPayloadBytes = 1900
    static let maxTitleBytes = 120
    static let sourceLine = "\nQuelle: DWD"

    /// nil when the size limit cannot be met.
    public static func make(alert: WarnAlert, subID: String, timeSensitive: Bool) -> String? {
        let title = truncate(alert.headline, maxBytes: maxTitleBytes)
        var budget = maxBodyBytes - sourceLine.utf8.count
        while budget >= 0 {
            let body = truncate(alert.text, maxBytes: budget) + sourceLine
            var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default", "thread-id": subID, "mutable-content": 1]
            if timeSensitive || alert.severity >= 4 { aps["interruption-level"] = "time-sensitive" }
            let object: [String: Any] = ["aps": aps, "type": "warning", "kind": alert.kind.rawValue, "severity": alert.severity,
                                         "sent": TimeUtil.toISO(alert.sent), "warning_id": alert.identifier]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return nil }
            if json.utf8.count <= maxPayloadBytes { return json }
            budget -= max(1, json.utf8.count - maxPayloadBytes)
        }
        return nil
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
