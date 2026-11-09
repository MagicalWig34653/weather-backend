import Foundation

/// Operator details for the public pages; all values come from the environment, nothing is hardcoded.
public struct SiteInfo: Sendable, Equatable {
    public var operatorName = ""
    public var operatorAddress = ""
    public var operatorEmail = ""
    public var proxyLogNote = ""
    public var appStoreURL = ""
    public var testflightURL = ""
    /// `SITE_EN_ENABLED` (default off): serves the English draft pages under `/en/...` (privacy, support, imprint, marketing).
    /// DRAFT: the English privacy text is not released by the operator yet; while off, these paths answer 404 and the German
    /// pages do not link to them.
    public var englishEnabled = false

    public init() {}

    public var missingRequired: Bool { operatorName.isEmpty || operatorAddress.isEmpty || operatorEmail.isEmpty }
}

/// Language of a public page (`/en/...` pages are English drafts, see `SiteInfo.englishEnabled`).
public enum SiteLang: String, Sendable { case de, en }

/// Static, self-contained HTML pages (no external JS/CSS/fonts). Pure functions: testable without a socket.
public enum SitePages {
    public static let appDocsURL = "https://magicalwig34653.github.io/weather-apple/"
    public static let backendDocsURL = "https://magicalwig34653.github.io/weather-backend/"
    public static let issuesURL = "https://github.com/MagicalWig34653/weather-apple/issues"
    public static let updated = "6. November 2026"

