import Foundation

/// `Series` of the contract: ascending by interval start, gaps are `v: nil`.
public struct InsightsSeries: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var t: Date
        public var v: Double?
        public init(t: Date, v: Double?) { self.t = t; self.v = v }
    }
    /// `hour` or `day`.
    public var resolution: String
    public var points: [Point]
    public init(resolution: String, points: [Point]) { self.resolution = resolution; self.points = points }

    var ij: IJ {
        .object(["resolution": .string(resolution),
                 "points": .array(points.map { p in
                     .object(["t": .date(p.t), "v": p.v.map { v in v == v.rounded() && abs(v) < 1e15 ? IJ.int(Int(v)) : IJ.ratio(v) } ?? .null])
                 })])
    }
}

/// One counter value at the start of its interval (hour or day).
struct InsightsSample: Sendable {
    let t: Date
    let metric: String
    let label: String
    let value: Int
}

/// Counters of one time window on one grid (hour or day). Gaps in the grid are intervals without any sample.
struct InsightsWindow: Sendable {
    let resolution: String
    let starts: [Date]
    private let byTime: [Date: [InsightsSample]]

    init(resolution: String, starts: [Date], samples: [InsightsSample]) {
        self.resolution = resolution
        self.starts = starts
        let set = Set(starts)
        byTime = Dictionary(grouping: samples.filter { set.contains($0.t) }, by: { $0.t })
    }

    var samples: [InsightsSample] { starts.flatMap { byTime[$0] ?? [] } }

    func has(_ metric: String) -> Bool { samples.contains { $0.metric == metric } }

    func sum(_ metric: String, where label: (String) -> Bool = { _ in true }) -> Int {
        samples.reduce(0) { $0 + ($1.metric == metric && label($1.label) ? $1.value : 0) }
    }

    /// Series of a per-interval value. No sample of `presence` anywhere: empty `points` (not collected / no traffic at all).
    /// Intervals without a `presence` sample are gaps (`nil`).
    func series(presence: String, _ value: ([InsightsSample]) -> Double?) -> InsightsSeries {
        guard has(presence) else { return InsightsSeries(resolution: resolution, points: []) }
        return InsightsSeries(resolution: resolution, points: starts.map { t in
            let s = byTime[t] ?? []
            return InsightsSeries.Point(t: t, v: s.contains { $0.metric == presence } ? value(s) : nil)
        })
    }

    func sumSeries(_ metric: String, where label: @escaping (String) -> Bool = { _ in true }, presence: String? = nil) -> InsightsSeries {
        series(presence: presence ?? metric) { s in
            Double(s.reduce(0) { $0 + ($1.metric == metric && label($1.label) ? $1.value : 0) })
        }
    }

    /// Shifted copy: the window before this one with the same grid length.
    func previous(samples all: [InsightsSample]) -> InsightsWindow {
        let step: TimeInterval = resolution == "hour" ? 3600 : 86400
        let shift = Double(starts.count) * step
        return InsightsWindow(resolution: resolution, starts: starts.map { $0.addingTimeInterval(-shift) }, samples: all)
    }
}

enum InsightsMath {
    static func ratio(_ part: Int, of total: Int) -> Double? { total > 0 ? Double(part) / Double(total) : nil }

    /// Change against the previous window in percent, one decimal; nil without a usable base.
    static func deltaPct(current: Double, previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return round((current - previous) / previous * 1000) / 10
    }
}

/// k-anonymity for distributions (docs-site/content/dashboard-api.md): groups with `0 < count < k` are suppressed; when exactly
/// one group is suppressed, the smallest remaining non-empty group is suppressed as well (complementary suppression).
/// Empty groups (count 0) disclose nothing and stay visible.
enum InsightsSuppression {
    static func buckets(_ counts: [(key: String, count: Int)], k: Int) -> [IJ] {
        var hidden = counts.map { $0.count > 0 && $0.count < k }
        if hidden.filter({ $0 }).count == 1 {
            let candidate = counts.indices.filter { !hidden[$0] && counts[$0].count > 0 }.min { counts[$0].count < counts[$1].count }
            if let candidate { hidden[candidate] = true }
        }
        return zip(counts, hidden).map { c, h in
            .object(["key": .string(c.key), "count": h ? .null : .int(c.count), "suppressed": .bool(h)])
        }
    }

    /// Fixed key order, counts looked up (missing = 0).
    static func buckets(keys: [String], _ counts: [String: Int], k: Int) -> [IJ] {
        buckets(keys.map { ($0, counts[$0] ?? 0) }, k: k)
    }

    /// A share is only published when the base reaches `k` and neither the part nor the rest is a number below `k` (0 is fine):
    /// otherwise the ratio itself reveals a small count (1 of 40 = 0.025) or, through the rest, the complementary one.
    static func share(_ part: Int, of base: Int, k: Int) -> IJ {
        let rest = base - part
        guard base >= k, part >= 0, rest >= 0, part == 0 || part >= k, rest == 0 || rest >= k else { return .null }
        return .ratio(Double(part) / Double(base))
    }
}
