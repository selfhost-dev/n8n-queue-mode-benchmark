#!/usr/bin/env ruby
# frozen_string_literal: true

# Summarises one run folder from scripts/run.sh.
#   ruby scripts/analyze.rb results/<label> [--json]
require "json"

dir = ARGV[0] or abort "usage: analyze.rb <run dir> [--json]"
meta = File.readlines(File.join(dir, "meta.txt"), chomp: true).to_h { |l| l.split("=", 2) }
t0 = meta["load_start"].to_i
t1 = meta["load_end"].to_i
start = meta["scenario_start"].to_i
dur = [ t1 - t0, 1 ].max

def pct(arr, q)
  return nil if arr.empty?

  s = arr.sort
  s[[ (q * (s.size - 1)).round, s.size - 1 ].min]
end

r = { "label" => meta["label"], "load_seconds" => dur }

# k6
k6f = File.join(dir, "k6-summary.json")
if File.exist?(k6f)
  m = JSON.parse(File.read(k6f))["metrics"]
  d = m["http_req_duration"] || {}
  ok = m.dig("checks", "passes").to_i
  bad = m.dig("checks", "fails").to_i
  r.merge!(
    "requests" => ok + bad, "ok" => ok, "errors" => bad,
    "exec_per_min" => (ok * 60.0 / dur).round(1),
    "p50_ms" => d["med"]&.round, "p95_ms" => d["p(95)"]&.round, "p99_ms" => d["p(99)"]&.round, "max_ms" => d["max"]&.round,
    "dropped_iterations" => m.dig("dropped_iterations", "count").to_i
  )
end

# cgroup samples: only containers created for this scenario
sf = File.join(dir, "stats.csv")
if File.exist?(sf)
  rows = File.readlines(sf, chomp: true).drop(1).map { |l| l.split(",", -1) }
  host = rows.select { |x| x[1] == "host" }
  ours = rows.reject { |x| x[1] == "host" }.select { |x| x[3].to_i >= start }
  by_c = ours.group_by { |x| x[1] }
  roles = Hash.new { |h, k| h[k] = { "containers" => 0, "cpu_avg_pct" => 0.0, "cpu_peak_pct" => 0.0, "mem_peak_mib" => 0.0, "mem_idle_mib" => 0.0, "oom_kills" => 0 } }
  per_ts_mem = Hash.new(0.0)
  by_c.each_value do |samples|
    role = samples.map { |x| x[2] }.tally.max_by { |_, n| n }[0]
    s = samples.sort_by { |x| x[0].to_i }
    load = s.select { |x| x[0].to_i.between?(t0, t1) }
    cpu = load.each_cons(2).map do |a, b|
      dt = b[0].to_i - a[0].to_i
      dt.positive? ? (b[4].to_f - a[4].to_f) / dt / 1e4 : 0
    end
    rr = roles[role]
    rr["containers"] += 1
    rr["cpu_avg_pct"] += cpu.empty? ? 0 : cpu.sum / cpu.size
    rr["cpu_peak_pct"] += cpu.max || 0
    rr["mem_peak_mib"] += load.map { |x| x[5].to_f }.max || 0
    rr["mem_idle_mib"] += s.select { |x| x[0].to_i < t0 }.map { |x| x[5].to_f }.last || 0
    rr["oom_kills"] = [ rr["oom_kills"], s.map { |x| x[7].to_i }.max ].max
    s.each { |x| per_ts_mem[x[0].to_i] += x[5].to_f }
  end
  roles.each_value { |v| v.transform_values! { |x| x.is_a?(Float) ? x.round(1) : x } }
  r["roles"] = roles
  load_ts = per_ts_mem.select { |ts, _| ts.between?(t0, t1) }
  r["stack_mem_peak_mib"] = load_ts.values.max&.round
  r["stack_mem_idle_mib"] = per_ts_mem.select { |ts, _| ts < t0 }.values.last&.round
  r["stack_cpu_avg_pct"] = roles.values.sum { |v| v["cpu_avg_pct"] }.round
  r["host_mem_peak_mib"] = host.select { |x| x[0].to_i.between?(t0, t1) }.map { |x| x[5].to_f }.max&.round
end

# editor probe
ef = File.join(dir, "editor.txt")
if File.exist?(ef)
  lines = File.readlines(ef, chomp: true).map(&:split).select { |x| x.size == 3 }
  during = lines.select { |ts, _, _| ts.to_i.between?(t0, t1) }
  idle = lines.select { |ts, _, _| ts.to_i < t0 }
  ms = ->(a) { a.map { |x| (x[2].to_f * 1000).round } }
  r["editor_idle_ms"] = pct(ms[idle], 0.5)
  r["editor_load_p50_ms"] = pct(ms[during], 0.5)
  r["editor_load_p95_ms"] = pct(ms[during], 0.95)
  r["editor_load_max_ms"] = ms[during].max
  r["editor_errors"] = during.count { |x| x[1] != "200" }
end

# pg / redis probe lines
lf = File.join(dir, "container-logs.txt")
if File.exist?(lf)
  txt = File.read(lf)
  pg = txt.scan(/\s(\d{10}) pg conns=(\d+) active=(\d+) exec_bytes=(\d+) executions=(\d+)/).map { |a| a.map(&:to_i) }
  pgl = pg.select { |x| x[0].between?(t0, t1) }
  unless pg.empty?
    r["pg_conns_max"] = pgl.map { |x| x[1] }.max
    r["pg_conns_idle"] = pg.select { |x| x[0] < t0 }.map { |x| x[1] }.last
    r["pg_active_max"] = pgl.map { |x| x[2] }.max
    r["exec_tables_mib_end"] = (pg.last[3] / 1048576.0).round(1)
    r["executions_rows_end"] = pg.last[4]
  end
  rd = txt.scan(/\s(\d{10}) redis used_bytes=(\d+) wait=(\d+) active=(\d+)/).map { |a| [ a[0].to_i, (a[1].to_f / 1048576).round(2), a[2].to_i, a[3].to_i ] }
  rdl = rd.select { |x| x[0].between?(t0, t1) }
  unless rd.empty?
    r["redis_mb_max"] = rdl.map { |x| x[1] }.max
    r["redis_mb_idle"] = rd.select { |x| x[0] < t0 }.map { |x| x[1] }.last
    r["queue_wait_max"] = rdl.map { |x| x[2] }.max
  end
end

if ARGV.include?("--json")
  puts JSON.pretty_generate(r)
else
  r.each do |k, v|
    if k == "roles"
      v.each { |role, x| puts format("  %-12s %s", role, x.map { |a, b| "#{a}=#{b}" }.join(" ")) }
    else
      puts "#{k}=#{v}"
    end
  end
end
