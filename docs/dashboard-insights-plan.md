# Dashboard-Ausbau: tiefe Insights, Aktionen, Geräte-Kopplung, Design

Stand: 6. November 2026. Status: **Entscheidungen D1 bis D14 angenommen (6.11.2026, mit zwei Änderungen: D3 dauerhafte Kopplung, Design nach dem Projekt `timetrack-pwa`); API-Verträge eingefroren (WP-V, Abschnitt 11); nichts gebaut.** Ergänzt [dashboard-plan.md](dashboard-plan.md) (WP1 bis WP9: Grundgerüst, Auth, Statistik-Zähler, Konfiguration, Neustart). Board: Todolino-Aufgabe „Dashboard-Insights und Geräte-Kopplung: Plan“. Neue Pakete heißen WP10 bis WP18 und setzen WP1 bis WP9 voraus oder erweitern sie (Abschnitt 7).

**Verträge:** [api.md](../docs-site/content/api.md) (App ↔ Backend, Abschnitt „Betreiber-Diagnose“), [dashboard-api.md](../docs-site/content/dashboard-api.md) (Dashboard ↔ Backend, ab „Vertrag Insights, Geräte, Aktionen“), Beispiele in [docs/fixtures/](fixtures/manifest.json). Wo dieser Plan und die Vertragsdateien voneinander abweichen, gilt der Vertrag.

Nutzerwunsch (6.11.2026): richtig tiefe Insights und alle sinnvollen Funktionen im gesunden Rahmen, wirklich schönes und hochwertiges Aussehen; dazu ein freiwilliges Opt-in in der App, mit dem der Betreiber sein eigenes Gerät im Dashboard zuordnen und manuell Dinge auslösen kann (Testpush, Live-Activity-Start/-Ende, Neuauswertung, Zustand der Registrierung); eventuell an TestFlight gekoppelt. Anlass: Live Activity startet trotz Aktivierung nicht, es fehlt Sichtbarkeit.

Unterscheidung: **BESTÄTIGT** = im Repo gelesen; **ANNAHME/HYPOTHESE** = nicht belegt, Prüfpunkt benannt.

## 1. Ausgangslage (BESTÄTIGT, Code gelesen)

- Zähler heute (`StatsCollector.labelRules`): `requests`, `bytes_out`, `errors_5xx`, `cache_hit`/`cache_miss` (radar/layer × memory/negative/joined/db), `ingest_run` (ok/error/missed), `push_sent` (nur `delivered`), `push_failed` (unregistered/rejected/retry/dropped), `rate_limited` (push/dashboard/other), `page_view`, `stats_dropped`. Tagesauflösung, 30 Tage, Flush alle 60 s.
- Nicht gemessen: Latenz, Verzögerung der Ebenen gegenüber dem DWD-Lauf, APNs-Fehler nach Grund (nur `reason` im Log-Pfad `Apns.swift`), Auslöser, Live-Activity-Start/Update/Ende, Überspringgründe (Sperre, Hysterese, belegter Platz), Token-Invalidierungen nach Tokenart, Outbox-Alter.
- Bereits in der DB als Gauge lesbar: `push_install` (inkl. `la_start_token`, `env`, `locale`, `last_seen_at`, `token_updated_at`), `push_sub` (`live_activity`, `enabled`, `state`, `last_sent_at`), `push_activity` (`started_at`, `ends_at`, Token), `push_outbox` (Status, Versuche, `next_attempt_at`), `push_state` (Leader-Lease über `acquireLeader`), `config_replica`.
- App meldet bei `PUT /v1/push/installations/<uuid>` `env`: `sandbox` (Debug) oder `production` (TestFlight und App Store). Das Backend kann TestFlight daher **nicht** von App Store unterscheiden (Abschnitt 4.6).
- Dashboard-Frontend (WP6) hat Gerüst, Mock-Modus, Seiten Übersicht/Traffic/Konfiguration/Protokoll als einfache Fassung, Komponenten `stat-card`, `bar-chart`, `config-row`; WP7 (Seiten) ist noch nicht begonnen.

**Sofort-Slice für die Live-Activity-Diagnose (Empfehlung):** Ein Großteil der Frage „warum startet sie nicht“ ist aus DB-Zuständen beantwortbar, ohne neue Zähler (Start-Token vorhanden? `live_activity=1`? Platz belegt? Sperre? Umgebung passt zu `APNS_ENV`?). WP12-Slice „Push-Gauges“ und WP13-Slice „Diagnose“ sollen deshalb vor dem Rest des Ausbaus liefern (Abschnitt 7, Welle A).

## 2. Insight-Katalog

Priorität: **M** = Muss (Kern, ohne den das Dashboard wenig nützt oder die Live-Activity-Frage offen bleibt), **S** = Soll, **K** = Kann (später, nur bei Bedarf). Spalte „Quelle“: `G` = Gauge aus DB bei Abruf (5 s gecacht), `Z` = Zähler, `Z+` = neuer Zähler, `H` = neue Stundenreihe (Entscheidung D1), `D` = abgeleitet.

Datenschutz-Regel für alles: nur Zähler, Gauges und feste Etiketten (Aufzählungen). Keine IPs, Koordinaten, Zellen, Installations-/Abo-IDs, Tokens, keine freien Zeichenketten. Kleine Gruppen werden unterdrückt (`<5`, siehe 2.5).

### 2.1 Betrieb und Gesundheit

| Insight | Darstellung | Prio | Quelle |
|---|---|---|---|
| Gesamtstatus „Befunde“ (grün/gelb/rot mit Begründung, aus Schwellen 2.6) | Statuskopf der Übersicht | M | D |
| Ingest je Ebene: letzter erfolgreicher Lauf, Alter, Ergebnis (ok/error/missed) der letzten 24 h | Streifen mit einer Zelle je Lauf (Heat-Strip) je Ebene plus Alterszahl | M | `ingest_run` H, G (jüngster Slot) |
| Verzögerung (Slot-Zeit bis Veröffentlichung) je Ebene, Median und P95 | Linie 24 h/7 d, aktueller Wert in Kachel | M | Z+ H (Bucket-Etiketten, 2.7), alternativ G aus Manifest |
| Fehler: 5xx-Rate je Routenklasse, Ingest-Fehler, `stats_dropped` | gestapelte Balken + Kachel | M | `errors_5xx`, `ingest_run` |
| Cache: Trefferquote (gesamt, radar, layer), Anteil Negativ-Treffer und Single-Flight, DB-Reads | Linie + Aufteilung als Balken | M | `cache_hit/miss` |
| Cache-Füllstand (Bytes/Einträge vs. `CACHE_MAX_MB`), Verdrängungen | Kachel + Balken | S | Z+ (Gauge-Provider im Prozess; je Replikat, nicht aggregierbar: Summe/Max anzeigen) |
| Latenz je Routenklasse (P50/P95/P99 aus Bucket-Zählern) | Linie, Histogramm | S | Z+ H |
| Replikate: Anzahl, Start-Alter, `applied_generation`, Version/`BUILD_REVISION` | Tabelle mit Statuspunkt | M | G (`config_replica`) |
| Leader: Inhaber (Hash, kein Hostname), Lease-Restzeit, Leader-Wechsel (24 h) | Kachel | M | G (`push_state`), Z+ (`leader_change`) |
| DB: Pool-Auslastung, Fehlerzähler, Migrationsstand | Kachel | S | Z+ |
| Speicher/Datenmenge: Zeilen je Tabelle (Größenordnung), Alter der ältesten Retention | Tabelle | K | G |
| Disk/CPU/RAM des Hosts | – | – | **nein** (außerhalb des Prozesses, wäre ein Monitoring-Ersatz; Nicht-Ziel bleibt) |

### 2.2 Traffic

| Insight | Darstellung | Prio | Quelle |
|---|---|---|---|
| Anfragen und Bytes je Tag und Routenklasse, Statusklassen, 304-Anteil | gestapelte Fläche + Tabelle | M | Z |
| Stundenverlauf heute und 7 Tage (Tagesmuster, Spitzen) | Fläche, Heatmap Stunde × Wochentag | S | H |
| Rate-Limit-Treffer (push/dashboard/other) | Balken | M | Z |
| Seitenaufrufe öffentlicher Seiten (Landing, Datenschutz, Support) | Balken | S | Z |
| Bandbreitenersparnis durch 304/ETag | Kachel (D aus 304 × mittlerer Bytegröße) | K | D |
| Top-Routen als Rangliste | horizontale Balken | S | Z |

### 2.3 Push und Live-Activity-Pipeline

Zentrale Seite für den Anlass. Als **Trichter** (Funnel) von oben nach unten, jede Stufe mit Zahl, Anteil an der Vorstufe und Alter des Zustands:

