#!/bin/bash
# idc-assert-class: behavior
# main-session-recirc-reconcile.sh — governance scenario: the MAIN-SESSION recirculation
# closeout-or-checkpoint reconciliation (v4 Phase 3 Stage E1, drop F — the main-session/kill-safe path).
#
# The invariant (plan §3.2 drop F, main-session path): the PRIMARY /idc:recirculate drain runs in the
# MAIN session, so NO SubagentStop fires for it and a HARD KILL fires no hook at all — Stage C's
# SubagentStop gate never sees it. scripts/idc_recirc_reconcile.py closes that hole: run from the drain
# loop (top of each autorun pass = kill-recovery, and end-of-/idc:recirculate), it reconciles every
# still-open Stage=Recirculation ∧ Status=Todo inbox ticket against the obligations ledger —
#   * CHECKPOINT an open ticket with NO recirc_checkpoint taint yet (stamp a resume comment via the
#     SANCTIONED comment helper + set the taint);
#   * the taint is the IDEMPOTENCE LATCH — an open ticket that ALREADY has it is skipped (no dup comment);
#   * CLEAR the taint for any ticket that has LEFT the open inbox (absorbed/Done/Blocked — the
#     "action completed" clear branch), ticket-keyed + cross-session (kill-recovery clears a dead
#     prior session's stale breadcrumb once its ticket is provably gone);
#   * a read failure (still_open==None — unreadable board) FAILS SAFE: clears nothing, stamps nothing,
#     reports `reconcile: unknown` (never a false "empty") — under-checkpointing IS the state loss.
# Transcript-LESS core (the board is ground truth for "covered"): a validly-closed-out ticket has left
# the open inbox, so the still-open set IS the un-disposed set. It is a fail-SOFT drain-loop ACTION
# step (never crashes the loop) and is repo-gated.
#
# Red-when-broken (MANDATORY, reviewed) — each neuter is IN idc_recirc_reconcile.py:
#   * neuter the CHECKPOINT-STAMP (make the `for t in still_open` stamp/taint loop a no-op) ⇒ case 1's
#     "every open inbox ticket is checkpointed (comment + taint)" asserts go RED;
#   * neuter the CLEAR branch (force `cleared = []`) ⇒ case 3's "a ticket that left the inbox has its
#     taint CLEARED" assert goes RED;
#   * neuter the IDEMPOTENCE LATCH (drop the `if t in existing: continue`) ⇒ case 2's "no duplicate
#     checkpoint comment on a re-run" assert goes RED (the comment count climbs to 2);
#   * neuter the READ-FAILURE fail-safe (treat `still_open is None` as an empty inbox) ⇒ case 4's
#     "an unreadable inbox PRESERVES the taint (never wiped)" assert goes RED.
#
# Filesystem-backed (hermetic, no gh). Auto-discovered by the governance lane (phase-governance.sh);
# runnable standalone under BOTH python3 and `uv run --with pyyaml` (a clean no-pyyaml venv python).
#
# Usage: bash tests/smoke/governance/main-session-recirc-reconcile.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

RECON="$GOV_PLUGIN/scripts/idc_recirc_reconcile.py"
LEDGER="$GOV_PLUGIN/scripts/hooks/idc_ledger.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$RECON" ] || fail "idc_recirc_reconcile.py not found at $RECON (not implemented yet)"
[ -f "$TRK" ]   || fail "filesystem tracker helper not found at $TRK"

# ── a governed filesystem repo with an initialized tracker → echoes the REPO dir ──────────────────
new_repo() {
  local d; d="$(mktemp -d)" || return 1
  mkdir -p "$d/docs/workflow"
  printf 'backend: filesystem\n' > "$d/docs/workflow/tracker-config.yaml"   # marks REPO IDC-governed
  python3 "$TRK" --tracker "$d/TRACKER.md" init >/dev/null || return 1
  printf '%s' "$d"
}
seed()     { python3 "$TRK" --tracker "$1/TRACKER.md" create --title "$4" --stage "$2" --status "$3"; }
move()     { python3 "$TRK" --tracker "$1/TRACKER.md" move --num "$2" --status "$3" >/dev/null; }
comments() { python3 "$TRK" --tracker "$1/TRACKER.md" show --num "$2" --comments; }
led()      { python3 "$LEDGER" --cwd "$1" "${@:2}"; }
has_ckpt() { comments "$1" "$2" | grep -q 'idc-recirc-checkpoint'; }
ckpt_count() { comments "$1" "$2" | grep -c 'idc-recirc-checkpoint'; }
has_taint() { led "$1" pending --session "$2" | grep -qx "recirc_checkpoint:$3"; }

