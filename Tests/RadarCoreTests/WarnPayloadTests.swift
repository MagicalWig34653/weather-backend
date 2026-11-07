import Foundation
import Testing
@testable import RadarCore

@Suite("Warn payload")
struct WarnPayloadTests {
    let sent = Date(timeIntervalSince1970: 1_794_000_000)

    func alert(text: String = "Es tritt Frost auf.", headline: String = "Amtliche WARNUNG vor FROST", severity: Int = 1) -> WarnAlert {
        WarnAlert(identifier: "A.DEU", kind: .frost, severity: severity, event: "FROST", sent: sent, onset: sent, expires: sent.addingTimeInterval(3600),
                  headline: headline, text: text, warncellIDs: ["814522510"])
    }

    func object(_ json: String?) throws -> [String: Any] {
        let text = try #require(json)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func structureFollowsTheContract() throws {
        let o = try object(WarnPayload.make(alert: alert(), subID: "sub-1", timeSensitive: false))
        let aps = try #require(o["aps"] as? [String: Any])
        let a = try #require(aps["alert"] as? [String: Any])
        #expect(a["title"] as? String == "Amtliche WARNUNG vor FROST")
        #expect(a["body"] as? String == "Es tritt Frost auf.\nQuelle: DWD")
        #expect(aps["sound"] as? String == "default" && aps["thread-id"] as? String == "sub-1" && aps["mutable-content"] as? Int == 1)
        #expect(aps["interruption-level"] == nil)
        #expect(o["type"] as? String == "warning" && o["kind"] as? String == "frost" && o["severity"] as? Int == 1)
        #expect(o["warning_id"] as? String == "A.DEU" && o["sent"] as? String == TimeUtil.toISO(sent))
    }

    @Test func timeSensitiveOnlyForLevel4OrSwitch() throws {
        func level(_ a: WarnAlert, _ ts: Bool) throws -> Any? { try (object(WarnPayload.make(alert: a, subID: "s", timeSensitive: ts))["aps"] as? [String: Any])?["interruption-level"] }
        #expect(try level(alert(severity: 3), false) == nil)
        #expect(try level(alert(severity: 3), true) as? String == "time-sensitive")
        #expect(try level(alert(severity: 4), false) as? String == "time-sensitive")
    }

    @Test func bodyAndTotalSizeAreBounded() throws {
        let long = String(repeating: "Ä", count: 3000)
        let json = try #require(WarnPayload.make(alert: alert(text: long, headline: String(repeating: "ß", count: 400)), subID: UUID().uuidString.lowercased(), timeSensitive: true))
        #expect(json.utf8.count <= WarnPayload.maxPayloadBytes)
        let a = try #require((try object(json)["aps"] as? [String: Any])?["alert"] as? [String: Any])
        let body = try #require(a["body"] as? String)
        #expect(body.utf8.count <= WarnPayload.maxBodyBytes && body.hasSuffix("\nQuelle: DWD") && body.contains("…"))
        #expect((a["title"] as? String ?? "").utf8.count <= 120)
    }

    @Test func truncationKeepsCharacterBoundaries() {
        #expect(WarnPayload.truncate("abc", maxBytes: 10) == "abc")
        let cut = WarnPayload.truncate("ääää", maxBytes: 5)   // 2 bytes each; "…" is 3 bytes
        #expect(cut == "ä…" && cut.utf8.count <= 5)
        let emoji = WarnPayload.truncate("⚠️⚠️⚠️⚠️", maxBytes: 9)
        #expect(emoji.utf8.count <= 9 && emoji.hasSuffix("…"))
        #expect(WarnPayload.truncate("abc", maxBytes: 0) == "")
    }

    @Test func dedupeAndCollapseIDs() {
        let key = WarnPayload.dedupeKey(subID: "s1", alertKey: "K")
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit) && key == WarnPayload.dedupeKey(subID: "s1", alertKey: "K"))
        #expect(key != WarnPayload.dedupeKey(subID: "s2", alertKey: "K") && key != WarnPayload.dedupeKey(subID: "s1", alertKey: "L"))
        let sub = UUID().uuidString.lowercased()
        #expect(WarnPayload.collapseID(subID: sub, kind: .severeWeather).utf8.count <= 64)
        #expect(WarnPayload.collapseID(subID: "s", kind: .frost) == "s:frost")
    }
}
