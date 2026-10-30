#!/usr/bin/env bash
# Setup wizard for a production Docker Swarm: asks for (or reads) all settings of the radar stack, validates them,
# writes the env file (.env in the top folder of the checkout, next to deploy/, mode 600, gitignored), creates the Swarm secret, runs the
# migration job, deploys (deploy/swarm/swarm-deploy.sh) and verifies health.
#
# Usage: deploy/swarm/setup.sh [options]
#   --env-file FILE      env file to write and, when it exists, to read as defaults (default: .env in the top folder of the checkout, next to deploy/)
#   --answers-file FILE  KEY=VALUE answers (same names as in the env file, plus the secret value DB_PASSWORD or
#                        DB_PASSWORD_FILE, optionally CHECK_NETWORK, SWARM_ADVERTISE_ADDR); parsed, never executed
#   --non-interactive    never prompt; take answers (file, SETUP_<KEY> env vars, existing env file, defaults)
#   --reconfigure        prompt again for every value, existing env values are the defaults
#                        (without it an existing env file is reused as is: idempotent re-run)
#   --stack NAME         stack name (default: radar)
#   --tag TAG            image tag instead of the newest sha- tag
#   --swarm-init         non-interactive: run `docker swarm init` when no swarm is active
#   --skip-checks        skip the database connectivity check
#   --no-deploy          write env file and create the secret only
#   --dry-run            no docker calls, no secrets; shows the plan and writes the env file to a temp directory
#   --yes                do not ask for the final confirmation
# The secret value is never written to the env file and never printed. TLS and the reverse proxy are external.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ANSWERS_FILE=""
NONINTERACTIVE=0
RECONFIGURE=0
STACK_ARG=""
TAG_ARG=""
SWARM_INIT=0
SKIP_CHECKS=0
NO_DEPLOY=0
DRY=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --answers-file) ANSWERS_FILE="${2:?missing value for --answers-file}"; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --stack) STACK_ARG="${2:?missing value for --stack}"; shift 2 ;;
    --tag) TAG_ARG="${2:?missing value for --tag}"; shift 2 ;;
    --swarm-init) SWARM_INIT=1; shift ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --no-deploy) NO_DEPLOY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done

