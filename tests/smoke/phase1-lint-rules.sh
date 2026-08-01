#!/bin/bash
# idc-assert-class: behavior
# Phase 1 (lint rules) smoke — the MIN-9 residual blind-spot rules in scripts/lint-references.sh
# (issue #5). The linter implemented Rules A–E,G,H but none of these six gap-classes; this test
# pins each one red-when-broken.
#
# lint-references.sh has no target-dir argument — it `cd`s to "$(dirname "$0")/.." and scans the
# four shipped surfaces (agents/ skills/ commands/ templates/) relative to ITS OWN location. So to
# run it against a controlled fixture we build a throwaway repo skeleton, copy the CURRENT linter
# into it (so we always test the edited script), seed ONE bad pattern into a scanned surface, and
# assert the linter exits 1 AND prints the specific new violation tag. Each bad class also gets a
# clean counterpart (the bare skeleton, asserted to exit 0).
#
# Red-when-broken: every assertion greps for the SPECIFIC new tag, not just the exit code — so a
# linter that lacks the rule fails the assertion even when an older rule (e.g. Rule A) happens to
# also fire. Classes 2a/3/4/5 exit 0 entirely until their rule lands (the crispest red).
#
# Classes covered (issue #5):
#   1. idc:idc: doubled namespace prefix                 -> [doubled-namespace]
#   2. unknown /idc:<token> slash command (typo or       -> [unknown-slash-command]
#      a slash pointed at a non-command component)
#   3. a ~/.claude/{agents,skills,commands,plugins} CONTENT  -> [personal-path-or-memory]
#      path that omits the slash separator (a BARE standalone
#      dir name stays exempt as a universal-harness mention)
#   4. /Users/<Capitalized> username                      -> [personal-path-or-memory]
#   5. an idc- reference split across a line break        -> [split-component-ref]
# (The audit's optional shellcheck-CI note is out of scope for this rule-level test.)
#
# Usage: bash tests/smoke/phase1-lint-rules.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$PLUGIN/scripts/lint-references.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

[ -f "$LINT" ] || fail "linter not found at $LINT"

# Build a clean throwaway repo skeleton under $ROOT/<name> and echo its path. The skeleton is the
# minimum the linter needs to run a full, CLEAN pass: the 9 command stubs (the valid slash-command
# set is derived from commands/*.md) and one well-formed skill component (so /idc:<skill> can be
# distinguished from /idc:<command>). It carries the edited linter so every run tests current code.
mk_repo() {
  local d="$ROOT/$1"
  mkdir -p "$d/scripts" "$d/commands" "$d/agents" "$d/templates" "$d/skills/idc-probe"
  cp "$LINT" "$d/scripts/lint-references.sh"
  local c
  for c in autorun build doctor init plan recirculate think uninstall update; do
    printf '# %s\n\nThe %s command.\n' "$c" "$c" > "$d/commands/$c.md"
  done
  printf -- '---\nname: idc-probe\ndescription: probe skill for the lint fixture\n---\n# idc-probe\n\nA probe skill.\n' \
    > "$d/skills/idc-probe/SKILL.md"
  printf '%s' "$d"
}

run_lint() { ( bash "$1/scripts/lint-references.sh" 2>&1 ); }

# desc, repo, tag — the linter MUST exit 1 and the output MUST name the specific violation.
expect_fail() {
  local out rc
  out="$(run_lint "$2")"; rc=$?
  [ "$rc" -eq 1 ] || fail "$1: expected exit 1, got $rc. Output:
$out"
  printf '%s' "$out" | grep -qF "$3" \
    || fail "$1: expected violation tag '$3' in linter output (rule not implemented?). Output:
$out"
}

# desc, repo — the bare skeleton (no injected bad pattern) MUST be clean.
expect_clean() {
  local out rc
  out="$(run_lint "$2")"; rc=$?
  [ "$rc" -eq 0 ] || fail "$1: expected exit 0 (clean), got $rc. Output:
$out"
}

# ---- control: the bare skeleton is clean ------------------------------------------------------
R="$(mk_repo clean)"
expect_clean "control: bare skeleton must lint clean" "$R"

