import Foundation

// DRAFT: English public pages (`/en/privacy`, `/en/support`, `/en/imprint`, `/en/marketing`).
// They are served only when `SITE_EN_ENABLED=true` (`SiteInfo.englishEnabled`, default off, then 404).
// The privacy text is Part A-EN of the app repo's `docs/datenschutz-entwurf-release.md` (7 Nov 2026) and is NOT released
// by the operator; open items stay visible as `.draft` spans in square brackets. Do not switch the flag on before the
// operator has approved the text. No operator data is hardcoded: name, address and e-mail come from the environment.

extension SitePages {
    static let missingNoticeEN = "The controller details are not configured yet."

    /// Controller block of the privacy page: configured values only; a visible notice when something is missing.
    static func controllerBlockEN(_ info: SiteInfo) -> String {
        var out = ""
        if info.missingRequired { out += "<p class=\"warn\">\(escape(missingNoticeEN))</p>" }
        var lines: [String] = []
        if !info.operatorName.isEmpty { lines.append("<strong>\(multiline(info.operatorName))</strong>") }
        if !info.operatorAddress.isEmpty { lines.append(multiline(info.operatorAddress)) }
        if !info.operatorEmail.isEmpty { lines.append("E-mail: \(mailLink(info.operatorEmail))") }
        if !lines.isEmpty { out += "<p>" + lines.joined(separator: "<br>") + "</p>" }
        return out
    }

