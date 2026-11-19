import Foundation
import Testing
@testable import RadarCore

@Suite("Slot cache within the container limit (radar OOM)")
struct MemoryBudgetTests {
    let mb = 1_048_576

    @Test func noLimitKeepsTheSetting() {
        #expect(MemoryBudget.cacheBytes(configured: 512 * mb, containerLimit: nil) == 512 * mb)
        #expect(MemoryBudget.cacheBytes(configured: 64 * mb, containerLimit: 0) == 64 * mb)
    }

    /// The live case of 18 Nov 2026: 512 MB cache in a 512M container cannot fit next to the ingest.
    @Test func cacheIsCappedBelowTheLimit() {
        let at512 = MemoryBudget.cacheBytes(configured: 512 * mb, containerLimit: 512 * mb)
        #expect(at512 == 64 * mb)
        #expect(at512 + MemoryBudget.reserveBytes < 512 * mb)
        #expect(MemoryBudget.cacheBytes(configured: 512 * mb, containerLimit: 768 * mb) == 192 * mb)
        // the default 64 MB fits both limits unchanged
        #expect(MemoryBudget.cacheBytes(configured: 64 * mb, containerLimit: 512 * mb) == 64 * mb)
        #expect(MemoryBudget.cacheBytes(configured: 64 * mb, containerLimit: 768 * mb) == 64 * mb)
    }

    @Test func tinyLimitKeepsAMinimumCache() {
        #expect(MemoryBudget.cacheBytes(configured: 512 * mb, containerLimit: 256 * mb) == MemoryBudget.minimumCacheBytes)
    }

    @Test func readsCgroupV2AndV1() {
        func reader(_ files: [String: String]) -> (String) -> String? { { files[$0] } }
        #expect(MemoryBudget.containerLimit(read: reader(["/sys/fs/cgroup/memory.max": "536870912\n"])) == 512 * mb)
        #expect(MemoryBudget.containerLimit(read: reader(["/sys/fs/cgroup/memory.max": "max\n"])) == nil)
        #expect(MemoryBudget.containerLimit(read: reader(["/sys/fs/cgroup/memory/memory.limit_in_bytes": "805306368"])) == 768 * mb)
        #expect(MemoryBudget.containerLimit(read: reader(["/sys/fs/cgroup/memory/memory.limit_in_bytes": "9223372036854771712"])) == nil)
        #expect(MemoryBudget.containerLimit(read: reader([:])) == nil)
    }

    @Test func apiCacheUsesTheBudget() async {
        let config = smallConfig { $0.cacheMaxBytes = 512 * 1_048_576 }
        let api = Api(repo: MemoryRepo(), configProvider: ConfigProvider(config), containerLimit: 512 * 1_048_576)
        #expect(await api.cache.snapshot().maxBytes == 64 * 1_048_576)
        let free = Api(repo: MemoryRepo(), config: config)
        #expect(await free.cache.snapshot().maxBytes == 512 * 1_048_576)
    }
}
