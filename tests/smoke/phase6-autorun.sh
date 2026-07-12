#!/bin/bash
# idc-assert-class: mixed
# Phase 6 smoke — Autorun's drain predicate (the one-shot exit condition) and its v3 autonomy
# boundary: with the gate at the END of Think, Autorun only decomposes/builds APPROVED
# considerations and treats an OPEN Think PR exactly like an open requirements gate (report + skip).
#   eligible build work = Status=Todo issues that are NOT operator-action gate issues, NOT an
#   upstream pointer (Stage=Consideration/Planning — a consideration pending admission behind the
#   Think PR), and whose every blocked-by upstream is Done. Autorun keeps draining while eligible
#   work exists and exits when nothing actionable remains (only Done + requirements-gated Blocked +
#   the operator's own gate issue + un-admitted considerations left).
# Failing-test-first: fails until scripts/idc_autorun_drain.py exists.
#
# Usage: bash tests/smoke/phase6-autorun.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
AUTORUN="$PLUGIN/agents/idc-autorun.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
T="$WORK/TRACKER.md"
fail() { echo "FAIL: $1"; exit 1; }
drain() { python3 "$DRAIN" --tracker "$T"; }

[ -f "$DRAIN" ] || fail "autorun drain helper not found at $DRAIN (not implemented yet)"

# empty board -> nothing actionable -> drain complete
python3 "$TRK" --tracker "$T" init || fail "tracker init failed"
drain | grep -q "^drain: complete$" || fail "empty board should drain complete"

# add a buildable Todo issue -> actionable
a=$(python3 "$TRK" --tracker "$T" create --title "Build me" --wave "Wave 1")
drain | grep -q "^drain: continue$" || fail "a Todo issue should make autorun continue"
drain | grep -qE "^eligible:.* $a( |$)" || fail "issue $a should be eligible"

# add the operator gate + a PRD-dependent issue blocked behind it
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] PRD change — x")
b=$(python3 "$TRK" --tracker "$T" create --title "PRD-dependent")
python3 "$TRK" --tracker "$T" block --num "$b" --by "$gate" >/dev/null
# still actionable because of issue a; gate + blocked b are NOT eligible
drain | grep -q "^drain: continue$" || fail "still actionable while issue a is Todo"
drain | grep -qE "(^| )$gate( |$)" && fail "the operator-action gate must not be eligible build work"
drain | grep -qE "(^| )$b( |$)" && fail "a Blocked PRD-dependent issue must not be eligible"

# add a consideration pointer that is Stage=Consideration ∧ Status=Todo — ADMITTED but not yet
# planned (per spec the Think PR is merged; it now awaits a Plan pass). Build must NEVER scoop a
# Consideration pointer regardless — Autorun only claims Stage=Buildable work. This is the guard that
# fails red if the drain predicate stops skipping a Stage=Consideration pointer.
c=$(python3 "$TRK" --tracker "$T" create --title "Admitted-but-unplanned consideration (awaiting Plan)" --stage Consideration)
drain | grep -qE "(^| )$c( |$)" && fail "a Stage=Consideration pointer must not be eligible build work"

# build issue a to Done -> only the gate (operator) + Blocked b + the admitted-but-unplanned
# consideration remain. The build lane IS drained (nothing eligible), but the Stage=Consideration ∧
# Status=Todo pointer is a whole-pipe fixpoint conjunct (unplanned_considerations>0), so the drain is
# NOT a terminal `complete` — it is `drain: recirc-pending` exit 4 (the pointer still owes a planning
# pass). The pointer is STILL never eligible build work (asserted at $c above). Exit 4 is NOT
# `complete`, so autorun does not stop — it plans the consideration next /loop. drainrc() runs the
# drain capturing its exit code (exit 4 would trip a bare `drain |` pipe under set -uo pipefail otherwise).
drainrc() { DOUT="$(python3 "$DRAIN" --tracker "$T" 2>/dev/null)"; DRC=$?; }
python3 "$TRK" --tracker "$T" claim --num "$a" --agent idc-implementer >/dev/null
python3 "$TRK" --tracker "$T" close --num "$a" >/dev/null
drainrc
[ "$DRC" -eq 4 ] || fail "with the build lane drained but an un-admitted Consideration pointer left, autorun must report recirc-pending exit 4 (not terminal), got $DRC"
printf '%s\n' "$DOUT" | grep -qx "drain: recirc-pending" || fail "a leftover Consideration ∧ Todo pointer must drive drain: recirc-pending (unplanned_considerations conjunct)"

