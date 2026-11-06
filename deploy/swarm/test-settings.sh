#!/usr/bin/env bash
# Offline test of settings.sh: whiptail and docker are replaced by stubs on PATH (scripted answers), the .env is a temp file.
# Covers: set/get/list/unset/check, validation, secrets never in the .env, backups without touching .env.bak, comments and unknown
# lines kept, atomic write with mode kept, quoting and shell injection (the file is sourced like update.sh does), menu flows.
# Usage: deploy/swarm/test-settings.sh   (needs bash 4.4+; not part of the deploy branch)
# shellcheck disable=SC2016,SC1090,SC2012  # Testdaten enthalten absichtlich $ und Backticks; .env wird absichtlich gesourct
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DIR="$WORK/repo/deploy/swarm"; mkdir -p "$DIR" "$WORK/bin"
cp "$SRC"/settings.sh "$SRC"/config-registry.tsv "$SRC"/config-extra.tsv "$SRC"/stack.yaml "$SRC"/stack.push.yaml "$DIR/"
cat > "$DIR/swarm-deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "swarm-deploy called STACK=${STACK:-} DB_HOST=${DB_HOST:-}" >> "$STUB_LOG.deploy"
EOF
chmod +x "$DIR/swarm-deploy.sh" "$DIR/settings.sh"
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo x >> "$STUB_LOG.docker"
if [ "$1 $2" = "secret ls" ]; then [ "${STUB_DOCKER:-ok}" = ok ] || exit 1; for s in ${STUB_SECRETS:-}; do echo "$s"; done; exit 0; fi
exit 1
EOF
cat > "$WORK/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" != --infobox ] || exit 0; done  # Hinweisbox ("Docker-Secrets werden geprüft"): keine Antwort nötig
n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_STATE"
{ printf '#%s:' "$n"; printf ' [%s]' "$@"; echo; } >> "$STUB_LOG"
prev=""; for a in "$@"; do [ "$prev" != --textbox ] || cp "$a" "$STUB_LOG.textbox.$n"; prev="$a"; done
line="$(sed -n "${n}p" "$STUB_SCRIPT")"
if [ -z "$line" ]; then echo "stub: script exhausted at call $n" >> "$STUB_LOG"; exit 255; fi
rc="${line%%|*}"; out="${line#*|}"
printf '%b' "$out" >&2
exit "$rc"
EOF
chmod +x "$WORK/bin/docker" "$WORK/bin/whiptail"
export PATH="$WORK/bin:$PATH"

ENVF="$WORK/.env"
fail=0; total=0
check() { # name, command...
  local name="$1"; shift
  total=$((total + 1))
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi
}
fresh() {
  rm -f "$ENVF" "$ENVF".bak*
  cat > "$ENVF" <<'EOF'
# Kommentar oben, bleibt erhalten
RADAR_STACK=radar
DB_HOST=db.example.internal
DB_PORT=3306

# Hinweis zu CACHE_MAX_MB
#CACHE_MAX_MB=64
#HISTORY_HOURS=48
UNKNOWN_THING='keep me'
OPERATOR_NAME="Max \"Muster\" \$HOME"
# Ende
EOF
  chmod 600 "$ENVF"
  export STUB_SECRETS="showernow_db_password showernow_apns_key"
}
S() { ( cd "$DIR" && timeout 30 ./settings.sh --env "$ENVF" "$@" ); }
sha() { cksum < "$ENVF"; }
nbackups() { ls "$ENVF".bak.* 2>/dev/null | wc -l | tr -d ' '; }
# shellcheck disable=SC2317,SC2329  # (SC2317 aeltere, SC2329 neuere shellcheck-Version) wird per declare -f in bash -c Aufrufen genutzt
call_n() { awk -v n="$1" '/^#[0-9]+:/ { p = ($0 ~ "^#" n ":") } p' "$WORK/log"; } # ganzer n-ter whiptail-Aufruf (Argumente mit Zeilenumbruch)
menu() { # Antwortzeilen "RC|Ausgabe" als Argumente; Ausgabe im Menümodus in $WORK/menu.out
  : > "$WORK/script"; for l in "$@"; do printf '%s\n' "$l" >> "$WORK/script"; done
  export STUB_SCRIPT="$WORK/script" STUB_STATE="$WORK/state" STUB_LOG="$WORK/log"
  rm -f "$WORK/state" "$WORK/log" "$WORK"/log.*
  ( cd "$DIR" && PATH="$WORK/bin:$PATH" SETTINGS_ROWS=24 SETTINGS_COLS=80 timeout 30 ./settings.sh --env "$ENVF" > "$WORK/menu.out" 2>&1 < /dev/null ); MENU_RC=$?
}

