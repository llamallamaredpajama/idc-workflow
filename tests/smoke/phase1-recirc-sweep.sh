#!/bin/bash
# Phase 1 smoke — the recirculation-intake safety net (scripts/idc_recirc_sweep.py) + its SessionEnd
# hook wiring. Hermetic: the pure decide() brain is exercised directly, the re-stage mutation against
# a throwaway filesystem tracker. NO live GitHub (the github write path is validated in the sandbox
# e2e). The SessionEnd hook (idc_recirc_sweep_hook.sh) re-stages rogue Buildables — issues that
# bypassed Plan and so carry no idc-provenance marker — into Recirculation, and captures untickered
# discovery/deferral markers.
#
# Red-when-broken throughout (per "tests aren't trusted until red-when-broken"): every decide() case
# is pinned by a CONTRAST input that would flip the assertion RED if its guard regressed, and the
# filesystem re-stage is paired with an unmarked-issue control that must stay untouched.
#
# Usage: bash tests/smoke/phase1-recirc-sweep.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
SWEEP="$SCRIPTS/idc_recirc_sweep.py"
HOOK="$SCRIPTS/idc_recirc_sweep_hook.sh"
TRK="$SCRIPTS/idc_tracker_fs.py"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
PLUGIN_JSON="$PLUGIN/.claude-plugin/plugin.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SWEEP" ] || fail "recirc-sweep helper not found at $SWEEP (not implemented yet)"
[ -f "$HOOK" ]  || fail "recirc-sweep hook wrapper not found at $HOOK"

# dec <matrices-json|none> <regime 0|1> <provenance-json|none> <has_discovery 0|1> -> prints the action
dec() {
python3 - "$SCRIPTS" "$1" "$2" "$3" "$4" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
matrices = None if sys.argv[2] == "none" else {k: set(v) for k, v in json.loads(sys.argv[2]).items()}
regime = sys.argv[3] == "1"
prov = None if sys.argv[4] == "none" else json.loads(sys.argv[4])
has_disc = sys.argv[5] == "1"
print(m.decide({"number": 1, "provenance": prov, "has_discovery": has_disc}, matrices, regime))
PY
}
M='{"p1-matrix.yaml":["p1","p2"]}'   # a matrix present, ids p1/p2 (provenance regime can be active)

# ── 1. pure decide() — ALL cases, each red-when-broken via a contrast input ─────────────────────

# (a) catch-rogue: a discovery/deferral-marked Buildable with NO valid provenance is a rogue and is
#     re-staged EVEN with the regime inactive (the marker is unambiguous). Contrast (b) drops the
#     marker → the same inputs must NOT re-stage, so this pins the discovery-marker guard.
[ "$(dec "$M" 0 none 1)" = "restage" ] \
  || fail "catch-rogue: discovery-marked unprovenanced Buildable must re-stage even with regime inactive"
# (b) red-when-broken control for (a): SAME (regime inactive, no provenance) but UNMARKED → surface,
#     never restage. If the discovery-marker branch regressed to always-restage, (a) would still pass
#     but this flips RED; if it regressed to never-restage, (a) flips RED. The pair pins the branch.
[ "$(dec "$M" 0 none 0)" = "surface" ] \
  || fail "no-flag-ambiguous: unmarked, unprovenanced, regime-inactive Buildable must SURFACE only (not mutate)"

# (c) no-flag-ambiguous when regime ACTIVE: an unmarked, unprovenanced Buildable IS a rogue once the
#     provenance regime is established (≥1 valid provenance on the board). Contrast with (b) — same
#     issue, regime flipped — pins the regime gate as load-bearing (the legacy-board safety valve).
[ "$(dec "$M" 1 none 0)" = "restage" ] \
  || fail "regime-active: unmarked, unprovenanced Buildable must re-stage once the regime is active"

# (d) no-flag-no-matrix: with NO matrix yaml present, the provenance check is skipped entirely — a
#     legacy board is never touched, regardless of regime/markers. Contrast: regime active + marked,
#     yet matrices=None still yields skip-no-matrix (the outermost gate).
[ "$(dec none 1 none 1)" = "skip-no-matrix" ] \
  || fail "no-flag-no-matrix: matrices=None must skip the provenance check entirely (legacy board untouched)"
[ "$(dec "$M" 1 none 1)" = "restage" ] \
  || fail "no-flag-no-matrix control: with a matrix present the same marked+regime inputs must NOT skip"

