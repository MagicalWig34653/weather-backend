import Foundation
import Testing
@testable import RadarCore

/// A 5 x 4 grid at 1 degree spacing, south-west corner 10 E / 50 N, as a field of 280 K with chosen cells.
private func field(_ edit: (inout [Float]) -> Void = { _ in }) -> GribField {
    var values = [Float](repeating: 280, count: 20)
    edit(&values)
    return GribField(ni: 5, nj: 4, lat1: 50, lon1: 10, dLat: 1, dLon: 1, scanMode: 64, referenceTime: Date(timeIntervalSince1970: 0),
                     forecastMinutes: 0, category: 0, number: 0, values: values)
}

/// Mercator extent of lon 10..14 / lat 50..53 (the grid) widened by one degree each side.
private func box(_ lon0: Double, _ lat0: Double, _ lon1: Double, _ lat1: Double) -> [Double] {
    func x(_ lon: Double) -> Double { lon * .pi / 180 * 6378137 }
    func y(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) * 6378137 }
    return [x(lon0), y(lat0), x(lon1), y(lat1)]
}

private func pixel(_ image: RGBAImage, _ x: Int, _ y: Int) -> [UInt8] { Array(image.pixels[(y * image.width + x) * 4..<(y * image.width + x) * 4 + 4]) }

@Suite("Mercator render")
struct MercatorRenderTests {
    let t = TempScale.load(id: "t2m-d2-v1")!

    private func rgba(_ band: Int) -> [UInt8] { let c = t.rgb(band: band); return [c.0, c.1, c.2, 255] }

    @Test func sizeFollowsBBoxAndRadarGrid() {
        let image = MercatorRender.image(field: field(), kind: .temperatureC, scale: t, bbox: RadarConstants.bbox, width: 64)
        #expect(image.width == 64 && image.height == RadarConstants.imageHeight(width: 64) && image.pixels.count == 64 * image.height * 4)
    }

    /// Pixel of an image of `width` over `b` at a geographic position.
    private func at(_ image: RGBAImage, _ b: [Double], _ lon: Double, _ lat: Double) -> [UInt8] {
        let x = (lon * .pi / 180 * 6378137 - b[0]) / (b[2] - b[0]) * Double(image.width)
        let y = (b[3] - log(tan(.pi / 4 + lat * .pi / 360)) * 6378137) / (b[3] - b[1]) * Double(image.height)
        return pixel(image, Int(x), Int(y))
    }

    @Test func centreAndCornersLandOnTheRightGridPoint() {
        // 280 K = 6.85 degrees C everywhere except the corner points (band centres: -9.5, 30.5, 0.5, 10.5 degrees C)
        let f = field { v in v[0] = 263.65; v[4] = 303.65; v[15] = 273.65; v[19] = 283.65 }  // SW, SE, NW, NE
        let b = box(9.9, 49.9, 14.1, 53.1)
        let image = MercatorRender.image(field: f, kind: .temperatureC, scale: t, bbox: b, width: 420)
        #expect(at(image, b, 10.005, 50.005) == rgba(t.bandIndex(-9.5)))   // south-west
        #expect(at(image, b, 13.995, 50.005) == rgba(t.bandIndex(30.5)))   // south-east
        #expect(at(image, b, 10.005, 52.995) == rgba(t.bandIndex(0.5)))    // north-west
        #expect(at(image, b, 13.995, 52.995) == rgba(t.bandIndex(10.5)))   // north-east
        #expect(at(image, b, 12, 51.5) == rgba(t.bandIndex(6.85)))         // centre: flat field
        // outside the grid: transparent
        #expect(pixel(image, 2, 2)[3] == 0 && pixel(image, 417, image.height - 2)[3] == 0)
    }

    @Test func bitmapHolesStayTransparentAndDoNotDiluteNeighbours() {
        let nan = Float.nan
        let f = field { v in v[6] = nan; v[7] = nan; v[11] = nan; v[12] = 293.65 }   // cells (1,1),(2,1),(1,2) holes; (2,2) = 20.5 degrees C
        let b = box(9.5, 49.5, 14.5, 53.5)
        let image = MercatorRender.image(field: f, kind: .temperatureC, scale: t, bbox: b, width: 500)
        #expect(at(image, b, 11.002, 51.002)[3] == 0 && at(image, b, 12.002, 51.002)[3] == 0 && at(image, b, 11.002, 52.002)[3] == 0)
        #expect(at(image, b, 12.002, 52.002) == rgba(t.bandIndex(20.5)))   // valid cell next to holes keeps its value
        #expect(at(image, b, 10.002, 50.002) == rgba(t.bandIndex(6.85)))
    }

    @Test func humidityAndDewpointUseTheirScales() {
        let rh = TempScale.load(id: "rh-d2-v1")!
        let f = GribField(ni: 2, nj: 2, lat1: 50, lon1: 10, dLat: 1, dLon: 1, scanMode: 64, referenceTime: Date(), forecastMinutes: 0,
                          category: 1, number: 1, values: [42, 42, 42, 42])
        let image = MercatorRender.image(field: f, kind: .relhumPercent, scale: rh, bbox: box(10.2, 50.2, 10.8, 50.8), width: 40)
        let c = rh.rgb(band: 8)   // 40 to 45 %
        #expect(pixel(image, 20, image.height / 2) == [c.0, c.1, c.2, 255])
    }

    @Test func validationAcceptsRealisticAndRejectsOddFiles() throws {
        try MercatorRender.validate(field(), kind: .temperatureC)
        #expect(throws: ImageError.self) { try MercatorRender.validate(field(), kind: .dewpointC) }                    // wrong parameter
        #expect(throws: ImageError.self) { try MercatorRender.validate(field { $0[3] = 400 }, kind: .temperatureC) }   // 127 degrees C
        #expect(throws: ImageError.self) { try MercatorRender.validate(field { $0[3] = 150 }, kind: .temperatureC) }   // -123 degrees C
        #expect(throws: ImageError.self) { try MercatorRender.validate(field { v in for i in 0..<15 { v[i] = .nan } }, kind: .temperatureC) }
    }
}
