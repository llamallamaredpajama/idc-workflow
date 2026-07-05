#!/bin/bash
# idc-assert-class: behavior
# recirc-mid-drain-checkpoint.sh — governance scenario: the SubagentStop recirculator
# closeout-or-checkpoint detective (v4 Phase 3 Stage C, drop F).
#
# The invariant (plan §3.4): when the IDC recirculator subagent STOPS mid-drain WITHOUT a valid
# closeout for an open inbox ticket, its state (branch, PR#, dispositions so far) must never be lost to
# truncation. The gate (scripts/hooks/idc_recirc_closeout_gate.py) reads a SubagentStop payload on
# stdin and, for **every still-open `Stage=Recirculation ∧ Status=Todo` inbox ticket that the
# transcript does NOT hold a valid `idc_recirc_closeout.py` closeout for**, stamps a resume-checkpoint
# comment (via the SANCTIONED filesystem comment helper — never a raw board mutation) and sets a
# `recirc_checkpoint:<ticket>` obligation-ledger taint. A ticket the recirculator DID validly close out
# is left alone (authoritative); a fully-closed-out run stops clean and clears its checkpoint taints.
# It is a POST-HOC detective: it never blocks the stop (fail-OPEN).
#
# The discriminator is PER-TICKET, not run-level: a run that closed out ticket #1 then died before #2
# must still checkpoint #2 (the exact drop-F failure). This scenario pins that with a MIXED transcript.
#
# Red-when-broken (MANDATORY, reviewed):
#   * neuter the checkpoint STAMPING (make the comment a no-op) ⇒ the "every uncovered open ticket has
#     a checkpoint comment" assert (case A, T2) goes RED;
#   * neuter the closeout-valid SHORT-CIRCUIT (force `covered` empty / drop the `t not in covered`
#     filter) ⇒ a validly-closed-out open ticket is WRONGLY checkpointed ⇒ the "covered ticket NOT
#     checkpointed" asserts (case A T1, and case B) go RED;
#   * [P2-1] neuter the EXPLICIT-dispatch SCOPE filter (revert its `uncovered` to whole-inbox) ⇒ an
#     untouched out-of-scope open ticket is WRONGLY checkpointed ⇒ case H's "Th2 NOT checkpointed" RED;
#   * [P2-2] neuter the FILE-based closeout harvest (drop the `--closeout <path>` read in
#     _scan_transcript) ⇒ a ticket closed out via a closeout FILE is not recognized covered and is
#     WRONGLY checkpointed ⇒ case I's "Ti NOT checkpointed" assert goes RED;
#   * [P1] neuter the GENERIC-dispatch whole-inbox DEFAULT (make an undeterminable/generic dispatch
#     checkpoint nothing) ⇒ a board-scan drainer that dies before any closeout silently loses every
#     open ticket's state ⇒ case J's "whole inbox checkpointed" asserts go RED;
#   * [fable audit] neuter GENERIC-LANGUAGE DOMINANCE (drop the `not generic_dispatch` term of the
#     explicit trigger) ⇒ an inbox-drain dispatch that name-drops an open ticket # narrows to just it
#     ⇒ case K1's "whole inbox checkpointed" asserts go RED;
#   * [fable audit] neuter the CORROBORATION term (drop `& recirc_real`) ⇒ a dispatch whose only #s
#     are noise (a PR#/project#) is treated explicit with a nothing-scope ⇒ case K2 RED;
#   * [fable audit] neuter FIRST-TURN anchoring (parse dispatch #s from EVERY user turn) ⇒ an injected
#     mid-run reminder's `#N` narrows a generic drainer's scope ⇒ case L's skipped-ticket assert RED.
#
# The scope rule is ASYMMETRIC (drop-F-safe): a corroborated EXPLICIT first-turn `#N` dispatch narrows
# (case H); a GENERIC (inbox-language, K1) or undeterminable (noise-#s K2 / no-#s J) dispatch defaults
# to the WHOLE still-open inbox; later user turns never narrow (L). Under-checkpointing is state loss;
# over-checkpointing is a recoverable breadcrumb.
#
# Filesystem-backed (hermetic, no gh). Auto-discovered by the governance lane (phase-governance.sh);
# runnable standalone under BOTH python3 and `uv run --with pyyaml`.
#
# Usage: bash tests/smoke/governance/recirc-mid-drain-checkpoint.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

GATE="$GOV_PLUGIN/scripts/hooks/idc_recirc_closeout_gate.py"
LEDGER="$GOV_PLUGIN/scripts/hooks/idc_ledger.py"
CLOSEOUT="$GOV_PLUGIN/scripts/idc_recirc_closeout.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$GATE" ]     || fail "recirc closeout gate not found at $GATE (not implemented yet)"
[ -f "$CLOSEOUT" ] || fail "closeout validator not found at $CLOSEOUT"

RECIRC_AGENT="idc:idc-recirculator"   # namespaced dispatch form; the gate normalizes off the idc: prefix
BRANCH="recirc/heal-scope"
PR_URL="https://github.com/o/r/pull/512"

