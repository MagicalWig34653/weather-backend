import Foundation

/// `radar check-config`: validates the operator environment exactly like `serve` does at start (same loader, same LAYERS parser, same
/// cross-field rules) but without database, network or secret files. Used by `deploy/swarm/update.sh` with the NEW image before the
/// migration and the rolling update, so that a value the new image refuses stops the update instead of a rollback after the rollout.
public enum ConfigCheck {
    public struct Result: Sendable, Equatable {
        public let ok: Bool
        public let lines: [String]
    }

    /// Secret files are mounted by Swarm only; they do not exist in a plain `docker run`. Their content is not part of this check:
    /// the DB password file is dropped and a push key placeholder stands in when push is on (the real presence is the deploy's job).
    static func prepared(_ env: [String: String]) -> [String: String] {
        var e = env
        e["DB_PASSWORD_FILE"] = nil
        e["APNS_KEY_FILE"] = nil
        if (e["PUSH_ENABLED"] ?? "").lowercased() == "true", (e["APNS_KEY"] ?? "").isEmpty { e["APNS_KEY"] = "check-config-placeholder" }
        return e
    }

    public static func run(env: [String: String] = ProcessInfo.processInfo.environment) -> Result {
        var warnings: [String] = []
        do {
            let config = try ConfigRegistry.resolve(env: prepared(env), stored: [:], warn: { warnings.append("warning: \($0)") })
            var lines = warnings
            lines.append("ok: layers=\((["radar"] + config.layers).joined(separator: ",")) push=\(config.push.enabled) width=\(config.width)")
            return Result(ok: true, lines: lines)
        } catch {
            return Result(ok: false, lines: warnings + ["error: \(error)"])
        }
    }
}
