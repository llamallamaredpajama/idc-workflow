#!/bin/bash
# next-action-truth.sh — Task 5 durable-state next-action oracle regression.
#
# Every case owns a fresh governed filesystem repo. The oracle must derive its answer only from a
# validated active intake manifest and the structured tracker state; a loose Markdown file is never
# execution authority. The scenario pins the exact reason/command truth table, Think precedence over
# a busy downstream pipe, multi-lane Autorun selection, fail-closed corruption, and the public frozen
# dataclass interface.
#
# Usage: /bin/bash tests/smoke/governance/next-action-truth.sh
set -uo pipefail
# Dynamic repo-relative source, shared by governance scenarios.
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

ORACLE="$GOV_PLUGIN/scripts/idc_next_action.py"
INTAKE="$GOV_PLUGIN/scripts/idc_intake_manifest.py"
DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
[ -f "$ORACLE" ] || gov_fail "scripts/idc_next_action.py not found"
[ -f "$INTAKE" ] || gov_fail "scripts/idc_intake_manifest.py not found"
[ -f "$DRAIN" ] || gov_fail "scripts/idc_autorun_drain.py not found"

WORK="$(mktemp -d)" || gov_fail "could not create temp workspace"
trap 'rm -rf "$WORK"' EXIT

new_repo() {
  local name="$1" repo="$WORK/$1"
  mkdir -p "$repo/docs/workflow/intakes" || gov_fail "could not create repo $name"
  printf 'backend: filesystem\n' > "$repo/docs/workflow/tracker-config.yaml"
  python3 "$GOV_TRK" --tracker "$repo/TRACKER.md" init >/dev/null \
    || gov_fail "could not initialize tracker for $name"
  printf '%s' "$repo"
}