# ── a governed filesystem repo with an initialized tracker → echoes the REPO dir ──────────────────
new_repo() {
  local d; d="$(mktemp -d)" || return 1
  mkdir -p "$d/docs/workflow"
  printf 'backend: filesystem\n' > "$d/docs/workflow/tracker-config.yaml"   # marks REPO IDC-governed
  python3 "$TRK" --tracker "$d/TRACKER.md" init >/dev/null || return 1
  printf '%s' "$d"
}
seed() {  # seed <repo> <stage> <status> <title> -> echoes the issue number
  python3 "$TRK" --tracker "$1/TRACKER.md" create --title "$4" --stage "$2" --status "$3"
}
comments() { python3 "$TRK" --tracker "$1/TRACKER.md" show --num "$2" --comments; }
led() { python3 "$LEDGER" --cwd "$1" "${@:2}"; }

# a VALID pass-through closeout JSON for a ticket (validates via idc_recirc_closeout.py)
valid_co() { printf '{"ticket":%s,"outcome":"pass-through","provenance":"originated from #%s discovered mid-build","recirc_count":1,"cascade_depth":0,"consideration":"docs/considerations/2026-07-05-x-considerations.md"}' "$1" "$1"; }
# an INVALID closeout (missing the mandatory provenance) — the validator rejects it, so it must NOT
# mark its ticket covered (a truncated/half closeout can never satisfy the gate).
invalid_co() { printf '{"ticket":%s,"outcome":"pass-through","recirc_count":0,"cascade_depth":0,"consideration":"docs/x.md"}' "$1"; }

# mk_transcript <out> <branch|-> <pr_url|-> [closeout-json ...] — a minimal recirculator transcript:
# a git branch tool_use, a PR text mention, and each closeout embedded as a Write's input.content.
mk_transcript() {
  python3 - "$@" <<'PY'
import json,sys
out,branch,pr=sys.argv[1:4]; closeouts=sys.argv[4:]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z",
    "message":{"role":"user","content":[{"type":"text","text":"drain the recirculation inbox"}]}}]
if branch!="-":
    L.append({"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
        "content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b "+branch}}]}})
if pr!="-":
    L.append({"type":"assistant","timestamp":"2020-01-01T00:00:02.000Z","message":{"role":"assistant",
        "content":[{"type":"text","text":"opened PR "+pr}]}})
for i,co in enumerate(closeouts):
    L.append({"type":"assistant","timestamp":"2020-01-01T00:00:03.000Z","message":{"role":"assistant",
        "content":[{"type":"tool_use","name":"Write","input":{"file_path":"closeout-%d.json"%i,"content":co}}]}})
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
}

# run_gate <cwd> <agent_type> <session> <transcript> -> prints stdout; sets $GATE_RC (+ $ERRLOG)
ERRLOG=""
run_gate() {
  local cwd="$1" atype="$2" sess="$3" tr="$4"
  local payload
  payload="$(python3 - "$cwd" "$atype" "$sess" "$tr" <<'PY'
import json,sys
cwd,atype,sess,tr=sys.argv[1:5]
print(json.dumps({"hook_event_name":"SubagentStop","cwd":cwd,"agent_type":atype,
 "agent_id":"recirc-1","session_id":sess,"agent_transcript_path":tr,"stop_hook_active":False}))
PY
)"
  : > "$ERRLOG"
  GATE_OUT="$(printf '%s' "$payload" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERRLOG")"; GATE_RC=$?
}
has_ckpt()  { comments "$1" "$2" | grep -q 'idc-recirc-checkpoint'; }

WORK="$(mktemp -d)"; ERRLOG="$WORK/err.log"; trap 'rm -rf "$WORK" "${REPOS[@]:-}"' EXIT
REPOS=()

# ══ Case A — MIXED incomplete drain: one open ticket validly closed out, one not ═══════════════════
# Board: D1 (Recirc, Done) + D2 (Recirc, Blocked) already dispositioned; T1 + T2 still Todo. Transcript
# carries a VALID closeout for T1 and only an INVALID (rejected) closeout for T2 → T1 covered, T2 not.
A="$(new_repo)" || fail "new_repo A failed"; REPOS+=("$A")
D1="$(seed "$A" Recirculation Done    'recirc: admitted+retired')"    || fail "seed D1"
D2="$(seed "$A" Recirculation Blocked 'recirc: parked behind gate')"  || fail "seed D2"
T1="$(seed "$A" Recirculation Todo    'recirc: closed out but board unmoved')" || fail "seed T1"
T2="$(seed "$A" Recirculation Todo    'recirc: never reached (truncated)')"    || fail "seed T2"
mk_transcript "$WORK/tr_A.jsonl" "$BRANCH" "$PR_URL" "$(valid_co "$T1")" "$(invalid_co "$T2")"
SIDA="sidA-$$-$(basename "$WORK")"
run_gate "$A" "$RECIRC_AGENT" "$SIDA" "$WORK/tr_A.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(A) gate exit $GATE_RC (a post-hoc detective must always allow the stop)"
printf '%s' "$GATE_OUT" | grep -q '"decision"' && fail "(A) the detective must NEVER emit a block decision (fail-open): $GATE_OUT"

