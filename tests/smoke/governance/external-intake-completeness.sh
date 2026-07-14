#!/bin/bash
# external-intake-completeness.sh — Task 4 exact-once foreign-plan manifest regression.
#
# Proves the stdlib helper extracts every source unit once, keeps absolute source locations out of the
# manifest, rejects incomplete/duplicate/misrouted/dependency-invalid mappings, binds an independent
# review to the intake and source hash, and updates dispositions without mutating a tracker.
#
# Usage: /bin/bash tests/smoke/governance/external-intake-completeness.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

INTAKE="$GOV_PLUGIN/scripts/idc_intake_manifest.py"
FIXTURE="$GOV_PLUGIN/tests/smoke/fixtures/session-b7a93ff6"
[ -f "$INTAKE" ] || gov_fail "scripts/idc_intake_manifest.py not found"
[ -f "$FIXTURE/external-plan.md" ] || gov_fail "sanitized external-plan fixture not found"
[ -f "$FIXTURE/expected-units.json" ] || gov_fail "expected unit set fixture not found"

WORK="$(mktemp -d)" || gov_fail "could not create temp workspace"
trap 'rm -rf "$WORK"' EXIT
MANIFEST="$WORK/2026-07-12-example.json"
REVIEW=""
COMPLETE="$WORK/complete.json"
GOOD_REVIEW="$WORK/good-review.json"

intake() { python3 "$INTAKE" "$@"; }

map_every_unit() {
  python3 - "$1" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for unit in data["units"]:
    if unit["id"] == "Drive":
        unit.update({"summary": "Deliver the Drive foundation", "class": "new_requirement",
                     "route": "think", "dependencies": [], "operator_stops": []})
    else:
        unit.update({"summary": f"Route {unit['id']} through admitted scope review",
                     "class": "admitted_unplanned", "route": "recirculate",
                     "dependencies": [], "operator_stops": []})
    unit["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".intake-test-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True); handle.write("\n")
os.replace(tmp, path)
PY
}

write_passing_review() {
  python3 - "$1" "$2" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
review = {"schema_version": 1, "intake_id": manifest["intake_id"],
          "source_sha256": manifest["source"]["sha256"], "verdict": "PASS",
          "missing_unit_ids": [], "duplicate_unit_ids": [],
          "misrouted_unit_ids": [], "notes": []}
json.dump(review, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
}

manifest_content_sha256() {
  python3 - "$1" <<'PY'
import hashlib, json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
content = {
    "schema_version": manifest["schema_version"],
    "intake_id": manifest["intake_id"],
    "source": manifest["source"],
    "operator_goal": manifest["operator_goal"],
    "runtime": manifest["runtime"],
    "expected_unit_ids": manifest["expected_unit_ids"],
    "units": [
        {
            key: unit[key]
            for key in (
                "id", "source_anchor", "summary", "class", "route", "dependencies",
                "operator_stops",
            )
        }
        for unit in manifest["units"]
    ],
}
print(hashlib.sha256(json.dumps(
    content, ensure_ascii=False, separators=(",", ":"), sort_keys=True
).encode("utf-8")).hexdigest())
PY
}

canonical_review_path() {
  local digest
  digest="$(manifest_content_sha256 "$1")" || return 1
  printf '%s/%s.review.%s.json\n' "$2" "$(jq -r '.intake_id' "$1")" "$digest"
}

write_canonical_review() {
  write_passing_review "$1" "$2"
}

drop_unit() {
  python3 - "$1" "$2" <<'PY'
import json, sys
unit_id, path = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
data["units"] = [unit for unit in data["units"] if unit["id"] != unit_id]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
}

set_route() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
unit_id, route, path = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
next(unit for unit in data["units"] if unit["id"] == unit_id)["route"] = route
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
}

set_unit_json_field() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
unit_id, field, encoded, path = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
next(unit for unit in data["units"] if unit["id"] == unit_id)[field] = json.loads(encoded)
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
}

mutate_manifest() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
kind, arg, path = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
if kind == "duplicate":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    data["units"].append(dict(unit))
elif kind == "unknown-dependency":
    next(unit for unit in data["units"] if unit["id"] == arg)["dependencies"] = ["NO-SUCH-UNIT"]
elif kind == "cycle":
    next(unit for unit in data["units"] if unit["id"] == "U1")["dependencies"] = ["U2"]
    next(unit for unit in data["units"] if unit["id"] == "U2")["dependencies"] = ["U1"]
elif kind == "absolute-source":
    data["source"]["repo_relative_locator"] = "/private/external-plan.md"
elif kind == "unsafe-source-locator":
    data["source"]["repo_relative_locator"] = arg
elif kind == "self-certified":
    data["verification"].update({"status": "passed", "review_path": "invented.review.json"})
elif kind == "malformed-unclassified":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": None, "route": None, "disposition": []})
elif kind == "coordinated-remove":
    data["expected_unit_ids"] = [unit_id for unit_id in data["expected_unit_ids"] if unit_id != arg]
    data["units"] = [unit for unit in data["units"] if unit["id"] != arg]
elif kind == "unsafe-operator-stop":
    next(unit for unit in data["units"] if unit["id"] == arg)["operator_stops"] = [
        "SERVICE_API_KEY=sample-sensitive-value"
    ]
elif kind == "malformed-unclassified-evidence":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": None, "route": None,
                 "disposition": {"state": "unclassified", "target_ref": None, "evidence": None}})
elif kind == "malformed-unclassified-target":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": None, "route": None,
                 "disposition": {"state": "unclassified", "target_ref": 42, "evidence": []}})
elif kind == "malformed-unclassified-state":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": None, "route": None,
                 "disposition": {"state": [], "target_ref": None, "evidence": []}})
