#!/bin/bash
# Phase 4 (github board pagination) smoke — the 30-item truncation fix (release 3.1.4).
#
# ROOT CAUSE this guards: every github board read called `gh project item-list … --format json`
# WITHOUT a limit, so gh returned only its default 30-item first page. On a board grown past 30
# items the build-lane query saw a fraction of the eligible `Stage=Buildable`/`Status=Todo` issues,
# a Consideration past the cut vanished, and the drain went blind → "Nothing pending" on a board
# full of work. The fix is the shared paginating reader scripts/idc_gh_board.py (TRUE cursor
# pagination — pages the GraphQL items() connection to completion, no magic --limit) + a github
# mode on scripts/idc_autorun_drain.py that consumes it with the SAME pure eligibility predicate as
# the filesystem backend.
#
# Hermetic: a PATH `gh` stub serves a 135-item board across TWO pages — page 1 = 100 NON-eligible
# (Done) items, page 2 = the ENTIRE ready frontier (eligible Buildable/Todo, a cross-page dependent,
# a Consideration, operator/recirc/blocked non-eligibles). With pagination reverted to a single
# unpaged fetch ONLY page 1 is seen → eligible EMPTY → drain reports complete (the production bug),
# so every assertion below is red-when-broken by construction.
#
# Usage: bash tests/smoke/phase4-github-pagination.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
BOARD="$SCRIPTS/idc_gh_board.py"
DRAIN="$SCRIPTS/idc_autorun_drain.py"
fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq required (to emulate gh --jq and assert over the helper output)"
[ -f "$BOARD" ] || fail "idc_gh_board.py not found (the shared paginating primitive is missing)"
[ -f "$DRAIN" ] || fail "idc_autorun_drain.py not found"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FIX="$WORK"

# --- build the 135-item, 2-page board fixture (page1.json / page2.json) + the blocked_by map ------
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
def ss(field, opt):
    return {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": opt,
            "field": {"name": field}}
def node(num, status=None, stage=None, title=None):
    fvs = []
    if status: fvs.append(ss("Status", status))
    if stage:  fvs.append(ss("Stage", stage))
    return {"id": f"PVTI_{num}", "fieldValues": {"nodes": fvs},
            "content": {"__typename": "Issue", "number": num, "title": title or f"issue {num}"}}

# page 1: 100 Done/Buildable NOISE (#101..#200) — none eligible (not Todo). #101 is a Done blocker
# referenced cross-page by #203, proving the predicate resolves a page-1 blocker for a page-2 issue.
page1 = [node(n, status="Done", stage="Buildable") for n in range(101, 201)]
# page 2: the ready frontier + non-eligibles + Done filler (#201..#235)
page2 = [
    node(201, status="Todo", stage="Buildable"),                                   # ELIGIBLE (unblocked)
    node(202, status="Todo", stage="Buildable"),                                   # blocked by #300 (not Done) -> excluded
    node(203, status="Todo", stage="Buildable"),                                   # blocked by #101 (Done, page 1) -> ELIGIBLE (cross-page)
    node(204, status="Todo", stage="Consideration", title="a consideration"),      # glass wall -> visible, not eligible
    node(205, status="Todo", stage="Buildable", title="[operator-action] approve"),# operator gate -> not eligible
    node(206, status="Todo", stage="Recirculation"),                               # recirc inbox -> not eligible
    node(207, status="Todo", stage="Buildable", title="ctrlchar"),           # ELIGIBLE + a control char in the title (escaping)
]
page2 += [node(n, status="Done", stage="Buildable") for n in range(208, 236)]      # Done filler -> 35 items total

def page(nodes, has_next, end):
    return {"data": {"node": {"items": {
        "pageInfo": {"hasNextPage": has_next, "endCursor": end}, "nodes": nodes}}}}

open(os.path.join(work, "page1.json"), "w").write(json.dumps(page(page1, True, "CUR1")))
open(os.path.join(work, "page2.json"), "w").write(json.dumps(page(page2, False, None)))
open(os.path.join(work, "blocked_by.json"), "w").write(json.dumps({"202": [300], "203": [101]}))
PY

