#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: a GitHub throttle BETWEEN create_item's Stage and Status writes leaves a
# Recirculation ticket with its source marker + Stage=Recirculation but an EMPTY Status. The sweep's
# marker-dedupe must NOT skip such a partial forever — it must SELF-HEAL it in place (issue #150 /
# codex R4 P1a): one setField Status=Todo + journal the completed intake, and NOT re-create a duplicate
# for the same marker. Hermetic: the module is imported directly, its gh / board IO monkeypatched.

. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || { echo "FAIL: throttle-partial heal assertions did not all hold"; exit 1; }
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")

CTX = {"owner": "o", "project_node": "PVT_node", "project_number": "7"}
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})

# The board carries ONE Recirculation ticket that is a throttle-partial: source marker present, but NO
# "status" key (empty Status — what create_item leaves when a rate limit hits between Stage and Status).
PARTIAL = {"stage": "Recirculation", "id": "PVTI_partial",
           "content": {"number": 42, "title": "recirc: shared limiter"}}
idc_gh_board.fetch_items = lambda owner, pn, r: [PARTIAL]

MARKER_BODY = ('Stage: Recirculation\n'
               '<!-- idc-recirc-source: {"origin": "#42|finisher", "what": "shared limiter"} -->\n')
def gh(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "view"]:
        return True, json.dumps({"body": MARKER_BODY}), ""
    return True, "", ""
m.gh = gh

heals = []
def fake_set_status(owner, project, r, item_id, status):
    heals.append({"item_id": item_id, "status": status})
idc_gh_board.set_status = fake_set_status

creates = []
def fake_create_item(*a):
    creates.append(a); return "PVTI_new"
idc_gh_board.create_item = fake_create_item
idc_gh_board.fetch_item = lambda iid, r: {"content": {"number": 999, "title": "x"}}

# A LEAVE host finding whose capture MATCHES the partial's marker key — the dedupe would have skipped it.
f = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")
f.captures = [{"origin": "#42|finisher", "what": "shared limiter", "area": "a", "suggested_scope": "s"}]

changed = m.apply_github([f], repo, CTX, lambda _l: None)

errs = []
def check(c, msg):
    if not c:
        errs.append(msg)

# (1) the throttle-partial is HEALED in place (one setField Status=Todo on the partial), not skipped.
check(len(heals) == 1, f"the throttle-partial must be healed with exactly one setField, got {len(heals)}")
if heals:
    check(heals[0]["item_id"] == "PVTI_partial", f"heal must target the partial item, got {heals[0]}")
    check(heals[0]["status"] == "Todo", f"heal must set Status=Todo, got {heals[0].get('status')!r}")
check(changed == 1, f"a healed partial must count as a board change, got {changed}")

# (2) NO duplicate: the healed key dedupes the matching capture → create_item is NOT called.
check(len(creates) == 0, f"a healed partial must NOT be re-created as a duplicate, got {len(creates)} create(s)")

# (3) the completed intake is journaled (recirculate-intake for #42, to Recirculation/Todo).
recs = [json.loads(l) for l in open(journal, encoding="utf-8") if l.strip()] if os.path.exists(journal) else []
intake = [r for r in recs if r.get("op") == "recirculate-intake" and r.get("item") == 42]
check(bool(intake), f"the healed intake must be journaled (recirculate-intake #42); saw {recs}")
if intake:
    to = intake[-1].get("to") or {}
    check(to.get("stage") == "Recirculation" and to.get("status") == "Todo",
          f"healed intake to must be Recirculation/Todo, got {to}")

# (4) codex R5 P1c — the heal must run INDEPENDENT of captures: when the source rogue was re-staged out
#     of the Buildable lane earlier this sweep, THIS sweep has NO captures, yet the prior throttle's
#     partial must still be healed (ctx.has_partials, set from the single board read, triggers the scan).
os.remove(journal) if os.path.exists(journal) else None
heals.clear(); creates.clear()
CTX2 = dict(CTX, has_partials=True)               # scan_github sets this from the board meta
f_nocap = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")   # NO captures this sweep
f_nocap.captures = []
changed2 = m.apply_github([f_nocap], repo, CTX2, lambda _l: None)
check(len(heals) == 1 and heals[0]["item_id"] == "PVTI_partial",
      "a partial must be healed even with NO captures this sweep (heal must not hide inside if captures)")
check(changed2 == 1, f"the no-capture heal must count, got {changed2}")
recs2 = [json.loads(l) for l in open(journal, encoding="utf-8") if l.strip()] if os.path.exists(journal) else []
check(any(r.get("op") == "recirculate-intake" and r.get("item") == 42 for r in recs2),
      "the no-capture heal must journal the completed intake")

# (5) codex R6 — a partial whose heal FAILS transiently must STILL dedupe its marker, so a matching
#     capture does NOT create a DUPLICATE (the incomplete ticket already exists); the heal retries next
#     sweep. Red-when-broken: dedupe-only-on-success lets the capture loop file a second ticket.
os.remove(journal) if os.path.exists(journal) else None
heals.clear(); creates.clear()
def failing_set_status(owner, project, r, item_id, status):
    raise idc_gh_board.BoardWriteError("transient heal failure")
idc_gh_board.set_status = failing_set_status
f_match = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host")
f_match.captures = [{"origin": "#42|finisher", "what": "shared limiter", "area": "a", "suggested_scope": "s"}]
changed3 = m.apply_github([f_match], repo, CTX, lambda _l: None)
check(len(creates) == 0,
      "a partial whose heal FAILED must still dedupe its marker — the matching capture must NOT create a duplicate")
check(changed3 == 0, f"a failed heal must not count as a board change, got {changed3}")

if errs:
    for e in errs:
        sys.stderr.write("ASSERT FAILED: " + e + "\n")
    sys.exit(1)
print("ok")
PY

echo "PASS: a throttle-partial (marker + empty Status) is SELF-HEALED in place (Status=Todo + journaled), not skipped forever, and not re-created as a duplicate."
