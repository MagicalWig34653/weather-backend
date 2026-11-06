import Foundation

/// Computes the six insights answers (docs-site/content/dashboard-api.md, "Insights") from an `InsightsDataSource`.
/// `nil` from the source means "not collected" and becomes JSON `null`; a throwing section becomes `null` plus a `partial` entry.
/// Only when the statistics themselves cannot be read does a route throw (the router answers `503 data_unavailable`).
public final class InsightsEngine: Sendable {
    let source: any InsightsDataSource
    let clock: @Sendable () -> Date

    public init(source: any InsightsDataSource, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source; self.clock = clock
    }

    // MARK: loading

    struct Loaded {
        let range: InsightsRange
        let now: Date
        let context: InsightsContext
        /// nil = no hourly counters collected.
        let hourly: [InsightsSample]?
        let daily: [InsightsSample]

        /// Metrics that have hourly counters (plan 2.7); all others are day series even for hourly ranges.
        static func hourlyEligible(_ metric: String) -> Bool {
            ["requests", "errors_5xx", "ingest_run", "ingest_lag", "latency"].contains(metric)
                || ["push_", "la_", "apns_", "token_", "install_"].contains { metric.hasPrefix($0) }
        }

        var hourGrid: Bool { range.hourly && hourly != nil }

        func window(_ metric: String) -> (current: InsightsWindow, previous: InsightsWindow) {
            if hourGrid, Self.hourlyEligible(metric), let hourly {
                let end = TimeUtil.floor(now, to: 3600)
                let starts = (0..<range.hours).map { end.addingTimeInterval(-Double(range.hours - 1 - $0) * 3600) }
                let current = InsightsWindow(resolution: "hour", starts: starts, samples: hourly)
                return (current, current.previous(samples: hourly))
            }
            let end = TimeUtil.floor(now, to: 86400)
            let starts = (0..<range.days).map { end.addingTimeInterval(-Double(range.days - 1 - $0) * 86400) }
            let current = InsightsWindow(resolution: "day", starts: starts, samples: daily)
            return (current, current.previous(samples: daily))
        }
    }

    func load(_ range: InsightsRange, now: Date) async throws -> Loaded {
        let context = await source.context()
        let endDay = TimeUtil.floor(now, to: 86400)
        let from = endDay.addingTimeInterval(-Double(range.days * 2 - 1) * 86400)
        let daily = try await source.dailyStats(from: from, to: endDay).map {
            InsightsSample(t: $0.day, metric: $0.metric, label: $0.label, value: $0.value)
        }
        var hourly: [InsightsSample]?
        if range.hourly, let rows = try? await source.hourlyStats(from: TimeUtil.floor(now, to: 3600).addingTimeInterval(-Double(max(range.hours * 2, 72) - 1) * 3600),
                                                                  to: now) {
            hourly = rows.map { InsightsSample(t: $0.hour, metric: $0.metric, label: $0.label, value: $0.value) }
        }
        return Loaded(range: range, now: now, context: context, hourly: hourly, daily: daily)
    }

    private func header(_ l: Loaded) -> [String: IJ] {
        ["generatedAt": .date(l.now), "range": .string(l.range.rawValue), "resolution": .string(l.hourGrid ? "hour" : "day")]
    }

    private static func gauge(_ used: Int, _ max: Int) -> IJ {
        .object(["used": .int(used), "max": .int(max), "ratio": .ratio(max > 0 ? min(1, Double(used) / Double(max)) : 0)])
    }

    private static func cacheTotals(_ w: InsightsWindow) -> (hits: Int, misses: Int, ratio: Double?) {
        let hits = w.sum("cache_hit"), misses = w.sum("cache_miss")
        return (hits, misses, InsightsMath.ratio(hits, of: hits + misses))
    }

    // MARK: findings

