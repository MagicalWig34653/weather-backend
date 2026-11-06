import Foundation
import PNG
import Testing
@testable import RadarCore

let run0 = TimeUtil.fromID("20261030T1105Z")!
let xmlError = Array(String(repeating: "<?xml version='1.0'?><ServiceExceptionReport/>", count: 30).utf8)

struct ByteSink: PNG.BytestreamDestination {
    var bytes: [UInt8] = []
    mutating func write(_ buffer: [UInt8]) -> Void? { bytes += buffer; return () }
}

func smallConfig(_ edit: (inout Config) -> Void = { _ in }) -> Config {
    var c = Config()
    c.width = 256
    edit(&c)
    return c
}

/// Synthetic RGBA radar-like image: transparent background plus a few palette colours.
func makeImage(width: Int, height: Int, seed: Int) -> RGBAImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) { pixels[i * 4] = 255; pixels[i * 4 + 1] = 255; pixels[i * 4 + 2] = 255 }
    func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) {
        let o = (y * width + x) * 4
        pixels[o] = c.0; pixels[o + 1] = c.1; pixels[o + 2] = c.2; pixels[o + 3] = c.3
    }
    for x in 0..<40 {
        set(x, seed % height, (126, 126, 126, 77))
        set(x, (seed + 3) % height, (247, 0, 255, 223))
    }
    return RGBAImage(width: width, height: height, pixels: pixels)
}

func pngBytes(_ image: RGBAImage, padTo: Int = 1100) -> [UInt8] {
    var rgba: [PNG.RGBA<UInt8>] = []
    rgba.reserveCapacity(image.width * image.height)
    for i in 0..<(image.width * image.height) {
        rgba.append(.init(image.pixels[i * 4], image.pixels[i * 4 + 1], image.pixels[i * 4 + 2], image.pixels[i * 4 + 3]))
    }
    let layout = PNG.Layout(format: .rgba8(palette: [], fill: nil))
    let png = PNG.Image(packing: rgba, size: (image.width, image.height), layout: layout)
    var sink = ByteSink()
    try! png.compress(stream: &sink, level: 4)
    return sink.bytes + [UInt8](repeating: 0, count: max(0, padTo - sink.bytes.count))
}

/// Fake DWD: call n (1-based) answers per `failures`; otherwise a valid PNG.
final class FakeDwd: @unchecked Sendable {
    enum Failure { case xml, network }
    struct NetworkError: Error {}
    private let lock = NSLock()
    private var calls = 0
    private let config: Config
    private let failures: [Int: Failure]
    private let failAll: Bool
    // Building a PNG is slow in debug builds: one image per instance is enough for the contract tests.
    private let cachedPNG: [UInt8]
    init(_ config: Config, failures: [Int: Failure] = [:], failAll: Bool = false) {
        self.config = config; self.failures = failures; self.failAll = failAll
        cachedPNG = pngBytes(makeImage(width: config.width, height: config.height, seed: 1))
    }
    var callCount: Int { lock.withLock { calls } }
    var fetch: Fetch {
        { [self] _ in
            let n = lock.withLock { calls += 1; return calls }
            if failAll || failures[n] == .xml { return xmlError }
            if failures[n] == .network { throw NetworkError() }
            return cachedPNG
        }
    }
}

enum RepoKind: CaseIterable, CustomTestStringConvertible, Sendable {
    case memory, maria
    var testDescription: String { self == .memory ? "memory" : "mariadb" }

    static var allCases: [RepoKind] { dbEnv == nil ? [.memory] : [.memory, .maria] }

    static var dbEnv: [String: String]? {
        let env = ProcessInfo.processInfo.environment
        return env["RADAR_TEST_DB_HOST"] == nil ? nil : env
    }

    // One pool for the whole test process (a MariaRepo must live until process exit).
    nonisolated(unsafe) static let shared = Locked<MariaRepo?>(nil)

    func make() async throws -> any Repo {
        switch self {
        case .memory: return MemoryRepo()
        case .maria:
            let env = Self.dbEnv!
            var c = smallConfig()
            c.dbHost = env["RADAR_TEST_DB_HOST"]!
            c.dbPort = Int(env["RADAR_TEST_DB_PORT"] ?? "3306")!
            c.dbName = env["RADAR_TEST_DB_NAME"] ?? "radar_test"
            c.dbUser = env["RADAR_TEST_DB_USER"] ?? "root"
            c.dbPassword = env["RADAR_TEST_DB_PASSWORD"] ?? ""
            c.migrationsDirectory = "migrations"
            let repo = Self.shared.withLock { holder -> MariaRepo in
                if let existing = holder { return existing }
                let created = MariaRepo(config: c)
                holder = created
                return created
            }
            try await repo.dropAllForTests()
            try await repo.migrate()
            return repo
        }
    }
}


final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// All suites that share the one test database run inside this parent so that they never overlap.
@Suite("Database", .serialized) enum DatabaseSuites {}
