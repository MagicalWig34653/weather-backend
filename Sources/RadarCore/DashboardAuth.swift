import Foundation
import WebAuthn

// Dashboard passkey authentication (docs/dashboard-plan.md 2.4 to 2.8). Framework independent service: handlers get raw bodies and
// return Encodable results or `DashboardAuthError`; the Vapor wiring (WP5) lives in `Sources/radar`.
// Library: swift-server/swift-webauthn 1.0.0-beta.1 verifies attestation (none) and assertions; options are built here
// (the library omits authenticatorSelection, which this service needs for userVerification=required).

// MARK: JSON shapes (camelCase; byte values are Base64URL strings)

public struct DashboardCreationOptions: Encodable, Sendable, Equatable {
    public struct RP: Encodable, Sendable, Equatable { public let id: String; public let name: String }
    public struct User: Encodable, Sendable, Equatable { public let id: String; public let name: String; public let displayName: String }
    public struct Param: Encodable, Sendable, Equatable { public let type: String; public let alg: Int }
    public struct Selection: Encodable, Sendable, Equatable { public let residentKey: String; public let userVerification: String }
    public let rp: RP
    public let user: User
    public let challenge: String
    public let pubKeyCredParams: [Param]
    public let timeout: Int
    public let attestation: String
    public let authenticatorSelection: Selection
}

public struct DashboardRequestOptions: Encodable, Sendable, Equatable {
    public struct Descriptor: Encodable, Sendable, Equatable { public let type: String; public let id: String }
    public let challenge: String
    public let rpId: String
    public let timeout: Int
    public let userVerification: String
    public let allowCredentials: [Descriptor]
}

public struct DashboardBeginResponse<Options: Encodable & Sendable>: Encodable, Sendable {
    public let challengeId: String
    public let options: Options
}

/// Result of a successful setup or login: the handler answers 204 and sets this cookie.
public struct DashboardLoginResult: Sendable, Equatable {
    public let setCookie: String
}

public struct DashboardCredentialInfo: Encodable, Sendable, Equatable {
    public let name: String
    public let createdAt: String
}

/// Body of `GET /dash/api/session`.
public struct DashboardSessionResponse: Encodable, Sendable, Equatable {
    /// `setupOpen`, `setupClosed`, `login` or `authenticated`.
    public let state: String
    public let minutesLeft: Int?
    public let csrfToken: String?
    public let credential: DashboardCredentialInfo?

    public init(state: String, minutesLeft: Int? = nil, csrfToken: String? = nil, credential: DashboardCredentialInfo? = nil) {
        self.state = state; self.minutesLeft = minutesLeft; self.csrfToken = csrfToken; self.credential = credential
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(minutesLeft, forKey: .minutesLeft)
        try c.encodeIfPresent(csrfToken, forKey: .csrfToken)
        try c.encodeIfPresent(credential, forKey: .credential)
    }
    private enum Keys: String, CodingKey { case state, minutesLeft, csrfToken, credential }
}

// MARK: service

public final class DashboardAuth: Sendable {
    /// Fixed handle of the only operator account (no name, no e-mail).
    static let userHandle = Array("operator".utf8)
    static let challengeLifetime: TimeInterval = 300
    static let maxBodyBytes = 16 * 1024
    /// Stored credential name shown on the session page.
    public static let credentialName = "Passkey des Betreibers"

    private let repo: any DashboardRepo
    public let config: DashboardAuthConfig
    public let sessions: DashboardSessions
    public let limits: DashboardRateLimits
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let manager: WebAuthnManager
    /// Setup window start: service start (a restart reopens the window while no credential exists).
    private let openedAt: Date

    public init(repo: any DashboardRepo, config: DashboardAuthConfig, limits: DashboardRateLimits = DashboardRateLimits(),
                clock: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.repo = repo; self.config = config; self.limits = limits; self.clock = clock; self.log = log
        sessions = DashboardSessions(repo: repo, config: config, clock: clock)
        manager = WebAuthnManager(configuration: .init(relyingPartyID: config.rpID, relyingPartyName: config.rpName,
                                                       relyingPartyOrigin: config.origin))
        openedAt = clock()
    }

    // MARK: setup window

    /// Whole minutes left in the setup window (0 = closed). Independent of whether a credential exists.
    public func setupMinutesLeft() -> Int {
        let left = openedAt.addingTimeInterval(Double(config.setupWindowMinutes) * 60).timeIntervalSince(clock())
        return left > 0 ? Int((left / 60).rounded(.up)) : 0
    }

