#!/bin/bash
# idc-assert-class: behavior
# Phase 6 (rate-limit detection) smoke — the resumable-pause SIGNAL (issue #99 DETECTION half, §C.3).
#
# ROOT CAUSE this guards: a github board read that hit GitHub's rate limit died as an opaque non-zero
# mid-wave, indistinguishable from a hard error — so autorun could not tell "wait an hour, then resume"
# from "the board is broken." The fix (detection half, this unit): idc_gh_board._gh gains (a) a
# once-per-process PREFLIGHT that fail-closes up-front when the quota is already exhausted, and (b)
# 403 / secondary-rate / RATE_LIMITED detection on a failing call → a RateLimitError (BoardReadError
# subclass carrying .reset). The CLI maps it to the EXACT machine-readable verdict `rate-limited until
# <reset>` on stdout + the DISTINCT exit 3 (0 ok, 2 hard error, 3 rate-limited). Unit 4 consumes this as
# pause-and-resume in the autorun drain — the string + exit convention are a pinned cross-unit contract.
#
# Hermetic: no live GitHub — ONE mode-switched PATH `gh` stub ($RL_MODE) serves `api rate_limit`
# (remaining depends on mode), `project view`, and a board read that fails with a chosen error class.
#   ok         — plenty of quota; board read succeeds                     → exit 0 (preflight must NOT over-block)
#   secondary  — quota OK, board read fails "secondary rate limit"        → reactive detect → exit 3
#   primary403 — quota OK, board read fails "403 API rate limit exceeded" → reactive detect → exit 3
#   hard       — quota OK, board read fails "HTTP 500"                     → NOT a rate-limit → exit 2 (negative control)
#   perm403    — quota OK, board read fails "403 Resource not accessible"  → a PERMISSION 403, NOT a rate-limit → exit 2
#   preflight  — quota EXHAUSTED (remaining 0)                            → up-front pause, board read NEVER runs → exit 3
# Every assertion is red-when-broken (reverts noted inline). Also pins the RateLimitError shape for U4.
#
# Usage: bash tests/smoke/phase6-rate-limit-detect.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
BOARD="$SCRIPTS/idc_gh_board.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$BOARD" ] || fail "idc_gh_board.py not found"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FIX="$WORK"
RESET=1719849600

# minimal valid board (used by the ok / preflight modes)
printf '%s' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PVTI_1","fieldValues":{"nodes":[]},"content":{"__typename":"Issue","number":1,"title":"t"}}]}}}}' > "$WORK/board.json"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<STUB
#!/bin/bash
sub="\$1"; mode="\${RL_MODE:-ok}"
if [ "\$sub" = "api" ] && [ "\$2" = "rate_limit" ]; then
  if [ "\$mode" = "preflight" ]; then rem=0; else rem=4000; fi
  printf '{"resources":{"graphql":{"remaining":%s,"reset":$RESET},"core":{"remaining":5000,"reset":$RESET}}}' "\$rem"
  exit 0
fi
if [ "\$sub" = "project" ] && [ "\$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "\$sub" = "api" ] && [ "\$2" = "graphql" ]; then
  echo "GRAPHQL" >> "\$FIX/gh.log"
  case "\$mode" in
    secondary)  echo "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2; exit 1 ;;
    primary403) echo "HTTP 403: API rate limit exceeded for user ID 123." >&2; exit 1 ;;
    perm403)    echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
    hard)       echo "HTTP 500: Internal Server Error" >&2; exit 1 ;;
    *)          cat "\$FIX/board.json"; exit 0 ;;
  esac
fi
echo "gh stub: unhandled \$*" >&2; exit 99
STUB
chmod +x "$WORK/bin/gh"
runb() { ( export PATH="$WORK/bin:$PATH"; RL_MODE="$1" python3 "$BOARD" --owner tester --project 7 --repo "$WORK" ); }

# ============================================================================================
# 0. RateLimitError shape (pinned for Unit 4): subclass of BoardReadError, carries .reset.
# ============================================================================================
python3 - "$SCRIPTS" <<'PY' || fail "RateLimitError contract broken (Unit 4 depends on it)"
import sys; sys.path.insert(0, sys.argv[1]); import idc_gh_board as b
assert issubclass(b.RateLimitError, b.BoardReadError), "RateLimitError must subclass BoardReadError"
assert b.RateLimitError(123).reset == 123, "RateLimitError must carry .reset"
PY

