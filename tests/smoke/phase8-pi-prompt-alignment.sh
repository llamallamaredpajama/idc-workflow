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
for limitation in 'mint-at-transition' 'per-worktree|per-worker-worktree' 'Pi and Codex|Pi/Codex' 'finisher/merge helper|merge helper' 'identity binding' 'TTL (heartbeat )?renewal|heartbeat renewal'; do
  if ! grep -qiE "$limitation" "$WORKFLOW"; then
    echo "MISSING in WORKFLOW.md: controlled-mode U8/U9 limitation /$limitation/"
    fails=$((fails+1))
  fi
done
grep -qiE 'default[^.]{0,80}off|off[^.]{0,80}default' "$WORKFLOW" || { echo "MISSING in WORKFLOW.md: pathway enforcement defaults to off"; fails=$((fails+1)); }
grep -qiE 'controlled[^.]{0,100}(opt-in|opt in)' "$WORKFLOW" || { echo "MISSING in WORKFLOW.md: controlled is opt-in"; fails=$((fails+1)); }
grep -qiE 'tracked to U8/U9|U8/U9' "$WORKFLOW" || { echo "MISSING in WORKFLOW.md: limitations are tracked to U8/U9"; fails=$((fails+1)); }

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
  echo "PASS: Pi role prompts and Path Gate docs align (operator-performed merge until a sanctioned helper; explicit transport coverage and U8/U9 controlled-mode limits; no retired vocab)"
  exit 0
fi
echo "FAIL: $fails prompt-alignment invariant(s) unmet"
exit 1
