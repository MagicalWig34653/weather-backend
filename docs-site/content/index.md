# ShowerNow Radar-Cache

Der Radar-Cache ist das Backend der Regen-App ShowerNow. Er holt alle 5 Minuten den Niederschlagsradar des Deutschen Wetterdienstes (DWD) für ganz Deutschland, speichert ihn und liefert ihn der App als fertige Ganzbilder aus. Die App lädt dadurch die Radarkarte schnell und ohne Ortsbezug im Request. Dieselbe Pipeline ist die Grundlage für spätere Benachrichtigungen (Plan, noch nicht umgesetzt).

> **Quelle: Deutscher Wetterdienst.** Die Bilder sind aus DWD-Rasterdaten (WMS `dwd:Niederschlagsradar`) bildlich wiedergegeben und verlustfrei in WebP umgewandelt (Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben). Der Vermerk steht im Manifest und muss in der App an der Karte sichtbar bleiben.

## Status

- Stufe 1 (Radar-Cache) ist in Swift 6 mit Vapor 4 implementiert und getestet. Der Pushdienst (Benachrichtigungen) ist **nicht** umgesetzt.
- Das Docker-Image `ghcr.io/magicalwig34653/weather-backend-radar` wird von GitHub Actions für amd64 und arm64 veröffentlicht (Tags `edge`, `latest`, `sha-<commit>`).
- Geprüft wurde lokal auf einem eigenen Swarm mit Wegwerf-Datenbank. **Nicht geprüft** sind der Betrieb auf einem fremden Produktiv-Swarm, ein Reverse Proxy, Last und der Tag-Lookup von `update.sh` gegen die veröffentlichten Images in jeder Umgebung. Details: [Entwicklung](entwicklung.html).
- Lizenz: AGPLv3 ist angestrebt, die Freigabe steht aus; bis dahin ist keine Lizenz erteilt.

## Wo es weitergeht

- [Architektur](architektur.html): Replikate, MariaDB, Claim und Lease, Cache.
- [Installationsanleitung](installation.html): vom leeren Swarm zum laufenden Dienst.
- [Betrieb und Fehlersuche](betrieb.html): Kommandos, typische Fehlerbilder, Stellschrauben.
- [API-Referenz](api.html): Endpunkte, Felder, Header.
- [Entwicklung](entwicklung.html) und [Roadmap](roadmap.html).

## Datenschutz

- Requests enthalten **keinen Ortsbezug**: feste Pfade je Lauf und Slot, Ganzbild für Deutschland.
- Keine Cookies, keine Sticky Sessions. Der Radar-Dienst führt keine Zugriffsprotokolle und speichert keine IP-Adressen oder Abfragedetails; Logs enthalten nur Lauf-IDs und Fehlerklassen. Ein vorgeschalteter Reverse Proxy sieht technisch bedingt die IP-Adresse jedes Abrufs; ob und wie lange er protokolliert, bestimmt der Betreiber.
- Anfragen an den DWD enthalten nur Layer, Zeit und eine feste Deutschland-BBox.
- Das Datenbank-Passwort liegt ausschließlich als Swarm-Secret vor.

## Quellen und Lizenzannahme

Die Daten stehen unter CC BY 4.0 beziehungsweise der GeoNutzV. Angenommen wird, dass dies Zwischenspeichern und Weitergabe mit Quellenvermerk „Quelle: Deutscher Wetterdienst“ und Veränderungshinweis erlaubt. Eine schriftliche Bestätigung des DWD ist optional und offen; das ist kein Rechtsrat. Der DWD sichert keine Verfügbarkeit zu, deshalb behält die App den DWD-Direktweg als Fallback.