# seed_intake <repo> <slug> <unit-id> <class>
# Creates a classified, queued, independently reviewed manifest through the real Task 4 helper.
seed_intake() {
  local repo="$1" slug="$2" unit_id="$3" unit_class="$4"
  local canonical_slug
  canonical_slug="$(printf '%s' "$slug" | tr '_' '-')"
  local source="$repo/$canonical_slug.md"
  local manifest="$repo/docs/workflow/intakes/2026-07-14-$canonical_slug.json"
  local supplied_review="$repo/docs/workflow/intakes/$slug-supplied-review.json"
  local route="recirculate"
  [ "$unit_class" = "new_requirement" ] && route="think"
  printf '# %s - durable unit\n\nEvidence only.\n' "$unit_id" > "$source"
  python3 "$INTAKE" extract --source "$source" --out "$manifest" \
    --goal "route $unit_id truthfully" --plugin-version 4.1.0 >/dev/null \
    || gov_fail "could not extract intake $slug"
  python3 - "$manifest" "$unit_class" "$route" <<'PY'
import json, os, sys, tempfile
path, unit_class, route = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
unit = data["units"][0]
unit.update({"class": unit_class, "route": route, "dependencies": [], "operator_stops": []})
unit["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".next-action-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, path)
PY
  python3 - "$INTAKE" "$manifest" "$supplied_review" <<'PY'
import importlib.util, json, sys
helper_path, manifest_path, review_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_intake_manifest_for_next_action", helper_path)
assert spec is not None and spec.loader is not None
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
manifest = json.load(open(manifest_path, encoding="utf-8"))
review = {
    "schema_version": 1,
    "intake_id": manifest["intake_id"],
    "source_sha256": manifest["source"]["sha256"],
    "verdict": "PASS",
    "missing_unit_ids": [],
    "duplicate_unit_ids": [],
    "misrouted_unit_ids": [],
    "notes": [f"manifest_content_sha256={helper._manifest_content_sha256(manifest)}"],
}
with open(review_path, "w", encoding="utf-8") as handle:
    json.dump(review, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  python3 "$INTAKE" validate --manifest "$manifest" --review "$supplied_review" --json >/dev/null \
    || gov_fail "could not validate intake $slug"
  rm -f "$supplied_review"
  printf '%s' "$manifest"
}

run_oracle() {
  local repo="$1"
  ORACLE_OUT="$WORK/oracle-out.json"
  ORACLE_ERR="$WORK/oracle-err.txt"
  python3 "$ORACLE" --repo "$repo" --json >"$ORACLE_OUT" 2>"$ORACLE_ERR"
  ORACLE_RC=$?
}

run_oracle_from_repo() {
  local repo="$1"
  ORACLE_OUT="$WORK/oracle-out.json"
  ORACLE_ERR="$WORK/oracle-err.txt"
  (cd "$repo" && python3 "$ORACLE" --repo "$repo" --json) >"$ORACLE_OUT" 2>"$ORACLE_ERR"
  ORACLE_RC=$?
}

# assert_action <expected-rc> <reason-code> <command-or-__NULL__> [expected-count-key=count]
assert_action() {
  local expected_rc="$1" reason="$2" command="$3" count="${4:-}"
  [ "$ORACLE_RC" -eq "$expected_rc" ] || gov_fail \
    "expected oracle exit $expected_rc for $reason, got $ORACLE_RC ($(tr '\n' '|' < "$ORACLE_ERR"))"
  python3 - "$ORACLE_OUT" "$reason" "$command" "$count" <<'PY' || gov_fail \
"oracle result mismatch for $reason: $(tr '\n' '|' < "$ORACLE_OUT")"
import json, sys
path, reason, expected_command, count = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
assert set(data) == {"verdict", "reason_code", "command", "refs", "counts"}, data
assert data["reason_code"] == reason, data
expected = None if expected_command == "__NULL__" else expected_command
assert data["command"] == expected, data
assert isinstance(data["refs"], list), data
assert set(data["counts"]) == {
    "intake_think", "intake_recirc", "recirc_tickets", "considerations",
    "eligible_buildables", "waiting_gates",
}, data
assert all(isinstance(value, int) and value >= 0 for value in data["counts"].values()), data
if count:
    key, value = count.split("=", 1)
    assert data["counts"][key] == int(value), data
PY
}

# Review regressions are collected in one run while the prior implementation is still in place.
# These helpers record every mismatch and defer the final failure until all cases ran.
REVIEW_FAILURES=""
record_review_failure() {
  local label="$1" detail="$2"
  echo "RED[$label]: $detail"
  if [ -n "$REVIEW_FAILURES" ]; then
    REVIEW_FAILURES="$REVIEW_FAILURES,$label"
  else
    REVIEW_FAILURES="$label"
  fi
}

review_expect_action() {
  local label="$1" expected_rc="$2" reason="$3" command="$4"
  local expected actual json_rc stderr_head
  expected="$reason|$command"
  actual="$(python3 - "$ORACLE_OUT" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(2)
command = "__NULL__" if data.get("command") is None else data.get("command")
print(f"{data.get('reason_code')}|{command}")
PY
)"
  json_rc=$?
  if [ "$ORACLE_RC" -eq "$expected_rc" ] && [ "$json_rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
    return
  fi
  stderr_head="$(sed -n '1p' "$ORACLE_ERR")"
  [ -n "$actual" ] || actual="<no-json>"
  [ -n "$stderr_head" ] || stderr_head="<empty>"
  record_review_failure "$label" \
    "expected exit=$expected_rc result=$expected; got exit=$ORACLE_RC result=$actual stderr=$stderr_head"
}

review_expect_observer_clean() {
  local label="$1" repo="$2" gitignore_mode="$3" gitignore_before="${4:-}"
  local detail="" artifacts stderr_text
  stderr_text="$(tr '\n' '|' < "$ORACLE_ERR")"
  if [ -n "$stderr_text" ]; then
    detail="stderr=$stderr_text"
  fi
  artifacts="$(find "$repo" -maxdepth 1 -name '.idc-drain-verdict.json*' -print | sort)"
  if [ -n "$artifacts" ]; then
    [ -z "$detail" ] || detail="$detail; "
    detail="${detail}verdict-artifacts=$(printf '%s' "$artifacts" | tr '\n' '|')"
  fi
  if [ "$gitignore_mode" = "absent" ]; then
    if [ -e "$repo/.gitignore" ] || [ -L "$repo/.gitignore" ]; then
      [ -z "$detail" ] || detail="$detail; "
      detail="${detail}.gitignore-created"
    fi
  elif ! cmp -s "$gitignore_before" "$repo/.gitignore"; then
    [ -z "$detail" ] || detail="$detail; "
    detail="${detail}.gitignore-altered"
  fi
  if [ -n "$detail" ]; then
    record_review_failure "$label" "read-only governed-cwd observer entered persistence path: $detail"
  fi
}

review_expect_counts() {
  local label="$1" first="$2" second="$3"
  if ! python3 - "$ORACLE_OUT" "$first" "$second" <<'PY'
import json, sys
path, first, second = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(2)
for encoded in (first, second):
    key, value = encoded.split("=", 1)
    if data.get("counts", {}).get(key) != int(value):
        raise SystemExit(2)
PY
  then
    record_review_failure "$label" \
      "expected counts $first,$second; got $(tr '\n' '|' < "$ORACLE_OUT")"
  fi
}

review_real_root_persistence() {
  local label="$1" repo="$2" fake_bin="$3" session="$4"
  local expected detail="" pass out err rc json_rc gitignore_count temp_artifacts
  expected="$(printf 'eligible: \nrecirc_inbox: 0\nunplanned_considerations: 0\ndrain: complete\n')"
  for pass in 1 2; do
    out="$WORK/real-drain-$pass.out"
    err="$WORK/real-drain-$pass.err"
    (cd "$repo" && PATH="$fake_bin:$PATH" python3 "$DRAIN" --backend github \
      --owner owner --project 10 --repo "$repo" --session-id "$session") >"$out" 2>"$err"
    rc=$?
    if [ "$rc" -ne 0 ] || [ "$(cat "$out")" != "$expected" ] || [ -s "$err" ]; then
      [ -z "$detail" ] || detail="$detail; "
      detail="${detail}pass$pass rc=$rc stdout=$(tr '\n' '|' < "$out") stderr=$(tr '\n' '|' < "$err")"
    fi
  done
  python3 - "$repo/.idc-drain-verdict.json" "$session" <<'PY'
import json, sys
path, session = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(2)
assert set(data) == {"version", "verdict", "exit", "session_id", "ts"}, data
assert data["version"] == 1, data
assert data["verdict"] == "complete", data
assert data["exit"] == 0, data
assert data["session_id"] == session, data
assert isinstance(data["ts"], (int, float)), data
PY
  json_rc=$?
  if [ "$json_rc" -ne 0 ]; then
    [ -z "$detail" ] || detail="$detail; "
    detail="${detail}missing-or-invalid-verdict"
  fi
  gitignore_count="$(grep -c '^\.idc-drain-verdict\.json\*$' "$repo/.gitignore" 2>/dev/null)"
  gitignore_count="${gitignore_count:-0}"
  if [ "$gitignore_count" -ne 1 ]; then
    [ -z "$detail" ] || detail="$detail; "
    detail="${detail}gitignore-entry-count=$gitignore_count"
  fi
  temp_artifacts="$(find "$repo" -maxdepth 1 -name '.idc-drain-verdict.*.tmp' -print)"
  if [ -n "$temp_artifacts" ]; then
    [ -z "$detail" ] || detail="$detail; "
    detail="${detail}temp-artifacts=$(printf '%s' "$temp_artifacts" | tr '\n' '|')"
  fi
  if [ -n "$detail" ]; then
    record_review_failure "$label" "concrete-root Autorun persistence failed: $detail"
  fi
}

# Public Python interface: exact frozen dataclass field order and decide(repo) return type.
INTERFACE_REPO="$(new_repo interface)"
python3 - "$ORACLE" "$INTERFACE_REPO" <<'PY' || gov_fail "public WorkflowState/NextAction interface drifted"
import dataclasses, importlib.util, sys, typing
path, repo = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_next_action_for_test", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert [field.name for field in dataclasses.fields(module.WorkflowState)] == [
    "intake_think", "intake_recirc", "recirc_tickets", "considerations",
    "eligible_buildables", "waiting_gates",
]
assert [field.name for field in dataclasses.fields(module.NextAction)] == [
    "verdict", "reason_code", "command", "refs", "counts",
]
assert typing.get_type_hints(module.WorkflowState) == {
    "intake_think": tuple[str, ...],
    "intake_recirc": tuple[str, ...],
    "recirc_tickets": tuple[int, ...],
    "considerations": tuple[int, ...],
    "eligible_buildables": tuple[int, ...],
    "waiting_gates": tuple[int, ...],
}
assert typing.get_type_hints(module.NextAction) == {
    "verdict": str,
    "reason_code": str,
    "command": str | None,
    "refs": tuple[str, ...],
    "counts": dict[str, int],
}
assert module.WorkflowState.__dataclass_params__.frozen is True
assert module.NextAction.__dataclass_params__.frozen is True
result = module.decide(repo)
assert isinstance(result, module.NextAction)
state = module.WorkflowState((), (), (), (), (), ())
for obj, field, value in ((state, "intake_think", ("changed",)),
                          (result, "reason_code", "mutated")):
    try:
        setattr(obj, field, value)
    except dataclasses.FrozenInstanceError:
        pass
    else:
        raise AssertionError(f"{type(obj).__name__} is not frozen")