    /// DRAFT, not released. Text: Part A-EN of the privacy draft (verbatim, without the editorial markers [R1] to [R9]).
    public static func privacyEN(_ info: SiteInfo) -> String {
        let controller = controllerBlockEN(info)
        let body = """
        <h1>Privacy Policy</h1>
        <p>For the Showers app (iPhone, iPad, Apple Watch) and the associated radar service. As of: <span class="draft">[date of go-live]</span>.</p>
        <h2>1. Controller</h2>
        \(controller)
        <h2>2. Overview</h2>
        <ul>
        <li>No user account, no advertising, no tracking, no analytics SDKs.</li>
        <li>If you only use the app to view radar and forecasts, the radar service creates no personal identifier: radar requests contain no location, no cookies and no identifier. Technically, the reverse proxy in front of the service sees the IP address and logs it for a limited time (section 3).</li>
        <li>Only if you turn on rain alerts does the app register your device with the radar service, using a random installation ID, the device token for notifications and the chosen location or area, rounded to a coarser grid (section 5). This is voluntary and can be revoked in the app at any time.</li>
        <li>Saved places with their names and your settings stay on your device. The place name in a notification is added on the device (section 5).</li>
        <li>Operational statistics only as aggregated counters that contain no personal data; device diagnostics only voluntarily and only after approval by the operator (sections 10 and 11). Only for a device paired in this way does the operator see its rain alerts with the position rounded to about 1 km; without pairing, the operator sees no individual devices or places.</li>
        <li>The server is hosted by Hetzner in Germany (section 15).</li>
        </ul>
        <h2>3. Radar map and radar service</h2>
        <p>The app loads the radar images for all of Germany from the Showers radar service. Requests contain no location: there are fixed paths per radar run and time step (full image for Germany), no cookies and no identifier.</p>
        <p>The radar service itself keeps no access logs and stores no IP addresses or request details. Its technical logs contain only run identifiers and error classes. This also applies to the push interface of the service. Rate limiting works without an IP address as well (per installation ID or overall).</p>
        <p>A reverse proxy (TLS, forwarding) sits in front of the radar service. It technically sees the IP address of every request and logs accesses including the IP address. The purposes are operation, troubleshooting and abuse prevention; the legal basis is our legitimate interest (Art. 6(1)(f) GDPR). Log files rotate by size (at most 64 MB per file, 16 files) and are overwritten afterwards. Depending on traffic, entries are therefore kept for up to roughly 14 months. <span class="draft">[Draft note: shortening the period at the proxy to 14 to 30 days is recommended; then adjust this paragraph and the German version.]</span></p>
        <p>The app also shows maps for air pressure, lightning, and clouds or sun. These images also come from the radar service, without a location. They are based on data from the German Weather Service (DWD) and, for clouds and sun, on satellite data from EUMETSAT (section 14). The radar service fetches this data from the sources; no user data is transmitted in doing so. Only the small legend image of these maps is loaded by the app directly from the DWD or from EUMETSAT (EUMETView), without a location; as with any internet connection, the respective body sees your IP address.</p>
        <h2>4. Direct retrieval from the German Weather Service</h2>
        <p>If the radar service does not respond or its data is older than 20 minutes, the app retrieves the radar images directly from the German Weather Service (DWD). The DWD then sees the requested map section and, as with any internet connection, your IP address. The DWD's privacy notices apply.</p>
        <p>The app queries the point forecast for a place directly from the DWD, as do the widgets and the Apple Watch for your saved places. The requested point and the IP address are visible to the DWD. The radar service does not receive these places.</p>
        <h2>5. Rain alerts, areas and Live Activities (optional)</h2>
        <p>If you turn on rain alerts for a place or an area (radius) in the app, the radar service can notify you even when the app is closed ("Rain starts in N minutes", "Rain reaches your area"). Without this function, none of this is stored.</p>
        <p><strong>What data is stored.</strong> The server stores:</p>
        <ul>
        <li>a random installation ID and the hash of a secret with which the app identifies itself to the server (the secret itself is kept only in your device's keychain);</li>
        <li>the device token for Apple Push Notifications (APNs), the environment (development or production) and the language (German or English);</li>
        <li>for each rain alert: for a place, the grid cell of the radar image it lies in (edge length about 0.7 km, no coordinate, no place name); for an area, the center point, rounded to a block of about 2 km (the app transmits the grid cell of the center, the server rounds it before storing), and the radius (5, 10 or 25 km); also the threshold, lead time (10, 20 or 30 minutes), for areas the minimum share, whether the alert should be delivered as time-sensitive, whether a Live Activity is wanted, the state of the rule evaluation and timestamps (created, last changed, last sent; "last seen" applies to the installation);</li>
        <li>if Live Activities are on, the start token of your device and one activity token per rain alert. The Live Activity shows only times, rain class and, for areas, the share of wet area, no place name and no coordinates. At most one Live Activity runs per device at a time; an activity token is removed after eight hours at the latest, when you turn it off or when you delete the rain alert;</li>
        <li>briefly, the notification text to be sent, in a queue (see retention).</li>
        </ul>
        <p>You can create up to 10 rain alerts per installation, of which up to 3 can be areas. Depending on location, the grid cell can be personal data because it is associated with a device through the installation ID. No location history is created: only the current value is stored per rain alert.</p>
        <p><strong>Place names stay on the device.</strong> The server does not know the name of your place or area. The notification contains an identifier of the rain alert (which the server sends as the thread identifier) and the minutes; a small app extension (Notification Service Extension) adds the name from a local table on your device to the text.</p>
        <p><strong>Test notification.</strong> In the settings you can trigger a test notification. It goes to the device token of your installation, contains a fixed text without a place and is not stored (at most 3 per hour).</p>
        <p><strong>Recipient Apple.</strong> Notifications and Live Activities are delivered through the Apple Push Notification service. For this, Apple receives from the server the device token, the content of the notification or Live Activity and technical identifiers for grouping notifications (the identifier of the rain alert, for the test notification the installation ID). Apple's privacy terms apply. Data may be transferred to Apple servers outside the EU, in particular in the USA. <span class="draft">[Legal review: basis of the third-country transfer and Apple's role, Part G.]</span></p>
        <p><strong>Retention and deletion.</strong> If you delete a rain alert or turn the function off, the app deletes the registration on the server; this deletes the installation, rain alerts, activity data and waiting notifications. If Apple reports a device token as invalid (for example after the app is deleted), the server deletes the registration immediately. Registrations that the app has not reported for 60 days are deleted automatically. Waiting or sent notifications in the queue are removed after about 6 hours. For backups, see section 15.</p>
        <p><strong>Legal basis.</strong> Your consent (Art. 6(1)(a) GDPR), which you give by turning the function on and can withdraw at any time with effect for the future by turning it off or deleting it. <span class="draft">[Legal review, Part C.]</span></p>
        <h2>6. Location and saved places</h2>
        <p>Location access is optional and is requested only when you want to use your location. There is no background location and there are no location histories. Your location stays on the device; only the point for the forecast is sent to the DWD (section 4). Saved places and their names are stored locally on your device (including for widgets and Apple Watch via the device's app group). Only if you turn on rain alerts for a place does its grid cell go to the radar service (section 5).</p>
        <h2>7. Map view and place search (Apple)</h2>
        <p>The map and place search of the app use Apple MapKit. For the base map, your device retrieves the map data of the displayed section from Apple. When you search for a place, the app sends your search text and a fixed search region (Germany, not your location) to Apple. Apple technically sees your IP address in the process. The search text goes neither to the radar service nor to the DWD. The map background of the radar map on Apple Watch is loaded through Apple Maps; the coordinate of the place goes to Apple in the process. Apple's processing is governed by Apple's privacy terms.</p>
        <p>A point that you choose by search, by long press on the map or via the location function is stored only locally on the device. Only this point goes to the DWD for the forecast. The radar service receives a place only in the case of section 5.</p>
        <h2>8. On-device summary</h2>
        <p>The short summary of the rain situation is produced by Apple Foundation Models on the device. No coordinates or place names are sent to third parties in the process.</p>
        <h2>9. Apple Watch, widgets and Live Activities</h2>
        <p>Widgets, Apple Watch and Live Activities use the saved places and settings on your device. The forecast for widgets and watch is retrieved directly from the DWD as described in section 4. The radar map on Apple Watch loads the radar images from the radar service like the app, without a location (section 3). The server does not learn your places in the process unless you have turned on rain alerts or Live Activities (section 5).</p>
        <h2>10. Operational statistics of the radar service</h2>
        <p>For operations, the radar service counts aggregated values that contain no personal data: for example requests per route group and status class, response times in coarse classes, retrieval and error counters of the data sources and results of push delivery. Neither IP addresses nor places, device or installation identifiers are counted. The counters are kept per day (30 days) and as hourly counters (72 hours) in the database and are deleted afterwards. Only the operator can access them, through a protected dashboard.</p>
        <h2>11. Operator diagnostics (only on approval by the operator, voluntary)</h2>
        <p>The operator can pair a device for troubleshooting rain alerts and Live Activities. This is off by default, can only be turned on in the app's settings, and is only possible while the operator has briefly opened a pairing window in the dashboard (5 minutes by default); outside the window the app does not show the function.</p>
        <ul>
        <li>When you turn it on, the app shows a short pairing code (valid for 10 minutes, usable once), which the operator enters in the dashboard, giving the device a label of their own.</li>
        <li>The code is issued only during the pairing window and can only be used if the operator is signed in to the dashboard with their passkey. No receipt from Apple (StoreKit) is transmitted or stored.</li>
        <li>Stored are the link to the push registration of the device, the label, timestamps (pairing, last seen) and a history of technical delivery results for the last 48 hours (for example test notification delivered or rejected by Apple).</li>
        <li>Only for a paired device and only while it is paired does the operator see in the dashboard its rain alerts including the position (center of the grid cell or of the area, as a coordinate rounded to about 1 km) and the current evaluation. Other devices and their places are not individually visible in the dashboard.</li>
        <li>Pairing applies until revoked, at most until the push registration is deleted (section 5). You can revoke it at any time by turning it off in the app; it is then deleted on the server. The operator can also remove it. At most three devices can be paired at the same time.</li>
        <li>The operator can send test notifications and a test Live Activity to the paired device.</li>
        <li>The dashboard's operator log keeps pairing, unpairing and actions for 365 days, without installation ID, token or place, with a short check value of the pairing; after unpairing, this check value can no longer be matched to any device.</li>
        <li>The legal basis is your consent (Art. 6(1)(a) GDPR), which you give by turning the function on and showing the code, and which you can withdraw at any time by turning it off. <span class="draft">[Legal review, Part G.]</span></li>
        </ul>
        <h2>12. No debug logs containing personal data</h2>
        <p>The app does not log URLs, locations or raw error data. Caches are held in memory or locally on the device. The radar service observes push operation only through fixed, aggregated counters without tokens, places or identifiers.</p>
        <h2>13. Your rights</h2>
        <p>Under the General Data Protection Regulation (GDPR) you have in particular the rights of access, rectification, erasure, restriction of processing, data portability and objection (Art. 15 to 21 GDPR), as well as the right to withdraw consent given at any time with effect for the future. You can also lodge a complaint with a data protection supervisory authority, in particular in the member state of your habitual residence <span class="draft">[competent supervisory authority of the operator: to be entered by the operator, Part G]</span>.</p>
        <p><strong>Right to object.</strong> Where we process data on the basis of legitimate interests (Art. 6(1)(f) GDPR, reverse proxy logs in section 3), you can object at any time on grounds relating to your particular situation (Art. 21 GDPR).</p>
        <p>The simplest way to delete your data on the server is to turn off or delete all rain alerts in the app. Because the installation ID is stored only on your device, the operator can match data on request only if you provide the installation ID. You can find it in the app's settings and copy it there. <span class="draft">[Draft note: the app change follows after build 34; publish this sentence only once the display is released in the app.]</span> For requests, contact the address given above.</p>
        <p><strong>Obligation and voluntariness.</strong> You are not obliged by law or contract to provide data. Without an IP address the app cannot technically load radar images; without registration there are no rain alerts or Live Activities from the server, without pairing no operator diagnostics. There is no automated decision-making within the meaning of Art. 22 GDPR; rain alerts are computed solely from the radar data for the place you chose.</p>
        <h2>14. Sources</h2>
        <p>Source: Deutscher Wetterdienst (German Weather Service). The radar images are graphical renderings prepared from DWD raster data. Cloud and sun maps: Contains modified EUMETSAT Meteosat data 2026 (EUMETSAT, year of data publication; adjust the year). Map background: Apple Maps.</p>
        <h2>15. Hosting and recipients</h2>
        <p>The radar service and its database run on a dedicated virtual server operated by Hetzner Online GmbH in a data center in Germany. <span class="draft">[Operator to confirm: the reverse proxy from section 3 runs on the same server or likewise at Hetzner in Germany.]</span> Hetzner provides the server and network and processes the data stored there as a processor under Art. 28 GDPR, only on our instructions and not for its own purposes. <span class="draft">[User action before go-live: conclude a data processing agreement with Hetzner.]</span></p>
        <p>Backups: <span class="draft">[operator information pending: whether backups or snapshots of the server or database exist, how often and how long they are kept. Do not state anything here until then.]</span></p>
        <p>Other recipients: Apple for delivering notifications and Live Activities (section 5). Directly from your device, without involvement of the operator, requests go to the DWD (sections 3 and 4), to EUMETSAT (legend images, section 3) and to Apple (maps and place search, section 7); these bodies process the data under their own responsibility. Beyond that, we do not pass on or sell any data. The server is located in Germany; a transfer to third countries can only take place via Apple (section 5).</p>
        """
        return page(title: "Privacy Policy", description: "Privacy policy of the Showers app and the radar service.", body: body, lang: .en, alternate: "/datenschutz")
    }

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
        <li><strong>Rain radar with a timeline:</strong> scrub through the recent past and the short-term development of rain. The app shows when the data was last updated and whether you are looking at a measurement or a forecast.</li>
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
        <li><a href="/en/privacy">Privacy Policy</a></li>
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
        <p><a href="/en/privacy">Privacy Policy</a> · <a href="/en/imprint">Legal Notice</a></p>
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
        <p>Information on the processing of personal data is in the <a href="/en/privacy">Privacy Policy</a>.</p>

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