# run_recon <repo> <session> -> stdout in $OUT, exit in $RC, stderr in $ERR
ERRFILE=""
run_recon() {
  OUT="$(python3 "$RECON" --repo "$1" --session-id "$2" 2>"$ERRFILE")"; RC=$?
}
val() { printf '%s\n' "$OUT" | grep -E "^$1:" | head -1 | sed -E "s/^$1:[[:space:]]*//"; }

WORK="$(mktemp -d)"; ERRFILE="$WORK/err.log"; trap 'rm -rf "$WORK" "${REPOS[@]:-}"' EXIT
REPOS=()

# ══ Case 1 — KILL MID-DRAIN (no closeout evidence) ⇒ EVERY still-open inbox ticket is checkpointed ══
# A main-session drain died (or was hard-killed) mid-way, leaving three Stage=Recirculation ∧ Todo
# tickets with no resume-checkpoint and no ledger taint. The next-pass reconciliation must stamp a
# checkpoint comment + set a recirc_checkpoint taint on EVERY one — that is the whole drop-F repair.
# Red-when-broken: neuter the stamp/taint loop ⇒ none are checkpointed ⇒ these asserts go RED.
R1="$(new_repo)" || fail "new_repo 1 failed"; REPOS+=("$R1")
A1="$(seed "$R1" Recirculation Todo 'recirc: killed mid-drain, ticket 1')" || fail "seed A1"
A2="$(seed "$R1" Recirculation Todo 'recirc: killed mid-drain, ticket 2')" || fail "seed A2"
A3="$(seed "$R1" Recirculation Todo 'recirc: killed mid-drain, ticket 3')" || fail "seed A3"
SID1="sid1-$$-$(basename "$WORK")"
run_recon "$R1" "$SID1"
[ "$RC" -eq 0 ] || fail "(1) reconcile exit $RC (a fail-soft drain-loop step must exit 0; err: $(cat "$ERRFILE"))"
[ "$(val recirc_inbox)" = "3" ] || fail "(1) recirc_inbox must be 3 (got '$(val recirc_inbox)')"
[ "$(val reconcile)" = "reconciled" ] || fail "(1) verdict must be 'reconciled' (got '$(val reconcile)')"
for t in "$A1" "$A2" "$A3"; do
  has_ckpt "$R1" "$t" || fail "(1) open inbox ticket #$t was NOT checkpointed [neuter the stamp loop ⇒ RED]"
  has_taint "$R1" "$SID1" "$t" || fail "(1) open inbox ticket #$t has no recirc_checkpoint taint [neuter the stamp loop ⇒ RED]"
  comments "$R1" "$t" | grep -qi 'UNFINISHED'      || fail "(1) #$t checkpoint does not mark the ticket UNFINISHED"
  comments "$R1" "$t" | grep -q  '/idc:recirculate' || fail "(1) #$t checkpoint omits the /idc:recirculate resume remediation"
  # TRANSCRIPT-LESS body: the main-session path has NO subagent + NO agent transcript, so the comment
  # must not claim either (that would be false recovery evidence). Red-when-broken: drop origin=
  # "main-session" ⇒ the reused body says "subagent … agent transcript" ⇒ this assert goes RED.
  comments "$R1" "$t" | grep -qiE 'subagent|agent transcript' \
    && fail "(1) main-session checkpoint must be TRANSCRIPT-LESS — no 'subagent'/'agent transcript' claim [drop origin=main-session ⇒ RED]"
  comments "$R1" "$t" | grep -qi 'transcript-less' \
    || fail "(1) main-session checkpoint should identify its transcript-less origin"
