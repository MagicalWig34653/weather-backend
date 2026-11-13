#!/usr/bin/env bash
# Run from a manager. A Swarm config provides a cross-host deployment mutex.
set -euo pipefail
cd "$(dirname "$0")"
STACK=${STACK:-radar}
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || exit 2
lock="${STACK}_deployment-lock"
printf 'deployment in progress\n' | docker config create "$lock" - >/dev/null
migration_running=0
cleanup() {
  if [[ $migration_running == 1 ]]; then
    echo "Migration state uncertain; deployment lock retained: $lock. Inspect task before manually removing lock." >&2
  else
    docker config rm "$lock" >/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
image=${RADAR_MIGRATE_IMAGE:-ghcr.io/magicalwig34653/weather-backend-radar:${RADAR_IMAGE_TAG:-edge}}
# RADAR_MIGRATE_IMAGE (full reference) only overrides the migration image and must match an override file
# if the stack image is overridden too. Extra stack files (e.g. overrides) may be passed as space-separated STACK_EXTRA_FILES.
compose_args=(-c stack.yaml)
# Optional push: only when PUSH_ENABLED=true (needs the external secret apns_key, see stack.push.yaml). Without push the
# stack does not reference the secret, so a missing secret cannot break the rollout.
# PUSH_ENABLED / APNS_KEY_SECRET normally come from the caller's environment (update.sh and setup.sh source the env file).
# If they are not set there (e.g. swarm-deploy.sh started by hand), read them from the env file (ENV_FILE, ./.env or
# ../../.env) so that the overlay is not skipped silently. The shell environment always wins.
SCRIPT_DIR="$(pwd)"
say() { echo "$*"; }
die() { echo "$*" >&2; exit 1; }
# shellcheck source=lib.sh
. ./lib.sh
if [[ -z "${PUSH_ENABLED+x}" || -z "${APNS_KEY_SECRET+x}" || -z "${DASH_ENABLED+x}" || -z "${DASH_PROXY_TOKEN_SECRET+x}" || -z "${DASH_PROXY_TOKEN_PREVIOUS_SECRET+x}" ]]; then
  for envf in "${ENV_FILE:-}" "$PWD/../../.env" "$PWD/.env"; do
    [[ -n "$envf" && -f "$envf" ]] || continue
    [[ -n "${PUSH_ENABLED+x}" ]] || PUSH_ENABLED="$(env_value "$envf" PUSH_ENABLED)"
    [[ -n "${DASH_ENABLED+x}" ]] || DASH_ENABLED="$(env_value "$envf" DASH_ENABLED)"
    [[ -n "${APNS_KEY_SECRET+x}" ]] || APNS_KEY_SECRET="$(env_value "$envf" APNS_KEY_SECRET)"
    [[ -n "${DASH_PROXY_TOKEN_SECRET+x}" ]] || DASH_PROXY_TOKEN_SECRET="$(env_value "$envf" DASH_PROXY_TOKEN_SECRET)"
    [[ -n "${DASH_PROXY_TOKEN_PREVIOUS_SECRET+x}" ]] || DASH_PROXY_TOKEN_PREVIOUS_SECRET="$(env_value "$envf" DASH_PROXY_TOKEN_PREVIOUS_SECRET)"
    break
  done
fi
if [[ "${PUSH_ENABLED:-false}" == true ]]; then
  docker secret inspect "${APNS_KEY_SECRET:-showernow_apns_key}" >/dev/null 2>&1 \
    || { echo "PUSH_ENABLED=true, but the Swarm secret ${APNS_KEY_SECRET:-showernow_apns_key} does not exist (docker secret create ${APNS_KEY_SECRET:-showernow_apns_key} AuthKey_XXXXXXXXXX.p8)." >&2; exit 1; }
  compose_args+=(-c stack.push.yaml)
  echo "Push enabled: stack files ${compose_args[*]}"
fi
# Optional dashboard (DASH_ENABLED=true): own service "dashboard" from the overlay stack.dashboard.yaml (one ingress port, see the overlay).
# The overlay exists since the dashboard work package; it stops with a clear message when the file is missing (old scripts folder).
if [[ "${DASH_ENABLED:-false}" == true ]]; then
  require_dashboard_overlay ""
  compose_args+=(-c stack.dashboard.yaml)
  # The proxy token is a Swarm secret that the overlay always mounts: check it before anything is deployed (clear error instead of a
  # failed deploy or a container that aborts at start). Also exports the secret names for `docker stack deploy`.
  require_dashboard_secret ""
  # DASH_ORIGIN is required (the overlay aborts without it). DASH_RP_ID is optional: when empty, use the host of DASH_ORIGIN
  # (no scheme, no port, lower case) - the WebAuthn RP ID must be a registrable domain suffix of that host.
  if [[ -z "${DASH_RP_ID:-}" && -n "${DASH_ORIGIN:-}" ]]; then
    rp="${DASH_ORIGIN#*://}"; rp="${rp%%/*}"; rp="${rp%%:*}"
    DASH_RP_ID="$(printf '%s' "$rp" | tr '[:upper:]' '[:lower:]')"; export DASH_RP_ID
  fi
  echo "Dashboard enabled: stack files ${compose_args[*]}"
fi
for f in ${STACK_EXTRA_FILES:-}; do compose_args+=(-c "$f"); done
# The DB is external: the one-shot migration below fails (without retry) if the DB is unreachable.
# Required: DB_HOST and the external secrets (see .env.example).
replicas=${RADAR_REPLICAS:-2}
if ! docker service inspect "${STACK}_radar" >/dev/null 2>&1; then
  # radar-pinned (PINNED_REPLICAS) must not start before the migration either.
  RADAR_REPLICAS=0 PINNED_REPLICAS=0 docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
fi
old_tasks=$(docker service ps --no-trunc --format '{{.ID}}' "${STACK}_migrate")
docker service scale "${STACK}_migrate=0" >/dev/null
migration_running=1
# The migration job must run with the effective environment of the NEW .env: `--image` alone keeps the old service environment
# (a stale LAYERS from a rolled-back update made the migration fail although .env and check-config were fine).
env_args=()
if env_out="$(service_env_sync_args "$STACK" migrate "${compose_args[@]}")"; then
  while IFS= read -r line; do [[ -n "$line" ]] && env_args+=("$line"); done <<< "$env_out"
else
  echo "Warning: docker stack config failed; the migration job keeps its previous environment." >&2
fi
docker service update --detach --image "$image" --force --replicas 1 ${env_args[@]+"${env_args[@]}"} "${STACK}_migrate" >/dev/null
for ((i=0; i<120; i++)); do
  task=''
  while IFS= read -r candidate; do
    if ! grep -Fxq "$candidate" <<< "$old_tasks"; then task=$candidate; break; fi
  done < <(docker service ps --no-trunc --format '{{.ID}}' "${STACK}_migrate")
  if [[ -z "$task" ]]; then sleep 2; continue; fi
  state=$(docker inspect --format '{{.Status.State}}' "$task")
  case "$state" in
    complete) migration_running=0; break ;;
    failed|rejected) migration_running=0; echo "Migration failed: $task" >&2; exit 1 ;;
  esac
  sleep 2
done
[[ $i -lt 120 ]] || { echo 'Migration timeout' >&2; exit 1; }
RADAR_REPLICAS=$replicas docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
echo "Migration complete; rollout started for $replicas replicas. Check health before accepting rollout."
