import Foundation
import Testing
@testable import RadarCore

private let testGrid = RainRateGrid(width: 180, height: 66, step: 2.0)
private let testWidth = 36

/// Rain of 5.0 mm/h (raw 50) at 10 E / 50 N (row 10, column 95) plus a degraded block in the far north; the rest of the world is dry (raw 0),
/// the left columns (180 W to 140 W) are no data.
private func rainFixture() -> NetcdfFixture {
    var f = NetcdfFixture()
    f.rate = { r, c in
        if c < 20 { return -9990 }
        if r == 10 && c == 95 { return 50 }
        return 0
    }
    f.dqf = { r, _ in r < 5 ? 2 : 0 }
    return f
}

@Suite("NOAA RRQPE NetCDF reader")
struct NoaaReaderTests {
    @Test func readsTheProductLayoutAndReprojects() throws {
        let table = WorldLookup(bbox: NoaaRain.worldBBox, width: testWidth, grid: testGrid)
        let r = try RainRateNetCDF.reduce(rainFixture().make(), table: table)
        #expect(r.width == testWidth && r.height == table.height && r.rate.count == r.width * r.height)
        #expect(r.rate.max() == 50)
        // 10 E = column 95 of 180, 50 N = row 10: the target pixel holds the maximum of its window
        let x = table.colMap[95], y = table.rowMap[10]
        #expect(r.rate[y * r.width + x] == 50)
        #expect(r.rate.filter { $0 == 50 }.count >= 1)
        // left columns (no data) stay -1, dry cells are 0
        #expect(r.rate[(table.height / 2) * r.width] == -1 && r.rate[(table.height / 2) * r.width + r.width - 1] == 0)
        #expect(r.validCells == (180 - 20) * 66)
    }

    @Test func marksDegradedPixelsOnlyWhereMostCellsAreDegraded() throws {
        let table = WorldLookup(bbox: NoaaRain.worldBBox, width: testWidth, grid: testGrid)
        let r = try RainRateNetCDF.reduce(rainFixture().make(), table: table)
        #expect(r.degraded[0] && r.degraded[r.width - 1])                  // top row (row 0 to 4 of the source are degraded)
        #expect(!r.degraded[(r.height - 1) * r.width])                      // south
        #expect(r.degraded.filter { $0 }.count < r.degraded.count / 2)
    }

