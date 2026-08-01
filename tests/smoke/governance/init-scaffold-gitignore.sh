#!/bin/bash
# idc-assert-class: behavior
# init-scaffold-gitignore.sh — issue #184 operator-experience pair: the scaffold gitignores the two
# machine-local state files that made a bare `git add -A` stage a protected surface.
#
# `docs/workflow/install-receipt.yaml` (the machine-owned fingerprint manifest) and
# `docs/workflow/reconciliation-seen-findings.json` (the janitor/doctor dedup ledger) are working
# state exactly like the `.idc-*` sidecars the scaffold already ignores — but they were NOT ignored,
# so the natural post-init `git add -A && git commit` staged the receipt and the pre-commit gate
# (correctly) denied the commit, wedging the operator's scaffold commit with no working recipe.
#
# Red-when-broken: drop the ensure block from idc_init_scaffold.sh and (1) fails; make it clobber or
# duplicate instead of append-if-missing and (2)/(3) fail.
#
# Usage: bash tests/smoke/governance/init-scaffold-gitignore.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$SCAFFOLD" ] || fail "missing scaffold: scripts/idc_init_scaffold.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

mk_repo() {  # $1=dir — a git repo the scaffold can target (filesystem backend, no board needed)
  git init -q -b main "$1"
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
}

ENTRY_RECEIPT="docs/workflow/install-receipt.yaml"
ENTRY_SEEN="docs/workflow/reconciliation-seen-findings.json"

# (1) a fresh scaffold ignores BOTH machine-local files, each as its own exact line.
R1="$WORK/fresh"; mk_repo "$R1"
bash "$SCAFFOLD" "$PLUGIN" "$R1" "gitignore-test" filesystem >/dev/null 2>&1 \
  || fail "(1) the scaffold itself failed on a fresh filesystem repo"
for entry in "$ENTRY_RECEIPT" "$ENTRY_SEEN"; do
  grep -qxF "$entry" "$R1/.gitignore" \
    || fail "(1) fresh scaffold did not gitignore $entry — a bare 'git add -A' will stage it and the pre-commit gate will deny the operator's scaffold commit"
done
# ...and git really considers a file at each path ignored (the line WORKS, not merely exists).
mkdir -p "$R1/docs/workflow"
printf 'x\n' > "$R1/$ENTRY_RECEIPT"
printf '{}\n' > "$R1/$ENTRY_SEEN"
git -C "$R1" check-ignore -q "$ENTRY_RECEIPT" \
  || fail "(1) git does not treat $ENTRY_RECEIPT as ignored despite the .gitignore line"
git -C "$R1" check-ignore -q "$ENTRY_SEEN" \
  || fail "(1) git does not treat $ENTRY_SEEN as ignored despite the .gitignore line"
echo "  ok (1) fresh scaffold ignores the receipt + seen-findings ledger, effectively"

# (2) APPEND-ONLY: an operator's existing .gitignore content survives, including one WITHOUT a
#     trailing newline (the append must not fuse onto the last line).
R2="$WORK/existing"; mk_repo "$R2"
printf 'node_modules/\n*.log' > "$R2/.gitignore"        # deliberately no trailing newline
bash "$SCAFFOLD" "$PLUGIN" "$R2" "gitignore-test" filesystem >/dev/null 2>&1 \
  || fail "(2) the scaffold failed on a repo with an existing .gitignore"
grep -qxF 'node_modules/' "$R2/.gitignore" || fail "(2) the operator's node_modules/ line was lost"
grep -qxF '*.log' "$R2/.gitignore" \
  || fail "(2) the operator's un-terminated last line was fused with an appended entry: $(tail -3 "$R2/.gitignore")"
grep -qxF "$ENTRY_RECEIPT" "$R2/.gitignore" || fail "(2) $ENTRY_RECEIPT was not appended"
grep -qxF "$ENTRY_SEEN" "$R2/.gitignore" || fail "(2) $ENTRY_SEEN was not appended"
echo "  ok (2) an existing .gitignore is appended to, never clobbered or fused"

# (3) IDEMPOTENT: a re-run adds nothing (exactly one line per entry).
bash "$SCAFFOLD" "$PLUGIN" "$R2" "gitignore-test" filesystem >/dev/null 2>&1 \
  || fail "(3) the scaffold re-run failed"
for entry in "$ENTRY_RECEIPT" "$ENTRY_SEEN"; do
  n="$(grep -cxF "$entry" "$R2/.gitignore")"
  [ "$n" = "1" ] || fail "(3) re-run duplicated $entry ($n lines) — the ensure step is not idempotent"
done
echo "  ok (3) the ensure step is idempotent"

echo "PASS: the scaffold gitignores docs/workflow/install-receipt.yaml and docs/workflow/reconciliation-seen-findings.json (issue #184 operator pair) — effectively (git check-ignore agrees), append-only over an operator's existing .gitignore even without a trailing newline, and idempotently"
