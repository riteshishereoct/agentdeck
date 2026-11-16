# AgentDeck protocol and build contract (frozen)

Status: frozen 2026-11-13 for the Phase 1 + Phase 2 build plan. Source of truth for behavior is the spec,
`docs/superpowers/specs/2026-11-13-agentdeck-design.md` (cited as §N / FN). This file freezes the
interfaces between parts so every coworker codes against it, not against each other. A change here needs
the orchestrator; a coworker that finds a gap writes it as an open issue, never a silent variation.

Where this file is stricter than the spec, the reason is given inline and tagged **[clarifies §N]**.

---

## 1. Paths

| What | Path | Mode |
|---|---|---|
| Support dir | `$HOME/Library/Application Support/AgentDeck/` | dir `0700` (created or `chmod`ed at daemon start) |
| Socket | `$HOME/Library/Application Support/AgentDeck/adeck.sock` | `0600` |
| Capability matrix (runtime) | `$HOME/Library/Application Support/AgentDeck/capabilities.json` | `0600` |
| Session snapshot | `$HOME/Library/Application Support/AgentDeck/sessions.json` | `0600`, metadata only |
| Log | `$HOME/Library/Logs/AgentDeck/agentdeck.log` (+ one `agentdeck.log.1`) | metadata only, rotate at 5 MB (5_242_880 bytes) |
| Hook script (installed) | `$HOME/.agentdeck/bin/adeck-hook` | `0755` |
| Settings backup | `$HOME/.claude/settings.json.agentdeck-backup-<YYYYmmdd-HHMMSS>` | copy of original |

**Socket path length.** `sockaddr_un.sun_path` is `char[104]` on macOS including the NUL, so the UTF-8 byte
length of the socket path must be **≤ 103** (spec: "AF_UNIX paths limited to 104 bytes"; production path
is 66 bytes for this user). The daemon checks before `bind` and throws `DaemonError.socketPathTooLong(bytes:)`.
Tests create sockets under `FileManager.default.temporaryDirectory` with a short random name and assert the
length first.

