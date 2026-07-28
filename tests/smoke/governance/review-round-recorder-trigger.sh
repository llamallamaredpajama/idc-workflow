#!/bin/bash
# idc-assert-class: behavior
# review-round-recorder-trigger.sh — pre-floor candidates are persisted by FIXED CODE, not by prose.
#
# Claim (b) of the convergence contract: a candidate rejected, refuted, or floored in round 1 must be
# *seen*, or it resurfaces in round 3 as new work and recycles the review attempt counter. The only
# thing that used to fire `record-round` was a prose instruction in agents/idc-review-coordinator.md
# step 3 — a round that skipped the command left no ledger entry and nothing detected it.
#
# The SubagentStop verdict gate now fires the recorder itself, on the same trigger that already fires
# the filer: a review that stops with a valid verdict and a round record on disk leaves ledger
# entries for its pre-floor candidates even though its transcript never ran the CLI.
#
# Red-when-broken (observed): delete the _run_round_recorder call in the gate's ok-branch =>
#   the below-floor fingerprint is absent from the per-PR seen ledger => FAIL.
#
# Usage: bash tests/smoke/governance/review-round-recorder-trigger.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE="$PLUGIN/scripts/hooks/idc_verdict_gate.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GATE" ] || fail "verdict gate not found at $GATE"
[ -f "$TRK" ] || fail "tracker backend not found at $TRK"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow/code-reviews"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"   # marks REPO as governed
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || fail "tracker init failed"
PARENT="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'build: feature W' --stage Buildable --status 'In Progress')" \
  || fail "parent create failed"

# Two DISTINCT fingerprints so the assertion cannot be satisfied by the verdict's own finding: the
# nit survives into the verdict (the filer records it), the candidate was dropped below the floor
# (only the round record carries it). Neither string appears in any path this scenario creates.
NIT_FP='logging:emit-batch.py:31:swallowed-error'
FLOORED_FP='style:cache-warmer.py:88:naming-drift'

cat > "$REPO/docs/workflow/code-reviews/pr-13-review.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":13,
 "findings":[{"dimension":"logging","severity":"nit","confidence":0.9,
   "evidence":"batch emit drops the error","attack":"a","unblock":"u",
   "fingerprint":"$NIT_FP"}],"deferrals":[]}
JSON
cat > "$REPO/docs/workflow/code-reviews/pr-13-round-1.json" <<JSON
{"schema_version":1,"pr":13,
 "candidates":[{"dimension":"style","confidence":0.4,
   "fingerprint":"$FLOORED_FP","disposition":"below-floor"}]}
JSON

# The review agent's transcript: it WROTE both artifacts and validated the verdict, but never ran
# record-round. That is precisely the round the prose-only contract loses.
python3 - "$WORK/transcript.jsonl" <<'PY' || fail "could not build the transcript"
import json, sys
start = "2020-01-01T00:00:00.000Z"
tools = [("Write", {"file_path": "docs/workflow/code-reviews/pr-13-review.json"}),
         ("Write", {"file_path": "docs/workflow/code-reviews/pr-13-round-1.json"}),
         ("Bash", {"command": "python3 scripts/idc_review_verdict_check.py docs/workflow/code-reviews/pr-13-review.json"})]
lines = [{"type": "user", "timestamp": start,
          "message": {"role": "user", "content": [{"type": "text", "text": "review"}]}}]
for name, inp in tools:
    lines.append({"type": "assistant", "timestamp": start,
                  "message": {"role": "assistant",
                              "content": [{"type": "tool_use", "name": name, "input": inp}]}})
with open(sys.argv[1], "w") as fh:
    for line in lines:
        fh.write(json.dumps(line) + "\n")
PY

PAYLOAD="$(python3 - "$REPO" "$WORK/transcript.jsonl" "$$" <<'PY'
import json, sys
repo, transcript, pid = sys.argv[1:4]
print(json.dumps({"hook_event_name": "SubagentStop", "cwd": repo,
                  "agent_type": "idc:idc-review-coordinator", "agent_id": "roundrec",
                  "session_id": f"sess-{pid}", "agent_transcript_path": transcript,
                  "stop_hook_active": False}))
PY
)"
set +e
GATE_OUT="$(printf '%s' "$PAYLOAD" | timeout 300 python3 "$GATE" "$PLUGIN" 2>"$WORK/stderr.log")"; GATE_RC=$?
set -e
[ "$GATE_RC" -ne 124 ] || fail "the verdict gate did not terminate within 300s"
[ "$GATE_RC" -eq 0 ] || fail "the gate exited $GATE_RC on a valid verdict — [$GATE_OUT] [$(cat "$WORK/stderr.log")]"
printf '%s' "$GATE_OUT" | grep -q '"decision"' \
  && fail "the gate emitted a decision on a valid verdict: [$GATE_OUT]"

LEDGER="$REPO/docs/workflow/code-reviews/pr-13-seen-fingerprints.json"
[ -f "$LEDGER" ] || fail "no per-PR seen ledger was written at $LEDGER"
python3 - "$LEDGER" "$FLOORED_FP" "$NIT_FP" <<'PY' || fail "the completed review round left no ledger entry for its below-floor candidate — pre-floor persistence is still prose-only"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
by_fp = {e.get("fingerprint"): e for e in entries}
floored = by_fp.get(sys.argv[2])
assert floored is not None, entries
assert floored.get("last_disposition") == "below-floor", floored
# the verdict's own nit must still be recorded by the filer, and must not be confused with it
assert sys.argv[3] in by_fp, entries
assert by_fp[sys.argv[3]].get("last_disposition") == "filed", by_fp[sys.argv[3]]
PY

echo "PASS: a completed review round persists its pre-floor candidates through fixed code, even when the coordinator never runs record-round itself"
