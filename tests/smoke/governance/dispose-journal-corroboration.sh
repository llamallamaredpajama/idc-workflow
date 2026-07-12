#!/bin/bash
# dispose-journal-corroboration.sh — governance scenario: the JOURNAL-CORROBORATION layer on the two
# forgeable dispose guards (#150 W2 close-out ruling; residual tracked as #151).
#
# WHY: `drained` and `retired` read board-side evidence (provenance markers, link records) that rides
# item bodies/comments — ALL writable through the sanctioned adapter. Marker-shape checks alone are
# therefore forgeable: raw-restage a Buildable item, comment a well-formed marker onto it, dispose it
# to Done with no verdict. The corroboration layer requires the item's SANCTIONED journal record too
# (the sweep's re-stage / the engine's intake for drained; the engine's link record for retired), so a
# forger must also fabricate journal lines — and an unjournaled raw Stage flip surfaces as replay
# divergence once the janitor's replay check defaults on (W3).
#
# GUARD-SURFACE ENUMERATION (#150 W2 — the class, not the instance):
#   dimensions: disposition {gate-approved, retired, drained} × evidence source {board marker/link,
#   journal record} × backend {filesystem, github} × era {pre-journal legacy, journaled} × actor
#   {sanctioned producer, forger through adapter doors}. Coverage map:
#   - close (verdict door) + missing/unknown/malformed disposition + guard-free terminal shapes:
#     engine-terminal-fail-closed.sh; Stage no-laundering: journal-replay.sh cases 2d/2e.
#   - gate-approved (identity + BOUND approval artifact; deliberately NOT journal-corroborated —
#     gates are adapter-created operator artifacts): dispose-gate-approved.sh, dispose-gate-approved-github.sh.
#   - retired/drained board-shape conjuncts (stage/status/marker payload, both backends):
#     dispose-retired.sh, dispose-drained.sh, dispose-github-paths.sh.
#   - retired/drained journal corroboration × era × forger (fs + hermetic github), rotation-archive
#     segments, corrupt-journal fail-closed, pre-journal carve-out: THIS file.
#   RESIDUAL (documented, #151): these guards prove provenance SHAPE + journal corroboration, not
#   producer AUTHENTICITY — a writer with repo+board access can forge both; the raw setField-Stage
#   door itself closes only via the stage-transition engine op tracked in #151.
#
# Red-when-broken (the mutation proof): drop the corroboration call from check_drained/check_retired
# → the forge cases (2, 5) close to Done → this FAILs. Break rotation-awareness (scan only the live
# journal) → case 8 FAILs. Make corrupt-journal lenient → case 7 FAILs. Swallow RateLimitError in
# the node-lookup fallback (_gh_node_for_corroboration's broad except) → case 10e FAILs. Remove the
# flock → case 11 FAILs. Open the sidecar lock with mode "a" (create) → case 12 FAILs (read-only scan
# mints the lock). Drop the absent-lock lock-appearance re-check → case 13 FAILs (fail-open race).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

EXTRA=""
trap 'rm -rf "$REPO" $EXTRA' EXIT
new_tracker() { local t; t="$(gov_new_tracker)" || fail "could not mint an extra tracker"; EXTRA="$EXTRA $(dirname "$t")"; printf '%s' "$t"; }

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
SRC_MARKER='<!-- idc-recirc-source: {"origin":9,"what":"forged scope","key":"k-forge"} -->'
DISC_MARKER='<!-- idc-discovery: {"what":"a swept rogue"} -->'

# ── 1. watermark: one engine create makes the journal's adoption watermark real ────────────────────
a1="$(eng create-ticket --title 'watermark anchor' --stage Buildable --status Todo)" \
  || fail "could not engine-create the watermark anchor"

# ── 2. FORGE-DENY drained: raw-staged item + well-formed marker, NO sanctioned journal record ──────
f="$(gov_seed_item "$T" --title 'recirc: forged via raw restage' --stage Recirculation --status Todo --comment "$SRC_MARKER")" \
  || fail "could not raw-seed the forged recirc item"
