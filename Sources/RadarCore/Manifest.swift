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

    static func imageJSON(config: Config) -> String {
        imageJSON(bbox: RadarConstants.bbox, width: config.width, height: config.height)
    }

    static func imageJSON(bbox: [Double], width: Int, height: Int) -> String {
        let sw = RadarConstants.mercatorToWGS84(x: bbox[0], y: bbox[1])
        let ne = RadarConstants.mercatorToWGS84(x: bbox[2], y: bbox[3])
        func r4(_ v: Double) -> Double { (v * 10000).rounded(.toNearestOrEven) / 10000 }
        let wgs = [sw.lon, sw.lat, ne.lon, ne.lat].map { number(r4($0)) }.joined(separator: ",")
        return "{\"format\":\"\(contentType)\",\"width\":\(width),\"height\":\(height),"
            + "\"projection\":\"EPSG:3857\",\"bbox\":[\(bbox.map(number).joined(separator: ","))],"
            + "\"bbox_wgs84\":[\(wgs)]}"
    }

    /// The `history` block (additive, schema stays 1) of history.json and of every layer manifest: what the configured duration promises
    /// (`hours`, the grid of `expected` times) against what is really there (`present`, `oldest`, `gaps`). Nothing is invented: a time that
    /// is not stored is a gap, whatever the reason (source too short, outage, still being backfilled).
    /// `grid`: all expected slot times, ascending; `present`: the slot times that exist (times off the grid do not count).
    static func historyJSON(hours: Int, grid: [Date], present: [Date], oldest: Date?, step: TimeInterval) -> String {
        let have = Set(present)
        var gaps: [(from: Date, to: Date, count: Int)] = []
        var found = 0
        for t in grid {
            if have.contains(t) { found += 1; continue }
            if let i = gaps.indices.last, t.timeIntervalSince(gaps[i].to) == step { gaps[i].to = t; gaps[i].count += 1 } else { gaps.append((t, t, 1)) }
        }
        let shown = gaps.prefix(100).map {
            "{\"from\":\(jsonString(TimeUtil.toISO($0.from))),\"to\":\(jsonString(TimeUtil.toISO($0.to))),\"slots\":\($0.count)}"
        }
        return "{\"hours\":\(hours),\"oldest\":\(oldest.map { jsonString(TimeUtil.toISO($0)) } ?? "null"),"
            + "\"expected\":\(grid.count),\"present\":\(found),\"complete\":\(found == grid.count),"
            + "\"gaps\":[\(shown.joined(separator: ","))]\(gaps.count > shown.count ? ",\"gaps_truncated\":true" : "")}"
    }

    /// history.json (schema 1): analysis slots of all published runs in (latest - history_hours, latest], ascending.
    /// The window is derived from the newest published run (not from the clock), so all replicas answer byte-identically.
    /// Additive (decision 19 Nov 2026): `history` (configured duration against what exists, gaps), see `historyJSON`.
    public static func buildHistory(repo: any Repo, config: Config) async throws -> [UInt8]? {
        guard let latest = try await repo.latestPublished() else { return nil }
        let since = latest.nominal.addingTimeInterval(-Double(config.historyHours) * 3600 + TimeUtil.step)
        let slots = try await repo.analysisSlots(since: since, before: latest.nominal.addingTimeInterval(TimeUtil.step))
        let grid = (0..<(config.historyHours * 3600 / Int(TimeUtil.step))).reversed().map { latest.nominal.addingTimeInterval(-Double($0) * TimeUtil.step) }
        let entries = slots.map { ref in
            "{\"time\":\(jsonString(TimeUtil.toISO(ref.slotTime))),\"kind\":\"analysis\","
                + "\"path\":\(jsonString(slotPath(runID: ref.runID, slotID: ref.slotID)))}"
        }
        let json = "{\"schema\":1,\"run\":\(jsonString(latest.runID)),"
            + "\"generated_at\":\(jsonString(TimeUtil.toISO(latest.publishedAt))),"
            + "\"step_minutes\":5,\"history_hours\":\(config.historyHours),"
            + "\"history\":\(historyJSON(hours: config.historyHours, grid: grid, present: slots.map(\.slotTime), oldest: slots.first?.slotTime, step: TimeUtil.step)),"
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
