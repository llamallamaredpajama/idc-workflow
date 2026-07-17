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
# the READ-ONLY calls the wave-3/wave-4 validators make:
#   * `gh pr view <N> --json state,mergedAt`  → MERGED when N in $FAKE_MERGED_PRS (space list), CLOSED
#     (unmerged, a dead gate) when N in $FAKE_CLOSED_PRS, else OPEN; $FAKE_PR_ERROR=1 EXITS NONZERO.
#   * `gh pr view <N> --json closingIssuesReferences` → the issues N closes, from $FAKE_PR_CLOSES
#     (space list of `pr:issue` pairs — the PR↔issue linkage a build receipt is proven against).
#   * `gh issue view <N> --json body -q .body` → prints $FAKE_ISSUE_DIR/<N>.body, or EXITS NONZERO when
#     absent (a nonexistent gate/pointer/child).
#   * `gh auth status` → the real gh reports on STDERR, so this does too: a token-scope line carrying
#     'project' (doctor row 2's PASS condition). $FAKE_GH_NO_PROJECT=1 drops the project scope (logged
#     in, wrong scope); $FAKE_GH_AUTH_ERROR=1 EXITS NONZERO (not logged in).
write_fake_gh() {  # $1 = path to the fake gh
  python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
src = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] == ["auth", "status"]:
    if os.environ.get("FAKE_GH_AUTH_ERROR") == "1":
        sys.stderr.write("fake gh: You are not logged into any GitHub hosts\n"); raise SystemExit(1)
    scopes = "'gist', 'read:org', 'repo'" if os.environ.get("FAKE_GH_NO_PROJECT") == "1" \
        else "'gist', 'project', 'read:org', 'repo'"
    sys.stderr.write("github.com\n  - Logged in to github.com account fake-user\n"
                     "  - Token scopes: %s\n" % scopes)
    raise SystemExit(0)
