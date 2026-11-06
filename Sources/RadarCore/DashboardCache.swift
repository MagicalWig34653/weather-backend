import Foundation

/// Operator cache tools of the dashboard (docs-site/content/dashboard-api.md, "Cache-Inventar"): inventory, slot list, image
/// preview and the manual ingest job. Session, host, CSRF and the general limit are checked by `DashboardApi` before.
/// Nothing here exposes tokens, IDs or coordinates: layer ids, times, sizes and fixed codes only.
final class DashboardCache: Sendable {
    let repo: any Repo
    let config: @Sendable () -> Config
    let processCache: @Sendable () async -> SlotCacheSnapshot?
    private let limiter = RateLimiter()

    static let previewMaxBytes = 8 * 1024 * 1024
    static let previewTypes: Set<String> = ["image/webp", "image/png", "image/jpeg"]
    static let readLimitPerMinute = 60
    static let previewLimitPerMinute = 120
    static let refreshLimitPerMinute = 6
    /// Answer cache of the inventory (the queries scan the slot tables).
    static let inventoryTTL: TimeInterval = 10
    private let inventoryMemo = InventoryMemo()

    init(repo: any Repo, config: @escaping @Sendable () -> Config, processCache: @escaping @Sendable () async -> SlotCacheSnapshot?) {
        self.repo = repo; self.config = config; self.processCache = processCache
    }

    private static func iso(_ date: Date?) -> Any { date.map { TimeUtil.toISO($0) } ?? NSNull() }
    private static func error(_ status: Int, _ code: String, retryAfter: Int? = nil) -> ApiResponse { DashboardApi.error(status, code, retryAfter: retryAfter) }

    static func isLayer(_ id: String) -> Bool { id == "radar" || LayerCatalog.specs[id] != nil }

