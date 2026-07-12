#!/bin/bash
# recirc-journal-heal.sh — governance scenario: the sweep's JOURNAL-BACKFILL heal for a stranded
# valid Recirculation ticket (codex round-11 P2).
#
# THE STRAND: `recirculate-intake` created the ticket on the board, but its BEST-EFFORT journal
# append failed → no sanctioned record. On an adopted journal the item is then PERMANENTLY
# undrainable: the drained guard's corroboration fails closed, the filer's marker-dedupe never
# re-files it, the sweep's idempotent re-stage skip never re-journals it, and the janitor's replay
# only REPORTS the divergence. The heal: the sweep (already the sanctioned, journaled judge of what
# belongs on the inbox — it re-stages any marker-bearing rogue) RATIFIES an already-staged item that
# passes the SAME validity predicate the drained guard uses, emitting its restage record with a
# `heal: journal-backfill` DISCLOSURE field. Self-deduping (the emitted record IS the corroboration
# the next run finds); a corrupt journal SKIPS the heal (never backfill blind); matrix-INDEPENDENT
# (a strand must heal without a provenance regime). HONEST RESIDUAL (#151): a well-formed forged
# marker is ratified too — corroboration proves a sanctioned producer's journaled decision, never
# marker authenticity (the same trust as the sweep's own rogue re-stage door).
#
# Red-when-broken: neuter heal_unjournaled_inbox (return 0) or drop its run()/apply_github wiring →
# cases 2/6 FAIL (the strand stays undrainable / no github heal record). Drop the validity predicate
# → case 4 FAILs (a bare item is ratified). Make a corrupt journal backfill anyway → case 5 FAILs.
# Count a heal whose journal append was SWALLOWED (round-14 P2) → case 7 FAILs. Continue into the
# heal pass after a mid-create rate limit (round-14 P2) → case 8 FAILs. Return "" instead of raising
# on a rate-limited HEAL-side read (round-15 P2) → case 9 FAILs (all candidates read, no defer).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

SWEEP="$GOV_PLUGIN/scripts/idc_recirc_sweep.py"
JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
SRC_MARKER='<!-- idc-recirc-source: {"origin":9,"what":"stranded scope","key":"k-strand"} -->'

# The sweep runs only in a governed repo (read_backend); NO pillar matrix on purpose — the heal
# must be matrix-independent (the provenance-regime gate applies to re-staging, not to healing).
mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"

# ── 1. the strand: adopted journal + a valid marker-bearing recirc ticket with NO record ──────────
anchor="$(eng create-ticket --title 'adoption anchor' --stage Buildable --status Todo)" \
  || fail "could not engine-create the adoption anchor"
strand="$(gov_seed_item "$T" --title 'recirc: intake whose journal append was lost' \
          --stage Recirculation --status Todo --comment "$SRC_MARKER")" \
  || fail "could not seed the stranded recirc ticket"
out=$(eng dispose --disposition drained --num "$strand" 2>&1) && \
  fail "drained closed the stranded ticket BEFORE the heal (corroboration hole)"
echo "$out" | grep -q "journal-heal" \
  || fail "the pre-heal denial does not NAME the sweep's journal-heal remediation: $out"
echo "  ok (1) the strand is denied pre-heal, and the denial names the sweep's journal-heal remediation"

# ── 2. the sweep backfills a DISCLOSED record; the same ticket then drains ─────────────────────────
sweep_out=$(python3 "$SWEEP" --repo "$REPO" --auto-correct 2>&1) \
  || fail "sweep --auto-correct must stay fail-soft (exit 0): $sweep_out"
python3 - "$JOURNAL" "$strand" <<'PY' || fail "the sweep did not backfill a DISCLOSED heal record for the strand"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
heals = [r for r in recs if r.get("heal") == "journal-backfill" and r.get("item") == int(sys.argv[2])]
if len(heals) != 1:
    raise SystemExit(f"expected exactly one disclosed heal record for #{sys.argv[2]}, got {heals}")
