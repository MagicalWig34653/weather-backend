import Foundation
import Testing
@testable import RadarCore

// Radar DE (the main radar, Ingestor + history.json) with HISTORY_HOURS = 48 and 72. HistoryTests only has the retention with
// historyHours = 1; 48 is only tested for the delivery and 72 only for the backfill budget. The retention is the real one
// (`Ingestor.process` -> `repo.retain`), the old analysis slots are stored like the backfill stores them.

private let deNewest = TimeUtil.fromID("20261030T1200Z")!
private let deNow = deNewest.addingTimeInterval(210)      // newest regular run 12:00 (200 s availability delay plus 10 s)
private let deStep: TimeInterval = 300

private func deJSON(_ body: [UInt8]) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
}

/// One analysis slot like the backfill stores it (claim, slot, publish), without any DWD access.
private func seedAnalysis(_ repo: any Repo, _ time: Date) async throws {
    let id = TimeUtil.toID(time)
    #expect(try await repo.tryClaim(runID: id, nominal: time, owner: "seed", leaseSeconds: 600, maxAttempts: 4, backfill: true))
    try await repo.putSlot(SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: time), contentType: "image/webp", data: Array(id.utf8))
    #expect(try await repo.publish(runID: id, owner: "seed", expectedSlots: 1))
}

/// 90 hours of analysis slots every 5 minutes before `newest` (more than any history duration), no gap.
private func seedNinetyHours(_ repo: any Repo, before newest: Date) async throws {
    for i in 1...(90 * 12) { try await seedAnalysis(repo, newest.addingTimeInterval(-Double(i) * deStep)) }
}

private func ingest(_ repo: any Repo, _ provider: ConfigProvider, run: Date) async throws {
    let ing = Ingestor(configProvider: provider, repo: repo, fetch: FakeDwd(provider()).fetch, owner: "a", sleep: { _ in }, transcode: memoizedTranscode)
    _ = try await ing.process(run: run)
}

