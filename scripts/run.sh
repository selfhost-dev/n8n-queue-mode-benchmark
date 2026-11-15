#!/usr/bin/env bash
# One measured run against a deployed variant: cgroup sampler over SSH + k6 load from
# this machine + an "editor" probe (time to load a workflow over the editor's REST API
# while the load runs) + the variant's pg/redis probe lines and n8n /metrics.
#
#   N8N_SSH=user@1.2.3.4 SSH_KEY=key BASE_URL=http://1.2.3.4:5701 [LOGS_CMD='...'] \
#     scripts/run.sh <label> [k6 -e args...]          # e.g. scripts/run.sh q2-r20 -e RATE=20 -e DURATION=3m
#
# Env: WF (default q1), IDLE_BEFORE / IDLE_AFTER (default 20/20), SCENARIO_START (unix ts the
#      variant was created; containers created earlier are not ours), EDITOR_EVERY (default 5 s),
#      LOGS_CMD (optional: a command that prints the variant's container logs).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
label=${1:?label}; shift
[[ $label =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "bad label: $label" >&2; exit 1; }
out="$here/results/$label"; rm -rf "$out"; mkdir -p "$out"
base=${BASE_URL:?}; wf=${WF:-q1}
remote=${N8N_SSH:?}
ssh_opts=(-o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)
[[ -n ${SSH_KEY:-} ]] && ssh_opts+=(-i "$SSH_KEY" -o UserKnownHostsFile="$SSH_KEY.known_hosts")
rsh() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

scp -q "${ssh_opts[@]}" "$here/scripts/stats-cgroup.sh" "$remote:/tmp/stats-cgroup.sh"
rsh "rm -f /tmp/q-$label.csv; nohup sh /tmp/stats-cgroup.sh /tmp/q-$label.csv 1 >/dev/null 2>&1 & echo \$! > /tmp/q-$label.pid"
editor_pid=""
cleanup() {
  [[ -n $editor_pid ]] && kill "$editor_pid" 2>/dev/null || true
  rsh "kill \$(cat /tmp/q-$label.pid) 2>/dev/null; true" || true
  scp -q "${ssh_opts[@]}" "$remote:/tmp/q-$label.csv" "$out/stats.csv" || true
}
trap cleanup EXIT

{ echo "label=$label"; echo "workflow=$wf"; echo "base_url=$base"; echo "scenario_start=${SCENARIO_START:-0}"
  echo "started_utc=$(date -u +%FT%TZ)"; echo "k6_args=$*"; } >"$out/meta.txt"

# editor probe: log in, find the workflow, time GET /rest/workflows/:id every EDITOR_EVERY s
jar=$(mktemp)
curl -s -o /dev/null -c "$jar" -X POST "$base/rest/login" -H 'content-type: application/json' \
  -d '{"emailOrLdapLoginId":"bench@example.com","password":"Bench-pass-1234"}'
wid=$(curl -s -b "$jar" "$base/rest/workflows" | jq -r --arg p "$wf" '.data[] | select(.nodes == null or true) | select(.name | ascii_downcase | startswith($p)) | .id' | head -1)
(
  while :; do
    t=$(curl -s -o /dev/null -m 60 -b "$jar" -w '%{http_code} %{time_total}' "$base/rest/workflows/$wid")
    echo "$(date +%s) $t"
    sleep "${EDITOR_EVERY:-5}"
  done
) >"$out/editor.txt" 2>/dev/null &
editor_pid=$!

sleep "${IDLE_BEFORE:-20}"
echo "load_start=$(date +%s)" >>"$out/meta.txt"
k6 run --quiet -e BASE_URL="$base" -e WF="$wf" "$@" \
  --summary-export "$out/k6-summary.json" "$here/scripts/load.js" >"$out/k6.txt" 2>&1 || true
echo "load_end=$(date +%s)" >>"$out/meta.txt"
sleep "${IDLE_AFTER:-20}"
kill "$editor_pid" 2>/dev/null || true; editor_pid=""
cleanup; trap - EXIT
curl -s -m 20 "$base/metrics" >"$out/metrics.txt" || true

# pg / redis probe lines: container logs, if you give a command that prints them
if [[ -n ${LOGS_CMD:-} ]]; then
  bash -c "$LOGS_CMD" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' >"$out/container-logs.txt" || true
fi
echo "ended_utc=$(date -u +%FT%TZ)" >>"$out/meta.txt"
ruby "$here/scripts/analyze.rb" "$out" | tee "$out/summary.txt"
