#!/bin/sh
# Installer tests. Settings files live in a temp dir and are always passed with --settings.
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/../.." && pwd); FXD="$D/fixtures"
W=$(mktemp -d /tmp/adk.XXXXXX); HOME="$W/home"; mkdir -p "$HOME"; export HOME; S="$W/settings.json"
trap 'rm -rf "$W"' EXIT; FAILS=0; RC=0; MS=0
PY="python3 -I $ROOT/installer/adeck_settings.py"
ok() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS+1)); fi; }
jeq() { python3 -I -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))!=json.load(open(sys.argv[2])))' "$1" "$2"; }
pyx() { python3 -I -c "import json,sys;o=json.load(open(sys.argv[1]));d=json.load(open(sys.argv[2]));sys.exit(0 if ($2) else 1)" "$FXD/$1" "$S"; }
nb() { n=0; for f in "$S".agentdeck-backup-*; do [ -e "$f" ] && n=$((n+1)); done; echo $n; }
fresh() { rm -f "$S" "$S".agentdeck-backup-*; cp "$FXD/$1" "$S"; chmod 600 "$S"; }
ONE='all(sum("/.agentdeck/bin/adeck-hook" in h["command"] for g in v for h in g["hooks"])==1 for v in d["hooks"].values())'

# A. missing file -> exact protocol section 7 entries, no backup, 12 events, one AgentDeck hook each
rm -f "$S"; $PY install --settings "$S" 2>/dev/null; ok "A1 install into missing file" $?
pyx empty-object.json "len(d['hooks'])==12 and $ONE"; ok "A2 12 events, exactly one entry each" $?
pyx empty-object.json 'd["hooks"]["PreToolUse"]==[{"matcher":"*","hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook gate PreToolUse","timeout":600}]}]'; ok "A3 PreToolUse entry exact" $?
pyx empty-object.json 'd["hooks"]["PermissionRequest"][0]["hooks"][0]=={"type":"command","command":"~/.agentdeck/bin/adeck-hook decide PermissionRequest","timeout":600}'; ok "A4 PermissionRequest entry exact" $?
pyx empty-object.json 'd["hooks"]["PostToolUseFailure"]==[{"matcher":"*","hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook event PostToolUseFailure","async":True}]}]'; ok "A5 PostToolUseFailure entry exact" $?
pyx empty-object.json 'd["hooks"]["SessionEnd"]==[{"hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook event SessionEnd","async":True}]}]'; ok "A6 SessionEnd has no matcher" $?
[ "$(nb)" = 0 ]; ok "A7 no backup for a missing file" $?
$PY uninstall --settings "$S" 2>/dev/null; echo '{}' > "$W/empty.json"; jeq "$S" "$W/empty.json"; ok "A8 install -> uninstall on missing file leaves {}" $?

$PY install --settings "$S" 2>/dev/null
pyx empty-object.json 'd["hooks"].get("PermissionDenied")==[{"matcher":"*","hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook event PermissionDenied","async":True}]}]'; ok "A9 PermissionDenied registered async with matcher" $?

# B. foreign hooks keep order and values; byte-idempotent; backup; mode; warning
fresh foreign.json; $PY install --settings "$S" 2>"$W/err"; ok "B1 install over foreign" $?
pyx foreign.json 'all(d["hooks"][k][:len(v)]==v for k,v in o["hooks"].items()) and all(d[k]==v for k,v in o.items() if k!="hooks") and list(d)[:len(o)]==list(o)'; ok "B2 foreign groups first, same order; unrelated keys and key order kept" $?
pyx foreign.json "$ONE"; ok "B3 one AgentDeck entry per event" $?
[ "$(nb)" = 1 ] && cmp -s "$(ls "$S".agentdeck-backup-*)" "$FXD/foreign.json"; ok "B4 backup equals original" $?
[ "$(stat -f %Lp "$S")" = 600 ]; ok "B5 file mode preserved" $?
[ "$(grep -c 'graphify hook pretool' "$W/err")" = 1 ] && [ "$(grep -c 'may return updatedInput after you approve in AgentDeck (Channel 2)' "$W/err")" = 1 ]; ok "B6 stderr warns once per foreign PreToolUse hook" $?
cp "$S" "$W/once"; $PY install --settings "$S" 2>/dev/null; cmp -s "$S" "$W/once" && [ "$(nb)" = 1 ]; ok "B7 second install byte-identical, no extra backup" $?
$PY uninstall --settings "$S" 2>/dev/null; jeq "$S" "$FXD/foreign.json" && [ "$(nb)" = 2 ]; ok "B8 uninstall -> JSON-equal to original, backup made" $?
cp "$S" "$W/clean"; $PY uninstall --settings "$S" 2>/dev/null; cmp -s "$S" "$W/clean" && [ "$(nb)" = 2 ]; ok "B9 uninstall on a clean file is a no-op" $?

# C. older AgentDeck entry with another matcher, and one inside a mixed group
fresh older-agentdeck.json; $PY install --settings "$S" 2>/dev/null; ok "C1 install over older entries" $?
pyx older-agentdeck.json "$ONE"; ok "C2 no duplicates" $?
pyx older-agentdeck.json 'len(d["hooks"]["PreToolUse"])==2 and d["hooks"]["PreToolUse"][0]==o["hooks"]["PreToolUse"][0] and d["hooks"]["PreToolUse"][1]["matcher"]=="*"'; ok "C3 old Bash-matcher group replaced by ours at the end" $?
pyx older-agentdeck.json 'd["hooks"]["Stop"][0]["hooks"]==o["hooks"]["Stop"][0]["hooks"][:1] and len(d["hooks"]["Stop"])==2'; ok "C4 mixed group keeps its foreign hook, loses the old AgentDeck one" $?
$PY uninstall --settings "$S" 2>/dev/null; jeq "$S" "$FXD/older-agentdeck-clean.json"; ok "C5 uninstall leaves only the foreign hooks" $?

