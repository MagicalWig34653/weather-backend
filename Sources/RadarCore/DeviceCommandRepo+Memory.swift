import Foundation

struct MemoryCommandStore {
    var commands: [String: DeviceCommand] = [:]
    var events: [String: [DeviceEvent]] = [:]
    func pendingCount(deviceID: String) -> Int {
        commands.values.filter { $0.deviceID == deviceID && ($0.status == .queued || $0.status == .running) }.count
    }
    /// N1: `running` commands whose leader died become `failed` (`timeout`).
    mutating func reapStuck(now: Date) {
        for (id, c) in commands where c.status == .running && now.timeIntervalSince(c.startedAt ?? c.createdAt) > DeviceRetention.runningTimeoutSeconds {
            commands[id]?.status = .failed
            commands[id]?.finishedAt = now
            commands[id]?.error = "timeout"
        }
    }
    mutating func removeAll(deviceID: String) {
        commands = commands.filter { $0.value.deviceID != deviceID }
        events[deviceID] = nil
    }
}

extension MemoryRepo: DeviceCommandRepo {
    public func createCommand(deviceID: String, kind: DeviceCommandKind, dryRun: Bool?, now: Date) async throws -> CreateCommandResult {
        commandStore.reapStuck(now: now)
        guard let device = deviceStore.devices[deviceID], push.installs[device.installID] != nil else { return .deviceGone }
        if commandStore.commands.values.contains(where: { $0.deviceID == deviceID && $0.kind == kind && ($0.status == .queued || $0.status == .running) }) { return .pending }
        let command = DeviceCommand(id: UUID().uuidString.lowercased(), deviceID: deviceID, kind: kind, dryRun: dryRun, status: .queued, createdAt: now)
        commandStore.commands[command.id] = command
        let own = commandStore.commands.values.filter { $0.deviceID == deviceID }.sorted { $0.createdAt < $1.createdAt }
        for old in own.dropLast(DeviceRetention.maxCommandsPerDevice) { commandStore.commands[old.id] = nil }
        deviceStore.devices[deviceID] = LinkedDevice(id: device.id, installID: device.installID, label: device.label, pairedAt: device.pairedAt,
                                                     expiresAt: device.expiresAt, lastActionAt: now)
        return .created(command)
    }

    public func command(id: String, deviceID: String) async throws -> DeviceCommand? {
        commandStore.commands[id].flatMap { $0.deviceID == deviceID ? $0 : nil }
    }

    public func commands(deviceID: String, limit: Int) async throws -> [DeviceCommand] {
        Array(commandStore.commands.values.filter { $0.deviceID == deviceID }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.prefix(max(0, limit)))
    }

    public func claimNextCommand(now: Date) async throws -> DeviceCommand? {
        commandStore.reapStuck(now: now)
        for (id, c) in commandStore.commands where c.status == .queued && now.timeIntervalSince(c.createdAt) > DeviceRetention.commandExpirySeconds {
            commandStore.commands[id]?.status = .expired
            commandStore.commands[id]?.finishedAt = now
        }
        guard let next = commandStore.commands.values.filter({ $0.status == .queued }).min(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) else { return nil }
        commandStore.commands[next.id]?.status = .running
        commandStore.commands[next.id]?.startedAt = now
        return commandStore.commands[next.id]
    }

    public func finishCommand(id: String, status: DeviceCommandStatus, result: String?, error: String?, now: Date) async throws {
        guard commandStore.commands[id] != nil else { return }
        commandStore.commands[id]?.status = status
        commandStore.commands[id]?.finishedAt = now
        commandStore.commands[id]?.result = result
        commandStore.commands[id]?.error = error
    }

    public func appendDeviceEvent(installationID: String, kind: String, outcome: String, reason: String?, now: Date) async throws {
        guard let device = deviceStore.devices.values.first(where: { $0.installID == installationID }) else { return }
        var list = commandStore.events[device.id] ?? []
        list.append(DeviceEvent(at: now, kind: kind, outcome: outcome, reason: reason.map { String($0.prefix(64)) }))
        commandStore.events[device.id] = Array(list.suffix(DeviceRetention.maxEventsPerDevice))
    }

    public func deviceEvents(deviceID: String, limit: Int) async throws -> [DeviceEvent] {
        Array((commandStore.events[deviceID] ?? []).reversed().prefix(max(0, limit)))
    }

    public func purgeDeviceOps(now: Date) async throws {
        let cutoff = now.addingTimeInterval(-Double(DeviceRetention.commandHours) * 3600)
        commandStore.commands = commandStore.commands.filter { $0.value.createdAt >= cutoff }
        for (id, list) in commandStore.events { commandStore.events[id] = list.filter { $0.at >= cutoff } }
    }
}
