#!/bin/bash
# idc-assert-class: doc
# Phase 7 (command prose invariants) smoke — testing-suite-overhaul.
#
# A cheap backstop for the prose that REMAINS in the file-changing command markdown after decisions
# were pushed into helpers. These grep-style invariants lock the must-hold instructions an executing
# agent reads, so a future edit can't silently reintroduce a destructive default (e.g. the 2.1.3
# keep/replace-for-data-configs footgun). No LLM, no cost; runs every PR. Hermetic.
#
# Usage: bash tests/smoke/phase7-command-prose-invariants.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
C="$PLUGIN/commands"
fail() { echo "FAIL: $1"; exit 1; }
has()  { grep -qiE "$2" "$1"; }   # file, regex

# --- update.md: data configs are preserved, never destructively replaced ------------------------
U="$C/update.md"
[ -f "$U" ] || fail "commands/update.md missing"
has "$U" 'never overwrite[s]? a data-bearing config' \
  || fail "update.md must state it never overwrites a data-bearing config"
has "$U" 'never.*offer.*destructive keep/replace|never offers a destructive keep/replace' \
  || fail "update.md must state it never offers a destructive keep/replace for data configs"
has "$U" 'idc_config_keys\.py' \
  || fail "update.md must resolve data-config structure via the idc_config_keys.py helper (not prose judgment)"
has "$U" 'idc_template_for\.py' \
  || fail "update.md must resolve templates via the shared idc_template_for.py resolver"
has "$U" 'idc_plugin_freshness\.py' \
  || fail "update.md must run the stale-session freshness guard"
# Board reconcile must know the 3.1.0 4th Stage option and, on a pre-3.1.0 board, APPLY the
# non-destructive append itself (update is the natural post-upgrade command) — not just report it.
has "$U" 'Consideration\|Planning\|Buildable\|Recirculation' \
  || fail "update.md board contract must list the Stage field's FOUR options incl. Recirculation"
has "$U" 'idc_stage_options\.py' \
  || fail "update.md must APPLY the non-destructive Recirculation append via the idc_stage_options.py helper (not just report it)"
has "$U" 'ensure-option Recirculation' \
  || fail "update.md must append the Recirculation option to a pre-3.1.0 board"
has "$U" 'stage-recirc-appended' \
  || fail "update.md must report stage-recirc-appended when it adds the option"
# But update must STILL forbid destructive board mutations (the safety line the append must not erode).
has "$U" 'never (performs?|does)( a)? destructive' \
  || fail "update.md must still forbid destructive/structural board mutations (only the additive append is allowed)"
# It must NOT tell the agent to do anything destructive to a data-bearing config. The 2.1.3 footgun
# was a keep/replace OFFER over operator data; a future edit could reintroduce it with any wording.
# A plain ordered grep ('overwrite .* WORKFLOW-config') is brittle — it misses the generic "data
# config" phrasing and the reversed word order. Scan line-by-line instead: flag any line that pairs a
# data-config REFERENT with a DESTRUCTIVE action, *unless* the destructive verb is directly negated
# (the legitimate prose is "**never** overwrite …" / "never offer a destructive keep/replace" — the
# negation sits immediately on the verb, only an adverb like "silently" may intervene). Order-
# independent; an incidental "not"/"no" elsewhere in the sentence does NOT excuse a destructive verb.
# Exit 2 = a destructive instruction was found.
python3 - "$U" <<'PY' || fail "update.md appears to instruct a destructive action on a data config (keep/replace offer, overwrite, clobber, or 'write … over it') — the 2.1.3 footgun"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
referent = re.compile(r"data[- ]?(bearing )?config|workflow-config|tracker-config|always_ask", re.I)
# Destructive actions over operator data: overwrite/clobber/replace-the-file, a keep/replace OFFER,
# a whole-file replace, or the "write … over it/the file" idiom (what 2.1.3 actually did).
destructive = re.compile(
    r"\b(overwrit\w*|clobber\w*|whole-file replace|keep[\s-]?(or|/|-|and)[\s-]?replace|"
    r"keep[- ]?vs[.-]? ?replace|replace[- ]?(or|/|-|and)[\s-]?keep|"
    r"offer\w*[^.\n]{0,30}?\b(keep|replace)|replac\w*|write[^.\n]*\bover\b)", re.I)
# Legitimate prose negates the destructive VERB directly: "never[/Never/don't/no/not] [adverb] <verb>"
# (only a single adverb like "silently" may sit between). An incidental negation elsewhere in the
# sentence is NOT a licence — the negation must immediately govern the destructive token.
neg_governs = re.compile(r"\b(never|n't|do not|not|no)\b(\s+\w+ly)?\s+(?=[^.\n]{0,4}?"
                         r"(overwrit|clobber|whole-file replace|offer|replace|write\b))", re.I)
