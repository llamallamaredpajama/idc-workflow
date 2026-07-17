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

# The command-line writer is Doctor-only.  Janitor and Intake evidence must come
# from their own helpers, never from a generic caller-supplied --kind/JSON door.
if python3 "$REPORT" --cwd "$REPO" write --kind janitor --session report-test \
    --payload-json '{"scanner_exit":0}' >/dev/null 2>&1; then
  gov_fail "the removed generic report writer still accepts arbitrary non-Doctor payloads"
fi
[ -d "$REPO/.idc-janitor-report.json" ] \
  || gov_fail "the collision fixture changed shape instead of leaving the report absent"

SCRIPTS_DIR="$GOV_PLUGIN/scripts" python3 - "$REPO" <<'PY' \
  || gov_fail "write_janitor_report returned success for a failed atomic write"
import os, sys
sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"], "hooks"))
import idc_command_report as report

repo = sys.argv[1]
assert not hasattr(report, "write_report"), "the generic source-less report API must be removed"
assert report.write_janitor_report(
    repo, scanner_exit=0, session_id="report-test", nonce="nonce-report-test"
) is False
PY

# A real Intake helper owns its failure receipt and clears it after the same invocation succeeds.
IREPO="$WORK/intake-repo"; mkdir -p "$IREPO/docs/workflow"
printf 'backend: filesystem\n' > "$IREPO/docs/workflow/tracker-config.yaml"
IMAN="$IREPO/docs/workflow/intakes/2026-07-17-test.json"
if python3 "$GOV_PLUGIN/scripts/idc_intake_manifest.py" extract \
    --source "$IREPO/missing.md" --out "$IMAN" --goal test --plugin-version 4.1.2 \
    --report-repo "$IREPO" --report-session intake-report --report-nonce nonce-intake >/dev/null 2>&1; then
  gov_fail "the missing Intake source unexpectedly succeeded"
fi
python3 - "$IREPO/.idc-intake-failure-report.json" <<'PY' \
  || gov_fail "the Intake helper did not write its exact source-owned failure receipt"
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
p = r["payload"]
assert r["producer"] == p["helper"] == "idc_intake_manifest.py"
assert p["session_id"] == "intake-report" and p["nonce"] == "nonce-intake"
assert p["operation"] == "extract" and p["exit"] == 2 and p["diagnostic"].startswith("idc-intake: FAIL")
PY
mkdir -p "$(dirname "$IMAN")"; printf '## U0 — One unit\n\nDo the thing.\n' > "$IREPO/source.md"
python3 "$GOV_PLUGIN/scripts/idc_intake_manifest.py" extract \
  --source "$IREPO/source.md" --out "$IMAN" --goal test --plugin-version 4.1.2 \
  --report-repo "$IREPO" --report-session intake-report --report-nonce nonce-intake >/dev/null \
  || gov_fail "the Intake retry did not succeed"
[ ! -e "$IREPO/.idc-intake-failure-report.json" ] \
  || gov_fail "the successful Intake retry left its stale failure receipt behind"

echo "PASS: report writes are source-owned and return failure when the atomic write does not land"
