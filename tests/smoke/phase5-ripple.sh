#!/bin/bash
# idc-assert-class: mixed
# Phase 5 smoke — the Recirculator's deterministic doctrine:
#   (a) downstream sync set: changing layer N requires syncing N + every layer below it in
#       ONE PR (PRD->spec->master->subphase->pillar); and the gate fires ONLY on a requirements
#       layer (the PRD always; the TRD/`spec` layer when gating.trd is on) — never on a
#       downstream/decomposition layer (master/subphase/pillar);
#   (a2) the TRD-gating toggle (U2): spec drift gates iff gating.trd is on;
#   (b) the requirements path reuses the ONE gate fired at the end of Think (the Think PR /
#       `idc:idc-gate-issue`); a non-requirements path creates NO gate. The Recirculator routes a
#       requirements-change backflow to that same gate (it does not own a second gate).
# Failing-test-first: fails until scripts/idc_recirculator_layers.py exists.
#
# Usage: bash tests/smoke/phase5-ripple.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
RL="$PLUGIN/scripts/idc_recirculator_layers.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
RECIRC="$PLUGIN/agents/idc-recirculator.md"
WORKFLOW="$PLUGIN/templates/WORKFLOW.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$RL" ] || fail "recirculator-layers helper not found at $RL (not implemented yet)"

# ---- (a) downstream sync set + gate decision -------------------------------------
# spec drift -> sync spec..pillar, no gate
out="$(python3 "$RL" spec)"
echo "$out" | grep -q "^sync: spec master subphase pillar$" || fail "spec drift sync set wrong: $out"
echo "$out" | grep -q "^gate: no$" || fail "spec drift must not gate"
# pillar drift -> sync pillar only, no gate
python3 "$RL" pillar | grep -q "^sync: pillar$" || fail "pillar drift sync set should be pillar only"
# prd drift -> sync everything, gate yes
out="$(python3 "$RL" prd)"
echo "$out" | grep -q "^sync: prd spec master subphase pillar$" || fail "prd drift sync set wrong: $out"
echo "$out" | grep -q "^gate: yes$" || fail "PRD drift MUST gate"
# unknown layer -> error
python3 "$RL" bogus >/dev/null 2>&1 && fail "unknown layer should error"

# the gate fires on REQUIREMENTS ADMISSION only — a downstream/decomposition layer
# (master/subphase/pillar) MUST NOT gate even with every toggle on. This is the guard that fails
# red if the gate is ever made to fire on a non-requirements change.
CFG_ON="$WORK/cfg-trd-on.yaml";  printf 'gating:\n  prd: on\n  trd: on\n'  > "$CFG_ON"
CFG_OFF="$WORK/cfg-trd-off.yaml"; printf 'gating:\n  prd: on\n  trd: off\n' > "$CFG_OFF"
for ds in master subphase pillar; do
  python3 "$RL" "$ds" --config "$CFG_ON" | grep -q "^gate: no$" \
    || fail "the gate must fire on requirements admission only — a '$ds' (downstream) change must NEVER gate, even with trd:on"
done

# ---- (a2) TRD-gating toggle: spec drift gates iff gating.trd is on (U2) ------------
# The `spec` layer IS the TRD. With gating.trd:on it now reaches the gate; with :off it stays
# autonomous (greenfield default). The PRD always gates regardless of the TRD toggle.
python3 "$RL" spec --config "$CFG_ON" | grep -q "^gate: yes$" \
  || fail "TRD toggle: spec drift MUST gate when gating.trd is on"
python3 "$RL" spec --config "$CFG_OFF" | grep -q "^gate: no$" \
  || fail "TRD toggle: spec drift must stay ungated when gating.trd is off"
python3 "$RL" prd --config "$CFG_OFF" | grep -q "^gate: yes$" \
  || fail "TRD toggle: PRD MUST always gate regardless of the TRD toggle"
# default (no --config) preserves greenfield: spec ungated, prd gated (asserted in (a) above).

# ---- (a3) malformed gating value FAILS CLOSED to gated (U4 / gotcha #7) -------------
# The gating block is the gate's ARMING SWITCH. A present-but-unrecognized value (typo /
# flow-style / mis-indent) must NOT silently fall back to off — that is exactly the brownfield
# "silent architecture rewrites" trap. It fails closed to gated instead. Break it (let a
# malformed value default to off) and a `spec` drift would print `gate: no` and this fails red.
CFG_BAD="$WORK/cfg-trd-bad.yaml"; printf 'gating:\n  prd: on\n  trd: maybe\n' > "$CFG_BAD"
python3 "$RL" spec --config "$CFG_BAD" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "malformed gating.trd value must FAIL CLOSED to gated (gate: yes), not silently default to off"

