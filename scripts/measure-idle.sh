#!/bin/sh
# Idle resource sampler (read-only on the target: ps, top and footprint). Usage: scripts/measure-idle.sh <pid> <minutes> <out.csv>
# Acceptance memory metric stays peak RSS <= 60 MiB (user decision 2026-11-15). phys_footprint is diagnostic only (app-owned dirty memory).
# Every 10 s: ps %cpu/rss/cputime, footprint phys_footprint, plus top (-l 2: the second sample is a 1 s interval) %cpu and IDLEW (cumulative). Then prints a summary.
# <minutes> may be fractional. Ctrl-C stops early and still summarises. Never signals or attaches to the target.
[ $# = 3 ] || { echo "usage: $0 <pid> <minutes> <out.csv>" >&2; exit 2; }
PID=$1; MIN=$2; OUT=$3
case $PID in ''|*[!0-9]*) echo "pid must be numeric" >&2; exit 2;; esac
kill -0 "$PID" 2>/dev/null || { echo "no such process $PID" >&2; exit 1; }
perl -e 'exit($ARGV[0] =~ /^\d+(\.\d+)?$/ && $ARGV[0] > 0 ? 0 : 1)' "$MIN" || { echo "minutes must be a positive number" >&2; exit 2; }
STOP=; trap 'STOP=1' INT TERM
echo "epoch,ps_cpu_pct,rss_kb,cputime,cputime_s,top_cpu_pct,top_idlew,phys_kb" > "$OUT" || exit 1
START=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); END=$(perl -e "printf '%.3f', $START + $MIN * 60"); K=0
while [ -z "$STOP" ]; do
  NOW=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  set -- $(ps -o %cpu=,rss=,cputime= -p "$PID" 2>/dev/null)
  [ $# = 3 ] || { echo "process $PID exited at $NOW" >&2; break; }
  T=$(top -l 2 -pid "$PID" -stats pid,cpu,idlew,mem 2>/dev/null | awk -v p="$PID" '$1 == p { c = $2; w = $3 } END { gsub(/[^0-9.]/, "", c); gsub(/[^0-9]/, "", w); print c, w }')
  F=$(footprint -p "$PID" 2>/dev/null | awk '$1 == "phys_footprint:" { v = $2; u = $3; m = (u == "GB") ? 1048576 : (u == "MB") ? 1024 : (u == "KB") ? 1 : 1 / 1024; printf "%d", v * m; exit }')
  echo "$NOW,$1,$2,$3,$(echo "$3" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'),${T% *},${T#* },$F" >> "$OUT"
  K=$((K+1)); NEXT=$(perl -e "printf '%.3f', $START + $K * 10")
  perl -e "exit($NEXT > $END ? 0 : 1)" && break                     # next slot is past the window: done
  perl -MTime::HiRes=time,sleep -e '$d = $ARGV[0] - time; sleep $d if $d > 0' "$NEXT" &
  wait $!
done
# shortcut: nearest-rank percentiles on the sample; ps %cpu is the OS's own smoothed figure, so CPU-time delta is the strict one.
awk -F, -v pid="$PID" 'NR > 1 && $2 != "" {
    n++; t[n] = $1; c[n] = $2; r[n] = $3; s[n] = $5; tc[n] = $6; if ($8 > mp) mp = $8; if ($7 != "") { if (!wn) w0 = $7; w1 = $7; wn++ } }
  function pct(a, m, p,   i, j, k, x) { for (i = 1; i <= m; i++) x[i] = a[i]
    for (i = 2; i <= m; i++) { k = x[i]; for (j = i - 1; j >= 1 && x[j] > k; j--) x[j+1] = x[j]; x[j+1] = k }
    k = int(p * m); if (k < p * m) k++; return x[k < 1 ? 1 : k] }
  END { if (n < 1) { print "IDLE: no samples"; exit 1 }
    mr = 0; for (i = 1; i <= n; i++) if (r[i] > mr) mr = r[i]
    el = t[n] - t[1]
    printf "IDLE: pid=%s samples=%d span=%.0fs\n", pid, n, el
    printf "IDLE: ps_cpu_pct   median=%.1f p95=%.1f\n", pct(c, n, 0.5), pct(c, n, 0.95)
    printf "IDLE: top_cpu_pct  median=%.1f p95=%.1f (1 s interval samples)\n", pct(tc, n, 0.5), pct(tc, n, 0.95)
    printf "IDLE: max_phys_footprint_kb=%d (%.1f MiB) [diagnostic]\n", mp, mp / 1024
    printf "IDLE: max_rss_kb=%d (%.1f MiB) [acceptance metric, target <= 60 MiB]\n", mr, mr / 1024
    printf "IDLE: cpu_time_delta=%.2fs over %.0fs => %.3f%% of one core\n", s[n] - s[1], el, (el > 0 ? 100 * (s[n] - s[1]) / el : 0)
    if (wn > 1 && el > 0) printf "IDLE: idle_wakeups=%d over %.0fs => %.2f/s (top IDLEW is a cumulative counter: last - first)\n", w1 - w0, el, (w1 - w0) / el }' "$OUT"
