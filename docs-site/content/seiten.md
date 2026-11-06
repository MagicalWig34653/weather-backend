# Datenschutz und Marketing-Seiten

Der Radar-Dienst liefert zusätzlich drei kleine, öffentliche HTML-Seiten, die Showers für App Store Connect und TestFlight braucht. Sie sind in den Dienst eingebaut (`Sources/RadarCore/SitePages.swift`), brauchen weder Datenbank noch Zusatzdienste und bleiben ohne Konfiguration funktionsfähig.

## Endpunkte

| Pfad | Inhalt | Verwendung in App Store Connect |
|---|---|---|
| `/datenschutz` | Datenschutzerklärung der App und des Radar-Dienstes | Datenschutz-URL (`https://showernow.linolaske.de/datenschutz`) |
| `/marketing` | Kurze Produktseite mit Funktionen, Status und Quellenangabe | Marketing-URL (`https://showernow.linolaske.de/marketing`) |
| `/support` | Kontakt-E-Mail und Link auf GitHub-Issues | Support-URL (`https://showernow.linolaske.de/support`) |

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

**Neugestaltung (6. November 2026).** Hero mit zwei Geräterahmen (CSS, Radar-Ringe als Hintergrund, Sweep-Animation), Funktionsreihen (Radar-Zeitleiste als CSS-Schema, Wolkenebene, Orte und Regenhinweis-Beispiel mit Kennzeichnung „nicht live“, Widgets/Watch mit zwei Watch-Screenshots), Chips „Ohne Konto, Ohne Werbung, Keine Standortverläufe“, Datenschutz- und Quellenband (DWD, EUMETSAT), Abschluss mit Icon. Hell/Dunkel per `prefers-color-scheme`, Reduced-Motion schaltet Animationen ab, kein JavaScript, keine externen Ressourcen, CSP unverändert. Bilder: 640- und 320-px-Varianten per `srcset`/`sizes`, Hero mit `fetchpriority=high`, übrige `loading=lazy`, Breite/Höhe gesetzt. Open Graph: `og:image` (1200x630 JPEG aus `creative/universal-16x9.png`, absolute URL `https://showers.linolaske.de/assets/og.<hash>.jpg`), `twitter:card=summary_large_image`, `apple-touch-icon` als PNG (180 px). Gewicht: HTML ca. 15 KB, CSS ca. 9 KB, alle Bilder zusammen ca. 0,45 MB, erste Ansicht (HTML, CSS, Icon, zwei Hero-Bilder in 2x) unter 250 KB. Generierung: `tools/landing-assets.sh <App-Repo>` (cwebp, ffmpeg).

**Inhalte** sind auf belegte Funktionen und den Datenschutztext begrenzt. Regenhinweise sind als „Optional, braucht den Radar-Dienst“ gekennzeichnet, Widgets und Watch als „In Erprobung“.

**App-Store-Link.** Der Button zeigt „Bald im App Store“ als nicht klickbaren Stil. Sobald der Link feststeht, entweder `APP_STORE_URL` setzen (bestehender Eintrag der Betreiberseiten, im Dashboard live änderbar) oder die Konstante `LandingPage.appStoreURL` in `LandingPage.swift` füllen (https-Link). Ein gesetzter `TESTFLIGHT_URL` erzeugt zusätzlich „Beta über TestFlight testen“. Es gibt keine neue Umgebungsvariable.

**Externe Links.** Nur `https://www.dwd.de` (Quelle) als `<a href>`; Bilder und CSS sind immer `'self'`. `/robots.txt` existiert im Dienst nicht (404, unverändert). Footer-Links: Datenschutz, Support, Mehr über Showers (`/marketing`), Sprache. Ein Impressum fehlt noch: die Anbieterangaben stehen im Abschnitt „Verantwortlicher“ von `/datenschutz`; ob eine eigene Impressum-Seite rechtlich nötig ist, muss der Betreiber klären.

## Inhalt der Datenschutzseite

