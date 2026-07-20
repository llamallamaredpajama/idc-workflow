#!/bin/bash
# idc-assert-class: behavior
# stop-github-persisted-verdict.sh — governance scenario: the Stop fixpoint gate gates a GITHUB-backend
# autorun/build orchestrator stop from the LOCAL persisted drain verdict, with ZERO new GraphQL on the
# stop path (v4 Phase 3 Stage E2).
#
# The invariant. Stage B shipped the Stop gate for the FILESYSTEM backend (a cheap live drain) and
# DEFERRED github (a live drain there is an expensive board read — banned on the stop path). Stage E2
# closes that hole WITHOUT a board scan: idc_autorun_drain.py persists {verdict, exit, session_id} to a
# gitignored .idc-drain-verdict.json on every drain pass, and the gate's github branch READS that local
# file (session-matched) instead of deferring. The block still needs BOTH conjuncts (board AND ledger);
# the persisted verdict supplies only the BOARD conjunct for github.
#
# Cases (all github backend):
#   (1) persisted recirc-pending (exit 4) for THIS session  ⇒ BLOCK (bounded N=3 → loud-fail-allow),
#       AND the drain binary is NEVER spawned on the stop path (0 GraphQL — a tripwire drain proves it);
#   (2) persisted `complete` (exit 0)                        ⇒ ALLOW (board conjunct false — the crux);
#   (3) NO persisted verdict for this session               ⇒ DEFER (allow + warn) — never guesses;
#   (4) persisted verdict for a DIFFERENT session           ⇒ not used ⇒ defer/allow (session scope);
#   (5) ledger-alone-never-blocks on github: persisted `complete` + a lingering mid_finish taint ⇒ ALLOW.
#
# Red-when-broken (MANDATORY, reviewed):
#   * neuter the session-match (current_verdict returns any session's verdict) ⇒ case (4) BLOCKS ⇒ RED;
#   * make the github branch re-defer (return False,False unconditionally) ⇒ case (1) stops blocking ⇒ RED;
#   * drop the persist in the drain / the write in current_verdict ⇒ case (1) can't block ⇒ RED.
#
# github backend but hermetic — NO gh is ever called: the persisted verdict is seeded via the
# idc_drain_verdict.py CLI (what the drain does during the loop), and the gate reads ONLY that local
# file. Auto-discovered by the governance lane; runnable standalone under BOTH python3 and
# `uv run --with pyyaml`.
#
# Usage: bash tests/smoke/governance/stop-github-persisted-verdict.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

GATE="$GOV_PLUGIN/scripts/hooks/idc_stop_fixpoint_gate.py"
LEDGER="$GOV_PLUGIN/scripts/hooks/idc_ledger.py"
VERDICT="$GOV_PLUGIN/scripts/hooks/idc_drain_verdict.py"
DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
[ -f "$GATE" ]    || fail "stop-fixpoint gate not found at $GATE (not implemented yet)"
[ -f "$VERDICT" ] || fail "drain-verdict module not found at $VERDICT (Stage E2 not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: github\n' > "$REPO/docs/workflow/tracker-config.yaml"   # github backend + IDC-governed

# A TRIPWIRE plugin root: its idc_autorun_drain.py DIES + drops a sentinel if ever spawned. The github
# stop path must read ONLY the local persisted verdict, so this drain must NEVER run. We point the gate
# at this fake root; it still imports the real idc_hook_lib/idc_ledger/idc_drain_verdict from its own
# scripts/hooks dir (only the drain BINARY it might shell is the tripwire).
TRIP="$WORK/tripplugin"; mkdir -p "$TRIP/scripts"
SENTINEL="$WORK/DRAIN_WAS_SPAWNED"
cat > "$TRIP/scripts/idc_autorun_drain.py" <<PY
import sys
open("$SENTINEL", "w").close()   # tripwire: the stop path spawned the drain (a GraphQL board read)
sys.stderr.write("TRIPWIRE: idc_autorun_drain.py was spawned on the github stop path\n")
sys.exit(4)
PY

led()  { python3 "$LEDGER"  --cwd "$REPO" "$@"; }
vwrite() { python3 "$VERDICT" --cwd "$REPO" write "$@"; }