out=$(eng dispose --disposition drained --num "$f" 2>&1) && \
  fail "drained closed a raw-staged item with a forged marker and NO corroborating journal record (the #151 forge class)"
echo "$out" | grep -q "corroborating journal record" || fail "the drained denial does not explain the missing corroboration: $out"
echo "$out" | grep -q "recirculate-intake" || fail "the drained denial does not NAME the remediation (engine intake / sweep re-stage): $out"
[ "$(gov_field "$T" "$f" Status)" != "Done" ] || fail "the denied forge still drove the item to Done"
echo "  ok (2) a raw-staged item with a well-formed marker but no journal record is REFUSED, naming the remediation"

# ── 3. GREEN drained via the engine intake door (journaled create) ─────────────────────────────────
i="$(eng recirculate-intake --title 'recirc(nit): engine-filed' --body "$SRC_MARKER")" \
  || fail "could not file the ticket through the engine intake door"
eng dispose --disposition drained --num "$i" >/dev/null 2>&1 \
  || fail "drained refused an engine-intaken ticket (corroboration must accept the recirculate-intake record)"
[ "$(gov_field "$T" "$i" Status)" = "Done" ] || fail "the engine-intaken ticket did not reach Done"
grep -q '"corroboration": "recirculate-intake"' "$JOURNAL" \
  || fail "the dispose record does not journal WHICH corroborating record admitted it (intake)"
echo "  ok (3) an engine-intaken ticket drains; the dispose record journals corroboration=recirculate-intake"

# ── 4. GREEN drained via the sweep's REAL re-stage journal record ──────────────────────────────────
s="$(gov_seed_item "$T" --title 'recirc: swept rogue' --stage Recirculation --status Todo --comment "$DISC_MARKER")" \
  || fail "could not seed the swept rogue"
python3 - "$GOV_PLUGIN/scripts" "$REPO" "$s" <<'PY' || fail "could not journal the sweep re-stage (real producer)"
import sys
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as SW
SW._journal_restage(sys.argv[2], "filesystem", "TRACKER.md", int(sys.argv[3]))
PY
eng dispose --disposition drained --num "$s" >/dev/null 2>&1 \
  || fail "drained refused a sweep-restaged rogue whose re-stage IS journaled (corroboration must accept recirc-restage)"
[ "$(gov_field "$T" "$s" Status)" = "Done" ] || fail "the sweep-restaged rogue did not reach Done"
grep -q '"corroboration": "recirc-restage"' "$JOURNAL" \
  || fail "the dispose record does not journal corroboration=recirc-restage"
echo "  ok (4) a sweep-restaged rogue drains via its journaled re-stage; corroboration=recirc-restage journaled"

# ── 5. FORGE-DENY retired: raw ADAPTER link only (board record, no engine journal) ─────────────────
p="$(eng create-pointer --title 'consideration: to forge-retire')" || fail "could not create the pointer"
c="$(eng create-ticket --title 'buildable: raw-linked child')" || fail "could not create the child"
python3 "$GOV_TRK" --tracker "$T" link --parent "$p" --child "$c" --kind sub >/dev/null \
  || fail "could not raw-link through the adapter"
out=$(eng dispose --disposition retired --num "$p" --child "$c" 2>&1) && \
  fail "retired accepted a raw adapter link with NO journaled engine link record (the #151 forge class)"
echo "$out" | grep -q "not journaled" || fail "the retired denial does not explain the missing journal record: $out"
echo "$out" | grep -q -- "link --parent $p --child $c" || fail "the retired denial does not NAME the engine re-link remediation: $out"
[ "$(gov_field "$T" "$p" Status)" != "Done" ] || fail "the denied retire still drove the pointer to Done"
echo "  ok (5) a board-only (raw adapter) decomposition link is REFUSED, naming the engine re-link remediation"

