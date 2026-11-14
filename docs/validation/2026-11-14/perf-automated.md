# Automated regression and performance evidence

Date 2026-11-14. Machine: macOS 26.7.1, Apple Silicon, Swift 5.9.2 / Xcode 15.2.

**These are harness numbers, not live-app acceptance.** They use the real `Daemon`, the real unix socket and the real
`hooks/adeck-hook`, but run in a debug test process (release shown once) with a Python fake daemon for the hook scripts. The
spec section 11 targets for the running AgentDeck app (idle CPU, RSS, gate p95, event-to-card, hook p95) are not covered here; measure them on the live app with `scripts/measure-idle.sh`. Other builds were running and testing on the
same machine, so the tails (max, p95 of the noisier runs) include contention.

## 1. Swift perf tests over the real socket

File: `Tests/AgentDeckCoreTests/Perf/PerfDaemonTests.swift` (3 tests, every number printed with the prefix `PERF:`).

```
swift test --filter PerfDaemonTests 2>&1 | grep -E "PERF:|Executed"
swift test -c release -Xswiftc -enable-testing --filter PerfDaemonTests   # release config, once
```

| Measurement | Debug (4 runs, range) | Release (1 run) | Threshold (not loosened) |
|---|---|---|---|
| Gate PASS, 200 requests, connect+send+read to EOF (read-only tool `Read`, gate channel enabled so the full broker gate path runs, 10 warm-up) | p50 0.7 ms, p95 0.9-1.1 ms (one contended run: 1.3 / 3.9 ms), max 1.2-1.8 ms (contended 15.6 ms) | p50 0.3, p95 0.6, max 0.8 ms | p95 <= 10 ms: **PASS** in every run |
| Event to store, 200 `PostToolUse` over 10 sessions, send until the `onChange` snapshot shows that session's `lastEventAt` at or after the send | p50 53-55 ms, p95 58-59 ms (contended 67 ms), max 63-94 ms | p50 53.9, p95 58.2, max 63.4 ms | p95 <= 300 ms: **PASS** |
| 10 sessions x 5 held requests (50), resolve to that hook's EOF | p50 0.5-0.9 ms, p95 0.9-2.0 ms, max 1.4-2.3 ms | p50 0.4, p95 1.1, max 1.2 ms | none (isolation test) |

Notes on the event number: the daemon coalesces store changes to one `onChange` per 50 ms (`Daemon.changed()`), so about 50 ms of
the figure is the designed coalescing delay, not processing. "Store" is observed through that callback because the `SessionStore`
is private. Sequential sends, so this is per-event latency, not burst throughput.

The 50-request isolation test asserts, using real sockets and `h.resolve`:
- all 50 hold ids unique; each session's pending list holds exactly its 5 requests in issue order (FIFO), each bound to its own
  session id and command (`echo s<i>-r<j>`);
- no wait ended before any resolve; resolving request (3,2) with a note ended only that wait and removed only that card;
- late and double resolve of the same id returns `.dropped(.unknownOrResolved)` and changes nothing;
- the other 49 resolve in FIFO order per session, interleaved across sessions, each wait receives exactly its own envelope
  (allow, or deny carrying its own `n-s<i>-r<j>` note); afterwards all 50 late resolves are dropped; 50 `requestUpdated` events.
  Printed: `PERF: held_isolation sessions=10 requests=50 cross_session_resolutions=0 late_resolves_dropped=50`.

Red evidence (tests can fail): with the p95 threshold temporarily set to 30 ms the event test failed (59.2 > 30), and with the expected
FIFO order reversed the isolation test failed on every session; the file was restored afterwards.

## 2. SIGKILL of the hook shell while held

```
sh hooks/tests/test-sigkill.sh
```

Runs the unmodified `hooks/tests/fake_daemon.py` in `hold-silent` mode (HOLD, then a wait that sends nothing). `run_daemon.py` (written to the temp HOME)
exec's that file with one in-memory change: the silent wait polls its socket and records when `recv` returns EOF, as the real
`WaitStream` does. Then it runs `hooks/adeck-hook decide PermissionRequest`, `kill -9`s the hook shell while held, and observes.

Measured (run 3 times; 5.92-5.93 s, 6.06 s orphan exit):

