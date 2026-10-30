# Projektstand und verbindliche Entscheidungen

Stand: 28. Oktober 2026. Aktueller App-Name: ShowerNow; Bundle-ID: `de.linolaske.showernow`. Entwicklung nach geklärten Einstiegsfragen freigegeben; Reihenfolge gemäß `plan.md`.

## Produkt

Native, werbefreie Regen-App mit nachvollziehbaren Datenzeitpunkten, kurzfristiger Ortsprognose und optionalen datensparsamen Regenwarnungen. Keine verpflichtenden Benutzerkonten. Lokale Ortsnamen bleiben auf dem Gerät.

## Vereinbarte Reihenfolge

1. DWD-Datenquellen, Radar und numerische Ortsprognose technisch validieren. Produkteigenschaften bleiben bis zur Prüfung offene Annahmen.
2. Eine eigenständig nutzbare iPhone-App fertigstellen: Regenradar, animierte Zeitleiste, Ortsprognose, Standort, lokale gespeicherte Orte, Datenalter, Cache, Light/Dark Mode und Regen-Widgets.
3. Bereits die erste brauchbare iPhone-Version intern über TestFlight im Alltag testen; nicht auf alle Plattformen oder das Backend warten.
4. iPadOS und macOS sind Ziele der ersten Produktversion mit angepasster Bedienung. watchOS ergänzt kompakte Ortsprognosen und Komplikationen. Die konkrete Release-Reihenfolge bleibt abzustimmen.
5. Erst nach der nutzbaren App den zentralen Pushdienst umsetzen. Automatische Regenwarnungen bei geschlossener App hängen von diesem Schritt ab.
6. Später Unterwegs-Warnungen, Wind- und Temperaturkarten, Wolken-/Satellitenansichten, tvOS und visionOS. visionOS zunächst im Simulator evaluieren; eigene Vision Pro ist nicht vorhanden.

Widgets sollen Regenstatus und/oder Niederschlagsverlauf für einen ausgewählten Ort zeigen und direkt dorthin verlinken. Aktualität und technische Machbarkeit ohne Backend sind zu prüfen. Umfang der Watch-Radaransicht und genaue Widgetgrößen sind noch offen.

## Architektur und Datenschutz

- Swift und SwiftUI; MapKit und CoreLocation für die Apple-App.
- Karte unabhängig vom eigenen Backend; Bilder grundsätzlich direkt vom Anbieter.
- Numerische Ortsprognose ohne Backend ist ein frühes Validierungsthema, noch keine bestätigte Datenkette.
- Zentraler Backend-Stack: Swift/Vapor, MariaDB, Docker Swarm; stateless Replikate, persistente Jobkoordination und Push-Outbox.
- Keine Serverregistrierung ohne aktivierte Pushabonnements.
- Für Warnungen möglichst Rasterzellreferenzen statt exakter Koordinaten, keine Ortsnamen und keine Bewegungshistorie übertragen.
- Keine Werbung, Analyse-SDKs oder verpflichtenden Konten.

## Identität und Veröffentlichung

- Lokale Zielordner heißen jeweils `weather`.
- Vorgesehene GitHub-Namen: `weather-apple` und `weather-backend`; öffentlich, sobald Zugang und Veröffentlichung möglich sind.
- Aktuelle Haupt-Bundle-ID: `de.linolaske.showernow` (Nutzerentscheidung vom 28. Oktober 2026); die frühere ID `de.linolaske.weather` ist historisch.
- Angegebene Apple Team ID: `J2DU2P47XW`; vor Signing mit dem Developer-Account bestätigen.
- App-Name ist verbindlich ShowerNow, Bundle-ID entsprechend geändert; technische Projekt-/Modulnamen bleiben Weather. Abhängige IDs für Widgets, Watch, App Groups etc. erst bei Target-Einrichtung festlegen.
- Aktueller Identity-/Signing-/TestFlight-Stand im [Apple-Repository](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md); dort bleiben alte Upload-IDs und Befunde historisch erhalten.
- AGPLv3 ist angestrebt. Lizenzentscheidung und mögliche Zusatzerlaubnisse für App-Store-Veröffentlichung sind offen. Es wird deshalb noch keine endgültige Lizenz behauptet.

## Quellenhierarchie

Aktuelle ausdrückliche Nutzerentscheidungen haben Vorrang. Dieses Dokument ergänzt und aktualisiert `concept-v2.md`, insbesondere hinsichtlich Plattformen und Reihenfolge. Das ursprüngliche Konzept bleibt als unveränderte Referenz erhalten.

## Verbindliche Arbeitsweise (Nutzerentscheidung vom 28. Oktober 2026)

