#!/bin/bash
# idc-assert-class: behavior
# Phase 10 (pause / resume) smoke — a long autonomous run can be stopped ON PURPOSE and picked back
# up, without the board ever misrepresenting reality. Real git repos, a real filesystem board, real
# hook invocations, no GitHub.
#
# WHAT THIS GUARDS. Before this, the only way to stop a running pipe was to kill it, which is exactly
# how items end up half-done: a session dying between merging a PR and flipping the board card leaves
# the board advertising work that already shipped. `/idc:pause` is the graceful alternative, and its
# whole value is one promise — WHEN PAUSE RETURNS, NOTHING IS HALF-DONE — so most of what follows is
# an attempt to get a pause recorded when that is not true.
#
# THE FOUR THINGS THAT MUST HOLD
#   1. A pause that cannot be proven clean is REFUSED, loudly, and records `pause-requested` (an
#      honest "asked for, not achieved") rather than a clean-looking pause.
#   2. A confirmed pause closes the interrupted run's lifecycle record with the `paused` terminal
#      status — the one that does not lie. (`complete` would claim a drained pipe; `waiting_gate` a
#      human decision nobody is waiting on; `no_action` an empty lane; `blocked_external` a failure.)
#   3. BOTH resume paths continue the run: the explicit `/idc:resume`, and the next `/idc:autorun`'s
#      preflight. A pause the operator forgets about never strands work.
#   4. Pausing twice, pausing with nothing running, and resuming with nothing paused are all safe,
#      honest no-ops.
#
# RED-WHEN-BROKEN. Every guard below was broken in the real source, one at a time, and observed to
# turn this suite RED before it was committed. The mutation, and the assertion that actually caught
# it — named honestly, because "some assertion went red" is not the same as "this assertion works":
#   * drop the `if code != 0` refusal in `idc_pause_state.confirm` (make it trust its caller)
#          ⇒ A2 RED (a pause gets recorded over an in-flight item).
#   * delete the `_claim_paused` quiescence re-run (return ok on the record alone)
#          ⇒ C1 RED (a hand-written record becomes enough to close a run as paused). A2b survives
#          this one, and that is the point: A2b's repo fails the CONFIRMED-state rule too, so the two
#          rules are checked by two different cases. C1 is the quiescence re-run's own test.
#   * delete the CONFIRMED-state rule in `_claim_paused` (accept `pause-requested`)
#          ⇒ C2 RED. (A2b's repo is also non-quiescent, so the re-run catches it there first —
#          C2 is the case that isolates this rule.)
#   * drop `PAUSED` from the autorun claim-table entry
#          ⇒ A5 RED (the interrupted run has no honest terminal status again — the gap this closes).
#   * delete the `_is_paused(cwd)` allow in idc_stop_fixpoint_gate.py
#          ⇒ A7 RED (a deliberate pause is refused the stop, so pausing degrades into a hard kill).
#   * make `_is_paused` accept `pause-requested` too
#          ⇒ A7c RED (an unachieved pause starts buying a free stop — the dishonest exit the gate
#          exists to refuse).
#   * delete the `_claim_resume_cleared` record check   ⇒ A8 RED (a resume that cleared nothing
#          reports success).
#   * remove the pause clear from the documented autorun preflight block
#          ⇒ A9 RED (a forgotten pause keeps the repo marked paused forever).
#   * make `request` overwrite an existing record   ⇒ B1 RED (a second pause downgrades a confirmed
#          pause back to a request).
#   * make `read_record` return a paused record on a corrupt file   ⇒ C3 RED. (Broadening it to
#          swallow a MISSING file too is caught earlier, at A1 — same class, different case.)
#   * drop the exit-MATCH in the `_PAUSE_HELPER` blocker branch   ⇒ C5b RED (a real failure could be
#          closed out citing a different exit than the one that actually happens).
#   * drift the stop gate's inlined `_PAUSE_FILENAME` from the module's
#          ⇒ D1 RED (verified by running the D1 block alone; in a full run A7 fails first, since the
#          gate then reads a file nobody writes — D1 is the precise diagnosis for that same break).
#
# Usage: bash tests/smoke/phase10-pause-resume.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
PS="$PLUGIN/scripts/idc_pause_state.py"
PC="$PLUGIN/scripts/idc_pause_check.py"
CC="$PLUGIN/scripts/idc_command_contract.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
COH="$PLUGIN/scripts/idc_finish_coherence.py"
LEDGER="$PLUGIN/scripts/hooks/idc_ledger.py"
GATE="$PLUGIN/scripts/hooks/idc_stop_fixpoint_gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
for f in "$PS" "$PC" "$CC" "$TRK" "$DRAIN" "$COH" "$LEDGER" "$GATE"; do
  [ -f "$f" ] || fail "missing helper: $f"
