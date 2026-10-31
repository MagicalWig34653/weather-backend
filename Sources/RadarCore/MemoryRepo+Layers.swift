import Foundation

extension MemoryRepo {
    private func key(_ layer: String, _ runID: String) -> String { "\(layer)/\(runID)" }

    public func layerTryClaim(layer: String, runID: String, nominal: Date, owner: String, leaseSeconds: Int, maxAttempts: Int) async throws -> Bool {
        let current = clockNow()
        let k = key(layer, runID)
        guard var run = layerRuns[k] else {
            layerRuns[k] = Run(nominal: nominal, status: "claimed", owner: owner, attempts: 1, lease: current.addingTimeInterval(Double(leaseSeconds)))
            return true
        }
        if run.status == "published" || run.lease >= current || run.attempts >= maxAttempts { return false }
        run.status = "claimed"; run.owner = owner; run.attempts += 1
        run.lease = current.addingTimeInterval(Double(leaseSeconds))
        layerRuns[k] = run
        return true
    }

    public func layerRenew(layer: String, runID: String, owner: String, leaseSeconds: Int) async throws -> Bool {
        let k = key(layer, runID)
        guard var run = layerRuns[k], run.owner == owner, run.status == "claimed" else { return false }
        run.lease = clockNow().addingTimeInterval(Double(leaseSeconds))
        layerRuns[k] = run
        return true
    }

    public func layerPutSlot(layer: String, _ ref: SlotRef, contentType: String, data: [UInt8]) async throws {
        layerSlots[key(layer, ref.runID), default: [:]][ref.slotID] = (ref, contentType, Hashing.sha256Hex(data), data)
    }

    public func layerPublish(layer: String, runID: String, owner: String, expectedSlots: Int) async throws -> Bool {
        let k = key(layer, runID)
        guard var run = layerRuns[k], run.status == "claimed", run.owner == owner else { return false }
        guard (layerSlots[k]?.count ?? 0) == expectedSlots else { return false }
        run.status = "published"; run.publishedAt = clockNow()
        layerRuns[k] = run
        return true
    }

    public func layerFail(layer: String, runID: String, owner: String, cooldownSeconds: Int) async throws {
        let k = key(layer, runID)
        guard var run = layerRuns[k], run.owner == owner, run.status == "claimed" else { return }
        run.status = "failed"; run.lease = clockNow().addingTimeInterval(Double(cooldownSeconds))
        layerRuns[k] = run
    }

    public func layerIsPublished(layer: String, runID: String) async throws -> Bool { layerRuns[key(layer, runID)]?.status == "published" }

    public func layerLatestPublished(layer: String) async throws -> PublishedRun? {
        let best = layerRuns.filter { $0.key.hasPrefix(layer + "/") && $0.value.status == "published" }.max { $0.value.nominal < $1.value.nominal }
        guard let best else { return nil }
        return PublishedRun(runID: String(best.key.dropFirst(layer.count + 1)), nominal: best.value.nominal,
                            publishedAt: best.value.publishedAt ?? best.value.nominal)
    }

    public func layerPublishedSlots(layer: String, runID: String) async throws -> [SlotRef] {
        let k = key(layer, runID)
        guard layerRuns[k]?.status == "published" else { return [] }
        return (layerSlots[k] ?? [:]).values.map(\.ref).sorted { $0.slotIndex < $1.slotIndex }
    }

    public func layerFirstSlots(layer: String, since: Date, before: Date) async throws -> [SlotRef] {
        var out: [SlotRef] = []
        for (k, run) in layerRuns where k.hasPrefix(layer + "/") && run.status == "published" && run.nominal >= since && run.nominal < before {
            out += (layerSlots[k] ?? [:]).values.map(\.ref).filter { $0.slotIndex == 0 }
        }
        return out.sorted { $0.slotTime < $1.slotTime }
    }

    public func layerGetSlot(layer: String, runID: String, slotID: String) async throws -> SlotBlob? {
        let k = key(layer, runID)
        guard layerRuns[k]?.status == "published", let v = layerSlots[k]?[slotID] else { return nil }
        return SlotBlob(contentType: v.type, sha256: v.sha, data: v.data)
    }

    public func layerRetain(layer: String, keepNewest: Int, keepSince: Date, staleAfter: TimeInterval) async throws -> Int {
        let mine = layerRuns.filter { $0.key.hasPrefix(layer + "/") }
        let newest = Set(mine.filter { $0.value.status == "published" }.sorted { $0.value.nominal > $1.value.nominal }
            .prefix(max(0, keepNewest)).map(\.key))
        let cutoff = clockNow().addingTimeInterval(-staleAfter)
        let doomed = mine.filter { entry in
            if entry.value.status == "published" { return !newest.contains(entry.key) && entry.value.nominal < keepSince }
            return entry.value.lease < cutoff
        }.map(\.key)
        for k in doomed { layerRuns[k] = nil; layerSlots[k] = nil }
        return doomed.count
    }
}
