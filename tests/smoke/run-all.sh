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
for t in \
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
  phase2-think \
  phase3-plan \
  phase3-dag-matrix \
  phase4-build \
  phase4-review-agent \
  phase4-triplet \
  phase4-sous-chef-ownership \
  phase4-tracker-github-recipe \
  phase4-github-pagination \
  phase4-acceptance \
  phase4-ready-frontier \
  phase4-e2e-merge-train \
  phase4-recirc-deconflict \
  phase4-recirc-inbox-drain \
  phase4-larger-loop \
  phase4-recirc-caps \
  phase5-ripple \
  phase6-autorun \
  phase6-autorun-autonomy \
  phase7-lifecycle \
  phase7-update-preserves-data \
  phase7-update-template-mapping \
  phase7-update-legacy-receipt-guard \
  phase7-update-config-structure \
  phase7-update-staleness-guard \
  phase7-file-commands-noop-default \
  phase7-command-prose-invariants \
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
  phase8-adapter-pi \
  phase8-adapter-fanout-docs; do
  if out="$(bash "$HERE/$t.sh" 2>&1)"; then
    echo "  PASS  $t"
  else
    echo "  FAIL  $t"
    printf '%s\n' "$out" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
done
echo "------------------------------------------------"
if [ "$fails" -eq 0 ]; then
  echo "idc smoke: ALL GREEN"
  exit 0
fi
echo "idc smoke: $fails FAILED"
exit 1