mk_payload() { python3 - "$1" "$2" <<'PY'
import json,sys
cwd,sid=sys.argv[1:3]
print(json.dumps({"hook_event_name":"Stop","cwd":cwd,"session_id":sid,
 "transcript_path":"","stop_hook_active":False}))
PY
}
ERRLOG="$WORK/stderr.log"
run_gate() { : > "$ERRLOG"; GATE_OUT="$(mk_payload "$REPO" "$1" | python3 "$GATE" "$TRIP" 2>"$ERRLOG")"; GATE_RC=$?; }
blocks() { printf '%s' "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null; }
no_trip() { [ ! -e "$SENTINEL" ] || fail "0-GraphQL VIOLATED: the drain binary was spawned on the github stop path (sentinel exists) — the gate must read ONLY the local persisted verdict"; }

# ── (1) persisted recirc-pending (exit 4) for THIS session ⇒ BLOCK (N=3) then ALLOW, drain NEVER spawned
SID="ghsess-$$-$(basename "$WORK")"
led    set --kind orchestrator_drain --session "$SID" >/dev/null || fail "could not set the orchestrator_drain marker"
led    set --kind mid_finish --key 42 --session "$SID" >/dev/null || fail "could not set the mid_finish taint"
vwrite --verdict recirc-pending --exit 4 --session "$SID"          || fail "could not persist the recirc-pending verdict"
blocked=0; allowed_on=""; FIRST_OUT=""
for i in 1 2 3 4 5; do
  run_gate "$SID"
  no_trip
  [ "$i" -eq 1 ] && FIRST_OUT="$GATE_OUT"
  if blocks "$GATE_OUT"; then
    blocked=$((blocked + 1))
    [ "$i" -le 3 ] || fail "gate blocked on try $i — the N=3 bound is not enforced (infinite-nag risk)"
  else
    allowed_on="$i"; break
  fi
done
[ "$blocked" -eq 3 ]    || fail "expected exactly 3 blocks before the loud-fail, got $blocked [re-defer / drop-persist ⇒ RED]"
[ "$allowed_on" = "4" ] || fail "expected the 4th stop to be ALLOWED (loud-fail), got '$allowed_on' (infinite-nag risk)"
printf '%s' "$FIRST_OUT" | grep -q '/idc:recirculate' || fail "block reason must name the /idc:recirculate remediation (got: $FIRST_OUT)"
[ ! -e "$SENTINEL" ]    || fail "0-GraphQL VIOLATED across the whole block loop — the drain was spawned"
echo "  ok (1) persisted recirc-pending (exit 4) for THIS session ⇒ blocks 3× then allows — AND the drain binary was NEVER spawned (0 GraphQL)"

# ── (2) persisted `complete` (exit 0) ⇒ ALLOW (board conjunct false — the crux allow) ───────────────
# Fresh session id so the anti-nag counter is clean; last-write-wins overwrites nothing (new session).
SID2="ghsess2-$$-$(basename "$WORK")"
led    set --kind orchestrator_drain --session "$SID2" >/dev/null || fail "(2) marker set failed"
vwrite --verdict complete --exit 0 --session "$SID2" --gates coherence,live \
                                                                  || fail "(2) could not persist the complete verdict"
run_gate "$SID2"; no_trip
blocks "$GATE_OUT" && fail "(2) THE CRUX FAILED: a persisted drain: complete must ALLOW the stop (board conjunct false) — got a block [re-map exit/verdict ⇒ RED]"
[ "$GATE_RC" -eq 0 ] || fail "(2) a complete-verdict stop must exit 0 (allow), got $GATE_RC"
led pending --session "$SID2" | grep -qx 'orchestrator_drain' \
  && fail "(2) m5: a proven github drain: complete must CLEAR the orchestrator_drain marker (obligation satisfied)"
echo "  ok (2) persisted drain: complete ⇒ ALLOW (the crux) + m5 clears the orchestrator marker"

# ── (3) NO persisted verdict for this session ⇒ DEFER (allow + warn) — never guesses ────────────────
SID3="ghsess3-$$-$(basename "$WORK")"
led set --kind orchestrator_drain --session "$SID3" >/dev/null || fail "(3) marker set failed"
# (no vwrite for SID3 — the .idc-drain-verdict.json still holds SID2's verdict, a DIFFERENT session)
run_gate "$SID3"; no_trip
blocks "$GATE_OUT" && fail "(3) no persisted verdict for THIS session must DEFER (allow), not block — you can only gate on data you have"
[ "$GATE_RC" -eq 0 ] || fail "(3) a defer must allow exit 0, got $GATE_RC"
grep -qi 'no persisted drain verdict\|deferring' "$ERRLOG" || fail "(3) the defer must WARN that there is no persisted verdict for this session (got stderr: $(cat "$ERRLOG"))"
echo "  ok (3) no persisted verdict for this session ⇒ DEFER (allow + warn), never a guess"

# ── (4) a persisted verdict for a DIFFERENT session ⇒ not used ⇒ defer/allow (session scope) ─────────
# Persist a recirc-pending owned by a FOREIGN session; the stopping session has the orchestrator marker
# but no verdict of its OWN. A broken session-match would read the foreign recirc-pending and BLOCK.
SID4="ghsess4-$$-$(basename "$WORK")"
FOREIGN="foreign-$$-$(basename "$WORK")"
led    set --kind orchestrator_drain --session "$SID4" >/dev/null || fail "(4) marker set failed"
vwrite --verdict recirc-pending --exit 4 --session "$FOREIGN"     || fail "(4) could not persist the foreign recirc-pending verdict"
run_gate "$SID4"; no_trip
blocks "$GATE_OUT" && fail "(4) SESSION-SCOPE BROKEN: a persisted recirc-pending owned by a DIFFERENT session must NEVER gate this stop — got a block [neuter the session-match ⇒ RED]"
[ "$GATE_RC" -eq 0 ] || fail "(4) a foreign-verdict stop must defer/allow exit 0, got $GATE_RC"
echo "  ok (4) a foreign-session persisted verdict is invisible ⇒ DEFER/allow (session scope)"

# ── (5) ledger-alone-never-blocks on github: persisted `complete` + a lingering mid_finish ⇒ ALLOW ──
# The board conjunct (github) is FALSE (drain: complete), so a lingering ledger obligation must not hold
# the stop — exactly the filesystem crux, now proven on the github persisted-verdict path.
SID5="ghsess5-$$-$(basename "$WORK")"
led    set --kind orchestrator_drain --session "$SID5" >/dev/null || fail "(5) marker set failed"
led    set --kind mid_finish --key 7 --session "$SID5"  >/dev/null || fail "(5) could not set the lingering mid_finish taint"
vwrite --verdict complete --exit 0 --session "$SID5" --gates coherence,live \
                                                                  || fail "(5) could not persist the complete verdict"
run_gate "$SID5"; no_trip
blocks "$GATE_OUT" && fail "(5) LEDGER-ALONE broke on github: a clean persisted drain: complete must ALLOW even with a lingering mid_finish taint — the ledger alone never blocks a clean board"
[ "$GATE_RC" -eq 0 ] || fail "(5) a clean-board github stop must allow exit 0, got $GATE_RC"
led pending --session "$SID5" | grep -qx 'mid_finish:7' \
  || fail "(5) the mid_finish:7 obligation must survive (m5 clears ONLY the orchestrator marker on a clean complete)"
echo "  ok (5) ledger-alone-never-blocks holds on github (persisted complete + lingering taint ⇒ allow; the taint survives)"

# ══ Case 5b — AN UNGATED `complete` IS NOT PROOF OF COMPLETION ══════════════════════════════════════
# THE HOLE THIS CLOSES. The wave-close gates (--coherence/--live) are opt-in FLAGS, so the drain prints
# and persists an IDENTICAL `complete` whether it checked the board against reality or checked nothing.
# Sanctioned callers legitimately run it ungated — `idc:idc-build` Phase 0 uses `--width` alone to size
# the ready frontier — and last-write-wins means that pass OVERWRITES a properly gated verdict. On the
# filesystem backend the gate re-runs the drain itself with all three flags, so it has a backstop; on
# GITHUB it cannot (the zero-GraphQL constraint), so it believes this file. Before the fix, an ungated
# frontier query could therefore launder an unchecked pipe into a cleared orchestrator marker — on the
# very backend where the seven-stale-card incident happened.
#
# THE CONTRACT: an ungated `complete` is neither a block (it proves no pending work either) nor a clean
# bill of health. It lands in the EXISTING no-fresh-verdict path — allow the stop, warn, and LEAVE THE
# MARKER — so nothing is laundered and nothing is wedged.
#
# Red-when-broken (verified by mutation): make _github_says_pending read `verdict == "complete"` again
# instead of proves_complete(), and the marker is cleared ⇒ this case FAILS.
SID6="ghsess6-$$-$(basename "$WORK")"
led    set --kind orchestrator_drain --session "$SID6" >/dev/null || fail "(5b) marker set failed"
vwrite --verdict complete --exit 0 --session "$SID6"              || fail "(5b) could not persist the ungated complete verdict"
run_gate "$SID6"; no_trip
blocks "$GATE_OUT" && fail "(5b) an ungated complete must ALLOW the stop (it proves no pending work either) — got a block; the fix must not wedge a stop, only refuse to call it proven"
[ "$GATE_RC" -eq 0 ] || fail "(5b) an ungated-complete stop must allow exit 0, got $GATE_RC"
led pending --session "$SID6" | grep -qx 'orchestrator_drain' \
  || fail "(5b) LAUNDERING: an UNGATED persisted complete (no --coherence/--live recorded) must NOT clear the orchestrator marker — only a verdict that NAMES the gates that ran is proof of completion [read verdict=='complete' instead of proves_complete ⇒ RED]"
grep -qi 'does not record the wave-close gates' "$ERRLOG" \
  || fail "(5b) the ungated-complete defer must WARN why it is not proof (got stderr: $(cat "$ERRLOG"))"
# And a verdict recording only PART of the required set is equally not proof (no partial credit).
SID7="ghsess7-$$-$(basename "$WORK")"
led    set --kind orchestrator_drain --session "$SID7" >/dev/null || fail "(5b) marker set failed for the partial-gates case"
vwrite --verdict complete --exit 0 --session "$SID7" --gates live || fail "(5b) could not persist the partial-gates verdict"
run_gate "$SID7"; no_trip
led pending --session "$SID7" | grep -qx 'orchestrator_drain' \
  || fail "(5b) a complete recording only SOME of the required wave-close gates must NOT clear the marker (no partial credit)"
echo "  ok (5b) an ungated (or partially gated) persisted complete allows the stop but is NOT proof — the orchestrator marker survives"

# ══ Case 6 — GITIGNORE SELF-HEAL: persisting a verdict must never leave committed litter ═════════════
# A repo installed BEFORE Stage E2 can run autorun before it ever updates, so the drain's FIRST verdict
# write must self-heal the repo-root .gitignore (idempotently) — otherwise a `git add -A` would commit
# the transient .idc-drain-verdict.json. Every vwrite above targeted $REPO (a governed repo), so its
# .gitignore must now carry the ignore glob, exactly once.
# Red-when-broken: drop the ensure_gitignored() call in write_verdict ⇒ the line is absent ⇒ RED.
GI="$REPO/.gitignore"
[ -f "$GI" ] || fail "(6) persisting a verdict did not create the repo-root .gitignore (litter risk) [drop ensure_gitignored ⇒ RED]"
grep -qxF '.idc-drain-verdict.json*' "$GI" \
  || fail "(6) .gitignore must ignore '.idc-drain-verdict.json*' after a persist (litter risk) [drop ensure_gitignored ⇒ RED]"
[ "$(grep -cxF '.idc-drain-verdict.json*' "$GI")" -eq 1 ] \
  || fail "(6) the gitignore self-heal must be idempotent — exactly ONE ignore line after many writes"
echo "  ok (6) gitignore self-heal: the verdict file is ignored after the first persist (idempotent, no litter)"

echo "PASS: the Stop fixpoint gate gates a github stop from the LOCAL persisted drain verdict with ZERO GraphQL — recirc-pending blocks (bounded, drain never spawned), complete allows + clears the marker, a missing or foreign-session verdict defers, the ledger alone never blocks a clean board, and persisting a verdict self-heals the gitignore (no committed litter)"