# T2 (uncovered) IS checkpointed, naming the reconstructed branch + PR + unfinished state.
has_ckpt "$A" "$T2" || fail "(A) the uncovered open ticket #$T2 was not checkpointed [neuter the stamp ⇒ RED]"
comments "$A" "$T2" | grep -q "branch=$BRANCH"   || fail "(A) checkpoint omits the reconstructed branch (got: $(comments "$A" "$T2"))"
comments "$A" "$T2" | grep -q "pr=#512"          || fail "(A) checkpoint omits the reconstructed PR# (got: $(comments "$A" "$T2"))"
comments "$A" "$T2" | grep -qi 'UNFINISHED'      || fail "(A) checkpoint does not mark the ticket UNFINISHED"
comments "$A" "$T2" | grep -q '/idc:recirculate' || fail "(A) checkpoint omits the /idc:recirculate resume remediation"
# dispositions-so-far names the already-handled tickets (board-derived enrichment).
comments "$A" "$T2" | grep -q "#${D1}->done"    || fail "(A) checkpoint dispositions-so-far omits the retired ticket #${D1}"
comments "$A" "$T2" | grep -q "#${D2}->blocked" || fail "(A) checkpoint dispositions-so-far omits the parked ticket #${D2}"
led "$A" pending --session "$SIDA" | grep -qx "recirc_checkpoint:$T2" || fail "(A) no recirc_checkpoint taint for the uncovered ticket #$T2"

# T1 (covered by a VALID closeout) is NOT checkpointed — the per-ticket short-circuit. [neuter it ⇒ RED]
has_ckpt "$A" "$T1" && fail "(A) a validly-closed-out open ticket #$T1 was WRONGLY checkpointed [neuter the closeout-valid short-circuit ⇒ RED]"
led "$A" pending --session "$SIDA" | grep -qx "recirc_checkpoint:$T1" && fail "(A) a covered ticket #$T1 must carry NO recirc_checkpoint taint"
# the already-dispositioned (off-Todo) tickets are never checkpointed.
has_ckpt "$A" "$D1" && fail "(A) a retired (Done) ticket #$D1 must not be checkpointed"
has_ckpt "$A" "$D2" && fail "(A) a parked (Blocked) ticket #$D2 must not be checkpointed"
echo "  ok (A) mixed drain: the uncovered open ticket is checkpointed (branch/PR/dispositions); a validly-closed-out open ticket and the off-Todo tickets are left alone"

# ══ Case B — a FULLY valid closeout ⇒ NO checkpoints stamped + prior checkpoint taints cleared ════
# One still-open ticket T3, and the transcript holds a VALID closeout for it → uncovered is empty → the
# gate allows, stamps nothing, and clears this session's pre-existing recirc_checkpoint taint.
B="$(new_repo)" || fail "new_repo B failed"; REPOS+=("$B")
T3="$(seed "$B" Recirculation Todo 'recirc: fully closed out')" || fail "seed T3"
SIDB="sidB-$$-$(basename "$WORK")"
led "$B" set --kind recirc_checkpoint --key "$T3" --session "$SIDB" >/dev/null || fail "(B) could not pre-seed the recirc_checkpoint taint"
led "$B" pending --session "$SIDB" | grep -qx "recirc_checkpoint:$T3" || fail "(B) pre-seeded taint did not take"
mk_transcript "$WORK/tr_B.jsonl" "$BRANCH" "$PR_URL" "$(valid_co "$T3")"
run_gate "$B" "$RECIRC_AGENT" "$SIDB" "$WORK/tr_B.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(B) gate exit $GATE_RC"
has_ckpt "$B" "$T3" && fail "(B) a fully-closed-out run WRONGLY stamped a checkpoint on #$T3 [neuter the closeout-valid short-circuit ⇒ RED]"
led "$B" pending --session "$SIDB" | grep -qx "recirc_checkpoint:$T3" && fail "(B) the recirc_checkpoint taint was not cleared on a valid closeout"
echo "  ok (B) a fully valid closeout ⇒ no checkpoints stamped + the session's recirc_checkpoint taints cleared"

# ══ Case C — self-gate: a NON-recirculator subagent is ignored instantly ═══════════════════════════
C="$(new_repo)" || fail "new_repo C failed"; REPOS+=("$C")
X="$(seed "$C" Recirculation Todo 'recirc: open, but a review agent stops')" || fail "seed X"
mk_transcript "$WORK/tr_C.jsonl" "$BRANCH" "$PR_URL"
run_gate "$C" "idc:idc-review-agent" "sidC-$$" "$WORK/tr_C.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(C) self-gate exit $GATE_RC"
has_ckpt "$C" "$X" && fail "(C) the gate checkpointed on a NON-recirculator stop (self-gate broken)"
echo "  ok (C) self-gate: a non-recirculator subagent stop is ignored (no checkpoint)"

