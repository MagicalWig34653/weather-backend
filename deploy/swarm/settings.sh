#!/usr/bin/env bash
# Einstellungen der .env per Menü (whiptail, wie raspi-config) oder per Kommandozeile bearbeiten.
#
# Aufruf: deploy/swarm/settings.sh [Optionen]
#   (ohne Aktion)     Menü starten (braucht whiptail oder dialog)
#   --env PFAD        .env-Datei (Standard: ../../.env, vom Skriptordner aus gesehen)
#   --list            alle Variablen mit Wert, Default und Quelle
#   --get KEY         Wert einer Variablen ausgeben (Geheimnisse nie)
#   --set KEY=VALUE   Wert prüfen und speichern (mit Sicherung); mehrfach möglich
#   --unset KEY       Variable auskommentieren (zurück auf den Default); mehrfach möglich
#   --check           gesamte .env prüfen (Typ, Grenzen, Konflikte, unbekannte Variablen, Secrets)
#   -h, --help        diese Hilfe
#
# Quelle der Metadaten: config-registry.tsv (aus dem Swift-Register erzeugt) und config-extra.tsv (Deploy-Variablen).
# Geheimnisse (DB_PASSWORD, APNS_KEY) werden nie angezeigt oder in die .env geschrieben: sie liegen als Docker-Secret.
# Gespeichert wird atomar; vorher entsteht eine Sicherung .env.bak.JJJJMMTT-HHMMSS (eine vorhandene .env.bak bleibt unberührt).
# Es wird nichts ausgerollt, solange man es nicht im Menü ("Jetzt anwenden") bestätigt.
# shellcheck disable=SC1003,SC2016  # Backslash und $ stehen absichtlich in einfachen Anführungszeichen
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "settings.sh braucht Bash 4.4 oder neuer (gefunden: ${BASH_VERSION})." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV_REGISTRY="${SETTINGS_REGISTRY:-$SCRIPT_DIR/config-registry.tsv}"
TSV_EXTRA="${SETTINGS_EXTRA:-$SCRIPT_DIR/config-extra.tsv}"
ENV_FILE=""
DASH_OVERLAY="$SCRIPT_DIR/stack.dashboard.yaml"
# The overlay carries a marker line "# dashboard-command: ready" once the image knows `radar dashboard` (WP5); until then the
# overlay exists but the service command is still missing ("Overlay vorhanden, Dienstbefehl folgt (WP5)": a hint, no error).
dash_command_ready() { [ -f "$DASH_OVERLAY" ] && grep -q '^# dashboard-command: ready' "$DASH_OVERLAY"; }
dash_prepared_text() { # Zustand des Dashboards: leer = bereit
  if [ ! -f "$DASH_OVERLAY" ]; then echo "vorbereitet (Overlay noch nicht vorhanden)"
  elif ! dash_command_ready; then echo "Overlay vorhanden, Dienstbefehl folgt (WP5)"; fi
}
BACKTITLE="Showers Radar-Backend: Einstellungen"
# Variablen, die das System setzt (Image, Swarm); in der .env sinnlos.
SYSTEM_KEYS=" REPLICA_SLOT BUILD_REVISION MIGRATIONS_DIR HTTP_PORT "

die() { echo "Fehler: $*" >&2; exit 1; }

# ---------------------------------------------------------------- Tabellen
declare -a KEYS=()
declare -A T_GROUP=() T_TYPE=() T_DEF=() T_UNIT=() T_MIN=() T_MAX=() T_CHOICES=() T_APPLY=() T_SECRET=() T_SUM=() T_SRC=()

load_table() { # Datei Quelle
  local f="$1" src="$2" k g ty d u mn mx ch ap se sm
  [ -r "$f" ] || die "Tabelle fehlt: $f (der Deploy-Branch enthält config-registry.tsv und config-extra.tsv)"
  # Unit Separator als Trenner: Tabulatoren würden leere Felder zusammenziehen.
  while IFS=$'\x1f' read -r k g ty d u mn mx ch ap se sm; do
    [ -n "$k" ] || continue
    if [ -n "${T_GROUP[$k]+x}" ]; then continue; fi
    KEYS+=("$k")
    T_GROUP[$k]="$g"; T_TYPE[$k]="$ty"; T_DEF[$k]="$d"; T_UNIT[$k]="$u"; T_MIN[$k]="$mn"; T_MAX[$k]="$mx"
    T_CHOICES[$k]="$ch"; T_APPLY[$k]="$ap"; T_SECRET[$k]="$se"; T_SUM[$k]="$sm"; T_SRC[$k]="$src"
  done < <(awk -F'\t' -v OFS='\037' '!/^#/ && NF >= 11 { $1 = $1; print }' "$f")
}

load_tables() {
  load_table "$TSV_REGISTRY" registry
  load_table "$TSV_EXTRA" extra
}

# Geheimnis-Variable? Tabelle entscheidet; unbekannte Namen mit PASSWORD/KEY/SECRET/TOKEN gelten vorsichtshalber als Geheimnis.
is_secretlike() {
  local k="$1"
  if [ -n "${T_SECRET[$k]+x}" ]; then [ "${T_SECRET[$k]}" = 1 ]; return; fi
  local up="${k^^}"
  [[ $up == *PASSWORD* || $up == *PASSWD* || $up == *SECRET* || $up == *KEY* || $up == *TOKEN* || $up == *CREDENTIAL* ]]
}
is_system_key() { [[ $SYSTEM_KEYS == *" $1 "* ]]; }
is_ignored_key() { [[ $1 == DEV_* ]]; }

apply_label() {
  local k="$1"
  if is_system_key "$k"; then echo "System"; return; fi
  if [ "${T_SECRET[$k]}" = 1 ]; then echo "Secret"; return; fi
  if [ "$k" = DASH_ENABLED ] && [ ! -f "$DASH_OVERLAY" ]; then echo "vorbereitet"; return; fi
  if [ "$k" = DASH_ENABLED ] && ! dash_command_ready; then echo "Befehl folgt"; return; fi
  case "${T_APPLY[$k]}" in
    live) echo "live" ;;
    restart) echo "Neustart" ;;
    *) echo "nur ENV" ;;
  esac
}

STACK_TEXT=""
load_stack_text() { STACK_TEXT="$(cat "$SCRIPT_DIR"/stack*.yaml 2>/dev/null || true)"; }
# Reicht der Stack die Variable an den Dienst durch? (Ohne Stack-Dateien: ja annehmen.)
passes_through() {
  local k="$1"
  [ -n "$STACK_TEXT" ] || return 0
  [ "$k" = DASH_ENABLED ] && return 0 # wird von swarm-deploy.sh/update.sh ausgewertet (Overlay-Auswahl), nicht vom Dienst
  [[ $STACK_TEXT == *'${'"$k"':'* || $STACK_TEXT == *'${'"$k"'}'* ]]
}

# ---------------------------------------------------------------- .env lesen
declare -a ENV_LINES=()
declare -A ENV_VAL=() ENV_COUNT=() ENV_EXPR=() ENV_BADMSG=()
declare -A PEND_SET=() PEND_UNSET=()
ENV_EXISTS=0
PV=""; UQ_BAD=""; UQ_EXPR=0

# Wert einer Zeile "KEY=<rest>" wie die Shell auflösen, aber ohne etwas auszuführen oder zu expandieren.
unquote() {
  local s="$1" out="" i=0 n c nc rest part closed
  n=${#s}; PV=""; UQ_BAD=""; UQ_EXPR=0
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    case "$c" in
      "'")
        rest="${s:i+1}"
        if [[ $rest != *"'"* ]]; then UQ_BAD="Anführungszeichen nicht geschlossen"; PV="$s"; return 0; fi
        part="${rest%%\'*}"; out+="$part"; i=$((i + ${#part} + 2)) ;;
      '"')
        i=$((i + 1)); closed=0
        while [ "$i" -lt "$n" ]; do
          c="${s:i:1}"
          if [ "$c" = '\' ]; then
            nc="${s:i+1:1}"
            case "$nc" in
              '$'|'`'|'"'|'\') out+="$nc"; i=$((i + 2)) ;;
              *) out+='\'; i=$((i + 1)) ;;
            esac
          elif [ "$c" = '"' ]; then closed=1; i=$((i + 1)); break
          else
            if [ "$c" = '$' ] || [ "$c" = '`' ]; then UQ_EXPR=1; fi
            out+="$c"; i=$((i + 1))
          fi
        done
        if [ "$closed" = 0 ]; then UQ_BAD="Anführungszeichen nicht geschlossen"; PV="$s"; return 0; fi ;;
      '\')
        nc="${s:i+1:1}"
        if [ -z "$nc" ]; then out+='\'; i=$((i + 1)); else out+="$nc"; i=$((i + 2)); fi ;;
      ' '|$'\t')
        rest="${s:i}"; rest="${rest#"${rest%%[![:space:]]*}"}"
        if [ -n "$rest" ] && [ "${rest:0:1}" != '#' ]; then UQ_BAD="Text nach dem Wert (die Shell würde ihn als Befehl ausführen)"; fi
        break ;;
      '$'|'`') UQ_EXPR=1; out+="$c"; i=$((i + 1)) ;;
      *) out+="$c"; i=$((i + 1)) ;;
    esac
  done
  PV="$out"
}

readonly ASSIGN_RE='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'

