import Foundation
import Testing
@testable import RadarCore

// Synthetic bytes only. Memory and MariaDB (when RADAR_TEST_DB_HOST is set) share the same contract.
private let t0 = run0
private func bytes(_ seed: UInt8, count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 7) } }
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
private let day: Double = 86400

@Suite("Dashboard repo", .serialized)
struct DashboardRepoTests {
    @Test(arguments: RepoKind.allCases) func credentialIsInsertedOnceAtomically(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.credential() == nil)
        let wins = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<8 {
                group.addTask {
                    (try? await repo.insertCredential(credentialID: bytes(UInt8(i), count: 40), publicKey: bytes(UInt8(100 + i), count: 77),
                                                      signCount: 0, now: t0)) ?? false
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wins == 1)
        let stored = try #require(try await repo.credential())
        #expect(stored.credentialID.count == 40 && stored.publicKey.count == 77)
        #expect(stored.signCount == 0 && stored.lastUsedAt == nil && stored.createdAt == t0)
        // A sequential second registration is refused as well and does not change the stored credential.
        #expect(try await repo.insertCredential(credentialID: bytes(9, count: 16), publicKey: bytes(9, count: 16), signCount: 0, now: at(5)) == false)
        #expect(try await repo.credential() == stored)
    }

    @Test(arguments: RepoKind.allCases) func credentialUseAndReset(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let id = bytes(1, count: 32), key = bytes(2, count: 91)
        #expect(try await repo.resetCredential() == false)
        #expect(try await repo.insertCredential(credentialID: id, publicKey: key, signCount: 3, now: t0))
        #expect(try await repo.updateCredentialUse(credentialID: bytes(5, count: 32), signCount: 9, now: at(10)) == false)
        #expect(try await repo.updateCredentialUse(credentialID: id, signCount: 4, now: at(10)))
        #expect(try await repo.updateCredentialUse(credentialID: id, signCount: 4, now: at(10)))
        let stored = try #require(try await repo.credential())
        #expect(stored.signCount == 4 && stored.lastUsedAt == at(10) && stored.publicKey == key)
        // Reset removes the credential, sessions and challenges; registration is possible again.
        try await repo.createSession(idHash: bytes(3, count: 32), csrfHash: bytes(4, count: 32), now: t0, expiresAt: at(3600))
        try await repo.putChallenge(id: bytes(6, count: 16), kind: .login, challenge: bytes(7, count: 32), expiresAt: at(300), now: t0)
        #expect(try await repo.resetCredential())
        #expect(try await repo.credential() == nil)
        #expect(try await repo.session(idHash: bytes(3, count: 32), now: at(1)) == nil)
        #expect(try await repo.consumeChallenge(id: bytes(6, count: 16), kind: .login, now: at(1)) == nil)
        #expect(try await repo.insertCredential(credentialID: id, publicKey: key, signCount: 0, now: at(20)))
    }

