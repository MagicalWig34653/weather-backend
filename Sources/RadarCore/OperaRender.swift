import Foundation

/// Source addresses and file names of the OPERA (EUMETNET) CIRRUS composite, checked 17 Nov 2026 (docs/research/europa-radar.md, section 7).
public enum Opera {
    /// Main bucket (CloudFerro). On 17 Nov 2026 it held no composites; the backup bucket (ECMWF, 10-day lifecycle) did.
    public static let defaultBaseURL = "https://s3.waw3-1.cloudferro.com/openradar-24h"
    public static let defaultBackupURL = "https://object-store.os-api.cci1.ecmwf.int/openradar-24h-backup"
    /// A composite appears about 4.5 minutes after its nominal time (measured, bucket time stamps).
    public static let availabilityDelay: TimeInterval = 300
    public static let stepSeconds: TimeInterval = 300
    /// libwebp effort: method 6 (default) took 3.9 s per slot in the release build, method 4 is far cheaper (as for ICON-D2).
    static let webpMethod: Int32 = 4
    /// Real file: 4.07 MB. Anything far larger is not the product.
    public static let maxFileBytes = 12_000_000
    /// Rain echoes below this dBZ are noise or no echo (the data set contains values down to -32 dBZ; threshold measured on 17 Nov 2026,
    /// not yet confirmed against the OPERA product sheet).
    public static let defaultNoiseDBZ = 0.126
    /// Credit line of the manifest (CC BY 4.0 requires attribution and a note on changes).
    public static let attribution = "Radardaten Europa: EUMETNET OPERA (CIRRUS), CC BY 4.0, Quelle: MeteoGate; umprojiziert und eingefärbt."
    public static let modificationNotice = "Datenbasis: EUMETNET OPERA (CIRRUS, DBZH), Daten umprojiziert, gefiltert und eingefärbt"

    /// `YYYY/MM/DD/OPERA/COMP/OPERA@YYYYMMDDTHHMM@0@DBZH.h5` below the bucket URL.
    public static func path(slot: Date) -> String {
        let id = TimeUtil.toID(slot)  // 20261117T1630Z
        let day = String(id.prefix(8))
        let hm = String(id.dropFirst(9).prefix(4))
        let y = day.prefix(4), m = day.dropFirst(4).prefix(2), d = day.dropFirst(6)
        return "\(y)/\(m)/\(d)/OPERA/COMP/OPERA@\(day)T\(hm)@0@DBZH.h5"
    }

    /// Main bucket first, backup second; empty URLs are skipped.
    public static func urls(slot: Date, primary: String, backup: String) -> [String] {
        [primary, backup].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }.filter { !$0.isEmpty }.map { "\($0)/\(path(slot: slot))" }
    }
}

/// Lambert azimuthal equal-area projection of the OPERA composite (ellipsoidal, Snyder 1987, eq. 24-2 to 24-27) and the cached lookup
/// table from the Web-Mercator target raster to source cells.
public struct LAEA: Sendable {
    public let lat0: Double, lon0: Double, falseEasting: Double, falseNorthing: Double
    private let e: Double, e2: Double, a: Double, qp: Double, rq: Double, sinB0: Double, cosB0: Double, d: Double

    /// `+proj=laea +lat_0=55 +lon_0=10 +x_0=1950000 +y_0=-2100000 +ellps=WGS84`; other definitions throw (the reader does not guess).
    public static func parse(_ projdef: String) throws -> LAEA {
        var values: [String: Double] = [:]
        var proj = "", ellps = ""
        for token in projdef.split(separator: " ") {
            let kv = token.drop(while: { $0 == "+" }).split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "proj" { proj = kv[1] } else if kv[0] == "ellps" { ellps = kv[1] } else if let v = Double(kv[1]) { values[kv[0]] = v }
        }
        guard proj == "laea", ellps == "WGS84", let lat0 = values["lat_0"], let lon0 = values["lon_0"] else {
            throw ImageError.invalid("unexpected projection '\(projdef)'")
        }
        return LAEA(lat0: lat0, lon0: lon0, falseEasting: values["x_0"] ?? 0, falseNorthing: values["y_0"] ?? 0)
    }

