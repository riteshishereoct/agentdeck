# AgentDeck: a floating supervisor for Claude Code sessions in Cursor

Status: draft for review · 2026-11-13 · working name "AgentDeck" (rename freely)

## 1. Why

You run several Claude Code sessions at once in Cursor: multiple extension tabs, and tabs whose session runs subagents. Each one stops for approvals and questions. Outside Cursor, nothing tells you a session is blocked, so you either tab-hop through every session or stay in Cursor and give up the browser and Zoom.

AgentDeck is a small always-on-top card, top-right by default and draggable. It lists every live session with its goal and progress. When a session needs you, the request pops up in the card and you answer it there. Focus never leaves the app you're in.

## 2. Success, goals, non-goals, anti-goals

**Success:** you work in the browser or Zoom for an hour while 3–5 sessions run, and never open Cursor just to find out whether something is blocked.

Goals:
- **G1 See:** every live session across all Cursor windows and tabs, with subagents nested under their parent. Each shows its goal, state, current step, progress (only when real), elapsed time and model.
- **G2 Act:** approve or deny tool requests, and answer questions, from the card. Focus is never stolen.
- **G3 Notice:** a request appears within 1 s and escalates gently if ignored.
- **G4 Place:** the card is draggable, snaps to corners, remembers its position per display, collapses to a pill, and has global hotkeys.
- **G5 Safe by default:** when AgentDeck is off, crashed or hung, Claude Code behaves exactly as it does today (fail-open). Nothing is ever approved that you didn't approve.

Non-goals (v1): replacing Cursor's chat or diff UI; editing code from the card; phone or remote access; Windows and Linux; Cursor's own agent and Codex (adapters come later, §12).

Anti-goals: it would be a failure even if it works technically if it does any of these:
- Steals keyboard focus mid-Zoom or mid-typing.
- Makes approvals less safe: one-click approval of things you can't see, "approve all", or a model deciding for you.
- Adds noticeable latency to every tool call (target: under 25 ms p95).
- Lets the same request be answered twice, or answered with stale input.
- Shows a fake progress bar.

## 3. What we verified (and what we didn't)

| # | Fact | Status | Source |
|---|---|---|---|
| F1 | "Claude in Cursor" here is the Claude Code extension (v2.1.323, bundled CLI). Its native UI receives approvals through the SDK `canUseTool` control protocol. | Verified on this machine | `CLAUDE_CODE_ENTRYPOINT=claude-vscode`; extension.js |
| F2 | A deep link opens a specific session tab: `cursor://anthropic.claude-code/open?session=<id>&prompt=<text>`, which runs `claude-vscode.primaryEditor.open(session, prompt)`. | Verified on this machine | extension.js `handleUri` |
| F3 | The bundled CLI implements PermissionRequest, PermissionDenied, PreToolUse, PostToolUse, PostToolUseFailure, Notification, Stop, SubagentStart/Stop, SessionStart/End, UserPromptSubmit and PreCompact hooks, plus `async` hooks and `disableAllHooks`. | Verified on this machine | strings in the bundled binary |
| F4 | PermissionRequest input = common fields plus `tool_name`, `tool_input`, `permission_suggestions` (and `mcp_server` for MCP tools; there is no `tool_use_id`). Output: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"\|"deny", …}}}`. `updatedInput` and `updatedPermissions` apply to allow only; `message` and `interrupt` apply to deny only. An allow never overrides a deny rule. | Verified (docs and binary) | code.claude.com/docs/en/hooks |
| F5 | Some prompts are **person-only**, for example auto mode falling back to ask when the classifier is unavailable. On those, hooks may deny but can't allow. | Verified on this machine (semantics inferred) | `personOnly`, `hooksMayAllow:false` in the binary |
| F6 | **The main risk.** The docs say hooks fire the same way in IDE extensions. For hosts that use `canUseTool` (the extension), "the hooks run alongside your host, and whichever decides first applies". So the native prompt and the card are **both live** at once. But issues #13203 and #31285 (PermissionRequest/Notification/PostToolUse not firing in the native UI) were closed with only a "works on 2.1.30+" comment, and nobody confirmed it on 2.1.29x–2.1.32x. | Docs-verified, **unconfirmed on this version → Phase 0 gate** | hooks docs; GitHub issues |
| F12 | PreToolUse returns `permissionDecision: allow\|deny\|ask\|defer`. Precedence across hooks: deny > defer > ask > allow. Allow skips the prompt, but **deny and ask rules are still evaluated**. Silence never approves. **AskUserQuestion can be answered** by PreToolUse `allow` plus `updatedInput` = original `questions` plus `answers{questionText: answer}`. | Verified (docs) | hooks docs |
| F13 | Tool events carry `tool_use_id`, plus `agent_id`/`agent_type` when inside a subagent. Stop has `last_assistant_message`. SubagentStop has `agent_transcript_path` and `last_assistant_message`. Common fields: `session_id, prompt_id, transcript_path, cwd, permission_mode, effort, hook_event_name`. There's no session-title field. | Verified (docs) | hooks docs |
| F14 | Default timeout is 600 s for command hooks; 30 s on UserPromptSubmit; SessionEnd shares a 1.5 s budget. `async: true` runs in the background with no timeout enforced and can't return decisions. `--settings '{"disableAllHooks":true}'` disables hooks for a nested `claude -p`. With `canUseTool`, Notification `permission_prompt` fires about 6 s after an unanswered ask. | Verified (docs) | hooks docs |
| F15 | Deep link `…/open?session=<id>` focuses the tab if it's open, or resumes the session from the open folder. `prompt=` **pre-fills only** (no auto-submit). Documented for `vscode://`; `cursor://` is untested. | Verified (docs + extension.js) | docs/en/vs-code |
| F16 | Task tools are TaskCreate/TaskUpdate (TodoWrite is legacy) and are **absent by default on newer models**, so most sessions have no task list. | Verified (docs) | docs/en/tools-reference |
| F17 | **Built-in Remote Control** (`/rc`, or auto-connect for all sessions from the extension) forwards permission prompts and AskUserQuestion to claude.ai/code and the mobile app, with push notifications. It has no Mac overlay and no goal/progress view, needs a claude.ai subscription, and is off when `DISABLE_TELEMETRY` is set. | Verified (docs) | docs/en/remote-control |
| F7 | A non-activating NSPanel (`.nonactivatingPanel`, level `.statusBar`, `.canJoinAllSpaces + .fullScreenAuxiliary + .stationary`) floats over full-screen apps and takes clicks without activating the app. | Likely (anecdotal for macOS 26) | Apple forums |
| F8 | `sharingType = .none` does **not** hide windows from Zoom, Meet or Teams (ScreenCaptureKit) on macOS ≥ 15.4. | Verified | Apple DTS, forum 792152 |
| F9 | Carbon `RegisterEventHotKey` (KeyboardShortcuts package) needs no Accessibility permission. Avoid Option-only combinations. | Verified (macOS 15 notes) | Apple forums |
| F10 | Xcode 15.2 / SDK 14.2 (installed) builds an AppKit+SwiftUI app that runs on macOS 26.7. Notifications and login items need a real `.app` bundle. | Likely | local `xcodebuild -version` |
| F11 | Prior art (§4B): none covers extension sessions, a draggable card, question answering and subagent trees together. | Research | §4 |

