import Foundation
import Testing
@testable import RadarCore

// Live switch of HISTORY_HOURS 72 -> 48 -> 72 for the observation layers that HistoryAllLayersTests does not switch (it has `clouds`):
// radar_eu (OPERA), radar_world (NOAA RRQPE) and lightning (the source delivers only 23 h). Real ingest ticks against the fakes
// and the repo; the retention is the real one.

private let switchNow: [String: Date] = [
    "radar_eu": TimeUtil.fromID("20261031T1037Z")!, "lightning": TimeUtil.fromID("20261031T1037Z")!, "radar_world": TimeUtil.fromID("20261117T1527Z")!,
]
private let worldGrid = RainRateGrid(width: 180, height: 66, step: 2.0)
private let worldTinyWidth = 36

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func add(_ url: String) { lock.withLock { urls.append(url) } }
    /// Requests for slot files (not the capabilities documents and bucket listings that come with every tick).
    var slotRequests: Int { lock.withLock { urls.filter { !$0.contains("GetCapabilities") && !$0.contains("?list-type=2") }.count } }
}

private func operaFile() -> [UInt8] {
    OdimFixture(width: 38, height: 44) { r, c in
        if c < 4 { return -9_999_000 }
        if (15...22).contains(c) && (18...25).contains(r) { return 30 }
        return -8_888_000
    }.make()
}

private func noaaFile() -> [UInt8] {
    var f = NetcdfFixture()
    f.rate = { r, c in
        if c < 20 { return -9990 }
        if r == 10 && c == 95 { return 50 }
        return 0
    }
    f.dqf = { r, _ in r < 5 ? 2 : 0 }
    return f.make()
}

/// Bucket listing of the hour in the request (all six slots of the hour, full version).
private func noaaListing(_ url: String) -> [UInt8] {
    let parts = (url.components(separatedBy: "prefix=").last ?? "").split(separator: "/")   // BLEND RainRate-Blend-INST 2026 11 17 15
    let hour = String(parts[2]) + parts[3] + parts[4] + parts[5], day = String(hour.prefix(8)), h = String(hour.suffix(2))
    let keys = (0..<6).map { i in
        "BLEND/RainRate-Blend-INST/\(day.prefix(4))/\(day.dropFirst(4).prefix(2))/\(day.suffix(2))/\(h)/RRQPE-INST-GLB-5_v1r1_blend_s\(hour)\(i)0000_e0_c0.nc"
    }
    return Array(("<ListBucketResult>" + keys.map { "<Contents><Key>\($0)</Key></Contents>" }.joined() + "</ListBucketResult>").utf8)
}

private struct SwitchRig {
    let layer: String
    var now: Date { switchNow[layer]! }
    var spec: LayerSpec {
        let spec = LayerCatalog.specs[layer]!
        switch layer {
        case "radar_eu": return spec.resized(width: 64)
        case "radar_world": return spec.resized(width: worldTinyWidth)
        default: return spec.resized(width: 48)
        }
    }
    var step: Double { spec.stepSeconds }
    /// How many hours back the source delivers for a duration of `hours` (lightning: 23 h).
    func reach(_ hours: Int) -> Int { min(hours, spec.sourceHistoryHours ?? hours) }
    func slots(_ hours: Int) -> Int { Int(Double(reach(hours)) * 3600 / step) + 1 }

    func config(hours: Int) -> Config {
        smallConfig { c in
            c.width = 48; c.layers = [layer]; c.layerPauseSeconds = 0; c.historyHours = hours
            c.operaURL = "https://main.test/bucket"; c.operaBackupURL = "https://backup.test/bucket"; c.noaaRainURL = "https://noaa.test/bucket"
        }
    }