**Socket startup.** (1) create/`chmod` support dir 0700; (2) if `adeck.sock` exists: `connect()` to it —
success → throw `DaemonError.alreadyRunning` (never unlink a live daemon's socket); failure → `unlink`;
(3) `umask(0o177)` around `bind`, then `chmod 0600`; `listen(fd, 64)`; (4) `signal(SIGPIPE, SIG_IGN)` once
at process start **and** `setsockopt(SO_NOSIGPIPE)` on every accepted fd.

## 2. Wire protocol (hook ⇄ daemon)

Transport: AF_UNIX stream, minimal HTTP/1.1, **one request per connection**, every response carries
`Connection: close`. Host part of the URL is ignored (`http://adeck/...`).

### 2.1 Request headers (sent by `adeck-hook`)

| Header | Value | Daemon use |
|---|---|---|
| `X-Adeck-Hook-Pid` | live `adeck-hook` process ID | Held request liveness: a dead hook releases its request without applying a late decision. Hook watchdog closes orphaned curl waits; no tool is replayed. |
| `X-Adeck-Pid` | `$PPID` of `adeck-hook` (decimal) | liveness (`kill(pid,0)`), walk up ≤ 5 parents via `sysctl(KERN_PROC_PID)` to the first process named `claude` or `node`; else use as is. Non-numeric → nil. |
| `X-Adeck-Host` | `${__CFBundleIdentifier:-$TERM_PROGRAM}` | scoping + per-host presence (§7). Absent/empty → nil. |
| `X-Adeck-Entry` | `${CLAUDE_CODE_ENTRYPOINT}` | headless detection (§7 "from X-Adeck-Host and CLAUDE_CODE_ENTRYPOINT"). **[clarifies §5.2]**: the spec's script sends only Pid/Host, but §7 needs the entrypoint, so the hook adds this third header. Absent/empty → nil. |
| `Content-Length` | body bytes | required for POST (missing → `411`). |
| `Expect: 100-continue` | sent by curl for large bodies | daemon MUST immediately write `HTTP/1.1 100 Continue\r\n\r\n` and keep reading; otherwise curl stalls ~1 s and the 0.5 s step-1 budget fails open silently for large Write/Edit inputs. |

Limits: header block ≤ 16 KiB (else `431`), body ≤ 8 MiB (`Content-Length` larger → `413`, close without
reading), whole request must arrive within 2 s of accept (else close). Header names are case-insensitive.

### 2.2 Endpoints

| Method + path | Hooks accepted (`<Hook>`) | Response |
|---|---|---|
| `POST /v1/event/<Hook>` | `SessionStart SessionEnd UserPromptSubmit PostToolUse PostToolUseFailure Notification Stop SubagentStart SubagentStop PreCompact PermissionDenied` | `204 No Content`, empty body, always (also on undecodable JSON or unknown `<Hook>`: ingest skipped, still 204). |
| `POST /v1/gate/PreToolUse` | `PreToolUse` only | `200`, body = one step-1 verb (§2.3). Undecodable JSON → `PASS`. |
| `POST /v1/decide/PermissionRequest` | `PermissionRequest` only | `200`, body = one step-1 verb. Undecodable JSON → `PASS`. |
| `POST /v1/external/claim` | — | `200 {"claimed":true,"request_id":"…"}`, `404` no match, `409` ambiguous, `400` bad body. See §2.2.1. |
| `POST /v1/external/resolve` | — | `200 {"resolved":true}`, `404` no match, `409` already resolved, `403` refused by a guard, `400` bad body. See §2.2.1. |
| `GET /v1/wait/<id>` | — | `200` streaming (§2.4), or `404` for unknown/expired/already-attached id. |
| anything else | — | `404`, `Content-Length: 0`. |

Every gate/decide body is also ingested as an event (`.hook(.preToolUse)` / `.hook(.permissionRequest)`)
before the verb is computed. Internal error while computing a verb → `500` (hook fails open via `--fail`).

#### 2.2.1 `POST /v1/external/claim` + `resolve` (another approval channel won the race)

Same transport as every endpoint (the AF_UNIX socket, §1; no extra auth). Before contacting the external
channel, the client posts `{"session_id", "tool_name", "tool_input"}` to `claim`. The broker returns the
unique pending held `PermissionRequest` as `request_id`; no match is `404` and more than one match is `409`.
The client sends only that opaque id back to `resolve`:
`{"request_id", "verdict": "allow"|"deny", "message"?: string, "source": "slack"}`. The broker then calls `resolve` with
`DecisionSource.external(source)`. `allow` = allow-once, `deny` = deny with `message` as the deny message; no
`updatedPermissions`, `updatedInput` or answers are ever produced, and unknown body fields are ignored.
All §6 guards apply (e.g. an allow on a `.high` risk request is refused with `403`, the hold stays and the panel
can still answer). Outcomes: `200` resolved; `404` no pending match; `409` more than one match, or the matching
request was already resolved (finished permission requests are remembered 120 s); `400` bad verdict or body.
Raw tool input stays on the local AF_UNIX claim request and never goes to Slack or the resolve endpoint. A late
answer is bound to the claimed broker request id and cannot resolve a later identical request.
The request leaves the panel like any resolved one (status `allowed`/`denied`); the audit log line records
`source=external:<source>`.

### 2.3 Step-1 verbs (deadline: hook uses `curl -m 0.5`; daemon target ≤ 10 ms p95, §11)

Exact response bytes:

```
HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: <n>\r\nConnection: close\r\n\r\n<verb>
```

| Verb | Body | Meaning |
|---|---|---|
| `PASS` | `PASS` | pass through; hook prints nothing. |
| `DECIDE <json>` | `DECIDE ` + compact envelope (§3) | hook prints `<json>` verbatim. **v1 daemon never emits DECIDE** (§9.2: no auto-decisions); the hook still supports it and contract tests cover it. |
| `HOLD <id>` | `HOLD ` + id | held; hook must `GET /v1/wait/<id>` within **2 s**. |

Hold id: `UUID().uuidString` (36 chars, `[0-9A-F-]`). No trailing newline in any verb body.

Events: `HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n`.
Errors: `HTTP/1.1 <code> <reason>\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`.

### 2.4 Step 2: `GET /v1/wait/<id>` (hook uses `-m 595 --speed-limit 1 --speed-time 6`)

1. Unknown id, id already has a waiter, or id older than 2 s without a waiter (→ status `hookGone`) → `404`.
2. Otherwise write immediately:
   `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`
   followed at once by the first heartbeat.
3. **Heartbeat:** exactly 4 ASCII spaces (`0x20` ×4) every 1.0 s (first one at t=0). Under 1 byte/s for 6 s
   the client aborts (fail open, tested 6.06 s).
4. **Finish with a decision:** write the compact envelope JSON (§3) then close. Leading spaces are valid JSON.
5. **Release:** close after heartbeats only (body has no `{`). Release is the only "no decision": never
   `defer`, never `ask` (§7).
6. **Disconnect detection:** a read source on the fd; `read() == 0` or a failed heartbeat write (`EPIPE`)
   means the hook is gone → broker `waiterClosed(id:)` → status `handledElsewhere`. A failed write must never
   crash the process (SIGPIPE ignored, §1).
7. Daemon's own release timer: **590 s** after the request's `createdAt` → release, status `timedOut`.

### 2.5 Fail-open matrix (hook side; asserted by `hooks/tests/test-adeck-hook.sh`)

| Case | Expected |
|---|---|
| socket missing | exit 0, empty stdout, < 50 ms (after first exec) |
| `ADECK_NESTED` set | exit 0, empty stdout, no connect |
| daemon accepts, never answers (gate) | exit 0, empty, ≈ 0.5 s |
| daemon accepts, never answers (event) | exit 0, empty, ≈ 0.3 s |
| HTTP 500 | exit 0, empty |
| body not `PASS`/`DECIDE `/`HOLD ` | exit 0, empty |
| `PASS` | exit 0, empty |
| `DECIDE <json>` | exit 0, stdout == `<json>` byte-exact |
| `HOLD` → heartbeats → JSON | exit 0, stdout parses as the JSON |
| `HOLD` → heartbeats → close | exit 0, empty stdout |
| `HOLD` → no bytes for 6 s | exit 0, empty, 6–7 s |
| `HOLD` → wait 404 | exit 0, empty |
| SIGTERM while held | exit 0, no leftover curl process, no leftover temp file |

## 3. Decision envelopes (exact; F4, F12, §5.2)

Built with `JSONSerialization`/`JSONEncoder` from values, never by string interpolation. Compared in tests
by parsed-JSON equality, not bytes. Fixture files: `Tests/AgentDeckCoreTests/Fixtures/envelopes/<name>.json`.

| Fixture | Envelope |
|---|---|
| `permission-allow.json` | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| `permission-allow-always.json` | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[<chosen permission_suggestions entry, verbatim>]}}}` |
| `permission-deny.json` | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in AgentDeck: <note>"}}}` |
| `pretooluse-allow.json` | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved in AgentDeck"}}` |
| `pretooluse-deny.json` | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied in AgentDeck: <note>"}}` |
| `question-answer.json` | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Answered in AgentDeck","updatedInput":{<every key of the original tool_input, verbatim>,"answers":{"<question text>":"<answer>"}}}}` |

