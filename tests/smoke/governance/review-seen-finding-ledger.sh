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
# Suppression is the OTHER half, and it is asserted here too — in the opposite direction. A minor
# that the filer actually routed, which a later round record then `rejected`, IS corroborated by the
# board, so re-filing the same verdict must SUPPRESS it. Without that positive case the whole
# dedupe/suppression behaviour could be hard-wired off (`suppressible_fingerprints` → `set()`) with
# every scenario in this lane still green: the negative cases all assert "not suppressed", and the
# filesystem board-key dedupe independently stops the duplicate ticket. Asserting `suppressed 1` is
# not enough on its own either — `skipped 1 duplicate` is what the board-key path prints, so the
# assertion pins BOTH counters plus the `suppressed-seen` ledger disposition, which only the
# suppression path can write.
#
# Red-when-broken (observed): make suppressible_fingerprints ignore corroboration (return the raw
# TERMINAL_NON_ROUTABLE set) => both resurfaced findings are suppressed, the board stays at 0
# Recirculation items, and both count assertions fail. Make it suppress NOTHING (`return set()`)
# => the board-corroborated resurfacing reports "suppressed 0 / skipped 1 duplicate" and its ledger
# entry stays "filed" instead of "suppressed-seen" => FAIL, in the opposite direction. Accept an
# invalid direct ledger write => the final refusal assertion flips.
#
# Usage: bash tests/smoke/governance/review-seen-finding-ledger.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FILER="$PLUGIN/scripts/idc_file_findings.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
SEEN="$PLUGIN/scripts/idc_review_seen_ledger.py"
fail() { echo "FAIL: $1"; exit 1; }
# shellcheck source=../lib/fail-closed.sh
. "$(dirname "$0")/../lib/fail-closed.sh"   # assert_fail_closed / fc_require_file

# Hard guards, never `if [ -f … ]`: a fixture that wraps assertions in an existence test silently
# deletes them the day a path is wrong, and still prints PASS.
fc_require_file "$FILER" "filer"
fc_require_file "$TRK" "tracker backend"
fc_require_file "$SEEN" "seen ledger helper"

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
# (Discussion trail: branch `followup/part2-seen-ledger-convergence`, commit e75bde8 "fix(review-
# ledger): only the board may authorize suppressing a seen finding", a follow-up to PR #182.)
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
# ── DO NOT RESTORE THE OLD ASSERTION HERE EITHER ──────────────────────────────────────────────────
# (Same discussion trail: branch `followup/part2-seen-ledger-convergence`, commit e75bde8, PR #182.)
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

# ── the OTHER direction: a BOARD-CORROBORATED resurfacing IS suppressed ──────────────────────────
# Everything above asserts what must NOT be suppressed. Nothing asserted what MUST be — so the whole
# suppression path could be deleted and this lane stayed green. Here the finding really is routed:
# the filer files it, a later round record `rejected`s it (legal precisely BECAUSE the board carries
# it), and the re-filed verdict must then be suppressed as an already-routed duplicate.
ROUTED_FP='perf:feature-x.py:44:unbounded-allocation'
cat > "$WORK/routed-minor.json" <<JSON
{"verdict":"PASS-WITH-NITS","issue":$PARENT,"pr":9,
 "findings":[{"dimension":"perf","severity":"minor","confidence":0.95,
   "evidence":"the warm path allocates per element","attack":"a","unblock":"u",
   "fingerprint":"$ROUTED_FP"}]}
JSON
python3 "$FILER" --repo "$REPO" --verdict "$WORK/routed-minor.json" >/dev/null \
  || fail "filing the to-be-suppressed finding failed"
[ "$(count_recirc)" -eq 3 ] \
  || fail "the finding that must later be suppressed was not routed in the first place: expected 3 Recirculation/Todo tickets, got $(count_recirc)"
cat > "$WORK/reject-routed-round.json" <<JSON
{"schema_version":1,"pr":9,
 "candidates":[{"dimension":"perf","confidence":0.4,"fingerprint":"$ROUTED_FP","disposition":"rejected"}]}
