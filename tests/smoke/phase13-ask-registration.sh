#!/usr/bin/env bash
# phase13-ask-registration.sh — `ask` is a registered, READ-ONLY 14th command.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. contract registry
python3 - "$REPO_ROOT" <<'PY' || fail "ask missing from COMMANDS"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_command_contract as C
assert "ask" in C.COMMANDS, C.COMMANDS
PY

# 2. path gate read-only ceiling is EMPTY
python3 - "$REPO_ROOT" <<'PY' || fail "ask is not read-only in the Path Gate"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_path_gate as PG
assert "ask" in PG.READ_ONLY_COMMANDS, PG.READ_ONLY_COMMANDS
assert PG._role_action_ceiling("ask") == set(), PG._role_action_ceiling("ask")
paths, actions = PG._default_profile("ask")
assert actions == [], actions
PY

# 3. the UserPromptExpansion matcher admits idc:ask
python3 - "$REPO_ROOT" <<'PY' || fail "hooks.json matcher does not admit idc:ask"
import json, re, sys, os
with open(os.path.join(sys.argv[1], "hooks", "hooks.json")) as fh:
    manifest = json.load(fh)
matchers = [h["matcher"] for h in manifest["hooks"]["UserPromptExpansion"]]
assert any(re.match(m, "idc:ask") for m in matchers), matchers
PY

# 4. ask is NOT auth-required (no Path Gate mint for the advisory path)
python3 - "$REPO_ROOT" <<'PY' || fail "ask must not be in AUTH_REQUIRED_COMMANDS"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "hooks"))
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_command_entry_gate as G
assert "ask" not in G.AUTH_REQUIRED_COMMANDS, sorted(G.AUTH_REQUIRED_COMMANDS)
assert "ask" in G.BASELINE_ALLOWED_COMMANDS, sorted(G.BASELINE_ALLOWED_COMMANDS)
PY

echo "PASS: phase13-ask-registration"
