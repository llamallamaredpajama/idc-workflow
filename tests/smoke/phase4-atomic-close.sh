#!/bin/bash
# idc-assert-class: behavior
# Phase 4 (atomic issue-close) smoke — the Done-but-open fix (issue #96, design §B.2, RC3).
#
# ROOT CAUSE this guards: the old github `close` recipe was TWO non-atomic gh calls — set Status=Done,
# then `gh issue close` — with NO verification the issue actually closed. A crash, a silent gh no-op, or
# a partial failure between them left a Done-but-OPEN issue (the live board carried 10 such stragglers).
# The fix: scripts/idc_gh_close.py collapses close into ONE fail-closed op — Status→Done + gh issue close
# + READ-BACK the issue state, refusing success unless it is CLOSED. Any unverified step exits 2 with a
# machine-readable `close: <step> failed` line; a re-close of an already-closed issue re-verifies (exit 0).
#
# Hermetic: no live GitHub — ONE mode-switched PATH `gh` stub ($GH_MODE) emulates project view (node id),
# field-list (Status/Done options), the board read, item-edit, issue close, and issue view. A mutable
# state file ($FIX/state, OPEN→CLOSED) makes the read-back verify a REAL check, not a paraphrase. Modes:
#   normal      — `gh issue close` truly closes (state→CLOSED)                       → happy path
#   close_noop  — `gh issue close` is a NO-OP (state stays OPEN)                      → read-back must catch it
#   no_graphql  — `api graphql` fails loudly; proves --item-id skips the board read
# The SHIPPED close op is EXTRACTED from SKILL.md and asserted to route through the helper (couples to
# the real file). Every assertion is red-when-broken (reverts noted inline).
#
# Usage: bash tests/smoke/phase4-atomic-close.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN/skills/idc-tracker-github/SKILL.md"
CLOSE="$PLUGIN/scripts/idc_gh_close.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SKILL" ] || fail "skill not found: $SKILL"
[ -f "$CLOSE" ] || fail "atomic close helper not found: $CLOSE (the #96 fix is missing)"

# --help parses cleanly
python3 "$CLOSE" --help >/dev/null 2>&1 || fail "idc_gh_close.py --help must parse cleanly"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FIX="$WORK"

# --- fixtures: a 1-item board (issue #42 → PVTI_42) + a field list (Status/Done). -----------------
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
board = {"data": {"node": {"items": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [
    {"id": "PVTI_42", "fieldValues": {"nodes": []},
     "content": {"__typename": "Issue", "number": 42, "title": "t"}}]}}}}
fields = {"fields": [{"name": "Status", "id": "FIELD_STATUS",
                      "options": [{"name": "Done", "id": "OPT_DONE"}, {"name": "Todo", "id": "OPT_TODO"}]}]}
