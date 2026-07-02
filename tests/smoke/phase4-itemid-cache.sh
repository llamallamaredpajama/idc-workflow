#!/bin/bash
# Phase 4 (item-id cache) smoke — the O(waves×board) API-cost fix (issue #98, design §C.1).
#
# ROOT CAUSE this guards: SKILL.md::itemid() re-downloaded the WHOLE board (board_json) on EVERY field
# mutation, so a build wave of M mutations cost O(M × board-pages) GraphQL reads (graphql-cost.md sink
# #1: ~120 board reads/wave). The fix: `idc_gh_board.py --emit-idmap` emits the whole board's
# {issue#→item_id} map from ONE paginated read; the orchestrator exports that file as $IDC_ITEMID_CACHE
# once per wave; itemid() then resolves from it WITHOUT a board read. A cache MISS (number not in the
# table), an unset cache, or an empty cache file falls back to the live board read (backward
# compatible), so a stale/absent cache never mutates with a blank id (the empty-id die_gh guard holds).
#
# Hermetic: no live GitHub — a PATH `gh` stub serves a 2-page board and LOGS every graphql fetch. The
# cache-HIT path must produce ZERO graphql fetches (the whole point); the miss/unset/empty paths must
# still read the board. Every assertion is red-when-broken by construction (reverts noted inline). The
# real idc_gh_board.py runs against the stub (CLAUDE_PLUGIN_ROOT exported), and the itemid()/board_json()
# recipe is EXTRACTED from the shipped SKILL.md (couples this test to the real file, not a paraphrase).
#
# Usage: bash tests/smoke/phase4-itemid-cache.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN/skills/idc-tracker-github/SKILL.md"
BOARD="$PLUGIN/scripts/idc_gh_board.py"
fail() { echo "FAIL: $1"; exit 1; }

# grep -c prints the count (0 included) AND exits 1 on zero matches — a `|| echo 0` would DOUBLE the
# output ("0\n0"). Capture the printed count and default an empty capture (missing file) to 0.
gq_count() { local c; c="$(grep -c graphql "$WORK/gh.log" 2>/dev/null)"; printf '%s' "${c:-0}"; }

command -v jq >/dev/null 2>&1 || fail "jq required (the recipe's fallback board read pipes to jq)"
[ -f "$SKILL" ] || fail "skill not found: $SKILL"
[ -f "$BOARD" ] || fail "paginating reader not found: $BOARD (--emit-idmap lives here)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FIX="$WORK"

# --- 2-page board fixture: #101 (page1); #201,#202 (page2). item id = PVTI_<num>. -----------------
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
def node(num): return {"id": f"PVTI_{num}", "fieldValues": {"nodes": []},
                       "content": {"__typename": "Issue", "number": num, "title": f"issue {num}"}}
def page(nodes, hn, ec): return {"data": {"node": {"items": {
    "pageInfo": {"hasNextPage": hn, "endCursor": ec}, "nodes": nodes}}}}
open(os.path.join(work, "page1.json"), "w").write(json.dumps(page([node(101)], True, "CUR1")))
open(os.path.join(work, "page2.json"), "w").write(json.dumps(page([node(201), node(202)], False, None)))
PY

# --- gh stub: project view -> node id; api graphql -> page1/page2 by cursor, LOGGED; api rate_limit
#     answered benignly (the #99 preflight calls it and must never block or error this test). -------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
sub="$1"
if [ "$sub" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then
  cur=""; for a in "$@"; do case "$a" in cursor=*) cur="${a#cursor=}" ;; esac; done
  echo "graphql" >> "$FIX/gh.log"
  if [ -n "$cur" ]; then cat "$FIX/page2.json"; else cat "$FIX/page1.json"; fi
  exit 0
fi
if [ "$sub" = "api" ]; then for a in "$@"; do case "$a" in rate_limit) echo '{}'; exit 0 ;; esac; done; fi
echo "gh stub: unhandled $*" >&2; exit 99
STUB
chmod +x "$WORK/bin/gh"

# ============================================================================================
# 1. --emit-idmap emits the whole-board NUM<TAB>item_id map from ONE paginated read (both pages).
# ============================================================================================
: > "$WORK/gh.log"
MAP="$(PATH="$WORK/bin:$PATH" python3 "$BOARD" --owner tester --project 7 --repo "$WORK" --emit-idmap)" \
  || fail "idc_gh_board.py --emit-idmap exited non-zero"
got="$(printf '%s\n' "$MAP" | awk -F'\t' 'NF==2 {print $1"="$2}' | sort | tr '\n' ' ')"
[ "$got" = "101=PVTI_101 201=PVTI_201 202=PVTI_202 " ] \
  || fail "--emit-idmap must print NUM<TAB>item_id for every issue across ALL pages (got '$got')"
gq="$(gq_count)"
[ "$gq" = "2" ] \
  || fail "--emit-idmap must page the whole board once (expected 2 graphql fetches, got $gq)"

