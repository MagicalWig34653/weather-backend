import Foundation
import Testing
@testable import RadarCore

// Traffic statistics end to end: two replicas (two collectors) flush into one repo; the traffic insights read it back.
// Memory always, MariaDB when RADAR_TEST_DB_HOST is set (disposable database only).
private func ij(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }
private func rows(_ any: Any?) -> [[String: Any]] { any as? [[String: Any]] ?? [] }

extension DatabaseSuites {
@Suite("Traffic statistics", .serialized)
struct TrafficStatsTests {
    private func engine(_ repo: any Repo, now: Date) -> InsightsEngine {
        let source = RepoInsightsDataSource(repo: repo, enabledLayers: [], context: { .make(config: Config()) })
        return InsightsEngine(source: source, clock: { now })
    }

    private func replica(_ repo: any Repo, at date: Date) -> StatsCollector {
        StatsCollector(repo: repo, interval: 60, clock: { date })
    }

    @Test(arguments: RepoKind.allCases) func twoReplicasWriteDayAndHour(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 3600).addingTimeInterval(600)
        let a = replica(repo, at: now), b = replica(repo, at: now.addingTimeInterval(-3600))
        for c in [a, b] {
            for _ in 0..<5 { c.recordRequest(path: "/v1/radar/latest.json", status: 200, bytes: 700, seconds: 0.004) }
            c.recordRequest(path: "/v1/radar/latest.json", status: 304, bytes: 0, seconds: 0.001)
            c.recordRequest(path: "/nope", status: 404, bytes: 20, seconds: 0.002)
        }
        let okA = await a.flush(), okB = await b.flush()
        #expect(okA && okB)
        let hour = TimeUtil.floor(now, to: 3600)
        let hourly = try await repo.statsHourly(from: hour.addingTimeInterval(-3600), to: hour)
        let daily = try await repo.stats(from: hour.addingTimeInterval(-86400), to: hour)
        func total(_ r: [(String, Int)], _ m: String) -> Int { r.filter { $0.0 == m }.reduce(0) { $0 + $1.1 } }
        for metric in ["requests", "bytes_out", "latency"] {
            #expect(total(hourly.map { ($0.metric, $0.value) }, metric) > 0, "hourly \(metric)")
            #expect(total(daily.map { ($0.metric, $0.value) }, metric) > 0, "daily \(metric)")
        }
        #expect(total(hourly.map { ($0.metric, $0.value) }, "bytes_out") == 2 * (5 * 700 + 20))
        #expect(total(hourly.map { ($0.metric, $0.value) }, "requests") == 14)

        let traffic = try await engine(repo, now: now).traffic(range: .h24)
        let requests = ij(traffic["requests"])
        #expect(requests["total"] as? Int == 14)
        let bytes = rows(requests["byRoute"]).reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
        #expect(bytes == 2 * (5 * 700 + 20), "data volume comes from the same hourly window as the requests")
        let series = ij(requests["series"])
        #expect(series["resolution"] as? String == "hour")
        let nonZero = rows(series["points"]).filter { ($0["v"] as? Int ?? 0) > 0 }
        #expect(nonZero.count == 2)
    }

