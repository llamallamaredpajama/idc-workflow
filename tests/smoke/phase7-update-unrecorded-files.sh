#!/bin/bash
# idc-assert-class: behavior
# Phase 7 (update unrecorded-file detection) smoke — the 4.0.0 migration gap the U6 update-sandbox
# e2e caught: a receipt written by an OLDER plugin version does not list files a NEWER version
# scaffolds (a 3.x receipt has no docs/workflow/workflow-machine.yaml), and a verify that
# classifies only receipt entries never surfaces them — so /idc:update's §B "a missing copy is
# restored" promise was unreachable and the drift contract read ok:true while the migration was
# incomplete. verify --json must emit those paths in "unrecorded" so Phase 1 routes them.
#
# Hermetic: temp repo + real receipt stamp/verify against the real templates dir; no GitHub.
#
# Usage: bash tests/smoke/phase7-update-unrecorded-files.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_receipt_check.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "receipt helper not found at $HELPER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs/workflow"

# Seed a pre-4.0.0-shaped repo: the old stamped set WITHOUT workflow-machine.yaml.
printf 'w\n' > "$WORK/WORKFLOW.md"
printf 'c\n' > "$WORK/WORKFLOW-config.yaml"
printf 't\n' > "$WORK/docs/workflow/tracker-config.yaml"
python3 "$HELPER" stamp --repo "$WORK" --out "$WORK/docs/workflow/install-receipt.yaml" \
  --plugin-version 3.3.0 \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml >/dev/null \
  || fail "could not stamp the old-version receipt"

out="$(python3 "$HELPER" verify --repo "$WORK" --json)" || fail "verify exited non-zero"

# 1. The new-in-4.0.0 machine table must surface as unrecorded (it is governed: the template
#    exists in this plugin) — this is the red-when-broken core: remove the unrecorded
#    computation and this fails.
echo "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
u = o.get("unrecorded")
ok = o.get("ok")
assert isinstance(u, list), f"unrecorded key missing or not a list: {u!r}"
assert "docs/workflow/workflow-machine.yaml" in u, f"workflow-machine.yaml not in unrecorded: {u}"
# 2. ok stays a modified+missing contract (back-compat): nothing modified/missing here.
assert ok is True, f"ok must stay modified+missing-based, got {ok!r}"
# 3. Receipt-listed files must never appear unrecorded.
assert "WORKFLOW.md" not in u, f"receipt-listed WORKFLOW.md wrongly unrecorded: {u}"
' || fail "unrecorded detection assertions failed: $out"

# 4. Closing the loop: once the file exists and a fresh (4.0.0) stamp records it, unrecorded
#    must empty for it — the post-update drift contract is truthful again.
cp "$PLUGIN/templates/workflow-machine.yaml" "$WORK/docs/workflow/workflow-machine.yaml" \
  || fail "could not lay down the machine template"
python3 "$HELPER" stamp --repo "$WORK" --out "$WORK/docs/workflow/install-receipt.yaml" \
  --plugin-version 4.0.0 \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml \
  docs/workflow/workflow-machine.yaml >/dev/null || fail "could not re-stamp with the machine file"
out2="$(python3 "$HELPER" verify --repo "$WORK" --json)" || fail "post-restamp verify exited non-zero"
echo "$out2" | python3 -c '
import json, sys
o = json.load(sys.stdin)
u = o.get("unrecorded", [])
assert "docs/workflow/workflow-machine.yaml" not in u, \
    f"machine file still unrecorded after being stamped: {u}"
' || fail "post-restamp unrecorded assertions failed: $out2"

# 5. TSV output stays free of unrecorded rows (uninstall consumes TSV as its removal manifest —
#    a never-stamped file must not enter it).
tsv="$(python3 "$HELPER" verify --repo "$WORK" 2>/dev/null)" || fail "TSV verify exited non-zero"
echo "$tsv" | grep -q "unrecorded" && fail "TSV output must not carry unrecorded rows: $tsv"

