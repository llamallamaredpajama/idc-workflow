#!/bin/bash
# lint-fixture.sh — shared scripts/lint-references.sh test harness: a minimal throwaway repo
# skeleton (9 command stubs + 1 well-formed skill) the linter can run a full CLEAN pass over, plus
# the expect_fail/expect_clean assertion helpers. Source this and call the makers. The caller must
# set $PLUGIN (repo root) and $LINT ($PLUGIN/scripts/lint-references.sh) and a $ROOT scratch dir
# (mktemp -d, trapped for cleanup by the caller).
#
#   lint_mk_repo NAME       build $ROOT/NAME as a clean skeleton carrying a COPY of the current
#                           linter (so every run tests the real, edited code); echoes the path.
#   lint_run REPO           run that repo's copy of the linter, echo combined stdout+stderr.
#   lint_expect_fail DESC REPO TAG    assert exit 1 and TAG present in the output (fail() on miss).
#   lint_expect_clean DESC REPO       assert exit 0 (fail() on miss).
#
# The caller must define fail() (a message-and-exit helper) before sourcing/calling these.

lint_mk_repo() {
  local d="$ROOT/$1"
  mkdir -p "$d/scripts" "$d/commands" "$d/agents" "$d/templates" "$d/skills/idc-probe"
  cp "$LINT" "$d/scripts/lint-references.sh"
  local c
  for c in autorun build doctor init plan recirculate think uninstall update; do
    printf '# %s\n\nThe %s command.\n' "$c" "$c" > "$d/commands/$c.md"
  done
  printf -- '---\nname: idc-probe\ndescription: probe skill for a lint fixture\n---\n# idc-probe\n\nA probe skill.\n' \
    > "$d/skills/idc-probe/SKILL.md"
  printf '%s' "$d"
}

lint_run() { ( bash "$1/scripts/lint-references.sh" 2>&1 ); }

lint_expect_fail() { # desc, repo, tag
  local out rc
  out="$(lint_run "$2")"; rc=$?
  [ "$rc" -eq 1 ] || fail "$1: expected exit 1, got $rc. Output:
$out"
  printf '%s' "$out" | grep -qF "$3" \
    || fail "$1: expected violation tag '$3' in linter output (rule not implemented?). Output:
$out"
}

lint_expect_clean() { # desc, repo
  local out rc
  out="$(lint_run "$2")"; rc=$?
  [ "$rc" -eq 0 ] || fail "$1: expected exit 0 (clean), got $rc. Output:
$out"
}
