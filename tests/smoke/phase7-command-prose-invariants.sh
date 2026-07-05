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
has "$I" 'single-select-options "Consideration,Planning,Buildable,Recirculation"' \
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

echo "PASS: file-changing command markdown holds its must-never/must-say invariants"
