import Foundation
import Testing
@testable import RadarCore

// Device link (WP13a): codes, pairing, limits, revocation, app routes. Memory and MariaDB (RADAR_TEST_DB_HOST).
private let installA = "11111111-1111-4111-8111-111111111111"
private let installB = "22222222-2222-4222-8222-222222222222"
private let installC = "33333333-3333-4333-8333-333333333333"
private let secret = String(repeating: "a", count: 40)
private let token = String(repeating: "ab", count: 32)
private let base = "/v1/push/installations/"

private func register(_ repo: any Repo, _ id: String, now: Date = Date()) async throws {
    _ = try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array(secret.utf8)), token: token + id.prefix(2), env: .sandbox,
                                          locale: "de", now: now, maxInstallations: 100)
}

extension DatabaseSuites {
@Suite("Device link", .serialized)
struct DeviceLinkTests {
    @Test func codeAlphabetAndNormalisation() {
        for _ in 0..<200 {
            let code = LinkCode.generate()
            #expect(code.count == 9 && code[code.index(code.startIndex, offsetBy: 4)] == "-")
            #expect(LinkCode.normalize(code)?.count == 8)
            #expect(!code.contains(where: { "ILOU".contains($0) }))
        }
        #expect(LinkCode.normalize("abcd efgh") == "ABCDEFGH")
        #expect(LinkCode.normalize("0O1I-LLoo") == "00111100")
        #expect(LinkCode.normalize("ABCD-EFG") == nil && LinkCode.normalize("ABCD-EFGU") == nil && LinkCode.normalize("ABCD-EFGHJ") == nil)
        #expect(LinkCode.hash("ABCDEFGH").count == 32)
    }

    @Test(arguments: RepoKind.allCases) func pairingIsOneShotAndNeedsAttestation(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date()
        try await register(repo, installA, now: now)
        let hash = LinkCode.hash("ABCDEFGH")
        #expect(try await repo.createLinkCode(installationID: installA, codeHash: hash, attested: false, now: now, ttl: 600, maxDevices: 3) == .created)
        #expect(try await repo.linkState(installationID: installA, now: now).kind == .codeOpen)
        // Not attested: unknown. Wrong code, expired code: unknown.
        #expect(try await repo.pairDevice(codeHash: hash, label: "x", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 3, ttlDays: 0) == .codeUnknown)
        let good = LinkCode.hash("2345ABCD")
        #expect(try await repo.createLinkCode(installationID: installA, codeHash: good, attested: true, now: now, ttl: 600, maxDevices: 3) == .created)
        // The new code replaced the old one.
        #expect(try await repo.pairDevice(codeHash: hash, label: "x", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 3, ttlDays: 0) == .codeUnknown)
        #expect(try await repo.pairDevice(codeHash: good, label: "x", deviceID: UUID().uuidString.lowercased(), now: now.addingTimeInterval(601), maxDevices: 3, ttlDays: 0) == .codeUnknown)
        let id = UUID().uuidString.lowercased()
        guard case .paired(let device) = try await repo.pairDevice(codeHash: good, label: "Mein iPhone", deviceID: id, now: now, maxDevices: 3, ttlDays: 0) else {
            Issue.record("pairing failed"); return
        }
        #expect(device.id == id && device.expiresAt == nil && device.label == "Mein iPhone")
        #expect(try await repo.pairDevice(codeHash: good, label: "again", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 3, ttlDays: 0) == .codeUnknown)
        let state = try await repo.linkState(installationID: installA, now: now)
        #expect(state.kind == .linked && state.expiresAt == nil && state.codeExpiresAt == nil)
        #expect(try await repo.createLinkCode(installationID: installA, codeHash: LinkCode.hash("ZZZZZZZZ"), attested: true, now: now, ttl: 600, maxDevices: 3) == .alreadyLinked)
        let info = try #require(try await repo.deviceInstallInfo(id: id))
        #expect(info.env == .sandbox)
    }

