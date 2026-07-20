#!/bin/bash
# idc-assert-class: behavior
# drain-wave-close-acceptance.sh — governance scenario: the drain loop INVOKES idc_acceptance_check.py
# at wave close (v4 Phase 3 Stage B). Proven with a SPY (a marker, not prose) and with the REAL check.
#
# The invariant: when `idc_autorun_drain.py --acceptance` finds the build lane drained (`not eligible`
# — the point the drain loop finishes a wave), it runs the EXISTING sibling idc_acceptance_check.py
# over the same tracker and surfaces its `acceptance: <ok|gap …>` verdict, so a merged-"Done" issue can
# never ship INERT (autorun audit Fix B). It reuses that script (never reimplements inertness). Since
# Stage E3 the result also GATES the would-be-`complete` verdict (gap ⇒ `drain: acceptance-gap` exit 4;
# see drain-acceptance-nonterminal.sh for the full gating matrix) — the Phase-0 exit-code SET {0,2,3,4}
# is unchanged. The line is opt-in (--acceptance) so default output stays byte-identical.
#
# Red-when-broken (MANDATORY, reviewed): remove the wave-close invocation (the `if args.acceptance and
# not eligible …` block in idc_autorun_drain.py) ⇒ the SPY marker is never written and the (SPY)/(GAP)
# asserts go RED.
#
# Filesystem-backed (hermetic, no gh). Auto-discovered by the governance lane (phase-governance.sh);
# runnable standalone under BOTH python3 and `uv run --with pyyaml`.
#
# Usage: bash tests/smoke/governance/drain-wave-close-acceptance.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
ACC="$GOV_PLUGIN/scripts/idc_acceptance_check.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$DRAIN" ] || fail "idc_autorun_drain.py not found at $DRAIN"
[ -f "$ACC" ]   || fail "idc_acceptance_check.py not found at $ACC (the sibling the drain must reuse)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── (SPY) the drain actually INVOKES the sibling script at wave close (marker, not prose) ──────────
# Copy the REAL drain beside a SPY idc_acceptance_check.py in a temp scripts dir. The drain resolves the
# checker relative to its OWN dir (os.path.dirname(__file__)), so the copied drain calls the spy — which
# writes a marker + a distinctive verdict line. This proves invocation without mutating the shipped repo.
SPYDIR="$WORK/scripts"; mkdir -p "$SPYDIR"
cp "$DRAIN" "$SPYDIR/idc_autorun_drain.py"
# The drain scrubs credential shapes out of child-process output at the door, through the SHARED
# table, which it resolves beside itself exactly as it resolves the checker. Copy it too, or this
# fixture models an install that cannot exist — and the drain, fail-closed by design, withholds every
# checker line rather than risk emitting an unscrubbed one.
cp "$GOV_PLUGIN/scripts/idc_credential_shapes.py" "$SPYDIR/idc_credential_shapes.py"
MARKER="$WORK/spy-was-invoked"
cat > "$SPYDIR/idc_acceptance_check.py" <<PY
#!/usr/bin/env python3
import sys
open("$MARKER", "w").write("invoked " + " ".join(sys.argv[1:]))
print("acceptance: SPY-INVOKED")
sys.exit(0)
PY
TS="$WORK/spy-tracker.md"; python3 "$TRK" --tracker "$TS" init >/dev/null || fail "spy tracker init failed"
out="$(python3 "$SPYDIR/idc_autorun_drain.py" --tracker "$TS" --acceptance 2>/dev/null)"
[ -f "$MARKER" ] \
  || fail "(SPY) the drain did NOT invoke idc_acceptance_check.py at wave close — no marker [remove the invocation ⇒ RED]"
printf '%s\n' "$out" | grep -qx "acceptance: SPY-INVOKED" \
  || fail "(SPY) the drain did not surface the checker's verdict line (got: $(printf '%s' "$out" | tr '\n' '|'))"
grep -q -- "--tracker $TS" "$MARKER" \
  || fail "(SPY) the drain must invoke the checker over the SAME tracker (marker said: $(cat "$MARKER"))"
echo "  ok (SPY) the drain invokes idc_acceptance_check.py over the same tracker at wave close (marker written)"