# --- gh stub: project view -> node id; api graphql -> page1/page2 by cursor presence; dependencies
#     blocked_by -> the mapped number list. Logs each graphql page fetch to prove the cursor loop ran.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
sub="$1"
if [ "$sub" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then
  has_cursor=0
  for a in "$@"; do case "$a" in cursor=*) has_cursor=1 ;; esac; done
  if [ "$has_cursor" = 1 ]; then echo "graphql page2" >> "$FIX/gh.log"; cat "$FIX/page2.json"
  else echo "graphql page1" >> "$FIX/gh.log"; cat "$FIX/page1.json"; fi
  exit 0
fi
if [ "$sub" = "api" ]; then
  path=""
  for a in "$@"; do case "$a" in */dependencies/blocked_by) path="$a" ;; esac; done
  if [ -n "$path" ]; then
    n="$(printf '%s' "$path" | sed -E 's#.*/issues/([0-9]+)/dependencies/blocked_by#\1#')"
    jq -c --arg n "$n" '.[$n] // []' "$FIX/blocked_by.json"
    exit 0
  fi
fi
echo "gh stub: unhandled: $*" >&2; exit 99
STUB
chmod +x "$WORK/bin/gh"

# a SECOND stub that always fails, for the fail-closed assertions
mkdir -p "$WORK/binfail"
printf '#!/bin/bash\necho "boom" >&2; exit 1\n' > "$WORK/binfail/gh"
chmod +x "$WORK/binfail/gh"

# ============================================================================================
# 1. idc_gh_board.py returns ALL items across BOTH pages (no 30/100 truncation)
# ============================================================================================
: > "$WORK/gh.log"
ALL="$(PATH="$WORK/bin:$PATH" python3 "$BOARD" --owner tester --project 7 --repo "$WORK")" \
  || fail "idc_gh_board.py exited non-zero against the multi-page stub"
total="$(printf '%s' "$ALL" | jq '.items | length')"
[ "$total" = "135" ] \
  || fail "paginated read must return ALL 135 items across pages (got $total — truncated to a single page?)"
# the cursor loop must have fetched BOTH pages (red if pagination reverts to one fetch)
graphql_calls="$(grep -c graphql "$WORK/gh.log" 2>/dev/null || echo 0)"
[ "$graphql_calls" = "2" ] \
  || fail "the reader must page until hasNextPage=false (expected 2 graphql fetches, got $graphql_calls)"
# the page-2 Consideration is visible
printf '%s' "$ALL" | jq -e '.items[] | select(.content.number==204 and .stage=="Consideration")' >/dev/null \
  || fail "the page-2 Consideration (#204) must be visible in the paginated read"
# a page-2 eligible Buildable/Todo is visible
printf '%s' "$ALL" | jq -e '.items[] | select(.content.number==201 and .status=="Todo" and .stage=="Buildable")' >/dev/null \
  || fail "the page-2 eligible Buildable/Todo (#201) must be visible in the paginated read"

# ============================================================================================
# 2. the skill's read patterns (capture-then-jq over the helper output) see cross-page items
# ============================================================================================
# build-lane query: Status=Todo AND (stage // "Buildable")=="Buildable" -> #201,#202,#203,#205,#207.
# #205 ([operator-action]) IS Buildable/Todo so the raw query returns it — the operator-action and
# blocked-by exclusions happen in the DRAIN predicate (section 3), not in the skill's query op.
buildable_todo="$(printf '%s' "$ALL" | jq -r '.items[] | select(.status=="Todo") | select((.stage // "Buildable")=="Buildable") | .content.number' | sort -n | tr '\n' ' ')"
[ "$buildable_todo" = "201 202 203 205 207 " ] \
  || fail "the build-lane query must see ALL Buildable/Todo across pages (got '$buildable_todo')"
# considerations query
cons="$(printf '%s' "$ALL" | jq -r '.items[] | select((.stage // "Buildable")=="Consideration") | .content.number')"
[ "$cons" = "204" ] \
  || fail "the considerations query must see the page-2 Consideration (got '$cons')"
