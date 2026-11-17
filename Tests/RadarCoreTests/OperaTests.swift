import Foundation
import Testing
@testable import RadarCore

/// Composite fixture: all undetect, a 30 dBZ block in the middle, nodata in the left columns.
private func compositeFixture(shuffle: Bool = false) -> OdimFixture {
    var f = OdimFixture(width: 38, height: 44) { r, c in
        if c < 4 { return -9_999_000 }
        if (15...22).contains(c) && (18...25).contains(r) { return 30 }
        return -8_888_000
    }
    f.shuffle = shuffle
    return f
}

@Suite("OPERA HDF5 reader")
struct OdimReaderTests {
    @Test(arguments: [false, true])
    func readsChunkedDeflateFloat64(shuffle: Bool) throws {
        let c = try OdimHDF5.read(compositeFixture(shuffle: shuffle).make())
        #expect(c.width == 38 && c.height == 44 && c.values.count == 38 * 44)
        #expect(c.quantity == "DBZH" && c.xscale == 100_000 && c.yscale == 100_000)
        #expect(c.projdef.hasPrefix("+proj=laea") && c.date == "20261117" && c.time == "162001")
        #expect(c.values[0].isNaN)                       // nodata, chunk 0 (columns 0..19)
        #expect(c.values[5] == -.infinity)               // undetect
        #expect(c.values[20 * 38 + 16] == 30)            // measured value across the chunk border (column 20 is in chunk 1)
        #expect(c.values[20 * 38 + 37] == -.infinity)    // last column, partial chunk
        #expect(c.values.last == -.infinity)             // last row: partial chunk rows
    }

    @Test func appliesGainAndOffset() throws {
        var f = compositeFixture()
        f.gain = 0.5; f.offset = -32
        let c = try OdimHDF5.read(f.make())
        #expect(c.values[20 * 38 + 16] == -17)
    }

    @Test func rejectsFilesThatAreNotTheProduct() throws {
        #expect(throws: Hdf5Error.self) { try OdimHDF5.read(Array("not hdf5".utf8) + [UInt8](repeating: 0, count: 200)) }
        #expect(throws: Hdf5Error.self) { try OdimHDF5.read(Array("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>".utf8)) }
        let good = compositeFixture().make()
        #expect(throws: Hdf5Error.self) { try OdimHDF5.read(Array(good.prefix(good.count / 2))) }      // truncated
        var broken = good
        for i in stride(from: 600, to: broken.count - 8, by: 97) { broken[i] ^= 0xA5 }               // damaged
        #expect(throws: Error.self) { _ = try OdimHDF5.read(broken) }
    }

    @Test func rejectsOtherQuantityAndProjection() throws {
        var f = compositeFixture(); f.quantity = "TH"
        #expect(throws: ImageError.self) { try OperaRender.image(file: f.make(), bbox: RadarConstants.europeBBox, width: 64, noiseDBZ: 0.126) }
        var g = compositeFixture(); g.projdef = "+proj=stere +lat_0=90"
        #expect(throws: ImageError.self) { try OperaRender.image(file: g.make(), bbox: RadarConstants.europeBBox, width: 64, noiseDBZ: 0.126) }
        let empty = OdimFixture(width: 38, height: 44)  // all nodata
        #expect(throws: ImageError.self) { try OperaRender.image(file: empty.make(), bbox: RadarConstants.europeBBox, width: 64, noiseDBZ: 0.126) }
    }

    /// The 17 Nov 2026 composite (4.07 MB) is not in the repository; the check runs only where the file is given.
    @Test func realCompositeWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["OPERA_SAMPLE_H5"], let data = FileManager.default.contents(atPath: path) else { return }
        let c = try OdimHDF5.read([UInt8](data))
        #expect(c.width == 3800 && c.height == 4400 && c.quantity == "DBZH")
    }
}

@Suite("OPERA projection and filter")
struct OperaProjectionTests {
    static let laea = try! LAEA.parse("+proj=laea +lat_0=55.0 +lon_0=10.0 +x_0=1950000.0 +y_0=-2100000.0 +units=m +ellps=WGS84")

