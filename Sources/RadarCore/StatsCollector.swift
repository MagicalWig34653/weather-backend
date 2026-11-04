import Foundation

/// Receiver of statistic events. Implementations must be cheap and thread-safe; the default does nothing.
/// Callers pass only fixed enumeration values (see `StatsCollector.labelRules`); unknown labels become `other`.
public protocol StatsSink: Sendable {
    func record(_ metric: String, label: String, by value: Int)
}

public extension StatsSink {
    func record(_ metric: String, label: String = "") { record(metric, label: label, by: 1) }
}

/// Default sink: existing initialisers and tests keep working without statistics.
public struct NoStatsSink: StatsSink {
    public init() {}
    public func record(_ metric: String, label: String, by value: Int) {}
}

/// Maps request paths to a fixed list of route groups. Never returns anything derived from the path itself
/// (no ids, run ids, tokens): the result is always one of `groups`.
public enum StatsRoute {
    public static let groups: [String] = [
        "healthz", "status", "radar_latest", "radar_history", "radar_image", "layer_manifest", "layer_image",
        "push", "landing", "asset", "site_page", "dash_api", "dash_static", "other",
    ]
    /// Fixed page names of `page_view` (no referrer, no user agent).
    public static let pages = ["landing_de", "landing_en", "privacy", "marketing", "support"]

    /// Route group of a path (query string ignored). Pure string checks, no allocation for the common cases.
    public static func group(path rawPath: String) -> String {
        var path = Substring(rawPath)
        if let q = path.firstIndex(of: "?") { path = path[..<q] }
        switch path {
        case "/healthz": return "healthz"
        case "/v1/status": return "status"
        case "/", "/en": return "landing"
        case "/datenschutz", "/marketing", "/support": return "site_page"
        case "/v1/radar/latest.json": return "radar_latest"
        case "/v1/radar/history.json": return "radar_history"
        default: break
        }
        if path.hasPrefix("/v1/radar/") { return path.hasSuffix(".webp") ? "radar_image" : "other" }
        if path.hasPrefix("/v1/layers/") {
            if path.hasSuffix(".webp") { return "layer_image" }
            return path.hasSuffix("/latest.json") ? "layer_manifest" : "other"
        }
        if path.hasPrefix("/v1/push/") { return "push" }
        if path.hasPrefix("/assets/") { return "asset" }
        if path == "/dash/api" || path.hasPrefix("/dash/api/") { return "dash_api" }
        if path == "/dash" || path.hasPrefix("/dash/") { return "dash_static" }
        return "other"
    }

    /// Page name for `page_view`, nil when the path is no page.
    public static func page(path rawPath: String) -> String? {
        var path = Substring(rawPath)
        if let q = path.firstIndex(of: "?") { path = path[..<q] }
        switch path {
        case "/": return "landing_de"
        case "/en": return "landing_en"
        case "/datenschutz": return "privacy"
        case "/marketing": return "marketing"
        case "/support": return "support"
        default: return nil
        }
    }

    static func statusClass(_ status: Int) -> String {
        switch status {
        case 304: return "304"
        case 200..<300: return "2xx"
        case 300..<400: return "3xx"
        case 400..<500: return "4xx"
        case 500..<600: return "5xx"
        default: return "other"
        }
    }

    static let statusClasses = ["2xx", "304", "3xx", "4xx", "5xx", "other"]
    /// Precomputed `group:class` labels: no string building per request.
    static let requestLabels: [String: [String: String]] = Dictionary(uniqueKeysWithValues: groups.map { g in
        (g, Dictionary(uniqueKeysWithValues: statusClasses.map { ($0, g + ":" + $0) }))
    })
}

/// Thread-safe in-process counters with a bounded key table, flushed additively into `stats_daily`.
///
/// Privacy: only fixed metric names and labels are stored (see `labelRules`); there is no way to put free text, IPs,
/// coordinates, installation or subscription ids, tokens, user agents or host names into a counter, because every label is
/// matched against a fixed set and replaced by `other` otherwise.
public final class StatsCollector: StatsSink, @unchecked Sendable {
    public enum LabelRule: Sendable {
        case fixed(Set<String>)
        /// `<group>:<status class>` with a group of `StatsRoute.groups` (e.g. `radar_image:2xx`).
        case requestLabel
        /// Any of the route groups.
        case routeGroup
        /// `<layer>:<result>`.
        case ingestLabel
    }

