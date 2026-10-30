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
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE ON showernow.* TO 'showernow'@'<Host-Muster>';
```

Die Migration `001_radar.sql` legt `radar_run`, `radar_slot` und (vom Migrationsprogramm) `schema_migration` an; dafür genügt `CREATE`. Ob künftige Migrationen weitere Rechte brauchen, ist nicht geprüft. Die Migrationen sind als additiv vorgesehen.

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

`setup.sh` schreibt diese Datei (Modus 600, nicht versioniert, Vorlage `.env.example`); `update.sh` und `deploy/swarm/swarm-deploy.sh` lesen sie.

| Variable | Standard | Bedeutung |
|---|---|---|
| `RADAR_STACK` | `radar` | Stack-Name; bestimmt die Service-Namen `<stack>_radar` und `<stack>_migrate`. |
| `RADAR_IMAGE_TAG` | `edge` | Image-Tag. `edge` folgt jedem Push auf `main`; für Produktion ein festes `sha-<commit>` oder eine Version. `update.sh` pflegt den Wert. |
| `RADAR_REPLICAS` | `2` | Anzahl Replikate; ab 2 sind unterbrechungsfreie Rolling Updates möglich. |
| `RADAR_PORT` | `38090` | Veröffentlichter Port der Swarm-Knoten (Ingress), auf den der Reverse Proxy zeigt. Im Container lauscht der Dienst auf 8080. |
| `RADAR_CPU_LIMIT` | `0` | CPU-Limit je Replikat, `0` = unbegrenzt. |
| `RADAR_MEMORY_LIMIT` | `0` | Speicher-Limit je Replikat, z. B. `512M`, `0` = unbegrenzt. |
| `PUBLIC_BASE_URL` | leer | Öffentliche Basis-URL (ohne Pfad und Schrägstrich am Ende); mit Wert prüft das Skript nach dem Rollout `GET <URL>/v1/radar/latest.json`. |
| `DB_HOST` | – (Pflicht) | Hostname oder IP der MariaDB, aus dem Swarm erreichbar. |
| `DB_PORT` | `3306` | Datenbank-Port. |
| `DB_NAME` | `showernow` | Datenbankname. |
| `DB_USER` | `showernow` | Datenbankbenutzer. |
| `DB_POOL_SIZE` | `4` | Verbindungen je Replikat, 1 bis 10. |
| `DB_PASSWORD_SECRET` | `showernow_db_password` | Name des Swarm-Secrets mit dem Passwort. |

Weitere Einstellungen ohne Abfrage im Assistenten; bei Bedarf von Hand in die `.env` eintragen (der Stack reicht sie durch):

| Variable | Standard | Bedeutung |
|---|---|---|
| `CACHE_MAX_MB` | `64` | LRU-Cache je Replikat. |
| `RETENTION_RUNS` | `16` | Aufbewahrte veröffentlichte Läufe, mindestens 15. |
| `FETCH_WORKERS` | `3` | Parallele DWD-Requests, 1 bis 6. |
| `USER_AGENT` | `ShowerNow-radar-ingest/1.0` | Kennung gegenüber dem DWD, z. B. mit Kontakt-URL des Betreibers; keine Daten von App-Nutzern. |
| `WMS_URL` | DWD-GeoServer | Nur für Tests: anderer WMS-Endpunkt. |

Die Variablen `DEV_*` in `.env.example` gehören zur lokalen Entwicklung und werden in Produktion nicht gebraucht.

### 4. Secret `showernow_db_password`

Das Datenbank-Passwort ist ausschließlich ein Swarm-Secret (im Container `DB_PASSWORD_FILE=/run/secrets/db_password`). `setup.sh` legt es an. Manuell, falls gewünscht (zum Beispiel mit `--no-deploy` vorbereiten):

```sh
printf '%s' "$DB_PASSWORT" | docker secret create showernow_db_password -
```

Ein Secret lässt sich nicht ändern. Zum Rotieren ein neues Secret mit anderem Namen anlegen, `DB_PASSWORD_SECRET` in der `.env` anpassen und neu ausrollen.

### 5. Migrationsjob und Deploy

Das übernimmt `deploy/swarm/swarm-deploy.sh` (vom Setup und von `update.sh` aufgerufen):

1. Es legt die Swarm-Config `<stack>_deployment-lock` als Sperre gegen parallele Deployments an.
2. Existiert der Service `<stack>_radar` noch nicht, wird der Stack mit 0 Replikaten angelegt.
3. Der Service `<stack>_migrate` läuft einmal mit dem neuen Image (`radar migrate --yes`, bis zu 240 s Wartezeit). Schlägt er fehl, gibt es keinen Rollout.
4. Danach startet der Rollout der Replikate (`start-first`, Überwachung 60 s, Rollback bei fehlgeschlagenem Healthcheck). Anschließend entfernt das Skript die Sperre.

### 6. Reverse Proxy

Im Reverse Proxy (zum Beispiel Zoraxy) die Domain auf `http://<Swarm-Knoten>:38090` zeigen lassen, mit TLS am Proxy. Keine Sticky Sessions, kein Proxy-Cache, Header unverändert durchreichen. Mehrere Knoten dürfen als Upstream eingetragen werden, da jeder Knoten das Routing-Mesh bedient.

### 7. Verifikation

```sh
curl -i http://127.0.0.1:38090/healthz               # 200, Body "ok"
curl -i https://radar.example.org/v1/radar/latest.json
```

`latest.json` liefert **404**, solange noch kein Lauf veröffentlicht ist, und **200** nach dem ersten erfolgreichen Lauf (wenige Minuten nach dem Start; Start 200 s nach der Nominalzeit plus Jitter). Das ist auch die Prüfung, die `setup.sh` und `update.sh` ausführen: 200 und 404 gelten als erreichbar, alles andere als Warnung. Danach `ETag` und `Cache-Control` prüfen (siehe [API-Referenz](api.html)).

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