# ============================================================================================
# 1. OK — plenty of quota → board read succeeds, exit 0. Proves the preflight does NOT over-block.
# ============================================================================================
: > "$WORK/gh.log"
out="$(runb ok 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] || fail "case 1: a healthy board read must exit 0 (got $rc) — preflight over-blocked?"
printf '%s' "$out" | grep -q '"items"' || fail "case 1: a healthy read must still emit the board JSON"

# ============================================================================================
# 2. SECONDARY rate limit on the read → `rate-limited until <reset>` + exit 3 (reactive detection).
#    RED-WHEN-BROKEN: remove the _is_rate_limit_stderr branch in _gh → this returns exit 2 (hard error).
# ============================================================================================
: > "$WORK/gh.log"
out="$(runb secondary 2>/dev/null)"; rc=$?
[ "$rc" = "3" ] || fail "case 2: a secondary-rate-limited read must exit 3 (got $rc), distinct from a hard error"
[ "$out" = "rate-limited until $RESET" ] \
  || fail "case 2: must emit the EXACT verdict 'rate-limited until $RESET' (got '$out') — Unit 4 pins this string"

# ============================================================================================
# 3. PRIMARY 403 rate limit → same verdict + exit 3 (403 detection).
# ============================================================================================
out="$(runb primary403 2>/dev/null)"; rc=$?
[ "$rc" = "3" ] || fail "case 3: a 403 'API rate limit exceeded' read must exit 3 (got $rc)"
[ "$out" = "rate-limited until $RESET" ] || fail "case 3: must emit 'rate-limited until $RESET' (got '$out')"

# ============================================================================================
# 4. HARD (non-rate) error → exit 2, NO rate-limit verdict. The negative control: detection must be
#    SPECIFIC, not "any failure is a rate-limit". RED-WHEN-BROKEN: treat every failure as rate-limited
#    → this flips to exit 3 and the assertion fails.
# ============================================================================================
out="$(runb hard 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] || fail "case 4: a non-rate gh failure (HTTP 500) must exit 2, NOT the rate-limit path (got $rc)"
printf '%s' "$out" | grep -q 'rate-limited' \
  && fail "case 4: a non-rate failure must NOT emit a 'rate-limited' verdict (detection over-broad)"

# ============================================================================================
# 5. PREFLIGHT — quota already exhausted (remaining 0) → up-front pause (exit 3) BEFORE any board read.
#    RED-WHEN-BROKEN: drop the preflight → the read runs; in preflight mode the board read SUCCEEDS
#    (quota is only 0 in rate_limit, the stub still serves the board), so the run would exit 0 — this
#    exit-3 assertion catches it. Also proves the board read never fired (no GRAPHQL logged).
# ============================================================================================
: > "$WORK/gh.log"
out="$(runb preflight 2>/dev/null)"; rc=$?
[ "$rc" = "3" ] || fail "case 5: an already-exhausted quota must pause up-front with exit 3 (got $rc)"
[ "$out" = "rate-limited until $RESET" ] || fail "case 5: preflight must emit 'rate-limited until $RESET' (got '$out')"
grep -q 'GRAPHQL' "$WORK/gh.log" \
  && fail "case 5: the preflight must short-circuit BEFORE the board read (a graphql fetch happened)"

# ============================================================================================
# 6. PERMISSION 403 ('Resource not accessible') → exit 2, NOT 3. The false-positive invariant: a plain
#    permission/auth 403 must NOT be misread as a resumable rate-limit (else a real access failure gets
#    silently paused-and-retried forever instead of surfacing). Detection keys on rate-limit WORDING,
#    never a bare "403". RED-WHEN-BROKEN: add "403" or "not accessible" to _RATE_LIMIT_MARKERS → this
#    flips to exit 3 and the assertion fails.
# ============================================================================================
out="$(runb perm403 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] \
  || fail "case 6: a permission 403 ('Resource not accessible') must exit 2 (hard error), NOT the rate-limit path (got $rc)"
printf '%s' "$out" | grep -q 'rate-limited' \
  && fail "case 6: a permission 403 must NOT emit a 'rate-limited' verdict (false positive — detection over-broad)"

echo "PASS: _gh preflights an exhausted quota (exit 3, no board read), detects secondary/403-rate limits on a failing read (exit 3, 'rate-limited until <reset>'), keeps a hard error AND a permission 403 at exit 2, and passes a healthy read (exit 0); RateLimitError subclasses BoardReadError with .reset"