done
printf '%s\n' "$OUT" | grep -qE "^checkpointed:.*\b$A2\b" || fail "(1) the checkpointed: line must list #$A2 (got: $(val checkpointed))"
echo "  ok (1) kill mid-drain: every still-open inbox ticket gets a resume checkpoint (comment + taint)"

# ══ Case 2 — IDEMPOTENT RE-RUN ⇒ no duplicate comments, taints unchanged (the taint-latch) ══════════
# The reconciliation runs at the TOP OF EVERY autorun pass, so it re-runs against the SAME open inbox
# repeatedly. The recirc_checkpoint taint is the idempotence latch: an open ticket that already carries
# it must be SKIPPED — no second comment, no changed taint. (Reuses R1's post-case-1 state: 3 open
# tickets, each already checkpointed once.)
# Red-when-broken: drop the `if t in existing: continue` latch ⇒ each ticket is re-commented ⇒ the
# comment count climbs to 2 ⇒ the "exactly one checkpoint comment" assert goes RED.
before_taints="$(led "$R1" pending --session "$SID1" | grep -c 'recirc_checkpoint:')"
run_recon "$R1" "$SID1"
[ "$RC" -eq 0 ] || fail "(2) re-run exit $RC (err: $(cat "$ERRFILE"))"
[ "$(val checkpointed)" = "" ] || fail "(2) an idempotent re-run must checkpoint NOTHING new (got: '$(val checkpointed)') [drop the latch ⇒ RED]"
[ "$(val cleared)" = "" ]      || fail "(2) an idempotent re-run must clear nothing (got: '$(val cleared)')"
for t in "$A1" "$A2" "$A3"; do
  c="$(ckpt_count "$R1" "$t")"
  [ "$c" -eq 1 ] || fail "(2) ticket #$t has $c checkpoint comments after a re-run — must be exactly 1 (no dup) [drop the latch ⇒ RED]"
done
after_taints="$(led "$R1" pending --session "$SID1" | grep -c 'recirc_checkpoint:')"
[ "$before_taints" -eq "$after_taints" ] && [ "$after_taints" -eq 3 ] \
  || fail "(2) taints changed on an idempotent re-run (before=$before_taints after=$after_taints, want 3/3)"
echo "  ok (2) idempotent re-run: no duplicate comments, taints unchanged (taint-latch holds)"

# ══ Case 3 — A TICKET LEAVES THE INBOX ⇒ its taint is CLEARED; still-open ones keep theirs ══════════
# When a ticket is absorbed/retired (Done) or parked (Blocked) it leaves the Stage=Recirculation ∧ Todo
# inbox — its checkpoint obligation is satisfied, so the reconciliation must CLEAR that ticket's taint
# (the "action completed" clear branch) while leaving every still-open ticket's taint in place.
# Red-when-broken: force `cleared = []` ⇒ the departed ticket's taint survives ⇒ the "taint cleared"
# assert goes RED.
R3="$(new_repo)" || fail "new_repo 3 failed"; REPOS+=("$R3")
B1="$(seed "$R3" Recirculation Todo 'recirc: will be retired to Done')" || fail "seed B1"
B2="$(seed "$R3" Recirculation Todo 'recirc: stays open')"              || fail "seed B2"
SID3="sid3-$$-$(basename "$WORK")"
run_recon "$R3" "$SID3"
has_taint "$R3" "$SID3" "$B1" || fail "(3) precondition: #$B1 must be checkpointed on the first pass"
has_taint "$R3" "$SID3" "$B2" || fail "(3) precondition: #$B2 must be checkpointed on the first pass"
move "$R3" "$B1" Done || fail "(3) could not retire #$B1 to Done"
run_recon "$R3" "$SID3"
[ "$RC" -eq 0 ] || fail "(3) reconcile exit $RC (err: $(cat "$ERRFILE"))"
has_taint "$R3" "$SID3" "$B1" \
  && fail "(3) a ticket #$B1 that LEFT the inbox (Done) still carries its recirc_checkpoint taint [force cleared=[] ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^cleared:.*\b$B1\b" \
  || fail "(3) the cleared: line must name the departed ticket #$B1 (got: '$(val cleared)') [force cleared=[] ⇒ RED]"