    func ingestor(_ repo: any Repo, _ provider: ConfigProvider, _ requests: Requests, clock: @escaping @Sendable () -> Date) -> LayerIngestor {
        let inner: Fetch
        switch layer {
        case "radar_eu": let file = operaFile(); inner = { _ in file }
        case "radar_world": let file = noaaFile(); inner = { url in url.contains("?list-type=2") ? noaaListing(url) : file }
        default: inner = FakeSources(provider()).fetch
        }
        let fetch: Fetch = { url in requests.add(url); return try await inner(url) }
        return LayerIngestor(spec: spec, configProvider: provider, repo: repo, fetch: fetch, owner: "a", sleep: { _ in }, clock: clock, noaaGrid: worldGrid)
    }

    func manifest(_ repo: any Repo, _ cfg: Config) async throws -> [String: Any] {
        let body = try #require(try await LayerManifest.build(repo: repo, config: cfg, spec: spec))
        return try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
    }

    func allSlots(_ repo: any Repo) async throws -> [SlotRef] {
        try await repo.layerFirstSlots(layer: layer, since: .distantPast, before: .distantFuture)
    }
}

/// Ticks until the layer has nothing left to do. Returns the number of stored slots.
@discardableResult
private func settle(_ ing: LayerIngestor, maxTicks: Int = 400) async throws -> Int {
    var stored = 0
    for _ in 0..<maxTicks {
        let r = try await ing.tick()
        stored += r.stored
        if r.stored == 0 && r.failed == 0 { return stored }
    }
    Issue.record("did not settle within \(maxTicks) ticks")
    return stored
}

private func historyOf(_ manifest: [String: Any]) -> [String: Any] { (manifest["history"] as? [String: Any]) ?? [:] }

extension DatabaseSuites {
@Suite("History switch 72 -> 48 -> 72 for radar_eu, radar_world and lightning", .serialized)
struct HistorySwitchLayersTests {
    /// 72 -> 48 (live): the manifest follows at once, the next tick deletes what is older than 48 h (plus one step of slack) and requests nothing.
    /// 48 -> 72: only what is missing is fetched, kept slots are not requested again and stay byte-identical. For lightning the source
    /// reaches back 23 h only: nothing is deleted at 48 h, nothing is fetched at 72 h, the rest of the window stays a reported gap.
    @Test(arguments: RepoKind.allCases, ["radar_eu", "radar_world", "lightning"])
    func switchBetween72And48And72(kind: RepoKind, layer: String) async throws {
        let rig = SwitchRig(layer: layer)
        let repo = try await kind.make()
        let live = Locked(rig.config(hours: 72))
        let provider = ConfigProvider { live.withLock { $0 } }
        let requests = Requests()
        let now = rig.now
        let ing = rig.ingestor(repo, provider, requests) { now }
        let total72 = rig.slots(72)
        #expect(try await settle(ing) == total72, "\(layer)")
        let all = try await rig.allSlots(repo)
        #expect(all.count == total72, "\(layer)")
        let latest = try #require(all.last?.slotTime)
        var m = try await rig.manifest(repo, live.withLock { $0 })
        #expect((m["slots"] as? [Any])?.count == total72 && m["history_hours"] as? Int == 72, "\(layer)")
        #expect((historyOf(m))["expected"] as? Int == 72 * 3600 / Int(rig.step) + 1 && (historyOf(m))["present"] as? Int == total72, "\(layer)")

        // 72 -> 48
        live.withLock { $0.historyHours = 48 }
        m = try await rig.manifest(repo, live.withLock { $0 })
        let listed48 = rig.slots(48)
        #expect((m["slots"] as? [Any])?.count == listed48 && m["history_hours"] as? Int == 48, "\(layer)")
        #expect((historyOf(m))["hours"] as? Int == 48 && (historyOf(m))["expected"] as? Int == 48 * 3600 / Int(rig.step) + 1, "\(layer)")
        #expect((historyOf(m))["present"] as? Int == listed48 && (historyOf(m))["complete"] as? Bool == (rig.reach(72) >= 48), "\(layer)")
        let calls = requests.slotRequests
        _ = try await ing.tick()
        #expect(requests.slotRequests == calls, "nothing is needed from the source, \(layer)")
        let kept = try await rig.allSlots(repo)
        // the retention keeps one step more than the manifest lists; the source limit (lightning) is below 48 h anyway
        let keepSpan = min(48 * 3600 + rig.step, Double(rig.reach(72)) * 3600)
        #expect(kept.count == Int(keepSpan / rig.step) + 1 && kept.first?.slotTime == latest.addingTimeInterval(-keepSpan), "\(layer)")
        let probe = try #require(kept.dropFirst(100).first)
        let probeBefore = try #require(try await repo.layerGetSlot(layer: layer, runID: probe.runID, slotID: probe.slotID))

        // 48 -> 72
        live.withLock { $0.historyHours = 72 }
        let before = requests.slotRequests
        let refetched = try await settle(ing)
        #expect(refetched == total72 - kept.count && requests.slotRequests - before == refetched, "\(layer)")
        m = try await rig.manifest(repo, live.withLock { $0 })
        #expect((m["slots"] as? [Any])?.count == total72 && m["history_hours"] as? Int == 72, "\(layer)")
        #expect((historyOf(m))["complete"] as? Bool == (rig.reach(72) == 72) && (historyOf(m))["present"] as? Int == total72, "\(layer)")
        let probeAfter = try #require(try await repo.layerGetSlot(layer: layer, runID: probe.runID, slotID: probe.slotID))
        #expect(probeAfter.sha256 == probeBefore.sha256 && probeAfter.data == probeBefore.data, "\(layer)")
    }

