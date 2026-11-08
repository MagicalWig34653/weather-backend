# Betrieb und Fehlersuche

Service-Namen bei Standard-Stack `radar`: `radar_radar` (API und Ingest) und `radar_migrate` (Einmal-Dienst). Bei anderem `RADAR_STACK` entsprechend `<stack>_radar`.

## Kommandos

```sh
docker service ls                                          # Replikate, z. B. 2/2
docker service ps radar_radar --no-trunc                   # Tasks, Fehlermeldungen, Neustarts
docker service logs radar_radar --tail 50                  # Lauf-IDs und Fehlerklassen
docker service logs radar_migrate --tail 50                # Ausgabe des letzten Migrationsjobs
docker service inspect radar_radar --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'   # laufendes Image
docker service inspect radar_radar --format '{{.UpdateStatus.State}} {{.UpdateStatus.Message}}'
curl -i http://127.0.0.1:38090/healthz
curl -i http://127.0.0.1:38090/v1/radar/latest.json
```

Der Radar-Dienst führt keine Zugriffsprotokolle und speichert keine IP-Adressen oder Abfragedetails; seine Logs enthalten nur Lauf-IDs und Fehlerklassen. Ob der vorgeschaltete Reverse Proxy Zugriffe protokolliert, bestimmt der Betreiber (siehe Installation, Schritt 6).

## Typische Fehlerbilder

| Symptom | Ursache und Abhilfe |
|---|---|
| `No such image` oder `pull access denied` in `docker service ps --no-trunc` | Das GHCR-Paket `weather-backend-radar` ist noch privat oder das Tag existiert nicht. Paket auf öffentlich stellen; Tag prüfen (`--tag`). Der Stack wird mit `--resolve-image never` deployt, der Pull passiert auf dem Knoten. |
| `secret not found` | Das Secret fehlt oder `DB_PASSWORD_SECRET` in der `.env` nennt einen anderen Namen. `docker secret ls`; Secret anlegen: `printf '%s' "$DB_PASSWORT" \| docker secret create showernow_db_password -`. |
| Migrationsjob scheitert („Migration failed“) | Datenbank nicht erreichbar (Host, Port, Firewall, vom Swarm-Knoten aus), falsche Zugangsdaten oder fehlende Rechte. Der Benutzer braucht `SELECT`, `INSERT`, `UPDATE`, `DELETE` **und `CREATE`**. Ursache in `docker service logs radar_migrate` und `docker service ps radar_migrate --no-trunc`. Ein fehlgeschlagener Job verhindert den Rollout; die alten Replikate laufen weiter. |
| Replikate starten nicht, Healthcheck schlägt fehl | `docker service ps radar_radar --no-trunc` und Logs ansehen. Der Healthcheck (`/healthcheck.sh`, bash über `/dev/tcp` auf Port 8080, `/healthz`) prüft nur Liveness. Typisch: ungültige Konfiguration (z. B. `RETENTION_RUNS` unter 15, `FETCH_WORKERS` außerhalb 1 bis 6, `DB_POOL_SIZE` außerhalb 1 bis 10). `/healthz` antwortet 503 `stale`, wenn die Ingest-Schleife nicht mehr lebt. |
| `exec format error` oder Task startet nicht auf einem Knoten | Architektur passt nicht. Das Image ist als Multi-Arch-Manifest (amd64, arm64) veröffentlicht; ältere oder lokal gebaute Images enthalten womöglich nur eine Architektur. Tag prüfen. |
| `latest.json` bleibt 404 | Noch kein Lauf veröffentlicht (nach dem Start dauert es einige Minuten), oder der Ingest scheitert (DWD-Fehler, Datenbank). Logs auf Fehlerklassen prüfen. Ein Lauf wird erst nach allen 25 Slots veröffentlicht. |
| `latest.json` wird älter als 20 Minuten | `generated_at` prüfen. Die App fällt dann auf den DWD-Direktweg zurück. Ursache im Ingest-Log suchen (DWD nicht erreichbar, `InvalidDimensionValue`-Serien, Datenbank). |
| Update bricht mit „rollout did not succeed“ ab | Swarm rollt selbst zurück; `update.sh` stellt die `.env` wieder her. Ursache wie bei „Replikate starten nicht“. |
| `docker config create` schlägt fehl: Konfiguration existiert („deployment-lock“) | Siehe nächster Abschnitt. |

