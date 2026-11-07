import Foundation
import Testing
@testable import RadarCore

// Live Activities for circle subscriptions (decision 7 Nov 2026, variant A): trigger share, content state, one slot per installation,
// a point beats a region. Synthetic identifiers, raster cells and tokens only.

private enum RF {
    static let installation = "11111111-1111-4111-8111-111111111111"
    static let point = "33333333-3333-4333-8333-333333333333"
    static let region = "55555555-5555-4555-8555-555555555555"
    static let region2 = "66666666-6666-4666-8666-666666666666"
    static let secret = String(repeating: "a", count: 40)
    static let device = String(repeating: "ab", count: 32)
    static let start = String(repeating: "cd", count: 32)
    static let pointToken = String(repeating: "ef", count: 32)
    static let regionToken = String(repeating: "12", count: 32)
    static let radius = 5          // 81 cells; share 10 % -> 9 wet cells needed
    static let centre = (x: 30, y: 30)
    static let pointCell = (x: 10, y: 20)

    static func config() -> Config {
        smallConfig { $0.width = 64; $0.push.enabled = true; $0.push.topic = "de.example.app"; $0.push.environments = [.sandbox, .production] }
    }
    static func regionInput(share: Int = 10, live: Bool = true, threshold: Int = 3) -> PushSubscriptionInput {
        .init(gridVersion: 1, cellX: centre.x, cellY: centre.y, threshold: threshold, leadMinutes: 20, enabled: true,
              kind: .circle, radiusCells: radius, minSharePercent: share, liveActivity: live)
    }
    static func pointInput() -> PushSubscriptionInput {
        .init(gridVersion: 1, cellX: pointCell.x, cellY: pointCell.y, threshold: 3, leadMinutes: 20, enabled: true, liveActivity: true)
    }
    /// Installation with start token, a region and optionally a point; nothing armed for an immediate start (activated long ago).
    static func prepared(region: Bool = true, point: Bool = false, armed: Bool = false) async throws -> MemoryRepo {
        let repo = MemoryRepo(clock: { run0 })
        _ = try await repo.upsertInstallation(id: installation, secretHash: Hashing.sha256Hex(Array(secret.utf8)), token: device, env: .sandbox, locale: "de", now: run0)
        try await repo.setLiveActivityStartToken(installationID: installation, token: start)
        if region { #expect(try await repo.addSubscription(installationID: installation, id: Self.region, regionInput(), maxPerInstallation: 10, now: run0) == .created) }
        if point { #expect(try await repo.addSubscription(installationID: installation, id: Self.point, pointInput(), maxPerInstallation: 10, now: run0) == .created) }
        if !armed {
            for id in [Self.region, Self.point] { try await repo.setStartRetry(subscriptionID: id, armed: false, attempts: 0) }
        }
        return repo
    }

    /// Wet cells (known class `cls`) and unknown cells (semi-transparent mask) of the region per slot, point class per slot.
    struct Slot { var wet = 0, unknown = 0, cls = 3, point = 0 }

    static func publish(_ repo: MemoryRepo, config: Config, at date: Date, slot: (Int) -> Slot) async throws {
        let id = TimeUtil.toID(date)
        #expect(try await repo.tryClaim(runID: id, nominal: date, owner: "fixture", leaseSeconds: 60, maxAttempts: 2))
        for (index, time) in TimeUtil.slots(of: date).enumerated() {
            let s = slot(index)
            var pixels = [UInt8](repeating: 0, count: config.width * config.height * 4)
            func set(_ x: Int, _ y: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
                let o = (y * config.width + x) * 4
                pixels[o] = rgba.0; pixels[o + 1] = rgba.1; pixels[o + 2] = rgba.2; pixels[o + 3] = rgba.3
            }
            if s.point > 0 { let c = PushIntensity.palette[s.point - 1]; set(pointCell.x, pointCell.y, (UInt8(c.r), UInt8(c.g), UInt8(c.b), 255)) }
            let c = PushIntensity.palette[s.cls - 1]
            for k in 0..<s.wet { set(centre.x - 4 + k, centre.y, (UInt8(c.r), UInt8(c.g), UInt8(c.b), 255)) }
            for k in 0..<s.unknown { set(centre.x - 4 + k, centre.y + 1, (0x7D, 0x7D, 0x7D, 76)) }
            let image = RGBAImage(width: config.width, height: config.height, pixels: pixels)
            try await repo.putSlot(.init(runID: id, slotID: TimeUtil.toID(time), slotIndex: index, slotTime: time), contentType: "image/webp", data: cachedWebP(image))
        }
        #expect(try await repo.publish(runID: id, owner: "fixture", expectedSlots: TimeUtil.forecastSlots))
    }

    static func aps(_ request: ApnsRequest) throws -> [String: Any] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(request.payload)) as? [String: Any])
        return try #require(object["aps"] as? [String: Any])
    }
    static func state(_ request: ApnsRequest) throws -> [String: Any] { try #require(try aps(request)["content-state"] as? [String: Any]) }

    /// Rig with a ticking service on a fake clock; `run(index, slot)` publishes the run at `run0 + 5 min * index` and ticks.
    struct Rig {
        let repo: MemoryRepo, sender: FakeApnsSender, service: PushService, now: Locked<Date>, config: Config
        init(repo: MemoryRepo) {
            self.repo = repo
            sender = FakeApnsSender()
            now = Locked(run0)
            config = RF.config()
            let clock = now
            service = PushService(config: config, repo: repo, sender: sender, owner: "region-la", clock: { clock.withLock { $0 } })
        }
        func run(_ index: Int, _ slot: @escaping (Int) -> Slot) async throws {
            let date = run0.addingTimeInterval(Double(index * 300))
            now.withLock { $0 = date }
            try await RF.publish(repo, config: config, at: date, slot: slot)
            _ = try await service.tick()
        }
        func starts() async -> [ApnsRequest] { await sender.requests.filter { $0.activityEvent == .start } }
        func ends() async -> [ApnsRequest] { await sender.requests.filter { $0.activityEvent == .end } }
        func updates() async -> [ApnsRequest] { await sender.requests.filter { $0.activityEvent == .update } }
    }

    static func dry(_ i: Int) -> Slot { Slot() }
    static func regionWet(from onset: Int = 0, cells: Int = 9, unknown: Int = 0, cls: Int = 3) -> (Int) -> Slot {
        { $0 >= onset ? Slot(wet: cells, unknown: unknown, cls: cls) : Slot() }
    }
    /// Point and region together: wet from the given slot onwards (99 = stays dry).
    static func both(point: Int = 99, region: Int = 99) -> (Int) -> Slot {
        { Slot(wet: $0 >= region ? 9 : 0, point: $0 >= point ? 3 : 0) }
    }
    static func pointWet(from onset: Int = 0) -> (Int) -> Slot { { $0 >= onset ? Slot(point: 3) : Slot() } }
}

