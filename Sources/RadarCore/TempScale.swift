import Foundation

/// Colour scale of an ICON-D2 layer, mirror of `docs/fixtures/scales/scales-v1.json` (the contract the app uses for legend and value
/// readout). `bandColors[i]` colours the values from `min + i * step` (inclusive) up to the next band; values below `min` belong to
/// the first and values from `max` upward to the last band.
public struct TempScale: Sendable, Equatable {
    public let id: String
    public let unit: String
    public let min: Double, max: Double, step: Double
    public let labelEvery: Int
    public let bandColors: [UInt32]

    public var bandCount: Int { bandColors.count }

    public static func load(id: String) -> TempScale? { table.first { $0.id == id } }

    /// Band of a value in the scale's unit. The value is rounded to 0.001 first, so float noise of the Kelvin conversion
    /// (273.15 K = 0 degrees C) cannot move a value across a band edge.
    public func bandIndex(_ value: Double) -> Int {
        let rounded = (value * 1000).rounded() / 1000
        let index = Int(((rounded - min) / step).rounded(.down))
        return Swift.min(Swift.max(index, 0), bandCount - 1)
    }

    /// RGB of the band as `(r, g, b)`.
    public func rgb(band: Int) -> (UInt8, UInt8, UInt8) {
        let c = bandColors[band]
        return (UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF))
    }
}

/// What a GRIB field is rendered as: the unit conversion and the plausibility range (outside means the file is not what we expect).
public enum TempKind: Sendable {
    case temperatureC, dewpointC, relhumPercent

    /// Scale ID in the manifest.
    public var scaleID: String {
        switch self {
        case .temperatureC: return "t2m-d2-v1"
        case .dewpointC: return "td-d2-v1"
        case .relhumPercent: return "rh-d2-v1"
        }
    }

    /// ICON-D2 file variable (`TEMP_D2_PARAMS` token).
    public var variable: String {
        switch self {
        case .temperatureC: return "t_2m"
        case .dewpointC: return "td_2m"
        case .relhumPercent: return "relhum_2m"
        }
    }

    /// GRIB2 discipline 0 parameter (category, number): t_2m 0/0, td_2m 0/6, relhum_2m 1/1.
    var parameter: (UInt8, UInt8) {
        switch self {
        case .temperatureC: return (0, 0)
        case .dewpointC: return (0, 6)
        case .relhumPercent: return (1, 1)
        }
    }

    /// Raw value to scale unit (K to degrees C; relative humidity unchanged).
    func convert(_ raw: Float) -> Double { self == .relhumPercent ? Double(raw) : Double(raw) - 273.15 }

    /// Accepted range in the scale unit (spec 3.5: -90..60 degrees C, 0..100 %; humidity may overshoot 100 by rounding).
    var plausible: ClosedRange<Double> { self == .relhumPercent ? -0.5...100.5 : -90...60 }

    public static func kind(variable: String) -> TempKind? {
        [TempKind.temperatureC, .dewpointC, .relhumPercent].first { $0.variable == variable }
    }
}