if (heals[0].get("to") or {}).get("stage") != "Recirculation" or heals[0].get("op") != "recirc-restage":
    raise SystemExit(f"the heal record is not a canonical restage record: {heals[0]}")
PY
eng dispose --disposition drained --num "$strand" >/dev/null 2>&1 \
  || fail "the healed strand still cannot drain (the backfilled record must corroborate)"
[ "$(gov_field "$T" "$strand" Status)" = "Done" ] || fail "the healed strand did not reach Done"
grep -q '"corroboration": "recirc-restage"' "$JOURNAL" \
  || fail "the post-heal dispose was not admitted BY the backfilled restage record"
echo "  ok (2) the sweep backfills one disclosed heal record (no matrix needed); the strand then drains via it"

# ── 3. idempotent: a second sweep emits NO second heal record ──────────────────────────────────────
strand2="$(gov_seed_item "$T" --title 'recirc: second strand' \
           --stage Recirculation --status Todo --comment "$SRC_MARKER")" \
  || fail "could not seed the second strand"
python3 "$SWEEP" --repo "$REPO" --auto-correct >/dev/null 2>&1 || fail "sweep run 1 failed"
python3 "$SWEEP" --repo "$REPO" --auto-correct >/dev/null 2>&1 || fail "sweep run 2 failed"
n=$(grep -c "\"heal\": \"journal-backfill\"" "$JOURNAL")
[ "$n" -eq 2 ] || fail "heal is not idempotent: expected 2 total heal records (strand + strand2), got $n"
echo "  ok (3) the heal is self-deduping (its own record is the corroboration the next run finds)"

# ── 4. a BARE Recirculation item (no valid marker) is never ratified ───────────────────────────────
bare="$(gov_seed_item "$T" --title 'recirc: bare, no provenance' --stage Recirculation --status Todo)" \
  || fail "could not seed the bare item"
python3 "$SWEEP" --repo "$REPO" --auto-correct >/dev/null 2>&1 || fail "sweep over bare item failed"
python3 - "$JOURNAL" "$bare" <<'PY' || fail "the sweep ratified a BARE Recirculation item (no valid provenance marker)"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
if any(r.get("heal") for r in recs if r.get("item") == int(sys.argv[2])):
    raise SystemExit("a bare item got a heal record")
PY
eng dispose --disposition drained --num "$bare" >/dev/null 2>&1 && \
  fail "the bare item drained — the heal must never manufacture drainability without a valid marker"
echo "  ok (4) a bare Recirculation item is never ratified (the guard's own validity predicate gates the heal)"

# ── 5. a CORRUPT journal skips the heal (never backfill blind) ─────────────────────────────────────
echo 'NOT-JSON {' >> "$JOURNAL"
before=$(grep -c "\"heal\": \"journal-backfill\"" "$JOURNAL")
sweep_out=$(python3 "$SWEEP" --repo "$REPO" --auto-correct 2>&1) \
  || fail "sweep over a corrupt journal must stay fail-soft (exit 0): $sweep_out"
after=$(grep -c "\"heal\": \"journal-backfill\"" "$JOURNAL")
[ "$before" -eq "$after" ] || fail "the sweep backfilled against a CORRUPT journal (blind heal)"
echo "$sweep_out" | grep -q "journal unreadable" \
  || fail "the corrupt-journal skip was not disclosed in the sweep output: $sweep_out"
echo "  ok (5) a corrupt journal skips the backfill, disclosed (corruption is the janitor's job)"

# ── 6. GITHUB wiring: apply_github heals via node-id matching, reading ONLY uncorroborated items ───
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "github journal-heal wiring unit failed (see above)"
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
jp = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
# #302's intake IS journaled — but numberless (only project_item_id: the github read-back gap).
# The heal must match it by NODE id and leave it alone; #301 has no record at all.
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "recirculate-intake", "project_item_id": "PVTI_302",
                         "what": "recirculate-intake 'numberless'"}) + "\n")

