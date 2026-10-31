# API-Referenz

Die Radar-Endpunkte sind `GET`, ohne Authentifizierung, ohne Cookies und ohne Ortsangabe. Die optionale Push-Registrierung (`/v1/push/…`, nur mit `PUSH_ENABLED=true`, sonst `404`) ist weiter unten beschrieben. Der Vertrag ist gegenüber der früheren Python-Fassung unverändert. Beispielwerte unten sind Platzhalter.

## `GET /v1/radar/latest.json`

Manifest des neuesten veröffentlichten Laufs.

- `Cache-Control: public, max-age=30, stale-while-revalidate=30`
- `ETag` (Hash des Inhalts), `If-None-Match` ergibt `304`. Die Antwort ist bei allen Replikaten byteidentisch.
- `404` (`Cache-Control: no-store`), solange noch kein Lauf veröffentlicht ist.

Felder (Schema 1):

| Feld | Bedeutung |
|---|---|
| `schema` | Schemaversion, `1` |
| `run` | Lauf-ID, z. B. `20261030T1105Z` |
| `reference_time` | Nominalzeit des Laufs (UTC, ISO 8601) |
| `generated_at` | Veröffentlichungszeit (UTC); Maß für die Datenalterung |
| `step_minutes` | Zeitschritt, `5` |
| `forecast_horizon_minutes` | Vorhersagehorizont, `120` |
| `image` | `format`, `width` (1024), `height` (1311), `projection` (`EPSG:3857`), `bbox` (Meter), `bbox_wgs84` |
| `slots[]` | je Eintrag `time`, `kind` (`analysis` oder `forecast`) und `path` (relativ zu `/v1/radar/`). Enthält bis zu 12 frühere Analysen aus älteren Läufen plus die 25 Slots des aktuellen Laufs. |
| `attribution` | Quellenvermerk „Quelle: Deutscher Wetterdienst“ |
| `modification_notice` | Veränderungshinweis; muss in der App an der Karte sichtbar bleiben |

Gekürztes Beispiel mit Platzhaltern:

```json
{
  "schema": 1,
  "run": "20261030T1105Z",
  "reference_time": "<ISO-8601-UTC>",
  "generated_at": "<ISO-8601-UTC>",
  "step_minutes": 5,
  "forecast_horizon_minutes": 120,
  "image": { "format": "image/webp", "width": 1024, "height": 1311, "projection": "EPSG:3857", "bbox": ["…"], "bbox_wgs84": ["…"] },
  "slots": [ { "time": "<ISO-8601-UTC>", "kind": "analysis", "path": "20261030T1105Z/20261030T1105Z.webp" } ],
  "attribution": "…",
  "modification_notice": "…"
}
```

Das Beispiel skizziert nur die Struktur; Texte und Koordinaten stehen im Live-Manifest.

## `GET /v1/radar/<run>/<slot>.webp`

Ein Radar-Ganzbild (verlustfreies WebP, 1024 × 1311).

- `Content-Type: image/webp`, `Cache-Control: public, max-age=31536000, immutable`
- `ETag` ist der SHA-256 des Bildes; `If-None-Match` ergibt `304`.
- `404` für unbekannte oder nicht veröffentlichte Läufe und Slots sowie für ungültige IDs.
- Die URLs sind unveränderlich und deshalb dauerhaft cachebar.

## `GET /v1/radar/history.json`

Analysebilder der Vergangenheit (Schema 1, additiv; `latest.json` bleibt unverändert). Die App kann damit eine längere Zeitleiste aufbauen.

- `Cache-Control: public, max-age=60, stale-while-revalidate=60`, `ETag`, `304` bei `If-None-Match`, bei allen Replikaten byteidentisch, keine Cookies.
- `404` (`no-store`), solange noch kein Lauf veröffentlicht ist.
- Die Slots stehen aufsteigend nach `time`, enthalten nur Analysen (`kind: analysis`) im Fenster von `history_hours` bis zur neuesten Analyse und nur veröffentlichte Bilder. Lücken sind erlaubt (z. B. DWD-Ausfälle oder ein noch laufendes Nachholen).
- Die Bilder sind unter `path` (relativ zu `/v1/radar/`) abrufbar, `immutable` wie alle Slots.

```json
{"schema":1,"run":"20261030T1105Z","generated_at":"2026-10-30T11:08:40Z","step_minutes":5,"history_hours":48,
 "image":{"format":"image/webp","width":1024,"height":1311,"projection":"EPSG:3857","bbox":[0,0,0,0],"bbox_wgs84":[0,0,0,0]},
 "slots":[{"time":"2026-10-28T11:10:00Z","kind":"analysis","path":"20261028T1110Z/20261028T1110Z.webp"}],
 "attribution":"Quelle: Deutscher Wetterdienst","modification_notice":"Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben"}
```

Größe: bis zu 576 Einträge, etwa 60 KB.

## `GET /healthz`

Liveness für den Healthcheck (nur intern gedacht): `200` mit Body `ok`, `503` mit `stale`, wenn die Ingest-Schleife nicht mehr lebt. Prüft nicht die Datenaktualität.

