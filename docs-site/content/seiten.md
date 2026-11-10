# Datenschutz und Marketing-Seiten

Der Radar-Dienst liefert zusätzlich drei kleine, öffentliche HTML-Seiten, die Showers für App Store Connect und TestFlight braucht. Sie sind in den Dienst eingebaut (`Sources/RadarCore/SitePages.swift`), brauchen weder Datenbank noch Zusatzdienste und bleiben ohne Konfiguration funktionsfähig.

## Endpunkte

| Pfad | Inhalt | Verwendung in App Store Connect |
|---|---|---|
| `/datenschutz` | Datenschutzerklärung der App und des Radar-Dienstes | Datenschutz-URL (`https://showers.linolaske.de/datenschutz`) |
| `/marketing` | Kurze Produktseite mit Funktionen, Status und Quellenangabe | Marketing-URL (`https://showers.linolaske.de/marketing`) |
| `/support` | Kontakt-E-Mail und Link auf GitHub-Issues | Support-URL (`https://showers.linolaske.de/support`) |

Die Seiten sind selbst enthalten (kein externes JavaScript, CSS oder Fonts; helles und dunkles Layout inline), werden mit `Content-Type: text/html; charset=utf-8`, `Cache-Control: public, max-age=3600`, ETag (`If-None-Match` ergibt `304`) und Sicherheits-Headern ausgeliefert (`X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, restriktive `Content-Security-Policy`). `HEAD` funktioniert; es gibt keine Cookies und, wie bei allen Routen, keine Zugriffsprotokolle. `/v1/radar/*` und `/healthz` bleiben unverändert.

## Landingpage (4. November 2026)

Der öffentliche Port liefert unter `/` (Deutsch) und `/en` (Englisch) eine Produktseite für Showers; vorher antwortete `/` mit 404. Die Seite ist in den Dienst eingebaut (`Sources/RadarCore/LandingPage.swift`), braucht weder Datenbank noch Dateizugriff zur Laufzeit und ist unter beiden Hostnamen identisch (kein Host-Check).

| Pfad | Inhalt |
|---|---|
| `/` | Landingpage Deutsch (`lang="de"`) |
| `/en` | Landingpage Englisch (`lang="en"`), `hreflang`-Links auf beide Sprachen, Umschalter im Kopf |
| `/assets/<name>.<hash>.<css\|webp>` | Stylesheet, App-Icon und Screenshots (hell/dunkel). Der Hash (SHA-256, 10 Zeichen) steht im Namen: `Cache-Control: public, max-age=31536000, immutable`, ETag. Ein falscher Hash ergibt 404. |

Die Sprache wird bewusst nicht per `Accept-Language` ausgehandelt: zwei feste URLs sind cachefreundlich und ohne `Vary`. `/datenschutz`, `/support`, `/marketing` bleiben unverändert und sind verlinkt. Eine Impressum-Route gibt es nicht (siehe unten).

**Technik.** HTML unter 8 KB je Sprache, CSS 5,9 KB (eigene Datei, kein Inline-CSS), Systemschrift, kein JavaScript, keine externen Ressourcen. Header: `Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Permissions-Policy`; HTML `max-age=300`. Hell/Dunkel per `prefers-color-scheme` (Screenshots über `<picture>`), `prefers-reduced-motion` schaltet die CSS-Animation ab, Skip-Link, semantische Struktur. Canonical und `hreflang` sind relativ (keine feste Domain); `og:image` fehlt absichtlich, weil Open Graph eine absolute URL verlangt.

**Bilder.** Die Bilder liegen als Base64 in `Sources/RadarCore/LandingAssetData.swift` (generiert) und werden beim Start dekodiert. Gewählt gegenüber SwiftPM-Resources, weil das Dockerfile nur das Binary (statisch gelinkt) ins Image kopiert; Resource-Bundles müssten zusätzlich mitkopiert werden und fehlten sonst zur Laufzeit. Neu erzeugen: `tools/landing-assets.sh <Pfad zum App-Repo>` (cwebp nötig). Größen: Icon 5 KB, Screenshots 31 bis 72 KB (je 640 px breit). Die Radar-Screenshots sind unterhalb der Kopfzeile beschnitten, damit der Banner „Vorerst kein messbarer Regen erwartet“ nicht im Widerspruch zum Archivregen steht; die Bildunterschrift nennt das Datum der Radardaten.

**Neugestaltung (6. November 2026).** Hero mit zwei Geräterahmen (CSS, Radar-Ringe als Hintergrund, Sweep-Animation), Funktionsreihen (Radar-Zeitleiste als CSS-Schema, Wolkenebene, Orte und Regenhinweis-Beispiel mit Kennzeichnung „nicht live“, Widgets/Watch mit zwei Watch-Screenshots), Chips „Ohne Konto, Ohne Werbung, Keine Standortverläufe“, Datenschutz- und Quellenband (DWD, EUMETSAT), Abschluss mit Icon. Hell/Dunkel per `prefers-color-scheme`, Reduced-Motion schaltet Animationen ab, kein JavaScript, keine externen Ressourcen, CSP unverändert. Bilder: 640- und 320-px-Varianten per `srcset`/`sizes`, Hero mit `fetchpriority=high`, übrige `loading=lazy`, Breite/Höhe gesetzt. Open Graph: `og:image` (1200x630 JPEG aus `creative/universal-16x9.png`, absolute URL `https://showers.linolaske.de/assets/og.<hash>.jpg`), `twitter:card=summary_large_image`, `apple-touch-icon` als PNG (180 px). Gewicht: HTML ca. 10 KB, CSS ca. 9 KB, alle Bilder zusammen ca. 0,45 MB, erste Ansicht (HTML, CSS, Icon, zwei Hero-Bilder in 2x) unter 250 KB. Generierung: `tools/landing-assets.sh <App-Repo>` (cwebp, ffmpeg).

**Inhalte** sind auf belegte Funktionen und den Datenschutztext begrenzt. Regenhinweise sind als „Optional, braucht den Radar-Dienst“ gekennzeichnet, Widgets und Watch als „In Erprobung“.

**App-Store-Link.** Der Button zeigt „Bald im App Store“ als nicht klickbaren Stil. Sobald der Link feststeht, entweder `APP_STORE_URL` setzen (bestehender Eintrag der Betreiberseiten, im Dashboard live änderbar) oder die Konstante `LandingPage.appStoreURL` in `LandingPage.swift` füllen (https-Link). Ein gesetzter `TESTFLIGHT_URL` erzeugt zusätzlich „Beta über TestFlight testen“. Es gibt keine neue Umgebungsvariable.

**Externe Links.** Nur `https://www.dwd.de` (Quelle) als `<a href>`; Bilder und CSS sind immer `'self'`. `/robots.txt` existiert im Dienst nicht (404, unverändert). Footer-Links: Datenschutz, Support, Mehr über Showers (`/marketing`), Sprache. Ein Impressum fehlt noch: die Anbieterangaben stehen im Abschnitt „Verantwortlicher“ von `/datenschutz`; ob eine eigene Impressum-Seite rechtlich nötig ist, muss der Betreiber klären.

## Inhalt der Datenschutzseite

Neun Abschnitte (Stand 10. November 2026, gekürzt auf die Angaben nach Art. 13 DSGVO): 1 Verantwortlicher (aus `OPERATOR_*`), 2 Überblick (kein Konto, kein Tracking, keine Werbung, keine Analyse-Dienste, Freiwilligkeit, keine automatisierte Entscheidung), 3 Radar-Abruf und Server-Protokolle (Dienst ohne Zugriffsprotokoll, Reverse Proxy protokolliert IP befristet, Art. 6 Abs. 1 lit. f; optional `PROXY_LOG_NOTE` angehängt), 4 Orte, Standort, Prognose und Karten (lokal, Direktabruf DWD/EUMETSAT, Apple MapKit), 5 Regenhinweise und Live Activities (Einwilligung, gespeicherte Daten, Apple APNs und Drittland, Speicherdauer; Absatz „Amtliche Warnungen“ nur mit `WARN_PUSH_ENABLED` und `PUSH_ENABLED`), 6 Betreiber-Diagnose (freiwillig, Einwilligung), 7 Empfänger, Hosting (Hetzner, Deutschland) und Drittländer, 8 Rechte (Widerruf, Widerspruch, Beschwerde bei einer Datenschutz-Aufsichtsbehörde, Installationskennung für Auskunft), 9 Quellen. Die Seite gibt es nur auf Deutsch (die App wird nur in Deutschland angeboten), ohne Sprachumschalter; es gibt keine englische Datenschutzseite, die englischen Seiten verlinken auf `/datenschutz`. Dieselbe Fassung steht in Teil A von `docs/datenschutz-entwurf-release.md` des App-Repos. Keine Entwurfs- oder Platzhaltertexte auf der Seite; Tests prüfen Pflichtabschnitte und das Fehlen von Klammern und Interna.

## Englische Seiten (hinter `SITE_EN_ENABLED`)

Pfade `/en/support`, `/en/imprint` (Legal Notice), `/en/marketing`; Code in `Sources/RadarCore/SitePagesEN.swift`. Gewählt gegenüber `Accept-Language` und gegenüber einem Sprachparameter: feste URLs sind cachefreundlich (kein `Vary`), die deutschen URLs, die App und App Store Connect nutzen, bleiben unverändert, und der Sprachumschalter ist ein normaler Link (wie bei der Landingpage `/` und `/en`). Beide Domains liefern dieselben Seiten, keine Weiterleitung. Die Seiten haben `lang="en"`, `Content-Language: en` und denselben Rahmen, dieselben Header und dieselbe Quellenzeile (englisch). Es gibt keine englische Datenschutzseite (10. November 2026: App nur in Deutschland angeboten); die englischen Seiten verlinken als „Privacy Policy (German)“ auf `/datenschutz`.

**Schalter `SITE_EN_ENABLED`** (Standard `false`, live): aus = die drei Pfade antworten `404`, die deutschen Seiten tragen keinen Sprachlink (auch `/datenschutz` nie); an = die Seiten werden ausgeliefert und `/support`, `/impressum`, `/marketing` verlinken „English“. Verantwortlicher und Impressum kommen wie bei den deutschen Seiten aus `OPERATOR_*` (ohne Wert: sichtbarer Hinweis „not configured yet“). Support und Marketing folgen den deutschen Seiten. Keine sichtbaren Entwurfs- oder Interna-Hinweise.

## Konfiguration

Alle Angaben zum Verantwortlichen kommen aus Umgebungsvariablen; im Repository steht nichts davon. Eintrag in der `.env` auf dem Server (Vorlage: `.env.example`), danach `update.sh` ausführen, damit die Replikate die Werte erhalten. Die `.env` wird von der Shell gelesen: Werte mit Leerzeichen in doppelte Anführungszeichen setzen, ohne `$`, Backticks und doppelte Anführungszeichen im Wert.

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `OPERATOR_NAME` | für `/datenschutz` | Name des Verantwortlichen |
| `OPERATOR_ADDRESS` | für `/datenschutz` | Anschrift; ein wörtliches `\n` wird zum Zeilenumbruch |
| `OPERATOR_EMAIL` | für `/datenschutz`, `/support` | Kontakt-E-Mail |
| `PROXY_LOG_NOTE` | optional | Zusatzsatz des Betreibers zu den Zugriffsprotokollen des Reverse Proxys (z. B. die konkrete Aufbewahrungsfrist); wird an den Proxy-Absatz in Abschnitt 3 angehängt. Ohne Wert steht dort nur, dass der Proxy die IP-Adresse befristet protokolliert. |
| `APP_STORE_URL` | optional | `https`-Link, wird auf `/marketing` angezeigt |
| `TESTFLIGHT_URL` | optional | `https`-Link, wird auf `/marketing` angezeigt |
| `SITE_EN_ENABLED` | optional, Standard `false` | Schaltet die englischen Seiten `/en/support`, `/en/imprint`, `/en/marketing` frei (aus: `404`). |

Sind die drei Pflichtwerte nicht gesetzt, zeigt `/datenschutz` sichtbar den Hinweis „Angaben zum Verantwortlichen sind noch nicht konfiguriert“; es wird nichts erfunden. `/healthz` bleibt davon unberührt. Alle Werte werden HTML-escaped; Links werden nur für `https://` ausgegeben. `setup.sh --reconfigure` übernimmt diese Zeilen unverändert in die neue `.env`.

## Rechtlicher Hinweis

Die Texte fassen die technisch belegten Datenflüsse zusammen (Radar-Dienst ohne Zugriffsprotokolle, Proxy, Direktabruf beim DWD, Apple-Karte und Ortssuche über MapKit, Standort nur lokal). Sie sind keine Rechtsberatung. Der Betreiber muss Datenschutzerklärung, Verantwortlichen-Angaben und gegebenenfalls ein Impressum selbst rechtlich prüfen, bevor die URLs in App Store Connect eingetragen werden. Die Rechte der Betroffenen sind nur allgemein genannt (Art. 15 bis 21 DSGVO, Beschwerde bei einer Aufsichtsbehörde).
