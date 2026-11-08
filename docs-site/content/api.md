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

## Zusatzebenen `/v1/layers/<ebene>/…`

Ebenen: `pressure`, `pressure_eu`, `lightning`, `clouds`, `cloudmask`, `cloudmask_vis`, `cloudmask_vis_eu` (Temperatur/Feuchte: eigener Abschnitt unten). Nur aktiv, wenn in `LAYERS` aktiviert; sonst `404`. Das Radar-API (`/v1/radar/…`, Schema 1) ist davon unberührt.

- `GET /v1/layers/<ebene>/latest.json`: Cache-Header wie Radar (`max-age=30, stale-while-revalidate=30`), `ETag`/`304`, `404` solange nichts veröffentlicht ist.
- `GET /v1/layers/<ebene>/<run>/<slot>.webp`: `public, max-age=31536000, immutable`, `ETag`. Pfade in `slots[].path` sind relativ zu `/v1/layers/<ebene>/`.
- Schema 1 mit eigenem Slot-Katalog: `layer`, `title`, `kind` (`forecast` Luftdruck mit `analysis`/`forecast`-Slots und `forecast_horizon_minutes`; `observation` mit `history_hours`), `run`, `reference_time`, `generated_at`, `step_minutes` (60, 5, 10, 15), `image` (`format`, `width`, `height`, `projection` EPSG:3857, `bbox`, `bbox_wgs84`; **je Ebene eigene Werte**: Deutschland-Ebenen wie das Radar 1024 × 1311, die `*_eu`-Ebenen Europa 2048 × 2168 mit `bbox` `[-2782987, 3503550, 5009377, 11753185]` und `bbox_wgs84` `[-25, 30, 45, 72]`; Bildgrößen immer höchstens 4096 px je Seite), `slots`, `attribution`, `modification_notice` und, falls die Quelle eine Legende nennt, `legend` (`url`, `width`, `height`; nur Verweis, nichts gespeichert). Wolkenebenen: deckende Bilder (`clouds` WebP verlustbehaftet, `cloudmask` verlustfrei). Quelle: DWD `Quelle: Deutscher Wetterdienst`; EUMETSAT wörtlich `Contains modified EUMETSAT Meteosat data <Jahr>` (Jahr der Veröffentlichung des neuesten Slots).
- `pressure_eu`: dieselbe DWD-Isobarenebene wie `pressure` (ICON, `Icon_reg025_fd_sl_PMSL`), Europa-Ausschnitt, transparentes verlustfreies WebP (RGBA), stündlich, Standard 24 Vorhersagestunden (`PRESSURE_EU_FORECAST_HOURS`). `pressure` (Deutschland) bleibt unverändert.
- `cloudmask_vis` (Deutschland, 1024 × 1311) und `cloudmask_vis_eu` (Europa, 2048 × 2168): sichtbarer Kanal `mtg_fd:vis06_hrfi` (Meteosat MTG FCI, 0,6 µm), nur Beobachtung, 10 min. **Pixelformat:** verlustfreies WebP, 8 Bit Graustufen als RGB mit R = G = B (Rohwert des Kanals 0 bis etwa 180, **nicht** auf 0 bis 255 normiert), Alpha 255. Keine Farbgebung und keine Sonnenhöhen-Normierung im Backend; die App liest den Rotkanal und rechnet Wolkendichte (Reflexion geteilt durch sin(Sonnenhöhe)). Nachts ist das Bild fast schwarz (Werte 0 bis 3, Rauschen); in der Nacht vom 31.10. zum 1.11.2026 lieferte EUMETView zwischen 22:30 und 01:30 UTC gar keine Bilder (Zeitwert nicht vorhanden, HTTP 502; ganze Scheibe dunkel). Solche Slots fehlen dann im Manifest (Lücken sind erlaubt, je Slot höchstens 2 Versuche); das neueste Manifest-Bild kann nachts also Stunden alt sein. Keine Legende (`legend` fehlt).
- Beobachtungsebenen listen nur veröffentlichte Slots, Lücken sind erlaubt; EUMETSAT-Bilder mit fehlenden (schwarzen) Kacheln werden nie veröffentlicht. Beim sichtbaren Kanal gilt die Prüfung nur dort, wo die Sonne um mehr als etwa 10 Grad über dem Horizont steht; Nachtbilder werden dadurch nicht verworfen.

## Temperatur- und Feuchtekarten `/v1/layers/temperature|dewpoint|humidity/…` (8. November 2026, Vertrag P1, Flags aus)

Drei **öffentliche** Ebenen-IDs: `temperature` (Lufttemperatur 2 m), `dewpoint` (Taupunkt 2 m), `humidity` (relative Feuchte 2 m). Die Routen sind die der Zusatzebenen (`latest.json`, `<run>/<slot>.webp`, Schema 1, Cache-Header, `ETag`). Der Server speichert je Quelle getrennt unter **internen** IDs (`temperature_wms`, `temperature_d2`, `dewpoint_d2`, `humidity_d2`, höchstens 16 Zeichen) und löst die öffentliche ID **zur Anfragezeit** auf die aktive interne Ebene auf; interne IDs sind **keine** Routen (`404`) und erscheinen weder im Manifest noch in `/v1/status`. Das Manifest nennt immer die öffentliche ID in `layer`. Die Cache-Schlüssel und "Cache leeren" im Dashboard arbeiten mit den internen IDs (`layer:temperature_wms/…`).

**Schalter** (Standard: alles aus, kein Verhaltenswechsel bestehender Deployments): `LAYERS` muss `temperature` enthalten (Hauptschalter, Neustart); `TEMP_SOURCE` (live) wählt die Quelle:

| `TEMP_SOURCE` | `temperature` | `dewpoint` | `humidity` |
|---|---|---|---|
| `off` (Standard) | `404` | `404` | `404` |
| `wms` | DWD-WMS-Bild (A), `source: "wms"` | `404` | `404` |
| `icon_d2` | ICON-D2 (B), `source: "icon_d2"`, sonst Warmstand A | nur mit `td_2m` in `TEMP_D2_PARAMS` und frischem Lauf | nur mit `relhum_2m` in `TEMP_D2_PARAMS` und frischem Lauf |

Ausfall und Fallback: ein ICON-D2-Lauf zählt bis `TEMP_D2_MAX_AGE_HOURS` (Standard 7 h) als frisch; ist er älter oder fehlt, liefert `temperature` den WMS-Lauf (nur wenn dieser höchstens 18 h alt ist, der Warmstand läuft bei `TEMP_FALLBACK_WARM=true` weiter), `dewpoint` und `humidity` antworten `404` (kein Ersatz). Die App blendet Ebenen mit `404` aus; ein Quellenwechsel zeigt sich im nächsten Manifest als anderer `run`, anderes `source`/`scale`/`legend`.

**Manifest** wie bei den Zusatzebenen (`kind: "forecast"`, 49 stündliche Slots, `step_minutes: 60`, `forecast_horizon_minutes: 2880`, `image` mit Radar-BBox 1024 × 1311, WebP) plus zwei **neue optionale** Felder (ältere App-Builds ignorieren sie):

- `source`: `"wms"` oder `"icon_d2"`.
- `scale`: Skalen-ID, **nur bei `icon_d2`** (das Backend färbt selbst): `t2m-d2-v1` (`temperature`), `td-d2-v1` (`dewpoint`), `rh-d2-v1` (`humidity`). Unbekannte `scale` oder `source`: die App zeigt nur einen Hinweistext (kein erratenes Raster).
- `legend` (nur Verweis, `maps.dwd.de`) bei `wms`; bei `icon_d2` fehlt es (die App zeichnet die Legende aus der Skala).

Beispiel A (`TEMP_SOURCE=wms`, Slots gekürzt):

