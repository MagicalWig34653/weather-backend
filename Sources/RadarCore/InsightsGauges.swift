import Foundation
import MySQLKit
import MySQLNIO

// Database gauges of the push pipeline for the insights routes: aggregates only (counts, ages), never an identifier.

enum InsightsGaugeBuckets {
    static let reservationTimeout: TimeInterval = 15 * 60
    static let lockWindow: TimeInterval = 60 * 60

    static func subscriptionBucket(_ n: Int) -> String { n >= 3 ? "3+" : String(n) }
    static func regionBucket(_ n: Int) -> String { String(min(n, 3)) }
}

extension MemoryRepo {
    /// Gauges over the in-memory push store (tests, single process).
    public func insightsPushGauges(now: Date) -> InsightsPushGauges {
        var g = InsightsPushGauges()
        let store = push
        g.installationsTotal = store.installs.count
        var subsPer: [String: Int] = [:], regionsPer: [String: Int] = [:]
        for (id, i) in store.installs {
            let age = now.timeIntervalSince(i.lastSeenAt)
            if age < 86400 { g.active1d += 1 }
            if age < 7 * 86400 { g.active7d += 1 }
            if age < 30 * 86400 { g.active30d += 1 }
            g.byEnv[i.env.rawValue, default: 0] += 1
            g.byLocale[i.locale, default: 0] += 1
            if !i.token.isEmpty { g.withDeviceToken += 1 }
            if i.liveActivityStartToken != nil { g.withStartToken += 1 }
            let mine = store.subs.values.filter { $0.installID == id }
            subsPer[InsightsGaugeBuckets.subscriptionBucket(mine.count), default: 0] += 1
            regionsPer[InsightsGaugeBuckets.regionBucket(mine.filter { $0.value.kind == .circle }.count), default: 0] += 1
        }
        g.subscriptionsPerInstallation = subsPer; g.regionsPerInstallation = regionsPer
        g.subscriptionsTotal = store.subs.count
        for s in store.subs.values {
            let v = s.value
            if v.enabled { g.subscriptionsEnabled += 1 }
            if v.timeSensitive { g.subscriptionsTimeSensitive += 1 }
            if v.liveActivity {
                g.subscriptionsLiveActivity += 1
                if store.installs[s.installID]?.liveActivityStartToken != nil { g.subscriptionsLiveActivityWithStartToken += 1 }
            }
            g.threshold[String(v.threshold), default: 0] += 1
            g.lead[String(v.leadMinutes), default: 0] += 1
            if v.kind == .circle, let r = v.radiusCells { g.regionCells += PushRegion.cellCount(radius: r) }
            if let sent = v.lastSentAt, now.timeIntervalSince(sent) < InsightsGaugeBuckets.lockWindow { g.activeLocks += 1 }
        }
        for a in store.activities.values {
            if a.activityToken == nil {
                if now.timeIntervalSince(a.startedAt) < InsightsGaugeBuckets.reservationTimeout { g.reservationsOpen += 1 } else { g.reservationsExpired += 1 }
            } else if a.endsAt > now { g.activeActivities += 1 }
        }
        let pending = store.outbox.values.filter { $0.status == "pending" }
        g.outboxWaiting = pending.count
        g.outboxRetrying = pending.filter { $0.attempts > 0 }.count
        g.outboxOldestAgeSeconds = pending.map { max(0, Int(now.timeIntervalSince($0.nextAttemptAt))) }.max()
        g.outboxDroppedOrExpired24h = store.outbox.values.filter { $0.status == "dropped" && ($0.finishedAt ?? .distantPast) > now.addingTimeInterval(-86400) }.count
        return g
    }
}