elif kind == "no-target":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit["disposition"] = {"state": "materialized", "target_ref": None, "evidence": []}
elif kind == "bad-class-route":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": "new_requirement", "route": "recirculate"})
elif kind == "done-without-evidence":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": "already_done", "route": "verify"})
    unit["disposition"] = {"state": "verified_done", "target_ref": None, "evidence": []}
elif kind == "ignored-without-reason":
    unit = next(unit for unit in data["units"] if unit["id"] == arg)
    unit.update({"class": "ignored_non_execution", "route": "ignore"})
    unit["disposition"] = {"state": "ignored", "target_ref": None, "evidence": []}
elif kind == "reviewed-anchor-heading":
    next(unit for unit in data["units"] if unit["id"] == arg)["source_anchor"]["heading"] = \
        f"{arg} - changed after review"
elif kind == "reviewed-anchor-range":
    next(unit for unit in data["units"] if unit["id"] == arg)["source_anchor"]["line_end"] += 1
elif kind == "reviewed-summary":
    next(unit for unit in data["units"] if unit["id"] == arg)["summary"] = \
        "Changed after independent review"
elif kind == "reviewed-operator-goal":
    data["operator_goal"]["normalized"] = "changed after independent review"
elif kind == "add-reviewed-operator-stop":
    next(unit for unit in data["units"] if unit["id"] == arg)["operator_stops"] = \
        ["operator approval required"]
elif kind == "remove-reviewed-operator-stop":
    next(unit for unit in data["units"] if unit["id"] == arg)["operator_stops"] = []
else:
    raise SystemExit(f"unknown manifest mutation {kind}")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
}

mutate_review() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
kind, value, path = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
if kind == "hash":
    data["source_sha256"] = value
elif kind == "intake":
    data["intake_id"] = value
elif kind == "verdict":
    data["verdict"] = value
elif kind == "finding":
    data["missing_unit_ids"] = [value]
else:
    raise SystemExit(f"unknown review mutation {kind}")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
}

fresh_case() {
  CASE_DIR="$WORK/case-$1"
  mkdir -p "$CASE_DIR" || gov_fail "could not create case directory for $1"
  CASE_MANIFEST="$CASE_DIR/2026-07-12-example.json"
  CASE_REVIEW="$CASE_DIR/$(basename "$REVIEW")"
  cp "$COMPLETE" "$CASE_MANIFEST" || gov_fail "could not copy complete manifest for $1"
  cp "$GOOD_REVIEW" "$CASE_REVIEW" || gov_fail "could not copy passing review for $1"
}

refresh_case_review() {
  local prior_review="$CASE_REVIEW"
  CASE_REVIEW="$(canonical_review_path "$CASE_MANIFEST" "$CASE_DIR")" \
    || gov_fail "could not calculate review path for $CASE_DIR"
  [ "$prior_review" = "$CASE_REVIEW" ] || rm -f "$prior_review"
  write_passing_review "$CASE_MANIFEST" "$CASE_REVIEW" \
    || gov_fail "could not refresh review for $CASE_DIR"
}

validate_must_fail_cleanly() {
  local expected="$1"
  local failure="$2"
  local output rc
  output="$(intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" 2>&1)"
  rc=$?
  if [ "$rc" -ne 2 ] || ! printf '%s' "$output" | grep -Fq "idc-intake: FAIL — $expected" \
       || printf '%s' "$output" | grep -q "Traceback"; then
    gov_fail "$failure (expected clean failure containing: $expected; got rc=$rc: $output)"
  fi
}

must_fail_manifest() {
  refresh_case_review
  validate_must_fail_cleanly "$1" "$2"
}

must_fail_reviewed() {
  validate_must_fail_cleanly "$1" "$2"
}

REVIEW_FIX_FAILURES=""
record_review_fix_failure() {
  if [ -n "$REVIEW_FIX_FAILURES" ]; then
    REVIEW_FIX_FAILURES="$REVIEW_FIX_FAILURES, $1"
  else
    REVIEW_FIX_FAILURES="$1"
  fi
}

ROUND2_FAILURES=""
record_round2_failure() {
  if [ -n "$ROUND2_FAILURES" ]; then
    ROUND2_FAILURES="$ROUND2_FAILURES, $1"
  else
    ROUND2_FAILURES="$1"
  fi
}

ROUND3_FAILURES=""
record_round3_failure() {
  if [ -n "$ROUND3_FAILURES" ]; then
    ROUND3_FAILURES="$ROUND3_FAILURES, $1"
  else
    ROUND3_FAILURES="$1"
  fi
}

ROUND4_FAILURES=""
record_round4_failure() {
  if [ -n "$ROUND4_FAILURES" ]; then
    ROUND4_FAILURES="$ROUND4_FAILURES, $1"
  else
    ROUND4_FAILURES="$1"
  fi
}

status_must_fail_cleanly() {
  local expected="$1"
  local output rc
  output="$(intake status --manifest "$CASE_MANIFEST" --json 2>&1)"
  rc=$?
  [ "$rc" -eq 2 ] || return 1
  case "$output" in
    *"idc-intake: FAIL — $expected"*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$output" | grep -q "Traceback" && return 1
  return 0
}

intake extract --source "$FIXTURE/external-plan.md" --out "$MANIFEST" \
  --goal 'execute the whole program; Drive first' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "extract failed"

jq -S '.expected_unit_ids' "$MANIFEST" > "$WORK/actual.json"
jq -S '.required_unit_ids' "$FIXTURE/expected-units.json" > "$WORK/expected.json"
cmp -s "$WORK/actual.json" "$WORK/expected.json" \
  || gov_fail "extractor did not find U0-U8, B1, B2, and Drive exactly"

