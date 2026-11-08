import Foundation

/// Source of the public temperature/humidity layers (`TEMP_SOURCE`, live): `off` = the layers answer 404 and nothing is fetched,
/// `wms` = DWD WMS images (temperature only), `icon_d2` = ICON-D2 GRIB (temperature, dew point, relative humidity).
public enum TempSource: String, Sendable, CaseIterable {
    case off, wms, icon_d2
}

/// Data variant of an internal temperature layer (decides which `TEMP_SOURCE` value lets it ingest).
public enum TempVariant: String, Sendable {
    case wms, d2
}

/// WMS layers that `TEMP_WMS_LAYER` may name, with the style and legend that belong to them (verified 8 Nov 2026 against GetCapabilities).
public enum TempWMS {
    public static let defaultLayer = "dwd:Icon-eu_reg00625_fd_gl_T"
    public static let fallbackLayer = "dwd:Icon_reg025_fd_sl_T2M"
    public static let layers = [defaultLayer, fallbackLayer]

    /// Style of the layer; the fallback layer uses the server default (empty).
    public static func style(for layer: String) -> String {
        layer == defaultLayer ? "icon-eu_reg00625_fd_gl_t_isoarea_tkb" : ""
    }

    /// GetLegendGraphic of the layer (size measured 8 Nov 2026: 72 x 482 for the default style).
    public static func legend(for layer: String) -> LayerLegend? {
        let base = "https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic&format=image/png&layer=" + layer
        if layer == defaultLayer { return LayerLegend(url: base + "&style=" + style(for: layer), width: 72, height: 482) }
        return LayerLegend(url: base, width: 88, height: 505)
    }
}

public struct TempConfig: Sendable, Equatable {
    /// `TEMP_SOURCE`; default `off` (the feature stays invisible without configuration).
    public var source: TempSource = .off
    /// `TEMP_D2_PARAMS`: ICON-D2 variables that cause load; `t_2m` is always part of `icon_d2`. Default: dew point only
    /// (decision 8 Nov 2026: dew point first, relative humidity switchable and not the default).
    public var d2Params: Set<String> = ["td_2m"]
    /// `TEMP_FALLBACK_WARM`: with `icon_d2` the WMS variant keeps running as warm fallback.
    public var fallbackWarm = true
    /// `TEMP_D2_MAX_AGE_HOURS`: older ICON-D2 runs count as failed (fallback to WMS).
    public var d2MaxAgeHours = 7
    /// `TEMP_WMS_LAYER`
    public var wmsLayer = TempWMS.defaultLayer
    /// `TEMP_D2_RUN_INTERVAL_HOURS` (3 or 6): how often ICON-D2 runs are fetched. Decision 8 Nov 2026: 6 h by default, 3 h configurable.
    public var d2RunIntervalHours = 6

    public static let allowedD2Params: Set<String> = ["t_2m", "td_2m", "relhum_2m"]

    public init() {}

    /// `value` empty = default; unknown variables throw.
    public static func parseD2Params(_ raw: String) throws -> Set<String> {
        let tokens = raw.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !tokens.isEmpty else { return TempConfig().d2Params }
        guard Set(tokens).isSubset(of: allowedD2Params) else {
            throw ConfigError(description: "TEMP_D2_PARAMS: allowed values are t_2m, td_2m, relhum_2m")
        }
        return Set(tokens)
    }

    public static func parseSource(_ raw: String) throws -> TempSource {
        guard let source = TempSource(rawValue: raw.lowercased()) else {
            throw ConfigError(description: "TEMP_SOURCE must be off, wms or icon_d2")
        }
        return source
    }

