#!/bin/sh
# Samples every Docker container's cgroup v2 counters into a CSV until killed.
# Runs as an unprivileged user on the benchmark server (no docker access needed).
#
#   sh stats-cgroup.sh <out.csv> [interval_seconds]
#
# Columns: unix_ts,container,role,created,cpu_usec,mem_current_mib,mem_peak_mib,oom_kill
#   role     n8n-main | n8n-worker | task-runner | postgres | redis | probe | other (from the processes)
#   created  the container cgroup's change time: lets the analysis keep only the containers
#            started for the scenario (other containers on the box are excluded)
#   A "host" row per sample: whole-box memory in use (MemTotal - MemAvailable) in mem_current_mib.
out=${1:?usage: stats-cgroup.sh <out.csv> [interval]}
interval=${2:-1}
[ -s "$out" ] || echo "unix_ts,container,role,created,cpu_usec,mem_current_mib,mem_peak_mib,oom_kill" >"$out"

role_of() {
  r=other
  for p in $(cat "$1/cgroup.procs" 2>/dev/null); do
    cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *"while :"*) echo probe; return ;;
      *task-runner*|*runners*|*launcher*) echo task-runner; return ;;
      *"n8n worker"*|*"n8n/bin/n8n worker"*) echo n8n-worker; return ;;
      *bin/n8n*|*"n8n start"*) r=n8n-main ;;
      *redis-server*) echo redis; return ;;
      postgres*|*bin/postgres*) echo postgres; return ;;
    esac
  done
  echo "$r"
}

while :; do
  ts=$(date +%s)
  for d in /sys/fs/cgroup/system.slice/docker-*.scope; do
    [ -d "$d" ] || continue
    id=$(basename "$d" .scope); id=${id#docker-}; id=$(echo "$id" | cut -c1-12)
    role=$(role_of "$d")
    created=$(stat -c %Z "$d" 2>/dev/null)
    cpu=$(awk '/^usage_usec/{print $2}' "$d/cpu.stat" 2>/dev/null)
    cur=$(awk '{printf "%.1f", $1/1048576}' "$d/memory.current" 2>/dev/null)
    peak=$(awk '{printf "%.1f", $1/1048576}' "$d/memory.peak" 2>/dev/null)
    oom=$(awk '/^oom_kill /{print $2}' "$d/memory.events" 2>/dev/null)
    echo "$ts,$id,$role,${created:-},${cpu:-},${cur:-},${peak:-},${oom:-0}"
  done >>"$out"
  awk -v ts="$ts" '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%s,host,host,,,%.1f,,0\n", ts, (t-a)/1024}' /proc/meminfo >>"$out"
  sleep "$interval"
done
