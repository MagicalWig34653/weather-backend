import Foundation
import Testing
@testable import RadarCore

private let tick5: TimeInterval = 300
/// The clock of the backfill tests: the newest regular run is 12:00 (200 s availability delay plus 10 s).
private let latest0 = TimeUtil.fromID("20261030T1200Z")!
private let now0 = latest0.addingTimeInterval(210)

private func header(_ r: ApiResponse, _ n: String) -> String? { r.headers.first { $0.0 == n }?.1 }

private func json(_ body: [UInt8]) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
}

/// Stores one analysis slot like the backfill does (claim, slot, publish), without any DWD access.
@discardableResult
private func seed(_ repo: any Repo, _ time: Date, backfill: Bool = true, bytes: [UInt8] = Array("x".utf8)) async throws -> Bool {
    let id = TimeUtil.toID(time)
    guard try await repo.tryClaim(runID: id, nominal: time, owner: "seed", leaseSeconds: 600, maxAttempts: 4, backfill: backfill) else { return false }
    try await repo.putSlot(SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: time), contentType: "image/webp", data: bytes)
    return try await repo.publish(runID: id, owner: "seed", expectedSlots: 1)
}

/// Fake DWD that records the requested TIME values.
private final class RecordingDwd: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var times: [String] = []
    private let png: [UInt8]
    private let failEvery: Int
    private var n = 0
    init(_ config: Config, failEvery: Int = 0) {
        png = pngBytes(makeImage(width: config.width, height: config.height, seed: 2)); self.failEvery = failEvery
    }
    var calls: Int { lock.withLock { times.count } }
    var fetch: Fetch {
        { [self] url in
            let time = (url.components(separatedBy: "&TIME=").last?.components(separatedBy: "&").first ?? "").removingPercentEncoding ?? ""
            let count = lock.withLock { () -> Int in times.append(time); n += 1; return n }
            if failEvery > 0, count % failEvery == 0 { return xmlError }  // every n-th answer is the known XML error
            return png
        }
    }
}

private func backfiller(_ repo: any Repo, _ cfg: Config, owner: String = "a", fetch: @escaping Fetch,
                        isBusy: @escaping @Sendable () -> Bool = { false },
                        sleep: @escaping @Sendable (Double) async -> Void = { _ in }) -> Backfiller {
    Backfiller(config: cfg, repo: repo, fetch: fetch, owner: owner, isBusy: isBusy, sleep: sleep, clock: { now0 })
}

@Suite("Configuration HISTORY_HOURS")
struct HistoryConfigTests {
    @Test func defaultAndBounds() throws {
        #expect(try Config.fromEnvironment([:]).historyHours == 48)
        #expect(try Config.fromEnvironment(["HISTORY_HOURS": "1"]).historyHours == 1)
        #expect(try Config.fromEnvironment(["HISTORY_HOURS": "72"]).historyHours == 72)
        for bad in ["0", "73", "-5", "abc", "1.5", ""] {
            #expect(throws: ConfigError.self, "\(bad)") { _ = try Config.fromEnvironment(["HISTORY_HOURS": bad]) }
        }
        do { _ = try Config.fromEnvironment(["HISTORY_HOURS": "100"]) } catch {
            #expect(String(describing: error).contains("HISTORY_HOURS must be between 1 and 72"))
        }
    }
}