    @Test func imageUsesTheDwdClassesAndReducedOpacityForDegraded() throws {
        var f = NetcdfFixture()
        f.rate = { r, c in (r == 30 && c == 60) ? 15 : (r == 2 && c == 100 ? 15 : 0) }   // 1.5 mm/h in the middle and in the degraded north
        f.dqf = { r, _ in r < 5 ? 2 : 0 }
        let img = try NoaaRainRender.image(file: f.make(), bbox: NoaaRain.worldBBox, width: testWidth, grid: testGrid)
        let coloured = (0..<(img.width * img.height)).filter { img.pixels[$0 * 4 + 3] != 0 }
        #expect(coloured.count == 2)
        let alphas = Set(coloured.map { img.pixels[$0 * 4 + 3] })
        #expect(alphas == [NoaaRainPalette.alpha, NoaaRainPalette.degradedAlpha])
        for i in coloured { #expect(Array(img.pixels[i * 4..<i * 4 + 3]) == [0x4D, 0xB3, 0x1B]) }  // class 1 to 2 mm/h
    }

    @Test func rejectsOtherLayouts() throws {
        let table = WorldLookup(bbox: NoaaRain.worldBBox, width: testWidth, grid: testGrid)
        func expectRejected(_ bytes: [UInt8]) { #expect(throws: Hdf5Error.self) { try RainRateNetCDF.reduce(bytes, table: table) } }
        var scale = rainFixture(); scale.scaleFactor = 0.01
        expectRejected(scale.make())
        var offset = rainFixture(); offset.addOffset = 5
        expectRejected(offset.make())
        var fill = rainFixture(); fill.fill = -1
        expectRejected(fill.make())
        var coarse = rainFixture(); coarse.grid = RainRateGrid(width: 90, height: 33, step: 4); coarse.chunkCols = 45; coarse.chunkRows = 11
        expectRejected(coarse.make())
        expectRejected(Array("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>".utf8))
        expectRejected(Array("not hdf5".utf8) + [UInt8](repeating: 0, count: 200))
        let good = rainFixture().make()
        expectRejected(Array(good.prefix(good.count / 2)))
        var broken = good
        for i in stride(from: 700, to: broken.count - 8, by: 83) { broken[i] ^= 0xA5 }
        #expect(throws: Error.self) { _ = try RainRateNetCDF.reduce(broken, table: table) }
    }

    @Test func fileWithoutEnoughValidCellsIsRejected() throws {
        var f = NetcdfFixture()
        f.rate = { _, c in c < 150 ? -9990 : 0 }   // 17 % valid
        #expect(throws: ImageError.self) { try NoaaRainRender.image(file: f.make(), bbox: NoaaRain.worldBBox, width: testWidth, grid: testGrid) }
    }

    /// Real file of 17 Nov 2026 (5.3 MB, not in the repository): runs only where `RRQPE_SAMPLE_NC` points to one. Prints the timings for docs/status.md.
    @Test func realFileWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RRQPE_SAMPLE_NC"], let data = FileManager.default.contents(atPath: path) else { return }
        let bytes = [UInt8](data)
        func now() -> Double { Date().timeIntervalSinceReferenceDate }
        var t = now(); let img = try NoaaRainRender.image(file: bytes, bbox: NoaaRain.worldBBox, width: 2048); let first = now() - t
        t = now(); _ = try NoaaRainRender.image(file: bytes, bbox: NoaaRain.worldBBox, width: 2048); let cached = now() - t
        t = now(); let webp = try ImagePipeline.toWebP(img, method: NoaaRain.webpMethod); let enc = now() - t
        let rain = (0..<(img.width * img.height)).filter { img.pixels[$0 * 4 + 3] != 0 }.count
        let degraded = (0..<(img.width * img.height)).filter { img.pixels[$0 * 4 + 3] == NoaaRainPalette.degradedAlpha }.count
        print("RRQPE_TIMING imageFirst=\(first) imageCached=\(cached) webp=\(enc) webpBytes=\(webp.count) size=\(img.width)x\(img.height) rainPixels=\(rain) degradedRain=\(degraded)")
        #expect(img.width == 2048 && img.height == 995 && rain > 0)
        let r = try RainRateNetCDF.reduce(bytes, table: WorldLookupCache.shared.lookup(bbox: NoaaRain.worldBBox, width: 2048, grid: .product))
        print("RRQPE_STATS valid=\(r.validCells) degradedPixels=\(r.degraded.filter { $0 }.count)")
    }
}

@Suite("NOAA RRQPE grid, palette and sources")
struct NoaaGridTests {
    @Test func worldBBoxAndImageSize() {
        let b = NoaaRain.worldBBox
        #expect(abs(b[0] + 20_037_508.34) < 1 && abs(b[2] - 20_037_508.34) < 1)
        #expect(abs(b[1] + 8_399_737.89) < 5 && abs(b[3] - 11_068_715.66) < 5)   // 60 S and 70 N
        #expect(RadarConstants.imageHeight(width: 2048, bbox: b) == 995)
        #expect(RadarConstants.imageHeight(width: 2048, bbox: b) <= LayerSpec.maxPixelsPerSide)
    }

    @Test func productLookupCoversEveryTargetPixel() {
        let t = WorldLookup(bbox: NoaaRain.worldBBox, width: 2048)
        #expect(t.height == 995 && t.minimumCells.cols >= 8 && t.minimumCells.rows >= 3)
        #expect(t.colMap.count == 18000 && t.rowMap.count == 6501)
        #expect(t.colMap.first == 0 && t.colMap.last == 2047 && t.rowMap.first == 0 && t.rowMap.last == 994)
        #expect(zip(t.colMap, t.colMap.dropFirst()).allSatisfy { $0 <= $1 } && zip(t.rowMap, t.rowMap.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(t.colCount.reduce(0, +) == 18000 && t.rowCount.reduce(0, +) == 6501)
        // Germany: 10 E, 51 N lies in the target pixel column/row of the Mercator formula
        let x = Int((10.0 + 180) / 360 * 2048), y = Int((NoaaRain.worldBBox[3] - 6378137 * log(tan(.pi / 4 + 51.0 * .pi / 360))) / (NoaaRain.worldBBox[3] - NoaaRain.worldBBox[1]) * 995)
        #expect(t.colMap[Int((10.0 + 180) / 0.02)] == x && abs(t.rowMap[Int((70.0 - 51) / 0.02)] - y) <= 1)
    }

