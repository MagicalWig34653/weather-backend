import Foundation

/// NOAA Enterprise Rainfall Rate (RRQPE, "RainRate-Blend-INST"), world mosaic from geostationary satellites. Source, file layout and
/// measurements: docs/research/rrqpe-welt.md (branch research/rrqpe-welt), checked 17/18 Nov 2026.
/// Source grid: `width` x `height` cells of `step` degrees, row 0 = 70 N, column 0 = 180 W. The product has `.product`; tests use a coarse grid.
public struct RainRateGrid: Sendable, Equatable {
    public let width: Int, height: Int, step: Double
    public init(width: Int, height: Int, step: Double) { self.width = width; self.height = height; self.step = step }
    public static let product = RainRateGrid(width: 18000, height: 6501, step: 0.02)
}

public enum NoaaRain {
    /// Public S3 bucket (us-east-1), read anonymously over HTTPS. Only for tests: other base URL.
    public static let defaultBaseURL = "https://noaa-enterprise-rainrate-pds.s3.amazonaws.com"
    public static let stepSeconds: TimeInterval = 600
    /// Full version (GLB-5) appears 15 to 27 minutes after the start of the 10-minute window (measured on 17 Nov 2026).
    public static let availabilityDelay: TimeInterval = 900
    /// Stage with all five satellites; a slot younger than `waitForFullSeconds` waits for it, an older one takes the best stage there is.
    public static let fullStage = 5
    public static let waitForFullSeconds: TimeInterval = 1800
    /// libwebp effort as for OPERA (method 4 instead of 6).
    static let webpMethod: Int32 = 4
    /// Real file: 5.2 to 5.4 MB. Anything far larger is not the product.
    public static let maxFileBytes = 16_000_000
    public static let attribution = "Quelle: NOAA, von Showers verarbeitet; aus Satellitendaten geschätzt, ungenauer"
    public static let modificationNotice = "Datenbasis: NOAA Enterprise Rainfall Rate (RRQPE, Blend), Daten umprojiziert, gefiltert und eingefärbt; aus Satellitendaten geschätzt"

    /// Fixed layout of the product (checked against the file of 17 Nov 2026): 0.02 degree grid, row 0 = 70 N, column 0 = 180 W.
    static let topLatitude = 70.0, leftLongitude = -180.0
    static let fillValue = -9990
    /// Web-Mercator extent of the whole product (180 W to 180 E, 60 S to 70 N), whole metres like `europeBBox`: the manifest prints it, so it must
    /// not depend on the platform's libm (computed values differed in the last digit between macOS and Linux).
    public static let worldBBox: [Double] = [-20037508.0, -8399738.0, 20037508.0, 11068716.0]

    static func hourPrefix(slot: Date) -> String {
        let id = TimeUtil.toID(slot)  // 20261117T1630Z
        let y = id.prefix(4), m = id.dropFirst(4).prefix(2), d = id.dropFirst(6).prefix(2), h = id.dropFirst(9).prefix(2)
        return "BLEND/RainRate-Blend-INST/\(y)/\(m)/\(d)/\(h)/"
    }

    /// Listing of the hour that holds the slot (a few KB of XML); the file name carries the creation time, so it cannot be built.
    public static func listURL(base: String, slot: Date) -> String {
        let root = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return "\(root)/?list-type=2&prefix=\(hourPrefix(slot: slot))"
    }

    /// Object keys of the slot with their stage (`GLB-2` to `GLB-5`), highest stage first. `s<YYYYMMDDhhmm>` in the file name is the slot start.
    public static func candidates(listing: [UInt8], slot: Date) -> [(key: String, stage: Int)] {
        let text = String(decoding: listing, as: UTF8.self)
        let id = TimeUtil.toID(slot)
        let stamp = "_s" + id.prefix(8) + id.dropFirst(9).prefix(4)
        var out: [(key: String, stage: Int)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<Key>"), let close = rest.range(of: "</Key>", range: open.upperBound..<rest.endIndex) {
            let key = String(rest[open.upperBound..<close.lowerBound])
            rest = rest[close.upperBound...]
            guard key.hasPrefix(hourPrefix(slot: slot) + "RRQPE-INST-GLB-"), key.hasSuffix(".nc"), key.contains(stamp) else { continue }
            let afterGLB = key.dropFirst((hourPrefix(slot: slot) + "RRQPE-INST-GLB-").count)
            guard let stage = afterGLB.first.flatMap({ Int(String($0)) }), afterGLB.dropFirst().first == "_" else { continue }
            out.append((key, stage))
        }
        return out.sorted { $0.stage > $1.stage }
    }

    public static func fileURL(base: String, key: String) -> String {
        base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + key
    }
}

/// Reader for exactly the NetCDF-4 layout of the product (`RRQPE` int16 and `DQF` int8, 6501 x 18000, deflate chunks, `scale_factor` 0.1,
/// `_FillValue` -9990). Another layout throws `Hdf5Error.unsupported`; the reader does not guess.
public enum RainRateNetCDF {
    /// Pixel of the target raster, after reading: highest rate in the window (units of 0.1 mm/h; -1 = no data) and degraded flag.
    public struct Reduced: Sendable {
        public let width: Int, height: Int
        public let rate: [Int16]
        public let degraded: [Bool]
        public let validCells: Int
    }

