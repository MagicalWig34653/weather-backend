import Foundation

/// Rate limits for the dashboard (docs/dashboard-plan.md 2.7). No IPs and no per-client keys: all counters are global per replica
/// (in memory, via the existing `RateLimiter`). A passkey cannot be guessed; the limits bound CPU and database load.
/// The failure delay (`recordFailure`) applies to setup only. On login a wrong signature cannot become a right one (P-256,
/// single-use challenge), so a delay would protect nothing but let an anonymous caller lock the operator out (review 6 Nov 2026, M1).
/// Unknown challenge IDs are not failures; they have their own bucket (`challengeProbe`), and `GET /session` has its own (`session`).
public final class DashboardRateLimits: @unchecked Sendable {
    public enum Bucket: String, CaseIterable, Sendable {
        case setupBegin = "global:dash:setup-begin"
        case setupFinish = "global:dash:setup-finish"
        case loginBegin = "global:dash:login-begin"
        case loginFinish = "global:dash:login-finish"
        case configWrite = "global:dash:config-write"
        case restart = "global:dash:restart"
        case other = "global:dash:other"
        case session = "global:dash:session"
        case challengeProbe = "global:dash:challenge-probe"

        /// Allowed calls per minute.
        public var perMinute: Int {
            switch self {
            case .setupBegin, .loginBegin: return 10
            case .setupFinish, .loginFinish: return 5
            case .configWrite: return 30
            case .restart: return 2
            case .session: return 600
            case .other: return 3000
            case .challengeProbe: return 120
            }
        }
    }

    /// Failures before the first delay.
    static let freeFailures = 3
    static let baseDelay: TimeInterval = 5
    static let maxDelay: TimeInterval = 60
    /// Failures are forgotten after this long without a new one.
    static let forgetAfter: TimeInterval = 900

    private let limiter = RateLimiter()
    private let lock = NSLock()
    private var failures = 0
    private var lastFailure: Date?
    private var blockedUntil: Date?
    private let window: TimeInterval = 60

    private let scale: Int

    /// `scale` multiplies the per-minute limits (tests only).
    public init(scale: Int = 1) { self.scale = max(1, scale) }

    /// Counts the call; throws 429 (with `Retry-After`) when the bucket is exhausted. Never keyed by client.
    public func check(_ bucket: Bucket, now: Date) throws {
        guard limiter.allow(bucket.rawValue, limit: bucket.perMinute * scale, window: window, now: now) else {
            throw DashboardAuthError.rateLimited(Int(window))
        }
    }

    /// Throws 429 while the exponential failure delay runs.
    public func checkNotBlocked(now: Date) throws {
        let until: Date? = lock.withLock { blockedUntil }
        if let until, now < until { throw DashboardAuthError.rateLimited(max(1, Int(until.timeIntervalSince(now).rounded(.up)))) }
    }

    /// A failed setup or login attempt: after `freeFailures` failures, each further one doubles the delay (5 s, 10 s, ... 60 s).
    public func recordFailure(now: Date) {
        lock.withLock {
            if let last = lastFailure, now.timeIntervalSince(last) > Self.forgetAfter { failures = 0 }
            failures += 1
            lastFailure = now
            if failures > Self.freeFailures {
                let delay = min(Self.baseDelay * pow(2, Double(failures - Self.freeFailures - 1)), Self.maxDelay)
                blockedUntil = now.addingTimeInterval(delay)
            }
        }
    }

    public func recordSuccess() {
        lock.withLock { failures = 0; lastFailure = nil; blockedUntil = nil }
    }

    public var failureCount: Int { lock.withLock { failures } }
}