```json
{"schema":1,"layer":"temperature","title":"Temperatur (ICON)","kind":"forecast","run":"20261108T0600Z",
 "reference_time":"2026-11-08T06:00:00Z","generated_at":"2026-11-08T07:41:12Z","step_minutes":60,"forecast_horizon_minutes":2880,
 "image":{"format":"image/webp","width":1024,"height":1311,"projection":"EPSG:3857","bbox":[612257.0,5942074.0,1736584.0,7381298.0],"bbox_wgs84":[5.5,47.2,15.6,55.1]},
 "slots":[{"time":"2026-11-08T06:00:00Z","kind":"analysis","path":"20261108T0600Z/20261108T0600Z.webp"},{"time":"2026-11-08T07:00:00Z","kind":"forecast","path":"20261108T0600Z/20261108T0700Z.webp"}],
 "attribution":"Quelle: Deutscher Wetterdienst","modification_notice":"Datenbasis: Deutscher Wetterdienst (ICON), Lufttemperatur 2 m bildlich wiedergegeben",
 "source":"wms","legend":{"url":"https://maps.dwd.de/geoserver/ows?service=WMS&version=1.3.0&request=GetLegendGraphic&format=image/png&layer=dwd:Icon-eu_reg00625_fd_gl_T&style=icon-eu_reg00625_fd_gl_t_isoarea_tkb","width":72,"height":482}}
```

Beispiel B (`TEMP_SOURCE=icon_d2`, Taupunkt; Umsetzung folgt mit Paket P4, Vertrag hier festgelegt): wie oben mit `"layer":"dewpoint"`, `"source":"icon_d2"`, `"scale":"td-d2-v1"`, ohne `legend`, Veränderungshinweis z. B. `Datenbasis: Deutscher Wetterdienst (ICON-D2), Taupunkt 2 m bildlich wiedergegeben`.

**Skalen** (Quelle der Wahrheit: `docs/fixtures/scales/scales-v1.json`, erzeugt und geprüft mit `tools/check_palette.py`; die App kopiert die Datei): `{"schema":1,"scales":[{"id","unit","min","max","step","label_every","bands":[{"from","hex"}]}]}`. Ein Band gilt von `from` (einschließlich) bis zum nächsten `from`; das letzte Band gilt bis `max` und darüber. Werte unter `min` gehören zum ersten, über `max` zum letzten Band (Beschriftung "unter -30", "über 40"). Die Bänder sind **gestuft**, die Pixelfarbe im (verlustfreien) Bild entspricht exakt der Bandfarbe (lokale Wertabfrage in der App, ohne Netz); Zellen ohne Wert sind transparent ("kein Wert").

| ID | Größe | Einheit | Bereich | Band | Beschriftung alle |
|---|---|---|---|---|---|
| `t2m-d2-v1` | Temperatur | °C | -30 bis 40 | 1 K (70 Bänder) | 5 K |
| `td-d2-v1` | Taupunkt | °C | -20 bis 24 | 1 K (44 Bänder) | 5 K |
| `rh-d2-v1` | relative Feuchte | % | 0 bis 100 | 5 % (20 Bänder) | 20 % |

Bei `wms` liefert der DWD die Farben (Klassen zu 5 K, Legendenbild); die App hat dafür keine Skalentabelle. Feuchte-Wörter ("schwül", "trocken") gibt es erst nach belegten Schwellen; bis dahin nur Zahlen. Quelle und Hinweis: "Quelle: Deutscher Wetterdienst" und `modification_notice` aus dem Manifest, Aussage "Modell, 2 m über Grund, kein Messwert".

## `GET /healthz`

Liveness für den Healthcheck (nur intern gedacht): `200` mit Body `ok`, `503` mit `stale`, wenn die Ingest-Schleife nicht mehr lebt. Prüft nicht die Datenaktualität.

## `GET /v1/status`

Datensparsame Betreiberdiagnose (additiv, `Cache-Control: no-store`). JSON: `schema` (1), `revision` (Commit des Images oder `null`), `push` (Boolean, kein Geheimnis), `capabilities` (Liste; aktuell `["regions", "live_activity", "live_activity_regions"]` bei `PUSH_ENABLED=true` (zusätzlich `"device_link"` bei `DEVICE_LINK_ENABLED=true`), sonst `[]`; `regions` steht für Umkreis-Abos, `live_activity` für den unten beschriebenen ActivityKit-Vertrag, `live_activity_regions` für Live Activities auf Umkreis-Abos (7. November 2026; ohne sie lehnten ältere Server `live_activity: true` mit `kind: "circle"` mit `400` ab, deshalb bietet die App die Option nur bei vorhandener Fähigkeit an). Die App prüft die einzelne Fähigkeit vor dem Anbieten der Option; fehlt sie, darf die Option nicht angeboten werden, weil ältere Backends unbekannte Abo-Felder ignorieren können), `now`, `layers[]` mit `id` (`radar`, `pressure`, `pressure_eu`, `lightning`, `clouds`, `cloudmask`, `cloudmask_vis`, `cloudmask_vis_eu`, `temperature`, `dewpoint`, `humidity`; die letzten drei mit `enabled` nach `TEMP_SOURCE`/`LAYERS` und `has_data` der aufgelösten Quelle), `enabled`, `has_data` und, falls Daten vorliegen, `latest_run` und `published_at`. Unterscheidet „Ebene nicht aktiviert“, „noch keine Daten“ und „Daten vorhanden“; bei Datenbankfehler `503`. Keine Nutzerdaten, keine Konfigurationswerte außer den genannten.

## Push-Registrierung `/v1/push/…` (optional, Standard aus)

Nur aktiv mit `PUSH_ENABLED=true`. Opt-in je Ort; es werden keine Koordinaten und keine Ortsnamen übertragen, sondern eine Rasterzelle des Radarbilds (siehe unten). Keine Cookies, keine Zugriffsprotokolle. Alle Antworten: `Cache-Control: no-store`, Fehler als `{"error":"<code>"}`. Rechtlich/technisch ist die Zelle (ca. 1 km) weiterhin personenbezogen.

Authentifizierung: Header `X-Installation-Secret` (zufällig, 32 bis 128 Zeichen aus `A-Za-z0-9_-`, in der Keychain der App). Der Server speichert nur den SHA-256-Hash. Die erste Registrierung einer Installations-ID legt das Geheimnis fest; falsche, fehlende oder unbekannte Kombinationen ergeben einheitlich `401`.

| Methode und Pfad | Body | Antwort |
|---|---|---|
| `PUT /v1/push/installations/<uuid>` | `{"token":"<hex>","env":"sandbox\|production","locale":"de\|en","live_activity_start_token":"<hex>"}` (letztes Feld optional) | `201` neu, `204` aktualisiert (Token, Umgebung, Sprache, `last_seen`) |
| `DELETE /v1/push/installations/<uuid>` | – | `204`; löscht Installation, Abos, Activities und Outbox |
| `GET /v1/push/installations/<uuid>/subscriptions` | – | `200`, Liste (`id`, `grid_version`, `cell_x`, `cell_y`, `threshold`, `lead_minutes`, `enabled`, `time_sensitive`, `live_activity`, `kind`; bei Umkreis zusätzlich `radius_cells`, `min_share_percent`) |
| `POST /v1/push/installations/<uuid>/subscriptions` | Abo-Felder | `201` `{"id":"<uuid>"}`; `409 subscription_limit` ab 10 Abos; `409 region_limit` / `409 region_capacity` bei Umkreisen (siehe unten) |
| `PUT /v1/push/installations/<uuid>/subscriptions/<sub>` | Abo-Felder | `204`, setzt den Automaten zurück; `404` falls fremd/unbekannt |
| `DELETE /v1/push/installations/<uuid>/subscriptions/<sub>` | – | `204` / `404` |
| `PUT /v1/push/subscriptions/<sub>/activity` | `{"activity_token":"<hex>"}` | `204`; registriert oder ersetzt das Activity-Token, siehe unten |
| `DELETE /v1/push/subscriptions/<sub>/activity` | `{"activity_token":"<hex>"}` oder ohne Body | `204`; mit Token: löscht nur bei Übereinstimmung mit dem aktuellen Token; ohne Token: gibt nur eine Reservierung ohne Token frei |
| `POST /v1/push/installations/<uuid>/test` | – | `200` `{"sent":true,"environment":"…"}`, siehe Testmeldung |

