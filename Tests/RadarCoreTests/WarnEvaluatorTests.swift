import Foundation
import Testing
@testable import RadarCore

@Suite("Warn evaluator")
struct WarnEvaluatorTests {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    var onset: Date { now.addingTimeInterval(9 * 3600) }

    func decide(msg: WarnMsgType = .alert, kind: WarnKind = .frost, severity: Int = 1, sent: Date? = nil, expires: Date? = nil,
                cells: [String] = ["814522510"], types: Set<WarnKind> = Set(WarnKind.allCases), enabled: Bool = true,
                min: [WarnKind: Int] = [:], chain: WarnSentRecord? = nil, lastOfKind: WarnSentRecord? = nil) -> WarnDecision {
        let sub = WarnSubscription(id: "s", installationID: "i", input: WarnSubscriptionInput(warncellIDs: ["814522510"], types: types, minSeverity: min, enabled: enabled))
        let alert = WarnAlert(identifier: "A.DEU", kind: kind, severity: severity, event: "E", msgType: msg, sent: sent ?? now.addingTimeInterval(-540),
                              onset: onset, expires: expires ?? now.addingTimeInterval(8 * 3600), headline: "H", text: "T", warncellIDs: cells)
        return WarnEvaluator.decide(sub: sub, alert: alert, chain: chain, lastOfKind: lastOfKind, now: now)
    }

    func rec(kind: WarnKind = .frost, sev: Int, onset: Date? = nil, sentAgo: TimeInterval = 600) -> WarnSentRecord {
        WarnSentRecord(chainID: "A", kind: kind, lastSeverity: sev, lastOnset: onset ?? self.onset, lastSentAt: now.addingTimeInterval(-sentAgo))
    }

    @Test func freshMatchingAlertIsSent() { #expect(decide() == .send) }
    @Test func cancelNeverSends() { #expect(decide(msg: .cancel) == .suppress(.cancel)) }
    @Test func expired() { #expect(decide(expires: now) == .suppress(.expired)) }
    @Test func staleOver20Minutes() { #expect(decide(sent: now.addingTimeInterval(-1201)) == .suppress(.stale)) }
    @Test func exactly20MinutesIsFresh() { #expect(decide(sent: now.addingTimeInterval(-1200)) == .send) }
    @Test func noCellOverlap() { #expect(decide(cells: ["999999999"]) == .suppress(.noMatch)) }
    @Test func typeDisabled() { #expect(decide(types: [.ice]) == .suppress(.typeOff)) }
    @Test func belowThresholdSevereWeatherLevel2() { #expect(decide(kind: .severeWeather, severity: 2) == .suppress(.belowThreshold)) }
    @Test func severeWeatherLevel3Sent() { #expect(decide(kind: .severeWeather, severity: 3) == .send) }
    @Test func iceLevel1SuppressedLevel2Sent() {
        #expect(decide(kind: .ice, severity: 1) == .suppress(.belowThreshold))
        #expect(decide(kind: .ice, severity: 2) == .send)
    }
    @Test func frostDefaultIsLevel1() { #expect(decide(kind: .frost, severity: 1) == .send) }
    @Test func customMinimumOverridesDefault() {
        #expect(decide(kind: .frost, severity: 1, min: [.frost: 2]) == .suppress(.belowThreshold))
        #expect(decide(kind: .severeWeather, severity: 2, min: [.severeWeather: 2]) == .send)
    }
    @Test func updateSameLevelSuppressed() { #expect(decide(chain: rec(sev: 1)) == .suppress(.noChange)) }
    @Test func updateHigherLevelSent() { #expect(decide(severity: 2, chain: rec(sev: 1)) == .send) }
    @Test func updateLowerLevelSuppressed() { #expect(decide(severity: 1, chain: rec(sev: 2)) == .suppress(.noChange)) }
    @Test func updateOtherKindSent() { #expect(decide(kind: .frost, chain: rec(kind: .ice, sev: 1)) == .send) }
    @Test func onsetMoreThanOneHourEarlierSent() { #expect(decide(chain: rec(sev: 1, onset: onset.addingTimeInterval(3601))) == .send) }
    @Test func onsetExactlyOneHourEarlierSuppressed() { #expect(decide(chain: rec(sev: 1, onset: onset.addingTimeInterval(3600))) == .suppress(.noChange)) }
    @Test func laterOnsetSuppressed() { #expect(decide(chain: rec(sev: 1, onset: onset.addingTimeInterval(-7200))) == .suppress(.noChange)) }
    @Test func lockWithinSixtyMinutesSameOrLowerLevel() { #expect(decide(lastOfKind: rec(sev: 1, sentAgo: 600)) == .suppress(.locked)) }
    @Test func higherLevelBreaksLock() { #expect(decide(severity: 2, lastOfKind: rec(sev: 1, sentAgo: 600)) == .send) }
    @Test func lockExpiresAfterSixtyMinutes() { #expect(decide(lastOfKind: rec(sev: 1, sentAgo: 3600)) == .send) }
    @Test func disabledSubscription() { #expect(decide(enabled: false) == .suppress(.disabled)) }
    @Test func reasonLabelsAreFixed() {
        #expect(WarnSuppression.allCases.map(\.rawValue).sorted() == ["belowThreshold", "cancel", "disabled", "expired", "locked", "noChange", "noMatch", "stale", "typeOff"])
    }
}
