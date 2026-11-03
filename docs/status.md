# Fortsetzbarer Arbeitsstand

Stand: 1. November 2026. Identität: ShowerNow / `de.linolaske.showernow`, Team `J2DU2P47XW` (endgültig). App-/TestFlight-Stand: [Apple-Arbeitsstatus](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md). Die Abschnitte ab „Auftrag und Freigabe“ sind chronologische Checkpoints (älter = weiter oben); dieser Kopf gilt zuerst.

## Umbenennung Showers: sichtbare Texte (3. November 2026)

Nutzerentscheidung 3.11.2026: App heißt künftig Showers; nur Optisches wird umbenannt. Geändert: Seiten (`SitePages.swift`), APNs-Titel (Live-Activity-Start und Testmeldung), zugehörige Tests, `docs-site` (Marke, `api.md`, `seiten.md`, `index.md`), README. Unverändert: Domain `showernow.linolaske.de` (`showers.linolaske.de` zeigt laut Nutzer aufs selbe Backend), DB-/User-Name, Secrets, Lock, Compose/Swarm, Image, APNs-Topic, User-Agent. Code hat keinen Host-/CORS-Check. Geprüft: `swift build`, `swift test --filter "SitePage|PushActivity|PushTests"` 121 Tests grün. Nicht geprüft: DB-Suite (nur Texte), Rollout, curl gegen beide Hosts. **Betreiber:** nach Rollout erscheint der Push-Titel „Showers“ auch bei Nutzern mit der alten App-Version (ShowerNow). Commit `3df0c8d`; CI, Docker publish (Image `edge`) und Pages erfolgreich. Kein Rollout.

## Live Activity Push gepusht (3. November 2026)

Commits auf `main`: `5e64b24` (docs: Dashboard-Plan), `49321e4` (feat: Live Activity Push inkl. Migration 007/008, Haertung, Regen-Start, Doku). Vor dem Push: `swift build` und `swift test --filter PushActivity` (48 Tests) gruen; volle Suite zuvor 199 Tests gruen gegen Wegwerf-MariaDB. CI-Laeufe zum Push: CI, Docker publish (Image `edge`), Pages, Deploy branch alle erfolgreich. **Kein Rollout:** Betreiber braucht `update.sh --pull-scripts --force`, Datenbankrechte ALTER/CREATE/INDEX fuer Migration 007/008, optional `PUSH_MAX_ACTIVITY_SUBSCRIPTIONS`, APNs-Key und Push aktiviert. Nicht geprueft: echtes APNs/ActivityKit am Geraet, Rollout.

## P2 Backend Live-Activity-Push (3. November 2026, Implementierung und Tests zur Abnahme)

Nutzerauftrag additiv nach dem App-Vertrag (Abschnitte 5/6), dort nur gelesen. Vorhandenen Diff übernommen und vervollständigt. Fortsetzung auf ausdrücklichen Nutzerwunsch ohne Teilagenten; nur dieses Repo geändert. Kein Rollout, Commit oder Push; keine neue Rechercheablage.