has_taint "$R3" "$SID3" "$B2" || fail "(3) a STILL-OPEN ticket #$B2 must KEEP its taint (over-cleared)"
printf '%s\n' "$OUT" | grep -qE "^checkpointed:.*\b$B1\b" \
  && fail "(3) a departed ticket #$B1 must NOT be re-checkpointed (it is off-Todo)"
echo "  ok (3) a ticket that left the inbox has its taint cleared; the still-open ticket keeps its own"

# ══ Case 4 — READ-FAILURE FAIL-SAFE ⇒ preserve the taint, report unknown, never a false 'empty' ════
# An unreadable inbox (a corrupt/locked/half-written TRACKER.md → the query helper dies rc=1) is
# UNKNOWN state, NOT a proven-empty inbox. The reconciliation must NOT clear the checkpoint taint
# (clearing on an unproven-empty inbox is the exact drop-F state loss) and must NOT report emptiness —
# it reports `reconcile: unknown` / `recirc_inbox: unknown` and warns. Pre-seed a taint, corrupt the
# tracker, then assert the taint SURVIVES.
# Red-when-broken: treat `still_open is None` as [] ⇒ still_open looks proven-empty ⇒ the taint is
# WIPED (cleared) ⇒ the "taint survives" assert goes RED.
R4="$(new_repo)" || fail "new_repo 4 failed"; REPOS+=("$R4")
SID4="sid4-$$-$(basename "$WORK")"
led "$R4" set --kind recirc_checkpoint --key 99 --session "$SID4" >/dev/null || fail "(4) pre-seed taint failed"
has_taint "$R4" "$SID4" 99 || fail "(4) pre-seeded taint did not take"
printf 'corrupt tracker — no idc-tracker-state JSON block, the query helper dies rc=1\n' > "$R4/TRACKER.md"
python3 "$TRK" --tracker "$R4/TRACKER.md" query --stage Recirculation --status Todo >/dev/null 2>&1 \
  && fail "(4) precondition: the corrupt TRACKER.md must make the query FAIL (rc!=0)"
run_recon "$R4" "$SID4"
[ "$RC" -eq 0 ] || fail "(4) reconcile exit $RC (a fail-soft step must still exit 0; err: $(cat "$ERRFILE"))"
[ "$(val reconcile)" = "unknown" ]    || fail "(4) verdict must be 'unknown' on an unreadable inbox (got '$(val reconcile)') [treat None as [] ⇒ RED]"
[ "$(val recirc_inbox)" = "unknown" ] || fail "(4) recirc_inbox must be 'unknown' on an unreadable inbox (got '$(val recirc_inbox)')"
[ "$(val cleared)" = "" ]             || fail "(4) an unreadable inbox must clear NOTHING (got: '$(val cleared)') [treat None as [] ⇒ RED]"
has_taint "$R4" "$SID4" 99 \
  || fail "(4) an UNREADABLE inbox WIPED the checkpoint taint — state loss [treat still_open None as [] ⇒ RED]"
grep -qi 'could not determine the recirculation inbox' "$ERRFILE" \
  || fail "(4) the degraded (unreadable-inbox) path must WARN (observability-first)"
echo "  ok (4) an unreadable/corrupt tracker read PRESERVES the taint (never wiped), reports unknown + warns [safe-bias]"

