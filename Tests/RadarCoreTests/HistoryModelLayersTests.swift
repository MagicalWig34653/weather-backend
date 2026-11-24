import Foundation
import Testing
@testable import RadarCore

// HISTORY_HOURS = 48 and 72 for the model layers that HistoryAllLayersTests does not cover (it only has `pressure`):
// the ICON-D2 layers (temperature, dew point, humidity; own retention call in Icon2DIngestor) and `pressure_eu` (+24 h horizon).
// Real ingest ticks against the fakes and the repo (memory, MariaDB with RADAR_TEST_DB_*): retention of the stored runs and the
// manifest (`past_slots`, `history`, `history_hours`) are checked, nothing of the retention is replaced by a stub.

private let d2Now = TimeUtil.fromID("20261108T0800Z")!     // newest run = 06 UTC (like Icon2DIngestorTests)
private let euNow = TimeUtil.fromID("20261031T1037Z")!     // newest run = 06 UTC (like HistoryAllLayersTests)
private let d2Run = TimeUtil.fromID("20261108T0600Z")!
private let euRun = TimeUtil.fromID("20261031T0600Z")!
private let d2TinyGrid = GribGrid(ni: 5, nj: 4, dLat: 1, dLon: 1)

struct ModelHistoryCase: Sendable, CustomTestStringConvertible {
    let layer: String
    let hours: Int
    var testDescription: String { "\(layer) \(hours) h" }
    static let layers = ["temperature_d2", "dewpoint_d2", "humidity_d2", "pressure_eu"]
    static let all: [ModelHistoryCase] = [48, 72].flatMap { hours in layers.map { ModelHistoryCase(layer: $0, hours: hours) } }
}

/// One model layer with its fake source: ICON-D2 (49 hourly slots, +48 h) or the Europe pressure map (25 hourly slots, +24 h).
private struct ModelRig {
    let layer: String
    var isD2: Bool { layer.hasSuffix("_d2") }
    var now: Date { isD2 ? d2Now : euNow }
    var newestRun: Date { isD2 ? d2Run : euRun }
    var newestRunID: String { TimeUtil.toID(newestRun) }
    var leads: Int { isD2 ? 48 : 24 }
    var spec: LayerSpec {
        let spec = LayerCatalog.specs[layer]!
        return isD2 ? spec.resized(width: 64) : spec.resized(width: 48)
    }

    func config(hours: Int) -> Config {
        smallConfig { c in
            c.width = isD2 ? 64 : 48; c.layers = isD2 ? TempLayers.internalIDs : [layer]; c.layerPauseSeconds = 0; c.historyHours = hours
            c.temp.source = .icon_d2; c.temp.d2Params = ["td_2m", "relhum_2m"]
            c.pressureRetentionRuns = 2
        }
    }

    /// `later`: the clock runs that much after `now` (the next run of the layer is then the one to publish).
    func ingestor(_ repo: any Repo, _ provider: ConfigProvider, later: TimeInterval = 0) -> LayerIngestor {
        let at = now.addingTimeInterval(later)
        if isD2 {
            return LayerIngestor(spec: spec, configProvider: provider, repo: repo, fetch: FakeICON().fetch, owner: "a", sleep: { _ in },
                                 clock: { at }, d2Grid: d2TinyGrid)
        }
        return LayerIngestor(spec: spec, configProvider: provider, repo: repo, fetch: FakeSources(provider()).fetch, owner: "a", sleep: { _ in },
                             clock: { at })
    }

    /// One published run with the slots 0...`leads` (hourly), written like the forecast ingest does.
    func seedRun(_ repo: any Repo, nominal: Date) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await repo.layerTryClaim(layer: layer, runID: id, nominal: nominal, owner: "seed", leaseSeconds: 600, maxAttempts: 4))
        for lead in 0...leads {
            let slot = nominal.addingTimeInterval(Double(lead) * 3600)
            try await repo.layerPutSlot(layer: layer, SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: lead, slotTime: slot),
                                        contentType: "image/webp", data: Array("\(id)/\(lead)".utf8))
        }
        #expect(try await repo.layerPublish(layer: layer, runID: id, owner: "seed", expectedSlots: leads + 1))
    }

    /// 15 earlier runs every 6 h (90 h back, older than the newest run), then the ingest tick publishes the newest run.
    func seedAndPublishNewest(_ repo: any Repo, _ cfg: Config) async throws -> LayerTickResult {
        for i in 1...15 { try await seedRun(repo, nominal: newestRun.addingTimeInterval(-Double(i) * 6 * 3600)) }
        return try await ingestor(repo, ConfigProvider(cfg)).tick()
    }

    func manifest(_ repo: any Repo, _ cfg: Config) async throws -> [String: Any] {
        let body = try #require(try await LayerManifest.build(repo: repo, config: cfg, spec: spec))
        return try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
    }

    func slotCount(_ repo: any Repo, run: Int) async throws -> Int {
        try await repo.layerPublishedSlots(layer: layer, runID: TimeUtil.toID(newestRun.addingTimeInterval(-Double(run) * 6 * 3600))).count
    }
}

private func gaps(_ history: [String: Any]) -> [[String: Any]] { (history["gaps"] as? [[String: Any]]) ?? [] }

