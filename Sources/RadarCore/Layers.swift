import Foundation

public enum LayerKind: String, Sendable { case forecast, observation }
public enum LayerProvider: String, Sendable { case dwd, eumetsat }
public enum LayerCompleteness: Sendable {
    case none
    /// Reject images with black cells (missing tiles); right for images that are never black (colour composites, masks).
    case blackCells
    /// Like `blackCells`, but cells with the sun below about 10 degrees may be dark: visible-channel images are legitimately
    /// (almost) black at night, a missing tile in daylight is not.
    case blackCellsInDaylight
}

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
    /// Completeness check before publishing (missing server-side tiles render black).
    public let completeness: LayerCompleteness
    /// Observation layers without capabilities: seconds after the nominal slot time at which a slot is expected.
    public let availabilityDelay: Double
    public let legend: LayerLegend?
    public let modificationNotice: String
    /// Image extent in EPSG:3857 (xmin, ymin, xmax, ymax); the radar extent unless the layer covers another area.
    public let bbox: [Double]
    /// Pixel width of this layer; `nil` = `Config.width` (the radar grid). The height follows from `bbox`.
    public let fixedWidth: Int?
    /// How often one slot may be claimed and fetched before it is given up (sources with real gaps, e.g. night VIS).
    public let maxAttempts: Int

    /// The app accepts images up to this many pixels per side.
    public static let maxPixelsPerSide = 4096

    public init(id: String, title: String, kind: LayerKind, provider: LayerProvider, wmsLayer: String,
                capsWorkspace: String?, capsLayer: String?, stepSeconds: Double, transparent: Bool, lossless: Bool,
                webpQuality: Float, completeness: LayerCompleteness, availabilityDelay: Double, legend: LayerLegend?,
                modificationNotice: String, bbox: [Double] = RadarConstants.bbox, fixedWidth: Int? = nil,
                maxAttempts: Int = LayerIngestor.maxSlotAttempts) {
        self.id = id; self.title = title; self.kind = kind; self.provider = provider; self.wmsLayer = wmsLayer
        self.capsWorkspace = capsWorkspace; self.capsLayer = capsLayer; self.stepSeconds = stepSeconds
        self.transparent = transparent; self.lossless = lossless; self.webpQuality = webpQuality
        self.completeness = completeness; self.availabilityDelay = availabilityDelay; self.legend = legend
        self.modificationNotice = modificationNotice; self.bbox = bbox; self.fixedWidth = fixedWidth
        self.maxAttempts = maxAttempts
    }

    public func width(_ config: Config) -> Int { fixedWidth ?? config.width }
    public func height(_ config: Config) -> Int { RadarConstants.imageHeight(width: width(config), bbox: bbox) }

    /// Same layer with another fixed width (tests use small images).
    public func resized(width: Int) -> LayerSpec {
        LayerSpec(id: id, title: title, kind: kind, provider: provider, wmsLayer: wmsLayer, capsWorkspace: capsWorkspace,
                  capsLayer: capsLayer, stepSeconds: stepSeconds, transparent: transparent, lossless: lossless,
                  webpQuality: webpQuality, completeness: completeness, availabilityDelay: availabilityDelay, legend: legend,
                  modificationNotice: modificationNotice, bbox: bbox, fixedWidth: width, maxAttempts: maxAttempts)
    }

    /// `Quelle: ...` for DWD layers; EUMETSAT's prescribed wording with the distribution year of the newest slot.
    public func attribution(year: Int) -> String {
        switch provider {
        case .dwd: return RadarConstants.attribution
        case .eumetsat: return "Contains modified EUMETSAT Meteosat data \(year)"
        }
    }

    public var stepMinutes: Int { Int(stepSeconds / 60) }

    /// How often a new run is published at best: forecast layers once per ICON run (6 h), observation layers per slot.
    /// Staleness checks must use this, not `stepSeconds` (an hourly forecast step is not an hourly publication).
    public var publishCadenceSeconds: Int { kind == .forecast ? Int(LayerIngestor.forecastRunInterval) : Int(stepSeconds) }
}

