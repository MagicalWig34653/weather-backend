import Foundation
import Testing
@testable import RadarCore

private let now = TimeUtil.fromID("20261108T1200Z")!
private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

private func cfg(_ source: TempSource, params: Set<String> = ["td_2m"], _ edit: (inout Config) -> Void = { _ in }) -> Config {
    smallConfig { c in
        c.layers = ["temperature_wms"]; c.layerPauseSeconds = 0
        c.temp.source = source; c.temp.d2Params = params
        edit(&c)
    }
}

@Suite("Temperature alias and fallback")
struct TempResolverTests {
    private func resolve(_ id: String, _ c: Config, _ runs: [String: Date]) -> String? {
        TempResolver.resolve(publicID: id, config: c, latest: { runs[$0] }, now: now)
    }

    @Test func offAnswersNothing() {
        let runs = ["temperature_wms": hoursAgo(1), "temperature_d2": hoursAgo(1), "dewpoint_d2": hoursAgo(1), "humidity_d2": hoursAgo(1)]
        for id in TempLayers.publicIDs { #expect(resolve(id, cfg(.off), runs) == nil) }
        #expect(resolve("pressure", cfg(.wms), runs) == nil)
    }

    @Test func wmsServesOnlyTemperature() {
        let runs = ["temperature_wms": hoursAgo(1), "dewpoint_d2": hoursAgo(1)]
        #expect(resolve("temperature", cfg(.wms), runs) == "temperature_wms")
        #expect(resolve("dewpoint", cfg(.wms), runs) == nil)
        #expect(resolve("humidity", cfg(.wms), runs) == nil)
    }

    @Test func d2ServesAllWhenFresh() {
        let runs = ["temperature_wms": hoursAgo(2), "temperature_d2": hoursAgo(3), "dewpoint_d2": hoursAgo(3), "humidity_d2": hoursAgo(3)]
        let c = cfg(.icon_d2, params: ["td_2m", "relhum_2m"])
        #expect(resolve("temperature", c, runs) == "temperature_d2")
        #expect(resolve("dewpoint", c, runs) == "dewpoint_d2")
        #expect(resolve("humidity", c, runs) == "humidity_d2")
    }

    @Test func humidityNeedsItsParameter() {
        let runs = ["humidity_d2": hoursAgo(1), "dewpoint_d2": hoursAgo(1)]
        #expect(resolve("humidity", cfg(.icon_d2), runs) == nil)
        #expect(resolve("dewpoint", cfg(.icon_d2, params: ["relhum_2m"]), runs) == nil)
        #expect(resolve("dewpoint", cfg(.icon_d2), runs) == "dewpoint_d2")
    }

    @Test func d2AgeLimitAndFallbackToWMS() {
        let c = cfg(.icon_d2)
        // exactly at the limit (7 h) still counts, beyond it does not
        #expect(resolve("temperature", c, ["temperature_d2": hoursAgo(7), "temperature_wms": hoursAgo(2)]) == "temperature_d2")
        #expect(resolve("temperature", c, ["temperature_d2": hoursAgo(7.1), "temperature_wms": hoursAgo(2)]) == "temperature_wms")
        #expect(resolve("temperature", c, ["temperature_wms": hoursAgo(2)]) == "temperature_wms")   // D2 never ran
        // WMS fallback up to 18 h
        #expect(resolve("temperature", c, ["temperature_wms": hoursAgo(18)]) == "temperature_wms")
        #expect(resolve("temperature", c, ["temperature_wms": hoursAgo(18.1)]) == nil)
        #expect(resolve("temperature", c, [:]) == nil)
        // dew point and humidity have no fallback
        #expect(resolve("dewpoint", c, ["dewpoint_d2": hoursAgo(8), "temperature_wms": hoursAgo(1)]) == nil)
        #expect(resolve("dewpoint", cfg(.icon_d2) { $0.temp.d2MaxAgeHours = 12 }, ["dewpoint_d2": hoursAgo(8)]) == "dewpoint_d2")
    }

    @Test func ingestGate() {
        func allowed(_ v: TempVariant, _ s: TempSource, warm: Bool = true) -> Bool {
            TempResolver.ingestAllowed(variant: v, config: cfg(s) { $0.temp.fallbackWarm = warm })
        }
        #expect(!allowed(.wms, .off) && !allowed(.d2, .off))
        #expect(allowed(.wms, .wms) && !allowed(.d2, .wms))
        #expect(allowed(.wms, .icon_d2) && allowed(.d2, .icon_d2))
        #expect(!allowed(.wms, .icon_d2, warm: false) && allowed(.d2, .icon_d2, warm: false))
    }
}

private let fixedNow = TimeUtil.fromID("20261108T1037Z")!

extension DatabaseSuites {
@Suite("Temperature layer through the API and ingest", .serialized)
struct TempApiTests {
    private func ingest(_ repo: any Repo, _ c: Config, _ src: FakeSources) -> LayerIngestor {
        LayerIngestor(spec: LayerCatalog.specs["temperature_wms"]!, config: c, repo: repo, fetch: src.fetch, owner: "a",
                      sleep: { _ in }, clock: { fixedNow })
    }

