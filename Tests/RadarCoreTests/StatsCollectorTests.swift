import Foundation
import Testing
@testable import RadarCore

private let day0 = run0  // 2026-10-30
private func clockAt(_ date: Date) -> @Sendable () -> Date { { date } }
private func value(_ rows: [StatRow], _ metric: String, _ label: String) -> Int? {
    rows.first { $0.metric == metric && $0.label == label }?.value
}
private func deltas(_ c: StatsCollector) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: c.pending().map { ($0.metric + "|" + $0.label, $0.value) })
}

/// Forwards to a repo; fails while `failing` is set. Counts successful writes.
private final class FlakyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var _failing = false
    private var _writes = 0
    var failing: Bool { get { lock.withLock { _failing } } set { lock.withLock { _failing = newValue } } }
    var writes: Int { lock.withLock { _writes } }
    struct Down: Error {}
    func writer(_ repo: any DashboardRepo) -> StatsCollector.Writer {
        StatsCollector.Writer(addStats: { [self] day, d in
            if failing { throw Down() }
            try await repo.addStats(day: day, d); lock.withLock { _writes += 1 }
        }, purge: { [self] now in
            if failing { throw Down() }
            _ = try await repo.purgeDashboard(now: now)
        })
    }
}

@Suite("Statistics collector (pure)")
struct StatsCollectorLogicTests {
    @Test func countsAndNormalizesLabels() {
        let c = StatsCollector(clock: clockAt(day0))
        c.record("cache_hit", label: "radar:memory")
        c.record("cache_hit", label: "radar:memory", by: 2)
        c.record("cache_hit", label: "evil label with spaces")  // unknown -> other
        c.record("cache_miss", label: "layer:db")
        c.record("unknown_metric", label: "x")                   // ignored
        c.record("cache_hit", label: "radar:memory", by: 0)      // ignored
        c.record("cache_hit", label: "radar:memory", by: -5)     // ignored
        c.record("ingest_run", label: "radar:ok")
        c.record("ingest_run", label: "radar:weird")
        c.record("push_failed", label: "BadDeviceToken")
        c.record("page_view", label: "landing_de")
        c.record("page_view", label: "https://example.com/?a=1")
        c.record("requests", label: "radar_image:2xx")
        c.record("requests", label: "/v1/radar/20261030T1105Z/x.webp:2xx")
        let d = deltas(c)
        #expect(d["cache_hit|radar:memory"] == 3)
        #expect(d["cache_hit|other"] == 1)
        #expect(d["cache_miss|layer:db"] == 1)
        #expect(d["unknown_metric|x"] == nil)
        #expect(d["ingest_run|radar:ok"] == 1 && d["ingest_run|other:error"] == 1)
        #expect(d["push_failed|other"] == 1)
        #expect(d["page_view|landing_de"] == 1 && d["page_view|other"] == 1)
        #expect(d["requests|radar_image:2xx"] == 1 && d["requests|other:other"] == 1)
        // Every produced pair is accepted by the repo validation.
        #expect(c.pending().allSatisfy(DashboardValidation.isValid))
    }

    @Test func requestRecordingDerivesAllMetrics() {
        let c = StatsCollector(clock: clockAt(day0))
        c.recordRequest(path: "/v1/radar/20261030T1105Z/20261030T1110Z.webp", status: 200, bytes: 1000)
        c.recordRequest(path: "/v1/radar/20261030T1105Z/20261030T1110Z.webp", status: 304, bytes: 0)
        c.recordRequest(path: "/v1/radar/latest.json?x=1", status: 200, bytes: 50)
        c.recordRequest(path: "/v1/layers/pressure/latest.json", status: 200, bytes: 70)
        c.recordRequest(path: "/v1/layers/pressure/20261030T1100Z/20261030T1100Z.webp", status: 404, bytes: 0)
        c.recordRequest(path: "/v1/push/installations/3F2504E0-4F89-41D3-9A0C-0305E82C3301", status: 429, bytes: 20)
        c.recordRequest(path: "/", status: 200, bytes: 9000)
        c.recordRequest(path: "/en", status: 200, bytes: 9000)
        c.recordRequest(path: "/datenschutz", status: 200, bytes: 100)
        c.recordRequest(path: "/support", status: 500, bytes: 0)
        c.recordRequest(path: "/dash/api/stats/overview", status: 429, bytes: 10)
        c.recordRequest(path: "/wp-login.php", status: 404, bytes: 0)
        let d = deltas(c)
        #expect(d["requests|radar_image:2xx"] == 1 && d["requests|radar_image:304"] == 1)
        #expect(d["requests|radar_latest:2xx"] == 1 && d["requests|layer_manifest:2xx"] == 1 && d["requests|layer_image:4xx"] == 1)
        #expect(d["requests|push:4xx"] == 1 && d["requests|landing:2xx"] == 2 && d["requests|other:4xx"] == 1)
        #expect(d["bytes_out|radar_image"] == 1000 && d["bytes_out|landing"] == 18000)
        #expect(d["errors_5xx|site_page"] == 1 && d["requests|site_page:5xx"] == 1)
        #expect(d["rate_limited|push"] == 1 && d["rate_limited|dashboard"] == 1)
        #expect(d["page_view|landing_de"] == 1 && d["page_view|landing_en"] == 1 && d["page_view|privacy"] == 1)
        #expect(d["page_view|support"] == nil, "failed page loads are no views")
    }

