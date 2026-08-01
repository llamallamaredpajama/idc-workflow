#!/bin/bash
# idc-assert-class: behavior
# janitor-doctor-no-persist.sh — doctor's diagnostic janitor scan must not write the governed tree.
#
# commands/doctor.md:7 promises doctor's probes are "read-only for source files and tracker/board
# state", yet the Row-10 janitor scan used to create `docs/workflow/reconciliation-seen-findings.json`
# — a durable governed-repo file — via the U7 seen-ledger recording (verified live in a sandbox run).
# The fix: `idc_git_janitor.py --no-persist-seen-ledger` READS the ledger for the `seen_before` marks
# but never writes it, and doctor.md Row 10 passes that flag on both backends. A REAL janitor run
# keeps persisting — that recording is the shipped U7 dedupe feature and must not weaken.
#
# What this scenario proves, on a hermetic filesystem-backend repo WITH findings (so the write path
# is genuinely reached — an empty scan proves nothing about a suppressed write):
#   1. doctor.md Row 10 wires --no-persist-seen-ledger into BOTH scanner invocations (a flag nobody
#      passes suppresses nothing);
#   2. a doctor-style scan (--no-persist-seen-ledger) reports its findings (exit 1) and leaves NO
#      docs/workflow/reconciliation-seen-findings.json behind;
#   3. POSITIVE CONTROL: the SAME fixture without the flag DOES write the ledger with the finding's
#      fingerprint — so assertion 2's absence is the flag's doing, not a fixture that never reached
#      the recording;
#   4. the read side stays live: with the ledger now present, a second no-persist scan marks the
#      resurfaced finding `seen_before` WITHOUT bumping its seen_count (read-only means read works);
#   5. the diagnostic posture refuses to combine with --apply-safe (discriminating stderr marker +
#      positive control via assert_fail_closed) — mutating modes keep the recording.
#
# Red-when-broken (each observed): make --no-persist-seen-ledger a no-op (persist=True always) =>
# assertion 2 fails on the ledger appearing; drop the flag from either doctor.md Row-10 invocation
# => assertion 1 fails; delete the combination guard => assertion 5 fails.
#
# Usage: bash tests/smoke/governance/janitor-doctor-no-persist.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/../lib/fail-closed.sh"
fail() { gov_fail "$1"; }

JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
DOCTOR_MD="$GOV_PLUGIN/commands/doctor.md"
fc_require_file "$JAN" "scripts/idc_git_janitor.py"
fc_require_file "$TRK" "scripts/idc_tracker_fs.py"
fc_require_file "$DOCTOR_MD" "commands/doctor.md"

# ── 1. doctor.md Row 10 actually passes the flag (a suppression nobody wires is dead) ─────────────
python3 - "$DOCTOR_MD" <<'PY' || gov_fail "doctor.md Row 10 must pass --no-persist-seen-ledger to EVERY idc_git_janitor.py invocation (both backends) — without it the doctor scan durably writes docs/workflow/reconciliation-seen-findings.json into the governed tree, breaking its read-only contract"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
heads = list(re.finditer(r'^\*\*(\d+[a-z]?) — .*$', text, re.M))
hits = [i for i, m in enumerate(heads) if re.search(r'Board.{0,3}git reconciliation', m.group(0), re.I)]
if not hits:
    sys.exit("no board-git reconciliation row found in doctor.md")
i = hits[0]
end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
row = text[heads[i].start():end]
# Row 10 is the last numbered row, so also stop at the next `## ` section (Output/lifecycle prose
# would otherwise ride along and its idc_command_report example is not a scanner invocation).
section = re.search(r'^## ', row, re.M)
if section:
    row = row[:section.start()]
# Join backslash-continued shell lines so a multi-line invocation is checked as one command.
physical = row.splitlines()
lines, j = [], 0
while j < len(physical):
    command = physical[j]
    while command.rstrip().endswith("\\") and j + 1 < len(physical):
        command = command.rstrip()[:-1] + " " + physical[j + 1].strip()
        j += 1
    lines.append(command)
    j += 1
invocations = [ln for ln in lines if "/scripts/idc_git_janitor.py" in ln and "python3" in ln]
if len(invocations) < 2:
    sys.exit("expected the github AND filesystem scanner invocations in Row 10, found %d" % len(invocations))
missing = [ln for ln in invocations if "--no-persist-seen-ledger" not in ln]
if missing:
    sys.exit("Row-10 invocation(s) missing --no-persist-seen-ledger: %r" % missing)
PY

# ── fixture: a hermetic repo whose scan yields a real post-boundary finding ───────────────────────
WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow" || gov_fail "could not create repo dirs"
git init -q -b main "$REPO" || gov_fail "git init failed"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "tracker init failed"
: > "$REPO/docs/workflow/transition-journal.ndjson"
printf base > "$REPO/app.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
LEGACY="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'legacy item' --stage Buildable)" \
  || gov_fail "legacy item create failed"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)" || gov_fail "could not read baseline head"
