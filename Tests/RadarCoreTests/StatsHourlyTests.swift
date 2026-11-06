import Foundation
import Testing
@testable import RadarCore

// WP11a: latency / ingest buckets, hourly statistics (72 h), read API for the insights.
private let h0 = TimeUtil.floor(run0, to: 3600)  // 2026-10-30 11:00 UTC, an exact hour
private func clockAt(_ date: Date) -> @Sendable () -> Date { { date } }
private func hour(_ n: Int) -> Date { h0.addingTimeInterval(Double(n) * 3600) }
private func deltas(_ c: StatsCollector) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: c.pending().map { ($0.metric + "|" + $0.label, $0.value) })
}
private func hv(_ rows: [StatHourRow], _ metric: String, _ label: String, hour: Date? = nil) -> Int? {
    rows.first { $0.metric == metric && $0.label == label && (hour == nil || $0.hour == hour) }?.value
}

@Suite("Statistics buckets (pure)")
struct StatsBucketTests {
    @Test func bucketBoundariesAreFixed() {
        let l = StatsBuckets.latency
        #expect(l.name(forSeconds: 0) == "lt10ms" && l.name(forSeconds: 0.00999) == "lt10ms")
        #expect(l.name(forSeconds: 0.01) == "lt50ms" && l.name(forSeconds: 0.199) == "lt200ms")
        #expect(l.name(forSeconds: 0.2) == "lt1s" && l.name(forSeconds: 1) == "ge1s" && l.name(forSeconds: 3600) == "ge1s")
        #expect(l.name(forSeconds: -5) == "lt10ms", "negative durations clamp to the first bucket")
        #expect(l.name(forSeconds: .nan) == nil && l.name(forSeconds: .infinity) == "ge1s")
        #expect(StatsBuckets.ingestLag.name(forSeconds: 299) == "lt5m" && StatsBuckets.ingestLag.name(forSeconds: 4000) == "ge1h")
        #expect(StatsBuckets.ingestDuration.name(forSeconds: 59) == "lt1m" && StatsBuckets.ingestDuration.name(forSeconds: 301) == "ge5m")
    }

    @Test func quantilesAreEstimatedFromBuckets() {
        let l = StatsBuckets.latency
        let counts = ["lt10ms": 50, "lt50ms": 40, "lt200ms": 9, "ge1s": 1]  // 100 samples
        let q = l.quantiles(counts, [0.5, 0.95, 0.99, 1.0])
        #expect(q.values[0] == 0.01, "p50 = upper bound of lt10ms")
        #expect(q.values[1] == 0.2 && q.values[2] == 0.2)
        #expect(q.values[3] == 1.0 && q.overflow, "the open bucket reports its lower bound and sets overflow")
        let empty = l.quantiles([:], [0.5])
        #expect(empty.values == [nil] && !empty.overflow)
        #expect(l.quantiles(["bogus": 5], [0.5]).values == [nil], "unknown bucket names are ignored")
    }
}

@Suite("Statistics hourly collector")
struct StatsHourlyCollectorTests {
    @Test func newMetricsUseFixedLabels() {
        let c = StatsCollector(clock: clockAt(h0))
        c.recordRequest(path: "/v1/radar/latest.json", status: 200, bytes: 10, seconds: 0.004)
        c.recordRequest(path: "/v1/radar/20261030T1105Z/x.webp", status: 200, bytes: 10, seconds: 0.3)
        c.recordRequest(path: "/wp-login.php/\(UUID().uuidString)", status: 404, bytes: 0, seconds: 7)
        c.recordRequest(path: "/", status: 200, bytes: 1)  // no duration -> no latency sample
        c.observe("ingest_lag", key: "radar", seconds: 420)
        c.observe("ingest_lag", key: "pressure", seconds: 99_999)
        c.observe("ingest_lag", key: "198.51.100.7", seconds: 1)      // unknown layer: ignored
        c.observe("ingest_dur", key: "radar", seconds: 45)
        c.observe("ingest_dur", key: "radar", seconds: .nan)         // ignored
        c.observe("nonsense", key: "radar", seconds: 1)              // ignored
        c.record("latency", label: "radar_latest:lt7ms")             // unknown bucket: ignored
        c.record("latency", label: "mystery:lt10ms")                 // unknown group: other
        c.record("cache_evict", label: "layer")
        c.record("cache_evict", label: "/etc/passwd")
        let d = deltas(c)
        #expect(d["latency|radar_latest:lt10ms"] == 1 && d["latency|radar_image:lt1s"] == 1 && d["latency|other:ge1s"] == 1)
        #expect(d["latency|other:lt10ms"] == 1)
        #expect(d["latency|landing:lt10ms"] == nil && d["latency|radar_latest:lt7ms"] == nil)
        #expect(d["ingest_lag|radar:lt10m"] == 1 && d["ingest_lag|pressure:ge1h"] == 1 && d.keys.filter { $0.hasPrefix("ingest_lag|") }.count == 2)
        #expect(d["ingest_dur|radar:lt1m"] == 1 && d.keys.filter { $0.hasPrefix("ingest_dur|") }.count == 1)
        #expect(d["cache_evict|layer"] == 1 && d["cache_evict|other"] == 1)
        #expect(c.pending().allSatisfy(DashboardValidation.isValid))
    }

