import Foundation
import Testing
@testable import RadarCore

@Suite("ICON-D2 colour scales")
struct TempScaleTests {
    private func contract() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/scales/scales-v1.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["scales"] as? [[String: Any]])
    }

    @Test func swiftTableEqualsJsonContract() throws {
        let scales = try contract()
        #expect(scales.count == TempScale.table.count && scales.count == 3)
        for json in scales {
            let id = try #require(json["id"] as? String)
            let scale = try #require(TempScale.load(id: id))
            #expect(scale.unit == json["unit"] as? String)
            #expect(scale.min == (json["min"] as? NSNumber)?.doubleValue && scale.max == (json["max"] as? NSNumber)?.doubleValue)
            #expect(scale.step == (json["step"] as? NSNumber)?.doubleValue && scale.labelEvery == json["label_every"] as? Int)
            let bands = try #require(json["bands"] as? [[String: Any]])
            #expect(bands.count == scale.bandCount && Double(scale.bandCount) * scale.step == scale.max - scale.min)
            for (i, band) in bands.enumerated() {
                #expect((band["from"] as? NSNumber)?.doubleValue == scale.min + Double(i) * scale.step)
                let hex = String((band["hex"] as? String ?? "").dropFirst())
                #expect(UInt32(hex, radix: 16) == scale.bandColors[i], "\(id) band \(i)")
            }
        }
        for kind in [TempKind.temperatureC, .dewpointC, .relhumPercent] { #expect(TempScale.load(id: kind.scaleID) != nil) }
        #expect(TempScale.load(id: "nope") == nil)
    }

    @Test func bandEdgesRoundingAndClamping() throws {
        let t = try #require(TempScale.load(id: "t2m-d2-v1"))
        #expect(t.bandIndex(0) == 30 && t.bandIndex(-0.01) == 29 && t.bandIndex(0.999) == 30 && t.bandIndex(1) == 31)
        #expect(t.bandIndex(-30) == 0 && t.bandIndex(-80) == 0 && t.bandIndex(39.9) == 69 && t.bandIndex(40) == 69 && t.bandIndex(99) == 69)
        // 273.15 K as float is 273.14999 K: still band "0 to 1 degrees C"
        #expect(t.bandIndex(TempKind.temperatureC.convert(273.15)) == 30)
        let rh = try #require(TempScale.load(id: "rh-d2-v1"))
        #expect(rh.bandIndex(0) == 0 && rh.bandIndex(4.99) == 0 && rh.bandIndex(5) == 1 && rh.bandIndex(100) == 19 && rh.bandIndex(100.001) == 19)
        let td = try #require(TempScale.load(id: "td-d2-v1"))
        #expect(td.bandIndex(-20) == 0 && td.bandIndex(24) == 43 && td.bandIndex(-19.5) == 0 && td.bandIndex(-18.9) == 1)
    }

    @Test func kindsMapVariablesAndUnits() {
        #expect(TempKind.kind(variable: "td_2m") == .dewpointC && TempKind.kind(variable: "relhum_2m") == .relhumPercent && TempKind.kind(variable: "x") == nil)
        #expect(abs(TempKind.dewpointC.convert(273.15)) < 1e-4 && TempKind.relhumPercent.convert(55) == 55)
        #expect(TempKind.temperatureC.plausible.contains(-30) && !TempKind.temperatureC.plausible.contains(80) && !TempKind.relhumPercent.plausible.contains(130))
    }
}
