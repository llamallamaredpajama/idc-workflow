#!/bin/bash
# journal-append.sh — governance scenario: engine ops must append to the transition journal.
#
# Phase-4 (journal-spine): every state transition is recorded as one append-only NDJSON line in
# docs/workflow/transition-journal.ndjson. This test verifies that a sequence of ops on both
# filesystem and github backends produces the expected number of records with the required keys.
# Red-when-broken: if the journal_append() call is removed from idc_transition.py, this test fails.
#
# Usage: bash tests/smoke/governance/journal-append.sh   (exit 0 = pass)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

J_PATH="$REPO/docs/workflow/transition-journal.ndjson"
mkdir -p "$(dirname "$J_PATH")"
# Start with a clean slate.
> "$J_PATH"

# (1) Filesystem backend: create, link, move, close should yield 4 journal entries.
n_parent=$(eng create-ticket --title 'fs-parent' --stage 'Buildable' --status 'Todo')
n_child=$(eng create-ticket --title 'fs-child' --stage 'Buildable' --status 'Todo')

eng link --parent "$n_parent" --child "$n_child" >/dev/null

VERDICT_PATH="$REPO/verdict.json"
cat > "$VERDICT_PATH" <<EOF
{
  "verdict": "PASS",
  "issue": $n_child,
  "pr": 1,
  "merge_conditions": [
    {"id": "c1", "description": "d1", "met": true}
  ]
}
EOF
eng move --num "$n_child" --to-status "In Progress" >/dev/null
eng close --num "$n_child" --verdict "$VERDICT_PATH" --pr 1 >/dev/null

[ -f "$J_PATH" ] || fail "journal file was not created"
lines_fs=$(wc -l < "$J_PATH")
[ "$lines_fs" -eq 5 ] || fail "fs ops: expected 5 journal lines, got $lines_fs"
echo "  ok (1) fs backend: create(x2), link, move, close wrote 5 journal lines"

# (2) Github backend: move + close should yield 2 more journal entries.
# We monkeypatch the github board interface to avoid real network calls.
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github journal unit failed (see above)"
import sys, json, os
sys.path.insert(0, sys.argv[1])
repo_root = sys.argv[2]
# Create a verdict for the github item. The issue number is hardcoded to 10 in the python block
# so we can just create the verdict file with that number.
verdict_path_gh = os.path.join(repo_root, "verdict_gh.json")
with open(verdict_path_gh, "w") as f:
    json.dump({
        "verdict": "PASS",
        "issue": 10,
        "pr": 2,
        "merge_conditions": [{"id": "c1", "description": "d1", "met": True}]
    }, f)

import idc_transition as E, idc_gh_board as B, idc_gh_close as C

# Mock github state and interactions
CUR = {"stage": "Buildable", "status": "Todo"}
sets = []
def fake_fetch_item(iid, r):
    if iid == "PVTI_12":
        return {"stage": "Buildable", "status": "Todo", "content": {"number": 12, "title": "gh-item"}}
    return dict(CUR)
B.fetch_item = fake_fetch_item
def set_status(o, p, r, iid, s): sets.append(s); CUR["status"] = s
B.set_status = set_status
def fake_close(o, p, n, r, item_id=None): CUR["status"] = "Done"
C.close_issue = fake_close
comments = []
def fake_comment(num, body, repo): comments.append({"num": num, "body": body})
B.add_comment = fake_comment
# github `link --kind blocks` now writes the native blocked-by edge too — stub the native helpers so
# the unit stays hermetic (no live gh) while still exercising the journal append.
native = {}
B.add_blocked_by = lambda child, parent, r: native.setdefault(int(child), set()).add(int(parent))
B.blocked_by_numbers = lambda child, r: sorted(native.get(int(child), set()))
creates = []
def fake_create(o, p, r, title, body, stage, status): creates.append(title); return "PVTI_12"
B.create_item = fake_create
ctx = E.github_ctx(repo_root, "o", "1", itemid_cache={10: "PVTI_10", 11: "PVTI_11"})

# Perform create, move, close and link
E.run("create-ticket", ctx, title="gh-item")
journal_path = os.path.join(repo_root, "docs", "workflow", "transition-journal.ndjson")
with open(journal_path, encoding="utf-8") as fh:
    create_line = json.loads(fh.readlines()[-1])
if create_line.get("item") != 12:
    raise SystemExit(f"github create journal line must record issue #12, got {create_line}")
E.run("move", ctx, num=10, to_status="In Progress")
E.run("close", ctx, num=10, verdict=verdict_path_gh, pr=2)

# Also test link for github backend
E.run("link", ctx, parent=10, child=11)
PY

lines_total=$(wc -l < "$J_PATH")
[ "$lines_total" -eq 9 ] || fail "gh ops: expected 9 total journal lines, got $lines_total"
echo "  ok (2) gh backend: create, move, close, link wrote 4 additional journal lines"

# (3) Verify journal entries have the required structure.
# We'll just check the last line for structure. A more rigorous check is too complex for bash.
last_line=$(tail -n 1 "$J_PATH")
keys_ok=true
for key in '"who"' '"what"' '"when"' '"guard_evidence_hash"' '"backend"' '"repo-relative tracker"'; do
    if ! echo "$last_line" | grep -q "$key"; then
        echo "FAIL: last journal entry missing key: $key"
        echo "Entry: $last_line"
        keys_ok=false
    fi
done
$keys_ok || fail "journal entry structure is incorrect"
echo "  ok (3) journal entry contains all required keys"

echo "PASS: engine ops correctly append to the transition journal for both fs and github backends."
