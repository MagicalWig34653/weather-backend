import Foundation

/// In-memory dashboard storage with the same semantics as the MariaDB tables (state lives inside `MemoryRepo`).
struct MemoryDashboardStore {
    struct Challenge { var kind: DashboardChallengeKind; var challenge: [UInt8]; var expiresAt: Date }
    var credential: DashboardCredential?
    var challenges: [[UInt8]: Challenge] = [:]
    var sessions: [[UInt8]: DashboardSessionRecord] = [:]
    /// Keyed by "day|metric|label".
    var stats: [String: StatRow] = [:]
    var statsHourly: [String: StatHourRow] = [:]
    var overrides: [String: DashboardOverride] = [:]
    var configRevision = 0
    var audit: [DashboardAuditEntry] = []
    var nextAuditID = 1
    var generation = 0
    var requestedAt: Date?
    var replicas: [String: ReplicaRecord] = [:]

    mutating func appendAudit(_ action: DashboardAuditAction, key: String?, old: String?, new: String?, now: Date,
                              deviceRef: String? = nil, outcome: String? = nil) {
        audit.append(DashboardAuditEntry(id: nextAuditID, at: now, action: action, key: key,
                                      oldValue: DashboardValidation.clip(old), newValue: DashboardValidation.clip(new),
                                      deviceRef: deviceRef, outcome: DashboardValidation.clip(outcome, to: 32)))
        nextAuditID += 1
    }
}

extension MemoryRepo: DashboardRepo {
    public func insertCredential(credentialID: [UInt8], publicKey: [UInt8], signCount: Int, now: Date) async throws -> Bool {
        guard dashboard.credential == nil else { return false }
        dashboard.credential = DashboardCredential(credentialID: credentialID, publicKey: publicKey, signCount: signCount, createdAt: now, lastUsedAt: nil)
        return true
    }

    public func credential() async throws -> DashboardCredential? { dashboard.credential }

    public func updateCredentialUse(credentialID: [UInt8], signCount: Int, now: Date) async throws -> Bool {
        guard let current = dashboard.credential, current.credentialID == credentialID else { return false }
        dashboard.credential = DashboardCredential(credentialID: current.credentialID, publicKey: current.publicKey, signCount: signCount,
                                                   createdAt: current.createdAt, lastUsedAt: now)
        return true
    }

    public func resetCredential() async throws -> Bool {
        dashboard.sessions = [:]
        dashboard.challenges = [:]
        defer { dashboard.credential = nil }
        return dashboard.credential != nil
    }

    public func putChallenge(id: [UInt8], kind: DashboardChallengeKind, challenge: [UInt8], expiresAt: Date, now: Date) async throws {
        dashboard.challenges = dashboard.challenges.filter { $0.value.expiresAt > now }
        dashboard.challenges[id] = .init(kind: kind, challenge: challenge, expiresAt: expiresAt)
    }

    public func consumeChallenge(id: [UInt8], kind: DashboardChallengeKind, now: Date) async throws -> [UInt8]? {
        guard let entry = dashboard.challenges[id], entry.kind == kind else { return nil }
        dashboard.challenges[id] = nil
        return entry.expiresAt > now ? entry.challenge : nil
    }

    public func createSession(idHash: [UInt8], csrfHash: [UInt8], now: Date, expiresAt: Date) async throws {
        dashboard.sessions = dashboard.sessions.filter { $0.value.expiresAt > now }
        dashboard.sessions[idHash] = DashboardSessionRecord(idHash: idHash, csrfHash: csrfHash, createdAt: now, lastSeenAt: now, expiresAt: expiresAt)
    }

    public func session(idHash: [UInt8], now: Date) async throws -> DashboardSessionRecord? {
        guard let record = dashboard.sessions[idHash] else { return nil }
        if record.expiresAt <= now { dashboard.sessions[idHash] = nil; return nil }
        return record
    }

