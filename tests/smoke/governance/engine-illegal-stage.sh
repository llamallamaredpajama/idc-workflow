#!/bin/bash
# engine-illegal-stage.sh — governance scenario: a --stage outside the machine's declared `stages:`
# domain is rejected ENGINE-side, on BOTH backends.
#
# The gap this closes (PR #133 review): `stages:` was dead data — the engine never validated a
# create's --stage against it, and github create had no stage check at all (it relied on the fs
# backend's incidental validation, which github never runs). validate_target now calls
# check_stage_legal on both backends.
#
# Two halves, both red-when-broken:
#   (A) FILESYSTEM — `create-ticket --stage Bogus` is refused; no item written.
#   (B) GITHUB — in-process: E.run("create-ticket", github_ctx, stage="Bogus") raises AND never calls
#       idc_gh_board.create_item.
# Remove check_stage_legal from validate_target → both halves FAIL (github especially — it had none).
#
# Usage: bash tests/smoke/governance/engine-illegal-stage.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# ── (A) FILESYSTEM ──
if eng create-ticket --title 'x' --stage Bogus --status Todo 2>/dev/null; then
  fail "(A) create-ticket --stage Bogus succeeded (illegal Stage not rejected engine-side)"
fi
[ -z "$(gov_query "$T" --stage Recirculation)$(gov_query "$T" --status Todo)" ] || fail "(A) an item was written despite the illegal Stage"
echo "  ok (A) filesystem: create with an out-of-domain --stage is refused"

# ── (B) GITHUB (in-process — github has NO incidental fs validation to fall back on) ──
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "(B) github illegal-stage unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]   # a throwaway repo dir — keeps any journal write out of the plugin tree
import idc_transition as E
import idc_gh_board as B

calls = []
def fake_create_item(*a, **k):
    calls.append(a); return "PVTI_x"
orig = B.create_item
B.create_item = fake_create_item
try:
    ctx = E.github_ctx(repo, "o", "1")
    try:
        E.run("create-ticket", ctx, title="t", body="b", stage="Bogus")
        print("FAIL: github create-ticket --stage Bogus did not raise"); sys.exit(1)
    except E.TransitionError:
        pass
    assert not calls, "create_item WAS called with an illegal Stage (no engine-side stage check on github)"
    print("  ok (B) github: an out-of-domain --stage is refused before create_item is called")
finally:
    B.create_item = orig
PY

echo "PASS: an out-of-domain --stage is rejected engine-side on both backends (stages: is live data, not decoration)"
