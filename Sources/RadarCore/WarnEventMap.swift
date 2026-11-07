import Foundation

public enum WarnKind: String, Sendable, CaseIterable, Codable {
    case severeWeather = "severe_weather"
    case frost
    case ice
}

/// Event code (`eventCode II`) to warning type. Source: DWD "Warnungen und Codes" (warning_codes.pdf, Stand 01.02.2024), table WW/WU,
/// cross-checked against real feed messages on 7 Nov 2026 (see docs/research/warnungen-ereigniscodes.md).
/// Fail-closed: everything not listed here (heat, UV, fog, test warnings, coast/sea, advance information) is not stored.
public enum WarnEventMap {
    public struct Row: Sendable { public let ii: Int; public let event: String; public let kind: WarnKind }

    private static func r(_ ii: Int, _ event: String, _ kind: WarnKind) -> Row { Row(ii: ii, event: event, kind: kind) }

    /// One row per entry of the documented WW/WU table that maps to a stored type. Ignored events are not listed.
    public static let rows: [Row] = [
        // Thunderstorm
        r(31, "GEWITTER", .severeWeather), r(33, "STARKES GEWITTER", .severeWeather), r(34, "STARKES GEWITTER", .severeWeather),
        r(36, "STARKES GEWITTER", .severeWeather), r(38, "STARKES GEWITTER", .severeWeather),
        r(40, "SCHWERES GEWITTER mit ORKANBÖEN", .severeWeather), r(41, "SCHWERES GEWITTER mit EXTREMEN ORKANBÖEN", .severeWeather),
        r(42, "SCHWERES GEWITTER mit HEFTIGEM STARKREGEN", .severeWeather),
        r(44, "SCHWERES GEWITTER mit ORKANBÖEN und HEFTIGEM STARKREGEN", .severeWeather),
        r(45, "SCHWERES GEWITTER mit EXTREMEN ORKANBÖEN und HEFTIGEM STARKREGEN", .severeWeather),
        r(46, "SCHWERES GEWITTER mit HEFTIGEM STARKREGEN und HAGEL", .severeWeather),
        r(48, "SCHWERES GEWITTER mit ORKANBÖEN, HEFTIGEM STARKREGEN und HAGEL", .severeWeather),
        r(49, "SCHWERES GEWITTER mit EXTREMEN ORKANBÖEN, HEFTIGEM STARKREGEN und HAGEL", .severeWeather),
        r(90, "GEWITTER", .severeWeather), r(91, "STARKES GEWITTER", .severeWeather), r(92, "SCHWERES GEWITTER", .severeWeather),
        r(93, "EXTREMES GEWITTER", .severeWeather),
        r(95, "SCHWERES GEWITTER mit EXTREM HEFTIGEM STARKREGEN und HAGEL", .severeWeather),
        r(96, "EXTREMES GEWITTER mit ORKANBÖEN, EXTREM HEFTIGEM STARKREGEN und HAGEL", .severeWeather),
        // Wind
        r(51, "WINDBÖEN", .severeWeather), r(52, "STURMBÖEN", .severeWeather), r(53, "SCHWERE STURMBÖEN", .severeWeather),
        r(54, "ORKANARTIGE BÖEN", .severeWeather), r(55, "ORKANBÖEN", .severeWeather), r(56, "EXTREME ORKANBÖEN", .severeWeather),
        // Rain
        r(61, "STARKREGEN", .severeWeather), r(62, "HEFTIGER STARKREGEN", .severeWeather), r(63, "DAUERREGEN", .severeWeather),
        r(64, "ERGIEBIGER DAUERREGEN", .severeWeather), r(65, "EXTREM ERGIEBIGER DAUERREGEN", .severeWeather),
        r(66, "EXTREM HEFTIGER STARKREGEN", .severeWeather),
        // Snow
        r(70, "LEICHTER SCHNEEFALL", .severeWeather), r(71, "SCHNEEFALL", .severeWeather), r(72, "STARKER SCHNEEFALL", .severeWeather),
        r(73, "EXTREM STARKER SCHNEEFALL", .severeWeather), r(74, "SCHNEEVERWEHUNG", .severeWeather),
        r(75, "STARKE SCHNEEVERWEHUNG", .severeWeather), r(76, "EXTREM STARKE SCHNEEVERWEHUNG", .severeWeather),
        // Thaw
        r(88, "TAUWETTER", .severeWeather), r(89, "STARKES TAUWETTER", .severeWeather),
        // Frost
        r(22, "FROST", .frost), r(82, "STRENGER FROST", .frost),
        // Ice
        r(84, "GLÄTTE", .ice), r(85, "GLATTEIS", .ice), r(86, "EXTREMES GLATTEIS", .ice), r(87, "MARKANTE GLÄTTE", .ice),
    ]

    /// Codes that the DWD table also uses for the "Vorabinformation Unwetter" (WP) with a different event name. For them the
    /// event name must match a row exactly; otherwise advance information would be stored as a warning.
    static let ambiguousCodes: Set<Int> = [40, 55, 65, 75, 85, 89]

    private static let byCode: [Int: Row] = Dictionary(rows.map { ($0.ii, $0) }, uniquingKeysWith: { a, _ in a })
    private static let byName: [String: WarnKind] = Dictionary(rows.map { ($0.event.uppercased(), $0.kind) }, uniquingKeysWith: { a, _ in a })

    /// nil = event is not stored in v1. The English feed carries English event names, so the code decides; only the
    /// ambiguous codes need the German name (an English alert with such a code is ignored, the German one is stored).
    public static func kind(ii: Int?, event: String) -> WarnKind? {
        let name = event.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let ii {
            guard let row = byCode[ii] else { return nil }
            if ambiguousCodes.contains(ii) { return row.event.uppercased() == name ? row.kind : nil }
            return row.kind
        }
        return byName[name]
    }
}