if args[:2] == ["pr", "view"] and len(args) >= 3:
    if os.environ.get("FAKE_PR_ERROR") == "1":
        sys.stderr.write("fake gh: pr read failed\n"); raise SystemExit(2)
    fields = args[args.index("--json") + 1] if "--json" in args else ""
    if "closingIssuesReferences" in fields:
        closes = {}
        for pair in (os.environ.get("FAKE_PR_CLOSES") or "").split():
            pr, _, issue = pair.partition(":")
            closes.setdefault(pr, []).append({"number": int(issue)})
        print(json.dumps({"closingIssuesReferences": closes.get(args[2], [])}))
        raise SystemExit(0)
    merged = set((os.environ.get("FAKE_MERGED_PRS") or "").split())
    closed = set((os.environ.get("FAKE_CLOSED_PRS") or "").split())
    if args[2] in merged:
        print(json.dumps({"state": "MERGED", "mergedAt": "2026-07-12T00:00:00Z"}))
    elif args[2] in closed:
        print(json.dumps({"state": "CLOSED", "mergedAt": None}))
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
# rec_nonce <repo> <session> <command> — the per-invocation nonce the entry gate stamped on the active
# command record (wave-4 finding 7): a diagnostic report must carry it for the closeout to accept it.
rec_nonce() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]+"/.idc-session-state.json"))
print(next((c.get("nonce","") for c in d["commands"] if c.get("state")=="active" and c.get("session_id")==sys.argv[2] and c.get("command")==sys.argv[3]),""))' "$1" "$2" "$3" 2>/dev/null
}
# doctor_report <repo> <session> <verdict> — write THIS session's persisted doctor report the way the
# doctor RUN does (round-5 finding 6): the FULL doctor row contract — all rows 1..10 (unique ids), legal
# outcomes, the script-backed row 10 carrying {script,exit}, a verdict EQUAL to the derived aggregation,
# bound to the active record's nonce.
#
# The rows are HONEST for a BARE hermetic repo (round-7 BLOCKS 2): every check is SKIP ("could not
# determine") because none of them can be established here — no settings opt-in, no gh, no scaffold, no
# receipt, no Pi/Codex mirror, no scanner run. That is exactly what a real doctor would report, and a
# SKIP row is never contested by the closeout (only a claimed PASS is). A FAIL verdict is driven by a
# FAIL row 2 (a FAIL row is likewise never contested — doctor completing is not the repo passing).
# The all-rows-PASS path is proven separately, against a FULLY-PROVISIONED fixture, in case (7c-r7).
doctor_report() {
  local n; n="$(rec_nonce "$1" "$2" doctor)"
  DR_VERDICT="$3" DR_NONCE="$n" python3 - "$CR" "$1" "$2" <<'PY' || gov_fail "could not write doctor report"
import json, os, subprocess, sys
cr, repo, sess = sys.argv[1:]
verdict, nonce = os.environ["DR_VERDICT"], os.environ["DR_NONCE"]
rows = []
for i in range(1, 11):
    if i == 10:
        # script-backed: the schema requires {script,exit} whatever the result. Exit 2 = the scanner
        # could not establish ground truth, which is doctor's own SKIP for this row.
        rows.append({"id": 10, "result": "SKIP", "script": "idc_git_janitor.py", "exit": 2})
    elif i == 2 and verdict == "FAIL":
        rows.append({"id": 2, "result": "FAIL"})
    else:
        rows.append({"id": i, "result": "SKIP"})
payload = {"rows": rows, "verdict": verdict, "nonce": nonce}
subprocess.run([sys.executable, cr, "--cwd", repo, "write", "--kind", "doctor", "--session", sess,
                "--payload-json", json.dumps(payload)], check=True, stdout=subprocess.DEVNULL)
PY
}
# raw_doctor_report <repo> <session> <payload-json> — write the report file DIRECTLY, BYPASSING the
# writer's schema gate, so a schema-violating report can reach (and be refused by) the CLOSEOUT's own
# independent re-validation (round-5 finding 6e).
raw_doctor_report() {
  python3 -c 'import json,sys,time
repo,sess,payload=sys.argv[1:]
body={"version":1,"kind":"doctor","session_id":sess,"ts":time.time(),"payload":json.loads(payload)}
open(repo+"/.idc-doctor-report.json","w").write(json.dumps(body))' "$1" "$2" "$3"
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

# (1) start creates one active record and is idempotent for the same session+command. S1 opens a
# `build` record — its cheap oracle-backed `no_action` close (REPO's board is empty) lets case (4)
# demonstrate a valid closeout without the heavy think evidence fixtures (which cases 7+ exercise).
contract start --repo "$REPO" --session "$S1" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'drive it' --source user >/dev/null
contract start --repo "$REPO" --session "$S1" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'drive it' --source user >/dev/null
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
if contract finish --repo "$REPO" --session "$S1" --command build --status done \
  --evidence-json '{}'; then
  gov_fail "unrecognized status cleared the obligation"
fi
if contract finish --repo "$REPO" --session "$S1" --command build --status done \
  --evidence-json '{"schema_version":1,"refs":{}}'; then
  gov_fail "an unknown status with a valid envelope must still be rejected (status guard)"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "a rejected finish must leave the active record intact"
echo "  ok (3) an unknown/malformed terminal status cannot clear the obligation (status guard isolated)"

# (3.1) COMMON-ENVELOPE guards, isolated (the envelope check runs BEFORE the per-command claim table).
if contract finish --repo "$REPO" --session "$S1" --command build --status no_action \
  --evidence-json '{"schema_version":true,"refs":{}}'; then
  gov_fail "(3.1a) schema_version: true (bool) was accepted as the integer 1"
fi
if contract finish --repo "$REPO" --session "$S1" --command build --status no_action \
  --evidence-json '{"schema_version":1.0,"refs":{}}'; then
  gov_fail "(3.1b) schema_version: 1.0 (float) was accepted as the integer 1"
fi
if contract finish --repo "$REPO" --session "$S1" --command build --status no_action \
  --evidence-json '{"schema_version":1,"refs":[]}'; then
  gov_fail "(3.1c) a non-object refs was accepted"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "rejected envelope finishes must leave the active record intact"
echo "  ok (3.1) common-envelope guards isolated: schema_version rejects true/1.0, refs must be an object"

# (4) a valid, command-specific closeout ends the command honestly → Stop no longer blocks. S1's open
# record is `build`; close it with an oracle-backed `no_action` (REPO's board is empty — a real
# re-derivation, not a caller flag), then prove Stop passes only when NO command is open.
contract finish --repo "$REPO" --session "$S1" --command build --status no_action \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(4) could not close S1's build record via an oracle-backed no_action"
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

# (7w, F2) think WAITING_GATE: the Think PR must read exactly OPEN (a CLOSED dead gate refuses), and
# the gate/pointer are re-derived from CURRENT board state (the gate open, the pointer genuinely
# Blocked) — not journal-absence alone.
REPO_W="$WORK/repo-w"; mkdir -p "$REPO_W/docs/workflow/considerations"
printf 'backend: filesystem\n' > "$REPO_W/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_W/TRACKER.md" init >/dev/null || gov_fail "(7w) could not init REPO_W"
write_consideration "$REPO_W" "$CONS_REL"
python3 "$GOV_TRK" --tracker "$REPO_W/TRACKER.md" create --title gate --status Blocked >/dev/null            # #1 gate (open)
python3 "$GOV_TRK" --tracker "$REPO_W/TRACKER.md" create --title ptr --stage Consideration --status Blocked >/dev/null  # #2 pointer (blocked)
python3 "$GOV_TRK" --tracker "$REPO_W/TRACKER.md" create --title ptr2 --stage Consideration --status Todo >/dev/null    # #3 pointer (advanced, Todo)
python3 "$GOV_TRK" --tracker "$REPO_W/TRACKER.md" create --title gate2 --status Done >/dev/null             # #4 gate (closed)
W_ISSUES="$WORK/w-issues"; mkdir -p "$W_ISSUES"
printf 'Gate.\n<!-- idc-gate-pr: 50 -->\n' > "$W_ISSUES/1.body"
printf 'pointer, blocked.\n' > "$W_ISSUES/2.body"
printf 'pointer, advanced.\n' > "$W_ISSUES/3.body"
printf 'Gate closed.\n<!-- idc-gate-pr: 50 -->\n' > "$W_ISSUES/4.body"
SW="sw-$$-$(basename "$WORK")"
wait_ev() { printf '{"schema_version":1,"refs":{"consideration":"%s","think_pr":50,"gate":%s,"pointer":%s}}' "$CONS_REL" "$1" "$2"; }
# honest: PR 50 OPEN, gate #1 open on the board, pointer #2 Blocked → accepted.
contract start --repo "$REPO_W" --session "$SW" --command think --plugin-root "$GOV_PLUGIN" --args 'w' --source user >/dev/null
FAKE_ISSUE_DIR="$W_ISSUES" gh_finish --repo "$REPO_W" --session "$SW" --command think --status waiting_gate \
  --evidence-json "$(wait_ev 1 2)" \
  || gov_fail "(7w) an honest think waiting_gate (PR OPEN, gate open on board, pointer Blocked) was rejected"
# (i) a CLOSED (unmerged, dead) Think PR is NOT a valid wait.
contract start --repo "$REPO_W" --session "$SW" --command think --plugin-root "$GOV_PLUGIN" --args 'w2' --source user >/dev/null
if FAKE_CLOSED_PRS="50" FAKE_ISSUE_DIR="$W_ISSUES" gh_finish --repo "$REPO_W" --session "$SW" \
     --command think --status waiting_gate --evidence-json "$(wait_ev 1 2)" 2>/dev/null; then
  gov_fail "(7w-i) a think waiting_gate whose Think PR reads CLOSED (a dead gate) was accepted"
fi
# (ii) an UNVERIFIABLE Think PR (gh errored) fails closed.
if FAKE_PR_ERROR=1 FAKE_ISSUE_DIR="$W_ISSUES" gh_finish --repo "$REPO_W" --session "$SW" \
     --command think --status waiting_gate --evidence-json "$(wait_ev 1 2)" 2>/dev/null; then
  gov_fail "(7w-ii) a think waiting_gate accepted an UNVERIFIABLE Think-PR state (gh errored)"
fi
# (iii) a gate that reads Done on the CURRENT board is not a wait (gate #4).
if FAKE_ISSUE_DIR="$W_ISSUES" gh_finish --repo "$REPO_W" --session "$SW" \
     --command think --status waiting_gate --evidence-json "$(wait_ev 4 2)" 2>/dev/null; then
  gov_fail "(7w-iii) a think waiting_gate whose gate reads Done on the board was accepted"
fi
# (iv) a pointer that is NOT Blocked on the CURRENT board (advanced to Todo) is not a wait (pointer #3).
if FAKE_ISSUE_DIR="$W_ISSUES" gh_finish --repo "$REPO_W" --session "$SW" \
     --command think --status waiting_gate --evidence-json "$(wait_ev 1 3)" 2>/dev/null; then
  gov_fail "(7w-iv) a think waiting_gate whose pointer reads Todo (advanced past its gate) was accepted"
fi
FAKE_ISSUE_DIR="$W_ISSUES" gh_finish --repo "$REPO_W" --session "$SW" --command think --status waiting_gate \
  --evidence-json "$(wait_ev 1 2)" >/dev/null \
  || gov_fail "(7w) could not honestly close the waiting_gate record after the sabotages"
echo "  ok (7w, F2) think waiting_gate requires an OPEN PR + gate open + pointer Blocked on the CURRENT board (CLOSED/errored/Done-gate/advanced-pointer refused)"

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

# (7c, ROUND-5 F6) doctor complete re-reads THIS session's persisted doctor report, which must satisfy
# the FULL doctor row contract: all rows 1..10 (unique ids), legal outcomes {PASS,FAIL,SKIP}, the
# script-backed row 10 carrying {script,exit}, and a verdict EQUAL to the derived aggregation of the row
# outcomes. A forged/no report, a 2-row / arbitrary report (refused at BOTH the write door and the
# closeout), an inconsistent verdict, and a script-row PASS whose read-only re-run disagrees are all
# refused. A FAIL verdict is still a complete doctor run; a diagnostic command may not claim no_action.
contract start --repo "$REPO3" --session "$S3" --command doctor --plugin-root "$GOV_PLUGIN" --args 'diag' --source user >/dev/null
# (i) forged rows/verdict with NO persisted report → refused.
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
     --evidence-json '{"schema_version":1,"refs":{"rows":["forged"],"verdict":"PASS"}}' 2>/dev/null; then
  gov_fail "(7c) a doctor complete with FORGED rows/verdict but NO persisted report was accepted"
fi
# (ii) doctor no_action (an illegal terminal status for a diagnostic command) → refused.
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status no_action \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(7c) doctor no_action (an illegal terminal status for a diagnostic command) was accepted"
fi
DOC_N="$(rec_nonce "$REPO3" "$S3" doctor)"
# (iii, F6f) the report WRITER refuses a 2-row doctor payload (the doctor schema gate at the write door).
if python3 "$CR" --cwd "$REPO3" write --kind doctor --session "$S3" \
     --payload-json "$(printf '{"rows":[{"id":1,"result":"PASS"},{"id":2,"result":"PASS"}],"verdict":"PASS","nonce":"%s"}' "$DOC_N")" 2>/dev/null; then
  gov_fail "(7c, F6f) the report writer PERSISTED a 2-row doctor payload (the doctor schema is not enforced at the write door)"
fi
# (iv, F6e) a raw 2-row report that BYPASSED the writer is refused by the CLOSEOUT's own schema re-check.
raw_doctor_report "$REPO3" "$S3" "$(printf '{"rows":[{"id":1,"result":"PASS"},{"id":2,"result":"PASS"}],"verdict":"PASS","nonce":"%s"}' "$DOC_N")"
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(7c, F6e) a doctor complete backed by a raw 2-row report (bypassing the writer) was accepted by the closeout"
fi
# (v, F6b) a full 10-row report whose verdict != the derived aggregation (a FAIL row but verdict PASS) → refused.
raw_doctor_report "$REPO3" "$S3" "$(python3 -c 'import json,sys; rows=[{"id":i,"result":("FAIL" if i==2 else ("SKIP" if i==5 else "PASS"))} for i in range(1,11)]; rows[9]={"id":10,"result":"PASS","script":"idc_git_janitor.py","exit":0}; print(json.dumps({"rows":rows,"verdict":"PASS","nonce":sys.argv[1]}))' "$DOC_N")"
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(7c, F6b) a doctor complete whose verdict (PASS) contradicts a FAIL row (aggregation FAIL) was accepted"
fi
# (vi, F6d) a schema-valid report claiming row 5 (install receipt) PASS on a NO-RECEIPT repo → the
# closeout SPOT-RE-RUNS the cheap read-only receipt verification and refuses the inconsistent PASS.
python3 "$CR" --cwd "$REPO3" write --kind doctor --session "$S3" \
  --payload-json "$(python3 -c 'import json,sys; rows=[{"id":i,"result":("PASS" if i!=10 else "PASS")} for i in range(1,11)]; rows[9]={"id":10,"result":"PASS","script":"idc_git_janitor.py","exit":0}; print(json.dumps({"rows":rows,"verdict":"PASS","nonce":sys.argv[1]}))' "$DOC_N")" >/dev/null \
  || gov_fail "(7c) could not write the row-5-PASS doctor report (schema should accept it; the closeout re-run rejects it)"
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(7c, F6d) a doctor complete claiming row 5 (install receipt) PASS on a no-receipt repo was accepted (spot re-run not enforced)"
fi
# (vii) an honest full 10-row FAIL report (schema-valid, verdict==aggregation) → accepted (a FAIL still completes).
doctor_report "$REPO3" "$S3" FAIL
contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(7c) doctor complete backed by an honest full 10-row FAIL report was rejected"
echo "  ok (7c, F6) doctor complete enforces the full row contract (writer + closeout schema gate; verdict==aggregation; row-5 spot re-run; 2-row/inconsistent refused; a FAIL verdict still completes; no_action illegal)"

# (7c-r7, ROUND-7 BLOCKS 2) EVERY row claiming PASS must survive a read-only re-derivation — not just
# row 5. Wave 6 contested row 5 alone, so a report forging PASS on any other row closed clean: the
# reviewer's probe forged row 2 (a gh read that never ran) and the lead's went further with row 4 (a
# governance scaffold deterministically ABSENT in the repo) — both `writer=ACCEPTED
# doctor_closeout_ok=True`. That is the terminal posture's named incident class: forged closeout
# evidence, a failed read counted as a pass.
#
# Each negative below forges exactly ONE PASS row (every other row SKIP) and asserts the refusal names
# THAT row — a blanket/incidental refusal would otherwise pass these vacuously. The positive proves no
# false-refusal: a fully-provisioned repo whose rows are ALL genuinely re-derivable still closes.
# Red-when-broken (MANDATORY, reviewed): make any one re-deriver unconditionally corroborate (e.g.
# `_rederive_doctor_row4` → `return True, ""`) ⇒ that row's negative goes GREEN. Receipts in the report.
#
# one_pass_report <repo> <session> <row-id> — a schema-valid report where every row is SKIP except
# <row-id>, which claims PASS (row 10 always carries its {script,exit}). It goes through the REAL
# WRITER, which ACCEPTS it: `validate_doctor_payload` is schema-only BY DESIGN (the closeout is the
# single guarded truth door — the row-5 precedent), so the closeout is what is under test here.
one_pass_report() {
  local n; n="$(rec_nonce "$1" "$2" doctor)"
  DR_ROW="$3" DR_NONCE="$n" python3 - "$CR" "$1" "$2" <<'PY'
import json, os, subprocess, sys
cr, repo, sess = sys.argv[1:]
want, nonce = int(os.environ["DR_ROW"]), os.environ["DR_NONCE"]
rows = []
for i in range(1, 11):
    row = {"id": i, "result": "PASS" if i == want else "SKIP"}
    if i == 10:
        row["script"], row["exit"] = "idc_git_janitor.py", 0
    rows.append(row)
payload = {"rows": rows, "verdict": "PASS", "nonce": nonce}
p = subprocess.run([sys.executable, cr, "--cwd", repo, "write", "--kind", "doctor", "--session", sess,
                    "--payload-json", json.dumps(payload)], stdout=subprocess.DEVNULL)
sys.exit(p.returncode)
PY
}
# refuse_row <repo> <session> <row-id> <why> <label> — forge that row's PASS, assert the closeout
# REFUSES, and assert the refusal is ABOUT that row (not an incidental failure elsewhere).
refuse_row() {
  one_pass_report "$1" "$2" "$3" \
    || gov_fail "(7c-r7) the report WRITER refused a schema-valid row-$3-PASS payload (it must stay schema-only; the closeout is the truth door)"
  local out
  out="$(PATH="$FAKE_BIN:$PATH" contract finish --repo "$1" --session "$2" --command doctor \
          --status complete --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)" \
    && gov_fail "(7c-r7, $5) a doctor complete forging row $3 PASS was ACCEPTED — $4"
  printf '%s' "$out" | grep -q "row $3" \
    || gov_fail "(7c-r7, $5) the closeout refused, but NOT about row $3 (an incidental refusal proves nothing): $out"
}
# A BARE repo: no scaffold, no settings opt-in, no receipt, no scanner report — so rows 1/2/4/5/10 are
# each deterministically NOT re-derivable here. Rows 3/6/7/8/9 are contested below by degrading only
# their own live truth, proving every row's checker independently refuses a forged PASS.
REPO_D7="$WORK/repo-d7"; mkdir -p "$REPO_D7/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_D7/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_D7/TRACKER.md" init >/dev/null || gov_fail "(7c-r7) could not init the REPO_D7 board"
SD7="sd7-$$-$(basename "$WORK")"
contract start --repo "$REPO_D7" --session "$SD7" --command doctor --plugin-root "$GOV_PLUGIN" --args 'diag' --source user >/dev/null \
  || gov_fail "(7c-r7) could not open the REPO_D7 doctor record"
# (r7-a) THE LEAD'S PROBE: row 4 (governance scaffold) PASS on a repo with no WORKFLOW.md and no
#        pillar-matrices — locally, deterministically FALSE.
refuse_row "$REPO_D7" "$SD7" 4 "the scaffold is deterministically ABSENT (no WORKFLOW.md, no pillar-matrices)" "lead probe: forged row-4 PASS"
# (r7-b) THE REVIEWER'S PROBE: row 2 (gh auth + project scope) PASS with a FAILING fake gh (logged out).
one_pass_report "$REPO_D7" "$SD7" 2 || gov_fail "(7c-r7) the writer refused the row-2 payload"
if FAKE_GH_AUTH_ERROR=1 PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_D7" --session "$SD7" \
     --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null 2>&1; then
  gov_fail "(7c-r7, reviewer probe) a doctor complete forging row-2 PASS was ACCEPTED while a real gh auth read FAILS (a failed read counted as a pass)"
fi
# (r7-b2) row 2 PASS with gh ABSENT from PATH entirely → refused (an unrunnable read never proves a pass).
one_pass_report "$REPO_D7" "$SD7" 2 || gov_fail "(7c-r7) the writer refused the row-2 payload"
EMPTY_BIN="$WORK/empty-bin"; mkdir -p "$EMPTY_BIN"
if PATH="$EMPTY_BIN" contract finish --repo "$REPO_D7" --session "$SD7" --command doctor \
     --status complete --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null 2>&1; then
  gov_fail "(7c-r7) a doctor complete forging row-2 PASS was ACCEPTED with gh ABSENT from PATH (rule B)"
fi
# (r7-b3) row 2 PASS while gh is logged in WITHOUT the project scope → refused (the row's own probe).
one_pass_report "$REPO_D7" "$SD7" 2 || gov_fail "(7c-r7) the writer refused the row-2 payload"
if FAKE_GH_NO_PROJECT=1 PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_D7" --session "$SD7" \
     --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null 2>&1; then
  gov_fail "(7c-r7) a doctor complete forging row-2 PASS was ACCEPTED while the token carries NO project scope"
fi
# (r7-c) row 10 (board↔git reconciliation) PASS with NO nonce-bound scanner report → refused: the row's
#        exit must come from the SCAN itself (--report-session/--report-nonce), never a caller integer.
refuse_row "$REPO_D7" "$SD7" 10 "no janitor scanner report exists for this session" "forged row-10 PASS, no scanner report"
# (r7-d) row 1 (plugin scoping) PASS with no project-scope opt-in in the repo's settings → refused.
refuse_row "$REPO_D7" "$SD7" 1 "the repo records no project-scope opt-in" "forged row-1 PASS"
# (r7-e) row 5 (install receipt) PASS on a no-receipt repo → refused (the wave-6 row-5 rule, preserved).
refuse_row "$REPO_D7" "$SD7" 5 "no install receipt that parses" "forged row-5 PASS (row-5 rule preserved)"

# (r7-e3) row 3 (tracker reachable) PASS while the filesystem board is absent → refused.
mv "$REPO_D7/TRACKER.md" "$REPO_D7/TRACKER.md.off"
refuse_row "$REPO_D7" "$SD7" 3 "the filesystem tracker is absent" "forged row-3 PASS"
mv "$REPO_D7/TRACKER.md.off" "$REPO_D7/TRACKER.md"

# (r7-e6) row 6 (optional Pi runtime) PASS while its own read-only prerequisite probe fails. A
# minimal system PATH deliberately has no Bun, which install-pi.sh treats as a hard prerequisite.
one_pass_report "$REPO_D7" "$SD7" 6 || gov_fail "(7c-r7) the writer refused the row-6 payload"
ROW6_OUT="$(PATH="$FAKE_BIN:/usr/bin:/bin" contract finish --repo "$REPO_D7" --session "$SD7" \
  --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)" \
  && gov_fail "(7c-r7) a doctor complete forging row 6 PASS was accepted while install-pi.sh --check fails"
printf '%s' "$ROW6_OUT" | grep -q 'row 6' \
  || gov_fail "(7c-r7) the row-6 closeout refusal was incidental: $ROW6_OUT"

# The probe deliberately exits zero when Bun/runtime are healthy but the optional Pi agent is absent;
# Doctor calls that SKIP, so a forged PASS must still be refused. Isolate that exact state with a
# fake Bun and a PATH carrying no Pi binary.
PI_ABSENT_BIN="$WORK/pi-absent-bin"; mkdir -p "$PI_ABSENT_BIN"
printf '#!/bin/sh\necho 1.2.3\n' > "$PI_ABSENT_BIN/bun"; chmod +x "$PI_ABSENT_BIN/bun"
one_pass_report "$REPO_D7" "$SD7" 6 || gov_fail "(7c-r7) the writer refused the row-6 absent-Pi payload"
ROW6_SKIP_OUT="$(PATH="$PI_ABSENT_BIN:/usr/bin:/bin" contract finish --repo "$REPO_D7" --session "$SD7" \
  --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)" \
  && gov_fail "(7c-r7) a forged row-6 PASS was accepted while the probe reported Pi agent ABSENT (Doctor SKIP)"
printf '%s' "$ROW6_SKIP_OUT" | grep -q 'row 6' \
  || gov_fail "(7c-r7) the absent-Pi row-6 refusal was incidental: $ROW6_SKIP_OUT"

# (r7-e7) row 7 (Codex mirror) PASS with an isolated HOME carrying no mirror state → refused.
EMPTY_HOME="$WORK/empty-home"; mkdir -p "$EMPTY_HOME"
HOME="$EMPTY_HOME" refuse_row "$REPO_D7" "$SD7" 7 "the Codex mirror is absent" "forged row-7 PASS"

# (r7-e8) row 8 (running plugin version readable) PASS while THIS closeout's plugin root has no
# manifest. Import the real contract and change only its live `_HERE` root; the row re-deriver itself
# is unmodified and must read the resulting missing manifest as SKIP, never PASS.
one_pass_report "$REPO_D7" "$SD7" 8 || gov_fail "(7c-r7) the writer refused the row-8 payload"
ROW8_OUT="$(SCRIPTS_DIR="$GOV_PLUGIN/scripts" python3 - "$WORK/no-plugin/scripts/idc_command_contract.py" \
  "$REPO_D7" "$SD7" 2>&1 <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"], "hooks"))