    @Test func projectionOriginAndCorners() {
        let o = Self.laea.forward(lat: 55, lon: 10)
        #expect(abs(o.x - 1_950_000) < 0.01 && abs(o.y + 2_100_000) < 0.01)
        // corners from the file (where/UL_lon ... rounded to 0.01 degrees = about 1 km): UL = pixel (0, 0), LL = pixel (0, 4400)
        let ul = Self.laea.forward(lat: 67.02, lon: -39.54)
        #expect(abs(ul.x) < 2500 && abs(ul.y) < 2500)
        let ll = Self.laea.forward(lat: 31.75, lon: -10.43)
        #expect(abs(ll.x) < 2500 && abs(ll.y + 4_400_000) < 2500)
    }

    @Test func parsesOnlyTheExpectedProjection() {
        #expect(throws: ImageError.self) { try LAEA.parse("+proj=merc +ellps=WGS84") }
        #expect(throws: ImageError.self) { try LAEA.parse("+proj=laea +lat_0=55 +lon_0=10 +ellps=GRS80") }
    }

    @Test func lookupMapsGermanyToTheRightCell() throws {
        let lookup = OperaLookup(laea: Self.laea, sourceWidth: 3800, sourceHeight: 4400, xscale: 1000, yscale: 1000,
                                 bbox: RadarConstants.europeBBox, width: 128)
        // the pixel at 10 E / 55 N is the projection centre: column 1950, row 2100
        let bbox = RadarConstants.europeBBox
        let mx = 10.0 / 180 * .pi * 6378137.0
        let my = log(tan(.pi / 4 + 55.0 / 180 * .pi / 2)) * 6378137.0
        let px = Int((mx - bbox[0]) / (bbox[2] - bbox[0]) * 128), py = Int((bbox[3] - my) / (bbox[3] - bbox[1]) * Double(lookup.height))
        let cell = try #require(lookup.cell(x: px, y: py))
        #expect(abs(cell.col - 1950) <= 40 && abs(cell.row - 2100) <= 40)  // a target pixel at 128 px is about 60 km
        #expect(lookup.cell(x: 0, y: lookup.height - 1) == nil)             // Atlantic / Africa corner is outside the composite
        #expect(lookup.coverage > 0.7 && lookup.coverage < 0.95)           // measured on 17 Nov 2026: 82 %
    }

    @Test func maxFilterKeepsIsolatedEchoes() {
        // 1 km source around Germany (centre at 10 E / 55 N is cell 190 / 220), 2048 px target = 2.4 km per pixel at 50 N
        let laea = LAEA(lat0: 55, lon0: 10, falseEasting: 190_000, falseNorthing: -220_000)
        let lookup = OperaLookup(laea: laea, sourceWidth: 380, sourceHeight: 440, xscale: 1000, yscale: 1000,
                                 bbox: RadarConstants.europeBBox, width: 2048)
        var source = [Float](repeating: -.infinity, count: 380 * 440)
        var hot = 0
        for r in stride(from: 20, to: 420, by: 5) { for c in stride(from: 20, to: 360, by: 5) { source[r * 380 + c] = 40; hot += 1 } }
        let out = lookup.resample(source)
        let survived = out.reduce(0) { $0 + ($1 == 40 ? 1 : 0) }
        #expect(survived >= hot * 9 / 10)   // nearest neighbour would keep about one in six
        #expect(out.filter { $0.isNaN }.count > out.count / 2)  // outside the small source: no data
    }

    @Test func lookupTableIsCached() {
        let a = OperaLookupCache.shared.lookup(laea: Self.laea, projdef: "p", sourceWidth: 38, sourceHeight: 44, xscale: 100_000, yscale: 100_000, bbox: RadarConstants.europeBBox, width: 32)
        let b = OperaLookupCache.shared.lookup(laea: Self.laea, projdef: "p", sourceWidth: 38, sourceHeight: 44, xscale: 100_000, yscale: 100_000, bbox: RadarConstants.europeBBox, width: 32)
        #expect(a.coverage == b.coverage && a.width == 32)
    }
}

