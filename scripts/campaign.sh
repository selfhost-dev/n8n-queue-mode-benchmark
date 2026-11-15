#!/usr/bin/env bash
# Runs the benchmark matrix: for each variant, deploy -> measure each rate -> delete.
# One variant at a time on the same server, so runs never overlap.
#
#   DEPLOY=./my-deploy.sh HOST=1.2.3.4 N8N_SSH=user@1.2.3.4 SECRETS=secrets.env SSH_KEY=key \
#     scripts/campaign.sh [variant...]
#
# DEPLOY is your own script: `DEPLOY up <name>` renders the variant with scripts/render.rb (the render
# env vars and HOST_PORT are set), deploys it to HOST, waits until n8n is ready and runs
# scripts/setup-http.sh $WORKFLOWS; `DEPLOY down <name>` removes it. Restrict the published port to
# the load generator's address while it runs.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
: "${DEPLOY:?}" "${HOST:?}" "${N8N_SSH:?}" "${SECRETS:?}" "${SSH_KEY:?}"
export HOST SECRETS SSH_KEY N8N_SSH
dur=${DURATION:-3m}

# name | port | render env | rates
variants=(
  "r0|5701|MODE=regular|5 20 50"
  "r1|5702|MODE=regular PROD_LIMIT=10|5 20 50"
  "q1|5703|MODE=queue WORKERS=1|5 20 50"
  "q2|5704|MODE=queue WORKERS=2|5 20 50"
  "q4|5705|MODE=queue WORKERS=4|5 20 50"
  "q2c5|5706|MODE=queue WORKERS=2 CONCURRENCY=5 RUNNER_MAX=5|20 50"
  "q2c10|5707|MODE=queue WORKERS=2 CONCURRENCY=10 RUNNER_MAX=10|20 50"
  "q2c20|5708|MODE=queue WORKERS=2 CONCURRENCY=20 RUNNER_MAX=20|20 50"
  "q4p10|5709|MODE=queue WORKERS=4 POOL_SIZE=10|20 50"
)
want=" $* "

for v in "${variants[@]}"; do
  IFS='|' read -r name port renv rates <<<"$v"
  rates=${RATES:-$rates}
  [[ $# -gt 0 && $want != *" $name "* ]] && continue
  echo "=== $name ($renv) on :$port  $(date -u +%T)"
  start=$(date +%s)
  if ! env $renv HOST_PORT="$port" WORKFLOWS="q1" "$DEPLOY" up "$name"; then
    echo "!!! $name failed to deploy"; "$DEPLOY" down "$name"; continue
  fi
  base="http://$HOST:$port"
  # warm up: start the task runners and JIT before measuring
  for i in $(seq 1 10); do curl -s -o /dev/null -m 60 -X POST "$base/webhook/q1" -H 'content-type: application/json' -d '{}'; done
  for rate in $rates; do
    BASE_URL=$base SCENARIO_START=$start \
      "$here/scripts/run.sh" "${LABEL_PREFIX:-}$name-r$rate" -e MODE=rate -e RATE="$rate" -e DURATION="$dur" -e MAX_VUS=1000
    sleep 20
  done
  "$DEPLOY" down "$name"
  sleep 30
done
echo "=== campaign done $(date -u +%T)"