import idc_command_contract as contract
contract._HERE = sys.argv[1]
raise SystemExit(contract.main(["finish", "--repo", sys.argv[2], "--session", sys.argv[3],
    "--command", "doctor", "--status", "complete", "--evidence-json",
    '{"schema_version":1,"refs":{}}']))
PY
)" && gov_fail "(7c-r7) a doctor complete forging row 8 PASS was accepted with no readable running manifest"
printf '%s' "$ROW8_OUT" | grep -q 'row 8' \
  || gov_fail "(7c-r7) the row-8 closeout refusal was incidental: $ROW8_OUT"

# (r7-e9) row 9 (build-lane hygiene) PASS while the board it claims to scan is unreadable → refused.
mv "$REPO_D7/TRACKER.md" "$REPO_D7/TRACKER.md.off"
refuse_row "$REPO_D7" "$SD7" 9 "the filesystem board cannot be read" "forged row-9 PASS"
mv "$REPO_D7/TRACKER.md.off" "$REPO_D7/TRACKER.md"

# Positive counterweight for row 6: with both Bun and Pi present and runtime files intact, the same
# one-row PASS report closes successfully.
PI_PRESENT_BIN="$WORK/pi-present-bin"; mkdir -p "$PI_PRESENT_BIN"
printf '#!/bin/sh\necho 1.2.3\n' > "$PI_PRESENT_BIN/bun"
printf '#!/bin/sh\necho 0.42.0\n' > "$PI_PRESENT_BIN/pi"
chmod +x "$PI_PRESENT_BIN/bun" "$PI_PRESENT_BIN/pi"
one_pass_report "$REPO_D7" "$SD7" 6 || gov_fail "(7c-r7) the writer refused the valid row-6 PASS"
PATH="$PI_PRESENT_BIN:/usr/bin:/bin" contract finish --repo "$REPO_D7" --session "$SD7" \
  --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(7c-r7) a real Pi-present/healthy row-6 PASS was rejected"
echo "  ok (7c-r7 row6 positive) Pi PRESENT + healthy probe can back PASS"

# (r7-f) NO FALSE-REFUSAL: a FULLY-PROVISIONED repo whose rows are all genuinely re-derivable closes
#        `complete`. This is the load-bearing counterweight — a re-derivation that refused everything
#        would satisfy every negative above and still be worthless.
REPO_DL="$WORK/repo-dl"
mkdir -p "$REPO_DL/docs/workflow/pillar-matrices" "$REPO_DL/docs/workflow/code-reviews" "$REPO_DL/.claude"
printf 'backend: filesystem\n' > "$REPO_DL/docs/workflow/tracker-config.yaml"
printf '# workflow\n' > "$REPO_DL/WORKFLOW.md"                    # row 4
printf 'version: 2\n' > "$REPO_DL/WORKFLOW-config.yaml"           # row 4
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_DL/.claude/settings.json"   # row 1
python3 "$GOV_TRK" --tracker "$REPO_DL/TRACKER.md" init >/dev/null || gov_fail "(7c-r7) could not init the REPO_DL board"  # rows 3 + 9
python3 "$RECEIPT" stamp --repo "$REPO_DL" --out "$REPO_DL/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(7c-r7) could not stamp the REPO_DL install receipt"                          # row 5
# A real git repo with a commit, so the row-10 scanner can establish ground truth (exit 0/1, not 2).
( cd "$REPO_DL" && git init -q . && git config user.email t@example.com && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1 \
  || gov_fail "(7c-r7) could not make REPO_DL a git repo for the row-10 scanner"
# A fake $HOME: the Codex mirror INSTALLED with a resolving adapter (row 7), and NO user-scope
# settings.json — so row 1's global-leak half is satisfied (absent is not `true`).
FAKE_HOME="$WORK/fake-home"
mkdir -p "$FAKE_HOME/.agents/skills/idc-adapter-codex"
: > "$FAKE_HOME/.agents/.idc-install-state"
printf '# codex adapter\n' > "$FAKE_HOME/.agents/skills/idc-adapter-codex/SKILL.md"
SDL="sdl-$$-$(basename "$WORK")"
contract start --repo "$REPO_DL" --session "$SDL" --command doctor --plugin-root "$GOV_PLUGIN" --args 'diag' --source user >/dev/null \
  || gov_fail "(7c-r7) could not open the REPO_DL doctor record"
DL_N="$(rec_nonce "$REPO_DL" "$SDL" doctor)"
[ -n "$DL_N" ] || gov_fail "(7c-r7) the REPO_DL doctor record carries no nonce"
# Run the REAL row-10 scanner the way commands/doctor.md now specifies — it writes the nonce-bound
# report the closeout re-derives row 10 from. Its OWN exit is what the row must record.
python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO_DL" --tracker "$REPO_DL/TRACKER.md" \
  --check-journal-divergence --report-session "$SDL" --report-nonce "$DL_N" >/dev/null 2>&1
DL_SCAN=$?
case "$DL_SCAN" in
  0|1) ;;
  *) gov_fail "(7c-r7) the row-10 scanner could not establish ground truth in REPO_DL (exit $DL_SCAN) — a PASS row 10 needs a completed scan; fixture broken" ;;
esac
# Row 6 (Pi runtime) is honestly SKIP: Pi is genuinely not installed in the hermetic suite, which IS
# doctor's own SKIP for that row (and a SKIP is never contested). Every other row claims PASS and is
# genuinely re-derivable in this fixture.
legit_report() {  # $1 = nonce
  DR_NONCE="$1" DR_EXIT="$DL_SCAN" python3 - "$CR" "$REPO_DL" "$SDL" <<'PY'
import json, os, subprocess, sys
cr, repo, sess = sys.argv[1:]
nonce, scan = os.environ["DR_NONCE"], int(os.environ["DR_EXIT"])
rows = []
for i in range(1, 11):
    if i == 6:
        rows.append({"id": 6, "result": "SKIP"})       # Pi genuinely not installed → doctor's own SKIP
    elif i == 10:
        rows.append({"id": 10, "result": "PASS", "script": "idc_git_janitor.py", "exit": scan})
    else:
        rows.append({"id": i, "result": "PASS"})
p = subprocess.run([sys.executable, cr, "--cwd", repo, "write", "--kind", "doctor", "--session", sess,
                    "--payload-json", json.dumps({"rows": rows, "verdict": "PASS", "nonce": nonce})],
                   stdout=subprocess.DEVNULL)
sys.exit(p.returncode)
PY
}
legit_report "$DL_N" || gov_fail "(7c-r7) could not write the legitimate doctor report"
OUT_DL="$(HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_DL" --session "$SDL" \
  --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' 2>&1)" \
  || gov_fail "(7c-r7, no-false-refusal) a doctor complete whose PASS rows are ALL genuinely re-derivable was REJECTED: $OUT_DL"
# (r7-g) LIVE truth, not a one-time blessing: the SAME legitimate report is refused once a re-derivable
#        truth degrades (the row-1 opt-in is removed between the run and the closeout).
contract start --repo "$REPO_DL" --session "$SDL" --command doctor --plugin-root "$GOV_PLUGIN" --args 'diag' --source user >/dev/null
DL_N2="$(rec_nonce "$REPO_DL" "$SDL" doctor)"
python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO_DL" --tracker "$REPO_DL/TRACKER.md" \
  --check-journal-divergence --report-session "$SDL" --report-nonce "$DL_N2" >/dev/null 2>&1
legit_report "$DL_N2" || gov_fail "(7c-r7) could not re-write the legitimate doctor report"
mv "$REPO_DL/.claude/settings.json" "$REPO_DL/.claude/settings.json.off"   # the row-1 opt-in degrades
if HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_DL" --session "$SDL" \
     --command doctor --status complete --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null 2>&1; then
  gov_fail "(7c-r7, r7-g) the SAME report still closed after the row-1 opt-in was removed — the re-derivation is not reading LIVE truth"
fi
mv "$REPO_DL/.claude/settings.json.off" "$REPO_DL/.claude/settings.json"
echo "  ok (7c-r7, BLOCKS 2) EVERY PASS-claiming doctor row is re-derived: forged row 1–10 PASSes are refused by their own checker, a failed/absent/wrong-scope read never counts as a pass, a fully-provisioned repo whose PASS rows are all genuinely re-derivable still closes complete, and the same report stops closing once a truth degrades"

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

# (7d-jan, F1 + ROUND-5 F7) janitor blocked_external: ONLY a report carrying the SCANNER's provenance
# stamp AND the documented blocked exit (2) grounds it. (a) a HAND-WRITTEN report lacking `produced_by`
# is refused (impossible to pass off). (b) a scanner-shaped report recording exit 1 (a COMPLETE scan
# with findings) citing a blocker is refused (exit 1 != blocked). (c) the honest exit-2 path RUNS THE
# REAL SCANNER in a non-git dir — build_ctx exits 2 and writes the nonce-bound, provenance-stamped report
# itself (no hand-written report) — and a blocker citing exit 2 re-derives + accepts.
REPO_JB="$WORK/repo-jb"; mkdir -p "$REPO_JB/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_JB/docs/workflow/tracker-config.yaml"
SJB="sjb-$$-$(basename "$WORK")"
contract start --repo "$REPO_JB" --session "$SJB" --command janitor --plugin-root "$GOV_PLUGIN" --args 'scan' --source user >/dev/null
JBN="$(rec_nonce "$REPO_JB" "$SJB" janitor)"
# (a) a hand-written report LACKING the scanner's provenance stamp → refused (cannot be passed off).
python3 "$CR" --cwd "$REPO_JB" write --kind janitor --session "$SJB" \
  --payload-json "$(printf '{"scanner_exit":2,"clean":false,"nonce":"%s"}' "$JBN")" >/dev/null
if contract finish --repo "$REPO_JB" --session "$SJB" --command janitor --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_git_janitor.py","exit":2,"diagnostic":"x"}}}' 2>/dev/null; then
  gov_fail "(7d-jan, F7) a janitor blocked_external backed by a HAND-WRITTEN report (no scanner provenance) was accepted"
fi
# (b) a scanner-shaped report recording exit 1 (findings = a COMPLETE scan) → a blocker citing exit 1 refused.
python3 "$CR" --cwd "$REPO_JB" write --kind janitor --session "$SJB" \
  --payload-json "$(printf '{"scanner_exit":1,"clean":false,"nonce":"%s","produced_by":"idc_git_janitor.py"}' "$JBN")" >/dev/null
if contract finish --repo "$REPO_JB" --session "$SJB" --command janitor --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_git_janitor.py","exit":1,"diagnostic":"findings"}}}' 2>/dev/null; then
  gov_fail "(7d-jan, F1) a janitor blocked_external citing scanner_exit 1 (findings, NOT blocked) was accepted"
fi
# (c) THE HONEST exit-2 path: RUN THE REAL SCANNER in a non-git dir → build_ctx exits 2 and writes the
# nonce-bound, provenance-stamped report itself (no hand-written report). A blocker citing exit 2 accepts.
NONGIT="$WORK/repo-jb-nongit"; mkdir -p "$NONGIT/docs/workflow"
printf 'backend: filesystem\n' > "$NONGIT/docs/workflow/tracker-config.yaml"
SJB2="sjb2-$$-$(basename "$WORK")"
contract start --repo "$NONGIT" --session "$SJB2" --command janitor --plugin-root "$GOV_PLUGIN" --args 'scan' --source user >/dev/null
JBN2="$(rec_nonce "$NONGIT" "$SJB2" janitor)"
python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$NONGIT" \
  --report-session "$SJB2" --report-nonce "$JBN2" >/dev/null 2>&1   # build_ctx: not a git repo → exit 2 → writes report
