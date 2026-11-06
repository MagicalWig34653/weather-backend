import Foundation
import Testing
@testable import RadarCore

// End-to-end chain of the rain evaluation with synthetic radar images (invented points only, no real locations):
// coordinate -> raster cell -> pixel in the stored WebP -> palette class -> measurement/diagnosis. Memory repository.
private let installID = "11111111-1111-4111-8111-111111111111"
private let secretHash = Hashing.sha256Hex(Array(String(repeating: "a", count: 40).utf8))
private let deviceToken = String(repeating: "ab", count: 32)

private func fullConfig() -> Config {
    var c = Config()
    c.width = 1024
    c.push.enabled = true; c.push.topic = "de.example.app"; c.push.environments = [.sandbox, .production]
    return c
}

private func blank(_ c: Config) -> RGBAImage {
    var pixels = [UInt8](repeating: 0, count: c.width * c.height * 4)
    for i in 0..<(c.width * c.height) { pixels[i * 4] = 255; pixels[i * 4 + 1] = 255; pixels[i * 4 + 2] = 255 }   // transparent white, as the DWD renders it
    return RGBAImage(width: c.width, height: c.height, pixels: pixels)
}

private func paint(_ image: inout RGBAImage, x: Int, y: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
    var pixels = image.pixels
    let o = (y * image.width + x) * 4
    pixels[o] = rgba.0; pixels[o + 1] = rgba.1; pixels[o + 2] = rgba.2; pixels[o + 3] = rgba.3
    image = RGBAImage(width: image.width, height: image.height, pixels: pixels)
}

private func legend(_ cls: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let c = PushIntensity.palette[cls - 1]
    return (UInt8(c.r), UInt8(c.g), UInt8(c.b), 255)
}

private func publish(_ repo: MemoryRepo, nominal: Date, slot0: RGBAImage, later: RGBAImage? = nil) async throws {
    let id = TimeUtil.toID(nominal)
    #expect(try await repo.tryClaim(runID: id, nominal: nominal, owner: "t", leaseSeconds: 60, maxAttempts: 2))
    let first = try ImagePipeline.toWebP(slot0)
    let rest = try later.map { try ImagePipeline.toWebP($0) } ?? first
    for (index, slot) in TimeUtil.slots(of: nominal).enumerated() {
        try await repo.putSlot(SlotRef(runID: id, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot), contentType: "image/webp", data: index == 0 ? first : rest)
    }
    #expect(try await repo.publish(runID: id, owner: "t", expectedSlots: TimeUtil.forecastSlots))
}

private func sub(_ id: String, x: Int, y: Int, threshold: Int, live: Bool = false, circle: Int? = nil, share: Int = 10) -> PushSubscription {
    PushSubscription(id: id, gridVersion: 1, cellX: x, cellY: y, threshold: threshold, leadMinutes: 20, enabled: true,
                     kind: circle == nil ? .point : .circle, radiusCells: circle, minSharePercent: circle == nil ? nil : share, liveActivity: live)
}

@Suite("Push chain: coordinate to class")
struct PushChainTests {
    @Test func coordinateToCellAndBack() {
        // Invented points spread over the raster. x grows eastwards, y grows southwards (row 0 = northern edge).
        let points: [(lat: Double, lon: Double)] = [(53.0, 11.0), (50.0, 10.0), (47.5, 7.5), (51.5, 13.5)]
        var cells: [(x: Int, y: Int)] = []
        for p in points {
            let mx = PushGrid.earthRadius * p.lon * .pi / 180
            let my = PushGrid.earthRadius * log(tan(.pi / 4 + p.lat * .pi / 360))
            let cell = PushGrid.cell(mercatorX: mx, mercatorY: my, width: 1024)
            #expect(cell != nil)
            guard let cell else { continue }
            cells.append(cell)
            let back = PushGrid.coordinate(cellX: cell.x, cellY: cell.y, width: 1024)
            #expect(back != nil)
            // One cell is about 1 km (0.01 degrees): the rounded centre lies within a cell of the input.
            #expect(abs((back?.lat ?? 0) - p.lat) <= 0.011 && abs((back?.lon ?? 0) - p.lon) <= 0.011)
        }
        #expect(cells[0].y < cells[1].y && cells[1].y < cells[2].y)         // further north = smaller row
        #expect(cells[2].x < cells[1].x && cells[1].x < cells[3].x)         // further east = larger column
        #expect(PushGrid.coordinate(cellX: 1024, cellY: 0, width: 1024) == nil)
        #expect(PushGrid.cell(mercatorX: 0, mercatorY: 0, width: 1024) == nil)   // outside the raster
    }