# ── (GAP) with the REAL checker, a Done-but-inert increment surfaces through the drain as gap <n> ──
# Only idc_acceptance_check.py computes inertness (a transitive blocks_goal:true deferral) — the drain
# never reimplements it — so reproducing the exact gap number THROUGH the drain proves the real wiring.
TG="$WORK/gap-tracker.md"; python3 "$TRK" --tracker "$TG" init >/dev/null || fail "gap tracker init failed"
DONE="$(python3 "$TRK" --tracker "$TG" create --title 'ddl merged, instance not provisioned' --stage Buildable --status Done)" \
  || fail "seed of the Done issue failed"
python3 "$TRK" --tracker "$TG" comment --num "$DONE" \
  --body '<!-- idc-deferral: {"kind":"infra","what":"provision the instance","blocks_goal":true,"suggested_issue":"none"} -->' \
  >/dev/null || fail "could not attach the blocks_goal deferral marker"
out="$(python3 "$DRAIN" --tracker "$TG" --acceptance 2>/dev/null)"
printf '%s\n' "$out" | grep -qx "acceptance: gap $DONE" \
  || fail "(GAP) the drain must surface the real acceptance gap 'acceptance: gap $DONE' at wave close (got: $(printf '%s' "$out" | tr '\n' '|')) [remove the invocation ⇒ RED]"
# and since Stage E3 the gap GATES the would-be-`complete` verdict: drain: acceptance-gap / exit 4
# (non-terminal), on the EXISTING exit-4 code — the deep gating matrix lives in
# drain-acceptance-nonterminal.sh; this pins that the Stage-B wiring + the E3 contract agree.
printf '%s\n' "$out" | grep -qx "drain: acceptance-gap" \
  || fail "(GAP) an inert wave close must gate the verdict to 'drain: acceptance-gap' (Stage E3) (got: $(printf '%s' "$out" | tr '\n' '|'))"
python3 "$DRAIN" --tracker "$TG" --acceptance >/dev/null 2>&1; [ $? -eq 4 ] \
  || fail "(GAP) an acceptance gap must exit 4 (the existing non-terminal code — Stage E3)"
echo "  ok (GAP) a Done-but-inert increment surfaces through the drain as 'acceptance: gap $DONE' (real check) and gates the verdict to acceptance-gap/4"

# ── (OPT-IN) without --acceptance, NO acceptance line (default output byte-identical) ──────────────
out="$(python3 "$DRAIN" --tracker "$TG" 2>/dev/null)"
printf '%s\n' "$out" | grep -qi '^acceptance:' \
  && fail "(OPT-IN) the acceptance line must be OPT-IN — default drain output must stay byte-identical"
echo "  ok (OPT-IN) the acceptance line is opt-in — absent without --acceptance"

# ── (WAVE-OPEN) eligible build work ⇒ NOT wave close ⇒ no acceptance line even with --acceptance ───
TB="$WORK/build-tracker.md"; python3 "$TRK" --tracker "$TB" init >/dev/null || fail "build tracker init failed"
python3 "$TRK" --tracker "$TB" create --title 'build: eligible' --stage Buildable --status Todo >/dev/null \
  || fail "seed of the eligible build item failed"
out="$(python3 "$DRAIN" --tracker "$TB" --acceptance 2>/dev/null)"
printf '%s\n' "$out" | grep -qx "drain: continue" \
  || fail "(WAVE-OPEN) precondition: eligible build work ⇒ drain: continue (got: $(printf '%s' "$out" | tr '\n' '|'))"
printf '%s\n' "$out" | grep -qi '^acceptance:' \
  && fail "(WAVE-OPEN) acceptance must run only at WAVE CLOSE (build lane drained), not while build work is eligible"
echo "  ok (WAVE-OPEN) acceptance runs only at wave close — skipped while build work is eligible"

echo "PASS: the drain loop invokes idc_acceptance_check.py at wave close (spy marker + real gap reproduced through the drain), opt-in (byte-identical default), only when the build lane is drained; a real gap gates the verdict to acceptance-gap/4 (Stage E3) within the unchanged Phase-0 exit-code set"
