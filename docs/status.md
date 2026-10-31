# Fortsetzbarer Arbeitsstand

Stand: 28. Oktober 2026. Aktuelle App-Identität: ShowerNow / `de.linolaske.showernow`, Team `J2DU2P47XW`. Technische Repository-Namen bleiben unverändert. Maßgeblicher aktueller App-/TestFlight-Stand: [Apple-Arbeitsstatus](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md); die folgenden frühen Checkpoints bleiben historisch eingeordnet.

## Auftrag und Freigabe

Entwicklung ist nach Beantwortung aller drei Einstiegsfragen freigegeben. Gemäß `plan.md` mit DWD-Datenvalidierung und App beginnen. Backend folgt nach nutzbarer App. Noch kein Anwendungscode vorhanden.

## Repository

- Dieses Repository: https://github.com/MagicalWig34653/weather-backend
- Schwesterrepository: https://github.com/MagicalWig34653/weather-apple
- Beide lokalen Arbeitsordner heißen `weather`; die private Zuordnung der absoluten Pfade steht in der ignorierten `LOCAL_WORKSPACE.md`. Vorlage für neue Rechner: `LOCAL_WORKSPACE.example.md`. Fachliche Entscheidungen bleiben versioniert.
- Die ursprünglich im Konzeptordner vorbereiteten Kopien sind nur Einrichtungsvorlagen. Dieses Zielrepository ist der aktive Arbeitsstand.

## Erledigt

- Ursprüngliches Konzept unverändert übernommen und aktuelle Plattform-/Produktentscheidungen separat dokumentiert.
- README, Ignore-Regeln, AGENTS.md und Claude-Code-Einstieg eingerichtet.
- Verbindliche Kostensparsamkeit, Agent-Nutzung und vollständig aus dem Repo fortsetzbare Sessions festgehalten.
- Unabhängiger Agent hat die Prozessregeln und minimale Übergabedokumentation geprüft; Ergebnisse integriert.
- Repository an den gewünschten lokalen Zielpfad übertragen; initiale Git-Historie vorhanden.

## Prüfungen

- Originalkonzept byteweise mit der Quelle verglichen: identisch.
- Initiale Git-Objekte geprüft und initiale Arbeitsbäume sauber.
- Einrichtungsskript auf zsh-Syntax geprüft.
- GitHub-CLI erfolgreich authentifiziert; gewünschte GitHub-Namen waren zum Zeitpunkt der Einrichtung noch nicht vorhanden.
- Build-/Laufzeittests nicht ausgeführt: noch keine Anwendung und keine Testkonfiguration vorhanden.

## Veröffentlichung

Repository am 28. Oktober 2026 öffentlich auf GitHub erstellt. `main` wurde erfolgreich gepusht und verfolgt `origin/main`. Dokumentationsänderungen mit `git diff --check` geprüft. Remote-Sichtbarkeit und synchroner Git-Stand werden beim Abschluss geprüft.

## Aktueller Schritt und nächste Aufgaben