contract finish --repo "$NONGIT" --session "$SJB2" --command janitor --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_git_janitor.py","exit":2,"diagnostic":"not a git repository"}}}' \
  || gov_fail "(7d-jan, F7) a janitor blocked_external re-derived from the REAL SCANNER's own exit-2 report was rejected"
echo "  ok (7d-jan, F1/F7) janitor blocked_external needs the scanner's provenance-stamped report; the honest exit-2 path RUNS the real scanner (hand-written/exit-1 refused, scanner exit-2 accepted)"

# (7d-receipt, F1) a blocked_external citing the receipt checker is grounded ONLY when a read-only
# RE-RUN actually FAILS (an invalid/modified receipt); a clean receipt refuses the blocker (no failure
# to prove). A caller exit/diagnostic alone is never accepted. Also: a NON-re-derivable helper (a PR
# finisher — no receipt, not re-runnable) can never ground a blocked stop for any command.
REPO_RB="$WORK/repo-rb"; mkdir -p "$REPO_RB/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_RB/docs/workflow/tracker-config.yaml"; printf 'wf\n' > "$REPO_RB/WORKFLOW.md"
SRB="srb-$$-$(basename "$WORK")"
python3 "$RECEIPT" stamp --repo "$REPO_RB" --out "$REPO_RB/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null || gov_fail "(7d-receipt) stamp failed"
contract start --repo "$REPO_RB" --session "$SRB" --command init --plugin-root "$GOV_PLUGIN" --args 'x' --source user >/dev/null
# clean receipt → the re-run passes → the blocker is refused (a helper that succeeds cannot block).
if contract finish --repo "$REPO_RB" --session "$SRB" --command init --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_receipt_check.py","exit":2,"diagnostic":"drift"}}}' 2>/dev/null; then
  gov_fail "(7d-receipt, F1) an init blocked_external citing the receipt checker was accepted while the re-run PASSES"
fi
# a NON-re-derivable helper (idc_pr_finish.py — not on init's allowlist) can never ground a blocked stop.
if contract finish --repo "$REPO_RB" --session "$SRB" --command init --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_pr_finish.py","exit":2,"diagnostic":"x"}}}' 2>/dev/null; then
  gov_fail "(7d-receipt, F1) an init blocked_external citing a non-re-derivable helper (idc_pr_finish.py) was accepted"
fi
# now MODIFY a stamped file → the read-only re-run FAILS → the blocker IS grounded.
printf 'TAMPERED\n' > "$REPO_RB/WORKFLOW.md"
contract finish --repo "$REPO_RB" --session "$SRB" --command init --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_receipt_check.py","exit":2,"diagnostic":"scaffold drift"}}}' \
  || gov_fail "(7d-receipt, F1) an init blocked_external whose receipt re-run genuinely FAILS was rejected"
echo "  ok (7d-receipt, F1) a receipt-checker blocker grounds only on a failing read-only re-run; a non-re-derivable helper never blocks"

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

# (7g-req, F5) Build stamps its REQUESTED issue set at start; complete requires ONE verified merged-PR
# receipt PER requested issue, with the PR↔issue linkage proven from the PR's OWN closing references.
REPO_BUILD="$WORK/repo-build"; mkdir -p "$REPO_BUILD/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_BUILD/docs/workflow/tracker-config.yaml"
SB="sb-$$-$(basename "$WORK")"
# started with `#1 #2` → requested {1,2}. A single merged-PR receipt for #1 leaves #2 uncovered → refuse.
contract start --repo "$REPO_BUILD" --session "$SB" --command build --plugin-root "$GOV_PLUGIN" \
  --args '#1 #2' --source user >/dev/null
if FAKE_MERGED_PRS="90" FAKE_PR_CLOSES="90:1" gh_finish --repo "$REPO_BUILD" --session "$SB" \
     --command build --status complete \
     --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90}}}}' 2>/dev/null; then
  gov_fail "(7g-req, F5) a build complete for TWO requested issues with only ONE merged-PR receipt was accepted"
fi
# a merged PR that closes the WRONG issue (#2, not the requested #1) fails the linkage closed.
if FAKE_MERGED_PRS="90 91" FAKE_PR_CLOSES="90:1 91:2" gh_finish --repo "$REPO_BUILD" --session "$SB" \
     --command build --status complete \
     --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90},"2":{"pr":91}}}}' 2>/dev/null; then
  : # this SHOULD pass (90→#1, 91→#2) — asserted below; the wrong-issue case is next.
fi
# wrong-issue: requested #2's receipt cites a merged PR (93) whose closing refs name #1, not #2 → refuse.
contract start --repo "$REPO_BUILD" --session "$SB" --command build --plugin-root "$GOV_PLUGIN" \
  --args '#1 #2' --source user >/dev/null
if FAKE_MERGED_PRS="90 93" FAKE_PR_CLOSES="90:1 93:1" gh_finish --repo "$REPO_BUILD" --session "$SB" \
     --command build --status complete \
     --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90},"2":{"pr":93}}}}' 2>/dev/null; then
  gov_fail "(7g-req, F5) a build complete accepted a receipt whose merged PR closes the WRONG issue"
fi
# honest: each requested issue has a merged PR that closes IT (90→#1, 92→#2) → accepted.
FAKE_MERGED_PRS="90 92" FAKE_PR_CLOSES="90:1 92:2" gh_finish --repo "$REPO_BUILD" --session "$SB" \
  --command build --status complete \
  --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90},"2":{"pr":92}}}}' \
  || gov_fail "(7g-req, F5) a build complete with a linked merged-PR receipt per requested issue was rejected"
echo "  ok (7g-req, F5) build stamps the requested issue set; complete needs a linked merged-PR receipt per issue (partial/wrong-issue refused)"

# (7g-frontier, ROUND-5 F4) a WHOLE-FRONTIER build (no explicit #issue) stamps the eligible frontier at
# START; complete requires a verified merged receipt per stamped-frontier issue OR an oracle-confirmed
# empty remaining frontier. An arbitrary-subset close is REFUSED.
REPO_BF="$WORK/repo-bf"; mkdir -p "$REPO_BF/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_BF/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_BF/TRACKER.md" init >/dev/null || gov_fail "(7g-frontier) could not init REPO_BF"
python3 "$GOV_TRK" --tracker "$REPO_BF/TRACKER.md" create --title b1 --stage Buildable --status Todo >/dev/null  # #1 eligible
python3 "$GOV_TRK" --tracker "$REPO_BF/TRACKER.md" create --title b2 --stage Buildable --status Todo >/dev/null  # #2 eligible
SBF="sbf-$$-$(basename "$WORK")"
bf_finish() { PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_BF" --session "$SBF" "$@"; }
# whole-frontier start (no #issue) stamps frontier {1,2}. A subset receipt (only #1, #2 still eligible)
# → REFUSED (arbitrary-subset close is not a whole-frontier complete).
contract start --repo "$REPO_BF" --session "$SBF" --command build --plugin-root "$GOV_PLUGIN" --args 'drain the whole ready frontier' --source user >/dev/null
if FAKE_MERGED_PRS="90" FAKE_PR_CLOSES="90:1" bf_finish --command build --status complete \
     --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90}}}}' 2>/dev/null; then
  gov_fail "(7g-frontier, F4) a whole-frontier build complete with a receipt for ONLY #1 (leaving #2 eligible) was accepted (arbitrary subset)"
fi
# covering EVERY stamped-frontier issue with a linked merged-PR receipt → accepted.
FAKE_MERGED_PRS="90 91" FAKE_PR_CLOSES="90:1 91:2" bf_finish --command build --status complete \
  --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90},"2":{"pr":91}}}}' \
  || gov_fail "(7g-frontier, F4) a whole-frontier build covering EVERY stamped-frontier issue was rejected"
echo "  ok (7g-frontier, F4) a whole-frontier build stamps the eligible frontier at start; an arbitrary-subset close is refused, full-frontier coverage accepted"
# (7g-frontier-empty) a whole-frontier build on an EMPTY ready frontier closes via the oracle (no receipts).
REPO_BFE="$WORK/repo-bfe"; mkdir -p "$REPO_BFE/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_BFE/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_BFE/TRACKER.md" init >/dev/null || gov_fail "(7g-frontier-empty) could not init REPO_BFE"
SBFE="sbfe-$$-$(basename "$WORK")"
contract start --repo "$REPO_BFE" --session "$SBFE" --command build --plugin-root "$GOV_PLUGIN" --args 'drain frontier' --source user >/dev/null
contract finish --repo "$REPO_BFE" --session "$SBFE" --command build --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(7g-frontier-empty, F4) a whole-frontier build on an oracle-confirmed empty ready frontier was rejected"
echo "  ok (7g-frontier-empty, F4) a whole-frontier build on an empty ready frontier closes via the oracle (no receipts needed)"

# (7g-crossmode, ROUND-6 F1 — rule A) CROSS-MODE monotonic build obligations. A whole-frontier start
# (stamps the eligible frontier {1,2}) then a `/idc:build #1` restart (stamps the requested set {1})
# leaves BOTH obligations on the ONE record; `complete` must satisfy the UNION — a receipt for only #1
# while #2 is still eligible is REFUSED (the requested branch can no longer shed the frontier). The
# mirror (requested-first then whole-frontier restart) refuses identically; full coverage is accepted.
REPO_CM="$WORK/repo-cm"; mkdir -p "$REPO_CM/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_CM/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_CM/TRACKER.md" init >/dev/null || gov_fail "(7g-crossmode) could not init REPO_CM"
python3 "$GOV_TRK" --tracker "$REPO_CM/TRACKER.md" create --title c1 --stage Buildable --status Todo >/dev/null  # #1 eligible
python3 "$GOV_TRK" --tracker "$REPO_CM/TRACKER.md" create --title c2 --stage Buildable --status Todo >/dev/null  # #2 eligible
# (a) frontier-first → requested restart: a subset close (#1 only, #2 still eligible) is refused.
SCM="scm-$$-$(basename "$WORK")"
contract start --repo "$REPO_CM" --session "$SCM" --command build --plugin-root "$GOV_PLUGIN" --args 'drain the whole ready frontier' --source user >/dev/null
contract start --repo "$REPO_CM" --session "$SCM" --command build --plugin-root "$GOV_PLUGIN" --args '#1' --source user >/dev/null
if FAKE_MERGED_PRS="90" FAKE_PR_CLOSES="90:1" gh_finish --repo "$REPO_CM" --session "$SCM" \
     --command build --status complete --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90}}}}' 2>/dev/null; then
  gov_fail "(7g-crossmode, F1) a cross-mode build (whole-frontier then #1 restart) closed covering ONLY #1 while #2 stayed eligible (the frontier obligation was dropped)"
fi
[ "$(contract status --repo "$REPO_CM" --session "$SCM" --json | json_count active)" -eq 1 ] \
  || gov_fail "(7g-crossmode, F1) the refused cross-mode subset close must leave the build record active"
# covering BOTH the requested #1 AND the stamped frontier {1,2} (union satisfied) → accepted.
FAKE_MERGED_PRS="90 91" FAKE_PR_CLOSES="90:1 91:2" gh_finish --repo "$REPO_CM" --session "$SCM" \
  --command build --status complete --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90},"2":{"pr":91}}}}' \
  || gov_fail "(7g-crossmode, F1) a cross-mode build covering BOTH the requested #1 AND the stamped frontier #1,#2 was rejected"
# (b) mirror: requested-first (#1) then whole-frontier restart → the same subset close is refused.
SCM2="scm2-$$-$(basename "$WORK")"
contract start --repo "$REPO_CM" --session "$SCM2" --command build --plugin-root "$GOV_PLUGIN" --args '#1' --source user >/dev/null
contract start --repo "$REPO_CM" --session "$SCM2" --command build --plugin-root "$GOV_PLUGIN" --args 'drain the whole ready frontier' --source user >/dev/null
if FAKE_MERGED_PRS="90" FAKE_PR_CLOSES="90:1" gh_finish --repo "$REPO_CM" --session "$SCM2" \
     --command build --status complete --evidence-json '{"schema_version":1,"refs":{"receipts":{"1":{"pr":90}}}}' 2>/dev/null; then
  gov_fail "(7g-crossmode, F1) the mirror cross-mode build (#1 then whole-frontier restart) closed covering ONLY #1 while #2 stayed eligible"
fi
echo "  ok (7g-crossmode, F1) cross-mode build obligations UNION — a whole-frontier + explicit-#issue record needs both covered; a subset close refused, full coverage accepted"

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

