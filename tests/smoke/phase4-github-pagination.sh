#!/bin/bash
# idc-assert-class: behavior
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
            "content": {"__typename": "Issue", "number": num, "title": title or f"issue {num}",
                        "repository": {"nameWithOwner": "tester/repo"}}}

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
    node(209, status="Todo"),                                                      # NO Stage (legacy 4-field) -> Buildable via (.stage // "Buildable") -> ELIGIBLE
    node(210, status="Todo", stage="Buildable"),                                   # blocked_by lookup FAILS -> fail-closed -> excluded from the drain
]
page2 += [node(n, status="Done", stage="Buildable") for n in range(211, 237)]      # Done filler (26) -> 35 page-2 items, 135 total

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
if [ "$sub" = "repo" ] && [ "$2" = "view" ]; then echo "tester/repo"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then
  cursor_val=""; has_pid=0
  for a in "$@"; do case "$a" in cursor=*) cursor_val="${a#cursor=}" ;; pid=PVT_test) has_pid=1 ;; esac; done
  # the resolved project NODE id must be wired through as `-f pid=PVT_test` — red if the node-id
  # resolution (gh project view) or the `-f pid=` variable wiring regresses.
  [ "$has_pid" = 1 ] || { echo "stub: graphql missing pid=PVT_test (broken pid resolution / -f wiring)" >&2; exit 7; }
  if [ -n "$cursor_val" ]; then
    # the reader must thread page 1's endCursor (CUR1) VERBATIM into the next page request — a
    # wrong/empty cursor (e.g. reusing an old cursor, or dropping endCursor) is a pagination
    # regression. Demanding the exact value proves the loop wires the correct endCursor, not just
    # "some cursor".
    [ "$cursor_val" = "CUR1" ] || { echo "stub: graphql cursor='$cursor_val' != CUR1 (reader did not thread page 1's endCursor)" >&2; exit 8; }
    echo "graphql page2" >> "$FIX/gh.log"; cat "$FIX/page2.json"
  else echo "graphql page1" >> "$FIX/gh.log"; cat "$FIX/page1.json"; fi
  exit 0
fi
if [ "$sub" = "api" ]; then
  path=""
  for a in "$@"; do case "$a" in */dependencies/blocked_by) path="$a" ;; esac; done
  if [ -n "$path" ]; then
    n="$(printf '%s' "$path" | sed -E 's#.*/issues/([0-9]+)/dependencies/blocked_by#\1#')"
    if [ "$n" = "210" ]; then echo "dependencies API boom" >&2; exit 1; fi   # simulate a FAILED lookup
    paginate=0; strict_jq=0
    for a in "$@"; do
      [ "$a" = "--paginate" ] && paginate=1
      [ "$a" = ".[].number" ] && strict_jq=1
    done
    [ "$paginate" = 1 ] && [ "$strict_jq" = 1 ] \
      || { echo "dependency reader omitted --paginate --jq .[].number" >&2; exit 9; }
    jq -r --arg n "$n" '.[$n][]?' "$FIX/blocked_by.json"
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

# a THIRD stub: project view OK, but graphql returns a MALFORMED/error response ($BADGQL) at exit 0.
# Models the anomalous case codex flagged — a 200 with errors / no board shape that must NOT coerce
# to an empty board (which would recreate the silent "blind drain: complete").
mkdir -p "$WORK/binbad"
cat > "$WORK/binbad/gh" <<'STUB'
#!/bin/bash
[ "$1" = "project" ] && [ "$2" = "view" ] && { echo "PVT_test"; exit 0; }
[ "$1" = "api" ] && [ "$2" = "graphql" ] && { printf '%s' "$BADGQL"; exit 0; }
echo "binbad: unhandled $*" >&2; exit 99
STUB
chmod +x "$WORK/binbad/gh"

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
# LEGACY 4-field default (red-when-broken): an item with no Stage must OMIT the stage key (not emit
# ""), so the shared (.stage // "Buildable") default reads it as Buildable. jq's // only defaults on
# null — if _flatten emitted stage="" a legacy board would surface ZERO Buildable items (silent blind).
printf '%s' "$ALL" | jq -e '.items[] | select(.content.number==209) | has("stage") | not' >/dev/null \
  || fail "an absent-Stage item (#209) must OMIT the stage key, not emit '' — else (.stage // \"Buildable\") can't default it (legacy 4-field blind)"

