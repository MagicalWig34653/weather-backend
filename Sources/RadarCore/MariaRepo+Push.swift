import Foundation
import MySQLKit

extension MariaRepo {
    private func ts(_ date: Date) -> MySQLData { MySQLData(string: TimeUtil.toSQL(date)) }
    private func str(_ value: String) -> MySQLData { MySQLData(string: value) }
    private static let dateOut = "'%Y-%m-%d %H:%i:%s'"

    /// `state` column: bits 0-3 = `PushState`, bit 4 = Live Activity wet hysteresis (no schema change).
    static let wetSeenBit = 0x10
    /// Bit 5: immediate Live Activity start armed; bits 6-7: failed start attempts (0...3).
    static let instantBit = 0x20
    static let attemptShift = 6
    static let automatonMask = 0x1F
    private static func subscription(_ row: MySQLRow) -> PushSubscription {
        var sub = PushSubscription(
            id: row.column("id")?.string ?? "", gridVersion: row.column("grid_version")?.int ?? 0,
            cellX: row.column("cell_x")?.int ?? 0, cellY: row.column("cell_y")?.int ?? 0,
            threshold: row.column("threshold")?.int ?? 0, leadMinutes: row.column("lead_min")?.int ?? 0,
            enabled: (row.column("enabled")?.int ?? 0) == 1, state: PushState(rawValue: (row.column("state")?.int ?? 0) & 0x0F) ?? .dry,
            lastSentAt: row.column("last_sent_s")?.string.flatMap { TimeUtil.fromSQL($0) },
            timeSensitive: (row.column("time_sensitive")?.int ?? 0) == 1,
            kind: PushKind(rawValue: row.column("kind")?.int ?? 0) ?? .point,
            radiusCells: row.column("radius_cells")?.int, minSharePercent: row.column("min_share")?.int, liveActivity: row.column("live_activity")?.int == 1)
        let raw = row.column("state")?.int ?? 0
        sub.wetSeen = (raw & wetSeenBit) != 0
        sub.instantStart = (raw & instantBit) != 0
        sub.startAttempts = (raw >> attemptShift) & 3
        sub.createdAt = row.column("created_s")?.string.flatMap { TimeUtil.fromSQL($0) }
        sub.changedAt = row.column("changed_s")?.string.flatMap { TimeUtil.fromSQL($0) }
        if let run = row.column("eval_run")?.string, let reason = row.column("eval_reason")?.string {
            sub.trace = EvalTrace(run: run, reason: reason, cls: row.column("eval_class")?.int ?? 0)
        }
        return sub
    }

    private static let subColumns = "id, grid_version, cell_x, cell_y, threshold, lead_min, enabled, state, time_sensitive, live_activity, kind, radius_cells, min_share, "
        + "eval_run, eval_reason, eval_class, DATE_FORMAT(created_at, \(dateOut)) AS created_s, DATE_FORMAT(changed_at, \(dateOut)) AS changed_s, DATE_FORMAT(last_sent_at, \(dateOut)) AS last_sent_s"

    public func upsertInstallation(id: String, secretHash: String, token: String, env: PushEnvironment, locale: String, now: Date,
                                   maxInstallations: Int) async throws -> UpsertResult {
        try await transaction { conn in
            // The cap applies to new installations only (soft under concurrency, like the region budget).
            if maxInstallations < Int.max,
               (try await query(conn, "SELECT 1 AS ok FROM push_install WHERE id=?", [str(id)])).rows.isEmpty,
               (try await query(conn, "SELECT COUNT(*) AS n FROM push_install")).rows.first?.column("n")?.int ?? 0 >= maxInstallations {
                return .serverFull
            }
            let inserted = try await query(conn,
                "INSERT IGNORE INTO push_install (id, secret_hash, token, env, locale, created_at, last_seen_at, token_updated_at) "
                + "VALUES (?,?,?,?,?,?,?,?)",
                [str(id), str(secretHash), str(token), str(env.rawValue), str(locale), ts(now), ts(now), ts(now)])
            if inserted.affected == 1 { return .created }
            let current = try await query(conn, "SELECT secret_hash FROM push_install WHERE id=? FOR UPDATE", [str(id)])
            guard current.rows.first?.column("secret_hash")?.string == secretHash else { return .forbidden }
            _ = try await query(conn,
                "UPDATE push_install SET token=?, env=?, locale=?, last_seen_at=?, token_updated_at=? WHERE id=?",
                [str(token), str(env.rawValue), str(locale), ts(now), ts(now), str(id)])
            return .updated
        }
    }

