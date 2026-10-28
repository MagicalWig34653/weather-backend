# Backend-Entwicklungsplan

Stand: 28. Oktober 2026.

## Freigabe und Abhängigkeit

Der Nutzer hat die Entwicklung nach Klärung der Einstiegsfragen freigegeben. Zuerst wird die native App umgesetzt. Backend-Implementierung bleibt bis zur nutzbaren App zurückgestellt. Verbindlicher detaillierter App-Plan: https://github.com/MagicalWig34653/weather-apple/blob/main/docs/plan.md

## Reihenfolge nach der App

1. Datenbefunde der App übernehmen; benötigte Rohdatenprodukte und konsistente Zellprojektion dokumentieren. Falls die lokale Punktprognose scheitert, nur nach ausdrücklicher Architekturentscheidung eine kleine API vorziehen.
2. Installationsidentität ohne Konto, widerrufbare Authentifizierung, Tokenwechsel, Rasterabonnements, Datenminimierung und konkrete Löschfristen konzipieren.
3. Vapor/MariaDB-Grundstruktur und abgesicherte API implementieren. Noch keine Mikroservices oder zusätzliche Queue-Infrastruktur.
4. Zentralen DWD-Abruf und wiederverwendbare Ereignisauswertung implementieren; echte Datenaltergrenzen und fehlende Werte behandeln.
5. Datenbank-Leases, persistente Outbox, Deduplizierung, Retry und APNs integrieren. Keine externen Netzwerkanfragen in langen Datenbanktransaktionen.
6. Neustarts und mehrere Replikate prüfen; kontrollierte Migrationen, Docker-Swarm-Betrieb, Secrets und datensparsame Beobachtbarkeit dokumentieren.
7. Löschung, ungültige Tokens, inaktive Installationen, Backups und Ereignisqualität prüfen. Erst danach dynamische Unterwegs-Warnorte.

## Abnahme

Ein fester Warnort erhält nachvollziehbare Regenbeginnwarnungen aus frischen Daten. Berechtigungen, Wiederanlauf, konkurrierende Worker, Deduplizierung und Löschung sind gezielt getestet. Die App-Karte bleibt bei Backend-Ausfall nutzbar. Keine Ortsnamen, exakten GPS-Positionen oder Bewegungshistorien werden zentral gespeichert. APNs-Zustellung wird nicht als garantiert bezeichnet.

## Prozess

Kostensparsam, Agents verpflichtend, Sessions wegwerfbar und Repo als Source of Truth. Entscheidungen, Quellen, Prüfergebnisse, offene Fragen und nächste Schritte fortlaufend dokumentieren. Jede neue Session beginnt mit AGENTS.md und docs/status.md.