# ── 6. GREEN retired: the engine link journals the decomposition record; the SAME pointer retires ──
eng link --parent "$p" --child "$c" --kind sub >/dev/null 2>&1 || fail "could not engine-link the child"
eng dispose --disposition retired --num "$p" --child "$c" >/dev/null 2>&1 \
  || fail "retired refused a pointer whose decomposition link IS journaled"
[ "$(gov_field "$T" "$p" Status)" = "Done" ] || fail "the engine-linked pointer did not reach Done"
grep -q '"corroboration": "link"' "$JOURNAL" \
  || fail "the dispose record does not journal corroboration=link"
echo "  ok (6) after an engine re-link the same pointer retires; corroboration=link journaled"

# ── 6b. JOURNAL PREDICATE: a kind=blocks link record is NEVER decomposition corroboration ──────────
# The board conjuncts (dispose-retired.sh / dispose-github-paths.sh) refuse a blocks-edge at the
# BOARD; this pins the JOURNAL half — `_link_record_matches` requires the DECOMPOSITION contract
# (codex round-13 P2): a record CARRYING a `kind` must say "sub"; a kind-LESS record predates kind
# journaling and is tolerated (the legacy carve-out). Direct unit so the kind conjunct is isolated
# from the board check. Mutation proof: delete `if kind is not None and kind != "sub": return False`
# → the kind=blocks assertion FAILs (a dependency edge would corroborate a pointer retirement).
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "the journal link-record predicate does not enforce the kind=sub decomposition contract (see above)"
import sys
sys.path.insert(0, sys.argv[1])
import idc_transition as E
SUB   = {"op": "link", "parent": 5, "child": 6, "kind": "sub"}
BLOCK = {"op": "link", "parent": 5, "child": 6, "kind": "blocks"}
LEGACY = {"op": "link", "parent": 5, "child": 6}          # pre-round-13: no kind field
NOTLINK = {"op": "move", "parent": 5, "child": 6, "kind": "sub"}
assert E._link_record_matches(SUB, 5, 6) is True,  "a kind=sub link record must corroborate the decomposition"
assert E._link_record_matches(BLOCK, 5, 6) is False, "a kind=blocks link record must NOT corroborate a decomposition (it is a dependency edge)"
assert E._link_record_matches(LEGACY, 5, 6) is True, "a kind-LESS (pre-round-13) link record must be tolerated (legacy carve-out)"
assert E._link_record_matches(SUB, 5, 7) is False, "a kind=sub record naming a DIFFERENT child must not match"
assert E._link_record_matches(NOTLINK, 5, 6) is False, "a non-link op must never match the link predicate"
print("  ok (6b) the journal link-record predicate enforces kind=sub (rejects kind=blocks; tolerates a kind-less legacy record)")
PY

# ── 7. CORRUPT journal: corroboration FAILS CLOSED (a damaged journal must never admit a dispose) ──
T2="$(new_tracker)"; REPO2="$(dirname "$T2")"
eng2() { python3 "$ENGINE" --repo "$REPO2" --backend filesystem --tracker "$T2" "$@"; }
g="$(eng2 recirculate-intake --title 'recirc(nit): then corrupt' --body "$SRC_MARKER")" \
  || fail "could not engine-intake in the corrupt-journal repo"
echo 'NOT-JSON {' >> "$REPO2/docs/workflow/transition-journal.ndjson"
out=$(eng2 dispose --disposition drained --num "$g" 2>&1) && \
  fail "drained closed an item while the journal was CORRUPT — a damaged journal must fail corroboration closed, not grant the legacy carve-out"
echo "$out" | grep -q "cannot be read for corroboration" || fail "the corrupt-journal denial is not explained: $out"
[ "$(gov_field "$T2" "$g" Status)" != "Done" ] || fail "the corrupt-journal denial still drove the item to Done"
echo "  ok (7) a corrupt journal fails corroboration CLOSED (corruption never unlocks the carve-out)"

