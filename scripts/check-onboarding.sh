#!/bin/sh
# Hosts actual SwiftUI views offscreen; no window is ordered and no live daemon/settings are used.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /private/tmp/agentdeck-onboarding-check.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'BUILD'
from pathlib import Path
import subprocess, sys
root, temp = map(Path, sys.argv[1:])
bin_path = Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=root,text=True).strip())
app = temp/'OnboardingCheck.app/Contents'
(app/'MacOS').mkdir(parents=True)
(app/'Info.plist').write_text('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.agentdeck.onboarding-check</string><key>CFBundleExecutable</key><string>OnboardingCheck</string><key>LSUIElement</key><true/></dict></plist>')
guide = root/'Resources/AgentDeck-Guide.html'
if guide.exists():
    (app/'Resources').mkdir()
    (app/'Resources/AgentDeck-Guide.html').write_bytes(guide.read_bytes())
main = temp/'main.swift'
main.write_text((root/'checks/OnboardingChecks.swift').read_text())
sources=[str(p) for p in (root/'Sources/AgentDeckApp').rglob('*.swift') if p.name != 'main.swift']
objects=[str(p) for p in (bin_path/'AgentDeckCore.build').rglob('*.o')]
if not objects: raise SystemExit('Run swift build before the hosted layout check')
subprocess.run(['swiftc','-I',str(bin_path),*sources,str(main),*objects,'-o',str(app/'MacOS/OnboardingCheck')],cwd=root,check=True)
subprocess.run([str(app/'MacOS/OnboardingCheck'),str(temp)],cwd=root,check=True)
BUILD
