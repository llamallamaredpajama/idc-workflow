#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken (issue #152): a GitHub throttle EARLY in a prior sweep's ticket-filing chain
# (issue created, never added to the board — or added but Stage never set) leaves an OFF-BOARD
# orphan carrying the idc-recirc-source marker. The board-scan dedupe reads board items only, so it
# cannot see the orphan — pre-fix, the next sweep re-filed the same capture as a DUPLICATE issue.
# The fix: before filing, ONE `gh issue list` call maps every open marker-bearing issue by the same
# (origin, what) dedupe key; a matching capture ADOPTS the orphan onto the board (Stage+Status set
# together via idc_gh_board.adopt_item, intake journaled) instead of re-filing. Fail-closed: an
# unreadable orphan list skips filing (an invisible orphan may exist). Hermetic: the module is
# imported directly, its gh / board IO monkeypatched.

. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || { echo "FAIL: orphan-adoption assertions did not all hold"; exit 1; }
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")

CTX = {"owner": "o", "project_node": "PVT_node", "project_number": "7"}
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})
idc_gh_board.fetch_items = lambda owner, pn, r: []   # board dedupe: NO tickets on the board

# The off-board orphan: an OPEN issue carrying the source marker, invisible to the board scan.
ORPHAN_BODY = ('Stage: Recirculation\n'
               '<!-- idc-recirc-source: {"origin": "#42|finisher", "what": "shared limiter"} -->\n')
ORPHAN = {"number": 300, "title": "recirc: shared limiter", "body": ORPHAN_BODY,
          "url": "https://github.com/o/r/issues/300"}
issue_lists = []
def gh(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "list"]:
        issue_lists.append(list(args))
        return True, json.dumps([ORPHAN]), ""
    return True, "", ""
m.gh = gh

real_adopt_item = idc_gh_board.adopt_item   # kept for the case-(6) unit below, pre-monkeypatch
adopts = []
def fake_adopt_item(owner, project, r, url, stage, status):
    adopts.append({"url": url, "stage": stage, "status": status})
    return "PVTI_adopted"
idc_gh_board.adopt_item = fake_adopt_item

creates = []
def fake_create_item(owner, project, r, title, body, stage, status):
    creates.append({"title": title})
    return "PVTI_new"
idc_gh_board.create_item = fake_create_item
idc_gh_board.fetch_item = lambda iid, r: {"content": {"number": 999, "title": "x"}}

errs = []
def check(c, msg):
    if not c:
        errs.append(msg)

# (1) a capture whose key matches the off-board orphan is ADOPTED, never re-filed as a duplicate.
f = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")
f.captures = [{"origin": "#42|finisher", "what": "shared limiter", "area": "a", "suggested_scope": "s"}]
logs1 = []
changed = m.apply_github([f], repo, CTX, logs1.append)
check(len(creates) == 0,
      f"an off-board orphan must be ADOPTED, never re-filed as a duplicate — got {len(creates)} create(s)")
check(len(adopts) == 1, f"the orphan must be adopted with exactly one adopt_item, got {len(adopts)}")
if adopts:
    check(adopts[0]["url"] == ORPHAN["url"], f"adoption must target the orphan's url, got {adopts[0]}")
    check(adopts[0]["stage"] == "Recirculation" and adopts[0]["status"] == "Todo",
          f"adoption must set Stage=Recirculation + Status=Todo together, got {adopts[0]}")
check(changed == 1, f"an adopted orphan must count as a board change, got {changed}")
check(any("adopted" in l for l in logs1), f"the adoption must be surfaced in the log, got {logs1}")

# (2) the adopted intake is journaled under the orphan's OWN issue number (Recirculation/Todo).
recs = [json.loads(l) for l in open(journal, encoding="utf-8") if l.strip()] if os.path.exists(journal) else []
intake = [r for r in recs if r.get("op") == "recirculate-intake" and r.get("item") == 300]
check(bool(intake), f"the adopted intake must be journaled (recirculate-intake #300); saw {recs}")
if intake:
    to = intake[-1].get("to") or {}
    check(to.get("stage") == "Recirculation" and to.get("status") == "Todo",
          f"adopted intake `to` must be Recirculation/Todo, got {to}")
    check(intake[-1].get("project_item_id") == "PVTI_adopted",
          "the adopted intake record must carry the adopted project_item_id")

# (3) POSITIVE control — a capture with NO matching orphan still files via the atomic create_item.
adopts.clear(); creates.clear()
f2 = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")
f2.captures = [{"origin": "#88|reviewer", "what": "different scope", "area": "a", "suggested_scope": "s"}]
changed2 = m.apply_github([f2], repo, CTX, lambda _l: None)
check(len(creates) == 1 and len(adopts) == 0 and changed2 == 1,
      f"a capture with no orphan match must still FILE (creates={len(creates)}, adopts={len(adopts)})")

# (4) FAIL-CLOSED — an unreadable orphan list skips filing entirely (an invisible orphan may exist).
adopts.clear(); creates.clear()
def gh_list_fail(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "list"]:
        return False, "", "simulated issue-list outage"
    return True, "", ""
m.gh = gh_list_fail
f3 = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")
f3.captures = [{"origin": "#42|finisher", "what": "shared limiter", "area": "a", "suggested_scope": "s"}]
logs4 = []
changed4 = m.apply_github([f3], repo, CTX, logs4.append)
check(len(creates) == 0 and len(adopts) == 0 and changed4 == 0,
      f"an unreadable orphan list must skip filing (fail-closed against blind duplicates), "
      f"got creates={len(creates)}, adopts={len(adopts)}, changed={changed4}")
