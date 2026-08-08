#!/bin/bash
# idc-assert-class: mixed
# Phase 3 smoke — ONE canonical Wave format at every tracker boundary (issue #206).
#
# `/idc:init` provisions the board's `Wave` single-select with LABEL options (`Wave 1`; see
# commands/init.md). Waves are DERIVED as integers (idc_execution_graph.derive_waves needs the
# arithmetic), but every value that crosses a tracker boundary — written OR read back — must be that
# same label. Before the fix the conversion was missing in both directions, which produced four
# distinct live failures from one root cause:
#
#   (A) freeze emitted `set-field Wave "1"`; on a github board the option lookup is exact-label, so
#       apply refused mid-transaction ("Wave field or option '1' not on the board").
#   (B) recovering by ADDING a `1` option leaves two disjoint wave taxonomies on one board.
#   (C) idc_matrix_check.wave_number could not read the canonical `Wave 1` back, so an immutable
#       `In Progress` item contributed nothing to derive_waves' start_wave — new work was scheduled
#       INTO an already-occupied wave, defeating the parallel-safety guarantee waves exist for.
#   (D) the projection's In-Progress immutability check compared live 'Wave 1' against a derived
#       int and died ("is immutable: wave: live='Wave 1' projected=None"), blocking Plan on any
#       board that had ever built anything.
#
# Hermetic: real shipped helpers over a throwaway filesystem tracker, plus a monkeypatched
# `idc_gh_board` gh boundary serving a board whose Wave options are exactly what init provisions.
# No live GitHub.
#
# Usage: bash tests/smoke/phase3-wave-label-format.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
TRK="$SCRIPTS/idc_tracker_fs.py"
TXN="$SCRIPTS/idc_tracker_transaction.py"
PROJ="$SCRIPTS/idc_tracker_projection.py"
GRAPH="$SCRIPTS/idc_execution_graph.py"
fail() { echo "FAIL: $1"; exit 1; }

for f in "$TRK" "$TXN" "$PROJ" "$GRAPH"; do
  [ -f "$f" ] || fail "required helper not found: $f"
done

# The format under test is not a test-local opinion — it is what commands/init.md provisions.
grep -q -- '--name Wave --option "Wave 1"' "$PLUGIN/commands/init.md" \
  || fail "commands/init.md no longer provisions the Wave option as 'Wave 1' — this lane's canonical format claim is stale"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mk_matrix() {   # $1 = path; two INDEPENDENT pillars (disjoint surfaces, no blocks_on)
  cat > "$1" <<'YAML'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/a/]
    blocks_on: []
  - id: pillar-b
    wave: 2
    domain: api
    surfaces: [src/b/]
    blocks_on: []
YAML
}

# ── (A) FREEZE emits the canonical label, never a bare number ─────────────────────────────────────
A="$WORK/a"; mkdir -p "$A"
python3 "$TRK" --tracker "$A/TRACKER.md" init >/dev/null || fail "A: tracker init failed"
mk_matrix "$A/matrix.yaml"
python3 "$TXN" freeze --repo "$A" --backend filesystem --tracker "$A/TRACKER.md" \
  --matrix "$A/matrix.yaml" --baseline expected-red --label wave-fmt --out "$A/frozen.json" >/dev/null \
  || fail "A: could not freeze the planning transaction"

python3 - "$A/frozen.json" <<'PY' || fail "A: frozen set-field Wave value is not the init-provisioned 'Wave N' label"
import json, re, sys
ops = json.load(open(sys.argv[1]))["operations"]
waves = [o for o in ops if o.get("op") == "set-field" and o.get("field") == "Wave"]
if not waves:
    print("no set-field Wave operations were frozen at all"); raise SystemExit(1)
bad = [o["value"] for o in waves if not re.fullmatch(r"Wave [1-9][0-9]*", str(o["value"]))]
if bad:
    print("frozen Wave values not in the board's option format: %r" % (bad,)); raise SystemExit(1)
print("  A ok — frozen Wave values: %s" % sorted({o["value"] for o in waves}))
PY

# Phase rides the same boundary and must stay label-formatted (it already was — lock it in).
python3 - "$A/frozen.json" <<'PY' || fail "A: frozen set-field Phase value is not the init-provisioned 'Phase N' label"
import json, re, sys
ops = json.load(open(sys.argv[1]))["operations"]
ph = [o for o in ops if o.get("op") == "set-field" and o.get("field") == "Phase"]
bad = [o["value"] for o in ph if not re.fullmatch(r"Phase [1-9][0-9]*", str(o["value"]))]
if not ph or bad:
    print("frozen Phase values wrong: %r" % ([o["value"] for o in ph],)); raise SystemExit(1)
print("  A ok — frozen Phase values: %s" % sorted({o["value"] for o in ph}))
PY

# ── (B) APPLY against a github-shaped option set: the frozen value resolves; a bare number is
#        REFUSED without any board mutation (an option is NEVER created to make a write fit) ───────
python3 - "$SCRIPTS" "$A/frozen.json" <<'PY' || fail "B: github apply-layer option resolution did not behave"
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_gh_board as B