# ══ Case 6 — OBSERVE-ONLY is a PURE DRY RUN: no taint, no comment, and it does NOT trap the latch ═══
# IDC_HOOKS_OBSERVE_ONLY=1 must warn what it WOULD do and mutate NEITHER the board NOR the ledger — in
# particular it must NOT pre-write the taint, or a later ENFORCE pass would find the ticket already
# latched and NEVER write its resume comment (the breadcrumb the gate exists to leave).
# Red-when-broken: make observe set the taint (engage the latch) ⇒ the enforce pass below finds the
# ticket in `existing` ⇒ skips it ⇒ NO comment is ever written ⇒ the "enforce writes the comment" assert
# goes RED.
R6="$(new_repo)" || fail "new_repo 6 failed"; REPOS+=("$R6")
C1="$(seed "$R6" Recirculation Todo 'recirc: seen first under observe-only')" || fail "seed C1"
SID6="sid6-$$-$(basename "$WORK")"
OUT="$(IDC_HOOKS_OBSERVE_ONLY=1 python3 "$RECON" --repo "$R6" --session-id "$SID6" 2>"$ERRFILE")"; RC=$?
[ "$RC" -eq 0 ] || fail "(6) observe-only exit $RC (err: $(cat "$ERRFILE"))"
[ "$(val checkpointed)" = "" ] || fail "(6) observe-only must checkpoint NOTHING (dry run) (got '$(val checkpointed)')"
has_taint "$R6" "$SID6" "$C1" && fail "(6) observe-only must NOT write the taint (it would trap the latch) [observe sets taint ⇒ RED]"
has_ckpt "$R6" "$C1" && fail "(6) observe-only must NOT stamp a board comment"
grep -qi 'OBSERVE-ONLY: would checkpoint' "$ERRFILE" || fail "(6) observe-only must WARN what it would checkpoint"
# Now ENFORCE (no observe): the ticket was NOT latched under observe, so this pass MUST write the comment.
run_recon "$R6" "$SID6"
has_ckpt "$R6" "$C1" || fail "(6) an ENFORCE pass after observe MUST write the resume comment (observe must not trap the latch) [observe sets taint ⇒ RED]"
has_taint "$R6" "$SID6" "$C1" || fail "(6) the enforce pass must set the taint"
echo "  ok (6) observe-only is a pure dry run (no taint/comment, warns) and never traps a later enforce pass"

# ══ Case 7 — BACKEND AUTO-DETECT: a github-config repo resolves to github WITHOUT a --backend flag ═══
# Cases 1-6 pass NO --backend flag and work → they already exercise the filesystem auto-detect. This
# case pins the github side: a repo whose tracker-config says `backend: github` must resolve to github
# (not silently default to filesystem — which would read an absent TRACKER.md and go permanently
# `unknown`, drop-F protection off). We assert the resolution INPUT (G._read_backend reads the config)
# since the full github path needs gh (best-effort, not hermetic — same posture as the Stage C gate).
R7="$WORK/gh-config"; mkdir -p "$R7/docs/workflow"; printf 'backend: github\n' > "$R7/docs/workflow/tracker-config.yaml"
DETECTED="$(python3 -c "import sys; sys.path.insert(0,'$GOV_PLUGIN/scripts/hooks'); import idc_recirc_closeout_gate as G; print(G._read_backend('$R7'))")" \
  || fail "(7) could not resolve the backend from tracker-config.yaml"
[ "$DETECTED" = "github" ] || fail "(7) a 'backend: github' repo must auto-detect as github, not '$DETECTED' [hardcode filesystem ⇒ RED]"
echo "  ok (7) backend auto-detect: a github-config repo resolves to github with no --backend flag"

# ══ Case 5 — REPO-GATE: a non-IDC-governed repo is an instant no-op ════════════════════════════════
NONGOV="$WORK/nongov"; mkdir -p "$NONGOV"
run_recon "$NONGOV" "sid5-$$"
[ "$RC" -eq 0 ] || fail "(5) repo-gate exit $RC"
[ "$(val reconcile)" = "ungoverned" ] || fail "(5) a non-governed repo must report 'ungoverned' (got '$(val reconcile)')"
echo "  ok (5) repo-gate: a non-IDC-governed repo → instant no-op (ungoverned)"

echo "PASS: the main-session recirculation reconciliation — a killed/next-pass drain checkpoints EVERY still-open Stage=Recirculation ∧ Todo inbox ticket (resume comment via the sanctioned helper + recirc_checkpoint taint); the taint is an idempotence latch so re-runs never duplicate comments; a ticket that leaves the inbox has its taint cleared (still-open ones keep theirs); an UNREADABLE inbox PRESERVES taints + reports unknown (never a false empty / state loss); repo-gated; fail-SOFT (never crashes the drain loop)"
