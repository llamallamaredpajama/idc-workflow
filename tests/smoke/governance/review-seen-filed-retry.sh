#!/bin/bash
# idc-assert-class: behavior
# review-seen-filed-retry.sh — a FAILED filing plus its own prescribed retry must still route.
#
# The per-PR seen ledger records disposition "filed" BEFORE the filing is attempted, so a filing that
# fails leaves the entry at "filed" with nothing on the board. That entry is a PENDING RETRY: the
# prescribed retry must file it for real. If "filed" ever counts as a terminal non-routable
# disposition (scripts/idc_review_seen_ledger.py TERMINAL_NON_ROUTABLE), the retry suppresses the
# finding as "already seen", the board never gets the item, and idc_git_finish's routing gap exempts
# it — a real finding stranded forever while the finish gate reports converged.
#
# The severity here MUST stay minor/nit. record_verdict_seen maps major/blocker to "confirmed", which
# is terminal both before and after the regression — a major fixture pins nothing and would stay green
# with the bug reinstated (that is exactly how this gap went uncovered).
#
# Red-when-broken (observed): add "filed" back into TERMINAL_NON_ROUTABLE =>
#   run 2 reports "filed 0, ... suppressed 1 seen finding(s)" and the board count stays 0 => FAIL.
#
# Usage: bash tests/smoke/governance/review-seen-filed-retry.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FILER="$PLUGIN/scripts/idc_file_findings.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$FILER" ] || fail "filer not found at $FILER"
[ -f "$TRK" ] || fail "tracker backend not found at $TRK"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || fail "tracker init failed"
PARENT="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'build: feature Y' --stage Buildable --status 'In Progress')" \
  || fail "parent create failed"
LEDGER="$REPO/docs/workflow/code-reviews/pr-11-seen-fingerprints.json"
FP='security:token-refresh.py:73:unbounded-retry'

cat > "$WORK/nit-verdict.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":11,
 "findings":[{"dimension":"security","severity":"minor","confidence":0.95,
   "evidence":"retry loop has no ceiling","attack":"a","unblock":"u",
   "fingerprint":"$FP"}]}
JSON

count_recirc() { python3 "$TRK" --tracker "$REPO/TRACKER.md" query --stage Recirculation --status Todo | grep -c . ; }

# ── run 1: the filing FAILS (the tracker it is pointed at does not exist) ────────────────────────
set +e
OUT1="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/nit-verdict.json" \
          --tracker "$WORK/absent-dir/TRACKER.md" 2>&1)"; RC1=$?
set -e
[ "$RC1" -eq 3 ] || fail "a failed filing must exit 3, got $RC1 — [$OUT1]"
[ "$(count_recirc)" -eq 0 ] || fail "run 1 filed board work despite the filing failing"
[ -f "$LEDGER" ] || fail "run 1 did not write the per-PR seen ledger at $LEDGER"
python3 - "$LEDGER" "$FP" <<'PY' || fail "run 1 did not leave the finding at last_disposition 'filed' (the pending-retry state)"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
hits = [e for e in entries if e.get("fingerprint") == sys.argv[2]]
assert len(hits) == 1, entries
assert hits[0].get("last_disposition") == "filed", hits[0]
PY

# ── run 2: the prescribed retry, valid tracker → it MUST file, not suppress ──────────────────────
set +e
OUT2="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/nit-verdict.json" 2>&1)"; RC2=$?
set -e
[ "$RC2" -eq 0 ] || fail "the retry after a failed filing must succeed, got $RC2 — [$OUT2]"
printf '%s' "$OUT2" | grep -q 'filed 1' \
  || fail "the retry after a failed filing did not file the finding (a pending-retry 'filed' entry was treated as terminal): [$OUT2]"
printf '%s' "$OUT2" | grep -q 'suppressed 0 seen finding' \
  || fail "the retry suppressed a finding whose filing had failed: [$OUT2]"
[ "$(count_recirc)" -eq 1 ] \
  || fail "the retry left the board at $(count_recirc) Recirculation/Todo item(s), expected exactly 1"

# ── run 3: a third identical run is idempotent via the BOARD key, not the ledger ─────────────────
set +e
OUT3="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/nit-verdict.json" 2>&1)"; RC3=$?
set -e
[ "$RC3" -eq 0 ] || fail "a third identical filing run must succeed, got $RC3 — [$OUT3]"
printf '%s' "$OUT3" | grep -q 'skipped 1 duplicate' \
  || fail "the third run did not dedupe against the board key: [$OUT3]"
printf '%s' "$OUT3" | grep -q 'filed 0' \
  || fail "the third run filed a duplicate board item: [$OUT3]"
[ "$(count_recirc)" -eq 1 ] \
  || fail "the third run changed the board count to $(count_recirc), expected it to stay at 1"

echo "PASS: a failed filing stays retryable — the retry routes the finding to the board and the run after it dedupes on the board key"