done

# `run <cmd…>` → $out (stdout) and $rc; stderr discarded (every verdict rides stdout by contract).
run() { out="$("$@" 2>/dev/null)"; rc=$?; }

# A governed filesystem repo with real git — the substrate a real run has.
mkrepo() { # $1 = dir
  local r="$1"; mkdir -p "$r/docs/workflow"
  git init -q -b main "$r" || fail "git init failed"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf 'backend: filesystem\n' > "$r/docs/workflow/tracker-config.yaml"   # marks it IDC-governed
  python3 "$TRK" --tracker "$r/TRACKER.md" init >/dev/null || fail "tracker init failed"
  echo v1 > "$r/app.py"; git -C "$r" add -A; git -C "$r" commit -qm init
}
# Open a command lifecycle record the way the entry gate does (the deterministic write door).
open_record() { # repo, session, command
  python3 - "$1" "$2" "$3" <<'PY' || fail "could not open the command record"
import sys, os
sys.path.insert(0, os.path.join(os.environ["IDC_PLUGIN"], "scripts", "hooks"))
import idc_ledger
repo, sid, cmd = sys.argv[1:4]
sys.exit(0 if idc_ledger.command_start(repo, sid, cmd, "0.0.0", "d", "user") else 1)
PY
}
export IDC_PLUGIN="$PLUGIN"
mk_payload() { python3 - "$1" "$2" <<'PY'
import json, sys
cwd, sid = sys.argv[1:3]
print(json.dumps({"hook_event_name": "Stop", "cwd": cwd, "session_id": sid,
                  "transcript_path": "", "stop_hook_active": False}))
PY
}
gate_blocks() { # repo, sid  → 0 when the gate BLOCKS the stop
  mk_payload "$1" "$2" | python3 "$GATE" "$PLUGIN" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null
}

echo "== A. THE REAL JOURNEY — start a run, pause it, prove it is clean, resume it (both ways)"
R="$WORK/journey"; mkrepo "$R"
T="$R/TRACKER.md"
SID="pausesess-$$-$(basename "$WORK")"
# The board a real mid-run pause sees: an inbox ticket the pipe has NOT drained yet (so the drain is
# genuinely non-terminal — exit 4 — and the stop gate has something to refuse), plus one Buildable
# item the run has CLAIMED and is working on.
python3 "$TRK" --tracker "$T" create --title 'recirc: scope found mid-build' --stage Recirculation --status Todo >/dev/null
python3 "$TRK" --tracker "$T" create --title 'the item in flight' --stage Buildable >/dev/null   # #2
python3 "$TRK" --tracker "$T" claim --num 2 --agent bot >/dev/null                               # In Progress
# …and its work has ALREADY SHIPPED (branch merged) while the board still says In Progress — the exact
# window a hard kill leaves behind, and precisely what a pause must refuse to paper over.
git -C "$R" checkout -q -b worktree-build-2; echo z > "$R/z"; git -C "$R" add -A; git -C "$R" commit -qm w2
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff worktree-build-2 -m "merge 2"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm board >/dev/null 2>&1
open_record "$R" "$SID" autorun
python3 "$LEDGER" --cwd "$R" set --kind orchestrator_drain --session "$SID" >/dev/null

# A0 — precondition: this really is a live, undrained run.
run python3 "$DRAIN" --tracker "$T"
[ "$rc" = 4 ] || fail "A0: precondition — the seeded board must be a non-terminal drain (exit 4), got $rc"

# A1 — the operator asks to pause. The REQUEST is recorded first, before anything is finished, so a
# session that dies mid-pause leaves a true record instead of silence.
run python3 "$PS" --cwd "$R" request --session "$SID" --command autorun --note "stopping for the night"
[ "$rc" = 0 ] || fail "A1: recording a pause request must succeed, got rc=$rc out=$out"
[ -f "$R/.idc-pause-state.json" ] || fail "A1: the pause request must be DURABLE (a file on disk)"

