#!/bin/bash
# Phase 4 (github tracker recipe robustness) smoke — overnight-e2e-hardening F1.
#
# Roots out the swallowed-retirement bug from the v3.0.0 autorun e2e: the github backend resolved
# project-item / option ids by piping `gh project … --format json` to an EXTERNAL jq. GitHub emits
# issue-body text with raw control chars (U+0000–U+001F); external jq rejects them
# (`parse error: control characters … must be escaped`), so the id resolved EMPTY and
# `updateProjectV2ItemFieldValue` failed on the blank global id `''` — while the lane reported
# "retired → Done". Two root-cause fixes (both in skills/idc-tracker-github/SKILL.md):
#   1. read via gh's BUILT-IN `--jq` (gh applies the filter to live data — never round-trips body
#      text through a strict external jq);
#   2. setField GUARDS the resolved item/option id and `die_gh`s before mutating, so a blank id
#      never reaches GraphQL.
#
# This test is RED-WHEN-BROKEN against the SHIPPED recipe: it EXTRACTS the real itemid/optid/setField
# bash from SKILL.md and runs it against a `gh` stub. Revert `--jq`→`| jq` and case A fails; remove
# the empty-id guard and case B fails. It also reproduces the bug class directly (external jq on a
# raw-control-char fixture) as the red baseline.
#
# Hermetic: no live GitHub — a PATH `gh` stub emulates the two relevant output paths. Uses `jq`.
# Usage: bash tests/smoke/phase4-tracker-github-recipe.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN/skills/idc-tracker-github/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq not available (required to emulate gh --jq and the external-jq baseline)"
[ -f "$SKILL" ] || fail "skill not found: $SKILL"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------
# Fixtures: one board item's body carries a raw control byte (0x01) — the exact failure trigger.
#  - RAW_ITEMS   = the data emitted as raw text with an UNESCAPED control byte — what gh's
#                  `--format json` TEXT output looked like, and what external jq chokes on.
#  - CLEAN_ITEMS = the same data as the in-memory structure gh's gojq (`--jq`) operates on —
#                  derived by stripping the control bytes, so it is valid JSON. (No literal
#                  control char is typed into this source file.)
# ---------------------------------------------------------------------------------------------
export CLEAN_ITEMS="$WORK/items-clean.json"
export RAW_ITEMS="$WORK/items-raw.json"
export CLEAN_FIELDS="$WORK/fields-clean.json"
export GH_LOG="$WORK/gh.log"
: > "$GH_LOG"

printf '{"items":[{"content":{"number":31,"body":"line1\001line2"},"id":"PVTI_aaa"},{"content":{"number":32,"body":"ok"},"id":"PVTI_bbb"}]}' > "$RAW_ITEMS"
tr -d '\000-\037' < "$RAW_ITEMS" > "$CLEAN_ITEMS"
printf '%s' '{"fields":[{"name":"Status","options":[{"name":"Done","id":"opt_done"},{"name":"Todo","id":"opt_todo"}]}]}' > "$CLEAN_FIELDS"

# ---------------------------------------------------------------------------------------------
# Red baseline: the OLD pattern (`gh … --format json | jq`) on the raw-control-char body FAILS.
# This proves the fixture reproduces the real bug class — external jq cannot parse it.
# ---------------------------------------------------------------------------------------------
if out="$(jq -r '.items[] | select(.content.number==31) | .id' "$RAW_ITEMS" 2>/dev/null)" && [ -n "$out" ]; then
  fail "red baseline broken: external jq parsed the raw-control-char fixture (got '$out') — fixture no longer reproduces the bug"
fi

# ---------------------------------------------------------------------------------------------
# gh stub on PATH:
#   project item-list … --format json --jq <expr>   → gh built-in path: jq <expr> on CLEAN fixture
#   project item-list … --format json   (no --jq)   → gh TEXT path: emit RAW fixture (control char)
#   project field-list … (same two paths, fields fixture)
#   project item-edit --id <IID> …                  → fail loudly + log if <IID> is empty (the '' bug)
# ---------------------------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
# crude arg scan
sub="$2"; has_jq=0; jqexpr=""; editid="__UNSET__"
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[$i]}" in
    --jq) has_jq=1; jqexpr="${args[$((i+1))]}" ;;
    --id) editid="${args[$((i+1))]}" ;;
  esac
done
case "$sub" in
  item-list)
    if [ "$has_jq" = 1 ]; then jq -r "$jqexpr" "$CLEAN_ITEMS"; else cat "$RAW_ITEMS"; fi ;;
  field-list)
    if [ "$has_jq" = 1 ]; then jq -r "$jqexpr" "$CLEAN_FIELDS"; else cat "$CLEAN_FIELDS"; fi ;;
  item-edit)
    if [ -z "$editid" ] || [ "$editid" = "__UNSET__" ]; then
      echo "GraphQL: Could not resolve to a node with the global id of '' (updateProjectV2ItemFieldValue)" >&2
      echo "ITEM_EDIT_EMPTY_ID" >> "$GH_LOG"; exit 1
    fi
    echo "ITEM_EDIT_OK $editid" >> "$GH_LOG"; echo "edited $editid"; exit 0 ;;
  *) echo "gh stub: unhandled '$sub'" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# ---------------------------------------------------------------------------------------------
