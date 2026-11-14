"""Local installation only; never removes the app, user data, or foreign hooks."""
import hashlib
import json
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

VERSION = "2.1.325"
CATEGORIES = {"Bash", "EditWrite", "Web", "MCP", "Question", "ExitPlanMode", "Other"}
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def preflight():
    uid = os.getuid()
    if uid == 0 or os.geteuid() == 0 or any(key in os.environ for key in ("SUDO_USER", "SUDO_UID", "SUDO_GID")):
        raise RuntimeError("Run this command as your regular Mac user, without sudo. No changes made.")
    home = Path(pwd.getpwuid(uid).pw_dir)
    if not home.is_absolute() or not os.environ.get("HOME") or Path(os.environ["HOME"]).resolve() != home.resolve():
        raise RuntimeError("HOME does not match your Mac account home. No changes made.")
    if sys.version_info < (3, 8):
        raise RuntimeError("System /usr/bin/python3 must be functional Python 3.8 or newer.")
    system = subprocess.check_output(["/usr/bin/uname", "-s"], text=True).strip()
    machine = subprocess.check_output(["/usr/bin/uname", "-m"], text=True).strip()
    if system != "Darwin" or machine != "arm64":
        raise RuntimeError("AgentDeck requires an Apple silicon Mac (arm64).")
    version = subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"], text=True).strip()
    if int(version.split(".")[0]) < 14:
        raise RuntimeError("AgentDeck requires macOS 14 or newer.")
    return home


def installed_profile_matches(home):
    folders = list((home / ".cursor/extensions").glob("anthropic.claude-code-*"))
    if len(folders) != 1 or not folders[0].is_dir():
        return False
    try:
        metadata = json.loads((folders[0] / "package.json").read_text())
        return (folders[0].name.startswith("anthropic.claude-code-" + VERSION + "-")
                and metadata.get("version") == VERSION)
    except (OSError, ValueError, AttributeError):
        return False