## Diagnose: `GET /v1/status` und „Ebenen 404“

`GET /v1/status` (intern/Betreiber, `Cache-Control: no-store`, keine Geheimnisse, keine Nutzerdaten) liefert JSON: `revision` (Commit des Images oder `null`), `push` (nur Boolean), `now` und je Ebene (`radar`, `pressure`, `pressure_eu`, `lightning`, `clouds`, `cloudmask`, `cloudmask_vis`, `cloudmask_vis_eu`) `enabled`, `has_data` und bei Daten `latest_run` und `published_at`. `/healthz` bleibt unverändert (`ok`/`stale`). Ein `404` auf `/v1/layers/<ebene>/latest.json` bedeutet entweder „Ebene nicht aktiviert“ (`enabled: false`) oder „noch keine Daten“ (`enabled: true`, `has_data: false`); ein Image ohne `/v1/status` antwortet dort `404` und ist zu alt.

```sh
curl -s http://127.0.0.1:38090/v1/status
```

Die Umgebungsvariable `LAYERS` (kommagetrennt aus `pressure`, `pressure_eu`, `lightning`, `clouds`, `cloudmask`, `cloudmask_vis`, `cloudmask_vis_eu`; `radar` läuft immer) schaltet die Zusatzebenen ein; ohne sie ist nur das Radar aktiv und jede Ebenen-Route antwortet `404`. Zugehörige Stellschrauben: `PRESSURE_FORECAST_HOURS`, `PRESSURE_RETENTION_RUNS`, `PRESSURE_EU_FORECAST_HOURS`, `CLOUDMASK_VIS_HISTORY_HOURS`, `CLOUDMASK_VIS_EU_HISTORY_HOURS`, `LIGHTNING_HISTORY_HOURS`, `CLOUDS_HISTORY_HOURS`, `CLOUDMASK_HISTORY_HOURS`, `LAYER_PAUSE_SECONDS` (siehe `.env.example`). Temperatur/Feuchte: `LAYERS` darf zusätzlich `temperature` enthalten (siehe Abschnitt "Temperatur- und Feuchtekarte aktivieren").

Symptom „Ebenen 404“, mögliche Ursachen in dieser Reihenfolge prüfen:

1. **`LAYERS` fehlt in der `.env`** auf dem Server oder die `.env` wurde nicht übernommen: `grep ^LAYERS .env`. `update.sh` und `swarm-deploy.sh` lesen nur diese Datei; `.env.example` wirkt nicht. Ältere `setup.sh --reconfigure`-Läufe schrieben die `.env` ohne `LAYERS` neu; neuere Skripte übernehmen die Zeile (`update.sh --pull-scripts` holt sie).
2. **Gleicher Image-Tag:** `update.sh` tut bei unverändertem Tag nichts. Geänderte `.env` oder `stack.yaml` brauchen `update.sh --force` (neue Skripte: `--pull-scripts --force`).
3. **Image zu alt:** das laufende Image kennt `LAYERS` noch nicht (Ebenen seit Commit 37e5f2e) oder `/v1/status` fehlt. `docker service ps radar_radar` zeigt das Tag; `update.sh` auf das neueste `sha-`-Tag.
4. **Migration oder Datenbankrechte:** Migration `004` (Ebenen), `005` und `006` (`ALTER` auf `push_sub`) laufen im Migrationsjob; fehlen `CREATE`/`ALTER`, scheitert er und der Rollout bleibt aus (`docker service logs radar_migrate`).
5. **Aktiviert, aber noch keine Daten:** `enabled: true`, `has_data: false`. Die erste Veröffentlichung folgt nach einigen Minuten; sonst Ingest-Log auf Fehlerklassen prüfen (Quelle DWD/EUMETSAT nicht erreichbar, schwarze Kacheln werden nie veröffentlicht).

## Historie nachholen (Backfill)