# ---- C5 allowlist: a Stage=Recirculation inbox ticket is NOT eligible build work ----------------
# Autorun claims ONLY Stage=Buildable. A Recirculation ticket (scope discovered mid-build, the
# non-Buildable inbox) is drained at the TOP of the pipe via /idc:recirculate — never scooped into a
# Buildable wave. It is ALSO a whole-pipe fixpoint conjunct (recirc_inbox>0): the drain stays
# recirc-pending exit 4, never a terminal `complete`. Red-when-broken: widen the drain allowlist to
# admit Recirculation and this ticket goes eligible (drain would flip to continue).
rec=$(python3 "$TRK" --tracker "$T" create --title "Discovered mid-build (recirculation inbox)" --stage Recirculation)
drainrc
printf '%s\n' "$DOUT" | grep -qE "^eligible:.*(^| )$rec( |$)" && fail "a Stage=Recirculation inbox ticket must not be eligible build work (claims only Buildable; Recirculation is build-excluded)"
[ "$DRC" -eq 4 ] || fail "a non-eligible Stage=Recirculation ticket must keep the drain at recirc-pending exit 4 (drained at the top of the pipe, not built), got $DRC"
printf '%s\n' "$DOUT" | grep -qx "drain: recirc-pending" || fail "a Stage=Recirculation ∧ Todo inbox ticket must drive drain: recirc-pending (recirc_inbox conjunct)"

# ---- a state block MISSING the `issues` key entirely -> exit 2 (not a silent empty board) ------
# A dropped `issues` key used to default to an empty board (state.get("issues", [])) -> a silent
# `drain: complete`. A missing key is corruption, not an empty board: fail closed (exit 2).
RAW="$WORK/no-issues-key.md"
{ echo "<!-- idc-tracker-state:begin -->"; echo '```json'; echo '{"next_number":1}'; echo '```'
  echo "<!-- idc-tracker-state:end -->"; } > "$RAW"
python3 "$DRAIN" --tracker "$RAW" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a state block missing the \`issues\` key must exit 2 (fail-closed), not drain: complete (got $rc)"

# ---- a malformed `blocked_by` (not a list) -> exit 2 (fail-closed, never iterated/misread) ------
# The eligibility loop iterates `it.get("blocked_by", [])`; a non-list value (a github bug or a
# hand-edit dropping the brackets) would crash with a TypeError (exit 1, traceback) or be iterated
# character-by-character and silently misread. The eager shape guard catches it BEFORE the loop and
# exits 2 with a clean corrupt-tracker diagnostic — the same fail-closed contract as the `number`
# and `issues`-key guards. Red-when-broken: drop the guard and this issue exits 1 (crash), not 2.
RAWBB="$WORK/bad-blocked-by.md"
{ echo "<!-- idc-tracker-state:begin -->"; echo '```json'
  echo '{"issues":[{"number":1,"status":"Todo","blocked_by":5}]}'; echo '```'
  echo "<!-- idc-tracker-state:end -->"; } > "$RAWBB"
