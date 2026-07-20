#!/bin/bash
# idc-assert-class: behavior
# Phase 1 (pipe safety) smoke — a shipped `--json` reporter must survive an operator piping it to
# `head`/`less`, which is the single most ordinary thing anyone does with a long report.
#
# WHAT WENT WRONG. `idc_command_contract.py status --repo <r> --json | head` printed a Python
# traceback and exited non-zero. `head` takes what it wants and closes the pipe; Python sets SIGPIPE
# to SIG_IGN at startup, so the writer's next write to that closed pipe raises `BrokenPipeError`
# instead of dying the silent death every other unix tool dies of. No guard existed anywhere in
# scripts/.
#
# WHY IT HID. Whether it bites depends on how much of the payload fits in the kernel's pipe buffer
# before the reader leaves — 16 KB on macOS (growable to 64 KB), 4 KB on Linux. A short report never
# touches the closed pipe. That is why this was invisible on a developer's mac and fatal on a Linux
# runner. THIS SUITE THEREFORE BUILDS ITS OWN BIG PAYLOAD rather than trusting whatever a scratch
# repo happens to hold: section A asserts the fixture actually exceeds any plausible buffer BEFORE
# asserting anything about the pipe, so the suite can never pass on this machine for the wrong reason
# (a report that fit, tested against a reader that never had to close early).
#
# WHAT IS ASSERTED, AND WHY EACH PART IS LOAD-BEARING. A guard that catches `BrokenPipeError` and
# stops there is not fixed, only quieter: the interpreter still flushes stdout on the way out, that
# flush hits the same dead pipe, and Python prints `Exception ignored in: <_io.TextIOWrapper ...>` to
# stderr and exits 120. So this suite asserts stderr is EMPTY — not merely traceback-free — and that
# the exit code is the guard's own 141, distinguishing a handled broken pipe from an uncaught
# exception (1), a shutdown-flush failure (120), and every load-bearing IDC verdict code (0/1/2/4).
#
# THE TEST RUNS THE REAL COMMAND. It does not grep the source for `BrokenPipeError` — that assertion
# would pass with the guard deleted from the real call path, which is the exact way this repo has been
# burned before (see the header of phase4-completion-honesty.sh). Every assertion below spawns the
# shipped script and pipes it into a reader that exits after one byte.
#
# RED-WHEN-BROKEN. Five mutations were made in the REAL source, one at a time, each observed to turn
# this suite red, each restored after:
#   1. idc_command_contract.py __main__ reverted to `raise SystemExit(main())` (the pre-fix line)
#      → A3 RED with the original BrokenPipeError traceback.
#   2. idc_stdio.silence_stdout() call dropped (catch the exception, skip the /dev/null redirect)
#      → A5 RED with `Exception ignored in: <_io.TextIOWrapper ...>`. This is the mutation that
#      proves the redirect is load-bearing rather than decorative, and it is caught ONLY by the
#      line-loop branch — which is why A5 exists and why its fixture is sized separately.
#   3. idc_stdio's `except SystemExit` arm dropped → B1 RED. Note this mutation is INVISIBLE to
#      sections A/C/D: when the pipe breaks, the exception fires mid-print, before any sys.exit is
#      reached, so only a direct test of the helper catches it.
#   4. idc_board_lint.py __main__ reverted to bare `main()` → C2 RED.
#   5. idc_tracker_fs.py __main__ reverted to bare `main()` → D2 RED.
#   6. idc_intake_manifest.py's tolerant guard import made hard again → F RED. This one is not
#      hypothetical: it is the defect the first cut of the fix actually shipped, caught by
#      governance/external-intake-completeness.sh going red before any of this was committed.
#
# ONE FALSE GREEN WAS FOUND AND FIXED IN THIS SUITE ITSELF, and is called out because it is the exact
# class this repo keeps getting burned by: B1's first cut ordered its cases (0, 1, 2, 4), so under
# mutation 3 the escaping `SystemExit(0)` ended the python check with status 0 — `|| fail` never
# fired, every later assertion silently never ran, and the suite reported PASS against a broken
# guard. B1 now converts an escaping SystemExit into an AssertionError and prints a completion
# sentinel that bash verifies, so any early exit is visible whatever its cause.
#
# Hermetic: a throwaway governed repo, the real ledger write door, no GitHub.
# Usage: bash tests/smoke/phase1-pipe-safety.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CC="$PLUGIN/scripts/idc_command_contract.py"
fail() { echo "FAIL: $1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$CC" ] || fail "idc_command_contract.py not found"
[ -f "$PLUGIN/scripts/idc_stdio.py" ] || fail "scripts/idc_stdio.py (the shared broken-pipe guard) not found"

REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"
# `is_governed_repo` keys on this one file — without it every ledger write is a silent no-op and the
# fixture would come back empty (which section A would then catch as a too-small payload).
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"

# ---- fixture: a report far larger than any pipe buffer, via the REAL ledger write door ----------
# 2000 records ≈ 600 KB of JSON and ≈ 120 KB of the line-per-record branch. The count is set by the
# SMALLER branch: the line loop must also clear the 64 KB max pipe buffer with real margin, or A5
# would pass by accident on whichever machine happened to swallow it (the exact way this bug hid in
# the first place). Session ids are UUID-shaped because that is what a real Claude session id looks
# like — the line length this fixture depends on is the real one, not an inflated one.
#
# Seeded in ONE interpreter (the CLI's own `start` would be 2000 process spawns for the same bytes).
# This is fixture, not the thing under test — the thing under test is the READ+PRINT path afterwards.
python3 - "$PLUGIN" "$REPO" <<'PY' || fail "could not seed the ledger fixture"
import sys, os, uuid
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_ledger
for i in range(2000):
    rec = idc_ledger.command_start(repo, f"sess-{i:04d}-{uuid.UUID(int=i)}", "build",
                                   "4.2.0", "0" * 64, "smoke")
    if not rec:
        raise SystemExit(f"ledger write did not persist at record {i} (repo not governed?)")
PY

# ================================================================================================
# A. `status --json` piped to a reader that leaves early
# ================================================================================================

# ---- A1: the fixture is genuinely bigger than any pipe buffer ----------------------------------
# Without this the whole suite could pass vacuously on a machine whose buffer swallowed the report.
# 64 KB is the largest pipe buffer in play (macOS grown; Linux default is 64 KB max, 4 KB initial).
BYTES="$(python3 "$CC" status --repo "$REPO" --json | wc -c | tr -d ' ')"
[ "$BYTES" -gt 131072 ] \
  || fail "A1: fixture payload is only ${BYTES} bytes — too small to force a closed-pipe write (need >128KB, i.e. comfortably past the 64KB max pipe buffer). The rest of this suite would pass without ever testing anything."

# ---- A2: the unpiped command is unaffected -----------------------------------------------------
# The guard must not change the ordinary path: a full reader still gets the whole report and exit 0.
FULL="$WORK/full.json"
python3 "$CC" status --repo "$REPO" --json > "$FULL" 2>"$WORK/full.err"
[ "$?" -eq 0 ] || fail "A2: unpiped status --json should exit 0, got $?"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["active"])==2000, len(d["active"])' "$FULL" \
  || fail "A2: unpiped status --json must still emit the complete, parseable report"

# ---- A3: stderr is EMPTY when the reader exits early -------------------------------------------
# Not "traceback-free" — EMPTY. `Exception ignored in: <_io.TextIOWrapper ...>` is what a
# catch-without-redirect guard leaks, and it is a failure, not a cosmetic difference.
python3 "$CC" status --repo "$REPO" --json 2>"$WORK/a3.err" | head -c 1 >/dev/null
ERRBYTES="$(wc -c < "$WORK/a3.err" | tr -d ' ')"
if [ "$ERRBYTES" -ne 0 ]; then
  echo "--- stderr the piped command produced (should have been empty) ---"; cat "$WORK/a3.err"
  fail "A3: piping status --json to an early-exiting reader wrote ${ERRBYTES} bytes to stderr"
fi

# ---- A4: the WRITER's exit code is the guard's 141, not a crash --------------------------------
# PIPESTATUS[0] is the writer's own code (the pipeline's is head's 0, which would hide everything).
# 141 = 128+SIGPIPE, what a shell reports for any ordinary tool `| head` kills. An uncaught
# BrokenPipeError exits 1; a shutdown-flush failure exits 120; both are the bug, and both are caught
# by pinning the code exactly rather than merely asserting non-zero or non-1.
python3 "$CC" status --repo "$REPO" --json 2>/dev/null | head -c 1 >/dev/null
WRITER_RC="${PIPESTATUS[0]}"
[ "$WRITER_RC" -eq 141 ] \
  || fail "A4: writer exit code was ${WRITER_RC}, expected 141 (1 = uncaught BrokenPipeError, 120 = unguarded shutdown flush, 0 = the payload never hit a closed pipe)"