# itemid pattern: a high-numbered page-2 issue resolves its item id (the blank-id mutation bug)
iid="$(printf '%s' "$ALL" | jq -r '.items[] | select(.content.number==207) | .id')"
[ "$iid" = "PVTI_207" ] \
  || fail "itemid for a page-2 issue (#207) must resolve its item id (got '$iid' — blank id on a high issue number?)"
# control-char title survives as valid escaped JSON (external jq never choked above; assert explicitly)
printf '%s' "$ALL" | jq -e '.items[] | select(.content.number==207)' >/dev/null \
  || fail "the control-char-title item (#207) must survive as valid escaped JSON (downstream jq safe)"

# ============================================================================================
# 3. github drain predicate over the >30 board -> the FULL cross-page eligible set + continue
# ============================================================================================
: > "$WORK/gh.log"
DR="$(PATH="$WORK/bin:$PATH" python3 "$DRAIN" --backend github --project 7 --owner tester --repo "$WORK" --width 2>/dev/null)" \
  || fail "github drain exited non-zero against the multi-page stub"
elig="$(printf '%s' "$DR" | grep '^eligible:' | sed 's/^eligible: //')"
[ "$elig" = "201 203 207" ] \
  || fail "github drain eligible set must be the full cross-page frontier '201 203 207' (got '$elig')"
printf '%s' "$DR" | grep -qx "drain: continue" \
  || fail "github drain must report 'continue' (the ready frontier sits on page 2)"
printf '%s' "$DR" | grep -qx "width: 3" \
  || fail "github drain width must be 3 (got: $(printf '%s' "$DR" | tr '\n' '|'))"
# blocked-aware (red-when-broken): #202 (blocker #300 NOT Done) excluded; #203 (blocker #101 Done) included
printf '%s' "$DR" | grep -qE '(^| )202( |$)' \
  && fail "#202 must NOT be eligible — its blocker #300 is not Done (blocked-aware predicate)"
printf '%s' "$DR" | grep -qE '(^| )203( |$)' \
  || fail "#203 MUST be eligible — its only blocker #101 is Done on page 1 (cross-page resolution)"

# ============================================================================================
# 4. the PURE predicate over a >30-item fixture whose frontier sits past index 30
# ============================================================================================
elig_pure="$(python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import idc_autorun_drain as d
issues = [{"number": n, "status": "Done", "stage": "Buildable"} for n in range(1, 36)]  # 35 Done (idx 0..34)
issues += [{"number": 40, "status": "Todo", "stage": "Buildable"},                       # eligible, past idx 30
           {"number": 41, "status": "Todo", "stage": "Buildable", "blocked_by": [40]},   # blocked by 40 (Todo) -> excluded
           {"number": 42, "status": "Todo", "stage": "Buildable", "blocked_by": [1]}]    # blocked by 1 (Done) -> eligible
print(" ".join(str(n) for n in d.compute_eligible(issues)))
PY
)"
[ "$elig_pure" = "40 42" ] \
  || fail "the pure predicate over a >30 fixture (frontier past index 30) must return '40 42' (got '$elig_pure')"

# ============================================================================================
# 5. fail-closed: arg guards + an unreadable board exit 2 (never a hollow empty drain)
# ============================================================================================
python3 "$DRAIN" --backend github --owner tester >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] || fail "github backend without --project must exit 2 (got $rc)"
python3 "$DRAIN" --backend github --project 7 >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] || fail "github backend without --owner must exit 2 (got $rc)"
PATH="$WORK/binfail:$PATH" python3 "$BOARD" --owner tester --project 7 --repo "$WORK" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] || fail "idc_gh_board.py must exit 2 on a gh failure (got $rc)"
PATH="$WORK/binfail:$PATH" python3 "$DRAIN" --backend github --project 7 --owner tester --repo "$WORK" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] || fail "an unreadable github board must exit 2 fail-closed (got $rc), never a hollow drain: complete"

echo "PASS: idc_gh_board.py paginates the whole board (135/135 across 2 pages); skill read patterns + github drain see the cross-page frontier (201 203 207, blocked-aware, control-char safe); pure predicate green past index 30; fail-closed on unreadable board"