extension DatabaseSuites {
@Suite("History retention and history.json", .serialized)
struct HistoryTests {
    @Test(arguments: RepoKind.allCases)
    func retentionKeepsAnalysisSlotsForTheHistoryWindowOnly(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.retentionRuns = 15; $0.historyHours = 1 }
        let dwd = FakeDwd(cfg)
        for i in 0..<20 {  // 11:05 ... 12:40
            let ing = Ingestor(config: cfg, repo: repo, fetch: dwd.fetch, owner: "a", sleep: { _ in })
            _ = try await ing.process(run: run0.addingTimeInterval(Double(i) * tick5))
        }
        func has(_ run: String, _ slot: String) async throws -> Bool { try await repo.getSlot(runID: run, slotID: slot) != nil }
        // Window: keep 12:40 - 1h - 15 min = 11:25 and newer.
        #expect(try await !has("20261030T1120Z", "20261030T1120Z"))  // expired completely
        #expect(try await has("20261030T1125Z", "20261030T1125Z"))   // beyond 15 runs: analysis stays ...
        #expect(try await !has("20261030T1125Z", "20261030T1130Z"))  // ... forecast slots go
        #expect(try await has("20261030T1140Z", "20261030T1145Z"))   // newest 15 runs stay complete
        #expect(try await has("20261030T1240Z", "20261030T1305Z"))
        // history.json: window (12:40 - 1h, 12:40], all slots resolvable, ascending, analysis only
        let body = try #require(try await Manifest.buildHistory(repo: repo, config: cfg))
        let doc = try json(body)
        let slots = try #require(doc["slots"] as? [[String: String]])
        #expect(slots.count == 12)
        #expect(slots.first?["time"] == "2026-10-30T11:45:00Z" && slots.last?["time"] == "2026-10-30T12:40:00Z")
        #expect(slots.map { $0["time"]! } == slots.map { $0["time"]! }.sorted())
        #expect(slots.allSatisfy { $0["kind"] == "analysis" })
        for slot in slots {
            let parts = slot["path"]!.split(separator: "/")
            #expect(try await has(String(parts[0]), String(parts[1].split(separator: ".")[0])), "\(slot)")
        }
        // latest.json keeps its shape: 12 earlier analyses + 25 slots of the newest run
        let latest = try json(try #require(try await Manifest.build(repo: repo, config: cfg)))
        #expect((latest["slots"] as? [Any])?.count == 12 + 25)
    }

    @Test(arguments: RepoKind.allCases)
    func retentionNeverRemovesSlotsOfValidManifests(kind: RepoKind) async throws {
        let repo = try await kind.make()
        var manifests: [(latest: [String: Any], history: [String: Any])] = []
        let cfg = smallConfig { $0.retentionRuns = 15; $0.historyHours = 1 }
        let dwd = FakeDwd(cfg)
        for i in 0..<20 {
            let ing = Ingestor(config: cfg, repo: repo, fetch: dwd.fetch, owner: "a", sleep: { _ in })
            _ = try await ing.process(run: run0.addingTimeInterval(Double(i) * tick5))
            manifests.append((try json(try #require(try await Manifest.build(repo: repo, config: cfg))),
                              try json(try #require(try await Manifest.buildHistory(repo: repo, config: cfg)))))
        }
        for m in manifests.suffix(3) {
            for doc in [m.latest, m.history] {
                for slot in doc["slots"] as! [[String: String]] {
                    let parts = slot["path"]!.split(separator: "/")
                    let name = String(parts[1].split(separator: ".")[0])
                    #expect(try await repo.getSlot(runID: String(parts[0]), slotID: name) != nil, "\(doc["run"]!) \(slot)")
                }
            }
        }
    }

    @Test(arguments: RepoKind.allCases)
    func fortyEightHoursAreServedSortedAndSmall(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig()  // 48 h
        let newest = latest0
        // Every second slot is missing (gaps are allowed); the 49th hour back must not appear.
        for i in stride(from: 0, through: 12 * 49, by: 2) { try await seed(repo, newest.addingTimeInterval(-Double(i) * tick5)) }
        let api = Api(repo: repo, config: cfg, clock: { now0 })
        let response = try await api.handle(path: "/v1/radar/history.json", ifNoneMatch: nil)
        #expect(response.status == 200)
        let doc = try json(response.body)
        let slots = try #require(doc["slots"] as? [[String: String]])
        #expect(slots.count == 288)  // 576 grid points, every second one present
        #expect(slots.last?["time"] == "2026-10-30T12:00:00Z")
        #expect(slots.first?["time"] == "2026-10-28T12:05:00Z" || slots.first?["time"] == "2026-10-28T12:10:00Z")
        let times = slots.map { $0["time"]! }
        #expect(times == times.sorted())
        #expect(response.body.count < 80_000)
    }

    @Test(arguments: RepoKind.allCases)
    func historyEndpointContractHeadersEtagAnd404(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 6 }
        let api = Api(repo: repo, config: cfg)
        #expect(try await api.handle(path: "/v1/radar/history.json", ifNoneMatch: nil).status == 404)
        let ing = Ingestor(config: cfg, repo: repo, fetch: FakeDwd(cfg).fetch, owner: "a", sleep: { _ in })
        _ = try await ing.process(run: run0)
        for i in 1...4 { try await seed(repo, run0.addingTimeInterval(-Double(i) * tick5)) }

        let api2 = Api(repo: repo, config: cfg), api3 = Api(repo: repo, config: cfg)
        let r = try await api2.handle(path: "/v1/radar/history.json", ifNoneMatch: nil)
        #expect(r.status == 200)
        #expect(header(r, "Cache-Control") == "public, max-age=60, stale-while-revalidate=60")
        #expect(header(r, "Content-Type") == "application/json")
        #expect(header(r, "Set-Cookie") == nil)
        #expect(header(r, "ETag") != nil)
        let again = try await api2.handle(path: "/v1/radar/history.json", ifNoneMatch: header(r, "ETag"))
        #expect(again.status == 304 && again.body.isEmpty)
        let other = try await api3.handle(path: "/v1/radar/history.json", ifNoneMatch: nil)
        #expect(other.body == r.body && header(other, "ETag") == header(r, "ETag"))  // replicas answer byte-identically

        let doc = try json(r.body)
        #expect(Array(doc.keys).sorted() == ["attribution", "generated_at", "history_hours", "image", "modification_notice",
                                              "run", "schema", "slots", "step_minutes"])
        #expect(doc["schema"] as? Int == 1 && doc["step_minutes"] as? Int == 5 && doc["history_hours"] as? Int == 6)
        #expect(doc["run"] as? String == "20261030T1105Z")
        let slots = try #require(doc["slots"] as? [[String: String]])
        #expect(slots.count == 5)
        #expect(slots.last == ["time": "2026-10-30T11:05:00Z", "kind": "analysis", "path": "20261030T1105Z/20261030T1105Z.webp"])
        // image block identical to latest.json
        let latestDoc = try json(try await api2.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil).body)
        #expect(NSDictionary(dictionary: doc["image"] as! [String: Any]).isEqual(to: latestDoc["image"] as! [String: Any]))
        #expect(doc["attribution"] as? String == latestDoc["attribution"] as? String)
        // a listed old slot is served immutably
        let slotPath = "/v1/radar/" + slots[0]["path"]!
        let slot = try await api2.handle(path: slotPath, ifNoneMatch: nil)
        #expect(slot.status == 200 && header(slot, "Cache-Control") == "public, max-age=31536000, immutable")
    }

