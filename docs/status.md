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

## Radar-Cache Stufe 1 (30. Oktober 2026)

Umgesetzt: `ingest/` (Python-Dienst: Claim, Ingest, Veröffentlichung, API mit LRU/ETag), `ingest/migrations/`, `deploy/swarm/` (Stackfile, `setup.sh`, `update.sh`, `stack.env.example`), GitHub-Workflows (CI mit MariaDB-Service, Image-Publish nach ghcr.io). Entscheidungen: [decisions.md](decisions.md).

Geprüft (tatsächlich ausgeführt, lokal): `ruff check`; alle Unit-Tests mit In-Memory-Fake und zusätzlich gegen eine lokale MariaDB 12.3 (Wegwerf-Container) inklusive Claim-Konkurrenz, Lease-Übernahme, atomarer Veröffentlichung, Retention, ETag/304, Single-Flight; `shellcheck` für beide Skripte; `docker compose config` für das Stackfile; Docker-Build des Images (arm64); Rauchtest des Containers gegen lokale MariaDB mit echtem DWD (ein Lauf, 25 Slots veröffentlicht, `latest.json` ausgeliefert, Healthcheck healthy).
Nicht geprüft: Ausführung von `setup.sh`/`update.sh` und `docker stack deploy` auf einem echten Swarm; Mehr-Replikat-Betrieb unter Swarm (Konkurrenz nur per Threads/Fake und DB-Test); GitHub-Actions-Läufe; amd64-Build; Lastverhalten bei Regenlage; Zoraxy-Anbindung; ghcr.io-Veröffentlichung.
Manuell durch den Betreiber: DB und Benutzer anlegen, `setup.sh` (Secret, `stack.env`), Paketsichtbarkeit auf ghcr.io, Actions-Berechtigung, Proxy-Upstream, optional DWD-Anfrage.
Nächste Schritte: App-Anbindung (Build 9, separater Auftrag); Praxisbeobachtung der Fehlerrate des DWD und der Ingest-Dauer; Nasslagen-Größen messen; optional nginx-Cache-Sidecar; später Benachrichtigungen auf derselben Pipeline.
