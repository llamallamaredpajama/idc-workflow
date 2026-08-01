#!/bin/bash
# idc-assert-class: doc
# Phase 8 smoke — the vendored Pi role prompts match the CURRENT 5-field-board IDC contract:
# they drive the board through the tracker adapter (not TRACKER.md), Plan is idempotent + sets
# the board fields + runs the matrix, Build claims before working, the finisher prepares an
# operator-merge handoff only on a durable review verdict + recirculates, the reviewer is source/tracker-read-only
# but writes a scoped verdict artifact under docs/workflow/code-reviews/ and reports findings
# over coms-net when available, and NO prompt carries the RETIRED vocabulary (claim-state
# machine, bookend ceremony, the deleted recirculator verdict taxonomy / change-order files).
#
# Red-when-broken: every must-have line below is ABSENT from the pre-fix prompts (they were
# file-write-framed and delegated to non-existent codex-idc-* skills), so this fails before the
# rewrite; every must-not line is PRESENT pre-fix, so it also fails — both flip green after.
#
# Usage: bash tests/smoke/phase8-pi-prompt-alignment.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
A="$PLUGIN/runtime/pi/.pi/agents/idc"
WORKFLOW="$PLUGIN/templates/WORKFLOW.md"
HOOKS="$PLUGIN/hooks/hooks.json"
fails=0
have() { # file regex label
  if ! grep -qiE "$2" "$A/$1"; then echo "MISSING in $1: $3 (/$2/)"; fails=$((fails+1)); fi
}
absent() { # file regex label
  if grep -qiE "$2" "$A/$1"; then echo "RETIRED-VOCAB in $1: $3 (/$2/)"; fails=$((fails+1)); fi
}

# ── Every role drives the board through the tracker adapter ─────────────────────────────────
for f in think plan sequence recirculator build-implementer build-reviewer build-finisher; do
  have "$f.md" "idc:idc-tracker-adapter" "names the tracker adapter"
done

# ── No prompt may reference the non-existent skills it used to delegate to ───────────────────
for f in think plan sequence recirculator build-implementer build-reviewer build-finisher; do
  absent "$f.md" "codex-idc-|skills/idc-workflow" "dead skill reference (codex-idc-* / idc-workflow)"
done

# ── No prompt may carry the RETIRED contract vocabulary ──────────────────────────────────────
for f in think plan sequence recirculator build-implementer build-reviewer build-finisher; do
  absent "$f.md" "claim-state|bookend" "retired claim-state/bookend vocab"
done

# ── Plan: idempotency + the five board fields + the matrix guardrail + Planning stage ────────
have "plan.md" "idempoten|duplicate|already exists" "idempotency guard"
have "plan.md" "Stage" "sets Stage"
have "plan.md" "Status" "sets Status"
have "plan.md" "Wave" "knows Wave"
have "plan.md" "Phase" "sets Phase"
have "plan.md" "Domain" "sets Domain"
have "plan.md" "idc:idc-matrix-analysis" "runs the matrix deconfliction"
have "plan.md" "Planning" "produces Planning-stage pointers"

# ── Sequence: admits to the board (Buildable + Wave), not TRACKER.md ─────────────────────────
have "sequence.md" "Buildable" "promotes Stage=Buildable"
have "sequence.md" "Wave" "owns Wave admission"

# ── Build implementer: claim-before-work eligibility ─────────────────────────────────────────
have "build-implementer.md" "Status[ =]?Todo|Status.?Todo" "queries Status=Todo"
have "build-implementer.md" "Buildable" "queries Stage=Buildable"
have "build-implementer.md" "blocked.?by" "checks blocked-by upstreams"
have "build-implementer.md" "claim" "claims the issue before working"
have "build-implementer.md" "In Progress" "flips Status to In Progress on claim"
have "build-implementer.md" "EXACT artifact" "enforces the goal contract's exact artifact (no language/framework substitution — review FAIL-BLOCKs substitutes)"

# ── Build reviewer: source/tracker-read-only; writes a durable verdict + may report over coms-net ─
have "build-reviewer.md" "source/tracker-read-only|read-only on source and tracker" "states it is read-only on source/tracker"
have "build-reviewer.md" "docs/workflow/code-reviews" "writes the durable review artifact lane"
have "build-reviewer.md" "pr-<PR-NUMBER>\\.verdict\\.json|pr-\\$\\{PR_NUMBER\\}\\.verdict\\.json|pr-[^ ]*verdict\\.json" "names the deterministic verdict file"
have "build-reviewer.md" "coms" "reports findings over coms-net when available"
have "build-reviewer.md" "verdict" "emits a verdict"
have "build-reviewer.md" "PASS" "uses the PASS/FAIL verdict ladder"
have "build-reviewer.md" "confabulate" "forbids confabulated verification (read-only; no narrated fixes that could yield a false PASS)"

