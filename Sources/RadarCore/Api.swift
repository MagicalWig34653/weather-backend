import Foundation

public struct ApiResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: [UInt8]
}

/// Byte-bounded LRU with single-flight loading. Entries are immutable by construction (ids never change content).
public actor SlotCache {
    private var items: [String: (blob: SlotBlob, tick: Int)] = [:]
    private var order = 0
    private var size = 0
    private var flights: [String: Task<SlotBlob?, Error>] = [:]
    private let maxBytes: Int
    public private(set) var dbReads = 0

    public init(maxBytes: Int) { self.maxBytes = maxBytes }

    func lookup(_ key: String) -> SlotBlob? {
        guard let entry = items[key] else { return nil }
        order += 1
        items[key] = (entry.blob, order)
        return entry.blob
    }

    func put(_ key: String, _ blob: SlotBlob) {
        if let old = items[key] { size -= old.blob.data.count }
        order += 1
        items[key] = (blob, order)
        size += blob.data.count
        while size > maxBytes, let oldest = items.min(by: { $0.value.tick < $1.value.tick }) {
            size -= oldest.value.blob.data.count
            items[oldest.key] = nil
        }
    }

    public func contains(_ key: String) -> Bool { items[key] != nil }

    /// On a miss exactly one task reads the DB per key; concurrent requests await the same task.
    public func load(_ key: String, _ loader: @escaping @Sendable () async throws -> SlotBlob?) async throws -> SlotBlob? {
        if let hit = lookup(key) { return hit }
        if let flight = flights[key] { return try await flight.value }
        dbReads += 1
        let task = Task { try await loader() }
        flights[key] = task
        defer { flights[key] = nil }
        let blob = try await task.value
        if let blob { put(key, blob) }
        return blob
    }
}

/// Stateless HTTP API logic independent of the socket layer; no cookies, no access logs.
public final class Api: Sendable {
    public static let immutable = "public, max-age=31536000, immutable"
    public static let latest = "public, max-age=30, stale-while-revalidate=30"
    public static let history = "public, max-age=60, stale-while-revalidate=60"
    static let pageCSP = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
    static let manifestTTL: TimeInterval = 5

    let repo: any Repo
    let config: Config
    let alive: @Sendable () -> Bool
    let clock: @Sendable () -> Date
    public let cache: SlotCache
    let push: PushApi
    private let manifestState = ManifestState()
    private let historyState = ManifestState()

    /// Short memo with single-flight: concurrent requests share one build.
    actor ManifestState {
        var value: (at: Date, body: [UInt8]?)?
        var flight: Task<[UInt8]?, Error>?
        func get(now: Date, ttl: TimeInterval, build: @escaping @Sendable () async throws -> [UInt8]?) async throws -> [UInt8]? {
            if let value, now.timeIntervalSince(value.at) <= ttl { return value.body }
            if let flight { return try await flight.value }
            let task = Task { try await build() }
            flight = task
            defer { flight = nil }
            let body = try await task.value
            value = (now, body)
            return body
        }
    }

    public init(repo: any Repo, config: Config, alive: @escaping @Sendable () -> Bool = { true },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repo = repo; self.config = config; self.alive = alive; self.clock = clock
        cache = SlotCache(maxBytes: config.cacheMaxBytes)
        push = PushApi(repo: repo, config: config, clock: clock)
    }

    static func etagMatches(_ header: String?, _ etag: String) -> Bool {
        guard let header else { return false }
        return header.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == etag }
    }

    private func respond(headers: [(String, String)], body: [UInt8], ifNoneMatch: String?, etag: String) -> ApiResponse {
        var all = [("ETag", etag), ("X-Content-Type-Options", "nosniff")] + headers
        if Self.etagMatches(ifNoneMatch, etag) {
            all.removeAll { $0.0 == "Content-Type" }
            return ApiResponse(status: 304, headers: all, body: [])
        }
        return ApiResponse(status: 200, headers: all, body: body)
    }

    static func parseSlotRoute(_ path: String) -> (String, String)? {
        let prefix = "/v1/radar/"
        guard path.hasPrefix(prefix), path.hasSuffix(".webp") else { return nil }
        let parts = path.dropFirst(prefix.count).dropLast(5).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, TimeUtil.fromID(String(parts[0])) != nil, TimeUtil.fromID(String(parts[1])) != nil else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static let notFound = ApiResponse(status: 404, headers: [("Cache-Control", "no-store")], body: [])

    /// Push registration routes (/v1/push/...); 404 when push is disabled or the path is unknown.
    public func handlePush(method: String, path: String, secret: String?, body: [UInt8]) async -> ApiResponse {
        await push.handle(method: method, path: path, secret: secret, body: body) ?? Self.notFound
    }

    public func handle(path rawPath: String, ifNoneMatch: String?) async throws -> ApiResponse {
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        if path == "/healthz" {
            return alive()
                ? ApiResponse(status: 200, headers: [("Cache-Control", "no-store")], body: Array("ok\n".utf8))
                : ApiResponse(status: 503, headers: [], body: Array("stale\n".utf8))
        }
        if let html = SitePages.render(path: path, info: config.site) {
            let body = Array(html.utf8)
            return respond(headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "public, max-age=3600"),
                                     ("Referrer-Policy", "no-referrer"), ("Content-Security-Policy", Self.pageCSP)],
                           body: body, ifNoneMatch: ifNoneMatch, etag: "\"" + Hashing.sha256Hex(body).prefix(32) + "\"")
        }
        if path == "/v1/radar/latest.json" {
            let repo = self.repo, config = self.config
            guard let body = try await manifestState.get(now: clock(), ttl: Self.manifestTTL, build: {
                try await Manifest.build(repo: repo, config: config)
            }) else { return Self.notFound }
            let etag = "\"" + Hashing.sha256Hex(body).prefix(32) + "\""
            return respond(headers: [("Content-Type", "application/json"), ("Cache-Control", Self.latest)],
                           body: body, ifNoneMatch: ifNoneMatch, etag: etag)
        }
        if path == "/v1/radar/history.json" {
            let repo = self.repo, config = self.config
            guard let body = try await historyState.get(now: clock(), ttl: Self.manifestTTL, build: {
                try await Manifest.buildHistory(repo: repo, config: config)
            }) else { return Self.notFound }
            let etag = "\"" + Hashing.sha256Hex(body).prefix(32) + "\""
            return respond(headers: [("Content-Type", "application/json"), ("Cache-Control", Self.history)],
                           body: body, ifNoneMatch: ifNoneMatch, etag: etag)
        }
        if let (runID, slotID) = Self.parseSlotRoute(path) {
            let repo = self.repo
            guard let blob = try await cache.load("\(runID)/\(slotID)", { try await repo.getSlot(runID: runID, slotID: slotID) })
            else { return Self.notFound }
            return respond(headers: [("Content-Type", blob.contentType), ("Cache-Control", Self.immutable)],
                           body: blob.data, ifNoneMatch: ifNoneMatch, etag: "\"\(blob.sha256)\"")
        }
        return Self.notFound
    }
}
