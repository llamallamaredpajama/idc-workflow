#!/bin/bash
# board-lifecycle-write-doors.sh — Init/Uninstall lifecycle mutations use the validating GitHub
# adapter instead of raw gh carve-outs. The fake is only the external gh seam; all lifecycle policy,
# idempotency, mutation ordering, and positive readback are the real idc_gh_board implementation.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" "$GOV_PLUGIN" <<'PY' || gov_fail "board lifecycle write-door behavior failed"
import json
import inspect
import os
import re
import sys

sys.path.insert(0, sys.argv[1])
plugin = sys.argv[2]
import idc_gh_board as B

assert list(inspect.signature(B.reconcile_status).parameters) == ["owner", "project", "repo"], \
    "Status reconcile must prove safety from board state, not trust a caller-supplied provenance bypass"

calls = []
projects = [{"number": 5, "id": "PVT_5", "title": "demo IDC Tracker", "url": "https://example.invalid/5",
             "items": {"totalCount": 0}}]
fields = [{"id": "STATUS", "name": "Status", "dataType": "SINGLE_SELECT",
           "options": [{"id": "O_OLD", "name": "Backlog"}]}]
linked = set()
issue_states = {11: "OPEN", 12: "CLOSED", 13: "OPEN"}
deleted_nodes = set()

def project(number):
    return next((p for p in projects if int(p["number"]) == int(number)), None)

def fake_gh(args, repo):
    calls.append(tuple(args))
    if args[:2] == ["project", "list"]:
        return json.dumps({"projects": projects})
    if args[:2] == ["project", "view"]:
        p = project(args[2])
        if not p:
            raise B.BoardReadError("project not found")
        return json.dumps(p)
    if args[:2] == ["project", "create"]:
        title = args[args.index("--title") + 1]
        p = {"number": 6, "id": "PVT_6", "title": title, "url": "https://example.invalid/6",
             "items": {"totalCount": 0}}
        projects.append(p)
        return json.dumps(p)
    if args[:2] == ["project", "field-list"]:
        return json.dumps({"fields": fields})
    if args[:2] == ["project", "field-create"]:
        name = args[args.index("--name") + 1]
        opts = args[args.index("--single-select-options") + 1].split(",")
        fields.append({"id": "F_" + name.upper(), "name": name, "dataType": "SINGLE_SELECT",
                       "options": [{"id": "O_" + str(i), "name": value} for i, value in enumerate(opts)]})
        return json.dumps(fields[-1])
    if args[:2] == ["repo", "view"]:
        return "o/r\n"
    if args[:3] == ["api", "graphql", "-f"]:
        query = args[3]
        if "updateProjectV2Field" in query:
            desired = ["Blocked", "Todo", "In Progress", "Done"]
            fields[0]["options"] = [{"id": "S_" + str(i), "name": value}
                                      for i, value in enumerate(desired)]
            return json.dumps({"data": {"updateProjectV2Field": {"projectV2Field": fields[0]}}})
        if "repository(" in query:
            nodes = [{"number": n} for n in sorted(linked)]
            return json.dumps({"data": {"repository": {"projectsV2": {"nodes": nodes}}}})
        if "node(id:" in query or "node(id:$id)" in query:
            node_id = next((a.split("=", 1)[1] for a in args if a.startswith("id=")), "")
            node = None if node_id in deleted_nodes else {"id": node_id}
            return json.dumps({"data": {"node": node}})
    if args[:2] == ["project", "link"]:
        linked.add(int(args[2]))
        return ""
    if args[:2] == ["issue", "view"]:
        return issue_states[int(args[2])] + "\n"
    if args[:2] == ["issue", "close"]:
        issue_states[int(args[2])] = "CLOSED"
        return ""
    if args[:2] == ["project", "delete"]:
        p = project(args[2])
        deleted_nodes.add(p["id"])
        projects.remove(p)
        return ""
    raise AssertionError("unexpected gh call: %r" % (args,))

B._gh = fake_gh
B.fetch_items = lambda owner, number, repo: [
    {"id": "PVTI_11", "content": {"type": "Issue", "number": 11, "title": "open",
                                      "repository": "o/r"},
     "stage": "Buildable", "status": "Todo"},
    {"id": "PVTI_12", "content": {"type": "Issue", "number": 12, "title": "closed",
                                      "repository": "o/r"},
     "stage": "Buildable", "status": "Done"},
    {"id": "PVTI_13", "content": {"type": "Issue", "number": 13, "title": "external",
                                      "repository": "elsewhere/other"},
     "stage": "Buildable", "status": "Todo"},
    {"id": "PVTI_PR", "content": {"type": "PullRequest", "number": 99, "title": "not an issue"},
     "stage": "Buildable", "status": "Todo"},
]

