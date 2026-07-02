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
# Six variants — Closes/Fixes/Resolves, the lowercase "closed" tense, and ALL-CAPS / mixed-case
# ("CLOSES" / "cLoSeS") proving Rule M matches case-insensitively (GitHub's own keyword match is
# fully case-insensitive; a rule that only varied the first letter's case would let a shouted or
# mixed-case keyword slip through) — in one probe file, one repo, one lint run. Each must
# independently trip Rule M, so assert the exact finding COUNT rather than just exit 1 (a count of
# 1 would mean five of the six silently slipped through).
R="$(lint_mk_repo backticked-variants)"
cat > "$R/templates/probe.md" <<'EOF'
On merge this PR carries `Closes #5` in its body.
The body reads `Fixes #12` for the linked issue.
Write `Resolves #7` so the issue auto-closes.
History note: `closed #9` previously.
Shouted: `CLOSES #3` still defeats the parser.
Mixed case: `cLoSeS #4` too.
EOF
out="$(lint_run "$R")"; rc=$?
[ "$rc" -eq 1 ] || fail "backtick-wrapped closing keywords: expected exit 1, got $rc. Output:
$out"
count=$(printf '%s' "$out" | grep -cF '[backticked-closing-keyword]')
[ "$count" -eq 6 ] || fail "backtick-wrapped closing keywords: expected 6 [backticked-closing-keyword] findings (Closes/Fixes/Resolves/closed/CLOSES/cLoSeS), got $count. Output:
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

# ---- (b) every PR-authoring agent instructs an UNBACKTICKED closing keyword --------------------
# assert_unbackticked_closes_instruction FILE LABEL — the same four checks against any
# PR-authoring role prompt: names the file, states the unbackticked rule, names the keyword form,
# explains why (auto-close parser), and eats its own dogfood (no backtick-wrapped example inline).
assert_unbackticked_closes_instruction() {
  local f="$1" label="$2"
  [ -f "$f" ] || fail "$label missing at $f"
  grep -qiE 'backtick' "$f" \
    || fail "$label must instruct the closing keyword be written unbackticked"
  grep -qiE "closes #|fixes #|resolves #" "$f" \
    || fail "$label must name the closing-keyword form (Closes/Fixes/Resolves #<N>)"
  grep -qiE "auto-close|closingIssuesReferences" "$f" \
    || fail "$label must explain WHY (GitHub's auto-close parser / closingIssuesReferences)"
  # Eat our own dogfood: the instruction text itself must not contain a backtick-wrapped closing
  # keyword (that would be the exact defect it's warning against, sitting right there in the
  # prose). Case-insensitive, matching Rule M's own match (GitHub's keyword match is case-blind).
  grep -qiE '`(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+`' "$f" \
    && fail "$label must not itself contain a backtick-wrapped closing keyword"
}

assert_unbackticked_closes_instruction \
  "$PLUGIN/agents/idc-implementer.md" "agents/idc-implementer.md"
echo "PASS (b1): agents/idc-implementer.md (Claude runtime) instructs an unbackticked PR closing keyword"

# Pi runtime parity: build-impl opens the build PR the same way the Claude implementer does (see
# runtime/pi/.pi/agents/idc/build-implementer.md's "Open the build PR..." operating-mode step) —
# runtime/ isn't in scripts/lint-references.sh's scanned surface (agents/skills/commands/templates
# only), so this is the only guard against the two runtimes drifting apart on this instruction.
# build-finisher.md is deliberately NOT checked here: it only merges (`gh pr merge`), it never
# authors the PR body, so it has nothing to instruct — same asymmetry as the Claude finisher.
assert_unbackticked_closes_instruction \
  "$PLUGIN/runtime/pi/.pi/agents/idc/build-implementer.md" "runtime/pi build-implementer.md"
echo "PASS (b2): runtime/pi/.pi/agents/idc/build-implementer.md (Pi runtime) instructs an unbackticked PR closing keyword"

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
