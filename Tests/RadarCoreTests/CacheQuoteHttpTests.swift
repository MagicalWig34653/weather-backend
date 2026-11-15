import Foundation
import Synchronization
import Testing
@testable import RadarCore

// Cache-Quote ueber den HTTP-Pfad (Api.handle), nicht nur SlotCache: drei Clients holen Manifest und alle Slots
// (ohne und mit If-None-Match). Gemessen auf 03cceda und 8e988e6 identisch (Untersuchung 15.11.2026).
private final class QuoteSink: StatsSink {
    private let counts = Mutex<[String: Int]>([:])
    func record(_ metric: String, label: String, by value: Int) { counts.withLock { $0[metric, default: 0] += value } }
    func total(_ metric: String) -> Int { counts.withLock { $0[metric] ?? 0 } }
}

@Suite struct CacheQuoteHttpTests {
    @Test func threeClientsOverHttpMostlyHitTheCache() async throws {
        let repo = MemoryRepo()
        let cfg = smallConfig()
        let ing = Ingestor(config: cfg, repo: repo, fetch: FakeDwd(cfg).fetch, owner: "a", sleep: { _ in }, transcode: memoizedTranscode)
        #expect(try await ing.process(run: run0))
        let sink = QuoteSink()
        let api = Api(repo: repo, config: cfg, stats: sink)
        let latest = try await api.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(latest.body)) as? [String: Any])
        let paths = try #require(doc["slots"] as? [[String: String]]).compactMap { $0["path"] }
        #expect(!paths.isEmpty)
        for _ in 0..<3 {
            for p in paths {
                let r = try await api.handle(path: "/v1/radar/" + p, ifNoneMatch: nil)
                #expect(r.status == 200)
                let etag = r.headers.first { $0.0 == "ETag" }?.1
                #expect(try await api.handle(path: "/v1/radar/" + p, ifNoneMatch: etag).status == 304)
            }
        }
        let hits = sink.total("cache_hit"), misses = sink.total("cache_miss")
        print("CACHE_QUOTE_HTTP slots=\(paths.count) hits=\(hits) misses=\(misses) ratio=\(Double(hits) / Double(hits + misses))")
        #expect(misses == paths.count)
        #expect(hits == paths.count * 5)
    }
}