Abo-Felder: `grid_version` (`1`), `cell_x` (0 bis 1023), `cell_y` (0 bis 1310), `threshold` (Intensitätsklasse 1 bis 15 der DWD-Legende, mm/h, siehe `PushIntensity`), `lead_minutes` (`10`, `20` oder `30`), optional `enabled` (Standard `true`), optional `time_sensitive` (Boolean, Standard `false`; nur `true`/`false`, andere Typen ergeben `400`; `null` zählt als nicht gesetzt). Mit `true` setzt der Sender im `aps`-Payload `interruption-level: time-sensitive`, sonst fehlt das Feld. Die Antwort der Abo-Liste enthält `time_sensitive`. `PUT` ersetzt alle Felder: fehlt `time_sensitive`, wird es `false`. Ob die App Zeitkritisch nutzen darf, entscheidet ihr Entitlement `com.apple.developer.usernotifications.time-sensitive` (Sache der App, nicht des Backends; Entitlement-Name laut Recherche des App-Repos eine Annahme). Umkreis-Abos (Regionen, Version 1): optional `kind` (`"point"` Standard, `"circle"`), bei `circle` Pflicht `radius_cells` (3 bis 40 Zellen; Zellkante real etwa 0,7 km, die App rechnet km nach Breitengrad um: 5/10/25 km entsprechen etwa 7/14/36 Zellen) und optional `min_share_percent` (`1`, `10` oder `25`, Standard `10`). `cell_x`/`cell_y` sind der Mittelpunkt; der Server rundet ihn immer auf die Mitte seines 3×3-Zellblocks (etwa 2 km Genauigkeit: `x' = min(floor(x/3)*3+1, 1023)`, `y'` analog), unabhängig davon, was der Client sendet, und liefert den gerundeten Wert zurück. Die Zellmenge (Kreis `dx²+dy² ≤ r²`) berechnet ausschließlich der Server aus Mittelpunkt und Radius; Zellenlisten vom Client gibt es nicht. Bei `point` sind `radius_cells`/`min_share_percent` nicht erlaubt (`400`), ebenso unbekannte `kind`-Werte, Werte außerhalb der Bereiche oder falsche Typen. Ohne die neuen Felder gilt wie bisher ein einzelner Ort. Grenzen: höchstens 3 Regionen je Installation (innerhalb der 10 Abos) und höchstens 8 000 Zellen je Installation (Summe der Kreisflächen, z. B. nur ein Radius-40-Kreis mit 5 026 Zellen) → `409 region_limit`; serverweit höchstens 2 000 000 Regionszellen → `409 region_capacity` (weicher Wert: gleichzeitige Registrierungen verschiedener Installationen können ihn geringfügig überschreiten). Punkt-Abos zählen nicht. `PUT` prüft dieselben Grenzen (ohne das Abo selbst). Die App sollte vor dem Anbieten von Regionen `GET /v1/status` auf `capabilities` prüfen.

### Live Activities (additiv, Ortsabos und Umkreis-Abos)

Voraussetzung: Migration `007_push_activity.sql` (Rechte `ALTER` und `CREATE`) und aktivierter Pushdienst. Alte Installations- und Abo-Anfragen bleiben gültig; der normale Regen-Alert wird weiterhin gesendet.

- `PUT installations/<uuid>`: optional `live_activity_start_token` (`String` oder `null`). Fehlt das Feld, bleibt ein vorhandenes Token erhalten; `null` löscht es. Eine neue Installation ohne Feld hat kein Start-Token. Rotation ersetzt den bisherigen Wert. Validierung wie Gerätetoken: **32 bis 200 Hexzeichen, gerade Länge**, Großbuchstaben werden kleingeschrieben. Andere Typen oder Formate ergeben `400 invalid_installation`. Die übrigen bisherigen Pflichtfelder bleiben erforderlich.
- Abo-Feld `live_activity`: optionales Boolean, Standard `false`; `null` zählt als nicht gesetzt. Die Abo-Liste liefert das Feld immer. `PUT` ersetzt die Einstellungen; fehlt es, wird es `false`. Falsche Typen ergeben `400 invalid_subscription`. `live_activity: true` ist seit dem 7. November 2026 auch mit `kind: "circle"` erlaubt (Fähigkeit `live_activity_regions`); ältere Server antworteten darauf mit `400`. Nur aktivierte Abos (Ort oder Umkreis) mit `live_activity: true` sind für Registrierung/Start berechtigt. **`live_activity: true` verlangt ein gemeldetes Start-Token** der Installation (`live_activity_start_token`), sonst `409 start_token_required` (bei `POST` und `PUT` des Abos; `false` ist immer möglich). Serverweit gilt eine Obergrenze (`PUSH_MAX_ACTIVITY_SUBSCRIPTIONS`, Standard 5 000): darüber `503 activity_full`; ein bereits aktives Abo kann aktiv bleiben.
- Activity-Endpunkte: `PUT` und `DELETE /v1/push/subscriptions/<sub>/activity`, authentifiziert mit dem **Geheimnis der besitzenden Installation** (`X-Installation-Secret`). Ebenso unterstützt: `/v1/push/installations/<uuid>/subscriptions/<sub>/activity` mit zusätzlicher Besitzprüfung. `PUT` verlangt `{"activity_token":"<hex>"}`; Format wie oben, sonst `400 invalid_activity_token`. `DELETE` mit `activity_token` wie bisher; **`DELETE` ohne Body oder ohne das Feld** gibt eine Reservierung ohne Token frei (eine registrierte Activity bleibt unberührt, `204`); `activity_token: null` oder ungültig ergibt `400`. Eine Reservierung ohne Token wird außerdem nach 15 Minuten automatisch freigegeben (Server-Tick). Das Token wird nie zurückgegeben. `PUT` antwortet `409 activity_not_eligible` bei ausgeschaltetem Abo (oder ohne `live_activity`) oder einer bereits abgelaufenen Activity und `409 activity_limit`, wenn ein anderes Abo derselben Installation den Activity-Platz belegt. `DELETE` ist bei vorhandenem Abo idempotent (`204`); ein altes Token löscht keine inzwischen erfolgte Rotation. Unbekanntes Abo: `404 not_found`; falsches/fehlendes Geheimnis bei bekanntem Abo: `401 unauthorized`; fremdes Abo im verschachtelten Pfad: `404 not_found`.
- Maximal **eine** reservierte oder registrierte Activity pro Installation. Push-to-Start reserviert den Platz vor dem Versand; `activity_token` ist bis zur Meldung der App `NULL`. Token-Rotation verlängert weder `started_at` noch `ends_at`. Registrierung ohne vorherigen Server-Start belegt den Platz ebenfalls für höchstens acht Stunden ab Registrierung.
- **Platzkonflikt Ort gegen Gebiet (7. November 2026, Nutzerentscheidung): der Ort hat Vorrang.** (1) Läuft oder ist ein Orts-Abo reserviert (auch ohne Token), startet kein Gebiet (Start verworfen, Grund `activity_slot_busy`); ebenso ein Gebiet gegen ein anderes Gebiet (wer zuerst bestätigt, gewinnt). (2) Will ein Orts-Abo starten, während eine **laufende** Gebiets-Activity (Token gemeldet) den Platz hält, beendet der Server sie sauber (`event: end` mit `dismissal-date` an ihr Activity-Token, einmal, ohne Wiederholung), gibt den Platz in derselben Transaktion frei und startet danach den Ort; die Reihenfolge der Sendungen ist Ende, dann Start. Der Platz ist auch frei, wenn die Ende-Sendung scheitert (die Gebiets-Activity endet dann spätestens mit ihrer 8-Stunden-Grenze oder durch die App). (3) Eine Gebiets-Reservierung **ohne** Token (Start unterwegs) wird nicht verdrängt: der Ort-Start wird in diesem Lauf verworfen (`reservation_pending`); ein Sofortstart (Regen läuft) bleibt scharf und versucht es im nächsten Lauf erneut. (4) Das verdrängte Gebiet behält Automatenzustand und 60-Minuten-Sperre und startet erst wieder, wenn der Platz frei ist und seine eigenen Regeln greifen. (5) Wollen im selben Lauf Ort und Gebiet starten, wird zuerst der Ort bearbeitet (kein Start-dann-Ende-Flackern beim Gebiet). Der Activity-Endpunkt `PUT .../activity` bleibt unverändert (`409 activity_limit`, wenn ein anderes Abo den Platz belegt): eine von der App lokal gestartete Ort-Activity verdrängt serverseitig nichts; die App beendet in diesem Fall die Gebiets-Activity lokal selbst. Die Prüfung läuft unter dem Installationssperre-Zeilenlock in einer Transaktion mit `READ COMMITTED` und sperrenden Lesezugriffen, daher legen zwei gleichzeitige Anfragen verschiedener Abos derselben Installation nie zwei Activities an (eine Migration war nicht nötig). Ein verspätetes Ende für eine Reservierung ohne Token löscht nur noch eine weiterhin tokenlose Zeile; wurde inzwischen ein Token gemeldet, wird das Ende regulär per APNs gesendet.
- Dieselben Grenzen gelten: Body höchstens 2 KB (`413 too_large`), 60 Anfragen/Minute je Installation, Fehlversuchsgrenze und globale Ratenlimits (`429 rate_limited`, je Replikat). Der kurze Activity-Pfad prüft Größe, `global:any` und die zusätzliche Grenze `global:activity` (je 3 000/Minute und Replikat) sowie das Geheimnis-Format (`401`) vor jedem Datenbankzugriff; danach genau eine Besitzerabfrage. API-Antworten sind `no-store`.

