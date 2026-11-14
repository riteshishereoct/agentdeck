#!/bin/sh
# Removes AgentDeck's hook entries from $HOME/.claude/settings.json; --purge also deletes its data.
set -eu
[ -n "${HOME:-}" ] || { echo "HOME unset" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
S="$HOME/.claude/settings.json"
[ ! -e "$S" ] || python3 -I "$REPO/installer/adeck_settings.py" uninstall --settings "$S"
if [ "${1:-}" = "--purge" ]; then rm -rf "$HOME/.agentdeck" "$HOME/Library/Application Support/AgentDeck"; fi
