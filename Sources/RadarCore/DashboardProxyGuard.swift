import Crypto
import Foundation

/// Shared secret between the reverse proxy and the dashboard listener (header `X-Dashboard-Proxy-Token`).
/// The check is the very first step of every dashboard request (before setup window, static files, login, API) so that
/// third parties reaching the published port learn nothing. Rejections are a plain `404`, never counted by the operator
/// login limits, never logged beyond one aggregated counter.
public struct DashboardProxyGuardError: Error, CustomStringConvertible {
    public let description: String
}

public final class DashboardProxyGuard: Sendable {
    public static let headerName = "X-Dashboard-Proxy-Token"
    public static let minLength = 32
    public static let maxLength = 256
    /// Fixed label of the aggregated counter (no request detail).
    public static let counterLabel = "dash_proxy_reject"

    private let digests: [[UInt8]]
    private let counter = Counter()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var current: Int { lock.withLock { value } }
    }

    /// `tokens` empty means the guard is switched off (only through `DASH_PROXY_TOKEN_REQUIRED=false`).
    public init(tokens: [String]) throws {
        for token in tokens { try Self.validate(token) }
        digests = tokens.map { Array(SHA256.hash(data: Data($0.utf8))) }
    }

    public var isEnabled: Bool { !digests.isEmpty }
    /// Number of rejected requests since start (aggregated, `dash_proxy_reject`).
    public var rejectCount: Int { counter.current }

    static func validate(_ token: String) throws {
        let bytes = Array(token.utf8)
        guard bytes.count >= minLength, bytes.count <= maxLength, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw DashboardProxyGuardError(description: "dashboard proxy token must be \(minLength) to \(maxLength) printable ASCII characters without spaces (e.g. openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')")
        }
    }

    /// Constant effort: both sides are hashed (length hidden) and every configured digest is compared completely.
    public func admits(_ presented: String?) -> Bool {
        guard isEnabled else { return true }
        let candidate = Array(SHA256.hash(data: Data((presented ?? "").utf8)))
        var match: UInt8 = 0
        for digest in digests {
            var diff: UInt8 = 0
            for i in 0..<digest.count { diff |= digest[i] ^ candidate[i] }
            match |= diff == 0 ? 1 : 0
        }
        let ok = match == 1 && presented != nil
        if !ok { counter.increment() }
        return ok
    }

    /// Loads `DASH_PROXY_TOKEN[_FILE]` and `DASH_PROXY_TOKEN_PREVIOUS[_FILE]`; fails closed without a valid token
    /// unless `DASH_PROXY_TOKEN_REQUIRED=false`. Token values are never part of an error message.
    public static func load(env raw: [String: String]) throws -> DashboardProxyGuard {
        let env = raw.filter { !$0.value.isEmpty }
        var tokens: [String] = []
        do {
            for name in ["DASH_PROXY_TOKEN", "DASH_PROXY_TOKEN_PREVIOUS"] {
                let value = try Config.secret(env, name, "")
                if !value.isEmpty { tokens.append(value) }
            }
            return try DashboardProxyGuard(tokens: tokens)
        } catch let error as DashboardProxyGuardError {
            throw DashboardProxyGuardError(description: "DASH_PROXY_TOKEN invalid: \(error.description)")
        }
    }

    /// Startup rule: required and nothing configured aborts; an invalid token always aborts.
    public static func loadForStartup(env: [String: String]) throws -> DashboardProxyGuard {
        let guardian = try load(env: env)
        let required = (env["DASH_PROXY_TOKEN_REQUIRED"].flatMap { $0.isEmpty ? nil : $0 } ?? "true").lowercased() != "false"
        if !guardian.isEnabled && required {
            throw DashboardProxyGuardError(description: "dashboard needs DASH_PROXY_TOKEN_FILE (or DASH_PROXY_TOKEN) with a secret of at least \(minLength) characters that the reverse proxy sends as \(headerName); only DASH_PROXY_TOKEN_REQUIRED=false disables this protection")
        }
        return guardian
    }

    public static let disabledWarning = "WARNUNG: DASH_PROXY_TOKEN_REQUIRED=false und kein Proxy-Token gesetzt: der Dashboard-Port ist ohne Proxy-Header erreichbar"
}
