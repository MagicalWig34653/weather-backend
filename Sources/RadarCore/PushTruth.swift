import Foundation

/// What a radar replica publishes about its push configuration with every heartbeat (`config_replica`). Fixed labels only:
/// no key, topic, team or installation data.
public struct PushReplicaReport: Sendable, Equatable {
    public var enabled: Bool
    /// `production`, `sandbox` or `both`; nil when push is off.
    public var environments: String?
    /// Live Activities possible (push on and a topic configured).
    public var liveActivity: Bool
    public init(enabled: Bool, environments: String?, liveActivity: Bool) {
        self.enabled = enabled; self.environments = enabled ? environments : nil; self.liveActivity = enabled && liveActivity
    }

    /// Report of this process (the replica's own effective configuration).
    public init(config: Config) {
        let envs = config.push.environments
        let label = envs.count > 1 ? "both" : (envs.first?.rawValue ?? "production")
        self.init(enabled: config.push.enabled, environments: label, liveActivity: !config.push.topic.isEmpty)
    }

    static func environmentSet(label: String?) -> Set<PushEnvironment>? {
        switch label {
        case "production": return [.production]
        case "sandbox": return [.sandbox]
        case "both": return [.production, .sandbox]
        default: return nil
        }
    }
}

public enum PushStatus: String, Sendable, Equatable {
    /// At least one fresh replica reports push on, or a fresh push leader exists.
    case on
    /// Fresh replicas report, and none has push on (and there is no fresh leader).
    case off
    /// No fresh replica reported (none running, database unreadable, only old replicas): neither on nor off is known.
    case unknown
}

/// The truth about push for the dashboard process: derived from the radar replicas in the shared database, never from the
/// dashboard's own configuration (its `PUSH_ENABLED` is deliberately false in the split deployment).
public struct PushTruth: Sendable, Equatable {
    public var status: PushStatus
    /// APNs environments the active replicas accept; nil when not known (e.g. only the leader lease proves push).
    public var environments: Set<PushEnvironment>?
    public var liveActivity: Bool
    /// A push leader lease is currently valid.
    public var leaderActive: Bool

    /// A heartbeat is valid for three intervals of the restart coordinator (30 s + up to 5 s jitter).
    public static let freshSeconds: TimeInterval = 3 * 35

    public var enabled: Bool { status == .on }

    public static let unknown = PushTruth(status: .unknown, environments: nil, liveActivity: false, leaderActive: false)

    /// Pure rule. `replicas` are the heartbeat rows (any age), `leaderSecondsLeft` the remaining lease (nil = no lease).
    public static func resolve(replicas: [ReplicaRecord], leaderSecondsLeft: Int?, now: Date) -> PushTruth {
        let fresh = replicas.filter { now.timeIntervalSince($0.lastSeenAt) <= freshSeconds }
        let leader = (leaderSecondsLeft ?? 0) > 0
        let active = fresh.compactMap { r in r.push.flatMap { $0.enabled ? $0 : nil } }
        if !active.isEmpty {
            let sets = active.compactMap { PushReplicaReport.environmentSet(label: $0.environments) }
            return PushTruth(status: .on, environments: sets.count == active.count ? sets.reduce(into: Set()) { $0.formUnion($1) } : nil,
                             liveActivity: active.contains { $0.liveActivity }, leaderActive: leader)
        }
        if leader { return PushTruth(status: .on, environments: nil, liveActivity: false, leaderActive: true) }
        if fresh.contains(where: { $0.push != nil }) { return PushTruth(status: .off, environments: nil, liveActivity: false, leaderActive: false) }
        return .unknown
    }

    /// Reads replicas and the leader lease; a database error gives `unknown`.
    public static func resolve(repo: any Repo, now: Date) async -> PushTruth {
        guard let replicas = try? await repo.replicas(now: now) else { return .unknown }
        let lease = (try? await repo.leaderLease(name: PushService.leaderName)) ?? nil
        return resolve(replicas: replicas, leaderSecondsLeft: lease?.secondsLeft, now: now)
    }
}
