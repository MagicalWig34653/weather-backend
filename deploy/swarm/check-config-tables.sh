#!/usr/bin/env bash
# Consistency of the settings tables (config-registry.tsv, config-extra.tsv) with stack.yaml, stack.push.yaml and .env.example:
#  - every ${VAR} of the stack files is in one of the tables (no variable without metadata for settings.sh),
#  - every ${VAR:-default} of the stack files has the same default as the table (LAYERS excepted, see below),
#  - every variable of .env.example (active or commented) is in a table (DEV_* are local development only),
#  - the tables are well formed (11 columns, known apply and type, no key twice), settings.sh knows its system keys.
# config-registry.tsv itself is checked against the Swift register by ConfigRegistryTSVTests (swift test).
# Usage: deploy/swarm/check-config-tables.sh   (bash 3.2+; not part of the deploy branch)
# shellcheck disable=SC2016,SC2013  # \${VAR} steht absichtlich in einfachen Anführungszeichen (Suchmuster)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
fail=0
err() { echo "FEHLER: $*" >&2; fail=1; }

rows="$(cat "$DIR/config-registry.tsv" "$DIR/config-extra.tsv" | grep -v '^#' | grep -v '^$')"
keys="$(printf '%s\n' "$rows" | cut -f1)"
dups="$(printf '%s\n' "$keys" | sort | uniq -d)"
[ -z "$dups" ] || err "Schluessel doppelt in den Tabellen: $dups"

# Form der Zeilen
while IFS= read -r line; do
  n="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  k="$(printf '%s' "$line" | cut -f1)"
  [ "$n" = 11 ] || err "$k: $n statt 11 Spalten"
  apply="$(printf '%s' "$line" | cut -f9)"; secret="$(printf '%s' "$line" | cut -f10)"; type="$(printf '%s' "$line" | cut -f3)"
  case "$apply" in live|restart|envOnly) ;; *) err "$k: apply '$apply'" ;; esac
  case "$secret" in 0|1) ;; *) err "$k: secret '$secret'" ;; esac
  case "${type%%:*}" in int|number|bool|choice|layers|text|url|secret) ;; *) err "$k: Typ '$type'" ;; esac
done <<< "$rows"

has_key() { [[ $'\n'"$keys"$'\n' == *$'\n'"$1"$'\n'* ]]; }
default_of() { awk -F'\t' -v k="$1" '$1 == k { print $4; exit }' <<< "$rows"; }

# ${VAR} der Stack-Dateien
for f in stack.yaml stack.push.yaml stack.dashboard.yaml; do
  for v in $(grep -o '\${[A-Z_][A-Z0-9_]*' "$DIR/$f" | tr -d '${' | sort -u); do
    has_key "$v" || err "$f: \${$v} fehlt in config-registry.tsv/config-extra.tsv"
  done
  # Defaults ${VAR:-x}
  while IFS= read -r m; do
    v="${m#\$\{}"; v="${v%%:-*}"; d="${m#*:-}"; d="${d%\}}"
    has_key "$v" || continue
    # An empty stack default (\${KEY:-}, the dashboard rule 'only explicitly set values') means 'not set': nothing to compare.
    [ -n "$d" ] || continue
    # LAYERS: the stack default is 'radar' (the radar always runs); the register default is empty (no additional layer).
    [ "$v" = LAYERS ] && continue
    # Placement variables: the stack default is an inert placeholder (always-true expression), the table default is empty (= not set).
    case "$v" in PLACEMENT_CONSTRAINT_[123]|PLACEMENT_SPREAD|PINNED_NODE|EXCLUDE_LABEL) continue ;; esac
    t="$(default_of "$v")"
    [ "$t" = "$d" ] || err "$f: Default von $v ist '$d', Tabelle sagt '$t'"
  done < <(grep -o '\${[A-Z_][A-Z0-9_]*:-[^}]*}' "$DIR/$f" | sort -u)
done

