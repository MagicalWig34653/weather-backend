import Foundation
import Testing
@testable import RadarCore

// Diagnosis export (GET /dash/api/diagnose): fields, session guard, privacy. Memory always, MariaDB when RADAR_TEST_DB_HOST is set
// (disposable database only). Nested in DatabaseSuites: the database suites share one test database.
private let origin = "https://dash.example.test"
private let installID = "11111111-1111-4111-8111-111111111111"
private let secretHash = Hashing.sha256Hex(Array("diagnose-secret".utf8))
private let deviceToken = String(repeating: "ab", count: 32)
private let replicaName = "replica-host-name-0"
private let revision = "0123456789abcdef0123456789abcdef01234567"

extension DatabaseSuites {
@Suite("Diagnose export", .serialized)
struct DiagnoseExportTests {
    private struct Rig {
        let api: DashboardApi
        let repo: any Repo
        let cookie: String
        let now = Date()

        init(kind: RepoKind) async throws {
            repo = try await kind.make()
            let env = ["BUILD_REVISION": revision, "RADAR_REPLICAS": "2", "LAYERS": "pressure,lightning", "DASH_DB_PASSWORD": "must-not-leak"]
            let store = try await ConfigStore(env: env, repo: repo)
            let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: origin, rpID: "dash.example.test"), log: { _ in })
            let dir = NSTemporaryDirectory() + "dash-static-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            api = DashboardApi(auth: auth, repo: repo, store: store, env: env, staticRoot: dir,
                               processCache: { SlotCacheSnapshot(bytes: 1234, entries: 3, maxBytes: 64 * 1024 * 1024) })
            _ = try await repo.insertCredential(credentialID: [1, 2, 3], publicKey: [4], signCount: 0, now: now)
            cookie = "__Host-dash_session=" + (try await auth.sessions.create()).cookieValue
        }

        func get(session: Bool = true) async -> (status: Int, body: String, json: [String: Any]) {
            let info = DashboardRequestInfo(method: "GET", cookieHeader: session ? cookie : nil, origin: nil, host: "dash.example.test",
                                            contentType: nil, csrfToken: nil)
            let r = await api.handle(DashboardHTTPRequest(method: "GET", path: "/dash/api/diagnose", info: info))
            let json = (try? JSONSerialization.jsonObject(with: Data(r.body))) as? [String: Any] ?? [:]
            return (r.status, String(decoding: r.body, as: UTF8.self), json)
        }

        func seed() async throws {
            let t = TimeUtil.floor(now, to: 300)
            let id = TimeUtil.toID(t)
            #expect(try await repo.tryClaim(runID: id, nominal: t, owner: "seed", leaseSeconds: 600, maxAttempts: 4, backfill: false))
            try await repo.putSlot(SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: t), contentType: "image/webp", data: [1, 2, 3])
            #expect(try await repo.publish(runID: id, owner: "seed", expectedSlots: 1))
            let older = t.addingTimeInterval(-600)
            let failedID = TimeUtil.toID(older)
            #expect(try await repo.tryClaim(runID: failedID, nominal: older, owner: "seed", leaseSeconds: 600, maxAttempts: 4, backfill: false))
            try await repo.fail(runID: failedID, owner: "seed", cooldownSeconds: 0)
            #expect(try await repo.acquireLeader(name: "layer:pressure", owner: replicaName, leaseSeconds: 300))
            try await repo.addStats(day: now, [StatDelta(metric: "cache_hit", label: "radar:memory", value: 7),
                                               StatDelta(metric: "ingest_run", label: "radar:ok", value: 4)])
            try await repo.addStatsHourly(hour: now, [StatDelta(metric: "ingest_run", label: "radar:error", value: 2),
                                                      StatDelta(metric: "ingest_run", label: "radar:missed", value: 1)])
            try await repo.heartbeat(replicaID: replicaName, slot: 1, appliedGeneration: 0, push: nil, now: now)
            try await repo.reportCacheFill(replicaID: replicaName, fill: ReplicaCacheFill(bytes: 999, entries: 2, maxBytes: 5000), now: now)
            _ = try await repo.upsertInstallation(id: installID, secretHash: secretHash, token: deviceToken, env: .production, locale: "de", now: now)
        }
    }

    @Test(arguments: RepoKind.allCases) func requiresDashboardSession(kind: RepoKind) async throws {
        let rig = try await Rig(kind: kind)
        try await rig.seed()
        let denied = await rig.get(session: false)
        #expect(denied.status == 401)
        #expect(!denied.body.contains("replicas"))
    }

    @Test(arguments: RepoKind.allCases) func exportHasOperationalFields(kind: RepoKind) async throws {
        let rig = try await Rig(kind: kind)
        try await rig.seed()
        let r = await rig.get()
        #expect(r.status == 200)
        let j = r.json
        #expect((j["generatedAt"] as? String)?.hasSuffix("Z") == true)
        #expect(j["version"] as? [String: Any] != nil)
        #expect((j["version"] as? [String: Any])?["commit"] as? String == String(revision.prefix(12)))

        let config = try #require(j["config"] as? [String: Any])
        #expect(config["layers"] as? [String] == ["pressure", "lightning"])
        #expect(config["imageWidth"] as? Int == 1024 && config["cacheMaxMB"] as? Int == 64 && config["radarReplicas"] as? String == "2")

        let replicas = try #require(j["replicas"] as? [[String: Any]])
        #expect(replicas.count == 1 && (replicas[0]["startedAt"] as? String)?.hasSuffix("Z") == true)

        let layers = try #require(j["layers"] as? [[String: Any]])
        let radar = try #require(layers.first { $0["id"] as? String == "radar" })
        #expect((radar["lastPublishedAt"] as? String)?.hasSuffix("Z") == true)
        #expect(radar["ageMinutes"] as? Int != nil)
        let runs = try #require(radar["runs6h"] as? [String: Int])
        #expect(runs["published"] == 1 && runs["failed"] == 1)
        let errors = try #require(radar["errors24h"] as? [String: Int])
        #expect(errors["error"] == 2 && errors["missed"] == 1)
        let pressure = try #require(layers.first { $0["id"] as? String == "pressure" })
        let lock = try #require(pressure["lock"] as? [String: Any])
        #expect(lock["owner"] as? String != nil && lock["leaseUntil"] as? String != nil)

        let cache = try #require(j["cache"] as? [String: Any])
        let local = try #require(cache["thisReplica"] as? [String: Any])
        #expect(local["bytes"] as? Int == 1234 && local["entries"] as? Int == 3)
        let perReplica = try #require(cache["replicas"] as? [[String: Any]])
        #expect(perReplica.first?["bytes"] as? Int == 999)
        #expect((cache["note"] as? String)?.isEmpty == false)   // hits/misses are cluster-wide, said openly

        let daily = try #require(j["statsDaily"] as? [[String: Any]])
        #expect(daily.contains { $0["label"] as? String == "radar:memory" && $0["metric"] as? String == "cache_hit" && $0["value"] as? Int == 7 })

        let logs = try #require(j["logs"] as? [String: Any])
        #expect(logs["available"] as? Bool == false && (logs["reason"] as? String)?.isEmpty == false)
    }

    @Test(arguments: RepoKind.allCases) func exportContainsNoPersonalDataOrSecrets(kind: RepoKind) async throws {
        let rig = try await Rig(kind: kind)
        try await rig.seed()
        let body = await rig.get().body
        for forbidden in [installID, secretHash, deviceToken, replicaName, "must-not-leak", "DB_PASSWORD", "127.0.0.1", "dash.example.test", revision] {
            #expect(!body.contains(forbidden), "export leaks \(forbidden)")
        }
        #expect(!body.lowercased().contains("token"))
    }
}
}
