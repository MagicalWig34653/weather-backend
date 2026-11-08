#!/usr/bin/env bash
# Offline test of swarm-deploy.sh with a stub `docker` (no Swarm needed): checks that the overlay stack.push.yaml is part of
# `docker stack deploy` exactly when push is enabled (shell variable or env file), and that a missing secret aborts the rollout.
# Same for the dashboard overlay stack.dashboard.yaml (DASH_ENABLED): present -> included, missing -> clear abort, shell wins over the env file.
# Usage: deploy/swarm/test-swarm-deploy.sh   (needs bash only; not part of the deploy branch)
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/deploy/swarm" "$WORK/bin"
cp "$SRC"/swarm-deploy.sh "$SRC"/update.sh "$SRC"/lib.sh "$SRC"/stack.yaml "$SRC"/stack.push.yaml "$WORK/repo/deploy/swarm/"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $* [rp=${DASH_RP_ID:-}]" >> "$STUB_LOG"
case "$1 $2" in
  "config create") cat > /dev/null ;;  # read the piped lock text like docker does (else printf dies with SIGPIPE under pipefail: flaky rc 141)
esac
case "$1 $2" in
  "run --rm")
    # STUB_CHECK_OLD: image without check-config (loads the config first: refuses with the real values because APNS_KEY_FILE is a
    # service secret, prints usage with the defaults). STUB_CHECK_FAIL: new image refusing the values (only when -e values are passed).
    if [ "${STUB_CHECK_OLD:-no}" = yes ]; then
      case "$*" in *" -e "*) echo "error: PUSH_ENABLED=true needs APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC" >&2 ;; *) echo "usage: radar [serve | migrate --yes]" >&2 ;; esac
      exit 1
    fi
    case "$*" in *" -e "*) [ "${STUB_CHECK_FAIL:-no}" = yes ] && { echo "error: LAYERS: unknown layer 'x'" >&2; exit 1; } ;; esac ;;
  "secret inspect") [ "${STUB_SECRET:-yes}" = yes ] || exit 1 ;;
  "service inspect")
    case "$*" in
      *ContainerSpec.Image*) case "$3" in
          *_dashboard) [ "${STUB_DASH_MISSING:-no}" = yes ] && exit 1; cat "$STUB_LOG.dashimg" 2>/dev/null || echo "${STUB_DASH_IMAGE:-}" ;;
          *) echo "${STUB_RADAR_IMAGE:-}" ;; esac ;;
      *UpdateStatus*) echo completed ;;
      *) exit 1 ;;
    esac ;;
  "service ls") echo 1/1 ;;
  "service update") case "$*" in *_dashboard*) while [ $# -gt 0 ]; do [ "$1" != --image ] || echo "$2" > "$STUB_LOG.dashimg"; shift; done ;; esac ;;
  "service ps")
    n=$(cat "$STUB_LOG.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_LOG.n"
    echo old; [ "$n" -eq 0 ] || echo new ;;
esac
[ "$1" != inspect ] || echo complete
exit 0
STUB
chmod +x "$WORK/bin/docker"
fail=0
run() { # name, expect_overlay(yes|no|abort), env assignments...
  local name="$1" expect="$2"; shift 2
  export STUB_LOG="$WORK/$name.log"; : > "$STUB_LOG"; rm -f "$STUB_LOG.n"
  local rc=0
  ( cd "$WORK/repo/deploy/swarm" && env -u PUSH_ENABLED -u APNS_KEY_SECRET -u DASH_ENABLED -u DASH_PROXY_TOKEN_SECRET -u DASH_PROXY_TOKEN_PREVIOUS_SECRET -u ENV_FILE PATH="$WORK/bin:$PATH" DB_HOST=db "$@" ./swarm-deploy.sh ) >"$WORK/$name.out" 2>&1 || rc=$?
  local deploys overlay
  deploys=$(grep -c 'stack deploy' "$STUB_LOG" || true); overlay=$(grep 'stack deploy' "$STUB_LOG" | grep -c "${CHECK:-stack.push.yaml}" || true)
  case "$expect" in
    yes) [ "$rc" = 0 ] && [ "$deploys" -ge 1 ] && [ "$overlay" = "$deploys" ] ;;
    no) [ "$rc" = 0 ] && [ "$deploys" -ge 1 ] && [ "$overlay" = 0 ] ;;
    abort) [ "$rc" != 0 ] && [ "$deploys" = 0 ] ;;
  esac
  local verdict=$?
  if [ "$verdict" = 0 ]; then echo "ok   $name"; else echo "FAIL $name (rc=$rc, stack deploy: $deploys, with overlay: $overlay)"; cat "$WORK/$name.out"; fail=1; fi
}
printf 'PUSH_ENABLED=true\nAPNS_KEY_SECRET=my_key\n' > "$WORK/push.env"
printf 'PUSH_ENABLED=false\n' > "$WORK/nopush.env"
run shell-true yes PUSH_ENABLED=true
run shell-false no PUSH_ENABLED=false
run nothing-set no
run envfile-true yes ENV_FILE="$WORK/push.env"
run envfile-false no ENV_FILE="$WORK/nopush.env"
cp "$WORK/push.env" "$WORK/repo/.env"
run default-dotenv-true yes
run shell-wins no PUSH_ENABLED=false
run secret-missing abort STUB_SECRET=no PUSH_ENABLED=true
grep -q 'secret inspect my_key' "$WORK/envfile-true.log" || { echo "FAIL secret name from env file not used"; fail=1; }

