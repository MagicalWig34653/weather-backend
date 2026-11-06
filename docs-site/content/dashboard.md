# Betreiber-Dashboard

Das Dashboard ist eine optionale, nur für den Betreiber gedachte Oberfläche: Betriebszustand, Traffic, Push-Pipeline, gekoppelte Testgeräte und einige Aktionen. Es ist standardmäßig aus, läuft als eigener Dienst mit eigenem Listener (Container-Port 9090), den nur Ihr externer Reverse Proxy erreichen soll (veröffentlichter Port 39090, per Firewall auf den Proxy beschränkt). Die Schnittstellen stehen in der [Dashboard-API](https://github.com/MagicalWig34653/weather-backend/blob/main/docs-site/content/dashboard-api.md). Es zeigt nur Zähler, Messwerte und feste Etiketten: keine IP-Adressen, Orte, Zellen, Installations-IDs oder Token.

## Aktivieren

1. In der `.env` (oder per `deploy/swarm/settings.sh`, Gruppe „Dashboard“) setzen: `DASH_ENABLED=true` und `DASH_ORIGIN=https://<Ihre-Dashboard-Adresse>` (https, ohne Pfad; ohne gültige Origin bricht der Start bewusst ab). `DASH_RP_ID` ist optional (Standard: Host der Origin).
2. Der **externe** Reverse Proxy terminiert TLS, leitet auf `<Swarm-Knoten>:39090` (`DASH_PUBLISH_PORT`, Ingress-Port wie bei `radar`; im Container lauscht der Dienst auf `DASH_PORT`, Standard 9090) und reicht den `Host`-Header unverändert durch (WebSockets nicht nötig). Auf dem öffentlichen Radar-Port antwortet `/dash` weiterhin mit 404.
3. **Proxy-Token als Docker-Secret anlegen** (Pflicht, siehe [Proxy-Token](#proxy-token)): ohne das Secret `showernow_dashboard_proxy_token` brechen `swarm-deploy.sh` und `update.sh` vor jeder Änderung mit einer klaren Meldung ab.
4. `swarm-deploy.sh` beziehungsweise `update.sh` binden bei `DASH_ENABLED=true` das Overlay `stack.dashboard.yaml` ein. Danach ausrollen.
5. **Setup-Fenster:** Nur beim ersten Start ohne vorhandenes Credential ist die Registrierung offen, für `DASH_SETUP_WINDOW_MINUTES` (Standard 15), und zwar für den **Ersten, der das Dashboard erreicht**. Rufen Sie das Dashboard deshalb **sofort nach dem Ausrollen** über Ihren Proxy auf und legen Sie den **Passkey** an (WebAuthn, daher HTTPS). Die Dienste melden den Hinweis jede Minute im Log. Ist das Fenster verpasst: Dienst neu starten.
6. Sitzungen laufen höchstens `DASH_SESSION_HOURS` (12) und enden nach `DASH_IDLE_MINUTES` (30) ohne Aktivität. Änderungen und Aktionen brauchen zusätzlich das CSRF-Token und sind ratenbegrenzt.
7. **Reset** (Passkey verloren): `radar dashboard-reset --yes` am Dienst. Es löscht Passkey, Sitzungen und offene Challenges (Audit `reset_cli`); das Setup-Fenster öffnet sich beim nächsten Start der Dienste.

Weitere Einstellungen: `DASH_MIN_GROUP` (3 bis 50, Standard 5): Gruppen darunter erscheinen als „<5“, auch Differenzen, aus denen sich kleine Gruppen errechnen ließen. `RESTART_STAGGER_SECONDS` (45): Abstand beim kontrollierten Neustart der Replikate.

## Erreichbarkeit absichern

Der Dienst veröffentlicht genau einen Ingress-Port (`DASH_PUBLISH_PORT`, Standard 39090; nie `mode: host`). Dieser Port ist auf jedem Swarm-Knoten erreichbar, deshalb:

- **Firewall:** Port nur für die Adresse(n) Ihres Reverse Proxys öffnen, nie fürs Internet. Beispiel `ufw` auf jedem Knoten: `ufw allow from <Proxy-IP> to any port 39090 proto tcp`; Docker umgeht `ufw`-Regeln, bei Bedarf stattdessen in der Kette `DOCKER-USER`: `iptables -I DOCKER-USER -p tcp --dport 39090 ! -s <Proxy-IP> -j DROP` (Beispiel, vom Betreiber auf dem eigenen Setup zu prüfen: Von einem Rechner außerhalb des Proxys darf `curl -m 5 http://<Knoten>:39090/` nicht antworten).
- **Host-Header** unverändert (`DASH_ORIGIN` wird gegen `Host` und `Origin` geprüft), **HTTPS** am Proxy.
- **Proxy-Token:** Der Dienst antwortet nur auf Anfragen mit dem Header `X-Dashboard-Proxy-Token` (richtiger Wert), alle anderen bekommen ein schlichtes 404, ohne Hinweis auf das Dashboard. Das ist die zweite Schranke neben der Firewall, falls der Port doch von anderswo erreichbar ist (siehe [Proxy-Token](#proxy-token)).
- **Passkey sofort** einrichten (Setup-Fenster, siehe oben). Danach schützt der Passkey; der Dienst hat Ratenbegrenzung, CSRF-Schutz, kein Docker-Socket, kein APNs-Schlüssel, schreibgeschütztes Dateisystem.

Proxy-Beispiele (Adresse `dash.example.org`, Knoten `10.0.0.5`, `<TOKEN>` = Inhalt Ihrer Datei `proxy-token.txt`, siehe unten). Der Header wird **gesetzt**, nicht angehängt: Ein vom Client mitgeschickter `X-Dashboard-Proxy-Token` darf nie durchgereicht werden (nginx `proxy_set_header` und Caddy `header_up` ersetzen ihn, bei Traefik ersetzt `customRequestHeaders` ihn ebenfalls):

```nginx
server {
  listen 443 ssl;
  server_name dash.example.org;
  location / {
    proxy_pass http://10.0.0.5:39090;
    proxy_set_header Host $host;                       # unverändert durchreichen
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Dashboard-Proxy-Token "<TOKEN>";   # setzt (ersetzt) den Header; besser aus einer nur für root lesbaren include-Datei
  }
}
```

```caddy
dash.example.org {
  reverse_proxy 10.0.0.5:39090 {   # Caddy reicht Host standardmäßig unverändert durch
    header_up X-Dashboard-Proxy-Token "<TOKEN>"   # header_up ersetzt den Wert (Platzhalter {$DASH_TOKEN} aus der Umgebung ist möglich)
  }
}
```

```yaml
# Traefik (dynamische Konfiguration); passHostHeader ist Standard true
http:
  routers:
    dash: { rule: "Host(`dash.example.org`)", service: dash, tls: {} }
  middlewares:
    dash-token:
      headers:
        customRequestHeaders:
          X-Dashboard-Proxy-Token: "<TOKEN>"   # ersetzt einen vom Client gesendeten Wert
  services:
    dash:
      loadBalancer:
        passHostHeader: true
        servers: [ { url: "http://10.0.0.5:39090" } ]
# am Router: middlewares: [dash-token]
```

### Proxy-Token

Das Token ist ein gemeinsames Geheimnis zwischen Proxy und Dashboard-Dienst (32 bis 256 sichtbare ASCII-Zeichen ohne Leerzeichen). Es liegt als **Docker-Secret** `showernow_dashboard_proxy_token` (Name über `DASH_PROXY_TOKEN_SECRET` änderbar) und wird als Datei eingehängt (`DASH_PROXY_TOKEN_FILE`). Nicht in der `.env`, nicht als Umgebungsvariable: dort würde es in `docker service inspect` und `docker stack config` sichtbar, anders als das Datenbank-Passwort und der APNs-Schlüssel. Nur der Dienst `dashboard` bekommt es; die `radar`-Replikate brauchen es nicht. `DASH_PROXY_TOKEN_REQUIRED=false` wirkt im Swarm-Stack nicht (das Secret ist immer eingehängt und wird immer geprüft).

**Erzeugen (auf einem Swarm-Manager):**

```sh
umask 077
openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' > proxy-token.txt
docker secret create showernow_dashboard_proxy_token proxy-token.txt
# Wert aus proxy-token.txt im Proxy eintragen (siehe oben), danach:
rm proxy-token.txt
```

Ein Secret lässt sich nicht auslesen; heben Sie den Wert nur im Proxy auf. `deploy/swarm/settings.sh --check` und die Skripte prüfen, ob das Secret existiert.

**Rotation** (Secrets sind unveränderlich, deshalb mit neuem Namen; `DASH_PROXY_TOKEN_PREVIOUS_SECRET` hält das alte Token für den Übergang gültig):

1. Neues Secret anlegen, z. B. `showernow_dashboard_proxy_token_2`.
2. In der `.env` `DASH_PROXY_TOKEN_SECRET=showernow_dashboard_proxy_token_2` und `DASH_PROXY_TOKEN_PREVIOUS_SECRET=showernow_dashboard_proxy_token` setzen, ausrollen (`update.sh --force` oder `swarm-deploy.sh`). Jetzt gelten beide Token.
3. Im Proxy den Header auf den neuen Wert umstellen und das Dashboard prüfen.
4. `DASH_PROXY_TOKEN_PREVIOUS_SECRET` aus der `.env` entfernen, erneut ausrollen (die Skripte nehmen dann das aktuelle Secret für beide), danach das alte Secret entfernen: `docker secret rm showernow_dashboard_proxy_token`.

Bei einem Deploy von Hand (`docker stack deploy -c stack.yaml -c stack.dashboard.yaml ...`) beide Namen exportieren oder keinen; die Skripte setzen den Rückfall selbst.

**Prüfen:** Ohne Header antwortet der Port mit 404, mit dem richtigen Header erscheint das Dashboard:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://<Knoten>:39090/dash/api/session -H 'Host: dash.example.org'                                  # 404
curl -s -o /dev/null -w '%{http_code}\n' http://<Knoten>:39090/dash/api/session -H 'Host: dash.example.org' -H "X-Dashboard-Proxy-Token: $(cat proxy-token.txt)"   # nicht 404
```

(Diese Prüfung vom Proxy-Rechner oder Knoten aus; von außen soll der Port ohnehin nicht antworten.)

### Update-Reihenfolge (Proxy-Token, Kopplungsfenster)

1. Backup der Datenbank; `deploy/swarm/update.sh --pull-scripts` holt die neuen Skripte und prüft vor jeder Änderung die Secrets.
2. Das Secret `showernow_dashboard_proxy_token` anlegen (siehe oben), **bevor** `update.sh` läuft, sonst bricht es ab.
3. In der `.env` (oder per `settings.sh`) setzen: `DASH_ENABLED=true`, `DASH_ORIGIN`, gegebenenfalls `DEVICE_LINK_ENABLED=true` (mit `PUSH_ENABLED=true`).
4. `update.sh` ausführen: Das neue Image, die Migrationen `012` (Audit) und `013` laufen im Migrationsjob automatisch mit, danach folgt das Rolling Update von `radar` und der Start des Dienstes `dashboard`.
5. Den Header `X-Dashboard-Proxy-Token` im Reverse Proxy setzen (Beispiele oben), Proxy neu laden. Bis dahin antwortet das Dashboard mit 404.
6. Dashboard aufrufen und den Passkey registrieren (Setup-Fenster beachten), die Prüfung oben ausführen.
7. Die Push-Anzeige im Dashboard zeigt „unbekannt“, bis die `radar`-Replikate mit dem neuen Image gestartet sind (der Zustand stammt aus den Meldungen der Replikate); nach dem Rolling Update verschwindet das. Die Statistik der neuen Bytes-Zähler gibt es erst ab diesem Deploy, frühere Tage bleiben leer.
8. Kopplungsfenster erst danach im Dashboard öffnen (siehe unten); Variablen `DEVICE_LINK_*` sind auf `radar` und `dashboard` identisch gesetzt (das Overlay spiegelt sie).

## Schwellen und Befunde

Der Statuskopf „Befunde“ wird bei jedem Abruf aus Regeln berechnet (kein Hintergrunddienst, kein externer Versand). Jede Regel hat eine gelbe und eine rote Schwelle im Register (Gruppe „Dashboard-Schwellen“, im Dashboard live änderbar; ein per Umgebung gesetzter Wert hat Vorrang):

| Befund (`code`) | Bedeutung | Schwellen `DASH_WARN_…` (gelb / rot) |
|---|---|---|
| `layer_stale` | Datenebene veraltet; Alter als Vielfaches des Takts | `LAYER_AGE_FACTOR` (2 / 4) |
| `error_rate_5xx` | Anteil 5xx-Antworten der letzten Stunde | `ERROR_RATE_5XX` (0,5 % / 2 %) |
| `outbox_age` | Ältester wartender Push-Eintrag | `OUTBOX_AGE_SECONDS` (120 s / 600 s) |
| `apns_rejection` | Anteil abgelehnter APNs-Sendungen (1 h, ohne `Unregistered`/Wiederholung, mindestens 10 Fälle) | `APNS_REJECTION` (5 % / 25 %) |
| `token_invalidation` | Ungültig gewordene Token je Alert und Live-Activity-Ereignis (24 h) | `TOKEN_INVALIDATION` (5 % / 20 %) |
| `cache_hit_low` | Trefferquote des Caches, untere Grenze | `CACHE_HIT` (80 % / 50 %) |
| `cap_fill` | Füllgrad einer Obergrenze (Installationen, Abos, Regionszellen, Activity-Abos) | `CAP_FILL` (80 % / 95 %) |
| `la_start_ratio_low` | Zugestellte Live-Activity-Starts je gesendetem Start (mindestens 10 Fälle) | `LA_START_RATIO` (70 % / 30 %) |
| `replicas_missing`, `leader_missing` | Weniger Replikate als Soll; kein Push-Leader | feste Regel |

Die Zahlen sind Startwerte und mit echten Daten noch nicht kalibriert.

## Seiten und Kennzahlen

- **Übersicht:** Befunde, Kennzahlen (Anfragen, Cache-Trefferquote, Alter der Ebenen, Zustellquote, aktive Live Activities) mit Veränderung zum Vorbereich.
- **Betrieb:** Ingest je Ebene (Läufe der letzten 24 h, Alter, Verzögerung Slot bis Veröffentlichung, P50/P95), Latenz je Routengruppe, Cache (Trefferquote, Füllstand und Verdrängungen **nur des Replikats, das die Anfrage beantwortet**), Replikate, Leader. Perzentile stammen aus Bucket-Zählern und sind nur auf die Bucketgrenze genau.
- **Traffic:** Anfragen, Bytes, Statusklassen, 304-Anteil, Ratenlimit-Treffer, Stunden- und Tagesverlauf. Stundenreihen reichen 72 Stunden zurück, Tageswerte 30 Tage.
- **Push:** Trichter und Versandbilanz (siehe unten), Outbox, APNs-Fehler, Token-Invalidierungen, Ablehnungen der Registrierung, Füllgrade, Push-Pause.
- **Geräte:** gekoppelte Testgeräte, Diagnose, Ereignisverlauf, Aktionen.
- **Aktionen:** Push-Pause, Cache leeren und kontrollierter Neustart (alle ratenbegrenzt und im Audit-Protokoll). Das Audit-Protokoll (`config_audit`) wird 365 Tage aufbewahrt, auch Einträge zu Kopplung, Trennen und Geräteaktionen (nur Zeitpunkt, 8-Zeichen-Geräteverweis und Ergebnis; nach dem Trennen nicht mehr auf die Installation zurückführbar).

Nicht erhoben und als „nicht verfügbar“ markiert: Datenbank-Pool und Fehlerzähler, Registrierungsverlauf, Zeitmessung der Auswertung, Anzahl der Leader-Wechsel.

## Live-Activity-Diagnose lesen

Der häufigste Anlass: „Die Live Activity startet trotz Aktivierung nicht.“ Zwei Ansichten helfen.

**1. Push-Seite, Trichter.** Von oben nach unten, jede Stufe mit Zahl und Anteil an der Vorstufe:

1. Installationen (aktiv, je Umgebung `sandbox`/`production`)
2. Installationen mit Gerätetoken, davon mit **Live-Activity-Start-Token**
3. Abos mit `live_activity` an
4. **Auslöser**: der Lauf hat einen Regenbeginn (`la_rain_start`) oder „Es regnet gerade“ (`la_raining_now`) erkannt
5. **Überspringgründe**: ausgelöst, aber nicht gesendet
6. Gesendete Starts, davon zugestellt, abgelehnt, wiederholt, verworfen
7. Aktive Activities jetzt, offene Reservierungen

Ein Einbruch zwischen zwei Stufen zeigt die Stelle. Viele Auslöser, kaum Starts: Überspringgründe prüfen. Viele Starts, wenige zugestellt: APNs-Fehler und Token-Invalidierungen prüfen.

**Überspringgründe** (Etikett `<Auslöser>:<Grund>`, Zähler je Auswertelauf):

| Grund | Bedeutung und Konsequenz |
|---|---|
| `lock_60min` | 60-Minuten-Sperre aktiv: seit dem letzten Alert oder Start für dieses Abo sind weniger als 60 Minuten vergangen (Alert und Live Activity teilen die Sperre). Normal. |
| `hysteresis` | „Es regnet gerade“ wird erst nach zwei aufeinanderfolgenden vollständigen Läufen mit nassem Slot 0 ausgelöst (Schutz gegen Schauer und Bildrauschen); ein trockener oder unbekannter Slot setzt die Bestätigung zurück. Normal. |
| `no_start_token` | Das Gerät hat keinen Start-Token gemeldet (Live Activities in iOS aus, App noch nicht geöffnet, Token fehlt). Serverseitig nicht behebbar. |
| `activity_slot_busy` | Für das Abo läuft bereits eine Live Activity (bis 8 Stunden). Kein zweiter Start. |
| `reservation_pending` | Ein früherer Start wurde reserviert und noch nicht bestätigt (bis 15 Minuten). Fällt ein Start aus, kann die Reservierung so lange blockieren. |
| `not_enabled`, `below_threshold` | Abo aus beziehungsweise Regen unter der Schwelle (`below_threshold` nur als Summe je Lauf). |
| `budget_exhausted` | Das 8-Sekunden-Budget des Laufs war aufgebraucht. |
| `env_not_allowed` | Die Umgebung der Installation ist laut `APNS_ENV` nicht erlaubt. |
| `unknown_pixel`, `no_fresh_run`, `incomplete_run` | Kein auswertbarer aktueller Lauf für diesen Punkt. |
| `paused` | Push-Pause ist aktiv. |

**2. Geräte-Seite, Diagnose.** Für ein gekoppeltes Gerät (nächster Abschnitt) prüft die Diagnose in fester Reihenfolge: Server und Capability, Push-Pause, erlaubte Umgebung, Gerätetoken, Start-Token, Abo aktiv mit Live Activity, freier Platz, Sperre und Hysterese, Auslösebedingung, letztes Versandergebnis. Angezeigt werden der wahrscheinlichste Grund und die übrigen Prüfungen. Der Ereignisverlauf (48 Stunden) zeigt Alert-, Start-, Update- und Ende-Versuche mit APNs-Ergebnis. Ein `apns_error` wie `BadDeviceToken` oder `DeviceTokenNotForTopic` zeigt meist eine falsche Umgebung oder einen falschen Schlüssel/Topic; `Unregistered` ist ein ungültig gewordener Token.

**Verlorener Start (bekannte Abwägung):** Endet ein Start mit Wiederholung (5xx, 429, Transportfehler) oder Ablehnung, gilt die 60-Minuten-Sperre trotzdem, und die Reservierung bleibt bis zu 15 Minuten. Der Start wird nicht wiederholt, weil Apple ihn trotz Fehler zugestellt haben kann. Sichtbar ist das als `la_event start:retry` beziehungsweise `apns_error start:<Grund>`. Eine Änderung (Start bei Wiederholung nicht verbrauchen) wartet auf eine Entscheidung.

## Geräte koppeln (Kopplungsfenster)

Setzt `PUSH_ENABLED=true`, `DASH_ENABLED=true` und `DEVICE_LINK_ENABLED=true` voraus. Weitere Variablen: `DEVICE_LINK_WINDOW_MINUTES` (Standard 5, 1 bis 15), `DEVICE_LINK_REQUIRE_TESTFLIGHT` (Standard `false`; mit `true` verlangt der Server zusätzlich den StoreKit-Nachweis einer Testversion, `DEVICE_LINK_BUNDLE_ID`, `DEVICE_LINK_ALLOWED_ENVS`, `DEVICE_LINK_MAX_AGE_HOURS` gelten dann), `DASH_MAX_DEVICES` (3), `DASH_DEVICE_TTL_DAYS` (0 = bis Widerruf), `DASH_DEVICE_STALE_DAYS` (14). Die Kopplung hängt nicht von der Installationsquelle ab (TestFlight oder App Store), sondern davon, dass du ein Kopplungsfenster geöffnet hast.

1. Im Dashboard unter „Geräte“ das Kopplungsfenster öffnen (Standard 5 Minuten, höchstens 15). Solange es offen ist, geben die App-Installationen auf Anfrage Koppelcodes aus (höchstens 30 je Fenster); ein Fremder kann dann einen Code anzeigen lassen, einlösen kannst ihn nur du mit Passkey.
2. In der App: Einstellungen, „Betreiber-Diagnose“, einschalten (die Option erscheint nur, solange ein Fenster offen ist). Voraussetzung: Regenhinweise für mindestens einen Ort sind an, damit das Gerät dem Server bekannt ist. Die App zeigt einen 8-stelligen Koppelcode (10 Minuten gültig, einmalig).
3. Im Dashboard unter „Geräte“ den Code eingeben und dem Gerät eine Bezeichnung geben.
4. Nach der ersten erfolgreichen Einlösung schließt sich das Fenster automatisch (erneutes Öffnen jederzeit möglich; „Schließen“ beendet es früher). Ein bereits ausgegebener Code bleibt bis zu seinem Ablauf einlösbar. Gespeichert werden: Zuordnung zur Push-Registrierung, Bezeichnung, Zeitpunkte und ein Ereignisverlauf der letzten 48 Stunden (höchstens 200 Einträge). Keine Standortdaten. Die Kopplung gilt bis zum Widerruf: Ausschalten in der App oder Entfernen im Dashboard löscht sie.
5. Aktionen je Gerät (ratenbegrenzt): Testpush, Live-Activity-Probe, Activity beenden, Neuauswertung (Trockenlauf oder mit Versand), Slot zurücksetzen. Das Dashboard sendet selbst nichts: Der Push-Leader (ein `radar`-Replikat mit Push und Kopplung an) führt den Auftrag innerhalb von etwa 2 Sekunden aus; nach 120 Sekunden ohne Bearbeitung wird er `expired`. Die Probe ignoriert Sperre und Hysterese, damit der Startweg getrennt geprüft werden kann.

Die Datenschutzseite `/datenschutz` beschreibt diese Funktion; der Text muss mit dem Info-Blatt der App übereinstimmen.
