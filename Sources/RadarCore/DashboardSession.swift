import Crypto
import Foundation

/// Dashboard sessions, cookie and CSRF logic (docs/dashboard-plan.md 2.5 and 2.6). Framework independent:
/// the Vapor middleware in `Sources/radar/DashboardMiddleware.swift` only translates requests into `DashboardRequestInfo`.
///
/// Only SHA-256 hashes are stored. The cookie value is 256 bits of randomness. The CSRF token is derived from the cookie value
/// (HMAC-SHA256, key = cookie bytes), so a page reload can obtain it again via `GET /dash/api/session` although only its hash
/// is stored; without the cookie it cannot be computed.

public enum DashboardBase64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> [UInt8]? {
        guard text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 })
        else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).map { [UInt8]($0) }
    }
}

/// Constant-time comparison of two byte strings (length is not secret here).
func dashboardConstantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

func dashboardRandom(_ count: Int) -> [UInt8] {
    var rng = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

/// Everything the guards need from a request; header values are taken as sent (no X-Forwarded-* anywhere).
public struct DashboardRequestInfo: Sendable {
    public var method: String
    public var cookieHeader: String?
    public var origin: String?
    public var host: String?
    public var contentType: String?
    public var csrfToken: String?
    /// Value of `X-Dashboard-Proxy-Token` (nil when absent or sent more than once); only read by `DashboardProxyGuard`.
    public var proxyToken: String?
    public init(method: String, cookieHeader: String? = nil, origin: String? = nil, host: String? = nil,
                contentType: String? = nil, csrfToken: String? = nil, proxyToken: String? = nil) {
        self.method = method; self.cookieHeader = cookieHeader; self.origin = origin; self.host = host
        self.contentType = contentType; self.csrfToken = csrfToken; self.proxyToken = proxyToken
    }

    public var isWrite: Bool { !["GET", "HEAD", "OPTIONS"].contains(method.uppercased()) }
}

/// An authenticated session as seen by handlers.
public struct DashboardSessionInfo: Sendable, Equatable {
    public let idHash: [UInt8]
    public let csrfToken: String
    /// SHA-256 of the CSRF token as stored in the database (the comparison happens against this value).
    public let csrfHash: [UInt8]
    public let createdAt: Date
    public let expiresAt: Date
}

public struct DashboardAuthError: Error, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let retryAfter: Int?
    public init(_ status: Int, _ code: String, retryAfter: Int? = nil) {
        self.status = status; self.code = code; self.retryAfter = retryAfter
    }
    public static let unauthorized = DashboardAuthError(401, "unauthorized")
    public static let forbidden = DashboardAuthError(403, "forbidden")
    public static let conflict = DashboardAuthError(409, "conflict")
    public static let validation = DashboardAuthError(400, "validation")
    public static func rateLimited(_ retryAfter: Int) -> DashboardAuthError { DashboardAuthError(429, "rate_limited", retryAfter: retryAfter) }
}

public struct DashboardAuthConfig: Sendable, Equatable {
    /// Exact origin, e.g. `https://dash.example.net` (scheme, host, optional port; no path).
    public var origin: String
    public var rpID: String
    public var rpName = "Showers Dashboard"
    public var sessionHours = 12
    public var idleMinutes = 30
    /// The setup window is open this long after service start while no credential exists (restart reopens it).
    public var setupWindowMinutes = 15

    public init(origin: String, rpID: String, rpName: String = "Showers Dashboard", sessionHours: Int = 12,
                idleMinutes: Int = 30, setupWindowMinutes: Int = 15) {
        self.origin = origin; self.rpID = rpID; self.rpName = rpName
        self.sessionHours = min(max(sessionHours, 1), 72)
        self.idleMinutes = min(max(idleMinutes, 1), 240)
        self.setupWindowMinutes = min(max(setupWindowMinutes, 1), 120)
    }

    /// Reads `DASH_ORIGIN`, `DASH_RP_ID`, `DASH_SESSION_HOURS`, `DASH_IDLE_MINUTES`, `DASH_SETUP_WINDOW_MINUTES`.
    /// Nil when origin or RP ID is missing or the origin is not a plain `scheme://host[:port]`.
    public static func fromEnvironment(_ env: [String: String]) -> DashboardAuthConfig? {
        // Scheme and host are case-insensitive and browsers send the origin in lower case: normalise, or every write would fail with 403.
        guard let rawOrigin = env["DASH_ORIGIN"], !rawOrigin.isEmpty, case let origin = rawOrigin.lowercased(),
              let hostPort = Self.hostPart(ofOrigin: origin) else { return nil }
        // Host without port; IPv6 literals are not usable as RP ID.
        let host = hostPort.hasPrefix("[") ? "" : String(hostPort.split(separator: ":", maxSplits: 1).first ?? "")
        guard !host.isEmpty else { return nil }
        // `DASH_RP_ID` is optional and must be the origin host or one of its parent domains (WebAuthn rule).
        var rp = host
        if let custom = env["DASH_RP_ID"], !custom.isEmpty {
            let lower = custom.lowercased()
            guard host == lower || host.hasSuffix("." + lower) else { return nil }
            rp = lower
        }
        func int(_ key: String, _ fallback: Int) -> Int { env[key].flatMap { Int($0) } ?? fallback }
        return DashboardAuthConfig(origin: origin, rpID: rp, sessionHours: int("DASH_SESSION_HOURS", 12),
                                   idleMinutes: int("DASH_IDLE_MINUTES", 30), setupWindowMinutes: int("DASH_SETUP_WINDOW_MINUTES", 15))
    }

