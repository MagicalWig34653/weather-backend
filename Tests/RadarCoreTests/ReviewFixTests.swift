import Foundation
import Testing
@testable import RadarCore

// Regression tests for the security review of 6 Nov 2026 (docs/research/security-review-dashboard-2026-11-06.md): N1, N3, N4.
private let installA = "11111111-1111-4111-8111-111111111111"
private let secretHash = Hashing.sha256Hex(Array(String(repeating: "a", count: 40).utf8))
private let origin = "https://dash.example.test"

private func linkedDevice(_ repo: any Repo, now: Date, code: String = "REV00000") async throws -> String {
    _ = try await repo.upsertInstallation(id: installA, secretHash: secretHash, token: String(repeating: "ab", count: 32), env: .sandbox,
                                          locale: "de", now: now, maxInstallations: 10)
    let hash = LinkCode.hash(code)
    _ = try await repo.createLinkCode(installationID: installA, codeHash: hash, attested: true, now: now, ttl: 600, maxDevices: 3)
    let id = UUID().uuidString.lowercased()
    guard case .paired = try await repo.pairDevice(codeHash: hash, label: "d", deviceID: id, now: now, maxDevices: 3, ttlDays: 0) else {
        Issue.record("pairing failed"); return id
    }
    return id
}

extension DatabaseSuites {
@Suite("Review fixes WP18", .serialized)
struct ReviewFixTests {
    /// N1: a command left `running` by a crashed leader must not block the action for 48 hours.
    @Test(arguments: RepoKind.allCases) func stuckRunningCommandTimesOut(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let id = try await linkedDevice(repo, now: now)
        guard case .created(let stuck) = try await repo.createCommand(deviceID: id, kind: .test, dryRun: nil, now: now) else { Issue.record("create"); return }
        _ = try await repo.claimNextCommand(now: now.addingTimeInterval(1))   // leader dies here
        #expect(try await repo.createCommand(deviceID: id, kind: .test, dryRun: nil, now: now.addingTimeInterval(60)) == .pending)
        let later = now.addingTimeInterval(DeviceRetention.runningTimeoutSeconds + 5)
        guard case .created = try await repo.createCommand(deviceID: id, kind: .test, dryRun: nil, now: later) else {
            Issue.record("action still blocked after the timeout"); return
        }
        let old = try #require(try await repo.command(id: stuck.id, deviceID: id))
        #expect(old.status == .failed && old.error == "timeout" && old.finishedAt != nil)
    }

    @Test(arguments: RepoKind.allCases) func claimAlsoReapsStuckRunningCommands(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let id = try await linkedDevice(repo, now: now)
        guard case .created(let stuck) = try await repo.createCommand(deviceID: id, kind: .laEnd, dryRun: nil, now: now) else { Issue.record("create"); return }
        _ = try await repo.claimNextCommand(now: now.addingTimeInterval(1))
        #expect(try await repo.claimNextCommand(now: now.addingTimeInterval(DeviceRetention.runningTimeoutSeconds + 5)) == nil)
        #expect(try await repo.command(id: stuck.id, deviceID: id)?.status == .failed)
    }

    /// N4: a leader whose environment lacks DEVICE_LINK_ENABLED must not wipe the links. Only an explicit `false` removes them.
    @Test func janitorKeepsLinksWhenSwitchIsMerelyMissing() async throws {
        let repo = MemoryRepo(); let now = Date()
        _ = try await linkedDevice(repo, now: now)
        let missing = smallConfig { $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox] }
        #expect(!missing.deviceLink.enabled && !missing.deviceLink.explicitlyDisabled)
        let service = PushService(config: missing, repo: repo, sender: FakeApnsSender(), owner: "t", clock: { now.addingTimeInterval(7200) })
        _ = try await service.tick()
        #expect(try await repo.devices().count == 1)
        await service.release()

        let off = smallConfig { $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox]
            $0.deviceLink.explicitlyDisabled = true }
        let offService = PushService(config: off, repo: repo, sender: FakeApnsSender(), owner: "t2", clock: { now.addingTimeInterval(7200) })
        _ = try await offService.tick()
        #expect(try await repo.devices().isEmpty)
    }

    @Test func environmentDistinguishesMissingFromFalse() throws {
        func loaded(_ value: String?) throws -> DeviceLinkSettings {
            var env: [String: String] = [:]
            if let value { env["DEVICE_LINK_ENABLED"] = value }
            return try Config.fromEnvironment(env).deviceLink
        }
        #expect(try loaded(nil).explicitlyDisabled == false)
        #expect(try loaded("").explicitlyDisabled == false)
        #expect(try loaded("false").explicitlyDisabled)
        #expect(try loaded("FALSE").explicitlyDisabled)
        #expect(try loaded("true").explicitlyDisabled == false && loaded("true").enabled)
    }
}
}

