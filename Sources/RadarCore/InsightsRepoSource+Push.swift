import Foundation

// Push counters of the insights (WP11b metrics, see `PushObserver`). Hourly ranges read `stats_hourly`, the longer ranges the day
// counters. Everything is summed per fixed label; counters that nothing counts yet stay `nil` (`timing`, `registrations`).

extension RepoInsightsDataSource {
    struct CounterRow { let metric: String; let label: String; let value: Int }

    /// APNs reasons that point at a broken sender setup (key, topic, environment), not at one bad device.
    static let criticalApnsReasons: Set<String> = [
        "InvalidProviderToken", "ExpiredProviderToken", "MissingProviderToken", "MissingTopic", "TopicDisallowed", "BadTopic",
        "BadEnvironmentKeyIdInToken", "Forbidden", "BadCertificate", "BadCertificateEnvironment", "DeviceTokenNotForTopic",
    ]
    /// Samples needed before a ratio rule may fire.
    static let minRatioCases = 10

    func counterRows(range: InsightsRange, now: Date) async throws -> [CounterRow] {
        if range.hourly {
            let from = TimeUtil.floor(now, to: 3600).addingTimeInterval(-Double(range.hours - 1) * 3600)
            return try await repo.statsHourly(from: from, to: now).map { CounterRow(metric: $0.metric, label: $0.label, value: $0.value) }
        }
        let endDay = TimeUtil.floor(now, to: 86400)
        return try await repo.stats(from: endDay.addingTimeInterval(-Double(range.days - 1) * 86400), to: endDay)
            .map { CounterRow(metric: $0.metric, label: $0.label, value: $0.value) }
    }

    private static func sum(_ rows: [CounterRow], _ metric: String, where match: (String) -> Bool = { _ in true }) -> Int {
        rows.reduce(0) { $0 + ($1.metric == metric && match($1.label) ? $1.value : 0) }
    }

    private static func grouped(_ rows: [CounterRow], _ metric: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rows where r.metric == metric && r.value > 0 { out[r.label, default: 0] += r.value }
        return out
    }

    /// Splits `a:b[:c]` into at most `parts` pieces (labels are fixed enumerations without further colons).
    private static func split(_ label: String, _ parts: Int) -> [String]? {
        let p = label.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return p.count == parts ? p : nil
    }

    public func pushCounters(range: InsightsRange, now: Date) async throws -> InsightsPushCounters? {
        let rows = try await counterRows(range: range, now: now)
        var c = InsightsPushCounters()
        let sorted = { (a: String, b: String) in a < b }
        c.triggers = Self.grouped(rows, "push_trigger").sorted { sorted($0.key, $1.key) }.map { (trigger: $0.key, count: $0.value) }
        c.skipped = Self.grouped(rows, "push_skipped").sorted { sorted($0.key, $1.key) }.compactMap { k, v in
            Self.split(k, 2).map { (trigger: $0[0], reason: $0[1], count: v) }
        }
        c.lifecycleEvents = Self.grouped(rows, "la_event").sorted { sorted($0.key, $1.key) }.compactMap { k, v in
            Self.split(k, 2).map { (event: $0[0], outcome: $0[1], count: v) }
        }
        c.apnsErrors = Self.grouped(rows, "apns_error").sorted { sorted($0.key, $1.key) }.compactMap { k, v in
            Self.split(k, 3).map { (kind: $0[0], reason: $0[1], env: $0[2], count: v) }
        }
        c.tokenInvalidations = Self.grouped(rows, "token_invalidated").sorted { sorted($0.key, $1.key) }.compactMap { k, v in
            Self.split(k, 2).map { (kind: $0[0], cause: $0[1], count: v) }
        }
        c.rejects = Self.grouped(rows, "push_api_reject").sorted { sorted($0.key, $1.key) }.map { (code: $0.key, count: $0.value) }

        // delivery (alerts): rejected includes devices that were unregistered by APNs.
        let sent = Self.sum(rows, "push_sent"), failed = Self.grouped(rows, "push_failed")
        let rejected = (failed["rejected"] ?? 0) + (failed["unregistered"] ?? 0), dropped = failed["dropped"] ?? 0, retry = failed["retry"] ?? 0
        let final = sent + rejected + dropped
        c.delivery = InsightsPushCounters.Delivery(
            created: Self.sum(rows, "push_created"), sent: sent, delivered: sent, rejected: rejected, dropped: dropped, retry: retry,
            ratio: final > 0 ? Double(sent) / Double(final) : nil,
            avgAttempts: final > 0 ? Double(Self.sum(rows, "push_attempt")) / Double(final) : nil)

        // Rule inputs: always the last 24 hours / the last two hour buckets, independent of the requested range.
        let hourRows = try await counterRows(range: .h24, now: now)
        let curHour = TimeUtil.floor(now, to: 3600)
        let recent = try await repo.statsHourly(from: curHour.addingTimeInterval(-3600), to: now)
            .map { CounterRow(metric: $0.metric, label: $0.label, value: $0.value) }
        let sent1 = Self.sum(recent, "push_sent"), failed1 = Self.sum(recent, "push_failed")
        let bad1 = Self.sum(recent, "push_failed") { $0 != "unregistered" && $0 != "retry" } + Self.sum(recent, "la_event") { !$0.hasSuffix(":delivered") && !$0.hasSuffix(":retry") }
        let total1 = sent1 + failed1 + Self.sum(recent, "la_event")
        if total1 >= Self.minRatioCases { c.apnsRejectionRatio1h = Double(bad1) / Double(total1) }
        c.apnsCriticalReasons1h = Self.sum(recent, "apns_error") { label in
            Self.split(label, 3).map { Self.criticalApnsReasons.contains($0[1]) } ?? false
        }
        let total24 = Self.sum(hourRows, "push_sent") + Self.sum(hourRows, "push_failed") + Self.sum(hourRows, "la_event")
        if total24 >= Self.minRatioCases { c.tokenInvalidationRatio24h = Double(Self.sum(hourRows, "token_invalidated")) / Double(total24) }
        // Denominator = Live-Activity starts that were actually sent (a trigger that the lock or hysteresis suppressed is no failure).
        c.laStartTriggers24h = Self.sum(hourRows, "la_event") { $0.hasPrefix("start:") }
        c.laStartDelivered24h = Self.sum(hourRows, "la_event") { $0 == "start:delivered" }
        return c
    }
}