env_load() {
  local line key
  ENV_LINES=(); ENV_VAL=(); ENV_COUNT=(); ENV_EXPR=(); ENV_BADMSG=(); ENV_EXISTS=0
  [ -f "$ENV_FILE" ] || return 0
  ENV_EXISTS=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    ENV_LINES+=("$line")
    if [[ $line =~ $ASSIGN_RE ]]; then
      key="${BASH_REMATCH[2]}"
      unquote "${BASH_REMATCH[3]}"
      ENV_VAL[$key]="$PV"
      ENV_COUNT[$key]=$(( ${ENV_COUNT[$key]:-0} + 1 ))
      if [ "$UQ_EXPR" = 1 ]; then ENV_EXPR[$key]=1; else unset 'ENV_EXPR[$key]'; fi
      if [ -n "$UQ_BAD" ]; then ENV_BADMSG[$key]="$UQ_BAD"; else unset 'ENV_BADMSG[$key]'; fi
    fi
  done < "$ENV_FILE"
}

# Wert so schreiben, dass `. .env` ihn unverändert liest: nur unkritische Zeichen unquotiert, sonst in einfachen Anführungszeichen.
shquote() {
  local v="$1" q="'\\''"
  if [[ $v =~ ^[A-Za-z0-9_@%+=:,./-]*$ ]]; then printf '%s' "$v"; else printf "'%s'" "${v//\'/$q}"; fi
}

# ---------------------------------------------------------------- wirksamer Zustand (Datei + offene Änderungen)
in_file() { [ -n "${ENV_VAL[$1]+x}" ] && [ -n "${ENV_VAL[$1]}" ]; }

is_set() {
  if [ -n "${PEND_UNSET[$1]+x}" ]; then return 1; fi
  if [ -n "${PEND_SET[$1]+x}" ]; then return 0; fi
  in_file "$1"
}
eff_value() {
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then printf '%s' "${T_DEF[$k]-}"
  elif [ -n "${PEND_SET[$k]+x}" ]; then printf '%s' "${PEND_SET[$k]}"
  elif in_file "$k"; then printf '%s' "${ENV_VAL[$k]}"
  else printf '%s' "${T_DEF[$k]-}"; fi
}
queue_set() { # KEY WERT (bereits geprüft)
  unset 'PEND_UNSET[$1]'
  if [ -z "${PEND_SET[$1]+x}" ] && in_file "$1" && [ "${ENV_VAL[$1]}" = "$2" ]; then return 0; fi
  PEND_SET[$1]="$2"
}
queue_unset() {
  local k="$1"
  unset 'PEND_SET[$k]'
  if [ -n "${ENV_COUNT[$k]+x}" ]; then PEND_UNSET[$k]=1; fi
}
pending_count() { echo $(( ${#PEND_SET[@]} + ${#PEND_UNSET[@]} )); }

# ---------------------------------------------------------------- Validierung
V_OUT=""; V_ERR=""

validate() { # KEY WERT -> V_OUT (normalisiert) / V_ERR; Rückgabe 0 = gültig
  local LC_ALL=C
  local key="$1" val="$2" type base rule lo hi n t
  type="${T_TYPE[$key]}"; base="${type%%:*}"; rule=""; [[ $type == *:* ]] && rule="${type#*:}"
  lo="${T_MIN[$key]}"; hi="${T_MAX[$key]}"
  V_OUT=""; V_ERR=""
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  if [[ $val =~ [[:cntrl:]] ]]; then V_ERR="Steuerzeichen und Zeilenumbrüche sind nicht erlaubt"; return 1; fi
  if [ -z "$val" ]; then V_ERR="leerer Wert; zum Entfernen 'Auf Default zurücksetzen' verwenden"; return 1; fi
  case "$base" in
    int)
      if ! [[ $val =~ ^[0-9]{1,12}$ ]]; then V_ERR="muss eine ganze Zahl sein"; return 1; fi
      n=$((10#$val))
      if [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; then V_ERR="muss zwischen $lo und $hi liegen"; return 1; fi
      V_OUT="$n" ;;
    number)
      if ! [[ $val =~ ^[0-9]{1,9}(\.[0-9]{1,6})?$ ]]; then V_ERR="muss eine Zahl sein (Dezimalpunkt)"; return 1; fi
      if ! awk -v v="$val" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }'; then
        V_ERR="muss zwischen $lo und $hi liegen"; return 1
      fi
      V_OUT="$(awk -v v="$val" 'BEGIN { printf "%.6g", v + 0 }')" ;;
    bool)
      t="${val,,}"
      if [ "$t" != true ] && [ "$t" != false ]; then V_ERR="muss true oder false sein"; return 1; fi
      V_OUT="$t" ;;
    choice)
      t="${val,,}"
      if [[ "|${T_CHOICES[$key]}|" != *"|$t|"* ]]; then V_ERR="erlaubt: ${T_CHOICES[$key]//|/, }"; return 1; fi
      V_OUT="$t" ;;
    layers)
      local tok out="" known="${T_CHOICES[$key]}" item
      t="${val,,}"; t="${t//,/ }"
      for tok in $t; do
        [ "$tok" = radar ] && continue
        if [[ "|$known|" != *"|$tok|"* ]]; then V_ERR="unbekannte Ebene '$tok' (erlaubt: radar, ${known//|/, })"; return 1; fi
      done
      IFS='|' read -ra _order <<< "$known"
      for item in "${_order[@]}"; do
        for tok in $t; do if [ "$tok" = "$item" ]; then out+="${out:+,}$item"; break; fi; done
      done
      V_OUT="${out:-radar}" ;;
    text)
      if [ "${#val}" -gt "$hi" ]; then V_ERR="höchstens $hi Zeichen"; return 1; fi
      case "$rule" in
        printableASCII) [[ $val =~ ^[\ -~]+$ ]] || { V_ERR="nur druckbare ASCII-Zeichen"; return 1; } ;;
        apnsIdentifier) [[ $val =~ ^[A-Z0-9]{10}$ ]] || { V_ERR="genau 10 Zeichen A bis Z und 0 bis 9"; return 1; } ;;
        bundleIdentifier)
          [[ $val =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
            || { V_ERR="ungültige Bundle-ID (z. B. de.example.app)"; return 1; } ;;
        stackname) [[ $val =~ ^[a-z][a-z0-9-]*$ ]] || { V_ERR="Stack-Name: Kleinbuchstaben, Ziffern, Bindestrich; beginnt mit Buchstabe"; return 1; } ;;
        imagetag) [[ $val =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { V_ERR="ungültiges Image-Tag"; return 1; } ;;
        memlimit) [[ $val =~ ^[0-9]+[bBkKmMgG]?$ ]] || { V_ERR="Zahl mit optionaler Einheit, z. B. 512M, 0 = unbegrenzt"; return 1; } ;;
        secretname) [[ $val =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { V_ERR="ungültiger Secret-Name"; return 1; } ;;
        *) ;;
      esac
      V_OUT="$val" ;;
    url)
      local want="" host=""
      [[ $rule == *.* ]] && want="$rule"
      if [ "${#val}" -gt "$hi" ] || [[ $val =~ [[:space:]] ]]; then V_ERR="https-Adresse ohne Leerzeichen, höchstens $hi Zeichen"; return 1; fi
      if ! [[ $val =~ ^https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?([/?#].*)?$ ]]; then
        V_ERR="https-Adresse erwartet${want:+ auf $want}"; return 1
      fi
      host="${BASH_REMATCH[1],,}"
      if [ -n "$want" ] && [ "$host" != "$want" ]; then V_ERR="https-Adresse auf $want erwartet"; return 1; fi
      V_OUT="$val" ;;
    secret) V_ERR="Geheimnisse gehören nicht in die .env (Docker-Secret verwenden)"; return 1 ;;
    *) V_ERR="unbekannter Typ '$type' in der Tabelle"; return 1 ;;
  esac
  validate_special "$key" || return 1
  return 0
}

origin_host() { # DASH_ORIGIN -> Host (leer, wenn ungültig)
  local o="$1"
  if [[ $o =~ ^https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$ ]]; then printf '%s' "${BASH_REMATCH[1],,}"; fi
}

validate_special() { # nutzt V_OUT; schlüsselspezifische Regeln
  local key="$1" h o
  case "$key" in
    DASH_ORIGIN)
      h="$(origin_host "$V_OUT")"
      if [ -z "$h" ]; then
        V_ERR="https-Origin ohne Pfad erwartet (z. B. https://dash.example.internal); WebAuthn braucht HTTPS"; return 1
      fi
      V_OUT="https://${V_OUT#https://}"; V_OUT="${V_OUT,,}" ;;
    DASH_RP_ID)
      if ! [[ $V_OUT =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then V_ERR="Domainname erwartet (kein Schema, kein Port)"; return 1; fi
      V_OUT="${V_OUT,,}"
      o="$(eff_value DASH_ORIGIN)"; h="$(origin_host "$o")"
      if [ -n "$h" ] && [ "$h" != "$V_OUT" ] && [[ $h != *".$V_OUT" ]]; then
        V_ERR="muss der Host der DASH_ORIGIN ($h) oder ein Domain-Suffix davon sein"; return 1
      fi ;;
  esac
  return 0
}

# ---------------------------------------------------------------- Docker-Secrets
SECRET_LIST=""; SECRET_KNOWN=-1
load_secret_list() {
  [ "$SECRET_KNOWN" = -1 ] || return 0
  SECRET_KNOWN=0
  command -v docker >/dev/null 2>&1 || return 0
  local out
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 5 docker secret ls --format '{{.Name}}' 2>/dev/null)" || return 0
  else
    out="$(docker secret ls --format '{{.Name}}' 2>/dev/null)" || return 0
  fi
  SECRET_LIST=$'\n'"$out"$'\n'; SECRET_KNOWN=1
}
# Wichtig: Der Aufruf `$(secret_status ...)` läuft in einer Unter-Shell; ein dort geladener Cache ginge verloren und jeder Menüaufbau
# würde `docker secret ls` neu starten (je Aufruf 0,1 bis 5 s). Deshalb vorher einmal in der Haupt-Shell laden (prefetch_secrets).
prefetch_secrets() { # Haupt-Shell; mit Hinweisbox, weil docker bis zu 5 s brauchen kann
  [ "$SECRET_KNOWN" = -1 ] || return 0
  command -v docker >/dev/null 2>&1 || { SECRET_KNOWN=0; return 0; }
  if [ -n "$UI" ] && [ "${1:-}" = ui ]; then "$UI" --backtitle "$BACKTITLE" --title "Einen Moment" --infobox "Docker-Secrets werden geprüft ..." 5 44 || true; fi
  load_secret_list
}
refresh_secrets() { SECRET_KNOWN=-1; prefetch_secrets "$@"; }
secret_status() { # Name -> vorhanden | fehlt | unbekannt
  load_secret_list
  if [ "$SECRET_KNOWN" != 1 ]; then echo unbekannt; return; fi
  if [[ $SECRET_LIST == *$'\n'"$1"$'\n'* ]]; then echo vorhanden; else echo fehlt; fi
}
secret_name_for() { # KEY -> Secret-Name
  case "$1" in
    DB_PASSWORD) eff_value DB_PASSWORD_SECRET ;;
    APNS_KEY) eff_value APNS_KEY_SECRET ;;
    *) printf '%s' "$(echo "$1" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}
