# Dashboard-Plan: Statistik, Traffic und Konfiguration

Stand: 3. November 2026. Status: Plan, noch keine Umsetzung. Board: Todolino-Aufgabe „Dashboard für Cache Hits, Statistiken und Traffic Analyse. Zugriff über einen zweiten Port“ mit je einer Unteraufgabe je Arbeitspaket (Abschnitt 11).

Nutzerentscheidungen (3.11.2026): eigene Webseite mit SvelteKit (statischer Build) und shadcn-svelte; Login per Passkey (WebAuthn), keine Benutzerverwaltung (genau ein Betreiber); zweiter Listener/Port, intern, standardmäßig aus; statischer Build im Backend-Image eingebettet; erster Passkey per fester Registrierung nur beim ersten Start ohne Token; Statistik: 30 Tage Tagesaggregate, nur Zähler ohne IPs, Koordinaten, Installations-IDs, Tokens; Konfiguration im Dashboard mit Rangfolge ENV > Dashboard-Wert (DB) > Default, Geheimnisse nur per ENV, Änderungsprotokoll, serverseitige Grenzen, CSRF. Alle Board-Fragen sind beantwortet (3.11.2026): Zugriff über den vorhandenen internen Reverse Proxy des Betreibers (Dienst `dashboard` im Overlay-Netz, kein Host-Port, kein Ingress; der Proxy terminiert TLS, der Betreiber muss im Repo nichts dafür tun); Einstellungen mit Neustartbedarf: Dashboard-Knopf für einen kontrollierten Neustart (Abschnitt 5.3, ohne Docker-Socket); Aufbewahrung 30 Tage Tagesaggregate; erster Passkey per fester Registrierung ohne Token; Auslieferung als statischer Build im Backend-Image.

## 1. Ziel und Nicht-Ziele

Ziel: Der einzige Betreiber sieht auf einer internen Webseite Cache-Treffer, Anfragen je Route und Status, Traffic über 30 Tage und ändert nicht geheime Backend-Einstellungen sicher.

Nicht-Ziele:

- Keine Benutzerverwaltung, keine Rollen, keine Registrierung weiterer Personen.
- Keine personenbezogenen Daten in der Statistik: keine IPs, Koordinaten, Installations-IDs, Tokens, keine rohen Pfade. Keine Zugriffsprotokolle (bleibt wie im Radar-Dienst).
- Keine Echtzeit-Streams, kein Alerting, keine externen Dienste (kein Prometheus/Grafana, keine CDN-Assets, keine Analyse-SDKs).
- Keine Geheimnisse im Dashboard (APNs-Key, DB-Passwort), keine Anzeige oder Speicherung.
- Kein Docker-Socket und keine Swarm-API im Dashboard; der Neustart-Knopf arbeitet nur über eine Konfigurations-Generation in der Datenbank (Abschnitt 5.3). Keine Änderung von DB-, Listener- und Dashboard-Bootstrap-Werten.
- Kein öffentlicher Zugriff, kein Ingress, kein veröffentlichter Host-Port für das Dashboard.

## 2. Architektur

### 2.1 Listener

- Zweiter Vapor-Listener in derselben Binärdatei, nur bei `DASH_ENABLED=true` (Standard `false`). Port `DASH_PORT` (Standard 9090), Bindung im Container `0.0.0.0`; Erreichbarkeit regelt Deploy (Abschnitt 9), nicht der Code. Der Port wird nirgends veröffentlicht: Zugriff nur aus dem Overlay-Netz über den vorhandenen internen Reverse Proxy des Betreibers (terminiert TLS und leitet an `dashboard:9090` weiter).
- Umsetzung vorgeschlagen als zweite `Application`-Instanz (Vapor bindet je Application einen HTTP-Server); WP5 prüft das gegen die Vapor-Version 4.122 und fällt sonst auf einen eigenen NIO-Server zurück. Nicht belegt, daher Prüfpunkt.
- Eigener Befehl `radar dashboard` (nur Dashboard-Listener, keine Ingest-Schleifen) neben `radar serve`. `serve` startet den Listener nur mit `DASH_ENABLED=true`. Empfehlung für Produktion: eigener Swarm-Dienst `dashboard` mit einem Replikat (Overlay `stack.dashboard.yaml`, Muster wie `stack.push.yaml`); die öffentlichen `radar`-Replikate behalten `DASH_ENABLED=false` und enthalten keinen aktiven Dashboard-Listener. Vorteil: exakte In-Memory-Rate-Limits, kleinere Angriffsfläche. Entschieden (3.11.2026): eigener Dienst `dashboard`, Zugriff über den vorhandenen internen Reverse Proxy.
- Fail-closed: Mit `DASH_ENABLED=true` verweigert der Start ohne `DASH_ORIGIN` (z. B. `https://dash.example.internal`). Aus `DASH_ORIGIN` werden WebAuthn-Origin und RP-ID (Host) sowie die erlaubte `Host`-Kopfzeile abgeleitet (Schutz gegen DNS-Rebinding). `DASH_RP_ID` ist optional und überschreibt nur die RP-ID (muss ein Domain-Suffix des Origin-Hosts sein); beides kommt ausschließlich aus der Konfiguration (ENV), nie aus Anfragen. Der Proxy muss `Host` unverändert durchreichen (oder der Betreiber setzt `DASH_ORIGIN` auf die öffentliche interne Adresse); `X-Forwarded-*` werden nicht ausgewertet.
- Der öffentliche Listener bleibt unverändert: `/dash` dort immer 404.

### 2.2 Routen

Alle JSON-Routen unter `/dash/api`, JSON-only (`Content-Type: application/json` bei Schreibzugriffen), `Cache-Control: no-store`.

| Methode, Pfad | Zweck | Auth |
|---|---|---|
| GET `/dash/api/session` | Zustand `setup_open`, `login` oder `authenticated`; bei Anmeldung das CSRF-Token | keine |
| POST `/dash/api/setup/begin`, `/setup/finish` | erster Passkey (Abschnitt 2.4) | nur solange offen |
| POST `/dash/api/login/begin`, `/login/finish` | Anmeldung mit Passkey | keine |
| POST `/dash/api/logout` | Sitzung beenden | Sitzung + CSRF |
| GET `/dash/api/stats/overview` | Cache-Quote, Gauges, Ebenenstatus | Sitzung |
| GET `/dash/api/stats/daily?days=30&metric=` | Tagesreihen | Sitzung |
| GET `/dash/api/config` | Register mit Wert, Quelle, Sperre | Sitzung |
| PUT `/dash/api/config/{key}`, DELETE `/dash/api/config/{key}` | Wert setzen bzw. auf Default zurück | Sitzung + CSRF |
| GET `/dash/api/config/audit?limit=` | Änderungsprotokoll | Sitzung |
| GET `/dash/api/restart` | Stand `config_generation`, `applied_generation` je Replikat, Liste der offenen `restart`-Schlüssel | Sitzung |
| POST `/dash/api/restart` | kontrollierten Neustart anfordern (Generation erhöhen), Abschnitt 5.3 | Sitzung + CSRF + Bestätigung |
| GET `/dash/**` | statische Dateien, Fallback `index.html` | keine (nur öffentliche Build-Artefakte) |

