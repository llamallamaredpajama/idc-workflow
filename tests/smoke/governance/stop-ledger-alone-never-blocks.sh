#!/bin/bash
# idc-assert-class: behavior
# stop-ledger-alone-never-blocks.sh — THE CRUX of the Stop fixpoint gate (v4 Phase 3 Stage B, §3.4):
# the ledger is a HINT, the board + `drain --fixpoint` are GROUND TRUTH, and a stale ledger taint must
# NEVER block a clean board — a clean `drain: complete` (exit 0) wins over any un-cleared obligation.
#
# The scenario pins all three faces of the design:
#   (crux)      an orchestrator drain session that HOLDS a stale mid_finish obligation, but whose board
#               is clean (drain: complete), does NOT block. The ledger alone cannot hold the stop.
#   (control)   the very same session, once the board flips to a non-empty inbox (drain: recirc-pending),
#               DOES block — proving the board conjunct is live and the crux ALLOW is the board talking,
#               not a broken gate.
#   (self-gate) a session with NO orchestrator_drain marker is never blocked (even with a non-empty
#               inbox) — a random claude session in a governed repo is spared.
#
# Red-when-broken (MANDATORY, reviewed): make the gate block on the ledger alone — i.e. drop the board
# conjunct (change `if board_pending and ledger_pending:` to `if ledger_pending:`) — and the (crux)
# assert goes RED (the stale taint would then block the clean board). Neuter the self-gate (drop the
# orchestrator_drain check) and the (self-gate) assert goes RED.
#
# Filesystem-backed (hermetic, no gh). Auto-discovered by the governance lane (phase-governance.sh);
# runnable standalone under BOTH python3 and `uv run --with pyyaml`.
#
# Usage: bash tests/smoke/governance/stop-ledger-alone-never-blocks.sh   (exit 0 = pass)
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
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
T="$REPO/TRACKER.md"
python3 "$TRK" --tracker "$T" init >/dev/null || fail "tracker init failed"
# CLEAN board: no Recirculation/Consideration inbox, no eligible build work → drain: complete exit 0.
python3 "$DRAIN" --tracker "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "precondition: an empty board must be drain: complete exit 0 (got $rc)"

