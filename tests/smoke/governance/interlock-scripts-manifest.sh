#!/bin/bash
# idc-assert-class: mixed
# interlock-scripts-manifest.sh — #192: the interlock's Rule 5 exemption is a PINNED MANIFEST of
# the scripts the plugin ships, kept in lockstep with the shipped tree, and the manifest — not the
# directory — is what decides sanctioning.
#
# THE DEFECT THIS LANE LOCKS. The old Rule 5 returned `[]` — unscanned — for ANY file whose
# resolved path lay under `<plugin_root>/scripts/`. That blanket prefix let an agent drop a helper
# script into that directory (a location the Path Gate deliberately treats as outside its
# jurisdiction) and run `gh pr merge` / `gh issue close` past the deny gate. #192 replaced the
# prefix with `_SHIPPED_SCRIPTS`, a manifest pinned INSIDE the gate. Two failure modes remain, and
# each half of this lane holds one shut:
#   1. DRIFT. A script added to (or removed from) `scripts/` without updating the manifest makes
#      the gate deny a genuinely shipped helper (a sanctioned-path regression) or keep sanctioning
#      a deleted name an agent could reuse. Section 1 compares the pinned set against the shipped
#      tree file-by-file and names every difference.
#   2. MECHANISM. The manifest must be what the gate actually consults: a NON-manifest name under
#      scripts/ is scanned (and its protected body denied), while a manifest name stays sanctioned.
#      Section 2 probes both through the real PreToolUse hook — the same body under both names, so
#      the NAME alone decides.
#
# Red-when-broken: revert Rule 5 to the blanket dir-prefix → the non-manifest probe stops denying →
# section 2 FAILs (and deleting a manifest entry without touching scripts/ turns section 1 red).
#
# Usage: bash tests/smoke/governance/interlock-scripts-manifest.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
RUNTIME="$GOV_PLUGIN/scripts/idc_python_runtime.sh"
[ -f "$GATE" ] || gov_fail "interlock gate not found at $GATE"
[ -f "$RUNTIME" ] || gov_fail "shared runtime preflight not found at $RUNTIME"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- 1. lockstep: the pinned manifest equals the shipped scripts tree ------------------------------
# The manifest is read out of the module SOURCE via ast (no import), so this half runs on any
# interpreter that can parse the file — it must never skip, because drift is a source defect.
# The shipped tree is the git-tracked listing when available (a checkout/worktree), else the
# directory walk minus interpreter droppings (__pycache__/*.pyc/.DS_Store).
SHIPPED="$WORK/shipped.txt"
if git -C "$GOV_PLUGIN" ls-files scripts 2>/dev/null | sed 's|^scripts/||' | grep -q .; then
  git -C "$GOV_PLUGIN" ls-files scripts | sed 's|^scripts/||' | LC_ALL=C sort > "$SHIPPED"
else
  ( cd "$GOV_PLUGIN/scripts" && find . -type f \
      ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '.DS_Store' \
      | sed 's|^\./||' | LC_ALL=C sort ) > "$SHIPPED"
fi
[ -s "$SHIPPED" ] || gov_fail "could not enumerate the shipped scripts tree under $GOV_PLUGIN/scripts"

timeout 60 python3 - "$GATE" "$SHIPPED" <<'PY' || gov_fail "the pinned _SHIPPED_SCRIPTS manifest has drifted from the shipped scripts tree — update the manifest in scripts/hooks/idc_interlock_gate.py in the SAME commit that adds/removes a script (a missing entry makes the gate deny a shipped helper; a stale entry keeps sanctioning a deleted name)"
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
manifest = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "_SHIPPED_SCRIPTS" for t in node.targets):
        manifest = set(ast.literal_eval(node.value.args[0]))
assert manifest, "no _SHIPPED_SCRIPTS assignment found in the gate module (the Rule 5 manifest is gone)"
shipped = {line.strip() for line in open(sys.argv[2], encoding="utf-8") if line.strip()}
missing = sorted(shipped - manifest)   # shipped but not pinned → the gate would scan/deny a real helper
stale = sorted(manifest - shipped)     # pinned but not shipped → a reusable sanctioned name
assert not missing and not stale, (
    "manifest drift — shipped-but-unpinned: %s; pinned-but-unshipped: %s" % (missing, stale))
