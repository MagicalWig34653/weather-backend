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

/// All `src`/`href`/`srcset` values of a page.
private func references(_ html: String) -> [String] {
    var out: [String] = []
    for attr in ["src=\"", "href=\"", "srcset=\""] {
        var rest = Substring(html)
        while let r = rest.range(of: attr) {
            rest = rest[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let value = String(rest[..<end])
            if attr == "srcset=\"" {
                // "url 320w, url 640w" -> urls
                out += value.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
            } else { out.append(value) }
        }
    }
    return out
}

@Suite("Landing page")
struct LandingPageTests {
    @Test func germanRootServesLandingPage() async throws {
        let r = try await api().handle(path: "/", ifNoneMatch: nil)
        #expect(r.status == 200)
        #expect(hdr(r, "Content-Type") == "text/html; charset=utf-8")
        #expect(hdr(r, "Content-Language") == "de")
        let t = text(r)
        #expect(t.contains("<html lang=\"de\">") && t.contains("<h1 id=\"h-hero\">Regen im Blick.</h1>"))
        #expect(t.contains("Bald im App Store") && t.contains("Quelle: Deutscher Wetterdienst"))
        #expect(t.contains("href=\"/datenschutz\"") && t.contains("href=\"/support\"") && t.contains("href=\"/marketing\"") && t.contains("href=\"/impressum\""))
        #expect(t.contains("hreflang=\"en\" href=\"/en\"") && t.contains("rel=\"canonical\" href=\"/\""))
        #expect(t.contains("class=\"skip\" href=\"#main\""))
        #expect((try await api().handle(path: "/?utm=x", ifNoneMatch: nil)).status == 200)
    }

    @Test func englishPage() async throws {
        let r = try await api().handle(path: "/en", ifNoneMatch: nil)
        #expect(r.status == 200 && hdr(r, "Content-Language") == "en")
        let t = text(r)
        #expect(t.contains("<html lang=\"en\">") && t.contains("Rain at a glance.") && t.contains("Coming soon to the App Store"))
        #expect(t.contains("Source: Deutscher Wetterdienst") && t.contains("rel=\"canonical\" href=\"/en\""))
        #expect(!t.contains("Regen im Blick"))
    }

    @Test func noLegacyNameAndNoExternalResources() async throws {
        let allowed = Set([LandingPage.dwdURL])
        for path in ["/", "/en"] {
            let t = text(try await api().handle(path: path, ifNoneMatch: nil))
            #expect(!t.lowercased().contains("showernow"), "\(path)")
            #expect(!t.contains("<script") && !t.contains("<iframe") && !t.contains("@import") && !t.contains("url("), "\(path)")
            #expect(!t.contains("src=\"http") && !t.contains("srcset=\"http"), "\(path)")
            // The Open Graph image is the only absolute self reference (content attribute, not fetched by the page).
            for ref in references(t) where ref.hasPrefix("http") || ref.hasPrefix("//") {
                #expect(allowed.contains(ref), "unexpected external reference \(ref) on \(path)")
            }
            #expect(t.contains("property=\"og:image\" content=\"https://showers.linolaske.de/assets/og."))
            #expect(t.contains("twitter:card\" content=\"summary_large_image\""))
            #expect(t.contains("rel=\"apple-touch-icon\" href=\"/assets/apple-touch-icon."))
        }
        let css = text(try await api().handle(path: LandingPage.css.path, ifNoneMatch: nil))
        #expect(!css.contains("http") && !css.contains("@import") && !css.contains("url("))
    }

    @Test func headersAndSizes() async throws {
        let a = api()
        for path in ["/", "/en"] {
            let r = try await a.handle(path: path, ifNoneMatch: nil)
            #expect(hdr(r, "Content-Security-Policy") == "default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            #expect(hdr(r, "X-Content-Type-Options") == "nosniff" && hdr(r, "Referrer-Policy") == "no-referrer")
            #expect(hdr(r, "X-Frame-Options") == "DENY" && hdr(r, "Cache-Control") == "public, max-age=300")
            #expect(hdr(r, "Set-Cookie") == nil)
            #expect(r.body.count < 24_000 && !r.body.isEmpty)
        }
        #expect(LandingPage.css.body.count < 16_000)
    }

    @Test func everyReferencedAssetIsServedWithLongCache() async throws {
        let a = api()
        var seen = Set<String>()
        for path in ["/", "/en"] {
            let t = text(try await a.handle(path: path, ifNoneMatch: nil))
            for ref in references(t) where ref.hasPrefix("/assets/") { seen.insert(ref) }
        }
        // The Open Graph image is referenced by an absolute URL only; every other asset is referenced by path.
        #expect(seen.count == LandingPage.assets.count - 1)
        #expect(!seen.contains(LandingPage.og.path))
        #expect(try await a.handle(path: LandingPage.og.path, ifNoneMatch: nil).status == 200)
        for ref in seen {
            let r = try await a.handle(path: ref, ifNoneMatch: nil)
            #expect(r.status == 200, "\(ref)")
            #expect(hdr(r, "Cache-Control") == "public, max-age=31536000, immutable")
            #expect(hdr(r, "X-Content-Type-Options") == "nosniff")
            let type = try #require(hdr(r, "Content-Type"))
            if ref.hasSuffix(".css") { #expect(type == "text/css; charset=utf-8") }
            else if ref.hasSuffix(".png") {
                #expect(type == "image/png" && r.body.starts(with: [0x89, 0x50, 0x4E, 0x47]) && r.body.count <= 20_000, "\(ref)")
            } else if ref.hasSuffix(".jpg") {
                #expect(type == "image/jpeg" && r.body.starts(with: [0xFF, 0xD8]) && r.body.count <= 80_000, "\(ref) \(r.body.count)")
            } else {
                #expect(type == "image/webp")
                #expect(r.body.starts(with: Array("RIFF".utf8)) && r.body[8..<12].elementsEqual(Array("WEBP".utf8)), "\(ref)")
                let limit = ref.contains("/icon.") ? 60_000 : 90_000
                #expect(r.body.count <= limit, "\(ref) \(r.body.count)")
            }
            let etag = try #require(hdr(r, "ETag"))
            let again = try await a.handle(path: ref, ifNoneMatch: etag)
            #expect(again.status == 304 && again.body.isEmpty)
        }
        // A wrong hash is not served.
        #expect(try await a.handle(path: "/assets/icon.0000000000.webp", ifNoneMatch: nil).status == 404)
        #expect(try await a.handle(path: "/assets/", ifNoneMatch: nil).status == 404)
    }

    /// Page weight budget: HTML plus the assets a first view loads (hero images eager, CSS, icon) stays small.
    @Test func firstViewWeightBudget() async throws {
        let a = api()
        let r = try await a.handle(path: "/", ifNoneMatch: nil)
        let html = text(r)
        var total = r.body.count + LandingPage.css.body.count + LandingPage.icon.body.count
        // Eager images: the four hero variants of one colour scheme at 2x (640 px) are the worst case.
        total += LandingPage.radarLight.body.count + LandingPage.placesLight.body.count
        #expect(total < 600_000, "first view \(total) bytes")
        let everything = LandingPage.assets.reduce(r.body.count) { $0 + $1.body.count }
        #expect(everything < 600_000, "all assets \(everything) bytes")
        #expect(html.components(separatedBy: "loading=\"lazy\"").count > 4)
        #expect(html.contains("fetchpriority=\"high\"") && html.contains("srcset=") && html.contains("sizes="))
    }

    @Test func contentSections() async throws {
        let de = text(try await api().handle(path: "/", ifNoneMatch: nil))
        for needle in ["Radar mit Zeitleiste", "Wolken als Ebene", "Deine Orte und Regenhinweise", "Regen beginnt in 12 min", "Beispiel für einen Regenhinweis",
                       "Widgets und Apple Watch", "Live Activity", "Keine Standortverläufe", "Ohne Werbung", "EUMETSAT", "Deutscher Wetterdienst"] {
            #expect(de.contains(needle), "\(needle)")
        }
        let en = text(try await api().handle(path: "/en", ifNoneMatch: nil))
        for needle in ["Radar with timeline", "Clouds as a layer", "Rain starts in 12 min", "No location history", "No ads", "EUMETSAT"] {
            #expect(en.contains(needle), "\(needle)")
        }
        // Every image has an alt attribute; decorative ones use an empty one.
        for t in [de, en] {
            var rest = Substring(t)
            while let r = rest.range(of: "<img ") {
                rest = rest[r.upperBound...]
                let tag = rest[..<(rest.firstIndex(of: ">") ?? rest.endIndex)]
                #expect(tag.contains(" alt=\""), "\(tag)")
                #expect(tag.contains("width=\"") && tag.contains("height=\""), "\(tag)")
            }
        }
    }

    @Test func pageEtagAndNotModified() async throws {
        let a = api()
        let first = try await a.handle(path: "/", ifNoneMatch: nil)
        let etag = try #require(hdr(first, "ETag"))
        #expect(try await a.handle(path: "/", ifNoneMatch: etag).status == 304)
        #expect(hdr(try await a.handle(path: "/en", ifNoneMatch: nil), "ETag") != etag)
    }

    @Test func storeAndTestflightLinksFromExistingConfig() async throws {
        let none = text(try await api().handle(path: "/", ifNoneMatch: nil))
        #expect(!none.contains("class=\"btn\"") && !none.contains("TestFlight testen"))
        let some = text(try await api {
            $0.appStoreURL = "https://apps.apple.com/app/id1"; $0.testflightURL = "javascript:alert(1)"
        }.handle(path: "/", ifNoneMatch: nil))
        #expect(some.contains("class=\"btn\" href=\"https://apps.apple.com/app/id1\"") && !some.contains("Bald im App Store"))
        #expect(!some.contains("javascript:"))
    }

    @Test func linkedPagesAndOtherPathsUnchanged() async throws {
        let a = api()
        for path in ["/datenschutz", "/support", "/marketing", "/impressum", "/healthz"] {
            #expect(try await a.handle(path: path, ifNoneMatch: nil).status == 200, "\(path)")
        }
        for bad in ["/en/", "/index.html", "/assets", "/assets/landing.css", "/robots.txt", "/v1/radar/x"] {
            #expect(try await a.handle(path: bad, ifNoneMatch: nil).status == 404, "\(bad)")
        }
    }

    /// Manual visual check: LANDING_DUMP_DIR=/dir swift test --filter dumpForVisualCheck writes the site to disk.
    @Test func dumpForVisualCheck() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LANDING_DUMP_DIR"] else { return }
        let a = api()
        try FileManager.default.createDirectory(atPath: dir + "/assets", withIntermediateDirectories: true)
        for (path, file) in [("/", "index.html"), ("/en", "en.html")] {
            try Data(try await a.handle(path: path, ifNoneMatch: nil).body).write(to: URL(fileURLWithPath: dir + "/" + file))
        }
        for asset in LandingPage.assets { try Data(asset.body).write(to: URL(fileURLWithPath: dir + "/assets/" + asset.path.dropFirst(8))) }
    }
}
