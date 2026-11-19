import Foundation

/// Process-wide gate for the memory-heavy conversions of the layer ingest (OPERA HDF5 + reprojection, 2048 px PNG decode, WebP encode).
/// Every layer loop runs as its own task and the leader of several layers is often the same replica: without the gate their
/// conversions overlap and the transient buffers (OPERA about 190 MB, a 2048 px PNG layer up to 235 MB above the base; three at once 520 MB, measured 18 Nov 2026) add up next to
/// the slot cache. One conversion at a time per replica caps the ingest peak at the largest single conversion (radar OOM, 18 Nov 2026).
/// The downloads stay outside the gate; only the synchronous decode/render/encode step waits.
public final class HeavyWork: Sendable {
    public static let shared = HeavyWork(limit: 1)

    private let gate: Gate

    public init(limit: Int) { gate = Gate(limit: max(1, limit)) }

    /// Runs `body` once a permit is free (FIFO). Cancellation while waiting throws `CancellationError` and gives no permit away.
    public func run<T>(_ body: () throws -> T) async throws -> T {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            let value = try body()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Waiting conversions (for tests and diagnostics).
    public func waiting() async -> Int { await gate.waiters.count }

    actor Gate {
        private var free: Int
        private(set) var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

        init(limit: Int) { free = limit }

        func acquire() async throws {
            if free > 0, waiters.isEmpty { free -= 1; return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                    waiters.append((id, c))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: i).continuation.resume(throwing: CancellationError())
        }

        func release() {
            if waiters.isEmpty { free += 1 } else { waiters.removeFirst().continuation.resume() }
        }
    }
}