PY

# 1. A queued new requirement always returns Think with the exact manifest and unit.
R="$(new_repo think)"
M="$(seed_intake "$R" think U1 new_requirement)"
run_oracle "$R"
assert_action 0 intake-needs-think \
  "/idc:think --doc docs/workflow/intakes/$(basename "$M") --unit U1" "intake_think=1"

# Think must win even when every downstream lane is simultaneously actionable.
gov_seed_item "$R/TRACKER.md" --title 'recirculation inbox' --stage Recirculation --status Todo >/dev/null
gov_seed_item "$R/TRACKER.md" --title 'admitted consideration' --stage Consideration --status Todo >/dev/null
gov_seed_item "$R/TRACKER.md" --title 'eligible buildable' --stage Buildable --status Todo >/dev/null
run_oracle "$R"
assert_action 0 intake-needs-think \
  "/idc:think --doc docs/workflow/intakes/$(basename "$M") --unit U1" "intake_think=1"

# 2a/2b. Both allowed queued recirculation classes route to the precise manifest#unit.
for class_name in admitted_unplanned discovered_drift; do
  R="$(new_repo "intake-$class_name")"
  M="$(seed_intake "$R" "$class_name" U2 "$class_name")"
  run_oracle "$R"
  assert_action 0 intake-needs-recirculation \
    "/idc:recirculate docs/workflow/intakes/$(basename "$M")#U2" "intake_recirc=1"
