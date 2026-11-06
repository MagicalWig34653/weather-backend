import Crypto
import Foundation

/// A device the operator has linked to the dashboard (docs/dashboard-insights-plan.md 4). `id` is the random linking ID shown to the
/// dashboard; `installID` is internal and never leaves the process.
public struct LinkedDevice: Sendable, Equatable {
    public let id: String
    public let installID: String
    public let label: String
    public let pairedAt: Date
    /// Only set when the operator configured `DASH_DEVICE_TTL_DAYS` (default: no expiry, linking is permanent until revoked).
    public let expiresAt: Date?
    public let lastActionAt: Date?
    public init(id: String, installID: String, label: String, pairedAt: Date, expiresAt: Date?, lastActionAt: Date?) {
        self.id = id; self.installID = installID; self.label = label; self.pairedAt = pairedAt
        self.expiresAt = expiresAt; self.lastActionAt = lastActionAt
    }
}

public struct DeviceLinkState: Sendable, Equatable {
    public enum Kind: String, Sendable { case none, codeOpen = "code_open", linked }
    public var kind: Kind
    public var codeExpiresAt: Date?
    public var linkedAt: Date?
    public var expiresAt: Date?
    public var lastActionAt: Date?
    public var pendingCommands: Int
    public init(kind: Kind, codeExpiresAt: Date? = nil, linkedAt: Date? = nil, expiresAt: Date? = nil, lastActionAt: Date? = nil, pendingCommands: Int = 0) {
        self.kind = kind; self.codeExpiresAt = codeExpiresAt; self.linkedAt = linkedAt; self.expiresAt = expiresAt
        self.lastActionAt = lastActionAt; self.pendingCommands = pendingCommands
    }
}

public enum CreateLinkCodeResult: Sendable, Equatable { case created, alreadyLinked, linkFull, unknownInstallation }
public enum PairDeviceResult: Sendable, Equatable { case paired(LinkedDevice), codeUnknown, deviceLimit }

/// Linking codes (hash only) and linked devices. Codes live 10 minutes and work once; at most one open code per installation.
/// Everything hangs off `push_install` (ON DELETE CASCADE): deleting an installation revokes its link.
public protocol DeviceLinkRepo: Sendable {
    /// Replaces an open code of the installation. `alreadyLinked` when the installation is linked, `linkFull` at `maxDevices`.
    func createLinkCode(installationID: String, codeHash: [UInt8], attested: Bool, now: Date, ttl: TimeInterval, maxDevices: Int) async throws -> CreateLinkCodeResult
    func linkState(installationID: String, now: Date) async throws -> DeviceLinkState
    /// Revocation by the app: link, open code, events and commands of the installation. Idempotent.
    func unlink(installationID: String) async throws
    /// Atomic redemption: needs an unused, unexpired, attested code. Consumes it only on success.
    func pairDevice(codeHash: [UInt8], label: String, deviceID: String, now: Date, maxDevices: Int, ttlDays: Int) async throws -> PairDeviceResult
    func devices() async throws -> [LinkedDevice]
    func device(id: String) async throws -> LinkedDevice?
    /// Dashboard revocation (events, commands, open code go with it). True when the device existed.
    @discardableResult func deleteDevice(id: String) async throws -> Bool
    /// Janitor: expired/used codes, expired links; with `removeAll` (switch off) every link. Returns the number of removed links.
    @discardableResult func purgeLinks(now: Date, removeAll: Bool) async throws -> Int
    /// `last_seen_at` of the installation behind a device, plus its environment (dashboard list, staleness).
    func deviceInstallInfo(id: String) async throws -> DeviceInstallInfo?
}

public struct DeviceInstallInfo: Sendable, Equatable {
    public var env: PushEnvironment
    public var lastSeenAt: Date?
    public init(env: PushEnvironment, lastSeenAt: Date?) { self.env = env; self.lastSeenAt = lastSeenAt }
}

/// Code alphabet and normalisation (Crockford Base32: 32 symbols, no I L O U; 8 symbols = 40 bits).
public enum LinkCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    /// `XXXX-XXXX` from 5 random bytes.
    public static func generate() -> String {
        let bytes = dashboardRandom(5)
        var value: UInt64 = 0
        for b in bytes { value = value << 8 | UInt64(b) }
        var chars: [UInt8] = []
        for i in (0..<8).reversed() { chars.append(alphabet[Int((value >> UInt64(i * 5)) & 31)]) }
        return String(decoding: chars[0..<4], as: UTF8.self) + "-" + String(decoding: chars[4..<8], as: UTF8.self)
    }

    /// Normalizes user input; nil when it is not 8 valid symbols. Case, hyphens and spaces are ignored; O to 0, I and L to 1.
    public static func normalize(_ input: String) -> String? {
        var out: [UInt8] = []
        for b in input.utf8 {
            if b == 0x2D || b == 0x20 { continue }
            var c = b
            if c >= 97 && c <= 122 { c -= 32 }
            if c == 0x4F { c = 0x30 } else if c == 0x49 || c == 0x4C { c = 0x31 }
            guard alphabet.contains(c) else { return nil }
            out.append(c)
        }
        return out.count == 8 ? String(decoding: out, as: UTF8.self) : nil
    }

    public static func hash(_ normalized: String) -> [UInt8] { Array(SHA256.hash(data: Array(normalized.utf8))) }
}
