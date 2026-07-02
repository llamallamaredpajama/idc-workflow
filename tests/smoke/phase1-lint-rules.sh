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

echo "PASS: lint-references catches all five MIN-9 blind-spot classes (and honors lint-allow)"
