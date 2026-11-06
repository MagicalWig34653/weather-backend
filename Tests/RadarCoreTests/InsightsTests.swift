import Foundation
import Testing
@testable import RadarCore

// Insights routes (WP12): contract shape against docs/fixtures/dashboard/insights-*.json, k-suppression, findings, partial failure,
// privacy scan. Fake data source, no network; repo-backed cases are in InsightsRepoTests.

private let now = TimeUtil.fromSQL("2026-11-06 09:15:00")!
private func hour(_ h: Int, day: Int = 6) -> Date { TimeUtil.fromSQL(String(format: "2026-11-%02d %02d:00:00", day, h))! }

struct FakeFailure: Error {}

/// Configurable source: everything defaults to "not collected".
struct FakeSource: InsightsDataSource {
    var ctx = InsightsContext(pushEnabled: true, caps: InsightsCapLimits(installations: 50000, subscriptions: 100000, regionCells: 2_000_000, activitySubscriptions: 5000))
    var daily: [StatRow] = []
    var hourlyRows: [HourlyStatRow]?
    var layerStates: [InsightsLayerState] = []
    var layersFail = false
    var statsFail = false
    var replicaInfoValue = InsightsReplicaInfo(replicas: [InsightsReplica(replicaID: "replica-a", startedAt: now.addingTimeInterval(-60), appliedGeneration: 4)], generation: 4,
                                               leader: InsightsLeader(holder: "replica-a", leaseSecondsLeft: 28, changes24h: 0))
    var fill: InsightsCacheFill?
    var latencyRoutes: [InsightsLatencyRoute]?
    var db: InsightsDatabaseInfo?
    var gauges: InsightsPushGauges?
    var gaugesFail = false
    var counters: InsightsPushCounters?

    func context() async -> InsightsContext { ctx }
    func dailyStats(from: Date, to: Date) async throws -> [StatRow] { if statsFail { throw FakeFailure() }; return daily }
    func hourlyStats(from: Date, to: Date) async throws -> [HourlyStatRow]? { hourlyRows }
    func layers(now: Date) async throws -> [InsightsLayerState] { if layersFail { throw FakeFailure() }; return layerStates }
    func replicaInfo(now: Date) async throws -> InsightsReplicaInfo { replicaInfoValue }
    func cacheFill() async throws -> InsightsCacheFill? { fill }
    func latency(range: InsightsRange, now: Date) async throws -> [InsightsLatencyRoute]? { latencyRoutes }
    func databaseInfo() async throws -> InsightsDatabaseInfo? { db }
    func pushGauges(now: Date) async throws -> InsightsPushGauges? { if gaugesFail { throw FakeFailure() }; return gauges }
    func pushCounters(range: InsightsRange, now: Date) async throws -> InsightsPushCounters? { counters }
}

private func engine(_ source: FakeSource) -> InsightsEngine { InsightsEngine(source: source, clock: { now }) }

private func jsonObject(_ dict: [String: Any]) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: dict))
}

// MARK: shape comparison

/// Compares key sets and JSON types (null on either side is tolerated: it depends on the data, not on the contract).
private func shapeDiffs(_ mine: Any, _ fixture: Any, path: String = "$") -> [String] {
    if mine is NSNull || fixture is NSNull { return [] }
    switch (mine, fixture) {
    case let (a as [String: Any], b as [String: Any]):
        var out: [String] = []
        for k in Set(a.keys).symmetricDifference(b.keys).sorted() { out.append("\(path).\(k): key only on one side (\(a[k] == nil ? "fixture" : "mine"))") }
        for k in Set(a.keys).intersection(b.keys) { out += shapeDiffs(a[k]!, b[k]!, path: path + "." + k) }
        return out
    case let (a as [Any], b as [Any]):
        guard let x = a.first, let y = b.first else { return [] }
        // Heterogeneous arrays (e.g. objects with optional members) are compared element-wise by first element.
        return shapeDiffs(x, y, path: path + "[0]")
    case let (a as NSNumber, b as NSNumber):
        let aBool = isJSONBool(a), bBool = isJSONBool(b)
        return aBool == bBool ? [] : ["\(path): bool vs number"]
    case (is String, is String): return []
    default: return ["\(path): type \(type(of: mine)) vs \(type(of: fixture))"]
    }
}

