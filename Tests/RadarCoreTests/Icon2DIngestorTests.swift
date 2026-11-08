import Foundation
import Testing
@testable import RadarCore

private let tinyGrid = GribGrid(ni: 5, nj: 4, dLat: 1, dLon: 1)
private let now = TimeUtil.fromID("20261108T0800Z")!   // newest run = 06 UTC (published after 07:15)
private let run06 = TimeUtil.fromID("20261108T0600Z")!, run00 = TimeUtil.fromID("20261108T0000Z")!

/// Fake DWD open-data server: listing HTML plus bz2 GRIB files of a 5 x 4 grid (all cells 280 K = 6.85 C, one hole), no network.
final class FakeICON: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [String] = []
    var incompleteRuns: Set<String> = []
    var break_: @Sendable (String) -> Bool = { _ in false }   // file URL -> serve a broken file
    var template: UInt16 = 0
    var wrongTimeAt: Int?
    var fail: @Sendable (String) -> Bool = { _ in false }
    var value: Float = 280
    var serveAs: String?   // content variable instead of the requested one
    var count: Int { lock.withLock { urls.count } }
    var fileCount: Int { lock.withLock { urls.filter { $0.hasSuffix(".bz2") }.count } }

    var fetch: Fetch {
        { [self] url in
            lock.withLock { urls.append(url) }
            if fail(url) { throw URLError(.cannotConnectToHost) }
            let parts = url.split(separator: "/").map(String.init)
            if url.hasSuffix("/") {   // listing of <HH>/<var>/
                let variable = parts.last!, hh = parts[parts.count - 2]
                let run = TimeUtil.fromID("20261108T\(hh)00Z")!
                if incompleteRuns.contains(hh) { return Array("<a href=\"\(Icon2D.fileName(run: run, hour: 0, variable: variable))\">x</a>".utf8) }
                var html = "<html><body><a href=\"icon-d2_germany_icosahedral_single-level_2026110806_000_2d_\(variable).grib2.bz2\">i</a>"
                for h in 0...48 { html += "<a href=\"\(Icon2D.fileName(run: run, hour: h, variable: variable))\">f</a>\n" }
                return Array(html.utf8)
            }
            if break_(url) { return Array("<html>error</html>".utf8) }
            let name = parts.last!   // icon-d2_germany_regular-lat-lon_single-level_2026110806_012_2d_t_2m.grib2.bz2
            let fields = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
            let stamp = fields[4], hour = Int(fields[5])!
            let variable = serveAs ?? fields[7...].joined(separator: "_").replacingOccurrences(of: ".grib2.bz2", with: "")
            var b = GribBuilder()
            b.ni = 5; b.nj = 4; b.lat1 = 50; b.lon1 = 10; b.dLat = 1; b.dLon = 1
            b.reference = (2026, 11, 8, Int(stamp.suffix(2))!, 0, 0)
            b.forecast = UInt32((wrongTimeAt == hour ? hour + 1 : hour) * 60)
            b.packingTemplate = template
            switch variable { case "td_2m": b.number = 6; case "relhum_2m": b.category = 1; b.number = 1; default: break }
            var values = [Float?](repeating: variable == "relhum_2m" ? 42 : value, count: 20)
            values[0] = nil
            return try Bzip2.compress(b.build(values))
        }
    }
}

private func config(_ source: TempSource = .icon_d2, _ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig { c in
        c.layers = TempLayers.internalIDs; c.layerPauseSeconds = 0; c.temp.source = source; edit(&c)
    }
}

private func ingestor(_ id: String, _ repo: any Repo, _ cfg: Config, _ src: FakeICON, owner: String = "a") -> LayerIngestor {
    LayerIngestor(spec: LayerCatalog.specs[id]!.resized(width: 64), config: cfg, repo: repo, fetch: src.fetch, owner: owner, sleep: { _ in }, clock: { now }, d2Grid: tinyGrid)
}