    public static let missingNotice = "Angaben zum Verantwortlichen sind noch nicht konfiguriert."

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Escaped text; a literal backslash-n (as written in a one-line env value) or a real newline becomes a line break.
    static func multiline(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { escape($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "<br>")
    }

    /// Only https links are rendered (blocks javascript: and other schemes); the value is escaped.
    static func safeLink(_ url: String, label: String) -> String? {
        guard url.lowercased().hasPrefix("https://"), !url.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" })
        else { return nil }
        return "<a href=\"\(escape(url))\" rel=\"noopener noreferrer\">\(escape(label))</a>"
    }

    static func mailLink(_ email: String) -> String {
        let plausible = email.contains("@") && !email.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "," })
        return plausible ? "<a href=\"mailto:\(escape(email))\">\(escape(email))</a>" : escape(email)
    }

    /// Shared page frame. `lang` switches language of navigation and footer; `alternate` is the path of the same page in the
    /// other language (rendered as a language link only when given).
    static func page(title: String, description: String, body: String, lang: SiteLang = .de, alternate: String? = nil) -> String {
        let nav: String
        let footer: String
        switch lang {
        case .de:
            nav = "<a href=\"/marketing\">Showers</a><a href=\"/datenschutz\">Datenschutz</a><a href=\"/support\">Support</a><a href=\"/impressum\">Impressum</a>"
            footer = "Quelle: Deutscher Wetterdienst. Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben, aufbereitet."
        case .en:
            nav = "<a href=\"/en/marketing\">Showers</a><a href=\"/en/privacy\">Privacy</a><a href=\"/en/support\">Support</a><a href=\"/en/imprint\">Legal Notice</a>"
            footer = "Source: Deutscher Wetterdienst (German Weather Service). Data basis: Deutscher Wetterdienst, raster data graphically rendered and processed."
        }
        let switcher = alternate.map { "<a href=\"\(escape($0))\" hreflang=\"\(lang == .de ? "en" : "de")\" lang=\"\(lang == .de ? "en" : "de")\">\(lang == .de ? "English" : "Deutsch")</a>" } ?? ""
        return """
        <!DOCTYPE html>
        <html lang="\(lang.rawValue)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="robots" content="noindex,follow">
        <meta name="description" content="\(escape(description))">
        <title>\(escape(title)) \u{2013} Showers</title>
        <style>
        :root{color-scheme:light dark;--bg:#fff;--fg:#1b1f24;--muted:#5b6672;--line:#d8dee4;--accent:#0a63c9;--card:#f4f7fa;--warn:#fff4d6;--warnfg:#5c3d00}
        @media(prefers-color-scheme:dark){:root{--bg:#10151a;--fg:#e6ebf0;--muted:#9aa7b4;--line:#2a333c;--accent:#6cb2ff;--card:#18202a;--warn:#3a2f10;--warnfg:#ffdf91}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
        main{max-width:42rem;margin:0 auto;padding:1.5rem 1.25rem 3rem}
        h1{font-size:1.9rem;line-height:1.25;margin:.5rem 0 1rem}
        h2{font-size:1.2rem;margin:2rem 0 .5rem}
        p,li{margin:.5rem 0}
        a{color:var(--accent)}
        nav{display:flex;flex-wrap:wrap;gap:.25rem 1rem;font-size:.95rem;border-bottom:1px solid var(--line);padding-bottom:.75rem}
        .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:.25rem 1rem;margin:1rem 0}
        .warn{background:var(--warn);color:var(--warnfg);border-radius:12px;padding:.75rem 1rem;margin:1rem 0;font-weight:600}
        .draft{background:var(--warn);color:var(--warnfg);border-radius:4px;padding:0 .25rem}
        .muted,footer{color:var(--muted);font-size:.9rem}
        footer{margin-top:2.5rem;border-top:1px solid var(--line);padding-top:1rem}
        </style></head><body><main>
        <nav>\(nav)\(switcher)</nav>
        \(body)
        <footer>\(footer)</footer>
        </main></body></html>
        """
    }

    public static func privacy(_ info: SiteInfo) -> String {
        var controller = ""
        if info.missingRequired {
            controller += "<p class=\"warn\">\(escape(missingNotice))</p>"
        }
        var lines: [String] = []
        if !info.operatorName.isEmpty { lines.append("<strong>\(multiline(info.operatorName))</strong>") }
        if !info.operatorAddress.isEmpty { lines.append(multiline(info.operatorAddress)) }
        if !info.operatorEmail.isEmpty { lines.append("E-Mail: \(mailLink(info.operatorEmail))") }
        if !lines.isEmpty { controller += "<p>" + lines.joined(separator: "<br>") + "</p>" }

        let proxy = info.proxyLogNote.isEmpty
            ? "Ob und wie lange der Reverse Proxy Zugriffe protokolliert, ist hier noch nicht angegeben."
            : escape(info.proxyLogNote)

        let body = """
        <h1>Datenschutzerklärung</h1>
        <p class="muted">Für die App Showers (iPhone, iPad) und den zugehörigen Radar-Dienst. Stand: \(updated).</p>

        <h2>1. Verantwortlicher</h2>
        \(controller)

        <h2>2. Überblick</h2>
        <ul>
        <li>Kein Benutzerkonto, keine Werbung, kein Tracking, keine Analyse-SDKs.</li>
        <li>Der Radar-Dienst setzt keine Cookies und vergibt keine Kennung.</li>
        <li>Betriebsstatistik nur als aggregierte, personenlose Zähler; Geräte-Diagnose nur freiwillig und nur in Testversionen (Abschnitte 8 und 9).</li>
        <li>Gespeicherte Orte und Einstellungen bleiben auf deinem Gerät.</li>
        </ul>

        <h2>3. Radarkarte und Radar-Dienst</h2>
        <p>Die App lädt die Radarbilder für ganz Deutschland vom Showers-Radar-Dienst. Die Anfragen enthalten keinen Ort: Es gibt feste Pfade je Radarlauf und Zeitschritt (Ganzbild für Deutschland), keine Cookies und keine Kennung.</p>
        <p>Der Radar-Dienst selbst führt keine Zugriffsprotokolle und speichert keine IP-Adressen oder Abfragedetails. Seine technischen Logs enthalten nur Lauf-Kennungen und Fehlerklassen.</p>
        <p>Dem Radar-Dienst ist ein Reverse Proxy (TLS, Weiterleitung) vorgeschaltet. Dieser sieht technisch bedingt die IP-Adresse jedes Abrufs. \(proxy)</p>

        <h2>4. Direktabruf beim Deutschen Wetterdienst</h2>
        <p>Antwortet der Radar-Dienst nicht oder sind seine Daten älter als 20 Minuten, ruft die App die Radarbilder direkt beim Deutschen Wetterdienst (DWD) ab. Der DWD sieht dann den abgefragten Kartenausschnitt und, wie bei jeder Internetverbindung, deine IP-Adresse. Es gelten die Datenschutzhinweise des DWD.</p>
        <p>Die Punktprognose für einen Ort fragt die App direkt beim DWD ab. Dabei sind der abgefragte Punkt und die IP-Adresse für den DWD sichtbar.</p>

        <h2>5. Standort und gespeicherte Orte</h2>
        <p>Der Standortzugriff ist optional und wird erst angefragt, wenn du den Standort verwenden willst. Es gibt keine Hintergrundortung und keine Standortverläufe. Der Standort verbleibt auf dem Gerät; für die Prognose wird nur der Punkt an den DWD gesendet (siehe Abschnitt 4). Gespeicherte Orte liegen ausschließlich lokal auf dem Gerät.</p>

        <h2>6. Kartenansicht und Ortssuche (Apple)</h2>
        <p>Die Karte und die Ortssuche der App nutzen Apple MapKit. Für die Basiskarte ruft dein Gerät die Kartendaten des angezeigten Ausschnitts von Apple ab. Wenn du nach einem Ort suchst, sendet die App deinen Suchtext und einen festen Suchbereich (Deutschland, nicht dein Standort) an Apple. Dabei sieht Apple technisch bedingt deine IP-Adresse. Der Suchtext geht nicht an den Radar-Dienst und nicht an den DWD. Die Verarbeitung durch Apple richtet sich nach den Datenschutzbestimmungen von Apple.</p>
        <p>Ein Punkt, den du per Suche, langem Druck auf die Karte oder über die Standortfunktion wählst, wird nur lokal auf dem Gerät gespeichert. An den DWD geht für die Prognose lediglich dieser Punkt (siehe Abschnitt 4). Der Radar-Dienst erhält keinen Ort.</p>

        <h2>7. Lokale Einordnung</h2>
        <p>Die kurze Einordnung der Regenlage erstellt Apple Foundation Models auf dem Gerät. Dabei werden keine Koordinaten oder Ortsnamen an Dritte gesendet.</p>

        <h2>8. Betriebsstatistik des Radar-Dienstes</h2>
        <p>Der Radar-Dienst zählt für den Betrieb aggregierte, personenlose Werte: zum Beispiel Anfragen je Routengruppe und Statusklasse, Antwortzeiten in groben Klassen, Abruf- und Fehlerzähler der Datenquellen sowie Ergebnisse des Push-Versands. Es werden weder IP-Adressen noch Orte, Geräte- oder Installationskennungen gezählt. Die Zähler liegen tageweise (30 Tage) und als Stundenzähler (72 Stunden) in der Datenbank und werden danach gelöscht. Der Zugriff darauf ist nur dem Betreiber über ein geschütztes Dashboard möglich.</p>

        <h2>9. Betreiber-Diagnose (nur auf Freigabe des Betreibers, freiwillig)</h2>
        <p>Der Betreiber kann ein Gerät zur Fehlersuche bei Regenhinweisen und Live Activities koppeln. Das ist standardmäßig aus, nur in den Einstellungen der App einschaltbar und nur möglich, solange der Betreiber dafür im Dashboard kurzzeitig (standardmäßig 5 Minuten) ein Kopplungsfenster geöffnet hat; außerhalb des Fensters zeigt die App die Funktion nicht an. Sie hängt nicht davon ab, ob die App aus dem App Store oder aus TestFlight stammt.</p>
        <ul>
        <li>Beim Einschalten zeigt die App einen kurzen Koppelcode (10 Minuten gültig, einmal verwendbar), den der Betreiber im Dashboard eingibt und dem Gerät dabei eine eigene Bezeichnung gibt.</li>
        <li>Der Code wird nur im Kopplungsfenster ausgegeben und ist nur nutzbar, wenn sich der Betreiber im Dashboard mit seinem Passkey angemeldet hat. Es wird kein Beleg von Apple (StoreKit) übertragen oder gespeichert.</li>
        <li>Gespeichert werden die Zuordnung zur Push-Registrierung des Geräts, die Bezeichnung, Zeitpunkte (Kopplung, zuletzt gesehen) und ein Verlauf technischer Versandergebnisse der letzten 48 Stunden (zum Beispiel Testmitteilung zugestellt oder von Apple abgelehnt). Es werden keine Standortdaten gespeichert.</li>
        <li>Die Kopplung gilt bis zum Widerruf. Du kannst sie jederzeit durch Ausschalten in der App widerrufen; dabei wird sie auf dem Server gelöscht. Der Betreiber kann sie ebenfalls entfernen. Höchstens drei Geräte können gleichzeitig gekoppelt sein.</li>
        </ul>

        <h2>10. Keine Debuglogs mit Personenbezug</h2>
        <p>Die App protokolliert keine URLs, Standorte oder Fehler-Rohdaten. Zwischenspeicher liegen im Arbeitsspeicher beziehungsweise lokal auf dem Gerät.</p>

        <h2>11. Deine Rechte</h2>
        <p>Dir stehen nach der Datenschutz-Grundverordnung (DSGVO) insbesondere die Rechte auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit und Widerspruch zu (Art. 15 bis 21 DSGVO). Zudem kannst du dich bei einer Datenschutz-Aufsichtsbehörde beschweren. Wende dich für Anfragen an die oben genannte Stelle.</p>

        <h2>12. Quellen</h2>
        <p>Quelle: Deutscher Wetterdienst. Die Radarbilder sind aus Rasterdaten des DWD bildlich wiedergegeben und aufbereitet.</p>
        """
        return page(title: "Datenschutzerklärung", description: "Datenschutzerklärung der Showers-App und des Radar-Dienstes.", body: body, alternate: info.englishEnabled ? "/en/privacy" : nil)
    }

    public static func marketing(_ info: SiteInfo) -> String {
        var status = "<p>Showers befindet sich in einer frühen Beta und wird über TestFlight erprobt.</p>"
        var links: [String] = []
        if let l = safeLink(info.appStoreURL, label: "Showers im App Store") { links.append(l) }
        if let l = safeLink(info.testflightURL, label: "Showers über TestFlight testen") { links.append(l) }
        if !links.isEmpty { status += "<p>" + links.joined(separator: "<br>") + "</p>" }

        let body = """
        <h1>Showers</h1>
        <p>Showers ist ein nativer Regenradar für iPhone und iPad auf Basis der Radardaten des Deutschen Wetterdienstes (DWD). Datensparsam, ohne Konto, ohne Werbung.</p>

        <h2>Funktionen</h2>
        <div class="card"><ul>
        <li><strong>Radar mit Zeitleiste:</strong> aktuelle Niederschlagsanalyse und Vorhersage bis zu zwei Stunden in Fünf-Minuten-Schritten.</li>
        <li><strong>Schnelle Anzeige:</strong> Die Radarbilder kommen aus einem Radar-Cache; bei Störungen greift die App direkt auf den DWD zurück.</li>
        <li><strong>Orte und Punktprognose:</strong> gespeicherte Orte, optional dein Standort, Prognose für den gewählten Punkt.</li>
        <li><strong>Lokale Einordnung:</strong> eine kurze Einschätzung der Regenlage, auf dem Gerät erstellt.</li>
        <li><strong>Kein Tracking:</strong> keine Werbung, keine Analyse-SDKs, kein Benutzerkonto.</li>
        </ul></div>

        <h2>Status</h2>
        \(status)

        <h2>Mehr erfahren</h2>
        <ul>
        <li><a href="\(appDocsURL)" rel="noopener noreferrer">Dokumentation der App</a></li>
        <li><a href="\(backendDocsURL)" rel="noopener noreferrer">Dokumentation des Radar-Dienstes</a></li>
        <li><a href="/datenschutz">Datenschutzerklärung</a></li>
        <li><a href="/support">Support</a></li>
        <li><a href="/impressum">Impressum</a></li>
        </ul>

        <h2>Quelle</h2>
        <p>Quelle: Deutscher Wetterdienst. Die Radarbilder sind aus DWD-Rasterdaten bildlich wiedergegeben und aufbereitet (verändert).</p>
        <p>Temperatur- und Feuchtekarten: DWD ICON-D2/ICON-EU Modelldaten (CC BY 4.0, Quelle: Deutscher Wetterdienst), verändert.</p>
        """
        return page(title: "Showers", description: "Showers: nativer DWD-Regenradar für iPhone und iPad.", body: body, alternate: info.englishEnabled ? "/en/marketing" : nil)
    }

    public static func support(_ info: SiteInfo) -> String {
        let contact = info.operatorEmail.isEmpty
            ? "<p class=\"warn\">Die Kontaktadresse ist noch nicht konfiguriert.</p>"
            : "<p>Kontakt per E-Mail: \(mailLink(info.operatorEmail))</p>"
        let body = """
        <h1>Support</h1>
        <p>Fragen, Fehler oder Wünsche zu Showers?</p>
        \(contact)
        <p>Fehler und Ideen kannst du auch auf <a href="\(issuesURL)" rel="noopener noreferrer">GitHub</a> melden. Bitte schreibe dort keine persönlichen Daten oder genauen Standorte.</p>
        <p><a href="/datenschutz">Datenschutzerklärung</a> · <a href="/impressum">Impressum</a></p>
        """
        return page(title: "Support", description: "Support für die Showers-App.", body: body, alternate: info.englishEnabled ? "/en/support" : nil)
    }

    public static func imprint(_ info: SiteInfo) -> String {
        var provider = ""
        if info.missingRequired {
            provider += "<p class=\"warn\">\(escape(missingNotice))</p>"
        }
        var lines: [String] = []
        if !info.operatorName.isEmpty { lines.append("<strong>\(multiline(info.operatorName))</strong>") }
        if !info.operatorAddress.isEmpty { lines.append(multiline(info.operatorAddress)) }
        if !lines.isEmpty { provider += "<p>" + lines.joined(separator: "<br>") + "</p>" }
        let contact = info.operatorEmail.isEmpty ? "" : "<p>E-Mail: \(mailLink(info.operatorEmail))</p>"

        let body = """
        <h1>Impressum</h1>
        <p class="muted">Angaben gemäß § 5 Digitale-Dienste-Gesetz (DDG) für die App Showers und den zugehörigen Radar-Dienst.</p>

        <h2>Anbieter</h2>
        \(provider)

        <h2>Kontakt</h2>
        \(contact)
        <p>Weitere Wege der Kontaktaufnahme: <a href="/support">Support</a>.</p>

        <h2>Datenschutz</h2>
        <p>Informationen zur Verarbeitung personenbezogener Daten stehen in der <a href="/datenschutz">Datenschutzerklärung</a>.</p>

        <h2>Quellen und Datenherkunft</h2>
        <p>Quelle: Deutscher Wetterdienst. Die Radar- und Wetterdaten stammen vom Deutschen Wetterdienst (DWD) und sind als Rasterdaten bildlich wiedergegeben und aufbereitet (verändert).</p>
        <p>Temperatur-, Taupunkt- und Feuchtekarten: DWD ICON-D2/ICON-EU Modelldaten (CC BY 4.0, Quelle: Deutscher Wetterdienst); Rasterdaten bildlich wiedergegeben und aufbereitet (verändert). Es sind Modellprognosen, keine Messwerte.</p>
        <p>Optionale Waldfläche in der Karte: © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium (CC BY 4.0); auf ca. 550 m gemittelt, in 4 Stufen gerundet und eigens eingefärbt (verändert).</p>
        <p>Für Wolken- und Satellitenkarten gilt: Contains modified EUMETSAT Meteosat data. Die Daten von EUMETSAT stehen unter der Lizenz CC BY 4.0 und wurden verändert.</p>
        <p>Showers ist ein unabhängiges Angebot und steht in keiner Verbindung zum DWD oder zu EUMETSAT. Die Angaben der App sind eine Orientierung und kein Ersatz für amtliche Warnungen und Wetterberichte.</p>
        """
        return page(title: "Impressum", description: "Impressum der Showers-App und des Radar-Dienstes.", body: body, alternate: info.englishEnabled ? "/en/imprint" : nil)
    }

    /// Path -> HTML for the public pages; nil for any other path.
    public static func render(path: String, info: SiteInfo) -> String? {
        switch path {
        case "/datenschutz": return privacy(info)
        case "/marketing": return marketing(info)
        case "/support": return support(info)
        case "/impressum": return imprint(info)
        // DRAFT English pages: only behind SITE_EN_ENABLED (default off, then 404).
        case "/en/privacy" where info.englishEnabled: return privacyEN(info)
        case "/en/marketing" where info.englishEnabled: return marketingEN(info)
        case "/en/support" where info.englishEnabled: return supportEN(info)
        case "/en/imprint" where info.englishEnabled: return imprintEN(info)
        default: return nil
        }
    }
}
