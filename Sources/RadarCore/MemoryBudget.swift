import Foundation

/// Fit of the in-process slot cache into the container memory limit (radar OOM, 18 Nov 2026).
/// The slot cache (`CACHE_MAX_MB`) lives in the same heap as the ingest: with a container limit the cache must leave room for the
/// process base and the largest ingest conversion (one at a time, `HeavyWork`). Without a limit (`RADAR_MEMORY_LIMIT=0`) nothing changes.
public enum MemoryBudget {
    /// Process base plus ingest peak that the cache must leave free (measured 18 Nov 2026 on macOS, docs/research/radar-oom.md):
    /// one gated conversion up to about 300 MB above the base (OPERA slot 190 MB, 2048 px PNG layer up to 235 MB), plus the base.
    public static let reserveBytes = 384 * 1_048_576
    /// The cache never shrinks below this (the radar still needs its current slots).
    public static let minimumCacheBytes = 16 * 1_048_576

    /// Cache bytes that fit: `configured` without a limit, otherwise at most half of what the reserve leaves (the cache counts payload
    /// bytes only; freed slots stay in the allocator for a while, so the real share is larger than the count).
    public static func cacheBytes(configured: Int, containerLimit: Int?) -> Int {
        guard let limit = containerLimit, limit > 0 else { return configured }
        let fits = max(minimumCacheBytes, (limit - reserveBytes) / 2)
        return min(configured, fits)
    }

    /// Container memory limit from the cgroup (v2 `memory.max`, v1 `memory.limit_in_bytes`); nil when there is none.
    public static func containerLimit(read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Int? {
        for path in ["/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"] {
            guard let text = read(path)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if text == "max" { return nil }
            guard let value = Int(text), value > 0 else { continue }
            return value >= 1 << 60 ? nil : value  // v1 reports "unlimited" as a huge number
        }
        return nil
    }
}