secret_hint() { # KEY -> Text mit dem docker-secret-create-Befehl
  local name; name="$(secret_name_for "$1")"
  case "$1" in
    APNS_KEY)
      printf 'Der APNs-Schlüssel (.p8) liegt als Docker-Secret, nie in der .env.\n\nAnlegen (auf einem Swarm-Manager):\n  docker secret create %s /pfad/AuthKey_XXXXXXXXXX.p8\n\nDas Secret wird nur mit PUSH_ENABLED=true über stack.push.yaml eingehängt. Der Name steht in APNS_KEY_SECRET.' "$name" ;;
    DB_PASSWORD)
      printf 'Das Datenbank-Passwort liegt als Docker-Secret, nie in der .env.\n\nAnlegen (auf einem Swarm-Manager; die Eingabe erscheint nicht in der Shell-Historie):\n  read -rs PW; printf %%s "$PW" | docker secret create %s -\n  unset PW\n\nDer Name steht in DB_PASSWORD_SECRET. Ein Secret lässt sich nicht ändern: zum Ersetzen unter neuem Namen anlegen und DB_PASSWORD_SECRET anpassen.' "$name" ;;
    *) printf 'Geheimnisse gehören als Docker-Secret in den Swarm, nie in die .env:\n  docker secret create NAME DATEI' ;;
  esac
}

# ---------------------------------------------------------------- Prüfung der gesamten .env
declare -a CHK_ERR=() CHK_WARN=() CHK_NOTE=()
chk_err() { CHK_ERR+=("$*"); }
chk_warn() { CHK_WARN+=("$*"); }
chk_note() { CHK_NOTE+=("$*"); } # Hinweis: weder Fehler noch Warnung

check_all() {
  load_secret_list # in der Haupt-Shell, damit `$(secret_status ...)` unten den Cache nutzt (kein docker je Aufruf)
  CHK_ERR=(); CHK_WARN=(); CHK_NOTE=()
  local k v name st
  if [ "$ENV_EXISTS" = 0 ]; then chk_warn "Datei $ENV_FILE existiert noch nicht (wird beim Speichern angelegt)."; fi
  # Zeilen und Werte der Datei
  for k in $(printf '%s\n' "${!ENV_VAL[@]}" | sort); do
    is_ignored_key "$k" && continue
    v="${ENV_VAL[$k]}"
    if [ -n "${PEND_SET[$k]+x}" ]; then v="${PEND_SET[$k]}"; fi
    if [ -n "${PEND_UNSET[$k]+x}" ]; then continue; fi
    if [ "${ENV_COUNT[$k]}" -gt 1 ]; then chk_warn "$k steht ${ENV_COUNT[$k]}-mal in der Datei; die Shell nimmt den letzten Wert."; fi
    if [ -n "${ENV_BADMSG[$k]+x}" ]; then chk_err "$k: Zeile nicht shell-sicher (${ENV_BADMSG[$k]})."; fi
    if [ -n "${ENV_EXPR[$k]+x}" ]; then
      chk_warn "$k: Wert enthält \$ oder Backtick; \`. .env\` wertet das in der Shell aus. In einfache Anführungszeichen setzen."
    fi
    if [ -n "${T_GROUP[$k]+x}" ]; then
      if [ "${T_SECRET[$k]}" = 1 ]; then
        [ -z "$v" ] || chk_err "$k: Geheimnis in der .env. Entfernen (--unset $k) und als Docker-Secret ablegen."
        continue
      fi
      [ -n "$v" ] || continue
      if is_system_key "$k"; then chk_warn "$k wird vom System gesetzt; ein Wert in der .env ist wirkungslos."; continue; fi
      if validate "$k" "$v"; then
        :
      else
        chk_err "$k=$v: $V_ERR"
      fi
      if [ "${T_SRC[$k]}" = registry ] && ! passes_through "$k"; then
        if [ "${T_GROUP[$k]}" = Dashboard ] && [ ! -f "$DASH_OVERLAY" ]; then :
        else chk_warn "$k: der Stack reicht diese Variable nicht an den Dienst durch; der Wert wirkt (noch) nicht."; fi
      fi
    else
      if is_secretlike "$k"; then chk_warn "$k: unbekannte Variable, Name deutet auf ein Geheimnis; keine Geheimnisse in der .env."
      else chk_warn "$k: unbekannte Variable (nicht in den Tabellen)."; fi
    fi
  done
  # Konflikte (auf Basis des wirksamen Zustands)
  if [ "$ENV_EXISTS" = 1 ] && ! is_set DB_HOST; then
    chk_err "DB_HOST fehlt (Pflicht, der Stack bricht sonst ab)."
  fi
  if [ "$(eff_value PUSH_ENABLED)" = true ]; then
    for k in APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC; do
      [ -n "$(eff_value "$k")" ] || chk_err "PUSH_ENABLED=true, aber $k fehlt."
    done
    if [ "$(eff_value IMAGE_WIDTH)" != 1024 ]; then chk_err "PUSH_ENABLED=true verlangt IMAGE_WIDTH=1024 (aktuell $(eff_value IMAGE_WIDTH))."; fi
    name="$(secret_name_for APNS_KEY)"; st="$(secret_status "$name")"
    case "$st" in
      fehlt) chk_err "PUSH_ENABLED=true, aber das Docker-Secret $name fehlt (docker secret create $name /pfad/AuthKey_XXXXXXXXXX.p8)." ;;
      unbekannt) chk_warn "Docker-Secret $name konnte nicht geprüft werden (docker nicht erreichbar oder kein Manager)." ;;
    esac
  fi
  if [ "$(eff_value DASH_ENABLED)" = true ]; then
    if [ -z "$(eff_value DASH_ORIGIN)" ]; then chk_err "DASH_ENABLED=true, aber DASH_ORIGIN fehlt (https-Adresse, unter der das Dashboard aufgerufen wird)."; fi
    if [ ! -f "$DASH_OVERLAY" ]; then chk_warn "Dashboard noch nicht verfügbar in dieser Version (deploy/swarm/stack.dashboard.yaml fehlt); ein Rollout bricht ab."
    elif ! dash_command_ready; then chk_note "Dashboard: Overlay vorhanden, Dienstbefehl folgt (WP5): der Befehl 'radar dashboard' ist in dieser Version noch nicht bestätigt; der Dienst startet erst mit einem Image, das ihn enthält."; fi
  fi
  if [ "$ENV_EXISTS" = 1 ]; then
    name="$(secret_name_for DB_PASSWORD)"; st="$(secret_status "$name")"
    case "$st" in
      fehlt) chk_err "Docker-Secret $name (Datenbank-Passwort) fehlt." ;;
      unbekannt) chk_warn "Docker-Secret $name konnte nicht geprüft werden (docker nicht erreichbar oder kein Manager)." ;;
    esac
  fi
  return 0
}

print_check() { # gibt Meldungen aus; Rückgabe 1 bei Fehlern
  local m
  for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "FEHLER   $m"; done
  for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "WARNUNG  $m"; done
  for m in ${CHK_NOTE[@]+"${CHK_NOTE[@]}"}; do echo "HINWEIS  $m"; done
  echo "Ergebnis: ${#CHK_ERR[@]} Fehler, ${#CHK_WARN[@]} Warnungen."
  [ "${#CHK_ERR[@]}" -eq 0 ]
}

# ---------------------------------------------------------------- Schreiben
declare -a NEW_LINES=()

