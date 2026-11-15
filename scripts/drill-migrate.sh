#!/usr/bin/env bash
# Drill (local Docker): move an n8n 2.40.7 instance from SQLite to Postgres with
# `n8n export:entities` / `n8n import:entities`, keeping the same N8N_ENCRYPTION_KEY.
# Everything runs on its own network/volumes with the `qm-` prefix and is removed at the end.
#
#   scripts/drill-migrate.sh > results/_drills/migrate.log 2>&1
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pgpass=$(openssl rand -hex 16)
img=n8nio/n8n:2.40.7; pg=${PG_IMAGE:-postgres:17.10-alpine}
key=$(openssl rand -hex 32)
# The n8n container writes the export as its own user (node, uid 1000), so this throwaway dir must be
# writable by it; it lives under a fresh mktemp dir and is not reused.
out=$(mktemp -d)/exports; mkdir -p "$out"; chmod 777 "$out"
net=qm-net
base=http://localhost:15679
jar=$(mktemp)
step() { echo; echo "### $*  ($(date -u +%T))"; }
wait_ready() { for i in $(seq 1 90); do curl -sf "$1/healthz/readiness" >/dev/null && return 0; sleep 2; done; echo "not ready: $1"; return 1; }
login() { curl -s -o /dev/null -c "$jar" -X POST "$base/rest/login" -H 'content-type: application/json' \
  -d '{"emailOrLdapLoginId":"bench@example.com","password":"Bench-pass-1234"}'; }
cleanup() { docker rm -f qm-sqlite qm-pg qm-n8n-pg >/dev/null 2>&1; docker volume rm qm-sqlite-data qm-pg-data qm-n8n-pg-data >/dev/null 2>&1; docker network rm $net >/dev/null 2>&1; }
cleanup; docker network create $net >/dev/null

step "1. n8n on SQLite (default DB_TYPE), owner + credential + 2 workflows + executions"
docker run -d --name qm-sqlite --network $net -p 15679:5678 -v qm-sqlite-data:/home/node/.n8n \
  -e N8N_ENCRYPTION_KEY="$key" -e N8N_SECURE_COOKIE=false -e N8N_DIAGNOSTICS_ENABLED=false $img >/dev/null
wait_ready $base
BASE_URL=$base WORKFLOW_DIR="$here/workflows" "$here/scripts/setup-http.sh" qslow >/dev/null && echo "owner + qslow created"
login
cred=$(curl -s -b "$jar" -X POST "$base/rest/credentials" -H 'content-type: application/json' \
  -d '{"name":"drill-basic","type":"httpBasicAuth","data":{"user":"alice","password":"s3cret-value"}}' | jq -r .data.id)
echo "credential id: $cred"
body=$(jq --arg c "$cred" 'del(.id) | .nodes |= map(if .credentials.httpBasicAuth then .credentials.httpBasicAuth.id = $c else . end) | .nodes |= map(if .name=="Call with credential" then .parameters.url="http://localhost:5678/healthz" else . end)' "$here/workflows/qcred.json")
wf=$(curl -s -b "$jar" -X POST "$base/rest/workflows" -H 'content-type: application/json' -d "$body")
wid=$(jq -r .data.id <<<"$wf"); ver=$(jq -r .data.versionId <<<"$wf")
curl -s -o /dev/null -b "$jar" -X POST "$base/rest/workflows/$wid/activate" -H 'content-type: application/json' -d "{\"versionId\":\"$ver\"}"
sleep 2
for i in 1 2 3; do curl -s -o /dev/null -X POST "$base/webhook/qcred" -H 'content-type: application/json' -d '{}'; done
echo "executions on SQLite: $(curl -s -b "$jar" "$base/rest/executions?limit=50" | jq '.data.count // (.data.results|length)')"
echo "workflows on SQLite: $(curl -s -b "$jar" "$base/rest/workflows" | jq '.data | length')"

step "2. stop n8n, export:entities (default: no execution history), then with --includeExecutionHistoryDataTables"
docker stop qm-sqlite >/dev/null
docker run --rm -v qm-sqlite-data:/home/node/.n8n -v "$out":/exports -e N8N_ENCRYPTION_KEY="$key" \
  --entrypoint n8n $img export:entities --outputDir=/exports/default 2>&1 | tail -8
docker run --rm -v qm-sqlite-data:/home/node/.n8n -v "$out":/exports -e N8N_ENCRYPTION_KEY="$key" \
  --entrypoint n8n $img export:entities --outputDir=/exports/with-history --includeExecutionHistoryDataTables=true 2>&1 | tail -3
