---
name: agentdeck-phone-approvals
description: Guide a user through setting up, testing, troubleshooting or removing AgentDeck's optional phone approvals (Slack DM with reaction taps for Claude Code permission requests). Use when the user says "set up phone approvals", asks to approve Claude Code actions from their phone or Slack, or asks about addons/phone-approvals.
---

# AgentDeck phone approvals: guided setup

Files live in `addons/phone-approvals/` (README.md explains the feature, safety rules and privacy). Work step by step and wait for the user at each step.

## Hard rules

- NEVER read, print, echo or paste the Slack token. Never ask the user to paste it (or the member id) into chat. Never read `~/.claude` secrets or query the keychain yourself.
- Credentials go only into the user's own Keychain prompts—never chat, files, screenshots or command arguments.
- Do not edit `~/.claude/settings.json` by hand; only `install.py` does that, and only after an explicit "yes" from the user.
- No Slack, no problem: the feature is optional and changes nothing until installed.

## Steps

1. **Explain and ask first.** One short paragraph: eligible read-only file requests can also arrive as a Slack DM from the user's own bot; they tap a reaction (allow once, allow plus note, deny, decide on laptop) or reply in the thread to deny with guidance. First answer wins among the Cursor dialog, the AgentDeck panel and Slack. Only a short redacted path or search pattern goes to their own DM; every shell command, write, destructive, production, secret and MCP action stays on the laptop; it only allows once. A personal workspace is recommended. Ask: "Do you want this?" Stop if no.
2. **Check AgentDeck is 0.3.0 or newer** (About window). Older builds cannot release their hold, so Claude Code would wait for both.
3. **Create the Slack app.** Explain that this creates an app in their chosen workspace and ask for separate consent before proceeding. Then: api.slack.com/apps > Create New App > From a manifest > pick the workspace > JSON tab > paste the contents of `addons/phone-approvals/slack-app-manifest.json` > Create. Then Install App (OAuth & Permissions) > Install to Workspace > Allow.
4. **Get the two values yourself in the browser:** the Bot User OAuth Token (OAuth & Permissions, starts with `xoxb-`) and your member ID (Slack profile > three dots > Copy member ID).
5. **Tell the USER to run these two commands in their own Terminal** (each prompts for the value; do not run them for them):
   `security add-generic-password -a "$USER" -s claude-approval-slack-token -w`
   `security add-generic-password -a "$USER" -s claude-approval-slack-user -w`
   If an item already exists, add `-U`. Ask them to reply only "done".
6. **Dry run:** `python3 addons/phone-approvals/install.py --dry-run`. Show the diff and explain it adds exactly two entries. Ask for explicit OK, then run `python3 addons/phone-approvals/install.py`.
7. **Self-test:** explain that this sends one harmless Slack DM and ask for consent before running `/usr/bin/python3 -I ~/.claude/hooks/phone_approve/phone_approve.py --selftest`; then ask them to tap a reaction on their phone. It prints only the outcome. Success = "allow-once tapped" or "deny tapped".
8. **Finish:** restart Claude Code tabs and relaunch AgentDeck.

## Uninstall

`python3 addons/phone-approvals/install.py --uninstall` (use `--dry-run` first). Removes only its own two entries. Keychain items can be deleted with `security delete-generic-password -s claude-approval-slack-token` and `-s claude-approval-slack-user`; the user runs those.

## Troubleshooting

- Self-test says keychain items missing: step 5 was not completed or the service names differ.
- Self-test fails: wrong token, app not installed to the workspace, a missing scope (re-create from the manifest), or wrong member ID.
- No DM for a request: destructive/prod/secret/MCP actions are intentionally not forwarded; answer those on the laptop.
- Claude Code seems to wait on the laptop after a phone tap: Claude Code waits for ALL permission hooks, so AgentDeck must be 0.3.0 or newer.
- `~/.claude/hooks/phone_approve/hook.log` holds timing and outcomes only (no commands); use it to see start/done times.
- Deny-with-note: a thread reply denies this exact action and passes the text to Claude as guidance, so it continues differently rather than stopping. The memo reaction allows once and delivers the note after the tool runs.
