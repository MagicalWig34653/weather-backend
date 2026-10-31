import Foundation

/// Maps radar pixel colours to the 15 rain classes of the DWD legend of `dwd:Niederschlagsradar` (mm/h).
/// Class 0 means "no rain / no data". Palette source: WMS GetLegendGraphic, rule "Niederschlag in mm/h" (see App repo
/// Weather/Map/RadarLegend.swift, checked 31 Oct 2026). NOT yet verified against real radar pixels: the matching is
/// tolerant (nearest legend colour) and everything unclear counts as dry, so uncertainty never creates a notification.
public enum PushIntensity {
    /// Lower bounds in mm/h of classes 1...15 (for documentation and the app's threshold names).
    public static let lowerBoundsMMPerHour: [Double] = [0.1, 0.2, 0.4, 1, 2, 3, 5, 7.5, 10, 15, 30, 45, 75, 100, 150]

    static let palette: [(r: Int, g: Int, b: Int)] = [
        (0x33, 0xFF, 0xFF), (0x1A, 0xCC, 0x9A), (0x01, 0x99, 0x34), (0x4D, 0xB3, 0x1B), (0x99, 0xCC, 0x01),
        (0xCC, 0xE6, 0x01), (0xFF, 0xFF, 0x01), (0xFF, 0xC4, 0x01), (0xFF, 0x89, 0x01), (0xFF, 0x45, 0x01),
        (0xFE, 0x00, 0x00), (0xE5, 0x00, 0x4C), (0xCC, 0x00, 0x98), (0x66, 0x00, 0xCB), (0x00, 0x00, 0xFE),
    ]
    /// Pixels below this alpha are background/mask (the "no data" class is the grey 7D7D7D at alpha 0.3).
    static let minAlpha = 128
    /// Squared RGB distance up to which a pixel still counts as a legend colour.
    static let maxDistanceSquared = 40 * 40

    public static func classify(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> Int {
        guard Int(a) >= minAlpha else { return 0 }
        var best = 0
        var bestDistance = Int.max
        for (index, color) in palette.enumerated() {
            let dr = Int(r) - color.r, dg = Int(g) - color.g, db = Int(b) - color.b
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance { bestDistance = distance; best = index + 1 }
        }
        return bestDistance <= maxDistanceSquared ? best : 0
    }

    public static func classify(_ image: RGBAImage, x: Int, y: Int) -> Int {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
        let o = (y * image.width + x) * 4
        return classify(r: image.pixels[o], g: image.pixels[o + 1], b: image.pixels[o + 2], a: image.pixels[o + 3])
    }
}

/// Rain-start automaton per subscription (pure function). `classes` holds the 25 slots of one run, index 0 = analysis.
public enum PushEvaluator {
    /// Runs older than this are not evaluated (decisions.md rule: no notification from stale data).
    public static let maxRunAge: TimeInterval = 20 * 60
    /// At most one notification per subscription in this time.
    public static let repeatLock: TimeInterval = 60 * 60
    /// Slots 0...6 (analysis + 30 minutes) must be dry to re-arm after a notification.
    public static let rearmSlots = 6

    public struct Step: Equatable, Sendable {
        public var state: PushState
        /// Minutes until rain when a notification is due.
        public var notifyMinutes: Int?
    }

    public static func step(state: PushState, threshold: Int, leadMinutes: Int, lastSentAt: Date?, classes: [Int], now: Date) -> Step {
        guard classes.count == TimeUtil.forecastSlots else { return Step(state: state, notifyMinutes: nil) }
        let wetNow = classes[0] >= threshold
        let leadSlots = max(1, min(leadMinutes / 5, classes.count - 1))
        let onset = (1...leadSlots).first { classes[$0] >= threshold }
        let beginning = !wetNow && onset != nil
        switch state {
        case .dry:
            return Step(state: beginning ? .pending : .dry, notifyMinutes: nil)
        case .pending:
            guard beginning, let onset else { return Step(state: .dry, notifyMinutes: nil) }
            if let lastSentAt, now.timeIntervalSince(lastSentAt) < repeatLock { return Step(state: .pending, notifyMinutes: nil) }
            return Step(state: .notified, notifyMinutes: onset * 5)
        case .notified:
            let dry = classes[0...rearmSlots].allSatisfy { $0 < threshold }
            return Step(state: dry ? .dry : .notified, notifyMinutes: nil)
        }
    }

    public static func payload(minutes: Int, subscriptionID: String) -> String {
        let object: [String: Any] = [
            "aps": ["alert": ["loc-key": "RAIN_STARTS_IN", "loc-args": [String(minutes)]], "sound": "default", "thread-id": subscriptionID],
            "type": "rain-start", "minutes": minutes,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
