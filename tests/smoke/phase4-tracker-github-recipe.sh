#!/bin/bash
# Phase 4 (github tracker recipe robustness) smoke.
#
# Guards the SHIPPED github recipe (skills/idc-tracker-github/SKILL.md), extracted and run against a
# `gh` stub — coupling this test to the real file, not a paraphrase. Three invariants:
#   1. itemid/query read the WHOLE board via the shared paginating helper `idc_gh_board.py`
#      (`board_json`), so a board past gh's 30-item first page is never truncated (the 3.1.4 fix).
#      The helper emits ASCII-escaped JSON, so the downstream `jq` is control-char-SAFE — an issue
#      title/body carrying a raw control char (U+0000–U+001F) arrives over the GraphQL transport
#      already escaped and never chokes a strict external jq (the historic blank-id failure).
#   2. setField GUARDS the resolved item/option id and `die_gh`s before mutating, so a blank id
#      (issue not on the board) never reaches updateProjectV2ItemFieldValue as ''.
#   3. itemid integer-guards its bare-interpolated number arg (no raw-jq injection / select-all).
# The cross-page pagination itself is proven hermetically in phase4-github-pagination.sh; this file
# proves the EXTRACTED recipe wires through the paginating reader and keeps its guards.
#
# Hermetic: no live GitHub — a PATH `gh` stub emulates project-view (node id), api-graphql (the
# board), field-list (options), and item-edit. The real idc_gh_board.py runs against that stub
# (CLAUDE_PLUGIN_ROOT is exported so the recipe's ${CLAUDE_PLUGIN_ROOT}/… path resolves). Uses `jq`.
# Usage: bash tests/smoke/phase4-tracker-github-recipe.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN/skills/idc-tracker-github/SKILL.md"
BOARD="$PLUGIN/scripts/idc_gh_board.py"
fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq not available (required to emulate gh --jq and the recipe's downstream jq)"
[ -f "$SKILL" ] || fail "skill not found: $SKILL"
[ -f "$BOARD" ] || fail "paginating reader not found: $BOARD (the recipe reads through it)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FIX="$WORK"
export GH_LOG="$WORK/gh.log"
: > "$GH_LOG"

# ---------------------------------------------------------------------------------------------
# Board fixture as a GraphQL response: issue #31's title carries a raw control byte (escaped 
# over the transport, the exact historic failure trigger), #32 is clean. Single page (the
# cross-page case is phase4-github-pagination.sh). Plus a field fixture for optid.
# ---------------------------------------------------------------------------------------------
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
def node(num, item_id, title):
    return {"id": item_id, "fieldValues": {"nodes": []},
            "content": {"__typename": "Issue", "number": num, "title": title}}
resp = {"data": {"node": {"items": {
    "pageInfo": {"hasNextPage": False, "endCursor": None},
    "nodes": [node(31, "PVTI_aaa", "line1line2"), node(32, "PVTI_bbb", "ok")]}}}}
open(os.path.join(work, "graphql.json"), "w").write(json.dumps(resp))
open(os.path.join(work, "fields-clean.json"), "w").write(json.dumps(
    {"fields": [{"name": "Status", "options": [{"name": "Done", "id": "opt_done"},
                                               {"name": "Todo", "id": "opt_todo"}]}]}))
PY

# ---------------------------------------------------------------------------------------------
# gh stub on PATH:
#   project view … --jq .id        → the project node id (PVT_test)
#   api graphql …                  → the board fixture (idc_gh_board parses it in-process)
#   project field-list … --jq <e>  → jq <e> on the fields fixture (optid path)
#   project item-edit --id <IID> … → fail loudly + log if <IID> is empty (the '' bug)
# ---------------------------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
sub="$1"
if [ "$sub" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then cat "$FIX/graphql.json"; exit 0; fi
has_jq=0; jqexpr=""; editid="__UNSET__"
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[$i]}" in
    --jq) has_jq=1; jqexpr="${args[$((i+1))]}" ;;
    --id) editid="${args[$((i+1))]}" ;;
  esac