SRC = '<!-- idc-recirc-source: {"origin":9,"what":"x","key":"k1"} -->'
views = []
def gh(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "view"]:
        views.append(args[2])
        return True, json.dumps({"body": SRC, "comments": []}), ""
    return True, "", ""
m.gh = gh
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})

ctx = {"owner": "o", "project_node": "PVT_node", "project_number": "7",
       "recirc_candidates": [{"number": 301, "item_id": "PVTI_301"},
                             {"number": 302, "item_id": "PVTI_302"}]}
changed = m.apply_github([], repo, ctx, lambda _l: None)
assert changed == 1, f"expected exactly the one heal to count as a change, got {changed}"
recs = [json.loads(l) for l in open(jp, encoding="utf-8") if l.strip()]
heals = [r for r in recs if r.get("heal") == "journal-backfill"]
assert len(heals) == 1 and heals[0].get("item") == 301 and heals[0].get("backend") == "github" \
    and heals[0].get("project_item_id") == "PVTI_301", f"bad github heal record: {heals}"
assert views == ["301"], \
    f"the heal must read ONLY uncorroborated items (node-matched #302 costs zero reads): {views}"
print("  ok (6a) github heal backfills the recordless item; the node-matched numberless intake costs zero reads")

views.clear()
changed = m.apply_github([], repo, ctx, lambda _l: None)
assert changed == 0 and views == ["301"] or changed == 0 and views == [], \
    f"second github heal run must emit nothing (changed={changed}, views={views})"
recs = [json.loads(l) for l in open(jp, encoding="utf-8") if l.strip()]
assert sum(1 for r in recs if r.get("heal")) == 1, "the github heal duplicated its record on re-run"
print("  ok (6b) the github heal is idempotent (its own record corroborates the item on the next run)")
PY

# ── 7. FINDING 3: a heal whose journal append is SWALLOWED is NOT counted as healed ────────────────
# journal_append is fail-soft (it catches permissions/full-disk/lock errors, warns, and now returns
# False). The heal's WHOLE PURPOSE is the record, so a swallowed append must count as still-stranded,
# never a (false) success repeated every sweep (codex round-14 P2). Red-when-broken: revert the heal
# to count unconditionally (`_journal_restage(...); healed += 1`) → this FAILs (healed==1, false log).
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "finding-3 (swallowed-append heal) unit failed (see above)"
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_transition as TE

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
open(os.path.join(repo, "docs", "workflow", "transition-journal.ndjson"), "w").close()  # adopted-empty: candidate uncorroborated
SRC = '<!-- idc-recirc-source: {"origin":9,"what":"stranded","key":"k1"} -->'  # a VALID provenance marker

orig = TE.journal_append
TE.journal_append = lambda *a, **k: False   # simulate a SWALLOWED append (disk full / perms / lock error)
try:
    logs = []
    healed = m.heal_unjournaled_inbox(repo, "github", None,
                                      [{"number": 301, "item_id": "PVTI_301"}],
                                      lambda c: SRC, logs.append)
finally:
    TE.journal_append = orig
assert healed == 0, f"a heal whose journal append FAILED was counted as healed: {healed}"
assert not any("backfilled the sanctioned inbox record" in l for l in logs), \
    f"a failed backfill logged a FALSE success: {logs}"
assert any("could not be journaled" in l for l in logs), \
    f"a failed backfill did not surface the unwritable-journal condition (still-stranded): {logs}"
print("  ok (7) a heal whose journal append is SWALLOWED counts as still-stranded, not a false success (round-14 P2)")
PY

# ── 8. FINDING 4: a mid-create RATE LIMIT skips the journal-backfill heal (no doomed reads) ─────────
# The capture loop breaks on RateLimitError; execution must NOT continue into the heal pass, which
# fires a `gh issue view` per uncorroborated candidate — in the SessionEnd hook (codex round-14 P2).
# Red-when-broken: drop the `if throttled: return changed` guard → the heal reads the candidate → FAILs.
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "finding-4 (throttle-skips-heal) unit failed (see above)"
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
open(os.path.join(repo, "docs", "workflow", "transition-journal.ndjson"), "w").close()