    /// Gathers everything the rules need; failed or missing parts are left out (no finding without a data basis).
    func findingInputs(_ l: Loaded) async -> (inputs: InsightsFindingInputs, layerFailed: Bool) {
        var i = InsightsFindingInputs(now: l.now, context: l.context)
        var layerFailed = false
        if let states = try? await source.layers(now: l.now) {
            i.layers = states.map { InsightsFindings.layerView($0, now: l.now, thresholds: l.context.thresholds) }
        } else { layerFailed = true }
        // 5xx share: latest hour bucket (current or previous) with enough traffic; hourly counters only.
        if let hourly = l.hourly {
            let cur = TimeUtil.floor(l.now, to: 3600)
            for t in [cur, cur.addingTimeInterval(-3600)] {
                let s = hourly.filter { $0.t == t }
                let req = s.filter { $0.metric == "requests" }.reduce(0) { $0 + $1.value }
                if req >= InsightsFindings.minRequests5xx {
                    i.errorRate5xx1h = Double(s.filter { $0.metric == "errors_5xx" }.reduce(0) { $0 + $1.value }) / Double(req)
                    break
                }
            }
        }
        let cache = Self.cacheTotals(Loaded(range: .h24, now: l.now, context: l.context, hourly: l.hourly, daily: l.daily).window("cache_hit").current)
        i.cacheHitRatio = cache.ratio; i.cacheLookups = cache.hits + cache.misses
        if l.context.pushEnabled {
            i.gauges = try? await source.pushGauges(now: l.now)
            i.counters = try? await source.pushCounters(range: .h24, now: l.now)
        }
        i.replicaInfo = try? await source.replicaInfo(now: l.now)
        return (i, layerFailed)
    }

    // MARK: overview

    public func overview(range: InsightsRange) async throws -> [String: Any] {
        let now = clock()
        let l = try await load(range, now: now)
        let ctx = l.context
        var partial: [String] = []

        func kpi(value: IJ, unit: String, delta: Double?, level: String, series: InsightsSeries?) -> IJ {
            .object(["value": value, "unit": .string(unit), "deltaPct": .num(delta), "level": .string(level), "series": series?.ij ?? .null])
        }

        let rw = l.window("requests")
        let hasRequests = rw.current.has("requests")
        let total = rw.current.sum("requests")
        let prevTotal: Double? = rw.previous.has("requests") ? Double(rw.previous.sum("requests")) : nil
        let requests = kpi(value: .int(total), unit: "count", delta: hasRequests ? InsightsMath.deltaPct(current: Double(total), previous: prevTotal) : nil,
                           level: hasRequests ? "ok" : "unknown", series: hasRequests ? rw.current.sumSeries("requests") : nil)

        let cw = l.window("cache_hit")
        let cache = Self.cacheTotals(cw.current)
        let prevCache = Self.cacheTotals(cw.previous).ratio
        var cacheLevel = "unknown"
        if let r = cache.ratio { cacheLevel = r < ctx.thresholds.cacheHit.red ? "critical" : (r < ctx.thresholds.cacheHit.yellow ? "warning" : "ok") }
        let cacheSeries = cw.current.series(presence: "cache_hit") { s in
            let h = s.filter { $0.metric == "cache_hit" }.reduce(0) { $0 + $1.value }
            let m = s.filter { $0.metric == "cache_miss" }.reduce(0) { $0 + $1.value }
            return h + m > 0 ? Double(h) / Double(h + m) : nil
        }
        let cacheKpi = kpi(value: .ratio(cache.ratio), unit: "ratio",
                           delta: cache.ratio.flatMap { r in prevCache.flatMap { InsightsMath.deltaPct(current: r, previous: $0) } },
                           level: cacheLevel, series: cache.ratio == nil ? nil : cacheSeries)

        let (inputs, layerFailed) = await findingInputs(l)
        var ageValue: IJ = .null, ageLevel = "unknown"
        if layerFailed { partial.append("ingestAgeSeconds") }
        else if let layers = inputs.layers {
            let known = layers.filter { $0.ageSeconds != nil }
            if let oldest = known.compactMap({ $0.ageSeconds }).max() {
                ageValue = .int(oldest)
                ageLevel = known.contains { $0.level == "critical" } ? "critical" : (known.contains { $0.level == "warning" } ? "warning" : "ok")
            }
        }

        var deliveryValue: IJ = .null, deliveryLevel = "unknown"
        if ctx.pushEnabled, let r = inputs.counters?.delivery?.ratio {
            deliveryValue = .ratio(r)
            deliveryLevel = r < 1 - ctx.thresholds.apnsRejection.red ? "critical" : (r < 1 - ctx.thresholds.apnsRejection.yellow ? "warning" : "ok")
        }
        var activeValue: IJ = .null, activeLevel = "unknown"
        if ctx.pushEnabled {
            if let g = inputs.gauges { activeValue = .int(g.activeActivities); activeLevel = "ok" }
            else if (try? await source.pushGauges(now: now)) == nil { partial.append("activeLiveActivities") }
        }

        let findings = InsightsFindings.evaluate(inputs)
        let anyData = hasRequests || (inputs.layers ?? []).contains { $0.ageSeconds != nil }
        let status: IJ = .object(["level": .string(findings.isEmpty ? (anyData ? "ok" : "unknown") : InsightsFindings.overallLevel(findings)),
                                  "findingCount": .int(findings.count)])
        var out = header(l)
        out["pushEnabled"] = .bool(ctx.pushEnabled); out["pushPaused"] = .bool(ctx.pushEnabled && ctx.pushPaused)
        out["status"] = status
        out["kpis"] = .object(["requests": requests, "cacheHitRatio": cacheKpi,
                               "ingestAgeSeconds": kpi(value: ageValue, unit: "seconds", delta: nil, level: ageLevel, series: nil),
                               "pushDeliveryRatio": kpi(value: deliveryValue, unit: "ratio", delta: nil, level: deliveryLevel, series: nil),
                               "activeLiveActivities": kpi(value: activeValue, unit: "count", delta: nil, level: activeLevel, series: nil)])
        out["notable"] = .array(findings.prefix(5).map { $0.ij })
        out["partial"] = .strings(partial)
        return Self.dict(out)
    }