@Suite("ICON-D2 ingest")
struct Icon2DIngestorTests {
    @Test func urlsMatchTheRealDirectoryLayout() {
        #expect(Icon2D.url(run: run06, hour: 12, variable: "t_2m")
                == "https://opendata.dwd.de/weather/nwp/icon-d2/grib/06/t_2m/icon-d2_germany_regular-lat-lon_single-level_2026110806_012_2d_t_2m.grib2.bz2")
        #expect(Icon2D.url(run: run00, hour: 48, variable: "relhum_2m").hasSuffix("/00/relhum_2m/icon-d2_germany_regular-lat-lon_single-level_2026110800_048_2d_relhum_2m.grib2.bz2"))
        #expect(Icon2D.directoryURL(run: run06, variable: "td_2m") == "https://opendata.dwd.de/weather/nwp/icon-d2/grib/06/td_2m/")
    }

    @Test func listingMustOfferAll49RegularLatLonFiles() {
        var html = ""
        for h in 0...47 { html += "<a href=\"\(Icon2D.fileName(run: run06, hour: h, variable: "t_2m"))\">" }
        #expect(!Icon2D.listingIsComplete(Array(html.utf8), run: run06, variable: "t_2m"))
        html += "<a href=\"icon-d2_germany_icosahedral_single-level_2026110806_048_2d_t_2m.grib2.bz2\">"   // other grid does not count
        #expect(!Icon2D.listingIsComplete(Array(html.utf8), run: run06, variable: "t_2m"))
        html += "<a href=\"\(Icon2D.fileName(run: run06, hour: 48, variable: "t_2m"))\">"
        #expect(Icon2D.listingIsComplete(Array(html.utf8), run: run06, variable: "t_2m"))
        #expect(!Icon2D.listingIsComplete(Array(html.utf8), run: run00, variable: "t_2m"))   // yesterday's run in the same directory
    }

    @Test func specsAreInternalAndShortEnough() {
        let expect: [(String, String, String)] = [("temperature_d2", "temperature", "t2m-d2-v1"), ("dewpoint_d2", "dewpoint", "td-d2-v1"), ("humidity_d2", "humidity", "rh-d2-v1")]
        for (id, pub, scale) in expect {
            let spec = LayerCatalog.specs[id]!
            #expect(id.count <= 16 && spec.publicID == pub && spec.scaleID == scale && spec.source == "icon_d2" && spec.tempVariant == .d2)
            #expect(spec.kind == .forecast && spec.stepSeconds == 3600 && spec.legend == nil && TempScale.load(id: scale) != nil)
        }
    }

    @Test(arguments: RepoKind.allCases)
    func publishesACompleteRunWithScaleAndColours(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = config()
        let src = FakeICON()
        let r = try await ingestor("temperature_d2", repo, cfg, src).tick()
        #expect(r.isLeader && r.stored == 49 && r.published == "20261108T0600Z" && r.failed == 0)
        #expect(src.fileCount == 49 && src.count == 50)   // one listing, 49 files, nothing else
        let body = try #require(try await LayerManifest.build(repo: repo, config: cfg, spec: LayerCatalog.specs["temperature_d2"]!.resized(width: 64)))
        let m = try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        #expect(m["layer"] as? String == "temperature" && m["source"] as? String == "icon_d2" && m["scale"] as? String == "t2m-d2-v1")
        #expect(m["kind"] as? String == "forecast" && m["step_minutes"] as? Int == 60 && m["forecast_horizon_minutes"] as? Int == 48 * 60)
        #expect(m["legend"] == nil && (m["modification_notice"] as? String)?.contains("ICON-D2") == true)
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == 49 && slots.first?["kind"] == "analysis" && slots.last?["time"] == "2026-11-10T06:00:00Z")
        let ids = try #require(slots[12]["path"]).dropLast(5).split(separator: "/").map(String.init)
        let blob = try #require(try await repo.layerGetSlot(layer: "temperature_d2", runID: ids[0], slotID: ids[1]))
        let image = try ImagePipeline.decodeWebP(blob.data)
        #expect(image.width == 64 && image.height == RadarConstants.imageHeight(width: 64))
        let opaque = stride(from: 3, to: image.pixels.count, by: 4).filter { image.pixels[$0] == 255 }
        #expect(!opaque.isEmpty && opaque.count < image.pixels.count / 4)   // Germany box mostly outside the tiny grid, so mostly transparent
        let scale = TempScale.load(id: "t2m-d2-v1")!, c = scale.rgb(band: scale.bandIndex(6.85))
        let first = opaque[0] - 3
        #expect(Array(image.pixels[first..<first + 3]) == [c.0, c.1, c.2])
        // done: a second tick fetches nothing
        let calls = src.count
        let again = try await ingestor("temperature_d2", repo, cfg, src).tick()
        #expect(again.stored == 0 && src.count == calls)
    }

    @Test(arguments: RepoKind.allCases)
    func incompleteNewestRunFallsBackToThePreviousOneWithoutDownloads(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let src = FakeICON(); src.incompleteRuns = ["06"]
        let r = try await ingestor("temperature_d2", repo, config(), src).tick()
        #expect(r.published == "20261108T0000Z" && r.stored == 49 && r.failed == 1 && r.failureClass == "unavailable")
        #expect(src.urls.filter { $0.contains("/06/") }.count == 1)   // only the listing of the incomplete run
        let none = FakeICON(); none.incompleteRuns = ["06", "00"]
        let r2 = try await ingestor("dewpoint_d2", try await kind.make(), config { $0.temp.d2Params = ["td_2m"] }, none).tick()
        #expect(r2.stored == 0 && r2.published == nil && r2.failed == 2 && none.fileCount == 0)
    }

    @Test(arguments: RepoKind.allCases)
    func unknownTemplateDropsTheRunAsInvalid(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let src = FakeICON(); src.template = 42
        let ing = ingestor("temperature_d2", repo, config(), src)
        await #expect(throws: ImageError.self) { try await ing.tick() }
        #expect(ing.failureClassOfLastError == "invalid")
        #expect(src.fileCount == 1)   // stops at the first file, no further downloads
        let latest = try await repo.layerLatestPublished(layer: "temperature_d2")
        #expect(latest == nil)
    }

    @Test(arguments: RepoKind.allCases)
    func wrongTimeBrokenFileOrWrongVariableAbortWithoutPublishing(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let src = FakeICON(); src.wrongTimeAt = 5
        await #expect(throws: ImageError.self) { try await ingestor("temperature_d2", repo, config(), src).tick() }
        #expect(src.fileCount == 6)
        let latest = try await repo.layerLatestPublished(layer: "temperature_d2")
        #expect(latest == nil)
        let broken = FakeICON(); broken.break_ = { $0.contains("_003_") }
        await #expect(throws: ImageError.self) { try await ingestor("temperature_d2", try await kind.make(), config(), broken).tick() }
        let swapped = FakeICON(); swapped.serveAs = "t_2m"   // dew point files that contain 2 m temperature: parameter check
        await #expect(throws: ImageError.self) { try await ingestor("dewpoint_d2", try await kind.make(), config(), swapped).tick() }
        #expect(swapped.fileCount == 1)
    }

    @Test(arguments: RepoKind.allCases)
    func transportErrorsAreRetriedThenGiveUpTheRun(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let flaky = FakeICON(); let hits = Locked(0)
        flaky.fail = { url in url.contains("_004_") && hits.withLock { $0 += 1; return $0 <= 2 } }
        let r = try await ingestor("temperature_d2", repo, config(), flaky).tick()
        #expect(r.published == "20261108T0600Z")   // two failures, third attempt works
        let dead = FakeICON(); dead.fail = { $0.contains("_004_") }
        await #expect(throws: RunUnavailable.self) { try await ingestor("temperature_d2", try await kind.make(), config(), dead).tick() }
    }

    @Test(arguments: RepoKind.allCases)
    func switchAndParamsGateTheRequests(kind: RepoKind) async throws {
        for source in [TempSource.off, .wms] {
            let src = FakeICON()
            let r = try await ingestor("temperature_d2", try await kind.make(), config(source), src).tick()
            #expect(!r.isLeader && src.count == 0)
        }
        // dew point is the default parameter; humidity only when switched on; temperature always
        let src = FakeICON()
        let rh = try await ingestor("humidity_d2", try await kind.make(), config(), src).tick()
        #expect(!rh.isLeader && src.count == 0)
        let on = try await ingestor("humidity_d2", try await kind.make(), config { $0.temp.d2Params = ["relhum_2m"] }, src).tick()
        #expect(on.published != nil && src.urls.allSatisfy { $0.contains("/relhum_2m/") })
        let temp = FakeICON()
        let t = try await ingestor("temperature_d2", try await kind.make(), config { $0.temp.d2Params = ["relhum_2m"] }, temp).tick()
        #expect(t.published != nil)
        let td = FakeICON()
        let d = try await ingestor("dewpoint_d2", try await kind.make(), config(), td).tick()
        #expect(d.published != nil && td.urls.allSatisfy { $0.contains("/td_2m/") })
    }

    @Test(arguments: RepoKind.allCases)
    func runIntervalSixOrThreeHoursAndSecondReplica(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let src = FakeICON()
        let a = try await ingestor("temperature_d2", repo, config(), src).tick()
        let calls = src.count
        let b = try await ingestor("temperature_d2", repo, config(), src, owner: "b").tick()
        #expect(a.isLeader && !b.isLeader && src.count == calls)
        // 3 h interval: at 09:30 the newest run is 06 UTC (09:30 - 75 min = 08:15), at 10:30 it is 09 UTC
        let early = LayerIngestor(spec: LayerCatalog.specs["temperature_d2"]!.resized(width: 64), config: config { $0.temp.d2RunIntervalHours = 3 }, repo: try await kind.make(),
                                  fetch: src.fetch, owner: "a", sleep: { _ in }, clock: { TimeUtil.fromID("20261108T1030Z")! }, d2Grid: tinyGrid)
        let r = try await early.tick()
        #expect(r.published == "20261108T0900Z")
    }
}

