import Foundation

public enum LayerKind: String, Sendable { case forecast, observation }
public enum LayerProvider: String, Sendable { case dwd, eumetsat }

public struct LayerLegend: Sendable, Equatable {
    public let url: String
    public let width: Int
    public let height: Int
}

/// Static description of one additional map layer (everything except the per-deployment settings in `Config`).
/// All values were verified against GetCapabilities/GetMap (see docs/decisions.md).
public struct LayerSpec: Sendable {
    public let id: String
    public let title: String
    public let kind: LayerKind
    public let provider: LayerProvider
    /// Layer name in the GetMap request.
    public let wmsLayer: String
    /// EUMETView only: workspace and local layer name for the (small) per-workspace GetCapabilities.
    public let capsWorkspace: String?
    public let capsLayer: String?
    public let stepSeconds: Double
    public let transparent: Bool
    public let lossless: Bool
    public let webpQuality: Float
    /// Reject images with black (missing-tile) areas before publishing.
    public let checkComplete: Bool
    /// Observation layers without capabilities: seconds after the nominal slot time at which a slot is expected.
    public let availabilityDelay: Double
    public let legend: LayerLegend?
    public let modificationNotice: String

    /// `Quelle: ...` for DWD layers; EUMETSAT's prescribed wording with the distribution year of the newest slot.
    public func attribution(year: Int) -> String {
        switch provider {
        case .dwd: return RadarConstants.attribution
        case .eumetsat: return "Contains modified EUMETSAT Meteosat data \(year)"
        }
    }

    public var stepMinutes: Int { Int(stepSeconds / 60) }
}

public enum LayerCatalog {
    public static let specs: [String: LayerSpec] = [
        "pressure": LayerSpec(
            id: "pressure", title: "Luftdruck (Isobaren, ICON)", kind: .forecast, provider: .dwd,
            wmsLayer: "dwd:Icon_reg025_fd_sl_PMSL", capsWorkspace: nil, capsLayer: nil, stepSeconds: 3600,
            transparent: true, lossless: true, webpQuality: 100, checkComplete: false, availabilityDelay: 0,
            legend: LayerLegend(url: "https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=dwd:Icon_reg025_fd_sl_PMSL", width: 219, height: 40),
            modificationNotice: "Datenbasis: Deutscher Wetterdienst (ICON), Isobaren bildlich wiedergegeben"),
        "lightning": LayerSpec(
            id: "lightning", title: "Blitzdichte (NowCastMIX)", kind: .observation, provider: .dwd,
            wmsLayer: "dwd:Blitzdichte", capsWorkspace: nil, capsLayer: nil, stepSeconds: 300,
            transparent: true, lossless: true, webpQuality: 100, checkComplete: false, availabilityDelay: 360,
            legend: LayerLegend(url: "https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=dwd:Blitzdichte", width: 119, height: 344),
            modificationNotice: "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben"),
        "clouds": LayerSpec(
            id: "clouds", title: "Wolken (Geo Colour RGB, Meteosat MTG)", kind: .observation, provider: .eumetsat,
            wmsLayer: "mtg_fd:rgb_geocolour", capsWorkspace: "mtg_fd", capsLayer: "rgb_geocolour", stepSeconds: 600,
            transparent: false, lossless: false, webpQuality: 80, checkComplete: true, availabilityDelay: 0, legend: nil,
            modificationNotice: "Datenbasis: EUMETSAT Meteosat (EUMETView), Bild ausgeschnitten, reprojiziert und verlustbehaftet komprimiert (WebP)"),
        "cloudmask": LayerSpec(
            id: "cloudmask", title: "Wolkenmaske (Meteosat SEVIRI)", kind: .observation, provider: .eumetsat,
            wmsLayer: "msg_fes:clm", capsWorkspace: "msg_fes", capsLayer: "clm", stepSeconds: 900,
            transparent: false, lossless: true, webpQuality: 100, checkComplete: true, availabilityDelay: 0,
            legend: LayerLegend(url: "https://view.eumetsat.int/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=msg_fes:clm&width=640&height=80", width: 640, height: 80),
            modificationNotice: "Datenbasis: EUMETSAT Meteosat (EUMETView), Bild ausgeschnitten und reprojiziert (WebP, verlustfrei)"),
    ]

