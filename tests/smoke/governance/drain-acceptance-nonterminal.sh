#!/bin/bash
# idc-assert-class: behavior
# drain-acceptance-nonterminal.sh — governance scenario: a wave-close acceptance ERROR or GAP makes the
# WOULD-BE-`complete` drain NON-TERMINAL, instead of being swallowed into `drain: complete`/exit 0
# (v4 Phase 3 Stage E3; the codex-flagged residual deferred from Stage B).
#
# The invariant: when `idc_autorun_drain.py --acceptance` finds the build lane drained (`not eligible`
# — the point the drain would otherwise print terminal `drain: complete`), the wave-close acceptance
# result GATES the verdict:
#   * acceptance ERROR (the sibling idc_acceptance_check.py errored / exited 2 / produced no verdict —
#     e.g. a corrupt tracker) ⇒ `drain: unknown` + exit 2 (we CANNOT prove the wave clean → not
#     terminal; autorun retries next /loop). Same verdict TOKEN + exit as the github blind-drain guard.
#   * acceptance GAP (a merged-Done item is inert) ⇒ `drain: acceptance-gap` + exit 4 (a NON-TERMINAL
#     verdict on the EXISTING exit-4 code the Stop gate + /loop already handle; the `acceptance: gap …`
#     line is still printed so the orchestrator recirculates the inert items).
#   * acceptance OK (or `--acceptance` absent) ⇒ `drain: complete` + exit 0, unchanged.
# Precedence: the gate fires ONLY on the would-be-`complete` path — an already-non-terminal verdict
# (recirc-pending/4) still wins. The new unknown/acceptance-gap verdicts PERSIST via the Stage E2
# sidecar so the github Stop gate reads them. The Phase-0 exit-code CONTRACT is unchanged (set {0,2,3,4}
# — acceptance-gap is a new TOKEN on the existing exit 4, not a new code).
#
# Red-when-broken (MANDATORY, reviewed): revert the acceptance gate (the two `if not eligible and
# accept_cls == …` branches in idc_autorun_drain.py main()) ⇒ case GAP prints `drain: complete`/0 and
# case ERROR prints `drain: complete`/0 instead of the non-terminal verdicts — both asserts go RED.
# (This is exactly the pre-Stage-E3 behavior, so running this scenario against the un-gated drain FAILs.)
#
# Filesystem-backed (hermetic, no gh). Each board lives in a GOVERNED repo dir (docs/workflow/
# tracker-config.yaml present) so the Stage E2 verdict persist (repo-gated) actually fires and is
# assertable. Auto-discovered by the governance lane (phase-governance.sh); runnable standalone under
# BOTH python3 and a no-pyyaml venv (none of these scripts import yaml).
#
# Usage: bash tests/smoke/governance/drain-acceptance-nonterminal.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
ACC="$GOV_PLUGIN/scripts/idc_acceptance_check.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
VERDICT="$GOV_PLUGIN/scripts/hooks/idc_drain_verdict.py"
[ -f "$DRAIN" ]   || fail "idc_autorun_drain.py not found at $DRAIN"
[ -f "$ACC" ]     || fail "idc_acceptance_check.py not found at $ACC (the sibling the drain reuses)"
[ -f "$VERDICT" ] || fail "idc_drain_verdict.py not found at $VERDICT (the Stage E2 persist sidecar)"

# new_repo -> echoes a fresh GOVERNED repo dir with an init'd TRACKER.md. Governed = docs/workflow/
# tracker-config.yaml present, so the repo-gated verdict persist actually writes (and is assertable).
new_repo() {
  local d
  d="$(mktemp -d)" || return 1
  mkdir -p "$d/docs/workflow" || return 1
  : > "$d/docs/workflow/tracker-config.yaml" || return 1
  python3 "$TRK" --tracker "$d/TRACKER.md" init >/dev/null || return 1
  printf '%s' "$d"
}
REPOS=()
cleanup() { for r in "${REPOS[@]:-}"; do [ -n "$r" ] && rm -rf "$r"; done; }
trap cleanup EXIT

# run_drain <tracker> <session> [extra-args…] -> stdout in $OUT, exit code in $RC (never aborts).
run_drain() { local t="$1" s="$2"; shift 2; OUT="$(python3 "$DRAIN" --tracker "$t" --session-id "$s" "$@" 2>/dev/null)"; RC=$?; }

# ── 1. acceptance GAP ⇒ drain: acceptance-gap + exit 4 (NOT complete/0), gap line printed + persisted ─
# A merged-"Done" increment with an unmet blocks_goal:true deferral (resolves to no clean Done enabler)
# is Done-but-INERT: the real idc_acceptance_check.py flags it `acceptance: gap <n>`. The build lane is
# drained (the Done item is not Buildable Todo) and the inbox is empty ⇒ the drain would otherwise print
# terminal `drain: complete`. The Stage E3 gate must instead make it NON-TERMINAL.
R1="$(new_repo)" || fail "new_repo failed (GAP)"; REPOS+=("$R1"); T1="$R1/TRACKER.md"
DONE="$(python3 "$TRK" --tracker "$T1" create --title 'ddl merged, instance not provisioned' --stage Buildable --status Done)" \
  || fail "seed of the Done issue failed (GAP)"