private func fixture(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "docs/fixtures/dashboard/" + name)))
}

// MARK: sample data

private func requestRows(_ day: Date, total: Int, e5xx: Int = 0, s304: Int = 0) -> [StatRow] {
    [StatRow(day: day, metric: "requests", label: "radar_image:2xx", value: total - s304 - e5xx),
     StatRow(day: day, metric: "requests", label: "radar_image:304", value: s304),
     StatRow(day: day, metric: "requests", label: "push:5xx", value: e5xx),
     StatRow(day: day, metric: "errors_5xx", label: "push", value: e5xx),
     StatRow(day: day, metric: "bytes_out", label: "radar_image", value: total * 100)]
}

private func hourlyRequests(hours: Int, per: Int = 100, e5xx: Int = 0) -> [HourlyStatRow] {
    (0..<hours).flatMap { i -> [HourlyStatRow] in
        let t = TimeUtil.floor(now, to: 3600).addingTimeInterval(-Double(i) * 3600)
        return [HourlyStatRow(hour: t, metric: "requests", label: "radar_image:2xx", value: per),
                HourlyStatRow(hour: t, metric: "errors_5xx", label: "radar_image", value: e5xx)]
    }
}

private func busyDaily() -> [StatRow] {
    let today = TimeUtil.floor(now, to: 86400)
    var rows: [StatRow] = []
    for d in 0..<8 {
        let day = today.addingTimeInterval(-Double(d) * 86400)
        rows += requestRows(day, total: 1000, e5xx: 1, s304: 400)
        rows += [StatRow(day: day, metric: "cache_hit", label: "radar:memory", value: 900), StatRow(day: day, metric: "cache_hit", label: "layer:negative", value: 30),
                 StatRow(day: day, metric: "cache_hit", label: "layer:joined", value: 60), StatRow(day: day, metric: "cache_miss", label: "radar:db", value: 10),
                 StatRow(day: day, metric: "ingest_run", label: "radar:error", value: 1), StatRow(day: day, metric: "ingest_run", label: "radar:ok", value: 280),
                 StatRow(day: day, metric: "rate_limited", label: "push", value: 3), StatRow(day: day, metric: "page_view", label: "landing_de", value: 40),
                 StatRow(day: day, metric: "stats_dropped", label: "", value: 0)]
    }
    return rows
}

private func fullGauges() -> InsightsPushGauges {
    var g = InsightsPushGauges()
    g.installationsTotal = 120; g.active1d = 61; g.active7d = 98; g.active30d = 117
    g.byEnv = ["sandbox": 2, "production": 118]; g.byLocale = ["de": 96, "en": 24]
    g.withDeviceToken = 119; g.withStartToken = 80; g.startTokenAge = ["lt1d": 41, "lt7d": 25, "lt30d": 11, "older": 3]
    g.subscriptionsTotal = 203; g.subscriptionsEnabled = 190; g.subscriptionsLiveActivity = 64; g.subscriptionsLiveActivityWithStartToken = 64
    g.subscriptionsTimeSensitive = 36
    g.subscriptionsPerInstallation = ["0": 9, "1": 71, "2": 30, "3+": 10]; g.regionsPerInstallation = ["0": 108, "1": 3, "2": 9]
    g.threshold = ["3": 40, "5": 55, "8": 3]; g.lead = ["10": 22, "20": 66, "30": 32]
    g.regionCells = 8200; g.activeActivities = 2; g.activeLocks = 7
    g.outboxWaiting = 0; g.outboxRetrying = 0; g.outboxOldestAgeSeconds = nil; g.outboxDroppedOrExpired24h = 0
    return g
}

private func fullCounters() -> InsightsPushCounters {
    var c = InsightsPushCounters()
    c.triggers = [("rain_start", 37), ("la_rain_start", 12)]
    c.skipped = [("la_rain_start", "lock_60min", 9)]
    c.lifecycleEvents = [("start", "delivered", 14)]
    c.apnsErrors = [("start", "BadDeviceToken", "production", 1)]
    c.delivery = .init(created: 54, sent: 54, delivered: 53, rejected: 1, dropped: 0, retry: 2, ratio: 0.981, avgAttempts: 1.04)
    c.tokenInvalidations = [("device", "410", 4)]
    c.timing = .init(apnsSendMs: [("50ms", 12)], evalMsP95: 420, cellsChecked: 912)
    let series = InsightsSeries(resolution: "hour", points: [.init(t: hour(4), v: 1), .init(t: hour(5), v: 0)])
    c.registrations = .init(created: series, deleted: series, retained7dRatio: 0.82)
    c.rejects = [("start_token_required", 3)]
    return c
}