# ── Build finisher: prepare for an operator merge; recirculate-on-persistent-fail ────────────
have "build-finisher.md" "verdict" "gates merge on the review verdict"
have "build-finisher.md" "PASS" "prepares only after PASS/PASS-WITH-NITS"
have "build-finisher.md" "operator[- ]performed|operator (performs|must perform|merges)" "makes merge operator-performed until a sanctioned helper exists"
have "build-finisher.md" "prepare[^.]{0,100}push[^.]{0,100}(report|handoff)|(prepare|push|report)[^.]{0,100}(operator|merge)" "limits the agent to prepare/push/report before operator merge"
absent "build-finisher.md" "gh pr merge" "forbidden raw merge instruction"
have "build-finisher.md" "recirculat" "recirculates on persistent failure"
have "build-finisher.md" "Done" "explains post-merge Status=Done handling"

# ── Plan: opens/pushes the planning PR, but merge is operator-performed for now ─────────────
have "plan.md" "operator[- ]performed|operator (performs|must perform|merges)" "makes planning-PR merge operator-performed until a sanctioned helper exists"
have "plan.md" "open[^.]{0,100}(push|planning PR)|(push|report)[^.]{0,100}(operator|merge)" "limits Plan to opening/pushing/reporting the PR"
absent "plan.md" "self-merge|gh pr merge" "forbidden raw/self-merge instruction"

# ── Recirculator: prepares/pushes/reports the sync PR; merge is operator-performed ──────────
have "recirculator.md" "operator[- ]performed|operator (performs|must perform|merges)" "makes sync-PR merge operator-performed until a sanctioned helper exists"
have "recirculator.md" "prepare[^.]{0,120}push[^.]{0,120}(report|handoff)|(prepare|push|report)[^.]{0,120}(operator|merge)" "limits the Recirculator to preparing/pushing/reporting the sync PR"
absent "recirculator.md" "automerge|auto-merge|self-merge|gh pr merge" "forbidden automatic/raw/self-merge instruction"

# ── Shared transport boundary + controlled-mode limitations are explicit ───────────────────
for transport in Bash Write Edit NotebookEdit; do
  if ! grep -q "$transport" "$WORKFLOW"; then
    echo "MISSING in WORKFLOW.md: covered Path Gate transport $transport"
    fails=$((fails+1))
  fi
done
if ! tr '\n' ' ' < "$WORKFLOW" | grep -qiE 'MCP[^.]{0,180}(explicit|dedicated)[^.]{0,120}(adapter|matcher)[^.]{0,120}(not|no)[^.]{0,80}(claim|cover)|not[^.]{0,100}(claim|cover)[^.]{0,180}MCP'; then
  echo "MISSING in WORKFLOW.md: MCP writer tools require an explicit adapter/matcher and are not claimed covered"
  fails=$((fails+1))
fi
for limitation in 'minted per COMMAND, not per transition|mint-at-transition' 'per-worktree|per-worker-worktree|per worktree' 'Pi and Codex|Pi/Codex' 'finisher/merge helper|merge helper' 'identity binding' 'TTL (heartbeat )?renewal|heartbeat renewal'; do
  if ! grep -qiE "$limitation" "$WORKFLOW"; then
    echo "MISSING in WORKFLOW.md: controlled-mode limitation /$limitation/"
    fails=$((fails+1))
  fi
done
grep -qiE 'default[^.]{0,80}off|off[^.]{0,80}default' "$WORKFLOW" || { echo "MISSING in WORKFLOW.md: pathway enforcement defaults to off"; fails=$((fails+1)); }
grep -qiE 'controlled[^.]{0,100}(opt-in|opt in)' "$WORKFLOW" || { echo "MISSING in WORKFLOW.md: controlled is opt-in"; fails=$((fails+1)); }
# The limitation list must state STATUS, not point at a unit of work. It used to say the six were
# "tracked to U8/U9"; U8 and U9 MERGED on 2026-07-23 without closing any of them, so from that day the
# sentence read as "handled" while every one was still open — and this lane REQUIRED that sentence,
# so it held the stale claim in place. The invariant is now the honest form, in both directions.
grep -qiE 'Every one of them is \*\*still open\*\*' "$WORKFLOW" \
  || { echo "MISSING in WORKFLOW.md: the controlled-mode limitations must be stated as still open"; fails=$((fails+1)); }
if grep -qiE 'U8/U9|tracked to U[0-9]' "$WORKFLOW"; then
  echo "STALE in WORKFLOW.md: a controlled-mode limitation is deferred to a named unit of work — that pointer reads as 'handled' the moment the unit merges, whether or not the limitation closed"
  fails=$((fails+1))
