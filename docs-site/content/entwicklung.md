# Entwicklung

## Lokal bauen und testen

{{BUILD}}

Die MariaDB-Tests brauchen eine Wegwerf-Datenbank. `compose.yaml` startet eine lokale MariaDB 12.3 (Port 23306) und mit dem Profil `app` den ganzen Dienst (Port 28090); die Entwicklungswerte `DEV_*` stehen in `.env.example`.

## CI und Veröffentlichung

- **CI** (`.github/workflows/ci.yml`): `swift build` und `swift test` im Container `swift:6.2-noble` gegen eine MariaDB-12.3-Service-Instanz ohne DWD-Zugriff; zusätzlich `shellcheck` für `deploy/swarm/*.sh` und `scripts/*.sh` sowie `docker compose config` für Stack- und Dev-Compose-Datei.
- **Docker publish** (`.github/workflows/docker-publish.yml`): pro Architektur ein nativer Build (`ubuntu-24.04` für amd64, `ubuntu-24.04-arm` für arm64, keine QEMU-Emulation), danach ein Multi-Arch-Manifest je Tag.
- **Tags:** `edge` und `latest` für `main`, `sha-<commit>`, bei `v*`-Tags die Version und `major.minor`. Produktion sollte ein festes `sha-`- oder Versions-Tag nutzen.
- **Pages** (`.github/workflows/pages.yml`): baut diese Seite, siehe `docs/pages.md`.
- Alle Actions sind auf Commit-SHAs gepinnt.

## Geprüfter Stand

Lokal ausgeführt (30. Oktober 2026): 24 Tests grün, davon Contract-Tests je gegen den Fake und gegen eine Wegwerf-MariaDB 12.3 (Claim-Konkurrenz, Lease-Übernahme, Versuchslimit, Cooldown, atomare Veröffentlichung, Retention, ETag/304, Single-Flight, kein `Set-Cookie`, identische Manifeste) sowie pixelgenaue WebP-Tests. Auf einem eigenen lokalen Swarm mit Wegwerf-Datenbank liefen `setup.sh`, Migrationsjob, Rolling Update mit `update.sh --tag`, manueller und automatischer Rollback sowie ein echter DWD-Lauf (`latest.json` 404, dann 200 mit 25 Slots). Der Publish-Workflow ist grün (Commit `8d3d487`, Tags `edge`, `latest`, `sha-8d3d487`, amd64 und arm64).

**Nicht geprüft:** Betrieb auf dem Produktiv-Swarm des Betreibers, Reverse Proxy, Last, amd64-Lauf lokal, Tag-Lookup `edge` zu `sha-` gegen das öffentliche Paket in jeder Umgebung.

## Entscheidungen (Kurzfassung)

Maßgeblich ist `docs/decisions.md`.

- **Swift 6 und Vapor 4** statt der früheren Python-Fassung; Fachlogik ohne Vapor in `RadarCore`.
- **MariaDB statt Dateien:** replizierbarer Zustand, später Basis für Benachrichtigungen; kein Redis, kein nginx-Sidecar.
- **Verlustfreies WebP** (libwebp): das DWD-PNG hat etwa 260 Farbwerte, PNG8 wäre verlustbehaftet.
- **Bis zu 6 Versuche je Slot** wegen der `InvalidDimensionValue`-Antworten des DWD, 3 parallele Requests.
- **Replikat-Claim** mit Lease in `radar_run`: genau ein Replikat holt einen Lauf; Übernahme bei Absturz.
- **Migrationen als eigener Einmal-Dienst**, nicht beim Start der Replikate.
- **Öffentliches Repo:** keine Geheimnisse, echten Domains, IPs oder Hostnamen; Konfiguration über Secrets und Platzhalter.