# ---- A5: the same holds for the human-readable (line-loop) branch ------------------------------
# `status` without --json prints one line per record in a LOOP. That shape fails at a DIFFERENT
# place than the single big write: the loop tends to leave data in Python's own buffer, so the
# failure surfaces at interpreter shutdown — precisely the half a catch-only guard does not cover.
#
# This branch is the SMALLER of the two, so it gets its own size floor. The first cut of this suite
# seeded 800 records, which made this branch 32 KB — it fit inside the pipe buffer, never hit a
# closed pipe, and reported exit 0. That is the bug's own hiding place reproduced inside the test, so
# the floor is asserted here rather than assumed from A1.
LINEBYTES="$(python3 "$CC" status --repo "$REPO" | wc -c | tr -d ' ')"
[ "$LINEBYTES" -gt 98304 ] \
  || fail "A5: the line-loop report is only ${LINEBYTES} bytes — it would fit in a 64KB pipe buffer and never test a closed pipe (need >96KB). Raise the fixture record count."

python3 "$CC" status --repo "$REPO" 2>"$WORK/a5.err" | head -c 1 >/dev/null
A5_RC="${PIPESTATUS[0]}"
ERRBYTES="$(wc -c < "$WORK/a5.err" | tr -d ' ')"
if [ "$ERRBYTES" -ne 0 ]; then
  echo "--- stderr from the line-loop branch (should have been empty) ---"; cat "$WORK/a5.err"
  fail "A5: piping plain status to an early-exiting reader wrote ${ERRBYTES} bytes to stderr"
fi
[ "$A5_RC" -eq 141 ] \
  || fail "A5: line-loop branch writer exit code was ${A5_RC}, expected 141"

# ---- A6: a reader that exits after several KB (a real `less`/`head -n`) ------------------------
# `head -c 1` is the sharpest trigger; a pager takes a screenful first. Both must be clean, so the
# guard is not accidentally specific to a reader that leaves before the first write lands.
python3 "$CC" status --repo "$REPO" --json 2>"$WORK/a6.err" | head -n 20 >/dev/null
A6_RC="${PIPESTATUS[0]}"
ERRBYTES="$(wc -c < "$WORK/a6.err" | tr -d ' ')"
if [ "$ERRBYTES" -ne 0 ]; then
  echo "--- stderr with a 20-line reader (should have been empty) ---"; cat "$WORK/a6.err"
  fail "A6: piping status --json to \`head -n 20\` wrote ${ERRBYTES} bytes to stderr"
fi
[ "$A6_RC" -eq 141 ] \
  || fail "A6: writer exit code with a 20-line reader was ${A6_RC}, expected 141"

# ================================================================================================
# B. The shared guard itself behaves
# ================================================================================================

# ---- B1: run_guarded passes a normal exit code through untouched -------------------------------
# The guard must be invisible on the happy path — a reporter that exits 2 (rejected) must still
# exit 2, or wrapping a CLI in it would silently rewrite IDC's load-bearing verdict codes.
#
# THIS CHECK PRINTS A COMPLETION SENTINEL AND BASH VERIFIES IT. The first cut of this section was a
# FALSE GREEN: an escaping `SystemExit(0)` from the very first case ended the python process with
# status 0, so `|| fail` never fired and every later assertion silently never ran — which is exactly
# the defect the section is meant to detect. An escaping SystemExit is now converted to an
# AssertionError, AND the sentinel makes any early exit visible regardless of cause.
B1_OUT="$(python3 - "$PLUGIN" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_stdio

def make_exiter(code):
    def boom():
        sys.exit(code)
    return boom

for expected in (1, 2, 4, 0):
    got = idc_stdio.run_guarded(lambda e=expected: e)
    assert got == expected, f"run_guarded rewrote a returned exit {expected} to {got}"
    # The code raised via sys.exit() from inside main — the shape MOST of these CLIs actually use
    # (idc_git_janitor, idc_board_lint and idc_recirc_sweep all end that way). SystemExit is NOT an
    # Exception subclass, so a guard missing that arm lets it sail past, losing the exit code AND
    # skipping the guarded flush — the guard silently becomes a no-op for those three scripts.
    try:
        got = idc_stdio.run_guarded(make_exiter(expected))
    except SystemExit:
        raise AssertionError(
            f"run_guarded let SystemExit({expected}) escape — the guarded flush is skipped entirely, "
            "so every CLI that ends in sys.exit() is left unprotected")
    assert got == expected, f"run_guarded rewrote a sys.exit({expected}) to {got}"

