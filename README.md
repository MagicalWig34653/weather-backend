# ShowerNow — Backend

Planungsrepository für die native, datensparsame Regen-App ShowerNow. Aktuelle App-Bundle-ID: `de.linolaske.showernow`; technisches Apple-Projekt und Repository-Namen bleiben Weather beziehungsweise `weather-apple`/`weather-backend`.

Zentraler optionaler Pushdienst mit Swift/Vapor, MariaDB und Docker Swarm. Kein PHP trotz des lokalen PhpstormProjects-Pfads. Backend-Implementierung folgt erst nach einer nutzbaren App. Keine Benutzerkonten, kein Dashboard und kein Self-Hosting-Produkt.

## Status

Stufe 1 (Radar-Cache) ist in Swift implementiert und getestet (Stand siehe Arbeitsstand); sie ersetzt die frühere Python-Fassung. Der Pushdienst (Benachrichtigungen) ist noch nicht umgesetzt. Prüfstand: [Arbeitsstand](docs/status.md).

## Radar-Cache (Stufe 1)

Zweck: Die App soll die Deutschland-Radarkarte schnell und ohne Ortsbezug im Request laden. Ein Dienst holt alle 5 Minuten pro DWD-Lauf alle 25 Slots (Analyse + Vorhersage bis +120 min) als Ganzbild vom DWD-WMS, validiert sie, speichert sie verlustfrei als WebP in MariaDB und liefert sie mit unveränderlichen URLs aus. Die App behält den DWD-Direktweg als Fallback. Dieselbe Pipeline ist die Ingest-Basis für spätere Benachrichtigungen.

Architektur (Details und Begründungen in [decisions.md](docs/decisions.md)):

- Swift 6 mit Vapor 4 (`Sources/radar`), Fachlogik ohne Vapor in `Sources/RadarCore` (Zustand, Ingest, Manifest, API-Logik, Bildpipeline). PNG-Dekodierung mit swift-png (reines Swift), WebP-Lossless über die System-Bibliothek libwebp, MariaDB über mysql-nio/MySQLKit.
- Ein Swarm-Service `radar` (Standard 2 Replikate) plus ein One-Shot-Service `migrate` (`radar migrate --yes`). Jedes Replikat liefert die HTTP-API und nimmt am Ingest teil; Migrationen laufen nicht beim Start der Replikate.
- Gemeinsamer Zustand in der vorhandenen MariaDB (InnoDB): `radar_run` (Lauf, Status, Lease), `radar_slot` (WebP-Bytes, SHA-256). Ein Lauf wird per Claim-Zeile (atomar, Lease, Übernahme bei Absturz) nur von einem Replikat geholt; Veröffentlichung = Statuswechsel auf `published` nach allen 25 Slots.
- Cache im Stack: prozesslokaler LRU je Replikat (Standard 64 MB) mit Single-Flight bei Misses; die DB wird nur bei Cache-Miss gelesen. Der Reverse Proxy reicht nur durch (TLS, Domain, Routing). Kein Redis.
- Keine Cookies, keine Sticky Sessions: Replikate sind stateless; das Swarm-Routing-Mesh verteilt per Round-Robin.

### URL-Vertrag (für die App, unverändert gegenüber der früheren Python-Stufe)

- `GET /v1/radar/latest.json`: `Cache-Control: public, max-age=30, stale-while-revalidate=30`, ETag, bei allen Replikaten byteidentisch. 404, solange noch nichts veröffentlicht ist.
- `GET /v1/radar/history.json` (neu, additiv): Schema 1 mit `run`, `generated_at`, `step_minutes` (5), `history_hours`, `image` (identisch zu `latest.json`), `slots[]` (nur `kind: analysis`, aufsteigend, Lücken erlaubt, `path` relativ zu `/v1/radar/`), `attribution`, `modification_notice`. `Cache-Control: public, max-age=60, stale-while-revalidate=60`, ETag, bei allen Replikaten byteidentisch, 404 solange nichts veröffentlicht ist. `latest.json` bleibt byte-kompatibel.
- Konfiguration: `HISTORY_HOURS` (Standard 48, 1-72) bestimmt, wie lange Analyse-Slots aufbewahrt und ausgeliefert werden; fehlende Slots holt ein Leader-Replikat langsam aus der DWD-WMS-Historie nach (siehe Dokumentationsseite „Betrieb“).
- `GET /v1/radar/<run>/<slot>.webp`: `Cache-Control: public, max-age=31536000, immutable`, ETag (SHA-256), `If-None-Match` ergibt 304. `<run>` und `<slot>` haben die Form `20261030T1105Z` (UTC).
- `GET /healthz`: Liveness, nur intern für den Healthcheck.
- `GET /datenschutz`, `GET /marketing`, `GET /support`: statische, selbst enthaltene HTML-Seiten (Datenschutzerklärung, Produktseite, Support) für App Store Connect/TestFlight; `Cache-Control: public, max-age=3600`, ETag, Sicherheits-Header, keine Cookies. Angaben zum Verantwortlichen nur per Umgebungsvariablen (`OPERATOR_NAME`, `OPERATOR_ADDRESS`, `OPERATOR_EMAIL`, `PROXY_LOG_NOTE`, optional `APP_STORE_URL`, `TESTFLIGHT_URL`); fehlen sie, zeigt `/datenschutz` einen Hinweis. Details: Dokumentationsseite „Datenschutz und Marketing-Seiten“.

