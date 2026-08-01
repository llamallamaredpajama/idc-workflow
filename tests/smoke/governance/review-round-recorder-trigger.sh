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
# Three further fixed-code guarantees ride on the same trigger and are pinned here:
#   * SHARED_FP — a fingerprint the verdict carries as a live nit AND the round record calls
#     `rejected`. That self-contradiction used to be resolved by whichever door ran LAST: with the
#     recorder first, the filer suppressed the finding and the board never got it. Suppression now
#     requires BOARD corroboration, so the finding reaches the board whatever the order — this is
#     the assertion that stops the gate's filer→recorder ordering from being load-bearing.
#   * STALE_FP — a round record whose mtime predates the review run must NOT be re-recorded.
#   * a round record the recorder REFUSES must never block the stop (the recorder can legitimately
#     refuse now, and a refusal turned into a block would deadlock every review silently).
#
# The staleness assertion is "STALE_FP is ABSENT from the ledger", and absence proves nothing on its
# own — deleting the transcript's Read of pr-13-round-0.json satisfies it just as well as the mtime
# rule does. So it carries a POSITIVE CONTROL: the same file, re-stamped to now and re-run through
# the same gate, MUST then be recorded. Only the pair distinguishes "the staleness rule fired" from
# "the fixture never reached the staleness rule".
#
# Red-when-broken (observed): delete the _run_round_recorder call in the gate's ok-branch =>
#   the below-floor fingerprint is absent from the per-PR seen ledger => FAIL.
#   Drop board corroboration from suppressible_fingerprints => SHARED_FP is suppressed and never
#   reaches the board => FAIL. Delete the getmtime staleness block in _fresh_round_records =>
#   STALE_FP appears in the ledger => FAIL. Make the staleness test compare against 0 instead of the
#   run start (never stale) => same FAIL; make it reject EVERY round record => the positive control
#   below reds instead. Make a recorder failure block the stop => rc != 0 => FAIL.
#
# Usage: bash tests/smoke/governance/review-round-recorder-trigger.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE="$PLUGIN/scripts/hooks/idc_verdict_gate.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
SEEN="$PLUGIN/scripts/idc_review_seen_ledger.py"
fail() { echo "FAIL: $1"; exit 1; }
# shellcheck source=../lib/fail-closed.sh
. "$(dirname "$0")/../lib/fail-closed.sh"   # fc_require_file (hard input guards, never `if [ -f … ]`)

fc_require_file "$GATE" "verdict gate"
fc_require_file "$TRK" "tracker backend"
fc_require_file "$SEEN" "seen ledger helper"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow/code-reviews"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"   # marks REPO as governed
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || fail "tracker init failed"
PARENT="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'build: feature W' --stage Buildable --status 'In Progress')" \
  || fail "parent create failed"

# DISTINCT fingerprints so no assertion can be satisfied by another's artifact: the nit survives
# into the verdict (the filer records it), the floored candidate was dropped below the floor (only
# the round record carries it), the shared one is in BOTH (the self-contradiction), and the stale one
# is in a round record that predates the run. No string appears in any path this scenario creates.
NIT_FP='logging:emit-batch.py:31:swallowed-error'
FLOORED_FP='style:cache-warmer.py:88:naming-drift'
SHARED_FP='concurrency:shard-router.py:57:double-ack'
STALE_FP='naming:legacy-adapter.py:12:shadowed-symbol'
REFUSED_FP='perf:index-builder.py:64:quadratic-merge'

cat > "$REPO/docs/workflow/code-reviews/pr-13-review.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":13,
 "findings":[{"dimension":"logging","severity":"nit","confidence":0.9,
   "evidence":"batch emit drops the error","attack":"a","unblock":"u",
   "fingerprint":"$NIT_FP"},
  {"dimension":"concurrency","severity":"minor","confidence":0.9,
   "evidence":"shard router can double-ack a redelivery","attack":"a","unblock":"u",
   "fingerprint":"$SHARED_FP"}],"deferrals":[]}
