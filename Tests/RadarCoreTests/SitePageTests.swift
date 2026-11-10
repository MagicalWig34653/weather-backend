import Foundation
import Testing
@testable import RadarCore

private func hdr(_ r: ApiResponse, _ n: String) -> String? { r.headers.first { $0.0 == n }?.1 }
private func text(_ r: ApiResponse) -> String { String(decoding: r.body, as: UTF8.self) }

private func api(_ edit: (inout SiteInfo) -> Void = { _ in }) -> Api {
    var cfg = smallConfig()
    edit(&cfg.site)
    return Api(repo: MemoryRepo(), config: cfg)
}

private func fullInfo(_ s: inout SiteInfo) {
    s.operatorName = "Erika Beispiel"
    s.operatorAddress = "Musterweg 1\\n12345 Musterstadt"
    s.operatorEmail = "kontakt@example.org"
    s.proxyLogNote = "Der Proxy speichert Zugriffe 7 Tage."
}

@Suite("Public site pages")
struct SitePageTests {
    @Test func pagesServeWithHeadings() async throws {
        let a = api(fullInfo)
        for (path, heading) in [("/datenschutz", "<h1>Datenschutzerklärung</h1>"), ("/marketing", "<h1>Showers</h1>"), ("/support", "<h1>Support</h1>"), ("/impressum", "<h1>Impressum</h1>")] {
            let r = try await a.handle(path: path, ifNoneMatch: nil)
            #expect(r.status == 200, "\(path)")
            #expect(text(r).contains(heading), "\(path)")
            #expect(hdr(r, "Content-Type") == "text/html; charset=utf-8")
            #expect(hdr(r, "Cache-Control") == "public, max-age=3600")
            #expect(hdr(r, "X-Content-Type-Options") == "nosniff")
            #expect(hdr(r, "Referrer-Policy") == "no-referrer")
            #expect(hdr(r, "Content-Security-Policy") == "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
            #expect(hdr(r, "Set-Cookie") == nil)
            #expect(!text(r).contains("<script") && !text(r).contains("src=\"http"))
        }
        let q = try await a.handle(path: "/marketing?x=1", ifNoneMatch: nil)
        #expect(q.status == 200)
    }

