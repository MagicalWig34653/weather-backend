# ShowerNow — Backend

Planungsrepository für die native, datensparsame Regen-App ShowerNow. Aktuelle App-Bundle-ID: `de.linolaske.showernow`; technisches Apple-Projekt und Repository-Namen bleiben Weather beziehungsweise `weather-apple`/`weather-backend`.

Zentraler optionaler Pushdienst mit Swift/Vapor, MariaDB und Docker Swarm. Kein PHP trotz des lokalen PhpstormProjects-Pfads. Backend-Implementierung folgt erst nach einer nutzbaren App. Keine Benutzerkonten, kein Dashboard und kein Self-Hosting-Produkt.

## Status

Stufe 1 (Radar-Cache) ist implementiert und lokal getestet, aber noch nicht auf dem Swarm des Betreibers ausgeführt. Der Pushdienst (Benachrichtigungen) ist noch nicht umgesetzt. Prüfstand: [Arbeitsstand](docs/status.md).

## Radar-Cache (Stufe 1)

Zweck: Die App soll die Deutschland-Radarkarte schnell und ohne Ortsbezug im Request laden. Ein Dienst holt alle 5 Minuten pro DWD-Lauf alle 25 Slots (Analyse + Vorhersage bis +120 min) als Ganzbild vom DWD-WMS, validiert sie, speichert sie verlustfrei als WebP in MariaDB und liefert sie mit unveränderlichen URLs aus. Die App behält den DWD-Direktweg als Fallback. Dieselbe Pipeline ist die Ingest-Basis für spätere Benachrichtigungen.

Architektur (Details und Begründungen in [decisions.md](docs/decisions.md)):

- Ein Swarm-Service `radar`, Standard 2 Replikate (konfigurierbar), Python 3.13 mit Pillow und PyMySQL. Jedes Replikat liefert die HTTP-API und nimmt am Ingest teil.
- Gemeinsamer Zustand in der vorhandenen MariaDB (InnoDB): `radar_run` (Lauf, Status, Lease), `radar_slot` (WebP-Bytes, SHA-256). Ein Lauf wird per Claim-Zeile (atomar, Lease, Übernahme bei Absturz) nur von einem Replikat geholt; Veröffentlichung = Statuswechsel auf `published` nach allen 25 Slots.
- Cache im Stack: prozesslokaler LRU je Replikat (Standard 64 MB) mit Single-Flight bei Misses; die DB wird nur bei Cache-Miss gelesen. Der Reverse Proxy (Zoraxy) reicht nur durch (TLS, Domain, Routing); HTTP/2 und Kompression kommen vom Proxy, die Bilder sind bereits komprimiert. Ein optionaler nginx-Cache-Sidecar ist für spätere Last vorgesehen, aber nicht Teil von Stufe 1. Ein CDN vor Zoraxy würde dank `immutable` ohne Änderung funktionieren.
- Keine Cookies, keine Sticky Sessions: Replikate sind stateless; das Swarm-Routing-Mesh verteilt per Round-Robin (Zoraxy nutzt den Service oder Knoten als Upstream ohne Session-Affinität). Kein Redis.

### URL-Vertrag (für die App)

- `GET /v1/radar/latest.json`: `Cache-Control: public, max-age=30, stale-while-revalidate=30`, ETag, bei allen Replikaten identisch. 404, solange noch nichts veröffentlicht ist.
- `GET /v1/radar/<run>/<slot>.webp`: `Cache-Control: public, max-age=31536000, immutable`, ETag (SHA-256), `If-None-Match` ergibt 304. `<run>` und `<slot>` haben die Form `20261030T1105Z` (UTC).
- `GET /healthz`: Liveness, nur intern für den Healthcheck.

`latest.json` (Schema 1): `run`, `reference_time`, `generated_at` (Veröffentlichungszeit), `step_minutes` (5), `forecast_horizon_minutes` (120), `image` (`format`, `width` 1024, `height` 1311, `projection` EPSG:3857, `bbox` in Metern, `bbox_wgs84`), `slots[]` mit `time`, `kind` (`analysis` oder `forecast`) und `path` (relativ zu `/v1/radar/`, enthält bis zu 12 frühere Analysen aus älteren Läufen plus die 25 Slots des Laufs), `attribution`, `modification_notice`. Die App fällt bei Fehler oder Datenalter über 20 Minuten auf den DWD-Direktweg zurück.

### Entwicklung und Tests