# ---- dashboard overlay (DASH_ENABLED) ----
rm -f "$WORK/repo/.env"
CHECK=stack.dashboard.yaml
run dash-missing-aborts abort DASH_ENABLED=true
grep -q 'Dashboard-Overlay fehlt' "$WORK/dash-missing-aborts.out" || { echo "FAIL message for the missing overlay"; fail=1; }
run dash-off-no-overlay no DASH_ENABLED=false
printf 'DASH_ENABLED=true\n' > "$WORK/dash.env"
run dash-envfile-missing-aborts abort ENV_FILE="$WORK/dash.env"
printf 'DASH_ENABLED=true\n' > "$WORK/repo/.env"
run dash-dotenv-missing-aborts abort
run dash-shell-false-wins no DASH_ENABLED=false
echo 'services: {}' > "$WORK/repo/deploy/swarm/stack.dashboard.yaml"
run dash-present-included yes DASH_ENABLED=true
run dash-dotenv-present-included yes
run dash-shell-false-wins-present no DASH_ENABLED=false
rm -f "$WORK/repo/.env"
printf 'PUSH_ENABLED=true\nDASH_ENABLED=true\n' > "$WORK/both.env"
run both-dashboard-part yes ENV_FILE="$WORK/both.env"
CHECK=stack.push.yaml
run both-push-part yes ENV_FILE="$WORK/both.env"
unset CHECK
# With the real overlay: DASH_RP_ID defaults to the host of DASH_ORIGIN (lower case, no scheme/port/path); an explicit value wins.
cp "$SRC/stack.dashboard.yaml" "$WORK/repo/deploy/swarm/stack.dashboard.yaml"
# Real overlay: exactly one published ingress port, target = listener port, never host mode.
ov="$SRC/stack.dashboard.yaml"
if ! { grep -Eq '^ +- target: \$\{DASH_PORT:-9090\}$' "$ov" && grep -Eq '^ +published: \$\{DASH_PUBLISH_PORT:-39090\}$' "$ov" \
  && grep -Eq '^ +mode: ingress$' "$ov" && ! grep -Eq '^ +mode: host$' "$ov" && [ "$(grep -cE '^ +- target:' "$ov")" = 1 ]; }; then
  echo "FAIL dashboard overlay port block"; fail=1
fi
CHECK=stack.dashboard.yaml
run dash-real-overlay yes DASH_ENABLED=true DASH_ORIGIN=https://dash.example.internal
run dash-rp-derived yes DASH_ENABLED=true DASH_ORIGIN=https://Dash.Example.internal:8443/
grep -q 'stack deploy.*\[rp=dash.example.internal\]' "$WORK/dash-rp-derived.log" || { echo "FAIL RP ID not derived from DASH_ORIGIN"; fail=1; }
run dash-rp-explicit yes DASH_ENABLED=true DASH_ORIGIN=https://dash.example.internal DASH_RP_ID=example.internal
grep -q 'stack deploy.*\[rp=example.internal\]' "$WORK/dash-rp-explicit.log" || { echo "FAIL explicit DASH_RP_ID overridden"; fail=1; }
run dash-off-no-rp no DASH_ENABLED=false DASH_ORIGIN=https://dash.example.internal
grep -q '\[rp=\]' "$WORK/dash-off-no-rp.log" || { echo "FAIL RP ID derived although the dashboard is off"; fail=1; }
run dash-push-and-dash yes DASH_ENABLED=true PUSH_ENABLED=true DASH_ORIGIN=https://dash.example.internal
CHECK=stack.push.yaml
run dash-push-and-dash-push yes DASH_ENABLED=true PUSH_ENABLED=true DASH_ORIGIN=https://dash.example.internal
unset CHECK