class F:   # a capture to file (drives the create loop); action=SURFACE so the re-stage loop skips it
    number = 50; item_id = "PVTI_50"; action = m.SURFACE
    captures = [{"origin": 9, "what": "scope", "area": "a", "suggested_scope": "s"}]

def boom(*a, **k):
    raise idc_gh_board.RateLimitError("secondary rate limit")
idc_gh_board.create_item = boom
m.github_existing_sources = lambda repo, ctx, log: (set(), [])
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})

views = []   # every heal-side issue read lands here (via _github_issue_text → gh issue view)
def gh(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["issue", "view"]:
        views.append(args[2]); return True, json.dumps({"body": "", "comments": []}), ""
    return True, "", ""
m.gh = gh

ctx = {"owner": "o", "project_node": "PVT_node", "project_number": "7",
       "recirc_candidates": [{"number": 301, "item_id": "PVTI_301"}]}
logs = []
m.apply_github([F()], repo, ctx, logs.append)
assert views == [], f"the heal pass fired gh issue view calls AFTER a rate limit (must skip): {views}"
assert any("skipping the journal-backfill heal" in l for l in logs), \
    f"the throttle-skip of the heal was not disclosed: {logs}"
print("  ok (8) a mid-create rate limit skips the journal-backfill heal (no doomed per-candidate reads; round-14 P2)")
PY

# ── 9. FINDING 2 (round-15): a rate limit that begins on a HEAL-side read defers the REMAINING ──────
# candidates — the round-14 short-circuit only covered create_item; a throttle that starts on the
# first `gh issue view` here must not fire the same doomed read for every remaining candidate.
# Red-when-broken: revert _github_issue_text to return "" on a rate-limited read (no raise) → the
# heal reads ALL three candidates → this FAILs.
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "finding-2 (heal-side throttle defer) unit failed (see above)"
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
open(os.path.join(repo, "docs", "workflow", "transition-journal.ndjson"), "w").close()  # adopted-empty

reads = []   # every heal-side `gh issue view` lands here
def gh(args, r):
    if args[:2] == ["issue", "view"]:
        reads.append(args[2])
        return False, "", "You have exceeded a secondary rate limit"   # a rate-limit stderr
    return True, "", ""
m.gh = gh

logs = []
healed = m.heal_unjournaled_inbox(
    repo, "github", None,
    [{"number": 301, "item_id": "PVTI_301"},
     {"number": 302, "item_id": "PVTI_302"},
     {"number": 303, "item_id": "PVTI_303"}],
    lambda c: m._github_issue_text(c["number"], repo), logs.append)
assert reads == ["301"], f"a heal-side rate limit must DEFER the remaining reads (fired: {reads})"
assert healed == 0, f"no candidate should heal under a heal-side throttle: {healed}"
assert any("throttled on a heal read" in l for l in logs), f"the heal-side throttle defer was not disclosed: {logs}"
# The defer line must NOT collide with the capture loop's throttle-STOP words (round-14 note).
assert not any("rate-limited" in l or "deferring" in l for l in logs), \
    f"the heal-side defer line reused a capture-loop throttle-STOP word: {logs}"
print("  ok (9) a rate limit on the FIRST heal read defers the remaining candidates (one read, not per-candidate; round-15 P2)")
PY

echo "PASS: a valid Recirculation ticket whose sanctioned journal record was lost is HEALED by the sweep's disclosed journal-backfill (both backends, matrix-independent, self-deduping, guard-predicate-gated, never against a corrupt journal) — the strand drains after the heal; a SWALLOWED journal append counts as still-stranded (not a false heal); a mid-create rate limit skips the heal pass entirely; a rate limit that begins on a heal read defers the remaining candidates; a bare item never gains drainability (residual: marker authenticity — #151)"
