#!/usr/bin/env bash
# Failure drills for n8n queue mode, run LOCALLY with Docker on the same rendered compose file
# as the benchmark (scripts/render.rb). Compose project `qd`, host port 15680. Removed at the end.
#
#   scripts/drills.sh [drill...] > results/_drills/drills.log 2>&1
#   drills: start-order kill-worker graceful bad-key redis-aof redis-noaof postgres binary-fs eviction
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
P=qd; port=15680; base=http://localhost:$port
work=$(mktemp -d); sec="$work/secrets.env"
{ echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)"; echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
  echo "REDIS_PASSWORD=$(openssl rand -hex 16)"; echo "RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)"; } >"$sec"
REDIS_PASSWORD=$(grep ^REDIS_PASSWORD "$sec" | cut -d= -f2)
jar="$work/jar"; f="$work/compose.yml"
all="start-order kill-worker graceful bad-key redis-aof redis-noaof postgres binary-fs eviction"
want=" ${*:-$all} "

step() { echo; echo "######## $*  ($(date -u +%T))"; }
dc() { docker compose -p $P -f "$f" "$@"; }
render() { env "$@" SECRETS="$sec" PUBLIC_URL="$base/" HOST_PORT=$port PROBES=0 METRICS=1 ruby "$here/scripts/render.rb" >"$f"; }
up() { render "$@"; dc up -d --wait --wait-timeout 300 >/dev/null 2>&1 || dc ps; }
down() { dc down -v --remove-orphans >/dev/null 2>&1; }
wait_ready() { for i in $(seq 1 120); do curl -sf "$base/healthz/readiness" >/dev/null && return 0; sleep 1; done; echo "main not ready"; }
# n8n 2.47 rate-limits POST /rest/login (429 after 5 tries), so log in once per stack and reuse the cookie.
login() { grep -q n8n-auth "$jar" 2>/dev/null && return 0; curl -s -o /dev/null -c "$jar" -X POST "$base/rest/login" -H 'content-type: application/json' \
  -d '{"emailOrLdapLoginId":"bench@example.com","password":"Bench-pass-1234"}'; }