/// N3 (outside the database suite: memory only).
@Suite("Review fixes WP18 pairing limit")
struct PairingLimitTests {
    private func api() async throws -> (DashboardApi, MemoryRepo, String, String) {
        let c = smallConfig { $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox]; $0.deviceLink.enabled = true }
        let repo = MemoryRepo()
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
        let api = DashboardApi(auth: auth, repo: repo, store: ConfigStore(fixed: c), staticRoot: "/nonexistent")
        _ = try await repo.insertCredential(credentialID: [1], publicKey: [2], signCount: 0, now: Date())
        let created = try await auth.sessions.create()
        return (api, repo, "__Host-dash_session=" + created.cookieValue, created.csrfToken)
    }

    private func pair(_ api: DashboardApi, _ cookie: String, _ csrf: String, code: String) async -> Int {
        let info = DashboardRequestInfo(method: "POST", cookieHeader: cookie, origin: origin, host: "dash.example.test", contentType: "application/json", csrfToken: csrf)
        let body = Array(#"{"code":"\#(code)","label":"x"}"#.utf8)
        return await api.handle(DashboardHTTPRequest(method: "POST", path: "/dash/api/devices/pair", query: [:], body: body, info: info)).status
    }

    /// The check and the count were two steps: a burst passed the check before the first failure was recorded.
    @Test func burstOfGuessesIsCappedAtFive() async throws {
        let (api, _, cookie, csrf) = try await api()
        let statuses = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<40 { group.addTask { await self.pair(api, cookie, csrf, code: "ABCDEFGH") } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses.filter { $0 == 404 }.count == 5 && statuses.filter { $0 == 429 }.count == 35)
    }

    /// A correct code is not counted as a failure: a legitimate pairing works after four wrong guesses and does not use up the budget.
    @Test func correctCodeWorksAfterFourFailuresAndIsNotCounted() async throws {
        let (api, repo, cookie, csrf) = try await api()
        _ = try await repo.upsertInstallation(id: installA, secretHash: secretHash, token: String(repeating: "ab", count: 32), env: .sandbox,
                                              locale: "de", now: Date(), maxInstallations: 10)
        _ = try await repo.createLinkCode(installationID: installA, codeHash: LinkCode.hash("2345ABCD"), attested: true, now: Date(), ttl: 600, maxDevices: 9)
        for _ in 0..<4 { #expect(await pair(api, cookie, csrf, code: "ABCDEFGH") == 404) }
        #expect(await pair(api, cookie, csrf, code: "2345ABCD") == 201)
        #expect(await pair(api, cookie, csrf, code: "ABCDEFGH") == 404)   // the 5th failure, still allowed
        #expect(await pair(api, cookie, csrf, code: "ABCDEFGH") == 429)
    }
}

/// N6: small deviations (memory only).
@Suite("Review fixes WP18 details")
struct ReviewDetailTests {
    @Test func originIsNormalisedToLowerCase() throws {
        let c = DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "HTTPS://Dash.Example.Test:8443"])
        #expect(c?.origin == "https://dash.example.test:8443" && c?.rpID == "dash.example.test")
        // A browser sends the lower case origin, so the write check must pass.
        let info = DashboardRequestInfo(method: "POST", cookieHeader: nil, origin: "https://dash.example.test:8443", host: "dash.example.test:8443",
                                        contentType: "application/json", csrfToken: nil)
        try DashboardSessions(repo: MemoryRepo(), config: c!, clock: { Date() }).checkWriteOrigin(info)
    }

    @Test func warnThresholdsKeepYellowBeforeRed() throws {
        // Rising metrics: yellow < red.
        #expect(throws: ConfigWriteError.self) {
            try ConfigRegistry.validateWrite(key: "DASH_WARN_ERROR_RATE_5XX_YELLOW", raw: "0.5", env: [:], stored: [:])   // default red 0.02
        }
        #expect(throws: ConfigWriteError.self) {
            try ConfigRegistry.validateWrite(key: "DASH_WARN_OUTBOX_AGE_SECONDS_RED", raw: "60", env: [:], stored: [:])    // default yellow 120
        }
        _ = try ConfigRegistry.validateWrite(key: "DASH_WARN_ERROR_RATE_5XX_YELLOW", raw: "0.01", env: [:], stored: [:])
        // Falling metrics (lower bound): yellow > red.
        #expect(throws: ConfigWriteError.self) {
            try ConfigRegistry.validateWrite(key: "DASH_WARN_CACHE_HIT_YELLOW", raw: "0.4", env: [:], stored: [:])         // default red 0.5
        }
        _ = try ConfigRegistry.validateWrite(key: "DASH_WARN_CACHE_HIT_YELLOW", raw: "0.9", env: [:], stored: [:])
        // The stored partner counts, an ENV value too.
        #expect(throws: ConfigWriteError.self) {
            try ConfigRegistry.validateWrite(key: "DASH_WARN_CAP_FILL_RED", raw: "0.7", env: [:], stored: ["DASH_WARN_CAP_FILL_YELLOW": "0.75"])
        }
        #expect(throws: ConfigWriteError.self) {
            try ConfigRegistry.validateWrite(key: "DASH_WARN_CAP_FILL_YELLOW", raw: "0.9", env: ["DASH_WARN_CAP_FILL_RED": "0.85"], stored: [:])
        }
    }
}
