import Foundation

/// Subscription kind: a single raster cell (default, as before) or a circle around a coarse centre cell.
public enum PushKind: Int, Sendable { case point = 0, circle = 1 }

/// Limits for region subscriptions (decisions.md, 1 Nov 2026). The server counts cells itself, from centre and radius.
public struct RegionLimits: Sendable, Equatable {
    public var maxRegionsPerInstallation = 3
    public var maxCellsPerInstallation = 8_000
    /// Evaluation cost guard, not a per-user quota: 2 Mio. cells take about 40 ms per run (release, `PushRegionBenchmark`),
    /// so 50 Mio. stay around 1 s. Raised from 2 Mio. so that fake installations cannot fill it for real users (review H2).
    public var maxCellsServerwide = 50_000_000
    /// Hard cap of all subscriptions (points and regions) on the server.
    public var maxSubscriptionsServerwide = 400_000
    /// Hard cap of subscriptions with `live_activity=true` (review A1): bounds the activity work per radar run and tick.
    public var maxLiveActivitySubscriptions = 5_000
    public init(maxRegionsPerInstallation: Int = 3, maxCellsPerInstallation: Int = 8_000, maxCellsServerwide: Int = 50_000_000,
                maxSubscriptionsServerwide: Int = 400_000, maxLiveActivitySubscriptions: Int = 5_000) {
        self.maxLiveActivitySubscriptions = maxLiveActivitySubscriptions
        self.maxRegionsPerInstallation = maxRegionsPerInstallation; self.maxCellsPerInstallation = maxCellsPerInstallation
        self.maxCellsServerwide = maxCellsServerwide; self.maxSubscriptionsServerwide = maxSubscriptionsServerwide
    }
    public static let standard = RegionLimits()

    /// `otherRadii`: radii of the installation's other regions; `serverCells`: cells of all other regions on the server.
    func violation(otherRadii: [Int], serverCells: Int, newRadius: Int) -> PushRegionLimitError? {
        let own = otherRadii.reduce(0) { $0 + PushRegion.cellCount(radius: $1) } + PushRegion.cellCount(radius: newRadius)
        if otherRadii.count + 1 > maxRegionsPerInstallation || own > maxCellsPerInstallation { return .perInstallation }
        if serverCells + PushRegion.cellCount(radius: newRadius) > maxCellsServerwide { return .capacity }
        return nil
    }
}

public enum PushRegionLimitError: Error, Sendable, Equatable { case perInstallation, capacity, activityCapacity }

/// Geometry and trigger rule of circular regions. No coordinates: everything is in cells of the ingest raster.
public enum PushRegion {
    public static let radiusRange = 3...40
    public static let allowedShares: Set<Int> = [1, 10, 25]
    public static let defaultShare = 10
    /// The centre is stored on a coarser 3 x 3 cell raster (about 2 km): the cell in the middle of its block.
    public static let centerBlock = 3
    /// Fewer wet cells never trigger (suppresses single-pixel clutter); regions below `smallRegion` cells need only one.
    public static let minWetCells = 3
    public static let smallRegion = 30

    public static func snapCenter(x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        (min(x / centerBlock * centerBlock + 1, width - 1), min(y / centerBlock * centerBlock + 1, height - 1))
    }

    private static func half(radius: Int, dy: Int) -> Int { Int(Double(radius * radius - dy * dy).squareRoot()) }

    /// Cells of the full (unclipped) disc: all cells with dx^2 + dy^2 <= r^2.
    public static func cellCount(radius: Int) -> Int {
        (-radius...radius).reduce(0) { $0 + 2 * half(radius: radius, dy: $1) + 1 }
    }

    /// Row runs of the disc clipped to the raster: (y, firstX, lastX).
    static func runs(cx: Int, cy: Int, radius: Int, width: Int, height: Int) -> [(y: Int, x0: Int, x1: Int)] {
        var result: [(Int, Int, Int)] = []
        for dy in -radius...radius {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            let h = half(radius: radius, dy: dy)
            let x0 = max(0, cx - h), x1 = min(width - 1, cx + h)
            if x0 <= x1 { result.append((y, x0, x1)) }
        }
        return result
    }

    /// Wet cells needed in one slot for `cells` cells in the region.
    public static func requiredWet(cells: Int, sharePercent: Int) -> Int {
        cells < smallRegion ? 1 : max(minWetCells, (cells * sharePercent + 99) / 100)
    }

    /// Pseudo class of one slot: `threshold` when the region counts as wet, otherwise 0 (so `PushEvaluator.step` runs unchanged).
    public static func pseudoClass(classMap: [UInt8], width: Int, height: Int, cx: Int, cy: Int, radius: Int,
                                   threshold: Int, sharePercent: Int) -> Int {
        let runs = runs(cx: cx, cy: cy, radius: radius, width: width, height: height)
        let cells = runs.reduce(0) { $0 + $1.x1 - $1.x0 + 1 }
        let need = requiredWet(cells: cells, sharePercent: sharePercent)
        let limit = UInt8(clamping: threshold)
        var wet = 0
        for run in runs {
            let base = run.y * width
            for x in run.x0...run.x1 where classMap[base + x] >= limit && classMap[base + x] != PushIntensity.unknownMark { wet += 1 }
            if wet >= need { return threshold }
        }
        return 0
    }
}

