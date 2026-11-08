import Foundation
@testable import RadarCore

/// Writes small GRIB2 messages with the layout DWD uses for ICON-D2 (sections 1-3-4-5-6-7, 16 bit simple packing, bitmap),
/// to test the decoder without real files. Values are `nil` where the bitmap has a hole.
struct GribBuilder {
    var ni = 4, nj = 3
    var lat1 = 50.0, lon1 = 8.0, dLat = 0.02, dLon = 0.02
    var scan: UInt8 = 64
    var gridTemplate: UInt16 = 0
    var packingTemplate: UInt16 = 0
    var bits = 16
    var e = -7, d = 0
    var category: UInt8 = 0, number: UInt8 = 0
    var reference = (2026, 11, 8, 6, 0, 0)
    var unit: UInt8 = 0
    var forecast: UInt32 = 720
    var useBitmap = true
    var truncate = 0

    private func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * (n - 1 - $0))) } }
    private func section(_ number: UInt8, _ body: [UInt8]) -> [UInt8] { be(UInt64(body.count + 5), 4) + [number] + body }
    private func sm16(_ v: Int) -> [UInt8] { be(UInt64(v < 0 ? 0x8000 | -v : v), 2) }

    func build(_ values: [Float?]) -> [UInt8] {
        precondition(values.count == ni * nj)
        let present = values.compactMap { $0 }
        let r = present.min() ?? 0
        let scale = Float(pow(2.0, Double(e))), div = Float(pow(10.0, Double(d)))
        let xs = present.map { UInt32(((($0 * div) - r) / scale).rounded()) }
        var packed = [UInt8](); var acc: UInt64 = 0; var nacc = 0
        for x in xs {
            acc = acc << UInt64(bits) | UInt64(x); nacc += bits
            while nacc >= 8 { packed.append(UInt8(truncatingIfNeeded: acc >> UInt64(nacc - 8))); nacc -= 8; acc &= (1 << UInt64(nacc)) - 1 }
        }
        if nacc > 0 { packed.append(UInt8(truncatingIfNeeded: acc << UInt64(8 - nacc))) }
        var bitmap = [UInt8](repeating: 0, count: (values.count + 7) / 8)
        for (i, v) in values.enumerated() where v != nil { bitmap[i >> 3] |= 0x80 >> UInt8(i & 7) }
        let (y, mo, da, h, mi, s) = reference
        let s1 = section(1, be(78, 2) + be(0, 2) + [19, 1, 1] + be(UInt64(y), 2) + [UInt8(mo), UInt8(da), UInt8(h), UInt8(mi), UInt8(s), 0, 1])
        let s2 = section(2, [UInt8](repeating: 0, count: 22))
        let lonStored = UInt32(bitPattern: Int32((lon1 < 0 ? lon1 + 360 : lon1) * 1e6))
        let lat2 = lat1 + Double(nj - 1) * dLat, lon2 = lon1 + Double(ni - 1) * dLon
        var g3: [UInt8] = [0]
        g3 += be(UInt64(ni * nj), 4)
        g3 += [0, 0]
        g3 += be(UInt64(gridTemplate), 2)
        g3 += [6, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] // shape + 14 radius/axis bytes
        g3 += be(UInt64(ni), 4)
        g3 += be(UInt64(nj), 4)
        g3 += be(0, 4)
        g3 += be(0xFFFF_FFFF, 4)
        let lat1Stored: UInt32 = UInt32(bitPattern: Int32(lat1 * 1e6))
        let lon2Stored: UInt32 = UInt32(bitPattern: Int32((lon2 < 0 ? lon2 + 360 : lon2) * 1e6))
        let lat2Stored: UInt32 = UInt32(bitPattern: Int32(lat2 * 1e6))
        g3 += be(UInt64(lat1Stored), 4)
        g3 += be(UInt64(lonStored), 4)
        g3 += [0x30]
        g3 += be(UInt64(lat2Stored), 4)
        g3 += be(UInt64(lon2Stored), 4)
        g3 += be(UInt64(dLon * 1e6), 4)
        g3 += be(UInt64(dLat * 1e6), 4)
        g3 += [scan]
        let s3 = section(3, g3)
        var g4: [UInt8] = be(0, 2)
        g4 += be(0, 2)
        g4 += [category, number, 2, 0, 0]
        g4 += be(0, 2)
        g4 += [0, unit]
        g4 += be(UInt64(forecast), 4)
        g4 += [103, 0]
        g4 += be(2, 4)
        g4 += [255, 0]
        g4 += be(0, 4)
        let s4 = section(4, g4)
        var g5: [UInt8] = be(UInt64(xs.count), 4)
        g5 += be(UInt64(packingTemplate), 2)
        g5 += be(UInt64(r.bitPattern), 4)
        g5 += sm16(e)
        g5 += sm16(d)
        g5 += [UInt8(bits), 0]
        let s5 = section(5, g5)
        let s6 = section(6, useBitmap ? [0] + bitmap : [255])
        let s7 = section(7, packed)
        var body: [UInt8] = s1
        for part in [s2, s3, s4, s5, s6, s7, Array("7777".utf8)] { body += part }
        let total = 16 + body.count
        var message: [UInt8] = Array("GRIB".utf8)
        message += [0xFF, 0xFF, 0, 2]
        message += be(UInt64(total), 8)
        message += body
        if truncate > 0 { message.removeLast(truncate) }
        return message
    }
}
