import Foundation
import Testing
@testable import RadarCore

private let inst = "11111111-1111-4111-8111-111111111111"
private let inst2 = "22222222-2222-4222-8222-222222222222"

private func newID() -> String { UUID().uuidString.lowercased() }

@discardableResult
private func register(_ repo: any Repo, _ id: String = inst) async throws -> UpsertResult {
    try await repo.upsertInstallation(id: id, secretHash: Hashing.sha256Hex(Array("s".utf8)), token: String(repeating: "ab", count: 32), env: .sandbox, locale: "de", now: run0)
}

private func input(_ cells: [String] = ["814522510"], types: Set<WarnKind> = Set(WarnKind.allCases), enabled: Bool = true) -> WarnSubscriptionInput {
    WarnSubscriptionInput(warncellIDs: cells, types: types, minSeverity: [.severeWeather: 3, .frost: 1, .ice: 2], enabled: enabled)
}

private func cells(_ from: Int, _ count: Int) -> [String] { (from..<(from + count)).map { String(800_000_000 + $0) } }

extension DatabaseSuites {
@Suite("Warn subscriptions", .serialized)
struct WarnSubRepoTests {
    @Test(arguments: RepoKind.allCases) func addListUpdateDelete(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let id = newID()
        #expect(try await repo.addWarnSubscription(installationID: inst, id: id, input(["814522510", "814522500"], types: [.frost, .ice]), now: run0) == .added)
        let listed = try await repo.warnSubscriptions(installationID: inst)
        #expect(listed.count == 1 && listed[0].id == id)
        #expect(Set(listed[0].input.warncellIDs) == ["814522510", "814522500"] && listed[0].input.types == [.frost, .ice])
        #expect(listed[0].input.minSeverity[.ice] == 2 && listed[0].input.minSeverity[.severeWeather] == 3 && listed[0].input.enabled)
        var changed = input(["814522510"], types: [.severeWeather], enabled: false)
        changed.timeSensitive = true
        changed.minSeverity[.severeWeather] = 4
        #expect(try await repo.updateWarnSubscription(installationID: inst, id: id, changed) == .updated)
        let after = try await repo.warnSubscriptions(installationID: inst)[0].input
        #expect(after.warncellIDs == ["814522510"] && after.types == [.severeWeather] && !after.enabled && after.timeSensitive && after.minSeverity[.severeWeather] == 4)
        #expect(try await repo.updateWarnSubscription(installationID: inst2, id: id, changed) == .notFound)
        #expect(try await repo.deleteWarnSubscription(installationID: inst2, id: id) == false)
        #expect(try await repo.deleteWarnSubscription(installationID: inst, id: id))
        #expect(try await repo.warnSubscriptions(installationID: inst).isEmpty)
    }

