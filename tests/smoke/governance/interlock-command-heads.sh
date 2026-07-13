#!/bin/bash
# interlock-command-heads.sh — command substitutions execute, quoted/argument text does not.
#
# The interlock must inspect two different execution surfaces independently:
#   * real command substitutions, whose inner commands execute before the outer command; and
#   * the outer segment's actual executable head after assignments/wrappers are peeled.
# A bare `gh` word in an ordinary argument is data, not a command head. These six probes pin both
# sides of that boundary through the public classifier used by the PreToolUse gate.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/../../.." && pwd)"
GATE="$PLUGIN/scripts/hooks/idc_interlock_gate.py"
[ -f "$GATE" ] || { echo "FAIL: interlock gate missing at $GATE"; exit 1; }

python3 - "$GATE" "$PLUGIN" <<'PY'
import importlib.util
import sys

gate_path, plugin_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_interlock_gate_command_heads_test", gate_path)
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)

must_deny = (
    "OWNER=$(gh repo view ...) gh issue create --title x --body x",
    "TITLE=$(gh issue view ...) gh project item-delete 8 --owner o --id X",
)
must_allow = (
    "echo 'gh issue create --title example'",
    "git commit -m 'docs: explain gh issue create'",
    "printf '%s\\n' gh issue create",
    "grep -F gh issue create README.md",
)

failures = []
for command in must_deny:
    if gate.classify(command, plugin_root, plugin_root, True) is None:
        failures.append("outer mutation escaped: " + command)
for command in must_allow:
    finding = gate.classify(command, plugin_root, plugin_root, True)
    if finding is not None:
        failures.append("benign argument text was classified: {} => {}".format(command, finding.subject))

if failures:
    for failure in failures:
        print("FAIL: " + failure)
    raise SystemExit(1)

print("PASS: command substitutions and the outer executable head are classified separately; argument text stays inert")
PY
