import Foundation

/// Public landing page (`/` German, `/en` English) and its static assets (`/assets/<name>.<hash>.<ext>`).
/// Self-contained: no external resources, no script; images are embedded as Base64 (see `LandingAssetData`), so nothing is read from disk at run time.
public enum LandingPage {
    /// App Store link; empty until the app is released. A configured `APP_STORE_URL` (operator pages) takes precedence.
    public static let appStoreURL = ""
    public static let dwdURL = "https://www.dwd.de"

    public struct Route: Sendable {
        public var headers: [(String, String)]
        public var body: [UInt8]
        public var etag: String
    }

    // MARK: Assets

    struct Asset: Sendable {
        let name: String
        let ext: String
        let type: String
        let body: [UInt8]
        let hash: String
        var path: String { "/assets/\(name).\(hash).\(ext)" }

        init(name: String, ext: String, type: String, body: [UInt8]) {
            self.name = name; self.ext = ext; self.type = type; self.body = body
            hash = String(Hashing.sha256Hex(body).prefix(10))
        }
    }

    private static func image(_ name: String, _ base64: String) -> Asset {
        Asset(name: name, ext: "webp", type: "image/webp", body: Array(Data(base64Encoded: base64) ?? Data()))
    }

    static let css = Asset(name: "landing", ext: "css", type: "text/css; charset=utf-8", body: Array(stylesheet.utf8))
    static let icon = image("icon", LandingAssetData.icon)
    static let radarLight = image("radar-light", LandingAssetData.radarLight)
    static let radarDark = image("radar-dark", LandingAssetData.radarDark)
    static let placesLight = image("places-light", LandingAssetData.placesLight)
    static let placesDark = image("places-dark", LandingAssetData.placesDark)
    static let assets: [Asset] = [css, icon, radarLight, radarDark, placesLight, placesDark]

