#!/bin/bash
# board-lint-stranded-gate.sh — governance scenario: the STRANDED-GATE board-lint rule + the
# orchestrator Blocked-scan recovery prose (round-11 close-out; Opus Major on the dispose-first
# reorder).
#
# THE STRAND: idc:idc-gate-issue step 4 closes the gate through the guarded dispose FIRST and
# unblocks dependents only after it succeeds (that order closed the worse revoked-approval
# fail-open). A run killed BETWEEN the two leaves a dependent Status=Blocked behind a gate that is
# already Done — invisible to the drain (Todo-only), to every open-gate re-check (the gate is
# closed), and to board-lint's other rules (retired-recirc only resolves Done RECIRCULATION
# blockers). This scenario locks the two recovery surfaces:
#   (1) DETERMINISTIC: board-lint's `stranded-gate` rule — a Status=Blocked item ALL of whose
#       blockers are Done, at least one being a Done [operator-action] gate (title from the index),
#       flags with the engine-unblock remediation; a live/unknown blocker or a Done NON-gate
#       blocker stays silent (SOLE/SATISFIED — never over-report a genuinely held issue).
#   (2) PROSE: the autorun/plan/recirculator playbooks carry the explicit Blocked-scan step
#       ("whose blocking gate issue is already Done" → engine's journaled unblock).
#
# Red-when-broken: neuter stranded_gate_evidence (return "") → cases 1/7 FAIL. Drop the Blocked-scan
# step from an orchestrator playbook → case 9 FAILs. Revert doctor.md's filesystem branch to the old
# blanket SKIP → case 8 FAILs (the rule becomes unreachable on fs — codex round-12 P2). Drop the
# null-lookup Blocked-item indeterminate count → case 4 FAILs (a failed dependency read reads as a
# clean board — codex round-15 P2).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

LINT="$GOV_PLUGIN/scripts/idc_board_lint.py"
[ -f "$LINT" ] || gov_fail "board-lint helper not found at $LINT"

run_lint() { OUT="$(printf '%s' "$1" | python3 "$LINT")"; RC=$?; }
run_lint_j() { OUT="$(printf '%s' "$1" | python3 "$LINT" --journal "$2")"; RC=$?; }  # tiered (round-13 P1)
fail() { gov_fail "$1"; }

# write_journal <path> <line...> — a hermetic transition journal (one record per arg) for the
# --journal tiering. `docs/workflow/` must exist relative to <path>'s dir for scan_journal_strict.
write_journal() { local p="$1"; shift; mkdir -p "$(dirname "$p")"; : > "$p"; for l in "$@"; do printf '%s\n' "$l" >> "$p"; done; }
DISPOSE_REC() { printf '{"op":"dispose","disposition":"gate-approved","item":%s,"what":"dispose #%s Todo -> Done [gate-approved]"}' "$1" "$1"; }

# One unified EXIT cleanup (mktemp -d paths carry no spaces, so unquoted $_CLEAN is safe and works on
# bash 3.2 — an empty "${arr[@]}" under set -u errors there; a single trap avoids the overwrite race).
_CLEAN=""
trap 'rm -rf $_CLEAN 2>/dev/null' EXIT
newdir() { local d; d="$(mktemp -d)"; _CLEAN="$_CLEAN $d"; printf '%s' "$d"; }

GATE_DONE='{"number": 9, "title": "[operator-action] Requirements change — add export", "stage": "Buildable", "status": "Done"}'
GATE_OPEN='{"number": 9, "title": "[operator-action] Requirements change — add export", "stage": "Buildable", "status": "Todo"}'
NONGATE_DONE='{"number": 9, "title": "implement the exporter", "stage": "Buildable", "status": "Done"}'

# ── 1. a Blocked dependent behind a DONE gate (NO --journal) → stranded-gate with the VERIFY-FIRST ──
#      remediation: a Done gate alone does not prove the guarded dispose ran (round-13 P1), so with no
#      journal supplied the rule cannot tier and MUST require verifying the journaled dispose first.
run_lint "[$GATE_DONE, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9]}]"
[ $RC -eq 0 ] || fail "lint exited $RC on the stranded-gate board"
echo "$OUT" | grep -q 'stranded-gate — Status=Blocked behind gate #9 that is already Done' \
  || fail "a Blocked dependent behind a Done gate was NOT flagged stranded-gate: $OUT"