@Suite("OPERA noise threshold and palette")
struct OperaPaletteTests {
    @Test func thresholdAndClasses() {
        let t: Float = 0.126
        #expect(OperaPalette.classIndex(.nan, threshold: t) == nil)
        #expect(OperaPalette.classIndex(-.infinity, threshold: t) == nil)
        #expect(OperaPalette.classIndex(-32, threshold: t) == nil)
        #expect(OperaPalette.classIndex(0.12, threshold: t) == nil)
        #expect(OperaPalette.classIndex(0.126, threshold: t) == 0)
        #expect(OperaPalette.classIndex(9.99, threshold: t) == 0)
        #expect(OperaPalette.classIndex(10, threshold: t) == 1)
        #expect(OperaPalette.classIndex(20, threshold: t) == 3)
        #expect(OperaPalette.classIndex(59.9, threshold: t) == 10)
        #expect(OperaPalette.classIndex(73.5, threshold: t) == OperaPalette.classes.count - 1)
        #expect(OperaPalette.classIndex(3, threshold: 5) == nil)  // the threshold is configurable
    }

    @Test func imageIsTransparentWithoutEchoAndColouredWithEcho() {
        let img = OperaPalette.image([.nan, -.infinity, 0.1, 25, 45], width: 5, height: 1, threshold: 0.126)
        #expect(Array(img.pixels[0..<12]).allSatisfy { $0 == 0 })
        #expect(Array(img.pixels[12..<16]) == [122, 209, 58, 250])
        #expect(Array(img.pixels[16..<20]) == [224, 43, 43, 255])
    }

    @Test func classesAreAscending() {
        let edges = OperaPalette.classes.map(\.from)
        #expect(edges == edges.sorted())
    }
}

@Suite("OPERA sources and ingest")
struct OperaIngestTests {
    private static let now = TimeUtil.fromID("20261031T1037Z")!

