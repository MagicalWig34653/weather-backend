import Foundation

public struct DashboardCredential: Sendable, Equatable {
    public let credentialID: [UInt8]
    public let publicKey: [UInt8]
    public let signCount: Int
    public let createdAt: Date
    public let lastUsedAt: Date?
    public init(credentialID: [UInt8], publicKey: [UInt8], signCount: Int, createdAt: Date, lastUsedAt: Date?) {
        self.credentialID = credentialID; self.publicKey = publicKey; self.signCount = signCount
        self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
    }
}

public enum DashboardChallengeKind: String, Sendable, Equatable { case setup, login }

/// Only hashes are stored (SHA-256 of the cookie value and of the CSRF token).
public struct DashboardSessionRecord: Sendable, Equatable {
    public let idHash: [UInt8]
    public let csrfHash: [UInt8]
    public let createdAt: Date
    public let lastSeenAt: Date
    public let expiresAt: Date
    public init(idHash: [UInt8], csrfHash: [UInt8], createdAt: Date, lastSeenAt: Date, expiresAt: Date) {
        self.idHash = idHash; self.csrfHash = csrfHash; self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt; self.expiresAt = expiresAt
    }
}

/// One counter increment. `metric` matches `[a-z][a-z0-9_]{0,31}`, `label` matches `[a-z0-9_:.-]{0,48}` (fixed enumerations,
/// never free text, no identifiers). Violations throw `DashboardRepoError.invalidStat`.
public struct StatDelta: Sendable, Equatable {
    public let metric: String
    public let label: String
    public let value: Int
    public init(metric: String, label: String = "", value: Int) { self.metric = metric; self.label = label; self.value = value }
}

public struct StatRow: Sendable, Equatable {
    /// UTC midnight of the day.
    public let day: Date
    public let metric: String
    public let label: String
    public let value: Int
    public init(day: Date, metric: String, label: String, value: Int) {
        self.day = day; self.metric = metric; self.label = label; self.value = value
    }
}

/// One counter value of one UTC hour (`stats_hourly`).
public struct StatHourRow: Sendable, Equatable {
    /// Start of the UTC hour.
    public let hour: Date
    public let metric: String
    public let label: String
    public let value: Int
    public init(hour: Date, metric: String, label: String, value: Int) {
        self.hour = hour; self.metric = metric; self.label = label; self.value = value
    }
}

public struct DashboardOverride: Sendable, Equatable {
    public let key: String
    public let value: String
    public let updatedAt: Date
    /// Global revision at the time of the write (see `DashboardConfigState.revision`).
    public let revision: Int
    public init(key: String, value: String, updatedAt: Date, revision: Int) {
        self.key = key; self.value = value; self.updatedAt = updatedAt; self.revision = revision
    }
}

/// Consistent snapshot of all overrides. `revision` is a global counter, increased by every set and reset
/// (a reset of a missing key does not count): replicas poll it cheaply with `configRevision()`.
public struct DashboardConfigState: Sendable, Equatable {
    public let revision: Int
    public let overrides: [DashboardOverride]
    public init(revision: Int, overrides: [DashboardOverride]) { self.revision = revision; self.overrides = overrides }
}

public enum DashboardAuditAction: String, Sendable, Equatable, CaseIterable {
    case set, reset, restart, login, setup, resetCLI = "reset_cli"
    case devicePair = "device_pair", deviceUnpair = "device_unpair", deviceAction = "device_action", pushPause = "push_pause", cacheClear = "cache_clear"
}

public struct DashboardAuditEntry: Sendable, Equatable {
    public let id: Int
    public let at: Date
    public let action: DashboardAuditAction
    public let key: String?
    public let oldValue: String?
    public let newValue: String?
    /// First 8 hex characters of SHA-256(linking ID); device audit entries only.
    public let deviceRef: String?
    public let outcome: String?
    public init(id: Int, at: Date, action: DashboardAuditAction, key: String?, oldValue: String?, newValue: String?,
                deviceRef: String? = nil, outcome: String? = nil) {
        self.id = id; self.at = at; self.action = action; self.key = key; self.oldValue = oldValue; self.newValue = newValue
        self.deviceRef = deviceRef; self.outcome = outcome
    }
}

/// How values are written to the audit log: `.masked` stores only "geändert" as new value (no old value).
public enum ConfigAuditMode: Sendable, Equatable { case values, masked }

public struct GenerationState: Sendable, Equatable {
    public let generation: Int
    public let requestedAt: Date?
    public init(generation: Int, requestedAt: Date?) { self.generation = generation; self.requestedAt = requestedAt }
}

