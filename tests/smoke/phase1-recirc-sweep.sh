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

# plugin.json: valid JSON, and it must NOT re-declare the auto-discovered standard hooks file.
# Claude Code auto-loads a plugin's standard-path hooks/hooks.json; a manifest `hooks` reference to
# that same file makes the loader abort with "Duplicate hooks file detected" (the 3.1.0 → 3.1.1
# plugin-load fix). The SessionEnd hook still ships at the standard path and loads via auto-discovery.
[ -f "$PLUGIN_JSON" ] || fail ".claude-plugin/plugin.json missing"
python3 - "$PLUGIN_JSON" "$PLUGIN" <<'PY' || fail "plugin.json must NOT declare a hooks key pointing at the auto-discovered hooks/hooks.json"
import json, os, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
hooks = cfg.get("hooks")
# manifest.hooks is only for ADDITIONAL hook files at non-standard paths; the standard
# hooks/hooks.json is auto-discovered, so referencing it here is the duplicate-load bug.
norm = (hooks or "").lstrip("./")
assert norm != "hooks/hooks.json", (
    f"plugin.json declares hooks={hooks!r} pointing at the auto-discovered standard file; "
    "remove the key (manifest.hooks is only for additional non-standard hook files)"
)
# the SessionEnd hook still ships at the auto-discovered standard path
assert os.path.isfile(os.path.join(sys.argv[2], "hooks", "hooks.json")), "hooks.json target missing"
PY

# ── 4. e2e-caught regressions: project_number inline-comment parse + degraded-≠-clean ────────────
# (4a) read_config must STRIP an inline `# comment` on project_number — the template ships
#      `project_number: 10  # integer; from gh project create`. Red-when-broken: the pre-fix regex
#      returns "10  # integer…", gh rejects it as an invalid number, and the WHOLE github sweep
#      silently no-ops (this is the defect the sandbox e2e caught).
pn="$(python3 - "$SCRIPTS" <<'PY'
import sys, os, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
d = tempfile.mkdtemp()
os.makedirs(os.path.join(d, "docs", "workflow"))
open(os.path.join(d, "docs", "workflow", "tracker-config.yaml"), "w").write(
    'backend: github\nproject_number: 10     # integer; from `gh project create`\n'
    'field_ids:\n  Stage: "PVTF_x"\n')
pn, _ = m.read_config(d)
print(pn)
PY
)"
[ "$pn" = "10" ] \
  || fail "read_config must strip the inline comment on project_number (got '$pn', want '10') — else gh rejects it and the github sweep silently no-ops"

# (4b) a github board that cannot be scanned must report a DEGRADED SKIP (exit 2), never a hollow
#      'clean (0 scanned)' all-clear (the 3.0.5 no-silent-all-clear discipline). A temp dir is not a
#      github repo, so gh cannot resolve the owner ⇒ the scan is degraded, not empty.
REPO4="$WORK/repo4"; mkdir -p "$REPO4/docs/workflow/pillar-matrices"
cat > "$REPO4/docs/workflow/tracker-config.yaml" <<'YAML'
backend: github
project_number: 10     # integer; from `gh project create`
field_ids:
  Stage: "PVTF_x"
YAML
cat > "$REPO4/docs/workflow/pillar-matrices/m.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: p1
    wave: 1
    domain: x
    surfaces: [a/]
YAML
out4="$(python3 "$SWEEP" --repo "$REPO4" --report 2>&1)"; code4=$?
echo "$out4" | grep -qiE 'could not scan|SKIP' \
  || fail "an unscannable github board must SURFACE a degraded SKIP, not a hollow all-clear (got: '$out4')"
if echo "$out4" | grep -qiE 'clean \(0'; then
  fail "a degraded (unscannable) github board must NOT report a hollow 'clean (0 scanned)' all-clear"
fi
[ "$code4" = "2" ] \
  || fail "a degraded github --report must exit 2 (→ doctor Row 9b SKIP), not 0 (got exit $code4)"

# ── 5. dropped larger-loop handoff: an admitted Consideration with no decomposition is SURFACE-only ─
# Plan advances a consideration pointer (Consideration -> Planning, retired as buildables land). An
# admitted consideration still at Stage=Consideration/Status=Todo with NO decomposition — no
# Stage=Buildable child issue and no in-flight Stage=Planning pointer — is a DROPPED larger-loop
# handoff (Plan never ran on it). The sweep SURFACES it (advisory, defense-in-depth) and NEVER mutates
# it. The pure brain (dropped_handoff_numbers) is exercised directly; the filesystem --report
# integration proves the surface + the no-mutation guarantee. Every case is red-when-broken.