    @Test func cardinalityIsBounded() {
        let c = StatsCollector(maxKeys: 50, clock: clockAt(day0))
        for i in 0..<10_000 { c.recordRequest(path: "/random/\(i)/\(UUID().uuidString)", status: 200 + (i % 400), bytes: i) }
        for i in 0..<500 { c.record("cache_hit", label: "label-\(i)") }
        #expect(c.keyCount <= 50 + 1)
        // Fixed enumerations only: all unknown paths collapse into one group.
        #expect(c.pending().filter { $0.metric == "requests" }.allSatisfy { $0.label.hasPrefix("other:") })
        // Full table: new combinations are dropped and counted, existing ones keep counting.
        let full = StatsCollector(maxKeys: 10, clock: clockAt(day0))
        let metrics = ["healthz", "status", "radar_latest", "radar_history", "radar_image", "layer_manifest", "layer_image", "push", "landing", "asset", "site_page"]
        for g in metrics { full.record("bytes_out", label: g) }
        #expect(full.keyCount <= 11)
        full.record("bytes_out", label: "healthz", by: 5)
        #expect(deltas(full)["bytes_out|healthz"] == 6)
        #expect((deltas(full)["stats_dropped|"] ?? 0) >= 1)
    }

    @Test func routeGroupsAreAlwaysFromTheFixedList() {
        let paths = ["/", "/en", "/healthz", "/v1/status", "/v1/radar/latest.json", "/v1/radar/a/b.webp", "/v1/layers/x/latest.json",
                     "/v1/push/installations/abc", "/assets/app.123.css", "/dash", "/dash/api/session", "/zzz", "", "///", "/v1/radar/", "\u{0}"]
        for path in paths { #expect(StatsRoute.groups.contains(StatsRoute.group(path: path)), "\(path)") }
    }
}

@Suite("Statistics privacy")
struct StatsPrivacyTests {
    nonisolated(unsafe) static let uuid = try! Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    nonisolated(unsafe) static let ipv4 = try! Regex("[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}")
    nonisolated(unsafe) static let longHex = try! Regex("[0-9a-fA-F]{16,}")
    nonisolated(unsafe) static let runID = try! Regex("[0-9]{8}T[0-9]{4}Z")
    nonisolated(unsafe) static let allowed = try! Regex("[a-z0-9_:]{0,48}")

    @Test func noLabelContainsIdentifiers() {
        let secret = String(repeating: "ab12", count: 16)
        let paths = [
            "/v1/push/installations/3F2504E0-4F89-41D3-9A0C-0305E82C3301/subscriptions/3F2504E0-4F89-41D3-9A0C-0305E82C3302",
            "/v1/push/installations/\(secret)", "/v1/radar/20261030T1105Z/20261030T1110Z.webp",
            "/v1/layers/pressure/20261030T1100Z/20261030T1100Z.webp", "/192.168.10.7", "/203.0.113.9/admin", "/?lat=52.52&lon=13.40",
            "/v1/radar/latest.json?token=\(secret)", "/dash/api/stats/overview?from=2026-10-01", "/assets/app.\(secret).js",
            "/share/\(secret)", "/users/jane.doe@example.com", "/x/y/z/\(UUID().uuidString)",
        ]
        let c = StatsCollector(clock: clockAt(day0))
        for (i, path) in paths.enumerated() {
            for status in [200, 304, 404, 429, 500] { c.recordRequest(path: path, status: status, bytes: i) }
        }
        // Hostile direct labels as well.
        for bad in [UUID().uuidString, "192.168.0.1", secret, "20261030T1105Z", "Mozilla/5.0 (iPhone)", "example.com", "52.52,13.40"] {
            for metric in StatsCollector.labelRules.keys { c.record(metric, label: bad) }
        }
        let pairs = c.pending()
        #expect(!pairs.isEmpty)
        for p in pairs {
            let text = p.metric + "|" + p.label
            #expect(!text.contains(Self.uuid) && !text.contains(Self.ipv4) && !text.contains(Self.longHex) && !text.contains(Self.runID), "\(text)")
            #expect(p.label.wholeMatch(of: Self.allowed) != nil, "\(text)")
            #expect(DashboardValidation.isValid(p))
        }
        // The label universe is finite and independent of the input.
        let universe = Set(pairs.map { $0.metric + "|" + $0.label })
        #expect(universe.count < 200)
    }

