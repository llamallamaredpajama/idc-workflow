#!/bin/bash
# idc-assert-class: behavior
# gh-call-timeout-bound.sh — every `gh` child is BOUNDED, and the bound is exercised, not just typed.
#
# Two shipped call sites bound their `gh` subprocess: idc_recirc_sweep.gh (the sweep + the CLI paths,
# including the seen ledger's board-corroboration read) and idc_gh_board._gh (every board read, plus
# its free rate-limit preflight). Both take `timeout=GH_TIMEOUT_S`. Nothing under tests/ referenced
# GH_TIMEOUT_S at all, so deleting either `timeout=` broke no test — and the failure mode of that
# deletion is the worst possible one for a test suite: a HANG. A hung `gh` (network stall, an auth
# prompt on a headless box) does not fail; it reads as a slow pass, and CI eventually dies somewhere
# unrelated. So this scenario asserts the bound BEHAVIOURALLY and treats a hang as RED:
#
#   * a fake `gh` first on PATH that just sleeps, with GH_TIMEOUT_S monkeypatched to 2s;
#   * `idc_recirc_sweep.gh` must return ok=False carrying "timed out after 2s" (never hang, never
#     claim success), and `idc_gh_board._gh` must raise BoardReadError carrying the same;
#   * the POSITIVE CONTROL is the same probe against a fake `gh` that answers instantly — it must
#     succeed and must NOT carry that marker, so the marker can only come from the bound firing;
#   * both run through assert_fail_closed, which runs them under an explicit outer timeout well
#     short of the fake gh's sleep. An unbounded call therefore reddens as "did not terminate"
#     instead of quietly costing 45s.
#
# Hermetic: the fake `gh` binaries are the only ones on PATH for the probes, so this never touches a
# network, a credential, or a real board.
#
# Red-when-broken (observed): drop `timeout=GH_TIMEOUT_S` from idc_recirc_sweep.gh's subprocess.run
#   => the probe never returns and assert_fail_closed reds with "did not terminate within 20s".
#   Same for idc_gh_board._gh. Make idc_recirc_sweep.gh swallow TimeoutExpired into (True, "", "")
#   => ok is True, the marker is gone => FAIL.
#
# Usage: bash tests/smoke/governance/gh-call-timeout-bound.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
SWEEP="$PLUGIN/scripts/idc_recirc_sweep.py"
BOARD="$PLUGIN/scripts/idc_gh_board.py"
fail() { echo "FAIL: $1"; exit 1; }
# shellcheck source=../lib/fail-closed.sh
. "$(dirname "$0")/../lib/fail-closed.sh"   # assert_fail_closed / fc_require_file

fc_require_file "$SWEEP" "recirc sweep (idc_recirc_sweep.gh)"
fc_require_file "$BOARD" "board reader (idc_gh_board._gh)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"

# Two fake `gh`s. The slow one sleeps far longer than the outer bound, so an unbounded call CANNOT
# finish in time; the fast one answers an empty JSON object immediately.
mkdir -p "$WORK/slow-bin" "$WORK/fast-bin"
printf '#!/bin/sh\nsleep 45\n' > "$WORK/slow-bin/gh"
printf '#!/bin/sh\nprintf "{}"\n' > "$WORK/fast-bin/gh"
chmod +x "$WORK/slow-bin/gh" "$WORK/fast-bin/gh"

# GH_TIMEOUT_S is monkeypatched to 2s so the probe costs seconds, not the shipped 120. The marker
# asserted below embeds that patched value, so it can only have been produced by the module's own
# bound firing — not by any other error path that happens to mention a timeout.
cat > "$WORK/probe-sweep.py" <<'PY'
import os, sys, time
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_recirc_sweep as SW
SW.GH_TIMEOUT_S = 2
started = time.time()
ok, out, err = SW.gh(["repo", "view", "--json", "owner"], repo)
sys.stderr.write("elapsed=%.1fs ok=%r err=%s\n" % (time.time() - started, ok, err.strip()))
sys.exit(0 if ok else 3)
PY
cat > "$WORK/probe-board.py" <<'PY'
import os, sys, time
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_gh_board as GB
GB.GH_TIMEOUT_S = 2
started = time.time()
try:
    out = GB._gh(["project", "item-list", "1"], repo)
except GB.BoardReadError as exc:
    sys.stderr.write("elapsed=%.1fs BoardReadError: %s\n" % (time.time() - started, exc))
    sys.exit(3)
except GB.RateLimitError as exc:
    sys.stderr.write("elapsed=%.1fs RateLimitError: %s\n" % (time.time() - started, exc))
    sys.exit(5)
sys.stderr.write("elapsed=%.1fs returned %d byte(s)\n" % (time.time() - started, len(out)))
sys.exit(0)
PY

# Comfortably above the patched 2s bound, comfortably below the fake gh's 45s sleep: a bounded call
# finishes in ~2-4s, an UNBOUNDED one cannot finish at all and reds as a hang.
FC_TIMEOUT_S=20

assert_fail_closed \
  "a hung gh must make idc_recirc_sweep.gh return a bounded failure, never hang and never claim success" \
  'timed out after 2s' \
  -- env PATH="$WORK/slow-bin:$PATH" python3 "$WORK/probe-sweep.py" "$PLUGIN" "$REPO" \
  -- env PATH="$WORK/fast-bin:$PATH" python3 "$WORK/probe-sweep.py" "$PLUGIN" "$REPO"
[ "$FC_CONTROL_RC" -eq 0 ] \
  || fail "the positive control did not complete a normal gh call (rc=$FC_CONTROL_RC), so 'the marker is absent' proves nothing: [$FC_CONTROL_OUT]"
printf '%s' "$FC_GUARDED_OUT" | grep -qF 'ok=False' \
  || fail "idc_recirc_sweep.gh did not report failure on a hung gh: [$FC_GUARDED_OUT]"

assert_fail_closed \
  "a hung gh must make idc_gh_board._gh raise a bounded BoardReadError, never hang" \
  'timed out after 2s' \
  -- env PATH="$WORK/slow-bin:$PATH" python3 "$WORK/probe-board.py" "$PLUGIN" "$REPO" \
  -- env PATH="$WORK/fast-bin:$PATH" python3 "$WORK/probe-board.py" "$PLUGIN" "$REPO"
[ "$FC_CONTROL_RC" -eq 0 ] \
  || fail "the positive control did not complete a normal board call (rc=$FC_CONTROL_RC): [$FC_CONTROL_OUT]"
printf '%s' "$FC_GUARDED_OUT" | grep -qF 'BoardReadError' \
  || fail "a hung gh did not surface as a BoardReadError the caller can fail closed on: [$FC_GUARDED_OUT]"

echo "PASS: both shipped gh call sites bound their child — a hung gh becomes a fast, explicit 'timed out after' failure instead of an unbounded wait, and a normal call carries no such marker"
