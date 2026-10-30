# Roadmap

## Umgesetzt (Stufe 1)

Radar-Cache in Swift: Ingest aller 25 Slots alle 5 Minuten, WebP-Ablage in MariaDB, API mit LRU-Cache, Swarm-Stack, `setup.sh`, `update.sh`, Migrationsjob, CI und Multi-Arch-Image.

## Offen

- Betrieb auf dem Produktiv-Swarm bestätigen, Reverse Proxy einrichten (siehe [Installation](installation.html)).
- Schriftliche Bestätigung des DWD zur Lizenzannahme (optional).
- Endgültige Lizenz (AGPLv3 angestrebt).

## Geplant: Benachrichtigungen (nicht umgesetzt)

Die Ingest-Pipeline und die Datenbank sind als Grundlage vorgesehen, ein Abo-Schema gibt es bewusst noch nicht. Vorgaben aus den Entscheidungen:

- Regenwarnungen, Punktprognosen und APNs-Abos erst nach der nutzbaren App.
- Keine Serverregistrierung ohne aktivierte Abos; keine Standortverläufe; Abos nur grob beziehungsweise als Rasterzellreferenz, keine Ortsnamen.
- APNs-Schlüssel nur als Swarm-Secret; Migrationen additiv.
- Keine Benutzerkonten, kein Dashboard.