# ══ Case D — repo-gate: a non-IDC-governed repo is an instant no-op ════════════════════════════════
NONGOV="$WORK/nongov"; mkdir -p "$NONGOV"
mk_transcript "$WORK/tr_D.jsonl" "$BRANCH" "$PR_URL"
run_gate "$NONGOV" "$RECIRC_AGENT" "sidD-$$" "$WORK/tr_D.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(D) repo-gate exit $GATE_RC"
printf '%s' "$GATE_OUT" | grep -q '"decision"' && fail "(D) the gate acted in a non-governed repo (repo-gate broken)"
echo "  ok (D) repo-gate: a non-IDC-governed repo → instant no-op"

# ══ Case E — observe-only: RECORD the taint (observe-only must SEE what would be lost), no board write ═
# IDC_HOOKS_OBSERVE_ONLY=1 is the observe-first rollout: the gate must NOT mutate the board (no
# comment) but MUST still record the obligation (the taint) so an operator sees exactly what state
# would have been lost — mirrors the Stage-A ledger's "keep recording under observe-only".
E="$(new_repo)" || fail "new_repo E failed"; REPOS+=("$E")
T5="$(seed "$E" Recirculation Todo 'recirc: observe-only, never reached')" || fail "seed T5"
SIDE="sidE-$$-$(basename "$WORK")"
mk_transcript "$WORK/tr_E.jsonl" "$BRANCH" "$PR_URL" "$(invalid_co "$T5")"
: > "$ERRLOG"
GATE_OUT="$(printf '%s' "$(python3 - "$E" "$RECIRC_AGENT" "$SIDE" "$WORK/tr_E.jsonl" <<'PY'
import json,sys
cwd,atype,sess,tr=sys.argv[1:5]
print(json.dumps({"hook_event_name":"SubagentStop","cwd":cwd,"agent_type":atype,
 "agent_id":"recirc-1","session_id":sess,"agent_transcript_path":tr,"stop_hook_active":False}))
PY
)" | IDC_HOOKS_OBSERVE_ONLY=1 python3 "$GATE" "$GOV_PLUGIN" 2>"$ERRLOG")"; GATE_RC=$?
[ "$GATE_RC" -eq 0 ] || fail "(E) observe-only exit $GATE_RC"
has_ckpt "$E" "$T5" && fail "(E) observe-only must NOT stamp a board comment (it downgrades the board write)"
led "$E" pending --session "$SIDE" | grep -qx "recirc_checkpoint:$T5" \
  || fail "(E) observe-only must STILL record the recirc_checkpoint taint (observe-only must SEE what would be lost)"
grep -qi 'OBSERVE-ONLY' "$ERRLOG" || fail "(E) observe-only must warn on stderr about the withheld checkpoint"
echo "  ok (E) observe-only: taint recorded (state-loss made visible), board comment withheld"

# ══ Case F — a FAILING/corrupt tracker read must PRESERVE checkpoints, never WIPE them (MAJOR-1) ════
# An unreadable inbox (a corrupt/locked/half-written TRACKER.md → the query helper dies rc=1) is UNKNOWN
# state, NOT a proven-empty inbox. The gate must NOT clear the checkpoint ledger (clearing on an
# unproven-empty inbox is the exact drop-F state loss). Corrupt the tracker AFTER a pre-existing
# checkpoint taint is on the ledger, then assert the taint SURVIVES + the gate warns.
# Red-when-broken: revert _fs_query to `[]`-on-failure ⇒ still_open==[] looks proven-empty ⇒ the taint
# is WIPED ⇒ the "taint survives" assert goes RED.
F="$(new_repo)" || fail "new_repo F failed"; REPOS+=("$F")
SIDF="sidF-$$-$(basename "$WORK")"
led "$F" set --kind recirc_checkpoint --key 99 --session "$SIDF" >/dev/null || fail "(F) pre-seed taint failed"
led "$F" pending --session "$SIDF" | grep -qx "recirc_checkpoint:99" || fail "(F) pre-seeded taint did not take"
printf 'corrupt tracker — no idc-tracker-state JSON block, the query helper dies rc=1\n' > "$F/TRACKER.md"
python3 "$TRK" --tracker "$F/TRACKER.md" query --stage Recirculation --status Todo >/dev/null 2>&1 \
  && fail "(F) precondition: the corrupt TRACKER.md must make the query FAIL (rc!=0)"
mk_transcript "$WORK/tr_F.jsonl" "$BRANCH" "$PR_URL"
run_gate "$F" "$RECIRC_AGENT" "$SIDF" "$WORK/tr_F.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(F) gate exit $GATE_RC (fail-open detective must still allow)"
led "$F" pending --session "$SIDF" | grep -qx "recirc_checkpoint:99" \
  || fail "(F) an UNREADABLE inbox WIPED the checkpoint taint — state loss [revert _fs_query to []-on-failure ⇒ RED]"
