import Foundation

/// `Finding` of the contract. Computed on every request from the thresholds (no background service, nothing is sent).
public struct InsightsFinding: Sendable, Equatable {
    public var code: String
    /// `warning` or `critical`.
    public var level: String
    public var subject: String?
    public var value: Double
    public var threshold: Double
    /// `ratio`, `seconds`, `count` or `percent`.
    public var unit: String
    public var since: Date?

    var severity: Int { level == "critical" ? 2 : 1 }

    var ij: IJ {
        .object(["code": .string(code), "level": .string(level), "subject": .opt(subject),
                 "value": unit == "ratio" ? .ratio(value) : (value == value.rounded() ? .int(Int(value)) : .num(value, decimals: 2)),
                 "threshold": threshold == threshold.rounded() ? .int(Int(threshold)) : .num(threshold, decimals: 4),
                 "unit": .string(unit), "since": .date(since)])
    }
}

/// Inputs of the rules; every field is optional because a failed or not collected source simply produces no finding.
struct InsightsFindingInputs {
    var now: Date
    var context: InsightsContext
    var layers: [InsightsLayerView]?
    /// Share of 5xx in the latest hour bucket with enough traffic (hourly counters only).
    var errorRate5xx1h: Double?
    var cacheHitRatio: Double?
    var cacheLookups = 0
    var gauges: InsightsPushGauges?
    var counters: InsightsPushCounters?
    var replicaInfo: InsightsReplicaInfo?
    /// Requests of today's day counters when the hourly table has no `requests` rows of the last hours (nil = fine or too few requests).
    var hourlyMissingDayRequests: Int?
    /// Failed statistics flushes (day or hour table) in the last 24 h.
    var statsFlushErrors24h = 0
}

/// One layer with derived age and level.
struct InsightsLayerView {
    var state: InsightsLayerState
    var ageSeconds: Int?
    var level: String
    var cadence: Int { state.cadenceSeconds }
}

enum InsightsFindings {
    /// Minimum base for ratio rules (a single failed request must not turn the dashboard red).
    static let minRequests5xx = 20
    static let minCacheLookups = 50
    static let minLaStartCases = 10

    static func layerView(_ state: InsightsLayerState, now: Date, thresholds: InsightsThresholds) -> InsightsLayerView {
        guard state.enabled, let published = state.publishedAt else {
            return InsightsLayerView(state: state, ageSeconds: nil, level: "unknown")
        }
        let age = max(0, Int(now.timeIntervalSince(published)))
        let cadence = Double(state.cadenceSeconds)
        var level = "ok"
        if Double(age) > thresholds.layerAgeFactor.red * cadence { level = "critical" }
        else if Double(age) > thresholds.layerAgeFactor.yellow * cadence { level = "warning" }
        // Three missed slots in a row are critical regardless of age.
        if let runs = state.runs, runs.count >= 3, runs.suffix(3).allSatisfy({ $0.result == "missed" }) { level = "critical" }
        return InsightsLayerView(state: state, ageSeconds: age, level: level)
    }

