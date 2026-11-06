# Installationsanleitung

Diese Anleitung führt von einem Docker-Swarm-Manager bis zum laufenden Radar-Cache. Alle Optionen, Variablen und Namen stammen aus `deploy/swarm/setup.sh`, `deploy/swarm/update.sh`, `deploy/swarm/swarm-deploy.sh`, `.env.example` und `deploy/swarm/stack.yaml`; Domains und Zugangsdaten sind Platzhalter (`radar.example.org`, `db.example.internal`).

## Voraussetzungen

Nicht Teil dieses Repos und vorher bereitzustellen:

| Baustein | Anforderung |
|---|---|
| Docker Swarm | Ein Manager-Knoten, auf dem das Setup läuft. Fehlt der Swarm, bietet `setup.sh` `docker swarm init` an (siehe `--swarm-init`). Auf dem Manager werden `git`, `docker`, `curl` und `openssl` gebraucht. |
| MariaDB | Extern, Version 12.3, von allen Swarm-Knoten aus erreichbar. Eine Datenbank und ein Benutzer mit den unten genannten Rechten. |
| Image | `ghcr.io/magicalwig34653/weather-backend-radar`. Das GHCR-Paket muss **öffentlich** sein (einmalig nach dem ersten Lauf von `docker-publish.yml` umstellen), sonst scheitern Pull und Tag-Lookup. amd64 und arm64 sind veröffentlicht. |
| Reverse Proxy | Extern, zum Beispiel Zoraxy, mit TLS und Domain. Keine Sticky Sessions nötig, kein Cache nötig (der Cache liegt in den Replikaten). Upstream: ein oder mehrere Swarm-Knoten auf Port **38090** (Routing-Mesh, Standardwert von `RADAR_PORT`). |

### Datenbank und Rechte

Der Migrationsjob und die Replikate verwenden denselben Benutzer. Er braucht `SELECT`, `INSERT`, `UPDATE`, `DELETE` und `CREATE` auf der Datenbank. Beispiel (Platzhalter ersetzen):

```sql
CREATE DATABASE showernow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'showernow'@'<Host-Muster>' IDENTIFIED BY '<Passwort>';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER ON showernow.* TO 'showernow'@'<Host-Muster>';
```

Die Migration `005_push_time_sensitive.sql` ergänzt `push_sub` per `ALTER TABLE` um eine Spalte; deshalb braucht der Migrationsbenutzer ab dieser Version zusätzlich `ALTER` (bestehende Installationen: `GRANT ALTER ON showernow.* TO …;`). Die Migration ist additiv (Standardwert `0`) und läuft vor dem Rollout; alte Replikate arbeiten mit der neuen Spalte weiter. Die Migration `001_radar.sql` legt `radar_run`, `radar_slot` und (vom Migrationsprogramm) `schema_migration` an; dafür genügt `CREATE`. Ob künftige Migrationen weitere Rechte brauchen, ist nicht geprüft. Die Migrationen sind als additiv vorgesehen.

Auch die Migration `006_push_region.sql` (Spalten `kind`, `radius_cells`, `min_share` für Umkreis-Abos) ist ein additives `ALTER TABLE push_sub ... ADD COLUMN IF NOT EXISTS`; sie braucht dasselbe Recht `ALTER`, es sind keine weiteren Rechte nötig. Bestehende Abos behalten ihr Verhalten (Ort). Nach dem Update zeigt `curl <Basis-URL>/v1/status` bei `PUSH_ENABLED=true` das Feld `"capabilities":["regions"]`.

## Schritt für Schritt

### 1. Deploy-Branch klonen

Der Server braucht nicht das ganze Repository. Der Branch `deploy` enthält nur `deploy/swarm/*` (Stackfile, Setup, Update, Deploy-Skript, Healthcheck, Hilfsfunktionen), `.env.example` und eine kurze README. Er wird bei jeder Änderung auf `main` automatisch gespiegelt und nie von Hand geändert.

```sh
git clone --depth 1 --branch deploy https://github.com/MagicalWig34653/weather-backend.git radar
cd radar
```

Die `.env` liegt später im Ordner `radar/` (neben `deploy/`), nicht versioniert.

### 2. Setup-Assistent

Auf dem Swarm-Manager:

```sh
deploy/swarm/setup.sh
```

Der Assistent erledigt der Reihe nach: Voraussetzungen prüfen, Stack und Image-Tag wählen (Vorschlag: das neueste `sha-<commit>`-Tag hinter `edge`), Basis-URL, Port, Replikate, Limits und Datenbank abfragen, Secret anlegen, Verbindung zur Datenbank testen, Zusammenfassung bestätigen lassen, `.env` schreiben, Migrationsjob ausführen, Replikate starten und die Erreichbarkeit prüfen. Der Datenbanktest startet einen Wegwerf-Container `mariadb:12.3` und führt `select 1` aus.

Optionen (aus `setup.sh --help`):

