#!/usr/bin/env bash
# Update a running Swarm stack to the newest published backend image: find the newest `sha-<commit>` tag on GHCR,
# write it into the env file (RADAR_IMAGE_TAG), run the migration job with the new image (deploy/swarm/swarm-deploy.sh,
# which holds the cross-host deployment lock), then watch the rolling update and the readiness check.
#
# Usage: deploy/swarm/update.sh [options]
#   --env-file FILE   stack variables (default: ./.env, else .env in the top folder of the checkout)
#   --tag TAG         use this tag (e.g. sha-6c074f7 or 0.1.0) instead of looking up the newest sha- tag
#   --stack NAME      stack name (default: radar)
#   --dry-run         only show what would happen (no file change, no docker calls)
#   --pull-scripts    first update the deploy scripts: `git pull --ff-only` in this checkout (clone of the deploy branch),
#                     then restart update.sh from the new files; .env is untracked and stays untouched
#   --force           also redeploy when the tag did not change
#   --no-dashboard-force  with DASH_ENABLED=true the dashboard service is checked after the rollout and, if it still runs another
#                     image than the target, forced onto it (docker service update --force --image ...); with this option the
#                     script only stops with an error and the command instead
#   --skip-config-check  do not run `radar check-config` of the new image against the env file before the update
#   --yes             do not ask for confirmation
#
# How the newest tag is found: the Docker workflow pushes `edge` (newest main build) together with `sha-<commit>`
# on every push to main (and `latest`/semver tags for v* tags). The sha- tag whose digest equals `edge` is the newest
# build. It is found in constant time via the image label org.opencontainers.image.revision (verified against the
# digest of `edge`); comparing all tags is only a fallback. Needs curl and docker.
# Back up the database first (mysqldump or your usual backup).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")
STACK=radar
STACK_SET=0
ENV_FILE=""
TAG=""
DRY=0
FORCE=0
DASH_FORCE=1
PULL=0
YES=0
SKIP_CHECK=0
FOLLOW_TAG=edge # used by lib.sh
export FOLLOW_TAG
WAIT_SECONDS=600

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --tag) TAG="${2:?missing value for --tag}"; shift 2 ;;
    --stack) STACK="${2:?missing value for --stack}"; STACK_SET=1; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --pull-scripts) PULL=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-dashboard-force) DASH_FORCE=0; shift ;;
    --skip-config-check) SKIP_CHECK=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid stack name: $STACK" >&2; exit 64; }

