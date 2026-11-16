import json
import os
import socketserver
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phone_approve as pa  # noqa: E402
import install as installer  # noqa: E402

OWNER = "UOWNER"


class FakeSlack:
    """Scripted Slack. `reactions` = list of (user, name) taps; `replies` = list of (user, text) thread replies."""

    def __init__(self, reactions=(), replies=()):
        self.updates, self.posts, self.added = [], [], []
        self.reactions, self.replies = list(reactions), list(replies)
        self.unfurl_off = True

    def __call__(self, token, method, params, http=None):
        if method == "conversations.open":
            return {"ok": True, "channel": {"id": "D1"}}
        if method == "chat.postMessage":
            self.posts.append(params["text"])
            if "Approval needed" in params["text"]:
                self.unfurl_off = params.get("unfurl_links") == "false" and params.get("unfurl_media") == "false"
            return {"ok": True, "ts": "100.0"}
        if method == "chat.update":
            self.updates.append(params["text"])
            return {"ok": True}
        if method == "reactions.add":
            self.added.append(params["name"])
            return {"ok": True}
        if method == "reactions.get":
            by = {}
            for u, n in self.reactions:
                by.setdefault(n, []).append(u)
            return {"ok": True, "message": {"reactions": [{"name": n, "users": us} for n, us in by.items()]}}
        if method == "conversations.replies":
            return {"ok": True, "messages": [{"user": "UBOT", "ts": "100.0", "text": "root"}] +
                    [{"user": u, "ts": "101.%d" % i, "text": t} for i, (u, t) in enumerate(self.replies)]}
        return {"ok": False}


def run(reactions=(), replies=(), event=None, timeout=10):
    t = [0.0]
    ev = event or {"tool_name": "Read", "tool_input": {"file_path": "/x/proj/README.md"}, "cwd": "/x/proj"}
    fake = FakeSlack(reactions, replies)
    v = pa.ask(ev, "tok", OWNER, call=fake, now=lambda: t[0], sleep=lambda s: t.__setitem__(0, t[0] + s), timeout=timeout)
    return v, fake