    /// Clear log line while the dashboard has no passkey (call at start and every minute). Returns the line, nil when a passkey exists.
    @discardableResult
    public func logSetupHintIfNeeded() async -> String? {
        do { if try await repo.credential() != nil { return nil } } catch { return nil }
        let left = setupMinutesLeft()
        let line = left > 0
            ? "Dashboard-Einrichtung OFFEN: erster Passkey ohne Token möglich, noch \(left) Minuten"
            : "Dashboard-Einrichtung geschlossen, noch kein Passkey: Dashboard neu starten, um das Fenster erneut zu öffnen"
        log(line)
        return line
    }

    // MARK: session state

    public func sessionState(cookieHeader: String?) async throws -> DashboardSessionResponse {
        let credential = try await repo.credential()
        if let session = try await sessions.validate(cookieValue: DashboardSessions.cookieValue(fromHeader: cookieHeader)),
           let credential {
            return DashboardSessionResponse(state: "authenticated", csrfToken: session.csrfToken,
                                            credential: DashboardCredentialInfo(name: Self.credentialName, createdAt: iso(credential.createdAt)))
        }
        if credential != nil { return DashboardSessionResponse(state: "login") }
        let left = setupMinutesLeft()
        return left > 0 ? DashboardSessionResponse(state: "setupOpen", minutesLeft: left) : DashboardSessionResponse(state: "setupClosed")
    }

    // MARK: setup

    public func beginSetup() async throws -> DashboardBeginResponse<DashboardCreationOptions> {
        let now = clock()
        try limits.checkNotBlocked(now: now)
        try limits.check(.setupBegin, now: now)
        try await requireSetupPossible()
        let (id, challenge) = try await newChallenge(.setup, now: now)
        let options = DashboardCreationOptions(
            rp: .init(id: config.rpID, name: config.rpName),
            user: .init(id: DashboardBase64URL.encode(Self.userHandle), name: "operator", displayName: "Betreiber"),
            challenge: DashboardBase64URL.encode(challenge),
            pubKeyCredParams: [.init(type: "public-key", alg: -7)],
            timeout: 300_000, attestation: "none",
            authenticatorSelection: .init(residentKey: "preferred", userVerification: "required"))
        return DashboardBeginResponse(challengeId: DashboardBase64URL.encode(id), options: options)
    }

    private struct SetupBody: Decodable { let challengeId: String; let credential: RegistrationCredential }

    /// Registers the first passkey (atomic, only when none exists) and signs the operator in.
    public func finishSetup(body: [UInt8]) async throws -> DashboardLoginResult {
        let now = clock()
        try limits.checkNotBlocked(now: now)
        try limits.check(.setupFinish, now: now)
        let parsed: SetupBody = try decode(body)
        try await requireSetupPossible()
        let challenge = try await consume(parsed.challengeId, kind: .setup, now: now)
        let verified: WebAuthn.Credential
        do {
            verified = try await manager.finishRegistration(
                challenge: challenge, credentialCreationData: parsed.credential, requireUserVerification: true,
                supportedPublicKeyAlgorithms: [.init(alg: .algES256)], confirmCredentialIDNotRegisteredYet: { _ in true })
        } catch {
            try fail(now)
        }
        guard parsed.credential.rawID.count <= 1024, !parsed.credential.rawID.isEmpty else { try fail(now) }
        guard try await repo.insertCredential(credentialID: parsed.credential.rawID, publicKey: verified.publicKey,
                                              signCount: Int(verified.signCount), now: now) else {
            throw DashboardAuthError.conflict
        }
        try await repo.appendAudit(action: .setup, key: nil, oldValue: nil, newValue: "Passkey registriert", now: now)
        log("Passkey registriert, Einrichtung geschlossen")
        limits.recordSuccess()
        return try await startSession()
    }

    private func requireSetupPossible() async throws {
        if try await repo.credential() != nil { throw DashboardAuthError.conflict }
        if setupMinutesLeft() == 0 { throw DashboardAuthError(403, "setup_closed") }
    }

    // MARK: login

    public func beginLogin() async throws -> DashboardBeginResponse<DashboardRequestOptions> {
        let now = clock()
        try limits.check(.loginBegin, now: now)
        guard let credential = try await repo.credential() else { throw DashboardAuthError.conflict }
        let (id, challenge) = try await newChallenge(.login, now: now)
        let options = DashboardRequestOptions(
            challenge: DashboardBase64URL.encode(challenge), rpId: config.rpID, timeout: 60_000, userVerification: "required",
            allowCredentials: [.init(type: "public-key", id: DashboardBase64URL.encode(credential.credentialID))])
        return DashboardBeginResponse(challengeId: DashboardBase64URL.encode(id), options: options)
    }

