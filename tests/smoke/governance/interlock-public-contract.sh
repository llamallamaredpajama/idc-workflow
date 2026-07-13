#!/bin/bash
# interlock-public-contract.sh — Task 3 public classifier + exact Finding contract.
#
# This imports the shipped hook module directly. It pins the callable promised by the canonical plan,
# rather than only exercising the private gate path: classify(command, cwd, plugin_root, active).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN" <<'PY' || gov_fail "interlock public-contract probe failed"
import dataclasses
import importlib.util
import inspect
import os
import sys
import tempfile

plugin = sys.argv[1]
gate_path = os.path.join(plugin, "scripts", "hooks", "idc_interlock_gate.py")
spec = importlib.util.spec_from_file_location("idc_interlock_gate_contract", gate_path)
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)

params = list(inspect.signature(gate.classify).parameters)
assert params == ["command", "cwd", "plugin_root", "active"], \
    f"public classify signature drifted: {params}"
assert [f.name for f in dataclasses.fields(gate.Finding)] == ["subject", "remediation", "source"], \
    f"Finding must expose exactly subject/remediation/source: {dataclasses.fields(gate.Finding)}"

with tempfile.TemporaryDirectory() as repo:
    hit = gate.classify("gh issue create --title x --body x", repo, plugin, True)
    assert isinstance(hit, gate.Finding), f"protected write returned {hit!r}"
    assert hit.source == "direct", hit

    fixture = os.path.join(plugin, "tests", "smoke", "fixtures", "session-b7a93ff6", "fire_gate.sh")
    indirect = gate.classify("bash %r" % fixture, repo, plugin, True)
    assert isinstance(indirect, gate.Finding), f"indirect write returned {indirect!r}"
    assert indirect.source == "script-indirection", indirect

    assert gate.classify("gh issue view 5", repo, plugin, True) is None

print("PASS: classify(command, cwd, plugin_root, active) and exact three-field Finding are public and indirection-aware")
PY
