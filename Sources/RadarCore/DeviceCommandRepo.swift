import Foundation

public enum DeviceCommandKind: String, Sendable, CaseIterable {
    case test, laProbe = "la_probe", laEnd = "la_end", reeval, resetSlot = "reset_slot", warnTest = "warn_test"

    /// Path segment of `POST /dash/api/devices/{id}/actions/{action}`.
    public init?(action: String) {
        switch action {
        case "test": self = .test
        case "la-probe": self = .laProbe
        case "la-end": self = .laEnd
        case "reeval": self = .reeval
        case "reset-slot": self = .resetSlot
        case "warn-test": self = .warnTest
        default: return nil
        }
    }
}

public enum DeviceCommandStatus: String, Sendable { case queued, running, done, failed, expired }

/// One operator action for a linked device. `result` is JSON with fixed fields only (docs-site/content/dashboard-api.md).
public struct DeviceCommand: Sendable, Equatable {
    public let id: String
    public let deviceID: String
    public let kind: DeviceCommandKind
    public let dryRun: Bool?
    /// Fixed-vocabulary parameter of the command (`warn_test`: `<type>:<level>`, e.g. `frost:1`); nil for all others.
    public let param: String?
    public var status: DeviceCommandStatus
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var result: String?
    public var error: String?
    public init(id: String, deviceID: String, kind: DeviceCommandKind, dryRun: Bool?, param: String? = nil, status: DeviceCommandStatus, createdAt: Date,
                startedAt: Date? = nil, finishedAt: Date? = nil, result: String? = nil, error: String? = nil) {
        self.id = id; self.deviceID = deviceID; self.kind = kind; self.dryRun = dryRun; self.param = param; self.status = status
        self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt; self.result = result; self.error = error
    }
}

public struct DeviceEvent: Sendable, Equatable {
    public let at: Date
    /// `alert`, `la_start`, `la_update`, `la_end`, `test`, `probe`, `token`
    public let kind: String
    /// `delivered`, `rejected`, `retry`, `dropped`, `skipped`
    public let outcome: String
    public let reason: String?
    public init(at: Date, kind: String, outcome: String, reason: String?) { self.at = at; self.kind = kind; self.outcome = outcome; self.reason = reason }
}

public enum CreateCommandResult: Sendable, Equatable { case created(DeviceCommand), pending, deviceGone }

public enum DeviceRetention {
    public static let commandHours = 48
    public static let maxCommandsPerDevice = 50
    public static let eventHours = 48
    public static let maxEventsPerDevice = 200
    /// Unprocessed commands expire after this many seconds.
    public static let commandExpirySeconds: TimeInterval = 120
    /// A `running` command older than this (leader died before `finishCommand`) is set to `failed` (`error: "timeout"`).
    public static let runningTimeoutSeconds: TimeInterval = 180
}

/// Command table (decision D6: the dashboard process sends nothing; the leader executes) and the 48 hour event log of linked devices.
public protocol DeviceCommandRepo: Sendable {
    /// `pending` when a command of the same kind is queued or running for the device. Trims to 50 commands per device and touches `last_action_at`.
    func createCommand(deviceID: String, kind: DeviceCommandKind, dryRun: Bool?, param: String?, now: Date) async throws -> CreateCommandResult
    func command(id: String, deviceID: String) async throws -> DeviceCommand?
    /// Newest first.
    func commands(deviceID: String, limit: Int) async throws -> [DeviceCommand]
    /// Leader: marks queued commands older than `commandExpirySeconds` as expired, then takes the oldest queued one (queued -> running).
    func claimNextCommand(now: Date) async throws -> DeviceCommand?
    func finishCommand(id: String, status: DeviceCommandStatus, result: String?, error: String?, now: Date) async throws
    /// Events are written only for linked devices (nothing for anybody else). Keeps at most 200 rows per device.
    func appendDeviceEvent(installationID: String, kind: String, outcome: String, reason: String?, now: Date) async throws
    /// Newest first.
    func deviceEvents(deviceID: String, limit: Int) async throws -> [DeviceEvent]
    /// Commands and events older than 48 hours.
    func purgeDeviceOps(now: Date) async throws
}

extension DeviceCommandRepo {
    public func createCommand(deviceID: String, kind: DeviceCommandKind, dryRun: Bool?, now: Date) async throws -> CreateCommandResult {
        try await createCommand(deviceID: deviceID, kind: kind, dryRun: dryRun, param: nil, now: now)
    }
}