    /// Fixed order for logs and loops.
    public static let order = ["pressure", "lightning", "clouds", "cloudmask"]

    /// Parses `LAYERS` (comma or space separated). `radar` is accepted but ignored: the radar always runs.
    public static func parse(_ raw: String?) throws -> [String] {
        let tokens = (raw ?? "").lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        var out: [String] = []
        for token in tokens where token != "radar" {
            guard specs[token] != nil else {
                throw ConfigError(description: "LAYERS: unknown layer '\(token)' (allowed: radar, \(order.joined(separator: ", ")))")
            }
            if !out.contains(token) { out.append(token) }
        }
        return order.filter(out.contains)
    }
}

extension Config {
    public func spec(for layer: String) -> LayerSpec? { layers.contains(layer) ? LayerCatalog.specs[layer] : nil }

    public func historyHours(for spec: LayerSpec) -> Int {
        switch spec.id {
        case "lightning": return lightningHistoryHours
        case "clouds": return cloudsHistoryHours
        case "cloudmask": return cloudmaskHistoryHours
        default: return 0
        }
    }
}

/// Request builders and capabilities parsing for the additional layers.
public enum LayerSources {
    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// One whole-image GetMap (EPSG:3857, same bbox and size as the radar), no location in any request.
    public static func mapURL(spec: LayerSpec, config: Config, run: Date, slot: Date) -> String {
        let bbox = RadarConstants.bbox.map(DWD.formatG).joined(separator: ",")
        var query: [(String, String)]
        switch spec.provider {
        case .dwd:
            query = [("SERVICE", "WMS"), ("VERSION", "1.1.1"), ("REQUEST", "GetMap"), ("LAYERS", spec.wmsLayer), ("STYLES", ""),
                     ("SRS", "EPSG:3857"), ("BBOX", bbox), ("WIDTH", String(config.width)), ("HEIGHT", String(config.height)),
                     ("FORMAT", "image/png"), ("TRANSPARENT", spec.transparent ? "TRUE" : "FALSE"), ("TIME", TimeUtil.toWMS(slot))]
            if spec.kind == .forecast { query.append(("DIM_REFERENCE_TIME", TimeUtil.toWMS(run))) }
        case .eumetsat:
            query = [("SERVICE", "WMS"), ("VERSION", "1.3.0"), ("REQUEST", "GetMap"), ("LAYERS", spec.wmsLayer), ("STYLES", ""),
                     ("CRS", "EPSG:3857"), ("BBOX", bbox), ("WIDTH", String(config.width)), ("HEIGHT", String(config.height)),
                     ("FORMAT", "image/png"), ("TIME", TimeUtil.toISO(slot))]
        }
        let base = spec.provider == .dwd ? config.wmsURL : config.eumetsatWMSURL
        return base + "?" + query.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    }

    /// EUMETView: the per-workspace capabilities (35-50 KB) instead of the 280 KB service-wide document.
    public static func capabilitiesURL(spec: LayerSpec, config: Config) -> String? {
        guard spec.provider == .eumetsat, let workspace = spec.capsWorkspace else { return nil }
        var base = config.eumetsatWMSURL
        if base.hasSuffix("/wms") { base = String(base.dropLast(4)) + "/\(workspace)/wms" }
        return base + "?service=WMS&version=1.3.0&request=GetCapabilities"
    }

    /// Newest slot time of the layer's `time` dimension (`start/end/period`) in a WMS 1.3.0 capabilities document.
    public static func latestSlot(capabilities: [UInt8], layerName: String) -> Date? {
        let text = String(decoding: capabilities, as: UTF8.self)
        guard let nameRange = text.range(of: "<Name>\(layerName)</Name>") else { return nil }
        let rest = text[nameRange.upperBound...]
        let layerEnd = rest.range(of: "</Layer>")?.lowerBound ?? rest.endIndex
        let segment = rest[..<layerEnd]
        guard let dim = segment.range(of: "<Dimension name=\"time\"") else { return nil }
        let afterDim = segment[dim.upperBound...]
        guard let open = afterDim.firstIndex(of: ">"), let close = afterDim.range(of: "</Dimension>") else { return nil }
        let value = afterDim[afterDim.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return TimeUtil.fromSQL(String(parts[1]))
    }
}
