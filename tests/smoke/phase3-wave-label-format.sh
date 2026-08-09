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

# ── (H) the immutability check compares waves SEMANTICALLY, so a LEGACY bare wave on an In Progress
#        item reads as equivalent — the very tolerance tracker_wave_number exists to provide ───────
# Arm D covers a board already written in the canonical format. The board this fix is FOR is the
# pre-#206 one: its In Progress item still stores a bare `1`. derive_waves reads that fine (arm C's
# tolerance), so the projection canonicalizes it to `Wave 1` — and a RAW comparison then called the
# item an immutable mismatch and aborted `/idc:plan` on exactly the legacy board the tolerant reader
# was added to support ("is immutable: wave: live='1' projected='Wave 1'").
H="$WORK/h"; mkdir -p "$H"
python3 "$TRK" --tracker "$H/TRACKER.md" init >/dev/null || fail "H: tracker init failed"
mk_matrix "$H/matrix.yaml"
n=$(python3 "$TRK" --tracker "$H/TRACKER.md" create --title "pillar-a" --stage Buildable \
      --wave "1" --phase "Phase 1" --domain ui) || fail "H: create failed"
python3 "$TRK" --tracker "$H/TRACKER.md" move --num "$n" --status "In Progress" >/dev/null \
  || fail "H: move to In Progress failed"

python3 "$PROJ" --matrix "$H/matrix.yaml" --backend filesystem --tracker "$H/TRACKER.md" \
  > "$H/proj.json" 2> "$H/proj.err" \
  || fail "H: projection aborted on a LEGACY bare-wave In Progress item: $(cat "$H/proj.err")"
grep -q "is immutable" "$H/proj.err" \
  && fail "H: projection reported a false immutability mismatch on a legacy bare wave: $(cat "$H/proj.err")"

# What the projection EMITS is split by whether Plan may WRITE the row, because canonicalizing a
# wave IS a write. `pillar-a` is In Progress (immutable), so it reports the spelling it actually
# holds — projecting the canonical label there manufactured a set-field against an immutable item
# (arm J). `pillar-b` has no live row, so Plan creates it and the canonical label stands: that is
# where the emission fix (arms A/B) lives, and it must NOT be undone.
python3 - "$H/proj.json" <<'PY' || fail "H: projection emits the wrong wave for a mutable/immutable row"
import json, re, sys
rows = {r["logical_id"]: r["wave"] for r in json.load(open(sys.argv[1]))["projection"]}
errs = []
if rows.get("pillar-a") != "1":
    errs.append("immutable In Progress row's live '1' was respelled to %r — a write Plan may not make"
                % (rows.get("pillar-a"),))
if not re.fullmatch(r"Wave [1-9][0-9]*", str(rows.get("pillar-b"))):
    errs.append("a row Plan MAY write projected %r, not the canonical 'Wave N' label" % (rows.get("pillar-b"),))
if errs:
    print("\n".join("  - " + e for e in errs)); raise SystemExit(1)
print("  H ok — legacy bare '1' accepted as wave 1; immutable row keeps %r, writable row gets %r"
      % (rows["pillar-a"], rows["pillar-b"]))
PY

# H2 — the OTHER immutable fields are still compared verbatim. They are projected with no transform
# between the two sides (a fixed `Buildable`, the live status echoed back, the matrix's own literal
# phase/domain), so raw equality stays correct there and must keep firing.
python3 "$TRK" --tracker "$H/TRACKER.md" set --num "$n" --field Phase --value "Phase 9" >/dev/null \
  || fail "H2: could not skew the live phase"
python3 "$PROJ" --matrix "$H/matrix.yaml" --backend filesystem --tracker "$H/TRACKER.md" \
  >/dev/null 2> "$H/skew.err" \
  && fail "H2: a genuinely-divergent immutable field no longer aborts the projection"
grep -q "is immutable" "$H/skew.err" \
  || fail "H2: projection failed for the wrong reason: $(cat "$H/skew.err")"
