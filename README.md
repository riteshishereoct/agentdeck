# AgentDeck

A native macOS floating overlay that supervises your Claude Code sessions.

**[Interactive guide and demo](https://riteshishereoct.github.io/agentdeck/)** · **[Download the preview](https://github.com/riteshishereoct/agentdeck/releases)**

You started Claude Code in three projects. One is waiting for a yes. One asked a question ten minutes ago. One finished and nobody noticed. AgentDeck keeps every session in view and lets you answer from one card.

**What.** A small overlay listing every Claude Code session across your Cursor windows and terminals: what each is doing now, what it is waiting for, and what it last finished.

**Why.** Agents stall silently on a permission prompt or a question. Every stall is parallel work not happening. AgentDeck shows the stall as it starts, so several sessions keep moving instead of you babysitting one tab.

**How.** Claude Code hooks report each step to the app over a local unix socket. With controls enabled, you allow, deny with a note, or answer a question from the card, and the session carries on.

```
Agent asks -> Deck lights up -> You decide -> Agent continues
```

## Features

- Pill and card overlay (AppKit panel + SwiftUI), global hotkeys, menu bar item, hides when idle.
- Per-session state: working, needs you, idle, finished; subagent tree; goal/title labels.
- Allow / deny (with a note) permission prompts and answer questions from the card.
- Risk rules per tool category; high-risk commands need a deliberate hold.
- Jump to the exact session tab in Cursor via deep link.
- Hook health checks with an explicit "repair hooks" action (see `docs/hook-health.md`).
- Optional Haiku-based summaries, off by default.
- Optional Slack phone approvals, separately installed and off by default.
- No AgentDeck account or cloud service; the core app makes no internet calls.

New in 0.3.0:

- **Optional phone approvals:** receive a dedicated read-only file request (`Read`, `Grep`, `Glob`, or `LS`) as a Slack DM and allow once, deny, or leave it for the laptop. The add-on is bundled but never auto-installed; AgentDeck works normally without Slack.
- **Race-safe approval endpoint:** the add-on claims one exact pending broker request before contacting Slack, then resolves only that opaque request ID. A delayed answer cannot authorize a later identical request.
- **Safer setup:** secret-bearing, write, edit, publishing, destructive, production, MCP and unrecognized actions remain on the laptop; install/uninstall preserves neighboring hooks.

From 0.2.0:

- **About AgentDeck** window: version and build, hooks health, socket, requirements, signing, license; open it from the menu-bar or deck header menu.
- **Menu icons:** SF Symbols on every menu item.
- **Animated state emoji** per session row (working, needs you, waiting, ready, error, idle, quiet, ended). Loops run at 15 fps for 4 seconds after a state change, then rest; Reduce Motion and a setting turn them off.
- **Liquid Glass** surfaces on macOS 26 (frosted material on macOS 14-25), with Appearance (System/Light/Dark), Surface, accent presets and opacity in Settings.
- **Companion:** a Pet blob or rotating 3D geometry in the pill and panel header (or off). It animates for about 4 seconds after a state change and while hovered.

## Architecture

```
Claude Code hooks
   |  hooks/adeck-hook  (sh + curl, fail-open)
   v
unix socket  (~/Library/Application Support/AgentDeck/adeck.sock)
   |
   v
Daemon  -> Ingest -> Reducer (session model) -> Decision broker (held requests)
   |
   v
UIModel (card queue, risk, arming)  ->  SwiftUI overlay
```

- `Sources/AgentDeckCore`: library (IPC, ingest, reducer, broker, risk, presence, transcript, UI model). Foundation/Darwin only, no AppKit.
- `Sources/AgentDeckApp`: executable (AppKit, SwiftUI, Carbon hotkeys, notifications).
- `hooks/adeck-hook`: the hook script. Any error means no output and exit 0, so Claude Code falls back to its own prompt.
- `installer/`: merges AgentDeck entries into `~/.claude/settings.json` without touching foreign entries, with backup.
- `addons/phone-approvals/`: optional Slack DM approvals and its standalone installer/tests. It is not part of the default AgentDeck install.
- Contract: [`docs/protocol.md`](docs/protocol.md). Design: [`docs/superpowers/specs/2026-11-13-agentdeck-design.md`](docs/superpowers/specs/2026-11-13-agentdeck-design.md).

## Safety design

- **600 ms arming.** Allow/Deny buttons stay inert until the full request has been visible for 600 ms, restarting each time the card is shown.
- **Hold to allow.** Risky commands need a 1 s press-and-hold; releasing early drops the action.
- **Silence never approves.** A timeout, a crash, a dropped connection or a hung daemon never allows anything; the hook fails open to Claude Code's own native prompt, not to "yes".
- **Notifications-only by default.** Out of the box AgentDeck only observes. Approving or answering from the card is an explicit opt-in per tool category (`config/capabilities.json`).
- Local only; the installer never touches Cursor/VS Code settings.
- The optional Slack add-on sends only complete short paths or search patterns from dedicated read-only file tools to the owner's DM; every shell command stays on the laptop, and credentials stay in macOS Keychain prompts.

## Requirements

- macOS 14+, Apple silicon
- Claude Code (CLI or the Cursor extension). Cursor extension tested on 2.1.325.
- Swift 5.9+ / Xcode 15.2+ to build from source

## Build from source

```sh
swift build
swift test
scripts/bundle.sh          # release build -> build/AgentDeck.app (ad-hoc signed)
installer/install.sh       # installs the hook to ~/.agentdeck/bin and merges ~/.claude/settings.json
installer/uninstall.sh
```

`installer/install.sh` edits your real `~/.claude/settings.json` (with a backup). Read it first. Tests use temporary HOMEs.

`distribution/team/` holds double-click `.command` wrappers around the same installer for handing a built zip to colleagues.

## Limitations

> **Known acceptance gap: memory target FAIL.** The prior ten-minute native run peaked at **62.9 MiB RSS versus the 60 MiB target** (physical footprint 36.0 MiB); memory was not remeasured for this security-focused release. Validation: 483/483 real XCTest tests, 26/26 add-on tests and 18/18 guide checks passed.

- Not notarized yet; ad-hoc signed. macOS may block the first launch: for a copy you trust, review System Settings → Privacy & Security → Open Anyway.
- Claude Code only. Other agents are not tracked.
- Phone approvals require the optional Slack add-on; native mobile push is not implemented.
- Follow-up prompts are pre-fill only: AgentDeck puts text in the input, it does not submit it.
- Tested against Claude Code hook behavior at one version; compatibility is pinned in `distribution/team/Compatibility/`.
- Some validation was automated harness runs rather than live-app acceptance; see `docs/validation/`.

## License

MIT. See [LICENSE](LICENSE).