    public static let ingestResults: Set<String> = ["ok", "error", "missed"]

    /// Allowed metrics with their fixed label sets.
    public static var labelRules: [String: LabelRule] {
        return [
            "requests": .requestLabel,
            "bytes_out": .routeGroup,
            "errors_5xx": .routeGroup,
            "cache_hit": .fixed(["radar:memory", "radar:negative", "radar:joined", "layer:memory", "layer:negative", "layer:joined"]),
            "cache_miss": .fixed(["radar:db", "layer:db"]),
            "ingest_run": .ingestLabel,
            "push_sent": .fixed(["delivered"]),
            "push_failed": .fixed(["unregistered", "rejected", "retry", "dropped"]),
            "rate_limited": .fixed(["push", "dashboard", "other"]),
            "page_view": .fixed(Set(StatsRoute.pages)),
            "stats_dropped": .fixed([""]),
        ]
    }

    private struct Key: Hashable { let metric: String; let label: String }

    private let lock = NSLock()
    private var current: [Key: Int] = [:]
    /// Batches of failed flushes with the UTC day they belong to.
    private var carry: [String: [Key: Int]] = [:]
    /// Write side of the repo as two closures (lets tests inject failures without a full `DashboardRepo` double).
    struct Writer: Sendable {
        let addStats: @Sendable (Date, [StatDelta]) async throws -> Void
        let purge: @Sendable (Date) async throws -> Void
        init(addStats: @escaping @Sendable (Date, [StatDelta]) async throws -> Void, purge: @escaping @Sendable (Date) async throws -> Void) {
            self.addStats = addStats; self.purge = purge
        }
        init(_ repo: any DashboardRepo) {
            addStats = { try await repo.addStats(day: $0, $1) }
            purge = { _ = try await repo.purgeDashboard(now: $0) }
        }
    }
    private var repo: Writer?
    private let clock: @Sendable () -> Date
    private let maxKeys: Int
    private let rules: [String: LabelRule]
    private let ingestLayers: Set<String>
    private var lastPurgeDay: String?
    private let interval: TimeInterval
    private let jitter: TimeInterval

    public static let defaultMaxKeys = 10_000

    public convenience init(repo: (any DashboardRepo)? = nil, maxKeys: Int = StatsCollector.defaultMaxKeys, interval: TimeInterval = 60,
                            jitter: TimeInterval = 5, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(writer: repo.map(Writer.init), maxKeys: maxKeys, interval: interval, jitter: jitter, clock: clock)
    }

    init(writer: Writer?, maxKeys: Int = StatsCollector.defaultMaxKeys, interval: TimeInterval = 60, jitter: TimeInterval = 5,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repo = writer; self.maxKeys = max(10, maxKeys); self.clock = clock; self.interval = max(0.01, interval); self.jitter = max(0, jitter)
        rules = Self.labelRules
        ingestLayers = Set(["radar"] + LayerCatalog.order)
    }

    /// Late binding of the database (the collector is a no-op for flushing until a repo is set; counters stay bounded).
    public func setRepo(_ repo: (any DashboardRepo)?) { lock.withLock { self.repo = repo.map(Writer.init) } }

    // MARK: recording

    func normalized(metric: String, label: String) -> String? {
        guard let rule = rules[metric] else { return nil }
        switch rule {
        case .fixed(let set): return set.contains(label) ? label : (set.contains("") ? "" : "other")
        case .requestLabel:
            if let colon = label.firstIndex(of: ":"), let byClass = StatsRoute.requestLabels[String(label[..<colon])],
               let full = byClass[String(label[label.index(after: colon)...])] { return full }
            return "other:other"
        case .routeGroup: return StatsRoute.requestLabels[label] != nil ? label : "other"
        case .ingestLabel:
            if let colon = label.firstIndex(of: ":"), ingestLayers.contains(String(label[..<colon])),
               Self.ingestResults.contains(String(label[label.index(after: colon)...])) { return label }
            return "other:error"
        }
    }

    /// Unknown metrics are ignored, unknown labels become `other`; negative values are ignored.
    public func record(_ metric: String, label: String, by value: Int) {
        guard value > 0, let label = normalized(metric: metric, label: label) else { return }
        lock.withLock { add(Key(metric: metric, label: label), value) }
    }