# (7f-retire, F3) THE RETIRE-THEN-OMIT bypass: the admitted set STAMPED at start remembers a
# consideration the plan itself RETIRES off the board, so retiring #1 and #3 but decomposing only
# #1→#2 (dropping #3's child) is REFUSED — the stamp catches #3 even though the live board is clean.
REPO_RT="$WORK/repo-rt"; mkdir -p "$REPO_RT/docs/workflow/pillar-matrices"
printf 'backend: filesystem\n' > "$REPO_RT/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" init >/dev/null || gov_fail "(7f-retire) could not init REPO_RT"
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" create --title cA --stage Consideration --status Todo >/dev/null  # #1
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" create --title cB --stage Consideration --status Todo >/dev/null  # #2
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" create --title chA --stage Buildable --status Todo >/dev/null     # #3
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" create --title chB --stage Buildable --status Todo >/dev/null     # #4
cp "$REPO_PLAN/$GOODMX" "$REPO_RT/$GOODMX"
SRT="srt-$$-$(basename "$WORK")"
# START stamps plan_admitted = {1,2} (both considerations). Retire BOTH off the board.
contract start --repo "$REPO_RT" --session "$SRT" --command plan --plugin-root "$GOV_PLUGIN" --args 'retire-omit' --source user >/dev/null
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" move --num 1 --status Done >/dev/null
python3 "$GOV_TRK" --tracker "$REPO_RT/TRACKER.md" move --num 2 --status Done >/dev/null
# decompose only #1→#3 (drop #2's child), claim only pointer #1 retired → REFUSED (the stamp remembers #2).
if FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_RT" --session "$SRT" --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"1":3}' '[1]')" 2>/dev/null; then
  gov_fail "(7f-retire, F3) a plan complete that retired #2 off the board but never decomposed it was ACCEPTED (retire-then-omit)"
fi
# honest: decompose BOTH (#1→#3, #2→#4) with both pointers retired → accepted.
FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_RT" --session "$SRT" --command plan --status complete \
  --evidence-json "$(plan_ev "$GOODMX" '{"1":3,"2":4}' '[1,2]')" \
  || gov_fail "(7f-retire, F3) a plan complete decomposing EVERY admitted consideration was rejected"
echo "  ok (7f-retire, F3) the retire-then-omit bypass is caught by the start-stamped admitted set (retire #1,#2 + decompose only #1 → refused)"

# (7f-ptr, ROUND-5 F2) pointers_retired is proven by reading each pointer's LIVE board status
# (genuinely retired = Done), NOT by comparing two caller-supplied maps. A pointer moved to Blocked but
# CLAIMED retired is REFUSED; only a genuinely-Done pointer is accepted. Fully isolated repo.
REPO_PTR="$WORK/repo-ptr"; mkdir -p "$REPO_PTR/docs/workflow/pillar-matrices"
printf 'backend: filesystem\n' > "$REPO_PTR/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_PTR/TRACKER.md" init >/dev/null || gov_fail "(7f-ptr) could not init REPO_PTR"
python3 "$GOV_TRK" --tracker "$REPO_PTR/TRACKER.md" create --title "pointer consideration" \
  --stage Consideration --status Todo >/dev/null || gov_fail "(7f-ptr) could not create consideration #1"
python3 "$GOV_TRK" --tracker "$REPO_PTR/TRACKER.md" create --title "child of #1" \
  --stage Buildable --status Todo >/dev/null || gov_fail "(7f-ptr) could not create child #2"
cp "$REPO_PLAN/$GOODMX" "$REPO_PTR/$GOODMX"
SPTR="sptr-$$-$(basename "$WORK")"
ptr_finish() { PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_PTR" --session "$SPTR" "$@"; }
contract start --repo "$REPO_PTR" --session "$SPTR" --command plan --plugin-root "$GOV_PLUGIN" --args 'ptr' --source user >/dev/null
python3 "$GOV_TRK" --tracker "$REPO_PTR/TRACKER.md" move --num 1 --status Blocked >/dev/null  # #1 → Blocked (NOT retired)
if FAKE_MERGED_PRS="42" ptr_finish --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"1":2}' '[1]')" 2>/dev/null; then
  gov_fail "(7f-ptr, F2) a plan complete claiming pointer #1 retired while the board reads Blocked was ACCEPTED (caller-map comparison, not a live read)"
fi
python3 "$GOV_TRK" --tracker "$REPO_PTR/TRACKER.md" move --num 1 --status Done >/dev/null  # genuinely retire it
FAKE_MERGED_PRS="42" ptr_finish --command plan --status complete \
  --evidence-json "$(plan_ev "$GOODMX" '{"1":2}' '[1]')" \
  || gov_fail "(7f-ptr, F2) a plan complete whose pointer #1 is GENUINELY retired (Done) was rejected"
echo "  ok (7f-ptr, F2) pointers_retired is proven by each pointer's LIVE board status (Blocked-claimed-retired refused; Done accepted)"

# (7f-gh-admitted, ROUND-5 F2) the FULL claim walker runs through the PRODUCTION start path on the
# github backend (contract start + gh_finish), NOT a private claim call: with the live board unreadable
# (no gh project hermetically), a plan complete is REFUSED — an unreadable truth is a refusal, never a
# pass (rule B). The old test manually inserted a stamp and called one private claim, so it could ACCEPT
# a github completion the production path can never prove. fake-gh serves only the planning-PR read.
REPO_GHP="$WORK/repo-ghp"; mkdir -p "$REPO_GHP/docs/workflow/pillar-matrices"
printf 'backend: github\nproject_number: 10\n' > "$REPO_GHP/docs/workflow/tracker-config.yaml"
cp "$REPO_PLAN/$GOODMX" "$REPO_GHP/$GOODMX"
SGHP="sghp-$$-$(basename "$WORK")"
contract start --repo "$REPO_GHP" --session "$SGHP" --command plan --plugin-root "$GOV_PLUGIN" --args 'gh-plan' --source user >/dev/null
if FAKE_MERGED_PRS="42" gh_finish --repo "$REPO_GHP" --session "$SGHP" --command plan --status complete \
     --evidence-json "$(plan_ev "$GOODMX" '{"1":2}' '[1]')" 2>/dev/null; then
  gov_fail "(7f-gh-admitted, F2) a github plan complete driven through the full walker was ACCEPTED while the live board was UNREADABLE (rule B: an unreadable truth must refuse)"
fi
echo "  ok (7f-gh-admitted, F2) the full plan walker runs through the production start path on github and REFUSES an unreadable-board completion (rule B; no private-claim crutch)"

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
# A modern run must retain its canonical receipt through finish. Removing it after start must not
# silently downgrade verification to the smaller pre-receipt fallback.
mv "$REPO4/docs/workflow/install-receipt.yaml" "$REPO4/docs/workflow/install-receipt.yaml.off"
if contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
     --evidence-json "$(applied_ev)" 2>/dev/null; then
  gov_fail "(9-sabotage) a receipt-backed uninstall deleted its receipt before finish and silently downgraded to the legacy fallback"
fi
mv "$REPO4/docs/workflow/install-receipt.yaml.off" "$REPO4/docs/workflow/install-receipt.yaml"
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

# (9b) the receipt + governance anchor remain through finish (a post-anchor-removal finish cannot land).
contract start --repo "$REPO4" --session "$S4" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'u3' --source user >/dev/null
rm -f "$REPO4/docs/workflow/tracker-config.yaml"
if contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
     --evidence-json "$(applied_ev)" 2>/dev/null; then
  gov_fail "(9b) an uninstall finish AFTER the anchor was removed unexpectedly succeeded"
fi
echo "  ok (9b) the canonical receipt + governance anchor remain until the combined POST-finish cleanup"

# (9c, F5 no-action) a no-action is PROVEN, never asserted: the start-stamped legacy list or receipt
# must show every non-anchor footprint absent, and the source cannot change mid-run.
REPO4B="$WORK/repo4b"; mkdir -p "$REPO4B/docs/workflow"
printf 'backend: filesystem\n' > "$REPO4B/docs/workflow/tracker-config.yaml"   # governed (finish can run)
printf 'workflow\n' > "$REPO4B/WORKFLOW.md"
S4B="s4b-$$-$(basename "$WORK")"
# (i) Pre-receipt source + a legacy footprint present → no-action refused.
contract start --repo "$REPO4B" --session "$S4B" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'na' --source user >/dev/null
if contract finish --repo "$REPO4B" --session "$S4B" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9c-i) a pre-receipt uninstall with a legacy footprint present was accepted as no-action"
fi
# (ii) A receipt appearing before same-session re-entry must NOT replace the first legacy source.
python3 "$RECEIPT" stamp --repo "$REPO4B" --out "$REPO4B/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9c) could not stamp the REPO4B receipt"
contract start --repo "$REPO4B" --session "$S4B" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'na-restart' --source user >/dev/null || gov_fail "(9c-ii) same-session restart failed"
rm -f "$REPO4B/WORKFLOW.md"
if contract finish --repo "$REPO4B" --session "$S4B" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9c-ii) same-session restart promoted legacy fallback to a newly appeared receipt"
fi
# (iii) A FRESH modern run uses the present receipt. Its live footprint refuses no-action, then the
# same start-stamped receipt accepts after that footprint is removed.
S4BM="s4bm-$$-$(basename "$WORK")"
printf 'workflow\n' > "$REPO4B/WORKFLOW.md"
contract start --repo "$REPO4B" --session "$S4BM" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'na-modern' --source user >/dev/null || gov_fail "(9c-iii) modern start failed"
if contract finish --repo "$REPO4B" --session "$S4BM" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9c-iii) modern no-action accepted while WORKFLOW.md was still present"
fi
rm -f "$REPO4B/WORKFLOW.md"
contract finish --repo "$REPO4B" --session "$S4BM" --command uninstall --status complete \
  --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' \
  || gov_fail "(9c-iii) a uninstall no-action whose receipt footprints are all absent was rejected"
echo "  ok (9c, F5) no-action is source-stable: legacy->receipt re-entry refused; fresh modern footprint present/absent cases verified"

# (9d, deferred #17/#18) A PRE-RECEIPT install uses the exact legacy-owned FILE list. Operator
# artifacts inside the three work-product directories are not footprints and must survive while the
# closeout still verifies that every keepfile/runtime-owned file was removed.
REPO_LEG="$WORK/repo-legacy-uninstall"
mkdir -p "$REPO_LEG/docs/workflow/pillar-matrices" "$REPO_LEG/docs/workflow/code-reviews" \
  "$REPO_LEG/docs/workflow/intakes" "$REPO_LEG/.claude"
printf 'workflow\n' > "$REPO_LEG/WORKFLOW.md"
printf 'config\n' > "$REPO_LEG/WORKFLOW-config.yaml"
printf 'backend: filesystem\n' > "$REPO_LEG/docs/workflow/tracker-config.yaml"
printf 'machine\n' > "$REPO_LEG/docs/workflow/workflow-machine.yaml"
printf 'readme\n' > "$REPO_LEG/docs/workflow/README.md"
: > "$REPO_LEG/docs/workflow/pillar-matrices/.gitkeep"
: > "$REPO_LEG/docs/workflow/code-reviews/.gitkeep"
: > "$REPO_LEG/docs/workflow/code-reviews/.gitignore"
: > "$REPO_LEG/docs/workflow/intakes/.gitkeep"
printf 'operator matrix\n' > "$REPO_LEG/docs/workflow/pillar-matrices/phase-a.yaml"
printf 'operator review\n' > "$REPO_LEG/docs/workflow/code-reviews/pr-12.md"
printf '{"schema_version":1}\n' > "$REPO_LEG/docs/workflow/intakes/vendor.intake.json"
printf 'tracker\n' > "$REPO_LEG/TRACKER.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_LEG/.claude/settings.json"
: > "$REPO_LEG/idc-archive-legacy.tar.gz"
SLEG="sleg-$$-$(basename "$WORK")"
contract start --repo "$REPO_LEG" --session "$SLEG" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall' --source user >/dev/null
if contract finish --repo "$REPO_LEG" --session "$SLEG" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"idc-archive-legacy.tar.gz"}}' 2>/dev/null; then
  gov_fail "(9d) a pre-receipt uninstall closed while legacy-owned files were still present"
fi
rm -f "$REPO_LEG/WORKFLOW.md" "$REPO_LEG/WORKFLOW-config.yaml" \
  "$REPO_LEG/docs/workflow/workflow-machine.yaml" "$REPO_LEG/docs/workflow/README.md" \
  "$REPO_LEG/docs/workflow/pillar-matrices/.gitkeep" \
  "$REPO_LEG/docs/workflow/code-reviews/.gitkeep" \
  "$REPO_LEG/docs/workflow/code-reviews/.gitignore" \
  "$REPO_LEG/docs/workflow/intakes/.gitkeep" "$REPO_LEG/TRACKER.md"
python3 "$GOV_PLUGIN/scripts/idc_settings_json.py" disable "$REPO_LEG/.claude/settings.json" idc@idc-workflow >/dev/null
contract finish --repo "$REPO_LEG" --session "$SLEG" --command uninstall --status complete \
  --evidence-json '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"idc-archive-legacy.tar.gz"}}' \
  || gov_fail "(9d) an exact pre-receipt cleanup was rejected"
for kept in docs/workflow/pillar-matrices/phase-a.yaml docs/workflow/code-reviews/pr-12.md \
            docs/workflow/intakes/vendor.intake.json; do
  [ -f "$REPO_LEG/$kept" ] || gov_fail "(9d) operator work product $kept was deleted"
done
echo "  ok (9d) pre-receipt uninstall uses exact legacy-owned files and preserves matrix/review/intake work products"