    @Test(arguments: RepoKind.allCases) func challengesAreOneTimeAndExpire(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let id = bytes(1, count: 16), challenge = bytes(2, count: 32)
        try await repo.putChallenge(id: id, kind: .setup, challenge: challenge, expiresAt: at(300), now: t0)
        // Wrong kind neither returns nor consumes the challenge.
        #expect(try await repo.consumeChallenge(id: id, kind: .login, now: at(10)) == nil)
        #expect(try await repo.consumeChallenge(id: id, kind: .setup, now: at(10)) == challenge)
        #expect(try await repo.consumeChallenge(id: id, kind: .setup, now: at(11)) == nil)
        // Expired challenge is not returned.
        try await repo.putChallenge(id: id, kind: .login, challenge: challenge, expiresAt: at(400), now: at(100))
        #expect(try await repo.consumeChallenge(id: id, kind: .login, now: at(400)) == nil)
        // Parallel consumption: exactly one caller receives it.
        try await repo.putChallenge(id: id, kind: .login, challenge: challenge, expiresAt: at(900), now: at(500))
        let got = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 { group.addTask { ((try? await repo.consumeChallenge(id: id, kind: .login, now: at(501))) ?? nil) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(got == 1)
        // Writing a new challenge removes expired ones.
        try await repo.putChallenge(id: bytes(8, count: 16), kind: .login, challenge: challenge, expiresAt: at(700), now: at(500))
        try await repo.putChallenge(id: bytes(9, count: 16), kind: .login, challenge: challenge, expiresAt: at(2000), now: at(800))
        #expect(try await repo.purgeDashboard(now: at(800)).challenges == 0)
        #expect(try await repo.consumeChallenge(id: bytes(8, count: 16), kind: .login, now: at(600)) == nil)
    }

    @Test(arguments: RepoKind.allCases) func sessionsLifecycle(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let id = bytes(1, count: 32), csrf = bytes(2, count: 32)
        #expect(try await repo.session(idHash: id, now: t0) == nil)
        try await repo.createSession(idHash: id, csrfHash: csrf, now: t0, expiresAt: at(3600))
        let record = try #require(try await repo.session(idHash: id, now: at(60)))
        #expect(record == DashboardSessionRecord(idHash: id, csrfHash: csrf, createdAt: t0, lastSeenAt: t0, expiresAt: at(3600)))
        #expect(try await repo.touchSession(idHash: id, now: at(120), expiresAt: nil))
        #expect(try await repo.touchSession(idHash: id, now: at(120), expiresAt: nil))
        #expect(try await repo.session(idHash: id, now: at(121))?.lastSeenAt == at(120))
        #expect(try await repo.touchSession(idHash: id, now: at(200), expiresAt: at(5000)))
        #expect(try await repo.session(idHash: id, now: at(4000))?.expiresAt == at(5000))
        // Expired: not returned, not touched.
        #expect(try await repo.session(idHash: id, now: at(5000)) == nil)
        #expect(try await repo.touchSession(idHash: id, now: at(5001), expiresAt: nil) == false)
        // Explicit logout.
        try await repo.createSession(idHash: id, csrfHash: csrf, now: at(6000), expiresAt: at(9000))
        #expect(try await repo.deleteSession(idHash: id))
        #expect(try await repo.deleteSession(idHash: id) == false)
        #expect(try await repo.session(idHash: id, now: at(6001)) == nil)
        // Retention removes expired sessions only.
        try await repo.createSession(idHash: bytes(5, count: 32), csrfHash: csrf, now: at(7000), expiresAt: at(7100))
        try await repo.createSession(idHash: bytes(6, count: 32), csrfHash: csrf, now: at(7000), expiresAt: at(9000))
        let purged = try await repo.purgeDashboard(now: at(8000))
        #expect(purged.sessions == 1)
        #expect(try await repo.session(idHash: bytes(6, count: 32), now: at(8000)) != nil)
        #expect(try await repo.purgeDashboard(now: at(8000)) == DashboardPurgeResult())
    }

    @Test(arguments: RepoKind.allCases) func statsAddReadAndPurge(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let d0 = at(0), d1 = at(day)
        try await repo.addStats(day: d0, [StatDelta(metric: "req", label: "radar_slot:2xx", value: 5), StatDelta(metric: "req", label: "status", value: 1)])
        // Second replica adds to the same counters; duplicates within one call merge; zero is skipped.
        try await repo.addStats(day: d0.addingTimeInterval(3600), [StatDelta(metric: "req", label: "radar_slot:2xx", value: 7),
                                                                   StatDelta(metric: "req", label: "radar_slot:2xx", value: 3),
                                                                   StatDelta(metric: "cache", label: "hit", value: 0)])
        try await repo.addStats(day: d1, [StatDelta(metric: "req", label: "status", value: 2)])
        let dayStart = DashboardValidation.date(day: DashboardValidation.day(d0))
        let rows = try await repo.stats(from: d0, to: d1)
        let expected: [StatRow] = [
            StatRow(day: dayStart, metric: "req", label: "radar_slot:2xx", value: 15),
            StatRow(day: dayStart, metric: "req", label: "status", value: 1),
            StatRow(day: dayStart.addingTimeInterval(day), metric: "req", label: "status", value: 2),
        ]
        #expect(rows == expected)
        #expect(try await repo.stats(from: d1, to: d1).count == 1)
        // Concurrent additions are not lost.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { try? await repo.addStats(day: d1, [StatDelta(metric: "req", label: "status", value: 1)]) } }
        }
        #expect(try await repo.stats(from: d1, to: d1).first?.value == 12)
        // Only fixed labels: free text, identifiers and negative values are rejected without writing anything.
        for bad in [StatDelta(metric: "req", label: "Berlin 52.5", value: 1), StatDelta(metric: "req", label: "a/b", value: 1),
                    StatDelta(metric: "Req", label: "x", value: 1), StatDelta(metric: "", label: "x", value: 1),
                    StatDelta(metric: String(repeating: "a", count: 33), label: "x", value: 1),
                    StatDelta(metric: "req", label: String(repeating: "a", count: 49), value: 1), StatDelta(metric: "req", label: "x", value: -1)] {
            await #expect(throws: DashboardRepoError.invalidStat) {
                try await repo.addStats(day: d1, [StatDelta(metric: "req", label: "status", value: 1), bad])
            }
        }
        #expect(try await repo.stats(from: d1, to: d1).first?.value == 12)
        // 30 days retention: day 0 is gone once "now" is more than 30 days later, day 1 one day later.
        #expect(try await repo.purgeStats(now: at(30 * day)) == 0)
        #expect(try await repo.purgeStats(now: at(31 * day)) == 2)
        #expect(try await repo.stats(from: d0, to: d1).count == 1)
        #expect(try await repo.purgeDashboard(now: at(32 * day)).stats == 1)
        #expect(try await repo.stats(from: d0, to: d1).isEmpty)
    }