    @Test func randomPathsNeverLeakIntoLabels() {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdef0123456789-./_?=&@:%ÄÖ ")
        let c = StatsCollector(clock: clockAt(day0))
        for _ in 0..<3000 {
            let path = "/" + String((0..<Int.random(in: 0..<60, using: &rng)).map { _ in chars.randomElement(using: &rng)! })
            c.recordRequest(path: path, status: [200, 304, 404, 429, 500, 503].randomElement(using: &rng)!, bytes: Int.random(in: 0..<5000, using: &rng))
        }
        let valid = Set(StatsRoute.groups)
        for p in c.pending() {
            switch p.metric {
            case "requests": #expect(valid.contains(String(p.label.split(separator: ":")[0])), "\(p.label)")
            case "bytes_out", "errors_5xx": #expect(valid.contains(p.label), "\(p.label)")
            case "rate_limited": #expect(["push", "dashboard", "other"].contains(p.label))
            case "page_view": #expect(StatsRoute.pages.contains(p.label))
            default: Issue.record("unexpected metric \(p.metric)")
            }
        }
    }
}

@Suite("Statistics hooks")
struct StatsHookTests {
    @Test func slotCacheCountsHitsMissesNegativeAndJoined() async throws {
        let stats = StatsCollector(clock: clockAt(day0))
        let cache = SlotCache(maxBytes: 1_000_000, clock: clockAt(day0), stats: stats)
        let blob = SlotBlob(contentType: "image/webp", sha256: "x", data: [1, 2, 3])
        _ = try await cache.load("a/b") { blob }              // miss -> db
        _ = try await cache.load("a/b") { blob }              // hit
        _ = try await cache.load("layer:p/a/b") { nil }       // miss, then negative
        _ = try await cache.load("layer:p/a/b") { nil }
        let d = deltas(stats)
        #expect(d["cache_miss|radar:db"] == 1 && d["cache_hit|radar:memory"] == 1)
        #expect(d["cache_miss|layer:db"] == 1 && d["cache_hit|layer:negative"] == 1)
        // Single-flight: concurrent requests join the one running load.
        let joined = StatsCollector(clock: clockAt(day0))
        let cache2 = SlotCache(maxBytes: 1_000_000, clock: clockAt(day0), stats: joined)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try? await cache2.load("k") { try await Task.sleep(nanoseconds: 100_000_000); return blob } } }
        }
        let j = deltas(joined)
        #expect(j["cache_miss|radar:db"] == 1)
        #expect((j["cache_hit|radar:joined"] ?? 0) + (j["cache_hit|radar:memory"] ?? 0) == 4)
    }

    @Test func ingestRunsAreCounted() async throws {
        let stats = StatsCollector(clock: clockAt(day0))
        let cfg = smallConfig()
        let ok = Ingestor(config: cfg, repo: MemoryRepo(), fetch: FakeDwd(cfg).fetch, owner: "a", sleep: { _ in }, stats: stats)
        #expect(try await ok.process(run: run0))
        let bad = Ingestor(config: cfg, repo: MemoryRepo(), fetch: FakeDwd(cfg, failAll: true).fetch, owner: "a", sleep: { _ in }, stats: stats)
        _ = try? await bad.process(run: run0)
        let d = deltas(stats)
        #expect(d["ingest_run|radar:ok"] == 1)
        #expect((d["ingest_run|radar:missed"] ?? 0) + (d["ingest_run|radar:error"] ?? 0) == 1)
    }
}

extension DatabaseSuites {
@Suite("Statistics flush", .serialized)
struct StatsFlushTests {
    @Test(arguments: RepoKind.allCases) func flushIsAdditiveAndResetsCounters(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = StatsCollector(repo: repo, clock: clockAt(day0))
        c.record("cache_hit", label: "radar:memory", by: 5)
        c.recordRequest(path: "/v1/status", status: 200, bytes: 300)
        #expect(await c.flush())
        #expect(c.pending().isEmpty)
        c.record("cache_hit", label: "radar:memory", by: 2)
        #expect(await c.flush())
        let rows = try await repo.stats(from: day0, to: day0)
        #expect(value(rows, "cache_hit", "radar:memory") == 7)
        #expect(value(rows, "requests", "status:2xx") == 1 && value(rows, "bytes_out", "status") == 300)
        #expect(await c.flush(), "empty flush is fine")
    }