setup() {
  wait_ready
  BASE_URL=$base WORKFLOW_DIR="$here/workflows" "$here/scripts/setup-http.sh" "$@" >/dev/null && echo "setup: $*"
  : >"$jar"; login
}
add_cred_flow() { # creates the basic-auth credential and the qcred workflow that uses it
  local cred body wf wid ver
  cred=$(curl -s -b "$jar" -X POST "$base/rest/credentials" -H 'content-type: application/json' \
    -d '{"name":"drill-basic","type":"httpBasicAuth","data":{"user":"alice","password":"s3cret-value"}}' | jq -r .data.id)
  body=$(jq --arg c "$cred" 'del(.id) | .nodes |= map(if .credentials.httpBasicAuth then .credentials.httpBasicAuth.id = $c else . end)' "$here/workflows/qcred.json")
  wf=$(curl -s -b "$jar" -X POST "$base/rest/workflows" -H 'content-type: application/json' -d "$body")
  wid=$(jq -r .data.id <<<"$wf"); ver=$(jq -r .data.versionId <<<"$wf")
  curl -s -o /dev/null -b "$jar" -X POST "$base/rest/workflows/$wid/activate" -H 'content-type: application/json' -d "{\"versionId\":\"$ver\"}"
  echo "credential $cred + qcred published"; sleep 2
}
fire() { local n=$1 wf=$2; for i in $(seq 1 "$n"); do curl -s -o /dev/null -w "%{http_code} " -m 30 -X POST "$base/webhook/$wf" -H 'content-type: application/json' -d '{}'; done; echo; }
execs() { login; curl -s -b "$jar" "$base/rest/executions?limit=${1:-50}" | jq -r '.data.results[] | "\(.id) \(.workflowName) \(.status) started=\(.startedAt // "-") stopped=\(.stoppedAt // "-")"'; }
status_count() { login; curl -s -b "$jar" "$base/rest/executions?limit=100" | jq -r --arg w "$1" '[.data.results[] | select(.workflowName|startswith($w)) | .status] | group_by(.) | map("\(.[0])=\(length)") | join(" ")'; }
logs() { dc logs --no-color --no-log-prefix "$1" 2>&1 | grep -vE '^\s*$' | tail -"${2:-15}"; }
redis_cli() { dc exec -T n8n-redis redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@"; }

trap down EXIT
down

if [[ $want == *" start-order "* ]]; then
  step "start-order: worker started before main ever ran (fresh DB: no migrations yet)"
  render MODE=queue WORKERS=1
  dc up -d --wait n8n-postgres n8n-redis >/dev/null 2>&1
  dc up -d --no-deps n8n-worker-1 >/dev/null 2>&1; sleep 25
  echo "--- worker-1 log:"; logs n8n-worker-1 20
  echo "--- worker-1 state: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' ${P}-n8n-worker-1-1)"
  down
fi

if [[ $want == *" kill-worker "* || $want == *" graceful "* ]]; then
  up MODE=queue WORKERS=2; setup q20 q50
fi

if [[ $want == *" kill-worker "* ]]; then
  step "kill-worker: SIGKILL worker-1 while it runs Wait-50s executions"
  dc stop n8n-worker-2 >/dev/null 2>&1   # everything lands on worker-1
  fire 4 q50; sleep 8
  echo "--- before kill:"; status_count Q50
  docker kill ${P}-n8n-worker-1-1 >/dev/null; echo "killed at $(date -u +%T)"
  sleep 5; echo "--- worker-1 state after kill: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' ${P}-n8n-worker-1-1)"
  echo "--- 10 s after kill:"; status_count Q50
  dc start n8n-worker-2 >/dev/null 2>&1
  sleep 90; echo "--- 95 s after kill (worker-2 running, worker-1 as restart policy left it):"; status_count Q50
  echo "--- worker-1 state: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' ${P}-n8n-worker-1-1)"
  execs 10 | grep Q50
  echo "--- main log (stalled/crashed/recovered lines):"; dc logs --no-color --no-log-prefix n8n-main 2>&1 | grep -iE "stall|crash|recover|lost|worker|job" | tail -15
  echo "--- worker-2 log:"; logs n8n-worker-2 12
  dc start n8n-worker-1 >/dev/null 2>&1
fi

if [[ $want == *" graceful "* ]]; then
  step "graceful: docker stop (SIGTERM, compose stop_grace_period 60s, N8N_GRACEFUL_SHUTDOWN_TIMEOUT default 30s) while worker-1 runs a 20 s and a 50 s wait"
  dc up -d --wait >/dev/null 2>&1; dc stop n8n-worker-2 >/dev/null 2>&1
  fire 2 q20; fire 2 q50; sleep 5
  echo "--- before stop:"; status_count Q20; status_count Q50
  t0=$(date +%s); dc stop -t 60 n8n-worker-1 >/dev/null 2>&1; echo "worker-1 stop took $(( $(date +%s) - t0 )) s"
  echo "--- right after stop:"; echo "Q20: $(status_count Q20)"; echo "Q50: $(status_count Q50)"
  echo "--- worker-1 log tail:"; logs n8n-worker-1 15
  dc start n8n-worker-2 >/dev/null 2>&1; sleep 75
  echo "--- 75 s later (worker-2 up):"; echo "Q20: $(status_count Q20)"; echo "Q50: $(status_count Q50)"
fi
[[ $want == *" kill-worker "* || $want == *" graceful "* ]] && down

if [[ $want == *" bad-key "* ]]; then
  step "bad-key: worker-2 has a different N8N_ENCRYPTION_KEY"
  up MODE=queue WORKERS=2 BAD_KEY_WORKER=1; setup q20; add_cred_flow
  for i in $(seq 1 8); do curl -s -m 30 -w " HTTP %{http_code}\n" -X POST "$base/webhook/qcred" -H 'content-type: application/json' -d '{}'; done
  echo "--- statuses: $(status_count QCRED)"
  echo "--- worker-2 (wrong key) log:"; dc logs --no-color --no-log-prefix n8n-worker-2 2>&1 | grep -iE "decrypt|credential|key|error" | sort | uniq -c | head -8
  login; bad=$(curl -s -b "$jar" "$base/rest/executions?limit=20" | jq -r '[.data.results[] | select(.status=="error")][0].id')
  [[ $bad != null ]] && curl -s -b "$jar" "$base/rest/executions/$bad" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)["data"]["data"]; a=json.loads(d) if isinstance(d,str) else d
