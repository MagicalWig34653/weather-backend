import Foundation

/// What the radar shows for one subscription in one slot (diagnosis only; the production evaluation uses `classes`).
public struct SlotMeasure: Sendable, Equatable {
    /// Point: class of the pixel (0 = dry, -1 = unknown pixel for Live Activity subscriptions). Circle: highest class inside the disc.
    public var maxClass: Int
    /// Circle only: cells with a class at or above the threshold, cells in the (clipped) disc, cells needed for "wet".
    public var wetCells: Int?
    public var cells: Int?
    public var neededCells: Int?
    public init(maxClass: Int, wetCells: Int? = nil, cells: Int? = nil, neededCells: Int? = nil) {
        self.maxClass = maxClass; self.wetCells = wetCells; self.cells = cells; self.neededCells = neededCells
    }
}

extension PushRegion {
    /// Full scan of the disc (no early exit): highest class and wet-cell count, same geometry and need as `pseudoClass`.
    static func measure(classMap: [UInt8], width: Int, height: Int, cx: Int, cy: Int, radius: Int, threshold: Int, sharePercent: Int) -> SlotMeasure {
        let runs = runs(cx: cx, cy: cy, radius: radius, width: width, height: height)
        let cells = runs.reduce(0) { $0 + $1.x1 - $1.x0 + 1 }
        let limit = UInt8(clamping: threshold)
        var wet = 0, top: UInt8 = 0
        for run in runs {
            let base = run.y * width
            for x in run.x0...run.x1 {
                let value = classMap[base + x]
                if value > top { top = value }
                if value >= limit { wet += 1 }
            }
        }
        return SlotMeasure(maxClass: Int(top), wetCells: wet, cells: cells, neededCells: requiredWet(cells: cells, sharePercent: sharePercent))
    }
}

/// JSON of the radar situation of one subscription for the dashboard (device subscriptions and re-evaluation).
/// Cell indices and a rounded coordinate (cell centre, about 1 km) are shown because the operator looks at his own linked device
/// behind the passkey session; never tokens or IDs (docs-site/content/dashboard-api.md).
enum PushMeasureJSON {
    static func mmPerHour(_ cls: Int) -> Any {
        cls <= 0 ? 0 : (PushIntensity.lowerBoundsMMPerHour[min(cls, 15) - 1] as Any)
    }

    static func place(_ sub: PushSubscription, width: Int) -> Any {
        guard let c = PushGrid.coordinate(cellX: sub.cellX, cellY: sub.cellY, width: width) else { return NSNull() }
        return ["lat": c.lat, "lon": c.lon, "x": sub.cellX, "y": sub.cellY, "cellKm": (PushGrid.cellKilometres(latitude: c.lat, width: width) * 100).rounded() / 100] as [String: Any]
    }

    /// Fields that describe slot 0 and the lead window against the threshold. `measures` holds 25 slots or none.
    static func fields(_ sub: PushSubscription, measures: [SlotMeasure]?, radarOK: Bool, width: Int) -> [String: Any] {
        var out: [String: Any] = ["place": place(sub, width: width), "thresholdMmPerHour": mmPerHour(sub.threshold)]
        guard radarOK, let measures, measures.count == TimeUtil.forecastSlots else {
            out["measuredClass"] = NSNull(); out["measuredMmPerHour"] = NSNull(); out["pixel"] = NSNull()
            out["leadMaxClass"] = NSNull(); out["leadOnsetMinutes"] = NSNull()
            out["wetCells"] = NSNull(); out["cells"] = NSNull(); out["neededCells"] = NSNull(); out["sharePercent"] = NSNull()
            return out
        }
        let now = measures[0]
        let lead = max(1, min(sub.leadMinutes / 5, measures.count - 1))
        out["measuredClass"] = now.maxClass < 0 ? NSNull() : now.maxClass as Any
        out["measuredMmPerHour"] = now.maxClass < 0 ? NSNull() : mmPerHour(now.maxClass)
        out["pixel"] = now.maxClass < 0 ? "unknown" : (now.maxClass == 0 ? "dry" : "rain")
        out["leadMaxClass"] = measures[1...lead].map(\.maxClass).max().map { max(0, $0) } as Any? ?? NSNull()
        let onset = (1...lead).first { measures[$0].maxClass >= sub.threshold && (measures[$0].wetCells.map { $0 >= (measures[$0].neededCells ?? 1) } ?? true) }
        out["leadOnsetMinutes"] = onset.map { $0 * 5 } as Any? ?? NSNull()
        if sub.kind == .circle, let wet = now.wetCells, let cells = now.cells {
            out["wetCells"] = wet; out["cells"] = cells; out["neededCells"] = now.neededCells as Any? ?? NSNull()
            out["sharePercent"] = cells > 0 ? (Double(wet) * 1000 / Double(cells)).rounded() / 10 : 0.0
        } else {
            out["wetCells"] = NSNull(); out["cells"] = NSNull(); out["neededCells"] = NSNull(); out["sharePercent"] = NSNull()
        }
        return out
    }

    /// Why the evaluation ends as it does, in fixed words. `decision` is the result of `PushService.decide`.
    static func reason(_ sub: PushSubscription, decision: String, measures: [SlotMeasure]?, radar: DeviceRadarView.Status) -> String {
        switch radar {
        case .noSlot: return "radar_missing"
        case .staleRun: return "radar_stale"
        case .ok: break
        }
        guard decision == "below_threshold" else { return decision }
        guard let measures, measures.count == TimeUtil.forecastSlots else { return "radar_missing" }
        let now = measures[0]
        if sub.kind == .circle {
            return (now.wetCells ?? 0) >= (now.neededCells ?? 1) ? "already_wet" : "share_below"
        }
        if now.maxClass < 0 { return "pixel_unknown" }
        if now.maxClass >= sub.threshold { return "already_wet" }
        return now.maxClass == 0 ? "cell_dry" : "class_below_threshold"
    }
}