    // MARK: findings

    public func findings() async throws -> [String: Any] {
        let now = clock()
        let l = try await load(.h24, now: now)
        let (inputs, _) = await findingInputs(l)
        let list = InsightsFindings.evaluate(inputs)
        return Self.dict(["generatedAt": .date(now), "level": .string(InsightsFindings.overallLevel(list)), "findings": .array(list.map { $0.ij })])
    }

    // MARK: ops

    public func ops(range: InsightsRange) async throws -> [String: Any] {
        let now = clock()
        let l = try await load(range, now: now)
        var partial: [String] = []
        var out = header(l)

        // layers
        var layers: [IJ] = []
        do {
            for state in try await source.layers(now: now) {
                let v = InsightsFindings.layerView(state, now: now, thresholds: l.context.thresholds)
                let lag: IJ = .object(["p50Seconds": .opt(state.lag?.p50Seconds), "p95Seconds": .opt(state.lag?.p95Seconds), "series": state.lag?.series?.ij ?? .null])
                layers.append(.object([
                    "id": .string(state.id), "enabled": .bool(state.enabled), "hasData": .bool(state.publishedAt != nil),
                    "latestRun": .opt(state.latestRun), "publishedAt": .date(state.publishedAt), "ageSeconds": .opt(v.ageSeconds),
                    "cadenceSeconds": .int(state.cadenceSeconds), "level": .string(v.level),
                    "runs": .array((state.runs ?? []).suffix(288).map { .object(["slot": .date($0.slot), "result": .string($0.result)]) }),
                    "lag": lag]))
            }
        } catch { partial.append("layers") }
        out["layers"] = .array(layers)

        // errors
        let rw = l.window("requests")
        let (cur, _) = (rw.current, rw.previous)
        var byRoute: [String: Int] = [:]
        for s in cur.samples where s.metric == "errors_5xx" { byRoute[s.label, default: 0] += s.value }
        let routes: [IJ] = byRoute.filter { $0.value > 0 }.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { .object(["route": .string($0.key), "count": .int($0.value)]) }
        var ratio1h: Double?
        if let hourly = l.hourly {
            let curHour = TimeUtil.floor(now, to: 3600)
            for t in [curHour, curHour.addingTimeInterval(-3600)] {
                let s = hourly.filter { $0.t == t }
                let req = s.filter { $0.metric == "requests" }.reduce(0) { $0 + $1.value }
                if req >= InsightsFindings.minRequests5xx { ratio1h = Double(s.filter { $0.metric == "errors_5xx" }.reduce(0) { $0 + $1.value }) / Double(req); break }
            }
        }
        let iw = l.window("ingest_run")
        out["errors"] = .object([
            "status5xx": .object(["series": cur.series(presence: "requests") { s in
                Double(s.filter { $0.metric == "errors_5xx" }.reduce(0) { $0 + $1.value }) }.ij,
                                  "ratio1h": .ratio(ratio1h), "byRoute": .array(routes)]),
            "ingestErrors": iw.current.series(presence: "ingest_run") { s in
                Double(s.filter { $0.metric == "ingest_run" && $0.label.hasSuffix(":error") }.reduce(0) { $0 + $1.value }) }.ij,
            "statsDropped": .int(l.window("stats_dropped").current.sum("stats_dropped")),
        ])

        // cache
        let cw = l.window("cache_hit").current
        let hit = cw.sum("cache_hit"), miss = cw.sum("cache_miss"), looks = hit + miss
        func scope(_ s: String) -> Double? {
            let h = cw.sum("cache_hit") { $0.hasPrefix(s + ":") }, m = cw.sum("cache_miss") { $0.hasPrefix(s + ":") }
            return InsightsMath.ratio(h, of: h + m)
        }
        var fill: IJ = .null
        do {
            if let f = try await source.cacheFill() {
                fill = .object(["bytes": .int(f.bytes), "maxBytes": .int(f.maxBytes), "entries": .int(f.entries), "evictions": .int(f.evictions),
                                "scope": .string("maxOfReplicas")])
            }
        } catch { partial.append("cache") }
        out["cache"] = .object([
            "hitRatio": .ratio(InsightsMath.ratio(hit, of: looks)), "hitRatioRadar": .ratio(scope("radar")), "hitRatioLayer": .ratio(scope("layer")),
            "negativeShare": .ratio(InsightsMath.ratio(cw.sum("cache_hit") { $0.hasSuffix(":negative") }, of: looks)),
            "joinedShare": .ratio(InsightsMath.ratio(cw.sum("cache_hit") { $0.hasSuffix(":joined") }, of: looks)),
            "dbReads": .int(miss),
            "series": cw.series(presence: "cache_hit") { s in
                let h = s.filter { $0.metric == "cache_hit" }.reduce(0) { $0 + $1.value }
                let m = s.filter { $0.metric == "cache_miss" }.reduce(0) { $0 + $1.value }
                return h + m > 0 ? Double(h) / Double(h + m) : nil }.ij,
            "fill": fill])

        // latency (not collected yet: null)
        var latency: IJ = .null
        do {
            if let routesLat = try await source.latency(range: range, now: now) {
                latency = .array(routesLat.map { r in
                    .object(["route": .string(r.route), "buckets": .array(r.buckets.map { .object(["le": .string($0.le), "count": .int($0.count)]) }),
                             "p50Ms": .opt(r.p50Ms), "p95Ms": .opt(r.p95Ms), "p99Ms": .opt(r.p99Ms)])
                })
            }
        } catch { partial.append("latency") }
        out["latency"] = latency

        // replicas, leader, generation
        var replicas: [IJ] = [], generation: IJ = .null, leader: IJ = .null
        do {
            let info = try await source.replicaInfo(now: now)
            let holderID = info.leader?.holder.map(DashboardApi.shortID)
            replicas = info.replicas.map { r in
                let id = DashboardApi.shortID(r.replicaID)
                return .object(["id": .string(id), "startedAt": .date(r.startedAt), "ageSeconds": .int(max(0, Int(now.timeIntervalSince(r.startedAt)))),
                                "appliedGeneration": .int(r.appliedGeneration), "revision": .opt(r.revision),
                                "level": .string(r.appliedGeneration >= info.generation ? "ok" : "warning"),
                                "isLeader": .bool(holderID == id)])
            }
            generation = .int(info.generation)
            if let lead = info.leader {
                leader = .object(["holder": .opt(holderID), "leaseSecondsLeft": .opt(lead.leaseSecondsLeft), "changes24h": .int(lead.changes24h)])
            }
        } catch { partial.append("replicas") }
        out["replicas"] = .array(replicas); out["generation"] = generation; out["leader"] = leader

        var db: IJ = .null
        do {
            if let d = try await source.databaseInfo() {
                db = .object(["poolUsage": .ratio(d.poolUsage), "errors24h": .opt(d.errors24h), "migration": .opt(d.migration)])
            }
        } catch { partial.append("db") }
        out["db"] = db
        out["partial"] = .strings(partial)
        return Self.dict(out)
    }