frozen = json.load(open(sys.argv[2]))["operations"]
wave_value = next(o["value"] for o in frozen if o.get("op") == "set-field" and o.get("field") == "Wave")

# A board provisioned by /idc:init: Wave carries LABEL options only.
FIELDS = {"fields": [{"id": "PVTF_wave", "name": "Wave", "options": [
    {"id": "opt1", "name": "Wave 1"}, {"id": "opt2", "name": "Wave 2"}]}]}
edits = []
def fake_gh(args, repo):
    if args[:2] == ["project", "view"]:
        return "PVT_node\n"
    if args[:2] == ["project", "field-list"]:
        return json.dumps(FIELDS)
    if args[:2] == ["project", "item-edit"]:
        edits.append(args); return ""
    raise AssertionError("unexpected gh call: %r" % (args,))
B._gh = fake_gh

errs = []
# B1 — the value Plan actually freezes resolves to a real option and issues exactly one item-edit.
try:
    B.set_single_select("o", 7, ".", "ITEM_1", "Wave", wave_value)
except Exception as e:
    errs.append("frozen Wave value %r was REFUSED by the github write door: %s" % (wave_value, e))
if len(edits) != 1:
    errs.append("expected exactly 1 item-edit for the frozen value, got %d" % len(edits))
elif "opt1" not in edits[0]:
    errs.append("item-edit did not target the 'Wave 1' option id: %r" % (edits[0],))

# B2 — a bare number is refused, and NOTHING is written (no silent new option).
before = len(edits)
try:
    B.set_single_select("o", 7, ".", "ITEM_1", "Wave", "1")
    errs.append("bare-number Wave '1' was ACCEPTED against a label-only board (must fail closed)")
except B.BoardWriteError as e:
    if "not on the board" not in str(e):
        errs.append("refusal message is not the fail-closed one: %s" % e)
except Exception as e:
    errs.append("bare-number Wave raised the wrong error type: %r" % (e,))
if len(edits) != before:
    errs.append("a refused Wave write still mutated the board (%d new item-edit calls)" % (len(edits) - before))

if errs:
    print("\n".join("  - " + e for e in errs)); raise SystemExit(1)
print("  B ok — frozen value %r resolves; bare '1' refused with no board mutation" % wave_value)
PY

# ── (C) derive_waves reads the canonical label back: an In Progress item at 'Wave 1' occupies
#        wave 1, so independent new work starts at wave 2 ─────────────────────────────────────────
C="$WORK/c"; mkdir -p "$C"
python3 "$TRK" --tracker "$C/TRACKER.md" init >/dev/null || fail "C: tracker init failed"
mk_matrix "$C/matrix.yaml"
n=$(python3 "$TRK" --tracker "$C/TRACKER.md" create --title "pillar-a" --stage Buildable \
      --wave "Wave 1" --phase "Phase 1" --domain ui) || fail "C: create failed"
python3 "$TRK" --tracker "$C/TRACKER.md" move --num "$n" --status "In Progress" >/dev/null \
  || fail "C: move to In Progress failed"

python3 "$GRAPH" --matrix "$C/matrix.yaml" --backend filesystem --tracker "$C/TRACKER.md" > "$C/graph.json" \
  || fail "C: execution graph would not compile against a live 'Wave 1'"
python3 - "$C/graph.json" <<'PY' || fail "C: an In Progress item at 'Wave 1' did not occupy wave 1"
import json, sys
w = json.load(open(sys.argv[1]))["waves"]
errs = []
if w.get("pillar-a") != 1:
    errs.append("In Progress pillar-a's live 'Wave 1' read back as %r, not 1" % (w.get("pillar-a"),))
if w.get("pillar-b") == 1:
    errs.append("pillar-b was scheduled INTO wave 1, which an immutable In Progress item occupies")
if not errs and (w.get("pillar-b") or 0) < 2:
    errs.append("pillar-b landed in %r; independent new work must start after the occupied wave" % (w.get("pillar-b"),))
if errs:
    print("\n".join("  - " + e for e in errs)); raise SystemExit(1)
print("  C ok — derived waves: %s" % w)
PY

# ── (D) the projection does not die on a live, correctly-valued In Progress item ──────────────────
python3 "$PROJ" --matrix "$C/matrix.yaml" --backend filesystem --tracker "$C/TRACKER.md" > "$C/proj.json" 2> "$C/proj.err" \
  || fail "D: projection died on a live 'Wave 1' In Progress item: $(cat "$C/proj.err")"
grep -q "is immutable" "$C/proj.err" && fail "D: projection reported a false immutability mismatch: $(cat "$C/proj.err")"

# ── (E) no churn: an item already at the canonical wave freezes NO redundant set-field ────────────
E="$WORK/e"; mkdir -p "$E"
python3 "$TRK" --tracker "$E/TRACKER.md" init >/dev/null || fail "E: tracker init failed"
mk_matrix "$E/matrix.yaml"
# Both pillars are independent with disjoint surfaces, so derive_waves puts BOTH in wave 1.
# Seed the board at exactly that answer, in the canonical format, so any frozen Wave op is churn.
for spec in "pillar-a:ui" "pillar-b:api"; do
  id="${spec%%:*}"; dm="${spec##*:}"
  python3 "$TRK" --tracker "$E/TRACKER.md" create --title "$id" --stage Buildable \
    --wave "Wave 1" --phase "Phase 1" --domain "$dm" >/dev/null || fail "E: create $id failed"