**Last und Reihenfolge:** Die Activity-Arbeit läuft nach dem Alert-Versand im selben Tick und nur mit Budget (höchstens 200 Sendungen/Beenden und 8 Sekunden je 15-s-Tick; Rest wird im nächsten Tick abgearbeitet, ein neuer Radarlauf ersetzt die Warteschlange). Je Auswertungsseite (2 000 Abos) gibt es eine Sammelabfrage für die Abos mit `live_activity`; die Ablaufprüfung liest nur vorhandene Activity-Zeilen (eine Abfrage je 50 Zeilen). Migration `008_push_activity_index.sql`: Index auf `push_sub.live_activity`.

**Gebiete (Variante A, 7. November 2026):** Ein Umkreis-Abo mit `live_activity` läuft durch dieselbe Automatik wie ein Ort, mit dem Anteil als „Pseudo-Klasse“ je Slot. Der Auslöseanteil ist **derselbe wie beim Alert des Gebiets** (`min_share_percent`, 1/10/25 %, mindestens 3 Zellen, bei Gebieten unter 30 Zellen 1 Zelle; keine eigene Einstellung): Ein Slot gilt als nass, wenn mindestens so viele Zellen sicher die Schwellenklasse erreichen. Unbekannte Zellen (halbtransparente Maske, Farbe außerhalb der Legende) zählen nie als nass; reichen nass plus unbekannt aber an die Mindestzahl heran, ist der Slot „unbekannt“ und bestätigt weder Regen noch Ende (wie ein unbekannter Pixel beim Ort). Start, Zwei-Läufe-Bestätigung, 60-Minuten-Sperre (gemeinsam mit dem Alert über `last_sent_at`), Sofortstart-Bit bei Aktivierung und Start-Wiederholung bei laufendem Regen (höchstens 3 Versuche), Update je Lauf, Ende nach 30 Minuten sicherer Trockenheit, Opt-out und acht Stunden gelten unverändert. Ein Gebiet nutzt denselben einen Platz je Installation und das gemeinsame Activity-Budget; das Gebiets-Abo hat ein eigenes Activity-Token (je Abo).

**Auswertung und Zustellung:** Start (a) beim bestehenden bestätigten Regenbeginn (zwei aufeinanderfolgende Läufe) oder (b) wenn es bereits regnet: Der aktuelle Slot muss in zwei aufeinanderfolgenden vollständigen, höchstens 20 Minuten alten Läufen bekannt nass sein (Klasse ≥ Schwelle; ein unbekannter oder trockener aktueller Slot setzt die Bestätigung zurück). Voraussetzungen wie bei (a): Ortsabo mit `live_activity`, aktiviert, Start-Token, keine laufende oder reservierte Activity. Die Wiederholsperre von 60 Minuten je Abo gilt gemeinsam für beide Startwege (gemeinsamer Zeitstempel `last_sent_at`; ein Start bei laufendem Regen setzt ihn, ohne eine Mitteilung zu senden; dadurch ist auch die gewöhnliche Regenbeginn-Mitteilung dieses Abos 60 Minuten gesperrt). Nach Ende der Activity (30 Minuten sicher trocken, Opt-out, acht Stunden) ist ein neuer Start nach Ablauf der Sperre möglich. Danach Update je neuem vollständig ausgewertetem Radarlauf. Ende, wenn die nächsten 30 Minuten sicher trocken sind (unbekannte Pixel, also maskierte oder nicht erkannte Farben, gelten für die Activity weder als trocken noch als nass: sie bestätigen kein Ende und setzen keine Endzeit; dann bleibt `phase` `raining` ohne `eventDate`; die normale Regen-Meldung behandelt sie unverändert als trocken), beim Ausschalten der Option/des Abos oder spätestens acht Stunden nach Reservierung/Registrierung. Das Zeitlimit und Opt-out werden auch ohne neuen Radarlauf bei jedem Leader-Tick geprüft. Bei gelöschtem Abo/Installation werden die Activity-Daten durch Cascade entfernt; die App beendet ihre Anzeige lokal.

APNs-Pfad: `apns-push-type: liveactivity`, Topic `<APNS_TOPIC>.push-type.liveactivity`, Priorität **5 für Updates**, **10 nur für Start und Ende**. Host je Installation (`sandbox`/`production`), eingeschränkt durch `APNS_ENV` wie bisher. `410` und `BadDeviceToken` löschen bei Start ausschließlich das passende Push-to-Start-Token und die Reservierung, bei Update/Ende ausschließlich das passende Activity-Token samt Activity-Datensatz; die Installation und ihr gewöhnliches Gerätetoken bleiben erhalten. Ein verspätetes Update-/Ende-410 darf kein rotiertes Token löschen.

**Payload-Vertrag für die App (P8):** `aps.event` ist `start`, `update` oder `end`; `aps.timestamp`, `aps.stale-date` und bei Ende `aps.dismissal-date` sind ganze UNIX-Sekunden. `content-state` wird vor dem Versand als UTF-8-JSON auf höchstens **4 096 Bytes** begrenzt (größer wird verworfen durch einen Fehler, kein Versand). Die folgenden Felder entsprechen Swift `Codable` mit Standard-Datumsstrategie: Datumszahlen sind Sekunden seit **2001-01-01T00:00:00Z**, nicht UNIX-Sekunden.

| `content-state`-Feld | Typ / Bedeutung |
|---|---|
| `phase` | `startsIn`, `raining`, `endsIn` oder `dry` |
| `eventDate` | Datum oder `null`: erster nasser Slot bzw. erster trockener Slot nach Regen |
| `intensityClass` | Integer: höchste Intensitätsklasse im Prognoselauf, `0` bei trocken |
| `referenceTime` | Datum: nominale Zeit des Radarlaufs |
| `staleDate` | Datum: Referenzzeit + 20 Minuten |
| `wetSharePercent` | **nur Gebiete, optional:** Integer 0 bis 100: Anteil der Zellen mit Klasse ≥ Schwelle im aktuellen Slot, in Prozent der Gebietsfläche (auf ganze Prozent gerundet, mindestens 1, sobald eine Zelle nass ist; unbekannte Zellen zählen nicht als nass, der Wert ist also eine Untergrenze) |
| `peakSharePercent` | **nur Gebiete, optional:** Integer 0 bis 100: höchster `wetSharePercent`-Wert der Slots 0 bis 12 (etwa die nächsten 60 Minuten) |
| `regionRadiusKm` | **nur Gebiete, optional:** Integer ≥ 1: Radius in Kilometern (Zellen × Zellkante auf Breite der Mitte, gerundet); fehlt, wenn nicht berechenbar. Die App darf stattdessen den lokal bekannten Radius des Abos anzeigen |