Rules:
- Deny text: note trimmed and capped at 500 chars; empty/nil note → exactly `"Denied in AgentDeck"` (no colon).
- `interrupt` is never set. `updatedInput` only on question answers; `updatedPermissions` only on allow-always.
- Multi-select answers: selected labels joined with `", "` in option order (**unverified; Phase 0 Q2 confirms**).
- "Other…" free text is used as the answer string as typed (trimmed).
- Allow-always exists only for `hook == .permissionRequest` with non-empty `suggestions`. Rule text shown on
  the card: for a suggestion `{"type":"addRules","rules":[{"toolName":T,"ruleContent":C}],…}` → `T(C)`
  (`T` alone when `ruleContent` absent), several rules joined by `", "`; any other shape → compact JSON.
- Release has no envelope (empty stdout).

## 4. Capability matrix (Phase 0 → Task 1)

Repo default: `config/capabilities.json`. Installer copies it to the runtime path (§1) **only if absent**.
The daemon reads the runtime path at start and on menubar "Reload"; missing/unreadable/invalid → all
categories channel 3.

```json
{
  "version": 1,
  "extensionVersion": "2.1.323",
  "measuredAt": null,
  "deepLink": "cursor://anthropic.claude-code/open?session={session}",
  "categories": {
    "Bash": 3, "EditWrite": 3, "Web": 3, "MCP": 3, "Question": 3, "ExitPlanMode": 3, "Other": 3
  }
}
```

- Tool → category: `Bash`→Bash; `Edit Write MultiEdit NotebookEdit`→EditWrite; `WebFetch WebSearch`→Web;
  prefix `mcp__`→MCP; `AskUserQuestion`→Question; `ExitPlanMode`→ExitPlanMode; anything else→Other.
- Allowed values: Bash/EditWrite/Web/MCP/Other ∈ {1,2,3}; Question ∈ {2,3} (2 = gate holds and answers via
  `updatedInput.answers`; 3 = read-only card with "Answer in Cursor ↗"); ExitPlanMode ∈ {3} (never approvable,
  §7). Missing key, other value or wrong type → 3. `version != 1` → all 3.
- Channel 3 (notify and jump) **always also runs as the backstop** regardless of the matrix (§7).
- `deepLink` must contain `{session}`; otherwise the default above is used. `{session}` is percent-encoded.

## 5. Swift contract (module `AgentDeckCore`)

All model types are `public`, value types, `Equatable` and `Sendable`, and every public struct declares an
explicit `public init` taking all stored properties in declaration order (optionals defaulting to `nil`,
collections to empty), because the app target imports the module without `@testable`. Core state (store, broker, server
callbacks) lives on one serial queue `DispatchQueue(label: "agentdeck.core")`; `SessionStore`,
`DecisionBroker` and `TranscriptTailer` are **not** thread-safe and are called only on that queue (tests
call them directly on the test thread). Time is injected via `Clock`; timers call `tick(now:)` every
100 ms from the daemon, never from inside these types.

