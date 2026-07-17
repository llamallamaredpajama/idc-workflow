#!/bin/bash
# engine-machine-table.sh — governance scenario: the machine-table loader is honest.
#
# The gaps this closes (PR #133 review MINOR-5 + MINOR-6):
#   (A) the stdlib fallback parser REJECTS unsupported YAML shapes LOUDLY (block-style `- item`
#       lists, keyless lines) instead of silently misparsing them into a deny-everything dict — the
#       table is operator-visible + hand-editable, so a bad edit must fail with a clear message.
#   (B) load-time validate_machine CROSS-CHECKS the table's Status/Stage domains against the
#       idc_tracker_fs backend enums and REFUSES on drift (the header comment's promise, made real).
#   (C) the shipped table parses IDENTICALLY under PyYAML and the stdlib fallback (when PyYAML is
#       installed) — so users on either path get the same machine.
#
# Red-when-broken: remove the loud-reject in _mini_yaml → (A) block-list parse no longer raises →
# FAIL. Neuter validate_machine → (B) drift no longer raises → FAIL.
#
# Usage: bash tests/smoke/governance/engine-machine-table.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
[ -f "$ENGINE" ] || fail "transition engine not found at $ENGINE"

python3 - "$GOV_PLUGIN/scripts" "$GOV_PLUGIN/templates/workflow-machine.yaml" <<'PY' || fail "machine-table assertions failed (see above)"
import sys
scripts, shipped = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_transition as E

# ── (A) loud rejection of unsupported shapes ──
BLOCK_LIST = "stages:\n  - Consideration\n  - Buildable\n"
try:
    E._mini_yaml(BLOCK_LIST)
    print("FAIL: _mini_yaml silently parsed a block-style '- item' list (should reject loudly)"); sys.exit(1)
except E.TransitionError as e:
    assert "block-style" in str(e), f"reject message unclear: {e}"
KEYLESS = "statuses\n"
try:
    E._mini_yaml(KEYLESS)
    print("FAIL: _mini_yaml silently accepted a keyless line"); sys.exit(1)
except E.TransitionError:
    pass
print("  ok (A) stdlib parser rejects block-style lists + keyless lines LOUDLY")

# ── (B) backend cross-check refuses drift ──
import idc_tracker_fs as FS
good = {"statuses": list(FS.STATUSES), "stages": list(FS.STAGES), "ops": {}}
E.validate_machine(good, "test")  # in lockstep → no raise
for bad in ({"statuses": ["Blocked", "Todo"], "stages": list(FS.STAGES), "ops": {}},           # missing statuses
            {"statuses": list(FS.STATUSES), "stages": list(FS.STAGES) + ["Xtra"], "ops": {}}):  # extra stage
    try:
        E.validate_machine(bad, "test")
        print(f"FAIL: validate_machine accepted a drifted table: {bad}"); sys.exit(1)
    except E.TransitionError:
        pass
print("  ok (B) validate_machine refuses a Status/Stage drift from the backend enums")

# ── (C) the SHIPPED table loads + has the full op set + the worked-state invariant ──
m = E.load_machine(shipped)  # load_machine runs validate_machine internally
expected_ops = {"create-ticket","create-pointer","recirculate-intake","claim","move","set-field","unblock","close","dispose","link"}
assert set(m["ops"]) == expected_ops, f"shipped ops {set(m['ops'])} != {expected_ops}"
# The `dispose` terminal op carries a per-disposition guard table (the #150 non-verdict doors);
# each disposition declares exactly one deterministic evidence guard.
disp = m["ops"]["dispose"].get("dispositions") or {}
assert set(disp) == {"gate-approved","retired","drained"}, f"dispose dispositions drift: {set(disp)}"
for name, entry in disp.items():
    assert entry.get("guards"), f"dispose disposition {name!r} must declare a non-empty guard list (fail-closed otherwise)"
assert m.get("worked_status") == "In Progress", "shipped table lost worked_status"
assert set(m.get("worked_forbidden_stages") or []) == {"Recirculation","Consideration"}, "worked_forbidden_stages drift"
print("  ok (C1) the shipped table loads with the full 10-op set (dispose w/ 3 guarded dispositions) + the worked-state invariant")

# ── (C2) PyYAML / fallback PARITY on the shipped table (skipped if PyYAML absent) ──
try:
    import yaml
except ImportError:
    print("  ok (C2) PyYAML absent — parity check skipped (stdlib fallback is the only path here)")
    sys.exit(0)
text = open(shipped, encoding="utf-8").read()
py = yaml.safe_load(text)
mini = E._mini_yaml(text)
def project(d):  # the engine-relevant subset (version's int/str type is irrelevant + excluded)
    return {"statuses": d.get("statuses"), "stages": d.get("stages"),
            "worked_status": d.get("worked_status"),
            "worked_forbidden_stages": d.get("worked_forbidden_stages"),
            "terminal_status": d.get("terminal_status"), "ops": d.get("ops")}
assert project(py) == project(mini), "PyYAML and the stdlib fallback DISAGREE on the shipped table"
print("  ok (C2) PyYAML and the stdlib fallback parse the shipped table identically")
PY

echo "PASS: machine-table loader is honest — loud rejection of unsupported shapes, backend cross-check refuses drift, and PyYAML/fallback parse the shipped table identically"