# ---- class 1: idc:idc: doubled namespace ------------------------------------------------------
R="$(mk_repo c1)"
printf 'Spawn idc:idc:build to orchestrate.\n' > "$R/templates/probe.md"
expect_fail "class 1: idc:idc: double" "$R" "[doubled-namespace]"

# ---- class 2a: a /idc:<token> slash command pointed at a NON-command component ----------------
# idc-probe resolves as a skill (so Rule A is satisfied), but a SLASH command must be one of the 9
# command stems — only the new rule catches this, so the linter is fully clean until it lands.
R="$(mk_repo c2a)"
printf 'Run /idc:idc-probe next.\n' > "$R/templates/probe.md"
expect_fail "class 2a: /idc: pointed at a skill, not a command" "$R" "[unknown-slash-command]"

# ---- class 2b: a /idc:<token> typo of a real command ------------------------------------------
R="$(mk_repo c2b)"
printf 'Run /idc:bild to start the build.\n' > "$R/templates/probe.md"
expect_fail "class 2b: /idc:bild command typo" "$R" "[unknown-slash-command]"

# ---- class 3: a ~/.claude/<plugin-dir> content path that OMITS the slash separator -------------
# `skills.bak` glues content to the dir name without the canonical `/`, so the original
# slash-anchored rule missed it. A BARE `~/.claude/skills` (whitespace/backtick after) is exempt by
# design — that is the universal-harness mention class — and is covered by the clean control above.
R="$(mk_repo c3)"
printf 'Stale copy at ~/.claude/skills.bak left behind.\n' > "$R/templates/probe.md"
expect_fail "class 3: ~/.claude/skills.bak no-slash content path" "$R" "[personal-path-or-memory]"
# control: the BARE dir mention must stay clean (universal-harness exemption, like teams/tasks)
R="$(mk_repo c3bare)"
printf 'The mirror tracks ~/.claude/skills entries automatically.\n' > "$R/templates/probe.md"
expect_clean "class 3 control: bare ~/.claude/skills mention is exempt" "$R"

# ---- class 4: /Users/<Capitalized> username ---------------------------------------------------
R="$(mk_repo c4)"
printf 'See /Users/Jeremy/dev/thing for the path.\n' > "$R/templates/probe.md"
expect_fail "class 4: /Users/Capitalized username" "$R" "[personal-path-or-memory]"

# ---- class 5: an idc- reference split across a line break -------------------------------------
# The token is broken at the hyphen across the newline; Rule G is line-based and misses it.
R="$(mk_repo c5)"
printf 'See the idc-\nbuild orchestrator.\n' > "$R/templates/probe.md"
expect_fail "class 5: idc- reference split across a line break" "$R" "[split-component-ref]"

# ---- allow-marker respected: a deliberately-retained bad ref with lint-allow does NOT fail ----
# (Rules B–G honor the lint-allow marker; the new path/slash/split rules must too.)
R="$(mk_repo allow)"
printf 'Legacy doc path /Users/Jeremy/old kept on purpose. lint-allow: historical example\n' \
  > "$R/templates/probe.md"
expect_clean "allow-marker: lint-allow line is exempt from the new path rule" "$R"

# ---- Rule Q: the DETECTOR, not just the pin test -----------------------------------------------
# Rule Q's security value lives entirely in what its grep SEES. Every spelling below is valid YAML
# that GitHub Actions runs exactly like the canonical `uses: owner/action@ref` form, and each one
# used to slip past the detector — an unpinned action that lints CLEAN is worse than no rule, because
# the CLEAN line is read as evidence the workflow is pinned. `uses` never appeared in the fixture
# skeleton, so these repos also prove the rule runs at all.
SHA40=1111111111111111111111111111111111111111
mk_wf() {                # $1 = fixture name, $2 = the `uses:` line to plant (already indented)
  local d; d="$(mk_repo "$1")"
  mkdir -p "$d/.github/workflows"
  { printf 'name: probe\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '%s\n' "$2"
  } > "$d/.github/workflows/probe.yml"
  printf '%s' "$d"
}

# The canonical unpinned form — the control that proves the fixture reaches the rule at all.
R="$(mk_wf q-canonical '      - uses: actions/checkout@v4')"
expect_fail "Rule Q: canonical unpinned tag ref" "$R" "[unpinned-action]"

