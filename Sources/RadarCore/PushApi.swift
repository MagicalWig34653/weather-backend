import Foundation

/// Fixed-window limiter per key with a bounded key table (no IP addresses involved). When the table is full, expired
/// entries are dropped first and then the oldest windows are evicted: a flood of random keys never rejects other keys.
/// Keys starting with `global:` live in a small separate table that is never evicted.
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [String: (start: Date, count: Int)] = [:]
    private var pinned: [String: (start: Date, count: Int)] = [:]
    private let maxKeys: Int

    init(maxKeys: Int = 20_000) { self.maxKeys = max(10, maxKeys) }

    var keyCount: Int { lock.withLock { windows.count } }

    /// True when the call is allowed.
    func allow(_ key: String, limit: Int, window: TimeInterval, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bump(key, window: window, now: now) <= limit
    }

    /// Counts an event without a limit decision (failed attempts).
    func record(_ key: String, window: TimeInterval, now: Date) {
        lock.lock(); defer { lock.unlock() }
        _ = bump(key, window: window, now: now)
    }

    /// Events of the current window (0 when none).
    func count(_ key: String, window: TimeInterval, now: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let entry = key.hasPrefix("global:") ? pinned[key] : windows[key], now.timeIntervalSince(entry.start) < window else { return 0 }
        return entry.count
    }

    private func bump(_ key: String, window: TimeInterval, now: Date) -> Int {
        let isPinned = key.hasPrefix("global:")
        if !isPinned, windows[key] == nil, windows.count >= maxKeys { evict(window: window, now: now) }
        var entry = (isPinned ? pinned[key] : windows[key]) ?? (now, 0)
        if now.timeIntervalSince(entry.start) >= window { entry = (now, 0) }
        entry.count += 1
        if isPinned { pinned[key] = entry } else { windows[key] = entry }
        return entry.count
    }

    private func evict(window: TimeInterval, now: Date) {
        windows = windows.filter { now.timeIntervalSince($0.value.start) < window }
        guard windows.count >= maxKeys else { return }
        // Still full of live windows: drop the oldest tenth in one go (amortized), instead of refusing the new key.
        let drop = windows.sorted { $0.value.start < $1.value.start }.prefix(max(1, maxKeys / 10))
        for (key, _) in drop { windows[key] = nil }
    }
}

/// Registration API under /v1/push/. Authentication: header `X-Installation-Secret` (random, kept in the app's keychain);
/// the server stores only its SHA-256. No coordinates, no cookies, nothing is logged.
///   PUT    /v1/push/installations/{id}                          body {token, env, locale}   (creates or updates)
///   DELETE /v1/push/installations/{id}                          deletes everything of the installation
///   GET    /v1/push/installations/{id}/subscriptions
///   POST   /v1/push/installations/{id}/subscriptions            body {grid_version, cell_x, cell_y, threshold, lead_minutes, enabled, time_sensitive, kind?, radius_cells?, min_share_percent?}
///   PUT    /v1/push/installations/{id}/subscriptions/{subId}    same body (re-arms the rule)
///   DELETE /v1/push/installations/{id}/subscriptions/{subId}
///   POST   /v1/push/installations/{id}/test                     sends one clearly labelled test notification to the installation's token
public final class PushApi: Sendable {
    public static let prefix = "/v1/push/"
    public static let perInstallationLimit = 60
    public static let globalRegistrationLimit = 600
    /// All push requests per window and replica, counted before any lookup (flood protection; real traffic is far below).
    public static let globalRequestLimit = 3000
    /// Failed authentications per installation id and window; further attempts get `429` without a database query.
    public static let failedAuthLimit = 10
    public static let window: TimeInterval = 60

    let repo: any Repo
    let config: Config
    let clock: @Sendable () -> Date
    /// nil when the APNs key could not be loaded: the test route then answers `503 apns_unavailable`.
    let sender: (any ApnsSender)?
    private let limiter = RateLimiter()
    private let globalRequestLimit: Int

