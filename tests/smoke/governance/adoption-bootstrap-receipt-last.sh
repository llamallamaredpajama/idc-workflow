#!/bin/bash
# idc-assert-class: behavior
# adoption-bootstrap-receipt-last.sh — U13 bootstrap finalizes RECEIPT-LAST, gated on a verified-
# converged confirming scan (final-review blocker B2).
#
# The one-time adoption bootstrap runs two scans: a pass-1 scan (no receipt yet) and a "confirming"
# post-final scan that runs WITH the freshly written receipt so it can compute the post-boundary
# watermark. The playbook invariant (commands/update.md Phase 3c) is: **only a converged bootstrap
# clears the baseline-pending marker and keeps the adoption receipt.** If the confirming scan is NOT
# clean (blockers / indeterminate ground truth), the repo must stay honestly `baseline-pending` — no
# durable `reconciliation-adoption.json` — and exit non-zero. The B2 defect was that finalization
# (checkpoint + receipt + marker-clear) ran BEFORE the confirming scan, so a non-clean confirming
# scan left the repo momentarily "adopted" (marker cleared + receipt written) while the scan said
# not-converged — a temporary false-completion.
#
# Proves four things on hermetic filesystem-backend repos:
#   A. B2 repro: a bootstrap whose confirming post-final scan is NOT clean leaves baseline-pending
#      PRESENT, writes NO adoption receipt, and exits non-zero with the blocker reported honestly.
#   B. Happy path unchanged: a converged bootstrap writes the receipt + checkpoint, clears the
#      marker, reports legacy-adopted, and exits 0 — exactly as before.
#   C. Empty-board / no-journal legacy repo bootstraps cleanly (the update-adoption anomaly-1 fix):
#      no human need pre-create an empty transition journal.
#   D. Crash-window safety: an interrupt AFTER the provisional receipt write but before the marker
#      clears leaves the repo baseline-pending (never a cleared marker), and a later run resumes to a
#      real adoption receipt.
#
# Red-when-broken (reviewed): restore the old finalize-before-scan order => Case A flips (receipt
# written + marker cleared while the confirming scan is not clean); neuter the convergence gate
# (finalize regardless of the confirming result) => Case A flips; drop the empty-board no-journal
# tolerance => Case C flips; clear the marker before the confirming scan converges => Case D flips.
#
# Usage: bash tests/smoke/governance/adoption-bootstrap-receipt-last.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$JAN" ] || gov_fail "scripts/idc_git_janitor.py not found"
[ -f "$TRK" ] || gov_fail "scripts/idc_tracker_fs.py not found"

MARKER_REL="docs/workflow/reconciliation-baseline-required.json"
ADOPTION_REL="docs/workflow/reconciliation-adoption.json"
CHECKPOINT_REL="docs/workflow/reconciliation-checkpoint.json"
JOURNAL_REL="docs/workflow/transition-journal.ndjson"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# new_repo <repo-dir> — a hermetic filesystem-backend governed repo with a baseline-pending marker,
# a base commit, and (intentionally) NO transition journal. Each case decides whether to add the
# journal and/or a legacy board item. The board starts empty.
new_repo() {
  local repo="$1"
  mkdir -p "$repo/docs/workflow" || gov_fail "could not create repo dirs ($repo)"
  git init -q -b main "$repo" || gov_fail "git init failed ($repo)"
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  printf 'backend: filesystem\n' > "$repo/docs/workflow/tracker-config.yaml"
  python3 "$TRK" --tracker "$repo/TRACKER.md" init >/dev/null || gov_fail "tracker init failed ($repo)"
  printf base > "$repo/app.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base >/dev/null || gov_fail "base commit failed ($repo)"
  cat > "$repo/$MARKER_REL" <<'JSON'
{
  "schema_version": 1,
  "state": "baseline-pending",
  "reason": "reconciliation-baseline-required"
}
JSON
}