# (e) leave-valid-provenance: a Buildable whose stamped pillar is in the NAMED matrix's id set is
#     planned → LEAVE. Contrast: an INVALID pillar (not in the set) is no provenance → restage. The
#     pair pins provenance_is_valid (strict to the named matrix's id set).
[ "$(dec "$M" 1 '{"matrix":"p1-matrix.yaml","pillar":"p1"}' 0)" = "leave" ] \
  || fail "leave-valid-provenance: a stamped pillar in the named matrix's id set must be LEFT ALONE"
[ "$(dec "$M" 1 '{"matrix":"p1-matrix.yaml","pillar":"NOPE"}' 0)" = "restage" ] \
  || fail "leave-valid-provenance control: a pillar absent from the named matrix must NOT validate (rogue)"
# strict-to-named-matrix: a pillar id that exists in a DIFFERENT matrix file must not validate.
[ "$(dec "$M" 1 '{"matrix":"other-matrix.yaml","pillar":"p1"}' 0)" = "restage" ] \
  || fail "provenance validity must be strict to the NAMED matrix (p1 in p1-matrix.yaml ≠ other-matrix.yaml)"

# ── 2. filesystem mechanical: re-stage rogue Buildable → Recirculation + clear Wave + idempotency ──
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow/pillar-matrices"
T="$REPO/TRACKER.md"
run_trk() { python3 "$TRK" --tracker "$T" "$@"; }
# filesystem backend + a matrix present (so the provenance regime is in play; matrices != None).
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
YAML
cat > "$REPO/docs/workflow/pillar-matrices/p1-matrix.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: p1
    wave: 1
    domain: x
    surfaces: [a/]
YAML
run_trk init >/dev/null || fail "tracker init failed"
# A rogue Buildable: Stage=Buildable, Status=Todo, carries a discovery marker (in a comment, where
# the finisher lands it on filesystem) + a Wave to be cleared.
rogue="$(run_trk create --title 'rogue buildable' --stage Buildable --wave 'Wave 2')" \
  || fail "create rogue failed"
run_trk comment --num "$rogue" \
  --body '<!-- idc-discovery: {"what":"shared limiter","area":"src/api","suggested_scope":"extract limiter","origin":"#9|finisher"} -->' \
  >/dev/null || fail "comment (discovery marker) failed"
# A clean control: Stage=Buildable, Status=Todo, NO marker, Wave set. With the regime inactive on a
# filesystem board (no provenance markers exist there), this must be SURFACED, never re-staged.
clean="$(run_trk create --title 'clean buildable' --stage Buildable --wave 'Wave 2')" \
  || fail "create clean failed"

python3 "$SWEEP" --repo "$REPO" --auto-correct || fail "auto-correct exited non-zero (must be fail-soft, exit 0)"

[ "$(run_trk show --num "$rogue" --field Stage)" = "Recirculation" ] \
  || fail "rogue Buildable must be re-staged to Recirculation (got '$(run_trk show --num "$rogue" --field Stage)')"
[ "$(run_trk show --num "$rogue" --field Wave)" = "" ] \
  || fail "re-staged rogue must have its Wave CLEARED (got '$(run_trk show --num "$rogue" --field Wave)')"
# red-when-broken control: the unmarked clean Buildable must be UNTOUCHED (regime inactive). If the
# re-stage over-fired (re-staged every Buildable), this flips RED.
[ "$(run_trk show --num "$clean" --field Stage)" = "Buildable" ] \
  || fail "an unmarked Buildable must NOT be re-staged on a regime-inactive filesystem board (over-fire)"
[ "$(run_trk show --num "$clean" --field Wave)" = "Wave 2" ] \
  || fail "an unmarked Buildable's Wave must be preserved (got '$(run_trk show --num "$clean" --field Wave)')"

# idempotent re-run: re-staging again changes nothing, and creates no duplicate issues.
before_count="$(python3 - "$T" <<'PY'
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"begin -->\s*```json\s*(.*?)\s*```\s*<!-- idc-tracker-state:end", t, re.S)
print(len(json.loads(m.group(1))["issues"]))
PY
)"
python3 "$SWEEP" --repo "$REPO" --auto-correct || fail "idempotent re-run exited non-zero"
[ "$(run_trk show --num "$rogue" --field Stage)" = "Recirculation" ] \
  || fail "idempotent re-run must leave the rogue at Recirculation"