    public func authenticate(id: String, secretHash: String, now: Date) async throws -> Bool {
        // One query in the common case; `last_seen_at` (retention is 60 days) is written at most once per hour and installation.
        try await connection { conn in
            let stale = ts(now.addingTimeInterval(-PushGrid.lastSeenRefreshSeconds))
            let rows = try await query(conn, "SELECT (last_seen_at < ?) AS stale FROM push_install WHERE id=? AND secret_hash=?",
                                       [stale, str(id), str(secretHash)]).rows
            guard let row = rows.first else { return false }
            if (row.column("stale")?.int ?? 0) == 1 {
                _ = try await query(conn, "UPDATE push_install SET last_seen_at=? WHERE id=? AND secret_hash=?", [ts(now), str(id), str(secretHash)])
            }
            return true
        }
    }

    public func deleteInstallation(id: String) async throws {
        regionCellsMemo.withLock { $0 = nil }
        try await connection { conn in _ = try await query(conn, "DELETE FROM push_install WHERE id=?", [str(id)]) }
    }

    private func optional(_ value: Int?) -> MySQLData { value.map { MySQLData(int: $0) } ?? .null }

    /// Inside the installation's row lock: radii of its other regions and cells of all other regions on the server.
    /// The server-wide sum is a soft budget (installations lock only themselves), so concurrent registrations may overshoot slightly.
    private func regionViolation(_ conn: MySQLConnection, installationID: String, excluding id: String, radius: Int, limits: RegionLimits) async throws -> PushRegionLimitError? {
        let own = try await query(conn, "SELECT radius_cells FROM push_sub WHERE install_id=? AND kind=1 AND id<>?", [str(installationID), str(id)])
            .rows.compactMap { $0.column("radius_cells")?.int }
        // The server-wide sum is memoized for 30 s (no GROUP BY per request); it is a soft budget anyway.
        let total = try await serverRegionCells(conn)
        var existing = 0
        if let current = try await query(conn, "SELECT radius_cells FROM push_sub WHERE id=? AND kind=1", [str(id)]).rows.first?.column("radius_cells")?.int {
            existing = PushRegion.cellCount(radius: current)
        }
        return limits.violation(otherRadii: own, serverCells: max(0, total - existing), newRadius: radius)
    }

    private static let cellsMemoSeconds: TimeInterval = 30

    private func serverRegionCells(_ conn: MySQLConnection) async throws -> Int {
        let now = Date()
        if let memo = regionCellsMemo.withLock({ $0 }), now.timeIntervalSince(memo.at) < Self.cellsMemoSeconds { return memo.cells }
        let all = try await query(conn, "SELECT radius_cells, COUNT(*) AS n FROM push_sub WHERE kind=1 GROUP BY radius_cells")
        var cells = 0
        for row in all.rows { cells += PushRegion.cellCount(radius: row.column("radius_cells")?.int ?? 0) * (row.column("n")?.int ?? 0) }
        regionCellsMemo.withLock { $0 = (now, cells) }
        return cells
    }