    @Test(arguments: RepoKind.allCases)
    func latestJsonIsUnchangedByBackfilledSlots(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig()
        let dwd = FakeDwd(cfg)
        for i in [0, 2] {  // runs 11:05 and 11:15; the gap 11:10 stays
            let ing = Ingestor(config: cfg, repo: repo, fetch: dwd.fetch, owner: "a", sleep: { _ in })
            _ = try await ing.process(run: run0.addingTimeInterval(Double(i) * tick5))
        }
        let before = try await Manifest.build(repo: repo, config: cfg)
        try await seed(repo, run0.addingTimeInterval(tick5))  // backfilled analysis in the gap
        try await seed(repo, run0.addingTimeInterval(-tick5))
        #expect(try await Manifest.build(repo: repo, config: cfg) == before)
        let history = try json(try #require(try await Manifest.buildHistory(repo: repo, config: cfg)))
        #expect((history["slots"] as? [Any])?.count == 4)
    }

    @Test func latestJsonMatchesTheFormerManifestByteForByte() async throws {
        let fixed = Date(timeIntervalSince1970: 1_793_000_000)
        let repo = MemoryRepo(clock: { fixed })
        let cfg = smallConfig()
        let dwd = FakeDwd(cfg)
        for i in 0..<3 {
            let ing = Ingestor(config: cfg, repo: repo, fetch: dwd.fetch, owner: "a", sleep: { _ in })
            _ = try await ing.process(run: run0.addingTimeInterval(Double(i) * tick5))
        }
        let body = try #require(try await Manifest.build(repo: repo, config: cfg))
        let golden = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/latest-before-history.json"), encoding: .utf8)
        #expect(String(decoding: body, as: UTF8.self) == golden)
    }
}

}

extension DatabaseSuites {
@Suite("History backfill", .serialized)
struct BackfillTests {
    @Test(arguments: RepoKind.allCases)
    func fillsGapsIdempotentlyAndResumes(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 1 }  // grid 11:05 ... 11:50 (12:00 and 11:55 are the regular ingest's)
        let end = latest0.addingTimeInterval(-2 * tick5)
        let existing = [end, end.addingTimeInterval(-3 * tick5), end.addingTimeInterval(-4 * tick5)]
        for t in existing { try await seed(repo, t) }
        let dwd = RecordingDwd(cfg, failEvery: 4)  // the known one-in-three XML answers
        let first = try await backfiller(repo, cfg, fetch: dwd.fetch).tick()
        #expect(first.isLeader)
        // 12 grid points in the window minus 2 guarded = 10 candidates, 3 were there already
        #expect(first.stored == 7 && first.remaining == 0)
        #expect(dwd.calls >= 7 && dwd.calls <= Backfiller.maxRequestsPerTick)
        let requested = Set(dwd.times)
        for t in existing { #expect(!requested.contains(TimeUtil.toWMS(t)), "existing slot fetched again") }
        let calls = dwd.calls
        let second = try await backfiller(repo, cfg, fetch: dwd.fetch).tick()
        #expect(second.stored == 0 && second.remaining == 0 && dwd.calls == calls)  // idempotent
        // the stored analysis is the normal slot: path run/slot and WebP
        let id = TimeUtil.toID(end.addingTimeInterval(-tick5))
        let blob = try #require(try await repo.getSlot(runID: id, slotID: id))
        #expect(Array(blob.data.prefix(4)) == Array("RIFF".utf8))
    }

