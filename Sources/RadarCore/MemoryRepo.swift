import Foundation

/// Fake with the same semantics as `MariaRepo` (single process), used by the fast contract tests.
public actor MemoryRepo: Repo {
    struct Run {
        var nominal: Date
        var status: String
        var owner: String
        var attempts: Int
        var lease: Date
        var publishedAt: Date?
    }
    private let clock: @Sendable () -> Date
    private var runs: [String: Run] = [:]
    private var slots: [String: [String: (ref: SlotRef, type: String, sha: String, data: [UInt8])]] = [:]

    public init(clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }) {
        self.clock = clock
    }

    public func migrate() async throws {}
    public func ping() async throws {}

    public func tryClaim(runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool {
        let now = clock()
        guard var run = runs[runID] else {
            runs[runID] = Run(nominal: nominal, status: "claimed", owner: owner, attempts: 1,
                              lease: now.addingTimeInterval(Double(leaseSeconds)))
            return true
        }
        if run.status == "published" || run.lease >= now || run.attempts >= maxAttempts { return false }
        run.status = "claimed"; run.owner = owner; run.attempts += 1
        run.lease = now.addingTimeInterval(Double(leaseSeconds))
        runs[runID] = run
        return true
    }

    public func renew(runID: String, owner: String, leaseSeconds: Int) async throws -> Bool {
        guard var run = runs[runID], run.owner == owner, run.status == "claimed" else { return false }
        run.lease = clock().addingTimeInterval(Double(leaseSeconds))
        runs[runID] = run
        return true
    }

    public func putSlot(_ ref: SlotRef, contentType: String, data: [UInt8]) async throws {
        slots[ref.runID, default: [:]][ref.slotID] = (ref, contentType, Hashing.sha256Hex(data), data)
    }

    public func publish(runID: String, owner: String, expectedSlots: Int) async throws -> Bool {
        guard var run = runs[runID], run.status == "claimed", run.owner == owner else { return false }
        guard (slots[runID]?.count ?? 0) == expectedSlots else { return false }
        run.status = "published"; run.publishedAt = clock()
        runs[runID] = run
        return true
    }

    public func fail(runID: String, owner: String, cooldownSeconds: Int) async throws {
        guard var run = runs[runID], run.owner == owner, run.status == "claimed" else { return }
        run.status = "failed"; run.lease = clock().addingTimeInterval(Double(cooldownSeconds))
        runs[runID] = run
    }

    public func isPublished(runID: String) async throws -> Bool { runs[runID]?.status == "published" }

    public func latestPublished() async throws -> PublishedRun? {
        let published = runs.filter { $0.value.status == "published" }
        guard let best = published.max(by: { $0.value.nominal < $1.value.nominal }) else { return nil }
        return PublishedRun(runID: best.key, nominal: best.value.nominal, publishedAt: best.value.publishedAt ?? best.value.nominal)
    }

    public func publishedSlots(runID: String) async throws -> [SlotRef] {
        guard runs[runID]?.status == "published" else { return [] }
        return (slots[runID] ?? [:]).values.map(\.ref).sorted { $0.slotIndex < $1.slotIndex }
    }

    public func historySlots(since: Date, before: Date) async throws -> [SlotRef] {
        var out: [SlotRef] = []
        for (runID, run) in runs where run.status == "published" && run.nominal >= since && run.nominal < before {
            out += (slots[runID] ?? [:]).values.map(\.ref).filter { $0.slotIndex == 0 }
        }
        return out.sorted { $0.slotTime < $1.slotTime }
    }

    public func getSlot(runID: String, slotID: String) async throws -> SlotBlob? {
        guard runs[runID]?.status == "published", let v = slots[runID]?[slotID] else { return nil }
        return SlotBlob(contentType: v.type, sha256: v.sha, data: v.data)
    }

    public func retain(keepPublished: Int, staleAfter: TimeInterval) async throws -> Int {
        let published = runs.filter { $0.value.status == "published" }.sorted { $0.value.nominal > $1.value.nominal }
        var doomed = published.dropFirst(max(0, keepPublished)).map(\.key)
        let cutoff = clock().addingTimeInterval(-staleAfter)
        doomed += runs.filter { $0.value.status != "published" && $0.value.lease < cutoff }.map(\.key)
        for id in doomed { runs[id] = nil; slots[id] = nil }
        return doomed.count
    }
}