grep -qi 'could not determine the recirculation inbox' "$ERRLOG" \
  || fail "(F) the degraded (unreadable-inbox) path must WARN (observability-first)"
echo "  ok (F) an unreadable/corrupt tracker read PRESERVES checkpoints (never wiped) + warns [MAJOR-1]"

# ══ Case G — an EXAMPLE closeout (read/quoted, not a real action) must NOT mark a ticket covered ════
# A valid-closeout-shaped JSON that merely appears in a tool_result (a doc the recirculator READ) is
# NOT a disposition. It must NOT suppress the checkpoint — the ticket is still open and un-closed-out.
# The subagent WAS dispatched over T6 (that is why it read T6's example), so T6 is in its scope; the
# example just never marks it covered.
# Red-when-broken: revert _scan_transcript to harvest closeouts from ANY string (not just authored
# Write/Bash actions) ⇒ the example is treated as covered ⇒ the ticket is NOT checkpointed ⇒ RED.
G="$(new_repo)" || fail "new_repo G failed"; REPOS+=("$G")
T6="$(seed "$G" Recirculation Todo 'recirc: open; an EXAMPLE closeout for it was only READ')" || fail "seed T6"
SIDG="sidG-$$-$(basename "$WORK")"
# a transcript whose ONLY closeout for T6 is inside a tool_result (a Read) + a text quote — never a
# Write/Edit artifact and never an idc_recirc_closeout.py Bash run. The dispatch prompt names T6 (the
# ticket this sous-chef was handed) so T6 is IN scope.
python3 - "$WORK/tr_G.jsonl" "$(valid_co "$T6")" "$T6" <<'PY'
import json,sys
out,example,t6=sys.argv[1],sys.argv[2],sys.argv[3]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"Process the Stage=Recirculation ticket #%s (a recirc event surfaced mid-build); drain it via the Recirculator playbook."%t6}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
    "content":[{"type":"tool_use","name":"Read","input":{"file_path":"docs/considerations/EXAMPLES.md"}}]}},
   {"type":"user","timestamp":"2020-01-01T00:00:02.000Z","message":{"role":"user",
    "content":[{"type":"tool_result","tool_use_id":"t1","content":"here is an example closeout: "+example}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:03.000Z","message":{"role":"assistant",
    "content":[{"type":"text","text":"for reference the schema looks like "+example}]}}]
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
run_gate "$G" "$RECIRC_AGENT" "$SIDG" "$WORK/tr_G.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(G) gate exit $GATE_RC"
has_ckpt "$G" "$T6" \
  || fail "(G) an EXAMPLE closeout (only READ/quoted) wrongly marked ticket #$T6 covered — it must still be checkpointed [revert to broad harvest ⇒ RED]"
led "$G" pending --session "$SIDG" | grep -qx "recirc_checkpoint:$T6" || fail "(G) missing checkpoint taint for #$T6"
echo "  ok (G) an example closeout that was only read/quoted does NOT mark a ticket covered — it is still checkpointed [MAJOR-2]"

# ══ Case H — SCOPE: an untouched open inbox ticket the subagent NEVER handled is NOT checkpointed ════
# The SubagentStop hook fires only for the Build larger-loop recirc-consultant — a sous-chef spawned
# over the ONE ticket its triplet surfaced. It must checkpoint only THAT ticket's state, never stamp
# its branch/PR breadcrumb onto a stranger's open ticket. Board: Th1 + Th2 both Recirc∧Todo, but the
# transcript shows the subagent was dispatched over Th1 ONLY (dispatch prompt names #Th1; a branch +
# PR but it died before emitting any closeout) — Th2 is another consultant's / untouched ticket.
# Th1 (in scope, uncovered) IS checkpointed; Th2 (out of scope) is left ENTIRELY alone.
# Red-when-broken: revert `uncovered = [t for t in still_open if t in scope and t not in covered]` to
# the whole-inbox `[t for t in still_open if t not in covered]` ⇒ Th2 is WRONGLY checkpointed ⇒ the
# "untouched Th2 NOT checkpointed" assert goes RED.
Hh="$(new_repo)" || fail "new_repo H failed"; REPOS+=("$Hh")
TH1="$(seed "$Hh" Recirculation Todo 'recirc: the ONE ticket this sous-chef was dispatched over')" || fail "seed TH1"
TH2="$(seed "$Hh" Recirculation Todo 'recirc: a DIFFERENT open ticket this subagent never touched')" || fail "seed TH2"
SIDH="sidH-$$-$(basename "$WORK")"
# dispatch names ONLY TH1; a branch + PR (state to preserve); NO closeout (died mid-drain) — so TH1's
# scope comes purely from the dispatch prompt (exercises the dispatch-scope reconstruction path).
python3 - "$WORK/tr_H.jsonl" "$TH1" "$BRANCH" "$PR_URL" <<'PY'
import json,sys
out,th1,branch,pr=sys.argv[1:5]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"Drain Stage=Recirculation ticket #%s: heal the scope drift and emit a closeout."%th1}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
    "content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b "+branch}}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:02.000Z","message":{"role":"assistant",
    "content":[{"type":"text","text":"opened PR "+pr}]}}]
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
run_gate "$Hh" "$RECIRC_AGENT" "$SIDH" "$WORK/tr_H.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(H) gate exit $GATE_RC"
has_ckpt "$Hh" "$TH1" || fail "(H) the dispatched ticket #$TH1 was not checkpointed (dispatch-scope reconstruction broken)"
comments "$Hh" "$TH1" | grep -q "branch=$BRANCH" || fail "(H) #$TH1 checkpoint omits the reconstructed branch"
led "$Hh" pending --session "$SIDH" | grep -qx "recirc_checkpoint:$TH1" || fail "(H) no taint for the dispatched ticket #$TH1"
has_ckpt "$Hh" "$TH2" \
  && fail "(H) an UNTOUCHED open ticket #$TH2 (out of this subagent's scope) was WRONGLY checkpointed [revert to whole-inbox scope ⇒ RED]"