    private struct LoginBody: Decodable { let challengeId: String; let credential: AuthenticationCredential }

    public func finishLogin(body: [UInt8]) async throws -> DashboardLoginResult {
        let now = clock()
        let parsed: LoginBody = try decode(body)
        let challenge = try await consume(parsed.challengeId, kind: .login, now: now)
        guard let stored = try await repo.credential(), stored.credentialID == parsed.credential.rawID,
              stored.signCount >= 0, stored.signCount <= Int(UInt32.max) else { try failNoCount(now) }
        let verified: VerifiedAuthentication
        do {
            verified = try manager.finishAuthentication(
                credential: parsed.credential, expectedChallenge: challenge, credentialPublicKey: stored.publicKey,
                credentialCurrentSignCount: UInt32(stored.signCount), requireUserVerification: true)
        } catch let error as WebAuthnError where error == .potentialReplayAttack {
            // Counter did not increase: cloned authenticator or replay. Reject and audit (no secrets).
            try? await repo.appendAudit(action: .login, key: nil, oldValue: nil, newValue: "abgelehnt: Zähler nicht gestiegen", now: now)
            log("Dashboard-Anmeldung abgelehnt: Signaturzähler nicht gestiegen (möglicher Klon)")
            try failNoCount(now)
        } catch {
            try failNoCount(now)
        }
        guard try await repo.updateCredentialUse(credentialID: stored.credentialID, signCount: Int(verified.newSignCount), now: now) else {
            try failNoCount(now)
        }
        try await repo.appendAudit(action: .login, key: nil, oldValue: nil, newValue: "erfolgreich", now: now)
        log("Dashboard-Anmeldung erfolgreich")
        limits.recordSuccess()
        return try await startSession()
    }

    // MARK: logout and reset

    /// Deletes the session; the answer clears the cookie.
    public func logout(cookieHeader: String?) async throws -> String {
        try await sessions.destroy(cookieValue: DashboardSessions.cookieValue(fromHeader: cookieHeader))
        log("Dashboard-Abmeldung")
        return sessions.clearCookieHeader()
    }

    /// `radar dashboard-reset --yes`: deletes passkey, sessions and challenges; audit entry; the setup window reopens at next start.
    @discardableResult
    public func resetViaCLI() async throws -> Bool {
        let existed = try await repo.resetCredential()
        try await repo.appendAudit(action: .resetCLI, key: nil, oldValue: nil, newValue: existed ? "Passkey und Sitzungen gelöscht" : "kein Passkey vorhanden", now: clock())
        return existed
    }

    // MARK: helpers

    private func startSession() async throws -> DashboardLoginResult {
        let created = try await sessions.create()
        return DashboardLoginResult(setCookie: sessions.setCookieHeader(value: created.cookieValue))
    }

    private func newChallenge(_ kind: DashboardChallengeKind, now: Date) async throws -> (id: [UInt8], challenge: [UInt8]) {
        let id = dashboardRandom(16), challenge = dashboardRandom(32)
        try await repo.putChallenge(id: id, kind: kind, challenge: challenge, expiresAt: now.addingTimeInterval(Self.challengeLifetime), now: now)
        return (id, challenge)
    }

    /// One-time use; unknown, expired, used or foreign IDs are refused (401) but are no failed attempts: anyone can send them,
    /// so they only count against the separate `challengeProbe` bucket. Wrong signatures on setup keep the capped failure delay (login has none).
    private func consume(_ challengeID: String, kind: DashboardChallengeKind, now: Date) async throws -> [UInt8] {
        try limits.check(.challengeProbe, now: now)
        guard let id = DashboardBase64URL.decode(challengeID), id.count == 16,
              let challenge = try await repo.consumeChallenge(id: id, kind: kind, now: now) else {
            throw DashboardAuthError.unauthorized
        }
        return challenge
    }

    /// Login failure: logged, but never delays the next login (see `DashboardRateLimits`).
    private func failNoCount(_ now: Date) throws -> Never {
        log("Dashboard-Anmeldung fehlgeschlagen")
        throw DashboardAuthError.unauthorized
    }

    private func fail(_ now: Date) throws -> Never {
        limits.recordFailure(now: now)
        log("Dashboard-Anmeldung fehlgeschlagen")
        throw DashboardAuthError.unauthorized
    }

    private func decode<T: Decodable>(_ body: [UInt8]) throws -> T {
        guard body.count <= Self.maxBodyBytes, let value = try? JSONDecoder().decode(T.self, from: Data(body)) else {
            throw DashboardAuthError.validation
        }
        return value
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
