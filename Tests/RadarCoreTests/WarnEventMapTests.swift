import Testing
@testable import RadarCore

@Suite("Warn event map")
struct WarnEventMapTests {
    static let documentedRowCount = 46

    @Test func frostIsMappedByCodeAndName() {
        #expect(WarnEventMap.kind(ii: 22, event: "FROST") == .frost)
        #expect(WarnEventMap.kind(ii: nil, event: "FROST") == .frost)
        #expect(WarnEventMap.kind(ii: 22, event: "frost") == .frost)  // English feed
    }

    @Test func observedRealCodes() {
        #expect(WarnEventMap.kind(ii: 84, event: "GLÄTTE") == .ice)
        #expect(WarnEventMap.kind(ii: 59, event: "NEBEL") == nil)
    }

    @Test func groupsFollowUserDecision() {
        #expect(WarnEventMap.kind(ii: 31, event: "GEWITTER") == .severeWeather)
        #expect(WarnEventMap.kind(ii: 52, event: "STURMBÖEN") == .severeWeather)
        #expect(WarnEventMap.kind(ii: 63, event: "DAUERREGEN") == .severeWeather)
        #expect(WarnEventMap.kind(ii: 72, event: "STARKER SCHNEEFALL") == .severeWeather)
        #expect(WarnEventMap.kind(ii: 88, event: "TAUWETTER") == .severeWeather)
        #expect(WarnEventMap.kind(ii: 82, event: "STRENGER FROST") == .frost)
        #expect(WarnEventMap.kind(ii: 85, event: "GLATTEIS") == .ice)
        #expect(WarnEventMap.kind(ii: 87, event: "MARKANTE GLÄTTE") == .ice)
    }

    @Test func ignoredAndUnknownEvents() {
        for (ii, ev) in [(246, "UV-INDEX"), (247, "HITZE"), (248, "EXTREME HITZE"), (59, "NEBEL"), (98, "TEST-WARNUNG"),
                         (99, "TEST-UNWETTERWARNUNG"), (13, "STURM"), (999, "UNBEKANNT")] {
            #expect(WarnEventMap.kind(ii: ii, event: ev) == nil, "\(ev)")
        }
        #expect(WarnEventMap.kind(ii: nil, event: "HITZE") == nil)
    }

    @Test func advanceInformationIsNotAWarning() {
        // Same codes as warnings 40/55/65/75/85/89, other event name (table "Vorabinformationen Unwetter").
        for (ii, ev) in [(40, "VORABINFORMATION SCHWERES GEWITTER"), (55, "VORABINFORMATION ORKANBÖEN"),
                         (65, "VORABINFORMATION HEFTIGER / ERGIEBIGER REGEN"), (75, "VORABINFORMATION STARKER SCHNEEFALL / SCHNEEVERWEHUNG"),
                         (85, "VORABINFORMATION GLATTEIS"), (89, "VORABINFORMATION STARKES TAUWETTER")] {
            #expect(WarnEventMap.kind(ii: ii, event: ev) == nil, "\(ev)")
        }
        #expect(WarnEventMap.kind(ii: 85, event: "GLATTEIS") == .ice)
    }

    @Test func everyDocumentedRowIsCovered() {
        #expect(WarnEventMap.rows.count == Self.documentedRowCount)
        #expect(Set(WarnEventMap.rows.map(\.ii)).count == WarnEventMap.rows.count)
        #expect(Set(WarnEventMap.rows.map(\.kind)) == Set(WarnKind.allCases))
    }
}