    public func touchSession(idHash: [UInt8], now: Date, expiresAt: Date?) async throws -> Bool {
        guard let record = dashboard.sessions[idHash], record.expiresAt > now else { return false }
        dashboard.sessions[idHash] = DashboardSessionRecord(idHash: idHash, csrfHash: record.csrfHash, createdAt: record.createdAt,
                                                            lastSeenAt: now, expiresAt: expiresAt ?? record.expiresAt)
        return true
    }

    public func deleteSession(idHash: [UInt8]) async throws -> Bool { dashboard.sessions.removeValue(forKey: idHash) != nil }

    public func addStats(day: Date, _ deltas: [StatDelta]) async throws {
        guard deltas.allSatisfy(DashboardValidation.isValid) else { throw DashboardRepoError.invalidStat }
        let dayText = DashboardValidation.day(day)
        for delta in deltas where delta.value > 0 {
            let key = "\(dayText)|\(delta.metric)|\(delta.label)"
            let current = dashboard.stats[key]?.value ?? 0
            dashboard.stats[key] = StatRow(day: DashboardValidation.date(day: dayText), metric: delta.metric, label: delta.label, value: current + delta.value)
        }
    }

    public func stats(from: Date, to: Date) async throws -> [StatRow] {
        let lower = DashboardValidation.date(day: DashboardValidation.day(from)), upper = DashboardValidation.date(day: DashboardValidation.day(to))
        return dashboard.stats.values.filter { $0.day >= lower && $0.day <= upper }
            .sorted { ($0.day, $0.metric, $0.label) < ($1.day, $1.metric, $1.label) }
    }

    public func purgeStats(now: Date) async throws -> Int {
        let cutoff = DashboardValidation.date(day: DashboardValidation.statsCutoffDay(now: now))
        let doomed = dashboard.stats.filter { $0.value.day < cutoff }.map(\.key)
        for key in doomed { dashboard.stats[key] = nil }
        return doomed.count
    }

    public func addStatsHourly(hour: Date, _ deltas: [StatDelta]) async throws {
        guard deltas.allSatisfy(DashboardValidation.isValid) else { throw DashboardRepoError.invalidStat }
        let start = DashboardValidation.hourStart(hour)
        for delta in deltas where delta.value > 0 {
            let key = "\(DashboardValidation.hour(start))|\(delta.metric)|\(delta.label)"
            let current = dashboard.statsHourly[key]?.value ?? 0
            dashboard.statsHourly[key] = StatHourRow(hour: start, metric: delta.metric, label: delta.label, value: current + delta.value)
        }
    }

    public func statsHourly(from: Date, to: Date) async throws -> [StatHourRow] {
        let lower = DashboardValidation.hourStart(from), upper = DashboardValidation.hourStart(to)
        return dashboard.statsHourly.values.filter { $0.hour >= lower && $0.hour <= upper }
            .sorted { ($0.hour, $0.metric, $0.label) < ($1.hour, $1.metric, $1.label) }
    }

    public func purgeStatsHourly(now: Date) async throws -> Int {
        let cutoff = DashboardValidation.statsHourlyCutoff(now: now)
        let doomed = dashboard.statsHourly.filter { $0.value.hour < cutoff }.map(\.key)
        for key in doomed { dashboard.statsHourly[key] = nil }
        return doomed.count
    }

    public func configState() async throws -> DashboardConfigState {
        DashboardConfigState(revision: dashboard.configRevision, overrides: dashboard.overrides.values.sorted { $0.key < $1.key })
    }

    public func configRevision() async throws -> Int { dashboard.configRevision }

    public func setConfigOverride(key: String, value: String, audit mode: ConfigAuditMode, now: Date) async throws -> Int {
        dashboard.configRevision += 1
        let old = dashboard.overrides[key]?.value
        dashboard.overrides[key] = DashboardOverride(key: key, value: value, updatedAt: now, revision: dashboard.configRevision)
        let texts = DashboardValidation.auditValues(old: old, new: value, mode: mode)
        dashboard.appendAudit(.set, key: key, old: texts.old, new: texts.new, now: now)
        return dashboard.configRevision
    }

