#!/bin/sh
# Offline test for hooks/adeck-hook. HOME is a temp dir; the real home is never read or written.
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/../.." && pwd)
HOOK="$ROOT/hooks/adeck-hook"; FX="$D/fixtures"
HOME=$(mktemp -d /tmp/adk.XXXXXX); export HOME
TMPDIR="$HOME/tmp"; mkdir -p "$TMPDIR"; export TMPDIR
SUP="$HOME/Library/Application Support/AgentDeck"; mkdir -p "$SUP"; SOCK="$SUP/adeck.sock"
LOG="$HOME/req.log"; FAILS=0; DPID=
[ ${#SOCK} -le 103 ] || { echo "FAIL socket path ${#SOCK} > 103"; exit 1; }
export __CFBundleIdentifier=com.todesktop.230313mzl4w4u92 CLAUDE_CODE_ENTRYPOINT=claude-vscode
trap 'kill $DPID 2>/dev/null; rm -rf "$HOME"' EXIT
now() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
ok() { if [ "$2" = 0 ]; then echo "ok   $1 [${MS}ms]"; else echo "FAIL $1 (rc=$RC ms=$MS)"; FAILS=$((FAILS+1)); fi; }
serve() { unserve; : > "$LOG"; python3 -I "$D/fake_daemon.py" "$SOCK" "$1" "$LOG" "${2:-}" & DPID=$!
  i=0; while [ ! -S "$SOCK" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; }
unserve() { [ -n "$DPID" ] && { kill $DPID 2>/dev/null; wait $DPID 2>/dev/null; }; DPID=; rm -f "$SOCK"; }
run() { S=$(now); /bin/sh "$HOOK" "$1" "$2" < "$3" > "$HOME/out" 2>/dev/null; RC=$?; MS=$(( $(now) - S )); }
empty() { [ ! -s "$HOME/out" ]; }
between() { [ "$MS" -ge "$1" ] && [ "$MS" -le "$2" ]; }
lq() { python3 -I -c 'import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];print(eval(sys.argv[2]))' "$LOG" "$1"; }
GATE="$FX/PreToolUse-Bash.json"; PERM="$FX/PermissionRequest-Bash.json"; POST="$FX/PostToolUse.json"
ENV="$FX/permission-allow.json"; printf '%s' "$(cat "$ENV")" > "$HOME/env.expected"

sh -n "$HOOK"; ok "sh -n adeck-hook" $?
case $SOCK in *" "*) ok "socket path contains a space" 0;; *) ok "socket path contains a space" 1;; esac
run gate PreToolUse "$GATE"                                   # warm-up: first exec of a new file is slow (spec §13)
run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 0 80; ok "no socket: exit 0, empty, <80 ms (50 ms + 2 perl spawns)" $?

serve pass; ADECK_NESTED=1; export ADECK_NESTED; run gate PreToolUse "$GATE"; unset ADECK_NESTED; [ $RC = 0 ] && empty && [ ! -s "$LOG" ]; ok "ADECK_NESTED=1: no request" $?
run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 0 300; ok "PASS: empty" $?
[ "$(lq 'r[0]["line"]')" = "POST /v1/gate/PreToolUse HTTP/1.1" ]; ok "gate path" $?
case $(lq 'r[0]["headers"]["x-adeck-pid"]') in ''|*[!0-9]*) ok "x-adeck-pid numeric" 1;; *) ok "x-adeck-pid numeric" 0;; esac
[ "$(lq 'r[0]["headers"]["x-adeck-host"]')" = "$__CFBundleIdentifier" ]; ok "x-adeck-host passed through" $?
[ "$(lq 'r[0]["headers"]["x-adeck-entry"]')" = "claude-vscode" ]; ok "x-adeck-entry passed through" $?
[ "$(lq 'r[0]["sha256"]')" = "$(shasum -a 256 < "$GATE" | cut -d' ' -f1)" ]; ok "body byte-equal to fixture" $?
run decide PermissionRequest "$PERM"; [ "$(lq 'r[-1]["line"]')" = "POST /v1/decide/PermissionRequest HTTP/1.1" ]; ok "decide path" $?
run event PostToolUse "$POST"; [ $RC = 0 ] && empty && [ "$(lq 'r[-1]["line"]')" = "POST /v1/event/PostToolUse HTTP/1.1" ]; ok "event path, empty" $?