# A2 — THE PROMISE. Work is in flight, so the pause must be REFUSED — loudly, by name, with a cure —
# and must NOT be recorded as a clean stop. [break confirm's re-run ⇒ RED]
run python3 "$PC" --repo "$R"
[ "$rc" = 1 ] || fail "A2: an in-flight run must not read as pause-ready, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^pause-ready: in-flight' || fail "A2: expected an in-flight verdict, got: $out"
printf '%s' "$out" | grep -q 'claimed:#2' || fail "A2: the claimed item must be named, got: $out"
printf '%s' "$out" | grep -q 'coherence:#2' || fail "A2: the shipped-but-unflipped item must be named, got: $out"
printf '%s' "$out" | grep -q '^cure: ' || fail "A2: every finding must name a cure that clears it, got: $out"
run python3 "$PS" --cwd "$R" confirm --session "$SID"
[ "$rc" != 0 ] || fail "A2: confirm must REFUSE while work is in flight (it re-runs the check itself)"
printf '%s' "$out" | grep -q 'pause: NOT paused' || fail "A2: a refused pause must say so plainly, got: $out"
python3 "$PS" --cwd "$R" status | grep -q 'NOT yet confirmed' \
  || fail "A2: a refused pause must stay 'pause-requested', never claim a clean stop"

# A2b — and no command record may close as `paused` on that record. [break _claim_paused ⇒ RED]
run python3 "$CC" finish --repo "$R" --session "$SID" --command autorun --status paused \
  --evidence-json '{"schema_version":1,"refs":{}}'
[ "$rc" != 0 ] || fail "A2b: a 'paused' closeout must be refused while the pause is unconfirmed"

# A3 — the GRACEFUL part: finish the item that was in flight, including its board card.
python3 "$TRK" --tracker "$T" close --num 2 >/dev/null || fail "A3: could not finish the in-flight item"
run python3 "$COH" --repo "$R" --tracker "$T"
[ "$rc" = 0 ] && [ "$out" = "finish-coherence: ok" ] \
  || fail "A3: after finishing, the board must agree with reality, got rc=$rc out=$out"
run python3 "$PC" --repo "$R"
[ "$rc" = 0 ] && [ "$out" = "pause-ready: ok" ] || fail "A3: nothing should be half-done now, got rc=$rc out=$out"

# A4 — now the pause is honest, so confirm records it.
run python3 "$PS" --cwd "$R" confirm --session "$SID"
[ "$rc" = 0 ] || fail "A4: a quiescent run must be pausable, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^pause: paused' || fail "A4: expected a confirmed pause, got: $out"
python3 -c '
import json,sys
r=json.load(open(sys.argv[1]))
assert r["state"]=="paused", r
assert r["quiescence"]["verdict"]=="ok", r
' "$R/.idc-pause-state.json" || fail "A4: the durable record must carry the confirmed state + its proof"

# A5 — the interrupted run closes with the ONE honest terminal status. [drop PAUSED from the table ⇒ RED]
run python3 "$PS" --cwd "$R" close-open --session "$SID"
[ "$rc" = 0 ] || fail "A5: closing the paused run's open records must succeed, got rc=$rc out=$out"
printf '%s' "$out" | grep -q 'closed as paused' || fail "A5: the autorun record must close as paused, got: $out"
python3 "$CC" status --repo "$R" --session "$SID" | grep -q 'done .*autorun *paused' \
  || fail "A5: the ledger must record the autorun run as terminally 'paused'"

# A6 — NOTHING IS HALF-DONE and the board does not misrepresent reality. This is the whole contract,
# asserted against the board itself rather than against the pause record's own say-so.
python3 - "$T" <<'PY' || fail "A6: a paused run must leave no item claimed as in progress"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sys.exit(1 if "In Progress" in text else 0)
PY
run python3 "$COH" --repo "$R" --tracker "$T"
[ "$rc" = 0 ] || fail "A6: the board must be coherent with reality at the pause, got rc=$rc out=$out"
# …while the WORK that remains is untouched: the inbox ticket is still there, waiting to be resumed.
run python3 "$DRAIN" --tracker "$T"
[ "$rc" = 4 ] || fail "A6: pausing must not consume or hide the remaining work, got drain rc=$rc"