    static let assetCSP = "default-src 'none'; frame-ancestors 'none'"
    static let pageCSP = "default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    private static func etag(_ body: [UInt8]) -> String { "\"" + Hashing.sha256Hex(body).prefix(32) + "\"" }

    /// Route for `/`, `/en` and the hashed assets; nil for every other path.
    public static func route(path: String, info: SiteInfo) -> Route? {
        if let lang = Lang(path: path) {
            let body = Array(html(lang, info: info).utf8)
            return Route(headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "public, max-age=300"),
                                   ("Content-Language", lang.code), ("Referrer-Policy", "no-referrer"),
                                   ("Content-Security-Policy", pageCSP), ("X-Frame-Options", "DENY"),
                                   ("Permissions-Policy", "camera=(), microphone=(), geolocation=()")],
                         body: body, etag: etag(body))
        }
        guard let asset = assets.first(where: { $0.path == path }) else { return nil }
        return Route(headers: [("Content-Type", asset.type), ("Cache-Control", "public, max-age=31536000, immutable"),
                               ("Referrer-Policy", "no-referrer"), ("Content-Security-Policy", assetCSP), ("X-Frame-Options", "DENY")],
                     body: asset.body, etag: "\"\(asset.hash)\"")
    }

    // MARK: Copy

    enum Lang {
        case de, en
        init?(path: String) {
            switch path {
            case "/": self = .de
            case "/en": self = .en
            default: return nil
            }
        }
        var code: String { self == .de ? "de" : "en" }
    }

    struct Copy {
        var title, description, skip, navFeatures, navPrivacy, navSupport, switchLabel, switchHref, switchLang: String
        var eyebrow, h1, lead, soon, testflight, seeFeatures, caption, alt1, alt2: String
        var featuresH2, featuresLead: String
        var cards: [(icon: String, title: String, text: String, tag: String)]
        var privacyH2, privacyLead: String
        var privacy: [String]
        var privacyLink: String
        var dataH2, dataText, dataSource, dataLink: String
        var ctaH2, ctaText: String
        var footerMore, footerSource: String
    }

    static let icRadar = "<path d=\"M3 12a9 9 0 1 0 9-9\"/><path d=\"M12 12l5-5\"/><circle cx=\"12\" cy=\"12\" r=\"1.6\"/>"
    static let icPin = "<path d=\"M12 21s7-6.2 7-11a7 7 0 0 0-14 0c0 4.8 7 11 7 11z\"/><circle cx=\"12\" cy=\"10\" r=\"2.5\"/>"
    static let icBell = "<path d=\"M6 9a6 6 0 0 1 12 0c0 6 2 7 2 7H4s2-1 2-7z\"/><path d=\"M10 20a2 2 0 0 0 4 0\"/>"
    static let icWatch = "<rect x=\"7\" y=\"6\" width=\"10\" height=\"12\" rx=\"3\"/><path d=\"M9 6l1-3h4l1 3M9 18l1 3h4l1-3\"/>"

    static func copy(_ lang: Lang) -> Copy {
        switch lang {
        case .de:
            return Copy(
                title: "Showers \u{2013} Regenradar für Deutschland",
                description: "Showers zeigt das Regenradar des Deutschen Wetterdienstes mit Zeitleiste und Vorhersage, Prognose für deine Orte, Widgets und Apple Watch. Ohne Konto, ohne Werbung.",
                skip: "Zum Inhalt springen", navFeatures: "Funktionen", navPrivacy: "Datenschutz", navSupport: "Support",
                switchLabel: "EN", switchHref: "/en", switchLang: "en",
                eyebrow: "Regenradar für iPhone, iPad und Apple Watch",
                h1: "Regen im Blick.",
                lead: "Showers zeigt dir, wo es regnet und wann es bei dir anfängt oder aufhört. Mit dem Radar des Deutschen Wetterdienstes: ruhig, schnell und ohne Konto.",
                soon: "Bald im App Store", testflight: "Beta über TestFlight testen", seeFeatures: "Funktionen ansehen",
                caption: "Beispielansichten, Radardaten vom 2. November 2026.",
                alt1: "Showers: Radarkarte von Niedersachsen mit Regengebieten, Zeitleiste und Wiedergabe-Taste",
                alt2: "Showers: Liste gespeicherter Orte mit Regenhinweis-Glocke und Regionen",
                featuresH2: "Gebaut für eine Frage: Wird es nass?",
                featuresLead: "Weniger Wetter-Show, mehr Antwort. Showers konzentriert sich auf Niederschlag.",
                cards: [
                    (icRadar, "Radar mit Zeitleiste", "Die Niederschlagsmessung der letzten Stunden und die Vorhersage bis zu zwei Stunden in Fünf-Minuten-Schritten. Abspielen oder per Zeitleiste zu jedem Zeitpunkt springen.", ""),
                    (icPin, "Prognose für deine Orte", "Speichere Orte oder nutze optional deinen Standort. Showers zeigt Beginn, Ende und Intensität des Regens, aber nur, soweit die Daten es hergeben.", ""),
                    (icBell, "Regenhinweise", "Lass dich für einen Ort oder eine Region (5, 10 oder 25 km Umkreis) per Mitteilung auf Regen hinweisen. Das setzt den Showers-Radar-Dienst und deine Erlaubnis für Mitteilungen voraus.", "Optional \u{B7} braucht den Radar-Dienst"),
                    (icWatch, "Widgets und Apple Watch", "Widgets für deine Orte und eine Watch-App mit Ortsliste, Ortsprognose und Radarkarte (Vorschau).", "In Erprobung"),
                ],
                privacyH2: "Datensparsam, mit Absicht",
                privacyLead: "Datenschutz ist hier eine Produktanforderung, kein Nachsatz.",
                privacy: [
                    "Kein Benutzerkonto, keine Werbung, kein Tracking, keine Analyse-SDKs.",
                    "Der Radar-Dienst führt keine Zugriffsprotokolle. Radar-Anfragen enthalten keinen Ort und keine Kennung.",
                    "Gespeicherte Orte und eigene Namen bleiben auf deinem Gerät. Keine Hintergrundortung, keine Standortverläufe.",
                    "Der Standort ist optional und wird erst bei Nutzung angefragt. Für Regionen erhält der Server nur einen groben Bereich.",
                    "Karte und Ortssuche nutzen Apple Karten; dabei sieht Apple die Anfrage.",
                ],
                privacyLink: "Datenschutzerklärung lesen",
                dataH2: "Daten vom Deutschen Wetterdienst",
                dataText: "Radar und Prognose stammen vom Deutschen Wetterdienst (DWD). Showers ist eine eigenständige App und kein Angebot des DWD.",
                dataSource: "Quelle: Deutscher Wetterdienst. Die Radarbilder sind aus Rasterdaten des DWD bildlich wiedergegeben und aufbereitet (verändert).",
                dataLink: "Zum Deutschen Wetterdienst",
                ctaH2: "Showers kommt in den App Store",
                ctaText: "Bis dahin läuft eine frühe Beta-Erprobung über TestFlight.",
                footerMore: "Mehr über Showers",
                footerSource: "Quelle: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben, aufbereitet.")
        case .en:
            return Copy(
                title: "Showers \u{2013} Rain radar for Germany",
                description: "Showers shows the rain radar of the German Weather Service with timeline and forecast, forecasts for your places, widgets and Apple Watch. No account, no ads.",
                skip: "Skip to content", navFeatures: "Features", navPrivacy: "Privacy", navSupport: "Support",
                switchLabel: "DE", switchHref: "/", switchLang: "de",
                eyebrow: "Rain radar for iPhone, iPad and Apple Watch",
                h1: "Rain at a glance.",
                lead: "Showers shows you where it rains and when it starts or stops where you are. Powered by the radar of the German Weather Service (DWD): calm, fast and without an account.",
                soon: "Coming soon to the App Store", testflight: "Try the beta on TestFlight", seeFeatures: "See features",
                caption: "Sample views, radar data from 2 November 2026. The screenshots show the German interface.",
                alt1: "Showers: radar map of Lower Saxony with rain areas, timeline and play button",
                alt2: "Showers: list of saved places with rain alert bell and regions",
                featuresH2: "Built around one question: will it get wet?",
                featuresLead: "Less weather show, more answers. Showers focuses on precipitation.",
                cards: [
                    (icRadar, "Radar with timeline", "Measured precipitation of the last hours and a forecast of up to two hours in five-minute steps. Play it back or jump to any point on the timeline.", ""),
                    (icPin, "Forecast for your places", "Save places or optionally use your location. Showers shows when rain starts and ends and how intense it is, but only as far as the data supports.", ""),
                    (icBell, "Rain alerts", "Get a notification about rain for a place or a region (5, 10 or 25 km radius). This requires the Showers radar service and your permission for notifications.", "Optional \u{B7} needs the radar service"),
                    (icWatch, "Widgets and Apple Watch", "Widgets for your places and a Watch app with a place list, place forecast and a radar map (preview).", "In testing"),
                ],
                privacyH2: "Data-sparing by design",
                privacyLead: "Privacy is a product requirement here, not an afterthought.",
                privacy: [
                    "No user account, no ads, no tracking, no analytics SDKs.",
                    "The radar service keeps no access logs. Radar requests contain no location and no identifier.",
                    "Saved places and custom names stay on your device. No background location, no location history.",
                    "Location is optional and requested only when you use it. For regions the server receives only a coarse area.",
                    "The map and place search use Apple Maps; Apple sees those requests.",
                ],
                privacyLink: "Read the privacy policy (German)",
                dataH2: "Data from the German Weather Service",
                dataText: "Radar and forecast come from the German Weather Service (Deutscher Wetterdienst, DWD). Showers is an independent app and not an offering of the DWD.",
                dataSource: "Source: Deutscher Wetterdienst. The radar images are rendered from DWD grid data and processed (modified).",
                dataLink: "Visit the German Weather Service",
                ctaH2: "Showers is coming to the App Store",
                ctaText: "Until then, an early beta runs on TestFlight.",
                footerMore: "About Showers",
                footerSource: "Source: Deutscher Wetterdienst, grid data rendered as images, processed.")
        }
    }

    // MARK: HTML

    private static func picture(_ light: Asset, _ dark: Asset, w: Int, h: Int, alt: String, eager: Bool) -> String {
        """
        <picture><source media="(prefers-color-scheme: dark)" srcset="\(dark.path)"><img src="\(light.path)" width="\(w)" height="\(h)" alt="\(SitePages.escape(alt))"\(eager ? "" : " loading=\"lazy\"") decoding="async"></picture>
        """
    }

    private static func link(_ url: String, class cls: String, _ label: String) -> String? {
        guard SitePages.safeLink(url, label: label) != nil else { return nil }
        return "<a class=\"\(cls)\" href=\"\(SitePages.escape(url))\" rel=\"noopener noreferrer\">\(SitePages.escape(label))</a>"
    }

    private static func storeButton(_ c: Copy, info: SiteInfo) -> String {
        let url = info.appStoreURL.isEmpty ? appStoreURL : info.appStoreURL
        return link(url, class: "btn", "App Store")
            ?? "<span class=\"btn off\" role=\"note\">\(SitePages.escape(c.soon))</span>"
    }

    static func html(_ lang: Lang, info: SiteInfo) -> String {
        let c = copy(lang)
        let e = SitePages.escape
        let other = lang == .de ? Lang.en : Lang.de
        let testflight = link(info.testflightURL, class: "btn ghost", c.testflight) ?? ""
        let cards = c.cards.map { card in
            """
            <li class="card"><span class="ic" aria-hidden="true"><svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">\(card.icon)</svg></span>
            <h3>\(e(card.title))</h3><p>\(e(card.text))</p>\(card.tag.isEmpty ? "" : "<p class=\"tag\">\(e(card.tag))</p>")</li>
            """
        }.joined(separator: "\n")
        let privacy = c.privacy.map { "<li>\(e($0))</li>" }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="\(lang.code)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(e(c.title))</title>
        <meta name="description" content="\(e(c.description))">
        <link rel="canonical" href="\(lang == .de ? "/" : "/en")">
        <link rel="alternate" hreflang="de" href="/">
        <link rel="alternate" hreflang="en" href="/en">
        <link rel="alternate" hreflang="x-default" href="/">
        <meta property="og:type" content="website">
        <meta property="og:site_name" content="Showers">
        <meta property="og:title" content="\(e(c.title))">
        <meta property="og:description" content="\(e(c.description))">
        <meta property="og:locale" content="\(lang == .de ? "de_DE" : "en_GB")">
        <meta name="twitter:card" content="summary">
        <link rel="icon" type="image/webp" href="\(icon.path)">
        <link rel="apple-touch-icon" href="\(icon.path)">
        <link rel="stylesheet" href="\(css.path)">
        </head><body>
        <a class="skip" href="#main">\(e(c.skip))</a>
        <header class="top"><div class="wrap bar">
        <a class="brand" href="\(lang == .de ? "/" : "/en")"><img src="\(icon.path)" width="36" height="36" alt="" decoding="async"><span>Showers</span></a>
        <nav aria-label="\(lang == .de ? "Hauptnavigation" : "Main")"><a href="#features">\(e(c.navFeatures))</a><a href="/datenschutz">\(e(c.navPrivacy))</a><a href="/support">\(e(c.navSupport))</a><a class="lang" href="\(c.switchHref)" hreflang="\(c.switchLang)" lang="\(c.switchLang)" aria-label="\(other == .de ? "Deutsch" : "English")">\(c.switchLabel)</a></nav>
        </div></header>
        <main id="main">
        <section class="hero wrap" aria-labelledby="h-hero">
        <div class="copy">
        <p class="eyebrow">\(e(c.eyebrow))</p>
        <h1 id="h-hero">\(e(c.h1))</h1>
        <p class="lead">\(e(c.lead))</p>
        <p class="actions">\(storeButton(c, info: info))\(testflight)<a class="link" href="#features">\(e(c.seeFeatures))</a></p>
        </div>
        <figure class="phones">
        <div class="phone">\(picture(radarLight, radarDark, w: 640, h: 1097, alt: c.alt1, eager: true))</div>
        <div class="phone second">\(picture(placesLight, placesDark, w: 640, h: 1391, alt: c.alt2, eager: true))</div>
        <figcaption>\(e(c.caption))</figcaption>
        </figure>
        </section>

        <section id="features" class="wrap sec" aria-labelledby="h-features">
        <h2 id="h-features">\(e(c.featuresH2))</h2>
        <p class="sub">\(e(c.featuresLead))</p>
        <ul class="cards">
        \(cards)
        </ul>
        </section>

        <section class="band"><div class="wrap two">
        <section aria-labelledby="h-privacy">
        <h2 id="h-privacy">\(e(c.privacyH2))</h2>
        <p class="sub">\(e(c.privacyLead))</p>
        <ul class="checks">
        \(privacy)
        </ul>
        <p><a class="link" href="/datenschutz">\(e(c.privacyLink))</a></p>
        </section>
        <section aria-labelledby="h-data" class="source">
        <h2 id="h-data">\(e(c.dataH2))</h2>
        <p>\(e(c.dataText))</p>
        <p class="muted">\(e(c.dataSource))</p>
        <p><a class="link" href="\(dwdURL)" rel="noopener noreferrer">\(e(c.dataLink))</a></p>
        </section>
        </div></section>

        <section class="wrap sec cta" aria-labelledby="h-cta">
        <h2 id="h-cta">\(e(c.ctaH2))</h2>
        <p class="sub">\(e(c.ctaText))</p>
        <p class="actions center">\(storeButton(c, info: info))\(testflight)</p>
        </section>
        </main>
        <footer class="foot"><div class="wrap">
        <nav aria-label="Footer"><a href="/datenschutz">\(e(c.navPrivacy))</a><a href="/support">\(e(c.navSupport))</a><a href="/marketing">\(e(c.footerMore))</a><a href="\(c.switchHref)" hreflang="\(c.switchLang)" lang="\(c.switchLang)">\(other == .de ? "Deutsch" : "English")</a></nav>
        <p>\(e(c.footerSource))</p>
        <p>Showers</p>
        </div></footer>
        </body></html>
        """
    }

    // MARK: CSS

    static let stylesheet = """
    :root{color-scheme:light dark;--bg:#f5f8fc;--bg2:#e3eefb;--fg:#14202b;--muted:#4a5866;--line:#d3dde8;--card:#fff;--accent:#0b5fc4;--onacc:#fff;--tint:#e4effc;--shadow:0 24px 48px -24px rgba(16,40,80,.4);--r:20px}
    @media(prefers-color-scheme:dark){:root{--bg:#0c1218;--bg2:#10202f;--fg:#e8eef4;--muted:#a3b0bd;--line:#273340;--card:#141e28;--accent:#7ab8ff;--onacc:#06121f;--tint:#17293b;--shadow:0 24px 48px -24px rgba(0,0,0,.85)}}
    *{box-sizing:border-box}
    html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
    body{margin:0;color:var(--fg);background:var(--bg) linear-gradient(180deg,var(--bg2),var(--bg) 42rem) no-repeat;font:17px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    img{display:block;max-width:100%;height:auto}
    a{color:var(--accent)}
    a:focus-visible{outline:3px solid var(--accent);outline-offset:3px;border-radius:6px}
    .wrap{max-width:68rem;margin:0 auto;padding:0 1.25rem}
    .skip{position:absolute;left:1rem;top:-4rem;background:var(--accent);color:var(--onacc);padding:.6rem 1rem;border-radius:10px;z-index:9;text-decoration:none}
    .skip:focus{top:1rem}
    .top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 82%,transparent);-webkit-backdrop-filter:saturate(1.4) blur(14px);backdrop-filter:saturate(1.4) blur(14px);border-bottom:1px solid transparent}
    .bar{display:flex;align-items:center;justify-content:space-between;gap:1rem;min-height:3.75rem}
    .brand{display:flex;align-items:center;gap:.6rem;color:var(--fg);font-weight:650;font-size:1.15rem;text-decoration:none;letter-spacing:-.01em}
    .brand img{border-radius:9px}
    .top nav{display:flex;align-items:center;gap:.25rem 1.1rem;font-size:.95rem}
    .top nav a{color:var(--muted);text-decoration:none;padding:.4rem 0}
    .top nav a:hover{color:var(--fg)}
    .top nav .lang{border:1px solid var(--line);border-radius:999px;padding:.15rem .65rem;font-size:.82rem;font-weight:600;color:var(--fg)}
    @media(max-width:34rem){.top nav a:not(.lang):first-child{display:none}.top nav{gap:.25rem .8rem}}
    .hero{display:grid;gap:2.5rem;padding-top:2.5rem;padding-bottom:3rem;align-items:center}
    .eyebrow{margin:0 0 .75rem;color:var(--accent);font-weight:600;font-size:.95rem;letter-spacing:.01em}
    h1{margin:0;font-size:clamp(2.8rem,9.5vw,4.4rem);line-height:1.03;letter-spacing:-.035em;font-weight:760}
    .lead{margin:1.25rem 0 0;font-size:clamp(1.1rem,2.6vw,1.3rem);color:var(--muted);max-width:34rem;line-height:1.5}
    .actions{display:flex;flex-wrap:wrap;align-items:center;gap:.75rem 1.25rem;margin:1.75rem 0 0}
    .actions.center{justify-content:center}
    .btn{display:inline-flex;align-items:center;min-height:3rem;padding:.65rem 1.4rem;border-radius:999px;background:var(--accent);color:var(--onacc);font-weight:620;text-decoration:none}
    .btn.off{background:transparent;color:var(--muted);border:1.5px dashed var(--line);cursor:default}
    .btn.ghost{background:transparent;color:var(--accent);border:1.5px solid var(--accent)}
    .link{font-weight:600;text-decoration:none}
    .link:hover{text-decoration:underline}
    .phones{margin:0;display:grid;grid-template-columns:1fr 1fr;gap:1rem;max-width:34rem;margin-inline:auto;align-items:start}
    .phone{border-radius:9%/4.2%;overflow:hidden;box-shadow:var(--shadow);border:1px solid var(--line);background:var(--card)}
    .phone.second{margin-top:3.2rem}
    .phones figcaption{grid-column:1/-1;text-align:center;color:var(--muted);font-size:.85rem;margin-top:.5rem}
    @media(min-width:56rem){.hero{grid-template-columns:minmax(0,1fr) minmax(0,1.2fr);gap:2rem;padding-top:3.5rem;padding-bottom:5rem}.phones{max-width:none;margin:0;gap:1.5rem}.phone.second{margin-top:5rem}}
    .sec{padding-top:3.5rem;padding-bottom:3.5rem}
    h2{margin:0;font-size:clamp(1.8rem,5vw,2.6rem);line-height:1.15;letter-spacing:-.025em;font-weight:720}
    h3{margin:.9rem 0 .35rem;font-size:1.2rem;letter-spacing:-.01em}
    .sub{margin:.6rem 0 0;color:var(--muted);font-size:1.1rem;max-width:38rem}
    .cards{list-style:none;margin:2rem 0 0;padding:0;display:grid;gap:1rem;grid-template-columns:repeat(auto-fit,minmax(15.5rem,1fr))}
    .card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:1.5rem}
    .card p{margin:0;color:var(--muted);font-size:1rem}
    .ic{display:inline-grid;place-items:center;width:2.9rem;height:2.9rem;border-radius:14px;background:var(--tint);color:var(--accent)}
    .card .tag{display:inline-block;margin-top:.9rem;padding:.2rem .7rem;border-radius:10px;background:var(--tint);color:var(--accent);font-size:.8rem;font-weight:600}
    .band{background:var(--card);border-block:1px solid var(--line)}
    .two{display:grid;gap:2.5rem;padding-top:3.5rem;padding-bottom:3.5rem}
    @media(min-width:56rem){.two{grid-template-columns:1.2fr .8fr;gap:4rem}}
    .checks{list-style:none;margin:1.5rem 0 1rem;padding:0;display:grid;gap:.75rem}
    .checks li{position:relative;padding-left:1.9rem}
    .checks li::before{content:"";position:absolute;left:.2rem;top:.5em;width:.5rem;height:.9rem;border:solid var(--accent);border-width:0 2.5px 2.5px 0;transform:rotate(45deg) translate(-2px,-4px) scale(.8)}
    .source p{margin:.75rem 0 0}
    .muted{color:var(--muted);font-size:.92rem}
    .cta{text-align:center}
    .cta .sub{margin-inline:auto}
    .foot{padding:2rem 0 3rem;color:var(--muted);font-size:.9rem}
    .foot nav{display:flex;flex-wrap:wrap;gap:.4rem 1.4rem;margin-bottom:1rem}
    .foot a{color:var(--fg);text-decoration:none}
    .foot a:hover{text-decoration:underline}
    .foot p{margin:.3rem 0}
    @keyframes rise{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
    .copy>*,.phone{animation:rise .7s cubic-bezier(.2,.7,.2,1) both}
    .copy>:nth-child(2){animation-delay:.05s}.copy>:nth-child(3){animation-delay:.1s}.copy>:nth-child(4){animation-delay:.15s}
    .phone{animation-delay:.2s}.phone.second{animation-delay:.32s}
    @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
    """
}
