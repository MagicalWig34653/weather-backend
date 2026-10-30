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
    func tryClaim(runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool
    func renew(runID: String, owner: String, leaseSeconds: Int) async throws -> Bool
    func putSlot(_ ref: SlotRef, contentType: String, data: [UInt8]) async throws
    func publish(runID: String, owner: String, expectedSlots: Int) async throws -> Bool
    func fail(runID: String, owner: String, cooldownSeconds: Int) async throws
    func isPublished(runID: String) async throws -> Bool
    func latestPublished() async throws -> PublishedRun?
    func publishedSlots(runID: String) async throws -> [SlotRef]
    func historySlots(since: Date, before: Date) async throws -> [SlotRef]
    func getSlot(runID: String, slotID: String) async throws -> SlotBlob?
    func retain(keepPublished: Int, staleAfter: TimeInterval) async throws -> Int
}
