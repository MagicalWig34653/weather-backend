import Foundation

/// Operator details for the public pages; all values come from the environment, nothing is hardcoded.
public struct SiteInfo: Sendable, Equatable {
    public var operatorName = ""
    public var operatorAddress = ""
    public var operatorEmail = ""
    public var proxyLogNote = ""
    public var appStoreURL = ""
    public var testflightURL = ""
    /// `SITE_EN_ENABLED` (default off): serves the English pages under `/en/...` (support, imprint, marketing). There is no
    /// English privacy page; the English pages link to the German one. While off, these paths answer 404 and the German pages
    /// do not link to them.
    public var englishEnabled = false
    /// Set from `WARN_PUSH_ENABLED` together with `PUSH_ENABLED`: only then the privacy page carries the warnings paragraph.
    public var warnPushEnabled = false

    public init() {}

    public var missingRequired: Bool { operatorName.isEmpty || operatorAddress.isEmpty || operatorEmail.isEmpty }
}

/// Language of a public page (`/en/...` pages are English, see `SiteInfo.englishEnabled`).
public enum SiteLang: String, Sendable { case de, en }

/// Static, self-contained HTML pages (no external JS/CSS/fonts). Pure functions: testable without a socket.
public enum SitePages {
    public static let appDocsURL = "https://magicalwig34653.github.io/weather-apple/"
    public static let backendDocsURL = "https://magicalwig34653.github.io/weather-backend/"
    public static let issuesURL = "https://github.com/MagicalWig34653/weather-apple/issues"
    public static let updated = "10. November 2026"

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
            nav = "<a href=\"/en/marketing\">Showers</a><a href=\"/datenschutz\" hreflang=\"de\" lang=\"de\">Privacy (German)</a><a href=\"/en/support\">Support</a><a href=\"/en/imprint\">Legal Notice</a>"
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
                .muted,footer{color:var(--muted);font-size:.9rem}
        footer{margin-top:2.5rem;border-top:1px solid var(--line);padding-top:1rem}
        </style></head><body><main>
        <nav>\(nav)\(switcher)</nav>
        \(body)
        <footer>\(footer)</footer>
        </main></body></html>
        """
    }

    /// Privacy policy (German, Art. 13 GDPR). Section structure is mirrored in the app repo's `docs/datenschutz-entwurf-release.md`
    /// (Teil A) and the in-app privacy text; keep them identical.
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

        let proxyNote = info.proxyLogNote.isEmpty ? "" : " " + escape(info.proxyLogNote)
        let warnBlock = info.warnPushEnabled ? """

        <p><strong>Amtliche Warnungen (optional).</strong> Wenn du Warnungen vor Unwetter, Frost oder Glatteis einschaltest, speichert der Server zusätzlich die Kennungen der Warngebiete (Kreise) deiner Orte und Gebiete, die gewünschten Warnarten und die Mindeststufe, jeweils mit deiner Installationskennung. Koordinaten und Ortsnamen speichert der Server dafür nicht; die Zuordnung deines Ortes zu einem Warngebiet geschieht auf deinem Gerät. Die aktuellen Warnungen ruft die App ohne Ortsangabe ab. Löschung wie bei Regenhinweisen. Quelle der Warnungen: Deutscher Wetterdienst. Die App ersetzt keine offiziellen Warnkanäle; im Notfall wähle 112.</p>
        """ : ""

        let body = """
        <h1>Datenschutzerklärung</h1>
        <p class="muted">Für die App Showers (iPhone, iPad, Apple Watch) und den zugehörigen Radar-Dienst. Stand: \(updated).</p>

        <h2>1. Verantwortlicher</h2>
        \(controller)

        <h2>2. Überblick</h2>
        <p>Kein Benutzerkonto, kein Tracking, keine Werbung, keine Analyse-Dienste. Gespeicherte Orte, ihre Namen und deine Einstellungen bleiben auf deinem Gerät. Die Nutzung ist freiwillig: Du musst keine Daten bereitstellen; ohne Regenhinweise registriert sich die App nicht auf dem Server. Eine automatisierte Entscheidungsfindung im Sinne von Art. 22 DSGVO findet nicht statt.</p>

        <h2>3. Radar-Abruf und Server-Protokolle</h2>
        <p>Die App lädt Radarbilder und weitere Karten (Luftdruck, Blitze, Wolken, Sonne, Temperatur, Feuchte) für ganz Deutschland vom Showers-Radar-Dienst. Die Anfragen enthalten keinen Ort, keine Cookies und keine Kennung. Der Radar-Dienst selbst führt keine Zugriffsprotokolle und speichert keine IP-Adressen; er zählt nur aggregierte, personenlose Werte für den Betrieb (Anfragen je Routengruppe, Fehlerzähler, 30 Tage beziehungsweise 72 Stunden).</p>
        <p>Dem Radar-Dienst ist ein Reverse Proxy vorgeschaltet. Technisch bedingt sieht er die IP-Adresse jedes Abrufs und protokolliert sie befristet. Zweck sind Betrieb, Fehlersuche und Abwehr von Missbrauch; Rechtsgrundlage ist unser berechtigtes Interesse (Art. 6 Abs. 1 lit. f DSGVO).\(proxyNote)</p>

