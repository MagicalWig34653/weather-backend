#!/usr/bin/env bash
# Offline test of swarm-deploy.sh with a stub `docker` (no Swarm needed): checks that the overlay stack.push.yaml is part of
# `docker stack deploy` exactly when push is enabled (shell variable or env file), and that a missing secret aborts the rollout.
# Usage: deploy/swarm/test-swarm-deploy.sh   (needs bash only; not part of the deploy branch)
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/deploy/swarm" "$WORK/bin"
cp "$SRC"/swarm-deploy.sh "$SRC"/lib.sh "$SRC"/stack.yaml "$SRC"/stack.push.yaml "$WORK/repo/deploy/swarm/"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
case "$1 $2" in
  "secret inspect") [ "${STUB_SECRET:-yes}" = yes ] || exit 1 ;;
  "service inspect") exit 1 ;;
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
  ( cd "$WORK/repo/deploy/swarm" && env -u PUSH_ENABLED -u APNS_KEY_SECRET -u ENV_FILE PATH="$WORK/bin:$PATH" DB_HOST=db "$@" ./swarm-deploy.sh ) >"$WORK/$name.out" 2>&1 || rc=$?
  local deploys overlay
  deploys=$(grep -c 'stack deploy' "$STUB_LOG" || true); overlay=$(grep 'stack deploy' "$STUB_LOG" | grep -c 'stack.push.yaml' || true)
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
exit $fail