    @Test(arguments: RepoKind.allCases) func hourlyWithoutRequestsFallsBackToDays(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 3600).addingTimeInterval(600)
        try await repo.addStats(day: now, [StatDelta(metric: "requests", label: "radar_image:2xx", value: 90),
                                           StatDelta(metric: "bytes_out", label: "radar_image", value: 9000)])
        try await repo.addStatsHourly(hour: now, [StatDelta(metric: "ingest_run", label: "radar:ok", value: 1)])
        let traffic = try await engine(repo, now: now).traffic(range: .h24)
        let requests = ij(traffic["requests"])
        #expect(requests["total"] as? Int == 90, "day counters are not hidden by a hourly table without requests")
        #expect(ij(requests["series"])["resolution"] as? String == "day")
        #expect(rows(requests["byRoute"]).reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) } == 9000)
        let findings = try await engine(repo, now: now).findings()
        let codes = rows(findings["findings"]).compactMap { $0["code"] as? String }
        #expect(codes.contains("stats_hourly_empty"))
    }

    @Test(arguments: RepoKind.allCases) func flushErrorsShowUpInOpsAndFindings(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 3600).addingTimeInterval(600)
        try await repo.addStats(day: now, [StatDelta(metric: "stats_flush_error", label: "hour", value: 2)])
        let e = engine(repo, now: now)
        #expect(ij(ij(try await e.ops(range: .d7)["errors"]))["statsFlushErrors"] as? Int == 2)
        let codes = rows(try await e.findings()["findings"]).compactMap { $0["code"] as? String }
        #expect(codes.contains("stats_write_error"))
    }

    @Test(arguments: RepoKind.allCases) func noHintWhenHourlyHasRequests(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = TimeUtil.floor(Date(), to: 3600).addingTimeInterval(600)
        try await repo.addStats(day: now, [StatDelta(metric: "requests", label: "radar_image:2xx", value: 90)])
        try await repo.addStatsHourly(hour: now, [StatDelta(metric: "requests", label: "radar_image:2xx", value: 90)])
        let codes = rows(try await engine(repo, now: now).findings()["findings"]).compactMap { $0["code"] as? String }
        #expect(!codes.contains("stats_hourly_empty"))
    }
}
}

@Suite("Statistics flush errors")
struct StatsFlushErrorTests {
    struct Boom: Error {}

    @Test func hourFailureIsCountedAndRetried() async {
        let failing = Locked(true)
        let wrote = Locked<[String]>([])
        let writer = StatsCollector.Writer(
            addStats: { _, d in wrote.withLock { $0 += d.map { "d:" + $0.metric } } }, purge: { _ in },
            addHourly: { _, d in
                if failing.withLock({ $0 }) { throw Boom() }
                wrote.withLock { $0 += d.map { "h:" + $0.metric } }
            })
        let c = StatsCollector(writer: writer, clock: { Date(timeIntervalSince1970: 1_790_000_000) })
        c.recordRequest(path: "/healthz", status: 200, bytes: 2)
        #expect(await c.flush() == false)
        #expect(c.flushErrors == ["hour": 1], "counted per kind, no error text")
        #expect(c.pending().contains { $0.metric == "stats_flush_error" && $0.label == "hour" })
        failing.withLock { $0 = false }
        #expect(await c.flush())
        #expect(wrote.withLock { $0 }.contains("d:stats_flush_error"), "the error counter reaches the day table")
        #expect(wrote.withLock { $0 }.contains("h:requests"))
    }

    @Test func dayFailureDoesNotBlockHour() async {
        let wrote = Locked<[String]>([])
        let writer = StatsCollector.Writer(addStats: { _, _ in throw Boom() }, purge: { _ in },
                                           addHourly: { _, d in wrote.withLock { $0 += d.map { "h:" + $0.metric } } })
        let c = StatsCollector(writer: writer)
        c.recordRequest(path: "/healthz", status: 200, bytes: 2)
        #expect(await c.flush() == false)
        #expect(wrote.withLock { $0 }.contains("h:requests"))
        #expect(c.flushErrors == ["day": 1])
    }

    @Test func responseBytesUseBodyOrContentLength() {
        #expect(StatsRoute.responseBytes(bodyCount: 120, contentLength: "5") == 120)
        #expect(StatsRoute.responseBytes(bodyCount: -1, contentLength: "5000") == 5000, "streamed body: Content-Length")
        #expect(StatsRoute.responseBytes(bodyCount: 0, contentLength: nil) == 0)
        #expect(StatsRoute.responseBytes(bodyCount: -1, contentLength: "junk") == 0)
        #expect(StatsRoute.responseBytes(bodyCount: -1, contentLength: "-4") == 0)
    }
}
