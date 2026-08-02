#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken (issue #109, graphql-cost sinks #2-#4): a github sweep used to read the FULL board
# TWICE (once to scan, once for the filing dedupe) and fire a `gh issue view --json body,comments`
# per Buildable AND per Recirculation ticket. The consolidation: ONE detailed board read
# (idc_gh_board.fetch_items include_details=True — body + comment bodies + native blockedBy numbers
# folded into the same paginated GraphQL query) feeds the Buildable marker scan, the dedupe/partial
# split, AND the derive path; apply_github consumes the snapshot via ctx["items"]. Pre-fix this lane
# FAILs: two board fetches (neither detailed) and per-issue view calls. Hermetic: the module is
# imported directly, its gh / board IO monkeypatched.

. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || { echo "FAIL: single-read consolidation assertions did not all hold"; exit 1; }
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

errs = []
def check(c, msg):
    if not c:
        errs.append(msg)

# ── (1) the query shape lives in idc_gh_board: lean by default, details only on request ───────────
check("blockedBy" not in idc_gh_board.ITEMS_QUERY and "comments(" not in idc_gh_board.ITEMS_QUERY,
      "the DEFAULT board query must stay lean (no blockedBy/comments) — other callers must not pay")
for want in ("body", "comments(first: 100)", "blockedBy(first: 50)"):
    check(want in idc_gh_board.ITEMS_QUERY_DETAILED,
          f"the detailed board query must fold in {want!r} (issue #109)")

# _flatten surfaces the detailed fields under content; the lean shape stays byte-identical.
node = {"id": "PVTI_1",
        "fieldValues": {"nodes": [{"__typename": "ProjectV2ItemFieldSingleSelectValue",
                                   "name": "Todo", "field": {"name": "Status"}}]},
        "content": {"__typename": "Issue", "number": 7, "title": "t",
                    "repository": {"nameWithOwner": "o/r"}, "body": "B",
                    "comments": {"nodes": [{"body": "c1"}, {"body": "c2"}]},
                    "blockedBy": {"nodes": [{"number": 3}, {"number": 4}]}}}
flat = idc_gh_board._flatten(node)
check(flat["content"].get("body") == "B", f"detailed flatten must surface content.body, got {flat['content']}")
check(flat["content"].get("comments") == ["c1", "c2"],
      f"detailed flatten must surface comment bodies, got {flat['content'].get('comments')}")
check(flat["content"].get("blocked_by") == [3, 4],
      f"detailed flatten must surface native blockedBy numbers, got {flat['content'].get('blocked_by')}")
lean = idc_gh_board._flatten({"id": "PVTI_2", "content": {"__typename": "Issue", "number": 8, "title": "t"}})
check("body" not in lean["content"] and "comments" not in lean["content"] and "blocked_by" not in lean["content"],
      "a lean read must not grow new content keys (byte-identical legacy shape)")

# ── (2) a FULL github sweep (scan + apply) costs exactly ONE board read, and it is detailed ───────
repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
# Corroborate the live inbox ticket up front so the journal-backfill heal costs zero reads here.
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "recirculate-intake", "item": 50, "project_item_id": "PVTI_50",
                         "to": {"stage": "Recirculation", "status": "Todo"}}) + "\n")

DISCOVERY = ('<!-- idc-discovery: {"origin": "#10|finisher", "what": "comment scope", '
             '"area": "src", "suggested_scope": "s"} -->')
DEFERRAL = '<!-- idc-deferral: {"what": "already filed"} -->'
SEEN_BODY = '<!-- idc-recirc-source: {"origin": "#10", "what": "already filed"} -->'
PARTIAL_BODY = '<!-- idc-recirc-source: {"origin": "#9|reviewer", "what": "partial scope"} -->'
BOARD = [
    # A Buildable whose DISCOVERY marker rides a COMMENT and whose DEFERRAL rides the body — both
    # must be read off the single detailed board read (no gh issue view).
    {"stage": "Buildable", "status": "Todo", "id": "PVTI_10",
     "content": {"number": 10, "title": "host", "body": DEFERRAL, "comments": [DISCOVERY]}},
    # A fully-filed Recirculation ticket whose body key dedupes the host's deferral capture.
    {"stage": "Recirculation", "status": "Todo", "id": "PVTI_50",
     "content": {"number": 50, "title": "recirc: already filed", "body": SEEN_BODY, "comments": []}},
    # A throttle-partial (marker + EMPTY Status) healed from the same snapshot.
    {"stage": "Recirculation", "id": "PVTI_42",
     "content": {"number": 42, "title": "recirc: partial scope", "body": PARTIAL_BODY, "comments": []}},
]
fetch_calls = []
def fake_fetch(owner, pn, r, include_details=False):
    fetch_calls.append(include_details)
    return BOARD
idc_gh_board.fetch_items = fake_fetch

views = []
def gh(args, r):
    if args[:2] == ["issue", "view"]:
        views.append(list(args))
        return True, json.dumps({"body": "", "comments": []}), ""
    if args[:2] == ["project", "view"]:
        return True, "PVT_node", ""
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "list"]:
        return True, "[]", ""
    return True, "", ""
m.gh = gh
m.gh_owner = lambda r: "o"
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})

heals = []
def fake_set_status(owner, project, r, item_id, status):
    heals.append({"item_id": item_id, "status": status})
idc_gh_board.set_status = fake_set_status
creates = []
def fake_create_item(owner, project, r, title, body, stage, status):
    creates.append({"title": title, "body": body})
    return "PVTI_new"
idc_gh_board.create_item = fake_create_item
idc_gh_board.fetch_item = lambda iid, r: {"content": {"number": 501, "title": "x"}}

findings, ctx = m.scan_github(repo, None, "7", lambda _l: None)
check(ctx is not None and ctx.get("items") is BOARD,
      "scan_github must carry the single detailed snapshot into ctx['items']")
changed = m.apply_github(findings, repo, ctx, lambda _l: None)

check(fetch_calls == [True],
      f"a full sweep must cost exactly ONE board read, and it must be detailed — got {fetch_calls}")
check(views == [],
      f"NO per-issue `gh issue view` may fire — body/comments ride the single read (#109), got {views}")
check(len(creates) == 1 and "comment scope" in creates[0]["title"],
      f"the COMMENT-borne discovery must be captured off the single read, got {creates}")
check(len(heals) == 1 and heals[0]["item_id"] == "PVTI_42",
      f"the throttle-partial must be detected + healed from the same snapshot, got {heals}")
check(changed == 2, f"expected 2 board changes (1 filing + 1 heal; the deferral deduped), got {changed}")

if errs:
    for e in errs:
        sys.stderr.write("ASSERT FAILED: " + e + "\n")
    sys.exit(1)
print("ok")
PY

echo "PASS: a github sweep costs ONE detailed board read — body/comments/blockedBy folded into the shared paginated query in idc_gh_board (lean by default), the dedupe consumes the ctx snapshot, and no per-issue gh view fires (#109)."
