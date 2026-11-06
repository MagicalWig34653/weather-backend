import Foundation

/// Inventory of the published slots of one layer in the database (`radar` = the radar tables). Published runs only, except the
/// last attempt which looks at runs of any status.
public struct CacheLayerInventory: Sendable, Equatable {
    public let layer: String
    public let runs: Int
    public let slots: Int
    public let bytes: Int
    public let oldestNominal: Date?
    public let newestNominal: Date?
    public let latestPublishedAt: Date?
    public let lastAttemptAt: Date?
    /// `claimed` (lease still valid: running), `claimed_expired`, `failed`, `published`.
    public let lastAttemptStatus: String?
    public init(layer: String, runs: Int, slots: Int, bytes: Int, oldestNominal: Date?, newestNominal: Date?, latestPublishedAt: Date?,
                lastAttemptAt: Date?, lastAttemptStatus: String?) {
        self.layer = layer; self.runs = runs; self.slots = slots; self.bytes = bytes; self.oldestNominal = oldestNominal
        self.newestNominal = newestNominal; self.latestPublishedAt = latestPublishedAt; self.lastAttemptAt = lastAttemptAt
        self.lastAttemptStatus = lastAttemptStatus
    }
}

public struct CacheSlotRow: Sendable, Equatable {
    public let slot: Date
    public let run: Date
    public let index: Int
    public let bytes: Int
    public let contentType: String
    public let published: Bool
    public let publishedAt: Date?
    public init(slot: Date, run: Date, index: Int, bytes: Int, contentType: String, published: Bool, publishedAt: Date?) {
        self.slot = slot; self.run = run; self.index = index; self.bytes = bytes; self.contentType = contentType
        self.published = published; self.publishedAt = publishedAt
    }
}

public enum RefreshStatus: String, Sendable { case queued, running, ok, failed, expired }

/// One manual ingest job. `result` is a small JSON object with fixed fields (`stored`, `failed`, `published`).
public struct RefreshJob: Sendable, Equatable {
    public let id: String
    public let layer: String
    public var status: RefreshStatus
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var result: String?
    public var error: String?
    public init(id: String, layer: String, status: RefreshStatus, createdAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil,
                result: String? = nil, error: String? = nil) {
        self.id = id; self.layer = layer; self.status = status; self.createdAt = createdAt; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.result = result; self.error = error
    }
}

public struct ReplicaCacheFill: Sendable, Equatable {
    public let bytes: Int
    public let entries: Int
    public let maxBytes: Int
    public init(bytes: Int, entries: Int, maxBytes: Int) { self.bytes = bytes; self.entries = entries; self.maxBytes = maxBytes }
}

public enum RefreshRetention {
    /// Unclaimed jobs expire after this many seconds (`no_ingest_replica`).
    public static let queuedExpirySeconds: TimeInterval = 120
    /// A `running` job without a result (replica died) fails with `timeout` after this long.
    public static let runningTimeoutSeconds: TimeInterval = 300
    public static let keepHours = 24
    public static let keepJobs = 100
}

/// Operator cache tools: inventory, slot list and preview of the stored images, manual ingest jobs, cache fill level per replica.
public protocol CacheAdminRepo: Sendable {
    /// One entry per requested layer id (`radar` or a layer id); empty inventories for layers without data.
    func cacheInventory(layers: [String], now: Date) async throws -> [CacheLayerInventory]
    /// Slots (any run status) with slot time in `[at]` when given, else older than `olderThan`; newest slot time first, then newest run.
    func cacheSlotRows(layer: String, olderThan: Date?, at: Date?, limit: Int) async throws -> [CacheSlotRow]
    /// Stored image of a published slot (newest run containing it, or the run with nominal time `run`).
    func cacheSlotBlob(layer: String, slot: Date, run: Date?) async throws -> SlotBlob?

    /// Fails running jobs that are too old, expires unclaimed ones, trims to 100 jobs / 24 hours, then creates one queued job for every
    /// layer that has none queued or running. `pending` lists the layers skipped for that reason.
    func createRefreshJobs(layers: [String], now: Date) async throws -> (created: [RefreshJob], pending: [String])
    func refreshJob(id: String) async throws -> RefreshJob?
    /// Newest first.
    func refreshJobs(limit: Int) async throws -> [RefreshJob]
    /// Distinct layers with a queued job, oldest job first.
    func queuedRefreshLayers(now: Date) async throws -> [String]
    /// Takes the oldest queued job of the layer (queued -> running); nil when another replica was faster.
    func claimRefreshJob(layer: String, now: Date) async throws -> RefreshJob?
    func finishRefreshJob(id: String, status: RefreshStatus, result: String?, error: String?, now: Date) async throws

    /// Every replica reports its in-process cache fill level with the heartbeat.
    func reportCacheFill(replicaID: String, fill: ReplicaCacheFill, now: Date) async throws
    /// Fresh replicas' reports (replica id -> fill); replicas without a report are absent.
    func replicaCacheFills(now: Date) async throws -> [String: ReplicaCacheFill]
}

extension CacheAdminRepo {
    /// One page for the dashboard: ties of the last slot time are completed so that `next` (exclusive cursor) never skips a row.
    public func cacheSlotPage(layer: String, before: Date, limit: Int) async throws -> (rows: [CacheSlotRow], next: Date?) {
        var rows = try await cacheSlotRows(layer: layer, olderThan: before, at: nil, limit: limit)
        guard rows.count == limit, let last = rows.last else { return (rows, nil) }
        let ties = try await cacheSlotRows(layer: layer, olderThan: nil, at: last.slot, limit: 500)
        for tie in ties where !rows.contains(tie) { rows.append(tie) }
        let more = try await cacheSlotRows(layer: layer, olderThan: last.slot, at: nil, limit: 1)
        rows.sort { ($0.slot, $0.run) > ($1.slot, $1.run) }
        return (rows, more.isEmpty ? nil : last.slot)
    }
}
