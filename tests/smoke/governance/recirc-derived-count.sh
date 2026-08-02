#!/usr/bin/env bash
set -uo pipefail

# idc-assert-class: behavior
# Red-when-broken (issue #108): the runaway caps (idc_recirc_caps.py) decide over a recirc_count the
# LLM consultant is trusted to bump — a consultant that forgets the bump lets an issue loop past the
# ceiling. The sweep now DERIVES that count from board state: `--derive-recirc-count N` counts the
# DISTINCT Recirculation tickets (ANY Status — retired/Done included) whose idc-recirc-source origin
# names issue N, printed as a bare integer for composition straight into the caps CLI. FAIL-CLOSED:
# an unreadable backend/board exits 2 with NO count (a guard that cannot compute its input must
# never wave the loop on — the caps caller treats non-zero as PARK).

. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
SWEEP="$GOV_PLUGIN/scripts/idc_recirc_sweep.py"

# ── (1) PURE derivation + github collection (hermetic, monkeypatched board) ───────────────────────
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "derived-count unit assertions did not all hold"
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

errs = []
def check(c, msg):
    if not c:
        errs.append(msg)

# PURE: two tickets name #42 (one retired/Done — it still counts), one names #77, none name #55.
tickets = [{"number": 101, "origins": {42}},
           {"number": 102, "origins": {42}},      # the retired one
           {"number": 103, "origins": {77}}]
check(m.derived_recirc_count(42, tickets) == 2, "42 must derive 2 (Done/retired tickets count)")
check(m.derived_recirc_count(77, tickets) == 1, "77 must derive 1")
check(m.derived_recirc_count(55, tickets) == 0, "55 must derive 0")
check(m.origin_issue("#42|finisher") == 42 and m.origin_issue(9) == 9 and m.origin_issue("") is None,
      "origin_issue must prefix-parse '#42|role', bare ints, and reject empties")

# GITHUB collection: only Stage=Recirculation items are counted, ANY status; markers come from bodies.
BOARD = [
    {"stage": "Recirculation", "status": "Done", "id": "PVTI_1", "content": {"number": 101}},
    {"stage": "Recirculation", "status": "Todo", "id": "PVTI_2", "content": {"number": 102}},
    {"stage": "Buildable",     "status": "Todo", "id": "PVTI_3", "content": {"number": 42}},
]
BODIES = {
    "101": '<!-- idc-recirc-source: {"origin": "#42|finisher", "what": "a"} -->',
    "102": '<!-- idc-recirc-source: {"origin": "#42|reviewer", "what": "b"} -->',
}
idc_gh_board.fetch_items = lambda owner, pn, r: BOARD
def gh(args, r):
    if args[:2] == ["issue", "view"]:
        return True, json.dumps({"body": BODIES.get(args[2], "")}), ""
    return True, "", ""
m.gh = gh
tickets = m._github_recirc_tickets("/x", "o", "7")
check(m.derived_recirc_count(42, tickets) == 2,
      f"github derivation for #42 must be 2 (Done ticket counts), got {m.derived_recirc_count(42, tickets)}")
check(m.derived_recirc_count(101, tickets) == 0,
      "the ticket's own number must not count as an origin")

# FAIL-CLOSED: one unreadable ticket body must fail the WHOLE derivation (an under-count would
# un-park a runaway), never return a partial count.
def gh_body_fail(args, r):
    if args[:2] == ["issue", "view"] and args[2] == "102":
        return False, "", "simulated body outage"
    if args[:2] == ["issue", "view"]:
        return True, json.dumps({"body": BODIES.get(args[2], "")}), ""
    return True, "", ""
m.gh = gh_body_fail
try:
    m._github_recirc_tickets("/x", "o", "7")
    errs.append("an unreadable ticket body must raise BoardReadError (fail-closed), not under-count")
except idc_gh_board.BoardReadError:
    pass

if errs:
    for e in errs:
        sys.stderr.write("ASSERT FAILED: " + e + "\n")
    sys.exit(1)
print("ok")
PY

# ── (2) CLI end-to-end on the filesystem backend (markers ride comments there) ────────────────────
T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"

M1='<!-- idc-recirc-source: {"origin": "#5|builder", "what": "scope one"} -->'
M2='<!-- idc-recirc-source: {"origin": "#5|reviewer", "what": "scope two"} -->'
M3='<!-- idc-recirc-source: {"origin": 9, "what": "scope three"} -->'
gov_seed_item "$T" --title 'recirc: one'   --stage Recirculation --status Done --comment "$M1" >/dev/null \
  || fail "could not seed the retired recirc ticket"
gov_seed_item "$T" --title 'recirc: two'   --stage Recirculation --status Todo --comment "$M2" >/dev/null \
  || fail "could not seed the live recirc ticket"
gov_seed_item "$T" --title 'recirc: three' --stage Recirculation --status Todo --comment "$M3" >/dev/null \
  || fail "could not seed the numeric-origin ticket"
gov_seed_item "$T" --title 'not recirc'    --stage Buildable     --status Todo --comment "$M1" >/dev/null \
  || fail "could not seed the non-recirc control issue"

n5="$(python3 "$SWEEP" --repo "$REPO" --tracker "$T" --derive-recirc-count 5)" \
  || fail "--derive-recirc-count 5 exited non-zero on a readable tracker"
[ "$n5" = "2" ] || fail "issue #5 must derive 2 (one retired + one live ticket; the Buildable control never counts), got '$n5'"
n9="$(python3 "$SWEEP" --repo "$REPO" --tracker "$T" --derive-recirc-count 9)" \
  || fail "--derive-recirc-count 9 exited non-zero"
[ "$n9" = "1" ] || fail "issue #9 must derive 1 (a bare numeric origin resolves), got '$n9'"
n8="$(python3 "$SWEEP" --repo "$REPO" --tracker "$T" --derive-recirc-count 8)" \
  || fail "--derive-recirc-count 8 exited non-zero"
[ "$n8" = "0" ] || fail "issue #8 must derive 0 (no attributable tickets), got '$n8'"

# ── (3) FAIL-CLOSED CLI: an ungoverned repo (no backend) exits 2 and prints NO count ──────────────
BARE="$(mktemp -d)"
out="$(python3 "$SWEEP" --repo "$BARE" --derive-recirc-count 5 2>/dev/null)"
rc=$?
rm -rf "$BARE"
[ "$rc" -eq 2 ] || fail "an ungoverned repo must exit 2 (fail-closed = PARK for the caps caller), got $rc"
[ -z "$out" ] || fail "an uncomputable derivation must print NO count (never a guessed 0), got '$out'"

echo "PASS: recirc_count is DERIVED from board state — distinct Recirculation tickets (retired included) whose idc-recirc-source origin names the issue; bare-int stdout for the caps CLI; an unreadable board exits 2 with no count (#108)."
