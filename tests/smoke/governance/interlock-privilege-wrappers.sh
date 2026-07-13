#!/bin/bash
# interlock-privilege-wrappers.sh — sudo/doas/su cannot hide the incident interpreter FILE/payload.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN" <<'PY' || gov_fail "privilege-wrapper indirection probe failed"
import importlib.util
import os
import sys
import tempfile

plugin = sys.argv[1]
path = os.path.join(plugin, "scripts", "hooks", "idc_interlock_gate.py")
spec = importlib.util.spec_from_file_location("idc_interlock_gate_privilege", path)
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)
fixture = os.path.join(plugin, "tests", "smoke", "fixtures", "session-b7a93ff6", "fire_gate.sh")

commands = [
    "sudo bash %r" % fixture,
    "sudo -u root sh %r" % fixture,
    "doas zsh %r" % fixture,
    "doas -u root bash %r" % fixture,
    "su -c %r root" % ("bash %r" % fixture),
    "su root -c %r" % ("sh %r" % fixture),
    "su --command=%r root" % "gh issue create --title gate --body-file /tmp/body",
]
with tempfile.TemporaryDirectory() as repo:
    for command in commands:
        hit = gate.inspect_command(command, repo, plugin)
        assert hit is not None, "privilege wrapper bypassed inspection: %s" % command
        assert "fire_gate.sh" not in hit.subject or "reached indirectly" in hit.subject, hit

print("PASS: sudo/doas/su interpreter-file and payload forms are inspected or fail closed")
PY