    @Test(arguments: RepoKind.allCases) func replicasSumInOneRow(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let replicas = (0..<3).map { _ in StatsCollector(repo: repo, clock: clockAt(day0)) }
        await withTaskGroup(of: Void.self) { group in
            for r in replicas {
                group.addTask {
                    for _ in 0..<100 { r.recordRequest(path: "/v1/radar/latest.json", status: 200, bytes: 10) }
                    await r.flush()
                    for _ in 0..<50 { r.recordRequest(path: "/v1/radar/latest.json", status: 200, bytes: 10) }
                    await r.flush()
                }
            }
        }
        let rows = try await repo.stats(from: day0, to: day0)
        #expect(value(rows, "requests", "radar_latest:2xx") == 450)
        #expect(value(rows, "bytes_out", "radar_latest") == 4500)
    }

    @Test(arguments: RepoKind.allCases) func failedFlushKeepsCountersAndRetries(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let flaky = FlakyWriter()
        let c = StatsCollector(writer: flaky.writer(repo), clock: clockAt(day0))
        c.record("push_sent", label: "delivered", by: 4)
        flaky.failing = true
        #expect(await c.flush() == false)
        #expect(deltas(c)["push_sent|delivered"] == 4)
        c.record("push_sent", label: "delivered", by: 1)  // counting continues while the DB is down
        #expect(await c.flush() == false)
        #expect(deltas(c)["push_sent|delivered"] == 5)
        flaky.failing = false
        #expect(await c.flush())
        #expect(c.pending().isEmpty)
        #expect(value(try await repo.stats(from: day0, to: day0), "push_sent", "delivered") == 5)
    }

    @Test(arguments: RepoKind.allCases) func failedBatchKeepsItsOwnDayAcrossMidnight(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Locked(day0)
        let flaky = FlakyWriter()
        let c = StatsCollector(writer: flaky.writer(repo), clock: { now.withLock { $0 } })
        c.record("rate_limited", label: "push", by: 3)
        flaky.failing = true
        _ = await c.flush()
        now.withLock { $0 = day0.addingTimeInterval(86400) }
        c.record("rate_limited", label: "push", by: 2)
        flaky.failing = false
        #expect(await c.flush())
        let rows = try await repo.stats(from: day0, to: day0.addingTimeInterval(86400))
        #expect(rows.filter { $0.metric == "rate_limited" }.map { $0.value }.sorted() == [2, 3])
        #expect(rows.filter { $0.metric == "rate_limited" }.count == 2, "one row per day")
    }

    @Test func missingRepoIsANoOp() async {
        let c = StatsCollector(repo: nil, maxKeys: 20, clock: clockAt(day0))
        c.record("cache_hit", label: "radar:memory")
        #expect(await c.flush())
        #expect(await c.purgeIfDue() == false)
        #expect(c.keyCount == 1, "counters stay (bounded) until a repo is attached")
        let repo = MemoryRepo()
        c.setRepo(repo)
        #expect(await c.flush())
        #expect(value(try! await repo.stats(from: day0, to: day0), "cache_hit", "radar:memory") == 1)
    }

    @Test(arguments: RepoKind.allCases) func purgeRunsOncePerDayAndRemovesOldDays(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let old = day0.addingTimeInterval(-40 * 86400)
        try await repo.addStats(day: old, [StatDelta(metric: "requests", label: "other:2xx", value: 1)])
        try await repo.addStats(day: day0, [StatDelta(metric: "requests", label: "other:2xx", value: 1)])
        let now = Locked(day0)
        let c = StatsCollector(repo: repo, clock: { now.withLock { $0 } })
        #expect(await c.purgeIfDue())
        #expect(await c.purgeIfDue() == false)
        let rows = try await repo.stats(from: old, to: day0)
        #expect(rows.count == 1 && rows[0].day >= day0.addingTimeInterval(-86400))
        now.withLock { $0 = day0.addingTimeInterval(86400) }
        #expect(await c.purgeIfDue())
    }