extension DatabaseSuites {
@Suite("History of the ICON-D2 layers and pressure_eu (HISTORY_HOURS 48 and 72)", .serialized)
struct HistoryModelLayersTests {
    @Test(arguments: RepoKind.allCases, ModelHistoryCase.all)
    func modelLayerKeepsAndListsPastValidTimes(kind: RepoKind, testCase: ModelHistoryCase) async throws {
        let hours = testCase.hours
        let rig = ModelRig(layer: testCase.layer)
        let repo = try await kind.make()
        let cfg = rig.config(hours: hours)
        let r = try await rig.seedAndPublishNewest(repo, cfg)
        #expect(r.published == rig.newestRunID && r.stored == rig.leads + 1, "\(testCase)")

        // retention: the newest 2 runs complete, older runs only the valid times they were current for (6 h each), nothing beyond the window
        #expect(try await rig.slotCount(repo, run: 0) == rig.leads + 1)
        #expect(try await rig.slotCount(repo, run: 1) == rig.leads + 1)
        let windowRuns = hours / 6
        for run in 2...windowRuns { #expect(try await rig.slotCount(repo, run: run) == 6, "run -\(run * 6) h, \(testCase)") }
        for run in (windowRuns + 1)...15 {
            #expect(try await rig.slotCount(repo, run: run) == 0, "run -\(run * 6) h is outside \(hours) h and must be gone, \(testCase)")
        }

        let m = try await rig.manifest(repo, cfg)
        #expect(m["layer"] as? String == (rig.spec.publicID ?? rig.spec.id) && m["history_hours"] as? Int == hours)
        // `slots` stays the newest run only, the forecast horizon is its own setting and does not follow the history duration
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == rig.leads + 1 && slots.first?["kind"] == "analysis" && slots.last?["kind"] == "forecast")
        #expect(m["forecast_horizon_minutes"] as? Int == rig.leads * 60)
        // `past_slots`: one slot per valid time, from the run that was current then, ascending, exactly `hours` of them
        let past = try #require(m["past_slots"] as? [[String: String]])
        #expect(past.count == hours, "\(testCase)")
        let times = past.map { $0["time"]! }
        #expect(times == times.sorted() && Set(times).count == hours)
        #expect(past.first?["time"] == TimeUtil.toISO(rig.newestRun.addingTimeInterval(-Double(hours) * 3600)))
        #expect(past.last?["time"] == TimeUtil.toISO(rig.newestRun.addingTimeInterval(-3600)))
        #expect(past.first?["kind"] == "analysis" && past.last?["kind"] == "forecast")
        #expect(past.filter { $0["kind"] == "analysis" }.count == hours / 6)  // every run's own time
        let history = try #require(m["history"] as? [String: Any])
        #expect(history["hours"] as? Int == hours && history["expected"] as? Int == hours && history["present"] as? Int == hours)
        #expect(history["complete"] as? Bool == true && gaps(history).isEmpty && history["oldest"] as? String == past.first?["time"])
        // every listed past slot (the oldest included) is a stored image
        for slot in past {
            let parts = slot["path"]!.dropLast(5).split(separator: "/").map(String.init)
            #expect(try await repo.layerGetSlot(layer: rig.layer, runID: parts[0], slotID: parts[1]) != nil, "\(slot)")
        }
    }

    /// Switching the duration live (the dashboard does that): the manifest follows at once, the retention after the next published run
    /// cleans up, a model run cannot be fetched again, so 48 -> 72 reports a gap instead of inventing slots.
    @Test(arguments: RepoKind.allCases, ModelHistoryCase.layers)
    func switchBetween72And48And72(kind: RepoKind, layer: String) async throws {
        let rig = ModelRig(layer: layer)
        let repo = try await kind.make()
        let live = Locked(rig.config(hours: 72))
        let provider = ConfigProvider { live.withLock { $0 } }
        for i in 1...15 { try await rig.seedRun(repo, nominal: rig.newestRun.addingTimeInterval(-Double(i) * 6 * 3600)) }
        _ = try await rig.ingestor(repo, provider).tick()
        #expect(((try await rig.manifest(repo, live.withLock { $0 }))["past_slots"] as? [Any])?.count == 72, "\(layer)")
        #expect(try await rig.slotCount(repo, run: 12) == 6, "\(layer)")  // 72 h: the run 72 h back is the oldest ...
        #expect(try await rig.slotCount(repo, run: 13) == 0, "\(layer)")

        // 72 -> 48: the manifest lists 48 h at once; the retention after the next run (6 h later) then removes what is older than 48 h
        live.withLock { $0.historyHours = 48 }
        #expect(((try await rig.manifest(repo, live.withLock { $0 }))["past_slots"] as? [Any])?.count == 48, "\(layer)")
        let next = try await rig.ingestor(repo, provider, later: 6 * 3600).tick()
        #expect(next.published == TimeUtil.toID(rig.newestRun.addingTimeInterval(6 * 3600)), "\(layer)")
        // relative to the old newest run: 42 h back is the oldest run that still covers a time inside 48 h of the new run, 48 h back is gone
        #expect(try await rig.slotCount(repo, run: 7) == 6, "\(layer)")
        #expect(try await rig.slotCount(repo, run: 8) == 0, "\(layer)")
        let cfg48 = live.withLock { $0 }
        let m48 = try await rig.manifest(repo, cfg48)
        #expect((m48["past_slots"] as? [Any])?.count == 48 && (m48["history"] as? [String: Any])?["complete"] as? Bool == true, "\(layer)")

        // 48 -> 72: what is gone is gone, the list says so with a gap, not with invented slots
        live.withLock { $0.historyHours = 72 }
        let m = try await rig.manifest(repo, live.withLock { $0 })
        let history = try #require(m["history"] as? [String: Any])
        #expect((m["past_slots"] as? [Any])?.count == 48 && m["history_hours"] as? Int == 72, "\(layer)")
        #expect(history["complete"] as? Bool == false && history["present"] as? Int == 48 && history["expected"] as? Int == 72, "\(layer)")
        #expect(gaps(history).count == 1 && gaps(history).first?["slots"] as? Int == 24, "\(layer)")
    }
}
}
