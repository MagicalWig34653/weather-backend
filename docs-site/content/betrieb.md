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

Es gibt keine Zugriffslogs; die Logs enthalten nur Lauf-IDs und Fehlerklassen.

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

## Deployment-Sperre hängt

`scripts/swarm-deploy.sh` legt vor jedem Deployment die Swarm-Config `<stack>_deployment-lock` an (bei Standard-Stack `radar_deployment-lock`) und entfernt sie am Ende wieder. Sie bleibt absichtlich stehen, wenn der Migrationszustand unklar ist, zum Beispiel nach „Migration timeout“ (der Job brauchte länger als etwa 240 s) oder wenn das Skript hart beendet wurde. Meldung: „Migration state uncertain; deployment lock retained“. Neue Deployments starten dann nicht.

1. Prüfen, ob noch ein Migrationstask läuft: `docker service ps radar_migrate --no-trunc` und `docker service logs radar_migrate --tail 50`.
2. Erst wenn der Task beendet ist (`Complete` oder `Failed`) und der Datenbankzustand geklärt ist, die Sperre entfernen:

```sh
docker config ls --filter name=radar_deployment-lock
docker config rm radar_deployment-lock
```

3. Update erneut starten (`deploy/swarm/update.sh`; bei nicht geändertem Tag mit `--force`).

Die Migrationen sind additiv und über den Advisory-Lock `showernow_migrate` gegen parallele Läufe geschützt.

## Stellschrauben

- **Replikate:** `RADAR_REPLICAS` (Standard 2). Zwei genügen für unterbrechungsfreie Rolling Updates; die Last ist klein. Änderung in der `.env`, dann `deploy/swarm/update.sh --force` oder `docker service scale radar_radar=<n>` (Letzteres überschreibt die `.env` nicht).
- **Ressourcenlimits:** `RADAR_CPU_LIMIT` (z. B. `1.5`) und `RADAR_MEMORY_LIMIT` (z. B. `512M`), `0` = unbegrenzt. Passende Werte sind nicht gemessen; erst beobachten, dann begrenzen.
- **Retention:** `RETENTION_RUNS` (Standard 16, Minimum 15). Bei 16 Läufen liegt der Datenbestand nach den Messungen unter etwa 25 MB.
- **Cache:** `CACHE_MAX_MB` (Standard 64) je Replikat. Die aktuellen Slots belegen etwa 0,2 bis 2 MB; der LRU ist reichlich bemessen. Der Reverse Proxy braucht keinen Cache.
- **Ingest:** `FETCH_WORKERS` (Standard 3) bewusst klein halten, um den DWD zu schonen.

Änderungen an der `.env` werden erst mit einem neuen Rollout wirksam (`update.sh --force`), da `swarm-deploy.sh` den Stack erneut deployt.
