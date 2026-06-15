#!/bin/bash
# Phase 7 (update config-structure check) smoke — fix/update-data-config-preserve.
#
# The two data-bearing configs (WORKFLOW-config.yaml, docs/workflow/tracker-config.yaml) are
# operator-owned data files seeded ONCE from a stub template (domains: [], field_ids: "",
# {{TOKENS}}). After /idc:init fills them, they permanently differ from the stub template — that
# difference IS the operator's data, not drift. So /idc:update must NOT offer a destructive
# keep/replace; it must preserve them and only flag GENUINE NEW STRUCTURE (new keys/schema) the
# template introduced. scripts/idc_config_keys.py answers that: it extracts a file's structural
# key-paths (list items, block scalars, and flow values treated as opaque), and `--added BASE NEW`
# prints the key-paths NEW has that BASE lacks.
#
# Hermetic: pure structural-key assertions on fixtures + the real templates; no GitHub.
#
# Usage: bash tests/smoke/phase7-update-config-structure.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_config_keys.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "config-structure helper not found at $HELPER (scripts/idc_config_keys.py)"

added() { python3 "$HELPER" --added "$1" "$2"; }

# --- Controlled fixtures: a data-filled config ("on-disk") and its stub template -----------------
cat > "$SBX/ondisk.yaml" <<'YAML'
project:
  name: "real-proj"
documents:
  prd: docs/PRD.md
domains:
  - name: foo
    brief: a domain with surfaces:colons in prose
    surfaces: [src/foo/, src/bar/]
  - name: baz
    brief: another
    surfaces: [src/baz/]
field_ids:
  Status: "PVTSSF_real_status"
  Wave: "PVTSSF_real_wave"
model_routing:
  standard:
    claude: { model: "claude-opus-4-8", effort: extra-high }
    use: >-
      execute-never-decide: research digestion and repo reconnaissance — this colon
      must NOT be parsed as a structural key
YAML

cat > "$SBX/template.yaml" <<'YAML'
project:
  name: "{{PROJECT_NAME}}"
documents:
  prd: docs/prd/
domains: []
  # - name: api
  #   brief: HTTP surface
  #   surfaces: [src/api/]
field_ids:
  Status: ""
  Wave: ""
model_routing:
  standard:
    claude: { model: "claude-opus-4-8", effort: extra-high }
    use: >-
      execute-never-decide: research digestion and repo reconnaissance — this colon
      must NOT be parsed as a structural key
YAML

# 1. CORE: a data-filled config has NO structural drift from its stub template. Update must report
#    "preserved — current" and NOT prompt. (The only diffs are operator data + tokens + block-scalar
#    prose, none of which are structure.)
out="$(added "$SBX/ondisk.yaml" "$SBX/template.yaml")"
[ -z "$out" ] || fail "stub template must add NO structure over a data-filled config; got added keys: [$out]"

# 2. LIST OPACITY: a populated domains list must not register as 'added structure' vs the empty
#    template (i.e. domains.name / domains.brief / domains.surfaces are NOT structural key-paths).
out="$(added "$SBX/template.yaml" "$SBX/ondisk.yaml")"
[ -z "$out" ] || fail "filled domains list must not read as added structure; got: [$out]"

# 3. BLOCK-SCALAR SAFETY: the 'execute-never-decide:' colon inside a >- block must never appear as a key.
keys="$(python3 "$HELPER" "$SBX/ondisk.yaml")"
printf '%s\n' "$keys" | grep -q 'execute-never-decide' \
  && fail "a colon inside a block scalar was wrongly parsed as a structural key"
printf '%s\n' "$keys" | grep -qx 'domains' || fail "expected 'domains' as a structural key"
printf '%s\n' "$keys" | grep -qx 'field_ids.Status' || fail "expected 'field_ids.Status' as a structural key"
printf '%s\n' "$keys" | grep -q 'domains.name' \
  && fail "domains list-item keys must be opaque (domains.name should not appear)"

# 4. DRIFT DETECTION: a template that genuinely adds a new field + a new top-level key is detected.
cat > "$SBX/template-v2.yaml" <<'YAML'
project:
  name: "{{PROJECT_NAME}}"
documents:
  prd: docs/prd/
domains: []
field_ids:
  Status: ""
  Wave: ""
  Stage: ""
model_routing:
  standard:
    claude: { model: "claude-opus-4-8", effort: extra-high }
    use: >-
      execute-never-decide: research digestion
new_top_level:
  child: ""
YAML
out="$(added "$SBX/ondisk.yaml" "$SBX/template-v2.yaml")"
printf '%s\n' "$out" | grep -qx 'field_ids.Stage'   || fail "must detect new field_ids.Stage; got: [$out]"
printf '%s\n' "$out" | grep -qx 'new_top_level'      || fail "must detect new top-level key; got: [$out]"
printf '%s\n' "$out" | grep -qx 'new_top_level.child' || fail "must detect nested new key; got: [$out]"

# --- Real-template parity: the lootr-web shape against the SHIPPED templates ----------------------
# Scaffold a repo, populate the configs the way /idc:init does, then assert the SHIPPED templates
# add no structure over the populated files (so a real update stays smooth — no destructive prompt).
mkdir -p "$SBX/repo"
bash "$PLUGIN/scripts/idc_init_scaffold.sh" "$PLUGIN" "$SBX/repo" "RealProj" filesystem >/dev/null \
  || fail "scaffold helper exited non-zero"
WC="$SBX/repo/WORKFLOW-config.yaml"
TC="$SBX/repo/docs/workflow/tracker-config.yaml"
# init-style data fill: domains list + tracker field_ids/project_number
python3 - "$WC" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("domains: []", "domains:\n  - name: web\n    brief: the web app\n    surfaces: [web/]")
open(p,"w").write(s)
PY
python3 - "$TC" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('Status: ""','Status: "PVTSSF_x"').replace("{{TRACKER_PROJECT_NUMBER}}","7")
open(p,"w").write(s)
PY
for f in "$WC" "$TC"; do
  base="$(basename "$f")"
  tmpl="$(python3 "$PLUGIN/scripts/idc_template_for.py" --plugin-root "$PLUGIN" \
            "$([ "$base" = WORKFLOW-config.yaml ] && echo WORKFLOW-config.yaml || echo docs/workflow/tracker-config.yaml)")"
  out="$(added "$f" "$tmpl")"
  [ -z "$out" ] || fail "shipped template adds phantom structure over a populated $base; got: [$out]"
done

echo "PASS: idc_config_keys.py — data-filled configs show no structural drift; real new keys detected"
