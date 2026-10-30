#!/usr/bin/env bash
# First-time setup on a Swarm manager: checks the swarm, writes stack.env from the example (mode 600),
# creates the database-password Swarm secret (prompt without echo, or from a file / stdin) and optionally deploys.
# Idempotent: existing env file and existing secret are kept. Secret values are never printed or written to disk.
#
# Usage: deploy/swarm/setup.sh [options]
#   --stack NAME           stack name (default: radar)
#   --env-file FILE        env file (default: deploy/swarm/stack.env)
#   --password-file FILE   read the DB password from FILE instead of prompting
#   --deploy               run `docker stack deploy` at the end (edit stack.env first!)
#   --dry-run              only show what would be done
# Migrations: the service applies the versioned SQL files in migrations/ at start (advisory-lock protected, additive).
# The MariaDB database and user must exist already (not part of this repository).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK=radar
ENV_FILE="$SCRIPT_DIR/stack.env"
PASSWORD_FILE=""
DEPLOY=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="${2:?missing value for --stack}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --password-file) PASSWORD_FILE="${2:?missing value for --password-file}"; shift 2 ;;
    --deploy) DEPLOY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid stack name: $STACK" >&2; exit 64; }

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die "docker is required"

if [ "$DRY" = 0 ]; then
  [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = active ] || die "this node is not part of an active swarm"
  [ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" = true ] || die "run this on a swarm manager"
fi

# 1. env file
if [ -f "$ENV_FILE" ]; then
  say "env file exists, keeping it: $ENV_FILE"
else
  say "writing $ENV_FILE from stack.env.example (mode 600) - edit the placeholders!"
  if [ "$DRY" = 0 ]; then
    ( umask 077; cp "$SCRIPT_DIR/stack.env.example" "$ENV_FILE" )
  fi
fi

# 2. secret
SECRET="$(sed -n 's/^DB_PASSWORD_SECRET=//p' "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d "\"'")"
SECRET="${SECRET:-showernow_db_password}"
if [ "$DRY" = 1 ]; then
  say "dry run: would ensure the Swarm secret '$SECRET' exists"
elif docker secret inspect "$SECRET" >/dev/null 2>&1; then
  say "secret '$SECRET' exists, keeping it (rotate: create a new name, set DB_PASSWORD_SECRET, redeploy)"
else
  if [ -n "$PASSWORD_FILE" ]; then
    [ -f "$PASSWORD_FILE" ] || die "password file not found"
    docker secret create "$SECRET" "$PASSWORD_FILE" >/dev/null
  else
    [ -t 0 ] || die "no terminal: pass --password-file"
    read -r -s -p "MariaDB password for the service user: " PW; echo
    [ -n "$PW" ] || die "empty password"
    printf '%s' "$PW" | docker secret create "$SECRET" - >/dev/null
    unset PW
  fi
  say "created secret '$SECRET'"
fi

# 3. deploy
if [ "$DEPLOY" = 1 ]; then
  [ "$DRY" = 1 ] && { say "dry run: would deploy stack '$STACK'"; exit 0; }
  grep -q 'example.internal\|OWNER' "$ENV_FILE" && die "stack.env still contains placeholders (DB_HOST / RADAR_IMAGE)"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  docker stack deploy --compose-file "$SCRIPT_DIR/stack.yaml" --resolve-image always "$STACK"
  say "deployed. Watch: docker service ps ${STACK}_radar"
else
  say "done. Next: edit $ENV_FILE, then run update.sh (or setup.sh --deploy)."
fi
