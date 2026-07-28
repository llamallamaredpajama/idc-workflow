#!/bin/bash
# idc-assert-class: behavior
# review-seen-finding-ledger.sh — U7 per-PR review-round seen fingerprint ledger.
#
# A finding seen in an earlier review round must not come back as new routed board work in a later
# round, even if the earlier round kept it at FAIL. The deterministic filer must persist a per-PR seen
# ledger, and an invalid direct ledger write must be refused fail-closed.
#
# Red-when-broken (reviewed): ignore earlier-round seen fingerprints => the second-round resurfaced
# finding is filed as duplicate routed work; accept an invalid direct ledger write => the final refusal
# assertion flips.
#
# Usage: bash tests/smoke/governance/review-seen-finding-ledger.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FILER="$PLUGIN/scripts/idc_file_findings.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
SEEN="$PLUGIN/scripts/idc_review_seen_ledger.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$FILER" ] || fail "filer not found at $FILER"
[ -f "$TRK" ] || fail "tracker backend not found at $TRK"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null
PARENT="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'build: feature X' --stage Buildable --status 'In Progress')"
LEDGER="$REPO/docs/workflow/code-reviews/pr-9-seen-fingerprints.json"

cat > "$WORK/round1-major.json" <<JSON
{"verdict":"FAIL","issue":$PARENT,"pr":9,
 "findings":[{"dimension":"security","severity":"major","confidence":0.95,
   "evidence":"same defect across rounds","attack":"a","unblock":"u",
   "fingerprint":"security:feature-x.py:17:shared-defect"}]}
JSON
cat > "$WORK/round2-minor.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":9,
 "findings":[{"dimension":"security","severity":"minor","confidence":0.95,
   "evidence":"same defect across rounds","attack":"a","unblock":"u",
   "fingerprint":"security:feature-x.py:17:shared-defect"}]}
JSON

count_recirc() { python3 "$TRK" --tracker "$REPO/TRACKER.md" query --stage Recirculation --status Todo | grep -c . ; }

python3 "$FILER" --repo "$REPO" --verdict "$WORK/round1-major.json" >/dev/null \
  || fail "round 1 major verdict filing failed"
[ "$(count_recirc)" -eq 0 ] || fail "round 1 major finding must not file Recirculation work"
python3 "$FILER" --repo "$REPO" --verdict "$WORK/round2-minor.json" >/dev/null \
  || fail "round 2 minor verdict filing failed"
[ "$(count_recirc)" -eq 0 ] \
  || fail "a resurfaced seen finding was treated as new and filed duplicate routed board work"
[ -f "$LEDGER" ] || fail "the per-PR seen-fingerprint ledger was not written"
python3 - "$LEDGER" <<'PY' || fail "the per-PR seen-fingerprint ledger did not retain the resurfaced finding exactly once"
import json, sys
ledger = json.load(open(sys.argv[1]))
entries = ledger.get("entries") or []
assert len(entries) == 1, entries
entry = entries[0]
assert entry.get("fingerprint") == "security:feature-x.py:17:shared-defect", entry
assert int(entry.get("seen_count") or 0) >= 2, entry
assert entry.get("last_disposition") in {"suppressed-seen", "confirmed", "filed"}, entry
PY

if [ -f "$SEEN" ]; then
  cat > "$WORK/below-floor-round.json" <<'JSON'
{"schema_version":1,"pr":9,
 "candidates":[{"dimension":"style","confidence":0.2,"fingerprint":"style:feature-x.py:21:low-floor","disposition":"below-floor"}]}
JSON
  python3 "$SEEN" record-round --repo "$REPO" --round "$WORK/below-floor-round.json" >/dev/null \
    || fail "record-round rejected a valid below-floor candidate"
  cat > "$WORK/below-floor-resurface.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":9,
 "findings":[{"dimension":"style","severity":"minor","confidence":0.95,
   "evidence":"same low-floor candidate resurfaced later","attack":"a","unblock":"u",
   "fingerprint":"style:feature-x.py:21:low-floor"}]}
JSON
  python3 "$FILER" --repo "$REPO" --verdict "$WORK/below-floor-resurface.json" >/dev/null \
    || fail "below-floor resurfaced verdict filing failed"
  [ "$(count_recirc)" -eq 0 ] \
    || fail "a below-floor seen fingerprint resurfaced as new routed work"
fi

cat > "$LEDGER" <<'JSON'
{"schema_version":1,"pr":9,"entries":["model-authored-pass"]}
JSON
set +e
BAD="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/round2-minor.json" 2>&1)"; BADRC=$?
set -e
[ "$BADRC" -ne 0 ] \
  || fail "review filing accepted an invalid direct seen-ledger write instead of refusing it fail-closed"
printf '%s' "$BAD" | grep -qi 'seen' \
  || fail "invalid review seen-ledger refusal did not mention the seen ledger problem: [$BAD]"

echo "PASS: review rounds persist seen fingerprints, suppress resurfaced routed work, and refuse invalid direct ledger writes"
