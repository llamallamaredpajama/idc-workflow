#!/bin/bash
# idc-assert-class: doc
# Honest pathway contract smoke — shipped docs/template must define the pathway boundary honestly,
# stop claiming "exactly five guardrails", and document the off|controlled|app-locked profiles
# without pretending filesystem mode provides hard pathway security.
#
# Usage: bash tests/smoke/governance/pathway-contract-profiles.sh   (exit 0 = pass)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
need_file() { [ -f "$ROOT/$1" ] || fail "missing file: $1"; }
need_literal() {
  local file="$1" text="$2" why="$3"
  grep -Fq "$text" "$ROOT/$file" || fail "$file — $why"
}
reject_literal() {
  local file="$1" text="$2" why="$3"
  grep -Fq "$text" "$ROOT/$file" && fail "$file — $why"
}

FILES=(
  README.md
  docs/prd/prd.md
  docs/specs/master-architectural-spec.md
  docs/architecture.md
  templates/WORKFLOW.md
  templates/WORKFLOW-config.yaml
)
for f in "${FILES[@]}"; do
  need_file "$f"
done

# The old contract was explicit about "five guardrails" and implied an advisory posture.
reject_literal README.md 'guardrails-5' 'still advertises a five-guardrail contract in the README badge'
reject_literal README.md '## The five guardrails' 'still has the old five-guardrail section heading'
reject_literal README.md 'There are exactly **five**:' 'still claims exactly five guardrails'
reject_literal docs/specs/master-architectural-spec.md 'Five guardrails, nothing else:' 'still claims exactly five guardrails in the master spec'
reject_literal docs/architecture.md 'five guardrails' 'still frames the architecture as exactly five guardrails'
reject_literal templates/WORKFLOW.md 'There are exactly five' 'still claims exactly five guardrails in WORKFLOW.md'

# Core replacement wording: pathway enforcement governs the route, not the coding method.
CORE_SENTENCE='**Pathway guardrails, not coding prescriptions.** IDC does not dictate how an agent designs, plans, or writes code. It does require governed work to enter through Think, Intake, Recirculation, Plan, Build, or an operational recovery route; it keeps the tracker synchronized as part of every transition and refuses unproven completion.'
need_literal README.md "$CORE_SENTENCE" 'must state the honest pathway boundary in README.md'
need_literal docs/prd/prd.md "$CORE_SENTENCE" 'must state the honest pathway boundary in the PRD'
need_literal docs/specs/master-architectural-spec.md "$CORE_SENTENCE" 'must state the honest pathway boundary in the master spec'
need_literal docs/architecture.md "$CORE_SENTENCE" 'must state the honest pathway boundary in the architecture guide'
need_literal templates/WORKFLOW.md "$CORE_SENTENCE" 'must state the honest pathway boundary in WORKFLOW.md'

PROFILE_SENTENCE='IDC names three `pathway_enforcement.mode` profiles: `off | controlled | app-locked`.'
need_literal README.md "$PROFILE_SENTENCE" 'must define the three enforcement profiles in README.md'
need_literal docs/prd/prd.md "$PROFILE_SENTENCE" 'must define the three enforcement profiles in the PRD'
need_literal docs/specs/master-architectural-spec.md "$PROFILE_SENTENCE" 'must define the three enforcement profiles in the master spec'
need_literal docs/architecture.md "$PROFILE_SENTENCE" 'must define the three enforcement profiles in the architecture guide'
need_literal templates/WORKFLOW.md "$PROFILE_SENTENCE" 'must define the three enforcement profiles in WORKFLOW.md'
need_literal templates/WORKFLOW-config.yaml "$PROFILE_SENTENCE" 'must define the three enforcement profiles in WORKFLOW-config.yaml comments'

