#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders the n8n queue-mode stack as a docker-compose file.
#
#   ruby scripts/render.rb > compose/docker-compose.yml          # the published file (placeholders)
#   SECRETS=secrets.env PUBLIC_URL=http://1.2.3.4:5701/ HOST_PORT=5701 \
#     MODE=queue WORKERS=4 ruby scripts/render.rb > /tmp/q4.yml   # a concrete benchmark variant
#
# Knobs (env):
#   MODE           queue (default) | regular
#   WORKERS        number of workers in queue mode (default 2)
#   CONCURRENCY    `n8n worker --concurrency` (default 10, n8n's own default)
#   RUNNER_MAX     N8N_RUNNERS_MAX_CONCURRENCY per runner (default 5, the template's value)
#   PROD_LIMIT     N8N_CONCURRENCY_PRODUCTION_LIMIT (regular mode; unset = n8n default)
#   POOL_SIZE      DB_POSTGRESDB_POOL_SIZE on every n8n process (unset = n8n default, 2)
#   HOST_PORT      host port for the editor/webhooks (default 5678)
#   AOF            yes (default) | no   Redis persistence
#   METRICS        1 = N8N_METRICS + queue metrics on main
#   PROBES         1 = add pg-probe / redis-probe sidecars that print stats every 5 s (benchmark only)
#   BAD_KEY_WORKER 1 = give the LAST worker a different N8N_ENCRYPTION_KEY (failure drill)
#   REDIS_POLICY   Redis maxmemory-policy (default noeviction; drills try allkeys-lru)
#   BINARY_MODE    N8N_DEFAULT_BINARY_DATA_MODE (drills only; unset in the published file)
#   DB_TYPE_OVERRIDE  replaces DB_TYPE (drills only, e.g. `postgres`)
#   SECRETS        file of KEY=value lines (N8N_ENCRYPTION_KEY, POSTGRES_PASSWORD, REDIS_PASSWORD,
#                  RUNNERS_AUTH_TOKEN); without it the output keeps ${VAR} placeholders
#   PUBLIC_URL     value for N8N_EDITOR_BASE_URL / N8N_WEBHOOK_URL (default ${N8N_PUBLIC_URL})
require "yaml"

N8N_VERSION = ENV.fetch("N8N_VERSION", "2.47.7")
POSTGRES_IMAGE = "postgres:17.10-alpine"
REDIS_IMAGE = "redis:7.4.6-alpine"

env = ENV.to_h
mode = env.fetch("MODE", "queue")
abort "MODE must be queue or regular" unless %w[queue regular].include?(mode)
queue = mode == "queue"
workers = Integer(env.fetch("WORKERS", "2"))
concurrency = Integer(env.fetch("CONCURRENCY", "10"))
runner_max = env.fetch("RUNNER_MAX", "5")
host_port = env.fetch("HOST_PORT", "5678")
aof = env.fetch("AOF", "yes") == "yes"

secrets = {}
if env["SECRETS"]
  File.readlines(env["SECRETS"], chomp: true).each do |line|
    k, v = line.split("=", 2)
    secrets[k] = v if k && v
  end
end
sec = ->(name) { secrets.fetch(name, "${#{name}}") }
public_url = env.fetch("PUBLIC_URL", "${N8N_PUBLIC_URL}")

n8n_env = {}
if queue
  n8n_env.merge!(
    "EXECUTIONS_MODE" => "queue",
    "QUEUE_BULL_REDIS_HOST" => "n8n-redis",
    "QUEUE_BULL_REDIS_PORT" => "6379",
    "QUEUE_BULL_REDIS_PASSWORD" => sec["REDIS_PASSWORD"],
    "QUEUE_HEALTH_CHECK_ACTIVE" => "true",
    "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS" => "true"
  )
