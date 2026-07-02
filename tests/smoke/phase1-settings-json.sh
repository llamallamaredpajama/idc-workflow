#!/bin/bash
# idc-assert-class: behavior
# Phase 1 smoke — project settings mutation preserves operator-owned keys and never
# truncates invalid JSON. REAL functional test of the shipped settings helper used by
# /idc:init for .claude/settings.json. Failing-test-first: fails until
# scripts/idc_settings_json.py exists.
#
# Usage: bash tests/smoke/phase1-settings-json.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_settings_json.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "settings helper not found at $HELPER (not implemented yet)"

settings="$WORK/settings.json"
cat > "$settings" <<'JSON'
{
  "theme": "dark",
  "permissions": {"allow": ["Bash(git status:*)"]},
  "enabledPlugins": {"other@plugin": false}
}
JSON

python3 "$HELPER" enable "$settings" "idc@idc-workflow" >/dev/null \
  || fail "enable should succeed on an existing settings object"
python3 - "$settings" <<'PY' || fail "enable did not preserve non-IDC settings"
import json, sys
p = sys.argv[1]
d = json.load(open(p))
assert d["theme"] == "dark"
assert d["permissions"] == {"allow": ["Bash(git status:*)"]}
assert d["enabledPlugins"]["other@plugin"] is False
assert d["enabledPlugins"]["idc@idc-workflow"] is True
PY

python3 "$HELPER" disable "$settings" "idc@idc-workflow" >/dev/null \
  || fail "disable should succeed on an existing settings object"
python3 - "$settings" <<'PY' || fail "disable did not preserve non-IDC settings"
import json, sys
p = sys.argv[1]
d = json.load(open(p))
assert d["theme"] == "dark"
assert d["permissions"] == {"allow": ["Bash(git status:*)"]}
assert d["enabledPlugins"]["other@plugin"] is False
assert "idc@idc-workflow" not in d["enabledPlugins"]
PY

missing="$WORK/new/.claude/settings.json"
python3 "$HELPER" enable "$missing" "idc@idc-workflow" >/dev/null \
  || fail "enable should create a missing settings file"
python3 - "$missing" <<'PY' || fail "created settings file is missing the IDC enablement key"
import json, sys
p = sys.argv[1]
d = json.load(open(p))
assert d == {"enabledPlugins": {"idc@idc-workflow": True}}
PY

invalid="$WORK/invalid.json"
printf '{"theme": ' > "$invalid"
before="$WORK/invalid.before"
cp "$invalid" "$before"
if python3 "$HELPER" enable "$invalid" "idc@idc-workflow" >/dev/null 2>&1; then
  fail "invalid JSON should fail instead of being replaced"
fi
cmp -s "$invalid" "$before" || fail "invalid JSON file was modified/truncated after failure"

non_object="$WORK/non-object.json"
printf '{"enabledPlugins": false, "theme": "dark"}\n' > "$non_object"
cp "$non_object" "$before"
if python3 "$HELPER" enable "$non_object" "idc@idc-workflow" >/dev/null 2>&1; then
  fail "non-object enabledPlugins should fail instead of being replaced"
fi
cmp -s "$non_object" "$before" || fail "non-object enabledPlugins file was modified after failure"

echo "PASS: settings helper preserves operator keys and fails without truncation"
