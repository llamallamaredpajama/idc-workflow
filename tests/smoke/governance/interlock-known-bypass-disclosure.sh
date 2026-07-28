#!/bin/bash
# idc-assert-class: mixed
# interlock-known-bypass-disclosure.sh — F58: the interlock's PUBLISHED scope matches what it
# actually classifies. Two demonstrated channels are outside its reach; both are disclosed, and this
# lane keeps the disclosure and the behavior from drifting apart in EITHER direction.
#
# WHY A DISCLOSURE LANE AND NOT A FIX. Both channels are pre-existing (they behave identically on
# `main`) and both sit on load-bearing exemptions:
#   1. any file resolving under `<plugin_root>/scripts/` is deliberately UNSCANNED — that exemption is
#      what stops IDC's own `gh`-calling helpers from being denied by their own gate — and the Path
#      Gate treats out-of-repository paths as outside its jurisdiction (a deliberate boundary locked
#      by path-gate-boundaries.sh), so the write that plants the payload is not stoppable either;
#   2. the classifier is a text scanner, so a protected call built as an argv LIST rather than a
#      command string carries no matching text.
# Narrowing either one (a hash-pinned script manifest; treating interpreter payloads as opaque) is a
# design change with real blast radius on the sanctioned path. It is parked as a follow-up. What is
# NOT acceptable is shipping a gate whose published description implies coverage it does not have —
# so the scope is stated in both operator-facing surfaces, and asserted here.
#
# THIS LANE IS NOT A BUG LOCK-IN. It never asserts "the bypass must keep working". It asserts that
# the DISCLOSURE and the BEHAVIOR agree. If a later change closes a channel, this lane goes red with
# an explicit instruction to delete that channel from the disclosure — the gap closing must be
# accompanied by the published scope widening, in the same commit.
#
# What it proves:
#   A. hooks.json's operator-facing description names both channels as known non-coverage;
#   B. the gate module's own docstring names both, and says they are pre-existing follow-ups;
#   C. the control still denies — the gate genuinely enforces in app-locked mode, so a "pass" here
#      can never come from a gate that denies nothing;
#   D. reality matches the disclosure: each disclosed channel is in fact still uncovered (and if one
#      becomes covered, this fails LOUDLY telling you to update the disclosure).
#
# Usage: bash tests/smoke/governance/interlock-known-bypass-disclosure.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
HOOKS="$GOV_PLUGIN/hooks/hooks.json"
[ -f "$GATE" ] || gov_fail "interlock gate not found at $GATE"
[ -f "$HOOKS" ] || gov_fail "hooks.json not found at $HOOKS"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- A. the operator-facing description discloses both channels -----------------------------------
timeout 60 python3 - "$HOOKS" <<'PY' || gov_fail "hooks.json does not disclose the interlock's known non-coverage"
import json, re, sys
description = json.load(open(sys.argv[1], encoding="utf-8"))["description"]
assert "KNOWN NON-COVERAGE" in description, "no known-non-coverage section in the hooks description"
assert re.search(r"scripts/`? directory is deliberately NOT scanned|sanctioned plugin scripts", description, re.I), \
    "the sanctioned-plugin-scripts channel is not disclosed"
assert re.search(r"argv[- ]list", description, re.I), "the argv-list interpreter channel is not disclosed"
assert re.search(r"out[- ]of[- ]repository paths", description, re.I), \
    "the disclosure omits the jurisdiction half that makes channel 1 reachable"
print("ok: hooks.json discloses both known channels")
PY

# --- B. the module's own docstring discloses them, and scopes them honestly -----------------------
timeout 60 python3 - "$GATE" <<'PY' || gov_fail "the interlock gate docstring does not publish its known non-coverage"
import ast, re, sys
doc = ast.get_docstring(ast.parse(open(sys.argv[1], encoding="utf-8").read())) or ""
assert "KNOWN NON-COVERAGE" in doc, "the gate docstring publishes no non-coverage section"
assert re.search(r"SANCTIONED PLUGIN SCRIPTS", doc), "channel 1 is not named in the docstring"
assert re.search(r"ARGV-LIST INTERPRETER PAYLOADS", doc), "channel 2 is not named in the docstring"
assert re.search(r"pre-existing", doc, re.I), "the docstring does not scope the channels as pre-existing"
assert re.search(r"path-gate-boundaries", doc), \
    "the docstring does not point at the test that locks the jurisdiction boundary"
print("ok: the gate docstring publishes both channels with honest scoping")
PY

# --- fixture: a governed, app-locked repo with no authorization -----------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"
( cd "$REPO" && git init -q && git checkout -q -b main ) || gov_fail "could not init the fixture repo"
printf 'backend: github\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: app-locked\n' > "$REPO/WORKFLOW-config.yaml"

# A stand-in plugin root, so the sanctioned-scripts probe never writes into the real checkout.
FAKE_ROOT="$WORK/plugin"
mkdir -p "$FAKE_ROOT/scripts"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/scripts/payload.sh"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/outside.sh"

# verdict <command> -> "deny" | "allow"
verdict() {
  local cmd="$1" json
  json="$(CMD="$cmd" REPO="$REPO" timeout 60 python3 -c '
import json, os
print(json.dumps({"cwd": os.environ["REPO"], "tool_name": "Bash", "session_id": "f58-disclosure",
                  "tool_input": {"command": os.environ["CMD"]}}))')"
  if printf '%s' "$json" | timeout 60 python3 "$GATE" "$FAKE_ROOT" 2>/dev/null \
      | grep -q '"permissionDecision" *: *"deny"'; then echo deny; else echo allow; fi
}

# --- C. control — the gate really is enforcing in this fixture ------------------------------------
[ "$(verdict 'gh pr merge 123 --squash')" = deny ] \
  || gov_fail "the control (inline gh pr merge, app-locked, no authorization) was NOT denied — this lane cannot distinguish a disclosed gap from a gate that denies nothing"
[ "$(verdict "bash '$FAKE_ROOT/outside.sh'")" = deny ] \
  || gov_fail "indirection through a script OUTSIDE the plugin's scripts/ dir was not denied — the indirection classifier itself has regressed, which is not a disclosed gap"

# --- D. reality matches the disclosure ------------------------------------------------------------
if [ "$(verdict "bash '$FAKE_ROOT/scripts/payload.sh'")" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: the sanctioned-plugin-scripts channel is now COVERED. Delete channel 1 from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion — a closed gap must never stay published as an open one."
fi
if [ "$(verdict 'python3 -c '"'"'import subprocess; subprocess.run(["gh","pr","merge","123"])'"'"'')" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: the argv-list interpreter channel is now COVERED. Delete channel 2 from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion."
fi

# The text-form sibling of channel 2 must stay COVERED — the disclosure is scoped to argv lists only,
# and this is what keeps that scoping honest rather than a blanket interpreter excuse.
[ "$(verdict 'python3 -c '"'"'import os; os.system("gh pr merge 123 --squash")'"'"'')" = deny ] \
  || gov_fail "a text-form interpreter payload (os.system with the call as a string) was NOT denied — the disclosure claims only the ARGV-LIST form is unseen, so this widens undisclosed non-coverage"

echo "PASS: the interlock publishes its two known uncovered channels in both operator-facing surfaces, still denies the control and the text-form interpreter payload, and the disclosure matches observed behavior (this lane reds if either the disclosure or the gap disappears)"
