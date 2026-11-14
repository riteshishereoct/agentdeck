# Hook health and recovery

AgentDeck checks hook delivery without asking Claude to diagnose itself. The flow keeps working when the model is quota-exhausted. It does not resume model work, replay tools, or grant approvals.

## Why the old warning stayed on

Claude Code records all `tool_use` blocks of an assistant message before necessarily starting them. In the recorded lead session, later siblings started their PreToolUse hooks 5–36 seconds after their transcript timestamp. The old detector started a five-second deadline at the transcript `tool_use` timestamp and permanently set a warning. This confused queued work with missing hooks.

The detector now waits until a successful transcript `tool_result` proves the tool actually ran. A matching PreToolUse cancels the suspect. If no matching hook is received within five seconds after the result, the session enters checking. Error results are excluded because validation failures, native denials and interruptions may never start a tool. Prelaunch/history calls are excluded. Matching late hooks resolve their own misses; another session cannot vouch for this one.

## What the row means

- **Checking:** one or more completed calls lacked a matching hook. Some steps or approvals may not have reached Deck.
- **Reconnecting:** AgentDeck repaired its own listener or rearmed its transcript tracking; this is not yet proof that the Claude session is sending hooks.
- **Recovered:** a fresh PreToolUse from that session arrived. The text keeps any unresolved historical miss count visible.
- **Action needed:** the row explains the observed registration/script/version problem or asks for a Claude-tab restart if checks pass but calls continue without hooks.
- **Last hook:** the last confirmed PreToolUse time, never a fabricated heartbeat.

Checks run immediately, then after 5 seconds, 30 seconds and 2 minutes. A resolved or action-required episode has no retry timer. Inactive transcripts read at most once per second even while another session has a timed broker hold; active transcript polling uses the existing core cadence. No additional polling timer is created. A clean but inconclusive check waits for the next real tool event without endless idle retries. Check connection starts another bounded check episode. Recovered does not mean missed history was replayed.

## Supported repairs and limits

Read-only diagnostics inspect our socket, registration for the twelve owned hook events, installed executable and byte equality with the bundled hook, watcher tracking, and known extension version. They never log settings contents. Automatic repairs are limited to relistening on AgentDeck's own socket and rearming its transcript watcher; pending requests retain their original binding.

If the listener cannot be restored, Action needed offers Check connection and explains that AgentDeck may need restarting; a failed listener never produces “checks passed.” An unrelated file occupying the socket path is not overwritten.

Repair hooks is an explicit user action. It runs the existing installer, which backs up and merges only AgentDeck entries while preserving foreign settings. The app bundle must supply `hooks/adeck-hook`, `installer/install.sh`, `installer/adeck_settings.py` and `config/capabilities.json` under `daemon.hookSource`. The installer requires `/bin/sh`, `python3`, and standard macOS command-line utilities. A missing repair source or installer failure returns failure; it never marks the session healthy.

AgentDeck never silently restarts Cursor or a Claude session, modifies macOS privacy permissions, enables model tools, changes capability channels, or answers a real approval. Extension-version comparison is available only for a verified process whose executable path identifies a version. A registered script cannot prove an already-open Claude tab loaded it; if that tab continues without hooks, restart instructions remain necessary. The app currently cannot infer quota exhaustion from an idle resident Cursor process; quiet state remains an observation, not proof of completion.

## Integrator wiring and live checks

Set `daemon.hookSource` before `start()`. Add `HookHealthView(session: session, check: { daemon.checkHookHealth(sessionId: session.id) }, repair: { daemon.repairHooks { ok in /* surface result */ } })` through DeckModel's core forwarding methods. Hide health detail in privacy mode along with other row metadata. Existing `RowDetail.degradedBadge` provides the short badge.

After rebuilding/installing, verify: a deliberately disconnected listener reconnects without changing a held request; missing registration shows an actionable repair; explicit repair preserves foreign entries; only a fresh hook from the same session changes health to recovered; unrelated session activity cannot clear a warning. Verify failure feedback from Repair hooks and confirm no retry work continues after terminal states. Unit/socket tests cover the model and daemon; live macOS/extension checks remain the UI orchestrator's responsibility.
