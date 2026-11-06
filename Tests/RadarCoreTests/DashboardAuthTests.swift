import Crypto
import Foundation
import Testing
@testable import RadarCore

// Passkey authentication, sessions, CSRF, rate limits (WP4). A fake authenticator (CryptoKit P-256, attestation "none") drives
// the real WebAuthn verification. Memory and MariaDB (when RADAR_TEST_DB_HOST is set) share the same contract.

private let origin = "https://dash.example.test"
private let rpID = "dash.example.test"

// MARK: minimal CBOR (just what the fake authenticator needs)

private func head(_ major: UInt8, _ value: Int) -> [UInt8] {
    let m = major << 5
    if value < 24 { return [m | UInt8(value)] }
    if value < 256 { return [m | 24, UInt8(value)] }
    return [m | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
}
private func cInt(_ v: Int) -> [UInt8] { v >= 0 ? head(0, v) : head(1, -1 - v) }
private func cBytes(_ b: [UInt8]) -> [UInt8] { head(2, b.count) + b }
private func cText(_ s: String) -> [UInt8] { head(3, s.utf8.count) + Array(s.utf8) }
private func cMap(_ pairs: [([UInt8], [UInt8])]) -> [UInt8] { head(5, pairs.count) + pairs.flatMap { $0.0 + $0.1 } }

private func b64(_ b: [UInt8]) -> String { DashboardBase64URL.encode(b) }

// MARK: fake authenticator

private final class FakeAuthenticator: @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    let credentialID: [UInt8]
    init(id: UInt8 = 7) { credentialID = (0..<32).map { UInt8(truncatingIfNeeded: Int($0) &* 5 &+ Int(id)) } }

    private func rpHash(_ id: String) -> [UInt8] { Array(SHA256.hash(data: Array(id.utf8))) }
    private func counter(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }

    private func clientData(type: String, challenge: String, origin: String) -> [UInt8] {
        Array("{\"type\":\"\(type)\",\"challenge\":\"\(challenge)\",\"origin\":\"\(origin)\",\"crossOrigin\":false}".utf8)
    }

    private var coseKey: [UInt8] {
        let raw = [UInt8](key.publicKey.rawRepresentation) // x || y
        return cMap([(cInt(1), cInt(2)), (cInt(3), cInt(-7)), (cInt(-1), cInt(1)),
                     (cInt(-2), cBytes(Array(raw[0..<32]))), (cInt(-3), cBytes(Array(raw[32..<64])))])
    }

    /// Body of `setup/finish`.
    func registration(challengeID: String, challenge: String, origin: String = origin, rpID: String = rpID,
                      flags: UInt8 = 0x45, signCount: UInt32 = 0) -> [UInt8] {
        var authData: [UInt8] = rpHash(rpID)
        authData.append(flags)
        authData += counter(signCount)
        authData += [UInt8](repeating: 0, count: 16)
        authData += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xFF)]
        authData += credentialID
        authData += coseKey
        let attStmt: [([UInt8], [UInt8])] = [(cText("fmt"), cText("none")), (cText("attStmt"), cMap([])), (cText("authData"), cBytes(authData))]
        let attestation = cMap(attStmt)
        let clientDataB64: String = b64(clientData(type: "webauthn.create", challenge: challenge, origin: origin))
        let response: [String: Any] = ["clientDataJSON": clientDataB64, "attestationObject": b64(attestation), "transports": ["internal"]]
        let credential: [String: Any] = ["id": b64(credentialID), "rawId": b64(credentialID), "type": "public-key", "response": response]
        let body: [String: Any] = ["challengeId": challengeID, "credential": credential]
        return json(body)
    }

    /// Body of `login/finish`.
    func assertion(challengeID: String, challenge: String, signCount: UInt32, origin: String = origin, rpID: String = rpID,
                   flags: UInt8 = 0x05, signWith: P256.Signing.PrivateKey? = nil, credentialID idOverride: [UInt8]? = nil) -> [UInt8] {
        var authData: [UInt8] = rpHash(rpID)
        authData.append(flags)
        authData += counter(signCount)
        let cd = clientData(type: "webauthn.get", challenge: challenge, origin: origin)
        let message: [UInt8] = authData + Array(SHA256.hash(data: cd))
        let signature = try! (signWith ?? key).signature(for: message).derRepresentation
        let id = idOverride ?? credentialID
        let response: [String: Any] = ["clientDataJSON": b64(cd), "authenticatorData": b64(authData), "signature": b64([UInt8](signature)),
                                       "userHandle": b64(Array("operator".utf8))]
        let credential: [String: Any] = ["id": b64(id), "rawId": b64(id), "type": "public-key", "response": response]
        let body: [String: Any] = ["challengeId": challengeID, "credential": credential]
        return json(body)
    }
}

