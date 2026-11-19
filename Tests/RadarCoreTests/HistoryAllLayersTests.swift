import Foundation
import Testing
@testable import RadarCore

// One history duration (HISTORY_HOURS = 48 or 72) for all maps, decision 19 Nov 2026: backfill, retention, manifest, retrieval.
// Everything runs with tiny images (48 px wide): the chain is what is tested, not the encoder.

private let layerNow = TimeUtil.fromID("20261031T1037Z")!

private func tinyConfig(_ layers: [String], hours: Int, _ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig { c in c.width = 48; c.layers = layers; c.layerPauseSeconds = 0; c.historyHours = hours; edit(&c) }
}

private func tinySpec(_ id: String) -> LayerSpec {
    let spec = LayerCatalog.specs[id]!
    return spec.fixedWidth == nil ? spec : spec.resized(width: 48)
}

private func makeIngestor(_ id: String, _ repo: any Repo, _ provider: ConfigProvider, _ src: FakeSources) -> LayerIngestor {
    LayerIngestor(spec: tinySpec(id), configProvider: provider, repo: repo, fetch: src.fetch, owner: "a", sleep: { _ in }, clock: { layerNow })
}

/// Ticks until the layer has nothing left to do (neither stored nor failed). Returns the number of stored slots.
@discardableResult
private func backfillAll(_ ing: LayerIngestor, maxTicks: Int = 400) async throws -> Int {
    var stored = 0
    for _ in 0..<maxTicks {
        let r = try await ing.tick()
        stored += r.stored
        if r.stored == 0 && r.failed == 0 { return stored }
    }
    Issue.record("backfill did not settle within \(maxTicks) ticks")
    return stored
}

private func manifestJSON(_ repo: any Repo, _ config: Config, _ id: String) async throws -> [String: Any] {
    let body = try #require(try await LayerManifest.build(repo: repo, config: config, spec: tinySpec(id)))
    return try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
}

private func iso(_ date: Date) -> String { TimeUtil.toISO(date) }

private func parseTime(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
}

private func requestedTimes(_ src: FakeSources, from start: Int = 0) -> [Date] {
    src.urls.dropFirst(start).compactMap { url -> Date? in
        guard let raw = url.components(separatedBy: "&TIME=").last?.components(separatedBy: "&").first?.removingPercentEncoding else { return nil }
        return parseTime(raw)
    }
}

/// Requests to the sources, without the capabilities documents that EUMETSAT layers ask for in every tick.
private func mapRequests(_ src: FakeSources) -> Int { src.urls.filter { !$0.contains("GetCapabilities") }.count }

private func gapList(_ history: [String: Any]) -> [[String: Any]] { (history["gaps"] as? [[String: Any]]) ?? [] }

/// Observation layers that the DWD/EUMETSAT fakes serve (the OPERA and NOAA layers have their own tests in OperaTests/NoaaRainTests).
private let observationLayers = ["lightning", "clouds", "cloudmask", "cloudmask_vis", "cloudmask_vis_eu"]

struct ObservationCase: Sendable, CustomTestStringConvertible {
    let hours: Int
    let layer: String
    var testDescription: String { "\(layer) \(hours) h" }
    static let all: [ObservationCase] = [48, 72].flatMap { hours in observationLayers.map { ObservationCase(hours: hours, layer: $0) } }
}

extension DatabaseSuites {
@Suite("History of all layers (HISTORY_HOURS 48 and 72)", .serialized)
struct HistoryAllLayersTests {
    // MARK: observation layers

    @Test(arguments: RepoKind.allCases, ObservationCase.all)
    func observationLayerBackfillsRetainsAndReportsTheDuration(kind: RepoKind, testCase: ObservationCase) async throws {
        let hours = testCase.hours, layer = testCase.layer
        let repo = try await kind.make()
        let cfg = tinyConfig([layer], hours: hours)
        let spec = tinySpec(layer)
        let src = FakeSources(cfg)
        let ing = makeIngestor(layer, repo, ConfigProvider(cfg), src)
        let stored = try await backfillAll(ing)

        // How far back the source can deliver: HISTORY_HOURS, cut at the measured limit of the source (lightning: 23 h).
        let reach = min(hours, spec.sourceHistoryHours ?? hours)
        let step = spec.stepSeconds
        let expectedSlots = Int(Double(hours) * 3600 / step) + 1
        let presentSlots = Int(Double(reach) * 3600 / step) + 1
        #expect(stored == presentSlots, "\(layer) \(hours) h")

        let m = try await manifestJSON(repo, cfg, layer)
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == presentSlots)
        let times = slots.map { $0["time"]! }
        #expect(times == times.sorted() && Set(times).count == times.count)
        #expect(slots.allSatisfy { $0["kind"] == "observation" })
        let referenceText = try #require(m["reference_time"] as? String)
        let latest = try #require(parseTime(referenceText))
        #expect(slots.last?["time"] == iso(latest))
        #expect(slots.first?["time"] == iso(latest.addingTimeInterval(-Double(reach) * 3600)))

