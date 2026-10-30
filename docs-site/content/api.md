# API-Referenz

Alle Endpunkte sind `GET`, ohne Authentifizierung, ohne Cookies und ohne Ortsangabe. Der Vertrag ist gegenüber der früheren Python-Fassung unverändert. Beispielwerte unten sind Platzhalter.

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

## Lauf- und Slot-ID

Format `YYYYMMDDTHHMMZ` in UTC, z. B. `20261030T1105Z`. `<run>` ist die Nominalzeit des Laufs, `<slot>` die Zeit des Slots; der Slot mit der Zeit des Laufs ist die Analyse (`kind: analysis`), spätere Slots sind Vorhersagen (`forecast`) bis +120 min im 5-Minuten-Raster.

## Verhalten der App (Fallback)

Die App nutzt den Radar-Cache und fällt auf den DWD-Direktweg zurück, wenn der Cache nicht antwortet oder die Daten älter als 20 Minuten sind. Der Radar-Cache ist damit eine optionale Beschleunigung; die App ist nicht von ihm abhängig.