```swift
// Model/JSONValue.swift
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public subscript(key: String) -> JSONValue? { get }      // nil unless .object containing key
    public var stringValue: String? { get }
    public func compactData() throws -> Data                 // JSONSerialization, no pretty print
}

// Model/Clock.swift
public protocol Clock: Sendable { func now() -> Date }
public struct SystemClock: Clock { public init() }

// Model/HookKind.swift
public enum HookKind: String, Codable, CaseIterable, Sendable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied"
    case postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure", notification = "Notification"
    case stop = "Stop", subagentStart = "SubagentStart", subagentStop = "SubagentStop", preCompact = "PreCompact"
}

// Ingest/HookInput.swift — decoded hook stdin (snake_case keys per F4/F13); unknown keys kept in `raw`
public struct HookInput: Equatable, Sendable {
    public var raw: [String: JSONValue]
    public var sessionId: String                 // session_id (required; missing → decode throws)
    public var transcriptPath: String?           // transcript_path
    public var cwd: String?
    public var permissionMode: String?           // permission_mode
    public var hookEventName: String?            // hook_event_name
    public var toolName: String?                 // tool_name
    public var toolInput: JSONValue?             // tool_input
    public var toolUseId: String?                // tool_use_id (absent on PermissionRequest, F4)
    public var agentId: String?                  // agent_id
    public var agentType: String?                // agent_type
    public var prompt: String?                   // prompt (UserPromptSubmit)
    public var lastAssistantMessage: String?     // last_assistant_message (Stop, SubagentStop)
    public var notificationType: String?         // notification_type (e.g. "permission_prompt", "idle_prompt")
    public var message: String?                  // message (Notification)
    public var permissionSuggestions: [JSONValue] // permission_suggestions, [] when absent
    public var mcpServer: String?                // mcp_server
    public var personOnly: Bool                  // raw["person_only"] == true; key name UNVERIFIED (Phase 0, F5)
    public static func decode(_ data: Data) throws -> HookInput
}

// Ingest/Ingest.swift
public struct HookMeta: Equatable, Sendable { public var pid: Int32?; public var host: String?; public var entrypoint: String? }
public enum Ingest {
    public static let previewLimit = 2048        // UTF-8 bytes, cut on a character boundary, then masked
    public static func event(_ hook: HookKind, _ input: HookInput, meta: HookMeta, now: Date) -> AgentEvent
}

// Model/AgentEvent.swift
public struct AgentEvent: Equatable, Sendable {
    public var sessionId: String
    public var agentId: String?
    public var agentType: String?
    public var kind: EventKind
    public var tool: String?
    public var toolUseId: String?
    public var inputPreview: String?   // ≤ Ingest.previewLimit, masked
    public var text: String?           // prompt | last_assistant_message | notification message | transcript text/title
    public var notificationType: String?
    public var permissionMode: String?
    public var model: String?          // from transcript message.model
    public var ts: Date
    public var pid: Int32?
    public var host: String?
    public var entrypoint: String?
    public var cwd: String?
    public var transcriptPath: String?
}
public enum EventKind: Equatable, Sendable {
    case hook(HookKind)
    case transcriptToolUse                          // toolUseId + tool set (hooks-degraded detection)
    case transcriptToolResult(isError: Bool)        // toolUseId set
    case transcriptAssistant                        // text and/or model set
    case transcriptTitle                            // text = title ("summary" line)
    case transcriptTasks(TaskProgress)
    case requestHeld(Request)                       // broker → store
    case requestUpdated(id: String, status: RequestStatus)
    case pidGone
    case tick                                       // never updates lastEventAt
}

// Model/Session.swift
public enum SessionState: String, Codable, Sendable {
    case idle, working, needsYou, waitingInCursor, yourTurn, error, ended, quiet
}
public struct TaskProgress: Codable, Equatable, Sendable { public var done: Int; public var total: Int }
public struct Step: Equatable, Sendable {
    public var label: String; public var tool: String; public var toolUseId: String?
    public var startedAt: Date; public var failed: Bool
}
public struct Agent: Equatable, Sendable, Identifiable {
    public var id: String; public var type: String     // type "" = internal, hidden (§6)
    public var state: SessionState                      // .working | .ended
    public var currentStep: Step?; public var stepCount: Int
    public var startedAt: Date; public var endedAt: Date?; public var summary: String?
}
public struct Session: Equatable, Sendable, Identifiable {
    public let id: String
    public var project: String            // basename(cwd), "" if unknown
    public var cwd: String
    public var transcriptPath: String?
    public var pid: Int32?
    public var host: String?
    public var entrypoint: String?
    public var title: String?             // transcript summary line (Phase 2)
    public var goal: String?              // first prompt, first line, ≤ 80 chars
    public var latestAsk: String?         // later prompts, first line, ≤ 80 chars
    public var model: String?
    public var state: SessionState
    public var currentStep: Step?
    public var stepCount: Int
    public var failureStreak: Int         // consecutive PostToolUseFailure; ≥ 3 → state .error
    public var progress: TaskProgress?    // only from real task updates (§6); never invented
    public var activity: [Int]            // 30 one-minute buckets of tool events, newest last
    public var summary: String?           // your-turn text: Stop last_assistant_message, ≤ 2 lines
    public var hooksDegraded: Bool        // transcript tool_use with no PreToolUse for it within 5 s (§14)
    public var subagents: [Agent]
    public var pending: [Request]         // oldest first
    public var startedAt: Date
    public var lastEventAt: Date
    public var endedAt: Date?
}

// Model/Channel.swift (created by plan Task 1)
public enum Channel: Int, Codable, Sendable { case race = 1, gate = 2, notify = 3 }

// Model/Request.swift
public enum RequestKind: String, Codable, Sendable { case permission, question, planReview }
public enum RiskLevel: String, Codable, Comparable, Sendable { case low, med, high }
public struct Risk: Equatable, Sendable { public var level: RiskLevel; public var reason: String }
public enum RequestStatus: String, Codable, Sendable {
    case pending, allowed, denied, answered, movedToCursor, timedOut, handledElsewhere, hookGone
}
public struct Request: Equatable, Sendable, Identifiable {
    public let id: String                 // == HOLD id; notices (channel 3) get a UUID too
    public let sessionId: String
    public let agentId: String?
    public let kind: RequestKind
    public let hook: HookKind             // .permissionRequest | .preToolUse | .notification (notice source)
    public let tool: String
    public let toolUseId: String?         // channel 1: copied from the matching PreToolUse (§6 of this file)
    public let preview: String            // StepLabel, masked
    public let fullInput: JSONValue       // memory only: never logged, never in sessions.json
    public let risk: Risk
    public let suggestions: [JSONValue]   // permission_suggestions verbatim
    public let personOnly: Bool
    public let channel: Channel           // .notify = no hook held; only "Open ↗" (and Dismiss)
    public let createdAt: Date
    public var status: RequestStatus
}

// Model/Presence.swift
public enum Presence: String, Sendable { case present, away }
public struct PresenceSnapshot: Equatable, Sendable {
    public var frontmostBundleId: String?; public var idleSeconds: Double; public var at: Date
}

// Model/AppSettings.swift (persisted by the app in UserDefaults key "AppSettings" as JSON)
public enum GateScope: String, Codable, Sendable { case automatic, full, riskyOnly } // automatic = riskyOnly when permission_mode == "auto", else full
public struct AppSettings: Codable, Equatable, Sendable {
    public var cursorBundleIds: [String] = ["com.todesktop.230313mzl4w4u92"]
    public var gateOtherHosts: Bool = false        // "a setting adds them" (§7)
    public var awayThresholdSeconds: Double = 20
    public var gateScope: GateScope = .automatic
    public var awayMode: Bool = false
    public var quiet: Bool = false
    public var privacy: Bool = false
    public var paused: Bool = false
    public var sounds: Bool = true
    public var summarizer: Bool = false
    public var launchAtLogin: Bool = false
    public init()
}

// Decision path
public enum Decision: Equatable, Sendable {
    case allow
    case allowAlways(suggestion: JSONValue)
    case deny(note: String?)
    case answer([String: String])                  // question text → answer
}
public enum DecisionSource: String, Sendable { case click, holdConfirmed, hotkey, notification }
public enum ResolveResult: Equatable, Sendable {
    case applied
    case dropped(DropReason)
}
public enum DropReason: String, Error, Sendable {
    case unknownOrResolved, personOnly, needsHoldConfirm, notAllowedFromSource, notApplicable
}
public enum GateVerb: Equatable, Sendable {
    case pass, decide(Data), hold(id: String)
    public var wireBody: String { get }            // "PASS" | "DECIDE <json>" | "HOLD <id>"
}

// Broker/Envelopes.swift
public enum Envelopes {
    public static func data(for request: Request, decision: Decision) throws -> Data  // throws DropReason.notApplicable as error for invalid combos
    public static func ruleText(for suggestion: JSONValue) -> String                  // §3 "Allow always" rule text, used by the UI
}

// Risk/RiskRules.swift, Risk/Masking.swift, Reducer/StepLabel.swift, Presence/PresenceRules.swift
public enum RiskRules { public static func classify(tool: String, input: JSONValue, cwd: String) -> Risk }
public enum Masking { public static func mask(_ s: String) -> String }    // Bearer …, sk-…, AKIA… → first 4 chars + "••••"
public enum StepLabel { public static func label(tool: String, input: JSONValue) -> String }
public enum PresenceRules {
    public static func presence(host: String?, snapshot: PresenceSnapshot, settings: AppSettings) -> Presence
}

// Broker/CapabilityMatrix.swift
public enum ToolCategory: String, CaseIterable, Sendable { case Bash, EditWrite, Web, MCP, Question, ExitPlanMode, Other }
public struct CapabilityMatrix: Equatable, Sendable {
    public var channels: [ToolCategory: Channel]
    public var deepLinkTemplate: String
    public static let fallback: CapabilityMatrix                 // every category .notify, default deepLink
    public static func load(from url: URL) -> CapabilityMatrix   // never throws; invalid → fallback rules (§4)
    public static func category(forTool tool: String) -> ToolCategory
    public func channel(forTool tool: String) -> Channel
    public func deepLink(sessionId: String) -> URL
}

// Broker/SettingsRules.swift — read-only view of Claude Code permission rules
public struct SettingsRules: Equatable, Sendable {
    public var allow: [String]; public var deny: [String]
    // merges permissions.allow/deny from ~/.claude/settings.json, <cwd>/.claude/settings.json,
    // <cwd>/.claude/settings.local.json; unreadable files are skipped
    public static func load(home: URL, cwd: String) -> SettingsRules
    public func mayDeny(tool: String, input: JSONValue) -> Bool      // any deny rule naming this tool (errs true)
    public func simplyAllows(tool: String, input: JSONValue) -> Bool // exact tool name, or Bash(prefix:*) prefix match only
}

// Reducer/Reducer.swift, Reducer/SessionStore.swift
public enum Reducer { public static func apply(_ session: Session?, _ event: AgentEvent) -> Session }
public final class SessionStore {
    public init()
    public private(set) var sessions: [String: Session]
    public func apply(_ event: AgentEvent)                 // reducer + 2-min removal of ended sessions on .tick
    public var ordered: [Session] { get }                  // needsYou first, then lastEventAt desc
}

// Broker/DecisionBroker.swift
public protocol HoldWaiter: AnyObject { func finish(_ body: Data?) }  // nil = release (close after heartbeats)
public final class DecisionBroker {
    public init(clock: Clock, matrix: CapabilityMatrix, settings: AppSettings,
                rules: @escaping (_ cwd: String) -> SettingsRules,
                emit: @escaping (AgentEvent) -> Void)           // .requestHeld / .requestUpdated → store
    public func update(settings: AppSettings)
    public func update(matrix: CapabilityMatrix)
    public func update(presence: PresenceSnapshot)
    public func gate(_ input: HookInput, meta: HookMeta) -> GateVerb       // /v1/gate/PreToolUse
    public func decide(_ input: HookInput, meta: HookMeta) -> GateVerb     // /v1/decide/PermissionRequest
    public func attach(id: String, waiter: HoldWaiter) -> Bool             // /v1/wait/<id>; false → 404
    public func waiterClosed(id: String)                                   // socket closed → handledElsewhere
    public func resolve(id: String, decision: Decision, source: DecisionSource) -> ResolveResult
    public func dismiss(id: String)                                        // channel-3 notices only
    public func observe(_ event: AgentEvent)                               // every ingested/transcript event
    public func tick(now: Date)                                            // 2 s hookGone, 3 s presence release, 6 s backstop, 590 s release
    public var pending: [Request] { get }
}

// IPC/HTTP.swift, IPC/SocketServer.swift
public struct HTTPRequest: Equatable, Sendable {
    public var method: String; public var path: String
    public var headers: [String: String]            // keys lower-cased
    public var body: Data
}
public enum HTTPParse: Equatable { case needMore, expectContinue, complete(HTTPRequest, consumed: Int), error(status: Int) }
public enum HTTPParser { public static func parse(_ buffer: Data, maxHeader: Int = 16_384, maxBody: Int = 8_388_608) -> HTTPParse }
public final class Connection {                      // one accepted fd; all callbacks on the core queue
    public func respond(status: Int, body: Data, contentType: String?)   // writes, then closes
    public func startStream(contentType: String)                          // 200 headers, no Content-Length
    public func write(_ data: Data) -> Bool                               // false on EPIPE/closed
    public func close()
    public var onClose: (() -> Void)?                                     // peer closed or write failed
}
public final class SocketServer {
    public init(path: String, queue: DispatchQueue, handler: @escaping (HTTPRequest, Connection) -> Void)
    public func start() throws                       // §1 startup rules; throws DaemonError
    public func stop()                               // closes fds, unlinks socket
}
public enum DaemonError: Error, Equatable { case socketPathTooLong(bytes: Int), alreadyRunning, bindFailed(errno: Int32) }

// Daemon/WaitStream.swift — HoldWaiter over a Connection: startStream, 4 spaces now and every 1.0 s,
// finish(json) → write json + close; finish(nil) → close; onClose → broker.waiterClosed(id:)
public final class WaitStream: HoldWaiter { public init(connection: Connection, queue: DispatchQueue, onClosed: @escaping () -> Void) }

// Daemon/Daemon.swift — the only type the app talks to
public struct AppPaths: Equatable, Sendable {
    public var supportDir: URL; public var socket: URL; public var capabilities: URL
    public var snapshot: URL; public var logFile: URL; public var home: URL
    public static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPaths
}
public final class Daemon {
    public init(paths: AppPaths, settings: AppSettings, clock: Clock = SystemClock())
    public func start() throws
    public func stop()
    public var onChange: (([Session]) -> Void)?       // delivered on main queue, coalesced ≤ every 50 ms
    public func update(settings: AppSettings)
    public func update(presence: PresenceSnapshot)
    public func reloadMatrix()
    public var matrix: CapabilityMatrix { get }       // for deep links in the UI
    public func resolve(requestId: String, decision: Decision, source: DecisionSource,
                        completion: @escaping (ResolveResult) -> Void)    // completion on main
    public func dismiss(requestId: String)
}
```