Antwortformen werden vor Beginn von WP5/WP7 in `docs-site/content/dashboard-api.md` (Teil von WP5) festgeschrieben; Eintrag in `GET /dash/api/config`: `key`, `group`, `type`, `default`, `min`, `max`, `unit`, `description`, `apply` (`live`|`restart`), `source` (`env`|`dashboard`|`default`), `locked` (bei `env`), `value`, `restart_pending`. Geheimnisse und ENV-only-Schlüssel erscheinen nie mit Wert (nur Name, `source: env`, `value: null` für Geheimnisse).

### 2.3 Statische Auslieferung

- Build-Artefakte liegen im Image unter `/app/dashboard` (aus dem Node-Build-Stage kopiert, Abschnitt 6.3). Der Server liest sie aus dem Dateisystem, nicht aus dem Netz.
- Eigener, kleiner Handler: Pfad normalisieren, `..`, Null-Bytes und absolute Pfade ablehnen, nur Dateien unterhalb des Wurzelverzeichnisses, `nosniff`. Hashbenannte Assets `immutable`, `index.html` `no-cache`. Unbekannte Pfade ohne Dateiendung liefern `index.html` (SPA-Fallback), mit Dateiendung 404.
- Sicherheitsköpfe auf allen Antworten: CSP (Abschnitt 6.4), `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Resource-Policy: same-origin`.

### 2.4 Passkey/WebAuthn

Bibliotheksvergleich (geprüft am 3.11.2026 über GitHub-API und Paketmanifest):