grep -q "phase:" "$H/skew.err" \
  || fail "H2: the abort did not name the divergent phase field: $(cat "$H/skew.err")"
echo "  H2 ok — non-wave immutable fields still abort: $(sed 's/^idc-tracker-projection: //' "$H/skew.err")"

# H3 — the wave comparison is SEMANTIC, not deleted. Through the real compiler an In Progress item's
# derived wave IS its own live wave, so a true wave divergence is unreachable end-to-end; drive
# expected_projection directly to prove the comparator still separates wave 1 from wave 2. Without
# this, "compare semantically" and "drop wave from the loop entirely" would both look green.
python3 - "$SCRIPTS" <<'PY' || fail "H3: the wave arm of the immutability check no longer discriminates"
import contextlib, io, sys
sys.path.insert(0, sys.argv[1])
import idc_tracker_projection as P

def project(g):   # the expected aborts are the assertion here; keep their stderr off the lane's log
    with contextlib.redirect_stderr(io.StringIO()):
        return P.expected_projection(g)

def graph(live_wave, derived_wave):
    live = {"number": 1, "status": "In Progress", "stage": "Buildable",
            "wave": live_wave, "phase": "Phase 1", "domain": "ui"}
    return {"phase": "Phase 1", "_live_by_id": {"pillar-a": live},
            "nodes": [{"id": "pillar-a", "derived_wave": derived_wave, "domain": "ui",
                       "blocks_on": [], "blocked_reasons": [], "surfaces": ["src/a/"]}]}

errs = []
for live_wave in ("1", "Wave 1"):
    try:
        project(graph(live_wave, 1))
    except SystemExit:
        errs.append("live %r vs derived wave 1 was reported as a mismatch (both mean wave 1)" % live_wave)
    try:
        project(graph(live_wave, 2))
        errs.append("live %r vs derived wave 2 passed — the wave check no longer discriminates" % live_wave)
    except SystemExit:
        pass
if errs:
    print("\n".join("  - " + e for e in errs)); raise SystemExit(1)
print("  H3 ok — wave compared by meaning: 1 == 'Wave 1', and 1 != 2 still aborts")
PY

# ── (I) doctor's 9c/9d probes keep `gh`'s exit status, so an UNREADABLE board is SKIP, never a
#        verdict about options nobody managed to read ────────────────────────────────────────────
# Piping `gh` straight into `grep` discards `gh`'s exit: a rate-limited field-list emits no lines,
# matches nothing, and lands on the `||` branch — 9d reported `wave-options-ok` (a PASS that
# inspected zero options) and 9c reported `stage-recirc-missing` (a ⚠ sending the operator to
# `/idc:update` for an option the board may already carry).
grep -q 'wave-options-unreadable' "$DOC" || fail "I: doctor.md 9d has no unreadable-read branch"
grep -q 'stage-recirc-unreadable' "$DOC" || fail "I: doctor.md 9c has no unreadable-read branch"
grep -qF 'if ! wave_opts=$(gh project field-list' "$DOC" \
  || fail "I: doctor.md 9d no longer captures the field-list read before classifying it"
grep -qF 'if ! stage_opts=$(gh project field-list' "$DOC" \
  || fail "I: doctor.md 9c no longer captures the field-list read before classifying it"
grep -qE "^gh project field-list .*\| grep" "$DOC" \
  && fail "I: a doctor probe still pipes gh directly into grep, discarding gh's exit status"

# Rehearse the published shape against a FAILING gh and both real board shapes, so the prose is
# proven to classify rather than merely to mention the marker (the technique arm F uses).
probe_9d() {   # mirrors doctor.md 9d; `gh` is whatever the caller defined
  if ! wave_opts=$(gh project field-list 7 --owner o --format json --jq \
        '.fields[] | select(.name=="Wave") | .options[].name' 2>/dev/null); then
    echo wave-options-unreadable
  elif printf '%s\n' "$wave_opts" | grep -qxE '[0-9]+'; then
    echo wave-options-split
  else
    echo wave-options-ok
  fi
}
gh() { return 1; }
[ "$(probe_9d)" = "wave-options-unreadable" ] \
  || fail "I: a failing field-list did not report as unreadable (got $(probe_9d))"
