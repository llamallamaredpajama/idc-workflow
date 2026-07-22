#!/bin/bash
# idc-assert-class: behavior
# foundation-failclosed-evidence.sh — U2 foundation witness for fail-closed lifecycle evidence.
#
# Covers the gaps the audit named and the brief requires on the SAME real paths the workflow uses:
#   * Stop closeout never turns the bounded repair budget into permission to falsely finish.
#   * A code-reviews verdict must carry a source-owned validator witness; a stale or wrong-source
#     witness is refused.
#
# Red-when-broken (MANDATORY, reviewed): restore the old loud-fail-allow branch in the closeout gate,
# or drop the witness checks / repo binding / digest binding in the verdict loader ⇒ this goes RED.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
CLOSEOUT_GATE="$GOV_PLUGIN/scripts/hooks/idc_command_closeout_gate.py"
[ -f "$ENGINE" ] || gov_fail "transition engine not found at $ENGINE"
[ -f "$TRK" ] || gov_fail "filesystem tracker not found at $TRK"
[ -f "$CHECK" ] || gov_fail "review verdict checker not found at $CHECK"
[ -f "$CLOSEOUT_GATE" ] || gov_fail "command closeout gate not found at $CLOSEOUT_GATE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

mkrepo() {
  local repo="$1"
  mkdir -p "$repo/docs/workflow/code-reviews"
  git -C "$repo" init -q -b main >/dev/null 2>&1
  git -C "$repo" config user.email test@example.com >/dev/null 2>&1
  git -C "$repo" config user.name Test >/dev/null 2>&1
  printf 'backend: filesystem\n' > "$repo/docs/workflow/tracker-config.yaml"
  python3 "$TRK" --tracker "$repo/TRACKER.md" init >/dev/null
}
eng() {
  local repo="$1"; shift
  python3 "$ENGINE" --repo "$repo" --backend filesystem --tracker "$repo/TRACKER.md" "$@"
}
closeout_payload() {
  python3 - "$1" "$2" <<'PY'
import json,sys
cwd,sid=sys.argv[1:3]
print(json.dumps({"session_id":sid,"cwd":cwd,"hook_event_name":"Stop","stop_hook_active":False}))
PY
}
blocks() {
  printf '%s' "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null
}
git_common_dir() {
  local repo="$1" gd
  gd="$(git -C "$repo" rev-parse --git-common-dir)"
  case "$gd" in
    /*) printf '%s\n' "$gd" ;;
    *) printf '%s\n' "$repo/$gd" ;;
  esac
}

# ── 1. Stop closeout stays FAIL-CLOSED after the repair budget is exhausted ───────────────────────
R1="$WORK/closeout-bound"
SID1="closeout-foundation-$$"
mkdir -p "$R1"
mkrepo "$R1"
python3 - "$GOV_PLUGIN/scripts/hooks" "$R1" "$SID1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import idc_ledger
ok = idc_ledger.command_start(sys.argv[2], sys.argv[3], "autorun", "0.0.0", "digest", "user")
if not ok:
    raise SystemExit("could not open the active command record")
PY
LOUD_ON=""
for i in 1 2 3 4; do
  ERR="$WORK/closeout-$i.err"
  OUT="$(closeout_payload "$R1" "$SID1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" 2>"$ERR")"
  blocks "$OUT" \
    || fail "(1) closeout gate allowed stop attempt $i for an open command record — the bound must never become permission to falsely finish"
  if grep -qi 'LOUD-FAIL' "$ERR"; then
    [ -z "$LOUD_ON" ] && LOUD_ON="$i"
    [ "$i" -ge 4 ] || fail "(1) closeout gate LOUD-FAILed before the bound was exhausted (try $i)"
  else
    [ "$i" -le 3 ] || fail "(1) closeout gate stopped blocking without LOUD-FAILing on try $i"
  fi
done
[ "$LOUD_ON" = "4" ] || fail "(1) expected the FIRST LOUD-FAIL on the 4th stop, got '${LOUD_ON:-<none>}'"
echo "  ok (1) the Stop closeout gate still blocks on the 4th stop, with the first LOUD-FAIL at the bound"

# ── 2. a STALE code-reviews witness is refused ─────────────────────────────────────────────────────
R2="$WORK/stale-witness"
mkdir -p "$R2"
mkrepo "$R2"
ITEM2="$(gov_seed_item "$R2/TRACKER.md" --title 'build' --stage Buildable --status 'In Progress')" || fail "(2) seed failed"
V2="$R2/docs/workflow/code-reviews/2026-07-22-pr-9-review.json"
cat > "$V2" <<JSON
{"verdict":"PASS","pr":9,"issue":$ITEM2,"findings":[]}
JSON
python3 "$CHECK" "$V2" >/dev/null 2>&1 || fail "(2) validator rejected the baseline verdict"
cat > "$V2" <<JSON
{"verdict":"PASS","pr":9,"issue":$ITEM2,"findings":[],"notes":"stale witness"}
JSON
if eng "$R2" close --num "$ITEM2" --verdict "$V2" --pr 9 >/dev/null 2>&1; then
  fail "(2) engine accepted a code-reviews verdict whose witness went stale after the validator ran"
fi
echo "  ok (2) a stale code-reviews witness is refused"

# ── 3. a WRONG-SOURCE witness is refused ───────────────────────────────────────────────────────────
R3="$WORK/wrong-source-target"
R4="$WORK/wrong-source-foreign"
mkdir -p "$R3" "$R4"
mkrepo "$R3"
mkrepo "$R4"
ITEM3="$(gov_seed_item "$R3/TRACKER.md" --title 'build' --stage Buildable --status 'In Progress')" || fail "(3) target seed failed"
ITEM4="$(gov_seed_item "$R4/TRACKER.md" --title 'build' --stage Buildable --status 'In Progress')" || fail "(3) foreign seed failed"
V3="$R3/docs/workflow/code-reviews/2026-07-22-pr-9-review.json"
V4="$R4/docs/workflow/code-reviews/2026-07-22-pr-9-review.json"
cat > "$V3" <<JSON
{"verdict":"PASS","pr":9,"issue":$ITEM3,"findings":[]}
JSON
cat > "$V4" <<JSON
{"verdict":"PASS","pr":9,"issue":$ITEM4,"findings":[]}
JSON
python3 "$CHECK" "$V4" >/dev/null 2>&1 || fail "(3) validator rejected the foreign verdict"
WG3="$(git_common_dir "$R3")/idc-review-verdict-witnesses.json"
WG4="$(git_common_dir "$R4")/idc-review-verdict-witnesses.json"
[ -f "$WG4" ] || fail "(3) the foreign validator run did not mint its witness file"
cp "$WG4" "$WG3"
if eng "$R3" close --num "$ITEM3" --verdict "$V3" --pr 9 >/dev/null 2>&1; then
  fail "(3) engine accepted a code-reviews witness copied from a different repo"
fi
echo "  ok (3) a wrong-source code-reviews witness is refused"

echo "PASS: fail-closed evidence foundations — Stop closeout never allows a false finish at attempt 4, and code-reviews verdicts reject stale or wrong-source validator witnesses"
