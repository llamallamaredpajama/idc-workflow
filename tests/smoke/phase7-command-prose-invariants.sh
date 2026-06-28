#!/bin/bash
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
# Board-drift contract must know the 3.1.0 4th Stage option and report a present-but-stale Stage
# field — the regression that shipped a Recirculation feature with no board option to file into.
has "$U" 'Consideration\|Planning\|Buildable\|Recirculation' \
  || fail "update.md board-drift contract must list the Stage field's FOUR options incl. Recirculation"
has "$U" 'stage-recirc-missing' \
  || fail "update.md must report a present-but-incomplete Stage field (stage-recirc-missing) and point at /idc:init"
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
# F1 completeness (overnight-e2e-hardening): the in-flight board count must use gh's BUILT-IN
# --jq — never pipe `gh project item-list … --format json` to an EXTERNAL jq. A raw control char
# (U+0000–U+001F) in any issue body crashes external jq → a wrong/empty count silently mis-reports
# in-flight work and can orphan board items on uninstall (the same class as the F1 skill bug).
has "$UN" 'item-list .*--format json .*--jq' \
  || fail "uninstall.md in-flight count must use gh's built-in --jq (control-char-robust), not an external-jq reparse (F1 completeness)"
grep -E 'gh project item-list[^|]*--format json[^|]*\| *jq' "$UN" \
  && fail "uninstall.md still pipes item-list --format json to an external jq (the F1 control-char fragility)"

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

echo "PASS: file-changing command markdown holds its must-never/must-say invariants"
