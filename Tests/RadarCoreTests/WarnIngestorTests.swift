import Foundation
import Testing
@testable import RadarCore

/// Scripted feed: answers per (feed, language) in order; the last one repeats. Records the requests.
final class FakeWarnFeedSource: WarnFeedSource, @unchecked Sendable {
    enum Step { case xml([String], etag: String?), notModified, fail }
    private let lock = NSLock()
    private var script: [String: [Step]] = [:]
    private(set) var requests: [(feed: WarnFeed, lang: String, etag: String?)] = []

    func set(_ feed: WarnFeed, _ lang: String, _ steps: [Step]) { lock.lock(); script["\(feed):\(lang)"] = steps; lock.unlock() }

    func fetch(feed: WarnFeed, lang: String, ifNoneMatch: String?) async throws -> WarnFeedResponse {
        let step: Step = lock.withLock {
            requests.append((feed, lang, ifNoneMatch))
            var steps = script["\(feed):\(lang)"] ?? [.notModified]
            let first = steps.count > 1 ? steps.removeFirst() : steps[0]
            script["\(feed):\(lang)"] = steps
            return first
        }
        switch step {
        case .notModified: return .notModified
        case .fail: throw WarnFeedError("boom")
        case let .xml(files, etag): return .xmlFiles(files.map { Data($0.utf8) }, etag: etag)
        }
    }
    func count(_ feed: WarnFeed) -> Int { lock.withLock { requests.filter { $0.feed == feed }.count } }
    var total: Int { lock.withLock { requests.count } }
}

