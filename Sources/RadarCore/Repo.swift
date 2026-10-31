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
public protocol Repo: PushRepo, LayerRepo {
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

/// Additional map layers: same claim/publish contract as the radar, keyed by layer id. Observation layers use one run
/// per slot (run id = slot id); forecast layers one run per reference time with several slots.
public protocol LayerRepo: Sendable {
    func layerTryClaim(layer: String, runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool
    func layerRenew(layer: String, runID: String, owner: String, leaseSeconds: Int) async throws -> Bool
    func layerPutSlot(layer: String, _ ref: SlotRef, contentType: String, data: [UInt8]) async throws
    func layerPublish(layer: String, runID: String, owner: String, expectedSlots: Int) async throws -> Bool
    func layerFail(layer: String, runID: String, owner: String, cooldownSeconds: Int) async throws
    func layerIsPublished(layer: String, runID: String) async throws -> Bool
    func layerLatestPublished(layer: String) async throws -> PublishedRun?
    func layerPublishedSlots(layer: String, runID: String) async throws -> [SlotRef]
    /// Slot 0 of all published runs with nominal time in [since, before), ascending.
    func layerFirstSlots(layer: String, since: Date, before: Date) async throws -> [SlotRef]
    func layerGetSlot(layer: String, runID: String, slotID: String) async throws -> SlotBlob?
    /// Deletes published runs that are not among the newest `keepNewest` AND older than `keepSince`, and unpublished
    /// leftovers after `staleAfter`. Returns the number of deleted runs.
    func layerRetain(layer: String, keepNewest: Int, keepSince: Date, staleAfter: TimeInterval) async throws -> Int
}

/// Push registration, evaluation state and outbox. Times are passed in by the caller (UTC, second resolution).
/// Secrets are stored only as SHA-256 hex hashes; no coordinates, only raster cells.
public protocol PushRepo: Sendable {
    /// Creates the installation, or updates token/env/locale when `secretHash` matches (`forbidden` otherwise).
    func upsertInstallation(id: String, secretHash: String, token: String, env: PushEnvironment, locale: String, now: Date) async throws -> UpsertResult
    /// True when the installation exists and the hash matches; then also refreshes `last_seen_at`.
    func authenticate(id: String, secretHash: String, now: Date) async throws -> Bool
    /// Deletes the installation with all subscriptions and outbox entries.
    func deleteInstallation(id: String) async throws
    func addSubscription(installationID: String, id: String, _ input: PushSubscriptionInput, maxPerInstallation: Int, now: Date) async throws -> AddSubscriptionResult
    /// Replaces the client fields and re-arms the automaton; false when the subscription does not belong to the installation.
    func updateSubscription(installationID: String, id: String, _ input: PushSubscriptionInput) async throws -> Bool
    func deleteSubscription(installationID: String, id: String) async throws -> Bool
    func subscriptions(installationID: String) async throws -> [PushSubscription]
    /// Delivery target of an authenticated installation (nil when unknown).
    func installation(id: String) async throws -> PushInstallation?
    /// All enabled subscriptions of a raster version (for the evaluation after a radar run).
    func evaluationSubscriptions(gridVersion: Int) async throws -> [PushSubscription]
    func lastEvaluatedRun() async throws -> String?
    /// Atomic: only if `runID` is newer than the last evaluated run it stores it, applies the state updates and inserts the
    /// outbox entries (duplicate `dedupeKey` ignored). Returns false when the run was already evaluated.
    func commitEvaluation(runID: String, updates: [SubscriptionUpdate], outbox: [NewOutboxItem], now: Date) async throws -> Bool
    func dueOutbox(now: Date, limit: Int) async throws -> [OutboxItem]
    func finishOutbox(id: Int, _ outcome: OutboxOutcome, now: Date) async throws
    /// 410 Unregistered: removes the installations (and thereby subscriptions/outbox) with this token and environment.
    func deleteInstallations(token: String, env: PushEnvironment) async throws -> Int
    /// Retention: installations not seen since `inactiveBefore`, and outbox entries that are finished/expired before `outboxBefore`.
    func purgePush(inactiveBefore: Date, outboxBefore: Date, now: Date) async throws -> PushPurgeResult
}

extension Repo {
    func tryClaim(runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool {
        try await tryClaim(runID: runID, nominal: nominal, owner: owner, leaseSeconds: leaseSeconds, maxAttempts: maxAttempts, backfill: false)
    }
}