# (9e) An EXISTING malformed receipt never downgrades to the legacy fallback.
REPO_BADREC="$WORK/repo-malformed-receipt"; mkdir -p "$REPO_BADREC/docs/workflow" "$REPO_BADREC/.claude"
printf 'backend: filesystem\n' > "$REPO_BADREC/docs/workflow/tracker-config.yaml"
printf 'not: [valid receipt\n' > "$REPO_BADREC/docs/workflow/install-receipt.yaml"
printf '{}\n' > "$REPO_BADREC/.claude/settings.json"
: > "$REPO_BADREC/idc-archive-badrec.tar.gz"
SBADREC="sbadrec-$$-$(basename "$WORK")"
contract start --repo "$REPO_BADREC" --session "$SBADREC" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall' --source user >/dev/null
BADREC_OUT="$(contract finish --repo "$REPO_BADREC" --session "$SBADREC" --command uninstall \
  --status complete --evidence-json '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"idc-archive-badrec.tar.gz"}}' 2>&1)" \
  && gov_fail "(9e) an existing malformed receipt silently fell back to the legacy list"
printf '%s' "$BADREC_OUT" | grep -qi 'receipt' \
  || gov_fail "(9e) malformed receipt refusal did not name the receipt: $BADREC_OUT"
echo "  ok (9e) an existing malformed receipt is a hard failure, never a legacy fallback"

# (9e-alt) The canonical receipt is not caller-selectable. Start against a valid canonical receipt,
# then corrupt it and point finish at a different missing path: the malformed canonical file must
# still fail instead of selecting the legacy fallback.
REPO_ALTREC="$WORK/repo-alternate-receipt"; mkdir -p "$REPO_ALTREC/docs/workflow" "$REPO_ALTREC/.claude"
printf 'backend: filesystem\n' > "$REPO_ALTREC/docs/workflow/tracker-config.yaml"
printf 'owned\n' > "$REPO_ALTREC/idc-owned.txt"
printf '{}\n' > "$REPO_ALTREC/.claude/settings.json"
python3 "$RECEIPT" stamp --repo "$REPO_ALTREC" --out "$REPO_ALTREC/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" idc-owned.txt docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9e-alt) could not stamp the canonical receipt"
: > "$REPO_ALTREC/idc-archive-altrec.tar.gz"
SALTREC="saltrec-$$-$(basename "$WORK")"
contract start --repo "$REPO_ALTREC" --session "$SALTREC" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall' --source user >/dev/null || gov_fail "(9e-alt) valid receipt did not start"
printf 'not: [valid receipt\n' > "$REPO_ALTREC/docs/workflow/install-receipt.yaml"
rm -f "$REPO_ALTREC/idc-owned.txt"
ALTREC_OUT="$(contract finish --repo "$REPO_ALTREC" --session "$SALTREC" --command uninstall \
  --status complete --evidence-json '{"schema_version":1,"refs":{"outcome":"applied","receipt":"docs/workflow/missing-alternate.yaml","settings":".claude/settings.json","archive":"idc-archive-altrec.tar.gz"}}' 2>&1)" \
  && gov_fail "(9e-alt) caller-selected missing receipt bypassed a malformed canonical receipt"
printf '%s' "$ALTREC_OUT" | grep -qi 'receipt' \
  || gov_fail "(9e-alt) alternate-receipt refusal did not name the canonical receipt: $ALTREC_OUT"
echo "  ok (9e-alt) uninstall always verifies the canonical receipt; caller evidence cannot select a fallback path"

# (9e-swap) Presence alone is not a stable manifest. Replacing the canonical receipt after start
# with a valid but narrower one must not let an originally receipt-owned file survive closeout.
REPO_SWAPREC="$WORK/repo-swapped-receipt"; mkdir -p "$REPO_SWAPREC/docs/workflow" "$REPO_SWAPREC/.claude"
printf 'backend: filesystem\n' > "$REPO_SWAPREC/docs/workflow/tracker-config.yaml"
printf 'must be removed\n' > "$REPO_SWAPREC/WORKFLOW.md"
printf '{}\n' > "$REPO_SWAPREC/.claude/settings.json"
python3 "$RECEIPT" stamp --repo "$REPO_SWAPREC" --out "$REPO_SWAPREC/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9e-swap) could not stamp the original canonical receipt"
: > "$REPO_SWAPREC/idc-archive-swaprec.tar.gz"
SSWAPREC="sswaprec-$$-$(basename "$WORK")"
contract start --repo "$REPO_SWAPREC" --session "$SSWAPREC" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall' --source user >/dev/null || gov_fail "(9e-swap) valid receipt did not start"
printf 'replacement\n' > "$REPO_SWAPREC/replacement-owned.txt"
rm -f "$REPO_SWAPREC/docs/workflow/install-receipt.yaml"
python3 "$RECEIPT" stamp --repo "$REPO_SWAPREC" --out "$REPO_SWAPREC/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" replacement-owned.txt docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9e-swap) could not stamp the narrower replacement receipt"
rm -f "$REPO_SWAPREC/replacement-owned.txt"
SWAPREC_OUT="$(contract finish --repo "$REPO_SWAPREC" --session "$SSWAPREC" --command uninstall \
  --status complete --evidence-json '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"idc-archive-swaprec.tar.gz"}}' 2>&1)" \
  && gov_fail "(9e-swap) a narrower replacement receipt hid an original owned file from closeout"
printf '%s' "$SWAPREC_OUT" | grep -Eqi 'receipt|manifest|changed' \
  || gov_fail "(9e-swap) receipt-swap refusal was not diagnostic: $SWAPREC_OUT"
[ -f "$REPO_SWAPREC/WORKFLOW.md" ] || gov_fail "(9e-swap) fixture lost the original owned file"
echo "  ok (9e-swap) uninstall pins the canonical receipt content at start and rejects a narrower replacement"

# (9e-pin-failure) A modern receipt whose bytes cannot be hashed at start must not open an
# obligation with a missing content pin. Simulate the read/hash failure at the narrow unit boundary,
# then replace the receipt with a valid narrower manifest: there must still be no active record for
# the replacement to close.
REPO_PINFAIL="$WORK/repo-receipt-pin-failure"; mkdir -p "$REPO_PINFAIL/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_PINFAIL/docs/workflow/tracker-config.yaml"
printf 'must remain an obligation\n' > "$REPO_PINFAIL/WORKFLOW.md"
python3 "$RECEIPT" stamp --repo "$REPO_PINFAIL" \
  --out "$REPO_PINFAIL/docs/workflow/install-receipt.yaml" --plugin-version "$RUN_VER" \
  WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9e-pin-failure) could not stamp the original receipt"
SPINFAIL="spinfail-$$-$(basename "$WORK")"
SCRIPTS_DIR="$GOV_PLUGIN/scripts" python3 - "$REPO_PINFAIL" "$SPINFAIL" "$RUN_VER" <<'PY' \
  || gov_fail "(9e-pin-failure) a modern uninstall opened without a start-time receipt digest"
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"], "hooks"))
import idc_command_contract as cc

repo, session, version = sys.argv[1:]
cc._uninstall_receipt_sha256_at_start = lambda *_args: None
record = cc.register_start(repo, session, "uninstall", version, "uninstall", "user")
if record is not None or cc.active_records(repo, session):
    raise SystemExit(1)
PY
printf 'replacement\n' > "$REPO_PINFAIL/replacement-owned.txt"
rm -f "$REPO_PINFAIL/docs/workflow/install-receipt.yaml"
python3 "$RECEIPT" stamp --repo "$REPO_PINFAIL" \
  --out "$REPO_PINFAIL/docs/workflow/install-receipt.yaml" --plugin-version "$RUN_VER" \
  replacement-owned.txt docs/workflow/tracker-config.yaml >/dev/null \
  || gov_fail "(9e-pin-failure) could not stamp the narrower replacement receipt"
if contract finish --repo "$REPO_PINFAIL" --session "$SPINFAIL" --command uninstall \
     --status complete --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' \
     2>/dev/null; then
  gov_fail "(9e-pin-failure) a replacement receipt closed after the original receipt could not be pinned"
fi
echo "  ok (9e-pin-failure) a modern receipt hash failure opens no record, so a replacement cannot close"

# (9-runtime, F6) the removal set is the receipt footprints UNION the documented runtime-created
# artifacts (TRACKER.md at minimum): an applied uninstall that leaves TRACKER.md behind is REFUSED.
REPO_UF="$WORK/repo-uf"; mkdir -p "$REPO_UF/docs/workflow" "$REPO_UF/.claude"
printf 'backend: filesystem\n' > "$REPO_UF/docs/workflow/tracker-config.yaml"
printf 'wf\n' > "$REPO_UF/WORKFLOW.md"; printf 'idc data\n' > "$REPO_UF/TRACKER.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_UF/.claude/settings.json"
python3 "$RECEIPT" stamp --repo "$REPO_UF" --out "$REPO_UF/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null || gov_fail "(9-runtime) stamp failed"
UF_ARCH="idc-archive-uf.tar.gz"; : > "$REPO_UF/$UF_ARCH"
SUF="suf-$$-$(basename "$WORK")"
uf_ev() { printf '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"%s"}}' "$UF_ARCH"; }
contract start --repo "$REPO_UF" --session "$SUF" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'uninstall' --source user >/dev/null
rm -f "$REPO_UF/WORKFLOW.md"   # remove the receipt footprint but LEAVE the runtime TRACKER.md
python3 "$GOV_PLUGIN/scripts/idc_settings_json.py" disable "$REPO_UF/.claude/settings.json" idc@idc-workflow >/dev/null
if contract finish --repo "$REPO_UF" --session "$SUF" --command uninstall --status complete \
     --evidence-json "$(uf_ev)" 2>/dev/null; then
  gov_fail "(9-runtime, F6) an applied uninstall that LEFT the runtime TRACKER.md behind was accepted"
fi
rm -f "$REPO_UF/TRACKER.md"   # now remove the runtime artifact too
contract finish --repo "$REPO_UF" --session "$SUF" --command uninstall --status complete \
  --evidence-json "$(uf_ev)" \
  || gov_fail "(9-runtime, F6) an applied uninstall whose receipt footprints + runtime TRACKER.md are all gone was rejected"
echo "  ok (9-runtime, F6) the removal set includes the documented runtime artifacts (TRACKER.md left behind → refused)"

# (9-flags, F6) a stamped opt-in flag must be HONORED before finish: an uninstall started with
# --close-issues while the board still shows an open issue is REFUSED (verified by a real board read).
REPO_UF2="$WORK/repo-uf2"; mkdir -p "$REPO_UF2/docs/workflow" "$REPO_UF2/.claude"
printf 'backend: filesystem\n' > "$REPO_UF2/docs/workflow/tracker-config.yaml"
printf 'wf\n' > "$REPO_UF2/WORKFLOW.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_UF2/.claude/settings.json"
python3 "$GOV_TRK" --tracker "$REPO_UF2/TRACKER.md" init >/dev/null
python3 "$GOV_TRK" --tracker "$REPO_UF2/TRACKER.md" create --title "still open" --status Todo >/dev/null   # #1 open
python3 "$RECEIPT" stamp --repo "$REPO_UF2" --out "$REPO_UF2/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null || gov_fail "(9-flags) stamp failed"
UF2_ARCH="idc-archive-uf2.tar.gz"; : > "$REPO_UF2/$UF2_ARCH"
SUF2="suf2-$$-$(basename "$WORK")"
uf2_ev() { printf '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"%s"}}' "$UF2_ARCH"; }
contract start --repo "$REPO_UF2" --session "$SUF2" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall --close-issues' --source user >/dev/null
rm -f "$REPO_UF2/WORKFLOW.md"
python3 "$GOV_PLUGIN/scripts/idc_settings_json.py" disable "$REPO_UF2/.claude/settings.json" idc@idc-workflow >/dev/null
# TRACKER.md still present WITH an open issue → the requested --close-issues was NOT honored → refuse.
if contract finish --repo "$REPO_UF2" --session "$SUF2" --command uninstall --status complete \
     --evidence-json "$(uf2_ev)" 2>/dev/null; then
  gov_fail "(9-flags, F6) an uninstall --close-issues with an OPEN board issue still present was accepted"
fi
# honoring it (removing the board substrate → no open issues) + removing the runtime TRACKER.md closes it.
rm -f "$REPO_UF2/TRACKER.md"
contract finish --repo "$REPO_UF2" --session "$SUF2" --command uninstall --status complete \
  --evidence-json "$(uf2_ev)" \
  || gov_fail "(9-flags, F6) an uninstall --close-issues whose board is gone (no open issues) was rejected"
echo "  ok (9-flags, F6) a stamped --close-issues is verified by a real board read (unhonored open issue → refused)"

