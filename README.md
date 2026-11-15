# n8n queue mode on one server: Compose file, test kit and raw results

The tested Docker Compose file, test workflows, load script, failure drills and raw numbers behind
Selfhost.dev's post on n8n queue mode.

## The Compose file

[`compose/docker-compose.yml`](compose/docker-compose.yml) runs n8n in queue mode on one server:
main, 2 workers, one task runner per n8n process, Redis and Postgres, every image pinned.

| Image | Version |
|---|---|
| `n8nio/n8n`, `n8nio/runners` | 2.47.7 |
| `postgres` | 17.10-alpine |
| `redis` | 7.4.6-alpine |

```bash
cd compose
cp .env.example .env        # fill in the five values
docker compose up -d
```

> **For measurement as published.** It serves the editor on all interfaces over plain HTTP with
> `N8N_SECURE_COOKIE=false`. To run it anywhere reachable, put it behind a TLS proxy, set
> `N8N_SECURE_COOKIE=true` and bind `127.0.0.1:5678:5678`.

To add a worker, copy a worker block **and** its runner block and change the number.

## What was tested

- **Benchmark** (`results/`): webhook → Code node (fixed CPU work) → Wait 0.5 s → Set, driven by k6 from a
  separate machine at 5, 20 and 50 requests/s for 3 minutes per run, on a 4 vCPU / 8 GB server.
  - `n8n-2.40.7-pg17/`: the full matrix (regular mode, regular with `N8N_CONCURRENCY_PRODUCTION_LIMIT`,
    queue mode with 1, 2 and 4 workers, the concurrency sweep, pool size 10). `numbers.csv` has every run.
  - `n8n-2.40.7-pg16/`: the same matrix on Postgres 16, an earlier pass.
  - `n8n-2.47.7-server2/` and `n8n-2.40.7-server2/`: regular, 2 workers and 4 workers at 50 requests/s on
    a second server of the same size, both versions on the same server.
- **Failure drills** (`drills/`): run locally in Docker with the same Compose file: killing a worker,
  a worker with the wrong encryption key, Redis and Postgres restarts, filesystem binary data, graceful
  shutdown, Redis eviction policy, start order, SQLite → Postgres migration, PgBouncer in transaction mode.

Each run folder holds `summary.txt` (the headline numbers), `k6-summary.json` and `k6.txt` (load generator
output), `editor.txt` (editor response times during the load), `stats.csv` (per-container CPU and memory
every second; container IDs are replaced with per-run aliases such as `c01`) and `metrics.txt` (n8n's
`/metrics` after the run). Server and client IP addresses are replaced with `SERVER_IP` and
`CLIENT_IP`; container logs are not included.

## Caveats

- One run per cell. Repeating the whole matrix moved single cells by up to about 25%.
- Two servers of the same size measured about 2× apart (2 workers at 50 requests/s: 519 against 1,070
  executions a minute on n8n 2.40.7). Compare setups within one results folder, not across folders.
- The k6 load held at most 1,000 requests in flight, so p95 at 20 and 50 requests/s includes queueing.

## Re-running it

- `workflows/build.rb` writes the workflow JSON files; `scripts/setup-http.sh` creates the owner account
  and publishes them over n8n's REST API. The owner it creates (`bench@example.com` /
  `Bench-pass-1234`) is a throwaway for these benchmark stacks: never run it against a server you did
  not create for this, and never reuse that account.
- `scripts/render.rb` renders any variant of the Compose file (`MODE`, `WORKERS`, `CONCURRENCY`,
  `RUNNER_MAX`, `POOL_SIZE`, `N8N_VERSION`, …; see the header of the file).
- `scripts/drills.sh` runs the failure drills against local Docker.
- `scripts/campaign.sh` and `run.sh` run the benchmark matrix: k6 load from your machine and container
  stats sampled over SSH (`scripts/stats-cgroup.sh`). Deployment is yours to plug in: `DEPLOY` names a
  script that deploys and removes each variant (see the header of `campaign.sh`).
- `scripts/table.rb` rebuilds `numbers.csv` from a results folder.