echo "files (default):"; ls "$out/default" | head -40
echo "execution files (default): $(ls "$out/default" | grep -ci execution || true)  (with-history): $(ls "$out/with-history" | grep -ci execution || true)"
du -sh "$out/default" "$out/with-history"

step "3. Postgres, and the wrong DB_TYPE=postgres first"
docker run -d --name qm-pg --network $net -v qm-pg-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=n8n -e POSTGRES_PASSWORD="$pgpass" -e POSTGRES_DB=n8n $pg >/dev/null
for i in $(seq 1 30); do docker exec qm-pg pg_isready -U n8n -d n8n >/dev/null 2>&1 && break; sleep 1; done
pgenv=(-e DB_POSTGRESDB_HOST=qm-pg -e DB_POSTGRESDB_DATABASE=n8n -e DB_POSTGRESDB_USER=n8n -e DB_POSTGRESDB_PASSWORD="$pgpass" -e N8N_ENCRYPTION_KEY="$key")
echo "--- DB_TYPE=postgres (wrong value):"
timeout 60 docker run --rm --network $net -e DB_TYPE=postgres "${pgenv[@]}" $img 2>&1 | grep -v '^\s*$' | head -12

step "4. n8n on Postgres once (creates + migrates the schema), stop, import:entities --truncateTables"
docker run -d --name qm-n8n-pg --network $net -p 15679:5678 -v qm-n8n-pg-data:/home/node/.n8n -e DB_TYPE=postgresdb "${pgenv[@]}" \
  -e N8N_SECURE_COOKIE=false -e N8N_DIAGNOSTICS_ENABLED=false $img >/dev/null
wait_ready $base && echo "fresh Postgres-backed n8n migrated"
docker stop qm-n8n-pg >/dev/null
docker run --rm --network $net -v "$out":/exports -v qm-n8n-pg-data:/home/node/.n8n -e DB_TYPE=postgresdb "${pgenv[@]}" \
  --entrypoint n8n $img import:entities --inputDir=/exports/with-history --truncateTables 2>&1 | tail -12
docker start qm-n8n-pg >/dev/null; wait_ready $base

step "5. what moved"
login
echo "login with the SQLite owner: $(curl -s -b "$jar" "$base/rest/login" | jq -r '.data.email // .message')"
echo "workflows: $(curl -s -b "$jar" "$base/rest/workflows" | jq -c '[.data[] | {name, active: (.active // .activeVersionId != null)}]')"
echo "executions: $(curl -s -b "$jar" "$base/rest/executions?limit=50" | jq '.data.count // (.data.results|length)')"
echo "credential decrypts (run the workflow that uses it):"
sleep 3
curl -s -m 30 -w "  -> HTTP %{http_code}\n" -X POST "$base/webhook/qcred" -H 'content-type: application/json' -d '{}'
docker logs qm-n8n-pg 2>&1 | grep -iE "decrypt|credential|error" | tail -5
echo "--- which constraint, and the id sequences vs max(id):"
docker exec qm-pg psql -U n8n -d n8n -tAc "select conrelid::regclass from pg_constraint where conname='pk_e3e63bbf986767844bbe1166d4e'"
for t in execution_entity execution_data execution_metadata; do
  docker exec qm-pg psql -U n8n -d n8n -tAc "select '$t max(id)=' || coalesce((select max(id)::text from $t),'-') || ' seq=' || coalesce((select last_value::text from pg_sequences where sequencename like '${t}%' limit 1),'(no sequence)')" 2>&1
done
echo "--- fix: move the execution id sequence past the imported rows, then retry"
fix="SELECT setval(pg_get_serial_sequence('execution_entity', 'id'), (SELECT max(id) FROM execution_entity));"
echo "$fix"
docker exec qm-pg psql -U n8n -d n8n -tAc "$fix"
curl -s -m 30 -w "  -> HTTP %{http_code}\n" -X POST "$base/webhook/qcred" -H 'content-type: application/json' -d '{}'
login; echo "last execution: $(curl -s -b "$jar" "$base/rest/executions?limit=1" | jq -c '.data.results[0] | {id, status, workflowName}')"

step "6. same import with a DIFFERENT encryption key"
docker stop qm-n8n-pg >/dev/null
docker run --rm --network $net -v "$out":/exports -v qm-n8n-pg-data:/home/node/.n8n -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=qm-pg -e DB_POSTGRESDB_DATABASE=n8n -e DB_POSTGRESDB_USER=n8n -e DB_POSTGRESDB_PASSWORD="$pgpass" \
  -e N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" --entrypoint n8n $img import:entities --inputDir=/exports/default --truncateTables 2>&1 | grep -vE '^\s+at ' | tail -8

cleanup; echo; echo "cleanup done"