# (9-delete-github, ROUND-5 F5) on a GITHUB repo, --delete-board must be proven by a REAL board-absence
# read (the project genuinely gone), NEVER by an absent local TRACKER.md (github repos normally have
# none). With no board read available, absence cannot be positively confirmed → the close REFUSES
# (rule B) instead of passing from the missing TRACKER.md.
REPO_DB="$WORK/repo-db"; mkdir -p "$REPO_DB/docs/workflow" "$REPO_DB/.claude"
printf 'backend: github\nproject_number: 10\n' > "$REPO_DB/docs/workflow/tracker-config.yaml"
printf 'wf\n' > "$REPO_DB/WORKFLOW.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_DB/.claude/settings.json"
python3 "$RECEIPT" stamp --repo "$REPO_DB" --out "$REPO_DB/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null || gov_fail "(9-delete-github) stamp failed"
DB_ARCH="idc-archive-db.tar.gz"; : > "$REPO_DB/$DB_ARCH"
SDB="sdb-$$-$(basename "$WORK")"
db_ev() { printf '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"%s"}}' "$DB_ARCH"; }
contract start --repo "$REPO_DB" --session "$SDB" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall --delete-board' --source user >/dev/null
rm -f "$REPO_DB/WORKFLOW.md"   # remove the receipt footprint; a github repo has NO TRACKER.md to begin with
python3 "$GOV_PLUGIN/scripts/idc_settings_json.py" disable "$REPO_DB/.claude/settings.json" idc@idc-workflow >/dev/null
# fake gh errors on `repo view`/`project view` → the github board-absence cannot be confirmed → refuse.
if PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_DB" --session "$SDB" --command uninstall --status complete \
     --evidence-json "$(db_ev)" 2>/dev/null; then
  gov_fail "(9-delete-github, F5) a github --delete-board close PASSED from an absent local TRACKER.md without a real board-absence read"
fi
echo "  ok (9-delete-github, F5) --delete-board requires a real board-absence read (an absent local TRACKER.md on a github repo is NOT proof)"

# (9-delete-malformed, ROUND-6 F2) a PRESENT-but-malformed tracker config must REFUSE a board-absence
# claim — it may NEVER fall back to `filesystem` (that let a corrupt github config 'prove' the board
# deleted via a missing local TRACKER.md). GENUINE ABSENCE of the config keeps its legacy filesystem
# meaning. `_board_absent` is probed directly for the three cases, then end-to-end via --delete-board.
board_absent_probe() {  # $1=repo -> prints True/False/None from the production _board_absent
  SCRIPTS_DIR="$GOV_PLUGIN/scripts" python3 - "$1" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"]); sys.path.insert(0, os.path.join(os.environ["SCRIPTS_DIR"], "hooks"))
import idc_command_contract as cc
print(cc._board_absent(sys.argv[1]))
PY
}
REPO_MAL="$WORK/repo-mal"; mkdir -p "$REPO_MAL/docs/workflow"
printf 'backend: github\nbackend: filesystem\nproject_number: 10\n' > "$REPO_MAL/docs/workflow/tracker-config.yaml"  # present + malformed (two backend keys)
[ "$(board_absent_probe "$REPO_MAL")" = "None" ] \
  || gov_fail "(9-delete-malformed, F2) a malformed PRESENT tracker config resolved a board-absence verdict (must be indeterminate/None, never a filesystem fallback)"
# genuine absence keeps legacy filesystem meaning: no config + no TRACKER.md → gone (True); + TRACKER.md → present (False).
REPO_ABS="$WORK/repo-abs"; mkdir -p "$REPO_ABS/docs/workflow"
[ "$(board_absent_probe "$REPO_ABS")" = "True" ] \
  || gov_fail "(9-delete-malformed, F2) a GENUINELY-ABSENT config with no TRACKER.md must keep filesystem meaning (board gone = True)"
python3 "$GOV_TRK" --tracker "$REPO_ABS/TRACKER.md" init >/dev/null || gov_fail "(9-delete-malformed) could not init REPO_ABS"
[ "$(board_absent_probe "$REPO_ABS")" = "False" ] \
  || gov_fail "(9-delete-malformed, F2) a GENUINELY-ABSENT config with a present TRACKER.md must read the filesystem board present (False)"
# e2e: an uninstall --delete-board on the malformed github config must REFUSE at the closeout (mirror 9-delete-github).
REPO_DBM="$WORK/repo-dbm"; mkdir -p "$REPO_DBM/docs/workflow" "$REPO_DBM/.claude"
printf 'backend: github\nbackend: filesystem\nproject_number: 10\n' > "$REPO_DBM/docs/workflow/tracker-config.yaml"
printf 'wf\n' > "$REPO_DBM/WORKFLOW.md"
printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO_DBM/.claude/settings.json"
python3 "$RECEIPT" stamp --repo "$REPO_DBM" --out "$REPO_DBM/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" WORKFLOW.md docs/workflow/tracker-config.yaml >/dev/null || gov_fail "(9-delete-malformed) stamp failed"
DBM_ARCH="idc-archive-dbm.tar.gz"; : > "$REPO_DBM/$DBM_ARCH"
SDBM="sdbm-$$-$(basename "$WORK")"
contract start --repo "$REPO_DBM" --session "$SDBM" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall --delete-board' --source user >/dev/null
rm -f "$REPO_DBM/WORKFLOW.md"   # remove the receipt footprint; the malformed tracker-config.yaml stays as the anchor
python3 "$GOV_PLUGIN/scripts/idc_settings_json.py" disable "$REPO_DBM/.claude/settings.json" idc@idc-workflow >/dev/null
if PATH="$FAKE_BIN:$PATH" contract finish --repo "$REPO_DBM" --session "$SDBM" --command uninstall --status complete \
     --evidence-json "$(printf '{"schema_version":1,"refs":{"outcome":"applied","settings":".claude/settings.json","archive":"%s"}}' "$DBM_ARCH")" 2>/dev/null; then
  gov_fail "(9-delete-malformed, F2) a github --delete-board close PASSED on a MALFORMED tracker config (board 'proven' deleted via a missing local TRACKER.md)"
fi
echo "  ok (9-delete-malformed, F2) a present-but-malformed tracker config REFUSES a board-absence claim (never a filesystem fallback); genuine absence keeps filesystem meaning"

# (9-noaction-flags, ROUND-5 F5) a no-action must FIRST verify NO board flags were stamped (a
# --close-issues/--delete-board run requested board work → not a no-action) AND that runtime artifacts
# (TRACKER.md) don't need removal.
REPO_NA="$WORK/repo-na"; mkdir -p "$REPO_NA/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_NA/docs/workflow/tracker-config.yaml"
python3 "$RECEIPT" stamp --repo "$REPO_NA" --out "$REPO_NA/docs/workflow/install-receipt.yaml" \
  --plugin-version "$RUN_VER" docs/workflow/tracker-config.yaml >/dev/null || gov_fail "(9-noaction-flags) stamp failed"
# (i) a no-action while --delete-board was stamped → refused (there WAS board work requested).
SNA="sna-$$-$(basename "$WORK")"
contract start --repo "$REPO_NA" --session "$SNA" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'uninstall --delete-board' --source user >/dev/null
if contract finish --repo "$REPO_NA" --session "$SNA" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9-noaction-flags, F5) a no-action while --delete-board was stamped (board work requested) was accepted"
fi
# (ii) a no-action while a runtime TRACKER.md is still present → refused (a runtime artifact must be removed).
SNA2="sna2-$$-$(basename "$WORK")"
printf 'idc data\n' > "$REPO_NA/TRACKER.md"
contract start --repo "$REPO_NA" --session "$SNA2" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'uninstall' --source user >/dev/null
if contract finish --repo "$REPO_NA" --session "$SNA2" --command uninstall --status complete \
     --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' 2>/dev/null; then
  gov_fail "(9-noaction-flags, F5) a no-action while a runtime TRACKER.md is still present was accepted"
fi
# (iii) no flags stamped + no runtime artifacts + all footprints absent → no-action accepted.
rm -f "$REPO_NA/TRACKER.md"
contract finish --repo "$REPO_NA" --session "$SNA2" --command uninstall --status complete \
  --evidence-json '{"schema_version":1,"refs":{"outcome":"no-action"}}' \
  || gov_fail "(9-noaction-flags, F5) a clean no-action (no flags, no runtime artifacts, footprints absent) was rejected"
echo "  ok (9-noaction-flags, F5) no-action verifies stamped flags absent + runtime TRACKER.md removed"

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
# intake fields (they are read from the record). A FRESH session on REPO3's $MANIFEST (Drive
# materialized): S5 still carries its UNMAT_REL obligation, and a different-manifest restart is now
# refused (16e, rule A), so this independent scenario opens its own record rather than swapping S5's.
S5B="s5b-$$-$(basename "$WORK")"
contract start --repo "$REPO3" --session "$S5B" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $MANIFEST_REL --unit Drive" --source user >/dev/null
FAKE_MERGED_PRS="706" FAKE_ISSUE_DIR="$REPO3_ISSUES" gh_finish --repo "$REPO3" --session "$S5B" \
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

# (13-mismatch, F4) the claimed disposition must EQUAL the durable manifest disposition, not merely be
# non-queued: RC_MANIFEST's U1 is `materialized`, so a closeout claiming `verified_done` for it is REFUSED.
contract start --repo "$REPO_RC" --session "$SR" --command recirculate --plugin-root "$GOV_PLUGIN" \
  --args "$REQ_REF" --source user >/dev/null
if contract finish --repo "$REPO_RC" --session "$SR" --command recirculate --status complete \
     --evidence-json "$(printf '{"schema_version":1,"refs":{"closeouts":{"%s":"verified_done"}}}' "$REQ_REF")" 2>/dev/null; then
  gov_fail "(13-mismatch, F4) a recirculate complete claiming 'verified_done' for a 'materialized' manifest unit was accepted"
fi
contract finish --repo "$REPO_RC" --session "$SR" --command recirculate --status complete \
  --evidence-json "$(printf '{"schema_version":1,"refs":{"closeouts":{"%s":"materialized"}}}' "$REQ_REF")" >/dev/null \
  || gov_fail "(13-mismatch, F4) could not close the disposition-equality record honestly"
echo "  ok (13-mismatch, F4) a manifest-unit closeout disposition must EQUAL the durable manifest state ('verified_done' != 'materialized' refused)"

# (13-ticket, ROUND-5 F3) a bare `#<ticket>` terminal disposition is re-derived from DURABLE evidence:
# the board Stage AND Status PLUS the transition journal (how the ticket reached Done). The ONLY
# durably-distinguishable recirc terminal is `drained` — the guarded recirc-retirement door
# (`dispose disposition=drained`, Stage stays Recirculation). `admitted`/`materialized` cannot be told
# apart from a plain drained retirement on a bare Done ticket, so a mismatched terminal disposition is
# refused (rule B); a raw-closed Done (no dispose/drained journal record) is refused too.
REPO_RCT="$WORK/repo-rct"; mkdir -p "$REPO_RCT/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_RCT/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_RCT/TRACKER.md" init >/dev/null || gov_fail "(13-ticket) could not init REPO_RCT"
python3 "$GOV_TRK" --tracker "$REPO_RCT/TRACKER.md" create --title t1 --stage Recirculation --status Done >/dev/null  # #1 Done via the guarded door
python3 "$GOV_TRK" --tracker "$REPO_RCT/TRACKER.md" create --title t2 --stage Recirculation --status Done >/dev/null  # #2 Done RAW (no journal)
# the guarded recirc-retirement door journaled `dispose disposition=drained` for #1 (but NOT #2).
journal_line "$REPO_RCT" '{"op":"dispose","item":1,"disposition":"drained","when":"2026-07-13T00:00:00Z","who":"t","what":"dispose #1 Recirculation -> Done [drained]"}'
SRT2="srt2-$$-$(basename "$WORK")"
# (i) omitting the requested ticket's closeout is refused.
contract start --repo "$REPO_RCT" --session "$SRT2" --command recirculate --plugin-root "$GOV_PLUGIN" --args '#1' --source user >/dev/null
if contract finish --repo "$REPO_RCT" --session "$SRT2" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{}}}' 2>/dev/null; then
  gov_fail "(13-ticket, F3) a recirculate complete with closeouts:{} against a NAMED bare ticket was accepted"
fi
# (ii) a non-terminal disposition ('paused' while the ticket reads Done) is refused.
if contract finish --repo "$REPO_RCT" --session "$SRT2" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#1":"paused"}}}' 2>/dev/null; then
  gov_fail "(13-ticket, F3) a bare-ticket closeout claiming 'paused' while the ticket reads Done was accepted"
fi
# (iii) 'admitted' claimed for a bare Done ticket that was DRAINED is refused (the durable evidence
# proves a `drained` retirement; admitted/drained/materialized are not interchangeable on a bare Done).
if contract finish --repo "$REPO_RCT" --session "$SRT2" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#1":"admitted"}}}' 2>/dev/null; then
  gov_fail "(13-ticket, F3) a bare-ticket closeout claiming 'admitted' for a DRAINED Done ticket was accepted (dispositions interchangeable on a Done)"
fi
# (iv) 'materialized' likewise mismatches the durable drained evidence → refused.
if contract finish --repo "$REPO_RCT" --session "$SRT2" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#1":"materialized"}}}' 2>/dev/null; then
  gov_fail "(13-ticket, F3) a bare-ticket closeout claiming 'materialized' for a DRAINED Done ticket was accepted"
fi
# (v) the durable-evidence-matching disposition ('drained' with a dispose/drained journal record) accepts.
contract finish --repo "$REPO_RCT" --session "$SRT2" --command recirculate --status complete \
  --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#1":"drained"}}}' \
  || gov_fail "(13-ticket, F3) a bare-ticket 'drained' closeout corroborated by the dispose/drained journal record was rejected"