# A7 — the Stop fixpoint gate lets a DELIBERATE stop through, even with the pipe undrained.
# [delete the _is_paused allow ⇒ RED]
gate_blocks "$R" "$SID" && fail "A7: the Stop gate must ALLOW a stop when the repo is deliberately paused"
# A7b — and it is the PAUSE doing that, not a broken gate: with the record gone, the same session,
# the same board, is refused. (The paired assertion is what keeps A7 from passing vacuously.)
mv "$R/.idc-pause-state.json" "$WORK/saved-pause.json"
gate_blocks "$R" "$SID" || fail "A7b: without the pause record the Stop gate must still refuse this stop"
# A7c — an UNCONFIRMED pause buys nothing. [make _is_paused accept pause-requested ⇒ RED]
python3 - "$R/.idc-pause-state.json" <<'PY'
import json, sys
json.dump({"version": 1, "state": "pause-requested", "session_id": "x", "requested_ts": 0.0},
          open(sys.argv[1], "w"))
PY
gate_blocks "$R" "$SID" || fail "A7c: a 'pause-requested' record must NOT buy a stop — it is not a pause"
cp "$WORK/saved-pause.json" "$R/.idc-pause-state.json"

# A8 — RESUME PATH 1: the explicit /idc:resume door. [break _claim_resume_cleared ⇒ RED]
open_record "$R" "$SID" resume
run python3 "$CC" finish --repo "$R" --session "$SID" --command resume --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}'
[ "$rc" != 0 ] || fail "A8: /idc:resume cannot close 'complete' while the repo is still recorded as paused"
run python3 "$PS" --cwd "$R" resume --session "$SID"
[ "$rc" = 0 ] || fail "A8: clearing the pause must succeed, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^resume: cleared (paused)' || fail "A8: resume must report what it cleared, got: $out"
[ -f "$R/.idc-pause-state.json" ] && fail "A8: the pause record must be GONE after a resume"
run python3 "$CC" finish --repo "$R" --session "$SID" --command resume --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}'
[ "$rc" = 0 ] || fail "A8: a real resume must close 'complete', got rc=$rc out=$out"
# …and the run is live again: the gate goes back to refusing a dishonest walk-away.
gate_blocks "$R" "$SID" || fail "A8: after resuming, the Stop gate must refuse an undrained exit again"
# …and the work that was waiting is exactly where it was left (the board is what resume continues from).
run python3 "$DRAIN" --tracker "$T"
[ "$rc" = 4 ] || fail "A8: the remaining work must survive a pause/resume round trip, got drain rc=$rc"

# A9 — RESUME PATH 2: a pause the operator FORGETS about is picked up by the next /idc:autorun. This
# runs the EXACT preflight block documented in docs/dev/pause-resume-autorun-integration.md.
# [remove the clear from the preflight ⇒ RED]
python3 "$PS" --cwd "$R" request --session "$SID" >/dev/null
python3 "$PS" --cwd "$R" confirm --session "$SID" >/dev/null || fail "A9: could not re-pause a clean repo"
[ -f "$R/.idc-pause-state.json" ] || fail "A9: precondition — the repo must be paused again"
PREFLIGHT="$(python3 - "$PLUGIN/docs/dev/pause-resume-autorun-integration.md" <<'PY'
import re, sys
doc = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<!-- autorun-preflight:begin -->\s*```bash\n(.*?)```", doc, re.S)
if not m:
    sys.exit("the integration doc has no marked autorun-preflight block")
print(m.group(1))
PY
)" || fail "A9: could not extract the documented autorun preflight block"
out="$(cd "$R" && CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_CODE_SESSION_ID="$SID" bash -c "$PREFLIGHT" 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "A9: the documented autorun preflight must exit 0, got rc=$rc out=$out"
printf '%s' "$out" | grep -q 'resume: cleared' \
  || fail "A9: the autorun preflight must pick up a forgotten pause, got: $out"
[ -f "$R/.idc-pause-state.json" ] && fail "A9: the autorun preflight must clear the pause record"
run python3 "$DRAIN" --tracker "$T"
[ "$rc" = 4 ] || fail "A9: auto-resuming must leave the remaining work intact, got drain rc=$rc"

