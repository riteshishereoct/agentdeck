# Phone approvals (optional add-on for AgentDeck 0.3.0+)

Answer a Claude Code permission request from your phone: the request arrives as a Slack DM from a bot in your own workspace, and you tap a reaction.

**No Slack? Nothing changes.** This add-on is not installed by AgentDeck. Until you install it and create the two keychain items below, AgentDeck and Claude Code behave exactly as before. If the keychain items are missing, the hook prints nothing and exits, and the normal dialog and AgentDeck panel are used.

Prerequisites: macOS, Python 3, Claude Code, AgentDeck 0.3.0+, and permission to install a Slack app in a workspace you control.

## What it does

When Claude Code asks for permission, three channels race: the Cursor dialog, the AgentDeck panel, and this Slack DM. **The first answer wins**; the others show "already answered" (the DM is rewritten, and AgentDeck releases the exact claimed hold through the local `claim`/`resolve` contract in protocol section 2.2.1).

Reactions on the DM (pre-added so one tap is enough):

| Reaction | Meaning |
|---|---|
| white_check_mark | Allow once |
| memo | Allow once, then reply in the thread; your text is passed to Claude as a note after the tool runs |
| x | Deny |
| computer | Decide on the laptop (no answer is given from Slack) |

A reply in the DM thread (no reaction) denies and gives Claude your text as guidance ("not this way, do it like this").

## Safety rules

- Allow-once or deny only. It never writes allow rules or permission updates.
- Only dedicated read-only file actions (`Read`, `Grep`, `Glob`, and `LS`) are eligible. Every shell command, plus writes, edits, publishing, destructive, production, secret-touching, MCP and unrecognized actions, stays on the laptop.
- Fail closed: no answer in time (about 110 s), any error, or missing setup means the normal local dialog decides. Silence is never approval.
- Only reactions and replies from your own Slack member id count. Bots and other users are ignored.
- Requires AgentDeck 0.3.0 or newer (Claude Code waits for ALL permission hooks; older builds cannot be released when you answer on the phone).

## Privacy

Only an allowlisted read-only tool name plus its complete short path or search pattern (at most 220 characters) leaves the machine, and only to your own Slack DM. Shell commands are never sent. Secret-looking or longer values are not sent at all. Links are not unfurled. `hook.log` next to the script records timing and outcomes only, never action details. A personal Slack workspace is recommended over a company one.

## Setup (summary; ask Claude Code to do it: open this repo and say "set up phone approvals")

1. Create the Slack app from `slack-app-manifest.json` (api.slack.com/apps > Create New App > From a manifest > JSON). It has bot scopes chat:write, im:write, im:history, reactions:read, reactions:write, the Messages tab on, no event subscriptions, no socket mode, no distribution. Install it to your workspace.
2. Store the bot token and your member id in the macOS keychain. Run these yourself in Terminal; each prompts for the value, so it never appears in chat, files, screenshots, command arguments or shell history:

   ```
   security add-generic-password -a "$USER" -s claude-approval-slack-token -w
   security add-generic-password -a "$USER" -s claude-approval-slack-user -w
   ```
   The token starts with `xoxb-`; the member id is in Slack under your profile > More > Copy member ID.
3. `python3 install.py --dry-run`, review the diff, then `python3 install.py`. It copies the script to `~/.claude/hooks/phone_approve/`, backs up `~/.claude/settings.json` with a timestamp, and adds one PermissionRequest and one PostToolUse entry without touching other hooks. Safe to re-run.
4. `/usr/bin/python3 -I ~/.claude/hooks/phone_approve/phone_approve.py --selftest` sends one harmless DM; tap a reaction; only the outcome is printed.
5. Restart Claude Code tabs and relaunch AgentDeck (0.3.0+).

Uninstall: `python3 install.py --uninstall` removes only its own commands and preserves neighboring hooks (the script folder stays; delete it if you wish). Optionally run both `security delete-generic-password -s claude-approval-slack-token` and `security delete-generic-password -s claude-approval-slack-user`, then revoke or delete the Slack app.

## Tests

`python3 -I -W ignore -m unittest discover` in this folder (stdlib only, no network).