# ------------------------------------------------------------- Grundfunktionen
fresh
check "help" S --help
printf 'SENTINEL-OLD-BACKUP\n' > "$ENVF.bak"
S --set HISTORY_HOURS=24 >/dev/null
check "set: Kommentarzeile #KEY= wird an Ort und Stelle aktiviert" bash -c "[ \"\$(sed -n 8p '$ENVF')\" = 'HISTORY_HOURS=24' ]"
check "set: get liefert den Wert" bash -c "[ \"\$(cd '$DIR' && ./settings.sh --env '$ENVF' --get HISTORY_HOURS)\" = 24 ]"
check "set: Kommentare und unbekannte Zeilen bleiben" bash -c "grep -qx '# Kommentar oben, bleibt erhalten' '$ENVF' && grep -qx \"UNKNOWN_THING='keep me'\" '$ENVF' && grep -qx '#CACHE_MAX_MB=64' '$ENVF' && grep -qx '# Ende' '$ENVF'"
check "set: Rechte 600 bleiben" bash -c "[ \"\$(stat -c '%a' '$ENVF' 2>/dev/null || stat -f '%Lp' '$ENVF')\" = 600 ]"
check "set: Sicherung .env.bak.JJJJMMTT-HHMMSS angelegt" bash -c "ls '$ENVF'.bak.[0-9]*-[0-9]* >/dev/null 2>&1"
check "set: vorhandene .env.bak bleibt unberuehrt" bash -c "[ \"\$(cat '$ENVF.bak')\" = SENTINEL-OLD-BACKUP ]"
check "set: Sicherung hat Rechte 600" bash -c "for f in '$ENVF'.bak.*; do [ \"\$(stat -c '%a' \"\$f\" 2>/dev/null || stat -f '%Lp' \"\$f\")\" = 600 ] || exit 1; done"
check "set: keine temporaeren Dateien uebrig" bash -c "! ls '$WORK'/.env.settings.* >/dev/null 2>&1"
S --set HISTORY_HOURS=24 >/dev/null; b="$(nbackups)"
check "set: gleicher Wert erzeugt keine neue Sicherung" bash -c "[ '$b' = 1 ]"
S --set CACHE_MAX_MB=128 --set FETCH_WORKERS=2 >/dev/null
check "set: mehrere Werte in einem Lauf" bash -c "grep -qx 'CACHE_MAX_MB=128' '$ENVF' && grep -qx 'FETCH_WORKERS=2' '$ENVF'"
check "set: neue Variable wird angehaengt" bash -c "tail -n1 '$ENVF' | grep -qx 'FETCH_WORKERS=2'"
check "set: normalisiert (Ebenen)" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set 'LAYERS=Clouds, pressure radar' >/dev/null && grep -qx 'LAYERS=pressure,clouds' '$ENVF'"
check "set: Zahl mit Fuehrungsnull" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set HISTORY_HOURS=007 >/dev/null && grep -qx 'HISTORY_HOURS=7' '$ENVF'"