# sys.exit() with no code, and the sys.exit("message") form, must survive intact too
assert idc_stdio.run_guarded(lambda: sys.exit()) is None, "run_guarded mangled a bare sys.exit()"
assert idc_stdio.run_guarded(lambda: sys.exit("msg")) == "msg", "run_guarded dropped sys.exit's message"
print("B1-COMPLETE")
PY
)" || fail "B1: run_guarded must pass through a normal exit code unchanged — ${B1_OUT}"
printf '%s\n' "$B1_OUT" | grep -qx 'B1-COMPLETE' \
  || fail "B1: the check did not run to completion (no sentinel) — an assertion was skipped, most likely a SystemExit escaping run_guarded and ending the check early. Output: ${B1_OUT}"

# ---- B2: run_guarded does not swallow an unrelated exception -----------------------------------
# A bare `except Exception` here would turn every real bug in a reporter into a quiet 141. Only
# BrokenPipeError may be caught.
python3 - "$PLUGIN" <<'PY' || fail "B2: run_guarded must let a non-BrokenPipe exception propagate"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_stdio
def boom():
    raise ValueError("a real bug in the reporter")
try:
    idc_stdio.run_guarded(boom)
except ValueError:
    sys.exit(0)
sys.exit("run_guarded swallowed a ValueError — only BrokenPipeError may be caught")
PY

# ================================================================================================
# C. The same guard on a SIBLING reporter — idc_board_lint.py
#
# board_lint prints one line per flagged item and already reads board JSON on STDIN, so it is
# normally invoked mid-pipeline (`idc_gh_board.py … | idc_board_lint.py | head`) — the closed-pipe
# case is its ordinary habitat, not an edge case. It is also the cheapest sibling to exercise for
# real: no git, no board, no GitHub, just a synthetic board on stdin.
# ================================================================================================
BL="$PLUGIN/scripts/idc_board_lint.py"
[ -f "$BL" ] || fail "idc_board_lint.py not found"
BOARD="$WORK/board.json"
python3 - > "$BOARD" <<'PY'
import json
# Stage=Consideration + empty Status is a real lint rule (the empty-status invariant), so every item
# here flags and prints a line. 1500 items ≈ 280 KB of output — well past any pipe buffer.
print(json.dumps([{"number": i, "title": f"a consideration item number {i}",
                   "stage": "Consideration", "status": "", "body": ""} for i in range(1, 1501)]))
PY

# ---- C1: the fixture really is oversized -------------------------------------------------------
BLBYTES="$(python3 "$BL" < "$BOARD" | wc -c | tr -d ' ')"
[ "$BLBYTES" -gt 131072 ] \
  || fail "C1: board-lint fixture output is only ${BLBYTES} bytes — too small to force a closed-pipe write (need >128KB)"

# ---- C2: early-exiting reader → clean stderr and the guard's exit code -------------------------
python3 "$BL" < "$BOARD" 2>"$WORK/c2.err" | head -c 1 >/dev/null
BL_RC="${PIPESTATUS[0]}"
ERRBYTES="$(wc -c < "$WORK/c2.err" | tr -d ' ')"
if [ "$ERRBYTES" -ne 0 ]; then
  echo "--- stderr from board-lint (should have been empty) ---"; cat "$WORK/c2.err"
  fail "C2: piping board-lint to an early-exiting reader wrote ${ERRBYTES} bytes to stderr"
fi
[ "$BL_RC" -eq 141 ] || fail "C2: board-lint writer exit code was ${BL_RC}, expected 141"

# ================================================================================================
# D. The OTHER wiring shape — idc_tracker_fs.py
#
# Three of the guarded CLIs are import-graph ROOTS that other scripts load as libraries (idc_gh_board
# is imported by fourteen of them). Those install the guard inside `__main__` together with their own
# sys.path setup, so that importers inherit nothing. idc_tracker_fs is the one root that is fully
# testable without GitHub, so it stands in for that wiring shape — including for idc_gh_board, whose
# whole-board dump is the highest-traffic reporter of the set but needs a live board to exercise.
# ================================================================================================
TF="$PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$TF" ] || fail "idc_tracker_fs.py not found"
TRACKER="$WORK/TRACKER.md"
python3 "$TF" --tracker "$TRACKER" init >/dev/null 2>&1 || fail "tracker init failed"
python3 "$TF" --tracker "$TRACKER" create --title "long-lived item" >/dev/null 2>&1 || fail "tracker create failed"
# Seed a long comment history through the real load/save door — this is what `show` dumps, and what
# any long-lived item accumulates from claim notes and recirculation checkpoints.
python3 - "$PLUGIN" "$TRACKER" <<'PY' || fail "could not seed the tracker comment history"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_tracker_fs as t
path = sys.argv[2]
state = t.load(path)
item = t.find(state, 1)
item.setdefault("comments", []).extend(
    f"recirculation checkpoint {i}: " + ("disposition detail " * 40) for i in range(200))
