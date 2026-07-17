#!/bin/bash
# idc-assert-class: behavior
set -uo pipefail
. "$(dirname "$0")/lib.sh"
CHECK="$GOV_PLUGIN/scripts/idc_worktree_stability.py"
[ -f "$CHECK" ] || gov_fail "worktree stability checker is missing"
WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO" || exit 1
git init -q && git config user.email t@example.com && git config user.name t
printf 'base\n' > tracked.txt; git add tracked.txt; git commit -qm base
BEFORE="$(git status --porcelain=v2 --untracked-files=all)"
sh -c 'sleep 0.2' & stable_pid=$!
python3 "$CHECK" --repo "$REPO" --pid "$stable_pid" --samples 3 --interval 0.05 \
  || gov_fail "stable worktree failed the post-process checker"
[ "$(git status --porcelain=v2 --untracked-files=all)" = "$BEFORE" ] \
  || gov_fail "the checker mutated the stable worktree"
sh -c 'sleep 0.2; printf changed > tracked.txt' & mutating_pid=$!
if python3 "$CHECK" --repo "$REPO" --pid "$mutating_pid" --samples 3 --interval 0.05 >/dev/null 2>&1; then
  gov_fail "checker accepted a worktree changed by the terminating process"
fi
grep -Eq '\bgit (reset|checkout|restore)\b' "$CHECK" \
  && gov_fail "checker contains a destructive recovery command"
echo "PASS: worktree checker waits for process exit, samples three times, detects change, and never resets"