# Dashboard overlay: same variables as radar (the dashboard shows which values the operator set), hard security properties.
ov="$DIR/stack.dashboard.yaml"; ovc="$(grep -v '^ *#' "$ov")"  # ovc: ohne Kommentare
env_keys() { # file, yaml indent: KEY of the lines `KEY: ${KEY:-...}` that mirror the radar environment
  grep -oE '^ +([A-Z][A-Z0-9_]*): \$\{\1[:?]' "$1" | sed -E 's/^ +//; s/:.*//' | sort -u
}
radar_keys="$(env_keys "$DIR/stack.yaml")"; dash_keys="$(env_keys "$ov")"
# Radar-only: APNS key secret path is a literal, REPLICA_SLOT is a literal; dashboard-only: DASH_PORT/ORIGIN/RP_ID/SETUP/SESSION/IDLE, DASH_*_LIMIT
for v in $radar_keys; do
  [ "$v" = PUSH_ENABLED ] && continue  # im Dashboard fest 'false'
  [[ $'\n'"$dash_keys"$'\n' == *$'\n'"$v"$'\n'* ]] || err "stack.dashboard.yaml: $v aus stack.yaml fehlt (Umgebung des Dashboards muss die von radar spiegeln)"
done
grep -qE '^# dashboard-command: ready$' "$ov" || err "stack.dashboard.yaml: Marke '# dashboard-command: ready' fehlt"
# Published port (decision 2026-11-06): exactly one, ingress, target = DASH_PORT (same variable as the listener), never host mode.
[ "$(grep -cE '^ +ports:' <<< "$ovc")" = 1 ] || err "stack.dashboard.yaml: genau ein ports:-Block erwartet"
[ "$(grep -cE '^ +- target:' <<< "$ovc")" = 1 ] || err "stack.dashboard.yaml: genau ein veroeffentlichter Port erwartet"
grep -qE '^ +- target: \$\{DASH_PORT:-9090\}$' <<< "$ovc" || err "stack.dashboard.yaml: target muss \${DASH_PORT:-9090} sein (Listener-Port)"
grep -qE '^ +published: \$\{DASH_PUBLISH_PORT:-39090\}$' <<< "$ovc" || err "stack.dashboard.yaml: published muss \${DASH_PUBLISH_PORT:-39090} sein"
grep -qE '^ +mode: ingress$' <<< "$ovc" || err "stack.dashboard.yaml: mode: ingress fehlt"
! grep -qE '^ +mode: host$' <<< "$ovc" || err "stack.dashboard.yaml: mode: host verboten"
! grep -qi 'docker.sock' <<< "$ovc" || err "stack.dashboard.yaml: Docker-Socket verboten"
grep -qE '^    read_only: true$' "$ov" || err "stack.dashboard.yaml: read_only: true fehlt"
grep -qE "^      PUSH_ENABLED: 'false'$" "$ov" || err "stack.dashboard.yaml: PUSH_ENABLED muss fest 'false' sein"
! grep -qiE 'apns_key_file|apns_key[^_]|secrets:.*apns' <<< "$ovc" || err "stack.dashboard.yaml: APNs-Schluessel darf nicht eingebunden werden"
! grep -qE '^ +(cap_add|privileged|network_mode|pid):' <<< "$ovc" || err "stack.dashboard.yaml: keine zusaetzlichen Rechte"

# .env.example
for v in $(grep -oE '^#?[A-Z][A-Z0-9_]*=' "$ROOT/.env.example" | tr -d '#=' | sort -u); do
  case "$v" in DEV_*) continue ;; esac
  has_key "$v" || err ".env.example: $v fehlt in den Tabellen"
done

# settings.sh: Systemvariablen gibt es in den Tabellen
for v in $(sed -n 's/^SYSTEM_KEYS="\(.*\)"/\1/p' "$DIR/settings.sh"); do
  has_key "$v" || err "settings.sh: SYSTEM_KEYS enthaelt $v, aber die Tabellen kennen es nicht"
done

if [ "$fail" = 0 ]; then echo "ok   Tabellen konsistent ($(printf '%s\n' "$keys" | wc -l | tr -d ' ') Variablen)"; fi
exit "$fail"