START_TIME=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START_TIME )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
warn() { printf '[%s] WARNUNG: %s\n' "$(elapsed)" "$*" >&2; }
die() { echo "[$(elapsed)] Fehler: $*" >&2; exit 1; }
STEP=0
step() { STEP=$((STEP + 1)); printf '\n[%s] == Schritt %d: %s\n' "$(elapsed)" "$STEP" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 wird benötigt, ist aber nicht installiert"; }
interactive() { [ "$NONINTERACTIVE" = 0 ] && [ -t 0 ]; }
if [ "$NONINTERACTIVE" = 0 ] && [ ! -t 0 ]; then
  die "keine Terminal-Eingabe: --non-interactive mit --answers-file verwenden"
fi

# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------- answer sources
# Parsed KEY=VALUE files (never sourced): answers go to A_<KEY>, the existing env file to E_<KEY>.
parse_kv() { # file prefix
  local file="$1" prefix="$2" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    printf -v "${prefix}${key}" '%s' "$val"
  done < "$file"
}
HAVE_ENV=0
if [ -f "$ENV_FILE" ]; then HAVE_ENV=1; parse_kv "$ENV_FILE" E_; fi
if [ -n "$ANSWERS_FILE" ]; then
  [ -f "$ANSWERS_FILE" ] || die "Antwortdatei nicht gefunden: $ANSWERS_FILE"
  parse_kv "$ANSWERS_FILE" A_
fi
REUSE=0
if [ "$HAVE_ENV" = 1 ] && [ "$RECONFIGURE" = 0 ]; then REUSE=1; fi

# Value precedence: answers file > SETUP_<KEY> environment > existing env file > default.
# Sets SRC to the origin ("answer", "env", "existing" or "default") and echoes the value.
SRC=default
LV=""
lookup() { # key default -> LV (value) and SRC; not for use inside $(...)
  local k="$1" d="$2" v
  v="A_$k"; if [ -n "${!v+x}" ]; then SRC=answer; LV="${!v}"; return 0; fi
  v="SETUP_$k"; if [ -n "${!v+x}" ]; then SRC="env"; LV="${!v}"; return 0; fi
  v="E_$k"; if [ -n "${!v+x}" ]; then SRC=existing; LV="${!v}"; return 0; fi
  SRC=default; LV="$d"
}
get() { lookup "$@"; printf '%s' "$LV"; } # value only (safe in $(...))
# valid_<name> functions return 0/1 and print a hint to stderr on failure.
ask() { # VAR "German prompt" default validator [explanation]
  local var="$1" prompt="$2" def="$3" validator="$4" help="${5:-}" cur val src
  lookup "$var" "$def"; cur="$LV"; src="$SRC"
  if [ "$NONINTERACTIVE" = 1 ] || { [ "$REUSE" = 1 ] && [ "$src" != default ]; } || [ "$src" = answer ] || [ "$src" = env ]; then
    if "$validator" "$cur" 2>/dev/null; then printf -v "$var" '%s' "$cur"; return 0; fi
    if [ "$NONINTERACTIVE" = 1 ] || [ "$src" = answer ] || [ "$src" = env ]; then
      "$validator" "$cur" || true
      die "ungültiger oder fehlender Wert für $var ('$cur', Quelle: $src)"
    fi
  fi
  [ -z "$help" ] || printf '\n%s\n' "$help"
  while :; do
    printf '%s [%s]: ' "$prompt" "$cur"
    IFS= read -r val || die "Eingabe abgebrochen"
    val="${val:-$cur}"
    if "$validator" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
  done
}
confirm() { # prompt default(y|n) -> 0 for yes
  local prompt="$1" def="$2" a hint='[j/N]'
  [ "$def" = y ] && hint='[J/n]'
  if ! interactive; then [ "$def" = y ]; return; fi
  printf '%s %s ' "$prompt" "$hint"
  IFS= read -r a || die "Eingabe abgebrochen"
  a="${a:-$def}"
  case "$a" in y|Y|j|J|ja|Ja|yes) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- validators
bad() { echo "  ungültig: $*" >&2; return 1; }
valid_stack() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || bad "Stack-Name: Kleinbuchstaben, Ziffern, '-', beginnt mit Buchstabe"; }
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || bad "Image-Tag (z. B. sha-abc1234, 0.1.0, edge)"; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?$ ]] || bad "Hostname oder IPv4-Adresse"; }
valid_domain() { { valid_host "$1" 2>/dev/null && { [[ "$1" == *.* ]] || [ "$1" = localhost ]; } && [ "$1" = "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ]; } || bad "Domain in Kleinbuchstaben, z. B. radar.example.org"; }
valid_port() { { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; } || bad "Port 1-65535"; }
valid_replicas() { { [[ "$1" =~ ^[0-9]{1,2}$ ]] && [ "$1" -ge 1 ]; } || bad "Anzahl Replikate 1-99"; }
valid_cpu() { [[ "$1" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || bad "CPU-Limit wie 1.5 (0 = unbegrenzt)"; }
valid_mem() { [[ "$1" =~ ^([0-9]+[bBkKmMgG]?)$ ]] || bad "Speicher-Limit wie 512M oder 1G (0 = unbegrenzt)"; }
valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || bad "Name aus Buchstaben, Ziffern, _ . -"; }
valid_bool() { [[ "$1" == true || "$1" == false ]] || bad "true oder false"; }
valid_any() { return 0; }
valid_baseurl() { [ -z "$1" ] || [[ "$1" =~ ^https?://[a-z0-9.-]+(:[0-9]{1,5})?$ ]] || bad "URL wie https://radar.example.org (ohne Pfad und Schrägstrich am Ende; leer = keine öffentliche Prüfung)"; }

# ---------------------------------------------------------------- docker helpers
docker_ok() { [ "$DRY" = 1 ] && return 1; docker "$@" >/dev/null 2>&1; }
secret_exists() { docker_ok secret inspect "$1"; }

# Returns the secret value from the answers/environment: <KEY> or <KEY>_FILE (path); empty when none.
provided_secret() {
  local key="$1" v f
  f="$(get "${key}_FILE" '')"; if [ -n "$f" ]; then [ -r "$f" ] || die "${key}_FILE nicht lesbar: $f"; tr -d '\r\n' < "$f"; return; fi
  v="A_$key"; if [ -n "${!v-}" ]; then printf '%s' "${!v}"; return; fi
  v="SETUP_$key"; if [ -n "${!v-}" ]; then printf '%s' "${!v}"; return; fi
}
# prompt_secret KEY label -> value in SECRET_VALUE (hidden input; empty = none)
prompt_secret() {
  local label="$2" a b
  SECRET_VALUE="$(provided_secret "$1")"
  [ -z "$SECRET_VALUE" ] || return 0
  [ "$NONINTERACTIVE" = 0 ] || return 0
  while :; do
    printf '%s (Eingabe wird nicht angezeigt): ' "$label"; IFS= read -rs a || die "Eingabe abgebrochen"; echo
    [ -n "$a" ] || { echo "  darf nicht leer sein" >&2; continue; }
    printf '%s (Wiederholung): ' "$label"; IFS= read -rs b || die "Eingabe abgebrochen"; echo
    [ "$a" = "$b" ] && { SECRET_VALUE="$a"; return 0; }
    echo "  Eingaben stimmen nicht überein" >&2
  done
}


# ---------------------------------------------------------------- Step 1: preflight
step "Voraussetzungen prüfen"
need curl
need openssl
[ "$DRY" = 1 ] || need docker
SWARM_CREATED=0
if [ "$DRY" = 1 ]; then
  say "Trockenlauf: keine Docker-Aufrufe (Swarm-Status, Secrets und Verbindungstests entfallen)."
else
  docker info >/dev/null 2>&1 || die "Docker-Daemon nicht erreichbar (docker info schlägt fehl)"
  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
  case "$swarm_state" in
    active)
      [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" = true ] || die "dieser Knoten ist ein Swarm-Worker; das Skript muss auf einem Manager laufen"
      say "Swarm aktiv, dieser Knoten ist Manager." ;;
    inactive)
      say "Docker Swarm ist auf diesem Host nicht aktiv."
      go=0
      if [ "$NONINTERACTIVE" = 1 ]; then
        [ "$SWARM_INIT" = 1 ] || die "kein aktiver Swarm; mit --swarm-init erlauben oder manuell 'docker swarm init' ausführen"
        go=1
      else
        confirm "'docker swarm init' jetzt ausführen (macht diesen Host zum Swarm-Manager)?" n && go=1
        [ "$go" = 1 ] || die "ohne Swarm kein Stack-Deploy; abgebrochen"
      fi
      adv="$(get SWARM_ADVERTISE_ADDR '')"
      if [ -z "$adv" ] && [ "$NONINTERACTIVE" = 0 ]; then
        printf 'Advertise-Adresse für den Swarm (IP oder Interface, leer = automatisch): '; IFS= read -r adv || die "Eingabe abgebrochen"
      fi
      if [ -n "$adv" ]; then docker swarm init --advertise-addr "$adv" >/dev/null; else docker swarm init >/dev/null; fi
      SWARM_CREATED=1
      say "Swarm initialisiert." ;;
    *) die "Swarm-Status '$swarm_state' wird nicht unterstützt (erwartet: active oder inactive)" ;;
  esac
fi

# ---------------------------------------------------------------- Step 2: stack and image
step "Stack und Image"
STACK_DEFAULT="${STACK_ARG:-radar}"
ask RADAR_STACK "Stack-Name" "$STACK_DEFAULT" valid_stack "Der Stack-Name bestimmt die Namen der Dienste (<name>_radar, <name>_migrate)."
[ -z "$STACK_ARG" ] || RADAR_STACK="$STACK_ARG"
valid_stack "$RADAR_STACK" || die "ungültiger Stack-Name"
if [ "$DRY" = 0 ] && docker_ok service inspect "${RADAR_STACK}_radar"; then
  say "Stack '$RADAR_STACK' läuft bereits: das Skript führt ein Update (Migration + Rolling Update) aus."
fi

IMAGE_BASE="$(stack_image_base)"; [ -n "$IMAGE_BASE" ] || die "Image-Name nicht aus stack.yaml lesbar"
REPO="${IMAGE_BASE#ghcr.io/}" # used by lib.sh
export REPO
tag_default=""
if [ -n "$TAG_ARG" ]; then
  tag_default="$TAG_ARG"
else
  lookup RADAR_IMAGE_TAG ''; cur="$LV"
  if [ -n "$cur" ] && [ "$SRC" != default ] && { [ "$REUSE" = 1 ] || [ "$NONINTERACTIVE" = 1 ] || [ "$SRC" = answer ]; }; then
    tag_default="$cur"
  elif [ "$DRY" = 1 ]; then
    tag_default="${cur:-edge}"
  else
    say "Suche das neueste Image-Tag auf ghcr.io ..."
    found="$( (find_newest_sha_tag >&2 2>/dev/null; printf '%s' "$TAG") || true)"
    if [ -n "$found" ]; then
      tag_default="$found"
    else
      warn "neuestes Tag nicht ermittelbar (Registry nicht erreichbar?); Vorschlag: edge"
      tag_default="${cur:-edge}"
    fi
  fi
fi
ask RADAR_IMAGE_TAG "Image-Tag (${IMAGE_BASE})" "$tag_default" valid_tag "Empfohlen: ein fest gepinntes sha-<commit>- oder Versions-Tag statt 'edge'."
[ -z "$TAG_ARG" ] || RADAR_IMAGE_TAG="$TAG_ARG"
[ "$RADAR_IMAGE_TAG" != edge ] || warn "'edge' folgt jedem Push auf main; für Produktion ein festes Tag wählen."

# ---------------------------------------------------------------- Step 3: public address
step "Öffentliche Adresse"
ask PUBLIC_BASE_URL "Öffentliche Basis-URL des Reverse Proxys (leer = keine öffentliche Prüfung)" "$(get PUBLIC_BASE_URL '')" valid_baseurl \
  "TLS und Reverse Proxy liegen außerhalb dieses Stacks. Mit URL prüft das Skript nach dem Rollout GET <URL>/v1/radar/latest.json."

# ---------------------------------------------------------------- Step 4: resources
step "Ingress-Port, Replikate und Ressourcen"
ask RADAR_PORT "Veröffentlichter Port auf den Swarm-Knoten (Reverse Proxy zeigt hierauf)" "38090" valid_port
ask RADAR_REPLICAS "Anzahl Replikate" "2" valid_replicas "Mindestens 2 erlauben unterbrechungsfreie Rolling Updates (start-first)."
ask RADAR_CPU_LIMIT "CPU-Limit je Replikat (0 = unbegrenzt)" "0" valid_cpu
ask RADAR_MEMORY_LIMIT "Speicher-Limit je Replikat, z. B. 512M (0 = unbegrenzt)" "0" valid_mem

# ---------------------------------------------------------------- Step 5: external MariaDB
step "Externe MariaDB"
echo "Die Datenbank ist extern (nicht Teil des Stacks) und muss von allen Swarm-Knoten erreichbar sein."
echo "Der Benutzer braucht SELECT/INSERT/UPDATE/DELETE und für den Migrationsjob CREATE auf dem Schema."
ask DB_HOST "DB_HOST" "$(get DB_HOST '')" valid_host
ask DB_PORT "DB_PORT" "3306" valid_port
ask DB_NAME "DB_NAME" "showernow" valid_ident
ask DB_USER "DB_USER" "showernow" valid_ident
ask DB_POOL_SIZE "DB_POOL_SIZE (1-10)" "4" valid_replicas
ask DB_PASSWORD_SECRET "Name des Swarm-Secrets für das DB-Passwort" "showernow_db_password" valid_ident

# ---------------------------------------------------------------- Step 6: secret
step "Secret"
SECRET_KEYS="DB_PASSWORD"
secret_name() { case "$1" in DB_PASSWORD) echo "$DB_PASSWORD_SECRET" ;; esac; }
secret_label() { case "$1" in DB_PASSWORD) echo "Datenbank-Passwort" ;; esac; }
for key in $SECRET_KEYS; do
  name="$(secret_name "$key")"
  if secret_exists "$name"; then
    printf -v "SS_$key" '%s' exists
    say "Secret '$name' ($(secret_label "$key")) existiert bereits und bleibt unverändert."
    # An existing secret cannot be read back; a provided value is kept only for the connectivity check.
    printf -v "SV_$key" '%s' "$(provided_secret "$key")"
    continue
  fi
  printf -v "SS_$key" '%s' create
  if [ "$DRY" = 1 ] && [ -z "$(provided_secret "$key")" ]; then
    SECRET_VALUE="dry-run-placeholder"
  else
    prompt_secret "$key" "$(secret_label "$key") für Secret '$name'"
    [ -n "$SECRET_VALUE" ] || die "kein Wert für $key angegeben (${key} oder ${key}_FILE in der Antwortdatei)"
  fi
  printf -v "SV_$key" '%s' "$SECRET_VALUE"
done
SECRET_VALUE=""

# ---------------------------------------------------------------- Step 7: connectivity check
step "Verbindungsprüfung"
CHECK_NETWORK="$(get CHECK_NETWORK '')"
if [ "$SKIP_CHECKS" = 1 ] || [ "$DRY" = 1 ]; then
  say "übersprungen ($([ "$DRY" = 1 ] && echo Trockenlauf || echo --skip-checks))."
else
  net_args=()
  [ -z "$CHECK_NETWORK" ] || net_args=(--network "$CHECK_NETWORK")
  run_checks=1
  if [ "$NONINTERACTIVE" = 0 ] && ! confirm "Datenbank jetzt auf Erreichbarkeit prüfen?" y; then run_checks=0; fi
  if [ "$run_checks" = 1 ]; then
    if [ -n "${SV_DB_PASSWORD-}" ]; then
      say "Datenbank: mariadb:12.3 Wegwerf-Container, 'select 1' gegen ${DB_HOST}:${DB_PORT}/${DB_NAME} ..."
      if MYSQL_PWD="$SV_DB_PASSWORD" docker run --rm "${net_args[@]+"${net_args[@]}"}" -e MYSQL_PWD mariadb:12.3 \
          mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -N -e 'select 1' "$DB_NAME" >/dev/null 2>&1; then
        say "Datenbank erreichbar, Anmeldung erfolgreich."
      else
        warn "Datenbank nicht erreichbar oder Anmeldung fehlgeschlagen (Host, Port, Benutzer, Passwort, Datenbank, Firewall)."
        if [ "$NONINTERACTIVE" = 1 ]; then die "Verbindungsprüfung fehlgeschlagen (mit --skip-checks überspringbar)"; fi
        confirm "Trotzdem fortfahren?" n || die "abgebrochen"
      fi
    else
      say "Datenbank: Passwort liegt nur im vorhandenen Secret vor, Anmeldetest übersprungen."
    fi
  fi
fi

# ---------------------------------------------------------------- Step 8: summary and confirmation
step "Zusammenfassung"
if [ "$DRY" = 1 ]; then
  OUT_ENV="$(mktemp -d)/.env"
else
  OUT_ENV="$ENV_FILE"
fi
cat <<EOF
Stack:             $RADAR_STACK
Image:             ${IMAGE_BASE}:${RADAR_IMAGE_TAG}
Öffentliche URL:   ${PUBLIC_BASE_URL:-(keine)}
Port / Replikate:  $RADAR_PORT / $RADAR_REPLICAS (CPU-Limit $RADAR_CPU_LIMIT, Speicher-Limit $RADAR_MEMORY_LIMIT)
MariaDB:           $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME (Pool $DB_POOL_SIZE)
Env-Datei:         $OUT_ENV (Modus 600)
EOF
for key in $SECRET_KEYS; do
  status="SS_$key"
  case "${!status}" in exists) st="vorhanden, bleibt unverändert" ;; *) st="wird angelegt" ;; esac
  printf 'Secret %-28s %s\n' "$(secret_name "$key")" "$st"
done
echo "Danach: Migrationsjob (deploy/swarm/swarm-deploy.sh), Rolling Update, Health-Prüfung."
echo "Sichern Sie vor einem Update einer bestehenden Installation die Datenbank."
if [ "$DRY" = 0 ] && [ "$YES" = 0 ] && [ "$NONINTERACTIVE" = 0 ]; then
  confirm "Mit diesen Einstellungen fortfahren?" n || die "abgebrochen; es wurde nichts geändert"
fi

# ---------------------------------------------------------------- Step 9: env file
step "Env-Datei schreiben"
write_env() {
  local target="$1" tmp
  mkdir -p "$(dirname "$target")"
  tmp="$(umask 077; mktemp "${target}.XXXXXX")"
  {
    echo "# Generated by deploy/swarm/setup.sh. No secret values in this file."
    echo "# Used by deploy/swarm/update.sh and deploy/swarm/swarm-deploy.sh. Re-run setup.sh --reconfigure to change values."
    echo "RADAR_STACK=$RADAR_STACK"
    echo "RADAR_IMAGE_TAG=$RADAR_IMAGE_TAG"
    echo "PUBLIC_BASE_URL=$PUBLIC_BASE_URL"
    echo "RADAR_PORT=$RADAR_PORT"
    echo "RADAR_REPLICAS=$RADAR_REPLICAS"
    echo "RADAR_CPU_LIMIT=$RADAR_CPU_LIMIT"
    echo "RADAR_MEMORY_LIMIT=$RADAR_MEMORY_LIMIT"
    echo "DB_HOST=$DB_HOST"
    echo "DB_PORT=$DB_PORT"
    echo "DB_NAME=$DB_NAME"
    echo "DB_USER=$DB_USER"
    echo "DB_POOL_SIZE=$DB_POOL_SIZE"
    echo "DB_PASSWORD_SECRET=$DB_PASSWORD_SECRET"
    # Optional operator details for /datenschutz, /marketing, /support: carried over unchanged (not asked here).
    for optional in OPERATOR_NAME OPERATOR_ADDRESS OPERATOR_EMAIL PROXY_LOG_NOTE APP_STORE_URL TESTFLIGHT_URL; do
      [ ! -f "$target" ] || grep -E "^${optional}=" "$target" || true
    done
  } > "$tmp"
  chmod 600 "$tmp"
  if [ -f "$target" ]; then
    if cmp -s "$tmp" "$target"; then rm -f "$tmp"; say "Env-Datei unverändert: $target"; return; fi
    cp -p "$target" "${target}.bak"; chmod 600 "${target}.bak"
    say "Vorherige Version gesichert als ${target}.bak"
  fi
  mv "$tmp" "$target"; chmod 600 "$target"
  say "Env-Datei geschrieben: $target (Modus 600)"
}
write_env "$OUT_ENV"

if [ "$DRY" = 1 ]; then
  step "Trockenlauf: geplante Aktionen"
  for key in $SECRET_KEYS; do
    status="SS_$key"
    [ "${!status}" = exists ] || echo "  docker secret create $(secret_name "$key") -   (Wert nicht angezeigt)"
  done
  echo "  deploy/swarm/swarm-deploy.sh   (STACK=$RADAR_STACK, Migrationsjob, danach Rollout mit $RADAR_REPLICAS Replikaten)"
  echo "  Rollout abwarten, GET /v1/radar/latest.json (200 oder 404) auf dem Ingress-Port${PUBLIC_BASE_URL:+ und $PUBLIC_BASE_URL} prüfen"
  say "Trockenlauf beendet; es wurden keine Docker-Aufrufe ausgeführt."
  exit 0
fi

# ---------------------------------------------------------------- Step 10: create secret
step "Secret anlegen"
for key in $SECRET_KEYS; do
  name="$(secret_name "$key")"
  status="SS_$key"; value="SV_$key"
  if [ "${!status}" = exists ]; then continue; fi
  if secret_exists "$name"; then say "Secret '$name' wurde inzwischen angelegt, unverändert gelassen."; continue; fi
  printf '%s' "${!value}" | docker secret create "$name" - >/dev/null
  say "Secret '$name' angelegt."
done
for key in $SECRET_KEYS; do printf -v "SV_$key" '%s' ''; done

if [ "$NO_DEPLOY" = 1 ]; then
  say "--no-deploy: Env-Datei und Secret sind bereit. Deploy später mit: set -a; . $ENV_FILE; set +a; STACK=$RADAR_STACK $SCRIPT_DIR/swarm-deploy.sh"
  exit 0
fi

# ---------------------------------------------------------------- Step 11: deploy
step "Deploy (Migrationsjob, dann Rollout)"
(
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  export STACK="$RADAR_STACK"
  "$SCRIPT_DIR/swarm-deploy.sh"
)
step "Rollout abwarten"
wait_for_rollout "${RADAR_STACK}_radar" 600
docker service ps "${RADAR_STACK}_radar" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'

# ---------------------------------------------------------------- Step 12: verify
step "Prüfung: Erreichbarkeit"
HEALTH_OK=0
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
http_code() { local c; c="$(curl -sS -m 5 -o "$BODY_FILE" -w '%{http_code}' "$1" 2>/dev/null || true)"; echo "${c:-000}"; }
# latest.json: 200 once a run is published, 404 before the first run (the first run follows within minutes).
for base in "${PUBLIC_BASE_URL:-}" "http://127.0.0.1:${RADAR_PORT}"; do
  [ -n "$base" ] || continue
  code=000
  for ((n = 0; n < 6; n++)); do
    code="$(http_code "$base/v1/radar/latest.json")"
    case "$code" in 200|404) break ;; esac
    sleep 5
  done
  case "$code" in
    200|404)
      say "GET $base/v1/radar/latest.json -> $code$([ "$code" = 404 ] && echo ' (noch kein Lauf veröffentlicht; der erste folgt in wenigen Minuten)')"
      HEALTH_OK=1
      [ "$base" = "${PUBLIC_BASE_URL:-}" ] || [ -z "${PUBLIC_BASE_URL:-}" ] || warn "über die öffentliche URL nicht erreichbar, nur über den Ingress-Port: DNS, TLS und Reverse Proxy prüfen."
      break ;;
    *) warn "GET $base/v1/radar/latest.json nicht erfolgreich (HTTP $code)" ;;
  esac