# ---- (a4) SHIPPED config shape: inline `# comments` on gating lines must be stripped (U4 / B1) ----
# The shipped templates/WORKFLOW-config.yaml ships its gating lines COMMENTED
# (`trd: off   # ...`). read_gating must strip the inline comment BEFORE classifying — otherwise the
# whole `off   # ...` string is "unrecognized" and the (a3) fail-closed branch would gate EVERY
# default greenfield repo ON, defeating the greenfield invariant. This case runs against the real
# shipped file (not a bare fixture), so it guards the shape every `/idc:init` actually produces.
# Break it (drop the inline-comment strip) and the commented `trd: off` reads as unrecognized → the
# warning fires and spec drift gates `yes` → both assertions below fail red.
WFCFG="$PLUGIN/templates/WORKFLOW-config.yaml"
[ -f "$WFCFG" ] || fail "shipped templates/WORKFLOW-config.yaml missing"
err="$(python3 "$RL" spec --config "$WFCFG" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'unrecognized value' \
  && fail "shipped (commented) gating lines tripped the fail-closed warning — inline # not stripped (B1)"
python3 "$RL" spec --config "$WFCFG" 2>/dev/null | grep -q "^gate: no$" \
  || fail "shipped (commented) greenfield template: spec drift must NOT gate (trd: off # ...)"
python3 "$RL" prd  --config "$WFCFG" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "shipped (commented) template: PRD (prd: on # ...) must gate"
# brownfield: the shipped template with trd flipped on (still commented) → spec now gates
BROWN_WF="$WORK/brownfield-config.yaml"; sed "s|^  trd: off|  trd: on |" "$WFCFG" > "$BROWN_WF"
python3 "$RL" spec --config "$BROWN_WF" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "shipped (commented) brownfield template (trd: on # ...): spec drift MUST gate"

# ---- (a5) arming switch must not depend on EXACTLY two-space indent (FIX 1 / gotcha #7 via indent) ----
# The template invites operators to "toggle either gate anytime" by hand. The old parser only saw
# gating children at indent==2, so a hand-edited 4-space `trd: on` fell through to the greenfield
# default (off) and SILENTLY DISARMED the TRD gate — a fail-OPEN on the gate's arming switch.
# read_gating must read prd/trd at ANY deeper indent. Break it (recognize only indent==2) and the
# 4-space spec drift below prints `gate: no` → fails red.
CFG_4SP="$WORK/cfg-trd-on-4space.yaml"; printf 'gating:\n    prd: on\n    trd: on\n' > "$CFG_4SP"
python3 "$RL" spec --config "$CFG_4SP" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "4-space-indented gating.trd: on must ARM the TRD gate (spec drift -> gate: yes), not silently default off"
# flow style `gating: {prd: on, trd: on}` is parsed too — trd: on still arms the gate.
CFG_FLOW="$WORK/cfg-flow-on.yaml"; printf 'gating: { prd: on, trd: on }\n' > "$CFG_FLOW"
python3 "$RL" spec --config "$CFG_FLOW" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "flow-style gating {trd: on} must ARM the TRD gate (spec drift -> gate: yes)"
# A `gating:` block that IS PRESENT but yields no parseable prd/trd (here a YAML list, not a mapping)
# FAILS CLOSED — both switches gate — rather than silently falling back to the greenfield default-off.
# Break it (default-off on an unparseable present block) and the spec drift below prints `gate: no`.
CFG_UNPARSE="$WORK/cfg-unparseable.yaml"; printf 'gating:\n  - prd\n  - trd\n' > "$CFG_UNPARSE"
python3 "$RL" spec --config "$CFG_UNPARSE" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "a present-but-unparseable gating: block must FAIL CLOSED for the TRD (spec drift -> gate: yes), not default off"
python3 "$RL" prd  --config "$CFG_UNPARSE" 2>/dev/null | grep -q "^gate: yes$" \
  || fail "a present-but-unparseable gating: block must FAIL CLOSED for the PRD too (gate: yes)"

# ---- (b) requirements path reuses the ONE (Think-PR) gate; non-requirements path: no gate -----
T="$WORK/TRACKER.md"
python3 "$TRK" --tracker "$T" init || fail "tracker init failed"
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] PRD change — recirculate")
doc_issue=$(python3 "$TRK" --tracker "$T" create --title "Sync requirements-affected open issue")
python3 "$TRK" --tracker "$T" block --num "$doc_issue" --by "$gate" >/dev/null
[ "$(python3 "$TRK" --tracker "$T" show --num "$doc_issue" --field Status)" = "Blocked" ] || fail "requirements-drift dependent should be Blocked behind the gate"

# the Recirculator REUSES the one gate (it does not own a second one): its gated backflow routes to
# the same `idc:idc-gate-issue` mechanism Think fires at the end of Think (the Think PR).
[ -f "$RECIRC" ] || fail "agents/idc-recirculator.md missing"
grep -qF 'idc:idc-gate-issue' "$RECIRC" \
  || fail "the Recirculator must route a requirements-change backflow to the one gate (idc:idc-gate-issue)"