echo "$OUT" | grep -q 'journaled `unblock`' \
  || fail "the stranded-gate finding does not name the engine's journaled unblock remediation: $OUT"
echo "$OUT" | grep -qi 'VERIFY the gate.s journaled guarded dispose' \
  || fail "the no-journal stranded-gate finding does not require VERIFYing the journaled guarded dispose first (round-13 P1): $OUT"
echo "$OUT" | grep -q 'op=dispose/disposition=gate-approved' \
  || fail "the verify-first remediation does not name the journaled guarded-dispose record shape: $OUT"
echo "$OUT" | grep -q 'board-lint: 1 flagged of 0 scanned (0 schema, 0 prose-dep, 1 stranded-gate)' \
  || fail "the summary does not tally the stranded-gate clause: $OUT"
echo "  ok (1) a Done-gate strand with NO journal flags stranded-gate REQUIRING journal verification first (round-13 P1)"

# ── 2. a Blocked dependent behind an OPEN gate → silent (genuinely pending, correct state) ─────────
run_lint "[$GATE_OPEN, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9]}]"
echo "$OUT" | grep -q 'stranded-gate' && fail "a dependent behind an OPEN gate was flagged (it is genuinely pending): $OUT"
echo "  ok (2) a dependent behind an OPEN gate stays silent (pending admission is the correct state)"

# ── 3. a Blocked item behind a DONE non-gate → silent (not this rule's business) ───────────────────
run_lint "[$NONGATE_DONE, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9]}]"
echo "$OUT" | grep -q 'stranded-gate' && fail "a Blocked item behind a Done NON-gate was flagged stranded-gate: $OUT"
echo "  ok (3) a Done non-gate blocker never reads as a gate (title-gated)"

# ── 4. blocked_by UNKNOWN (null) → NOT flagged, but the check is INDETERMINATE (round-15 P2) ────────
# A Blocked item whose dependency lookup FAILED (blocked_by: null) is not a stranded-gate finding
# (never flag what the lookup could not prove), BUT the stranded-gate check could not run — so it
# must surface as an indeterminate dependency lookup, never masquerade as a clean board. The Blocked
# item is index-only (0 scanned), so without the round-15 count it would exit before unknown_count.
run_lint "[$GATE_DONE, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": null}]"
echo "$OUT" | grep -q 'stranded-gate' && fail "an UNKNOWN blocked_by was flagged stranded-gate: $OUT"
echo "$OUT" | grep -q 'board-lint: clean (0 scanned; 1 dependency lookup indeterminate)' \
  || fail "a null-lookup Blocked item did not surface as INDETERMINATE (round-15 P2 — it must not read as a clean board): $OUT"
echo "  ok (4) a null-lookup Blocked item is NOT a finding but surfaces as indeterminate (round-15 P2), never a bare clean"

# ── 5. a mixed set with one LIVE blocker → silent (the issue is genuinely held) ────────────────────
run_lint "[$GATE_DONE, {\"number\": 10, \"title\": \"live upstream\", \"stage\": \"Buildable\", \"status\": \"In Progress\"}, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9, 10]}]"
echo "$OUT" | grep -q 'stranded-gate' && fail "an issue with a LIVE blocker was flagged stranded-gate (over-report): $OUT"
echo "  ok (5) a live blocker in the set keeps the rule silent (SOLE/SATISFIED — never over-report)"

# ── 6. the summary clause is byte-absent when zero (existing-summary compatibility) ────────────────
run_lint '[{"number": 3, "title": "t", "body": "Goal-contract: G\nAcceptance: A\nDependencies: blocked-by #0 (none)\nVerification: V\nContract-version: 1", "blocked_by": []}]'
echo "$OUT" | grep -q 'stranded-gate' && fail "a clean board mentions stranded-gate: $OUT"
echo "  ok (6) zero stranded items leave the summary byte-for-byte unchanged"