private func layerStates() -> [InsightsLayerState] {
    [InsightsLayerState(id: "radar", enabled: true, latestRun: "20261106T0910Z", publishedAt: now.addingTimeInterval(-80), cadenceSeconds: 300,
                        runs: [InsightsLayerRun(slot: hour(7), result: "ok"), InsightsLayerRun(slot: hour(7).addingTimeInterval(300), result: "missed")],
                        lag: InsightsLayerLag(p50Seconds: 190, p95Seconds: 260, series: InsightsSeries(resolution: "hour", points: [.init(t: hour(8), v: 190)]))),
     InsightsLayerState(id: "lightning", enabled: false, latestRun: nil, publishedAt: nil, cadenceSeconds: 300)]
}

private func fullSource() -> FakeSource {
    var s = FakeSource()
    s.daily = busyDaily()
    s.hourlyRows = hourlyRequests(hours: 72) + (0..<3).flatMap { i in
        [HourlyStatRow(hour: TimeUtil.floor(now, to: 3600).addingTimeInterval(-Double(i) * 3600), metric: "ingest_run", label: "radar:error", value: 1)]
    }
    s.layerStates = layerStates()
    s.fill = InsightsCacheFill(bytes: 48_234_496, maxBytes: 67_108_864, entries: 212, evictions: 14)
    s.latencyRoutes = [InsightsLatencyRoute(route: "radar_image", buckets: [("10ms", 5), ("inf", 1)], p50Ms: 10, p95Ms: 50, p99Ms: 200)]
    s.db = InsightsDatabaseInfo(poolUsage: 0.31, errors24h: 0, migration: "010_insights")
    s.gauges = fullGauges(); s.counters = fullCounters()
    return s
}

// MARK: contract

@Suite("Insights contract")
struct InsightsContractTests {
    private func check(_ name: String, _ dict: [String: Any], sourceLine: Int = #line) throws {
        let diffs = shapeDiffs(try jsonObject(dict), try fixture(name))
        #expect(diffs.isEmpty, "\(name): \(diffs)")
    }

    @Test func overviewMatchesFixtures() async throws {
        let e = engine(fullSource())
        try check("insights-overview.200.json", try await e.overview(range: .h24))
        var broken = fullSource(); broken.layersFail = true
        let partial = try await engine(broken).overview(range: .d7)
        try check("insights-overview.partial.json", partial)
        #expect(partial["partial"] as? [String] == ["ingestAgeSeconds"])
        var empty = FakeSource(); empty.ctx.pushEnabled = false
        let em = try await engine(empty).overview(range: .h24)
        try check("insights-overview.empty.json", em)
        #expect((em["resolution"] as? String) == "day")
        #expect(((em["status"] as? [String: Any])?["level"] as? String) == "unknown")
    }

    @Test func findingsMatchFixtures() async throws {
        var s = fullSource(); s.daily = busyDaily().filter { $0.metric != "cache_hit" } + [StatRow(day: TimeUtil.floor(now, to: 86400), metric: "cache_hit", label: "radar:memory", value: 70),
                                                                                           StatRow(day: TimeUtil.floor(now, to: 86400), metric: "cache_miss", label: "radar:db", value: 30)]
        s.layerStates[0].publishedAt = now.addingTimeInterval(-1500)
        let list = try await engine(s).findings()
        try check("insights-findings.200.json", list)
        #expect((list["findings"] as? [[String: Any]])?.map { $0["code"] as? String } == ["layer_stale", "cache_hit_low"])
        try check("insights-findings.ok.json", try await engine(fullSource()).findings())
        var c = fullSource(); c.counters?.apnsRejectionRatio1h = 0.31; c.gauges?.outboxOldestAgeSeconds = 240
        let crit = try await engine(c).findings()
        try check("insights-findings.critical.json", crit)
        #expect(crit["level"] as? String == "critical")
        #expect((crit["findings"] as? [[String: Any]])?.map { $0["code"] as? String } == ["apns_rejection", "outbox_age"])
    }