Bei Gebieten ist `intensityClass` die höchste sicher erkannte Klasse **im Gebiet** über alle 25 Slots (statt der Pixelklasse eines Orts); `phase`/`eventDate` folgen dem Anteils-Pseudoverlauf (nass = Anteil erreicht den Auslöseanteil). Die drei Zusatzfelder fehlen bei Orten, die Payload eines Orts bleibt byte-identisch. Alte Apps dekodieren sie nicht (Swift `Codable` für optionale Felder: `decodeIfPresent`). Beispiel `content-state` eines Gebiets:

```json
{"eventDate":815142900.0,"intensityClass":4,"peakSharePercent":34,"phase":"startsIn","referenceTime":815142300.0,"regionRadiusKm":10,"staleDate":815143500.0,"wetSharePercent":0}
```

Größe der Gesamtnutzlast eines Starts: unter 700 Byte (Grenze 4 096; durch Test abgesichert). Der Start-`alert` bleibt „Regen beginnt bald“ / „Es regnet gerade“; die Attribute bleiben `{"displayName":"","subscriptionID":"<sub>"}` (Radius nur im `content-state`).

Start enthält zusätzlich `attributes-type: "RainActivityAttributes"`, `attributes: {"displayName":"","subscriptionID":"<sub>"}` und `alert: {"title":"Showers","body":"Regen beginnt bald"}` (Installationssprache `en`: `"Rain starting soon"`, sonst Deutsch). Startet die Activity bei laufendem Regen (`phase` `endsIn` oder `raining`), lautet der Text `"Es regnet gerade"` (`en`: `"It is raining right now"`); Apple verlangt für den Start einen `alert`. Bei laufendem Regen ist `phase` `endsIn` mit `eventDate` = erster sicher trockener Slot, oder `raining` ohne `eventDate`, wenn das Ende unsicher ist oder außerhalb des 120-Minuten-Fensters liegt. Payload-Felder und Vertrag sind unverändert. Der Anzeigename bleibt leer, weil das Backend keine Ortsnamen erhält; die App ordnet die Abo-ID lokal zu. Update/Ende enthalten keine Start-Attribute und keinen Alert. Ende setzt `dismissal-date` auf die Versandzeit.

**Fehler-/Wiederanlaufgrenzen:** Activity-Versand läuft separat vom normalen Alert-Outbox-Pfad. Bei unklarem Startfehler bleibt die Reservierung bis zum Ende/Timeout bestehen, um doppelte Starts zu verhindern; kein automatischer zweiter Push-to-Start. Updates werden erst mit dem nächsten Lauf erneut versucht, ein erfolgloses Ende beim nächsten Tick. Es gibt keine persistente Activity-Nachrichten-Outbox; ein Prozessabbruch zwischen bestätigtem Lauf und Versand kann eine Activity-Nachricht auslassen. Die App muss Datenalter sichtbar behandeln. Echte APNs-/ActivityKit-Zustellung und App-Decodierung sind noch nicht am Gerät geprüft.

**Datenschutz:** Gespeichert werden nur aktuelle Start-/Activity-Token, Abo-Bezug, Opt-in und Start-/Endzeit; keine Ortsnamen, Koordinaten oder Standortverläufe. Activity-Token sind Gerätekennungen mit Ortsbezug wie bisherige Pushdaten. Löschung mit Abo/Installation (Cascade), Activity-Ende, passendem `410` oder Ablauf der bisherigen Installationsfrist (60 Tage Inaktivität). Keine Token in Antworten oder Logs. Vor Livegang bleiben Datenschutztext/App-Privacy-Angaben durch Betreiber bzw. App-Paket zu ergänzen.

Das Raster ist das Pixelraster des Ingest-Bildes (1024 × 1311, EPSG:3857, feste Bbox aus `latest.json`): `x = floor((X - bbox0) / (bbox2 - bbox0) * 1024)`, `y = floor((bbox3 - Y) / (bbox3 - bbox1) * 1311)` mit Web-Mercator-Meterwerten `X`, `Y`. Die App rechnet lokal; der Server sieht nie eine Koordinate.

Grenzen: Body höchstens 2 KB (`413`), Token 32 bis 200 Hexzeichen, 60 Anfragen je Installation und Minute (`429`, im Speicher je Replikat, ohne IP), globale Obergrenze für Registrierungen je Replikat und Minute, höchstens 10 Abos je Installation. Zusätzlich (Härtung 2. November 2026, alles je Replikat im Speicher): Gesamtrate aller Push-Anfragen (`429 rate_limited`, 3 000 je Minute, vor jeder Prüfung), höchstens 10 fehlgeschlagene Authentifizierungen je Installations-ID und Minute (danach `429 rate_limited` ohne Datenbankzugriff), und die Schlüsseltabelle verdrängt bei Überlauf die ältesten Fenster, statt neue Schlüssel abzulehnen. Serverweite Obergrenzen (additiv): neue Installationen (`PUT`) und neue Abos (`POST`) beantworten bei Überschreitung `503` `{"error":"server_full"}`; bestehende Installationen können weiter aktualisieren, Abos ändern und löschen. `GET /v1/status` ist 5 Sekunden zwischengespeichert; unbekannte Radar-/Ebenen-Slot-IDs werden 10 Sekunden als „nicht vorhanden“ gemerkt. Ein Reverse Proxy sollte zusätzlich ein Rate-Limit je Quelle setzen.

Testmeldung (`POST /v1/push/installations/<uuid>/test`, ohne Body, Authentifizierung wie die übrigen Routen): sendet sofort eine Mitteilung „Showers Testmeldung“ (`en`: „Showers test notification“, Typ `test`, ohne Ort, ohne Abo-Bezug, ohne `interruption-level`) an das Gerätetoken der eigenen Installation in deren registrierter Umgebung. Für gewöhnliche Alerts ist es ein Gerätetoken je Installation; Activity-Token sind davon getrennt (siehe oben). Es wird nichts gespeichert (keine Outbox, keine neuen Felder); Ablauf der Meldung nach 10 Minuten. Grenze: 3 Testmeldungen je Installation und Stunde (im Speicher je Replikat), danach `429` `test_rate_limited` mit `Retry-After: 3600`. Fehler als `{"error":"<code>"}`, bei Apple-Fehlern zusätzlich `reason` (Apples Reason-Text, nie Token oder Schlüssel):

| Status | `error` | Bedeutung |
|---|---|---|
| `404` | – | Push nicht aktiv (`PUSH_ENABLED=false`) wie bei allen Push-Routen |
| `401` | `unauthorized` | Geheimnis falsch oder Installation unbekannt |
| `405` | `method_not_allowed` | nur `POST` |
| `409` | `environment_not_allowed` | die registrierte Umgebung steht nicht in `APNS_ENV` |
| `429` | `test_rate_limited` | mehr als 3 Testmeldungen in einer Stunde |
| `503` | `apns_unavailable` | APNs-Schlüssel beim Start nicht lesbar |
| `502` | `apns_bad_device_token` | Apple `BadDeviceToken`: Token passt nicht zur Umgebung (oder Schlüssel/Topic) |
| `502` | `apns_key_rejected` | Apple `InvalidProviderToken`: Schlüssel, Key-ID oder Team-ID ungültig, oder Schlüssel gilt nicht für diese Umgebung |
| `502` | `apns_unavailable` | vorübergehend (403 `ExpiredProviderToken`, 429, 5xx, Netz); später erneut versuchen |
| `502` | `apns_rejected` | anderer dauerhafter Apple-Fehler |
| `410` | `token_unregistered` | Apple meldet das Token als ungültig; die Installation wird wie beim normalen Versand gelöscht, die App registriert sich neu |

Umgebung je Installation: Die App meldet bei `PUT` `env` (`sandbox` für Debug-Builds, `production` für TestFlight/App Store). Der Sender wählt je Meldung den Host der Installation (`api.sandbox.push.apple.com` oder `api.push.apple.com`); `APNS_ENV=both` erlaubt beide Umgebungen im selben Betrieb, `sandbox`/`production` nur die genannte (andere Meldungen werden verworfen, die Testmeldung antwortet `409`). Es gibt genau einen Schlüssel je Betrieb (`APNS_KEY_FILE`), er wird für beide Hosts verwendet. Ob ein Schlüssel für beide Umgebungen reicht, siehe Installation.

