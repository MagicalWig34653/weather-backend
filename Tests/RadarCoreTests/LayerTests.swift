import Foundation
import Testing
@testable import RadarCore

private let fixedNow = TimeUtil.fromID("20261031T1037Z")!

private func layerConfig(_ layers: [String], _ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig { c in c.layers = layers; c.layerPauseSeconds = 0; edit(&c) }
}

private func capsXML(layer: String, last: String) -> [UInt8] {
    Array("<Layer><Name>\(layer)</Name><Dimension name=\"time\" default=\"\(last)\" units=\"ISO8601\" nearestValue=\"1\">2020-09-01T00:00:00.000Z/\(last)/PT15M</Dimension></Layer>".utf8)
}

/// Fake of all sources: answers by URL, records requests; no network.
final class FakeSources: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [String] = []
    var xmlFor: @Sendable (String) -> Bool = { _ in false }
    var capsLatest = "2026-10-31T10:30:00.000Z"
    let good: [UInt8]
    let black: [UInt8]
    var useBlack: @Sendable (String) -> Bool = { _ in false }
    init(_ config: Config) {
        good = pngBytes(makeImage(width: config.width, height: config.height, seed: 2))
        black = pngBytes(RGBAImage(width: config.width, height: config.height,
                                   pixels: (0..<(config.width * config.height * 4)).map { $0 % 4 == 3 ? 255 : 0 }))
    }
    var count: Int { lock.withLock { urls.count } }
    var fetch: Fetch {
        { [self] url in
            lock.withLock { urls.append(url) }
            if url.contains("GetCapabilities") { return capsXML(layer: url.contains("mtg_fd") ? "rgb_geocolour" : "clm", last: capsLatest) }
            if xmlFor(url) { return xmlError }
            return useBlack(url) ? black : good
        }
    }
}

private func ingestor(_ spec: String, _ repo: any Repo, _ cfg: Config, _ src: FakeSources, owner: String = "a") -> LayerIngestor {
    LayerIngestor(spec: LayerCatalog.specs[spec]!, config: cfg, repo: repo, fetch: src.fetch, owner: owner,
                  sleep: { _ in }, clock: { fixedNow })
}

private func manifest(_ repo: any Repo, _ cfg: Config, _ id: String) async throws -> [String: Any] {
    let body = try #require(try await LayerManifest.build(repo: repo, config: cfg, spec: LayerCatalog.specs[id]!))
    return try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
}

@Suite("Layer configuration and sources")
struct LayerUnitTests {
    @Test func layersEnvParsing() throws {
        #expect(try Config.fromEnvironment([:]).layers.isEmpty)
        #expect(try Config.fromEnvironment(["LAYERS": "radar"]).layers.isEmpty)
        #expect(try Config.fromEnvironment(["LAYERS": "radar, clouds lightning,pressure"]).layers == ["pressure", "lightning", "clouds"])
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["LAYERS": "radar,wind"]) }
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["PRESSURE_FORECAST_HOURS": "0"]) }
    }

    @Test func requestURLs() {
        let cfg = Config()
        let slot = TimeUtil.fromID("20261031T1200Z")!, run = TimeUtil.fromID("20261031T0600Z")!
        let p = LayerSources.mapURL(spec: LayerCatalog.specs["pressure"]!, config: cfg, run: run, slot: slot)
        #expect(p.hasPrefix("https://maps.dwd.de/geoserver/ows?") && p.contains("SRS=EPSG%3A3857") && p.contains("TRANSPARENT=TRUE"))
        #expect(p.contains("TIME=2026-10-31T12%3A00%3A00.000Z") && p.contains("DIM_REFERENCE_TIME=2026-10-31T06%3A00%3A00.000Z"))
        let l = LayerSources.mapURL(spec: LayerCatalog.specs["lightning"]!, config: cfg, run: slot, slot: slot)
        #expect(!l.contains("DIM_REFERENCE_TIME") && l.contains("LAYERS=dwd%3ABlitzdichte"))
        let c = LayerSources.mapURL(spec: LayerCatalog.specs["clouds"]!, config: cfg, run: slot, slot: slot)
        #expect(c.hasPrefix("https://view.eumetsat.int/geoserver/wms?") && c.contains("CRS=EPSG%3A3857") && c.contains("VERSION=1.3.0"))
        #expect(c.contains("TIME=2026-10-31T12%3A00%3A00Z") && c.contains("BBOX=612257%2C5942074%2C1736584%2C7381298"))
        #expect(LayerSources.capabilitiesURL(spec: LayerCatalog.specs["cloudmask"]!, config: cfg)
                == "https://view.eumetsat.int/geoserver/msg_fes/wms?service=WMS&version=1.3.0&request=GetCapabilities")
        #expect(LayerSources.capabilitiesURL(spec: LayerCatalog.specs["lightning"]!, config: cfg) == nil)
    }

    @Test func capabilitiesLatestSlot() {
        let latest = LayerSources.latestSlot(capabilities: capsXML(layer: "clm", last: "2026-10-31T09:30:00.000Z"), layerName: "clm")
        #expect(latest == TimeUtil.fromID("20261031T0930Z"))
        #expect(LayerSources.latestSlot(capabilities: capsXML(layer: "clm", last: "x"), layerName: "other") == nil)
    }

    @Test func blackCellDetection() {
        let cfg = smallConfig()
        #expect(ImagePipeline.blackCells(makeImage(width: cfg.width, height: cfg.height, seed: 1)) == 0)
        var img = makeImage(width: cfg.width, height: cfg.height, seed: 1)
        var px = img.pixels
        for y in 0..<(cfg.height / 2) { for x in (cfg.width / 2)..<cfg.width { let o = (y * cfg.width + x) * 4; px[o] = 0; px[o + 1] = 0; px[o + 2] = 0 } }
        img = RGBAImage(width: img.width, height: img.height, pixels: px)
        #expect(ImagePipeline.blackCells(img) >= 30)
    }

    @Test func attributionWording() {
        #expect(LayerCatalog.specs["clouds"]!.attribution(year: 2026) == "Contains modified EUMETSAT Meteosat data 2026")
        #expect(LayerCatalog.specs["cloudmask"]!.attribution(year: 2027) == "Contains modified EUMETSAT Meteosat data 2027")
        #expect(LayerCatalog.specs["pressure"]!.attribution(year: 2026) == "Quelle: Deutscher Wetterdienst")
    }
}