    @Test func opsMatchesFixtures() async throws {
        try check("insights-ops.200.json", try await engine(fullSource()).ops(range: .h24))
        var empty = FakeSource(); empty.fill = nil
        empty.layerStates = [InsightsLayerState(id: "radar", enabled: true, latestRun: nil, publishedAt: nil, cadenceSeconds: 300)]
        let o = try await engine(empty).ops(range: .h24)
        try check("insights-ops.empty.json", o)
        #expect(o["latency"] is NSNull && o["db"] is NSNull && (o["cache"] as? [String: Any])?["fill"] is NSNull)
    }

    @Test func trafficMatchesFixtures() async throws {
        let t = try await engine(fullSource()).traffic(range: .h72)
        try check("insights-traffic.200.json", t)
        #expect((t["resolution"] as? String) == "hour")
        let empty = try await engine(FakeSource()).traffic(range: .h24)
        try check("insights-traffic.empty.json", empty)
        #expect(empty["hourly"] is NSNull)
    }

    @Test func pushMatchesFixtures() async throws {
        var s = fullSource(); s.ctx.setup = InsightsPushSetup(apnsEnv: "production", topicSet: true, keyPresent: true, liveActivityCapability: true)
        try check("insights-push.200.json", try await engine(s).push(range: .h24))
        var off = fullSource(); off.ctx.pushEnabled = false
        let disabled = try await engine(off).push(range: .h24)
        try check("insights-push.disabled.json", disabled)
        #expect((disabled["prerequisites"] as? [[String: Any]])?.count == 1)
        // Slice 1: database gauges only, counters not collected.
        var slice = FakeSource(); slice.gauges = fullGauges(); slice.counters = nil
        let one = try await engine(slice).push(range: .h24)
        for key in ["triggers", "skipped", "apnsErrors", "delivery", "tokenInvalidations", "timing", "registrations", "rejects"] {
            #expect(one[key] is NSNull, "\(key) must be null (not collected), never 0")
        }
        #expect((one["lifecycle"] as? [String: Any])?["events"] as? [Any] != nil)
        #expect(one["funnel"] is [String: Any] && one["outbox"] is [String: Any] && one["caps"] is [Any])
        try check("insights-push.slice1.json", one)
    }

    @Test func distributionMatchesFixtures() async throws {
        var s = FakeSource(); s.gauges = fullGauges()
        try check("insights-distribution.200.json", try await engine(s).distribution())
        var e = FakeSource(); e.gauges = InsightsPushGauges()
        try check("insights-distribution.empty.json", try await engine(e).distribution())
    }
}

// MARK: behaviour

@Suite("Insights behaviour")
struct InsightsBehaviourTests {
    private func buckets(_ counts: [(String, Int)], k: Int = 5) -> [(count: Int?, suppressed: Bool)] {
        InsightsSuppression.buckets(counts.map { ($0.0, $0.1) }, k: k).map {
            guard case .object(let o) = $0, case .bool(let s) = o["suppressed"]! else { return (nil, false) }
            if case .int(let n) = o["count"]! { return (n, s) }
            return (nil, s)
        }
    }

    @Test func kBoundaryFourSuppressedFiveShown() {
        let b = buckets([("a", 4), ("b", 5), ("c", 20)])
        #expect(b[0].suppressed && b[0].count == nil)
        // Exactly one suppressed: the smallest remaining group goes with it.
        #expect(b[1].suppressed && b[2].count == 20 && !b[2].suppressed)
        let five = buckets([("a", 5), ("b", 6)])
        #expect(five.allSatisfy { !$0.suppressed } && five[0].count == 5)
    }