    @Test func gateStopsFetchesWithoutSource() async throws {
        let repo = MemoryRepo()
        let source = Locked<TempSource>(.off)
        let live = ConfigProvider { cfg(source.withLock { $0 }) }
        let src = FakeSources(cfg(.off))
        let ing = LayerIngestor(spec: LayerCatalog.specs["temperature_wms"]!, configProvider: live, repo: repo, fetch: src.fetch, owner: "a",
                                sleep: { _ in }, clock: { fixedNow })
        var r = try await ing.tick()
        #expect(src.count == 0 && !r.isLeader && r.stored == 0)
        source.withLock { $0 = .wms }
        r = try await ing.tick()
        #expect(src.count > 0 && r.stored == 49 && r.published != nil)
    }

    @Test func fallbackWarmSwitchesTheWMSIngest() async throws {
        let src = FakeSources(cfg(.icon_d2))
        let cold = try await ingest(MemoryRepo(), cfg(.icon_d2) { $0.temp.fallbackWarm = false }, src).tick()
        #expect(src.count == 0 && cold.stored == 0)
        let warm = try await ingest(MemoryRepo(), cfg(.icon_d2), src).tick()
        #expect(src.count > 0 && warm.stored == 49)
    }

    @Test(arguments: RepoKind.allCases)
    func publicRoutesServeTheActiveSource(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = cfg(.wms)
        let src = FakeSources(c)
        _ = try await ingest(repo, c, src).tick()
        let api = Api(repo: repo, config: c, clock: { fixedNow })
        let res = try await api.handle(path: "/v1/layers/temperature/latest.json", ifNoneMatch: nil)
        #expect(res.status == 200)
        let m = try #require(try JSONSerialization.jsonObject(with: Data(res.body)) as? [String: Any])
        #expect(m["layer"] as? String == "temperature" && m["source"] as? String == "wms" && m["scale"] == nil && m["kind"] as? String == "forecast")
        #expect((m["slots"] as? [[String: String]])?.count == 49)
        #expect((m["legend"] as? [String: Any])?["url"] as? String == TempWMS.legend(for: TempWMS.defaultLayer)?.url)
        let path = try #require((m["slots"] as? [[String: String]])?.last?["path"])
        #expect(try await api.handle(path: "/v1/layers/temperature/\(path)", ifNoneMatch: nil).status == 200)
        #expect(await api.cache.contains("layer:temperature_wms/" + path.replacingOccurrences(of: ".webp", with: "")))
        // internal IDs are not routes; dew point / humidity do not exist with the WMS source
        #expect(try await api.handle(path: "/v1/layers/temperature_wms/latest.json", ifNoneMatch: nil).status == 404)
        #expect(try await api.handle(path: "/v1/layers/dewpoint/latest.json", ifNoneMatch: nil).status == 404)
        #expect(try await api.handle(path: "/v1/layers/humidity/latest.json", ifNoneMatch: nil).status == 404)
    }