    // MARK: traffic

    public func traffic(range: InsightsRange) async throws -> [String: Any] {
        let now = clock()
        let l = try await load(range, now: now)
        let w = l.window("requests").current
        let has = w.has("requests")
        let total = w.sum("requests")
        let group = { (label: String) -> String in String(label.split(separator: ":", maxSplits: 1).first ?? "other") }
        var counts: [String: Int] = [:], bytes: [String: Int] = [:], classes: [String: Int] = [:]
        for s in w.samples {
            if s.metric == "requests" {
                counts[group(s.label), default: 0] += s.value
                let cls = String(s.label.split(separator: ":", maxSplits: 1).last ?? "")
                let mapped = cls == "304" ? "3xx" : cls
                if ["2xx", "3xx", "4xx", "5xx"].contains(mapped) { classes[mapped, default: 0] += s.value }
            } else if s.metric == "bytes_out" { bytes[group(s.label), default: 0] += s.value }
        }
        let notModified = w.sum("requests") { $0.hasSuffix(":304") }
        let byRoute: [IJ] = counts.filter { $0.value > 0 }.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { .object(["route": .string($0.key), "count": .int($0.value), "bytes": .int(bytes[$0.key] ?? 0)]) }

        // The other counters have day series only; they use the day window of the range.
        let dw = Loaded(range: range, now: now, context: l.context, hourly: nil, daily: l.daily).window("rate_limited").current
        let limited: [IJ] = has ? ["push", "dashboard", "other"].map { k in .object(["kind": .string(k), "count": .int(dw.sum("rate_limited") { $0 == k })]) } : []
        let pages: [IJ] = has ? StatsRoute.pages.map { p in .object(["page": .string(p), "count": .int(dw.sum("page_view") { $0 == p })]) } : []

        var hourly: IJ = .null
        if let rows = l.hourly {
            let cut = now.addingTimeInterval(-72 * 3600)
            var cells: [Date: Int] = [:]
            for r in rows where r.metric == "requests" && r.t > cut { cells[r.t, default: 0] += r.value }
            if !cells.isEmpty {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
                hourly = .object(["cells": .array(cells.keys.sorted().map { t in
                    let c = cal.dateComponents([.year, .month, .day, .hour], from: t)
                    return .object(["date": .string(String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)),
                                    "hour": .int(c.hour ?? 0), "count": .int(cells[t] ?? 0)])
                })])
            }
        }

