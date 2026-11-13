#!/usr/bin/env bash
# Shared helpers for deploy/swarm/update.sh and deploy/swarm/setup.sh. Source this file, do not execute it.
# Expects the caller to define: SCRIPT_DIR, say (log line) and die (log error and exit).

# Image repository from stack.yaml: ghcr.io/magicalwig34653/weather-backend-radar.
stack_image_base() {
  sed -n 's/^ *image: *\(ghcr\.io\/[^:$ ]*\).*/\1/p' "$SCRIPT_DIR/stack.yaml" | head -n 1
}

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

registry_token() {
  curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${REPO}:pull" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
# Digest of a tag (empty when the tag does not exist).
digest_of() {
  curl -fsSI -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}
# Commit the image of a tag was built from (label org.opencontainers.image.revision); empty when it cannot be read.
revision_of() {
  local index manifest config
  index="$(curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1")" || return 1
  manifest="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"digest":"sha256:[0-9a-f]*","size":[0-9]*,"platform":{"architecture":"\(amd64\|arm64\)"' | head -1 | grep -o 'sha256:[0-9a-f]*' || true)"
  if [ -n "$manifest" ]; then
    index="$(curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/${manifest}")" || return 1
  fi
  config="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"config":{[^}]*}' | grep -o 'sha256:[0-9a-f]*' | head -1 || true)"
  [ -n "$config" ] || return 1
  curl -fsSL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/blobs/${config}" \
    | grep -o '"org.opencontainers.image.revision":"[0-9a-f]*"' | head -1 | sed 's/.*:"\([0-9a-f]*\)"/\1/' || true
}

# Sets TAG to the newest sha-<commit> tag (the one whose digest equals FOLLOW_TAG, default edge).
# Needs IMAGE_BASE/REPO and curl; prints progress through say.
find_newest_sha_tag() {
  local FOLLOW_TAG="${FOLLOW_TAG:-edge}" candidate
  TAG=""
  say "Registry: ghcr.io, repository ${REPO}"
  TOKEN="$(registry_token)"; [ -n "$TOKEN" ] || die "could not get a registry token (is the package public?)"
  FOLLOW_DIGEST="$(digest_of "$FOLLOW_TAG")"; [ -n "$FOLLOW_DIGEST" ] || die "tag '${FOLLOW_TAG}' not found on ghcr.io"
  say "${FOLLOW_TAG} = ${FOLLOW_DIGEST}"
  REVISION="$(revision_of "$FOLLOW_TAG" || true)"
  if [ -n "$REVISION" ]; then
    candidate="sha-${REVISION:0:7}"
    if [ "$(digest_of "$candidate")" = "$FOLLOW_DIGEST" ]; then TAG="$candidate"; say "${FOLLOW_TAG} was built from commit ${REVISION:0:7} -> ${candidate} (verified)"; fi
  fi
  if [ -z "$TAG" ]; then
    say "Label lookup did not give a verified tag, comparing all sha- tags (slow with many images) ..."
    TAGS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list?n=1000" | grep -o '"sha-[0-9a-f]*"' | tr -d '"' || true)"
    [ -n "$TAGS" ] || die "no sha- tags found"
    for candidate in $TAGS; do
      if [ "$(digest_of "$candidate")" = "$FOLLOW_DIGEST" ]; then TAG="$candidate"; say "  ${candidate} matches ${FOLLOW_TAG}"; break; fi
    done
  fi
  [ -n "$TAG" ] || die "no sha- tag matches ${FOLLOW_TAG} (${FOLLOW_DIGEST}); pass --tag explicitly"
}