- Umsetzung: Migration `007_push_activity.sql`, optionale Start-/Activity-Token und `live_activity=false`, Memory-/MariaDB-Persistenz, API, Capability `live_activity`, eigener APNs-Pfad und Start/Update/Ende. Nur aktivierte Ortsabos, ein belegter Activity-Platz je Installation einschließlich Reservierung, Rotation ohne Fristverlängerung, Acht-Stunden-Ende auch ohne neuen Radarlauf. API-Form, ContentState-Datumsformat und Datenschutz in der [API-Referenz](../docs-site/content/api.md#live-activities-additiv-nur-ortsabos); Wiederanlaufgrenzen und P8-Vertrag in [decisions.md](decisions.md#p2-backend-live-activity-push-3-november-2026).
- Tests ergänzt: `Tests/RadarCoreTests/PushActivityTests.swift` (21 neue Tests für veröffentlichte Radar-Fixtures mit Fake-Sender, Lebenszyklus/60-Minuten-Sperre/Acht-Stunden-Ende, Token-Rotation/410, Reservierung/Limit/Cascade, API-Felder/alte Requests/Validierung/Ratenlimit, APNs-Header/Umgebung, Payload/Codable-Daten und 4-KB-Grenze); vorhandene Capability-Erwartung in `PushTests.swift` erweitert.
- Prüfstand: `swift build` vom Nutzer/Hauptagenten als grün gemeldet, nicht in dieser Fortsetzung wiederholt. Testcode durch Lesen auf Signaturen und Ablauf geprüft; `git diff --check` erfolgreich. **Nicht geprüft:** Kompilierung/Ausführung der neuen Tests (`swift test` übernimmt der Hauptagent, auf Nutzeranweisung hier nicht ausgeführt), Migration/Transaktionen gegen MariaDB, echte APNs-/ActivityKit-Zustellung, Geräteverhalten und P8-Decodierung.
- Nächster Schritt: Hauptagent führt `swift test` aus und nimmt die Tests ab. Danach separater MariaDB-Test und App-/Geräteabgleich vor einem gesondert freizugebenden Livegang. Activity-Versand hat keine persistente Nachrichten-Outbox: bei unklarem Start bleibt der Platz reserviert, Updates versuchen es mit dem nächsten Lauf erneut, Ende beim nächsten Tick; Prozessabbruch kann eine Nachricht auslassen. Normale Push-Outbox unverändert.

## Live Activity startet bei laufendem Regen (3. November 2026, lokal, nicht committet/deployt)

Umgesetzt (Details: [decisions.md](decisions.md#live-activity-startet-auch-bei-laufendem-regen-3-november-2026-lokal-nicht-committetdeployt)): zusätzlicher Startweg bei bekannt nassem aktuellem Slot in zwei aufeinanderfolgenden vollständigen Läufen, gemeinsame 60-Minuten-Sperre mit dem Regenbeginn-Start, Hysterese-Bit in `push_sub.state` (keine Migration), eigener Startalert „Es regnet gerade“ / „It is raining right now“ (Apple verlangt einen Alert beim Start). Dateien: `PushService.swift`, `PushActivity.swift`, `PushModels.swift`, `MariaRepo+Push.swift`, `MemoryRepo+Push.swift`, `PushActivityTests.swift`, `api.md`, `decisions.md`.

Prüfung: `swift build` grün; `swift test` komplett gegen Wegwerf-MariaDB 11 (Docker, tmpfs, Container entfernt): 199 Tests in 35 Suiten bestanden (1111 s); davon 9 neue (8 Verhalten mit Memory-Fake-Sender, 1 Persistenztest Memory und MariaDB). Bestehende Tests unverändert grün. **Nicht geprüft:** echtes APNs/ActivityKit am Gerät (insbesondere ob der Startalert-Text wie erwartet erscheint), Last, Rollout, echte DWD-Maskenpixel.

## Live-Activity-Review Runde 3 (3. November 2026, lokal, nicht committet/deployt)

Umgesetzt (Details: [decisions.md](decisions.md#live-activity-review-runde-3-3-november-2026)): Activity-Limit unter Nebenläufigkeit (READ COMMITTED plus sperrende Lesezugriffe, keine Migration), unbekannte Radarpixel bestätigen kein Activity-Ende, tokenloser Endepfad löscht keinen später gemeldeten Token, Startalert in Installationssprache.

Prüfung: `swift build` grün; `swift test` komplett gegen Wegwerf-MariaDB 11 (Docker, tmpfs, entfernt): 189 Tests in 34 Suiten bestanden (1089 s). Nebenläufigkeitstest schlug ohne Fix reproduzierbar fehl. **Nicht geprüft:** echte DWD-Maskenpixel (Alpha-Annahme 16..127), APNs/ActivityKit am Gerät, Rollout.

## Live-Activity-Härtung A1/A6/A7/A8 (3. November 2026, lokal, nicht committet/deployt)

Umgesetzt (Details: [decisions.md](decisions.md#live-activity-härtung-a1a6a7a8-3-november-2026)): Sammelabfragen je Auswertungsseite, Ablaufprüfung nur über Activity-Zeilen, Activity-Versand nach den Alerts mit Budget (200 Sendungen/8 s je Tick), `live_activity=true` nur mit Start-Token (`409 start_token_required`) und Obergrenze `PUSH_MAX_ACTIVITY_SUBSCRIPTIONS` (Standard 5 000, `503 activity_full`), Migration `008_push_activity_index.sql`, kurzer Pfad ohne DB-Zugriff vor Limits/Format, Reservierung per `DELETE` ohne Token löschbar plus 15-Minuten-Timeout, `BadDeviceToken` auf das Start-Token räumt Token und Reservierung. Tests: `PushActivityTests.swift` (neue Suites Hardening und Bulk-Repo, Letztere auch gegen MariaDB).

Prüfstand: siehe Abschnitt „Prüfung“ unten in diesem Block.

## Backend-Härtung (2. November 2026, lokal, nicht gepusht, nicht deployt)

Umgesetzt (Security-Review H1/H2/M1/M2, Entscheidungen in [decisions.md](decisions.md), Tests `HardeningTests.swift`): serverweite Obergrenzen Installationen/Abos (`503 server_full`, `PUSH_MAX_*`), Auswertung in Seiten (`evaluationSubscriptions(after:limit:)`, 2 000 je Seite), Zellbudget 50 Mio. und Summe 30 s gemerkt statt GROUP BY je Request, Rate-Limiter mit Verdrängung, `global:any`-Rate, Fehlversuchszähler je Installation, `status()` 5 s Memo, Negativ-Cache (10 s) für fehlende Slots, `authenticate` mit einer Query (`last_seen_at` höchstens stündlich). Keine Migration. Nicht gebaut: Registrierungsschutz (Frage am Todolino-Board), Aktivierung neuer Installationen erst nach Token-Test. Geprüft (2.11., macOS, Debug): `swift build`; `swift test` 151 Tests grün gegen Fake und Wegwerf-MariaDB (Docker, tmpfs, danach entfernt), 20+ neue Tests in `HardeningTests.swift`; zwei bestehende Tests angepasst (Rate-Limit-Zählung, `RegionLimits` explizit 2 Mio.). Nicht geprüft: Last, Verhalten im echten Swarm. Betreiber: optional `PUSH_MAX_*` in der `.env`, sonst Defaults; kein ALTER nötig.

## Aktueller Stand (1. November 2026)

Auf `main` (letzter Code-Commit `881edeb`): Radar-Cache (Swift/Vapor, produktiv unter https://showernow.linolaske.de), `history.json`, öffentliche Seiten `/datenschutz`, `/marketing`, `/support`; Pushdienst (optional, Standard aus: Registrierungs-API, Auswertung, APNs-Versand, Testmeldung, `time_sensitive`, Migrationen 003/005); **Push-Regionen Version 1 (Umkreis)** `34e6416` (Migration 006, `capabilities: ["regions"]`); Zusatzebenen `37e5f2e` (`pressure`, `lightning`, `clouds`, `cloudmask`, Migration 004) und Welle 2 `881edeb` (`pressure_eu`, `cloudmask_vis`, `cloudmask_vis_eu`, eigene Bildausdehnung je Ebene im Manifest); Overlay `deploy/swarm/stack.push.yaml` und Push-Fragen im `setup.sh` (`d523cc1`); `GET /v1/status` (Ebenen, `push`, `capabilities`, `revision`). Zuletzt gemeldet: `swift test` 131 Tests grün (Fake/Memory; MariaDB-Läufe bei 124 Tests mit Regionen grün).

**Nicht geprüft:** echter APNs-Aufruf (nur Fake; Push-Registrierung in der App wurde vom Nutzer am Gerät bestätigt, Zustellung nicht), Farbzuordnung gegen echte Regenpixel, Last und Leader-Wechsel, MariaDB-Last durch Ebenen/Regionen, Rollout des Overlays im echten Swarm, EUMETView-Verfügbarkeit nachts (22:30 bis 01:30 UTC lieferte keine Bilder).

**Diagnose-Ergebnis:** Die Zusatzebenen antworteten live mit 404, weil `LAYERS` in der Server-`.env` fehlte bzw. durch `setup.sh --reconfigure` verloren gegangen war (Ursache im Code behoben: `--reconfigure` übernimmt `LAYERS` und Tuning); erst nach Korrektur durch den Betreiber lieferten die Ebenen Daten. Hilfen: `GET /v1/status` und Betriebsseite „Fehlersuche Ebenen 404“.

## Übergabe-Checkliste für den Betreiber

- [ ] Server auf neuestes Image/Skripte: `deploy/swarm/update.sh --pull-scripts --force` (gleicher Tag braucht `--force`).
- [ ] `.env`: `LAYERS=pressure,pressure_eu,lightning,clouds,cloudmask,cloudmask_vis,cloudmask_vis_eu` (je nach Wunsch); Speicherbedarf der Datenbank beobachten (Europa-Bilder größer).
- [ ] DB-Benutzer mit `ALTER`-Recht für die additiven Migrationen 005 und 006 (004 braucht CREATE).
- [ ] `curl <Basis-URL>/v1/status`: Ebenen `enabled`/`has_data`, `capabilities` enthält `regions`, `revision` passt.
- [ ] Push (optional): APNs-Key, Secret `showernow_apns_key`, `PUSH_ENABLED=true`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_ENV` (siehe Installationsseite und App-Repo `docs/apns-einrichtung.md`); danach Testmeldung aus der App.
- [ ] **Vor Livegang von Push/Regionen:** Text `/datenschutz` ergänzen (siehe offene Punkte), App-Privacy Variante B in App Store Connect.
- [ ] Zoraxy: IP-Zugriffslog abschalten oder kürzen, Rate-Limit am Proxy (E7/E8), `PROXY_LOG_NOTE` anpassen; Rechtsprüfung/Impressum (`OPERATOR_*`).

## Offene Punkte (Backend)

1. `/datenschutz` und Dokumentationsseite enthalten noch nichts zu Regenwarnungen/Push, Regionen, Testmeldung und zur EUMETSAT-Quelle (Attribution „Contains modified EUMETSAT Meteosat data 2026“ für Wolken-/Sonnenebenen); Text bewusst noch nicht geändert, Freigabe durch den Nutzer nötig (Änderungsbedarf in [decisions.md](decisions.md)).
2. MariaDB-Last: Ebenen (insbesondere Europa, Bilder bis etwa 17 MB dekodiert in der App) und Push-Auswertung nicht unter Last gemessen.
3. Regionen-Zellbudget (8000 je Installation) ist serverweit nicht transaktionssicher über Installationen (weicher Wert); Zusammenfassung mehrerer Abos eines Geräts (R2b) nicht umgesetzt.
4. APNs: unbelegt, ob ein umgebungsbeschränkter Key am falschen Host `InvalidProviderToken` oder `BadDeviceToken` liefert; TestFlight = Produktionstoken nur aus dem Profil abgeleitet.
5. Möglich später: Druck-Farbfläche über GRIB (libaec), Live Activities (App-Repo-Recherchen).

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

Nicht geprüft/offen: kein Aufruf des echten APNs (kein Key, kein Gerät); die Farbzuordnung ist nicht gegen echte Radarpixel verifiziert (nur gegen die Legendentabelle); Last und Leader-Wechsel nicht gemessen; `stack.yaml`/`setup.sh` zunächst nicht um Secret und `APNS_*` erweitert (später per Overlay umgesetzt, siehe unten); `/datenschutz` unverändert (Änderungsbedarf in decisions.md); Ruhezeiten, Obergrenze Installationen, Proxy-Rate-Limit offen. Nutzeraufgaben: APNs-Key und Push-Capability anlegen, Secret `showernow_apns_key` erzeugen, Stack um Secret/Variablen erweitern, Datenschutztext und App-Privacy freigeben, Test auf Gerät (Sandbox/TestFlight).

## Push-Erweiterungen (31. Oktober 2026)

Umgesetzt (Details: [decisions.md](decisions.md), API: `docs-site/content/api.md`): Testmeldung `POST /v1/push/installations/<uuid>/test`, Abo-Feld `time_sensitive` (Migration `005_push_time_sensitive.sql`), klare Umgebungs-/Schlüsselfehler, Apple-Reasons im Log, Doku zu Schlüssel und `APNS_ENV`. Geprüft (31.10., macOS, Debug): `swift build` ok; `swift test` 105 Tests grün ohne DB (Fake) und zusätzlich gegen Wegwerf-MariaDB 12 (Docker, tmpfs, danach entfernt; Migration 005 lief dabei). Neue Tests in `PushTests.swift`: Testmeldung (Payload, Auth, Rate-Limit, Fehlerabbildung, kein Geheimnis in Antworten), `time_sensitive` (API, Repo Memory+MariaDB, Payload), `APNS_ENV=both` mit Host je Installation.

Offen/Nutzeraufgaben: echter APNs-Aufruf nie geprüft (Testmeldung gegen Fake); ob ein umgebungsbeschränkter Schlüssel am falschen Host `InvalidProviderToken` oder `BadDeviceToken` liefert, ist unbelegt; Datenbankrecht `ALTER` für den Migrationsbenutzer; für Produktion `PUSH_ENABLED=true`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_ENV` und Secret `showernow_apns_key` (Stack weiter nicht verdrahtet); Time-Sensitive-Entitlement in der App; `/datenschutz` weiter nicht geändert.

## Zusatzebenen (31. Oktober 2026)

Umgesetzt: `LAYERS`-Schalter, Ebenen pressure/lightning/clouds/cloudmask, Migration 004, `LayerIngestor`, `LayerManifest`, Routen, Tests (`LayerTests.swift`, Fake-Quellen, Memory und MariaDB). Geprüft (macOS, Debug): `swift build`; `swift test` 94 Tests grün gegen Fake und Wegwerf-MariaDB 12.3 (tmpfs, danach entfernt); live gegen DWD/EUMETView einzeln per curl geprüft (GetMap 200, EPSG:3857). Offen: Lauf im echten Dienst, Lastbeobachtung, App-Anbindung.

## Push im Stack, Status-Endpunkt, Fehlersuche (31. Oktober 2026)

Umgesetzt (Details: [decisions.md](decisions.md)): Overlay `deploy/swarm/stack.push.yaml` (nur bei `PUSH_ENABLED=true` eingebunden), APNS-Variablen in `stack.yaml`, Secret-Prüfung in `update.sh`/`swarm-deploy.sh`, Push-Fragen im `setup.sh`, `LAYERS` und Tuning bleiben bei `--reconfigure` erhalten, Workflow `deploy-branch.yml` spiegelt `stack.push.yaml`, `GET /v1/status` (Tests in `LayerTests.swift`), `BUILD_REVISION` (Dockerfile-Argument, Workflow), Fehlersuche „Ebenen 404“ in `docs-site/content/betrieb.md`.

Geprüft (macOS): `swift build`; `swift test` 107 Tests grün (Fake, ohne Datenbank; MariaDB-Fälle nicht gelaufen); `bash -n` und ShellCheck der Skripte; `docker stack config` mit/ohne Overlay (Secret nur mit Overlay, Variablen durchgereicht); `setup.sh --dry-run --non-interactive` mit Push an/aus; `update.sh` mit gefälschtem `docker` (Secret fehlt: Abbruch vor jeder Änderung). Nicht geprüft: Verhalten eines fehlenden externen Secrets und Rollout mit Secret in einem echten Swarm; echter `docker secret create` im Assistenten; Deploy-Branch-Spiegelung siehe Bericht des Pushs.

Nutzeraufgaben: auf dem Server `deploy/swarm/update.sh --pull-scripts --force` (holt Skripte und Overlay, gleicher Tag braucht `--force`); für Push zuvor Secret `showernow_apns_key` anlegen und in der `.env` `PUSH_ENABLED=true`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_ENV` setzen; für Ebenen `LAYERS=...` in der `.env`; danach `curl /v1/status`. `/v1/status` und `BUILD_REVISION` gibt es erst mit einem neu gebauten Image.

## Push-Regionen Version 1: Umkreis (1. November 2026)

Umgesetzt (Pakete R0 bis R2 des App-Entwurfs `push-regionen.md`, Entscheidungen in [decisions.md](decisions.md), API in `docs-site/content/api.md`): Migration `006_push_region.sql` (additiv, idempotent), `PushRegion.swift` (Kreis-Geometrie, 3×3-Mittelpunktrundung, Auslöseregel, Pseudo-Wert), `PushRepo` in Memory und MariaDB (Felder, Limits `region_limit`/`region_capacity`), API additiv (ohne neue Felder gilt weiter ein Ort), Auswertung im bestehenden `PushService.evaluate` mit unverändertem `PushEvaluator.step`, Payload-Variante `RAIN_REGION_STARTS_IN` (`region: true`), `GET /v1/status` mit `capabilities`. Testmeldung und `time_sensitive` unverändert.

Geprüft (1.11., macOS): `swift build`; `swift test` 124 Tests grün, einmal ohne Datenbank (Fake/Memory) und einmal gegen Wegwerf-MariaDB 12 (Docker, tmpfs, danach entfernt); Migration von Hand an einer 001-005-Datenbank mit Altabo angewendet, zweimal (idempotent, Altabo bleibt `kind=0`). Neue Tests in `PushTests.swift`: Geometrie und Regel, Repo-Vertrag Memory+MariaDB (Felder, Grenzen, Update), API (Rundung, Validierung, 409, Rückwärtskompatibilität, Status), Auswertung mit Fake-APNs (Anteil, Mindestzellen, Payload).

Benchmark (`PushRegionBenchmark`, nur mit `RADAR_BENCH=1`; synthetisches 1024×1311-Bild mit 15 % Regenfläche in Legendenfarben, kein echtes DWD-Bild; Apple Silicon, Ergebnisse pro Lauf = 25 Slots): Klassenkarte 1 ms je Slot, WebP-Decode 2 ms (9 KB, bei echtem Starkregen größer). Release-Build: 400 Kreise r40 (2 Mio. Zellen) 40 ms, 3 260 Kreise r14 80 ms, 13 400 Kreise r7 170 ms, fester Anteil 25 × (Decode + Klassenkarte) 90 ms, also unter 0,3 s je Lauf bei serverweit vollem Budget. Debug-Build (Tests) etwa 30-mal langsamer (3,5 bis 6,4 s je Lauf), reicht ebenfalls. Folge: Limits (3 Regionen, 8 000 Zellen, 2 Mio.) bleiben unverändert; sie sind nicht durch die Rechenzeit begrenzt, sondern durch Missbrauchsschutz. Nicht gemessen: echte Radarbilder mit großen Regenflächen, Datenbanklast bei vielen Abos (`evaluationSubscriptions` lädt alle aktiven Abos in den Speicher).

Offen: Server-weites Budget ist nicht transaktionssicher über Installationen (weicher Wert); Zusammenfassung mehrerer Abos eines Geräts (R2b) nicht umgesetzt; App braucht Strings `RAIN_REGION_STARTS_IN`; `/datenschutz` weiter ungeändert (Änderungsbedarf in decisions.md).

Nutzeraufgaben: Datenbankrecht `ALTER` für den Migrationsbenutzer (wie schon für 005); Update mit `deploy/swarm/update.sh --pull-scripts --force` (neues Image mit Migration 006), danach `curl <Basis-URL>/v1/status` auf `capabilities` prüfen; Datenschutztext vor Livegang der Regionen freigeben.

## Ebenen mit eigener Bildausdehnung, Europa-Druck, sichtbarer Kanal (1. November 2026)

Umgesetzt (Entscheidungen: [decisions.md](decisions.md), API: `docs-site/content/api.md`): `LayerSpec` mit eigener `bbox`/Breite/`maxAttempts`/Vollständigkeitsstufe; neue Ebenen `pressure_eu`, `cloudmask_vis`, `cloudmask_vis_eu`; `SunElevation.swift` für die Nachtlogik; neue Variablen `PRESSURE_EU_FORECAST_HOURS`, `CLOUDMASK_VIS_HISTORY_HOURS`, `CLOUDMASK_VIS_EU_HISTORY_HOURS` in `Config`, `.env.example`, `stack.yaml`, `setup.sh` (Übernahme bei `--reconfigure`), Dokumentation (api, installation, betrieb, README). `/v1/status` listet die neuen Ebenen. Keine Migration.

Geprüft (macOS, Fake/Memory, MariaDB nicht nötig, da keine Migration und keine neue Tabelle): `swift build`, `swift test` 131 Tests grün (neu: Konfiguration/IDs/Spaltenlängen/4096-Grenze, Request-URLs mit Europa-bbox, Sonnenhöhe, Dunkelzellen, Europa-Manifest mit bbox/bbox_wgs84/Größe, Nachtbild wird veröffentlicht, Tagbild mit schwarzer Fläche verworfen, Europa über der Tag-Nacht-Grenze). Live (1.11.2026 gegen DWD und EUMETView, je ein Durchlauf des echten `LayerIngestor` mit Memory-Repo): `pressure_eu` 3 Slots à etwa 170 KB (2048 x 2168; der Lauf 06 UTC war noch nicht angeboten, Rückfall auf 00 UTC wie vorgesehen), `cloudmask_vis` 7 Slots 37 bis 269 KB (1024 x 1311), `cloudmask_vis_eu` 7 Slots 546 bis 836 KB (2048 x 2168); Dämmerungs-/Teilnachtbilder wurden nicht fälschlich verworfen. Nicht geprüft: Betrieb auf dem Server, Last über Tage, MariaDB-Läufe, Tagbild mit echtem fehlendem Kachelstück, Nachtbild mit exakt 0-Pixeln.

Nutzeraufgaben: `LAYERS` in der Server-`.env` um `pressure_eu,cloudmask_vis,cloudmask_vis_eu` ergänzen (je nach Wunsch), dann `deploy/swarm/update.sh --pull-scripts --force` (neues Image und `stack.yaml` mit den neuen Variablen). Speicherbedarf der Datenbank wächst bei Standardwerten um etwa 25 bis 40 MB (Details in decisions.md).

## Dashboard WP1: Datenmodell (3. November 2026)

Umgesetzt: `migrations/009_dashboard.sql` (additiv, acht Tabellen: `dashboard_credential`, `dashboard_challenge`, `dashboard_session`, `stats_daily`, `config_override`, `config_generation` mit globalem Zähler `config_revision`, `config_replica` mit `slot`, `config_audit`), Protokoll `DashboardRepo` (in `Repo` eingehängt) mit `DashboardRepo+Maria.swift` und `DashboardRepo+Memory.swift`, Tests `DashboardRepoTests.swift` (Memory und MariaDB). Stats nehmen nur feste Etiketten (`[a-z0-9_:.-]`, Metrik `[a-z][a-z0-9_]*`); Retention per `purgeDashboard` (Statistik 30 Tage, Audit 365 Tage, Replikate 10 min). Typen heißen `Dashboard*`, weil `ConfigOverrideRecord`/`ConfigAuditEntry` bereits in WP3 (`ConfigRegistry.swift`) vergeben sind; die Anbindung `ConfigStore` an `DashboardRepo` gehört zu WP3/WP5.

Geprüft: siehe Commit-Nachricht und Bericht (Dashboard-Tests Memory und MariaDB 11, komplette DB-Suite). Nicht geprüft: Migration gegen MariaDB 12.3 und Lastverhalten.