# ------------------------------------------------------------- Ablehnung ungültiger Werte
fresh; before="$(sha)"
for pair in HISTORY_HOURS=99 HISTORY_HOURS=abc HISTORY_HOURS= JITTER_SECONDS=-1 JITTER_SECONDS=1e3 PUSH_ENABLED=yes APNS_ENV=staging \
            APNS_KEY_ID=abc APNS_TOPIC=nodots LAYERS=foo APP_STORE_URL=http://apps.apple.com/x APP_STORE_URL=https://evil.example/x \
            DASH_ORIGIN=http://dash.example.internal DASH_ORIGIN=https://dash.example.internal/path DASH_RP_ID=https://x \
            RADAR_STACK=Bad_Name RADAR_MEMORY_LIMIT=lots UNKNOWN_VAR=1 REPLICA_SLOT=2; do
  S --set "$pair" >/dev/null 2>&1; rc=$?
  check "ablehnen: $pair" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ]"
done
S --set $'OPERATOR_NAME=zwei\nzeilen' >/dev/null 2>&1; rc=$?
check "ablehnen: Zeilenumbruch im Wert" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ]"
check "ablehnen: keine Sicherung bei Fehlern" bash -c "[ '$(nbackups)' = 0 ]"
S --set HISTORY_HOURS=99 --set CACHE_MAX_MB=128 >/dev/null 2>&1
check "ablehnen: ein ungueltiger Wert verhindert den ganzen Lauf" bash -c "[ '$(sha)' = '$before' ] && ! grep -q 'CACHE_MAX_MB=128' '$ENVF'"

# ------------------------------------------------------------- Zurücksetzen
fresh
S --set HISTORY_HOURS=24 >/dev/null
S --unset HISTORY_HOURS >/dev/null
check "unset: Zeile wird auskommentiert, Wert bleibt lesbar" grep -qx '#HISTORY_HOURS=24' "$ENVF"
check "unset: get liefert den Default" bash -c "[ \"\$(cd '$DIR' && ./settings.sh --env '$ENVF' --get HISTORY_HOURS)\" = 48 ]"
check "unset: nicht gesetzte Variable ist kein Fehler" S --unset CACHE_MAX_MB
check "unset: unbekannte Variable wird abgelehnt" bash -c "! (cd '$DIR' && ./settings.sh --env '$ENVF' --unset NOPE_X >/dev/null 2>&1)"

# ------------------------------------------------------------- Geheimnisse
fresh; before="$(sha)"
for pair in DB_PASSWORD=geheim123 APNS_KEY=geheim123 MY_API_TOKEN=geheim123 SOME_SECRET=geheim123; do
  S --set "$pair" >"$WORK/out" 2>&1; rc=$?
  check "Geheimnis: $pair abgelehnt, Datei unveraendert" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ]"
done
check "Geheimnis: Wert taucht nie in .env oder Ausgabe auf" bash -c "! grep -rq geheim123 '$ENVF' '$WORK/out'"
check "Geheimnis: Hinweis nennt docker secret create" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set DB_PASSWORD=x 2>&1 | grep -q 'docker secret create showernow_db_password'"
check "Geheimnis: --get verweigert" bash -c "! (cd '$DIR' && ./settings.sh --env '$ENVF' --get DB_PASSWORD >/dev/null 2>&1)"
printf 'DB_PASSWORD=hunter2\nFOO_TOKEN=abc123\n' >> "$ENVF"
check "Geheimnis in der .env: --check meldet Fehler" bash -c "! (cd '$DIR' && ./settings.sh --env '$ENVF' --check >/dev/null 2>&1)"
check "Geheimnis in der .env: --list zeigt keinen Wert" bash -c "! (cd '$DIR' && PATH='$WORK/bin:$PATH' ./settings.sh --env '$ENVF' --list | grep -q 'hunter2\|abc123')"
check "Geheimnis in der .env: --check gibt keinen Wert aus" bash -c "! (cd '$DIR' && ./settings.sh --env '$ENVF' --check 2>&1 | grep -q 'hunter2\|abc123')"
S --set HISTORY_HOURS=30 >/dev/null
check "Geheimnis in der .env: andere Aenderung beruehrt die Zeile nicht" grep -qx 'DB_PASSWORD=hunter2' "$ENVF"
S --unset DB_PASSWORD >/dev/null
check "Geheimnis in der .env: --unset loescht die Zeile (kein Kommentar mit Wert)" bash -c "! grep -q 'hunter2' '$ENVF' && grep -qx 'FOO_TOKEN=abc123' '$ENVF'"