1. Installationen gesamt, aktiv (gesehen 1/7/30 d), je Umgebung (`sandbox`/`production`) und Sprache. **M**, G.
2. Installationen mit Gerätetoken; **mit Live-Activity-Start-Token**; Alter des Start-Tokens (Verteilung < 1 d, < 7 d, < 30 d, älter). **M**, G.
3. Abos gesamt, aktiv, **mit `live_activity=1`**, davon mit Start-Token (müssten alle sein, `409 start_token_required`; Differenz = Inkonsistenz). **M**, G.
4. Auslöser (Auswerteläufe, in denen ein Abo auslöste): Alert Regenbeginn, Live-Activity-Start „Regenbeginn“, „Es regnet gerade“. **M**, Z+ `push_trigger{rain_start, raining_now, la_rain_start, la_raining_now}`.
5. **Überspringgründe** je Auslöser: `lock_60min`, `hysteresis`, `no_start_token`, `activity_slot_busy`, `reservation_pending`, `not_enabled`, `budget_exhausted` (8-s-Budget), `below_threshold`. Das ist der Schlüssel zur Frage „startet nicht“. **M**, Z+ `push_skipped{reason}` (feste Liste; `below_threshold` nur als Summe je Lauf, nicht je Abo, sonst Zählerflut).
6. Live-Activity-Lebenszyklus: Starts gesendet/zugestellt/abgelehnt, Updates, Enden, Acht-Stunden-Enden, aktive Activities jetzt (G `push_activity` mit `ends_at > now`), Reservierungen offen und abgelaufen (15 min). **M**, Z+ `la_event{start,update,end,expire}×{delivered,rejected,retry,dropped}`, G.
7. Sperren: aktive 60-Minuten-Sperren (G aus `push_sub.last_sent_at`/State), Aktivitätsplätze belegt (Anzahl vs. `PUSH_MAX_ACTIVITY_SUBSCRIPTIONS`). **S**, G.
8. **APNs-Fehler nach Grund** (feste Liste bekannter Apple-Gründe + `other`): `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered`, `ExpiredProviderToken`, `InvalidProviderToken`, `MissingTopic`, `TopicDisallowed`, `PayloadTooLarge`, `TooManyRequests`, `InternalServerError`, `ServiceUnavailable`, `ExpiredToken` (Gründe laut Apple-Doku zur Antwort der Push-Dienste; Liste vor Umsetzung gegen die aktuelle Apple-Seite abgleichen, ANNAHME). Je Art: Alert/Start/Update/Ende, je Umgebung. **M**, Z+ `apns_error{kind,reason,env}` (Etikettenraum klein halten: kind×reason, Umgebung als eigene Metrik).
9. **Versandbilanz**: erzeugt (Outbox) → gesendet → zugestellt (APNs 200) → abgelehnt/verworfen/Wiederholung; Quote und Ø Versuche. **M**, `push_sent`/`push_failed` (erweitert um `kind`).
10. Outbox: wartend, ältester Eintrag (Alter), Wiederholungen, verworfen/abgelaufen. **M**, G.
11. **Token-Invalidierungen** nach Art (Gerätetoken, Start-Token, Activity-Token) und Ursache (`410`, `BadDeviceToken`). Steigende Raten sind ein Frühindikator für Umgebungs-/Key-Fehler. **M**, Z+ `token_invalidated{device,start,activity}`.
12. Sendedauer APNs (Latenz Bucket), Budgetnutzung je Tick, Auswertedauer je Lauf und geprüfte Zellen vs. `PUSH_MAX_REGION_CELLS`. **S**, Z+ H.
13. Registrierungsrate (neu/Tag), Löschungen/Abgänge, Verbleib (Anteil mit `last_seen` < 7 d). **S**, G + Z+ (`install_created`, `install_deleted`).
14. Ablehnungen der Registrierung: `server_full`, `activity_full`, `region_limit`, `subscription_limit`, `start_token_required`, `401` (Fehlauth). **S**, Z+ `push_api_reject{code}`.

### 2.4 Zustandsfenster „Konfiguration wirkt“

Auf der Push-Seite zeigt eine Prüfliste die Server-Voraussetzungen (nur Zustand, keine Werte geheimer Felder): `PUSH_ENABLED`, `APNS_ENV` vs. Umgebungen der Installationen (Mismatch-Zähler: Installationen, deren `env` nicht erlaubt ist), `APNS_TOPIC` gesetzt, Key vorhanden (nur ja/nein), Capability `live_activity` aktiv, Obergrenzen mit Füllgrad. **M**, G/D.

### 2.5 Regionen und Abos: nur aggregiert

- Verteilungen ohne Geografie: Abos je Installation (0/1/2/3+), Regionen je Installation, Schwellen-Verteilung (Intensitätsstufen), Vorlaufzeit-Verteilung, Sprache, Umgebung, Zeitkritisch-Anteil, Anteil mit Live Activity. **S**, G.
- Alle Gruppen mit weniger als 5 Einträgen erscheinen als „<5“ (k-Schwelle, Konfig `DASH_MIN_GROUP`, Default 5, nicht unter 3).
- Füllgrade der Obergrenzen (Installationen, Abos, Regionszellen, Activity-Abos). **M**, G.
- Geografische Verteilung (grobe Sektoren, k ≥ 10): **K**, nur nach ausdrücklicher Nutzerentscheidung D5; nie eine Karte mit Punkten, nie Zellen.

### 2.6 Warnungen und Schwellen (im Dashboard, kein externes Alerting)

Befunde werden bei Abruf aus Regeln berechnet (kein Hintergrunddienst, kein Versand). Schwellen liegen als Schlüssel `DASH_WARN_*` im Konfigurationsregister (live, mit Grenzen, Gruppe „Dashboard-Schwellen“). Vorschläge:

| Regel | Gelb | Rot |
|---|---|---|
| Ebene zu alt (Alter des jüngsten Slots) | > 2 × Takt | > 4 × Takt oder `missed` ≥ 3 in Folge |
| 5xx-Rate (1 h) | > 0,5 % | > 2 % |
| Outbox ältester Eintrag | > 2 min | > 10 min |
| APNs-Ablehnung (1 h, ohne `Unregistered`) | > 5 % | > 25 % oder `InvalidProviderToken`/`TopicDisallowed` > 0 |
| Token-Invalidierung (24 h) | > 5 % der aktiven | > 20 % |
| Replikate | < Soll | 0 oder kein Leader > Lease |
| Cache-Trefferquote (24 h) | < 80 % | < 50 % |
| Füllgrad Obergrenzen | > 80 % | > 95 % |
| Live-Activity-Start-Quote (Auslöser → Start zugestellt, 24 h, ≥ 10 Fälle) | < 70 % | < 30 % |

Alle Zahlen sind **Vorschläge** und werden in WP12 mit echten Daten kalibriert (ANNAHME). Optional (K, D8): Benachrichtigung des gekoppelten Betreibergeräts bei „rot“; nicht Teil der ersten Fassung.

### 2.7 Neue Zähler: Regeln

- Feste Etikettenmengen im `StatsCollector.labelRules` (unbekannt wird `other`), Obergrenze 10 000 Schlüssel bleibt.
- Latenz und Verzögerung als **Bucket-Zähler** (Etiketten z. B. `<10ms,<50ms,<200ms,<1s,>=1s`), keine Roh-Zeitstempel; P50/P95 werden aus Buckets geschätzt (Grenze: nur Bucketgenauigkeit, im UI vermerkt).
- Stundenreihen (D1): neue Tabelle `stats_hourly` (`hour DATETIME, metric, label, value`, PK dieselbe Form), Aufbewahrung 72 Stunden, nur ausgewählte Metriken (`requests`, `errors_5xx`, `ingest_run`, `ingest_lag`, `latency`, `push_*`, `la_event`, `apns_error`, `token_invalidated`); Flush schreibt Tages- und Stundenzeile in einer Transaktion.

## 3. Aktionen und Funktionen (Abgrenzung)

Grundsatz: Das Dashboard ist ein **Betreiber-Werkzeug mit kleiner, klar begrenzter Wirkung**. Jede Schreibaktion: Passkey-Sitzung + CSRF + Bestätigungsdialog (bei Wirkung auf Nutzer), Rate-Limit je Aktion, Audit-Eintrag, serverseitige Validierung. Keine Aktion nimmt eine beliebige Installation, Token oder Zelle als Eingabe (Ausnahme: gekoppelte Geräte, Abschnitt 4).

| Aktion | Wirkung | Prio | Schutz |
|---|---|---|---|
| Konfiguration ändern/zurücksetzen, Änderungsprotokoll | wie WP3/WP5 | M (existiert im Plan) | Register, Grenzen, Audit |
| Kontrollierter Neustart | wie Abschnitt 5.3 des Grundplans | M (existiert) | Staffelung, Mindestabstand |
| **Push pausieren/fortsetzen** (Schalter `PUSH_PAUSED`, live): Auswertung läuft, aber kein Versand; Outbox bleibt, läuft ab | Notbremse bei APNs-/Spam-Problem | S | Audit, Anzeige im Statuskopf, automatisches Ablaufen nur durch Betreiber |
| **Cache leeren** (SlotCache je Ebene, nur im Prozess; mehrere Replikate: über `config_revision`-artigen Zähler `cache_generation`) | erzwingt Neuladen aus DB | S | 2 pro Minute, Audit |
| **Ingest jetzt anstoßen** (eine Ebene, Leader führt aus, kein Parallellauf) | schneller Nachlauf nach Störung | K | nur Leader, Mindestabstand, respektiert DWD-Pausen (`LAYER_PAUSE_SECONDS`) |
| Outbox bereinigen (wartende ältere als N Minuten verwerfen) | nach Key-/Umgebungsfehler | K | Bestätigung mit Anzahl, Audit |
| Retention/Janitor sofort ausführen | Aufräumen | K | – |
| Export der Dashboard-Reihen als CSV (aggregiert, was sichtbar ist) | Offline-Auswertung | K | nur aggregierte Daten |
| **Gerätebezogene Aktionen** (Testpush, Live-Activity-Probe, Ende, Neuauswertung, Diagnose, Entkoppeln) | siehe 4.4 | M | nur für gekoppelte Geräte |
| Statistik zurücksetzen, Nutzer/Tokens löschen, beliebige SQL, Docker/Swarm, Secrets | – | **nein** | bewusst nicht vorgesehen |

## 4. Geräte-Opt-in („Mein Gerät im Dashboard“)

### 4.1 Ziel und Modell

Der Betreiber kann **sein eigenes** Gerät freiwillig mit dem Dashboard koppeln, um dessen Push-/Live-Activity-Zustand zu sehen und Aktionen dafür auszulösen. Gewählt: **Koppelcode** statt Identifikatoren. Die App zeigt auf Wunsch einen kurzlebigen Code; der Betreiber gibt ihn im Dashboard ein. Es wird kein Gerätename, keine Seriennummer, kein Hardwarekennzeichen und keine Installations-ID im Dashboard eingegeben oder angezeigt. Die Zuordnung `Code → Installation` löst der Server intern über die bestehende pseudonyme Installations-ID auf, die bereits für die Push-Registrierung gespeichert ist.

### 4.2 Ablauf

1. App (nur wenn Server-Capability `device_link` gemeldet **und** Build nachweislich TestFlight, 4.6; sonst existiert der Abschnitt nicht): Info-Sheet, Abschnitt „Betreiber-Diagnose“, Schalter „Dieses Gerät für die Diagnose bereitstellen“ (Standard aus). Beim Einschalten ruft die App `POST /v1/push/installations/<id>/link-code` mit dem `AppTransaction`-JWS auf (Installations-Secret wie bei allen App-Aufrufen).
2. Server erzeugt einen 8-stelligen Code (Crockford-Base32, 32 Symbole `0-9A-Z` ohne `I L O U`, 40 Bit; Eingabe normalisiert `O`→`0`, `I`/`L`→`1`; Korrektur 6.11.2026: der frühere Zusatz „ohne 0/1“ ergäbe nur 28 Symbole und keine 40 Bit), speichert **nur den Hash**, gültig 10 Minuten, einmalig verwendbar, höchstens ein offener Code je Installation. Antwort: Code und Ablaufzeit. App zeigt den Code groß mit Restzeit und „Abbrechen“.
3. Betreiber (Dashboard, Seite „Geräte“, angemeldet per Passkey): „Gerät koppeln“, gibt Code und eine **eigene Bezeichnung** (frei wählbar, höchstens 40 Zeichen, z. B. „Mein iPhone“) ein: `POST /dash/api/devices/pair`. Der Server prüft Hash/Ablauf, markiert den Code als verbraucht und legt die Kopplung an.
4. App fragt kurz `GET /v1/push/installations/<id>/link` (Polling nur, solange der Code-Bildschirm offen ist, alle 3 s, höchstens 10 Minuten) und zeigt „Gekoppelt seit …“ (und „läuft ab am …“ nur, wenn der Betreiber serverseitig einen Ablauf eingestellt hat) mit „Trennen“.
5. Ab jetzt zeigt das Dashboard für dieses Gerät Diagnose und Aktionen (4.4).