done
case "$sub" in
  project)
    case "$2" in
      field-list)
        if [ "$has_jq" = 1 ]; then jq -r "$jqexpr" "$FIX/fields-clean.json"; else cat "$FIX/fields-clean.json"; fi ;;
      item-edit)
        if [ -z "$editid" ] || [ "$editid" = "__UNSET__" ]; then
          echo "GraphQL: Could not resolve to a node with the global id of '' (updateProjectV2ItemFieldValue)" >&2
          echo "ITEM_EDIT_EMPTY_ID" >> "$GH_LOG"; exit 1
        fi
        echo "ITEM_EDIT_OK $editid" >> "$GH_LOG"; echo "edited $editid"; exit 0 ;;
      *) echo "gh stub: unhandled project '$2'" >&2; exit 99 ;;
    esac ;;
  *) echo "gh stub: unhandled '$sub'" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# ---------------------------------------------------------------------------------------------
# Extract the SHIPPED recipe from SKILL.md (couples this test to the real file).
# ---------------------------------------------------------------------------------------------
extract_fn() {  # $1 = function name; grabs `fn() {` … first line ending `; }`
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { grab=1 }
    grab { print }
    grab && /; \}[[:space:]]*$/ { exit }
  ' "$SKILL"
}
extract_setfield() {
  awk '
    /^IID="\$\(itemid/ { grab=1 }
    grab { print }
    grab && /single-select-option-id.*\|\| die_gh/ { exit }
  ' "$SKILL"
}

BOARD_JSON_SRC="$(extract_fn board_json)"
ITEMID_SRC="$(extract_fn itemid)"
OPTID_SRC="$(extract_fn optid)"
SETFIELD_SRC="$(extract_setfield)"
[ -n "$BOARD_JSON_SRC" ] || fail "could not extract board_json() from SKILL.md (paginating reader not wired?)"
[ -n "$ITEMID_SRC" ]     || fail "could not extract itemid() from SKILL.md (recipe shape changed?)"
[ -n "$OPTID_SRC" ]      || fail "could not extract optid() from SKILL.md (recipe shape changed?)"
[ -n "$SETFIELD_SRC" ]   || fail "could not extract the setField guard block from SKILL.md"

# Sanity: the WHOLE-BOARD reads go through the paginating helper, never a bare unpaginated item-list.
printf '%s\n' "$BOARD_JSON_SRC" | grep -q 'idc_gh_board\.py' \
  || fail "board_json() must read via the paginating idc_gh_board.py helper (regressed to gh project item-list?)"
printf '%s\n' "$ITEMID_SRC" | grep -q 'board_json' \
  || fail "itemid() must resolve over the whole board via board_json (regressed to an unpaginated read?)"
grep -qE '^[[:space:]]*gh project item-list' "$SKILL" \
  && fail "SKILL.md still uses a bare 'gh project item-list' board read (truncates at 30 — must page via idc_gh_board.py)"
# Sanity: setField must guard BOTH resolved ids before mutating.
printf '%s\n' "$SETFIELD_SRC" | grep -q '\[ -n "\$IID" \] || die_gh' || fail "setField is missing the empty item-id guard"
printf '%s\n' "$SETFIELD_SRC" | grep -q '\[ -n "\$OID" \] || die_gh' || fail "setField is missing the empty option-id guard"
# Sanity: NO board read pipes gh's --format json text to an external jq (the store-and-reparse bug).
grep -E 'gh project (item-list|field-list)[^|]*--format json[^|]*\| *jq' "$SKILL" \
  && fail "a board read still pipes gh --format json to external jq (store-and-reparse — the F1 fragility)"
# Sanity: an explicit retire helper exists and steers away from hand-rolled store-and-reparse.
grep -q '\*\*retire(pointer, reason)\*\*' "$SKILL" || fail "skill is missing the explicit retire convenience (agents will hand-roll the fragile retire)"
grep -qi 'never hand-roll the' "$SKILL"            || fail "retire recipe must warn against the hand-rolled store-and-reparse pattern"