1. Entwicklungsplan in `plan.md` angelegt und unabhängig durch einen Agent auf Reihenfolge und Abnahmekriterien geprüft.
2. Alle drei Einstiegsfragen beantwortet; Geräte/Versionen, iPhone-first-TestFlight und vorläufige Identität in `decisions.md` dokumentiert.
3. DWD-Datenvalidierung im Apple-Repo begonnen: realer RV-Lauf mit25Frames untersucht; reproduzierbares Forschungsskript und Berichte im [Apple-Repo](https://github.com/MagicalWig34653/weather-apple/tree/main/docs/research). Agent hat WMS-Punktserie erfolgreich abgefragt; alle25Werte einer nassen Zelle gegen Rohdaten abgeglichen. Direkter kleiner Datenweg ist für diesen Fall bestätigt; Einheiten-/NoData-/Aktualitätsrandfälle bleiben offen. Phase1 bleibt offen. Backend wartet auf die nutzbare App.
4. Die Lizenz bleibt offen; aktuelle App-Identität ist inzwischen ShowerNow / `de.linolaske.showernow`. Dies blockiert die lokale Datenvalidierung nicht.

Lokale Entwicklungsumgebung geprüft: Xcode 27.1, Swift 6.4, iOS-27- und watchOS-27-Simulatoren vorhanden; Apple Silicon. Noch keine App-Builds durchgeführt.

Prüfung dieses Schritts: realer Archivbericht auf25Frames, ACRR,1200×1100 und Vorläufe0..120/5 geprüft. Noch kein App-Build, keine iPhone-Performanceaussage.

Agent-Prüfung abgeschlossen: Planreihenfolge, WMS-Abfrage und Forschungsskript geprüft. Numerische WMS-Property im geprüften Lauf als5-Minuten-Akkumulation erkannt; nicht ungeprüft als mm/h ausgeben. Nächster technischer Schritt im Apple-Repo: weitere Zellen/NoData und Aktualität prüfen, Datenadapter samt Fixtures/gezielten Tests beginnen; danach iPhone-Projekt aufbauen. `git diff --check` bestanden; noch keine App kompiliert oder nach TestFlight geladen.

Lokale Repo-Zuordnung eingerichtet und durch Agent geprüft: `LOCAL_WORKSPACE.md` enthält private Pfade und wird ignoriert; öffentliche Vorlage enthält Platzhalter. `git check-ignore` bestätigt den Ausschluss, die private Datei ist nicht versioniert, der Git-Index enthält keine absoluten Benutzerpfade. `git diff --check` bestanden. Claude-Code-Status auf freigegebene Entwicklung korrigiert.

## App-/Prozesscheckpoint vom 28. Oktober 2026

Die verbindliche kleine Hierarchie mit ausschließlich koordinierendem Hauptagenten und technischem Lead steht in `team.md`. Frische ausführende Agents übernehmen abgegrenzte Aufgaben; Sessions bleiben aus dem Repository fortsetzbar.

Im [Apple-Repo](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md) liegt inzwischen der geprüfte native iPhone-Prototyp mit zwölf erfolgreichen Datentests, Quellen-/Datenschutz-Smoke und abschließend erfolgreichem Orts-CRUD-Smoke vor. Unabhängiges Review ohne offene P1-/P2-Befunde; Live-Providergrenzen bleiben dokumentiert. Icon-Design und TestFlight-Upload sind noch offen, keine fertige Version 1. Backend-Implementierung bleibt zurückgestellt. Dieser Backend-Checkpoint ändert ausschließlich Prozess-/Statusdokumentation; keine Builds oder Anwendungstests ausgeführt.

## Radar-Cache Stufe 1 in Swift (30. Oktober 2026)

Die Python-Fassung ist entfernt; Ersatz: Swift 6 / Vapor 4 (`Sources/RadarCore`, `Sources/radar`), `Tests/`, `migrations/`, `deploy/swarm/` (nach Vorlage des Projekts todo), `deploy/swarm/swarm-deploy.sh`, `Dockerfile`, `compose.yaml`, `.env.example`. Entscheidungen: [decisions.md](decisions.md).

Tatsächlich ausgeführt (lokal, Linux-Container swift:6.4-noble, arm64):
- `swift test`: 24 Tests grün, Contract-Tests je einmal gegen den Fake und gegen eine Wegwerf-MariaDB 12.3 (Claim-Konkurrenz, Lease-Übernahme, Versuchslimit, Cooldown, atomare Veröffentlichung, Retention, 404-freies latest.json der letzten 3 Läufe, ETag/304, Single-Flight, kein Set-Cookie, identische Manifeste, BLOB-Roundtrip) plus Bild-Tests (WebP pixelgenau).
- Paritätsvergleich an einem Live-DWD-Bild (1024x1311): Python- und Swift-WebP dekodieren pixelidentisch zum DWD-PNG; Größe Python 5890 B, Swift 5878 B, PNG 44680 B.
- Echter lokaler Docker-Swarm (selbst angelegt, davor inaktiv), Wegwerf-MariaDB 12.3: `setup.sh` (non-interactive, Antwortdatei, Dry-Run), Secret, Migrationsjob, 3 Replikate mit bash-Healthcheck, `update.sh --tag` Rolling Update, manueller Rollback, automatischer Rollback bei kaputtem Image (`.env` wird zurückgesetzt), fehlgeschlagener Migrationsjob verhindert den Rollout. Ein echter DWD-Lauf: latest.json 404 -> 200 mit 25 Slots, ETag/304, immutable-Header, byteidentisches Manifest über alle Replikate, kein Set-Cookie.
- `shellcheck`, `docker compose config` lokal.

Docker-publish ist inzwischen grün (Commit `8d3d487`; Tags `edge`, `latest`, `sha-8d3d487`; amd64 und arm64). Nicht geprüft: Tag-Lookup `edge` -> `sha-` gegen das veröffentlichte ghcr.io-Paket (Paket muss noch öffentlich gestellt werden), amd64 lokal, Last, Reverse-Proxy, Betrieb auf dem echten Swarm des Betreibers.
Nächste Schritte: CI und Docker-publish prüfen; ghcr.io-Paket öffentlich stellen; Betreiber führt `deploy/swarm/setup.sh` aus (DB-User braucht CREATE für den Migrationsjob). Server-Installation per flachem Klon des Branches `deploy` (siehe decisions.md); Deploy-Skripte liegen jetzt komplett in `deploy/swarm/`, `stack.env.example` und `scripts/` sind entfernt, `update.sh --pull-scripts` neu. Geprüft am 30. Oktober 2026: shellcheck, compose config, --help/--dry-run von setup.sh und update.sh, Pages-Build, realer Swarm-Rauchtest (setup.sh, Migrationsjob, /healthz 200 im Replikat, update.sh --pull-scripts --tag <sha> --force) aus einem flachen Klon von deploy; Swarm danach verlassen. Von außen nicht geprüft: Ingress-Port (lokales Colima), echter DWD-Lauf, update.sh --pull-scripts mit tatsächlich neuen Commits (nur "Already up to date"), Tarball-Weg (nicht dokumentiert).

## Dokumentationsseite (30. Oktober 2026)

GitHub-Pages-Seite mit Installationsanleitung unter `docs-site/` (Generator, Inhalte), Workflow `.github/workflows/pages.yml`, Beschreibung in [pages.md](pages.md). Optionen und Variablen gegen `setup.sh --help`, `update.sh --help`, `.env.example` abgeglichen. Pages-Quelle und Veröffentlichung: siehe Git-Historie/Actions.

## Öffentliche Seiten (30. Oktober 2026)

`/datenschutz`, `/marketing`, `/support` im Radar-Dienst, Konfiguration über `OPERATOR_*` u. a. (siehe decisions.md und Dokumentationsseite „Datenschutz und Marketing-Seiten“). Tests: `Tests/RadarCoreTests/SitePageTests.swift`. Tatsächlich ausgeführt (lokal macOS, ohne Datenbank): `swift test` 32 Tests grün (24 bestehende + 8 neue), `docs-site` `npm ci && node build.mjs`, `git diff --check`, `shellcheck setup.sh` (nur Info SC1091). Nicht geprüft: MariaDB-Variante der Tests, echter Betrieb hinter dem Proxy. Offen: rechtliche Prüfung der Texte durch den Betreiber; Werte in der Server-`.env` eintragen und `update.sh` ausführen; die App-Ortssuche ist im App-Repo nicht datenschutzseitig dokumentiert und daher auf der Seite nicht erwähnt.

## Radar-Historie HISTORY_HOURS (30. Oktober 2026)

Umgesetzt: `HISTORY_HOURS` (Standard 48, 1-72) in `Config`, `.env.example`, `stack.yaml`; `migrations/002_history.sql` (Spalte `radar_run.backfilled`, Tabelle `radar_lock`, additiv, alte Replikate laufen unverändert weiter); `Repo` um `analysisSlots`, `settledRunTimes`, `acquireLeader/releaseLeader` und neue `retain` (Analyse-Slot bleibt HISTORY_HOURS + 15 min, Vorhersage-Slots älterer Läufe gehen nach `RETENTION_RUNS`); `Backfiller.swift` (Leader-Lease, 2 Worker, 3 s Abstand, max. 20 Requests je Durchlauf, 3 Versuche je Slot, 10 min Sperre je gescheitertem Slot, Pause nach 6 Fehlern in Folge, pausiert während des regulären Laufs, neueste zuerst, die 2 neuesten Raster-Slots bleiben dem regulären Lauf); `/v1/radar/history.json`; `latest.json` unverändert (Golden-Test `Fixtures/latest-before-history.json`, aus dem Stand vor der Änderung erzeugt).

Gemessen (Einzelrequests 30.10.2026): WMS-Zeitwerte bis 90 h zurück abrufbar (auch 24/48/60/72/84 h), 96 h und 108 h je fünfmal XML-Fehler; GetCapabilities nennt nur einen veralteten Zeitbereich und taugt nicht als Grenze. Daher Maximum 72 h. Bildgrößen (trocken bis leichter Regen): WebP 6-29 KB, PNG 45-111 KB. Starker Regen wurde nicht gemessen (Annahme bis ca. 50 KB). Rechnung: 576 Slots, ca. 850 Requests einmalig, bei 20 Requests/min ca. 45-60 min.

Geprüft: `swift test` lokal (macOS) mit Wegwerf-MariaDB 12.3: 46 Tests grün (Fake und MariaDB), 981 s (Debug-Build, PNG-Erzeugung langsam); ohne DB 46 Tests (Fake). Echter Rauchtest mit `HISTORY_HOURS=2`: Backfill lief, `history.json` mit 23 Analyse-Slots aufsteigend, Slot per Pfad abrufbar (WebP, ca. 6,5 KB), ETag/304, `latest.json` byteidentisch vor/nach Backfill, 22 nachgeholte Läufe plus der reguläre. Nicht geprüft: Betrieb mit 48 h auf dem echten Swarm, Regen-Bildgrößen, Mehrreplikat-Leaderwechsel im echten Swarm (nur Test gegen MariaDB).

## Datenschutzseite: Apple-Karte und Ortssuche (31. Oktober 2026)

`/datenschutz` hat den neuen Abschnitt 6 „Kartenansicht und Ortssuche (Apple)“ (Quelle: Diagnosebericht des App-Repos, Teil 2); Test `privacyMentionsAppleMapsAndSearch`, `docs-site/content/seiten.md` und `decisions.md` angepasst. Offen: Betreiberfreigabe des Textes; Apples Datenverarbeitung nicht geprüft.

## Pushdienst Backend ohne Apple-Konto (31. Oktober 2026)

Umgesetzt (Details: [decisions.md](decisions.md), API: `docs-site/content/api.md`): Migration `003_push.sql`, `PushRepo` in `MariaRepo` und `MemoryRepo`, Registrierungs-API `/v1/push/…`, Pixel-zu-Klasse-Zuordnung, Zustandsautomat, Auswertung nach neuem Lauf, Outbox, `ApnsSender` mit `FakeApnsSender` und `ApnsClient` (JWT/HTTP2-Transport), Leader `push`, 410-Bereinigung, Retention. Standardmäßig deaktiviert (`PUSH_ENABLED`).

Geprüft (31.10., macOS, Debug): `swift build` ok; `swift test` 83 Tests grün ohne DB (Fake) und 83 Tests grün zusätzlich gegen Wegwerf-MariaDB 12.3 (Docker, tmpfs). Neue Tests: `Tests/RadarCoreTests/PushTests.swift` (Automat, Farbzuordnung, Repo-Vertrag Memory+MariaDB, API, ApnsClient mit Fake-Transport inkl. JWT-Signatur, PushService mit FakeApnsSender).

Nicht geprüft/offen: kein Aufruf des echten APNs (kein Key, kein Gerät); die Farbzuordnung ist nicht gegen echte Radarpixel verifiziert (nur gegen die Legendentabelle); Last und Leader-Wechsel nicht gemessen; `stack.yaml`/`setup.sh` nicht um Secret und `APNS_*` erweitert (absichtlich, sonst scheitert der Rollout ohne Secret); `/datenschutz` unverändert (Änderungsbedarf in decisions.md); Ruhezeiten, Obergrenze Installationen, Proxy-Rate-Limit offen. Nutzeraufgaben: APNs-Key und Push-Capability anlegen, Secret `showernow_apns_key` erzeugen, Stack um Secret/Variablen erweitern, Datenschutztext und App-Privacy freigeben, Test auf Gerät (Sandbox/TestFlight).
