import Foundation

/// Server raster for push subscriptions: the pixel grid of the ingest image (IMAGE_WIDTH 1024 -> 1024 x 1311, EPSG:3857, fixed bbox).
public enum PushGrid {
    public static let version = 1
    public static let width = 1024
    public static let validLeadMinutes: Set<Int> = [10, 20, 30]
    public static let thresholdRange = 1...15
    public static let maxSubscriptionsPerInstallation = 10
    public static let maxBodyBytes = 2048
    /// `last_seen_at` is refreshed at most this often (retention is 60 days).
    public static let lastSeenRefreshSeconds: TimeInterval = 3600

    /// Cell of a Web-Mercator point (used by tests and docs; the app computes the cell locally, the server never sees a coordinate).
    public static func cell(mercatorX x: Double, mercatorY y: Double, width: Int) -> (x: Int, y: Int)? {
        let b = RadarConstants.bbox
        let height = RadarConstants.imageHeight(width: width)
        guard x >= b[0], x < b[2], y > b[1], y <= b[3] else { return nil }
        let cx = Int((x - b[0]) / (b[2] - b[0]) * Double(width))
        let cy = Int((b[3] - y) / (b[3] - b[1]) * Double(height))
        return (min(cx, width - 1), min(cy, height - 1))
    }

    static let earthRadius = 6_378_137.0

    /// Centre of a cell as latitude/longitude, rounded to two decimals (about 1 km, the cell size): the inverse of `cell`.
    /// The server stores only the cell; this is the same information shown on a map in the operator dashboard.
    public static func coordinate(cellX: Int, cellY: Int, width: Int) -> (lat: Double, lon: Double)? {
        let b = RadarConstants.bbox
        let height = RadarConstants.imageHeight(width: width)
        guard cellX >= 0, cellY >= 0, cellX < width, cellY < height else { return nil }
        let x = b[0] + (Double(cellX) + 0.5) / Double(width) * (b[2] - b[0])
        let y = b[3] - (Double(cellY) + 0.5) / Double(height) * (b[3] - b[1])
        let lon = x / earthRadius * 180 / .pi
        let lat = atan(sinh(y / earthRadius)) * 180 / .pi
        return ((lat * 100).rounded() / 100, (lon * 100).rounded() / 100)
    }

    /// Ground distance of one cell edge in kilometres at the given latitude (Web Mercator stretches towards the poles).
    public static func cellKilometres(latitude: Double, width: Int) -> Double {
        let b = RadarConstants.bbox
        return (b[2] - b[0]) / Double(width) * cos(latitude * .pi / 180) / 1000
    }
}

public enum PushEnvironment: String, Sendable, Codable, CaseIterable { case sandbox, production }

/// Per-subscription state of the rain-start automaton.
public enum PushState: Int, Sendable {
    /// Armed: no rain expected within the lead time.
    case dry = 0
    /// The rain-start condition held in the last evaluated run; a second consecutive run triggers the notification.
    case pending = 1
    /// Notified; re-armed once the next 30 minutes are dry again.
    case notified = 2
}

public struct PushSubscription: Sendable, Equatable {
    public var id: String
    public var gridVersion: Int
    public var cellX: Int
    public var cellY: Int
    public var threshold: Int
    public var leadMinutes: Int
    public var enabled: Bool
    public var state: PushState
    public var lastSentAt: Date?
    /// Optional per-subscription flag: the rain-start notification carries `interruption-level: time-sensitive`.
    public var liveActivity: Bool
    public var timeSensitive: Bool
    /// `.circle`: region around the (coarse) centre cell `cellX/cellY` with `radiusCells` and trigger share `minSharePercent`.
    public var kind: PushKind
    public var radiusCells: Int?
    public var minSharePercent: Int?
    /// Live Activity hysteresis: the previous complete run showed a known wet slot 0 (persisted as bit 4 of `state`).
    public var wetSeen: Bool = false
    /// Immediate Live Activity start (decision 6 Nov 2026, persisted as bit 5 of `state`): armed by activation (subscription with
    /// Live Activity, new start token) or while a rain-now start is in flight; a single wet run then starts, without the 60-minute lock.
    public var instantStart: Bool = false
    /// Last real evaluation result (Live Activity subscriptions only; `nil` before the first run after the migration).
    public var trace: EvalTrace?
    /// Creation and last change by the owner (diagnosis only; `nil` when unknown).
    public var createdAt: Date?
    public var changedAt: Date?
    /// Failed start attempts of the current immediate start (bits 6-7 of `state`, 0...3).
    public var startAttempts: Int = 0
    public init(id: String, gridVersion: Int, cellX: Int, cellY: Int, threshold: Int, leadMinutes: Int,
                enabled: Bool, state: PushState = .dry, lastSentAt: Date? = nil, timeSensitive: Bool = false,
                kind: PushKind = .point, radiusCells: Int? = nil, minSharePercent: Int? = nil, liveActivity: Bool = false) {
        self.liveActivity = liveActivity
        self.kind = kind; self.radiusCells = radiusCells; self.minSharePercent = minSharePercent
        self.id = id; self.gridVersion = gridVersion; self.cellX = cellX; self.cellY = cellY; self.threshold = threshold
        self.leadMinutes = leadMinutes; self.enabled = enabled; self.state = state; self.lastSentAt = lastSentAt
        self.timeSensitive = timeSensitive
    }
}