### 4.3 Was gespeichert wird, wie lange, wie widerrufbar

| Tabelle (Migration `011_device_link.sql`) | Inhalt | Lebensdauer |
|---|---|---|
| `push_link_code` | `code_hash BINARY(32) PK`, `install_id` (FK, ON DELETE CASCADE), `expires_at`, `used_at NULL` | 10 Minuten; abgelaufene Zeilen beim Zugriff und stündlich gelöscht |
| `dashboard_device` | `id CHAR(36) PK` (zufällige Kopplungs-ID), `install_id` UNIQUE (FK, ON DELETE CASCADE), `label VARCHAR(40)`, `paired_at`, `expires_at NULL`, `last_action_at NULL` | **dauerhaft** (Entscheidung D3, 6.11.2026): bis zum Widerruf oder zur Löschung der Installation. Ablauf nur optional: `DASH_DEVICE_TTL_DAYS` (Standard `0` = aus, 0 bis 365); dann ist `expires_at` gesetzt und der Janitor löscht abgelaufene Kopplungen. Anzeige „zuletzt gesehen“ aus `push_install.last_seen_at`, `stale` ab `DASH_DEVICE_STALE_DAYS` (Standard 14) |
| `dashboard_command` (Befehlstabelle, D6) | `id`, `device_id` (FK, CASCADE), `kind`, `dry_run`, `status`, Zeitpunkte, `result` (nur feste Felder), `error`; Vertrag in dashboard-api.md | 48 Stunden, höchstens 50 je Gerät, Löschen mit der Kopplung |
| `dashboard_device_event` | `id BIGINT PK`, `device_id` (FK, ON DELETE CASCADE), `at`, `kind` (`alert`,`la_start`,`la_update`,`la_end`,`test`,`probe`,`token`), `outcome` (`delivered`,`rejected`,`retry`,`dropped`,`skipped`), `reason VARCHAR(64) NULL` (feste Gründe: APNs-Reason oder Überspringgrund) | 48 Stunden, höchstens 200 Zeilen je Gerät (ältere werden beim Einfügen gelöscht) |
| `config_audit` (bestehend, `action` erweitert um `device_pair`, `device_unpair`, `device_action`, `push_pause`, `cache_clear`) | Aktion, Geräte-Referenz = erste 8 Zeichen von `SHA-256(Kopplungs-ID)`, Ergebnis | 365 Tage wie die übrige Audit-Tabelle (Entscheidung D4 nennt 90 Tage als Alternative) |

**Nicht gespeichert und nie ausgegeben:** Gerätemodell, OS-Version, Gerätename, IP, User-Agent, Koordinaten, Zelle, Gerätetoken im Klartext (Dashboard zeigt nur „vorhanden“, Alter, Umgebung, Länge-Plausibilität), Start-/Activity-Token im Klartext, Installations-ID, Abo-IDs. Das Ereignisprotokoll wird **nur** für gekoppelte Geräte geschrieben (Prüfung `device exists` im Observer); für alle anderen bleibt es bei anonymen Zählern. Keine Debuglogs mit Gerätebezug; strukturierte Logs enthalten höchstens „Kopplung angelegt/gelöscht“ ohne IDs.

**Widerruf (jederzeit, drei Wege, wirkt serverseitig sofort):**
- App-Schalter aus oder „Trennen“: `DELETE /v1/push/installations/<id>/link` löscht Kopplung, offenen Code und alle Geräteereignisse.
- Dashboard „Trennen“: `DELETE /dash/api/devices/<id>` mit demselben Löschumfang.
- Automatisch: Löschen der Installation (CASCADE; auch durch die bestehende 60-Tage-Inaktivitätsfrist der Installation), `DEVICE_LINK_ENABLED=false` (Routen 404, Janitor löscht alle Kopplungen beim nächsten Lauf) und, **nur wenn der Betreiber es einstellt**, der Ablauf nach `DASH_DEVICE_TTL_DAYS`. Ohne diese Einstellung läuft eine Kopplung nie ab.

**Ehrliche Risikobewertung der dauerhaften Kopplung (D3):** (1) Ein weitergegebenes, verkauftes oder verliehenes Gerät bleibt gekoppelt, bis jemand widerruft; Gegenmaßnahmen: Anzeige „zuletzt gesehen“ und `stale`-Markierung im Dashboard (kein automatisches Löschen), „Trennen“ ist jederzeit im Dashboard möglich, die App-Löschung der Installation räumt auf. (2) Es gibt keine Inaktivitätsprüfung mit Löschung; `last_seen_at` ist nur eine Anzeige und kein Beweis der Nutzung. (3) Ereignisse bleiben dennoch auf 48 Stunden und 200 Zeilen begrenzt, es entsteht also kein dauerhaftes Verlaufsprotokoll. (4) Datenschutztext und Datenschutzfolgen sprechen von „bis zum Widerruf“, nicht von einer festen Frist. (5) Wer den Ablauf wünscht, stellt `DASH_DEVICE_TTL_DAYS` ein (Server-Konfiguration, kein Code).

**Begrenzungen:** standardmäßig höchstens 3 gekoppelte Geräte gleichzeitig (`DASH_MAX_DEVICES`, 1 bis 5); Code-Erzeugung höchstens 6 pro Stunde je Installation; Einlösen höchstens 5 Fehlversuche pro Minute global (Code-Raum 2^40, Gültigkeit 10 Minuten, daher nicht ratbar); Einlösen nur mit Passkey-Sitzung + CSRF. **Ein ausgespähter Code ist ohne Betreiber-Sitzung wertlos.**

### 4.4 Gerätebezogene Funktionen (Seite „Geräte“)

Nur für gekoppelte Geräte, alle mit Audit und Ratenlimit (je Gerät):

| Funktion | Verhalten | Limit | Prio |
|---|---|---|---|
| **Registrierungsstatus** | Installation: `env`, Sprache, Alter, `last_seen`; Gerätetoken vorhanden/Alter; Start-Token vorhanden/Alter; Abos (Anzahl, davon `live_activity`, aktiv, Schwelle/Vorlauf als Stufen, Region-Anzahl, **keine Zellen**); Activity-Zeile (Start, Ende, Token vorhanden); Reservierung; Sperre bis; Hysterese-Bit | beliebig lesen, 60/min | M |
| **Diagnose „Warum startet keine Live Activity?“** | Prüfliste mit Ampel je Bedingung, siehe 4.5 | – | M |
| **Testpush** | wie vorhandener `…/test`-Pfad, aber vom Dashboard ausgelöst, Ergebnis (APNs-Antwort) sofort angezeigt | 3 pro Stunde (wie `testLimit`) | M |
| **Live-Activity-Probe starten** | sendet über den **echten Startpfad** (Push-to-Start, echter ContentState des Abos) mit Startalert „Test“; ignoriert 60-min-Sperre und Hysterese, **nicht** den Platz/Token-Check; trennt „Pfad kaputt“ von „Auslösebedingung nicht erfüllt“ | 3 pro Stunde | M |
| **Live Activity beenden** | End-Event an Activity-Token (falls vorhanden) und Aufräumen der Reservierung | 6 pro Stunde | M |
| **Neu auswerten (Trockenlauf)** | wertet die Abos des Geräts gegen den aktuellen Radarslot aus und zeigt je Abo Entscheidung und Grund (`below_threshold`, `lock`, `hysteresis`, `would_trigger`), **ohne** Versand | 20 pro Stunde | M |
| Neu auswerten **mit Versand** | wie Tick, aber nur für dieses Gerät, echte Sperren gelten | 3 pro Stunde | S |
| Reservierung/Platz zurücksetzen | löscht hängende Reservierung/Activity-Zeile des Geräts (Fall: Platz dauerhaft „belegt“) | 6 pro Stunde | S |
| Ereignisverlauf (48 h) | letzte 200 Ereignisse mit Art/Ergebnis/Grund | – | M |
| Entkoppeln | 4.3 | – | M |
| Token erneut anfordern („App, melde dich neu“) | **nicht möglich** (APNs-Silent-Push würde neue Sendepfade erfordern); stattdessen Hinweis „App öffnen“ | – | nein |

Alle Aktionen laufen **serverseitig im Backend** über vorhandene Dienste (`PushService`/Apns-Sender); das Dashboard-Prozess braucht dafür Zugriff auf APNs-Sender und Radarslot-Lesezugriff. Wichtige Architekturfolge (**Prüfpunkt WP13**): Der Dienst `dashboard` ist ein eigener Swarm-Dienst (Grundplan 2.1) und hat heute weder APNs-Key noch Push-Secret. Empfehlung: Dashboard-Dienst bekommt in `stack.dashboard.yaml` das APNs-Secret **nur wenn** `PUSH_ENABLED=true` (gleiches externes Secret wie `radar`); sonst Alternative: Aktionen werden als Auftrag in eine kleine Tabelle `dashboard_command` (Gerät, Art, Status, Ergebnis) geschrieben, die der Leader der `radar`-Replikate abarbeitet (kein zusätzliches Secret im Dashboard, aber Verzug bis zum nächsten Poll, z. B. 2 s). Entscheidung D6.

### 4.5 Diagnose-Prüfliste (Live Activity startet nicht)

Reine Funktion `PushDiagnosis` (testbar ohne Netz): Eingabe Installation, Abos, Activity, Config-Snapshot, letzter Slot; Ausgabe geordnete Befunde mit Ampel und Klartext. Bedingungen in dieser Reihenfolge:

1. Server: `PUSH_ENABLED`, Capability `live_activity`, `PUSH_PAUSED` nicht gesetzt.
2. Umgebung: `env` der Installation durch `APNS_ENV` erlaubt (sonst Meldungen verworfen). Hinweis: TestFlight und App Store melden `production`, Debug `sandbox`; passt nicht zum Key → `BadDeviceToken` (siehe `docs`/App-Doku `apns-einrichtung`).
3. Gerätetoken vorhanden und jünger als Schwelle; letzter Token-Fehler (`token_invalidated`).
4. **Start-Token vorhanden** (`la_start_token`) und Alter; fehlt es, hat die App es nicht gemeldet (App-seitig: Berechtigung/Live Activities in iOS-Einstellungen aus, `pushToStartTokenUpdates` kommt nicht) – Server kann das nur feststellen, nicht beheben.
5. Abo: `enabled`, `live_activity=1`.
6. Platz: keine offene Reservierung (<15 min) und keine laufende Activity (`ends_at > now`).
7. Sperre: 60-Minuten-Sperre nicht aktiv; Hysterese-Bit.
8. Auslösebedingung: aktueller Slot gegenüber Schwelle und Vorlauf (zwei aufeinanderfolgende vollständige Läufe für „Es regnet gerade“).
9. Letztes Versandergebnis aus dem Ereignisverlauf: APNs-Reason im Klartext der Befundtexte (BadDeviceToken, TopicDisallowed usw.).

Ausgang: genau ein „wahrscheinlichster Grund“ plus Liste der übrigen Prüfungen. Das ist die Antwort auf „es fehlt Sichtbarkeit“ und braucht nur Lesezugriffe plus das Ereignisprotokoll.

### 4.6 TestFlight-Kopplung und Erkennung (harte Anforderung, Präzisierung 6.11.2026)

**Anforderung H1:** Das Geräte-Opt-in darf in App-Store-Installationen **weder sichtbar noch aktivierbar** sein; es erscheint nur, wenn die App nachweislich aus TestFlight stammt. Gilt zweifach: App-seitig (UI und Code-Pfad) **und** serverseitig (Backend lehnt die Kopplung ohne gültigen Umgebungsnachweis ab). Im Zweifel (offline, nicht verifizierbar, unbekannter Wert) gilt „kein TestFlight“ (fail closed).

**Belegte Befunde (Primärquelle: Apples Bibliothek `app-store-server-library-swift`, `main`, abgerufen 6.11.2026, Dateien `SignedDataVerifier.swift`, `Models/AppTransaction.swift`, `Models/AppStoreEnvironment.swift`):**
- Das signierte `AppTransaction`-JWS enthält ein Feld `receiptType`, dokumentiert als „server environment, production or sandbox, that signed the app transaction“; Werte `Sandbox`, `Production`, `Xcode`, `LocalTesting`.
- `SignedDataVerifier.verifyAndDecodeAppTransaction` prüft Zertifikatskette (Apple-Wurzelzertifikate, vom Betreiber der Prüfung bereitzustellen), `bundleId` und Umgebung (`INVALID_ENVIRONMENT`, `INVALID_APP_IDENTIFIER`); optional Online-Prüfung (`enableOnlineChecks`). Das Backend kann also die Umgebung **kryptografisch aus dem von der App gelieferten JWS prüfen**, ohne Apple-Server-Aufruf und ohne Konto-Zugang.
- Das JWS enthält zusätzlich `deviceVerification` und `deviceVerificationNonce` (Bindung an das Gerät; Berechnung laut Apple-Doku zu `AppTransaction.deviceVerification`, Details ANNAHME, nicht gelesen) und `appTransactionId` (konto-/app-bezogene ID: **nicht speichern**).

**Nicht belegt (Prüfpunkt, ANNAHME):** dass TestFlight-Installationen `Sandbox` melden und App-Store-Installationen `Production`. Das ist die verbreitete Aussage; die Apple-Doku-Seiten (`AppTransaction`, `AppTransaction.environment`, App Store Server API „Environment“) waren per Abrufwerkzeug nicht inhaltlich lesbar (dynamisch geladen). **Abnahme per Gerätetest (WP14-Spike):** TestFlight-Build liefert `Sandbox`, Xcode-Lauf `Xcode`; der App-Store-Fall `Production` ist erst mit der ersten Veröffentlichung messbar. Deshalb dort doppelt abgesichert (Testplan unten).

| Methode | Bewertung |
|---|---|
| **StoreKit 2 `AppTransaction.shared`** (iOS 16+; `environment`, `jwsRepresentation`) | **Empfehlung (Primärmethode):** liefert ein von Apple signiertes Objekt, dessen `receiptType` das Backend selbst prüft. Grenzen: braucht beim ersten Abruf eine Verbindung zum App Store; ohne Netz/Verifikation `unverified` → fail closed. `AppTransaction.refresh()` zeigt eine Anmeldeabfrage und wird **nicht** aufgerufen. `Sandbox` bedeutet „kein App-Store-Produktionskauf“ und ist nicht exklusiv TestFlight (auch Sandbox-Konten); `Xcode`/`LocalTesting` sind Entwicklungsläufe und gelten nur in Debug-Konfiguration als zulässig. Aktuelle Empfehlung unter iOS 27: **nicht geprüft** (Apple-Seiten nicht lesbar); bis zur Prüfung gilt iOS-16+-API, zusätzlich Release Notes zu StoreKit/iOS 27 im Spike lesen. |
| `Bundle.main.appStoreReceiptURL` mit Endung `sandboxReceipt` | Nur **Rückfall und Gegenprobe** (lokal, offline lesbar), nicht für die Serverseite: inoffiziell als TestFlight-Merkmal, StoreKit-1-Altlast (ANNAHME zur Einstufung als veraltet). **Fälschbar** (kein Nachweis; Jailbreak/Neuverpackung). Darf nie allein das Freischalten bewirken, kann aber verhindern, dass bei Widerspruch zum JWS etwas erscheint (beide müssen zustimmen: JWS `Sandbox` **und** `sandboxReceipt`, außer in Debug). |
| `env` der Push-Registrierung / `aps-environment` | TestFlight und App Store melden beide `production` (App-Repo `docs/apns-einrichtung.md`, dort selbst als ungeprüft vermerkt): **ungeeignet** |
| Eingebettetes Provisioning-Profil | TestFlight und App Store haben keines: **ungeeignet** |
| Info.plist-Kanal-Schlüssel | gleiche Binärdatei für TestFlight und App Store möglich: **ungeeignet** als Beleg |

**Grenzen und Fälschbarkeit (offen benannt):**
- Das Backend prüft Echtheit, Bundle-ID und Umgebung des JWS (Apple-Signatur). Ein Angreifer ohne gültiges Sandbox-JWS kann die Kopplung nicht erzeugen.
- Ein **wiedergegebenes** echtes Sandbox-JWS (anderes Gerät, manipulierte App) ist technisch möglich; Gegenmaßnahmen: JWS nur zusammen mit dem Koppelcode und nur über die authentifizierte Installations-Route, Alter `receiptCreationDate` ≤ 24 Stunden (ANNAHME zur Praktikabilität: das JWS wird von StoreKit gecacht; Spike prüft, ob das Feld bei jedem Abruf neu ist, sonst Fenster 7 Tage oder entfällt), Speicherung **nur des Prüfergebnisses** (Umgebung, Zeitpunkt), nie des JWS. Der entscheidende Schutz bleibt, dass die Kopplung **nur ein Passkey-Betreiber im Dashboard einlösen kann**; ein Fälscher gewänne ohne Betreiber nichts. Ein vollständig kompromittiertes Gerät/ein manipuliertes App-Binary kann die Client-Erkennung umgehen, **aber nicht die Serverprüfung**, sofern es kein echtes Sandbox-JWS besitzt.
- Jeder TestFlight-Tester (auch extern) kann die Kopplung anfordern, aber nur der Betreiber kann sie einlösen: Der Code gilt nur für die eigene Installation.
- Zusätzlich serverseitig `DEVICE_LINK_ENABLED` (Standard aus) und Capability `device_link`, die ein Betreiber im Dashboard abschaltet, sobald nicht mehr getestet wird.

**App-seitiges Gating (H1, WP14):**
1. Code-Pfad: Eine Komponente `BuildChannel` (injizierbar, Tests ohne StoreKit) liefert `.testFlight` nur, wenn `AppTransaction.shared` verifiziert ist **und** `environment == .sandbox` **und** `sandboxReceipt` passt; in Debug zusätzlich `.xcode`. Alles andere, einschließlich Fehler/Offline/Timeout (3 s), ergibt `.appStore`/`.unknown` = **nicht sichtbar**.
2. UI: Abschnitt „Betreiber-Diagnose“ wird nur bei `.testFlight` **und** Server-Capability `device_link` überhaupt in die View-Hierarchie eingefügt (kein verstecktes, kein ausgegrautes Element, kein Accessibility-Eintrag, kein Deep Link, kein Debug-Menü, keine Einstellung in `UserDefaults`).
3. Netzpfad: Die Routen werden nur aus dieser Komponente aufgerufen (kein Aufruf aus Hintergrund, Widget, Watch, Intent, URL-Schema). Der Schalter-Zustand wird bei jedem Start gegen `BuildChannel` geprüft; wechselt das Gerät von TestFlight zu App Store (Update), wird ein bestehender Link beim nächsten Start per `DELETE …/link` gelöscht und der Schalter entfernt.
4. Der Nachweis (`jwsRepresentation`) wird nur im Speicher gehalten und nur mit `link-code` gesendet.

**Serverseitiges Gegenstück (H1, WP13):** `POST …/link-code` verlangt im Body `app_transaction` (JWS). Das Backend verifiziert Signaturkette gegen im Repo gebündelte Apple-Wurzelzertifikate (öffentliche Zertifikate, Prüfsumme dokumentiert), `bundleId` gleich `APNS_TOPIC`-Basis (Konfiguration `DEVICE_LINK_BUNDLE_ID`), `receiptType == Sandbox` (Konfiguration `DEVICE_LINK_ALLOWED_ENVS`, Standard `Sandbox`; `Xcode` nur bei `APNS_ENV` sandbox/both erlaubbar), Zeitfenster, und lehnt sonst mit `403 not_testflight` ab (einheitlich, ohne Grund; Zähler `device_link_reject{reason}` mit festen Gründen `unverified|production|expired|bundle`). Verfahren: entweder Apples Swift-Bibliothek als exakt gepinnte Abhängigkeit (Lizenz/Abhängigkeitsgröße in WP13 prüfen) oder eigene Minimalprüfung (ES256, x5c-Kette, wie bei WebAuthn als Rückfall geplant). Entscheidung D14. Zusätzlich verlangt auch `POST /dash/api/devices/pair`, dass die zugehörige Code-Zeile mit `attested=1` angelegt wurde.

