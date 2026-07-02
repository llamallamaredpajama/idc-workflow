#!/bin/bash
# Phase 7 (closing keywords) smoke — issue #100 (design doc §B.3).
#
# The audit (docs/dev/audit-2026-07-01-idc-effectiveness.md §3, RC3) found all 16 checked PRs wrote
# their closing keyword backtick-wrapped (`` `Closes #N` ``), which GitHub's auto-close parser never
# recognizes — `closingIssuesReferences` stayed empty on every one, so merging never closed the
# issue. The fix has three parts, each asserted here:
#   (a) scripts/lint-references.sh gains a rule that flags a BACKTICK-WRAPPED closing keyword in
#       shipped markdown (agents/skills/commands/templates) and leaves the correct, unbackticked
#       form alone.
#   (b) the PR-authoring agent (agents/idc-implementer.md — it opens the draft PR at hand-off,
#       see agents/idc-finisher.md's git-finalization step for where the *existing* PR gets merged)
#       carries an explicit instruction to write the closing keyword unbackticked.
#   (c) commands/init.md and commands/update.md each describe the operator-consent-gated
#       deleteBranchOnMerge offer — a platform-level backstop, never auto-applied.
#
# Red-when-broken: (a) removing the backtick detection from the new lint rule makes the
# "flags backticked closes" assertion below FAIL (its tag stops appearing in the linter's output);
# (b)/(c) are plain content greps against the real shipped files — deleting the instruction/offer
# text fails them directly.
#
# Usage: bash tests/smoke/phase7-closing-keywords.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$PLUGIN/scripts/lint-references.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

[ -f "$LINT" ] || fail "linter not found at $LINT"

# lint_mk_repo / lint_run / lint_expect_fail / lint_expect_clean — shared fixture harness (also
# used by tests/smoke/phase1-lint-rules.sh's own inline copy of the same pattern).
. "$PLUGIN/tests/smoke/lib/lint-fixture.sh"

# ---- (a1) every backtick-wrapped GitHub closing keyword is flagged, in one lint pass -----------
# Four variants (Closes/Fixes/Resolves, plus the lowercase "closed" tense) in one probe file, one
# repo, one lint run — each must independently trip Rule M, so assert the exact finding COUNT
# rather than just exit 1 (a count of 1 would mean three of the four silently slipped through).
R="$(lint_mk_repo backticked-variants)"
cat > "$R/templates/probe.md" <<'EOF'
On merge this PR carries `Closes #5` in its body.
The body reads `Fixes #12` for the linked issue.
Write `Resolves #7` so the issue auto-closes.
History note: `closed #9` previously.
EOF
out="$(lint_run "$R")"; rc=$?
[ "$rc" -eq 1 ] || fail "backtick-wrapped closing keywords: expected exit 1, got $rc. Output:
$out"
count=$(printf '%s' "$out" | grep -cF '[backticked-closing-keyword]')
[ "$count" -eq 4 ] || fail "backtick-wrapped closing keywords: expected 4 [backticked-closing-keyword] findings (Closes/Fixes/Resolves/closed), got $count. Output:
$out"

# ---- (a2) control: the UNBACKTICKED (correct) form must NOT be flagged -------------------------
R="$(lint_mk_repo unbackticked-closes)"
printf 'This PR body carries Closes #5, written as plain text.\n' > "$R/templates/probe.md"
lint_expect_clean "unbacktick-wrapped Closes #N is the correct form" "$R"

# ---- (a3) control: the bare skeleton with no injected pattern stays clean -----------------------
# (docs/ isn't in Rule M's scan surface either — same surfaces as every other per-file rule — so
# the audit/design docs quoting the bad pattern for illustration never trip it; proven for real by
# (2) below: the actual `bash scripts/lint-references.sh` run over this repo must still exit 0.)
R="$(lint_mk_repo bare-control)"
lint_expect_clean "bare skeleton with no injected pattern" "$R"

echo "PASS (a): Rule M flags every backtick-wrapped closing keyword and leaves the unbackticked form alone"

# ---- (b) the PR-authoring agent instructs an UNBACKTICKED closing keyword ----------------------
IMPL="$PLUGIN/agents/idc-implementer.md"
[ -f "$IMPL" ] || fail "agents/idc-implementer.md missing"
grep -qiE 'backtick' "$IMPL" \
  || fail "agents/idc-implementer.md must instruct the closing keyword be written unbackticked"
grep -qiE "closes #|fixes #|resolves #" "$IMPL" \
  || fail "agents/idc-implementer.md must name the closing-keyword form (Closes/Fixes/Resolves #<N>)"
grep -qiE "auto-close|closingIssuesReferences" "$IMPL" \
  || fail "agents/idc-implementer.md must explain WHY (GitHub's auto-close parser / closingIssuesReferences)"
# Eat our own dogfood: the instruction text itself must not contain a backtick-wrapped closing
# keyword (that would be the exact defect it's warning against, sitting right there in the prose).
grep -qE '`([Cc]lose[sd]?|[Ff]ix(e[sd])?|[Rr]esolve[sd]?)[[:space:]]+#[0-9]+`' "$IMPL" \
  && fail "agents/idc-implementer.md must not itself contain a backtick-wrapped closing keyword"

echo "PASS (b): agents/idc-implementer.md instructs an unbackticked PR closing keyword"

# ---- (c) init.md / update.md describe the consent-gated deleteBranchOnMerge offer --------------
for f in "$PLUGIN/commands/init.md" "$PLUGIN/commands/update.md"; do
  [ -f "$f" ] || fail "$f missing"
  grep -qiE 'deleteBranchOnMerge' "$f" \
    || fail "$f must describe the deleteBranchOnMerge offer"
  grep -qiE 'gh repo edit --delete-branch-on-merge' "$f" \
    || fail "$f must show the exact gh repo edit --delete-branch-on-merge mutation"
  grep -qiE 'consent|ask the operator' "$f" \
    || fail "$f must gate the offer on operator consent"
  grep -qiE 'never.{0,20}silently|never flip it silently' "$f" \
    || fail "$f must state the setting is never flipped silently"
done

echo "PASS (c): init.md and update.md both offer the consent-gated deleteBranchOnMerge backstop"

echo "PASS: closing keywords (#100) — lint rule, PR-authoring instruction, and init/update offer all present"
