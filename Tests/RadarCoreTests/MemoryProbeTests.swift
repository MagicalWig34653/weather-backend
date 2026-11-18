import Foundation
import Testing
@testable import RadarCore
#if canImport(Darwin)
import Darwin
#endif

/// Memory probe of the heavy ingest paths (radar OOM, Nov 2026). Runs only with `MEMORY_PROBE=<scenario>`; prints peak and current
/// footprint in MB (macOS: phys_footprint and its ledger peak; Linux: VmRSS/VmHWM). One scenario per process: the peak is not reset.
/// Scenarios: `opera` (OPERA_SAMPLE_H5, one slot), `opera_seq` (OPERA_SAMPLE_DIR, all .h5 files 3 times), `png2048` (one 2048 px
/// WMS layer), `concurrent` (radar_eu + two 2048 px layers at the same time), `concurrent_gated` (the same through `HeavyWork`).
@Suite("Memory probe (manual)")
struct MemoryProbeTests {
    static func footprintMB() -> (now: Double, peak: Double) {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
        #else
        let text = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        func kb(_ key: String) -> Double {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(key) }) else { return 0 }
            return Double(line.split(separator: " ").dropFirst().first ?? "0").map { $0 / 1024 } ?? 0
        }
        return (kb("VmRSS:"), kb("VmHWM:"))
        #endif
    }

    static func report(_ label: String, base: Double) {
        let f = footprintMB()
        print(String(format: "MEMPROBE %@ now=%.1f peak=%.1f peakAboveBase=%.1f", label, f.now, f.peak, f.peak - base))
    }

    static var scenario: String? { ProcessInfo.processInfo.environment["MEMORY_PROBE"] }

    static func operaSlot(_ file: [UInt8]) throws -> Int {
        let image = try OperaRender.image(file: file, bbox: RadarConstants.europeBBox, width: 2048, noiseDBZ: Opera.defaultNoiseDBZ)
        return try ImagePipeline.toWebP(image, lossless: true, quality: 100, method: Opera.webpMethod).count
    }

    /// Satellite-like 2048 px layer (grey noise blocks, lossless, as cloudmask_vis_eu).
    static func layerPNG() -> [UInt8] {
        let w = 2048, h = RadarConstants.imageHeight(width: w, bbox: RadarConstants.europeBBox)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 1
        for i in 0..<(w * h) where i % 7 != 0 {
            seed = seed &* 1_103_515_245 &+ 12345
            let g = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[i * 4] = g; pixels[i * 4 + 1] = g; pixels[i * 4 + 2] = g
        }
        return pngBytes(RGBAImage(width: w, height: h, pixels: pixels))
    }

    static func layerSlot(_ png: [UInt8]) throws -> Int {
        let w = 2048, h = RadarConstants.imageHeight(width: w, bbox: RadarConstants.europeBBox)
        let image = try ImagePipeline.validatePNG(png, width: w, height: h, sizeRange: 200...20_000_000)
        return try ImagePipeline.toWebP(image, lossless: true, quality: 100).count
    }

    @Test func probe() async throws {
        guard let scenario = Self.scenario else { return }
        let env = ProcessInfo.processInfo.environment
        switch scenario {
        case "opera":
            let file = [UInt8](FileManager.default.contents(atPath: env["OPERA_SAMPLE_H5"] ?? "") ?? Data())
            let base = Self.footprintMB().now
            Self.report("opera:base", base: base)
            let composite = try OdimHDF5.read(file)
            Self.report("opera:afterRead(\(composite.width)x\(composite.height))", base: base)
            _ = composite.values.count
            let bytes = try Self.operaSlot(file)
            Self.report("opera:afterSlot(webp=\(bytes))", base: base)
        case "opera_seq":
            let dir = env["OPERA_SAMPLE_DIR"] ?? ""
            let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".h5") }.sorted()
            let base = Self.footprintMB().now
            for round in 0..<3 {
                for name in files {
                    let file = [UInt8](FileManager.default.contents(atPath: dir + "/" + name) ?? Data())
                    _ = try Self.operaSlot(file)
                    Self.report("opera_seq:r\(round):\(name)", base: base)
                }
            }
        case "png2048":
            let png = Self.layerPNG()
            let base = Self.footprintMB().now
            Self.report("png2048:base(png=\(png.count))", base: base)
            let bytes = try Self.layerSlot(png)
            Self.report("png2048:afterSlot(webp=\(bytes))", base: base)
        case "concurrent", "concurrent_gated":
            let file = [UInt8](FileManager.default.contents(atPath: env["OPERA_SAMPLE_H5"] ?? "") ?? Data())
            let png = Self.layerPNG()
            let gated = scenario == "concurrent_gated"
            let base = Self.footprintMB().now
            Self.report("\(scenario):base", base: base)
            try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask { gated ? try await HeavyWork.shared.run { try Self.operaSlot(file) } : try Self.operaSlot(file) }
                for _ in 0..<2 {
                    group.addTask { gated ? try await HeavyWork.shared.run { try Self.layerSlot(png) } : try Self.layerSlot(png) }
                }
                for try await _ in group {}
            }
            Self.report("\(scenario):after", base: base)
        case "cache":
            // slot cache at its limit: counted bytes vs. real footprint (blobs of 300 kB as radar/layer WebP slots)
            let mb = Int(env["CACHE_PROBE_MB"] ?? "64") ?? 64
            let cache = SlotCache(maxBytes: mb * 1_048_576)
            let base = Self.footprintMB().now
            for i in 0..<(mb * 1_048_576 / 300_000 + 50) {
                let blob = SlotBlob(contentType: "image/webp", sha256: String(repeating: "a", count: 64), data: [UInt8](repeating: UInt8(i & 255), count: 300_000))
                _ = try await cache.load("layer:radar_eu/\(i)") { blob }
            }
            let snap = await cache.snapshot()
            Self.report(String(format: "cache:counted=%.1fMB entries=%d", Double(snap.bytes) / 1_048_576, snap.entries), base: base)
            print(String(format: "MEMPROBE cache:nowAboveBase=%.1f", Self.footprintMB().now - base))
        default:
            Issue.record("unknown MEMORY_PROBE \(scenario)")
        }
    }
}