build_new_lines() {
  local k i line trimmed last first
  NEW_LINES=(${ENV_LINES[@]+"${ENV_LINES[@]}"})
  for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} | sort); do
    [ -n "$k" ] || continue
    is_secretlike "$k" && die "Interner Schutz: $k ist ein Geheimnis und wird nie in die .env geschrieben."
    last=-1; first=-1
    for i in "${!NEW_LINES[@]}"; do
      line="${NEW_LINES[$i]}"
      if [[ $line =~ $ASSIGN_RE ]] && [ "${BASH_REMATCH[2]}" = "$k" ]; then last=$i
      elif [[ $line == "#$k="* ]] && [ "$first" = -1 ]; then first=$i; fi
    done
    if [ "$last" != -1 ]; then NEW_LINES[last]="$k=$(shquote "${PEND_SET[$k]}")"
    elif [ "$first" != -1 ]; then NEW_LINES[first]="$k=$(shquote "${PEND_SET[$k]}")"
    else NEW_LINES+=("$k=$(shquote "${PEND_SET[$k]}")"); fi
  done
  for k in $(printf '%s\n' ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort); do
    [ -n "$k" ] || continue
    for i in "${!NEW_LINES[@]}"; do
      line="${NEW_LINES[$i]}"
      if [[ $line =~ $ASSIGN_RE ]] && [ "${BASH_REMATCH[2]}" = "$k" ]; then
        trimmed="${line#"${line%%[![:space:]]*}"}"
        # A secret that landed in the file is deleted, not commented out (it must not stay readable as a comment).
        if is_secretlike "$k"; then NEW_LINES[i]=$'\x01DELETE'; else NEW_LINES[i]="#$trimmed"; fi
      fi
    done
  done
  local -a kept=()
  for i in "${!NEW_LINES[@]}"; do [ "${NEW_LINES[$i]}" = $'\x01DELETE' ] || kept+=("${NEW_LINES[$i]}"); done
  NEW_LINES=(${kept[@]+"${kept[@]}"})
}

BACKUP_PATH=""
write_env() {
  build_new_lines
  local target="$ENV_FILE" dir ts bak n mode tmp
  if [ -L "$target" ]; then target="$(readlink -f "$target")"; fi
  dir="$(dirname "$target")"
  BACKUP_PATH=""
  if [ -f "$target" ]; then
    ts="$(date +%Y%m%d-%H%M%S)"; bak="$target.bak.$ts"; n=1
    while [ -e "$bak" ]; do bak="$target.bak.$ts-$n"; n=$((n + 1)); done
    cp -p "$target" "$bak"
    mode="$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target")"
    BACKUP_PATH="$bak"
  else
    mode=600
  fi
  tmp="$(umask 077; mktemp "$dir/.env.settings.XXXXXX")"
  if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$tmp"; else : > "$tmp"; fi
  chmod "$mode" "$tmp"
  if [ -f "$target" ]; then chown --reference="$target" "$tmp" 2>/dev/null || true; fi
  mv -f "$tmp" "$target"
  PEND_SET=(); PEND_UNSET=()
  env_load
}

redact_line() { # eine .env-Zeile ohne Geheimnisse ausgeben
  local line="$1"
  if [[ $line =~ ^[[:space:]]*#?[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && is_secretlike "${BASH_REMATCH[2]}"; then
    printf '%s=***' "${BASH_REMATCH[2]}"
  else
    printf '%s' "$line"
  fi
}

show_val() { # Wert für Anzeige (Geheimnisse nie)
  local k="$1" v="$2"
  if is_secretlike "$k"; then printf '***'; elif [ -z "$v" ]; then printf '(leer)'; else printf '%s' "$v"; fi
}

# ---------------------------------------------------------------- Anzeige-Hilfen
describe_type() {
  local k="$1" t="${T_TYPE[$1]}" b="${T_TYPE[$1]%%:*}" r="" u="${T_UNIT[$1]}"
  [[ $t == *:* ]] && r="${t#*:}"
  case "$b" in
    int) echo "Ganzzahl ${T_MIN[$k]} bis ${T_MAX[$k]}${u:+ $u}" ;;
    number) echo "Zahl ${T_MIN[$k]} bis ${T_MAX[$k]}${u:+ $u}" ;;
    bool) echo "true oder false" ;;
    choice) echo "Auswahl: ${T_CHOICES[$k]//|/, }" ;;
    layers) echo "Liste (Komma): ${T_CHOICES[$k]//|/, }" ;;
    url) echo "https-Adresse${r:+ auf $r}, höchstens ${T_MAX[$k]} Zeichen" ;;
    text)
      case "$r" in
        apnsIdentifier) echo "10 Zeichen A-Z, 0-9" ;;
        bundleIdentifier) echo "Bundle-ID, z. B. de.example.app" ;;
        printableASCII) echo "ASCII-Text, höchstens ${T_MAX[$k]} Zeichen" ;;
        *) echo "Text, höchstens ${T_MAX[$k]} Zeichen" ;;
      esac ;;
    secret) echo "Geheimnis (Docker-Secret)" ;;
    *) echo "$b" ;;
  esac
}

effect_text() {
  local k="$1"
  if is_system_key "$k"; then echo "System: wird vom Image bzw. Swarm gesetzt, nicht in der .env"; return; fi
  case "${T_APPLY[$k]}" in
    live) echo "live: im Dashboard änderbar (30 s); ein Wert in der .env hat Vorrang und wirkt nach \"Jetzt anwenden\"" ;;
    restart) echo "Neustart: wird beim Start gelesen; wirkt nach \"Jetzt anwenden\"" ;;
    *) echo "nur ENV: nur über die .env, wirkt nach \"Jetzt anwenden\"" ;;
  esac
}

state_label() {
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then echo RESET
  elif [ -n "${PEND_SET[$k]+x}" ]; then echo NEU
  elif in_file "$k"; then echo gesetzt
  else echo Default; fi
}

