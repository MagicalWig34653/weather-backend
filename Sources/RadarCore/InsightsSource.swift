import Foundation

// Data layer of the insights routes (docs-site/content/dashboard-api.md, "Insights"). The engine never touches repos directly:
// everything it needs comes through `InsightsDataSource`. What is not collected yet is `nil` (never an empty value that looks
// like 0); WP11 only has to fill the corresponding adapter methods.

/// Range parameter of the insights routes.
public enum InsightsRange: String, Sendable, CaseIterable {
    case h24 = "24h", h72 = "72h", d7 = "7d", d30 = "30d"

    /// Hourly ranges can use `stats_hourly` (retention 72 h).
    var hourly: Bool { self == .h24 || self == .h72 }
    var hours: Int { self == .h24 ? 24 : 72 }
    /// Number of UTC days of the day grid (an hourly range touches one more calendar day than it is long).
    var days: Int {
        switch self { case .h24: return 2; case .h72: return 4; case .d7: return 7; case .d30: return 30 }
    }
}

/// Operator thresholds (register group "Dashboard-Schwellen", keys `DASH_WARN_<RULE>_YELLOW|RED`, `DASH_MIN_GROUP`).
public struct InsightsThresholds: Sendable, Equatable {
    public struct Pair: Sendable, Equatable {
        public var yellow: Double, red: Double
        public init(_ yellow: Double, _ red: Double) { self.yellow = yellow; self.red = red }
    }
    public var layerAgeFactor = Pair(2, 4)
    public var errorRate5xx = Pair(0.005, 0.02)
    public var outboxAgeSeconds = Pair(120, 600)
    public var apnsRejection = Pair(0.05, 0.25)
    public var tokenInvalidation = Pair(0.05, 0.20)
    /// Lower bounds: below yellow is a warning, below red critical.
    public var cacheHit = Pair(0.80, 0.50)
    public var capFill = Pair(0.80, 0.95)
    public var laStartRatio = Pair(0.70, 0.30)
    public var minGroup = 5

    public init() {}

    /// Reads `DASH_WARN_*` and `DASH_MIN_GROUP` from a lookup (ENV or the live register); invalid values keep the default.
    public init(lookup: (String) -> String?) {
        func pair(_ rule: String, _ current: Pair) -> Pair {
            let y = lookup("DASH_WARN_\(rule)_YELLOW").flatMap(Double.init) ?? current.yellow
            let r = lookup("DASH_WARN_\(rule)_RED").flatMap(Double.init) ?? current.red
            return Pair(y, r)
        }
        layerAgeFactor = pair("LAYER_AGE_FACTOR", layerAgeFactor)
        errorRate5xx = pair("ERROR_RATE_5XX", errorRate5xx)
        outboxAgeSeconds = pair("OUTBOX_AGE_SECONDS", outboxAgeSeconds)
        apnsRejection = pair("APNS_REJECTION", apnsRejection)
        tokenInvalidation = pair("TOKEN_INVALIDATION", tokenInvalidation)
        cacheHit = pair("CACHE_HIT", cacheHit)
        capFill = pair("CAP_FILL", capFill)
        laStartRatio = pair("LA_START_RATIO", laStartRatio)
        if let k = lookup("DASH_MIN_GROUP").flatMap(Int.init), (3...50).contains(k) { minGroup = k }
    }
}

/// Server-side prerequisites of the push chain (state only, never configuration values).
public struct InsightsPushSetup: Sendable, Equatable {
    /// `APNS_ENV` (`sandbox` or `production`); nil when unknown.
    public var apnsEnv: String?
    public var topicSet: Bool
    public var keyPresent: Bool
    public var liveActivityCapability: Bool
    public init(apnsEnv: String?, topicSet: Bool, keyPresent: Bool, liveActivityCapability: Bool) {
        self.apnsEnv = apnsEnv; self.topicSet = topicSet; self.keyPresent = keyPresent; self.liveActivityCapability = liveActivityCapability
    }
}

