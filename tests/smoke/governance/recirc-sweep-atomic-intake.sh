#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: the sweep's github ticket-filing path must mint a Recirculation ticket through the
# ATOMIC idc_gh_board.create_item() (issue #130) — which sets Stage AND Status together and discards a
# partial — instead of the old issue-create → item-add → item-edit chain that left the new item
# Stage=Recirculation with an EMPTY Status (the #255/#256 empty-Status pointer class the drain later
# trips over). The filed create is also journaled as the engine's recirculate-intake op (issue #150)
# so a lifecycle including a filed ticket replays to an EMPTY diff.
#
# Hermetic: the module is imported directly, its gh / create_item / fetch IO boundaries monkeypatched.

. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || { echo "FAIL: atomic-intake / intake-journal assertions did not all hold"; exit 1; }
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")

CTX = {"owner": "o", "project_node": "PVT_node", "project_number": "7"}
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})

# Scripted gh: only field-list (recirc option id) is still gh-driven; the ticket-filing create is
# create_item now, and the dedupe read is fetch_items.
def gh(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    return True, "", ""
m.gh = gh
idc_gh_board.fetch_items = lambda owner, pn, r: []          # dedupe read OK, no existing tickets

# create_item is the atomic primitive — capture its call so we can assert Stage AND Status land together.
create_calls = []
def fake_create_item(owner, project, r, title, body, stage, status):
    create_calls.append({"stage": stage, "status": status, "title": title})
    return "PVTI_filed"
idc_gh_board.create_item = fake_create_item
# Issue-number read-back for the journal `item` key.
idc_gh_board.fetch_item = lambda iid, r: {"content": {"number": 501, "title": "recirc: shared limiter"}}

# A LEAVE host finding carrying an untickered discovery marker → the ticket-filing path fires.
f = m.Finding(42, m.LEAVE, "host issue (carries an untickered marker)", item_id="PVTI_host")
f.captures = [{"origin": "#42|finisher", "what": "shared limiter",
               "area": "src/api", "suggested_scope": "extract limiter"}]

changed = m.apply_github([f], repo, CTX, lambda _l: None)

errs = []
def check(cond, msg):
    if not cond:
        errs.append(msg)

# (1) #130 — the ATOMIC door was used, with Stage AND a non-empty Status (the empty-Status fix).
check(len(create_calls) == 1, f"ticket-filing must call the atomic create_item exactly once, got {len(create_calls)}")
if create_calls:
    c = create_calls[0]
    check(c["stage"] == "Recirculation",
          f"create_item must set Stage=Recirculation, got {c['stage']!r}")
    check(c["status"] == "Todo",
          f"create_item must set a NON-EMPTY Status=Todo atomically (the #255/#256 fix), got {c['status']!r}")
check(changed == 1, f"a successful atomic filing must count as filed, got changed={changed}")

# (2) #150 — the filed create is journaled as recirculate-intake with to.{stage,status} + item number.
recs = [json.loads(l) for l in open(journal, encoding="utf-8") if l.strip()] if os.path.exists(journal) else []
intake = [r for r in recs if r.get("op") == "recirculate-intake" and r.get("item") == 501]
check(bool(intake), f"filed ticket must journal a recirculate-intake record for #501; saw {recs}")
if intake:
    to = intake[-1].get("to") or {}
    check(to.get("stage") == "Recirculation", f"intake record to.stage must be Recirculation, got {to!r}")
    check(to.get("status") == "Todo", f"intake record to.status must be Todo, got {to!r}")
    check(intake[-1].get("project_item_id") == "PVTI_filed",
          "intake record must carry the created project_item_id")

# (3) #150 replay-consistency — reconstruct from the journal; a board with the filed ticket at
#     Recirculation/Todo yields an EMPTY diff (the ticket is journaled, not a phantom board-only item).
import idc_journal_replay as R
expected, err = R.reconstruct_state_from_journal(journal)
check(err is None, f"reconstruct must succeed, got {err}")
actual = {501: {"stage": "Recirculation", "status": "Todo"}}
diffs = R.compare_states(expected or {}, actual)
check(not diffs, f"a filed-ticket lifecycle must replay to an EMPTY diff, got {diffs}")

# (4) codex round-1 P2 — if the filed ticket's issue number cannot be resolved for the journal, the
#     filing must NOT be reported/counted as clean (a number-less record would let replay see the live
#     ticket as board-only). The ticket still exists on the board, so it is surfaced for reconciliation.
os.remove(journal) if os.path.exists(journal) else None
idc_gh_board.fetch_item = lambda iid, r: (_ for _ in ()).throw(idc_gh_board.BoardReadError("no number"))
logs2 = []
f2 = m.Finding(77, m.LEAVE, "host", item_id="PVTI_host2")
f2.captures = [{"origin": "#77|finisher", "what": "other scope", "area": "a", "suggested_scope": "s"}]
changed2 = m.apply_github([f2], repo, CTX, logs2.append)
check(changed2 == 0, f"an intake whose issue number cannot be journaled must NOT count as filed, got {changed2}")
check(any("not counted as filed" in l for l in logs2),
      "an un-numbered intake must be SURFACED (not counted as filed), not silently reported clean")

# (5) codex round-2 P1 — a throttle mid-create (RateLimitError, a BoardReadError SUBCLASS) must be
#     caught SEPARATELY and DEFER filing (the sweep can't pause/resume and create_item leaves the
#     partial for a resumable caller), not flattened into a generic per-capture failure. The loop
#     breaks on the first throttle, neither capture counts, and the throttle is surfaced.
os.remove(journal) if os.path.exists(journal) else None
idc_gh_board.create_item = lambda o, p, r, t, b, s, st: (_ for _ in ()).throw(
    idc_gh_board.RateLimitError("2026-07-10T01:00:00Z"))
logs3 = []
f3 = m.Finding(88, m.LEAVE, "host", item_id="PVTI_host3")
f3.captures = [{"origin": "#88|a", "what": "scope A", "area": "a", "suggested_scope": "s"},
               {"origin": "#88|b", "what": "scope B", "area": "b", "suggested_scope": "t"}]
changed3 = m.apply_github([f3], repo, CTX, logs3.append)
check(changed3 == 0, f"a throttled filing must NOT count as filed, got {changed3}")
# "deferring" is emitted ONLY by the separate RateLimitError handler (break). The generic BoardReadError
# path would log a per-capture "failed" — and since str(RateLimitError) itself contains "rate-limited",
# asserting on "rate-limited" alone would NOT distinguish the two; "deferring" is the load-bearing signal.
check(any("deferring" in l for l in logs3),
      "a throttle must be caught SEPARATELY and DEFER filing (break), not flattened into a per-capture failure")
# And it must STOP (break), not continue: exactly ONE throttle log, not one failure per capture.
check(sum(1 for l in logs3 if "rate-limited" in l) == 1,
      "a throttle must STOP filing (one deferral log), not attempt every capture")

if errs:
    for e in errs:
        sys.stderr.write("ASSERT FAILED: " + e + "\n")
    sys.exit(1)
print("ok")
PY

echo "PASS: sweep ticket-filing mints via the atomic create_item (Stage+Status together, #130), journals recirculate-intake, and replays clean (#150)."