Nach dem ersten Start mit `HISTORY_HOURS=48` fehlen die 576 Analysebilder der letzten 48 Stunden. Ein Replikat holt sie nach. Rechnung: 576 Slots, etwa ein Drittel der Antworten ist der XML-Fehler, also rund 850 Requests einmalig. Bei höchstens 20 Requests pro Minute dauert das etwa 45 bis 60 Minuten (jeder Durchlauf pausiert zusätzlich 10 s). Danach fällt nur noch pro 5-Minuten-Lauf ein Slot an, der ohnehin vom regulären Lauf stammt. Fortschritt: Logzeile `history backfill: stored N, failed N, missing N`; `history.json` zeigt die gefüllten Slots (Lücken sind erlaubt).

| Fehlerbild | Ursache und Abhilfe |
|---|---|
| `missing` sinkt nicht | Meist DWD-Fehler: nach 6 Fehlern in Folge pausiert das Nachholen 5 Minuten. Slots, die 4-mal scheitern, werden nicht weiter versucht. |
| Kein Log vom Backfill | Ein anderes Replikat ist Leader (Lease 3 Minuten); bei dessen Ausfall übernimmt ein anderes. |
| Zeitwerte älter als etwa 90 Stunden | Der DWD liefert sie nicht mehr; deshalb ist `HISTORY_HOURS` auf 72 begrenzt. |

## Deployment-Sperre hängt

`deploy/swarm/swarm-deploy.sh` legt vor jedem Deployment die Swarm-Config `<stack>_deployment-lock` an (bei Standard-Stack `radar_deployment-lock`) und entfernt sie am Ende wieder. Sie bleibt absichtlich stehen, wenn der Migrationszustand unklar ist, zum Beispiel nach „Migration timeout“ (der Job brauchte länger als etwa 240 s) oder wenn das Skript hart beendet wurde. Meldung: „Migration state uncertain; deployment lock retained“. Neue Deployments starten dann nicht.

1. Prüfen, ob noch ein Migrationstask läuft: `docker service ps radar_migrate --no-trunc` und `docker service logs radar_migrate --tail 50`.
2. Erst wenn der Task beendet ist (`Complete` oder `Failed`) und der Datenbankzustand geklärt ist, die Sperre entfernen:

```sh
docker config ls --filter name=radar_deployment-lock
docker config rm radar_deployment-lock
```

3. Update erneut starten (`deploy/swarm/update.sh`, bei Bedarf mit `--pull-scripts` für aktuelle Skripte; bei nicht geändertem Tag mit `--force`).

Die Migrationen sind additiv und über den Advisory-Lock `showernow_migrate` gegen parallele Läufe geschützt.

## Temperatur- und Feuchtekarte aktivieren

Alles ist standardmäßig aus: ohne `temperature` in `LAYERS` und mit `TEMP_SOURCE=off` antworten `/v1/layers/temperature|dewpoint|humidity/…` mit `404`, es gibt keinen DWD-Abruf (Vertrag und Manifest: API-Referenz "Temperatur- und Feuchtekarten"). Reihenfolge (Entscheidung 8.11.2026):

1. Image ausrollen, Einstellungen unverändert (keine Wirkung, keine Migration: `layer` ist `VARCHAR(16)`, interne IDs höchstens 15 Zeichen).
2. `LAYERS=...,temperature` setzen (Neustart nötig) und `TEMP_SOURCE=wms` (live, auch im Dashboard): nur Temperatur, 49 `GetMap` je Lauf, 6-stündlich, **etwa 200 Abrufe am Tag** beim DWD (sequentiell, Pause `LAYER_PAUSE_SECONDS`), kleiner Speicher (49 Bilder zu 20 bis 30 KB je Lauf, 2 Läufe).
3. Später `TEMP_SOURCE=icon_d2` (Paket P4, noch nicht umgesetzt; bis dahin liefert `icon_d2` nur den Warmstand A): Standard `TEMP_D2_PARAMS=td_2m` (Taupunkt zuerst, relative Feuchte mit `relhum_2m` zuschaltbar, nicht Standard), Takt der ICON-D2-Läufe `TEMP_D2_RUN_INTERVAL_HOURS=6` (Standard) oder `3`. Last beobachten (`ingest_lag`, `ingest_dur`); bei zu großer Last zurück auf `wms` oder `off`, **ohne App-Update**.

