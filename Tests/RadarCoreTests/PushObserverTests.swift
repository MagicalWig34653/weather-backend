import Foundation
import Testing
@testable import RadarCore

// WP11b: push observer counters, operator pause, cache clear. Synthetic ids, tokens and one raster cell only; fake APNs sender.
private let inst = "11111111-1111-4111-8111-111111111111"
private let subA = "33333333-3333-4333-8333-333333333333"
private let subB = "44444444-4444-4444-8444-444444444444"
private let secretHex = String(repeating: "a", count: 40)
private let deviceTok = String(repeating: "ab", count: 32)
private let startTok = String(repeating: "cd", count: 32)

private func cfg(envs: Set<PushEnvironment> = [.sandbox, .production]) -> Config {
    smallConfig { $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = envs }
}

private func wet(onset: Int) -> [Int] { (0..<TimeUtil.forecastSlots).map { $0 >= onset ? 3 : 0 } }

private func publish(_ repo: MemoryRepo, _ config: Config, at date: Date, classes: [Int]) async throws {
    let id = TimeUtil.toID(date)
    #expect(try await repo.tryClaim(runID: id, nominal: date, owner: "fx", leaseSeconds: 60, maxAttempts: 2))
    for (index, slot) in TimeUtil.slots(of: date).enumerated() {
        var pixels = [UInt8](repeating: 0, count: config.width * config.height * 4)
        let o = (20 * config.width + 10) * 4
        if classes[index] < 0 { pixels[o] = 0x7D; pixels[o + 1] = 0x7D; pixels[o + 2] = 0x7D; pixels[o + 3] = 76 }
        else if classes[index] > 0 {
            let c = PushIntensity.palette[classes[index] - 1]
            pixels[o] = UInt8(c.r); pixels[o + 1] = UInt8(c.g); pixels[o + 2] = UInt8(c.b); pixels[o + 3] = 255
        }
        try await repo.putSlot(.init(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot),
                               contentType: "image/webp", data: ImagePipeline.toWebP(RGBAImage(width: config.width, height: config.height, pixels: pixels)))
    }
    #expect(try await repo.publish(runID: id, owner: "fx", expectedSlots: TimeUtil.forecastSlots))
}

private struct World {
    let repo: MemoryRepo
    let config: Config
    let stats = StatsCollector()
    let sender: FakeApnsSender
    let now = Locked(run0)
    let service: PushService

    init(env: PushEnvironment = .sandbox, envs: Set<PushEnvironment> = [.sandbox, .production], startToken: Bool = true, twoSubs: Bool = false,
         script: [ApnsResult] = []) async throws {
        config = cfg(envs: envs)
        repo = MemoryRepo(clock: { run0 })
        sender = FakeApnsSender(script: script)
        _ = try await repo.upsertInstallation(id: inst, secretHash: Hashing.sha256Hex(Array(secretHex.utf8)), token: deviceTok, env: env, locale: "de", now: run0)
        if startToken { try await repo.setLiveActivityStartToken(installationID: inst, token: startTok) }
        for id in twoSubs ? [subA, subB] : [subA] {
            let input = PushSubscriptionInput(gridVersion: 1, cellX: 10, cellY: 20, threshold: 3, leadMinutes: 20, enabled: true, liveActivity: true)
            #expect(try await repo.addSubscription(installationID: inst, id: id, input, maxPerInstallation: 10, now: run0) == .created)
        }
        let clock = now
        service = PushService(config: config, repo: repo, sender: sender, owner: "t", clock: { clock.withLock { $0 } }, stats: stats)
    }

    @discardableResult func tick(_ index: Int, _ classes: [Int]) async throws -> PushTick {
        let date = run0.addingTimeInterval(Double(index * 300))
        now.withLock { $0 = date }
        try await publish(repo, config, at: date, classes: classes)
        return try await service.tick()
    }

    func count(_ metric: String, _ label: String) -> Int { stats.pending().first { $0.metric == metric && $0.label == label }?.value ?? 0 }
}

@Suite("Push observer")
struct PushObserverTests {
    // MARK: reasons and labels