private func json(_ object: Any) -> [UInt8] { [UInt8](try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }

// MARK: harness

private final class Harness: @unchecked Sendable {
    let repo: any DashboardRepo
    let now: Locked<Date>
    let logs = Locked<[String]>([])
    let limits: DashboardRateLimits
    let config: DashboardAuthConfig
    var auth: DashboardAuth

    init(repo: any DashboardRepo, scale: Int = 1, config: DashboardAuthConfig = DashboardAuthConfig(origin: origin, rpID: rpID)) {
        self.repo = repo
        self.config = config
        let now = Locked(run0)
        self.now = now
        let logs = self.logs
        let limits = DashboardRateLimits(scale: scale)
        self.limits = limits
        auth = DashboardAuth(repo: repo, config: config, limits: limits, clock: { now.withLock { $0 } },
                             log: { line in logs.withLock { $0.append(line) } })
    }

    /// Simulates a process restart: new service, new setup window, empty in-memory limits.
    func restart() {
        let now = self.now, logs = self.logs
        auth = DashboardAuth(repo: repo, config: config, limits: DashboardRateLimits(), clock: { now.withLock { $0 } },
                             log: { line in logs.withLock { $0.append(line) } })
    }

    func advance(_ seconds: Double) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }

    func register(_ device: FakeAuthenticator, signCount: UInt32 = 0) async throws -> DashboardLoginResult {
        let begin = try await auth.beginSetup()
        return try await auth.finishSetup(body: device.registration(challengeID: begin.challengeId, challenge: begin.options.challenge, signCount: signCount))
    }

    func login(_ device: FakeAuthenticator, signCount: UInt32, origin o: String = origin, rpID r: String = rpID, flags: UInt8 = 0x05,
               signWith: P256.Signing.PrivateKey? = nil) async throws -> DashboardLoginResult {
        let begin = try await auth.beginLogin()
        return try await auth.finishLogin(body: device.assertion(challengeID: begin.challengeId, challenge: begin.options.challenge,
                                                                 signCount: signCount, origin: o, rpID: r, flags: flags, signWith: signWith))
    }

    func cookieValue(_ result: DashboardLoginResult) -> String {
        DashboardSessions.cookieValue(fromHeader: result.setCookie.split(separator: ";").first.map(String.init))!
    }
}

