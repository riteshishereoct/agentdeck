#!/bin/sh
# Checks the actual AppKit panel without showing a window or starting AgentDeck.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d /tmp/adeck-panel.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/Sources/AgentDeckApp/OverlayPanel.swift" "$ROOT/checks/PanelChecks.swift" -o "$CHECK_DIR/panel-checks"
"$CHECK_DIR/panel-checks"
