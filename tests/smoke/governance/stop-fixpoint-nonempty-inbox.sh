#!/bin/bash
# idc-assert-class: behavior
# stop-fixpoint-nonempty-inbox.sh — governance scenario: the Stop fixpoint gate refuses a dishonest
# orchestrator exit (forensic drop E) and stays FAIL-CLOSED when the bounded repair budget is exhausted.
#
# The invariant (v4 Phase 3 Stage B, plan §3.4; convergent-integrity §4.5): an autorun/build
# orchestrator DRAIN session — marked active via the ledger's session-scoped `orchestrator_drain`
# taint — cannot Stop while the drain predicate reports `drain: recirc-pending` (exit 4: the build
# lane is drained but the Recirculation/Consideration inbox is non-empty). The Stop hook
# (scripts/hooks/idc_stop_fixpoint_gate.py) reads a Stop payload on stdin and, when BOTH the board
# (idc_autorun_drain.py) AND the ledger say work remains, BLOCKS ({"decision":"block", reason})
# with the /idc:recirculate remediation. The first three stops are ordinary blocks; on the fourth and
# later attempts the gate must LOUD-FAIL on stderr and leave ONE board annotation, but it STILL
# BLOCKS — the attempt ceiling governs repair retries, never permission to falsely finish.
#
# Red-when-broken (MANDATORY, reviewed):
#   * neuter the block (make bounded_block/block a no-op allow) ⇒ the "still blocks" assert goes RED;
#   * restore the old loud-fail-allow branch ⇒ the "4th stop is still blocked" assert goes RED;
#   * neuter the annotation (make _annotate_forced_exit_once a no-op) ⇒ the annotation assert goes RED.
#
# Filesystem-backed (hermetic, no gh). Auto-discovered by the governance lane (phase-governance.sh);
# runnable standalone under BOTH python3 and `uv run --with pyyaml`.
#
# Usage: bash tests/smoke/governance/stop-fixpoint-nonempty-inbox.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

