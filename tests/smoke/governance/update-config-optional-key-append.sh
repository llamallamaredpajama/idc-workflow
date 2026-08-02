#!/bin/bash
# idc-assert-class: behavior
# update-config-optional-key-append.sh — /idc:update's ONE safe additive config mutation (#123).
#
# Before this fix, new optional keys a release added to a data-bearing config's template surfaced
# only as a report line ("N new optional keys") — the operator had to hand-edit the file to adopt
# them, so shipped knobs (3.3.0: autorun.staffing_gate_threshold, model_routing.overrides) never
# engaged in governed repos. The 3.1.3 doctrine (the board Stage-option append) says update itself
# performs the safe ADDITIVE migration. commands/update.md Phase 2 §A now carries a fixed appender:
# offer-yes appends each new key COMMENTED OUT (its `# idc-new-key:` marker + the template's own
# doc comments and default, all `# `-prefixed) at the end of the file — no existing line touched,
# operator values byte-identical, structural key set (idc_config_keys.py) unchanged, idempotent
# re-run no-op (exit 3). This extracts that appender AS SHIPPED from the playbook and runs it.
#
# Red-when-broken: stash the commands/update.md appender (pre-#123 playbook) → the extraction
# finds no `idc-new-key` heredoc and this scenario FAILs.
#
# Hermetic: fixture configs + the real idc_config_keys.py; no GitHub, no live repo.
# Usage: bash tests/smoke/governance/update-config-optional-key-append.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
UPDATE="$PLUGIN/commands/update.md"
CK="$PLUGIN/scripts/idc_config_keys.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$UPDATE" ] || fail "commands/update.md not found at $UPDATE"
[ -f "$CK" ] || fail "idc_config_keys.py not found at $CK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- extract the SHIPPED appender (the bash-fenced heredoc python that writes idc-new-key) -----
python3 - "$UPDATE" > "$WORK/appender.py" <<'PY' || fail "could not extract the §A optional-key appender from commands/update.md — is the #123 offer-yes appender missing?"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# The appender is the heredoc between <<'PY' and its terminating PY inside §A's fenced bash block,
# identified by the marker string it (and only it) writes: idc-new-key.
blocks = [b for b in re.findall(r"<<'PY'\n(.*?)\nPY\n", text, re.S) if "idc-new-key" in b]
if len(blocks) != 1:
    sys.exit("expected exactly one idc-new-key appender heredoc in commands/update.md, found %d" % len(blocks))
sys.stdout.write(blocks[0])
PY

# ---- fixtures: an operator-populated config ("on disk") + the new version's rendered template --
cat > "$WORK/ondisk.yaml" <<'YAML'
project:
  name: "real-proj"
autorun:
  max_parallel: 3
model_routing:
  standard:
    claude: { model: "claude-opus-4-8" }
YAML
cat > "$WORK/template.yaml" <<'YAML'
project:
  name: "{{PROJECT_NAME}}"
autorun:
  max_parallel: 2
  # Pause the drain when fewer than this many build workers can be staffed.
  # 0 disables the gate.
  staffing_gate_threshold: 0
model_routing:
  standard:
    claude: { model: "claude-opus-4-8" }
  # Per-role model overrides; keys are role names, values full model ids.
  overrides: {}
YAML

# ---- detection (the existing §A step): the template's two new keys are reported ----------------
added="$(python3 "$CK" --added "$WORK/ondisk.yaml" "$WORK/template.yaml")" \
  || fail "idc_config_keys.py --added failed on the fixtures"
printf '%s\n' "$added" | grep -qx 'autorun.staffing_gate_threshold' \
  || fail "detection should report autorun.staffing_gate_threshold, got: $added"
printf '%s\n' "$added" | grep -qx 'model_routing.overrides' \
  || fail "detection should report model_routing.overrides, got: $added"
cp "$WORK/ondisk.yaml" "$WORK/before.yaml"   # offer-no baseline: detection alone mutates nothing
cmp -s "$WORK/ondisk.yaml" "$WORK/before.yaml" || fail "detection touched the config file"
keys_before="$(python3 "$CK" "$WORK/ondisk.yaml")"

echo "== offer-yes: the shipped appender lands both keys, commented, additively =="
out="$(timeout 60 python3 "$WORK/appender.py" "$WORK/ondisk.yaml" "$WORK/template.yaml" "$PLUGIN" \
        autorun.staffing_gate_threshold model_routing.overrides 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "appender exited $rc (expected 0): $out"
