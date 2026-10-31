import Foundation

public struct LayerTickResult: Sendable, Equatable {
    public var isLeader = false
    public var stored = 0
    public var failed = 0
    public var published: String?
}

/// Ingest of one additional layer. Only the leader replica of a layer works (lease `layer:<id>`), one request at a time with a
/// pause between requests, bounded retries (the sources answer sporadically with HTTP 500 or XML errors) and a completeness
/// check before anything is published.
public final class LayerIngestor: Sendable {
    public static let leaderLeaseSeconds = 240
    public static let runLeaseSeconds = 150
    public static let maxSlotAttempts = 4
    public static let failCooldownSeconds = 150
    public static let slotsPerTick = 8
    public static let forecastRunInterval: TimeInterval = 6 * 3600
    public static let staleAfter: TimeInterval = 3600

    public let spec: LayerSpec
    let config: Config
    let repo: any Repo
    let fetch: Fetch
    let owner: String
    let sleep: @Sendable (Double) async -> Void
    let clock: @Sendable () -> Date

    public init(spec: LayerSpec, config: Config, repo: any Repo, fetch: @escaping Fetch, owner: String,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.spec = spec; self.config = config; self.repo = repo; self.fetch = fetch; self.owner = owner
        self.sleep = sleep; self.clock = clock
    }

    public var leaderName: String { "layer:\(spec.id)" }
    private var layer: String { spec.id }

    public func release() async { try? await repo.releaseLeader(name: leaderName, owner: owner) }

    /// Validates, checks completeness and converts to WebP; throws for XML/truncated/incomplete images.
    func convert(_ bytes: [UInt8]) throws -> [UInt8] {
        let image = try ImagePipeline.validatePNG(bytes, width: config.width, height: config.height, sizeRange: 200...8_000_000)
        if spec.checkComplete {
            let black = ImagePipeline.blackCells(image)
            guard black == 0 else { throw ImageError.invalid("incomplete image (\(black) black cells)") }
        }
        return try ImagePipeline.toWebP(image, lossless: spec.lossless, quality: spec.webpQuality)
    }