Möglichst kostensparsam entwickeln. Agents sind Pflicht. Sessions müssen wegwerfbar sein und das Repo ist die Source of Truth; alle relevanten Ergebnisse und Entscheidungen sind immer im Repo zu dokumentieren. Der konkrete Prozess steht in `AGENTS.md`, der fortsetzbare Arbeitsstand in `docs/status.md`.

## Entwicklungsstart und Testgeräte (28. Oktober 2026)

- Nutzerfreigabe: Plan schreiben, Einstiegsfragen klären, danach anfangen. Alle drei Einstiegsfragen sind beantwortet; der Start ist damit freigegeben.
- iPhone 17 Pro und 18 Pro, Apple Watch Ultra, Apple-Silicon-Macs; jeweils 27er-Systemversionen. Zunächst diese Mindestgeneration der Betriebssysteme vorsehen.
- Erster interner TestFlight-Build nur mit brauchbarer iPhone-App; Widgets und Watch folgen danach.
- Damalige Freigabe: Vorläufige Identität Weather / de.linolaske.weather durfte für TestFlight verwendet werden. Durch die spätere verbindliche Umbenennung in ShowerNow / `de.linolaske.showernow` überholt; Team bleibt `J2DU2P47XW`.
- Datenvalidierung vor größerem UI-Ausbau; Backend bleibt zurückgestellt.

## Datenvalidierung — Arbeitsbefund

Ein direkter DWD-WMS-GetFeatureInfo-Request kann25Zeitpunkte als kleine JSON-Serie liefern. Bei einem nassen Kontrollpunkt stimmen alle Werte mit dem gleichen Rohdatenlauf überein. Dies ist ein validierter Kandidat für die direkte App-Ortsprognose, noch keine endgültige Datenadapterentscheidung. Die JSON-Property entspricht dort5-Minuten-Akkumulation; fehlende Werte, Laufaktualität und weitere Orte müssen vor Produktnutzung geprüft werden. Befunde im Apple-Repo unter `docs/research/`.

## Private lokale Repository-Zuordnung

Absolute lokale Repository-Pfade werden ausschließlich in der ignorierten `LOCAL_WORKSPACE.md` gespeichert. Öffentliche Dateien enthalten nur die Vorlage und GitHub-Verweise. `AGENTS.md` weist neue Sessions auf die optionale lokale Zuordnung hin. Diese Rechnerkonfiguration ist die Ausnahme zur versionierten Dokumentation; Produktentscheidungen, Prüfergebnisse und Arbeitsstände bleiben im Repo. Vor Veröffentlichung Ignore-Regel und Ausschluss aus dem Git-Index prüfen.

## Radar-Cache-Backend (Nutzerentscheidungen vom 30. Oktober 2026)

Vorrang vor dem früheren Stand "Karte unabhängig vom Backend" und vor der Reihenfolge "Backend erst nach nutzbarer App" für diesen Teil. Recherche und Messungen: [Apple-Repo, backend-radar-cache.md](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/research/backend-radar-cache.md).