python3 - "$MANIFEST" <<'PY' || gov_fail "extracted manifest shape/privacy contract failed"
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(data) == {"schema_version", "intake_id", "source", "operator_goal", "runtime",
                     "expected_unit_ids", "units", "verification"}
assert data["schema_version"] == 1 and data["intake_id"] == "2026-07-12-example"
assert data["source"]["kind"] == "external_markdown"
assert data["source"]["display_name"] == "external-plan.md"
assert data["source"]["repo_relative_locator"] is None
assert re.fullmatch(r"[0-9a-f]{64}", data["source"]["sha256"])
assert data["operator_goal"]["verbatim_or_redacted"] == "execute the whole program; Drive first"
assert data["operator_goal"]["normalized"] == \
       "execute the complete program in dependency order with Drive first"
assert data["operator_goal"]["redactions"] == []
assert data["verification"] == {"status": "pending", "review_path": None,
                                "source_sha256": data["source"]["sha256"]}
for unit in data["units"]:
    assert set(unit) == {"id", "source_anchor", "summary", "class", "route", "dependencies",
                         "operator_stops", "disposition"}
    assert set(unit["source_anchor"]) == {"heading", "line_start", "line_end"}
    assert set(unit["disposition"]) == {"state", "target_ref", "evidence"}
    assert unit["disposition"]["state"] == "unclassified"
PY

if intake validate --manifest "$MANIFEST" >/dev/null 2>&1; then
  gov_fail "unclassified manifest passed"
fi
map_every_unit "$MANIFEST"
if intake validate --manifest "$MANIFEST" >/dev/null 2>&1; then
  gov_fail "manifest without independent review passed"
fi
REVIEW="$(canonical_review_path "$MANIFEST" "$WORK")" \
  || gov_fail "could not calculate passing review path"
write_passing_review "$MANIFEST" "$REVIEW"
intake validate --manifest "$MANIFEST" --review "$REVIEW" >/dev/null \
  || gov_fail "complete independently reviewed manifest failed"

python3 - "$MANIFEST" "$REVIEW" <<'PY' || gov_fail "passing review was not atomically stamped"
import json, os, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["verification"]["status"] == "passed"
assert data["verification"]["review_path"] == os.path.basename(sys.argv[2])
assert not os.path.isabs(data["verification"]["review_path"])
PY

cp "$MANIFEST" "$COMPLETE" || gov_fail "could not freeze complete manifest"
cp "$REVIEW" "$GOOD_REVIEW" || gov_fail "could not freeze passing review"

# Review-fix RED probes: keep these collected so one baseline run reports all four review findings.
# 1. Downstream operations must resolve and revalidate the stamped review, not trust editable fields.
REVIEW_BINDING_OK=1
fresh_case forged-link
mutate_manifest self-certified ignored "$CASE_MANIFEST"
if intake link --manifest "$CASE_MANIFEST" --unit U4 --state queued >/dev/null 2>&1; then
  REVIEW_BINDING_OK=0
fi
fresh_case forged-status
mutate_manifest self-certified ignored "$CASE_MANIFEST"
if intake status --manifest "$CASE_MANIFEST" --json >/dev/null 2>&1; then
  REVIEW_BINDING_OK=0
fi

TAMPER_DIR="$WORK/tampered-review"
mkdir -p "$TAMPER_DIR" || gov_fail "could not create tampered-review case"
cp "$COMPLETE" "$TAMPER_DIR/2026-07-12-example.json" \
  || gov_fail "could not copy tampered-review manifest"
TAMPER_REVIEW="$TAMPER_DIR/$(basename "$REVIEW")"
cp "$GOOD_REVIEW" "$TAMPER_REVIEW" \
  || gov_fail "could not copy tampered review"
mutate_review verdict FAIL "$TAMPER_REVIEW"
if intake status --manifest "$TAMPER_DIR/2026-07-12-example.json" --json >/dev/null 2>&1; then
  REVIEW_BINDING_OK=0
fi

OUTSIDE_REVIEW="$REVIEW"
fresh_case outside-review
if intake validate --manifest "$CASE_MANIFEST" --review "$OUTSIDE_REVIEW" >/dev/null 2>&1; then
  REVIEW_BINDING_OK=0
fi
[ "$REVIEW_BINDING_OK" -eq 1 ] || record_review_fix_failure "review-binding"

# 2. Source-derived human text is redacted; manually supplied durable references are rejected.
SAMPLE_PRIVATE_URL="https://private.example.invalid/intake/42"
SAMPLE_PRIVATE_URL_ALT="ssh://private.example.invalid/intake/43"
SAMPLE_MACHINE_PATH="/Users/example/private/intake"
SAMPLE_MACHINE_PATH_ALT="/opt/example/private/intake"
SAMPLE_CREDENTIAL="api_key=sample-sensitive-value"
SAMPLE_CREDENTIAL_ALT="FIRECRAWL_API_KEY=sample-sensitive-value"
PRIVACY_SOURCE="$WORK/privacy.md"
PRIVACY_MANIFEST="$WORK/2026-07-12-privacy.json"
python3 - "$PRIVACY_SOURCE" "$SAMPLE_PRIVATE_URL" "$SAMPLE_PRIVATE_URL_ALT" \
  "$SAMPLE_MACHINE_PATH" "$SAMPLE_MACHINE_PATH_ALT" "$SAMPLE_CREDENTIAL" \
  "$SAMPLE_CREDENTIAL_ALT" <<'PY'
import sys
path, private_url, private_url_alt, machine_path, machine_path_alt, credential, credential_alt = \
    sys.argv[1:]
