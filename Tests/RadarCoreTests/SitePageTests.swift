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
        for (path, heading) in [("/datenschutz", "<h1>Datenschutzerklärung</h1>"), ("/marketing", "<h1>ShowerNow</h1>"), ("/support", "<h1>Support</h1>")] {
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
        #expect(t.contains("noch nicht angegeben"))
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
        #expect(none.contains("Quelle: Deutscher Wetterdienst") && none.contains("bildlich wiedergegeben"))
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
        for bad in ["/", "/datenschutz/", "/impressum", "/v1/radar/x"] {
            #expect(try await a.handle(path: bad, ifNoneMatch: nil).status == 404, "\(bad)")
        }
    }

    @Test func configReadsEnvironment() throws {
        let c = try Config.fromEnvironment(["OPERATOR_NAME": "  N ", "OPERATOR_EMAIL": "e@example.org"])
        #expect(c.site.operatorName == "N" && c.site.operatorEmail == "e@example.org" && c.site.operatorAddress.isEmpty)
        #expect(c.site.missingRequired)
    }
}
