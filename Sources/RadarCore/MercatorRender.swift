import Foundation

/// Projects a regular lat/lon GRIB field onto a Web-Mercator image (EPSG:3857, the extent of a layer) and colours it with a
/// stepped `TempScale`. Cells without a value (bitmap holes, outside the model domain) stay transparent: no value instead of a wrong one.
public enum MercatorRender {
    /// Checks that a decoded file is the expected variable with plausible values and enough valid cells; throws `ImageError.invalid`
    /// otherwise (the run is then dropped, see `Icon2DIngestor`). Expected for ICON-D2: 754 862 of 906 390 cells valid (83 %).
    public static func validate(_ field: GribField, kind: TempKind, minimumValidFraction: Double = 0.5) throws {
        guard field.category == kind.parameter.0, field.number == kind.parameter.1 else {
            throw ImageError.invalid("grib parameter \(field.category)/\(field.number) is not \(kind.variable)")
        }
        var valid = 0
        var lo = Double.infinity, hi = -Double.infinity
        for raw in field.values where !raw.isNaN {
            valid += 1
            let v = kind.convert(raw)
            if v < lo { lo = v }; if v > hi { hi = v }
        }
        guard Double(valid) >= minimumValidFraction * Double(field.values.count) else { throw ImageError.invalid("grib: only \(valid) valid cells") }
        guard kind.plausible.contains(lo), kind.plausible.contains(hi) else { throw ImageError.invalid("grib: values out of range (\(lo) ... \(hi))") }
    }

    /// - Parameters:
    ///   - bbox: image extent in EPSG:3857 (xmin, ymin, xmax, ymax).
    ///   - width: image width in pixels; the height follows from `bbox` like for every layer.
    public static func image(field: GribField, kind: TempKind, scale: TempScale, bbox: [Double], width: Int) -> RGBAImage {
        let height = RadarConstants.imageHeight(width: width, bbox: bbox)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ni = field.ni, nj = field.nj
        // per column: grid x position; per row: grid y position (scan mode 64: row 0 = southernmost)
        var colIndex = [Int32](repeating: 0, count: width), colFrac = [Float](repeating: 0, count: width)
        var colInside = [Bool](repeating: false, count: width)
        for x in 0..<width {
            let mx = bbox[0] + (Double(x) + 0.5) / Double(width) * (bbox[2] - bbox[0])
            let lon = mx / 6378137.0 * 180 / .pi
            let fx = (lon - field.lon1) / field.dLon
            colInside[x] = fx >= 0 && fx <= Double(ni - 1)
            if colInside[x] { let i = min(Int(fx), ni - 2); colIndex[x] = Int32(i); colFrac[x] = Float(fx - Double(i)) }
        }
        let bandRGB = (0..<scale.bandCount).map { scale.rgb(band: $0) }
        let k = Float(273.15)
        let isRH = kind == .relhumPercent
        field.values.withUnsafeBufferPointer { v in
            for y in 0..<height {
                let my = bbox[3] - (Double(y) + 0.5) / Double(height) * (bbox[3] - bbox[1])
                let lat = RadarConstants.mercatorToWGS84(x: 0, y: my).lat
                let fy = (lat - field.lat1) / field.dLat
                guard fy >= 0, fy <= Double(nj - 1) else { continue }
                let j = min(Int(fy), nj - 2), ty = Float(fy - Double(j))
                let row0 = j * ni, row1 = (j + 1) * ni
                for x in 0..<width where colInside[x] {
                    let i = Int(colIndex[x]), tx = colFrac[x]
                    let a = v[row0 + i], b = v[row0 + i + 1], c = v[row1 + i], d = v[row1 + i + 1]
                    // the nearest cell decides whether there is a value; valid neighbours are blended (no dilution by holes)
                    let nearest = ty < 0.5 ? (tx < 0.5 ? a : b) : (tx < 0.5 ? c : d)
                    if nearest.isNaN { continue }
                    var sum: Float = 0, weight: Float = 0
                    if !a.isNaN { let w = (1 - tx) * (1 - ty); sum += a * w; weight += w }
                    if !b.isNaN { let w = tx * (1 - ty); sum += b * w; weight += w }
                    if !c.isNaN { let w = (1 - tx) * ty; sum += c * w; weight += w }
                    if !d.isNaN { let w = tx * ty; sum += d * w; weight += w }
                    let raw = sum / weight
                    let value = isRH ? Double(raw) : Double(raw - k)
                    let (r, g, bl) = bandRGB[scale.bandIndex(value)]
                    let o = (y * width + x) * 4
                    pixels[o] = r; pixels[o + 1] = g; pixels[o + 2] = bl; pixels[o + 3] = 255
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}