# ── 8. ROTATION: a corroborating record living in an ARCHIVED segment still admits the dispose ─────
T3="$(new_tracker)"; REPO3="$(dirname "$T3")"
eng3() { python3 "$ENGINE" --repo "$REPO3" --backend filesystem --tracker "$T3" "$@"; }
r="$(eng3 recirculate-intake --title 'recirc(nit): rotated' --body "$SRC_MARKER")" \
  || fail "could not engine-intake in the rotation repo"
mkdir -p "$REPO3/docs/workflow/journal-archive"
mv "$REPO3/docs/workflow/transition-journal.ndjson" "$REPO3/docs/workflow/journal-archive/0001-rotated.ndjson" \
  || fail "could not archive the journal segment"
eng3 dispose --disposition drained --num "$r" >/dev/null 2>&1 \
  || fail "drained refused a ticket whose intake record lives in a ROTATED archive segment — corroboration must scan journal-archive/ like replay does"
[ "$(gov_field "$T3" "$r" Status)" = "Done" ] || fail "the rotated-segment ticket did not reach Done"
# The admit must come from the ARCHIVED record, not the legacy carve-out: with the live segment gone,
# a live-only scan sees an empty journal (watermark None) and would launder the admit through
# pre-journal-legacy — so the dispose record's journaled corroboration is the distinguishing observable.
grep -q '"corroboration": "recirculate-intake"' "$REPO3/docs/workflow/transition-journal.ndjson" \
  || fail "the rotated-segment dispose was not admitted BY the archived intake record (corroboration!=recirculate-intake — an archive-blind scan laundered it through the legacy carve-out)"
echo "  ok (8) corroboration is rotation-aware (archived segments count; watermark included; admit journaled as recirculate-intake)"

# ── 9. LEGACY carve-out: an item BELOW the adoption watermark keeps marker-only semantics ──────────
T4="$(new_tracker)"; REPO4="$(dirname "$T4")"
eng4() { python3 "$ENGINE" --repo "$REPO4" --backend filesystem --tracker "$T4" "$@"; }
l1="$(gov_seed_item "$T4" --title 'recirc: pre-journal legacy' --stage Recirculation --status Todo --comment "$SRC_MARKER")" \
  || fail "could not seed the legacy recirc item"
gov_seed_item "$T4" --title 'another pre-journal item' --stage Buildable --status Todo >/dev/null \
  || fail "could not seed the second legacy item"
w="$(eng4 create-ticket --title 'journal adoption begins here')" || fail "could not engine-create the watermark item"
[ "$w" -gt "$l1" ] || fail "test harness: the watermark item is not above the legacy item"
eng4 dispose --disposition drained --num "$l1" >/dev/null 2>&1 \
  || fail "drained refused a pre-journal LEGACY item (below the adoption watermark) — the carve-out must keep marker-only semantics for items that predate journaling"
[ "$(gov_field "$T4" "$l1" Status)" = "Done" ] || fail "the legacy item did not reach Done"
grep -q '"corroboration": "pre-journal-legacy"' "$REPO4/docs/workflow/transition-journal.ndjson" \
  || fail "the legacy dispose record does not DISCLOSE it rode the pre-journal carve-out"
echo "  ok (9) a below-watermark legacy item drains marker-only; the dispose record discloses corroboration=pre-journal-legacy"
# (The no-journal-at-all pre-adoption board — watermark None — is exercised by dispose-drained.sh /
#  dispose-retired.sh, whose raw-seeded happy paths ride exactly that carve-out.)

# ── 10. GITHUB: project_item_id fallback + the same forge denial (hermetic, monkeypatched) ─────────
T5="$(new_tracker)"; REPO5="$(dirname "$T5")"
python3 - "$GOV_PLUGIN/scripts" "$REPO5" <<'PY' || fail "github corroboration unit failed (see above)"
import json, os, sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B, idc_gh_close as GC

