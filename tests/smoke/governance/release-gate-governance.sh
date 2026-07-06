#!/bin/bash
# idc-assert-class: behavior
# release-gate-governance.sh — verifies that `idc_release_check.py --governance` correctly
# runs the governance lane and reports its success/failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
. "$HERE/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

# Test harness helpers
expect_pass() { "$@" || fail "expected command to succeed: $*"; }
expect_fail() { "$@" && fail "expected command to FAIL but it succeeded: $*"; return 0; }

# Setup a temporary, isolated governance lane to avoid recursion.
# The python script will read from this directory if IDC_OVERRIDE_GOVERNANCE_LANE_DIR is set.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ISOLATED_LANE="$WORK/governance"
mkdir -p "$ISOLATED_LANE"
cp "$HERE/lib.sh" "$ISOLATED_LANE/"
# The python script requires the self-check to exist. A simple passing one is enough for this test.
printf '#!/bin/bash\nexit 0\n' > "$ISOLATED_LANE/_lane-selfcheck.sh"
chmod +x "$ISOLATED_LANE/_lane-selfcheck.sh"

PY_SCRIPT="$REPO_ROOT/scripts/idc_release_check.py"

# --- Test Case 1: Lane fails when a test fails ---
echo "INFO: Seeding a failing test in the isolated lane..."
cat > "$ISOLATED_LANE/seeded_fail.sh" <<'EOF'
#!/bin/bash
echo "This is the seeded failure."
exit 1
EOF
chmod +x "$ISOLATED_LANE/seeded_fail.sh"

echo "INFO: Verifying that --governance exits non-zero when the lane is red..."
export IDC_OVERRIDE_GOVERNANCE_LANE_DIR="$ISOLATED_LANE"
# This is the TDD failure point: the `--governance` flag doesn't exist yet.
expect_fail python3 "$PY_SCRIPT" --governance

# --- Test Case 2: Lane passes when all tests pass ---
echo "INFO: Removing failing test..."
rm "$ISOLATED_LANE/seeded_fail.sh"

echo "INFO: Verifying that --governance exits zero when the lane is green..."
export IDC_OVERRIDE_GOVERNANCE_LANE_DIR="$ISOLATED_LANE"
expect_pass python3 "$PY_SCRIPT" --governance

# --- Test Case 3: Default behavior is unchanged ---
echo "INFO: Verifying that default behavior (no flag) is a silent, quick pass..."
# Unset the override to ensure it's not looking at our test lane
unset IDC_OVERRIDE_GOVERNANCE_LANE_DIR
# This command should succeed quickly. We can time it.
# It should also not print anything about governance.
output=$( (time python3 "$PY_SCRIPT") 2>&1 )
exit_code=$?
[ $exit_code -eq 0 ] || fail "Default behavior failed with exit code $exit_code. Output: $output"
echo "$output" | grep -q "governance" && fail "Default behavior should not mention governance. Output: $output"
echo "$output" | grep -q "FAIL" && fail "Default behavior should not fail. Output: $output"

echo "PASS: release-gate-governance.sh"