# ---- dashboard proxy token secret (DASH_ENABLED=true): checked before any deploy, names from shell or env file ----
CHECK=stack.dashboard.yaml
run dash-token-secret-missing abort STUB_SECRET=no DASH_ENABLED=true DASH_ORIGIN=https://dash.example.internal
grep -q "secret 'showernow_dashboard_proxy_token' (dashboard proxy token) does not exist" "$WORK/dash-token-secret-missing.out" || { echo "FAIL message for the missing proxy token secret"; fail=1; }
run dash-token-secret-present yes DASH_ENABLED=true DASH_ORIGIN=https://dash.example.internal
grep -q 'secret inspect showernow_dashboard_proxy_token' "$WORK/dash-token-secret-present.log" || { echo "FAIL default token secret name not checked"; fail=1; }
run dash-off-no-token-check no DASH_ENABLED=false STUB_SECRET=no
! grep -q 'secret inspect' "$WORK/dash-off-no-token-check.log" || { echo "FAIL secret checked although the dashboard is off"; fail=1; }
printf 'DASH_ENABLED=true\nDASH_ORIGIN=https://dash.example.internal\nDASH_PROXY_TOKEN_SECRET=tok_new\nDASH_PROXY_TOKEN_PREVIOUS_SECRET=tok_old\n' > "$WORK/rot.env"
run dash-token-rotation-names yes ENV_FILE="$WORK/rot.env"
if ! { grep -q 'secret inspect tok_new' "$WORK/dash-token-rotation-names.log" && grep -q 'secret inspect tok_old' "$WORK/dash-token-rotation-names.log"; }; then
  echo "FAIL rotation: both secret names must be checked"; fail=1
fi
printf 'DASH_ENABLED=true\nDASH_ORIGIN=https://dash.example.internal\nDASH_PROXY_TOKEN_SECRET=tok_only\n' > "$WORK/one.env"
run dash-token-previous-defaults-to-current yes ENV_FILE="$WORK/one.env"
[ "$(grep -c 'secret inspect tok_only' "$WORK/dash-token-previous-defaults-to-current.log")" = 2 ] || { echo "FAIL previous token secret must default to the current one"; fail=1; }
run dash-token-shell-wins yes ENV_FILE="$WORK/one.env" DASH_PROXY_TOKEN_SECRET=tok_shell
grep -q 'secret inspect tok_shell' "$WORK/dash-token-shell-wins.log" || { echo "FAIL shell secret name must win over the env file"; fail=1; }
# The real overlay mounts exactly the proxy token secrets besides db_password and no APNs key.
if ! { grep -q 'DASH_PROXY_TOKEN_FILE: /run/secrets/dashboard_proxy_token$' "$ov" && grep -q 'secrets: \[db_password, dashboard_proxy_token, dashboard_proxy_token_previous\]' "$ov" \
  && ! grep -v '^ *#' "$ov" | grep -qiE 'apns_key_file|secrets:.*apns'; }; then echo "FAIL dashboard overlay secrets"; fail=1; fi
unset CHECK