GATE="$GOV_PLUGIN/scripts/hooks/idc_stop_fixpoint_gate.py"
LEDGER="$GOV_PLUGIN/scripts/hooks/idc_ledger.py"
DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$GATE" ] || fail "stop-fixpoint gate not found at $GATE (not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"   # marks REPO IDC-governed
T="$REPO/TRACKER.md"
python3 "$TRK" --tracker "$T" init >/dev/null || fail "tracker init failed"
# A Recirculation ∧ Todo inbox ticket: the build lane is drained but the inbox is non-empty → exit 4.
INBOX="$(python3 "$TRK" --tracker "$T" create --title 'recirc: discovered mid-build scope' --stage Recirculation --status Todo)" \
  || fail "seed of the recirc inbox ticket failed"

# per-RUN-unique session id: the gate's anti-nag counter persists in the OS temp dir, so a shared id
# would leak its count across eval runs (a false loud-fail). One id reused across THIS run's calls to
# exercise the bound; unique across runs so nothing leaks (mirrors verdict-gate.sh).
SID="stopsess-$$-$(basename "$WORK")"
led() { python3 "$LEDGER" --cwd "$REPO" "$@"; }
# the orchestrator marker (self-gate) + a mid_finish obligation (the ledger 'work remains' hint)
led set --kind orchestrator_drain --session "$SID" >/dev/null || fail "could not set the orchestrator_drain marker"
led set --kind mid_finish --key 42 --session "$SID"      >/dev/null || fail "could not set the mid_finish taint"

mk_payload() { python3 - "$1" "$2" <<'PY'
import json,sys
cwd,sid=sys.argv[1:3]
print(json.dumps({"hook_event_name":"Stop","cwd":cwd,"session_id":sid,
 "transcript_path":"","stop_hook_active":False}))
PY
}
ERRLOG="$WORK/stderr.log"
run_gate() { : > "$ERRLOG"; GATE_OUT="$(mk_payload "$REPO" "$SID" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERRLOG")"; GATE_RC=$?; }
blocks() { printf '%s' "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null; }

# ── precondition: the seeded board really is at drain: recirc-pending (exit 4) ─────────────────────
python3 "$DRAIN" --tracker "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] || fail "precondition: the seeded board must be drain: recirc-pending exit 4 (got $rc)"

# ── (1-3) an orchestrator drain stop with a non-empty inbox ⇒ BLOCK, and stay blocked past N=3 ────
blocked=0; loud_on=""; FIRST_OUT=""
for i in 1 2 3 4 5; do
  run_gate
  [ "$i" -eq 1 ] && FIRST_OUT="$GATE_OUT"
  blocks "$GATE_OUT" \
    || fail "gate allowed on try $i — the bounded stop budget must never become permission to falsely finish [restore loud-fail-allow ⇒ RED]"
  blocked=$((blocked + 1))
  if grep -qi 'LOUD-FAIL' "$ERRLOG"; then
    [ -z "$loud_on" ] && loud_on="$i"
    [ "$i" -ge 4 ] || fail "gate LOUD-FAILed before the bound was exhausted (got loud_on=$i)"
  else
    [ "$i" -le 3 ] || fail "the gate must LOUD-FAIL once the bound is exhausted, while STILL blocking (try $i)"
  fi
done
[ "$blocked" -eq 5 ] || fail "expected all 5 stop attempts to stay BLOCKED, got $blocked blocks"
[ "$loud_on" = "4" ] || fail "expected the FIRST LOUD-FAIL on the 4th stop, got loud_on='${loud_on:-<none>}'"
echo "  ok (1-3) non-empty inbox ⇒ blocks 5×, with the first LOUD-FAIL on the 4th stop (still fail-closed)"

# ── the block reason names the exact pending conjunct + the /idc:recirculate remediation ──────────
printf '%s' "$FIRST_OUT" | grep -qi 'recirc'          || fail "block reason must name the recirculation inbox (got: $FIRST_OUT)"
printf '%s' "$FIRST_OUT" | grep -q  '/idc:recirculate' || fail "block reason must name the /idc:recirculate remediation (got: $FIRST_OUT)"
echo "  ok reason names the pending conjunct + the /idc:recirculate remediation"

# ── the loud-fail (4th stop) is LOUD on stderr AND leaves exactly ONE board annotation ─────────────
grep -qi 'LOUD-FAIL' "$ERRLOG" \
  || fail "the bound-exhausting stop must LOUD-FAIL on stderr (P8: a forced exit is a visible governance miss)"
python3 "$TRK" --tracker "$T" show --num "$INBOX" --comments | grep -qi 'idc-stop-gate. forced exit' \
  || fail "the forced exit must leave a board annotation on the blocking inbox item [neuter the annotation ⇒ RED]"
n="$(python3 "$TRK" --tracker "$T" show --num "$INBOX" --comments | grep -c 'idc-stop-gate. forced exit')"
[ "$n" -eq 1 ] || fail "the board annotation must be written ONCE at the bound (not per stop), got $n"
echo "  ok loud-fail on stderr + exactly ONE board annotation on the inbox item (one-time, not per stop)"

# ── (observe-only) IDC_HOOKS_OBSERVE_ONLY=1 ⇒ warn, never block (fresh session, clean counter) ─────
SID_OO="stopsess-oo-$$-$(basename "$WORK")"
led set --kind orchestrator_drain --session "$SID_OO" >/dev/null || fail "observe-only marker set failed"
OUT_OO="$(mk_payload "$REPO" "$SID_OO" | IDC_HOOKS_OBSERVE_ONLY=1 python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"
blocks "$OUT_OO" && fail "(observe-only) IDC_HOOKS_OBSERVE_ONLY=1 must NOT emit a block decision (downgrade to warn)"
echo "  ok (observe-only) IDC_HOOKS_OBSERVE_ONLY=1 ⇒ warn, never block"

# ── (fail-closed) a CRASHING drain (exit OUTSIDE the {0,2,3,4} contract) ⇒ the gate fails CLOSED ────
# P4: once a session is CONFIRMED an orchestrator drain, an UNTRUSTWORTHY drain verdict must fail CLOSED
# — the gate cannot prove the pipe is drained, so it BLOCKS (bounded) rather than let a possibly-
# dishonest exit through. Point the REAL gate at a FAKE plugin root whose idc_autorun_drain.py is a
# crashing stub (exit 1 — an uncaught traceback, OUTSIDE the Phase-0 {0,2,3,4} contract) for a marked
# orchestrator session. The gate still imports the real idc_hook_lib/idc_ledger from its own dir; only
# the drain it spawns is the stub. Red-when-broken: revert the exit-contract raise in _board_says_pending
# (return board_pending=False instead of raising on a non-contract exit) ⇒ the gate ALLOWS ⇒ this RED.
FAKE="$WORK/fakeplugin"; mkdir -p "$FAKE/scripts"
cat > "$FAKE/scripts/idc_autorun_drain.py" <<'PY'
import sys
sys.stderr.write("boom: simulated drain crash\n")
sys.exit(1)   # OUTSIDE the Phase-0 exit-code contract {0,2,3,4} — an untrustworthy verdict
PY
SID_FC="stopsess-fc-$$-$(basename "$WORK")"
led set --kind orchestrator_drain --session "$SID_FC" >/dev/null || fail "fail-closed: could not set the orchestrator marker"
OUT_FC="$(mk_payload "$REPO" "$SID_FC" | python3 "$GATE" "$FAKE" 2>/dev/null)"; RC_FC=$?
blocks "$OUT_FC" \
  || fail "(fail-closed) a crashing drain (exit outside {0,2,3,4}) for a confirmed orchestrator MUST fail closed and BLOCK — got no block (RC=$RC_FC, out=$OUT_FC) [revert the exit-contract raise ⇒ RED]"
printf '%s' "$OUT_FC" | grep -qi 'could not verify' \
  || fail "(fail-closed) the block reason must say it could not verify the drain state (got: $OUT_FC)"
# The orchestrator_drain marker MUST SURVIVE an unverifiable (fail-closed) stop — the obligation is NOT
# satisfied (the pipe was never proven drained), so the m5 gate-side clear must fire ONLY on a proven
# `drain: complete`, never here. If m5 cleared the marker on a fail-closed stop the obligation would be
# silently lost (a later stop would fast-path through the self-gate). Directly pins "clear on clean-
# complete ONLY, never on fail-closed/unknown/rate-limited".
led pending --session "$SID_FC" | grep -qx 'orchestrator_drain' \
  || fail "(fail-closed) the orchestrator_drain marker MUST survive an unverifiable (fail-closed) stop — m5 must clear ONLY on a proven drain: complete, never on a fail-closed/pending stop"
echo "  ok (fail-closed) a crashing drain (exit outside the {0,2,3,4} contract) ⇒ the gate fails CLOSED and blocks (and the marker survives — m5 clears on clean-complete only)"

# ── (acceptance-gap) an INERT wave close is board-pending at the stop too (Stage E3) ───────────────
# A SECOND governed repo whose board is would-be-complete (build lane drained, EMPTY inbox) but holds
# an inert merged-Done item (unmet blocks_goal:true deferral). The gate's filesystem re-run passes
# `--acceptance` (Stage E3), so the drain reports `drain: acceptance-gap` exit 4 → the stop BLOCKS.
# Red-when-broken: drop `--acceptance` from the gate's drain invocation (_board_says_pending) ⇒ the
# same board reads `drain: complete` ⇒ the gate ALLOWS (and clears the marker) ⇒ this asserts RED.
REPO_AG="$WORK/repo-ag"; mkdir -p "$REPO_AG/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_AG/docs/workflow/tracker-config.yaml"
TAG_T="$REPO_AG/TRACKER.md"
python3 "$TRK" --tracker "$TAG_T" init >/dev/null || fail "(acceptance-gap) tracker init failed"
DONE_AG="$(python3 "$TRK" --tracker "$TAG_T" create --title 'ddl merged, instance not provisioned' --stage Buildable --status Done)" \
  || fail "(acceptance-gap) seed of the inert Done failed"
python3 "$TRK" --tracker "$TAG_T" comment --num "$DONE_AG" \
  --body '<!-- idc-deferral: {"kind":"infra","what":"provision the instance","blocks_goal":true,"suggested_issue":"none"} -->' \
  >/dev/null || fail "(acceptance-gap) could not attach the blocks_goal deferral marker"
# precondition: WITHOUT --acceptance this board drains complete/0 — only the E3 gate makes it pending.
python3 "$DRAIN" --tracker "$TAG_T" >/dev/null 2>&1; [ $? -eq 0 ] \
  || fail "(acceptance-gap) precondition: the inert board must drain complete/0 without --acceptance"
SID_AG="stopsess-ag-$$-$(basename "$WORK")"
python3 "$LEDGER" --cwd "$REPO_AG" set --kind orchestrator_drain --session "$SID_AG" >/dev/null \
  || fail "(acceptance-gap) could not set the orchestrator marker"
OUT_AG="$(mk_payload "$REPO_AG" "$SID_AG" | python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"
blocks "$OUT_AG" \
  || fail "(acceptance-gap) an orchestrator stop on an INERT wave close (drain: acceptance-gap) must BLOCK — got: ${OUT_AG:-<allow>} [drop --acceptance from the gate's drain re-run ⇒ RED]"
printf '%s' "$OUT_AG" | grep -qi 'inert' \
  || fail "(acceptance-gap) the block reason must name the INERT merged-Done diagnosis (got: $OUT_AG)"
# the marker must SURVIVE the blocked stop (the obligation is unmet — no false clear on acceptance-gap)
python3 "$LEDGER" --cwd "$REPO_AG" pending --session "$SID_AG" | grep -qx 'orchestrator_drain' \
  || fail "(acceptance-gap) the orchestrator_drain marker must survive an acceptance-gap block (clear fires on proven complete only)"
echo "  ok (acceptance-gap) an inert wave close (Stage E3) blocks the stop via the gate's --acceptance re-run (marker survives)"

echo "PASS: the Stop fixpoint gate refuses a drain-orchestrator exit with a non-empty inbox (drain: recirc-pending) OR an inert wave close (drain: acceptance-gap, Stage E3), names the /idc:recirculate remediation, LOUD-FAILS on the 4th stop while STILL blocking (one board annotation only), honors observe-only, and fails CLOSED on a crashing drain"
