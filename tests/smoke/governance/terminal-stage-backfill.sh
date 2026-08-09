#!/bin/bash
# idc-assert-class: behavior
# terminal-stage-backfill.sh — #213: a TERMINAL (Done) item with a missing Stage has a sanctioned
# repair, and it is the reconciler — not a loosened transition.
#
# THE GAP. A Done item whose Stage is absent could not be repaired through ANY door:
#   * `move` — and every transition — refuses a terminal item, engine-wide (the terminal invariant);
#   * `set-field` refuses Stage/Status by design ("a Status change is a transition — use move").
# So the only way through was the raw `gh project item-edit` the mutation interlock forbids, which is
# exactly what the reporting session did (knowledge-engine 4731f696, unjournaled, advisory mode).
#
# THE DESIGN CALL this lane pins (see the PR body and templates/workflow-machine.yaml):
# repair belongs to the JANITOR RECONCILER, which the machine table ALREADY discloses as the one
# non-engine door that may stamp board truth. It is not an exception carved into the terminal
# invariant — it is a different KIND of operation. The reconciler copies the Stage the JOURNAL
# already recorded onto the row that lost it, asserts nothing new, and journals `janitor-repair`
# (never an engine `move`/`close`), so the audit trail always tells a reconciliation from a guarded
# transition and replay CONVERGES instead of re-reporting the divergence forever.
#
# The boundary, asserted here too: when BOTH sides assert a Stage and they DIFFER, it stays a manual
# RISKY finding. Picking a winner between two asserted values is a decision, and the reconciler makes
# none — that is the line between reconciling truth and deciding a transition.
#
# Red-when-broken: see the per-case notes.
#
# Usage: bash tests/smoke/governance/terminal-stage-backfill.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

T_S="${T_S:-120}"
command -v timeout >/dev/null 2>&1 \
  || fail "BLOCKED: \`timeout\` is not on PATH. Every probe here runs under an explicit bound so a
hung helper REDS instead of looking like a slow pass. Run via tests/smoke/run-all.sh, or install
coreutils, then re-run."

