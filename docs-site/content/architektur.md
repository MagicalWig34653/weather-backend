# Architektur

Alle Angaben stammen aus dem Repository (README, `docs/decisions.md`, `deploy/swarm/stack.yaml`).

```
App ──HTTPS──> Reverse Proxy (extern, TLS) ──> Swarm-Knoten :38090 (Routing-Mesh)
                                                  │
                          ┌───────────────────────┼───────────────────────┐
                      Replikat 1              Replikat 2   …          (radar_radar)
                      HTTP-API + Ingest       HTTP-API + Ingest
                      LRU-Cache               LRU-Cache
                          └───────────────────────┼───────────────────────┘
                                                  ▼
                                 externe MariaDB 12.3 (InnoDB)
                                 radar_run · radar_slot · schema_migration
                                                  ▲
                          Einmal-Dienst radar_migrate (radar migrate --yes)

Ingest: alle 5 min ein Lauf ──> DWD-WMS (dwd:Niederschlagsradar)
```

## Bausteine

- **Swift 6 und Vapor 4.** `Sources/radar` ist der Einstieg, `Sources/RadarCore` enthält die Fachlogik ohne Vapor (Zustand, Ingest, Manifest, API-Logik, Bildpipeline). PNG-Dekodierung mit swift-png, WebP-Lossless über die System-Bibliothek libwebp, MariaDB über mysql-nio/MySQLKit.
- **Zwei Swarm-Services.** `radar` (Standard 2 Replikate) liefert die API und nimmt am Ingest teil. `migrate` ist ein Einmal-Dienst mit `replicas: 0`, den `deploy/swarm/swarm-deploy.sh` vor jedem Rollout startet. Migrationen laufen nicht beim Start der Replikate.
- **Zustand in MariaDB, nicht in Dateien.** `radar_run` hält Lauf, Status und Lease, `radar_slot` die WebP-Bytes (MEDIUMBLOB) samt SHA-256. Kein geteiltes Volume, keine Knotenbindung.
- **Claim und Lease.** Ein Lauf wird per atomarem INSERT auf `radar_run` von genau einem Replikat beansprucht. Die Lease verfällt bei Absturz, dann übernimmt ein anderes Replikat. Versuche pro Lauf sind begrenzt (2), fehlgeschlagene Läufe haben 240 s Cooldown. Lease-Zeiten kommen von der DB-Uhr.
- **Atomare Veröffentlichung.** Ein Lauf wird erst nach allen 25 Slots in einer Transaktion auf `published` gesetzt. `latest.json` und Slot-Abrufe sehen nur veröffentlichte Läufe.
- **LRU-Cache je Replikat.** Standard 64 MB (`CACHE_MAX_MB`), mit Single-Flight bei Cache-Misses: die DB wird je Replikat und Slot nur einmal gelesen. Der Reverse Proxy braucht keinen eigenen Cache. Kein Redis.
- **Keine Sessions.** Replikate sind zustandslos, das Routing-Mesh verteilt per Round-Robin. Rolling Update mit `start-first`, automatischer Rollback bei fehlgeschlagenem Healthcheck.
- **Healthcheck nur Liveness** (`/healthz`), damit DWD- oder DB-Ausfälle keine Neustartschleifen erzeugen. Die Datenalterung zeigt `generated_at` in `latest.json`.

## Schonung des DWD

Etwa jede dritte GetMap-Antwort des DWD ist ein HTTP-200 mit XML-Fehler `InvalidDimensionValue` (gemessen am 30. Oktober 2026, unabhängig von Lauf und Slot). Deshalb gilt:

- jede Antwort wird validiert, bis zu 6 Versuche je Slot mit Backoff (3 bis 20 s plus Jitter);
- nur 3 parallele Requests (`FETCH_WORKERS`), ein Abruf je Lauf für alle Replikate;
- Start 200 s nach der Nominalzeit plus Jitter, zusätzlicher Backoff bei Serienfehlern (maximal 10 min), alte Läufe werden nicht nachgeholt.

## Retention

Standard 16 veröffentlichte Läufe, mindestens 15 (12 historische Analysen der Zeitleiste, aktueller Lauf, Reserve). Kleinere Werte verweigert die Konfiguration. Läufe in Arbeit werden nach 1 h Inaktivität gelöscht.

## Bildformat

Verlustfreies WebP, 1024 × 1311 px, DWD-Palette unverändert. Gemessen an Livebildern: PNG roh 44,7 KB, verlustfreies WebP etwa 5,9 KB.