def backup(home):
    directory = home / ".agentdeck/backups" / (time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    for name, source in [
        ("settings.json", home / ".claude/settings.json"),
        ("capabilities.json", home / "Library/Application Support/AgentDeck/capabilities.json"),
    ]:
        if source.exists():
            shutil.copy2(str(source), str(directory / name))
            (directory / name).chmod(0o600)
    print("Backup: " + str(directory), flush=True)
    return directory


def app_digest(app):
    digest = hashlib.sha256()
    for item in sorted(app.rglob("*")):
        relative = str(item.relative_to(app)).encode()
        if item.is_symlink():
            kind, content = b"link", os.readlink(str(item)).encode()
        elif item.is_file():
            kind, content = b"file", item.read_bytes()
        elif item.is_dir():
            kind, content = b"dir", b""
        else:
            raise RuntimeError("Unsupported app entry: " + str(item))
        for value in (relative, kind, content):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return digest.hexdigest()


def check_signature(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def validate_settings(home):
    settings = home / ".claude/settings.json"
    if not settings.exists():
        return
    data = json.loads(settings.read_text())
    if not isinstance(data, dict) or ("hooks" in data and not isinstance(data["hooks"], dict)):
        raise RuntimeError("Claude settings must contain JSON objects; repair them before installation.")
    for groups in data.get("hooks", {}).values():
        if not isinstance(groups, list) or any(not isinstance(group, dict) for group in groups):
            raise RuntimeError("Claude hook groups must be lists of objects; no settings changed.")


def profile(path, tested=False):
    value = json.loads(path.read_text())
    expected = {category: 3 for category in CATEGORIES}
    if tested:
        expected.update(Bash=1, Question=2)
    if (value.get("version") != 1 or value.get("categories") != expected
            or (tested and value.get("extensionVersion") != VERSION)):
        raise RuntimeError("Unexpected compatibility payload; no settings changed.")
    return value


def write_profile(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".agentdeck-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(action, root):
    home = preflight()
    source = root / "AgentDeck.app"
    target = home / "Applications/AgentDeck.app"
    support = source / "Contents/Resources/AgentDeck"
    capabilities = home / "Library/Application Support/AgentDeck/capabilities.json"
    helper = support / "installer/adeck_settings.py"
    env = dict(os.environ, HOME=str(home), PATH=SYSTEM_PATH)

    if action == "install":
        required = [source / "Contents/MacOS/AgentDeck", helper, support / "installer/install.sh", support / "hooks/adeck-hook"]
        if not all(path.is_file() for path in required):
            raise RuntimeError("Keep this command beside the complete AgentDeck.app payload.")
        profile(support / "config/capabilities.json")  # New installs always start notifications-only.
        validate_settings(home)
        check_signature(source)
        exists = target.exists() or target.is_symlink()
        if exists:
            if target.is_symlink() or not target.is_dir() or app_digest(source) != app_digest(target):
                raise RuntimeError("An existing ~/Applications/AgentDeck.app differs; it was not overwritten. Quit it and move it aside manually first.")
            check_signature(target)
        matches = installed_profile_matches(home)
        print("Starting with notifications only for new installs. Existing capabilities will be preserved.", flush=True)
        if not matches:
            print("Warning: no single installed Claude Code 2.1.325 profile match. Tested controls remain unavailable; other versions are unmeasured.", flush=True)
        backup(home)
        if not exists:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(str(source), str(target), symlinks=True)
        else:
            print("Reusing the identical, signature-verified installed app.", flush=True)
        if capabilities.exists():
            print("Warning: existing capabilities preserved; they may enable controls. Use Reset to notifications.command for notifications-only mode.", flush=True)
        installed_support = target / "Contents/Resources/AgentDeck"
        subprocess.run(["/bin/sh", str(installed_support / "installer/install.sh")], env=env, check=True)
        print("Installed. Restart Cursor to load hooks. Opening AgentDeck through macOS; security approval may be required.", flush=True)
        subprocess.run(["/usr/bin/open", str(target)], check=True)

    elif action == "uninstall":
        print("Quit AgentDeck using its menu before removing hooks. This command preserves the app and all data.", flush=True)
        if not helper.is_file():
            raise RuntimeError("Keep this command beside the complete AgentDeck.app payload.")
        validate_settings(home)
        backup(home)
        subprocess.run(["/usr/bin/python3", "-I", str(helper), "uninstall", "--settings", str(home / ".claude/settings.json")], env=env, check=True)
        print("AgentDeck hook entries removed; foreign settings, app and data preserved. Restart Cursor.", flush=True)

    elif action in ("enable", "reset"):
        if action == "enable":
            if not installed_profile_matches(home):
                raise RuntimeError("Tested controls require exactly one installed anthropic.claude-code-2.1.325-* folder and package.json version 2.1.325. Nothing changed.")
            if not target.is_dir() or not (home / ".agentdeck/bin/adeck-hook").is_file():
                raise RuntimeError("Run Install AgentDeck.command first.")
            value = profile(root / "Compatibility/claude-code-2.1.325.json", tested=True)
            print("Enabling the optional historical 2.1.325 profile. Before launching this command, verify Cursor's active Claude Code version and restart Cursor.", flush=True)
            print("Installed version metadata is NOT runtime enforcement or per-Mac calibration. Reset to notifications BEFORE updating Claude Code.", flush=True)
        else:
            value = profile(root / "Compatibility/notifications-only.json")
        backup(home)
        write_profile(capabilities, value)
        print("Profile saved. Quit and reopen AgentDeck, then restart Cursor. Active held requests were not changed by this command.", flush=True)
        if action == "enable":
            print("Before real work, perform harmless smoke checks: allow creating a temporary test file, deny another with a note, answer a simple question, and confirm the exact session. If anything differs, run Reset to notifications.command.", flush=True)
        else:
            print("Notifications-only mode selected; approval/question controls remain disabled after restart.", flush=True)
    else:
        raise RuntimeError("Unknown action.")


def entrypoint(arguments):
    if len(arguments) != 1:
        raise RuntimeError("Pass one setup action only; the package location is determined automatically.")
    main(arguments[0], Path(__file__).resolve().parent.parent)


if __name__ == "__main__":
    try:
        entrypoint(sys.argv[1:])
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("AgentDeck setup stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