    static func parseISO(_ text: String) -> Date? {
        guard text.utf8.count <= 32 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// nil: not a cache route owned here (`cache/clear` belongs to the push actions).
    func handle(_ req: DashboardHTTPRequest, _ sub: String, now: Date) async throws -> ApiResponse? {
        guard sub == "/cache" || sub.hasPrefix("/cache/") else { return nil }
        let parts = sub.split(separator: "/", omittingEmptySubsequences: false).map(String.init)   // ["", "cache", ...]
        let m = req.method
        switch parts.count {
        case 2:
            guard m == "GET" else { return Self.error(405, "not_found") }
            return try await inventory(now: now)
        case 3 where parts[2] == "refresh":
            if m == "POST" { return try await refresh(req, now: now) }
            guard m == "GET" else { return Self.error(405, "not_found") }
            return try await refreshList(req.query, now: now)
        case 3 where parts[2] == "clear":
            return nil
        case 4 where parts[2] == "refresh":
            guard m == "GET" else { return Self.error(405, "not_found") }
            return try await refreshOne(parts[3], now: now)
        case 4 where parts[3] == "slots":
            guard m == "GET" else { return Self.error(405, "not_found") }
            return try await slots(parts[2], req.query, now: now)
        case 4 where parts[3] == "preview":
            guard m == "GET" else { return Self.error(405, "not_found") }
            return try await preview(parts[2], req.query, now: now)
        default:
            return Self.error(404, "not_found")
        }
    }

    private func readAllowed(_ now: Date) -> Bool { limiter.allow("cache-read", limit: Self.readLimitPerMinute, window: 60, now: now) }

    // MARK: inventory

    private func cadence(_ id: String) -> Int {
        if id == "radar" { return 300 }
        guard let spec = LayerCatalog.specs[id] else { return 300 }
        return spec.publishCadenceSeconds
    }

    private func kind(_ id: String) -> String {
        if id == "radar" { return "radar" }
        return LayerCatalog.specs[id]?.kind.rawValue ?? "observation"
    }

    /// Pure rule, see the contract: `empty`/`disabled` first, then age against the cadence.
    static func state(enabled: Bool, hasData: Bool, ageSeconds: Int?, cadence: Int, lastAttemptFailed: Bool) -> String {
        guard hasData, let age = ageSeconds else { return enabled ? "empty" : "disabled" }
        if !enabled { return "disabled" }
        if age <= max(900, 3 * cadence) { return "current" }
        if age <= 12 * cadence { return lastAttemptFailed ? "failed" : "stale" }
        return "failed"
    }

    private func inventory(now: Date) async throws -> ApiResponse {
        guard readAllowed(now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        if let hit = inventoryMemo.get(now: now) { return hit }
        let enabledLayers = Set(config().layers)
        let ids = ["radar"] + LayerCatalog.order
        var partial: [String] = []
        var layers: [[String: Any]] = []
        let from = TimeUtil.floor(now, to: 3600).addingTimeInterval(-23 * 3600)
        let hourly = (try? await repo.statsHourly(from: from, to: now)).flatMap { $0.isEmpty ? nil : $0 }
        do {
            for item in try await repo.cacheInventory(layers: ids, now: now) {
                let enabled = item.layer == "radar" || enabledLayers.contains(item.layer)
                let age = item.latestPublishedAt.map { max(0, Int(now.timeIntervalSince($0))) }
                let result: Any
                switch item.lastAttemptStatus {
                case "claimed": result = "running"
                case "claimed_expired", "failed": result = "error"
                case "published": result = "ok"
                default: result = NSNull()
                }
                let state = Self.state(enabled: enabled, hasData: item.runs > 0, ageSeconds: age, cadence: cadence(item.layer),
                                       lastAttemptFailed: result as? String == "error")
                var errors: Any = NSNull()
                if let hourly {
                    errors = hourly.filter { $0.metric == "ingest_run" && ($0.label == item.layer + ":error" || $0.label == item.layer + ":missed") }
                        .reduce(0) { $0 + $1.value }
                }
                let span: Any = (item.oldestNominal != nil && item.newestNominal != nil)
                    ? Int(item.newestNominal!.timeIntervalSince(item.oldestNominal!)) : NSNull()
                layers.append(["id": item.layer, "kind": kind(item.layer), "enabled": enabled, "state": state, "runs": item.runs, "slots": item.slots,
                               "bytes": item.bytes, "oldestNominal": Self.iso(item.oldestNominal), "newestNominal": Self.iso(item.newestNominal),
                               "spanSeconds": span, "latestPublishedAt": Self.iso(item.latestPublishedAt), "ageSeconds": age as Any? ?? NSNull(),
                               "cadenceSeconds": cadence(item.layer), "lastAttemptAt": Self.iso(item.lastAttemptAt), "lastAttemptResult": result,
                               "errors24h": errors])
            }
        } catch {
            partial.append("layers")
            layers = []
        }
        var processJSON: Any = NSNull()
        if let snap = await processCache() {
            processJSON = ["scope": "thisReplica", "bytes": snap.bytes, "maxBytes": snap.maxBytes, "entries": snap.entries]
        }
        var replicas: [[String: Any]] = []
        do {
            let fills = try await repo.replicaCacheFills(now: now)
            for r in try await repo.replicas(now: now) {
                let fill = fills[r.replicaID]
                replicas.append(["id": DashboardApi.shortID(r.replicaID), "cacheBytes": fill?.bytes as Any? ?? NSNull(),
                                 "cacheEntries": fill?.entries as Any? ?? NSNull(), "cacheMaxBytes": fill?.maxBytes as Any? ?? NSNull()])
            }
        } catch { partial.append("replicas") }
        let response = DashboardApi.object(200, ["generatedAt": TimeUtil.toISO(now), "partial": partial, "layers": layers, "process": processJSON, "replicas": replicas])
        if partial.isEmpty { inventoryMemo.put(response, now: now, ttl: Self.inventoryTTL) }
        return response
    }

    // MARK: slots and preview

    private func slots(_ layer: String, _ query: [String: String], now: Date) async throws -> ApiResponse {
        guard Self.isLayer(layer) else { return Self.error(404, "not_found") }
        guard readAllowed(now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        var limit = 50
        if let raw = query["limit"] { guard let n = Int(raw), (1...200).contains(n) else { return Self.error(400, "validation") }; limit = n }
        var before = now.addingTimeInterval(86400)
        if let raw = query["before"] { guard let d = Self.parseISO(raw) else { return Self.error(400, "validation") }; before = d }
        let page = try await repo.cacheSlotPage(layer: layer, before: before, limit: limit)
        let rows = page.rows.map { r -> [String: Any] in
            ["slot": TimeUtil.toISO(r.slot), "run": TimeUtil.toISO(r.run), "index": r.index, "bytes": r.bytes, "contentType": r.contentType,
             "published": r.published, "publishedAt": Self.iso(r.publishedAt)]
        }
        return DashboardApi.object(200, ["layer": layer, "slots": rows, "next": Self.iso(page.next)])
    }

    private func preview(_ layer: String, _ query: [String: String], now: Date) async throws -> ApiResponse {
        guard Self.isLayer(layer) else { return Self.error(404, "not_found") }
        guard limiter.allow("cache-preview", limit: Self.previewLimitPerMinute, window: 60, now: now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        guard let rawSlot = query["slot"], let slot = Self.parseISO(rawSlot) else { return Self.error(400, "validation") }
        var run: Date?
        if let rawRun = query["run"] { guard let d = Self.parseISO(rawRun) else { return Self.error(400, "validation") }; run = d }
        guard let blob = try await repo.cacheSlotBlob(layer: layer, slot: slot, run: run) else { return Self.error(404, "not_found") }
        guard Self.previewTypes.contains(blob.contentType) else { return Self.error(415, "unsupported_media") }
        guard blob.data.count <= Self.previewMaxBytes else { return Self.error(413, "too_large") }
        return ApiResponse(status: 200, headers: [("Content-Type", blob.contentType), ("Cache-Control", "private, no-store"),
                                                  ("X-Content-Type-Options", "nosniff"), ("Content-Security-Policy", "default-src 'none'"),
                                                  ("Content-Disposition", "inline")], body: blob.data)
    }

    // MARK: refresh

    private static func jobJSON(_ j: RefreshJob) -> [String: Any] {
        let result: Any = j.status == .ok ? (j.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()) : NSNull()
        return ["id": j.id, "layer": j.layer, "status": j.status.rawValue, "createdAt": TimeUtil.toISO(j.createdAt), "startedAt": iso(j.startedAt),
                "finishedAt": iso(j.finishedAt), "result": result, "error": j.error as Any? ?? NSNull()]
    }

    private func refresh(_ req: DashboardHTTPRequest, now: Date) async throws -> ApiResponse {
        guard limiter.allow("cache-refresh", limit: Self.refreshLimitPerMinute, window: 60, now: now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        guard let object = DashboardPushActions.object(req.body), object.count == 1, let layer = object["layer"] as? String,
              layer == "all" || Self.isLayer(layer) else { return Self.error(400, "validation") }
        let enabled = Set(config().layers)
        var targets: [String]
        if layer == "all" { targets = ["radar"] + LayerCatalog.order.filter { enabled.contains($0) } }
        else {
            guard layer == "radar" || enabled.contains(layer) else { return Self.error(409, "layer_disabled") }
            targets = [layer]
        }
        let fresh = try await repo.replicas(now: now).contains { now.timeIntervalSince($0.lastSeenAt) <= PushTruth.freshSeconds }
        guard fresh else { return Self.error(503, "ingest_unavailable") }
        let result = try await repo.createRefreshJobs(layers: targets, now: now)
        guard !result.created.isEmpty else { return Self.error(409, "refresh_pending") }
        try await repo.appendDeviceAudit(action: .cacheRefresh, deviceRef: nil, outcome: layer, now: now)
        return DashboardApi.object(202, ["jobs": result.created.map(Self.jobJSON)])
    }

    private func refreshList(_ query: [String: String], now: Date) async throws -> ApiResponse {
        guard readAllowed(now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        var limit = 10
        if let raw = query["limit"] { guard let n = Int(raw), (1...30).contains(n) else { return Self.error(400, "validation") }; limit = n }
        _ = try await repo.queuedRefreshLayers(now: now)   // settles expired / timed-out jobs
        return DashboardApi.object(200, ["jobs": try await repo.refreshJobs(limit: limit).map(Self.jobJSON)])
    }

    private func refreshOne(_ id: String, now: Date) async throws -> ApiResponse {
        guard let uuid = DashboardDevices.canonicalUUID(id) else { return Self.error(404, "not_found") }
        guard readAllowed(now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        _ = try await repo.queuedRefreshLayers(now: now)
        guard let job = try await repo.refreshJob(id: uuid) else { return Self.error(404, "not_found") }
        return DashboardApi.object(200, Self.jobJSON(job))
    }
}

private final class InventoryMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (until: Date, response: ApiResponse)?
    func get(now: Date) -> ApiResponse? { lock.withLock { entry.flatMap { $0.until > now ? $0.response : nil } } }
    func put(_ response: ApiResponse, now: Date, ttl: TimeInterval) { lock.withLock { entry = (now.addingTimeInterval(ttl), response) } }
}