@Suite("Region Live Activity: trigger share, unknown cells, content state")
struct RegionActivityUnitTests {
    private func image(wet: Int, unknown: Int, cls: Int = 3) -> RGBAImage {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let c = PushIntensity.palette[cls - 1]
        for k in 0..<wet { let o = (30 * w + 26 + k) * 4; pixels[o] = UInt8(c.r); pixels[o + 1] = UInt8(c.g); pixels[o + 2] = UInt8(c.b); pixels[o + 3] = 255 }
        for k in 0..<unknown { let o = (31 * w + 26 + k) * 4; pixels[o] = 0x7D; pixels[o + 1] = 0x7D; pixels[o + 2] = 0x7D; pixels[o + 3] = 76 }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }
    private func stats(_ img: RGBAImage, share: Int = 10) -> RegionSlotStats {
        let map = PushIntensity.classMap(img, markUnknown: true)
        return PushRegion.slotStats(classMap: map, width: img.width, height: img.height, cx: 30, cy: 30, radius: 5, threshold: 3, sharePercent: share)
    }

    @Test func trigger_isThresholdWhenShareReached_sameAsAlert() {
        let s = stats(image(wet: 9, unknown: 0))
        #expect(s.cells == 81 && s.need == 9 && s.wet == 9 && s.pseudoClass == 3)
        // The alert path (no unknown marking) reaches the same decision with the same share.
        let img = image(wet: 9, unknown: 0)
        #expect(PushRegion.pseudoClass(classMap: PushIntensity.classMap(img), width: 64, height: 64, cx: 30, cy: 30, radius: 5, threshold: 3, sharePercent: 10) == 3)
        let below = image(wet: 8, unknown: 0)
        #expect(stats(below).pseudoClass == 0)
        #expect(PushRegion.pseudoClass(classMap: PushIntensity.classMap(below), width: 64, height: 64, cx: 30, cy: 30, radius: 5, threshold: 3, sharePercent: 10) == 0)
    }

