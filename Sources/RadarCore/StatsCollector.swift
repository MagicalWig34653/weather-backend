import Foundation
import Logging

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

    /// Bytes of a finished response: the in-memory body size, or the `Content-Length` header for streamed bodies (Vapor reports
    /// `-1` for them; counting `max(0, count)` alone would silently drop their volume). Never negative, junk header -> 0.
    public static func responseBytes(bodyCount: Int, contentLength: String?) -> Int {
        if bodyCount > 0 { return bodyCount }
        guard bodyCount < 0, let contentLength, let n = Int(contentLength.trimmingCharacters(in: .whitespaces)), n > 0 else { return 0 }
        return n
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

    /// Precomputed `group:bucket` latency labels.
    static let latencyLabels: [String: [String: String]] = Dictionary(uniqueKeysWithValues: groups.map { g in
        (g, Dictionary(uniqueKeysWithValues: StatsBuckets.latency.names.map { ($0, g + ":" + $0) }))
    })

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
        /// `<route group>:<bucket>` of a bucket scheme (unknown group becomes `other`, unknown bucket drops the sample).
        case routeBucket(StatsBucketScheme)
        /// `<layer>:<bucket>` (`radar` or a layer id) of a bucket scheme.
        case layerBucket(StatsBucketScheme)
    }

    /// Metrics that are additionally kept per UTC hour (`stats_hourly`, 72 h); all others only per day.
    static let hourlyMetrics: Set<String> = [
        "requests", "errors_5xx", "ingest_run", "ingest_lag", "ingest_dur", "latency", "cache_hit", "cache_miss", "cache_evict",
        "push_sent", "push_failed", "la_event", "apns_error", "token_invalidated", "push_trigger", "push_skipped",
        "push_created", "push_attempt", "la_reservation", "push_api_reject",
        // Volume per hour (same grid as `requests`); the flush-error counter goes to both tables so it survives a broken one.
        "bytes_out", "stats_flush_error",
    ]
    static func isHourly(_ metric: String) -> Bool { hourlyMetrics.contains(metric) }

    public static let ingestResults: Set<String> = ["ok", "error", "missed"]

    /// Allowed metrics with their fixed label sets.
    public static var labelRules: [String: LabelRule] {
        return pushLabelRules.merging([
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
            "device_link_reject": .fixed(Set(AppTransactionReject.allCases.map(\.rawValue))),
            "latency": .routeBucket(StatsBuckets.latency),
            "ingest_lag": .layerBucket(StatsBuckets.ingestLag),
            "ingest_dur": .layerBucket(StatsBuckets.ingestDuration),
            "cache_evict": .fixed(["radar", "layer"]),
            "stats_dropped": .fixed([""]),
            "stats_flush_error": .fixed(["day", "hour"]),
        ]) { push, _ in push }
    }

    private struct Key: Hashable { let metric: String; let label: String }

    private let lock = NSLock()
    private var current: [Key: Int] = [:]
    /// Batches of failed flushes with the UTC day they belong to.
    private var carry: [String: [Key: Int]] = [:]
    /// Batches of failed hourly writes with the UTC hour (`yyyy-MM-dd HH`) they belong to. Daily and hourly writes fail and retry
    /// independently, so a failure of one table never double counts in the other.
    private var carryHourly: [String: [Key: Int]] = [:]
    /// Write side of the repo as closures (lets tests inject failures without a full `DashboardRepo` double).
    struct Writer: Sendable {
        let addStats: @Sendable (Date, [StatDelta]) async throws -> Void
        let purge: @Sendable (Date) async throws -> Void
        let addHourly: @Sendable (Date, [StatDelta]) async throws -> Void
        init(addStats: @escaping @Sendable (Date, [StatDelta]) async throws -> Void, purge: @escaping @Sendable (Date) async throws -> Void,
             addHourly: @escaping @Sendable (Date, [StatDelta]) async throws -> Void = { _, _ in }) {
            self.addStats = addStats; self.purge = purge; self.addHourly = addHourly
        }
        init(_ repo: any DashboardRepo) {
            addStats = { try await repo.addStats(day: $0, $1) }
            purge = { _ = try await repo.purgeDashboard(now: $0) }
            addHourly = { try await repo.addStatsHourly(hour: $0, $1) }
        }
    }
    private var flushErrorTotals: [String: Int] = [:]
    private var lastErrorLog: Date?
    private static let log = Logger(label: "radar.stats")
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
        case .routeBucket(let scheme):
            guard let colon = label.firstIndex(of: ":") else { return nil }
            let bucket = String(label[label.index(after: colon)...])
            guard scheme.names.contains(bucket) else { return nil }
            let group = String(label[..<colon])
            return (StatsRoute.requestLabels[group] != nil ? group : "other") + ":" + bucket
        case .layerBucket(let scheme):
            guard let colon = label.firstIndex(of: ":"), ingestLayers.contains(String(label[..<colon])),
                  scheme.names.contains(String(label[label.index(after: colon)...])) else { return nil }
            return label
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
        guard storedKeys() < maxKeys else {
            // Table full: drop the new combination and count the loss (the key exists or is created from the reserve).
            current[Key(metric: "stats_dropped", label: ""), default: 0] += value
            return
        }
        current[key] = value
    }

    /// One finished request. Derives `requests`, `bytes_out`, `errors_5xx`, `rate_limited` (429) and `page_view` from the
    /// route group and status. `path` is only classified, never stored. With `seconds` (handling time of the request) it also
    /// counts one `latency` sample into the bucket of the route group.
    public func recordRequest(path: String, status: Int, bytes: Int, seconds: Double? = nil) {
        let group = StatsRoute.group(path: path)
        let cls = StatsRoute.statusClass(status)
        let label = StatsRoute.requestLabels[group]![cls]!
        let page = status == 200 ? StatsRoute.page(path: path) : nil
        let latency: String? = seconds.flatMap { StatsBuckets.latency.name(forSeconds: $0) }.map { StatsRoute.latencyLabels[group]![$0]! }
        lock.withLock {
            if let latency { add(Key(metric: "latency", label: latency), 1) }
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
            // Same key in the current counters and in a carried batch: one summed entry.
            var sum = current
            for batch in carry.values { sum.merge(batch, uniquingKeysWith: +) }
            return sum.map { StatDelta(metric: $0.key.metric, label: $0.key.label, value: $0.value) }
                .sorted { ($0.metric, $0.label) < ($1.metric, $1.label) }
        }
    }

    /// Failed flushes per kind (`day` or `hour`) since start of this process (fixed keys, never an error text).
    public var flushErrors: [String: Int] { lock.withLock { flushErrorTotals } }

    public var keyCount: Int { lock.withLock { storedKeys() } }

    /// Counter pairs held in memory (current, daily carry, hourly carry). Caller holds the lock.
    private func storedKeys() -> Int {
        current.count + carry.values.reduce(0) { $0 + $1.count } + carryHourly.values.reduce(0) { $0 + $1.count }
    }

    // MARK: flushing

    static func utcDay(_ date: Date) -> String { DashboardValidation.day(date) }

    /// Writes the counters additively into the database. A failing write keeps the counters (they go into the next attempt).
    /// Returns true when nothing is left to write. Safe to call concurrently: each call takes its own batch.
    @discardableResult
    public func flush() async -> Bool {
        typealias Batches = [String: [Key: Int]]
        let (writer, daily, hourly): (Writer?, Batches, Batches) = lock.withLock {
            guard let target = self.repo else { return (nil, [:], [:]) }
            var days = carry, hours = carryHourly
            carry = [:]; carryHourly = [:]
            if !current.isEmpty {
                let now = clock()
                days[Self.utcDay(now), default: [:]].merge(current, uniquingKeysWith: +)
                let selected = current.filter { Self.isHourly($0.key.metric) }
                if !selected.isEmpty { hours[DashboardValidation.hour(now), default: [:]].merge(selected, uniquingKeysWith: +) }
                current = [:]
            }
            return (target, days, hours)
        }
        guard let writer else { return true }
        func deltas(_ counters: [Key: Int]) -> [StatDelta] { counters.map { StatDelta(metric: $0.key.metric, label: $0.key.label, value: $0.value) } }
        var failedDaily: Batches = [:], failedHourly: Batches = [:]
        var errorClass: [String: String] = [:]
        for (day, counters) in daily {
            do { try await writer.addStats(DashboardValidation.date(day: day), deltas(counters)) } catch {
                failedDaily[day] = counters; errorClass["day"] = String(describing: type(of: error))
            }
        }
        for (hour, counters) in hourly {
            do { try await writer.addHourly(DashboardValidation.date(hour: hour), deltas(counters)) } catch {
                failedHourly[hour] = counters; errorClass["hour"] = String(describing: type(of: error))
            }
        }
        if failedDaily.isEmpty && failedHourly.isEmpty { return true }
        lock.withLock {
            // One fixed-label count per failed kind and flush (no error text, no SQL); it is written with the next successful flush.
            for kind in errorClass.keys {
                flushErrorTotals[kind, default: 0] += 1
                add(Key(metric: "stats_flush_error", label: kind), 1)
            }
            // At most one log line per minute: error class only (the driver's message may contain SQL or values).
            let now = clock()
            if lastErrorLog.map({ now.timeIntervalSince($0) >= 60 || now < $0 }) ?? true {
                lastErrorLog = now
                let kinds = errorClass.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                Self.log.warning("statistics flush failed (\(kinds)); counters are kept and retried")
            }
            // Put back, bounded: surplus combinations are dropped and counted.
            var dropped = 0
            for (day, counters) in failedDaily {
                for (key, value) in counters {
                    if storedKeys() >= maxKeys { dropped += value; continue }
                    carry[day, default: [:]][key, default: 0] += value
                }
            }
            for (hour, counters) in failedHourly {
                for (key, value) in counters {
                    if storedKeys() >= maxKeys { dropped += value; continue }
                    carryHourly[hour, default: [:]][key, default: 0] += value
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
