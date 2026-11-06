import Foundation

/// Fixed bucket scheme of one histogram metric (`latency`, `ingest_lag`, `ingest_dur`). Samples are never stored; only a counter
/// per bucket. Bucket names are part of the label (`<key>:<bucket>`), so the label space is finite and free of identifiers.
public struct StatsBucketScheme: Sendable, Equatable {
    public let metric: String
    /// Upper bounds in seconds (exclusive) of all buckets but the last, ascending.
    public let upperBounds: [Double]
    /// One name per bucket (`upperBounds.count + 1`); the last bucket is open (`ge...`).
    public let names: [String]

    /// Bucket of a duration in seconds; negative values count as 0. NaN has no bucket.
    public func name(forSeconds seconds: Double) -> String? {
        guard !seconds.isNaN else { return nil }
        let s = max(0, seconds)
        for (i, bound) in upperBounds.enumerated() where s < bound { return names[i] }
        return names[names.count - 1]
    }

    /// Estimated quantiles from bucket counts (keys are bucket names): the upper bound of the bucket in which the cumulative count
    /// reaches the quantile. In the open bucket the lower bound is returned and `overflow` is set (the true value is at least that).
    /// Resolution is the bucket width; unknown names are ignored; no samples gives nil.
    public func quantiles(_ counts: [String: Int], _ qs: [Double]) -> (values: [Double?], overflow: Bool) {
        let ordered = names.map { max(0, counts[$0] ?? 0) }
        let total = ordered.reduce(0, +)
        guard total > 0 else { return (qs.map { _ in nil }, false) }
        var overflow = false
        let values: [Double?] = qs.map { q in
            let target = max(1.0, (min(1, max(0, q)) * Double(total)).rounded(.up))
            var cumulative = 0.0
            for (i, c) in ordered.enumerated() {
                cumulative += Double(c)
                if cumulative >= target {
                    if i < upperBounds.count { return upperBounds[i] }
                    overflow = true
                    return upperBounds.last
                }
            }
            return upperBounds.last
        }
        return (values, overflow)
    }
}

public enum StatsBuckets {
    /// Response time per route group.
    public static let latency = StatsBucketScheme(metric: "latency", upperBounds: [0.01, 0.05, 0.2, 1],
                                                  names: ["lt10ms", "lt50ms", "lt200ms", "lt1s", "ge1s"])
    /// Time from the nominal run/slot time to availability in the cache, per layer (`radar` or a layer id).
    public static let ingestLag = StatsBucketScheme(metric: "ingest_lag", upperBounds: [300, 600, 900, 1800, 3600],
                                                    names: ["lt5m", "lt10m", "lt15m", "lt30m", "lt1h", "ge1h"])
    /// Duration of one ingest run (claim to publish), per layer.
    public static let ingestDuration = StatsBucketScheme(metric: "ingest_dur", upperBounds: [10, 30, 60, 120, 300],
                                                         names: ["lt10s", "lt30s", "lt1m", "lt2m", "lt5m", "ge5m"])
    public static let all = [latency, ingestLag, ingestDuration]
    public static func scheme(for metric: String) -> StatsBucketScheme? { all.first { $0.metric == metric } }
}

public extension StatsSink {
    /// Counts one duration sample into the bucket counter of `metric` (`latency`, `ingest_lag`, `ingest_dur`) for `key`
    /// (route group or layer). Unknown metrics/keys are ignored by the sink.
    func observe(_ metric: String, key: String, seconds: Double) {
        guard let scheme = StatsBuckets.scheme(for: metric), let bucket = scheme.name(forSeconds: seconds) else { return }
        record(metric, label: key + ":" + bucket, by: 1)
    }
}