    @Test func complementarySuppressionOnlyForExactlyOne() {
        let two = buckets([("a", 1), ("b", 2), ("c", 30), ("d", 40)])
        #expect(two.map(\.suppressed) == [true, true, false, false])
        let none = buckets([("a", 10), ("b", 30)])
        #expect(none.map(\.suppressed) == [false, false])
        // Empty groups disclose nothing and stay visible; they are never the complement.
        let zero = buckets([("a", 3), ("b", 0), ("c", 7), ("d", 50)])
        #expect(zero.map(\.suppressed) == [true, false, true, false] && zero[1].count == 0)
        #expect(buckets([("a", 2), ("b", 0)]).map(\.suppressed) == [true, false])
    }

    @Test func sharesNeedMinGroup() {
        #expect(InsightsSuppression.share(1, of: 4, k: 5) == .null)
        #expect(InsightsSuppression.share(1, of: 5, k: 5) == .ratio(0.2))
    }

    @Test func distributionAppliesMinGroupFromThresholds() async throws {
        var s = FakeSource(); s.gauges = fullGauges()
        s.ctx.thresholds.minGroup = 50
        let d = try await engine(s).distribution()
        #expect(d["minGroup"] as? Int == 50)
        let lead = d["lead"] as? [[String: Any]] ?? []
        #expect(lead.map { $0["suppressed"] as? Bool } == [true, false, true])   // 22 and 32 < 50
        // Small base: shares are not published.
        var tiny = FakeSource(); var g = InsightsPushGauges(); g.installationsTotal = 3; g.subscriptionsTotal = 3; g.subscriptionsLiveActivity = 1; tiny.gauges = g
        let t = try await engine(tiny).distribution()
        #expect(t["liveActivityShare"] is NSNull && t["timeSensitiveShare"] is NSNull)
    }

    @Test func thresholdsReadRegisterKeysAndIgnoreInvalid() {
        let t = InsightsThresholds(lookup: { ["DASH_WARN_CACHE_HIT_YELLOW": "0.9", "DASH_WARN_CAP_FILL_RED": "x", "DASH_MIN_GROUP": "2"][$0] })
        #expect(t.cacheHit.yellow == 0.9 && t.cacheHit.red == 0.5 && t.capFill.red == 0.95 && t.minGroup == 5)
        #expect(InsightsThresholds(lookup: { $0 == "DASH_MIN_GROUP" ? "12" : nil }).minGroup == 12)
    }

    @Test func layerFindingsWarnAndCritical() async throws {
        var s = fullSource()
        s.layerStates[0].publishedAt = now.addingTimeInterval(-650)   // > 2 x 300
        var f = try await engine(s).findings()
        var list = f["findings"] as? [[String: Any]] ?? []
        #expect(list.first?["code"] as? String == "layer_stale" && list.first?["level"] as? String == "warning" && list.first?["subject"] as? String == "radar")
        #expect(list.first?["threshold"] as? Int == 600)
        s.layerStates[0].publishedAt = now.addingTimeInterval(-1300)  // > 4 x 300
        f = try await engine(s).findings(); list = f["findings"] as? [[String: Any]] ?? []
        #expect(list.first?["level"] as? String == "critical" && list.first?["threshold"] as? Int == 1200)
        // Three missed slots in a row are critical although the age is fine.
        var m = fullSource()
        m.layerStates[0].runs = [InsightsLayerRun(slot: hour(7), result: "missed"), InsightsLayerRun(slot: hour(8), result: "missed"), InsightsLayerRun(slot: hour(9), result: "missed")]
        let mf = try await engine(m).findings()
        #expect((mf["findings"] as? [[String: Any]])?.first?["level"] as? String == "critical")
    }

    @Test func ratioRulesNeedADataBasis() async throws {
        // 5xx: 3 of 10 requests is high, but 10 < 20 requests: no finding.
        var s = fullSource(); s.hourlyRows = hourlyRequests(hours: 3, per: 10, e5xx: 3)
        #expect((try await engine(s).findings()["findings"] as? [Any])?.isEmpty == true)
        s.hourlyRows = hourlyRequests(hours: 3, per: 1000, e5xx: 30)   // 3 %
        let list = try await engine(s).findings()["findings"] as? [[String: Any]] ?? []
        #expect(list.first?["code"] as? String == "error_rate_5xx" && list.first?["level"] as? String == "critical" && list.first?["unit"] as? String == "ratio")
        // LA start ratio: 9 cases are too few, 10 low cases are critical.
        var la = fullSource(); la.counters?.laStartTriggers24h = 9; la.counters?.laStartDelivered24h = 0
        #expect((try await engine(la).findings()["findings"] as? [Any])?.isEmpty == true)
        la.counters?.laStartTriggers24h = 10
        #expect((try await engine(la).findings()["findings"] as? [[String: Any]])?.first?["code"] as? String == "la_start_ratio_low")
    }

