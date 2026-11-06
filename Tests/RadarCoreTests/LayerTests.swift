import Foundation
import Testing
@testable import RadarCore

private let fixedNow = TimeUtil.fromID("20261031T1037Z")!

private func layerConfig(_ layers: [String], _ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig { c in c.layers = layers; c.layerPauseSeconds = 0; edit(&c) }
}

private func capsXML(layers: [String], last: String) -> [UInt8] {
    Array(layers.map { "<Layer><Name>\($0)</Name><Dimension name=\"time\" default=\"\(last)\" units=\"ISO8601\" nearestValue=\"1\">2020-09-01T00:00:00.000Z/\(last)/PT15M</Dimension></Layer>" }.joined().utf8)
}

private func capsXML(layer: String, last: String) -> [UInt8] { capsXML(layers: [layer], last: last) }

/// Fake of all sources: answers by URL (image size from WIDTH/HEIGHT), records requests; no network.
final class FakeSources: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [String] = []
    var xmlFor: @Sendable (String) -> Bool = { _ in false }
    var capsLatest = "2026-10-31T10:30:00.000Z"
    private var good: [String: [UInt8]] = [:]
    private var black: [String: [UInt8]] = [:]
    var useBlack: @Sendable (String) -> Bool = { _ in false }
    init(_ config: Config) {}
    var count: Int { lock.withLock { urls.count } }

    private func size(_ url: String) -> (Int, Int) {
        func value(_ key: String) -> Int {
            url.split(separator: "&").first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) } ?? 0
        }
        return (value("WIDTH"), value("HEIGHT"))
    }

    var fetch: Fetch {
        { [self] url in
            lock.withLock { urls.append(url) }
            if url.contains("GetCapabilities") {
                return url.contains("mtg_fd") ? capsXML(layers: ["rgb_geocolour", "vis06_hrfi"], last: capsLatest) : capsXML(layer: "clm", last: capsLatest)
            }
            if xmlFor(url) { return xmlError }
            let (w, h) = size(url)
            let key = "\(w)x\(h)"
            return lock.withLock {
                if useBlack(url) {
                    if black[key] == nil {
                        black[key] = pngBytes(RGBAImage(width: w, height: h, pixels: (0..<(w * h * 4)).map { $0 % 4 == 3 ? 255 : 0 }))
                    }
                    return black[key]!
                }
                if good[key] == nil { good[key] = pngBytes(makeImage(width: w, height: h, seed: 2)) }
                return good[key]!
            }
        }
    }
}

/// The Europe layers are 2048 px wide in production; tests run them small.
private func testSpec(_ id: String) -> LayerSpec {
    let spec = LayerCatalog.specs[id]!
    return spec.fixedWidth == nil ? spec : spec.resized(width: 256)
}

private func ingestor(_ spec: String, _ repo: any Repo, _ cfg: Config, _ src: FakeSources, owner: String = "a") -> LayerIngestor {
    LayerIngestor(spec: testSpec(spec), config: cfg, repo: repo, fetch: src.fetch, owner: owner,
                  sleep: { _ in }, clock: { fixedNow })
}

