import Foundation

public struct SlotRef: Sendable, Equatable {
    public let runID: String
    public let slotID: String
    public let slotIndex: Int
    public let slotTime: Date
    public init(runID: String, slotID: String, slotIndex: Int, slotTime: Date) {
        self.runID = runID; self.slotID = slotID; self.slotIndex = slotIndex; self.slotTime = slotTime
    }
}

public struct SlotBlob: Sendable, Equatable {
    public let contentType: String
    public let sha256: String
    public let data: [UInt8]
    public init(contentType: String, sha256: String, data: [UInt8]) {
        self.contentType = contentType; self.sha256 = sha256; self.data = data
    }
}

public struct PublishedRun: Sendable, Equatable {
    public let runID: String
    public let nominal: Date
    public let publishedAt: Date
    public init(runID: String, nominal: Date, publishedAt: Date) {
        self.runID = runID; self.nominal = nominal; self.publishedAt = publishedAt
    }
}

/// State storage. Contract (see tests): claim/renew/fail/publish are atomic and owner-checked;
/// readers only see published runs. All times are UTC with second resolution.
public protocol Repo: Sendable {
    func migrate() async throws
    func ping() async throws
    /// `backfill` marks an analysis-only run (one slot) created by the backfill; a takeover then drops stale forecast slots.
    func tryClaim(runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int, backfill: Bool) async throws -> Bool
    func renew(runID: String, owner: String, leaseSeconds: Int) async throws -> Bool
    func putSlot(_ ref: SlotRef, contentType: String, data: [UInt8]) async throws
    func publish(runID: String, owner: String, expectedSlots: Int) async throws -> Bool
    func fail(runID: String, owner: String, cooldownSeconds: Int) async throws
    func isPublished(runID: String) async throws -> Bool
    func latestPublished() async throws -> PublishedRun?
    func publishedSlots(runID: String) async throws -> [SlotRef]
    /// Analysis slots of full runs in [since, before) (latest.json history; backfilled runs are excluded on purpose).
    func historySlots(since: Date, before: Date) async throws -> [SlotRef]
    /// Analysis slots of ALL published runs (full and backfilled) in [since, before), ascending (history.json). One query.
    func analysisSlots(since: Date, before: Date) async throws -> [SlotRef]
    /// Run times in [since, until] that need no backfill: published, or claimed/failed but not takeable right now.
    func settledRunTimes(since: Date, until: Date, maxAttempts: Int) async throws -> Set<Date>
    /// Cross-replica leader lease (acquire or renew). Exactly one owner holds a non-expired lease per name.
    func acquireLeader(name: String, owner: String, leaseSeconds: Int) async throws -> Bool
    func releaseLeader(name: String, owner: String) async throws
    func getSlot(runID: String, slotID: String) async throws -> SlotBlob?
    /// Keeps the newest `keepPublished` full runs completely; older published runs keep only their analysis slot
    /// until `keepAnalysisSince` and are deleted entirely before it. Unpublished leftovers expire after `staleAfter`.
    func retain(keepPublished: Int, keepAnalysisSince: Date, staleAfter: TimeInterval) async throws -> Int
}

extension Repo {
    func tryClaim(runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool {
        try await tryClaim(runID: runID, nominal: nominal, owner: owner, leaseSeconds: leaseSeconds, maxAttempts: maxAttempts, backfill: false)
    }
}
