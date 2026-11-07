import Foundation

/// Warning routes: `GET /v1/warnings/active` (public, via `Api`) and the warning subscription routes under
/// `/v1/push/installations/<id>/warn-subscriptions` (called by `PushApi` after authentication). Only warning cell ids are handled.
enum WarnApi {
    static let activeCacheControl = "public, max-age=30"

    private static func json(_ status: Int, _ object: Any? = nil, cache: String = "no-store") -> ApiResponse {
        var headers = [("Cache-Control", cache), ("X-Content-Type-Options", "nosniff")]
        guard let object else { return ApiResponse(status: status, headers: headers, body: []) }
        headers.append(("Content-Type", "application/json"))
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return ApiResponse(status: status, headers: headers, body: Array(data))
    }
    static func error(_ status: Int, _ code: String) -> ApiResponse { json(status, ["error": code]) }

    /// `en` when the header's first language tag is English, else German.
    static func language(acceptLanguage: String?) -> String {
        guard let first = acceptLanguage?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return "de" }
        return first == "en" || first.hasPrefix("en-") || first.hasPrefix("en;") ? "en" : "de"
    }

    static func active(repo: any Repo, now: Date, acceptLanguage: String?) async throws -> ApiResponse {
        guard let fetched = try await repo.warnFetchedAt() else { return error(503, "warnings_unavailable") }
        let lang = language(acceptLanguage: acceptLanguage)
        let warnings = try await repo.activeAlerts(now: now, lang: lang).map { stored -> [String: Any] in
            let a = stored.alert
            return ["id": a.identifier, "kind": a.kind.rawValue, "severity": a.severity, "event": a.event, "sent": TimeUtil.toISO(a.sent),
                    "onset": TimeUtil.toISO(a.onset), "expires": TimeUtil.toISO(a.expires), "headline": a.headline, "text": a.text,
                    "instruction": a.instruction, "lang": a.lang, "warncell_ids": a.warncellIDs.sorted()]
        }
        var response = json(200, ["schema": 1, "source": "dwd", "fetched_at": TimeUtil.toISO(fetched), "warnings": warnings], cache: activeCacheControl)
        response.headers.append(("Vary", "Accept-Language"))
        return response
    }

    // MARK: subscriptions

    static func decode(_ body: [UInt8]) -> WarnSubscriptionInput? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any],
              let cells = object["warncell_ids"] as? [Any], (1...WarnLimits.maxCellsPerSubscription).contains(cells.count),
              let types = object["types"] as? [Any], !types.isEmpty else { return nil }
        var ids: [String] = []
        for cell in cells {
            guard let id = cell as? String, id.utf8.count == 9, id.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            ids.append(id)
        }
        guard Set(ids).count == ids.count else { return nil }
        var kinds = Set<WarnKind>()
        for type in types {
            guard let raw = type as? String, let kind = WarnKind(rawValue: raw) else { return nil }
            kinds.insert(kind)
        }
        var minimum = WarnEvaluator.defaultMinSeverity
        if let raw = object["min_severity"] {
            guard let map = raw as? [String: Any] else { return nil }
            for (key, value) in map {
                guard let kind = WarnKind(rawValue: key), let n = jsonWholeNumber(value), (1...4).contains(n) else { return nil }
                minimum[kind] = n
            }
        }
        var enabled = true, timeSensitive = false
        if let raw = object["enabled"] { guard let v = bool(raw) else { return nil }; enabled = v }
        if let raw = object["time_sensitive"] { guard let v = bool(raw) else { return nil }; timeSensitive = v }
        return WarnSubscriptionInput(warncellIDs: ids, types: kinds, minSeverity: minimum, enabled: enabled, timeSensitive: timeSensitive)
    }

    private static func bool(_ raw: Any) -> Bool? { (raw as? NSNumber).flatMap { isJSONBool($0) ? $0.boolValue : nil } }

    static func describe(_ sub: WarnSubscription) -> [String: Any] {
        let i = sub.input
        return ["id": sub.id, "warncell_ids": i.warncellIDs.sorted(), "types": i.types.map(\.rawValue).sorted(),
                "min_severity": Dictionary(uniqueKeysWithValues: WarnKind.allCases.map { ($0.rawValue, i.minSeverity[$0] ?? WarnEvaluator.defaultMinSeverity[$0] ?? 1) }),
                "enabled": i.enabled, "time_sensitive": i.timeSensitive]
    }

    static func list(repo: any Repo, installID: String) async throws -> ApiResponse {
        json(200, try await repo.warnSubscriptions(installationID: installID).map(describe))
    }

    static func create(repo: any Repo, installID: String, body: [UInt8], now: Date) async throws -> ApiResponse {
        guard let input = decode(body) else { return error(400, "invalid_warn_subscription") }
        let id = UUID().uuidString.lowercased()
        switch try await repo.addWarnSubscription(installationID: installID, id: id, input, now: now) {
        case .added: return json(201, ["id": id])
        case .limit: return error(409, "warn_limit")
        case .unknownCell: return error(409, "warncell_unknown")
        case .unknownInstallation: return error(401, "unauthorized")
        }
    }

    static func replace(repo: any Repo, installID: String, subID: String, body: [UInt8]) async throws -> ApiResponse {
        guard let input = decode(body) else { return error(400, "invalid_warn_subscription") }
        switch try await repo.updateWarnSubscription(installationID: installID, id: subID, input) {
        case .updated: return json(204)
        case .notFound: return error(404, "not_found")
        case .limit: return error(409, "warn_limit")
        case .unknownCell: return error(409, "warncell_unknown")
        }
    }

    static func delete(repo: any Repo, installID: String, subID: String) async throws -> ApiResponse {
        try await repo.deleteWarnSubscription(installationID: installID, id: subID) ? json(204) : error(404, "not_found")
    }
}