**Testplan H1:**
| Fall | Erwartung | Wie |
|---|---|---|
| App-Store-Build (Umgebung `Production`) | Abschnitt fehlt vollständig; kein Netzaufruf zu `link*`; Server antwortet auf manuell gesendetes Production-JWS `403 not_testflight` | Unit-Tests `BuildChannel` mit injizierten Antworten (production, unverified, offline, Timeout, `Xcode` in Release); UI-Test: View-Hierarchie enthält den Abschnitt nicht; Backend-Test mit selbstsigniertem Testketten-JWS (`Production`) |
| TestFlight-Build | Abschnitt sichtbar, Code erzeugbar, Kopplung möglich | Gerätetest (Spike und Abnahme WP18) |
| Xcode-Debug | sichtbar nur in Debug-Konfiguration | UI-Test/Gerät |
| Manipulierter Client sendet Production-/fremdes/abgelaufenes JWS | `403 not_testflight`, Zähler | Backend-Tests mit Fixtures (falsche Kette, falsche Bundle-ID, abgelaufen, verändertes Feld) |
| Update TestFlight → App Store | bestehender Link wird gelöscht, Abschnitt verschwindet | Test mit gespeichertem Zustand |
| Echter App-Store-Build | Abschnitt fehlt | **erst nach erster Veröffentlichung messbar**; bis dahin Fixture-Tests und Review der Logik; nach Veröffentlichung Stichprobe (App-Store-Installation zeigt keine Diagnose) als Abnahmepunkt in WP18 |

### 4.7 API-Entwurf

**Eingefroren 6.11.2026 (WP-V): maßgeblich sind api.md und dashboard-api.md; die folgenden Tabellen sind der ursprüngliche Entwurf.** Abweichungen: Capability `device_link` steht in `GET /v1/status` (nicht `/v1/push/capabilities`); zusätzliche Fehler `already_linked`, `invalid_request`, `413`; `GET …/link` liefert alle Felder immer; Aktionen laufen über `dashboard_command` (D6) mit Ergebnis-Polling.

App ↔ Backend (Auth wie übrige Push-Routen: Installations-ID + Secret; Rate-Limits wie dort; JSON; `404` bei `DEVICE_LINK_ENABLED=false`):

| Methode, Pfad | Zweck | Antworten |
|---|---|---|
| POST `/v1/push/installations/<id>/link-code` | Body `{"app_transaction":"<JWS>"}`; Code erzeugen (ersetzt einen offenen Code) | `201 {"code":"ABCD-EFGH","expires_at":"…"}`; `403 not_testflight` (Nachweis fehlt/ungültig/Production); `409 link_full`; `429` |
| GET `/v1/push/installations/<id>/link` | Zustand | `200 {"state":"none\|code_open\|linked","linked_at":"…","expires_at":"…","label_set":true}` (Bezeichnung nicht zurückgeben) |
| DELETE `/v1/push/installations/<id>/link` | Trennen und Code verwerfen | `204` (idempotent) |
| GET `/v1/status` | `capabilities` + `device_link` | bestehend, additiv |

Dashboard ↔ Backend (nur Dashboard-Listener, Sitzung + CSRF bei Schreibzugriff):

| Methode, Pfad | Zweck |
|---|---|
| GET `/dash/api/devices` | Liste gekoppelter Geräte (Bezeichnung, Alter, Ablauf, letzter Ereigniszeitpunkt, Kurzstatus) |
| POST `/dash/api/devices/pair` | `{code,label}` → `201`; `404 code_unknown` (einheitlich für falsch/abgelaufen/verbraucht); `409 device_limit` |
| GET `/dash/api/devices/{id}` | Registrierungsstatus (4.4) |
| GET `/dash/api/devices/{id}/diagnosis` | Diagnose-Prüfliste (4.5) |
| GET `/dash/api/devices/{id}/events` | Ereignisverlauf (48 h) |
| POST `/dash/api/devices/{id}/actions/{test\|la-probe\|la-end\|reeval\|reset-slot}` | `{dry_run?:bool}` → `202` mit Ergebnis oder Auftrags-ID (je nach D6) |
| DELETE `/dash/api/devices/{id}` | Entkoppeln |

Alle Fehler `{"error":"code"}`, kein Detail. Der Vertrag wird in `docs-site/content/dashboard-api.md` (Betreiberteil) und `api.md` (App-Teil) festgeschrieben, bevor WP14/WP16 beginnen.

### 4.8 Datenschutz-Auswirkungen

- **App-Datenschutztext (Info-Sheet)** und **Backend-Seite `/datenschutz` (`SitePages.swift`)**: neuer Absatz „Betreiber-Diagnose (freiwillig)“: standardmäßig aus; nur in Testversionen; Schalter; Code; Betreiber ordnet das Gerät einer eigenen Bezeichnung zu; gespeichert werden Zuordnung, Bezeichnung, Zeitpunkte und ein 48-Stunden-Verlauf technischer Versandergebnisse; Löschung durch Ausschalten in der App, Trennen im Dashboard oder Löschen der Registrierung (die Kopplung besteht dauerhaft bis zum Widerruf, ein Ablauf ist nur auf Betreiberwunsch eingestellt); keine Standortverlaufsdaten, keine Gerätekennzeichen. Texte DE/EN, in `SitePages`-Tests auf Inhalt/Escaping prüfen.
- **`docs-site/content/api.md`**, **`datenschutz`-Abschnitt in `docs-site/content/seiten.md`** und **`docs/pages.md`** (Hinweis auf neue veröffentlichte Aussage; keine Domains/IPs/Pfade) nachziehen.
- **Dashboard selbst** ist intern und nicht öffentlich dokumentiert, aber `docs-site/content/betrieb.md` beschreibt Aktivierung und Datenumfang.
- **App-Store-Datenschutzangaben (Privacy Nutrition Label)** und App-Repo-Doku: Prüfen, ob die bestehenden Angaben (pseudonyme Installations-ID, Push-Token) die Kopplung abdecken; wird in WP14 im App-Repo bewertet (nicht hier entschieden). Rechtsbewertung ist keine Rechtsberatung; Betreiber prüft.
- Rechtsgrundlage: Einwilligung (Schalter), Datenminimierung (kein Gerätebezug außer Pseudonym), Speicherbegrenzung (Ereignisse 48 h; Kopplung selbst dauerhaft bis zum Widerruf, Ablauf optional), Widerruf jederzeit und wirksam sofort.

## 5. Design-Leitlinien

Ziel: hochwertiges, ruhiges, dichtes aber lesbares Betreiber-Dashboard; eine Handschrift, kein Baukasten-Look. **Entscheidung 6.11.2026: Das Design orientiert sich an `timetrack-pwa` (Svelte 5 + shadcn-svelte, Tailwind 4); dessen Designsprache wird übernommen** (Quelle: `src/routes/layout.css`, `components.json`, `docs/STATUS.md` „Designsprache“, nur gelesen; die Doku `docs/DESIGN.md` und ADR-0014 liegen im dortigen Backend-Repo und wurden nicht gesichtet). Umsetzung als Designsystem in `dashboard/src/lib/design` (WP10) mit Beispiel-/Vorschauseite (nur Dev-Build, `/dash/_design`, nicht im Produktionsbuild).

**Übernommen aus `timetrack-pwa` (BESTÄTIGT, Dateien gelesen):**
- **Stack:** shadcn-svelte (Stil `nova`, `baseColor: neutral`, Icons `@lucide/svelte`), Tailwind 4 mit `@theme inline`, `tw-animate-css`, `tailwind-variants`, bits-ui-basierte Primitive; Aliasse `#lib/...`; Komponenten in `lib/components/{ui,app,shell,...}`.
- **Tokens:** Zinc-Grauskala in OKLCH als CSS-Variablen (`--background`, `--foreground`, `--card`, `--muted`, `--muted-foreground`, `--border`, `--ring`, `--destructive`, `--chart-1..5`, `--sidebar*`), hell und dunkel gleichberechtigt (`.dark`-Klasse, System-Voreinstellung plus Umschalter), `--radius: 0.625rem` mit abgeleiteten Radien, Schatten `--shadow-card`/`--shadow-pop`, Basisschrift 15 px mit Zeilenhöhe 1,6, `tabular-nums` für `time`/`.tabular`.
- **Akzentsystem:** ein Akzent über `--ui-accent`, `--ui-accent-foreground`, `--ui-accent-ink`, `--ui-accent-soft` (Standard `#2563EB`), zur Laufzeit überschreibbar; semantische Statusfarben nie allein, immer mit Icon und Text. Für das Dashboard genügt die Voreinstellung (keine Konto-Synchronisierung, Auswahl nur lokal oder fest).
- **Glas:** schwebende Flächen (Popover, Dialog, Toast, Seitenleiste, Kopfzeile) mit Blur über `--bf-*`/`--glass-*` und deckenden Rückfällen (reduzierte Transparenz, kein `backdrop-filter`); Daten selbst nie auf Glas, Text bleibt deckend. Leuchteffekt (`glow`) **nicht** übernommen (nicht nötig für ein Betreiberwerkzeug).
- **Schrift:** Inter Variable lokal gebündelt über `@fontsource-variable/inter` (`--font-sans`), Systemschrift als Rückfall; entspricht D11, `font-src 'self'` bleibt gültig.
- **Shell:** Seitenleiste 256 px, Kopfzeile 60 px, mobiles Off-Canvas-Menü, Befehlspalette/Einstellungssuche optional; Breakpoints `menu` 760 px und `wide` 1100 px.
- **Musterkomponenten (Namen übernehmen, Inhalt für das Dashboard):** `PageHeader`, `Panel`, `KpiCard`, `SectionHeading`, `EmptyState`, `FilterBar`, `StatusChip`, `Banner`, `Segmented`, `ConfirmDialog`, `Toast`, `Field`, `CopyButton`, `Dur`; UI-Primitive `button`, `card`, `badge`, `input`, `select`, `switch`, `checkbox`, `alert`, `label`, `textarea`.
- **Diagramme:** dort ein eigener SVG-`Chart.svelte` ohne Abhängigkeiten (Linie, gruppierte/gestapelte Balken, Tooltip bei Hover und Fokus mit Pfeiltasten, Textalternative als Tabelle) mit `niceTicks`/`labelIndexes` in `lib/stats/scale.ts`. Das bestätigt Entscheidung D7 (eigene SVG-Bausteine) und liefert das Muster für die Dashboard-Bausteine.