extension MariaRepo {
    /// Gauges from the push tables (a handful of aggregate queries; the caller caches the answer for 5 s).
    public func insightsPushGauges(now: Date) async throws -> InsightsPushGauges {
        func ts(_ d: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(d)) }
        return try await connection { conn in
            var g = InsightsPushGauges()
            func one(_ sql: String, _ binds: [MySQLData] = []) async throws -> MySQLRow? {
                try await self.query(conn, sql, binds).rows.first
            }
            func groups(_ sql: String, _ binds: [MySQLData] = []) async throws -> [String: Int] {
                var out: [String: Int] = [:]
                for r in try await self.query(conn, sql, binds).rows { out[r.column("k")?.string ?? "", default: 0] += r.column("n")?.int ?? 0 }
                return out
            }
            if let r = try await one("SELECT COUNT(*) AS total, SUM(last_seen_at > ?) AS d1, SUM(last_seen_at > ?) AS d7, SUM(last_seen_at > ?) AS d30, "
                                      + "SUM(token <> '') AS dev, SUM(la_start_token IS NOT NULL) AS st FROM push_install",
                                      [ts(now.addingTimeInterval(-86400)), ts(now.addingTimeInterval(-7 * 86400)), ts(now.addingTimeInterval(-30 * 86400))]) {
                g.installationsTotal = r.column("total")?.int ?? 0
                g.active1d = r.column("d1")?.int ?? 0; g.active7d = r.column("d7")?.int ?? 0; g.active30d = r.column("d30")?.int ?? 0
                g.withDeviceToken = r.column("dev")?.int ?? 0; g.withStartToken = r.column("st")?.int ?? 0
            }
            g.byEnv = try await groups("SELECT CAST(env AS CHAR) AS k, COUNT(*) AS n FROM push_install GROUP BY env")
            g.byLocale = try await groups("SELECT locale AS k, COUNT(*) AS n FROM push_install GROUP BY locale")
            if let r = try await one("SELECT COUNT(*) AS total, SUM(s.enabled=1) AS en, SUM(s.time_sensitive=1) AS ts, SUM(s.live_activity=1) AS la, "
                                      + "SUM(s.live_activity=1 AND i.la_start_token IS NOT NULL) AS la_st, SUM(s.last_sent_at > ?) AS locks "
                                      + "FROM push_sub s JOIN push_install i ON i.id = s.install_id WHERE s.kind<>2",
                                      [ts(now.addingTimeInterval(-InsightsGaugeBuckets.lockWindow))]) {
                g.subscriptionsTotal = r.column("total")?.int ?? 0; g.subscriptionsEnabled = r.column("en")?.int ?? 0
                g.subscriptionsTimeSensitive = r.column("ts")?.int ?? 0; g.subscriptionsLiveActivity = r.column("la")?.int ?? 0
                g.subscriptionsLiveActivityWithStartToken = r.column("la_st")?.int ?? 0; g.activeLocks = r.column("locks")?.int ?? 0
            }
            g.threshold = try await groups("SELECT CAST(threshold AS CHAR) AS k, COUNT(*) AS n FROM push_sub WHERE kind<>2 GROUP BY threshold")
            g.lead = try await groups("SELECT CAST(lead_min AS CHAR) AS k, COUNT(*) AS n FROM push_sub WHERE kind<>2 GROUP BY lead_min")
            for (column, keep) in [("COUNT(s.id)", 0), ("COALESCE(SUM(s.kind=1),0)", 1)] {
                let raw = try await groups("SELECT CAST(LEAST(c, 3) AS CHAR) AS k, COUNT(*) AS n FROM (SELECT i.id, \(column) AS c FROM push_install i "
                                           + "LEFT JOIN push_sub s ON s.install_id = i.id AND s.kind<>2 GROUP BY i.id) t GROUP BY LEAST(c, 3)")
                if keep == 0 { g.subscriptionsPerInstallation = raw.reduce(into: [:]) { $0[$1.key == "3" ? "3+" : $1.key, default: 0] += $1.value } }
                else { g.regionsPerInstallation = raw }
            }
            for r in try await self.query(conn, "SELECT radius_cells, COUNT(*) AS n FROM push_sub WHERE kind=1 GROUP BY radius_cells").rows {
                g.regionCells += PushRegion.cellCount(radius: r.column("radius_cells")?.int ?? 0) * (r.column("n")?.int ?? 0)
            }
            if let r = try await one("SELECT SUM(activity_token IS NOT NULL AND ends_at > ?) AS act, SUM(activity_token IS NULL AND started_at > ?) AS open_r, "
                                      + "SUM(activity_token IS NULL AND started_at <= ?) AS exp_r FROM push_activity",
                                      [ts(now), ts(now.addingTimeInterval(-InsightsGaugeBuckets.reservationTimeout)), ts(now.addingTimeInterval(-InsightsGaugeBuckets.reservationTimeout))]) {
                g.activeActivities = r.column("act")?.int ?? 0; g.reservationsOpen = r.column("open_r")?.int ?? 0; g.reservationsExpired = r.column("exp_r")?.int ?? 0
            }
            if let r = try await one("SELECT COUNT(*) AS waiting, SUM(attempts > 0) AS retrying, DATE_FORMAT(MIN(created_at), '%Y-%m-%d %H:%i:%s') AS oldest_s FROM push_outbox WHERE status='pending'") {
                g.outboxWaiting = r.column("waiting")?.int ?? 0; g.outboxRetrying = r.column("retrying")?.int ?? 0
                if let s = r.column("oldest_s")?.string, let d = TimeUtil.fromSQL(s) { g.outboxOldestAgeSeconds = max(0, Int(now.timeIntervalSince(d))) }
            }
            if let r = try await one("SELECT COUNT(*) AS n FROM push_outbox WHERE status='dropped' AND finished_at > ?", [ts(now.addingTimeInterval(-86400))]) {
                g.outboxDroppedOrExpired24h = r.column("n")?.int ?? 0
            }
            return g
        }
    }
}