# Extract the SHIPPED recipe from SKILL.md (couples this test to the real file).
#   - itemid()/optid(): the one-statement helper defs (line + `\` continuation, ending `; }`).
#   - the setField guard block: from `IID="$(itemid …` through the item-edit `… || die_gh`.
# ---------------------------------------------------------------------------------------------
HARNESS="$WORK/harness.sh"
extract_fn() {  # $1 = function name
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

ITEMID_SRC="$(extract_fn itemid)"
OPTID_SRC="$(extract_fn optid)"
SETFIELD_SRC="$(extract_setfield)"
[ -n "$ITEMID_SRC" ]   || fail "could not extract itemid() from SKILL.md (recipe shape changed?)"
[ -n "$OPTID_SRC" ]    || fail "could not extract optid() from SKILL.md (recipe shape changed?)"
[ -n "$SETFIELD_SRC" ] || fail "could not extract the setField guard block from SKILL.md"

# Sanity: the extracted helpers must use gh's built-in --jq, not an external `| jq` pipe.
printf '%s\n' "$ITEMID_SRC" | grep -q -- '--jq' || fail "extracted itemid() does not use gh --jq (regressed to external jq?)"
printf '%s\n' "$ITEMID_SRC" | grep -q '| jq'    && fail "extracted itemid() still pipes to external jq"
# Sanity: setField must guard BOTH resolved ids before mutating.
printf '%s\n' "$SETFIELD_SRC" | grep -q '\[ -n "\$IID" \] || die_gh' || fail "setField is missing the empty item-id guard"
printf '%s\n' "$SETFIELD_SRC" | grep -q '\[ -n "\$OID" \] || die_gh' || fail "setField is missing the empty option-id guard"
# Sanity: NO board read pipes gh's --format json text to an external jq (the store-and-reparse bug).
grep -E 'gh project (item-list|field-list)[^|]*--format json[^|]*\| *jq' "$SKILL" \
  && fail "a board read still pipes gh --format json to external jq (store-and-reparse — the F1 fragility)"
# Sanity: an explicit retire helper exists and steers away from hand-rolled store-and-reparse.
grep -q '\*\*retire(pointer, reason)\*\*' "$SKILL" || fail "skill is missing the explicit retire convenience (agents will hand-roll the fragile retire)"
grep -qi 'never hand-roll the' "$SKILL"            || fail "retire recipe must warn against the hand-rolled store-and-reparse pattern"

# Assemble a runnable harness from the EXTRACTED shipped source + minimal stubs.
{
  echo 'set -uo pipefail'
  echo 'PROJ="PVT_test"; OWNER="tester"'
  echo 'fid() { echo "FIELD_NODE_ID"; }'
  # die_gh halts the op (exit 1) per the skill's Fail-closed posture — a mid-recipe guard must stop.
  echo 'die_gh() { echo "{\"backend\":\"github\",\"op\":\"setField\",\"error\":\"blank id refused\"}" >&2; exit 1; }'
  printf '%s\n' "$ITEMID_SRC"
  printf '%s\n' "$OPTID_SRC"
  echo 'setField() { local NUM="$1" FIELD="$2" VALUE="$3"'
  printf '%s\n' "$SETFIELD_SRC"
  echo '}'
} > "$HARNESS"

run_setfield() { ( export PATH="$WORK/bin:$PATH"; source "$HARNESS"; setField "$@" ); }
run_itemid()   { ( export PATH="$WORK/bin:$PATH"; source "$HARNESS"; itemid  "$@" ); }

# ---- Case A: issue ON the board → resolves the real id → item-edit succeeds -------------------
: > "$GH_LOG"
if ! errA="$(run_setfield 31 Status Done 2>&1 >/dev/null)"; then
  fail "case A: setField for an on-board issue should succeed (got error: $errA) — is --jq resolving the id?"
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
# The --jq conversion interpolates $1 BARE into the jq program (select(.content.number==$1)); a
# non-integer arg like '31 or true' would otherwise inject raw jq and select ALL items. itemid must
# integer-guard $1 and die_gh (non-zero) instead — so a malformed/board-derived NUM never becomes a
# jq injection. (optid/query interpolate fixed v2 enums and are controlled-inputs-only by contract.)
run_itemid '31 or true' >/dev/null 2>&1 \
  && fail "case C: itemid accepted a non-integer arg (raw-jq injection / select-all) — the integer guard is missing"
run_itemid '' >/dev/null 2>&1 \
  && fail "case C: itemid accepted an empty arg — the integer guard is missing"
cid="$(run_itemid 31 2>/dev/null)" || fail "case C: itemid rejected a VALID integer arg — guard too strict"
[ "$cid" = "PVTI_aaa" ] || fail "case C: itemid 31 must still resolve PVTI_aaa (got '$cid')"

echo "PASS: github tracker recipe resolves ids via gh --jq (control-char-robust), setField refuses a blank id, and itemid rejects non-integer args"
