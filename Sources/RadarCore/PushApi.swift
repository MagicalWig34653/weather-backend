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

    /// Gives back one event reserved with `allow` (a successful attempt that must not use up a failure budget).
    func refund(_ key: String, window: TimeInterval, now: Date) {
        lock.lock(); defer { lock.unlock() }
        let isPinned = key.hasPrefix("global:")
        guard var entry = isPinned ? pinned[key] : windows[key], now.timeIntervalSince(entry.start) < window, entry.count > 0 else { return }
        entry.count -= 1
        if isPinned { pinned[key] = entry } else { windows[key] = entry }
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
    public static let perInstallationLimit = PushRateLimits().perInstallation
    public static let globalRegistrationLimit = PushRateLimits().globalRegistration
    /// All push requests per window and replica, counted before any lookup (flood protection; real traffic is far below).
    public static let globalRequestLimit = PushRateLimits().globalRequest
    /// Failed authentications per installation id and window; further attempts get `429` without a database query.
    public static let failedAuthLimit = PushRateLimits().failedAuth
    public static let window: TimeInterval = 60

    let repo: any Repo
    let configProvider: ConfigProvider
    var config: Config { configProvider() }
    let clock: @Sendable () -> Date
    /// nil when the APNs key could not be loaded: the test route then answers `503 apns_unavailable`.
    let sender: (any ApnsSender)?
    private let limiter = RateLimiter()
    let stats: any StatsSink
    let observer: any PushObserver
    /// Test override; nil = built from `config.deviceLink` with the bundled Apple root.
    private let verifierOverride: AppTransactionVerifier?
    /// Test override of the global request limit; nil = `config.push.rateLimits.globalRequest`.
    private let globalRequestLimitOverride: Int?
    private var globalRequestLimit: Int { globalRequestLimitOverride ?? config.push.rateLimits.globalRequest }

    /// Test notifications per installation and hour (in memory per replica, like the other limits).
    public static let testLimit = PushRateLimits().testPerHour
    public static let testWindow: TimeInterval = 3600
    static let testExpirySeconds: TimeInterval = 600

    public convenience init(repo: any Repo, config: Config, sender: (any ApnsSender)? = nil, globalRequestLimit: Int? = nil,
                            clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(repo: repo, configProvider: ConfigProvider(config), sender: sender, globalRequestLimit: globalRequestLimit, clock: clock)
    }

    public init(repo: any Repo, configProvider: ConfigProvider, sender: (any ApnsSender)? = nil, globalRequestLimit: Int? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }, stats: any StatsSink = NoStatsSink(),
                appTransactionVerifier: AppTransactionVerifier? = nil) {
        self.stats = stats; self.observer = StatsPushObserver(stats: stats); self.verifierOverride = appTransactionVerifier
        self.repo = repo; self.configProvider = configProvider; self.sender = sender; self.clock = clock; self.globalRequestLimitOverride = globalRequestLimit
    }

    struct InstallationBody: Decodable { var token: String; var env: String; var locale: String; var live_activity_start_token: String? }
    struct SubscriptionBody: Decodable {
        var grid_version: Int; var cell_x: Int; var cell_y: Int; var threshold: Int; var lead_minutes: Int; var enabled: Bool?; var time_sensitive: Bool?
        /// Optional region fields; without them the subscription is a single cell as before.
        var live_activity: Bool?; var kind: String?; var radius_cells: Int?; var min_share_percent: Int?
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
        // Live Activities for circles (capability `live_activity_regions`, decision 7 Nov 2026): the same flag as for points.
        return PushSubscriptionInput(gridVersion: body.grid_version, cellX: cellX, cellY: cellY,
                                     threshold: body.threshold, leadMinutes: body.lead_minutes, enabled: body.enabled ?? true,
                                     timeSensitive: body.time_sensitive ?? false, kind: kind, radiusCells: radius, minSharePercent: share, liveActivity: body.live_activity ?? false)
    }

    /// nil when the path is not a push route (or push is disabled): the caller answers 404.
    /// Rejected registrations are counted by their fixed error code (`push_api_reject`); nothing else leaves this method.
    public func handle(method: String, path rawPath: String, secret: String?, body: [UInt8]) async -> ApiResponse? {
        let response = await handleRoute(method: method, path: rawPath, secret: secret, body: body)
        if let response, response.status >= 400, response.status < 600,
           let object = try? JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any], let code = object["error"] as? String,
           StatsCollector.pushApiRejectCodes.contains(code) {
            observer.apiRejected(code)
        }
        return response
    }

    func handleRoute(method: String, path rawPath: String, secret: String?, body: [UInt8]) async -> ApiResponse? {
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        guard config.push.enabled, path.hasPrefix(Self.prefix) else { return nil }
        var parts = path.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // The short activity route resolves its owner, then uses the same authentication and limits. Same order as the other
        // routes (review A6): body size, global limits, then input format (also the secret) without the database; only then the
        // single owner lookup. The global request counter is incremented once (not again after the rewrite).
        var countedGlobal = false
        var ownerResolved = false
        if parts.count == 3, parts[0] == "subscriptions", parts[2] == "activity" {
            guard body.count <= PushGrid.maxBodyBytes else { return Self.error(413, "too_large") }
            let early = clock()
            guard limiter.allow("global:any", limit: globalRequestLimit, window: Self.window, now: early),
                  limiter.allow("global:activity", limit: globalRequestLimit, window: Self.window, now: early) else { return Self.error(429, "rate_limited") }
            countedGlobal = true; ownerResolved = true
            guard let sub = Self.canonicalUUID(parts[1]) else { return Self.error(400, "invalid_id") }
            guard Self.validSecret(secret) != nil else { return Self.error(401, "unauthorized") }
            do {
                guard let owner = try await repo.subscriptionOwner(subscriptionID: sub) else { return Self.error(404, "not_found") }
                parts = ["installations", owner, "subscriptions", sub, "activity"]
            } catch { return Self.error(503, "unavailable") }
        }
        guard parts.count >= 2, parts[0] == "installations", parts.count <= 5, (parts.count != 5 || parts[2] == "subscriptions" && parts[4] == "activity"), parts.count != 3 || ["subscriptions", "test", "link-code", "link"].contains(parts[2]) else { return nil }
        let isLinkRoute = parts.count == 3 && (parts[2] == "link-code" || parts[2] == "link")
        // Device link routes answer 404 like disabled push when the switch is off.
        if isLinkRoute, !config.deviceLink.enabled { return nil }
        guard body.count <= (parts.count == 3 && parts[2] == "link-code" ? Self.linkCodeMaxBodyBytes : PushGrid.maxBodyBytes) else { return Self.error(413, "too_large") }
        let now = clock()
        guard countedGlobal || limiter.allow("global:any", limit: globalRequestLimit, window: Self.window, now: now) else { return Self.error(429, "rate_limited") }
        guard let installID = Self.canonicalUUID(parts[1]) else { return Self.error(400, "invalid_id") }
        guard limiter.allow("i:" + installID, limit: config.push.rateLimits.perInstallation, window: Self.window, now: now) else {
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
            if isLinkRoute { return try await handleLink(parts[2], method: method, installID: installID, secret: secret, body: body, now: now) }
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
                    if let refusal = try await self.startTokenRefusal(input, installID) { return refusal }
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
                    case .activityCapacity: return Self.error(503, "activity_full")
                    }
                }
                default: return Self.error(405, "method_not_allowed")
                }
            }
            guard let subID = Self.canonicalUUID(parts[3]) else { return Self.error(400, "invalid_id") }
            if parts.count == 5 {
                guard method == "PUT" || method == "DELETE" else { return Self.error(405, "method_not_allowed") }
                let verified = ownerResolved
                return try await authenticated(installID, secret, now) { _ in
                    if !verified { guard try await self.repo.subscriptionOwner(subscriptionID: subID) == installID else { return Self.error(404, "not_found") } }
                    // DELETE without `activity_token` frees a reservation that never got a token (review A7).
                    if method == "DELETE", (try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])?["activity_token"] == nil {
                        _ = try await self.repo.deleteReservation(subscriptionID: subID)
                        return Self.json(204)
                    }
                    guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                          let raw = object["activity_token"] as? String, let token = Self.validToken(raw) else { return Self.error(400, "invalid_activity_token") }
                    if method == "DELETE" {
                        _ = try await self.repo.deleteActivity(subscriptionID: subID, matchingToken: token)
                        return Self.json(204)
                    }
                    switch try await self.repo.setActivityToken(subscriptionID: subID, token: token, now: now) {
                    case .updated: return Self.json(204)
                    case .notFound: return Self.error(404, "not_found")
                    case .notEligible: return Self.error(409, "activity_not_eligible")
                    case .activityLimit: return Self.error(409, "activity_limit")
                    }
                }
            }
            switch method {
            case "PUT": return try await authenticated(installID, secret, now) { _ in
                guard let input = self.decodeSubscription(body) else { return Self.error(400, "invalid_subscription") }
                if let refusal = try await self.startTokenRefusal(input, installID) { return refusal }
                do {
                    return try await self.repo.updateSubscription(installationID: installID, id: subID, input, regionLimits: self.config.push.regionLimits) ? Self.json(204) : Self.error(404, "not_found")
                } catch let limit as PushRegionLimitError {
                    switch limit {
                    case .activityCapacity: return Self.error(503, "activity_full")
                    case .capacity: return Self.error(409, "region_capacity")
                    case .perInstallation: return Self.error(409, "region_limit")
                    }
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
                                    "lead_minutes": sub.leadMinutes, "enabled": sub.enabled, "time_sensitive": sub.timeSensitive, "live_activity": sub.liveActivity,
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
        guard limiter.allow("t:" + installID, limit: config.push.rateLimits.testPerHour, window: Self.testWindow, now: now) else {
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

    /// `live_activity: true` is only accepted for an installation that has reported a push-to-start token (review A1):
    /// anonymous installations cannot inflate the activity work. `409 start_token_required` otherwise.
    private func startTokenRefusal(_ input: PushSubscriptionInput, _ installID: String) async throws -> ApiResponse? {
        guard input.liveActivity else { return nil }
        guard try await repo.installation(id: installID)?.liveActivityStartToken != nil else { return Self.error(409, "start_token_required") }
        return nil
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

    // MARK: device link (docs-site/content/api.md, "Geräte-Kopplung")

    static let linkCodeMaxBodyBytes = 8 * 1024
    static let linkCodeTTL: TimeInterval = 600
    static let linkCodesPerHour = 6
    static let linkCodesPerWindow = 30

    private func handleLink(_ route: String, method: String, installID: String, secret: String?, body: [UInt8], now: Date) async throws -> ApiResponse {
        let settings = config.deviceLink
        switch (route, method) {
        case ("link", "GET"):
            return try await authenticated(installID, secret, now) { _ in
                let state = try await self.repo.linkState(installationID: installID, now: now)
                func iso(_ d: Date?) -> Any { d.map { TimeUtil.toISO($0) } ?? NSNull() }
                return Self.json(200, ["state": state.kind.rawValue, "code_expires_at": iso(state.codeExpiresAt), "linked_at": iso(state.linkedAt),
                                       "expires_at": iso(state.expiresAt), "last_action_at": iso(state.lastActionAt), "pending_commands": state.pendingCommands])
            }
        case ("link", "DELETE"):
            return try await authenticated(installID, secret, now) { _ in
                try await self.repo.unlink(installationID: installID)
                return Self.json(204)
            }
        case ("link-code", "POST"):
            return try await authenticated(installID, secret, now) { _ in
                // Codes are only handed out while the operator's pairing window is open (checked first, uniform answer).
                // A database error counts as closed (fail closed).
                guard let windowEnd = try? await self.repo.pairingWindowEnd(now: now) else { return Self.error(403, "pairing_closed") }
                guard self.limiter.allow("lc:" + installID, limit: Self.linkCodesPerHour, window: 3600, now: now) else {
                    var response = Self.error(429, "link_code_rate_limited")
                    response.headers.append(("Retry-After", "3600"))
                    return response
                }
                // Flood limit: a stranger must not fill the window with codes (per replica and window).
                guard self.limiter.allow("lcw:" + TimeUtil.toISO(windowEnd), limit: Self.linkCodesPerWindow, window: 900, now: now) else {
                    var response = Self.error(429, "link_code_rate_limited")
                    response.headers.append(("Retry-After", String(max(1, Int(windowEnd.timeIntervalSince(now).rounded(.up))))))
                    return response
                }
                let object = body.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
                guard let object else { return Self.error(400, "invalid_request") }
                if settings.requireTestFlight {
                    guard let jws = object["app_transaction"] as? String else { return Self.error(400, "invalid_request") }
                    let verifier = self.verifierOverride ?? self.makeVerifier(settings)
                    if let reason = await verifier.verify(jws: jws) {
                        self.stats.record("device_link_reject", label: reason.rawValue, by: 1)
                        return Self.error(403, "not_testflight")
                    }
                }
                let code = LinkCode.generate()
                guard let normalized = LinkCode.normalize(code) else { return Self.error(503, "unavailable") }
                switch try await self.repo.createLinkCode(installationID: installID, codeHash: LinkCode.hash(normalized), attested: true,
                                                          now: now, ttl: Self.linkCodeTTL, maxDevices: settings.maxDevices) {
                case .created:
                    return Self.json(201, ["code": code, "expires_at": TimeUtil.toISO(now.addingTimeInterval(Self.linkCodeTTL)), "ttl_seconds": Int(Self.linkCodeTTL)])
                case .alreadyLinked: return Self.error(409, "already_linked")
                case .linkFull: return Self.error(409, "link_full")
                case .unknownInstallation: return Self.error(401, "unauthorized")
                }
            }
        default:
            return Self.error(405, "method_not_allowed")
        }
    }

    private func makeVerifier(_ settings: DeviceLinkSettings) -> AppTransactionVerifier {
        var bundle = settings.bundleID.isEmpty ? config.push.topic : settings.bundleID
        if let range = bundle.range(of: ".push-type.") { bundle = String(bundle[..<range.lowerBound]) }
        return AppTransactionVerifier(roots: AppleRoots.rootG3().map { [$0] } ?? [], bundleID: bundle,
                                      allowedEnvironments: settings.allowedEnvironments, maxAgeHours: settings.maxAgeHours, clock: clock)
    }

    private func blockedByFailures(_ installID: String, _ now: Date) -> Bool {
        limiter.count("f:" + installID, window: Self.window, now: now) >= config.push.rateLimits.failedAuth
    }

    private func putInstallation(_ installID: String, secret: String?, body: [UInt8], now: Date) async throws -> ApiResponse {
        guard limiter.allow("global:put", limit: config.push.rateLimits.globalRegistration, window: Self.window, now: now) else {
            return Self.error(429, "rate_limited")
        }
        guard let secret = Self.validSecret(secret) else { return Self.error(401, "unauthorized") }
        if blockedByFailures(installID, now) { return Self.error(429, "rate_limited") }
        guard let decoded = try? JSONDecoder().decode(InstallationBody.self, from: Data(body)),
              let token = Self.validToken(decoded.token), let env = PushEnvironment(rawValue: decoded.env),
              ["de", "en"].contains(decoded.locale) else { return Self.error(400, "invalid_installation") }
        let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
        let hasStartToken = object?.keys.contains("live_activity_start_token") == true
        if let raw = decoded.live_activity_start_token, Self.validToken(raw) == nil { return Self.error(400, "invalid_installation") }
        switch try await repo.upsertInstallation(id: installID, secretHash: Hashing.sha256Hex(Array(secret.utf8)), token: token,
                                                 env: env, locale: decoded.locale, now: now,
                                                 maxInstallations: config.push.maxInstallations) {
        case .created:
            if hasStartToken { try await repo.setLiveActivityStartToken(installationID: installID, token: decoded.live_activity_start_token.flatMap(Self.validToken)) }
            return Self.json(201)
        case .updated:
            if hasStartToken { try await repo.setLiveActivityStartToken(installationID: installID, token: decoded.live_activity_start_token.flatMap(Self.validToken)) }
            return Self.json(204)
        case .forbidden:
            limiter.record("f:" + installID, window: Self.window, now: now)
            return Self.error(401, "unauthorized")
        case .serverFull: return Self.error(503, "server_full")
        }
    }
}