extension DatabaseSuites {
@Suite("Layer ingest and API", .serialized)
struct LayerServiceTests {
    @Test(arguments: RepoKind.allCases)
    func lightningFillsHistoryNewestFirstAndManifest(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["lightning"]) { $0.lightningHistoryHours = 1 }
        let src = FakeSources(cfg)
        let ing = ingestor("lightning", repo, cfg, src)
        let first = try await ing.tick()
        #expect(first.isLeader && first.stored == LayerIngestor.slotsPerTick)
        var m = try await manifest(repo, cfg, "lightning")
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.count == 8 && slots.last?["time"] == "2026-10-31T10:30:00Z" && slots.last?["kind"] == "observation")
        #expect(m["attribution"] as? String == "Quelle: Deutscher Wetterdienst")
        #expect(m["step_minutes"] as? Int == 5 && m["schema"] as? Int == 1 && m["kind"] as? String == "observation")
        #expect((m["legend"] as? [String: Any])?["width"] as? Int == 119)
        _ = try await ing.tick()
        let calls = src.count
        let third = try await ing.tick()
        #expect(third.stored == 0 && src.count == calls)  // complete: 13 slots in 1 h, nothing is fetched again
        m = try await manifest(repo, cfg, "lightning")
        #expect((m["slots"] as? [Any])?.count == 13)
        let path = try #require(slots.last?["path"])
        let ids = path.dropLast(5).split(separator: "/").map(String.init)
        let blob = try #require(try await repo.layerGetSlot(layer: "lightning", runID: ids[0], slotID: ids[1]))
        #expect(blob.contentType == "image/webp" && (try? ImagePipeline.decodeWebP(blob.data).width) == cfg.width)
    }

    @Test(arguments: RepoKind.allCases)
    func secondReplicaIsNotLeader(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["lightning"])
        let src = FakeSources(cfg)
        _ = try await ingestor("lightning", repo, cfg, src, owner: "a").tick()
        let calls = src.count
        let b = try await ingestor("lightning", repo, cfg, src, owner: "b").tick()
        #expect(!b.isLeader && src.count == calls)
    }

    @Test(arguments: RepoKind.allCases)
    func cloudsRejectIncompleteImagesAndUseCapabilities(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["clouds"]) { $0.cloudsHistoryHours = 1 }
        let src = FakeSources(cfg)
        src.capsLatest = "2026-10-31T10:10:00Z"
        src.useBlack = { $0.contains("TIME=2026-10-31T10%3A10%3A00Z") }
        let ing = ingestor("clouds", repo, cfg, src)
        let r = try await ing.tick()
        #expect(r.failed == 1 && r.stored >= 1)
        #expect(try await !repo.layerIsPublished(layer: "clouds", runID: "20261031T1010Z"))  // black area: never published
        #expect(!src.urls.contains { $0.contains("T10%3A20%3A00Z") })  // nothing newer than the capabilities say
        let m = try await manifest(repo, cfg, "clouds")
        #expect((m["slots"] as? [[String: String]])?.contains { $0["time"] == "2026-10-31T10:00:00Z" } == true)
        #expect((m["attribution"] as? String)?.hasPrefix("Contains modified EUMETSAT Meteosat data 20") == true)
        #expect(m["legend"] == nil && m["step_minutes"] as? Int == 10)
    }

    @Test(arguments: RepoKind.allCases)
    func cloudmaskIsLosslessAndHasLegend(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["cloudmask"]) { $0.cloudmaskHistoryHours = 1 }
        let src = FakeSources(cfg)
        src.capsLatest = "2026-10-31T10:30:00Z"
        _ = try await ingestor("cloudmask", repo, cfg, src).tick()
        let m = try await manifest(repo, cfg, "cloudmask")
        let slot = try #require((m["slots"] as? [[String: String]])?.last)
        let ids = try #require(slot["path"]).dropLast(5).split(separator: "/").map(String.init)
        let blob = try #require(try await repo.layerGetSlot(layer: "cloudmask", runID: ids[0], slotID: ids[1]))
        let expected = makeImage(width: cfg.width, height: cfg.height, seed: 2)
        #expect(try ImagePipeline.decodeWebP(blob.data).pixels == expected.pixels)
        #expect((m["legend"] as? [String: Any])?["height"] as? Int == 80 && m["step_minutes"] as? Int == 15)
    }

    @Test(arguments: RepoKind.allCases)
    func pressureFallsBackToPreviousRunAndKeepsTwoRuns(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["pressure"]) { $0.pressureForecastHours = 3; $0.pressureRetentionRuns = 2 }
        let src = FakeSources(cfg)
        // fixedNow 10:37 -> newest reference 06:00; pretend 06:00 is not offered yet, 00:00 is.
        src.xmlFor = { $0.contains("DIM_REFERENCE_TIME=2026-10-31T06") }
        let ing = ingestor("pressure", repo, cfg, src)
        let r = try await ing.tick()
        #expect(r.published == "20261031T0000Z" && r.stored == 4)
        var m = try await manifest(repo, cfg, "pressure")
        let slots = try #require(m["slots"] as? [[String: String]])
        #expect(slots.map { $0["kind"]! } == ["analysis", "forecast", "forecast", "forecast"])
        #expect(m["forecast_horizon_minutes"] as? Int == 180 && m["step_minutes"] as? Int == 60 && m["run"] as? String == "20261031T0000Z")
        // the 06:00 run appears later
        src.xmlFor = { _ in false }
        let r2 = try await ing.tick()
        #expect(r2.published == "20261031T0600Z")
        #expect(try await ing.tick().stored == 0)  // newest run published: no request at all
        m = try await manifest(repo, cfg, "pressure")
        #expect(m["run"] as? String == "20261031T0600Z")
        #expect(try await repo.layerIsPublished(layer: "pressure", runID: "20261031T0000Z"))
        // a third run pushes the oldest out
        let later = LayerIngestor(spec: LayerCatalog.specs["pressure"]!, config: cfg, repo: repo, fetch: src.fetch, owner: "a",
                                  sleep: { _ in }, clock: { TimeUtil.fromID("20261031T1305Z")! })
        _ = try await later.tick()
        #expect(try await !repo.layerIsPublished(layer: "pressure", runID: "20261031T0000Z"))
        #expect(try await repo.layerIsPublished(layer: "pressure", runID: "20261031T0600Z"))
    }

    @Test(arguments: RepoKind.allCases)
    func apiRoutesAndHeaders(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let on = layerConfig(["lightning"])
        let src = FakeSources(on)
        _ = try await ingestor("lightning", repo, on, src).tick()
        let api = Api(repo: repo, config: on)
        let latest = try await api.handle(path: "/v1/layers/lightning/latest.json", ifNoneMatch: nil)
        #expect(latest.status == 200 && latest.headers.contains { $0.0 == "Cache-Control" && $0.1 == Api.latest })
        let m = try #require(try JSONSerialization.jsonObject(with: Data(latest.body)) as? [String: Any])
        let path = try #require((m["slots"] as? [[String: String]])?.last?["path"])
        let slot = try await api.handle(path: "/v1/layers/lightning/\(path)", ifNoneMatch: nil)
        #expect(slot.status == 200 && slot.headers.contains { $0.0 == "Cache-Control" && $0.1 == Api.immutable })
        let etag = try #require(slot.headers.first { $0.0 == "ETag" }?.1)
        #expect(try await api.handle(path: "/v1/layers/lightning/\(path)", ifNoneMatch: etag).status == 304)
        #expect(!(slot.headers.contains { $0.0 == "Set-Cookie" }))
        // other layers, wrong ids and the radar path of a layer id: 404
        #expect(try await api.handle(path: "/v1/layers/pressure/latest.json", ifNoneMatch: nil).status == 404)
        #expect(try await api.handle(path: "/v1/layers/lightning/nope.webp", ifNoneMatch: nil).status == 404)
        #expect(try await api.handle(path: "/v1/layers/wind/latest.json", ifNoneMatch: nil).status == 404)
        #expect(try await api.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil).status == 404)  // radar unchanged: no run
        // disabled layer answers 404 although data exists
        let off = Api(repo: repo, config: layerConfig([]))
        #expect(try await off.handle(path: "/v1/layers/lightning/latest.json", ifNoneMatch: nil).status == 404)
        #expect(try await off.handle(path: "/v1/layers/lightning/\(path)", ifNoneMatch: nil).status == 404)
    }
}
}
