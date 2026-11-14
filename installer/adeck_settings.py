"""Merge/unmerge AgentDeck hook entries in a Claude Code settings.json (protocol section 7)."""
import argparse, json, os, shutil, sys, tempfile, time

MARKER = "/.agentdeck/bin/adeck-hook"
DEFAULT_PREFIX = "~/.agentdeck/bin/adeck-hook"
SYNC = {"PermissionRequest": "decide", "PreToolUse": "gate"}
MATCHED = {"PermissionRequest", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"}
EVENTS = ["PermissionRequest", "PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit",
          "PermissionDenied", "Stop", "SubagentStart", "SubagentStop", "Notification", "SessionStart", "SessionEnd"]


def entries(prefix):
    out = {}
    for ev in EVENTS:
        hook = {"type": "command", "command": f"{prefix} {SYNC.get(ev, 'event')} {ev}"}
        if ev in SYNC:
            hook["timeout"] = 600
        else:
            hook["async"] = True
        group = {"matcher": "*", "hooks": [hook]} if ev in MATCHED else {"hooks": [hook]}
        out[ev] = group
    return out


def _ours(h):
    return isinstance(h, dict) and MARKER in str(h.get("command", ""))


def strip(settings):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return settings
    removed = False
    for ev in list(hooks):
        groups = hooks[ev]
        if not isinstance(groups, list):
            continue
        kept, touched = [], False
        for g in groups:
            hs = g.get("hooks") if isinstance(g, dict) else None
            if isinstance(hs, list) and any(_ours(h) for h in hs):
                touched = True
                g = {**g, "hooks": [h for h in hs if not _ours(h)]}
                if not g["hooks"]:
                    continue
            kept.append(g)
        if touched:
            removed = True
            if kept:
                hooks[ev] = kept
            else:
                del hooks[ev]
    if removed and not hooks:
        del settings["hooks"]
    return settings


def merge(settings, prefix):
    strip(settings)
    hooks = settings.setdefault("hooks", {})
    for ev, group in entries(prefix).items():
        hooks.setdefault(ev, []).append(group)
    return settings


def _foreign_pretooluse(settings):
    for g in (settings.get("hooks") or {}).get("PreToolUse", []):
        for h in g.get("hooks", []) if isinstance(g, dict) else []:
            if isinstance(h, dict) and not _ours(h):
                yield h.get("command", "")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["install", "uninstall"])
    ap.add_argument("--settings", required=True)
    ap.add_argument("--hook-cmd-prefix", default=DEFAULT_PREFIX)
    a = ap.parse_args(argv)
    if MARKER not in a.hook_cmd_prefix:
        print(f"adeck: hook prefix must contain {MARKER}", file=sys.stderr)
        return 2
    path, exists = a.settings, os.path.exists(a.settings)
    raw = b""
    try:
        if exists:
            raw = open(path, "rb").read()
            data = json.loads(raw.decode("utf-8"))
        else:
            data = {}
    except (OSError, ValueError) as e:
        print(f"adeck: cannot read {path}: {e}", file=sys.stderr)
        return 2
    if not isinstance(data, dict) or ("hooks" in data and not isinstance(data["hooks"], dict)):
        print(f"adeck: {path}: top level and 'hooks' must be JSON objects", file=sys.stderr)
        return 2
    if a.action == "install":
        for cmd in _foreign_pretooluse(data):
            print(f'adeck: PreToolUse hook "{cmd}" may return updatedInput after you approve in AgentDeck (Channel 2)',
                  file=sys.stderr)
        new = merge(data, a.hook_cmd_prefix)
    else:
        if not exists:
            return 0
        new = strip(data)
    text = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
    if exists and text.encode("utf-8") == raw:
        return 0
    if exists:
        base = f"{path}.agentdeck-backup-{time.strftime('%Y%m%d-%H%M%S')}"
        bak, n = base, 0
        while os.path.exists(bak):
            n += 1
            bak = f"{base}.{n}"
        shutil.copy2(path, bak)
    mode = os.stat(path).st_mode & 0o777 if exists else 0o600
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".adeck-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