text = f"""# Wrapper
## U1 - Read {machine_path}
body
**B1 - Fetch {private_url}**
body
1. U2 - Use {credential}
body
## U3 - Read {machine_path_alt}, fetch {private_url_alt}, and use {credential_alt}
body
"""
open(path, "w", encoding="utf-8", newline="").write(text)
PY
PRIVACY_OK=1
if ! intake extract --source "$PRIVACY_SOURCE" --out "$PRIVACY_MANIFEST" \
     --goal "Run $SAMPLE_MACHINE_PATH and $SAMPLE_MACHINE_PATH_ALT with $SAMPLE_PRIVATE_URL, $SAMPLE_PRIVATE_URL_ALT, $SAMPLE_CREDENTIAL, and $SAMPLE_CREDENTIAL_ALT" \
     --plugin-version 4.1.0 >/dev/null 2>&1; then
  PRIVACY_OK=0
elif ! python3 - "$PRIVACY_MANIFEST" "$SAMPLE_PRIVATE_URL" "$SAMPLE_PRIVATE_URL_ALT" \
       "$SAMPLE_MACHINE_PATH" "$SAMPLE_MACHINE_PATH_ALT" "$SAMPLE_CREDENTIAL" \
       "$SAMPLE_CREDENTIAL_ALT" <<'PY' >/dev/null 2>&1
import json, sys
path, *unsafe_values = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
serialized = json.dumps(data, sort_keys=True)
for unsafe_value in unsafe_values:
    assert unsafe_value not in serialized
assert set(data["operator_goal"]["redactions"]) == {
    "credential", "machine_specific_path", "private_url"
}
assert "[REDACTED_" in data["operator_goal"]["verbatim_or_redacted"]
for unit in data["units"]:
    for unsafe_value in unsafe_values:
        assert unsafe_value not in unit["source_anchor"]["heading"]
        assert unsafe_value not in unit["summary"]
PY
then
  PRIVACY_OK=0
fi

fresh_case unsafe-source-locator
mutate_manifest unsafe-source-locator "$SAMPLE_PRIVATE_URL" "$CASE_MANIFEST"
if intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" >/dev/null 2>&1; then
  PRIVACY_OK=0
fi
fresh_case unsafe-target-ref
if intake link --manifest "$CASE_MANIFEST" --unit U4 --state materialized \
     --target-ref "$SAMPLE_MACHINE_PATH_ALT" >/dev/null 2>&1; then
  PRIVACY_OK=0
fi
fresh_case unsafe-evidence-ref
if intake link --manifest "$CASE_MANIFEST" --unit U4 --state queued \
     --evidence "$SAMPLE_PRIVATE_URL_ALT" --evidence "$SAMPLE_CREDENTIAL_ALT" >/dev/null 2>&1; then
  PRIVACY_OK=0
fi
[ "$PRIVACY_OK" -eq 1 ] || record_review_fix_failure "privacy-redaction"

# 3. Markdown-looking lines inside fenced or indented code are not execution units.
CODE_SOURCE="$WORK/code-regions.md"
CODE_MANIFEST="$WORK/2026-07-12-code-regions.json"
python3 - "$CODE_SOURCE" <<'PY'
import sys
text = """# Wrapper
```markdown
## U90 - fenced heading
**B90 - fenced bold**
1. U91 - fenced numbered
- [ ] fenced checklist
```
~~~text
## U92 - tilde-fenced heading
**B91 - tilde-fenced bold**
1. U93 - tilde-fenced numbered
- [ ] tilde-fenced checklist
~~~
    **B92 - indented bold**
    1. U94 - indented numbered
    - [ ] indented checklist
## U1 - real heading
real body
**B1 - real bold**
real tail
"""
open(sys.argv[1], "w", encoding="utf-8", newline="").write(text)
PY
CODE_REGIONS_OK=1
if ! intake extract --source "$CODE_SOURCE" --out "$CODE_MANIFEST" --goal complete \
     --plugin-version 4.1.0 >/dev/null 2>&1; then
  CODE_REGIONS_OK=0
elif ! python3 - "$CODE_MANIFEST" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["expected_unit_ids"] == ["B1", "U1"]
by_id = {unit["id"]: unit for unit in data["units"]}
assert by_id["U1"]["source_anchor"] == {
    "heading": "U1 - real heading", "line_start": 17, "line_end": 18
}
assert by_id["B1"]["source_anchor"] == {
    "heading": "B1 - real bold", "line_start": 19, "line_end": 20
}
PY
then
  CODE_REGIONS_OK=0
fi
[ "$CODE_REGIONS_OK" -eq 1 ] || record_review_fix_failure "code-regions"

# 4. Malformed unclassified dispositions must use the helper's deterministic exit-2 contract.
fresh_case malformed-disposition
mutate_manifest malformed-unclassified U4 "$CASE_MANIFEST"
MALFORMED_OUTPUT="$(intake status --manifest "$CASE_MANIFEST" --json 2>&1)"
MALFORMED_RC=$?
MALFORMED_OK=1
case "$MALFORMED_OUTPUT" in
  *"idc-intake: FAIL — unit U4.disposition must be a JSON object"*) ;;
  *) MALFORMED_OK=0 ;;
esac
if [ "$MALFORMED_RC" -ne 2 ] || printf '%s' "$MALFORMED_OUTPUT" | grep -q "Traceback"; then
  MALFORMED_OK=0
fi
[ "$MALFORMED_OK" -eq 1 ] || record_review_fix_failure "malformed-disposition"

[ -z "$REVIEW_FIX_FAILURES" ] \
  || gov_fail "Task 4 review regressions failed: $REVIEW_FIX_FAILURES"

