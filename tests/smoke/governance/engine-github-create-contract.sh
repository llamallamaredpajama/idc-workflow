#!/bin/bash
# engine-github-create-contract.sh — governance scenario: the github create door honors the adapter
# contract (Task 3, round-3 Fix 1).
#
# The adapter declares `createTicket(title, body, type, labels) -> issue#` and the github skill says
# stdout is an ISSUE NUMBER. Before the fix the engine create door accepted neither `type` nor
# `labels` and RETURNED the `PVTI_…` project-item id — so a gate issue could not carry the
# `operator-action` label through the door, and callers that need an integer issue number (e.g. the
# filer's `link_blocks(parent=num)`) got a PVTI string.
#
# This pins the contract on the github backend by stubbing ONLY the low-level `gh` primitive (`_gh`)
# and the single-item read-back (`fetch_item`) — the REAL `create_item` (label/type application, the
# atomic Stage+Status set) and the REAL engine create path run:
#   * the door RETURNS the integer issue number (never the PVTI id);
#   * the REAL create_item passes `--label operator-action` / `--label type:Task` to `gh issue create`
#     (asserted against the captured gh args — so removing the label application makes this FAIL);
#   * the engine POSITIVELY READS BACK Stage+Status after creating and FAILS on a mismatch (Fix 3), so
#     a create whose fields did not land can never be journaled as a success.
#
# Red-when-broken: drop the label wiring in create_item → the captured gh args lose `--label`; drop the
# create read-back in the engine → the mismatch case below stops raising. Either regression FAILs here.
#
# Usage: bash tests/smoke/governance/engine-github-create-contract.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github create-contract unit failed (see above)"
import json, sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

# ---- stub ONLY the low-level gh seam; the REAL create_item drives it (labels, atomic Stage+Status) ----
def make_gh(calls):
    def fake_gh(args, r):
        calls.append(list(args))
        head = args[:2]
        if head == ["project", "view"]:
            return "PVT_NODE\n"
        if head == ["project", "field-list"]:
            return json.dumps({"fields": [
                {"name": "Stage",  "id": "FID_STAGE",  "options": [{"name": "Buildable", "id": "OPT_B"}]},
                {"name": "Status", "id": "FID_STATUS", "options": [{"name": "Todo",      "id": "OPT_T"}]},
            ]})
        if head == ["issue", "create"]:
            return "https://github.com/o/r/issues/4242\n"
        if head == ["project", "item-add"]:
            return "PVTI_ABC123\n"
        if head == ["project", "item-edit"]:
            return ""
        raise AssertionError(f"unexpected gh call reached the stub: {args!r}")
    return fake_gh

ctx = E.github_ctx(repo, "o", "1", itemid_cache={})

# ---- positive: real create_item + a matching read-back → integer number, labels applied ----
calls = []
B._gh = make_gh(calls)
B.fetch_item = lambda item_id, r: {"content": {"number": 4242, "type": "Issue"},
                                   "stage": "Buildable", "status": "Todo"}   # the write landed
result = E.run("create-ticket", ctx, title="gate", body="b", stage=None, status=None,
               type="Task", labels=["operator-action"])

# (1) the door returns the INTEGER issue number, never the PVTI project-item id.
assert result == 4242, f"door must return the integer issue number, got {result!r}"
assert not (isinstance(result, str) and str(result).startswith("PVTI")), \
    f"door returned the PVTI project-item id instead of the issue number: {result!r}"
print("  ok github create door returns the integer issue number (not the PVTI id)")

# (2)+(3) the REAL create_item applied --label operator-action AND --label type:Task on `gh issue create`.
issue_create = next((c for c in calls if c[:2] == ["issue", "create"]), None)
assert issue_create is not None, f"the real create_item never issued `gh issue create`: {calls}"
def _has_label(argv, lbl):
    return any(argv[i] == "--label" and i + 1 < len(argv) and argv[i + 1] == lbl for i in range(len(argv)))
assert _has_label(issue_create, "operator-action"), \
    f"the `operator-action` label was not applied by the real create_item: {issue_create}"
assert _has_label(issue_create, "type:Task"), \
    f"the `--type` (type:Task label) was not applied by the real create_item: {issue_create}"
print("  ok the REAL create_item applies --label operator-action + type:Task to `gh issue create`")

# (4) red-when-broken: a read-back whose Stage/Status does NOT match the request must FAIL the create.
calls2 = []
B._gh = make_gh(calls2)
B.fetch_item = lambda item_id, r: {"content": {"number": 4242, "type": "Issue"},
                                   "stage": "Recirculation", "status": "Blocked"}   # did NOT land
try:
    E.run("create-ticket", ctx, title="gate", body="b", stage=None, status=None)
    print("FAIL: create reported success when the Stage/Status read-back did not match the request"); sys.exit(1)
except E.TransitionError:
    pass
print("  ok the engine positively reads Stage/Status back and FAILS a create that did not land")
PY

echo "PASS: the github create door returns the integer issue number, the real create_item applies --type/--labels, and the engine positively reads Stage/Status back"