after_count="$(python3 - "$T" <<'PY'
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"begin -->\s*```json\s*(.*?)\s*```\s*<!-- idc-tracker-state:end", t, re.S)
print(len(json.loads(m.group(1))["issues"]))
PY
)"
[ "$before_count" = "$after_count" ] \
  || fail "idempotent re-run must not create duplicate issues (issues $before_count -> $after_count)"

# --report mode is read-only + exits 0, and must NOT have mutated anything above (already asserted).
python3 "$SWEEP" --repo "$REPO" --report >/dev/null || fail "--report must exit 0 (read-only)"

# no-matrix skip (mechanical): remove the matrix yaml → a fresh rogue is NOT re-staged (skip-no-matrix).
REPO2="$WORK/repo2"; mkdir -p "$REPO2/docs/workflow/pillar-matrices"; T2="$REPO2/TRACKER.md"
cat > "$REPO2/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
YAML
python3 "$TRK" --tracker "$T2" init >/dev/null
r2="$(python3 "$TRK" --tracker "$T2" create --title 'rogue, no matrix' --stage Buildable --wave 'Wave 1')"
python3 "$TRK" --tracker "$T2" comment --num "$r2" \
  --body '<!-- idc-discovery: {"what":"x","area":"y","suggested_scope":"z","origin":"#1"} -->' >/dev/null
python3 "$SWEEP" --repo "$REPO2" --auto-correct || fail "no-matrix auto-correct must be fail-soft"
[ "$(python3 "$TRK" --tracker "$T2" show --num "$r2" --field Stage)" = "Buildable" ] \
  || fail "with NO pillar matrix the sweep must SKIP entirely — a rogue must stay Buildable (legacy untouched)"

# fail-soft outside an IDC repo: no tracker-config.yaml → exit 0, no error.
REPO3="$WORK/repo3"; mkdir -p "$REPO3"
python3 "$SWEEP" --repo "$REPO3" --auto-correct || fail "auto-correct in a non-IDC repo must exit 0 (fail-soft)"

# ── 3. hook wiring is structurally sound (lint does NOT scan hooks/ or .claude-plugin/) ──────────
[ -x "$HOOK" ] || fail "hook wrapper $HOOK must be executable"
grep -q 'idc_recirc_sweep.py' "$HOOK" \
  || fail "hook wrapper must invoke idc_recirc_sweep.py"
grep -q 'tracker-config.yaml' "$HOOK" \
  || fail "hook wrapper must early-exit when docs/workflow/tracker-config.yaml is absent (not an IDC repo)"

# hooks.json: valid JSON, registers a SessionEnd command hook that names the wrapper, and the command
# path resolves to the real wrapper file under the plugin root.
[ -f "$HOOKS_JSON" ] || fail "hooks/hooks.json missing"
python3 - "$HOOKS_JSON" "$PLUGIN" <<'PY' || fail "hooks/hooks.json is malformed or does not register the SessionEnd wrapper"
import json, os, re, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
se = cfg.get("hooks", {}).get("SessionEnd")
assert isinstance(se, list) and se, "no SessionEnd hook group"
cmds = [h.get("command", "") for g in se for h in g.get("hooks", []) if h.get("type") == "command"]
assert any("idc_recirc_sweep_hook.sh" in c for c in cmds), "SessionEnd does not call the wrapper"
# the ${CLAUDE_PLUGIN_ROOT}-relative command path must resolve to the real wrapper
for c in cmds:
    for tok in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9._/-]+\.sh)", c):
        assert os.path.isfile(os.path.join(root, tok)), f"hook command path {tok} does not resolve"
PY

# plugin.json: valid JSON, declares the hooks key pointing at ./hooks/hooks.json, and that file exists.
[ -f "$PLUGIN_JSON" ] || fail ".claude-plugin/plugin.json missing"
python3 - "$PLUGIN_JSON" "$PLUGIN" <<'PY' || fail "plugin.json must declare \"hooks\": \"./hooks/hooks.json\" resolving to a real file"
import json, os, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
hooks = cfg.get("hooks")
assert hooks == "./hooks/hooks.json", f"plugin.json hooks key is {hooks!r} (want ./hooks/hooks.json)"
assert os.path.isfile(os.path.join(sys.argv[2], "hooks", "hooks.json")), "hooks.json target missing"
PY

echo "PASS: decide() classifies all cases (red-when-broken) + filesystem re-stage/Wave-clear/idempotency + no-matrix skip + hook wiring resolves"