# ── 6a. --journal, PROVEN: the gate's guarded dispose IS journaled → stranded-gate (safe to finish) ─
# The canonical interrupted dispose-then-unblock: the gate's op=dispose/gate-approved record exists,
# so finishing the unblock is safe. Mutation proof: make stranded_gate_evidence ignore proven_gates
# (always return the "unproven-gate-done" tier, or drop the proven_gates branch) → this flags
# unproven-gate-done and case 6a FAILs.
J6="$(newdir)/docs/workflow/transition-journal.ndjson"; write_journal "$J6" "$(DISPOSE_REC 9)"
run_lint_j "[$GATE_DONE, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9]}]" "$J6"
[ $RC -eq 0 ] || fail "lint exited $RC on the proven-gate board"
echo "$OUT" | grep -q 'stranded-gate — Status=Blocked behind gate #9 that is already Done — the gate.s guarded dispose IS journaled (proven)' \
  || fail "a strand behind a PROVEN Done gate was not flagged stranded-gate(proven): $OUT"
echo "$OUT" | grep -q 'unproven-gate-done' && fail "a PROVEN gate was mis-tiered as unproven-gate-done: $OUT"
echo "$OUT" | grep -q 'board-lint: 1 flagged of 0 scanned (0 schema, 0 prose-dep, 1 stranded-gate)' \
  || fail "the proven-gate summary is wrong: $OUT"
echo "  ok (6a) --journal + a journaled gate-approved dispose → stranded-gate (proven; safe to finish the unblock)"

# ── 6b. --journal, UNPROVEN: the gate is Done but has NO journaled dispose → unproven-gate-done ──────
# A raw/manual close (or janitor repair) minted the Done — the guard never validated the approval.
# The journal exists (a create record) but carries no op=dispose/gate-approved for the gate. The
# dependent must NOT be auto-unblocked. Mutation proof: drop the proven_gates tier (always emit
# stranded-gate) → this flags stranded-gate and case 6b FAILs.
J6b="$(newdir)/docs/workflow/transition-journal.ndjson"
write_journal "$J6b" '{"op":"create-pointer","item":9,"what":"create #9"}'
run_lint_j "[$GATE_DONE, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9]}]" "$J6b"
[ $RC -eq 0 ] || fail "lint exited $RC on the unproven-gate board"
echo "$OUT" | grep -q 'unproven-gate-done — Status=Blocked behind gate #9 that is Done but has NO journaled guarded dispose' \
  || fail "a strand behind an UNPROVEN Done gate was not flagged unproven-gate-done: $OUT"
echo "$OUT" | grep -qi 'do NOT auto-unblock' || fail "the unproven-gate-done finding does not warn against auto-unblocking: $OUT"
echo "$OUT" | grep -q '1 stranded-gate' && fail "an UNPROVEN gate was mis-tiered as stranded-gate: $OUT"
echo "$OUT" | grep -q 'board-lint: 1 flagged of 0 scanned (0 schema, 0 prose-dep, 1 unproven-gate-done)' \
  || fail "the unproven-gate summary is wrong: $OUT"
echo "  ok (6b) --journal + no journaled dispose → unproven-gate-done (a raw-closed Done is UNPROVEN; do not auto-unblock)"

# ── 6c. --journal, FAIL-CLOSED: a CORRUPT journal → every Done gate reads UNPROVEN (never all-proven) ─
# Damaging the journal must deny (unproven), never launder a strand into a safe stranded-gate.
J6c="$(newdir)/docs/workflow/transition-journal.ndjson"
write_journal "$J6c" 'NOT-JSON {'
run_lint_j "[$GATE_DONE, {\"number\": 12, \"title\": \"blocked dependent\", \"stage\": \"Buildable\", \"status\": \"Blocked\", \"blocked_by\": [9]}]" "$J6c"
[ $RC -eq 0 ] || fail "lint exited $RC on the corrupt-journal board"
echo "$OUT" | grep -q 'unproven-gate-done' \
  || fail "a corrupt journal did not FAIL CLOSED to unproven-gate-done (it must never read as proven): $OUT"
