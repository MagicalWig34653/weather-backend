import Foundation

// Read side of the hourly statistics (`stats_hourly`, 72 h) for the insights (WP12). Hours are UTC, serialized as
// `yyyy-MM-ddTHH:00:00Z`; ranges are inclusive, at most `StatsQuery.maxHours` hours, hours without data are present.
// Durations are in seconds (latency, ingest lag and duration alike), bucket resolution only.

public enum StatsQueryError: Error, Equatable { case unknownMetric }

public struct StatsHourValues: Codable, Sendable, Equatable {
    public let hour: String
    public let values: [StatsValue]
}

public struct StatsHourly: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    public let hours: [StatsHourValues]
}

public struct HourPoint: Codable, Sendable, Equatable {
    public let hour: String
    public let total: Int
    /// Value per full label (e.g. `radar_image:2xx`).
    public let byLabel: [String: Int]
    /// Value per label part before the first colon (route group or layer); the whole label when there is no colon.
    public let byGroup: [String: Int]
}

public struct HourlySeries: Codable, Sendable, Equatable {
    public let metric: String
    public let from: String
    public let to: String
    public let points: [HourPoint]
}

public struct BucketCount: Codable, Sendable, Equatable {
    public let bucket: String
    public let count: Int
}

/// Distribution of one key (route group or layer) summed over the range. `p50`/`p95`/`p99` are upper bounds of the bucket that
/// contains the quantile (seconds); nil without samples. `overflow` is set when a quantile lies in the open last bucket
/// (the value is then its lower bound, the true value is at least that).
public struct DistributionSummary: Codable, Sendable, Equatable {
    public let key: String
    public let count: Int
    public let buckets: [BucketCount]
    public let p50: Double?
    public let p95: Double?
    public let p99: Double?
    public let overflow: Bool
}

public struct DistributionReport: Codable, Sendable, Equatable {
    public let metric: String
    public let unit: String
    public let from: String
    public let to: String
    /// Ascending by key.
    public let entries: [DistributionSummary]
}

public struct DistributionPoint: Codable, Sendable, Equatable {
    public let hour: String
    public let count: Int
    public let p50: Double?
    public let p95: Double?
    public let p99: Double?
    public let overflow: Bool
}

public struct DistributionSeries: Codable, Sendable, Equatable {
    public let metric: String
    public let key: String
    public let unit: String
    public let from: String
    public let to: String
    public let points: [DistributionPoint]
}

public extension StatsQuery {
    /// Longest range of one hourly query (retention is 72 h; the cap protects against absurd ranges).
    static let maxHours = 168

    private static func hours(from: Date, to: Date) -> [Date] {
        let start = DashboardValidation.hourStart(from), end = DashboardValidation.hourStart(to)
        var result: [Date] = []
        var h = start
        while h <= end, result.count < maxHours {
            result.append(h)
            h = h.addingTimeInterval(3600)
        }
        return result
    }

    private func hourRows(from: Date, to: Date, metrics: Set<String>? = nil) async throws -> (hours: [Date], byHour: [Date: [StatHourRow]]) {
        let list = Self.hours(from: from, to: to)
        guard let first = list.first, let last = list.last else { return ([], [:]) }
        let rows = try await repo.statsHourly(from: first, to: last).filter { metrics?.contains($0.metric) ?? true }
        return (list, Dictionary(grouping: rows, by: \.hour))
    }

    private static func iso(_ date: Date) -> String { TimeUtil.toISO(date) }

    /// All hourly counters of the range (optionally only some metrics).
    func hourly(from: Date, to: Date, metrics: Set<String>? = nil) async throws -> StatsHourly {
        let (list, byHour) = try await hourRows(from: from, to: to, metrics: metrics)
        let hours = list.map { h in
            StatsHourValues(hour: Self.iso(h), values: (byHour[h] ?? []).map { StatsValue(metric: $0.metric, label: $0.label, value: $0.value) }
                .sorted { ($0.metric, $0.label) < ($1.metric, $1.label) })
        }
        return StatsHourly(from: list.first.map(Self.iso) ?? "", to: list.last.map(Self.iso) ?? "", hours: hours)
    }

