import Foundation
import Testing
@testable import RadarCore

func warnTestAlert(_ id: String, lang: String = "de", kind: WarnKind = .frost, severity: Int = 1, sent: Date, expires: Date? = nil,
                   msgType: WarnMsgType = .alert, references: [String] = [], cells: [String] = ["814522510"], text: String = "T") -> WarnAlert {
    WarnAlert(identifier: id, kind: kind, severity: severity, event: kind == .frost ? "FROST" : "GLÄTTE", msgType: msgType, references: references,
              sent: sent, onset: sent.addingTimeInterval(3600), expires: expires ?? sent.addingTimeInterval(6 * 3600), headline: "H \(lang)", text: text,
              instruction: "I", lang: lang, warncellIDs: cells)
}

extension DatabaseSuites {
@Suite("Warn repo", .serialized)
struct WarnRepoTests {
    let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    @Test func alertKeyStripsLanguageSuffix() {
        #expect(WarnAlert.alertKey(identifier: "2.49.0.0.276.0.DWD.PVW.1.abc.DEU") == "2.49.0.0.276.0.DWD.PVW.1.abc")
        #expect(WarnAlert.alertKey(identifier: "2.49.0.0.276.0.DWD.PVW.1.abc.ENG") == "2.49.0.0.276.0.DWD.PVW.1.abc")
        #expect(WarnAlert.alertKey(identifier: "T.FROST.1") == "T.FROST.1")
    }

    @Test(arguments: RepoKind.allCases) func upsertIsIdempotentAndReplacesCells(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let a = warnTestAlert("K1.DEU", sent: t0, cells: ["814522510", "814522500"])
        let first = try await repo.upsertAlert(a, now: t0)
        #expect(first.status == "active" && first.chainID == "K1")
        var b = a; b.text = "neu"; b.warncellIDs = ["814522510"]
        _ = try await repo.upsertAlert(b, now: t0.addingTimeInterval(60))
        let active = try await repo.activeAlerts(now: t0.addingTimeInterval(120), lang: "de")
        #expect(active.count == 1)
        #expect(active.first?.alert.text == "neu" && active.first?.alert.warncellIDs == ["814522510"])
        #expect(active.first?.alert.headline == "H de" && active.first?.alert.instruction == "I")
        #expect(active.first?.alert.sent == t0 && active.first?.alert.kind == .frost)
        #expect(try await repo.alert(identifier: "K1.DEU")?.alert.text == "neu")
        #expect(try await repo.alert(identifier: "nope") == nil)
    }

    @Test(arguments: RepoKind.allCases) func updateKeepsChainAndSupersedesTheOldOne(kind: RepoKind) async throws {
        let repo = try await kind.make()
        _ = try await repo.upsertAlert(warnTestAlert("K1.DEU", sent: t0), now: t0)
        let u = try await repo.upsertAlert(warnTestAlert("K2.DEU", severity: 2, sent: t0.addingTimeInterval(600), msgType: .update,
                                                         references: ["K1.DEU"]), now: t0.addingTimeInterval(600))
        #expect(u.chainID == "K1")
        let active = try await repo.activeAlerts(now: t0.addingTimeInterval(700), lang: "de")
        #expect(active.map(\.alert.identifier) == ["K2.DEU"])
        #expect(try await repo.alert(identifier: "K1.DEU")?.status == "superseded")
        // Unknown reference: own key. Re-sending the old message never revives it.
        let lone = try await repo.upsertAlert(warnTestAlert("K9.DEU", sent: t0, msgType: .update, references: ["UNKNOWN.1"]), now: t0)
        #expect(lone.chainID == "K9")
        _ = try await repo.upsertAlert(warnTestAlert("K1.DEU", sent: t0), now: t0.addingTimeInterval(800))
        #expect(try await repo.alert(identifier: "K1.DEU")?.status == "superseded")
        // A late older message of an existing chain is stored as superseded.
        _ = try await repo.upsertAlert(warnTestAlert("K3.DEU", sent: t0.addingTimeInterval(1), msgType: .update, references: ["K1.DEU"]), now: t0.addingTimeInterval(900))
        #expect(try await repo.alert(identifier: "K3.DEU")?.status == "superseded")
    }