# ---- update.sh stops before any change when the overlay is missing (dry run, no network: --tag given) ----
upd() { # name, expect_rc0(yes|no), env-file content
  local name="$1" expect="$2" rc=0
  printf '%s' "$3" > "$WORK/upd.env"
  ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED PATH="$WORK/bin:$PATH" ./update.sh --env-file "$WORK/upd.env" --tag sha-abc1234 --dry-run ) >"$WORK/$name.out" 2>&1 || rc=$?
  if { [ "$expect" = yes ] && [ "$rc" = 0 ]; } || { [ "$expect" = no ] && [ "$rc" != 0 ] && grep -q 'Dashboard-Overlay fehlt' "$WORK/$name.out"; }; then
    echo "ok   $name"
  else echo "FAIL $name (rc=$rc)"; cat "$WORK/$name.out"; fail=1; fi
}
rm -f "$WORK/repo/deploy/swarm/stack.dashboard.yaml"
upd update-dash-missing no $'DASH_ENABLED=true\n'
upd update-dash-off yes $'DASH_ENABLED=false\n'
echo 'services: {}' > "$WORK/repo/deploy/swarm/stack.dashboard.yaml"
upd update-dash-present yes $'DASH_ENABLED=true\n'

# ---- update.sh: rollout check of the dashboard service (full run against the stub, no network: --tag given) ----
# Target image = IMAGE_BASE:TAG. Old tag -> forced (docker service update --force --image); new tag -> nothing forced;
# DASH_ENABLED=false -> the dashboard is not touched; --no-dashboard-force -> error with the command, no update.
IMG=ghcr.io/magicalwig34653/weather-backend-radar
dupd() { # name, expect(ok|force|error|untouched), dashboard image, update.sh args..., env: DASH_ENABLED line in $WORK/d.env
  local name="$1" expect="$2" dimg="$3" rc=0; shift 3
  export STUB_LOG="$WORK/$name.log"; : > "$STUB_LOG"; rm -f "$STUB_LOG.n" "$STUB_LOG.dashimg"
  ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED PATH="$WORK/bin:$PATH" DB_HOST=db STUB_RADAR_IMAGE="$IMG:sha-new1234" STUB_DASH_IMAGE="$dimg" \
      ./update.sh --env-file "$WORK/d.env" --tag sha-new1234 --yes "$@" ) >"$WORK/$name.out" 2>&1 || rc=$?
  local forced=0 ok=0
  grep -q "service update.*--image $IMG:sha-new1234.*_dashboard" "$STUB_LOG" && forced=1
  case "$expect" in
    ok) [ "$rc" = 0 ] && [ "$forced" = 0 ] && grep -q "_dashboard -> $IMG:sha-new1234" "$WORK/$name.out" && ok=1 ;;
    force) [ "$rc" = 0 ] && [ "$forced" = 1 ] && grep -q 'WARNING: .*_dashboard still runs' "$WORK/$name.out" && ok=1 ;;
    error) [ "$rc" != 0 ] && [ "$forced" = 0 ] && grep -q 'docker service update --force --image .*_dashboard' "$WORK/$name.out" && ok=1 ;;
    untouched) [ "$rc" = 0 ] && [ "$forced" = 0 ] && ! grep -q '_dashboard' "$STUB_LOG" && ok=1 ;;
  esac
  if [ "$ok" = 1 ]; then echo "ok   $name"; else echo "FAIL $name (rc=$rc, forced=$forced)"; cat "$WORK/$name.out"; fail=1; fi
}
cp "$SRC/stack.dashboard.yaml" "$WORK/repo/deploy/swarm/stack.dashboard.yaml"
printf 'DASH_ENABLED=true\nDASH_ORIGIN=https://dash.example.internal\nRADAR_IMAGE_TAG=sha-old0000\n' > "$WORK/d.env"
dupd dash-update-new-tag-ok ok "$IMG:sha-new1234@sha256:0123abcd"
dupd dash-update-old-tag-forced force "$IMG:sha-old0000"
dupd dash-update-no-force-errors error "$IMG:sha-old0000" --no-dashboard-force
printf 'DASH_ENABLED=false\nRADAR_IMAGE_TAG=sha-old0000\n' > "$WORK/d.env"
dupd dash-update-off-untouched untouched "$IMG:sha-old0000"
# Tag already current in the env file: the dashboard is still checked (repair path) and forced when it is behind.
printf 'DASH_ENABLED=true\nDASH_ORIGIN=https://dash.example.internal\nRADAR_IMAGE_TAG=sha-new1234\n' > "$WORK/d.env"
export STUB_LOG="$WORK/same-tag.log"; : > "$STUB_LOG"; rm -f "$STUB_LOG.dashimg"
rc=0; ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED PATH="$WORK/bin:$PATH" STUB_DASH_IMAGE="$IMG:sha-old0000" ./update.sh --env-file "$WORK/d.env" --tag sha-new1234 --yes ) >"$WORK/same-tag.out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -q "service update.*--image $IMG:sha-new1234.*_dashboard" "$STUB_LOG" && ! grep -q 'stack deploy' "$STUB_LOG"; then echo "ok   dash-same-tag-repaired"
else echo "FAIL dash-same-tag-repaired"; cat "$WORK/same-tag.out"; fail=1; fi
# Dry run mentions the dashboard check and calls no docker.
printf 'DASH_ENABLED=true\nRADAR_IMAGE_TAG=sha-old0000\n' > "$WORK/d.env"
rc=0; ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED PATH="$WORK/bin:$PATH" ./update.sh --env-file "$WORK/d.env" --tag sha-new1234 --dry-run ) >"$WORK/dry.out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -q 'wait for .*_dashboard' "$WORK/dry.out"; then echo "ok   dash-dry-run-text"; else echo "FAIL dash-dry-run-text"; cat "$WORK/dry.out"; fail=1; fi
# Config check with the new image: a refused configuration aborts BEFORE the env file changes and before any stack deploy;
# --skip-config-check does not call it.
printf 'DASH_ENABLED=false\nLAYERS=temperature_wms\nRADAR_IMAGE_TAG=sha-old0000\n' > "$WORK/c.env"; cp "$WORK/c.env" "$WORK/c.env.orig"
export STUB_LOG="$WORK/cc-fail.log"; : > "$STUB_LOG"
rc=0; ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED PATH="$WORK/bin:$PATH" STUB_CHECK_FAIL=yes ./update.sh --env-file "$WORK/c.env" --tag sha-new1234 --yes ) >"$WORK/cc-fail.out" 2>&1 || rc=$?
if [ "$rc" != 0 ] && cmp -s "$WORK/c.env" "$WORK/c.env.orig" && ! grep -q 'stack deploy\|service update' "$STUB_LOG" \
   && grep -q "check-config" "$STUB_LOG" && grep -q "unknown layer" "$WORK/cc-fail.out"; then echo "ok   config-check-aborts-before-change"
