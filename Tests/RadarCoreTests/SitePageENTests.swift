import Foundation
import Testing
@testable import RadarCore

private func hdr(_ r: ApiResponse, _ n: String) -> String? { r.headers.first { $0.0 == n }?.1 }
private func text(_ r: ApiResponse) -> String { String(decoding: r.body, as: UTF8.self) }

private func api(en: Bool, _ edit: (inout SiteInfo) -> Void = { _ in }) -> Api {
    var cfg = smallConfig()
    cfg.site.englishEnabled = en
    edit(&cfg.site)
    return Api(repo: MemoryRepo(), config: cfg)
}

private func fullInfo(_ s: inout SiteInfo) {
    s.operatorName = "Erika Beispiel"
    s.operatorAddress = "Musterweg 1\\n12345 Musterstadt"
    s.operatorEmail = "kontakt@example.org"
}

private let enPaths = ["/en/privacy", "/en/support", "/en/imprint", "/en/marketing"]

/// DRAFT English pages: off by default (404), served only with `SITE_EN_ENABLED`.
@Suite("English site pages (draft, behind SITE_EN_ENABLED)")
struct SitePageENTests {
    @Test func offByDefaultAnswers404AndGermanPagesDoNotLinkThere() async throws {
        #expect(SiteInfo().englishEnabled == false)
        #expect(try Config.fromEnvironment([:]).site.englishEnabled == false)
        let a = api(en: false, fullInfo)
        for p in enPaths { #expect(try await a.handle(path: p, ifNoneMatch: nil).status == 404, "\(p)") }
        for p in ["/datenschutz", "/support", "/impressum", "/marketing"] {
            let r = try await a.handle(path: p, ifNoneMatch: nil)
            #expect(r.status == 200 && !text(r).contains("/en/") && !text(r).contains("hreflang"), "\(p)")
        }
    }

    @Test func enabledServesFourPagesWithHeadersAndLanguage() async throws {
        let a = api(en: true, fullInfo)
        let pages = [("/en/privacy", "<h1>Privacy Policy</h1>"), ("/en/support", "<h1>Support</h1>"),
                     ("/en/imprint", "<h1>Legal Notice</h1>"), ("/en/marketing", "<h1>Showers</h1>")]
        for (path, heading) in pages {
            let r = try await a.handle(path: path, ifNoneMatch: nil)
            #expect(r.status == 200, "\(path)")
            let t = text(r)
            #expect(t.contains("<html lang=\"en\">") && t.contains(heading), "\(path)")
            #expect(hdr(r, "Content-Language") == "en")
            #expect(hdr(r, "Content-Type") == "text/html; charset=utf-8")
            #expect(hdr(r, "Cache-Control") == "public, max-age=3600")
            #expect(hdr(r, "Referrer-Policy") == "no-referrer" && hdr(r, "Set-Cookie") == nil)
            #expect(hdr(r, "Content-Security-Policy") == "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
            #expect(!t.contains("<script") && !t.contains("src=\"http"))
            #expect(t.contains("<a href=\"/en/privacy\">Privacy</a>") && t.contains(">Deutsch</a>"))
        }
        #expect(try await a.handle(path: "/en/privacy/", ifNoneMatch: nil).status == 404)
        #expect(try await a.handle(path: "/en/privacy?x=1", ifNoneMatch: nil).status == 200)
        // The existing landing page and German URLs are unchanged.
        #expect(hdr(try await a.handle(path: "/en", ifNoneMatch: nil), "Content-Language") == "en")
        #expect(hdr(try await a.handle(path: "/datenschutz", ifNoneMatch: nil), "Content-Language") == nil)
    }

    @Test func languageSwitchLinksPointToTheSamePage() async throws {
        let a = api(en: true, fullInfo)
        for (de, en) in [("/datenschutz", "/en/privacy"), ("/support", "/en/support"), ("/impressum", "/en/imprint"), ("/marketing", "/en/marketing")] {
            let g = text(try await a.handle(path: de, ifNoneMatch: nil))
            #expect(g.contains("<a href=\"\(en)\" hreflang=\"en\" lang=\"en\">English</a>"), "\(de)")
            let e = text(try await a.handle(path: en, ifNoneMatch: nil))
            #expect(e.contains("<a href=\"\(de)\" hreflang=\"de\" lang=\"de\">Deutsch</a>"), "\(en)")
        }
    }

    @Test func privacyIsTheDraftTextWithOperatorValues() async throws {
        let t = text(try await api(en: true, fullInfo).handle(path: "/en/privacy", ifNoneMatch: nil))
        for h in ["1. Controller", "2. Overview", "3. Radar map and radar service", "4. Direct retrieval from the German Weather Service",
                  "5. Rain alerts, areas and Live Activities (optional)", "6. Location and saved places", "7. Map view and place search (Apple)",
                  "8. On-device summary", "9. Apple Watch, widgets and Live Activities", "10. Operational statistics of the radar service",
                  "11. Operator diagnostics (only on approval by the operator, voluntary)", "12. No debug logs containing personal data",
                  "13. Your rights", "14. Sources", "15. Hosting and recipients"] {
            #expect(t.contains("<h2>\(h)</h2>"), "\(h)")
        }
        #expect(t.contains("No user account, no advertising, no tracking, no analytics SDKs."))
        #expect(t.contains("Hetzner Online GmbH") && t.contains("Art. 6(1)(f) GDPR") && t.contains("up to roughly 14 months"))
        #expect(t.contains("Erika Beispiel") && t.contains("Musterweg 1<br>12345 Musterstadt") && t.contains("mailto:kontakt@example.org"))
        #expect(!t.contains("OPERATOR_NAME") && !t.contains("class=\"warn\""))
        // Editorial markers are removed; open items stay visible as draft spans and are not silently dropped.
        #expect(!t.contains("[R1]") && !t.contains("[R9]"))
        #expect(t.contains("<span class=\"draft\">[date of go-live]</span>"))
        #expect(t.contains("[Operator to confirm:") && t.contains("Backups: <span class=\"draft\">[operator information pending"))
    }

    @Test func missingOperatorDetailsShowNoticeNotInventedData() async throws {
        let a = api(en: true)
        for p in ["/en/privacy", "/en/imprint"] {
            let t = text(try await a.handle(path: p, ifNoneMatch: nil))
            #expect(t.contains("The controller details are not configured yet."), "\(p)")
        }
        #expect(text(try await a.handle(path: "/en/support", ifNoneMatch: nil)).contains("The contact address is not configured yet."))
        let partial = text(try await api(en: true) { $0.operatorName = "Only Name" }.handle(path: "/en/imprint", ifNoneMatch: nil))
        #expect(partial.contains("not configured yet") && partial.contains("Only Name"))
    }

    @Test func imprintHasNoPlaceholderLeaks() async throws {
        let t = text(try await api(en: true, fullInfo).handle(path: "/en/imprint", ifNoneMatch: nil))
        #expect(t.contains("Erika Beispiel") && t.contains("mailto:kontakt@example.org") && t.contains("Section 5 of the German Digital Services Act"))
        #expect(!t.contains("[") && !t.contains("OPERATOR_") && !t.contains("class=\"warn\"") && !t.contains("class=\"draft\""))
        #expect(t.contains("ESA WorldCover") && t.contains("EUMETSAT") && t.contains("CC BY 4.0") && t.contains("not affiliated"))
    }

    @Test func valuesAreEscaped() async throws {
        let evil = "<script>alert(1)</script>\"'&"
        let a = api(en: true) {
            $0.operatorName = evil; $0.operatorAddress = evil; $0.operatorEmail = "a@b.c\"><script>x</script>"
            $0.appStoreURL = "https://example.org/\"onmouseover=\"x"; $0.testflightURL = "javascript:alert(1)"
        }
        for p in enPaths {
            let t = text(try await a.handle(path: p, ifNoneMatch: nil))
            #expect(!t.contains("<script"), "\(p)")
            #expect(!t.contains("javascript:") && !t.contains("onmouseover=\"x"), "\(p)")
        }
        #expect(text(try await a.handle(path: "/en/privacy", ifNoneMatch: nil)).contains("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;&amp;"))
    }

    @Test func marketingLinksOnlyWhenConfiguredHttps() async throws {
        let none = text(try await api(en: true).handle(path: "/en/marketing", ifNoneMatch: nil))
        #expect(!none.contains("on the App Store") && !none.contains("through TestFlight</a>"))
        let some = text(try await api(en: true) { $0.testflightURL = "https://testflight.example.org/join/abc" }.handle(path: "/en/marketing", ifNoneMatch: nil))
        #expect(some.contains("href=\"https://testflight.example.org/join/abc\""))
    }

    @Test func englishEnabledReadsEnvironmentAndLiveSetting() throws {
        #expect(try Config.fromEnvironment(["SITE_EN_ENABLED": "true"]).site.englishEnabled)
        #expect(try Config.fromEnvironment(["SITE_EN_ENABLED": "TRUE"]).site.englishEnabled)
        #expect(try Config.fromEnvironment(["SITE_EN_ENABLED": "false"]).site.englishEnabled == false)
        #expect(try Config.fromEnvironment(["SITE_EN_ENABLED": ""]).site.englishEnabled == false)
        let base = try Config.fromEnvironment([:])
        #expect(try base.applying(overrides: ["SITE_EN_ENABLED": "true"]).site.englishEnabled)
        let def = try #require(ConfigRegistry.settings.first { $0.key == "SITE_EN_ENABLED" })
        #expect(def.defaultValue == "false")
    }
}
