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
