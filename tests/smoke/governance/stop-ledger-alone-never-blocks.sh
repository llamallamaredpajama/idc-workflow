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

echo "PASS: the ledger is a HINT, the board is GROUND TRUTH — a stale taint never blocks a clean board (drain: complete wins), the board conjunct is live (recirc-pending blocks the same session), and the self-gate spares un-marked sessions"