# Assemble a runnable harness from the EXTRACTED shipped source + minimal stubs. The real
# idc_gh_board.py runs (CLAUDE_PLUGIN_ROOT exported), so this exercises the true paginating read.
HARNESS="$WORK/harness.sh"
{
  echo 'set -uo pipefail'
  echo 'PROJ="7"; OWNER="tester"'
  echo 'fid() { echo "FIELD_NODE_ID"; }'
  # die_gh halts the op (exit 1) per the skill's Fail-closed posture — a mid-recipe guard must stop.
  echo 'die_gh() { echo "{\"backend\":\"github\",\"op\":\"setField\",\"error\":\"blank id refused\"}" >&2; exit 1; }'
  printf '%s\n' "$BOARD_JSON_SRC"
  printf '%s\n' "$ITEMID_SRC"
  printf '%s\n' "$OPTID_SRC"
  echo 'setField() { local NUM="$1" FIELD="$2" VALUE="$3"'
  printf '%s\n' "$SETFIELD_SRC"
  echo '}'
} > "$HARNESS"

run_setfield() { ( export PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN"; source "$HARNESS"; setField "$@" ); }
run_itemid()   { ( export PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN"; source "$HARNESS"; itemid  "$@" ); }

# ---- Case A: issue ON the board (control-char title) → resolves the real id → item-edit succeeds --
: > "$GH_LOG"
if ! errA="$(run_setfield 31 Status Done 2>&1 >/dev/null)"; then
  fail "case A: setField for an on-board issue should succeed (got error: $errA) — is the paginating read resolving the id?"
fi
grep -q '^ITEM_EDIT_OK PVTI_aaa$' "$GH_LOG" || fail "case A: item-edit was not called with the resolved id PVTI_aaa (log: $(cat "$GH_LOG"))"
grep -q 'ITEM_EDIT_EMPTY_ID' "$GH_LOG" && fail "case A: item-edit was somehow called with a blank id"

# ---- Case B: issue NOT on the board → empty id → guard fires, item-edit NEVER called ----------
: > "$GH_LOG"
if run_setfield 999 Status Done >/dev/null 2>"$WORK/errB"; then
  fail "case B: setField for an off-board issue must FAIL loudly (it returned success — empty id was swallowed)"
fi
grep -q 'ITEM_EDIT_EMPTY_ID' "$GH_LOG" && fail "case B: GraphQL mutation ran with a blank id — the empty-id guard did not fire (the F1 bug)"
grep -q 'ITEM_EDIT_OK' "$GH_LOG"       && fail "case B: item-edit should not have run at all for an off-board issue"
grep -q 'backend.*github' "$WORK/errB" || fail "case B: die_gh did not surface a structured non-zero error"

# ---- Case C (injection-hardening): itemid must REJECT a non-integer/empty arg, not inject jq -----
# itemid interpolates $1 BARE into the jq (select(.content.number==$1)); a non-integer like
# '31 or true' would inject raw jq and select ALL items. itemid integer-guards $1 and die_gh instead.
run_itemid '31 or true' >/dev/null 2>&1 \
  && fail "case C: itemid accepted a non-integer arg (raw-jq injection / select-all) — the integer guard is missing"
run_itemid '' >/dev/null 2>&1 \
  && fail "case C: itemid accepted an empty arg — the integer guard is missing"
cid="$(run_itemid 31 2>/dev/null)" || fail "case C: itemid rejected a VALID integer arg — guard too strict"
[ "$cid" = "PVTI_aaa" ] || fail "case C: itemid 31 must still resolve PVTI_aaa over the control-char-title board (got '$cid')"

echo "PASS: github recipe reads the WHOLE board via the paginating idc_gh_board.py (control-char-safe), setField refuses a blank id, and itemid rejects non-integer args"