private func expectError(_ status: Int, _ code: String? = nil, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("expected error \(status)") }
    catch let e as DashboardAuthError { #expect(e.status == status); if let code { #expect(e.code == code) } }
    catch { Issue.record("unexpected error \(error)") }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

private func request(_ method: String = "POST", cookie: String? = nil, origin o: String? = origin, host: String? = rpID,
                     type: String? = "application/json", csrf: String? = nil) -> DashboardRequestInfo {
    DashboardRequestInfo(method: method, cookieHeader: cookie.map { "other=1; \(DashboardSessions.cookieName)=\($0)" }, origin: o,
                         host: host, contentType: type, csrfToken: csrf)
}

extension DatabaseSuites {
@Suite("Dashboard auth", .serialized)
struct DashboardAuthTests {
    // MARK: flows

    @Test(arguments: RepoKind.allCases) func setupAndLoginFlow(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        let device = FakeAuthenticator()

        let begin = try await h.auth.beginSetup()
        let options = try encodeJSON(begin.options)
        #expect(Set(options.keys) == ["rp", "user", "challenge", "pubKeyCredParams", "timeout", "attestation", "authenticatorSelection"])
        #expect((options["rp"] as? [String: String])?["id"] == rpID)
        #expect((options["pubKeyCredParams"] as? [[String: Any]])?.first?["alg"] as? Int == -7)
        #expect(options["attestation"] as? String == "none")
        let selection = try #require(options["authenticatorSelection"] as? [String: String])
        #expect(selection["userVerification"] == "required" && selection["residentKey"] == "preferred")
        #expect(DashboardBase64URL.decode(begin.options.challenge)?.count == 32 && DashboardBase64URL.decode(begin.challengeId)?.count == 16)
        #expect(DashboardBase64URL.decode(begin.options.user.id) == Array("operator".utf8))

        let setup = try await h.auth.finishSetup(body: device.registration(challengeID: begin.challengeId, challenge: begin.options.challenge))
        let stored = try #require(try await h.repo.credential())
        #expect(stored.credentialID == device.credentialID && stored.signCount == 0)

        // Cookie attributes, exactly.
        let value = h.cookieValue(setup)
        #expect(setup.setCookie == "__Host-dash_session=\(value); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=43200")
        #expect(!setup.setCookie.contains("Domain"))
        #expect(value.count == 43 && DashboardBase64URL.decode(value)?.count == 32)
        h.logs.withLock { #expect($0.contains("Passkey registriert, Einrichtung geschlossen")) }

        let state = try await h.auth.sessionState(cookieHeader: "\(DashboardSessions.cookieName)=\(value)")
        #expect(state.state == "authenticated")
        let csrf = try #require(state.csrfToken)
        #expect(csrf != value && csrf.count == 43)
        #expect(state.credential?.name == DashboardAuth.credentialName)

        // Only hashes are stored.
        let record = try #require(try await h.repo.session(idHash: Array(SHA256.hash(data: Array(value.utf8))), now: h.now.withLock { $0 }))
        #expect(record.csrfHash == Array(SHA256.hash(data: Array(csrf.utf8))))

        // Login with counter 1: new session (rotation), counter stored.
        let loginBegin = try await h.auth.beginLogin()
        let loginOptions = try encodeJSON(loginBegin.options)
        #expect(Set(loginOptions.keys) == ["challenge", "rpId", "timeout", "userVerification", "allowCredentials"])
        #expect(loginOptions["rpId"] as? String == rpID && loginOptions["userVerification"] as? String == "required")
        #expect((loginOptions["allowCredentials"] as? [[String: String]])?.first?["id"] == b64(device.credentialID))
        h.advance(5)
        let login = try await h.auth.finishLogin(body: device.assertion(challengeID: loginBegin.challengeId, challenge: loginBegin.options.challenge, signCount: 1))
        #expect(h.cookieValue(login) != value)
        let after = try #require(try await h.repo.credential())
        #expect(after.signCount == 1 && after.lastUsedAt != nil)
        // The first session stays valid (single operator), both work.
        #expect(try await h.auth.sessions.authenticate(request("GET", cookie: value)).idHash == record.idHash)
        _ = try await h.auth.sessions.authenticate(request("GET", cookie: h.cookieValue(login)))

        let audit = try await h.repo.auditEntries(limit: 10)
        #expect(audit.map(\.action).sorted { $0.rawValue < $1.rawValue } == [.login, .setup])
    }

    @Test(arguments: RepoKind.allCases) func challengeIsOneTimeAndLoginRejectsTampering(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let device = FakeAuthenticator()
        _ = try await h.register(device)

        // Replay: the same challenge twice.
        let begin = try await h.auth.beginLogin()
        let body = device.assertion(challengeID: begin.challengeId, challenge: begin.options.challenge, signCount: 1)
        _ = try await h.auth.finishLogin(body: body)
        await expectError(401) { _ = try await h.auth.finishLogin(body: body) }
        h.limits.recordSuccess()

        // Wrong origin, wrong rpId, wrong signature key, user verification missing, other credential id: all rejected.
        await expectError(401) { _ = try await h.login(device, signCount: 2, origin: "https://evil.example.test") }
        h.limits.recordSuccess()
        await expectError(401) { _ = try await h.login(device, signCount: 2, rpID: "evil.example.test") }
        h.limits.recordSuccess()
        await expectError(401) { _ = try await h.login(device, signCount: 2, signWith: P256.Signing.PrivateKey()) }
        h.limits.recordSuccess()
        await expectError(401) { _ = try await h.login(device, signCount: 2, flags: 0x01) }
        h.limits.recordSuccess()
        let begin2 = try await h.auth.beginLogin()
        await expectError(401) {
            _ = try await h.auth.finishLogin(body: device.assertion(challengeID: begin2.challengeId, challenge: begin2.options.challenge,
                                                                    signCount: 2, credentialID: FakeAuthenticator(id: 9).credentialID))
        }
        h.limits.recordSuccess()
        // A challenge of another kind or an unknown challenge ID is refused.
        let setupBegin = try? await h.auth.beginSetup()
        #expect(setupBegin == nil) // credential exists: 409
        let forged = device.assertion(challengeID: b64(Array(repeating: 1, count: 16)), challenge: begin.options.challenge, signCount: 3)
        await expectError(401) { _ = try await h.auth.finishLogin(body: forged) }
        h.limits.recordSuccess()
        await expectError(400) { _ = try await h.auth.finishLogin(body: Array("{}".utf8)) }
        // The correct login still works and the stored counter is unchanged by the failures.
        #expect(try await h.repo.credential()?.signCount == 1)
        h.limits.recordSuccess()
        _ = try await h.login(device, signCount: 2)
    }

    @Test(arguments: RepoKind.allCases) func registrationRejectsBadAttestation(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let device = FakeAuthenticator()
        let variants: [(String, String, UInt8)] = [("https://evil.example.test", rpID, 0x45), (origin, "evil.example.test", 0x45), (origin, rpID, 0x41)]
        for (origin, rp, flags) in variants {
            let begin = try await h.auth.beginSetup()
            await expectError(401) {
                _ = try await h.auth.finishSetup(body: device.registration(challengeID: begin.challengeId, challenge: begin.options.challenge,
                                                                           origin: origin, rpID: rp, flags: flags))
            }
            h.limits.recordSuccess()
        }
        #expect(try await h.repo.credential() == nil)
        _ = try await h.register(device) // the right one still works
    }

    @Test(arguments: RepoKind.allCases) func onlyOneOfEightParallelSetupsWins(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let devices = (0..<8).map { FakeAuthenticator(id: UInt8($0 + 1)) }
        let begins = try await withThrowingTaskGroup(of: (Int, DashboardBeginResponse<DashboardCreationOptions>).self) { group in
            for i in 0..<8 { group.addTask { (i, try await h.auth.beginSetup()) } }
            var out: [Int: DashboardBeginResponse<DashboardCreationOptions>] = [:]
            for try await (i, b) in group { out[i] = b }
            return out
        }
        let results = await withTaskGroup(of: Int.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let b = begins[i]!
                    do {
                        _ = try await h.auth.finishSetup(body: devices[i].registration(challengeID: b.challengeId, challenge: b.options.challenge))
                        return 204
                    } catch let e as DashboardAuthError { return e.status } catch { return 500 }
                }
            }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(results.filter { $0 == 204 }.count == 1)
        #expect(results.filter { $0 == 409 }.count == 7)
        let stored = try #require(try await h.repo.credential())
        #expect(devices.contains { $0.credentialID == stored.credentialID })
        // A later setup is refused outright, already at begin.
        await expectError(409) { _ = try await h.auth.beginSetup() }
        #expect(try await h.repo.auditEntries(limit: 20).filter { $0.action == .setup }.count == 1)
    }

    @Test(arguments: RepoKind.allCases) func signCountRollbackIsRejectedAndAudited(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let device = FakeAuthenticator()
        _ = try await h.register(device)
        _ = try await h.login(device, signCount: 5)
        for count: UInt32 in [5, 3] { // same and lower counter: clone suspicion
            await expectError(401) { _ = try await h.login(device, signCount: count) }
            h.limits.recordSuccess()
        }
        #expect(try await h.repo.credential()?.signCount == 5)
        let audit = try await h.repo.auditEntries(limit: 10)
        #expect(audit.filter { $0.newValue?.hasPrefix("abgelehnt") == true }.count == 2)
        h.logs.withLock { #expect($0.contains { $0.contains("möglicher Klon") }) }
        _ = try await h.login(device, signCount: 6)
    }

    @Test(arguments: RepoKind.allCases) func authenticatorsWithoutCounterWork(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let device = FakeAuthenticator()
        _ = try await h.register(device)
        _ = try await h.login(device, signCount: 0)
        _ = try await h.login(device, signCount: 0)
    }

    // MARK: setup window

    @Test(arguments: RepoKind.allCases) func setupWindowOpensAtStartAndCloses(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        #expect(h.auth.setupMinutesLeft() == 15)
        #expect(try await h.auth.sessionState(cookieHeader: nil) == DashboardSessionResponse(state: "setupOpen", minutesLeft: 15))
        let hint = await h.auth.logSetupHintIfNeeded()
        #expect(hint?.contains("Dashboard-Einrichtung OFFEN") == true && hint?.contains("noch 15 Minuten") == true)
        h.advance(14 * 60 + 30)
        #expect(h.auth.setupMinutesLeft() == 1)
        h.advance(31)
        #expect(h.auth.setupMinutesLeft() == 0)
        await expectError(403, "setup_closed") { _ = try await h.auth.beginSetup() }
        #expect(try await h.auth.sessionState(cookieHeader: nil).state == "setupClosed")
        #expect(await h.auth.logSetupHintIfNeeded()?.contains("geschlossen") == true)
        h.restart() // restart reopens the window while no passkey exists
        #expect(h.auth.setupMinutesLeft() == 15)
        let device = FakeAuthenticator()
        _ = try await h.register(device)
        #expect(await h.auth.logSetupHintIfNeeded() == nil)
        // After registration the window no longer matters: setup is conflict, state is login.
        await expectError(409) { _ = try await h.auth.beginSetup() }
        #expect(try await h.auth.sessionState(cookieHeader: nil).state == "login")
    }

    @Test func configFromEnvironment() {
        let ok = DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "https://d.example.test:8443", "DASH_RP_ID": "d.example.test",
                                                      "DASH_SESSION_HOURS": "6", "DASH_IDLE_MINUTES": "10", "DASH_SETUP_WINDOW_MINUTES": "5"])
        #expect(ok?.expectedHost == "d.example.test:8443" && ok?.sessionHours == 6 && ok?.idleMinutes == 10 && ok?.setupWindowMinutes == 5)
        #expect(DashboardAuthConfig.fromEnvironment([:]) == nil)
        #expect(DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "https://d.example.test/x", "DASH_RP_ID": "d.example.test"]) == nil)
        #expect(DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "ftp://d.example.test", "DASH_RP_ID": "d.example.test"]) == nil)
        #expect(DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "https://d.example.test", "DASH_RP_ID": "other.test"]) == nil)
        #expect(DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "https://a.d.example.test:8443"])?.rpID == "a.d.example.test")
        #expect(DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "https://a.d.example.test", "DASH_RP_ID": "d.example.test"])?.rpID == "d.example.test")
        #expect(DashboardAuthConfig.fromEnvironment(["DASH_ORIGIN": "https://d.example.test", "DASH_RP_ID": "d.example.test"])?.sessionHours == 12)
    }

    // MARK: sessions

    @Test(arguments: RepoKind.allCases) func sessionIdleAndAbsoluteLifetime(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        let device = FakeAuthenticator()
        let value = h.cookieValue(try await h.register(device))
        let sessions = h.auth.sessions
        // Sliding idle window: activity every 20 minutes keeps the session alive.
        for _ in 0..<5 {
            h.advance(20 * 60)
            _ = try await sessions.authenticate(request("GET", cookie: value))
        }
        // 30 minutes of silence ends it, and the row is gone.
        h.advance(30 * 60 + 1)
        await expectError(401) { _ = try await sessions.authenticate(request("GET", cookie: value)) }
        #expect(try await h.repo.session(idHash: Array(SHA256.hash(data: Array(value.utf8))), now: h.now.withLock { $0 }) == nil)

        // Absolute lifetime of 12 hours holds despite constant activity.
        let second = h.cookieValue(try await h.login(device, signCount: 1))
        var elapsed = 0.0
        while elapsed < 12 * 3600 - 20 * 60 {
            h.advance(20 * 60); elapsed += 20 * 60
            _ = try await sessions.authenticate(request("GET", cookie: second))
        }
        h.advance(20 * 60 + 1)
        await expectError(401) { _ = try await sessions.authenticate(request("GET", cookie: second)) }
    }

    @Test(arguments: RepoKind.allCases) func logoutDeletesSessionAndClearsCookie(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        let value = h.cookieValue(try await h.register(FakeAuthenticator()))
        let clear = try await h.auth.logout(cookieHeader: "\(DashboardSessions.cookieName)=\(value)")
        #expect(clear == "__Host-dash_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0")
        await expectError(401) { _ = try await h.auth.sessions.authenticate(request("GET", cookie: value)) }
        #expect(try await h.auth.sessionState(cookieHeader: "\(DashboardSessions.cookieName)=\(value)").state == "login")
    }

    @Test func cookieParsingRejectsMalformedValues() {
        let good = DashboardBase64URL.encode(Array(repeating: 9, count: 32))
        #expect(DashboardSessions.cookieValue(fromHeader: "a=b; __Host-dash_session=\(good); c=d") == good)
        #expect(DashboardSessions.cookieValue(fromHeader: "__Host-dash_session=\(good)x") == nil)
        #expect(DashboardSessions.cookieValue(fromHeader: "__Host-dash_session=short") == nil)
        #expect(DashboardSessions.cookieValue(fromHeader: "dash_session=\(good)") == nil)
        #expect(DashboardSessions.cookieValue(fromHeader: "__Host-dash_session=" + String(repeating: "+", count: 43)) == nil)
        #expect(DashboardSessions.cookieValue(fromHeader: nil) == nil)
    }

    // MARK: CSRF, origin, host

    @Test(arguments: RepoKind.allCases) func csrfOriginAndHostChecks(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        let value = h.cookieValue(try await h.register(FakeAuthenticator()))
        let sessions = h.auth.sessions
        let session = try await sessions.authenticate(request("GET", cookie: value))
        let csrf = session.csrfToken

        try sessions.authorizeWrite(request("POST", cookie: value, csrf: csrf), session: session)
        try sessions.authorizeWrite(request("PUT", cookie: value, type: "application/json; charset=utf-8", csrf: csrf), session: session)
        try sessions.authorizeWrite(request("GET", cookie: value), session: session) // reads need no token
        for method in ["POST", "PUT", "DELETE", "PATCH"] {
            #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request(method, cookie: value), session: session) }
            #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request(method, cookie: value, csrf: "wrong"), session: session) }
            #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request(method, cookie: value, csrf: String(csrf.dropLast())), session: session) }
            #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request(method, cookie: value, csrf: value), session: session) }
        }
        #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request("POST", cookie: value, origin: nil, csrf: csrf), session: session) }
        #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request("POST", cookie: value, origin: "https://evil.example.test", csrf: csrf), session: session) }
        #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request("POST", cookie: value, origin: origin + "/", csrf: csrf), session: session) }
        #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request("POST", cookie: value, type: "text/plain", csrf: csrf), session: session) }
        #expect(throws: DashboardAuthError.forbidden) { try sessions.authorizeWrite(request("POST", cookie: value, type: nil, csrf: csrf), session: session) }
        // Host (DNS rebinding): applies to reads and writes; a different token of another session does not work either.
        #expect(throws: DashboardAuthError.forbidden) { try sessions.checkHost(request("GET", host: "evil.example.test")) }
        #expect(throws: DashboardAuthError.forbidden) { try sessions.checkHost(request("GET", host: nil)) }
        try sessions.checkHost(request("GET", host: "DASH.example.test"))
        await expectError(403) { _ = try await sessions.authenticate(request("GET", cookie: value, host: "127.0.0.1")) }
        // No cookie / garbage cookie: 401. Public routes check origin and type, but no token.
        await expectError(401) { _ = try await sessions.authenticate(request("GET")) }
        await expectError(401) { _ = try await sessions.authenticate(request("GET", cookie: "garbage")) }
        try sessions.checkWriteOrigin(request("POST"))
        #expect(throws: DashboardAuthError.forbidden) { try sessions.checkWriteOrigin(request("POST", origin: "null")) }
    }

    // MARK: rate limits

    @Test func bucketLimitsAndWindowReset() throws {
        let limits = DashboardRateLimits()
        var now = run0
        for _ in 0..<10 { try limits.check(.loginBegin, now: now) }
        #expect(throws: DashboardAuthError.rateLimited(60)) { try limits.check(.loginBegin, now: now) }
        try limits.check(.setupBegin, now: now) // independent bucket
        for _ in 0..<5 { try limits.check(.loginFinish, now: now) }
        #expect(throws: DashboardAuthError.rateLimited(60)) { try limits.check(.loginFinish, now: now) }
        now = now.addingTimeInterval(61)
        try limits.check(.loginBegin, now: now)
        try limits.check(.loginFinish, now: now)
        for _ in 0..<29 { try limits.check(.configWrite, now: now) }
        try limits.check(.configWrite, now: now)
        #expect(throws: DashboardAuthError.self) { try limits.check(.configWrite, now: now) }
    }

    @Test func failuresBackOffExponentially() throws {
        let limits = DashboardRateLimits()
        let now = run0
        for _ in 0..<3 { limits.recordFailure(now: now) }
        try limits.checkNotBlocked(now: now) // three free failures
        limits.recordFailure(now: now)       // 4th: 5 s
        #expect(throws: DashboardAuthError.rateLimited(5)) { try limits.checkNotBlocked(now: now) }
        try limits.checkNotBlocked(now: now.addingTimeInterval(5))
        limits.recordFailure(now: now.addingTimeInterval(5)) // 5th: 10 s
        #expect(throws: DashboardAuthError.rateLimited(10)) { try limits.checkNotBlocked(now: now.addingTimeInterval(5)) }
        var t = now.addingTimeInterval(15)
        for _ in 0..<10 { limits.recordFailure(now: t); t = t.addingTimeInterval(1) } // capped at 5 minutes
        #expect(throws: DashboardAuthError.rateLimited(300)) { try limits.checkNotBlocked(now: t.addingTimeInterval(-1)) }
        limits.recordSuccess()
        try limits.checkNotBlocked(now: t)
        #expect(limits.failureCount == 0)
        // Old failures are forgotten.
        for _ in 0..<3 { limits.recordFailure(now: now) }
        limits.recordFailure(now: now.addingTimeInterval(1000))
        #expect(limits.failureCount == 1)
    }

    @Test(arguments: RepoKind.allCases) func failedLoginsBlockTemporarily(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let device = FakeAuthenticator()
        _ = try await h.register(device)
        for _ in 0..<4 { await expectError(401) { _ = try await h.login(device, signCount: 1, signWith: P256.Signing.PrivateKey()) } }
        await expectError(429) { _ = try await h.auth.beginLogin() }
        do { _ = try await h.auth.beginLogin() } catch let e as DashboardAuthError { #expect(e.retryAfter == 5) }
        h.advance(6)
        _ = try await h.login(device, signCount: 1) // success resets
        #expect(h.limits.failureCount == 0)
    }

    @Test(arguments: RepoKind.allCases) func endpointLimitsAreGlobal(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        for _ in 0..<10 { _ = try await h.auth.beginSetup() }
        await expectError(429) { _ = try await h.auth.beginSetup() }
        h.advance(61)
        _ = try await h.auth.beginSetup()
    }

    // MARK: reset and audit

    @Test(arguments: RepoKind.allCases) func cliResetRemovesPasskeyAndSessions(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make())
        let device = FakeAuthenticator()
        let value = h.cookieValue(try await h.register(device))
        #expect(try await h.auth.resetViaCLI())
        #expect(try await h.repo.credential() == nil)
        await expectError(401) { _ = try await h.auth.sessions.authenticate(request("GET", cookie: value)) }
        #expect(try await h.repo.auditEntries(limit: 5).first?.action == .resetCLI)
        #expect(try await h.auth.resetViaCLI() == false)
        // The window of the running service is still open, so the new passkey can be registered right away.
        _ = try await h.register(FakeAuthenticator(id: 3))
    }

    @Test(arguments: RepoKind.allCases) func auditContainsNoSecrets(kind: RepoKind) async throws {
        let h = Harness(repo: try await kind.make(), scale: 100)
        let device = FakeAuthenticator()
        let begin = try await h.auth.beginSetup()
        let setup = try await h.auth.finishSetup(body: device.registration(challengeID: begin.challengeId, challenge: begin.options.challenge))
        let loginBegin = try await h.auth.beginLogin()
        let login = try await h.auth.finishLogin(body: device.assertion(challengeID: loginBegin.challengeId, challenge: loginBegin.options.challenge, signCount: 2))
        _ = try? await h.login(device, signCount: 2) // rollback
        try await h.auth.resetViaCLI()
        let secrets = [h.cookieValue(setup), h.cookieValue(login), begin.challengeId, begin.options.challenge, loginBegin.challengeId,
                       loginBegin.options.challenge, b64(device.credentialID), DashboardSessions.csrfToken(forCookieValue: h.cookieValue(setup))]
        let entries = try await h.repo.auditEntries(limit: 50)
        #expect(entries.count == 4)
        for entry in entries {
            for text in [entry.key, entry.oldValue, entry.newValue].compactMap({ $0 }) {
                for secret in secrets { #expect(!text.contains(secret)) }
                #expect(text.count < 60)
            }
        }
        h.logs.withLock { logs in for line in logs { for secret in secrets { #expect(!line.contains(secret)) } } }
    }
}
}