| Option | Befund | Bewertung |
|---|---|---|
| `swift-server/webauthn-swift` (alt) | letzter Tag 0.0.3 (Juli 2023), Tools-Version 5.6, früher als „proof of concept, nicht produktiv“ gekennzeichnet; im Swift Package Index als entfernt geführt ([ecosyste.ms](https://packages.ecosyste.ms/registries/swiftpackageindex.com/packages/github.com%2Fswift-server%2Fwebauthn-swift)) | nicht verwenden |
| `swift-server/swift-webauthn` (Nachfolger) | Lizenz Apache-2.0, nicht archiviert, letzter Commit 7.10.2026, jüngstes Release `1.0.0-beta.1` (3.11.2025, Vorabversion), `Package.swift` mit `swift-tools-version: 6.0`, Abhängigkeiten SwiftCBOR 0.4.7, swift-crypto `3.8.1..<6.0.0`, swift-log ([Repo](https://github.com/swift-server/swift-webauthn), Manifest `main`) | Empfehlung |
| eigene Minimal-Prüfung mit swift-crypto | nur Attestation `none`, ES256 (P-256), Challenge/Origin/RP-ID/Flags/Zähler selbst prüfen; etwa 300 Zeilen | Rückfall, falls die Beta-API nicht trägt |

Entscheidung im Plan: `swift-webauthn` exakt auf `1.0.0-beta.1` pinnen (`exact:`), `Package.resolved` einchecken. Swift-6-Strikt-Concurrency-Tauglichkeit ist wegen des Manifests mit Tools 6.0 plausibel, aber nicht gemessen: WP4 prüft es per Build im Projekt (`swift build` unter Swift 6.2) vor dem Aufbau darauf. swift-crypto ist im Projekt bereits `from: 3.0.0`; die Auflösung gegen `3.8.1..<6.0.0` prüft WP4.

Parameter: Attestation `none`, `userVerification: required`, Resident Key bevorzugt, Algorithmus ES256 (-7), `rp.id` aus `DASH_ORIGIN`, ein fester Benutzer-Handle (`operator`, kein Name, keine E-Mail). Zähler (`sign_count`) bei jeder Anmeldung prüfen und speichern; Rückgang führt zur Ablehnung und einer Log-Meldung.

Challenges liegen in der Datenbank (`dashboard_challenge`, Einmalverwendung, 5 Minuten gültig), nicht im Speicher: begin und finish können bei mehreren Replikaten verschiedene Prozesse treffen.

**Erster Passkey (Entscheidung: feste Registrierung ohne Token), Gegenmaßnahmen:**

1. Registrierung nur, solange keine Zeile in `dashboard_credential` existiert; die Prüfung und das Einfügen laufen atomar (feste Primärschlüssel-Zeile, Doppelregistrierung scheitert am Schlüssel mit 409).
2. Nur auf dem Dashboard-Listener (nie auf dem öffentlichen Port).
3. Zeitfenster: offen für `DASH_SETUP_WINDOW_MINUTES` (Standard 15, 0 = nie) ab Prozessstart. Danach nur durch Neustart des Dashboards erneut offen, wenn weiterhin kein Passkey existiert.
4. Rate-Limit auf `setup/begin` und `setup/finish` (global, z. B. 10 pro Minute).
5. Deutliche Log-Meldung: beim Start und jede Minute solange offen („Dashboard-Einrichtung OFFEN: erster Passkey ohne Token möglich, noch N Minuten“); bei Erfolg („Passkey registriert, Einrichtung geschlossen“). Beides ohne IP.
6. Host-/Origin-Prüfung wie bei allen Routen.
7. Notfall-Befehl `radar dashboard-reset --yes` (Muster `migrate --yes`): löscht Passkey und Sitzungen, schreibt einen Audit-Eintrag; danach öffnet sich das Fenster beim nächsten Start. Wer den Befehl ausführen kann, hat bereits Datenbank- und Server-Zugriff.

Restrisiko (bewusst akzeptiert, dokumentiert): Wer das interne Netz erreicht und schneller als der Betreiber ist, kann den ersten Passkey registrieren. Deshalb gilt die Betriebsregel: Dashboard erst starten, wenn der Betreiber sofort registriert; direkt nach der Registrierung Log prüfen. Den Passkey-Namen/die Registrierungszeit zeigt die Seite „Sitzung“, damit eine Fremdregistrierung auffällt.

### 2.5 Sitzungen und Cookies

- Cookie `__Host-dash_session`: `Secure; HttpOnly; SameSite=Strict; Path=/`, ohne `Domain`. Wert: 32 Zufallsbytes (swift-crypto `SystemRandomNumberGenerator` bzw. `SymmetricKey`), in der DB nur als SHA-256 (`dashboard_session.id_hash`).
- Laufzeit: absolut 12 Stunden (`DASH_SESSION_HOURS`, 1 bis 24), Leerlauf 30 Minuten (`DASH_IDLE_MINUTES`, 5 bis 240); bei Anmeldung neue Sitzungs-ID, alte Sitzungen bleiben (Einzelbetreiber), Abmeldung löscht.
- Hinweis: `__Host-` verlangt `Secure`; Safari akzeptiert `Secure`-Cookies nicht über `http://localhost`. Produktiv daher HTTPS-Origin (Abschnitt 9).

### 2.6 CSRF

Dreifach: (1) `SameSite=Strict`; (2) alle Schreibzugriffe nur mit `Content-Type: application/json` und einem `Origin`-Header, der exakt `DASH_ORIGIN` entspricht; (3) pro Sitzung ein CSRF-Token (32 Zufallsbytes, in der DB als Hash), das `GET /dash/api/session` zurückgibt und die Seite im Speicher hält (nicht in Cookie oder `localStorage`) und als `X-CSRF-Token` mitsendet (Vergleich in konstanter Zeit). Fehlt eines, antwortet der Server 403 ohne Details.

### 2.7 Rate-Limits

Wiederverwendung der vorhandenen Klasse `RateLimiter` (`PushApi.swift`), Schlüssel ohne IP: Schlüssel je Endpunkt (`global:`-Schlüssel, nie verdrängt). Vorschlag: `login/begin` 30 pro Minute, `login/finish` 30 pro Minute und zusätzlich 10 Fehlversuche pro Minute (danach 429 für diese Minute), `setup/*` 10 pro Minute, Schreibzugriffe auf Konfiguration 30 pro Minute, alle anderen Routen 600 pro Minute. Bei einem Dashboard-Replikat sind die Grenzen exakt; bei mehreren Prozessen gilt je Prozess. Ein Passkey-Login lässt sich nicht per Raten brechen; die Limits begrenzen CPU und DB-Last. Nachteil ohne IP: ein interner Angreifer kann den Betreiber für eine Minute aussperren (siehe Risiken).

### 2.8 Logging

- Keine Zugriffsprotokolle, keine IPs, keine Pfade mit Nutzerdaten. Strukturierte Ereignisse nur: Einrichtung offen/geschlossen, Anmeldung erfolgreich/fehlgeschlagen (ohne Details), Abmeldung, Konfigurationsänderung (Schlüssel, nicht der Wert geheimer Felder), Rate-Limit ausgelöst (Zähler je Minute, nicht jede Anfrage), Dashboard-Reset.
- Fehlerantworten generisch (`{"error":"code"}`), Datenbankfehler nie nach außen.

## 3. Datenmodell

Neue Migration `migrations/009_dashboard.sql` (idempotent, `CREATE TABLE IF NOT EXISTS`, InnoDB, utf8mb4, Muster der Migrationen 001 bis 008; der Migrationslauf trennt Anweisungen an `;\n`, das gilt auch für 009). Alle Zeiten UTC.

| Tabelle | Spalten (Auszug) | Hinweise |
|---|---|---|
| `dashboard_credential` | `id TINYINT PRIMARY KEY` (fest 1), `credential_id VARBINARY(1024) UNIQUE`, `public_key BLOB`, `sign_count INT UNSIGNED`, `created_at`, `last_used_at` | genau eine Zeile erzwungen; Doppelregistrierung scheitert atomar |
| `dashboard_challenge` | `id BINARY(16) PK`, `kind ENUM('setup','login')`, `challenge VARBINARY(64)`, `expires_at` | Einmalverwendung (Löschen mit Prüfung der betroffenen Zeilen), Aufräumen beim Zugriff |
| `dashboard_session` | `id_hash BINARY(32) PK`, `csrf_hash BINARY(32)`, `created_at`, `last_seen_at`, `expires_at` | nur Hashes; abgelaufene Zeilen beim Zugriff löschen |
| `stats_daily` | `day DATE`, `metric VARCHAR(32)`, `label VARCHAR(48)`, `value BIGINT UNSIGNED`, `PRIMARY KEY (day, metric, label)` | Zähler per `ON DUPLICATE KEY UPDATE value = value + VALUES(value)`; Aufbewahrung 30 Tage |
| `config_override` | `config_key VARCHAR(64) PK`, `value VARCHAR(600)`, `updated_at`, `revision BIGINT` | nur Schlüssel des Registers; Geheimnisse nie |
| `config_generation` | `id TINYINT PK` (fest 1), `generation BIGINT`, `requested_at` | Neustart-Generation (Abschnitt 5.3); Erhöhen per `UPDATE … SET generation = generation + 1` |
| `config_replica` | `replica_id VARCHAR(64) PK`, `applied_generation BIGINT`, `started_at`, `last_seen_at` | je Radar-Replikat eine Zeile (Hostname-Hash, keine Nutzerdaten); nur für die Anzeige des Neustart-Fortschritts; veraltete Zeilen (> 10 min) werden ignoriert und gelöscht |
| `config_audit` | `id BIGINT AUTO_INCREMENT PK`, `at`, `action ENUM('set','reset','restart','login','setup','reset_cli')`, `config_key VARCHAR(64) NULL`, `old_value VARCHAR(200) NULL`, `new_value VARCHAR(200) NULL` | „wer“ ist stets der einzige Betreiber (Passkey); Werte gekürzt; Aufbewahrung 365 Tage (Vorschlag) |

Die fünf Tabellen der Entscheidung plus `dashboard_challenge` (nötig wegen Mehrprozess-Betrieb) sowie `config_generation` und `config_replica` (Neustart-Knopf). Zugriff über ein neues `DashboardRepo`-Protokoll (Datei `DashboardRepo.swift`) mit Implementierungen `MariaRepo+Dashboard.swift` und `MemoryRepo+Dashboard.swift`, Muster wie `PushRepo`.

Betreiber-Texte im Audit (Name, Adresse) sind die öffentlich im Impressum stehenden Angaben; trotzdem werden `OPERATOR_*`-Werte im Audit nur gekürzt und als „geändert“ ohne Volltext gespeichert (Entscheidung im Register: Spalte „Audit-Wert“ `maskiert`).

## 4. Statistik-Erfassung

Gemessen wird ausschließlich im Prozess, mit festen Etiketten (Aufzählungen, keine freien Zeichenketten):

| Metrik | Etiketten | Quelle |
|---|---|---|
| `req` | Route-Klasse × Statusklasse, z. B. `radar_slot:2xx`, `radar_latest:304`, `layer_manifest:2xx`, `push:4xx`, `status`, `healthz`, `site_page`, `other:404` | Wrapper um `Api.handle`/`handlePush` in `main.swift`; unbekannte Pfade immer `other` (keine Kardinalitäts-Bombe, keine Pfaddaten) |
| `bytes` | Route-Klasse | Antwortlänge |
| `cache` | `hit`, `miss_db`, `negative_hit`, `joined_flight` | `SlotCache.load` (Zähler `dbReads` existiert bereits) |
| `limited` | `push_installation`, `push_global`, `push_auth`, `dash_*` | Rate-Limit-Treffer (nur Zähler) |
| `ingest` | `published`, `failed` je Ebene | vorhandene Schleifen, Log-Stellen |

Zähler im Prozess hinter einem `NSLock`-geschützten Wörterbuch (`StatsCounter`, Muster `RateLimiter`), ohne Zeitstempel pro Ereignis. Eine Flush-Schleife (alle 60 s und beim Beenden) schreibt die Deltas in `stats_daily` (Tag = UTC-Datum des Flushs) und setzt sie zurück; schlägt der Flush fehl, bleiben die Deltas erhalten und gehen in den nächsten Versuch (Grenze: 10 000 Etikettenpaare, danach verwerfen und `limited`-Zähler `stats_dropped`). Absturz verliert höchstens etwa eine Minute. Aufräumen: stündlich `DELETE FROM stats_daily WHERE day < UTC_DATE() - INTERVAL 30 DAY` durch jeden Prozess (idempotent).

Mehrere Replikate im Swarm: Jede Replikatsinstanz addiert ihre Deltas direkt per `value = value + …` in dieselbe Zeile; die Aggregation ist reine SQL-Addition, ohne Replikat-ID. Das Dashboard liest nur aus der DB und sieht dadurch die Summe aller Replikate (Verzug höchstens 60 s). Gauges (Installationen, Abos, Outbox-Größe, Ebenenstatus) werden bei Abruf live aus der DB berechnet (kurz gecacht, 5 s), nicht gespeichert. Die Cache-Quote ist `hit / (hit + miss_db + negative_hit)` je Tag.

Grenze: nur Tagesauflösung (Entscheidung). Stundenwerte wären eine Erweiterung (Abschnitt 12).

## 5. Konfigurationsregister

### 5.1 Mechanik

- Ein `ConfigRegistry` (neue Datei `ConfigRegistry.swift`) beschreibt jede Einstellung: Schlüssel, Gruppe, Typ, Default, Grenzen, Einheit, Beschreibung (deutsch), `apply` (`live`/`restart`), `secret`, `envOnly`, Prüfung. Dieselben Prüfungen nutzt `Config.fromEnvironment` (eine Quelle der Wahrheit).
- Rangfolge je Schlüssel: ENV (nicht leer) > `config_override` > Default. Eine leere ENV-Variable zählt als nicht gesetzt.
- **Befund, der Deploy betrifft:** `deploy/swarm/stack.yaml` reicht heute fast alle Variablen immer durch (`CACHE_MAX_MB: ${CACHE_MAX_MB:-64}` usw.). Damit wäre jeder Wert „durch ENV gesetzt“ und das Dashboard wirkungslos. WP8 stellt die änderbaren Schlüssel auf `${KEY:-}` (leerer Standard); `Config.fromEnvironment` behandelt leer als nicht gesetzt (heute würde `Int("")` einen Fehler werfen, WP3 ändert das). `setup.sh`/`update.sh` übernehmen nur noch ausdrücklich gesetzte Werte in die `.env`.
- Start: ENV laden, DB öffnen (nur ENV-Werte nötig), `config_override` lesen, effektive `Config` bilden. Ein ungültiger gespeicherter Wert (z. B. nach geänderten Grenzen) wird mit Warnung ignoriert und der Default genutzt, nie ein Startabbruch.
- Live-Änderungen: neue Klasse `ConfigStore` (Sperre, `snapshot() -> Config`, `revision`). Alle Prozesse fragen `max(revision)` alle 30 s und laden bei Änderung nach; Verbraucher von `live`-Werten lesen den Snapshot beim jeweiligen Tick/Request statt einer beim Start kopierten `Config`. Heute kopieren `Api`, `Ingestor`, `PushService`, `SitePages` die Struct beim Start: WP3 migriert nur die als `live` ausgewiesenen Werte, alles andere bleibt `restart`.
- Schreiben: Prüfung gegen das Register (Typ, Grenzen, Querregeln), Transaktion aus `config_override` + `config_audit`, Antwort mit neuem Zustand. Zurücksetzen löscht den Override. ENV-gesperrte Schlüssel antworten 409 `locked_by_env`. Geheime und `envOnly`-Schlüssel antworten 404/403.
- Querregeln: `PUSH_ENABLED=true` verlangt `IMAGE_WIDTH=1024`, vier APNs-Werte und den Schlüssel (nur per ENV/Secret); `RETENTION_RUNS >= 15`; `LAYERS` nur bekannte Kennungen.

### 5.2 Register (aus `Config.swift`, `.env.example`, `stack.yaml`)

Grenzen mit „(neu)“ sind Vorschläge dieses Plans, in der Umsetzung durch Review zu bestätigen; alle anderen stehen heute im Code. `live` setzt die Migration auf `ConfigStore` voraus (WP3).

| Schlüssel | Typ | Default | Grenzen | Wirkung | Bemerkung |
|---|---|---|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_POOL_SIZE` | Text/Zahl | 127.0.0.1, 3306, showernow, showernow, 4 | Pool 1 bis 10 | nur ENV | Bootstrap vor DB-Zugriff; im Dashboard schreibgeschützt sichtbar |
| `DB_PASSWORD(_FILE)` | Geheimnis | – | – | nur ENV | nie angezeigt |
| `HTTP_PORT` | Zahl | 8080 | – | nur ENV | Listener |
| `REPLICA_SLOT`, `RESTART_STAGGER_SECONDS` | Zahl | –, 45 | Stagger 15 bis 300 | nur ENV | Neustart-Staffelung (Abschnitt 5.3); Slot kommt aus Swarm-Template |
| `DASH_ENABLED`, `DASH_PORT`, `DASH_ORIGIN`, `DASH_RP_ID`, `DASH_SETUP_WINDOW_MINUTES`, `DASH_SESSION_HOURS`, `DASH_IDLE_MINUTES` | verschiedene | false, 9090, –, 15, 12, 30 | siehe 2.4/2.5 | nur ENV | Dashboard-Bootstrap |
| `MIGRATIONS_DIR`, `BUILD_REVISION` | Text | migrations, – | – | nur ENV | Revision nur Anzeige |
| `WMS_URL`, `EUMETSAT_WMS_URL` | URL | DWD/EUMETSAT-Standard | – | nur ENV | nur für Tests; Dashboard-Änderung wäre ein SSRF-/Datenintegritätsrisiko |
| `CACHE_MAX_MB` | Zahl (MB) | 64 | 8 bis 1024 (neu) | restart | `SlotCache.maxBytes` ist `let`; live später möglich |
| `IMAGE_WIDTH` | Zahl | 1024 | 256 bis 2048 | restart | mit Push fest 1024; Änderung entwertet Bildraster, Bestätigungsdialog |
| `LAYERS` | Liste | radar | bekannte Kennungen (`LayerCatalog`) | restart | startet Schleifen; Migration 004 nötig |
| `RETENTION_RUNS` | Zahl | 16 | 15 bis 96 (neu) | live | Retention |
| `HISTORY_HOURS` | Zahl | 48 | 1 bis 72 | live | |
| `FETCH_WORKERS` | Zahl | 3 | 1 bis 6 | restart | |
| `AVAILABILITY_DELAY_SECONDS` | Zahl | 200 | 60 bis 900 (neu) | live | |
| `JITTER_SECONDS` | Zahl | 20 | 0 bis 120 (neu) | live | |
| `REQUEST_TIMEOUT_SECONDS` | Zahl | 30 | 5 bis 120 (neu) | live | |
| `USER_AGENT` | Text | ShowerNow-radar-ingest/1.0 | 1 bis 200 Zeichen, druckbares ASCII (neu) | live | wird an DWD gesendet |
| `PRESSURE_FORECAST_HOURS` | Zahl | 48 | 1 bis 168 | live | |
| `PRESSURE_EU_FORECAST_HOURS` | Zahl | 24 | 1 bis 168 | live | Bild 4,3-fach größer |
| `PRESSURE_RETENTION_RUNS` | Zahl | 2 | 2 bis 8 | live | |
| `LIGHTNING_HISTORY_HOURS`, `CLOUDS_HISTORY_HOURS`, `CLOUDMASK_HISTORY_HOURS`, `CLOUDMASK_VIS_HISTORY_HOURS`, `CLOUDMASK_VIS_EU_HISTORY_HOURS` | Zahl | je 3 | je 1 bis 24 | live | |
| `LAYER_PAUSE_SECONDS` | Zahl | 2 | im Dashboard 1 bis 60 (Code erlaubt 0; Dashboard strenger, schont DWD) | live | |
| `OPERATOR_NAME`, `OPERATOR_ADDRESS`, `OPERATOR_EMAIL`, `PROXY_LOG_NOTE` | Text | leer | je höchstens 500 Zeichen | live | erscheinen auf öffentlichen Seiten; Audit maskiert |
| `APP_STORE_URL`, `TESTFLIGHT_URL` | URL | leer | `https`, höchstens 500 Zeichen, Host `apps.apple.com` bzw. `testflight.apple.com` (neu) | live | verhindert `javascript:`-URLs |
| `PUSH_ENABLED` | Bool | false | Querregeln siehe 5.1 | restart | APNs-Sender entsteht beim Start |
| `APNS_KEY(_FILE)` | Geheimnis | – | – | nur ENV | Swarm-Secret |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | Text | leer | je 10 Zeichen A bis Z, 0 bis 9 (neu) | restart | keine Geheimnisse, aber Konfiguration einer Identität |
| `APNS_TOPIC` | Text | leer | Bundle-ID-Muster (neu) | restart | |
| `APNS_ENV` | Aufzählung | production | sandbox, production, both | restart | |
| `PUSH_MAX_INSTALLATIONS` | Zahl | 100 000 | 1 bis 1 000 000 (neu) | live | `503 server_full` |
| `PUSH_MAX_SUBSCRIPTIONS` | Zahl | 400 000 | 1 bis 5 000 000 (neu) | live | |
| `PUSH_MAX_REGION_CELLS` | Zahl | 50 000 000 | 1 bis 500 000 000 (neu) | live | Auswertung etwa 1 s je 50 Mio. Zellen (Messung im Code kommentiert) |
| `PUSH_MAX_ACTIVITY_SUBSCRIPTIONS` | Zahl | 5 000 | 1 bis 50 000 (neu) | live | |
| Phase 2: heute Konstanten in `PushApi`/`RegionLimits`: `perInstallationLimit` 60/min, `globalRegistrationLimit` 600/min, `globalRequestLimit` 3000/min, `failedAuthLimit` 10/min, `testLimit` 3/h, `maxRegionsPerInstallation` 3, `maxCellsPerInstallation` 8000 | Zahl | wie links | vorgeschlagen 10 bis 600, 60 bis 6000, 300 bis 30000, 3 bis 60, 1 bis 10, 1 bis 10, 500 bis 50000 (alle neu) | live | erst nach Überführung in `Config` (WP3, zweite Stufe); Dashboard darf nie über die Obergrenzen oder unter die Untergrenzen |

### 5.3 Neustart-Knopf (Entscheidung 3.11.2026: kontrollierter Neustart per Dashboard)

Grundsatz: Das Dashboard bekommt **keinen Docker-Socket** und keine Swarm-Rechte. Der Neustart läuft über die Datenbank; Swarm startet beendete Replikate selbst neu.

1. **Anzeige:** Hat ein gespeicherter Dashboard-Wert `apply = restart` und weicht vom beim Prozessstart geladenen Wert ab, zeigt die Konfigurationsseite je Zeile „Neustart nötig“ und oben ein Banner mit Knopf „Radar-Dienst neu starten“. Der Abgleich nutzt `config_override.revision` gegenüber der beim Start gelesenen Revision (`config_replica` / Prozess-Revision), nicht nur eine statische Markierung. `live`-Werte wirken ohne Neustart (30-s-Nachladen, Abschnitt 5.1).
2. **Auslösen:** `POST /dash/api/restart` nur mit Passkey-Sitzung, CSRF-Token, Bestätigungsdialog (Seite zeigt die Liste der offenen Schlüssel und die Folge „Radar-Replikate starten nacheinander neu“), Rate-Limit (z. B. 2 pro Minute, 6 pro Stunde), Audit-Eintrag (`action = restart`, Generation alt/neu) und Log-Ereignis. Wirkung: `config_generation.generation` um 1 erhöhen (atomar, eine Zeile).
3. **Erkennen:** Jedes `radar`-Replikat liest `generation` periodisch (im bestehenden 30-s-Nachladen der Revision, mit Jitter) und vergleicht sie mit dem beim Start gelesenen Wert. Bei Abweichung leitet es seinen geordneten Austritt ein; die Replikate stellen dabei `applied_generation` in `config_replica` ein.
4. **Gestaffelter, geordneter Austritt (Verfügbarkeit):** Nicht alle Replikate gleichzeitig. Jedes Replikat wartet eine Staffelung ab, abgeleitet aus dem stabilen Replikat-Index (Swarm-Template `{{.Task.Slot}}` als `REPLICA_SLOT`, Zusatz-Jitter): Wartezeit = `(slot - 1) × RESTART_STAGGER_SECONDS` (Standard 45 s, Grenzen 15 bis 300) plus 0 bis 5 s Jitter; zusätzlich beendet sich ein Replikat erst, wenn die Replikat-Tabelle mindestens ein anderes bereites Replikat der **neuen** Generation zeigt oder es das Replikat mit dem kleinsten Slot ist. Der Leader (Ingest-Schleifen) geht zuletzt: Er wartet, bis alle anderen auf die neue Generation gewechselt sind (Obergrenze 10 min, danach geht er trotzdem). Austritt = Graceful Shutdown (Vapor-Lifecycle: keine neuen Anfragen annehmen, laufende beenden, Statistik-Flush, Leader-Sperre freigeben), danach Prozessende mit Exit-Code 0; `restart_policy: any` startet den Task neu, `update_config` bleibt unverändert. Mit nur einem Replikat gibt es zwangsläufig ein kurzes Ausfallfenster (Healthcheck/`start_period` abwarten); die Seite weist darauf hin, wenn `replicas < 2`.
5. **Nach dem Neustart:** Der neue Prozess liest die aktuelle `generation` als Ausgangswert und löst keinen weiteren Neustart aus (verhindert Schleifen); er trägt sich in `config_replica` ein. Die Seite zeigt je Replikat „neu gestartet / wartet“ bis alle `applied_generation = generation` haben, danach verschwindet das Banner.
6. **Grenzen und Absicherung:** Mindestabstand zwischen zwei Neustarts (z. B. 5 Minuten, sonst 429); Healthcheck des Dienstes (`/healthz`) bleibt maßgeblich, ein Replikat mit ungültiger neuer Konfiguration fällt auf den Default zurück (Abschnitt 5.1) statt in eine Absturzschleife; das Dashboard selbst (Dienst `dashboard`) ist nicht betroffen, startet aber bei geänderten `DASH_*`-Werten ohnehin nur über Redeploy (ENV-only).
7. **Tests (WP3/WP5, Memory-Repo mit mehreren simulierten Replikaten):** Generation erhöht → alle Replikate beenden sich, aber nie mehr als eines gleichzeitig; Leader zuletzt; neuer Prozess startet nicht erneut; zweiter Klick innerhalb des Mindestabstands wird abgelehnt; Audit-Eintrag vorhanden; Auslösen ohne Sitzung/CSRF/Bestätigung scheitert.

## 6. Frontend

### 6.1 Technik und Seiten

SvelteKit (Svelte 5) mit `adapter-static`, SPA-Modus (`ssr = false`, Fallback `index.html`, `paths.base = '/dash'`), TypeScript, Tailwind und shadcn-svelte, Dark/Light, deutsche Texte, Zahlen/Daten in `de-DE`. Verzeichnis `dashboard/` im Repo. Seiten:

- Übersicht: Cache-Quote heute und 30 Tage, Anfragen heute, Gauges (Installationen, Abos, Ebenenstatus), Hinweis „Verzug bis 60 s“.
- Traffic: Tagesreihen (Anfragen, Bytes) nach Route und Statusklasse, 304-Anteil, Rate-Limit-Treffer.
- Konfiguration: nach Gruppen, je Zeile Wert, Quelle-Badge, Schloss („durch Umgebungsvariable festgelegt“), Typ/Grenzen, „live“/„Neustart nötig“, Speichern, Auf Default; Banner „Neustart nötig“ mit Knopf (Bestätigungsdialog, Fortschritt je Replikat, Abschnitt 5.3); Reiter „Änderungsprotokoll“.
- Login und Einrichtung: Zustand aus `GET /dash/api/session`; Einrichtung zeigt den Hinweis auf das offene Fenster.

Diagramme: shadcn-svelte-Chart-Komponente (nach Doku auf LayerChart aufgebaut; Verfügbarkeit mit Svelte 5 und Lizenz in WP6 prüfen), alternativ eigene SVG-Balken (keine Abhängigkeit, genügt für Tagesreihen). Keine `{@html}`-Ausgaben, alle Serverwerte als Text.

### 6.2 Passkey im Browser

`navigator.credentials.create/get` mit den Optionen des Servers (Base64URL-Wandlung im Client). Fehlerzustände: nicht unterstützt, abgebrochen, Fenster geschlossen, Sitzung abgelaufen.

### 6.3 Build-Pipeline

- Dockerfile: neues Stage `FROM node:<LTS>-slim AS dashboard` (Digest pinnen, aktuelle LTS zum Zeitpunkt von WP6 prüfen), `COPY dashboard/package.json dashboard/package-lock.json`, `npm ci --ignore-scripts`, `COPY dashboard/`, `npm run build`; im Endstage `COPY --from=dashboard /build/build /app/dashboard`. Lockfile eingecheckt, keine Netzzugriffe zur Laufzeit (keine CDN-Schriften/Skripte; Schrift per System-Stack oder lokal gebündelt).
- `.dockerignore`: `dashboard/node_modules`, `dashboard/.svelte-kit`, `dashboard/build`.
- CI (`ci.yml`): `npm ci`, `svelte-check`, `vitest`, Build, `npm audit --omit=dev` (Befund als Warnung). Das bestehende `docs-site` mit Lockfile ist das Vorbild.
- Das Swift-Binary ist unabhängig vom Frontend testbar (Handler liest ein Verzeichnis).

### 6.4 CSP

Ziel: `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`. SvelteKit fügt beim statischen Build ein Inline-Startskript ein; dafür `kit.csp` im Hash-Modus (für prerender-Seiten unterstützt) und CSP als Header. Offenes Detail: Bibliotheken wie bits-ui (Grundlage von shadcn-svelte) setzen Inline-`style`-Attribute; dann wäre `style-src-attr 'unsafe-inline'` nötig, Skripte bleiben strikt. WP6 klärt das per Browser-Test und dokumentiert die genaue Richtlinie.

## 7. Sicherheit

### 7.1 Bedrohungsmodell

Vertrauen: nur Betreiber mit Passkey; Netz „intern“ ist nicht vertrauenswürdig für anonyme Aufrufer, gilt aber als nicht öffentlich. Angreifer: (a) anonym im internen Netz, (b) Betreiber-Browser mit bösartiger Webseite, (c) bösartiger Inhalt in Betreibertexten, (d) Lieferkette (npm/Swift).

| Bedrohung | Gegenmaßnahme |
|---|---|
| Erstregistrierung ohne Token durch Fremde | Abschnitt 2.4: nur ohne Credential, nur intern, Zeitfenster, Rate-Limit, Log, atomar, `dashboard-reset`; Restrisiko dokumentiert |
| Brute-Force/Flooding | Passkey nicht ratbar; Rate-Limits, Challenge-Einmalverwendung, Zähler-Prüfung; Aussperrung des Betreibers für eine Minute als bekannte Folge |
| Sitzungsdiebstahl | `__Host-`, `HttpOnly`, `Secure`, `SameSite=Strict`, nur Hash in DB, Leerlauf- und Absolut-Timeout, Abmeldung |
| XSS | Svelte-Escaping, kein `{@html}`, strikte CSP, `nosniff`, keine Inline-Skripte außer Hash; Betreibertexte im Dashboard nur als Text |
| Gespeichertes XSS über Betreibertexte auf öffentlichen Seiten | Prüfen, dass `SitePages` alle `OPERATOR_*`-Werte HTML-escaped (Test); URLs nur `https` mit Host-Liste |
| CSRF | Abschnitt 2.6 |
| DNS-Rebinding, falscher Host | Host- und Origin-Prüfung gegen `DASH_ORIGIN` |
| Clickjacking | `frame-ancestors 'none'`, `X-Frame-Options` |
| Missbrauch der Konfiguration | Register mit Grenzen, nur Schlüssel des Registers, ENV-Sperre, Querregeln, Audit; keine URLs der Datenquellen, keine Geheimnisse |
| SQL-Injection | nur parametrisierte Abfragen; Schlüssel gegen Register-Allowlist |
| Pfad-Traversal im Statikhandler | Normalisierung, Wurzelprüfung, Tests mit `..`, `%2e%2e`, Null-Byte |
| Informationsleck | generische Fehler, keine Geheimnisse in Antworten, kein Stacktrace, Statistik ohne personenbezogene Daten |
| Replay | Challenge-Einmalverwendung, Ablauf 5 min, `sign_count` |
| Lieferkette | Lockfile, `npm ci --ignore-scripts`, gepinntes Node-Image, `npm audit`, Swift-Paket exakt gepinnt, `Package.resolved` |
| Listener unbeabsichtigt öffentlich | Standard aus, im Overlay `dashboard` gar kein `ports:` und kein Ingress (nur Overlay-Netz, Zugriff über den internen Proxy), Deploy-Prüfung per `docker stack config` |
| Missbrauch des Neustart-Knopfs (Dauer-Neustarts, Ausfall) | Nur Passkey-Sitzung + CSRF + Bestätigung, Rate-Limit und Mindestabstand, gestaffelter Austritt, Audit; kein Docker-Socket, daher keine Rechteausweitung auf den Host |

### 7.2 Review

WP9: unabhängiger Sicherheits-Review (Skill `security-audit`/`security-review`) über Auth, Sitzungen, CSRF, Konfigurationsschreiben, Statikhandler, CSP, Deploy; Befunde P1/P2 vor Abschluss geklärt.

## 8. Tests

| Bereich | Tests (Swift Testing/XCTest wie in `Tests/RadarCoreTests`) |
|---|---|
| Rangfolge | ENV > Dashboard > Default je Typ; leere ENV zählt als nicht gesetzt; ungültiger DB-Wert fällt auf Default zurück |
| Validierung | Grenzen je Register-Eintrag (Rand und außerhalb), Querregeln (Push/Breite), Geheimnisse/`envOnly` nicht schreibbar, ENV-gesperrt 409 |
| Audit | Eintrag je Änderung, Maskierung, keine Geheimnisse |
| Statistik | Zähler, Flush-Addition über zwei simulierte Replikate, Fehlerfall behält Deltas, Retention 30 Tage, keine freien Etiketten |
| Cache-Zähler | Treffer, Fehlgriff, Negativ-Cache, Single-Flight (`SlotCache`) |
| WebAuthn | Registrierung und Anmeldung mit Software-Authenticator (CryptoKit/swift-crypto P-256), falscher Origin/RP-ID/Challenge, Wiederverwendung, Zähler-Rückgang, Doppelregistrierung, geschlossenes Fenster, `dashboard-reset` |
| Sitzung/CSRF | Cookie-Attribute, Ablauf, fehlendes/falsches Token, falscher Origin/Host, Content-Type |
| Rate-Limit | Grenzen je Endpunkt, Fehlversuche |
| Neustart | Generation erhöhen → mehrere simulierte Replikate beenden sich gestaffelt (nie alle gleichzeitig, Leader zuletzt), kein Neustart-Schleife, Mindestabstand, Audit, Schutz (Sitzung/CSRF/Bestätigung) |
| Statik | Traversal-Varianten, Fallback, Köpfe/CSP |
| Listener | bei `DASH_ENABLED=false` kein Port; öffentlicher Port liefert 404 für `/dash` |
| Frontend | `svelte-check`, `vitest` (Stores, Formatierung, Fehlerzustände), Build; E2E mit Playwright und virtuellem WebAuthn-Authenticator (Chrome-DevTools-Protokoll) |
| Gesamt | `swift test` ohne DB (Memory) und gegen Wegwerf-MariaDB (Docker, wie in `docs/status.md` beschrieben); `docker build` mit Node-Stage; Smoke mit lokalem Compose |

## 9. Deploy

- `stack.yaml` bleibt für `radar` unverändert bis auf `${KEY:-}`-Durchreichung der dashboardfähigen Schlüssel (Abschnitt 5.1) und `DASH_ENABLED: "false"`. Kein neues `ports:`.
- Neues Overlay `deploy/swarm/stack.dashboard.yaml` (nur eingebunden bei `DASH_ENABLED=true`, Muster `stack.push.yaml`; `swarm-deploy.sh`/`update.sh` ergänzen): Dienst `dashboard` mit Befehl `[dashboard]`, ein Replikat, Netz `internal`, Secrets wie `radar` (DB), **kein `ports:`-Eintrag (weder Ingress noch `host`)**, Healthcheck auf `/dash/api/session`, `DASH_ORIGIN` (und optional `DASH_RP_ID`) aus der `.env`. Der Radar-Dienst bekommt zusätzlich `REPLICA_SLOT: "{{.Task.Slot}}"` für die Staffelung (Abschnitt 5.3). `deploy-branch.yml` spiegelt die neue Datei.
- Erreichbarkeit (Entscheidung 3.11.2026): Ein bereits vorhandener interner Reverse Proxy des Betreibers terminiert TLS und leitet an den Dienst `dashboard` (Port 9090) im Overlay-Netz weiter. Der Betreiber muss dafür nichts im Repo tun; das Repo liefert weder Proxy noch VPN noch Host-Port. WP8 dokumentiert nur die Anforderungen an den Proxy (Overlay-Netz erreichbar, `Host` unverändert, HTTPS, WebSockets nicht nötig) und dass `DASH_ORIGIN` exakt der Adresse entsprechen muss, unter der der Betreiber das Dashboard aufruft. Prüfung per `docker stack config`: im Dashboard-Dienst kein `ports:`. WebAuthn verlangt einen sicheren Kontext (HTTPS) und eine feste RP-ID.
- `.env.example`, `setup.sh --help`, `update.sh`, `docs-site/content/betrieb.md` und `installation.md`: neue Abschnitte „Dashboard“ (Aktivierung, Einrichtung, Notfall-Reset, Aufbewahrung, Datenschutz). `docs/decisions.md`, `docs/status.md`, `README.md` führt der Dokumentations-/Abschluss-Agent nach.

## 10. Reihenfolge, Arbeitspakete, Dateibesitz

Vorbedingung W0 (kein Paket) ist **erfüllt** (3.11.2026): Die Live-Activity-Härtung ist committet (Backend-Commits 49321e4 und 1945a4e, CI grün). Die Pakete dürfen die Dateien (u. a. `Api.swift`, `Config.swift`, `PushApi.swift`, `Repo.swift`, `MariaRepo*.swift`, `MemoryRepo*.swift`, `stack.yaml`, `.env.example`) ab diesem Stand ändern. `main.swift` hat genau einen Besitzer (WP5); andere Pakete stellen Funktionen in eigenen Dateien bereit.

| Paket | Inhalt | Besitzer | Exklusive Dateien | Hängt ab von | Welle |
|---|---|---|---|---|---|
| WP1 Daten und Repo | Migration 009, `DashboardRepo` (Credential, Challenge, Sitzung, Stats, Override, Audit), Maria- und Memory-Implementierung, Retention | Codex | `migrations/009_dashboard.sql`, `DashboardRepo.swift`, `MariaRepo+Dashboard.swift`, `MemoryRepo+Dashboard.swift`, `Repo.swift`, `Tests/…/DashboardRepoTests.swift` | W0 | 1 |
| WP3 Konfigurationsregister | `ConfigRegistry`, `ConfigStore`, Umbau `Config.fromEnvironment` (leer = ungesetzt, gemeinsame Prüfung), `live`-Verbraucher migrieren (Retention, Stunden, Pausen, Timeouts, Push-Caps, Betreibertexte), Phase-2-Konstanten | Codex | `ConfigRegistry.swift`, `ConfigStore.swift`, `Config.swift`, `Tests/…/ConfigRegistryTests.swift`; `Ingestor/LayerIngestor/PushService/SitePages` nur Lesezugriffe auf den Snapshot (Besitz für diese Welle) | W0; Datenzugriff über Protokoll aus WP1 (Stub bis dahin) | 1 |
| WP6 Frontend-Gerüst | SvelteKit/Tailwind/shadcn-svelte, Layout, Login/Einrichtung (Passkey-Client), API-Client mit CSRF, Mock-Server, CSP-Klärung, Dockerfile-Node-Stage, `.dockerignore`, CI-Schritte | Claude | `dashboard/**` (Gerüst, `src/lib`, Login/Setup), `Dockerfile`, `.dockerignore`, `.github/workflows/ci.yml` | keine | 1 |
| WP2 Statistik | `StatsCounter`, Flush-/Retention-Schleife, Instrumentierung `Api`/`SlotCache`/Rate-Limits/Ingest, Leseabfragen | Codex | `Stats.swift`, `Api.swift`, `PushApi.swift` (nur Zähler), `Tests/…/StatsTests.swift` | WP1 | 2 |
| WP4 Auth und Sicherheit | `swift-webauthn` einbinden und Swift-6-Prüfung, Setup/Login-Logik, Sitzungen, CSRF, Host/Origin, Rate-Limits, Setup-Fenster, `dashboard-reset` | Claude | `Package.swift`, `Package.resolved`, `DashboardAuth.swift`, `DashboardSession.swift`, `Tests/…/DashboardAuthTests.swift` | WP1 | 2 |
| WP7 Frontend-Seiten | Übersicht, Traffic, Konfiguration, Änderungsprotokoll, Diagramme, Frontend-Tests | Codex | `dashboard/src/routes/(app)/**`, `dashboard/src/lib/charts`, Tests | WP6 | 2 |
| WP5 Listener und Router | zweiter Listener/`radar dashboard`, Routen `/dash/api`, Statikhandler, Köpfe/CSP, Verdrahtung in `main.swift`, API-Vertrag in `docs-site/content/dashboard-api.md` | Codex | `main.swift`, `DashboardApi.swift`, `StaticFiles.swift`, `Tests/…/DashboardApiTests.swift`, `docs-site/content/dashboard-api.md` | WP2, WP3, WP4 (Schnittstellen) | 3 |
| WP8 Deploy und Doku | `stack.yaml` (`${KEY:-}`), Overlay `stack.dashboard.yaml`, `swarm-deploy.sh`, `update.sh`, `setup.sh`, `deploy-branch.yml`, `.env.example`, `docs-site` (Betrieb, Installation), README | Codex | genannte Dateien, `docs-site/content/{betrieb,installation}.md` | WP3 (Schlüsselliste), Frage 1 | 3 |
| WP9 Review und Abnahme | Sicherheits-Review, `docker build`, Browser-E2E mit virtuellem Authenticator, Prüfung der Aussagen (Port nicht öffentlich), danach `docs/decisions.md`, `docs/status.md`, Commit nach Auftrag | Claude | `docs/decisions.md`, `docs/status.md`, Testskripte unter `dashboard/e2e` | alle | 4 |

Parallelität: höchstens drei Worker gleichzeitig (Wellen 1 und 2 je drei, Welle 3 zwei, Welle 4 einer). Codex besitzt 6 von 9 Paketen (WP1, WP2, WP3, WP5, WP7, WP8), Claude 3 (WP4 sicherheitskritisch, WP6 Build/Frontend-Prüfung, WP9 Review/Abnahme). Gemeinsame Build-/Docker-Ressourcen: jeweils der Besitzer der Welle; Docker-Builds nur WP6 und WP9. WP7 darf gegen den Mock-Server aus WP6 arbeiten; echte Integration erst in WP9.

Je Paket: Übergabe mit geänderten Dateien, ausgeführten und nicht ausgeführten Prüfungen im Board (`post_progress`); `docs/status.md` pflegt nur WP9 beziehungsweise der Dokumentations-Agent.

## 11. Board

Je Arbeitspaket eine Unteraufgabe (Parent: Hauptaufgabe) mit zwei bis drei Kriterien; Namen `WP1 …` bis `WP9 …`. Besitzer und Abhängigkeiten stehen in der Aufgabenbeschreibung.

## 12. Risiken und offene Fragen

Risiken:

1. Erstregistrierung ohne Token: Wer vor dem Betreiber den internen Port erreicht, kann den Passkey übernehmen. Gegenmaßnahmen siehe 2.4; Restrisiko akzeptiert (Nutzerentscheidung), Betriebsregel und Notfall-Reset dokumentiert.
2. `swift-webauthn` ist nur als Beta (`1.0.0-beta.1`) veröffentlicht; API-Änderungen und Swift-6-Strikt-Concurrency-Warnungen sind möglich. Rückfall: eigene Minimal-Prüfung mit swift-crypto (ES256, Attestation `none`).
3. Rangfolge ENV > Dashboard funktioniert nur, wenn `stack.yaml` keine Standardwerte mehr erzwingt; Umstellung betrifft bestehende `.env`-Dateien und `setup.sh`/`update.sh` (WP8, Regressionsrisiko im Deploy).
4. `live`-Konfiguration erfordert Umbau mehrerer Verbraucher von kopierten Struct-Werten auf einen Snapshot (WP3); Fehler können Ingest/Push beeinflussen. Deshalb nur ausgewählte Schlüssel live, übrige Neustart.
5. CSP mit shadcn-svelte/bits-ui: Inline-Styles könnten `style-src-attr 'unsafe-inline'` erzwingen (WP6 klärt).
6. Zugriff über den vorhandenen internen Reverse Proxy: Dessen Konfiguration (Host-Kopfzeile, Overlay-Erreichbarkeit, HTTPS-Origin) liegt außerhalb des Repos und ist nicht geprüft; falsches `DASH_ORIGIN`/`Host` führt zu 403 und fehlgeschlagenen Passkeys (WP8-Doku, WP9-Smoke).
11. Neustart-Knopf: Fehler in der Staffelung könnten alle Replikate gleichzeitig beenden oder eine Neustartschleife auslösen (Ausfall der öffentlichen API). Gegenmaßnahmen: Abschnitt 5.3 (Staffelung, Leader zuletzt, Mindestabstand, neuer Prozess übernimmt aktuelle Generation), Test mit mehreren Replikaten (WP3/WP5), Smoke im echten Swarm in WP9. Ohne zweites Replikat entsteht ein kurzes Ausfallfenster.
12. Kein Docker-Socket: Das Dashboard kann Replikate nur zum Beenden auffordern; hängt ein Replikat, hilft nur Swarm (Healthcheck) oder der Betreiber.
7. Rate-Limit ohne IP: interner Angreifer kann Anmeldung kurz blockieren; Limits pro Prozess.
8. Statistik nur täglich: „Traffic über Zeit“ ist grob; Stundenwerte wären zusätzliche Tabelle (nicht geplant).
9. Gespeichertes XSS über Betreibertexte auf öffentlichen Seiten, falls `SitePages` nicht überall escaped (Test in WP3/WP9).
10. Zweite `Application` in Vapor als zweiter Listener ist nicht geprüft (WP5).

Offene Entscheidungen: keine. Die fünf Board-Fragen (Zugriffsweg, Neustart, Aufbewahrung, erster Passkey, Auslieferung) sind am 3.11.2026 beantwortet und im Plan umgesetzt. Offene Prüfpunkte (keine Nutzerentscheidungen): Staffelungswerte (`RESTART_STAGGER_SECONDS`, Mindestabstand) und die Proxy-Anforderungen werden in WP3/WP8/WP9 praktisch bestätigt.

Nicht ausgeführt: keine Builds oder Tests; Plan basiert auf gelesenem Code (`Config.swift`, `Api.swift`, `PushApi.swift`, `main.swift`, `stack.yaml`, `.env.example`, `Dockerfile`, `MariaRepo.migrate`) und der Bibliotheksprüfung vom 3.11.2026.

## Quellen

- swift-webauthn (Nachfolger): <https://github.com/swift-server/swift-webauthn> (Lizenz, Tags, `Package.swift` auf `main` abgefragt am 3.11.2026).
- webauthn-swift (alt, Index-Eintrag): <https://packages.ecosyste.ms/registries/swiftpackageindex.com/packages/github.com%2Fswift-server%2Fwebauthn-swift>.