JSON
python3 "$SEEN" record-round --repo "$REPO" --round "$WORK/reject-routed-round.json" >/dev/null \
  || fail "record-round refused to reject a fingerprint the board actually carries (the corroborated flip must stay legal)"
set +e
SUP="$(python3 "$FILER" --repo "$REPO" --verdict "$WORK/routed-minor.json" 2>&1)"; SUPRC=$?
set -e
[ "$SUPRC" -eq 0 ] || fail "re-filing a board-corroborated resurfacing exited $SUPRC — [$SUP]"
# `suppressed 1` AND `skipped 0 duplicate`: the counters discriminate the seen-ledger suppression
# path from the board-key dedupe path, which is the OTHER way this run could report "no new ticket".
printf '%s' "$SUP" | grep -qF 'suppressed 1 seen finding' \
  || fail "a resurfaced finding the BOARD corroborates as routed was not suppressed — the dedupe half of the seen ledger is doing nothing: [$SUP]"
printf '%s' "$SUP" | grep -qF 'skipped 0 duplicate' \
  || fail "the resurfacing was stopped by the board-key dedupe, not by seen-ledger suppression — this assertion would pass with suppression deleted: [$SUP]"
printf '%s' "$SUP" | grep -qF 'filed 0' \
  || fail "the suppressed resurfacing still filed board work: [$SUP]"
[ "$(count_recirc)" -eq 3 ] \
  || fail "the suppressed resurfacing changed the board count to $(count_recirc), expected it to stay at 3"
python3 - "$LEDGER" "$ROUTED_FP" <<'PY' || fail "the suppressed resurfacing was not recorded as 'suppressed-seen' by the filer — only the suppression path writes that disposition"
import json, sys
entries = json.load(open(sys.argv[1])).get("entries") or []
hits = [e for e in entries if e.get("fingerprint") == sys.argv[2]]
assert len(hits) == 1, entries
assert hits[0].get("last_disposition") == "suppressed-seen", hits[0]
assert hits[0].get("last_source") == "filer", hits[0]
PY

# ── a model-authored direct ledger write is refused FAIL-CLOSED ──────────────────────────────────
# Run against an isolated COPY so $REPO's ledger survives for nothing else to trip over, and key on
# the refusal's OWN sentence — `grep -qi 'seen'` used to match the ledger FILENAME echoed in the
# message (pr-9-seen-fingerprints.json), i.e. the fixture's own scaffolding, so it could not tell a
# validation refusal from any other failure. The positive control is the same filer run against the
# untouched repo, where that sentence must not appear.
REPO_BADLEDGER="$WORK/repo-invalid-ledger"
cp -R "$REPO" "$REPO_BADLEDGER" || fail "could not copy the repo for the invalid-ledger case"
cat > "$REPO_BADLEDGER/docs/workflow/code-reviews/pr-9-seen-fingerprints.json" <<'JSON'
{"schema_version":1,"pr":9,"entries":["model-authored-pass"]}
JSON
assert_fail_closed \
  "a directly model-authored seen ledger must refuse the whole filing run, not be silently rebuilt" \
  'refusing to file — review seen-fingerprint ledger did not validate' \
  -- python3 "$FILER" --repo "$REPO_BADLEDGER" --verdict "$WORK/round2-minor.json" \
  -- python3 "$FILER" --repo "$REPO" --verdict "$WORK/round2-minor.json"
printf '%s' "$FC_GUARDED_OUT" | grep -qF 'refusing a direct model-authored ledger write' \
  || fail "the refusal did not say WHY the ledger was rejected (a model-authored entry), so it cannot be told from any other read failure: [$FC_GUARDED_OUT]"

echo "PASS: review rounds persist seen fingerprints, file resurfaced work the board never routed, suppress a resurfacing the board DOES corroborate, and refuse invalid direct ledger writes"
