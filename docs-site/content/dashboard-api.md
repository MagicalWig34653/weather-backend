# Dashboard-API

Nur auf dem Dashboard-Listener (nie auf dem öffentlichen Port), Basis `/dash/api`. JSON, UTF-8, Feldnamen camelCase, Antworten mit `Cache-Control: no-store`. Binärwerte (Challenges, IDs, Signaturen) sind Base64URL ohne Padding. Fehlerantworten: `{"error":"<code>"}` (kein Klartext, keine Details). Die übrigen Abschnitte (Statistik, Konfiguration, Neustart) ergänzt WP5.

## Authentifizierung

Passkey (WebAuthn): Attestation `none`, ES256, `userVerification: required`, Resident Key bevorzugt, fester Benutzer-Handle `operator`. Bibliothek: [swift-webauthn](https://github.com/swift-server/swift-webauthn) 1.0.0-beta.1 (Apache-2.0, exakt gepinnt). `rp.id` und Origin kommen aus `DASH_RP_ID` und `DASH_ORIGIN`; `X-Forwarded-*` wird nie ausgewertet.

### Gemeinsame Prüfungen

| Prüfung | Gilt für | Fehler |
|---|---|---|
| `Host` gleich dem Host aus `DASH_ORIGIN` (Groß-/Kleinschreibung egal) | alle Anfragen | 403 |
| `Origin` exakt gleich `DASH_ORIGIN` (kein Schrägstrich am Ende) | POST, PUT, DELETE, PATCH | 403 |
| `Content-Type: application/json` | POST, PUT, DELETE, PATCH | 403 |
| Sitzungs-Cookie gültig | alle Routen außer `session`, `setup/*`, `login/*` | 401 |
| `X-CSRF-Token` gleich dem Token der Sitzung (konstante Zeit) | schreibende Routen mit Sitzung | 403 |

Antwort-Statuscodes der Auth-Routen: 400 (Body ungültig, `validation`), 401 (Prüfung fehlgeschlagen oder Challenge unbekannt, abgelaufen, benutzt; `unauthorized`), 403 (`forbidden` für Host/Origin/CSRF; `setup_closed` für das geschlossene Einrichtungsfenster), 409 (`conflict`: Passkey existiert bereits bei `setup/*`, keiner bei `login/begin`), 429 (`rate_limited`, mit `Retry-After` in Sekunden).

### Sitzungs-Cookie und CSRF-Token

Cookie `__Host-dash_session`, Wert 32 Zufallsbytes (43 Zeichen Base64URL), Attribute exakt: `Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=<Sekunden der absoluten Laufzeit>`, ohne `Domain`. In der Datenbank liegt nur der SHA-256 des Wertes. Absolute Laufzeit 12 Stunden (`DASH_SESSION_HOURS`), Leerlauf 30 Minuten (`DASH_IDLE_MINUTES`), gleitend verlängert bei jeder Anfrage, nie über die absolute Laufzeit hinaus. Jede Anmeldung erzeugt eine neue Sitzung (Rotation); ältere Sitzungen bleiben gültig, bis sie ablaufen oder per Abmeldung bzw. `dashboard-reset` gelöscht werden. Abmeldung löscht die Zeile und setzt das Cookie mit `Max-Age=0` zurück.

CSRF-Token: 256 Bit, abgeleitet per HMAC-SHA256 aus dem Cookie-Wert (Schlüssel = Cookie-Wert); in der Datenbank liegt nur sein SHA-256. Das erlaubt, das Token nach einem Seiten-Reload erneut über `GET session` zu liefern, obwohl es nicht im Klartext gespeichert ist. Ohne Cookie lässt es sich nicht berechnen. Der Client hält es nur im Speicher und sendet es bei jeder schreibenden Anfrage als `X-CSRF-Token`.

### `GET /dash/api/session`

Ohne Sitzung nutzbar. Antwort 200:

```json
{ "state": "setupOpen", "minutesLeft": 12 }
{ "state": "setupClosed" }
{ "state": "login" }
{ "state": "authenticated", "csrfToken": "…", "credential": { "name": "Passkey des Betreibers", "createdAt": "2026-11-04T19:31:00Z" } }
```

`setupOpen`: kein Passkey vorhanden und das Fenster offen. `setupClosed`: kein Passkey und Fenster abgelaufen (nur ein Neustart des Dashboards öffnet es wieder). `login`: Passkey vorhanden, keine gültige Sitzung.

### Einrichtung (erster Passkey, ohne Token)

Nur solange kein Passkey existiert und das Fenster offen ist (`DASH_SETUP_WINDOW_MINUTES`, Standard 15, ab Prozessstart). Die Registrierung ist atomar: parallele Versuche scheitern bis auf einen mit 409.

`POST /dash/api/setup/begin` mit Body `{}`. Antwort 200:

```json
{
  "challengeId": "<16 Byte Base64URL>",
  "options": {
    "rp": { "id": "dash.example.net", "name": "Showers Dashboard" },
    "user": { "id": "b3BlcmF0b3I", "name": "operator", "displayName": "Betreiber" },
    "challenge": "<32 Byte Base64URL>",
    "pubKeyCredParams": [ { "type": "public-key", "alg": -7 } ],
    "timeout": 300000,
    "attestation": "none",
    "authenticatorSelection": { "residentKey": "preferred", "userVerification": "required" }
  }
}
```

`options` ist unverändert (nach Wandlung von `challenge` und `user.id` in Puffer) als `publicKey` an `navigator.credentials.create` übergeben. Die Challenge ist 5 Minuten gültig und einmalig verwendbar (liegt in `dashboard_challenge`, daher Mehrprozessbetrieb möglich).

`POST /dash/api/setup/finish`:

```json
{ "challengeId": "…", "credential": { "id": "…", "rawId": "…", "type": "public-key",
  "response": { "clientDataJSON": "…", "attestationObject": "…", "transports": ["internal"] } } }
```

Antwort 204 mit `Set-Cookie` (der Betreiber ist danach angemeldet) und Audit-Eintrag `setup`. Fehler: 401 (Attestation ungültig: falsche Origin, falscher `rpIdHash`, Challenge, UV-Flag fehlt), 409 (Passkey existiert), 403 `setup_closed`.

### Anmeldung

`POST /dash/api/login/begin` mit Body `{}`. Antwort 200:

```json
{ "challengeId": "…", "options": { "challenge": "…", "rpId": "dash.example.net", "timeout": 60000,
  "userVerification": "required", "allowCredentials": [ { "type": "public-key", "id": "<Credential-ID>" } ] } }
```

409 `conflict`, wenn noch kein Passkey existiert.

`POST /dash/api/login/finish`:

```json
{ "challengeId": "…", "credential": { "id": "…", "rawId": "…", "type": "public-key",
  "response": { "clientDataJSON": "…", "authenticatorData": "…", "signature": "…", "userHandle": "…" } } }
```

Geprüft werden Challenge (einmalig, 5 min), Origin, `rpIdHash`, Flags (User Present und User Verified), Credential-ID, Signatur und der Signaturzähler: steigt er nicht (Rollback, Klonverdacht), wird die Anmeldung abgelehnt und im Audit vermerkt; Zähler 0 bei gespeichertem Zähler 0 ist erlaubt (Authenticator ohne Zähler). Antwort 204 mit `Set-Cookie`, Audit-Eintrag `login`. Es wird nie eine Challenge wiederverwendet; auch eine fehlgeschlagene Prüfung verbraucht sie.

### `POST /dash/api/logout`

Sitzung und CSRF erforderlich, Body `{}`. Antwort 204 mit zurückgesetztem Cookie.

### Ratenbegrenzung

Ohne IP, global je Prozess (im Speicher): `setup/begin` und `login/begin` 10 pro Minute, `setup/finish` und `login/finish` 5 pro Minute (je getrennt gezählt), Konfigurationsschreiben 30 pro Minute, alle übrigen Routen 600 pro Minute. Zusätzlich verzögern Fehlversuche (Setup und Login zusammen): drei Fehlversuche frei, danach 5 s, 10 s, 20 s … bis höchstens 5 Minuten Sperre (429 mit `Retry-After`); ein Erfolg setzt zurück, Fehlversuche verfallen nach 15 Minuten. Mit mehreren Dashboard-Replikaten gilt jede Grenze je Prozess.

### Notfall: `radar dashboard-reset --yes`

Löscht Passkey, Sitzungen und offene Challenges und schreibt einen Audit-Eintrag `reset_cli`; das Einrichtungsfenster öffnet sich beim nächsten Start.

### Abweichungen zum Frontend-Client (`dashboard/src/lib/api.ts`, WP7 passt an)

| Frontend heute | Server (verbindlich) |
|---|---|
| `challenge_id` in Antwort und Request | `challengeId` |
| `csrf_token`, `minutes_left`, `created_at` | `csrfToken`, `minutesLeft`, `createdAt` |
| Zustand `setup_open` | `setupOpen`; zusätzlich neuer Zustand `setupClosed` (Dashboard neu starten) |
| Antwort von `setup/finish`, `login/finish`: nichts | 204 plus `Set-Cookie`; danach `GET session` aufrufen |
| `BeginResponse.options` mit `excludeCredentials` (Setup) | entfällt (es gibt höchstens einen Passkey); `authenticatorSelection` ist zusätzlich vorhanden |
| Fehlertext `message` | Server liefert nur `{"error":"<code>"}`, der Client wählt den Text nach Status (409 `conflict`, 429 `rate_limited`, 401 `unauthorized`, 403 `forbidden`/`setup_closed`) |

---

# Vertrag Insights, Geräte, Aktionen (eingefroren 6. November 2026, WP-V)

Status: **eingefroren**. Änderungen nur additiv (neue optionale Felder, neue Aufzählungswerte, die Clients als „unbekannt“ darstellen müssen) oder mit Versionssprung in dieser Datei und in `docs/fixtures/`. Backend, Frontend-Mock und App-Tests nutzen dieselben Beispiele unter [`docs/fixtures/`](https://github.com/MagicalWig34653/weather-backend/tree/main/docs/fixtures) (Manifest `docs/fixtures/manifest.json` ordnet Methode, Pfad und Status der Datei zu). Alle Beispielwerte sind erfunden.

## Konventionen

- Alle Routen unter `/dash/api`, nur Dashboard-Listener, Sitzung erforderlich; schreibende Routen zusätzlich `Origin`, `Content-Type: application/json`, `X-CSRF-Token` (siehe oben). Antworten `Cache-Control: no-store`.
- Feldnamen camelCase. Zeitpunkte ISO 8601 UTC mit `Z` und Sekundengenauigkeit (`2026-11-06T09:15:00Z`). Zähler und Dauern sind ganze Zahlen ≥ 0 (`…Seconds`, `…Ms`), Anteile Dezimalzahlen 0 bis 1 (höchstens 4 Nachkommastellen), Bytes ganze Zahlen. **Unbekannt oder nicht erhoben ist immer `null`, nie `0`.** Eine fehlende Aufzählung gibt es nicht: Clients müssen unbekannte Aufzählungswerte tolerieren.
- **Keine IDs, Tokens, IPs, Koordinaten, Zellen, Installations- oder Abo-IDs, keine freien Zeichenketten aus Nutzerdaten** in Insights-Antworten. Replikat-IDs sind 8 Hexzeichen eines SHA-256 (kein Hostname). Die einzige Nutzereingabe in Antworten ist die Gerätebezeichnung (`label`, höchstens 40 Zeichen, vom Betreiber vergeben).
- Fehler: `{"error":"<code>"}`, kein Detail. Gemeinsame Codes: `validation` (400, Body/Query ungültig), `unauthorized` (401, keine Sitzung), `forbidden` (403, Host/Origin/CSRF), `not_found` (404), `conflict` (409), `rate_limited` (429 mit `Retry-After`), `data_unavailable` (503, Datenbank nicht erreichbar). Weitere Codes stehen je Route.
- Texte (Titel, Beschreibungen, Befundsätze) liefert **nicht** der Server: Er sendet Codes und Parameter, das Frontend formuliert Deutsch.
- Ratenlimit (im Speicher je Prozess): Insights-Routen und alle Lesezugriffe 600 pro Minute gesamt; Schreib- und Aktionsrouten wie unten je Route. Insights werden serverseitig 5 Sekunden gecacht, Zähler stammen aus dem Flush alle 60 Sekunden (Verzug bis 60 s; `generatedAt` nennt den Rechenzeitpunkt).

### Gemeinsame Typen

| Typ | Form |
|---|---|
| `Level` | `"ok"`, `"warning"`, `"critical"` oder `"unknown"` |
| `Series` | `{"resolution":"hour"\|"day","points":[{"t":"<ISO>","v":<Zahl>\|null}]}`, aufsteigend nach `t`; `t` ist der Beginn des Intervalls (UTC); Lücken stehen als `v: null` |
| `Bucket` | `{"key":"<Aufzählung>","count":<int>\|null,"suppressed":<bool>}`; `suppressed: true` ⇒ `count: null` (k-Schwelle) |
| `Gauge` | `{"used":<int>,"max":<int>,"ratio":<0..1>}` für Obergrenzen |

Abfrage-Parameter `range` (alle Insights-Routen außer `findings`): `24h` (Standard), `72h`, `7d`, `30d`; sonst `400 validation`. `24h` und `72h` liefern Stundenreihen (`resolution: "hour"`, aus `stats_hourly`, Aufbewahrung 72 h), `7d` und `30d` Tagesreihen (`resolution: "day"`, aus `stats_daily`, 30 Tage). Metriken ohne Stundenreihe liefern bei `24h`/`72h` Tagesreihen mit `resolution: "day"` je Serie; jede `Series` trägt ihre eigene `resolution`.

**k-Unterdrückung:** Jede Gruppe mit weniger als `DASH_MIN_GROUP` Einträgen (Standard 5, Grenzen 3 bis 50) wird als `{"count":null,"suppressed":true}` ausgegeben. Wird in einer Aufteilung genau ein Eintrag unterdrückt, wird zusätzlich der kleinste nicht unterdrückte Eintrag unterdrückt (Komplementärunterdrückung). Betrifft nur Verteilungen und Trichter-Aufteilungen nach Umgebung/Sprache sowie daraus abgeleitete Anteile (siehe unten), nicht Betriebszähler (Anfragen, Cache usw.). Die Trichter-Summen (`installations.total/active*`, `tokens.with*`, `subscriptions.*`) sind Betriebszähler im Sinn dieser Regel und bleiben exakte Ganzzahlen (Vertragstyp `int`); sie nennen nur Summen, keine Merkmale einer einzelnen Installation.

**Teilausfall:** Fällt ein Abschnitt aus (z. B. Gauge-Abfrage), antwortet die Route trotzdem `200`, der Abschnitt ist `null` und sein Schlüssel steht in `partial: ["cache"]`. `503 data_unavailable` nur, wenn gar nichts berechnet werden kann.

**Push deaktiviert** (`PUSH_ENABLED=false`): Push-Abschnitte sind `null`, `pushEnabled: false`; `GET insights/push` antwortet `200` mit `pushEnabled: false` und nur `prerequisites`.

## Insights

Alle `GET`, Sitzung, `?range=…` (außer `findings`).

### `GET /dash/api/insights/overview`

```
{ generatedAt, range, resolution,
  pushEnabled: bool, pushPaused: bool,
  status: { level: Level, findingCount: int },
  kpis: {
    requests:            Kpi,   // unit "count", Summe im Bereich
    cacheHitRatio:       Kpi,   // unit "ratio"
    ingestAgeSeconds:    Kpi,   // unit "seconds", ältester Ebenenstand der aktivierten Ebenen
    pushDeliveryRatio:   Kpi,   // unit "ratio", null bei Push aus
    activeLiveActivities: Kpi   // unit "count", Gauge, series null
  },
  notable: [ Finding ],         // höchstens 5, nach Schwere sortiert
  partial: [string] }
Kpi = { value: number|null, unit: "count"|"ratio"|"seconds", deltaPct: number|null, level: Level, series: Series|null }
```

`deltaPct` = Änderung gegenüber dem gleich langen Vorbereich (Prozent, eine Nachkommastelle), `null` ohne Vorbereich.

### `GET /dash/api/insights/findings`

Befunde aus den Schwellen (Regeln 2.6 des Plans). Keine Abfrageparameter.

```
{ generatedAt, level: Level, findings: [ Finding ] }
Finding = { code: string, level: "warning"|"critical", subject: string|null,
            value: number, threshold: number, unit: "ratio"|"seconds"|"count"|"percent", since: ISO|null }
```

`code` aus: `layer_stale` (`subject` = Ebenenkennung), `error_rate_5xx`, `outbox_age`, `apns_rejection`, `token_invalidation`, `replicas_missing`, `leader_missing`, `cache_hit_low`, `cap_fill` (`subject` = `installations`, `subscriptions`, `region_cells`, `activity_subscriptions`), `la_start_ratio_low`. `threshold` ist der überschrittene Wert (gelb oder rot, je nach `level`). Schwellen-Schlüssel im Register (Gruppe „Dashboard-Schwellen“, `apply: live`): `DASH_WARN_<REGEL>_YELLOW` und `DASH_WARN_<REGEL>_RED` mit `<REGEL>` = `LAYER_AGE_FACTOR` (Faktor des Takts, 2/4), `ERROR_RATE_5XX` (Anteil, 0,005/0,02), `OUTBOX_AGE_SECONDS` (120/600), `APNS_REJECTION` (0,05/0,25), `TOKEN_INVALIDATION` (0,05/0,20), `CACHE_HIT` (untere Grenze, 0,80/0,50), `CAP_FILL` (0,80/0,95), `LA_START_RATIO` (untere Grenze, 0,70/0,30); Startwerte wie im Plan, Kalibrierung nach zwei Wochen. `DASH_MIN_GROUP` wie oben. Fehlende Datenbasis (z. B. weniger als 10 Fälle bei `la_start_ratio_low`) erzeugt keinen Befund.

### `GET /dash/api/insights/ops`

```
{ generatedAt, range, resolution, partial: [string],
  layers: [ { id, enabled: bool, hasData: bool, latestRun: string|null, publishedAt: ISO|null,
              ageSeconds: int|null, cadenceSeconds: int, level: Level,
              runs: [ { slot: ISO, result: "ok"|"error"|"missed" } ],      // letzte 24 h, aufsteigend, höchstens 288
              lag: { p50Seconds: int|null, p95Seconds: int|null, series: Series|null } } ],
  errors: { status5xx: { series: Series, ratio1h: number|null, byRoute: [ { route, count } ] },
            ingestErrors: Series, statsDropped: int },
  cache: { hitRatio: number|null, hitRatioRadar: number|null, hitRatioLayer: number|null,
           negativeShare: number|null, joinedShare: number|null, dbReads: int, series: Series,
           fill: { bytes: int, maxBytes: int, entries: int, evictions: int, scope: "maxOfReplicas"|"thisReplica" }|null },
  latency: [ { route, buckets: [ { le: "10ms"|"50ms"|"200ms"|"1s"|"inf", count: int } ],
               p50Ms: int|null, p95Ms: int|null, p99Ms: int|null } ] | null,
  replicas: [ { id: "<8 hex>", startedAt: ISO, ageSeconds: int, appliedGeneration: int,
                revision: string|null, level: Level, isLeader: bool } ],
  generation: int,
  leader: { holder: "<8 hex>"|null, leaseSecondsLeft: int|null, changes24h: int|null },   // null: Leaderwechsel werden nicht gezählt
  db: { poolUsage: number|null, errors24h: int|null, migration: string|null } }
```

`id` der Ebene: `radar` und die Kennungen aus `LayerCatalog` (`pressure`, `pressure_eu`, `lightning`, `clouds`, `cloudmask`, `cloudmask_vis`, `cloudmask_vis_eu`). `route`: eine der festen Routengruppen (`healthz`, `status`, `radar_latest`, `radar_history`, `radar_image`, `layer_manifest`, `layer_image`, `push`, `landing`, `asset`, `site_page`, `dash_api`, `dash_static`, `other`; maßgeblich `StatsRoute.groups`). Perzentile sind aus Buckets geschätzt (Bucketgenauigkeit, die Obergrenze des Buckets). `latency` und `fill` sind `null`, solange WP11 die Zähler nicht liefert (Fähigkeit schaltet das Frontend auf „noch nicht erhoben“); ebenso `lag`, `db`. `cadenceSeconds`: 300 (Radar), je Ebene 600/900/3600 laut `step_minutes`.

### `GET /dash/api/insights/traffic`

```
{ generatedAt, range, resolution, partial: [string],
  requests: { total: int, series: Series, notModifiedShare: number|null,
              byRoute: [ { route, count: int, bytes: int } ],                 // nach count absteigend
              byStatusClass: [ { class: "2xx"|"3xx"|"4xx"|"5xx", count: int } ] },
  rateLimited: [ { kind: "push"|"dashboard"|"other", count: int } ],
  pageViews: [ { page: "landing_de"|"landing_en"|"privacy"|"marketing"|"support", count: int } ],
  hourly: { cells: [ { date: "YYYY-MM-DD", hour: 0..23, count: int } ] } | null }
```

`hourly` (Heatmap) nur aus vorhandenen Stundenzeilen (höchstens 72 Stunden); `null`, wenn `stats_hourly` leer ist. Wochentag leitet das Frontend aus `date` ab.

### `GET /dash/api/insights/push`

```
{ generatedAt, range, resolution, pushEnabled: bool, pushPaused: bool, partial: [string],
  prerequisites: [ { key: "push_enabled"|"apns_env_match"|"apns_topic_set"|"apns_key_present"|"capability_live_activity"|"push_not_paused",
                     ok: bool, detail: string|null } ],     // detail: feste Kennung, z. B. "sandbox_install_with_production_env"
  funnel: {
    installations: { total: int, active1d: int, active7d: int, active30d: int,
                     byEnv: [ Bucket ], byLocale: [ Bucket ] },            // key "sandbox"|"production", "de"|"en"
    tokens: { withDeviceToken: int, withStartToken: int,
              startTokenAge: [ Bucket ] },                                 // key "lt1d"|"lt7d"|"lt30d"|"older"
    subscriptions: { total: int, enabled: int, liveActivity: int, liveActivityWithStartToken: int, inconsistent: int }
  } | null,
  triggers: [ { trigger: "rain_start"|"raining_now"|"la_rain_start"|"la_raining_now", count: int } ] | null,
  skipped: [ { trigger: <wie oben>|"run", reason: "lock_60min"|"hysteresis"|"no_start_token"|"activity_slot_busy"|"reservation_pending"|"not_enabled"|"budget_exhausted"|"below_threshold"|"env_not_allowed"|"unknown_pixel"|"no_fresh_run"|"incomplete_run"|"paused", count: int } ] | null,
  lifecycle: { events: [ { event: "start"|"update"|"end"|"expire", outcome: "delivered"|"rejected"|"retry"|"dropped", count: int } ],
               activeNow: int, reservationsOpen: int, reservationsExpired: int } | null,
  locks: { activeLocks: int, activitySlots: Gauge } | null,
  apnsErrors: [ { kind: "alert"|"start"|"update"|"end", reason: <APNs-Reason>|"other", env: "sandbox"|"production", count: int } ] | null,
  delivery: { created: int, sent: int, delivered: int, rejected: int, dropped: int, retry: int, ratio: number|null, avgAttempts: number|null } | null,
  outbox: { waiting: int, oldestAgeSeconds: int|null, retrying: int, droppedOrExpired24h: int } | null,
  tokenInvalidations: [ { kind: "device"|"start"|"activity", cause: "410"|"bad_device_token"|"other", count: int } ] | null,
  timing: { apnsSendMs: [ { le, count } ], evalMsP95: int|null, cellsChecked: int|null, cellsMax: int } | null,
  registrations: { created: Series, deleted: Series, retained7dRatio: number|null } | null,
  rejects: [ { code: "server_full"|"activity_full"|"region_limit"|"subscription_limit"|"start_token_required"|"unauthorized", count: int } ] | null,
  caps: [ { key: "installations"|"subscriptions"|"region_cells"|"activity_subscriptions", gauge: Gauge } ] | null }
```

**Additive Erweiterung (WP11b/Integration, 6.11.2026):** `skipped[].trigger` ist zusätzlich `"run"` für Gründe, die den ganzen Auswertelauf betreffen (`no_fresh_run`, `incomplete_run`, `paused`); neue Gründe `env_not_allowed` (APNs-Umgebung der Installation nicht erlaubt), `unknown_pixel`, `no_fresh_run`, `incomplete_run`, `paused`. Clients zeigen unbekannte Werte als Rohtext. `lifecycle.events`, `apnsErrors` usw. stammen aus Zählern, `timing` und `registrations` bleiben `null`, bis dafür Zähler existieren; `delivery.rejected` enthält von APNs abgemeldete Geräte (`Unregistered`). `ops.layers[].runs` hat Stundenauflösung (ein Eintrag je Stunde mit Aufnahmeaktivität: `ok`, wenn mindestens ein Lauf gelang, sonst `error`/`missed`).

`<APNs-Reason>`: `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered`, `ExpiredProviderToken`, `InvalidProviderToken`, `MissingTopic`, `TopicDisallowed`, `PayloadTooLarge`, `TooManyRequests`, `InternalServerError`, `ServiceUnavailable`, `ExpiredToken` (Liste vor Umsetzung gegen die aktuelle Apple-Doku abzugleichen; alles andere `other`). Der Abschnitt `funnel` ist die Slice-1-Fassung (nur DB-Gauges) und steht vor WP11 zur Verfügung; die zählerbasierten Abschnitte (`triggers`, `skipped`, `lifecycle`, `apnsErrors`, `delivery`, `tokenInvalidations`, `timing`, `registrations`, `rejects`) sind `null`, solange WP11 nicht geliefert ist. `prerequisites[].detail` ist eine feste Kennung, nie ein Konfigurationswert.

### `GET /dash/api/insights/distribution`

```
{ generatedAt, minGroup: int, partial: [string],
  subscriptionsPerInstallation: [ Bucket ],   // key "0"|"1"|"2"|"3+"
  regionsPerInstallation: [ Bucket ],         // key "0"|"1"|"2"|"3"
  threshold: [ Bucket ],                      // key "1".."15" (Intensitätsklasse)
  lead: [ Bucket ],                           // key "10"|"20"|"30"
  locale: [ Bucket ], env: [ Bucket ],        // "de"|"en", "sandbox"|"production"
  timeSensitiveShare: number|null, liveActivityShare: number|null,
  caps: [ { key, gauge: Gauge } ] }
```

Keine Geografie. Anteile `null`, wenn die Grundmenge kleiner als `minGroup` ist oder der Teil bzw. der Rest (Grundmenge minus Teil) zwischen 1 und `minGroup - 1` liegt (sonst würde der Anteil eine Kleinstzahl verraten).

## Aktionen (global)

| Methode, Pfad | Body | Antwort | Limit | Audit |
|---|---|---|---|---|
| `PUT /dash/api/push/pause` | `{"paused":true\|false}` | `200 {"paused":bool,"since":ISO\|null}` | 6 pro Minute | `push_pause` |
| `POST /dash/api/cache/clear` | `{"layer":"all"\|"radar"\|"<Ebenen-ID>"}` | `202 {"generation":int,"layer":"…"}` | 2 pro Minute | `cache_clear` |

Fehler: `400 validation` (unbekannte `layer`), `429 rate_limited`. Pause: Auswertung läuft weiter, es wird nichts gesendet; Outbox bleibt bestehen und läuft nach 6 Stunden ab; `PUSH_PAUSED` erscheint nicht im Register (Zustand in der Datenbank). `cache/clear` erhöht `cache_generation`; Replikate leeren ihre `SlotCache` beim nächsten 30-s-Nachladen.

## Geräte

Vorbedingung: `DEVICE_LINK_ENABLED=true`. Ist der Schalter aus, antworten `GET devices` mit `200 {"linkEnabled":false,"max":3,"devices":[]}` und alle anderen Geräterouten mit `404 not_found` (`POST …/pair`: `409 link_disabled`). Gerätekennung `{id}` ist die zufällige Kopplungs-ID (UUID in Kleinschreibung), **nicht** die Installations-ID; kein Parameter nimmt Installations-ID, Token oder Zelle an; unbekannte IDs ergeben `404 not_found`.

Die Kopplung ist **dauerhaft** (Nutzerentscheidung 6.11.2026, ersetzt den früheren 14-Tage-Ablauf): sie endet nur durch Widerruf (App-Schalter, Dashboard, `DEVICE_LINK_ENABLED=false`, Löschen der Installation) oder, wenn der Betreiber es einstellt, durch `DASH_DEVICE_TTL_DAYS` (Standard `0` = kein Ablauf, Grenzen 0 bis 365). `DASH_DEVICE_STALE_DAYS` (Standard 14, 1 bis 365) steuert nur die Anzeige „zuletzt gesehen“ (`stale`); es wird nichts automatisch gelöscht.

### Typ `Device` (Listenkopf)

```
{ id, label: string, pairedAt: ISO, expiresAt: ISO|null, lastSeenAt: ISO|null, stale: bool,
  lastActionAt: ISO|null, env: "sandbox"|"production",
  summary: { level: Level, code: "ok"|"no_start_token"|"no_device_token"|"env_mismatch"|"no_live_activity_sub"|"unknown" } }
```

`lastSeenAt` = `last_seen_at` der Installation (letzter App-Kontakt), `stale` = Alter größer `DASH_DEVICE_STALE_DAYS`. `expiresAt` ist `null`, solange kein Ablauf konfiguriert ist.

### `GET /dash/api/devices`

`200 {"linkEnabled":bool,"max":int,"devices":[Device]}`. Rate: Lesen, 60 pro Minute.

### `POST /dash/api/devices/pair`

Body `{"code":"ABCD-EFGH","label":"Mein iPhone"}`. Code: 8 Zeichen Crockford-Base32 (`0-9A-Z` ohne `I L O U`), Groß-/Kleinschreibung, Bindestrich und Leerzeichen egal; `O`→`0`, `I`/`L`→`1` werden normalisiert. `label`: 1 bis 40 Zeichen nach Trimmen, keine Steuerzeichen. Sitzung + CSRF.

| Status | `error` | Bedeutung |
|---|---|---|
| `201` | – | Antwort: `Device` |
| `400` | `validation` | Code- oder Bezeichnungsformat ungültig |
| `404` | `code_unknown` | einheitlich für falsch, abgelaufen, verbraucht, nicht attestiert |
| `409` | `device_limit` | `DASH_MAX_DEVICES` (Standard 3, 1 bis 5) erreicht |
| `409` | `link_disabled` | `DEVICE_LINK_ENABLED=false` |
| `429` | `rate_limited` | 5 Fehlversuche pro Minute global (nur Fehlversuche zählen), `Retry-After` |

Audit `device_pair`. Der Code wird einmalig verbraucht; die Zeile in `push_link_code` muss mit `attested=1` angelegt sein (Serverprüfung der AppTransaction, siehe App-API).

### `GET /dash/api/devices/{id}`

```
{ device: Device,
  installation: { env, locale: "de"|"en", ageDays: int, lastSeenAt: ISO|null,
                  deviceToken: { present: bool, ageDays: int|null },
                  startToken:  { present: bool, ageDays: int|null } },
  subscriptions: [ { index: int,                      // 0-basiert, nach Anlegezeit, nur zur Zuordnung in Antworten
                     kind: "point"|"circle", enabled: bool, liveActivity: bool,
                     thresholdClass: 1..15, leadMinutes: 10|20|30, timeSensitive: bool,
                     lockUntil: ISO|null, hysteresis: bool } ],
  activity: { state: "none"|"reserved"|"active", startedAt: ISO|null, endsAt: ISO|null, tokenPresent: bool },
  reservation: { open: bool, ageSeconds: int|null } }
```

Keine Zellen, keine Koordinaten, keine Tokens, keine Abo-IDs. `lockUntil`: Ende der 60-Minuten-Sperre, `null` wenn frei. `ageDays` ganze Tage (abgerundet).

### `GET /dash/api/devices/{id}/diagnosis`

```
{ generatedAt, verdict: { code: <check-code>, level: Level }|null,
  checks: [ { order: 1..9, code: "server"|"environment"|"device_token"|"start_token"|"subscription"|"slot"|"lock"|"trigger"|"last_result",
              level: Level, reason: string, params: { <name>: string|number|bool|null } } ] }
```

Immer neun Prüfungen in fester Reihenfolge (`order`). `verdict` = erste Prüfung mit `critical`, sonst erste mit `warning`, sonst `null` (alles in Ordnung). `reason`: feste Kennung je Prüfung: `server`: `ok`, `push_disabled`, `capability_missing`, `push_paused`; `environment`: `ok`, `env_not_allowed`; `device_token`: `ok`, `missing`, `old`, `invalidated_recently`; `start_token`: `ok`, `missing`, `old`; `subscription`: `ok`, `no_subscription`, `disabled`, `live_activity_off`; `slot`: `ok`, `reservation_open`, `activity_running`; `lock`: `ok`, `lock_active`, `hysteresis`; `trigger`: `would_trigger`, `below_threshold`, `no_slot`, `stale_run`; `last_result`: `none`, `delivered`, `rejected`, `unregistered`, `retry`, `dropped`. `params` (feste Schlüssel, z. B. `ageDays`, `lockUntil`, `apnsReason`, `thresholdClass`, `currentMaxClass`) enthalten keine Tokens oder Zellen.

### `GET /dash/api/devices/{id}/events?limit=`

`limit` 1 bis 200 (Standard 50). `200 {"events":[{"at":ISO,"kind":"alert"|"la_start"|"la_update"|"la_end"|"test"|"probe"|"token","outcome":"delivered"|"rejected"|"retry"|"dropped"|"skipped","reason":string|null}]}`, neueste zuerst; `reason` ist ein APNs-Reason (siehe oben) oder ein Überspringgrund. Aufbewahrung 48 Stunden, höchstens 200 Zeilen je Gerät; nur für gekoppelte Geräte geschrieben.

### Aktionen und Befehlstabelle

`POST /dash/api/devices/{id}/actions/{action}` mit `action` ∈ `test`, `la-probe`, `la-end`, `reeval`, `reset-slot`. Body `{}`; `reeval` nimmt `{"dryRun":true|false}` (Standard `true`). Das Dashboard-Prozess sendet selbst nichts (Entscheidung D6): Die Aktion schreibt einen Auftrag in `dashboard_command`; der Leader der `radar`-Replikate fragt die Tabelle alle 2 Sekunden ab, führt aus und schreibt das Ergebnis. Antwort `202`:

```
{ "commandId": "<uuid>", "kind": "test"|"la_probe"|"la_end"|"reeval"|"reset_slot", "status": "queued", "createdAt": ISO }
```

Ergebnis per `GET /dash/api/devices/{id}/commands/{commandId}` (Polling 1 bis 2 s, höchstens 2 Minuten):

```
{ commandId, kind, status: "queued"|"running"|"done"|"failed"|"expired",
  createdAt, startedAt: ISO|null, finishedAt: ISO|null, dryRun: bool|null,
  result: <je kind>|null, error: "<code>"|null }
```

`GET /dash/api/devices/{id}/commands?limit=` (1 bis 20, Standard 10) liefert `{"commands":[…gleiche Form…]}`, neueste zuerst. Unbearbeitete Aufträge werden nach 120 Sekunden `expired`. Aufbewahrung 48 Stunden, höchstens 50 je Gerät, Löschen mit der Kopplung.

Ergebnisformen (`result`, nur bei `status: "done"`):

| `kind` | `result` |
|---|---|
| `test` | `{"outcome":"delivered"\|"rejected"\|"retry"\|"dropped","apnsStatus":int\|null,"reason":<APNs-Reason>\|null}` |
| `la_probe` | wie `test`, zusätzlich `"skipped":null\|"no_start_token"\|"activity_slot_busy"\|"reservation_pending"` (dann `outcome: "dropped"`, kein Versand) |
| `la_end` | `{"outcome":…,"hadActivity":bool,"reservationCleared":bool}` |
| `reeval` | `{"dryRun":bool,"subscriptions":[{"index":int,"decision":"would_trigger"\|"below_threshold"\|"lock"\|"hysteresis"\|"not_enabled"\|"no_start_token"\|"activity_slot_busy"\|"reservation_pending","sent":bool\|null}]}` (`sent` nur bei `dryRun: false`) |
| `reset_slot` | `{"cleared":"none"\|"reservation"\|"activity"}` |

`error` bei `status: "failed"`: `apns_unavailable`, `environment_not_allowed`, `device_gone` (Installation inzwischen gelöscht), `internal`. Die Pfade verwenden dieselben Dienste wie der normale Betrieb (echter Startpfad, Payload-Vertrag P8); die Probe ignoriert 60-Minuten-Sperre und Hysterese, **nicht** den Platz-/Token-Check, und sendet den Alert-Text `Live-Activity-Test` (`en`: `Live Activity test`). Neuauswertung mit Versand (`dryRun: false`) berücksichtigt Sperren wie ein Tick.

| Aktion | Limit je Gerät | Fehler bei Überschreitung |
|---|---|---|
| `test` | 3 pro Stunde | `429 action_rate_limited` mit `Retry-After` |
| `la-probe` | 3 pro Stunde | wie oben |
| `la-end` | 6 pro Stunde | wie oben |
| `reeval` (`dryRun: true`) | 20 pro Stunde | wie oben |
| `reeval` (`dryRun: false`) | 3 pro Stunde | wie oben |
| `reset-slot` | 6 pro Stunde | wie oben |

Weitere Fehler: `400 validation` (unbekannte Aktion, falscher Typ von `dryRun`), `404 not_found`, `409 command_pending` (für dieselbe Art läuft bereits ein Auftrag dieses Geräts), `409 link_disabled`. Jede Aktion erzeugt einen Audit-Eintrag `device_action` und einen Ereigniseintrag.

Tabelle `dashboard_command` (Migration 011 oder 012): `id CHAR(36) PK`, `device_id CHAR(36)` (FK `dashboard_device`, `ON DELETE CASCADE`), `kind VARCHAR(16)`, `dry_run TINYINT NULL`, `status VARCHAR(8)`, `created_at`, `started_at NULL`, `finished_at NULL`, `result JSON NULL` (nur die festen Felder oben), `error VARCHAR(32) NULL`. Index `(status, created_at)` für den Leader.

### `DELETE /dash/api/devices/{id}`

`204`; löscht Kopplung, Ereignisse, Befehle und einen offenen Code. Idempotent (`204` auch, wenn schon gelöscht, solange die ID syntaktisch eine UUID ist; sonst `404 not_found`). Audit `device_unpair`.

## Konfiguration, Neustart, Protokoll (Verweis auf WP5, hier für Frontend-Mock festgehalten)

| Methode, Pfad | Antwort |
|---|---|
| `GET /dash/api/config` | `{"revision":int,"entries":[ConfigEntry]}`, `ConfigEntry` = `{key, group, type:"bool"\|"int"\|"double"\|"string"\|"enum"\|"list", default, min, max, unit, description, apply:"live"\|"restart", source:"env"\|"dashboard"\|"default", locked:bool, value, restartPending:bool}`; Geheimnisse und ENV-only-Schlüssel mit `value: null` |
| `PUT /dash/api/config/{key}` | Body `{"value":…}` → `200 {"entry":ConfigEntry}`; Fehler `400 validation`, `404 not_found`, `409 locked_by_env` |
| `DELETE /dash/api/config/{key}` | `200 {"entry":ConfigEntry}` (zurück auf Default), Fehler wie `PUT` |
| `GET /dash/api/config/audit?limit=&action=` | `{"entries":[AuditEntry]}`, `limit` 1 bis 200 (Standard 50), `action` optional (eine der Aktionen unten) |
| `GET /dash/api/restart` | `{"generation":int,"pending":["KEY"],"replicas":[{"id":"<8 hex>","appliedGeneration":int,"startedAt":ISO,"state":"current"\|"waiting"}]}` |
| `POST /dash/api/restart` | Body `{}` → `202 {"generation":int}`, Limit 2 pro Minute und 6 pro Stunde |

`AuditEntry` = `{id:int, at:ISO, action:"set"|"reset"|"restart"|"login"|"setup"|"reset_cli"|"device_pair"|"device_unpair"|"device_action"|"push_pause"|"cache_clear", configKey:string|null, oldValue:string|null, newValue:string|null, deviceRef:string|null, outcome:string|null}`. `deviceRef` sind die ersten 8 Hexzeichen von `SHA-256(Kopplungs-ID)`; `outcome` bei `device_action` z. B. `test:delivered`. Aufbewahrung 365 Tage.

## Zusammenfassung Fehlercodes dieses Vertrags

`validation` 400; `unauthorized` 401; `forbidden` 403; `not_found` 404; `code_unknown` 404; `conflict` 409; `device_limit` 409; `link_disabled` 409; `command_pending` 409; `locked_by_env` 409; `rate_limited` 429; `action_rate_limited` 429; `data_unavailable` 503.