item_desc() { # KEY [Breite der Beschreibungsspalte] -> "Wert  Zustand  Wirkung", der Wert wird auf die Breite gekürzt
  local k="$1" dw="${2:-34}" v u st vb lab
  if [ "${T_SECRET[$k]}" = 1 ]; then
    st="$(secret_status "$(secret_name_for "$k")")"
    if [ "$dw" -ge 24 ]; then printf '%-16s %s' "Secret $st" "(nicht in .env)"; else printf 'Secret %s' "$st"; fi
    return
  fi
  v="$(eff_value "$k")"; u="${T_UNIT[$k]}"
  if [ "$dw" -ge 32 ]; then vb=$((dw - 19)); elif [ "$dw" -ge 20 ]; then vb=$((dw - 9)); else vb=$dw; fi
  [ "$vb" -ge 6 ] || vb=6; [ "$vb" -le 26 ] || vb=26
  if [ -z "$v" ]; then v="(leer)"; elif [ -n "$u" ] && [ $((${#v} + ${#u} + 1)) -le "$vb" ]; then v="$v $u"; fi
  if [ "${#v}" -gt "$vb" ]; then v="${v:0:$((vb - 1))}~"; fi
  lab="$(apply_label "$k")"
  if [ "$dw" -ge 32 ]; then printf '%-*s %-8s %s' "$vb" "$v" "$(state_label "$k")" "$lab"
  elif [ "$dw" -ge 20 ]; then printf '%-*s %s' "$vb" "$v" "$(state_label "$k")"
  else printf '%s' "$v"; fi
}

# ---------------------------------------------------------------- whiptail-Hilfen
UI=""; ROWS=24; COLS=80; H=22; W=76; LH=12
WT_OUT=""
TMPFILES=()
cleanup() { local f; for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do rm -f "$f"; done; }

ui_init() {
  if command -v whiptail >/dev/null 2>&1; then UI=whiptail
  elif command -v dialog >/dev/null 2>&1; then UI=dialog
  else
    cat >&2 <<'EOF'
whiptail (oder dialog) fehlt. Installieren mit: apt install whiptail
Ohne Menü funktionieren: --list, --get KEY, --set KEY=VALUE, --unset KEY, --check, --help
EOF
    exit 1
  fi
}

ui_size() {
  local sz
  if [ -n "${SETTINGS_ROWS:-}" ] && [ -n "${SETTINGS_COLS:-}" ]; then ROWS="$SETTINGS_ROWS"; COLS="$SETTINGS_COLS"
  elif sz="$(stty size 2>/dev/null </dev/tty)" && [ -n "$sz" ]; then ROWS="${sz% *}"; COLS="${sz#* }"
  else ROWS="${LINES:-$(tput lines 2>/dev/null || echo 24)}"; COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"; fi
  [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24; [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
  H=$((ROWS - 2)); [ "$H" -gt 30 ] && H=30; [ "$H" -lt 14 ] && H=14
  W=$((COLS - 4)); [ "$W" -gt 100 ] && W=100; [ "$W" -lt 50 ] && W=50
  LH=$((H - 8)); [ "$LH" -lt 4 ] && LH=4
  return 0
}

# whiptail aufrufen; Auswahl landet in WT_OUT, Rückgabe = Exit-Code. @H, @W und @LH werden durch die aktuelle
# Fenstergröße ersetzt (Terminalgröße wird bei jedem Aufruf neu gelesen).
wt() {
  local rc=0 a bt="$BACKTITLE | ${ENV_FILE##*/}"
  local -a args=()
  ui_size
  [ "$(pending_count)" -eq 0 ] || bt+=" | $(pending_count) ungespeichert"
  for a in "$@"; do
    case "$a" in @H) a="$H" ;; @W) a="$W" ;; @LH) a="$LH" ;; *) ;; esac
    args+=("$a")
  done
  WT_OUT="$("$UI" --backtitle "$bt" --ok-button OK --cancel-button Zurück --yes-button Ja --no-button Nein "${args[@]}" 3>&1 1>&2 2>&3)" || rc=$?
  return "$rc"
}

# Höhe und Listenhöhe eines Menüs mit N Einträgen und TEXTZEILEN Textzeilen (soweit es das Terminal zulässt).
FIT_H=20; FIT_LH=10
fit_menu() {
  ui_size
  FIT_LH="$1"; [ "$FIT_LH" -le "$LH" ] || FIT_LH="$LH"
  FIT_H=$((FIT_LH + $2 + 6)); [ "$FIT_H" -le "$H" ] || FIT_H="$H"
  return 0
}

# Wie fit_menu, aber mit dem (umbrochenen) Text selbst statt einer Zeilenzahl.
fit_menu_text() { # N-Einträge Text
  local th; th="$(text_height "$2")"
  fit_menu "$1" $((th - 5))
}

text_height() { # Zeilen eines Textes (mit Umbruch) + Rahmen
  local text="$1" lines=0 line
  ui_size
  while IFS= read -r line; do lines=$((lines + 1 + ${#line} / (W - 6))); done <<< "$text"
  echo $((lines + 6))
}

# --scrolltext nur, wenn der Text nicht ins Fenster passt: mit --scrolltext liegt der Fokus im Text und Enter schließt die Box NICHT
# (man müsste erst Tab drücken); das wirkte als "hängt".
ui_msg() { # Titel Text
  local h st="" t="$1"; ui_size; h="$(text_height "$2")"; if [ "$h" -gt "$H" ]; then h=$H; st=--scrolltext; t+=" (Tab, dann Enter schließt)"; fi
  wt --title "$t" ${st:+"$st"} --msgbox "$2" "$h" "$W" || true
}
ui_yesno() { # Titel Text [--defaultno]
  local h; ui_size; h="$(text_height "$2")"; [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" ${3:+"$3"} --yesno "$2" "$h" "$W"
}
ui_input() { # Titel Text Startwert
  local h; ui_size; h="$(text_height "$2")"; h=$((h + 2)); [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" --inputbox "$2" "$h" "$W" "$3"
}
ui_textfile() { # Titel Datei: passt der Text ins Fenster, als normale Box (Enter schließt); sonst scrollbar (Pfeile, Bild auf/ab; Esc schließt)
  local text h; text="$(cat "$2")"; ui_size; h="$(text_height "$text")"
  if [ "$h" -le "$H" ]; then wt --title "$1" --msgbox "$text" "$h" "$W" || true
  else wt --title "$1 (Esc schließt)" --scrolltext --textbox "$2" @H @W || true; fi
}

# ---------------------------------------------------------------- Menüs
MENU_TITLES=("Radar & Cache" "Zusatzebenen" "Push" "Push-Limits und Raten" "Betreiberseiten" "Dashboard" "Dashboard-Schwellen" "Geräte-Kopplung" "Datenbank & Dienst" "Deploy / Image" "Sonstiges")
MENU_TG=("Radar Cache" "Ebenen" "Push" "Push-Grenzen Push-Ratenlimits" "Betreiberseiten" "Dashboard Neustart" "Dashboard-Schwellen" "Geräte-Kopplung" "Datenbank Dienst Quellen" "Deploy" "")
# Pfad im Titel: "Einstellungen › Push › APNS_ENV" (ohne UTF-8-Locale ">", weil whiptail sonst die Breite falsch berechnet)
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) CRUMB_SEP=" › " ;; *) CRUMB_SEP=" > " ;; esac
crumb() { local out="Einstellungen" p; for p in "$@"; do out+="$CRUMB_SEP$p"; done; printf '%s' "$out"; }

# Schlüssel je Menügruppe einmal je Sitzung berechnen (die Tabellen ändern sich nicht): GROUP_KEYS[idx] = "K1 K2 ..."
declare -a GROUP_KEYS=()
build_groups() {
  local idx k tg n=$((${#MENU_TITLES[@]} - 1))
  declare -A seen=()
  GROUP_KEYS=()
  for idx in "${!MENU_TITLES[@]}"; do
    GROUP_KEYS[idx]=""
    [ "$idx" -lt "$n" ] || continue
    for tg in ${MENU_TG[$idx]}; do
      for k in "${KEYS[@]}"; do
        if [ "${T_GROUP[$k]}" = "$tg" ]; then GROUP_KEYS[idx]+="${GROUP_KEYS[idx]:+ }$k"; seen[$k]=1; fi
      done
    done
  done
  for k in "${KEYS[@]}"; do [ -n "${seen[$k]+x}" ] || GROUP_KEYS[n]+="${GROUP_KEYS[n]:+ }$k"; done
}
group_keys() { local k; for k in ${GROUP_KEYS[$1]}; do echo "$k"; done; }

group_summary() { # Index -> "n Einträge, m gesetzt[, c geändert]"
  local n=0 m=0 c=0 k
  for k in ${GROUP_KEYS[$1]}; do
    n=$((n + 1)); is_set "$k" && m=$((m + 1))
    if [ -n "${PEND_SET[$k]+x}" ] || [ -n "${PEND_UNSET[$k]+x}" ]; then c=$((c + 1)); fi
  done
  if [ "$c" -gt 0 ]; then echo "$n Einträge, $m gesetzt, $c geändert"; else echo "$n Einträge, $m gesetzt"; fi
}

detail_text() { # KEY
  local k="$1" cur src note=""
  cur="$(eff_value "$k")"; src="$(state_label "$k")"
  if ! is_system_key "$k" && ! passes_through "$k"; then
    if [ "${T_GROUP[$k]}" = Dashboard ] && [ ! -f "$DASH_OVERLAY" ]; then
      note=$'\nStatus:   vorbereitet (Overlay noch nicht vorhanden): Dashboard noch nicht verfügbar in dieser Version'
    else note=$'\nHinweis:  der Stack reicht die Variable nicht durch; ein Wert wirkt (noch) nicht'; fi
  elif [ "$k" = DASH_ENABLED ] && [ ! -f "$DASH_OVERLAY" ]; then
    note=$'\nStatus:   vorbereitet (Overlay noch nicht vorhanden): Dashboard noch nicht verfügbar in dieser Version'
  elif [ "$k" = DASH_ENABLED ] && ! dash_command_ready; then
    note=$'\nStatus:   Overlay vorhanden, Dienstbefehl folgt (WP5)'
  fi
  printf '%s\n\nTyp:      %s\nDefault:  %s\nAktuell:  %s (%s)\nWirkung:  %s%s' \
    "${T_SUM[$k]}" "$(describe_type "$k")" "$(show_val "$k" "${T_DEF[$k]}")" "$(show_val "$k" "$cur")" "$src" "$(effect_text "$k")" "$note"
}

# Bearbeiten eines Eintrags in EINEM Schritt (kein Zwischenmenü): Auswahlliste für bool/choice/kleine Zahlenbereiche, sonst Eingabefeld
# (leer lassen = auf Default zurücksetzen); ungültige Eingaben bleiben im selben Feld. Titel mit Pfad: Einstellungen › Gruppe › KEY.
PARENT_CRUMB=""
edit_key() { # KEY
  local k="$1" base="${T_TYPE[$1]%%:*}" init prompt tok cur n lo hi ct i choice
  local -a opts=() ch
  ct="$(crumb ${PARENT_CRUMB:+"$PARENT_CRUMB"} "$k")"
  if [ "${T_SECRET[$k]}" = 1 ]; then
    refresh_secrets ui # nach `docker secret create` in einer anderen Sitzung: frischer Status
    ui_msg "$ct (Secret: $(secret_status "$(secret_name_for "$k")"))" "$(secret_hint "$k")"
    return 0
  fi
  if is_system_key "$k"; then
    local extra=""
    [ "$k" = REPLICA_SLOT ] && extra=$'\n\nDer Swarm setzt den Wert per {{.Task.Slot}}; nicht manuell eintragen.'
    ui_msg "$ct" "$(detail_text "$k")$extra"
    return 0
  fi
  init="$(eff_value "$k")"; lo="${T_MIN[$k]}"; hi="${T_MAX[$k]}"
  # Auswahlliste: Wert, Beschreibung; dazu (wenn gesetzt) "Auf Default zurücksetzen"
  opts=()
  case "$base" in
    bool) opts=(true "an" false "aus") ;;
    choice) IFS='|' read -ra ch <<< "${T_CHOICES[$k]}"; for tok in "${ch[@]}"; do opts+=("$tok" ""); done ;;
    int) if [[ $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]] && [ $((hi - lo)) -le 5 ]; then for ((i = lo; i <= hi; i++)); do opts+=("$i" ""); done; fi ;;
  esac
  if [ "${#opts[@]}" -gt 0 ]; then
    n=$(( ${#opts[@]} / 2 ))
    if [ -n "${ENV_COUNT[$k]+x}" ] || [ -n "${PEND_SET[$k]+x}" ]; then opts+=("-" "Auf Default zurücksetzen (${T_DEF[$k]:-leer})"); n=$((n + 1)); fi
    # aktueller Wert in der Beschreibung markieren
    for ((i = 0; i < ${#opts[@]}; i += 2)); do [ "${opts[i]}" = "$init" ] && opts[i + 1]="${opts[i + 1]:+${opts[i + 1]}  }<- aktuell"; done
    prompt="$(detail_text "$k")"
    fit_menu_text "$n" "$prompt"
    if wt --title "$ct" --default-item "$init" --menu "$prompt" "$FIT_H" @W "$FIT_LH" "${opts[@]}"; then
      choice="$WT_OUT"
      if [ "$choice" = "$init" ]; then :  # unverändert: nichts vormerken (ein explizit gesetzter Wert sperrt im Dashboard das Feld)
      elif [ "$choice" = - ]; then reset_key "$k"
      elif [ "$k" = DASH_ENABLED ] && [ "$choice" = true ]; then dashboard_enable_flow
      else queue_set "$k" "$choice"; fi
    fi
    return 0
  fi
  if [ "$base" = layers ]; then
    local -a lopts=() lch
    IFS='|' read -ra lch <<< "${T_CHOICES[$k]}"
    for tok in "${lch[@]}"; do
      if [[ ",$init," == *",$tok,"* ]]; then lopts+=("$tok" "" ON); else lopts+=("$tok" "" OFF); fi
    done
    prompt="${T_SUM[$k]}"$'\n'"Aktuell: $(show_val "$k" "$init"). Radar läuft immer; nichts gewählt = nur Radar."$'\n'"Leertaste wählt, Tab wechselt zu OK."
    fit_menu_text "${#lch[@]}" "$prompt"
    if wt --title "$ct" --separate-output --checklist "$prompt" "$FIT_H" @W "$FIT_LH" "${lopts[@]}"; then
      tok="$(printf '%s' "$WT_OUT" | tr '\n' ',')"; tok="${tok%,}"
      if validate "$k" "${tok:-radar}"; then queue_set "$k" "$V_OUT"; fi
    fi
    return 0
  fi
  prompt="$(detail_text "$k")"$'\n\n'"Neuer Wert (leer lassen = Default${T_DEF[$k]:+ ${T_DEF[$k]}}):"
  if [ "$k" = DASH_RP_ID ] && [ -z "$init" ]; then init="$(origin_host "$(eff_value DASH_ORIGIN)")"; fi
  while :; do
    ui_input "$ct" "$prompt" "$init" || return 0
    if [ -z "${WT_OUT//[[:space:]]/}" ]; then
      if [ -n "${ENV_COUNT[$k]+x}" ] || [ -n "${PEND_SET[$k]+x}" ]; then
        if ui_yesno "$ct" "Leer: $k auf den Default zurücksetzen (${T_DEF[$k]:-leer})?
Die Zeile in der .env wird beim Speichern auskommentiert."; then reset_key "$k"; return 0; fi
        init="$(eff_value "$k")"; continue
      fi
      ui_msg "$ct" "Nicht gesetzt: es gilt bereits der Default (${T_DEF[$k]:-leer})."; return 0
    fi
    if validate "$k" "$WT_OUT"; then
      # gleicher Wert wie der wirksame Default/Wert: nichts vormerken
      if [ "$V_OUT" != "$(eff_value "$k")" ] || in_file "$k" || [ -n "${PEND_SET[$k]+x}" ]; then queue_set "$k" "$V_OUT"; fi
      return 0
    fi
    init="$WT_OUT"
    ui_msg "Ungültiger Wert" "$k: $V_ERR

Erlaubt: $(describe_type "$k")
Die Eingabe bleibt im Feld stehen und kann korrigiert werden."
  done
}

reset_key() {
  local k="$1"
  if ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ] && [ -z "${ENV_COUNT[$k]+x}" ]; then
    ui_msg "$k" "Nicht gesetzt: es gilt bereits der Default (${T_DEF[$k]:-leer})."
    return 0
  fi
  queue_unset "$k" # sichtbar als Zustand RESET in der Liste
}

dashboard_enable_flow() {
  local origin host
  ui_msg "Dashboard aktivieren: Voraussetzungen" "$(cat <<'EOF'
- Das Dashboard läuft als eigener Dienst "dashboard" und veröffentlicht einen Ingress-Port (DASH_PUBLISH_PORT, Standard 39090); Ihr EXTERNER Reverse Proxy zeigt darauf. Firewall: Port nur für die Proxy-Adresse(n) öffnen, nie für das Internet.
- DASH_ORIGIN ist Pflicht: die https-Adresse, unter der Sie das Dashboard aufrufen (ohne Pfad). WebAuthn (Passkey) braucht HTTPS.
- Der Reverse Proxy terminiert TLS, leitet an <Swarm-Knoten>:DASH_PUBLISH_PORT weiter und muss den Host-Header unverändert durchreichen.
- Sofort nach dem Ausrollen den ersten Passkey registrieren: das Setup-Fenster gilt für den ersten, der das Dashboard erreicht.
- DASH_RP_ID ist optional (Standard: Host der Origin).
WARNUNG: Der erste Passkey wird beim ersten Start OHNE vorhandenes Credential registriert. Richten Sie ihn nur im internen Netz ein, direkt nach dem Start. Notfall-Reset: radar dashboard-reset --yes
EOF
)"
  if [ ! -f "$DASH_OVERLAY" ]; then
    ui_msg "Dashboard noch nicht verfügbar" "In dieser Version fehlt deploy/swarm/stack.dashboard.yaml. Die Werte werden vorbereitet; ein Rollout mit DASH_ENABLED=true bricht ab, bis das Overlay vorhanden ist (nach pull-scripts)."
  elif ! dash_command_ready; then
    ui_msg "Dienstbefehl folgt" "Overlay vorhanden, Dienstbefehl folgt (WP5): Der Befehl 'radar dashboard' ist in dieser Version noch nicht bestätigt. Die Werte werden gespeichert; der Dienst startet erst mit einem Image, das den Befehl enthält."
  fi
  origin="$(eff_value DASH_ORIGIN)"
  if [ -z "$origin" ]; then
    edit_key DASH_ORIGIN
    origin="$(eff_value DASH_ORIGIN)"
    if [ -z "$origin" ]; then ui_msg "Abgebrochen" "Ohne DASH_ORIGIN bleibt das Dashboard aus (DASH_ENABLED unverändert)."; return 0; fi
  fi
  queue_set DASH_ENABLED true
  host="$(origin_host "$origin")"
  if ! is_set DASH_RP_ID && [ -n "$host" ]; then
    if ui_yesno "DASH_RP_ID" "DASH_RP_ID ist optional. Auf den Host der Origin ($host) setzen?"; then queue_set DASH_RP_ID "$host"; fi
  fi
}

declare -A GSEL=()
longest_key() { local k m=0; for k in "$@"; do [ "${#k}" -le "$m" ] || m=${#k}; done; echo "$m"; }

group_menu() { # Index
  local idx="$1" k kw dw intro title
  local -a items keys
  title="${MENU_TITLES[$idx]}"
  read -ra keys <<< "${GROUP_KEYS[$idx]}"
  [ "${#keys[@]}" -gt 0 ] || return 0
  kw="$(longest_key "${keys[@]}")"
  PARENT_CRUMB="$title"
  while :; do
    ui_size; dw=$((W - kw - 9)) # Spalte Beschreibung: Fensterbreite minus Schlüsselspalte und Rahmen
    items=()
    for k in "${keys[@]}"; do items+=("$k" "$(item_desc "$k" "$dw")"); done
    intro="Enter: bearbeiten, Esc: zurück. Spalten: Wert | Zustand | Wirkung"
    if [ "$idx" = 5 ] && [ -n "$(dash_prepared_text)" ]; then intro="Dashboard: $(dash_prepared_text)"$'\n'"$intro"; fi
    fit_menu "${#keys[@]}" "$(grep -c '' <<< "$intro")"
    if wt --title "$(crumb "$title")" ${GSEL[$idx]:+--default-item "${GSEL[$idx]}"} --menu "$intro" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      GSEL[$idx]="$WT_OUT"; edit_key "$WT_OUT"
    else return 0; fi
  done
}

# Suche/Filter: Text in Name, Beschreibung, Gruppe oder Zustand ("gesetzt", "neu", "default", "reset"); die Trefferliste wird nach jeder
# Änderung neu aufgebaut, die Auswahl bleibt auf dem zuletzt bearbeiteten Eintrag; Esc in der Liste führt zurück zur Eingabe.
search_menu() {
  local term="" k hay lt sel="" kw dw
  local -a items keys
  while :; do
    ui_input "$(crumb Suche)" "Suchbegriff (Name, Beschreibung, Gruppe oder Zustand wie gesetzt/neu):" "$term" || return 0
    term="${WT_OUT,,}"; term="${term#"${term%%[![:space:]]*}"}"; term="${term%"${term##*[![:space:]]}"}"
    [ -n "$term" ] || { ui_msg "$(crumb Suche)" "Bitte einen Suchbegriff eingeben."; continue; }
    sel=""
    while :; do
      items=(); keys=()
      for k in "${KEYS[@]}"; do
        hay="${k,,} ${T_SUM[$k],,} ${T_GROUP[$k],,} $(state_label "$k" | tr '[:upper:]' '[:lower:]')"
        if [[ $hay == *"$term"* ]]; then keys+=("$k"); fi
      done
      if [ "${#keys[@]}" -eq 0 ]; then ui_msg "$(crumb Suche)" "Keine Treffer für '$term'."; break; fi
      kw="$(longest_key "${keys[@]}")"; ui_size; dw=$((W - kw - 9))
      for k in "${keys[@]}"; do items+=("$k" "$(item_desc "$k" "$dw")"); done
      lt=${#keys[@]}
      fit_menu "$lt" 3
      PARENT_CRUMB="Suche"
      if wt --title "$(crumb Suche "'$term'")" ${sel:+--default-item "$sel"} --menu "$lt Treffer. Enter: bearbeiten, Esc: neue Suche" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
        sel="$WT_OUT"; edit_key "$sel"
      else break; fi
    done
  done
}

show_notes() {
  ui_msg "$(crumb Hinweise)" "$(cat <<'EOF'
Wirkung der Einstellungen
- live: Der Dienst übernimmt den Wert alle 30 s, wenn er im Dashboard gesetzt wird. Eine Variable in der .env ist immer ENV und hat Vorrang; sie wirkt erst nach einem neuen Rollout (Jetzt anwenden).
- Neustart: wird beim Start der Dienste gelesen; wirkt nach einem Rollout.
- nur ENV: nur über die .env, wirkt nach einem Rollout.
- vorbereitet / "reicht der Stack nicht durch": Variable ist vorgesehen, wirkt in dieser Version noch nicht.

Speichern und Anwenden
- Änderungen sammelt das Menü im Speicher. Beim Speichern erscheint eine Diff-Übersicht; vorher entsteht eine Sicherung .env.bak.JJJJMMTT-HHMMSS (eine vorhandene .env.bak bleibt unberührt).
- Zurücksetzen kommentiert die Zeile aus (#KEY=alt): reversibel, und der Stack nimmt den Default.
- Geheimnisse (DB_PASSWORD, APNS_KEY) liegen als Docker-Secret und erscheinen hier nie.
- Ausgerollt wird nur mit "Jetzt anwenden" und Bestätigung.
EOF
)"
}

# ---------------------------------------------------------------- Speichern, Diff, Anwenden
build_review() { # Datei
  local f="$1" k old new line m
  {
    echo "ÄNDERUNGEN"
    for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort -u); do
      [ -n "$k" ] || continue
      if in_file_raw "$k"; then old="$(show_val "$k" "${ENV_VAL[$k]}")"; else old="(Default: $(show_val "$k" "${T_DEF[$k]-}"))"; fi
      if [ -n "${PEND_SET[$k]+x}" ]; then new="$(show_val "$k" "${PEND_SET[$k]}")"; else new="(Default: $(show_val "$k" "${T_DEF[$k]-}"), Zeile wird auskommentiert)"; fi
      echo "  $k: $old  ->  $new"
    done
    echo
    echo "WIRKUNG (erst nach \"Jetzt anwenden\", also nach dem Rollout)"
    local lbl n_restart=0 n_dash=0 n_env=0
    for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort -u); do
      [ -n "$k" ] || continue
      lbl="$(apply_label "$k")"
      case "$lbl" in Neustart) n_restart=$((n_restart + 1)) ;; "nur ENV") n_env=$((n_env + 1)) ;; esac
      case "$k" in DASH_*|DEVICE_LINK_*) n_dash=$((n_dash + 1)) ;; esac
      echo "  $k: $lbl"
    done
    echo "  Der Rollout startet die Radar-Replikate nacheinander neu (Rolling Update, kurze Unterbrechung je Replikat)."
    if [ "$n_restart" -gt 0 ]; then echo "  $n_restart Wert(e) mit Wirkung 'Neustart' werden erst beim Start der Dienste gelesen."; fi
    if [ "$n_env" -gt 0 ]; then echo "  $n_env Wert(e) 'nur ENV' lassen sich nie im Dashboard ändern."; fi
    if [ "$n_dash" -gt 0 ] && [ "$(eff_value DASH_ENABLED)" = true ]; then echo "  Dashboard-Dienst wird mit den neuen Werten gestartet bzw. neu angelegt."; fi
    echo
    echo "DIFF der Datei $ENV_FILE (ohne Kontext)"
    local before after
    before="$(mktemp)"; after="$(mktemp)"; TMPFILES+=("$before" "$after")
    if [ "${#ENV_LINES[@]}" -gt 0 ]; then printf '%s\n' "${ENV_LINES[@]}" > "$before"; fi
    build_new_lines
    if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$after"; fi
    diff -U0 "$before" "$after" | tail -n +3 | while IFS= read -r line; do
      case "$line" in
        '@@'*) ;;
        [+-]*) printf '%s%s\n' "${line:0:1}" "$(redact_line "${line:1}")" ;;
      esac
    done || true
    rm -f "$before" "$after"
    check_all
    if [ "${#CHK_ERR[@]}" -gt 0 ] || [ "${#CHK_WARN[@]}" -gt 0 ] || [ "${#CHK_NOTE[@]}" -gt 0 ]; then
      echo; echo "PRÜFUNG"
      for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "  FEHLER   $m"; done
      for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "  WARNUNG  $m"; done
      for m in ${CHK_NOTE[@]+"${CHK_NOTE[@]}"}; do echo "  HINWEIS  $m"; done
    fi
  } > "$f"
}
in_file_raw() { [ -n "${ENV_COUNT[$1]+x}" ]; }

save_flow() { # Rückgabe 0 = gespeichert
  local f chg dh
  if [ "$(pending_count)" -eq 0 ]; then ui_msg "Speichern" "Keine Änderungen."; return 1; fi
  f="$(mktemp)"; TMPFILES+=("$f")
  build_review "$f"
  ui_textfile "$(crumb "Änderungen prüfen")" "$f"
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_yesno "Fehler in der Prüfung" "Die Prüfung meldet ${#CHK_ERR[@]} Fehler (siehe Übersicht). Trotzdem speichern?" --defaultno || return 1
  elif ! ui_yesno "Speichern" "Änderungen in $ENV_FILE speichern?
Vorher wird eine Sicherung angelegt."; then
    return 1
  fi
  chg=" $(printf '%s ' ${PEND_SET[@]+"${!PEND_SET[@]}"} ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"}) "
  write_env
  dh=""
  if [[ $chg == *" DASH_ENABLED "* || $chg == *" DASH_ORIGIN "* || $chg == *" DASH_SETUP_WINDOW_MINUTES "* ]] && [ "$(eff_value DASH_ENABLED)" = true ]; then
    dh="

Dashboard nach dem Ausrollen:
- Aufruf unter $(eff_value DASH_ORIGIN); Proxy-Ziel: Swarm-Knoten, Port $(eff_value DASH_PUBLISH_PORT) (Container-Port $(eff_value DASH_PORT)). Firewall: Port nur für den Proxy öffnen.
- Setup-Fenster: $(eff_value DASH_SETUP_WINDOW_MINUTES) Minuten ab Dienststart, gilt für den Ersten, der das Dashboard erreicht: Passkey SOFORT registrieren.
- Ist das Fenster abgelaufen: Dienst neu starten (docker service update --force $(eff_value RADAR_STACK)_dashboard) oder Notfall-Reset: radar dashboard-reset --yes."
  fi
  ui_msg "$(crumb Gespeichert)" "${BACKUP_PATH:+Sicherung: $BACKUP_PATH
}Datei: $ENV_FILE

Die Dienste laufen noch mit den alten Werten. Wirksam wird die Änderung erst nach 'Jetzt anwenden' (oder update.sh / swarm-deploy.sh).$dh"
  return 0
}

apply_now() {
  local choice stack
  if [ "$(pending_count)" -gt 0 ]; then
    ui_yesno "Jetzt anwenden" "Es gibt ungespeicherte Änderungen. Zuerst speichern?" || return 0
    save_flow || return 0
  fi
  if [ ! -f "$ENV_FILE" ]; then ui_msg "Jetzt anwenden" "Es gibt noch keine .env."; return 0; fi
  check_all
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_msg "Jetzt anwenden" "Die Prüfung meldet Fehler; zuerst beheben (Menü oder --check):
$(printf '%s\n' "${CHK_ERR[@]}")"
    return 0
  fi
  stack="$(eff_value RADAR_STACK)"
  wt --title "$(crumb Anwenden)" --cancel-button Zurück --menu "Nichts wird ohne Bestätigung ausgerollt." @H @W 3 \
    S "Nur diese Einstellungen ausrollen (swarm-deploy.sh, Image-Tag $(eff_value RADAR_IMAGE_TAG) bleibt)" \
    U "Auf neuestes Image aktualisieren (update.sh --force)" \
    B "Zurück" || return 0
  choice="$WT_OUT"
  case "$choice" in
    S)
      [ -x "$SCRIPT_DIR/swarm-deploy.sh" ] || { ui_msg "Jetzt anwenden" "swarm-deploy.sh nicht gefunden."; return 0; }
      ui_yesno "Ausrollen bestätigen" "Es passiert:
1. Migrationsjob mit Image-Tag $(eff_value RADAR_IMAGE_TAG) (Stack $stack)
2. Rolling Update der Radar-Replikate mit den neuen Werten (kurze Neustarts)
Ist die Datenbank gesichert? Jetzt ausrollen?" --defaultno || return 0
      clear 2>/dev/null || true
      # shellcheck disable=SC1090
      ( set -a; . "$ENV_FILE"; set +a; export STACK="$stack"; cd "$SCRIPT_DIR" && ./swarm-deploy.sh ) || echo "swarm-deploy.sh endete mit einem Fehler."
      echo; echo "Rollout prüfen: docker service ps ${stack}_radar"
      read -r -p "Enter zum Zurückkehren ... " _ || true ;;
    U)
      [ -x "$SCRIPT_DIR/update.sh" ] || { ui_msg "Jetzt anwenden" "update.sh nicht gefunden."; return 0; }
      ui_yesno "Ausrollen bestätigen" "update.sh --force sucht das neueste Image (sha-Tag), schreibt RADAR_IMAGE_TAG in die .env, führt die Migration aus und startet das Rolling Update. Es fragt vorher nach der Datenbanksicherung. Fortfahren?" --defaultno || return 0
      clear 2>/dev/null || true
      "$SCRIPT_DIR/update.sh" --force --env-file "$ENV_FILE" || echo "update.sh endete mit einem Fehler."
      read -r -p "Enter zum Zurückkehren ... " _ || true
      env_load ;;
  esac
}

leave_menu() { # Rückgabe 0 = beenden
  local choice
  if [ "$(pending_count)" -eq 0 ]; then return 0; fi
  if wt --title "$(crumb Beenden)" --cancel-button "Zurück zum Menü" --menu "$(pending_count) Änderung(en) sind nicht gespeichert." @H @W 3 \
      S "Speichern und beenden" V "Verwerfen und beenden" Z "Zurück zum Menü"; then choice="$WT_OUT"; else return 1; fi
  case "$choice" in
    S) save_flow && return 0 || return 1 ;;
    V) return 0 ;;
    *) return 1 ;;
  esac
}