private func historyDoc(_ repo: any Repo, _ cfg: Config) async throws -> [String: Any] {
    try deJSON(try #require(try await Manifest.buildHistory(repo: repo, config: cfg)))
}

/// Number of analysis slots that are still stored (all of them, whatever the window).
private func storedAnalysis(_ repo: any Repo) async throws -> [SlotRef] {
    try await repo.analysisSlots(since: .distantPast, before: .distantFuture)
}

private func hasSlot(_ repo: any Repo, _ time: Date) async throws -> Bool {
    let id = TimeUtil.toID(time)
    return try await repo.getSlot(runID: id, slotID: id) != nil
}

extension DatabaseSuites {
@Suite("Radar DE history (HISTORY_HOURS 48 and 72)", .serialized)
struct HistoryRadarDETests {
    @Test(arguments: RepoKind.allCases, [48, 72])
    func retentionKeepsTheDurationPlusSlackAndHistoryJsonReportsIt(kind: RepoKind, hours: Int) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.retentionRuns = 15; $0.historyHours = hours }
        try await seedNinetyHours(repo, before: deNewest)
        #expect(try await storedAnalysis(repo).count == 90 * 12)
        try await ingest(repo, ConfigProvider(cfg), run: deNewest)

        // the retention keeps `run - (HISTORY_HOURS * 3600 + 900)` and newer: 3 slots of slack beyond the window, everything older is gone
        let keepSince = deNewest.addingTimeInterval(-(Double(hours) * 3600 + 900))
        #expect(try await hasSlot(repo, keepSince))
        #expect(try await !hasSlot(repo, keepSince.addingTimeInterval(-deStep)))
        #expect(try await !hasSlot(repo, deNewest.addingTimeInterval(-Double(hours + 10) * 3600)))
        #expect(try await storedAnalysis(repo).count == hours * 12 + 4, "\(hours) h")  // window plus 4 older slots: run -H and 3 of slack

        // history.json: window (newest - H, newest], every grid point is there, the oldest one can be fetched
        let doc = try await historyDoc(repo, cfg)
        let slots = try #require(doc["slots"] as? [[String: String]])
        #expect(slots.count == hours * 12 && doc["history_hours"] as? Int == hours)
        #expect(slots.first?["time"] == TimeUtil.toISO(deNewest.addingTimeInterval(-Double(hours) * 3600 + deStep)))
        #expect(slots.last?["time"] == TimeUtil.toISO(deNewest))
        let times = slots.map { $0["time"]! }
        #expect(times == times.sorted() && slots.allSatisfy { $0["kind"] == "analysis" })
        let history = try #require(doc["history"] as? [String: Any])
        #expect(history["hours"] as? Int == hours && history["expected"] as? Int == hours * 12 && history["present"] as? Int == hours * 12)
        #expect(history["complete"] as? Bool == true && (history["gaps"] as? [Any])?.isEmpty == true && history["oldest"] as? String == slots.first?["time"])
        let oldest = try #require(slots.first?["path"]).split(separator: "/").map(String.init)
        #expect(try await repo.getSlot(runID: oldest[0], slotID: String(oldest[1].dropLast(5))) != nil)
        // the backfilled analysis slots never show up in latest.json: it is the newest run only
        let latest = try deJSON(try #require(try await Manifest.build(repo: repo, config: cfg)))
        #expect((latest["slots"] as? [Any])?.count == 25)
    }

    /// The same data base: 72 -> 48 (cleanup with the next run), 48 -> 72 (a gap that the backfill would fill, not invented slots).
    @Test(arguments: RepoKind.allCases)
    func switchBetween72And48And72(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let live = Locked(smallConfig { $0.retentionRuns = 15; $0.historyHours = 72 })
        let provider = ConfigProvider { live.withLock { $0 } }
        try await seedNinetyHours(repo, before: deNewest)
        try await ingest(repo, provider, run: deNewest)
        #expect(try await storedAnalysis(repo).count == 72 * 12 + 4)
        let probe = deNewest.addingTimeInterval(-30 * 3600)
        let probeBlob = try #require(try await repo.getSlot(runID: TimeUtil.toID(probe), slotID: TimeUtil.toID(probe)))

        // 72 -> 48: history.json follows at once ...
        live.withLock { $0.historyHours = 48 }
        let doc48 = try await historyDoc(repo, live.withLock { $0 })
        var history = try #require(doc48["history"] as? [String: Any])
        #expect(history["expected"] as? Int == 576 && history["present"] as? Int == 576 && history["complete"] as? Bool == true)
        #expect((doc48["slots"] as? [Any])?.count == 576)
        // ... the old slots go with the next run (5 minutes later), the ones inside 48 h are untouched
        let next = deNewest.addingTimeInterval(deStep)
        try await ingest(repo, provider, run: next)
        #expect(try await storedAnalysis(repo).count == 48 * 12 + 4)  // window plus run -H and 3 slots of slack, seen from the new run
        #expect(try await !hasSlot(repo, next.addingTimeInterval(-Double(48 * 3600 + 1200))))
        let probeAfter = try #require(try await repo.getSlot(runID: TimeUtil.toID(probe), slotID: TimeUtil.toID(probe)))
        #expect(probeAfter.sha256 == probeBlob.sha256 && probeAfter.data == probeBlob.data)

        // 48 -> 72: what is gone is gone, history.json says so with one gap (the backfill would fetch exactly these slots)
        live.withLock { $0.historyHours = 72 }
        let cfg72 = live.withLock { $0 }
        let doc72 = try await historyDoc(repo, cfg72)
        history = try #require(doc72["history"] as? [String: Any])
        // present: the 48 h window plus the 4 slots that the retention keeps beyond it, which lie inside the 72 h window
        #expect(history["expected"] as? Int == 864 && history["present"] as? Int == 580 && history["complete"] as? Bool == false)
        let gaps = try #require(history["gaps"] as? [[String: Any]])
        #expect(gaps.count == 1 && gaps.first?["slots"] as? Int == 284)
        let slots72 = try #require(doc72["slots"] as? [[String: String]])
        #expect(slots72.count == 580 && history["oldest"] as? String == slots72.first?["time"])
        let backfill = Backfiller(config: cfg72, repo: repo, fetch: FakeDwd(cfg72).fetch, owner: "a", sleep: { _ in }, clock: { next.addingTimeInterval(210) })
        let missing = try await backfill.missing(now: next.addingTimeInterval(210))
        #expect(missing.count == 284 && missing.first == next.addingTimeInterval(-Double(48 * 3600 + 1200)))
        #expect(missing.last == next.addingTimeInterval(-Double(72 * 3600) + deStep))
    }
}
}