| Option | Wirkung |
|---|---|
| `--env-file FILE` | Zu schreibende (und, falls vorhanden, als Vorgabe gelesene) Env-Datei. Standard: `.env` im Ordner des Klons. |
| `--answers-file FILE` | Antworten als `KEY=VALUE` (gleiche Namen wie in `.env`, zusätzlich `DB_PASSWORD` oder `DB_PASSWORD_FILE`, optional `CHECK_NETWORK`, `SWARM_ADVERTISE_ADDR`). Die Datei wird geparst, nie ausgeführt. |
| `--non-interactive` | Keine Rückfragen. Werte kommen aus Antwortdatei, `SETUP_<KEY>`-Umgebungsvariablen, vorhandener Env-Datei oder Standardwerten (in dieser Reihenfolge). |
| `--reconfigure` | Alle Werte erneut abfragen; bestehende Werte sind die Vorgabe. Ohne diese Option wird eine vorhandene `.env` unverändert wiederverwendet (idempotenter Neustart). |
| `--stack NAME` | Stack-Name, Standard `radar`. |
| `--tag TAG` | Image-Tag statt des neuesten `sha-`-Tags. |
| `--swarm-init` | Nur mit `--non-interactive`: führt `docker swarm init` aus, wenn kein Swarm aktiv ist. |
| `--skip-checks` | Datenbank-Verbindungstest überspringen. |
| `--no-deploy` | Nur `.env` schreiben und Secret anlegen. |
| `--dry-run` | Keine Docker-Aufrufe, keine Secrets; zeigt den Plan und schreibt die `.env` in ein temporäres Verzeichnis. |
| `--yes` | Abschlussbestätigung überspringen. |

Das Passwort wird nie in die `.env` geschrieben und nie ausgegeben. Existiert das Secret bereits, bleibt es unverändert. Ohne Terminal und ohne `--non-interactive` bricht das Skript ab.

#### Nicht interaktiv mit Antwortdatei

```sh
# answers.env (nicht committen, Modus 600) – Platzhalterwerte
RADAR_STACK=radar
RADAR_IMAGE_TAG=sha-abc1234
PUBLIC_BASE_URL=https://radar.example.org
RADAR_PORT=38090
RADAR_REPLICAS=2
DB_HOST=db.example.internal
DB_PORT=3306
DB_NAME=showernow
DB_USER=showernow
DB_PASSWORD_FILE=/pfad/zur/passwortdatei
```

```sh
deploy/swarm/setup.sh --dry-run --non-interactive --answers-file answers.env   # erst prüfen
deploy/swarm/setup.sh --non-interactive --answers-file answers.env --swarm-init
```

### 3. Variablen der `.env`

`setup.sh` schreibt diese Datei (Modus 600, nicht versioniert, Vorlage `.env.example`); `update.sh` und `setup.sh` laden sie vor dem Deploy in die Umgebung; `deploy/swarm/swarm-deploy.sh` liest `PUSH_ENABLED` und `APNS_KEY_SECRET` notfalls selbst aus der `.env` (Umgebungsvariablen der Shell haben Vorrang), alle übrigen Werte nur aus der Umgebung (`set -a; . ./.env; set +a`).

| Variable | Standard | Bedeutung |
|---|---|---|
| `RADAR_STACK` | `radar` | Stack-Name; bestimmt die Service-Namen `<stack>_radar` und `<stack>_migrate`. |
| `RADAR_IMAGE_TAG` | `edge` | Image-Tag. `edge` folgt jedem Push auf `main`; für Produktion ein festes `sha-<commit>` oder eine Version. `update.sh` pflegt den Wert. |
| `RADAR_REPLICAS` | `2` | Anzahl Replikate; ab 2 sind unterbrechungsfreie Rolling Updates möglich. |
| `RADAR_PORT` | `38090` | Veröffentlichter Port der Swarm-Knoten (Ingress), auf den der Reverse Proxy zeigt. Im Container lauscht der Dienst auf 8080. |
| `DASH_PUBLISH_PORT` | `39090` | Nur mit `DASH_ENABLED=true`: veröffentlichter Ingress-Port des Dashboards für den Reverse Proxy (Container-Port `DASH_PORT`, 9090). Per Firewall auf den Proxy beschränken. |
| `RADAR_CPU_LIMIT` | `0` | CPU-Limit je Replikat, `0` = unbegrenzt. |
| `RADAR_MEMORY_LIMIT` | `0` | Speicher-Limit je Replikat, z. B. `512M`, `0` = unbegrenzt. |
| `PUBLIC_BASE_URL` | leer | Öffentliche Basis-URL (ohne Pfad und Schrägstrich am Ende); mit Wert prüft das Skript nach dem Rollout `GET <URL>/v1/radar/latest.json`. |
| `DB_HOST` | – (Pflicht) | Hostname oder IP der MariaDB, aus dem Swarm erreichbar. |
| `DB_PORT` | `3306` | Datenbank-Port. |
| `DB_NAME` | `showernow` | Datenbankname. |
| `DB_USER` | `showernow` | Datenbankbenutzer. |
| `DB_POOL_SIZE` | `4` | Verbindungen je Replikat, 1 bis 10. |
| `DB_PASSWORD_SECRET` | `showernow_db_password` | Name des Swarm-Secrets mit dem Passwort. |

