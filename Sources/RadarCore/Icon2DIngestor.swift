import Foundation

/// Source addresses and file names of the DWD open-data ICON-D2 GRIB files (checked 8 Nov 2026 against the real directory).
public enum Icon2D {
    public static let baseURL = "https://opendata.dwd.de/weather/nwp/icon-d2/grib"
    public static let forecastHours = 48
    /// A run is published about 80 minutes after its reference time (06 UTC: hour 0 at 06:44, hour 48 at 07:21 UTC); no listing before.
    public static let availabilityDelay: TimeInterval = 75 * 60
    /// Upper bound of one decompressed file (a real one has 1.62 MB).
    static let maxUnpackedBytes = 4_000_000
    /// Upper bound of the directory listing we are willing to read.
    static let maxListingBytes = 2_000_000
    /// libwebp effort for the stepped images: method 4 takes 0.2 s per slot for +0.5 % size, the default method 6 takes 3.4 s
    /// (measured 8 Nov 2026 on real files, Release, 1024 x 1311).
    static let webpMethod: Int32 = 4

    private static func runStamp(_ run: Date) -> String {
        let id = TimeUtil.toID(run)  // 20261108T0600Z
        return String(id.prefix(8)) + String(id.dropFirst(9).prefix(2))
    }

    public static func hour(of run: Date) -> String { String(runStamp(run).suffix(2)) }

    public static func fileName(run: Date, hour: Int, variable: String) -> String {
        "icon-d2_germany_regular-lat-lon_single-level_\(runStamp(run))_\(String(format: "%03d", hour))_2d_\(variable).grib2.bz2"
    }

    public static func directoryURL(run: Date, variable: String) -> String { "\(baseURL)/\(hour(of: run))/\(variable)/" }

    public static func url(run: Date, hour: Int, variable: String) -> String {
        directoryURL(run: run, variable: variable) + fileName(run: run, hour: hour, variable: variable)
    }

    /// Whether the directory listing offers all 49 hourly files (0 to 48) of this run and variable. Only the regular-lat-lon grid counts
    /// (the icosahedral files of the same directory are another product). Complete = the run is fully published, so 49 downloads follow.
    public static func listingIsComplete(_ listing: [UInt8], run: Date, variable: String) -> Bool {
        let text = String(decoding: listing, as: UTF8.self)
        return (0...forecastHours).allSatisfy { text.contains("\"\(fileName(run: run, hour: $0, variable: variable))\"") }
    }
}

extension LayerIngestor {
    /// Failure classes: `unavailable` (run not (completely) published), `fetch`-like errors become `RunUnavailable`, anything the
    /// file itself gets wrong (not bz2, not the expected GRIB, wrong variable/time, implausible values) is `invalid` and gives up the run.
    private func d2Variable() -> TempKind? {
        switch spec.id {
        case TempLayers.d2Temperature: return .temperatureC
        case TempLayers.d2Dewpoint: return .dewpointC
        case TempLayers.d2Humidity: return .relhumPercent
        default: return nil
        }
    }

    /// One ingest tick of an ICON-D2 layer: newest and previous run of the configured interval, each only if its directory listing shows
    /// all 49 files; downloads one file at a time with a pause (fair use), publishes only a complete run. Raw values are dropped after rendering.
    func tickIcon2D() async throws -> LayerTickResult {
        var result = LayerTickResult()
        guard let kind = d2Variable(), kind == .temperatureC || config.temp.d2Params.contains(kind.variable) else { return result }  // t_2m is always on
        guard let scale = TempScale.load(id: spec.scaleID ?? kind.scaleID) else { throw ImageError.invalid("scale \(kind.scaleID) unknown") }
        guard try await repo.acquireLeader(name: leaderName, owner: owner, leaseSeconds: Self.leaderLeaseSeconds) else { return result }
        result.isLeader = true
        let interval = Double(config.temp.d2RunIntervalHours) * 3600
        let newest = TimeUtil.floor(clock().addingTimeInterval(-Icon2D.availabilityDelay), to: interval)
        for run in [newest, newest.addingTimeInterval(-interval)] {
            let runID = TimeUtil.toID(run)
            if try await repo.layerIsPublished(layer: spec.id, runID: runID) { break }
            let listing: [UInt8]
            do { listing = try await fetch(Icon2D.directoryURL(run: run, variable: kind.variable)) } catch is CancellationError { throw CancellationError() } catch {
                result.failed += 1; result.failureClass = "fetch"; continue
            }
            guard Icon2D.listingIsComplete(listing, run: run, variable: kind.variable) else {
                result.failed += 1; result.failureClass = "unavailable"; continue
            }
            switch try await processIcon2D(run: run, kind: kind, scale: scale, result: &result) {
            case .published: result.published = runID; return result
            case .unavailable: continue
            case .busy: return result
            }
        }
        return result
    }

