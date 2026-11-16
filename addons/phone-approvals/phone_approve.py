#!/usr/bin/env python3
"""PermissionRequest hook: ask the owner on Slack (DM from a bot) and relay THEIR answer. Never decides by itself.

Flow: permission dialog would open -> forward a short redacted description to the owner's Slack DM, pre-tapped with three
reaction choices -> owner taps one on their phone: white_check_mark = allow once, x = deny, computer = decide on the laptop.
A reply in the message's thread denies and passes the owner's text to Claude as feedback. Each message is polled by its own
timestamp, so concurrent approvals never mix. No valid answer in time, any error, a missing keychain item, or a
risky/secret-touching action -> print nothing and exit 0, so Claude Code shows its normal local dialog.
Fail closed: this script can only ever return allow-ONCE or deny; it never writes allow rules (no updatedPermissions).

Keychain items (created by the owner, never read by an assistant):
  service claude-approval-slack-token  -> bot token (xoxb-...), scopes chat:write, im:write, im:history, reactions:read, reactions:write
  service claude-approval-slack-user   -> the owner's Slack member id (U...)
"""
import hashlib
import http.client
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

TIMEOUT_S = int(os.environ.get("PHONE_APPROVE_TIMEOUT_S", "110"))  # keep below the hook timeout in settings
POLL_S = 4
ALLOW, NOTE, DENY, LAPTOP = "white_check_mark", "memo", "x", "computer"
NOTE_WAIT_S = 90  # after the note reaction, how long we wait for the thread reply
PENDING_TTL_S = 900
PENDING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pending")
NOTE_MAX = 500
MAX_LEN = 220
REMOTE_TOOLS = {"Read", "Grep", "Glob", "LS"}

# never forwarded: the owner must answer these on the laptop
RISKY = re.compile(
    r"(\brm\s+-[a-z]*[rf]|\bgit\s+(push|reset\s+--hard|clean|branch\s+-D|checkout\s+--)|\bsudo\b|\bdd\s+if=|\bmkfs|\bchmod\s+-R|"
    r"\bdrop\s+(table|database)|\bTRUNCATE\b|\bdelete(Many|One)\b|\bkubectl\s+delete|\baws\s+\w+\s+(delete|terminate|rm)|"
    r"\bprod(uction)?\b|--force|\|\s*(ba|z)?sh\b|curl[^|]*\|\s*(ba|z)?sh|\bkill\s+-9\b|launchctl\s+(unload|bootout|remove))",
    re.I)
SECRETISH_PATH = re.compile(r"(\.env\b|\.pem\b|\.key\b|id_rsa|id_ed25519|\bjwt/|credentials|\.aws/|\.ssh/|keychain|secrets?\b)", re.I)
SECRET_VALUE = re.compile(r"(xox[abprs]-[\w-]+|sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|"
                          r"eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{5,}|(?i:bearer)\s+[\w.-]{16,}|(?i:(password|passwd|token|secret|api[_-]?key))\s*[=:]\s*\S+)")
SECRET_ASSIGNMENT = re.compile(r'''(?i)["']?(password|passwd|token|secret|api[_-]?key)["']?\s*[:=]\s*["']?[^\s,"']+''')
URL_USERINFO = re.compile(r"https?://[^\s/:@]+:[^\s/@]+@", re.I)


def describe(event):
    """(text, forwardable). Text is redacted and short; forwardable False = ask on the laptop instead."""
    name = event.get("tool_name", "?")
    inp = event.get("tool_input") or {}
    if name == "Selftest":
        return "Selftest: AgentDeck phone-approval self-test", True
    if name == "Bash":
        return "Bash: laptop review required", False
    if name not in REMOTE_TOOLS:
        return "%s: laptop review required" % name, False
    fields = [str(inp.get(key)) for key in ("file_path", "path", "pattern") if inp.get(key)]
    raw = " | ".join(fields)
    safe = bool(raw) and len(raw) <= MAX_LEN and not (RISKY.search(raw) or SECRETISH_PATH.search(raw) or SECRET_VALUE.search(raw) or SECRET_ASSIGNMENT.search(raw) or URL_USERINFO.search(raw))
    return ("%s: %s" % (name, raw), True) if safe else ("%s: laptop review required" % name, False)


def keychain(service):
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", service, "-w"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def slack(token, method, params, http=None):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request("https://slack.com/api/" + method, data, {"Authorization": "Bearer " + token})
    with (http or urllib.request.urlopen)(req, timeout=10) as r:
        return json.load(r)


ACTIVE = {}  # the one request this process is waiting on, so a SIGTERM (answered elsewhere) can update the Slack message


def settle(call, token, status):
    """Rewrite the original Slack message so stale buttons are not left looking actionable. Never raises."""
    a = ACTIVE.pop("req", None)
    if not a:
        return
    try:
        call(token, "chat.update", {"channel": a["cid"], "ts": a["ts"], "text": "%s\n`%s`" % (status, a["desc"]), "unfurl_links": "false"})
    except Exception:  # noqa: BLE001
        pass