    private func fetchWebP(url: String, attempts: Int, backoffs: [Double], before: () async throws -> Void) async throws -> [UInt8] {
        var last: Error?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try await before()
            do {
                return try convert(try await fetch(url))
            } catch is CancellationError {
                throw CancellationError()
            } catch is LeaseLost {
                throw LeaseLost()
            } catch {
                last = error
                if attempt + 1 < attempts { await sleep(backoffs[min(attempt, backoffs.count - 1)] * (1 + Double.random(in: 0..<0.5))) }
            }
        }
        throw RunUnavailable(description: "\(layer) fetch failed: \(last.map { String(describing: type(of: $0)) } ?? "unknown")")
    }

    private func keepLeadership() async throws {
        guard try await repo.acquireLeader(name: leaderName, owner: owner, leaseSeconds: Self.leaderLeaseSeconds) else { throw LeaseLost() }
    }

    private func ref(_ runID: String, _ slot: Date, _ index: Int) -> SlotRef {
        SlotRef(runID: runID, slotID: TimeUtil.toID(slot), slotIndex: index, slotTime: slot)
    }

    // MARK: observation (one run per slot)

    /// Newest slot that may be fetched: EUMETView from its capabilities (a future TIME answers 502), DWD from a fixed delay.
    func newestSlot() async throws -> Date? {
        if let url = LayerSources.capabilitiesURL(spec: spec, config: config) {
            var last: Error?
            for attempt in 0..<3 {
                do {
                    let bytes = try await fetch(url)
                    guard let name = spec.capsLayer,
                          let latest = LayerSources.latestSlot(capabilities: bytes, layerName: name)
                            ?? LayerSources.latestSlot(capabilities: bytes, layerName: spec.wmsLayer) else {
                        throw RunUnavailable(description: "\(layer): no time dimension in capabilities")
                    }
                    return TimeUtil.floor(latest, to: spec.stepSeconds)
                } catch is CancellationError { throw CancellationError() } catch {
                    last = error
                    if attempt < 2 { await sleep(3) }
                }
            }
            throw last ?? RunUnavailable(description: "\(layer): capabilities")
        }
        return TimeUtil.floor(clock().addingTimeInterval(-spec.availabilityDelay), to: spec.stepSeconds)
    }

    public func tickObservation() async throws -> LayerTickResult {
        var result = LayerTickResult()
        guard try await repo.acquireLeader(name: leaderName, owner: owner, leaseSeconds: Self.leaderLeaseSeconds) else { return result }
        result.isLeader = true
        guard let newest = try await newestSlot() else { return result }
        let hours = config.historyHours(for: spec)
        let count = Int(Double(hours) * 3600 / spec.stepSeconds)
        let oldest = newest.addingTimeInterval(-Double(count) * spec.stepSeconds)
        let have = Set(try await repo.layerFirstSlots(layer: layer, since: oldest, before: newest.addingTimeInterval(spec.stepSeconds)).map(\.slotTime))
        var budget = Self.slotsPerTick
        var inARow = 0
        for i in 0...count {
            let slot = newest.addingTimeInterval(-Double(i) * spec.stepSeconds)
            if have.contains(slot) { continue }
            guard budget > 0, inARow < 3 else { break }
            let runID = TimeUtil.toID(slot)
            guard try await repo.layerTryClaim(layer: layer, runID: runID, nominal: slot, owner: owner,
                                               leaseSeconds: Self.runLeaseSeconds, maxAttempts: Self.maxSlotAttempts) else { continue }
            budget -= 1
            do {
                let url = LayerSources.mapURL(spec: spec, config: config, run: slot, slot: slot)
                let data = try await fetchWebP(url: url, attempts: 2, backoffs: [3]) {
                    try await self.keepLeadership()
                    guard try await self.repo.layerRenew(layer: self.layer, runID: runID, owner: self.owner, leaseSeconds: Self.runLeaseSeconds)
                    else { throw LeaseLost() }
                }
                try await repo.layerPutSlot(layer: layer, ref(runID, slot, 0), contentType: Manifest.contentType, data: data)
                guard try await repo.layerPublish(layer: layer, runID: runID, owner: owner, expectedSlots: 1) else { throw LeaseLost() }
                result.stored += 1; inARow = 0
                result.published = runID
            } catch is LeaseLost {
                break
            } catch is CancellationError {
                try? await repo.layerFail(layer: layer, runID: runID, owner: owner, cooldownSeconds: 0)
                throw CancellationError()
            } catch {
                try? await repo.layerFail(layer: layer, runID: runID, owner: owner, cooldownSeconds: Self.failCooldownSeconds)
                result.failed += 1; inARow += 1
            }
            await sleep(config.layerPauseSeconds)
        }
        let keepSince = newest.addingTimeInterval(-(Double(hours) * 3600 + spec.stepSeconds))
        _ = try? await repo.layerRetain(layer: layer, keepNewest: 1, keepSince: keepSince, staleAfter: Self.staleAfter)
        return result
    }

    // MARK: forecast (one run per reference time)

    public func tickForecast() async throws -> LayerTickResult {
        var result = LayerTickResult()
        guard try await repo.acquireLeader(name: leaderName, owner: owner, leaseSeconds: Self.leaderLeaseSeconds) else { return result }
        result.isLeader = true
        let newest = TimeUtil.floor(clock(), to: Self.forecastRunInterval)
        for run in [newest, newest.addingTimeInterval(-Self.forecastRunInterval)] {
            let runID = TimeUtil.toID(run)
            if try await repo.layerIsPublished(layer: layer, runID: runID) { break }
            switch try await processForecast(run: run, result: &result) {
            case .published: result.published = runID; return result
            case .unavailable: continue
            case .busy: return result
            }
        }
        return result
    }

    enum ForecastOutcome { case published, unavailable, busy }

    func processForecast(run: Date, result: inout LayerTickResult) async throws -> ForecastOutcome {
        let runID = TimeUtil.toID(run)
        let slots = (0...config.pressureForecastHours).map { run.addingTimeInterval(Double($0) * spec.stepSeconds) }
        func url(_ slot: Date) -> String { LayerSources.mapURL(spec: spec, config: config, run: run, slot: slot) }
        // Probe slot 0 before claiming: a reference time that the source does not offer yet answers with an XML error.
        let first: [UInt8]
        do {
            first = try await fetchWebP(url: url(slots[0]), attempts: 2, backoffs: [3]) { try await self.keepLeadership() }
        } catch is RunUnavailable { result.failed += 1; return .unavailable }
        guard try await repo.layerTryClaim(layer: layer, runID: runID, nominal: run, owner: owner,
                                           leaseSeconds: Self.runLeaseSeconds, maxAttempts: 2) else { return .busy }
        do {
            try await repo.layerPutSlot(layer: layer, ref(runID, slots[0], 0), contentType: Manifest.contentType, data: first)
            result.stored += 1
            for (index, slot) in slots.enumerated().dropFirst() {
                await sleep(config.layerPauseSeconds)
                let data = try await fetchWebP(url: url(slot), attempts: 5, backoffs: [3, 6, 12, 20]) {
                    try await self.keepLeadership()
                    guard try await self.repo.layerRenew(layer: self.layer, runID: runID, owner: self.owner, leaseSeconds: Self.runLeaseSeconds)
                    else { throw LeaseLost() }
                }
                try await repo.layerPutSlot(layer: layer, ref(runID, slot, index), contentType: Manifest.contentType, data: data)
                result.stored += 1
            }
            guard try await repo.layerPublish(layer: layer, runID: runID, owner: owner, expectedSlots: slots.count) else { throw LeaseLost() }
        } catch is LeaseLost {
            return .busy
        } catch is CancellationError {
            try? await repo.layerFail(layer: layer, runID: runID, owner: owner, cooldownSeconds: 0)
            throw CancellationError()
        } catch {
            try? await repo.layerFail(layer: layer, runID: runID, owner: owner, cooldownSeconds: 300)
            result.failed += 1
            throw error
        }
        _ = try? await repo.layerRetain(layer: layer, keepNewest: config.pressureRetentionRuns,
                                        keepSince: Date(timeIntervalSince1970: 4_000_000_000), staleAfter: Self.staleAfter)
        return .published
    }

    public func tick() async throws -> LayerTickResult {
        spec.kind == .forecast ? try await tickForecast() : try await tickObservation()
    }
}

