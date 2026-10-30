# Datenschutz und Marketing-Seiten

Der Radar-Dienst liefert zusätzlich drei kleine, öffentliche HTML-Seiten, die ShowerNow für App Store Connect und TestFlight braucht. Sie sind in den Dienst eingebaut (`Sources/RadarCore/SitePages.swift`), brauchen weder Datenbank noch Zusatzdienste und bleiben ohne Konfiguration funktionsfähig.

## Endpunkte

| Pfad | Inhalt | Verwendung in App Store Connect |
|---|---|---|
| `/datenschutz` | Datenschutzerklärung der App und des Radar-Dienstes | Datenschutz-URL (`https://showernow.linolaske.de/datenschutz`) |
| `/marketing` | Kurze Produktseite mit Funktionen, Status und Quellenangabe | Marketing-URL (`https://showernow.linolaske.de/marketing`) |
| `/support` | Kontakt-E-Mail und Link auf GitHub-Issues | Support-URL (`https://showernow.linolaske.de/support`) |

Die Seiten sind selbst enthalten (kein externes JavaScript, CSS oder Fonts; helles und dunkles Layout inline), werden mit `Content-Type: text/html; charset=utf-8`, `Cache-Control: public, max-age=3600`, ETag (`If-None-Match` ergibt `304`) und Sicherheits-Headern ausgeliefert (`X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, restriktive `Content-Security-Policy`). `HEAD` funktioniert; es gibt keine Cookies und, wie bei allen Routen, keine Zugriffsprotokolle. `/v1/radar/*` und `/healthz` bleiben unverändert.

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

Die Texte fassen die technisch belegten Datenflüsse zusammen (Radar-Dienst ohne Zugriffsprotokolle, Proxy, Direktabruf beim DWD, Standort nur lokal). Sie sind keine Rechtsberatung. Der Betreiber muss Datenschutzerklärung, Verantwortlichen-Angaben und gegebenenfalls ein Impressum selbst rechtlich prüfen, bevor die URLs in App Store Connect eingetragen werden. Die Rechte der Betroffenen sind nur allgemein genannt (Art. 15 bis 21 DSGVO, Beschwerde bei einer Aufsichtsbehörde).
