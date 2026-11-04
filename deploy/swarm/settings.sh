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
declare -a CHK_ERR=() CHK_WARN=()
chk_err() { CHK_ERR+=("$*"); }
chk_warn() { CHK_WARN+=("$*"); }

check_all() {
  CHK_ERR=(); CHK_WARN=()
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
    if [ ! -f "$DASH_OVERLAY" ]; then chk_warn "Dashboard noch nicht verfügbar in dieser Version (deploy/swarm/stack.dashboard.yaml fehlt); ein Rollout bricht ab."; fi
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
    live) echo "live: per Dashboard sofort (30 s); in der .env gilt immer ENV, wirkt nach \"Jetzt anwenden\"" ;;
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

item_desc() { # KEY -> "Wert  Zustand  Wirkung" in höchstens ~34 Zeichen
  local k="$1" v u st
  if [ "${T_SECRET[$k]}" = 1 ]; then
    st="$(secret_status "$(secret_name_for "$k")")"
    printf '%-14s %-8s %s' "Secret $st" "-" Secret
    return
  fi
  v="$(eff_value "$k")"; u="${T_UNIT[$k]}"
  if [ -z "$v" ]; then v="(leer)"; elif [ -n "$u" ] && [ $((${#v} + ${#u} + 1)) -le 14 ]; then v="$v $u"; fi
  if [ "${#v}" -gt 14 ]; then v="${v:0:13}~"; fi
  printf '%-14s %-8s %s' "$v" "$(state_label "$k")" "$(apply_label "$k")"
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
  local rc=0 a
  local -a args=()
  ui_size
  for a in "$@"; do
    case "$a" in @H) a="$H" ;; @W) a="$W" ;; @LH) a="$LH" ;; *) ;; esac
    args+=("$a")
  done
  WT_OUT="$("$UI" --backtitle "$BACKTITLE" --ok-button OK --cancel-button Abbrechen --yes-button Ja --no-button Nein "${args[@]}" 3>&1 1>&2 2>&3)" || rc=$?
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

text_height() { # Zeilen eines Textes (mit Umbruch) + Rahmen
  local text="$1" lines=0 line
  ui_size
  while IFS= read -r line; do lines=$((lines + 1 + ${#line} / (W - 6))); done <<< "$text"
  echo $((lines + 6))
}

ui_msg() { # Titel Text
  local h; ui_size; h="$(text_height "$2")"; [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" --scrolltext --msgbox "$2" "$h" "$W" || true
}
ui_yesno() { # Titel Text [--defaultno]
  local h; ui_size; h="$(text_height "$2")"; [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" ${3:+"$3"} --yesno "$2" "$h" "$W"
}
ui_input() { # Titel Text Startwert
  local h; ui_size; h="$(text_height "$2")"; h=$((h + 2)); [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" --inputbox "$2" "$h" "$W" "$3"
}
ui_textfile() { # Titel Datei
  wt --title "$1" --scrolltext --textbox "$2" @H @W || true
}

# ---------------------------------------------------------------- Menüs
MENU_TITLES=("Radar & Cache" "Zusatzebenen" "Push" "Push-Limits und Raten" "Betreiberseiten" "Dashboard" "Datenbank & Dienst" "Deploy / Image" "Sonstiges")
MENU_TG=("Radar Cache" "Ebenen" "Push" "Push-Grenzen Push-Ratenlimits" "Betreiberseiten" "Dashboard Neustart" "Datenbank Dienst Quellen" "Deploy" "")

group_keys() { # Index -> Schlüsselliste (eine je Zeile)
  local idx="$1" tg k j covered all
  if [ "$idx" -lt $((${#MENU_TITLES[@]} - 1)) ]; then
    for tg in ${MENU_TG[$idx]}; do
      for k in "${KEYS[@]}"; do [ "${T_GROUP[$k]}" = "$tg" ] && echo "$k"; done
    done
  else
    all=" ${MENU_TG[*]} "
    for k in "${KEYS[@]}"; do covered=0; for j in ${all}; do [ "${T_GROUP[$k]}" = "$j" ] && covered=1; done; [ "$covered" = 1 ] || echo "$k"; done
  fi
}

group_summary() { # Index -> "n Einträge, m gesetzt"
  local n=0 m=0 k
  while IFS= read -r k; do [ -n "$k" ] || continue; n=$((n + 1)); is_set "$k" && m=$((m + 1)); done < <(group_keys "$1")
  echo "$n Einträge, $m gesetzt"
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
  fi
  printf '%s\n\nTyp:      %s\nDefault:  %s\nAktuell:  %s (%s)\nWirkung:  %s%s' \
    "${T_SUM[$k]}" "$(describe_type "$k")" "$(show_val "$k" "${T_DEF[$k]}")" "$(show_val "$k" "$cur")" "$src" "$(effect_text "$k")" "$note"
}

key_detail() { # KEY
  local k="$1" choice
  if [ "${T_SECRET[$k]}" = 1 ]; then
    ui_msg "$k (Secret: $(secret_status "$(secret_name_for "$k")"))" "$(secret_hint "$k")"
    return 0
  fi
  if is_system_key "$k"; then
    local extra=""
    [ "$k" = REPLICA_SLOT ] && extra=$'\n\nDer Swarm setzt den Wert per {{.Task.Slot}}; nicht manuell eintragen.'
    ui_msg "$k" "$(detail_text "$k")$extra"
    return 0
  fi
  while :; do
    if wt --title "$k" --cancel-button Zurück --menu "$(detail_text "$k")" @H @W 3 \
        E "Wert ändern" R "Auf Default zurücksetzen (Zeile auskommentieren)" B "Zurück"; then choice="$WT_OUT"; else return 0; fi
    case "$choice" in
      E) edit_key "$k" ;;
      R) reset_key "$k" ;;
      *) return 0 ;;
    esac
  done
}

reset_key() {
  local k="$1"
  if ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ] && [ -z "${ENV_COUNT[$k]+x}" ]; then
    ui_msg "$k" "Nicht gesetzt: es gilt bereits der Default (${T_DEF[$k]:-leer})."
    return 0
  fi
  queue_unset "$k"
  ui_msg "$k" "Wird beim Speichern auf den Default zurückgesetzt: die Zeile in der .env wird auskommentiert (#$k=...), der alte Wert bleibt dort lesbar."
}

edit_key() {
  local k="$1" base="${T_TYPE[$1]%%:*}" init prompt items="" tok cur n
  init="$(eff_value "$k")"
  case "$base" in
    bool)
      cur="$init"
      if wt --title "$k" --default-item "$cur" --menu "${T_SUM[$k]}" @H @W 2 true "an (true)" false "aus (false)"; then
        if [ "$k" = DASH_ENABLED ] && [ "$WT_OUT" = true ]; then dashboard_enable_flow; else queue_set "$k" "$WT_OUT"; fi
      fi ;;
    choice)
      local -a opts=() ch
      IFS='|' read -ra ch <<< "${T_CHOICES[$k]}"
      for tok in "${ch[@]}"; do opts+=("$tok" ""); done
      n=${#ch[@]}
      if wt --title "$k" --default-item "$init" --menu "${T_SUM[$k]}" @H @W "$n" "${opts[@]}"; then queue_set "$k" "$WT_OUT"; fi ;;
    layers)
      local -a lopts=() lch
      IFS='|' read -ra lch <<< "${T_CHOICES[$k]}"
      for tok in "${lch[@]}"; do
        if [[ ",$init," == *",$tok,"* ]]; then lopts+=("$tok" "" ON); else lopts+=("$tok" "" OFF); fi
      done
      if wt --title "$k" --separate-output --checklist "Zusätzliche Ebenen (Radar läuft immer). Leer lassen = nur Radar. Leertaste wählt." @H @W "${#lch[@]}" "${lopts[@]}"; then
        tok="$(printf '%s' "$WT_OUT" | tr '\n' ',')"; tok="${tok%,}"
        if validate "$k" "${tok:-radar}"; then queue_set "$k" "$V_OUT"; fi
      fi ;;
    *)
      prompt="${T_SUM[$k]}"$'\n'"Erlaubt: $(describe_type "$k")"
      if [ "$k" = DASH_RP_ID ] && [ -z "$init" ]; then init="$(origin_host "$(eff_value DASH_ORIGIN)")"; fi
      while :; do
        ui_input "$k" "$prompt" "$init" || return 0
        if validate "$k" "$WT_OUT"; then queue_set "$k" "$V_OUT"; return 0; fi
        init="$WT_OUT"
        ui_msg "Ungültiger Wert" "$k: $V_ERR"
      done ;;
  esac
}

dashboard_enable_flow() {
  local origin host
  ui_msg "Dashboard aktivieren: Voraussetzungen" "$(cat <<'EOF'
- Das Dashboard läuft als eigener Dienst "dashboard" nur im Overlay-Netz, ohne veröffentlichten Port.
- DASH_ORIGIN ist Pflicht: die https-Adresse, unter der Sie das Dashboard aufrufen (ohne Pfad). WebAuthn (Passkey) braucht HTTPS.
- Ihr interner Reverse Proxy terminiert TLS, leitet an dashboard:9090 weiter und muss den Host-Header unverändert durchreichen.
- DASH_RP_ID ist optional (Standard: Host der Origin).
WARNUNG: Der erste Passkey wird beim ersten Start OHNE vorhandenes Credential registriert. Richten Sie ihn nur im internen Netz ein, direkt nach dem Start. Notfall-Reset: radar dashboard-reset --yes
EOF
)"
  if [ ! -f "$DASH_OVERLAY" ]; then
    ui_msg "Dashboard noch nicht verfügbar" "In dieser Version fehlt deploy/swarm/stack.dashboard.yaml. Die Werte werden vorbereitet; ein Rollout mit DASH_ENABLED=true bricht ab, bis das Overlay vorhanden ist (nach pull-scripts)."
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

group_menu() { # Index
  local idx="$1" k sel="" intro
  local -a items
  while :; do
    items=()
    while IFS= read -r k; do [ -n "$k" ] || continue; items+=("$k" "$(item_desc "$k")"); done < <(group_keys "$idx")
    [ "${#items[@]}" -gt 0 ] || return 0
    intro="Wert | Zustand | Wirkung"
    if [ "$idx" = 5 ] && [ ! -f "$DASH_OVERLAY" ]; then intro="Dashboard: vorbereitet (Overlay noch nicht vorhanden)"; fi
    fit_menu $(( ${#items[@]} / 2 )) 3
    if wt --title "${MENU_TITLES[$idx]}" ${sel:+--default-item "$sel"} --cancel-button Zurück --menu "$intro" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      sel="$WT_OUT"; key_detail "$sel"
    else return 0; fi
  done
}

search_menu() {
  local term k hay lt
  local -a items
  ui_input "Suche" "Suchbegriff (Name, Beschreibung, Gruppe):" "" || return 0
  term="${WT_OUT,,}"; [ -n "$term" ] || return 0
  items=()
  for k in "${KEYS[@]}"; do
    hay="${k,,} ${T_SUM[$k],,} ${T_GROUP[$k],,}"
    if [[ $hay == *"$term"* ]]; then items+=("$k" "$(item_desc "$k")"); fi
  done
  if [ "${#items[@]}" -eq 0 ]; then ui_msg "Suche" "Keine Treffer für '$WT_OUT'."; return 0; fi
  lt=$(( ${#items[@]} / 2 ))
  while wt --title "Treffer: $term" --cancel-button Zurück --menu "$lt Treffer" @H @W @LH "${items[@]}"; do key_detail "$WT_OUT"; done
}

show_notes() {
  ui_msg "Hinweise" "$(cat <<'EOF'
Wirkung der Einstellungen
- live: Der Dienst übernimmt den Wert alle 30 s, wenn er über das kommende Dashboard gesetzt wird. Eine Variable in der .env ist immer ENV und hat Vorrang; sie wirkt erst nach einem neuen Rollout (Jetzt anwenden).
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
    if [ "${#CHK_ERR[@]}" -gt 0 ] || [ "${#CHK_WARN[@]}" -gt 0 ]; then
      echo; echo "PRÜFUNG"
      for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "  FEHLER   $m"; done
      for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "  WARNUNG  $m"; done
    fi
  } > "$f"
}
in_file_raw() { [ -n "${ENV_COUNT[$1]+x}" ]; }

save_flow() { # Rückgabe 0 = gespeichert
  local f
  if [ "$(pending_count)" -eq 0 ]; then ui_msg "Speichern" "Keine Änderungen."; return 1; fi
  f="$(mktemp)"; TMPFILES+=("$f")
  build_review "$f"
  ui_textfile "Änderungen prüfen" "$f"
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_yesno "Fehler in der Prüfung" "Die Prüfung meldet ${#CHK_ERR[@]} Fehler (siehe Übersicht). Trotzdem speichern?" --defaultno || return 1
  elif ! ui_yesno "Speichern" "Änderungen in $ENV_FILE speichern?\nVorher wird eine Sicherung angelegt."; then
    return 1
  fi
  write_env
  ui_msg "Gespeichert" "${BACKUP_PATH:+Sicherung: $BACKUP_PATH
}Datei: $ENV_FILE

Die Dienste laufen noch mit den alten Werten. Wirksam wird die Änderung erst nach 'Jetzt anwenden' (oder update.sh / swarm-deploy.sh)."
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
  wt --title "Jetzt anwenden" --cancel-button Zurück --menu "Nichts wird ohne Bestätigung ausgerollt." @H @W 3 \
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
  if wt --title "Ungespeicherte Änderungen" --menu "$(pending_count) Änderung(en) sind nicht gespeichert." @H @W 3 \
      S "Speichern und beenden" V "Verwerfen und beenden" Z "Zurück zum Menü"; then choice="$WT_OUT"; else return 1; fi
  case "$choice" in
    S) save_flow && return 0 || return 1 ;;
    V) return 0 ;;
    *) return 1 ;;
  esac
}

main_menu() {
  local sel="" i
  local -a items
  while :; do
    items=()
    for i in "${!MENU_TITLES[@]}"; do
      if [ -n "$(group_keys "$i")" ]; then items+=("$i" "${MENU_TITLES[$i]}  ($(group_summary "$i"))"); fi
    done
    items+=(S "Suche / Filter" H "Hinweise (live, Neustart, nur ENV)" D "Änderungen anzeigen und speichern ($(pending_count) offen)" A "Jetzt anwenden (ausrollen)")
    fit_menu $(( ${#items[@]} / 2 )) 2
    if wt --title "Einstellungen (${ENV_FILE##*/})" ${sel:+--default-item "$sel"} --cancel-button Beenden --menu "Datei: $ENV_FILE" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      sel="$WT_OUT"
      case "$sel" in
        S) search_menu ;;
        H) show_notes ;;
        D) save_flow || true ;;
        A) apply_now ;;
        *) group_menu "$sel" ;;
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

main "$@"