public struct ReplicaRecord: Sendable, Equatable {
    public let replicaID: String
    public let slot: Int?
    public let appliedGeneration: Int
    public let startedAt: Date
    public let lastSeenAt: Date
    public init(replicaID: String, slot: Int?, appliedGeneration: Int, startedAt: Date, lastSeenAt: Date) {
        self.replicaID = replicaID; self.slot = slot; self.appliedGeneration = appliedGeneration
        self.startedAt = startedAt; self.lastSeenAt = lastSeenAt
    }
}

public struct DashboardPurgeResult: Sendable, Equatable {
    public var sessions = 0, challenges = 0, stats = 0, statsHourly = 0, audit = 0, replicas = 0
    public init() {}
}

public enum DashboardRepoError: Error, Equatable { case invalidStat }

public enum DashboardRetention {
    public static let statsDays = 30
    /// Hourly counters (`stats_hourly`) are kept for this many hours.
    public static let statsHourlyHours = 72
    public static let auditDays = 365
    /// Replica rows older than this are ignored and deleted.
    public static let replicaStale: TimeInterval = 600
    public static let maxValueLength = 600
    public static let auditValueLength = 200
}

/// Operator dashboard storage: passkey credential, one-time challenges, sessions, daily statistics, configuration overrides,
/// audit log, restart generation and replica heartbeats. Times are passed in by the caller (UTC, second resolution).
/// No personal data is stored (no IPs, coordinates, installation IDs or tokens); statistics carry fixed labels only.
public protocol DashboardRepo: Sendable {
    // MARK: credential (exactly one row)
    /// Atomic: inserts the single credential only when none exists. False when one exists (two parallel inserts: one wins).
    func insertCredential(credentialID: [UInt8], publicKey: [UInt8], signCount: Int, now: Date) async throws -> Bool
    func credential() async throws -> DashboardCredential?
    /// Stores the new signature counter and `last_used_at`; false when `credentialID` does not match the stored credential.
    func updateCredentialUse(credentialID: [UInt8], signCount: Int, now: Date) async throws -> Bool
    /// `dashboard-reset`: deletes the credential and all sessions and challenges. True when a credential existed.
    @discardableResult func resetCredential() async throws -> Bool

    // MARK: challenges (one-time)
    func putChallenge(id: [UInt8], kind: DashboardChallengeKind, challenge: [UInt8], expiresAt: Date, now: Date) async throws
    /// Atomic one-time use: returns the challenge and deletes it; nil when unknown, other kind, used or expired (expired rows are removed).
    func consumeChallenge(id: [UInt8], kind: DashboardChallengeKind, now: Date) async throws -> [UInt8]?

    // MARK: sessions
    func createSession(idHash: [UInt8], csrfHash: [UInt8], now: Date, expiresAt: Date) async throws
    /// nil when unknown or expired (an expired row is deleted).
    func session(idHash: [UInt8], now: Date) async throws -> DashboardSessionRecord?
    /// Sets `last_seen_at`, and `expires_at` when given; false when the session does not exist or is expired.
    @discardableResult func touchSession(idHash: [UInt8], now: Date, expiresAt: Date?) async throws -> Bool
    @discardableResult func deleteSession(idHash: [UInt8]) async throws -> Bool

    // MARK: statistics
    /// Adds the deltas to the counters of the UTC day of `day` (one transaction, additive, zero values skipped).
    func addStats(day: Date, _ deltas: [StatDelta]) async throws
    /// Rows with day in [from, to] (UTC days), ordered by day, metric, label.
    func stats(from: Date, to: Date) async throws -> [StatRow]
    /// Deletes days older than `statsDays` before the UTC day of `now`; returns the number of deleted rows.
    func purgeStats(now: Date) async throws -> Int
    /// Adds the deltas to the counters of the UTC hour of `hour` (minutes truncated; same rules as `addStats`).
    func addStatsHourly(hour: Date, _ deltas: [StatDelta]) async throws
    /// Rows with hour in [from, to] (UTC hours, both truncated), ordered by hour, metric, label.
    func statsHourly(from: Date, to: Date) async throws -> [StatHourRow]
    /// Deletes hours older than `statsHourlyHours` before the UTC hour of `now`; returns the number of deleted rows.
    func purgeStatsHourly(now: Date) async throws -> Int

