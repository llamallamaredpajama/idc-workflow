#!/bin/bash
# idc-assert-class: behavior
# plan-stage-recipe-parses.sh — the SHIPPED Plan Stage-transition recipe in agents/idc-plan.md must
# PARSE against idc_transition.py's real CLI. `--repo` is a PARENT-parser flag, so it MUST precede the
# `move` subcommand (`idc_transition.py --repo R move --num N …`). The prior prose put `move` first and
# `--repo` after it → argparse exits 2 (`unrecognized arguments: --repo …`), so the documented recovery
# command never ran. engine-stage-move.sh only exercises the `eng` wrapper (which already orders --repo
# correctly), so it could not catch the broken PROSE. This runs the recipe AS WRITTEN.
#
# Red-when-broken: revert idc-plan.md to `… idc_transition.py move --repo …` (op before --repo) → the
# reconstructed recipe exits 2 and this scenario FAILs.
#
# Usage: bash tests/smoke/governance/plan-stage-recipe-parses.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

PLAN="$GOV_PLUGIN/agents/idc-plan.md"
[ -f "$PLAN" ] || fail "idc-plan.md not found at $PLAN"

# Seed a Consideration pointer the recipe would advance.
P="$(eng create-pointer --title 'pointer: recipe' | tail -1)" || fail "could not seed the pointer"
[ "$(gov_field "$T" "$P" Stage)" = "Consideration" ] || fail "seed pointer is not at Stage=Consideration"

echo "== the SHIPPED \`move --to-stage Planning\` recipe from idc-plan.md parses + runs AS WRITTEN =="
# Extract the shipped invocation (backslash-newline continuations joined), bind the documented
# placeholders to this hermetic repo, splice in the parent-parser backend/tracker flags right after
# the script path (where a parent flag legally goes), and RUN it. A recipe that places `move` before
# `--repo`/`--backend`/`--tracker` makes argparse reject them → non-zero exit → FAIL.
python3 - "$PLAN" "$GOV_PLUGIN" "$REPO" "$T" "$P" <<'PY' || fail "the shipped Stage recipe did not parse/run (see above) — is --repo placed AFTER the move subcommand?"
import re, shlex, subprocess, sys
plan, plugin, repo, tracker, num = sys.argv[1:6]
text = open(plan, encoding="utf-8").read().replace("\\\n", " ")   # join shell line-continuations
m = re.search(
    r'python3\s+"?\$\{CLAUDE_PLUGIN_ROOT\}/scripts/idc_transition\.py"?\s+([^\n`]*?--to-stage\s+Planning[^\n`]*)',
    text)
if not m:
    sys.exit("could not locate the shipped `move --to-stage Planning` recipe in idc-plan.md")
args = shlex.split(m.group(1))
subst = {"$PWD": repo, "<pointer>": str(num)}                     # documented placeholders
args = [subst.get(a, a) for a in args]
cmd = ["python3", f"{plugin}/scripts/idc_transition.py", *args]
cmd[2:2] = ["--backend", "filesystem", "--tracker", tracker]      # parent flags, after the script path
print("  recipe:", " ".join(cmd))
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit(f"recipe exited {r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}")
PY

# The recipe actually advanced the pointer Consideration -> Planning (it parsed AND executed).
[ "$(gov_field "$T" "$P" Stage)" = "Planning" ] \
  || fail "the shipped recipe parsed but did not land Stage=Planning (got $(gov_field "$T" "$P" Stage))"
echo "  ok the documented \`idc_transition.py --repo … move --to-stage Planning\` recipe parses and advances the pointer"

echo "PASS: the shipped Plan Stage-transition recipe places --repo before the move subcommand, so it parses against the real CLI and advances a Consideration pointer to Planning"