    public init(lat0: Double, lon0: Double, falseEasting: Double, falseNorthing: Double) {
        self.lat0 = lat0; self.lon0 = lon0; self.falseEasting = falseEasting; self.falseNorthing = falseNorthing
        a = 6378137.0
        let f = 1 / 298.257223563
        e2 = f * (2 - f); e = e2.squareRoot()
        qp = LAEA.q(90 * .pi / 180, e: e, e2: e2)
        rq = a * (qp / 2).squareRoot()
        let phi0 = lat0 * .pi / 180
        let b0 = asin(LAEA.q(phi0, e: e, e2: e2) / qp)
        sinB0 = sin(b0); cosB0 = cos(b0)
        d = a * (cos(phi0) / (1 - e2 * sin(phi0) * sin(phi0)).squareRoot()) / (rq * cosB0)
    }

    private static func q(_ phi: Double, e: Double, e2: Double) -> Double {
        let s = sin(phi)
        return (1 - e2) * (s / (1 - e2 * s * s) - (1 / (2 * e)) * log((1 - e * s) / (1 + e * s)))
    }

    /// Projected metres (x east, y north, including the false easting/northing).
    public func forward(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let phi = lat * .pi / 180, dl = (lon - lon0) * .pi / 180
        let beta = asin(max(-1, min(1, LAEA.q(phi, e: e, e2: e2) / qp)))
        let sinB = sin(beta), cosB = cos(beta)
        let denom = 1 + sinB0 * sinB + cosB0 * cosB * cos(dl)
        let bb = rq * (2 / max(denom, 1e-12)).squareRoot()
        return (falseEasting + bb * d * cosB * sin(dl), falseNorthing + (bb / d) * (cosB0 * sinB - sinB0 * cosB * cos(dl)))
    }
}

/// Mapping of every pixel of the target raster to a window of source cells. Built once per (grid, bbox, width) and cached:
/// per target pixel the centre cell (row-major index, `-1` = outside the composite) and the half edge of the window in cells.
public struct OperaLookup: Sendable {
    public let width: Int, height: Int
    public let sourceWidth: Int, sourceHeight: Int
    let index: [Int32]
    let half: [UInt8]

    /// - Parameters:
    ///   - xscale/yscale: metres per source cell; the origin is the top left corner (row 0 = north).
    public init(laea: LAEA, sourceWidth: Int, sourceHeight: Int, xscale: Double, yscale: Double, bbox: [Double], width: Int) {
        let height = RadarConstants.imageHeight(width: width, bbox: bbox)
        self.width = width; self.height = height; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        var index = [Int32](repeating: -1, count: width * height)
        var half = [UInt8](repeating: 0, count: width * height)
        let pixelMetres = (bbox[2] - bbox[0]) / Double(width)
        for y in 0..<height {
            let my = bbox[3] - (Double(y) + 0.5) / Double(height) * (bbox[3] - bbox[1])
            let lat = RadarConstants.mercatorToWGS84(x: 0, y: my).lat
            // Mercator stretches by 1/cos(lat): one target pixel covers this many metres on the ground, i.e. source cells.
            let cells = pixelMetres * cos(lat * .pi / 180) / min(xscale, yscale)
            let h = UInt8(max(0, min(8, Int(cells / 2 + 0.25))))
            for x in 0..<width {
                let mx = bbox[0] + (Double(x) + 0.5) / Double(width) * (bbox[2] - bbox[0])
                let lon = mx / 6378137.0 * 180 / .pi
                let p = laea.forward(lat: lat, lon: lon)
                let col = Int((p.x / xscale).rounded(.down)), row = Int((-p.y / yscale).rounded(.down))
                guard col >= 0, col < sourceWidth, row >= 0, row < sourceHeight else { continue }
                index[y * width + x] = Int32(row * sourceWidth + col)
                half[y * width + x] = h
            }
        }
        self.index = index; self.half = half
    }

    /// Fraction of target pixels inside the composite grid.
    public var coverage: Double { Double(index.reduce(0) { $0 + ($1 >= 0 ? 1 : 0) }) / Double(max(1, index.count)) }

    /// Source cell (column, row) of a target pixel; nil outside the composite.
    public func cell(x: Int, y: Int) -> (col: Int, row: Int)? {
        let i = Int(index[y * width + x])
        return i < 0 ? nil : (i % sourceWidth, i / sourceWidth)
    }

    /// Reduces the source to the target raster. Max filter over the window (a downsampled cell keeps its strongest echo); `NaN` =
    /// outside the coverage or no data in the whole window, `-inf` = measured, no echo.
    public func resample(_ source: [Float]) -> [Float] {
        var out = [Float](repeating: .nan, count: width * height)
        source.withUnsafeBufferPointer { s in
            for i in 0..<out.count {
                let c = Int(index[i])
                if c < 0 { continue }
                let h = Int(half[i])
                if h == 0 { out[i] = s[c]; continue }
                let row = c / sourceWidth, col = c % sourceWidth
                var best = Float.nan
                for r in max(0, row - h)...min(sourceHeight - 1, row + h) {
                    let base = r * sourceWidth
                    for cc in max(0, col - h)...min(sourceWidth - 1, col + h) {
                        let v = s[base + cc]
                        if v.isNaN { continue }
                        if best.isNaN || v > best { best = v }
                    }
                }
                out[i] = best
            }
        }
        return out
    }
}

