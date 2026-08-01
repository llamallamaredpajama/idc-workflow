#!/bin/bash
# idc-assert-class: behavior
# interlock-backstop-parity.sh — NEW-1: the interlock's tokenize-failure BACKSTOP must protect the
# SAME command set as its primary positional path.
#
# THE DEFECT THIS LANE LOCKS. `idc_interlock_gate._PROTECTED_COMBOS` lists every (noun, verb) the
# interlock denies. Segments that the shell lexer CAN parse are judged there. A segment it cannot
# parse — an unbalanced quote is enough — falls through to the whitespace-flexible text backstop
# `_ws_combos`, which was hand-written as a parallel list of `if` rules and had drifted NARROWER:
# 15 project verbs and 11 issue verbs were protected on the primary path, but the backstop knew only
# 11 and 6. `gh project item-archive`, `edit`, `copy`, `unlink` and `gh issue lock`, `unlock`,
# `transfer`, `pin`, `unpin` therefore degraded to a generic "could not be parsed" refusal the moment
# a quote was unbalanced, instead of naming the single write door. A reviewer asked for the alignment
# as a named follow-up and nobody owned it — because nothing anywhere compared the two lists.
#
# This lane is that comparison, derived from the shipped set rather than a copy of it: a verb added to
# `_PROTECTED_COMBOS` without a backstop rule turns this RED on the day it lands.
#
# ASSERTS:
#   1. CONTROL FIRST — the probe can tell a hit from a miss: a known-protected verb returns a finding
#      and a known READ returns None. Without this, "every verb is covered" could pass because the
#      probe always reported a hit.
#   2. Every (noun, verb) in _PROTECTED_COMBOS produces a backstop finding.
#   3. For each, the backstop's private `kind` EQUALS the kind the positional path assigns — an
#      aligned-but-mislabeled backstop would send the operator to the wrong remediation door.
#   4. End to end through the real hook: an UNLEXABLE form of each newly covered verb is DENIED and
#      the refusal names the single write door, not the generic unparseable message.
#
# Usage: bash tests/smoke/governance/interlock-backstop-parity.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$GATE" ]     || gov_fail "idc_interlock_gate.py not found at $GATE"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"

# --- 1-3. structural parity, read off the shipped module --------------------------------------
timeout 120 python3 - "$GOV_PLUGIN" <<'PY' || exit 1
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts"))
sys.path.insert(0, os.path.join(root, "scripts", "hooks"))
import idc_interlock_gate as IG

combos = sorted(IG._PROTECTED_COMBOS)
if not combos:
    raise SystemExit("FAIL: _PROTECTED_COMBOS is EMPTY — every assertion below would hold vacuously")

# 1. CONTROL: the probe distinguishes a hit from a miss.
if IG._ws_combos("gh issue create --title x") is None:
    raise SystemExit("FAIL: CONTROL — the backstop probe found nothing for a known-protected verb "
                     "(`gh issue create`), so it cannot detect coverage at all; this lane is INERT")
for read in ("gh issue view 5", "gh pr view 5", "gh project item-list 5 --owner o",
             "gh project field-list 5 --owner o"):
    if IG._ws_combos(read) is not None:
        raise SystemExit(f"FAIL: CONTROL — the backstop flagged a governed READ ({read!r}); it would "
                         "report 'covered' for anything and cannot prove parity")

# 2 + 3. every protected combo is covered, with the SAME kind the positional path assigns.
uncovered, mismatched = [], []
for noun, verb in combos:
    text = f"gh {noun} {verb} 5 --owner o"
    back = IG._ws_combos(text)
    primary = IG._combo_subject([noun, verb])
    if primary is None:
        raise SystemExit(f"FAIL: the positional path does not classify the protected combo "
                         f"({noun!r}, {verb!r}) — the two sets cannot be compared")
    if back is None:
        uncovered.append(f"gh {noun} {verb}")
        continue
    if back.kind != primary.kind:
        mismatched.append(f"gh {noun} {verb}: backstop kind {back.kind!r} != positional {primary.kind!r}")