def on_term(signum, frame):
    """Claude Code stops hooks once another channel (dialog / AgentDeck) has answered: say so and leave quietly."""
    a = ACTIVE.get("req")
    if a:
        settle(a["call"], a["token"], ":information_source: Already answered elsewhere (Cursor or AgentDeck). No action needed.")
    log("stopped: answered elsewhere")
    os._exit(0)


def owner_choice(reactions, user):
    """First owner-tapped choice among our three reactions (deny wins ties), else None."""
    tapped = {r.get("name") for r in reactions or [] if user in (r.get("users") or [])}
    for name, verdict in ((DENY, "deny"), (LAPTOP, "laptop"), (NOTE, "note"), (ALLOW, "allow")):
        if name in tapped:
            return verdict
    return None


def owner_message(message, user):
    return (message.get("user") == user and not message.get("bot_id") and not message.get("app_id")
            and not message.get("subtype") and message.get("text") and message.get("ts"))


def ask(event, token, user, call=slack, now=time.time, sleep=time.sleep, timeout=TIMEOUT_S):
    """Returns ('allow'|'deny'|'laptop', note) or None. None/laptop = no decision: the normal local dialog shows."""
    text, ok = describe(event)
    if not ok:
        return None
    ch = call(token, "conversations.open", {"users": user})
    if not ch.get("ok"):
        return None
    cid = ch["channel"]["id"]
    msg = call(token, "chat.postMessage", {"channel": cid, "unfurl_links": "false", "unfurl_media": "false", "text":
               "*Approval needed* (%s)\n`%s`\nTap :white_check_mark: allow once  .  :x: deny  .  :computer: decide on laptop.\n"
               "Or reply in this thread to deny with a note for Claude. Expires in %ds." %
               (os.path.basename(event.get("cwd", "") or "?"), text, timeout)})
    if not msg.get("ok"):
        return None
    ts, end = msg["ts"], now() + timeout
    ACTIVE["req"] = {"cid": cid, "ts": ts, "desc": text, "call": call, "token": token}
    for name in (ALLOW, NOTE, DENY, LAPTOP):  # pre-add the choices so one tap is enough
        call(token, "reactions.add", {"channel": cid, "timestamp": ts, "name": name})
    while now() < end:
        sleep(POLL_S)
        r = call(token, "reactions.get", {"channel": cid, "timestamp": ts})
        verdict = owner_choice(((r.get("message") or {}).get("reactions")), user) if r.get("ok") else None
        if verdict == "note":  # approved, but wait for the owner's thread reply and hand it to Claude afterwards
            call(token, "chat.postMessage", {"channel": cid, "thread_ts": ts, "text": "Allowed once. Reply here with your note for Claude (%ds)." % NOTE_WAIT_S})
            stop = now() + NOTE_WAIT_S
            while now() < stop:
                sleep(POLL_S)
                r = call(token, "reactions.get", {"channel": cid, "timestamp": ts})
                override = owner_choice(((r.get("message") or {}).get("reactions")), user) if r.get("ok") else None
                if override in ("deny", "laptop"):
                    settle(call, token, ":x: Denied (answered here)" if override == "deny" else ":computer: Left for the laptop")
                    return ("deny", "") if override == "deny" else None
                for m in call(token, "conversations.replies", {"channel": cid, "ts": ts, "limit": 30}).get("messages", []):
                    if owner_message(m, user) and m.get("ts") != ts and "Allowed once." not in m["text"]:
                        settle(call, token, ":white_check_mark: Allowed once, with your note (answered here)")
                        return ("allow", re.sub(r"\s+", " ", m["text"]).strip()[:NOTE_MAX])
            settle(call, token, ":computer: No note arrived: decide on the laptop")
            return None
        if verdict:
            settle(call, token, {"allow": ":white_check_mark: Allowed once (answered here)", "deny": ":x: Denied (answered here)",
                                 "laptop": ":computer: Left for the laptop"}[verdict])
            return (verdict, "") if verdict != "laptop" else None
        h = call(token, "conversations.replies", {"channel": cid, "ts": ts, "limit": 20})
        for m in h.get("messages", []):
            if owner_message(m, user) and m.get("ts") != ts:  # only the owner's own human replies count
                note = re.sub(r"\s+", " ", m["text"]).strip()[:NOTE_MAX]
                settle(call, token, ":x: Denied with your note (answered here)")
                return ("deny", note)
    settle(call, token, ":hourglass: No answer: decide on the laptop")
    return None


def decision(verdict, note=""):
    if verdict == "allow":
        d = {"behavior": "allow"}
    elif note:  # a thread reply means "not this way, do it my way": the note is guidance for Claude, not a hard stop
        d = {"behavior": "deny", "interrupt": False, "message":
             "The user did not approve this exact action. They replied from their phone: \"%s\". "
             "Do not retry the same action; follow their reply and continue the task." % note}
    else:
        d = {"behavior": "deny", "interrupt": False, "message": "The user denied this action from their phone. Do not retry it; choose a different approach or ask them."}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": d}}  # no updatedPermissions, ever