## 4. Approaches considered

**A. Native Swift app with hooks and transcript tailing (recommended).** A small AppKit/SwiftUI menubar app receives Claude Code hook events over a Unix socket, answers permission hooks, and tails session transcripts for ground truth.
- Pros: best focus control (the only way to get a true non-activating panel); ~30–50 MB RAM; no new toolchain (Xcode is installed); you own the code.
- Cons: you build it, an estimated 3–5 focused agent-days across phases.

**B. Fork Open Island** (github.com/Octane0411/open-vibe-island, GPL-3.0, ~2.1k★). Hooks → CLI → Unix socket, fail-open, already supports Cursor hooks.
- Pros: fastest route to a working approval UI.
- Cons:
  - GPL-3.0 restricts redistribution (fine for personal use, a problem for sharing inside the company).
  - The UI is notch-centric, not a draggable card.
  - Extension-session support is undocumented.
  - It's a large codebase to learn.

  Worth a 15-minute trial (§12, Phase 0) before building, in case it already behaves well for extension sessions. Claude Island (Apache-2.0, CLI-only, analytics built in) and Claude Peek (MIT, tiny) are references, not bases.

**C. Agent SDK launcher.** AgentDeck itself starts sessions via the Claude Agent SDK, and `canUseTool` routes every approval to the card with certainty.
- Cons: sessions no longer live in Cursor tabs, so you lose the IDE chat, diffs and context. That contradicts the core ask.
- Kept as an optional Phase 3 ("launch a multi-agent team from the card").

**D. Electron or Tauri.** Electron idles at 150–300 MB and trades focus control against text input. Tauri needs Rust plus a community NSPanel plugin. Rejected.

**E. Built-in Remote Control (F17), the zero-build stopgap.**
- Turn on auto-connect in the extension. Approvals and questions then reach your phone and claude.ai/code, with push notifications.
- Gaps: it's a browser tab or phone, not a card over your Mac apps; there's no goal or progress view; it depends on your subscription type.
- Try it today. It costs nothing, and it shows how much of the pain a notification alone solves.

**Pick: A**, with E as today's stopgap, B as a quick trial and C as a later extension.

## 5. Architecture

```
 Cursor: Claude Code extension, N tabs (+subagents)          AgentDeck.app (one process, menubar, LSUIElement)
 ┌────────────────────────────────────────┐                 ┌───────────────────────────────────────────────┐
 │ session A   session B   session C       │  events        │ IPC server: AF_UNIX socket, 0600, tiny HTTP/1.1 │
 │   │ hooks from ~/.claude/settings.json   │ ─fire&forget─▶ │  ├─ Event ingest ──▶ Session store (reducer)    │
 │   ▼                                      │  decisions     │  ├─ Decision broker ◀── Presence monitor        │
 │ adeck-hook (POSIX sh + curl)             │ ─long-poll───▶ │  │        ▲  clicks · hotkeys · notif actions   │
 │                                          │ ◀ allow/deny/∅ │  ├─ Transcript tailer ◀── transcript_path JSONL │
 └────────────────────────────────────────┘                 │  ├─ Risk rules · Liveness · (opt) summarizer    │
            ▲                                                │  └─ Overlay: NSPanel + SwiftUI · menubar · notif│
            └──── cursor://anthropic.claude-code/open?session=<id> ◀── "Open in Cursor" ───────────────────────┘
```