# ============================================================================================
# Extract the SHIPPED itemid()/board_json() recipe from SKILL.md (couples to the real file).
# ============================================================================================
extract_fn() {  # $1 = fn name; grabs `fn() {` … first line ending `; }`
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { grab=1 }
    grab { print }
    grab && /; \}[[:space:]]*$/ { exit }' "$SKILL"
}
BOARD_JSON_SRC="$(extract_fn board_json)"
ITEMID_SRC="$(extract_fn itemid)"
[ -n "$BOARD_JSON_SRC" ] || fail "could not extract board_json() from SKILL.md"
[ -n "$ITEMID_SRC" ]     || fail "could not extract itemid() from SKILL.md (recipe shape changed?)"
# The cache branch must be present in the SHIPPED itemid (RED-WHEN-BROKEN: revert it → this fails).
printf '%s\n' "$ITEMID_SRC" | grep -q 'IDC_ITEMID_CACHE' \
  || fail "itemid() must consume the IDC_ITEMID_CACHE cache file (the #98 O(waves×board) fix is missing)"
# … and MUST still fall back to board_json (RED-WHEN-BROKEN: drop the fallback → backward compat lost).
printf '%s\n' "$ITEMID_SRC" | grep -q 'board_json' \
  || fail "itemid() must still fall back to board_json on a cache miss / unset cache (backward compat)"

# Assemble a runnable harness from the EXTRACTED shipped source + minimal stubs.
HARNESS="$WORK/harness.sh"
{
  echo 'set -uo pipefail'
  echo 'PROJ=7; OWNER=tester'
  echo 'die_gh() { echo "{\"backend\":\"github\",\"op\":\"itemid\",\"error\":\"blank id / bad arg refused\"}" >&2; exit 1; }'
  printf '%s\n' "$BOARD_JSON_SRC"
  printf '%s\n' "$ITEMID_SRC"
} > "$HARNESS"
run_itemid()   { ( export PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN" FIX="$WORK" IDC_ITEMID_CACHE="$1"; source "$HARNESS"; shift; itemid "$@" ); }
run_nocache()  { ( export PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN" FIX="$WORK"; unset IDC_ITEMID_CACHE; source "$HARNESS"; itemid "$@" ); }

# Build the cache file from the REAL --emit-idmap output (dogfoods the emitted format), but DROP #101
# so #101 is a genuine cache MISS while #201/#202 are hits.
CACHE="$WORK/idmap.tsv"
printf '%s\n' "$MAP" | awk -F'\t' '$1!=101' > "$CACHE"

# ============================================================================================
# 2. CACHE HIT (#201 present in the map) → resolves the id with ZERO board reads (the #98 fix).
#    RED-WHEN-BROKEN: revert the cache branch in itemid() → it board-reads → graphql count > 0.
# ============================================================================================
: > "$WORK/gh.log"
cid="$(run_itemid "$CACHE" 201)" || fail "case 2: cache-hit itemid should succeed"
[ "$cid" = "PVTI_201" ] || fail "case 2: cache-hit itemid must resolve PVTI_201 (got '$cid')"
gq="$(gq_count)"
[ "$gq" = "0" ] \
  || fail "case 2: a cache HIT must do NO board read (got $gq graphql fetches) — the O(waves×board) fix"

# ============================================================================================
# 3. CACHE MISS (#101 not in the map) → falls back to a live board read and resolves (never '').
# ============================================================================================
: > "$WORK/gh.log"
cid="$(run_itemid "$CACHE" 101)" || fail "case 3: cache-miss itemid should fall back and succeed"
[ "$cid" = "PVTI_101" ] || fail "case 3: cache-miss itemid must fall back to the board read (got '$cid')"
gq="$(gq_count)"
[ "$gq" -ge 1 ] \
  || fail "case 3: a cache MISS must fall back to a live board read (got 0) — never mutate with a blank id"

# ============================================================================================
# 4. UNSET cache → live board read (backward compatible with every pre-#98 caller).
# ============================================================================================
: > "$WORK/gh.log"
cid="$(run_nocache 202)" || fail "case 4: no-cache itemid should read the board"
[ "$cid" = "PVTI_202" ] || fail "case 4: no-cache itemid must resolve via the board read (got '$cid')"
gq="$(gq_count)"
[ "$gq" -ge 1 ] || fail "case 4: an unset cache must do a live board read (backward compat) — got 0"

# ============================================================================================
# 5. EMPTY cache file → the `[ -s ]` guard skips it → falls back to the board read.
# ============================================================================================
EMPTY="$WORK/empty.tsv"; : > "$EMPTY"
: > "$WORK/gh.log"
cid="$(run_itemid "$EMPTY" 201)" || fail "case 5: empty-cache itemid should fall back"
[ "$cid" = "PVTI_201" ] || fail "case 5: empty-cache itemid must fall back to the board read (got '$cid')"

# ============================================================================================
# 6. The integer guard STILL fires before the cache branch (no raw-jq injection via a cache lookup).
# ============================================================================================
run_itemid "$CACHE" '201 or true' >/dev/null 2>&1 \
  && fail "case 6: itemid must still reject a non-integer arg (injection guard precedes the cache lookup)"
run_itemid "$CACHE" '' >/dev/null 2>&1 \
  && fail "case 6: itemid must still reject an empty arg"

echo "PASS: --emit-idmap emits the whole-board id map from one read; itemid() resolves a cache HIT with zero board reads, falls back on miss/unset/empty, and keeps its integer guard"