def w(v):
  if isinstance(v,dict): return {k:r(x) for k,x in v.items()}
  if isinstance(v,list): return [r(x) for x in v]
  return v
def r(x):
  if isinstance(x,str):
    t=a[int(x)]; return t if isinstance(t,str) else w(t)
  return w(x)
e=w(a[0])["resultData"].get("error",{}); print("execution error:", e.get("message"), "|", e.get("description"))'
  down
fi

redis_drill() { # $1 = yes|no (AOF)
  step "redis-$( [[ $1 == yes ]] && echo aof || echo noaof ): kill Redis (SIGKILL) with jobs waiting, AOF=$1"
  up MODE=queue WORKERS=1 AOF=$1; setup q20
  dc stop n8n-worker-1 >/dev/null 2>&1      # no consumer: jobs stay waiting
  fire 20 q20; sleep 3
  echo "--- waiting in Redis before kill: $(redis_cli llen bull:jobs:wait)"
  docker kill ${P}-n8n-redis-1 >/dev/null; echo "redis killed at $(date -u +%T)"
  echo "--- webhooks while Redis is down:"; fire 3 q20
  for i in 5 10 15 20; do sleep 5; echo "  +${i}s main: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' ${P}-n8n-main-1)"; done
  echo "--- main log:"; dc logs --no-color --no-log-prefix n8n-main 2>&1 | grep -iE "redis|lost|reconnect|queue|exit|shut" | sort | uniq -c | sort -rn | head -8
  t0=$(date +%s); dc start n8n-redis >/dev/null 2>&1
  for i in $(seq 1 60); do redis_cli ping 2>/dev/null | grep -q PONG && break; sleep 1; done
  echo "--- redis back after $(( $(date +%s) - t0 )) s; waiting jobs after restart: $(redis_cli llen bull:jobs:wait)"
  for i in $(seq 1 120); do curl -sf "$base/healthz/readiness" >/dev/null && break; sleep 1; done
  echo "--- main ready again $(( $(date +%s) - t0 )) s after Redis started; main: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' ${P}-n8n-main-1)"
  echo "--- webhooks after Redis is back:"; fire 3 q20
  echo "--- statuses before the worker returns: $(status_count Q20)"
  dc start n8n-worker-1 >/dev/null 2>&1; sleep 60
  echo "--- Q20 executions 60 s after the worker came back: $(status_count Q20)"
  down
}
[[ $want == *" redis-aof "* ]] && redis_drill yes
[[ $want == *" redis-noaof "* ]] && redis_drill no

