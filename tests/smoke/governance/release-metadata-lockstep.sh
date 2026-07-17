#!/bin/bash
# idc-assert-class: behavior
# Release metadata is one atomic contract: both manifests, the changelog heading, and exactly one
# README version badge must name the same version.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/repo"
mkdir -p "$ROOT/scripts" "$ROOT/.claude-plugin"
cp "$GOV_PLUGIN/scripts/idc_release_check.py" "$ROOT/scripts/idc_release_check.py"

seed() {
  VERSION="$1" ALT="$2" URL_VERSION="$3" DUPLICATE="${4:-no}" ROOT="$ROOT" python3 - <<'PY'
import json, os
root = os.environ["ROOT"]
version, alt, url_version, duplicate = (os.environ[k] for k in
                                        ("VERSION", "ALT", "URL_VERSION", "DUPLICATE"))
with open(os.path.join(root, ".claude-plugin", "plugin.json"), "w", encoding="utf-8") as f:
    json.dump({"name": "idc", "version": version}, f)
with open(os.path.join(root, ".claude-plugin", "marketplace.json"), "w", encoding="utf-8") as f:
    json.dump({"plugins": [{"name": "idc", "version": version}]}, f)
badge = (f'<img src="https://img.shields.io/badge/version-{url_version}-grey" '
         f'alt="{alt}">')
with open(os.path.join(root, "README.md"), "w", encoding="utf-8") as f:
    f.write(badge + ("\n" + badge if duplicate == "yes" else "") + "\n")
with open(os.path.join(root, "CHANGELOG.md"), "w", encoding="utf-8") as f:
    f.write(f"# Changelog\n\n## {version} — 2026-07-17\n\n- release\n")
PY
}

check() { python3 "$ROOT/scripts/idc_release_check.py" >"$WORK/out" 2>"$WORK/err"; }

seed 4.1.1 'version 4.1.1' 4.1.1
check || gov_fail "matching release metadata was rejected: $(cat "$WORK/err")"

seed 4.1.1 'version 4.1.0' 4.1.1
check && gov_fail "a stale README badge alt text was accepted"
grep -qi 'alt' "$WORK/err" || gov_fail "stale alt refusal did not name alt text: $(cat "$WORK/err")"

seed 4.1.1 'version 4.1.1' 4.1.0
check && gov_fail "a stale README badge URL was accepted"
grep -qi 'URL' "$WORK/err" || gov_fail "stale URL refusal did not name the URL: $(cat "$WORK/err")"

seed 4.1.1 'version 4.1.1' 4.1.1 yes
check && gov_fail "duplicate README version badges were accepted"
grep -qi 'exactly one' "$WORK/err" || gov_fail "duplicate refusal did not require exactly one badge"

printf '<p>no version badge</p>\n' > "$ROOT/README.md"
check && gov_fail "a missing README version badge was accepted"

seed 4.1.1 'version 4.1.1' 4.1.1
ROOT="$ROOT" python3 - <<'PY'
import json, os
p = os.path.join(os.environ["ROOT"], ".claude-plugin", "marketplace.json")
d = json.load(open(p, encoding="utf-8")); d["plugins"][0]["version"] = "4.1.0"
with open(p, "w", encoding="utf-8") as f: json.dump(d, f)
PY
check && gov_fail "manifest version disagreement was accepted"

echo "PASS: release manifests, changelog, and exactly one README badge stay in lockstep"