echo "  ok (6c) a corrupt journal fails closed → unproven-gate-done (a damaged journal never proves a gate)"

# ── 7. FILESYSTEM: the doctor's fs index feed drives the same rule end-to-end, --journal-tiered ─────
# The strand class exists on filesystem too (fs gate disposed, run dies before the unblock), and
# Row 9's old fs branch skipped board-lint entirely (codex round-12 P2). The fs feed emits the
# tracker's structured records as INDEX-ONLY objects — Buildable+Todo EXCLUDED so nothing is
# body-schema-scanned (fs has no bodies) — and passes --journal so the Done gate is tiered
# proven-vs-unproven (round-13 P1). This replicates doctor.md's emission against a REAL seeded
# TRACKER.md. Case 7 = PROVEN (the gate's guarded dispose IS journaled); case 7b = UNPROVEN.
T2="$(gov_new_tracker)" || gov_fail "could not mint the fs tracker"
REPO2="$(dirname "$T2")"; _CLEAN="$_CLEAN $REPO2"
J7="$REPO2/docs/workflow/transition-journal.ndjson"
gate="$(gov_seed_item "$T2" --title '[operator-action] Requirements change — fs gate' --stage Buildable --status Done)" \
  || gov_fail "could not seed the fs gate"
dep="$(gov_seed_item "$T2" --title 'fs dependent' --stage Buildable --status Blocked --blocked-by "$gate")" \
  || gov_fail "could not seed the fs dependent"
gov_seed_item "$T2" --title 'ordinary todo work' --stage Buildable --status Todo >/dev/null \
  || gov_fail "could not seed the fs todo item"
# The fs index feed exactly as doctor.md emits it — captured so its exit is checkable (see case 8b).
fs_feed() { python3 - "$GOV_PLUGIN/scripts" "$T2" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_tracker_fs
for it in idc_tracker_fs.load(sys.argv[2]).get("issues", []):
    if not isinstance(it, dict) or it.get("number") is None:
        continue
    stage, status = it.get("stage") or "Buildable", it.get("status") or "none"
    if stage == "Buildable" and status == "Todo":
        continue  # the body re-scan lane is github-only; never fed, so never schema-scanned
    obj = {"number": it["number"], "title": it.get("title") or "", "stage": stage, "status": status}
    if status == "Blocked":
        bb = it.get("blocked_by")
        obj["blocked_by"] = bb if isinstance(bb, list) else []
    print(json.dumps(obj))
PY
}
# PROVEN: journal the gate's guarded dispose → the canonical interrupted dispose-then-unblock.
write_journal "$J7" "$(DISPOSE_REC "$gate")"
OUT=$(fs_feed | python3 "$LINT" --journal "$J7")
echo "$OUT" | grep -q "stranded-gate — Status=Blocked behind gate #$gate that is already Done — the gate.s guarded dispose IS journaled (proven)" \
  || fail "the fs index feed did not surface the PROVEN stranded dependent: $OUT"
# The exact summary proves BOTH properties: index-only (0 scanned — the seeded Buildable+Todo item
# was excluded, so its body-less record was never schema-scanned) and exactly one stranded flag.
echo "$OUT" | grep -q 'board-lint: 1 flagged of 0 scanned (0 schema, 0 prose-dep, 1 stranded-gate)' \
  || fail "the fs feed (proven) summary is wrong (must be index-only: 0 scanned, 1 stranded-gate): $OUT"
echo "  ok (7) the fs index feed + --journal surfaces a PROVEN stranded dependent as stranded-gate (0 scanned)"

# ── 7b. FILESYSTEM UNPROVEN: same feed, but the gate's Done is NOT journaled → unproven-gate-done ───
write_journal "$J7" '{"op":"create-pointer","item":1,"what":"unrelated"}'   # no dispose for the gate
OUT=$(fs_feed | python3 "$LINT" --journal "$J7")
echo "$OUT" | grep -q "unproven-gate-done — Status=Blocked behind gate #$gate that is Done but has NO journaled guarded dispose" \
  || fail "the fs index feed did not tier an UNPROVEN Done gate as unproven-gate-done: $OUT"