    /// Reduces the file in one streaming pass per variable (no full-size array: 117 million cells would be 234 MB).
    public static func reduce(_ bytes: [UInt8], table: WorldLookup) throws -> Reduced {
        let f = try H5File(bytes)
        let root = try f.rootHeader()
        let rrHeader = try f.group(root, "RRQPE"), dqHeader = try f.group(root, "DQF")
        let attrs = try f.attributes(rrHeader)
        if let scale = try attrs["scale_factor"]?.double(), abs(scale - 0.1) > 1e-4 { throw Hdf5Error.unsupported("scale_factor \(scale)") }
        if let offset = try attrs["add_offset"]?.double(), offset != 0 { throw Hdf5Error.unsupported("add_offset \(offset)") }
        if let fill = try attrs["_FillValue"]?.double(), Int(fill) != NoaaRain.fillValue { throw Hdf5Error.unsupported("_FillValue \(fill)") }
        let grid = table.grid, maxCells = grid.width * grid.height
        let rr = try f.dataset(rrHeader, maxCells: maxCells), dq = try f.dataset(dqHeader, maxCells: maxCells)
        guard rr.width == grid.width, rr.height == grid.height, rr.classID == 0, rr.elementSize == 2, rr.signed,
              dq.width == rr.width, dq.height == rr.height, dq.classID == 0, dq.elementSize == 1 else {
            throw Hdf5Error.unsupported("variables (need RRQPE int16 and DQF int8, \(grid.width) x \(grid.height))")
        }
        let w = table.width, h = table.height
        // pass 1: degraded cells (DQF bit 1) per target pixel
        var degradedCount = [UInt8](repeating: 0, count: w * h)
        try f.forEachChunk(dq) { chunk in
            chunk.raw.withUnsafeBufferPointer { raw in
                degradedCount.withUnsafeMutableBufferPointer { out in
                    for r in 0..<chunk.rows {
                        let rowBase = table.rowMap[chunk.row0 + r] * w
                        let src = r * chunk.chunkCols
                        for c in 0..<chunk.cols where raw[src + c] & 2 != 0 {
                            let i = rowBase + table.colMap[chunk.col0 + c]
                            if out[i] < 255 { out[i] += 1 }
                        }
                    }
                }
            }
        }
        // pass 2: maximum rate per target pixel (negative raw values, the fill value among them, are no data)
        var rate = [Int16](repeating: -1, count: w * h)
        var valid = 0
        try f.forEachChunk(rr) { chunk in
            chunk.raw.withUnsafeBufferPointer { raw in
                rate.withUnsafeMutableBufferPointer { out in
                    for r in 0..<chunk.rows {
                        let rowBase = table.rowMap[chunk.row0 + r] * w
                        let src = r * chunk.chunkCols * 2
                        for c in 0..<chunk.cols {
                            let v = Int16(bitPattern: UInt16(raw[src + 2 * c]) | UInt16(raw[src + 2 * c + 1]) << 8)
                            if v < 0 { continue }
                            valid += 1
                            let i = rowBase + table.colMap[chunk.col0 + c]
                            if v > out[i] { out[i] = v }
                        }
                    }
                }
            }
        }
        var degraded = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let total = table.rowCount[y] * table.colCount[x]
                degraded[y * w + x] = total > 0 && Int(degradedCount[y * w + x]) * 2 > total
            }
        }
        return Reduced(width: w, height: h, rate: rate, degraded: degraded, validCells: valid)
    }
}

/// Mapping of the 0.02 degree source grid to the Web-Mercator target raster. The projection is separable: a column depends only on the
/// longitude, a row only on the latitude, so two small arrays (18000 and 6501 entries) replace a table of the target size. Every target
/// pixel covers at least 3 rows and 8 columns of the source (at 70 N the narrowest), so nothing falls through.
public struct WorldLookup: Sendable {
    public let width: Int, height: Int
    public let grid: RainRateGrid
    let colMap: [Int], rowMap: [Int]
    /// Source columns/rows per target column/row (for the share of degraded cells).
    let colCount: [Int], rowCount: [Int]

    public init(bbox: [Double], width: Int, grid: RainRateGrid = .product) {
        self.grid = grid
        let height = RadarConstants.imageHeight(width: width, bbox: bbox)
        self.width = width; self.height = height
        let r = 6378137.0
        func merc(_ lat: Double) -> Double { r * log(tan(.pi / 4 + lat * .pi / 360)) }
        colMap = (0..<grid.width).map { c in
            let lon = NoaaRain.leftLongitude + Double(c) * grid.step
            let x = (lon * .pi / 180 * r - bbox[0]) / (bbox[2] - bbox[0]) * Double(width)
            return max(0, min(width - 1, Int(x.rounded(.down))))
        }
        rowMap = (0..<grid.height).map { row in
            let lat = NoaaRain.topLatitude - Double(row) * grid.step
            let y = (bbox[3] - merc(lat)) / (bbox[3] - bbox[1]) * Double(height)
            return max(0, min(height - 1, Int(y.rounded(.down))))
        }
        var cc = [Int](repeating: 0, count: width), rc = [Int](repeating: 0, count: height)
        for x in colMap { cc[x] += 1 }
        for y in rowMap { rc[y] += 1 }
        colCount = cc; rowCount = rc
    }

