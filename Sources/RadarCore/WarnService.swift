import Foundation

/// Trigger for warning pushes (leader only, called with the result of an ingest tick). For every new or changed active warning
/// the matching warning subscriptions are found by warning cell, `WarnEvaluator` decides, and the push goes into the normal outbox
/// (delivery by `PushService`). German and English messages of one warning (`alertKey`) are one decision; each installation gets
/// its own language. Counters use fixed labels only (no area, subscription or warning identifiers).
public final class WarnService: Sendable {
    static let outboxHorizon: TimeInterval = 6 * 3600

    let config: Config
    let repo: any Repo
    let stats: any StatsSink
    let clock: @Sendable () -> Date

    public init(config: Config, repo: any Repo, stats: any StatsSink = NoStatsSink(), clock: @escaping @Sendable () -> Date = Date.init) {
        self.config = config; self.repo = repo; self.stats = stats; self.clock = clock
    }

    private struct Pair { var de: WarnStoredAlert?; var en: WarnStoredAlert? }

    /// Number of queued pushes. 0 and no side effects unless `PUSH_ENABLED` and `WARN_PUSH_ENABLED` are both set.
    public func trigger(_ changed: [WarnStoredAlert]) async throws -> Int {
        guard config.push.enabled, config.warn.pushEnabled, !changed.isEmpty else { return 0 }
        let now = clock()
        var order: [String] = []
        var pairs: [String: Pair] = [:]
        for stored in changed where stored.status == "active" {
            let key = stored.alert.alertKey
            if pairs[key] == nil { order.append(key) }
            if stored.alert.lang == "en" { pairs[key, default: Pair()].en = stored } else { pairs[key, default: Pair()].de = stored }
        }
        var locales: [String: String] = [:]
        var queued = 0
        for key in order {
            guard var pair = pairs[key] else { continue }
            if pair.de == nil, let en = pair.en { pair.de = try await repo.alert(identifier: Self.counterpart(en.alert.identifier, lang: "de")) }
            if pair.en == nil, let de = pair.de { pair.en = try await repo.alert(identifier: Self.counterpart(de.alert.identifier, lang: "en")) }
            guard let primary = pair.de ?? pair.en else { continue }
            queued += try await deliver(primary: primary, pair: pair, key: key, locales: &locales, now: now)
        }
        return queued
    }

    private func deliver(primary: WarnStoredAlert, pair: Pair, key: String, locales: inout [String: String], now: Date) async throws -> Int {
        let alert = primary.alert
        var items: [WarnSendItem] = []
        for sub in try await repo.warnSubscriptions(matching: alert.warncellIDs) {
            let sent = try await repo.warnSent(subID: sub.id)
            let chain = sent.first { $0.chainID == primary.chainID }
            let lastOfKind = sent.filter { $0.kind == alert.kind }.max { $0.lastSentAt < $1.lastSentAt }
            switch WarnEvaluator.decide(sub: sub, alert: alert, chain: chain, lastOfKind: lastOfKind, now: now) {
            case let .suppress(reason):
                stats.record("warn_push", label: "suppressed_" + reason.rawValue)
                continue
            case .send:
                break
            }
            let locale: String
            if let known = locales[sub.installationID] { locale = known }
            else { locale = try await repo.installation(id: sub.installationID)?.locale ?? "de"; locales[sub.installationID] = locale }
            let variant = (locale == "en" ? pair.en ?? pair.de : pair.de ?? pair.en) ?? primary
            guard let payload = WarnPayload.make(alert: variant.alert, subID: sub.id, timeSensitive: sub.input.timeSensitive) else {
                stats.record("warn_push", label: "payload_too_large")
                continue
            }
            items.append(WarnSendItem(
                subID: sub.id,
                record: WarnSentRecord(chainID: primary.chainID, kind: alert.kind, lastSeverity: alert.severity, lastOnset: alert.onset, lastSentAt: now),
                outbox: NewOutboxItem(subID: sub.id, dedupeKey: WarnPayload.dedupeKey(subID: sub.id, alertKey: key),
                                      collapseID: WarnPayload.collapseID(subID: sub.id, kind: alert.kind), payloadJSON: payload,
                                      expiresAt: min(alert.expires, now.addingTimeInterval(Self.outboxHorizon)))))
        }
        guard !items.isEmpty else { return 0 }
        let added = try await repo.commitWarnSend(items, now: now)
        if added > 0 { stats.record("warn_push", label: "sent", by: added) }
        return added
    }

    /// Identifier of the other language (`...DEU` <-> `...ENG`); unchanged when it has no language suffix.
    static func counterpart(_ identifier: String, lang: String) -> String {
        let key = WarnAlert.alertKey(identifier: identifier)
        guard key != identifier else { return identifier }
        return key + (lang == "en" ? ".ENG" : ".DEU")
    }
}
