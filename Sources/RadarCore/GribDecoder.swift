import Foundation

public enum GribError: Error, CustomStringConvertible, Equatable {
    /// Well-formed GRIB2 that this decoder deliberately does not handle (other template, other grid, ...).
    case unsupported(String)
    /// Truncated or inconsistent data.
    case invalid(String)
    public var description: String {
        switch self {
        case .unsupported(let reason): return "grib unsupported: \(reason)"
        case .invalid(let reason): return "grib invalid: \(reason)"
        }
    }
}

/// The grid a field must have (anything else is rejected): ICON-D2 `regular-lat-lon`, 1215 x 746 points, 0.02 degrees, scan mode 64.
public struct GribGrid: Sendable, Equatable {
    public var ni: Int, nj: Int
    public var dLat: Double, dLon: Double
    public var scanMode: UInt8
    public init(ni: Int, nj: Int, dLat: Double, dLon: Double, scanMode: UInt8 = 64) {
        self.ni = ni; self.nj = nj; self.dLat = dLat; self.dLon = dLon; self.scanMode = scanMode
    }
    public static let iconD2 = GribGrid(ni: 1215, nj: 746, dLat: 0.02, dLon: 0.02)
}

/// One decoded GRIB2 field. `values` is row-major as stored (scan mode 64: first row = southernmost, west to east);
/// cells without a value (bitmap) are `Float.nan`.
public struct GribField: Sendable {
    public let ni: Int, nj: Int
    /// First grid point (south-west for scan mode 64); longitude normalised to -180...180.
    public let lat1: Double, lon1: Double
    public let dLat: Double, dLon: Double
    public let scanMode: UInt8
    public let referenceTime: Date
    public let forecastMinutes: Int
    public let category: UInt8, number: UInt8
    public let values: [Float]
    public var validCount: Int { values.reduce(0) { $0 + ($1.isNaN ? 0 : 1) } }
}