    @Test func apnsReasonListIsFixedAndUnknownBecomesOther() {
        #expect(ApnsReason.known.count == 31 && Set(ApnsReason.known).count == 31)
        for reason in ApnsReason.known { #expect(ApnsReason.normalize(reason) == reason) }
        #expect(ApnsReason.normalize("400 PayloadTooLarge") == "PayloadTooLarge")
        #expect(ApnsReason.normalize("503") == "ServiceUnavailable" && ApnsReason.normalize("429") == "TooManyRequests")
        for odd in ["", "transport", "apns disabled", "418 Teapot", String(repeating: "x", count: 500), "BadDeviceToken extra"] { #expect(ApnsReason.normalize(odd) == "other") }
    }

    @Test func everyObserverLabelIsAcceptedByTheCollector() {
        let c = StatsCollector()
        let o = StatsPushObserver(stats: c)
        for t in PushTrigger.allCases { o.triggered(t, by: 1); for r in PushSkipReason.allCases { o.skipped(t, r, by: 1) } }
        for r in PushSkipReason.allCases { o.skipped(nil, r, by: 1) }
        for k in PushSendKind.allCases { for e in PushEnvironment.allCases { for out in PushOutcome.allCases {
            for r in ApnsReason.known + ["zzz"] { o.sent(kind: k, env: e, outcome: out, reason: r) }
        } } }
        for k in PushTokenKind.allCases { for cause in PushTokenCause.allCases { o.tokenInvalidated(k, cause) } }
        for code in StatsCollector.pushApiRejectCodes { o.apiRejected(code) }
        o.apiRejected("not-a-code")
        // Nothing fell into `other` by mistake: the rules know every label that the observer emits.
        let pending = c.pending()
        #expect(!pending.isEmpty && pending.allSatisfy { !$0.label.hasSuffix("other") || $0.metric == "apns_error" || $0.metric == "token_invalidated" || $0.metric == "push_api_reject" })
        #expect(pending.filter { $0.metric == "apns_error" }.allSatisfy { $0.label.split(separator: ":").count == 3 })
        #expect(c.pending().first { $0.metric == "push_api_reject" && $0.label == "other" }?.value == 1)
    }

    // MARK: pipeline

    @Test func rainStartCountsTriggerCreatedSentAndLifecycle() async throws {
        let w = try await World()
        try await w.tick(0, wet(onset: 3))
        #expect(w.count("push_trigger", "rain_start") == 0 && w.count("push_skipped", "rain_start:below_threshold") == 0)
        let t = try await w.tick(1, wet(onset: 2))
        #expect(t.sent == 2)
        #expect(w.count("push_trigger", "rain_start") == 1 && w.count("push_trigger", "la_rain_start") == 1)
        #expect(w.count("push_created", "") == 1 && w.count("push_attempt", "") == 1 && w.count("push_sent", "delivered") == 1)
        #expect(w.count("la_event", "start:delivered") == 1)
    }

    @Test func lockHysteresisAndBelowThresholdAreTold() async throws {
        let w = try await World()
        try await w.tick(0, wet(onset: 3))
        try await w.tick(1, wet(onset: 2))             // start + alert, lock set
        try await w.tick(2, wet(onset: 3))             // notified, rain would begin again but not re-armed: hysteresis
        #expect(w.count("push_skipped", "rain_start:hysteresis") == 1 && w.count("push_skipped", "la_rain_start:hysteresis") == 1)
        try await w.tick(3, wet(onset: 30))            // fully dry: re-armed (dry now)
        try await w.tick(4, wet(onset: 3))             // pending
        try await w.tick(5, wet(onset: 3))             // would start, 60 minute lock holds it back
        #expect(w.count("push_skipped", "rain_start:lock_60min") == 1 && w.count("push_skipped", "la_rain_start:lock_60min") == 1)
        #expect(w.count("push_trigger", "rain_start") == 1)
        try await w.tick(6, wet(onset: 30)); try await w.tick(7, wet(onset: 30))
        #expect(w.count("push_skipped", "rain_start:below_threshold") >= 1)
    }

    @Test func missingStartTokenAndBusySlotAreTold() async throws {
        let none = try await World(startToken: false)
        try await none.tick(0, wet(onset: 3)); try await none.tick(1, wet(onset: 2))
        #expect(none.count("push_skipped", "la_rain_start:no_start_token") == 1 && none.count("push_trigger", "rain_start") == 1)
        let busy = try await World(twoSubs: true)
        try await busy.tick(0, wet(onset: 3)); try await busy.tick(1, wet(onset: 2))
        #expect(busy.count("la_event", "start:delivered") == 1 && busy.count("push_skipped", "la_rain_start:activity_slot_busy") == 1)
    }

    @Test func unknownPixelIsTold() async throws {
        let w = try await World()
        var classes = wet(onset: 30); classes[0] = -1
        try await w.tick(0, classes)
        #expect(w.count("push_skipped", "la_raining_now:unknown_pixel") == 1)
    }

    @Test func disallowedEnvironmentIsTold() async throws {
        let w = try await World(env: .sandbox, envs: [.production])
        try await w.tick(0, wet(onset: 3)); try await w.tick(1, wet(onset: 2))
        #expect(await w.sender.requests.count == 0)
        #expect(w.count("push_skipped", "rain_start:env_not_allowed") == 1 && w.count("push_skipped", "la_rain_start:env_not_allowed") == 1)
        #expect(w.count("push_failed", "dropped") == 1)
    }

    @Test func staleAndIncompleteRunsAreTold() async throws {
        let w = try await World()
        w.now.withLock { $0 = run0.addingTimeInterval(21 * 60) }
        try await publish(w.repo, w.config, at: run0, classes: wet(onset: 3))
        _ = try await w.service.tick()
        #expect(w.count("push_skipped", "run:no_fresh_run") == 1)
    }

    @Test func failuresCarryApnsReasonAndInvalidateTokens() async throws {
        // alert delivered, start answered BadDeviceToken
        let bad = try await World(script: [.delivered, .badToken("BadDeviceToken")])
        try await bad.tick(0, wet(onset: 3)); try await bad.tick(1, wet(onset: 2))
        #expect(bad.count("apns_error", "start:BadDeviceToken:sandbox") == 1 && bad.count("token_invalidated", "start:bad_device_token") == 1)
        #expect(bad.count("la_event", "start:rejected") == 1)
        #expect(try await bad.repo.installation(id: inst)?.liveActivityStartToken == nil)
        // alert Unregistered (410)
        let gone = try await World(script: [.unregistered])
        try await gone.tick(0, wet(onset: 3)); try await gone.tick(1, wet(onset: 2))
        #expect(gone.count("push_failed", "unregistered") == 1 && gone.count("token_invalidated", "device:410") == 1)
        // alert 503 -> retry
        let retry = try await World(script: [.retry("503")])
        try await retry.tick(0, wet(onset: 3)); try await retry.tick(1, wet(onset: 2))
        #expect(retry.count("push_failed", "retry") == 1 && retry.count("apns_error", "alert:ServiceUnavailable:sandbox") == 1)
    }

    /// Finding (WP11b, item 4): the 60 minute lock is committed with the evaluation, before any send. A start that ends in
    /// `retry` keeps its reservation (no second activity) but is never repeated by the next run; documented, behaviour unchanged.
    @Test func lostStartKeepsTheLockAndIsNotRepeated() async throws {
        let w = try await World(script: [.delivered, .retry("503")])
        try await w.tick(0, wet(onset: 3)); try await w.tick(1, wet(onset: 2))
        #expect(w.count("la_event", "start:retry") == 1)
        let stored = try #require(try await w.repo.subscriptions(installationID: inst).first)
        #expect(stored.lastSentAt != nil)
        let before = await w.sender.requests.count
        try await w.tick(2, wet(onset: 2)); try await w.tick(3, wet(onset: 2))
        let all = await w.sender.requests
        #expect(all.filter { $0.activityEvent == .start }.count == 1 && all.count >= before)
    }

    // MARK: pause and outbox

    @Test func pauseStopsSendingKeepsOutboxAndShowsInGauge() async throws {
        let w = try await World()
        try await w.repo.setPushPaused(true, now: run0)
        try await w.tick(0, wet(onset: 3))
        let t = try await w.tick(1, wet(onset: 2))
        let sentWhilePaused = await w.sender.requests.count
        #expect(t.paused && t.queued == 1 && t.sent == 0 && sentWhilePaused == 0)
        #expect(w.count("push_skipped", "run:paused") >= 1)
        let gauge = try await w.repo.outboxGauge(now: w.now.withLock { $0 })
        #expect(gauge.waiting == 1 && gauge.retrying == 0 && gauge.oldestAgeSeconds != nil)
        // Resume: the pending alert is still deliverable within its life time.
        try await w.repo.setPushPaused(false, now: run0)
        let after = try await w.service.tick()
        #expect(!after.paused && after.sent == 2)
        #expect(try await w.repo.outboxGauge(now: w.now.withLock { $0 }).waiting == 0)
    }

    // MARK: privacy and concurrency

    @Test func countersNeverContainTokensIdsOrCells() async throws {
        let w = try await World(twoSubs: true, script: [.delivered, .badToken("BadDeviceToken")])
        try await w.tick(0, wet(onset: 3)); try await w.tick(1, wet(onset: 2)); try await w.tick(2, wet(onset: 3))
        let rows = w.stats.pending()
        #expect(!rows.isEmpty)
        for row in rows {
            let text = row.metric + row.label
            for secret in [inst, subA, subB, deviceTok, startTok, secretHex, "10", "20"] where secret.count > 2 { #expect(!text.contains(secret)) }
            #expect(row.label.count < 80)
        }
    }

    @Test func concurrentObserversCountExactly() async {
        let c = StatsCollector()
        let o = StatsPushObserver(stats: c)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { for _ in 0..<100 { o.sent(kind: .start, env: .production, outcome: .rejected, reason: "BadDeviceToken"); o.alertAttempt() } } }
        }
        let rows = Dictionary(uniqueKeysWithValues: c.pending().map { ($0.metric + "|" + $0.label, $0.value) })
        #expect(rows["apns_error|start:BadDeviceToken:production"] == 5000 && rows["la_event|start:rejected"] == 5000 && rows["push_attempt|"] == 5000)
    }
}

// MARK: operator actions

extension DatabaseSuites {
@Suite("Push operator actions", .serialized)
struct PushOperatorActionTests {
    private func request(_ method: String, _ path: String, _ body: String) -> DashboardHTTPRequest {
        DashboardHTTPRequest(method: method, path: path, body: Array(body.utf8),
                             info: DashboardRequestInfo(method: method, cookieHeader: nil, origin: nil, host: "x", contentType: "application/json", csrfToken: nil))
    }
    private func json(_ r: ApiResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(r.body))) as? [String: Any] ?? [:] }