python3 "$TRK" --tracker "$T1" comment --num "$DONE" \
  --body '<!-- idc-deferral: {"kind":"infra","what":"provision the instance","blocks_goal":true,"suggested_issue":"none"} -->' \
  >/dev/null || fail "could not attach the blocks_goal deferral marker (GAP)"
# precondition: the REAL checker independently reports the gap (exit 1) — proves the seed is genuinely inert.
python3 "$ACC" --tracker "$T1" >/dev/null 2>&1; [ $? -eq 1 ] \
  || fail "(GAP) precondition: idc_acceptance_check.py must exit 1 (gap) on the inert Done seed"
run_drain "$T1" S-GAP --acceptance
[ "$RC" -eq 4 ] \
  || fail "(GAP) an inert Done at wave close must be NON-TERMINAL — exit 4, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|')) [revert the gate ⇒ exit 0 RED]"
printf '%s\n' "$OUT" | grep -qx "drain: acceptance-gap" \
  || fail "(GAP) must print 'drain: acceptance-gap' (out: $(printf '%s' "$OUT" | tr '\n' '|')) [revert the gate ⇒ 'drain: complete' RED]"
printf '%s\n' "$OUT" | grep -qx "drain: complete" \
  && fail "(GAP) the drain must NOT report terminal 'drain: complete' on an inert wave close (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "acceptance: gap $DONE" \
  || fail "(GAP) the 'acceptance: gap $DONE' line must still be printed so the orchestrator recirculates (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
V="$(python3 "$VERDICT" --cwd "$R1" read --session S-GAP)"
printf '%s' "$V" | grep -q '"verdict": "acceptance-gap"' \
  || fail "(GAP) the acceptance-gap verdict must be PERSISTED (Stage E2) — got: ${V:-<none>}"
printf '%s' "$V" | grep -q '"exit": 4' \
  || fail "(GAP) the persisted verdict must record exit 4 — got: ${V:-<none>}"
echo "  ok (GAP) an inert Done at wave close ⇒ drain: acceptance-gap exit 4 (gap line printed, verdict persisted), NOT complete"

# ── 2. acceptance ERROR ⇒ drain: unknown + exit 2 (NOT complete/0), persisted ──────────────────────
# Feed acceptance a corrupt input the DRAIN itself tolerates: a Done issue whose deferral marker is
# unparseable JSON. The drain's load_filesystem never inspects comments (so it computes eligible=[]
# cleanly), but the real idc_acceptance_check.py exits 2 on the bad marker. The checker's non-zero,
# non-clean-gap exit + missing verdict line must classify as ERROR ⇒ drain: unknown, NOT a silent complete.
R2="$(new_repo)" || fail "new_repo failed (ERROR)"; REPOS+=("$R2"); T2="$R2/TRACKER.md"
DONE2="$(python3 "$TRK" --tracker "$T2" create --title 'corrupt deferral marker' --stage Buildable --status Done)" \
  || fail "seed of the Done issue failed (ERROR)"
python3 "$TRK" --tracker "$T2" comment --num "$DONE2" \
  --body '<!-- idc-deferral: {"kind":"infra", THIS IS NOT JSON -->' \
  >/dev/null || fail "could not attach the corrupt deferral marker (ERROR)"
# precondition A: the REAL checker exits 2 (error) on the corrupt marker.
python3 "$ACC" --tracker "$T2" >/dev/null 2>&1; [ $? -eq 2 ] \
  || fail "(ERROR) precondition: idc_acceptance_check.py must exit 2 (error) on the corrupt marker"
# precondition B: the DRAIN itself tolerates the same tracker (it never reads comments) — a corrupt
# deferral is an acceptance-layer error, not a drain load error. Without --acceptance it drains cleanly.
run_drain "$T2" S-ERR-PRE
[ "$RC" -eq 0 ] \
  || fail "(ERROR) precondition: the drain must TOLERATE the corrupt-marker tracker without --acceptance (got exit $RC — the corruption must surface only via the acceptance check)"
run_drain "$T2" S-ERR --acceptance
[ "$RC" -eq 2 ] \
  || fail "(ERROR) an unrunnable/corrupt wave-close acceptance must be NON-TERMINAL — exit 2, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|')) [revert the gate ⇒ exit 0 RED]"
printf '%s\n' "$OUT" | grep -qx "drain: unknown" \
  || fail "(ERROR) must print 'drain: unknown' (out: $(printf '%s' "$OUT" | tr '\n' '|')) [revert the gate ⇒ 'drain: complete' RED]"
printf '%s\n' "$OUT" | grep -qx "drain: complete" \
  && fail "(ERROR) the drain must NOT report terminal 'drain: complete' when acceptance could not be proven (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
V2="$(python3 "$VERDICT" --cwd "$R2" read --session S-ERR)"
printf '%s' "$V2" | grep -q '"verdict": "unknown"' \
  || fail "(ERROR) the unknown verdict must be PERSISTED (Stage E2) — got: ${V2:-<none>}"
printf '%s' "$V2" | grep -q '"exit": 2' \
  || fail "(ERROR) the persisted verdict must record exit 2 — got: ${V2:-<none>}"
echo "  ok (ERROR) a corrupt/unrunnable wave-close acceptance ⇒ drain: unknown exit 2 (persisted), NOT complete"

# ── 3. acceptance OK ⇒ drain: complete + exit 0, unchanged (control) ───────────────────────────────
# A clean Done (no deferral) at wave close: acceptance reports ok, and the drain's terminal verdict
# stays exactly `drain: complete` exit 0. The gate must NOT fire on a clean wave close.
R3="$(new_repo)" || fail "new_repo failed (OK)"; REPOS+=("$R3"); T3="$R3/TRACKER.md"
python3 "$TRK" --tracker "$T3" create --title 'clean Done, nothing deferred' --stage Buildable --status Done >/dev/null \
  || fail "seed of the clean Done failed (OK)"
run_drain "$T3" S-OK --acceptance
[ "$RC" -eq 0 ] \
  || fail "(OK) a clean wave close must stay terminal — exit 0, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: complete" \
  || fail "(OK) a clean wave close must print 'drain: complete' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "acceptance: ok" \
  || fail "(OK) the 'acceptance: ok' line must be printed on a clean wave close (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
V3="$(python3 "$VERDICT" --cwd "$R3" read --session S-OK)"
printf '%s' "$V3" | grep -q '"verdict": "complete"' \
  || fail "(OK) the complete verdict must be PERSISTED unchanged — got: ${V3:-<none>}"
echo "  ok (OK) a clean wave close ⇒ drain: complete exit 0, unchanged (gate does not fire)"

# ── 4. PRECEDENCE: recirc-pending/4 still wins over an acceptance gap on the same board ─────────────
# A board that is BOTH would-be-complete-with-a-GAP AND has a non-empty Recirculation inbox. The
# acceptance gate only changes the would-be-`complete` path; an already-non-terminal verdict
# (recirc-pending, which precedes the gate) must still win — the acceptance gap is moot.
R4="$(new_repo)" || fail "new_repo failed (PRECEDENCE)"; REPOS+=("$R4"); T4="$R4/TRACKER.md"
DONE4="$(python3 "$TRK" --tracker "$T4" create --title 'inert Done' --stage Buildable --status Done)" \
  || fail "seed of the inert Done failed (PRECEDENCE)"
python3 "$TRK" --tracker "$T4" comment --num "$DONE4" \
  --body '<!-- idc-deferral: {"kind":"infra","what":"provision","blocks_goal":true,"suggested_issue":"none"} -->' \
  >/dev/null || fail "could not attach the blocks_goal deferral marker (PRECEDENCE)"
python3 "$TRK" --tracker "$T4" create --title 'recirc: discovered mid-build scope' --stage Recirculation --status Todo >/dev/null \
  || fail "could not seed the Recirculation inbox ticket (PRECEDENCE)"
run_drain "$T4" S-PREC --acceptance
[ "$RC" -eq 4 ] \
  || fail "(PRECEDENCE) a non-empty recirc inbox must still exit 4, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: recirc-pending" \
  || fail "(PRECEDENCE) recirc-pending must WIN over an acceptance gap — expected 'drain: recirc-pending' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: acceptance-gap" \
  && fail "(PRECEDENCE) the acceptance gate must NOT override an already-non-terminal recirc-pending verdict (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
V4="$(python3 "$VERDICT" --cwd "$R4" read --session S-PREC)"
printf '%s' "$V4" | grep -q '"verdict": "recirc-pending"' \
  || fail "(PRECEDENCE) recirc-pending must be the persisted verdict — got: ${V4:-<none>}"
echo "  ok (PRECEDENCE) recirc-pending exit 4 still wins over an acceptance gap (gate fires only on would-be-complete)"

# ── 5. NO --acceptance ⇒ default output byte-identical (the gate never fires) ───────────────────────
# The inert-Done GAP board from case 1, run WITHOUT --acceptance, must drain exactly `drain: complete`
# exit 0 with NO acceptance line — proving the gate is strictly opt-in and the default path untouched.
run_drain "$T1" S-DEFAULT
[ "$RC" -eq 0 ] \
  || fail "(DEFAULT) without --acceptance the GAP board must drain complete exit 0, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: complete" \
  || fail "(DEFAULT) without --acceptance the GAP board must print 'drain: complete' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qi '^acceptance:' \
  && fail "(DEFAULT) no acceptance line may appear without --acceptance — default output must stay byte-identical"
echo "  ok (DEFAULT) without --acceptance the gate never fires — default drain output byte-identical"

echo "PASS: a wave-close acceptance ERROR ⇒ drain: unknown exit 2 and a GAP ⇒ drain: acceptance-gap exit 4 (both non-terminal + persisted, gap line still printed); acceptance ok stays drain: complete exit 0; recirc-pending still wins; the gate is opt-in (--acceptance) so default output is byte-identical; Phase-0 exit-code set {0,2,3,4} unchanged"