done

# 3. A tracker Recirculation/Todo inbox ticket routes to bare Recirculate.
R="$(new_repo recirc-inbox)"
gov_seed_item "$R/TRACKER.md" --title 'recirculation inbox' --stage Recirculation --status Todo >/dev/null
run_oracle "$R"
assert_action 0 recirculation-inbox /idc:recirculate "recirc_tickets=1"

# 4. An admitted undecomposed Consideration/Todo routes to Plan.
R="$(new_repo consideration)"
gov_seed_item "$R/TRACKER.md" --title 'admitted consideration' --stage Consideration --status Todo >/dev/null
run_oracle "$R"
assert_action 0 admitted-consideration /idc:plan "considerations=1"

# 5. Only eligible Buildable/Todo work routes to Build.
R="$(new_repo buildable)"
gov_seed_item "$R/TRACKER.md" --title 'eligible buildable' --stage Buildable --status Todo >/dev/null
run_oracle "$R"
assert_action 0 eligible-buildable /idc:build "eligible_buildables=1"

# 6. Any two downstream lanes select Autorun before a single lane. Pin all three pairs.
for pair in recirc-plan recirc-build plan-build; do
  R="$(new_repo "multi-$pair")"
  case "$pair" in
    recirc-plan)
      gov_seed_item "$R/TRACKER.md" --title recirc --stage Recirculation --status Todo >/dev/null
      gov_seed_item "$R/TRACKER.md" --title plan --stage Consideration --status Todo >/dev/null
      ;;
    recirc-build)
      gov_seed_item "$R/TRACKER.md" --title recirc --stage Recirculation --status Todo >/dev/null
      gov_seed_item "$R/TRACKER.md" --title build --stage Buildable --status Todo >/dev/null
      ;;
    plan-build)
      gov_seed_item "$R/TRACKER.md" --title plan --stage Consideration --status Todo >/dev/null
      gov_seed_item "$R/TRACKER.md" --title build --stage Buildable --status Todo >/dev/null
      ;;
  esac
  run_oracle "$R"
  assert_action 0 multi-lane-actionable /idc:autorun