    @Test func capFillReplicasAndLeader() async throws {
        var s = fullSource(); s.gauges?.installationsTotal = 41_000      // 82 %
        var list = try await engine(s).findings()["findings"] as? [[String: Any]] ?? []
        #expect(list.first?["code"] as? String == "cap_fill" && list.first?["subject"] as? String == "installations" && list.first?["level"] as? String == "warning")
        s.gauges?.installationsTotal = 49_000                              // 98 %
        list = try await engine(s).findings()["findings"] as? [[String: Any]] ?? []
        #expect(list.first?["level"] as? String == "critical")
        var r = fullSource(); r.replicaInfoValue = InsightsReplicaInfo(replicas: [], generation: 1, leader: nil)
        list = try await engine(r).findings()["findings"] as? [[String: Any]] ?? []
        #expect(list.contains { $0["code"] as? String == "replicas_missing" && $0["level"] as? String == "critical" })
        var l = fullSource(); l.replicaInfoValue.leader = InsightsLeader(holder: nil, leaseSecondsLeft: nil, changes24h: 2)
        list = try await engine(l).findings()["findings"] as? [[String: Any]] ?? []
        #expect(list.contains { $0["code"] as? String == "leader_missing" })
        // Push off: push rules are silent.
        var off = l; off.ctx.pushEnabled = false; off.gauges?.installationsTotal = 49_000
        #expect((try await engine(off).findings()["findings"] as? [Any])?.isEmpty == true)
    }

    @Test func pushDisabledNullsPushSections() async throws {
        var s = fullSource(); s.ctx.pushEnabled = false
        let o = try await engine(s).overview(range: .h24)
        let kpis = o["kpis"] as? [String: Any] ?? [:]
        #expect((kpis["pushDeliveryRatio"] as? [String: Any])?["value"] is NSNull)
        #expect((kpis["activeLiveActivities"] as? [String: Any])?["value"] is NSNull)
        #expect(o["pushEnabled"] as? Bool == false)
        let p = try await engine(s).push(range: .h24)
        #expect(p["funnel"] is NSNull && p["caps"] is NSNull && p["outbox"] is NSNull)
    }

    @Test func notCollectedIsNullNotZero() async throws {
        var s = fullSource(); s.hourlyRows = nil; s.fill = nil; s.latencyRoutes = nil; s.db = nil; s.counters = nil
        s.layerStates[0].lag = nil
        let o = try await engine(s).ops(range: .h24)
        #expect(o["resolution"] as? String == "day")
        #expect(o["latency"] is NSNull && o["db"] is NSNull)
        let radar = (o["layers"] as? [[String: Any]])?.first
        let lag = radar?["lag"] as? [String: Any]
        #expect(lag?["p50Seconds"] is NSNull && lag?["series"] is NSNull)
        let series = ((o["errors"] as? [String: Any])?["status5xx"] as? [String: Any])?["series"] as? [String: Any]
        #expect(series?["resolution"] as? String == "day")
        #expect(((o["errors"] as? [String: Any])?["status5xx"] as? [String: Any])?["ratio1h"] is NSNull)
    }

    @Test func partialInsteadOfFailure() async throws {
        var s = fullSource(); s.layersFail = true
        let o = try await engine(s).ops(range: .h24)
        #expect((o["partial"] as? [String])?.contains("layers") == true)
        #expect((o["layers"] as? [Any])?.isEmpty == true)
        var g = fullSource(); g.gaugesFail = true
        let p = try await engine(g).push(range: .h24)
        #expect((p["partial"] as? [String])?.contains("funnel") == true && p["funnel"] is NSNull)
        let ov = try await engine(g).overview(range: .h24)
        #expect((ov["partial"] as? [String])?.contains("activeLiveActivities") == true)
        var d = FakeSource(); d.gaugesFail = true
        #expect((try await engine(d).distribution()["partial"] as? [String]) == ["distribution"])
    }