end
n8n_env.merge!(
  "DB_TYPE" => "postgresdb",
  "DB_POSTGRESDB_HOST" => "n8n-postgres",
  "DB_POSTGRESDB_PORT" => "5432",
  "DB_POSTGRESDB_DATABASE" => "n8n",
  "DB_POSTGRESDB_USER" => "n8n",
  "DB_POSTGRESDB_PASSWORD" => sec["POSTGRES_PASSWORD"],
  "N8N_ENCRYPTION_KEY" => sec["N8N_ENCRYPTION_KEY"],
  "N8N_RUNNERS_MODE" => "external",
  "N8N_RUNNERS_BROKER_LISTEN_ADDRESS" => "0.0.0.0",
  "N8N_RUNNERS_BROKER_PORT" => "5679",
  "N8N_RUNNERS_AUTH_TOKEN" => sec["RUNNERS_AUTH_TOKEN"],
  "N8N_EDITOR_BASE_URL" => public_url,
  "N8N_WEBHOOK_URL" => public_url,
  "N8N_SECURE_COOKIE" => "false",
  "EXECUTIONS_DATA_PRUNE" => "true",
  "EXECUTIONS_DATA_MAX_AGE" => "168",
  "GENERIC_TIMEZONE" => "UTC",
  "TZ" => "UTC",
  "N8N_DIAGNOSTICS_ENABLED" => "false"
)
n8n_env["N8N_CONCURRENCY_PRODUCTION_LIMIT"] = env["PROD_LIMIT"] if env["PROD_LIMIT"]
n8n_env["DB_POSTGRESDB_POOL_SIZE"] = env["POOL_SIZE"] if env["POOL_SIZE"]
n8n_env["N8N_DEFAULT_BINARY_DATA_MODE"] = env["BINARY_MODE"] if env["BINARY_MODE"] # drills only
n8n_env["DB_TYPE"] = env["DB_TYPE_OVERRIDE"] if env["DB_TYPE_OVERRIDE"] # drills only (e.g. the wrong value `postgres`)
if env["METRICS"] == "1"
  n8n_env["N8N_METRICS"] = "true"
  n8n_env["N8N_METRICS_INCLUDE_QUEUE_METRICS"] = "true" if queue
end

pg_check = [ "CMD-SHELL", "pg_isready -U n8n -d n8n" ]
runner = lambda do |broker|
  {
    "image" => "n8nio/runners:#{N8N_VERSION}",
    "restart" => "unless-stopped",
    "environment" => {
      "N8N_RUNNERS_AUTH_TOKEN" => sec["RUNNERS_AUTH_TOKEN"],
      "N8N_RUNNERS_MAX_CONCURRENCY" => runner_max,
      "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT" => "15",
      "N8N_RUNNERS_TASK_BROKER_URI" => "http://#{broker}:5679"
    },
    "depends_on" => [ broker ],
    "healthcheck" => {
      "test" => [ "CMD-SHELL", "wget -qO- http://127.0.0.1:5680/healthz" ],
      "interval" => "10s", "timeout" => "10s", "retries" => 10
    }
  }
end

services = {}
services["n8n-postgres"] = {
  "image" => POSTGRES_IMAGE,
  "restart" => "unless-stopped",
  "environment" => { "POSTGRES_USER" => "n8n", "POSTGRES_PASSWORD" => sec["POSTGRES_PASSWORD"], "POSTGRES_DB" => "n8n" },
  "volumes" => [ "postgres-data:/var/lib/postgresql/data" ],
  "healthcheck" => { "test" => pg_check, "interval" => "5s", "timeout" => "5s", "retries" => 10 }
}
if queue
  persistence = aof ? "--appendonly yes --appendfsync everysec" : "--appendonly no --save ''"
  services["n8n-redis"] = {
    "image" => REDIS_IMAGE,
    "restart" => "unless-stopped",
    "command" => "redis-server --requirepass #{sec['REDIS_PASSWORD']} #{persistence} --maxmemory-policy #{env.fetch('REDIS_POLICY', 'noeviction')}",
    "environment" => { "REDISCLI_AUTH" => sec["REDIS_PASSWORD"] },
    "volumes" => [ "redis-data:/data" ],
    "healthcheck" => { "test" => [ "CMD-SHELL", "redis-cli ping | grep PONG" ], "interval" => "5s", "timeout" => "5s", "retries" => 10 }
  }
end

main_deps = { "n8n-postgres" => { "condition" => "service_healthy" } }
main_deps["n8n-redis"] = { "condition" => "service_healthy" } if queue
services["n8n-main"] = {
  "image" => "n8nio/n8n:#{N8N_VERSION}",
  "restart" => "unless-stopped",
  "environment" => n8n_env.dup,
  "ports" => [ "#{host_port}:5678" ],
  "volumes" => [ "n8n-main-data:/home/node/.n8n" ],
  "depends_on" => main_deps,
  "healthcheck" => {
    "test" => [ "CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz/readiness" ],
    "interval" => "10s", "timeout" => "10s", "retries" => 30
  }
}
services["runner-main"] = runner.call("n8n-main")

