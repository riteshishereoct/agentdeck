#!/bin/sh
# Hosts actual SwiftUI views offscreen; no window is ordered and no live daemon/settings are used.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /private/tmp/agentdeck-layout-check.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'BUILD'
from pathlib import Path
import subprocess, sys
root, temp = map(Path, sys.argv[1:])
bin_path = Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=root,text=True).strip())
app = temp/'LayoutCheck.app/Contents'
(app/'MacOS').mkdir(parents=True)
(app/'Info.plist').write_text('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.agentdeck.layout-check</string><key>CFBundleExecutable</key><string>LayoutCheck</string><key>LSUIElement</key><true/></dict></plist>')
main = temp/'main.swift'
main.write_text((root/'checks/DeckLayoutChecks.swift').read_text())
sources=[str(p) for p in (root/'Sources/AgentDeckApp').rglob('*.swift') if p.name != 'main.swift']
objects=[str(p) for p in (bin_path/'AgentDeckCore.build').rglob('*.o')]
if not objects: objects=[str(p) for p in bin_path.parents[1].glob('Intermediates.noindex/**/Debug/AgentDeckCore-t.build/Objects-normal/*/*.o')]
if not objects: raise SystemExit('Run swift build before the hosted layout check')
subprocess.run(['swiftc','-I',str(bin_path),*sources,str(main),*objects,'-o',str(app/'MacOS/LayoutCheck')],cwd=root,check=True)
subprocess.run([str(app/'MacOS/LayoutCheck'),str(temp)],cwd=root,check=True)
BUILD
