#!/bin/bash
# Phase 7 (command prose invariants) smoke — testing-suite-overhaul.
#
# A cheap backstop for the prose that REMAINS in the file-changing command markdown after decisions
# were pushed into helpers. These grep-style invariants lock the must-hold instructions an executing
# agent reads, so a future edit can't silently reintroduce a destructive default (e.g. the 2.1.3
# keep/replace-for-data-configs footgun). No LLM, no cost; runs every PR. Hermetic.
#
# Usage: bash tests/smoke/phase7-command-prose-invariants.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
C="$PLUGIN/commands"
fail() { echo "FAIL: $1"; exit 1; }
has()  { grep -qiE "$2" "$1"; }   # file, regex

# --- update.md: data configs are preserved, never destructively replaced ------------------------
U="$C/update.md"
[ -f "$U" ] || fail "commands/update.md missing"
has "$U" 'never overwrite[s]? a data-bearing config' \
  || fail "update.md must state it never overwrites a data-bearing config"
has "$U" 'never.*offer.*destructive keep/replace|never offers a destructive keep/replace' \
  || fail "update.md must state it never offers a destructive keep/replace for data configs"
has "$U" 'idc_config_keys\.py' \
  || fail "update.md must resolve data-config structure via the idc_config_keys.py helper (not prose judgment)"
has "$U" 'idc_template_for\.py' \
  || fail "update.md must resolve templates via the shared idc_template_for.py resolver"
has "$U" 'idc_plugin_freshness\.py' \
  || fail "update.md must run the stale-session freshness guard"
# It must NOT tell the agent to overwrite/replace a data-bearing config.
grep -iE 'overwrite .*(WORKFLOW-config|tracker-config)|replace .*(WORKFLOW-config|tracker-config) with' "$U" \
  && fail "update.md appears to instruct overwriting/replacing a data config — the 2.1.3 footgun" || true

# --- init.md: the two data configs are stamped --customized (so update/uninstall protect them) ---
I="$C/init.md"
[ -f "$I" ] || fail "commands/init.md missing"
has "$I" 'customized .*WORKFLOW-config\.yaml|--customized WORKFLOW-config\.yaml' \
  || fail "init.md must stamp WORKFLOW-config.yaml --customized"
has "$I" 'customized .*tracker-config\.yaml|--customized docs/workflow/tracker-config\.yaml' \
  || fail "init.md must stamp docs/workflow/tracker-config.yaml --customized"

# --- uninstall.md: deletion is receipt-driven (only delete what IDC created) --------------------
UN="$C/uninstall.md"
[ -f "$UN" ] || fail "commands/uninstall.md missing"
has "$UN" 'receipt' || fail "uninstall.md must drive removal from the install receipt"
has "$UN" 'only delete what IDC' \
  || fail "uninstall.md must state it only deletes what IDC created"

# --- doctor.md: read-only (it must never mutate the repo or board) ------------------------------
D="$C/doctor.md"
[ -f "$D" ] || fail "commands/doctor.md missing"
has "$D" 'read-only' || fail "doctor.md must declare itself read-only"

echo "PASS: file-changing command markdown holds its must-never/must-say invariants"
