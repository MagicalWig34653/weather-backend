import Foundation
import Testing
@testable import RadarCore

@Suite("bz2 decompression (libbz2)")
struct Bzip2Tests {
    /// Fixture made with the system tool: `printf 'ICON-D2 ...' | bzip2 -9 | xxd -i`; bytes below decode to `text`.
    private let text = Array("ICON-D2 bz2 fixture, repeated. ".utf8)

    @Test func decompressesWhatItCompresses() throws {
        let raw = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 7)) }
        let packed = try Bzip2.compress(raw)
        #expect(packed.count < raw.count)
        #expect(try Bzip2.decompress(packed, maxOutput: 1 << 20) == raw)
    }

    @Test func decompressesStreamsMadeByTheBzip2Tool() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bz2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("a.txt")
        try Data(text).write(to: plain)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/bzip2")
        task.arguments = ["-k", plain.path]
        try task.run(); task.waitUntilExit()
        let packed = try [UInt8](Data(contentsOf: dir.appendingPathComponent("a.txt.bz2")))
        #expect(try Bzip2.decompress(packed, maxOutput: 1024) == text)
    }

    @Test func limitProtectsAgainstBombs() throws {
        let bomb = try Bzip2.compress([UInt8](repeating: 0, count: 5_000_000))
        #expect(bomb.count < 2000)
        #expect(throws: Bzip2Error.self) { try Bzip2.decompress(bomb, maxOutput: 1_000_000) }
        #expect(try Bzip2.decompress(bomb, maxOutput: 5_000_000).count == 5_000_000)
    }

    @Test func corruptAndTruncatedDataThrow() throws {
        let packed = try Bzip2.compress((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        #expect(throws: Bzip2Error.self) { try Bzip2.decompress(Array(packed.dropLast(10)), maxOutput: 1 << 20) }
        var bad = packed; bad[bad.count / 2] ^= 0xFF
        #expect(throws: Bzip2Error.self) { try Bzip2.decompress(bad, maxOutput: 1 << 20) }
        #expect(throws: Bzip2Error.self) { try Bzip2.decompress(Array("<html>404</html>".utf8), maxOutput: 1 << 20) }
        #expect(throws: Bzip2Error.self) { try Bzip2.decompress([], maxOutput: 1 << 20) }
    }
}
