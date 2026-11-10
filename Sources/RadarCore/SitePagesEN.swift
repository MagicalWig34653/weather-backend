import Foundation

// English public pages (`/en/support`, `/en/imprint`, `/en/marketing`). They are served only when `SITE_EN_ENABLED=true`
// (`SiteInfo.englishEnabled`, default off, then 404). There is no English privacy page: the app is offered in Germany only,
// and the English pages link to the German privacy policy. No operator data is hardcoded: name, address and e-mail come
// from the environment.

extension SitePages {
    static let missingNoticeEN = "The controller details are not configured yet."

    public static func marketingEN(_ info: SiteInfo) -> String {
        var status = "<p>Showers is in an early beta and is being tested through TestFlight.</p>"
        var links: [String] = []
        if let l = safeLink(info.appStoreURL, label: "Showers on the App Store") { links.append(l) }
        if let l = safeLink(info.testflightURL, label: "Try Showers through TestFlight") { links.append(l) }
        if !links.isEmpty { status += "<p>" + links.joined(separator: "<br>") + "</p>" }

        let body = """
        <h1>Showers</h1>
        <p>Showers shows you when and where it rains in Germany. A native rain radar for iPhone, iPad and Apple Watch, based on data from the Deutscher Wetterdienst (DWD).</p>

        <h2>Features</h2>
        <div class="card"><ul>
        <li><strong>Rain radar:</strong> scrub through the recent past and the short-term development of rain. The app shows when the data was last updated and whether you are looking at a measurement or a forecast.</li>
        <li><strong>Temperature and humidity maps:</strong> temperature, dew point and, where available, relative humidity. These layers are model values from the DWD and are labelled as such.</li>
        <li><strong>Warnings from the DWD:</strong> the Warnings page lists warnings issued by the DWD for storms, frost and ice, grouped by your saved places, each with its source and the time of the data. Showers is not an official warning app and does not replace official channels. In an emergency, follow official instructions.</li>
        <li><strong>Your places and regions:</strong> save places and regions and see a short-term rain forecast for each one. Saved places and their names stay on your device.</li>
        <li><strong>Optional rain alerts:</strong> a notification when rain is about to start at one of your places. Voluntary and can be revoked in the app at any time.</li>
        <li><strong>Widgets, Live Activity and Apple Watch.</strong></li>
        <li><strong>Designed for privacy:</strong> no user account, no advertising, no tracking, no analytics SDKs.</li>
        </ul></div>

        <h2>Status</h2>
        \(status)

        <h2>Learn more</h2>
        <ul>
        <li><a href="\(appDocsURL)" rel="noopener noreferrer">App documentation</a> (German)</li>
        <li><a href="\(backendDocsURL)" rel="noopener noreferrer">Radar service documentation</a> (German)</li>
        <li><a href="/datenschutz" hreflang="de" lang="de">Privacy Policy (German)</a></li>
        <li><a href="/en/support">Support</a></li>
        <li><a href="/en/imprint">Legal Notice</a></li>
        </ul>

        <h2>Source</h2>
        <p>Source: Deutscher Wetterdienst. The radar images are graphical renderings prepared from DWD raster data (modified).</p>
        <p>Temperature and humidity maps: DWD ICON-D2/ICON-EU model data (CC BY 4.0, source: Deutscher Wetterdienst), modified.</p>
        <p>Showers is an independent app and is not affiliated with the Deutscher Wetterdienst.</p>
        """
        return page(title: "Showers", description: "Showers: native rain radar for iPhone, iPad and Apple Watch, with DWD data.", body: body, lang: .en, alternate: "/marketing")
    }

    public static func supportEN(_ info: SiteInfo) -> String {
        let contact = info.operatorEmail.isEmpty
            ? "<p class=\"warn\">The contact address is not configured yet.</p>"
            : "<p>Contact by e-mail: \(mailLink(info.operatorEmail))</p>"
        let body = """
        <h1>Support</h1>
        <p>Questions, bugs or wishes about Showers?</p>
        \(contact)
        <p>You can also report bugs and ideas on <a href="\(issuesURL)" rel="noopener noreferrer">GitHub</a>. Please do not post personal data or exact locations there.</p>
        <p><a href="/datenschutz" hreflang="de" lang="de">Privacy Policy (German)</a> · <a href="/en/imprint">Legal Notice</a></p>
        """
        return page(title: "Support", description: "Support for the Showers app.", body: body, lang: .en, alternate: "/support")
    }

    public static func imprintEN(_ info: SiteInfo) -> String {
        var provider = ""
        if info.missingRequired { provider += "<p class=\"warn\">\(escape(missingNoticeEN))</p>" }
        var lines: [String] = []
        if !info.operatorName.isEmpty { lines.append("<strong>\(multiline(info.operatorName))</strong>") }
        if !info.operatorAddress.isEmpty { lines.append(multiline(info.operatorAddress)) }
        if !lines.isEmpty { provider += "<p>" + lines.joined(separator: "<br>") + "</p>" }
        let contact = info.operatorEmail.isEmpty ? "" : "<p>E-mail: \(mailLink(info.operatorEmail))</p>"

        let body = """
        <h1>Legal Notice</h1>
        <p class="muted">Information pursuant to Section 5 of the German Digital Services Act (DDG) for the Showers app and the associated radar service.</p>

        <h2>Provider</h2>
        \(provider)

        <h2>Contact</h2>
        \(contact)
        <p>Other ways to get in touch: <a href="/en/support">Support</a>.</p>

        <h2>Privacy</h2>
        <p>Information on the processing of personal data is in the <a href="/datenschutz" hreflang="de" lang="de">Privacy Policy</a> (German).</p>

        <h2>Sources and data origin</h2>
        <p>Source: Deutscher Wetterdienst. The radar and weather data come from the German Weather Service (DWD) and are graphical renderings prepared from raster data (modified).</p>
        <p>Temperature, dew point and humidity maps: DWD ICON-D2/ICON-EU model data (CC BY 4.0, source: Deutscher Wetterdienst); raster data graphically rendered and processed (modified). These are model forecasts, not measurements.</p>
        <p>Optional forest layer in the map: \u{00A9} ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium (CC BY 4.0); averaged to about 550 m, rounded to 4 levels and coloured separately (modified).</p>
        <p>For cloud and satellite maps: Contains modified EUMETSAT Meteosat data. The EUMETSAT data is licensed under CC BY 4.0 and has been modified.</p>
        <p>Showers is an independent offering and is not affiliated with the DWD or EUMETSAT. The information in the app is guidance and no substitute for official warnings and weather reports.</p>
        """
        return page(title: "Legal Notice", description: "Legal notice of the Showers app and the radar service.", body: body, lang: .en, alternate: "/impressum")
    }
}
