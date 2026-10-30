import CWebP
import Foundation
import Testing
@testable import RadarCore

@Suite struct UnitTests {
    @Test func lruEvictsByBytes() async {
        let cache = SlotCache(maxBytes: 10)
        @Sendable func blob(_ n: Int) -> SlotBlob { SlotBlob(contentType: "t", sha256: "s", data: [UInt8](repeating: 1, count: n)) }
        _ = try? await cache.load("a") { blob(6) }
        _ = try? await cache.load("b") { blob(6) }
        #expect(await !cache.contains("a"))
        #expect(await cache.contains("b"))
    }

    @Test func dwdURLHasNoLocationAndUsesMillisecondTimes() {
        let url = DWD.buildURL(config: smallConfig(), run: run0, slot: run0)
        #expect(url.contains("TIME=2026-10-30T11%3A05%3A00.000Z"))
        #expect(url.contains("DIM_REFERENCE_TIME=2026-10-30T11%3A05%3A00.000Z"))
        #expect(url.contains("LAYERS=dwd%3ANiederschlagsradar"))
        #expect(url.contains("WIDTH=256"))
        #expect(url.contains("BBOX=612257%2C5942074%2C1736584%2C7381298"))
    }

    @Test func configRejectsUnsafeValuesAndReadsSecretFile() throws {
        #expect(throws: ConfigError.self) { _ = try Config.fromEnvironment(["RETENTION_RUNS": "14"]) }
        #expect(try Config.fromEnvironment(["DB_POOL_SIZE": "3"]).dbPoolSize == 3)
        #expect(try Config.fromEnvironment([:]).retentionRuns == 16)
        let path = NSTemporaryDirectory() + "radar-secret-\(UUID().uuidString)"
        try "s3cret\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try Config.fromEnvironment(["DB_PASSWORD_FILE": path]).dbPassword == "s3cret")
    }

    @Test func imageHeightAndIds() {
        #expect(Config().height == 1311)
        #expect(TimeUtil.toID(run0) == "20261030T1105Z")
        #expect(TimeUtil.fromID("20261030T1105Z") == run0)
        #expect(TimeUtil.fromID("nope") == nil)
        #expect(TimeUtil.toISO(run0) == "2026-10-30T11:05:00Z")
        let wake = TimeUtil.nextWakeup(now: run0.addingTimeInterval(210), availabilityDelay: 200)
        #expect(wake == run0.addingTimeInterval(500))
    }

    @Test func rejectsXmlTruncatedAndWrongSizedImages() throws {
        #expect(throws: ImageError.self) { _ = try ImagePipeline.validatePNG(xmlError, width: 256, height: 329) }
        #expect(throws: ImageError.self) { _ = try ImagePipeline.validatePNG(Array("hello".utf8), width: 256, height: 329) }
        let good = pngBytes(makeImage(width: 256, height: 329, seed: 1))
        #expect(throws: ImageError.self) { _ = try ImagePipeline.validatePNG(Array(good.prefix(200)) + [UInt8](repeating: 0, count: 1000), width: 256, height: 329) }
        #expect(throws: ImageError.self) { _ = try ImagePipeline.validatePNG(good, width: 128, height: 329) }
        #expect(throws: ImageError.self) { _ = try ImagePipeline.validatePNG(Array(good.prefix(500)), width: 256, height: 329) }
        _ = try ImagePipeline.validatePNG(good, width: 256, height: 329)
    }

    @Test func webpIsLosslessAndPixelExact() throws {
        let original = makeImage(width: 256, height: 329, seed: 7)
        let decodedPNG = try ImagePipeline.validatePNG(pngBytes(original), width: 256, height: 329)
        #expect(decodedPNG == original)
        let webp = try ImagePipeline.toWebP(decodedPNG)
        #expect(Array(webp.prefix(4)) == Array("RIFF".utf8) && Array(webp[8..<12]) == Array("WEBP".utf8))
        var w: Int32 = 0, h: Int32 = 0
        let ok = webp.withUnsafeBufferPointer { WebPGetInfo($0.baseAddress, $0.count, &w, &h) }
        #expect(ok != 0 && w == 256 && h == 329)
        let out = webp.withUnsafeBufferPointer { WebPDecodeRGBA($0.baseAddress, $0.count, &w, &h) }
        defer { WebPFree(out) }
        let pixels = Array(UnsafeBufferPointer(start: out, count: 256 * 329 * 4))
        #expect(pixels == original.pixels)
    }

    /// Parity helper: RADAR_COMPARE_PNG=<in.png> RADAR_COMPARE_OUT=<out.webp> swift test --filter parity
    @Test func parityDump() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["RADAR_COMPARE_PNG"], let output = env["RADAR_COMPARE_OUT"] else { return }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: input)))
        let image = try ImagePipeline.validatePNG(bytes, width: 1024, height: 1311)
        try Data(try ImagePipeline.toWebP(image)).write(to: URL(fileURLWithPath: output))
    }
}