extension NSLock { func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() } }

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func frost(_ id: String, _ sent: String = "2026-11-07T12:31:00+01:00", msgType: String = "Alert", references: String? = nil,
                   severity: String = "Minor", expires: String = "2026-11-08T09:00:00+01:00", lang: String = "de-DE") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?><alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
    <identifier>\(id)</identifier><sent>\(sent)</sent><status>Actual</status><msgType>\(msgType)</msgType>\(references.map { "<references>\($0)</references>" } ?? "")
    <info><language>\(lang)</language><event>FROST</event><severity>\(severity)</severity>
    <eventCode><valueName>II</valueName><value>22</value></eventCode>
    <onset>2026-11-07T22:00:00+01:00</onset><expires>\(expires)</expires><headline>H</headline><description>D</description>
    <area><geocode><valueName>WARNCELLID</valueName><value>814522510</value></geocode></area></info></alert>
    """
}

extension DatabaseSuites {
@Suite("Warn ingestor", .serialized)
struct WarnIngestorTests {
    let t0 = ISO8601DateFormatter().date(from: "2026-11-07T11:40:00Z")!   // after the sent time of the fixtures

    private func make(_ repo: any Repo, _ src: FakeWarnFeedSource, _ clock: Clock, owner: String = "r1") -> WarnIngestor {
        WarnIngestor(repo: repo, source: src, owner: owner, clock: { clock.now })
    }

    @Test(arguments: RepoKind.allCases) func nonLeaderDoesNothing(kind: RepoKind) async throws {
        let repo = try await kind.make(); let clock = Clock(t0); let src = FakeWarnFeedSource()
        #expect(try await repo.acquireLeader(name: WarnIngestor.leaderName, owner: "other", leaseSeconds: 600))
        let r = try await make(repo, src, clock).tick()
        #expect(r == WarnIngestResult() && src.requests.isEmpty)
        #expect(try await repo.warnFetchedAt() == nil)
    }

    @Test(arguments: RepoKind.allCases) func firstTickIsStatThenDiffsAndDedupes(kind: RepoKind) async throws {
        let repo = try await kind.make(); let clock = Clock(t0); let src = FakeWarnFeedSource()
        src.set(.stat, "de", [.xml([frost("A.DEU")], etag: "s1")])
        src.set(.stat, "en", [.xml([frost("A.ENG", lang: "en")], etag: "s2")])
        src.set(.diff, "de", [.xml([frost("A.DEU")], etag: "d1"), .notModified])
        let ing = make(repo, src, clock)
        let first = try await ing.tick()
        #expect(first.fetched == 2 && first.stored == 2 && first.newOrChanged.count == 2 && !first.failed)
        #expect(src.count(.stat) == 2 && src.count(.diff) == 0)
        #expect(try await repo.warnFetchedAt() == t0)
        // Next minute: DIFF with the same message is no second newOrChanged; ETag is sent after the first answer.
        clock.now = t0.addingTimeInterval(60)
        let second = try await ing.tick()
        #expect(second.stored == 0 && second.newOrChanged.isEmpty && src.count(.diff) == 2)
        clock.now = t0.addingTimeInterval(120)
        let third = try await ing.tick()
        #expect(third.fetched == 0 && src.requests.last(where: { $0.lang == "de" })?.etag == "d1")
        #expect(try await repo.activeAlerts(now: clock.now, lang: "de").count == 1)
    }

    @Test(arguments: RepoKind.allCases) func updateCancelAndStatEveryFifteenMinutes(kind: RepoKind) async throws {
        let repo = try await kind.make(); let clock = Clock(t0); let src = FakeWarnFeedSource()
        src.set(.stat, "de", [.xml([frost("A.DEU")], etag: nil), .xml([frost("A.DEU")], etag: nil)])
        let ing = make(repo, src, clock)
        _ = try await ing.tick()
        clock.now = t0.addingTimeInterval(60)
        src.set(.diff, "de", [.xml([frost("B.DEU", "2026-11-07T12:41:00+01:00", msgType: "Update", references: "x,A.DEU,2026-11-07T12:31:00+01:00", severity: "Moderate")], etag: "d2")])
        let upd = try await ing.tick()
        #expect(upd.newOrChanged.map(\.alert.identifier) == ["B.DEU"] && upd.newOrChanged.first?.chainID == "A")
        #expect(try await repo.activeAlerts(now: clock.now, lang: "de").map(\.alert.identifier) == ["B.DEU"])
        clock.now = t0.addingTimeInterval(120)
        src.set(.diff, "de", [.xml([frost("C.DEU", "2026-11-07T12:42:00+01:00", msgType: "Cancel", references: "x,B.DEU,2026-11-07T12:41:00+01:00")], etag: "d3")])
        let cancel = try await ing.tick()
        #expect(cancel.cancelled == 1 && cancel.newOrChanged.isEmpty)
        #expect(try await repo.activeAlerts(now: clock.now, lang: "de").isEmpty)
        // STAT is repeated after 15 minutes.
        let statBefore = src.count(.stat)
        clock.now = t0.addingTimeInterval(900 + 1)
        _ = try await ing.tick()
        #expect(src.count(.stat) == statBefore + 2)
    }

    @Test(arguments: RepoKind.allCases) func errorsBackOffAndKeepFetchedAt(kind: RepoKind) async throws {
        let repo = try await kind.make(); let clock = Clock(t0); let src = FakeWarnFeedSource()
        src.set(.stat, "de", [.xml([frost("A.DEU")], etag: nil)])
        let ing = make(repo, src, clock)
        _ = try await ing.tick()
        #expect(try await repo.warnFetchedAt() == t0)
        src.set(.diff, "de", [.fail]); src.set(.stat, "de", [.fail])
        for (offset, wait) in [(60.0, 60.0), (120.0, 120.0), (240.0, 300.0), (540.0, 300.0)] {
            clock.now = t0.addingTimeInterval(offset)
            let before = src.total
            let r = try await ing.tick()
            #expect(r.failed && src.total > before, "offset \(offset)")
            // Within the backoff nothing is requested.
            clock.now = t0.addingTimeInterval(offset + wait - 1)
            let silent = src.total
            #expect(try await ing.tick() == WarnIngestResult() && src.total == silent, "backoff \(wait)")
        }
        #expect(try await repo.warnFetchedAt() == t0)
        // Recovery.
        src.set(.diff, "de", [.notModified]); src.set(.stat, "de", [.notModified])
        clock.now = t0.addingTimeInterval(2000)   // gap: a STAT is requested first
        let ok = try await ing.tick()
        #expect(!ok.failed)
        #expect(try await repo.warnFetchedAt() == clock.now)
    }

    @Test(arguments: RepoKind.allCases) func gapTriggersStatAndExpiredIsSkipped(kind: RepoKind) async throws {
        let repo = try await kind.make(); let clock = Clock(t0); let src = FakeWarnFeedSource()
        src.set(.stat, "de", [.notModified])
        let ing = make(repo, src, clock)
        _ = try await ing.tick()
        let stat1 = src.count(.stat)
        clock.now = t0.addingTimeInterval(120)   // more than 90 s since the last good tick
        src.set(.stat, "de", [.xml([frost("OLD.DEU", expires: "2026-11-07T12:00:00+01:00"), frost("NEW.DEU", "2026-11-07T12:32:00+01:00")], etag: nil)])
        let r = try await ing.tick()
        #expect(src.count(.stat) > stat1)
        #expect(r.stored == 1 && r.newOrChanged.map(\.alert.identifier) == ["NEW.DEU"])
    }

    @Test(arguments: RepoKind.allCases) func brokenFilesAndIgnoredEventsAreCounted(kind: RepoKind) async throws {
        let repo = try await kind.make(); let clock = Clock(t0); let src = FakeWarnFeedSource()
        src.set(.stat, "de", [.xml(["<alert><nope", frost("A.DEU").replacingOccurrences(of: "<value>22</value>", with: "<value>247</value>").replacingOccurrences(of: ">FROST<", with: ">HITZE<")], etag: nil)])
        let r = try await make(repo, src, clock).tick()
        #expect(r.rejected == 1 && r.ignored == 1 && r.stored == 0 && !r.failed)
    }
}
}
