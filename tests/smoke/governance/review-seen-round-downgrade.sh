#!/bin/bash
# idc-assert-class: behavior
# review-seen-round-downgrade.sh — a model-authored round record cannot strand an owed finding.
#
# `record-round` is the ONE model-authored write door into the per-PR seen ledger. Restricting WHICH
# dispositions it may claim is not enough: the damage is done by WHICH ENTRY it overwrites. An entry
# left at "filed" by a FAILED filing is a pending retry — the filer still owes it a board item.
# Flipping that entry to a terminal disposition (rejected/refuted/below-floor) makes the prescribed
# retry suppress it as resurfaced, and idc_git_finish.routing_gap then exempts "suppressed-seen": the
# finding is stranded forever while the finish gate reports converged and the merge proceeds.
#
# The refusal is corroborated, not blanket: when the recirculation ticket IS on the board the flip is
# harmless (the routed work survives), and the legitimate "round-1 nit filed, round-2 coordinator
# rejects the re-raise" flow needs it to stay legal. This scenario pins both halves.
#
# Red-when-broken (observed): delete the _refuse_pending_retry_downgrade call in record_observations
#   => record-round exits 0, the retry reports "filed 0 ... suppressed 1", the board stays at 0
#      Recirculation items, and routing_gap returns [] (the merge gate would pass) => FAIL.
#
# Usage: bash tests/smoke/governance/review-seen-round-downgrade.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FILER="$PLUGIN/scripts/idc_file_findings.py"
SEEN="$PLUGIN/scripts/idc_review_seen_ledger.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
FINISH="$PLUGIN/scripts/idc_git_finish.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$FILER" ] || fail "filer not found at $FILER"
[ -f "$SEEN" ] || fail "seen ledger helper not found at $SEEN"
[ -f "$TRK" ] || fail "tracker backend not found at $TRK"
[ -f "$FINISH" ] || fail "finisher not found at $FINISH"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || fail "tracker init failed"
PARENT="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'build: feature Z' --stage Buildable --status 'In Progress')" \
  || fail "parent create failed"
LEDGER="$REPO/docs/workflow/code-reviews/pr-12-seen-fingerprints.json"
FP='concurrency:queue-drain.py:214:lost-wakeup'

cat > "$WORK/nit-verdict.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":12,
 "findings":[{"dimension":"concurrency","severity":"minor","confidence":0.95,
   "evidence":"drain loop can miss a wakeup","attack":"a","unblock":"u",
   "fingerprint":"$FP"}]}
JSON
cat > "$WORK/downgrade.json" <<JSON
{"schema_version":1,"pr":12,
 "candidates":[{"fingerprint":"$FP","disposition":"rejected"}]}
JSON

count_recirc() { python3 "$TRK" --tracker "$REPO/TRACKER.md" query --stage Recirculation --status Todo | grep -c . ; }
# routing_gap as idc_git_finish computes it for this verdict on the filesystem backend.
gap_count() {
  python3 - "$PLUGIN" "$REPO" "$WORK/nit-verdict.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_git_finish as GF
verdict = json.load(open(sys.argv[3]))
gap = GF.routing_gap(verdict, "filesystem", sys.argv[2],
                     os.path.join(sys.argv[2], "TRACKER.md"), None, None)
print(len(gap))
PY
}

# ── the filing FAILS → the ledger entry sits at "filed" with nothing on the board ────────────────
set +e
OUT1="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/nit-verdict.json" \
          --tracker "$WORK/absent-dir/TRACKER.md" 2>&1)"; RC1=$?
set -e
[ "$RC1" -eq 3 ] || fail "a failed filing must exit 3, got $RC1 — [$OUT1]"
[ "$(count_recirc)" -eq 0 ] || fail "the failed filing still created board work"
python3 - "$LEDGER" "$FP" <<'PY' || fail "the failed filing did not leave the entry at last_disposition 'filed'"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
hits = [e for e in entries if e.get("fingerprint") == sys.argv[2]]
assert len(hits) == 1, entries
assert hits[0].get("last_disposition") == "filed", hits[0]
PY

# ── a model-authored round record must NOT be able to downgrade that pending-retry entry ─────────
LEDGER_BEFORE="$(cat "$LEDGER")"
set +e
BAD="$(python3 "$SEEN" record-round --repo "$REPO" --round "$WORK/downgrade.json" 2>&1)"; BADRC=$?
set -e
[ "$BADRC" -ne 0 ] \
  || fail "record-round accepted a downgrade of a pending-retry 'filed' entry: [$BAD]"
printf '%s' "$BAD" | grep -q "$FP" \
  || fail "the refusal did not name the pending-retry entry it protected: [$BAD]"
printf '%s' "$BAD" | grep -qi 'pending-retry' \
  || fail "the refusal did not identify the entry as a pending retry: [$BAD]"
[ "$(cat "$LEDGER")" = "$LEDGER_BEFORE" ] \
  || fail "a refused round record still mutated the seen ledger (the guard must run before any write)"
python3 - "$LEDGER" "$FP" <<'PY' || fail "the refused round record changed the entry's disposition"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
hits = [e for e in entries if e.get("fingerprint") == sys.argv[2]]
assert hits and hits[0].get("last_disposition") == "filed", entries
PY

# ── while unrouted, the finish routing gap must SEE it (no merge on a stranded finding) ──────────
[ "$(gap_count)" -eq 1 ] \
  || fail "idc_git_finish.routing_gap reported no gap ($(gap_count)) for a finding that is not on the board"

# ── the prescribed retry still files it ──────────────────────────────────────────────────────────
set +e
OUT2="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/nit-verdict.json" 2>&1)"; RC2=$?
set -e
[ "$RC2" -eq 0 ] || fail "the retry after the refused downgrade must succeed, got $RC2 — [$OUT2]"
printf '%s' "$OUT2" | grep -q 'filed 1' \
  || fail "the retry did not file the finding after the downgrade attempt: [$OUT2]"
[ "$(count_recirc)" -eq 1 ] \
  || fail "the retry left the board at $(count_recirc) Recirculation/Todo item(s), expected exactly 1"
[ "$(gap_count)" -eq 0 ] \
  || fail "routing_gap still reports a gap ($(gap_count)) after the finding was routed"

# ── corroborated case: once it IS on the board, the same round record is legal ───────────────────
set +e
OK="$(python3 "$SEEN" record-round --repo "$REPO" --round "$WORK/downgrade.json" 2>&1)"; OKRC=$?
set -e
[ "$OKRC" -eq 0 ] \
  || fail "record-round refused a downgrade of an entry the board actually carries (blanket refusal would jam the review loop): [$OK]"
[ "$(count_recirc)" -eq 1 ] || fail "the corroborated round record disturbed the board"

echo "PASS: record-round cannot downgrade an unrouted pending-retry entry (the retry still files it and the routing gap sees it), while a board-corroborated downgrade stays legal"