# --- Task 8 Step 1: /idc:update installs the intake home into an older repo, and never touches ---
# intake CONTENTS. Same migration shape as workflow-machine.yaml above: a pre-4.1.0 receipt has no
# docs/workflow/intakes/.gitkeep, so update must surface it as `unrecorded` and restore it. But the
# directory may already hold operator work products (compiled /idc:intake manifests), and those are
# NOT governed scaffold: update must never classify — and so never refresh, diff-and-ask about, or
# remove — a manifest. Seed a populated intake home and prove the classifier's blast radius.
#
# This is also the UPDATE-side of the directory-exists-but-keepfile-absent class the Task-8 incident
# e2e hit on the init side (run-t8e2e.txt "Setup findings" 2; the scaffold fix + its regression live
# in phase1-init-doctor.sh). The shape below is exactly that repo: the intake DIRECTORY exists while
# its keepfile does not. `unrecorded` is derived from the plugin's TEMPLATE tree, not from what
# happens to be on disk, so the keepfile must still surface for update to restore — a classifier
# that inferred expectations from the repo would go quiet here and strand the migration.
mkdir -p "$WORK/docs/workflow/intakes"
printf '{"schema_version":1,"intake_id":"legacy"}' > "$WORK/docs/workflow/intakes/vendor.intake.json"
[ -e "$WORK/docs/workflow/intakes/.gitkeep" ] \
  && fail "test setup is wrong: this scenario needs the intake DIRECTORY present and its keepfile ABSENT"
out3="$(python3 "$HELPER" verify --repo "$WORK" --json)" || fail "verify with a populated intakes/ exited non-zero"
echo "$out3" | python3 -c '
import json, sys
o = json.load(sys.stdin)
u = o.get("unrecorded", [])
assert "docs/workflow/intakes/.gitkeep" in u, \
    f"the intake home must surface as unrecorded so /idc:update installs it into an older repo: {u}"
listed = u + o["unchanged"] + o["modified"] + o["missing"]
stray = sorted(p for p in listed if p.startswith("docs/workflow/intakes/")
               and p != "docs/workflow/intakes/.gitkeep")
assert not stray, \
    f"/idc:update classified intake CONTENTS as governed files — it would touch an operator work product: {stray}"
' || fail "populated-intake-home assertions failed: $out3"

# The same guarantee on the uninstall side: the TSV removal manifest must never carry a manifest.
tsv3="$(python3 "$HELPER" verify --repo "$WORK" 2>/dev/null)" || fail "TSV verify with a populated intakes/ exited non-zero"
echo "$tsv3" | grep -q "intakes/vendor.intake.json" \
  && fail "an intake manifest entered the TSV removal manifest — /idc:uninstall would delete an operator work product: $tsv3"

# The prose half of the contract: the receipt mechanics above only hold if the command bodies an
# agent actually follows name the intake home and its work-product rule.
UPD="$PLUGIN/commands/update.md"
UNI="$PLUGIN/commands/uninstall.md"
grep -qF 'docs/workflow/intakes/' "$UPD" \
  || fail "commands/update.md must name docs/workflow/intakes/ — the intake home it installs into older repos without touching intake contents"
grep -qF 'docs/workflow/intakes/.gitkeep' "$UNI" \
  || fail "commands/uninstall.md's pre-receipt fallback must remove the intake home by its .gitkeep only — a bare docs/workflow/intakes/ would delete the operator's compiled manifests as pristine scaffold"
grep -qF 'docs/workflow/pillar-matrices/.gitkeep' "$UNI" \
  || fail "commands/uninstall.md's pre-receipt fallback must name only the matrix keepfile"
grep -qF 'docs/workflow/code-reviews/.gitkeep' "$UNI" \
  || fail "commands/uninstall.md's pre-receipt fallback must name the review keepfile"
grep -qF 'docs/workflow/code-reviews/.gitignore' "$UNI" \
  || fail "commands/uninstall.md's pre-receipt fallback must name the review ignore file"
python3 - "$UNI" <<'PY' \
  || fail "commands/uninstall.md must never recursively remove or list a work-product directory as a footprint"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
if re.search(r"git[^\n]*\brm\b[^\n]*\s-r(?:\s|$)", text):
    raise SystemExit(1)
fallback = text.split("- **No receipt**", 1)[1].split("Always add two footprints", 1)[0]
for directory in ("pillar-matrices", "code-reviews", "intakes"):
    if f"`docs/workflow/{directory}/`" in fallback:
        raise SystemExit(1)
PY
grep -qi 'work product' "$UNI" \
  || fail "commands/uninstall.md must state the work-product policy that preserves populated intake manifests"
grep -qF 'receipt MUST remain' "$UNI" \
  || fail "commands/uninstall.md must retain the canonical receipt through closeout"
grep -qF 'docs/workflow/install-receipt.yaml docs/workflow/tracker-config.yaml' "$UNI" \
  || fail "commands/uninstall.md must remove the retained receipt and anchor together only after finish"

echo "PASS: phase7-update-unrecorded-files"
exit 0
