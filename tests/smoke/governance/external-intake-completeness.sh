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
REVIEW="$WORK/2026-07-12-example.review.json"
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
import hashlib, json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
content = {
    "expected_unit_ids": manifest["expected_unit_ids"],
    "units": [
        {key: unit[key] for key in ("id", "class", "route", "dependencies")}
        for unit in manifest["units"]
    ],
}
content_sha256 = hashlib.sha256(json.dumps(
    content, ensure_ascii=False, separators=(",", ":"), sort_keys=True
).encode("utf-8")).hexdigest()
review = {"schema_version": 1, "intake_id": manifest["intake_id"],
          "source_sha256": manifest["source"]["sha256"],
          "manifest_content_sha256": content_sha256, "verdict": "PASS",
          "missing_unit_ids": [], "duplicate_unit_ids": [],
          "misrouted_unit_ids": [], "notes": []}
json.dump(review, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
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
  CASE_MANIFEST="$WORK/case-$1.json"
  CASE_REVIEW="$WORK/case-$1.review.json"
  cp "$COMPLETE" "$CASE_MANIFEST" || gov_fail "could not copy complete manifest for $1"
  cp "$GOOD_REVIEW" "$CASE_REVIEW" || gov_fail "could not copy passing review for $1"
}

must_fail_reviewed() {
  if intake validate --manifest "$CASE_MANIFEST" --review "$CASE_REVIEW" >/dev/null 2>&1; then
    gov_fail "$1"
  fi
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
write_passing_review "$MANIFEST" "$REVIEW"
intake validate --manifest "$MANIFEST" --review "$REVIEW" >/dev/null \
  || gov_fail "complete independently reviewed manifest failed"

python3 - "$MANIFEST" <<'PY' || gov_fail "passing review was not atomically stamped"
import json, os, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["verification"]["status"] == "passed"
assert data["verification"]["review_path"] == "2026-07-12-example.review.json"
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
cp "$GOOD_REVIEW" "$TAMPER_DIR/2026-07-12-example.review.json" \
  || gov_fail "could not copy tampered review"
mutate_review verdict FAIL "$TAMPER_DIR/2026-07-12-example.review.json"
if intake status --manifest "$TAMPER_DIR/2026-07-12-example.json" --json >/dev/null 2>&1; then
  REVIEW_BINDING_OK=0
fi

OUTSIDE_REVIEW="$WORK/../$(basename "$WORK")-outside.review.json"
cp "$GOOD_REVIEW" "$OUTSIDE_REVIEW" || gov_fail "could not create outside review case"
fresh_case outside-review
if intake validate --manifest "$CASE_MANIFEST" --review "$OUTSIDE_REVIEW" >/dev/null 2>&1; then
  REVIEW_BINDING_OK=0
fi
rm -f "$OUTSIDE_REVIEW"
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

fresh_case missing-b2
drop_unit B2 "$CASE_MANIFEST"
must_fail_reviewed "missing B2 passed exact-once validation"

fresh_case duplicate-u3
mutate_manifest duplicate U3 "$CASE_MANIFEST"
must_fail_reviewed "duplicate U3 passed exact-once validation"

fresh_case build-route
set_route U4 build "$CASE_MANIFEST"
must_fail_reviewed "foreign unit routed directly to Build"

fresh_case autorun-route
set_route U4 autorun "$CASE_MANIFEST"
must_fail_reviewed "foreign unit routed directly to Autorun"

fresh_case bad-class-route
mutate_manifest bad-class-route U4 "$CASE_MANIFEST"
must_fail_reviewed "invalid class/route pair passed"

fresh_case unknown-dependency
mutate_manifest unknown-dependency U4 "$CASE_MANIFEST"
must_fail_reviewed "unknown dependency passed"

fresh_case dependency-cycle
mutate_manifest cycle ignored "$CASE_MANIFEST"
must_fail_reviewed "dependency cycle passed"

fresh_case stale-review
mutate_review hash "$(printf '0%.0s' {1..64})" "$CASE_REVIEW"
must_fail_reviewed "stale review hash passed"

fresh_case wrong-intake
mutate_review intake 2026-07-12-other "$CASE_REVIEW"
must_fail_reviewed "review for another intake passed"

fresh_case nonpass-review
mutate_review verdict FAIL "$CASE_REVIEW"
must_fail_reviewed "non-PASS review passed"

fresh_case review-findings
mutate_review finding U4 "$CASE_REVIEW"
must_fail_reviewed "review with findings passed"

fresh_case absolute-source
mutate_manifest absolute-source ignored "$CASE_MANIFEST"
must_fail_reviewed "absolute source locator passed"

fresh_case no-target
mutate_manifest no-target U4 "$CASE_MANIFEST"
must_fail_reviewed "unit with neither target nor explicit queued state passed"

fresh_case done-no-evidence
mutate_manifest done-without-evidence U4 "$CASE_MANIFEST"
must_fail_reviewed "already-done unit without evidence passed"

fresh_case ignored-no-reason
mutate_manifest ignored-without-reason U4 "$CASE_MANIFEST"
must_fail_reviewed "ignored unit without a reason passed"

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