echo "== B. THE AWKWARD CASES — safe, honest no-ops (never errors, never silent corruption)"
B="$WORK/awkward"; mkrepo "$B"
BSID="awk-$$"
# B1 — pausing twice. [make request overwrite ⇒ RED]
python3 "$PS" --cwd "$B" request --session "$BSID" >/dev/null
python3 "$PS" --cwd "$B" confirm --session "$BSID" >/dev/null || fail "B1: could not pause an idle repo"
run python3 "$PS" --cwd "$B" request --session "other-session"
[ "$rc" = 0 ] || fail "B1: pausing twice must be a safe no-op, got rc=$rc out=$out"
printf '%s' "$out" | grep -q 'already-recorded' || fail "B1: a second pause must report the existing one, got: $out"
python3 -c '
import json,sys; r=json.load(open(sys.argv[1]))
assert r["state"]=="paused", r        # never regressed back to a request
assert r["session_id"]=="'"$BSID"'", r  # never re-attributed to the second caller
' "$B/.idc-pause-state.json" || fail "B1: a second pause must not downgrade or re-own the first"
run python3 "$PS" --cwd "$B" confirm --session "other-session"
[ "$rc" = 0 ] || fail "B1: re-confirming an already-paused repo must be a safe no-op, got rc=$rc out=$out"

# B2 — resuming when nothing is paused.
python3 "$PS" --cwd "$B" resume --session "$BSID" >/dev/null
run python3 "$PS" --cwd "$B" resume --session "$BSID"
[ "$rc" = 0 ] || fail "B2: resuming an unpaused repo must exit 0 (an honest no-op), got rc=$rc"
[ "$out" = "resume: not-paused" ] || fail "B2: expected 'resume: not-paused', got: $out"
# …and it closes out honestly rather than being stuck with an open obligation.
open_record "$B" "$BSID" resume
run python3 "$CC" finish --repo "$B" --session "$BSID" --command resume --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}'
[ "$rc" = 0 ] || fail "B2: resuming with nothing paused must still close honestly, got rc=$rc out=$out"

# B3 — pausing when nothing is running. "Do not start anything new" is a meaningful instruction even
# with an empty board, so it records a real pause rather than erroring.
run python3 "$PS" --cwd "$B" confirm --session "$BSID"
[ "$rc" = 0 ] || fail "B3: pausing an idle repo must succeed, got rc=$rc out=$out"
run python3 "$PS" --cwd "$B" close-open --session "$BSID"
[ "$rc" = 0 ] || fail "B3: closing open records with none open must be a no-op, got rc=$rc out=$out"
[ "$out" = "paused-record: none open" ] || fail "B3: expected 'none open', got: $out"
python3 "$PS" --cwd "$B" resume --session "$BSID" >/dev/null

echo "== C. FAIL-CLOSED — a pause that is not true cannot be recorded, claimed, or forged"
C="$WORK/failclosed"; mkrepo "$C"
CSID="fc-$$"
python3 "$TRK" --tracker "$C/TRACKER.md" create --title 'in flight' --stage Buildable >/dev/null
python3 "$TRK" --tracker "$C/TRACKER.md" claim --num 1 --agent bot >/dev/null
open_record "$C" "$CSID" build

# C1 — a HAND-WRITTEN `paused` record buys nothing: the closeout re-derives quiescence for real.
# [delete the _claim_paused re-run ⇒ RED]
python3 - "$C/.idc-pause-state.json" <<'PY'
import json, sys
json.dump({"version": 1, "state": "paused", "session_id": "forged", "requested_ts": 0.0,
           "confirmed_ts": 0.0, "quiescence": {"verdict": "ok", "checked_ts": 0.0}},
          open(sys.argv[1], "w"))
PY
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command build --status paused \
  --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C1: a forged pause record must not close a run as paused"
printf '%s' "$out" | grep -q 'paused-not-quiescent' \
  || fail "C1: the refusal must name the missing quiescence proof, got: $out"

# C2 — a `pause-requested` record cannot close a run as paused either.
python3 - "$C/.idc-pause-state.json" <<'PY'
import json, sys
json.dump({"version": 1, "state": "pause-requested", "session_id": "x", "requested_ts": 0.0},
          open(sys.argv[1], "w"))