    @Test func unknownCellsMakeTheSlotUnknownOnlyWhenTheyCouldDecide() {
        let undecided = stats(image(wet: 6, unknown: 3))        // 6 + 3 unknown could reach 9
        #expect(undecided.wet == 6 && undecided.unknown == 3 && undecided.pseudoClass == PushIntensity.unknown)
        #expect(stats(image(wet: 6, unknown: 2)).pseudoClass == 0)   // even all unknown cells would not reach the need
        #expect(stats(image(wet: 9, unknown: 4)).pseudoClass == 3)   // known wet is enough
        // Unknown never counts as wet for the alert: the alert pseudo class ignores the mark.
        let img = image(wet: 6, unknown: 3)
        #expect(PushRegion.pseudoClass(classMap: PushIntensity.classMap(img, markUnknown: true), width: 64, height: 64, cx: 30, cy: 30, radius: 5, threshold: 3, sharePercent: 10) == 0)
        // Fully transparent background is dry, not unknown.
        #expect(stats(image(wet: 0, unknown: 0)).unknown == 0)
    }

    @Test func contentSharesRoundingPeakWindowAndClass() {
        func s(_ wet: Int, cls: Int = 3) -> RegionSlotStats { .init(cells: 81, wet: wet, unknown: 0, maxClass: cls, need: 9, pseudoClass: 0) }
        var slots = [RegionSlotStats](repeating: s(0, cls: 0), count: TimeUtil.forecastSlots)
        slots[0] = s(1)                 // 1.2 % -> 1
        slots[5] = s(27, cls: 7)        // 33.3 % -> 33, inside the first 13 slots
        slots[20] = s(81, cls: 11)      // outside the peak window, but inside the class maximum
        let c = RegionActivityContent(stats: slots, radiusKm: 4)
        #expect(c.wetSharePercent == 1 && c.peakSharePercent == 33 && c.maxClass == 11 && c.radiusKm == 4 && c.currentMaxClass == 3)
        // A single wet cell never shows as 0 %.
        #expect(RegionActivityContent(stats: [.init(cells: 5000, wet: 1, unknown: 0, maxClass: 3, need: 50, pseudoClass: 0)], radiusKm: nil).wetSharePercent == 1)
        #expect(RegionActivityContent(stats: [s(81)], radiusKm: nil).wetSharePercent == 100)
    }

    @Test func radiusInKilometres() throws {
        let km = try #require(PushRegion.radiusKilometres(radiusCells: 14, cellX: 456, cellY: 851, width: 1024))
        #expect((9...11).contains(km))   // about 0.7 km per cell at 50 degrees north
        #expect(PushRegion.radiusKilometres(radiusCells: 3, cellX: 2000, cellY: 0, width: 1024) == nil)
    }

    @Test func payloadContractPointUnchangedRegionAdditiveAndSmall() throws {
        let classes = (0..<TimeUtil.forecastSlots).map { $0 >= 2 ? 3 : 0 }
        let point = PushActivityPayload.content(classes: classes, threshold: 3, reference: run0)
        #expect(Set(point.keys) == ["phase", "eventDate", "intensityClass", "referenceTime", "staleDate"])
        let region = RegionActivityContent(stats: [.init(cells: 81, wet: 0, unknown: 0, maxClass: 0, need: 9, pseudoClass: 0),
                                                   .init(cells: 81, wet: 20, unknown: 0, maxClass: 6, need: 9, pseudoClass: 3)], radiusKm: 4)
        let content = PushActivityPayload.content(classes: classes, threshold: 3, reference: run0, region: region)
        #expect(Set(content.keys) == Set(point.keys).union(["wetSharePercent", "peakSharePercent", "regionRadiusKm"]))
        #expect(content["phase"] as? String == "startsIn" && content["intensityClass"] as? Int == 6)
        #expect(content["wetSharePercent"] as? Int == 0 && content["peakSharePercent"] as? Int == 25 && content["regionRadiusKm"] as? Int == 4)
        let bytes = try PushActivityPayload.encode(event: .start, subscriptionID: RF.region, content: content, now: run0)
        #expect(bytes.count < 4096 && bytes.count < 700)
        let state = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        #expect(state.count < 4096)
        // Unknown radius: key absent (optional on the wire).
        let noRadius = PushActivityPayload.content(classes: classes, threshold: 3, reference: run0, region: RegionActivityContent(stats: [], radiusKm: nil))
        #expect(noRadius["regionRadiusKm"] == nil && noRadius["wetSharePercent"] as? Int == 0)
    }
}