- Es wird ein Radar-Cache-Backend gebaut; die App behält den DWD-Direktweg als Fallback. Es ist zugleich die Ingest-Basis für spätere Benachrichtigungen (noch nicht implementiert).
- Hosting existiert beim Betreiber (Docker Swarm, MariaDB 12.3, Reverse Proxy Zoraxy mit TLS/Domain) und ist nicht Teil dieses Repos. Dieses Repo liefert Stackfile, `setup.sh`, `update.sh` und Images über ghcr.io (GitHub Actions, amd64 und arm64 als Annahme).
- Das Repo ist öffentlich: keine Geheimnisse, echten Domains, IPs, Hostnamen oder Nutzerpfade; Konfiguration nur über Swarm-Secrets und Umgebungsvariablen mit Platzhaltern.
- **Replizierbarer Zustand in MariaDB (InnoDB), nicht in Dateien** (Änderung gegenüber dem ersten Entwurf mit Volume + nginx): Das Backend läuft mit mehreren Replikaten und soll später Benachrichtigungen übernehmen; gemeinsamer Zustand gehört in die vorhandene DB. Slots als MEDIUMBLOB (`radar_slot`), Läufe in `radar_run`. Größenordnung 25 Slots mal ca. 6-50 KB je Lauf, bei 16 Läufen Retention unter ca. 25 MB. Nicht die MEMORY-Engine (keine BLOBs, verliert Daten beim Neustart).
- **Auslieferung ohne nginx:** Die API-Replikate liefern selbst aus. Gründe: Zoraxy cached vermutlich nicht, der Cache muss im Stack liegen; ein einziger Service mit Healthcheck genügt; kein geteiltes Volume und keine Knotenbindung nötig. Pro Replikat ein byte-begrenzter LRU (64 MB; die aktuellen 37 Slots belegen etwa 0,2-2 MB, auch bei Regenlage mit Faktor 10 weit darunter) mit Single-Flight: DB-Zugriff nur bei Cache-Miss, je Replikat und Slot einmal. ETag/304 und `Cache-Control: immutable` (Slots) bzw. `max-age=30` (latest.json). Ein nginx-`proxy_cache`-Sidecar ist als spätere, standardmäßig deaktivierte Variante vorgesehen, nicht umgesetzt. Ein CDN vor Zoraxy würde ohne Änderung funktionieren.
- **Ingest genau einmal je Lauf über DB-Claim:** Atomares INSERT (Claim) auf `radar_run` mit Lease; abgelaufene Leases übernimmt ein anderes Replikat; Versuche pro Lauf begrenzt (2); fehlgeschlagene Läufe haben 240 s Cooldown. Veröffentlichung in einer Transaktion (Status `published` nur bei Besitzer und vollständigen 25 Slots); `latest.json` und Slot-Abruf sehen nur veröffentlichte Läufe. Leader-Election über `GET_LOCK` wurde verworfen, da Leases nach Absturz ohne Sitzungsbindung robuster und je Lauf nachvollziehbar sind. Lease-Zeiten kommen von der DB-Uhr.
- **Kein Redis:** Locks, Leases und gemeinsamer Zustand sind mit MariaDB abgedeckt, die Last (eine Handvoll Abfragen pro Lauf, Cache-Misses je Replikat) ist klein; eine zusätzliche Abhängigkeit hätte keinen klaren Mehrwert. Pub/Sub wäre erst bei Echtzeit-Push zwischen Replikaten sinnvoll.
- **Sprache (ERSETZT am 30. Oktober 2026): ~~Python 3.13 (Pillow, PyMySQL), nicht Swift/Vapor~~.** Die Python-Fassung war eine Abweichung vom ursprünglichen Plan (Swift/Vapor/MariaDB) und wurde nach Nutzerentscheidung vollständig durch eine Swift-Implementierung ersetzt, siehe Abschnitt "Radar-Cache in Swift (Nutzerentscheidung 30. Oktober 2026)". Verhalten und HTTP-Vertrag blieben unverändert.
- **Bildformat: verlustfreies WebP, 1024 x 1311 px**, DWD-Palette unverändert. Messung (Livebilder 30.10.2026): das DWD-PNG hat 259-260 verschiedene RGBA-Werte, PNG8 wäre daher verlustbehaftet; optimiertes PNG ca. 20 KB, verlustfreies WebP ca. 5,9 KB (PNG roh 44,7 KB). `TRANSPARENT=TRUE` liefert Transparenz außerhalb des Radars; die graue Abdeckungsmaske und die magentafarbene Randlinie des DWD bleiben erhalten.
- **DWD-Schonung:** Gemessen: etwa jede dritte GetMap-Antwort ist ein HTTP-200 mit XML-Fehler `InvalidDimensionValue`, unabhängig vom Lauf und vom Slot (wiederholte Anfragen desselben Slots wechseln zwischen Fehler und Bild). Deshalb: Validierung jeder Antwort, bis zu 6 Versuche je Slot mit Backoff (3-20 s plus Jitter), Probe des ersten Slots mit längerem Backoff für noch nicht veröffentlichte Läufe, nur 3 parallele Requests, ein Abruf je Lauf für alle Replikate, Start 200 s nach Nominalzeit plus Jitter, zusätzlicher Backoff bei Serienfehlern (max. 10 min), kein Nachholen alter Läufe. Rund 25-35 Requests je 5 Minuten. Eine schriftliche DWD-Bestätigung zu Spiegelung und Takt bleibt optional und offen.
- **Retention:** Standard 16, mindestens 15 veröffentlichte Läufe (12 historische Analysen der Zeitleiste, aktueller Lauf und 2 Läufe Reserve; die Konfiguration verweigert kleinere Werte). Damit bleiben die Slot-URLs auch eines `latest.json` der letzten 3 Läufe (Client-Cache 30-60 s, Test vorhanden) sicher auflösbar; Läufe in Arbeit werden erst nach 1 h Inaktivität gelöscht.
- **Replikate, keine Sessions:** Standard 2 (konfigurierbar), `start-first`-Rolling-Update, Rollback bei fehlgeschlagenem Healthcheck. Keine Cookies, keine Sticky Sessions; Swarm-Routing-Mesh Round-Robin. Der Healthcheck prüft nur Liveness (Prozess, HTTP, Ingest-Schleife), damit DWD- oder DB-Ausfälle nicht zu Neustartschleifen führen; die Datenalterung zeigt `latest.json` (`generated_at`).
- **Lizenzannahme:** CC BY 4.0 und GeoNutzV genügen für Zwischenspeichern und Weitergabe, mit Quellenvermerk "Quelle: Deutscher Wetterdienst" und Veränderungshinweis. Eine schriftliche Bestätigung des DWD ist optional und offen. Kein Rechtsrat.
- **Benachrichtigungen (später):** Ingest-Pipeline und DB sind dafür vorgesehen (Regenwarnungen, Punktprognosen, APNs-Abos). Es gibt bewusst noch kein Abo-Schema. Vorgaben: keine Standortverläufe, Abos nur grob/rasterisiert, APNs-Schlüssel nur als Swarm-Secret, Migrationen additiv.