offenders = []
for ln in text.splitlines():
    if not (referent.search(ln) and destructive.search(ln)):
        continue
    if neg_governs.search(ln):
        continue
    offenders.append(ln)
sys.exit(2 if offenders else 0)
PY

# --- init.md: the two data configs are stamped --customized (so update/uninstall protect them) ---
I="$C/init.md"
[ -f "$I" ] || fail "commands/init.md missing"
has "$I" 'customized .*WORKFLOW-config\.yaml|--customized WORKFLOW-config\.yaml' \
  || fail "init.md must stamp WORKFLOW-config.yaml --customized"
has "$I" 'customized .*tracker-config\.yaml|--customized docs/workflow/tracker-config\.yaml' \
  || fail "init.md must stamp docs/workflow/tracker-config.yaml --customized"
# Board provisioning must carry the 3.1.0 4th Stage option on a fresh create AND reconcile an
# existing pre-3.1.0 board by appending it non-destructively (the regression: init seeded only 3
# options and skipped an existing field, so /idc:recirculate had no stage to file into).
has "$I" 'ensure-field.*--repo|ensure-field' \
  || fail "init.md must create missing board fields through the validating adapter"
has "$I" 'name Stage --option Consideration --option Planning --option Buildable --option Recirculation' \
  || fail "init.md must create the Stage field with all FOUR options incl. Recirculation"
has "$I" 'idc_stage_options\.py' \
  || fail "init.md must reconcile an existing Stage field via the idc_stage_options.py append helper"
has "$I" 'ensure-option Recirculation' \
  || fail "init.md must append the Recirculation option to a pre-3.1.0 board (the on-existing migration)"

# --- uninstall.md: deletion is receipt-driven (only delete what IDC created) --------------------
UN="$C/uninstall.md"
[ -f "$UN" ] || fail "commands/uninstall.md missing"
has "$UN" 'receipt' || fail "uninstall.md must drive removal from the install receipt"
has "$UN" 'only delete what IDC' \
  || fail "uninstall.md must state it only deletes what IDC created"
# F1 + pagination (overnight-e2e-hardening + the 30-item-truncation fix): the in-flight board count
# must read the WHOLE board via the shared paginating reader (idc_gh_board.py), NEVER a truncating
# `gh project item-list` (it returns only its 30-item first page; `--limit` just moves the ceiling),
# which would under-count in-flight work and orphan board items past the cut on uninstall. The reader
# emits ASCII-escaped JSON, so piping ITS output to an external jq stays control-char-safe — a raw
# control char (U+0000–U+001F) in any issue body would otherwise crash a strict external jq → a
# wrong/empty count (the F1 class). No `--limit N` ceiling left in any github board read.
has "$UN" 'idc_gh_board\.py' \
  || fail "uninstall.md in-flight count must read the whole board via the paginating idc_gh_board.py (not a truncating gh item-list)"
grep -E 'gh project item-list.*--format json' "$UN" \
  && fail "uninstall.md must not read the board with a truncating gh project item-list --format json (use the paginating idc_gh_board.py)"
# Round-2 finding F4-r2 + deferred #17: uninstall must DO the destructive work, THEN finish (which
# independently verifies that work against the still-readable receipt), THEN remove the canonical
# receipt and governance anchor together. The finish must NOT record 'applied' before the work
# happened, and neither verification file may disappear before finish. Assert the ordering:
# footprint-removal git-rm < finish < receipt+anchor cleanup git-rm, and no
# expected/harmless-failure framing survives. Red-when-broken: finish before footprint removal,
# either verification file removed before finish, or a no-op finish excused as expected/harmless.
python3 - "$UN" <<'PY' || fail "uninstall.md must remove the footprints, THEN finish against the retained canonical receipt + governance anchor, THEN remove those two files together; and must not call a failing/late finish 'expected'/'harmless'"
import re, sys
physical = open(sys.argv[1], encoding="utf-8").read().splitlines()
# Treat a backslash-continued shell command as one line so the cleanup command's two paths are
# checked together even when the Markdown formats them across lines.
lines = []
i = 0
while i < len(physical):
    command = physical[i]
    while command.rstrip().endswith("\\") and i + 1 < len(physical):
        command = command.rstrip()[:-1] + " " + physical[i + 1].strip()
        i += 1
    lines.append(command)
    i += 1
def first_idx(pred):
    for i, ln in enumerate(lines):
        if pred(ln):
            return i
    return None
def is_git_rm(l):
    return re.search(r'git .*\brm\b', l) is not None