done

# Queued-intake Recirculation is the same downstream lane as a tracker inbox ticket. Combining that
# durable intake lane with Plan or Build must also select Autorun; removing `state.intake_recirc`
# from the lane calculation makes both cases fail while the tracker-only pairs above stay green.
for downstream in plan build; do
  R="$(new_repo "multi-intake-recirc-$downstream")"
  seed_intake "$R" "intake-recirc-$downstream" U3 admitted_unplanned >/dev/null
  if [ "$downstream" = "plan" ]; then
    gov_seed_item "$R/TRACKER.md" --title plan --stage Consideration --status Todo >/dev/null
  else
    gov_seed_item "$R/TRACKER.md" --title build --stage Buildable --status Todo >/dev/null
  fi
  run_oracle "$R"
  assert_action 0 multi-lane-actionable /idc:autorun "intake_recirc=1"
done

# 7. Only an open operator gate is an honest human wait, never build work.
R="$(new_repo gate)"
gov_seed_item "$R/TRACKER.md" --title '[operator-action] approve requirements' \
  --stage Buildable --status Todo >/dev/null
run_oracle "$R"
assert_action 0 waiting-human-gate __NULL__ "waiting_gates=1"

# The operator marker owns the item regardless of its Stage. Gates accidentally filed in either
# upstream Todo lane must still wait for the human and must never become automated Recirculate/Plan
# work. Collect both mismatches in one RED run against the prior implementation.
for gate_stage in Recirculation Consideration; do
  R="$(new_repo "gate-$gate_stage")"
  gov_seed_item "$R/TRACKER.md" --title '[operator-action] approve upstream decision' \
    --stage "$gate_stage" --status Todo >/dev/null
  run_oracle "$R"
  review_expect_action "operator-gate-$gate_stage" 0 waiting-human-gate __NULL__
  if [ "$gate_stage" = "Recirculation" ]; then
    review_expect_counts "operator-gate-$gate_stage-counts" waiting_gates=1 recirc_tickets=0
  else
    review_expect_counts "operator-gate-$gate_stage-counts" waiting_gates=1 considerations=0
  fi
done

# 8. A truly empty board is a fixpoint and can never invent Recirculate, Build, or Autorun.
R="$(new_repo empty)"
run_oracle "$R"
assert_action 0 fixpoint __NULL__
python3 - "$ORACLE_OUT" <<'PY' || gov_fail "empty board invented a downstream action"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["command"] not in ("/idc:recirculate", "/idc:build", "/idc:autorun"), data
PY

# A loose foreign Markdown artifact is evidence only. Without a validated manifest it stays fixpoint.
printf '# U8 - loose foreign plan\n\nDo not execute this directly.\n' > "$R/foreign-plan.md"
run_oracle "$R"
assert_action 0 fixpoint __NULL__