/// Manifest of one additional layer: /v1/layers/<layer>/latest.json (schema 1). Paths are relative to /v1/layers/<layer>/.
public enum LayerManifest {
    public static func build(repo: any Repo, config: Config, spec: LayerSpec) async throws -> [UInt8]? {
        guard let latest = try await repo.layerLatestPublished(layer: spec.id) else { return nil }
        var entries: [String] = []
        let tail: String
        switch spec.kind {
        case .forecast:
            let slots = try await repo.layerPublishedSlots(layer: spec.id, runID: latest.runID)
            entries = slots.map { entry($0, kind: $0.slotTime == latest.nominal ? "analysis" : "forecast") }
            let horizon = Int((slots.last?.slotTime.timeIntervalSince(latest.nominal) ?? 0) / 60)
            tail = "\"forecast_horizon_minutes\":\(horizon),"
        case .observation:
            let hours = config.historyHours(for: spec)
            let since = latest.nominal.addingTimeInterval(-Double(hours) * 3600)
            let slots = try await repo.layerFirstSlots(layer: spec.id, since: since, before: latest.nominal.addingTimeInterval(spec.stepSeconds))
            entries = slots.map { entry($0, kind: "observation") }
            tail = "\"history_hours\":\(hours),"
        }
        let year = TimeUtil.year(of: latest.publishedAt)
        var json = "{\"schema\":1,\"layer\":\(Manifest.jsonString(spec.id)),\"title\":\(Manifest.jsonString(spec.title)),"
            + "\"kind\":\"\(spec.kind.rawValue)\",\"run\":\(Manifest.jsonString(latest.runID)),"
            + "\"reference_time\":\(Manifest.jsonString(TimeUtil.toISO(latest.nominal))),"
            + "\"generated_at\":\(Manifest.jsonString(TimeUtil.toISO(latest.publishedAt))),"
            + "\"step_minutes\":\(spec.stepMinutes),\(tail)"
            + "\"image\":\(Manifest.imageJSON(config: config)),\"slots\":[\(entries.joined(separator: ","))],"
            + "\"attribution\":\(Manifest.jsonString(spec.attribution(year: year))),"
            + "\"modification_notice\":\(Manifest.jsonString(spec.modificationNotice))"
        if let legend = spec.legend {
            json += ",\"legend\":{\"url\":\(Manifest.jsonString(legend.url)),\"width\":\(legend.width),\"height\":\(legend.height)}"
        }
        return Array((json + "}\n").utf8)
    }

    private static func entry(_ ref: SlotRef, kind: String) -> String {
        "{\"time\":\(Manifest.jsonString(TimeUtil.toISO(ref.slotTime))),\"kind\":\"\(kind)\","
            + "\"path\":\(Manifest.jsonString(Manifest.slotPath(runID: ref.runID, slotID: ref.slotID)))}"
    }
}
