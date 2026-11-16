import Foundation

/// Read-only diagnosis export of the dashboard (`GET /dash/api/diagnose`): one JSON document with operational data only.
/// Privacy: layer ids, times, counters and fixed labels. No IPs, device or installation ids, tokens or secrets; replica and lock owner
/// ids are the 8-character hashes of the dashboard. Session, host and the general limit are checked by `DashboardApi` before.
final class DashboardDiagnose: Sendable {
    let repo: any Repo
    let config: @Sendable () -> Config
    let env: [String: String]
    let processCache: @Sendable () async -> SlotCacheSnapshot?

    static let runWindow: TimeInterval = 6 * 3600
    /// Leaders besides the per-layer ones (`layer:<id>`); the radar itself claims runs and holds no lock.
    static let globalLeaders = ["backfill", "warn", "push"]

    init(repo: any Repo, config: @escaping @Sendable () -> Config, env: [String: String], processCache: @escaping @Sendable () async -> SlotCacheSnapshot?) {
        self.repo = repo; self.config = config; self.env = env; self.processCache = processCache
    }

    private static func iso(_ date: Date?) -> Any { date.map { TimeUtil.toISO($0) } ?? NSNull() }

    func response(now: Date) async -> ApiResponse {
        let cfg = config()
        var partial: [String] = []
        let ids = ["radar"] + LayerCatalog.order
        let enabled = Set(cfg.layers)

        // Layers: latest image, runs of the last 6 h by status, failures of the last 24 h by class, leader lock.
        var inventory: [String: CacheLayerInventory] = [:]
        do { for item in try await repo.cacheInventory(layers: ids, now: now) { inventory[item.layer] = item } } catch { partial.append("layers") }
        let hourlyFrom = TimeUtil.floor(now, to: 3600).addingTimeInterval(-23 * 3600)
        var hourly: [StatHourRow] = []
        do { hourly = try await repo.statsHourly(from: hourlyFrom, to: now) } catch { partial.append("errors24h") }
        var layers: [[String: Any]] = []
        for id in ids {
            let item = inventory[id]
            let age = item?.latestPublishedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
            var counts: [String: Int] = [:]
            do { counts = try await repo.runStatusCounts(layer: id, since: now.addingTimeInterval(-Self.runWindow)) } catch { if !partial.contains("runs6h") { partial.append("runs6h") } }
            func errors(_ cls: String) -> Int { hourly.filter { $0.metric == "ingest_run" && $0.label == "\(id):\(cls)" }.reduce(0) { $0 + $1.value } }
            var lock: Any = NSNull()
            if id != "radar", let lease = try? await repo.leaderLease(name: "layer:\(id)") { lock = Self.lockJSON(lease, now: now) }
            layers.append(["id": id, "enabled": id == "radar" || enabled.contains(id), "lastPublishedAt": Self.iso(item?.latestPublishedAt),
                           "ageMinutes": age as Any? ?? NSNull(), "lastAttempt": item?.lastAttemptStatus as Any? ?? NSNull(),
                           "runs6h": ["published": counts["published"] ?? 0, "failed": counts["failed"] ?? 0, "claimed": counts["claimed"] ?? 0],
                           "errors24h": ["error": errors("error"), "missed": errors("missed")], "lock": lock])
        }
        var leaders: [String: Any] = [:]
        for name in Self.globalLeaders { if let lease = try? await repo.leaderLease(name: name) { leaders[name] = Self.lockJSON(lease, now: now) } }

        // Replicas and cache. Hits/misses are only counted cluster-wide (stats_daily); size and entries exist per replica.
        var replicas: [[String: Any]] = []
        var perReplica: [[String: Any]] = []
        do {
            let fills = try await repo.replicaCacheFills(now: now)
            for r in try await repo.replicas(now: now) {
                let id = DashboardApi.shortID(r.replicaID)
                replicas.append(["id": id, "startedAt": TimeUtil.toISO(r.startedAt)])
                let fill = fills[r.replicaID]
                perReplica.append(["id": id, "bytes": fill?.bytes as Any? ?? NSNull(), "entries": fill?.entries as Any? ?? NSNull(),
                                   "maxBytes": fill?.maxBytes as Any? ?? NSNull()])
            }
        } catch { partial.append("replicas") }
        var local: Any = NSNull()
        if let snap = await processCache() { local = ["bytes": snap.bytes, "entries": snap.entries, "maxBytes": snap.maxBytes] }

        // stats_daily: today and yesterday (UTC), labels as stored (<group>:<class>).
        var daily: [[String: Any]] = []
        do {
            let from = TimeUtil.floor(now, to: 86400).addingTimeInterval(-86400)
            daily = try await repo.stats(from: from, to: now).map { ["day": String(TimeUtil.toISO($0.day).prefix(10)), "metric": $0.metric, "label": $0.label, "value": $0.value] }
        } catch { partial.append("statsDaily") }

        let body: [String: Any] = [
            "generatedAt": TimeUtil.toISO(now), "partial": partial,
            "version": ["commit": cfg.buildRevision as Any? ?? NSNull()],
            "config": ["layers": cfg.layers, "imageWidth": cfg.width, "cacheMaxMB": cfg.cacheMaxBytes / 1_048_576,
                       "radarReplicas": env["RADAR_REPLICAS"] as Any? ?? NSNull()],
            "replicas": replicas, "layers": layers, "leaders": leaders,
            "cache": ["thisReplica": local, "replicas": perReplica,
                      "note": "Size and entries per replica (reported every 20 s); hits and misses are counted cluster-wide only (see statsDaily: cache_hit, cache_miss). thisReplica is null when the answering process has no public cache (dashboard-only service)."],
            "statsDaily": daily,
            "logs": ["available": false, "reason": "The service keeps no log buffer; WARNING/ERROR lines only go to the container log (docker service logs)."],
        ]
        var out = DashboardApi.object(200, body)
        out.headers.append(("Content-Disposition", "attachment; filename=\"diagnose-\(TimeUtil.toID(now)).json\""))
        return out
    }

    private static func lockJSON(_ lease: LeaderLease, now: Date) -> [String: Any] {
        ["owner": DashboardApi.shortID(lease.owner), "leaseUntil": TimeUtil.toISO(now.addingTimeInterval(TimeInterval(lease.secondsLeft)))]
    }
}