JSON
cat > "$REPO/docs/workflow/code-reviews/pr-13-round-1.json" <<JSON
{"schema_version":1,"pr":13,
 "candidates":[{"dimension":"style","confidence":0.4,
   "fingerprint":"$FLOORED_FP","disposition":"below-floor"},
  {"dimension":"concurrency","confidence":0.4,
   "fingerprint":"$SHARED_FP","disposition":"rejected"}]}
JSON
# A round record left by a PREVIOUS run: same shape, same naming convention, referenced by this
# run's transcript — but its mtime predates the review's start, so it must not be re-recorded.
cat > "$REPO/docs/workflow/code-reviews/pr-13-round-0.json" <<JSON
{"schema_version":1,"pr":13,
 "candidates":[{"dimension":"naming","confidence":0.3,
   "fingerprint":"$STALE_FP","disposition":"refuted"}]}
JSON
touch -t 201901010000 "$REPO/docs/workflow/code-reviews/pr-13-round-0.json" \
  || fail "could not age the stale round record"

# The review agent's transcript: it WROTE both artifacts and validated the verdict, but never ran
# record-round. That is precisely the round the prose-only contract loses.
python3 - "$WORK/transcript.jsonl" <<'PY' || fail "could not build the transcript"
import json, sys
start = "2020-01-01T00:00:00.000Z"
tools = [("Write", {"file_path": "docs/workflow/code-reviews/pr-13-review.json"}),
         ("Write", {"file_path": "docs/workflow/code-reviews/pr-13-round-1.json"}),
         ("Read", {"file_path": "docs/workflow/code-reviews/pr-13-round-0.json"}),
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

# The round record is recorded BEFORE the filer ever runs — the exact ordering that used to strand a
# finding. (The coordinator prose once told it to run this command itself, and nothing stopped it
# running early; a round file named or placed so the gate's own recorder never sees it has the same
# effect.) The fixture must reach the filer with SHARED_FP already sitting at `rejected`, or the
# corroboration rule is never exercised and the board assertion below proves nothing.
python3 "$SEEN" record-round --repo "$REPO" \
  --round "$REPO/docs/workflow/code-reviews/pr-13-round-1.json" >/dev/null \
  || fail "record-round rejected the pre-filer round record"

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

# A clean round record must NOT emit the two diagnostic markers this scenario later asserts — the
# positive controls that keep those greps from matching something every run prints.
! grep -q 'round recorder refused' "$WORK/stderr.log" \
  || fail "the gate reported a recorder refusal on a round record the recorder ACCEPTED — the 'round recorder refused' marker does not discriminate: [$(cat "$WORK/stderr.log")]"
! grep -q 'NO fresh pre-floor round record' "$WORK/stderr.log" \
  || fail "the gate reported 'no round record' for a review that left one — that marker does not discriminate: [$(cat "$WORK/stderr.log")]"

LEDGER="$REPO/docs/workflow/code-reviews/pr-13-seen-fingerprints.json"
[ -f "$LEDGER" ] || fail "no per-PR seen ledger was written at $LEDGER"
# One assertion per heredoc: a single message covering five asserts named the wrong one when a
# different assert fired, and only the python AssertionError on stderr told the truth.
python3 - "$LEDGER" "$FLOORED_FP" <<'PY' || fail "the completed review round left no ledger entry for its below-floor candidate — pre-floor persistence is still prose-only"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
by_fp = {e.get("fingerprint"): e for e in entries}
floored = by_fp.get(sys.argv[2])
assert floored is not None, entries
assert floored.get("last_disposition") == "below-floor", floored
assert floored.get("last_source") == "round", floored
PY
python3 - "$LEDGER" "$NIT_FP" <<'PY' || fail "the verdict's own nit was not recorded by the FILER (or was confused with the round record's below-floor candidate)"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
by_fp = {e.get("fingerprint"): e for e in entries}
assert sys.argv[2] in by_fp, entries
assert by_fp[sys.argv[2]].get("last_disposition") == "filed", by_fp[sys.argv[2]]
assert by_fp[sys.argv[2]].get("last_source") == "filer", by_fp[sys.argv[2]]
PY
python3 - "$LEDGER" "$STALE_FP" <<'PY' || fail "a round record older than this review run (a PREVIOUS run's artifact) was re-recorded into the seen ledger"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
assert sys.argv[2] not in {e.get("fingerprint") for e in entries}, f"stale round record was re-recorded: {entries}"
PY

# The self-contradicting fingerprint (live nit in the verdict, `rejected` in the round record) must
# be ON THE BOARD. Read the real dedupe keys the filer wrote, so nothing here can match scaffolding.
python3 - "$PLUGIN" "$REPO" "$SHARED_FP" "$NIT_FP" <<'PY' || fail "a fingerprint the verdict carries as a live finding was stranded by the round record that also names it"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_file_findings as FF
keys = FF._fs_existing_keys(os.path.join(sys.argv[2], "TRACKER.md"))
assert f"finding:{sys.argv[3]}" in keys, sorted(keys)
assert f"finding:{sys.argv[4]}" in keys, sorted(keys)
PY

# ── POSITIVE CONTROL for the staleness assertion above ───────────────────────────────────────────
# "STALE_FP is absent" is satisfied just as well by a fixture that never reached the staleness rule
# (delete the transcript's Read of pr-13-round-0.json and it passes vacuously). Re-stamp that exact
# file to now — nothing else changes, same transcript, same gate — and it MUST now be recorded. The
# pair is what proves the mtime comparison is the thing deciding.
touch "$REPO/docs/workflow/code-reviews/pr-13-round-0.json" \
  || fail "could not re-stamp the previously-stale round record"
PAYLOAD_FRESH="$(python3 - "$REPO" "$WORK/transcript.jsonl" "$$" <<'PY'
import json, sys
repo, transcript, pid = sys.argv[1:4]
print(json.dumps({"hook_event_name": "SubagentStop", "cwd": repo,
                  "agent_type": "idc:idc-review-coordinator", "agent_id": "roundrec-restamped",
                  "session_id": f"sess-{pid}", "agent_transcript_path": transcript,
                  "stop_hook_active": False}))
PY
)"
set +e
OUT_FRESH="$(printf '%s' "$PAYLOAD_FRESH" | timeout 300 python3 "$GATE" "$PLUGIN" 2>"$WORK/stderr-fresh.log")"; RC_FRESH=$?
set -e
[ "$RC_FRESH" -ne 124 ] || fail "the verdict gate did not terminate within 300s on the re-stamped round record"
[ "$RC_FRESH" -eq 0 ] \
  || fail "the gate exited $RC_FRESH on the re-stamped round record — [$OUT_FRESH] [$(cat "$WORK/stderr-fresh.log")]"