/// Maximum values of the caps (`PUSH_MAX_*`).
public struct InsightsCapLimits: Sendable, Equatable {
    public var installations: Int, subscriptions: Int, regionCells: Int, activitySubscriptions: Int
    public init(installations: Int, subscriptions: Int, regionCells: Int, activitySubscriptions: Int) {
        self.installations = installations; self.subscriptions = subscriptions
        self.regionCells = regionCells; self.activitySubscriptions = activitySubscriptions
    }
}

public struct InsightsContext: Sendable, Equatable {
    public var pushEnabled: Bool
    public var pushPaused: Bool
    public var thresholds: InsightsThresholds
    public var setup: InsightsPushSetup
    public var caps: InsightsCapLimits
    /// Desired replica count when known (fewer running replicas is a finding).
    public var expectedReplicas: Int?
    public init(pushEnabled: Bool, pushPaused: Bool = false, thresholds: InsightsThresholds = InsightsThresholds(),
                setup: InsightsPushSetup = InsightsPushSetup(apnsEnv: nil, topicSet: true, keyPresent: true, liveActivityCapability: true),
                caps: InsightsCapLimits, expectedReplicas: Int? = nil) {
        self.pushEnabled = pushEnabled; self.pushPaused = pushPaused; self.thresholds = thresholds
        self.setup = setup; self.caps = caps; self.expectedReplicas = expectedReplicas
    }
}

public struct HourlyStatRow: Sendable, Equatable {
    /// Start of the UTC hour.
    public let hour: Date
    public let metric: String
    public let label: String
    public let value: Int
    public init(hour: Date, metric: String, label: String, value: Int) {
        self.hour = hour; self.metric = metric; self.label = label; self.value = value
    }
}

public struct InsightsLayerRun: Sendable, Equatable {
    public let slot: Date
    /// `ok`, `error` or `missed`.
    public let result: String
    public init(slot: Date, result: String) { self.slot = slot; self.result = result }
}

public struct InsightsLayerLag: Sendable, Equatable {
    public var p50Seconds: Int?, p95Seconds: Int?
    public var series: InsightsSeries?
    public init(p50Seconds: Int?, p95Seconds: Int?, series: InsightsSeries?) {
        self.p50Seconds = p50Seconds; self.p95Seconds = p95Seconds; self.series = series
    }
}

public struct InsightsLayerState: Sendable, Equatable {
    /// `radar` or an id of `LayerCatalog`.
    public var id: String
    public var enabled: Bool
    public var latestRun: String?
    public var publishedAt: Date?
    public var cadenceSeconds: Int
    /// Last 24 h ascending; nil = not collected (shown as empty list).
    public var runs: [InsightsLayerRun]?
    public var lag: InsightsLayerLag?
    public init(id: String, enabled: Bool, latestRun: String?, publishedAt: Date?, cadenceSeconds: Int,
                runs: [InsightsLayerRun]? = nil, lag: InsightsLayerLag? = nil) {
        self.id = id; self.enabled = enabled; self.latestRun = latestRun; self.publishedAt = publishedAt
        self.cadenceSeconds = cadenceSeconds; self.runs = runs; self.lag = lag
    }
}

public struct InsightsReplica: Sendable, Equatable {
    /// Raw replica id; the answer only carries the 8-hex hash.
    public var replicaID: String
    public var startedAt: Date
    public var appliedGeneration: Int
    public var revision: String?
    public init(replicaID: String, startedAt: Date, appliedGeneration: Int, revision: String? = nil) {
        self.replicaID = replicaID; self.startedAt = startedAt; self.appliedGeneration = appliedGeneration; self.revision = revision
    }
}

