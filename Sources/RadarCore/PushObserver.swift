import Foundation

// Push pipeline observation (WP11b). Everything here is a fixed enumeration: no tokens, installation or subscription ids,
// cells, coordinates or free text ever reach a counter. The service reports events, the observer turns them into counters.

/// What caused (or would have caused) a start. `raining_now` is part of the dashboard contract but is not produced by the
/// alert automaton (it never alerts while it already rains); the Live Activity variant `la_raining_now` is.
public enum PushTrigger: String, Sendable, CaseIterable {
    case rainStart = "rain_start", rainingNow = "raining_now", laRainStart = "la_rain_start", laRainingNow = "la_raining_now"
}

/// Why a start did not happen. The first eight are the dashboard contract; `env_not_allowed`, `unknown_pixel`,
/// `no_fresh_run`, `incomplete_run` and `paused` extend it (documented in docs/status.md, WP11b).
public enum PushSkipReason: String, Sendable, CaseIterable {
    case lock60min = "lock_60min", hysteresis, noStartToken = "no_start_token", activitySlotBusy = "activity_slot_busy"
    case reservationPending = "reservation_pending", notEnabled = "not_enabled", budgetExhausted = "budget_exhausted"
    case belowThreshold = "below_threshold"
    case envNotAllowed = "env_not_allowed", unknownPixel = "unknown_pixel", noFreshRun = "no_fresh_run"
    case incompleteRun = "incomplete_run", paused
}

/// Kind of one APNs request.
public enum PushSendKind: String, Sendable, CaseIterable { case alert, start, update, end }

/// Live Activity lifecycle step; `expire` = ended by the server (eight-hour deadline, opt-out, stale reservation).
public enum PushLifecycle: String, Sendable, CaseIterable { case start, update, end, expire }

public enum PushOutcome: String, Sendable, CaseIterable { case delivered, rejected, retry, dropped }

public enum PushTokenKind: String, Sendable, CaseIterable { case device, start, activity }
public enum PushTokenCause: String, Sendable, CaseIterable { case gone = "410", badDeviceToken = "bad_device_token", other }

/// APNs reason strings. Source: Apple "Handling notification responses from APNs" (developer.apple.com, checked 6 Nov 2026
/// against the page's published data): 31 reasons. Everything else is `other`.
public enum ApnsReason {
    public static let known: [String] = [
        "BadCertificate", "BadCertificateEnvironment", "BadCollapseId", "BadDeviceToken", "BadEnvironmentKeyIdInToken",
        "BadExpirationDate", "BadMessageId", "BadPath", "BadPriority", "BadTopic", "DeviceTokenNotForTopic", "DuplicateHeaders",
        "ExpiredProviderToken", "ExpiredToken", "Forbidden", "IdleTimeout", "InternalServerError", "InvalidProviderToken",
        "InvalidPushType", "MethodNotAllowed", "MissingDeviceToken", "MissingProviderToken", "MissingTopic", "PayloadEmpty",
        "PayloadTooLarge", "ServiceUnavailable", "Shutdown", "TooManyProviderTokenUpdates", "TooManyRequests", "TopicDisallowed",
        "Unregistered",
    ]
    static let knownSet = Set(known)
    /// Fallback when only an HTTP status is known (empty reason body).
    static let byStatus: [String: String] = ["429": "TooManyRequests", "500": "InternalServerError", "503": "ServiceUnavailable"]

    /// Maps a reason as carried by `ApnsResult` (`BadDeviceToken`, `400 PayloadTooLarge`, `503`, `transport`) to a fixed label.
    public static func normalize(_ raw: String) -> String {
        let word = raw.split(separator: " ").last.map(String.init) ?? ""
        if knownSet.contains(word) { return word }
        return byStatus[word] ?? "other"
    }
}

/// Narrow seam between `PushService`/`PushApi` and the statistics (docs/dashboard-insights-plan.md WP11).
public protocol PushObserver: Sendable {
    /// A start decision of an evaluation run (counted after the run was committed).
    func triggered(_ trigger: PushTrigger, by: Int)
    /// A start that did not happen. `trigger == nil`: run-level reason (`no_fresh_run`, `incomplete_run`, `paused`).
    func skipped(_ trigger: PushTrigger?, _ reason: PushSkipReason, by: Int)
    func outboxCreated(_ count: Int)
    /// Result of one APNs request. `reason` is the raw APNs reason of a failure (normalised here). `expire`: the server ended
    /// the activity (deadline, opt-out, stale reservation) instead of a radar-driven `end`.
    func sent(kind: PushSendKind, env: PushEnvironment, outcome: PushOutcome, reason: String?, expire: Bool)
    /// One more attempt of an alert (retries count again): average attempts = attempts / terminal alerts.
    func alertAttempt()
    /// Outbox item dropped without a send result (expired, environment not allowed, retries exhausted).
    func alertDropped()
    func tokenInvalidated(_ kind: PushTokenKind, _ cause: PushTokenCause)
    func reservationExpired()
    /// Rejected registration request (`PushApi`), fixed codes only.
    func apiRejected(_ code: String)
}

extension PushObserver {
    func sent(kind: PushSendKind, env: PushEnvironment, outcome: PushOutcome, reason: String?) {
        sent(kind: kind, env: env, outcome: outcome, reason: reason, expire: false)
    }
}