@Suite("Region Live Activity: API and capability")
struct RegionActivityApiTests {
    private func api(_ repo: MemoryRepo) -> PushApi { PushApi(repo: repo, config: RF.config(), clock: { run0 }) }
    private func call(_ api: PushApi, _ method: String, _ path: String, _ body: [String: Any]) async throws -> Int? {
        var base: [String: Any] = ["grid_version": 1, "cell_x": 30, "cell_y": 30, "threshold": 3, "lead_minutes": 20, "kind": "circle", "radius_cells": 5]
        base.merge(body) { _, new in new }
        let data = Array(try JSONSerialization.data(withJSONObject: base))
        return await api.handle(method: method, path: "/v1/push/installations/" + RF.installation + path, secret: RF.secret, body: data)?.status
    }

    @Test func circleWithLiveActivityNeedsStartTokenAndRoundTrips() async throws {
        let repo = try await RF.prepared(region: false)
        try await repo.setLiveActivityStartToken(installationID: RF.installation, token: nil)
        let api = api(repo)
        #expect(try await call(api, "POST", "/subscriptions", ["live_activity": true]) == 409)    // start_token_required, as for points
        try await repo.setLiveActivityStartToken(installationID: RF.installation, token: RF.start)
        #expect(try await call(api, "POST", "/subscriptions", ["live_activity": true, "min_share_percent": 25]) == 201)
        let sub = try #require(try await repo.subscriptions(installationID: RF.installation).first)
        #expect(sub.kind == .circle && sub.liveActivity && sub.minSharePercent == 25 && sub.instantStart)   // armed like a point
        #expect(try await call(api, "PUT", "/subscriptions/" + sub.id, ["live_activity": "yes"]) == 400)
        #expect(try await call(api, "PUT", "/subscriptions/" + sub.id, ["live_activity": false]) == 204)
    }

    @Test func statusAnnouncesCapability() async throws {
        let config = RF.config()
        let repo = MemoryRepo(clock: { run0 })
        let response = try await Api(repo: repo, config: config).handle(path: "/v1/status", ifNoneMatch: nil)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any])
        #expect((doc["capabilities"] as? [String])?.contains("live_activity_regions") == true)
    }
}