echo "$OUT" | grep -q 'board-lint: 1 flagged of 0 scanned (0 schema, 0 prose-dep, 1 unproven-gate-done)' \
  || fail "the fs feed (unproven) summary is wrong: $OUT"
echo "  ok (7b) the fs index feed + --journal tiers an UNPROVEN Done gate as unproven-gate-done"

# ── 8. doctor.md's filesystem branch runs the index rules, --journal-tiered, SKIP-on-producer-fail ─
# Three prose invariants over the shipped recipe: (a) it runs the index rules on fs; (b) it passes
# --journal so the strand is tiered (round-13 P1); (c) it CAPTURES the producer and SKIPs on a
# read failure rather than piping straight into the lint (round-13 P2 — finding 3).
D="$GOV_PLUGIN/commands/doctor.md"
python3 - "$D" <<'PY' || fail "doctor.md's filesystem Row 9 branch lost an index-rule / --journal / SKIP invariant (see above)"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
norm = re.sub(r"\s+", " ", text)
if "filesystem` → run the backend-neutral INDEX rules only" not in norm:
    raise SystemExit("FAIL: doctor.md Row 9 filesystem branch no longer runs the backend-neutral index rules")
if "idc_tracker_fs" not in text:
    raise SystemExit("FAIL: doctor.md's fs feed no longer reads the tracker via idc_tracker_fs")
# The fs branch must SKIP (not silently print clean 0-scanned) when the producer fails — a naked
# pipe would classify PASS on an uninspectable board (finding 3). Bind to the exact SKIP marker.
if "board-lint: SKIP — filesystem tracker unreadable" not in text:
    raise SystemExit("FAIL: doctor.md's fs branch does not emit an explicit SKIP marker on a tracker-read failure (finding 3 regressed — a naked pipe would PASS on an uninspectable board)")
# The tiering must be reachable via the recipe: both branches pass --journal to the lint helper.
if norm.count("idc_board_lint.py") and "--journal" not in norm:
    raise SystemExit("FAIL: doctor.md Row 9 no longer passes --journal to idc_board_lint.py (the stranded-gate journal tiering is unreachable)")
print("  ok (8) doctor.md Row 9 fs branch: index rules + --journal tiering + explicit SKIP-on-read-failure")
PY

# ── 8b. FINDING 3 (functional): the fs recipe's capture+exit-check emits SKIP against a MISSING ─────
# tracker — never the hollow `clean (0 scanned)` a naked producer|consumer pipe would print (which
# reads as PASS on an uninspectable board). Replicates doctor.md's exact capture/exit-check/SKIP
# shape (dedented — the markdown bullet indent is structure, not code; see case 7 for the pattern).
MISS="$(newdir)"   # a repo dir with NO TRACKER.md → idc_tracker_fs.load die()s (exit ≠ 0)
fs_lint_in="$(mktemp)"; _CLEAN="$_CLEAN $fs_lint_in"
if python3 - "$GOV_PLUGIN/scripts" "$MISS/TRACKER.md" > "$fs_lint_in" 2>/dev/null <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_tracker_fs
for it in idc_tracker_fs.load(sys.argv[2]).get("issues", []):
    print(json.dumps(it))
PY
then
  SKIP_OUT="$(python3 "$LINT" --journal "$MISS/docs/workflow/transition-journal.ndjson" < "$fs_lint_in")"
else
  SKIP_OUT="board-lint: SKIP — filesystem tracker unreadable (idc_tracker_fs.load exit ≠ 0); could not determine"
fi
printf '%s' "$SKIP_OUT" | grep -q '^board-lint: SKIP — filesystem tracker unreadable' \
  || fail "the fs recipe did not SKIP on a MISSING tracker (finding 3): got: $SKIP_OUT"