main_menu() {
  local sel="" i t d dw
  local -a items
  ui_size
  prefetch_secrets ui
  while :; do
    ui_size; dw=$((W - 21 - 9)) # Beschreibungsbreite: Fenster minus längster Gruppenname minus Rahmen (zu breite Zeilen zerlegen whiptail)
    items=()
    for i in "${!MENU_TITLES[@]}"; do
      [ -n "${GROUP_KEYS[$i]}" ] || continue
      d="($(group_summary "$i"))"
      if [ "${#d}" -gt "$dw" ]; then d="${d/ Einträge/}"; d="${d/ gesetzt/ ges.}"; fi
      items+=("${MENU_TITLES[$i]}" "${d:0:dw}")
    done
    d="Prüfen, speichern ($(pending_count) offen)"
    items+=("Suchen" "Filtern nach Text" "Hinweise" "live / Neustart / nur ENV" "Speichern" "${d:0:dw}" "Anwenden" "Ausrollen (mit Bestätigung)")
    t="Gruppe wählen (Enter), Esc beendet."
    if [ "$ROWS" -lt 24 ] || [ "$COLS" -lt 80 ]; then t+=$'\n'"Terminal ${COLS}x${ROWS}: empfohlen 80x24 oder größer."; fi
    fit_menu $(( ${#items[@]} / 2 )) "$(grep -c '' <<< "$t")"
    if wt --title "$(crumb)" --cancel-button Beenden ${sel:+--default-item "$sel"} --menu "$t" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      sel="$WT_OUT"
      case "$sel" in
        Suchen) search_menu ;;
        Hinweise) show_notes ;;
        Speichern) save_flow || true ;;
        Anwenden) apply_now ;;
        *) for i in "${!MENU_TITLES[@]}"; do if [ "${MENU_TITLES[$i]}" = "$sel" ]; then group_menu "$i"; break; fi; done ;;
      esac
    else
      if leave_menu; then return 0; fi
    fi
  done
}