Einstellungen: `TEMP_SOURCE` (`off`/`wms`/`icon_d2`, live), `TEMP_D2_PARAMS` (live), `TEMP_FALLBACK_WARM` (Standard `true`: bei `icon_d2` läuft die WMS-Temperatur als Warmstand weiter und springt ein), `TEMP_D2_MAX_AGE_HOURS` (Standard 7, live), `TEMP_D2_RUN_INTERVAL_HOURS` (Standard 6, live), `TEMP_WMS_LAYER` (Standard `dwd:Icon-eu_reg00625_fd_gl_T` mit Stil `tkb`, Rückfall `dwd:Icon_reg025_fd_sl_T2M`, Neustart; nicht mitten im Lauf wechseln, ein Lauf mischt sonst zwei Layer). `TEMP_SOURCE` wird je Ingest-Takt gelesen: `off` beendet Abrufe sofort, bereits gespeicherte Daten werden nicht mehr ausgeliefert. Fehlersuche: `GET /v1/status` führt `temperature`/`dewpoint`/`humidity` mit `enabled` (Schalter) und `has_data` (frischer Lauf der aktiven Quelle); `enabled: false` heißt `LAYERS` ohne `temperature`, `TEMP_SOURCE=off` oder (Taupunkt/Feuchte) Quelle ohne diese Größe.

## Amtliche Warnungen aktivieren

Beide Schalter sind standardmäßig aus (nur Umgebung, im Dashboard schreibgeschützt). Reihenfolge: (1) Image mit den Migrationen 016 und 017 ausrollen (Migrationsjob, Replikate migrieren nicht selbst); (2) optional die Kreisliste einmalig laden: `tools/seed_warncells.sh | mariadb <db>` (liest `tools/data/warncells-district.txt`, Stand 07.11.2026; optional anderer Pfad als Argument; 402 Kreis-Warnzellen; ohne Seed akzeptiert der Server jede wohlgeformte ID); (3) `WARN_INGEST_ENABLED=true`: der Leader `warn` lädt alle 60 s den DWD-Feed `DISTRICT_DWD_DIFF` bzw. alle 15 min `_STAT` (ETag, nur DE/EN), `/v1/warnings/active` antwortet, Fähigkeit `warnings`; (4) zuletzt `WARN_PUSH_ENABLED=true` (braucht `PUSH_ENABLED=true`): Warn-Abos und Warn-Pushes, Fähigkeit `warnings_push`. Push erst nach Antwort des DWD auf die Rückfrage und Freigabe des Datenschutztexts. Zurück: Schalter entfernen, die Daten bleiben bis zur Bereinigung (24 h Nachlauf) liegen.

## Stellschrauben

- **Replikate:** `RADAR_REPLICAS` (Standard 2). Zwei genügen für unterbrechungsfreie Rolling Updates; die Last ist klein. Änderung in der `.env`, dann `deploy/swarm/update.sh --force` oder `docker service scale radar_radar=<n>` (Letzteres überschreibt die `.env` nicht).
- **Ressourcenlimits:** `RADAR_CPU_LIMIT` (z. B. `1.5`) und `RADAR_MEMORY_LIMIT` (z. B. `512M`), `0` = unbegrenzt. Passende Werte sind nicht gemessen; erst beobachten, dann begrenzen.
- **Retention:** `RETENTION_RUNS` (Standard 16, Minimum 15). Bei 16 Läufen liegt der Datenbestand nach den Messungen unter etwa 25 MB.
- **Historie:** `HISTORY_HOURS` (Standard 48, 1 bis 72). Der Datenbestand wächst um etwa 4 bis 17 MB (576 Analysebilder, siehe Architektur).
- **Cache:** `CACHE_MAX_MB` (Standard 64) je Replikat. Die aktuellen Slots belegen etwa 0,2 bis 2 MB; der LRU ist reichlich bemessen. Der Reverse Proxy braucht keinen Cache.
- **Ingest:** `FETCH_WORKERS` (Standard 3) bewusst klein halten, um den DWD zu schonen.

Änderungen an der `.env` werden erst mit einem neuen Rollout wirksam (`update.sh --force`), da `swarm-deploy.sh` den Stack erneut deployt.