    @Test(arguments: RepoKind.allCases) func limitTtlAndRevocation(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date()
        for id in [installA, installB, installC] { try await register(repo, id, now: now) }
        var ids: [String] = []
        for (i, install) in [installA, installB].enumerated() {
            let hash = LinkCode.hash("2345ABC" + String(i))
            #expect(try await repo.createLinkCode(installationID: install, codeHash: hash, attested: true, now: now, ttl: 600, maxDevices: 2) == .created)
            let id = UUID().uuidString.lowercased(); ids.append(id)
            guard case .paired = try await repo.pairDevice(codeHash: hash, label: "d\(i)", deviceID: id, now: now, maxDevices: 2, ttlDays: i == 0 ? 0 : 1) else {
                Issue.record("pairing \(i) failed"); return
            }
        }
        // Limit reached: no new code, and a code made earlier cannot be redeemed beyond the limit.
        #expect(try await repo.createLinkCode(installationID: installC, codeHash: LinkCode.hash("ZZZZ0000"), attested: true, now: now, ttl: 600, maxDevices: 2) == .linkFull)
        #expect(try await repo.createLinkCode(installationID: installC, codeHash: LinkCode.hash("ZZZZ0001"), attested: true, now: now, ttl: 600, maxDevices: 3) == .created)
        #expect(try await repo.pairDevice(codeHash: LinkCode.hash("ZZZZ0001"), label: "c", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 2, ttlDays: 0) == .deviceLimit)
        #expect(try await repo.devices().count == 2)
        // TTL (optional): the second device expires after a day, the first never.
        #expect(try await repo.purgeLinks(now: now.addingTimeInterval(2 * 86400), removeAll: false) == 1)
        #expect(try await repo.devices().map(\.id) == [ids[0]])
        // Dashboard revocation, idempotent.
        #expect(try await repo.deleteDevice(id: ids[0]) == true)
        #expect(try await repo.deleteDevice(id: ids[0]) == false)
        #expect(try await repo.linkState(installationID: installA, now: now).kind == .none)
        // App revocation and cascade on installation delete.
        let h = LinkCode.hash("QQQQ0000")
        _ = try await repo.createLinkCode(installationID: installA, codeHash: h, attested: true, now: now, ttl: 600, maxDevices: 3)
        _ = try await repo.pairDevice(codeHash: h, label: "again", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 3, ttlDays: 0)
        try await repo.unlink(installationID: installA)
        try await repo.unlink(installationID: installA)   // idempotent
        #expect(try await repo.linkState(installationID: installA, now: now).kind == .none)
        let h2 = LinkCode.hash("QQQQ0001")
        _ = try await repo.createLinkCode(installationID: installA, codeHash: h2, attested: true, now: now, ttl: 600, maxDevices: 3)
        _ = try await repo.pairDevice(codeHash: h2, label: "x", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 3, ttlDays: 0)
        try await repo.deleteInstallation(id: installA)
        #expect(try await repo.devices().allSatisfy { $0.installID != installA })
        // Switch off removes every link.
        let removed = try await repo.purgeLinks(now: now, removeAll: true)
        let left = try await repo.devices()
        #expect(removed >= 0 && left.isEmpty)
    }