git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t 2>/dev/null
git -C "$REPO" config user.name t 2>/dev/null
git -C "$REPO" commit -q --allow-empty -m init 2>/dev/null

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
janitor() { timeout "$T_S" python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" \
              --repo "$REPO" --tracker "$T" --check-journal-divergence "$@" 2>&1; }

# ── the fixture: a genuinely TERMINAL item whose board Stage was lost ─────────────────────────────
# Created through the engine, so the JOURNAL carries its Stage (that is the truth the repair copies).
item="$(eng create-ticket --title 'terminal stage backfill' --stage 'Buildable' --status 'Todo')"
[ -f "$JOURNAL" ] || fail "fixture: the engine op did not create the canonical journal"
grep -q '"stage": "Buildable"' "$JOURNAL" \
  || fail "fixture: the journal does not record the created Stage, so there is no truth to copy"

# Drive the board to the state #213 describes, WITHOUT the engine — because that is the point: the
# engine cannot produce it and cannot repair it. Status=Done (terminal) and Stage blanked.
# Stage is blanked by editing the tracker row directly, because the fs tracker's own `set` REFUSES
# an empty Stage — which is the point: no sanctioned door can produce OR repair this state, so the
# fixture has to write it the way the real world did (a board row that simply lost its value).
python3 "$GOV_TRK" --tracker "$T" set --num "$item" --field Status --value Done >/dev/null
python3 - "$T" "$item" <<'PY'
import json, sys
path, num = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
# The tracker's AUTHORITATIVE state is the embedded JSON object (the markdown table below it is a
# rendering). Locate it by brace matching from `{"next_number"`, blank the Stage there, then
# re-render the table cell to match — the state a real board row in this condition would be in.
begin = raw.index('{\n  "next_number"')
depth, i = 0, begin
while i < len(raw):
    if raw[i] == "{":
        depth += 1
    elif raw[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
stop = i + 1
doc = json.loads(raw[begin:stop])
found = False
for issue in doc.get("issues", []):
    if str(issue.get("number")) == num:
        issue["stage"] = ""
        found = True
assert found, "fixture: no issue %s in the tracker state block" % num
raw = raw[:begin] + json.dumps(doc, indent=2) + raw[stop:]
out = []
for line in raw.splitlines():
    cells = [c.strip() for c in line.split("|")]
    if len(cells) > 5 and cells[1] == num:
        cells[4] = "\u2014"
        line = "| " + " | ".join(cells[1:-1]) + " |"
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
[ "$(gov_field "$T" "$item" Status)" = "Done" ] \
  || fail "fixture: the item is not terminal, so this lane would not be testing #213 at all"
[ -z "$(gov_field "$T" "$item" Stage)" ] || [ "$(gov_field "$T" "$item" Stage)" = "—" ] \
  || fail "fixture: the board Stage was not cleared, so there is nothing to backfill"

# ── CONTROL: every sanctioned door really does refuse this repair ─────────────────────────────────
# Without this the reconciler could be redundant — and the whole design call rests on there being no
# other way in.
# NOTE: this file runs under `set -uo pipefail` with NO errexit, deliberately — the janitor exits
# non-zero whenever it has findings, which is the normal case here, so a stray `set -e` would end the
# lane at the first report instead of asserting on it.
MOVE_OUT="$(timeout "$T_S" python3 "$GOV_ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" \
             move --num "$item" --to-status Done --to-stage Recirculation 2>&1)"
MOVE_RC=$?
SET_OUT="$(timeout "$T_S" python3 "$GOV_ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" \
            set-field --num "$item" --field Stage --value Buildable 2>&1)"
SET_RC=$?
[ "$MOVE_RC" -ne 0 ] \
  || fail "#213 control: \`move\` ACCEPTED a terminal item — the terminal invariant is not holding,
so this lane's premise (no sanctioned door exists) is wrong. Output: $MOVE_OUT"
[ "$SET_RC" -ne 0 ] \
  || fail "#213 control: \`set-field\` ACCEPTED a Stage write — it refuses Stage by design, so the
premise that no sanctioned door exists is wrong. Output: $SET_OUT"

# ── 1. the reconciler REPORTS it as a repairable SAFE-FIX, not a manual RISKY ─────────────────────
janitor --json > "$REPO/report1.json"
grep -q '"dim": "stage"' "$REPO/report1.json" \
  || fail "#213: the janitor does not surface a missing Stage on a terminal item as its own
repairable finding, so there is still no sanctioned door. Report was:
$(cat "$REPO/report1.json")"
grep -q '"tier": "SAFE-FIX"' "$REPO/report1.json" \
  || fail "#213: the Stage backfill is not SAFE-FIX, so --apply-safe will never repair it. Report:
$(cat "$REPO/report1.json")"

# ── 2. --apply-safe repairs it, on a TERMINAL item, without touching Status ───────────────────────
janitor --apply-safe --json > "$REPO/applied.json"
[ "$(gov_field "$T" "$item" Stage)" = "Buildable" ] \
  || fail "#213: --apply-safe did not backfill the Stage the journal recorded. This is the whole
issue: a Done item with a missing Stage had NO sanctioned repair, and the only way through was the
raw board write the mutation interlock forbids. Applied output:
$(cat "$REPO/applied.json")"
[ "$(gov_field "$T" "$item" Status)" = "Done" ] \
  || fail "#213: the Stage repair CHANGED Status. A reconciler copies board truth; it must never
move an item, least of all a terminal one — that is the line between reconciliation and transition"

# ── 3. it journals as the JANITOR's own op, never an engine transition ────────────────────────────
grep -q '"door": "janitor-stage-backfill"' "$JOURNAL" \
  || fail "#213: the repair did not disclose its own door in the journal — an audit reader cannot
tell a reconciliation from a guarded transition without it"
if grep '"door": "janitor-stage-backfill"' "$JOURNAL" | grep -qE '"op": "(move|close|dispose|set-field)"'; then
  fail "#213: the reconciler journaled an ENGINE-OP look-alike. The engine's ops are guarded doors;
a look-alike record launders a reconciliation into a sanctioned transition in the audit trail"
fi
grep -q '"op": "janitor-repair"' "$JOURNAL" \
  || fail "#213: the repair must be journaled as op=janitor-repair (the reconciler's own op)"

# ── 4. it CONVERGES — the divergence is not re-reported forever ───────────────────────────────────
# This is the issue's second half: whatever door ships must let the reconciliation absorb the residue
# rather than flag it every scan.
#
# HONEST NOTE on what this asserts: convergence here comes from the BOARD WRITE — once the row carries
# the Stage the journal already recorded, the two agree and there is nothing left to diverge. The
# `to_stage` on the janitor-repair record is DISCLOSURE (the record says what it did), not the
# convergence mechanism, and removing it does NOT redden this case. It is kept because a repair record
# that does not state what it repaired is not an audit line.
janitor --json > "$REPO/rescan.json"
grep -q '"dim": "stage"' "$REPO/rescan.json" \
  && fail "#213: the repaired item is STILL reported as a Stage divergence on the next scan — the
repair must journal its to_stage so replay converges, or the operator sees this finding forever.
Re-scan:
$(cat "$REPO/rescan.json")"

# ── 5. THE BOUNDARY: two asserted Stages stay manual ──────────────────────────────────────────────
# The reconciler copies truth; it never picks a winner. A board value that CONTRADICTS the journal is
# a decision, and auto-applying one would let the reconciler overwrite real board state.
other="$(eng create-ticket --title 'contradicting stage' --stage 'Buildable' --status 'Todo')"
python3 "$GOV_TRK" --tracker "$T" set --num "$other" --field Stage --value Recirculation >/dev/null
janitor --json > "$REPO/conflict.json"
grep -q "Stage mismatch" "$REPO/conflict.json" \
  || fail "#213: a board Stage CONTRADICTING the journal is no longer reported at all — the conflict
case must stay visible, just not auto-applied. Report:
$(cat "$REPO/conflict.json")"
BEFORE="$(gov_field "$T" "$other" Stage)"
janitor --apply-safe --json >/dev/null
[ "$(gov_field "$T" "$other" Stage)" = "$BEFORE" ] \
  || fail "#213: --apply-safe OVERWROTE a board Stage that contradicted the journal. Choosing
between two asserted values is a decision, and the reconciler makes none — it may only fill in a
value that is MISSING. (Board was '$BEFORE', is now '$(gov_field "$T" "$other" Stage)'.)"

# ── 6. NON-TERMINAL items keep their manual finding ──────────────────────────────────────────────
# The machine contract authorizes this door for a TERMINAL item — the one no door can repair. A
# non-terminal item is still `move`-able, so it needs no backdoor; and auto-stamping one is actively
# unsafe: a journal-expected `Recirculation` on an `In Progress` row is the worked_forbidden_stages
# pair the engine refuses outright, so the reconciler would write a state no door would accept.
live="$(eng create-ticket --title 'nonterminal blank stage' --stage 'Recirculation' --status 'Todo')"
eng claim --num "$live" --agent tester >/dev/null 2>&1 || true
python3 - "$T" "$live" <<'PY'
import json, sys
path, num = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
begin = raw.index('{\n  "next_number"')
depth, i = 0, begin
while i < len(raw):
    if raw[i] == "{": depth += 1
    elif raw[i] == "}":
        depth -= 1
        if depth == 0: break
    i += 1
doc = json.loads(raw[begin:i + 1])
for issue in doc.get("issues", []):
    if str(issue.get("number")) == num:
        issue["stage"] = ""
        issue["status"] = "In Progress"
open(path, "w", encoding="utf-8").write(raw[:begin] + json.dumps(doc, indent=2) + raw[i + 1:])
PY
janitor --json > "$REPO/nonterminal.json"
python3 - "$REPO/nonterminal.json" "$live" <<'PY' || exit 1
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
num = int(sys.argv[2])
bad = [f for f in report.get("findings", [])
       if f.get("dim") == "stage" and f.get("number") == num and f.get("tier") == "SAFE-FIX"]
if bad:
    print("FAIL: #213: a NON-TERMINAL item with a blank Stage was classified SAFE-FIX. The reconciler "
          "is authorized for a terminal item — the one no door can repair — and auto-stamping a "
          "non-terminal one can write a Stage/Status pair the engine itself refuses "
          "(worked_forbidden_stages). Finding: %r" % bad)
    raise SystemExit(1)
PY

# ── 7. the repair RE-PROVES its precondition before writing ──────────────────────────────────────
# The finding is classified during the scan; another writer can fill the Stage in — with a DIFFERENT
# value — before apply. Applying the cached finding would overwrite an asserted value and journal a
# stale repair, which is exactly the conflict this door refuses to decide.
race="$(eng create-ticket --title 'raced stage' --stage 'Buildable' --status 'Todo')"
python3 - "$T" "$race" <<'PY'
import json, sys
path, num = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
begin = raw.index('{\n  "next_number"')
depth, i = 0, begin
while i < len(raw):
    if raw[i] == "{": depth += 1
    elif raw[i] == "}":
        depth -= 1
        if depth == 0: break
    i += 1
doc = json.loads(raw[begin:i + 1])
for issue in doc.get("issues", []):
    if str(issue.get("number")) == num:
        issue["stage"] = ""
        issue["status"] = "Done"
open(path, "w", encoding="utf-8").write(raw[:begin] + json.dumps(doc, indent=2) + raw[i + 1:])
PY
timeout "$T_S" python3 - "$GOV_PLUGIN/scripts" "$REPO" "$T" "$race" <<'PY' >"$REPO/race.out" 2>&1
import sys
scripts, repo, tracker, num = sys.argv[1:5]
sys.path.insert(0, scripts)
import idc_git_janitor as J

# The finding as the scan produced it: Stage is blank, backfill 'Buildable'.
finding = {"tier": J.SAFE_FIX, "dim": "stage", "name": "#%s" % num, "number": int(num),
           "op": "set-stage", "stage": "Buildable", "detail": "scan-time"}
ctx = {"repo": repo, "tracker": tracker}

# ...but another writer got there first with a DIFFERENT value.
real_live = J._live_stage
J._live_stage = lambda n, b, c: "Recirculation"
ok, note = J._apply_stage(finding, ctx)
J._live_stage = real_live
print("ok=%s note=%s" % (ok, note))
PY
grep -q "ok=False" "$REPO/race.out" \
  || fail "#213: the repair applied a CACHED finding without re-proving the Stage was still blank. If
another writer filled it between scan and apply, this overwrites an asserted value and journals a
stale repair — the very conflict this door refuses to decide. Got:
$(cat "$REPO/race.out")"
grep -qi "no longer blank" "$REPO/race.out" \
  || fail "#213: the refusal must name the raced precondition. Got: $(cat "$REPO/race.out")"

# ── 8. the SHIPPED janitor path can actually reach this repair ───────────────────────────────────
# The finding is produced by the journal↔board pass, which only runs under
# --check-journal-divergence. /idc:janitor --apply-safe is the path doctor tells operators to run —
# if that invocation omits the flag, the repair is unreachable in production and this whole lane
# would be proving something no operator can trigger.
grep -q -- '--check-journal-divergence' "$GOV_PLUGIN/commands/janitor.md" \
  || fail "#213: commands/janitor.md does not pass --check-journal-divergence, so the shipped
\`/idc:janitor --apply-safe\` never produces the Stage finding and the repair is unreachable — doctor's
advice to run it would be a dead end"

echo "PASS: a terminal item's missing Stage is repaired by the reconciler from journal truth — journaled as janitor-repair, never an engine op, converging on re-scan, leaving Status untouched, and refusing to pick a winner when both sides assert a Stage, refusing non-terminal items, re-proving the precondition before writing, and reachable from the shipped janitor path"