    @Test func lookupIsCached() {
        let a = WorldLookupCache.shared.lookup(bbox: NoaaRain.worldBBox, width: 32, grid: testGrid)
        let b = WorldLookupCache.shared.lookup(bbox: NoaaRain.worldBBox, width: 32, grid: testGrid)
        #expect(a.height == b.height && a.colMap == b.colMap)
    }

    @Test func paletteThresholdAndClasses() {
        #expect(NoaaRainPalette.classIndex(-1) == nil && NoaaRainPalette.classIndex(0) == nil)   // no data, dry
        #expect(NoaaRainPalette.classIndex(1) == 0 && NoaaRainPalette.classIndex(1) != nil)      // 0.1 mm/h
        #expect(NoaaRainPalette.classIndex(3) == 1 && NoaaRainPalette.classIndex(4) == 2)         // 0.4 mm/h
        #expect(NoaaRainPalette.classIndex(10) == 3 && NoaaRainPalette.classIndex(99) == 7 && NoaaRainPalette.classIndex(100) == 8)
        #expect(NoaaRainPalette.classIndex(1499) == 13 && NoaaRainPalette.classIndex(Int16.max) == 14)
        #expect(NoaaRainPalette.classes.count == 15)
        let edges = NoaaRainPalette.classes.map(\.from)
        #expect(edges == edges.sorted())
        #expect(NoaaRainPalette.degradedAlpha < NoaaRainPalette.alpha)
    }

    @Test func listingPicksTheHighestStageOfTheSlot() {
        let slot = TimeUtil.fromID("20261117T1500Z")!
        let p = "BLEND/RainRate-Blend-INST/2026/11/17/15/RRQPE-INST-GLB-"
        let xml = "<ListBucketResult>" + [
            "\(p)2_v1r1_blend_s202611171500000_e202611171509599_c202611171512000.nc",
            "\(p)5_v1r1_blend_s202611171500000_e202611171509599_c202611171522238.nc",
            "\(p)3_v1r1_blend_s202611171500000_e202611171509599_c202611171514000.nc",
            "\(p)5_v1r1_blend_s202611171510000_e202611171519599_c202611171524499.nc",   // other slot
            "\(p)5_v1r1_blend_s202611171500000_e202611171509599_c202611171522238.txt",   // other type
            "BLEND/RainRate-Blend-INST/2026/11/17/15/other-s202611171500000.nc",
        ].map { "<Contents><Key>\($0)</Key></Contents>" }.joined() + "</ListBucketResult>"
        let c = NoaaRain.candidates(listing: Array(xml.utf8), slot: slot)
        #expect(c.map(\.stage) == [5, 3, 2] && c.first?.key.hasSuffix("c202611171522238.nc") == true)
        #expect(NoaaRain.candidates(listing: Array("<Error/>".utf8), slot: slot).isEmpty)
        #expect(NoaaRain.listURL(base: "https://b.test/", slot: slot) == "https://b.test/?list-type=2&prefix=BLEND/RainRate-Blend-INST/2026/11/17/15/")
        #expect(NoaaRain.fileURL(base: "https://b.test/", key: "k/a.nc") == "https://b.test/k/a.nc")
    }
}

@Suite("NOAA RRQPE layer ingest")
struct NoaaIngestTests {
    private static let now = TimeUtil.fromID("20261117T1527Z")!

