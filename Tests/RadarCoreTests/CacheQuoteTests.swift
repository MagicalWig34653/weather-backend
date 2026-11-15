import Foundation
import Synchronization
import Testing
@testable import RadarCore

// Schutz der Cache-Quote (Meldung 15.11.2026: "nahezu 0"): wiederholte Abrufe derselben Schluessel muessen Treffer zaehlen,
// nur der erste Abruf je Schluessel ist ein Fehlgriff (DB-Lesung).
private final class CountingSink: StatsSink {
    private let counts = Mutex<[String: Int]>([:])
    func record(_ metric: String, label: String, by value: Int) { counts.withLock { $0[metric, default: 0] += value } }
    func total(_ metric: String) -> Int { counts.withLock { $0[metric] ?? 0 } }
}

@Suite struct CacheQuoteTests {
    @Test func repeatedSlotRequestsHitTheCache() async throws {
        let sink = CountingSink()
        let cache = SlotCache(maxBytes: 1 << 20, stats: sink)
        let blob = SlotBlob(contentType: "image/webp", sha256: "x", data: [UInt8](repeating: 1, count: 100))
        for _ in 0..<20 { for key in ["a", "b", "c", "layer:l/r/s"] { _ = try await cache.load(key) { blob } } }
        #expect(sink.total("cache_miss") == 4)
        #expect(sink.total("cache_hit") == 76)
        #expect(await cache.dbReads == 4)
    }
}