    /// One metric per hour, summed and split by label / group (e.g. `requests`, `errors_5xx`, `ingest_run`, `cache_hit`).
    func hourlySeries(metric: String, from: Date, to: Date) async throws -> HourlySeries {
        let (list, byHour) = try await hourRows(from: from, to: to, metrics: [metric])
        let points = list.map { h -> HourPoint in
            var byLabel: [String: Int] = [:], byGroup: [String: Int] = [:]
            for r in byHour[h] ?? [] {
                byLabel[r.label, default: 0] += r.value
                byGroup[String(r.label.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""), default: 0] += r.value
            }
            return HourPoint(hour: Self.iso(h), total: byLabel.values.reduce(0, +), byLabel: byLabel, byGroup: byGroup)
        }
        return HourlySeries(metric: metric, from: list.first.map(Self.iso) ?? "", to: list.last.map(Self.iso) ?? "", points: points)
    }

    private static func split(label: String) -> (key: String, bucket: String)? {
        guard let colon = label.lastIndex(of: ":") else { return nil }
        return (String(label[..<colon]), String(label[label.index(after: colon)...]))
    }

    /// Bucket distribution with P50/P95/P99 per key over the range, for `latency` (key = route group),
    /// `ingest_lag` and `ingest_dur` (key = `radar` or layer id). Throws `unknownMetric` for other metrics.
    func distribution(metric: String, from: Date, to: Date) async throws -> DistributionReport {
        guard let scheme = StatsBuckets.scheme(for: metric) else { throw StatsQueryError.unknownMetric }
        let (list, byHour) = try await hourRows(from: from, to: to, metrics: [metric])
        var counts: [String: [String: Int]] = [:]
        for r in byHour.values.joined() {
            guard let (key, bucket) = Self.split(label: r.label) else { continue }
            counts[key, default: [:]][bucket, default: 0] += r.value
        }
        let entries = counts.keys.sorted().map { key -> DistributionSummary in
            let c = counts[key]!
            let q = scheme.quantiles(c, [0.5, 0.95, 0.99])
            return DistributionSummary(key: key, count: scheme.names.reduce(0) { $0 + (c[$1] ?? 0) },
                                       buckets: scheme.names.map { BucketCount(bucket: $0, count: c[$0] ?? 0) },
                                       p50: q.values[0], p95: q.values[1], p99: q.values[2], overflow: q.overflow)
        }
        return DistributionReport(metric: metric, unit: "s", from: list.first.map(Self.iso) ?? "", to: list.last.map(Self.iso) ?? "", entries: entries)
    }

    /// Quantiles per hour for one key (e.g. `latency` of `radar_image`), for line charts.
    func distributionSeries(metric: String, key: String, from: Date, to: Date) async throws -> DistributionSeries {
        guard let scheme = StatsBuckets.scheme(for: metric) else { throw StatsQueryError.unknownMetric }
        let (list, byHour) = try await hourRows(from: from, to: to, metrics: [metric])
        let points = list.map { h -> DistributionPoint in
            var c: [String: Int] = [:]
            for r in byHour[h] ?? [] {
                guard let (k, bucket) = Self.split(label: r.label), k == key else { continue }
                c[bucket, default: 0] += r.value
            }
            let q = scheme.quantiles(c, [0.5, 0.95, 0.99])
            return DistributionPoint(hour: Self.iso(h), count: scheme.names.reduce(0) { $0 + (c[$1] ?? 0) },
                                     p50: q.values[0], p95: q.values[1], p99: q.values[2], overflow: q.overflow)
        }
        return DistributionSeries(metric: metric, key: key, unit: "s", from: list.first.map(Self.iso) ?? "",
                                  to: list.last.map(Self.iso) ?? "", points: points)
    }
}
