#!/bin/bash
# engine-create-cannot-mint-terminal.sh — governance scenario: a create op can NEVER mint a terminal
# Status (Done). The ONLY path to Done is a guarded `close`.
#
# The gap this closes (PR #133 review BLOCKER-1): `create-ticket --status Done` produced a
# Buildable/Done item with no verdict, rc=0. The engine now runs every create through validate_target,
# which refuses the terminal Status on BOTH backends (fs AND github) BEFORE any write.
#
# Two halves, both red-when-broken:
#   (A) FILESYSTEM — `create-ticket --status Done` (and --stage Recirculation --status "In Progress")
#       are refused via the CLI; no item is written.
#   (B) GITHUB — in-process: E.run("create-ticket", github_ctx, status="Done") raises AND never calls
#       the atomic idc_gh_board.create_item primitive (the refusal is BEFORE the write).
# Remove refuse_terminal from validate_target → both halves FAIL.
#
# Usage: bash tests/smoke/governance/engine-create-cannot-mint-terminal.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# ── (A) FILESYSTEM: create cannot mint Done, and nothing is written ──
if eng create-ticket --title 'sneaky' --status Done 2>/dev/null; then
  fail "(A) create-ticket --status Done succeeded (minted a terminal Status with no verdict)"
fi
[ -z "$(gov_query "$T" --status Done)" ] || fail "(A) a Done item was written despite the refusal"
echo "  ok (A1) filesystem: create-ticket --status Done is refused (no item written)"
# And create cannot mint a worked state on a non-build Stage either (validate_target is one gate).
if eng create-pointer --title 'p' --stage Recirculation --status "In Progress" 2>/dev/null; then
  fail "(A) create-pointer minted In Progress on a Recirculation Stage (worked-state gate bypassed)"
fi
echo "  ok (A2) filesystem: create cannot mint a worked Status on a non-build Stage"

# ── (B) GITHUB: the same gate, in-process, must fire BEFORE the atomic create primitive ──
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "(B) github create-terminal unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]   # a throwaway repo dir — keeps any journal write out of the plugin tree
import idc_transition as E
import idc_gh_board as B

calls = []
def fake_create_item(*a, **k):
    calls.append(a)
    return "PVTI_x"
orig = B.create_item
B.create_item = fake_create_item
try:
    ctx = E.github_ctx(repo, "o", "1")   # loads the bundled machine table
    try:
        E.run("create-ticket", ctx, title="t", body="b", status="Done")
        print("FAIL: github create-ticket --status Done did not raise"); sys.exit(1)
    except E.TransitionError:
        pass
    assert not calls, "create_item WAS called — the terminal refusal fired AFTER the write, not before"
    print("  ok (B) github: create-ticket --status Done is refused before create_item is ever called")
finally:
    B.create_item = orig
PY

echo "PASS: no create op mints a terminal Status on either backend — the only path to Done is a guarded close"
