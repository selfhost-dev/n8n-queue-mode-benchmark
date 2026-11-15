#!/usr/bin/env ruby
# frozen_string_literal: true

# Collects every results/<run>/ folder into results/numbers.csv and prints a markdown table.
#   ruby scripts/table.rb
require "json"
require "csv"

here = File.expand_path("..", __dir__)
rows = []
Dir[File.join(here, "results", "*", "meta.txt")].sort.each do |meta_path|
  dir = File.dirname(meta_path)
  next if File.basename(dir).start_with?("_")

  s = JSON.parse(IO.popen([ "ruby", File.join(here, "scripts", "analyze.rb"), dir, "--json" ], &:read))
  meta = File.readlines(meta_path, chomp: true).to_h { |l| l.split("=", 2) }
  t0 = meta["load_start"].to_i
  t1 = meta["load_end"].to_i
  k6 = File.exist?(File.join(dir, "k6.txt")) ? File.read(File.join(dir, "k6.txt")) : ""
  st = k6.scan(/non-200: status=(\d+)/).flatten.tally
  n8n_errors = st.reject { |code, _| code == "0" }.values.sum
  net_errors = st.fetch("0", 0)
  # executions n8n recorded during the load window (pg-probe row counts)
  logs = File.exist?(File.join(dir, "container-logs.txt")) ? File.read(File.join(dir, "container-logs.txt")) : ""
  pg = logs.scan(/\s(\d{10}) pg conns=\d+ active=\d+ exec_bytes=\d+ executions=(\d+)/).map { |a| a.map(&:to_i) }
  before = pg.select { |ts, _| ts <= t0 }.map(&:last).last
  after = pg.select { |ts, _| ts <= t1 }.map(&:last).last
  accepted = before && after ? after - before : nil
  name, rate = File.basename(dir).split("-r")
  roles = s["roles"] || {}
  rows << {
    "run" => File.basename(dir), "variant" => name, "rate_rps" => rate.to_i,
    "answered_200" => s["ok"], "answered_per_min" => s["exec_per_min"],
    "executions_started_per_min" => accepted && (accepted * 60.0 / s["load_seconds"]).round(1),
    "n8n_errors" => n8n_errors, "timeouts_or_network" => net_errors,
    "error_codes" => st.map { |c, n| "#{c}x#{n}" }.join(" "),
    "not_sent" => s["dropped_iterations"],
    "p50_ms" => s["p50_ms"], "p95_ms" => s["p95_ms"], "p99_ms" => s["p99_ms"],
    "stack_mem_idle_mib" => s["stack_mem_idle_mib"], "stack_mem_peak_mib" => s["stack_mem_peak_mib"],
    "host_mem_peak_mib" => s["host_mem_peak_mib"], "stack_cpu_avg_pct" => s["stack_cpu_avg_pct"],
    "main_mem_peak_mib" => roles.dig("n8n-main", "mem_peak_mib"),
    "workers_mem_peak_mib" => roles.dig("n8n-worker", "mem_peak_mib"),
    "runners_cpu_avg_pct" => roles.dig("task-runner", "cpu_avg_pct"),
    "editor_idle_ms" => s["editor_idle_ms"], "editor_p50_ms" => s["editor_load_p50_ms"],
    "editor_p95_ms" => s["editor_load_p95_ms"],
    "pg_conns_idle" => s["pg_conns_idle"], "pg_conns_max" => s["pg_conns_max"],
    "redis_mb_idle" => s["redis_mb_idle"], "redis_mb_max" => s["redis_mb_max"], "queue_wait_max" => s["queue_wait_max"],
    "exec_tables_mib_end" => s["exec_tables_mib_end"]
  }
end
order = %w[r0 r1 q1 q2 q4 q2c5 q2c10 q2c20 q4p10]
rows.sort_by! { |r| [ order.index(r["variant"]) || 99, r["rate_rps"] ] }

CSV.open(File.join(here, "results", "numbers.csv"), "w") do |csv|
  csv << rows.first.keys
  rows.each { |r| csv << r.values }
end

cols = %w[run answered_per_min n8n_errors timeouts_or_network p50_ms p95_ms main_mem_peak_mib stack_mem_peak_mib runners_cpu_avg_pct editor_p95_ms pg_conns_max redis_mb_max queue_wait_max]
puts "| #{cols.join(' | ')} |"
puts "|#{cols.map { '---' }.join('|')}|"
rows.each { |r| puts "| #{cols.map { |c| r[c].nil? ? '-' : r[c] }.join(' | ')} |" }