    /// Caller holds the lock.
    private func add(_ key: Key, _ value: Int) {
        if let existing = current[key] { current[key] = existing &+ value; return }
        let stored = current.count + carry.values.reduce(0) { $0 + $1.count }
        guard stored < maxKeys else {
            // Table full: drop the new combination and count the loss (the key exists or is created from the reserve).
            current[Key(metric: "stats_dropped", label: ""), default: 0] += value
            return
        }
        current[key] = value
    }

    /// One finished request. Derives `requests`, `bytes_out`, `errors_5xx`, `rate_limited` (429) and `page_view` from the
    /// route group and status. `path` is only classified, never stored.
    public func recordRequest(path: String, status: Int, bytes: Int) {
        let group = StatsRoute.group(path: path)
        let cls = StatsRoute.statusClass(status)
        let label = StatsRoute.requestLabels[group]![cls]!
        let page = status == 200 ? StatsRoute.page(path: path) : nil
        lock.withLock {
            add(Key(metric: "requests", label: label), 1)
            if bytes > 0 { add(Key(metric: "bytes_out", label: group), bytes) }
            if status >= 500 && status < 600 { add(Key(metric: "errors_5xx", label: group), 1) }
            if status == 429 { add(Key(metric: "rate_limited", label: group == "push" ? "push" : (group.hasPrefix("dash") ? "dashboard" : "other")), 1) }
            if let page { add(Key(metric: "page_view", label: page), 1) }
        }
    }

    /// Snapshot for tests and diagnostics (not yet flushed values).
    public func pending() -> [StatDelta] {
        lock.withLock {
            (current.map { StatDelta(metric: $0.key.metric, label: $0.key.label, value: $0.value) }
                + carry.values.flatMap { $0.map { StatDelta(metric: $0.key.metric, label: $0.key.label, value: $0.value) } })
                .sorted { ($0.metric, $0.label) < ($1.metric, $1.label) }
        }
    }

    public var keyCount: Int { lock.withLock { current.count + carry.values.reduce(0) { $0 + $1.count } } }

    // MARK: flushing

    static func utcDay(_ date: Date) -> String { DashboardValidation.day(date) }

    /// Writes the counters additively into the database. A failing write keeps the counters (they go into the next attempt).
    /// Returns true when nothing is left to write. Safe to call concurrently: each call takes its own batch.
    @discardableResult
    public func flush() async -> Bool {
        let (writer, batches): (Writer?, [String: [Key: Int]]) = lock.withLock {
            guard let target = self.repo else { return (nil, [:]) }
            var all = carry
            carry = [:]
            if !current.isEmpty { all[Self.utcDay(clock()), default: [:]].merge(current, uniquingKeysWith: +); current = [:] }
            return (target, all)
        }
        guard let writer else { return true }
        var failed: [String: [Key: Int]] = [:]
        for (day, counters) in batches {
            let deltas = counters.map { StatDelta(metric: $0.key.metric, label: $0.key.label, value: $0.value) }
            do { try await writer.addStats(DashboardValidation.date(day: day), deltas) } catch { failed[day] = counters }
        }
        if failed.isEmpty { return true }
        lock.withLock {
            // Put back, bounded: surplus combinations are dropped and counted.
            var dropped = 0
            for (day, counters) in failed {
                for (key, value) in counters {
                    let stored = current.count + carry.values.reduce(0) { $0 + $1.count }
                    if stored >= maxKeys { dropped += value; continue }
                    carry[day, default: [:]][key, default: 0] += value
                }
            }
            if dropped > 0 { current[Key(metric: "stats_dropped", label: ""), default: 0] += dropped }
        }
        return false
    }

    /// Retention: runs `purgeDashboard` at most once per UTC day and process (idempotent, safe on every replica).
    @discardableResult
    public func purgeIfDue() async -> Bool {
        let (writer, day): (Writer?, String) = lock.withLock { (self.repo, Self.utcDay(clock())) }
        guard let writer, lock.withLock({ lastPurgeDay != day }) else { return false }
        do { try await writer.purge(clock()) } catch { return false }
        lock.withLock { lastPurgeDay = day }
        return true
    }

    /// Flush loop: every `interval` plus up to `jitter` seconds, daily purge, final flush when cancelled (graceful shutdown).
    /// The caller cancels the task on shutdown and awaits it.
    public func run() async {
        _ = await purgeIfDue()
        while !Task.isCancelled {
            let wait = interval + Double.random(in: 0...jitter)
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } catch { break }
            await flush()
            _ = await purgeIfDue()
        }
        await flush()
    }
}
