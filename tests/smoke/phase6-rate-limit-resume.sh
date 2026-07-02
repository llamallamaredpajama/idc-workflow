#!/bin/bash
# idc-assert-class: mixed
# Phase 6 (rate-limit RESUME) smoke — the resumable-pause CONSUMER (issue #99 RESPONSE half, §C.3).
#
# ROOT CAUSE this guards: Unit 1's `idc_gh_board.py` already detects an exhausted GraphQL quota and
# raises `RateLimitError` (the machine-readable `rate-limited until <reset>` verdict, exit 3) — but
# nothing downstream consumed it as a resumable pause. Before this unit, `idc_autorun_drain.py`'s
# github loader caught EVERY `BoardReadError` (RateLimitError is a subclass) the SAME way — a bare
# exit 2, indistinguishable from a hard error — so autorun could not tell "GitHub's quota resets at
# <reset>, resume then" from "the board read is broken, investigate." The fix (this unit): the drain's
# github loader catches `RateLimitError` FIRST and emits a DISTINCT verdict `drain: rate-limited until
# <reset>` on exit 3 (mirrors `idc_gh_board`'s own 0/2/3 convention), so `/loop` treats it as
# pause-and-resume instead of a silent drop or a false `drain: complete`. `commands/autorun.md`
# documents the consuming behavior: pause (never drop, never report drained), re-check next `/loop`,
# and post-reset re-verify any in-flight finish via `idc_git_finish.py`'s end-state check.
#
# Hermetic: no live GitHub — a mode-switched PATH `gh` stub ($RL_MODE) serves `api rate_limit`,
# `project view`, and a board read that either succeeds, rate-limits, or hard-fails.
#   ok        — healthy board (0 items) → drain: complete, exit 0 (negative control: normal path intact)
#   secondary — board read fails "secondary rate limit"     → drain: rate-limited until <reset>, exit 3
#   hard      — board read fails "HTTP 500" (NOT a rate limit) → hard BoardReadError path, exit 2, no
#               "rate-limited" text anywhere (detection must stay SPECIFIC — the drain must not treat
#               every board-read failure as resumable)
# Every assertion is red-when-broken (reverts noted inline).
#
# Usage: bash tests/smoke/phase6-rate-limit-resume.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
CMD="$PLUGIN/commands/autorun.md"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$DRAIN" ] || fail "idc_autorun_drain.py not found"
[ -f "$CMD" ]   || fail "commands/autorun.md not found"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RESET=1719849600

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<STUB
#!/bin/bash
sub="\$1"; mode="\${RL_MODE:-ok}"
if [ "\$sub" = "api" ] && [ "\$2" = "rate_limit" ]; then
  printf '{"resources":{"graphql":{"remaining":4000,"reset":$RESET},"core":{"remaining":5000,"reset":$RESET}}}'
  exit 0
fi
if [ "\$sub" = "project" ] && [ "\$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "\$sub" = "api" ] && [ "\$2" = "graphql" ]; then
  case "\$mode" in
    secondary) echo "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2; exit 1 ;;
    hard)      echo "HTTP 500: Internal Server Error" >&2; exit 1 ;;
    *)         printf '%s' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'; exit 0 ;;
  esac
fi
echo "gh stub: unhandled \$*" >&2; exit 99
STUB
chmod +x "$WORK/bin/gh"
runb() { ( export PATH="$WORK/bin:$PATH"; RL_MODE="$1" python3 "$DRAIN" --backend github --owner tester --project 7 --repo "$WORK" ); }

# ============================================================================================
# 1. OK — a healthy (empty) board still drains normally. Negative control: proves the new
#    RateLimitError branch does not swallow or alter the ordinary success path.
# ============================================================================================
out="$(runb ok 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] || fail "case 1: a healthy board read must still exit 0 (got $rc)"
printf '%s\n' "$out" | grep -qx "drain: complete" || fail "case 1: an empty board must still report drain: complete (got: $out)"

# ============================================================================================
# 2. SECONDARY rate limit mid-read -> `drain: rate-limited until <reset>` + exit 3, NEVER
#    `drain: complete` and NEVER a bare exit 2 (which would be indistinguishable from a hard error).
#    RED-WHEN-BROKEN: revert the RateLimitError-specific catch in idc_autorun_drain.load_github (let
#    it fall through to the generic BoardReadError branch) -> this exits 2 with no "rate-limited" text
#    and the exact-string assertion fails.
# ============================================================================================
out="$(runb secondary 2>/dev/null)"; rc=$?
[ "$rc" = "3" ] || fail "case 2: a rate-limited board read must exit 3 (got $rc), distinct from a hard error (2) or complete (0)"
# the exact-string match below subsumes "never drain: complete" — $out can't equal both.
[ "$out" = "drain: rate-limited until $RESET" ] \
  || fail "case 2: must emit the EXACT verdict 'drain: rate-limited until $RESET' (got '$out') — would silently drop the tail wave if it read drain: complete instead"

# ============================================================================================
# 3. HARD (non-rate) board-read failure -> exit 2, no rate-limited text anywhere. The negative
#    control: detection must stay SPECIFIC (inherited from idc_gh_board), not "any board-read
#    failure is resumable". RED-WHEN-BROKEN: catch bare BoardReadError as if it were always
#    RateLimitError -> this flips to exit 3 and the assertion fails.
# ============================================================================================
out="$(runb hard 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] || fail "case 3: a non-rate board-read failure (HTTP 500) must exit 2, NOT the rate-limit path (got $rc)"
printf '%s\n' "$out" | grep -q 'rate-limited' \
  && fail "case 3: a hard board-read failure must NOT emit a rate-limited verdict (over-broad detection)"

# ============================================================================================
# 4. commands/autorun.md documents pause-and-resume consumption of the signal (prose, red-when-broken
#    per assertion — dropping any one clause fails its check).
# ============================================================================================
flat="$(tr '\n' ' ' < "$CMD" | tr -s ' ')"
grep -qE 'rate-limited until <reset>' "$CMD" \
  || fail "commands/autorun.md must reference the pinned 'rate-limited until <reset>' verdict"
printf '%s' "$flat" | grep -qiE 'deliberate,? resumable pause' \
  || fail "commands/autorun.md must frame a rate-limit verdict as a deliberate, resumable pause"
printf '%s' "$flat" | grep -qiE 'never[^.]*silent(ly)? drop|never[^.]*silently drop' \
  || fail "commands/autorun.md must state a rate-limit verdict is never silently dropped"
printf '%s' "$flat" | grep -qiE 're-check[^.]*next[^.]*/loop|next[^.]*/loop[^.]*re-check' \
  || fail "commands/autorun.md must state /loop re-checks the rate-limited lane next iteration"
grep -qE 'idc_git_finish\.py' "$CMD" \
  || fail "commands/autorun.md must reference idc_git_finish.py for the post-reset in-flight re-verify"
printf '%s' "$flat" | grep -qiE 'end-state' \
  || fail "commands/autorun.md must state the post-reset re-verify is an end-state check (idc_git_finish.py's contract)"

echo "PASS: idc_autorun_drain.py's github loader consumes Unit 1's RateLimitError as a distinct 'drain: rate-limited until <reset>' verdict on exit 3 (never drain: complete, never a bare hard-error exit 2); a non-rate board-read failure stays at exit 2 with no rate-limited text; a healthy board still drains normally; commands/autorun.md documents pause-and-resume + post-reset idc_git_finish.py end-state re-verify"