# ------------------------------------------------------------- Quoting und Injektion
fresh
rm -f "$WORK/PWNED"
i=0
for v in 'a $(touch '"$WORK"'/PWNED) b' '`touch '"$WORK"'/PWNED`' 'x"y'"'"'z' 'back\slash \n literal' 'semi; touch '"$WORK"'/PWNED' '$HOME ${PATH} ~ * ?' '  lead and trail  ' '#hash' 'ä ö ü €'; do
  i=$((i + 1))
  S --set "OPERATOR_NAME=$v" >/dev/null 2>&1
  got="$( set -a; . "$ENVF"; printf '%s' "$OPERATOR_NAME" )"
  want="$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  check "Quoting $i: gesourcter Wert identisch" bash -c "[ \"\$1\" = \"\$2\" ]" _ "$got" "$want"
  check "Quoting $i: --get liest denselben Wert" bash -c "[ \"\$(cd '$DIR' && ./settings.sh --env '$ENVF' --get OPERATOR_NAME)\" = \"\$1\" ]" _ "$want"
  check "Quoting $i: keine Shell-Ausfuehrung" bash -c "[ ! -e '$WORK/PWNED' ]"
done
fresh
check "Lesen: Original mit \\\" und \\\$ wird entquotet" bash -c "[ \"\$(cd '$DIR' && ./settings.sh --env '$ENVF' --get OPERATOR_NAME)\" = 'Max \"Muster\" \$HOME' ]"
check "Lesen: --check warnt vor \$ im Wert nicht bei einfach gequotetem Wert" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set 'OPERATOR_NAME=\$HOME' >/dev/null && ! ./settings.sh --env '$ENVF' --check 2>&1 | grep -q 'enthält \$'"
printf 'OPERATOR_EMAIL=$(id)\n' >> "$ENVF"
check "--check warnt bei Shell-Ausdruck in der Datei" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --check 2>&1 | grep -q 'OPERATOR_EMAIL.*Backtick'"

# ------------------------------------------------------------- --check
fresh
check "check: saubere Datei ohne Fehler" S --check
printf 'FANCY_THING=1\n' >> "$ENVF"
check "check: unbekannte Variable ist Warnung, kein Fehler" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --check 2>&1 | grep -q 'WARNUNG.*FANCY_THING' && ./settings.sh --env '$ENVF' --check >/dev/null"
printf 'HISTORY_HOURS=500\n' >> "$ENVF"
check "check: Grenzverletzung ist Fehler (Exit 1)" bash -c "cd '$DIR' && ! ./settings.sh --env '$ENVF' --check >/dev/null 2>&1"
fresh; printf 'PUSH_ENABLED=true\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "check: PUSH_ENABLED=true ohne APNS-Werte ist Fehler" bash -c "[ $rc -ne 0 ] && grep -q 'APNS_KEY_ID fehlt' <<< \"\$1\" && grep -q 'APNS_TOPIC fehlt' <<< \"\$1\"" _ "$out"
printf 'APNS_KEY_ID=ABCDE12345\nAPNS_TEAM_ID=ZYXWV98765\nAPNS_TOPIC=de.example.app\n' >> "$ENVF"
check "check: PUSH mit allen Werten und Secret ist sauber" S --check
export STUB_SECRETS="showernow_db_password"
out="$(S --check 2>&1)"; rc=$?
check "check: fehlendes APNs-Secret ist Fehler" bash -c "[ $rc -ne 0 ] && grep -q 'showernow_apns_key. fehlt\|Secret showernow_apns_key fehlt' <<< \"\$1\"" _ "$out"
export STUB_SECRETS="showernow_apns_key"
check "check: fehlendes DB-Secret ist Fehler" bash -c "! (cd '$DIR' && ./settings.sh --env '$ENVF' --check >/dev/null 2>&1)"
export STUB_SECRETS="showernow_db_password showernow_apns_key"
printf 'IMAGE_WIDTH=512\n' >> "$ENVF"
check "check: PUSH mit IMAGE_WIDTH != 1024 ist Fehler" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --check 2>&1 | grep -q 'IMAGE_WIDTH=1024'"
fresh
export STUB_DOCKER=down
out="$(S --check 2>&1)"; rc=$?
check "check: ohne docker nur Warnung 'unbekannt'" bash -c "[ $rc -eq 0 ] && grep -q 'konnte nicht geprüft werden' <<< \"\$1\"" _ "$out"
unset STUB_DOCKER
printf 'DASH_ENABLED=true\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "check: DASH_ENABLED ohne DASH_ORIGIN ist Fehler" bash -c "[ $rc -ne 0 ] && grep -q 'DASH_ORIGIN fehlt' <<< \"\$1\"" _ "$out"
check "check: Dashboard ohne Overlay: Warnung 'noch nicht verfuegbar'" bash -c "grep -q 'Dashboard noch nicht verfügbar in dieser Version' <<< \"\$1\"" _ "$out"
printf 'DASH_ORIGIN=https://dash.example.internal\n' >> "$ENVF"
grep -v '^# dashboard-command' "$SRC/stack.dashboard.yaml" > "$DIR/stack.dashboard.yaml"
out="$(S --check 2>&1)"; rc=$?
check "check: mit Overlay entfaellt die Dashboard-Warnung" bash -c "[ $rc -eq 0 ] && ! grep -q 'noch nicht verfügbar' <<< \"\$1\"" _ "$out"
check "check: Overlay ohne Befehlsmarke: Hinweis (kein Fehler, keine Warnung)" bash -c "grep -q '^HINWEIS .*Dienstbefehl folgt (WP5)' <<< \"\$1\" && ! grep '^WARNUNG' <<< \"\$1\" | grep -qv UNKNOWN_THING" _ "$out"
cp "$SRC/stack.dashboard.yaml" "$DIR/stack.dashboard.yaml"
check "overlay: Repo-Overlay traegt die Marke ready" grep -q '^# dashboard-command: ready$' "$SRC/stack.dashboard.yaml"
out="$(S --check 2>&1)"; rc=$?
check "check: Overlay mit Marke 'ready': kein Hinweis mehr" bash -c "[ $rc -eq 0 ] && ! grep -q 'HINWEIS' <<< \"\$1\"" _ "$out"
rm -f "$DIR/stack.dashboard.yaml"
fresh; printf 'DASH_ORIGIN=https://dash.example.internal\nDASH_RP_ID=other.example\n' >> "$ENVF"
check "set: DASH_RP_ID muss Suffix des Origin-Hosts sein" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set DASH_RP_ID=example.internal >/dev/null && ! ./settings.sh --env '$ENVF' --set DASH_RP_ID=evil.example >/dev/null 2>&1"

# ------------------------------------------------------------- --list
fresh
out="$(S --list 2>&1)"
check "list: Kopfzeile und Quellen" bash -c "grep -q '^VARIABLE' <<< \"\$1\" && grep -Eq '^HISTORY_HOURS +48 +48 +Default' <<< \"\$1\" && grep -Eq '^DB_HOST +db.example.internal .* Datei' <<< \"\$1\"" _ "$out"
check "list: unbekannte Variable gekennzeichnet" bash -c "grep -q 'UNKNOWN_THING.*unbekannt' <<< \"\$1\"" _ "$out"
check "list: alle Tabellenzeilen (>= 70 Variablen)" bash -c "[ \$(grep -c . <<< \"\$1\") -ge 70 ]" _ "$out"

# ------------------------------------------------------------- Menüführung (whiptail-Stub)
# Ablauf: Hauptmenü (Tag = Gruppenname) -> Gruppe (Tag = KEY) -> direkt Eingabe/Auswahl (kein Zwischenmenü), Esc/Zurück = "1|".
fresh
menu '0|Radar & Cache' '0|HISTORY_HOURS' '0|abc' '0|' '0|30' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "menue: Eingabe-Ablauf endet normal" bash -c "[ $MENU_RC -eq 0 ] && ! grep -q 'script exhausted' '$WORK/log'"
check "menue: ungueltige Eingabe 'abc' wird mit Fehlerbox abgelehnt und erneut gefragt" bash -c "grep -q 'HISTORY_HOURS: muss eine ganze Zahl sein' '$WORK/log'"
check "menue: nach dem Fehler steht 'abc' wieder im selben Eingabefeld" bash -c "$(declare -f call_n); WORK='$WORK'; call_n 5 | grep -q -- '--inputbox' && call_n 5 | grep -q '\[abc\]\$'"
check "menue: Fehlerbox ohne --scrolltext (Enter schliesst sie)" bash -c "grep '^#4:' '$WORK/log' | grep -q 'msgbox' && ! grep '^#4:' '$WORK/log' | grep -q 'scrolltext'"
check "menue: gespeichert" grep -qx 'HISTORY_HOURS=30' "$ENVF"
check "menue: Diff-Uebersicht zeigt Aenderung" bash -c "grep -q 'HISTORY_HOURS: (Default: 48)  ->  30' '$WORK/log'"
check "menue: Uebersicht nennt die Wirkung (live) und den Rollout" bash -c "grep -q 'WIRKUNG' '$WORK/log' && grep -q 'HISTORY_HOURS: live' '$WORK/log' && grep -q 'Rolling Update' '$WORK/log'"
check "menue: Titel mit Pfad Einstellungen > Gruppe > KEY" bash -c "grep -Eq 'Einstellungen (>|›) Radar & Cache (>|›) HISTORY_HOURS' '$WORK/log'"
check "menue: nach der Aenderung bleibt die Auswahl auf dem bearbeiteten Eintrag" bash -c "grep '^#6:' '$WORK/log' | grep -q -- '--default-item.*\[HISTORY_HOURS\]'"
check "menue: Hilfetext aus dem Register im Eingabedialog" bash -c "grep '^#3:' '$WORK/log' | grep -q 'Stunden Radar-Historie'"
check "menue: Sicherung angelegt" bash -c "[ '$(nbackups)' = 1 ]"

fresh; S --set HISTORY_HOURS=24 >/dev/null; rm -f "$ENVF".bak.*
menu '0|Radar & Cache' '0|HISTORY_HOURS' '0|' '0|' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "menue: leere Eingabe + Ja setzt auf Default zurueck (Zeile auskommentiert)" grep -qx '#HISTORY_HOURS=24' "$ENVF"
fresh; before="$(sha)"
menu '0|Radar & Cache' '0|HISTORY_HOURS' '0|24' '1|' '1|' '0|V'
check "menue: leere/gleiche Eingaben ohne Aenderung" bash -c "[ '$(sha)' = '$before' ]"

# Kleine Zahlenbereiche und Auswahl statt Freitext
fresh
menu '0|Geräte-Kopplung' '0|DASH_MAX_DEVICES' '0|2' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "menue: DASH_MAX_DEVICES (1 bis 5) als Auswahlliste, gespeichert" bash -c "grep -qx 'DASH_MAX_DEVICES=2' '$ENVF' && $(declare -f call_n); WORK='$WORK'; call_n 3 | grep -q -- '--menu' && call_n 3 | grep -q '<- aktuell'"
fresh
menu '0|Push' '0|APNS_ENV' '0|sandbox' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "menue: Aufzaehlung APNS_ENV als Auswahlliste" bash -c "grep -qx 'APNS_ENV=sandbox' '$ENVF'"

fresh; before="$(sha)"
menu '0|Datenbank & Dienst' '0|DB_PASSWORD' '0|' '1|' '1|'
check "menue: Geheimnis zeigt Hinweis mit docker secret create, Datei unveraendert" bash -c "grep -q 'docker secret create showernow_db_password' '$WORK/log' && grep -q 'vorhanden' '$WORK/log' && [ '$(sha)' = '$before' ] && [ $MENU_RC -eq 0 ]"
fresh
menu '0|Push' '0|APNS_KEY' '0|' '1|' '1|'
check "menue: APNs-Hinweis nennt .p8" bash -c "grep -q 'docker secret create showernow_apns_key /pfad/AuthKey' '$WORK/log'"
export STUB_SECRETS="x"
menu '0|Datenbank & Dienst' '1|' '1|'
check "menue: Secret-Zeile zeigt 'fehlt' wenn docker ls ohne das Secret laeuft" bash -c "grep -q 'Secret fehlt' '$WORK/log'"
export STUB_DOCKER=down
menu '0|Datenbank & Dienst' '1|' '1|'
check "menue: Secret-Zeile zeigt 'unbekannt' ohne docker" bash -c "grep -q 'Secret unbekannt' '$WORK/log'"
unset STUB_DOCKER; export STUB_SECRETS="showernow_db_password showernow_apns_key"
# Latenz: docker secret ls hoechstens einmal je Sitzung, nicht bei jedem Menueaufbau
fresh
menu '0|Datenbank & Dienst' '1|' '0|Datenbank & Dienst' '1|' '0|Push' '1|' '0|Datenbank & Dienst' '1|' '1|'
check "menue: docker secret ls nur einmal je Sitzung trotz mehrfachem Menueaufbau" bash -c "[ \$(grep -c . '$WORK/log.docker') -eq 1 ]"
check "cli: --list ruft docker secret ls nur einmal" bash -c "rm -f '$WORK/log.docker'; export STUB_LOG='$WORK/log'; cd '$DIR' && ./settings.sh --env '$ENVF' --list >/dev/null && [ \$(grep -c . '$WORK/log.docker') -eq 1 ]"

# Dashboard aktivieren (Overlay fehlt: 'vorbereitet')
fresh
menu '0|Dashboard' '0|DASH_ENABLED' '0|true' '0|' '0|' '0|https://Dash.Example.internal' '0|' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "dashboard: Menue zeigt 'vorbereitet'" bash -c "grep -q 'vorbereitet (Overlay noch nicht vorhanden)' '$WORK/log'"
check "dashboard: Voraussetzungen und Reset-Befehl angezeigt" bash -c "grep -q 'radar dashboard-reset --yes' '$WORK/log' && grep -q 'Host-Header unverändert' '$WORK/log'"
check "dashboard: DASH_ENABLED, ORIGIN (kleingeschrieben) und RP_ID gespeichert" bash -c "grep -qx 'DASH_ENABLED=true' '$ENVF' && grep -qx 'DASH_ORIGIN=https://dash.example.internal' '$ENVF' && grep -qx 'DASH_RP_ID=dash.example.internal' '$ENVF'"
check "dashboard: Diff zeigt Warnung 'noch nicht verfuegbar'" bash -c "grep -q 'Dashboard noch nicht verfügbar' '$WORK/log'"
check "dashboard: nach dem Speichern Hinweis auf Setup-Fenster und Aufruf-Adresse" bash -c "grep -q 'Setup-Fenster: 15 Minuten' '$WORK/log' && grep -q 'Aufruf unter https://dash.example.internal' '$WORK/log'"
check "dashboard: Hinweis nennt Proxy-Ziel-Port 39090, Firewall und sofortigen Passkey" bash -c "grep -q 'Port 39090 (Container-Port 9090)' '$WORK/log' && grep -q 'Firewall: Port nur' '$WORK/log' && grep -q 'SOFORT' '$WORK/log'"
fresh; before="$(sha)"
menu '0|Dashboard' '0|DASH_ENABLED' '0|true' '0|' '0|' '1|' '0|' '1|' '1|'
check "dashboard: Abbruch bei DASH_ORIGIN laesst DASH_ENABLED aus" bash -c "[ '$(sha)' = '$before' ] && ! grep -q DASH_ENABLED '$ENVF'"
menu '0|Dashboard-Schwellen' '1|' '1|'
check "menue: Gruppe Dashboard-Schwellen vorhanden (DASH_WARN_*, DASH_MIN_GROUP)" bash -c "grep -q 'DASH_WARN_CACHE_HIT_RED' '$WORK/log' && grep -q 'DASH_MIN_GROUP' '$WORK/log'"

# Verwerfen beim Beenden, Suche, Anwenden
fresh; before="$(sha)"
menu '0|Radar & Cache' '0|HISTORY_HOURS' '0|30' '1|' '1|' '0|V'
check "menue: Verwerfen beim Beenden aendert nichts" bash -c "[ '$(sha)' = '$before' ] && [ $MENU_RC -eq 0 ]"
menu '0|Suchen' '0|stagger' '0|RESTART_STAGGER_SECONDS' '1|' '1|' '1|' '1|'
check "menue: Suche findet RESTART_STAGGER_SECONDS" bash -c "grep -q 'RESTART_STAGGER_SECONDS' '$WORK/log' && ! grep -q 'script exhausted' '$WORK/log'"
menu '0|Suchen' '0|stagger' '0|RESTART_STAGGER_SECONDS' '0|60' '1|' '1|' '1|' '0|V'
check "menue: Suchergebnis nach Bearbeitung neu aufgebaut, Auswahl bleibt (default-item)" bash -c "$(declare -f call_n); WORK='$WORK'; call_n 5 | grep -q -- '--default-item.*\[RESTART_STAGGER_SECONDS\]' && call_n 5 | grep -q '60 s'"
fresh
menu '0|Anwenden' '0|S' '1|' '1|'
check "anwenden: ohne Bestaetigung wird nicht ausgerollt" bash -c "[ ! -e '$WORK/log.deploy' ]"
menu '0|Anwenden' '0|S' '0|' '1|'
check "anwenden: mit Bestaetigung ruft swarm-deploy.sh mit Stack und .env-Werten auf" bash -c "grep -q 'STACK=radar DB_HOST=db.example.internal' '$WORK/log.deploy'"
fresh; printf 'HISTORY_HOURS=500\n' >> "$ENVF"
menu '0|Anwenden' '0|' '1|'
check "anwenden: bei Pruefungsfehlern wird nicht ausgerollt" bash -c "[ ! -e '$WORK/log.deploy' ] && grep -q 'FEHLER\|Fehler' '$WORK/log'"

# ------------------------------------------------------------- whiptail fehlt
fresh
nowt="$WORK/nowt"; mkdir -p "$nowt"; ln -sf "$(command -v bash)" "$nowt/bash"
for t in env dirname cat awk sed sort tr date cp chmod mv stat mktemp rm timeout readlink diff tail grep; do ln -sf "$(command -v $t)" "$nowt/$t" 2>/dev/null || true; done
out="$( cd "$DIR" && PATH="$nowt" "$nowt/bash" ./settings.sh --env "$ENVF" 2>&1 )"; rc=$?
check "ohne whiptail/dialog: klare Meldung, Exit 1" bash -c "[ $rc -eq 1 ] && grep -q 'whiptail (oder dialog) fehlt' <<< \"\$1\"" _ "$out"

echo "---- $total Pruefungen, $([ "$fail" = 0 ] && echo 'alle bestanden' || echo 'FEHLER')"
exit "$fail"