    @Test(arguments: RepoKind.allCases)
    func onlyTheLeaderBackfills(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 1 }
        let a = RecordingDwd(cfg), b = RecordingDwd(cfg)
        let first = try await backfiller(repo, cfg, owner: "a", fetch: a.fetch).tick()
        let rival = try await backfiller(repo, cfg, owner: "b", fetch: b.fetch).tick()
        #expect(first.isLeader && first.stored > 0)
        #expect(!rival.isLeader && b.calls == 0)
        let newBackfiller = backfiller(repo, cfg, owner: "a", fetch: a.fetch)
        await newBackfiller.release()
        #expect(try await backfiller(repo, cfg, owner: "b", fetch: b.fetch).tick().isLeader)  // lease handed over
    }

    @Test(arguments: RepoKind.allCases)
    func requestBudgetPerTickIsHard(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 72 }
        let dwd = RecordingDwd(cfg, failEvery: 4)
        let result = try await backfiller(repo, cfg, fetch: dwd.fetch).tick()
        #expect(dwd.calls <= Backfiller.maxRequestsPerTick)
        #expect(result.stored > 0 && result.stored <= Backfiller.maxRequestsPerTick)
        #expect(result.remaining > 800)
        // newest first
        #expect(dwd.times.prefix(2).contains(TimeUtil.toWMS(latest0.addingTimeInterval(-2 * tick5))))
    }

    @Test(arguments: RepoKind.allCases)
    func consecutiveFailuresPauseAndPublishNothing(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 2 }
        let dead = FakeDwd(cfg, failAll: true)
        let result = try await backfiller(repo, cfg, fetch: dead.fetch).tick()
        #expect(result.errorPause && result.stored == 0)
        #expect(dead.callCount <= Backfiller.maxRequestsPerTick)
        #expect(try await repo.latestPublished() == nil)
    }

    @Test(arguments: RepoKind.allCases)
    func neverFetchesWhileTheRegularIngestIsBusy(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 1 }
        let activity = ActivityFlag()
        activity.set(true)
        let waits = Locked(0)
        let dwd = RecordingDwd(cfg)
        let seen = Locked(false)
        let fetch: Fetch = { url in
            if activity.isBusy { seen.withLock { $0 = true } }
            return try await dwd.fetch(url)
        }
        let sleep: @Sendable (Double) async -> Void = { _ in
            if waits.withLock({ $0 += 1; return $0 }) >= 3 { activity.set(false) }  // the regular run finishes after a few waits
        }
        let result = try await backfiller(repo, cfg, fetch: fetch, isBusy: { activity.isBusy }, sleep: sleep).tick()
        #expect(result.stored > 0)
        #expect(!seen.withLock { $0 })
        #expect(waits.withLock { $0 } >= 3)
    }

    @Test(arguments: RepoKind.allCases)
    func cancellationStopsPromptlyAndReleasesTheClaim(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 2 }
        let dwd = RecordingDwd(cfg)
        let b = backfiller(repo, cfg, fetch: dwd.fetch, sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) })
        let started = Date()
        let task = Task { try await b.tick() }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = try await task.value
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(dwd.calls < 5)
    }

    @Test(arguments: RepoKind.allCases)
    func windowEdgeAndGuardAreRespected(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig { $0.historyHours = 1 }
        let times = try await backfiller(repo, cfg, fetch: RecordingDwd(cfg).fetch).missing(now: now0)
        #expect(times.count == 10)
        #expect(times.first == latest0.addingTimeInterval(-2 * tick5))
        #expect(times.last == latest0.addingTimeInterval(-11 * tick5))  // history_hours window: (12:00 - 1 h, 12:00]
    }
}
}