# 9. A corrupt manifest fails closed with the exact invalid-intake reason and exit 2.
R="$(new_repo corrupt-intake)"
printf '{"schema_version":1,"units":[' > \
  "$R/docs/workflow/intakes/2026-07-14-corrupt.json"
run_oracle "$R"
assert_action 2 invalid-intake __NULL__

# The intake store itself is durable state. A non-directory or broken locator must fail closed rather
# than be mistaken for an absent/empty intake store.
for storage_kind in regular-file broken-path; do
  R="$(new_repo "corrupt-intake-store-$storage_kind")"
  rm -rf "$R/docs/workflow/intakes"
  if [ "$storage_kind" = "regular-file" ]; then
    printf 'not a directory\n' > "$R/docs/workflow/intakes"
  else
    ln -s "$R/missing-intake-target" "$R/docs/workflow/intakes" \
      || gov_fail "could not seed broken intake path"
  fi
  run_oracle "$R"
  review_expect_action "intake-store-$storage_kind" 2 invalid-intake __NULL__
done

# Invalid UTF-8 in a canonical manifest must be deterministic invalid-intake JSON, never a Python
# UnicodeDecodeError traceback with exit 1.
R="$(new_repo corrupt-intake-utf8)"
printf '\377' > "$R/docs/workflow/intakes/2026-07-14-invalid-utf8.json"
run_oracle "$R"
review_expect_action intake-invalid-utf8 2 invalid-intake __NULL__

# Tracker corruption also fails closed under the documented invalid-state exit contract.
R="$(new_repo corrupt-tracker)"
printf '%s\n' '<!-- idc-tracker-state:begin -->' '```json' '{"next_number":1}' '```' \
  '<!-- idc-tracker-state:end -->' > "$R/TRACKER.md"
run_oracle "$R"
assert_action 2 invalid-tracker __NULL__

# JSON booleans are Python ints, but they are not valid issue identities. Pin both positions where
# accepting `true` would corrupt the dependency graph: as an issue number and as a blocker that
# falsely aliases issue #1.
R="$(new_repo corrupt-tracker-boolean-number)"
printf '%s\n' '<!-- idc-tracker-state:begin -->' '```json' \
  '{"next_number":2,"issues":[{"number":true,"title":"boolean issue","status":"Todo","stage":"Buildable","blocked_by":[]}]}' \
  '```' '<!-- idc-tracker-state:end -->' > "$R/TRACKER.md"
run_oracle "$R"
review_expect_action tracker-boolean-number 2 invalid-tracker __NULL__

R="$(new_repo corrupt-tracker-boolean-blocker)"
printf '%s\n' '<!-- idc-tracker-state:begin -->' '```json' \
  '{"next_number":3,"issues":[{"number":1,"title":"done upstream","status":"Done","stage":"Buildable","blocked_by":[]},{"number":2,"title":"boolean-blocked child","status":"Todo","stage":"Buildable","blocked_by":[true]}]}' \
  '```' '<!-- idc-tracker-state:end -->' > "$R/TRACKER.md"
run_oracle "$R"
review_expect_action tracker-boolean-blocker 2 invalid-tracker __NULL__

# A genuinely absent tracker config preserves the brief's legacy filesystem default.
R="$(new_repo absent-tracker-config)"
rm -f "$R/docs/workflow/tracker-config.yaml"
run_oracle "$R"
assert_action 0 fixpoint __NULL__

# An existing-but-invalid config locator is corruption, not legacy absence.
for config_kind in directory dangling-symlink; do
  R="$(new_repo "corrupt-tracker-config-$config_kind")"
  rm -f "$R/docs/workflow/tracker-config.yaml"
  if [ "$config_kind" = "directory" ]; then
    mkdir "$R/docs/workflow/tracker-config.yaml" \
      || gov_fail "could not seed tracker config directory"
  else
    ln -s "$R/missing-tracker-config" "$R/docs/workflow/tracker-config.yaml" \
      || gov_fail "could not seed dangling tracker config"
  fi
  run_oracle "$R"
  review_expect_action "tracker-config-$config_kind" 2 invalid-tracker __NULL__