def call_key(event):
    raw = "%s|%s|%s" % (event.get("session_id", ""), event.get("tool_name", ""), json.dumps(event.get("tool_input") or {}, sort_keys=True))
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def save_note(event, note, now=time.time):
    """The allow decision cannot carry text to Claude, so the note waits for the PostToolUse hook of the same call."""
    os.makedirs(PENDING, mode=0o700, exist_ok=True)
    with open(os.path.join(PENDING, call_key(event)), "w") as f:
        json.dump({"note": note, "at": now()}, f)


def take_note(event, now=time.time):
    """PostToolUse side: returns the hook JSON carrying the owner's note, or None. Deletes the file; drops stale ones."""
    if not os.path.isdir(PENDING):
        return None
    for name in os.listdir(PENDING):
        try:
            if now() - os.path.getmtime(os.path.join(PENDING, name)) > PENDING_TTL_S:
                os.remove(os.path.join(PENDING, name))
        except OSError:
            pass
    path = os.path.join(PENDING, call_key(event))
    try:
        with open(path) as f:
            note = json.load(f)["note"]
        os.remove(path)
    except (OSError, ValueError, KeyError):
        return None
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext":
            "The user approved this action from their phone and added this note: \"%s\". Take it into account for what you do next." % note}}


def post_main():
    try:
        out = take_note(json.load(sys.stdin))
    except Exception:  # noqa: BLE001 - never disturb the tool result
        return 0
    if out:
        print(json.dumps(out))
    return 0


ADECK_SOCK = os.path.expanduser("~/Library/Application Support/AgentDeck/adeck.sock")


class _UnixConn(http.client.HTTPConnection):
    def __init__(self, path, timeout=3):
        super().__init__("adeck", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def agentdeck_post(path, body, sock=ADECK_SOCK):
    if not os.path.exists(sock):
        return None, None
    try:
        c = _UnixConn(sock)
        c.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})
        response = c.getresponse()
        data = json.loads(response.read() or b"{}")
        c.close()
        return response.status, data
    except (OSError, ValueError, http.client.HTTPException):
        return None, None


def claim_agentdeck(event, sock=ADECK_SOCK):
    body = {"session_id": event.get("session_id", ""), "tool_name": event.get("tool_name", ""),
            "tool_input": event.get("tool_input") or {}}
    code, data = agentdeck_post("/v1/external/claim", body, sock)
    return data.get("request_id") if code == 200 and data else None


def release_agentdeck(request_id, verdict, message="", sock=ADECK_SOCK):
    """Race: our answer arrived first, so ask AgentDeck to drop its hold on the same request (allow-once/deny only).
    Best effort: AgentDeck absent / older build / no matching hold all just mean nothing to release."""
    body = {"request_id": request_id, "verdict": verdict, "source": "slack"}
    if message:
        body["message"] = message
    return agentdeck_post("/v1/external/resolve", body, sock)[0]


LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook.log")


def log(*parts):
    """Timing/outcome only (never commands): lets us see when our answer was produced versus when Claude Code moved on."""
    try:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), " ".join(str(p) for p in parts)))
    except OSError:
        pass


def main():
    t0 = time.time()
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    try:
        event = json.load(sys.stdin)
        log("start pid=%d tool=%s" % (os.getpid(), event.get("tool_name")))
        token, user = keychain("claude-approval-slack-token"), keychain("claude-approval-slack-user")
        if not (token and user):
            return 0
        request_id = claim_agentdeck(event)
        if not request_id:
            return 0
        res = ask(event, token, user)
    except Exception as e:  # noqa: BLE001 - any failure means the normal local dialog, never an implicit allow
        log("error", type(e).__name__)
        return 0
    log("done verdict=%s after=%.1fs" % (res[0] if res else "none", time.time() - t0))
    if res:
        d = decision(*res)["hookSpecificOutput"]["decision"]
        if res[0] == "allow" and res[1]:
            try:
                save_note(event, res[1])
            except OSError:
                return 0  # cannot deliver the note: let the normal dialog decide
        log("agentdeck-release", release_agentdeck(request_id, res[0], d.get("message", "")))
        print(json.dumps(decision(*res)))
    return 0


def selftest():
    """Send one harmless DM and wait for a tap. Prints only the outcome, never the token or ids."""
    token, user = keychain("claude-approval-slack-token"), keychain("claude-approval-slack-user")
    if not (token and user):
        print("selftest: keychain items missing (claude-approval-slack-token / claude-approval-slack-user)")
        return 1
    try:
        res = ask({"tool_name": "Selftest", "tool_input": {"command": "echo AgentDeck phone-approval selftest"}, "cwd": "selftest"},
                  token, user, timeout=90)
    except Exception as e:  # noqa: BLE001
        print("selftest: failed (%s). Check the token, scopes and member id." % type(e).__name__)
        return 1
    print("selftest outcome: %s" % ({"allow": "allow-once tapped", "deny": "deny tapped (or thread reply)"}.get(res[0]) if res else "no decision (laptop tapped, error or timeout)"))
    return 0 if res else 2


if __name__ == "__main__":
    sys.exit(post_main() if sys.argv[1:] == ["post"] else selftest() if sys.argv[1:] == ["--selftest"] else main())