# ---------------------------------------------------------------- Kommandozeile
usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cli_list() {
  local k v src extra
  load_secret_list
  printf '%-38s %-26s %-18s %s\n' VARIABLE WERT DEFAULT QUELLE
  for k in "${KEYS[@]}"; do
    if [ "${T_SECRET[$k]}" = 1 ]; then
      printf '%-38s %-26s %-18s %s\n' "$k" "(Secret: $(secret_status "$(secret_name_for "$k")"))" "-" "Docker-Secret"
      continue
    fi
    v="$(eff_value "$k")"
    if in_file "$k"; then src="Datei"; else src="Default"; fi
    printf '%-38s %-26s %-18s %s\n' "$k" "${v:-(leer)}" "${T_DEF[$k]:-(leer)}" "$src"
  done
  for k in $(printf '%s\n' "${!ENV_VAL[@]}" | sort); do
    [ -z "${T_GROUP[$k]+x}" ] || continue
    is_ignored_key "$k" && continue
    if is_secretlike "$k"; then extra="***"; else extra="${ENV_VAL[$k]:-(leer)}"; fi
    printf '%-38s %-26s %-18s %s\n' "$k" "$extra" "-" "Datei (unbekannt)"
  done
}

cli_get() {
  local k="$1"
  load_secret_list
  if [ -z "${T_GROUP[$k]+x}" ]; then
    if [ -n "${ENV_VAL[$k]+x}" ] && ! is_secretlike "$k"; then printf '%s\n' "${ENV_VAL[$k]}"; return 0; fi
    echo "Unbekannte Variable: $k" >&2; return 2
  fi
  if [ "${T_SECRET[$k]}" = 1 ]; then echo "$k ist ein Geheimnis und wird nie ausgegeben (Status: $(secret_status "$(secret_name_for "$k")"))." >&2; return 2; fi
  eff_value "$k"; echo
}