done

# Existing config content must be readable and name a backend. Invalid UTF-8 and a structurally
# empty config both fail closed instead of silently selecting filesystem.
R="$(new_repo corrupt-tracker-config-utf8)"
printf '\377' > "$R/docs/workflow/tracker-config.yaml"
run_oracle "$R"
review_expect_action tracker-config-invalid-utf8 2 invalid-tracker __NULL__

R="$(new_repo corrupt-tracker-config-content)"
printf 'project_number: 7\n' > "$R/docs/workflow/tracker-config.yaml"
run_oracle "$R"
review_expect_action tracker-config-invalid-content 2 invalid-tracker __NULL__

# Invalid UTF-8 in filesystem TRACKER.md must be invalid-tracker JSON, never a loader traceback.
R="$(new_repo corrupt-tracker-utf8)"
printf '\377' > "$R/TRACKER.md"
run_oracle "$R"
review_expect_action tracker-invalid-utf8 2 invalid-tracker __NULL__

# GitHub quota exhaustion retains the shared reader's distinct resumable exit 3. The preflight must
# stop before any board query; an unexpected fake-gh call makes the case fail rather than go hollow.
R="$(new_repo github-rate-limit)"
printf 'backend: github\nproject_number: 7\n' > "$R/docs/workflow/tracker-config.yaml"
mkdir -p "$R/fake-bin" || gov_fail "could not create fake gh directory"
# Literal shell source for the generated fake; expansion belongs to that later process.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' \
  'if [ "$1 $2" = "api rate_limit" ]; then' \
  '  printf '\''{"resources":{"graphql":{"remaining":0,"reset":1999999999}}}\n'\''' \
  '  exit 0' \
  'fi' \
  'echo "unexpected gh call: $*" >&2' \
  'exit 99' > "$R/fake-bin/gh"
chmod +x "$R/fake-bin/gh"
PATH="$R/fake-bin:$PATH" run_oracle "$R"
assert_action 3 rate-limited __NULL__

# A throttle encountered by the board reader (after repository identity succeeds) must also exit 3,
# but the observer must not emit Autorun's drain diagnostic or attempt its verdict sidecar write.
R="$(new_repo github-board-rate-limit)"
printf 'backend: github\nproject_number: 8\n' > "$R/docs/workflow/tracker-config.yaml"
mkdir -p "$R/fake-bin" || gov_fail "could not create board-rate fake gh directory"
# Literal shell source for the generated fake; expansion belongs to that later process.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' \
  'case "$1 $2" in' \
  '  "api rate_limit")' \
  '    printf '\''{"resources":{"graphql":{"remaining":100,"reset":1999999999}}}\n'\''' \
  '    exit 0' \
  '    ;;' \
  '  "repo view")' \
  '    printf '\''owner/repo\n'\''' \
  '    exit 0' \
  '    ;;' \
  '  "project view")' \
  '    echo "API rate limit exceeded" >&2' \
  '    exit 1' \
  '    ;;' \
  'esac' \
  'echo "unexpected gh call: $*" >&2' \
  'exit 99' > "$R/fake-bin/gh"
chmod +x "$R/fake-bin/gh"
rm -f "$R/.gitignore"
PATH="$R/fake-bin:$PATH" run_oracle_from_repo "$R"
review_expect_action github-board-rate-limit 3 rate-limited __NULL__
review_expect_observer_clean github-board-observer-persistence "$R" absent

# A dependency lookup is part of the complete GitHub state read. If #2's blocked_by read is throttled,
# exit 3 must dominate even though #1 would otherwise be eligible Build work.
R="$(new_repo github-dependency-rate-limit)"
printf 'backend: github\nproject_number: 9\n' > "$R/docs/workflow/tracker-config.yaml"
mkdir -p "$R/fake-bin" || gov_fail "could not create dependency-rate fake gh directory"
python3 - "$R/fake-bin/gh" <<'PY'
import json, os, sys