Regel „Regen beginnt in N Minuten“: Nach jedem neuen Radarlauf wertet der Leader (`acquireLeader("push")`) die abonnierten Zellen aus. Pixelfarbe wird der nächsten Legendenfarbe (Toleranz) zugeordnet, transparente oder unbekannte Pixel zählen als trocken. Meldung nur, wenn die Zelle jetzt trocken ist, innerhalb von `lead_minutes` die Schwelle erreicht wird und dies in zwei aufeinanderfolgenden Läufen gilt (Hysterese). Danach höchstens eine Meldung je Abo und 60 Minuten; Wiederbewaffnung, wenn die Zelle für die nächsten 30 Minuten trocken ist. Läufe, die älter als 20 Minuten sind, lösen nichts aus. Umkreis-Abos: je Slot zählt der Server die Zellen der Kreisfläche mit Klasse ≥ `threshold`; die Region gilt in diesem Slot als nass, wenn mindestens `max(3, ceil(Zellen · min_share_percent / 100))` Zellen nass sind (bei Regionen unter 30 Zellen genügt 1 Zelle; am Bildrand zählen nur Zellen im Bild). Pro Slot entsteht damit ein Pseudo-Wert (`threshold` oder 0), auf den derselbe Automat unverändert angewendet wird (zwei Läufe, 60 Minuten Sperre, Wiederbewaffnung nach 30 trockenen Minuten in der ganzen Region); keine Meldung, wenn es in der Region schon regnet. Der Payload eines Umkreises nutzt `loc-key` `RAIN_REGION_STARTS_IN` (Text „Regen erreicht deine Region in N min“ / „Rain reaches your area in N min“, Strings liegen in der App) und `"region":true`, sonst unverändert (kein Ortsname, keine Koordinaten, keine Zellen). Der Payload enthält nur `loc-key` `RAIN_STARTS_IN`, die Minuten, `thread-id` (Abo-ID) und `mutable-content: 1`, keinen Ortsnamen. `mutable-content` erlaubt der Notification Service Extension der App, den nur lokal gespeicherten Namen anzuhängen; der Server kennt den Namen nie (Test- und Live-Activity-Pushes tragen es nicht). Löschung: 410 von Apple, `DELETE`, oder 60 Tage ohne Aktivität (`last_seen`); Outbox-Einträge werden nach 6 Stunden entfernt.

## Betreiber-Diagnose: Gerätekopplung (nur im Kopplungsfenster, Standard aus)

Stand: **eingefroren 6. November 2026** (WP-V; Kopplungsfenster statt TestFlight-Nachweis, Nutzerentscheidung 6.11.2026). Beispiele: `docs/fixtures/app/`. Freiwilliges Opt-in, mit dem der Betreiber sein **eigenes** Gerät im Dashboard zuordnet (Registrierungsstatus, Testpush, Live-Activity-Probe, Neuauswertung). Nur sichtbar und nutzbar, wenn alle Bedingungen gelten: Server `PUSH_ENABLED=true` **und** `DEVICE_LINK_ENABLED=true` (Standard `false`), `GET /v1/status` meldet in `capabilities` den Wert `device_link`, und `GET /v1/status` meldet ein offenes Kopplungsfenster (`device_link_window`, siehe unten). Die Installationsquelle (TestFlight oder App Store) spielt keine Rolle; die App fragt keinen StoreKit-Beleg mehr ab. Ohne offenes Fenster zeigt die App die Funktion nicht an. Ist der Schalter aus, antworten alle drei Routen mit `404` wie die übrigen Push-Routen bei `PUSH_ENABLED=false`.

Authentifizierung wie alle Push-Routen (`X-Installation-Secret`, einheitlich `401 unauthorized`); Antworten `no-store`, Fehler `{"error":"<code>"}`. Zeitpunkte ISO 8601 UTC mit `Z`. Die Kopplung ist **dauerhaft** (kein automatischer Ablauf, Nutzerentscheidung 6.11.2026) und jederzeit widerrufbar (siehe `DELETE`).

| Methode und Pfad | Body | Antwort |
|---|---|---|
| `POST /v1/push/installations/<uuid>/link-code` | `{}` | `201 {"code":"ABCD-EFGH","expires_at":"<ISO>","ttl_seconds":600}` |
| `GET /v1/push/installations/<uuid>/link` | – | `200`, Zustand (unten) |
| `DELETE /v1/push/installations/<uuid>/link` | – | `204`, idempotent |

