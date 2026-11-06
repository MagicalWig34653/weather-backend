import Foundation
import MySQLKit
import NIOCore

extension MariaRepo: CacheAdminRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private func opt(_ value: String?) -> MySQLData { value.map { MySQLData(string: $0) } ?? .null }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"

    /// Table names and the layer predicate of a layer id (`radar` has its own tables without a layer column).
    private static func tables(_ layer: String) -> (run: String, slot: String, filter: String, binds: [MySQLData]) {
        layer == "radar" ? ("radar_run", "radar_slot", "1=1", []) : ("layer_run", "layer_slot", "r.layer = ?", [MySQLData(string: layer)])
    }

    private static func joinOn(_ layer: String) -> String {
        layer == "radar" ? "s.run_id = r.run_id" : "s.layer = r.layer AND s.run_id = r.run_id"
    }

    public func cacheInventory(layers: [String], now: Date) async throws -> [CacheLayerInventory] {
        try await connection { conn in
            var out: [CacheLayerInventory] = []
            for layer in layers {
                let t = Self.tables(layer)
                let isRadar = layer == "radar"
                let runFilter = isRadar ? "1=1" : "layer = ?"
                let runBinds = t.binds
                // Slots and bytes from the slot table (size column only), runs and times from the run table.
                let stats = try await query(conn,
                    "SELECT COUNT(*) AS n_runs, DATE_FORMAT(MIN(nominal_time), \(Self.dateOut)) AS oldest_s, DATE_FORMAT(MAX(nominal_time), \(Self.dateOut)) AS newest_s, "
                    + "DATE_FORMAT(MAX(published_at), \(Self.dateOut)) AS pub_s FROM \(t.run) WHERE status='published' AND \(runFilter)", runBinds).rows.first
                let sizes = try await query(conn,
                    "SELECT COUNT(*) AS n_slots, COALESCE(SUM(s.size), 0) AS n_bytes FROM \(t.slot) s JOIN \(t.run) r ON \(Self.joinOn(layer)) "
                    + "WHERE r.status='published' AND \(t.filter)", t.binds).rows.first
                let last = try await query(conn,
                    "SELECT status, lease_until >= ? AS leased, DATE_FORMAT(created_at, \(Self.dateOut)) AS created_s FROM \(t.run) "
                    + "WHERE \(runFilter) ORDER BY created_at DESC, nominal_time DESC LIMIT 1", [ts(now)] + runBinds).rows.first
                var attempt: String?
                if let status = last?.column("status")?.string {
                    attempt = status == "claimed" && (last?.column("leased")?.int ?? 0) == 0 ? "claimed_expired" : status
                }
                out.append(CacheLayerInventory(
                    layer: layer, runs: stats?.column("n_runs")?.int ?? 0, slots: sizes?.column("n_slots")?.int ?? 0,
                    bytes: sizes?.column("n_bytes")?.int ?? 0,
                    oldestNominal: stats?.column("oldest_s")?.string.flatMap(TimeUtil.fromSQL),
                    newestNominal: stats?.column("newest_s")?.string.flatMap(TimeUtil.fromSQL),
                    latestPublishedAt: stats?.column("pub_s")?.string.flatMap(TimeUtil.fromSQL),
                    lastAttemptAt: last?.column("created_s")?.string.flatMap(TimeUtil.fromSQL), lastAttemptStatus: attempt))
            }
            return out
        }
    }

    public func cacheSlotRows(layer: String, olderThan: Date?, at: Date?, limit: Int) async throws -> [CacheSlotRow] {
        try await connection { conn in
            let t = Self.tables(layer)
            var sql = "SELECT s.slot_index, s.size, s.content_type, r.status, DATE_FORMAT(s.slot_time, \(Self.dateOut)) AS slot_s, "
                + "DATE_FORMAT(r.nominal_time, \(Self.dateOut)) AS nominal_s, DATE_FORMAT(r.published_at, \(Self.dateOut)) AS pub_s "
                + "FROM \(t.slot) s JOIN \(t.run) r ON \(Self.joinOn(layer)) WHERE \(t.filter)"
            var binds = t.binds
            if let at { sql += " AND s.slot_time = ?"; binds.append(ts(at)) }
            if let olderThan { sql += " AND s.slot_time < ?"; binds.append(ts(olderThan)) }
            sql += " ORDER BY s.slot_time DESC, r.nominal_time DESC LIMIT ?"
            binds.append(MySQLData(int: max(0, limit)))
            return try await query(conn, sql, binds).rows.map { row in
                CacheSlotRow(slot: Self.time(row, "slot_s"), run: Self.time(row, "nominal_s"), index: row.column("slot_index")?.int ?? 0,
                             bytes: row.column("size")?.int ?? 0, contentType: row.column("content_type")?.string ?? "",
                             published: row.column("status")?.string == "published",
                             publishedAt: row.column("pub_s")?.string.flatMap(TimeUtil.fromSQL))
            }
        }
    }

    public func cacheSlotBlob(layer: String, slot: Date, run: Date?) async throws -> SlotBlob? {
        try await connection { conn in
            let t = Self.tables(layer)
            var sql = "SELECT s.content_type, s.sha256, s.bytes FROM \(t.slot) s JOIN \(t.run) r ON \(Self.joinOn(layer)) "
                + "WHERE r.status='published' AND \(t.filter) AND s.slot_time = ?"
            var binds = t.binds + [ts(slot)]
            if let run { sql += " AND r.nominal_time = ?"; binds.append(ts(run)) }
            sql += " ORDER BY r.nominal_time DESC LIMIT 1"
            guard let row = try await query(conn, sql, binds).rows.first, let type = row.column("content_type")?.string,
                  let sha = row.column("sha256")?.string, let buffer = row.column("bytes")?.buffer else { return nil }
            return SlotBlob(contentType: type, sha256: sha, data: Array(buffer.readableBytesView))
        }
    }

    // MARK: refresh jobs

    private static let jobColumns = "id, layer, status, result, error, DATE_FORMAT(created_at, \(dateOut)) AS created_s, "
        + "DATE_FORMAT(started_at, \(dateOut)) AS started_s, DATE_FORMAT(finished_at, \(dateOut)) AS finished_s"

    private static func job(_ row: MySQLRow) -> RefreshJob? {
        guard let status = row.column("status")?.string.flatMap(RefreshStatus.init(rawValue:)) else { return nil }
        return RefreshJob(id: row.column("id")?.string ?? "", layer: row.column("layer")?.string ?? "", status: status,
                          createdAt: time(row, "created_s"), startedAt: row.column("started_s")?.string.flatMap(TimeUtil.fromSQL),
                          finishedAt: row.column("finished_s")?.string.flatMap(TimeUtil.fromSQL),
                          result: row.column("result")?.string, error: row.column("error")?.string)
    }

    /// Stale jobs: unclaimed ones expire, running ones without a result fail.
    private func settleRefreshJobs(_ conn: MySQLConnection, now: Date) async throws {
        _ = try await query(conn, "UPDATE dashboard_refresh SET status='expired', finished_at=?, error='no_ingest_replica' WHERE status='queued' AND created_at < ?",
                            [ts(now), ts(now.addingTimeInterval(-RefreshRetention.queuedExpirySeconds))])
        _ = try await query(conn, "UPDATE dashboard_refresh SET status='failed', finished_at=?, error='timeout' WHERE status='running' AND started_at < ?",
                            [ts(now), ts(now.addingTimeInterval(-RefreshRetention.runningTimeoutSeconds))])
    }

    public func createRefreshJobs(layers: [String], now: Date) async throws -> (created: [RefreshJob], pending: [String]) {
        try await transaction { conn in
            try await settleRefreshJobs(conn, now: now)
            _ = try await query(conn, "DELETE FROM dashboard_refresh WHERE created_at < ?", [ts(now.addingTimeInterval(-Double(RefreshRetention.keepHours) * 3600))])
            var created: [RefreshJob] = [], pending: [String] = []
            for layer in layers {
                if try await query(conn, "SELECT id FROM dashboard_refresh WHERE layer=? AND status IN ('queued','running') LIMIT 1 FOR UPDATE", [str(layer)]).rows.first != nil {
                    pending.append(layer); continue
                }
                let id = UUID().uuidString.lowercased()
                _ = try await query(conn, "INSERT INTO dashboard_refresh (id, layer, status, created_at) VALUES (?, ?, 'queued', ?)", [str(id), str(layer), ts(now)])
                created.append(RefreshJob(id: id, layer: layer, status: .queued, createdAt: now))
            }
            _ = try await query(conn, "DELETE FROM dashboard_refresh WHERE id NOT IN (SELECT id FROM (SELECT id FROM dashboard_refresh ORDER BY created_at DESC, id DESC LIMIT ?) keep)",
                                [MySQLData(int: RefreshRetention.keepJobs)])
            return (created, pending)
        }
    }

    public func refreshJob(id: String) async throws -> RefreshJob? {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.jobColumns) FROM dashboard_refresh WHERE id=?", [str(id)]).rows.first.flatMap(Self.job)
        }
    }

    public func refreshJobs(limit: Int) async throws -> [RefreshJob] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.jobColumns) FROM dashboard_refresh ORDER BY created_at DESC, id DESC LIMIT ?",
                            [MySQLData(int: max(0, limit))]).rows.compactMap(Self.job)
        }
    }

    public func queuedRefreshLayers(now: Date) async throws -> [String] {
        try await connection { conn in
            try await settleRefreshJobs(conn, now: now)
            var seen: [String] = []
            for row in try await query(conn, "SELECT layer FROM dashboard_refresh WHERE status='queued' ORDER BY created_at, id").rows {
                if let layer = row.column("layer")?.string, !seen.contains(layer) { seen.append(layer) }
            }
            return seen
        }
    }

    public func claimRefreshJob(layer: String, now: Date) async throws -> RefreshJob? {
        try await connection { conn in
            guard let row = try await query(conn, "SELECT \(Self.jobColumns) FROM dashboard_refresh WHERE layer=? AND status='queued' ORDER BY created_at, id LIMIT 1",
                                            [str(layer)]).rows.first, var job = Self.job(row) else { return nil }
            let taken = try await query(conn, "UPDATE dashboard_refresh SET status='running', started_at=? WHERE id=? AND status='queued'", [ts(now), str(job.id)])
            guard taken.affected == 1 else { return nil }
            job.status = .running; job.startedAt = now
            return job
        }
    }

    public func finishRefreshJob(id: String, status: RefreshStatus, result: String?, error: String?, now: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "UPDATE dashboard_refresh SET status=?, finished_at=?, result=?, error=? WHERE id=? AND status='running'",
                                [str(status.rawValue), ts(now), opt(result), opt(error), str(id)])
        }
    }

    // MARK: replica cache fill

    public func reportCacheFill(replicaID: String, fill: ReplicaCacheFill, now: Date) async throws {
        try await connection { conn in
            _ = try await query(conn, "UPDATE config_replica SET cache_bytes=?, cache_entries=?, cache_max=? WHERE replica_id=?",
                                [MySQLData(int: fill.bytes), MySQLData(int: fill.entries), MySQLData(int: fill.maxBytes), str(replicaID)])
        }
    }

    public func replicaCacheFills(now: Date) async throws -> [String: ReplicaCacheFill] {
        try await connection { conn in
            var out: [String: ReplicaCacheFill] = [:]
            for row in try await query(conn, "SELECT replica_id, cache_bytes, cache_entries, cache_max FROM config_replica WHERE last_seen_at > ? AND cache_bytes IS NOT NULL",
                                       [ts(now.addingTimeInterval(-DashboardRetention.replicaStale))]).rows {
                if let id = row.column("replica_id")?.string, let b = row.column("cache_bytes")?.int, let e = row.column("cache_entries")?.int, let m = row.column("cache_max")?.int {
                    out[id] = ReplicaCacheFill(bytes: b, entries: e, maxBytes: m)
                }
            }
            return out
        }
    }
}