    @Test(arguments: RepoKind.allCases) func unknownInstallationIsRefused(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input(), now: run0) == .unknownInstallation)
    }

    @Test(arguments: RepoKind.allCases) func warnSubscriptionsAreInvisibleToRainFunctions(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let warnID = newID()
        _ = try await repo.addWarnSubscription(installationID: inst, id: warnID, input(), now: run0)
        #expect(try await repo.subscriptions(installationID: inst).isEmpty)
        #expect(try await repo.evaluationSubscriptions(gridVersion: PushGrid.version).isEmpty)
        // The rain routes cannot touch a warning subscription.
        let rain = PushSubscriptionInput(gridVersion: 1, cellX: 1, cellY: 1, threshold: 3, leadMinutes: 20, enabled: true)
        #expect(try await repo.updateSubscription(installationID: inst, id: warnID, rain) == false)
        #expect(try await repo.deleteSubscription(installationID: inst, id: warnID) == false)
        #expect(try await repo.warnSubscriptions(installationID: inst).count == 1)
        // The 10-subscription limit of the rain subscriptions ignores them, and vice versa.
        for _ in 0..<PushGrid.maxSubscriptionsPerInstallation {
            #expect(try await repo.addSubscription(installationID: inst, id: newID(), rain, maxPerInstallation: PushGrid.maxSubscriptionsPerInstallation, now: run0) == .created)
        }
        #expect(try await repo.addSubscription(installationID: inst, id: newID(), rain, maxPerInstallation: PushGrid.maxSubscriptionsPerInstallation, now: run0) == .limitReached)
        #expect(try await repo.subscriptions(installationID: inst).count == 10)
        #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input(), now: run0) == .added)
    }

    @Test(arguments: RepoKind.allCases) func subscriptionLimitsApply(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        for i in 0..<WarnLimits.maxSubscriptionsPerInstallation {
            #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input(cells(i, 1)), now: run0) == .added)
        }
        #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input(), now: run0) == .limit)
        // Cells per installation: 128 in total.
        try await register(repo, inst2)
        let a = newID(), b = newID()
        #expect(try await repo.addWarnSubscription(installationID: inst2, id: a, input(cells(0, 64)), now: run0) == .added)
        #expect(try await repo.addWarnSubscription(installationID: inst2, id: b, input(cells(100, 64)), now: run0) == .added)
        #expect(try await repo.addWarnSubscription(installationID: inst2, id: newID(), input(cells(300, 1)), now: run0) == .limit)
        #expect(try await repo.updateWarnSubscription(installationID: inst2, id: b, input(cells(100, 65))) == .limit)
        #expect(try await repo.updateWarnSubscription(installationID: inst2, id: b, input(cells(100, 10))) == .updated)
    }

    @Test(arguments: RepoKind.allCases) func unknownCellsAreRejectedOnlyOnceTheListIsSeeded(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        // Not seeded: every well-formed id is accepted.
        #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input(["999999999"]), now: run0) == .added)
        // A partly filled list does not switch the check on.
        try await repo.seedKnownWarnCells(["814522510"])
        #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input(["999999999"]), now: run0) == .added)
        try await repo.seedKnownWarnCells(cells(0, WarnCellCatalog.minimumSeed))
        #expect(try await repo.addWarnSubscription(installationID: inst, id: newID(), input([cells(5, 1)[0], "999999999"]), now: run0) == .unknownCell("999999999"))
        let ok = newID()
        #expect(try await repo.addWarnSubscription(installationID: inst, id: ok, input([cells(5, 1)[0]]), now: run0) == .added)
        #expect(try await repo.updateWarnSubscription(installationID: inst, id: ok, input(["999999998"])) == .unknownCell("999999998"))
    }

    @Test(arguments: RepoKind.allCases) func matchingFindsOnlyEnabledOverlap(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let hit = newID(), off = newID(), other = newID()
        _ = try await repo.addWarnSubscription(installationID: inst, id: hit, input(["814522510", "814522500"]), now: run0)
        _ = try await repo.addWarnSubscription(installationID: inst, id: off, input(["814522510"], enabled: false), now: run0)
        _ = try await repo.addWarnSubscription(installationID: inst, id: other, input(["811111111"]), now: run0)
        let found = try await repo.warnSubscriptions(matching: ["814522500", "000000000"])
        #expect(found.map(\.id) == [hit] && found[0].installationID == inst && Set(found[0].input.warncellIDs) == ["814522510", "814522500"])
        #expect(try await repo.warnSubscriptions(matching: []).isEmpty)
    }

    private func send(_ sub: String, chain: String = "K1", sev: Int = 1, key: String = "d1", at: Date) -> WarnSendItem {
        WarnSendItem(subID: sub, record: WarnSentRecord(chainID: chain, kind: .frost, lastSeverity: sev, lastOnset: at.addingTimeInterval(3600), lastSentAt: at),
                     outbox: NewOutboxItem(subID: sub, dedupeKey: key, collapseID: sub + ":frost", payloadJSON: "{}", expiresAt: at.addingTimeInterval(3600)))
    }

    @Test(arguments: RepoKind.allCases) func commitStoresStateOncePerDedupeKey(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let sub = newID()
        _ = try await repo.addWarnSubscription(installationID: inst, id: sub, input(), now: run0)
        #expect(try await repo.commitWarnSend([send(sub, at: run0)], now: run0) == 1)
        #expect(try await repo.warnSent(subID: sub) == [WarnSentRecord(chainID: "K1", kind: .frost, lastSeverity: 1, lastOnset: run0.addingTimeInterval(3600), lastSentAt: run0)])
        // Same dedupe key: no second outbox entry, state is not overwritten.
        #expect(try await repo.commitWarnSend([send(sub, sev: 3, at: run0.addingTimeInterval(60))], now: run0.addingTimeInterval(60)) == 0)
        #expect(try await repo.warnSent(subID: sub).first?.lastSeverity == 1)
        // New key in the same chain updates the record.
        #expect(try await repo.commitWarnSend([send(sub, sev: 2, key: "d2", at: run0.addingTimeInterval(120))], now: run0.addingTimeInterval(120)) == 1)
        let records = try await repo.warnSent(subID: sub)
        #expect(records.count == 1 && records[0].lastSeverity == 2)
        // The delivery path of the rain pushes finds the entries.
        #expect(try await repo.dueOutbox(now: run0.addingTimeInterval(200), limit: 10).count == 2)
        // Unknown subscription: nothing happens.
        #expect(try await repo.commitWarnSend([send(newID(), key: "x", at: run0)], now: run0) == 0)
    }

    @Test(arguments: RepoKind.allCases) func deletingTheInstallationRemovesEverything(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let sub = newID()
        _ = try await repo.addWarnSubscription(installationID: inst, id: sub, input(), now: run0)
        _ = try await repo.commitWarnSend([send(sub, at: run0)], now: run0)
        try await repo.deleteInstallation(id: inst)
        #expect(try await repo.warnSubscriptions(matching: ["814522510"]).isEmpty)
        #expect(try await repo.warnSent(subID: sub).isEmpty)
        #expect(try await repo.dueOutbox(now: run0.addingTimeInterval(10), limit: 10).isEmpty)
    }

    @Test(arguments: RepoKind.allCases) func purgeRemovesOldSentState(kind: RepoKind) async throws {
        let repo = try await kind.make()
        try await register(repo)
        let sub = newID()
        _ = try await repo.addWarnSubscription(installationID: inst, id: sub, input(), now: run0)
        _ = try await repo.commitWarnSend([send(sub, chain: "old", key: "o", at: run0), send(sub, chain: "new", key: "n", at: run0.addingTimeInterval(7200))], now: run0)
        #expect(try await repo.purgeWarnSent(before: run0.addingTimeInterval(3600)) == 1)
        #expect(try await repo.warnSent(subID: sub).map(\.chainID) == ["new"])
    }
}
}
