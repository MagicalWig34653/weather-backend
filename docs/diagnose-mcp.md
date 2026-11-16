# Entwurf: lokaler MCP-Server für den Diagnose-Export

Status: nur Entwurf (16. November 2026), nicht gebaut. Umsetzung braucht Linos Freigabe.

Ziel: Das Brain und Lino lesen den Zustand des Radar-Dienstes, ohne SQL- und Log-Befehle von Hand. Ein schmaler MCP-Server (stdio, lokal) ruft denselben Endpunkt `GET /dash/api/diagnose` ab wie der Dashboard-Knopf.

## Werkzeuge (nur lesend)

- `radar_diagnose`: liefert das Export-JSON (optional `sections`, z. B. `layers`, `cache`, `statsDaily`, um Kontext zu sparen).
- `radar_layer_status`: nur die Zeilen je Ebene (Alter, Läufe 6 h, Fehler 24 h, Sperre), abgeleitet aus demselben Aufruf.
- Kein Schreibwerkzeug: kein Neustart, kein Cache-Leeren, keine Konfiguration.

## Authentifizierung

Die Dashboard-Anmeldung ist ein Passkey mit Browser-Sitzung und lässt sich nicht headless nutzen. Nötig wäre ein zweiter, enger Weg: ein Lese-Token, nur für `GET /dash/api/diagnose` gültig (Header `Authorization: Bearer`), als SHA-256-Hash im Dienst (Env/Secret, nie in der Datenbank im Klartext), vergleichszeitkonstant, eigenes Ratenlimit. Das ist eine neue Auth-Fläche und eine Entscheidung für Lino. Das Token liegt lokal im macOS-Schlüsselbund oder in einer Datei mit Modus 600 außerhalb des Repos, der MCP-Server liest es per Umgebungsvariable. Erreichbar ist der Endpunkt nur über den internen Weg des Dashboards (Proxy-Token, Host-Prüfung bleiben).

## Token-Rotation

- Zwei Hashes gleichzeitig gültig (`DIAG_TOKEN_SHA256`, `DIAG_TOKEN_SHA256_NEXT`): neues Token erzeugen, `NEXT` setzen und ausrollen, MCP-Server umstellen, alten Hash entfernen.
- Rhythmus 90 Tage oder sofort bei Verdacht; Widerruf = Hash entfernen und Dashboard-Dienst neu starten.

## Risiken

- Zweite Auth-Fläche am Dashboard: ein geleaktes Token gibt Betriebsdaten (keine personenbezogenen Daten, keine Secrets), aber auch Betriebsinformationen wie Stand und Konfiguration. Deshalb nur lesend, nur dieser eine Pfad, Ratenlimit, Audit-Zähler ohne IP.
- Der Export muss weiter frei von Personenbezug bleiben; der Test `DiagnoseExportTests` ist die Schranke und muss bei jeder Feldergänzung laufen.
- Prompt-Injection: Export-Felder sind Zahlen und feste Labels, der MCP-Server gibt nur diesen JSON-Text zurück und folgt keinem Inhalt daraus.
- Ein lokaler Prozess mit Token-Zugriff kann den Dienst belasten: Abrufe cachen (z. B. 10 s) und begrenzen.
- Alternative ohne neue Auth: Export manuell per Knopf herunterladen und dem Brain als Datei geben (heutiger Stand).