    public func resetConfigOverride(key: String, audit mode: ConfigAuditMode, now: Date) async throws -> Int? {
        guard let old = dashboard.overrides.removeValue(forKey: key)?.value else { return nil }
        dashboard.configRevision += 1
        let texts = DashboardValidation.auditValues(old: old, new: nil, mode: mode)
        dashboard.appendAudit(.reset, key: key, old: texts.old, new: texts.new, now: now)
        return dashboard.configRevision
    }

    public func appendAudit(action: DashboardAuditAction, key: String?, oldValue: String?, newValue: String?, now: Date) async throws {
        dashboard.appendAudit(action, key: key, old: oldValue, new: newValue, now: now)
    }

    public func appendDeviceAudit(action: DashboardAuditAction, deviceRef: String?, outcome: String?, now: Date) async throws {
        dashboard.appendAudit(action, key: nil, old: nil, new: nil, now: now, deviceRef: deviceRef, outcome: outcome)
    }

    public func auditEntries(limit: Int) async throws -> [DashboardAuditEntry] {
        Array(dashboard.audit.reversed().prefix(max(0, limit)))
    }

    public func purgeAudit(now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(DashboardRetention.auditDays) * 86400)
        let before = dashboard.audit.count
        dashboard.audit.removeAll { $0.at < cutoff }
        return before - dashboard.audit.count
    }

    public func generation() async throws -> GenerationState {
        GenerationState(generation: dashboard.generation, requestedAt: dashboard.requestedAt)
    }

    public func requestRestart(minInterval: TimeInterval, now: Date) async throws -> Int? {
        if let last = dashboard.requestedAt, last > now.addingTimeInterval(-minInterval) { return nil }
        dashboard.generation += 1
        dashboard.requestedAt = now
        dashboard.appendAudit(.restart, key: nil, old: String(dashboard.generation - 1), new: String(dashboard.generation), now: now)
        return dashboard.generation
    }

    public func heartbeat(replicaID: String, slot: Int?, appliedGeneration: Int, now: Date) async throws {
        let started = dashboard.replicas[replicaID]?.startedAt ?? now
        dashboard.replicas[replicaID] = ReplicaRecord(replicaID: replicaID, slot: slot, appliedGeneration: appliedGeneration, startedAt: started, lastSeenAt: now)
    }

    public func replicas(now: Date) async throws -> [ReplicaRecord] {
        let cutoff = now.addingTimeInterval(-DashboardRetention.replicaStale)
        return dashboard.replicas.values.filter { $0.lastSeenAt > cutoff }.sorted {
            ($0.slot ?? Int.max, $0.replicaID) < ($1.slot ?? Int.max, $1.replicaID)
        }
    }

    public func removeReplica(replicaID: String) async throws { dashboard.replicas[replicaID] = nil }

    public func purgeDashboard(now: Date) async throws -> DashboardPurgeResult {
        var result = DashboardPurgeResult()
        let sessions = dashboard.sessions.filter { $0.value.expiresAt <= now }.map(\.key)
        for key in sessions { dashboard.sessions[key] = nil }
        result.sessions = sessions.count
        let challenges = dashboard.challenges.filter { $0.value.expiresAt <= now }.map(\.key)
        for key in challenges { dashboard.challenges[key] = nil }
        result.challenges = challenges.count
        let stale = dashboard.replicas.filter { $0.value.lastSeenAt <= now.addingTimeInterval(-DashboardRetention.replicaStale) }.map(\.key)
        for key in stale { dashboard.replicas[key] = nil }
        result.replicas = stale.count
        result.stats = try await purgeStats(now: now)
        result.statsHourly = try await purgeStatsHourly(now: now)
        result.audit = try await purgeAudit(now: now)
        return result
    }
}