**`link-code`.** Erzeugt einen Koppelcode, der nur im Dashboard von einem angemeldeten Betreiber (Passkey) eingelöst werden kann. Der Code hat 8 Zeichen aus dem Crockford-Base32-Alphabet (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`, 40 Bit), Anzeige als `XXXX-XXXX`; der Server speichert nur den SHA-256-Hash, der Code gilt 10 Minuten und genau einmal, je Installation gibt es höchstens einen offenen Code (ein neuer ersetzt den alten). **Nur im Kopplungsfenster:** Der Betreiber öffnet das Fenster im Dashboard (Standard 5 Minuten, höchstens 15, schließt automatisch nach der ersten erfolgreichen Einlösung). Ohne offenes Fenster antwortet die Route einheitlich `403 pairing_closed` (vor jeder weiteren Logik; nur bei abgeschaltetem Feature `404`). Der Body ist `{}`; ein gesendetes `app_transaction` wird ignoriert. Ein bereits ausgegebener Code bleibt bis zu seinem Ablauf (10 Minuten) einlösbar, auch wenn das Fenster inzwischen schließt; neue Codes gibt es nur im Fenster. Eingelöst wird ein Code weiterhin ausschließlich vom Betreiber mit Passkey im Dashboard. Zum Schutz vor Flutung durch Fremde gilt zusätzlich ein Limit von 30 ausgegebenen Codes je Fenster und Replikat (danach `429 link_code_rate_limited` mit `Retry-After` bis zum Fensterende).

**Optionaler Nachweis (nur `DEVICE_LINK_REQUIRE_TESTFLIGHT=true`, Standard `false`, nur per Umgebungsvariable).** Dann gilt zusätzlich der bisherige Vertrag: `app_transaction` ist das von StoreKit gelieferte `AppTransaction.jwsRepresentation` (kompaktes JWS, `ES256`, `x5c`-Kette), fehlt es: `400 invalid_request`, ist es ungültig: `403 not_testflight`. Das Backend verifiziert die Signaturkette gegen im Repo gebündelte Apple-Wurzelzertifikate, `bundleId` (= `DEVICE_LINK_BUNDLE_ID`, Standard Basis von `APNS_TOPIC`), `receiptType` (muss in `DEVICE_LINK_ALLOWED_ENVS` stehen, Standard `Sandbox`; `Xcode` ist erlaubbar, wird aber nicht gegen `APNS_ENV` geprüft (Xcode-Belege enden nie in der Apple-Kette und werden vom Verifier abgelehnt); `Production` nie) und das Alter von `receiptCreationDate` (höchstens `DEVICE_LINK_MAX_AGE_HOURS`, Standard 24; nach dem WP14-Spike gegebenenfalls anzupassen). Gespeichert wird nur das Prüfergebnis (`attested`), **nie** das JWS oder `appTransactionId`; das JWS darf in keinem Log erscheinen. Body höchstens 8 KB (diese Route; sonst gelten 2 KB).

| Status | `error` | Bedeutung |
|---|---|---|
| `201` | – | Code erzeugt |
| `400` | `invalid_request` | Body kein JSON-Objekt (bei `DEVICE_LINK_REQUIRE_TESTFLIGHT=true` zusätzlich: `app_transaction` fehlt oder ist kein String) |
| `401` | `unauthorized` | Geheimnis falsch oder Installation unbekannt |
| `403` | `pairing_closed` | kein Kopplungsfenster offen (einheitlich) |
| `403` | `not_testflight` | nur bei `DEVICE_LINK_REQUIRE_TESTFLIGHT=true`: Nachweis fehlt, ungültig, abgelaufen, falsche Bundle-ID oder Umgebung (einheitlich, ohne Grund) |
| `404` | – | `DEVICE_LINK_ENABLED=false` oder Push aus |
| `409` | `already_linked` | die Installation ist bereits gekoppelt (zuerst `DELETE …/link`) |
| `409` | `link_full` | serverweit bereits `DASH_MAX_DEVICES` Geräte gekoppelt (Standard 3) |
| `413` | `too_large` | Body größer als 8 KB |
| `429` | `rate_limited` / `link_code_rate_limited` | allgemeine Grenze (60 pro Minute je Installation) bzw. mehr als 6 Codes pro Stunde je Installation bzw. mehr als 30 Codes im Fenster (`Retry-After`) |

Die Zähler der Ablehnungen (`device_link_reject`, feste Gründe `unverified`, `production`, `expired`, `bundle`) sind nur serverseitig sichtbar; die Antwort verrät den Grund nicht.

**`link`** liefert alle Felder immer, nicht zutreffende als `null`:

```json
{ "state": "none", "code_expires_at": null, "linked_at": null, "expires_at": null, "last_action_at": null, "pending_commands": 0 }
```

`state`: `none` (nicht gekoppelt, kein offener Code), `code_open` (Code erzeugt, `code_expires_at` gesetzt), `linked` (`linked_at` gesetzt; `expires_at` ist `null`, solange der Betreiber kein `DASH_DEVICE_TTL_DAYS` eingestellt hat; `last_action_at` = letzte Dashboard-Aktion für dieses Gerät oder `null`; `pending_commands` = Anzahl noch nicht ausgeführter Dashboard-Aufträge, 0 bis 5). Die Bezeichnung, die der Betreiber vergibt, wird **nicht** zurückgegeben. Die App fragt nur, solange der Code-Bildschirm offen ist, alle 3 Sekunden, höchstens 10 Minuten (das Ratenlimit von 60 pro Minute je Installation reicht), und beim Öffnen des Info-Sheets einmal. `GET` ist unabhängig vom TestFlight-Nachweis möglich, damit die App eine Kopplung nach einem Wechsel zu App Store erkennen und entfernen kann.

**`DELETE`** löscht Kopplung, offenen Code und alle Geräteereignisse und -befehle dieses Geräts sofort. Es verlangt keinen Nachweis (Aufräumen muss immer möglich sein) und ist idempotent. Wechselt eine Installation von TestFlight zu App Store (Update), muss die App beim nächsten Start `DELETE` senden und den Schalter entfernen.

### Befehle und Ereignisse für gekoppelte Geräte

Es gibt **keinen** Abruf- oder Befehlskanal zur App: Die App erhält keine Befehle und liefert keine Ereignisse. Aktionen des Betreibers (Testpush, Live-Activity-Probe, Ende, Neuauswertung, Slot-Reset) erzeugt das Dashboard serverseitig (Befehlstabelle `dashboard_command`, Vertrag in der Dashboard-API); der Leader führt sie über die bestehenden APNs-Wege aus. Für die App bedeutet das ausschließlich:

- **Testpush:** normale Testmeldung (Payload wie `POST …/test`, Typ `test`); die App behandelt sie wie bisher.
- **Live-Activity-Probe:** regulärer Push-to-Start nach Payload-Vertrag P8 (`aps.event: start`, `attributes-type: "RainActivityAttributes"`, echter `content-state`), mit Alert-Text `Live-Activity-Test` (`en`: `Live Activity test`). Die App muss ihn wie jeden Start verarbeiten und das Activity-Token wie gewohnt per `PUT …/activity` melden.
- **Live Activity beenden:** `aps.event: end` an das Activity-Token wie im Normalbetrieb.
- **Ereignisverlauf (48 h) und Diagnose** liegen nur im Dashboard; die App zeigt nichts davon außer dem Kopplungszustand (`link`).

Datenschutz: gespeichert werden Zuordnung (Installation zu Kopplung), vom Betreiber vergebene Bezeichnung, Zeitpunkte und ein 48-Stunden-Verlauf technischer Versandergebnisse (Art, Ergebnis, APNs-Reason). Keine Gerätemodelle, OS-Versionen, IPs, Koordinaten oder Zellen, keine Token im Klartext in Dashboard-Antworten. Löschung: Ausschalten in der App, Trennen im Dashboard, Löschen der Installation (Cascade) oder ausdrücklich gesetztes `DEVICE_LINK_ENABLED=false` (eine fehlende Variable beim Push-Leader löscht keine Kopplungen).

Capability: `GET /v1/status` listet bei aktivem Schalter zusätzlich `device_link` in `capabilities` (additiv wie `regions` und `live_activity`; die App prüft sie vor dem Anbieten).

**Kopplungsfenster in `GET /v1/status`.** Zusätzliches Top-Level-Feld `device_link_window`: fehlt oder `null`, wenn kein Fenster offen ist (oder die Funktion aus ist); sonst `{"ends_at":"<ISO8601 UTC>"}` (Beispiel: `docs/fixtures/app/status.device_link_window.json`). Die Statusantwort wird höchstens 5 Sekunden zwischengespeichert, ein Fenster erscheint oder verschwindet also mit bis zu 5 Sekunden Verzug; die App fragt `link-code` ohnehin erst auf Nutzeraktion und bekommt sonst `403 pairing_closed`. Die App zeigt die Kopplung nur an, solange `capabilities` `device_link` enthält und ein Fenster offen ist (oder bereits ein Code offen bzw. ein Gerät gekoppelt ist, damit sie Widerruf anbieten kann).

## Amtliche Warnungen `/v1/warnings/…` und Warn-Abos (7. November 2026, Vertrag W0, implementiert in W2, Flags aus)

Quelle: DWD-Opendata-CAP (`DISTRICT_DWD_DIFF`/`_STAT`, **Kreisebene**, Profil 2.1.14; Nutzerentscheidung 7.11.2026 aus Lizenzgründen, die Gemeindeebene `COMMUNEUNION_*` ist nur eine spätere Erweiterung, der Parser versteht beide); ein Warngebiet (`warncell_ids`) ist eine Kreis-Warnzelle: 9 Ziffern, Typ 1 `1` + Kreis-AGS (5 Stellen) + `000`, Typ 10 mit Präfix `9` für geteilte Küsten-/Inselkreise (z. B. `909184999` München, `903352001`/`903352002` Cuxhaven Binnenland/Küste); Text, Stufe und Zeiten unverändert vom DWD, kein Ersatz für amtliche Warnkanäle (WarnWetter-App, NINA). Alle Fixtures unter `docs/fixtures/warnings/`. Flags (Standard aus): `WARN_INGEST_ENABLED`, `WARN_PUSH_ENABLED`.

**Fähigkeiten in `GET /v1/status`:** `"warnings"` genau dann, wenn `WARN_INGEST_ENABLED=true` (unabhängig von `PUSH_ENABLED`; bei ausgeschaltetem Push bleibt der Rest der Liste leer). `"warnings_push"` genau dann, wenn `PUSH_ENABLED=true`, `WARN_INGEST_ENABLED=true` und `WARN_PUSH_ENABLED=true`. Die App bietet Anzeige nur mit `warnings`, Push-Einstellungen nur mit `warnings_push` an; ältere Backends kennen beides nicht.

**Typen (`kind`):** `severe_weather` (Gewitter, Sturm/Orkan, Stark-/Dauerregen, Schneefall/Schneeverwehung, Tauwetter), `frost` (Frost, Strenger Frost), `ice` (Glätte, Glatteis). Hitze, UV und Nebel werden nicht gespeichert (Nutzerentscheidung 7.11.2026). **Stufe (`severity`) 1 bis 4:** CAP `Minor`=1, `Moderate`=2, `Severe`=3, `Extreme`=4 (am 7.11.2026 für `FROST`/`Minor`=Stufe 1 an einer echten Meldung bestätigt; 2 bis 4 anhand Profil, nicht an echten Meldungen geprüft). Zeiten ISO 8601 UTC (`...Z`). Die Zuordnung Ereigniscode (`eventCode II`) zu `kind` liegt in der Server-Tabelle `WarnEventMap` (W1); unbekannte Ereignisse werden gezählt, nicht gespeichert.

### `GET /v1/warnings/active`

Ohne Authentifizierung, ohne Ortsangabe, bundesweit alle aktiven (nicht abgelaufenen, nicht aufgehobenen) Warnungen der drei Typen. Nur mit `WARN_INGEST_ENABLED=true`, sonst `404 {"error":"not_found"}`. Antwort `200`, `Cache-Control: public, max-age=30`, Sprache per `Accept-Language` (`en` liefert Englisch, sonst Deutsch; fehlt der englische Text, steht der deutsche mit `"lang":"de"`).

JSON: `schema` (1), `source` (`"dwd"`), `fetched_at` (letzter erfolgreicher Feed-Abgleich, UTC), `warnings[]` mit `id` (CAP-`identifier`), `kind`, `severity` (1 bis 4), `event` (CAP-`event`, unverändert), `sent`, `onset`, `expires`, `headline`, `text` (CAP `description`), `instruction` (kann leer sein), `lang` (`de`|`en`), `warncell_ids` (Liste von je 9 Ziffern). Beispiel: `docs/fixtures/warnings/active.200.json`. Das Gerät filtert lokal nach seinen Warngebieten; es verlässt dadurch keine Gebietskennung das Gerät. Ohne Daten (z. B. noch kein Abgleich): `503 {"error":"warnings_unavailable"}`.

### Warn-Abos (nur mit `PUSH_ENABLED` und `WARN_PUSH_ENABLED`, sonst `404`)

Authentifizierung wie die Push-Routen (`X-Installation-Secret`, einheitlich `401`). Pfade:

| Methode und Pfad | Antwort |
|---|---|
| `GET /v1/push/installations/<uuid>/warn-subscriptions` | `200` Liste (`id`, `warncell_ids`, `types`, `min_severity`, `enabled`, `time_sensitive`) |
| `POST /v1/push/installations/<uuid>/warn-subscriptions` | `201` `{"id":"<uuid>"}` |
| `PUT /v1/push/installations/<uuid>/warn-subscriptions/<sub>` | `204`, ersetzt alle Felder; `404` falls fremd/unbekannt |
| `DELETE /v1/push/installations/<uuid>/warn-subscriptions/<sub>` | `204` / `404` |

Body (Beispiel `warn-subscription.request.json`): `warncell_ids` (1 bis 64 Strings, je genau 9 Ziffern, ohne Duplikate), `types` (nicht leere Teilmenge von `severe_weather`, `frost`, `ice`), `min_severity` (Objekt `kind -> 1..4`; fehlt ein aktivierter Typ, gelten die Standardwerte `severe_weather` 3, `frost` 1, `ice` 2), optional `enabled` (Standard `true`), optional `time_sensitive` (Boolean, Standard `false`; nur Bedeutung für die App-Einstellung "Zeitkritisch", der Server setzt `interruption-level: time-sensitive` bei Stufe 4 immer, sonst nur bei `true`). Falsche Typen oder Formate: `400 invalid_warn_subscription`. Grenzen: höchstens 10 Warn-Abos und 128 Warngebiete je Installation, sonst `409 warn_limit`; Warngebiet-ID nicht in der DWD-Kreisliste (Tabelle `warn_cell_known`, 402 Zellen; geprüft erst, wenn mindestens 300 IDs gespeichert sind, vorher akzeptiert der Server jede wohlgeformte ID): `409 warncell_unknown`. Body höchstens 4 KB (`413 too_large`), Ratenlimits wie die Push-Routen (`429`). Warn-Abos zählen nicht zum 10er-Limit der Regen-Abos und erscheinen nicht in `GET .../subscriptions`. Gespeichert werden nur Warngebiets-IDs, keine Koordinaten, keine Namen.

### Push-Payload (APNs)

Der Alert ist eine eigene Kurzmeldung, kein DWD-Wortlaut (kein DWD-`headline`/`description`, keine Kürzung amtlicher Texte, kein "Quelle: DWD" im Push): `aps.alert.title-loc-key` = `WARN_PUSH_TITLE_SEVERE` | `WARN_PUSH_TITLE_FROST` | `WARN_PUSH_TITLE_ICE` (je nach `kind`), `aps.alert.title-loc-args` = `["<Stufe 1..4>"]`, `aps.alert.loc-key` = `WARN_PUSH_BODY` (ohne `loc-args`). Als Rückfall ohne Lokalisierung (Schlüssel fehlt, App nicht lesbar) zusätzlich `aps.alert.title` (`Unwetterhinweis, Stufe N` | `Frosthinweis, Stufe N` | `Glättehinweis, Stufe N`) und `aps.alert.body` = `Tippen für Details.`. Die Schlüssel entsprechen den App-Strings (`WARN_PUSH_TITLE_SEVERE`: "Unwetterhinweis, Stufe %d"); die Notification Service Extension der App ersetzt den Alert bei `type=warning` weiterhin und ergänzt den Ort im `subtitle`. Die vollständige, unveränderte DWD-Warnung gibt es nur über `GET /v1/warnings/active`. Gesamtpayload unter 1 900 Bytes (praktisch unter 700), `aps.sound` `default`, `aps.thread-id` = Abo-ID, `aps.mutable-content` `1`, `aps.interruption-level` `time-sensitive` nur bei Stufe 4 oder `time_sensitive: true`, sonst fehlt das Feld. Top-Level: `type` `"warning"`, `kind`, `severity`, `sent` (ISO UTC), `warning_id`. Kein Ortsname, keine Koordinate. `collapse_id` `<sub>:<kind>` (höchstens 64 Bytes). Auslieferung über die bestehende Outbox (`apns-expiration` = min(`expires`, jetzt + 6 h)). Sprache je Installation (`locale`): bestimmt nur die gewählte Meldung (`warning_id`, englische bei `en`, sonst deutsch; fehlt eine Sprache, die andere); der Alert-Text selbst wird vom Gerät lokalisiert. `warning_id` ist der CAP-`identifier` der gewählten Sprache; Dedupe über den sprachlosen Schlüssel (`sha256(sub_id|alert_key)`), damit DE und EN nie doppelt zählen.

### Auslöseregeln (Verhalten, Tests in W2)

Push nur für Meldungen mit `sent` höchstens 20 Minuten alt und `expires` in der Zukunft. Neue Meldung (`msgType` Alert): Push, wenn Typ aktiv und Stufe größer oder gleich Mindeststufe und Schnittmenge der Warngebiete nicht leer. Update: Push nur bei höherer Stufe, anderem Typ oder um mehr als eine Stunde früherem Beginn gegenüber der Kette; sonst nur in der App-Liste. Cancel/Ablauf: nie Push (Entwarnung nur in der App). Wiederholsperre 60 Minuten je (Abo, Typ), eine höhere Stufe durchbricht sie. Dedupe `sha256(sub_id|alert_key)` (`alert_key` = Identifier ohne `.DEU`/`.ENG`; 64 Hex-Zeichen). Die Warnungsliste `GET /v1/warnings/active` setzt `Vary: Accept-Language`. Zählerlabels (fest): `warn_push` `sent`, `payload_too_large`, `trigger_error`, `suppressed_<Grund>`; `warn_ingest` `stored`, `cancelled`, `ignored`, `rejected`, `fetch_error`, `store_error`.

## Lauf- und Slot-ID

Format `YYYYMMDDTHHMMZ` in UTC, z. B. `20261030T1105Z`. `<run>` ist die Nominalzeit des Laufs, `<slot>` die Zeit des Slots; der Slot mit der Zeit des Laufs ist die Analyse (`kind: analysis`), spätere Slots sind Vorhersagen (`forecast`) bis +120 min im 5-Minuten-Raster.

## Verhalten der App (Fallback)

Die App nutzt den Radar-Cache und fällt auf den DWD-Direktweg zurück, wenn der Cache nicht antwortet oder die Daten älter als 20 Minuten sind. Der Radar-Cache ist damit eine optionale Beschleunigung; die App ist nicht von ihm abhängig.