    public func addSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, maxPerInstallation: Int,
                                regionLimits: RegionLimits, now: Date) async throws -> AddSubscriptionResult {
        try await transaction { conn in
            // The installation row lock serializes concurrent additions, so the limit cannot be exceeded.
            guard !(try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(installationID)])).rows.isEmpty else {
                return .unknownInstallation
            }
            let count = try await query(conn, "SELECT COUNT(*) AS n FROM push_sub WHERE install_id=?", [str(installationID)])
            guard (count.rows.first?.column("n")?.int ?? 0) < maxPerInstallation else { return .limitReached }
            if (try await query(conn, "SELECT COUNT(*) AS n FROM push_sub")).rows.first?.column("n")?.int ?? 0 >= regionLimits.maxSubscriptionsServerwide {
                return .serverFull
            }
            if input.liveActivity,
               (try await query(conn, "SELECT COUNT(*) AS n FROM push_sub WHERE live_activity=1")).rows.first?.column("n")?.int ?? 0 >= regionLimits.maxLiveActivitySubscriptions {
                return .activityCapacity
            }
            if input.kind == .circle {
                switch try await regionViolation(conn, installationID: installationID, excluding: id, radius: input.radiusCells ?? 0, limits: regionLimits) {
                case .perInstallation?: return .regionLimit
                case .capacity?: return .regionCapacity
                case .activityCapacity?: return .activityCapacity
                case nil: break
                }
            }
            _ = try await query(conn,
                "INSERT INTO push_sub (id, install_id, grid_version, cell_x, cell_y, threshold, lead_min, enabled, state, time_sensitive, live_activity, kind, radius_cells, min_share, created_at) "
                + "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [str(id), str(installationID), MySQLData(int: input.gridVersion), MySQLData(int: input.cellX), MySQLData(int: input.cellY),
                 MySQLData(int: input.threshold), MySQLData(int: input.leadMinutes), MySQLData(int: input.enabled ? 1 : 0),
                 MySQLData(int: Self.armedState(input)),
                 MySQLData(int: input.timeSensitive ? 1 : 0), MySQLData(int: input.liveActivity ? 1 : 0), MySQLData(int: input.kind.rawValue), optional(input.radiusCells),
                 optional(input.minSharePercent), ts(now)])
            if input.kind == .circle, let radius = input.radiusCells {
                regionCellsMemo.withLock { if let memo = $0 { $0 = (memo.at, memo.cells + PushRegion.cellCount(radius: radius)) } }
            }
            return .created
        }
    }

    public func updateSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, regionLimits: RegionLimits) async throws -> Bool {
        try await transaction { conn in
            guard !(try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(installationID)])).rows.isEmpty,
                  !(try await query(conn, "SELECT 1 AS ok FROM push_sub WHERE id=? AND install_id=?", [str(id), str(installationID)])).rows.isEmpty
            else { return false }
            if input.liveActivity,
               (try await query(conn, "SELECT live_activity FROM push_sub WHERE id=?", [str(id)])).rows.first?.column("live_activity")?.int != 1,
               (try await query(conn, "SELECT COUNT(*) AS n FROM push_sub WHERE live_activity=1")).rows.first?.column("n")?.int ?? 0 >= regionLimits.maxLiveActivitySubscriptions {
                throw PushRegionLimitError.activityCapacity
            }
            if input.kind == .circle,
               let violation = try await regionViolation(conn, installationID: installationID, excluding: id, radius: input.radiusCells ?? 0, limits: regionLimits) {
                throw violation
            }
            _ = try await query(conn,
                "UPDATE push_sub SET grid_version=?, cell_x=?, cell_y=?, threshold=?, lead_min=?, enabled=?, time_sensitive=?, live_activity=?, kind=?, radius_cells=?, min_share=?, state=?, eval_run=NULL, eval_reason=NULL, eval_class=NULL, changed_at=UTC_TIMESTAMP() WHERE id=? AND install_id=?",
                [MySQLData(int: input.gridVersion), MySQLData(int: input.cellX), MySQLData(int: input.cellY), MySQLData(int: input.threshold),
                 MySQLData(int: input.leadMinutes), MySQLData(int: input.enabled ? 1 : 0), MySQLData(int: input.timeSensitive ? 1 : 0),
                 MySQLData(int: input.liveActivity ? 1 : 0), MySQLData(int: input.kind.rawValue), optional(input.radiusCells), optional(input.minSharePercent),
                 MySQLData(int: Self.armedState(input)), str(id), str(installationID)])
            regionCellsMemo.withLock { $0 = nil }
            return true
        }
    }

    public func deleteSubscription(installationID: String, id: String) async throws -> Bool {
        regionCellsMemo.withLock { $0 = nil }
        return try await connection { conn in
            try await query(conn, "DELETE FROM push_sub WHERE id=? AND install_id=?", [str(id), str(installationID)]).affected >= 1
        }
    }

    public func subscriptions(installationID: String) async throws -> [PushSubscription] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.subColumns) FROM push_sub WHERE install_id=? ORDER BY created_at, id", [str(installationID)])
                .rows.map(Self.subscription)
        }
    }

    public func installation(id: String) async throws -> PushInstallation? {
        try await connection { conn in
            let rows = try await query(conn, "SELECT token, env, locale, la_start_token FROM push_install WHERE id=?", [str(id)]).rows
            guard let row = rows.first, let token = row.column("token")?.string,
                  let env = row.column("env")?.string.flatMap(PushEnvironment.init(rawValue:)) else { return nil }
            return PushInstallation(token: token, env: env, locale: row.column("locale")?.string ?? "de", liveActivityStartToken: row.column("la_start_token")?.string)
        }
    }

    public func evaluationSubscriptions(gridVersion: Int, after: String?, limit: Int) async throws -> [PushSubscription] {
        try await connection { conn in
            try await query(conn, "SELECT \(Self.subColumns) FROM push_sub WHERE enabled=1 AND grid_version=? AND id>? ORDER BY id LIMIT \(max(1, limit))",
                            [MySQLData(int: gridVersion), str(after ?? "")]).rows.map(Self.subscription)
        }
    }

    public func lastEvaluatedRun() async throws -> String? {
        try await connection { conn in
            try await query(conn, "SELECT value FROM push_state WHERE name='last_run'").rows.first?.column("value")?.string
        }
    }

    public func commitEvaluation(runID: String, updates: [SubscriptionUpdate], outbox: [NewOutboxItem], now: Date) async throws -> Bool {
        try await transaction { conn in
            _ = try await query(conn, "INSERT IGNORE INTO push_state (name, value) VALUES ('last_run', '')")
            let last = try await query(conn, "SELECT value FROM push_state WHERE name='last_run' FOR UPDATE").rows.first?.column("value")?.string ?? ""
            guard last < runID else { return false }
            _ = try await query(conn, "UPDATE push_state SET value=? WHERE name='last_run'", [str(runID)])
            for update in updates {
                _ = try await query(conn, "UPDATE push_sub SET state=?, last_sent_at=? WHERE id=?",
                                    [MySQLData(int: update.state.rawValue | (update.wetSeen ? Self.wetSeenBit : 0)
                                              | (update.instantStart ? Self.instantBit : 0) | ((update.startAttempts & 3) << Self.attemptShift)), update.lastSentAt.map { ts($0) } ?? .null, str(update.id)])
                if let trace = update.trace {
                    _ = try await query(conn, "UPDATE push_sub SET eval_run=?, eval_reason=?, eval_class=? WHERE id=?",
                                        [str(trace.run), str(trace.reason), MySQLData(int: trace.cls), str(update.id)])
                }
            }
            for item in outbox {
                // INSERT ... SELECT skips subscriptions that were deleted meanwhile; the unique key ignores duplicates.
                _ = try await query(conn,
                    "INSERT IGNORE INTO push_outbox (sub_id, dedupe_key, collapse_id, payload_json, expires_at, next_attempt_at, created_at) "
                    + "SELECT id, ?, ?, ?, ?, ?, ? FROM push_sub WHERE id=?",
                    [str(item.dedupeKey), str(item.collapseID), str(item.payloadJSON), ts(item.expiresAt), ts(now), ts(now), str(item.subID)])
            }
            return true
        }
    }

    public func dueOutbox(now: Date, limit: Int) async throws -> [OutboxItem] {
        try await connection { conn in
            try await query(conn,
                "SELECT o.id, i.token, i.env, o.collapse_id, o.payload_json, DATE_FORMAT(o.expires_at, \(Self.dateOut)) AS expires_s, o.attempts "
                + "FROM push_outbox o JOIN push_sub s ON s.id = o.sub_id JOIN push_install i ON i.id = s.install_id "
                + "WHERE o.status='pending' AND o.next_attempt_at <= ? ORDER BY o.id LIMIT \(max(1, limit))", [ts(now)]).rows.compactMap { row in
                guard let id = row.column("id")?.int, let token = row.column("token")?.string,
                      let env = row.column("env")?.string.flatMap(PushEnvironment.init(rawValue:)) else { return nil }
                return OutboxItem(id: id, token: token, env: env, collapseID: row.column("collapse_id")?.string ?? "",
                                  payloadJSON: row.column("payload_json")?.string ?? "", expiresAt: Self.time(row, "expires_s"),
                                  attempts: row.column("attempts")?.int ?? 0)
            }
        }
    }

    public func finishOutbox(id: Int, _ outcome: OutboxOutcome, now: Date) async throws {
        try await connection { conn in
            switch outcome {
            case .sent:
                _ = try await query(conn, "UPDATE push_outbox SET status='sent', finished_at=? WHERE id=?", [ts(now), MySQLData(int: id)])
            case .dropped:
                _ = try await query(conn, "UPDATE push_outbox SET status='dropped', finished_at=? WHERE id=?", [ts(now), MySQLData(int: id)])
            case .retry(let attempts, let at):
                _ = try await query(conn, "UPDATE push_outbox SET attempts=?, next_attempt_at=? WHERE id=?",
                                    [MySQLData(int: attempts), ts(at), MySQLData(int: id)])
            }
        }
    }

    public func deleteInstallations(token: String, env: PushEnvironment) async throws -> Int {
        regionCellsMemo.withLock { $0 = nil }
        return try await connection { conn in
            Int(try await query(conn, "DELETE FROM push_install WHERE token=? AND env=?", [str(token), str(env.rawValue)]).affected)
        }
    }

    public func purgePush(inactiveBefore: Date, outboxBefore: Date, now: Date) async throws -> PushPurgeResult {
        regionCellsMemo.withLock { $0 = nil }
        return try await connection { conn in
            let installs = try await query(conn, "DELETE FROM push_install WHERE last_seen_at < ?", [ts(inactiveBefore)]).affected
            let outbox = try await query(conn,
                "DELETE FROM push_outbox WHERE (status<>'pending' AND finished_at < ?) OR (status='pending' AND expires_at < ?)",
                [ts(outboxBefore), ts(outboxBefore)]).affected
            return PushPurgeResult(installations: Int(installs), outbox: Int(outbox))
        }
    }
}