Support types (core part; consumed by the broker part's `Daemon`):

```swift
// Liveness/Liveness.swift
public enum Liveness {
    public static func resolveClaudePid(_ pid: Int32) -> Int32   // walk ≤ 5 parents to "claude"/"node", else pid
    public static func isAlive(_ pid: Int32) -> Bool             // kill(pid, 0) == 0 || errno == EPERM
    public static let checkInterval: TimeInterval = 30
}
// Model/MetaLog.swift — metadata only (never tool input), rotates to .1 at maxBytes
public final class MetaLog { public init(url: URL, maxBytes: Int = 5_242_880); public func write(_ line: String) }
// Model/SnapshotIO.swift — id, project, cwd, transcriptPath, pid, host, entrypoint, title, goal, model,
// startedAt, lastEventAt only; loaded sessions start in state .idle with empty pending
public enum SnapshotIO {
    public static func save(_ sessions: [Session], to url: URL) throws
    public static func load(from url: URL) -> [Session]          // missing/corrupt → []
}
```

Constants (frozen): present = host frontmost ∧ idle < 20 s; presence release 3 s; hook-gone 2 s;
backstop 6 s; release 590 s; quiet after 1800 s without events (pid alive); ended sessions removed 120 s after
`endedAt`; goal/latestAsk ≤ 80 chars; error at `failureStreak ≥ 3`; summary ≤ 2 lines.

Phase 2 additions (owned by the core part; signatures frozen here):

```swift
public final class TranscriptTailer {               // core queue
    public init(emit: @escaping (AgentEvent) -> Void)
    public func track(sessionId: String, path: String)   // idempotent; starts at offset 0 on first track
    public func untrack(sessionId: String)
    public func poll()                                    // reads appended bytes only; called from DispatchSource or tick
    public static let maxLine = 262_144                   // lines over 256 KB skipped
}
public enum TranscriptParser { public static func events(fromLine line: Data, sessionId: String, now: Date) -> [AgentEvent] }
public protocol SummarizerRunner { func run(prompt: String, completion: @escaping (String?) -> Void) }
public final class Summarizer {                     // off unless settings.summarizer; never in decision path
    public init(runner: SummarizerRunner, clock: Clock)
    public func request(session: Session, completion: @escaping (String?) -> Void)  // debounced: ≤ 1 per session per 120 s; cached
}
// Live runner command: env ADECK_NESTED=1 claude -p --model claude-haiku-5-5 --settings '{"disableAllHooks":true}'
```

UI-only pure logic (card queue, arming, attention ladder, corner snap) lives in
`Sources/AgentDeckCore/UIModel/` so it is unit-testable; its signatures are owned by the UI part.

## 6. Broker semantics (frozen rules the broker part implements and the UI relies on)

**Scoping** (checked first, both endpoints):
1. `settings.paused` → `PASS`.
2. `meta.entrypoint` has prefix `sdk` (e.g. `sdk-cli`, `sdk-ts`, `sdk-py`) → headless → `PASS`, never a notice.
3. `meta.host ∉ settings.cursorBundleIds` and `!settings.gateOtherHosts` → shown only → `PASS`, never a notice.
   nil host counts as not-Cursor. **[clarifies §7]** unknown entrypoint (nil) is treated as interactive.

**`decide` (PermissionRequest):** correlate to the most recent PreToolUse with the same
`(sessionId, agentId, toolName, toolInput)` seen ≤ 30 s earlier and copy its `tool_use_id`.
- category channel == `.race` → `HOLD`; request `channel = .race`. Presence changes only attention (UI).
- otherwise → `PASS` and create a `.notify` notice at once (a PermissionRequest firing proves a native prompt
  is showing).
- ExitPlanMode → `PASS` + `.notify` notice of kind `.planReview`.

**`gate` (PreToolUse):**
- `ExitPlanMode` → `PASS` + `.planReview` notice.
- `AskUserQuestion`: Question channel `.gate` and presence `.away` → `HOLD`, kind `.question`, channel `.gate`;
  otherwise `PASS` (+ `.notify` question notice when away).
- other tools with category channel `.gate`: `PASS` when any holds — presence `.present`; `permission_mode`
  ∈ {`bypassPermissions`,`plan`,`dontAsk`}; `acceptEdits` and tool ∈ {Edit, Write, MultiEdit, NotebookEdit};
  tool read-only (Read, Grep, Glob, LS, TodoWrite, TaskCreate, TaskUpdate, TaskList, TaskGet); `rules.mayDeny`;
  `rules.simplyAllows`; effective scope riskyOnly and risk `.low`. Otherwise `HOLD`, channel `.gate`.
  `settings.awayMode` forces `.away`.
- category channel `.race` or `.notify` → `PASS`.
- Backstop (channel 3, always): every PreToolUse of a tool not in {Bash, Task, Agent, WebFetch, WebSearch,
  mcp__*} that has no PostToolUse/PostToolUseFailure/PermissionDenied/transcript tool_result for its
  `tool_use_id` within 6 s → `.notify` notice. A `Notification` with `notification_type == "permission_prompt"`
  → `.notify` notice for that session (if no held/notice request already covers it).

**Resolution** (`resolve`): one-shot, bound to `id`. Unknown or non-pending id → `.dropped(.unknownOrResolved)`.
`.allow`/`.allowAlways`/`.answer` on `personOnly` → `.dropped(.personOnly)`. Allow on risk `.high` unless
`source == .holdConfirmed` → `.dropped(.needsHoldConfirm)`. Any allow from `.notification` →
`.dropped(.notAllowedFromSource)`. `.answer` on non-question, `.allowAlways` without suggestions or on
`.gate`, any decision on a `.notify` request → `.dropped(.notApplicable)`. Applied → `waiter.finish(envelope)`,
status `allowed|denied|answered`, emit `.requestUpdated`.

**Release and expiry** (`tick`):
- held, no waiter 2 s after `HOLD` → `hookGone` (removed, no card).
- `.gate` request whose host has been `.present` continuously ≥ 3 s → `finish(nil)`, `movedToCursor`.
- 590 s after `createdAt` → `finish(nil)`, `timedOut`.

**Handled elsewhere** **[clarifies §5.2 step 3 / §7.4]**: the spec's "any newer event for the same session"
would wrongly resolve a held request on the `Notification(permission_prompt)` that fires ~6 s into every
unanswered ask (F14) and on async PostToolUse of parallel tool calls. Frozen rule — a held request becomes
`handledElsewhere` only on: socket close (`waiterClosed`); PostToolUse / PostToolUseFailure / PermissionDenied /
transcript tool_result whose `toolUseId` equals the request's; or UserPromptSubmit, Stop, SessionEnd,
`.pidGone` for the same session (SubagentStop for the same `agentId`). Notices resolve the same way, or on
`dismiss`.

**Restart:** pending requests are never persisted; a request whose connection dropped is discarded.

## 7. settings.json merge and uninstall (§5.2, §9.7)

Implemented in `installer/adeck_settings.py` (python3 stdlib, run as `python3 -I`), driven by
`installer/install.sh` and `installer/uninstall.sh`. All paths derive from `$HOME`; tests always run with
`HOME` set to a temp dir.

- **Ownership marker:** a hook entry is AgentDeck's iff its `command` contains `/.agentdeck/bin/adeck-hook`.
- **Entries** (exactly §5.2 plus `PostToolUseFailure`, which §6 needs **[clarifies §5.2]**):
  - `PermissionRequest`: `{"matcher":"*","hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook decide PermissionRequest","timeout":600}]}`
  - `PreToolUse`: `{"matcher":"*","hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook gate PreToolUse","timeout":600}]}`
  - `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`: `{"matcher":"*","hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook event <Hook>","async":true}]}`
  - `UserPromptSubmit Stop SubagentStart SubagentStop Notification SessionStart SessionEnd`:
    `{"hooks":[{"type":"command","command":"~/.agentdeck/bin/adeck-hook event <Hook>","async":true}]}`
- **Install/merge:** missing file → start from `{}` (no backup). Invalid JSON or non-object `hooks` → exit 2,
  no write. Otherwise back up first (§1 name), then per event: remove any existing AgentDeck hook entries
  (drop a matcher group only if it becomes empty because of that), append our group at the end. Foreign
  entries, foreign groups and all other keys keep their order and values. Write 2-space-indented JSON + `\n`
  via temp file + `os.replace`, preserving the original file mode. **Idempotent:** a second install is
  byte-identical.
- **Uninstall:** back up, remove only AgentDeck entries; remove a group, an event key or the `hooks` key only
  when it became empty because of a removal. For any input with no empty hook arrays,
  install → uninstall is JSON-equal to the original. Leaves `~/.agentdeck` and App Support data unless `--purge`.
- **Warning (§9.8):** install prints to stderr every foreign `PreToolUse` hook command with
  "may return updatedInput after you approve in AgentDeck (Channel 2)".
- **Install also:** copies `hooks/adeck-hook` → `~/.agentdeck/bin/adeck-hook` (0755); runs it once with no
  socket (first-exec scan, §13); creates the support dir 0700; copies `config/capabilities.json` to the
  runtime path if absent. Never touches Cursor/VS Code settings; never enables Remote Control.

## 8. Repository layout and part ownership

```
/Users/ritesh.raj/Documents/agent-deck/
  Package.swift                      swift-tools-version:5.9, platforms [.macOS(.v14)], no dependencies
  config/capabilities.json           (core)
  Sources/AgentDeckCore/             library target; Foundation + Darwin + CoreGraphics only (no AppKit)
    Model/ Ingest/ IPC/ Reducer/ Risk/ Presence/ Liveness/ Transcript/ Summarizer/   (core)
    Broker/ Daemon/                                                                    (broker)
      except Broker/CapabilityMatrix.swift and Model/Channel.swift: core, plan Task 1
    UIModel/                                                                           (ui)
  Sources/AgentDeckApp/              executable target (AppKit, SwiftUI, Carbon, UserNotifications, ServiceManagement)   (ui)
  Tests/AgentDeckCoreTests/          XCTest; resources: .copy("Fixtures")
    Support/FakeClock.swift          (core)
    Fixtures/hooks/<Hook>.json       synthetic until Phase 0 captures replace them (core)
    Fixtures/envelopes/*.json        (broker)
    Fixtures/transcripts/*.jsonl     (core)
    Model/ Ingest/ IPC/ Reducer/ Risk/ Presence/ Liveness/ Transcript/ Summarizer/   (core)
    Broker/ Daemon/                                                                    (broker)
      except Broker/CapabilityMatrixTests.swift: core, plan Task 1
    UIModel/                                                                           (ui)
    Contract/HookDaemonContractTests.swift   real adeck-hook ⇄ real Daemon (hooks)
  hooks/adeck-hook                   POSIX sh (hooks)
  hooks/tests/test-adeck-hook.sh, hooks/tests/fake_daemon.py                          (hooks)
  installer/install.sh, installer/uninstall.sh, installer/adeck_settings.py           (hooks)
  installer/tests/test-installer.sh, installer/tests/fixtures/*.json                  (hooks)
  Resources/Info.plist, scripts/bundle.sh   → build/AgentDeck.app (ad-hoc signed)    (ui)
```

- Spec §10.2 says `Sources/Core/` and `Sources/UI/`; this layout maps them to the SwiftPM default paths of the
  targets `AgentDeckCore` and `AgentDeckApp`.
- `Package.swift` is created by plan Task 1 (core part) with all three targets; the UI part's first task adds
  nothing to it except, if needed, `linkerSettings` on `AgentDeckApp`.
- `Sources/AgentDeckApp/main.swift` is created as a one-line placeholder by Task 1 (so the package builds) and
  replaced by the UI part's first task. Hotkey bindings are UI-owned and stored in UserDefaults key `Hotkeys`.
- App bundle id: `local.agentdeck.AgentDeck`; `LSUIElement = true`; `LSMinimumSystemVersion = 14.0`.
- Commands: `swift build`, `swift test` (from the project root), `sh hooks/tests/test-adeck-hook.sh`,
  `sh installer/tests/test-installer.sh`, `sh scripts/bundle.sh`.

### 2026-11-14 validation amendment

Register PermissionDenied as a twelfth asynchronous, tool-matched event. Installed extension schemas 2.1.319/322/323 accept it. Per the official hooks reference, it fires for auto-mode denials, not manual denial, a PreToolUse block, or deny-rule matches. It clears the matching backstop without returning a retry decision.
Source: https://code.claude.com/docs/en/hooks#permissiondenied