    @Test(arguments: RepoKind.allCases) func configOverridesWithAudit(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.configState() == DashboardConfigState(revision: 0, overrides: []))
        let r1 = try await repo.setConfigOverride(key: "RETENTION_RUNS", value: "20", audit: .values, now: t0)
        let r2 = try await repo.setConfigOverride(key: "OPERATOR_NAME", value: "Max Mustermann", audit: .masked, now: at(10))
        let r3 = try await repo.setConfigOverride(key: "RETENTION_RUNS", value: "24", audit: .values, now: at(20))
        #expect(r1 == 1 && r2 == 2 && r3 == 3)
        #expect(try await repo.configRevision() == 3)
        let state = try await repo.configState()
        #expect(state.revision == 3)
        #expect(state.overrides == [
            DashboardOverride(key: "OPERATOR_NAME", value: "Max Mustermann", updatedAt: at(10), revision: 2),
            DashboardOverride(key: "RETENTION_RUNS", value: "24", updatedAt: at(20), revision: 3),
        ])
        #expect(try await repo.resetConfigOverride(key: "UNKNOWN", audit: .values, now: at(25)) == nil)
        #expect(try await repo.configRevision() == 3)
        #expect(try await repo.resetConfigOverride(key: "RETENTION_RUNS", audit: .values, now: at(30)) == 4)
        #expect(try await repo.configState().overrides.map(\.key) == ["OPERATOR_NAME"])
        // Long audit text is clipped to 200 characters; the stored value stays complete.
        let long = String(repeating: "x", count: 450)
        _ = try await repo.setConfigOverride(key: "OPERATOR_ADDRESS", value: long, audit: .values, now: at(40))
        #expect(try await repo.configState().overrides.first?.value == long)
        try await repo.appendAudit(action: .login, key: nil, oldValue: nil, newValue: nil, now: at(50))
        let audit = try await repo.auditEntries(limit: 100)
        #expect(audit.map(\.action) == [.login, .set, .reset, .set, .set, .set])
        #expect(audit[1].newValue == String(repeating: "x", count: 200) && audit[1].oldValue == nil)
        #expect(audit[2] == DashboardAuditEntry(id: audit[2].id, at: at(30), action: .reset, key: "RETENTION_RUNS", oldValue: "24", newValue: nil))
        #expect(audit[3].key == "RETENTION_RUNS" && audit[3].oldValue == "20" && audit[3].newValue == "24")
        // Masked: neither old nor new text is stored.
        #expect(audit[4] == DashboardAuditEntry(id: audit[4].id, at: at(10), action: .set, key: "OPERATOR_NAME", oldValue: nil, newValue: "geändert"))
        #expect(!audit.contains { ($0.oldValue ?? "").contains("Mustermann") || ($0.newValue ?? "").contains("Mustermann") })
        #expect(Set(audit.map(\.id)).count == audit.count && audit.map(\.id) == audit.map(\.id).sorted(by: >))
        #expect(try await repo.auditEntries(limit: 2).count == 2)
        // Audit retention is 365 days.
        #expect(try await repo.purgeAudit(now: at(365 * day)) == 0)
        #expect(try await repo.purgeAudit(now: at(365 * day + 35)) == 4)
        #expect(try await repo.auditEntries(limit: 100).count == 2)
    }

    @Test(arguments: RepoKind.allCases) func concurrentOverrideWritesGetDistinctRevisions(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let revisions = await withTaskGroup(of: Int?.self) { group in
            for i in 0..<6 { group.addTask { try? await repo.setConfigOverride(key: "K\(i)", value: "v", audit: .values, now: t0) } }
            var all: [Int] = []
            for await r in group { if let r { all.append(r) } }
            return all.sorted()
        }
        #expect(revisions == Array(1...6))
        #expect(try await repo.configState().overrides.map(\.revision).sorted() == Array(1...6))
    }

    @Test(arguments: RepoKind.allCases) func restartGenerationAndMinimumInterval(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.generation() == GenerationState(generation: 0, requestedAt: nil))
        #expect(try await repo.requestRestart(minInterval: 60, now: t0) == 1)
        #expect(try await repo.generation() == GenerationState(generation: 1, requestedAt: t0))
        #expect(try await repo.requestRestart(minInterval: 60, now: at(59)) == nil)
        #expect(try await repo.requestRestart(minInterval: 60, now: at(60)) == 2)
        // Parallel clicks: only one passes the interval check.
        let passed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 { group.addTask { ((try? await repo.requestRestart(minInterval: 60, now: at(1000))) ?? nil) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(passed == 1)
        #expect(try await repo.generation().generation == 3)
        let audit = try await repo.auditEntries(limit: 10)
        #expect(audit.count == 3 && audit.allSatisfy { $0.action == .restart && $0.key == nil })
        #expect(audit[0].oldValue == "2" && audit[0].newValue == "3")
    }

    @Test(arguments: RepoKind.allCases) func replicaHeartbeatsAndSlots(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await repo.heartbeat(replicaID: "b", slot: 2, appliedGeneration: 0, now: t0)
        try await repo.heartbeat(replicaID: "a", slot: 1, appliedGeneration: 0, now: at(5))
        try await repo.heartbeat(replicaID: "z", slot: nil, appliedGeneration: 0, now: at(5))
        // A repeated heartbeat keeps started_at and updates generation, slot and last_seen_at.
        try await repo.heartbeat(replicaID: "b", slot: 3, appliedGeneration: 1, now: at(100))
        let rows = try await repo.replicas(now: at(100))
        let expected: [ReplicaRecord] = [
            ReplicaRecord(replicaID: "a", slot: 1, appliedGeneration: 0, startedAt: at(5), lastSeenAt: at(5)),
            ReplicaRecord(replicaID: "b", slot: 3, appliedGeneration: 1, startedAt: t0, lastSeenAt: at(100)),
            ReplicaRecord(replicaID: "z", slot: nil, appliedGeneration: 0, startedAt: at(5), lastSeenAt: at(5)),
        ]
        #expect(rows == expected)
        // Rows older than 10 minutes are ignored, then deleted by the retention.
        #expect(try await repo.replicas(now: at(5 + 601)).map(\.replicaID) == ["b"])
        #expect(try await repo.purgeDashboard(now: at(5 + 601)).replicas == 2)
        try await repo.removeReplica(replicaID: "b")
        #expect(try await repo.replicas(now: at(700)).isEmpty)
    }
}