    @Test func seriesGapsAndDelta() async throws {
        var s = FakeSource()
        // Hours 0 and 2 ago have traffic, 1 ago is a gap; previous window has half of the traffic.
        let end = TimeUtil.floor(now, to: 3600)
        s.hourlyRows = [HourlyStatRow(hour: end, metric: "requests", label: "push:2xx", value: 200), HourlyStatRow(hour: end.addingTimeInterval(-7200), metric: "requests", label: "push:2xx", value: 200),
                        HourlyStatRow(hour: end.addingTimeInterval(-25 * 3600), metric: "requests", label: "push:2xx", value: 200)]
        let o = try await engine(s).overview(range: .h24)
        let req = (o["kpis"] as? [String: Any])?["requests"] as? [String: Any]
        #expect(req?["value"] as? Int == 400 && req?["deltaPct"] as? Double == 100)
        let points = (req?["series"] as? [String: Any])?["points"] as? [[String: Any]] ?? []
        #expect(points.count == 24 && points.last?["v"] as? Int == 200 && points[points.count - 2]["v"] is NSNull)
        #expect(points.map { $0["t"] as? String } == points.compactMap { $0["t"] as? String }.sorted())
    }

    @Test func trafficBreakdown() async throws {
        let t = try await engine(fullSource()).traffic(range: .d7)
        #expect(t["resolution"] as? String == "day")
        let requests = t["requests"] as? [String: Any] ?? [:]
        #expect(requests["total"] as? Int == 7000)
        #expect(requests["notModifiedShare"] as? Double == 0.4)
        let classes = requests["byStatusClass"] as? [[String: Any]] ?? []
        #expect(classes.map { $0["class"] as? String } == ["2xx", "3xx", "4xx", "5xx"])
        #expect(classes[1]["count"] as? Int == 2800)   // 304 counts as 3xx
        let routes = requests["byRoute"] as? [[String: Any]] ?? []
        #expect(routes.first?["route"] as? String == "radar_image" && routes.first?["bytes"] as? Int == 700_000)
        #expect(((t["pageViews"] as? [[String: Any]])?.first { $0["page"] as? String == "landing_de" })?["count"] as? Int == 280)
    }

    @Test func neverContainsIdentifiers() async throws {
        var s = fullSource(); s.replicaInfoValue.replicas[0].replicaID = "swarm-host-01.internal"
        s.ctx.setup = InsightsPushSetup(apnsEnv: "production", topicSet: true, keyPresent: true, liveActivityCapability: true)
        let e = engine(s)
        var all: [[String: Any]] = []
        for r in InsightsRange.allCases { all += [try await e.overview(range: r), try await e.ops(range: r), try await e.traffic(range: r), try await e.push(range: r)] }
        all += [try await e.distribution(), try await e.findings()]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: all), as: UTF8.self)
        let patterns = ["[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",   // UUID
                        "[0-9a-fA-F]{32,}",                                                              // token / hash
                        "\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b",                               // IPv4
                        "swarm-host", "internal", "cell_x", "cellX", "token\":\"", "latitude", "longitude"]
        for p in patterns { #expect(text.range(of: p, options: .regularExpression) == nil, "pattern \(p) found") }
        #expect(text.contains(DashboardApi.shortID("swarm-host-01.internal")))
    }
}

// MARK: routes

private let origin = "https://dash.example.test"

@Suite("Insights routes")
struct InsightsRouteTests {
    private func harness(_ source: FakeSource, clock: @escaping @Sendable () -> Date = { now }) async throws -> (api: DashboardApi, cookie: String) {
        let repo = MemoryRepo()
        let store = try await ConfigStore(env: [:], repo: repo)
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        let insights = InsightsEngine(source: source, clock: clock)
        let api = DashboardApi(auth: auth, repo: repo, store: store, env: [:], staticRoot: NSTemporaryDirectory(), clock: clock,
                               extra: registerInsightsRoutes(engine: insights, clock: clock))
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        return (api, "__Host-dash_session=" + created.cookieValue)
    }

