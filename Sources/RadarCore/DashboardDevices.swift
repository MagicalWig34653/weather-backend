import Foundation

/// Device routes of the dashboard (docs-site/content/dashboard-api.md "Geräte"): list, pairing, state, diagnosis, events, actions
/// through the command table, revocation. Answers never contain installation IDs, tokens, cells, or subscription IDs.
final class DashboardDevices: Sendable {
    let repo: any Repo
    let config: @Sendable () -> Config
    let clock: @Sendable () -> Date
    private let limiter = RateLimiter()

    init(repo: any Repo, config: @escaping @Sendable () -> Config, clock: @escaping @Sendable () -> Date) {
        self.repo = repo; self.config = config; self.clock = clock
    }

    private static func iso(_ date: Date?) -> Any { date.map { TimeUtil.toISO($0) } ?? NSNull() }
    private static func error(_ status: Int, _ code: String, retryAfter: Int? = nil) -> ApiResponse { DashboardApi.error(status, code, retryAfter: retryAfter) }

    static func canonicalUUID(_ text: String) -> String? {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else { return nil }
        return text
    }

    /// nil: not a device route.
    func handle(_ req: DashboardHTTPRequest, _ sub: String, now: Date, audit: any DashboardRepo) async throws -> ApiResponse? {
        guard sub == "/devices" || sub.hasPrefix("/devices/") else { return nil }
        let settings = config().deviceLink
        let parts = sub.split(separator: "/", omittingEmptySubsequences: false).map(String.init)   // ["", "devices", ...]
        let m = req.method
        if parts.count == 2 {
            guard m == "GET" else { return Self.error(405, "not_found") }
            guard limiter.allow("read", limit: 60, window: 60, now: now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
            return try await list(settings: settings, now: now)
        }
        if parts.count == 3, parts[2] == "pairing" {
            return try await pairingWindow(req, settings: settings, now: now)
        }
        if parts.count == 3, parts[2] == "pair" {
            guard m == "POST" else { return Self.error(405, "not_found") }
            return try await pair(req, settings: settings, now: now)
        }
        guard parts.count >= 3, let id = Self.canonicalUUID(parts[2]) else { return Self.error(404, "not_found") }
        guard settings.enabled else { return Self.error(404, "not_found") }
        if parts.count == 3 {
            switch m {
            case "GET":
                guard limiter.allow("read", limit: 60, window: 60, now: now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
                return try await detail(id, settings: settings, now: now)
            case "DELETE":
                if try await repo.deleteDevice(id: id) {
                    try await repo.appendDeviceAudit(action: .deviceUnpair, deviceRef: DashboardValidation.deviceRef(id), outcome: nil, now: now)
                }
                return ApiResponse(status: 204, headers: DashboardApi.apiHeaders, body: [])
            default: return Self.error(405, "not_found")
            }
        }
        guard m == "GET" || parts.count == 5 && parts[3] == "actions" && m == "POST" else { return Self.error(m == "GET" || m == "POST" ? 404 : 405, "not_found") }
        guard limiter.allow("read", limit: 60, window: 60, now: now) || m == "POST" else { return Self.error(429, "rate_limited", retryAfter: 60) }
        switch (parts.count, parts[3]) {
        case (4, "diagnosis"): return try await diagnosis(id, now: now)
        case (4, "subscriptions"): return try await subscriptionStates(id, now: now)
        case (4, "events"): return try await events(id, req.query)
        case (4, "commands"): return try await commands(id, req.query)
        case (5, "commands"): return try await oneCommand(id, parts[4])
        case (5, "actions"): return try await action(id, parts[4], req, settings: settings, now: now)
        default: return Self.error(404, "not_found")
        }
    }

    // MARK: list and detail

    private func deviceJSON(_ device: LinkedDevice, settings: DeviceLinkSettings, now: Date) async throws -> [String: Any] {
        guard let info = try await repo.deviceInstallInfo(id: device.id) else { return [:] }
        let subs = try await repo.subscriptions(installationID: device.installID)
        let events = try await repo.deviceEvents(deviceID: device.id, limit: 5)
        let activities = Dictionary(uniqueKeysWithValues: try await repo.activityTargets(subscriptionIDs: subs.map(\.id)).compactMap { t in t.activity.map { (t.subscription.id, $0) } })
        let pushPaused = (try? await repo.pushPausedSince()) != nil
        let truth = await PushTruth.resolve(repo: repo, now: now)
        var input = PushDiagnosis.Input(pushEnabled: truth.enabled, pushPaused: pushPaused, allowedEnvironments: truth.environments ?? Set(PushEnvironment.allCases),
                                        install: info, subs: subs, activities: activities, recentEvents: events, radar: DeviceRadarView(status: .noSlot), now: now)
        input.pushUnknown = truth.status == .unknown
        let verdict = PushDiagnosis.run(input).verdict
        let summary = PushDiagnosis.summaryCode(verdict, install: info)
        let stale = info.lastSeenAt.map { now.timeIntervalSince($0) > Double(settings.staleDays) * 86400 } ?? true
        return ["id": device.id, "label": device.label, "pairedAt": TimeUtil.toISO(device.pairedAt), "expiresAt": Self.iso(device.expiresAt),
                "lastSeenAt": Self.iso(info.lastSeenAt), "stale": stale, "lastActionAt": Self.iso(device.lastActionAt), "env": info.env.rawValue,
                "summary": ["level": summary.level.rawValue, "code": summary.code]]
    }

    private func list(settings: DeviceLinkSettings, now: Date) async throws -> ApiResponse {
        guard settings.enabled else {
            return DashboardApi.object(200, ["linkEnabled": false, "max": settings.maxDevices, "devices": [Any](), "pairing": pairingJSON(nil, settings: settings)])
        }
        var rows: [[String: Any]] = []
        for device in try await repo.devices() { let row = try await deviceJSON(device, settings: settings, now: now); if !row.isEmpty { rows.append(row) } }
        let end = try await repo.pairingWindowEnd(now: now)
        return DashboardApi.object(200, ["linkEnabled": true, "max": settings.maxDevices, "devices": rows, "pairing": pairingJSON(end, settings: settings)])
    }

    // MARK: pairing window

    static let maxWindowMinutes = 15

    private func pairingJSON(_ end: Date?, settings: DeviceLinkSettings) -> [String: Any] {
        ["open": end != nil, "endsAt": Self.iso(end), "defaultMinutes": settings.windowMinutes, "maxMinutes": Self.maxWindowMinutes]
    }

    private func pairingWindow(_ req: DashboardHTTPRequest, settings: DeviceLinkSettings, now: Date) async throws -> ApiResponse {
        guard req.method == "POST" || req.method == "DELETE" else { return Self.error(405, "not_found") }
        guard limiter.allow("pairing", limit: 6, window: 60, now: now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        if req.method == "DELETE" {
            if try await repo.closePairingWindow(now: now) {
                try await repo.appendDeviceAudit(action: .devicePairingClose, deviceRef: nil, outcome: "manual", now: now)
            }
            return DashboardApi.object(200, ["open": false, "endsAt": NSNull()])
        }
        guard settings.enabled else { return Self.error(409, "link_disabled") }
        var minutes = settings.windowMinutes
        if !req.body.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any] else { return Self.error(400, "validation") }
            if let raw = object["minutes"], !(raw is NSNull) {
                guard let value = jsonWholeNumber(raw), (1...Self.maxWindowMinutes).contains(value) else { return Self.error(400, "validation") }
                minutes = value
            }
        }
        let end = now.addingTimeInterval(Double(minutes) * 60)
        try await repo.openPairingWindow(until: end)
        try await repo.appendDeviceAudit(action: .devicePairingOpen, deviceRef: nil, outcome: "minutes:\(minutes)", now: now)
        return DashboardApi.object(200, ["open": true, "endsAt": TimeUtil.toISO(end)])
    }

    private func detail(_ id: String, settings: DeviceLinkSettings, now: Date) async throws -> ApiResponse {
        guard let device = try await repo.device(id: id), let info = try await repo.deviceInstallInfo(id: id) else { return Self.error(404, "not_found") }
        let subs = try await repo.subscriptions(installationID: device.installID)
        let activities = try await repo.activityTargets(subscriptionIDs: subs.map(\.id)).compactMap { t in t.activity.map { (t.subscription.id, $0) } }
        func ageDays(_ d: Date?) -> Any { d.map { max(0, Int(now.timeIntervalSince($0) / 86400)) } ?? NSNull() }
        let subJSON: [[String: Any]] = subs.enumerated().map { index, s in
            let lock = s.lastSentAt.map { $0.addingTimeInterval(PushEvaluator.repeatLock) }.flatMap { $0 > now ? $0 : nil }
            return ["index": index, "kind": s.kind == .circle ? "circle" : "point", "enabled": s.enabled, "liveActivity": s.liveActivity,
                    "thresholdClass": s.threshold, "leadMinutes": s.leadMinutes, "timeSensitive": s.timeSensitive, "lockUntil": Self.iso(lock),
                    "hysteresis": s.wetSeen]
        }
        let running = activities.first { $0.1.activityToken != nil }?.1
        let reservation = activities.first { $0.1.activityToken == nil }?.1
        let active = running ?? reservation
        let activity: [String: Any] = ["state": running != nil ? "active" : (reservation != nil ? "reserved" : "none"),
                                       "startedAt": Self.iso(active?.startedAt), "endsAt": Self.iso(active?.endsAt), "tokenPresent": running != nil]
        let deviceJSON = try await self.deviceJSON(device, settings: settings, now: now)
        return DashboardApi.object(200, [
            "device": deviceJSON,
            "installation": ["env": info.env.rawValue, "locale": info.locale == "en" ? "en" : "de", "ageDays": ageDays(info.createdAt) as Any,
                             "lastSeenAt": Self.iso(info.lastSeenAt),
                             "deviceToken": ["present": true, "ageDays": ageDays(info.tokenUpdatedAt)],
                             "startToken": ["present": info.hasStartToken, "ageDays": NSNull()]],
            "subscriptions": subJSON, "activity": activity,
            "reservation": ["open": reservation != nil, "ageSeconds": reservation.map { Int(now.timeIntervalSince($0.startedAt)) } as Any? ?? NSNull()],
        ])
    }

    /// Subscriptions with their automaton state and the radar situation of their cell (no cells, coordinates, tokens or IDs in the answer).
    private func subscriptionStates(_ id: String, now: Date) async throws -> ApiResponse {
        guard let device = try await repo.device(id: id) else { return Self.error(404, "not_found") }
        let subs = try await repo.subscriptions(installationID: device.installID)
        let activities = Dictionary(uniqueKeysWithValues: try await repo.activityTargets(subscriptionIDs: subs.map(\.id)).compactMap { t in t.activity.map { (t.subscription.id, $0) } })
        let view = subs.isEmpty ? DeviceRadarView(status: .noSlot) : await DeviceRadarView.load(repo: repo, config: config(), subs: subs, now: now, allowStale: true)
        let run = try? await repo.latestPublished()
        let status: String
        switch view.status { case .ok: status = "ok"; case .noSlot: status = "no_slot"; case .staleRun: status = "stale_run" }
        let rows: [[String: Any]] = subs.enumerated().map { index, s in
            let classes = view.classes[s.id] ?? []
            var cell = "unknown", leadCell = "unknown"
            if view.status == .ok, classes.count == TimeUtil.forecastSlots, classes[0] >= 0 {
                let lead = max(1, min(s.leadMinutes / 5, classes.count - 1))
                cell = classes[0] >= s.threshold ? "wet" : "dry"
                leadCell = classes[0...lead].contains { $0 >= s.threshold } ? "wet" : "dry"
            }
            let lock = s.lastSentAt.map { $0.addingTimeInterval(PushEvaluator.repeatLock) }.flatMap { $0 > now ? $0 : nil }
            let activity = activities[s.id].map { $0.activityToken != nil ? "active" : "reserved" } ?? "none"
            let circle = s.kind == .circle
            var row: [String: Any] = ["index": index, "kind": circle ? "circle" : "point", "enabled": s.enabled, "liveActivity": s.liveActivity, "timeSensitive": s.timeSensitive,
                    "thresholdClass": s.threshold, "leadMinutes": s.leadMinutes,
                    "radiusCells": circle ? (s.radiusCells as Any? ?? NSNull()) : NSNull(), "minSharePercent": circle ? (s.minSharePercent as Any? ?? NSNull()) : NSNull(),
                    "state": s.state == .pending ? "pending" : (s.state == .notified ? "notified" : "dry"), "hysteresis": s.wetSeen,
                    "lastSentAt": Self.iso(s.lastSentAt), "lockUntil": Self.iso(lock), "cell": cell, "leadCell": leadCell, "activity": activity]
            row.merge(PushMeasureJSON.fields(s, measures: view.measures[s.id], radarOK: view.status != .noSlot, width: config().width)) { _, new in new }
            return row
        }
        return DashboardApi.object(200, ["generatedAt": TimeUtil.toISO(now),
                                         "radar": ["status": status, "runAgeSeconds": run.flatMap { $0 }.map { max(0, Int(now.timeIntervalSince($0.nominal))) } as Any? ?? NSNull(),
                                                  "runNominal": view.runNominal.map { TimeUtil.toISO($0) } as Any? ?? NSNull(), "slotIndex": 0,
                                                  "gridWidth": config().width, "gridHeight": config().height] as [String: Any],
                                         "subscriptions": rows])
    }

    private func diagnosis(_ id: String, now: Date) async throws -> ApiResponse {
        guard let device = try await repo.device(id: id), let info = try await repo.deviceInstallInfo(id: id) else { return Self.error(404, "not_found") }
        let cfg = config()
        let subs = try await repo.subscriptions(installationID: device.installID)
        let activities = Dictionary(uniqueKeysWithValues: try await repo.activityTargets(subscriptionIDs: subs.map(\.id)).compactMap { t in t.activity.map { (t.subscription.id, $0) } })
        let events = try await repo.deviceEvents(deviceID: id, limit: 20)
        let radarSubs = subs.filter(\.enabled)
        let view = radarSubs.isEmpty ? DeviceRadarView(status: .noSlot) : await DeviceRadarView.load(repo: repo, config: cfg, subs: radarSubs, now: now)
        let pushPaused = (try? await repo.pushPausedSince()) != nil
        // Push facts come from the radar replicas (this process may run with PUSH_ENABLED=false); only grid and size come from `cfg`.
        let truth = await PushTruth.resolve(repo: repo, now: now)
        var input = PushDiagnosis.Input(pushEnabled: truth.enabled, pushPaused: pushPaused, allowedEnvironments: truth.environments ?? Set(PushEnvironment.allCases),
                                        install: info, subs: subs, activities: activities, recentEvents: events, radar: view, now: now)
        input.pushUnknown = truth.status == .unknown
        let result = PushDiagnosis.run(input)
        func check(_ c: DiagnosisCheck) -> [String: Any] {
            ["order": c.order, "code": c.code, "level": c.level.rawValue, "reason": c.reason, "params": c.params.mapValues(\.json)]
        }
        let verdict: Any = result.verdict.map { ["code": $0.code, "level": $0.level.rawValue] } ?? NSNull()
        return DashboardApi.object(200, ["generatedAt": TimeUtil.toISO(now), "verdict": verdict, "checks": result.checks.map(check)])
    }

    private func events(_ id: String, _ query: [String: String]) async throws -> ApiResponse {
        guard try await repo.device(id: id) != nil else { return Self.error(404, "not_found") }
        var limit = 50
        if let raw = query["limit"] { guard let n = Int(raw), (1...200).contains(n) else { return Self.error(400, "validation") }; limit = n }
        let rows = try await repo.deviceEvents(deviceID: id, limit: limit).map { e -> [String: Any] in
            ["at": TimeUtil.toISO(e.at), "kind": e.kind, "outcome": e.outcome, "reason": e.reason as Any? ?? NSNull()]
        }
        return DashboardApi.object(200, ["events": rows])
    }

    // MARK: pairing

    private func pair(_ req: DashboardHTTPRequest, settings: DeviceLinkSettings, now: Date) async throws -> ApiResponse {
        guard settings.enabled else { return Self.error(409, "link_disabled") }
        guard let body = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any],
              let rawCode = body["code"] as? String, let code = LinkCode.normalize(rawCode),
              let rawLabel = body["label"] as? String else { return Self.error(400, "validation") }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(label.count), !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return Self.error(400, "validation")
        }
        // Budget: 5 unknown codes per minute (global, per replica). The slot is reserved atomically before the check (a burst
        // cannot pass the check before the first failure is counted) and given back unless the code was unknown, so a correct
        // code does not use up the budget. While guessers have used it up, even a correct code gets 429: the check itself is what
        // the limit protects (2^40 codes, 10 minutes, session and CSRF required).
        guard limiter.allow("pair-fail", limit: 5, window: 60, now: now) else { return Self.error(429, "rate_limited", retryAfter: 60) }
        switch try await repo.pairDevice(codeHash: LinkCode.hash(code), label: label, deviceID: UUID().uuidString.lowercased(), now: now,
                                         maxDevices: settings.maxDevices, ttlDays: settings.ttlDays) {
        case .codeUnknown:
            return Self.error(404, "code_unknown")
        case .deviceLimit:
            limiter.refund("pair-fail", window: 60, now: now)
            return Self.error(409, "device_limit")
        case .paired(let device):
            limiter.refund("pair-fail", window: 60, now: now)
            try await repo.appendDeviceAudit(action: .devicePair, deviceRef: DashboardValidation.deviceRef(device.id), outcome: nil, now: now)
            // The window closes after the first successful redemption (the operator can open it again at any time).
            if (try? await repo.closePairingWindow(now: now)) == true {
                try await repo.appendDeviceAudit(action: .devicePairingClose, deviceRef: nil, outcome: "redeemed", now: now)
            }
            return DashboardApi.object(201, try await deviceJSON(device, settings: settings, now: now))
        }
    }

    // MARK: actions and commands

    private static let hourlyLimits: [DeviceCommandKind: Int] = [.test: 3, .laProbe: 3, .laEnd: 6, .resetSlot: 6]

    private func action(_ id: String, _ name: String, _ req: DashboardHTTPRequest, settings: DeviceLinkSettings, now: Date) async throws -> ApiResponse {
        guard let kind = DeviceCommandKind(action: name) else { return Self.error(400, "validation") }
        var dryRun: Bool?
        if let object = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any] {
            if kind == .reeval {
                if let raw = object["dryRun"] { guard let flag = raw as? Bool else { return Self.error(400, "validation") }; dryRun = flag } else { dryRun = true }
            }
        } else { return Self.error(400, "validation") }
        guard try await repo.device(id: id) != nil else { return Self.error(404, "not_found") }
        // Commands are executed by the push leader (a radar replica); without one nothing would ever run them.
        let truth = await PushTruth.resolve(repo: repo, now: now)
        guard truth.leaderActive else {
            return Self.error(503, truth.status == .off ? "push_disabled" : (truth.status == .unknown ? "push_state_unknown" : "push_leader_missing"))
        }
        let limit = kind == .reeval ? (dryRun == true ? 20 : 3) : Self.hourlyLimits[kind]!
        guard limiter.allow("act:\(id):\(kind.rawValue):\(dryRun == false ? "live" : "dry")", limit: limit, window: 3600, now: now) else {
            return Self.error(429, "action_rate_limited", retryAfter: 3600)
        }
        switch try await repo.createCommand(deviceID: id, kind: kind, dryRun: dryRun, now: now) {
        case .deviceGone: return Self.error(404, "not_found")
        case .pending: return Self.error(409, "command_pending")
        case .created(let c):
            return DashboardApi.object(202, ["commandId": c.id, "kind": c.kind.rawValue, "status": c.status.rawValue, "createdAt": TimeUtil.toISO(c.createdAt)])
        }
    }

    private static func commandJSON(_ c: DeviceCommand) -> [String: Any] {
        let result: Any = c.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()
        return ["commandId": c.id, "kind": c.kind.rawValue, "status": c.status.rawValue, "createdAt": TimeUtil.toISO(c.createdAt),
                "startedAt": iso(c.startedAt), "finishedAt": iso(c.finishedAt), "dryRun": c.dryRun as Any? ?? NSNull(),
                "result": c.status == .done ? result : NSNull(), "error": c.error as Any? ?? NSNull()]
    }

    private func oneCommand(_ id: String, _ commandID: String) async throws -> ApiResponse {
        guard let cid = Self.canonicalUUID(commandID), let c = try await repo.command(id: cid, deviceID: id) else { return Self.error(404, "not_found") }
        return DashboardApi.object(200, Self.commandJSON(c))
    }

    private func commands(_ id: String, _ query: [String: String]) async throws -> ApiResponse {
        guard try await repo.device(id: id) != nil else { return Self.error(404, "not_found") }
        var limit = 10
        if let raw = query["limit"] { guard let n = Int(raw), (1...20).contains(n) else { return Self.error(400, "validation") }; limit = n }
        return DashboardApi.object(200, ["commands": try await repo.commands(deviceID: id, limit: limit).map(Self.commandJSON)])
    }
}
