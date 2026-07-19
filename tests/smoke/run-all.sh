#!/bin/bash
# run-all.sh — the IDC v2 functional verification suite.
#
# Runs every per-phase smoke test (real round-trips against the shipped helpers and a
# throwaway filesystem-backend sandbox — no live GitHub). This is v2's verification surface;
# the v1 behavioral evalset harness (scripts/run-evals.sh) is retired.
#
# Usage: bash tests/smoke/run-all.sh   (exit 0 = all green)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/smoke-path-preflight.sh"

# Preflight: fail once, clearly, if TMPDIR is unwritable — otherwise every phase's `WORK="$(mktemp -d)"`
# comes back empty, writes fall through to bogus root paths, and the cascade looks like N broken tests
# (not one blocked environment). A read-only TMPDIR in a sandboxed/managed cell is the trigger.
#
# Probe with an explicit template pinned INSIDE TMPDIR: a bare `mktemp -d` silently
# falls back to the system temp on some implementations (notably GNU coreutils) when
# TMPDIR is unwritable, which would hide exactly the failure we want to catch. An
# explicit template forces creation at that path, so a bad TMPDIR fails here instead.
_tdir="${TMPDIR:-/tmp}"
if ! _probe="$(mktemp -d "$_tdir/smoke-preflight.XXXXXX" 2>&1)"; then
  echo "idc smoke: BLOCKED — TMPDIR ($_tdir) is not writable." >&2
  echo "            mktemp said: $_probe" >&2
  echo "            Smoke needs a writable TMPDIR; point TMPDIR at a writable dir and retry." >&2
  exit 2
fi
rmdir "$_probe" 2>/dev/null || true
unset _tdir _probe

fails=0
n_behavior=0; n_doc=0; n_mixed=0; unclassified=""
for t in \
  phase1-smoke-path-preflight \
  phase1-tracker-fs \
  phase1-tracker-stage \
  phase1-stage-recirc-append \
  phase1-tracker-lease \
  phase1-init-doctor \
  phase1-doctor-board-lint \
  phase1-recirc-sweep \
  phase1-recirc-sweep-github \
  phase1-brownfield-scan \
  phase1-settings-json \
  phase1-lint-rules \
  phase1-codex-mirror-sync \
  phase1-git-janitor \
  phase1-janitor-preflight \
  phase2-think \
  phase3-plan \
  phase3-dag-matrix \
  phase3-provenance-gate \
  phase4-build \
  phase4-review-agent \
  phase4-triplet \
  phase4-sous-chef-ownership \
  phase4-tracker-github-recipe \
  phase4-github-pagination \
  phase4-acceptance \
  phase4-completion-honesty \
  phase4-ready-frontier \
  phase4-e2e-merge-train \
  phase4-recirc-deconflict \
  phase4-recirc-inbox-drain \
  phase4-larger-loop \
  phase4-recirc-caps \
  phase4-atomic-close \
  phase4-git-finish \
  phase4-mid-finish-recovery \
  phase4-itemid-cache \
  phase4-marker-emit \
  phase5-ripple \
  phase6-autorun \
  phase6-autorun-autonomy \
  phase6-rate-limit-detect \
  phase6-rate-limit-resume \
  phase7-lifecycle \
  phase7-update-preserves-data \
  phase7-update-template-mapping \
  phase7-update-legacy-receipt-guard \
  phase7-update-config-structure \
  phase7-update-staleness-guard \
  phase7-update-unrecorded-files \
  phase7-file-commands-noop-default \
  phase7-command-prose-invariants \
  phase7-closing-keywords \
  phase8-pi-launchable \
  phase8-pi-runtime \
  phase8-pi-fleet-secret \
  phase8-pi-fleet-failclose \
  phase8-pi-review-verdict \
  phase8-governance \
  phase8-pi-governance-gate \
  phase8-pi-guard-acl \
  phase8-pi-prompt-alignment \
  phase8-pi-finish-gate \
  phase8-pi-tracker-adapter-bridge \
  phase8-pi-review-write-tool \
  phase8-pi-model-umbrella \
  phase8-adapter-pi \
  phase8-adapter-fanout-docs \
  phase8-model-ladder \
  phase9-realgit-lifecycle \
  phase9-multiwave-accumulation \
  phase10-pause-resume \
  phase-governance; do
  # Assertion-class rollup (design §E.4 / audit RC6): tally each phase by WHAT its green proves, so
  # "all green" can never be silently over-read as end-to-end behavioral proof. The class is declared
  # co-located in each phase file as a `# idc-assert-class: <behavior|doc|mixed>` header tag:
  #   behavior — executed a real shipped helper / git / tracker and asserted on real output
  #   doc      — prose-integrity greps over the shipped playbooks an LLM later reads (proves the
  #              instructions SAY the right thing, NOT that a runtime DID it)
  #   mixed    — both real execution AND prose-integrity greps
  # A run phase with no valid tag is UNCLASSIFIED → a hard failure below (keeps the breakdown honest:
  # every phase must declare what it proves; classification is sourced from the RC6 assertion
  # inventory, docs/dev/audit-2026-07-01-idc-effectiveness.md §3).
  cls="$(sed -n '/^# idc-assert-class:/{s/^# idc-assert-class:[[:space:]]*//p;q;}' "$HERE/$t.sh")"
  case "$cls" in
    behavior) n_behavior=$((n_behavior + 1)) ;;
    doc)      n_doc=$((n_doc + 1)) ;;
    mixed)    n_mixed=$((n_mixed + 1)) ;;
    *)        unclassified="$unclassified $t" ;;
  esac
  if out="$(bash "$HERE/$t.sh" 2>&1)"; then
    echo "  PASS  $t"
  else
    echo "  FAIL  $t"
    printf '%s\n' "$out" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
done
echo "------------------------------------------------"
# Report what the green actually proved (behavior vs doc-integrity), not just a pass count.
echo "idc smoke: assertion classes — ${n_behavior:-0} behavior · ${n_mixed:-0} mixed · ${n_doc:-0} doc"
echo "           (behavior/mixed executed real helpers/git/tracker; doc = prose-integrity greps over"
echo "            the shipped playbooks — they prove the instructions SAY the right thing, not that a"
echo "            runtime DID it)"
if [ -n "${unclassified:-}" ]; then
  echo "idc smoke: UNCLASSIFIED phases (add a '# idc-assert-class: <behavior|doc|mixed>' header tag):${unclassified}"
  fails=$((fails + 1))
fi
if [ "$fails" -eq 0 ]; then
  echo "idc smoke: ALL GREEN"
  exit 0
fi
echo "idc smoke: $fails FAILED"
exit 1
