import Foundation

/// Subscription kind: a single raster cell (default, as before) or a circle around a coarse centre cell.
public enum PushKind: Int, Sendable { case point = 0, circle = 1 }

/// Limits for region subscriptions (decisions.md, 1 Nov 2026). The server counts cells itself, from centre and radius.
public struct RegionLimits: Sendable, Equatable {
    public var maxRegionsPerInstallation = 3
    public var maxCellsPerInstallation = 8_000
    public var maxCellsServerwide = 2_000_000
    public init(maxRegionsPerInstallation: Int = 3, maxCellsPerInstallation: Int = 8_000, maxCellsServerwide: Int = 2_000_000) {
        self.maxRegionsPerInstallation = maxRegionsPerInstallation; self.maxCellsPerInstallation = maxCellsPerInstallation
        self.maxCellsServerwide = maxCellsServerwide
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

public enum PushRegionLimitError: Error, Sendable, Equatable { case perInstallation, capacity }

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
            for x in run.x0...run.x1 where classMap[base + x] >= limit { wet += 1 }
            if wet >= need { return threshold }
        }
        return 0
    }
}

extension PushIntensity {
    /// Class (0...15) of every pixel; neighbouring pixels of the same colour are classified once.
    static func classMap(_ image: RGBAImage) -> [UInt8] {
        var map = [UInt8](repeating: 0, count: image.width * image.height)
        var lastKey: UInt32 = 0, lastClass: UInt8 = 0, have = false
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<map.count {
                let o = i * 4
                if p[o + 3] < UInt8(minAlpha) { map[i] = 0; continue }
                let key = UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2])
                if !have || key != lastKey {
                    lastKey = key; have = true
                    lastClass = UInt8(classify(r: p[o], g: p[o + 1], b: p[o + 2], a: p[o + 3]))
                }
                map[i] = lastClass
            }
        }
        return map
    }
}