# Review round 2 RED probes: report all four independent-review findings in one baseline run.
# 1. A review of the complete manifest must not survive coordinated removal from both exact-once lists.
CONTENT_BINDING_OK=1
fresh_case coordinated-removal
mutate_manifest coordinated-remove B2 "$CASE_MANIFEST"
if intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" >/dev/null 2>&1; then
  CONTENT_BINDING_OK=0
fi
fresh_case coordinated-removal-status
mutate_manifest coordinated-remove B2 "$CASE_MANIFEST"
if intake status --manifest "$CASE_MANIFEST" --json >/dev/null 2>&1; then
  CONTENT_BINDING_OK=0
fi
[ "$CONTENT_BINDING_OK" -eq 1 ] || record_round2_failure "review-content-binding"

# 2. A nested task item is an execution unit; visually similar fenced/indented code remains inert.
NESTED_SOURCE="$WORK/nested-checklist.md"
NESTED_MANIFEST="$WORK/2026-07-12-nested-checklist.json"
python3 - "$NESTED_SOURCE" <<'PY'
import sys
text = """# Wrapper
- Parent list item
    - [ ] nested execution item
      nested body
Paragraph ends list context.

    - [ ] indented code sample

```markdown
- [ ] fenced code sample
```
## U1 - real heading
real body
"""
open(sys.argv[1], "w", encoding="utf-8", newline="").write(text)
PY
NESTED_OK=1
if ! intake extract --source "$NESTED_SOURCE" --out "$NESTED_MANIFEST" --goal complete \
     --plugin-version 4.1.0 >/dev/null 2>&1; then
  NESTED_OK=0
elif ! python3 - "$NESTED_MANIFEST" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["expected_unit_ids"] == ["L3", "U1"]
by_id = {unit["id"]: unit for unit in data["units"]}
assert by_id["L3"]["source_anchor"] == {
    "heading": "nested execution item", "line_start": 3, "line_end": 11
}
assert by_id["U1"]["source_anchor"] == {
    "heading": "U1 - real heading", "line_start": 12, "line_end": 13
}
PY
then
  NESTED_OK=0
fi
[ "$NESTED_OK" -eq 1 ] || record_round2_failure "nested-checklist"

# 3. Manifest string-list privacy applies to operator_stops too.
fresh_case unsafe-operator-stop
mutate_manifest unsafe-operator-stop U4 "$CASE_MANIFEST"
if intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" >/dev/null 2>&1; then
  record_round2_failure "operator-stops-privacy"
fi

# 4. Every unclassified disposition field must be shape-safe before status consumes it.
ROUND2_DISPOSITION_OK=1
fresh_case malformed-unclassified-evidence
mutate_manifest malformed-unclassified-evidence U4 "$CASE_MANIFEST"
status_must_fail_cleanly "unit U4.disposition.evidence must be a list of non-empty strings" \
  || ROUND2_DISPOSITION_OK=0
fresh_case malformed-unclassified-target
mutate_manifest malformed-unclassified-target U4 "$CASE_MANIFEST"
status_must_fail_cleanly "unit U4 target_ref must be a non-empty string or null" \
  || ROUND2_DISPOSITION_OK=0
fresh_case malformed-unclassified-state
mutate_manifest malformed-unclassified-state U4 "$CASE_MANIFEST"
status_must_fail_cleanly "unit U4 has invalid disposition state []" \
  || ROUND2_DISPOSITION_OK=0
[ "$ROUND2_DISPOSITION_OK" -eq 1 ] || record_round2_failure "unclassified-disposition-shape"

[ -z "$ROUND2_FAILURES" ] \
  || gov_fail "Task 4 review round 2 regressions failed: $ROUND2_FAILURES"

# Review round 3 RED probes: collect every adjudicated finding before changing production code.
# 1. The published review schema has exactly eight fields; content binding lives in its real path.
ROUND3_SCHEMA_DIR="$WORK/round3-canonical-schema"
mkdir -p "$ROUND3_SCHEMA_DIR" || gov_fail "could not create canonical review case"
ROUND3_SCHEMA_MANIFEST="$ROUND3_SCHEMA_DIR/2026-07-12-example.json"
cp "$COMPLETE" "$ROUND3_SCHEMA_MANIFEST" || gov_fail "could not copy canonical review manifest"
ROUND3_SCHEMA_REVIEW="$(canonical_review_path "$ROUND3_SCHEMA_MANIFEST" "$ROUND3_SCHEMA_DIR")" \
  || gov_fail "could not calculate canonical review path"
write_canonical_review "$ROUND3_SCHEMA_MANIFEST" "$ROUND3_SCHEMA_REVIEW" \
  || gov_fail "could not write canonical review"
if ! python3 - "$ROUND3_SCHEMA_REVIEW" <<'PY' >/dev/null 2>&1
import json, sys
review = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(review) == {
    "schema_version", "intake_id", "source_sha256", "verdict",
    "missing_unit_ids", "duplicate_unit_ids", "misrouted_unit_ids", "notes",
}
PY
then
  gov_fail "canonical review fixture does not have exactly eight fields"
fi
if ! intake validate --manifest "$ROUND3_SCHEMA_MANIFEST" \
     --review "$ROUND3_SCHEMA_REVIEW" >/dev/null 2>&1; then
  record_round3_failure "canonical-review-schema"
fi

# 2. Removing only the exact-set gate must let missing B2 through, proving no stale binding masks it.
ROUND3_SABOTAGE_DIR="$WORK/round3-exact-set-sabotage"
mkdir -p "$ROUND3_SABOTAGE_DIR" || gov_fail "could not create exact-set sabotage case"
ROUND3_SABOTAGE_MANIFEST="$ROUND3_SABOTAGE_DIR/2026-07-12-example.json"
cp "$COMPLETE" "$ROUND3_SABOTAGE_MANIFEST" \
  || gov_fail "could not copy exact-set sabotage manifest"
