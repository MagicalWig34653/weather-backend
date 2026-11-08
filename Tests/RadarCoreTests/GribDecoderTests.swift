import Foundation
import Testing
@testable import RadarCore

private let tiny = GribGrid(ni: 4, nj: 3, dLat: 0.02, dLon: 0.02)

@Suite("GRIB2 decoder")
struct GribDecoderTests {
    private func values() -> [Float?] {
        var out: [Float?] = []
        for i in 0..<12 { out.append(i == 5 || i == 11 ? nil : Float(270) + Float(i) * 0.5) }
        return out
    }

    @Test func decodesBitmapValuesAndHeader() throws {
        let field = try GribDecoder.decode(GribBuilder().build(values()), expecting: tiny)
        #expect(field.ni == 4 && field.nj == 3 && field.scanMode == 64)
        #expect(abs(field.lat1 - 50) < 1e-9 && abs(field.lon1 - 8) < 1e-9 && abs(field.dLat - 0.02) < 1e-9)
        #expect(field.referenceTime == TimeUtil.fromID("20261108T0600Z") && field.forecastMinutes == 720)
        #expect(field.category == 0 && field.number == 0)
        #expect(field.validCount == 10)
        for (i, v) in values().enumerated() {
            if let v { #expect(abs(field.values[i] - v) < 0.01) } else { #expect(field.values[i].isNaN) }
        }
    }

    @Test func westernLongitudeIsNormalised() throws {
        var b = GribBuilder(); b.lon1 = -3.94
        let field = try GribDecoder.decode(b.build(values()), expecting: tiny)
        #expect(abs(field.lon1 + 3.94) < 1e-6)
    }

    @Test func forecastTimeInHoursAndScaleFactors() throws {
        var b = GribBuilder(); b.unit = 1; b.forecast = 5; b.d = 1; b.e = -4
        let field = try GribDecoder.decode(b.build((0..<12).map { Float(27 + $0) }), expecting: tiny)
        #expect(field.forecastMinutes == 300)
        #expect(abs(field.values[3] - 30) < 0.1 && abs(field.values[11] - 38) < 0.1)
    }

    @Test func withoutBitmapAllCellsCount() throws {
        var b = GribBuilder(); b.useBitmap = false
        let field = try GribDecoder.decode(b.build((0..<12).map { Float(280 + $0) }), expecting: tiny)
        #expect(field.validCount == 12 && abs(field.values[11] - 291) < 0.01)
    }

    @Test func otherBitWidths() throws {
        for bits in [8, 12, 24] {
            var b = GribBuilder(); b.bits = bits; b.e = bits == 8 ? 0 : -3
            let step: Float = bits == 8 ? 10 : 1.5
            let source: [Float?] = (0..<12).map { Float($0) * step }
            let field = try GribDecoder.decode(b.build(source), expecting: tiny)
            for i in 0..<12 { #expect(abs(field.values[i] - source[i]!) < 0.2) }
        }
    }

    @Test func rejectsUnknownTemplatesAndGrids() {
        var b = GribBuilder(); b.packingTemplate = 42
        #expect(throws: GribError.unsupported("packing template 5.42")) { try GribDecoder.decode(b.build(values()), expecting: tiny) }
        b = GribBuilder(); b.gridTemplate = 101
        #expect(throws: GribError.unsupported("grid template 3.101")) { try GribDecoder.decode(b.build(values()), expecting: tiny) }
        #expect(throws: GribError.unsupported("grid 4 x 3")) { try GribDecoder.decode(GribBuilder().build(values())) }  // default: ICON-D2 grid
        b = GribBuilder(); b.scan = 0
        #expect(throws: GribError.unsupported("scan mode 0")) { try GribDecoder.decode(b.build(values()), expecting: tiny) }
        b = GribBuilder(); b.dLon = 0.0625
        #expect(throws: GribError.self) { try GribDecoder.decode(b.build(values()), expecting: tiny) }
        b = GribBuilder(); b.unit = 11
        #expect(throws: GribError.self) { try GribDecoder.decode(b.build(values()), expecting: tiny) }
    }

    @Test func rejectsTruncatedAndForeignData() {
        var b = GribBuilder(); b.truncate = 30
        #expect(throws: GribError.self) { try GribDecoder.decode(b.build(values()), expecting: tiny) }
        let whole = GribBuilder().build(values())
        for cut in [0, 3, 16, 40, whole.count / 2] {
            #expect(throws: GribError.self) { try GribDecoder.decode(Array(whole.prefix(cut)), expecting: tiny) }
        }
        #expect(throws: GribError.self) { try GribDecoder.decode(Array("<html>404 not found</html>".utf8), expecting: tiny) }
        var edition1 = whole; edition1[7] = 1
        #expect(throws: GribError.unsupported("GRIB edition 1")) { try GribDecoder.decode(edition1, expecting: tiny) }
    }

    /// `Fixtures/grib/icon-d2-t2m-crop-12x8.grib2` is a 12 x 8 window cut out of a real DWD file (t_2m, run 2026-11-08 06 UTC, +12 h,
    /// columns 176..187, rows 0..7 at the southern edge, so the bitmap has holes) with tools/make_grib_fixture.py; real header layout
    /// and packing constants. Expected values come from an independent Python decode of the full original file.
    @Test func realCutOutFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/grib/icon-d2-t2m-crop-12x8.grib2")
        let field = try GribDecoder.decode([UInt8](try Data(contentsOf: url)), expecting: GribGrid(ni: 12, nj: 8, dLat: 0.02, dLon: 0.02))
        #expect(field.referenceTime == TimeUtil.fromID("20261108T0600Z") && field.forecastMinutes == 720 && field.category == 0 && field.number == 0)
        #expect(abs(field.lat1 - 43.18) < 1e-6 && abs(field.lon1 - (-3.94 + 176 * 0.02)) < 1e-6)
        #expect(field.validCount == 68)
        let holes: Set<Int> = [0, 1, 2, 3, 4, 12, 13, 14, 15, 16, 24, 25, 26, 27, 36, 37, 38, 39, 48, 49, 50, 60, 61, 72, 73, 84, 85, 86]
        for i in 0..<96 { #expect(field.values[i].isNaN == holes.contains(i), "cell \(i)") }
        #expect(abs(field.values[5] - 287.126) < 0.001 && abs(field.values[8] - 285.987) < 0.001 && abs(field.values[17] - 287.447) < 0.001)
    }

    /// Real downloaded files (not checked in, ~1.6 MB each): ICON_D2_SAMPLE = directory with the unpacked `.grib2` files.
    @Test func realFileMatchesReferenceRange() throws {
        guard let dir = ProcessInfo.processInfo.environment["ICON_D2_SAMPLE"] else { return }
        let ref: [(String, Float, Float, Int)] = [  // file part, min, max, forecast minutes (values from the independent Python decode, 8 Nov 2026)
            ("012_2d_t_2m", 259.895, 289.947, 720), ("012_2d_td_2m", 249.546, 288.435, 720), ("012_2d_relhum_2m", 29.431, 100.001, 720),
            ("000_2d_t_2m", 260.353, 289.252, 0), ("048_2d_t_2m", 267.224, 292.571, 2880)]
        for (part, lo, hi, minutes) in ref {
            let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("icon-d2_germany_regular-lat-lon_single-level_2026110806_\(part).grib2")))
            let f = try GribDecoder.decode(bytes)
            let valid = f.values.filter { !$0.isNaN }
            #expect(f.validCount == 754_862 && f.values.count == 906_390 && f.forecastMinutes == minutes)
            #expect(abs(valid.min()! - lo) < 0.002 && abs(valid.max()! - hi) < 0.002, "\(part)")
            #expect(abs(f.lat1 - 43.18) < 1e-6 && abs(f.lon1 + 3.94) < 1e-6)
        }
    }
}