`latest.json` (Schema 1): `run`, `reference_time`, `generated_at` (Veröffentlichungszeit), `step_minutes` (5), `forecast_horizon_minutes` (120), `image` (`format`, `width` 1024, `height` 1311, `projection` EPSG:3857, `bbox` in Metern, `bbox_wgs84`), `slots[]` mit `time`, `kind` (`analysis` oder `forecast`) und `path` (relativ zu `/v1/radar/`, enthält bis zu 12 frühere Analysen aus älteren Läufen plus die 25 Slots des Laufs), `attribution`, `modification_notice`. Die App fällt bei Fehler oder Datenalter über 20 Minuten auf den DWD-Direktweg zurück.

### Entwicklung und Tests

Swift 6.2 oder neuer, `libwebp-dev` und `pkg-config` (macOS: `brew install webp`, Linux: `apt install libwebp-dev pkg-config`). Die Tests laufen ohne Datenbank gegen einen Fake; mit `RADAR_TEST_DB_HOST` zusätzlich gegen eine WEGWERF-MariaDB:

```
swift build
swift test                                                         # Fake, ohne Datenbank
docker compose up -d --wait db                                     # lokale MariaDB 12.3 (compose.yaml)
RADAR_TEST_DB_HOST=127.0.0.1 RADAR_TEST_DB_PORT=23306 RADAR_TEST_DB_USER=root \
  RADAR_TEST_DB_PASSWORD=dev-root-only RADAR_TEST_DB_NAME=showernow swift test
docker compose --profile app up --build                            # ganzer Dienst lokal (Port 28090)
```

Die MariaDB-Tests löschen die Tabellen `radar_*` und `schema_migration` in `RADAR_TEST_DB_NAME` (Standard `radar_test`); niemals gegen die Produktionsdatenbank verwenden. Kein Test greift auf den DWD zu. Unter macOS bauen die Tests ebenfalls; die CI nutzt `swift:6.2-noble`.

### Optionaler Pushdienst

Standardmäßig aus (`PUSH_ENABLED=false`). Registrierungs-API `/v1/push/…` (Opt-in je Ort, nur Rasterzelle, keine Koordinaten), Auswertung nach jedem Radarlauf (Regel „Regen beginnt in N Minuten“) und APNs-Versand nur durch den Leader `push`. Beschreibung: Dokumentationsseite API und Installation, Entscheidungen in `docs/decisions.md`. Der APNs-Versand ist nur gegen einen Fake geprüft.

### Deployment (Docker Swarm)

Voraussetzung (nicht Teil dieses Repos): Swarm, MariaDB mit Datenbank und Benutzer, Reverse Proxy mit TLS und Domain. Der DB-Benutzer braucht SELECT/INSERT/UPDATE/DELETE sowie CREATE auf dem Schema (der Migrationsjob nutzt denselben Benutzer; die Replikate führen selbst keine Migrationen aus).