python3 - "$LEDGER" "$STALE_FP" <<'PY' || fail "a round record re-stamped to NOW was still skipped as stale — the earlier 'absent' assertion was passing vacuously, not because the mtime rule fired"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
by_fp = {e.get("fingerprint"): e for e in entries}
assert sys.argv[2] in by_fp, f"re-stamped round record was not recorded: {entries}"
assert by_fp[sys.argv[2]].get("last_disposition") == "refuted", by_fp[sys.argv[2]]
assert by_fp[sys.argv[2]].get("last_source") == "round", by_fp[sys.argv[2]]
PY

# ── a round record the recorder REFUSES must not block the stop ──────────────────────────────────
cat > "$REPO/docs/workflow/code-reviews/pr-13-round-2.json" <<JSON
{"schema_version":1,"pr":13,
 "candidates":[{"dimension":"perf","confidence":0.4,
   "fingerprint":"$REFUSED_FP","disposition":"suppressed-seen"}]}
JSON
python3 - "$WORK/transcript-refused.jsonl" <<'PY' || fail "could not build the refusal transcript"
import json, sys
start = "2020-01-01T00:00:00.000Z"
tools = [("Write", {"file_path": "docs/workflow/code-reviews/pr-13-review.json"}),
         ("Write", {"file_path": "docs/workflow/code-reviews/pr-13-round-2.json"}),
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
PAYLOAD2="$(python3 - "$REPO" "$WORK/transcript-refused.jsonl" "$$" <<'PY'
import json, sys
repo, transcript, pid = sys.argv[1:4]
print(json.dumps({"hook_event_name": "SubagentStop", "cwd": repo,
                  "agent_type": "idc:idc-review-coordinator", "agent_id": "roundrec-refused",
                  "session_id": f"sess-{pid}", "agent_transcript_path": transcript,
                  "stop_hook_active": False}))
PY
)"
set +e
OUT2="$(printf '%s' "$PAYLOAD2" | timeout 300 python3 "$GATE" "$PLUGIN" 2>"$WORK/stderr2.log")"; RC2=$?
set -e
[ "$RC2" -ne 124 ] || fail "the verdict gate did not terminate within 300s on the refused round record"
[ "$RC2" -eq 0 ] \
  || fail "a refused round record blocked the stop (rc=$RC2) — a legitimate recorder refusal must never deadlock the review: [$OUT2] [$(cat "$WORK/stderr2.log")]"