        // additive history block, old fields unchanged
        #expect(m["history_hours"] as? Int == hours && m["schema"] as? Int == 1)
        let history = try #require(m["history"] as? [String: Any])
        #expect(history["hours"] as? Int == hours && history["expected"] as? Int == expectedSlots && history["present"] as? Int == presentSlots)
        #expect(history["oldest"] as? String == slots.first?["time"])
        if reach == hours {
            #expect(history["complete"] as? Bool == true && gapList(history).isEmpty)
        } else {
            // the source stops earlier: ONE gap from the start of the window to the oldest slot, no placeholder slot inside it
            #expect(history["complete"] as? Bool == false)
            let gaps = gapList(history)
            #expect(gaps.count == 1)
            #expect(gaps.first?["from"] as? String == iso(latest.addingTimeInterval(-Double(hours) * 3600)))
            #expect(gaps.first?["slots"] as? Int == expectedSlots - presentSlots)
            #expect(gaps.first?["to"] as? String == iso(latest.addingTimeInterval(-Double(reach) * 3600 - step)))
            // nothing older than the source limit was ever requested
            let oldestAsked = try #require(requestedTimes(src).min())
            #expect(oldestAsked >= latest.addingTimeInterval(-Double(reach) * 3600))
        }

        // the oldest listed slot can be fetched and is a real image of the layer's size
        let oldest = try #require(slots.first?["path"]).dropLast(5).split(separator: "/").map(String.init)
        let blob = try #require(try await repo.layerGetSlot(layer: layer, runID: oldest[0], slotID: oldest[1]))
        #expect(blob.contentType == "image/webp" && (try? ImagePipeline.decodeWebP(blob.data).width) == 48)

        // retention deletes nothing inside the duration: another tick (which also runs the retention) changes nothing
        let before = try await manifestBody(repo, cfg, layer)
        let calls = mapRequests(src)
        let again = try await ing.tick()
        #expect(again.stored == 0 && mapRequests(src) == calls)
        #expect(try await manifestBody(repo, cfg, layer) == before)
        let after = try #require((try await manifestJSON(repo, cfg, layer))["history"] as? [String: Any])
        #expect(after["present"] as? Int == presentSlots)
    }

    private func manifestBody(_ repo: any Repo, _ cfg: Config, _ id: String) async throws -> [UInt8] {
        try #require(try await LayerManifest.build(repo: repo, config: cfg, spec: tinySpec(id)))
    }

    @Test(arguments: RepoKind.allCases)
    func switchingBetween72And48CleansUpAndBackfillsWithoutTouchingKeptImages(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let live = Locked(tinyConfig(["clouds"], hours: 72))
        let provider = ConfigProvider { live.withLock { $0 } }
        let src = FakeSources(live.withLock { $0 })
        let ing = makeIngestor("clouds", repo, provider, src)
        #expect(try await backfillAll(ing) == 433)  // 72 h at 10 min: 432 steps + 1
        let all = try await repo.layerFirstSlots(layer: "clouds", since: .distantPast, before: .distantFuture)
        #expect(all.count == 433)
        let latest = try #require(all.last?.slotTime)

        // 72 -> 48 (live, as the dashboard does it): the manifest follows at once, the images older than 48 h go with the next tick
        live.withLock { $0.historyHours = 48 }
        var m = try await manifestJSON(repo, live.withLock { $0 }, "clouds")
        #expect((m["slots"] as? [Any])?.count == 289 && m["history_hours"] as? Int == 48)
        #expect((m["history"] as? [String: Any])?["complete"] as? Bool == true)
        let calls = mapRequests(src)
        _ = try await ing.tick()
        #expect(mapRequests(src) == calls)  // nothing needed from the source
        let kept = try await repo.layerFirstSlots(layer: "clouds", since: .distantPast, before: .distantFuture)
        // 289 listed slots plus one slot of slack (the retention keeps one step more than the manifest lists)
        #expect(kept.count == 290 && kept.first?.slotTime == latest.addingTimeInterval(-48 * 3600 - 600))
        let probe = try #require(kept.dropFirst(100).first)
        let probeBefore = try #require(try await repo.layerGetSlot(layer: "clouds", runID: probe.runID, slotID: probe.slotID))

        // 48 -> 72: the missing day is fetched, the 290 kept slots are not requested again and stay byte-identical
        live.withLock { $0.historyHours = 72 }
        let asked = src.count
        #expect(try await backfillAll(ing) == 433 - 290)
        let askedTimes = requestedTimes(src, from: asked)
        #expect(askedTimes.allSatisfy { $0 < latest.addingTimeInterval(-48 * 3600 - 600) })
        m = try await manifestJSON(repo, live.withLock { $0 }, "clouds")
        #expect((m["slots"] as? [Any])?.count == 433 && (m["history"] as? [String: Any])?["complete"] as? Bool == true)
        let probeAfter = try #require(try await repo.layerGetSlot(layer: "clouds", runID: probe.runID, slotID: probe.slotID))
        #expect(probeAfter.sha256 == probeBefore.sha256 && probeAfter.data == probeBefore.data)
    }