# (a) YAML permits whitespace before the `:`; the old anchor required `uses:` with none.
R="$(mk_wf q-spacecolon '      - uses : actions/checkout@v4')"
expect_fail "Rule Q: 'uses :' with a space before the colon is still an unpinned action" "$R" "[unpinned-action]"

# (b) FLOW mapping — `uses` is not the first token on the line, so a line-anchored pattern missed it.
R="$(mk_wf q-flow '      - {uses: actions/checkout@v4}')"
expect_fail "Rule Q: '- {uses: ...}' flow mapping is still an unpinned action" "$R" "[unpinned-action]"

# (c) Flow mapping where `uses` follows another key — the ref must be read from the LAST uses key and
#     its trailing `}` stripped, or a correctly pinned flow entry would false-positive instead.
R="$(mk_wf q-flow2 '      - {name: checkout, uses: actions/checkout@v4}')"
expect_fail "Rule Q: '{name: x, uses: y@tag}' flow mapping is still an unpinned action" "$R" "[unpinned-action]"

# (d) FALSE-POSITIVE control: a correctly pinned but QUOTED ref must lint CLEAN. The quote broke the
#     `@<40-hex>$` anchor, so the rule reported a good pin as unpinned — the failure mode that gets a
#     supply-chain rule disabled. Asserted in all three spellings the extractor must now handle.
R="$(mk_wf q-quoted "      - uses: \"actions/checkout@$SHA40\" # v4")"
expect_clean "Rule Q control: a double-quoted 40-hex pin is correctly pinned" "$R"
R="$(mk_wf q-quoted1 "      - uses: 'actions/checkout@$SHA40'")"
expect_clean "Rule Q control: a single-quoted 40-hex pin is correctly pinned" "$R"
R="$(mk_wf q-flowpin "      - {uses: actions/checkout@$SHA40}")"
expect_clean "Rule Q control: a flow-mapping 40-hex pin is correctly pinned" "$R"

# (e) The local-action exemption must not cover a `..` traversal out of this repo's action surface.
R="$(mk_wf q-dotdot '      - uses: ./../../elsewhere/action')"
expect_fail "Rule Q: './../..' local ref escapes the repo and is not exempt" "$R" "[unpinned-action]"
# ...while a genuine in-repo local action stays exempt (or the rule above is a blanket refusal).
R="$(mk_wf q-local '      - uses: ./.github/actions/probe')"
expect_clean "Rule Q control: an in-repo './' local action stays exempt" "$R"

# ---- Rule R: no shipped surface may direct a caller at a Path Gate minting door -----------------
# `scripts/idc_path_gate.py` has no `authorize` verb (V-DOOR) and the scenario mint fixture
# `tests/smoke/lib/path_gate_authorize.py` ships inside the plugin package — a playbook pointing at
# either is a privilege-escalation instruction shipped to every governed repo, and nothing caught it.
R="$(mk_repo r-verb)"
printf 'Then run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_path_gate.py" authorize --repo "$PWD"`.\n' \
  > "$R/templates/probe.md"
expect_fail "Rule R: prose re-adding the deleted idc_path_gate.py authorize verb" "$R" "[path-gate-mint-directive]"
R="$(mk_repo r-fixture)"
printf 'Set up the grant with `python3 "${CLAUDE_PLUGIN_ROOT}/tests/smoke/lib/path_gate_authorize.py" --repo .`.\n' \
  > "$R/templates/probe.md"
expect_fail "Rule R: prose pointing at the shipped scenario mint fixture" "$R" "[path-gate-mint-directive]"
# Control: a PROHIBITION naming the door in order to forbid it must stay clean, or the honest
# documentation of the deleted verb becomes unwritable and the rule gets suppressed instead.
R="$(mk_repo r-prohibition)"
printf 'There is no `idc_path_gate.py authorize` verb; minting is admission-side.\n' \
  > "$R/templates/probe.md"
expect_clean "Rule R control: a prohibition naming the deleted verb is exempt" "$R"

echo "PASS: lint-references catches all five MIN-9 blind-spot classes, sees every valid uses: spelling without false-positiving a quoted pin (Rule Q), refuses a '..' local-action ref, blocks shipped prose that points at a Path Gate minting door (Rule R), and honors lint-allow"