**Anpassungen für das Dashboard:** `components.json` des Dashboards zeigt auf `src/routes/layout.css` und `#lib`-Aliasse wie dort (WP10 legt es an bzw. gleicht es ab). Die weiter unten genannten Bausteine (Heat-Strip, Heatmap, Trichter, Histogramm, Sparkline) gibt es im Vorbild nicht und werden im selben Stil ergänzt. Der Akzent aus der App (Showers) wird **nicht** nachgebildet; es gilt das Vorbild (`#2563EB`), damit beide Betreiber-Oberflächen gleich wirken. Keine Konto-Einstellungen (Akzent je Konto, Transparenz) und keine i18n-Infrastruktur: Texte sind deutsch, aber in einer Textdatei gebündelt.

**Typografie und Zahlen (Ergänzung zum Vorbild).** Alle Zahlen `tabular-nums`, de-DE-Format, konsistente Einheiten (ms, MB, %), Kennzahlen 28 bis 36 px mit kleiner Einheit, Monospace-Systemstapel für Schlüssel/IDs. Dunkelmodus: Flächen nicht reines Schwarz (wie Vorbild), Diagrammfarben für Dunkel separat abgestimmt, nicht invertiert.

**Diagrammbausteine (eigene SVG-Bausteine, keine Chartbibliothek; D7 angenommen).** Gründe: CSP, Kontrolle über Stil und Barrierefreiheit, kleine Größe. Bausteine: Sparkline (in Kacheln), Linie/Fläche (Zeitreihe mit Stunden-/Tagesachse), gestapelte Balken (Status, Routen), horizontale Rangbalken, **Heat-Strip** (Ingest-Läufe), Heatmap Stunde × Wochentag (Traffic), Histogramm (Latenzbuckets), Trichter (Push-Pipeline). Regeln (Skill `dataviz` bei Umsetzung heranziehen): Direkte Beschriftung statt schwerer Legenden, wenige Rasterlinien, ruhige Achsen, Nullbasis bei Balken, ein Farbton je Bedeutung durchgängig, kein 3D, keine Tortendiagramme, Tooltips per Hover **und** Tastatur/Fokus, „Als Tabelle anzeigen“-Umschalter je Diagramm (Screenreader und Detail), `prefers-reduced-motion` respektiert (nur dezente Übergänge ≤ 150 ms), Farbpalette farbfehlsichtigkeits-verträglich (Prüfung per Simulation, nicht nur Auge).

**Kacheln und Dichte.** Kennzahl-Kachel: Titel, Wert, Delta/Trend (Pfeil + Text), Sparkline, Statuspunkt; Hinweis „Stand hh:mm:ss, Verzug bis 60 s“. Inhalte in Karten mit einheitlichem Rahmen/Radius; Abschnittsüberschriften mit kurzer Erklärung („Was zeigt das?“ als aufklappbares Info-Popover).

**Zustände.** Jedes Widget hat Ladezustand (Skeleton gleicher Größe, kein Layoutsprung), **Leerzustand** (ruhige Illustration/Icon, Satz „Noch keine Daten“ + Grund + was zu tun ist, z. B. „Zähler erscheinen nach dem ersten Flush (höchstens 60 Sekunden)“ oder „Push ist deaktiviert (`PUSH_ENABLED`)“), Fehlerzustand (Meldung, Wiederholen, Fehlercode ohne Details), **veraltet** (Hinweis, wenn Daten älter als das Abrufintervall), Teil-Ausfall (nur dieses Widget rot, Seite bleibt benutzbar). Mock-Modus bleibt für Entwicklung und Screenshots.

**Layout, Responsivität.** Desktop: schmale Seitenleiste (Icons + Text), Inhaltsbreite 1280 maximal, 12-Spalten-Raster; Tablet: Leiste einklappbar; Telefon: untere Tab-Leiste (Übersicht, Betrieb, Push, Geräte, Mehr), Karten einspaltig, Tabellen horizontal scrollbar mit fixierter erster Spalte oder Kartenansicht. Zeitbereichsauswahl (24 h/7 d/30 d) und „Aktualisieren“ + optionales Auto-Refresh (30 s, Polling, kein Stream) in der Kopfzeile; Auswahl in der URL.

**Barrierefreiheit.** WCAG 2.2 AA: Kontrast ≥ 4,5:1 Text/3:1 Grafik, sichtbarer Fokus, volle Tastaturbedienung (Dialoge mit Fokusfalle durch bits-ui), Zielgröße ≥ 24 px (Telefon 44 px), Landmarks und Überschriftenhierarchie, `aria-live` für Aktionsergebnisse, Status nie nur Farbe, Diagramme mit Textalternative/Tabelle, `prefers-reduced-motion`, 200 % Zoom ohne Informationsverlust.

**Mikro-Interaktion und Ton.** Kurze, sachliche deutsche Texte (Du-Form nein, neutral), konsistente Begriffe (siehe App: „Showers“), Zeiten UTC mit Anzeige in lokaler Zeit und Umschalter; Bestätigungsdialoge nennen die Folge konkret („3 Replikate starten nacheinander neu“); erfolgreiche Aktionen als Toast **und** im Protokoll.

**Qualitätssicherung Design (WP10, WP15, WP16):** Screenshots (Chromium headless) hell/dunkel, 360/768/1280 px, mit Mock-Daten in Leer-/Lade-/Fehler-/Vollzustand; Kontrast- und Axe-Prüfung (`@axe-core/playwright`, Dev-Abhängigkeit, ANNAHME zur Verfügbarkeit in der Lockdatei); Designabnahme durch den Nutzer an Screenshots vor der Integration. Safari/Firefox mit strikter CSP nachprüfen (im Grundplan offen).

### Seitenstruktur

| Seite | Inhalt | Prio |
|---|---|---|
| Übersicht | Statuskopf mit Befunden, Kennzahlen (Anfragen heute, Cache-Quote, Ingest-Alter, Push-Versandquote, aktive Live Activities), Mini-Trends, „Was ist auffällig?“ | M |
| Betrieb | Ebenen-Heat-Strips, Verzögerung, Fehler, Cache, Latenz, Replikate/Leader, Neustart-Banner | M |
| Traffic | Anfragen/Bytes, Routen, Statusklassen, Stundenmuster, Rate-Limits, Seitenaufrufe | M |
| Push & Live Activities | Trichter, Überspringgründe, Lebenszyklus, Versandbilanz, APNs-Fehler nach Grund, Token-Invalidierungen, Outbox, Voraussetzungs-Prüfliste, Pause-Schalter | M |
| Abos & Verteilung | aggregierte Verteilungen, Füllgrade, k-Unterdrückung | S |
| Geräte | gekoppelte Geräte, Koppeln, Diagnose, Aktionen, Ereignisverlauf | M |
| Konfiguration | Register (WP3/WP7) + Schwellen | M |
| Protokoll | Audit (Konfiguration, Neustart, Geräte, Pausen) | M |
| Sitzung | Passkey-Info, Abmelden, Theme, Zeitzone | M |

## 6. Sicherheit und Abgrenzung zu bestehendem Review

- Neue Angriffsfläche: Code-Erzeugung (Installations-Secret-geschützt, App-Endpunkt auf dem **öffentlichen** Listener, also Rate-Limit und Fehlauth-Zähler wie übrige Push-Routen), Einlösen und Aktionen (Dashboard-Listener, Passkey). Aktionen können nur auf die ≤ 3 gekoppelten Installationen wirken; kein Parameter für andere Ziele (Test mit Fuzz: fremde IDs liefern 404).
- Der Dashboard-Dienst darf nicht mehr Rechte bekommen als nötig; D6 entscheidet Secret vs. Befehlstabelle.
- Ereignisprotokoll und Diagnose dürfen keine Tokens/Zellen enthalten (Testfall: Serialisierung der Antworten gegen Muster für Token/UUID/Koordinaten).
- WP18 erweitert den Review aus WP9 um diesen Abschnitt (Skill `security-review`).

## 7. Arbeitspakete

Dateibesitz exklusiv je Paket; `main.swift` gehört WP5, `PushService.swift` und `PushApi.swift` je Welle genau einem Paket. Aufwand: S ≤ 0,5 Tag, M 1 bis 2, L 3 bis 5 (Agentenarbeit inkl. Tests). Besitzer-Vorschlag folgt der Aufteilung der Grundpakete (Codex/Claude), ist aber Sache des Leads.

