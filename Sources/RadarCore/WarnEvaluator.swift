import Foundation

public enum WarnSuppression: String, Sendable, CaseIterable { case cancel, expired, stale, noMatch, typeOff, belowThreshold, noChange, locked, disabled }
public enum WarnDecision: Sendable, Equatable { case send, suppress(WarnSuppression) }

/// Pure decision whether one warning message becomes a push for one warning subscription (no I/O).
/// Rules (decisions 7 Nov 2026): fresh (sent <= 20 min, not expired), area and type match, level at least the minimum; an update
/// only on a higher level, another type or an onset more than 1 h earlier; 60 min lock per (subscription, type), a higher level
/// breaks it; cancel and expiry never push.
public enum WarnEvaluator {
    public static let maxAge: TimeInterval = PushEvaluator.maxRunAge
    public static let repeatLock: TimeInterval = PushEvaluator.repeatLock
    public static let earlierOnset: TimeInterval = 3600
    public static let defaultMinSeverity: [WarnKind: Int] = [.severeWeather: 3, .frost: 1, .ice: 2]

    /// `chain`: last send of this warning chain to the subscription; `lastOfKind`: last send of any chain of the same type.
    public static func decide(sub: WarnSubscription, alert: WarnAlert, chain: WarnSentRecord?, lastOfKind: WarnSentRecord?, now: Date) -> WarnDecision {
        let input = sub.input
        guard input.enabled else { return .suppress(.disabled) }
        if alert.msgType == .cancel { return .suppress(.cancel) }
        if alert.expires <= now { return .suppress(.expired) }
        if now.timeIntervalSince(alert.sent) > maxAge { return .suppress(.stale) }
        guard !Set(input.warncellIDs).isDisjoint(with: alert.warncellIDs) else { return .suppress(.noMatch) }
        guard input.types.contains(alert.kind) else { return .suppress(.typeOff) }
        let minimum = input.minSeverity[alert.kind] ?? defaultMinSeverity[alert.kind] ?? 1
        guard alert.severity >= minimum else { return .suppress(.belowThreshold) }
        if let chain {
            let higher = alert.severity > chain.lastSeverity
            let otherKind = alert.kind != chain.kind
            let earlier = chain.lastOnset.timeIntervalSince(alert.onset) > earlierOnset
            if !(higher || otherKind || earlier) { return .suppress(.noChange) }
        }
        if let last = lastOfKind, now.timeIntervalSince(last.lastSentAt) < repeatLock, alert.severity <= last.lastSeverity {
            return .suppress(.locked)
        }
        return .send
    }
}
