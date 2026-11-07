import Foundation
import Testing
@testable import RadarCore

private let instDE = "11111111-1111-4111-8111-111111111111"
private let instEN = "22222222-2222-4222-8222-222222222222"

final class WarnTestCounter: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var counts: [String: Int] = [:]
    func record(_ metric: String, label: String, by value: Int) { lock.withLock { counts[metric + ":" + label, default: 0] += value } }
    subscript(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
}

@Suite("Warn service")
struct WarnServiceTests {
    let now = Date(timeIntervalSince1970: 1_794_000_000)

    func config(push: Bool = true, warnPush: Bool = true) -> Config {
        smallConfig { $0.push.enabled = push; $0.warn.ingestEnabled = true; $0.warn.pushEnabled = warnPush }
    }

    func setup(_ cfg: Config? = nil, stats: WarnTestCounter = WarnTestCounter()) async throws -> (MemoryRepo, WarnService, WarnTestCounter, subDE: String, subEN: String, subOther: String) {
        let repo = MemoryRepo()
        for (id, locale) in [(instDE, "de"), (instEN, "en")] {
            _ = try await repo.upsertInstallation(id: id, secretHash: "h", token: String(repeating: "ab", count: 32), env: .sandbox, locale: locale, now: now)
        }
        let all = Set(WarnKind.allCases)
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased(), c = UUID().uuidString.lowercased()
        _ = try await repo.addWarnSubscription(installationID: instDE, id: a, WarnSubscriptionInput(warncellIDs: ["814522510"], types: all), now: now)
        _ = try await repo.addWarnSubscription(installationID: instEN, id: b, WarnSubscriptionInput(warncellIDs: ["814522510", "811111111"], types: all), now: now)
        _ = try await repo.addWarnSubscription(installationID: instDE, id: c, WarnSubscriptionInput(warncellIDs: ["899999999"], types: all), now: now)
        let service = WarnService(config: cfg ?? config(), repo: repo, stats: stats, clock: { [now] in now })
        return (repo, service, stats, a, b, c)
    }

    func store(_ repo: MemoryRepo, _ id: String, kind: WarnKind = .frost, severity: Int = 1, ageSeconds: TimeInterval = 300, lang: String = "de",
               msgType: WarnMsgType = .alert, references: [String] = [], expires: Date? = nil, text: String? = nil) async throws -> WarnStoredAlert {
        let sent = now.addingTimeInterval(-ageSeconds)
        var a = warnTestAlert(id, lang: lang, kind: kind, severity: severity, sent: sent, expires: expires ?? now.addingTimeInterval(8 * 3600),
                              msgType: msgType, references: references, text: text ?? (lang == "en" ? "English text" : "Deutscher Text"))
        a.onset = now.addingTimeInterval(9 * 3600)
        return try await repo.upsertAlert(a, now: now)
    }

