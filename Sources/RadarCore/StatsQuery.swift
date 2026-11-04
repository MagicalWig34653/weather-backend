import Foundation

/// One counter value of one UTC day (`day` as `yyyy-MM-dd`).
public struct StatsValue: Codable, Sendable, Equatable {
    public let metric: String
    public let label: String
    public let value: Int
}

public struct StatsDayValues: Codable, Sendable, Equatable {
    public let day: String
    public let values: [StatsValue]
}

/// Cache hit rate of one scope (`radar` or `layer`): hits = memory + negative + joined, misses = database reads.
public struct StatsCacheRate: Codable, Sendable, Equatable {
    public let scope: String
    public let hits: Int
    public let misses: Int
    /// `hits / (hits + misses)`, nil without any lookup.
    public let hitRate: Double?
}

public struct StatsOverview: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    /// One entry per day of the range (also days without data), ascending.
    public let days: [StatsDayValues]
    /// Sum over the range per metric and label.
    public let totals: [StatsValue]
    public let cache: [StatsCacheRate]
    public let requests: Int
    public let bytesOut: Int
    public let errors5xx: Int
}

public struct TrafficPoint: Codable, Sendable, Equatable {
    public let day: String
    public let requests: Int
    public let bytesOut: Int
    public let errors5xx: Int
    public let rateLimited: Int
    public let pageViews: Int
    /// Requests per route group (all status classes summed).
    public let byGroup: [String: Int]
}

public struct TrafficSeries: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    public let points: [TrafficPoint]
}

/// Read side of the statistics for the dashboard routes (camelCase JSON). Days are UTC days, range inclusive, at most 366 days.
public struct StatsQuery: Sendable {
    let repo: any DashboardRepo
    public init(repo: any DashboardRepo) { self.repo = repo }

    private static func days(from: Date, to: Date) -> [String] {
        let start = DashboardValidation.date(day: DashboardValidation.day(from)), end = DashboardValidation.date(day: DashboardValidation.day(to))
        var result: [String] = []
        var d = start
        while d <= end, result.count < 366 {
            result.append(DashboardValidation.day(d))
            d = d.addingTimeInterval(86400)
        }
        return result
    }

    private func rows(from: Date, to: Date) async throws -> (days: [String], byDay: [String: [StatRow]]) {
        let list = Self.days(from: from, to: to)
        guard let first = list.first, let last = list.last else { return ([], [:]) }
        let rows = try await repo.stats(from: DashboardValidation.date(day: first), to: DashboardValidation.date(day: last))
        return (list, Dictionary(grouping: rows, by: { DashboardValidation.day($0.day) }))
    }

    public func overview(from: Date, to: Date) async throws -> StatsOverview {
        let (list, byDay) = try await rows(from: from, to: to)
        var totals: [String: StatsValue] = [:]
        var perDay: [StatsDayValues] = []
        for day in list {
            let values = (byDay[day] ?? []).map { StatsValue(metric: $0.metric, label: $0.label, value: $0.value) }
                .sorted { ($0.metric, $0.label) < ($1.metric, $1.label) }
            perDay.append(StatsDayValues(day: day, values: values))
            for v in values {
                let k = v.metric + "\u{0}" + v.label
                totals[k] = StatsValue(metric: v.metric, label: v.label, value: (totals[k]?.value ?? 0) + v.value)
            }
        }
        let sorted = totals.values.sorted { ($0.metric, $0.label) < ($1.metric, $1.label) }
        func sum(_ metric: String) -> Int { sorted.filter { $0.metric == metric }.reduce(0) { $0 + $1.value } }
        var cache: [StatsCacheRate] = []
        for scope in ["radar", "layer"] {
            let hits = sorted.filter { $0.metric == "cache_hit" && $0.label.hasPrefix(scope + ":") }.reduce(0) { $0 + $1.value }
            let misses = sorted.filter { $0.metric == "cache_miss" && $0.label.hasPrefix(scope + ":") }.reduce(0) { $0 + $1.value }
            cache.append(StatsCacheRate(scope: scope, hits: hits, misses: misses, hitRate: hits + misses > 0 ? Double(hits) / Double(hits + misses) : nil))
        }
        return StatsOverview(from: list.first ?? "", to: list.last ?? "", days: perDay, totals: sorted, cache: cache,
                             requests: sum("requests"), bytesOut: sum("bytes_out"), errors5xx: sum("errors_5xx"))
    }

    public func trafficSeries(from: Date, to: Date) async throws -> TrafficSeries {
        let (list, byDay) = try await rows(from: from, to: to)
        let points = list.map { day -> TrafficPoint in
            let rows = byDay[day] ?? []
            func sum(_ metric: String) -> Int { rows.filter { $0.metric == metric }.reduce(0) { $0 + $1.value } }
            var groups: [String: Int] = [:]
            for r in rows where r.metric == "requests" {
                groups[String(r.label.split(separator: ":", maxSplits: 1).first ?? "other"), default: 0] += r.value
            }
            return TrafficPoint(day: day, requests: sum("requests"), bytesOut: sum("bytes_out"), errors5xx: sum("errors_5xx"),
                                rateLimited: sum("rate_limited"), pageViews: sum("page_view"), byGroup: groups)
        }
        return TrafficSeries(from: list.first ?? "", to: list.last ?? "", points: points)
    }
}