python3 "$DRAIN" --tracker "$RAWBB" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a malformed \`blocked_by\` (non-list) must exit 2 (fail-closed), not crash/misread (got $rc)"

# ---- a non-dict `issues[]` entry (e.g. issues:[5]) -> exit 2 (fail-closed, never a bare crash) ---
# Every membership test / `.get()` / sort key / `.startswith()` below assumes each entry is a dict;
# a scalar entry (corrupt tracker) would crash with a TypeError (exit 1, traceback). The eager shape
# guard rejects a non-dict entry up front. Red-when-broken: drop the guard and this exits 1, not 2.
RAWND="$WORK/non-dict-issue.md"
{ echo "<!-- idc-tracker-state:begin -->"; echo '```json'; echo '{"issues":[5]}'; echo '```'
  echo "<!-- idc-tracker-state:end -->"; } > "$RAWND"
python3 "$DRAIN" --tracker "$RAWND" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a non-dict \`issues[]\` entry must exit 2 (fail-closed), not crash (got $rc)"

# ---- a non-int `number` (unhashable/wrong type) -> exit 2 (fail-closed, never a bare crash) ------
# `number` is used as a dict key (status_by_num) and a sort key; an unhashable value (list/dict) or
# a type that won't sort against the other ints crashes with a TypeError instead of the documented
# exit 2. The eager guard requires an int. Red-when-broken: drop the guard and this exits 1, not 2.
RAWNI="$WORK/non-int-number.md"
{ echo "<!-- idc-tracker-state:begin -->"; echo '```json'; echo '{"issues":[{"number":[1],"status":"Todo"}]}'; echo '```'
  echo "<!-- idc-tracker-state:end -->"; } > "$RAWNI"
python3 "$DRAIN" --tracker "$RAWNI" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a non-int \`number\` must exit 2 (fail-closed), not crash (got $rc)"

# ---- an explicitly-present empty board (`issues: []`) stays a legitimate empty board -> complete -
RAWEMPTY="$WORK/empty-board.md"
{ echo "<!-- idc-tracker-state:begin -->"; echo '```json'; echo '{"issues":[]}'; echo '```'
  echo "<!-- idc-tracker-state:end -->"; } > "$RAWEMPTY"
python3 "$DRAIN" --tracker "$RAWEMPTY" 2>/dev/null | grep -q "^drain: complete$" \
  || fail "an explicitly-present empty board (issues: []) must stay drain: complete exit 0"

# ---- prose invariant: the planning lane only plans APPROVED considerations (v3) ---------------
[ -f "$AUTORUN" ] || fail "agents/idc-autorun.md missing"
grep -qiE 'Think PR' "$AUTORUN" \
  || fail "idc-autorun.md must treat an open Think PR like an open gate (report + skip) — the planning lane only plans approved considerations"
grep -qiE 'approved consideration' "$AUTORUN" \
  || fail "idc-autorun.md must state Autorun only decomposes/builds approved considerations"

# ---- P0-1: no-ask invariant — the sanctioned stops are exhaustive (autorun audit Defect 1) ------
# Autorun's first live run improvised four AskUserQuestion gates its playbook never sanctioned. The
# fix is an explicit enumerated invariant in BOTH the autorun and build agent playbooks: never ask
# how-autonomous, never re-confirm chosen scope, never turn a deterministic drain:continue into a
# question, never call AskUserQuestion. Removing the clause from EITHER agent file fails this red.
BUILD="$PLUGIN/agents/idc-build.md"
[ -f "$BUILD" ] || fail "agents/idc-build.md missing"
for f in "$AUTORUN" "$BUILD"; do
  bn="$(basename "$f")"
  grep -qiE 'no-ask invariant' "$f" \
    || fail "$bn must carry the enumerated no-ask invariant (P0-1)"
  grep -qiE 'never[[:space:]]+calls?[[:space:]]+.?AskUserQuestion' "$f" \
    || fail "$bn no-ask invariant must forbid calling AskUserQuestion (P0-1)"
  grep -qiE 'how autonomous' "$f" \
    || fail "$bn no-ask invariant must forbid asking how-autonomous-to-be (P0-1)"
  # the no-ask invariant must name the operator-decision strategic gate as a SANCTIONED board-state
  # gate — else a model treats it as unsanctioned and may ignore it or improvise a prompt (Codex review)
  grep -qiE 'operator-decision' "$f" \
    || fail "$bn no-ask invariant must name the operator-decision strategic gate as sanctioned (else it reads as unsanctioned)"
done

# ---- L2-1: the exit report's working-tree claim is sourced from a FINAL post-build git status ---
# The L2 e2e exit report under-counted untracked artifacts (claimed 2, actual 10) because the
# working-tree view was a session-START snapshot taken before the build lane wrote files. The exit
# report must reconcile the tree at EXIT (post-build), not from a stale snapshot.
grep -qiE 'post-build .*git status' "$AUTORUN" \
  || fail "idc-autorun.md exit report must source its working-tree state from a post-build git status, not a start-of-run snapshot (L2-1)"
grep -qiE 'start-of-run snapshot' "$AUTORUN" \
  || fail "idc-autorun.md must warn against a start-of-run working-tree snapshot in the exit report (L2-1)"
# M1 (L2 review): commands/autorun.md carries the SAME post-build reconciliation prose — lock it too
# so the command entry can't silently diverge from the (authoritative) agent file it delegates to.
CMD="$PLUGIN/commands/autorun.md"
[ -f "$CMD" ] || fail "commands/autorun.md missing"
grep -qiE 'post-build .*git status' "$CMD" \
  || fail "commands/autorun.md exit report must source its working-tree state from a post-build git status (L2-1 parity)"
grep -qiE 'start-of-run snapshot' "$CMD" \
  || fail "commands/autorun.md must warn against a start-of-run working-tree snapshot in the exit report (L2-1 parity)"

# ---- PR#72 follow-up: the human-gate skill is portable to the filesystem backend ---------------
# A filesystem TRACKER.md repo has no PRs and no labels, so the github gate-approval signals can't
# exist there; the skill must document the portable signal (flip the gate issue's Status to Done).
# Each assertion's `fail` message carries the full rationale.
GATE="$PLUGIN/skills/idc-gate-issue/SKILL.md"
[ -f "$GATE" ] || fail "skills/idc-gate-issue/SKILL.md missing"
grep -qiE 'Approval signal by backend' "$GATE" \
  || fail "idc-gate-issue must document the per-backend approval signal (Approval signal by backend) — else a filesystem gate is silently un-approvable (PR#72 follow-up)"
grep -qiE 'no PRs and no labels' "$GATE" \
  || fail "idc-gate-issue must state the filesystem backend has no PRs and no labels (why the github merge/label signal can't apply) (PR#72 follow-up)"
# The filesystem gate-approval Done-move now routes through the engine's guarded terminal door
# (dispose --disposition gate-approved), not a raw idc_tracker_fs close — the #150 door unification.
grep -qiE 'dispose --disposition gate-approved --num <gate' "$GATE" \
  || fail "idc-gate-issue must define the filesystem approval action: flip the gate issue's Status to Done via the engine's guarded dispose --disposition gate-approved --num <gate#> (#150 door unification; PR#72 follow-up)"
# WORKFLOW.md template carries the same backend-portable-approval note so the doctrine can't drift
WF="$PLUGIN/templates/WORKFLOW.md"
[ -f "$WF" ] || fail "templates/WORKFLOW.md missing"
grep -qiE 'Backend-portable approval' "$WF" \
  || fail "WORKFLOW.md §2 must note backend-portable gate approval (filesystem: gate issue Status -> Done) (PR#72 follow-up)"

# ============================================================================================
# Lane 5 — Autorun top-of-pipeline ordering + human-gate preservation (Recirculation intake)
# ============================================================================================
# Autorun now STARTS at the top of the pipe: drain the Recirculation inbox via /idc:recirculate,
# THEN plan approved considerations, THEN drain Buildable waves. It is full-pipeline autonomy that
# pauses ONLY at human gates — a gate-worthy recirculation ticket pauses behind its gate (reported +
# skipped, reusing the existing [operator-action] skip/surface behavior), never forced. Both the
# command entry and the agent playbook must carry this consistently. Every assertion below is
# red-when-broken: break the ordering/guard text and the matching check fails.

# line number of the first case-insensitive match of $2 in file $1 ("" if none; -m1 avoids SIGPIPE)
lineof() { grep -n -m1 -iE "$2" "$1" 2>/dev/null | cut -d: -f1; }
# assert the Recirculation-intake anchor ($2) precedes the plan anchor ($3) precedes the build
# anchor ($4) by physical line position in file $1 (top-of-pipeline order)
ord() {
  local f="$1" r p d
  r=$(lineof "$f" "$2"); p=$(lineof "$f" "$3"); d=$(lineof "$f" "$4")
  [ -n "$r" ] && [ -n "$p" ] && [ -n "$d" ] && [ "$r" -lt "$p" ] && [ "$p" -lt "$d" ]
}

for f in "$AUTORUN" "$CMD"; do
  bn="$(basename "$f")"
  # (1) the fixed top-of-pipeline order is documented on one line: recirculate -> plan -> drain
  grep -qiE 'recirculate.*plan.*drain' "$f" \
    || fail "$bn must document the fixed top-of-pipeline order (recirculate -> plan -> drain) on one line (Lane 5 ordering)"
  # (2) full-pipeline autonomy that pauses ONLY at human gates
  grep -qiE 'only at human gates' "$f" \
    || fail "$bn must state autorun is full-pipeline autonomy that pauses only at human gates (Lane 5)"
  # (3) autorun NEVER forces a gate
  grep -qiE 'never forc' "$f" \
    || fail "$bn must state autorun never forces a gate (Lane 5)"
  # (4) a gate-worthy item pauses behind its gate, reusing the existing [operator-action] skip/surface
  grep -qiE 'pauses behind its gate' "$f" \
    || fail "$bn must state a gate-worthy item pauses behind its gate (reported + skipped), not forced (Lane 5)"
  grep -qiE 'operator-action' "$f" \
    || fail "$bn must reuse the existing [operator-action] gate skip/surface behavior — autorun doesn't force gates (Lane 5)"
  # (5) the Recirculation intake runs /idc:recirculate in its board-scan inbox-drain mode
  grep -qiE '/idc:recirculate' "$f" \
    || fail "$bn Recirculation intake must run /idc:recirculate (Lane 5)"
  grep -qiE 'inbox-drain' "$f" \
    || fail "$bn Recirculation intake must invoke the board-scan inbox-drain mode (Lane 5)"
  # (5b) rogue-sweep backstop: autorun must re-stage rogues ITSELF via idc_recirc_sweep.py
  #      --auto-correct before draining — the SessionEnd hook is cancelled in headless -p / /loop, so
  #      autorun cannot rely on it (e2e-caught). Red-when-broken: drop the sweep call from the intake.
  grep -qE 'idc_recirc_sweep\.py' "$f" \
    || fail "$bn Recirculation intake must run the idc_recirc_sweep.py rogue-sweep backstop — SessionEnd is unreliable headless (Lane 5/e2e)"
  grep -qE -- '--auto-correct' "$f" \
    || fail "$bn rogue-sweep backstop must run --auto-correct (re-stage rogues), not report-only (Lane 5/e2e)"
  # (6) drain allowlist alignment: Consideration/Planning/Recirculation are build-excluded (claims only Buildable)
  grep -qiE 'Consideration.*Planning.*Recirculation' "$f" \
    || fail "$bn build-exclusion must name Consideration/Planning/Recirculation as build-excluded — claims only Buildable (Lane 5 / C5)"
done

# (7) structural ordering — the Recirculation-intake step physically precedes the plan step which
# precedes the build/drain step in each file (red-when-broken: move the intake below the build step).
# Agent anchors are scoped to the DRAIN-LOOP step prose (the `inbox first` phrase appears only in the
# step-1 body, not the section heading/lead) so the guard tests true execution order, not doc layout.
ord "$AUTORUN" 'inbox first' 'Find approved' 'Build eligible waves' \
  || fail "agents/idc-autorun.md drain loop must order Recirculation-intake -> plan -> build (top-of-pipeline) (Lane 5)"
ord "$CMD" 'Recirculation intake' 'Planning lane' 'Build lane' \
  || fail "commands/autorun.md must order Recirculation-intake -> Planning lane -> Build lane (top-of-pipeline) (Lane 5)"

echo "PASS: autorun drain predicate green; exit report reconciles the working tree post-build (L2-1); human gate is filesystem-backend portable (PR#72 follow-up); top-of-pipeline order recirculate->plan->drain + human-gate skip/surface preserved (Lane 5)"