    @Test(arguments: RepoKind.allCases) func runLoopFlushesPeriodicallyAndOnCancel(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = StatsCollector(repo: repo, interval: 0.05, jitter: 0.02, clock: clockAt(day0))
        let task = Task { await c.run() }
        c.record("page_view", label: "support")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(value(try await repo.stats(from: day0, to: day0), "page_view", "support") == 1, "periodic flush")
        c.record("page_view", label: "support", by: 4)
        task.cancel()
        await task.value
        #expect(value(try await repo.stats(from: day0, to: day0), "page_view", "support") == 5, "final flush on shutdown")
    }

    @Test(arguments: RepoKind.allCases) func queryOverviewAndTrafficSeries(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let d1 = day0, d2 = day0.addingTimeInterval(86400), d3 = day0.addingTimeInterval(2 * 86400)
        try await repo.addStats(day: d1, [
            StatDelta(metric: "requests", label: "radar_image:2xx", value: 90), StatDelta(metric: "requests", label: "landing:2xx", value: 10),
            StatDelta(metric: "bytes_out", label: "radar_image", value: 9000), StatDelta(metric: "cache_hit", label: "radar:memory", value: 80),
            StatDelta(metric: "cache_hit", label: "radar:negative", value: 10), StatDelta(metric: "cache_miss", label: "radar:db", value: 10),
            StatDelta(metric: "page_view", label: "landing_de", value: 10)])
        try await repo.addStats(day: d3, [StatDelta(metric: "requests", label: "radar_image:5xx", value: 5),
                                          StatDelta(metric: "errors_5xx", label: "radar_image", value: 5)])
        let q = StatsQuery(repo: repo)
        let o = try await q.overview(from: d1, to: d3)
        #expect(o.days.map(\.day) == ["2026-10-30", "2026-10-31", "2026-11-01"])
        #expect(o.days[1].values.isEmpty, "days without data are present")
        #expect(o.requests == 105 && o.bytesOut == 9000 && o.errors5xx == 5)
        let radar = try #require(o.cache.first { $0.scope == "radar" })
        #expect(radar.hits == 90 && radar.misses == 10 && radar.hitRate == 0.9)
        #expect(o.cache.first { $0.scope == "layer" }?.hitRate == nil)
        let s = try await q.trafficSeries(from: d1, to: d3)
        #expect(s.points.map(\.requests) == [100, 0, 5])
        #expect(s.points[0].byGroup == ["radar_image": 90, "landing": 10] && s.points[0].pageViews == 10)
        _ = d2
        // camelCase JSON
        let json = String(decoding: try JSONEncoder().encode(o), as: UTF8.self)
        #expect(json.contains("\"bytesOut\"") && json.contains("\"hitRate\"") && json.contains("\"errors5xx\""))
        #expect(!json.contains("bytes_out") || json.contains("\"metric\":\"bytes_out\""))
        #expect(try JSONDecoder().decode(StatsOverview.self, from: JSONEncoder().encode(o)) == o)
    }
}
}

@Suite("Statistics overhead", .serialized)
struct StatsOverheadTests {
    /// Micro benchmark of the per-request cost (classification + counting under the lock), single thread and contended.
    @Test func perRequestOverheadIsSmall() async {
        let c = StatsCollector(clock: clockAt(day0))
        let paths = ["/v1/radar/20261030T1105Z/20261030T1110Z.webp", "/v1/radar/latest.json", "/v1/layers/pressure/latest.json",
                     "/v1/push/installations/3F2504E0-4F89-41D3-9A0C-0305E82C3301", "/", "/healthz"]
        for i in 0..<20_000 { c.recordRequest(path: paths[i % paths.count], status: 200, bytes: 100) }  // warm-up
        let n = 300_000
        let clock = ContinuousClock()
        let single = clock.measure { for i in 0..<n { c.recordRequest(path: paths[i % paths.count], status: 200, bytes: 100) } }
        let perCall = Double(single.components.attoseconds) / 1e18 / Double(n) + Double(single.components.seconds) / Double(n)
        let threads = 8, each = 50_000
        let contended = await clock.measure {
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<threads { group.addTask { for i in 0..<each { c.recordRequest(path: paths[(i + t) % paths.count], status: 200, bytes: 100) } } }
            }
        }
        let perContended = (Double(contended.components.attoseconds) / 1e18 + Double(contended.components.seconds)) / Double(threads * each)
        print("STATS-OVERHEAD single=\(String(format: "%.2f", perCall * 1e6)) us/request contended(8 tasks)=\(String(format: "%.2f", perContended * 1e6)) us/request")
        #if DEBUG
        #expect(perCall < 100e-6, "debug build bound")
        #else
        #expect(perCall < 20e-6)
        #endif
    }
}