/// dBZ palette of the `radar_eu` layer. Values below the noise threshold stay transparent.
public enum OperaPalette {
    /// Lower edge (dBZ) and RGBA of every class; the first class starts at the noise threshold.
    public static let classes: [(from: Float, rgba: (UInt8, UInt8, UInt8, UInt8))] = [
        (-.infinity, (156, 201, 255, 150)),
        (10, (79, 147, 242, 210)),
        (15, (43, 107, 224, 235)),
        (20, (31, 179, 90, 245)),
        (25, (122, 209, 58, 250)),
        (30, (232, 224, 42, 255)),
        (35, (245, 166, 35, 255)),
        (40, (239, 107, 30, 255)),
        (45, (224, 43, 43, 255)),
        (50, (179, 18, 110, 255)),
        (55, (122, 31, 162, 255)),
        (60, (242, 230, 255, 255)),
    ]

    /// Class index of a value, `nil` = transparent (no data, no echo, below the threshold).
    public static func classIndex(_ dbz: Float, threshold: Float) -> Int? {
        guard !dbz.isNaN, dbz >= threshold else { return nil }
        var index = 0
        for (i, c) in classes.enumerated() where dbz >= c.from { index = i }
        return index
    }

    public static func image(_ values: [Float], width: Int, height: Int, threshold: Float) -> RGBAImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<values.count {
            guard let k = classIndex(values[i], threshold: threshold) else { continue }
            let c = classes[k].rgba
            pixels[i * 4] = c.0; pixels[i * 4 + 1] = c.1; pixels[i * 4 + 2] = c.2; pixels[i * 4 + 3] = c.3
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}

/// Cache of lookup tables (one per grid; the table of Europe 2048 px has about 4.4 million entries, 22 MB).
final class OperaLookupCache: @unchecked Sendable {
    static let shared = OperaLookupCache()
    private let lock = NSLock()
    private var tables: [String: OperaLookup] = [:]

    func lookup(laea: LAEA, projdef: String, sourceWidth: Int, sourceHeight: Int, xscale: Double, yscale: Double, bbox: [Double], width: Int) -> OperaLookup {
        let key = "\(projdef)|\(sourceWidth)x\(sourceHeight)|\(xscale)x\(yscale)|\(bbox)|\(width)"
        lock.lock(); defer { lock.unlock() }
        if let hit = tables[key] { return hit }
        let table = OperaLookup(laea: laea, sourceWidth: sourceWidth, sourceHeight: sourceHeight, xscale: xscale, yscale: yscale, bbox: bbox, width: width)
        if tables.count >= 4 { tables.removeAll() }
        tables[key] = table
        return table
    }
}

public enum OperaRender {
    /// File bytes to the coloured Europe image. Throws `ImageError.invalid` when the file is not the expected product.
    public static func image(file: [UInt8], bbox: [Double], width: Int, noiseDBZ: Double, minimumCoverage: Double = 0.05) throws -> RGBAImage {
        guard file.count <= Opera.maxFileBytes else { throw ImageError.invalid("opera file too large") }
        let composite: OdimComposite
        do { composite = try OdimHDF5.read(file) } catch { throw ImageError.invalid(String(describing: error)) }
        guard composite.quantity == "DBZH" else { throw ImageError.invalid("opera quantity \(composite.quantity)") }
        let laea = try LAEA.parse(composite.projdef)
        let table = OperaLookupCache.shared.lookup(laea: laea, projdef: composite.projdef, sourceWidth: composite.width, sourceHeight: composite.height,
                                                    xscale: composite.xscale, yscale: composite.yscale, bbox: bbox, width: width)
        // a composite without any measured cell (all nodata) is a broken product, not a dry day
        let measured = composite.values.reduce(0) { $0 + ($1.isNaN ? 0 : 1) }
        guard Double(measured) >= minimumCoverage * Double(composite.values.count) else { throw ImageError.invalid("opera: only \(measured) measured cells") }
        let resampled = table.resample(composite.values)
        return OperaPalette.image(resampled, width: table.width, height: table.height, threshold: Float(noiseDBZ))
    }
}