    @Test(arguments: RepoKind.allCases, [48, 72])
    func sourceGapIsReportedAndNeverFilled(kind: RepoKind, hours: Int) async throws {
        let repo = try await kind.make()
        let cfg = tinyConfig(["clouds"], hours: hours)
        let src = FakeSources(cfg)
        // the source has nothing for the whole hour 08:xx (six slots at 10 minutes)
        src.xmlFor = { $0.contains("TIME=2026-10-31T08%3A") }
        let ing = makeIngestor("clouds", repo, ConfigProvider(cfg), src)
        let stored = try await backfillAll(ing)
        let expected = hours * 6 + 1
        #expect(stored == expected - 6)

        let m = try await manifestJSON(repo, cfg, "clouds")
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == expected - 6 && !slots.contains { $0["time"]!.hasPrefix("2026-10-31T08:") })  // no placeholder
        let history = try #require(m["history"] as? [String: Any])
        #expect(history["complete"] as? Bool == false && history["present"] as? Int == expected - 6 && history["expected"] as? Int == expected)
        let gaps = gapList(history)
        #expect(gaps.count == 1 && gaps.first?["from"] as? String == "2026-10-31T08:00:00Z"
                && gaps.first?["to"] as? String == "2026-10-31T08:50:00Z" && gaps.first?["slots"] as? Int == 6)
        #expect(history["oldest"] as? String == slots.first?["time"])  // the gap is in the middle, the oldest slot is still the window start
        for id in ["20261031T0800Z", "20261031T0830Z"] { #expect(try await repo.layerGetSlot(layer: "clouds", runID: id, slotID: id) == nil) }
        // and it stays a gap: the failed slots are in their cooldown, nothing else is requested
        let calls = mapRequests(src)
        _ = try await ing.tick()
        #expect(mapRequests(src) == calls)
    }

    @Test(arguments: RepoKind.allCases, [48, 72])
    func layersAreServedThroughTheApiWithTheOldestSlotAndABoundedCache(kind: RepoKind, hours: Int) async throws {
        let repo = try await kind.make()
        var cfg = tinyConfig(["clouds"], hours: hours)
        let src = FakeSources(cfg)
        try await backfillAll(makeIngestor("clouds", repo, ConfigProvider(cfg), src))
        var total = 0
        for ref in try await repo.layerFirstSlots(layer: "clouds", since: .distantPast, before: .distantFuture) {
            total += try await repo.layerGetSlot(layer: "clouds", runID: ref.runID, slotID: ref.slotID)?.data.count ?? 0
        }
        cfg.cacheMaxBytes = total / 8  // far less than the slots of 48 or 72 hours
        let limit = cfg.cacheMaxBytes
        let api = Api(repo: repo, config: cfg, clock: { layerNow })
        let latest = try await api.handle(path: "/v1/layers/clouds/latest.json", ifNoneMatch: nil)
        #expect(latest.status == 200)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(latest.body)) as? [String: Any])
        let slots = try #require(doc["slots"] as? [[String: String]])
        #expect(slots.count == hours * 6 + 1 && doc["history_hours"] as? Int == hours)
        #expect(await api.cache.snapshot().entries == 0)  // the manifest loads no image: slots come in on demand

        // every listed slot, oldest first, is served; the cache never grows with the history
        var biggest = 0
        for slot in slots {
            let r = try await api.handle(path: "/v1/layers/clouds/" + slot["path"]!, ifNoneMatch: nil)
            #expect(r.status == 200 && r.headers.contains { $0.0 == "Cache-Control" && $0.1 == Api.immutable })
            biggest = max(biggest, r.body.count)
            let snap = await api.cache.snapshot()
            #expect(snap.bytes <= snap.maxBytes)
        }
        let snap = await api.cache.snapshot()
        #expect(snap.maxBytes == limit && snap.bytes <= limit && snap.entries < slots.count / 4)
        #expect(await api.cache.dbReads == slots.count)  // one read per slot, nothing preloaded
        #expect(biggest > 0)
    }

    // MARK: model (forecast) layers: past valid times

    /// One published run with the slots 0...`leads` (hourly), written like the forecast ingest does.
    private func seedRun(_ repo: any Repo, layer: String, nominal: Date, leads: Int = 12) async throws {
        let id = TimeUtil.toID(nominal)
        #expect(try await repo.layerTryClaim(layer: layer, runID: id, nominal: nominal, owner: "seed", leaseSeconds: 600, maxAttempts: 4))
        for lead in 0...leads {
            let slot = nominal.addingTimeInterval(Double(lead) * 3600)
            try await repo.layerPutSlot(layer: layer, SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: lead, slotTime: slot),
                                        contentType: "image/webp", data: Array("\(id)/\(lead)".utf8))
        }
        #expect(try await repo.layerPublish(layer: layer, runID: id, owner: "seed", expectedSlots: leads + 1))
    }

    private static let newestRun = TimeUtil.fromID("20261031T0600Z")!  // the run that the ingest at 10:37 publishes

    @Test(arguments: RepoKind.allCases, [48, 72])
    func modelLayerKeepsAndListsPastValidTimes(kind: RepoKind, hours: Int) async throws {
        let repo = try await kind.make()
        var cfg = tinyConfig(["pressure"], hours: hours)
        cfg.pressureForecastHours = 12; cfg.pressureRetentionRuns = 2
        // earlier runs every 6 h, 15 of them (90 h back), older than the new run; then the ingest publishes the newest run
        for i in 1...15 { try await seedRun(repo, layer: "pressure", nominal: Self.newestRun.addingTimeInterval(-Double(i) * 6 * 3600)) }
        let src = FakeSources(cfg)
        let r = try await makeIngestor("pressure", repo, ConfigProvider(cfg), src).tick()
        #expect(r.published == "20261031T0600Z" && r.stored == 13)

        // retention: the newest 2 runs complete, older runs only the valid times they were current for, nothing beyond the window
        func slotCount(_ run: Int) async throws -> Int {
            let nominal = Self.newestRun.addingTimeInterval(-Double(run) * 6 * 3600)
            return try await repo.layerPublishedSlots(layer: "pressure", runID: TimeUtil.toID(nominal)).count
        }
        let newestCount = try await slotCount(0), secondCount = try await slotCount(1)
        #expect(newestCount == 13 && secondCount == 13)
        let windowRuns = hours / 6
        for run in 2...windowRuns { #expect(try await slotCount(run) == 6, "run -\(run * 6) h") }
        for run in (windowRuns + 1)...15 { #expect(try await slotCount(run) == 0, "run -\(run * 6) h is outside \(hours) h and must be gone") }

        let m = try await manifestJSON(repo, cfg, "pressure")
        // `slots` is what it always was: the newest run, analysis then forecast
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == 13 && slots.first?["kind"] == "analysis" && slots.last?["kind"] == "forecast")
        #expect(slots.first?["time"] == "2026-10-31T06:00:00Z" && m["forecast_horizon_minutes"] as? Int == 720)
        // `past_slots`: one slot per valid time, from the run that was current then, ascending
        let past = try #require(m["past_slots"] as? [[String: String]])
        #expect(past.count == hours)
        let times = past.map { $0["time"]! }
        #expect(times == times.sorted() && Set(times).count == hours)
        #expect(past.first?["time"] == iso(Self.newestRun.addingTimeInterval(-Double(hours) * 3600)))
        #expect(past.last?["time"] == "2026-10-31T05:00:00Z")
        #expect(past.last?["path"] == "20261031T0000Z/20261031T0500Z.webp")  // lead 5 h of the run before the newest one
        #expect(past.last?["kind"] == "forecast" && past.first?["kind"] == "analysis")
        let analysis = past.filter { $0["kind"] == "analysis" }
        #expect(analysis.count == hours / 6)  // every run's own time
        #expect(m["history_hours"] as? Int == hours)
        let history = try #require(m["history"] as? [String: Any])
        #expect(history["hours"] as? Int == hours && history["expected"] as? Int == hours && history["present"] as? Int == hours)
        #expect(history["complete"] as? Bool == true && gapList(history).isEmpty && history["oldest"] as? String == past.first?["time"])
        // every listed past slot (the oldest included) is a stored image
        for slot in past {
            let parts = slot["path"]!.dropLast(5).split(separator: "/").map(String.init)
            #expect(try await repo.layerGetSlot(layer: "pressure", runID: parts[0], slotID: parts[1]) != nil, "\(slot)")
        }
    }

    @Test(arguments: RepoKind.allCases)
    func modelLayerGapIsReportedWhenNoRunCoversATime(kind: RepoKind) async throws {
        let repo = try await kind.make()
        var cfg = tinyConfig(["pressure"], hours: 48)
        cfg.pressureForecastHours = 12
        // the runs 18 h and 24 h before the newest one never existed; the run before them reaches only 12 h ahead
        for i in 1...9 where i != 3 && i != 4 { try await seedRun(repo, layer: "pressure", nominal: Self.newestRun.addingTimeInterval(-Double(i) * 6 * 3600)) }
        let src = FakeSources(cfg)
        _ = try await makeIngestor("pressure", repo, ConfigProvider(cfg), src).tick()
        let m = try await manifestJSON(repo, cfg, "pressure")
        let past = try #require(m["past_slots"] as? [[String: String]])
        let history = try #require(m["history"] as? [String: Any])
        // the run at -30 h covers -30 h ... -18 h (lead 12), the run at -12 h starts at -12 h: -17 h ... -13 h are missing
        let gaps = gapList(history)
        #expect(gaps.count == 1 && gaps.first?["from"] as? String == "2026-10-30T13:00:00Z"
                && gaps.first?["to"] as? String == "2026-10-30T17:00:00Z" && gaps.first?["slots"] as? Int == 5)
        #expect(history["complete"] as? Bool == false && history["present"] as? Int == 43 && past.count == 43)
        #expect(!past.contains { ["2026-10-30T13:00:00Z", "2026-10-30T15:00:00Z", "2026-10-30T17:00:00Z"].contains($0["time"]!) })  // no placeholder
    }

    @Test(arguments: RepoKind.allCases)
    func modelLayerSwitchBetween72And48(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let live = Locked(tinyConfig(["pressure"], hours: 72))
        live.withLock { $0.pressureForecastHours = 12 }
        let provider = ConfigProvider { live.withLock { $0 } }
        for i in 1...15 { try await seedRun(repo, layer: "pressure", nominal: Self.newestRun.addingTimeInterval(-Double(i) * 6 * 3600)) }
        let src = FakeSources(live.withLock { $0 })
        let ing = makeIngestor("pressure", repo, provider, src)
        _ = try await ing.tick()
        #expect(((try await manifestJSON(repo, live.withLock { $0 }, "pressure"))["past_slots"] as? [Any])?.count == 72)
        // 72 -> 48: the manifest lists 48 h at once; the retention of the next run cleans up (here: the retention call itself)
        live.withLock { $0.historyHours = 48 }
        #expect(((try await manifestJSON(repo, live.withLock { $0 }, "pressure"))["past_slots"] as? [Any])?.count == 48)
        _ = try await repo.layerRetainPast(layer: "pressure", keepNewest: 2, pastHours: 48, staleAfter: 3600)
        let older = TimeUtil.toID(Self.newestRun.addingTimeInterval(-9 * 6 * 3600))  // 54 h back: outside 48 h
        #expect(try await repo.layerPublishedSlots(layer: "pressure", runID: older).isEmpty)
        // 48 -> 72: what is gone is gone (a model run cannot be fetched again), the list says so with a gap, not with invented slots
        live.withLock { $0.historyHours = 72 }
        let m = try await manifestJSON(repo, live.withLock { $0 }, "pressure")
        let history = try #require(m["history"] as? [String: Any])
        #expect(history["complete"] as? Bool == false && history["present"] as? Int == 48 && history["expected"] as? Int == 72)
        #expect(gapList(history).count == 1 && gapList(history).first?["slots"] as? Int == 24)
    }
}
}
