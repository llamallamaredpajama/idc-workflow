#!/bin/bash
# verdict-gate.sh — governance scenario: the SubagentStop verdict gate is un-skippable.
#
# The invariant (Phase 1, plan §3.2/§3.3): a review agent cannot stop without having produced a
# VALIDATED verdict JSON for THIS review run. The gate script (scripts/hooks/idc_verdict_gate.py)
# reads a SubagentStop payload on stdin and decides:
#   * review agent + a fresh valid verdict in its transcript  -> ALLOW (exit 0, no block decision)
#   * review agent + NO verdict produced this run             -> BLOCK ({"decision":"block", reason})
#   * review agent + a verdict that FAILS the validator        -> BLOCK (reason carries the problems)
#   * review agent + only a STALE pre-existing verdict         -> BLOCK (freshness anchor defeats it)
#   * a non-review agent_type                                  -> ALLOW instantly (self-gate)
#   * a non-IDC-governed repo (no tracker-config.yaml)         -> ALLOW instantly (repo-gate)
#   * bounded: after N=3 blocks for the same agent             -> LOUD-FAIL allow (never an infinite nag)
#   * IDC_HOOKS_OBSERVE_ONLY=1                                 -> WARN, never block
#
# Red-when-broken: neuter the gate's verdict-check (make it always allow) and cases B/C/D_stale FAIL;
# remove the self-gate and case D FAILs; remove the repo-gate and case E FAILs.
#
# This is the hermetic decision-logic test. The LIVE "Claude Code actually blocks the stop and the
# reviewer retries, N=3 then loud fail" behavior is proven by the sandbox e2e negative test (task 5),
# on the strength of the Phase-1 spike (docs/dev/2026-07-03-phase1-hook-availability-spike.md).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE="$PLUGIN/scripts/hooks/idc_verdict_gate.py"
VC="$PLUGIN/scripts/idc_review_verdict_check.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GATE" ] || fail "verdict gate not found at $GATE (not implemented yet)"
[ -f "$VC" ]   || fail "verdict validator not found at $VC"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow/code-reviews"
: > "$REPO/docs/workflow/tracker-config.yaml"   # marks REPO as IDC-governed

REVIEW_AGENT="idc:idc-review-agent"
# The gate's bounded anti-nag counter is keyed by session_id+agent_id and persists in the OS temp
# dir (correct in production: each real session has a UNIQUE session_id). The eval must therefore
# use a per-RUN-unique session id, or a once-per-run block agent (B/C/Ds) would accumulate its
# counter across repeated eval runs and eventually hit the N=3 bound → loud-fail allow (a false
# "gate accepted it"). Case F still shares this one session id across its iterations (it must, to
# exercise the bound), but across runs the id differs, so nothing leaks.
SESS="sess-$$-$(basename "$WORK")"

# A structurally-valid PASS-WITH-NITS verdict (one nit) — validates via idc_review_verdict_check.py.
good_verdict() {
  cat <<'JSON'
{"verdict":"PASS-WITH-NITS","findings":[{"dimension":"style","severity":"nit","confidence":0.9,
"evidence":"e","attack":"a","unblock":"u","fingerprint":"style:f.py:1:x"}],"deferrals":[]}
JSON
}
# A malformed verdict the validator rejects (missing attack/unblock/fingerprint).
bad_verdict() { echo '{"verdict":"PASS","findings":[{"dimension":"x","severity":"nit","confidence":0.9,"evidence":"e"}]}'; }

# build_transcript <out.jsonl> <start_iso> <tool_use_json_lines...>
# Writes a minimal JSONL: first line carries the start timestamp; extra lines are assistant tool_use.
mk_transcript() {
  python3 - "$@" <<'PY'
import json,sys
out, start = sys.argv[1], sys.argv[2]
tools = sys.argv[3:]  # each is "Bash:<command>" or "Write:<file_path>"
lines=[{"type":"user","timestamp":start,"message":{"role":"user","content":[{"type":"text","text":"review"}]}}]
for t in tools:
    kind, val = t.split(":",1)
    inp = {"command":val} if kind=="Bash" else {"file_path":val}
    lines.append({"type":"assistant","timestamp":start,
        "message":{"role":"assistant","content":[{"type":"tool_use","name":kind,"input":inp}]}})
with open(out,"w") as fh:
    for l in lines: fh.write(json.dumps(l)+"\n")
PY
}