| Paket | Inhalt | Exklusive Dateien | Hängt ab von | Aufwand | Tests |
|---|---|---|---|---|---|
| **WP10 Designsystem und Komponenten** | Tokens, Themes, Schrift lokal, Layout (Seitenleiste/Tab-Leiste), Kacheln, Tabellen, Statuspunkte, Leer-/Lade-/Fehlerzustände, SVG-Chart-Bausteine (Sparkline, Linie/Fläche, gestapelte Balken, Rangbalken, Heat-Strip, Heatmap, Histogramm, Trichter), Design-Vorschauseite, Mock-Daten | `dashboard/src/lib/design/**`, `dashboard/src/lib/charts/**`, `dashboard/src/routes/layout.css`, `dashboard/src/routes/+layout.svelte`, `dashboard/src/routes/_design/**` | WP6 | L | `svelte-check`, `vitest` (Skalen, Formatierung), Screenshots, axe, CSP-Test im Build |
| **WP11 Metriken und Beobachter** | `PushObserver`-Protokoll in `PushService`/`PushApi` (Auslöser, Überspringgründe, Versandergebnis mit Grund, Token-Invalidierung, Lebenszyklus), neue Zähler/Buckets (Latenz, Verzögerung, `apns_error`, `la_event`, `push_trigger`, `push_skipped`, `token_invalidated`, `leader_change`), `stats_hourly`, Migration 010, Flush-Erweiterung | `migrations/010_insights.sql`, `StatsCollector.swift`, `StatsQuery.swift`, `PushObserver.swift`, `PushService.swift`, `PushApi.swift`, `Apns.swift` (nur Reason-Weitergabe), `Api.swift` (Latenz-Messpunkt), Tests | WP1, WP2 (erledigt), WP5 für Verdrahtung | L | Zähler/Etikettenraum, Flush additiv für Stunden, Observer-Aufrufe je Pfad (Memory + MariaDB), Overhead-Messung, keine IDs in Labels |
| **WP12 Insight-Lese-API** | Abfragen/Gauges (Trichter, Verteilungen mit k-Unterdrückung, Outbox, Replikate, Leader, Füllgrade), Befund-Regeln `DashboardFindings`, Routen `/dash/api/insights/{overview,ops,traffic,push,distribution,findings}`, Schwellen-Schlüssel im Register | `DashboardInsights.swift`, `DashboardFindings.swift`, `DashboardInsightsApi.swift`, `ConfigRegistry.swift` (nur Schlüssel `DASH_WARN_*`, `DASH_MIN_GROUP`; Besitz für diese Welle), `docs-site/content/dashboard-api.md` (Insights-Teil), Tests | WP5 (Router), WP11 (Zähler; **Slice 1 „Push-Gauges und Prüfliste“ nur DB-Gauges, vorab möglich**) | L | Gauge-Abfragen gegen Memory+MariaDB, k-Unterdrückung, Regeln mit Grenzfällen, keine IDs in Antworten (Musterprüfung) |
| **WP13 Geräte-Kopplung (Backend)** | Migration 011, `DeviceLinkRepo` (Memory + Maria), App-Routen link-code/link, Dashboard-Routen devices/*, `PushDiagnosis`, Aktionen (Testpush, Probe, Ende, Neuauswertung, Slot-Reset), `DeviceEventRecorder` (Observer-Implementierung), Janitor, Capability `device_link`, `DEVICE_LINK_ENABLED`, `DASH_MAX_DEVICES`, `DASH_DEVICE_TTL_DAYS`, optional `dashboard_command` (D6), Datenschutztext in `SitePages` | `migrations/011_device_link.sql`, `DeviceLinkRepo*.swift`, `PushDiagnosis.swift`, `DeviceActions.swift`, `DashboardDevicesApi.swift`, `PushLinkApi.swift`, `SitePages.swift` (nur Datenschutzabsatz), `PushApi.swift` (nur Routeneinhängung, **nach WP11**), Tests | WP5, WP11, Entscheidungen D2, D3, D6 | L | Code-Lebenszyklus (Ablauf, Einmalverwendung, Rate-Limit), Limit 3, Kaskadenlöschung, Widerruf (App/Dashboard/TTL/Flag), nur gekoppelte Ziele (Fuzz), Diagnose je Befundfall, Aktionslimits, Audit, keine Tokens/Zellen in Antworten, Datenschutztext DE/EN |
| **WP14 App: Opt-in und Erkennung (App-Repo, eigener Besitzer)** | Spike TestFlight-Erkennung auf echtem Gerät, Schalter und Code-Anzeige im Info-Sheet, Datenschutztext, Fehlerzustände, fail closed bei unklarer Erkennung | im App-Repo (Dateien dort festlegen); **dieses Repo ändert nichts** | Vertrag aus WP13 (API-Entwurf 4.7) | M | Gerätetest TestFlight, Unit-Tests der Erkennung (injizierbar), Snapshot/UI-Test Schalter, Löschverhalten gegen Mock-Server |
| **WP15 Frontend: Betrieb, Traffic, Push, Abos, Übersicht** | Seiten auf Basis WP10 und Insights-Vertrag (zuerst gegen Mock), Zeitbereich, Auto-Refresh, Befundkopf, Info-Popover | `dashboard/src/routes/(app)/**` (außer `geraete`, `konfiguration`), `dashboard/src/lib/insights/**`, Mock-Erweiterung | WP10, Vertrag WP12 | L | `vitest`, `svelte-check`, Screenshots hell/dunkel/Breiten, axe |
| **WP16 Frontend: Geräte und Konfiguration/Schwellen/Protokoll** | Seite „Geräte“ (Koppeln, Diagnose-Ampel, Aktionen mit Bestätigung, Verlauf), Konfiguration um Schwellen und Pause-Schalter, Protokoll-Filter | `dashboard/src/routes/(app)/geraete/**`, `…/konfiguration/**`, `…/protokoll/**` | WP10, Vertrag WP13; **ersetzt den Teil von WP7 für Konfiguration** | M | wie WP15, Dialog-/Fokus-Tests |
| **WP17 Doku, Datenschutz, Deploy** | `docs-site` (api, dashboard-api, betrieb, seiten/datenschutz), `docs/pages.md`, `.env.example`, Registerzeilen und Tabellen (`deploy/swarm/config-registry.tsv`, `check-config-tables.sh` laufen lassen), ggf. Secret im `stack.dashboard.yaml` (D6) | genannte Dateien; **`deploy/swarm/*` erst anfassen, wenn der Fremdbesitz der uncommitteten Änderungen geklärt ist** | WP13, WP12 | M | Linkprüfung, Suche nach privaten Pfaden/Domains, `check-config-tables.sh`, `docker stack config` |
| **WP18 Review und Abnahme** | Erweiterung WP9: Sicherheits-Review Gerätekopplung, E2E (Playwright, virtueller Authenticator, Pairing-Flow mit Test-App-Client), Datenschutzprüfung, Gerätetest mit TestFlight-Build (Live Activity Probe), Designabnahme, Status/Entscheidungen | `docs/decisions.md`, `docs/status.md`, `dashboard/e2e/**` | alle | M | siehe Spalte, plus Abschnitt 8 |

**Parallelisierung (Präzisierung 6.11.2026): drei unabhängige Spuren, getrennter Dateibesitz, höchstens drei Worker.**

Schritt 0 (**erledigt 6.11.2026**, Todolino „WP-V API-Verträge“): **WP-V „Verträge einfrieren“** hat die API-Verträge in `docs-site/content/api.md` (App-Routen inkl. `app_transaction`, `device_link`), `docs-site/content/dashboard-api.md` (Insights-, Geräte-, Aktions- und Befehlsrouten) und einen Fixture-Satz (`docs/fixtures/app/*.json`, `docs/fixtures/dashboard/*.json`, Manifest `docs/fixtures/manifest.json`, erfundene Beispieldaten) festgeschrieben (Abschnitt 11). Danach arbeiten die Spuren ohne gegenseitiges Warten:

| Spur | Worker | Pakete in Reihenfolge | Exklusive Verzeichnisse | Gegen was entwickelt |
|---|---|---|---|---|
| **Backend-API** (Repo Backend, `Sources/`, `Tests/`, `migrations/`) | 1 | WP5 (Router, Voraussetzung) → WP13a (Kopplung + JWS-Prüfung + Diagnose, **zuerst**, weil Nutzerschmerz) → WP11 (Metriken/Observer) → WP12 (Insight-API) | alle Swift-Dateien dieser Pakete, `migrations/010+`, `docs-site/content/{api,dashboard-api}.md` und `docs/fixtures/**` nach WP-V (Änderungen nur additiv oder mit Vertragsversion) | Tests mit Memory/MariaDB, selbstsignierte Testkette für JWS |
| **Dashboard-Frontend** (Repo Backend, nur `dashboard/**`) | 2 | WP10 (Designsystem) → WP15 (Seiten) → WP16 (Geräte, Konfiguration) | `dashboard/**` ausschließlich | Mock-Server mit `docs/fixtures/` (Manifest) |
| **App-Opt-in** (Repo Apple, eigener Besitzer) | 3 | WP14: Spike TestFlight-Erkennung → `BuildChannel` → UI → Datenschutztext → Tests | nur App-Repo; dieses Repo unverändert | Mock-Server nach Vertrag, injizierte StoreKit-Antworten |

Konflikte ausgeschlossen: Frontend schreibt nur unter `dashboard/`, App nur im App-Repo, Backend nur unter `Sources/`, `Tests/`, `migrations/`, Vertragsdateien (erst nach WP-V). `PushService.swift`/`PushApi.swift` hat im Backend nur ein Worker. Docker/Browser-Build: Frontend-Worker; Swift-Build/DB-Tests: Backend-Worker; Gerätetests: Nutzer/App-Worker. WP17 (Doku/Deploy, nach Klärung von `deploy/swarm/`) und WP18 (Review/E2E, Gerätetest TestFlight, App-Store-Stichprobe nach Veröffentlichung) folgen, sobald die Spuren fertig sind; auch sie als ein Worker je Paket, nie mehr als drei gleichzeitig.

Zeitliche Abfolge: Welle 0: WP-V (+ Spike WP14 parallel, weil unabhängig). Welle 1: die drei Spuren parallel. Welle 2: WP17, WP18 (WP12-Rest und WP16 laufen in ihren Spuren weiter). Der Sofort-Slice (Push-Gauges, Diagnose, Ereignisse) liegt vorn in der Backend-Spur (WP13a vor WP11); das Frontend zeigt ihn zuerst im Mock.

Voraussetzung bleibt der Abschluss von WP5; WP7-Altumfang entfällt zugunsten WP10/WP15/WP16 (Board-Aufgabe WP7 anpassen). WP13 aus der Tabelle oben heißt jetzt WP13a (Kopplung, Diagnose, JWS-Prüfung, Aktionen); der Rest der Tabellenzeile (Dateien) bleibt, erweitert um `AppAttestation.swift` (JWS-Prüfung, ggf. mit Package-Änderung `Package.swift`/`Package.resolved`, Besitz Backend-Spur).

**Abgrenzung zu WP5 bis WP9.**
- WP5 bleibt Listener/Router/Statik/`main.swift`; Insights- und Geräte-Routen kommen als eigene Dateien, die WP5 nur registriert (Router-Erweiterungspunkt in WP5 verlangen: Liste von Routen-Registrierern).
- WP7 wird durch WP10/WP15/WP16 ersetzt (Konfiguration-UI übernimmt WP16, Übersicht/Traffic WP15).
- WP8: Deploy-Dateien; der Fremdbesitz der uncommitteten Änderungen in `deploy/swarm/` bleibt unangetastet, WP17 stimmt sich mit WP8 ab.
- WP9 bleibt Review des Grundumfangs; WP18 prüft den Ausbau und kann mit WP9 zusammengelegt werden.

## 8. Tests gesamt

`swift test` (Memory) und gegen Wegwerf-MariaDB; Frontend: `npm run check`, `lint`, `test`, `build`, Playwright-E2E; manuell: Gerätetest TestFlight mit echter Live Activity (Probe, Ende, Diagnose gegen reales Verhalten). Nicht ausgeführt, da reine Planung: Builds und Tests.

## 9. Entscheidungen (alle angenommen am 6.11.2026)

Der Nutzer hat am 6.11.2026 **alle Empfehlungen D1 bis D14 angenommen**, mit zwei Änderungen: **D3** (Kopplung dauerhaft, kein Ablauf) und **Design** (Vorbild `timetrack-pwa`, Abschnitt 5). Spalte „Entscheidung“ ist verbindlich.

| # | Frage | Entscheidung | Verworfene Alternative |
|---|---|---|---|
| D1 | Stundenauflösung für ausgewählte Metriken | **Ja**, 72 h, nur Zähler | nur Tageswerte |
| D2 | Sichtbarkeit des App-Schalters | **Nie im App Store; nur nachweislich TestFlight (Debug zusätzlich), fail closed, App- und Serverprüfung**; Server-Schalter `DEVICE_LINK_ENABLED` Standard aus (harte Anforderung H1) | – |
| D3 | Kopplungsdauer und Anzahl | **GEÄNDERT: dauerhaft (kein Ablauf), jederzeit widerrufbar** (App-Schalter, Dashboard, `DEVICE_LINK_ENABLED=false`, Löschen der Installation); **höchstens 3 Geräte** (`DASH_MAX_DEVICES`). Ablauf nur optional per `DASH_DEVICE_TTL_DAYS` (Standard `0` = aus); Anzeige „zuletzt gesehen“, Risiken in 4.3 | 14 Tage (Empfehlung des Plans, durch den Nutzer verworfen), 7/30 Tage, 1 Gerät |
| D4 | Aufbewahrung | Geräteereignisse 48 h, Audit 365 Tage | Audit 90 Tage |
| D5 | Geografische Verteilung der Abos | **Nein** | grobe Sektoren |
| D6 | Wie erreichen Dashboard-Aktionen APNs? | **Befehlstabelle `dashboard_command`**, vom Leader abgearbeitet (kein APNs-Secret im Dashboard-Dienst, Verzug ≈ 2 s) | APNs-Secret im Dashboard-Dienst |
| D7 | Chart-Technik | **Eigene SVG-Bausteine** (bestätigt durch das Vorbild `timetrack-pwa`) | shadcn-svelte-Chart/LayerChart |
| D8 | Benachrichtigung an gekoppeltes Gerät bei „rot“ | **Nicht jetzt** | später als Kann |
| D9 | Push-Pause-Schalter und Cache leeren | **Ja** | nur Konfiguration/Neustart |
| D10 | Reihenfolge | **Zuerst Sofort-Slice (Push-Gauges, Diagnose, Ereignisse), dann Optik/Rest** | erst Designsystem |
| D11 | Schrift | **Inter Variable lokal gebündelt** (wie `timetrack-pwa`) | Systemschrift |
| D12 | TestFlight-Erkennung | **`AppTransaction` (verifiziertes JWS, `Sandbox`) + `sandboxReceipt` als Gegenprobe, Spike-Abnahme** (WP14), bis zur Messung Schalter in Release-Builds aus | nur lokale Erkennung |
| D13 | Befund-Schwellen aus 2.6 | **Startwerte übernehmen**, nach 2 Wochen kalibrieren | andere Werte |
| D14 | JWS-Prüfung im Backend | **Apples `app-store-server-library-swift` exakt gepinnt**, falls Lizenz/Abhängigkeiten tragbar (WP13a prüft); sonst eigene Minimalprüfung | Eigenprüfung von Anfang an |

## 10. Risiken

1. **Datenschutz/Vertrauen:** Gerätekopplung ist die einzige Funktion mit Gerätebezug und besteht dauerhaft bis zum Widerruf; Gegenmaßnahmen 4.3. Restrisiko: Betreiber koppelt fremdes Gerät (Code nur über die App, Einwilligung des Gerätebesitzers; Betreiber-Hinweis in Doku).
2. **TestFlight=`Sandbox` unbelegt** (4.6): Spike zuerst, fail closed; Replay eines echten Sandbox-JWS bleibt möglich, wird durch Passkey-Einlösung entschärft; App-Store-Fall erst nach Veröffentlichung messbar.
3. **Zähler-Overhead und Etikettenraum** bei neuen Metriken: Messung wie in WP2 (Mikrosekunden je Anfrage), feste Etiketten.
4. **Gleichzeitige Änderungen an `PushService`/`PushApi`** (WP11, WP13): sequenziell, `PushObserver` als schmale Nahtstelle.
5. **Dashboard-Dienst ohne APNs-Secret** (D6) kann Aktionen nicht direkt senden → Befehlstabelle; Verzug und Fehlerrückmeldung über Ereignisverlauf.
6. **Diagnose beantwortet nur, was das Backend weiß:** Fehlt der Start-Token, liegt die Ursache in der App/iOS (Live-Activities-Einstellung, Berechtigung); das Dashboard zeigt es, behebt es nicht.
7. **Apple-Gründe (APNs):** Liste vor Umsetzung gegen die aktuelle Apple-Dokumentation abgleichen; unbekannte Gründe landen in `other`.
8. **Umfangsrisiko:** Der Katalog ist groß. Schnitt: erst alle „M“ (WP10 bis WP13, WP15/16 für M-Seiten), „S“ nach Abnahme, „K“ nur auf Zuruf.
9. **Dauerhafte Kopplung (D3, 6.11.2026):** Ein dauerhaft gekoppeltes Gerät kann in fremde Hände gelangen oder lange ungenutzt bleiben; es gibt nur Anzeige (`zuletzt gesehen`, `stale`), keine automatische Löschung; Gegenmaßnahmen und Restrisiko in 4.3. Der Betreiber kann einen Ablauf per Konfiguration erzwingen.

Nicht ausgeführt: keine Builds/Tests; Primärquellen zu `AppTransaction` waren per Werkzeug nicht inhaltlich lesbar (nur Seitentitel), daher bleiben die Aussagen in 4.6 Annahmen.

## 11. WP-V: Vertragsumfang und Übergabenotizen je Spur (6.11.2026)

**Eingefroren** (Stand 6.11.2026; spätere Änderungen nur additiv oder mit Vertragsversion in dieser Datei, in api.md/dashboard-api.md und in `docs/fixtures/` zugleich):

- App ↔ Backend (`api.md`): `POST/GET/DELETE /v1/push/installations/<id>/link-code|link`, `app_transaction` (JWS-Prüfung, `403 not_testflight`), Capability `device_link` in `GET /v1/status`, Fehlercodes, Ratenlimits, Hinweis „keine Befehle/Ereignisse zur App“.
- Dashboard ↔ Backend (`dashboard-api.md`): `GET insights/{overview,ops,traffic,push,distribution,findings}` (Felder, Einheiten, k-Unterdrückung, Teilausfall), Push-Pause, Cache leeren, Geräte (`devices`, `pair`, Status, Diagnose, Ereignisse), Aktionen und Befehlstabelle mit Ergebnis-Polling, Konfiguration/Audit/Neustart (für den Mock), Fehlercodes.
- Fixtures: `docs/fixtures/manifest.json` (Methode, Pfad, Status je Datei), `docs/fixtures/app/` (snake_case) und `docs/fixtures/dashboard/` (camelCase), mit Leer-, Fehler- und Teilausfallfällen.

**Übergabe Spur Backend (Worker 1)**
- Besitz: `Sources/**`, `Tests/**`, `migrations/**`, `Package.swift`/`Package.resolved`; Vertragsdateien `docs-site/content/{api,dashboard-api}.md` und `docs/fixtures/**` nur bei Vertragsänderung (additiv, mit Fixture-Anpassung).
- Reihenfolge: WP5 → WP13a → WP11 → WP12. Antworten müssen den Fixtures strukturell entsprechen (Contract-Tests: Fixture laden, Schlüsselmenge und Typen vergleichen, Null-Semantik beachten).
- Besonderheiten: Route-Gruppen aus `StatsRoute.groups`; k-Unterdrückung inkl. Komplementärunterdrückung; keine IDs/Token/Zellen in Antworten (Musterprüfung); Body-Grenze 8 KB nur für `link-code`; Code-Alphabet Crockford 32 Symbole; Kopplung dauerhaft (`expires_at` nur bei `DASH_DEVICE_TTL_DAYS > 0`).
- Nicht anfassen: `dashboard/**`, App-Repo, `deploy/swarm/*` (Fremdbesitz bis zur Klärung; WP17).

**Übergabe Spur Frontend (Worker 2)**
- Besitz: ausschließlich `dashboard/**`. Mock-Server liest `docs/fixtures/manifest.json` (Repo-Pfad relativ zu `dashboard/`, nicht kopieren, damit Vertragsänderungen sofort wirken) und liefert je Pfad Standardfall; Leer-/Fehlerfälle über Szenario-Schalter.
- Design: nach `timetrack-pwa` (Abschnitt 5). Unbekannte Aufzählungswerte tolerieren, `null` als „nicht erhoben“ darstellen (nicht als 0), `partial` je Widget als Teilausfall, Fehlertexte nach Code/Status wählen, keine Serverfreitexte.
- Abhängigkeiten: Frontend-Typen (`dashboard/src/lib/api.ts`) aus dem Vertrag ableiten (camelCase), Abweichungstabelle in dashboard-api.md beachten.

**Übergabe Spur App (Worker 3, App-Repo)**
- Besitz: nur App-Repo (WP14); dieses Repo wird nicht geändert. Tests und Mock-Server nutzen `docs/fixtures/app/*.json` (snake_case) und `GET /v1/status`-Fixture.
- Pflicht: `BuildChannel` fail closed (Abschnitt 4.6), Abschnitt nur bei `.testFlight` **und** Capability `device_link`; `app_transaction` nur im Speicher und nur mit `link-code`; bei Wechsel zu App Store beim Start `DELETE …/link`; Polling nur bei offenem Code-Bildschirm (3 s, höchstens 10 min); „läuft ab am“ nur anzeigen, wenn `expires_at` nicht `null` ist; Kopplung ist dauerhaft („bis zum Widerruf“ im Datenschutztext).
- Nicht im Umfang: Befehlsempfang (es gibt keinen Kanal), Dashboard-Funktionen.

**Offene Punkte nach WP-V** (nicht blockierend): Spike-Ergebnis zu `receiptType` (TestFlight = `Sandbox`?) und `receiptCreationDate`-Fenster (`DEVICE_LINK_MAX_AGE_HOURS`); APNs-Reason-Liste gegen aktuelle Apple-Doku abgleichen; Latenz-/Lag-Buckets nach WP11 kalibrieren; Heatmap Wochentag × Stunde ist durch die 72-h-Stundenaufbewahrung auf 3 Tage begrenzt; Dashboard-Frontend-Typen bis WP7-Umbau noch snake_case.
