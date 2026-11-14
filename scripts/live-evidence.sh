#!/bin/sh
# live-evidence.sh <since: e.g. 2026-11-14T05:00:00Z> [transcript.jsonl ...]
# Prints metadata-only evidence for a live test window:
#  1. AgentDeck log lines after <since> (hook routes, held requests, request status changes, person decisions + source + outcome)
#  2. for each given Claude transcript: tool_use -> tool_result outcome after <since> (tool name, is_error, first 100 chars of result)
# Never prints prompts, notes or answers from AgentDeck; transcript result excerpts are the agent's own output - redact before sharing.
SINCE=${1:?usage: live-evidence.sh <since-iso> [transcript.jsonl ...]}; shift
LOG="$HOME/Library/Logs/AgentDeck/agentdeck.log"
echo "== AgentDeck log since $SINCE"
awk -v s="$SINCE" '$1 >= s && ($2=="decision" || $2=="request" || $3 ~ /PermissionRequest|PreToolUse|Notification|Stop|Subagent/)' "$LOG"
for T in "$@"; do
  echo "== transcript $(basename "$T")"
  python3 -I - "$T" "$SINCE" <<'EOF'
import json, sys
path, since = sys.argv[1], sys.argv[2]
uses = {}
for line in open(path, encoding="utf-8", errors="replace"):
    try: e = json.loads(line)
    except Exception: continue
    ts = e.get("timestamp", "")
    if ts and ts < since: continue
    content = (e.get("message") or {}).get("content")
    if not isinstance(content, list): continue
    for b in content:
        if b.get("type") == "tool_use": uses[b.get("id")] = (b.get("name"), ts)
        elif b.get("type") == "tool_result":
            name, t0 = uses.get(b.get("tool_use_id"), ("?", ""))
            c = b.get("content"); text = c if isinstance(c, str) else " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))
            print(f"{ts} {name} error={bool(b.get('is_error'))} :: {text[:100]!r}")
EOF
done