t.save(path, state)
PY

# ---- D1: the fixture really is oversized -------------------------------------------------------
TFBYTES="$(python3 "$TF" --tracker "$TRACKER" show --num 1 | wc -c | tr -d ' ')"
[ "$TFBYTES" -gt 131072 ] \
  || fail "D1: tracker-fs show output is only ${TFBYTES} bytes — too small to force a closed-pipe write (need >128KB)"

# ---- D2: early-exiting reader → clean stderr and the guard's exit code -------------------------
python3 "$TF" --tracker "$TRACKER" show --num 1 2>"$WORK/d2.err" | head -c 1 >/dev/null
TF_RC="${PIPESTATUS[0]}"
ERRBYTES="$(wc -c < "$WORK/d2.err" | tr -d ' ')"
if [ "$ERRBYTES" -ne 0 ]; then
  echo "--- stderr from tracker-fs show (should have been empty) ---"; cat "$WORK/d2.err"
  fail "D2: piping tracker-fs show to an early-exiting reader wrote ${ERRBYTES} bytes to stderr"
fi
[ "$TF_RC" -eq 141 ] || fail "D2: tracker-fs show writer exit code was ${TF_RC}, expected 141"

# ================================================================================================
# E. Wiring census — a SUPPLEMENT to sections A–D, never a substitute
#
# Stated plainly because this repo has been burned by source-grepping tests: on its own this section
# is worth little — it would pass against a guard that never runs. Sections A–D are the real
# assertions, and they cover both wiring shapes behaviourally. This section exists only to catch the
# four reporters that cannot be driven hermetically (idc_gh_board and idc_git_janitor need a live
# board / a dirty git repo; idc_recirc_sweep and idc_intake_manifest need substantial fixtures)
# silently LOSING the wiring in a future refactor. If you add a reporter here, add a behavioural
# case above too.
# ================================================================================================
for s in idc_gh_board idc_git_janitor idc_board_lint idc_tracker_fs idc_recirc_sweep \
         idc_intake_manifest idc_command_contract; do
  f="$PLUGIN/scripts/$s.py"
  [ -f "$f" ] || fail "E: $s.py not found"
  grep -q 'idc_stdio.run_guarded(main)' "$f" \
    || fail "E: $s.py no longer installs the broken-pipe guard at its entry point (expected \`raise SystemExit(idc_stdio.run_guarded(main))\` in its __main__ block)"
done

# ================================================================================================
# F. The guard must not make a relocatable script un-relocatable
#
# THIS SECTION EXISTS BECAUSE THE FIX BROKE THIS ONCE. idc_gh_board, idc_tracker_fs and
# idc_intake_manifest are import-graph ROOTS: they import no sibling at module scope, so a lone copy
# of any of them runs anywhere. That is a property the governance suite USES — external-intake-
# completeness.sh copies idc_intake_manifest.py to a temp dir with one validator deleted and runs the
# copy, to prove the deleted gate was the one doing the work. The first cut of the broken-pipe guard
# added a hard `import idc_stdio` to those __main__ blocks, and the relocated copy died on
# ImportError, turning that governance test red.
#
# So the three roots import the guard TOLERANTLY: in place it always loads, and a relocated copy
# falls back to its previous unguarded behaviour instead of failing to run at all.
# ================================================================================================
RELOC="$WORK/relocated"
mkdir -p "$RELOC"
for s in idc_gh_board idc_tracker_fs idc_intake_manifest; do
  cp "$PLUGIN/scripts/$s.py" "$RELOC/$s.py" || fail "F: could not copy $s.py"
  # No sibling modules exist next to the copy — this must still run, not die on ImportError.
  python3 "$RELOC/$s.py" --help >/dev/null 2>&1 \
    || fail "F: a relocated copy of $s.py can no longer run (exit $?). It is an import-graph root that imports no sibling at module scope; the broken-pipe guard must not turn that into a hard dependency — governance/external-intake-completeness.sh executes exactly such a copy."
done

echo "PASS: shipped reporters survive an early-exiting reader (no traceback, no shutdown-flush noise, exit 141)"