@Suite("Region Live Activity: evaluation with fake sender")
struct RegionActivityEvaluationTests {
    @Test func forecastStartUpdateAndEndAfterThirtyMinutesDry() async throws {
        let rig = RF.Rig(repo: try await RF.prepared())
        try await rig.run(0, RF.regionWet(from: 3))
        #expect(await rig.starts().isEmpty)                          // first run only arms the rule
        try await rig.run(1, RF.regionWet(from: 2))
        let start = try #require(await rig.starts().first)
        #expect(start.tokenHex == RF.start)
        let aps = try RF.aps(start)
        #expect(aps["attributes-type"] as? String == "RainActivityAttributes")
        #expect((aps["attributes"] as? [String: Any])?["subscriptionID"] as? String == RF.region)
        #expect((aps["alert"] as? [String: Any])?["body"] as? String == "Regen beginnt bald")
        let state = try RF.state(start)
        #expect(state["phase"] as? String == "startsIn" && state["wetSharePercent"] as? Int == 0)
        #expect(state["peakSharePercent"] as? Int == 11 && state["intensityClass"] as? Int == 3)
        #expect((state["regionRadiusKm"] as? Int ?? 0) >= 3)
        // The ordinary region alert is still sent once.
        #expect(await rig.sender.requests.filter { $0.activityEvent == nil }.count == 1)
        _ = try await rig.repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0.addingTimeInterval(300))
        try await rig.run(2, RF.regionWet(from: 0))
        let update = try #require(await rig.updates().last)
        #expect(update.tokenHex == RF.regionToken)
        let raining = try RF.state(update)
        #expect(raining["phase"] as? String == "raining" && raining["wetSharePercent"] as? Int == 11 && raining["peakSharePercent"] as? Int == 11)
        // 30 minutes safely dry: ends.
        try await rig.run(3, RF.dry)
        #expect(await rig.ends().count == 1)
        #expect(try await rig.repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
        // 60-minute lock: a new onset within an hour does not start again.
        try await rig.run(4, RF.regionWet(from: 1))
        try await rig.run(5, RF.regionWet(from: 1))
        #expect(await rig.starts().count == 1)
    }

    @Test func raininAlreadyStartsFromOneWetRunWhenArmedAndNeedsTwoOtherwise() async throws {
        // Armed (activation): one wet run starts it, without the 60-minute lock.
        let armed = RF.Rig(repo: try await RF.prepared(armed: true))
        try await armed.run(0, RF.regionWet())
        let start = try #require(await armed.starts().first)
        #expect(try RF.state(start)["phase"] as? String == "raining")
        #expect((try RF.aps(start)["alert"] as? [String: Any])?["body"] as? String == "Es regnet gerade")
        // Not armed: first wet run only sets the hysteresis bit, the second starts.
        let plain = RF.Rig(repo: try await RF.prepared())
        try await plain.run(0, RF.regionWet())
        #expect(await plain.starts().isEmpty)
        #expect(try await plain.repo.subscriptions(installationID: RF.installation).first?.trace?.reason == "hysteresis")
        try await plain.run(1, RF.regionWet())
        #expect(await plain.starts().count == 1)
    }

    @Test func shareBelowTriggerDoesNotStartAndUsesTheAlertShare() async throws {
        let rig = RF.Rig(repo: try await RF.prepared(armed: true))
        try await rig.run(0, RF.regionWet(cells: 8))            // 8 < 9 needed at 10 %
        #expect(await rig.starts().isEmpty)
        #expect(try await rig.repo.subscriptions(installationID: RF.installation).first?.trace?.reason == "below_threshold")
        // The same subscription at 1 %: the minimum of 3 cells is needed, 8 are enough (shared setting with the alert).
        _ = try await rig.repo.updateSubscription(installationID: RF.installation, id: RF.region, RF.regionInput(share: 1), regionLimits: .standard)
        try await rig.run(1, RF.regionWet(cells: 8))
        #expect(await rig.starts().count == 1)
    }

    @Test func unknownCellsNeverEndAndNeverConfirm() async throws {
        let rig = RF.Rig(repo: try await RF.prepared(armed: true))
        try await rig.run(0, RF.regionWet())
        _ = try await rig.repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0)
        // Dry in the known cells, but 4 unknown cells could still make it wet (0 + 4 < 9 would end; 6 + 3 >= 9 may not).
        try await rig.run(1) { _ in .init(wet: 6, unknown: 3) }
        let endsNow = await rig.ends(), updatesNow = await rig.updates()
        #expect(endsNow.isEmpty && !updatesNow.isEmpty)
        #expect(try await rig.repo.subscriptions(installationID: RF.installation).first?.trace?.cls == PushIntensity.unknown)
        let update = try #require(await rig.updates().last)
        #expect(try RF.state(update)["wetSharePercent"] as? Int == 7)     // 6 of 81 cells: unknown cells are not counted as wet
        // Unknown cells that cannot reach the need do not hold the activity: safely dry -> end.
        try await rig.run(2) { _ in .init(wet: 0, unknown: 2) }
        #expect(await rig.ends().count == 1)
    }

    @Test func nonLiveRegionKeepsTheAlertOnly() async throws {
        let repo = try await RF.prepared(region: false)
        #expect(try await repo.addSubscription(installationID: RF.installation, id: RF.region, RF.regionInput(live: false), maxPerInstallation: 10, now: run0) == .created)
        let rig = RF.Rig(repo: repo)
        try await rig.run(0, RF.regionWet(from: 3))
        try await rig.run(1, RF.regionWet(from: 2))
        #expect(await rig.starts().isEmpty)
        #expect(await rig.sender.requests.filter { $0.activityEvent == nil }.count == 1)
    }

    @Test func eightHourDeadlineEndsARegionActivityWithoutNewRuns() async throws {
        let repo = try await RF.prepared()
        #expect(try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0) == .updated)
        let sender = FakeApnsSender()
        let now = Locked(run0.addingTimeInterval(8 * 3600))
        let service = PushService(config: RF.config(), repo: repo, sender: sender, owner: "expiry", clock: { now.withLock { $0 } })
        _ = try await service.tick()
        let end = try #require(await sender.requests.first)
        #expect(end.activityEvent == .end && end.tokenHex == RF.regionToken)
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
    }
}