# ============================================================================================
# 2. the skill's read patterns (capture-then-jq over the helper output) see cross-page items
# ============================================================================================
# build-lane query: Status=Todo AND (stage // "Buildable")=="Buildable" -> 201,202,203,205,207,209,210.
# #205 ([operator-action]) IS Buildable/Todo so the raw query returns it — the operator-action and
# blocked-by exclusions happen in the DRAIN predicate (section 3), not in the skill's query op. #209
# (no Stage) is included via the legacy (.stage // "Buildable") default — red if _flatten emits stage="".
buildable_todo="$(printf '%s' "$ALL" | jq -r '.items[] | select(.status=="Todo") | select((.stage // "Buildable")=="Buildable") | .content.number' | sort -n | tr '\n' ' ')"
[ "$buildable_todo" = "201 202 203 205 207 209 210 " ] \
  || fail "the build-lane query must see ALL Buildable/Todo across pages incl. the legacy-default #209 (got '$buildable_todo')"
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

# --- 2b. the SHIPPED query(filter) op block, EXTRACTED from SKILL.md and run end-to-end over the
#         paginated stub — proves the real recipe (not a replica) reads the WHOLE board, incl. the
#         legacy (.stage // "Buildable") default for #209. Couples the test to the shipped file.
SKILL="$PLUGIN/skills/idc-tracker-github/SKILL.md"
query_src="$(awk '
  /\*\*query\(filter\)/ { found=1 }
  found && /^```bash/ { grab=1; next }
  found && grab && /^```/ { exit }
  found && grab { print }
' "$SKILL")"
bj_src="$(awk '/^board_json\(\) \{/{print; exit}' "$SKILL")"
[ -n "$query_src" ] || fail "could not extract the query(filter) op block from SKILL.md (recipe shape changed?)"
[ -n "$bj_src" ]    || fail "could not extract board_json() from SKILL.md"
printf '%s\n' "$query_src" | grep -q 'board_json' || fail "the query op must read the board via the paginated board_json"
qharness="$WORK/qharness.sh"
{
  echo 'set -uo pipefail'
  echo 'OWNER=tester; PROJ=7'
  echo 'die_gh() { echo "die_gh: query read failed" >&2; exit 1; }'
  printf '%s\n' "$bj_src"
  echo 'STATUS=Todo; STAGE=Buildable; WAVE=""; PHASE=""; DOMAIN=""'
  printf '%s\n' "$query_src"
} > "$qharness"
qout="$( ( export PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN" FIX="$WORK"; bash "$qharness" ) | sort -n | tr '\n' ' ')"
[ "$qout" = "201 202 203 205 207 209 210 " ] \
  || fail "the SHIPPED query op (Stage=Buildable,Status=Todo) must return the cross-page Buildable/Todo set incl. legacy-default #209 (got '$qout')"

# ============================================================================================
# 3. github drain predicate over the >30 board -> the FULL cross-page eligible set + continue
# ============================================================================================
: > "$WORK/gh.log"
DR="$(PATH="$WORK/bin:$PATH" python3 "$DRAIN" --backend github --project 7 --owner tester --repo "$WORK" --width 2>/dev/null)" \
  || fail "github drain exited non-zero against the multi-page stub"
elig="$(printf '%s' "$DR" | grep '^eligible:' | sed 's/^eligible: //')"
[ "$elig" = "201 203 207 209" ] \
  || fail "github drain eligible set must be the full cross-page frontier '201 203 207 209' (got '$elig')"
printf '%s' "$DR" | grep -qx "drain: continue" \
  || fail "github drain must report 'continue' (the ready frontier sits on page 2)"
printf '%s' "$DR" | grep -qx "width: 4" \
  || fail "github drain width must be 4 (got: $(printf '%s' "$DR" | tr '\n' '|'))"