    public static func parseBool(_ key: String, _ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        default: throw ConfigError(description: "\(key) must be true or false")
        }
    }

    public static func parseInt(_ key: String, _ raw: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(raw), range.contains(value) else {
            throw ConfigError(description: "\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return value
    }

    public static func parseWMSLayer(_ raw: String) throws -> String {
        guard layersContain(raw) else { throw ConfigError(description: "TEMP_WMS_LAYER must be \(TempWMS.layers.joined(separator: " or "))") }
        return raw
    }

    private static func layersContain(_ raw: String) -> Bool { TempWMS.layers.contains(raw) }

    /// Applies one setting (shared by the environment loader and dashboard overrides).
    public mutating func apply(key: String, raw: String) throws {
        switch key {
        case "TEMP_SOURCE": source = try Self.parseSource(raw)
        case "TEMP_D2_PARAMS": d2Params = try Self.parseD2Params(raw)
        case "TEMP_FALLBACK_WARM": fallbackWarm = try Self.parseBool(key, raw)
        case "TEMP_D2_MAX_AGE_HOURS": d2MaxAgeHours = try Self.parseInt(key, raw, 1...48)
        case "TEMP_WMS_LAYER": wmsLayer = try Self.parseWMSLayer(raw)
        case "TEMP_D2_RUN_INTERVAL_HOURS":
            let hours = try Self.parseInt(key, raw, 3...6)
            guard hours == 3 || hours == 6 else { throw ConfigError(description: "\(key) must be 3 or 6") }
            d2RunIntervalHours = hours
        default: throw ConfigError(description: "\(key) is not a temperature setting")
        }
    }

    public static let keys = ["TEMP_SOURCE", "TEMP_D2_PARAMS", "TEMP_FALLBACK_WARM", "TEMP_D2_MAX_AGE_HOURS", "TEMP_WMS_LAYER",
                              "TEMP_D2_RUN_INTERVAL_HOURS"]
}

/// Internal storage IDs per source (at most 16 characters: `layer_run.layer VARCHAR(16)`) and the public IDs that resolve to them.
public enum TempLayers {
    public static let publicIDs = ["temperature", "dewpoint", "humidity"]
    public static let wms = "temperature_wms"
    public static let d2Temperature = "temperature_d2"
    public static let d2Dewpoint = "dewpoint_d2"
    public static let d2Humidity = "humidity_d2"
    /// Internal IDs that exist as specs today (the D2 specs follow with the ICON-D2 ingest).
    public static let internalIDs = [wms, d2Temperature, d2Dewpoint, d2Humidity]

    public static func isInternal(_ id: String) -> Bool { internalIDs.contains(id) }
    public static func isPublic(_ id: String) -> Bool { publicIDs.contains(id) }
}

/// Maps a public ID to the internal layer that serves it right now (or nil = 404).
public enum TempResolver {
    /// Age limit of a WMS run that is used as fallback (the pressure/temperature runs are 6-hourly; 18 h = the app's limit).
    public static let wmsMaxAgeHours = 18

    /// - Parameter latest: nominal (reference) time of the newest published run of an internal layer, nil = none.
    public static func resolve(publicID: String, config: Config, latest: (String) -> Date?, now: Date) -> String? {
        let temp = config.temp
        guard TempLayers.isPublic(publicID), temp.source != .off else { return nil }
        func fresh(_ id: String, hours: Int) -> Bool {
            guard let run = latest(id) else { return false }
            return now.timeIntervalSince(run) <= Double(hours) * 3600
        }
        switch (temp.source, publicID) {
        case (.wms, "temperature"):
            return TempLayers.wms
        case (.icon_d2, "temperature"):
            if fresh(TempLayers.d2Temperature, hours: temp.d2MaxAgeHours) { return TempLayers.d2Temperature }
            return fresh(TempLayers.wms, hours: wmsMaxAgeHours) ? TempLayers.wms : nil
        case (.icon_d2, "dewpoint"):
            return temp.d2Params.contains("td_2m") && fresh(TempLayers.d2Dewpoint, hours: temp.d2MaxAgeHours) ? TempLayers.d2Dewpoint : nil
        case (.icon_d2, "humidity"):
            return temp.d2Params.contains("relhum_2m") && fresh(TempLayers.d2Humidity, hours: temp.d2MaxAgeHours) ? TempLayers.d2Humidity : nil
        default:
            return nil
        }
    }

    /// Whether an internal layer may fetch right now (gate of the ingest tick; read per tick, so `TEMP_SOURCE` acts live).
    public static func ingestAllowed(variant: TempVariant, config: Config) -> Bool {
        switch (variant, config.temp.source) {
        case (_, .off): return false
        case (.wms, .wms): return true
        case (.wms, .icon_d2): return config.temp.fallbackWarm
        case (.d2, .icon_d2): return true
        case (.d2, .wms): return false
        }
    }

    /// Whether the public ID is offered at all with the current settings (status `enabled`).
    public static func isEnabled(publicID: String, config: Config) -> Bool {
        guard config.layers.contains(where: TempLayers.isInternal) else { return false }
        switch (config.temp.source, publicID) {
        case (.off, _): return false
        case (_, "temperature"): return true
        case (.icon_d2, "dewpoint"): return config.temp.d2Params.contains("td_2m")
        case (.icon_d2, "humidity"): return config.temp.d2Params.contains("relhum_2m")
        default: return false
        }
    }
}
