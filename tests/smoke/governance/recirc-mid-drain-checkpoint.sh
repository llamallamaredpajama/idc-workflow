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
#     checkpointed" asserts (case A T1, and case B) go RED.
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

echo "PASS: the SubagentStop recirculator closeout-or-checkpoint detective — a mid-drain stop checkpoints every UNCOVERED open inbox ticket (branch/PR/dispositions, via the sanctioned comment helper) + sets a recirc_checkpoint taint; a validly-closed-out ticket is left alone (per-ticket); a fully-valid run clears its taints and stamps nothing; self-gated to the recirculator + repo-gated; fail-OPEN (never blocks); observe-only records without mutating the board"