    @Test(arguments: RepoKind.allCases)
    func offAndMissingMainSwitchAnswer404(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = cfg(.wms)
        _ = try await ingest(repo, c, FakeSources(c)).tick()
        let off = Api(repo: repo, config: cfg(.off), clock: { fixedNow })
        #expect(try await off.handle(path: "/v1/layers/temperature/latest.json", ifNoneMatch: nil).status == 404)
        let noSwitch = Api(repo: repo, config: cfg(.wms) { $0.layers = [] }, clock: { fixedNow })
        #expect(try await noSwitch.handle(path: "/v1/layers/temperature/latest.json", ifNoneMatch: nil).status == 404)
    }

    @Test(arguments: RepoKind.allCases)
    func staleWMSRunIsNotServedAsFallback(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = cfg(.icon_d2)
        _ = try await ingest(repo, c, FakeSources(c)).tick()   // run 06:00Z
        let fresh = Api(repo: repo, config: c, clock: { fixedNow })
        let m = try #require(try JSONSerialization.jsonObject(with: Data(try await fresh.handle(path: "/v1/layers/temperature/latest.json", ifNoneMatch: nil).body)) as? [String: Any])
        #expect(m["source"] as? String == "wms")   // D2 has no run: the WMS warm run answers
        let late = Api(repo: repo, config: c, clock: { fixedNow.addingTimeInterval(20 * 3600) })
        #expect(try await late.handle(path: "/v1/layers/temperature/latest.json", ifNoneMatch: nil).status == 404)
    }

    @Test(arguments: RepoKind.allCases)
    func statusListsPublicIds(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = cfg(.wms)
        _ = try await ingest(repo, c, FakeSources(c)).tick()
        let res = try await Api(repo: repo, config: c, clock: { fixedNow }).handle(path: "/v1/status", ifNoneMatch: nil)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(res.body)) as? [String: Any])
        let layers = try #require(doc["layers"] as? [[String: Any]])
        func entry(_ id: String) -> [String: Any]? { layers.first { $0["id"] as? String == id } }
        #expect(entry("temperature_wms") == nil)
        #expect(entry("temperature")?["enabled"] as? Bool == true && entry("temperature")?["has_data"] as? Bool == true)
        #expect(entry("dewpoint")?["enabled"] as? Bool == false && entry("humidity")?["enabled"] as? Bool == false)
        let off = try await Api(repo: repo, config: cfg(.off), clock: { fixedNow }).handle(path: "/v1/status", ifNoneMatch: nil)
        let offDoc = try #require(try JSONSerialization.jsonObject(with: Data(off.body)) as? [String: Any])
        let offTemp = (offDoc["layers"] as? [[String: Any]])?.first { $0["id"] as? String == "temperature" }
        #expect(offTemp?["enabled"] as? Bool == false && offTemp?["has_data"] as? Bool == false)
    }

    @Test(arguments: RepoKind.allCases)
    func clearCacheByInternalId(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let c = cfg(.wms)
        _ = try await ingest(repo, c, FakeSources(c)).tick()
        let api = Api(repo: repo, config: c, clock: { fixedNow })
        let m = try #require(try JSONSerialization.jsonObject(with: Data(try await api.handle(path: "/v1/layers/temperature/latest.json", ifNoneMatch: nil).body)) as? [String: Any])
        let path = try #require((m["slots"] as? [[String: String]])?.first?["path"])
        _ = try await api.handle(path: "/v1/layers/temperature/\(path)", ifNoneMatch: nil)
        let key = "layer:temperature_wms/" + path.replacingOccurrences(of: ".webp", with: "")
        #expect(await api.cache.contains(key))
        await api.cache.clear(scope: "temperature_wms")
        #expect(!(await api.cache.contains(key)))
        #expect(DashboardCache.isLayer("temperature_wms"))
    }
}
}
