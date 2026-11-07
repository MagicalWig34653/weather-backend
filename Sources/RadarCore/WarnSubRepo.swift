import Foundation

/// Client-settable fields of a warning subscription (stored as `push_sub` kind 2 plus `warn_sub*`). Only warning cell ids: no
/// coordinates, no place names.
public struct WarnSubscriptionInput: Sendable, Equatable {
    public var warncellIDs: [String]
    public var types: Set<WarnKind>
    public var minSeverity: [WarnKind: Int]
    public var enabled: Bool
    public var timeSensitive: Bool
    public init(warncellIDs: [String], types: Set<WarnKind>, minSeverity: [WarnKind: Int] = [:], enabled: Bool = true, timeSensitive: Bool = false) {
        self.warncellIDs = warncellIDs; self.types = types; self.minSeverity = minSeverity; self.enabled = enabled; self.timeSensitive = timeSensitive
    }
}

public struct WarnSubscription: Sendable, Equatable {
    public var id: String
    public var installationID: String
    public var input: WarnSubscriptionInput
    public init(id: String, installationID: String, input: WarnSubscriptionInput) { self.id = id; self.installationID = installationID; self.input = input }
}

/// Last push of one warning chain to one subscription (`warn_sent`).
public struct WarnSentRecord: Sendable, Equatable {
    public var chainID: String
    public var kind: WarnKind
    public var lastSeverity: Int
    public var lastOnset: Date
    public var lastSentAt: Date
    public init(chainID: String, kind: WarnKind, lastSeverity: Int, lastOnset: Date, lastSentAt: Date) {
        self.chainID = chainID; self.kind = kind; self.lastSeverity = lastSeverity; self.lastOnset = lastOnset; self.lastSentAt = lastSentAt
    }
}

public enum WarnAddResult: Sendable, Equatable {
    case added
    case limit                    // 409 warn_limit
    case unknownCell(String)      // 409 warncell_unknown
    case unknownInstallation
}

public enum WarnUpdateResult: Sendable, Equatable { case updated, notFound, limit, unknownCell(String) }

public enum WarnLimits {
    public static let maxSubscriptionsPerInstallation = 10
    public static let maxCellsPerSubscription = 64
    public static let maxCellsPerInstallation = 128
    public static let maxBodyBytes = 4096
}

public enum WarnCellCatalog {
    /// The id check is only active once `warn_cell_known` holds at least this many ids (the DWD list has about 11 800 municipalities).
    /// An empty or partly filled table accepts every well-formed id, so a missing seed never blocks subscriptions.
    public static let minimumSeed = 10_000
}

/// One warning send decided by the service: the sent-state to store and the outbox entry.
public struct WarnSendItem: Sendable, Equatable {
    public var subID: String
    public var record: WarnSentRecord
    public var outbox: NewOutboxItem
    public init(subID: String, record: WarnSentRecord, outbox: NewOutboxItem) { self.subID = subID; self.record = record; self.outbox = outbox }
}

public protocol WarnSubRepo: Sendable {
    func addWarnSubscription(installationID: String, id: String, _ input: WarnSubscriptionInput, now: Date) async throws -> WarnAddResult
    func updateWarnSubscription(installationID: String, id: String, _ input: WarnSubscriptionInput) async throws -> WarnUpdateResult
    func deleteWarnSubscription(installationID: String, id: String) async throws -> Bool
    func warnSubscriptions(installationID: String) async throws -> [WarnSubscription]
    /// Enabled warning subscriptions that contain at least one of the cells.
    func warnSubscriptions(matching warncellIDs: [String]) async throws -> [WarnSubscription]
    func warnSent(subID: String) async throws -> [WarnSentRecord]
    /// Atomic per item: the outbox entry is inserted (duplicate `dedupeKey` ignored); the sent-state is stored only if the entry is new.
    /// Returns the number of new outbox entries.
    func commitWarnSend(_ items: [WarnSendItem], now: Date) async throws -> Int
    /// Adds ids to the known list (seed tool, tests).
    func seedKnownWarnCells(_ ids: [String]) async throws
    /// Removes sent-state older than `before` (retention, `warn_sent` rows of long expired chains).
    @discardableResult func purgeWarnSent(before: Date) async throws -> Int
}