printf '%s' "$SKIP_OUT" | grep -q 'clean (0 scanned)' \
  && fail "the fs recipe printed the hollow 'clean (0 scanned)' on a MISSING tracker (finding 3 regressed — reads as PASS): $SKIP_OUT"
echo "  ok (8b) the fs recipe SKIPs (not clean-0-scanned) when the tracker is missing/corrupt (finding 3)"

# ── 9. every recovery surface VERIFIES the gate's journaled proof before unblocking (round-13 P1), ──
# and does it through the ONE CENTRALIZED reader (Task 7). A Done gate alone does not prove the
# guarded dispose ran, so each playbook must (a) carry the Blocked-scan step, (b) route the unblock
# through the engine's journaled `unblock`, (c) require VERIFYing the gate's journaled guarded dispose
# FIRST — via `idc_gate_proof.py`, never a hand-rolled scan — and (d) name the UNPROVEN posture (leave
# Blocked, do not auto-unblock). Red-when-broken: drop the verify-first clause, or re-inline a private
# journal scan, in any surface → FAIL.
python3 - "$GOV_PLUGIN" <<'PY' || fail "a recovery surface lost the verify-the-journaled-proof-first step, or re-inlined a private journal scan (see above)"
import re, sys
root = sys.argv[1]
PHRASE = "whose blocking gate issue is already `Done`"
SURFACES = ("agents/idc-autorun.md", "agents/idc-plan.md", "agents/idc-recirculator.md")
for rel in SURFACES:
    text = re.sub(r"\s+", " ", open(f"{root}/{rel}", encoding="utf-8").read())
    if PHRASE not in text:
        raise SystemExit(f"FAIL: {rel} lost the Blocked-scan recovery step ({PHRASE!r})")
    if "journaled `unblock`" not in text:
        raise SystemExit(f"FAIL: {rel} does not route the recovery through the engine's journaled unblock")
    if "journaled guarded dispose" not in text:
        raise SystemExit(f"FAIL: {rel} does not require VERIFYing the gate's journaled guarded dispose first (round-13 P1)")
    if "UNPROVEN" not in text:
        raise SystemExit(f"FAIL: {rel} does not name the UNPROVEN posture (a Done gate whose dispose is not journaled must not auto-unblock)")
    if "idc_gate_proof.py" not in text:
        raise SystemExit(f"FAIL: {rel} does not verify through the CENTRALIZED reader (idc_gate_proof.py) — "
                         "a per-surface scan is how these four drift apart (Task 7)")
    print(f"  ok {rel} verifies the gate's proof through the centralized idc_gate_proof.py reader")

# The gate skill is the authoritative recovery source: it must name the DETERMINISTIC verification
# command and BOTH proven kinds — recovery may finish a still-blocked pointer on either, never on
# `unproven` (and an unreadable journal is indeterminate, not a clean negative).
gate = open(f"{root}/skills/idc-gate-issue/SKILL.md", encoding="utf-8").read()
# `disposition=gate-approved` is the RECORD SHAPE the guarded door writes: the skill must still name
# it (that is what `guarded-dispose` means), independent of how any code spells it.
for token in ("idc_gate_proof.py", "guarded-dispose", "verified-reconciliation", "unproven",
              "disposition=gate-approved", "PROVEN", "UNPROVEN"):
    if token not in gate:
        raise SystemExit(f"FAIL: idc-gate-issue/SKILL.md lacks the deterministic verification token {token!r}")
print("  ok idc-gate-issue/SKILL.md names the centralized reader + both proven kinds (guarded-dispose | "
      "verified-reconciliation) and the UNPROVEN posture")

# ANTI-DRIFT (Task 7): the centralized reader is the ONLY place the raw journal-scan primitives are
# named. A surface that re-inlines `scan_journal_strict`/`idc_journal_replay` has forked the proof
# logic again — exactly the duplication Task 7 removed — so the four surfaces could silently disagree
# about whether a gate is proven. The reader itself is the sanctioned home.
for rel in SURFACES + ("skills/idc-gate-issue/SKILL.md",):
    text = open(f"{root}/{rel}", encoding="utf-8").read()
    for banned in ("scan_journal_strict", "idc_journal_replay"):
        if banned in text:
            raise SystemExit(f"FAIL: {rel} re-inlines the raw journal-scan primitive {banned!r} — the proof "
                             "logic is centralized in scripts/idc_gate_proof.py; call it instead (Task 7)")