private func manifest(_ repo: any Repo, _ cfg: Config, _ id: String) async throws -> [String: Any] {
    let body = try #require(try await LayerManifest.build(repo: repo, config: cfg, spec: testSpec(id)))
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

    @Test func newLayerIdsAndSettings() throws {
        #expect(try Config.fromEnvironment(["LAYERS": "cloudmask_vis_eu, pressure_eu cloudmask_vis,pressure"]).layers
                == ["pressure", "pressure_eu", "cloudmask_vis", "cloudmask_vis_eu"])
        #expect(LayerCatalog.order.count == LayerCatalog.specs.count)
        #expect(try Config.fromEnvironment([:]).pressureEUForecastHours == 24)
        #expect(try Config.fromEnvironment(["PRESSURE_EU_FORECAST_HOURS": "48", "CLOUDMASK_VIS_EU_HISTORY_HOURS": "6"]).pressureEUForecastHours == 48)
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["PRESSURE_EU_FORECAST_HOURS": "0"]) }
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["CLOUDMASK_VIS_HISTORY_HOURS": "25"]) }
        // column limits of layer_run/layer_slot (VARCHAR(16)) and radar_lock (VARCHAR(32), "layer:" prefix)
        for id in LayerCatalog.order { #expect(id.count <= 16 && "layer:\(id)".count <= 32) }
        // the app accepts images up to 4096 px per side
        let cfg = Config()
        for spec in LayerCatalog.specs.values {
            #expect(spec.width(cfg) <= LayerSpec.maxPixelsPerSide && spec.height(cfg) <= LayerSpec.maxPixelsPerSide)
        }
        let eu = LayerCatalog.specs["pressure_eu"]!
        #expect(eu.width(cfg) == 2048 && eu.height(cfg) == 2168 && eu.bbox == RadarConstants.europeBBox)
        let de = LayerCatalog.specs["cloudmask_vis"]!
        #expect(de.width(cfg) == 1024 && de.height(cfg) == 1311 && de.bbox == RadarConstants.bbox)
        // existing layers keep the radar grid and follow IMAGE_WIDTH
        #expect(LayerCatalog.specs["pressure"]!.width(smallConfig()) == 256)
        // Europe extent: lon -25..45, lat 30..72
        let sw = RadarConstants.mercatorToWGS84(x: RadarConstants.europeBBox[0], y: RadarConstants.europeBBox[1])
        let ne = RadarConstants.mercatorToWGS84(x: RadarConstants.europeBBox[2], y: RadarConstants.europeBBox[3])
        #expect(abs(sw.lon + 25) < 0.001 && abs(sw.lat - 30) < 0.001 && abs(ne.lon - 45) < 0.001 && abs(ne.lat - 72) < 0.001)
    }

    @Test func newLayerRequestURLs() {
        let cfg = Config()
        let slot = TimeUtil.fromID("20261031T1200Z")!, run = TimeUtil.fromID("20261031T0600Z")!
        let p = LayerSources.mapURL(spec: LayerCatalog.specs["pressure_eu"]!, config: cfg, run: run, slot: slot)
        #expect(p.contains("WIDTH=2048&HEIGHT=2168") && p.contains("BBOX=-2782987%2C3503550%2C5009377%2C11753185"))
        #expect(p.contains("LAYERS=dwd%3AIcon_reg025_fd_sl_PMSL") && p.contains("DIM_REFERENCE_TIME=2026-10-31T06"))
        let v = LayerSources.mapURL(spec: LayerCatalog.specs["cloudmask_vis"]!, config: cfg, run: slot, slot: slot)
        #expect(v.hasPrefix("https://view.eumetsat.int/geoserver/wms?") && v.contains("LAYERS=mtg_fd%3Avis06_hrfi"))
        #expect(v.contains("WIDTH=1024&HEIGHT=1311") && v.contains("BBOX=612257%2C5942074%2C1736584%2C7381298"))
        let e = LayerSources.mapURL(spec: LayerCatalog.specs["cloudmask_vis_eu"]!, config: cfg, run: slot, slot: slot)
        #expect(e.contains("WIDTH=2048&HEIGHT=2168") && e.contains("TIME=2026-10-31T12%3A00%3A00Z"))
        #expect(LayerSources.capabilitiesURL(spec: LayerCatalog.specs["cloudmask_vis"]!, config: cfg)
                == "https://view.eumetsat.int/geoserver/mtg_fd/wms?service=WMS&version=1.3.0&request=GetCapabilities")
        // the radar request of a default layer is unchanged
        let c = LayerSources.mapURL(spec: LayerCatalog.specs["clouds"]!, config: cfg, run: slot, slot: slot)
        #expect(c.contains("WIDTH=1024&HEIGHT=1311"))
    }

    @Test func sunElevationAndDarkCells() {
        // Berlin around local solar noon on 1 Nov: 90 - 52.5 - 14.3 (declination) = about 23 degrees
        let noon = SunElevation.degrees(lat: 52.5, lon: 13.4, at: TimeUtil.fromID("20261101T1105Z")!)
        #expect(abs(noon - 23.2) < 1.0)
        #expect(SunElevation.degrees(lat: 52.5, lon: 13.4, at: TimeUtil.fromID("20261101T2300Z")!) < -30)
        // equator, 21 Mar-ish noon at lon 0 stays near the zenith; antipodal side is dark
        #expect(SunElevation.degrees(lat: 0, lon: 0, at: TimeUtil.fromID("20260320T1200Z")!) > 85)
        #expect(SunElevation.degrees(lat: 0, lon: 180, at: TimeUtil.fromID("20260320T1200Z")!) < -85)
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

    @Test func darkCellsAreSkipped() {
        let cfg = smallConfig()
        let black = RGBAImage(width: cfg.width, height: cfg.height,
                              pixels: (0..<(cfg.width * cfg.height * 4)).map { $0 % 4 == 3 ? 255 : 0 })
        #expect(ImagePipeline.blackCells(black) == 256)
        #expect(ImagePipeline.blackCells(black, mayBeDark: { _, _ in true }) == 0)
        #expect(ImagePipeline.blackCells(black, mayBeDark: { gx, _ in gx < 8 }) == 128)
    }

    @Test func attributionWording() {
        #expect(LayerCatalog.specs["cloudmask_vis"]!.attribution(year: 2026) == "Contains modified EUMETSAT Meteosat data 2026")
        #expect(LayerCatalog.specs["cloudmask_vis_eu"]!.attribution(year: 2027) == "Contains modified EUMETSAT Meteosat data 2027")
        #expect(LayerCatalog.specs["pressure_eu"]!.attribution(year: 2026) == "Quelle: Deutscher Wetterdienst")
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

    @Test func lateCompletedForecastRunIsRetriedBeyondTwoAttempts() async throws {
        let now = Locked(fixedNow)
        let repo = MemoryRepo(clock: { now.withLock { $0 } })
        let cfg = layerConfig(["pressure"]) { $0.pressureForecastHours = 3 }
        let src = FakeSources(cfg)
        // Slot +2 h of the 06:00 run is not there yet (the source completes the run late); 00:00 is not offered at all.
        src.xmlFor = { $0.contains("DIM_REFERENCE_TIME=2026-10-31T06") && $0.contains("TIME=2026-10-31T08") || $0.contains("DIM_REFERENCE_TIME=2026-10-31T00") }
        let ing = LayerIngestor(spec: testSpec("pressure"), config: cfg, repo: repo, fetch: src.fetch, owner: "a", sleep: { _ in },
                                clock: { now.withLock { $0 } })
        for _ in 0..<4 {  // four failed claims: the old limit of two attempts would have given the run up for good
            do { _ = try await ing.tick() } catch { #expect(LayerTickResult.classify(error) == "unavailable") }
            now.withLock { $0 = $0.addingTimeInterval(400) }
        }
        #expect(try await !repo.layerIsPublished(layer: "pressure", runID: "20261031T0600Z"))
        src.xmlFor = { _ in false }
        let done = try await ing.tick()
        #expect(done.published == "20261031T0600Z")
    }

    @Test func publishCadenceIsTheRunIntervalForForecastLayers() {
        #expect(LayerCatalog.specs["pressure"]!.publishCadenceSeconds == 6 * 3600)
        #expect(LayerCatalog.specs["pressure_eu"]!.publishCadenceSeconds == 6 * 3600)
        #expect(LayerCatalog.specs["lightning"]!.publishCadenceSeconds == 300)
    }

    @Test func failureClassesAreFixedLabels() {
        #expect(LayerTickResult.classify(ImageError.invalid("incomplete image (3 black cells)")) == "incomplete")
        #expect(LayerTickResult.classify(ImageError.invalid("truncated")) == "invalid")
        #expect(LayerTickResult.classify(RunUnavailable(description: "x")) == "unavailable")
        #expect(LayerTickResult.classify(LeaseLost()) == "lease")
    }

    @Test(arguments: RepoKind.allCases)
    func statusEndpointDistinguishesDisabledAndEmptyLayers(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["lightning", "clouds"]) { $0.buildRevision = "abc1234" }
        let src = FakeSources(cfg)
        _ = try await ingestor("lightning", repo, cfg, src).tick()
        let res = try await Api(repo: repo, config: cfg).handle(path: "/v1/status", ifNoneMatch: nil)
        #expect(res.status == 200)
        #expect(res.headers.contains { $0.0 == "Cache-Control" && $0.1 == "no-store" })
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(res.body)) as? [String: Any])
        #expect(doc["revision"] as? String == "abc1234")
        #expect(doc["push"] as? Bool == false)
        let layers = try #require(doc["layers"] as? [[String: Any]])
        func entry(_ id: String) -> [String: Any]? { layers.first { $0["id"] as? String == id } }
        #expect(layers.count == 8)
        #expect(entry("pressure_eu")?["enabled"] as? Bool == false && entry("cloudmask_vis_eu")?["enabled"] as? Bool == false)
        #expect(entry("radar")?["enabled"] as? Bool == true && entry("radar")?["has_data"] as? Bool == false)
        #expect(entry("lightning")?["enabled"] as? Bool == true && entry("lightning")?["has_data"] as? Bool == true)
        #expect(entry("lightning")?["latest_run"] is String)
        #expect(entry("clouds")?["enabled"] as? Bool == true && entry("clouds")?["has_data"] as? Bool == false)
        #expect(entry("pressure")?["enabled"] as? Bool == false && entry("pressure")?["latest_run"] == nil)
        // no secrets or per-user data in the document
        let text = String(decoding: res.body, as: UTF8.self)
        #expect(!text.contains("APNS") && !text.contains("secret"))
    }

    @Test func buildRevisionEnvParsing() throws {
        #expect(try Config.fromEnvironment([:]).buildRevision == nil)
        #expect(try Config.fromEnvironment(["BUILD_REVISION": "0123456789ABCDEF0123"]).buildRevision == "0123456789ab")
        #expect(try Config.fromEnvironment(["BUILD_REVISION": "not hex!"]).buildRevision == nil)
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

    @Test(arguments: RepoKind.allCases)
    func pressureEuropeHasOwnExtentAndSlotLimit(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["pressure_eu", "pressure"]) { $0.pressureEUForecastHours = 2; $0.pressureForecastHours = 3 }
        let src = FakeSources(cfg)
        let eu = try await ingestor("pressure_eu", repo, cfg, src).tick()
        #expect(eu.published == "20261031T0600Z" && eu.stored == 3)  // own forecast limit: 2 h + analysis
        _ = try await ingestor("pressure", repo, cfg, src).tick()
        let m = try await manifest(repo, cfg, "pressure_eu")
        let img = try #require(m["image"] as? [String: Any])
        #expect(img["width"] as? Int == 256 && img["height"] as? Int == 271 && img["projection"] as? String == "EPSG:3857")
        #expect((img["bbox"] as? [Double]) == RadarConstants.europeBBox)
        let wgs = try #require(img["bbox_wgs84"] as? [Double])
        #expect(wgs == [-25.0, 30.0, 45.0, 72.0])
        #expect(m["layer"] as? String == "pressure_eu" && (m["slots"] as? [Any])?.count == 3 && m["forecast_horizon_minutes"] as? Int == 120)
        #expect((m["legend"] as? [String: Any])?["width"] as? Int == 219)
        // the German pressure layer is unchanged: radar grid, own limit
        let de = try await manifest(repo, cfg, "pressure")
        #expect((de["image"] as? [String: Any])?["height"] as? Int == RadarConstants.imageHeight(width: 256))
        #expect((de["image"] as? [String: Any])?["bbox"] as? [Double] == RadarConstants.bbox && (de["slots"] as? [Any])?.count == 4)
        // requests of the Europe layer carry the Europe extent
        #expect(src.urls.filter { $0.contains("BBOX=-2782987") }.count == 3)
        let blob = try #require(try await repo.layerGetSlot(layer: "pressure_eu", runID: "20261031T0600Z", slotID: "20261031T0600Z"))
        #expect(try ImagePipeline.decodeWebP(blob.data).height == 271)
    }

    @Test(arguments: RepoKind.allCases)
    func visibleChannelKeepsNightImagesButRejectsBlackTilesInDaylight(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = layerConfig(["cloudmask_vis"]) { $0.cloudmaskVisHistoryHours = 1 }
        // Day over Germany (10:30 UTC): an all-black image is a missing tile and is not published.
        let day = FakeSources(cfg)
        day.capsLatest = "2026-10-31T10:30:00Z"
        day.useBlack = { $0.contains("TIME=2026-10-31T10%3A30%3A00Z") }
        let r = try await ingestor("cloudmask_vis", repo, cfg, day).tick()
        #expect(r.failed >= 1 && r.stored >= 1)
        #expect(try await !repo.layerIsPublished(layer: "cloudmask_vis", runID: "20261031T1030Z"))
        // Night (23:00 UTC): sun is below the horizon everywhere; the dark image is the real one and is published.
        let nightRepo = try await kind.make()
        let night = FakeSources(cfg)
        night.capsLatest = "2026-10-31T23:00:00Z"
        night.useBlack = { _ in true }
        let n = try await ingestor("cloudmask_vis", nightRepo, cfg, night).tick()
        #expect(n.failed == 0 && n.stored == 7)  // 1 h history at 10 min plus the newest slot
        #expect(try await nightRepo.layerIsPublished(layer: "cloudmask_vis", runID: "20261031T2300Z"))
        let m = try await manifest(nightRepo, cfg, "cloudmask_vis")
        #expect(m["step_minutes"] as? Int == 10 && m["kind"] as? String == "observation" && m["legend"] == nil)
        #expect((m["attribution"] as? String)?.hasPrefix("Contains modified EUMETSAT Meteosat data 20") == true)
        #expect((m["image"] as? [String: Any])?["bbox"] as? [Double] == RadarConstants.bbox)
        // lossless: the stored slot decodes to the source pixels
        let slot = try #require((m["slots"] as? [[String: String]])?.last)
        let ids = try #require(slot["path"]).dropLast(5).split(separator: "/").map(String.init)
        let blob = try #require(try await nightRepo.layerGetSlot(layer: "cloudmask_vis", runID: ids[0], slotID: ids[1]))
        #expect(try ImagePipeline.decodeWebP(blob.data).pixels.allSatisfy { $0 == 0 || $0 == 255 })
    }

    @Test(arguments: RepoKind.allCases)
    func visibleChannelEuropeAcrossTheTerminator(kind: RepoKind) async throws {
        // 06:20 UTC on 1 Nov: Europe is half dark (west) and half lit (east); black only in the dark part is fine,
        // a fully black image is not (the east is in daylight).
        let repo = try await kind.make()
        let cfg = layerConfig(["cloudmask_vis_eu"]) { $0.cloudmaskVisEUHistoryHours = 1 }
        let src = FakeSources(cfg)
        src.capsLatest = "2026-11-01T06:20:00Z"
        src.useBlack = { _ in true }
        let r = try await ingestor("cloudmask_vis_eu", repo, cfg, src).tick()
        #expect(r.stored == 0 && r.failed >= 1)
        // Europe's lit part at noon: normal image is published with the Europe extent and 10 min step
        let repo2 = try await kind.make()
        let ok = FakeSources(cfg)
        ok.capsLatest = "2026-11-01T12:00:00Z"
        let r2 = try await ingestor("cloudmask_vis_eu", repo2, cfg, ok).tick()
        #expect(r2.failed == 0 && r2.stored == 7)
        let m = try await manifest(repo2, cfg, "cloudmask_vis_eu")
        #expect((m["image"] as? [String: Any])?["bbox"] as? [Double] == RadarConstants.europeBBox)
        #expect(m["layer"] as? String == "cloudmask_vis_eu" && m["step_minutes"] as? Int == 10)
        #expect(ok.urls.contains { $0.contains("GetCapabilities") && $0.contains("mtg_fd") })
        #expect(ok.urls.filter { $0.contains("GetMap") }.allSatisfy { $0.contains("vis06_hrfi") && $0.contains("WIDTH=256&HEIGHT=271") })
    }
}
}
