import Foundation

public typealias Fetch = @Sendable (String) async throws -> [UInt8]

/// Minimal DWD WMS GetMap client (one whole-Germany image per slot, no location in any request).
public enum DWD {
    static func formatG(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func buildURL(config: Config, run: Date, slot: Date) -> String {
        let query: [(String, String)] = [
            ("SERVICE", "WMS"), ("VERSION", "1.1.1"), ("REQUEST", "GetMap"),
            ("LAYERS", RadarConstants.layer), ("STYLES", ""), ("SRS", "EPSG:3857"),
            ("BBOX", RadarConstants.bbox.map(formatG).joined(separator: ",")),
            ("WIDTH", String(config.width)), ("HEIGHT", String(config.height)),
            ("FORMAT", "image/png"), ("TRANSPARENT", "TRUE"),
            ("TIME", TimeUtil.toWMS(slot)), ("DIM_REFERENCE_TIME", TimeUtil.toWMS(run)),
        ]
        return config.wmsURL + "?" + query.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    }
}