CONTROLLED_SENTENCE='`controlled` blocks supported-runtime off-path mutations and blocks merge when pathway evidence is missing or inconsistent, but it cannot stop a machine administrator from removing hooks, editing `.git`, or disabling GitHub rules.'
APP_LOCKED_SENTENCE='`app-locked` adds a GitHub App as the sole tracker writer and trusted check source; it closes the ordinary-token tracker-write gap but still does not protect against repository or organization administrators removing the rules or the App.'
FILESYSTEM_SENTENCE='The filesystem tracker remains useful for hermetic tests and local demonstrations. It must stay `off` and makes no hard pathway-security claim.'
need_literal README.md "$CONTROLLED_SENTENCE" 'must describe the controlled-mode threat boundary honestly in README.md'
need_literal README.md "$APP_LOCKED_SENTENCE" 'must describe the app-locked boundary honestly in README.md'
need_literal README.md "$FILESYSTEM_SENTENCE" 'must preserve honest filesystem semantics in README.md'
need_literal docs/specs/master-architectural-spec.md "$CONTROLLED_SENTENCE" 'must describe the controlled-mode threat boundary honestly in the master spec'
need_literal docs/specs/master-architectural-spec.md "$APP_LOCKED_SENTENCE" 'must describe the app-locked boundary honestly in the master spec'
need_literal docs/specs/master-architectural-spec.md "$FILESYSTEM_SENTENCE" 'must preserve honest filesystem semantics in the master spec'
need_literal docs/architecture.md "$CONTROLLED_SENTENCE" 'must describe the controlled-mode threat boundary honestly in the architecture guide'
need_literal docs/architecture.md "$APP_LOCKED_SENTENCE" 'must describe the app-locked boundary honestly in the architecture guide'
need_literal docs/architecture.md "$FILESYSTEM_SENTENCE" 'must preserve honest filesystem semantics in the architecture guide'
need_literal templates/WORKFLOW.md "$CONTROLLED_SENTENCE" 'must describe the controlled-mode threat boundary honestly in WORKFLOW.md'
need_literal templates/WORKFLOW.md "$APP_LOCKED_SENTENCE" 'must describe the app-locked boundary honestly in WORKFLOW.md'
need_literal templates/WORKFLOW.md "$FILESYSTEM_SENTENCE" 'must preserve honest filesystem semantics in WORKFLOW.md'
need_literal templates/WORKFLOW-config.yaml "$CONTROLLED_SENTENCE" 'must describe the controlled-mode threat boundary honestly in WORKFLOW-config.yaml comments'
need_literal templates/WORKFLOW-config.yaml "$APP_LOCKED_SENTENCE" 'must describe the app-locked boundary honestly in WORKFLOW-config.yaml comments'
need_literal templates/WORKFLOW-config.yaml "$FILESYSTEM_SENTENCE" 'must preserve honest filesystem semantics in WORKFLOW-config.yaml comments'

# ── NEW-2: the controlled-mode limitation list must state STATUS, never point at a unit of work ────
# The shipped template told every governed repo that six controlled-mode limitations were "tracked to
# U8/U9". U8 and U9 MERGED on 2026-07-23 (PRs #176/#177) without closing any of the six. From that day
# the sentence read to an operator as "handled" while all six were still open, and nothing anywhere
# noticed — a unit pointer in shipped prose goes stale silently the moment the unit merges. These
# assertions make the honest form load-bearing.
#
# CONTROL FIRST: the file must actually contain the limitations section, or every "does not say X"
# assertion below would pass on an empty/renamed section for the wrong reason.
LIMITS_HEADER='`controlled` currently has these documented limitations. Every one of them is **still open**'
need_literal templates/WORKFLOW.md "$LIMITS_HEADER" \
  'lost the controlled-mode limitations section (or its honest still-open framing) — without it the staleness assertions below are vacuous'

# No shipped operator-facing surface may defer a live limitation to a NAMED unit of work. A unit
# either ships and closes the limitation (then the line is deleted) or it does not (then the line must
# say the limitation is open) — a pointer is the one form that can silently become false.
for f in templates/WORKFLOW.md templates/WORKFLOW-config.yaml README.md; do
  reject_literal "$f" 'U8/U9' \
    'still defers a controlled-mode limitation to units U8/U9, which merged on 2026-07-23 without closing any of them — state the ACTUAL status instead of pointing at a unit'
  reject_literal "$f" 'tracked to U' \
    'still defers a live limitation to a named unit of work — that pointer reads as "handled" the moment the unit merges, whether or not the limitation closed'
done

# Each of the six limitations must be present AND marked open. A silently deleted line would otherwise
# read as "closed" to an operator with no evidence that anything changed.
for phrase in \
  'Authorization is minted per COMMAND, not per transition' \
  'One authorization per worktree — the newest mint wins' \
  'Pi and Codex are not first-class lifecycle producers' \
  'No sanctioned merge helper on the experimental Pi runtime' \
  'Identity binding is optional, not mandatory' \
  'No TTL renewal'; do
  need_literal templates/WORKFLOW.md "$phrase" \
    "dropped the controlled-mode limitation '$phrase' — deleting a line an operator relied on reads as 'closed'; if it really closed, its claim must be removed together with the code that made it true"
done

