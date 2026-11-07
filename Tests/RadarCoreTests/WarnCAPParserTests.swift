import Foundation
import Testing
import ZIPFoundation
@testable import RadarCore

@Suite("Warn CAP parser")
struct WarnCAPParserTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func parsesRealFrostAlert() throws {
        let r = WarnCAPParser.parse(xml: try fixture("warn-cap-frost.xml"))
        #expect(r.alerts.count == 1)
        let a = try #require(r.alerts.first)
        #expect(a.identifier == "2.49.0.0.276.0.DWD.PVW.1794051060000.2509064c-9ae8-40a2-8059-834d43d182b6.DEU")
        #expect(a.kind == .frost); #expect(a.severity == 1); #expect(a.msgType == .alert)
        #expect(a.lang == "de")
        #expect(a.warncellIDs == ["814522510", "814522500"])
        #expect(a.sent == iso("2026-11-07T11:31:00Z"))
        #expect(a.expires == iso("2026-11-08T08:00:00Z"))
        #expect(a.headline == "Amtliche WARNUNG vor FROST")
        #expect(a.instruction.hasPrefix("Hinweis auf: mögliche Frostschäden."))
    }

    @Test func unknownEventIsCountedNotStored() {
        let r = WarnCAPParser.parse(xml: Data(Self.minimal(event: "HITZE", ii: 247, severity: "Minor").utf8))
        #expect(r.alerts.isEmpty); #expect(r.ignoredEvents["HITZE"] == 1); #expect(r.rejected == 0)
    }

    @Test func severityMapping() {
        for (s, n) in [("Minor", 1), ("Moderate", 2), ("Severe", 3), ("Extreme", 4)] {
            let r = WarnCAPParser.parse(xml: Data(Self.minimal(event: "FROST", ii: 22, severity: s).utf8))
            #expect(r.alerts.first?.severity == n)
        }
        let bad = WarnCAPParser.parse(xml: Data(Self.minimal(event: "FROST", ii: 22, severity: "Unknown").utf8))
        #expect(bad.alerts.isEmpty); #expect(bad.rejected == 1)
    }

    @Test func cancelAndReferences() {
        let xml = Self.minimal(event: "FROST", ii: 22, severity: "Minor", msgType: "Cancel",
                               references: "opendata@dwd.de,OLD.ID.1,2026-11-07T12:31:00+01:00 opendata@dwd.de,OLD.ID.2,2026-11-07T12:40:00+01:00")
        let a = WarnCAPParser.parse(xml: Data(xml.utf8)).alerts.first
        #expect(a?.msgType == .cancel); #expect(a?.references == ["OLD.ID.1", "OLD.ID.2"])
    }

    @Test func brokenXmlIsRejectedWithoutCrash() {
        for broken in ["<alert><nope", "", "not xml at all", "<alert xmlns=\"urn:oasis:names:tc:emergency:cap:1.2\"></alert>"] {
            let r = WarnCAPParser.parse(xml: Data(broken.utf8))
            #expect(r.alerts.isEmpty); #expect(r.rejected == 1, "\(broken)")
        }
    }

    @Test func testStatusAndDuplicateCellsAndBadCells() {
        var xml = Self.minimal(event: "FROST", ii: 22, severity: "Minor")
        let r1 = WarnCAPParser.parse(xml: Data(xml.replacingOccurrences(of: "<status>Actual", with: "<status>Test").utf8))
        #expect(r1.alerts.isEmpty); #expect(r1.rejected == 1)
        xml = xml.replacingOccurrences(of: "</info>", with: "<area><geocode><valueName>WARNCELLID</valueName><value>814522510</value></geocode></area>"
            + "<area><geocode><valueName>WARNCELLID</valueName><value>12345</value></geocode></area></info>")
        #expect(WarnCAPParser.parse(xml: Data(xml.utf8)).alerts.first?.warncellIDs == ["814522510"])
    }

    @Test func englishAdvanceInformationAndAmbiguousCodes() {
        let en = Self.minimal(event: "frost", ii: 22, severity: "Minor", lang: "en")
        #expect(WarnCAPParser.parse(xml: Data(en.utf8)).alerts.first?.lang == "en")
        let vor = Self.minimal(event: "VORABINFORMATION GLATTEIS", ii: 85, severity: "Severe")
        let r = WarnCAPParser.parse(xml: Data(vor.utf8))
        #expect(r.alerts.isEmpty); #expect(r.ignoredEvents.count == 1)
    }

    @Test func storesNoCoordinatesOrNames() throws {
        let a = try #require(WarnCAPParser.parse(xml: try fixture("warn-cap-frost.xml")).alerts.first)
        let dump = String(describing: a)
        #expect(!dump.contains("Roßwein")); #expect(!dump.contains("54.364817"))
    }

    static func minimal(event: String, ii: Int, severity: String, msgType: String = "Alert", references: String? = nil, lang: String = "de-DE") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
        <identifier>T.\(event).1</identifier><sent>2026-11-07T12:31:00+01:00</sent><status>Actual</status><msgType>\(msgType)</msgType>\(references.map { "<references>\($0)</references>" } ?? "")
        <info><language>\(lang)</language><event>\(event)</event><severity>\(severity)</severity>
        <eventCode><valueName>II</valueName><value>\(ii)</value></eventCode>
        <onset>2026-11-07T22:00:00+01:00</onset><expires>2026-11-08T09:00:00+01:00</expires>
        <headline>H</headline><description>D</description>
        <area><areaDesc>Stadt X</areaDesc><geocode><valueName>WARNCELLID</valueName><value>814522510</value></geocode></area>
        </info></alert>
        """
    }
}

@Suite("Warn feed source")
struct WarnFeedSourceTests {
    static func zip(_ files: [(String, Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        return try #require(archive.data)
    }

    @Test func urlsAreFixedAndOnlyDeEn() throws {
        #expect(try DWDWarnFeedSource.url(feed: .diff, lang: "de")
                == "https://opendata.dwd.de/weather/alerts/cap/COMMUNEUNION_DWD_DIFF/Z_CAP_C_EDZW_LATEST_PVW_DIFFERENCE_PREMIUMDWD_COMMUNEUNION_DE.zip")
        #expect(try DWDWarnFeedSource.url(feed: .stat, lang: "en").hasSuffix("STATUS_PREMIUMDWD_COMMUNEUNION_EN.zip"))
        #expect(throws: WarnFeedError.self) { try DWDWarnFeedSource.url(feed: .stat, lang: "fr") }
    }

    @Test func readsXmlOnlyAndPassesEtag() async throws {
        let z = try Self.zip([("a.xml", Data("<a/>".utf8)), ("readme.txt", Data("x".utf8)), ("b.XML", Data("<b/>".utf8))])
        let seen = Locked<[String?]>([])
        let source = DWDWarnFeedSource { url, inm, max in
            seen.withLock { $0.append(inm) }
            #expect(max == DWDWarnFeedSource.maxZipBytes)
            return WarnHTTPResponse(status: 200, etag: "\"v1\"", body: z)
        }
        let r = try await source.fetch(feed: .stat, lang: "de", ifNoneMatch: "\"v0\"")
        #expect(r == .xmlFiles([Data("<a/>".utf8), Data("<b/>".utf8)], etag: "\"v1\""))
        #expect(seen.withLock { $0 } == ["\"v0\""])
    }

    @Test func notModifiedEmptyZipAndErrors() async throws {
        func source(_ status: Int, _ body: Data = Data()) -> DWDWarnFeedSource { DWDWarnFeedSource { _, _, _ in WarnHTTPResponse(status: status, etag: nil, body: body) } }
        #expect(try await source(304).fetch(feed: .diff, lang: "de", ifNoneMatch: "x") == .notModified)
        #expect(try await source(200, Data([0x50, 0x4b, 5, 6] + [UInt8](repeating: 0, count: 18))).fetch(feed: .diff, lang: "de", ifNoneMatch: nil) == .xmlFiles([], etag: nil))
        await #expect(throws: WarnFeedError.self) { try await source(500).fetch(feed: .diff, lang: "de", ifNoneMatch: nil) }
        await #expect(throws: WarnFeedError.self) { try await source(200, Data("not a zip, long enough to try parsing it".utf8)).fetch(feed: .diff, lang: "de", ifNoneMatch: nil) }
    }

    @Test func limits() throws {
        #expect(throws: WarnFeedError.self) { try DWDWarnFeedSource.xmlFiles(inZip: Data(count: DWDWarnFeedSource.maxZipBytes + 1)) }
        let big = Data(repeating: 0x20, count: DWDWarnFeedSource.maxFileBytes + 1)   // compresses well: small zip, big content
        let z = try Self.zip([("big.xml", big)])
        #expect(z.count < DWDWarnFeedSource.maxZipBytes)
        #expect(throws: WarnFeedError.self) { try DWDWarnFeedSource.xmlFiles(inZip: z) }
    }
}