# run_boot <repo> [extra-env-assignment] — run `--bootstrap --json`, capturing BOOT_OUT + BOOT_RC.
run_boot() {
  local repo="$1"; shift
  set +e
  BOOT_OUT="$(env "$@" python3 "$JAN" --repo "$repo" --tracker "$repo/TRACKER.md" --bootstrap --json 2>/dev/null)"
  BOOT_RC=$?
  set +e
}

# ---------------------------------------------------------------------------------------------------
# Case A — B2 reproduction: the confirming post-final scan is NOT clean, so the bootstrap must NOT
# have cleared baseline-pending nor written a durable adoption receipt.
#
# Fixture: a NON-empty board (one legacy Buildable item) with NO transition journal on disk. Pass-1
# has no receipt, so it is clean and the bootstrap proceeds to finalize; the confirming scan then
# runs WITH the receipt, and a missing journal beside a non-empty adopted board is an indeterminate
# post-boundary gap (root_id `post-boundary-journal`) → the confirming scan is not clean.
# ---------------------------------------------------------------------------------------------------
REPO_A="$WORK/repoA"; new_repo "$REPO_A"
gov_seed_item "$REPO_A/TRACKER.md" --title 'legacy buildable' --stage Buildable --status Todo >/dev/null \
  || gov_fail "Case A: legacy item create failed"
# (no journal on disk — this is what makes the confirming post-final scan not-clean)

run_boot "$REPO_A"
[ "$BOOT_RC" -ne 0 ] \
  || gov_fail "Case A: a bootstrap whose confirming scan is not clean must exit non-zero (only a converged bootstrap may exit 0) — got $BOOT_RC"
[ -f "$REPO_A/$MARKER_REL" ] \
  || gov_fail "Case A: INVARIANT VIOLATED — bootstrap cleared baseline-pending before the confirming scan converged (temporary false-completion); the marker must still be present"
[ ! -f "$REPO_A/$ADOPTION_REL" ] \
  || gov_fail "Case A: INVARIANT VIOLATED — bootstrap wrote a durable adoption receipt while the confirming scan is not converged (temporary false-completion); no reconciliation-adoption.json may survive"
BOOT_OUT="$BOOT_OUT" python3 - <<'PY' || gov_fail "Case A: the non-converged bootstrap did not report the confirming-scan blocker honestly"
import json, os
report = json.loads(os.environ["BOOT_OUT"])
assert report.get("verdict") in ("findings", "indeterminate"), report
findings = report.get("findings", [])
assert any(f.get("blocker") for f in findings), ("no blocker reported", report)
assert any(f.get("root_id") == "post-boundary-journal" for f in findings), ("post-boundary-journal blocker missing", findings)
assert report.get("baseline", {}).get("state") != "legacy-adopted", ("repo was momentarily marked adopted", report)
PY

# ---------------------------------------------------------------------------------------------------
# Case B — happy path unchanged: a converged bootstrap finalizes exactly as before.
#
# Fixture: one legacy Buildable item AND an (empty) transition journal on disk. Pass-1 clean; the
# confirming scan (receipt present, empty journal, legacy item matched by the receipt) is clean →
# converged.
# ---------------------------------------------------------------------------------------------------
REPO_B="$WORK/repoB"; new_repo "$REPO_B"
gov_seed_item "$REPO_B/TRACKER.md" --title 'legacy buildable' --stage Buildable --status Todo >/dev/null \
  || gov_fail "Case B: legacy item create failed"
: > "$REPO_B/$JOURNAL_REL"

run_boot "$REPO_B"
[ "$BOOT_RC" -eq 0 ] \
  || gov_fail "Case B: a converged bootstrap must exit 0, got $BOOT_RC — [$BOOT_OUT]"
[ -f "$REPO_B/$ADOPTION_REL" ] \
  || gov_fail "Case B: a converged bootstrap must write the durable adoption receipt"
[ -f "$REPO_B/$CHECKPOINT_REL" ] \
  || gov_fail "Case B: a converged bootstrap must write the convergence checkpoint"