extension MariaRepo {
    /// State of a subscription after activation: a point subscription with Live Activity arms the immediate start.
    static func armedState(_ input: PushSubscriptionInput) -> Int {
        input.liveActivity && input.enabled && input.kind == .point ? instantBit : 0
    }

    public func setLiveActivityStartToken(installationID: String, token: String?) async throws {
        try await transaction { conn in
            let old = try await query(conn, "SELECT la_start_token FROM push_install WHERE id=? FOR UPDATE", [str(installationID)]).rows.first?.column("la_start_token")?.string
            _ = try await query(conn, "UPDATE push_install SET la_start_token=? WHERE id=?", [token.map(str) ?? .null, str(installationID)])
            // A new start token is an activation as well: arm the immediate start of the installation's Live Activity subscriptions.
            if token != nil, token != old {
                _ = try await query(conn, "UPDATE push_sub SET state=((state & \(Self.automatonMask)) | \(Self.instantBit)) WHERE install_id=? AND live_activity=1", [str(installationID)])
            }
        }
    }

    public func setStartRetry(subscriptionID: String, armed: Bool, attempts: Int) async throws {
        try await connection { conn in
            _ = try await query(conn, "UPDATE push_sub SET state=((state & \(Self.automatonMask)) | ?) WHERE id=?",
                                [MySQLData(int: (armed ? Self.instantBit : 0) | ((attempts & 3) << Self.attemptShift)), str(subscriptionID)])
        }
    }
    public func clearLiveActivityStartToken(installationID: String, matchingToken: String) async throws {
        try await connection { conn in
            _ = try await query(conn, "UPDATE push_install SET la_start_token=NULL WHERE id=? AND la_start_token=?", [str(installationID), str(matchingToken)])
        }
    }
    public func activityTarget(subscriptionID: String) async throws -> PushActivityTarget? {
        let values = try await connection { conn in
            try await query(conn, "SELECT \(Self.subColumns), install_id FROM push_sub WHERE id=?", [str(subscriptionID)]).rows
        }
        guard let row = values.first, let installID = row.column("install_id")?.string,
              let install = try await installation(id: installID) else { return nil }
        let activity = try await connection { conn -> PushActivity? in
            let row = try await query(conn, "SELECT activity_token, DATE_FORMAT(started_at, \(Self.dateOut)) AS started, DATE_FORMAT(ends_at, \(Self.dateOut)) AS ends FROM push_activity WHERE subscription_id=?", [str(subscriptionID)]).rows.first
            guard let row, let start = row.column("started")?.string.flatMap(TimeUtil.fromSQL),
                  let end = row.column("ends")?.string.flatMap(TimeUtil.fromSQL) else { return nil }
            return PushActivity(subscriptionID: subscriptionID, activityToken: row.column("activity_token")?.string, startedAt: start, endsAt: end)
        }
        return PushActivityTarget(installationID: installID, installation: install, subscription: Self.subscription(row), activity: activity)
    }
    public func subscriptionOwner(subscriptionID: String) async throws -> String? {
        try await connection { conn in
            try await query(conn, "SELECT install_id FROM push_sub WHERE id=?", [str(subscriptionID)]).rows.first?.column("install_id")?.string
        }
    }