    @Test func privacyMentionsAppleMapsAndSearch() async throws {
        let t = text(try await api(fullInfo).handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(t.contains("<h2>4. Orte, Standort, Prognose und Karten</h2>"))
        #expect(t.contains("Apple MapKit") && t.contains("Suchtext") && t.contains("Datenschutzbestimmungen von Apple"))
        #expect(t.contains("<h2>9. Quellen</h2>"))
        #expect(!t.contains("href=\"http"))
    }

    @Test func privacyDescribesOperatorDiagnosticsAndStatistics() async throws {
        let t = text(try await api(fullInfo).handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(t.contains("aggregierte, personenlose Werte") && t.contains("72 Stunden"))
        #expect(t.contains("<h2>6. Betreiber-Diagnose (freiwillig)</h2>"))
        #expect(t.contains("Koppelcode") && t.contains("48 Stunden") && t.contains("bis zum Widerruf") && t.contains("Kopplungsfenster") && t.contains("1 km") && t.contains("Passkey") && !t.contains("App-Transaktion") && !t.contains("nur Testversionen"))
    }

    private static let requiredPrivacyHeadings = [
        "1. Verantwortlicher", "2. Überblick", "3. Radar-Abruf und Server-Protokolle", "4. Orte, Standort, Prognose und Karten",
        "5. Regenhinweise und Live Activities (optional)", "6. Betreiber-Diagnose (freiwillig)", "7. Empfänger, Hosting und Drittländer",
        "8. Deine Rechte", "9. Quellen"]

    @Test func privacyHasRequiredSectionsAndStand() async throws {
        let t = text(try await api(fullInfo).handle(path: "/datenschutz", ifNoneMatch: nil))
        for h in Self.requiredPrivacyHeadings { #expect(t.contains("<h2>\(h)</h2>"), "\(h)") }
        #expect(t.contains("Stand: 10. November 2026."))
        #expect(t.contains("Art. 6 Abs. 1 lit. f DSGVO") && t.contains("Art. 6 Abs. 1 lit. a DSGVO") && t.contains("widersprechen") && t.contains("Datenschutz-Aufsichtsbehörde"))
        #expect(t.contains("60 Tage") && t.contains("6 Stunden") && t.contains("Hetzner Online GmbH") && t.contains("Apple Push Notification Service") && t.contains("USA") && t.contains("Art. 22 DSGVO") && t.contains("keine Analyse-Dienste") && t.contains("widerrufen"))
        #expect(t.contains("Technisch bedingt sieht er die IP-Adresse jedes Abrufs und protokolliert sie befristet."))
        #expect(t.contains("Erika Beispiel") && t.contains("mailto:kontakt@example.org"))
    }

    @Test func publicPagesHaveNoDraftOrInternalStrings() async throws {
        let a = api(fullInfo)
        let banned = ["[", "]", "Entwurf", "Entwurfs", "Platzhalter", "Rechtsprüfung", "Rechtliche Prüfung", "nach Build", "Teil G", "Teil D", "Teil C",
                      "Nutzerentscheidung", "Nutzeraktion", "Betreiber bestätigt", "ShowerNow", "showernow", "class=\"draft\"", "14 Monate", "Datensicherung", "Backup", "Debuglogs"]
        for path in ["/datenschutz", "/marketing", "/support", "/impressum", "/"] {
            let t = text(try await a.handle(path: path, ifNoneMatch: nil))
            for b in banned { #expect(!t.contains(b), "\(path): \(b)") }
            for r in 1...9 { #expect(!t.contains("[R\(r)]"), "\(path)") }
        }
    }

    @Test func privacyHasNoLanguageSwitchEvenWithEnglishEnabled() async throws {
        let a = api { fullInfo(&$0); $0.englishEnabled = true }
        let t = text(try await a.handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(!t.contains("hreflang") && !t.contains("/en/"))
    }

    @Test func warningsParagraphOnlyWithWarnPushFlag() async throws {
        let off = text(try await api(fullInfo).handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(!off.contains("Amtliche Warnungen") && !off.contains("Unwetter, Frost oder Glatteis"))
        let on = text(try await api { fullInfo(&$0); $0.warnPushEnabled = true }.handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(on.contains("<strong>Amtliche Warnungen (optional).</strong>") && on.contains("Unwetter, Frost oder Glatteis") && on.contains("im Notfall wähle 112"))
        #expect(!on.contains("[") && !on.contains("Entwurf"))
        for h in Self.requiredPrivacyHeadings { #expect(on.contains("<h2>\(h)</h2>"), "\(h)") }
        // Flag is derived from WARN_PUSH_ENABLED together with PUSH_ENABLED.
        #expect(try Config.fromEnvironment(["WARN_PUSH_ENABLED": "true"]).site.warnPushEnabled == false)
        let key = NSTemporaryDirectory() + "site-test-key-\(UUID().uuidString).p8"
        try Data("x".utf8).write(to: URL(fileURLWithPath: key))
        defer { try? FileManager.default.removeItem(atPath: key) }
        let apns = ["PUSH_ENABLED": "true", "APNS_KEY_FILE": key, "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "APNS_TOPIC": "t", "IMAGE_WIDTH": "1024"]
        #expect(try Config.fromEnvironment(apns).site.warnPushEnabled == false)
        #expect(try Config.fromEnvironment(apns.merging(["WARN_PUSH_ENABLED": "true"]) { $1 }).site.warnPushEnabled)
        #expect(SiteInfo().warnPushEnabled == false)
    }

    @Test func imprintShowsOperatorSourcesAndNavigation() async throws {
        let t = text(try await api(fullInfo).handle(path: "/impressum", ifNoneMatch: nil))
        #expect(t.contains("Erika Beispiel") && t.contains("Musterweg 1<br>12345 Musterstadt") && t.contains("mailto:kontakt@example.org"))
        #expect(t.contains("§ 5 Digitale-Dienste-Gesetz") && !t.contains("class=\"warn\""))
        #expect(t.contains("Quelle: Deutscher Wetterdienst") && t.contains("CC BY 4.0") && t.contains("EUMETSAT"))
        #expect(t.contains("DWD ICON-D2/ICON-EU Modelldaten (CC BY 4.0, Quelle: Deutscher Wetterdienst)") && t.contains("© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium"))
        for link in ["/datenschutz", "/support", "/marketing", "/impressum"] { #expect(t.contains("<a href=\"\(link)\">"), "\(link)") }
        for path in ["/datenschutz", "/support", "/marketing"] {
            #expect(text(try await api(fullInfo).handle(path: path, ifNoneMatch: nil)).contains("href=\"/impressum\""), "\(path)")
        }
        let none = text(try await api().handle(path: "/impressum", ifNoneMatch: nil))
        #expect(none.contains(SitePages.missingNotice) && !none.contains("mailto:"))
    }

    @Test func configuredValuesAppearAndNoticeIsHidden() async throws {
        let t = text(try await api(fullInfo).handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(t.contains("Erika Beispiel") && t.contains("Musterweg 1<br>12345 Musterstadt"))
        #expect(t.contains("mailto:kontakt@example.org") && t.contains("Der Proxy speichert Zugriffe 7 Tage."))
        #expect(!t.contains(SitePages.missingNotice))
    }

    @Test func missingConfigurationShowsNoticeAndHealthStaysOk() async throws {
        let a = api()
        let t = text(try await a.handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(t.contains("Angaben zum Verantwortlichen sind noch nicht konfiguriert"))
        #expect(!t.contains("noch nicht angegeben"))
        let partial = text(try await api { $0.operatorName = "Nur Name" }.handle(path: "/datenschutz", ifNoneMatch: nil))
        #expect(partial.contains("noch nicht konfiguriert") && partial.contains("Nur Name"))
        #expect(try await a.handle(path: "/healthz", ifNoneMatch: nil).status == 200)
        #expect(text(try await a.handle(path: "/support", ifNoneMatch: nil)).contains("Kontaktadresse ist noch nicht konfiguriert"))
    }

    @Test func valuesAreEscaped() async throws {
        let evil = "<script>alert(1)</script>\"'&"
        let a = api {
            $0.operatorName = evil; $0.operatorAddress = evil; $0.operatorEmail = "a@b.c\"><script>x</script>"
            $0.proxyLogNote = evil; $0.appStoreURL = "https://example.org/\"onmouseover=\"x"; $0.testflightURL = "javascript:alert(1)"
        }
        for path in ["/datenschutz", "/marketing", "/support"] {
            let t = text(try await a.handle(path: path, ifNoneMatch: nil))
            #expect(!t.contains("<script"), "\(path)")
            #expect(!t.contains("javascript:"), "\(path)")
            #expect(!t.contains("onmouseover=\"x"), "\(path)")
        }
        #expect(text(try await a.handle(path: "/datenschutz", ifNoneMatch: nil)).contains("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;&amp;"))
    }

    @Test func marketingLinksOnlyWhenConfiguredHttps() async throws {
        let none = text(try await api().handle(path: "/marketing", ifNoneMatch: nil))
        #expect(!none.contains("im App Store") && !none.contains("über TestFlight testen"))
        #expect(none.contains(SitePages.appDocsURL) && none.contains(SitePages.backendDocsURL))
        #expect(none.contains("Quelle: Deutscher Wetterdienst") && none.contains("bildlich wiedergegeben") && none.contains("ICON-D2/ICON-EU"))
        let some = text(try await api { $0.testflightURL = "https://testflight.example.org/join/abc" }.handle(path: "/marketing", ifNoneMatch: nil))
        #expect(some.contains("href=\"https://testflight.example.org/join/abc\""))
    }

    @Test func etagAndNotModified() async throws {
        let a = api(fullInfo)
        let first = try await a.handle(path: "/datenschutz", ifNoneMatch: nil)
        let etag = try #require(hdr(first, "ETag"))
        let again = try await a.handle(path: "/datenschutz", ifNoneMatch: etag)
        #expect(again.status == 304 && again.body.isEmpty && hdr(again, "Content-Type") == nil)
        #expect(hdr(again, "ETag") == etag)
        let other = try await a.handle(path: "/marketing", ifNoneMatch: nil)
        #expect(hdr(other, "ETag") != etag)
    }

    @Test func existingRoutesUnchanged() async throws {
        let a = api(fullInfo)
        let health = try await a.handle(path: "/healthz", ifNoneMatch: nil)
        #expect(health.status == 200 && text(health) == "ok\n" && hdr(health, "Cache-Control") == "no-store")
        #expect(try await a.handle(path: "/v1/radar/latest.json", ifNoneMatch: nil).status == 404)  // nothing published
        for bad in ["/datenschutz/", "/impressum/", "/v1/radar/x"] {
            #expect(try await a.handle(path: bad, ifNoneMatch: nil).status == 404, "\(bad)")
        }
    }

    @Test func configReadsEnvironment() throws {
        let c = try Config.fromEnvironment(["OPERATOR_NAME": "  N ", "OPERATOR_EMAIL": "e@example.org"])
        #expect(c.site.operatorName == "N" && c.site.operatorEmail == "e@example.org" && c.site.operatorAddress.isEmpty)
        #expect(c.site.missingRequired)
    }
}
