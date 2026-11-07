import Foundation

public struct WarnIngestResult: Sendable, Equatable {
    public var fetched = 0, stored = 0, cancelled = 0, ignored = 0, rejected = 0
    public var failed = false
    /// New or changed active messages (German and English separately; `WarnAlert.alertKey` groups the pair). Input for the push evaluation (W2).
    public var newOrChanged: [WarnStoredAlert] = []
    public init() {}
}

/// Leader-only DWD CAP ingest (leader lease `warn`). One tick = one DIFF request per language (every minute) or, every 15 minutes
/// and after a gap, the full STAT feed. Conditional requests (ETag), exponential backoff on errors, only German and English.
/// The tick cadence is the caller's (60 s). Stores no coordinates and no place names.
public final class WarnIngestor: Sendable {
    public static let leaderName = "warn"
    public static let leaseSeconds = 180
    public static let statInterval: TimeInterval = 900
    public static let diffGap: TimeInterval = 90
    public static let backoffSeconds: [TimeInterval] = [60, 120, 300]
    public static let retention: TimeInterval = 24 * 3600
    public static let purgeInterval: TimeInterval = 3600
    static let languages = ["de", "en"]
    static let maxSeen = 50_000

    private struct State {
        var etags: [String: String] = [:]
        var lastStatAt: Date?
        var lastDiffAt: Date?
        var retryAt: Date?
        var failures = 0
        var lastPurge = Date.distantPast
        var seen: [String: Int] = [:]
    }

    let repo: any Repo
    let source: any WarnFeedSource
    let owner: String
    let stats: any StatsSink
    let clock: @Sendable () -> Date
    private let state = PushGuarded(State())

    public init(repo: any Repo, source: any WarnFeedSource, owner: String, stats: any StatsSink = NoStatsSink(),
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.repo = repo; self.source = source; self.owner = owner; self.stats = stats; self.clock = clock
    }

    public func release() async {
        try? await repo.releaseLeader(name: Self.leaderName, owner: owner)
        state.withLock { $0 = State() }
    }

    public func tick() async throws -> WarnIngestResult {
        let now = clock()
        var result = WarnIngestResult()
        guard try await repo.acquireLeader(name: Self.leaderName, owner: owner, leaseSeconds: Self.leaseSeconds) else {
            state.withLock { $0 = State() }   // after a lease change the next leader term starts with a full STAT
            return result
        }
        let snapshot = state.withLock { $0 }
        if let retry = snapshot.retryAt, now < retry { return result }
        let needStat = snapshot.lastStatAt.map { now.timeIntervalSince($0) >= Self.statInterval } ?? true
            || snapshot.lastDiffAt.map { now.timeIntervalSince($0) > Self.diffGap } ?? true
        let feed: WarnFeed = needStat ? .stat : .diff
        var failed = false
        var alerts: [WarnAlert] = []
        var newTags: [String: String] = [:]
        for lang in Self.languages {
            let tagKey = "\(needStat ? "stat" : "diff"):\(lang)"
            do {
                switch try await source.fetch(feed: feed, lang: lang, ifNoneMatch: snapshot.etags[tagKey]) {
                case .notModified: continue
                case let .xmlFiles(files, etag):
                    result.fetched += files.count
                    for file in files {
                        let parsed = WarnCAPParser.parse(xml: file)
                        alerts += parsed.alerts
                        result.rejected += parsed.rejected
                        result.ignored += parsed.ignoredEvents.values.reduce(0, +)
                    }
                    if let etag { newTags[tagKey] = etag }
                }
            } catch {
                failed = true
                stats.record("warn_ingest", label: "fetch_error")
            }
        }
        // Oldest first: an update always meets the message it replaces.
        alerts.sort { ($0.sent, $0.identifier) < ($1.sent, $1.identifier) }
        for alert in alerts {
            do { try await store(alert, now: now, into: &result) } catch { failed = true; stats.record("warn_ingest", label: "store_error") }
        }
        if failed {
            result.failed = true
            state.withLock { s in
                s.failures += 1
                s.retryAt = now.addingTimeInterval(Self.backoffSeconds[min(s.failures, Self.backoffSeconds.count) - 1])
            }
            return result
        }
        state.withLock { s in
            s.failures = 0; s.retryAt = nil; s.lastDiffAt = now
            if needStat { s.lastStatAt = now }
            for (k, v) in newTags { s.etags[k] = v }
        }
        try await repo.setWarnFetchedAt(now)
        let doPurge = state.withLock { s -> Bool in
            guard now.timeIntervalSince(s.lastPurge) >= Self.purgeInterval else { return false }
            s.lastPurge = now; return true
        }
        if doPurge { _ = try? await repo.purgeWarnings(now: now, retention: Self.retention) }
        stats.record("warn_ingest", label: "stored", by: result.stored)
        stats.record("warn_ingest", label: "cancelled", by: result.cancelled)
        stats.record("warn_ingest", label: "ignored", by: result.ignored)
        stats.record("warn_ingest", label: "rejected", by: result.rejected)
        return result
    }

    private func store(_ alert: WarnAlert, now: Date, into result: inout WarnIngestResult) async throws {
        if alert.msgType == .cancel {
            try await repo.cancelAlerts(identifiers: alert.references, now: now)
            result.cancelled += 1
            return
        }
        guard alert.expires > now else { return }
        let key = alert.lang + "|" + alert.identifier
        let print = Self.fingerprint(alert)
        if state.withLock({ $0.seen[key] }) == print { return }
        if let existing = try await repo.alert(identifier: alert.identifier), existing.alert.lang == alert.lang,
           Self.sameContent(existing.alert, alert.clippedForStorage()) {
            remember(key, print)
            return
        }
        let stored = try await repo.upsertAlert(alert, now: now)
        remember(key, print)
        result.stored += 1
        if stored.status == "active" { result.newOrChanged.append(stored) }
    }

    private func remember(_ key: String, _ print: Int) {
        state.withLock { s in
            if s.seen.count >= Self.maxSeen { s.seen.removeAll() }
            s.seen[key] = print
        }
    }

    static func fingerprint(_ a: WarnAlert) -> Int {
        var h = Hasher()
        h.combine(a.kind); h.combine(a.severity); h.combine(a.event); h.combine(a.sent); h.combine(a.onset); h.combine(a.expires)
        h.combine(a.headline); h.combine(a.text); h.combine(a.instruction); h.combine(a.warncellIDs.sorted())
        return h.finalize()
    }

    static func sameContent(_ a: WarnAlert, _ b: WarnAlert) -> Bool {
        var x = a, y = b
        x.msgType = .alert; y.msgType = .alert; x.references = []; y.references = []
        x.warncellIDs.sort(); y.warncellIDs.sort()
        return x == y
    }
}
