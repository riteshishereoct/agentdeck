#!/bin/sh
# Claude Code statusLine command: records the plan-usage windows Claude Code itself passes on stdin
# (documented `rate_limits`, Pro/Max only) to ~/.agentdeck/usage.json for AgentDeck, and prints a short status line.
# Reads nothing else; no credentials, no network. Install: settings.json "statusLine": {"type":"command","command":"sh <this file>"}.
IN=$(cat)
OUT="$HOME/.agentdeck/usage.json"
U=$(printf '%s' "$IN" | jq -c '.rate_limits // empty | {five_hour, seven_day, updated_at: (now | floor)}' 2>/dev/null)
if [ -n "$U" ]; then
  mkdir -p "$HOME/.agentdeck" && printf '%s\n' "$U" > "$OUT.$$" && mv -f "$OUT.$$" "$OUT"
fi
printf '%s' "$IN" | jq -r '
  def win($n; $w; $f): if $w then "\($n) \($w.used_percentage | floor)% · resets \($w.resets_at | strflocaltime($f))" else empty end;
  [win("5h"; .rate_limits.five_hour; "%H:%M"), win("7d"; .rate_limits.seven_day; "%a %H:%M")] | if length > 0 then join("  ") else "usage: n/a" end' 2>/dev/null