# ensure-project is idempotent by exact title, and a new project is positively read back.
before = len(calls)
r = B.ensure_project("o", "demo IDC Tracker", ".")
assert r["action"] == "skipped-existing" and r["number"] == 5, r
assert not any(c[:2] == ("project", "create") for c in calls[before:]), calls[before:]
r = B.ensure_project("o", "new IDC Tracker", ".")
assert r["action"] == "created" and r["number"] == 6, r
assert any(c[:2] == ("project", "view") and c[2] == "6" for c in calls), "create lacked readback"

# Status replacement is provenance-gated (empty/created board only), then read back exactly.
r = B.reconcile_status("o", 5, ".")
assert r["action"] == "updated" and [o["name"] for o in fields[0]["options"]] == \
    ["Blocked", "Todo", "In Progress", "Done"], r
before = len(calls)
r = B.reconcile_status("o", 5, ".")
assert r["action"] == "skipped-existing" and not any("updateProjectV2Field" in " ".join(c) for c in calls[before:])
fields[0]["options"] = [{"id": "O_OLD", "name": "Backlog"}]
project(5)["items"]["totalCount"] = 1
before = len(calls)
try:
    B.reconcile_status("o", 5, ".")
    raise AssertionError("populated board accepted a destructive Status replacement")
except B.BoardWriteError:
    pass
assert not any("updateProjectV2Field" in " ".join(c) for c in calls[before:]), calls[before:]
project(5)["items"]["totalCount"] = 0
fields[0]["options"] = [{"id": "S_" + str(i), "name": value} for i, value in enumerate(
    ["Blocked", "Todo", "In Progress", "Done"])]

# Missing fields and links are created once and positively read back; reruns are no-ops.
r = B.ensure_single_select_field("o", 5, "Stage",
                                 ["Consideration", "Planning", "Buildable", "Recirculation"], ".")
assert r["action"] == "created", r
before = len(calls)
r = B.ensure_single_select_field("o", 5, "Stage",
                                 ["Consideration", "Planning", "Buildable", "Recirculation"], ".")
assert r["action"] == "skipped-existing"
assert not any(c[:2] == ("project", "field-create") for c in calls[before:])
r = B.ensure_project_link("o", 5, "o/r", ".")
assert r["action"] == "linked" and 5 in linked, r
before = len(calls)
r = B.ensure_project_link("o", 5, "o/r", ".")
assert r["action"] == "skipped-existing"
assert not any(c[:2] == ("project", "link") for c in calls[before:])

# Bulk close scopes itself to issue-backed items on the verified board and reads every close back.
r = B.close_project_issues("o", 5, ".")
assert r == {"action": "closed-project-issues", "closed": [11], "skipped_closed": [12],
             "skipped_external": ["elsewhere/other#13"]}, r
assert issue_states == {11: "CLOSED", 12: "CLOSED", 13: "OPEN"}
assert not any(c[:2] == ("issue", "close") and c[2] == "13" for c in calls)
assert not any(c[:2] == ("issue", "close") and c[2] == "99" for c in calls)

# Permanent delete requires exact number/title confirmation and verifies the captured node is absent.
before = len(calls)
try:
    B.delete_project("o", 5, "wrong", ".")
    raise AssertionError("mismatched confirmation did not fail")
except B.BoardWriteError:
    pass
assert not any(c[:2] == ("project", "delete") for c in calls[before:])
r = B.delete_project("o", 5, "5", ".")
assert r["action"] == "deleted" and r["number"] == 5, r
assert "PVT_5" in deleted_nodes

# Shipped role-facing command prose must invoke these adapter doors, never executable raw lifecycle writes.
init_text = open(os.path.join(plugin, "commands", "init.md"), encoding="utf-8").read()
uninstall_text = open(os.path.join(plugin, "commands", "uninstall.md"), encoding="utf-8").read()
for name in ("ensure-project", "reconcile-status", "ensure-field", "ensure-link"):
    assert "idc_gh_board.py" in init_text and name in init_text, "init missing adapter door " + name
for name in ("close-project-issues", "delete-project"):
    assert "idc_gh_board.py" in uninstall_text and name in uninstall_text, "uninstall missing adapter door " + name
for text, label in ((init_text, "init"), (uninstall_text, "uninstall")):
    for body in re.findall(r"```bash\n(.*?)```", text, re.S):
        assert not re.search(r"(^|[;&|]\s*)gh\s+(?:issue\s+close|project\s+(?:create|field-create|link|delete|item-delete))\b", body, re.M), \
            "%s still carries an executable raw lifecycle write: %s" % (label, body)

print("PASS: Init/Uninstall lifecycle writes use validating, idempotent, read-back-verified idc_gh_board adapter doors")
PY