drop_unit B2 "$ROUND3_SABOTAGE_MANIFEST"
ROUND3_SABOTAGE_REVIEW="$(canonical_review_path \
  "$ROUND3_SABOTAGE_MANIFEST" "$ROUND3_SABOTAGE_DIR")" \
  || gov_fail "could not calculate exact-set sabotage review path"
write_canonical_review "$ROUND3_SABOTAGE_MANIFEST" "$ROUND3_SABOTAGE_REVIEW" \
  || gov_fail "could not write exact-set sabotage review"
ROUND3_SABOTAGED_INTAKE="$WORK/idc-intake-without-exact-set.py"
python3 - "$INTAKE" "$ROUND3_SABOTAGED_INTAKE" <<'PY' \
  || gov_fail "could not prepare exact-set sabotage helper"
import sys
source, destination = sys.argv[1:]
text = open(source, encoding="utf-8").read()
needle = '''    if missing or extra:
        raise IntakeError(f"manifest exact-once unit mismatch (missing={missing}, extra={extra})")
'''
assert text.count(needle) == 1
open(destination, "w", encoding="utf-8").write(text.replace(needle, "", 1))
PY
if ! python3 "$ROUND3_SABOTAGED_INTAKE" validate \
     --manifest "$ROUND3_SABOTAGE_MANIFEST" --review "$ROUND3_SABOTAGE_REVIEW" \
     >/dev/null 2>&1; then
  record_round3_failure "negative-validator-reasons"
fi

# 3. Even an absolute source path with a credential-shaped basename must persist only safe text.
ROUND3_PRIVATE_BASENAME="SERVICE_API_KEY=sample-sensitive-value.md"
ROUND3_PRIVATE_SOURCE="$WORK/$ROUND3_PRIVATE_BASENAME"
ROUND3_PRIVATE_MANIFEST="$WORK/2026-07-12-private-basename.json"
python3 - "$ROUND3_PRIVATE_SOURCE" <<'PY'
import sys
open(sys.argv[1], "w", encoding="utf-8").write("## U1 - safe unit\nbody\n")
PY
ROUND3_BASENAME_OK=1
if ! intake extract --source "$ROUND3_PRIVATE_SOURCE" --out "$ROUND3_PRIVATE_MANIFEST" \
     --goal complete --plugin-version 4.1.0 >/dev/null 2>&1; then
  ROUND3_BASENAME_OK=0
elif ! python3 - "$ROUND3_PRIVATE_MANIFEST" "$ROUND3_PRIVATE_BASENAME" \
       <<'PY' >/dev/null 2>&1
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
display_name = manifest["source"]["display_name"]
assert sys.argv[2] not in display_name
assert "[REDACTED_CREDENTIAL]" in display_name
PY
then
  ROUND3_BASENAME_OK=0
fi
[ "$ROUND3_BASENAME_OK" -eq 1 ] || record_round3_failure "source-basename-privacy"

# 4. Every malformed class/route container or scalar must use the clean exit-2 contract.
ROUND3_CLASS_ROUTE_OK=1
for FIELD in class route; do
  for SHAPE in '[]' '{}' '42'; do
    fresh_case "round3-$FIELD-$(printf '%s' "$SHAPE" | tr -cd '[:alnum:]')"
    set_unit_json_field U4 "$FIELD" "$SHAPE" "$CASE_MANIFEST"
    status_must_fail_cleanly "unit U4 $FIELD must be a string" \
      || ROUND3_CLASS_ROUTE_OK=0
  done
done
[ "$ROUND3_CLASS_ROUTE_OK" -eq 1 ] || record_round3_failure "class-route-shape"

[ -z "$ROUND3_FAILURES" ] \
  || gov_fail "Task 4 review round 3 regressions failed: $ROUND3_FAILURES"

# Review round 4 RED probes: collect all three findings before production changes.
# 1. Numbered checklists and nested numbered labels are work; code-shaped controls stay inert.
ROUND4_NUMBERED_SOURCE="$WORK/round4-numbered-units.md"
ROUND4_NUMBERED_MANIFEST="$WORK/2026-07-12-round4-numbered-units.json"
python3 - "$ROUND4_NUMBERED_SOURCE" <<'PY'
import sys
text = """# Wrapper
1. [ ] top numbered checklist
top body
- Parent list item
    1. U7 - nested numbered unit
       nested body
Paragraph ends list context.

    1. U90 - genuine indented code
    1. [ ] genuine indented checklist code
```markdown
1. [ ] fenced checklist
- Parent
    1. U91 - fenced nested number
```
## U1 - real heading
real body
"""
open(sys.argv[1], "w", encoding="utf-8", newline="").write(text)
PY
ROUND4_NUMBERED_OK=1
if ! intake extract --source "$ROUND4_NUMBERED_SOURCE" --out "$ROUND4_NUMBERED_MANIFEST" \
     --goal complete --plugin-version 4.1.0 >/dev/null 2>&1; then
  ROUND4_NUMBERED_OK=0
elif ! python3 - "$ROUND4_NUMBERED_MANIFEST" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["expected_unit_ids"] == ["L2", "U1", "U7"]
by_id = {unit["id"]: unit for unit in data["units"]}
assert by_id["L2"]["source_anchor"] == {
    "heading": "top numbered checklist", "line_start": 2, "line_end": 4,
}
assert by_id["U7"]["source_anchor"] == {
    "heading": "U7 - nested numbered unit", "line_start": 5, "line_end": 15,
}
assert by_id["U1"]["source_anchor"] == {
    "heading": "U1 - real heading", "line_start": 16, "line_end": 17,
}
assert "U90" not in by_id and "U91" not in by_id
PY
then
  ROUND4_NUMBERED_OK=0
