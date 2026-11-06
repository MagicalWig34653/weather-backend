import Foundation

struct MemoryCacheAdminStore {
    var jobs: [RefreshJob] = []
    var fills: [String: (fill: ReplicaCacheFill, at: Date)] = [:]
}

extension MemoryRepo {
    /// Runs and slots of a layer id as one list of (run id, run, slots).
    private func layerData(_ layer: String) -> [(runID: String, run: Run, slots: [(ref: SlotRef, type: String, sha: String, data: [UInt8])])] {
        if layer == "radar" { return runs.map { ($0.key, $0.value, Array((slots[$0.key] ?? [:]).values)) } }
        let prefix = layer + "/"
        return layerRuns.filter { $0.key.hasPrefix(prefix) }.map { ($0.key, $0.value, Array((layerSlots[$0.key] ?? [:]).values)) }
    }

    public func cacheInventory(layers: [String], now: Date) async throws -> [CacheLayerInventory] {
        layers.map { layer in
            let all = layerData(layer)
            let published = all.filter { $0.run.status == "published" }
            // The fake has no creation time: the newest nominal run stands in for "last attempt".
            let last = all.max { $0.run.nominal < $1.run.nominal }
            var attempt: String?
            if let last { attempt = last.run.status == "claimed" && last.run.lease < now ? "claimed_expired" : last.run.status }
            return CacheLayerInventory(
                layer: layer, runs: published.count, slots: published.reduce(0) { $0 + $1.slots.count },
                bytes: published.reduce(0) { $0 + $1.slots.reduce(0) { $0 + $1.data.count } },
                oldestNominal: published.map(\.run.nominal).min(), newestNominal: published.map(\.run.nominal).max(),
                latestPublishedAt: published.compactMap(\.run.publishedAt).max(), lastAttemptAt: last?.run.nominal, lastAttemptStatus: attempt)
        }
    }

    public func cacheSlotRows(layer: String, olderThan: Date?, at: Date?, limit: Int) async throws -> [CacheSlotRow] {
        var rows: [CacheSlotRow] = []
        for entry in layerData(layer) {
            for slot in entry.slots {
                if let at, slot.ref.slotTime != at { continue }
                if let olderThan, slot.ref.slotTime >= olderThan { continue }
                rows.append(CacheSlotRow(slot: slot.ref.slotTime, run: entry.run.nominal, index: slot.ref.slotIndex, bytes: slot.data.count,
                                         contentType: slot.type, published: entry.run.status == "published", publishedAt: entry.run.publishedAt))
            }
        }
        rows.sort { ($0.slot, $0.run) > ($1.slot, $1.run) }
        return Array(rows.prefix(max(0, limit)))
    }

    public func cacheSlotBlob(layer: String, slot: Date, run: Date?) async throws -> SlotBlob? {
        let candidates = layerData(layer).filter { $0.run.status == "published" && (run == nil || $0.run.nominal == run) }
            .sorted { $0.run.nominal > $1.run.nominal }
        for entry in candidates {
            if let hit = entry.slots.first(where: { $0.ref.slotTime == slot }) { return SlotBlob(contentType: hit.type, sha256: hit.sha, data: hit.data) }
        }
        return nil
    }

    private func settleJobs(now: Date) {
        for i in cacheAdmin.jobs.indices {
            let job = cacheAdmin.jobs[i]
            if job.status == .queued, job.createdAt < now.addingTimeInterval(-RefreshRetention.queuedExpirySeconds) {
                cacheAdmin.jobs[i].status = .expired; cacheAdmin.jobs[i].finishedAt = now; cacheAdmin.jobs[i].error = "no_ingest_replica"
            } else if job.status == .running, let started = job.startedAt, started < now.addingTimeInterval(-RefreshRetention.runningTimeoutSeconds) {
                cacheAdmin.jobs[i].status = .failed; cacheAdmin.jobs[i].finishedAt = now; cacheAdmin.jobs[i].error = "timeout"
            }
        }
    }

    public func createRefreshJobs(layers: [String], now: Date) async throws -> (created: [RefreshJob], pending: [String]) {
        settleJobs(now: now)
        cacheAdmin.jobs.removeAll { $0.createdAt < now.addingTimeInterval(-Double(RefreshRetention.keepHours) * 3600) }
        var created: [RefreshJob] = [], pending: [String] = []
        for layer in layers {
            if cacheAdmin.jobs.contains(where: { $0.layer == layer && ($0.status == .queued || $0.status == .running) }) { pending.append(layer); continue }
            let job = RefreshJob(id: UUID().uuidString.lowercased(), layer: layer, status: .queued, createdAt: now)
            cacheAdmin.jobs.append(job); created.append(job)
        }
        if cacheAdmin.jobs.count > RefreshRetention.keepJobs { cacheAdmin.jobs.removeFirst(cacheAdmin.jobs.count - RefreshRetention.keepJobs) }
        return (created, pending)
    }

    public func refreshJob(id: String) async throws -> RefreshJob? { cacheAdmin.jobs.first { $0.id == id } }

    public func refreshJobs(limit: Int) async throws -> [RefreshJob] {
        Array(cacheAdmin.jobs.reversed().prefix(max(0, limit)))
    }

    public func queuedRefreshLayers(now: Date) async throws -> [String] {
        settleJobs(now: now)
        var seen: [String] = []
        for job in cacheAdmin.jobs where job.status == .queued && !seen.contains(job.layer) { seen.append(job.layer) }
        return seen
    }

    public func claimRefreshJob(layer: String, now: Date) async throws -> RefreshJob? {
        guard let i = cacheAdmin.jobs.firstIndex(where: { $0.layer == layer && $0.status == .queued }) else { return nil }
        cacheAdmin.jobs[i].status = .running; cacheAdmin.jobs[i].startedAt = now
        return cacheAdmin.jobs[i]
    }

    public func finishRefreshJob(id: String, status: RefreshStatus, result: String?, error: String?, now: Date) async throws {
        guard let i = cacheAdmin.jobs.firstIndex(where: { $0.id == id && $0.status == .running }) else { return }
        cacheAdmin.jobs[i].status = status; cacheAdmin.jobs[i].finishedAt = now
        cacheAdmin.jobs[i].result = result; cacheAdmin.jobs[i].error = error
    }

    public func reportCacheFill(replicaID: String, fill: ReplicaCacheFill, now: Date) async throws {
        cacheAdmin.fills[replicaID] = (fill, now)
    }

    public func replicaCacheFills(now: Date) async throws -> [String: ReplicaCacheFill] {
        let cutoff = now.addingTimeInterval(-DashboardRetention.replicaStale)
        return cacheAdmin.fills.filter { $0.value.at > cutoff }.mapValues(\.fill)
    }
}