## Push-Registrierung `/v1/push/…` (optional, Standard aus)

Nur aktiv mit `PUSH_ENABLED=true`. Opt-in je Ort; es werden keine Koordinaten und keine Ortsnamen übertragen, sondern eine Rasterzelle des Radarbilds (siehe unten). Keine Cookies, keine Zugriffsprotokolle. Alle Antworten: `Cache-Control: no-store`, Fehler als `{"error":"<code>"}`. Rechtlich/technisch ist die Zelle (ca. 1 km) weiterhin personenbezogen.

Authentifizierung: Header `X-Installation-Secret` (zufällig, 32 bis 128 Zeichen aus `A-Za-z0-9_-`, in der Keychain der App). Der Server speichert nur den SHA-256-Hash. Die erste Registrierung einer Installations-ID legt das Geheimnis fest; falsche, fehlende oder unbekannte Kombinationen ergeben einheitlich `401`.

| Methode und Pfad | Body | Antwort |
|---|---|---|
| `PUT /v1/push/installations/<uuid>` | `{"token":"<hex>","env":"sandbox\|production","locale":"de\|en"}` | `201` neu, `204` aktualisiert (Token, Umgebung, Sprache, `last_seen`) |
| `DELETE /v1/push/installations/<uuid>` | – | `204`; löscht Installation, Abos und Outbox |
| `GET /v1/push/installations/<uuid>/subscriptions` | – | `200`, Liste (`id`, `grid_version`, `cell_x`, `cell_y`, `threshold`, `lead_minutes`, `enabled`) |
| `POST /v1/push/installations/<uuid>/subscriptions` | Abo-Felder | `201` `{"id":"<uuid>"}`; `409 subscription_limit` ab 10 Abos |
| `PUT /v1/push/installations/<uuid>/subscriptions/<sub>` | Abo-Felder | `204`, setzt den Automaten zurück; `404` falls fremd/unbekannt |
| `DELETE /v1/push/installations/<uuid>/subscriptions/<sub>` | – | `204` / `404` |

Abo-Felder: `grid_version` (`1`), `cell_x` (0 bis 1023), `cell_y` (0 bis 1310), `threshold` (Intensitätsklasse 1 bis 15 der DWD-Legende, mm/h, siehe `PushIntensity`), `lead_minutes` (`10`, `20` oder `30`), optional `enabled` (Standard `true`). Das Raster ist das Pixelraster des Ingest-Bildes (1024 × 1311, EPSG:3857, feste Bbox aus `latest.json`): `x = floor((X - bbox0) / (bbox2 - bbox0) * 1024)`, `y = floor((bbox3 - Y) / (bbox3 - bbox1) * 1311)` mit Web-Mercator-Meterwerten `X`, `Y`. Die App rechnet lokal; der Server sieht nie eine Koordinate.

Grenzen: Body höchstens 2 KB (`413`), Token 32 bis 200 Hexzeichen, 60 Anfragen je Installation und Minute (`429`, im Speicher je Replikat, ohne IP), globale Obergrenze für Registrierungen je Replikat und Minute, höchstens 10 Abos je Installation. Ein Reverse Proxy sollte zusätzlich ein Rate-Limit je Quelle setzen.

Regel „Regen beginnt in N Minuten“: Nach jedem neuen Radarlauf wertet der Leader (`acquireLeader("push")`) die abonnierten Zellen aus. Pixelfarbe wird der nächsten Legendenfarbe (Toleranz) zugeordnet, transparente oder unbekannte Pixel zählen als trocken. Meldung nur, wenn die Zelle jetzt trocken ist, innerhalb von `lead_minutes` die Schwelle erreicht wird und dies in zwei aufeinanderfolgenden Läufen gilt (Hysterese). Danach höchstens eine Meldung je Abo und 60 Minuten; Wiederbewaffnung, wenn die Zelle für die nächsten 30 Minuten trocken ist. Läufe, die älter als 20 Minuten sind, lösen nichts aus. Der Payload enthält nur `loc-key` `RAIN_STARTS_IN`, die Minuten und `thread-id` (Abo-ID), keinen Ortsnamen. Löschung: 410 von Apple, `DELETE`, oder 60 Tage ohne Aktivität (`last_seen`); Outbox-Einträge werden nach 6 Stunden entfernt.

## Lauf- und Slot-ID

Format `YYYYMMDDTHHMMZ` in UTC, z. B. `20261030T1105Z`. `<run>` ist die Nominalzeit des Laufs, `<slot>` die Zeit des Slots; der Slot mit der Zeit des Laufs ist die Analyse (`kind: analysis`), spätere Slots sind Vorhersagen (`forecast`) bis +120 min im 5-Minuten-Raster.

## Verhalten der App (Fallback)

Die App nutzt den Radar-Cache und fällt auf den DWD-Direktweg zurück, wenn der Cache nicht antwortet oder die Daten älter als 20 Minuten sind. Der Radar-Cache ist damit eine optionale Beschleunigung; die App ist nicht von ihm abhängig.