gh() { printf 'Wave 1\nWave 2\n'; }
[ "$(probe_9d)" = "wave-options-ok" ] || fail "I: a clean board no longer reports ok (got $(probe_9d))"
gh() { printf 'Wave 1\nWave 2\n1\n2\n'; }
[ "$(probe_9d)" = "wave-options-split" ] || fail "I: a split board no longer reports split (got $(probe_9d))"
unset -f gh
echo "  I ok — 9c/9d SKIP on an unreadable read; clean/split boards still classify"

# ── (J) legacy spelling on an IMMUTABLE row is not a divergence to write ─────────────────────────
# The projection is diffed against the live snapshot by `idc_tracker_transaction.build_operations`,
# which has NO status guard of its own — it freezes an op for any field that differs. So projecting
# the canonical label for a Done / In Progress row (whose wave Plan may not touch; `action_plan`
# skips both) manufactured a `set-field Wave` aimed at an immutable item: `/idc:plan` rewrote a row
# it treats as frozen, and on a board without the matching option that write fails mid-apply.
# The invariant: a board whose ONLY divergence is legacy spelling on immutable rows has NOTHING to
# do — it must freeze expected-GREEN — while a row Plan may legitimately write still migrates.
for spec in "In Progress:2" "Done:1"; do
  st="${spec%%:*}"; bw="${spec##*:}"
  J="$WORK/j-${st// /-}"; mkdir -p "$J"
  python3 "$TRK" --tracker "$J/TRACKER.md" init >/dev/null || fail "J($st): tracker init failed"
  mk_matrix "$J/matrix.yaml"
  # pillar-a is immutable and still stores the PRE-#206 bare wave; pillar-b is seeded at exactly the
  # wave derive_waves puts it in, in the canonical format. Nothing else differs.
  n=$(python3 "$TRK" --tracker "$J/TRACKER.md" create --title "pillar-a" --stage Buildable \
        --wave "1" --phase "Phase 1" --domain ui) || fail "J($st): create pillar-a failed"
  python3 "$TRK" --tracker "$J/TRACKER.md" move --num "$n" --status "$st" >/dev/null \
    || fail "J($st): move to $st failed"
  python3 "$TRK" --tracker "$J/TRACKER.md" create --title "pillar-b" --stage Buildable \
    --wave "Wave $bw" --phase "Phase 1" --domain api >/dev/null || fail "J($st): create pillar-b failed"

  python3 "$TXN" freeze --repo "$J" --backend filesystem --tracker "$J/TRACKER.md" \
    --matrix "$J/matrix.yaml" --baseline expected-green --label "wave-fmt-j" --out "$J/frozen.json" \
    2> "$J/freeze.err" >/dev/null \
    || fail "J($st): a board diverging only by legacy spelling on an immutable row did not freeze clean: $(cat "$J/freeze.err")"
  python3 - "$J/frozen.json" "$st" <<'PY' || fail "J: a write was frozen against an immutable item"
import json, sys
ops = json.load(open(sys.argv[1]))["operations"]
aimed = [o for o in ops if o.get("logical_id") == "pillar-a"]
if aimed:
    print("operations frozen against the immutable ('%s') pillar-a: %r" % (sys.argv[2], aimed))
    raise SystemExit(1)
PY
  echo "  J ok — a legacy bare wave on a '$st' row freezes an EMPTY transaction"
done

