import Foundation
import Testing
@testable import RadarCore

@Suite("Temperature settings")
struct TempSourceTests {
    @Test func defaults() throws {
        let c = try Config.fromEnvironment([:])
        #expect(c.temp.source == .off && c.temp.d2Params == ["td_2m"] && c.temp.fallbackWarm && c.temp.d2MaxAgeHours == 7)
        #expect(c.temp.wmsLayer == "dwd:Icon-eu_reg00625_fd_gl_T" && c.temp.d2RunIntervalHours == 6)
        #expect(c.layers.isEmpty)
    }

    @Test func parsing() throws {
        let c = try Config.fromEnvironment(["TEMP_SOURCE": "ICON_D2", "TEMP_D2_PARAMS": "td_2m, relhum_2m", "TEMP_FALLBACK_WARM": "false",
                                            "TEMP_D2_MAX_AGE_HOURS": "9", "TEMP_WMS_LAYER": "dwd:Icon_reg025_fd_sl_T2M",
                                            "TEMP_D2_RUN_INTERVAL_HOURS": "3"])
        #expect(c.temp.source == .icon_d2 && c.temp.d2Params == ["td_2m", "relhum_2m"] && !c.temp.fallbackWarm)
        #expect(c.temp.d2MaxAgeHours == 9 && c.temp.wmsLayer == "dwd:Icon_reg025_fd_sl_T2M" && c.temp.d2RunIntervalHours == 3)
        // an empty value counts as unset
        #expect(try Config.fromEnvironment(["TEMP_SOURCE": ""]).temp.source == .off)
    }

    @Test func invalidValuesThrow() {
        for env in [["TEMP_SOURCE": "d2"], ["TEMP_D2_PARAMS": "td_2m,t_g"], ["TEMP_FALLBACK_WARM": "yes"], ["TEMP_D2_MAX_AGE_HOURS": "0"],
                    ["TEMP_D2_MAX_AGE_HOURS": "49"], ["TEMP_WMS_LAYER": "dwd:Other"], ["TEMP_D2_RUN_INTERVAL_HOURS": "4"],
                    ["TEMP_D2_RUN_INTERVAL_HOURS": "x"]] {
            #expect(throws: ConfigError.self) { try Config.fromEnvironment(env) }
        }
    }

    @Test func layersMainSwitch() throws {
        #expect(try Config.fromEnvironment(["LAYERS": "temperature"]).layers == ["temperature_wms"])
        #expect(try Config.fromEnvironment(["LAYERS": "radar,lightning temperature"]).layers == ["lightning", "temperature_wms"])
        // Internal storage IDs are no operator values (incident 2026-11-08: temperature_wms in LAYERS aborted the start of an older image).
        for id in ["temperature_wms", "temperature_d2", "dewpoint_d2", "humidity_d2"] {
            #expect(throws: ConfigError.self) { try Config.fromEnvironment(["LAYERS": "radar,\(id)"]) }
        }
        do { _ = try LayerCatalog.parse("temperature_wms") } catch { #expect("\(error)".contains("use 'temperature'")) }
        #expect(!LayerCatalog.operatorTokens.contains("temperature_wms") && LayerCatalog.operatorTokens.contains("temperature"))
        // A dashboard value with an internal ID is rejected on write and ignored (with a warning) at start; the service keeps running.
        #expect(throws: (any Error).self) { try ConfigRegistry.validateWrite(key: "LAYERS", raw: "temperature_wms", env: [:], stored: [:]) }
        var warnings: [String] = []
        let cfg = try ConfigRegistry.resolve(env: [:], stored: ["LAYERS": "temperature_wms", "FETCH_WORKERS": "2"], warn: { warnings.append($0) })
        #expect(cfg.layers.isEmpty && cfg.workers == 2 && warnings.contains { $0.contains("LAYERS") })
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["LAYERS": "dewpoint"]) }
        #expect(TempLayers.internalIDs.allSatisfy { $0.count <= 16 })
    }

    @Test func dashboardOverridesAreLiveExceptWMSLayer() throws {
        for key in ["TEMP_SOURCE", "TEMP_D2_PARAMS", "TEMP_FALLBACK_WARM", "TEMP_D2_MAX_AGE_HOURS", "TEMP_D2_RUN_INTERVAL_HOURS"] {
            #expect(ConfigRegistry.setting(key)?.apply == .live)
        }
        #expect(ConfigRegistry.setting("TEMP_WMS_LAYER")?.apply == .restart)
        let c = try Config().applying(overrides: ["TEMP_SOURCE": "wms", "TEMP_D2_RUN_INTERVAL_HOURS": "3", "TEMP_D2_PARAMS": "relhum_2m"], env: [:])
        #expect(c.temp.source == .wms && c.temp.d2RunIntervalHours == 3 && c.temp.d2Params == ["relhum_2m"])
        #expect(throws: ConfigError.self) { try Config().applying(overrides: ["TEMP_D2_PARAMS": "foo"], env: [:]) }
    }
}