fi
# ── The merge posture is PI-SCOPED, and these invariants used to universalise it ───────────────────
# This lane previously demanded that WORKFLOW.md say merges are operator-performed, full stop, and
# BANNED the word "automerge" outright. Both were wrong in the direction that is hardest to notice —
# they described the experimental Pi runtime's carve-out as the whole system's behavior. Claude and
# Codex DO self-merge, through `idc_pr_finish.py autonomous` (planning / intake / recirculation) and
# `idc_git_finish.py` (build PRs); `agents/idc-finisher.md` §Git finalization and `agents/idc-plan.md`
# are the code-level sources, and WORKFLOW.md §4.3a already described `idc_git_finish.py --close-only`,
# so the file CONTRADICTED ITSELF while this lane held the false half in place. A doc lane that
# enforces a false claim is worse than no lane: it turns the correction red.
#
# The honest invariants, in both directions:
#   * Pi's carve-out must be stated AND scoped to Pi (not to "the system").
#   * The runtimes that DO self-merge must be named, so the carve-out cannot re-universalise.
#   * An automerge claim is fine — REQUIRED, even — but it must never appear un-runtime-scoped.
tr '\n' ' ' < "$WORKFLOW" | grep -qiE 'Pi[^.]{0,200}no sanctioned merge helper|no sanctioned merge helper[^.]{0,200}Pi' \
  || { echo "MISSING in WORKFLOW.md: the missing merge helper must be scoped to the experimental Pi runtime, not stated as a system-wide gap"; fails=$((fails+1)); }
grep -qiE 'Claude and Codex[^.]{0,120}self-merge' "$WORKFLOW" \
  || { echo "MISSING in WORKFLOW.md: the runtimes that DO self-merge (Claude and Codex, via idc_pr_finish.py autonomous / idc_git_finish.py) must be named, or the Pi carve-out reads as system-wide"; fails=$((fails+1)); }
if grep -qiE 'automerge|auto-merge' "$WORKFLOW"; then
  # NOTE the window is `.{0,160}`, not `[^.]{0,160}`: the sentence that scopes the claim names the
  # helper (`idc_pr_finish.py`), and a dot-excluding window stops dead at that filename's dot — the
  # check would then demand a scoping that IS present. Proximity is the assertion here.
  tr '\n' ' ' < "$WORKFLOW" | grep -qiE '(automerge|auto-merge).{0,160}(Claude|Codex|Pi)|(Claude|Codex|Pi).{0,160}(automerge|auto-merge)' \
    || { echo "STALE in WORKFLOW.md: an UNSCOPED automerge promise — automerge is Claude/Codex behavior and the experimental Pi runtime does not self-merge, so the claim must name the runtime it applies to"; fails=$((fails+1)); }
fi
tr '\n' ' ' < "$WORKFLOW" | grep -qiE 'planning PRs[^.]{0,200}(finisher|operator)|(finisher|operator)[^.]{0,200}planning PRs' \
  || { echo "MISSING in WORKFLOW.md: planning PR merge posture (sanctioned finisher on Claude/Codex, operator on Pi)"; fails=$((fails+1)); }
tr '\n' ' ' < "$WORKFLOW" | grep -qiE 'build PRs[^.]{0,200}(finisher|operator)|(finisher|operator)[^.]{0,200}build PRs' \
  || { echo "MISSING in WORKFLOW.md: build PR merge posture (sanctioned finisher on Claude/Codex, operator on Pi)"; fails=$((fails+1)); }

python3 - "$HOOKS" <<'PY' || { echo "MISSING in hooks.json: honest Bash/Write/Edit/NotebookEdit coverage description"; fails=$((fails+1)); }
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
desc = doc.get("description", "")
for name in ("Bash", "Write", "Edit", "NotebookEdit"):
    assert name in desc, name
PY

# ── Recirculator: binary gate model; NOT the deleted verdict taxonomy ────────────────────────
have "recirculator.md" "idc_recirculator_layers.py|gate:.?no|gate:.?yes|gated Think PR" "binary gate decision"
absent "recirculator.md" "NO_RECIRCULATION|MINOR_AUTONOMOUS|MAJOR_GATED" "deleted verdict taxonomy"

if [ "$fails" -eq 0 ]; then
  echo "PASS: Pi role prompts and Path Gate docs align (the missing merge helper is scoped to the experimental Pi runtime and the self-merging runtimes are named, so no automerge claim goes un-runtime-scoped; explicit transport coverage; the six controlled-mode limits stated as STILL OPEN rather than deferred to a merged unit; no retired vocab)"
  exit 0
fi
echo "FAIL: $fails prompt-alignment invariant(s) unmet"
exit 1