    private static let targetSelect = "SELECT s.id, s.grid_version, s.cell_x, s.cell_y, s.threshold, s.lead_min, s.enabled, s.state, s.time_sensitive, "
        + "s.live_activity, s.kind, s.radius_cells, s.min_share, s.eval_run, s.eval_reason, s.eval_class, DATE_FORMAT(s.created_at, \(dateOut)) AS created_s, DATE_FORMAT(s.changed_at, \(dateOut)) AS changed_s, DATE_FORMAT(s.last_sent_at, \(dateOut)) AS last_sent_s"
        + ", s.install_id, i.token, i.env, i.locale, i.la_start_token, a.subscription_id AS act_id, a.activity_token, "
        + "DATE_FORMAT(a.started_at, \(dateOut)) AS started, DATE_FORMAT(a.ends_at, \(dateOut)) AS ends "
        + "FROM push_sub s JOIN push_install i ON i.id=s.install_id LEFT JOIN push_activity a ON a.subscription_id=s.id "

    private static func target(_ row: MySQLRow) -> PushActivityTarget? {
        guard let installID = row.column("install_id")?.string, let token = row.column("token")?.string,
              let env = row.column("env")?.string.flatMap(PushEnvironment.init(rawValue:)) else { return nil }
        let install = PushInstallation(token: token, env: env, locale: row.column("locale")?.string ?? "de", liveActivityStartToken: row.column("la_start_token")?.string)
        let sub = subscription(row)
        var activity: PushActivity?
        if row.column("act_id")?.string != nil, let start = row.column("started")?.string.flatMap(TimeUtil.fromSQL),
           let end = row.column("ends")?.string.flatMap(TimeUtil.fromSQL) {
            activity = PushActivity(subscriptionID: sub.id, activityToken: row.column("activity_token")?.string, startedAt: start, endsAt: end)
        }
        return PushActivityTarget(installationID: installID, installation: install, subscription: sub, activity: activity)
    }

