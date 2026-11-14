#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="$ROOT/build/AgentDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AgentDeckApp" "$APP/Contents/MacOS/AgentDeck"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AgentDeck-Guide.html" "$APP/Contents/Resources/AgentDeck-Guide.html"
SUPPORT="$APP/Contents/Resources/AgentDeck"
mkdir -p "$SUPPORT/hooks" "$SUPPORT/installer" "$SUPPORT/config"
cp "$ROOT/hooks/adeck-hook" "$SUPPORT/hooks/adeck-hook"
cp "$ROOT/installer/install.sh" "$ROOT/installer/adeck_settings.py" "$SUPPORT/installer/"
cp "$ROOT/config/capabilities.json" "$SUPPORT/config/capabilities.json"
codesign --force -s - "$APP"
echo "$APP"
