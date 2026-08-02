#!/bin/bash
# idc-assert-class: behavior
# autorun-stale-plugin-gate.sh — /idc:autorun refuses to start a drain on a stale plugin cache
# (#106 / RC7). /idc:doctor check 8 already SURFACED a stale cache, but nothing forced an update
# before an autonomous run — production transcripts showed overnight sessions re-discovering and
# ad-hoc re-patching bugs the plugin had already fixed. commands/autorun.md now carries a
# fail-closed stale-plugin gate BEFORE the orchestrator marker and every preflight: the same
# idc_plugin_freshness.py guard /idc:update Phase 0 runs, plus doctor check 8's marketplace-clone
# compare, with the exact remedy printed and an explicit operator override (--allow-stale-plugin).
# This extracts the gate's shipped bash block and runs it against version fixtures, proving the
# documented signals actually fire (stale) and stay quiet on a fresh install (no false refusal).
#
# Red-when-broken: stash the commands/autorun.md gate (pre-#106 playbook) → the extraction finds
# no idc_plugin_freshness.py block in autorun.md and this scenario FAILs.
#
# Hermetic: fixture plugin roots/receipts/HOME + the real idc_plugin_freshness.py; no GitHub.
# Usage: bash tests/smoke/governance/autorun-stale-plugin-gate.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
AUTORUN="$PLUGIN/commands/autorun.md"
FRESH="$PLUGIN/scripts/idc_plugin_freshness.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$AUTORUN" ] || fail "commands/autorun.md not found at $AUTORUN"
[ -f "$FRESH" ] || fail "idc_plugin_freshness.py not found at $FRESH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- the gate exists, and it runs BEFORE the orchestrator marker + the preflights --------------
gate_line="$(grep -n 'idc_plugin_freshness\.py' "$AUTORUN" | head -1 | cut -d: -f1)"
[ -n "$gate_line" ] \
  || fail "commands/autorun.md has no stale-plugin gate (no idc_plugin_freshness.py call) — the pre-#106 playbook"
marker_line="$(grep -n 'orchestrator_drain' "$AUTORUN" | head -1 | cut -d: -f1)"
[ -n "$marker_line" ] || fail "could not locate the orchestrator_drain marker step in autorun.md"
[ "$gate_line" -lt "$marker_line" ] \
  || fail "the stale-plugin gate (line $gate_line) must run BEFORE the orchestrator marker (line $marker_line) — a refused run must not have marked itself a drain"

# ---- the refusal prints the EXACT remedy, and the override flag is documented ------------------
grep -qF 'claude plugin update idc@idc-workflow --scope project' "$AUTORUN" \
  || fail "the refusal must print the exact scope-aware update command"
grep -qF -- '--allow-stale-plugin' "$AUTORUN" \
  || fail "the operator override flag --allow-stale-plugin must be documented"
grep -q 'REFUSE TO START THE DRAIN' "$AUTORUN" \
  || fail "the gate must state the refusal (REFUSE TO START THE DRAIN)"

# ---- extract the gate's fenced bash block (the one invoking idc_plugin_freshness.py) -----------
python3 - "$AUTORUN" > "$WORK/gate.sh" <<'PYX' || fail "could not extract the stale-plugin gate's bash block from commands/autorun.md"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = [b for b in re.findall(r"```bash\n(.*?)```", text, re.S) if "idc_plugin_freshness.py" in b]
if len(blocks) != 1:
    sys.exit("expected exactly one idc_plugin_freshness.py bash block in autorun.md, found %d" % len(blocks))
sys.stdout.write(blocks[0])
PYX
grep -q 'marketplaces/idc-workflow' "$WORK/gate.sh" \
  || fail "the gate block must also run doctor check 8's marketplace-clone compare (the installed-cache-itself-stale case)"

# ---- fixtures: a version-keyed cache with 1.0.0 running and 9.9.9 installed, a repo receipt
#      stamped 9.9.9, and a marketplace clone at 9.9.9 — the RC7 stale topology ------------------
mk_root() {  # <dir> <version> — a plugin root with a manifest + the real freshness script
  mkdir -p "$1/.claude-plugin" "$1/scripts"
  printf '{"name":"idc","version":"%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"
  cp "$FRESH" "$1/scripts/idc_plugin_freshness.py"
}
mk_root "$WORK/cache/1.0.0" 1.0.0
mk_root "$WORK/cache/9.9.9" 9.9.9
mkdir -p "$WORK/repo/docs/workflow"
printf 'receipt_version: 2\nplugin_version: 9.9.9\n' > "$WORK/repo/docs/workflow/install-receipt.yaml"
mkdir -p "$WORK/home/.claude/plugins/marketplaces/idc-workflow/.claude-plugin"
printf '{"name":"idc","version":"9.9.9"}\n' \
  > "$WORK/home/.claude/plugins/marketplaces/idc-workflow/.claude-plugin/plugin.json"

run_gate() {  # <plugin-root> — run the extracted block exactly as the playbook ships it
  ( cd "$WORK/repo" && CLAUDE_PLUGIN_ROOT="$1" HOME="$WORK/home" timeout 60 bash "$WORK/gate.sh" )
}

echo "== stale topology: running 1.0.0 behind cache/receipt/marketplace 9.9.9 → the gate's refusal signals fire =="
out="$(run_gate "$WORK/cache/1.0.0" 2>&1)" || fail "the gate block itself errored: $out"
printf '%s\n' "$out" | grep -q '"verdict": "stale"' \
  || fail "signal 1 should report verdict stale for a 1.0.0 runtime under a 9.9.9 install, got: $out"
printf '%s\n' "$out" | grep -qx 'running 1.0.0; marketplace 9.9.9' \
  || fail "signal 2 should read 'running 1.0.0; marketplace 9.9.9', got: $out"
echo "  ok both documented refusal signals fire on the RC7 topology"

echo "== fresh topology: running 9.9.9 everywhere → no false refusal =="
out2="$(run_gate "$WORK/cache/9.9.9" 2>&1)" || fail "the gate block errored on a fresh install: $out2"
printf '%s\n' "$out2" | grep -q '"verdict": "current"' \
  || fail "a current install must report verdict current, got: $out2"
printf '%s\n' "$out2" | grep -qx 'running 9.9.9; marketplace 9.9.9' \
  || fail "signal 2 should read equal versions on a fresh install, got: $out2"
echo "  ok a current install passes the gate (no false refusal)"

echo "== the helper's stale exit code is the documented 4 (the gate's machine-readable branch) =="
( cd "$WORK/repo" && timeout 60 python3 "$WORK/cache/1.0.0/scripts/idc_plugin_freshness.py" \
    --plugin-root "$WORK/cache/1.0.0" --repo "$WORK/repo" --json >/dev/null 2>&1 )
rc=$?
[ "$rc" -eq 4 ] || fail "idc_plugin_freshness.py should exit 4 on the stale topology, got $rc"
echo "  ok exit 4 = stale, exactly as the gate documents"

echo "PASS: autorun's stale-plugin gate ships before the orchestrator marker, both refusal signals fire on a stale cache and stay quiet on a fresh one, the exact update command and --allow-stale-plugin override are documented"