    @Test func hourlyMetricSelection() {
        for m in ["requests", "errors_5xx", "ingest_run", "ingest_lag", "ingest_dur", "latency", "cache_hit", "cache_miss", "cache_evict", "push_sent", "push_failed"] {
            #expect(StatsCollector.isHourly(m), "\(m)")
        }
        for m in ["bytes_out", "page_view", "stats_dropped", "rate_limited"] { #expect(!StatsCollector.isHourly(m), "\(m)") }
        #expect(StatsCollector.labelRules.keys.allSatisfy { $0.count <= 32 })
    }

    @Test func observeLabelsStayWithinTheRepoLimits() {
        for scheme in [StatsBuckets.latency, StatsBuckets.ingestLag, StatsBuckets.ingestDuration] {
            for group in StatsRoute.groups + ["radar"] + LayerCatalog.order {
                for name in scheme.names {
                    #expect(DashboardValidation.isValid(StatDelta(metric: scheme.metric, label: group + ":" + name, value: 1)), "\(group):\(name)")
                }
            }
        }
    }

    @Test func ingestRecordsLagAndDuration() async throws {
        let stats = StatsCollector(clock: clockAt(h0))
        let cfg = smallConfig()
        // Published 7 minutes after the nominal run time; the run itself took 20 s (virtual clock).
        let now = Locked(run0.addingTimeInterval(7 * 60))
        let ingestor = Ingestor(config: cfg, repo: MemoryRepo(), fetch: FakeDwd(cfg).fetch, owner: "a",
                                sleep: { _ in }, stats: stats,
                                clock: { now.withLock { $0 } })
        #expect(try await ingestor.process(run: run0))
        let d = deltas(stats)
        #expect(d["ingest_lag|radar:lt10m"] == 1)
        #expect(d["ingest_dur|radar:lt10s"] == 1, "no virtual time passes in the fake")
    }
}

@Suite("Slot cache gauges")
struct SlotCacheGaugeTests {
    @Test func evictionsAreCountedAndSnapshotReportsSize() async throws {
        let stats = StatsCollector(clock: clockAt(h0))
        let cache = SlotCache(maxBytes: 100, clock: clockAt(h0), stats: stats)
        @Sendable func blob(_ n: Int) -> SlotBlob { SlotBlob(contentType: "image/webp", sha256: "x", data: [UInt8](repeating: 1, count: n)) }
        _ = try await cache.load("a") { blob(60) }
        _ = try await cache.load("layer:b") { blob(60) }   // evicts a
        _ = try await cache.load("c") { blob(60) }         // evicts layer:b
        let s = await cache.snapshot()
        #expect(s.entries == 1 && s.bytes == 60 && s.maxBytes == 100)
        let d = deltas(stats)
        #expect(d["cache_evict|radar"] == 1 && d["cache_evict|layer"] == 1)
    }
}

extension DatabaseSuites {
@Suite("Statistics hourly storage", .serialized)
struct StatsHourlyStorageTests {
    @Test(arguments: RepoKind.allCases) func hourlyAddIsAdditiveAndValidated(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.addStatsHourly(hour: h0.addingTimeInterval(1234), [StatDelta(metric: "requests", label: "status:2xx", value: 3),
                                                                           StatDelta(metric: "requests", label: "status:2xx", value: 2),
                                                                           StatDelta(metric: "errors_5xx", label: "status", value: 0)])
        try await repo.addStatsHourly(hour: h0, [StatDelta(metric: "requests", label: "status:2xx", value: 1)])
        try await repo.addStatsHourly(hour: hour(1), [StatDelta(metric: "requests", label: "status:2xx", value: 9)])
        let rows = try await repo.statsHourly(from: h0, to: hour(1))
        #expect(rows.count == 2, "zero values are skipped, minutes are truncated")
        #expect(hv(rows, "requests", "status:2xx", hour: h0) == 6 && hv(rows, "requests", "status:2xx", hour: hour(1)) == 9)
        #expect(rows.map(\.hour) == [h0, hour(1)])
        await #expect(throws: DashboardRepoError.invalidStat) {
            try await repo.addStatsHourly(hour: h0, [StatDelta(metric: "requests", label: "has space", value: 1)])
        }
        #expect(try await repo.statsHourly(from: h0, to: hour(1)).count == 2, "invalid batch writes nothing")
        #expect(try await repo.statsHourly(from: hour(5), to: hour(6)).isEmpty)
    }