done
if [ "$HEALTH_OK" = 0 ]; then
  # Last resort (VM-based Docker hosts without port forwarding): run the healthcheck inside a local replica.
  cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${RADAR_STACK}_radar" | head -n 1)"
  if [ -n "$cid" ] && docker exec "$cid" /bin/bash /healthcheck.sh >/dev/null 2>&1; then
    HEALTH_OK=1
    warn "nur von innen geprüft (Replikat $cid: /healthz = 200); Ingress-Port und Domain von außen selbst prüfen."
  fi
fi

echo
echo "Nächste Schritte"
echo "  1. Reverse Proxy/TLS auf Port $RADAR_PORT der Swarm-Knoten zeigen lassen."
echo "  2. Der erste Lauf erscheint nach wenigen Minuten: GET /v1/radar/latest.json ändert sich von 404 auf 200."
echo "  3. Updates: deploy/swarm/update.sh --env-file $ENV_FILE"
[ "$SWARM_CREATED" = 0 ] || echo "  Hinweis: Dieses Skript hat den Swarm initialisiert ('docker swarm leave --force' macht das rückgängig)."
if [ "$HEALTH_OK" = 0 ]; then
  echo "Prüfung nicht erfolgreich: docker service ps ${RADAR_STACK}_radar; docker service logs ${RADAR_STACK}_radar" >&2
  exit 2
fi
say "Fertig nach $(elapsed)."
