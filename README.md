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
- No account, no cloud service, no network calls of its own.

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
- Contract: [`docs/protocol.md`](docs/protocol.md). Design: [`docs/superpowers/specs/2026-11-13-agentdeck-design.md`](docs/superpowers/specs/2026-11-13-agentdeck-design.md).

## Safety design

- **600 ms arming.** Allow/Deny buttons stay inert until the full request has been visible for 600 ms, restarting each time the card is shown.
- **Hold to allow.** Risky commands need a 1 s press-and-hold; releasing early drops the action.
- **Silence never approves.** A timeout, a crash, a dropped connection or a hung daemon never allows anything; the hook fails open to Claude Code's own native prompt, not to "yes".
- **Notifications-only by default.** Out of the box AgentDeck only observes. Approving or answering from the card is an explicit opt-in per tool category (`config/capabilities.json`).
- Local only; the installer never touches Cursor/VS Code settings.

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

> **Known acceptance gap — FAIL.** The previous full warm-idle run peaked at 97.2 MiB RSS versus a 60 MiB target after text entry. Investigation found macOS text-input framework residency and no app-owned leak. The 0.1.1 binary has not had a new ten-minute native energy run, so its memory target remains unverified.

- Not notarized yet; ad-hoc signed. macOS may block the first launch: for a copy you trust, review System Settings → Privacy & Security → Open Anyway.
- Claude Code only. Other agents are not tracked.
- Mobile push is not implemented.
- Follow-up prompts are pre-fill only: AgentDeck puts text in the input, it does not submit it.
- Tested against Claude Code hook behavior at one version; compatibility is pinned in `distribution/team/Compatibility/`.
- Some validation was automated harness runs rather than live-app acceptance; see `docs/validation/`.

## License

MIT. See [LICENSE](LICENSE).
