#!/bin/bash
# janitor-branch-attribution.sh — governance scenario: the git janitor attributes ALL IDC branch
# conventions, including the `recirc/<slug>` branches Recirculation now creates (Task 3, Fix 7).
#
# Recirculation requires `recirc/<slug>` branches (agents/idc-recirculator.md). If the janitor's
# IDC-branch recognition knows only `recirculate/*`, a leftover `recirc/*` branch is misclassified as
# a foreign/non-IDC branch → REPORT-ONLY, never safely cleanable. Red-when-broken: drop `recirc/` from
# IDC_NAME_RE → is_idc('recirc/heal-scope') is False → this FAILs.
#
# Usage: bash tests/smoke/governance/janitor-branch-attribution.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || gov_fail "janitor branch-attribution unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
import idc_git_janitor as J

idc = ["idc-x", "build-7", "build/7", "plan/decompose", "recirculate/legacy", "recirc/heal-scope",
       "worktree-build-9"]
for name in idc:
    assert J.is_idc(name), f"IDC branch {name!r} was NOT attributed to IDC"
# a foreign name that merely starts with the letters must still NOT be attributed.
for name in ["recirculator-tool", "buildbot", "codex/x", "feature/thing"]:
    assert not J.is_idc(name), f"foreign branch {name!r} was wrongly attributed to IDC"
print("  ok is_idc attributes recirc/* (and recirculate/*, plan/*, build*) while rejecting foreign names")
PY

echo "PASS: the git janitor attributes recirc/<slug> branches to IDC (cleanable), not to foreign tooling"