done
# A board that already says exactly what Plan derives has NOTHING to do, so the freeze must come
# back expected-GREEN. Pre-#206 the format mismatch manufactured a Wave rewrite for every item, and
# this same command failed with "expected expected-green, actual expected-red".
python3 "$TXN" freeze --repo "$E" --backend filesystem --tracker "$E/TRACKER.md" \
  --matrix "$E/matrix.yaml" --baseline expected-green --label wave-fmt-e --out "$E/frozen.json" 2> "$E/freeze.err" >/dev/null \
  || fail "E: an already-canonical board did not freeze clean: $(cat "$E/freeze.err")"
python3 - "$E/frozen.json" <<'PY' || fail "E: a board already at the canonical Wave format still churned set-field ops"
import json, sys
ops = json.load(open(sys.argv[1]))["operations"]
churn = [o for o in ops if o.get("op") == "set-field" and o.get("field") == "Wave"]
if churn:
    print("redundant Wave writes against an already-correct board: %r" % ([o["value"] for o in churn],))
    raise SystemExit(1)
print("  E ok — no redundant Wave set-field ops")
PY

# ── (F) doctor DETECTS an already-polluted board (prose integrity + a live probe rehearsal) ───────
# The emission fix stops new pollution; it cannot un-split a board a pre-#206 runtime already
# drained. doctor 9d is the read-only detector that points at it (it never mutates the board).
DOC="$PLUGIN/commands/doctor.md"
grep -q 'wave-options-split' "$DOC" || fail "F: doctor.md has no 9d Wave-taxonomy detection"
grep -q 'wave-options-ok' "$DOC"    || fail "F: doctor.md 9d has no clean-board branch"
grep -q 'never mutates the board' "$DOC" || fail "F: doctor.md 9d must keep doctor's read-only contract explicit"

# Rehearse 9d's ACTUAL option-name classifier against both board shapes, so the published one-liner
# is proven to classify — not merely present in the prose. The literal is asserted to still BE in
# doctor.md, so the prose and this proof cannot drift apart silently.
grep -qF "grep -qxE '[0-9]+'" "$DOC" || fail "F: doctor.md 9d no longer carries the bare-number option classifier this lane rehearses"
printf 'Wave 1\nWave 2\n1\n2\n' | grep -qxE '[0-9]+' || fail "F: 9d's classifier misses a split Wave option set"
printf 'Wave 1\nWave 2\n'       | grep -qxE '[0-9]+' && fail "F: 9d's classifier false-flags a clean Wave option set"
echo "  F ok — doctor 9d detects a split Wave taxonomy and passes a clean one"

# ── (G) KNOWN LIMIT, pinned: a wave whose option was never pre-seeded fails CLOSED and names the
#        value it wanted — it never mints an option to make the write fit ────────────────────────
# /idc:init seeds `Wave` with `Wave 1` only, and `ensure-field` is create-only (it returns
# skipped-existing rather than appending), so nothing ever adds `Wave 2`. Canonical formatting does
# NOT change that: it is a separate pre-seeding gap that `Phase` and `Domain` share. What this fix
# owes is that the boundary stays HONEST — refuse, name the value, mutate nothing.
python3 - "$SCRIPTS" <<'PY' || fail "G: a never-seeded wave option did not fail closed cleanly"
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_gh_board as B

FIELDS = {"fields": [{"id": "PVTF_wave", "name": "Wave",
                      "options": [{"id": "opt1", "name": "Wave 1"}]}]}   # exactly what init seeds
edits = []
def fake_gh(args, repo):
    if args[:2] == ["project", "view"]:
        return "PVT_node\n"
    if args[:2] == ["project", "field-list"]:
        return json.dumps(FIELDS)
    if args[:2] == ["project", "item-edit"]:
        edits.append(args); return ""
    raise AssertionError("unexpected gh call: %r" % (args,))
B._gh = fake_gh

errs = []
try:
    B.set_single_select("o", 7, ".", "ITEM_1", "Wave", "Wave 2")
    errs.append("'Wave 2' was accepted against a board that only carries 'Wave 1'")
except B.BoardWriteError as e:
    if "'Wave 2'" not in str(e):
        errs.append("refusal does not name the value it wanted: %s" % e)
    if "not on the board" not in str(e):
        errs.append("refusal is not the fail-closed message: %s" % e)
except Exception as e:
    errs.append("wrong error type for an unseeded option: %r" % (e,))
if edits:
    errs.append("a refused write still mutated the board: %r" % (edits,))
if errs:
    print("\n".join("  - " + e for e in errs)); raise SystemExit(1)
print("  G ok — an unseeded 'Wave 2' is refused by name, with no board mutation")
PY

echo "PASS: phase3-wave-label-format"