| What | Result |
|---|---|
| Hook shell after SIGKILL | dead, its `trap` never ran |
| `curl` child | **survives**, reparented to launchd (ppid 1) |
| Temp file (`mktemp -t adeck`, `curl -o`) | **survives** (0 bytes), the script removes it in cleanup |
| Orphan exit | by itself at curl's `--speed-time 6` abort: 5.96-6.06 s after the kill |
| Daemon side sees socket close (recv EOF) | 5.92-5.93 s after the kill (5.94-5.95 s after the wait attached): **<= 7 s PASS** |

So this is the documented SIGKILL limit, not a pass of orphan cleanup: for up to about 6 s an orphan curl keeps the wait connection open and the
temp file leaks permanently. With the real daemon the card would then resolve as "Handled elsewhere" when the connection closes
(`waiterClosed`) or earlier on any matching newer event for that session (spec section 6; covered by `HookKilledWhileHeldTests`, which uses SIGTERM, plus
`DaemonRoutingTests`). A fix, if wanted, belongs in `hooks/adeck-hook` (out of scope for this run): e.g. have curl write to a fixed per-run path that
the next hook run sweeps.

Side finding: on this macOS, `mktemp -t` ignores `$TMPDIR` and writes to the per-user temp dir
(`/var/folders/.../T`). `hooks/tests/test-adeck-hook.sh` checks `ls "$TMPDIR" | grep '^adeck'` after SIGTERM, which therefore looks
in the wrong directory and cannot detect a leaked file. `test-sigkill.sh` reads the real file name from curl's `-o` argument instead.

## 3. Latency and idle scripts

```
sh scripts/measure-hook-latency.sh 200
sh scripts/measure-idle.sh <pid> <minutes> <out.csv>     # CSV columns: epoch,ps_cpu_pct,rss_kb,cputime,cputime_s,top_cpu_pct,top_idlew
```

Hook wall time (200 runs after 5 warm-up, one perl process times fork+exec of `/bin/sh hooks/adeck-hook`; fake Python daemon in `pass` mode;
second run in parentheses):

| Path | p50 | p95 | max |
|---|---|---|---|
| missing socket (exits at the `[ -S ]` test) | 4.4 ms (4.2) | 5.2 ms (4.9) | 5.7 ms (5.0) |
| event (`/v1/event`, curl -m 0.3) | 14.7 ms (14.1) | 18.0 ms (15.4) | 48.3 ms (16.4) |
| gate PASS (`/v1/gate`, curl -m 0.5) | 15.1 ms (14.6) | 17.7 ms (16.1) | 52.6 ms (16.3) |

Spec target for the hook is <= 25 ms p95 (event: 0 ms with async registration): met in this harness. This is wall time of the shell script
plus curl against a Python daemon; it does not include Claude Code's own hook spawn, and the real daemon is faster than the Python stub.

Idle sampler: **not run against the live app** (out of scope for this run). Self-check against an idle fake-daemon process for 60 s (7 samples):
median/p95 ps CPU 0.0/0.2%, top CPU 0.0/0.0%, max RSS 18400 KiB, CPU-time delta 0.00 s over 60 s, 0 idle wakeups. Earlier check against a
100 Hz perl timer for 30 s gave 1.2 wakeups/s and 0.13% CPU, showing the sampler registers activity. `top`'s IDLEW is a cumulative counter (it
grows monotonically within and across `top -l N` samples), so the script reports last minus first over the window; the exact meaning
of IDLEW (package idle wakeups) is Apple's, treat it as indicative. `ps %cpu` is the OS's smoothed figure, so the strict number is the CPU-time
delta line. Use for the live app (lead only, read-only): `sh scripts/measure-idle.sh $(pgrep -x AgentDeck) 10 /tmp/agentdeck-idle.csv`.

## 4. Gate in the workspace

| Gate | Result |
|---|---|
| `swift build` | Build complete |
| `swift test` (whole suite) | 312 tests, 0 failures (39.0 s, includes the 3 new Perf tests) |
| `sh hooks/tests/test-adeck-hook.sh` | ALL GREEN |
| `sh installer/tests/test-installer.sh` | ALL GREEN |
| `sh hooks/tests/test-sigkill.sh` | all observations recorded, exit 0 (reports behaviour, see section 2) |

## Not covered

Live-app numbers (idle CPU/RSS over 10 minutes, battery, real gate p95, event-to-card on screen), real Cursor or Claude hook spawn cost,
SIGKILL with the real daemon and app (only the fake daemon and the daemon's existing SIGTERM test), burst throughput beyond 50 held requests.