check(any("skipping ticket-filing" in l for l in logs4),
      f"the fail-closed skip must be surfaced, got {logs4}")

# (5) zero-cost on a deduped sweep — when the BOARD dedupe already covers every capture, the orphan
#     scan (gh issue list) never fires.
m.gh = gh
issue_lists.clear()
BOARD_TICKET = {"stage": "Recirculation", "status": "Todo", "id": "PVTI_board",
                "content": {"number": 301, "title": "recirc: shared limiter"}}
def gh_with_board_body(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "view"]:
        return True, json.dumps({"body": ORPHAN_BODY}), ""
    if args[:2] == ["issue", "list"]:
        issue_lists.append(list(args))
        return True, json.dumps([]), ""
    return True, "", ""
m.gh = gh_with_board_body
idc_gh_board.fetch_items = lambda owner, pn, r: [BOARD_TICKET]
f4 = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")
f4.captures = [{"origin": "#42|finisher", "what": "shared limiter", "area": "a", "suggested_scope": "s"}]
m.apply_github([f4], repo, CTX, lambda _l: None)
check(len(issue_lists) == 0,
      f"a fully board-deduped sweep must not fire the orphan scan (zero extra calls), got {issue_lists}")

# (6) idc_gh_board.adopt_item unit — via the single _gh seam: adds the existing issue, sets Stage AND
#     Status together, and NEVER closes/deletes the pre-existing issue on a hard failure (the orphan
#     is the operator's ticket; adoption is resumable — item-add is idempotent).
import idc_gh_board as B
FIELDS = {"fields": [
    {"name": "Stage",  "id": "FID_stage",  "options": [{"name": "Recirculation", "id": "OID_recirc"}]},
    {"name": "Status", "id": "FID_status", "options": [{"name": "Todo", "id": "OID_todo"}]}]}
calls = []
def gh_ok(args, r):
    calls.append(list(args))
    if args[:2] == ["project", "view"]:
        return "PVT_node\n"
    if args[:2] == ["project", "field-list"]:
        return json.dumps(FIELDS)
    if args[:2] == ["project", "item-add"]:
        return "PVTI_adopt\n"
    return ""
B._gh = gh_ok
iid = real_adopt_item("o", "7", repo, "https://github.com/o/r/issues/300", "Recirculation", "Todo")
check(iid == "PVTI_adopt", f"adopt_item must return the adopted item id, got {iid!r}")
edits = [c for c in calls if c[:2] == ["project", "item-edit"]]
check(len(edits) == 2, f"adopt_item must set Stage AND Status together (2 item-edits), got {len(edits)}")
check(not any(c[:2] in (["issue", "close"], ["project", "item-delete"]) for c in calls),
      "a clean adopt must not close/delete anything")

calls.clear()
def gh_status_fails(args, r):
    calls.append(list(args))
    if args[:2] == ["project", "view"]:
        return "PVT_node\n"
    if args[:2] == ["project", "field-list"]:
        return json.dumps(FIELDS)
    if args[:2] == ["project", "item-add"]:
        return "PVTI_adopt\n"
    if args[:2] == ["project", "item-edit"] and "FID_status" in args:
        raise B.BoardReadError("simulated Status-edit failure")
    return ""
B._gh = gh_status_fails
try:
    real_adopt_item("o", "7", repo, "https://github.com/o/r/issues/300", "Recirculation", "Todo")
    errs.append("adopt_item must raise BoardWriteError on a hard mid-adopt failure")
except B.RateLimitError:
    errs.append("a hard failure must not be flattened into RateLimitError")
except B.BoardWriteError:
    pass
check(not any(c[:2] == ["issue", "close"] for c in calls),
      "a failed adopt must NEVER close the pre-existing issue (it is the operator's ticket)")

calls.clear()
def gh_status_throttles(args, r):
    calls.append(list(args))
    if args[:2] == ["project", "view"]:
        return "PVT_node\n"
    if args[:2] == ["project", "field-list"]:
        return json.dumps(FIELDS)
    if args[:2] == ["project", "item-add"]:
        return "PVTI_adopt\n"
    if args[:2] == ["project", "item-edit"] and "FID_status" in args:
        raise B.RateLimitError("2026-08-02T00:00:00Z")
    return ""
B._gh = gh_status_throttles
try:
    real_adopt_item("o", "7", repo, "https://github.com/o/r/issues/300", "Recirculation", "Todo")
    errs.append("adopt_item must re-raise a mid-adopt RateLimitError")
except B.RateLimitError:
    pass   # re-raised UNCHANGED (pause-and-resume; teardown calls would hit the same live limit)
except B.BoardReadError:
    errs.append("a mid-adopt throttle must re-raise RateLimitError unchanged, not a flattened error")

if errs:
    for e in errs:
        sys.stderr.write("ASSERT FAILED: " + e + "\n")
    sys.exit(1)
print("ok")
PY

echo "PASS: an off-board Recirculation orphan (throttle-partial filing) is ADOPTED onto the board (Stage+Status together, intake journaled) instead of re-filed as a duplicate; an unreadable orphan list fails closed; a board-deduped sweep pays zero extra calls (#152)."