Weitere Einstellungen ohne Abfrage im Assistenten; bei Bedarf mit [`settings.sh`](#einstellungen-mit-settingssh) oder von Hand in die `.env` eintragen (der Stack reicht sie durch):

| Variable | Standard | Bedeutung |
|---|---|---|
| `CACHE_MAX_MB` | `64` | LRU-Cache je Replikat. |
| `RETENTION_RUNS` | `16` | Aufbewahrte veröffentlichte Läufe mit allen Vorhersage-Slots, mindestens 15. |
| `LAYERS` | `radar` | Zusatzebenen, kommagetrennt: `pressure` (Luftdruck, DWD ICON), `lightning` (Blitzdichte, DWD), `clouds` (Geo Colour, EUMETSAT), `cloudmask` (Wolkenmaske, EUMETSAT), `pressure_eu` (Luftdruck Europa, 2048 px), `cloudmask_vis` (sichtbarer Kanal Deutschland, tagsüber), `cloudmask_vis_eu` (sichtbarer Kanal Europa, 2048 px). Beispiel: `radar,pressure,pressure_eu,lightning,clouds,cloudmask,cloudmask_vis,cloudmask_vis_eu`. Ohne Eintrag startet nichts Neues; die Migration `004` muss vorher gelaufen sein (`update.sh`). Unbekannte Namen verhindern den Start. |
| `PRESSURE_FORECAST_HOURS` | `48` | Vorhersagestunden je Luftdruck-Lauf (1 bis 168); jeder Lauf kostet so viele Abrufe. `PRESSURE_RETENTION_RUNS` (Standard 2, 2 bis 8) bestimmt die behaltenen Läufe. `PRESSURE_EU_FORECAST_HOURS` (Standard 24, 1 bis 168) gilt nur für `pressure_eu`. |
| `LIGHTNING_HISTORY_HOURS`, `CLOUDS_HISTORY_HOURS`, `CLOUDMASK_HISTORY_HOURS`, `CLOUDMASK_VIS_HISTORY_HOURS`, `CLOUDMASK_VIS_EU_HISTORY_HOURS` | `3` | Aufbewahrte Vergangenheit je Beobachtungsebene (1 bis 24 Stunden). |
| `LAYER_PAUSE_SECONDS` | `2` | Pause zwischen zwei Abrufen einer Zusatzebene (0 bis 60); je Ebene arbeitet nur ein Replikat (Leader), nie parallel. |
| `HISTORY_HOURS` | `48` | Aufbewahrte und über `history.json` ausgelieferte Vergangenheit (Analysebilder), 1 bis 72 Stunden. Ungültige Werte verhindern den Start. Das DWD-WMS liefert Zeitwerte nur etwa 90 Stunden zurück. |
| `FETCH_WORKERS` | `3` | Parallele DWD-Requests, 1 bis 6. |
| `USER_AGENT` | `ShowerNow-radar-ingest/1.0` | Kennung gegenüber dem DWD, z. B. mit Kontakt-URL des Betreibers; keine Daten von App-Nutzern. |
| `OPERATOR_NAME`, `OPERATOR_ADDRESS`, `OPERATOR_EMAIL` | leer | Verantwortlicher für `/datenschutz` und `/support`; ohne Werte zeigt die Seite einen Hinweis. Siehe [Datenschutz und Marketing-Seiten](seiten.html). |
| `PROXY_LOG_NOTE` | leer | Ein Satz des Betreibers zur Protokollierung des Reverse Proxys (erscheint auf `/datenschutz`). |
| `APP_STORE_URL`, `TESTFLIGHT_URL` | leer | Optionale `https`-Links auf `/marketing`. |
| `WMS_URL` | DWD-GeoServer | Nur für Tests: anderer WMS-Endpunkt. |
| `EUMETSAT_WMS_URL` | EUMETSAT-GeoServer (`https://view.eumetsat.int/geoserver/wms`) | Nur für Tests: anderer WMS-Endpunkt der EUMETSAT-Ebenen. |
| `IMAGE_WIDTH` | `1024` | Bildbreite der Radar-Ebene in Pixeln (256 bis 2048). Mit `PUSH_ENABLED=true` muss sie `1024` bleiben. |
| `AVAILABILITY_DELAY_SECONDS`, `JITTER_SECONDS`, `REQUEST_TIMEOUT_SECONDS` | `200`, `20`, `30` | Wartezeit nach dem Rasterzeitpunkt bis zum Abruf (60 bis 900), zufälliger Zusatz (0 bis 120) und Timeout je Abruf (5 bis 120), jeweils in Sekunden. |
| `BUILD_REVISION` | – | Commit des Images (setzt der Docker-Workflow im Image); nur in `/v1/status` sichtbar. Der Stack reicht die Variable bewusst nicht durch, ein Wert in der `.env` wirkt nicht. |
| `PUSH_ENABLED` | `false` | Optionaler Pushdienst (Registrierungs-API, Auswertung, APNs-Versand). Mit `true` sind die vier `APNS_*`-Werte Pflicht und `IMAGE_WIDTH` muss `1024` sein; sonst Startfehler. |
| `PUSH_MAX_INSTALLATIONS`, `PUSH_MAX_SUBSCRIPTIONS`, `PUSH_MAX_REGION_CELLS` | `100000`, `400000`, `50000000` | Serverweite Obergrenzen für Installationen, Abos und Regionszellen (Missbrauchsschutz); darüber `503 server_full` bzw. `409 region_capacity`. Weiche Werte (Zähler werden bis zu 30 s zwischengespeichert). |
| `PUSH_MAX_ACTIVITY_SUBSCRIPTIONS` | `5000` | Obergrenze der Abos mit `live_activity: true` (begrenzt die Live-Activity-Arbeit je Radarlauf); darüber `503 activity_full`. Migration `008_push_activity_index.sql` legt dafür einen Index an (Recht `CREATE INDEX`/`ALTER`). |
| `PUSH_MAX_REGIONS_PER_INSTALLATION`, `PUSH_MAX_CELLS_PER_INSTALLATION` | `3`, `8000` | Regionen (1 bis 10) und Rasterzellen (500 bis 50000) je Installation. |
| `PUSH_RATE_PER_INSTALLATION`, `PUSH_RATE_GLOBAL_REGISTRATIONS`, `PUSH_RATE_GLOBAL_REQUESTS`, `PUSH_RATE_FAILED_AUTH`, `PUSH_TEST_LIMIT_PER_HOUR` | `60`, `600`, `3000`, `10`, `3` | Ratenlimits (Bereiche 10 bis 600, 60 bis 6000, 300 bis 30000, 3 bis 60 pro Minute; Testmeldungen 1 bis 10 pro Stunde); die globalen Werte gelten je Replikat. |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | leer | Key-ID (10 Zeichen), Team-ID und `apns-topic` (Bundle-ID). Keine Geheimnisse, aber Betreiberwerte. |
| `APNS_ENV` | `production` | `sandbox`, `production` oder `both`: erlaubte APNs-Umgebungen. Jede Installation meldet ihre Umgebung; der Sender nutzt den passenden Apple-Host. Meldungen einer nicht erlaubten Umgebung werden verworfen, die Testmeldung antwortet `409`. Beim Start steht die erlaubte Menge im Log. |
| `APNS_KEY_FILE` | – | Im Container der Pfad des `.p8`-Schlüssels (Swarm-Secret `showernow_apns_key`, Name über `APNS_KEY_SECRET`; vom Overlay `stack.push.yaml` eingehängt, siehe unten). |

Die Variablen `DEV_*` in `.env.example` gehören zur lokalen Entwicklung und werden in Produktion nicht gebraucht.

### 4. Secret `showernow_db_password`

Das Datenbank-Passwort ist ausschließlich ein Swarm-Secret (im Container `DB_PASSWORD_FILE=/run/secrets/db_password`). `setup.sh` legt es an. Manuell, falls gewünscht (zum Beispiel mit `--no-deploy` vorbereiten):

```sh
printf '%s' "$DB_PASSWORT" | docker secret create showernow_db_password -
```

Ein Secret lässt sich nicht ändern. Zum Rotieren ein neues Secret mit anderem Namen anlegen, `DB_PASSWORD_SECRET` in der `.env` anpassen und neu ausrollen.

#### APNs-Schlüssel und Umgebung (`APNS_ENV`)

Der Dienst nutzt einen einzigen `.p8`-Schlüssel für alle erlaubten Umgebungen. Belegt (Apple-Dokumentation laut App-Repo-Recherche `push-benachrichtigungen.md`): Token und Umgebung müssen zusammenpassen, sonst `400 BadDeviceToken`; Apple kennt team-scoped Schlüssel, die auf Sandbox oder Produktion beschränkt sein können (höchstens zwei je Umgebung), und topic-specific Schlüssel (eine Umgebung); ältere Schlüssel für beide Umgebungen bleiben gültig, Apple empfiehlt umgebungsspezifische. Daraus folgt:

- Nur `production` (TestFlight/App Store): ein Schlüssel, der für Produktion gilt. `APNS_ENV=production`.
- Nur `sandbox` (Xcode-Debug-Builds): ein Schlüssel, der für Sandbox gilt. `APNS_ENV=sandbox`.
- `APNS_ENV=both`: der eine Schlüssel muss für beide Umgebungen gelten, also ein Schlüssel „für beide Umgebungen“ (älteres Modell). Mit umgebungsspezifischen Schlüsseln wären zwei nötig; dafür kennt der Stack nur ein Secret, deshalb ist das derzeit nicht vorgesehen.
- Nicht belegt: ob Apple einen auf eine Umgebung beschränkten Schlüssel am anderen Host mit `InvalidProviderToken` oder mit `BadDeviceToken` ablehnt, und dass TestFlight-Builds Produktionstokens liefern (Letzteres folgt nur aus dem Profil, ist nicht ausdrücklich belegt).

Fehlbedienung zeigt sich zur Laufzeit, nicht beim Start (der Dienst prüft den Schlüssel nicht gegen Apple): Testmeldung `POST /v1/push/installations/<uuid>/test` liefert `apns_bad_device_token` oder `apns_key_rejected` mit Apples Reason; im regulären Versand zählt das Log die Apple-Reasons je Lauf (`apns reasons BadDeviceToken=…`), nie Token oder Schlüssel.

#### Optional: Push einschalten (Secret `showernow_apns_key`)

Der Pushdienst braucht den APNs-Auth-Key (`.p8`) aus dem Apple-Developer-Konto. Er wird wie das DB-Passwort als Swarm-Secret angelegt, nie als Umgebungswert und nie im Repo. Der Setup-Assistent fragt alles ab (Push an/aus, Key-ID, Team-ID, Topic, Umgebung, Pfad zur `.p8`) und legt das Secret mit `docker secret create <name> <datei>` an, ohne den Inhalt zu lesen oder auszugeben; er warnt, wenn die Datei für andere Benutzer lesbar ist. Von Hand:

```sh
docker secret create showernow_apns_key /pfad/zu/AuthKey_XXXXXXXXXX.p8
# in der .env: PUSH_ENABLED=true, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, APNS_ENV (optional APNS_KEY_SECRET)
deploy/swarm/update.sh --pull-scripts --force
```

> **Achtung: Hauptdatei allein reicht nicht.** `deploy/swarm/stack.yaml` enthält den APNs-Schlüssel nicht; das Secret hängt nur im Overlay `stack.push.yaml`. Wer mit `PUSH_ENABLED=true` nur `stack.yaml` deployt (zum Beispiel von Hand mit `docker stack deploy -c stack.yaml …`), erhält Container ohne `/run/secrets/apns_key`; sie starten nicht (Startfehler beim Lesen von `APNS_KEY_FILE`, Service bleibt bei 0 laufenden Replikaten). `update.sh`, `setup.sh` und `swarm-deploy.sh` binden das Overlay selbst ein. Von Hand immer beide Dateien angeben, im Ordner `deploy/swarm`, mit geladener `.env` (Migrationsjob und Sperre übernimmt dieser Weg nicht, vorher `swarm-deploy.sh` oder `update.sh` bevorzugen):
>
> ```sh
> cd deploy/swarm
> set -a; . ../../.env; set +a
> docker stack deploy --resolve-image never -c stack.yaml -c stack.push.yaml radar
> ```
>
> Prüfen, ob das Secret am Dienst hängt: `docker service inspect radar_radar --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}'` muss `apns_key` und `db_password` zeigen.

Verdrahtung: `deploy/swarm/stack.yaml` reicht `PUSH_ENABLED` (Standard `false`), `APNS_KEY_FILE=/run/secrets/apns_key`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` und `APNS_ENV` durch. Das externe Secret selbst hängt nur im Overlay `deploy/swarm/stack.push.yaml` (Name über `APNS_KEY_SECRET`, Standard `showernow_apns_key`), das `swarm-deploy.sh` nur bei `PUSH_ENABLED=true` zusätzlich einbindet. Grund: Ein im Stack referenziertes externes Secret muss existieren, sonst scheitert `docker stack deploy` mit „secret not found“; so bleiben Installationen ohne Push unberührt. `update.sh` und `swarm-deploy.sh` prüfen bei `PUSH_ENABLED=true` vor dem Rollout, dass das Secret existiert und die drei APNS-Werte gesetzt sind, und brechen sonst mit klarer Meldung ab, bevor etwas geändert wird. Rotation: neues Secret mit neuem Namen anlegen, `APNS_KEY_SECRET` anpassen, `update.sh --force`. Migration `003_push.sql` läuft über den normalen Migrationsjob und ist additiv (neue Tabellen `push_*`).

Geprüft: `docker stack config` (Docker 29) mit und ohne Overlay zeigt das Secret nur mit Overlay; beim Zusammenführen werden die `secrets:`-Listen vereinigt (`apns_key` und `db_password`, Name `showernow_apns_key`, Mountpunkt `/run/secrets/apns_key`, wie `APNS_KEY_FILE` im Stack); `deploy/swarm/test-swarm-deploy.sh` prüft mit einem Stub-`docker`, dass `swarm-deploy.sh` das Overlay genau bei `PUSH_ENABLED=true` (Shell oder `.env`) einbindet; das Verhalten bei einem fehlenden externen Secret im echten Swarm sowie der Rollout mit Secret sind nicht gegen einen Swarm geprüft.

### 5. Migrationsjob und Deploy

Das übernimmt `deploy/swarm/swarm-deploy.sh` (vom Setup und von `update.sh` aufgerufen):

1. Es legt die Swarm-Config `<stack>_deployment-lock` als Sperre gegen parallele Deployments an.
2. Existiert der Service `<stack>_radar` noch nicht, wird der Stack mit 0 Replikaten angelegt.
3. Der Service `<stack>_migrate` läuft einmal mit dem neuen Image (`radar migrate --yes`, bis zu 240 s Wartezeit). Schlägt er fehl, gibt es keinen Rollout.
4. Danach startet der Rollout der Replikate (`start-first`, Überwachung 60 s, Rollback bei fehlgeschlagenem Healthcheck). Anschließend entfernt das Skript die Sperre.

### 6. Reverse Proxy

Im Reverse Proxy (zum Beispiel Zoraxy) die Domain auf `http://<Swarm-Knoten>:38090` zeigen lassen, mit TLS am Proxy. Keine Sticky Sessions, kein Proxy-Cache, Header unverändert durchreichen. Mehrere Knoten dürfen als Upstream eingetragen werden, da jeder Knoten das Routing-Mesh bedient. Zugriffslogs des Proxys prüfen: Der Proxy sieht die IP-Adresse jedes Abrufs; ob und wie lange er sie protokolliert, bestimmt der Betreiber (bei Zoraxy die Einstellung der Zugriffslogs prüfen und gegebenenfalls abschalten oder kurz halten).

### 7. Verifikation

```sh
curl -i http://127.0.0.1:38090/healthz               # 200, Body "ok"
curl -i https://radar.example.org/v1/radar/latest.json
```

`latest.json` liefert **404**, solange noch kein Lauf veröffentlicht ist, und **200** nach dem ersten erfolgreichen Lauf (wenige Minuten nach dem Start; Start 200 s nach der Nominalzeit plus Jitter). Das ist auch die Prüfung, die `setup.sh` und `update.sh` ausführen: 200 und 404 gelten als erreichbar, alles andere als Warnung. Danach `ETag` und `Cache-Control` prüfen (siehe [API-Referenz](api.html)).

## Einstellungen mit settings.sh

`deploy/swarm/settings.sh` bearbeitet die `.env` per Menü (wie `raspi-config`) oder per Kommandozeile. Es liegt im Deploy-Branch neben `update.sh`; `update.sh --pull-scripts --force` holt es mit (`git pull --ff-only` im Klon, die `.env` ist nicht versioniert). Voraussetzung für das Menü: `whiptail` (Debian/Ubuntu: Paket `whiptail`; `dialog` geht als Rückfall) und Bash 4.4 oder neuer. Die Kommandozeilen-Modi brauchen kein whiptail.

```sh
cd radar                          # Klon des Branches deploy
deploy/swarm/settings.sh          # Menü; die .env liegt zwei Ebenen über dem Skript
deploy/swarm/settings.sh --env /pfad/.env --check
```

**Menü:** Hauptmenü mit Gruppen (Radar und Cache, Zusatzebenen, Push, Push-Limits, Betreiberseiten, Dashboard, Dashboard-Schwellen, Geräte-Kopplung, Datenbank und Dienst, Deploy und Image), Suchen, Hinweise, Speichern, Anwenden. Der Titel zeigt den Pfad („Einstellungen › Push › APNS_ENV“), die Kopfzeile die Zahl ungespeicherter Änderungen. Jede Zeile einer Gruppe zeigt `Wert  Zustand  Wirkung` (Zustand: `gesetzt`, `Default`, `NEU`, `RESET`; Wirkung: `live`, `Neustart`, `nur ENV`). Enter auf einer Zeile öffnet direkt die Bearbeitung: eine Auswahlliste für Ja/Nein, Aufzählungen und Zahlen mit höchstens sechs Werten, sonst ein Eingabefeld mit Beschreibung, Typ, Grenzen, Default und Wirkung. Leer lassen setzt auf den Default zurück (nach Rückfrage); eine ungültige Eingabe bleibt mit verständlicher Meldung im selben Feld. Nach einer Änderung bleibt die Auswahl auf dem bearbeiteten Eintrag. Esc geht überall eine Ebene zurück. „Suchen“ filtert nach Text in Name, Beschreibung, Gruppe oder Zustand (z. B. `gesetzt`, `neu`). „Speichern“ zeigt zuerst Änderungen, Wirkung (live, Neustart, nur ENV; Rolling Update) und Diff der Datei; nach Aktivierung des Dashboards erscheinen Aufruf-Adresse und Setup-Fenster. Der Docker-Secret-Status wird einmal beim Start gelesen (mit Hinweisbox) und beim Öffnen eines Secret-Eintrags aktualisiert. Empfohlen sind 80x24 Zeichen; die Spalten passen sich der Breite an.

**Wirkung:** `live` heißt, der Dienst übernimmt den im Dashboard gesetzten Wert binnen 30 s; eine Variable in der `.env` ist immer ENV, hat Vorrang und wirkt erst nach einem Rollout. `Neustart` und `nur ENV` werden beim Start gelesen. „Auf Default zurücksetzen“ kommentiert die Zeile aus (`#KEY=alt`): reversibel, der Alt-Wert bleibt lesbar, und der Stack nimmt den Default.

**Anwenden:** „Jetzt anwenden“ rollt nie ohne Bestätigung aus. Zur Wahl stehen `swarm-deploy.sh` (nur die Einstellungen, der Image-Tag bleibt) oder `update.sh --force` (zusätzlich neuestes Image; fragt nach der Datenbanksicherung).

| Modus | Wirkung |
|---|---|
| `--list` | alle Variablen mit Wert, Default und Quelle (Datei oder Default) |
| `--get KEY` | wirksamen Wert ausgeben |
| `--set KEY=VALUE` | prüfen und speichern, mehrfach möglich; ungültig → nichts wird geschrieben (Exit 3) |
| `--unset KEY` | Zeile auskommentieren (zurück auf den Default) |
| `--check` | ganze `.env` prüfen: Typ und Grenzen, unbekannte Variablen, Konflikte (z. B. `PUSH_ENABLED=true` ohne `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` oder mit `IMAGE_WIDTH` ungleich 1024), Shell-Ausdrücke in Werten, fehlende Docker-Secrets; Exit 1 bei Fehlern |
| `--env PFAD` | andere `.env` |

**Sicherheit:**

- Geheimnisse (`DB_PASSWORD`, `APNS_KEY`, alles Unbekannte mit `PASSWORD`, `SECRET`, `KEY`, `TOKEN` im Namen) werden nie angezeigt und nie in die `.env` geschrieben. Das Menü zeigt stattdessen den passenden `docker secret create`-Befehl und den Status (`vorhanden`, `fehlt`, `unbekannt`, wenn `docker secret ls` nicht läuft).
- Vor dem Schreiben entsteht eine Sicherung `.env.bak.JJJJMMTT-HHMMSS` (Rechte wie das Original). Eine vorhandene `.env.bak` wird nicht angefasst. Geschrieben wird atomar (temporäre Datei, dann `mv`), die Rechte der `.env` bleiben (z. B. 600). Kommentare und unbekannte Zeilen bleiben unverändert; eine Kommentarzeile `#KEY=...` wird an Ort und Stelle aktiviert.
- Die `.env` wird von den Skripten per `. ./.env` gesourct. Werte mit Leerzeichen oder Sonderzeichen (`$`, Backtick, `"`, `'`, `\`, `;`) schreibt das Skript deshalb in einfachen Anführungszeichen und liest sie beim Einlesen ohne Auswertung zurück; Zeilenumbrüche im Wert werden abgelehnt. Das Skript führt nie etwas aus der `.env` aus (nur „Jetzt anwenden“ sourct sie nach Bestätigung für `swarm-deploy.sh`).
- Die Tabellen `config-registry.tsv` (aus dem Swift-Register erzeugt; der Test `ConfigRegistryTSVTests` hält sie synchron, Neuerzeugung mit `UPDATE_CONFIG_TSV=1 swift test --filter ConfigRegistryTSVTests`) und `config-extra.tsv` (Deploy-Variablen, handgepflegt) liegen im Deploy-Branch. Ein CI-Schritt prüft, dass jede `${VAR}` aus `stack.yaml` in einer Tabelle steht.
- Hinweis: `update.sh` überschreibt bei jedem Lauf die Sicherung `.env.bak`; `settings.sh` legt dagegen eigene Zeitstempel-Sicherungen an.

### Dashboard aktivieren

Gruppe „Dashboard“ im Menü (oder `--set DASH_ENABLED=true --set DASH_ORIGIN=https://...`). Namen und Bedeutung wie im Dashboard-Plan: `DASH_ENABLED` (Standard `false`), `DASH_ORIGIN` (Pflicht bei `true`: https-Adresse ohne Pfad, unter der Sie das Dashboard aufrufen; WebAuthn braucht HTTPS), `DASH_RP_ID` (optional, Standard der Host der Origin; Vorschlag im Menü), `RESTART_STAGGER_SECONDS` (Standard 45, 15 bis 300). `REPLICA_SLOT` setzt der Swarm per `{{.Task.Slot}}`, nicht manuell eintragen.

- Das Dashboard läuft als eigener Dienst `dashboard` und veröffentlicht wie `radar` einen Ingress-Port (`DASH_PUBLISH_PORT`, Standard **39090**; Container-Port `DASH_PORT`, 9090). Ihr **externer** Reverse Proxy terminiert TLS, leitet an `<Swarm-Knoten>:39090` weiter und muss den `Host`-Header unverändert durchreichen. **Firewall:** den Port nur für die Proxy-Adresse(n) öffnen. Proxy-Beispiele (nginx, Caddy, Traefik) und Firewall-Zeilen: [Betreiber-Dashboard](dashboard.html#erreichbarkeit-absichern).
- **Reihenfolge:** Aktivieren, ausrollen, **sofort** den ersten Passkey registrieren. Die Registrierung ist nur beim ersten Start ohne vorhandenes Credential offen und gilt für den Ersten, der das Dashboard erreicht. Notfall-Reset: `radar dashboard-reset --yes`.
- Ausführliche Anleitung (Setup-Fenster, Passkey, Schwellen, Kopplung, Diagnose lesen): [Betreiber-Dashboard](dashboard.html). Zusätzliche Variablen: `DASH_PORT`, `DASH_PUBLISH_PORT`, `DASH_SETUP_WINDOW_MINUTES`, `DASH_SESSION_HOURS`, `DASH_IDLE_MINUTES`, `DASH_MIN_GROUP`, `DASH_WARN_*` und `DEVICE_LINK_*` (siehe `.env.example`).
- **Stand dieser Version:** `swarm-deploy.sh` und `update.sh` binden bei `DASH_ENABLED=true` (Shell vor `.env`, wie bei `PUSH_ENABLED`) das Overlay `deploy/swarm/stack.dashboard.yaml` ein (Dienst `dashboard`, Befehl `radar dashboard`, ein veröffentlichter Ingress-Port `DASH_PUBLISH_PORT`, schreibgeschütztes Dateisystem, kein Docker-Socket, kein APNs-Secret). `DASH_ORIGIN` ist Pflicht; `DASH_RP_ID` leitet das Skript sonst aus dem Host von `DASH_ORIGIN` ab. Fehlt die Datei (alter Skriptordner, `update.sh --pull-scripts` holt sie), brechen beide Skripte mit „Dashboard-Overlay fehlt“ ab, bevor etwas geändert wird.

## Update

```sh
deploy/swarm/update.sh
```

`update.sh` sucht auf ghcr.io das `sha-<commit>`-Tag, dessen Digest dem Tag `edge` entspricht (über das Image-Label `org.opencontainers.image.revision`, gegen den Digest verifiziert; Vergleich aller `sha-`-Tags nur als langsamer Rückfall), fragt nach der Datenbanksicherung, sichert die `.env` als `.env.bak`, schreibt `RADAR_IMAGE_TAG`, führt Migrationsjob und Rolling Update aus, wartet auf den Rollout (bis 600 s) und prüft `PUBLIC_BASE_URL`.

| Option | Wirkung |
|---|---|
| `--env-file FILE` | Env-Datei, Standard `./.env`, sonst `.env` im Ordner des Klons. |
| `--tag TAG` | Dieses Tag verwenden (z. B. `sha-6c074f7` oder `0.1.0`) statt der Suche. |
| `--stack NAME` | Stack-Name, Standard aus `RADAR_STACK`, sonst `radar`. |
| `--dry-run` | Zeigt, was passieren würde; keine Dateiänderung, keine Docker-Aufrufe. Die Tag-Suche auf ghcr.io läuft dennoch (nur lesend). |
| `--pull-scripts` | Zuerst die Deploy-Skripte aktualisieren (`git pull --ff-only` im Klon des Branches `deploy`), dann `update.sh` aus den neuen Dateien neu starten. Die `.env` ist nicht versioniert und bleibt unberührt. Ohne Git-Klon bricht die Option mit einer Meldung ab. |
| `--force` | Auch dann neu ausrollen, wenn sich das Tag nicht geändert hat. |
| `--yes` | Rückfrage („Database backed up?“) überspringen. |

Ist das ermittelte Tag bereits aktiv, beendet sich das Skript ohne Änderung. Die Skriptausgabe von `update.sh` ist englisch, die von `setup.sh` deutsch.

## Rollback

- **Automatisch:** Schlägt der Healthcheck der neuen Replikate fehl, rollt Swarm selbst zurück (`failure_action: rollback`); `update.sh` meldet den Fehler und stellt die `.env` aus `.env.bak` wieder her. Scheitert der Migrationsjob, gibt es keinen Rollout und das vorherige Tag bleibt aktiv.
- **Manuell:** `docker service rollback radar_radar` oder `deploy/swarm/update.sh --tag <vorheriges Tag>`. Beim manuellen Rollback mit `docker service rollback` anschließend `RADAR_IMAGE_TAG` in der `.env` selbst auf das laufende Tag setzen.
- Datenbankänderungen werden durch einen Image-Rollback nicht zurückgenommen; die Migrationen sind additiv.

## Umstieg vom alten Python-Stack

Die frühere Python-Fassung ist ersetzt. Vor dem ersten Setup den alten Stack entfernen, damit `setup.sh` nicht über abweichende Services hinwegdeployt:

```sh
docker stack rm radar
docker service ls    # warten, bis keine radar_*-Services mehr erscheinen
```

Danach normal `deploy/swarm/setup.sh` ausführen. Ein bereits vorhandenes Secret `showernow_db_password` bleibt unverändert und wird weiterverwendet. Eine alte `stack.env` wird nicht mehr gelesen; die Env-Datei heißt jetzt `.env`. Welche Daten der alte Stack in der Datenbank hinterlassen hat, ist hier nicht geprüft.

## Backup

Vor jedem Update und vor dem Umstieg die Datenbank sichern (zum Beispiel mit `mysqldump` oder dem üblichen Backup des Betreibers); `update.sh` fragt ausdrücklich danach. Die Radar-Bilder selbst sind ersetzbar (neue Läufe kommen alle 5 Minuten); der Verlust der Tabellen `radar_*` bedeutet daher nur eine kurze Lücke bis zum nächsten Lauf. Sichern Sie zusätzlich die `.env` (enthält keine Geheimnisse) und das Passwort an einem sicheren Ort, da sich ein Swarm-Secret nicht auslesen lässt.