    func payloads(_ repo: MemoryRepo) async throws -> [[String: Any]] {
        try await repo.dueOutbox(now: now.addingTimeInterval(1), limit: 100).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.payloadJSON.utf8)) as? [String: Any]
        }
    }

    @Test func onlyTheMatchingSubscriptionsGetOnePush() async throws {
        let (repo, service, stats, a, b, _) = try await setup()
        let de = try await store(repo, "K1.DEU"), en = try await store(repo, "K1.ENG", lang: "en")
        #expect(try await service.trigger([de, en]) == 2)   // pair counts once per subscription
        let due = try await repo.dueOutbox(now: now.addingTimeInterval(1), limit: 10)
        #expect(due.count == 2 && Set(due.map(\.collapseID)) == [a + ":frost", b + ":frost"])
        #expect(stats["warn_push:sent"] == 2)
        for item in due {
            #expect(item.payloadJSON.utf8.count < 2048)
            #expect(item.expiresAt == now.addingTimeInterval(6 * 3600))
        }
    }

    @Test func languageFollowsTheInstallation() async throws {
        let (repo, service, _, _, _, _) = try await setup()
        let de = try await store(repo, "K1.DEU"), en = try await store(repo, "K1.ENG", lang: "en")
        _ = try await service.trigger([de, en])
        let bodies = try await payloads(repo).compactMap { (($0["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String }
        #expect(Set(bodies) == ["Deutscher Text\nQuelle: DWD", "English text\nQuelle: DWD"])
        let ids = try await payloads(repo).compactMap { $0["warning_id"] as? String }
        #expect(Set(ids) == ["K1.DEU", "K1.ENG"])
    }

    @Test func englishAloneFindsTheGermanCounterpartInTheStore() async throws {
        let (repo, service, _, _, _, _) = try await setup()
        _ = try await store(repo, "K1.DEU")
        let en = try await store(repo, "K1.ENG", lang: "en")
        _ = try await service.trigger([en])
        let bodies = try await payloads(repo).compactMap { (($0["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String }
        #expect(Set(bodies) == ["Deutscher Text\nQuelle: DWD", "English text\nQuelle: DWD"])
    }

    @Test func fallbackToTheOtherLanguageWhenOnlyOneExists() async throws {
        let (repo, service, _, _, _, _) = try await setup()
        _ = try await service.trigger([try await store(repo, "K1.DEU")])
        let bodies = try await payloads(repo).compactMap { (($0["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String }
        #expect(bodies.count == 2 && bodies.allSatisfy { $0 == "Deutscher Text\nQuelle: DWD" })
    }

    @Test func secondTriggerWithTheSameMessageSendsNothing() async throws {
        let (repo, service, stats, _, _, _) = try await setup()
        let de = try await store(repo, "K1.DEU")
        #expect(try await service.trigger([de]) == 2)
        #expect(try await service.trigger([de]) == 0)
        #expect(try await repo.dueOutbox(now: now.addingTimeInterval(1), limit: 10).count == 2)
        #expect(stats["warn_push:suppressed_noChange"] == 2)
    }

    @Test func updateWithHigherLevelSendsAgainWithTheSameCollapseID() async throws {
        let (repo, service, _, a, _, _) = try await setup()
        _ = try await service.trigger([try await store(repo, "K1.DEU")])
        let up = try await store(repo, "K2.DEU", severity: 2, ageSeconds: 60, msgType: .update, references: ["K1.DEU"])
        #expect(up.chainID == "K1")
        #expect(try await service.trigger([up]) == 2)
        let due = try await repo.dueOutbox(now: now.addingTimeInterval(1), limit: 10)
        #expect(due.filter { $0.collapseID == a + ":frost" }.count == 2)
        #expect(try await repo.warnSent(subID: a).map(\.lastSeverity) == [2])
    }

    @Test func updateWithTheSameLevelIsOnlyForTheList() async throws {
        let (repo, service, _, _, _, _) = try await setup()
        _ = try await service.trigger([try await store(repo, "K1.DEU")])
        let up = try await store(repo, "K2.DEU", severity: 1, ageSeconds: 60, msgType: .update, references: ["K1.DEU"])
        #expect(try await service.trigger([up]) == 0)
    }

    @Test func oldMessagesAndWeakLevelsAreSuppressed() async throws {
        let (repo, service, stats, _, _, _) = try await setup()
        #expect(try await service.trigger([try await store(repo, "OLD.DEU", ageSeconds: 1300)]) == 0)
        #expect(try await service.trigger([try await store(repo, "WX.DEU", kind: .severeWeather, severity: 2)]) == 0)
        #expect(stats["warn_push:suppressed_stale"] == 2 && stats["warn_push:suppressed_belowThreshold"] == 2)
        #expect(try await service.trigger([try await store(repo, "WX3.DEU", kind: .severeWeather, severity: 3)]) == 2)
    }

    @Test func switchesGateTheTrigger() async throws {
        for cfg in [config(push: true, warnPush: false), config(push: false, warnPush: true)] {
            let (repo, service, _, _, _, _) = try await setup(cfg)
            #expect(try await service.trigger([try await store(repo, "K1.DEU")]) == 0)
            #expect(try await repo.dueOutbox(now: now.addingTimeInterval(1), limit: 10).isEmpty)
        }
    }

    @Test func shortWarningExpiresTheOutboxEntryWithTheWarning() async throws {
        let (repo, service, _, _, _, _) = try await setup()
        let expires = now.addingTimeInterval(1800)
        _ = try await service.trigger([try await store(repo, "K1.DEU", expires: expires)])
        #expect(try await repo.dueOutbox(now: now.addingTimeInterval(1), limit: 10).allSatisfy { $0.expiresAt == expires })
    }

    @Test func levelFourIsTimeSensitiveEvenWithoutTheSwitch() async throws {
        let (repo, service, _, _, _, _) = try await setup()
        _ = try await service.trigger([try await store(repo, "K1.DEU", kind: .severeWeather, severity: 4)])
        let levels = try await payloads(repo).compactMap { ($0["aps"] as? [String: Any])?["interruption-level"] as? String }
        #expect(levels == ["time-sensitive", "time-sensitive"])
    }

    @Test func oversizedPayloadIsCountedNotSent() async throws {
        let (repo, service, stats, _, _, _) = try await setup()
        // A title of 120 bytes plus a body always fits, so force failure through a long identifier.
        let id = String(repeating: "X", count: 2100) + ".DEU"
        _ = try await service.trigger([try await store(repo, id)])
        #expect(stats["warn_push:payload_too_large"] == 2 && stats["warn_push:sent"] == 0)
    }
}