proof = open(f"{root}/scripts/idc_gate_proof.py", encoding="utf-8").read()
if "scan_journal_strict" not in proof:
    raise SystemExit("FAIL: scripts/idc_gate_proof.py no longer reads the journal through the fail-closed "
                     "scan_journal_strict — the centralized reader must keep the archive-aware, lock-safe scan")
print("  ok no recovery surface re-inlines a private journal scan — scripts/idc_gate_proof.py is the single reader")

# The recovery's FINISH step routes through the guarded pointer-finish door, never a raw engine
# unblock (Task 7 wave 2). The engine's `unblock --by` drops only the NAMED edge before setting Todo,
# so the playbook-instructed raw unblock frees a pointer Blocked by [gate, other] past `other`
# WITHOUT its proof — reviewer probe through the real dispatcher: `status='Todo', blocked_by=[999],
# journal op='unblock'`. The door re-reads the gate's on-disk proof AND refuses unless the proven gate
# is the SOLE remaining blocker, so the guard lives in ONE mechanical place instead of being
# hand-rolled (or forgotten) per playbook. Red-when-broken: restore a bare-unblock instruction, or
# drop the door, in any surface → FAIL.
BARE_UNBLOCK = re.compile(r"finish (?:the|its) unblock through the engine's journaled")
for rel in SURFACES + ("skills/idc-gate-issue/SKILL.md",):
    text = re.sub(r"\s+", " ", open(f"{root}/{rel}", encoding="utf-8").read())
    if "--finish-pointer" not in text:
        raise SystemExit(f"FAIL: {rel} does not route the interrupted-run recovery through the guarded "
                         "pointer-finish door (idc_gate_repair.py --finish-pointer) — the door is what "
                         "enforces the gate's on-disk proof AND the sole-remaining-blocker rule (Task 7 "
                         "wave 2)")
    if BARE_UNBLOCK.search(text):
        raise SystemExit(f"FAIL: {rel} still instructs the interrupted-run recovery to finish through a "
                         "BARE engine `unblock` — `unblock --by` drops only the NAMED edge and then sets "
                         "Todo, admitting a multiply-blocked pointer past its other gates without their "
                         "proof; route the finish through `idc_gate_repair.py --finish-pointer`")
    print(f"  ok {rel} routes the recovery's finish through the guarded pointer-finish door")

# doctor Row 9's unproven-gate-done remediation must point at the HONEST repair door and forbid the
# tempting forgery (a hand-written dispose record that silences the finding without any verification).
doctor = re.sub(r"\s+", " ", open(f"{root}/commands/doctor.md", encoding="utf-8").read())
for token in ("idc_gate_proof.py", "idc_gate_repair.py", "dry run by default"):
    if token not in doctor:
        raise SystemExit(f"FAIL: doctor.md Row 9's unproven-gate-done remediation lacks {token!r} — an "
                         "unproven gate must route to the dry-run-first reconciliation door")
if "Never hand-write a journal record to silence this finding" not in doctor:
    raise SystemExit("FAIL: doctor.md Row 9 no longer forbids hand-writing a journal record to silence an "
                     "unproven-gate-done finding (the forgery this repair path exists to replace)")
print("  ok doctor.md Row 9 routes an unproven gate to the dry-run-first repair door and forbids the forgery")
PY

echo "PASS: a dependent stranded Status=Blocked behind an already-Done gate is deterministically surfaced AND tiered (board-lint stranded-gate when the guarded dispose is journaled, unproven-gate-done when not; doctor Row 9 passes --journal; the fs recipe SKIPs on a tracker-read failure) — never flagged behind an open gate, a non-gate blocker, a live blocker, or an unknown lookup — and the gate skill + autorun/plan/recirculator playbooks each VERIFY the journaled guarded dispose before unblocking (round-13 P1)"