# J2 — the other half of the contract: a row Plan MAY write still migrates to the canonical label,
# so "stop rewriting immutable rows" cannot be satisfied by never canonicalizing anything.
J2="$WORK/j2"; mkdir -p "$J2"
python3 "$TRK" --tracker "$J2/TRACKER.md" init >/dev/null || fail "J2: tracker init failed"
mk_matrix "$J2/matrix.yaml"
python3 "$TRK" --tracker "$J2/TRACKER.md" create --title "pillar-a" --stage Buildable \
  --wave "1" --phase "Phase 1" --domain ui >/dev/null || fail "J2: create failed"   # Todo = mutable
python3 "$TXN" freeze --repo "$J2" --backend filesystem --tracker "$J2/TRACKER.md" \
  --matrix "$J2/matrix.yaml" --baseline expected-red --label wave-fmt-j2 --out "$J2/frozen.json" >/dev/null \
  || fail "J2: could not freeze"
python3 - "$J2/frozen.json" <<'PY' || fail "J2: a MUTABLE row's legacy wave was left un-migrated"
import json, sys
ops = json.load(open(sys.argv[1]))["operations"]
mig = [o for o in ops if o.get("op") == "set-field" and o.get("field") == "Wave"
       and o.get("logical_id") == "pillar-a"]
if not mig or mig[0].get("value") != "Wave 1":
    print("a Todo row holding legacy '1' froze %r, not a migration to 'Wave 1'" % (mig,))
    raise SystemExit(1)
print("  J2 ok — a writable row still migrates: %r" % (mig[0]["value"],))
PY

# J3 — the projection is also read BACK against the live board by
# `idc_planning_receipt.compare_projection_to_live`, which compares wave by RAW equality. So the
# projected value for an immutable row has to be what the board actually holds — canonicalizing it
# there while issuing no write to match would fail the planning receipt's own verification.
python3 - "$SCRIPTS" "$WORK/j-In-Progress" <<'PY' || fail "J3: the projection no longer reads back clean against a legacy board"
import os, sys
sys.path.insert(0, sys.argv[1])
import idc_execution_graph as G, idc_tracker_projection as P, idc_planning_receipt as PR
work = sys.argv[2]
graph = G.compile_graph(matrix_path=os.path.join(work, "matrix.yaml"), backend="filesystem",
                        tracker=os.path.join(work, "TRACKER.md"), repo=work)
mismatches = PR.compare_projection_to_live(P.expected_projection(graph), graph["_tracker_items"])
if mismatches:
    print("projection does not match the live board it was derived from: %r" % (mismatches,))
    raise SystemExit(1)
print("  J3 ok — the frozen projection reads back clean against the legacy board")
PY

# ── (K) an In Progress item whose wave NOBODY can read fails closed ──────────────────────────────
# An occupied wave sets `start_wave`, the floor new waves are placed above. A nonempty value in
# neither accepted shape is not "no wave" — the item occupies one and which is unknowable — but it
# parsed to None on BOTH sides, so the immutability check read that shared failure as agreement and
# waved it through, and derive_waves then dropped it from start_wave and scheduled new work into
# wave 1. Pre-#206 this aborted; that fail-closed contract is restored here.
K="$WORK/k"; mkdir -p "$K"
python3 "$TRK" --tracker "$K/TRACKER.md" init >/dev/null || fail "K: tracker init failed"
mk_matrix "$K/matrix.yaml"
n=$(python3 "$TRK" --tracker "$K/TRACKER.md" create --title "pillar-a" --stage Buildable \
      --wave "Later" --phase "Phase 1" --domain ui) || fail "K: create failed"
python3 "$TRK" --tracker "$K/TRACKER.md" move --num "$n" --status "In Progress" >/dev/null \
  || fail "K: move to In Progress failed"

python3 "$GRAPH" --matrix "$K/matrix.yaml" --backend filesystem --tracker "$K/TRACKER.md" \
  > "$K/graph.json" 2> "$K/graph.err" \
  && fail "K: the graph compiled around an In Progress item whose wave is unreadable — pillar-b was scheduled anyway: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["waves"])' "$K/graph.json" 2>/dev/null)"
grep -q "unreadable Wave on In Progress" "$K/graph.err" \
  || fail "K: compile failed for the wrong reason: $(cat "$K/graph.err")"
