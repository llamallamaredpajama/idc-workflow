#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: the janitor's own SAFE-FIX board closes are sanctioned mutations, so they must
# land in the SAME canonical transition journal the engine writes. Otherwise `--apply-safe`'s
# re-scan compares the just-mutated board against a journal that still says the pre-fix Status and
# reports the janitor's OWN fix as a RISKY journal↔board divergence — the apply pass can never
# converge to clean.
#
# Rig: an engine-created + engine-claimed item (journal: In Progress) whose merged IDC build branch
# makes it a SAFE-FIX close-fs finding. `--apply-safe` closes the item (and deletes the merged
# branch); the re-scan must then find a coherent board — which requires the close to be journaled.

. "$(dirname "$0")/lib.sh"
gov_engine_env

git -C "$REPO" init -b main >/dev/null 2>&1
git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
git -C "$REPO" config user.name "Test" >/dev/null 2>&1
git -C "$REPO" commit --allow-empty -m "initial commit" >/dev/null 2>&1

item=$(eng create-ticket --title 'apply-safe journal convergence' --stage 'Buildable' --status 'Todo')
eng claim --num "$item" --agent tester >/dev/null
JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
[ -f "$JOURNAL" ] || fail "engine ops must have created the canonical journal"

# A merged IDC build branch for the item (tip == main HEAD → trivially merged) makes it SAFE-FIX.
git -C "$REPO" branch "build-$item" >/dev/null

echo "--- --apply-safe must converge: the applied board close is journaled, re-scan is clean ---"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --check-journal-divergence --apply-safe --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected apply-safe to converge to a coherent board (exit 0), got $rc: $output"
if echo "$output" | grep '"dim": "journal"'; then
    fail "the janitor's own SAFE-FIX close came back as a journal divergence — the board fix was not journaled: $output"
fi
grep -q '"op": "close"' "$JOURNAL" || \
    fail "expected the janitor to append its op=close record to the canonical journal"
grep -q '"who": "janitor"' "$JOURNAL" || \
    fail "expected the janitor's journal record to be attributed to the janitor"
[ "$(python3 "$GOV_TRK" --tracker "$T" show --num "$item" --field Status)" = "Done" ] \
  || fail "apply-safe should have closed #$item (Status=Done)"
echo "PASS: apply-safe board close is journaled and the re-scan converges to coherent."

echo "--- All journal-apply-safe-close tests passed! ---"