    @Test func everyLegendColourSurvivesWebPAndLandsInItsClassAtTheRightPixel() async throws {
        let config = fullConfig()
        var image = blank(config)
        var subs: [PushSubscription] = []
        for cls in 1...15 {
            // Column and row differ on purpose (x != y) so that a swapped axis finds a different pixel.
            let x = 100 + cls * 7, y = 900 - cls * 11
            paint(&image, x: x, y: y, legend(cls))
            paint(&image, x: y, y: x, legend(16 - cls))   // the mirrored pixel holds another class
            subs.append(sub("s\(cls)", x: x, y: y, threshold: 1))
        }
        let repo = MemoryRepo()
        let nominal = TimeUtil.floorStep(Date().addingTimeInterval(-300))
        try await publish(repo, nominal: nominal, slot0: image)
        let view = await DeviceRadarView.load(repo: repo, config: config, subs: subs, now: nominal.addingTimeInterval(120))
        #expect(view.status == .ok && view.runNominal == nominal)
        for cls in 1...15 {
            #expect(view.classes["s\(cls)"]?.first == cls)
            #expect(view.measures["s\(cls)"]?.first?.maxClass == cls)
        }
        // Neighbouring pixels are dry.
        let neighbour = sub("n", x: 101 + 7, y: 900 - 11, threshold: 1)
        let v2 = await DeviceRadarView.load(repo: repo, config: config, subs: [neighbour], now: nominal.addingTimeInterval(120))
        #expect(v2.classes["n"]?.first == 0)
    }