/// GRIB2 reader for exactly what DWD publishes for ICON-D2 single-level fields: section 3 template 0 (regular lat/lon),
/// section 4 template 0, section 5 template 0 (simple packing), section 6 bitmap or none, section 7. Everything else throws
/// `GribError.unsupported`; no eccodes needed. Only the first message of the data is read.
public enum GribDecoder {
    public static func decode(_ data: [UInt8], expecting grid: GribGrid? = .iconD2) throws -> GribField {
        guard data.count >= 20, data[0..<4].elementsEqual("GRIB".utf8) else { throw GribError.invalid("no GRIB header") }
        guard data[7] == 2 else { throw GribError.unsupported("GRIB edition \(data[7])") }
        guard data[6] == 0 else { throw GribError.unsupported("discipline \(data[6])") }
        let total = Int(uint(data, 8, 8))
        guard total <= data.count, total >= 20 else { throw GribError.invalid("truncated message (\(data.count) of \(total) bytes)") }
        guard data[total - 4..<total].elementsEqual("7777".utf8) else { throw GribError.invalid("missing end marker") }

        var pos = 16
        var time: Date?
        var grid3: (ni: Int, nj: Int, lat1: Double, lon1: Double, dLat: Double, dLon: Double, scan: UInt8)?
        var product: (category: UInt8, number: UInt8, minutes: Int)?
        var packing: (count: Int, r: Float, e: Int, d: Int, bits: Int)?
        var bitmap: ArraySlice<UInt8>?
        var hasBitmapSection = false, values7: ArraySlice<UInt8>?
        while pos < total - 4 {
            guard pos + 5 <= total - 4 else { throw GribError.invalid("truncated section header") }
            let length = Int(uint(data, pos, 4)), number = data[pos + 4]
            guard length >= 5, pos + length <= total - 4 else { throw GribError.invalid("section \(number) length \(length) out of range") }
            let s = data[pos..<pos + length]  // octet n of the section = data[pos + n - 1]
            func at(_ octet: Int) -> Int { pos + octet - 1 }
            switch number {
            case 1:
                guard length >= 19 else { throw GribError.invalid("section 1 too short") }
                var c = DateComponents(); c.calendar = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")
                c.year = Int(uint(data, at(13), 2)); c.month = Int(data[at(15)]); c.day = Int(data[at(16)])
                c.hour = Int(data[at(17)]); c.minute = Int(data[at(18)]); c.second = Int(data[at(19)])
                guard let date = c.date else { throw GribError.invalid("reference time") }
                time = date
            case 3:
                guard length >= 72 else { throw GribError.invalid("section 3 too short") }
                guard data[at(6)] == 0 else { throw GribError.unsupported("grid definition source \(data[at(6)])") }
                let template = Int(uint(data, at(13), 2))
                guard template == 0 else { throw GribError.unsupported("grid template 3.\(template)") }
                guard uint(data, at(39), 4) == 0, uint(data, at(43), 4) == 0 || uint(data, at(43), 4) == 0xFFFF_FFFF else {
                    throw GribError.unsupported("grid angle units")
                }
                let ni = Int(uint(data, at(31), 4)), nj = Int(uint(data, at(35), 4))
                func micro(_ octet: Int) -> Double { Double(Int32(bitPattern: UInt32(uint(data, at(octet), 4)))) / 1e6 }
                func lon(_ octet: Int) -> Double { let v = micro(octet); return v > 180 ? v - 360 : v }
                let lat1 = micro(47), lon1 = lon(51), lat2 = micro(56)
                let di = Double(uint(data, at(64), 4)) / 1e6, dj = Double(uint(data, at(68), 4)) / 1e6
                grid3 = (ni, nj, lat1, lon1, dj, di, data[at(72)])
                _ = lat2
            case 4:
                guard length >= 22 else { throw GribError.invalid("section 4 too short") }
                let template = Int(uint(data, at(8), 2))
                guard template == 0 else { throw GribError.unsupported("product template 4.\(template)") }
                let unit = data[at(18)], amount = Int(uint(data, at(19), 4))
                switch unit {
                case 0: product = (data[at(10)], data[at(11)], amount)
                case 1: product = (data[at(10)], data[at(11)], amount * 60)
                default: throw GribError.unsupported("forecast time unit \(unit)")
                }
            case 5:
                guard length >= 21 else { throw GribError.invalid("section 5 too short") }
                let template = Int(uint(data, at(10), 2))
                guard template == 0 else { throw GribError.unsupported("packing template 5.\(template)") }
                let r = Float(bitPattern: UInt32(uint(data, at(12), 4)))
                func signMagnitude(_ octet: Int) -> Int {
                    let v = Int(uint(data, at(octet), 2)); return v & 0x8000 != 0 ? -(v & 0x7FFF) : v
                }
                packing = (Int(uint(data, at(6), 4)), r, signMagnitude(16), signMagnitude(18), Int(data[at(20)]))
                guard (0...32).contains(packing!.bits) else { throw GribError.unsupported("bits per value \(packing!.bits)") }
            case 6:
                hasBitmapSection = true
                switch data[at(6)] {
                case 0: bitmap = data[at(7)..<pos + length]
                case 255: bitmap = nil
                default: throw GribError.unsupported("bitmap indicator \(data[at(6)])")
                }
            case 7:
                values7 = data[at(6)..<pos + length]
            case 2: break  // local use, ignored
            case 8: break
            default: throw GribError.unsupported("section \(number)")
            }
            _ = s
            pos += length
        }
        guard let time, let g = grid3, let product, let packing, hasBitmapSection, let values7 else {
            throw GribError.invalid("missing section")
        }
        if let want = grid {
            guard g.ni == want.ni, g.nj == want.nj else { throw GribError.unsupported("grid \(g.ni) x \(g.nj)") }
            guard abs(g.dLat - want.dLat) < 1e-6, abs(g.dLon - want.dLon) < 1e-6 else { throw GribError.unsupported("grid spacing \(g.dLat) x \(g.dLon)") }
            guard g.scan == want.scanMode else { throw GribError.unsupported("scan mode \(g.scan)") }
        }
        guard g.ni > 0, g.nj > 0, g.ni * g.nj <= 20_000_000 else { throw GribError.invalid("grid size") }
        let cells = g.ni * g.nj
        if let bitmap { guard bitmap.count * 8 >= cells else { throw GribError.invalid("bitmap too short") } }
        let count = bitmap == nil ? cells : packing.count
        guard count <= cells, bitmap != nil || count == cells else { throw GribError.invalid("value count \(count) for \(cells) cells") }
        guard values7.count * 8 >= count * packing.bits else { throw GribError.invalid("data section too short") }

        let scale = Float(pow(2.0, Double(packing.e))), divisor = Float(pow(10.0, Double(packing.d)))
        var out = [Float](repeating: .nan, count: cells)
        values7.withUnsafeBufferPointer { src in
            var reader = BitReader(src)
            func next() -> Float {
                if packing.bits == 0 { return packing.r / divisor }
                return (packing.r + Float(reader.read(packing.bits)) * scale) / divisor
            }
            if let bitmap {
                bitmap.withUnsafeBufferPointer { bm in
                    var used = 0
                    for i in 0..<cells where bm[i >> 3] & (0x80 >> UInt8(i & 7)) != 0 && used < count { out[i] = next(); used += 1 }
                }
            } else {
                for i in 0..<cells { out[i] = next() }
            }
        }
        if let bitmap {
            let set = bitmap.withUnsafeBufferPointer { bm in (0..<cells).reduce(0) { $0 + (bm[$1 >> 3] & (0x80 >> UInt8($1 & 7)) != 0 ? 1 : 0) } }
            guard set == count else { throw GribError.invalid("bitmap marks \(set) points, section 5 says \(count)") }
        }
        return GribField(ni: g.ni, nj: g.nj, lat1: g.lat1, lon1: g.lon1, dLat: g.dLat, dLon: g.dLon, scanMode: g.scan,
                         referenceTime: time, forecastMinutes: product.minutes, category: product.category, number: product.number, values: out)
    }

    private static func uint(_ data: [UInt8], _ index: Int, _ bytes: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<bytes { v = v << 8 | UInt64(data[index + i]) }
        return v
    }
}

/// MSB-first bit reader over a section; 16-bit values (ICON-D2) take the byte-pair fast path.
private struct BitReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var bit = 0
    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }
    mutating func read(_ width: Int) -> UInt32 {
        if width == 16, bit & 7 == 0 {
            let i = bit >> 3; bit += 16
            return UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
        }
        var v: UInt64 = 0, left = width
        while left > 0 {
            let i = bit >> 3, offset = bit & 7, take = min(8 - offset, left)
            v = v << UInt64(take) | UInt64((bytes[i] >> UInt8(8 - offset - take)) & UInt8((1 << take) - 1))
            bit += take; left -= take
        }
        return UInt32(v)
    }
}
