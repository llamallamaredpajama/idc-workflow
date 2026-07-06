#!/bin/bash
set -euo pipefail

# Test that lint-references.sh catches invalid workflow references in markdown files.

# Create a temporary directory for our test files to be linted.
# This ensures we don't lint the whole repo, which might have other errors.
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Create a fake command file with a bogus workflow stage reference
BOGUS_FILE="$TEST_DIR/bogus-command.md"
cat > "$BOGUS_FILE" <<EOF
# Bogus Command

A command that references a workflow stage that does not exist.

\`\`\`yaml
Stage: BogusStage
\`\`\`

We expect the linter to fail on this file.
EOF

# Find the repo root from the script's location
REPO_ROOT="$(git rev-parse --show-toplevel)"
LINTER_SCRIPT="$REPO_ROOT/scripts/lint-references.sh"

echo "Running linter on a file with a bogus workflow reference..."

# Run the linter on our specific test directory.
# We expect this to fail once the feature is implemented.
# In this "red" commit, we expect it to PASS, which means our test should FAIL.
if bash "$LINTER_SCRIPT" "$TEST_DIR"; then
  echo "Linter PASSED, but it should have FAILED. This is the 'red' state."
  echo "The cross-check for machine-yaml references is missing."
  exit 1 # Fail the test
else
  echo "Linter FAILED as expected. The cross-check is working."
  exit 0 # Pass the test
fi