    /// Smallest number of source columns/rows per target column/row (0 = a target line without any source cell).
    public var minimumCells: (cols: Int, rows: Int) { (colCount.min() ?? 0, rowCount.min() ?? 0) }
}

/// Rain-rate palette of `radar_world`: the 15 classes and colours of the DWD radar (app legend `MapLegend.precipitationRadar`), so one legend
/// serves all rain layers. Satellite estimates are less certain than radar: degraded cells (DQF bit 1, mainly north of 60 N) are drawn
/// with reduced opacity. Everything below 0.1 mm/h (the smallest value of the product) and no data stays transparent.
public enum NoaaRainPalette {
    /// Lower edge in units of 0.1 mm/h and RGB of every class.
    public static let classes: [(from: Int16, rgb: (UInt8, UInt8, UInt8))] = [
        (1, (0x33, 0xFF, 0xFF)), (2, (0x1A, 0xCC, 0x9A)), (4, (0x01, 0x99, 0x34)), (10, (0x4D, 0xB3, 0x1B)), (20, (0x99, 0xCC, 0x01)),
        (30, (0xCC, 0xE6, 0x01)), (50, (0xFF, 0xFF, 0x01)), (75, (0xFF, 0xC4, 0x01)), (100, (0xFF, 0x89, 0x01)), (150, (0xFF, 0x45, 0x01)),
        (300, (0xFE, 0x00, 0x00)), (450, (0xE5, 0x00, 0x4C)), (750, (0xCC, 0x00, 0x98)), (1000, (0x66, 0x00, 0xCB)), (1500, (0x00, 0x00, 0xFE)),
    ]
    public static let alpha: UInt8 = 235
    public static let degradedAlpha: UInt8 = 140

    public static func classIndex(_ rate: Int16) -> Int? {
        guard rate >= classes[0].from else { return nil }
        var index = 0
        for (i, c) in classes.enumerated() where rate >= c.from { index = i }
        return index
    }

    public static func image(_ reduced: RainRateNetCDF.Reduced) -> RGBAImage {
        var pixels = [UInt8](repeating: 0, count: reduced.width * reduced.height * 4)
        for i in 0..<reduced.rate.count {
            guard let k = classIndex(reduced.rate[i]) else { continue }
            let c = classes[k].rgb
            pixels[i * 4] = c.0; pixels[i * 4 + 1] = c.1; pixels[i * 4 + 2] = c.2
            pixels[i * 4 + 3] = reduced.degraded[i] ? degradedAlpha : alpha
        }
        return RGBAImage(width: reduced.width, height: reduced.height, pixels: pixels)
    }
}

final class WorldLookupCache: @unchecked Sendable {
    static let shared = WorldLookupCache()
    private let lock = NSLock()
    private var tables: [String: WorldLookup] = [:]

    func lookup(bbox: [Double], width: Int, grid: RainRateGrid) -> WorldLookup {
        let key = "\(bbox)|\(width)|\(grid)"
        lock.lock(); defer { lock.unlock() }
        if let hit = tables[key] { return hit }
        let table = WorldLookup(bbox: bbox, width: width, grid: grid)
        if tables.count >= 4 { tables.removeAll() }
        tables[key] = table
        return table
    }
}

public enum NoaaRainRender {
    /// File bytes to the coloured world image. Throws `ImageError.invalid` when the file is not the expected product.
    public static func image(file: [UInt8], bbox: [Double], width: Int, grid: RainRateGrid = .product, minimumCoverage: Double = 0.2) throws -> RGBAImage {
        guard file.count <= NoaaRain.maxFileBytes else { throw ImageError.invalid("noaa file too large") }
        let table = WorldLookupCache.shared.lookup(bbox: bbox, width: width, grid: grid)
        let mins = table.minimumCells
        guard mins.cols > 0, mins.rows > 0 else { throw ImageError.invalid("noaa: target raster not covered by the source grid") }
        let reduced: RainRateNetCDF.Reduced
        do { reduced = try RainRateNetCDF.reduce(file, table: table) } catch { throw ImageError.invalid(String(describing: error)) }
        // the lowest stages (GLB-2) still have about half of the cells; far fewer is a broken file, not a dry world
        guard Double(reduced.validCells) >= minimumCoverage * Double(grid.width * grid.height) else {
            throw ImageError.invalid("noaa: only \(reduced.validCells) valid cells")
        }
        return NoaaRainPalette.image(reduced)
    }
}