public enum LayerCatalog {
    public static let specs: [String: LayerSpec] = [
        "pressure": LayerSpec(
            id: "pressure", title: "Luftdruck (Isobaren, ICON)", kind: .forecast, provider: .dwd,
            wmsLayer: "dwd:Icon_reg025_fd_sl_PMSL", capsWorkspace: nil, capsLayer: nil, stepSeconds: 3600,
            transparent: true, lossless: true, webpQuality: 100, completeness: .none, availabilityDelay: 0,
            legend: LayerLegend(url: "https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=dwd:Icon_reg025_fd_sl_PMSL", width: 219, height: 40),
            modificationNotice: "Datenbasis: Deutscher Wetterdienst (ICON), Isobaren bildlich wiedergegeben"),
        "pressure_eu": LayerSpec(
            id: "pressure_eu", title: "Luftdruck Europa (Isobaren, ICON)", kind: .forecast, provider: .dwd,
            wmsLayer: "dwd:Icon_reg025_fd_sl_PMSL", capsWorkspace: nil, capsLayer: nil, stepSeconds: 3600,
            transparent: true, lossless: true, webpQuality: 100, completeness: .none, availabilityDelay: 0,
            legend: LayerLegend(url: "https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=dwd:Icon_reg025_fd_sl_PMSL", width: 219, height: 40),
            modificationNotice: "Datenbasis: Deutscher Wetterdienst (ICON), Isobaren bildlich wiedergegeben",
            bbox: RadarConstants.europeBBox, fixedWidth: 2048),
        "lightning": LayerSpec(
            id: "lightning", title: "Blitzdichte (NowCastMIX)", kind: .observation, provider: .dwd,
            wmsLayer: "dwd:Blitzdichte", capsWorkspace: nil, capsLayer: nil, stepSeconds: 300,
            transparent: true, lossless: true, webpQuality: 100, completeness: .none, availabilityDelay: 360,
            legend: LayerLegend(url: "https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=dwd:Blitzdichte", width: 119, height: 344),
            modificationNotice: "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben"),
        "clouds": LayerSpec(
            id: "clouds", title: "Wolken (Geo Colour RGB, Meteosat MTG)", kind: .observation, provider: .eumetsat,
            wmsLayer: "mtg_fd:rgb_geocolour", capsWorkspace: "mtg_fd", capsLayer: "rgb_geocolour", stepSeconds: 600,
            transparent: false, lossless: false, webpQuality: 80, completeness: .blackCells, availabilityDelay: 0, legend: nil,
            modificationNotice: "Datenbasis: EUMETSAT Meteosat (EUMETView), Bild ausgeschnitten, reprojiziert und verlustbehaftet komprimiert (WebP)"),
        "cloudmask": LayerSpec(
            id: "cloudmask", title: "Wolkenmaske (Meteosat SEVIRI)", kind: .observation, provider: .eumetsat,
            wmsLayer: "msg_fes:clm", capsWorkspace: "msg_fes", capsLayer: "clm", stepSeconds: 900,
            transparent: false, lossless: true, webpQuality: 100, completeness: .blackCells, availabilityDelay: 0,
            legend: LayerLegend(url: "https://view.eumetsat.int/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic"
                                + "&format=image/png&layer=msg_fes:clm&width=640&height=80", width: 640, height: 80),
            modificationNotice: "Datenbasis: EUMETSAT Meteosat (EUMETView), Bild ausgeschnitten und reprojiziert (WebP, verlustfrei)"),
        "cloudmask_vis": LayerSpec(
            id: "cloudmask_vis", title: "Sichtbares Licht (Meteosat MTG VIS 0,6, Tag)", kind: .observation, provider: .eumetsat,
            wmsLayer: "mtg_fd:vis06_hrfi", capsWorkspace: "mtg_fd", capsLayer: "vis06_hrfi", stepSeconds: 600,
            transparent: false, lossless: true, webpQuality: 100, completeness: .blackCellsInDaylight, availabilityDelay: 0, legend: nil,
            modificationNotice: "Datenbasis: EUMETSAT Meteosat (EUMETView), Bild ausgeschnitten und reprojiziert (Graustufen, WebP, verlustfrei)",
            maxAttempts: 2),
        "cloudmask_vis_eu": LayerSpec(
            id: "cloudmask_vis_eu", title: "Sichtbares Licht Europa (Meteosat MTG VIS 0,6, Tag)", kind: .observation, provider: .eumetsat,
            wmsLayer: "mtg_fd:vis06_hrfi", capsWorkspace: "mtg_fd", capsLayer: "vis06_hrfi", stepSeconds: 600,
            transparent: false, lossless: true, webpQuality: 100, completeness: .blackCellsInDaylight, availabilityDelay: 0, legend: nil,
            modificationNotice: "Datenbasis: EUMETSAT Meteosat (EUMETView), Bild ausgeschnitten und reprojiziert (Graustufen, WebP, verlustfrei)",
            bbox: RadarConstants.europeBBox, fixedWidth: 2048, maxAttempts: 2),
    ]

    /// Fixed order for logs and loops.
    public static let order = ["pressure", "pressure_eu", "lightning", "clouds", "cloudmask", "cloudmask_vis", "cloudmask_vis_eu"]

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

    public func forecastHours(for spec: LayerSpec) -> Int {
        spec.id == "pressure_eu" ? pressureEUForecastHours : pressureForecastHours
    }

    public func historyHours(for spec: LayerSpec) -> Int {
        switch spec.id {
        case "lightning": return lightningHistoryHours
        case "clouds": return cloudsHistoryHours
        case "cloudmask": return cloudmaskHistoryHours
        case "cloudmask_vis": return cloudmaskVisHistoryHours
        case "cloudmask_vis_eu": return cloudmaskVisEUHistoryHours
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

    /// One whole-image GetMap (EPSG:3857, bbox and size of the layer; the radar grid unless the spec says otherwise), no location in any request.
    public static func mapURL(spec: LayerSpec, config: Config, run: Date, slot: Date) -> String {
        let bbox = spec.bbox.map(DWD.formatG).joined(separator: ",")
        let width = String(spec.width(config)), height = String(spec.height(config))
        var query: [(String, String)]
        switch spec.provider {
        case .dwd:
            query = [("SERVICE", "WMS"), ("VERSION", "1.1.1"), ("REQUEST", "GetMap"), ("LAYERS", spec.wmsLayer), ("STYLES", ""),
                     ("SRS", "EPSG:3857"), ("BBOX", bbox), ("WIDTH", width), ("HEIGHT", height),
                     ("FORMAT", "image/png"), ("TRANSPARENT", spec.transparent ? "TRUE" : "FALSE"), ("TIME", TimeUtil.toWMS(slot))]
            if spec.kind == .forecast { query.append(("DIM_REFERENCE_TIME", TimeUtil.toWMS(run))) }
        case .eumetsat:
            query = [("SERVICE", "WMS"), ("VERSION", "1.3.0"), ("REQUEST", "GetMap"), ("LAYERS", spec.wmsLayer), ("STYLES", ""),
                     ("CRS", "EPSG:3857"), ("BBOX", bbox), ("WIDTH", width), ("HEIGHT", height),
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