[ ! -f "$REPO_B/$MARKER_REL" ] \
  || gov_fail "Case B: a converged bootstrap must clear the baseline-pending marker"
BOOT_OUT="$BOOT_OUT" python3 - <<'PY' || gov_fail "Case B: converged bootstrap report is not the honest legacy-adopted state"
import json, os
report = json.loads(os.environ["BOOT_OUT"])
assert report.get("baseline", {}).get("state") == "legacy-adopted", report
assert report.get("plan", {}).get("validated") is True, report
assert report.get("plan", {}).get("checkpoint_advanced") is True, report
PY

# ---------------------------------------------------------------------------------------------------
# Case C — empty-board / no-journal legacy repo (update-adoption anomaly 1): must bootstrap cleanly
# without a human first creating an empty transition journal. An empty board has no post-boundary
# tracker facts, so a missing journal is the lazy pre-journal start, not an indeterminate gap.
# ---------------------------------------------------------------------------------------------------
REPO_C="$WORK/repoC"; new_repo "$REPO_C"
# empty board, NO journal on disk

run_boot "$REPO_C"
[ "$BOOT_RC" -eq 0 ] \
  || gov_fail "Case C: an empty-board / no-journal legacy repo must bootstrap cleanly (exit 0), got $BOOT_RC — [$BOOT_OUT]"
[ -f "$REPO_C/$ADOPTION_REL" ] \
  || gov_fail "Case C: empty-board / no-journal bootstrap must write the durable adoption receipt"
[ ! -f "$REPO_C/$MARKER_REL" ] \
  || gov_fail "Case C: empty-board / no-journal converged bootstrap must clear the baseline-pending marker"
BOOT_OUT="$BOOT_OUT" python3 - <<'PY' || gov_fail "Case C: empty-board / no-journal bootstrap did not converge honestly"
import json, os
report = json.loads(os.environ["BOOT_OUT"])
assert report.get("baseline", {}).get("state") == "legacy-adopted", report
assert report.get("plan", {}).get("validated") is True, report
PY

# ---------------------------------------------------------------------------------------------------
# Case D — crash-window safety: an interrupt AFTER the provisional receipt write but BEFORE the
# marker clears must leave the repo baseline-pending (never a cleared marker), and a later run must
# resume to a real adoption receipt. Convergent fixture (empty journal, empty board).
# ---------------------------------------------------------------------------------------------------
REPO_D="$WORK/repoD"; new_repo "$REPO_D"
: > "$REPO_D/$JOURNAL_REL"

set +e
env IDC_JANITOR_TEST_INTERRUPT_AFTER='after-provisional-receipt' \
  python3 "$JAN" --repo "$REPO_D" --tracker "$REPO_D/TRACKER.md" --bootstrap --json >/dev/null 2>&1
RC_D=$?
set +e
[ "$RC_D" -eq 99 ] \
  || gov_fail "Case D: the after-provisional-receipt interrupt hook did not surface the expected test exit 99 (got $RC_D)"
[ -f "$REPO_D/$MARKER_REL" ] \
  || gov_fail "Case D: INVARIANT VIOLATED — an interrupt after the provisional receipt cleared baseline-pending; the marker must survive until the confirming scan converges"

run_boot "$REPO_D"
[ "$BOOT_RC" -eq 0 ] \
  || gov_fail "Case D: bootstrap restart after a crash-window interrupt must resume and converge (exit 0), got $BOOT_RC — [$BOOT_OUT]"
[ -f "$REPO_D/$ADOPTION_REL" ] \
  || gov_fail "Case D: bootstrap restart must write a real adoption receipt"
[ ! -f "$REPO_D/$MARKER_REL" ] \
  || gov_fail "Case D: bootstrap restart did not clear the baseline-pending marker after success"

echo "PASS: bootstrap finalizes receipt-last — a non-converged confirming scan stays baseline-pending with no receipt, the converged happy path is unchanged, empty-board/no-journal legacy repos bootstrap cleanly, and the provisional-receipt crash window resumes safely"