    private func get(_ h: (api: DashboardApi, cookie: String), _ path: String, _ query: [String: String] = [:], session: Bool = true) async -> (Int, [String: Any], ApiResponse) {
        let info = DashboardRequestInfo(method: "GET", cookieHeader: session ? h.cookie : nil, host: "dash.example.test")
        let r = await h.api.handle(DashboardHTTPRequest(method: "GET", path: path, query: query, info: info))
        return (r.status, (try? JSONSerialization.jsonObject(with: Data(r.body))) as? [String: Any] ?? [:], r)
    }

    @Test func allSixRoutesAnswerWithNoStore() async throws {
        let h = try await harness(fullSource())
        for name in ["overview", "ops", "traffic", "push", "distribution", "findings"] {
            let (status, json, response) = await get(h, "/dash/api/insights/" + name)
            #expect(status == 200, "\(name)")
            #expect(json["generatedAt"] as? String == "2026-11-06T09:15:00Z")
            #expect(response.headers.contains { $0.0 == "Cache-Control" && $0.1 == "no-store" })
        }
    }

    @Test func rangeValidation() async throws {
        let h = try await harness(fullSource())
        for bad in ["1y", "", "24H", "7"] {
            let (status, json, _) = await get(h, "/dash/api/insights/overview", ["range": bad])
            #expect(status == 400 && json["error"] as? String == "validation", "range=\(bad)")
        }
        for good in ["24h", "72h", "7d", "30d"] {
            let (status, json, _) = await get(h, "/dash/api/insights/traffic", ["range": good])
            #expect(status == 200 && json["range"] as? String == good)
        }
        // findings takes no range parameter.
        #expect(await get(h, "/dash/api/insights/findings", ["range": "1y"]).0 == 200)
    }

    @Test func needsSessionAndKnowsOnlyItsRoutes() async throws {
        let h = try await harness(fullSource())
        #expect(await get(h, "/dash/api/insights/overview", session: false).0 == 401)
        #expect(await get(h, "/dash/api/insights/nope").0 == 404)
        #expect(await get(h, "/dash/api/insights").0 == 404)
    }

    @Test func statsDownGives503() async throws {
        var s = fullSource(); s.statsFail = true
        let h = try await harness(s)
        let (status, json, _) = await get(h, "/dash/api/insights/overview")
        #expect(status == 503 && json["error"] as? String == "data_unavailable")
        // Sections that do not need statistics still partially work.
        #expect(await get(h, "/dash/api/insights/distribution").0 == 200)
    }

    @Test func answersAreCachedForFiveSeconds() async throws {
        let time = Locked(now)
        let calls = Locked(0)
        struct Counting: InsightsDataSource {
            let calls: Locked<Int>
            func context() async -> InsightsContext { InsightsContext(pushEnabled: false, caps: InsightsCapLimits(installations: 1, subscriptions: 1, regionCells: 1, activitySubscriptions: 1)) }
            func dailyStats(from: Date, to: Date) async throws -> [StatRow] { calls.withLock { $0 += 1 }; return [] }
            func layers(now: Date) async throws -> [InsightsLayerState] { [] }
            func replicaInfo(now: Date) async throws -> InsightsReplicaInfo { InsightsReplicaInfo(replicas: [], generation: 0) }
            func pushGauges(now: Date) async throws -> InsightsPushGauges? { nil }
        }
        let repo = MemoryRepo()
        let store = try await ConfigStore(env: [:], repo: repo)
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        let clock: @Sendable () -> Date = { time.withLock { $0 } }
        let api = DashboardApi(auth: auth, repo: repo, store: store, env: [:], staticRoot: NSTemporaryDirectory(), clock: clock,
                               extra: registerInsightsRoutes(engine: InsightsEngine(source: Counting(calls: calls), clock: clock), clock: clock))
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        let h = (api: api, cookie: "__Host-dash_session=" + created.cookieValue)
        _ = await get(h, "/dash/api/insights/ops"); _ = await get(h, "/dash/api/insights/ops")
        #expect(calls.withLock { $0 } == 1)
        _ = await get(h, "/dash/api/insights/ops", ["range": "7d"])
        #expect(calls.withLock { $0 } == 2)
        time.withLock { $0 = $0.addingTimeInterval(6) }
        _ = await get(h, "/dash/api/insights/ops")
        #expect(calls.withLock { $0 } == 3)
    }
}
