import Foundation

/// latest.json: describes only published runs. Paths are relative to /v1/radar/.
public enum Manifest {
    public static let fileExtension = "webp"
    public static let contentType = "image/webp"

    public static func slotPath(runID: String, slotID: String) -> String {
        "\(runID)/\(slotID).\(fileExtension)"
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value > 0x7E {
                    // Same as Python's ensure_ascii.
                    for unit in String(scalar).utf16 {
                        let hex = String(unit, radix: 16)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func number(_ value: Double) -> String { value.description }

    private static func entry(_ ref: SlotRef, runTime: Date) -> String {
        let kind = ref.slotTime == runTime ? "analysis" : "forecast"
        return "{\"time\":\(jsonString(TimeUtil.toISO(ref.slotTime))),\"kind\":\"\(kind)\","
            + "\"path\":\(jsonString(slotPath(runID: ref.runID, slotID: ref.slotID)))}"
    }

    private static func imageJSON(config: Config) -> String {
        let bbox = RadarConstants.bbox
        let sw = RadarConstants.mercatorToWGS84(x: bbox[0], y: bbox[1])
        let ne = RadarConstants.mercatorToWGS84(x: bbox[2], y: bbox[3])
        func r4(_ v: Double) -> Double { (v * 10000).rounded(.toNearestOrEven) / 10000 }
        let wgs = [sw.lon, sw.lat, ne.lon, ne.lat].map { number(r4($0)) }.joined(separator: ",")
        return "{\"format\":\"\(contentType)\",\"width\":\(config.width),\"height\":\(config.height),"
            + "\"projection\":\"EPSG:3857\",\"bbox\":[\(bbox.map(number).joined(separator: ","))],"
            + "\"bbox_wgs84\":[\(wgs)]}"
    }

    /// history.json (schema 1): analysis slots of all published runs in (latest - history_hours, latest], ascending.
    /// The window is derived from the newest published run (not from the clock), so all replicas answer byte-identically.
    public static func buildHistory(repo: any Repo, config: Config) async throws -> [UInt8]? {
        guard let latest = try await repo.latestPublished() else { return nil }
        let since = latest.nominal.addingTimeInterval(-Double(config.historyHours) * 3600 + TimeUtil.step)
        let slots = try await repo.analysisSlots(since: since, before: latest.nominal.addingTimeInterval(TimeUtil.step))
        let entries = slots.map { ref in
            "{\"time\":\(jsonString(TimeUtil.toISO(ref.slotTime))),\"kind\":\"analysis\","
                + "\"path\":\(jsonString(slotPath(runID: ref.runID, slotID: ref.slotID)))}"
        }
        let json = "{\"schema\":1,\"run\":\(jsonString(latest.runID)),"
            + "\"generated_at\":\(jsonString(TimeUtil.toISO(latest.publishedAt))),"
            + "\"step_minutes\":5,\"history_hours\":\(config.historyHours),"
            + "\"image\":\(imageJSON(config: config)),"
            + "\"slots\":[\(entries.joined(separator: ","))],"
            + "\"attribution\":\(jsonString(RadarConstants.attribution)),"
            + "\"modification_notice\":\(jsonString(RadarConstants.modificationNotice))}\n"
        return Array(json.utf8)
    }

    /// Deterministic per DB state (generated_at = publication time), so all replicas answer byte-identically.
    /// Key order and compact separators match the former Python implementation.
    public static func build(repo: any Repo, config: Config) async throws -> [UInt8]? {
        guard let latest = try await repo.latestPublished() else { return nil }
        let history = try await repo.historySlots(
            since: latest.nominal.addingTimeInterval(-Double(TimeUtil.historySlots) * TimeUtil.step), before: latest.nominal)
        var entries = history.map { entry($0, runTime: $0.slotTime) }
        entries += try await repo.publishedSlots(runID: latest.runID).map { entry($0, runTime: latest.nominal) }
        let json = "{\"schema\":1,\"run\":\(jsonString(latest.runID)),"
            + "\"reference_time\":\(jsonString(TimeUtil.toISO(latest.nominal))),"
            + "\"generated_at\":\(jsonString(TimeUtil.toISO(latest.publishedAt))),"
            + "\"step_minutes\":5,\"forecast_horizon_minutes\":\(TimeUtil.horizonMinutes),"
            + "\"image\":\(imageJSON(config: config)),"
            + "\"slots\":[\(entries.joined(separator: ","))],"
            + "\"attribution\":\(jsonString(RadarConstants.attribution)),"
            + "\"modification_notice\":\(jsonString(RadarConstants.modificationNotice))}\n"
        return Array(json.utf8)
    }
}