print("ok: _SHIPPED_SCRIPTS matches the shipped scripts tree (%d entries)" % len(manifest))
PY

# --- 2. mechanism: the manifest, not the directory, decides sanctioning ----------------------------
# Executing the gate needs the 3.10 runtime; on an older ambient python3 every probe would read as
# "allow" and this half would false-pass, so it SKIPS loudly instead (same posture as
# path-gate-runtime-failclosed.sh). Section 1 ran either way.
if ! sh "$RUNTIME"; then
  echo "SKIP: the ambient python3 ($(python3 --version 2>&1)) predates 3.10, so the interlock gate cannot be executed here. Section 1 (manifest lockstep) DID run and passed; section 2 (deny/allow mechanism) is skipped."
  echo "PASS: _SHIPPED_SCRIPTS matches the shipped tree (mechanism probes skipped — runtime below floor)"
  exit 0
fi

REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"
( cd "$REPO" && git init -q && git checkout -q -b main ) || gov_fail "could not init the fixture repo"
printf 'backend: github\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: app-locked\n' > "$REPO/WORKFLOW-config.yaml"

# A stand-in plugin root: the SAME protected body under a non-manifest name and a manifest name.
FAKE_ROOT="$WORK/plugin"
mkdir -p "$FAKE_ROOT/scripts"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/scripts/dropped_helper.sh"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/scripts/idc_init_scaffold.sh"

verdict() {
  local cmd="$1" json
  json="$(CMD="$cmd" REPO="$REPO" timeout 60 python3 -c '
import json, os
print(json.dumps({"cwd": os.environ["REPO"], "tool_name": "Bash", "session_id": "scripts-manifest",
                  "tool_input": {"command": os.environ["CMD"]}}))')"
  if printf '%s' "$json" | timeout 60 python3 "$GATE" "$FAKE_ROOT" 2>/dev/null \
      | grep -q '"permissionDecision" *: *"deny"'; then echo deny; else echo allow; fi
}

# CONTROL: the gate is enforcing at all (an inline protected write denies in app-locked mode).
[ "$(verdict 'gh pr merge 123 --squash')" = deny ] \
  || gov_fail "the control (inline gh pr merge, app-locked) was NOT denied — a gate that denies nothing makes every probe below meaningless"
# A NON-manifest file under <plugin_root>/scripts/ is scanned like any other target → its body denies.
[ "$(verdict "bash '$FAKE_ROOT/scripts/dropped_helper.sh'")" = deny ] \
  || gov_fail "a non-manifest helper under the plugin's scripts/ dir was NOT denied — Rule 5 has regressed to the blanket dir-prefix exemption (#192)"
# The SAME body under a shipped-manifest name stays sanctioned → the NAME alone discriminated.
[ "$(verdict "bash '$FAKE_ROOT/scripts/idc_init_scaffold.sh'")" = allow ] \
  || gov_fail "a shipped-manifest script name was DENIED — the Rule 5 manifest exemption stopped admitting the plugin's own helpers (sanctioned-path regression)"
# And the REAL shipped helper in the REAL plugin root stays runnable through the gate.
OUTJSON="$(CMD="bash '$GOV_PLUGIN/scripts/lint-references.sh'" REPO="$REPO" timeout 60 python3 -c '
import json, os
print(json.dumps({"cwd": os.environ["REPO"], "tool_name": "Bash", "session_id": "scripts-manifest",
                  "tool_input": {"command": os.environ["CMD"]}}))' \
  | timeout 60 python3 "$GATE" "$GOV_PLUGIN" 2>/dev/null)"
printf '%s' "$OUTJSON" | grep -q '"permissionDecision" *: *"deny"' \
  && gov_fail "the real shipped lint-references.sh was DENIED under the real plugin root — the manifest does not admit the plugin's own scripts"

echo "PASS: _SHIPPED_SCRIPTS matches the shipped scripts tree, a non-manifest file under scripts/ is scanned and denied, the same body under a manifest name stays sanctioned, and the real shipped helper passes the gate"
