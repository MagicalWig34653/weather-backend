#!/usr/bin/env bash
# Roll the radar stack to a new image tag: writes RADAR_IMAGE_TAG into the env file (backup kept), runs
# `docker stack deploy` and watches the rolling update. Swarm rolls back automatically when the new tasks fail their
# healthcheck (update_config.failure_action: rollback). Idempotent: nothing happens when the tag is unchanged.
#
# Usage: deploy/swarm/update.sh [options]
#   --tag TAG        image tag, e.g. sha-1a2b3c4 or 1.0.0 (default: latest; a moving tag is re-resolved at deploy)
#   --stack NAME     stack name (default: radar)
#   --env-file FILE  env file (default: deploy/swarm/stack.env)
#   --force          redeploy even when the tag is unchanged (picks up a new `latest`)
#   --dry-run        show what would happen
# Manual rollback: docker service rollback <stack>_radar ; or run again with the previous --tag (see stack.env.bak).
# Schema changes are additive (see docs/decisions.md), so old and new replicas can run side by side during a roll.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK=radar
ENV_FILE="$SCRIPT_DIR/stack.env"
TAG=latest
FORCE=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?missing value for --tag}"; shift 2 ;;
    --stack) STACK="${2:?missing value for --stack}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid stack name: $STACK" >&2; exit 64; }
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "invalid tag: $TAG" >&2; exit 64; }

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE (run setup.sh first)"

CURRENT="$(sed -n 's/^RADAR_IMAGE_TAG=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
say "stack:   $STACK"
say "current: ${CURRENT:-<unset>}"
say "new:     $TAG"
if [ "$TAG" = "$CURRENT" ] && [ "$FORCE" = 0 ]; then
  say "Already on this tag. Nothing to do (use --force to redeploy)."
  exit 0
fi
if [ "$DRY" = 1 ]; then
  say "dry run: would set RADAR_IMAGE_TAG=$TAG and run docker stack deploy"
  exit 0
fi
command -v docker >/dev/null 2>&1 || die "docker is required"

cp "$ENV_FILE" "${ENV_FILE}.bak"
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
awk -v tag="$TAG" 'BEGIN{done=0} /^RADAR_IMAGE_TAG=/ {print "RADAR_IMAGE_TAG=" tag; done=1; next} {print} END{if(!done) print "RADAR_IMAGE_TAG=" tag}' "$ENV_FILE" > "$TMP"
cat "$TMP" > "$ENV_FILE"; rm -f "$TMP"
say "wrote RADAR_IMAGE_TAG=$TAG (previous env file: ${ENV_FILE}.bak)"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
docker stack deploy --compose-file "$SCRIPT_DIR/stack.yaml" --resolve-image always "$STACK"

SERVICE="${STACK}_radar"
waited=0
while :; do
  state="$(docker service inspect "$SERVICE" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
  case "$state" in
    completed|"") replicas="$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | head -n 1)"
      if [ "${replicas%%/*}" = "${replicas##*/}" ] && [ "${replicas%%/*}" != 0 ]; then say "rollout completed ($replicas)"; break; fi ;;
    paused|rollback_started|rollback_completed|rollback_paused)
      docker service ps "$SERVICE" --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}' | head -n 6 >&2 || true
      die "rollout failed ($state). Swarm rolls back by itself; check: docker service ps $SERVICE ; previous settings: ${ENV_FILE}.bak" ;;
  esac
  [ "$waited" -lt 600 ] || die "rollout not finished after 600s (docker service ps $SERVICE)"
  sleep 3; waited=$((waited + 3))
done
say "to roll back manually: docker service rollback $SERVICE   (then restore ${ENV_FILE}.bak)"