Why two data sources: hooks give instant signals and the only channel for decisions. Transcripts (`transcript_path`, appended JSONL) are the ground truth for progress, tool results, the model and the assistant's last words. They keep working even if some hooks don't fire in the extension (F6).

### 5.1 Components

| Component | Responsibility | Notes |
|---|---|---|
| `adeck-hook` | One script for every hook event. Non-decision events: POST and exit. Decision events: long-poll and print the daemon's JSON verbatim. | Prints nothing on any failure, so Claude Code falls back to its own flow. |
| IPC server | AF_UNIX stream socket at `~/Library/Application Support/AgentDeck/adeck.sock` (dir 0700, socket 0600). Minimal HTTP/1.1: POST with Content-Length only. | Raw BSD sockets plus DispatchSource. NWListener can't listen on Unix sockets. Detects client disconnect, used as the cancellation signal. |
| Event ingest | Decodes hook JSON into `AgentEvent{sessionId, agentId?, kind, tool, inputPreview, ts, pid, cwd, transcriptPath}`. | Truncates large inputs on ingest. |
| Session store | Pure reducer `apply(Session, AgentEvent) -> Session` (§6), in memory. Snapshot of metadata only to JSON for restart. | Unit-tested in isolation. |
| Transcript tailer | Per session, watches the transcript file; reads appended bytes only; extracts tool results, assistant text, `message.model`, todo/task updates, and `summary` title lines. | Skips lines over 256 KB. Unknown line types are ignored, never fatal. |
| Decision broker | Holds pending requests; routes them by presence (§7); enforces one-shot, person-only, hold-to-confirm and the timeout release. | Core safety logic. Most tests live here. |
| Presence monitor | Frontmost app (NSWorkspace notifications) and HID idle seconds (`CGEventSource.secondsSinceLastEventType`). | No permissions needed. Cursor bundle id `com.todesktop.230313mzl4w4u92` (configurable). |
| Risk rules | Deterministic table that labels each request low/med/high with a reason (§9). | No LLM. |
| Liveness | Hook sends `$PPID` (walk up to the `claude` process if needed). `kill(pid,0)` every 30 s; SessionEnd; 30 min silence → "stale". | Handles closed tabs and crashes without SessionEnd. |
| Summarizer (optional, off in v1) | Haiku 5.5 one-liners for goal and status (§10). | Debounced, cached, never in the decision path. |
| Overlay + menubar + notifier | NSPanel UI (§8), NSStatusItem with badge, UNUserNotification fallback with actions. | Ships as a `.app` bundle (ad-hoc signed) for notifications and launch at login. |

### 5.2 Hook wiring

The installer merges these entries into `~/.claude/settings.json`. It keeps your existing graphify, gstack and kb hooks, backs the file up first, and the uninstaller removes only AgentDeck's entries.

```json
{
  "hooks": {
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook decide PermissionRequest", "timeout": 600 }] }],
    "PreToolUse":        [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook gate PreToolUse", "timeout": 600 }] }],
    "PostToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event PostToolUse", "async": true }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event UserPromptSubmit", "async": true }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event Stop", "async": true }] }],
    "SubagentStart":     [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event SubagentStart", "async": true }] }],
    "SubagentStop":      [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event SubagentStop", "async": true }] }],
    "Notification":      [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event Notification", "async": true }] }],
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event SessionStart", "async": true }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "~/.agentdeck/bin/adeck-hook event SessionEnd", "async": true }] }]
  }
}
```

`async` means Claude doesn't wait at all, and async hooks can't return decisions (F14), so only `gate` and `decide` are synchronous. The PreToolUse `gate` answers in milliseconds unless the broker holds the request (AskUserQuestion, or Channel 2 in §7).

**Two-step decision protocol** (so a hung daemon can never freeze a session for 600 s):
1. `POST /v1/<mode>/<Hook>` with a 0.5 s limit. The daemon answers at once with a one-word verb:
   - `PASS`: pass through.
   - `DECIDE <json>`: a decision.
   - `HOLD <id>`: held.
   A dead or hung daemon fails this step, so the hook fails open in ≤ 0.5 s.
2. Only on `HOLD`: `GET /v1/wait/<id>` with a 595 s limit. The daemon streams a **heartbeat** (4 spaces per second) and then the decision JSON, or nothing to pass through. Leading spaces are valid JSON. Fail-open cases:
   - Under 1 byte/s for 6 s means the daemon is hung: curl aborts and the hook fails open (tested: 6.06 s).
   - The daemon crashes: the socket closes, curl returns, and the hook fails open.
   - Timeout: the daemon releases on its own timer at 590 s.
3. **Cancellation.** If Claude Code ends the hook (you answered in Cursor), the TERM trap kills the waiting curl, so the daemon sees the socket close (tested: no curl or temp file left over).
   - The daemon also resolves a held card as "Handled elsewhere" on any newer event for the same session, or a transcript `tool_result` for the same tool. That covers SIGKILL, where traps can't run.
   - A `HOLD` whose `GET` doesn't arrive within 2 s is dropped as "hook gone".