printf '%s\n' "$out" | grep -q '^config-keys-appended: autorun.staffing_gate_threshold, model_routing.overrides$' \
  || fail "expected 'config-keys-appended: <both keys>', got: $out"

# 1. Existing bytes untouched: the original file is an exact byte PREFIX of the new one.
sz="$(wc -c < "$WORK/before.yaml")"
head -c "$sz" "$WORK/ondisk.yaml" | cmp -s - "$WORK/before.yaml" \
  || fail "the append rewrote existing bytes — the original file must be an exact prefix"
# 2. Everything appended is a comment (or blank) — the file's parse cannot have changed.
tail -c +"$((sz + 1))" "$WORK/ondisk.yaml" | grep -vE '^(#|$)' \
  && fail "a non-comment line was appended: $(tail -c +"$((sz + 1))" "$WORK/ondisk.yaml" | grep -vE '^(#|$)' | head -1)"
# 3. Structural key set UNCHANGED (the same walker /idc:update's detection uses).
[ "$(python3 "$CK" "$WORK/ondisk.yaml")" = "$keys_before" ] \
  || fail "the append changed the structural key set — it must be structurally invisible"
# 4. Each key's marker + its template doc comments and default landed, commented.
grep -qx '# idc-new-key: autorun.staffing_gate_threshold' "$WORK/ondisk.yaml" \
  || fail "missing the idc-new-key marker for autorun.staffing_gate_threshold"
grep -qx '# idc-new-key: model_routing.overrides' "$WORK/ondisk.yaml" \
  || fail "missing the idc-new-key marker for model_routing.overrides"
grep -q '^#.*staffing_gate_threshold: 0' "$WORK/ondisk.yaml" \
  || fail "the template default (staffing_gate_threshold: 0) was not appended commented"
grep -q '^#.*0 disables the gate\.' "$WORK/ondisk.yaml" \
  || fail "the template's doc comment for staffing_gate_threshold was not carried along"
grep -q '^#.*overrides: {}' "$WORK/ondisk.yaml" \
  || fail "the template default (overrides: {}) was not appended commented"
# 5. Operator values survive verbatim.
grep -qx '  max_parallel: 3' "$WORK/ondisk.yaml" \
  || fail "the operator's max_parallel: 3 must survive (the template says 2 — no value adoption)"
echo "  ok both keys appended commented; prefix, parse, and operator values intact"

echo "== idempotent re-run: exit 3, file byte-identical =="
cp "$WORK/ondisk.yaml" "$WORK/after1.yaml"
out2="$(timeout 60 python3 "$WORK/appender.py" "$WORK/ondisk.yaml" "$WORK/template.yaml" "$PLUGIN" \
         autorun.staffing_gate_threshold model_routing.overrides 2>&1)"
rc2=$?
[ "$rc2" -eq 3 ] || fail "re-run should exit 3 (already-appended no-op), got $rc2: $out2"
printf '%s\n' "$out2" | grep -q '^config-keys-already-appended:' \
  || fail "re-run should report config-keys-already-appended, got: $out2"
cmp -s "$WORK/ondisk.yaml" "$WORK/after1.yaml" \
  || fail "the idempotent re-run modified the file"
echo "  ok re-run is a marker-detected no-op"

echo "== fail-closed: an unknown key-path rolls back untouched =="
out3="$(timeout 60 python3 "$WORK/appender.py" "$WORK/ondisk.yaml" "$WORK/template.yaml" "$PLUGIN" \
         no.such.key 2>&1)"
rc3=$?
[ "$rc3" -ne 0 ] && [ "$rc3" -ne 3 ] \
  || fail "an unknown key-path must fail (got exit $rc3): $out3"
printf '%s\n' "$out3" | grep -q 'not found in the rendered template' \
  || fail "the unknown-key failure should name the missing key-path, got: $out3"
cmp -s "$WORK/ondisk.yaml" "$WORK/after1.yaml" \
  || fail "a failed append modified the file — it must leave it untouched"
echo "  ok unknown key fails closed with the file untouched"

echo "PASS: update.md's §A appender adopts new optional config keys additively — commented blocks with template docs/defaults, marker-deduped re-runs, operator bytes and structure untouched"