led() { python3 "$LEDGER" --cwd "$REPO" "$@"; }
mk_payload() { python3 - "$1" "$2" <<'PY'
import json,sys
cwd,sid=sys.argv[1:3]
print(json.dumps({"hook_event_name":"Stop","cwd":cwd,"session_id":sid,
 "transcript_path":"","stop_hook_active":False}))
PY
}
# A Stop payload with NO session_id key at all (an unattributable session) — used by the (absent-sid) case.
mk_payload_nosid() { python3 - "$1" <<'PY'
import json,sys
cwd=sys.argv[1]
print(json.dumps({"hook_event_name":"Stop","cwd":cwd,
 "transcript_path":"","stop_hook_active":False}))
PY
}
blocks() { printf '%s' "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null; }

# ── (crux) a stale mid_finish obligation + a clean board (drain: complete) ⇒ NO block ──────────────
SID="stopsess-$$-$(basename "$WORK")"
# This orchestrator session is marked active AND holds an un-cleared mid_finish obligation (a crash
# mid-finish that never cleared) — the ledger LOUDLY says "work remains".
led set --kind orchestrator_drain --session "$SID" >/dev/null || fail "could not set the orchestrator marker"
led set --kind mid_finish --key 42 --session "$SID"      >/dev/null || fail "could not set the stale mid_finish taint"
led pending --session "$SID" | grep -q 'mid_finish:42' || fail "precondition: the stale taint must be pending for this session"
OUT="$(mk_payload "$REPO" "$SID" | python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"; RC=$?
blocks "$OUT" && fail "THE CRUX FAILED: the gate BLOCKED a clean board on a stale ledger taint alone — the ledger must NEVER block a clean board (drain: complete wins) [neuter: block on the ledger alone ⇒ RED]"
[ "$RC" -eq 0 ] || fail "a clean-board stop must exit 0 (allow), got $RC"
echo "  ok (crux) a stale mid_finish taint + drain: complete ⇒ the gate does NOT block (ground truth wins)"

# ── (m5) the clean-complete stop CLEARS the orchestrator_drain marker (obligation satisfied) ────────
# A confirmed orchestrator stopping on a PROVEN-complete pipe (drain: complete) has met its drain
# obligation, so the gate clears its orchestrator_drain marker — a completed run then leaves NO stale
# marker to misclassify a LATER unrelated stop (removes MAJOR-3's fuel). It clears ONLY the marker: the
# session's other obligations (the stale mid_finish:42) must survive, cleared by their own completion
# points. Red-when-broken: neuter the `if board_complete: clear_taint(...)` in _gate ⇒ the marker
# persists ⇒ the "must be cleared" assert goes RED.
led pending --session "$SID" | grep -qx 'orchestrator_drain' \
  && fail "(m5) after a clean-complete stop the orchestrator_drain marker must be CLEARED (obligation satisfied) [neuter the board_complete clear ⇒ RED]"
led pending --session "$SID" | grep -qx 'mid_finish:42' \
  || fail "(m5) the clean-stop clear must remove ONLY the orchestrator marker — the mid_finish:42 obligation must remain (its own completion point clears it, not the stop gate)"
echo "  ok (m5) a clean-complete stop clears ONLY the orchestrator_drain marker (mid_finish:42 survives) — one fewer misclassify fuel"

# ── (control) flip the board to recirc-pending: the SAME kind of session now BLOCKS ────────────────
# Proves the board conjunct is LIVE — the crux ALLOW above is the board (drain: complete), not a dead
# gate. Fresh session id so the anti-nag counter is clean.
python3 "$TRK" --tracker "$T" create --title 'recirc: x' --stage Recirculation --status Todo >/dev/null \
  || fail "could not seed the recirc inbox ticket for the control"
python3 "$DRAIN" --tracker "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] || fail "control precondition: the board must now be drain: recirc-pending exit 4 (got $rc)"
SID2="stopsess2-$$-$(basename "$WORK")"
led set --kind orchestrator_drain --session "$SID2" >/dev/null || fail "control marker set failed"
OUT2="$(mk_payload "$REPO" "$SID2" | python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"
blocks "$OUT2" || fail "control: with the inbox now non-empty (drain: recirc-pending) the gate MUST block — else the board conjunct is dead and the crux ALLOW is meaningless"
echo "  ok (control) once the board flips to recirc-pending the same session blocks — the board conjunct is live"

# ── (self-gate) a session with NO orchestrator_drain marker is never blocked ───────────────────────
# The board is STILL non-empty here (recirc-pending), and to make the SELF-GATE the ONLY thing sparing
# this session, give it an obligation taint (mid_finish) but NO orchestrator marker — so board_pending
# AND ledger_pending are both true and ONLY the missing marker holds the block off. A random claude
# session doing unrelated work in this governed repo (that happens to have an un-cleared taint) must be
# spared. Red-when-broken: drop the self-gate (the orchestrator_drain check) and this session BLOCKS.
SID3="randomsess-$$-$(basename "$WORK")"
led set --kind mid_finish --key 7 --session "$SID3" >/dev/null || fail "could not seed the un-marked session's taint"
OUT3="$(mk_payload "$REPO" "$SID3" | python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"; RC3=$?
blocks "$OUT3" && fail "self-gate broken: a session with no orchestrator_drain marker must NEVER be blocked, even with a non-empty inbox AND an obligation taint [neuter the self-gate ⇒ RED]"
[ "$RC3" -eq 0 ] || fail "an un-marked (non-orchestrator) session must allow exit 0, got $RC3"
echo "  ok (self-gate) an un-marked session (with a taint but no marker) is never blocked — only the marker gates"

# ── (absent-sid) a Stop payload with NO session_id ⇒ ALLOW, even with a stale dead-session marker ────
# The board is STILL recirc-pending here. A payload with no session_id cannot be attributed to THIS
# session; pending_taints(cwd, session_id=None) returns the UNSCOPED taint set, so a stale
# orchestrator_drain marker left by a DIFFERENT (dead) session would misclassify this unattributable
# stop as an orchestrator drain → false BLOCK over the recirc-pending board. A session we cannot
# attribute is not provably an orchestrator: the gate must ALLOW it (fail-open-before-classify).
# Red-when-broken: drop the `if not sid: allow` guard in _gate and this stop BLOCKS (the dead-session
# marker classifies it as an orchestrator over the live recirc-pending board).
led set --kind orchestrator_drain --session "deadsess-$$-$(basename "$WORK")" >/dev/null \
  || fail "could not seed the dead-session stale orchestrator marker"
OUT4="$(mk_payload_nosid "$REPO" | python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"; RC4=$?
blocks "$OUT4" && fail "absent-sid broken: a Stop payload with no session_id must ALLOW even with a stale orchestrator_drain marker from a dead session over a recirc-pending board [drop the absent-sid guard ⇒ RED]"
[ "$RC4" -eq 0 ] || fail "an unattributable (no session_id) stop must allow exit 0, got $RC4"
echo "  ok (absent-sid) a stop with no session_id is allowed even with a stale dead-session marker over a recirc-pending board"

# ── (m5-continue) a CONFIRMED orchestrator stop on a NON-complete clean board (drain: continue) ALLOWS
#    but does NOT clear the marker — m5 clears on `drain: complete` (whole-pipe fixpoint) ONLY, never on
#    `continue` (eligible build work remains — the obligation is NOT satisfied; /loop iterates on it).
#    This pins the exact boundary: clean-COMPLETE clears (crux above), clean-CONTINUE does not.
#    Red-when-broken: drop the `board_complete` guard on the m5 clear (clear on ANY clean allow) ⇒ the
#    marker is dropped here on a still-pending pipe ⇒ the "must survive" assert goes RED.
python3 "$TRK" --tracker "$T" create --title 'build: eligible' --stage Buildable --status Todo >/dev/null \
  || fail "(m5-continue) could not seed a Buildable item to force drain: continue"
python3 "$DRAIN" --tracker "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "(m5-continue) precondition: an eligible Buildable item must make the board drain: continue exit 0 (got $rc)"
SID5="stopsess5-$$-$(basename "$WORK")"
led set --kind orchestrator_drain --session "$SID5" >/dev/null || fail "(m5-continue) marker set failed"
OUT5="$(mk_payload "$REPO" "$SID5" | python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"; RC5=$?
blocks "$OUT5" && fail "(m5-continue) a drain: continue stop must ALLOW — build work is exactly what /loop iterates on — not block"
[ "$RC5" -eq 0 ] || fail "(m5-continue) a drain: continue stop for a confirmed orchestrator must allow exit 0, got $RC5"
led pending --session "$SID5" | grep -qx 'orchestrator_drain' \
  || fail "(m5-continue) the orchestrator_drain marker MUST survive a drain: continue stop — m5 clears on drain: complete ONLY, not on continue [drop the board_complete guard ⇒ RED]"
echo "  ok (m5-continue) a confirmed-orchestrator stop on a drain: continue board allows AND keeps the marker (m5 clears on complete only)"

echo "PASS: the ledger is a HINT, the board is GROUND TRUTH — a stale taint never blocks a clean board (drain: complete wins), the board conjunct is live (recirc-pending blocks the same session), the self-gate spares un-marked sessions, an unattributable (no-session_id) stop is allowed even against a stale dead-session marker, and m5 clears the marker on a proven drain: complete ONLY (survives continue)"