finish_i = first_idx(lambda l: "idc_command_contract.py" in l and "finish" in l)
# The footprint-removal step names manifest/footprint paths but retains BOTH verification files.
work_rm_i = first_idx(lambda l: is_git_rm(l) and ("receipt entries" in l.lower()
                                                  or "manifest" in l.lower()
                                                  or "footprint" in l.lower())
                                and "tracker-config" not in l.lower()
                                and "install-receipt" not in l.lower())
# The one post-finish cleanup command must remove the canonical receipt + anchor together.
cleanup_i = first_idx(lambda l: is_git_rm(l) and "tracker-config" in l.lower()
                                and "install-receipt" in l.lower())
if None in (finish_i, work_rm_i, cleanup_i):
    sys.exit(1)                 # all three ordered steps must be present
if not (work_rm_i < finish_i < cleanup_i):
    sys.exit(1)                 # remove footprints -> verify/finish -> remove receipt + anchor
text = "\n".join(lines).lower()
if re.search(r'(no-op|no op|exit ?2|fail\w*)[^.\n]{0,80}(expected|harmless)', text) or \
   re.search(r'(expected|harmless)[^.\n]{0,80}(no-op|no op|exit ?2|fail\w*)', text):
    sys.exit(1)                 # a failing/no-op finish must not be excused as expected/harmless
sys.exit(0)
PY

# --- doctor.md: read-only (it must never mutate the repo or board) ------------------------------
D="$C/doctor.md"
[ -f "$D" ] || fail "commands/doctor.md missing"
has "$D" 'read-only' || fail "doctor.md must declare itself read-only"

# --- build.md: dissolved-barrier coherence (#76) -------------------------------------------------
# #76 dissolved the wave barrier: Build dispatches off the whole-board READY FRONTIER (not the active
# wave), and the acceptance gate retriggers continuously (per-area finish + convergence + wave-close),
# not only at wave-close. The operator-facing command summary must agree with agents/idc-build.md —
# a future edit must not silently reintroduce the wave-barrier model. Red-when-broken: the positive
# grep fails if 'ready frontier' is dropped; each negative grep fails if the stale barrier prose returns.
B="$C/build.md"
[ -f "$B" ] || fail "commands/build.md missing"
has "$B" 'ready frontier' \
  || fail "build.md must dispatch off the ready frontier (#76 dissolved the wave barrier)"
# Negative asserts over WHITESPACE-NORMALIZED prose — markdown wraps unpredictably, so a stale phrase
# could re-enter split across two lines and dodge a line-based grep; flatten newlines first so the
# guard stays red-when-broken regardless of wrapping. (BSD/GNU-portable: tr only.)
BFLAT="$(tr '\n' ' ' < "$B" | tr -s ' ')"
printf '%s' "$BFLAT" | grep -qiE 'wave[ -]?close runs the full suite' \
  && fail "build.md must not say 'wave close runs the full suite' — #76 retriggers the acceptance gate continuously (per-area finish + convergence + wave-close), not only at wave-close"
printf '%s' "$BFLAT" | grep -qiE 'promotes the next wave' \
  && fail "build.md must not say it 'promotes the next wave' — Wave no longer gates dispatch (#76); it survives only as the acceptance gate's reporting scope"
printf '%s' "$BFLAT" | grep -qiE 'claim the active wave' \
  && fail "build.md must not 'claim the active wave' — Build dispatches off the whole-board ready frontier (#76), not the active wave"

# --- autorun fs drain carries --acceptance in the REAL playbook (v4 Phase 3 Stage B, MAJOR-2) -----
# /idc:autorun tells the session to read agents/idc-autorun.md and run ITS steps, so the wave-close
# acceptance check (Stage B deliverable #2) is only LIVE if the PLAYBOOK's own filesystem drain call
# carries --acceptance — the command markdown having it is not enough. Lock BOTH the agent playbook and
# the command: the FILESYSTEM idc_autorun_drain.py drain (the --tracker exit-condition call, NOT the
# --width staffing call) must carry --acceptance, and the --backend github drain must NOT (github
# wave-close acceptance runs in idc:idc-build Phase 4). Red-when-broken: drop --acceptance from the
# playbook's fs drain ⇒ the (fs) assert goes RED; add it to the github drain ⇒ the (gh) assert goes RED.
for f in "$PLUGIN/agents/idc-autorun.md" "$PLUGIN/commands/autorun.md"; do
  [ -f "$f" ] || fail "$(basename "$f") missing"
  python3 - "$f" <<'PY' || fail "$(basename "$f"): the filesystem idc_autorun_drain.py exit-condition drain must carry --acceptance and the github drain must not (else the wave-close acceptance check is DEAD in a real autorun run)"