# ── The two limitations that were OVERSTATED, not understated ─────────────────────────────────────
# Both of these lines used to tell every governed repo something FALSE about its own guarantees, in
# the safe-sounding direction (claiming LESS protection than exists), which is why nothing caught them:
#
#   * "One authorization per repository … Parallel workers in separate worktrees share a single grant."
#     The authorization lives at `git rev-parse --git-path idc-path-gate/authorization.json`, which
#     resolves into each LINKED WORKTREE'S OWN git directory, and `assert_allowed` refuses a mutation
#     whose live branch differs from the grant's. Worktrees do not share a grant and the grant IS
#     branch-bound. An operator reading the old line would have serialized parallel work for nothing.
#   * "There is no sanctioned finisher/merge helper. The operator performs every merge." True on the
#     experimental Pi runtime ONLY. Claude and Codex self-merge through `idc_pr_finish.py autonomous`
#     and `idc_git_finish.py` — and this same file says so in §4.3a, so the file contradicted itself.
#
# These reject the corrected claims from regressing back to the false ones.
reject_literal templates/WORKFLOW.md 'separate worktrees share a single grant' \
  'still tells governed repos that parallel worktrees share one Path Gate grant — they do not: the authorization resolves into each linked worktree'"'"'s own git dir and every grant is branch-bound'
reject_literal templates/WORKFLOW.md 'There is no sanctioned finisher/merge helper' \
  'still universalises a Pi-ONLY limitation — Claude and Codex self-merge through idc_pr_finish.py autonomous / idc_git_finish.py, which this same file describes in §4.3a'
need_literal templates/WORKFLOW.md 'resolves to each linked worktree'"'"'s OWN git directory' \
  'must state where the authorization actually lives, or the corrected worktree claim is just a different assertion with no reason attached'
need_literal templates/WORKFLOW.md 'Claude and Codex DO self-merge through the sanctioned finishers' \
  'must name the runtimes that DO have a sanctioned merge helper, so the Pi carve-out cannot be read as a system-wide gap again'
# The one limitation with no per-tool coverage at all must say so in those words.
need_literal templates/WORKFLOW.md '**Codex has no per-tool gate at all**' \
  'must state plainly that Codex has no per-tool gate — scripts/install-codex.sh wires no hooks, so Codex is covered only by the git backstop'
OPEN_COUNT="$(grep -c '\*\*Open\.\*\*' "$ROOT/templates/WORKFLOW.md")"
[ "$OPEN_COUNT" -eq 6 ] || fail "templates/WORKFLOW.md — expected exactly 6 controlled-mode limitations marked **Open.**, found $OPEN_COUNT; a limitation that closed must have its whole line removed, and a new one must be marked open"

# ── NEW-15: the spec's T3 traceability table must point at scenarios that EXIST ────────────────────
# T3's "Blocking surfaces" column used to name surface CATEGORIES, so a reader tracing the threat
# reached neither the code that answers it nor a test that proves it. It now names concrete scenario
# files — which is only an improvement while those names stay true. A renamed or deleted scenario must
# turn this red instead of quietly leaving the spec pointing at nothing.
SPEC=docs/specs/idc-convergent-pathway-integrity-spec.md
need_file "$SPEC"
need_literal "$SPEC" '**T3 traceability.**' 'lost the T3 traceability table — T3 is unreachable from the threat matrix again'
T3_SCENARIOS="$(sed -n '/\*\*T3 traceability\.\*\*/,/^$/p;/\*\*T3 traceability\.\*\*/,/^## /p' "$ROOT/$SPEC" \
  | grep -oE '[a-z0-9-]+\.sh' | sort -u)"
[ -n "$T3_SCENARIOS" ] \
  || fail "$SPEC — the T3 traceability table names no scenario files; either it lost its rows or this extraction is broken (it must never pass by finding nothing)"
T3_COUNT=0
for s in $T3_SCENARIOS; do
  [ -f "$ROOT/tests/smoke/governance/$s" ] \
    || fail "$SPEC — the T3 traceability table cites tests/smoke/governance/$s, which does not exist; a spec pointing at a missing test is the exact rot this table was added to fix"
  T3_COUNT=$((T3_COUNT + 1))
done
[ "$T3_COUNT" -ge 10 ] \
  || fail "$SPEC — the T3 traceability table resolved only $T3_COUNT scenario(s); it named 13 when written, so rows have been dropped"

# The config template must surface the stanza explicitly without enabling it by default yet.
need_literal templates/WORKFLOW-config.yaml 'pathway_enforcement:' 'must mention the pathway_enforcement stanza'
need_literal templates/WORKFLOW-config.yaml 'mode: off' 'must keep the scaffold non-enforcing by default for now'
need_literal templates/WORKFLOW-config.yaml 'attempt_ceiling: 3' 'must document the attempt ceiling in the pathway_enforcement stanza'

printf 'PASS: pathway contract profiles\n'