# D. refusals leave the file untouched
for f in invalid.json hooks-array.json; do fresh $f; $PY install --settings "$S" 2>/dev/null; R=$?
  [ $R = 2 ] && cmp -s "$S" "$FXD/$f" && [ "$(nb)" = 0 ]; ok "D $f: exit 2, unchanged, no backup" $?; done
fresh invalid.json; $PY uninstall --settings "$S" 2>/dev/null; [ $? = 2 ] && cmp -s "$S" "$FXD/invalid.json"; ok "D3 uninstall on invalid JSON: exit 2, unchanged" $?

# E. custom prefix must carry the ownership marker
fresh empty-object.json; $PY install --settings "$S" --hook-cmd-prefix /opt/x/.agentdeck/bin/adeck-hook 2>/dev/null
pyx empty-object.json 'd["hooks"]["Stop"][0]["hooks"][0]["command"]=="/opt/x/.agentdeck/bin/adeck-hook event Stop"'; ok "E1 custom prefix used" $?
fresh empty-object.json; $PY install --settings "$S" --hook-cmd-prefix /opt/x/bin/hook 2>/dev/null; [ $? = 2 ] && cmp -s "$S" "$FXD/empty-object.json"; ok "E2 prefix without marker: exit 2, unchanged" $?

# hooks.3 runs a copy of the repo so config/capabilities.json can be a fixture (config/ belongs to the Swift part)
R="$W/repo"; mkdir -p "$R/installer" "$R/hooks" "$R/config"
cp "$ROOT/installer/"*.sh "$ROOT/installer/adeck_settings.py" "$R/installer/"; cp "$ROOT/hooks/adeck-hook" "$R/hooks/"; cp "$FXD/capabilities.json" "$R/config/"
# hooks.3: scripts under a temp HOME only
H2="$W/h2"; mkdir -p "$H2/Library/Application Support/Cursor/User"
CUR="$H2/Library/Application Support/Cursor/User/settings.json"; echo '{"a":1}' > "$CUR"; cp "$CUR" "$W/cursor.orig"
SUP2="$H2/Library/Application Support/AgentDeck"
env -i PATH="$PATH" /bin/sh "$R/installer/install.sh" >/dev/null 2>&1; [ $? -ne 0 ]; ok "F1 install refuses unset HOME" $?
env -i PATH="$PATH" /bin/sh "$R/installer/uninstall.sh" >/dev/null 2>&1; [ $? -ne 0 ]; ok "F2 uninstall refuses unset HOME" $?
env -i PATH="$PATH" HOME="" /bin/sh "$R/installer/install.sh" >/dev/null 2>&1; [ $? -ne 0 ]; ok "F3 install refuses empty HOME" $?
env -i PATH="$PATH" HOME="$H2" /bin/sh "$R/installer/install.sh" >/dev/null 2>&1; ok "F4 install runs" $?
[ "$(stat -f %Lp "$H2/.agentdeck/bin/adeck-hook")" = 755 ] && cmp -s "$H2/.agentdeck/bin/adeck-hook" "$R/hooks/adeck-hook"; ok "F5 hook copied, mode 0755" $?
[ "$(stat -f %Lp "$SUP2")" = 700 ]; ok "F6 support dir 0700" $?
cmp -s "$SUP2/capabilities.json" "$R/config/capabilities.json"; ok "F7 capabilities copied" $?
echo '{"version":1,"marker":"keep"}' > "$SUP2/capabilities.json"
I1=$(stat -f %i "$H2/.agentdeck/bin/adeck-hook")
env -i PATH="$PATH" HOME="$H2" /bin/sh "$R/installer/install.sh" >/dev/null 2>&1; grep -q keep "$SUP2/capabilities.json"; ok "F8 existing capabilities.json not overwritten" $?
[ "$(stat -f %i "$H2/.agentdeck/bin/adeck-hook")" != "$I1" ] && [ -x "$H2/.agentdeck/bin/adeck-hook" ] && ! ls "$H2/.agentdeck/bin/" | grep -q 'adeck-hook\.'; ok "F14 reinstall replaces the hook atomically (new inode, no temp left)" $?
[ "$(grep -o '/.agentdeck/bin/adeck-hook\|~/.agentdeck/bin/adeck-hook' "$H2/.claude/settings.json" | wc -l | tr -d ' ')" = 12 ]; ok "F9 12 entries in settings.json, not 24 after two installs" $?
grep -q 'adeck-hook" event SessionStart' "$R/installer/install.sh"; ok "F10 install runs the hook once (first-exec scan)" $?
env -i PATH="$PATH" HOME="$H2" /bin/sh "$R/installer/uninstall.sh" >/dev/null 2>&1
[ -f "$H2/.agentdeck/bin/adeck-hook" ] && ! grep -q adeck-hook "$H2/.claude/settings.json" && [ -d "$SUP2" ]; ok "F11 uninstall removes entries only" $?
env -i PATH="$PATH" HOME="$H2" /bin/sh "$R/installer/uninstall.sh" --purge >/dev/null 2>&1
[ ! -e "$H2/.agentdeck" ] && [ ! -e "$SUP2" ]; ok "F12 --purge removes ~/.agentdeck and the support dir" $?
cmp -s "$CUR" "$W/cursor.orig"; ok "F13 Cursor settings untouched" $?

[ $FAILS = 0 ] && echo "ALL GREEN" || { echo "$FAILS FAILED"; exit 1; }