    /// Bulk lookup: one query per chunk of 500 ids (never one per subscription).
    public func activityTargets(subscriptionIDs: [String]) async throws -> [PushActivityTarget] {
        var result: [PushActivityTarget] = []
        var index = 0
        while index < subscriptionIDs.count {
            let chunk = Array(subscriptionIDs[index..<min(index + 500, subscriptionIDs.count)])
            index += 500
            let rows = try await connection { conn in
                try await query(conn, Self.targetSelect + "WHERE s.id IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")", chunk.map(str)).rows
            }
            result += rows.compactMap(Self.target)
        }
        return result
    }

    public func endableActivities(now: Date, reservationTimeout: TimeInterval, after: String?, limit: Int) async throws -> [PushActivityTarget] {
        // Starts from the (small) push_activity table; the primary keys of push_sub/push_install are joined, nothing else is scanned.
        try await connection { conn in
            try await query(conn, Self.targetSelect + "WHERE a.subscription_id > ? AND (a.ends_at <= ? OR s.enabled=0 OR s.live_activity=0 OR s.kind<>0 "
                            + "OR (a.activity_token IS NULL AND a.started_at <= ?)) ORDER BY a.subscription_id LIMIT \(max(1, limit))",
                            [str(after ?? ""), ts(now), ts(now.addingTimeInterval(-reservationTimeout))]).rows
        }.compactMap(Self.target)
    }