        var out = header(l)
        out["partial"] = .strings([])
        out["requests"] = .object([
            "total": .int(total), "series": w.sumSeries("requests").ij, "notModifiedShare": .ratio(InsightsMath.ratio(notModified, of: total)),
            "byRoute": .array(byRoute),
            "byStatusClass": .array(has ? ["2xx", "3xx", "4xx", "5xx"].map { .object(["class": .string($0), "count": .int(classes[$0] ?? 0)]) } : [])])
        out["rateLimited"] = .array(limited); out["pageViews"] = .array(pages); out["hourly"] = hourly
        return Self.dict(out)
    }

    // MARK: push

    public func push(range: InsightsRange) async throws -> [String: Any] {
        let now = clock()
        let l = try await load(range, now: now)
        let ctx = l.context
        let k = ctx.thresholds.minGroup
        var out = header(l)
        out["pushEnabled"] = .bool(ctx.pushEnabled); out["pushPaused"] = .bool(ctx.pushEnabled && ctx.pushPaused)

        var prereq: [IJ] = [.object(["key": .string("push_enabled"), "ok": .bool(ctx.pushEnabled), "detail": .null])]
        guard ctx.pushEnabled else {
            for key in ["funnel", "triggers", "skipped", "lifecycle", "locks", "apnsErrors", "delivery", "outbox", "tokenInvalidations", "timing", "registrations", "rejects", "caps"] {
                out[key] = .null
            }
            out["prerequisites"] = .array(prereq); out["partial"] = .strings([])
            return Self.dict(out)
        }

        var partial: [String] = []
        var gauges: InsightsPushGauges?
        do { gauges = try await source.pushGauges(now: now) } catch { partial.append("funnel") }
        var counters: InsightsPushCounters?
        do { counters = try await source.pushCounters(range: range, now: now) } catch { partial.append("counters") }

        // prerequisites (fixed identifiers, never configuration values)
        if let apns = ctx.setup.apnsEnv, let g = gauges {
            let wrong = apns == "production" ? "sandbox" : "production"
            let bad = g.byEnv[wrong] ?? 0
            prereq.append(.object(["key": .string("apns_env_match"), "ok": .bool(bad == 0),
                                   "detail": bad == 0 ? .null : .string("\(wrong)_installs_with_\(apns)_env")]))
        }
        prereq.append(.object(["key": .string("apns_topic_set"), "ok": .bool(ctx.setup.topicSet), "detail": .null]))
        prereq.append(.object(["key": .string("apns_key_present"), "ok": .bool(ctx.setup.keyPresent), "detail": .null]))
        prereq.append(.object(["key": .string("capability_live_activity"), "ok": .bool(ctx.setup.liveActivityCapability), "detail": .null]))
        prereq.append(.object(["key": .string("push_not_paused"), "ok": .bool(!ctx.pushPaused), "detail": .null]))
        out["prerequisites"] = .array(prereq)

        if let g = gauges {
            out["funnel"] = .object([
                "installations": .object(["total": .int(g.installationsTotal), "active1d": .int(g.active1d), "active7d": .int(g.active7d), "active30d": .int(g.active30d),
                                          "byEnv": .array(InsightsSuppression.buckets(keys: ["sandbox", "production"], g.byEnv, k: k)),
                                          "byLocale": .array(InsightsSuppression.buckets(keys: ["de", "en"], g.byLocale, k: k))]),
                "tokens": .object(["withDeviceToken": .int(g.withDeviceToken), "withStartToken": .int(g.withStartToken),
                                   "startTokenAge": .array(g.startTokenAge.map { InsightsSuppression.buckets(keys: ["lt1d", "lt7d", "lt30d", "older"], $0, k: k) } ?? [])]),
                "subscriptions": .object(["total": .int(g.subscriptionsTotal), "enabled": .int(g.subscriptionsEnabled), "liveActivity": .int(g.subscriptionsLiveActivity),
                                          "liveActivityWithStartToken": .int(g.subscriptionsLiveActivityWithStartToken),
                                          "inconsistent": .int(max(0, g.subscriptionsLiveActivity - g.subscriptionsLiveActivityWithStartToken))])])
            let events: [IJ] = (counters?.lifecycleEvents ?? []).map { .object(["event": .string($0.event), "outcome": .string($0.outcome), "count": .int($0.count)]) }
            out["lifecycle"] = .object(["events": .array(events), "activeNow": .int(g.activeActivities), "reservationsOpen": .int(g.reservationsOpen),
                                        "reservationsExpired": .int(g.reservationsExpired)])
            out["locks"] = .object(["activeLocks": .int(g.activeLocks), "activitySlots": Self.gauge(g.subscriptionsLiveActivity, ctx.caps.activitySubscriptions)])
            out["outbox"] = .object(["waiting": .int(g.outboxWaiting), "oldestAgeSeconds": .opt(g.outboxOldestAgeSeconds), "retrying": .int(g.outboxRetrying),
                                     "droppedOrExpired24h": .int(g.outboxDroppedOrExpired24h)])
            out["caps"] = .array(Self.caps(g, ctx.caps))
        } else {
            for key in ["funnel", "lifecycle", "locks", "outbox", "caps"] { out[key] = .null }
        }

        let c = counters
        out["triggers"] = c?.triggers.map { .array($0.map { .object(["trigger": .string($0.trigger), "count": .int($0.count)]) }) } ?? .null
        out["skipped"] = c?.skipped.map { .array($0.map { .object(["trigger": .string($0.trigger), "reason": .string($0.reason), "count": .int($0.count)]) }) } ?? .null
        out["apnsErrors"] = c?.apnsErrors.map { .array($0.map { .object(["kind": .string($0.kind), "reason": .string($0.reason), "env": .string($0.env), "count": .int($0.count)]) }) } ?? .null
        out["delivery"] = c?.delivery.map { d in
            .object(["created": .int(d.created), "sent": .int(d.sent), "delivered": .int(d.delivered), "rejected": .int(d.rejected), "dropped": .int(d.dropped),
                     "retry": .int(d.retry), "ratio": .ratio(d.ratio), "avgAttempts": .num(d.avgAttempts, decimals: 2)])
        } ?? .null
        out["tokenInvalidations"] = c?.tokenInvalidations.map { .array($0.map { .object(["kind": .string($0.kind), "cause": .string($0.cause), "count": .int($0.count)]) }) } ?? .null
        out["timing"] = c?.timing.map { t in
            .object(["apnsSendMs": .array(t.apnsSendMs.map { .object(["le": .string($0.le), "count": .int($0.count)]) }), "evalMsP95": .opt(t.evalMsP95),
                     "cellsChecked": .opt(t.cellsChecked), "cellsMax": .int(ctx.caps.regionCells)])
        } ?? .null
        out["registrations"] = c?.registrations.map { r in
            .object(["created": r.created.ij, "deleted": r.deleted.ij, "retained7dRatio": .ratio(r.retained7dRatio)])
        } ?? .null
        out["rejects"] = c?.rejects.map { .array($0.map { .object(["code": .string($0.code), "count": .int($0.count)]) }) } ?? .null
        out["partial"] = .strings(partial)
        return Self.dict(out)
    }

    private static func caps(_ g: InsightsPushGauges, _ limits: InsightsCapLimits) -> [IJ] {
        [("installations", g.installationsTotal, limits.installations), ("subscriptions", g.subscriptionsTotal, limits.subscriptions),
         ("region_cells", g.regionCells, limits.regionCells), ("activity_subscriptions", g.subscriptionsLiveActivity, limits.activitySubscriptions)]
            .map { .object(["key": .string($0.0), "gauge": gauge($0.1, $0.2)]) }
    }

    // MARK: distribution

    public func distribution() async throws -> [String: Any] {
        let now = clock()
        let ctx = await source.context()
        let k = ctx.thresholds.minGroup
        var partial: [String] = []
        var g: InsightsPushGauges?
        do { g = try await source.pushGauges(now: now) } catch { partial.append("distribution") }
        var out: [String: IJ] = ["generatedAt": .date(now), "minGroup": .int(k)]
        guard let g, g.installationsTotal > 0 || g.subscriptionsTotal > 0 else {
            for key in ["subscriptionsPerInstallation", "regionsPerInstallation", "threshold", "lead", "locale", "env"] { out[key] = .array([]) }
            out["timeSensitiveShare"] = .null; out["liveActivityShare"] = .null
            out["caps"] = .array(g.map { Self.caps($0, ctx.caps).prefix(1).map { $0 } } ?? [])
            out["partial"] = .strings(partial)
            return Self.dict(out)
        }
        let thresholdKeys = g.threshold.keys.compactMap(Int.init).sorted().map(String.init)
        out["subscriptionsPerInstallation"] = .array(InsightsSuppression.buckets(keys: ["0", "1", "2", "3+"], g.subscriptionsPerInstallation, k: k))
        out["regionsPerInstallation"] = .array(InsightsSuppression.buckets(keys: ["0", "1", "2", "3"], g.regionsPerInstallation, k: k))
        out["threshold"] = .array(InsightsSuppression.buckets(keys: thresholdKeys, g.threshold, k: k))
        out["lead"] = .array(InsightsSuppression.buckets(keys: ["10", "20", "30"], g.lead, k: k))
        out["locale"] = .array(InsightsSuppression.buckets(keys: ["de", "en"], g.byLocale, k: k))
        out["env"] = .array(InsightsSuppression.buckets(keys: ["sandbox", "production"], g.byEnv, k: k))
        out["timeSensitiveShare"] = InsightsSuppression.share(g.subscriptionsTimeSensitive, of: g.subscriptionsTotal, k: k)
        out["liveActivityShare"] = InsightsSuppression.share(g.subscriptionsLiveActivity, of: g.subscriptionsTotal, k: k)
        out["caps"] = .array(Self.caps(g, ctx.caps))
        out["partial"] = .strings(partial)
        return Self.dict(out)
    }

    // MARK: serialisation

    /// Plain dictionary form (`DashboardApi.object` serialises it with sorted keys, explicit nulls).
    static func dict(_ fields: [String: IJ]) -> [String: Any] { fields.mapValues(Self.any) }

    static func any(_ j: IJ) -> Any {
        switch j {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(any)
        case .object(let v): return v.mapValues(any)
        }
    }
}
