import Foundation
import Testing
@testable import RadarCore

@Suite("Temperature WMS layer")
struct TempLayerSpecTests {
    let slot = TimeUtil.fromID("20261108T1200Z")!, run = TimeUtil.fromID("20261108T0600Z")!

    @Test func requestUsesLayerAndStyle() {
        let spec = LayerCatalog.specs["temperature_wms"]!
        #expect(spec.id.count <= 16 && spec.kind == .forecast && spec.stepSeconds == 3600 && spec.publicID == "temperature" && spec.source == "wms")
        let url = LayerSources.mapURL(spec: spec, config: Config(), run: run, slot: slot)
        #expect(url.contains("LAYERS=dwd%3AIcon-eu_reg00625_fd_gl_T"))
        #expect(url.contains("STYLES=icon-eu_reg00625_fd_gl_t_isoarea_tkb"))
        #expect(url.contains("TIME=2026-11-08T12%3A00%3A00.000Z") && url.contains("DIM_REFERENCE_TIME=2026-11-08T06%3A00%3A00.000Z"))
        #expect(url.contains("WIDTH=1024&HEIGHT=1311") && url.contains("TRANSPARENT=TRUE"))
    }

    @Test func fallbackLayerHasNoStyleAndOwnLegend() {
        var cfg = Config()
        cfg.temp.wmsLayer = "dwd:Icon_reg025_fd_sl_T2M"
        let spec = LayerCatalog.specs["temperature_wms"]!
        let url = LayerSources.mapURL(spec: spec, config: cfg, run: run, slot: slot)
        #expect(url.contains("LAYERS=dwd%3AIcon_reg025_fd_sl_T2M") && url.contains("STYLES=&"))
        #expect(spec.legend(cfg)?.url.contains("layer=dwd:Icon_reg025_fd_sl_T2M") == true && spec.legend(cfg)?.url.contains("style=") == false)
        #expect(spec.legend(Config())?.url.contains("style=icon-eu_reg00625_fd_gl_t_isoarea_tkb") == true)
    }

    @Test func otherLayersKeepEmptyStyle() {
        let url = LayerSources.mapURL(spec: LayerCatalog.specs["pressure"]!, config: Config(), run: run, slot: slot)
        #expect(url.contains("STYLES=&"))
    }

    @Test func cadenceFollowsSpecAndD2Interval() {
        let wms = LayerCatalog.specs["temperature_wms"]!
        #expect(wms.publishCadenceSeconds == 6 * 3600 && wms.publishCadenceSeconds(Config()) == 6 * 3600)
        #expect(LayerCatalog.specs["lightning"]!.publishCadenceSeconds == 300)
        // ICON-D2 specs follow with the ingest (P4); their cadence is taken from the setting
        let d2 = LayerSpec(id: "temperature_d2", title: "t", kind: .forecast, provider: .dwd, wmsLayer: "", capsWorkspace: nil, capsLayer: nil,
                           stepSeconds: 3600, transparent: true, lossless: true, webpQuality: 100, completeness: .none, availabilityDelay: 0,
                           legend: nil, modificationNotice: "", tempVariant: .d2)
        var cfg = Config()
        #expect(d2.publishCadenceSeconds(cfg) == 6 * 3600)
        cfg.temp.d2RunIntervalHours = 3
        #expect(d2.publishCadenceSeconds(cfg) == 3 * 3600)
    }

    @Test func forecastHoursGive49Slots() {
        #expect(Config().forecastHours(for: LayerCatalog.specs["temperature_wms"]!) == 48)
    }
}
