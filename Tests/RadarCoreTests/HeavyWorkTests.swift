import Foundation
import Testing
@testable import RadarCore

@Suite("Heavy conversion gate (radar OOM)")
struct HeavyWorkTests {
    final class Overlap: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var maximum = 0
        func enter() { lock.lock(); running += 1; maximum = max(maximum, running); lock.unlock() }
        func leave() { lock.lock(); running -= 1; lock.unlock() }
        var observed: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    }

    /// Several layer loops converting at the same time: at most one conversion runs, all finish.
    @Test func atMostOneConversionAtATime() async throws {
        let gate = HeavyWork(limit: 1), overlap = Overlap()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<6 {
                group.addTask {
                    try await gate.run {
                        overlap.enter(); defer { overlap.leave() }
                        Thread.sleep(forTimeInterval: 0.02)
                        return i
                    }
                }
            }
            var out: [Int] = []
            for try await r in group { out.append(r) }
            return out
        }
        #expect(results.sorted() == Array(0..<6))
        #expect(overlap.observed == 1)
    }

    @Test func limitTwoAllowsTwo() async throws {
        let gate = HeavyWork(limit: 2), overlap = Overlap()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { try await gate.run { overlap.enter(); defer { overlap.leave() }; Thread.sleep(forTimeInterval: 0.03) } }
            }
            try await group.waitForAll()
        }
        #expect(overlap.observed <= 2)
    }

    /// A failing conversion gives its permit back.
    @Test func errorReleasesThePermit() async throws {
        let gate = HeavyWork(limit: 1)
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await gate.run { throw Boom() } }
        let value = try await gate.run { 7 }
        #expect(value == 7)
    }

    /// A waiting conversion that is cancelled (shutdown) leaves the queue and does not run.
    @Test func cancelledWaiterDoesNotRun() async throws {
        let gate = HeavyWork(limit: 1)
        let ran = Overlap()
        let holder = Task { try await gate.run { Thread.sleep(forTimeInterval: 0.3) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let waiter = Task { try await gate.run { ran.enter() } }
        while await gate.waiting() == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        try await holder.value
        #expect(ran.observed == 0)
        #expect(try await gate.run { 1 } == 1)
    }

    /// Layer ingest goes through the gate: with the gate held, a tick does not convert.
    @Test func layerIngestUsesTheGate() async throws {
        let gate = HeavyWork(limit: 1)
        let spec = LayerCatalog.specs["lightning"]!.resized(width: 64)
        let config = smallConfig { $0.layers = ["lightning"]; $0.layerPauseSeconds = 0 }
        let png = pngBytes(makeImage(width: spec.width(config), height: spec.height(config), seed: 3))
        let ingestor = LayerIngestor(spec: spec, config: config, repo: MemoryRepo(), fetch: { _ in png }, owner: "a", sleep: { _ in }, heavy: gate)
        let holder = Task { try await gate.run { Thread.sleep(forTimeInterval: 0.3) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        _ = try await ingestor.fetchAndConvert(url: "u", slot: run0)
        #expect(Date().timeIntervalSince(started) > 0.15)
        try await holder.value
    }
}