    public func deleteReservation(subscriptionID: String) async throws -> Bool {
        try await connection { conn in
            try await query(conn, "DELETE FROM push_activity WHERE subscription_id=? AND activity_token IS NULL", [str(subscriptionID)]).affected > 0
        }
    }
    /// Installation row lock serializes reservations across subscriptions and replicas. The transaction runs READ COMMITTED and
    /// the reads after the lock are locking reads: under REPEATABLE READ the first plain SELECT would open a snapshot before the
    /// lock (two subscriptions could both see "no activity"; MariaDB 11 with snapshot isolation fails with error 1020 instead).
    private func writeActivity(subscriptionID: String, token: String?, now: Date) async throws -> PushActivityRegistrationResult {
        try await transaction(readCommitted: true) { conn in
            guard let owner = try await query(conn, "SELECT install_id FROM push_sub WHERE id=?", [str(subscriptionID)]).rows.first?.column("install_id")?.string else { return .notFound }
            guard !(try await query(conn, "SELECT id FROM push_install WHERE id=? FOR UPDATE", [str(owner)])).rows.isEmpty else { return .notFound }
            guard let sub = try await query(conn, "SELECT enabled, live_activity, kind FROM push_sub WHERE id=? AND install_id=? FOR UPDATE", [str(subscriptionID), str(owner)]).rows.first else { return .notFound }
            guard sub.column("enabled")?.int == 1, sub.column("live_activity")?.int == 1, sub.column("kind")?.int == 0 else { return .notEligible }
            let existing = try await query(conn, "SELECT a.subscription_id, DATE_FORMAT(a.ends_at, \(Self.dateOut)) AS ends FROM push_activity a JOIN push_sub s ON s.id=a.subscription_id WHERE s.install_id=? FOR UPDATE", [str(owner)]).rows
            if let row = existing.first {
                guard row.column("subscription_id")?.string == subscriptionID else { return .activityLimit }
                guard let token, let end = row.column("ends")?.string.flatMap(TimeUtil.fromSQL), end > now else { return .notEligible }
                _ = try await query(conn, "UPDATE push_activity SET activity_token=? WHERE subscription_id=?", [str(token), str(subscriptionID)])
            } else {
                _ = try await query(conn, "INSERT INTO push_activity (subscription_id, activity_token, started_at, ends_at) VALUES (?,?,?,?)", [str(subscriptionID), token.map(str) ?? .null, ts(now), ts(now.addingTimeInterval(8 * 3600))])
            }
            return .updated
        }
    }
    public func reserveActivity(subscriptionID: String, now: Date) async throws -> Bool {
        try await writeActivity(subscriptionID: subscriptionID, token: nil, now: now) == .updated
    }
    public func setActivityToken(subscriptionID: String, token: String, now: Date) async throws -> PushActivityRegistrationResult {
        try await writeActivity(subscriptionID: subscriptionID, token: token, now: now)
    }
    public func deleteActivity(subscriptionID: String, matchingToken: String?) async throws -> Bool {
        try await connection { conn in
            if let matchingToken {
                return try await query(conn, "DELETE FROM push_activity WHERE subscription_id=? AND activity_token=?", [str(subscriptionID), str(matchingToken)]).affected > 0
            }
            return try await query(conn, "DELETE FROM push_activity WHERE subscription_id=?", [str(subscriptionID)]).affected > 0
        }
    }
}