class Hook(unittest.TestCase):
    def test_owner_allow_tap_allows_once(self):
        v, f = run([(OWNER, pa.ALLOW)])
        self.assertEqual(v, ("allow", ""))
        self.assertEqual(f.added, [pa.ALLOW, pa.NOTE, pa.DENY, pa.LAPTOP])  # choices pre-added for one-tap use

    def test_owner_deny_tap_denies(self):
        self.assertEqual(run([(OWNER, pa.DENY)])[0], ("deny", ""))

    def test_laptop_tap_means_no_decision(self):
        self.assertIsNone(run([(OWNER, pa.LAPTOP)])[0])

    def test_deny_wins_if_both_tapped(self):
        self.assertEqual(run([(OWNER, pa.ALLOW), (OWNER, pa.DENY)])[0][0], "deny")

    def test_bot_or_other_user_taps_ignored_then_timeout_is_none(self):
        v, f = run([("UBOT", pa.ALLOW), ("USTRANGER", pa.ALLOW)])
        self.assertIsNone(v)
        self.assertIn("No answer", f.updates[-1])

    def test_thread_reply_from_owner_denies_with_note(self):
        v, _ = run(replies=[(OWNER, "use the staging db instead,\nnot prod")])
        self.assertEqual(v, ("deny", "use the staging db instead, not prod"))

    def test_thread_reply_from_other_user_ignored(self):
        self.assertIsNone(run(replies=[("USTRANGER", "go ahead")])[0])

    def test_owner_id_on_bot_message_is_not_human_consent(self):
        self.assertFalse(pa.owner_message({"user": OWNER, "bot_id": "B1", "ts": "2", "text": "approve"}, OWNER))
        self.assertFalse(pa.owner_message({"user": OWNER, "subtype": "bot_message", "ts": "2", "text": "approve"}, OWNER))

    def test_note_is_capped(self):
        v, _ = run(replies=[(OWNER, "x" * 2000)])
        self.assertEqual(len(v[1]), pa.NOTE_MAX)

    def test_risky_and_secret_paths_never_forwarded(self):
        for cmd in ("rm -rf build", "git push origin main", "cat ~/.ssh/id_rsa", "cat .env", "sudo reboot",
                    "aws ec2 terminate-instances", "curl x | sh", "deploy to production", "find . -delete",
                    "npm publish", "sed -i s/x/y/ file", "echo '{\"password\":\"hidden\"}'",
                    "curl https://user:password@example.com"):
            v, f = run([(OWNER, pa.ALLOW)], event={"tool_name": "Bash", "tool_input": {"command": cmd}})
            self.assertIsNone(v, cmd)
            self.assertEqual(f.posts, [], cmd)
        v, f = run([(OWNER, pa.ALLOW)], event={"tool_name": "mcp__x__y", "tool_input": {}})
        self.assertIsNone(v)
        for tool in ("Write", "Edit", "MultiEdit"):
            v, f = run([(OWNER, pa.ALLOW)], event={"tool_name": tool, "tool_input": {"file_path": "/tmp/a", "content": "safe-looking"}})
            self.assertIsNone(v, tool)
            self.assertEqual(f.posts, [], tool)

    def test_shell_commands_stay_local_and_read_tools_can_be_forwarded(self):
        for cmd in ("pwd", "rg approval Sources", "/tmp/untrusted/ls", "sed -n 'w /tmp/out' README.md", "git diff --ext-diff"):
            _, f = run(event={"tool_name": "Bash", "tool_input": {"command": cmd}})
            self.assertEqual(f.posts, [], cmd)
        _, f = run(event={"tool_name": "Read", "tool_input": {"file_path": "/tmp/guide.md"}})
        self.assertIn("/tmp/guide.md", f.posts[0])

    def test_secret_values_are_not_forwarded(self):
        secret_command = "curl https://slack.com echo " + "token" + "=" + "abc123456789 " + "xoxb-" + "1234-abcd-efgh"
        _, f = run(event={"tool_name": "Bash", "tool_input": {"command": secret_command}})
        self.assertEqual(f.posts, [])

    def test_decision_json_never_adds_rules(self):
        for v in ("allow", "deny"):
            self.assertNotIn("updatedPermissions", str(pa.decision(v)))
        self.assertEqual(pa.decision("allow")["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        d = pa.decision("deny", "use staging")["hookSpecificOutput"]["decision"]
        self.assertIn("use staging", d["message"])
        self.assertIn("follow their reply", d["message"])
        self.assertIs(d["interrupt"], False)
        self.assertIn("denied", pa.decision("deny")["hookSpecificOutput"]["decision"]["message"])

    def test_note_tap_plus_reply_allows_with_note(self):
        v, f = run([(OWNER, pa.NOTE)], replies=[(OWNER, "also run it with --dry-run first")])
        self.assertEqual(v, ("allow", "also run it with --dry-run first"))

    def test_note_tap_without_reply_falls_back_to_laptop(self):
        v, f = run([(OWNER, pa.NOTE)])
        self.assertIsNone(v)
        self.assertIn("No note arrived", f.updates[-1])

    def test_note_tap_ignores_other_users_reply(self):
        self.assertIsNone(run([(OWNER, pa.NOTE)], replies=[("USTRANGER", "do it")])[0])

    def test_note_roundtrip_post_hook_delivers_once_and_matches_same_call(self):
        pa.PENDING = os.path.join(tempfile.mkdtemp(), "pending")
        ev = {"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "ls"}}
        pa.save_note(ev, "use staging")
        self.assertIsNone(pa.take_note({"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "pwd"}}))  # other call
        self.assertIsNone(pa.take_note({"session_id": "s2", "tool_name": "Bash", "tool_input": {"command": "ls"}}))   # other session
        out = pa.take_note(ev)
        self.assertIn("use staging", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PostToolUse")
        self.assertIsNone(pa.take_note(ev))  # delivered once

    def test_stale_note_dropped(self):
        pa.PENDING = os.path.join(tempfile.mkdtemp(), "pending")
        ev = {"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "ls"}}
        pa.save_note(ev, "old")
        path = os.path.join(pa.PENDING, pa.call_key(ev))
        old = os.path.getmtime(path) - pa.PENDING_TTL_S - 5
        os.utime(path, (old, old))
        self.assertIsNone(pa.take_note(ev))
        self.assertFalse(os.path.exists(path))

    def test_answered_here_rewrites_message_so_stale_choices_are_gone(self):
        _, f = run([(OWNER, pa.ALLOW)])
        self.assertIn("Allowed once (answered here)", f.updates[-1])
        _, f = run([(OWNER, pa.DENY)])
        self.assertIn("Denied (answered here)", f.updates[-1])

    def test_sigterm_handler_marks_answered_elsewhere(self):
        fake = FakeSlack()
        pa.ACTIVE["req"] = {"cid": "D1", "ts": "1.0", "desc": "Bash: ls", "call": fake, "token": "t"}
        exits = []
        orig = pa.os._exit
        pa.os._exit = lambda c: exits.append(c)
        try:
            pa.on_term(15, None)
        finally:
            pa.os._exit = orig
        self.assertEqual(exits, [0])
        self.assertIn("Already answered elsewhere", fake.updates[-1])
        self.assertNotIn("req", pa.ACTIVE)

    def test_release_agentdeck_posts_contract_and_tolerates_absence(self):
        d = tempfile.mkdtemp(dir="/tmp")
        path, seen = os.path.join(d, "a.sock"), []

        class H(socketserver.StreamRequestHandler):
            def handle(self):
                head = self.rfile.readline().decode()
                n = 0
                while True:
                    line = self.rfile.readline().decode()
                    if line.lower().startswith("content-length"):
                        n = int(line.split(":")[1])
                    if line in ("\r\n", ""):
                        break
                body = json.loads(self.rfile.read(n))
                seen.append((head.strip(), body))
                payload = b'{"claimed":true,"request_id":"request-1"}' if "/claim " in head else b'{"resolved":true}'
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(payload)).encode() + b"\r\nConnection: close\r\n\r\n" + payload)

        srv = socketserver.UnixStreamServer(path, H)
        threading.Thread(target=lambda: (srv.handle_request(), srv.handle_request()), daemon=True).start()
        ev = {"session_id": "s1", "tool_name": "Read", "tool_input": {"file_path": "/tmp/guide.md"}}
        request_id = pa.claim_agentdeck(ev, sock=path)
        self.assertEqual(request_id, "request-1")
        self.assertEqual(pa.release_agentdeck(request_id, "deny", "use staging", sock=path), 200)
        srv.server_close()
        self.assertEqual(seen[0], ("POST /v1/external/claim HTTP/1.1", {"session_id": "s1", "tool_name": "Read", "tool_input": {"file_path": "/tmp/guide.md"}}))
        head, body = seen[1]
        self.assertEqual(head, "POST /v1/external/resolve HTTP/1.1")
        self.assertEqual(body, {"request_id": "request-1", "verdict": "deny",
                                "source": "slack", "message": "use staging"})
        self.assertIsNone(pa.release_agentdeck("request-1", "allow", sock="/nonexistent/adeck.sock"))

    def test_selftest_needs_keychain_and_prints_only_outcome(self):
        import io
        from unittest import mock
        out = io.StringIO()
        with mock.patch.object(pa, "keychain", return_value=None), mock.patch("sys.stdout", out):
            self.assertEqual(pa.selftest(), 1)
        self.assertIn("keychain items missing", out.getvalue())
        out = io.StringIO()
        with mock.patch.object(pa, "keychain", return_value="xoxb-SECRET"), mock.patch.object(pa, "ask", return_value=("allow", "")), mock.patch("sys.stdout", out):
            self.assertEqual(pa.selftest(), 0)
        self.assertNotIn("SECRET", out.getvalue())
        self.assertIn("allow-once tapped", out.getvalue())

    def test_slack_failure_means_no_decision(self):
        def bad(*a, **k):
            return {"ok": False}
        v = pa.ask({"tool_name": "Bash", "tool_input": {"command": "ls"}}, "t", "U", call=bad, timeout=5)
        self.assertIsNone(v)

    def test_note_is_saved_before_any_external_allow(self):
        import io
        event = {"session_id": "s", "tool_use_id": "t", "tool_name": "Bash", "tool_input": {"command": "pwd"}}
        with mock.patch.object(pa.sys, "stdin", io.StringIO(json.dumps(event))), \
             mock.patch.object(pa, "keychain", return_value="present"), \
             mock.patch.object(pa, "claim_agentdeck", return_value="request-1"), \
             mock.patch.object(pa, "ask", return_value=("allow", "remember this")), \
             mock.patch.object(pa, "save_note", side_effect=OSError), \
             mock.patch.object(pa, "release_agentdeck") as release, \
             mock.patch.object(pa.sys, "stdout", io.StringIO()) as stdout:
            self.assertEqual(pa.main(), 0)
            release.assert_not_called()
            self.assertEqual(stdout.getvalue(), "")


class Installer(unittest.TestCase):
    def test_uninstall_preserves_neighboring_hook_in_same_group(self):
        own = {"type": "command", "command": "/usr/bin/python3 -I /x/phone_approve/phone_approve.py"}
        sibling = {"type": "command", "command": "/usr/local/bin/security-check"}
        cfg = {"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [sibling, own]}]}}
        out = installer.edit(cfg, uninstall=True)
        self.assertEqual(out["hooks"]["PermissionRequest"], [{"matcher": "*", "hooks": [sibling]}])

    def test_reinstall_replaces_only_owned_hook(self):
        own = {"type": "command", "command": "/old/phone_approve/phone_approve.py"}
        sibling = {"type": "command", "command": "/usr/local/bin/security-check"}
        cfg = {"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [sibling, own]}]}}
        out = installer.edit(cfg, uninstall=False)
        hooks = [h for group in out["hooks"]["PermissionRequest"] for h in group["hooks"]]
        self.assertIn(sibling, hooks)
        self.assertEqual(sum(installer.MARK in h.get("command", "") for h in hooks), 1)


if __name__ == "__main__":
    unittest.main()