# blocked-aware (red-when-broken): #202 (blocker #300 NOT Done) excluded; #203 (blocker #101 Done) included
printf '%s' "$DR" | grep -qE '(^| )202( |$)' \
  && fail "#202 must NOT be eligible — its blocker #300 is not Done (blocked-aware predicate)"
printf '%s' "$DR" | grep -qE '(^| )203( |$)' \
  || fail "#203 MUST be eligible — its only blocker #101 is Done on page 1 (cross-page resolution)"
# legacy default (red-when-broken on the python side): #209 (no Stage) MUST be eligible via (stage or "Buildable")
printf '%s' "$DR" | grep -qE '(^| )209( |$)' \
  || fail "#209 MUST be eligible — an absent Stage reads as Buildable (legacy 4-field default)"
# per-issue FAIL-CLOSED (red-when-broken): #210's blocked_by lookup FAILED → a positive self-block
# excludes it (never claim work whose blockers we couldn't verify). Flip that self-block to []
# (fail-open) and #210 wrongly becomes eligible — this assertion catches it.
printf '%s' "$DR" | grep -qE '(^| )210( |$)' \
  && fail "#210 must NOT be eligible — its blocked_by lookup FAILED, so the fail-closed self-block must exclude it"

# ============================================================================================
# 3b. AGGREGATE fail-closed (the Blocker): the board read SUCCEEDS but EVERY Buildable/Todo
#     candidate's blocked_by lookup FAILS (a board-wide dependencies API outage) → every candidate is
#     fail-closed-excluded → eligible empties. The verdict must be `drain: unknown` + a NON-ZERO exit,
#     NEVER `drain: complete` exit 0 — that hollow "complete" is the silent blind-drain autorun treats
#     as TERMINAL (it stops on a board still full of work). Remove the aggregate guard in
#     idc_autorun_drain.main() and this flips to `drain: complete` exit 0, so the asserts are
#     red-when-broken by construction.
# ============================================================================================
mkdir -p "$WORK/binunverif"
cat > "$WORK/binunverif/gh" <<'STUB'
#!/bin/bash
sub="$1"
if [ "$sub" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$sub" = "repo" ] && [ "$2" = "view" ]; then echo "tester/repo"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then
  has_cursor=0
  for a in "$@"; do case "$a" in cursor=*) has_cursor=1 ;; esac; done
  if [ "$has_cursor" = 1 ]; then cat "$FIX/page2.json"; else cat "$FIX/page1.json"; fi
  exit 0
fi
# every native blocked_by lookup FAILS (a board-wide dependencies API outage)
if [ "$sub" = "api" ]; then
  for a in "$@"; do case "$a" in */dependencies/blocked_by) echo "dependencies API down" >&2; exit 1 ;; esac; done
fi
echo "binunverif: unhandled $*" >&2; exit 99
STUB
chmod +x "$WORK/binunverif/gh"

DRU="$(PATH="$WORK/binunverif:$PATH" python3 "$DRAIN" --backend github --project 7 --owner tester --repo "$WORK" 2>/dev/null)"; rcu=$?
[ "$rcu" = "2" ] \
  || fail "all-candidates-unverifiable drain must exit 2 (got $rcu), never exit 0 — the silent blind-drain"
printf '%s' "$DRU" | grep -qx "drain: unknown" \
  || fail "all-candidates-unverifiable drain must report 'drain: unknown' (got: $(printf '%s' "$DRU" | tr '\n' '|'))"
