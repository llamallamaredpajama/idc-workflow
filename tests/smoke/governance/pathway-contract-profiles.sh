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

# The config template must surface the stanza explicitly without enabling it by default yet.
need_literal templates/WORKFLOW-config.yaml 'pathway_enforcement:' 'must mention the pathway_enforcement stanza'
need_literal templates/WORKFLOW-config.yaml 'mode: off' 'must keep the scaffold non-enforcing by default for now'
need_literal templates/WORKFLOW-config.yaml 'attempt_ceiling: 3' 'must document the attempt ceiling in the pathway_enforcement stanza'

printf 'PASS: pathway contract profiles\n'