/// Slot conflicts (decision 7 Nov 2026): one activity per installation; a point beats a region.
@Suite("Region Live Activity: slot conflict between point and region")
struct RegionActivitySlotConflictTests {
    @Test func runningPointBlocksRegionStart() async throws {
        let repo = try await RF.prepared(point: true, armed: true)
        #expect(try await repo.reserveActivity(subscriptionID: RF.point, now: run0))
        #expect(try await repo.setActivityToken(subscriptionID: RF.point, token: RF.pointToken, now: run0) == .updated)
        let rig = RF.Rig(repo: repo)
        try await rig.run(0, RF.both(point: 0, region: 0))      // both rain; the point activity keeps running, the armed region wants to start
        #expect(await rig.starts().isEmpty)
        #expect(await rig.ends().isEmpty)                       // the point activity is untouched
        #expect(await rig.updates().map(\.tokenHex) == [RF.pointToken])
        #expect(try await repo.activityTarget(subscriptionID: RF.point)?.activity?.activityToken == RF.pointToken)
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
    }

    @Test func reservedPointBlocksRegionStart() async throws {
        let repo = try await RF.prepared(point: true, armed: true)
        #expect(try await repo.reserveActivity(subscriptionID: RF.point, now: run0))        // start in flight, no token yet
        let rig = RF.Rig(repo: repo)
        try await rig.run(0, RF.both(point: 0, region: 0))
        #expect(await rig.starts().isEmpty)
        let held = try #require(try await repo.activityTarget(subscriptionID: RF.point)?.activity)
        #expect(held.activityToken == nil)                      // the point reservation stays, the region did not take the slot
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
    }