printf '%s' "$OUT2" | grep -q '"decision"' \
  && fail "the gate emitted a decision after a recorder refusal: [$OUT2]"
grep -q 'round recorder refused' "$WORK/stderr2.log" \
  || fail "the recorder refusal was swallowed instead of surfaced on stderr: [$(cat "$WORK/stderr2.log")]"
python3 - "$LEDGER" "$REFUSED_FP" <<'PY' || fail "the refused round record still mutated the seen ledger"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
assert sys.argv[2] not in {e.get("fingerprint") for e in entries}, entries
PY

# ── a review that leaves NO round record at all is visible, not silent ───────────────────────────
# GAP 4 is NARROWED, not closed: fixed code cannot synthesize a round record the reviewer never
# wrote, and a review that floored nothing legitimately writes none. It can say so.
python3 - "$WORK/transcript-noround.jsonl" <<'PY' || fail "could not build the no-round transcript"
import json, sys
start = "2020-01-01T00:00:00.000Z"
tools = [("Write", {"file_path": "docs/workflow/code-reviews/pr-13-review.json"}),
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
PAYLOAD3="$(python3 - "$REPO" "$WORK/transcript-noround.jsonl" "$$" <<'PY'
import json, sys
repo, transcript, pid = sys.argv[1:4]
print(json.dumps({"hook_event_name": "SubagentStop", "cwd": repo,
                  "agent_type": "idc:idc-review-coordinator", "agent_id": "roundrec-noround",
                  "session_id": f"sess-{pid}", "agent_transcript_path": transcript,
                  "stop_hook_active": False}))
PY
)"
set +e
OUT3="$(printf '%s' "$PAYLOAD3" | timeout 300 python3 "$GATE" "$PLUGIN" 2>"$WORK/stderr3.log")"; RC3=$?
set -e
[ "$RC3" -eq 0 ] || fail "the gate blocked a valid verdict that simply had no round record (rc=$RC3)"
grep -q 'NO fresh pre-floor round record' "$WORK/stderr3.log" \
  || fail "a review that stopped with a valid verdict and no round record said nothing — the remaining GAP-4 case is invisible: [$(cat "$WORK/stderr3.log")]"

echo "PASS: a completed review round persists its pre-floor candidates through fixed code (skipping stale round records, recording the same file once it is re-stamped), a fingerprint both the verdict and the round record name still reaches the board, a refused round record never blocks the stop, and a review with no round record at all says so"