    @Test func pauseToggleAuditAndLimit() async throws {
        let repo = MemoryRepo(); let actions = DashboardPushActions(repo: repo)
        let now = run0
        var r = try #require(try await actions.handle(request("PUT", "/dash/api/push/pause", #"{"paused":true}"#), "/push/pause", now: now))
        #expect(r.status == 200 && json(r)["paused"] as? Bool == true && json(r)["since"] as? String == TimeUtil.toISO(now))
        r = try #require(try await actions.handle(request("PUT", "", #"{"paused":true}"#), "/push/pause", now: now.addingTimeInterval(5)))
        #expect(json(r)["since"] as? String == TimeUtil.toISO(now))  // idempotent: original time
        r = try #require(try await actions.handle(request("PUT", "", #"{"paused":false}"#), "/push/pause", now: now.addingTimeInterval(6)))
        #expect(json(r)["paused"] as? Bool == false && json(r)["since"] is NSNull)
        for bad in ["{}", #"{"paused":"yes"}"#, #"{"paused":true,"x":1}"#] {
            #expect(try await actions.handle(request("PUT", "", bad), "/push/pause", now: now.addingTimeInterval(7))?.status == 400)
        }
        #expect(try await actions.handle(request("PUT", "", #"{"paused":true}"#), "/push/pause", now: now.addingTimeInterval(8))?.status == 429)
        let audit = try await repo.auditEntries(limit: 10).filter { $0.action == .pushPause }
        #expect(audit.count == 3 && Set(audit.compactMap(\.outcome)) == ["paused", "resumed"])
        #expect(try await actions.handle(request("GET", "", ""), "/push/pause", now: now)?.status == 405)
        #expect(try await actions.handle(request("GET", "", ""), "/other", now: now) == nil)
    }