/// Subscription fields the client may set (everything else is server state).
public struct PushSubscriptionInput: Sendable, Equatable {
    public var gridVersion: Int
    public var cellX: Int
    public var cellY: Int
    public var threshold: Int
    public var leadMinutes: Int
    public var enabled: Bool
    public var liveActivity: Bool
    public var timeSensitive: Bool
    public var kind: PushKind
    public var radiusCells: Int?
    public var minSharePercent: Int?
    public init(gridVersion: Int, cellX: Int, cellY: Int, threshold: Int, leadMinutes: Int, enabled: Bool, timeSensitive: Bool = false,
                kind: PushKind = .point, radiusCells: Int? = nil, minSharePercent: Int? = nil, liveActivity: Bool = false) {
        self.liveActivity = liveActivity
        self.kind = kind; self.radiusCells = radiusCells; self.minSharePercent = minSharePercent
        self.gridVersion = gridVersion; self.cellX = cellX; self.cellY = cellY; self.threshold = threshold
        self.leadMinutes = leadMinutes; self.enabled = enabled; self.timeSensitive = timeSensitive
    }
}

/// Delivery target of an installation (device token, APNs environment, language); used by the test notification.
public struct PushInstallation: Sendable, Equatable {
    public var token: String
    public var env: PushEnvironment
    public var locale: String
    public var liveActivityStartToken: String?
    public init(token: String, env: PushEnvironment, locale: String, liveActivityStartToken: String? = nil) {
        self.token = token; self.env = env; self.locale = locale; self.liveActivityStartToken = liveActivityStartToken
    }
}

public enum UpsertResult: Sendable, Equatable { case created, updated, forbidden, serverFull }
public enum AddSubscriptionResult: Sendable, Equatable { case created, limitReached, unknownInstallation, regionLimit, regionCapacity, serverFull, activityCapacity }

/// Result of the last real evaluation of one Live Activity subscription (diagnosis, persisted in `eval_*` columns).
public struct EvalTrace: Sendable, Equatable {
    public var run: String
    /// Fixed word, see `PushService.TraceReason`.
    public var reason: String
    /// Class of slot 0 (0 dry, -1 unknown pixel).
    public var cls: Int
    public init(run: String, reason: String, cls: Int) { self.run = run; self.reason = reason; self.cls = cls }
}

public struct SubscriptionUpdate: Sendable, Equatable {
    public var trace: EvalTrace?
    public var id: String
    public var state: PushState
    public var lastSentAt: Date?
    public var wetSeen: Bool
    public var instantStart: Bool
    public var startAttempts: Int
    public init(id: String, state: PushState, lastSentAt: Date?, wetSeen: Bool = false, instantStart: Bool = false, startAttempts: Int = 0, trace: EvalTrace? = nil) {
        self.trace = trace
        self.id = id; self.state = state; self.lastSentAt = lastSentAt; self.wetSeen = wetSeen
        self.instantStart = instantStart; self.startAttempts = startAttempts
    }
}

public struct NewOutboxItem: Sendable, Equatable {
    public var subID: String
    public var dedupeKey: String
    public var collapseID: String
    public var payloadJSON: String
    public var expiresAt: Date
    public init(subID: String, dedupeKey: String, collapseID: String, payloadJSON: String, expiresAt: Date) {
        self.subID = subID; self.dedupeKey = dedupeKey; self.collapseID = collapseID
        self.payloadJSON = payloadJSON; self.expiresAt = expiresAt
    }
}

/// A due outbox entry together with the delivery target.
public struct OutboxItem: Sendable, Equatable {
    public var id: Int
    public var token: String
    public var env: PushEnvironment
    public var collapseID: String
    public var payloadJSON: String
    public var expiresAt: Date
    public var attempts: Int
    public init(id: Int, token: String, env: PushEnvironment, collapseID: String, payloadJSON: String, expiresAt: Date, attempts: Int) {
        self.id = id; self.token = token; self.env = env; self.collapseID = collapseID
        self.payloadJSON = payloadJSON; self.expiresAt = expiresAt; self.attempts = attempts
    }
}

public enum OutboxOutcome: Sendable, Equatable {
    case sent
    case dropped
    case retry(attempts: Int, at: Date)
}

public struct PushPurgeResult: Sendable, Equatable {
    public var installations = 0
    public var outbox = 0
    public init(installations: Int = 0, outbox: Int = 0) { self.installations = installations; self.outbox = outbox }
}

/// One current activity per subscription; nil token reserves a push-to-start while the app reports its token.
public struct PushActivity: Sendable, Equatable {
    public var subscriptionID: String
    public var activityToken: String?
    public var startedAt: Date
    public var endsAt: Date
    public init(subscriptionID: String, activityToken: String?, startedAt: Date, endsAt: Date) {
        self.subscriptionID = subscriptionID; self.activityToken = activityToken; self.startedAt = startedAt; self.endsAt = endsAt
    }
}

public struct PushActivityTarget: Sendable, Equatable {
    public var installationID: String
    public var installation: PushInstallation
    public var subscription: PushSubscription
    public var activity: PushActivity?
    public init(installationID: String, installation: PushInstallation, subscription: PushSubscription, activity: PushActivity?) {
        self.installationID = installationID; self.installation = installation; self.subscription = subscription; self.activity = activity
    }
}

/// Result of the atomic slot reservation. `displaced`: a point took the slot from a running region activity (the row of the region
/// is already deleted; the caller ends it via APNs with this token). `regionReservationPending`: a region start is in flight (no token yet).
public enum ActivityReservation: Sendable, Equatable {
    case reserved, busy, regionReservationPending
    case displaced(subscriptionID: String, activityToken: String)
}

public enum PushActivityRegistrationResult: Sendable, Equatable { case updated, notFound, notEligible, activityLimit }