    @Test(arguments: RepoKind.allCases) func parallelRedemptionsRespectTheLimit(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date()
        let installs = (0..<4).map { String(format: "%08d-0000-4000-8000-000000000000", $0 + 10) }
        for id in installs { try await register(repo, id, now: now) }
        for (i, id) in installs.enumerated() {
            _ = try await repo.createLinkCode(installationID: id, codeHash: LinkCode.hash("PAR0000" + String(i)), attested: true, now: now, ttl: 600, maxDevices: 9)
        }
        let results = try await withThrowingTaskGroup(of: PairDeviceResult.self) { group in
            for i in 0..<4 {
                group.addTask { try await repo.pairDevice(codeHash: LinkCode.hash("PAR0000" + String(i)), label: "p\(i)", deviceID: UUID().uuidString.lowercased(), now: now, maxDevices: 2, ttlDays: 0) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let paired = results.filter { if case .paired = $0 { return true } else { return false } }.count
        #expect(paired == 2 && results.contains(.deviceLimit))
        #expect(try await repo.devices().count == 2)
    }

    @Test(arguments: RepoKind.allCases) func commandsAndEventsContract(kind: RepoKind) async throws {
        let repo = try await kind.make(); let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try await register(repo, installA, now: now)
        let hash = LinkCode.hash("CMD00000")
        _ = try await repo.createLinkCode(installationID: installA, codeHash: hash, attested: true, now: now, ttl: 600, maxDevices: 3)
        let id = UUID().uuidString.lowercased()
        guard case .paired = try await repo.pairDevice(codeHash: hash, label: "d", deviceID: id, now: now, maxDevices: 3, ttlDays: 0) else { Issue.record("pair"); return }
        // Unknown device, duplicates of one kind, other kinds in parallel.
        #expect(try await repo.createCommand(deviceID: UUID().uuidString.lowercased(), kind: .test, dryRun: nil, now: now) == .deviceGone)
        guard case .created(let first) = try await repo.createCommand(deviceID: id, kind: .test, dryRun: nil, now: now) else { Issue.record("create"); return }
        #expect(try await repo.createCommand(deviceID: id, kind: .test, dryRun: nil, now: now) == .pending)
        guard case .created = try await repo.createCommand(deviceID: id, kind: .reeval, dryRun: true, now: now.addingTimeInterval(1)) else { Issue.record("reeval"); return }
        #expect(try await repo.linkState(installationID: installA, now: now).pendingCommands == 2)
        #expect(try await repo.device(id: id)?.lastActionAt != nil)
        // Claim: oldest first, queued -> running, finish stores the result.
        let claimed = try #require(try await repo.claimNextCommand(now: now.addingTimeInterval(2)))
        #expect(claimed.id == first.id && claimed.status == .running)
        try await repo.finishCommand(id: first.id, status: .done, result: #"{"outcome":"delivered"}"#, error: nil, now: now.addingTimeInterval(3))
        let loaded = try #require(try await repo.command(id: first.id, deviceID: id))
        #expect(loaded.status == .done && loaded.result == #"{"outcome":"delivered"}"# && loaded.finishedAt != nil)
        #expect(try await repo.command(id: first.id, deviceID: UUID().uuidString.lowercased()) == nil)
        // Expiry after 120 s.
        #expect(try await repo.claimNextCommand(now: now.addingTimeInterval(200)) == nil)
        let all = try await repo.commands(deviceID: id, limit: 10)
        #expect(all.count == 2 && all.first?.kind == .reeval && all.first?.status == .expired)
        // Events only for linked devices, newest first, capped at 200.
        try await repo.appendDeviceEvent(installationID: installB, kind: "test", outcome: "delivered", reason: nil, now: now)
        for i in 0..<205 { try await repo.appendDeviceEvent(installationID: installA, kind: i == 204 ? "probe" : "test", outcome: "delivered", reason: i == 204 ? "x" : nil, now: now.addingTimeInterval(Double(i))) }
        let events = try await repo.deviceEvents(deviceID: id, limit: 500)
        #expect(events.count == 200 && events.first?.kind == "probe" && events.first?.reason == "x")
        // Retention.
        try await repo.purgeDeviceOps(now: now.addingTimeInterval(49 * 3600))
        let purgedEvents = try await repo.deviceEvents(deviceID: id, limit: 5)
        let purgedCommands = try await repo.commands(deviceID: id, limit: 5)
        #expect(purgedEvents.isEmpty && purgedCommands.isEmpty)
        // Cascade with the device.
        _ = try await repo.createCommand(deviceID: id, kind: .laEnd, dryRun: nil, now: now)
        #expect(try await repo.deleteDevice(id: id))
        let afterDelete = try await repo.commands(deviceID: id, limit: 5)
        #expect(afterDelete.isEmpty)
        // Audit columns.
        try await repo.appendDeviceAudit(action: .deviceAction, deviceRef: "abcd1234", outcome: "test:delivered", now: now)
        let audit = try #require(try await repo.auditEntries(limit: 1).first)
        #expect(audit.action == .deviceAction && audit.deviceRef == "abcd1234" && audit.outcome == "test:delivered")
    }

    // MARK: app routes

    private func api(_ repo: MemoryRepo, enabled: Bool = true, chain: TestChain, stats: StatsCollector = StatsCollector()) -> PushApi {
        var c = smallConfig { $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.deviceLink.enabled = enabled }
        c.width = 64
        let verifier = AppTransactionVerifier(roots: [chain.root], bundleID: "de.example.app")
        return PushApi(repo: repo, configProvider: ConfigProvider(c), clock: { Date() }, stats: stats, appTransactionVerifier: verifier)
    }

    private func call(_ api: PushApi, _ method: String, _ route: String, body: Any? = nil, secret: String? = secret) async throws -> (Int, [String: Any]) {
        let bytes = try body.map { Array(try JSONSerialization.data(withJSONObject: $0)) } ?? []
        let r = try #require(await api.handle(method: method, path: base + installA + "/" + route, secret: secret, body: bytes))
        return (r.status, (try? JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any]) ?? [:])
    }

    @Test func appRoutesLifecycle() async throws {
        let repo = MemoryRepo(); try await register(repo, installA)
        let chain = try TestChain(); let stats = StatsCollector()
        let api = api(repo, chain: chain, stats: stats)
        let none = try await call(api, "GET", "link")
        #expect(none.0 == 200 && none.1["state"] as? String == "none" && none.1["linked_at"] is NSNull && none.1["pending_commands"] as? Int == 0)
        #expect(try await call(api, "GET", "link", secret: String(repeating: "b", count: 40)).0 == 401)
        #expect(try await call(api, "POST", "link-code", body: [:]).0 == 400)
        // Production proof, wrong bundle: 403 uniformly, counted by reason.
        let prod = try await call(api, "POST", "link-code", body: ["app_transaction": try chain.jws(receiptType: "Production")])
        #expect(prod.0 == 403 && prod.1["error"] as? String == "not_testflight")
        #expect(try await call(api, "POST", "link-code", body: ["app_transaction": try chain.jws(bundleID: "de.other")]).0 == 403)
        #expect(try await call(api, "POST", "link-code", body: ["app_transaction": "garbage"]).0 == 403)
        let rejects = stats.pending().filter { $0.metric == "device_link_reject" }.map { "\($0.label)=\($0.value)" }.sorted()
        #expect(rejects == ["bundle=1", "production=1", "unverified=1"])
        let ok = try await call(api, "POST", "link-code", body: ["app_transaction": try chain.jws()])
        #expect(ok.0 == 201 && ok.1["ttl_seconds"] as? Int == 600)
        let code = try #require(ok.1["code"] as? String)
        #expect(LinkCode.normalize(code) != nil)
        #expect(try await call(api, "GET", "link").1["state"] as? String == "code_open")
        // Pair, then app sees `linked`, a new code is refused, DELETE revokes.
        let hash = LinkCode.hash(try #require(LinkCode.normalize(code)))
        _ = try await repo.pairDevice(codeHash: hash, label: "iPhone", deviceID: UUID().uuidString.lowercased(), now: Date(), maxDevices: 3, ttlDays: 0)
        let linked = try await call(api, "GET", "link")
        #expect(linked.1["state"] as? String == "linked" && linked.1["expires_at"] is NSNull && linked.1["label"] == nil)
        #expect(try await call(api, "DELETE", "link").0 == 204)
        #expect(try await call(api, "DELETE", "link").0 == 204)
        #expect(try await call(api, "GET", "link").1["state"] as? String == "none")
        // Rate limit: 6 codes per hour (4 used above incl. rejects counted? only attempts that passed auth count).
        var limited = false
        for _ in 0..<8 { if try await call(api, "POST", "link-code", body: ["app_transaction": try chain.jws()]).0 == 429 { limited = true; break } }
        #expect(limited)
    }

    @Test func disabledSwitchAndCapabilityAnd404() async throws {
        let repo = MemoryRepo(); try await register(repo, installA)
        let chain = try TestChain()
        let off = api(repo, enabled: false, chain: chain)
        let r = await off.handle(method: "GET", path: base + installA + "/link", secret: secret, body: [])
        #expect(r == nil)   // caller answers 404
        let big = try #require(await api(repo, chain: chain).handle(method: "POST", path: base + installA + "/link-code", secret: secret, body: [UInt8](repeating: 65, count: 9000)))
        #expect(big.status == 413)
    }

    @Test func statusAnnouncesCapability() async throws {
        var c = smallConfig { $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.deviceLink.enabled = true }
        c.width = 64
        let a = Api(repo: MemoryRepo(), config: c)
        let r = try await a.handle(path: "/v1/status", ifNoneMatch: nil)
        let caps = (try JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any])?["capabilities"] as? [String]
        #expect(caps == ["regions", "live_activity", "device_link"])
        c.deviceLink.enabled = false
        let b = try await Api(repo: MemoryRepo(), config: c).handle(path: "/v1/status", ifNoneMatch: nil)
        #expect((try JSONSerialization.jsonObject(with: Data(b.body)) as? [String: Any])?["capabilities"] as? [String] == ["regions", "live_activity"])
    }
}
}