        <h2>4. Orte, Standort, Prognose und Karten</h2>
        <p>Der Standortzugriff ist optional und wird erst angefragt, wenn du ihn nutzen willst; es gibt keine Hintergrundortung und keine Standortverläufe. Gespeicherte Orte und ihre Namen liegen nur lokal auf deinem Gerät (auch für Widgets und Apple Watch). Die kurze Einordnung der Regenlage erstellt Apple Foundation Models auf dem Gerät.</p>
        <p>Die Punktprognose für einen Ort, auch für Widgets und Apple Watch, ruft die App direkt beim Deutschen Wetterdienst (DWD) ab. Der Radar-Dienst erhält diese Orte nicht. Antwortet der Radar-Dienst nicht oder sind seine Daten älter als 20 Minuten, lädt die App die Radarbilder ebenfalls direkt beim DWD; die Legendenbilder einiger Karten lädt sie direkt beim DWD beziehungsweise bei EUMETSAT. Diese Stellen sehen dabei den angefragten Punkt oder Kartenausschnitt und, wie bei jeder Internetverbindung, deine IP-Adresse; es gelten ihre eigenen Datenschutzhinweise.</p>
        <p>Karte und Ortssuche nutzen Apple MapKit: Dein Gerät ruft Kartendaten von Apple ab, bei der Suche gehen Suchtext und ein fester Suchbereich (Deutschland, nicht dein Standort) an Apple, auf der Apple Watch für den Kartenhintergrund die Koordinate des Ortes. Apple sieht dabei deine IP-Adresse; es gelten die Datenschutzbestimmungen von Apple. Suchtext und Karte gehen nicht an den Radar-Dienst.</p>

        <h2>5. Regenhinweise und Live Activities (optional)</h2>
        <p>Wenn du Regenhinweise für einen Ort oder ein Gebiet einschaltest, kann dich der Radar-Dienst auch bei geschlossener App benachrichtigen. Zweck ist die Zustellung dieser Hinweise; Rechtsgrundlage ist deine Einwilligung (Art. 6 Abs. 1 lit. a DSGVO), die du mit dem Einschalten erteilst und durch Ausschalten oder Löschen jederzeit mit Wirkung für die Zukunft widerrufen kannst. Ohne diese Funktion wird nichts davon gespeichert.</p>
        <p><strong>Gespeichert werden</strong> auf dem Server: eine zufällige Installationskennung und der Hash eines Geheimnisses (das Geheimnis selbst liegt nur im Schlüsselbund deines Geräts); das Gerätetoken für Apple Push-Mitteilungen, die Umgebung (Entwicklung oder Produktion) und die Sprache; je Regenhinweis bei einem Ort die Rasterzelle des Radarbildes (Kantenlänge etwa 0,7 km, keine Koordinate, kein Ortsname), bei einem Gebiet der auf etwa 2 km gerundete Mittelpunkt und der Radius, dazu Schwelle, Vorlauf, Einstellungen, Zustand der Auswertung und Zeitpunkte; bei Live Activities Start- und Activity-Token; kurzzeitig der zu sendende Mitteilungstext in einer Warteschlange. Es sind bis zu 10 Regenhinweise je Installation möglich, davon bis zu 3 Gebiete. Die Rasterzelle kann zusammen mit der Installationskennung einem Gerät zugeordnet und damit personenbezogen sein; ein Standortverlauf entsteht nicht. Ortsnamen kennt der Server nicht: Eine Erweiterung der App ergänzt sie auf dem Gerät.</p>
        <p><strong>Testmeldung.</strong> In den Einstellungen kannst du eine Testmeldung mit festem Text auslösen (höchstens 3 je Stunde); sie wird nicht gespeichert.</p>\(warnBlock)
        <p><strong>Apple.</strong> Mitteilungen und Live Activities werden über den Apple Push Notification Service zugestellt. Apple erhält dafür vom Server das Gerätetoken, den Inhalt der Mitteilung und technische Kennungen zum Zusammenfassen von Mitteilungen. Dabei können Daten an Server von Apple außerhalb der EU, insbesondere in den USA, übermittelt werden. Es gelten die Datenschutzbestimmungen von Apple.</p>
        <p><strong>Speicherdauer.</strong> Löschst du einen Regenhinweis oder schaltest die Funktion aus, löscht die App die Registrierung auf dem Server; damit werden Installation, Regenhinweise, Activity-Daten und wartende Mitteilungen gelöscht. Meldet Apple ein Gerätetoken als ungültig (zum Beispiel nach Löschen der App), löscht der Server die Registrierung sofort. Registrierungen, die 60 Tage lang nicht mehr von der App gemeldet wurden, werden automatisch gelöscht. Mitteilungen in der Warteschlange werden nach etwa 6 Stunden entfernt.</p>