else echo "FAIL config-check-aborts-before-change (rc=$rc)"; cat "$WORK/cc-fail.out"; fail=1; fi
export STUB_LOG="$WORK/cc-skip.log"; : > "$STUB_LOG"
rc=0; ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED PATH="$WORK/bin:$PATH" STUB_CHECK_FAIL=yes DB_HOST=db ./update.sh --env-file "$WORK/c.env" --tag sha-new1234 --yes --skip-config-check ) >"$WORK/cc-skip.out" 2>&1 || rc=$?
if ! grep -q 'check-config' "$STUB_LOG" && grep -q 'stack deploy' "$STUB_LOG"; then echo "ok   config-check-skippable"
else echo "FAIL config-check-skippable (rc=$rc)"; cat "$WORK/cc-skip.out"; fail=1; fi
# Image older than check-config: it refuses the real values (APNS_KEY_FILE is a service secret) - must be skipped, not abort.
printf 'DASH_ENABLED=false\nPUSH_ENABLED=true\nAPNS_KEY_ID=ABC\nAPNS_TEAM_ID=T\nAPNS_TOPIC=t.x\nRADAR_IMAGE_TAG=sha-old0000\n' > "$WORK/o.env"
export STUB_LOG="$WORK/cc-old.log"; : > "$STUB_LOG"
rc=0; ( cd "$WORK/repo/deploy/swarm" && env -u DASH_ENABLED -u PUSH_ENABLED PATH="$WORK/bin:$PATH" STUB_CHECK_OLD=yes ./update.sh --env-file "$WORK/o.env" --tag sha-new1234 --yes ) >"$WORK/cc-old.out" 2>&1 || rc=$?
if grep -q 'has no check-config command' "$WORK/cc-old.out" && grep -q 'stack deploy' "$STUB_LOG" && ! grep -q 'needs APNS_KEY_FILE' "$WORK/cc-old.out"; then echo "ok   config-check-old-image-skipped"
else echo "FAIL config-check-old-image-skipped (rc=$rc)"; cat "$WORK/cc-old.out"; fail=1; fi
exit $fail