    @Test func pathAndUrls() {
        let slot = TimeUtil.fromID("20261117T1630Z")!
        #expect(Opera.path(slot: slot) == "2026/11/17/OPERA/COMP/OPERA@20261117T1630@0@DBZH.h5")
        #expect(Opera.urls(slot: slot, primary: "https://a.test/b/", backup: "https://c.test/d") == [
            "https://a.test/b/2026/11/17/OPERA/COMP/OPERA@20261117T1630@0@DBZH.h5",
            "https://c.test/d/2026/11/17/OPERA/COMP/OPERA@20261117T1630@0@DBZH.h5"])
        #expect(Opera.urls(slot: slot, primary: "https://a.test/b", backup: "").count == 1)
    }

    @Test func layerIsRegisteredButNotActiveByDefault() throws {
        #expect(LayerCatalog.specs["radar_eu"] != nil && LayerCatalog.order.contains("radar_eu"))
        #expect(LayerCatalog.operatorTokens.contains("radar_eu"))
        #expect(try Config.fromEnvironment([:]).layers.isEmpty)
        #expect(try Config.fromEnvironment(["LAYERS": "radar_eu"]).layers == ["radar_eu"])
        #expect(try Config.fromEnvironment(["LAYERS": "radar_eu"]).spec(for: "radar_eu")?.attribution(year: 2026) == "Radardaten Europa: EUMETNET OPERA (CIRRUS), CC BY 4.0, Quelle: MeteoGate; umprojiziert und eingefärbt.")
        #expect(try Config.fromEnvironment(["RADAR_EU_HISTORY_HOURS": "6"]).radarEUHistoryHours == 6)
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["RADAR_EU_HISTORY_HOURS": "7"]) }
        #expect("radar_eu".count <= 16)  // column layer VARCHAR(16)
    }

    private func config(_ edit: (inout Config) -> Void = { _ in }) -> Config {
        smallConfig { c in
            c.layers = ["radar_eu"]; c.layerPauseSeconds = 0; c.radarEUHistoryHours = 1
            c.operaURL = "https://main.test/bucket"; c.operaBackupURL = "https://backup.test/bucket"
            edit(&c)
        }
    }

    private func ingestor(_ cfg: Config, _ repo: any Repo, _ fetch: @escaping Fetch) -> LayerIngestor {
        LayerIngestor(spec: LayerCatalog.specs["radar_eu"]!.resized(width: 64), config: cfg, repo: repo, fetch: fetch, owner: "a",
                      sleep: { _ in }, clock: { Self.now })
    }

    private final class Requests: @unchecked Sendable {
        let lock = NSLock(); var urls: [String] = []
        func add(_ u: String) { lock.withLock { urls.append(u) } }
    }

    private struct NotFound: Error {}

    @Test(arguments: RepoKind.allCases)
    func fallsBackToTheBackupBucketWhenTheMainBucketIsEmpty(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let file = compositeFixture().make()
        let seen = Requests()
        let ing = ingestor(config(), repo) { url in
            seen.add(url)
            if url.hasPrefix("https://main.test/") { throw NotFound() }
            return file
        }
        let r = try await ing.tick()
        // main fails for 3 slots in a row (slot 1 twice because of its retry), then the backup takes over and is kept
        #expect(r.failed == 1 && r.stored == LayerIngestor.slotsPerTick - 1)
        let r2 = try await ing.tick()
        #expect(r2.stored >= 13 - LayerIngestor.slotsPerTick)
        let mainCount = seen.urls.filter { $0.hasPrefix("https://main.test/") }.count
        #expect(mainCount == 3)  // after the switch the main bucket is not asked again
        #expect(seen.urls.first == "https://main.test/bucket/2026/10/31/OPERA/COMP/OPERA@20261031T1030@0@DBZH.h5")
        #expect(seen.urls.contains { $0.hasPrefix("https://backup.test/bucket/2026/10/31/OPERA/COMP/") })
        #expect(try await repo.layerIsPublished(layer: "radar_eu", runID: "20261031T1025Z"))
        let body = try #require(try await LayerManifest.build(repo: repo, config: config(), spec: LayerCatalog.specs["radar_eu"]!.resized(width: 64)))
        let m = try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        #expect(m["layer"] as? String == "radar_eu" && m["step_minutes"] as? Int == 5 && m["kind"] as? String == "observation")
        #expect(m["attribution"] as? String == "Radardaten Europa: EUMETNET OPERA (CIRRUS), CC BY 4.0, Quelle: MeteoGate; umprojiziert und eingefärbt.")
        #expect((m["image"] as? [String: Any])?["bbox"] as? [Double] == RadarConstants.europeBBox)
        #expect(m["source"] as? String == "opera" && m["history_hours"] as? Int == 1)
    }

    @Test(arguments: RepoKind.allCases)
    func mainBucketIsPreferredAndNotTheBackup(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let file = compositeFixture().make()
        let seen = Requests()
        let r = try await ingestor(config(), repo) { url in seen.add(url); return file }.tick()
        #expect(r.stored == LayerIngestor.slotsPerTick && !seen.urls.contains { $0.hasPrefix("https://backup.test/") })
    }

    @Test(arguments: RepoKind.allCases)
    func nothingIsPublishedWhenBothBucketsAreEmpty(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let xml = Array("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>".utf8)
        let r = try await ingestor(config(), repo) { url in
            if url.hasPrefix("https://main.test/") { throw NotFound() }
            return xml
        }.tick()
        #expect(r.stored == 0 && r.failed >= 1)
        #expect(try await repo.layerIsPublished(layer: "radar_eu", runID: "20261031T1030Z") == false)
    }

    @Test func imageHasTransparentBackgroundAndColouredEcho() throws {
        let img = try OperaRender.image(file: compositeFixture().make(), bbox: RadarConstants.europeBBox, width: 64, noiseDBZ: 0.126)
        #expect(img.width == 64 && img.height == RadarConstants.imageHeight(width: 64, bbox: RadarConstants.europeBBox))
        var coloured = 0, opaque30 = 0
        for i in 0..<(img.width * img.height) where img.pixels[i * 4 + 3] != 0 {
            coloured += 1
            if Array(img.pixels[i * 4..<i * 4 + 4]) == [232, 224, 42, 255] { opaque30 += 1 }  // the 30 dBZ class
        }
        #expect(coloured == opaque30 && coloured > 0)  // undetect and nodata are transparent
    }
}
