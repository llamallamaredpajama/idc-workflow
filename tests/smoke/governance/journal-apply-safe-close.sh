#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: the janitor's own SAFE-FIX board closes are sanctioned mutations, so they must
# land in the SAME canonical transition journal the engine writes. Otherwise `--apply-safe`'s
# re-scan compares the just-mutated board against a journal that still says the pre-fix Status and
# reports the janitor's OWN fix as a RISKY journal↔board divergence — the apply pass can never
# converge to clean.
#
# AND the record must be the janitor's OWN disclosed kind (codex round-12 P1): op=janitor-repair
# carrying the deterministic truth the SAFE-FIX classifier verified — never an engine `close`
# look-alike, which would launder the janitor's reconciliation into a sanctioned guarded close in
# the audit trail (a verdict-free third door to Done). Revert the record to op=close → this FAILs.
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
grep -q '"op": "janitor-repair"' "$JOURNAL" || \
    fail "expected the janitor to journal its repair as its OWN op=janitor-repair record"
grep -q '"door": "janitor-safe-fix"' "$JOURNAL" || \
    fail "the janitor-repair record does not disclose the janitor-safe-fix door"
grep -q '"verified": "Status=In Progress but its IDC build branch merged"' "$JOURNAL" || \
    fail "the janitor-repair record does not carry the deterministic truth the classifier verified"
grep -q '"who": "janitor"' "$JOURNAL" || \
    fail "expected the janitor's journal record to be attributed to the janitor"
if grep '"who": "janitor"' "$JOURNAL" | grep -q '"op": "close"'; then
    fail "the janitor journaled an engine-close look-alike (op=close) — the verdict-free third-door masquerade (codex round-12 P1)"
fi
[ "$(python3 "$GOV_TRK" --tracker "$T" show --num "$item" --field Status)" = "Done" ] \
  || fail "apply-safe should have closed #$item (Status=Done)"
echo "PASS: apply-safe board close is journaled and the re-scan converges to coherent."

echo "--- unsupported raw Done must NOT be laundered through a SAFE-FIX board close ---"
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "apply-safe laundered a raw Done despite journal divergence"
import sys
sys.path.insert(0, sys.argv[1])
import idc_git_janitor as J

calls = []

def fake_apply_board(finding, ctx):
    calls.append((finding.get("op"), finding.get("number")))
    return True, "closed issue"

J._apply_board = fake_apply_board
findings = [
    J.finding(J.SAFE_FIX, "board", "#42",
              "Status=Done but the issue is still OPEN",
              "close the issue (gh issue close)", number=42, op="close-issue"),
    J.finding(J.RISKY, "journal", "#42",
              "Status mismatch: journal says 'Todo', board says 'Done'",
              "reconcile manually", number=42),
]
results = J.apply_safe(findings, {"repo": "/tmp/repo", "backend": "github"})
if calls:
    raise SystemExit("apply_safe executed a SAFE-FIX board close for #42 even though the same item "
                     "already had a journal divergence finding — that launders an unsupported raw Done")
if len(results) != 1:
    raise SystemExit(f"expected one skipped SAFE-FIX result, got: {results!r}")
finding, ok, note = results[0]
if ok:
    raise SystemExit(f"the raw-Done SAFE-FIX was reported successful instead of refused: {results!r}")
if finding.get("number") != 42 or "journal" not in note.lower():
    raise SystemExit(f"the refusal must stay attached to #42 and name the journal divergence: {results!r}")
print("  ok an unsupported raw Done with a journal mismatch is REFUSED before any SAFE-FIX board close runs")
PY

echo "--- All journal-apply-safe-close tests passed! ---"