START_TIME=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START_TIME )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
STEP=0; STEPS=6
step() { STEP=$((STEP + 1)); printf '\n[%s] == Step %d/%d: %s\n' "$(elapsed)" "$STEP" "$STEPS" "$*"; }
ENV_WRITTEN=0
die() {
  echo "[$(elapsed)] error: $*" >&2
  # The stack was not (or no longer) running the new tag: put the previous tag back so the env file matches reality.
  if [ "$ENV_WRITTEN" = 1 ] && [ -f "${ENV_FILE}.bak" ]; then cp "${ENV_FILE}.bak" "$ENV_FILE"; echo "[$(elapsed)] restored ${ENV_FILE} from ${ENV_FILE}.bak" >&2; fi
  exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need curl
[ "$DRY" = 1 ] || need docker

# Optional: bring the deploy scripts to the newest state of the deploy branch (flat clone), then run the new update.sh.
if [ "$PULL" = 1 ] && [ -z "${RADAR_SCRIPTS_PULLED:-}" ]; then
  need git
  git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "--pull-scripts needs a git checkout (git clone --depth 1 --branch deploy ...); this directory is none"
  if [ "$DRY" = 1 ]; then
    say "Dry run: would run git pull --ff-only in $(git -C "$SCRIPT_DIR" rev-parse --show-toplevel) and restart update.sh."
  else
    say "Updating the deploy scripts (git pull --ff-only)"
    git -C "$SCRIPT_DIR" pull --ff-only || die "git pull failed (local changes in tracked files or diverged history?); nothing was changed"
    args=(); for a in "${ORIG_ARGS[@]}"; do [ "$a" = --pull-scripts ] || args+=("$a"); done
    RADAR_SCRIPTS_PULLED=1 exec "$SCRIPT_DIR/update.sh" "${args[@]+"${args[@]}"}"
  fi
fi

if [ -z "$ENV_FILE" ]; then
  if [ -f ./.env ]; then ENV_FILE=./.env
  elif [ -f "$SCRIPT_DIR/../../.env" ]; then ENV_FILE="$SCRIPT_DIR/../../.env"
  else die "no .env found; run deploy/swarm/setup.sh or pass --env-file"; fi
fi
[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"

# setup.sh records the stack name as RADAR_STACK; --stack wins.
if [ "$STACK_SET" = 0 ]; then
  env_stack="$(sed -n 's/^RADAR_STACK=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
  if [ -n "$env_stack" ]; then STACK="$env_stack"; fi
  [[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid stack name: $STACK"
fi

# Image repository: ghcr.io/magicalwig34653/weather-backend-radar (the same name as in stack.yaml).
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
IMAGE_BASE="$(stack_image_base)"
[ -n "$IMAGE_BASE" ] || die "cannot read the ghcr.io image name from stack.yaml"
REPO="${IMAGE_BASE#ghcr.io/}"; export REPO # used by lib.sh
CURRENT_TAG="$(sed -n 's/^RADAR_IMAGE_TAG=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
CURRENT_TAG="${CURRENT_TAG:-edge}"
CURRENT_IMAGE="${IMAGE_BASE}:${CURRENT_TAG}"

# Dashboard enabled (DASH_ENABLED=true in the shell or the env file) but the overlay is missing: stop before anything changes.
require_dashboard_overlay "$ENV_FILE"

step "Find the newest image tag"
if [ -z "$TAG" ]; then
  find_newest_sha_tag
else
  say "Using the tag from --tag: ${TAG}"
fi

NEW_IMAGE="${IMAGE_BASE}:${TAG}"
echo "Stack:     ${STACK}"
echo "Env file:  ${ENV_FILE}"
echo "Current:   ${CURRENT_IMAGE}"
echo "New:       ${NEW_IMAGE}"

if [ "$TAG" = "$CURRENT_TAG" ] && [ "$FORCE" = 0 ]; then
  # The dashboard is a separate service that a deploy without the overlay or with an unchanged spec leaves on its old image: check it anyway.
  if [ "$DRY" = 0 ] && dashboard_enabled "$ENV_FILE"; then
    step "Check the dashboard service (tag unchanged)"
    check_dashboard_rollout "$STACK" "$NEW_IMAGE" "$DASH_FORCE" "$WAIT_SECONDS"
  fi
  echo "Already on the newest tag. Nothing to do (use --force to redeploy anyway)."
  exit 0
fi
if [ "$DRY" = 1 ]; then
  echo "Dry run: would (with PUSH_ENABLED=true: check the APNs key secret; with DASH_ENABLED=true: the dashboard proxy token secret; then) set RADAR_IMAGE_TAG=${TAG}, run the migration job, then roll ${STACK}_radar."
  if dashboard_enabled "$ENV_FILE"; then
    if [ "$DASH_FORCE" = 1 ]; then force_txt="forced onto the target image if it still runs another one"; else force_txt="error with the command if it runs another image (--no-dashboard-force)"; fi
    echo "Dry run: DASH_ENABLED=true -> afterwards wait for ${STACK}_dashboard, show the image tags of both services, dashboard ${force_txt}."
  fi
  exit 0
fi

# Push enabled: the APNs key secret must exist before anything is rolled out (clear error instead of a failed deploy).
require_push_secret "$ENV_FILE"
# Dashboard enabled: the proxy token secret must exist as well (same early, clear error).
require_dashboard_secret "$ENV_FILE"

step "Confirm"
if [ "$YES" = 0 ]; then
  printf 'Database backed up? Continue with the update? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|j|J|ja) ;; *) echo "Aborted."; exit 1 ;; esac
else
  say "Confirmation skipped (--yes)."
fi

step "Check the configuration with the new image"
if [ "$SKIP_CHECK" = 1 ]; then
  say "Skipped (--skip-config-check)."
else
  say "docker run --rm ${NEW_IMAGE} check-config (env file values, no database, no network)"
  check_config_with_image "$ENV_FILE" "$NEW_IMAGE" \
    || die "the new image refuses the configuration in ${ENV_FILE} (see above); nothing was changed. Fix the value (settings.sh) and run update.sh again"
fi

step "Write the new tag into ${ENV_FILE}"
cp "$ENV_FILE" "${ENV_FILE}.bak"
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
awk -v tag="$TAG" 'BEGIN{done=0} /^RADAR_IMAGE_TAG=/ {print "RADAR_IMAGE_TAG=" tag; done=1; next} {print} END{if(!done) print "RADAR_IMAGE_TAG=" tag}' "$ENV_FILE" > "$TMP"
cat "$TMP" > "$ENV_FILE"; rm -f "$TMP"
ENV_WRITTEN=1
say "Wrote RADAR_IMAGE_TAG=${TAG} (backup: ${ENV_FILE}.bak)."

step "Migrate and start the rolling update (deploy/swarm/swarm-deploy.sh)"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
export RADAR_IMAGE_TAG="$TAG" STACK
"$SCRIPT_DIR/swarm-deploy.sh" || die "migration or deployment failed; the previous tag stays in use"

step "Watch the rollout and check the result"
SERVICE="${STACK}_radar"
wait_for_rollout "$SERVICE" "$WAIT_SECONDS"
docker service ps "$SERVICE" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'
if dashboard_enabled "$ENV_FILE"; then
  check_dashboard_rollout "$STACK" "$NEW_IMAGE" "$DASH_FORCE" "$WAIT_SECONDS"
else
  say "DASH_ENABLED is not true: the dashboard service is not touched (an existing ${STACK}_dashboard keeps its old image)."
fi

BASE_URL="${PUBLIC_BASE_URL:-}"
if [ -n "$BASE_URL" ]; then
  # latest.json answers 200 (data available) or 404 (no run published yet); anything else means the proxy or service is broken.
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "${BASE_URL%/}/v1/radar/latest.json" 2>/dev/null || true)"; code="${code:-000}"
  case "$code" in
    200) say "GET ${BASE_URL%/}/v1/radar/latest.json -> 200" ;;
    404) say "GET ${BASE_URL%/}/v1/radar/latest.json -> 404 (no run published yet; the first run follows within a few minutes)" ;;
    *) say "WARNING: GET ${BASE_URL%/}/v1/radar/latest.json -> HTTP ${code} (reverse proxy, DNS or TLS?)" ;;
  esac
else
  say "PUBLIC_BASE_URL is not set in the env file; skipping the public readiness check."
fi
say "Done in $(elapsed)."