```sh
#!/bin/sh
# adeck-hook <event|gate|decide> <HookName>. Fail-open: any error → no stdout, exit 0.
[ -n "$ADECK_NESTED" ] && exit 0                     # our own summarizer calls never re-enter
SOCK="$HOME/Library/Application Support/AgentDeck/adeck.sock"
[ -S "$SOCK" ] || exit 0
c() { curl -s --fail --unix-socket "$SOCK" -H "X-Adeck-Pid: $PPID" -H "X-Adeck-Host: ${__CFBundleIdentifier:-$TERM_PROGRAM}" "$@" 2>/dev/null; }
if [ "$1" = event ]; then c -m 0.3 --data-binary @- "http://adeck/v1/event/$2" >/dev/null; exit 0; fi
R=$(c -m 0.5 --data-binary @- "http://adeck/v1/$1/$2") || exit 0
case "$R" in
  "DECIDE "*) printf '%s' "${R#DECIDE }"; exit 0 ;;
  "HOLD "*)   ;;
  *)          exit 0 ;;                               # PASS or anything unexpected
esac
# Held: the daemon streams 4 spaces/s as a heartbeat, then the decision JSON (or nothing).
# Under 1 byte/s for 6 s = hung daemon → curl aborts → fail open. Leading spaces are valid JSON.
OUT=$(mktemp -t adeck) || exit 0
curl -s --fail --unix-socket "$SOCK" -m 595 --speed-limit 1 --speed-time 6 -o "$OUT" "http://adeck/v1/wait/${R#HOLD }" 2>/dev/null & CP=$!   # direct, so $! is curl
trap 'kill $CP 2>/dev/null; rm -f "$OUT"; exit 0' HUP INT TERM
if wait $CP && grep -q '{' "$OUT"; then cat "$OUT"; fi
rm -f "$OUT"; exit 0
```