    static func evaluate(_ i: InsightsFindingInputs) -> [InsightsFinding] {
        let t = i.context.thresholds
        var out: [InsightsFinding] = []

        // layer_stale
        for l in i.layers ?? [] where l.level == "warning" || l.level == "critical" {
            guard let age = l.ageSeconds else { continue }
            let factor = l.level == "critical" ? t.layerAgeFactor.red : t.layerAgeFactor.yellow
            out.append(InsightsFinding(code: "layer_stale", level: l.level, subject: l.state.id, value: Double(age),
                                       threshold: factor * Double(l.cadence), unit: "seconds", since: l.state.publishedAt))
        }
        // error_rate_5xx
        if let r = i.errorRate5xx1h { upper(&out, "error_rate_5xx", nil, r, t.errorRate5xx, "ratio") }
        // outbox_age (push only)
        if i.context.pushEnabled, let age = i.gauges?.outboxOldestAgeSeconds { upper(&out, "outbox_age", nil, Double(age), t.outboxAgeSeconds, "seconds") }
        // apns_rejection
        if i.context.pushEnabled, let r = i.counters?.apnsRejectionRatio1h {
            let critical = (i.counters?.apnsCriticalReasons1h ?? 0) > 0
            if critical { out.append(InsightsFinding(code: "apns_rejection", level: "critical", subject: nil, value: r, threshold: t.apnsRejection.red, unit: "ratio", since: nil)) }
            else { upper(&out, "apns_rejection", nil, r, t.apnsRejection, "ratio") }
        }
        // token_invalidation
        if i.context.pushEnabled, let r = i.counters?.tokenInvalidationRatio24h { upper(&out, "token_invalidation", nil, r, t.tokenInvalidation, "ratio") }
        // replicas_missing, leader_missing
        if let info = i.replicaInfo {
            if info.replicas.isEmpty {
                out.append(InsightsFinding(code: "replicas_missing", level: "critical", subject: nil, value: 0, threshold: Double(max(1, i.context.expectedReplicas ?? 1)), unit: "count", since: nil))
            } else if let expected = i.context.expectedReplicas, info.replicas.count < expected {
                out.append(InsightsFinding(code: "replicas_missing", level: "warning", subject: nil, value: Double(info.replicas.count), threshold: Double(expected), unit: "count", since: nil))
            }
            if i.context.pushEnabled, let leader = info.leader, leader.holder == nil || (leader.leaseSecondsLeft ?? 1) <= 0 {
                out.append(InsightsFinding(code: "leader_missing", level: "critical", subject: nil, value: 0, threshold: 1, unit: "count", since: nil))
            }
        }
        // cache_hit_low
        if let r = i.cacheHitRatio, i.cacheLookups >= minCacheLookups { lower(&out, "cache_hit_low", nil, r, t.cacheHit, "ratio") }
        // cap_fill
        if let g = i.gauges, i.context.pushEnabled {
            let caps: [(String, Int, Int)] = [("installations", g.installationsTotal, i.context.caps.installations),
                                              ("subscriptions", g.subscriptionsTotal, i.context.caps.subscriptions),
                                              ("region_cells", g.regionCells, i.context.caps.regionCells),
                                              ("activity_subscriptions", g.subscriptionsLiveActivity, i.context.caps.activitySubscriptions)]
            for (key, used, max) in caps where max > 0 { upper(&out, "cap_fill", key, Double(used) / Double(max), t.capFill, "ratio") }
        }
        // la_start_ratio_low
        if i.context.pushEnabled, let n = i.counters?.laStartTriggers24h, let ok = i.counters?.laStartDelivered24h, n >= minLaStartCases {
            lower(&out, "la_start_ratio_low", nil, Double(ok) / Double(n), t.laStartRatio, "ratio")
        }
        // stats_hourly_empty: day counters have traffic, the hourly table does not (hour series would be an empty line).
        if let n = i.hourlyMissingDayRequests {
            out.append(InsightsFinding(code: "stats_hourly_empty", level: "warning", subject: nil, value: Double(n), threshold: Double(minRequests5xx), unit: "count", since: nil))
        }
        // stats_write_error: the flush into stats_daily or stats_hourly failed (counted without any error text).
        if i.statsFlushErrors24h > 0 {
            out.append(InsightsFinding(code: "stats_write_error", level: "warning", subject: nil, value: Double(i.statsFlushErrors24h), threshold: 0, unit: "count", since: nil))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    private static func upper(_ out: inout [InsightsFinding], _ code: String, _ subject: String?, _ value: Double, _ p: InsightsThresholds.Pair, _ unit: String) {
        if value > p.red { out.append(InsightsFinding(code: code, level: "critical", subject: subject, value: value, threshold: p.red, unit: unit, since: nil)) }
        else if value > p.yellow { out.append(InsightsFinding(code: code, level: "warning", subject: subject, value: value, threshold: p.yellow, unit: unit, since: nil)) }
    }

    private static func lower(_ out: inout [InsightsFinding], _ code: String, _ subject: String?, _ value: Double, _ p: InsightsThresholds.Pair, _ unit: String) {
        if value < p.red { out.append(InsightsFinding(code: code, level: "critical", subject: subject, value: value, threshold: p.red, unit: unit, since: nil)) }
        else if value < p.yellow { out.append(InsightsFinding(code: code, level: "warning", subject: subject, value: value, threshold: p.yellow, unit: unit, since: nil)) }
    }

    static func overallLevel(_ findings: [InsightsFinding]) -> String {
        findings.contains { $0.level == "critical" } ? "critical" : (findings.isEmpty ? "ok" : "warning")
    }
}
