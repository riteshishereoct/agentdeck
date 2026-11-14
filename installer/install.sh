#!/bin/sh
# Installs adeck-hook under $HOME and merges AgentDeck entries into $HOME/.claude/settings.json.
set -eu
[ -n "${HOME:-}" ] || { echo "HOME unset" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
SUP="$HOME/Library/Application Support/AgentDeck"
mkdir -p "$HOME/.agentdeck/bin" "$HOME/.claude" "$SUP"
# Atomic replace: a hook shell holding a decision keeps reading its old inode (bash reads scripts incrementally).
DST="$HOME/.agentdeck/bin/adeck-hook"
cp "$REPO/hooks/adeck-hook" "$DST.$$"
chmod 0755 "$DST.$$"
mv -f "$DST.$$" "$DST"
chmod 0700 "$SUP"
/bin/sh "$HOME/.agentdeck/bin/adeck-hook" event SessionStart </dev/null || true   # first-exec scan, no socket
[ -e "$SUP/capabilities.json" ] || { cp "$REPO/config/capabilities.json" "$SUP/capabilities.json"; chmod 0600 "$SUP/capabilities.json"; }
python3 -I "$REPO/installer/adeck_settings.py" install --settings "$HOME/.claude/settings.json"