/// Measurement with the real files (not run without `ICON_D2_SAMPLE` = directory with the downloaded `.grib2.bz2` files):
/// `ICON_D2_SAMPLE=<dir> swift test -c release -Xswiftc -enable-testing --filter realPipelineTiming`, numbers go to the test log.
@Suite("ICON-D2 real files")
struct Icon2DRealFileTests {
    @Test func realPipelineTiming() throws {
        guard let dir = ProcessInfo.processInfo.environment["ICON_D2_SAMPLE"] else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".grib2.bz2") }.sorted()
        var total = (unpack: 0.0, decode: 0.0, validate: 0.0, render: 0.0, webp: 0.0)
        var sizes: [Int] = []
        func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        let spec = LayerCatalog.specs["temperature_d2"]!
        let methodUnderTest = Int32(ProcessInfo.processInfo.environment["WEBP_METHOD"] ?? "6") ?? 6
        for name in names {
            let variable = name.contains("relhum_2m") ? "relhum_2m" : name.contains("td_2m") ? "td_2m" : "t_2m"
            let kind = try #require(TempKind.kind(variable: variable)), scale = try #require(TempScale.load(id: kind.scaleID))
            let packed = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)))
            var t = clock()
            let raw = try Bzip2.decompress(packed, maxOutput: Icon2D.maxUnpackedBytes); total.unpack += clock() - t; t = clock()
            let field = try GribDecoder.decode(raw); total.decode += clock() - t; t = clock()
            try MercatorRender.validate(field, kind: kind); total.validate += clock() - t; t = clock()
            let image = MercatorRender.image(field: field, kind: kind, scale: scale, bbox: spec.bbox, width: 1024); total.render += clock() - t; t = clock()
            let webp = try ImagePipeline.toWebP(image, lossless: true, method: methodUnderTest); total.webp += clock() - t
            if name.contains("_012_2d_t_2m") {
                for m: Int32 in [0, 2, 3, 4, 6] {
                    let t0 = clock(); let bytes = try ImagePipeline.toWebP(image, lossless: true, method: m)
                    print("MEASURE webp method \(m): \(bytes.count) bytes, \(Int((clock() - t0) * 1000)) ms")
                }
            }
            sizes.append(webp.count)
            #expect(image.height == 1311)
            print("MEASURE \(name.suffix(28)) webp \(webp.count) bytes")
        }
        let n = Double(names.count)
        print(String(format: "MEASURE files %d per file ms: unpack %.0f decode %.0f validate %.0f render %.0f webp %.0f total %.0f", names.count,
                     total.unpack / n * 1000, total.decode / n * 1000, total.validate / n * 1000, total.render / n * 1000, total.webp / n * 1000,
                     (total.unpack + total.decode + total.validate + total.render + total.webp) / n * 1000))
        print("MEASURE webp bytes min \(sizes.min() ?? 0) max \(sizes.max() ?? 0) avg \(sizes.reduce(0, +) / max(sizes.count, 1))")
    }
}