if uncovered:
    raise SystemExit(
        "FAIL: the tokenize-failure backstop does not cover protected command(s) the positional path "
        f"denies: {uncovered}. An unlexable segment naming one of these degrades to the generic "
        "'could not be parsed' refusal instead of naming the single write door. Add a rule to "
        "_ws_combos for each.")
if mismatched:
    raise SystemExit("FAIL: backstop/positional remediation kinds disagree: " + "; ".join(mismatched))

print(f"ok: all {len(combos)} protected gh combos are covered by the tokenize-failure backstop with "
      "matching remediation kinds")
PY

# --- 4. behavioral: an UNLEXABLE form of each newly covered verb denies through the real hook ------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"

SID="ws-parity-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SID" --command think \
  --plugin-root "$GOV_PLUGIN" --args 'backstop-parity' --source user >/dev/null \
  || gov_fail "could not open the active /idc:think command record for $SID"

ERR="$WORK/err"
gate() { # $1 = command text
  OUT="$(CMD="$1" SID="$SID" REPO="$REPO" python3 - <<'PY' | timeout 60 python3 "$GATE" 2>"$ERR"
import json, os
print(json.dumps({"session_id": os.environ["SID"], "cwd": os.environ["REPO"],
                  "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": os.environ["CMD"]}}))
PY
)"
  RC=$?
}

# The unlexable form: a trailing unbalanced double quote makes shlex fail, forcing the text backstop.
deny_unlexable() { # $1 = label, $2 = command text (must be unlexable)
  gate "$2"
  [ "$RC" -eq 0 ] || gov_fail "$1: gate exited $RC (a hook signals via JSON, not the exit code): $(cat "$ERR")"
  printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"' \
    || gov_fail "$1: an unlexable [$2] was NOT denied by the backstop: stdout=[$OUT] stderr=[$(cat "$ERR")]"
  printf '%s' "$OUT" | grep -q 'idc_transition.py' \
    || gov_fail "$1: the backstop denied but did not name the single write door — it fell through to the generic unparseable refusal: [$OUT]"
  echo "  ok backstop deny + write-door remediation: $1"
}

echo "== newly covered gh project verbs deny through the tokenize-failure backstop =="
deny_unlexable 'project item-archive' 'gh project item-archive 8 --owner o --id "PVTI_X'
deny_unlexable 'project edit'         'gh project edit 5 --owner o --title "y'
deny_unlexable 'project copy'         'gh project copy 5 --source-owner o --target-owner "p'
deny_unlexable 'project unlink'       'gh project unlink 5 --owner o --repo "o/r'

echo "== newly covered gh issue verbs deny through the tokenize-failure backstop =="
deny_unlexable 'issue lock'     'gh issue lock 5 --reason "spam'
deny_unlexable 'issue unlock'   'gh issue unlock 5 --repo "o/r'
deny_unlexable 'issue transfer' 'gh issue transfer 5 "o/r'
deny_unlexable 'issue pin'      'gh issue pin 5 --repo "o/r'
deny_unlexable 'issue unpin'    'gh issue unpin 5 --repo "o/r'

echo "== the backstop did not widen into READS =="
# An unlexable segment is denied either way — the Path Gate fails closed on any command whose targets
# it cannot prove — so "was it denied?" cannot distinguish a widened backstop here. The distinguishing
# fact is WHICH refusal speaks: a READ must get the generic unparseable message, never the backstop's
# single-write-door remediation. (A LEXABLE read is the plain-allow control, asserted below.)
gate 'gh project item-list 5 --owner "o'
printf '%s' "$OUT" | grep -q 'idc_transition.py' \
  && gov_fail "an unlexable governed READ drew the backstop's WRITE-DOOR refusal — the backstop widened past the protected set: [$OUT]"
echo "  ok: unlexable gh project item-list falls to the generic unparseable refusal, not the backstop"
gate 'gh project item-list 5 --owner o'
printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"' \
  && gov_fail "a LEXABLE governed read (gh project item-list) was denied: [$OUT]"
echo "  ok allow: lexable gh project item-list"

echo "PASS: the interlock's tokenize-failure backstop protects the SAME command set as its positional path, with matching remediation kinds, and the nine previously-missing gh project/issue verbs now deny (naming the single write door) while governed reads stay allowed"