    /// Lightning keeps recording: after a pause of 30 h the old and the new slots are 53 h apart, the source reaches 23 h back.
    /// 48 h removes the old slots that are older than 48 h (the retention is real), 72 h does not get them back: the source cannot
    /// deliver them, they stay a gap in `history`, nothing invented, nothing requested again and again.
    @Test(arguments: RepoKind.allCases)
    func lightningPausedThirtyHoursThenSwitchedTo48And72(kind: RepoKind) async throws {
        let rig = SwitchRig(layer: "lightning")
        let repo = try await kind.make()
        let live = Locked(rig.config(hours: 72))
        let provider = ConfigProvider { live.withLock { $0 } }
        let requests = Requests()
        let clock = Locked(rig.now)
        let ing = rig.ingestor(repo, provider, requests) { clock.withLock { $0 } }
        #expect(try await settle(ing) == 277)  // 23 h at 5 min
        clock.withLock { $0 = $0.addingTimeInterval(30 * 3600) }
        #expect(try await settle(ing) == 277)
        #expect(try await rig.allSlots(repo).count == 554)  // 72 h keeps both blocks
        let latest = try #require(try await rig.allSlots(repo).last?.slotTime)
        var history = historyOf(try await rig.manifest(repo, live.withLock { $0 }))
        #expect(history["present"] as? Int == 554 && history["expected"] as? Int == 865 && history["complete"] as? Bool == false)

        // 48 h: the old block loses the slots older than 48 h before the newest one (60 listed, one more by the slack of the retention)
        live.withLock { $0.historyHours = 48 }
        history = historyOf(try await rig.manifest(repo, live.withLock { $0 }))
        #expect(history["present"] as? Int == 554 - 60 && history["expected"] as? Int == 577)
        let calls = requests.slotRequests
        _ = try await ing.tick()
        #expect(requests.slotRequests == calls)
        let kept = try await rig.allSlots(repo)
        #expect(kept.count == 554 - 60 + 1 && kept.first?.slotTime == latest.addingTimeInterval(-48 * 3600 - 300))

        // back to 72 h: the 59 deleted slots are beyond what the source delivers, so nothing is requested and the gap is reported
        live.withLock { $0.historyHours = 72 }
        #expect(try await settle(ing) == 0)
        #expect(requests.slotRequests == calls)
        let m = try await rig.manifest(repo, live.withLock { $0 })
        history = historyOf(m)
        #expect((m["slots"] as? [Any])?.count == 554 - 59 && history["present"] as? Int == 554 - 59)
        #expect(history["complete"] as? Bool == false && history["oldest"] as? String == (m["slots"] as? [[String: String]])?.first?["time"])
    }
}
}
