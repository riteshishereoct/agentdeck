#!/usr/bin/env python3
"""Install / uninstall the AgentDeck phone-approvals hook. Idempotent; only touches its own two settings entries.

  python3 install.py [--dry-run] [--uninstall]

Copies phone_approve.py to ~/.claude/hooks/phone_approve/, backs up ~/.claude/settings.json (timestamped) and adds one
PermissionRequest and one PostToolUse entry. Existing hooks are never modified. Uses $HOME, so tests can use a temp HOME.
"""
import difflib
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
DEST = os.path.join(HOME, ".claude", "hooks", "phone_approve")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
SCRIPT = os.path.join(DEST, "phone_approve.py")
PY = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
MARK = "phone_approve/phone_approve.py"  # identifies our entries


def entries():
    return {"PermissionRequest": {"matcher": "*", "hooks": [{"type": "command", "command": "%s -I %s" % (PY, SCRIPT), "timeout": 130}]},
            "PostToolUse": {"matcher": "*", "hooks": [{"type": "command", "command": "%s -I %s post" % (PY, SCRIPT), "timeout": 10}]}}


def without_ours(group):
    kept = [h for h in group.get("hooks", []) if MARK not in (h.get("command") or "")]
    return dict(group, hooks=kept) if kept else None


def edit(cfg, uninstall):
    hooks = cfg.setdefault("hooks", {})
    for event, entry in entries().items():
        groups = [kept for group in hooks.get(event, []) if (kept := without_ours(group)) is not None]
        if not uninstall:
            groups.append(entry)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        cfg.pop("hooks", None)
    return cfg


def main(argv):
    dry, un = "--dry-run" in argv, "--uninstall" in argv
    raw = open(SETTINGS).read() if os.path.exists(SETTINGS) else "{}\n"
    cfg = json.loads(raw)
    new = json.dumps(edit(json.loads(raw), un), indent=2, ensure_ascii=False) + "\n"
    old = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    diff = "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), "settings.json (before)", "settings.json (after)"))
    print(diff or "settings.json: no change needed.")
    if dry:
        print("(dry run: nothing written)")
        return 0
    if new != old:
        if os.path.exists(SETTINGS):
            bak = "%s.bak-%s" % (SETTINGS, time.strftime("%Y%m%dT%H%M%S"))
            shutil.copy2(SETTINGS, bak)
            print("backup:", bak)
        os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
        # an untouched file is left byte-for-byte alone; a changed one is rewritten whole
        open(SETTINGS, "w").write(new)
    if un:
        print("Uninstalled the settings entries. The script folder %s was left in place; delete it if you like." % DEST)
    else:
        os.makedirs(DEST, mode=0o700, exist_ok=True)
        shutil.copy2(os.path.join(HERE, "phone_approve.py"), SCRIPT)
        print("Installed. Restart Claude Code tabs, then run: %s -I %s --selftest" % (PY, SCRIPT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
