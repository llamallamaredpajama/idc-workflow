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
# This pins the contract on the github backend (monkeypatched gh primitives — no live GitHub):
#   * the door RETURNS the integer issue number (never the PVTI id);
#   * a `--labels` value passed through the door is APPLIED to the created issue;
#   * a `--type` value passed through the door is APPLIED too.
#
# Red-when-broken: revert the door to return the PVTI id / drop labels+type from create_item → the
# return is not an int / the label is not captured → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-github-create-contract.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github create-contract unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

captured = {}
def fake_create_item(owner, project, r, title, body, stage, status, labels=None, issue_type=None):
    captured["labels"] = labels
    captured["issue_type"] = issue_type
    captured["stage"] = stage
    captured["status"] = status
    return "PVTI_ABC123"                 # the project-item id — must NOT be what the door returns
B.create_item = fake_create_item
# fetch_item resolves the created issue NUMBER (and is also the create read-back on this backend).
B.fetch_item = lambda item_id, r: {"content": {"number": 4242, "type": "Issue"},
                                   "stage": "Buildable", "status": "Todo"}
ctx = E.github_ctx(repo, "o", "1", itemid_cache={})

result = E.run("create-ticket", ctx, title="gate", body="b", stage=None, status=None,
               type="Task", labels=["operator-action"])

# (1) the door returns the INTEGER issue number, never the PVTI project-item id.
assert result == 4242, f"door must return the integer issue number, got {result!r}"
assert not (isinstance(result, str) and result.startswith("PVTI")), \
    f"door returned the PVTI project-item id instead of the issue number: {result!r}"
print("  ok github create door returns the integer issue number (not the PVTI id)")

# (2) the label passed through the door was applied to the created issue.
assert captured.get("labels") == ["operator-action"], \
    f"the `operator-action` label was not applied through the door: {captured}"
# (3) the type passed through the door was applied too.
assert captured.get("issue_type") == "Task", f"the `--type` was not applied through the door: {captured}"
print("  ok a --labels / --type value passed through the door is applied to the created issue")
PY

echo "PASS: the github create door returns the integer issue number and applies --type/--labels to the created issue"