printf '%s' "$DRU" | grep -qx "drain: complete" \
  && fail "all-candidates-unverifiable drain must NEVER report 'drain: complete' (the false-clean Blocker this guards)"

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
# MALFORMED/anomalous graphql (gh exits 0 but the board shape is absent / carries errors) MUST
# fail-closed exit 2 — never coerce to an empty board, the silent "blind drain" this reader kills.
# The fixtures, in order, exercise every fail-closed branch in fetch_items(). HOW each is
# red-when-broken differs, so the assertions differ (each entry below is "fixture|||exact-stderr",
# an empty stderr field = exit-code-only):
#   1. graphql `errors` payload            → errors branch. Dropping THIS guard does NOT return an
#      empty board: data.get("data") is None → node is None → it falls through to the missing-
#      node.items guard → still exit 2, but a DIFFERENT message. So exit==2 alone would pass for the
#      WRONG reason; we ALSO assert the exact "graphql errors:" stderr (only the errors branch emits
#      it) → genuinely red-when-broken in isolation.
#   2. node == null                        → missing node.items branch. Drop it → node["items"]
#      raises TypeError → exit 1 ≠ 2 → red via the exit code alone.
#   3. items.nodes absent                  → missing items.nodes branch. Drop it → `for n in nodes`
#      over None raises → exit 1 ≠ 2 → red via the exit code alone.
#   4. pageInfo absent                     → missing items.pageInfo branch. Drop it → page.get(...)
#      on None raises → exit 1 ≠ 2 → red via the exit code alone.
#   5. pageInfo present, hasNextPage MISSING→ non-bool branch: a bare `if page.get("hasNextPage")`
#      reads a missing/null hasNextPage as falsy → "last page" → a silently TRUNCATED board exit 0;
#      the isinstance(...bool) guard fail-closes it → red via the exit code alone.
#   6. hasNextPage=true but endCursor=null → null-endCursor branch. Dropping THIS guard does NOT
#      return an empty board: cursor stays null, the page never advances, and the loop spins to the
#      MAX_PAGES backstop → still exit 2, but the MAX_PAGES message. So exit==2 alone would pass for
#      the WRONG reason; we ALSO assert the exact "hasNextPage=true but no endCursor" stderr (MAX_PAGES
#      emits a different message) → genuinely red-when-broken in isolation. GitHub always pairs a true
#      hasNextPage with an endCursor, so a true-but-null cursor is anomalous → fail-closed rather than
#      silently return the PARTIAL first page (the `if not cursor:` raise).
# (MAX_PAGES exhaustion itself is the one branch left unstubbed — correct-by-inspection, needs 1000+
# valid pages each advancing the cursor.)
for entry in \
  '{"errors":[{"message":"boom"}]}|||idc-gh-board: graphql errors:' \
  '{"data":{"node":null}}|||' \
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false}}}}}|||' \
  '{"data":{"node":{"items":{"nodes":[]}}}}|||' \
  '{"data":{"node":{"items":{"pageInfo":{"endCursor":"x"},"nodes":[]}}}}|||' \
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}|||idc-gh-board: paginated board read: hasNextPage=true but no endCursor'; do
  bad="${entry%%|||*}"; want="${entry#*|||}"
  err="$(BADGQL="$bad" PATH="$WORK/binbad:$PATH" python3 "$BOARD" --owner tester --project 7 --repo "$WORK" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = "2" ] || fail "a malformed graphql response must fail-closed exit 2, never an empty board: $bad (got $rc)"
  if [ -n "$want" ]; then
    printf '%s' "$err" | grep -qF "$want" \
      || fail "fixture must fail-closed with its SPECIFIC guard message '$want' (got stderr: '$err') — removing only that guard falls through to a DIFFERENT exit-2 path, so an exit-only check would pass for the wrong reason"
  fi
done
# positive control (not over-strict): a LEGIT empty board (nodes: []) is NOT an error → exit 0, 0 items.
emptyout="$(BADGQL='{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' PATH="$WORK/binbad:$PATH" python3 "$BOARD" --owner tester --project 7 --repo "$WORK" 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] || fail "a legit empty board (nodes: []) must exit 0, not fail-closed (over-strict parse)"
[ "$(printf '%s' "$emptyout" | jq '.items | length')" = "0" ] || fail "a legit empty board must yield 0 items"

echo "PASS: idc_gh_board.py paginates the whole board (135/135 across 2 pages); skill read patterns + github drain see the cross-page frontier (201 203 207 209, blocked-aware, control-char safe, legacy absent-Stage default, per-issue fail-closed on #210); pure predicate green past index 30; fail-closed on unreadable board"