    @Test func layerIsRegisteredButNotActiveByDefault() throws {
        let spec = try #require(LayerCatalog.specs["radar_world"])
        #expect(LayerCatalog.order.contains("radar_world") && LayerCatalog.operatorTokens.contains("radar_world"))
        #expect(try Config.fromEnvironment([:]).layers.isEmpty)
        #expect(try Config.fromEnvironment(["LAYERS": "radar_world"]).layers == ["radar_world"])
        #expect(try Config.fromEnvironment([:]).historyHours(for: spec) == 48)
        #expect(try Config.fromEnvironment(["HISTORY_HOURS": "72"]).historyHours(for: spec) == 72)
        #expect(spec.attribution(year: 2026) == "Quelle: NOAA, von Showers verarbeitet; aus Satellitendaten geschätzt, ungenauer")
        #expect(spec.kind == .observation && spec.stepMinutes == 10 && spec.fixedWidth == 2048 && spec.source == "noaa_rrqpe")
        #expect("radar_world".count <= 16)  // column layer VARCHAR(16)
        #expect(spec.width(smallConfig()) == 2048 && spec.height(smallConfig()) == 995)
    }

    private func config(hours: Int = 1) -> Config {
        smallConfig { c in
            c.layers = ["radar_world"]; c.layerPauseSeconds = 0; c.historyHours = hours
            c.noaaRainURL = "https://noaa.test/bucket"
        }
    }

    private func ingestor(_ repo: any Repo, now: Date = NoaaIngestTests.now, hours: Int = 1, _ fetch: @escaping Fetch) -> LayerIngestor {
        LayerIngestor(spec: LayerCatalog.specs["radar_world"]!.resized(width: testWidth), config: config(hours: hours), repo: repo, fetch: fetch, owner: "a",
                      sleep: { _ in }, clock: { now }, noaaGrid: testGrid)
    }

    /// Listing of the hour: the slot and every earlier one of the hour with the given stage.
    private func listing(hour: String, stage: Int) -> [UInt8] {
        let day = String(hour.prefix(8)), h = String(hour.suffix(2))
        let keys = (0..<6).map { i in
            "BLEND/RainRate-Blend-INST/\(day.prefix(4))/\(day.dropFirst(4).prefix(2))/\(day.suffix(2))/\(h)/RRQPE-INST-GLB-\(stage)_v1r1_blend_s\(hour)\(i)0000_e0_c0.nc"
        }
        return Array(("<ListBucketResult>" + keys.map { "<Contents><Key>\($0)</Key></Contents>" }.joined() + "</ListBucketResult>").utf8)
    }

    private final class Requests: @unchecked Sendable {
        let lock = NSLock(); var urls: [String] = []
        func add(_ u: String) { lock.withLock { urls.append(u) } }
    }

    /// Listing answer for a request URL of the ingest (hour taken from the prefix).
    private func listing(for url: String, stage: Int) -> [UInt8] {
        let parts = (url.components(separatedBy: "prefix=").last ?? "").split(separator: "/")   // BLEND RainRate-Blend-INST 2026 11 17 15
        return listing(hour: String(parts[2]) + parts[3] + parts[4] + parts[5], stage: stage)
    }

    @Test(arguments: RepoKind.allCases)
    func publishesSlotsFromListingAndManifestCarriesAttribution(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let file = rainFixture().make()
        let seen = Requests()
        let r = try await ingestor(repo) { url in
            seen.add(url)
            return url.contains("?list-type=2") ? self.listing(for: url, stage: 5) : file
        }.tick()
        #expect(r.stored == 7 && r.failed == 0)   // 1 h of history = 7 slots, newest 15:10 (clock 15:27 minus 15 min delay)
        #expect(seen.urls.first == "https://noaa.test/bucket/?list-type=2&prefix=BLEND/RainRate-Blend-INST/2026/11/17/15/")
        #expect(seen.urls.contains { $0.hasPrefix("https://noaa.test/bucket/BLEND/RainRate-Blend-INST/2026/11/17/15/RRQPE-INST-GLB-5_") })
        #expect(try await repo.layerIsPublished(layer: "radar_world", runID: "20261117T1510Z"))
        let spec = LayerCatalog.specs["radar_world"]!.resized(width: testWidth)
        let body = try #require(try await LayerManifest.build(repo: repo, config: config(), spec: spec))
        let m = try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        #expect(m["layer"] as? String == "radar_world" && m["step_minutes"] as? Int == 10 && m["kind"] as? String == "observation")
        #expect(m["attribution"] as? String == "Quelle: NOAA, von Showers verarbeitet; aus Satellitendaten geschätzt, ungenauer")
        #expect((m["modification_notice"] as? String)?.contains("NOAA") == true && m["source"] as? String == "noaa_rrqpe")
        #expect((m["image"] as? [String: Any])?["bbox"] as? [Double] == NoaaRain.worldBBox && m["history_hours"] as? Int == 1)
        #expect(m["legend"] == nil)
    }