if queue
  (1..workers).each do |i|
    wenv = n8n_env.dup
    wenv["N8N_ENCRYPTION_KEY"] = "wrong-key-#{'0' * 32}" if env["BAD_KEY_WORKER"] == "1" && i == workers
    services["n8n-worker-#{i}"] = {
      "image" => "n8nio/n8n:#{N8N_VERSION}",
      "restart" => "unless-stopped",
      "command" => "worker --concurrency=#{concurrency}",
      "environment" => wenv,
      "depends_on" => { "n8n-main" => { "condition" => "service_healthy" } },
      "healthcheck" => {
        "test" => [ "CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz" ],
        "interval" => "10s", "timeout" => "10s", "retries" => 10
      },
      "stop_grace_period" => "60s"
    }
    services["runner-worker-#{i}"] = runner.call("n8n-worker-#{i}")
  end
end

if env["PROBES"] == "1"
  pg_sql = "select 'pg conns=' || (select count(*) from pg_stat_activity where usename='n8n') || " \
           "' active=' || (select count(*) from pg_stat_activity where usename='n8n' and state='active') || " \
           "' exec_bytes=' || coalesce((select sum(pg_total_relation_size(c.oid)) from pg_class c " \
           "where c.relname in ('execution_entity','execution_data')),0) || " \
           "' executions=' || (select count(*) from execution_entity)"
  services["pg-probe"] = {
    "image" => POSTGRES_IMAGE,
    "restart" => "unless-stopped",
    "environment" => { "PGPASSWORD" => sec["POSTGRES_PASSWORD"] },
    "entrypoint" => [ "sh", "-c",
                     "while :; do echo \"$$(date +%s) $$(psql -h n8n-postgres -U n8n -d n8n -tAc \"#{pg_sql}\" 2>&1)\"; sleep 5; done" ],
    "depends_on" => { "n8n-postgres" => { "condition" => "service_healthy" } },
    "healthcheck" => { "test" => pg_check.map { |s| s == "pg_isready -U n8n -d n8n" ? "pg_isready -h n8n-postgres -U n8n -d n8n" : s },
                       "interval" => "10s", "timeout" => "5s", "retries" => 10 }
  }
  if queue
    services["redis-probe"] = {
      "image" => REDIS_IMAGE,
      "restart" => "unless-stopped",
      "environment" => { "REDISCLI_AUTH" => sec["REDIS_PASSWORD"] },
      "entrypoint" => [ "sh", "-c",
                       "while :; do echo \"$$(date +%s) redis used_bytes=$$(redis-cli -h n8n-redis info memory | " \
                       "grep '^used_memory:' | cut -d: -f2 | tr -d '\\r') " \
                       "wait=$$(redis-cli -h n8n-redis llen bull:jobs:wait) " \
                       "active=$$(redis-cli -h n8n-redis llen bull:jobs:active)\"; sleep 5; done" ],
      "depends_on" => { "n8n-redis" => { "condition" => "service_healthy" } },
      "healthcheck" => { "test" => [ "CMD-SHELL", "redis-cli -h n8n-redis ping | grep PONG" ],
                         "interval" => "10s", "timeout" => "5s", "retries" => 10 }
    }
  end
end

volumes = { "postgres-data" => nil, "n8n-main-data" => nil }
volumes["redis-data"] = nil if queue

doc = { "services" => services, "volumes" => volumes }
header = <<~HDR
  # n8n #{N8N_VERSION} #{queue ? "queue mode: main + #{workers} worker(s) + Redis + Postgres" : 'regular mode: main + Postgres'}, one server.
  # Generated by scripts/render.rb (n8n-queue-mode-benchmark). Tested on a Selfhost.dev Projects server.
  #
  # - Workers are separate services (n8n-worker-1, -2, ...): to add one, copy a worker
  #   block AND its runner block. (Selfhost.dev's Compose route does not accept `deploy:`/replicas.)
  # - Every n8n process runs Code nodes in its own task runner: one runner per process.
  # - Services are prefixed (n8n-postgres, n8n-redis) so they cannot collide with other
  #   containers that share the host's network.
  # - For measurement as published: n8n listens on all interfaces over plain HTTP with
  #   N8N_SECURE_COOKIE=false. Anywhere reachable, put it behind a TLS proxy, set
  #   N8N_SECURE_COOKIE=true and bind 127.0.0.1:5678:5678.
  # - Set before the first deploy: N8N_ENCRYPTION_KEY (same everywhere, never change it),
  #   POSTGRES_PASSWORD, REDIS_PASSWORD, RUNNERS_AUTH_TOKEN, N8N_PUBLIC_URL (e.g. http://<ip>:5678/).
HDR
print header, doc.to_yaml(line_width: -1).sub(/\A---\n/, "")