SRC = '<!-- idc-recirc-source: {"origin":9,"what":"x","key":"k1"} -->'
STATE = {"PVTI_8": {"stage": "Recirculation", "status": "Todo"},
         "PVTI_12": {"stage": "Recirculation", "status": "Todo"}}
ISSUE = {"8": {"body": SRC, "comments": []}, "12": {"body": SRC, "comments": []}}
B._gh = lambda args, r: json.dumps(ISSUE[args[2]]) if args[:2] == ["issue", "view"] else (_ for _ in ()).throw(AssertionError(args))
B.fetch_item = lambda iid, r: STATE[iid]
closed = []
GC.close_issue = lambda o, p, i, r, item_id=None: closed.append(i)
ctx = E.github_ctx(repo, "o", "1", itemid_cache={8: "PVTI_8", 12: "PVTI_12"})

# Journal: adoption watermark exists (a create with item=1); ticket #8's intake record lost its
# issue-number read-back (item ABSENT) and carries only project_item_id — the documented best-effort
# gap in _github_created_issue_number / the sweep's _github_issue_number. #12 has NO record at all.
jp = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
os.makedirs(os.path.dirname(jp), exist_ok=True)
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "create-ticket", "item": 1, "what": "create-ticket 'anchor'"}) + "\n")
    fh.write(json.dumps({"op": "recirculate-intake", "project_item_id": "PVTI_8",
                         "what": "recirculate-intake 'numberless'"}) + "\n")

E.run("dispose", ctx, num=8, disposition="drained")
assert closed == [8], f"github drained refused a journaled intake whose record carries only project_item_id: {closed}"
print("  ok (10a) github corroboration matches a NUMBERLESS intake record via its project_item_id (no false denial)")

closed.clear()
try:
    E.run("dispose", ctx, num=12, disposition="drained")
    raise SystemExit("FAIL: github drained closed a marker-only item with no journal record (forge class)")
except E.TransitionError:
    pass
assert closed == [], f"the denied github forge still closed: {closed}"
print("  ok (10b) github drained refuses a marker-only item above the watermark (same forge denial as fs)")

# 10c — an ADOPTED journal whose only create is NUMBERLESS (watermark None): the legacy carve-out
# must NOT open (that would fail the guard open for the whole board on one read-back failure —
# codex r8 P2); corroboration is required, and the project_item_id fallback still admits the
# genuine numberless record while the marker-only item is refused.
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "recirculate-intake", "project_item_id": "PVTI_8",
                         "what": "recirculate-intake 'numberless'"}) + "\n")
closed.clear()
E.run("dispose", ctx, num=8, disposition="drained")
assert closed == [8], f"numberless-only journal refused its OWN journaled item (project_item_id match): {closed}"
closed.clear()
try:
    E.run("dispose", ctx, num=12, disposition="drained")
    raise SystemExit("FAIL: a numberless-only journal (watermark None but ADOPTED) granted the "
                     "legacy carve-out to a marker-only item — the fail-open codex r8 P2 class")
except E.TransitionError:
    pass
assert closed == [], f"the denied numberless-era forge still closed: {closed}"
print("  ok (10c) an adopted-but-numberless journal requires corroboration (no blanket carve-out; fallback still admits)")

# 10d — a numberless create VOIDS the below-watermark carve-out (codex r9 P1): with a numberless
# create followed by a NUMBERED create (#7 → watermark 7), an item numbered BELOW the watermark
# (#5) may still be post-adoption (the true first create is the numberless one), so it must be
# DENIED without corroboration — never misclassified as pre-journal legacy.
STATE["PVTI_5"] = {"stage": "Recirculation", "status": "Todo"}
ISSUE["5"] = {"body": SRC, "comments": []}
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5", 8: "PVTI_8", 12: "PVTI_12"})
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "recirculate-intake", "project_item_id": "PVTI_8",
                         "what": "recirculate-intake 'numberless'"}) + "\n")
    fh.write(json.dumps({"op": "create-ticket", "item": 7, "what": "create-ticket 'numbered later'"}) + "\n")