        <h2>6. Betreiber-Diagnose (freiwillig)</h2>
        <p>Der Betreiber kann ein Gerät zur Fehlersuche bei Regenhinweisen und Live Activities koppeln. Das ist standardmäßig aus, nur in den Einstellungen der App einschaltbar und nur möglich, solange der Betreiber im Dashboard kurzzeitig ein Kopplungsfenster geöffnet hat. Dabei zeigt die App einen kurzen Koppelcode (10 Minuten gültig, einmal verwendbar), den der Betreiber nach Anmeldung mit seinem Passkey im Dashboard eingibt. Gespeichert werden die Zuordnung zur Push-Registrierung, eine vom Betreiber vergebene Bezeichnung, Zeitpunkte und ein Verlauf technischer Versandergebnisse der letzten 48 Stunden. Nur für ein gekoppeltes Gerät sieht der Betreiber dessen Regenhinweise mit der auf etwa 1 km gerundeten Position und der aktuellen Auswertung; er kann diesem Gerät Test-Mitteilungen und eine Test-Live-Activity senden. Höchstens drei Geräte können gleichzeitig gekoppelt sein. Im Betreiberprotokoll werden Kopplung, Entkopplung und Aktionen ohne Installationskennung, Token oder Ort mit einem kurzen Prüfwert 365 Tage aufbewahrt. Die Kopplung gilt bis zum Widerruf, längstens bis die Push-Registrierung gelöscht wird; du kannst sie jederzeit in der App ausschalten, dabei wird sie auf dem Server gelöscht. Rechtsgrundlage ist deine Einwilligung (Art. 6 Abs. 1 lit. a DSGVO).</p>

        <h2>7. Empfänger, Hosting und Drittländer</h2>
        <p>Der Radar-Dienst und seine Datenbank laufen auf einem eigenen virtuellen Server bei der Hetzner Online GmbH in einem Rechenzentrum in Deutschland. Hetzner verarbeitet die dort gespeicherten Daten als Auftragsverarbeiter nach Art. 28 DSGVO nur nach unseren Weisungen. Empfänger der Push-Daten ist Apple (Abschnitt 5). Direkt von deinem Gerät, ohne Beteiligung des Betreibers, gehen Anfragen an den DWD, an EUMETSAT und an Apple (Abschnitt 4); diese Stellen verarbeiten die Daten in eigener Verantwortung. Darüber hinaus geben wir keine Daten weiter und verkaufen keine Daten. Eine Übermittlung in Drittländer kann nur über Apple erfolgen (Abschnitt 5).</p>

        <h2>8. Deine Rechte</h2>
        <p>Dir stehen nach der Datenschutz-Grundverordnung (DSGVO) die Rechte auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit und Widerspruch zu (Art. 15 bis 21 DSGVO) sowie das Recht, eine erteilte Einwilligung jederzeit mit Wirkung für die Zukunft zu widerrufen. Soweit wir Daten auf Grundlage berechtigter Interessen verarbeiten (Protokolle des Reverse Proxys, Abschnitt 3), kannst du aus Gründen, die sich aus deiner besonderen Situation ergeben, jederzeit widersprechen (Art. 21 DSGVO). Zudem kannst du dich bei einer Datenschutz-Aufsichtsbehörde beschweren, insbesondere in dem Mitgliedstaat deines Aufenthaltsorts.</p>
        <p>Am einfachsten löschst du deine Daten auf dem Server selbst: Schalte alle Regenhinweise in der App aus oder lösche sie. Da die Installationskennung nur auf deinem Gerät liegt, kann der Betreiber Daten auf Anfrage nur zuordnen, wenn du die Installationskennung nennst; du findest sie in der App in den Einstellungen und kannst sie dort kopieren. Wende dich für Anfragen an die in Abschnitt 1 genannte Stelle.</p>

        <h2>9. Quellen</h2>
        <p>Quelle: Deutscher Wetterdienst. Die Radarbilder sind aus Rasterdaten des DWD bildlich wiedergegeben und aufbereitet. Wolken- und Sonnenkarten: Contains modified EUMETSAT Meteosat data 2026. Kartenhintergrund: Apple Karten.</p>
        """
        return page(title: "Datenschutzerklärung", description: "Datenschutzerklärung der Showers-App und des Radar-Dienstes.", body: body)
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
        <li><strong>Regenradar:</strong> aktuelle Niederschlagsanalyse und Vorhersage bis zu zwei Stunden in Fünf-Minuten-Schritten.</li>
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
        // English pages: only behind SITE_EN_ENABLED (default off, then 404). No English privacy page.
        case "/en/marketing" where info.englishEnabled: return marketingEN(info)
        case "/en/support" where info.englishEnabled: return supportEN(info)
        case "/en/imprint" where info.englishEnabled: return imprintEN(info)
        default: return nil
        }
    }
}