    /// HISTORY_HOURS (48 or 72) is the history of this layer too (before 19 Nov 2026: RADAR_WORLD_HISTORY_HOURS, 1 to 24, default 24).
    @Test(arguments: RepoKind.allCases, [48, 72])
    func backfillsTheWholeDurationAndReportsIt(kind: RepoKind, hours: Int) async throws {
        let repo = try await kind.make()
        let file = rainFixture().make()
        let seen = Requests()
        let ing = ingestor(repo, hours: hours) { url in
            seen.add(url)
            return url.contains("?list-type=2") ? self.listing(for: url, stage: 5) : file
        }
        var stored = 0
        for _ in 0..<300 {
            let r = try await ing.tick()
            stored += r.stored
            if r.stored == 0 && r.failed == 0 { break }
        }
        let expected = hours * 6 + 1  // 10 min steps, both ends
        #expect(stored == expected)
        let spec = LayerCatalog.specs["radar_world"]!.resized(width: testWidth)
        let body = try #require(try await LayerManifest.build(repo: repo, config: config(hours: hours), spec: spec))
        let m = try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == expected && m["history_hours"] as? Int == hours)
        let history = try #require(m["history"] as? [String: Any])
        #expect(history["hours"] as? Int == hours && history["expected"] as? Int == expected && history["present"] as? Int == expected)
        #expect(history["complete"] as? Bool == true && (history["gaps"] as? [Any])?.isEmpty == true && history["oldest"] as? String == slots.first?["time"])
        #expect(slots.first?["time"] == TimeUtil.toISO(TimeUtil.fromID("20261117T1510Z")!.addingTimeInterval(-Double(hours) * 3600)))
        let oldest = try #require(slots.first?["path"]).dropLast(5).split(separator: "/").map(String.init)
        #expect(try await repo.layerGetSlot(layer: "radar_world", runID: oldest[0], slotID: oldest[1]) != nil)
    }

    @Test(arguments: RepoKind.allCases)
    func youngSlotWaitsForTheFullVersionOlderOnesTakeWhatThereIs(kind: RepoKind) async throws {
        let file = rainFixture().make()
        // only stage 3 exists. Clock 15:27: 15:10 (17 min old) and 15:00 (27 min) wait for stage 5, 14:50 (37 min) takes stage 3.
        let repo = try await kind.make()
        let r = try await ingestor(repo) { url in url.contains("?list-type=2") ? self.listing(for: url, stage: 3) : file }.tick()
        #expect(try await repo.layerIsPublished(layer: "radar_world", runID: "20261117T1510Z") == false)
        #expect(try await repo.layerIsPublished(layer: "radar_world", runID: "20261117T1500Z") == false)
        #expect(try await repo.layerIsPublished(layer: "radar_world", runID: "20261117T1450Z"))
        #expect(r.failed >= 2)
        // clock 15:42: 15:20 (22 min) waits, 15:10 (32 min) takes stage 3
        let repo2 = try await kind.make()
        let later = TimeUtil.fromID("20261117T1542Z")!
        _ = try await ingestor(repo2, now: later) { url in url.contains("?list-type=2") ? self.listing(for: url, stage: 3) : file }.tick()
        #expect(try await repo2.layerIsPublished(layer: "radar_world", runID: "20261117T1520Z") == false)
        #expect(try await repo2.layerIsPublished(layer: "radar_world", runID: "20261117T1510Z"))
    }

    @Test(arguments: RepoKind.allCases)
    func nothingIsPublishedForAnEmptyListingOrAnErrorPage(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let xml = Array("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>".utf8)
        let r = try await ingestor(repo) { _ in xml }.tick()
        #expect(r.stored == 0 && r.failed >= 1)
        let garbage = try await ingestor(try await kind.make()) { url in url.contains("?list-type=2") ? self.listing(hour: "2026111714", stage: 5) : xml }.tick()
        #expect(garbage.stored == 0)
    }
}