1. Einmalig: das ghcr.io-Paket `weather-backend-radar` nach dem ersten Lauf von `docker-publish.yml` auf öffentlich stellen.
2. Auf einem Swarm-Manager (nur Deploy-Dateien, nicht das ganze Repo): `git clone --depth 1 --branch deploy https://github.com/MagicalWig34653/weather-backend.git radar && cd radar && deploy/swarm/setup.sh`. Der Branch `deploy` wird per `.github/workflows/deploy-branch.yml` aus `main` gespiegelt. Der Assistent prüft Voraussetzungen, fragt alle Werte ab (oder liest `--answers-file`, `--non-interactive`, `--dry-run`), prüft die DB-Verbindung, schreibt `.env` (Modus 600, nicht versioniert), legt das Secret `showernow_db_password` an, führt den Migrationsjob aus, startet die Replikate und prüft die Erreichbarkeit.
3. Updates: `deploy/swarm/update.sh` (mit `--pull-scripts` zuerst `git pull --ff-only` für neue Skripte). Es ermittelt das neueste `sha-<commit>`-Tag hinter `edge` auf ghcr.io (oder `--tag`), sichert `.env` als `.env.bak`, führt den Migrationsjob mit dem neuen Image aus und startet das Rolling Update (start-first, Rollback bei fehlgeschlagenem Healthcheck); `deploy/swarm/swarm-deploy.sh` hält dabei eine Deployment-Sperre als Swarm-Config. Rückgängig: `docker service rollback radar_radar` oder `update.sh --tag <vorheriges Tag>`.
4. Reverse Proxy: Upstream auf den Ingress-Port (Standard 38090).

Das Image heißt fest `ghcr.io/magicalwig34653/weather-backend-radar` (Tags: `edge` und `latest` für `main`, `sha-<commit>`, Version bei `v*`-Tags); amd64 und arm64 werden nativ gebaut. Alle Variablen der `.env`: `.env.example`.

### Konfiguration

Nur Umgebungsvariablen (`.env` für den Stack) und das Swarm-Secret. Das DB-Passwort ist ausschließlich das Secret (`DB_PASSWORD_FILE`). Der Radar-Dienst selbst führt keine Zugriffsprotokolle und speichert keine IP-Adressen oder Abfragedetails; Logs enthalten nur Lauf-IDs und Fehlerklassen. Ein vorgeschalteter Reverse Proxy sieht technisch bedingt die IP-Adresse jedes Abrufs. Ob und wie lange er protokolliert, bestimmt der Betreiber (bei Zoraxy die Einstellung der Zugriffslogs prüfen und gegebenenfalls abschalten oder kurz halten).

### Datenschutz und Quellen

Requests enthalten keinen Ortsbezug: feste Pfade je Lauf/Slot, Ganzbild für Deutschland; keine Cookies; der Radar-Dienst führt keine Zugriffsprotokolle mit IP-Adressen oder Abfragedetails (Proxy: siehe Konfiguration). Die Anfragen an den DWD enthalten nur Layer, Zeit und feste Deutschland-BBox.

Quelle: Deutscher Wetterdienst. Die Bilder sind aus DWD-Rasterdaten (WMS `dwd:Niederschlagsradar`) bildlich wiedergegeben und verlustfrei in WebP umgewandelt (Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben); der Vermerk steht im Manifest und muss in der App an der Karte sichtbar bleiben. Lizenz der Daten: CC BY 4.0 / GeoNutzV. Der DWD sichert keine Verfügbarkeit zu.

## Einstieg

- [Dokumentationsseite mit Installationsanleitung](https://magicalwig34653.github.io/weather-backend/) ([Aufbau](docs/pages.md))
- [Entwicklungsplan](docs/plan.md)

- [Arbeitsstand und nächste Schritte](docs/status.md)

- [Aktuelle Entscheidungen und Roadmap](docs/decisions.md)
- [Ursprüngliches Konzept v2](docs/concept-v2.md)
- [Arbeitsanweisungen für Coding-Agenten](AGENTS.md)
- [Claude-Code-Einstieg](CLAUDE.md)

Die Apple-App wird zuerst entwickelt und intern über TestFlight erprobt. Der Pushdienst folgt danach. Schwesterrepository: [weather-apple](https://github.com/MagicalWig34653/weather-apple); aktueller App- und TestFlight-Stand im dortigen [Arbeitsstatus](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md).

## Lizenz

Open Source unter AGPLv3 ist vorgesehen. Die endgültige Lizenzfreigabe und die Vereinbarkeit mit der vorgesehenen App-Store-Veröffentlichung stehen noch aus. Derzeit ist keine Lizenz erteilt; insbesondere bedeutet ein öffentliches Repository allein keine Nutzungserlaubnis.