grep -qiE 'Think PR' "$RECIRC" \
  || fail "the Recirculator's gated backflow must reuse the gate fired at the end of Think (the Think PR)"
# WORKFLOW.md §2 must describe the one gate as the Think-PR requirements gate (anchor §2 kept).
[ -f "$WORKFLOW" ] || fail "templates/WORKFLOW.md missing"
grep -qiE 'Think PR' "$WORKFLOW" \
  || fail "WORKFLOW.md must describe the one gate as the Think PR (requirements admission at the end of Think)"

# ---- (c) the ONLY block-clearing/admission signal is the Think PR MERGING (FIX 2 / draft-until-merge) ----
# The PRD/TRD live in the Think PR and stay DRAFT until it merges. A closed-but-unmerged gate issue
# (or an `approved` comment) must therefore NOT clear the block — admitting on close/comment would let
# Plan/Autorun proceed against requirements that are still only draft in an open PR. The gate-issue
# skill must teach merge-only admission and must NOT offer close/comment as an approval/admission path.
GATE_SKILL="$PLUGIN/skills/idc-gate-issue/SKILL.md"
[ -f "$GATE_SKILL" ] || fail "skills/idc-gate-issue/SKILL.md missing"
# The retired close/comment-admits wording must be GONE. These substrings exist ONLY in the pre-fix
# skill (body: "merge the Think PR (or close this issue / comment ...)"; step 4: a close/comment is an
# "equivalent manual signal"), so their presence means the contract violation has returned → red.
grep -qiE 'or close this issue' "$GATE_SKILL" \
  && fail "gate-issue skill still offers 'close this issue' as an approval path — only MERGING the Think PR admits"
grep -qiE 'equivalent manual signal' "$GATE_SKILL" \
  && fail "gate-issue skill still treats a close/comment as an 'equivalent manual signal' — admission must be merge-only"
# And it must positively state that a closed-but-unmerged gate does NOT unblock (merge is admission).
grep -qiE 'closed-but-unmerged' "$GATE_SKILL" \
  || fail "gate-issue skill must state that a closed-but-unmerged gate does NOT unblock (Think-PR merge is the only admission)"

# ---- P2-2: the strategic decision gate is a modeled board slot, fail-closed, no 7th op --------
# A non-requirements GO/NO-GO (e.g. a proving-spike) gets a real board slot so the orchestrator
# never IMPROVISES the prompt (autorun audit Fix D). It is a SECOND gate TYPE in idc-gate-issue —
# NOT a second admission gate, and the requirements gate stays the only ADMISSION gate.
grep -qiE 'operator-decision' "$GATE_SKILL" \
  || fail "gate-issue skill must define the strategic operator-decision gate type (P2-2)"
grep -qiE 'decision-approved' "$GATE_SKILL" \
  || fail "the decision gate's approval must be an explicit positive signal (decision-approved / merged decision-PR), not a bare close (P2-2)"
grep -qiE 'closed-but-unapproved' "$GATE_SKILL" \
  || fail "the decision gate must state a closed-but-unapproved gate is NOT a GO (fail-closed) (P2-2)"
grep -qiE 'only requirements-admission gate' "$GATE_SKILL" \
  || fail "gate-issue skill must keep the requirements gate as the only ADMISSION gate (P2-2 doctrine preserved)"
grep -qiE 'operator-decision' "$WORKFLOW" \
  || fail "WORKFLOW.md must document the strategic operator-decision gate as a distinct board state (P2-2, append-only §2.1)"

# ---- Task 6: Recirculation consumes a route=recirculate intake unit + links it ----------------
# Recirculate accepts `<manifest>#<unit>` (only for a unit whose route is `recirculate`), processes it
# through the SAME layer decision, and links the unit to the resulting ticket/consideration/gate via
# the exact-once manifest helper — never leaving the manifest stale. It also closes its command
# contract and surfaces the oracle handoff (the command frame pinned across all commands in phase7).
RECIRC_CMD="$PLUGIN/commands/recirculate.md"
[ -f "$RECIRC_CMD" ] || fail "commands/recirculate.md missing"
grep -qF 'idc_intake_manifest.py' "$RECIRC" \
  || fail "agents/idc-recirculator.md must link a consumed route=recirculate intake unit through idc_intake_manifest.py link (Task 6)"
grep -qiE '<manifest>#<unit>|manifest.{0,6}#.{0,6}unit|\$MANIFEST#\$UNIT|route[ =]*recirculate' "$RECIRC_CMD" \
  || fail "commands/recirculate.md must accept a <manifest>#<unit> intake reference for a route=recirculate unit (Task 6)"
grep -qF 'idc_intake_manifest.py' "$RECIRC_CMD" \
  || fail "commands/recirculate.md must link a consumed intake unit through idc_intake_manifest.py (Task 6)"

echo "PASS: recirculation downstream-sync + requirements-only gate doctrine + Think-PR gate reuse + strategic decision gate green"