cli_set() { # KEY=VALUE
  local pair="$1" k v
  if ! [[ $pair == ?*=* ]]; then echo "Format: --set KEY=VALUE" >&2; return 64; fi
  k="${pair%%=*}"; v="${pair#*=}"
  if [ -z "${T_GROUP[$k]+x}" ]; then
    if is_secretlike "$k"; then echo "$k sieht wie ein Geheimnis aus und wird nie geschrieben." >&2; return 2; fi
    echo "Unbekannte Variable: $k (siehe --list)" >&2; return 2
  fi
  if [ "${T_SECRET[$k]}" = 1 ]; then
    echo "$k ist ein Geheimnis und wird nie in die .env geschrieben." >&2
    secret_hint "$k" >&2; echo >&2
    return 2
  fi
  if is_system_key "$k"; then echo "$k wird vom System gesetzt, nicht in der .env." >&2; return 2; fi
  if ! validate "$k" "$v"; then echo "Ungültiger Wert für $k: $V_ERR" >&2; return 3; fi
  queue_set "$k" "$V_OUT"
  echo "$k gesetzt auf: $(show_val "$k" "$V_OUT")"
}

cli_unset() {
  local k="$1"
  if [ -z "${T_GROUP[$k]+x}" ] && [ -z "${ENV_COUNT[$k]+x}" ]; then echo "Unbekannte Variable: $k" >&2; return 2; fi
  if ! in_file_raw "$k"; then echo "$k ist nicht gesetzt (Default)."; return 0; fi
  queue_unset "$k"
  if is_secretlike "$k"; then echo "$k wird aus der .env gelöscht (Geheimnisse gehören als Docker-Secret in den Swarm)."
  else echo "$k wird auf den Default zurückgesetzt (Zeile auskommentiert)."; fi
}

main() {
  local -a actions=()
  local want_menu=1 rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) ENV_FILE="${2:?--env braucht einen Pfad}"; shift 2 ;;
      --list) actions+=("list"); want_menu=0; shift ;;
      --get) actions+=("get:${2:?--get braucht einen Namen}"); want_menu=0; shift 2 ;;
      --set) actions+=("set:${2:?--set braucht KEY=VALUE}"); want_menu=0; shift 2 ;;
      --unset) actions+=("unset:${2:?--unset braucht einen Namen}"); want_menu=0; shift 2 ;;
      --check) actions+=("check"); want_menu=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
    esac
  done
  [ -n "$ENV_FILE" ] || ENV_FILE="$(cd "$SCRIPT_DIR/../.." && pwd)/.env"
  load_tables
  load_stack_text
  env_load
  trap cleanup EXIT

  if [ "$want_menu" = 1 ]; then
    ui_init
    build_groups
    main_menu
    return 0
  fi

  local before_msgs="" after_msgs="" mutate=0 act
  for act in "${actions[@]}"; do case "$act" in set:*|unset:*) mutate=1 ;; esac; done
  if [ "$mutate" = 1 ]; then check_all; before_msgs="$(print_check || true)"; fi
  for act in "${actions[@]}"; do
    case "$act" in
      list) cli_list ;;
      get:*) cli_get "${act#get:}" || rc=$? ;;
      set:*) cli_set "${act#set:}" || { rc=$?; PEND_SET=(); PEND_UNSET=(); break; } ;;
      unset:*) cli_unset "${act#unset:}" || { rc=$?; PEND_SET=(); PEND_UNSET=(); break; } ;;
      check) check_all; print_check || rc=1 ;;
    esac
  done
  if [ "$rc" = 0 ] && [ "$(pending_count)" -gt 0 ]; then
    check_all; after_msgs="$(print_check || true)"
    write_env
    [ -z "$BACKUP_PATH" ] || echo "Sicherung: $BACKUP_PATH"
    echo "Gespeichert: $ENV_FILE (wirksam nach dem nächsten Rollout)"
    # Nur neue Hinweise zeigen
    local line
    while IFS= read -r line; do
      case "$line" in Ergebnis:*) continue ;; esac
      [ -n "$line" ] || continue
      if [[ $before_msgs != *"$line"* ]]; then echo "$line"; fi
    done <<< "$after_msgs"
  fi
  return "$rc"
}

# Beim Einbinden per `source` (Tests, Messungen) wird nicht gestartet.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