# (vi) 'drained' claimed for #2 — Done but RAW-CLOSED (no dispose/drained journal record) → refused (rule B).
SRT2B="srt2b-$$-$(basename "$WORK")"
contract start --repo "$REPO_RCT" --session "$SRT2B" --command recirculate --plugin-root "$GOV_PLUGIN" --args '#2' --source user >/dev/null
if contract finish --repo "$REPO_RCT" --session "$SRT2B" --command recirculate --status complete \
     --evidence-json '{"schema_version":1,"refs":{"closeouts":{"#2":"drained"}}}' 2>/dev/null; then
  gov_fail "(13-ticket, F3) a bare-ticket 'drained' closeout for a RAW-CLOSED Done ticket (no guarded-retirement journal record) was accepted (rule B)"
fi
echo "  ok (13-ticket, F3) a bare-ticket terminal disposition is re-derived from Stage+Status+journal (interchangeable/raw-closed/non-terminal refused; journal-corroborated drained accepted)"

# (13-gate, F4) recirculate waiting_gate reads the referenced gate for real — an OPEN gate on the board
# is a valid wait; a nonexistent (hollow) or Done gate is refused.
REPO_RCG="$WORK/repo-rcg"; mkdir -p "$REPO_RCG/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_RCG/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO_RCG/TRACKER.md" init >/dev/null || gov_fail "(13-gate) could not init REPO_RCG"
python3 "$GOV_TRK" --tracker "$REPO_RCG/TRACKER.md" create --title g1 --status Blocked >/dev/null   # #1 open gate
python3 "$GOV_TRK" --tracker "$REPO_RCG/TRACKER.md" create --title g2 --status Done >/dev/null       # #2 closed gate
r="$(direct_validate recirculate waiting_gate '{"schema_version":1,"refs":{"gate":"#999"}}' "$REPO_RCG")"
[ "$r" != "ok" ] || gov_fail "(13-gate, F4) a recirculate waiting_gate on a HOLLOW (nonexistent) gate was accepted"
r="$(direct_validate recirculate waiting_gate '{"schema_version":1,"refs":{"gate":"#2"}}' "$REPO_RCG")"
[ "$r" != "ok" ] || gov_fail "(13-gate, F4) a recirculate waiting_gate on a Done (closed) gate was accepted"
r="$(direct_validate recirculate waiting_gate '{"schema_version":1,"refs":{"gate":"#1"}}' "$REPO_RCG")"
[ "$r" = "ok" ] || gov_fail "(13-gate, F4) a recirculate waiting_gate on a real OPEN gate was rejected ($r)"
echo "  ok (13-gate, F4) recirculate waiting_gate reads the referenced gate for real (hollow/closed gate refused)"

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

# (14-janitor, F7) janitor complete re-reads THIS session's persisted janitor report, which the SCANNER
# RUN writes (the honest path actually runs the scanner) bound to the active record's NONCE — a caller
# scanner_exit, and a report NOT bound to the record's nonce, are both refused.
REPO_JAN="$WORK/repo-jan"; mkdir -p "$REPO_JAN/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_JAN/docs/workflow/tracker-config.yaml"
git -C "$REPO_JAN" init -q && git -C "$REPO_JAN" add -A \
  && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
     git -C "$REPO_JAN" commit -qm init || gov_fail "(14-janitor) could not init the janitor git repo"
contract start --repo "$REPO_JAN" --session "$S6" --command janitor --plugin-root "$GOV_PLUGIN" --args 'scan' --source user >/dev/null
# (i) a caller scanner_exit with NO persisted report is refused.
if contract finish --repo "$REPO_JAN" --session "$S6" --command janitor --status complete \
     --evidence-json '{"schema_version":1,"refs":{"scanner_exit":0}}' 2>/dev/null; then
  gov_fail "(14-janitor) a janitor complete with a caller scanner_exit but NO persisted report was accepted"
fi
# (ii) a hand-written report NOT bound to the record's nonce is refused (must be written by the scanner run).
python3 "$CR" --cwd "$REPO_JAN" write --kind janitor --session "$S6" \
  --payload-json '{"scanner_exit":1,"clean":false,"nonce":"forged-nonce","produced_by":"idc_git_janitor.py"}' >/dev/null
if contract finish --repo "$REPO_JAN" --session "$S6" --command janitor --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(14-janitor) a janitor complete backed by a report NOT bound to the record nonce was accepted"
fi
# (ii-prov, ROUND-5 F7) a hand-written report bound to the record nonce but LACKING the scanner's
# provenance stamp is refused — a hand-written report cannot be passed off as a real scan.
python3 "$CR" --cwd "$REPO_JAN" write --kind janitor --session "$S6" \
  --payload-json "$(printf '{"scanner_exit":0,"clean":true,"nonce":"%s"}' "$(rec_nonce "$REPO_JAN" "$S6" janitor)")" >/dev/null
if contract finish --repo "$REPO_JAN" --session "$S6" --command janitor --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(14-janitor, F7) a janitor complete backed by a HAND-WRITTEN report (no scanner provenance) was accepted"
fi
# (iii) the honest path: RUN the real scanner, which writes the report bound to the record's nonce.
JAN_NONCE="$(rec_nonce "$REPO_JAN" "$S6" janitor)"
[ -n "$JAN_NONCE" ] || gov_fail "(14-janitor) the janitor record carries no nonce"
python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO_JAN" \
  --report-session "$S6" --report-nonce "$JAN_NONCE" >/dev/null 2>&1
contract finish --repo "$REPO_JAN" --session "$S6" --command janitor --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(14-janitor) a janitor complete backed by the SCANNER-written, nonce-bound report was rejected"
echo "  ok (14-janitor, F7) janitor complete re-reads the SCANNER-written report bound to the record nonce (caller exit / unbound report refused)"

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
# (F7) the closeout RUNS the real FINGERPRINT verification, not a syntax parse: a stamped file whose
# bytes were modified after stamping (scaffold drift) fails the init complete closed.
printf 'TAMPERED\n' > "$REPO_INIT/WORKFLOW.md"
if contract finish --repo "$REPO_INIT" --session "$SI2" --command init --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(14-init, F7) an init complete accepted a receipt whose stamped file was MODIFIED (no fingerprint check)"
fi
printf 'workflow\n' > "$REPO_INIT/WORKFLOW.md"   # restore to the exact stamped bytes
contract finish --repo "$REPO_INIT" --session "$SI2" --command init --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(14-init) an init complete backed by a v2 receipt + anchor + enablement + intact fingerprints was rejected"
echo "  ok (14-init, F6/F7) init complete re-derives from the install receipt + anchor + enablement + RUNS the fingerprint verify (modified scaffold refused)"

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
# (F7) update ALSO runs the fingerprint verify: a modified stamped file fails the update complete closed.
printf 'TAMPERED\n' > "$REPO_UPD/WORKFLOW.md"
if contract finish --repo "$REPO_UPD" --session "$SU2" --command update --status complete \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(14-update, F7) an update complete accepted a receipt whose stamped file was MODIFIED (no fingerprint check)"
fi
printf 'workflow\n' > "$REPO_UPD/WORKFLOW.md"   # restore to the exact stamped bytes
contract finish --repo "$REPO_UPD" --session "$SU2" --command update --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(14-update) an update complete whose receipt plugin_version == the running version + intact fingerprints was rejected"
echo "  ok (14-update, F6/F7) update complete re-derives receipt v2 + plugin_version == running + RUNS the fingerprint verify (modified scaffold refused)"

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

# ============================================================================================
# (16, ROUND-5 F1 — rule A) MONOTONIC OBLIGATIONS. A second command_start for the same
# (session, command) may only UNION the stamped obligation, never replace/narrow it. A re-entry with a
# SMALLER arg set still owes every obligation the record was opened with.
rec_field_json() {  # $1=repo $2=session $3=command $4=field -> the active record's field as JSON (or null)
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]+"/.idc-session-state.json"))
r=next((c for c in d["commands"] if c.get("state")=="active" and c.get("session_id")==sys.argv[2] and c.get("command")==sys.argv[3]),{})
print(json.dumps(r.get(sys.argv[4])))' "$1" "$2" "$3" "$4"
}
field_has() {  # $1=json-list $2=needle -> exit 0 iff needle is present (string-compared)
  python3 -c 'import json,sys; lst=json.loads(sys.argv[1]) or []; sys.exit(0 if sys.argv[2] in [str(x) for x in lst] else 1)' "$1" "$2"
}
SM="sm-$$-$(basename "$WORK")"
# (16a) build `#1 #2` restart as `#1` still owes BOTH issues.
contract start --repo "$REPO" --session "$SM" --command build --plugin-root "$GOV_PLUGIN" --args '#1 #2' --source user >/dev/null
contract start --repo "$REPO" --session "$SM" --command build --plugin-root "$GOV_PLUGIN" --args '#1' --source user >/dev/null
BR="$(rec_field_json "$REPO" "$SM" build build_requested)"
field_has "$BR" 1 && field_has "$BR" 2 \
  || gov_fail "(16a, F1) a build restart with FEWER issues SHED an obligation (build_requested=$BR, expected #1 AND #2)"
echo "  ok (16a, F1) build requested-set unions across a narrowing restart (both #1 and #2 still owed)"
# (16b) uninstall two-flag restart as one still owes BOTH flags.
contract start --repo "$REPO" --session "$SM" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'uninstall --close-issues --delete-board' --source user >/dev/null
contract start --repo "$REPO" --session "$SM" --command uninstall --plugin-root "$GOV_PLUGIN" --args 'uninstall --close-issues' --source user >/dev/null
UFM="$(rec_field_json "$REPO" "$SM" uninstall uninstall_flags)"
field_has "$UFM" close-issues && field_has "$UFM" delete-board \
  || gov_fail "(16b, F1) an uninstall restart with FEWER flags SHED an obligation (uninstall_flags=$UFM, expected close-issues AND delete-board)"
echo "  ok (16b, F1) uninstall flag-set unions across a narrowing restart (both flags still owed)"
# (16c) think intake restart with FEWER units still owes BOTH selected units (same manifest).
contract start --repo "$REPO" --session "$SM" --command think --plugin-root "$GOV_PLUGIN" --args '--doc mono.json --unit U0,U1' --source user >/dev/null
contract start --repo "$REPO" --session "$SM" --command think --plugin-root "$GOV_PLUGIN" --args '--doc mono.json --unit U0' --source user >/dev/null
TUM="$(rec_field_json "$REPO" "$SM" think intake_units)"
field_has "$TUM" U0 && field_has "$TUM" U1 \
  || gov_fail "(16c, F1) a think intake restart with FEWER units SHED an obligation (intake_units=$TUM, expected U0 AND U1)"
echo "  ok (16c, F1) think intake unit-set unions across a narrowing restart (both units still owed)"
# (16d) recirculate named-item restart with FEWER items still owes BOTH.
contract start --repo "$REPO" --session "$SM" --command recirculate --plugin-root "$GOV_PLUGIN" --args 'mono.json#U0 mono.json#U1' --source user >/dev/null
contract start --repo "$REPO" --session "$SM" --command recirculate --plugin-root "$GOV_PLUGIN" --args 'mono.json#U0' --source user >/dev/null
RRM="$(rec_field_json "$REPO" "$SM" recirculate recirc_requested)"
field_has "$RRM" mono.json#U0 && field_has "$RRM" mono.json#U1 \
  || gov_fail "(16d, F1) a recirculate restart with FEWER named items SHED an obligation (recirc_requested=$RRM, expected both)"
echo "  ok (16d, F1) recirculate requested-set unions across a narrowing restart (both named items still owed)"
# (16e, ROUND-6 F1) a Think re-start binding a DIFFERENT intake manifest is REFUSED at command_start —
# a same-manifest restart unions its units (16c), but silently REPLACING the manifest would drop the
# first manifest's exact-once coverage obligation. The refusal leaves the prior record intact: it STILL
# owes the FIRST manifest + its units.
SMT="smt-$$-$(basename "$WORK")"
contract start --repo "$REPO" --session "$SMT" --command think --plugin-root "$GOV_PLUGIN" --args '--doc first.json --unit U0' --source user >/dev/null
if contract start --repo "$REPO" --session "$SMT" --command think --plugin-root "$GOV_PLUGIN" --args '--doc second.json --unit V0' --source user >/dev/null 2>&1; then
  gov_fail "(16e, F1) a Think re-start binding a DIFFERENT manifest was ACCEPTED (it replaced the stamped obligation instead of refusing)"
fi
TMAN="$(rec_field_json "$REPO" "$SMT" think intake_manifest)"
[ "$TMAN" = '"first.json"' ] \
  || gov_fail "(16e, F1) after the refused different-manifest restart, intake_manifest=$TMAN (must still owe the FIRST manifest first.json, never second.json)"
TMU="$(rec_field_json "$REPO" "$SMT" think intake_units)"
field_has "$TMU" U0 \
  || gov_fail "(16e, F1) the refused restart shed the first manifest's units (intake_units=$TMU, expected U0)"
echo "  ok (16e, F1) a different-manifest Think restart is refused at command_start; the first manifest's coverage obligation stands"

echo "PASS: the IDC command lifecycle envelope + wave-3 evidence contract hold — every terminal fact is re-derived from durable state (consideration re-run, gate marker/disposal, pointer admission, admitted-consideration set, receipt/report/journal, real gh reads), a forged or omitting claim is refused across all eleven commands, and the 2026-07-12 incident shape is blocked at Think closeout"
