import Foundation
import Testing
@testable import RadarCore

/// Keeps `deploy/swarm/config-registry.tsv` (read by `deploy/swarm/settings.sh`, which lands in the deploy branch) in sync with
/// `ConfigRegistry.settings`. Regenerate with: UPDATE_CONFIG_TSV=1 swift test --filter ConfigRegistryTSVTests
@Suite struct ConfigRegistryTSVTests {
    static let columns = ["key", "group", "type", "default", "unit", "min", "max", "choices", "apply", "secret", "summary"]

    static func swarmDirectory() -> URL {
        // .../Tests/RadarCoreTests/ConfigRegistryTSVTests.swift -> repository root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("deploy/swarm")
    }

    static func number(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func row(_ s: ConfigSetting) -> String {
        var type = s.kind.name
        var lo = "", hi = "", choices = ""
        switch s.kind {
        case .int(let a, let b): lo = String(a); hi = String(b)
        case .number(let a, let b): lo = number(a); hi = number(b)
        case .text(let n, let rule): type = "text:\(rule.rawValue)"; hi = String(n)
        case .url(let host, let n): type = host.map { "url:\($0)" } ?? "url"; hi = String(n)
        case .choice(let options): choices = options.joined(separator: "|")
        case .layers: choices = LayerCatalog.order.joined(separator: "|")
        case .bool, .secret: break
        }
        let cells = [s.key, s.group, type, s.secret ? "" : s.defaultValue, s.unit ?? "", lo, hi, choices,
                     s.apply.rawValue, s.secret ? "1" : "0", s.summary]
        return cells.map(field).joined(separator: "\t")
    }

    static func generate() -> String {
        var lines = ["#" + columns.joined(separator: "\t")]
        lines.append(contentsOf: ConfigRegistry.settings.map(row))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Register keys whose rows may be missing from the table (tables under deploy/ belong to another owner; rows follow with the next deploy update).
    /// Pairing window (6.11.2026): DEVICE_LINK_*; proxy auth (6.11.2026): DASH_PROXY_TOKEN*.
    static let pendingKeys: Set<String> = ["DEVICE_LINK_REQUIRE_TESTFLIGHT", "DEVICE_LINK_WINDOW_MINUTES",
                                           "DASH_PROXY_TOKEN", "DASH_PROXY_TOKEN_PREVIOUS", "DASH_PROXY_TOKEN_REQUIRED"]

    private static func lines(_ text: String, dropping pending: Bool) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            !pending || !pendingKeys.contains(String(line.split(separator: "\t", omittingEmptySubsequences: false).first ?? ""))
        }
    }

    @Test func tableMatchesRegistry() throws {
        let file = Self.swarmDirectory().appendingPathComponent("config-registry.tsv")
        let expected = Self.generate()
        if ProcessInfo.processInfo.environment["UPDATE_CONFIG_TSV"] == "1" {
            try expected.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let actual = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(Self.lines(actual, dropping: true) == Self.lines(expected, dropping: true), """
            deploy/swarm/config-registry.tsv ist nicht aktuell (ConfigRegistry.settings wurde geaendert).
            Neu erzeugen mit: UPDATE_CONFIG_TSV=1 swift test --filter ConfigRegistryTSVTests
            und die Datei mit dem Code committen.
            """)
        // Pending keys that already are in the table must be identical to the register.
        let present = Self.lines(actual, dropping: false).filter { line in
            Self.pendingKeys.contains(String(line.split(separator: "\t", omittingEmptySubsequences: false).first ?? ""))
        }
        let all = Set(Self.lines(expected, dropping: false))
        for line in present { #expect(all.contains(line), "pending row differs from the register: \(line.prefix(40))") }
        #expect(ConfigRegistry.settings.map(\.key).filter { Self.pendingKeys.contains($0) }.count == Self.pendingKeys.count, "pendingKeys lists unknown keys")
    }

    @Test func extraTableIsWellFormedAndDisjoint() throws {
        let file = Self.swarmDirectory().appendingPathComponent("config-extra.tsv")
        let text = try String(contentsOf: file, encoding: .utf8)
        let registry = Set(ConfigRegistry.settings.map(\.key))
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            #expect(cells.count == Self.columns.count, "config-extra.tsv: \(cells.first ?? "?") hat \(cells.count) Spalten")
            guard cells.count == Self.columns.count else { continue }
            #expect(!registry.contains(cells[0]), "\(cells[0]) steht schon im Register, nicht in config-extra.tsv")
            #expect(seen.insert(cells[0]).inserted, "\(cells[0]) doppelt in config-extra.tsv")
            #expect(["live", "restart", "envOnly"].contains(cells[8]), "\(cells[0]): apply \(cells[8])")
            #expect(["0", "1"].contains(cells[9]), "\(cells[0]): secret \(cells[9])")
        }
        #expect(!seen.isEmpty)
    }
}
