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

    private static func image(_ name: String, _ base64: String, ext: String = "webp", type: String = "image/webp") -> Asset {
        Asset(name: name, ext: ext, type: type, body: Array(Data(base64Encoded: base64) ?? Data()))
    }

    static let css = Asset(name: "landing", ext: "css", type: "text/css; charset=utf-8", body: Array(stylesheet.utf8))
    static let icon = image("icon", LandingAssetData.icon)
    static let appleIcon = image("apple-touch-icon", LandingAssetData.appleIcon, ext: "png", type: "image/png")
    static let og = image("og", LandingAssetData.og, ext: "jpg", type: "image/jpeg")
    static let radarLight = image("radar-light", LandingAssetData.radarLight)
    static let radarDark = image("radar-dark", LandingAssetData.radarDark)
    static let radarLightSmall = image("radar-light-320", LandingAssetData.radarLightSmall)
    static let radarDarkSmall = image("radar-dark-320", LandingAssetData.radarDarkSmall)
    static let placesLight = image("places-light", LandingAssetData.placesLight)
    static let placesDark = image("places-dark", LandingAssetData.placesDark)
    static let placesLightSmall = image("places-light-320", LandingAssetData.placesLightSmall)
    static let placesDarkSmall = image("places-dark-320", LandingAssetData.placesDarkSmall)
    static let clouds = image("clouds", LandingAssetData.clouds)
    static let watchList = image("watch-list", LandingAssetData.watchList)
    static let watchForecast = image("watch-forecast", LandingAssetData.watchForecast)
    static let assets: [Asset] = [css, icon, appleIcon, og, radarLight, radarDark, radarLightSmall, radarDarkSmall, placesLight, placesDark,
                                  placesLightSmall, placesDarkSmall, clouds, watchList, watchForecast]
    /// Public origin for the absolute Open Graph image URL (Open Graph requires absolute URLs). Both hostnames serve the same page.
    static let publicOrigin = "https://showers.linolaske.de"

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
        var title, description, skip, navFeatures, navPrivacy, navSupport, switchLabel, switchHref, switchLang, mainNav: String
        var eyebrow, h1, lead, soon, testflight, seeFeatures, caption, alt1, alt2, ogAlt: String
        var chips: [String]
        var featuresH2, featuresLead: String
        // Timeline row
        var radarH, radarText, timelineLabel, timelinePast, timelineNow, timelineFuture: String
        // Clouds row
        var cloudsH, cloudsText, cloudsAlt, cloudsTag: String
        // Places and alerts row
        var alertsH, placesText, alertsText, alertsTag, noteTitle, noteBody, noteLabel: String
        // Widgets and Watch row
        var watchH, watchText, watchTag, watchAlt1, watchAlt2: String
        var privacyH2, privacyLead: String
        var privacy: [String]
        var privacyLink: String
        var dataH2, dataText, dataSource, dataSatellite, dataLink: String
        var ctaH2, ctaText: String
        var footerMore, footerSource, footerNav: String
    }

    static func copy(_ lang: Lang) -> Copy {
        switch lang {
        case .de:
            return Copy(
                title: "Showers \u{2013} Regenradar für Deutschland",
                description: "Showers zeigt das Regenradar des Deutschen Wetterdienstes mit Zeitleiste und Vorhersage, Prognose für deine Orte, Widgets und Apple Watch. Ohne Konto, ohne Werbung.",
                skip: "Zum Inhalt springen", navFeatures: "Funktionen", navPrivacy: "Datenschutz", navSupport: "Support",
                switchLabel: "EN", switchHref: "/en", switchLang: "en", mainNav: "Hauptnavigation",
                eyebrow: "Regenradar für iPhone, iPad und Apple Watch",
                h1: "Regen im Blick.",
                lead: "Showers zeigt dir, wo es regnet und wann es bei dir anfängt oder aufhört. Mit dem Radar des Deutschen Wetterdienstes: ruhig, schnell und ohne Konto.",
                soon: "Bald im App Store", testflight: "Beta über TestFlight testen", seeFeatures: "Funktionen ansehen",
                caption: "Beispielansichten, Radardaten vom 2. November 2026.",
                alt1: "Showers: Radarkarte von Niedersachsen mit Regengebieten, Zeitleiste und Wiedergabe-Taste",
                alt2: "Showers: Liste gespeicherter Orte mit Regenhinweis-Glocke und Regionen",
                ogAlt: "Showers: App-Symbol und Screenshots von Orteliste und Regenradar mit Zeitleiste",
                chips: ["Ohne Konto", "Ohne Werbung", "Keine Standortverläufe"],
                featuresH2: "Gebaut für eine Frage: Wird es nass?",
                featuresLead: "Weniger Wetter-Show, mehr Antwort. Showers konzentriert sich auf Niederschlag.",
                radarH: "Radar mit Zeitleiste",
                radarText: "Die Niederschlagsmessung der letzten Stunden und die Vorhersage bis zu zwei Stunden in Fünf-Minuten-Schritten. Abspielen oder per Zeitleiste zu jedem Zeitpunkt springen.",
                timelineLabel: "Schematische Darstellung der Zeitleiste: links Messung, in der Mitte Jetzt, rechts Vorhersage",
                timelinePast: "Messung", timelineNow: "Jetzt", timelineFuture: "Vorhersage",
                cloudsH: "Wolken als Ebene",
                cloudsText: "Schalte das Satellitenbild als Wolkenebene unter das Radar. So siehst du, was sich zusammenbraut, bevor es auf dem Radar auftaucht.",
                cloudsAlt: "Showers: Karte von Niedersachsen mit Satelliten-Wolkenebene und Zeitleiste",
                cloudsTag: "Ebene zuschaltbar",
                alertsH: "Deine Orte und Regenhinweise",
                placesText: "Speichere Orte oder nutze optional deinen Standort. Showers zeigt Beginn, Ende und Intensität des Regens, aber nur, soweit die Daten es hergeben.",
                alertsText: "Lass dich für einen Ort oder eine Region (5, 10 oder 25 km Umkreis) per Mitteilung auf Regen hinweisen. Das setzt den Showers-Radar-Dienst und deine Erlaubnis für Mitteilungen voraus.",
                alertsTag: "Optional \u{B7} braucht den Radar-Dienst",
                noteTitle: "Showers", noteBody: "Regen beginnt in 12 min", noteLabel: "Beispiel für einen Regenhinweis, nicht live",
                watchH: "Widgets und Apple Watch",
                watchText: "Widgets für deine Orte und eine Watch-App mit Ortsliste, Ortsprognose und Radarkarte (Vorschau). Eine Live Activity für den Sperrbildschirm und die Dynamic Island ist vorbereitet und braucht den Radar-Dienst.",
                watchTag: "In Erprobung",
                watchAlt1: "Showers auf der Apple Watch: Ortsliste", watchAlt2: "Showers auf der Apple Watch: Prognose für Hannover, vorerst kein messbarer Regen erwartet",
                privacyH2: "Datensparsam, mit Absicht",
                privacyLead: "Datenschutz ist hier eine Produktanforderung, kein Nachsatz.",
                privacy: [
                    "Kein Benutzerkonto, keine Werbung, kein Tracking, keine Analyse-SDKs.",
                    "Der Radar-Dienst selbst führt keine Zugriffsprotokolle. Radar-Anfragen enthalten keinen Ort und keine Kennung.",
                    "Gespeicherte Orte und eigene Namen bleiben auf deinem Gerät. Keine Hintergrundortung, keine Standortverläufe.",
                    "Der Standort ist optional und wird erst bei Nutzung angefragt. Für Regionen erhält der Server nur einen groben Bereich.",
                    "Karte und Ortssuche nutzen Apple Karten; dabei sieht Apple die Anfrage.",
                    "Betriebsstatistik nur aggregiert und ohne Personenbezug. Die Geräte-Diagnose für den Betreiber ist freiwillig, standardmäßig aus und nur nach Freigabe des Betreibers möglich.",
                ],
                privacyLink: "Datenschutzerklärung lesen",
                dataH2: "Daten vom Deutschen Wetterdienst",
                dataText: "Radar und Prognose stammen vom Deutschen Wetterdienst (DWD). Showers ist eine eigenständige App und kein Angebot des DWD.",
                dataSource: "Quelle: Deutscher Wetterdienst. Die Radarbilder sind aus Rasterdaten des DWD bildlich wiedergegeben und aufbereitet (verändert). Temperatur- und Feuchtekarten: DWD ICON-D2/ICON-EU Modelldaten (CC BY 4.0, Quelle: Deutscher Wetterdienst). Optionale Waldfläche: © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium (CC BY 4.0).",
                dataSatellite: "Wolkenebene: Contains modified EUMETSAT Meteosat data.",
                dataLink: "Zum Deutschen Wetterdienst",
                ctaH2: "Showers kommt in den App Store",
                ctaText: "Bis dahin läuft eine frühe Beta-Erprobung über TestFlight.",
                footerMore: "Mehr über Showers",
                footerSource: "Quelle: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben, aufbereitet. Wolken: Contains modified EUMETSAT Meteosat data.",
                footerNav: "Fußbereich")
        case .en:
            return Copy(
                title: "Showers \u{2013} Rain radar for Germany",
                description: "Showers shows the rain radar of the German Weather Service with timeline and forecast, forecasts for your places, widgets and Apple Watch. No account, no ads.",
                skip: "Skip to content", navFeatures: "Features", navPrivacy: "Privacy", navSupport: "Support",
                switchLabel: "DE", switchHref: "/", switchLang: "de", mainNav: "Main",
                eyebrow: "Rain radar for iPhone, iPad and Apple Watch",
                h1: "Rain at a glance.",
                lead: "Showers shows you where it rains and when it starts or stops where you are. Powered by the radar of the German Weather Service (DWD): calm, fast and without an account.",
                soon: "Coming soon to the App Store", testflight: "Try the beta on TestFlight", seeFeatures: "See features",
                caption: "Sample views, radar data from 2 November 2026. The screenshots show the German interface.",
                alt1: "Showers: radar map of Lower Saxony with rain areas, timeline and play button",
                alt2: "Showers: list of saved places with rain alert bell and regions",
                ogAlt: "Showers: app icon and screenshots of the place list and the rain radar with timeline",
                chips: ["No account", "No ads", "No location history"],
                featuresH2: "Built around one question: will it get wet?",
                featuresLead: "Less weather show, more answers. Showers focuses on precipitation.",
                radarH: "Radar with timeline",
                radarText: "Measured precipitation of the last hours and a forecast of up to two hours in five-minute steps. Play it back or jump to any point on the timeline.",
                timelineLabel: "Schematic of the timeline: measurement on the left, now in the middle, forecast on the right",
                timelinePast: "Measured", timelineNow: "Now", timelineFuture: "Forecast",
                cloudsH: "Clouds as a layer",
                cloudsText: "Switch on the satellite image as a cloud layer beneath the radar. See what is brewing before it shows up on the radar.",
                cloudsAlt: "Showers: map of Lower Saxony with a satellite cloud layer and timeline",
                cloudsTag: "Switchable layer",
                alertsH: "Your places and rain alerts",
                placesText: "Save places or optionally use your location. Showers shows when rain starts and ends and how intense it is, but only as far as the data supports.",
                alertsText: "Get a notification about rain for a place or a region (5, 10 or 25 km radius). This requires the Showers radar service and your permission for notifications.",
                alertsTag: "Optional \u{B7} needs the radar service",
                noteTitle: "Showers", noteBody: "Rain starts in 12 min", noteLabel: "Example of a rain alert, not live",
                watchH: "Widgets and Apple Watch",
                watchText: "Widgets for your places and a Watch app with a place list, place forecast and a radar map (preview). A Live Activity for the Lock Screen and the Dynamic Island is prepared and needs the radar service.",
                watchTag: "In testing",
                watchAlt1: "Showers on Apple Watch: place list", watchAlt2: "Showers on Apple Watch: forecast for Hannover, no measurable rain expected for now",
                privacyH2: "Data-sparing by design",
                privacyLead: "Privacy is a product requirement here, not an afterthought.",
                privacy: [
                    "No user account, no ads, no tracking, no analytics SDKs.",
                    "The radar service itself keeps no access logs. Radar requests contain no location and no identifier.",
                    "Saved places and custom names stay on your device. No background location, no location history.",
                    "Location is optional and requested only when you use it. For regions the server receives only a coarse area.",
                    "The map and place search use Apple Maps; Apple sees those requests.",
                    "Operating statistics are aggregated and anonymous. Operator diagnostics are voluntary, off by default and only possible after approval by the operator.",
                ],
                privacyLink: "Read the privacy policy (German)",
                dataH2: "Data from the German Weather Service",
                dataText: "Radar and forecast come from the German Weather Service (Deutscher Wetterdienst, DWD). Showers is an independent app and not an offering of the DWD.",
                dataSource: "Source: Deutscher Wetterdienst. The radar images are rendered from DWD grid data and processed (modified). Temperature and humidity maps: DWD ICON-D2/ICON-EU model data (CC BY 4.0, source: Deutscher Wetterdienst). Optional forest layer: © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium (CC BY 4.0).",
                dataSatellite: "Cloud layer: Contains modified EUMETSAT Meteosat data.",
                dataLink: "Visit the German Weather Service",
                ctaH2: "Showers is coming to the App Store",
                ctaText: "Until then, an early beta runs on TestFlight.",
                footerMore: "About Showers",
                footerSource: "Source: Deutscher Wetterdienst, grid data rendered as images, processed. Clouds: Contains modified EUMETSAT Meteosat data.",
                footerNav: "Footer")
        }
    }

    // MARK: HTML

    /// Light/dark screenshot pair as `<picture>`; `small` (320 px) variants feed `srcset` for narrow screens.
    private static func picture(_ light: Asset, _ dark: Asset, small: (Asset, Asset), w: Int, h: Int, alt: String, priority: Bool) -> String {
        let sizes = "(min-width: 56rem) 17rem, 42vw"
        return """
        <picture><source media="(prefers-color-scheme: dark)" srcset="\(small.1.path) 320w, \(dark.path) 640w" sizes="\(sizes)"><img src="\(light.path)" srcset="\(small.0.path) 320w, \(light.path) 640w" sizes="\(sizes)" width="\(w)" height="\(h)" alt="\(SitePages.escape(alt))"\(priority ? " fetchpriority=\"high\"" : " loading=\"lazy\"") decoding="async"></picture>
        """
    }

    private static func img(_ a: Asset, w: Int, h: Int, alt: String) -> String {
        "<img src=\"\(a.path)\" width=\"\(w)\" height=\"\(h)\" alt=\"\(SitePages.escape(alt))\" loading=\"lazy\" decoding=\"async\">"
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
        let selfPath = lang == .de ? "/" : "/en"
        let testflight = link(info.testflightURL, class: "btn ghost", c.testflight) ?? ""
        let chips = c.chips.map { "<li>\(e($0))</li>" }.joined(separator: "")
        let privacy = c.privacy.map { "<li>\(e($0))</li>" }.joined(separator: "\n")
        let tag = { (t: String) in "<p class=\"tag\">\(e(t))</p>" }
        return """
        <!DOCTYPE html>
        <html lang="\(lang.code)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="theme-color" content="#f5f8fc" media="(prefers-color-scheme: light)">
        <meta name="theme-color" content="#0c1218" media="(prefers-color-scheme: dark)">
        <title>\(e(c.title))</title>
        <meta name="description" content="\(e(c.description))">
        <link rel="canonical" href="\(selfPath)">
        <link rel="alternate" hreflang="de" href="/">
        <link rel="alternate" hreflang="en" href="/en">
        <link rel="alternate" hreflang="x-default" href="/">
        <meta property="og:type" content="website">
        <meta property="og:site_name" content="Showers">
        <meta property="og:title" content="\(e(c.title))">
        <meta property="og:description" content="\(e(c.description))">
        <meta property="og:locale" content="\(lang == .de ? "de_DE" : "en_GB")">
        <meta property="og:image" content="\(publicOrigin)\(og.path)">
        <meta property="og:image:width" content="1200">
        <meta property="og:image:height" content="630">
        <meta property="og:image:alt" content="\(e(c.ogAlt))">
        <meta name="twitter:card" content="summary_large_image">
        <link rel="icon" type="image/webp" href="\(icon.path)">
        <link rel="apple-touch-icon" href="\(appleIcon.path)">
        <link rel="stylesheet" href="\(css.path)">
        </head><body>
        <a class="skip" href="#main">\(e(c.skip))</a>
        <header class="top"><div class="wrap bar">
        <a class="brand" href="\(selfPath)"><img src="\(icon.path)" width="36" height="36" alt="" decoding="async"><span>Showers</span></a>
        <nav aria-label="\(e(c.mainNav))"><a href="#features">\(e(c.navFeatures))</a><a href="/datenschutz">\(e(c.navPrivacy))</a><a href="/support">\(e(c.navSupport))</a><a class="lang" href="\(c.switchHref)" hreflang="\(c.switchLang)" lang="\(c.switchLang)" aria-label="\(c.switchLabel) \(other == .de ? "Deutsch" : "English")">\(c.switchLabel)</a></nav>
        </div></header>
        <main id="main">
        <section class="hero wrap" aria-labelledby="h-hero">
        <div class="copy">
        <p class="eyebrow">\(e(c.eyebrow))</p>
        <h1 id="h-hero">\(e(c.h1))</h1>
        <p class="lead">\(e(c.lead))</p>
        <p class="actions">\(storeButton(c, info: info))\(testflight)<a class="link" href="#features">\(e(c.seeFeatures))</a></p>
        <ul class="chips">\(chips)</ul>
        </div>
        <figure class="stage">
        <div class="radar" aria-hidden="true"></div>
        <div class="phones">
        <div class="phone">\(picture(radarLight, radarDark, small: (radarLightSmall, radarDarkSmall), w: 640, h: 1097, alt: c.alt1, priority: true))</div>
        <div class="phone second">\(picture(placesLight, placesDark, small: (placesLightSmall, placesDarkSmall), w: 640, h: 1391, alt: c.alt2, priority: true))</div>
        </div>
        <figcaption>\(e(c.caption))</figcaption>
        </figure>
        </section>

        <section id="features" class="wrap sec" aria-labelledby="h-features">
        <h2 id="h-features">\(e(c.featuresH2))</h2>
        <p class="sub">\(e(c.featuresLead))</p>

        <article class="row">
        <div class="txt"><h3>\(e(c.radarH))</h3><p>\(e(c.radarText))</p></div>
        <figure class="media"><div class="tl" role="img" aria-label="\(e(c.timelineLabel))"><span class="play"></span><div class="track"><span class="past"></span><span class="future"></span><span class="thumb"></span></div>
        <div class="ticks" aria-hidden="true"><span>\(e(c.timelinePast))</span><span>\(e(c.timelineNow))</span><span>\(e(c.timelineFuture))</span></div></div></figure>
        </article>

        <article class="row flip">
        <div class="txt"><h3>\(e(c.cloudsH))</h3><p>\(e(c.cloudsText))</p>\(tag(c.cloudsTag))</div>
        <figure class="media"><div class="phone">\(img(clouds, w: 640, h: 1097, alt: c.cloudsAlt))</div></figure>
        </article>

        <article class="row">
        <div class="txt"><h3>\(e(c.alertsH))</h3><p>\(e(c.placesText))</p><p>\(e(c.alertsText))</p>\(tag(c.alertsTag))</div>
        <figure class="media"><div class="note" role="img" aria-label="\(e(c.noteLabel))"><img src="\(icon.path)" width="40" height="40" alt="" loading="lazy" decoding="async"><div><p class="nt"><b>\(e(c.noteTitle))</b><span aria-hidden="true">\(lang == .de ? "jetzt" : "now")</span></p><p class="nb">\(e(c.noteBody))</p></div></div>
        <figcaption>\(e(c.noteLabel))</figcaption></figure>
        </article>

        <article class="row flip">
        <div class="txt"><h3>\(e(c.watchH))</h3><p>\(e(c.watchText))</p>\(tag(c.watchTag))</div>
        <figure class="media watches"><div class="watch">\(img(watchList, w: 422, h: 514, alt: c.watchAlt1))</div><div class="watch">\(img(watchForecast, w: 422, h: 514, alt: c.watchAlt2))</div></figure>
        </article>
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
        <p class="muted">\(e(c.dataSatellite))</p>
        <p><a class="link" href="\(dwdURL)" rel="noopener noreferrer">\(e(c.dataLink))</a></p>
        </section>
        </div></section>

        <section class="wrap sec cta" aria-labelledby="h-cta">
        <img class="appicon" src="\(icon.path)" width="96" height="96" alt="" loading="lazy" decoding="async">
        <h2 id="h-cta">\(e(c.ctaH2))</h2>
        <p class="sub">\(e(c.ctaText))</p>
        <p class="actions center">\(storeButton(c, info: info))\(testflight)</p>
        </section>
        </main>
        <footer class="foot"><div class="wrap">
        <nav aria-label="\(e(c.footerNav))"><a href="/datenschutz">\(e(c.navPrivacy))</a><a href="/support">\(e(c.navSupport))</a><a href="/impressum">Impressum</a><a href="/marketing">\(e(c.footerMore))</a><a href="\(c.switchHref)" hreflang="\(c.switchLang)" lang="\(c.switchLang)">\(other == .de ? "Deutsch" : "English")</a></nav>
        <p>\(e(c.footerSource))</p>
        <p>Showers</p>
        </div></footer>
        </body></html>
        """
    }

    // MARK: CSS

    static let stylesheet = """
    :root{color-scheme:light dark;--bg:#f5f8fc;--bg2:#e3eefb;--fg:#14202b;--muted:#4a5866;--line:#d3dde8;--card:#fff;--accent:#0b5fc4;--onacc:#fff;--tint:#e4effc;--ring:#1c9a66;--bezel:#18222d;--shadow:0 28px 50px -26px rgba(16,40,80,.5);--r:20px}
    @media(prefers-color-scheme:dark){:root{--bg:#0c1218;--bg2:#10202f;--fg:#e8eef4;--muted:#a3b0bd;--line:#273340;--card:#141e28;--accent:#7ab8ff;--onacc:#06121f;--tint:#17293b;--ring:#3ccf91;--bezel:#2b3744;--shadow:0 28px 50px -26px rgba(0,0,0,.9)}}
    *{box-sizing:border-box}
    html{scroll-behavior:smooth;-webkit-text-size-adjust:100%;scroll-padding-top:4.5rem}
    body{margin:0;overflow-x:clip;color:var(--fg);background:var(--bg) linear-gradient(180deg,var(--bg2),var(--bg) 42rem) no-repeat;font:17px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    img{display:block;max-width:100%;height:auto}
    a{color:var(--accent)}
    a:focus-visible{outline:3px solid var(--accent);outline-offset:3px;border-radius:6px}
    .wrap{max-width:70rem;margin:0 auto;padding:0 1.25rem}
    .skip{position:absolute;left:1rem;top:-4rem;background:var(--accent);color:var(--onacc);padding:.6rem 1rem;border-radius:10px;z-index:9;text-decoration:none}
    .skip:focus{top:1rem}
    .top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 82%,transparent);-webkit-backdrop-filter:saturate(1.4) blur(14px);backdrop-filter:saturate(1.4) blur(14px)}
    .bar{display:flex;align-items:center;justify-content:space-between;gap:1rem;min-height:3.75rem}
    .brand{display:flex;align-items:center;gap:.6rem;color:var(--fg);font-weight:650;font-size:1.15rem;text-decoration:none;letter-spacing:-.01em}
    .brand img{border-radius:9px}
    .top nav{display:flex;align-items:center;gap:.25rem 1.1rem;font-size:.95rem}
    .top nav a{color:var(--muted);text-decoration:none;padding:.4rem 0}
    .top nav a:hover{color:var(--fg)}
    .top nav .lang{border:1px solid var(--line);border-radius:999px;padding:.15rem .65rem;font-size:.82rem;font-weight:600;color:var(--fg)}
    @media(max-width:34rem){.top nav a:nth-child(-n+2){display:none}.top nav{gap:.25rem .8rem}}
    .hero{overflow:clip;display:grid;gap:2rem;padding-top:2rem;padding-bottom:3rem;align-items:center}
    .eyebrow{margin:0 0 .75rem;color:var(--accent);font-weight:600;font-size:.95rem;letter-spacing:.01em}
    h1{margin:0;font-size:clamp(2.9rem,10vw,5rem);line-height:1.02;letter-spacing:-.04em;font-weight:780;text-wrap:balance}
    .lead{margin:1.25rem 0 0;font-size:clamp(1.1rem,2.6vw,1.3rem);color:var(--muted);max-width:34rem;line-height:1.5}
    .actions{display:flex;flex-wrap:wrap;align-items:center;gap:.75rem 1.25rem;margin:1.75rem 0 0}
    .actions.center{justify-content:center}
    .btn{display:inline-flex;align-items:center;min-height:3rem;padding:.65rem 1.4rem;border-radius:999px;background:var(--accent);color:var(--onacc);font-weight:620;text-decoration:none}
    .btn.off{background:transparent;color:var(--muted);border:1.5px dashed var(--line);cursor:default}
    .btn.ghost{background:transparent;color:var(--accent);border:1.5px solid var(--accent)}
    .link{font-weight:600;text-decoration:none}
    .link:hover{text-decoration:underline}
    .chips{list-style:none;display:flex;flex-wrap:wrap;gap:.5rem;margin:1.75rem 0 0;padding:0}
    .chips li{padding:.25rem .8rem;border:1px solid var(--line);border-radius:999px;background:var(--card);font-size:.9rem;color:var(--muted);font-weight:560}
    .stage{position:relative;isolation:isolate;margin:0;max-width:34rem;margin-inline:auto;width:100%}
    .radar{position:absolute;z-index:-1;inset:-6% -14%;border-radius:50%;background:repeating-radial-gradient(circle,transparent 0 3.6rem,color-mix(in srgb,var(--ring) 22%,transparent) 3.6rem calc(3.6rem + 1px));-webkit-mask-image:radial-gradient(circle,#000 30%,transparent 70%);mask-image:radial-gradient(circle,#000 30%,transparent 70%)}
    .radar::after{content:"";position:absolute;inset:0;border-radius:50%;background:conic-gradient(from 0deg,transparent 0 78%,color-mix(in srgb,var(--ring) 38%,transparent) 100%);animation:sweep 9s linear infinite}
    .phones{display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:start}
    .phone{aspect-ratio:.52;overflow:hidden;border:6px solid var(--bezel);border-radius:2rem;background:#000;box-shadow:var(--shadow)}
    .phone img{width:100%;height:100%;object-fit:cover;object-position:top}
    .phone.second{margin-top:3rem}
    .stage figcaption{text-align:center;color:var(--muted);font-size:.85rem;margin-top:1rem}
    @media(min-width:56rem){.hero{grid-template-columns:minmax(0,.9fr) minmax(0,1.1fr);gap:2rem;padding-top:3rem;padding-bottom:5rem}.stage{margin:0;max-width:none}.phones{gap:1.5rem}.phone.second{margin-top:5rem}}
    .sec{padding-top:3.5rem;padding-bottom:3.5rem}
    h2{margin:0;font-size:clamp(1.8rem,5vw,2.7rem);line-height:1.12;letter-spacing:-.03em;font-weight:740;text-wrap:balance}
    h3{margin:0 0 .5rem;font-size:clamp(1.4rem,3.4vw,1.8rem);line-height:1.2;letter-spacing:-.02em;text-wrap:balance}
    .sub{margin:.6rem 0 0;color:var(--muted);font-size:1.1rem;max-width:38rem}
    .row{display:grid;gap:1.75rem;align-items:center;margin-top:3.5rem;padding:1.5rem;border:1px solid var(--line);border-radius:28px;background:var(--card)}
    .row>*{min-width:0}
    .txt p{margin:.6rem 0 0;color:var(--muted);max-width:32rem}
    .media{margin:0;display:flex;flex-direction:column;align-items:center;gap:.75rem}
    .media figcaption{color:var(--muted);font-size:.85rem;text-align:center}
    .media .phone{width:min(15rem,100%)}
    @media(min-width:48rem){.row{grid-template-columns:1fr 1fr;gap:3rem;padding:2.5rem}.row.flip .media{order:-1}}
    .tag{display:inline-block;margin:1rem 0 0;padding:.2rem .7rem;border-radius:10px;background:var(--tint);color:var(--accent);font-size:.8rem;font-weight:600}
    .tl{display:flex;align-items:center;gap:.9rem;flex-wrap:wrap;width:100%;max-width:26rem;padding:1.1rem 1.2rem;border-radius:22px;background:var(--bg2);border:1px solid var(--line)}
    .play{flex:none;width:2.4rem;height:2.4rem;border-radius:50%;background:var(--accent);position:relative}
    .play::after{content:"";position:absolute;left:55%;top:50%;transform:translate(-50%,-50%);border:.5rem solid transparent;border-left:.8rem solid var(--onacc);border-right:0}
    .track{position:relative;flex:1;min-width:8rem;height:.7rem;display:flex;border-radius:99px;background:var(--line)}
    .past{flex:5;border-radius:99px 0 0 99px;background:linear-gradient(90deg,var(--ring),var(--accent))}
    .future{flex:3;border-radius:0 99px 99px 0;background:repeating-linear-gradient(90deg,color-mix(in srgb,var(--accent) 45%,transparent) 0 6px,transparent 6px 12px)}
    .thumb{position:absolute;top:50%;left:62.5%;width:1.5rem;height:1.5rem;margin:-.75rem 0 0 -.75rem;border-radius:50%;background:var(--card);border:3px solid var(--accent);box-shadow:0 2px 8px rgba(0,0,0,.25);animation:scrub 7s ease-in-out infinite alternate}
    .ticks{display:flex;justify-content:space-between;width:100%;font-size:.8rem;font-weight:600;color:var(--muted);padding-left:3.3rem}
    .note{display:flex;gap:.8rem;align-items:center;width:100%;max-width:24rem;padding:.9rem 1rem;border-radius:22px;background:var(--bg2);border:1px solid var(--line);box-shadow:var(--shadow)}
    .note img{flex:none;border-radius:10px}
    .note p{margin:0}
    .note .nt{display:flex;justify-content:space-between;gap:1rem;font-size:.85rem;color:var(--muted)}
    .note .nt b{color:var(--fg)}
    .note .nb{font-weight:620;font-size:1.05rem}
    .watches{flex-direction:row;justify-content:center;gap:1rem;flex-wrap:wrap}
    .watch{width:min(10.5rem,44%);aspect-ratio:422/514;overflow:hidden;border:5px solid var(--bezel);border-radius:2.1rem;background:#000;box-shadow:var(--shadow)}
    .band{background:var(--card);border-block:1px solid var(--line)}
    .two{display:grid;gap:2.5rem;padding-top:3.5rem;padding-bottom:3.5rem}
    @media(min-width:56rem){.two{grid-template-columns:1.2fr .8fr;gap:4rem}}
    .checks{list-style:none;margin:1.5rem 0 1rem;padding:0;display:grid;gap:.75rem}
    .checks li{position:relative;padding-left:1.9rem}
    .checks li::before{content:"";position:absolute;left:.2rem;top:.5em;width:.5rem;height:.9rem;border:solid var(--ring);border-width:0 2.5px 2.5px 0;transform:rotate(45deg) translate(-2px,-4px) scale(.8)}
    .source p{margin:.75rem 0 0}
    .muted{color:var(--muted);font-size:.92rem}
    .cta{text-align:center;padding-top:4.5rem;padding-bottom:4.5rem}
    .cta .appicon{margin:0 auto 1.25rem;border-radius:22px;box-shadow:var(--shadow)}
    .cta .sub{margin-inline:auto}
    .foot{padding:2rem 0 3rem;color:var(--muted);font-size:.9rem}
    .foot nav{display:flex;flex-wrap:wrap;gap:.4rem 1.4rem;margin-bottom:1rem}
    .foot a{color:var(--fg);text-decoration:none}
    .foot a:hover{text-decoration:underline}
    .foot p{margin:.3rem 0}
    @keyframes rise{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
    @keyframes sweep{to{transform:rotate(360deg)}}
    @keyframes scrub{from{left:12%}to{left:62.5%}}
    .copy>*,.phone{animation:rise .7s cubic-bezier(.2,.7,.2,1) both}
    .copy>:nth-child(2){animation-delay:.05s}.copy>:nth-child(3){animation-delay:.1s}.copy>:nth-child(4){animation-delay:.15s}
    .phones .phone{animation-delay:.2s}.phones .phone.second{animation-delay:.32s}
    @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
    """
}
