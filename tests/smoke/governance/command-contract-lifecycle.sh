#!/bin/bash
# idc-assert-class: behavior
# command-contract-lifecycle.sh — the universal IDC command lifecycle envelope + the wave-3 EVIDENCE
# CONTRACT (Task 2 + Task 6). Every governed `/idc:*` command opens a lifecycle record in the session
# ledger at expansion and MUST close it with a valid terminal status; a `Stop` closeout gate refuses to
# let an agent walk away from an open command. Under the wave-3 claim table, EVERY terminal fact a
# closeout carries is RE-DERIVED from durable state (a re-run helper, a durable receipt/report/journal,
# a tracker/oracle read, or a real `gh` read) — a caller supplies only REFERENCE KEYS (a path, an
# issue/PR number, a unit id). This scenario pins the whole contract end-to-end on the filesystem
# backend (hermetic; a fake `gh` stub covers the real GitHub reads):
#
#   (1)-(6)   the universal envelope: idempotent start; Stop blocks an open command with the exact
#             finish remediation; an unknown/malformed status cannot clear it; a valid closeout ends
#             it; no foreign session can finish another's record; the finished-history cap.
#   (7)-(15)  the wave-3 evidence contract, per finding: think (F2), plan (F3), recirculate (F4),
#             uninstall (F5), the diagnostic/lifecycle commands (F6), blocked_external (F1), and the
#             incident-sized Think coverage regression (F7).
#
# Red-when-broken (MANDATORY, reviewed): every forged/omitting claim below is asserted to REFUSE, and
# every honest close to LAND — reverting any derivation to trust the caller flips a pair.
#
# Auto-discovered by the governance lane (phase-governance.sh); runnable standalone under python3.
# Usage: bash tests/smoke/governance/command-contract-lifecycle.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
CLOSEOUT_GATE="$GOV_PLUGIN/scripts/hooks/idc_command_closeout_gate.py"
INTAKE="$GOV_PLUGIN/scripts/idc_intake_manifest.py"
DV="$GOV_PLUGIN/scripts/hooks/idc_drain_verdict.py"
CR="$GOV_PLUGIN/scripts/hooks/idc_command_report.py"
RECEIPT="$GOV_PLUGIN/scripts/idc_receipt_check.py"
for f in "$CONTRACT" "$CLOSEOUT_GATE" "$INTAKE" "$DV" "$CR" "$RECEIPT"; do
  [ -f "$f" ] || gov_fail "required helper not found: $f (not implemented yet)"
done

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# The RUNNING plugin version (plugin.json). An install receipt's plugin_version is the freshness gate's
# REQUIRED version, so a receipt stamped ABOVE the running version makes `contract start` refuse as
# stale — every receipt-bearing test repo below stamps the RUNNING version so start is fresh.
RUN_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$GOV_PLUGIN/.claude-plugin/plugin.json")"
[ -n "$RUN_VER" ] || gov_fail "could not read the running plugin version from plugin.json"
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "could not init REPO board"
OUT="$WORK/out.json"
S1="s1-$$-$(basename "$WORK")"
S2="s2-$$-$(basename "$WORK")"
_MAX_FINISHED_EXPECT=20

contract() { python3 "$CONTRACT" "$@"; }
json_count() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(len(data.get(sys.argv[1], [])))' "$1"
}
stop_payload() {
  python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"cwd":sys.argv[2],"hook_event_name":"Stop","stop_hook_active":False}))' "$1" "$REPO"
}

# write_fake_gh <path> — the suite's hermetic `gh` stub on PATH (see next-action-truth.sh). It answers
# the READ-ONLY calls the wave-3 validators make:
#   * `gh pr view <N> --json state,mergedAt`  → MERGED when N in $FAKE_MERGED_PRS (space list), else
#     OPEN; $FAKE_PR_ERROR=1 makes it EXIT NONZERO (gh missing / an unresolvable PR).
#   * `gh issue view <N> --json body -q .body` → prints $FAKE_ISSUE_DIR/<N>.body, or EXITS NONZERO when
#     absent (a nonexistent gate/pointer/child).
write_fake_gh() {  # $1 = path to the fake gh
  python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
src = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] == ["pr", "view"] and len(args) >= 3:
    if os.environ.get("FAKE_PR_ERROR") == "1":
        sys.stderr.write("fake gh: pr read failed\n"); raise SystemExit(2)
    merged = set((os.environ.get("FAKE_MERGED_PRS") or "").split())
    if args[2] in merged:
        print(json.dumps({"state": "MERGED", "mergedAt": "2026-07-12T00:00:00Z"}))
    else:
        print(json.dumps({"state": "OPEN", "mergedAt": None}))
    raise SystemExit(0)
if args[:2] == ["issue", "view"] and len(args) >= 3:
    d = os.environ.get("FAKE_ISSUE_DIR") or ""
    p = os.path.join(d, args[2] + ".body") if d else ""
    if p and os.path.isfile(p):
        with open(p, encoding="utf-8") as h:
            sys.stdout.write(h.read())
        raise SystemExit(0)
    sys.stderr.write("fake gh: no Issue #%s\n" % args[2]); raise SystemExit(1)