if [[ $want == *" postgres "* ]]; then
  step "postgres: restart Postgres during load (k6, 4 req/s of q20-onReceived + q1, 90 s)"
  up MODE=queue WORKERS=2; setup q1 q20
  ( k6 run --quiet -e BASE_URL=$base -e WF=q1 -e MODE=rate -e RATE=4 -e DURATION=90s -e TIMEOUT=60s \
      --summary-export "$work/pg-k6.json" "$here/scripts/load.js" >"$work/pg-k6.txt" 2>&1 ) &
  k=$!; sleep 30
  t0=$(date +%s); dc restart n8n-postgres >/dev/null 2>&1; echo "postgres restarted (took $(( $(date +%s) - t0 )) s) at $(date -u +%T)"
  for i in $(seq 1 120); do curl -sf "$base/healthz/readiness" >/dev/null && break; sleep 1; done
  echo "main readiness back $(( $(date +%s) - t0 )) s after the restart began"
  wait $k
  echo "--- k6: $(jq -c '{reqs: .metrics.http_reqs.count, ok: .metrics.checks.passes, failed: .metrics.checks.fails, p95: .metrics.http_req_duration["p(95)"]}' "$work/pg-k6.json")"
  grep -o 'non-200: status=[0-9]* error=[^"]*body=.\{0,80\}' "$work/pg-k6.txt" | sed 's/\\"/"/g' | sort | uniq -c | sort -rn | head -5
  for s in n8n-main n8n-worker-1; do echo "--- $s:"; dc logs --no-color --no-log-prefix $s 2>&1 | grep -iE "database|connection|postgres|ECONN|terminat|ready" | sort | uniq -c | sort -rn | head -6; done
  sleep 10; echo "--- workers still serving after: $(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST $base/webhook/q1 -H 'content-type: application/json' -d '{}')"
  down
fi

if [[ $want == *" binary-fs "* ]]; then
  step "binary-fs: N8N_DEFAULT_BINARY_DATA_MODE=filesystem in queue mode, upload a 300 kB file"
  up MODE=queue WORKERS=1 BINARY_MODE=filesystem; wait_ready
  BASE_URL=$base WORKFLOW_DIR="$here/workflows" "$here/scripts/setup-http.sh" qbin qbin2 2>&1 | tail -5
  echo "--- main state: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' ${P}-n8n-main-1)"; logs n8n-main 12
  login; wid=$(curl -s -b "$jar" "$base/rest/workflows" | jq -r '.data[0].id'); wf=$(curl -s -b "$jar" "$base/rest/workflows/$wid")
  echo "--- activate response:"; curl -s -b "$jar" -X POST "$base/rest/workflows/$wid/activate" -H 'content-type: application/json' -d "{\"versionId\":\"$(jq -r .data.versionId <<<"$wf")\"}" | head -c 600; echo
  head -c 300000 /dev/urandom >"$work/bin.dat"
  sleep 2; curl -s -m 60 -w " HTTP %{http_code}\n" -X POST "$base/webhook/qbin" -F "data=@$work/bin.dat"
  echo "--- read the bytes on the worker (Code node, getBinaryDataBuffer):"
  curl -s -m 60 -w " HTTP %{http_code}\n" -X POST "$base/webhook/qbin2" -F "data=@$work/bin.dat"
  login; eid=$(curl -s -b "$jar" "$base/rest/executions?limit=1" | jq -r '.data.results[0].id')
  echo "--- execution $eid:"; curl -s -b "$jar" "$base/rest/executions/$eid" | python3 -I "$here/scripts/exec-error.py"
  down
  step "binary (unset, for comparison)"
  up MODE=queue WORKERS=1; setup qbin qbin2
  curl -s -m 60 -w " HTTP %{http_code}\n" -X POST "$base/webhook/qbin" -F "data=@$work/bin.dat"
  curl -s -m 60 -w " HTTP %{http_code}\n" -X POST "$base/webhook/qbin2" -F "data=@$work/bin.dat"
  down
fi

if [[ $want == *" eviction "* ]]; then
  step "eviction: Redis maxmemory-policy allkeys-lru instead of noeviction"
  up MODE=queue WORKERS=1 REDIS_POLICY=allkeys-lru; setup q20
  echo "--- policy: $(redis_cli config get maxmemory-policy | tr '\n' ' ')"
  for s in n8n-main n8n-worker-1 n8n-redis; do echo "--- $s:"; dc logs --no-color --no-log-prefix $s 2>&1 | grep -iE "evict|policy|noeviction|warn" | sort | uniq -c | head -6; done
  fire 3 q20
  down
fi
echo; echo "drills done $(date -u +%T)"
