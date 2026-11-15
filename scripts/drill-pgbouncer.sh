#!/usr/bin/env bash
# Drill (local Docker): n8n 2.40.7 queue mode (main + 2 workers) on Postgres 17 through
# PgBouncer in TRANSACTION pooling. Every n8n process talks only to PgBouncer, including the
# first-boot migrations. Compose project `qp`, host port 15681. Removed at the end.
#
#   scripts/drill-pgbouncer.sh > results/_drills/pgbouncer.log 2>&1
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
P=qp; port=15681; base=http://localhost:$port
PG_IMAGE=${PG_IMAGE:-postgres:17.10-alpine}; PGB_IMAGE=${PGB_IMAGE:-edoburu/pgbouncer:v1.24.1-p1}
work=$(mktemp -d); sec="$work/secrets.env"; f="$work/compose.yml"; jar="$work/jar"
{ echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)"; echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
  echo "REDIS_PASSWORD=$(openssl rand -hex 16)"; echo "RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)"; } >"$sec"
step() { echo; echo "######## $*  ($(date -u +%T))"; }
dc() { docker compose -p $P -f "$f" "$@"; }
down() { dc down -v --remove-orphans >/dev/null 2>&1; }
login() { curl -s -o /dev/null -c "$jar" -X POST "$base/rest/login" -H 'content-type: application/json' \
  -d '{"emailOrLdapLoginId":"bench@example.com","password":"Bench-pass-1234"}'; }
counts() { login; curl -s -b "$jar" "$base/rest/executions?limit=100" | jq -r --arg w "$1" \
  '[.data.results[] | select(.workflowName|startswith($w)) | .status] | group_by(.) | map("\(.[0])=\(length)") | join(" ")'; }

env SECRETS="$sec" PUBLIC_URL="$base/" HOST_PORT=$port PROBES=0 METRICS=1 MODE=queue WORKERS=2 \
  ruby "$here/scripts/render.rb" >"$work/base.yml"
# Postgres 17, a PgBouncer in front of it, and every n8n process pointed at PgBouncer.
ruby -ryaml -e '
  c = YAML.load_file(ARGV[0], aliases: true); pw = File.read(ARGV[1])[/^POSTGRES_PASSWORD=(.*)$/, 1]
  c["services"]["n8n-postgres"]["image"] = ARGV[2]
  c["services"]["n8n-postgres"]["environment"]["POSTGRES_HOST_AUTH_METHOD"] = "scram-sha-256"
  c["services"]["n8n-pgbouncer"] = {
    "image" => ARGV[3], "restart" => "unless-stopped",
    "environment" => { "DB_HOST" => "n8n-postgres", "DB_USER" => "n8n", "DB_PASSWORD" => pw, "DB_NAME" => "n8n",
                       "AUTH_TYPE" => "scram-sha-256", "POOL_MODE" => "transaction",
                       "MAX_CLIENT_CONN" => "200", "DEFAULT_POOL_SIZE" => "20", "MAX_PREPARED_STATEMENTS" => "0" },
    "depends_on" => { "n8n-postgres" => { "condition" => "service_healthy" } },
    "healthcheck" => { "test" => [ "CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432" ], "interval" => "5s", "retries" => 10 } }
  c["services"].each do |name, s|
    next unless s["image"].to_s.start_with?("n8nio/n8n:")
    s["environment"]["DB_POSTGRESDB_HOST"] = "n8n-pgbouncer"
    (s["depends_on"] ||= {})["n8n-pgbouncer"] = { "condition" => "service_healthy" } if s["depends_on"].is_a?(Hash)
  end
  File.write(ARGV[4], c.to_yaml)
' "$work/base.yml" "$sec" "$PG_IMAGE" "$PGB_IMAGE" "$f"

trap down EXIT
down
step "1. start: migrations on first boot go through PgBouncer (transaction mode)"
dc up -d --wait --wait-timeout 300 >/dev/null 2>&1; dc ps --format '{{.Service}} {{.Status}}'
dc exec -T n8n-postgres postgres --version
dc exec -T n8n-pgbouncer pgbouncer --version 2>&1 | head -1
dc exec -T n8n-postgres psql -U n8n -d n8n -tAc "select count(*) || ' migrations applied' from migrations"
echo "--- n8n hosts point at: $(dc exec -T n8n-worker-1 printenv DB_POSTGRESDB_HOST)"

step "2. owner + q1 + qslow, then 200 q1 webhooks, 20 at a time"
BASE_URL=$base WORKFLOW_DIR="$here/workflows" "$here/scripts/setup-http.sh" q1 qslow >/dev/null && echo "setup done"
sleep 2
seq 1 200 | xargs -P 20 -I{} curl -s -o /dev/null -w "%{http_code}\n" -m 60 -X POST "$base/webhook/q1" \
  -H 'content-type: application/json' -d '{}' | sort | uniq -c
echo "q1 executions: $(counts Q1)"

step "3. 10 qslow in flight, restart worker-1 mid-run (SIGTERM), wait for them to finish"
for i in $(seq 1 10); do curl -s -o /dev/null -m 10 -X POST "$base/webhook/qslow" -H 'content-type: application/json' -d '{}'; done
sleep 5; dc restart n8n-worker-1 >/dev/null 2>&1; echo "worker-1 restarted"; sleep 60
echo "qslow executions: $(counts QSLOW)"

step "4. Postgres-side view and errors"
dc exec -T n8n-postgres psql -U n8n -d n8n -tAc "select 'server connections from pgbouncer: ' || count(*) from pg_stat_activity where datname='n8n' and backend_type='client backend'"
for s in n8n-main n8n-worker-1 n8n-worker-2; do
  echo "--- $s errors:"; dc logs --no-color --no-log-prefix $s 2>&1 | grep -iE 'error|prepared statement|advisory|unsupported|Database is not ready' | sort | uniq -c | sort -rn | head -6
done
echo "--- pgbouncer warnings/errors:"; dc logs --no-color --no-log-prefix n8n-pgbouncer 2>&1 | grep -iE 'warning|error' | sed -E 's/^[^ ]+ [^ ]+ //' | sort | uniq -c | sort -rn | head -8
echo; echo "cleanup on exit"