    @Test func rainAtTheCellOfAnInventedCoordinateIsMeasured() async throws {
        let config = fullConfig()
        let lat = 50.0, lon = 10.0
        let cell = try #require(PushGrid.cell(mercatorX: PushGrid.earthRadius * lon * .pi / 180,
                                              mercatorY: PushGrid.earthRadius * log(tan(.pi / 4 + lat * .pi / 360)), width: config.width))
        var image = blank(config)
        paint(&image, x: cell.x, y: cell.y, legend(2))       // light rain (0.2 to 0.4 mm/h)
        let repo = MemoryRepo()
        let nominal = TimeUtil.floorStep(Date().addingTimeInterval(-300))
        try await publish(repo, nominal: nominal, slot0: image)
        let light = sub("light", x: cell.x, y: cell.y, threshold: 3)
        let any = sub("any", x: cell.x, y: cell.y, threshold: 1, live: true)
        let view = await DeviceRadarView.load(repo: repo, config: config, subs: [light, any], now: nominal.addingTimeInterval(120))
        #expect(view.classes["light"]?.first == 2)
        // The rain is real, but below class 3: "Leicht" (class 3, from 0.4 mm/h) does not fire, class 1 does.
        #expect(PushService.decide(sub: light, classes: view.classes["light"] ?? [], hasStartToken: true, activity: nil, now: nominal) == "below_threshold")
        #expect(PushService.decide(sub: any.with(wetSeen: true), classes: view.classes["any"] ?? [], hasStartToken: true, activity: nil, now: nominal) == "would_trigger")
        let fields = PushMeasureJSON.fields(light, measures: view.measures["light"], radarOK: true, width: config.width)
        #expect(fields["measuredClass"] as? Int == 2 && fields["pixel"] as? String == "rain")
        #expect(fields["measuredMmPerHour"] as? Double == 0.2 && fields["thresholdMmPerHour"] as? Double == 0.4)
        #expect(PushMeasureJSON.reason(light, decision: "below_threshold", measures: view.measures["light"], radar: .ok) == "class_below_threshold")
    }

    @Test func dryUnknownAndMaskPixelsAreTold() async throws {
        let config = fullConfig()
        var image = blank(config)
        paint(&image, x: 500, y: 600, (126, 126, 126, 77))        // "no data" grey mask
        paint(&image, x: 501, y: 600, (200, 10, 200, 255))        // colour outside the legend
        let repo = MemoryRepo()
        let nominal = TimeUtil.floorStep(Date().addingTimeInterval(-300))
        try await publish(repo, nominal: nominal, slot0: image)
        let subs = [sub("dry", x: 10, y: 10, threshold: 3, live: true), sub("mask", x: 500, y: 600, threshold: 3, live: true),
                    sub("odd", x: 501, y: 600, threshold: 3, live: true), sub("maskAlert", x: 500, y: 600, threshold: 3)]
        let view = await DeviceRadarView.load(repo: repo, config: config, subs: subs, now: nominal.addingTimeInterval(60))
        #expect(view.measures["dry"]?.first?.maxClass == 0)
        #expect(view.measures["mask"]?.first?.maxClass == -1 && view.measures["odd"]?.first?.maxClass == -1)
        #expect(view.measures["maskAlert"]?.first?.maxClass == -1)     // diagnosis separates unknown from dry for every kind
        #expect(view.classes["maskAlert"]?.first == 0)                  // the alert automaton still treats it as dry
        #expect(PushMeasureJSON.reason(subs[1], decision: "below_threshold", measures: view.measures["mask"], radar: .ok) == "pixel_unknown")
        #expect(PushMeasureJSON.reason(subs[0], decision: "below_threshold", measures: view.measures["dry"], radar: .ok) == "cell_dry")
    }

    @Test func circleCountsCellsAndReportsShare() async throws {
        let config = fullConfig()
        var image = blank(config)
        let cx = 400, cy = 500, radius = 10
        // Four cells of class 2 inside the disc (need = 4 at 1 % of 317 cells): nothing is wet at threshold 3, but at threshold 2.
        for dx in 0..<4 { paint(&image, x: cx + dx, y: cy, legend(2)) }
        paint(&image, x: cx + radius + 5, y: cy, legend(9))        // outside the disc: ignored
        let repo = MemoryRepo()
        let nominal = TimeUtil.floorStep(Date().addingTimeInterval(-300))
        try await publish(repo, nominal: nominal, slot0: image)
        let strict = sub("strict", x: cx, y: cy, threshold: 3, circle: radius, share: 1)
        let loose = sub("loose", x: cx, y: cy, threshold: 2, circle: radius, share: 1)
        let view = await DeviceRadarView.load(repo: repo, config: config, subs: [strict, loose], now: nominal.addingTimeInterval(60))
        let a = try #require(view.measures["strict"]?.first), b = try #require(view.measures["loose"]?.first)
        #expect(a.maxClass == 2 && a.wetCells == 0 && a.cells == PushRegion.cellCount(radius: radius))
        #expect(b.maxClass == 2 && b.wetCells == 4 && b.neededCells == 4)
        // The measurement agrees with the production rule (pseudo class).
        #expect(view.classes["strict"]?.first == 0)
        #expect(view.classes["loose"]?.first == 2)     // 4 cells >= need: threshold class is the pseudo class
        #expect(PushMeasureJSON.reason(strict, decision: "below_threshold", measures: view.measures["strict"], radar: .ok) == "share_below")
        let fields = PushMeasureJSON.fields(strict, measures: view.measures["strict"], radarOK: true, width: config.width)
        #expect(fields["wetCells"] as? Int == 0 && fields["sharePercent"] as? Double == 0 && fields["neededCells"] as? Int == a.neededCells)
    }

    @Test func staleRunIsReportedAndOnlyDecodedOnRequest() async throws {
        let config = fullConfig()
        var image = blank(config)
        paint(&image, x: 300, y: 400, legend(4))
        let repo = MemoryRepo()
        let nominal = TimeUtil.floorStep(Date().addingTimeInterval(-3600))
        try await publish(repo, nominal: nominal, slot0: image)
        let s = sub("a", x: 300, y: 400, threshold: 3)
        let now = nominal.addingTimeInterval(3000)
        let plain = await DeviceRadarView.load(repo: repo, config: config, subs: [s], now: now)
        #expect(plain.status == .staleRun && plain.measures.isEmpty && plain.runNominal == nominal)
        let detailed = await DeviceRadarView.load(repo: repo, config: config, subs: [s], now: now, allowStale: true)
        #expect(detailed.status == .staleRun && detailed.measures["a"]?.first?.maxClass == 4)
        #expect(PushMeasureJSON.reason(s, decision: "below_threshold", measures: detailed.measures["a"], radar: .staleRun) == "radar_stale")
        let empty = await DeviceRadarView.load(repo: MemoryRepo(), config: config, subs: [s], now: now)
        #expect(empty.status == .noSlot && empty.runNominal == nil)
    }

    @Test func updatingAnActivitySubscriptionArmsTheImmediateStartAgain() async throws {
        let repo = MemoryRepo()
        _ = try await repo.upsertInstallation(id: installID, secretHash: secretHash, token: deviceToken, env: .sandbox, locale: "de", now: Date(), maxInstallations: 10)
        let id = "33333333-3333-4333-8333-333333333333"
        _ = try await repo.addSubscription(installationID: installID, id: id, .init(gridVersion: 1, cellX: 10, cellY: 20, threshold: 5, leadMinutes: 20, enabled: true, liveActivity: true), maxPerInstallation: 10, now: Date())
        try await repo.setStartRetry(subscriptionID: id, armed: false, attempts: 2)
        func stored() async throws -> PushSubscription { try #require(try await repo.subscriptions(installationID: installID).first) }
        #expect(try await !stored().instantStart)
        // The app uploads the changed threshold as an update of the same subscription.
        #expect(try await repo.updateSubscription(installationID: installID, id: id, .init(gridVersion: 1, cellX: 10, cellY: 20, threshold: 3, leadMinutes: 20, enabled: true, liveActivity: true), regionLimits: .standard))
        let after = try await stored()
        #expect(after.threshold == 3 && after.instantStart && after.startAttempts == 0 && !after.wetSeen)
    }
}