/// What one slot shows inside a region (Live Activity regions only; the alert path keeps using `pseudoClass`).
public struct RegionSlotStats: Sendable, Equatable {
    /// Cells of the disc clipped to the raster.
    public var cells: Int
    /// Cells with a known class at or above the threshold.
    public var wet: Int
    /// Cells that could not be interpreted (semi-transparent mask, colour outside the legend).
    public var unknown: Int
    /// Highest known class inside the disc (0 = dry).
    public var maxClass: Int
    /// Wet cells needed for "wet" (same rule as the alert).
    public var need: Int
    /// `threshold` when the region is surely wet, `PushIntensity.unknown` (-1) when the unknown cells could still make it wet, else 0.
    public var pseudoClass: Int
}

extension PushRegion {
    /// Full scan of the disc on a class map made with `markUnknown: true`. The decision matches `pseudoClass` (wet cells >= need
    /// is wet, so the Live Activity and the alert of one region never disagree about "wet"); additionally it reports
    /// "unknown" when wet + unknown cells would reach the need: that slot neither confirms rain nor an end (like an unknown point pixel).
    static func slotStats(classMap: [UInt8], width: Int, height: Int, cx: Int, cy: Int, radius: Int, threshold: Int, sharePercent: Int) -> RegionSlotStats {
        let runs = runs(cx: cx, cy: cy, radius: radius, width: width, height: height)
        let cells = runs.reduce(0) { $0 + $1.x1 - $1.x0 + 1 }
        let need = requiredWet(cells: cells, sharePercent: sharePercent)
        let limit = UInt8(clamping: threshold)
        var wet = 0, unknown = 0, top: UInt8 = 0
        for run in runs {
            let base = run.y * width
            for x in run.x0...run.x1 {
                let value = classMap[base + x]
                if value == PushIntensity.unknownMark { unknown += 1; continue }
                if value > top { top = value }
                if value >= limit { wet += 1 }
            }
        }
        let pseudo = wet >= need ? threshold : (wet + unknown >= need ? PushIntensity.unknown : 0)
        return RegionSlotStats(cells: cells, wet: wet, unknown: unknown, maxClass: Int(top), need: need, pseudoClass: pseudo)
    }

    /// Radius in whole kilometres (at least 1) at the latitude of the centre cell; `nil` outside the raster.
    public static func radiusKilometres(radiusCells: Int, cellX: Int, cellY: Int, width: Int) -> Int? {
        guard let c = PushGrid.coordinate(cellX: cellX, cellY: cellY, width: width) else { return nil }
        return max(1, Int((Double(radiusCells) * PushGrid.cellKilometres(latitude: c.lat, width: width)).rounded()))
    }
}

/// Region fields of the Live Activity `content-state` (additive; absent for point subscriptions).
public struct RegionActivityContent: Sendable, Equatable {
    /// Share of wet cells in slot 0 in percent of all cells of the disc (unknown cells count as not wet: a lower bound).
    public var wetSharePercent: Int
    /// Highest wet share of the slots 0...12 (about the next 60 minutes).
    public var peakSharePercent: Int
    /// Highest known class inside the disc over all 25 slots (replaces the point pixel class in `intensityClass`).
    public var maxClass: Int
    public var radiusKm: Int?
    /// Highest known class of slot 0 (diagnosis trace only, not part of the payload).
    public var currentMaxClass: Int
    /// Slots (about 60 minutes) over which the peak share is taken.
    public static let peakSlots = 13

    static func percent(_ stats: RegionSlotStats) -> Int {
        guard stats.cells > 0, stats.wet > 0 else { return 0 }
        return min(100, max(1, Int((Double(stats.wet) * 100 / Double(stats.cells)).rounded())))
    }

    public init(stats: [RegionSlotStats], radiusKm: Int?) {
        wetSharePercent = stats.first.map(Self.percent) ?? 0
        peakSharePercent = stats.prefix(Self.peakSlots).map(Self.percent).max() ?? 0
        maxClass = stats.map(\.maxClass).max() ?? 0
        currentMaxClass = stats.first?.maxClass ?? 0
        self.radiusKm = radiusKm
    }
}

extension PushIntensity {
    /// Marker of `classMap(_, markUnknown: true)`: the pixel could not be interpreted. Never a real class (0...15).
    static let unknownMark: UInt8 = 255

    /// Class (0...15) of every pixel; neighbouring pixels of the same colour are classified once.
    /// `markUnknown`: mask pixels (alpha 16...127) and colours outside the legend become `unknownMark` instead of 0 (Live Activity regions).
    static func classMap(_ image: RGBAImage, markUnknown: Bool = false) -> [UInt8] {
        var map = [UInt8](repeating: 0, count: image.width * image.height)
        var lastKey: UInt32 = 0, lastClass: UInt8 = 0, have = false
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<map.count {
                let o = i * 4
                if p[o + 3] < UInt8(minAlpha) {
                    map[i] = markUnknown && p[o + 3] >= UInt8(transparentAlpha) ? unknownMark : 0
                    continue
                }
                let key = UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2])
                if !have || key != lastKey {
                    lastKey = key; have = true
                    let value = classify(r: p[o], g: p[o + 1], b: p[o + 2], a: p[o + 3])
                    lastClass = value == 0 && markUnknown ? unknownMark : UInt8(value)
                }
                map[i] = lastClass
            }
        }
        return map
    }
}