PY
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command build --status paused \
  --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C2: an unconfirmed pause must not close a run as paused"
printf '%s' "$out" | grep -q 'paused-not-confirmed' || fail "C2: expected paused-not-confirmed, got: $out"

# C3 — a CORRUPT record reads as "not paused", never as a pause. [make read_record tolerant ⇒ RED]
printf 'not json at all' > "$C/.idc-pause-state.json"
run python3 "$PS" --cwd "$C" status
[ "$out" = "pause: none" ] || fail "C3: a corrupt pause record must read as no pause, got: $out"
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command build --status paused \
  --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C3: a corrupt pause record must not close a run as paused"
rm -f "$C/.idc-pause-state.json"

# C4 — `paused` is a PIPELINE terminal. A lifecycle/diagnostic command may not claim it.
open_record "$C" "$CSID" doctor
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command doctor --status paused \
  --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C4: /idc:doctor must not be able to claim a pipeline 'paused'"
printf '%s' "$out" | grep -q 'status-not-legal-for-command' || fail "C4: expected the legality refusal, got: $out"

# C5 — `blocked_external` for pause is re-derived by RE-RUNNING the check, never taken on trust.
open_record "$C" "$CSID" pause
# C5a — while something IS in flight, the blocker is real and its cited exit matches.
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command pause --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_pause_check.py","exit":1,"diagnostic":"#1 is still claimed"}}}' 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "C5a: a genuine in-flight blocker must close /idc:pause as blocked_external, got: $out"
# C5b — a MISMATCHED exit is refused. [drop the exit match ⇒ RED]
open_record "$C" "$CSID" pause
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command pause --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_pause_check.py","exit":2,"diagnostic":"invented"}}}' 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C5b: a blocker citing an exit the helper does not produce must be refused"
printf '%s' "$out" | grep -q 'blocked-external-pause-exit-mismatch' || fail "C5b: expected the exit-mismatch refusal, got: $out"
# C5c — once nothing is in flight, a blocker is refused outright: the honest close is the pause.
python3 "$TRK" --tracker "$C/TRACKER.md" close --num 1 >/dev/null
out="$(python3 "$CC" finish --repo "$C" --session "$CSID" --command pause --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_pause_check.py","exit":1,"diagnostic":"stale"}}}' 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C5c: a blocker must be refused when the re-run passes"
printf '%s' "$out" | grep -q 'blocked-external-pause-not-failing' || fail "C5c: expected the not-failing refusal, got: $out"

# C6 — INDETERMINATE is not clean. An unreadable board must never be recorded as a quiet pause.
D="$WORK/indeterminate"; mkrepo "$D"
printf 'backend: nonsense-not-a-backend\n' > "$D/docs/workflow/tracker-config.yaml"
run python3 "$PC" --repo "$D"
[ "$rc" = 2 ] || fail "C6: an unreadable board must be INDETERMINATE (exit 2), got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^pause-ready: error' || fail "C6: expected an error verdict, got: $out"
out="$(python3 "$PS" --cwd "$D" confirm --session "$CSID" 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "C6: confirm must refuse when quiescence cannot be established"
python3 "$PS" --cwd "$D" status | grep -q 'none\|NOT yet confirmed' \
  || fail "C6: an unprovable pause must never be recorded as confirmed"

echo "== D. LOCKSTEP — the constants two files must agree on, and the wiring a new command needs"
# D1 — the Stop gate inlines the pause filename + confirmed state (it must not grow a sys.path
# dependency on a sibling package), so the smoke suite is what holds the two sides together.
python3 - "$PLUGIN" <<'PY' || fail "D1: the Stop gate's inlined pause constants have drifted from idc_pause_state.py"
import os, re, sys
plugin = sys.argv[1]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_pause_state as PS
gate = open(os.path.join(plugin, "scripts", "hooks", "idc_stop_fixpoint_gate.py"), encoding="utf-8").read()
name = re.search(r'^_PAUSE_FILENAME\s*=\s*"([^"]+)"', gate, re.M)
state = re.search(r'^_PAUSE_CONFIRMED\s*=\s*"([^"]+)"', gate, re.M)
if not name or not state:
    sys.exit("the Stop gate no longer declares _PAUSE_FILENAME / _PAUSE_CONFIRMED")