    @Test func cacheClearValidatesScopeCountsAndLimits() async throws {
        let repo = MemoryRepo(); let actions = DashboardPushActions(repo: repo)
        let now = run0
        var r = try #require(try await actions.handle(request("POST", "", #"{"layer":"all"}"#), "/cache/clear", now: now))
        #expect(r.status == 202 && json(r)["generation"] as? Int == 1 && json(r)["layer"] as? String == "all")
        r = try #require(try await actions.handle(request("POST", "", #"{"layer":"radar"}"#), "/cache/clear", now: now))
        #expect(json(r)["generation"] as? Int == 2)
        #expect(try await actions.handle(request("POST", "", #"{"layer":"all"}"#), "/cache/clear", now: now)?.status == 429)
        var later = now
        for bad in [#"{"layer":"../etc"}"#, #"{"layer":""}"#, "{}", #"{"layer":1}"#] {
            later = later.addingTimeInterval(61)
            #expect(try await actions.handle(request("POST", "", bad), "/cache/clear", now: later)?.status == 400)
        }
        let layer = try #require(LayerCatalog.order.first)
        later = later.addingTimeInterval(61)
        #expect(try await actions.handle(request("POST", "", #"{"layer":"\#(layer)"}"#), "/cache/clear", now: later)?.status == 202)
        #expect(try await repo.cacheClearState() == CacheClearState(generation: 3, scope: layer))
        #expect(try await repo.auditEntries(limit: 10).filter { $0.action == .cacheClear }.count == 3)
    }