led "$Hh" pending --session "$SIDH" | grep -qx "recirc_checkpoint:$TH2" \
  && fail "(H) an untouched out-of-scope ticket #$TH2 must carry NO recirc_checkpoint taint"
echo "  ok (H) scope: only the dispatched ticket is checkpointed; an untouched open inbox ticket is left entirely alone [P2-1]"

# ══ Case I — a FILE-based closeout (idc_recirc_closeout.py --closeout <path>) is harvested as covered ═
# The documented closeout flow writes the closeout to a FILE, then validates it with `--closeout
# <path>` (not an inline here-string). The gate must read that file so a legitimately-closed-out ticket
# is recognized covered and NOT wrongly checkpointed. Ti is dispatched (in scope); its ONLY closeout is
# a real on-disk file the agent ran the validator on.
# Red-when-broken: revert the `--closeout <path>` file-harvest ⇒ Ti has no covered closeout ⇒ Ti is
# WRONGLY checkpointed ⇒ the "file-closed-out ticket NOT checkpointed" assert goes RED.
Ii="$(new_repo)" || fail "new_repo I failed"; REPOS+=("$Ii")
TI="$(seed "$Ii" Recirculation Todo 'recirc: closed out via a --closeout FILE, not an inline heredoc')" || fail "seed TI"
SIDI="sidI-$$-$(basename "$WORK")"
# the real closeout artifact on disk, at a repo-relative path the Bash command references (resolved
# against the subagent cwd = the repo root by the gate).
printf '%s' "$(valid_co "$TI")" > "$Ii/closeout-ti.json" || fail "(I) could not write the closeout file"
# dispatch names TI (scope); a Bash tool_use that RUNS the validator on the FILE — no Write artifact,
# no inline JSON in the command, so the ONLY way to recognize it covered is the file-harvest path.
python3 - "$WORK/tr_I.jsonl" "$TI" "$CLOSEOUT" <<'PY'
import json,sys
out,ti,closeout=sys.argv[1:4]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"Drain Stage=Recirculation ticket #%s and validate the closeout."%ti}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
    "content":[{"type":"tool_use","name":"Bash","input":{"command":"python3 %s --closeout closeout-ti.json"%closeout}}]}}]
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
run_gate "$Ii" "$RECIRC_AGENT" "$SIDI" "$WORK/tr_I.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(I) gate exit $GATE_RC"
has_ckpt "$Ii" "$TI" \
  && fail "(I) a ticket #$TI closed out via a --closeout FILE was WRONGLY checkpointed — the file-based closeout was not harvested [revert the --closeout <path> file-harvest ⇒ RED]"
led "$Ii" pending --session "$SIDI" | grep -qx "recirc_checkpoint:$TI" \
  && fail "(I) a file-closed-out ticket #$TI must carry NO recirc_checkpoint taint"
echo "  ok (I) a documented file-based closeout (--closeout <path>) is harvested as covered — the ticket is left alone [P2-2]"