open(os.path.join(work, "board.json"), "w").write(json.dumps(board))
open(os.path.join(work, "fields.json"), "w").write(json.dumps(fields))
PY

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
sub="$1"; mode="${GH_MODE:-normal}"
# #99 preflight — answer rate_limit benignly (never block/error these cases)
if [ "$sub" = "api" ]; then for a in "$@"; do case "$a" in rate_limit) echo '{}'; exit 0 ;; esac; done; fi
if [ "$sub" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then
  echo "GRAPHQL" >> "$FIX/gh.log"
  if [ "$mode" = "no_graphql" ]; then echo "board read should not happen (--item-id given)" >&2; exit 1; fi
  cat "$FIX/board.json"; exit 0
fi
if [ "$sub" = "project" ] && [ "$2" = "field-list" ]; then cat "$FIX/fields.json"; exit 0; fi
if [ "$sub" = "project" ] && [ "$2" = "item-edit" ]; then
  iid="__UNSET__"; pid="__UNSET__"; oid="__UNSET__"; args=("$@")
  for ((i=0;i<${#args[@]};i++)); do case "${args[$i]}" in
    --id) iid="${args[$((i+1))]}" ;; --project-id) pid="${args[$((i+1))]}" ;;
    --single-select-option-id) oid="${args[$((i+1))]}" ;; esac; done
  echo "ITEM_EDIT id=$iid pid=$pid opt=$oid" >> "$FIX/gh.log"; exit 0
fi
if [ "$sub" = "issue" ] && [ "$2" = "close" ]; then
  echo "ISSUE_CLOSE $3" >> "$FIX/gh.log"
  [ "$mode" = "close_noop" ] || echo "CLOSED" > "$FIX/state"   # normal closes; close_noop leaves it OPEN
  exit 0
fi
if [ "$sub" = "issue" ] && [ "$2" = "view" ]; then cat "$FIX/state"; exit 0; fi
echo "gh stub: unhandled $*" >&2; exit 99
STUB
chmod +x "$WORK/bin/gh"
run() { ( export PATH="$WORK/bin:$PATH"; "$@" ); }

# ============================================================================================
# A. HAPPY PATH — Status→Done + close + read-back(CLOSED) → exit 0, and the right gh calls happen.
# ============================================================================================
echo "OPEN" > "$WORK/state"; : > "$WORK/gh.log"
GH_MODE=normal run python3 "$CLOSE" --owner tester --project 7 --issue 42 --repo "$WORK" >/dev/null 2>"$WORK/errA"; rc=$?
[ "$rc" = "0" ] || fail "case A: a clean atomic close must exit 0 (got $rc; err: $(cat "$WORK/errA"))"
grep -q '^ITEM_EDIT id=PVTI_42 pid=PVT_test opt=OPT_DONE$' "$WORK/gh.log" \
  || fail "case A: item-edit must set Status=Done (OPT_DONE) on PVTI_42 with the PVT_ node id (log: $(cat "$WORK/gh.log"))"
grep -q '^ISSUE_CLOSE 42$' "$WORK/gh.log" || fail "case A: the issue must actually be closed"
[ "$(cat "$WORK/state")" = "CLOSED" ] || fail "case A: end state must be CLOSED"

# ============================================================================================
# B. READ-BACK CATCHES Done-but-open — `gh issue close` is a NO-OP (state stays OPEN); the helper
#    must FAIL LOUDLY (exit 2, `close: verify-closed failed`), NEVER report a phantom success.
#    RED-WHEN-BROKEN: remove the `state != CLOSED` read-back check → the helper exits 0 → this fails.
# ============================================================================================
echo "OPEN" > "$WORK/state"; : > "$WORK/gh.log"
GH_MODE=close_noop run python3 "$CLOSE" --owner tester --project 7 --issue 42 --repo "$WORK" >/dev/null 2>"$WORK/errB"; rc=$?
[ "$rc" = "2" ] \
  || fail "case B: a close that leaves the issue OPEN must exit 2 (got $rc) — the Done-but-open bug must be caught"
grep -q 'close:.*failed' "$WORK/errB" \
  || fail "case B: must emit a machine-readable 'close: <step> failed' line (got: $(cat "$WORK/errB"))"
grep -q 'verify-closed' "$WORK/errB" \
  || fail "case B: the failing step must be the read-back verify (got: $(cat "$WORK/errB"))"

# ============================================================================================
# C. FAIL-CLOSED on an off-board issue — #999 is not on the board → exit 2 `close: resolve-item-id`,
#    the mutation NEVER runs (never "close" a ghost).
# ============================================================================================
echo "OPEN" > "$WORK/state"; : > "$WORK/gh.log"
GH_MODE=normal run python3 "$CLOSE" --owner tester --project 7 --issue 999 --repo "$WORK" >/dev/null 2>"$WORK/errC"; rc=$?
[ "$rc" = "2" ] || fail "case C: closing an off-board issue must exit 2 (got $rc)"
grep -q 'close:.*failed' "$WORK/errC" || fail "case C: must emit a 'close: <step> failed' line"
grep -q 'ITEM_EDIT' "$WORK/gh.log" && fail "case C: item-edit must NOT run for an off-board issue"
grep -q 'ISSUE_CLOSE' "$WORK/gh.log" && fail "case C: issue close must NOT run for an off-board issue"

# ============================================================================================
# D. IDEMPOTENT — issue already CLOSED; a re-close re-verifies and exits 0 (no error on a settled issue).
# ============================================================================================
echo "CLOSED" > "$WORK/state"; : > "$WORK/gh.log"
GH_MODE=normal run python3 "$CLOSE" --owner tester --project 7 --issue 42 --repo "$WORK" >/dev/null 2>"$WORK/errD"; rc=$?
[ "$rc" = "0" ] || fail "case D: re-closing an already-CLOSED issue must exit 0 (idempotent; got $rc: $(cat "$WORK/errD"))"

# ============================================================================================
# E. --item-id skips the board read — pass the (cached) item id; `api graphql` fails loudly, yet close
#    succeeds → proves the helper never re-reads the board when the caller supplies the id (cache reuse).
# ============================================================================================
echo "OPEN" > "$WORK/state"; : > "$WORK/gh.log"
GH_MODE=no_graphql run python3 "$CLOSE" --owner tester --project 7 --issue 42 --item-id PVTI_42 --repo "$WORK" >/dev/null 2>"$WORK/errE"; rc=$?
[ "$rc" = "0" ] || fail "case E: --item-id close must succeed WITHOUT a board read (got $rc: $(cat "$WORK/errE"))"
grep -q 'GRAPHQL' "$WORK/gh.log" && fail "case E: --item-id must skip the board read (a graphql fetch happened)"

# ============================================================================================
# F. The SHIPPED close op routes through the helper (couples to the real SKILL.md).
#    RED-WHEN-BROKEN: point `close` back at the old `move Done` + `gh issue close` recipe → this fails.
# ============================================================================================
close_block="$(awk '/\*\*close\(issue\)\*\*/{f=1} f{print} f && /idc_gh_close\.py/{exit}' "$SKILL")"
printf '%s\n' "$close_block" | grep -q 'idc_gh_close\.py' \
  || fail "SKILL.md close op must route through scripts/idc_gh_close.py (the atomic helper), not the old two-call recipe"

echo "PASS: idc_gh_close.py sets Status=Done + closes + reads back CLOSED (exit 0), catches a Done-but-open no-op (exit 2 close: verify-closed failed), fail-closes off-board, is idempotent, skips the board read with --item-id, and the shipped close op routes through it"