    /// Test notifications per installation and hour (in memory per replica, like the other limits).
    public static let testLimit = 3
    public static let testWindow: TimeInterval = 3600
    static let testExpirySeconds: TimeInterval = 600

    public init(repo: any Repo, config: Config, sender: (any ApnsSender)? = nil, globalRequestLimit: Int = PushApi.globalRequestLimit,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repo = repo; self.config = config; self.sender = sender; self.clock = clock; self.globalRequestLimit = globalRequestLimit
    }

    struct InstallationBody: Decodable { var token: String; var env: String; var locale: String }
    struct SubscriptionBody: Decodable {
        var grid_version: Int; var cell_x: Int; var cell_y: Int; var threshold: Int; var lead_minutes: Int; var enabled: Bool?; var time_sensitive: Bool?
        /// Optional region fields; without them the subscription is a single cell as before.
        var kind: String?; var radius_cells: Int?; var min_share_percent: Int?
    }

    private static func json(_ status: Int, _ object: Any? = nil) -> ApiResponse {
        var headers = [("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]
        guard let object else { return ApiResponse(status: status, headers: headers, body: []) }
        headers.append(("Content-Type", "application/json"))
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return ApiResponse(status: status, headers: headers, body: Array(data))
    }

    private static func error(_ status: Int, _ code: String) -> ApiResponse { json(status, ["error": code]) }

    static func canonicalUUID(_ text: String) -> String? {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func validSecret(_ text: String?) -> String? {
        guard let text, (32...128).contains(text.utf8.count),
              text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F })
        else { return nil }
        return text
    }

    static func validToken(_ text: String) -> String? {
        let lower = text.lowercased()
        guard (32...200).contains(lower.utf8.count), lower.utf8.count % 2 == 0,
              lower.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return lower
    }

    private func validInput(_ body: SubscriptionBody) -> PushSubscriptionInput? {
        let height = config.height
        guard body.grid_version == PushGrid.version, (0..<config.width).contains(body.cell_x), (0..<height).contains(body.cell_y),
              PushGrid.thresholdRange.contains(body.threshold), PushGrid.validLeadMinutes.contains(body.lead_minutes) else { return nil }
        var kind = PushKind.point
        var cellX = body.cell_x, cellY = body.cell_y
        var radius: Int?, share: Int?
        switch body.kind ?? "point" {
        case "point":
            guard body.radius_cells == nil, body.min_share_percent == nil else { return nil }
        case "circle":
            guard let r = body.radius_cells, PushRegion.radiusRange.contains(r),
                  PushRegion.allowedShares.contains(body.min_share_percent ?? PushRegion.defaultShare) else { return nil }
            kind = .circle; radius = r; share = body.min_share_percent ?? PushRegion.defaultShare
            // The server stores only a coarse centre (3 x 3 cells, about 2 km), whatever the client sent.
            (cellX, cellY) = PushRegion.snapCenter(x: cellX, y: cellY, width: config.width, height: height)
        default:
            return nil
        }
        return PushSubscriptionInput(gridVersion: body.grid_version, cellX: cellX, cellY: cellY,
                                     threshold: body.threshold, leadMinutes: body.lead_minutes, enabled: body.enabled ?? true,
                                     timeSensitive: body.time_sensitive ?? false, kind: kind, radiusCells: radius, minSharePercent: share)
    }

    /// nil when the path is not a push route (or push is disabled): the caller answers 404.
    public func handle(method: String, path rawPath: String, secret: String?, body: [UInt8]) async -> ApiResponse? {
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        guard config.push.enabled, path.hasPrefix(Self.prefix) else { return nil }
        let parts = path.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "installations", parts.count <= 4, parts.count != 3 || parts[2] == "subscriptions" || parts[2] == "test" else { return nil }
        guard body.count <= PushGrid.maxBodyBytes else { return Self.error(413, "too_large") }
        let now = clock()
        guard limiter.allow("global:any", limit: globalRequestLimit, window: Self.window, now: now) else { return Self.error(429, "rate_limited") }
        guard let installID = Self.canonicalUUID(parts[1]) else { return Self.error(400, "invalid_id") }
        guard limiter.allow("i:" + installID, limit: Self.perInstallationLimit, window: Self.window, now: now) else {
            return Self.error(429, "rate_limited")
        }
        do {
            if parts.count == 2 {
                switch method {
                case "PUT": return try await putInstallation(installID, secret: secret, body: body, now: now)
                case "DELETE": return try await authenticated(installID, secret, now) { _ in
                    try await self.repo.deleteInstallation(id: installID)
                    return Self.json(204)
                }
                default: return Self.error(405, "method_not_allowed")
                }
            }
            if parts.count == 3, parts[2] == "test" {
                guard method == "POST" else { return Self.error(405, "method_not_allowed") }
                return try await authenticated(installID, secret, now) { _ in try await self.sendTest(installID, now: now) }
            }
            if parts.count == 3 {
                switch method {
                case "GET": return try await authenticated(installID, secret, now) { _ in
                    let subs = try await self.repo.subscriptions(installationID: installID)
                    return Self.json(200, subs.map(Self.describe))
                }
                case "POST": return try await authenticated(installID, secret, now) { _ in
                    guard let input = self.decodeSubscription(body) else { return Self.error(400, "invalid_subscription") }
                    let id = UUID().uuidString.lowercased()
                    switch try await self.repo.addSubscription(installationID: installID, id: id, input,
                                                               maxPerInstallation: PushGrid.maxSubscriptionsPerInstallation,
                                                               regionLimits: self.config.push.regionLimits, now: now) {
                    case .created: return Self.json(201, ["id": id])
                    case .limitReached: return Self.error(409, "subscription_limit")
                    case .unknownInstallation: return Self.error(401, "unauthorized")
                    case .regionLimit: return Self.error(409, "region_limit")
                    case .regionCapacity: return Self.error(409, "region_capacity")
                    case .serverFull: return Self.error(503, "server_full")
                    }
                }
                default: return Self.error(405, "method_not_allowed")
                }
            }
            guard let subID = Self.canonicalUUID(parts[3]) else { return Self.error(400, "invalid_id") }
            switch method {
            case "PUT": return try await authenticated(installID, secret, now) { _ in
                guard let input = self.decodeSubscription(body) else { return Self.error(400, "invalid_subscription") }
                do {
                    return try await self.repo.updateSubscription(installationID: installID, id: subID, input, regionLimits: self.config.push.regionLimits) ? Self.json(204) : Self.error(404, "not_found")
                } catch let limit as PushRegionLimitError {
                    return Self.error(409, limit == .capacity ? "region_capacity" : "region_limit")
                }
            }
            case "DELETE": return try await authenticated(installID, secret, now) { _ in
                try await self.repo.deleteSubscription(installationID: installID, id: subID) ? Self.json(204) : Self.error(404, "not_found")
            }
            default: return Self.error(405, "method_not_allowed")
            }
        } catch {
            return Self.error(503, "unavailable")
        }
    }

    private static func describe(_ sub: PushSubscription) -> [String: Any] {
        var entry: [String: Any] = ["id": sub.id, "grid_version": sub.gridVersion, "cell_x": sub.cellX, "cell_y": sub.cellY, "threshold": sub.threshold,
                                    "lead_minutes": sub.leadMinutes, "enabled": sub.enabled, "time_sensitive": sub.timeSensitive,
                                    "kind": sub.kind == .circle ? "circle" : "point"]
        if sub.kind == .circle {
            entry["radius_cells"] = sub.radiusCells
            entry["min_share_percent"] = sub.minSharePercent
        }
        return entry
    }

    /// Test notification to the installation's own token. Stores nothing; errors name the cause without leaking token or key.
    private func sendTest(_ installID: String, now: Date) async throws -> ApiResponse {
        guard let sender else { return Self.error(503, "apns_unavailable") }
        guard let target = try await repo.installation(id: installID) else { return Self.error(401, "unauthorized") }
        guard config.push.environments.contains(target.env) else { return Self.error(409, "environment_not_allowed") }
        guard limiter.allow("t:" + installID, limit: Self.testLimit, window: Self.testWindow, now: now) else {
            var response = Self.error(429, "test_rate_limited")
            response.headers.append(("Retry-After", String(Int(Self.testWindow))))
            return response
        }
        let request = ApnsRequest(tokenHex: target.token, env: target.env, topic: config.push.topic,
                                  payload: Array(PushEvaluator.testPayload(locale: target.locale).utf8),
                                  collapseID: "test-" + installID, expiration: Int(now.addingTimeInterval(Self.testExpirySeconds).timeIntervalSince1970))
        switch await sender.send(request) {
        case .delivered:
            return Self.json(200, ["sent": true, "environment": target.env.rawValue])
        case .unregistered:
            _ = try await repo.deleteInstallations(token: target.token, env: target.env)  // same as the normal sender: a dead token is removed
            return Self.json(410, ["error": "token_unregistered"])
        case .badToken(let reason):
            // Token and APNs environment (or key/topic) do not match.
            return Self.json(502, ["error": "apns_bad_device_token", "reason": reason, "environment": target.env.rawValue])
        case .retry(let reason) where reason == "InvalidProviderToken" || reason == "MissingProviderToken":
            return Self.json(502, ["error": "apns_key_rejected", "reason": reason, "environment": target.env.rawValue])
        case .retry(let reason):
            return Self.json(502, ["error": "apns_unavailable", "reason": reason])
        case .rejected(let reason):
            return Self.json(502, ["error": "apns_rejected", "reason": String(reason.prefix(64))])
        }
    }

    private func decodeSubscription(_ body: [UInt8]) -> PushSubscriptionInput? {
        guard let decoded = try? JSONDecoder().decode(SubscriptionBody.self, from: Data(body)) else { return nil }
        return validInput(decoded)
    }

    private func authenticated(_ installID: String, _ secret: String?, _ now: Date, _ body: (String) async throws -> ApiResponse) async throws -> ApiResponse {
        guard let secret = Self.validSecret(secret) else { return Self.error(401, "unauthorized") }
        if blockedByFailures(installID, now) { return Self.error(429, "rate_limited") }
        guard try await repo.authenticate(id: installID, secretHash: Hashing.sha256Hex(Array(secret.utf8)), now: now) else {
            limiter.record("f:" + installID, window: Self.window, now: now)
            return Self.error(401, "unauthorized")
        }
        return try await body(installID)
    }

    private func blockedByFailures(_ installID: String, _ now: Date) -> Bool {
        limiter.count("f:" + installID, window: Self.window, now: now) >= Self.failedAuthLimit
    }

    private func putInstallation(_ installID: String, secret: String?, body: [UInt8], now: Date) async throws -> ApiResponse {
        guard limiter.allow("global:put", limit: Self.globalRegistrationLimit, window: Self.window, now: now) else {
            return Self.error(429, "rate_limited")
        }
        guard let secret = Self.validSecret(secret) else { return Self.error(401, "unauthorized") }
        if blockedByFailures(installID, now) { return Self.error(429, "rate_limited") }
        guard let decoded = try? JSONDecoder().decode(InstallationBody.self, from: Data(body)),
              let token = Self.validToken(decoded.token), let env = PushEnvironment(rawValue: decoded.env),
              ["de", "en"].contains(decoded.locale) else { return Self.error(400, "invalid_installation") }
        switch try await repo.upsertInstallation(id: installID, secretHash: Hashing.sha256Hex(Array(secret.utf8)), token: token,
                                                 env: env, locale: decoded.locale, now: now,
                                                 maxInstallations: config.push.maxInstallations) {
        case .created: return Self.json(201)
        case .updated: return Self.json(204)
        case .forbidden:
            limiter.record("f:" + installID, window: Self.window, now: now)
            return Self.error(401, "unauthorized")
        case .serverFull: return Self.error(503, "server_full")
        }
    }
}