# ══ Case J — a GENERIC board-scan dispatch that dies BEFORE any closeout ⇒ the WHOLE inbox is ════════
# checkpointed (drop-F-SAFE default), NEVER silently skipped [codex P1].
# A board-scan recirculator drains the WHOLE Stage=Recirculation∧Todo inbox; its dispatch enumerates NO
# ticket #s ("drain the recirculation inbox"). If it dies mid-drain BEFORE emitting a single closeout,
# scope is undeterminable — and the safe bias is ASYMMETRIC: UNDER-checkpointing a ticket it owned IS
# the drop-F state loss, while over-checkpointing is only a recoverable breadcrumb (board is ground
# truth, re-drain idempotent). So an undeterminable/generic dispatch must default to the WHOLE inbox and
# checkpoint every un-reached open ticket — NOT nothing.
# Red-when-broken: revert the generic-branch whole-inbox default to "undeterminable ⇒ nothing" (make
# the else-branch `uncovered` empty / scope-only) ⇒ NONE of the open tickets are checkpointed ⇒ RED.
J="$(new_repo)" || fail "new_repo J failed"; REPOS+=("$J")
TJ1="$(seed "$J" Recirculation Todo 'recirc: board-scan drain, ticket 1 (never reached)')" || fail "seed TJ1"
TJ2="$(seed "$J" Recirculation Todo 'recirc: board-scan drain, ticket 2 (never reached)')" || fail "seed TJ2"
TJ3="$(seed "$J" Recirculation Todo 'recirc: board-scan drain, ticket 3 (never reached)')" || fail "seed TJ3"
SIDJ="sidJ-$$-$(basename "$WORK")"
# GENERIC dispatch (mk_transcript's default first user turn "drain the recirculation inbox" — NO
# enumerated #s) + a branch + PR, and NO closeout (died mid-drain before disposing anything).
mk_transcript "$WORK/tr_J.jsonl" "$BRANCH" "$PR_URL"
run_gate "$J" "$RECIRC_AGENT" "$SIDJ" "$WORK/tr_J.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(J) gate exit $GATE_RC"
for t in "$TJ1" "$TJ2" "$TJ3"; do
  has_ckpt "$J" "$t" \
    || fail "(J) a GENERIC-dispatch board-scan drainer died mid-drain but open ticket #$t was NOT checkpointed — drop-F state loss [revert the whole-inbox default to nothing ⇒ RED]"
  led "$J" pending --session "$SIDJ" | grep -qx "recirc_checkpoint:$t" || fail "(J) no checkpoint taint for open ticket #$t"
done
echo "  ok (J) a generic inbox-drain dispatch that dies before any closeout checkpoints the WHOLE still-open inbox (drop-F-safe default) [codex P1]"

# ══ Case K1 — GENERIC LANGUAGE DOMINATES a name-dropped open-ticket # ═══════════════════════════════
# A board-scan drainer dispatch that says it owns the INBOX but also name-drops one open ticket
# ("drain the recirculation inbox; start with ticket #N") owns EVERY open ticket — the `#N` must not
# narrow scope to just #N. Dies before any closeout ⇒ the WHOLE inbox is checkpointed.
# Red-when-broken: drop the `not generic_dispatch` term of the explicit trigger ⇒ the dispatch
# corroborates against the open #TK1 and narrows to {TK1} ⇒ TK2/TK3 NOT checkpointed ⇒ RED.
K1="$(new_repo)" || fail "new_repo K1 failed"; REPOS+=("$K1")
TK1="$(seed "$K1" Recirculation Todo 'recirc: name-dropped in the inbox-drain dispatch')" || fail "seed TK1"
TK2="$(seed "$K1" Recirculation Todo 'recirc: inbox ticket 2 (never reached)')" || fail "seed TK2"
TK3="$(seed "$K1" Recirculation Todo 'recirc: inbox ticket 3 (never reached)')" || fail "seed TK3"
SIDK1="sidK1-$$-$(basename "$WORK")"
python3 - "$WORK/tr_K1.jsonl" "$TK1" "$BRANCH" <<'PY'
import json,sys
out,tk1,branch=sys.argv[1:4]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"Drain the recirculation inbox top-of-pipe; start with ticket #%s (the oldest)."%tk1}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
    "content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b "+branch}}]}}]
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
run_gate "$K1" "$RECIRC_AGENT" "$SIDK1" "$WORK/tr_K1.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(K1) gate exit $GATE_RC"
for t in "$TK1" "$TK2" "$TK3"; do
  has_ckpt "$K1" "$t" \
    || fail "(K1) an INBOX-drain dispatch name-dropping #$TK1 narrowed scope — open ticket #$t NOT checkpointed (generic language must dominate) [drop 'not generic_dispatch' ⇒ RED]"
  led "$K1" pending --session "$SIDK1" | grep -qx "recirc_checkpoint:$t" || fail "(K1) no checkpoint taint for open ticket #$t"
done
echo "  ok (K1) inbox-wide drainer language DOMINATES a name-dropped ticket # — the whole inbox is checkpointed [fable audit]"