fi
[ "$ROUND4_NUMBERED_OK" -eq 1 ] || record_round4_failure "numbered-unit-extraction"

# 2. Every immutable field shown to the reviewer invalidates a stale content-addressed PASS path.
ROUND4_BINDING_OK=1
for MUTATION in reviewed-anchor-heading reviewed-anchor-range reviewed-summary reviewed-operator-goal; do
  fresh_case "round4-$MUTATION"
  mutate_manifest "$MUTATION" U4 "$CASE_MANIFEST"
  status_must_fail_cleanly "manifest.verification.review_path basename must be" \
    || ROUND4_BINDING_OK=0
done
fresh_case round4-reviewed-operator-stop
mutate_manifest add-reviewed-operator-stop U4 "$CASE_MANIFEST"
refresh_case_review
intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" >/dev/null \
  || gov_fail "could not prepare reviewed operator-stop case"
mutate_manifest remove-reviewed-operator-stop U4 "$CASE_MANIFEST"
status_must_fail_cleanly "manifest.verification.review_path basename must be" \
  || ROUND4_BINDING_OK=0
[ "$ROUND4_BINDING_OK" -eq 1 ] || record_round4_failure "review-immutable-content-binding"

# 3. AWS_SECRET_ACCESS_KEY assignments are credentials; nearby AWS_REGION text is harmless.
ROUND4_AWS_SECRET="AWS_SECRET_ACCESS_KEY=sample-sensitive-value"
ROUND4_AWS_CONTROL="AWS_REGION=us-east-1"
ROUND4_AWS_SOURCE="$WORK/round4-aws-secret.md"
ROUND4_AWS_MANIFEST="$WORK/2026-07-12-round4-aws-secret.json"
python3 - "$ROUND4_AWS_SOURCE" "$ROUND4_AWS_CONTROL" "$ROUND4_AWS_SECRET" <<'PY'
import sys
path, control, secret = sys.argv[1:]
open(path, "w", encoding="utf-8", newline="").write(
    f"## U1 - configure {control}\nbody\n## U2 - use {secret}\nbody\n"
)
PY
ROUND4_AWS_OK=1
if ! intake extract --source "$ROUND4_AWS_SOURCE" --out "$ROUND4_AWS_MANIFEST" \
     --goal "Keep $ROUND4_AWS_CONTROL; use $ROUND4_AWS_SECRET" \
     --plugin-version 4.1.0 >/dev/null 2>&1; then
  ROUND4_AWS_OK=0
elif ! python3 - "$ROUND4_AWS_MANIFEST" "$ROUND4_AWS_CONTROL" "$ROUND4_AWS_SECRET" \
       <<'PY' >/dev/null 2>&1
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
control, secret = sys.argv[2:]
serialized = json.dumps(manifest, sort_keys=True)
assert secret not in serialized
assert control in serialized
assert "[REDACTED_CREDENTIAL]" in manifest["operator_goal"]["verbatim_or_redacted"]
assert manifest["operator_goal"]["redactions"] == ["credential"]
by_id = {unit["id"]: unit for unit in manifest["units"]}
assert control in by_id["U1"]["source_anchor"]["heading"]
assert "[REDACTED_CREDENTIAL]" in by_id["U2"]["source_anchor"]["heading"]
PY
then
  ROUND4_AWS_OK=0
fi
[ "$ROUND4_AWS_OK" -eq 1 ] || record_round4_failure "aws-secret-privacy"

[ -z "$ROUND4_FAILURES" ] \
  || gov_fail "Task 4 review round 4 regressions failed: $ROUND4_FAILURES"

fresh_case missing-b2
drop_unit B2 "$CASE_MANIFEST"
must_fail_manifest "manifest exact-once unit mismatch" \
  "missing B2 did not fail the exact-once validator"

fresh_case duplicate-u3
mutate_manifest duplicate U3 "$CASE_MANIFEST"
must_fail_manifest "manifest.units contains duplicate ids" \
  "duplicate U3 did not fail the duplicate-id validator"

fresh_case build-route
set_route U4 build "$CASE_MANIFEST"
must_fail_manifest "unit U4 may not route directly to build" \
  "foreign unit did not fail the direct-Build route validator"

fresh_case autorun-route
set_route U4 autorun "$CASE_MANIFEST"
must_fail_manifest "unit U4 may not route directly to autorun" \
  "foreign unit did not fail the direct-Autorun route validator"

fresh_case bad-class-route
mutate_manifest bad-class-route U4 "$CASE_MANIFEST"
must_fail_manifest "unit U4 class new_requirement cannot route to 'recirculate'" \
  "invalid class/route pair did not fail its validator"

fresh_case unknown-dependency
mutate_manifest unknown-dependency U4 "$CASE_MANIFEST"
must_fail_manifest "unit U4 names unknown dependencies" \
  "unknown dependency did not fail its validator"

fresh_case dependency-cycle
mutate_manifest cycle ignored "$CASE_MANIFEST"
must_fail_manifest "dependency cycle detected" \
  "dependency cycle did not fail its validator"

fresh_case stale-review
mutate_review hash "$(printf '0%.0s' {1..64})" "$CASE_REVIEW"
must_fail_reviewed "review source_sha256 does not match manifest source" \
  "stale review hash passed"

fresh_case wrong-intake
mutate_review intake 2026-07-12-other "$CASE_REVIEW"
must_fail_reviewed "review intake_id does not match manifest" \
  "review for another intake passed"

fresh_case nonpass-review
mutate_review verdict FAIL "$CASE_REVIEW"
must_fail_reviewed "review verdict must be PASS" "non-PASS review passed"

