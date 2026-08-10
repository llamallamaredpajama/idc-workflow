#!/bin/bash
# idc-assert-class: behavior
# adoption-bootstrap-fixpoint.sh — `--bootstrap` converges on a direct-to-main repo.
#
# The baseline finding used to fire on a plain sha inequality between the adoption receipt's pinned
# default-branch head and the live one. `--bootstrap` pins the head as it stands BEFORE it writes its
# own three reconciliation state files — and those are tracked governed-tree state, so committing them
# (which the operator must) moved the head PAST the pin and re-raised the very finding the bootstrap was
# run to clear. Re-bootstrapping re-pinned and re-dirtied the same files: on a direct-to-main repo the
# loop had no fixpoint. Pinning "the head after the write" is not available as a remedy, because the
# bootstrap never commits those files, so the resulting sha does not exist when the receipt is minted.
#
# So the test asks the question it always meant to ask — did PRODUCT work land on the default branch
# outside a receipted path — instead of "did the sha change".
#
# Proves, on a hermetic filesystem-backend repo with a scanned board:
#   1. after `--bootstrap`, committing ONLY the machine-owned reconciliation state is CLEAN (the
#      treadmill is gone, and no second `--bootstrap` is needed);
#   2. an ordinary PRODUCT commit on the default branch STILL raises the RISKY baseline finding;
#   3. a MIXED commit (product + machine state together) STILL raises it — bookkeeping is not a cloak;
#   4. an unreadable pinned base FAILS CLOSED and raises, rather than silently passing.
#
# Red-when-broken (reviewed): make `_only_machine_state_moved` return True unconditionally => 2, 3 and 4
# flip; make it return False unconditionally => 1 flips; add ordinary paths to
# `_MACHINE_STATE_RELPATHS` => 2 flips; drop the `rc != 0` fail-closed guard => 4 flips.
#
# Usage: bash tests/smoke/governance/adoption-bootstrap-fixpoint.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
[ -f "$JAN" ] || gov_fail "scripts/idc_git_janitor.py not found"
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$GOV_PLUGIN/.claude-plugin/plugin.json")" || gov_fail "could not read the plugin version"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# adopted_repo <name> -> a governed repo that has been bootstrapped AND has committed the
# reconciliation state the bootstrap produced (the state every operator lands on).
adopted_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo/docs/workflow" || return 1
  git init -q -b main "$repo" || return 1
  git -C "$repo" config user.email t@t.t || return 1
  git -C "$repo" config user.name t || return 1
  printf 'backend: filesystem\n' > "$repo/docs/workflow/tracker-config.yaml" || return 1
  printf 'receipt_version: 2\nplugin_version: %s\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
    "$PLUGIN_VERSION" > "$repo/docs/workflow/install-receipt.yaml" || return 1
  python3 "$GOV_TRK" --tracker "$repo/TRACKER.md" init >/dev/null || return 1
  : > "$repo/docs/workflow/transition-journal.ndjson"
  printf 'base\n' > "$repo/app.txt"
  git -C "$repo" add -A >/dev/null 2>&1 || return 1
  git -C "$repo" commit -qm base >/dev/null 2>&1 || return 1
  python3 "$JAN" --repo "$repo" --tracker "$repo/TRACKER.md" --bootstrap >/dev/null 2>&1 \
    || return 1
  [ -f "$repo/docs/workflow/reconciliation-adoption.json" ] || return 1
  git -C "$repo" add -A docs/workflow/ >/dev/null 2>&1 || return 1
  git -C "$repo" commit -qm 'chore: reconciliation state' >/dev/null 2>&1 || return 1
  printf '%s' "$repo"
}

# baseline_count <repo> -> how many `baseline`-dimension findings the janitor reports.
baseline_count() {
  python3 "$JAN" --repo "$1" --tracker "$1/TRACKER.md" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(sum(1 for f in (json.load(sys.stdin).get("findings") or []) if f.get("dim")=="baseline"))'
}

# ── 1. bookkeeping-only forward progress is CLEAN — the treadmill is gone ───────────────────────────
R="$(adopted_repo bookkeeping)" || gov_fail "could not seed an adopted repo"
pinned="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["default_branch"]["head"])' \
  "$R/docs/workflow/reconciliation-adoption.json")" || gov_fail "could not read the pinned head"
[ "$pinned" != "$(git -C "$R" rev-parse HEAD)" ] \
  || gov_fail "fixture is vacuous: the pin already equals HEAD, so no head-moved check is exercised"
count="$(baseline_count "$R")"
[ "$count" = "0" ] \
  || gov_fail "committing only the bootstrap's own reconciliation state still raises $count baseline finding(s) — the --bootstrap treadmill is back"

# ── 2. un-receipted PRODUCT work on the default branch still raises ─────────────────────────────────
R="$(adopted_repo product)" || gov_fail "could not seed an adopted repo"
printf 'feature\n' >> "$R/app.txt"
git -C "$R" add app.txt >/dev/null 2>&1
git -C "$R" commit -qm 'feat: real work' >/dev/null 2>&1 || gov_fail "could not create the product commit"
count="$(baseline_count "$R")"
[ "$count" = "1" ] \
  || gov_fail "an un-receipted product commit on the default branch raised $count baseline findings (expected 1) — the guard is gone"

# ── 3. bookkeeping does not cloak product work in the same range ────────────────────────────────────
R="$(adopted_repo mixed)" || gov_fail "could not seed an adopted repo"
printf 'feature\n' >> "$R/app.txt"
printf '{"op":"move","n":1}\n' >> "$R/docs/workflow/transition-journal.ndjson"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm 'feat: mixed with bookkeeping' >/dev/null 2>&1 || gov_fail "could not create the mixed commit"
count="$(baseline_count "$R")"
[ "$count" = "1" ] \
  || gov_fail "a commit mixing product work with machine state raised $count baseline findings (expected 1) — bookkeeping became a cloak"

# ── 4. an unreadable pinned base FAILS CLOSED ──────────────────────────────────────────────────────
R="$(adopted_repo failclosed)" || gov_fail "could not seed an adopted repo"
python3 - "$R" <<'PY' || gov_fail "could not rewrite the pinned head"
import json, os, sys
path = os.path.join(sys.argv[1], "docs", "workflow", "reconciliation-adoption.json")
with open(path) as fh:
    doc = json.load(fh)
doc["default_branch"]["head"] = "0" * 40      # a base that resolves in no repository
with open(path, "w") as fh:
    json.dump(doc, fh)
PY
count="$(baseline_count "$R")"
[ "$count" = "1" ] \
  || gov_fail "an unresolvable pinned base raised $count baseline findings (expected 1) — the range check does not fail closed"

echo "PASS: adoption-bootstrap-fixpoint"