## Radar-Cache in Swift (Nutzerentscheidung 30. Oktober 2026)

Das Backend ist Swift (wie ursprünglich geplant: Swift/Vapor/MariaDB); die Python-Stufe 1 ist entfernt. Verbindlich vom Nutzer außerdem nach Meldung, dass die Python-Fassung auf dem Swarm nicht lief und `setup.sh`/`update.sh` unbrauchbar waren.

- **Vorlage Referenzprojekt `todo`** (Swift/Vapor, nur gelesen): Struktur und Logik von `deploy/swarm/{setup.sh,update.sh,lib.sh,stack.yaml,healthcheck.sh}`, `scripts/swarm-deploy.sh` (Deployment-Sperre als Swarm-Config), `compose.yaml`, `Dockerfile` (`swift:6.2-noble`, `--static-swift-stdlib`, `ubuntu:noble`, nicht-root), CI und Docker-Workflow. Angepasst wurde nur Fachliches (Stack `radar`, Image `weather-backend-radar`, Port 38090, Secret `showernow_db_password`, DB `showernow`).
- **Eigentümer und Image fest:** `ghcr.io/magicalwig34653/weather-backend-radar:${RADAR_IMAGE_TAG:-edge}` im Stackfile, kein `OWNER`-Platzhalter, kein Image-Override. Tags: `edge` und `latest` (main), `sha-<commit>`, Version/`major.minor` bei `v*`-Tags.
- **Env-Dateien heißen immer `.env`** (nie `stack.env`); `.env.example` im Repo-Root, `.gitignore`: `.env`, `.env.*`, `!.env.example`. `setup.sh` schreibt `.env` (Modus 600, ohne Secret-Werte), `update.sh` liest sie und sichert sie als `.env.bak`.
- **Migrationen als getrennter One-Shot-Service** `migrate` (`radar migrate --yes`), nicht beim Start jedes Replikats (Änderung gegenüber der Python-Fassung). `swarm-deploy.sh` führt ihn vor jedem Rollout aus. Der Migrationsjob nutzt denselben DB-Benutzer wie der Dienst; dieser braucht daher SELECT/INSERT/UPDATE/DELETE und CREATE auf dem Schema. Der Advisory-Lock `GET_LOCK('showernow_migrate')` bleibt als Schutz gegen parallele Migrationen. SQL-Dateien (`migrations/`) unverändert und additiv.
- **Healthcheck** als Swarm-Config (`healthcheck.sh`, bash und `/dev/tcp` auf `/healthz`; das Runtime-Image enthält absichtlich kein curl und kein Python); nur Liveness.
- **Update-Ablauf:** `update.sh` sucht das neueste `sha-<commit>` hinter `edge` auf ghcr.io (Label `org.opencontainers.image.revision`, verifiziert per Digest), schreibt es in `.env`, migriert, rollt mit start-first aus (Rollback bei fehlgeschlagenem Healthcheck) und prüft die öffentliche URL.
- **Bibliotheken:** swift-png 4 (reines Swift, kein C) zur Validierung/Dekodierung der DWD-PNGs; libwebp (System-Bibliothek, `libwebp-dev` im Build, `libwebp7` im Runtime-Image) für verlustfreies WebP mit `lossless`, `quality=100`, `method=6`, `exact=1` (wie zuvor Pillow); mysql-nio/MySQLKit (Vapor) für MariaDB, kleiner Pool (`DB_POOL_SIZE`, Standard 4); AsyncHTTPClient für den DWD. Vapor 4 (aktuell stabil 4.x; 5.0 war nur Beta). Gründe: kein Pillow-Äquivalent in reinem Swift nötig; libwebp ist die Referenzimplementierung und unter Ubuntu als Paket verfügbar; die Alternative optimiertes PNG (ca. 20 KB statt ca. 6 KB) war nicht nötig.
- **Multi-Arch:** amd64 und arm64 werden auf nativen GitHub-Runnern (`ubuntu-24.04`, `ubuntu-24.04-arm`) gebaut und per Digest zu einem Manifest verbunden; QEMU-Emulation wäre für den Swift-Release-Build zu langsam.
