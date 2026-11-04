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