grep -q "'Later'" "$K/graph.err" \
  || fail "K: the refusal does not name the value it could not read: $(cat "$K/graph.err")"
grep -q "pillar-a" "$K/graph.err" \
  || fail "K: the refusal does not name the item holding it: $(cat "$K/graph.err")"
# Plan reaches the same wall (it compiles this graph first), so no plan is built on the guess.
python3 "$PROJ" --matrix "$K/matrix.yaml" --backend filesystem --tracker "$K/TRACKER.md" \
  >/dev/null 2> "$K/proj.err" \
  && fail "K: the projection accepted an In Progress item whose wave is unreadable"
grep -q "unreadable Wave on In Progress" "$K/proj.err" \
  || fail "K: the projection failed for the wrong reason: $(cat "$K/proj.err")"
echo "  K ok — unreadable occupied wave refused: $(head -1 "$K/proj.err" | sed 's/^idc-execution-graph: //')"

# K2 — an ABSENT wave is a different fact and stays ACCEPTED. That is the pre-#206 contract (such an
# item still holds conflicting work back through surface overlap), so the new guard must not
# over-reach into "every In Progress item must carry a wave".
K2="$WORK/k2"; mkdir -p "$K2"
python3 "$TRK" --tracker "$K2/TRACKER.md" init >/dev/null || fail "K2: tracker init failed"
mk_matrix "$K2/matrix.yaml"
n=$(python3 "$TRK" --tracker "$K2/TRACKER.md" create --title "pillar-a" --stage Buildable \
      --phase "Phase 1" --domain ui) || fail "K2: create failed"
python3 "$TRK" --tracker "$K2/TRACKER.md" move --num "$n" --status "In Progress" >/dev/null \
  || fail "K2: move to In Progress failed"
python3 "$PROJ" --matrix "$K2/matrix.yaml" --backend filesystem --tracker "$K2/TRACKER.md" \
  >/dev/null 2> "$K2/proj.err" \
  || fail "K2: an In Progress item with NO wave was rejected — the guard over-reached: $(cat "$K2/proj.err")"
echo "  K2 ok — an In Progress item with no wave at all is still accepted"

# K3 — the comparator itself, driven directly (arm K's end-to-end path now dies upstream in
# derive_waves, so without this the projection's own guard is never exercised). `None == None` from
# two failed parses must NOT read as agreement.
python3 - "$SCRIPTS" <<'PY' || fail "K3: the projection's wave comparator treats an unreadable wave as agreement"
import contextlib, io, sys
sys.path.insert(0, sys.argv[1])
import idc_tracker_projection as P

def project(g):
    with contextlib.redirect_stderr(io.StringIO()):
        return P.expected_projection(g)

def graph(live_wave, derived_wave):
    live = {"number": 1, "status": "In Progress", "stage": "Buildable",
            "wave": live_wave, "phase": "Phase 1", "domain": "ui"}
    return {"phase": "Phase 1", "_live_by_id": {"pillar-a": live},
            "nodes": [{"id": "pillar-a", "derived_wave": derived_wave, "domain": "ui",
                       "blocks_on": [], "blocked_reasons": [], "surfaces": ["src/a/"]}]}

errs = []
# An unreadable live wave derives to nothing; both sides parse to None and must NOT compare equal.
try:
    project(graph("Later", None))
    errs.append("live 'Later' vs an absent derived wave was ACCEPTED (two failed parses read as agreement)")
except SystemExit:
    pass
# A genuinely absent wave on both sides is real agreement and stays accepted.
try:
    project(graph("", None))
except SystemExit:
    errs.append("an In Progress item with no wave was rejected — the guard over-reached")
if errs:
    print("\n".join("  - " + e for e in errs)); raise SystemExit(1)
print("  K3 ok — an unreadable wave equals nothing; a genuinely empty one still matches")
PY

echo "PASS: phase3-wave-label-format"
