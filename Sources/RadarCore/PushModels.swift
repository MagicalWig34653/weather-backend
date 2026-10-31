import Foundation

/// Server raster for push subscriptions: the pixel grid of the ingest image (IMAGE_WIDTH 1024 -> 1024 x 1311, EPSG:3857, fixed bbox).
public enum PushGrid {
    public static let version = 1
    public static let width = 1024
    public static let validLeadMinutes: Set<Int> = [10, 20, 30]
    public static let thresholdRange = 1...15
    public static let maxSubscriptionsPerInstallation = 10
    public static let maxBodyBytes = 2048

    /// Cell of a Web-Mercator point (used by tests and docs; the app computes the cell locally, the server never sees a coordinate).
    public static func cell(mercatorX x: Double, mercatorY y: Double, width: Int) -> (x: Int, y: Int)? {
        let b = RadarConstants.bbox
        let height = RadarConstants.imageHeight(width: width)
        guard x >= b[0], x < b[2], y > b[1], y <= b[3] else { return nil }
        let cx = Int((x - b[0]) / (b[2] - b[0]) * Double(width))
        let cy = Int((b[3] - y) / (b[3] - b[1]) * Double(height))
        return (min(cx, width - 1), min(cy, height - 1))
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
    public init(id: String, gridVersion: Int, cellX: Int, cellY: Int, threshold: Int, leadMinutes: Int,
                enabled: Bool, state: PushState = .dry, lastSentAt: Date? = nil) {
        self.id = id; self.gridVersion = gridVersion; self.cellX = cellX; self.cellY = cellY; self.threshold = threshold
        self.leadMinutes = leadMinutes; self.enabled = enabled; self.state = state; self.lastSentAt = lastSentAt
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
    public init(gridVersion: Int, cellX: Int, cellY: Int, threshold: Int, leadMinutes: Int, enabled: Bool) {
        self.gridVersion = gridVersion; self.cellX = cellX; self.cellY = cellY; self.threshold = threshold
        self.leadMinutes = leadMinutes; self.enabled = enabled
    }
}

public enum UpsertResult: Sendable, Equatable { case created, updated, forbidden }
public enum AddSubscriptionResult: Sendable, Equatable { case created, limitReached, unknownInstallation }

public struct SubscriptionUpdate: Sendable, Equatable {
    public var id: String
    public var state: PushState
    public var lastSentAt: Date?
    public init(id: String, state: PushState, lastSentAt: Date?) { self.id = id; self.state = state; self.lastSentAt = lastSentAt }
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