# ══ Case K2 — a NOISE-#-only dispatch (no inbox language, #s corroborate nothing) defaults WIDE ═════
# Dispatch text is LLM-composed English: a drainer dispatch may name-drop a PR#/project#/run# that is
# NOT an inbox ticket ("context: build PR #512"). Such noise #s must NOT make the dispatch 'explicit'
# — an explicit trigger needs at least one # that is recirc-REAL (open ∪ closeout-candidate ∪ handled).
# Otherwise scope narrows to {512}, uncovered = ∅, and the WHOLE inbox is silently skipped — the exact
# eac5104 defect this case pins. (No inbox-wide phrase here, so generic-dominance can't mask the
# corroboration guard.)
# Red-when-broken: drop the `& recirc_real` corroboration term ⇒ NOTHING is checkpointed ⇒ RED.
K2="$(new_repo)" || fail "new_repo K2 failed"; REPOS+=("$K2")
TK4="$(seed "$K2" Recirculation Todo 'recirc: open ticket A (dispatch names only a stray PR#)')" || fail "seed TK4"
TK5="$(seed "$K2" Recirculation Todo 'recirc: open ticket B (dispatch names only a stray PR#)')" || fail "seed TK5"
SIDK2="sidK2-$$-$(basename "$WORK")"
python3 - "$WORK/tr_K2.jsonl" "$BRANCH" <<'PY'
import json,sys
out,branch=sys.argv[1:3]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"Recirculate the stranded scope per autorun pass 2; context: this run was spawned from build PR #512."}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
    "content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b "+branch}}]}}]
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
run_gate "$K2" "$RECIRC_AGENT" "$SIDK2" "$WORK/tr_K2.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(K2) gate exit $GATE_RC"
for t in "$TK4" "$TK5"; do
  has_ckpt "$K2" "$t" \
    || fail "(K2) a dispatch whose only # is a stray PR# (#512, not recirc-real) narrowed scope to nothing — open ticket #$t NOT checkpointed [drop '& recirc_real' ⇒ RED]"
  led "$K2" pending --session "$SIDK2" | grep -qx "recirc_checkpoint:$t" || fail "(K2) no checkpoint taint for open ticket #$t"
done
echo "  ok (K2) noise #s that corroborate against nothing recirc-real do NOT make a dispatch explicit — whole-inbox default holds [fable audit]"

# ══ Case L — a mid-run INJECTED user-role text block never narrows scope (first-turn anchoring) ═════
# A subagent's later user-role events are tool_results or INJECTED text (system-reminders, task lists
# — which carry `#N.`-shaped noise). Only the FIRST user event is the dispatch. First turn here is
# undeterminable (no #s, no inbox phrase) ⇒ WIDE; the injected reminder names #TL1 (recirc-REAL, so
# corroboration alone would NOT catch this — only first-turn anchoring does) and must not narrow.
# Red-when-broken: parse dispatch #s from EVERY user turn ⇒ scope narrows to {TL1} ⇒ TL2 skipped ⇒ RED.
Ll="$(new_repo)" || fail "new_repo L failed"; REPOS+=("$Ll")
TL1="$(seed "$Ll" Recirculation Todo 'recirc: named by an injected mid-run reminder')" || fail "seed TL1"
TL2="$(seed "$Ll" Recirculation Todo 'recirc: never mentioned anywhere (must still checkpoint)')" || fail "seed TL2"
SIDL="sidL-$$-$(basename "$WORK")"
python3 - "$WORK/tr_L.jsonl" "$TL1" "$BRANCH" <<'PY'
import json,sys
out,tl1,branch=sys.argv[1:4]
L=[{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"Resume the recirc drain from the prior checkpoint."}]}},
   {"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"assistant",
    "content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b "+branch}}]}},
   {"type":"user","timestamp":"2020-01-01T00:00:02.000Z","message":{"role":"user",
    "content":[{"type":"text","text":"<system-reminder>Existing tasks: #%s. [in_progress] recirc heal</system-reminder>"%tl1}]}}]
open(out,"w").write("".join(json.dumps(x)+"\n" for x in L))
PY
run_gate "$Ll" "$RECIRC_AGENT" "$SIDL" "$WORK/tr_L.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(L) gate exit $GATE_RC"
has_ckpt "$Ll" "$TL1" || fail "(L) open ticket #$TL1 not checkpointed (wide default broken)"
has_ckpt "$Ll" "$TL2" \
  || fail "(L) an INJECTED mid-run reminder naming #$TL1 narrowed scope — untouched open ticket #$TL2 NOT checkpointed [parse all user turns ⇒ RED]"
led "$Ll" pending --session "$SIDL" | grep -qx "recirc_checkpoint:$TL2" || fail "(L) no checkpoint taint for open ticket #$TL2"
echo "  ok (L) dispatch scope is FIRST-TURN anchored — an injected mid-run reminder's #N never narrows a drainer's scope [fable audit]"

echo "PASS: the SubagentStop recirculator closeout-or-checkpoint detective — a mid-drain stop checkpoints every UNCOVERED open inbox ticket in scope (branch/PR/dispositions, via the sanctioned comment helper) + sets a recirc_checkpoint taint; scope is ASYMMETRIC — a corroborated EXPLICIT first-turn #N dispatch NARROWS to that ticket (an untouched stranger is never checkpointed), while a GENERIC (inbox-language, even with a name-dropped #) or undeterminable (noise-#s or no-#s) dispatch DEFAULTS to the WHOLE still-open inbox and a mid-run injected user turn never narrows — so a board-scan drainer that dies loses nothing (drop-F-safe); a validly-closed-out ticket (incl. a file-based --closeout <path> closeout) is left alone; a fully-valid run clears its scope's taints and stamps nothing; an UNREADABLE inbox PRESERVES checkpoints (never wiped); an EXAMPLE closeout that was only read/quoted does NOT mark a ticket covered; self-gated to the recirculator + repo-gated; fail-OPEN (never blocks); observe-only records without mutating the board"