    private func processIcon2D(run: Date, kind: TempKind, scale: TempScale, result: inout LayerTickResult) async throws -> ForecastOutcome {
        let runID = TimeUtil.toID(run)
        let started = clock()
        guard try await repo.layerTryClaim(layer: spec.id, runID: runID, nominal: run, owner: owner,
                                           leaseSeconds: Self.runLeaseSeconds, maxAttempts: Self.forecastMaxAttempts) else { return .busy }
        let width = spec.width(config)
        do {
            for hour in 0...Icon2D.forecastHours {
                if hour > 0 { await sleep(config.layerPauseSeconds) }
                try await keepD2Leadership(runID: runID)
                let slot = run.addingTimeInterval(Double(hour) * 3600)
                let data = try await d2SlotImage(run: run, hour: hour, kind: kind, scale: scale, width: width)
                try await repo.layerPutSlot(layer: spec.id, SlotRef(runID: runID, slotID: TimeUtil.toID(slot), slotIndex: hour, slotTime: slot),
                                            contentType: Manifest.contentType, data: data)
                result.stored += 1
            }
            guard try await repo.layerPublish(layer: spec.id, runID: runID, owner: owner, expectedSlots: Icon2D.forecastHours + 1) else { throw LeaseLost() }
        } catch is LeaseLost {
            return .busy
        } catch is CancellationError {
            try? await repo.layerFail(layer: spec.id, runID: runID, owner: owner, cooldownSeconds: 0)
            throw CancellationError()
        } catch {
            // 5 minutes of cooldown like every forecast layer; an `invalid` file (changed format) repeats until the claims are used up.
            try? await repo.layerFail(layer: spec.id, runID: runID, owner: owner, cooldownSeconds: 300)
            result.failed += 1
            result.failureClass = LayerTickResult.classify(error)
            throw error
        }
        _ = try? await repo.layerRetain(layer: spec.id, keepNewest: config.pressureRetentionRuns,
                                        keepSince: Date(timeIntervalSince1970: 4_000_000_000), staleAfter: Self.staleAfter)
        let now = clock()
        stats.observe("ingest_lag", key: spec.id, seconds: now.timeIntervalSince(run))
        stats.observe("ingest_dur", key: spec.id, seconds: now.timeIntervalSince(started))
        return .published
    }

    private func keepD2Leadership(runID: String) async throws {
        guard try await repo.acquireLeader(name: leaderName, owner: owner, leaseSeconds: Self.leaderLeaseSeconds) else { throw LeaseLost() }
        guard try await repo.layerRenew(layer: spec.id, runID: runID, owner: owner, leaseSeconds: Self.runLeaseSeconds) else { throw LeaseLost() }
    }

    /// Download (3 attempts for transport errors), bz2, GRIB, checks, render, lossless WebP of one hour.
    func d2SlotImage(run: Date, hour: Int, kind: TempKind, scale: TempScale, width: Int) async throws -> [UInt8] {
        let url = Icon2D.url(run: run, hour: hour, variable: kind.variable)
        var packed: [UInt8]?
        var last: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { packed = try await fetch(url); break } catch is CancellationError { throw CancellationError() } catch {
                last = error
                if attempt < 2 { await sleep(Double([3, 8][attempt]) * (1 + Double.random(in: 0..<0.5))) }
            }
        }
        guard let packed else { throw RunUnavailable(description: "\(spec.id) fetch failed: \(last.map { String(describing: type(of: $0)) } ?? "unknown")") }
        do {
            let raw = try Bzip2.decompress(packed, maxOutput: Icon2D.maxUnpackedBytes)
            let field = try GribDecoder.decode(raw, expecting: d2Grid)
            guard field.referenceTime == run, field.forecastMinutes == hour * 60 else { throw ImageError.invalid("grib time does not match the file name") }
            try MercatorRender.validate(field, kind: kind)
            return try ImagePipeline.toWebP(MercatorRender.image(field: field, kind: kind, scale: scale, bbox: spec.bbox, width: width), lossless: true, method: Icon2D.webpMethod)
        } catch let error as ImageError {
            throw error
        } catch {
            throw ImageError.invalid(String(describing: error))
        }
    }
}