import sys
fs_drain, gh_bad = [], False
for ln in open(sys.argv[1], encoding="utf-8"):
    if "idc_autorun_drain.py" not in ln:
        continue
    if "--backend github" in ln:
        if "--acceptance" in ln:
            gh_bad = True          # github wave-close acceptance belongs in idc:idc-build Phase 4
        continue
    if "--width" in ln:
        continue                    # the staffing-estimate frontier-width call, not the wave-close drain
    if "--tracker" in ln:
        fs_drain.append(ln)
ok = bool(fs_drain) and all("--acceptance" in ln for ln in fs_drain) and not gh_bad
sys.exit(0 if ok else 2)
PY
done

# --- autorun marker-set fails VISIBLY on an empty session id (v4 Phase 3 Stage B, m4) --------------
# If $CLAUDE_CODE_SESSION_ID is empty, storing the orchestrator_drain marker keyed to "" silently
# disables the Stop fixpoint gate (the real payload id never matches ""). The command must GUARD the
# marker-set with an empty-id check that skips + warns loudly (fail-open, but VISIBLE) rather than
# store an unkeyable marker. Red-when-broken: drop the `[ -z "$CLAUDE_CODE_SESSION_ID" ]` guard ⇒ RED.
AR="$C/autorun.md"
[ -f "$AR" ] || fail "commands/autorun.md missing"
has "$AR" '\[ -z "\$CLAUDE_CODE_SESSION_ID" \]' \
  || fail "autorun.md must guard the orchestrator_drain marker-set with an empty-id check ([ -z \"\$CLAUDE_CODE_SESSION_ID\" ]) so an empty session id fails VISIBLY, not by silently disabling the gate"
has "$AR" 'will NOT fire this run|NOT setting the orchestrator_drain marker' \
  || fail "autorun.md must WARN loudly (stderr) when it skips the marker-set on an empty session id — the disabling must be visible"

# --- Task 6: the command-integrity closeout frame -----------------------------------------------
# Every governed /idc:* command body must VERIFY its active command-contract record at entry
# (idc_command_contract.py status — the entry gate opened it at expansion) and CLOSE it
# deterministically at exit (idc_command_contract.py finish), never an improvised walk-away. The six
# pipeline commands must additionally surface the read-only next-action oracle's machine result
# (idc_next_action.py) as the final handoff, not a hand-authored "next, run X". Per-file greps only —
# a bare recursive `grep -r` can hang under this machine's default ugrep, and shipped users get BSD
# grep, so the suite iterates files explicitly (portability: /usr/bin/grep + /usr/bin/awk).
for cmd in autorun build doctor init intake janitor plan recirculate think uninstall update; do
  f="$C/$cmd.md"
  [ -f "$f" ] || fail "missing command: $cmd"
  grep -q 'idc_command_contract.py.*status' "$f" \
    || fail "$cmd does not verify its active command contract (idc_command_contract.py status at entry)"
  grep -q 'idc_command_contract.py.*finish' "$f" \
    || fail "$cmd has no deterministic closeout (idc_command_contract.py finish)"
done
for cmd in autorun build intake plan recirculate think; do
  f="$C/$cmd.md"
  grep -q 'idc_next_action.py' "$f" \
    || fail "$cmd does not derive its pipeline handoff from the oracle (idc_next_action.py)"
done

# Shipped prose must not claim Recirculate SEEDS work with no intake/inbox, nor let Build INFER work
# from a foreign Markdown plan (a foreign plan is evidence, never execution authority). Flag any
# single line that pairs the referent with the forbidden action. Iterate files explicitly (never a
# bare `grep -r`, which hangs under ugrep); `.{0,N}` bounded quantifiers are POSIX-ERE portable.
_seed_offenders=""; _infer_offenders=""
for f in "$C"/*.md "$PLUGIN"/agents/*.md "$PLUGIN"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  if grep -qiE 'recirculate.{0,80}(seed|create).{0,40}(ticket|issue)' "$f" 2>/dev/null; then
    _seed_offenders="$_seed_offenders $f"
  fi
  if grep -qiE 'build.{0,80}(infer|derive|read).{0,60}(foreign|external|markdown plan)' "$f" 2>/dev/null; then
    _infer_offenders="$_infer_offenders $f"
  fi
done
[ -z "$_seed_offenders" ] \
  || fail "shipped prose still claims Recirculate seeds work without an intake/inbox:$_seed_offenders"
[ -z "$_infer_offenders" ] \
  || fail "shipped prose still lets Build infer work from foreign Markdown:$_infer_offenders"

echo "PASS: file-changing command markdown holds its must-never/must-say invariants"
