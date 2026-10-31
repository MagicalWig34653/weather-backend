import Crypto
import Foundation

public struct ApnsRequest: Sendable, Equatable {
    public var tokenHex: String
    public var env: PushEnvironment
    public var topic: String
    public var payload: [UInt8]
    public var collapseID: String
    /// UNIX seconds; the notification is useless after this moment.
    public var expiration: Int
    public init(tokenHex: String, env: PushEnvironment, topic: String, payload: [UInt8], collapseID: String, expiration: Int) {
        self.tokenHex = tokenHex; self.env = env; self.topic = topic; self.payload = payload
        self.collapseID = collapseID; self.expiration = expiration
    }
}

public enum ApnsResult: Sendable, Equatable {
    case delivered
    /// 410 (Unregistered/ExpiredToken): the token is dead, delete the installation.
    case unregistered
    /// 400 BadDeviceToken / DeviceTokenNotForTopic: drop this message only (could be a configuration or environment error).
    case badToken(String)
    /// 403, 429, 5xx, network: try again later with backoff.
    case retry(String)
    /// Any other permanent refusal: drop the message.
    case rejected(String)
}

/// Sender behind a protocol: the radar service never talks to Apple directly (tests use `FakeApnsSender`).
public protocol ApnsSender: Sendable {
    func send(_ request: ApnsRequest) async -> ApnsResult
}

/// Scriptable fake: answers per call in order (then `defaultResult`) and records every request.
public actor FakeApnsSender: ApnsSender {
    public private(set) var requests: [ApnsRequest] = []
    private var script: [ApnsResult]
    private let defaultResult: ApnsResult
    public init(script: [ApnsResult] = [], defaultResult: ApnsResult = .delivered) {
        self.script = script; self.defaultResult = defaultResult
    }
    public func send(_ request: ApnsRequest) async -> ApnsResult {
        requests.append(request)
        return script.isEmpty ? defaultResult : script.removeFirst()
    }
}

/// Used when push is disabled or no key is configured: never sends.
public struct DisabledApnsSender: ApnsSender {
    public init() {}
    public func send(_ request: ApnsRequest) async -> ApnsResult { .retry("apns disabled") }
}

public struct ApnsHTTPRequest: Sendable, Equatable {
    public var url: String
    public var headers: [(String, String)]
    public var body: [UInt8]
    public static func == (a: ApnsHTTPRequest, b: ApnsHTTPRequest) -> Bool {
        a.url == b.url && a.body == b.body && a.headers.map { "\($0.0)=\($0.1)" } == b.headers.map { "\($0.0)=\($0.1)" }
    }
}

public struct ApnsHTTPResponse: Sendable {
    public var status: Int
    public var body: [UInt8]
    public init(status: Int, body: [UInt8]) { self.status = status; self.body = body }
}

/// HTTP/2 POST to Apple. The real implementation (AsyncHTTPClient) lives in the executable target.
public protocol ApnsTransport: Sendable {
    func perform(_ request: ApnsHTTPRequest) async throws -> ApnsHTTPResponse
}

/// Token-based APNs client (ES256 JWT, `.p8` key). Request format and error mapping follow Apple's documentation
/// (see the App repo research push-benachrichtigungen.md, section 3.5). NOT yet exercised against the real service.
public final class ApnsClient: ApnsSender, @unchecked Sendable {
    /// Apple: a provider token may be refreshed at most every 20 minutes and must be renewed within 60 minutes.
    public static let tokenLifetime: TimeInterval = 40 * 60
    let key: P256.Signing.PrivateKey
    let keyID: String
    let teamID: String
    let topic: String
    let transport: any ApnsTransport
    let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedJWT: (token: String, issuedAt: Date)?

    public init(keyPEM: String, keyID: String, teamID: String, topic: String, transport: any ApnsTransport,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        self.keyID = keyID; self.teamID = teamID; self.topic = topic; self.transport = transport; self.clock = clock
    }

    static func base64URL(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func makeJWT(issuedAt: Date) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        let signingInput = Self.base64URL(Array(header.utf8)) + "." + Self.base64URL(Array(claims.utf8))
        let signature = try key.signature(for: Array(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    func jwt() throws -> String {
        let now = clock()
        return try lock.withLock {
            if let cachedJWT, now.timeIntervalSince(cachedJWT.issuedAt) < Self.tokenLifetime { return cachedJWT.token }
            let token = try makeJWT(issuedAt: now)
            cachedJWT = (token, now)
            return token
        }
    }

    func invalidateJWT() { lock.withLock { cachedJWT = nil } }

    static func host(_ env: PushEnvironment) -> String {
        env == .production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com"
    }

    func httpRequest(_ request: ApnsRequest, jwt: String) -> ApnsHTTPRequest {
        ApnsHTTPRequest(
            url: "\(Self.host(request.env))/3/device/\(request.tokenHex)",
            headers: [("authorization", "bearer \(jwt)"), ("apns-topic", topic), ("apns-push-type", "alert"), ("apns-priority", "10"),
                      ("apns-expiration", String(request.expiration)), ("apns-collapse-id", request.collapseID),
                      ("content-type", "application/json")],
            body: request.payload)
    }

    static func reason(_ body: [UInt8]) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any], let reason = object["reason"] as? String
        else { return "" }
        return String(reason.prefix(64))
    }

    static func map(status: Int, body: [UInt8]) -> ApnsResult {
        let reason = reason(body)
        switch status {
        case 200: return .delivered
        case 410: return .unregistered
        case 400 where reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic": return .badToken(reason)
        case 403: return .retry(reason.isEmpty ? "403" : reason)  // ExpiredProviderToken: new JWT; other reasons are configuration errors
        case 429, 500...599: return .retry(reason.isEmpty ? String(status) : reason)
        default: return .rejected("\(status) \(reason)")
        }
    }

    public func send(_ request: ApnsRequest) async -> ApnsResult {
        do {
            let response = try await transport.perform(httpRequest(request, jwt: try jwt()))
            if response.status == 403 { invalidateJWT() }
            return Self.map(status: response.status, body: response.body)
        } catch {
            return .retry("transport")
        }
    }
}