    @Test(arguments: RepoKind.allCases) func concurrentHourlyAddsAreExact(kind: RepoKind) async throws {
        let repo = try await kind.make()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<5 { try? await repo.addStatsHourly(hour: h0, [StatDelta(metric: "latency", label: "push:lt10ms", value: 2)]) } } }
        }
        #expect(hv(try await repo.statsHourly(from: h0, to: h0), "latency", "push:lt10ms") == 80)
    }

    @Test(arguments: RepoKind.allCases) func purgeKeepsSeventyTwoHours(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = hour(100).addingTimeInterval(600)
        for h in [100 - 73, 100 - 72, 100 - 10, 100] {
            try await repo.addStatsHourly(hour: hour(h), [StatDelta(metric: "requests", label: "other:2xx", value: 1)])
        }
        #expect(try await repo.purgeStatsHourly(now: now) == 1)
        let rest = try await repo.statsHourly(from: hour(0), to: hour(200)).map(\.hour)
        #expect(rest == [hour(28), hour(90), hour(100)])
        #expect(try await repo.purgeStatsHourly(now: now) == 0, "idempotent")
        // purgeDashboard includes the hourly table.
        try await repo.addStatsHourly(hour: hour(1), [StatDelta(metric: "requests", label: "other:2xx", value: 1)])
        let result = try await repo.purgeDashboard(now: now)
        #expect(result.statsHourly == 1)
    }

    @Test(arguments: RepoKind.allCases) func flushWritesDayAndHourAdditively(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = h0.addingTimeInterval(1800)
        let c = StatsCollector(repo: repo, clock: clockAt(now))
        c.record("requests", label: "status:2xx", by: 4)
        c.record("bytes_out", label: "status", by: 99)
        c.observe("ingest_lag", key: "radar", seconds: 400)
        #expect(await c.flush())
        c.record("requests", label: "status:2xx", by: 1)
        #expect(await c.flush())
        let hourly = try await repo.statsHourly(from: h0, to: h0)
        #expect(hv(hourly, "requests", "status:2xx", hour: h0) == 5 && hv(hourly, "ingest_lag", "radar:lt10m", hour: h0) == 1)
        #expect(hv(hourly, "bytes_out", "status") == nil, "daily-only metric")
        let daily = try await repo.stats(from: h0, to: h0)
        #expect(daily.first { $0.metric == "requests" }?.value == 5 && daily.first { $0.metric == "bytes_out" }?.value == 99)
    }

    @Test(arguments: RepoKind.allCases) func hourlyFailureIsRetriedWithoutDoubleCounting(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let failDaily = Locked(false), failHourly = Locked(false)
        struct Down: Error {}
        let writer = StatsCollector.Writer(
            addStats: { day, d in if failDaily.withLock({ $0 }) { throw Down() }; try await repo.addStats(day: day, d) },
            purge: { now in _ = try await repo.purgeDashboard(now: now) },
            addHourly: { hr, d in if failHourly.withLock({ $0 }) { throw Down() }; try await repo.addStatsHourly(hour: hr, d) })
        let now = Locked(h0.addingTimeInterval(60))
        let c = StatsCollector(writer: writer, clock: { now.withLock { $0 } })
        c.record("requests", label: "status:2xx", by: 3)
        failHourly.withLock { $0 = true }
        #expect(await c.flush() == false)
        // Daily went through exactly once, hourly is held back with its own hour.
        #expect(try await repo.stats(from: h0, to: h0).first?.value == 3)
        #expect(try await repo.statsHourly(from: h0, to: hour(5)).isEmpty)
        now.withLock { $0 = hour(1).addingTimeInterval(30) }  // next hour
        c.record("requests", label: "status:2xx", by: 2)
        #expect(await c.flush() == false)
        failHourly.withLock { $0 = false }
        #expect(await c.flush())
        let rows = try await repo.statsHourly(from: h0, to: hour(1))
        #expect(hv(rows, "requests", "status:2xx", hour: h0) == 3 && hv(rows, "requests", "status:2xx", hour: hour(1)) == 2)
        #expect(try await repo.stats(from: h0, to: h0).first?.value == 5, "daily counted once")
        // Both failing: nothing is lost, nothing duplicated.
        failDaily.withLock { $0 = true }; failHourly.withLock { $0 = true }
        c.record("requests", label: "status:2xx", by: 7)
        #expect(await c.flush() == false)
        #expect(deltas(c)["requests|status:2xx"] == 7, "pending() shows the daily side; the hourly carry is held separately")
        #expect(c.keyCount == 2)
        failDaily.withLock { $0 = false }; failHourly.withLock { $0 = false }
        #expect(await c.flush())
        #expect(c.pending().isEmpty)
        #expect(try await repo.stats(from: h0, to: h0).first?.value == 12)
        #expect(hv(try await repo.statsHourly(from: hour(1), to: hour(1)), "requests", "status:2xx") == 9)
    }

    @Test(arguments: RepoKind.allCases) func concurrentCollectorsSumHourly(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let a = StatsCollector(repo: repo, clock: clockAt(h0.addingTimeInterval(5))), b = StatsCollector(repo: repo, clock: clockAt(h0.addingTimeInterval(50)))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let c = i % 2 == 0 ? a : b
                    for _ in 0..<500 { c.recordRequest(path: "/healthz", status: 200, bytes: 1, seconds: 0.001) }
                    _ = await c.flush()
                }
            }
        }
        _ = await a.flush(); _ = await b.flush()
        let rows = try await repo.statsHourly(from: h0, to: h0)
        #expect(hv(rows, "requests", "healthz:2xx") == 4000 && hv(rows, "latency", "healthz:lt10ms") == 4000)
    }

    @Test(arguments: RepoKind.allCases) func queryHourlySeriesAndQuantiles(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.addStatsHourly(hour: h0, [
            StatDelta(metric: "requests", label: "radar_image:2xx", value: 10), StatDelta(metric: "requests", label: "landing:5xx", value: 2),
            StatDelta(metric: "latency", label: "radar_image:lt10ms", value: 90), StatDelta(metric: "latency", label: "radar_image:lt200ms", value: 9),
            StatDelta(metric: "latency", label: "radar_image:ge1s", value: 1), StatDelta(metric: "latency", label: "push:lt50ms", value: 4),
            StatDelta(metric: "ingest_lag", label: "radar:lt5m", value: 3), StatDelta(metric: "ingest_lag", label: "radar:lt10m", value: 1)])
        try await repo.addStatsHourly(hour: hour(2), [
            StatDelta(metric: "requests", label: "radar_image:2xx", value: 5), StatDelta(metric: "latency", label: "radar_image:lt10ms", value: 5),
            StatDelta(metric: "ingest_lag", label: "radar:ge1h", value: 1)])
        let q = StatsQuery(repo: repo)

        let all = try await q.hourly(from: h0, to: hour(2).addingTimeInterval(1000))
        #expect(all.hours.count == 3 && all.hours[1].values.isEmpty, "hours without data are present")
        #expect(all.hours[0].hour == "2026-10-30T11:00:00Z" && all.from == "2026-10-30T11:00:00Z" && all.to == "2026-10-30T13:00:00Z")

        let series = try await q.hourlySeries(metric: "requests", from: h0, to: hour(2))
        #expect(series.points.map(\.total) == [12, 0, 5])
        #expect(series.points[0].byLabel == ["radar_image:2xx": 10, "landing:5xx": 2])
        #expect(series.points[0].byGroup == ["radar_image": 10, "landing": 2])

        let lat = try await q.distribution(metric: "latency", from: h0, to: hour(2))
        let radar = try #require(lat.entries.first { $0.key == "radar_image" })
        #expect(radar.count == 105 && radar.buckets.map(\.bucket) == StatsBuckets.latency.names)
        #expect(radar.buckets.map(\.count) == [95, 0, 9, 0, 1])
        #expect(radar.p50 == 0.01 && radar.p95 == 0.2 && radar.p99 == 0.2 && !radar.overflow)
        #expect(lat.entries.first { $0.key == "push" }?.p50 == 0.05)
        #expect(lat.entries.map(\.key) == lat.entries.map(\.key).sorted())
        let lag = try await q.distribution(metric: "ingest_lag", from: h0, to: hour(2))
        #expect(lag.entries.map(\.key) == ["radar"] && lag.entries[0].count == 5 && lag.unit == "s")
        await #expect(throws: StatsQueryError.unknownMetric) { _ = try await q.distribution(metric: "requests", from: h0, to: hour(2)) }

        let ser = try await q.distributionSeries(metric: "latency", key: "radar_image", from: h0, to: hour(2))
        #expect(ser.points.map(\.count) == [100, 0, 5])
        #expect(ser.points[0].p50 == 0.01 && ser.points[1].p50 == nil && ser.points[2].p99 == 0.01)

        // Ranges are capped at one week of hours; reversed ranges are empty.
        let capped = try await q.hourly(from: h0, to: h0.addingTimeInterval(30 * 86400))
        #expect(capped.hours.count == 168)
        #expect(try await q.hourly(from: hour(5), to: hour(1)).hours.isEmpty)
        // camelCase JSON round trip.
        let json = String(decoding: try JSONEncoder().encode(radar), as: UTF8.self)
        #expect(json.contains("\"p95\"") && json.contains("\"overflow\""))
        #expect(try JSONDecoder().decode(DistributionSummary.self, from: JSONEncoder().encode(radar)) == radar)
    }
}
}