Zwölf Abschnitte: Verantwortlicher, Überblick, Radarkarte und Radar-Dienst, Direktabruf beim DWD, Standort und gespeicherte Orte, Kartenansicht und Ortssuche (Apple), lokale Einordnung, Betriebsstatistik (aggregiert, personenlos, Tageszähler 30 Tage, Stundenzähler 72 Stunden), Betreiber-Diagnose (nur Testversionen, freiwillig, Koppelcode, gespeichert: Zuordnung, Bezeichnung, Zeitpunkte, 48-Stunden-Ereignisverlauf, bis Widerruf; der Apple-Nachweis wird geprüft, nicht gespeichert), keine Debuglogs mit Personenbezug, Rechte, Quellen. Die Seite gibt es nur auf Deutsch; die Landingpage (`/`, `/en`) nennt Statistik und Diagnose in einer Zeile. Abschnitt 6 nennt, dass die Basiskarte und die Ortssuche Apple MapKit nutzen, dass Suchtext und ein fester Suchbereich (Deutschland, nicht der Standort) samt IP-Adresse an Apple gehen, dass der Suchtext weder Radar-Dienst noch DWD erreicht und dass gewählte Punkte nur lokal gespeichert werden. Für Apples Verarbeitung verweist er ohne Link auf deren Datenschutzbestimmungen. Grundlage ist der Diagnosebericht des App-Repos (Datenflüsse im Code belegt; Kachelabruf und Apples Praxis nicht geprüft).

## Konfiguration

Alle Angaben zum Verantwortlichen kommen aus Umgebungsvariablen; im Repository steht nichts davon. Eintrag in der `.env` auf dem Server (Vorlage: `.env.example`), danach `update.sh` ausführen, damit die Replikate die Werte erhalten. Die `.env` wird von der Shell gelesen: Werte mit Leerzeichen in doppelte Anführungszeichen setzen, ohne `$`, Backticks und doppelte Anführungszeichen im Wert.

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `OPERATOR_NAME` | für `/datenschutz` | Name des Verantwortlichen |
| `OPERATOR_ADDRESS` | für `/datenschutz` | Anschrift; ein wörtliches `\n` wird zum Zeilenumbruch |
| `OPERATOR_EMAIL` | für `/datenschutz`, `/support` | Kontakt-E-Mail |
| `PROXY_LOG_NOTE` | empfohlen | Ein Satz des Betreibers, ob und wie lange der vorgeschaltete Reverse Proxy Zugriffe protokolliert. Ohne Wert steht auf der Seite, dass dies noch nicht angegeben ist. |
| `APP_STORE_URL` | optional | `https`-Link, wird auf `/marketing` angezeigt |
| `TESTFLIGHT_URL` | optional | `https`-Link, wird auf `/marketing` angezeigt |

Sind die drei Pflichtwerte nicht gesetzt, zeigt `/datenschutz` sichtbar den Hinweis „Angaben zum Verantwortlichen sind noch nicht konfiguriert“; es wird nichts erfunden. `/healthz` bleibt davon unberührt. Alle Werte werden HTML-escaped; Links werden nur für `https://` ausgegeben. `setup.sh --reconfigure` übernimmt diese Zeilen unverändert in die neue `.env`.

## Rechtlicher Hinweis

Die Texte fassen die technisch belegten Datenflüsse zusammen (Radar-Dienst ohne Zugriffsprotokolle, Proxy, Direktabruf beim DWD, Apple-Karte und Ortssuche über MapKit, Standort nur lokal). Sie sind keine Rechtsberatung. Der Betreiber muss Datenschutzerklärung, Verantwortlichen-Angaben und gegebenenfalls ein Impressum selbst rechtlich prüfen, bevor die URLs in App Store Connect eingetragen werden. Die Rechte der Betroffenen sind nur allgemein genannt (Art. 15 bis 21 DSGVO, Beschwerde bei einer Aufsichtsbehörde).