serve decide "$ENV"; run decide PermissionRequest "$PERM"; [ $RC = 0 ] && cmp -s "$HOME/out" "$HOME/env.expected"; ok "DECIDE: stdout byte-equal to envelope" $?
serve hold-json "$ENV"; run decide PermissionRequest "$PERM"
python3 -I -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))!=json.load(open(sys.argv[2])))' "$HOME/out" "$ENV"; ok "HOLD -> json: stdout parses equal" $?
case $(lq 'r[-1]["headers"].get("x-adeck-hook-pid", "")') in ''|*[!0-9]*) ok "wait sends numeric x-adeck-hook-pid" 1;; *) ok "wait sends numeric x-adeck-hook-pid" 0;; esac
serve hold-heartbeat-json "$ENV"; run decide PermissionRequest "$PERM"
[ $RC = 0 ] && between 2500 4500 && python3 -I -c 'import json,sys;json.load(open(sys.argv[1]))' "$HOME/out"; ok "HOLD -> heartbeats -> json (~3 s)" $?
serve hold-heartbeat-empty; run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 2500 4500; ok "HOLD -> heartbeats -> close: empty" $?
serve hold-silent; run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 6000 7500; ok "HOLD -> silence: empty, 6-7.5 s" $?
serve wait404; run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 0 400; ok "HOLD -> wait 404: empty" $?
serve hang; run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 400 800; ok "hang, gate: ~0.5 s" $?
run event PostToolUse "$POST"; [ $RC = 0 ] && empty && between 250 600; ok "hang, event: ~0.3 s" $?
serve http500; run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 0 300; ok "HTTP 500: empty" $?
serve garbage; run gate PreToolUse "$GATE"; [ $RC = 0 ] && empty && between 0 300; ok "garbage body: empty" $?

serve hold-silent; /bin/sh "$HOOK" gate PreToolUse < "$GATE" > "$HOME/out" 2>/dev/null & HP=$!
sleep 1; [ "$(pgrep -f "curl.*$HOME/Library" | wc -l | tr -d ' ')" -ge 1 ]; ok "curl is waiting while held" $?
kill -TERM $HP; wait $HP; RC=$?; sleep 0.4
[ $RC = 0 ] && [ "$(pgrep -f "curl.*$HOME/Library" | wc -l | tr -d ' ')" = 0 ] && [ -z "$(ls "$TMPDIR" | grep '^adeck')" ]; ok "SIGTERM while held: exit 0, no curl, no temp file" $?
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}' > "$HOME/pretool-allow.json"
serve hold-json "$HOME/pretool-allow.json"; run gate PreToolUse "$GATE"
[ $RC = 0 ] && cmp -s "$HOME/out" "$HOME/pretool-allow.json"; ok "valid PreToolUse envelope preserved" $?
# Invalid daemon replies must never become Claude hook output, even when HTTP itself succeeds.
for BADJSON in '{broken' '[]' '{}' '{"hookSpecificOutput":' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"maybe"}}}' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; do
  printf '%s' "$BADJSON" > "$HOME/bad-response.json"
  for RESPONSE in decide hold-json; do
    serve "$RESPONSE" "$HOME/bad-response.json"; run decide PermissionRequest "$PERM"
    [ $RC = 0 ] && empty; ok "$RESPONSE invalid envelope fails open" $?
  done
done
unserve; [ $FAILS = 0 ] && echo "ALL GREEN" || { echo "$FAILS FAILED"; exit 1; }