@Suite("Statistics hourly overhead", .serialized)
struct StatsHourlyOverheadTests {
    /// Per-request cost incl. latency sample (classification, two counters under the lock) and the flush path with hourly rows.
    @Test func perRequestOverheadWithLatencyIsSmall() async {
        let c = StatsCollector(clock: clockAt(h0))
        let paths = ["/v1/radar/20261030T1105Z/20261030T1110Z.webp", "/v1/radar/latest.json", "/v1/layers/pressure/latest.json", "/", "/healthz"]
        for i in 0..<20_000 { c.recordRequest(path: paths[i % paths.count], status: 200, bytes: 100, seconds: 0.003) }
        let n = 300_000
        let clock = ContinuousClock()
        let single = clock.measure { for i in 0..<n { c.recordRequest(path: paths[i % paths.count], status: 200, bytes: 100, seconds: Double(i % 50) / 100) } }
        let perCall = (Double(single.components.attoseconds) / 1e18 + Double(single.components.seconds)) / Double(n)
        let threads = 8, each = 50_000
        let contended = await clock.measure {
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<threads { group.addTask { for i in 0..<each { c.recordRequest(path: paths[(i + t) % paths.count], status: 200, bytes: 100, seconds: 0.002) } } }
            }
        }
        let perContended = (Double(contended.components.attoseconds) / 1e18 + Double(contended.components.seconds)) / Double(threads * each)
        print("STATS-OVERHEAD-WP11A single=\(String(format: "%.2f", perCall * 1e6)) us/request contended(8 tasks)=\(String(format: "%.2f", perContended * 1e6)) us/request")
        #if DEBUG
        #expect(perCall < 100e-6, "debug build bound")
        #else
        #expect(perCall < 20e-6)
        #endif
    }

    @Test func flushCostWithHourlyRowsIsBounded() async {
        let repo = MemoryRepo()
        let c = StatsCollector(repo: repo, clock: clockAt(h0))
        for g in StatsRoute.groups { for cls in ["2xx", "4xx"] { c.record("requests", label: g + ":" + cls, by: 3) }
            for b in StatsBuckets.latency.names { c.record("latency", label: g + ":" + b, by: 2) } }
        let keys = c.keyCount
        let elapsed = await ContinuousClock().measure { _ = await c.flush() }
        print("STATS-FLUSH-WP11A keys=\(keys) ms=\((Double(elapsed.components.attoseconds) / 1e15))")
        #expect(keys < 300, "label universe of a busy minute stays small")
        #expect(elapsed < .seconds(1))
    }
}