# run_gate <cwd> <agent_type> <agent_id> <transcript> [extra_json]  -> prints stdout; sets $GATE_RC
run_gate() {
  local cwd="$1" atype="$2" aid="$3" tr="$4"
  local payload
  payload="$(python3 - "$cwd" "$atype" "$aid" "$tr" "$SESS" <<'PY'
import json,sys
cwd,atype,aid,tr,sess=sys.argv[1:6]
print(json.dumps({"hook_event_name":"SubagentStop","cwd":cwd,"agent_type":atype,
 "agent_id":aid,"session_id":sess,"agent_transcript_path":tr,"stop_hook_active":False}))
PY
)"
  GATE_OUT="$(printf '%s' "$payload" | python3 "$GATE" "$PLUGIN" 2>/dev/null)"; GATE_RC=$?
}
blocks()   { printf '%s' "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null; }

# ── (A) review agent wrote + validated a FRESH good verdict → ALLOW ──────────────────────────────
good_verdict > "$REPO/docs/workflow/code-reviews/2026-07-03-pr-9-review.json"
mk_transcript "$WORK/tr_A.jsonl" "2020-01-01T00:00:00.000Z" \
  "Write:docs/workflow/code-reviews/2026-07-03-pr-9-review.json" \
  "Bash:python3 \$ROOT/scripts/idc_review_verdict_check.py docs/workflow/code-reviews/2026-07-03-pr-9-review.json"
run_gate "$REPO" "$REVIEW_AGENT" "agentA" "$WORK/tr_A.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(A) gate exit $GATE_RC, expected 0"
blocks "$GATE_OUT" && fail "(A) gate BLOCKED a review that produced a valid fresh verdict"
echo "  ok (A) valid fresh verdict → allow"

# ── (B) review agent produced NO verdict → BLOCK with the canonical path + validator in the reason ─
mk_transcript "$WORK/tr_B.jsonl" "2020-01-01T00:00:00.000Z" "Bash:echo just chatting, no verdict"
run_gate "$REPO" "$REVIEW_AGENT" "agentB" "$WORK/tr_B.jsonl"
blocks "$GATE_OUT" || fail "(B) gate did NOT block a review that produced no verdict"
printf '%s' "$GATE_OUT" | grep -q "code-reviews"            || fail "(B) block reason omits the canonical code-reviews path"
printf '%s' "$GATE_OUT" | grep -q "idc_review_verdict_check" || fail "(B) block reason omits the validator command"
echo "  ok (B) no verdict → block with the exact missing-artifact remediation"

# ── (C) review agent referenced a verdict that FAILS validation → BLOCK ───────────────────────────
bad_verdict > "$REPO/docs/workflow/code-reviews/2026-07-03-pr-10-review.json"
mk_transcript "$WORK/tr_C.jsonl" "2020-01-01T00:00:00.000Z" \
  "Write:docs/workflow/code-reviews/2026-07-03-pr-10-review.json"
run_gate "$REPO" "$REVIEW_AGENT" "agentC" "$WORK/tr_C.jsonl"
blocks "$GATE_OUT" || fail "(C) gate did NOT block a review whose verdict fails validation"
echo "  ok (C) invalid verdict → block"

# ── (D_stale) a valid verdict the agent merely re-VALIDATED but did not produce this run → BLOCK ──
# The verdict is structurally valid and IS referenced in the transcript, but its file mtime PREDATES
# the agent's start — i.e. a pre-existing verdict the agent ran the checker over without writing a
# fresh one. The freshness anchor must reject it (else "validate an old file" would satisfy the gate).
good_verdict > "$REPO/docs/workflow/code-reviews/2026-07-03-pr-8-review.json"
touch -t 200001010000 "$REPO/docs/workflow/code-reviews/2026-07-03-pr-8-review.json"
mk_transcript "$WORK/tr_Dstale.jsonl" "2030-01-01T00:00:00.000Z" \
  "Bash:python3 \$ROOT/scripts/idc_review_verdict_check.py docs/workflow/code-reviews/2026-07-03-pr-8-review.json"
run_gate "$REPO" "$REVIEW_AGENT" "agentDs" "$WORK/tr_Dstale.jsonl"
blocks "$GATE_OUT" || fail "(D_stale) gate accepted a STALE prior verdict (mtime < agent start) as this run's artifact"
echo "  ok (D_stale) stale referenced verdict → block (freshness anchor holds)"

# ── (D) a NON-review agent_type → ALLOW instantly (self-gate) ─────────────────────────────────────
mk_transcript "$WORK/tr_D.jsonl" "2020-01-01T00:00:00.000Z" "Bash:echo whatever"
run_gate "$REPO" "general-purpose" "agentD" "$WORK/tr_D.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(D) non-review gate exit $GATE_RC"
blocks "$GATE_OUT" && fail "(D) gate blocked a NON-review subagent (self-gate broken)"
echo "  ok (D) non-review agent → allow"

# ── (E) a NON-governed repo → ALLOW instantly (repo-gate) ─────────────────────────────────────────
NONGOV="$WORK/nongov"; mkdir -p "$NONGOV"
mk_transcript "$WORK/tr_E.jsonl" "2020-01-01T00:00:00.000Z" "Bash:echo x"
run_gate "$NONGOV" "$REVIEW_AGENT" "agentE" "$WORK/tr_E.jsonl"
[ "$GATE_RC" -eq 0 ] || fail "(E) non-governed gate exit $GATE_RC"
blocks "$GATE_OUT" && fail "(E) gate blocked in a non-IDC-governed repo (repo-gate broken)"
echo "  ok (E) non-governed repo → allow"

# ── (F) bounded: after N=3 blocks for the same agent → LOUD-FAIL allow, never an infinite nag ─────
# Drive four consecutive gate calls for the same (session,agent) with a no-verdict transcript.
mk_transcript "$WORK/tr_F.jsonl" "2020-01-01T00:00:00.000Z" "Bash:echo no verdict"
blocked=0; allowed_after=""
for i in 1 2 3 4 5; do
  run_gate "$REPO" "$REVIEW_AGENT" "agentF" "$WORK/tr_F.jsonl"
  if blocks "$GATE_OUT"; then blocked=$((blocked+1)); else allowed_after="$i"; break; fi
done
[ "$blocked" -le 3 ] || fail "(F) gate blocked $blocked times — the N=3 bound is not enforced (nag risk)"
[ -n "$allowed_after" ] || fail "(F) gate never stopped blocking within 5 tries (infinite-nag risk)"
echo "  ok (F) bounded at N=3 then loud-fail allow (blocked ${blocked} times, then allowed on try ${allowed_after})"

# ── (G) IDC_HOOKS_OBSERVE_ONLY=1 → never a block, even with a missing verdict ─────────────────────
# Reuse the one payload builder in run_gate; a command-prefix env assignment scopes OBSERVE_ONLY to
# just this gate invocation (run_gate calls the gate python in a pipeline, and the assignment on the
# function call exports into that subshell).
mk_transcript "$WORK/tr_G.jsonl" "2020-01-01T00:00:00.000Z" "Bash:echo no verdict"
IDC_HOOKS_OBSERVE_ONLY=1 run_gate "$REPO" "$REVIEW_AGENT" "agentG" "$WORK/tr_G.jsonl"
blocks "$GATE_OUT" && fail "(G) OBSERVE_ONLY still emitted a block decision"
echo "  ok (G) observe-only → warn, never block"

echo "PASS: SubagentStop verdict gate — a review agent cannot stop without a fresh validated verdict; self-gated to review agents in governed repos; bounded N=3 loud-fail; observe-only downgrades to warn"