public struct InsightsLeader: Sendable, Equatable {
    /// Raw replica id of the lease holder (hashed in the answer), nil without holder.
    public var holder: String?
    public var leaseSecondsLeft: Int?
    /// nil = leader changes are not counted (answer: `changes24h: null`).
    public var changes24h: Int?
    public init(holder: String?, leaseSecondsLeft: Int?, changes24h: Int? = nil) {
        self.holder = holder; self.leaseSecondsLeft = leaseSecondsLeft; self.changes24h = changes24h
    }
}

public struct InsightsReplicaInfo: Sendable, Equatable {
    public var replicas: [InsightsReplica]
    public var generation: Int
    /// nil = lease state not readable (answer: `leader: null`).
    public var leader: InsightsLeader?
    public init(replicas: [InsightsReplica], generation: Int, leader: InsightsLeader? = nil) {
        self.replicas = replicas; self.generation = generation; self.leader = leader
    }
}

public struct InsightsCacheFill: Sendable, Equatable {
    public var bytes: Int, maxBytes: Int, entries: Int, evictions: Int
    /// `maxOfReplicas` (contract) or `thisReplica` (only the replica that answers the dashboard request is known).
    public var scope: String
    public init(bytes: Int, maxBytes: Int, entries: Int, evictions: Int, scope: String = "maxOfReplicas") {
        self.bytes = bytes; self.maxBytes = maxBytes; self.entries = entries; self.evictions = evictions; self.scope = scope
    }
}

public struct InsightsLatencyRoute: Sendable {
    public var route: String
    /// `le` in `10ms|50ms|200ms|1s|inf`.
    public var buckets: [(le: String, count: Int)]
    public var p50Ms: Int?, p95Ms: Int?, p99Ms: Int?
    public init(route: String, buckets: [(le: String, count: Int)], p50Ms: Int?, p95Ms: Int?, p99Ms: Int?) {
        self.route = route; self.buckets = buckets; self.p50Ms = p50Ms; self.p95Ms = p95Ms; self.p99Ms = p99Ms
    }
}

public struct InsightsDatabaseInfo: Sendable, Equatable {
    public var poolUsage: Double?, errors24h: Int?, migration: String?
    public init(poolUsage: Double?, errors24h: Int?, migration: String?) {
        self.poolUsage = poolUsage; self.errors24h = errors24h; self.migration = migration
    }
}

/// Database gauges of the push pipeline (aggregates only, no identifiers).
public struct InsightsPushGauges: Sendable, Equatable {
    public var installationsTotal = 0
    public var active1d = 0, active7d = 0, active30d = 0
    /// Installations per `sandbox|production` and per locale (`de|en`).
    public var byEnv: [String: Int] = [:]
    public var byLocale: [String: Int] = [:]
    public var withDeviceToken = 0, withStartToken = 0
    /// `lt1d|lt7d|lt30d|older`; nil when not derivable.
    public var startTokenAge: [String: Int]?
    public var subscriptionsTotal = 0, subscriptionsEnabled = 0, subscriptionsLiveActivity = 0, subscriptionsLiveActivityWithStartToken = 0
    public var subscriptionsTimeSensitive = 0
    /// Installations per number of subscriptions (`0|1|2|3+`) and of region subscriptions (`0|1|2|3`).
    public var subscriptionsPerInstallation: [String: Int] = [:]
    public var regionsPerInstallation: [String: Int] = [:]
    /// Subscriptions per intensity class (`1`..`15`) and lead time (`10|20|30`).
    public var threshold: [String: Int] = [:]
    public var lead: [String: Int] = [:]
    public var regionCells = 0
    public var activeActivities = 0, reservationsOpen = 0
    /// Reservations older than the 15 min timeout.
    public var reservationsExpired = 0
    public var activeLocks = 0
    public var outboxWaiting = 0, outboxOldestAgeSeconds: Int?, outboxRetrying = 0, outboxDroppedOrExpired24h = 0
    /// Installations whose environment differs from `APNS_ENV` (`sandbox`/`production` counts live in `byEnv`).
    public init() {}
}

