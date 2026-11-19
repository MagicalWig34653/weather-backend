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

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Holds the gate until `release` is set (no fixed sleeps: the suite runs slowly on throttled machines).
    static func hold(_ gate: HeavyWork, entered: Flag, release: Flag) -> Task<Void, Error> {
        Task { try await gate.run { entered.set(); while !release.isSet { Thread.sleep(forTimeInterval: 0.002) } } }
    }

    static func until(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !(await condition()) {
            guard Date() < deadline else { Issue.record("condition not reached"); return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// A waiting conversion that is cancelled (shutdown) leaves the queue and does not run.
    @Test func cancelledWaiterDoesNotRun() async throws {
        let gate = HeavyWork(limit: 1), ran = Overlap(), entered = Flag(), release = Flag()
        let holder = Self.hold(gate, entered: entered, release: release)
        try await Self.until { entered.isSet }
        let waiter = Task { try await gate.run { ran.enter() } }
        try await Self.until { await gate.waiting() > 0 }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        release.set()
        try await holder.value
        #expect(ran.observed == 0)
        #expect(try await gate.run { 1 } == 1)
    }

    /// Layer ingest goes through the gate: while the gate is held, the conversion waits in the queue.
    @Test func layerIngestUsesTheGate() async throws {
        let gate = HeavyWork(limit: 1), entered = Flag(), release = Flag()
        let spec = LayerCatalog.specs["lightning"]!.resized(width: 64)
        let config = smallConfig { $0.layers = ["lightning"]; $0.layerPauseSeconds = 0 }
        let png = pngBytes(makeImage(width: spec.width(config), height: spec.height(config), seed: 3))
        let ingestor = LayerIngestor(spec: spec, config: config, repo: MemoryRepo(), fetch: { _ in png }, owner: "a", sleep: { _ in }, heavy: gate)
        let holder = Self.hold(gate, entered: entered, release: release)
        try await Self.until { entered.isSet }
        let convert = Task { try await ingestor.fetchAndConvert(url: "u", slot: run0) }
        try await Self.until { await gate.waiting() == 1 }
        release.set()
        let webp = try await convert.value
        #expect(webp.starts(with: Array("RIFF".utf8)))
        try await holder.value
    }
}