```
cd ingest
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/ruff check .
.venv/bin/python -m unittest discover -s . -t .            # ohne Datenbank: Fakes
RADAR_TEST_DB_PORT=3306 .venv/bin/python -m unittest discover -s . -t .   # zusätzlich gegen eine WEGWERF-MariaDB
```

Die MariaDB-Tests löschen die Tabellen `radar_*` und `schema_migration` der Schema-Variable `RADAR_TEST_DB_NAME` (Standard `radar_test`, Benutzer `RADAR_TEST_DB_USER`/`RADAR_TEST_DB_PASSWORD`); niemals gegen die Produktionsdatenbank verwenden. Kein Test greift auf den DWD zu.

### Deployment (Docker Swarm)

Voraussetzung (nicht Teil dieses Repos): Swarm, MariaDB mit Datenbank und Benutzer (DML + CREATE auf dem Schema), Reverse Proxy mit TLS und Domain.

1. GitHub: Nach dem ersten Lauf von `docker-publish.yml` das Paket `<repository>-radar` unter ghcr.io auf öffentlich stellen (oder auf dem Swarm `docker login ghcr.io` verwenden und `--with-registry-auth` ergänzen). Repo-Einstellungen: Actions mit Schreibrecht auf Packages für `GITHUB_TOKEN` zulassen.
2. Auf einem Swarm-Manager: `deploy/swarm/setup.sh` (schreibt `deploy/swarm/stack.env` aus `stack.env.example`, legt das Secret `showernow_db_password` an). `stack.env` anpassen (`DB_HOST`, `RADAR_IMAGE`).
3. `deploy/swarm/update.sh --tag sha-<commit>` (oder ohne `--tag` für `latest`) führt `docker stack deploy` aus, beobachtet das Rolling Update (start-first, Rollback bei fehlgeschlagenem Healthcheck). Rückgängig: `docker service rollback radar_radar` oder erneut mit dem vorherigen Tag.
4. Reverse Proxy: Upstream auf den Service-Port (Standard 38090) des Swarm; Beispiel-Labels stehen auskommentiert in `stack.yaml`.

Migrationen (`ingest/migrations/*.sql`, nur additiv) wendet jedes Replikat beim Start unter einem MariaDB-Advisory-Lock an. Images: amd64 und arm64 (Annahme, da die Swarm-Architektur unbekannt ist).

### Konfiguration

Nur Umgebungsvariablen und Swarm-Secrets, siehe `deploy/swarm/stack.env.example`. Das DB-Passwort ist ausschließlich das Secret (`DB_PASSWORD_FILE`). Es werden keine Zugriffslogs geschrieben; Logs enthalten nur Lauf-IDs und Fehlerklassen.

### Datenschutz und Quellen

Requests enthalten keinen Ortsbezug: feste Pfade je Lauf/Slot, Ganzbild für Deutschland; keine Cookies, keine Zugriffsprotokolle mit IP/Query. Die Anfragen an den DWD enthalten nur Layer, Zeit und feste Deutschland-BBox.

Quelle: Deutscher Wetterdienst. Die Bilder sind aus DWD-Rasterdaten (WMS `dwd:Niederschlagsradar`) bildlich wiedergegeben und verlustfrei in WebP umgewandelt (Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben); der Vermerk steht im Manifest und muss in der App an der Karte sichtbar bleiben. Lizenz der Daten: CC BY 4.0 / GeoNutzV. Der DWD sichert keine Verfügbarkeit zu.

## Einstieg

- [Entwicklungsplan](docs/plan.md)

- [Arbeitsstand und nächste Schritte](docs/status.md)

- [Aktuelle Entscheidungen und Roadmap](docs/decisions.md)
- [Ursprüngliches Konzept v2](docs/concept-v2.md)
- [Arbeitsanweisungen für Coding-Agenten](AGENTS.md)
- [Claude-Code-Einstieg](CLAUDE.md)

Die Apple-App wird zuerst entwickelt und intern über TestFlight erprobt. Der Pushdienst folgt danach. Schwesterrepository: [weather-apple](https://github.com/MagicalWig34653/weather-apple); aktueller App- und TestFlight-Stand im dortigen [Arbeitsstatus](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md).

## Lizenz

Open Source unter AGPLv3 ist vorgesehen. Die endgültige Lizenzfreigabe und die Vereinbarkeit mit der vorgesehenen App-Store-Veröffentlichung stehen noch aus. Derzeit ist keine Lizenz erteilt; insbesondere bedeutet ein öffentliches Repository allein keine Nutzungserlaubnis.