cat > "$REPO/docs/workflow/reconciliation-adoption.json" <<JSON
{
  "schema_version": 1,
  "state": "legacy-adopted",
  "default_branch": {"name": "main", "head": "$HEAD_SHA"},
  "journal_entry_count": 0,
  "legacy_items": [
    {"number": $LEGACY, "stage": "Buildable", "status": "Todo", "evidence_class": "legacy-adopted", "historical_verification": "not-claimed"}
  ],
  "routed_obligations": [],
  "unresolved": []
}
JSON
RAW="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'raw post-boundary item' --stage Buildable)" \
  || gov_fail "post-boundary raw create failed"
LEDGER="$REPO/docs/workflow/reconciliation-seen-findings.json"

# ── 2. the doctor-style scan finds debris but leaves NO durable ledger behind ─────────────────────
set +e
OUT_DIAG="$(timeout 120 python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" \
            --no-persist-seen-ledger --json)"; RC_DIAG=$?
set -e
[ "$RC_DIAG" -ne 124 ] || gov_fail "doctor-style scan timed out (a hang is RED, never a slow pass)"
[ "$RC_DIAG" -eq 1 ] || gov_fail "doctor-style scan must exit 1 with findings (the write path is only proven reached on a non-empty scan), got $RC_DIAG"
REPORT_JSON="$OUT_DIAG" python3 - <<'PY' || gov_fail "doctor-style scan reported no findings — an empty scan cannot prove the suppressed write"
import json, os, sys
report = json.loads(os.environ["REPORT_JSON"])
sys.exit(0 if (report.get("findings") or []) else 1)
PY
[ ! -e "$LEDGER" ] \
  || gov_fail "the doctor-style (--no-persist-seen-ledger) scan WROTE docs/workflow/reconciliation-seen-findings.json into the governed tree — doctor's read-only contract is broken again"

# ── 3. POSITIVE CONTROL: the same fixture without the flag DOES record the ledger ─────────────────
set +e
OUT_REAL="$(timeout 120 python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC_REAL=$?
set -e
[ "$RC_REAL" -eq 1 ] || gov_fail "real janitor scan must exit 1 with findings, got $RC_REAL"
[ -f "$LEDGER" ] \
  || gov_fail "the REAL janitor scan no longer writes the seen ledger — the U7 dedupe recording (a shipped feature) has been weakened, so the no-persist assertion above proves nothing"
REPORT_JSON="$OUT_REAL" python3 - "$LEDGER" <<'PY' || gov_fail "the real scan's ledger does not carry the finding's fingerprint — the positive control did not exercise the recording this scenario suppresses"
import json, os, sys
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings") or []
fps = {f.get("fingerprint") for f in findings if f.get("fingerprint")}
assert fps, findings
ledger = json.load(open(sys.argv[1]))
recorded = {entry.get("fingerprint") for entry in (ledger.get("entries") or [])}
assert fps & recorded, (fps, recorded)
PY

# ── 4. the read side stays live: seen_before flips, seen_count does NOT increment ─────────────────
COUNTS_BEFORE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted((e["fingerprint"], e["seen_count"]) for e in d["entries"]))' "$LEDGER")"
set +e
OUT_DIAG2="$(timeout 120 python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" \
             --no-persist-seen-ledger --json)"; RC_DIAG2=$?
set -e
[ "$RC_DIAG2" -eq 1 ] || gov_fail "second doctor-style scan must exit 1 with findings, got $RC_DIAG2"
REPORT_JSON="$OUT_DIAG2" python3 - <<'PY' || gov_fail "a no-persist scan over an existing ledger did not mark the resurfaced finding seen_before — the diagnostic read path is dead, not read-only"
import json, os, sys
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings") or []
sys.exit(0 if any(f.get("seen_before") for f in findings) else 1)
PY
COUNTS_AFTER="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted((e["fingerprint"], e["seen_count"]) for e in d["entries"]))' "$LEDGER")"
[ "$COUNTS_BEFORE" = "$COUNTS_AFTER" ] \
  || gov_fail "a --no-persist-seen-ledger scan still MUTATED the ledger (seen_count moved): before=$COUNTS_BEFORE after=$COUNTS_AFTER"

# ── 5. the diagnostic posture refuses mutating modes (fail-closed, discriminating marker) ─────────
assert_fail_closed \
  "--no-persist-seen-ledger combined with --apply-safe must refuse (mutating modes keep the U7 recording)" \
  "diagnostic read-only posture and cannot be combined" \
  -- python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --no-persist-seen-ledger --apply-safe \
  -- python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --no-persist-seen-ledger --json

echo "PASS: doctor's diagnostic janitor scan is genuinely read-only (no seen-ledger write), the real janitor still records, the read side stays live, and mutating modes refuse the diagnostic flag"