    @Test func pointDisplacesRunningRegionWithCleanEndAndTakesTheSlot() async throws {
        let repo = try await RF.prepared(point: true)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0))
        #expect(try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0) == .updated)
        let rig = RF.Rig(repo: repo)
        try await rig.run(0, RF.both(point: 3, region: 0))      // the region keeps raining; arms the point's forecast start
        try await rig.run(1, RF.both(point: 2, region: 0))      // confirmed onset: the point wants to start
        let requests = await rig.sender.requests.filter { $0.activityEvent != nil }
        // Run 0: update for the running region. Run 1: clean end of the region first, then the point start; no stale update after the end.
        #expect(requests.map(\.activityEvent) == [.update, .end, .start])
        #expect(requests[1].tokenHex == RF.regionToken && requests[2].tokenHex == RF.start)
        #expect((try RF.aps(requests[2])["attributes"] as? [String: Any])?["subscriptionID"] as? String == RF.point)
        #expect(try RF.aps(requests[1])["dismissal-date"] != nil)
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
        let pointActivity = try #require(try await repo.activityTarget(subscriptionID: RF.point)?.activity)
        #expect(pointActivity.activityToken == nil)             // reserved, the app reports the token next
        // The point payload has no region fields.
        #expect(try RF.state(requests[2])["wetSharePercent"] == nil)
    }

    @Test func displacedRegionIsFreedEvenWhenTheEndPushFails() async throws {
        let repo = try await RF.prepared(point: true)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0))
        _ = try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0)
        let sender = FakeApnsSender(script: [.retry("synthetic")])
        let service = PushService(config: RF.config(), repo: repo, sender: sender, owner: "displace", clock: { run0 })
        let target = try #require(try await repo.activityTarget(subscriptionID: RF.point))
        var result = PushTick(); result.isLeader = true
        try await service.evaluateActivity(target: target, classes: RF.pointClasses(), notify: true, reference: run0, now: run0, result: &result)
        let events = await sender.requests.map(\.activityEvent)
        #expect(events == [.end, .start])
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)    // slot freed despite the retry answer
        #expect(try await repo.activityTarget(subscriptionID: RF.point)?.activity != nil)
    }

    @Test func pointDoesNotDisplaceARegionStartThatIsStillInFlight() async throws {
        let repo = try await RF.prepared(point: true, armed: true)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0))         // reservation without token
        let rig = RF.Rig(repo: repo)
        try await rig.run(0, RF.both(point: 0, region: 0))      // armed point sees rain right now; the region start is still in flight
        #expect(await rig.sender.requests.filter { $0.activityEvent != nil }.isEmpty)
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity != nil)
        // The rain-now start is not lost: the immediate-start bit stays armed for the next run.
        #expect(try await repo.subscriptions(installationID: RF.installation).first { $0.id == RF.point }?.instantStart == true)
        // Once the region reports its token, the next run lets the point take over.
        _ = try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0)
        try await rig.run(1, RF.both(point: 0, region: 0))
        #expect(await rig.sender.requests.filter { $0.activityEvent != nil }.map(\.activityEvent) == [.end, .start])
    }

    @Test func regionNeverDisplacesAnotherRegion() async throws {
        let repo = try await RF.prepared(armed: true)
        #expect(try await repo.addSubscription(installationID: RF.installation, id: RF.region2, RF.regionInput(), maxPerInstallation: 10, now: run0) == .created)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0))
        _ = try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region2, now: run0, displacingRegion: false) == .busy)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region2, now: run0, displacingRegion: true) == .busy)      // even with the flag
    }

    @Test func pointAndRegionStartingInTheSameRunPointWinsWithoutRegionStartPush() async throws {
        let repo = try await RF.prepared(point: true, armed: true)
        let rig = RF.Rig(repo: repo)
        try await rig.run(0) { _ in .init(wet: 9, unknown: 0, cls: 3, point: 3) }     // both rain now, both armed
        let starts = await rig.starts()
        #expect(starts.count == 1)
        #expect((try RF.aps(starts[0])["attributes"] as? [String: Any])?["subscriptionID"] as? String == RF.point)
        #expect(await rig.ends().isEmpty)                       // no start-then-end flicker for the region
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
    }

    @Test func repositoryReservationContractMemory() async throws {
        let repo = try await RF.prepared(point: true)
        // Free slot.
        #expect(try await repo.reserveActivity(subscriptionID: RF.point, now: run0, displacingRegion: true) == .reserved)
        // A point is never displaced, not even by another point.
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0, displacingRegion: true) == .busy)
        #expect(try await repo.deleteActivity(subscriptionID: RF.point, matchingToken: nil))
        // Region with token is displaced by a point; a tokenless region reservation is reported as pending.
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0))
        #expect(try await repo.reserveActivity(subscriptionID: RF.point, now: run0, displacingRegion: true) == .regionReservationPending)
        _ = try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0)
        #expect(try await repo.reserveActivity(subscriptionID: RF.point, now: run0, displacingRegion: false) == .busy)
        #expect(try await repo.reserveActivity(subscriptionID: RF.point, now: run0, displacingRegion: true) == .displaced(subscriptionID: RF.region, activityToken: RF.regionToken))
        #expect(try await repo.activityTarget(subscriptionID: RF.region)?.activity == nil)
        #expect(try await repo.activityTarget(subscriptionID: RF.point)?.activity != nil)
    }

    @Test func reevalNamesTheDisplacementAndCircleActivityIsEligible() async throws {
        let repo = try await RF.prepared(point: true)
        #expect(try await repo.reserveActivity(subscriptionID: RF.region, now: run0))
        _ = try await repo.setActivityToken(subscriptionID: RF.region, token: RF.regionToken, now: run0)
        let activity = try #require(try await repo.activityTarget(subscriptionID: RF.region)?.activity)
        let region = try #require(try await repo.subscriptions(installationID: RF.installation).first { $0.id == RF.region })
        // The region itself sees its running activity as busy ...
        #expect(PushService.decide(sub: region.with(wetSeen: true), classes: RF.pointClasses(), hasStartToken: true, activity: activity, now: run0) == "activity_slot_busy")
        // ... an eligible region without activity would trigger.
        #expect(PushService.decide(sub: region, classes: RF.pointClasses(onset: 2), hasStartToken: true, activity: nil, now: run0) == "would_trigger")
    }
}

