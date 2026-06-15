#!/bin/bash
# Phase 7 (file-command quiet/no-op default) smoke — testing-suite-overhaul.
#
# THE 2.1.3 CATCH. The bad update UX shipped because tests used BLANK inputs and only checked "no
# data lost," never "behaves quietly on a real, already-correct project." This test runs the
# file-changing commands' deterministic decision helpers against a REALISTIC, already-set-up repo
# (filled configs) and asserts the non-destructive / quiet default: when the project is already
# correct, nothing is changed and no keep/replace prompt is raised. Also covers the cross-version
# (older-schema) upgrade — which advises, but still never overwrites. Hermetic; no GitHub.
#
# Usage: bash tests/smoke/phase7-file-commands-noop-default.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
. "$PLUGIN/tests/smoke/lib/realistic-repo.sh"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

added_for() {  # dest -> structural keys the rendered template adds over the on-disk file
  local repo="$1" dest="$2"
  local tmpl rendered
  tmpl="$(python3 "$PLUGIN/scripts/idc_template_for.py" --plugin-root "$PLUGIN" "$dest")" || return 2
  rendered="$(mktemp)"
  sed -e 's/{{PROJECT_NAME}}/RealProj/g' -e 's/{{TRACKER_PROJECT_NUMBER}}/7/g' "$tmpl" > "$rendered"
  python3 "$PLUGIN/scripts/idc_config_keys.py" --added "$repo/$dest" "$rendered"
  rm -f "$rendered"
}
in_always_ask() {  # repo, dest -> 0 if dest is in verify --json always_ask
  python3 "$PLUGIN/scripts/idc_receipt_check.py" verify --repo "$1" --json 2>/dev/null \
    | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in set(json.load(sys.stdin).get("always_ask",[])) else 1)' "$2"
}
advisory_for_extra_key() {  # repo, dest, newkey -> the keys added when the template gains `newkey`
  # The mirror of added_for: render the REAL shipped template, then append ONE extra top-level key to
  # the rendered COPY (never the shipped template on disk) and diff the on-disk file against it. This
  # makes the quiet-default assertion FALSIFIABLE — added_for() alone is tautological because the
  # fixture scaffolds the on-disk config FROM the same template, so it is empty by construction; only
  # an *injected* new key proves the advisory path actually fires when the template gains structure.
  local repo="$1" dest="$2" newkey="$3"
  local tmpl rendered
  tmpl="$(python3 "$PLUGIN/scripts/idc_template_for.py" --plugin-root "$PLUGIN" "$dest")" || return 2
  rendered="$(mktemp)"
  sed -e 's/{{PROJECT_NAME}}/RealProj/g' -e 's/{{TRACKER_PROJECT_NUMBER}}/7/g' "$tmpl" > "$rendered"
  printf '%s: injected\n' "$newkey" >> "$rendered"
  python3 "$PLUGIN/scripts/idc_config_keys.py" --added "$repo/$dest" "$rendered"
  rm -f "$rendered"
}

# ============ REALISTIC, already-current repo ============
R="$SBX/current"; make_realistic_repo "$R" || fail "could not build realistic repo"
WC="$R/WORKFLOW-config.yaml"; TC="$R/docs/workflow/tracker-config.yaml"

# UPDATE quiet default: the data configs are already structurally current vs the shipped templates,
# so the structure check adds NOTHING (no advisory) — update reports 'preserved — config current'
# and raises no prompt. (This is the exact assertion missing in 2.1.3.)
[ -z "$(added_for "$R" WORKFLOW-config.yaml)" ] \
  || fail "update would raise an advisory on an already-current WORKFLOW-config.yaml — not quiet"
[ -z "$(added_for "$R" docs/workflow/tracker-config.yaml)" ] \
  || fail "update would raise an advisory on an already-current tracker-config.yaml — not quiet"

# ...but the advisory path MUST fire when the template genuinely gains structure — otherwise the
# "quiet" assertion above is a constant (the fixture's on-disk config is scaffolded from the same
# template, so added_for is empty by construction). Prove the other direction: a template with ONE
# extra key surfaces exactly that key, so "quiet when current, advise when the template grew" is a
# real, breakable assertion, not a tautology.
[ "$(advisory_for_extra_key "$R" WORKFLOW-config.yaml zzz_new_struct)" = "zzz_new_struct" ] \
  || fail "update did NOT surface a genuinely new template key on WORKFLOW-config.yaml — quiet default is a tautology, not a real assertion"
[ "$(advisory_for_extra_key "$R" docs/workflow/tracker-config.yaml zzz_new_struct)" = "zzz_new_struct" ] \
  || fail "update did NOT surface a genuinely new template key on tracker-config.yaml — quiet default is a tautology"

# UPDATE never silently overwrites the data configs (always_ask guard holds for a real repo).
in_always_ask "$R" WORKFLOW-config.yaml || fail "WORKFLOW-config.yaml must be in always_ask"
in_always_ask "$R" docs/workflow/tracker-config.yaml || fail "tracker-config.yaml must be in always_ask"

# INIT quiet default (idempotent): re-running the scaffold on the populated repo changes NOTHING —
# never clobbers operator data.
before="$(shasum -a 256 "$WC" "$TC" | awk '{print $1}')"
bash "$PLUGIN/scripts/idc_init_scaffold.sh" "$PLUGIN" "$R" "RealProj" github >/dev/null \
  || fail "re-scaffold exited non-zero"
[ "$before" = "$(shasum -a 256 "$WC" "$TC" | awk '{print $1}')" ] \
  || fail "init re-scaffold clobbered an existing config — not idempotent"

# UNINSTALL non-destructive default: the data configs are state: customized, so uninstall ask-keeps
# them (never silently deletes operator data).
state_of() { awk -v p="path: $1" 'index($0,p){f=1} f&&/state:/{print $2; exit}' "$R/docs/workflow/install-receipt.yaml"; }
[ "$(state_of WORKFLOW-config.yaml)" = customized ] \
  || fail "uninstall would not ask-keep WORKFLOW-config.yaml (state '$(state_of WORKFLOW-config.yaml)')"
[ "$(state_of docs/workflow/tracker-config.yaml)" = customized ] \
  || fail "uninstall would not ask-keep tracker-config.yaml"

# ============ LEGACY (older-schema) repo — cross-version upgrade stays non-destructive ============
L="$SBX/legacy"; make_legacy_repo "$L" || fail "could not build legacy repo"

# The older tracker-config lacks Stage; update ADVISES the new field — but it's an advisory, never an
# overwrite, and the data config is still protected by always_ask despite its state: stamped receipt.
printf '%s\n' "$(added_for "$L" docs/workflow/tracker-config.yaml)" | grep -qx 'field_ids.Stage' \
  || fail "legacy upgrade must surface new field_ids.Stage as an advisory"
in_always_ask "$L" docs/workflow/tracker-config.yaml \
  || fail "legacy data config must still be in always_ask despite state: stamped"

echo "PASS: file-changing commands stay quiet/non-destructive on a realistic repo (current + legacy upgrade)"