/// Counter-based push sections (WP11). Every field nil = not collected.
public struct InsightsPushCounters: Sendable {
    public var triggers: [(trigger: String, count: Int)]?
    public var skipped: [(trigger: String, reason: String, count: Int)]?
    public var lifecycleEvents: [(event: String, outcome: String, count: Int)]?
    public var apnsErrors: [(kind: String, reason: String, env: String, count: Int)]?
    public var delivery: Delivery?
    public var tokenInvalidations: [(kind: String, cause: String, count: Int)]?
    public var timing: Timing?
    public var registrations: Registrations?
    public var rejects: [(code: String, count: Int)]?
    /// Rule inputs (1 h / 24 h windows) for the findings.
    public var apnsRejectionRatio1h: Double?
    public var apnsCriticalReasons1h: Int?
    public var tokenInvalidationRatio24h: Double?
    public var laStartTriggers24h: Int?
    public var laStartDelivered24h: Int?

    public struct Delivery: Sendable {
        public var created: Int, sent: Int, delivered: Int, rejected: Int, dropped: Int, retry: Int
        public var ratio: Double?, avgAttempts: Double?
        public init(created: Int, sent: Int, delivered: Int, rejected: Int, dropped: Int, retry: Int, ratio: Double?, avgAttempts: Double?) {
            self.created = created; self.sent = sent; self.delivered = delivered; self.rejected = rejected
            self.dropped = dropped; self.retry = retry; self.ratio = ratio; self.avgAttempts = avgAttempts
        }
    }
    public struct Timing: Sendable {
        public var apnsSendMs: [(le: String, count: Int)]
        public var evalMsP95: Int?, cellsChecked: Int?
        public init(apnsSendMs: [(le: String, count: Int)], evalMsP95: Int?, cellsChecked: Int?) {
            self.apnsSendMs = apnsSendMs; self.evalMsP95 = evalMsP95; self.cellsChecked = cellsChecked
        }
    }
    public struct Registrations: Sendable {
        public var created: InsightsSeries, deleted: InsightsSeries, retained7dRatio: Double?
        public init(created: InsightsSeries, deleted: InsightsSeries, retained7dRatio: Double?) {
            self.created = created; self.deleted = deleted; self.retained7dRatio = retained7dRatio
        }
    }

    public init() {}
}

/// Everything the insights engine reads. Methods that throw make only their section fail (`partial`); defaults mean
/// "not collected" (nil).
public protocol InsightsDataSource: Sendable {
    /// Configuration state at call time (never throws; unreadable values fall back to defaults).
    func context() async -> InsightsContext
    /// Daily counters, UTC days in [from, to].
    func dailyStats(from: Date, to: Date) async throws -> [StatRow]
    /// Hourly counters (`stats_hourly`, retention 72 h); nil = not collected.
    func hourlyStats(from: Date, to: Date) async throws -> [HourlyStatRow]?
    func layers(now: Date) async throws -> [InsightsLayerState]
    func replicaInfo(now: Date) async throws -> InsightsReplicaInfo
    /// Cache fill level (max over replicas), nil = not collected.
    func cacheFill() async throws -> InsightsCacheFill?
    func latency(range: InsightsRange, now: Date) async throws -> [InsightsLatencyRoute]?
    func databaseInfo() async throws -> InsightsDatabaseInfo?
    /// nil = push disabled or not readable (not a failure).
    func pushGauges(now: Date) async throws -> InsightsPushGauges?
    func pushCounters(range: InsightsRange, now: Date) async throws -> InsightsPushCounters?
}

public extension InsightsDataSource {
    func hourlyStats(from: Date, to: Date) async throws -> [HourlyStatRow]? { nil }
    func cacheFill() async throws -> InsightsCacheFill? { nil }
    func latency(range: InsightsRange, now: Date) async throws -> [InsightsLatencyRoute]? { nil }
    func databaseInfo() async throws -> InsightsDatabaseInfo? { nil }
    func pushCounters(range: InsightsRange, now: Date) async throws -> InsightsPushCounters? { nil }
}
