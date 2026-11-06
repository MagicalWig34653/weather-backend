import Foundation

struct MemoryDeviceStore {
    struct Code { var installID: String; var attested: Bool; var expiresAt: Date; var usedAt: Date? }
    var codes: [[UInt8]: Code] = [:]
    var devices: [String: LinkedDevice] = [:]
    var pairingUntil: Date?
}

extension MemoryRepo: DeviceLinkRepo {
    /// Cascade of `push_install` (ON DELETE CASCADE in MariaDB): rows of vanished installations are dropped on access.
    private func prune() {
        deviceStore.devices = deviceStore.devices.filter { push.installs[$0.value.installID] != nil }
        deviceStore.codes = deviceStore.codes.filter { push.installs[$0.value.installID] != nil }
    }

    public func createLinkCode(installationID: String, codeHash: [UInt8], attested: Bool, now: Date, ttl: TimeInterval, maxDevices: Int) async throws -> CreateLinkCodeResult {
        prune()
        guard push.installs[installationID] != nil else { return .unknownInstallation }
        if deviceStore.devices.values.contains(where: { $0.installID == installationID }) { return .alreadyLinked }
        if deviceStore.devices.count >= maxDevices { return .linkFull }
        deviceStore.codes = deviceStore.codes.filter { $0.value.installID != installationID && $0.value.expiresAt > now }
        deviceStore.codes[codeHash] = .init(installID: installationID, attested: attested, expiresAt: now.addingTimeInterval(ttl), usedAt: nil)
        return .created
    }

    public func linkState(installationID: String, now: Date) async throws -> DeviceLinkState {
        prune()
        if let device = deviceStore.devices.values.first(where: { $0.installID == installationID }) {
            let pending = commandStore.pendingCount(deviceID: device.id)
            return DeviceLinkState(kind: .linked, linkedAt: device.pairedAt, expiresAt: device.expiresAt, lastActionAt: device.lastActionAt, pendingCommands: pending)
        }
        if let code = deviceStore.codes.values.first(where: { $0.installID == installationID && $0.usedAt == nil && $0.expiresAt > now }) {
            return DeviceLinkState(kind: .codeOpen, codeExpiresAt: code.expiresAt)
        }
        return DeviceLinkState(kind: .none)
    }

    public func unlink(installationID: String) async throws {
        for (id, device) in deviceStore.devices where device.installID == installationID { removeDeviceData(id) }
        deviceStore.codes = deviceStore.codes.filter { $0.value.installID != installationID }
    }

    public func pairDevice(codeHash: [UInt8], label: String, deviceID: String, now: Date, maxDevices: Int, ttlDays: Int) async throws -> PairDeviceResult {
        prune()
        guard let code = deviceStore.codes[codeHash], code.attested, code.usedAt == nil, code.expiresAt > now,
              !deviceStore.devices.values.contains(where: { $0.installID == code.installID }) else { return .codeUnknown }
        guard deviceStore.devices.count < maxDevices else { return .deviceLimit }
        let device = LinkedDevice(id: deviceID, installID: code.installID, label: label, pairedAt: now,
                                  expiresAt: ttlDays > 0 ? now.addingTimeInterval(Double(ttlDays) * 86400) : nil, lastActionAt: nil)
        deviceStore.devices[deviceID] = device
        deviceStore.codes[codeHash]?.usedAt = now
        return .paired(device)
    }

    public func devices() async throws -> [LinkedDevice] {
        prune()
        return deviceStore.devices.values.sorted { ($0.pairedAt, $0.id) < ($1.pairedAt, $1.id) }
    }

    public func device(id: String) async throws -> LinkedDevice? { prune(); return deviceStore.devices[id] }

    public func deleteDevice(id: String) async throws -> Bool {
        guard let device = deviceStore.devices[id] else { return false }
        removeDeviceData(id)
        deviceStore.codes = deviceStore.codes.filter { $0.value.installID != device.installID }
        return true
    }

    public func purgeLinks(now: Date, removeAll: Bool) async throws -> Int {
        prune()
        deviceStore.codes = deviceStore.codes.filter { $0.value.usedAt == nil && $0.value.expiresAt > now }
        let doomed = deviceStore.devices.values.filter { removeAll || ($0.expiresAt.map { $0 <= now } ?? false) }
        for d in doomed { removeDeviceData(d.id) }
        return doomed.count
    }

    public func deviceInstallInfo(id: String) async throws -> DeviceInstallInfo? {
        guard let device = deviceStore.devices[id], let install = push.installs[device.installID] else { return nil }
        return DeviceInstallInfo(installID: device.installID, env: install.env, locale: install.locale, createdAt: install.createdAt,
                                 lastSeenAt: install.lastSeenAt, tokenUpdatedAt: install.lastSeenAt, hasStartToken: install.liveActivityStartToken != nil)
    }

    func removeDeviceData(_ deviceID: String) {
        deviceStore.devices[deviceID] = nil
        commandStore.removeAll(deviceID: deviceID)
    }
}