fresh_case review-findings
mutate_review finding U4 "$CASE_REVIEW"
must_fail_reviewed "review.missing_unit_ids must be empty for PASS" \
  "review with findings passed"

fresh_case absolute-source
mutate_manifest absolute-source ignored "$CASE_MANIFEST"
must_fail_manifest "manifest.source.repo_relative_locator must never be absolute" \
  "absolute source locator passed"

fresh_case no-target
mutate_manifest no-target U4 "$CASE_MANIFEST"
must_fail_manifest "unit U4 materialized disposition requires target_ref" \
  "unit with neither target nor explicit queued state passed"

fresh_case done-no-evidence
mutate_manifest done-without-evidence U4 "$CASE_MANIFEST"
must_fail_manifest "unit U4 verified_done disposition requires evidence" \
  "already-done unit without evidence passed"

fresh_case ignored-no-reason
mutate_manifest ignored-without-reason U4 "$CASE_MANIFEST"
must_fail_manifest "unit U4 ignored disposition requires a reason in evidence" \
  "ignored unit without a reason passed"

fresh_case self-certified
mutate_manifest self-certified ignored "$CASE_MANIFEST"
if intake validate --manifest "$CASE_MANIFEST" >/dev/null 2>&1; then
  gov_fail "manifest self-certified by editing verification.status"
fi

# link updates one unit's durable disposition; status reports the verified intake without touching a tracker.
fresh_case link
intake link --manifest "$CASE_MANIFEST" --unit U4 --state materialized \
  --target-ref recirc-ticket:42 --evidence ticket:42 --evidence journal:42 >/dev/null \
  || gov_fail "link could not materialize U4"
intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" >/dev/null \
  || gov_fail "linked manifest no longer validates"
STATUS_JSON="$(intake status --manifest "$CASE_MANIFEST" --json)" \
  || gov_fail "status failed on linked manifest"
STATUS_JSON="$STATUS_JSON" python3 - <<'PY' || gov_fail "link/status receipt was wrong"
import json, os
data = json.loads(os.environ["STATUS_JSON"])
assert data["intake_id"] == "2026-07-12-example"
assert data["verification_status"] == "passed"
assert data["disposition_counts"]["materialized"] == 1
assert "U4" not in data["queued_unit_ids"]
assert data["complete"] is False
PY
if intake link --manifest "$CASE_MANIFEST" --unit NOPE --state queued >/dev/null 2>&1; then
  gov_fail "link accepted an unknown unit"
fi

# Hash the ORIGINAL CRLF bytes while parsing normalized LF lines.
CRLF_SOURCE="$WORK/crlf.md"
CRLF_MANIFEST="$WORK/2026-07-12-crlf.json"
python3 - "$FIXTURE/external-plan.md" "$CRLF_SOURCE" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(raw.replace(b"\n", b"\r\n"))
PY
intake extract --source "$CRLF_SOURCE" --out "$CRLF_MANIFEST" --goal complete \
  --plugin-version 4.1.0 >/dev/null || gov_fail "CRLF extraction failed"
python3 - "$CRLF_SOURCE" "$CRLF_MANIFEST" <<'PY' || gov_fail "CRLF hash did not bind original bytes"
import hashlib, json, sys
raw = open(sys.argv[1], "rb").read()
data = json.load(open(sys.argv[2], encoding="utf-8"))
assert data["source"]["sha256"] == hashlib.sha256(raw).hexdigest()
assert len(data["expected_unit_ids"]) == 12
PY

# Stable L<line> candidates, natural ordering, and exact source ranges.
ANCHOR_SOURCE="$WORK/anchors.md"
ANCHOR_MANIFEST="$WORK/2026-07-12-anchors.json"
python3 - "$ANCHOR_SOURCE" <<'PY'
import sys
text = """# Wrapper
intro
## Phase Alpha
phase body
- [ ] unchecked action
action body
## Step Beta
step body
## Gate Review
gate body
## Stop Approval
stop body
## U10 - later
u10 body
**U2 - earlier**
u2 body
1. B1 - numbered
end
"""
open(sys.argv[1], "w", encoding="utf-8", newline="").write(text)
PY
intake extract --source "$ANCHOR_SOURCE" --out "$ANCHOR_MANIFEST" --goal complete \
  --plugin-version 4.1.0 >/dev/null || gov_fail "stable-anchor extraction failed"
python3 - "$ANCHOR_MANIFEST" <<'PY' || gov_fail "stable anchors/natural sort/source ranges were wrong"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["expected_unit_ids"] == ["B1", "L3", "L5", "L7", "L9", "L11", "U2", "U10"]
by_id = {unit["id"]: unit for unit in data["units"]}
assert by_id["L3"]["source_anchor"] == {"heading": "Phase Alpha", "line_start": 3, "line_end": 4}
assert by_id["L5"]["source_anchor"]["line_end"] == 6
assert by_id["B1"]["source_anchor"] == {"heading": "B1 - numbered", "line_start": 17,
                                         "line_end": 18}
PY

# Duplicate explicit IDs are refused during extraction, before a manifest can be created.
DUP_SOURCE="$WORK/duplicate.md"
python3 - "$ANCHOR_SOURCE" "$DUP_SOURCE" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(text + "\n## U2 - duplicate\n")
PY
if intake extract --source "$DUP_SOURCE" --out "$WORK/2026-07-12-duplicate.json" --goal complete \
     --plugin-version 4.1.0 >/dev/null 2>&1; then
  gov_fail "duplicate explicit source IDs passed extraction"
fi

echo "PASS: external Markdown compiles to an exact-once, independently reviewed intake manifest with strict routes, dependencies, safe locators, stable anchors, and durable dispositions"
