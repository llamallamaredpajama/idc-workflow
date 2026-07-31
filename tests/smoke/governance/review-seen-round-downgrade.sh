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
#   Give the guard a fail-OPEN shortcut (`if not routed: continue` right after the routed lookup in
#   _refuse_pending_retry_downgrade) => the unreadable-board round record is GRANTED => FAIL.
#   Poison the fail-closed handler in board_routed_fingerprints (make `raise RuntimeError(...)` its
#   first statement) => the discriminating marker never appears => FAIL. That last one is the point
#   of the unreadable-board block below: until it drove a GENUINE board-read failure it hid the
#   tracker with `mv TRACKER.md TRACKER.md.hidden`, which the FILESYSTEM backend degrades to an
#   empty board (idc_file_findings._fs_state swallows the loader's SystemExit) instead of failing —
#   so the handler was never entered, and the poisoned-handler probe stayed GREEN.
#
# Usage: bash tests/smoke/governance/review-seen-round-downgrade.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FILER="$PLUGIN/scripts/idc_file_findings.py"
SEEN="$PLUGIN/scripts/idc_review_seen_ledger.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
FINISH="$PLUGIN/scripts/idc_git_finish.py"
fail() { echo "FAIL: $1"; exit 1; }
# shellcheck source=../lib/fail-closed.sh
. "$(dirname "$0")/../lib/fail-closed.sh"   # assert_fail_closed / fc_require_file

fc_require_file "$FILER" "filer"
fc_require_file "$SEEN" "seen ledger helper"
fc_require_file "$TRK" "tracker backend"
fc_require_file "$FINISH" "finisher"

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
printf '%s' "$BAD" | grep -qF -- "$FP" \
  || fail "the refusal did not name the pending-retry entry it protected: [$BAD]"
printf '%s' "$BAD" | grep -qi 'pending-retry' \
  || fail "the refusal did not identify the entry as a pending retry: [$BAD]"
# POSITIVE CONTROL for the fail-closed marker asserted further down: THIS refusal read the board
# fine (it just found nothing routed), so the board-read failure line must be absent here. Without
# this, "the marker appeared" could not distinguish an unreadable board from an ordinary refusal —
# which is precisely how the unreadable-board block below used to pass while never reaching its guard.
! printf '%s' "$BAD" | grep -qF 'could not read the board to corroborate routed findings' \
  || fail "an ordinary refusal on a READABLE board claimed it could not read the board — the fail-closed marker does not discriminate: [$BAD]"
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

# ── an UNREADABLE board corroborates nothing: the refusal must fail CLOSED ───────────────────────
# This must drive a GENUINE board-read failure. Hiding TRACKER.md does NOT produce one: on the
# filesystem backend idc_file_findings._fs_state catches the loader's SystemExit and degrades a
# missing tracker to an empty board, so board_routed_fingerprints returns normally with an empty set
# and its fail-closed handler is never entered — the refusal that follows is the ORDINARY unrouted
# refusal, indistinguishable from the guarded one.
#
# So: an isolated COPY of the repo switched to the github backend with no owner/project resolvable
# (a stub `gh` first on PATH keeps it hermetic and instant), which makes routed_finding_fingerprints
# raise BoardReadError for real. The assertion then keys on the DISCRIMINATING artifact only that
# path emits — the "could not read the board to corroborate routed findings … (fail closed)" line —
# with the readable-board run as the positive control proving that line is absent otherwise.
REPO_BLIND="$WORK/repo-unreadable-board"
cp -R "$REPO" "$REPO_BLIND" || fail "could not copy the repo for the unreadable-board case"
printf 'backend: github\n' > "$REPO_BLIND/docs/workflow/tracker-config.yaml"
mkdir -p "$WORK/stub-bin"
printf '#!/bin/sh\necho "stub gh: no board here" >&2\nexit 1\n' > "$WORK/stub-bin/gh"
chmod +x "$WORK/stub-bin/gh"
BLIND_LEDGER="$REPO_BLIND/docs/workflow/code-reviews/pr-12-seen-fingerprints.json"
BLIND_BEFORE="$(cat "$BLIND_LEDGER")"

# The positive control is the SAME command on the readable board — which is also the corroborated
# case this scenario has to pin anyway: once the ticket IS on the board the downgrade is legal, so a
# blanket refusal (which would satisfy a marker-free assertion) is a failure here too.
assert_fail_closed \
  "a board record-round cannot read corroborates nothing, so the pending-retry downgrade must be refused" \
  'could not read the board to corroborate routed findings' \
  -- env PATH="$WORK/stub-bin:$PATH" python3 "$SEEN" record-round --repo "$REPO_BLIND" --round "$WORK/downgrade.json" \
  -- env PATH="$WORK/stub-bin:$PATH" python3 "$SEEN" record-round --repo "$REPO" --round "$WORK/downgrade.json"

printf '%s' "$FC_GUARDED_OUT" | grep -qF -- "$FP" \
  || fail "the unreadable-board refusal did not name the pending-retry entry it protected: [$FC_GUARDED_OUT]"
printf '%s' "$FC_GUARDED_OUT" | grep -qi 'PENDING-RETRY seen entry' \
  || fail "the unreadable-board refusal did not identify the entry as a pending retry: [$FC_GUARDED_OUT]"
[ "$(cat "$BLIND_LEDGER")" = "$BLIND_BEFORE" ] \
  || fail "the fail-closed refusal still mutated the seen ledger (the guard must run before any write)"
python3 - "$BLIND_LEDGER" "$FP" <<'PY' || fail "the fail-closed refusal still changed the entry's disposition"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
hits = [e for e in entries if e.get("fingerprint") == sys.argv[2]]
assert hits and hits[0].get("last_disposition") == "filed", entries
PY

# ── corroborated case: once it IS on the board, the same round record is legal ───────────────────
# The positive control above WAS that call. Assert it did the legal thing rather than merely exiting
# 0 for some other reason: the entry is now at the round's terminal disposition, board untouched.
[ "$FC_CONTROL_RC" -eq 0 ] \
  || fail "record-round refused a downgrade of an entry the board actually carries (blanket refusal would jam the review loop): [$FC_CONTROL_OUT]"
python3 - "$LEDGER" "$FP" <<'PY' || fail "the board-corroborated round record did not apply its disposition"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
hits = [e for e in entries if e.get("fingerprint") == sys.argv[2]]
assert hits and hits[0].get("last_disposition") == "rejected", entries
assert hits[0].get("last_source") == "round", entries
PY
[ "$(count_recirc)" -eq 1 ] || fail "the corroborated round record disturbed the board"

echo "PASS: record-round cannot downgrade an unrouted pending-retry entry (the retry still files it and the routing gap sees it) and fails closed on an unreadable board, while a board-corroborated downgrade stays legal"