    @Test func watcherClearsOnlyTheScopeAfterTheFirstObservation() async throws {
        let repo = MemoryRepo(); let cache = SlotCache(maxBytes: 1_000_000)
        let blob = SlotBlob(contentType: "image/webp", sha256: "x", data: [1, 2, 3])
        await cache.put("run/slot", blob); await cache.put("layer:rain/run/slot", blob); await cache.put("layer:wind/run/slot", blob)
        let watcher = CacheClearWatcher(repo: repo, cache: cache)
        #expect(await watcher.poll() == false)            // first observation only records the generation
        #expect(await cache.contains("run/slot"))
        _ = try await repo.requestCacheClear(scope: "radar")
        #expect(await watcher.poll())
        #expect(await !cache.contains("run/slot"))
        #expect(await cache.contains("layer:rain/run/slot"))
        #expect(await watcher.poll() == false)            // nothing new
        _ = try await repo.requestCacheClear(scope: "rain")
        #expect(await watcher.poll())
        #expect(await !cache.contains("layer:rain/run/slot"))
        #expect(await cache.contains("layer:wind/run/slot"))
        _ = try await repo.requestCacheClear(scope: "all")
        #expect(await watcher.poll())
        #expect(await !cache.contains("layer:wind/run/slot"))
    }

    @Test(arguments: RepoKind.allCases) func pauseCacheGenerationAndOutboxGaugePersist(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try await repo.pushPausedSince() == nil)
        let first = try await repo.setPushPaused(true, now: now)
        #expect(first == TimeUtil.fromSQL(TimeUtil.toSQL(now)))
        #expect(try await repo.setPushPaused(true, now: now.addingTimeInterval(60)) == first)
        #expect(try await repo.pushPausedSince() == first)
        #expect(try await repo.setPushPaused(false, now: now) == nil)
        #expect(try await repo.pushPausedSince() == nil)
        #expect(try await repo.cacheClearState() == CacheClearState(generation: 0, scope: "all"))
        async let a = repo.requestCacheClear(scope: "radar")
        async let b = repo.requestCacheClear(scope: "all")
        let gens = try await [a, b].sorted()
        #expect(gens == [1, 2])
        #expect(try await repo.cacheClearState().generation == 2)
        #expect(try await repo.outboxGauge(now: now) == OutboxGauge())
    }

    @Test(arguments: RepoKind.allCases) func outboxGaugeCountsWaitingRetryingAndLost(kind: RepoKind) async throws {
        let repo = try await kind.make()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await repo.upsertInstallation(id: inst, secretHash: Hashing.sha256Hex(Array(secretHex.utf8)), token: deviceTok, env: .sandbox, locale: "de", now: now, maxInstallations: 100)
        let input = PushSubscriptionInput(gridVersion: 1, cellX: 1, cellY: 1, threshold: 3, leadMinutes: 20, enabled: true)
        _ = try await repo.addSubscription(installationID: inst, id: subA, input, maxPerInstallation: 10, now: now)
        let items = (0..<3).map { NewOutboxItem(subID: subA, dedupeKey: "k\($0)", collapseID: subA, payloadJSON: "{}", expiresAt: now.addingTimeInterval(1200)) }
        #expect(try await repo.commitEvaluation(runID: "20270115T0800Z", updates: [], outbox: items, now: now.addingTimeInterval(-120)))
        let due = try await repo.dueOutbox(now: now, limit: 10)
        #expect(due.count == 3)
        try await repo.finishOutbox(id: due[0].id, .retry(attempts: 1, at: now), now: now)
        try await repo.finishOutbox(id: due[1].id, .dropped, now: now)
        let g = try await repo.outboxGauge(now: now)
        #expect(g.waiting == 2 && g.retrying == 1 && g.droppedOrExpired24h == 1 && g.oldestAgeSeconds == 120)
        // After expiry the items are no longer waiting but count as lost.
        let late = try await repo.outboxGauge(now: now.addingTimeInterval(1300))
        #expect(late.waiting == 0 && late.oldestAgeSeconds == nil && late.droppedOrExpired24h == 3)
    }
}
}
