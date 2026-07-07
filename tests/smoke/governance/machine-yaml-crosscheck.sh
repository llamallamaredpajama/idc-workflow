#!/bin/bash
# machine-yaml-crosscheck.sh — governance scenario: lint-references.sh's machine-yaml
# cross-check is honest.
#
# The gaps this closes (PR #147 review):
#   (1) Field-swapped values are rejected (Status: Buildable is a FAIL).
#   (2) The regex is line-oriented and does not miss multi-line blocks.
#   (3) The test lives in the smoke suite and is discovered by run-all.sh.
#
# Red-when-broken:
#   - Weaken the python script's validation to a union check -> (1) fails to fail.
#   - Use a multi-line regex in the python script -> (2) fails to fail.
#
# Usage: bash tests/smoke/governance/machine-yaml-crosscheck.sh (exit 0 = pass)
set -uo pipefail

# setup_governed_repo creates a temporary, clean copy of the entire plugin repo
# so that the linter can be run in an isolated environment.
# It sets GOV_TMP to the path of the temporary repo.
# It sets GOV_PLUGIN to the same path, as the linter expects to be run from the root.
setup_governed_repo() {
  local suite_name="$1"
  local tmp_base
  tmp_base="$(mktemp -d)"
  GOV_TMP="$tmp_base/$suite_name"
  
  # The plugin root is three levels up from this script's directory
  local plugin_root
  plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

  # Copy the entire plugin repository to the temp directory
  # Exclude .git and any worktrees to keep it clean and fast
  rsync -a --exclude ".git" --exclude ".worktrees" "$plugin_root/" "$GOV_TMP/"
  
  GOV_PLUGIN="$GOV_TMP"
  
  # Cleanup trap
  trap 'rm -rf "$tmp_base"' EXIT
}


. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

# Setup a temp repo copy to lint, so we can seed errors without touching the real tree.
setup_governed_repo "machine-yaml-crosscheck"
cd "$GOV_TMP"

LINTER="bash $GOV_PLUGIN/scripts/lint-references.sh"

echo "  (1) Seeding bogus references into a command file..."
# A file we know is scanned by the linter
TARGET_FILE="commands/doctor.md"
[ -f "$TARGET_FILE" ] || fail "Target file $TARGET_FILE for seeding errors not found."

# Save original content
original_content=$(cat "$TARGET_FILE")

# Restore file content on exit
trap 'printf "%s" "$original_content" > "$TARGET_FILE"' EXIT

# Seed all three error types from the review
cat >> "$TARGET_FILE" <<EOF

---
## BOGUS REFERENCES FOR TESTING

1. Unknown name:
   - Stage: Wibble

2. Field-swapped valid name:
   - Status: Buildable

3. Multiline block (should be ignored by line-oriented check, but let's add a bogus one inside too)
   \`\`\`yaml
   Stage: BogusStage
   Status: Planning
   \`\`\`

EOF

echo "  (2) Running linter on modified repo, expecting FAIL..."
if output=$($LINTER 2>&1); then
  fail "Linter PASSED on a tree with known bogus references. Output:\n$output"
fi

echo "$output" | grep -q "Invalid Stage reference: 'Wibble'" || fail "Linter did not report unknown stage 'Wibble'"
echo "$output" | grep -q "Invalid Status reference: 'Buildable'" || fail "Linter did not report field-swapped status 'Buildable'"
echo "$output" | grep -q "Invalid Stage reference: 'BogusStage'" || fail "Linter did not report unknown stage 'BogusStage' in yaml block"
echo "$output" | grep -q "Invalid Status reference: 'Planning'" || fail "Linter did not report field-swapped status 'Planning' in yaml block"
echo "    ok: linter failed as expected and reported the correct errors."


echo "  (3) Restoring original file and running linter, expecting PASS..."
printf "%s" "$original_content" > "$TARGET_FILE"

if ! output=$($LINTER 2>&1); then
  fail "Linter FAILED on a clean tree. Output:\n$output"
fi
echo "    ok: linter passed on the clean tree."


echo "PASS: machine-yaml cross-check correctly identifies invalid and field-swapped references."
