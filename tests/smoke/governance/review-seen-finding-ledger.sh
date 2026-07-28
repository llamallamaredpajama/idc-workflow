#!/bin/bash
# idc-assert-class: behavior
# review-seen-finding-ledger.sh — U7 per-PR review-round seen fingerprint ledger.
#
# The deterministic filer must persist a per-PR seen ledger, and an invalid direct ledger write must
# be refused fail-closed. What "seen" may and may not do is the point of this scenario: a resurfaced
# fingerprint is only suppressed when the BOARD corroborates that its work is already routed. A
# prior `confirmed` (a major the filer never files) and a round record's `below-floor` both route
# NOTHING, so a later round that carries the same fingerprint as a live minor finding must FILE it —
# suppressing it would delete the only routing it ever gets while idc_git_finish.routing_gap read
# the merge as converged. Both filed tickets carry seen-ledger provenance.
#
# Red-when-broken (observed): make suppressible_fingerprints ignore corroboration (return the raw
# TERMINAL_NON_ROUTABLE set) => both resurfaced findings are suppressed, the board stays at 0
# Recirculation items, and both count assertions fail. Accept an invalid direct ledger write => the
# final refusal assertion flips.
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
# ── DO NOT RESTORE THE OLD ASSERTION HERE ────────────────────────────────────────────────────────
# The assertion that used to sit on this line was `[ "$(count_recirc)" -eq 0 ]` — it claimed that a
# major finding downgraded to minor in a later round is correctly SUPPRESSED as an already-seen
# duplicate. That was wrong, and it enshrined the defect it was meant to guard:
#   * round 1's major was a review FAIL the implementer must fix — the filer NEVER routes a
#     major/blocker to the board, so `confirmed` records work that was never routed;
#   * suppressing the round-2 downgrade therefore prevents no duplicate — it deletes the ONLY
#     routing the finding ever gets;
#   * `idc_git_finish.routing_gap` then exempts the resulting `suppressed-seen` entry, so the merge
#     gate reports "converged" over work that silently vanished — a false green.
# Spec §8 forbids re-filing duplicate ROUTED work. This work was never routed, so it must be filed;
# if the downgrade is genuinely not worth doing, a human closes the ticket visibly.
[ "$(count_recirc)" -eq 1 ] \
  || fail "a confirmed(major) finding downgraded to minor in a later round vanished instead of being filed: expected exactly 1 Recirculation/Todo ticket, got $(count_recirc)"
# provenance: the filed ticket must say which review round filed it and what severity it carried
# before the downgrade, so the downgrade is auditable rather than an unexplained new nit.
python3 - "$PLUGIN" "$REPO" <<'PY' || fail "the downgrade ticket carries no seen-ledger provenance (review round + original severity)"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_tracker_fs
state = idc_tracker_fs.load(os.path.join(sys.argv[2], "TRACKER.md"))
blob = "\n".join(c for it in state.get("issues", [])
                 if (it.get("stage") or "") == "Recirculation"
                 for c in (it.get("comments") or []))
assert "review round 2" in blob, blob
assert "original severity major" in blob, blob
PY
[ -f "$LEDGER" ] || fail "the per-PR seen-fingerprint ledger was not written"
python3 - "$LEDGER" <<'PY' || fail "the per-PR seen-fingerprint ledger did not retain the resurfaced finding exactly once"
import json, sys
ledger = json.load(open(sys.argv[1]))
entries = ledger.get("entries") or []
assert len(entries) == 1, entries
entry = entries[0]
assert entry.get("fingerprint") == "security:feature-x.py:17:shared-defect", entry
assert int(entry.get("seen_count") or 0) >= 2, entry
# "filed" exactly: the downgrade was ROUTED, not swallowed as "suppressed-seen"
assert entry.get("last_disposition") == "filed", entry
assert entry.get("first_severity") == "major", entry   # provenance for the downgrade
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
  # ── DO NOT RESTORE THE OLD ASSERTION HERE EITHER ────────────────────────────────────────────────
  # It was `[ "$(count_recirc)" -eq 0 ]`, claiming a below-floor candidate that a later round raises
  # as a live minor finding is correctly suppressed. Same false green as the downgrade above: a
  # round record's `below-floor` routes NO board work, so suppressing the resurfacing deletes the
  # only routing the finding gets. A round record saying "not work" and a verdict saying "minor
  # work" for the same fingerprint is a self-contradiction, and fixed code resolves it toward the
  # board — the ledger records that it was seen, the BOARD decides what is already routed.
  [ "$(count_recirc)" -eq 2 ] \
    || fail "a below-floor candidate the next round raised as a live minor finding vanished: expected 2 Recirculation/Todo tickets, got $(count_recirc)"
  python3 - "$PLUGIN" "$REPO" <<'PY' || fail "the resurfaced below-floor ticket does not name the round record that had dropped it"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_tracker_fs
state = idc_tracker_fs.load(os.path.join(sys.argv[2], "TRACKER.md"))
blob = "\n".join(c for it in state.get("issues", [])
                 if (it.get("stage") or "") == "Recirculation"
                 for c in (it.get("comments") or []))
assert "previously recorded below-floor by a review round record" in blob, blob
PY
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
