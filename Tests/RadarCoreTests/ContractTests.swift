import Foundation
import Testing
@testable import RadarCore

private func ingestor(_ repo: any Repo, owner: String = "a", fetch: Fetch? = nil, edit: (inout Config) -> Void = { _ in })
    -> (Ingestor, Config) {
    let cfg = smallConfig(edit)
    return (Ingestor(config: cfg, repo: repo, fetch: fetch ?? FakeDwd(cfg).fetch, owner: owner, sleep: { _ in }), cfg)
}

private func sleepSeconds(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

private func manifestJSON(_ repo: any Repo, _ cfg: Config) async throws -> [String: Any] {
    let body = try #require(try await Manifest.build(repo: repo, config: cfg))
    return try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
}

extension DatabaseSuites {
@Suite("Repo and service contract", .serialized)
struct ContractTests {
    @Test(arguments: RepoKind.allCases)
    func claimIsExclusiveAndRenewable(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.tryClaim(runID: "r1", nominal: run0, owner: "a", leaseSeconds: 60, maxAttempts: 2))
        #expect(try await !repo.tryClaim(runID: "r1", nominal: run0, owner: "b", leaseSeconds: 60, maxAttempts: 2))
        #expect(try await repo.renew(runID: "r1", owner: "a", leaseSeconds: 60))
        #expect(try await !repo.renew(runID: "r1", owner: "b", leaseSeconds: 60))
    }

    @Test(arguments: RepoKind.allCases)
    func expiredLeaseIsTakenOverOnceAndAttemptsAreCapped(kind: RepoKind) async throws {
        let repo = try await kind.make()
        #expect(try await repo.tryClaim(runID: "r1", nominal: run0, owner: "a", leaseSeconds: 1, maxAttempts: 2))
        await sleepSeconds(2.1)
        #expect(try await repo.tryClaim(runID: "r1", nominal: run0, owner: "b", leaseSeconds: 1, maxAttempts: 2))  // crash takeover
        #expect(try await !repo.tryClaim(runID: "r1", nominal: run0, owner: "c", leaseSeconds: 1, maxAttempts: 2))  // b holds a lease
        #expect(try await !repo.renew(runID: "r1", owner: "a", leaseSeconds: 60))  // a lost it
        await sleepSeconds(2.1)
        #expect(try await !repo.tryClaim(runID: "r1", nominal: run0, owner: "c", leaseSeconds: 1, maxAttempts: 2))  // attempts exhausted
    }

    @Test(arguments: RepoKind.allCases)
    func failedRunHasCooldown(kind: RepoKind) async throws {
        let repo = try await kind.make()
        _ = try await repo.tryClaim(runID: "r1", nominal: run0, owner: "a", leaseSeconds: 60, maxAttempts: 3)
        try await repo.fail(runID: "r1", owner: "a", cooldownSeconds: 1)
        #expect(try await !repo.tryClaim(runID: "r1", nominal: run0, owner: "b", leaseSeconds: 60, maxAttempts: 3))
        await sleepSeconds(2.1)
        #expect(try await repo.tryClaim(runID: "r1", nominal: run0, owner: "b", leaseSeconds: 60, maxAttempts: 3))
    }

    @Test(arguments: RepoKind.allCases)
    func concurrentClaimsHaveASingleWinner(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<8 {
                group.addTask { try await repo.tryClaim(runID: "r1", nominal: run0, owner: "o\(i)", leaseSeconds: 60, maxAttempts: 2) }
            }
            var n = 0
            for try await won in group where won { n += 1 }
            return n
        }
        #expect(wins == 1)
    }

    @Test(arguments: RepoKind.allCases)
    func publishIsAllOrNothingAndHidesUnpublishedData(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let id = "20261030T1105Z"
        _ = try await repo.tryClaim(runID: id, nominal: run0, owner: "a", leaseSeconds: 60, maxAttempts: 2)
        try await repo.putSlot(SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: run0), contentType: "image/webp", data: Array("data".utf8))
        #expect(try await repo.getSlot(runID: id, slotID: id) == nil)  // not visible yet
        #expect(try await !repo.publish(runID: id, owner: "a", expectedSlots: 25))  // incomplete
        #expect(try await !repo.publish(runID: id, owner: "b", expectedSlots: 1))  // not the owner
        #expect(try await repo.latestPublished() == nil)
        #expect(try await repo.publish(runID: id, owner: "a", expectedSlots: 1))
        #expect(try await repo.getSlot(runID: id, slotID: id)?.data == Array("data".utf8))
        #expect(try await repo.latestPublished()?.runID == id)
    }

    @Test(arguments: RepoKind.allCases)
    func blobRoundTripsAllByteValues(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let id = "20261030T1105Z"
        _ = try await repo.tryClaim(runID: id, nominal: run0, owner: "a", leaseSeconds: 60, maxAttempts: 2)
        let data = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
        try await repo.putSlot(SlotRef(runID: id, slotID: id, slotIndex: 0, slotTime: run0), contentType: "image/webp", data: data)
        _ = try await repo.publish(runID: id, owner: "a", expectedSlots: 1)
        let blob = try #require(try await repo.getSlot(runID: id, slotID: id))
        #expect(blob.data == data)
        #expect(blob.sha256 == Hashing.sha256Hex(data))
    }

    @Test(arguments: RepoKind.allCases)
    func fullRunManifestAndHistory(kind: RepoKind) async throws {
        let repo = try await kind.make()
        var cfg = smallConfig()
        for i in 0..<3 {
            let (ing, c) = ingestor(repo); cfg = c
            #expect(try await ing.process(run: run0.addingTimeInterval(Double(i) * 300)))
        }
        let doc = try await manifestJSON(repo, cfg)
        #expect(doc["run"] as? String == "20261030T1115Z")
        let slots = try #require(doc["slots"] as? [[String: String]])
        #expect(slots.count == 2 + 25)
        #expect(slots[0]["path"] == "20261030T1105Z/20261030T1105Z.webp")
        #expect(slots[0]["kind"] == "analysis")
        #expect(slots[2]["kind"] == "analysis")
        #expect(slots.last?["time"] == "2026-10-30T13:15:00Z")
        for slot in slots {
            let parts = slot["path"]!.split(separator: "/")
            let name = parts[1].split(separator: ".")[0]
            #expect(try await repo.getSlot(runID: String(parts[0]), slotID: String(name)) != nil)
        }
        let image = try #require(doc["image"] as? [String: Any])
        #expect(image["width"] as? Int == 256)
        #expect(image["projection"] as? String == "EPSG:3857")
    }

    @Test(arguments: RepoKind.allCases)
    func secondReplicaDoesNotFetchAgain(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig()
        let fakeB = FakeDwd(cfg)
        let (a, _) = ingestor(repo, owner: "a")
        let (b, _) = ingestor(repo, owner: "b", fetch: fakeB.fetch)
        #expect(try await a.process(run: run0))
        #expect(try await !b.process(run: run0))
        #expect(fakeB.callCount == 0)
    }

    @Test(arguments: RepoKind.allCases)
    func xmlErrorIsRetriedBoundedAndFailurePublishesNothing(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig()
        let flaky = FakeDwd(cfg, failures: [1: .xml, 2: .network, 5: .xml])
        let (ing, _) = ingestor(repo, fetch: flaky.fetch)
        #expect(try await ing.process(run: run0))
        #expect(flaky.callCount == 28)

        let dead = FakeDwd(cfg, failAll: true)
        let (ing2, _) = ingestor(repo, owner: "b", fetch: dead.fetch)
        await #expect(throws: RunUnavailable.self) { _ = try await ing2.process(run: run0.addingTimeInterval(300)) }
        #expect(dead.callCount == Ingestor.probeBackoffSeconds.count + 1)
        #expect(try await repo.latestPublished()?.runID == "20261030T1105Z")  // previous publication untouched
    }

    @Test(arguments: RepoKind.allCases)
    func partialFailureDoesNotExposeTheRun(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let cfg = smallConfig()
        var failures: [Int: FakeDwd.Failure] = [:]
        for n in 5..<90 { failures[n] = .xml }
        let (ing, _) = ingestor(repo, fetch: FakeDwd(cfg, failures: failures).fetch)
        await #expect(throws: RunUnavailable.self) { _ = try await ing.process(run: run0) }
        #expect(try await repo.latestPublished() == nil)
        #expect(try await repo.getSlot(runID: "20261030T1105Z", slotID: "20261030T1105Z") == nil)
    }

    @Test(arguments: RepoKind.allCases)
    func retentionKeepsNewestPublishedRunsWithTheirSlots(kind: RepoKind) async throws {
        let repo = try await kind.make()
        var cfg = smallConfig()
        for i in 0..<17 {
            let (ing, c) = ingestor(repo, edit: { $0.retentionRuns = 15 }); cfg = c
            _ = try await ing.process(run: run0.addingTimeInterval(Double(i) * 300))
        }
        // Beyond the newest 15 runs only the analysis slot stays (HISTORY_HOURS, default 48), forecast slots go.
        #expect(try await repo.getSlot(runID: "20261030T1105Z", slotID: "20261030T1105Z") != nil)
        #expect(try await repo.getSlot(runID: "20261030T1105Z", slotID: "20261030T1110Z") == nil)
        #expect(try await repo.getSlot(runID: "20261030T1110Z", slotID: "20261030T1115Z") == nil)
        #expect(try await repo.getSlot(runID: "20261030T1115Z", slotID: "20261030T1120Z") != nil)
        let doc = try await manifestJSON(repo, cfg)
        #expect((doc["slots"] as? [Any])?.count == 12 + 25)
    }

    @Test(arguments: RepoKind.allCases)
    func olderLatestJsonStaysResolvableAfterNewerRuns(kind: RepoKind) async throws {
        let repo = try await kind.make()
        var manifests: [[String: Any]] = []
        for i in 0..<20 {
            let (ing, cfg) = ingestor(repo, edit: { $0.retentionRuns = 15 })
            _ = try await ing.process(run: run0.addingTimeInterval(Double(i) * 300))
            manifests.append(try await manifestJSON(repo, cfg))
        }
        for doc in manifests.suffix(3) {
            for slot in doc["slots"] as! [[String: String]] {
                let parts = slot["path"]!.split(separator: "/")
                let name = String(parts[1].split(separator: ".")[0])
                #expect(try await repo.getSlot(runID: String(parts[0]), slotID: name) != nil, "\(doc["run"]!) \(slot)")
            }
        }
    }

    @Test(arguments: RepoKind.allCases)
    func manifestIsIdenticalForAllReplicas(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let (ing, cfg) = ingestor(repo)
        _ = try await ing.process(run: run0)
        let first = try await Manifest.build(repo: repo, config: cfg)
        #expect(first == (try await Manifest.build(repo: repo, config: cfg)))
        let a = Api(repo: repo, config: cfg), b = Api(repo: repo, config: cfg)
        let etagA = try await a.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil).headers.first { $0.0 == "ETag" }?.1
        let etagB = try await b.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil).headers.first { $0.0 == "ETag" }?.1
        #expect(etagA != nil && etagA == etagB)
    }

    @Test(arguments: RepoKind.allCases)
    func httpEtag304CacheHeadersAndRouting(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let (ing, cfg) = ingestor(repo)
        _ = try await ing.process(run: run0)
        let api = Api(repo: repo, config: cfg)
        func header(_ r: ApiResponse, _ n: String) -> String? { r.headers.first { $0.0 == n }?.1 }

        let slot = try await api.handle(path: "/v1/radar/20261030T1105Z/20261030T1105Z.webp", ifNoneMatch: nil)
        #expect(slot.status == 200)
        #expect(header(slot, "Cache-Control") == "public, max-age=31536000, immutable")
        #expect(header(slot, "Content-Type") == "image/webp")
        #expect(Array(slot.body.prefix(4)) == Array("RIFF".utf8))
        let again = try await api.handle(path: "/v1/radar/20261030T1105Z/20261030T1105Z.webp", ifNoneMatch: header(slot, "ETag"))
        #expect(again.status == 304 && again.body.isEmpty)

        let latest = try await api.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil)
        #expect(latest.status == 200)
        #expect(header(latest, "Cache-Control") == "public, max-age=30, stale-while-revalidate=30")
        #expect(header(latest, "Content-Type") == "application/json")
        #expect(try await api.handle(path: "/v1/radar/latest.json", ifNoneMatch: header(latest, "ETag")).status == 304)
        let doc = try JSONSerialization.jsonObject(with: Data(latest.body)) as? [String: Any]
        #expect(doc?["run"] as? String == "20261030T1105Z")

        for bad in ["/v1/radar/../x", "/v1/radar/20261030T1105Z/nope.webp", "/", "/v1/radar/20990101T0000Z/20990101T0000Z.webp"] {
            #expect(try await api.handle(path: bad, ifNoneMatch: nil).status == 404, "\(bad)")
        }
        let health = try await api.handle(path: "/healthz", ifNoneMatch: nil)
        #expect(health.status == 200)
        for r in [slot, latest, health] { #expect(header(r, "Set-Cookie") == nil) }  // stateless, no cookies
    }

    @Test(arguments: RepoKind.allCases)
    func lruServesConcurrentRequestsWithOneDbRead(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let (ing, cfg) = ingestor(repo)
        _ = try await ing.process(run: run0)
        let api = Api(repo: repo, config: cfg)
        let path = "/v1/radar/20261030T1105Z/20261030T1110Z.webp"
        let codes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<64 { group.addTask { try await api.handle(path: path, ifNoneMatch: nil).status } }
            var all = Set<Int>()
            for try await c in group { all.insert(c) }
            return all
        }
        #expect(codes == [200])
        #expect(await api.cache.dbReads == 1)
    }

    @Test(arguments: RepoKind.allCases)
    func latestIs404BeforeFirstPublication(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let api = Api(repo: repo, config: smallConfig())
        #expect(try await api.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil).status == 404)
    }

    @Test func migrationsAreIdempotentOnMariaDB() async throws {
        guard RepoKind.dbEnv != nil else { return }
        let repo = try await RepoKind.maria.make()
        try await repo.migrate()
        try await repo.migrate()
        try await repo.ping()
    }
}
}
