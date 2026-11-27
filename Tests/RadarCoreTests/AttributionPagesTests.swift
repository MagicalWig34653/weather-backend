import Foundation
import Testing
@testable import RadarCore

private func text(_ r: ApiResponse) -> String { String(decoding: r.body, as: UTF8.self) }

private func api(en: Bool = false) -> Api {
    var cfg = smallConfig()
    cfg.site.englishEnabled = en
    cfg.site.operatorName = "Erika Beispiel"
    cfg.site.operatorAddress = "Musterweg 1\\n12345 Musterstadt"
    cfg.site.operatorEmail = "kontakt@example.org"
    return Api(repo: MemoryRepo(), config: cfg)
}

/// Karte 31A623B9 (Frage 9B360945): EUMETSAT-Namensnennung mit Jahr (Data Policy Art. 6.3) auf allen Seiten, OPERA und NOAA im Impressum.
@Suite("Attribution on public pages")
struct AttributionPagesTests {
    static let eumetsat = "Contains modified EUMETSAT Meteosat data 2026"

    @Test func everyPageThatNamesEumetsatCarriesTheYear() async throws {
        for path in ["/", "/en", "/impressum", "/en/imprint", "/datenschutz"] {
            let t = text(try await api(en: true).handle(path: path, ifNoneMatch: nil))
            #expect(t.contains(Self.eumetsat), "\(path) names the year")
            #expect(!t.contains("Meteosat data."), "\(path) has no attribution without the year")
        }
    }

    @Test func germanImprintNamesOperaAndNoaaAndIndependence() async throws {
        let t = text(try await api().handle(path: "/impressum", ifNoneMatch: nil))
        #expect(t.contains("Regen Europa: EUMETNET OPERA (CIRRUS), CC BY 4.0, Quelle: MeteoGate; umprojiziert, gefiltert und eingefärbt. Regen weltweit: NOAA Enterprise Rainfall Rate (RRQPE), aus Satellitendaten geschätzt, umprojiziert, gefiltert und eingefärbt."))
        #expect(t.contains("in keiner Verbindung zum DWD, zu EUMETSAT, EUMETNET oder NOAA"))
    }

    @Test func englishImprintNamesOperaAndNoaaAndIndependence() async throws {
        let t = text(try await api(en: true).handle(path: "/en/imprint", ifNoneMatch: nil))
        #expect(t.contains("Rain in Europe: EUMETNET OPERA (CIRRUS), CC BY 4.0, source: MeteoGate; reprojected, filtered and colored. Rain worldwide: NOAA Enterprise Rainfall Rate (RRQPE), estimated from satellite data, reprojected, filtered and colored."))
        #expect(t.contains("is not affiliated with the DWD, EUMETSAT, EUMETNET or NOAA"))
    }
}