`X-Adeck-Host` is the bundle id of the app the session runs in (Cursor for both extension tabs and Cursor's integrated terminal). It drives scoping and per-host presence (§7).

The daemon only ever sends the exact JSON Claude Code expects (F4, F12):
- PermissionRequest: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
- PreToolUse: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied in AgentDeck: <your note>"}}`
- AskUserQuestion: PreToolUse `allow` plus `updatedInput:{questions:[…original…], answers:{"<question text>":"<answer>"}}`

Phase 0 captures real payloads and freezes them as contract fixtures.

## 6. Session model

```
Session { id, project(basename cwd), cwd, transcriptPath, pid, title?, goal, latestAsk, model?,
          state, currentStep{label, tool, startedAt}?, progress{done,total}? , subagents[Agent],
          pending[Request], startedAt, lastEventAt }
Request { id, sessionId, agentId?, kind(permission|question), tool, preview, fullInput(mem only),
          risk{level, reason}, suggestions[], personOnly?, channel, createdAt, status }
```

| From → event | To |
|---|---|
| (none) → SessionStart / first event | `idle` |
| any → UserPromptSubmit | `working`. The first prompt sets `goal` (first line, ≤ 80 chars); later prompts set `latestAsk`. |
| working → PreToolUse | `working` with `currentStep` = deterministic label ("Bash: npm test", "Edit routes.js +12 −3", "Agent: code-reviewer") |
| any → decision held | `needsYou(permission/question)` |
| needsYou → released to Cursor | `waitingInCursor` |
| any → PostToolUse / transcript tool_result | `working`, step done |
| working → Stop | `yourTurn`, plus a 1–2 line summary from the last assistant text (transcript) |
| any → Notification(idle_prompt) | `yourTurn` (if not already) |
| any → PostToolUseFailure | `working`, step marked failed; repeated failures → `error` badge |
| any → SessionEnd / pid gone | `ended` (fades after 2 min) |
| working, no events for 30 min, pid alive | `quiet` (shows "no activity for 30m", never "stuck") |

- **Goal and title:** use a title line from the transcript if Phase 0 finds one (the extension derives its tab title from history or the first prompt). Otherwise use the first prompt.
- **Progress:** done/total only from real task updates (TaskCreate/TaskUpdate or TodoWrite, plus the `TaskCreated` hook). These tools are absent by default on newer models (F16), so the **normal** display is the step count, the current step with its elapsed time, and an activity sparkline. **No invented percentages.**
- **Your-turn summary:** Stop's `last_assistant_message` (F13); no transcript parsing needed.
- **Subagents:** SubagentStart/Stop give `agent_id`/`agent_type`, and tool events inside a subagent carry `agent_id` (F13), so they attach to the child row. SubagentStop with an empty `agent_type` is internal (prompt suggestions, /btw); hide it.

## 7. Getting decisions into the card: three channels, chosen by Phase 0

| Channel | Works if | How |
|---|---|---|
| **1. PermissionRequest, racing the native prompt** (preferred) | Phase 0 confirms F6 on 2.1.323, or you use the extension's terminal mode (`claudeCode.useTerminal: true`), where CLI hooks are fully supported | The hook is held while the native prompt shows in Cursor at the same time. **Whichever you answer first wins** (F6). If you answer in Cursor, Claude Code ends the hook; the card sees the socket close and shows "Handled in Cursor". No request can get stuck in only one place. |
| **2. Away gate (PreToolUse)** | PermissionRequest doesn't fire in the extension | PreToolUse fires in the extension (issue reports agree). Only while you're **away** (or in "Away mode"), the gate holds tool calls that would likely prompt and asks in the card. Allow skips the prompt; deny/ask rules are still enforced by Claude Code (F12). Rules below. |
| **3. Notify and jump** | Neither of the above | The card shows "Session B needs approval (Bash: …)" with one-click **Open in Cursor ↗** (F2/F15 deep link focuses the exact tab). Signals: the Notification `permission_prompt` hook (fires about 6 s after an unanswered ask, F14), or PreToolUse seen with no tool result within 6 s for a tool that isn't long-running. |

**Questions (AskUserQuestion) use PreToolUse in every channel** (F12). The gate always holds an AskUserQuestion call while you're away and answers it with `updatedInput.answers`. While you're present it passes through, and you answer in Cursor.

**Channel 3 always runs as a backstop**, on top of Channel 1 or 2. Some prompts slip past the active channel:
- passed through while you were present, then you left;
- low-risk under "risky-only" scope;
- an unexpected prompt for a "read-only" tool;
- a prompt in a background Cursor window.

Each still surfaces as a "needs approval · Open ↗" card.

**Mixed Phase 0 results:** the broker reads a capability matrix keyed by tool category (Bash, Edit/Write, Web, MCP, Question, ExitPlanMode). Each category uses the best channel that worked for it in Phase 0.

**Which sessions it acts on** (from `X-Adeck-Host` and `CLAUDE_CODE_ENTRYPOINT`):
- Cursor-hosted interactive sessions (extension tabs and the Cursor integrated terminal) are shown **and** gated.
- Interactive sessions in other hosts (iTerm, VS Code) are **shown only** (a setting adds them).
- Headless runs (`claude -p`, SDK automation) are **never held**. They pass through immediately, so automation can't stall.

"Present" is per host: the session's host app is frontmost.

**Permission modes and special tools:**
- `bypassPermissions`, `plan` and `dontAsk`: the gate always passes through. An allow from AgentDeck must never loosen a mode you chose.
- `auto`: the gate defaults to risky-only scope.
- `ExitPlanMode` (plan approval plus a choice of mode) is never approvable from the card. It shows the plan's first lines with **Review in Cursor ↗** only.

**Release means empty stdout.** Never `defer`: it's a decision in its own right and outranks ask/allow (F12).

Away-gate rules for Channel 2. It is deterministic, and any mismatch errs toward asking, never toward allowing. Pass through (∅) when:
- you're present, or
- `permission_mode` is `bypassPermissions`, or
- `permission_mode` is `acceptEdits` and the tool is Edit/Write/MultiEdit/NotebookEdit, or
- the tool is read-only (Read, Grep, Glob, LS, todo/task tools), or
- a settings **deny** rule matches (let Claude Code deny it; never override deny), or
- a simple settings allow rule matches (exact tool name, or `Bash(prefix:*)`).

Otherwise hold. A "Gate scope: risky-only" setting holds only med/high-risk requests, for users in auto mode who find full scope too noisy.

### Presence routing

"Present" = Cursor is frontmost **and** you were active in the last 20 s.

1. **Channel 1** (the native prompt is already live in parallel). Presence changes only *attention*:
   - Present: a muted list row; no expansion, no sound.
   - Away: the action card pops (§8).
   - The hook stays held either way, so you can answer in whichever place you look first.
2. **Channel 2 / questions** (nothing shows in Cursor while the gate holds):
   - Present: pass through at once.
   - Away: hold and show the card.
   - If you switch to Cursor and stay 3 s: release (empty stdout), so the native prompt or question appears there. The card says "Moved to Cursor ↗".
3. At 590 s (hook timeout 600 s): release (∅). In Channel 1 the native prompt is still there. In Channel 2 the normal prompt then shows. The card keeps a low-key "waiting in Cursor ↗".
4. If the hook connection closes first (answered in Cursor, turn interrupted, session killed): mark the card "Handled elsewhere" and drop it.
5. **Person-only requests (F5):** the card offers **Deny** and **Approve in Cursor ↗** only, because an allow would be ignored.

## 8. Overlay UX

The window is an NSPanel with `[.borderless, .nonactivatingPanel]`, level `.statusBar`, and `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. It's shown with `orderFrontRegardless()` and never made key, except that `becomesKeyOnlyIfNeeded` lets a reply text field take typing. Content is SwiftUI via NSHostingView. The panel is movable by its background, snaps to the nearest corner within 40 px when you drop it, and its frame is saved per display.

**Collapsed pill** (default, top-right):
```
╭──────────────────────────────────────╮
│ ◉ 4 agents · 1 needs you · 2 working │
╰──────────────────────────────────────╯
```
Colors: grey = idle, blue = working, amber = needs you, green = your turn, red = error.

**Expanded list** (hover with a 300 ms intent delay, or click; collapses 1.2 s after the pointer leaves, unless pinned or something is pending):
```
╭─────────────────────────────────────────────────────╮
│ ◉ 4 agents · 1 needs you                    📌 ⚙ ─ │
├─────────────────────────────────────────────────────┤
│ ⚠ my-project · "Fix S3 pool leak"   Opus · 4m │
│   Wants to run  Bash  npm run test:e2e   [med]      │
│   [Allow ⌃⌥Y] [Deny ⌃⌥N] [Deny + note…] [Open ↗]    │
├─────────────────────────────────────────────────────┤
│ ● web-app · "CALL tooltip" Sonnet·12m│
│   ▓▓▓▓▓▓▓░░░ 4/7   Edit ActivityLog.tsx +18 −2  0:41│
│   └ 2 subagents · code-reviewer ● · tests ●         │
├─────────────────────────────────────────────────────┤
│ ✓ reports · "Optimise report query"  your turn│
│   "Added compound index; query 4.1s → 180ms."  [↗]  │
├─────────────────────────────────────────────────────┤
│ ○ sdk-demo · idle 22m                           │
╰─────────────────────────────────────────────────────╯
```

**Action card** (auto-expands for a new request, showing only that card):
- Project, session title, model and elapsed time.
- What it wants: the tool plus its key argument (the command; the file with +/− counts and a 6-line diff preview; the URL; the MCP server.tool).
- A risk badge with its reason. Click to expand the full input (monospace, scrolls, at most 20 lines). Things that look like tokens (`Bearer …`, `sk-…`, `AKIA…`) are masked, with click to reveal.
- Buttons:
  - **Allow**.
  - **Allow always…**: only when `permission_suggestions` exist; shows the exact rule, e.g. `Bash(npm test:*)` for this project.
  - **Deny**.
  - **Deny + note…**: an inline field; the note goes to Claude as the deny message, so it can adapt.
  - **Open in Cursor ↗**.
- **High risk:** Allow needs a 1 s press-and-hold. Hotkey approval is disabled for high-risk requests.
- **Queue:** "1 of 3". Oldest first. A new request **never replaces the card under the pointer**; it joins the queue.
- **No approving what you didn't see:**
  - Every click and hotkey is bound to the request id **rendered on screen**. If that request resolves elsewhere first, the action is dropped, never passed to the next card.
  - A card's Allow, by button or hotkey, arms only after the card has been fully visible for 600 ms. It disarms again whenever the top card changes.
  - In collapsed, Quiet or privacy mode, and for muted Channel 1 rows, ⌃⌥Y and ⌃⌥N only expand the card; they don't decide.

**Question card** (AskUserQuestion, F12): the question, option buttons (checkboxes when multi-select), an "Other…" field, and Submit. Submit returns PreToolUse `allow` with `updatedInput.answers`. If Phase 0 shows the extension ignores the injected answers, it's read-only with **Answer in Cursor ↗**.

**Your-turn card:** "✓ Done" plus a 1–2 line summary, **Open ↗** and **Dismiss**. It folds into the list after 10 s.

**Attention ladder** (never steals focus):
- t=0: expand, glow, and an optional single soft sound.
- t=30 s: the pill pulses.
- t=90 s: a macOS notification with **Deny** and **Show** actions only. Notifications persist in Notification Center and on the lock screen with truncated input, so they never carry Allow.
- t=590 s: release to Cursor (§7).

**Hotkeys** (Carbon; each includes Ctrl):

| Keys | Action |
|---|---|
| ⌃⌥Space | expand/collapse |
| ⌃⌥Y | allow the top card |
| ⌃⌥N | deny the top card |
| ⌃⌥O | open the top card's session in Cursor |
| ⌃⌥H | hide / privacy mode |

All are rebindable.

**Privacy mode:** shows only states and counts ("Session 2 needs approval · Bash"); no goals, commands or diffs. Toggle it from a hotkey or the menubar. Because hiding from screen share isn't possible on macOS ≥ 15.4 (F8), privacy mode is the mitigation. Auto-detecting screen sharing is left out of v1.

**Menubar:**
- Show/hide.
- Away mode (forces holding requests).
- Quiet (badge only).
- Privacy.
- Pause AgentDeck (every request passes through).
- Settings:
  - Cursor bundle ids.
  - Away threshold.
  - Gate scope.
  - Sounds.
  - Summarizer on/off.
  - Launch at login.
- Quit.

## 9. Safety and security rules

1. **Fail-open everywhere.** No socket, a hung daemon, a crash or a malformed response → the hook prints nothing → Claude Code's own flow runs. Tested (§13).
2. **No model in the decision path.** No "approve all". No auto-approval rules of AgentDeck's own beyond what Claude Code's settings already allow.
3. **Never override deny.** Settings deny rules win, and person-only requests can't be allowed from the card.
4. **One-shot, bound decisions.** A decision applies only to its request id, and only while that hook connection is open. A late click resolves to "Handled elsewhere".
5. **Risk rules (deterministic).**
   - High:
     - `rm -rf`, `sudo`, `curl … | sh`.
     - `git push` (force or otherwise), `git reset --hard`.
     - `npm publish`.
     - Writes outside `cwd`.
     - Edits to `.env*`, `*.pem`, `*.key`, `jwt/`.
     - Commands naming `prod`/`production` with `aws`/`kubectl`/`mongo`.
     - `DROP`/`DELETE`/`TRUNCATE` SQL.
   - Med: network fetches, package installs, `git commit`, MCP write tools.
   - Low: everything else that prompts.
6. **Local-only data.** The socket is user-only (0600 in a 0700 dir). Full tool inputs live in memory only. Logs hold metadata only, rotated at 5 MB. Network is used only by the optional summarizer.
   - Trust model: any process running as you could talk to the socket, but such a process can already edit `~/.claude/settings.json`, so this crosses no new boundary.
7. **Installer hygiene.** It backs up `settings.json`, merges idempotently, and uninstall removes exactly its own entries.
8. **Known limit: other PreToolUse hooks.** In Channel 2, another PreToolUse hook that returns `updatedInput` could change what runs after you approved the original input in the card. Claude Code re-checks the new input against deny/ask rules, but not against your eyes.
   - The installer lists existing PreToolUse hooks and warns if any can return `updatedInput`. Today's graphify hook only adds context.
   - Channel 1 doesn't have this problem: PermissionRequest runs after PreToolUse, so the card shows the final input.

## 10. Model routing

### 10.1 Inside the product (runtime)

| Function | Model | Why |
|---|---|---|
| Approve/deny routing, risk labels, state, step labels | **None (deterministic)** | Must be instant, predictable and auditable. A model must never approve anything. |
| Session goal one-liner and "what it's doing" sentence (on Stop, at most every 2 min while working) | **Claude Haiku 5.5** (`claude-haiku-5-5`), low effort | $0.10 / $0.50 per MTok, so ~$0.0001 per summary. Summarizing is easy and Haiku is fast. **Off by default:** the transcript title plus the first prompt cover most of the need. |
| "Explain this command" button (Phase 2, on demand) | **Claude Sonnet 5.5** (`claude-sonnet-5-5`) | Risk explanations need judgment; rare and user-initiated. |

Summarizer transport: `ADECK_NESTED=1 claude -p --model claude-haiku-5-5 --settings '{"disableAllHooks":true}'`. This uses your existing Claude Code login (no API key). `disableAllHooks` (verified, F14) plus the env guard in `adeck-hook` stop it from re-triggering AgentDeck or your other hooks.

## 11. Non-functional requirements

| Requirement | Target |
|---|---|
| Hook overhead, non-decision events | 0 ms with async; ≤ 25 ms p95 otherwise |
| Gate pass-through decision | ≤ 10 ms p95 |
| Event → card update | ≤ 300 ms |
| Resources | ≤ 60 MB RSS and ~0% CPU when idle. The tailer reads appended bytes only. |
| Scale | 10 concurrent sessions, 50 queued requests, 3 Cursor windows |
| Fail-open | Daemon quit, crash or hang changes nothing in Claude Code's behavior (§13 test) |
| Restart | Sessions rebuild from the next event plus a transcript re-read. Requests whose hook connection dropped are discarded. |

## 12. Delivery phases

**Phase 0: capability spike (≤ ½ day, throwaway).** A 20-line logging hook plus a manual responder, run in a scratch folder with project-level `.claude/settings.json` (so your global settings stay untouched). It answers:
1. Does PermissionRequest fire for native-UI prompts in extension 2.1.323 (Bash, Edit, WebFetch, MCP)? Does the docs' "whichever decides first" race hold: native prompt and hook live together, with the hook ended when you answer in Cursor? Same questions in terminal mode.
2. Does the extension honor PreToolUse allow/deny (native prompt skipped)? Does it honor AskUserQuestion `updatedInput.answers`?
3. Do PostToolUse, Notification(`permission_prompt`) and SubagentStart fire in the extension? Do `async` hooks behave?
4. Does a title line exist in the transcript? What do real payloads look like (capture fixtures)?
5. Does `cursor://anthropic.claude-code/open?session=<id>` focus the tab (only `vscode://` is documented)?
6. Does an NSPanel float over full-screen Zoom, and take clicks without focus loss? Does a Carbon hotkey work in an ad-hoc-signed bundle on 26.7?
7. A 15-minute trial each of Remote Control auto-connect (approach E) and Open Island (approach B) with one extension session.

**Output:** a capability matrix **per tool category** (§7) that picks each category's channel, and the JSON envelopes frozen as fixtures. **Go/no-go per category:** where neither Channel 1 nor 2 works, that category uses Channel 3 (notify and jump), and terminal mode is documented as the way to get full approvals there. Phase 1 ships either way.

**Phase 1: MVP "see and approve".**
- Hook bridge, installer, daemon and session list (title/goal, state, current step, elapsed).
- Action cards on the chosen Channel, presence routing, fail-open, deep-link jump.
- Drag, snap and persist; hotkeys; menubar.

**Phase 2: full picture.**
- Transcript-based progress, subagent tree, question cards and your-turn cards.
- Attention ladder with notifications, "Allow always" suggestions, risk rules with hold-to-confirm.
- Privacy mode, optional Haiku summaries.

**Phase 3 (optional, each separately approved):**
- Reply from the card. Deep link `prompt=` only pre-fills (F15), so you'd still press Enter in Cursor. A true no-switch reply means a Stop hook that holds sessions you mark "keep listening" and returns `{"decision":"block","reason":"<your reply>"}`. Claude caps this at 8 consecutive continuations; check `stop_hook_active`.
- A Cursor native agent adapter (`~/.cursor/hooks.json`: `beforeShellExecution`/`beforeMCPExecution` return `permission: allow|deny|ask`, blocking with a timeout, fail-open).
- A Codex adapter.
- An Agent SDK "launch a multi-agent team" button (approach C).

## 13. Testing

- **Contract:** fixtures per event, captured in Phase 0 from real extension sessions and scrubbed by the scout → `adeck-hook` → a fake socket server. Assert request shape. Decision responses are validated against the frozen envelopes.
- **Reducer:** event sequences → states, including out-of-order events, a missing SessionEnd, pid death, and a subagent without `agent_id`.
- **Broker:**
  - allow, deny, timeout release, presence release, disconnect
  - person-only, double click, high-risk hold
  - 50-request queue
- **Fail-open:**
  - Socket missing → exit 0, empty stdout, < 50 ms.
  - Daemon accepts but never answers → curl `-m` fires, empty stdout.
  - Daemon returns 500 → empty stdout (`--fail`).
- **Already prototyped (2026-11-13, this machine).** The §5.2 script ran against a fake Python daemon on a socket path containing a space:

  | Case | Result | Time |
  |---|---|---|
  | No socket | exit 0, empty | 0.00 s (first run of a new file: 0.5–0.8 s, likely the macOS first-exec scan; the installer should run it once) |
  | Hung daemon, gate | exit 0, empty | 0.53 s |
  | Hung daemon, event | exit 0, empty | 0.31 s |
  | PASS | empty | 0.03 s |
  | DECIDE | exact JSON | 0.01 s |
  | HOLD → wait | decision JSON | 0.04 s |
  | HOLD → heartbeat 3 s → allow (final script) | decision JSON | 3.78 s |
  | HOLD → heartbeat → empty | empty | 3.08 s |
  | HOLD → daemon hangs, no heartbeat | exit 0, empty | 6.06 s |
  | Hook gets SIGTERM while held | 0 leftover curl, 0 temp files | immediate |

  macOS limits AF_UNIX paths to **104 bytes**; the production path is 66 bytes.
- **Manual E2E checklist (Cursor):**
  - 3 tabs, one with 2 subagents.
  - Zoom full-screen on a second display.
  - Approve from the card, deny with a note, switch to Cursor mid-request, quit AgentDeck mid-request.

## 14. Risks

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| PermissionRequest doesn't fire in the extension's native UI (F6) | High / high | Three channels (§7), Phase 0 gate, terminal-mode fallback |
| Extension auto-updates change hook behavior (3 versions are already installed side by side) | Med / high | Contract fixtures. A "hooks degraded" badge when the transcript shows tool activity with no matching hook events. Re-run Phase 0 checks after updates. |
| Full-screen and Spaces behavior shifts in a macOS update | Med / med | Configurable window level; E2E checklist per macOS update |
| Screen share shows the card (F8) | High / med | Privacy mode plus hotkey; documented, not promised |
| Away gate over-asks in auto mode | Med / low | "Risky-only" scope; presence routing means it's only active while you're away |
| A hung daemon freezes sessions (hooks default to a 600 s timeout) | Low / high | Two-step protocol (§5.2). The 0.5 s first call fails open. Long waits happen only after `HOLD`, and only while the heartbeat flows: 6 s of silence fails open (tested). A socket close also ends the wait. |
| A Channel 1 race: you click Allow in the card just as you answer in Cursor | Med / low | Claude Code applies whichever answers first (F6). The card resolves on socket close. Decisions are one-shot per request. |
| A PreToolUse allow gets discarded after a later permission-check error (changelog 2.1.323) | Low / low | Claude Code then decides as if no hook answered, i.e. the normal prompt. Shown as "moved to Cursor". |

## 15. Key design decisions

1. Native Swift over Electron, Tauri or a fork (§4).
2. Unix socket plus `sh`/`curl` hooks, not a compiled helper. Zero install footprint; fast enough.
3. Presence-aware routing. In Channel 1 presence changes only how loudly the card alerts, because the native prompt is live anyway. For the gate and questions, present → Cursor, away → card.
4. No LLM in v1's critical path; Haiku summaries opt-in.
5. The card also supervises multi-agent sessions you run, via the subagent tree. A product feature that *launches* teams is Phase 3 (approach C).
6. The working name "AgentDeck" and the default hotkeys.
7. **Scope:** Cursor-hosted interactive sessions are gated. Other hosts are shown only. Headless runs are never held (§7).
8. **Distribution:** ad-hoc signed for now. Developer ID signing and notarization can be added later with no design change.
9. Channel 3 always on as a backstop. No Allow in macOS notifications. ExitPlanMode only in Cursor.

## 16. Left to the builder

- Swift package layout, test framework details, the HTTP parser implementation.
- Visual styling (materials, typography, animation timing) within §8's behavior.
- Exact deterministic step-label wording.
- Risk-rule regexes beyond the §9 list.
- Corner-snap thresholds and the hover intent delay (start with 40 px / 300 ms).
- Fixture scrubbing approach.