    // MARK: configuration overrides and audit
    func configState() async throws -> DashboardConfigState
    /// Cheap poll of the global revision.
    func configRevision() async throws -> Int
    /// Upsert plus audit entry (`set`) in one transaction; returns the new global revision.
    /// The register validates the value (max 600 characters); the repo truncates only the audit text (200 characters).
    func setConfigOverride(key: String, value: String, audit: ConfigAuditMode, now: Date) async throws -> Int
    /// Deletes the override plus audit entry (`reset`) in one transaction; nil when there was none (no audit, no revision change).
    func resetConfigOverride(key: String, audit: ConfigAuditMode, now: Date) async throws -> Int?
    func appendAudit(action: DashboardAuditAction, key: String?, oldValue: String?, newValue: String?, now: Date) async throws
    /// Audit entry of a device or global action (`deviceRef` may be nil for global actions such as `push_pause`).
    func appendDeviceAudit(action: DashboardAuditAction, deviceRef: String?, outcome: String?, now: Date) async throws
    /// Newest first.
    func auditEntries(limit: Int) async throws -> [DashboardAuditEntry]
    func purgeAudit(now: Date) async throws -> Int

    // MARK: restart generation and replicas
    func generation() async throws -> GenerationState
    /// Atomic: increases the generation by one unless the last request is younger than `minInterval` (then nil).
    /// Writes an audit entry (`restart`, old/new generation) in the same transaction. Returns the new generation.
    func requestRestart(minInterval: TimeInterval, now: Date) async throws -> Int?
    /// Upsert of this replica; `started_at` is set on first insert only.
    func heartbeat(replicaID: String, slot: Int?, appliedGeneration: Int, now: Date) async throws
    /// Replicas seen within `DashboardRetention.replicaStale`, ascending by slot (nil last), then id.
    func replicas(now: Date) async throws -> [ReplicaRecord]
    func removeReplica(replicaID: String) async throws

    // MARK: retention
    /// Expired sessions and challenges, stats > 30 days, audit > 365 days, stale replicas. Idempotent.
    func purgeDashboard(now: Date) async throws -> DashboardPurgeResult
}

enum DashboardValidation {
    /// Reference shown in the audit log: first 8 hex characters of SHA-256(linking ID).
    static func deviceRef(_ deviceID: String) -> String { String(Hashing.sha256Hex(Array(deviceID.utf8)).prefix(8)) }

    static func isValid(_ delta: StatDelta) -> Bool {
        guard delta.value >= 0, (1...32).contains(delta.metric.utf8.count), delta.label.utf8.count <= 48 else { return false }
        let metric = Array(delta.metric.utf8)
        guard let first = metric.first, (97...122).contains(first) else { return false }
        for b in metric where !((97...122).contains(b) || (48...57).contains(b) || b == 95) { return false }
        for b in delta.label.utf8 where !((97...122).contains(b) || (48...57).contains(b) || b == 95 || b == 58 || b == 46 || b == 45) { return false }
        return true
    }

    static func clip(_ text: String?, to length: Int = DashboardRetention.auditValueLength) -> String? {
        text.map { String($0.prefix(length)) }
    }

    /// Audit text for a value, honouring the mode.
    static func auditValues(old: String?, new: String?, mode: ConfigAuditMode) -> (old: String?, new: String?) {
        switch mode {
        case .values: return (clip(old), clip(new))
        case .masked: return (nil, new == nil ? nil : "geändert")
        }
    }

    static func day(_ date: Date) -> String { String(TimeUtil.toSQL(date).prefix(10)) }
    static func date(day: String) -> Date { TimeUtil.fromSQL(day + " 00:00:00") ?? Date(timeIntervalSince1970: 0) }
    static func statsCutoffDay(now: Date) -> String {
        day(now.addingTimeInterval(-Double(DashboardRetention.statsDays) * 86400))
    }
    /// `yyyy-MM-dd HH` of the UTC hour.
    static func hour(_ date: Date) -> String { String(TimeUtil.toSQL(date).prefix(13)) }
    static func date(hour: String) -> Date { TimeUtil.fromSQL(hour + ":00:00") ?? Date(timeIntervalSince1970: 0) }
    static func hourStart(_ date: Date) -> Date { self.date(hour: hour(date)) }
    static func statsHourlyCutoff(now: Date) -> Date {
        hourStart(now).addingTimeInterval(-Double(DashboardRetention.statsHourlyHours) * 3600)
    }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []; var it = hex.utf8.makeIterator()
        func v(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : c >= 65 ? c - 55 : c - 48 }
        while let a = it.next(), let b = it.next() { out.append(v(a) << 4 | v(b)) }
        return out
    }
}
