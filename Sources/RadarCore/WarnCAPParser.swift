import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses one DWD CAP 1.2 message (profile 2.1.14). Defensive: broken or unexpected input is counted in `rejected`, never a crash.
/// Only fields needed for the warning feed are read; polygons, coordinates and area names are discarded on purpose.
public enum WarnCAPParser {
    public static let maxIdentifierLength = 160

    public static func parse(xml: Data) -> WarnParseResult {
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.depthOK else { return WarnParseResult(rejected: 1) }
        return delegate.build()
    }

    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func severity(_ text: String) -> Int? {
        ["Minor": 1, "Moderate": 2, "Severe": 3, "Extreme": 4][text]
    }

    private struct RawInfo {
        var language = "", event = "", severity = "", onset = "", effective = "", expires = "", headline = "", description = "", instruction = ""
        var codes: [(name: String, value: String)] = []
        var cells: [String] = []
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var identifier = "", sent = "", msgType = "", status = "", references = ""
        var infos: [RawInfo] = []
        var depthOK = true
        private var path: [String] = []
        private var text = ""
        private var info: RawInfo?
        private var codeName = "", codeValue = ""
        private var geoName = "", geoValue = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            if path.count > 12 { depthOK = false; parser.abortParsing(); return }
            text = ""
            if name == "info" { info = RawInfo() }
            if name == "eventCode" { codeName = ""; codeValue = "" }
            if name == "geocode" { geoName = ""; geoValue = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if text.utf8.count < 65_536 { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8), text.utf8.count < 65_536 { text += s }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast(); text = "" }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            switch (parent, name) {
            case ("alert", "identifier"): identifier = value
            case ("alert", "sent"): sent = value
            case ("alert", "status"): status = value
            case ("alert", "msgType"): msgType = value
            case ("alert", "references"): references = value
            case ("info", "language"): info?.language = value
            case ("info", "event"): info?.event = value
            case ("info", "severity"): info?.severity = value
            case ("info", "onset"): info?.onset = value
            case ("info", "effective"): info?.effective = value
            case ("info", "expires"): info?.expires = value
            case ("info", "headline"): info?.headline = value
            case ("info", "description"): info?.description = value
            case ("info", "instruction"): info?.instruction = value
            case ("eventCode", "valueName"): codeName = value
            case ("eventCode", "value"): codeValue = value
            case ("geocode", "valueName"): geoName = value
            case ("geocode", "value"): geoValue = value
            case ("info", "eventCode"): info?.codes.append((codeName, codeValue))
            case ("area", "geocode"):
                // Only municipality-union cells count; polygon areas carry no geocode and are dropped (no geometry is kept).
                if geoName == "WARNCELLID", geoValue.count == 9, geoValue.allSatisfy({ $0 >= "0" && $0 <= "9" }) { info?.cells.append(geoValue) }
            case ("alert", "info"):
                if let info { infos.append(info) }
                info = nil
            default: break
            }
        }

        func build() -> WarnParseResult {
            var result = WarnParseResult()
            guard !identifier.isEmpty, identifier.count <= WarnCAPParser.maxIdentifierLength,
                  status == "Actual", let type = WarnMsgType(rawValue: msgType), let sentDate = WarnCAPParser.date(sent), !infos.isEmpty
            else { result.rejected = 1; return result }
            let refs: [String] = references.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { entry in
                let parts = entry.split(separator: ",", omittingEmptySubsequences: false)
                return parts.count == 3 && !parts[1].isEmpty ? String(parts[1]) : nil
            }
            for info in infos {
                let ii = info.codes.first { $0.name == "II" }.flatMap { Int($0.value) }
                guard let kind = WarnEventMap.kind(ii: ii, event: info.event) else {
                    result.ignoredEvents[info.event.isEmpty ? "?" : info.event, default: 0] += 1
                    continue
                }
                guard let sev = WarnCAPParser.severity(info.severity) else { result.rejected += 1; continue }
                let onset = WarnCAPParser.date(info.onset) ?? WarnCAPParser.date(info.effective) ?? (type == .cancel ? sentDate : nil)
                let expires = WarnCAPParser.date(info.expires) ?? (type == .cancel ? sentDate : nil)
                var seen = Set<String>()
                let cells = info.cells.filter { seen.insert($0).inserted }
                guard let onset, let expires, expires >= onset, type == .cancel || !cells.isEmpty else { result.rejected += 1; continue }
                let lang = String(info.language.prefix(2)).lowercased()
                guard lang == "de" || lang == "en" else { result.rejected += 1; continue }
                result.alerts.append(WarnAlert(identifier: identifier, kind: kind, severity: sev, event: info.event, msgType: type, references: refs,
                                               sent: sentDate, onset: onset, expires: expires, headline: info.headline, text: info.description,
                                               instruction: info.instruction, lang: lang, warncellIDs: cells))
            }
            return result
        }
    }
}