public struct NoPushObserver: PushObserver {
    public init() {}
    public func triggered(_ trigger: PushTrigger, by: Int) {}
    public func skipped(_ trigger: PushTrigger?, _ reason: PushSkipReason, by: Int) {}
    public func outboxCreated(_ count: Int) {}
    public func sent(kind: PushSendKind, env: PushEnvironment, outcome: PushOutcome, reason: String?, expire: Bool) {}
    public func alertAttempt() {}
    public func alertDropped() {}
    public func tokenInvalidated(_ kind: PushTokenKind, _ cause: PushTokenCause) {}
    public func reservationExpired() {}
    public func apiRejected(_ code: String) {}
}

/// Counters (all through `StatsCollector`, which re-validates every label against `StatsCollector.pushLabelRules`):
/// `push_trigger{trigger}`, `push_skipped{trigger|run:reason}`, `push_created`, `push_attempt`, `push_sent{delivered}`,
/// `push_failed{rejected|retry|dropped}` (alerts), `la_event{event:outcome}`, `apns_error{kind:reason:env}`,
/// `token_invalidated{kind:cause}`, `la_reservation{expired}`, `push_api_reject{code}`.
public struct StatsPushObserver: PushObserver {
    let stats: any StatsSink
    public init(stats: any StatsSink) { self.stats = stats }

    public func triggered(_ trigger: PushTrigger, by: Int) { stats.record("push_trigger", label: trigger.rawValue, by: by) }
    public func skipped(_ trigger: PushTrigger?, _ reason: PushSkipReason, by: Int) {
        stats.record("push_skipped", label: (trigger?.rawValue ?? "run") + ":" + reason.rawValue, by: by)
    }
    public func outboxCreated(_ count: Int) { stats.record("push_created", label: "", by: count) }
    public func sent(kind: PushSendKind, env: PushEnvironment, outcome: PushOutcome, reason: String?, expire: Bool) {
        let normalized = reason.map(ApnsReason.normalize)
        if outcome != .delivered, let normalized { stats.record("apns_error", label: "\(kind.rawValue):\(normalized):\(env.rawValue)") }
        if kind == .alert {
            if outcome == .delivered { stats.record("push_sent", label: "delivered") }
            else { stats.record("push_failed", label: normalized == "Unregistered" ? "unregistered" : outcome.rawValue) }
        } else {
            stats.record("la_event", label: "\(expire ? PushLifecycle.expire.rawValue : kind.rawValue):\(outcome.rawValue)")
        }
    }
    public func alertAttempt() { stats.record("push_attempt", label: "") }
    public func alertDropped() { stats.record("push_failed", label: "dropped") }
    public func tokenInvalidated(_ kind: PushTokenKind, _ cause: PushTokenCause) {
        stats.record("token_invalidated", label: "\(kind.rawValue):\(cause.rawValue)")
    }
    public func reservationExpired() { stats.record("la_reservation", label: "expired") }
    public func apiRejected(_ code: String) { stats.record("push_api_reject", label: code) }
}

extension StatsCollector {
    public static let pushApiRejectCodes = ["server_full", "activity_full", "region_limit", "subscription_limit", "start_token_required", "unauthorized"]

    /// Label sets of the push metrics (merged into `labelRules`).
    static var pushLabelRules: [String: LabelRule] {
        let triggers = PushTrigger.allCases.map(\.rawValue)
        let reasons = PushSkipReason.allCases.map(\.rawValue)
        let apnsReasons = ApnsReason.known + ["other"]
        let kinds = PushSendKind.allCases.map(\.rawValue)
        let envs = PushEnvironment.allCases.map(\.rawValue)
        return [
            "push_trigger": .fixed(Set(triggers)),
            "push_skipped": .fixed(Set((triggers + ["run"]).flatMap { t in reasons.map { t + ":" + $0 } })),
            "push_created": .fixed([""]),
            "push_attempt": .fixed([""]),
            "la_event": .fixed(Set(PushLifecycle.allCases.flatMap { e in PushOutcome.allCases.map { e.rawValue + ":" + $0.rawValue } })),
            "apns_error": .fixed(Set(kinds.flatMap { k in apnsReasons.flatMap { r in envs.map { "\(k):\(r):\($0)" } } })),
            "token_invalidated": .fixed(Set(PushTokenKind.allCases.flatMap { k in PushTokenCause.allCases.map { k.rawValue + ":" + $0.rawValue } })),
            "la_reservation": .fixed(["expired"]),
            "push_api_reject": .fixed(Set(pushApiRejectCodes)),
        ]
    }
}

/// Events of one evaluation run, collected while the pages are processed and emitted only after the run was committed
/// (an incomplete or lost run must not leave counters behind).
struct PushEventBuffer {
    private var triggers: [PushTrigger: Int] = [:]
    private var skips: [SkipKey: Int] = [:]
    private struct SkipKey: Hashable { let trigger: PushTrigger?; let reason: PushSkipReason }
    var isEmpty: Bool { triggers.isEmpty && skips.isEmpty }

    mutating func trigger(_ trigger: PushTrigger) { triggers[trigger, default: 0] += 1 }
    mutating func skip(_ trigger: PushTrigger?, _ reason: PushSkipReason, by: Int = 1) { skips[SkipKey(trigger: trigger, reason: reason), default: 0] += by }
    mutating func discard() { triggers = [:]; skips = [:] }

    func emit(to observer: any PushObserver) {
        for (trigger, count) in triggers { observer.triggered(trigger, by: count) }
        for (key, count) in skips { observer.skipped(key.trigger, key.reason, by: count) }
    }
}