closed.clear()
try:
    E.run("dispose", ctx, num=5, disposition="drained")
    raise SystemExit("FAIL: a numberless create left the numbered watermark trusted — item #5 "
                     "(below watermark 7, no record) rode the legacy carve-out (codex r9 P1 class)")
except E.TransitionError:
    pass
assert closed == [], f"the denied below-watermark forge still closed: {closed}"
print("  ok (10d) a numberless create voids the numbered-watermark carve-out (below-watermark items need corroboration)")

# 10e — a RATE-LIMITED node lookup re-raises RateLimitError (the resumable exit-3 contract), never a
# missing-corroboration denial (codex round-10 P2). The node fallback is best-effort for ORDINARY
# failures (degrades to issue-number matching), but a throttle is transient and run-global —
# converting it into a denial mis-signals a permanent guard failure to the drain's exit-code contract.
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "create-ticket", "item": 1, "what": "create-ticket 'anchor'"}) + "\n")
real_get_item, real_resolve = E.get_item, GC._resolve_item_id
E.get_item = lambda c, n: {"stage": "Recirculation", "status": "Todo"}   # board reads stay green
def _throttled(*a, **k):
    raise B.RateLimitError("9999999999")   # only the node lookup hits the limit
GC._resolve_item_id = _throttled
closed.clear()
try:
    E.run("dispose", E.github_ctx(repo, "o", "1", itemid_cache={}), num=12, disposition="drained")
    raise SystemExit("FAIL: a rate-limited node lookup neither paused nor denied")
except B.RateLimitError:
    pass
except E.TransitionError:
    raise SystemExit("FAIL: a rate-limited node lookup was converted into a missing-corroboration "
                     "denial (exit-2 class) instead of re-raising the resumable RateLimitError (exit-3)")
finally:
    E.get_item, GC._resolve_item_id = real_get_item, real_resolve
assert closed == [], f"the rate-limited dispose still closed: {closed}"
print("  ok (10e) a rate-limited node lookup re-raises RateLimitError (resumable), never a corroboration denial")
PY
[ $? -eq 0 ] || exit 1

# ── 11. The corroboration scan HONORS the journal sidecar lock (rotation race, codex r9 P1) ────────
# A rotation's read-then-os.replace moves records between the live segment and the archive; an
# unlocked scan can miss them mid-move, see no creates, and grant the carve-out (fail open). The
# scan must block on the STABLE sidecar `<journal>.lock` while a rotation-style LOCK_EX holder owns
# it. Red-when-broken: remove the flock from scan_journal_strict → the scan returns while the lock
# is held → this FAILs.
T6="$(new_tracker)"; REPO6="$(dirname "$T6")"
python3 - "$GOV_PLUGIN/scripts" "$REPO6" <<'PY' || fail "corroboration scan lock unit failed (see above)"
import fcntl, json, os, subprocess, sys, threading, time
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_journal_replay as RP

jp = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
os.makedirs(os.path.dirname(jp), exist_ok=True)
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "create-ticket", "item": 1, "what": "create-ticket 'anchor'"}) + "\n")

# A rotation-style holder takes LOCK_EX on the sidecar in ANOTHER process (flock is per-process).
holder = subprocess.Popen([sys.executable, "-c", (
    "import fcntl, sys, time\n"
    "fh = open(sys.argv[1], 'a')\n"
    "fcntl.flock(fh.fileno(), fcntl.LOCK_EX)\n"
    "print('HELD', flush=True)\n"
    "time.sleep(15)\n"), jp + ".lock"], stdout=subprocess.PIPE, text=True)
assert holder.stdout.readline().strip() == "HELD", "the lock holder never acquired the sidecar"

result = {}
def scan():
    result["value"] = RP.scan_journal_strict(jp)
t = threading.Thread(target=scan, daemon=True)
t.start()
t.join(timeout=2.0)
if not t.is_alive():
    holder.kill()
    raise SystemExit("FAIL: scan_journal_strict returned while the rotation sidecar lock was held "
                     "— an unlocked scan can race a rotation mid-move and fail the guard open")
