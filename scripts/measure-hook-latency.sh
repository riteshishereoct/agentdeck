#!/bin/sh
# Wall time of the REAL hooks/adeck-hook against hooks/tests/fake_daemon.py: event, gate PASS, missing socket.
# Usage: scripts/measure-hook-latency.sh [N=100]. Offline, temp HOME; prints "HOOKLAT:" lines (p50/p95/max in ms).
# Harness numbers only: the fake daemon is Python, the real app's daemon is not in the path.
N=${1:-100}; case $N in ''|*[!0-9]*) echo "usage: $0 [N]" >&2; exit 2;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd); HOOK="$ROOT/hooks/adeck-hook"; FX="$ROOT/Tests/AgentDeckCoreTests/Fixtures/hooks"
HOME=$(mktemp -d /tmp/adk.XXXXXX); export HOME
SUP="$HOME/Library/Application Support/AgentDeck"; mkdir -p "$SUP"; SOCK="$SUP/adeck.sock"; DPID=
export __CFBundleIdentifier=com.todesktop.230313mzl4w4u92 CLAUDE_CODE_ENTRYPOINT=claude-vscode
trap '[ -n "$DPID" ] && kill $DPID 2>/dev/null; rm -rf "$HOME"' EXIT
# One perl process times every run (no per-sample process-spawn overhead beyond the hook itself).
time_runs() {   # label n kind hook-event fixture
  perl -MTime::HiRes=time -e '
    my ($label, $n, $kind, $ev, $fx, $hook) = @ARGV; my @t;
    for my $i (-5 .. $n - 1) {                       # 5 warm-up runs: first exec of a new file is slow (spec §13)
      my $t0 = time; my $pid = fork;                  # fork+exec directly: no extra "sh -c" layer in the sample
      if (!$pid) { open STDIN, "<", $fx; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null"; exec "/bin/sh", $hook, $kind, $ev; exit 127 }
      waitpid $pid, 0; my $ms = (time - $t0) * 1000;
      push @t, $ms if $i >= 0;
    }
    @t = sort { $a <=> $b } @t; my $p = sub { $t[ int(($_[0] * @t) - 1e-9) ] };
    printf "HOOKLAT: %-16s n=%d p50=%.1fms p95=%.1fms max=%.1fms\n", $label, scalar @t, $p->(0.5), $p->(0.95), $t[-1];
  ' "$1" "$2" "$3" "$4" "$5" "$HOOK"
}
GATE="$FX/PreToolUse-Bash.json"; POST="$FX/PostToolUse.json"
time_runs "missing-socket" "$N" gate PreToolUse "$GATE"
LOG="$HOME/req.log"; python3 -I "$ROOT/hooks/tests/fake_daemon.py" "$SOCK" pass "$LOG" & DPID=$!
i=0; while [ ! -S "$SOCK" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
[ -S "$SOCK" ] || { echo "fake daemon did not start" >&2; exit 1; }
time_runs "event" "$N" event PostToolUse "$POST"
time_runs "gate-PASS" "$N" gate PreToolUse "$GATE"
echo "HOOKLAT: daemon requests served: $(wc -l < "$LOG" | tr -d ' ') (expected $((2 * (N + 5))))"
echo "HOOKLAT: spec targets: hook overhead <= 25 ms p95 (event: 0 ms with async); these are harness numbers, not live-app acceptance"