    /// `host[:port]` of an origin, nil when the origin is not `http(s)://host[:port]` without path, query or userinfo.
    static func hostPart(ofOrigin origin: String) -> String? {
        for scheme in ["https://", "http://"] where origin.hasPrefix(scheme) {
            let rest = String(origin.dropFirst(scheme.count))
            guard !rest.isEmpty, !rest.contains("/"), !rest.contains("?"), !rest.contains("#"), !rest.contains("@") else { return nil }
            return rest.lowercased()
        }
        return nil
    }

    var expectedHost: String { Self.hostPart(ofOrigin: origin) ?? "" }
    /// Cookies are only usable over HTTPS (`__Host-` needs `Secure`); a plain-http origin is for local development only.
    var absoluteLifetime: TimeInterval { Double(sessionHours) * 3600 }
    var idleLifetime: TimeInterval { Double(idleMinutes) * 60 }
}

public final class DashboardSessions: Sendable {
    public static let cookieName = "__Host-dash_session"
    private let repo: any DashboardRepo
    private let config: DashboardAuthConfig
    private let clock: @Sendable () -> Date

    public init(repo: any DashboardRepo, config: DashboardAuthConfig, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repo = repo; self.config = config; self.clock = clock
    }

    static func hash(_ text: String) -> [UInt8] { Array(SHA256.hash(data: Array(text.utf8))) }

    static func csrfToken(forCookieValue value: String) -> String {
        let key = SymmetricKey(data: Array(value.utf8))
        return DashboardBase64URL.encode(Array(HMAC<SHA256>.authenticationCode(for: Array("dashboard-csrf-v1".utf8), using: key)))
    }

    /// New session (rotation: every login gets a new random ID). Returns cookie value and CSRF token.
    func create() async throws -> (cookieValue: String, csrfToken: String, expiresAt: Date) {
        let now = clock()
        let value = DashboardBase64URL.encode(dashboardRandom(32))
        let csrf = Self.csrfToken(forCookieValue: value)
        let expires = now.addingTimeInterval(min(config.idleLifetime, config.absoluteLifetime))
        try await repo.createSession(idHash: Self.hash(value), csrfHash: Self.hash(csrf), now: now, expiresAt: expires)
        return (value, csrf, expires)
    }

    /// Extracts a well-formed session cookie value (43 characters Base64URL) from a `Cookie` header.
    public static func cookieValue(fromHeader header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix(cookieName + "=") {
                let value = String(piece.dropFirst(cookieName.count + 1))
                return value.utf8.count == 43 && DashboardBase64URL.decode(value)?.count == 32 ? value : nil
            }
        }
        return nil
    }

    /// Validates the cookie, enforces absolute lifetime and idle timeout and slides the expiry.
    func validate(cookieValue: String?) async throws -> DashboardSessionInfo? {
        guard let cookieValue, cookieValue.utf8.count == 43 else { return nil }
        let now = clock()
        let idHash = Self.hash(cookieValue)
        guard let record = try await repo.session(idHash: idHash, now: now) else { return nil }
        let absoluteEnd = record.createdAt.addingTimeInterval(config.absoluteLifetime)
        guard now < absoluteEnd, now.timeIntervalSince(record.lastSeenAt) < config.idleLifetime else {
            try await repo.deleteSession(idHash: idHash)
            return nil
        }
        let newExpiry = min(absoluteEnd, now.addingTimeInterval(config.idleLifetime))
        guard try await repo.touchSession(idHash: idHash, now: now, expiresAt: newExpiry) else { return nil }
        return DashboardSessionInfo(idHash: idHash, csrfToken: Self.csrfToken(forCookieValue: cookieValue),
                                    csrfHash: record.csrfHash, createdAt: record.createdAt, expiresAt: newExpiry)
    }

    func destroy(cookieValue: String?) async throws {
        guard let cookieValue, cookieValue.utf8.count == 43 else { return }
        try await repo.deleteSession(idHash: Self.hash(cookieValue))
    }

    /// `Set-Cookie` value. `__Host-` requires Secure, Path=/ and no Domain.
    public func setCookieHeader(value: String) -> String {
        "\(Self.cookieName)=\(value); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=\(Int(config.absoluteLifetime))"
    }

    public func clearCookieHeader() -> String {
        "\(Self.cookieName)=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"
    }

    // MARK: guards

    /// DNS-rebinding protection: the Host header must be the host of `DASH_ORIGIN` (all requests).
    public func checkHost(_ req: DashboardRequestInfo) throws {
        guard let host = req.host?.lowercased(), host == config.expectedHost else { throw DashboardAuthError.forbidden }
    }

    /// Writes need `Origin == DASH_ORIGIN` and a JSON content type (a simple form post cannot send it cross-site).
    public func checkWriteOrigin(_ req: DashboardRequestInfo) throws {
        try checkHost(req)
        guard req.isWrite else { return }
        guard req.origin == config.origin else { throw DashboardAuthError.forbidden }
        guard let type = req.contentType?.lowercased(), type == "application/json" || type.hasPrefix("application/json;") else {
            throw DashboardAuthError.forbidden
        }
    }

    /// Session check (401 without a valid session). Does not check CSRF.
    public func authenticate(_ req: DashboardRequestInfo) async throws -> DashboardSessionInfo {
        try checkHost(req)
        guard let session = try await validate(cookieValue: Self.cookieValue(fromHeader: req.cookieHeader)) else {
            throw DashboardAuthError.unauthorized
        }
        return session
    }

    /// Full check for state-changing session routes: host, origin, content type and `X-CSRF-Token` (constant time).
    public func authorizeWrite(_ req: DashboardRequestInfo, session: DashboardSessionInfo) throws {
        try checkWriteOrigin(req)
        guard req.isWrite else { return }
        guard let token = req.csrfToken, dashboardConstantTimeEquals(Self.hash(token), session.csrfHash) else {
            throw DashboardAuthError.forbidden
        }
    }
}