path = sys.argv[1]
source = r'''#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
if args[:2] == ["api", "rate_limit"]:
    print(json.dumps({"resources": {"graphql": {"remaining": 100, "reset": 1999999999}}}))
    raise SystemExit(0)
if args[:2] == ["repo", "view"]:
    print("owner/repo")
    raise SystemExit(0)
if args[:2] == ["project", "view"]:
    print("PVT_next_action_test")
    raise SystemExit(0)
if args[:2] == ["api", "graphql"]:
    def item(number):
        return {
            "id": f"PVTI_{number}",
            "fieldValues": {"nodes": [
                {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": "Todo",
                 "field": {"name": "Status"}},
                {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": "Buildable",
                 "field": {"name": "Stage"}},
            ]},
            "content": {"__typename": "Issue", "number": number,
                        "title": f"buildable {number}",
                        "repository": {"nameWithOwner": "owner/repo"}},
        }
    print(json.dumps({"data": {"node": {"items": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [item(1), item(2)],
    }}}}))
    raise SystemExit(0)
if args and args[0] == "api" and len(args) > 1 and "issues/1/" in args[1]:
    print("[]")
    raise SystemExit(0)
if args and args[0] == "api" and len(args) > 1 and "issues/2/" in args[1]:
    print("API rate limit exceeded", file=sys.stderr)
    raise SystemExit(1)
print(f"unexpected gh call: {' '.join(args)}", file=sys.stderr)
raise SystemExit(99)
'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(source)
os.chmod(path, 0o755)
PY
printf '# operator sentinel — observer must preserve this byte-for-byte\n' > "$R/.gitignore"
cp "$R/.gitignore" "$WORK/dependency-rate.gitignore.before"
PATH="$R/fake-bin:$PATH" run_oracle_from_repo "$R"
review_expect_action github-dependency-rate-limit 3 rate-limited __NULL__
review_expect_observer_clean github-dependency-observer-persistence "$R" existing \
  "$WORK/dependency-rate.gitignore.before"

# Exercise the real Autorun drain with a concrete governed root, not the oracle's explicit read-only
# mode. A healthy empty GitHub board must persist the exact complete verdict, atomically and
# idempotently, while preserving the drain's stdout/exit contract across two passes.
R="$(new_repo real-root-autorun-persistence)"
printf 'backend: github\nproject_number: 10\n' > "$R/docs/workflow/tracker-config.yaml"
mkdir -p "$R/fake-bin" || gov_fail "could not create real-root fake gh directory"
python3 - "$R/fake-bin/gh" <<'PY'
import os, sys

path = sys.argv[1]
source = r'''#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
if args[:2] == ["api", "rate_limit"]:
    print(json.dumps({"resources": {"graphql": {"remaining": 100, "reset": 1999999999}}}))
    raise SystemExit(0)
if args[:2] == ["project", "view"]:
    print("PVT_real_root")
    raise SystemExit(0)
if args[:2] == ["api", "graphql"]:
    print(json.dumps({"data": {"node": {"items": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [],
    }}}}))
    raise SystemExit(0)
print(f"unexpected gh call: {' '.join(args)}", file=sys.stderr)
raise SystemExit(99)
'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(source)
os.chmod(path, 0o755)
PY
review_real_root_persistence real-root-autorun-persistence "$R" "$R/fake-bin" \
  task5-real-root

if [ -n "$REVIEW_FAILURES" ]; then
  gov_fail "round-3 review regressions: $REVIEW_FAILURES"
fi

echo "PASS: durable next-action truth table — validated queued intake routes only to Think/Recirculate; Think outranks a busy downstream pipe; tracker and queued-intake Recirculation combine truthfully with Plan/Build for Autorun; exact frozen dataclass contracts hold; single lanes stay exact; every operator gate waits outside automated lanes; empty/foreign-Markdown state fixes at no action; corrupt intake storage/content and strict integer tracker identities fail closed; every GitHub throttle, including dependency reads beside eligible work, remains dominant resumable exit 3 without observer side effects; a real Autorun drain persists its exact complete verdict idempotently"
