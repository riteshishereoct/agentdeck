#!/bin/sh
# SIGKILL of the hook shell while a decision is held (spec §13/protocol "SIGKILL orphan"). Offline: temp HOME/TMPDIR, fake daemon only.
# The fake daemon keeps sending heartbeats (like the real one), so curl's 6 s speed abort can never be what ends the orphan:
# only the hook's watchdog can. The real daemon's own release on X-Adeck-Hook-Pid is proven in Swift (HookLivenessTests).
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/../.." && pwd)
HOOK="$ROOT/hooks/adeck-hook"; FX="$ROOT/Tests/AgentDeckCoreTests/Fixtures/hooks"
HOME=$(mktemp -d /tmp/adk.XXXXXX); export HOME
TMPDIR="$HOME/tmp"; mkdir -p "$TMPDIR"; export TMPDIR
SUP="$HOME/Library/Application Support/AgentDeck"; mkdir -p "$SUP"; SOCK="$SUP/adeck.sock"
LOG="$HOME/req.log"; CLOSED="$LOG.closed"; DPID=; HP=; CP=; WP=; FAILS=0
export __CFBundleIdentifier=com.todesktop.230313mzl4w4u92 CLAUDE_CODE_ENTRYPOINT=claude-vscode
# Only our own PIDs are ever signalled (other processes may run the same binaries).
trap 'for p in $CP $WP $DPID; do kill $p 2>/dev/null; done; wait $DPID 2>/dev/null; rm -rf "$HOME"' EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time()'; }
ok() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS+1)); fi; }
within() { perl -e "exit(($2) - ($1) <= $3 ? 0 : 1)"; }   # within T0 T1 seconds
lq() { python3 -I -c 'import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];print(eval(sys.argv[2]))' "$LOG" "$1"; }

python3 -I "$D/fake_daemon.py" "$SOCK" hold-heartbeat-forever "$LOG" & DPID=$!
i=0; while [ ! -S "$SOCK" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
[ -S "$SOCK" ]; ok "fake daemon (heartbeats forever) listening" $?

# Leftovers of an earlier SIGKILL: the held path sweeps adeck.* older than any hold (595 s), never a fresh one.
: > "$TMPDIR/adeck.STALE001"; touch -t 202001010000 "$TMPDIR/adeck.STALE001"; : > "$TMPDIR/adeck.FRESH001"

/bin/sh "$HOOK" decide PermissionRequest < "$FX/PermissionRequest-Bash.json" > "$HOME/out" 2>/dev/null & HP=$!
i=0; while [ $i -lt 100 ]; do CP=$(pgrep -P $HP curl | head -1); [ -n "$CP" ] && grep -q /v1/wait/ "$LOG" 2>/dev/null && break; sleep 0.05; i=$((i+1)); done
[ -n "$CP" ]; ok "hook shell $HP holds; its curl child is $CP" $?
[ -n "$CP" ] || { echo "$FAILS FAILED"; exit 1; }
WP=$(pgrep -P $HP | grep -v "^$CP\$" | head -1)
[ -n "$WP" ]; ok "watchdog $WP runs beside curl" $?
[ "$(lq '[x for x in r if "/v1/wait/" in x["line"]][0]["headers"].get("x-adeck-hook-pid")')" = "$HP" ]; ok "wait carries X-Adeck-Hook-Pid = hook shell pid" $?
OUTF=$(ps -o command= -p $CP | sed -n 's/.* -o \([^ ]*\) .*/\1/p')
[ -f "$OUTF" ] && [ "$(dirname "$OUTF")" = "$TMPDIR" ]; ok "temp file lives in \$TMPDIR while held: $OUTF" $?
i=0; while [ -e "$TMPDIR/adeck.STALE001" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i+1)); done
[ ! -e "$TMPDIR/adeck.STALE001" ] && [ -e "$TMPDIR/adeck.FRESH001" ]; ok "stale adeck.* swept, fresh one kept" $?
[ ! -e "$CLOSED" ]; ok "daemon side still sees the connection open" $?

T_KILL=$(now); kill -9 $HP; wait $HP 2>/dev/null
kill -0 $HP 2>/dev/null; [ $? != 0 ]; ok "hook shell is dead after SIGKILL" $?
T_GONE=; T_RM=; T_WD=
while [ -z "$T_GONE" ] || [ -z "$T_RM" ] || [ -z "$T_WD" ]; do
  [ -z "$T_GONE" ] && ! kill -0 $CP 2>/dev/null && T_GONE=$(now)
  [ -z "$T_RM" ] && [ ! -e "$OUTF" ] && T_RM=$(now)
  [ -z "$T_WD" ] && ! kill -0 $WP 2>/dev/null && T_WD=$(now)
  within "$T_KILL" "$(now)" 5 || break; sleep 0.05
done
[ -n "$T_GONE" ] && within "$T_KILL" "$T_GONE" 2; ok "orphan curl ends <= 2 s after the kill (watchdog, not the speed abort)" $?
[ -n "$T_RM" ] && within "$T_KILL" "$T_RM" 2; ok "temp file removed <= 2 s after the kill" $?
[ -n "$T_WD" ]; ok "watchdog exits after cleaning up" $?
i=0; while [ ! -e "$CLOSED" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i+1)); done
[ -e "$CLOSED" ] && within "$T_KILL" "$(cat "$CLOSED")" 2.5; ok "daemon side saw the socket close <= 2.5 s after the kill" $?
[ -n "$T_GONE" ] && echo "MEASURED: kill->curl-exit $(perl -e "printf '%.2f', $T_GONE - $T_KILL")s"
[ $FAILS = 0 ] && echo "ALL GREEN" || { echo "$FAILS FAILED"; exit 1; }