extension RF {
    static func pointClasses(onset: Int = 0) -> [Int] { (0..<TimeUtil.forecastSlots).map { $0 >= onset ? 3 : 0 } }
}

/// The atomic reservation of the real MariaDB repository, same contract as the memory one (runs with `RADAR_TEST_DB_HOST` only).
extension DatabaseSuites {
    @Suite("Region Live Activity repository", .serialized)
    struct RegionActivityRepositoryTests {
        @Test(arguments: RepoKind.allCases) func displacementContract(kind: RepoKind) async throws {
            let repo = try await kind.make()
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let install = UUID().uuidString.lowercased()
            _ = try await repo.upsertInstallation(id: install, secretHash: Hashing.sha256Hex(Array("s".utf8)), token: String(repeating: "ab", count: 32),
                                                  env: .sandbox, locale: "de", now: now, maxInstallations: 100)
            try await repo.setLiveActivityStartToken(installationID: install, token: String(repeating: "cd", count: 32))
            let point = UUID().uuidString.lowercased(), region = UUID().uuidString.lowercased(), region2 = UUID().uuidString.lowercased()
            #expect(try await repo.addSubscription(installationID: install, id: point, RF.pointInput(), maxPerInstallation: 10, now: now) == .created)
            #expect(try await repo.addSubscription(installationID: install, id: region, RF.regionInput(), maxPerInstallation: 10, now: now) == .created)
            #expect(try await repo.addSubscription(installationID: install, id: region2, RF.regionInput(), maxPerInstallation: 10, now: now) == .created)
            // Circles are eligible for the activity; the armed bit is set like for points.
            #expect(try await repo.subscriptions(installationID: install).filter { $0.kind == .circle }.allSatisfy { $0.instantStart && $0.liveActivity })
            #expect(try await repo.reserveActivity(subscriptionID: region, now: now, displacingRegion: false) == .reserved)
            #expect(try await repo.reserveActivity(subscriptionID: region2, now: now, displacingRegion: true) == .busy)          // region never displaces
            #expect(try await repo.reserveActivity(subscriptionID: point, now: now, displacingRegion: true) == .regionReservationPending)
            let token = String(repeating: "12", count: 32)
            #expect(try await repo.setActivityToken(subscriptionID: region, token: token, now: now) == .updated)
            #expect(try await repo.reserveActivity(subscriptionID: point, now: now, displacingRegion: false) == .busy)
            #expect(try await repo.reserveActivity(subscriptionID: point, now: now, displacingRegion: true) == .displaced(subscriptionID: region, activityToken: token))
            #expect(try await repo.activityTarget(subscriptionID: region)?.activity == nil)
            #expect(try await repo.activityTarget(subscriptionID: point)?.activity != nil)
            // A point is never displaced.
            #expect(try await repo.reserveActivity(subscriptionID: region, now: now, displacingRegion: true) == .busy)
            #expect(try await repo.deleteActivity(subscriptionID: point, matchingToken: nil))
            // A region activity ends with its subscription's opt-out like a point one (kind no longer excludes it).
            #expect(try await repo.reserveActivity(subscriptionID: region, now: now))
            let endable = try await repo.endableActivities(now: now, reservationTimeout: 900, after: nil, limit: 10)
            #expect(endable.isEmpty)
            var off = RF.regionInput(); off.liveActivity = false
            #expect(try await repo.updateSubscription(installationID: install, id: region, off, regionLimits: .standard))
            #expect(try await repo.endableActivities(now: now, reservationTimeout: 900, after: nil, limit: 10).map(\.subscription.id) == [region])
        }
    }
}
