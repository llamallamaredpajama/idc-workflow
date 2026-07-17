#!/bin/bash
# idc-assert-class: behavior
# A report write may fail after the payload has passed validation (for example, the final target is
# not replaceable). The Python API and CLI must report that failure instead of claiming the report
# landed. This uses a real filesystem collision at the report path; no writer seam is mocked.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

REPORT="$GOV_PLUGIN/scripts/hooks/idc_command_report.py"
WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow" "$REPO/.idc-janitor-report.json"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"

if python3 "$REPORT" --cwd "$REPO" write --kind janitor --session report-test \
    --payload-json '{"scanner_exit":0}' >/dev/null 2>&1; then
  gov_fail "report CLI exited zero even though the atomic replace could not land"
fi
[ -d "$REPO/.idc-janitor-report.json" ] \
  || gov_fail "the collision fixture changed shape instead of leaving the report absent"

SCRIPTS_DIR="$GOV_PLUGIN/scripts" python3 - "$REPO" <<'PY' \
  || gov_fail "write_report returned success for a failed atomic write"
import os, sys
sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"], "hooks"))
import idc_command_report as report

repo = sys.argv[1]
assert report.write_report(repo, "janitor", {"scanner_exit": 0}, session_id="report-test") is False
PY

echo "PASS: command report writes return failure when the atomic write does not land"