    @Test(arguments: RepoKind.allCases) func cancelAndExpiryRemoveFromActive(kind: RepoKind) async throws {
        let repo = try await kind.make()
        _ = try await repo.upsertAlert(warnTestAlert("C1.DEU", sent: t0), now: t0)
        _ = try await repo.upsertAlert(warnTestAlert("C2.DEU", kind: .ice, sent: t0, expires: t0.addingTimeInterval(1800)), now: t0)
        #expect(try await repo.activeAlerts(now: t0.addingTimeInterval(60), lang: "de").count == 2)
        try await repo.cancelAlerts(identifiers: ["C1.DEU"], now: t0.addingTimeInterval(60))
        #expect(try await repo.activeAlerts(now: t0.addingTimeInterval(61), lang: "de").map(\.alert.identifier) == ["C2.DEU"])
        #expect(try await repo.alert(identifier: "C1.DEU")?.status == "cancelled")
        #expect(try await repo.activeAlerts(now: t0.addingTimeInterval(1800), lang: "de").isEmpty)   // expires <= now
        // A Cancel message stores nothing but cancels its references.
        _ = try await repo.upsertAlert(warnTestAlert("C3.DEU", sent: t0), now: t0)
        let c = try await repo.upsertAlert(warnTestAlert("C4.DEU", sent: t0, msgType: .cancel, references: ["C3.DEU"]), now: t0.addingTimeInterval(10))
        #expect(c.status == "cancelled")
        let c4 = try await repo.alert(identifier: "C4.DEU"), c3 = try await repo.alert(identifier: "C3.DEU")
        #expect(c4 == nil && c3?.status == "cancelled")
    }

    @Test(arguments: RepoKind.allCases) func languagesPreferRequestedThenGerman(kind: RepoKind) async throws {
        let repo = try await kind.make()
        _ = try await repo.upsertAlert(warnTestAlert("L1.DEU", lang: "de", sent: t0), now: t0)
        _ = try await repo.upsertAlert(warnTestAlert("L1.ENG", lang: "en", sent: t0), now: t0)
        _ = try await repo.upsertAlert(warnTestAlert("L2.DEU", lang: "de", kind: .ice, sent: t0.addingTimeInterval(5)), now: t0)
        let en = try await repo.activeAlerts(now: t0.addingTimeInterval(60), lang: "en")
        #expect(en.map(\.alert.lang) == ["en", "de"] && en.map(\.alert.identifier) == ["L1.ENG", "L2.DEU"])
        let de = try await repo.activeAlerts(now: t0.addingTimeInterval(60), lang: "de")
        #expect(de.map(\.alert.identifier) == ["L1.DEU", "L2.DEU"])
        // Cancelling by the German identifier cancels the English twin as well.
        try await repo.cancelAlerts(identifiers: ["L1.DEU"], now: t0.addingTimeInterval(70))
        #expect(try await repo.activeAlerts(now: t0.addingTimeInterval(80), lang: "en").map(\.alert.identifier) == ["L2.DEU"])
    }

    @Test(arguments: RepoKind.allCases) func purgeAndFetchedAt(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.warnFetchedAt() == nil)
        try await repo.setWarnFetchedAt(t0); try await repo.setWarnFetchedAt(t0.addingTimeInterval(60))
        #expect(try await repo.warnFetchedAt() == t0.addingTimeInterval(60))
        _ = try await repo.upsertAlert(warnTestAlert("P1.DEU", sent: t0, expires: t0.addingTimeInterval(3600)), now: t0)
        _ = try await repo.upsertAlert(warnTestAlert("P2.DEU", sent: t0, expires: t0.addingTimeInterval(86400 * 3)), now: t0)
        _ = try await repo.upsertAlert(warnTestAlert("P3.DEU", sent: t0, expires: t0.addingTimeInterval(86400 * 3)), now: t0)
        try await repo.cancelAlerts(identifiers: ["P3.DEU"], now: t0)
        let day: TimeInterval = 86400
        #expect(try await repo.purgeWarnings(now: t0 + 3600 + 3600, retention: day) == 0)
        // 1 day after expiry of P1 and 1 day after the cancel of P3.
        #expect(try await repo.purgeWarnings(now: t0 + day + 3601, retention: day) == 2)
        let p1 = try await repo.alert(identifier: "P1.DEU"), p2 = try await repo.alert(identifier: "P2.DEU"), p3 = try await repo.alert(identifier: "P3.DEU")
        #expect(p1 == nil && p3 == nil && p2 != nil)
    }
}
}