# Waits until the rolling update of a service finished (all replicas running); dies on rollback or timeout.
wait_for_rollout() {
  local BACKEND="$1" limit="${2:-600}" waited=0 last="" ustate replicas now
  while :; do
    ustate="$(docker service inspect "$BACKEND" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
    replicas="$(docker service ls --filter "name=${BACKEND}" --format '{{.Replicas}}' | head -n 1)"
    now="update=${ustate:-none} replicas=${replicas}"
    if [ "$now" != "$last" ]; then say "$now"; last="$now"; fi
    case "$ustate" in
      completed|"") case "$replicas" in */*) [ "${replicas%%/*}" = "${replicas##*/}" ] && [ "${replicas%%/*}" != 0 ] && { say "Rollout completed."; break; } ;; esac ;;
      paused|rollback_started|rollback_completed|rollback_paused)
        docker service inspect "$BACKEND" --format '{{.UpdateStatus.Message}}' >&2 || true
        docker service ps "$BACKEND" --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}' | head -n 6 >&2 || true
        die "rollout did not succeed (${ustate}); Swarm rolls back automatically" ;;
    esac
    [ "$waited" -lt "$limit" ] || die "rollout did not finish within ${limit}s (see: docker service ps ${BACKEND})"
    sleep 3; waited=$((waited + 3))
  done
}

# Push (optional): value of a KEY=VALUE line of an env file (last one wins, quotes stripped); empty when unset.
env_value() { sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d "\"'"; }

# APNs key secret (decision 2026-11-06): stack.yaml ALWAYS mounts the external secret apns_key, with and without push, so it must
# exist before every deploy; without this check `docker stack deploy` fails late with a bare "secret not found". With push off the
# server never reads the file: a placeholder secret is enough (setup.sh creates one on a fresh install without push).
# With PUSH_ENABLED=true the values APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC must be set as well.
# Name: APNS_KEY_SECRET (shell wins over the env file), default showernow_apns_key; exported for `docker stack deploy`.
# Usage: require_apns_secret [ENV_FILE]. Without ENV_FILE only the shell variables count. Needs docker; prints no secret value.
require_apns_secret() {
  local file="${1:-}" enabled="${PUSH_ENABLED-}" name="${APNS_KEY_SECRET-}" k
  if [ -n "$file" ] && [ -f "$file" ]; then
    [ -n "${PUSH_ENABLED+x}" ] || enabled="$(env_value "$file" PUSH_ENABLED)"
    [ -n "$name" ] || name="$(env_value "$file" APNS_KEY_SECRET)"
  fi
  name="${name:-showernow_apns_key}"; export APNS_KEY_SECRET="$name"
  docker secret inspect "$name" >/dev/null 2>&1 \
    || die "The Swarm secret '${name}' (APNs .p8 key) does not exist. stack.yaml always mounts it, also with PUSH_ENABLED=false. Create it first: docker secret create ${name} /path/to/AuthKey_XXXXXXXXXX.p8 - without push a placeholder is enough: printf 'placeholder, no APNs key\\n' | docker secret create ${name} - (later for push: new secret name plus APNS_KEY_SECRET, secrets cannot be changed). Nothing was changed."
  # Values check only with an env file (update.sh); swarm-deploy.sh checks the secret only, as before.
  [ -n "$file" ] && [ -f "$file" ] && [ "$enabled" = true ] || return 0
  local missing=""
  for k in APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC; do [ -n "$(env_value "$file" "$k")" ] || missing="$missing $k"; done
  [ -z "$missing" ] || die "PUSH_ENABLED=true, but these values are missing in ${file}:${missing}. Nothing was changed."
}

# Dashboard (optional): with DASH_ENABLED=true the overlay stack.dashboard.yaml must exist next to the scripts, otherwise stop with a
# clear message instead of deploying without the dashboard. DASH_ENABLED from the shell wins over the env file (like PUSH_ENABLED).
# Usage: require_dashboard_overlay [ENV_FILE]. Without ENV_FILE only the shell variable counts (swarm-deploy.sh already resolved it).
require_dashboard_overlay() {
  local file="${1:-}" enabled="${DASH_ENABLED-}"
  if [ -z "${DASH_ENABLED+x}" ] && [ -n "$file" ] && [ -f "$file" ]; then enabled="$(env_value "$file" DASH_ENABLED)"; fi
  [ "$enabled" = true ] || return 0
  [ -f "$SCRIPT_DIR/stack.dashboard.yaml" ] \
    || die "Dashboard-Overlay fehlt: diese Version enthält das Dashboard noch nicht (deploy/swarm/stack.dashboard.yaml nicht gefunden). DASH_ENABLED=true in der .env entfernen oder auf false setzen, oder zuerst update.sh --pull-scripts. Nothing was changed."
}

# Dashboard proxy token (DASH_ENABLED=true): the overlay always mounts the Swarm secrets dashboard_proxy_token (+ _previous). A missing
# secret would make `docker stack deploy` fail late (or the container abort at start), so stop early with the creation hint.
# Names: DASH_PROXY_TOKEN_SECRET (default showernow_dashboard_proxy_token); DASH_PROXY_TOKEN_PREVIOUS_SECRET defaults to the current one.
# Shell variables win over the env file. Usage: require_dashboard_secret [ENV_FILE]; exports both names for `docker stack deploy`.
require_dashboard_secret() {
  local file="${1:-}" enabled="${DASH_ENABLED-}" cur prev name
  if [ -z "${DASH_ENABLED+x}" ] && [ -n "$file" ] && [ -f "$file" ]; then enabled="$(env_value "$file" DASH_ENABLED)"; fi
  [ "$enabled" = true ] || return 0
  cur="${DASH_PROXY_TOKEN_SECRET-}"; prev="${DASH_PROXY_TOKEN_PREVIOUS_SECRET-}"
  if [ -n "$file" ] && [ -f "$file" ]; then
    [ -n "$cur" ] || cur="$(env_value "$file" DASH_PROXY_TOKEN_SECRET)"
    [ -n "$prev" ] || prev="$(env_value "$file" DASH_PROXY_TOKEN_PREVIOUS_SECRET)"
  fi
  cur="${cur:-showernow_dashboard_proxy_token}"; prev="${prev:-$cur}"
  export DASH_PROXY_TOKEN_SECRET="$cur" DASH_PROXY_TOKEN_PREVIOUS_SECRET="$prev"
  for name in "$cur" "$prev"; do
    docker secret inspect "$name" >/dev/null 2>&1 \
      || die "DASH_ENABLED=true, but the Swarm secret '${name}' (dashboard proxy token) does not exist. Create it first: umask 077; openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' > proxy-token.txt; docker secret create ${name} proxy-token.txt; put the same value into the reverse proxy as header X-Dashboard-Proxy-Token; rm proxy-token.txt (see docs-site dashboard.md). The Swarm stack always enforces the token (DASH_PROXY_TOKEN_REQUIRED=false has no effect there). Nothing was changed."
  done
}

# Dashboard (DASH_ENABLED=true): true when the dashboard is enabled. Shell variable wins over the env file (like require_dashboard_overlay).
# Usage: dashboard_enabled ENV_FILE
dashboard_enabled() {
  local file="${1:-}" enabled="${DASH_ENABLED-}"
  if [ -z "${DASH_ENABLED+x}" ] && [ -n "$file" ] && [ -f "$file" ]; then enabled="$(env_value "$file" DASH_ENABLED)"; fi
  [ "$enabled" = true ]
}

# Image reference a service is configured with, without the @sha256 digest that `docker stack deploy` may append; empty when the service is missing.
service_image() {
  docker service inspect "$1" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null | head -n 1 | sed 's/@sha256:[0-9a-f]*$//'
}

# Dashboard rollout check (single replica, short restart): waits for the rollout of STACK_dashboard, prints the image tags of BOTH services
# and verifies that the dashboard runs the target image. `docker stack deploy` only restarts a service when its spec changed: with an
# unchanged tag (e.g. edge), a deploy without the dashboard overlay (DASH_ENABLED unset) or an older deploy, the dashboard silently
# keeps its old image. On a mismatch the dashboard is forced onto the target image (FORCE=1, default) or the script stops with the command.
# Prints no secrets and calls no dashboard URL (the published port needs the proxy token); the health state is the task state of the service.
# Usage: check_dashboard_rollout STACK TARGET_IMAGE FORCE(1|0) WAIT_SECONDS. Needs docker; uses say/die/wait_for_rollout.
check_dashboard_rollout() {
  local stack="$1" target="$2" force="$3" limit="$4" svc="${1}_dashboard" have cmd
  have="$(service_image "$svc")"
  [ -n "$have" ] || die "DASH_ENABLED=true, but the service ${svc} does not exist. Deploy it with the overlay: deploy/swarm/swarm-deploy.sh (DASH_ENABLED=true in the env file or the shell)."
  if [ "$have" = "$target" ]; then
    wait_for_rollout "$svc" "$limit"
  else
    cmd="docker service update --force --image ${target} ${svc}"
    if [ "$force" = 1 ]; then
      say "WARNING: ${svc} still runs ${have}, target is ${target}. Forcing the update: ${cmd}"
      docker service update --detach --force --image "$target" "$svc" >/dev/null || die "could not update ${svc}; run by hand: ${cmd}"
      sleep 2
      wait_for_rollout "$svc" "$limit"
    else
      echo "[$(elapsed)] error: ${svc} runs ${have}, target is ${target} (the dashboard would show the old frontend). Run: ${cmd}" >&2
      exit 1
    fi
  fi
  say "Images:  ${stack}_radar -> $(service_image "${stack}_radar")"
  say "         ${svc} -> $(service_image "$svc")"
  have="$(service_image "$svc")"
  if [ "$have" != "$target" ]; then
    echo "[$(elapsed)] error: ${svc} runs ${have} instead of ${target} after the update. Run: docker service update --force --image ${target} ${svc}" >&2
    exit 1
  fi
  docker service ps "$svc" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'
  say "Dashboard health: a task only counts as Running after its healthcheck passed (start-first update); no request is sent to the dashboard port."
}

# Config check with the NEW image before anything is changed: `radar check-config` loads the operator environment exactly like
# `serve` (same LAYERS parser and rules) without database, network or secrets. The migration job keeps the environment of the
# previously deployed spec (only `--image` changes), so a changed .env would otherwise only show up when the radar tasks start.
# Usage: check_config_with_image ENV_FILE IMAGE. Needs docker; an image without the command (older than this check) is skipped
# with a notice. Returns 1 when the image refuses the configuration.
check_config_with_image() {
  local file="$1" image="$2" key out rc=0
  local -a args=(run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges)
  # Probe with an EMPTY environment first: an image older than the check loads the full configuration before it looks at the
  # command, so with the real values it would report e.g. "PUSH_ENABLED=true needs APNS_KEY_FILE..." (that file is a Swarm secret
  # that only exists in the service) instead of "usage". With the defaults alone it reaches the usage line, which identifies it.
  out="$(docker "${args[@]}" "$image" check-config 2>&1)" || rc=$?
  case "$out" in
    *"usage: radar"*) echo "Note: this image has no check-config command (older than the check); skipped." >&2; return 0 ;;
  esac
  rc=0
  while IFS= read -r key; do args+=(-e "$key"); done < <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$file" | sort -u)
  # shellcheck disable=SC1090  # operator env file, path is not constant
  out="$(set -a; . "$file"; set +a; docker "${args[@]}" "$image" check-config 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then printf '%s\n' "$out"; return 0; fi
  case "$out" in
    *"usage: radar"*) echo "Note: this image has no check-config command (older than the check); skipped." >&2; return 0 ;;
  esac
  printf '%s\n' "$out" >&2
  return 1
}

# Effective environment of a one-shot service from the NEW stack files. `docker service update --image` keeps the environment of
# the previously deployed spec, so a changed .env (e.g. LAYERS) would not reach the migration job before the final
# `docker stack deploy`. This renders the stack (`docker stack config`, same variable substitution as the deploy) and prints
# `--env-rm KEY` for keys that are no longer in the new spec and `--env-add KEY=VALUE` for all new ones, one argument per line.
# Usage: service_env_sync_args STACK SERVICE STACK_ARG... (stack args like -c stack.yaml). Returns 1 when the stack cannot be rendered.
service_env_sync_args() {
  local stack="$1" svc="$2" rendered key line; shift 2
  rendered="$(docker stack config "$@" 2>/dev/null)" || return 1
  local -a new_keys=()
  while IFS= read -r line; do
    key="${line%%$'\t'*}"; new_keys+=("$key")
  done < <(printf '%s\n' "$rendered" | _service_env_pairs "$svc")
  while IFS= read -r line; do
    key="${line%%=*}"; [ -n "$key" ] || continue
    printf '%s\n' "${new_keys[@]}" | grep -Fxq -- "$key" || printf '%s\n%s\n' --env-rm "$key"
  done < <(docker service inspect --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' "${stack}_${svc}" 2>/dev/null || true)
  while IFS= read -r line; do
    printf '%s\n%s=%s\n' --env-add "${line%%$'\t'*}" "${line#*$'\t'}"
  done < <(printf '%s\n' "$rendered" | _service_env_pairs "$svc")
}
# Reads `docker stack config` output on stdin; prints KEY<TAB>VALUE of the environment of one service (values unquoted).
_service_env_pairs() {
  awk -v svc="$1" '
    /^  [A-Za-z0-9_-]+:[ ]*$/ { insvc = ($1 == svc ":"); inenv = 0; next }
    insvc && /^    environment:[ ]*$/ { inenv = 1; next }
    insvc && inenv && /^      [^ ]/ {
      line = substr($0, 7); i = index(line, ":"); k = substr(line, 1, i - 1); v = substr(line, i + 1); sub(/^[ ]+/, "", v)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v) }
      else if (v ~ /^'"'"'.*'"'"'$/) { v = substr(v, 2, length(v) - 2); gsub(/'"'"''"'"'/, "'"'"'", v) }
      print k "\t" v; next }
    insvc && inenv && !/^      / { inenv = 0 }
  '
}