sys.stderr.write("fake gh: unexpected call %s\n" % " ".join(args)); raise SystemExit(3)
'''
with open(path, "w", encoding="utf-8") as h:
    h.write(src)
os.chmod(path, 0o755)
PY
}
FAKE_BIN="$WORK/fake-bin"; mkdir -p "$FAKE_BIN" || gov_fail "could not make fake-bin"
write_fake_gh "$FAKE_BIN/gh"
gh_finish() { PATH="$FAKE_BIN:$PATH" contract finish "$@"; }

# journal_line <repo> <json> — append one raw NDJSON record to the repo's transition journal.
journal_line() {
  local jr="$1/docs/workflow/transition-journal.ndjson"
  mkdir -p "$(dirname "$jr")"
  printf '%s\n' "$2" >> "$jr"
}
# doctor_report <repo> <session> <verdict> — write THIS session's persisted doctor report.
doctor_report() {
  python3 "$CR" --cwd "$1" write --kind doctor --session "$2" \
    --payload-json "$(printf '{"rows":["1..10"],"verdict":"%s"}' "$3")" >/dev/null \
    || gov_fail "could not write doctor report"
}
# a consideration file that PASSES idc_consideration_check (H1 + function/PRD/TRD/open-questions).
write_consideration() {  # $1 = repo, $2 = repo-relative path
  local p="$1/$2"; mkdir -p "$(dirname "$p")"
  cat > "$p" <<'MD'
# Dark mode — Consideration

## What it does for the user

Users can toggle dark mode in Settings and it persists across sessions.

PRD impact: yes — a new user-facing appearance setting.
TRD impact: yes — a theme provider + a persisted preference.

## Open questions

- default follows OS at launch?
MD
}

# (1) start creates one active record and is idempotent for the same session+command.
contract start --repo "$REPO" --session "$S1" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'Drive first' --source user >/dev/null
contract start --repo "$REPO" --session "$S1" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'Drive first' --source user >/dev/null
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "start must upsert one active command record"
echo "  ok (1) start upserts exactly one active command record (idempotent)"

# (2) Stop blocks an active command with no closeout, and the block names the REAL absolute path to
# idc_command_contract.py under the plugin root the gate was given — NOT the literal token.
stop_payload "$S1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" > "$OUT"
grep -q '"decision": "block"' "$OUT" || gov_fail "active command escaped Stop"
grep -F -q "$GOV_PLUGIN/scripts/idc_command_contract.py" "$OUT" \
  || gov_fail "block remediation lacks the REAL absolute idc_command_contract.py path (literal/basename)"
grep -q 'idc_command_contract.py.*finish' "$OUT" || gov_fail "block lacks the exact finish remediation"
if grep -q 'CLAUDE_PLUGIN_ROOT' "$OUT"; then
  gov_fail "block remediation still emits the literal \${CLAUDE_PLUGIN_ROOT} token (not interpolated)"
fi
echo "  ok (2) Stop closeout gate blocks an open command + names the exact finish remediation (real absolute path)"

# (3) the record cannot be cleared with an unknown or malformed status (status guard, isolated).
if contract finish --repo "$REPO" --session "$S1" --command think --status done \
  --evidence-json '{}'; then
  gov_fail "unrecognized status cleared the obligation"
fi
if contract finish --repo "$REPO" --session "$S1" --command think --status done \
  --evidence-json '{"schema_version":1,"refs":{}}'; then
  gov_fail "an unknown status with a valid envelope must still be rejected (status guard)"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "a rejected finish must leave the active record intact"
echo "  ok (3) an unknown/malformed terminal status cannot clear the obligation (status guard isolated)"

# (3.1) COMMON-ENVELOPE guards, isolated (the envelope check runs BEFORE the per-command claim table).
if contract finish --repo "$REPO" --session "$S1" --command think --status waiting_gate \
  --evidence-json '{"schema_version":true,"refs":{}}'; then
  gov_fail "(3.1a) schema_version: true (bool) was accepted as the integer 1"
fi
if contract finish --repo "$REPO" --session "$S1" --command think --status waiting_gate \
  --evidence-json '{"schema_version":1.0,"refs":{}}'; then
  gov_fail "(3.1b) schema_version: 1.0 (float) was accepted as the integer 1"
fi
if contract finish --repo "$REPO" --session "$S1" --command think --status waiting_gate \
  --evidence-json '{"schema_version":1,"refs":[]}'; then
  gov_fail "(3.1c) a non-object refs was accepted"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "rejected envelope finishes must leave the active record intact"
echo "  ok (3.1) common-envelope guards isolated: schema_version rejects true/1.0, refs must be an object"

# (4) a valid, command-specific closeout ends the command honestly → Stop no longer blocks. S1's open
# record is `think`; close it with an allowlisted blocked_external (idc_pr_finish.py belongs to think),
# a cheap real-derivation closeout, then prove Stop passes only when NO command is open.
contract finish --repo "$REPO" --session "$S1" --command think --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_pr_finish.py","exit":2,"diagnostic":"gate PR could not be opened"}}}' \
  || gov_fail "(4) could not close S1's think record via an allowlisted blocked_external"
stop_payload "$S1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" > "$OUT"
[ ! -s "$OUT" ] || gov_fail "(4) a valid closeout still blocked Stop"
echo "  ok (4) a valid closeout ends the command → Stop no longer blocks"

# (5) a different session cannot finish or inherit S1's ACTIVE record — isolated on OWNERSHIP. Open a
# fresh ACTIVE build record for S1, then have S2 attempt to finish it with a FULLY VALID closeout
# (build no_action is oracle-backed on REPO's empty board), so the ONLY possible rejection is ownership.
contract start --repo "$REPO" --session "$S1" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'build it' --source user >/dev/null
if contract finish --repo "$REPO" --session "$S2" --command build --status no_action \
  --evidence-json '{"schema_version":1,"refs":{}}'; then
  gov_fail "foreign session finished S1's active record despite a valid envelope (ownership not enforced)"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "the foreign finish attempt must leave S1's active build record intact"
# S1 closes its own build no_action (oracle-backed empty board) to not leak the record.
contract finish --repo "$REPO" --session "$S1" --command build --status no_action \
  --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null \
  || gov_fail "(5) S1 could not close its own oracle-backed build no_action"
echo "  ok (5) a foreign session cannot finish/inherit another session's active record (ownership isolated)"

# (6) the finished-history cap drops the OLDEST finished record and RETAINS the just-finished newest
# one. Uses an isolated ledger + doctor complete (a per-session report written just before each finish).
REPO2="$WORK/repo2"; mkdir -p "$REPO2/docs/workflow"
printf 'backend: filesystem\n' > "$REPO2/docs/workflow/tracker-config.yaml"
KEEP="keep-$$-$(basename "$WORK")"
contract start --repo "$REPO2" --session "$KEEP" --command doctor --plugin-root "$GOV_PLUGIN" \
  --args 'first in, last out' --source user >/dev/null
for i in $(seq -w 1 20); do
  SI="n${i}-$$-$(basename "$WORK")"
  contract start --repo "$REPO2" --session "$SI" --command doctor --plugin-root "$GOV_PLUGIN" \
    --args "fill $i" --source user >/dev/null
  doctor_report "$REPO2" "$SI" PASS
  contract finish --repo "$REPO2" --session "$SI" --command doctor --status complete \
    --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null \
    || gov_fail "(6) could not finish filler record $i"
done
doctor_report "$REPO2" "$KEEP" PASS
contract finish --repo "$REPO2" --session "$KEEP" --command doctor --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null \
  || gov_fail "(6) could not finish the KEEP record"
[ "$(contract status --repo "$REPO2" --json | json_count finished)" -eq "$_MAX_FINISHED_EXPECT" ] \
  || gov_fail "(6) finished history is not capped at $_MAX_FINISHED_EXPECT records"
contract status --repo "$REPO2" --json | grep -q "$KEEP" \
  || gov_fail "(6) newest-finish-retained: the just-finished record was pruned"
if contract status --repo "$REPO2" --json | grep -q "n01-$$-"; then
  gov_fail "(6) oldest-finished-dropped: the oldest finished record survived the cap"
fi
echo "  ok (6) the finished cap drops the OLDEST + retains the just-finished NEWEST record"

# ============================================================================================
# (7) Task 6 wave-3 — THE EVIDENCE CONTRACT. Each closeout re-derives every terminal fact from durable
# state; a caller supplies only reference keys. REPO3 carries a reviewed intake manifest (Drive+U1+U2),
# a passing consideration file, a fake-gh gate/pointer body, and a transition journal.
REPO3="$WORK/repo3"; mkdir -p "$REPO3/docs/workflow/intakes"
printf 'backend: filesystem\n' > "$REPO3/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO3/TRACKER.md" init >/dev/null || gov_fail "could not init REPO3 board"
S3="s3-$$-$(basename "$WORK")"
CONS_REL="docs/workflow/considerations/dark.md"
write_consideration "$REPO3" "$CONS_REL"
# fake-gh bodies: gate #708 carries EXACTLY ONE idc-gate-pr marker bound to Think PR #706; pointer #707 exists.
REPO3_ISSUES="$WORK/repo3-issues"; mkdir -p "$REPO3_ISSUES"
printf 'Gate body.\n<!-- idc-gate-pr: 706 -->\n' > "$REPO3_ISSUES/708.body"
printf 'Consideration pointer body.\n' > "$REPO3_ISSUES/707.body"
# journal: gate #708 disposed (gate-approved) + pointer #707 admitted (unblock) — the guarded doors.
journal_line "$REPO3" '{"op":"dispose","item":708,"disposition":"gate-approved","when":"2026-07-12T00:00:00Z","who":"t","what":"dispose #708 Blocked -> Done [gate-approved]"}'
journal_line "$REPO3" '{"op":"unblock","item":707,"when":"2026-07-12T00:00:01Z","who":"t","what":"unblock #707 Blocked -> Todo"}'

# Build a reviewed intake manifest (Drive + U1 + U2), materialize only Drive (U1/U2 stay queued).
SRC="$REPO3/life-plan.md"
MANIFEST="$REPO3/docs/workflow/intakes/2026-07-12-life.json"
MANIFEST_REL="docs/workflow/intakes/2026-07-12-life.json"
printf '# Drive - foundation\n\nbody\n\n## U1 - first unit\n\nbody\n\n## U2 - second unit\n\nbody\n' > "$SRC"
python3 "$INTAKE" extract --source "$SRC" --out "$MANIFEST" \
  --goal 'execute the whole program; Drive first' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "(7) intake extract failed"
classify_and_review() {  # $1 = manifest path -> classify all units route=think, write+validate a PASS review
  python3 - "$1" <<'PY' || gov_fail "(7) could not classify manifest"
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for unit in data["units"]:
    unit.update({"class": "new_requirement", "route": "think", "dependencies": [], "operator_stops": []})
    unit["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".cls-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as h:
    json.dump(data, h, indent=2, sort_keys=True); h.write("\n")
os.replace(tmp, path)
PY
  local rv="${1%.json}-review.json"
  python3 - "$INTAKE" "$1" "$rv" <<'PY' || gov_fail "(7) could not write review"
import importlib.util, json, sys
helper_path, manifest_path, review_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_intake_life", helper_path)
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
m = json.load(open(manifest_path, encoding="utf-8"))
review = {"schema_version": 1, "intake_id": m["intake_id"], "source_sha256": m["source"]["sha256"],
          "verdict": "PASS", "missing_unit_ids": [], "duplicate_unit_ids": [], "misrouted_unit_ids": [],
          "notes": [f"manifest_content_sha256={helper._manifest_content_sha256(m)}"]}
json.dump(review, open(review_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
  python3 "$INTAKE" validate --manifest "$1" --review "$rv" >/dev/null \
    || gov_fail "(7) could not validate reviewed manifest $1"
}
classify_and_review "$MANIFEST"
python3 "$INTAKE" link --manifest "$MANIFEST" --unit Drive --state materialized \
  --target-ref "think-pr:706" --evidence "gate:708" --evidence "pointer:707" >/dev/null \
  || gov_fail "(7) could not materialize Drive"

think_complete_ev() {  # $1 = manifest locator, $2 = selected JSON array
  printf '{"schema_version":1,"refs":{"consideration":"%s","think_pr":706,"gate":708,"pointer":707,"intake_manifest":"%s","intake_selected":%s}}' "$CONS_REL" "$1" "$2"
}

# (7a) a think complete: consideration re-checks PASS, coverage complete (Drive materialized, U1/U2
# queued), the Think PR reads MERGED (fake gh), the gate carries one bound marker + is disposed
# (journal), the pointer exists + is admitted (journal). Every fact re-derived, none trusted.
contract start --repo "$REPO3" --session "$S3" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'life' --source user >/dev/null
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
  --command think --status complete --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" \
  || gov_fail "(7a) a complete think whose every fact re-derives (consideration/coverage/PR/gate/pointer) was rejected"
echo "  ok (7a) think complete re-derives consideration + coverage + merged PR + bound-marker + gate disposal + pointer admission"

# (7a-sabotage) the Think PR merged-state is RE-READ (real gh): unmerged/unverifiable refuse.
contract start --repo "$REPO3" --session "$S3" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'life-unmerged' --source user >/dev/null
if FAKE_MERGED_PRS="" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" 2>/dev/null; then
  gov_fail "(7a-sabotage) a think complete whose Think PR reads NOT merged (real gh) was accepted"
fi
if FAKE_PR_ERROR=1 FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" 2>/dev/null; then
  gov_fail "(7a-sabotage) a think complete accepted an UNVERIFIABLE Think-PR merged-state (gh errored)"
fi
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
  --command think --status complete --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" >/dev/null \
  || gov_fail "(7a-sabotage) could not honestly close with a real MERGED gh read"
echo "  ok (7a-sabotage) think complete re-reads the Think PR merged-state (unmerged/unverifiable refused)"

# (7b, F2) each of the four re-derived think facts fails closed INDEPENDENTLY (finding 2). PR reads
# MERGED throughout so each sabotage reaches its own claim.
contract start --repo "$REPO3" --session "$S3" --command think --plugin-root "$GOV_PLUGIN" --args 'f2' --source user >/dev/null
# (i) a forged consideration 'pass' string (not a path) is refused — the checker is RE-RUN.
BOGUSCONS='{"schema_version":1,"refs":{"consideration":"pass","think_pr":706,"gate":708,"pointer":707,"intake_manifest":"'"$MANIFEST_REL"'","intake_selected":["Drive"]}}'
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$BOGUSCONS" 2>/dev/null; then
  gov_fail "(7b-i) a think complete carrying consideration:\"pass\" (a caller string, not a re-run) was accepted"
fi
# (ii) a gate whose body carries NO / a WRONG-bound marker is refused. Point at a gate (#799) that
# either does not exist or binds a different PR.
printf 'Gate with two markers.\n<!-- idc-gate-pr: 706 -->\n<!-- idc-gate-pr: 999 -->\n' > "$REPO3_ISSUES/799.body"
DOUBLE='{"schema_version":1,"refs":{"consideration":"'"$CONS_REL"'","think_pr":706,"gate":799,"pointer":707,"intake_manifest":"'"$MANIFEST_REL"'","intake_selected":["Drive"]}}'
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$DOUBLE" 2>/dev/null; then
  gov_fail "(7b-ii) a think complete whose gate body carries TWO idc-gate-pr markers was accepted"
fi
# (iii) a gate with NO journal dispose record is refused (gate #710 has a body+bound marker but no dispose).
printf 'Gate body.\n<!-- idc-gate-pr: 706 -->\n' > "$REPO3_ISSUES/710.body"
UNDISPOSED='{"schema_version":1,"refs":{"consideration":"'"$CONS_REL"'","think_pr":706,"gate":710,"pointer":707,"intake_manifest":"'"$MANIFEST_REL"'","intake_selected":["Drive"]}}'
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$UNDISPOSED" 2>/dev/null; then
  gov_fail "(7b-iii) a think complete whose gate has NO dispose/gate-approved journal record was accepted"
fi
# (iv) a pointer with NO journal unblock record is refused (pointer #720 has a body but no unblock).
printf 'pointer.\n' > "$REPO3_ISSUES/720.body"
UNADMITTED='{"schema_version":1,"refs":{"consideration":"'"$CONS_REL"'","think_pr":706,"gate":708,"pointer":720,"intake_manifest":"'"$MANIFEST_REL"'","intake_selected":["Drive"]}}'
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$UNADMITTED" 2>/dev/null; then
  gov_fail "(7b-iv) a think complete whose pointer has NO unblock journal record was accepted"
fi
[ "$(contract status --repo "$REPO3" --session "$S3" --json | json_count active)" -eq 1 ] \
  || gov_fail "(7b) the rejected sabotage finishes must leave the think record active"
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
  --command think --status complete --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" >/dev/null \
  || gov_fail "(7b) could not honestly close after the F2 sabotages"
echo "  ok (7b, F2) think re-derives consideration/marker-binding/gate-disposal/pointer-admission — each fails closed independently"

# (7b-drop / F7-shape) a think complete that materializes Drive but DROPS U1/U2 from the exact-once
# manifest is BLOCKED — the closeout re-reads the manifest and the drop fails validation.
DROP_MANIFEST="$REPO3/docs/workflow/intakes/2026-07-12-drop.json"
DROP_REL="docs/workflow/intakes/2026-07-12-drop.json"
python3 - "$MANIFEST" "$DROP_MANIFEST" <<'PY' || gov_fail "(7b-drop) could not build dropped manifest"
import json, sys
src, dst = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
data["units"] = [u for u in data["units"] if u["id"] == "Drive"]   # drop U1+U2 from units, keep in expected
data["intake_id"] = "2026-07-12-drop"
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
contract start --repo "$REPO3" --session "$S3" --command think --plugin-root "$GOV_PLUGIN" --args 'drop' --source user >/dev/null
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
     --command think --status complete --evidence-json "$(think_complete_ev "$DROP_REL" '["Drive"]')" 2>/dev/null; then
  gov_fail "(7b-drop) a think closeout that materialized Drive but dropped U1/U2 was ACCEPTED (coverage not re-verified)"
fi
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S3" \
  --command think --status complete --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" >/dev/null \
  || gov_fail "(7b-drop) could not honestly close the drop-case think record"
echo "  ok (7b-drop) a think closeout that drops units from the exact-once manifest is BLOCKED"

# (7c, F6-doctor) doctor complete is re-read from THIS session's persisted doctor report (a FAIL
# verdict is still a complete doctor run); a forged rows/verdict with NO report is refused; and a
# lifecycle command may not claim a pipeline no_action.
contract start --repo "$REPO3" --session "$S3" --command doctor --plugin-root "$GOV_PLUGIN" --args 'diag' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
     --evidence-json '{"schema_version":1,"refs":{"rows":["forged"],"verdict":"PASS"}}' 2>/dev/null; then
  gov_fail "(7c) a doctor complete with FORGED rows/verdict but NO persisted report was accepted"
fi
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status no_action \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(7c) doctor no_action (an illegal terminal status for a diagnostic command) was accepted"
fi
doctor_report "$REPO3" "$S3" FAIL
contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(7c) doctor complete backed by a persisted FAIL report was rejected"
echo "  ok (7c, F6) doctor complete re-reads the durable report (forged rows refused; a FAIL verdict still completes; no_action illegal)"

# (7d, F1) blocked_external: an allowlisted helper + NONZERO exit + diagnostic; a zero exit, a phantom
# helper, a helper NOT belonging to the command, and an invented/mismatched drain are all refused.
contract start --repo "$REPO3" --session "$S3" --command build --plugin-root "$GOV_PLUGIN" --args 'b' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_autorun_drain.py","exit":0,"diagnostic":"ok"}}}' 2>/dev/null; then
  gov_fail "(7d) a blocked_external with a ZERO helper exit was accepted"
fi
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"totally_not_a_real_helper.py","exit":3,"diagnostic":"phantom"}}}' 2>/dev/null; then
  gov_fail "(7d) a blocked_external citing a PHANTOM helper was accepted"
fi
# (F1a) a helper that does NOT belong to /idc:build (the janitor scanner) cannot close it.
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_git_janitor.py","exit":2,"diagnostic":"x"}}}' 2>/dev/null; then
  gov_fail "(7d, F1a) a build blocked_external citing the janitor scanner (not a build helper) was accepted"
fi
# an INVENTED drain (no persisted verdict) is refused.
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_autorun_drain.py","exit":3,"diagnostic":"rate-limited"}}}' 2>/dev/null; then
  gov_fail "(7d) an INVENTED drain blocked_external (no persisted verdict) was accepted"
fi
# persist a real non-complete drain verdict with exit 4, then a MISMATCHED cited exit (3) is refused (F1b).
python3 "$DV" --cwd "$REPO3" write --verdict unknown --exit 4 --session "$S3" \
  || gov_fail "(7d) could not persist a non-complete drain verdict"
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_autorun_drain.py","exit":3,"diagnostic":"rate-limited"}}}' 2>/dev/null; then
  gov_fail "(7d, F1b) a drain blocked_external whose cited exit (3) MISMATCHES the persisted exit (4) was accepted"
fi
# the MATCHING cited exit (4) re-derives + closes.
contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_autorun_drain.py","exit":4,"diagnostic":"github GraphQL rate-limited until reset"}}}' \
  || gov_fail "(7d) a drain blocked_external whose cited exit MATCHES the persisted verdict was rejected"
echo "  ok (7d, F1) blocked_external requires an ALLOWLISTED helper + nonzero exit + diagnostic; a drain blocker re-derives + MATCHES the durable verdict exit"

# (7e) autorun complete reads THIS session's PERSISTED drain: complete verdict — never a caller string.
python3 "$DV" --cwd "$REPO3" write --verdict complete --exit 0 --session "$S3" \
  || gov_fail "(7e) could not persist a drain verdict"
contract start --repo "$REPO3" --session "$S3" --command autorun --plugin-root "$GOV_PLUGIN" --args 'a' --source user >/dev/null
contract finish --repo "$REPO3" --session "$S3" --command autorun --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(7e) an autorun complete backed by THIS session's persisted drain: complete verdict was rejected"
python3 "$DV" --cwd "$REPO3" write --verdict complete --exit 0 --session "someone-else" >/dev/null
contract start --repo "$REPO3" --session "$S3" --command autorun --plugin-root "$GOV_PLUGIN" --args 'a2' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command autorun --status complete \
     --evidence-json "$(printf '{"schema_version":1,"refs":{"drain":"complete","drain_session":"%s"}}' "$S3")" 2>/dev/null; then
  gov_fail "(7e-sabotage) an autorun complete with a FORGED caller drain claim but a FOREIGN persisted verdict was ACCEPTED"
fi
python3 "$DV" --cwd "$REPO3" write --verdict complete --exit 0 --session "$S3" >/dev/null
contract finish --repo "$REPO3" --session "$S3" --command autorun --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null \
  || gov_fail "(7e-sabotage) could not honestly close the autorun record"
echo "  ok (7e) autorun complete is cleared only by THIS session's durable drain: complete verdict (forged/foreign refused)"

# ============================================================================================
# (7f, F3) plan complete re-derives: matrix re-validates, planning PR reads MERGED (real gh), the
# decomposition children exist, pointers_retired cross-checks the decomposed set, AND the required
# admitted-consideration set is independently re-derived (no admitted consideration remains un-planned).
REPO_PLAN="$WORK/repo-plan"; mkdir -p "$REPO_PLAN/docs/workflow/pillar-matrices"
printf 'backend: filesystem\n' > "$REPO_PLAN/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_PLAN/TRACKER.md" init >/dev/null || gov_fail "could not init REPO_PLAN"
python3 "$GOV_TRK" --tracker "$REPO_PLAN/TRACKER.md" create --title "consider dark mode" \
  --stage Consideration --status Todo >/dev/null || gov_fail "could not create consideration #1"
python3 "$GOV_TRK" --tracker "$REPO_PLAN/TRACKER.md" create --title "dark mode child" \
  --stage Buildable --status Todo >/dev/null || gov_fail "could not create child #2"
SP="sp-$$-$(basename "$WORK")"
GOODMX="docs/workflow/pillar-matrices/good.yaml"
cat > "$REPO_PLAN/$GOODMX" <<'YML'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/a/]
    blocks_on: []
  - id: pillar-b
    wave: 1
    domain: api
    surfaces: [src/b/]
    blocks_on: []
YML
plan_ev() {  # $1 = matrix, $2 = decompositions JSON, $3 = pointers_retired JSON
  printf '{"schema_version":1,"refs":{"matrix":"%s","planning_pr":42,"decompositions":%s,"pointers_retired":%s}}' "$1" "$2" "$3"
}
retire_pointer() { python3 "$GOV_TRK" --tracker "$REPO_PLAN/TRACKER.md" move --num "$1" --status Done >/dev/null; }
# (7f-omit / F3) with consideration #1 STILL admitted (Consideration/Todo) plan complete is refused —
# the required admitted set is re-derived from the tracker, not the caller's decompositions keys.
contract start --repo "$REPO_PLAN" --session "$SP" --command plan --plugin-root "$GOV_PLUGIN" --args 'omit' --source user >/dev/null
if FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"1":2}' '[1]')" 2>/dev/null; then
  gov_fail "(7f-omit) a plan complete leaving an admitted consideration un-planned (still on the board) was accepted"
fi
# retire the pointer (Plan's real advance moves it off the Consideration/Todo lane) → no admitted remains.
retire_pointer 1
FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
  --evidence-json "$(plan_ev "$GOODMX" '{"1":2}' '[1]')" \
  || gov_fail "(7f) a plan complete backed by matrix + MERGED PR + existing child + retired pointer + no-admitted-remaining was rejected"
echo "  ok (7f, F3) plan complete re-derives matrix + merged PR + children + retired pointers + the required admitted set (an omitted consideration refuses)"

# (7f-sabotage) each re-derived claim fails closed independently (children present so the reach is real).
python3 "$GOV_TRK" --tracker "$REPO_PLAN/TRACKER.md" create --title "second consideration" \
  --stage Consideration --status Todo >/dev/null || gov_fail "could not create consideration #3"
python3 "$GOV_TRK" --tracker "$REPO_PLAN/TRACKER.md" create --title "second child" \
  --stage Buildable --status Todo >/dev/null || gov_fail "could not create child #4"
contract start --repo "$REPO_PLAN" --session "$SP" --command plan --plugin-root "$GOV_PLUGIN" --args 'p2' --source user >/dev/null
# (i) planning PR NOT merged (real gh OPEN).
if FAKE_MERGED_PRS="" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"3":4}' '[3]')" 2>/dev/null; then
  gov_fail "(7f-sabotage) a plan complete whose planning PR reads NOT merged was accepted"
fi
# (ii) a decomposition child that does NOT exist on the tracker.
if FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"3":999}' '[3]')" 2>/dev/null; then
  gov_fail "(7f-sabotage) a plan complete naming a decomposition child ABSENT from the tracker was accepted"
fi
# (iii) pointers_retired EMPTY while a consideration was decomposed.
if FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"3":4}' '[]')" 2>/dev/null; then
  gov_fail "(7f-sabotage) a plan complete with pointers_retired:[] against a real decomposition was accepted"
fi
# (iv) a colliding matrix (same wave, shared surface).
BADMX="docs/workflow/pillar-matrices/collide.yaml"
cat > "$REPO_PLAN/$BADMX" <<'YML'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/x/]
    blocks_on: []
  - id: pillar-b
    wave: 1
    domain: ui
    surfaces: [src/x/]
    blocks_on: []
YML
if FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
     --evidence-json "$(plan_ev "$BADMX" '{"3":4}' '[3]')" 2>/dev/null; then
  gov_fail "(7f-sabotage) a plan complete whose matrix FAILS deconfliction was accepted"
fi
retire_pointer 3
FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_PLAN" --session "$SP" --command plan --status complete \
  --evidence-json "$(plan_ev "$GOODMX" '{"3":4}' '[3]')" >/dev/null \
  || gov_fail "(7f-sabotage) could not honestly close the plan record"
echo "  ok (7f-sabotage) plan complete fails closed on unmerged PR, missing child, empty pointers, colliding matrix"

# (7f-gh, F2/F3) on the GITHUB backend the child re-verification RE-RUNS the shipped github-only schema
# + provenance checks against each child's live body (exercised directly, since the hermetic oracle
# cannot read a github board). A schema-invalid body or an absent/mismatched provenance marker fails closed.
REPO_PLAN_GH="$WORK/repo-plan-gh"; mkdir -p "$REPO_PLAN_GH/docs/workflow/pillar-matrices"
printf 'backend: github\nproject_number: 10\n' > "$REPO_PLAN_GH/docs/workflow/tracker-config.yaml"
GHMX="docs/workflow/pillar-matrices/p1-matrix.yaml"
cat > "$REPO_PLAN_GH/$GHMX" <<'YML'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/a/]
    blocks_on: []
YML
ISSUE_DIR="$WORK/gh-issue-bodies"; mkdir -p "$ISSUE_DIR"
cat > "$ISSUE_DIR/2.body" <<'MD'
GOAL: Users can toggle dark mode in Settings and it persists across sessions.
VERIFICATION SURFACE: `pnpm test settings/theme` green; new test theme_persist.test added first (red→green).
CONSTRAINTS: existing settings unchanged; no new deps; no-punt — incidental fixes land here.
BOUNDARIES: touch src/settings/, src/theme/ ; off-limits src/auth/, src/billing/
ITERATION POLICY: record-and-vary
BLOCKED-STOP: halt after 3 failed hypotheses or on a missing design token; surface evidence.
ASSUMPTIONS: "System" follows OS at launch (vetoable).
---
Dependencies: blocked-by #0 (none)
Trace: pillars/dark-mode-toggle-plan.md · PRD §Appearance
<!-- idc-provenance: {"matrix":"p1-matrix.yaml","pillar":"pillar-a"} -->
MD
verify_children() {  # $1=repo $2=matrix $3=children-json ; prints ok / reject:<code>
  SCRIPTS_DIR="$GOV_PLUGIN/scripts" FAKE_ISSUE_DIR="$ISSUE_DIR" PATH="$FAKE_BIN:$PATH" \
    python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"]); sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"],"hooks"))
import idc_command_contract as cc
repo, matrix, children = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
res = cc._verify_decomposition(repo, matrix, children)
print("ok" if res.ok else f"reject:{res.reason_code}")
PY
}
[ "$(verify_children "$REPO_PLAN_GH" "$GHMX" '[2]')" = "ok" ] \
  || gov_fail "(7f-gh) a github child with a schema-valid, provenance-stamped body was rejected"
printf 'GOAL: make settings better\nBOUNDARIES: touch everything\n' > "$ISSUE_DIR/2.body"
[ "$(verify_children "$REPO_PLAN_GH" "$GHMX" '[2]')" != "ok" ] \
  || gov_fail "(7f-gh) a github child whose body FAILS the schema check was accepted"
[ "$(verify_children "$REPO_PLAN_GH" "$GHMX" '[404]')" != "ok" ] \
  || gov_fail "(7f-gh) a github child that does not exist (gh issue view errors) was accepted"
echo "  ok (7f-gh) github child re-verification re-runs schema + provenance on each live body (invalid/absent fail closed)"

# (8) an EMPTY session identity is refused fail-closed (Codex/Pi set no CLAUDE_CODE_SESSION_ID).
if contract start --repo "$REPO" --session "" --command think --plugin-root "$GOV_PLUGIN" \
     --args 'anon' --source codex 2>/dev/null; then
  gov_fail "(8) an empty session identity opened a command record (anonymous obligation)"
fi
anon_active=$(contract status --repo "$REPO" --json \
  | python3 -c 'import json,sys; print(sum(1 for c in json.load(sys.stdin)["active"] if not str(c.get("session_id","")).strip()))')
[ "$anon_active" -eq 0 ] || gov_fail "(8) an anonymous (session=\"\") active record was written to the ledger"
if contract finish --repo "$REPO" --session "" --command think --status waiting_gate \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(8) an empty session identity finished a command record"
fi
echo "  ok (8) an empty session identity is refused fail-closed (no anonymous record opened or finished)"

# ============================================================================================
# (9, F5) Uninstall derives its removal set from the INSTALL RECEIPT (never the caller's `removed`
# list); the destructive work must have happened before finish; only the anchor removal is post-finish.
REPO4="$WORK/repo4"; mkdir -p "$REPO4/docs/workflow" "$REPO4/.claude"
printf 'backend: filesystem\n' > "$REPO4/docs/workflow/tracker-config.yaml"   # the governance anchor
printf 'workflow\n' > "$REPO4/WORKFLOW.md"
printf 'machine\n' > "$REPO4/docs/workflow/workflow-machine.yaml"
printf 'idc data\n' > "$REPO4/TRACKER.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true},"theme":"dark"}\n' > "$REPO4/.claude/settings.json"
# stamp a real install receipt listing the footprints (WORKFLOW.md, workflow-machine.yaml, the anchor).
python3 "$RECEIPT" stamp --repo "$REPO4" --out "$REPO4/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/workflow-machine.yaml docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9) could not stamp the install receipt"
ARCHIVE_REL="idc-archive-20260712-000000.tar.gz"
S4="s4-$$-$(basename "$WORK")"
applied_ev() {  # the caller's `removed` list is now IRRELEVANT — the receipt is authoritative.
  printf '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"%s"}}' "$ARCHIVE_REL"
}

# (9-sabotage, THE F5 FIX) a finish claiming 'applied' while a RECEIPT footprint is STILL PRESENT is
# REFUSED — even when the caller supplies a dummy-absent `removed` path + a real archive (the bypass).
contract start --repo "$REPO4" --session "$S4" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall' --source user >/dev/null
: > "$REPO4/$ARCHIVE_REL"
BYPASS='{"schema_version":1,"refs":{"outcome":"applied","removed":["already-absent-dummy"],"settings":".claude/settings.json","archive":"'"$ARCHIVE_REL"'"}}'
if contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
     --evidence-json "$BYPASS" 2>/dev/null; then
  gov_fail "(9-sabotage, F5) an 'applied' uninstall was accepted via a dummy-absent 'removed' path while a RECEIPT footprint (WORKFLOW.md) was still present"
fi
# Now do the real destructive work EXCEPT the anchor: remove the receipt footprints + strip the key.
rm -f "$REPO4/WORKFLOW.md" "$REPO4/docs/workflow/workflow-machine.yaml" "$REPO4/TRACKER.md"
python3 "$GOV_PLUGIN/scripts/idc_settings_json.py" disable "$REPO4/.claude/settings.json" idc@idc-workflow >/dev/null \
  || gov_fail "(9) could not strip the enablement key"
# with the footprints gone but the archive missing, finish still refuses.
rm -f "$REPO4/$ARCHIVE_REL"
if contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
     --evidence-json "$(applied_ev)" 2>/dev/null; then
  gov_fail "(9-sabotage) an applied uninstall was accepted with a MISSING archive file"
fi
: > "$REPO4/$ARCHIVE_REL"
contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
  --evidence-json "$(applied_ev)" \
  || gov_fail "(9a) an uninstall finish whose receipt footprints are gone (settings stripped, archive present, anchor present) was rejected"
[ "$(contract status --repo "$REPO4" --session "$S4" --json | json_count active)" -eq 0 ] \
  || gov_fail "(9a) the uninstall record did not close on the verified finish"
echo "  ok (9, F5) uninstall derives the removal set from the receipt (a dummy-'removed' bypass with a footprint still present is REFUSED)"

# (9b) the governance anchor removal is the single POST-finish step (a post-anchor-removal finish cannot land).
contract start --repo "$REPO4" --session "$S4" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'u3' --source user >/dev/null
rm -f "$REPO4/docs/workflow/tracker-config.yaml"
if contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
     --evidence-json "$(applied_ev)" 2>/dev/null; then
  gov_fail "(9b) an uninstall finish AFTER the anchor was removed unexpectedly succeeded"
fi
echo "  ok (9b) the governance anchor removal is the single POST-finish step"

# (9c, F5 no-action) a no-action is PROVEN, never asserted: a receipt must enumerate the footprints and
# EVERY non-anchor footprint be already absent. A no-receipt no-action, and a no-action while a footprint
# is still present, are both refused; a governed repo whose receipt footprints are all absent accepts it.
REPO4B="$WORK/repo4b"; mkdir -p "$REPO4B/docs/workflow"
printf 'backend: filesystem\n' > "$REPO4B/docs/workflow/tracker-config.yaml"   # governed (finish can run)
printf 'workflow\n' > "$REPO4B/WORKFLOW.md"
S4B="s4b-$$-$(basename "$WORK")"
# (i) NO receipt → no-action cannot prove the filesystem is clean → refused (the RED-probe shape).
contract start --repo "$REPO4B" --session "$S4B" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'na' --source user >/dev/null
if contract finish --repo "$REPO4B" --session "$S4B" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9c-i) a uninstall no-action with NO install receipt (cannot prove the filesystem clean) was accepted"
fi
# (ii) a receipt whose footprint (WORKFLOW.md) is STILL PRESENT → there IS work → no-action refused.
python3 "$RECEIPT" stamp --repo "$REPO4B" --out "$REPO4B/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9c) could not stamp the REPO4B receipt"
if contract finish --repo "$REPO4B" --session "$S4B" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9c-ii) a uninstall no-action while a receipt footprint (WORKFLOW.md) is still present was accepted"
fi
# (iii) the footprint removed → every non-anchor receipt footprint absent → no-action accepted (the repo
# is still governed, so finish runs; the anchor removal is the post-finish step).
rm -f "$REPO4B/WORKFLOW.md"
contract finish --repo "$REPO4B" --session "$S4B" --command uninstall --status complete \
  --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' \
  || gov_fail "(9c-iii) a uninstall no-action whose receipt footprints are all absent was rejected"
echo "  ok (9c, F5) uninstall no-action is proven from the receipt (no-receipt + still-present-footprint refused; all-absent accepted)"

# ============================================================================================
# (10, F2) intake mode is DURABLE on the record: coverage is re-verified from the RECORD on EVERY path,
# even a finish that omits the intake fields, and INCLUDING waiting_gate.
S5="s5-$$-$(basename "$WORK")"
UNMAT_MANIFEST="$REPO3/docs/workflow/intakes/2026-07-12-unmat.json"
UNMAT_REL="docs/workflow/intakes/2026-07-12-unmat.json"
python3 "$INTAKE" extract --source "$SRC" --out "$UNMAT_MANIFEST" \
  --goal 'execute the whole program; Drive first' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "(10) intake extract failed"
classify_and_review "$UNMAT_MANIFEST"   # all units QUEUED (Drive NOT materialized)
# waiting_gate fixtures: gate #708 NOT-yet-disposed body + a NOT-yet-admitted pointer #730.
printf 'pointer, still blocked.\n' > "$REPO3_ISSUES/730.body"
UNDISP_JOURNAL_REPO="$REPO3"   # REPO3's journal has 708 disposed + 707 unblocked; use a fresh gate/pointer
printf 'Gate awaiting merge.\n<!-- idc-gate-pr: 706 -->\n' > "$REPO3_ISSUES/740.body"
think_bare_complete='{"schema_version":1,"refs":{"consideration":"'"$CONS_REL"'","think_pr":706,"gate":708,"pointer":707}}'
think_wait_ev='{"schema_version":1,"refs":{"consideration":"'"$CONS_REL"'","think_pr":706,"gate":740,"pointer":730}}'

# (10a) intake-mode record (--doc/--unit) + a bare complete that OMITS the intake fields, on a manifest
# whose selected unit Drive is NOT materialized → REFUSED (coverage re-read from the record).
contract start --repo "$REPO3" --session "$S5" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $UNMAT_REL --unit Drive" --source user >/dev/null
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S5" \
     --command think --status complete --evidence-json "$think_bare_complete" 2>/dev/null; then
  gov_fail "(10a) an intake-mode think closed WITHOUT materializing its selected unit by OMITTING the intake fields (the bypass)"
fi
[ "$(contract status --repo "$REPO3" --session "$S5" --json | json_count active)" -eq 1 ] \
  || gov_fail "(10a) the rejected bypass finish must leave the think record active"
echo "  ok (10a) an intake-mode record enforces coverage from the RECORD even when the finish omits the intake fields (complete)"

# (10c) the same bypass on the WAITING_GATE path is closed too (coverage runs on EVERY path).
contract start --repo "$REPO3" --session "$S5" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $UNMAT_REL --unit Drive" --source user >/dev/null
if FAKE_MERGED_PRS="" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S5" \
     --command think --status waiting_gate --evidence-json "$think_wait_ev" 2>/dev/null; then
  gov_fail "(10c) an intake-mode think WAITING_GATE closed WITHOUT materializing its selected unit"
fi
echo "  ok (10c) intake coverage is enforced on the waiting_gate path too"

# (10b) an intake-mode record with SATISFIED coverage still closes even when the finish omits the
# intake fields (they are read from the record). Reuse REPO3's $MANIFEST (Drive materialized).
contract start --repo "$REPO3" --session "$S5" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $MANIFEST_REL --unit Drive" --source user >/dev/null
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S5" \
  --command think --status complete --evidence-json "$think_bare_complete" \
  || gov_fail "(10b) an intake-mode think whose recorded coverage is satisfied was refused even though the finish omitted the intake fields"
echo "  ok (10b) an intake-mode record with satisfied coverage still closes honestly (coverage from the record)"

# (11) Think intake IDENTITY + MONOTONICITY.
# (11a) a plain anchor-doc Think (`--doc <anchor>`, no `--unit`) is NOT intake-mode: it closes with a
# bare complete (no coverage obligation was ever stamped).
ANCHOR_REL="anchor-note.md"
printf '# an ordinary anchor document\n\nnot an intake manifest\n' > "$REPO3/$ANCHOR_REL"
S7="s7-$$-$(basename "$WORK")"
contract start --repo "$REPO3" --session "$S7" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $ANCHOR_REL" --source user >/dev/null
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S7" \
  --command think --status complete --evidence-json "$think_bare_complete" \
  || gov_fail "(11a) a plain anchor-doc Think (--doc with NO --unit) was wrongly intake-stamped and could not close"
echo "  ok (11a) a plain anchor-doc Think (--doc, no --unit) is NOT intake-stamped and closes honestly"

# (11b) MONOTONICITY: an intake-mode start, then a PLAIN re-start, must carry the intake marker forward.
S8="s8-$$-$(basename "$WORK")"
contract start --repo "$REPO3" --session "$S8" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $UNMAT_REL --unit Drive" --source user >/dev/null
contract start --repo "$REPO3" --session "$S8" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'plain restart, no intake args' --source user >/dev/null
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S8" \
     --command think --status complete --evidence-json "$think_bare_complete" 2>/dev/null; then
  gov_fail "(11b) a plain think RE-START shed the intake marker, letting an intake-mode run drop its selected unit"
fi
[ "$(contract status --repo "$REPO3" --session "$S8" --json | json_count active)" -eq 1 ] \
  || gov_fail "(11b) the rejected monotonicity-bypass finish must leave the think record active"
echo "  ok (11b) the intake marker is monotonic — a plain re-start carries it forward, coverage still enforced"

# ============================================================================================
# (12) Autorun waiting_gate CONSULTS THE ORACLE; a nonexistent/unreadable repo or a fixpoint board fails closed.
direct_validate() {  # $1=command $2=status $3=evidence-json $4=repo ; prints "ok" or "reject:<code>"
  SCRIPTS_DIR="$GOV_PLUGIN/scripts" python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"]); sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"],"hooks"))
import idc_command_contract as cc
cmd, status, ev_json, repo = sys.argv[1:]
res = cc.validate_closeout(cmd, status, json.loads(ev_json), repo=repo, session="probe-session")
print("ok" if res.ok else f"reject:{res.reason_code}")
PY
}
REPO_GATE="$WORK/repo-gate"; mkdir -p "$REPO_GATE/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_GATE/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_GATE/TRACKER.md" init >/dev/null || gov_fail "could not init REPO_GATE board"
python3 "$GOV_TRK" --tracker "$REPO_GATE/TRACKER.md" create \
  --title "[operator-action] approve the Think PR" --status Todo >/dev/null \
  || gov_fail "could not create the operator gate"
SG="sg-$$-$(basename "$WORK")"
contract start --repo "$REPO_GATE" --session "$SG" --command autorun --plugin-root "$GOV_PLUGIN" --args 'a' --source user >/dev/null
contract finish --repo "$REPO_GATE" --session "$SG" --command autorun --status waiting_gate \
  --evidence-json '{"schema_version":1,"refs":{"gates":["#1"]}}' \
  || gov_fail "(12a) an autorun waiting_gate naming the oracle's live human gate was rejected"
r="$(direct_validate autorun waiting_gate '{"schema_version":1,"refs":{"gates":["#1"]}}' "$WORK/does-not-exist")"
[ "$r" != "ok" ] || gov_fail "(12b) autorun waiting_gate returned success against a NONEXISTENT repo"
r="$(direct_validate autorun waiting_gate '{"schema_version":1,"refs":{"gates":["#99"]}}' "$REPO")"
[ "$r" != "ok" ] || gov_fail "(12c) autorun waiting_gate accepted a fabricated gate on a fixpoint board"
echo "  ok (12) autorun waiting_gate consults the oracle (live gate accepted; nonexistent repo + fixpoint board refused)"

# ============================================================================================
# (13, F4) Recirculate complete: reconciliation RE-DERIVES from durable state; the closed disposition
# vocabulary is enforced; and EVERY requested item (recorded at start) has a validated, tracker-checked
# closeout. `closeouts:{}` passes only when the re-derived requested set is empty.
SR="sr-$$-$(basename "$WORK")"
# (13a) a full-inbox drain (no named item): reconciliation settles the drained board → complete with
# any documented-vocabulary closeouts (or an empty set).
contract start --repo "$REPO" --session "$SR" --command recirculate --plugin-root "$GOV_PLUGIN" --args '' --source user >/dev/null
contract finish --repo "$REPO" --session "$SR" --command recirculate --status complete \
  --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#12":"drained"}}}' \
  || gov_fail "(13a) a recirculate complete whose reconciliation re-derives from a drained inbox was rejected"
echo "  ok (13a) recirculate complete re-derives reconciliation from durable state (drained inbox, documented disposition)"

# (13-vocab) an UNDOCUMENTED disposition (the old test's "absorbed") is refused — the prose + validator agree.
contract start --repo "$REPO" --session "$SR" --command recirculate --plugin-root "$GOV_PLUGIN" --args '' --source user >/dev/null
if contract finish --repo "$REPO" --session "$SR" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#12":"absorbed"}}}' 2>/dev/null; then
  gov_fail "(13-vocab) a recirculate complete with an UNDOCUMENTED disposition 'absorbed' was accepted"
fi
contract finish --repo "$REPO" --session "$SR" --command recirculate --status complete \
  --evidence-json '{"schema_version":1,"refs":{"closeouts":{}}}' >/dev/null \
  || gov_fail "(13-vocab) could not close the bare full-drain record (empty requested set → empty closeouts ok)"
echo "  ok (13-vocab) the recirculate disposition vocabulary is closed to the documented values (absorbed refused)"

# (13-req, F4) a recirculate STARTED with a named `<manifest>#<unit>` requested item must carry a
# validated closeout for it, re-checked against the manifest (state != queued). Build a manifest with a
# recirculate-route unit and a fresh repo whose reconciliation re-derives complete.
REPO_RC="$WORK/repo-rc"; mkdir -p "$REPO_RC/docs/workflow/intakes"
printf 'backend: filesystem\n' > "$REPO_RC/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_RC/TRACKER.md" init >/dev/null || gov_fail "could not init REPO_RC"
RC_SRC="$REPO_RC/drift.md"; printf '# Drift plan\n\n## U1 - a discovered drift\n\nbody\n' > "$RC_SRC"
RC_MANIFEST="$REPO_RC/docs/workflow/intakes/2026-07-13-drift.json"
RC_MANIFEST_REL="docs/workflow/intakes/2026-07-13-drift.json"
python3 "$INTAKE" extract --source "$RC_SRC" --out "$RC_MANIFEST" --goal 'absorb the drift' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "(13-req) intake extract failed"
python3 - "$RC_MANIFEST" <<'PY' || gov_fail "(13-req) could not classify drift manifest"
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for u in data["units"]:
    u.update({"class": "discovered_drift", "route": "recirculate", "dependencies": [], "operator_stops": []})
    u["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".d-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as h:
    json.dump(data, h, indent=2, sort_keys=True); h.write("\n")
os.replace(tmp, path)
PY
RC_REVIEW="$REPO_RC/drift-review.json"
python3 - "$INTAKE" "$RC_MANIFEST" "$RC_REVIEW" <<'PY' || gov_fail "(13-req) could not write drift review"
import importlib.util, json, sys
hp, mp, rp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_intake_drift", hp)
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
m = json.load(open(mp, encoding="utf-8"))
review = {"schema_version": 1, "intake_id": m["intake_id"], "source_sha256": m["source"]["sha256"],
          "verdict": "PASS", "missing_unit_ids": [], "duplicate_unit_ids": [], "misrouted_unit_ids": [],
          "notes": [f"manifest_content_sha256={helper._manifest_content_sha256(m)}"]}
json.dump(review, open(rp, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
python3 "$INTAKE" validate --manifest "$RC_MANIFEST" --review "$RC_REVIEW" >/dev/null \
  || gov_fail "(13-req) could not validate drift manifest"
REQ_REF="$RC_MANIFEST_REL#U1"
# started with the named unit STILL queued → a closeout claiming it drained is refused (manifest re-check).
contract start --repo "$REPO_RC" --session "$SR" --command recirculate --plugin-root "$GOV_PLUGIN" \
  --args "$REQ_REF" --source user >/dev/null
if contract finish --repo "$REPO_RC" --session "$SR" --command recirculate --status complete \
     --evidence-json "$(printf '{"schema_version":1,"refs":{"closeouts":{"%s":"drained"}}}' "$REQ_REF")" 2>/dev/null; then
  gov_fail "(13-req) a recirculate complete claiming a requested unit 'drained' while it is STILL QUEUED in the manifest was accepted"
fi
# omitting the requested item's closeout entirely is refused too.
contract start --repo "$REPO_RC" --session "$SR" --command recirculate --plugin-root "$GOV_PLUGIN" \
  --args "$REQ_REF" --source user >/dev/null
if contract finish --repo "$REPO_RC" --session "$SR" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{}}}' 2>/dev/null; then
  gov_fail "(13-req) a recirculate complete with closeouts:{} against a NAMED requested item was accepted"
fi
# now actually process the unit (materialize it) → the closeout re-check passes.
python3 "$INTAKE" link --manifest "$RC_MANIFEST" --unit U1 --state materialized --target-ref "recirc-ticket:5" >/dev/null \
  || gov_fail "(13-req) could not materialize the drift unit"
contract finish --repo "$REPO_RC" --session "$SR" --command recirculate --status complete \
  --evidence-json "$(printf '{"schema_version":1,"refs":{"closeouts":{"%s":"materialized"}}}' "$REQ_REF")" \
  || gov_fail "(13-req) a recirculate complete whose requested unit was actually processed (materialized) was rejected"
echo "  ok (13-req, F4) every requested recirc item needs a tracker-checked closeout ('drained' while queued / omitted → refused; materialized → accepted)"

# ============================================================================================
# (14, F6) the diagnostic/lifecycle commands re-derive from durable artifacts: intake PR (real gh read),
# janitor report, init receipt+presence, update receipt+plugin.json. (doctor covered in 7c.)
S6="s6-$$-$(basename "$WORK")"
# (14-intake) intake complete re-reads the intake PR merged-state (real gh), never a caller state.
contract start --repo "$REPO3" --session "$S6" --command intake --plugin-root "$GOV_PLUGIN" --args 'compile' --source user >/dev/null
intake_ev() { printf '{"schema_version":1,"refs":{"manifest":"%s","review":"2026-07-12-life-review.json","intake_pr":806}}' "$MANIFEST_REL"; }
if FAKE_MERGED_PRS="" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S6" \
     --command intake --status complete --evidence-json "$(intake_ev)" 2>/dev/null; then
  gov_fail "(14-intake) an intake complete whose intake PR reads NOT merged (real gh) was accepted"
fi
FAKE_MERGED_PRS="806" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S6" \
  --command intake --status complete --evidence-json "$(intake_ev)" \
  || gov_fail "(14-intake) an intake complete with a reviewed manifest + a real MERGED intake-PR read was rejected"
echo "  ok (14-intake, F6) intake complete re-reads the intake PR merged-state (unmerged refused, merged accepted)"

# (14-janitor) janitor complete re-reads THIS session's persisted janitor report (a caller scanner_exit is ignored).
contract start --repo "$REPO3" --session "$S6" --command janitor --plugin-root "$GOV_PLUGIN" --args 'scan' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S6" --command janitor --status complete \
     --evidence-json '{"schema_version":1,"refs":{"scanner_exit":0}}' 2>/dev/null; then
  gov_fail "(14-janitor) a janitor complete with a caller scanner_exit but NO persisted report was accepted"
fi
python3 "$CR" --cwd "$REPO3" write --kind janitor --session "$S6" \
  --payload-json '{"scanner_exit":1,"clean":false}' >/dev/null || gov_fail "(14-janitor) could not write janitor report"
contract finish --repo "$REPO3" --session "$S6" --command janitor --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(14-janitor) a janitor complete backed by a persisted findings report (exit 1, not clean) was rejected"
echo "  ok (14-janitor, F6) janitor complete re-reads the durable scan report (a caller exit is ignored)"

# (14-init) init complete re-derives from the install receipt (v2) + governance anchor + enablement.
REPO_INIT="$WORK/repo-init"; mkdir -p "$REPO_INIT/docs/workflow" "$REPO_INIT/.claude"
printf 'backend: filesystem\n' > "$REPO_INIT/docs/workflow/tracker-config.yaml"
printf 'workflow\n' > "$REPO_INIT/WORKFLOW.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_INIT/.claude/settings.json"
SI2="si2-$$-$(basename "$WORK")"
contract start --repo "$REPO_INIT" --session "$SI2" --command init --plugin-root "$GOV_PLUGIN" --args 'scaffold' --source user >/dev/null
if contract finish --repo "$REPO_INIT" --session "$SI2" --command init --status complete \
     --evidence-json '{"schema_version":1,"refs":{"tracker_config":"ok","scaffold":"ok","hooks":"ok","receipt_version":2}}' 2>/dev/null; then
  gov_fail "(14-init) an init complete with three 'ok' strings but NO install receipt was accepted"
fi
python3 "$RECEIPT" stamp --repo "$REPO_INIT" --out "$REPO_INIT/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(14-init) could not stamp the init receipt"
contract finish --repo "$REPO_INIT" --session "$SI2" --command init --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(14-init) an init complete backed by a v2 receipt + anchor + enablement was rejected"
echo "  ok (14-init, F6) init complete re-derives from the install receipt + governance anchor + enablement"

# (14-update) update complete re-derives from the install receipt + the RUNNING plugin version (plugin.json).
REPO_UPD="$WORK/repo-upd"; mkdir -p "$REPO_UPD/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_UPD/docs/workflow/tracker-config.yaml"
printf 'workflow\n' > "$REPO_UPD/WORKFLOW.md"
SU2="su2-$$-$(basename "$WORK")"
# a receipt whose plugin_version is BELOW the running version passes the freshness gate at start but is
# refused at finish (the repo was NOT resynced to the running version — receipt != running).
python3 "$RECEIPT" stamp --repo "$REPO_UPD" --out "$REPO_UPD/docs/workflow/install-receipt.yaml" \
  --plugin-version 3.0.0 WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(14-update) could not stamp a below-running receipt"
contract start --repo "$REPO_UPD" --session "$SU2" --command update --plugin-root "$GOV_PLUGIN" --args 'resync' --source user >/dev/null
if contract finish --repo "$REPO_UPD" --session "$SU2" --command update --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(14-update) an update complete whose receipt plugin_version != the running version was accepted"
fi
python3 "$RECEIPT" stamp --repo "$REPO_UPD" --out "$REPO_UPD/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(14-update) could not re-stamp the receipt to the running version"
contract finish --repo "$REPO_UPD" --session "$SU2" --command update --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(14-update) an update complete whose receipt plugin_version == the running version was rejected"
echo "  ok (14-update, F6) update complete re-derives receipt v2 + receipt plugin_version == the RUNNING plugin version"

# ============================================================================================
# (15, F7) THE INCIDENT-SIZED REGRESSION. Run the full U0–U8/B1/B2 fixture through Think closeout,
# materializing ONLY Drive. The exact 2026-07-12 incident shape: the remainder units "disappear" from
# the exact-once manifest — Think closeout must REFUSE until every unit has a durable disposition.
REPO_INC="$WORK/repo-inc"; mkdir -p "$REPO_INC/docs/workflow/intakes"
printf 'backend: filesystem\n' > "$REPO_INC/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_INC/TRACKER.md" init >/dev/null || gov_fail "could not init REPO_INC"
write_consideration "$REPO_INC" "$CONS_REL"
INC_ISSUES="$WORK/inc-issues"; mkdir -p "$INC_ISSUES"
printf 'Gate.\n<!-- idc-gate-pr: 706 -->\n' > "$INC_ISSUES/708.body"
printf 'pointer.\n' > "$INC_ISSUES/707.body"
journal_line "$REPO_INC" '{"op":"dispose","item":708,"disposition":"gate-approved","when":"2026-07-12T00:00:00Z","who":"t","what":"dispose #708 -> Done [gate-approved]"}'
journal_line "$REPO_INC" '{"op":"unblock","item":707,"when":"2026-07-12T00:00:01Z","who":"t","what":"unblock #707 -> Todo"}'
INC_SRC="$REPO_INC/2026-07-12-life.md"
{ printf '# Drive - foundation\n\nbody\n'; for u in U0 U1 U2 U3 U4 U5 U6 U7 U8 B1 B2; do printf '\n## %s - unit\n\nbody\n' "$u"; done; } > "$INC_SRC"
INC_MANIFEST="$REPO_INC/docs/workflow/intakes/2026-07-12-life.json"
INC_REL="docs/workflow/intakes/2026-07-12-life.json"
python3 "$INTAKE" extract --source "$INC_SRC" --out "$INC_MANIFEST" \
  --goal 'execute the whole program; Drive first' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "(15) incident intake extract failed"
# confirm the full incident set was extracted (Drive + U0..U8 + B1 + B2 = 12 units).
INC_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["expected_unit_ids"]))' "$INC_MANIFEST")"
[ "$INC_COUNT" -eq 12 ] || gov_fail "(15) incident fixture must extract 12 units (Drive+U0..U8+B1+B2), got $INC_COUNT"
python3 - "$INC_MANIFEST" <<'PY' || gov_fail "(15) could not classify incident manifest"
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for u in data["units"]:
    u.update({"class": "new_requirement", "route": "think", "dependencies": [], "operator_stops": []})
    u["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".i-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as h:
    json.dump(data, h, indent=2, sort_keys=True); h.write("\n")
os.replace(tmp, path)
PY
INC_REVIEW="$REPO_INC/inc-review.json"
python3 - "$INTAKE" "$INC_MANIFEST" "$INC_REVIEW" <<'PY' || gov_fail "(15) could not write incident review"
import importlib.util, json, sys
hp, mp, rp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_intake_inc", hp)
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
m = json.load(open(mp, encoding="utf-8"))
review = {"schema_version": 1, "intake_id": m["intake_id"], "source_sha256": m["source"]["sha256"],
          "verdict": "PASS", "missing_unit_ids": [], "duplicate_unit_ids": [], "misrouted_unit_ids": [],
          "notes": [f"manifest_content_sha256={helper._manifest_content_sha256(m)}"]}
json.dump(review, open(rp, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
python3 "$INTAKE" validate --manifest "$INC_MANIFEST" --review "$INC_REVIEW" >/dev/null \
  || gov_fail "(15) could not validate incident manifest"
python3 "$INTAKE" link --manifest "$INC_MANIFEST" --unit Drive --state materialized \
  --target-ref "think-pr:706" --evidence "gate:708" --evidence "pointer:707" >/dev/null \
  || gov_fail "(15) could not materialize Drive in the incident manifest"

# THE INCIDENT: drop U0–U8/B1/B2 from `units` (they "disappear into private memory") but keep them in
# expected_unit_ids → exact-once mismatch → Think closeout must REFUSE.
INC_DROP="$REPO_INC/docs/workflow/intakes/2026-07-12-life-drop.json"
INC_DROP_REL="docs/workflow/intakes/2026-07-12-life-drop.json"
python3 - "$INC_MANIFEST" "$INC_DROP" <<'PY' || gov_fail "(15) could not build the incident-drop manifest"
import json, sys
src, dst = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
data["units"] = [u for u in data["units"] if u["id"] == "Drive"]   # only Drive survives (the incident)
data["intake_id"] = "2026-07-12-life-drop"
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
SINC="sinc-$$-$(basename "$WORK")"
inc_ev() { printf '{"schema_version":1,"refs":{"consideration":"%s","think_pr":706,"gate":708,"pointer":707,"intake_manifest":"%s","intake_selected":["Drive"]}}' "$CONS_REL" "$1"; }
contract start --repo "$REPO_INC" --session "$SINC" --command think --plugin-root "$GOV_PLUGIN" --args 'incident' --source user >/dev/null
if FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$INC_ISSUES" gh_finish --repo "$REPO_INC" --session "$SINC" \
     --command think --status complete --evidence-json "$(inc_ev "$INC_DROP_REL")" 2>/dev/null; then
  gov_fail "(15) THE INCIDENT: a Think closeout materializing ONLY Drive while U0–U8/B1/B2 disappeared was ACCEPTED"
fi
[ "$(contract status --repo "$REPO_INC" --session "$SINC" --json | json_count active)" -eq 1 ] \
  || gov_fail "(15) the rejected incident finish must leave the think record active"
# the HEALTHY shape (all 12 units present, Drive materialized, the rest durably queued) closes honestly.
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$INC_ISSUES" gh_finish --repo "$REPO_INC" --session "$SINC" \
  --command think --status complete --evidence-json "$(inc_ev "$INC_REL")" \
  || gov_fail "(15) the HEALTHY incident shape (every one of the 12 units durably disposed) was rejected"
echo "  ok (15, F7) the incident-sized Think closeout REFUSES until every U0–U8/B1/B2 unit has a durable disposition"

echo "PASS: the IDC command lifecycle envelope + wave-3 evidence contract hold — every terminal fact is re-derived from durable state (consideration re-run, gate marker/disposal, pointer admission, admitted-consideration set, receipt/report/journal, real gh reads), a forged or omitting claim is refused across all eleven commands, and the 2026-07-12 incident shape is blocked at Think closeout"