holder.kill(); holder.wait()
t.join(timeout=10.0)
assert not t.is_alive(), "the scan never completed after the lock was released"
entries, err = result["value"]
assert err is None and len(entries) == 1, f"post-release scan wrong: {result['value']}"
print("  ok (11) the corroboration scan WAITS on the rotation sidecar lock, then reads correctly")
PY
[ $? -eq 0 ] || exit 1

# ── 12/13. scan_journal_strict is READ-ONLY + absent-lock RACE-SAFE (codex round-16 P2) ─────────────
# 12: a scan of a lockless repo (an older install, or a governed repo before the first journaling op)
#     reads the journal correctly and NEVER mints the `<journal>.lock` sidecar — /idc:doctor Row 9
#     `--journal` (via _proven_gates) promises a read-only check. Red-when-broken: reopen the lock with
#     mode "a" → the scan mints the lock → case 12 FAILs.
# 13: not minting the lock must NOT reopen the round-9 fail-open race. A writer that starts mid-scan
#     mints the lock FIRST (its first act), so the lock APPEARING is the race signal; the scan retries
#     through the now-present shared lock and reads consistently. Red-when-broken: drop the
#     lock-appearance re-check (return the unlocked read unconditionally) → no retry → case 13 FAILs.
T7="$(new_tracker)"; REPO7="$(dirname "$T7")"
python3 - "$GOV_PLUGIN/scripts" "$REPO7" <<'PY' || fail "read-only / race-safe scan unit failed (see above)"
import json, os, sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_journal_replay as RP

jp = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
os.makedirs(os.path.dirname(jp), exist_ok=True)
with open(jp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "create-ticket", "item": 1, "what": "create-ticket 'anchor'"}) + "\n")
lock = jp + ".lock"

# (12) read-only contract: a lockless repo reads correctly and no lock file is minted.
assert not os.path.exists(lock), "test setup: the lock must be absent"
entries, err = RP.scan_journal_strict(jp)
assert err is None and len(entries) == 1, f"the lockless read is wrong: {entries}, {err}"
assert not os.path.exists(lock), "a READ-ONLY scan MINTED the lock sidecar (round-16 P2 — mutates the repo)"
print("  ok (12) scan_journal_strict reads a lockless repo without MINTING the lock sidecar (read-only)")

# (13) absent-lock race: a writer that mints the lock during the FIRST (unlocked) read is detected —
# the scan retries through the now-present shared lock and reads consistently (no fail-open, round-9).
calls = {"n": 0}
real = RP._read_journal_segments
def racing(path):
    calls["n"] += 1
    if calls["n"] == 1:
        open(lock, "a").close()   # a concurrent writer mints the lock mid-scan (its first act)
    return real(path)
RP._read_journal_segments = racing
try:
    e2, r2 = RP.scan_journal_strict(jp)
finally:
    RP._read_journal_segments = real
assert calls["n"] == 2, f"the scan did NOT retry after the lock appeared mid-scan (fail-open race; calls={calls['n']})"
assert r2 is None and len(e2) == 1, f"the retry-through-lock read is wrong: {e2}, {r2}"
assert os.path.exists(lock), "test invariant: the writer's lock must persist"
print("  ok (13) a lock that APPEARS mid-scan is detected — the scan retries through the shared lock (no fail-open; round-16 P2)")
PY
[ $? -eq 0 ] || exit 1

echo "PASS: drained/retired are journal-CORROBORATED — a sanctioned record (sweep re-stage, engine intake, engine link; rotation-archive segments included) must name the item, marker-only forgeries are refused with remediation-naming denials, a corrupt journal fails closed, pre-journal legacy items keep marker-only semantics and DISCLOSE it, github's numberless-create gap is bridged by project_item_id, and scan_journal_strict is read-only (never mints the lock sidecar) AND absent-lock race-safe (residual: producer authenticity — #151)"