if name.group(1) != PS.PAUSE_FILENAME or state.group(1) != PS.PAUSED:
    sys.exit(f"drift: gate has {name.group(1)}/{state.group(1)}, module has {PS.PAUSE_FILENAME}/{PS.PAUSED}")
PY

# D2 — the full command-integrity chain must actually cover the two new commands: the contract knows
# them, the entry-gate matcher admits them (no matcher entry ⇒ no freshness gate, no lifecycle record,
# no closeout enforcement), and `paused` is legal for exactly the pipeline commands.
python3 - "$PLUGIN" <<'PY' || fail "D2: pause/resume are not fully wired into the command-integrity chain"
import json, os, re, sys
plugin = sys.argv[1]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_command_contract as C
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_command_entry_gate as EG
problems = []
for cmd in ("pause", "resume"):
    if cmd not in C.COMMANDS:
        problems.append(f"{cmd} missing from idc_command_contract.COMMANDS")
    if not os.path.isfile(os.path.join(plugin, "commands", f"{cmd}.md")):
        problems.append(f"commands/{cmd}.md missing")
    if cmd not in (EG.WORKFLOW_COMMANDS | EG.RECOVERY_COMMANDS | EG.DEFERS_REGISTRATION):
        problems.append(f"{cmd} is classified by neither the workflow nor the recovery entry-gate set")
doc = json.load(open(os.path.join(plugin, "hooks", "hooks.json"), encoding="utf-8"))
matchers = [e.get("matcher", "") for e in doc["hooks"]["UserPromptExpansion"]]
admitted = set()
for pat in matchers:
    m = re.fullmatch(r"\^idc:\(([a-z|-]+)\)\$", pat or "")
    if m:
        admitted.update(m.group(1).split("|"))
for cmd in ("pause", "resume"):
    if cmd not in admitted:
        problems.append(f"/idc:{cmd} is not admitted by the entry-gate matcher — it would ship with NO "
                        "freshness gate, lifecycle record, or closeout enforcement")
pausable = {c for c, s in C.LEGAL_STATUSES.items() if C.PAUSED in s}
# NOT every pipeline command — only the three whose half-done work the quiescence check can OBSERVE.
# This narrowed after review: `paused` promises resume never has to reconstruct partial work, and
# idc_pause_check.py earns that promise from the board and the obligations ledger. Think, Intake and
# Plan leave their partial work in a branch, which it never reads, so they passed quiescence
# TRIVIALLY and closed as certified clean stops. See _PAUSABLE_STAGES in idc_command_contract.py.
expected = {"build", "recirculate", "autorun"}
if pausable != expected:
    problems.append(f"`paused` is legal for {sorted(pausable)}, expected exactly {sorted(expected)}")
sys.exit("; ".join(problems) if problems else 0)
PY

# A10 — THE INTEGRATION IS ACTUALLY APPLIED, not merely documented. A9 proves the block in
# docs/dev/pause-resume-autorun-integration.md WORKS by executing it; it says nothing about whether
# the playbooks a real run reads have it. Without this, the whole second resume path could be deleted
# from both files and every other assertion here would stay green — the exact "documented but not
# wired" trap E3 in phase4-completion-honesty.sh locks for the drain flags.
#
# BOTH files, deliberately: `/idc:autorun` tells the session to read the AGENT file and run its steps,
# so a step present only in the command markdown is not live in a real run.
#
# Scoped to the real invocation, never a file-wide grep: the surrounding prose in both files names the
# script too, so a bare `grep idc_pause_state.py` would pass with the command deleted.
#
# The single edit that makes this fail: delete the resume preflight command line from either playbook.
for f in "$PLUGIN/commands/autorun.md" "$PLUGIN/agents/idc-autorun.md"; do
  grep -qE 'idc_pause_state\.py"? --cwd "\$PWD" resume' "$f" \
    || fail "A10: $(basename "$f") must INVOKE the resume preflight (idc_pause_state.py … resume) on a
real command line — a forgotten pause is only picked up automatically if this step is in the playbook
the run actually reads"
done

echo "PASS: a run can be paused on purpose without the board ever lying, and both resume paths continue it"