# dropped <items-json> -> space-joined surfaced consideration numbers ("" if none)
dropped() {
python3 - "$SCRIPTS" "$1" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
print(" ".join(str(n) for n in m.dropped_handoff_numbers(json.loads(sys.argv[2]))))
PY
}

# (a) a lone admitted Consideration/Todo -> surfaced (its number). Contrasts (b)/(c) add decomposition
#     activity and must flip it to NOT surfaced.
[ "$(dropped '[{"number":5,"stage":"Consideration","status":"Todo"}]')" = "5" ] \
  || fail "dropped-handoff: an admitted Consideration/Todo with no decomposition must be surfaced"
# (b) red-when-broken: a child Buildable means decomposition is active -> NOT surfaced.
[ "$(dropped '[{"number":5,"stage":"Consideration","status":"Todo"},{"number":6,"stage":"Buildable","status":"Todo"}]')" = "" ] \
  || fail "a Consideration WITH a child Buildable (decomposition active) must NOT be surfaced (red-when-broken)"
# (c) red-when-broken: an in-flight Planning pointer also means decomposition started -> NOT surfaced.
[ "$(dropped '[{"number":5,"stage":"Consideration","status":"Todo"},{"number":7,"stage":"Planning","status":"Todo"}]')" = "" ] \
  || fail "a Consideration WITH an in-flight Planning pointer must NOT be surfaced (in-flight plan)"
# (d) a non-Todo (e.g. already-retired) Consideration is not an admitted-but-dropped handoff.
[ "$(dropped '[{"number":5,"stage":"Consideration","status":"Done"}]')" = "" ] \
  || fail "a non-Todo Consideration must NOT be surfaced (only admitted/Todo considerations)"

# filesystem --report integration: a real Consideration/Todo board with NO buildables surfaces the
# dropped handoff (and a matrix need NOT exist — Plan, which writes the matrix, never ran), and the
# surface is read-only: neither --report nor --auto-correct mutates the consideration.
REPO5="$WORK/repo5"; mkdir -p "$REPO5/docs/workflow/pillar-matrices"; T5="$REPO5/TRACKER.md"
cat > "$REPO5/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
YAML
python3 "$TRK" --tracker "$T5" init >/dev/null || fail "repo5 tracker init failed"
cons="$(python3 "$TRK" --tracker "$T5" create --title 'admitted consideration' --stage Consideration)" \
  || fail "create consideration failed"
out5="$(python3 "$SWEEP" --repo "$REPO5" --report 2>&1)"
echo "$out5" | grep -qE "^#$cons: dropped larger-loop handoff" \
  || fail "an admitted Consideration with no decomposition must surface '#$cons: dropped larger-loop handoff' in --report (got: $out5)"
# SURFACE-only: --report mutates nothing.
[ "$(python3 "$TRK" --tracker "$T5" show --num "$cons" --field Stage)" = "Consideration" ] \
  || fail "dropped-handoff is SURFACE-only: --report must not mutate the consideration's Stage"
# defense-in-depth: --auto-correct never auto-mutates a consideration either.
python3 "$SWEEP" --repo "$REPO5" --auto-correct || fail "auto-correct must be fail-soft (exit 0)"
[ "$(python3 "$TRK" --tracker "$T5" show --num "$cons" --field Stage)" = "Consideration" ] \
  || fail "dropped-handoff is never auto-mutated: --auto-correct must leave the consideration at Consideration"

# control: add a child Buildable -> decomposition active -> the surface disappears (red-when-broken).
python3 "$TRK" --tracker "$T5" create --title 'child buildable' --stage Buildable >/dev/null \
  || fail "create child buildable failed"
out5b="$(python3 "$SWEEP" --repo "$REPO5" --report 2>&1)"
echo "$out5b" | grep -qiE 'dropped larger-loop handoff' \
  && fail "a Consideration WITH a child Buildable must NOT surface a dropped handoff (red-when-broken control)"

echo "PASS: decide() classifies all cases (red-when-broken) + filesystem re-stage/Wave-clear/idempotency + no-matrix skip + hook wiring resolves + project_number comment-strip + degraded-github-scan surfaces (not a hollow clean) + dropped larger-loop handoff surfaced (Consideration, surface-only)"
