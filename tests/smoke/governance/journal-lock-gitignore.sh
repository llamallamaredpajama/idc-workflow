#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: the journal's advisory-lock SIDECAR (docs/workflow/transition-journal.ndjson.lock) is
# a runtime-only flock token rotation + journal_append create — never committed. The janitor's
# --ensure-gitignore (wired into idc_init_scaffold.sh, mirroring the Phase 3 Stage A ledger sidecar)
# must add it to the repo-root .gitignore idempotently, non-destructively, governed-repo-gated — AND the
# ignored pattern must MATCH the sidecar path rotation actually locks (journal_lock_path), so the ignore
# rule and the lock path cannot drift.

. "$(dirname "$0")/lib.sh"
JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"

# (0) drift guard: the gitignore pattern joined onto a repo == the sidecar journal_lock_path() locks.
python3 - "$GOV_PLUGIN/scripts" <<'PY' || gov_fail "the gitignore pattern drifted from journal_lock_path()"
import os, sys
sys.path.insert(0, sys.argv[1])
import idc_git_janitor as J
repo = "/tmp/some-repo"
journal = os.path.join(repo, J.JOURNAL_REL)
want = J.journal_lock_path(journal)                          # what rotation actually locks
got = os.path.join(repo, J.JOURNAL_LOCK_GITIGNORE_LINE.replace("/", os.sep))  # what we gitignore
if os.path.normpath(want) != os.path.normpath(got):
    raise SystemExit(f"ignore pattern {got!r} != locked sidecar {want!r} (drift)")
PY
echo "  ok (0) the ignored pattern matches the sidecar rotation locks (no drift)"

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT

# (1) non-governed repo → no-op (never litters a non-IDC dir with a .gitignore).
python3 "$JAN" --repo "$D" --ensure-gitignore >/dev/null
[ ! -f "$D/.gitignore" ] || gov_fail "--ensure-gitignore must be a no-op (no .gitignore) outside a governed repo"
echo "  ok (1) non-governed repo → no .gitignore created"

# (2) governed repo: appends the sidecar line, preserving the operator's existing lines.
mkdir -p "$D/docs/workflow"; echo "backend: filesystem" > "$D/docs/workflow/tracker-config.yaml"
printf 'node_modules/\n.env\n' > "$D/.gitignore"
out="$(python3 "$JAN" --repo "$D" --ensure-gitignore)"
[ "$out" = "journal-lock-gitignore-added" ] || gov_fail "first ensure must report 'added', got '$out'"
grep -qx "docs/workflow/transition-journal.ndjson.lock" "$D/.gitignore" \
  || gov_fail "the sidecar ignore line must be present after ensure"
grep -qx "node_modules/" "$D/.gitignore" && grep -qx ".env" "$D/.gitignore" \
  || gov_fail "the operator's existing .gitignore lines must be PRESERVED (non-destructive)"
echo "  ok (2) governed repo → sidecar line appended, operator lines preserved"

# (3) idempotent: a re-run reports already-present and never duplicates the line.
out2="$(python3 "$JAN" --repo "$D" --ensure-gitignore)"
[ "$out2" = "journal-lock-gitignore-already-present" ] || gov_fail "re-run must report 'already-present', got '$out2'"
n="$(grep -c "transition-journal.ndjson.lock" "$D/.gitignore")"
[ "$n" = "1" ] || gov_fail "idempotent re-run must not duplicate the sidecar line (found $n)"
echo "  ok (3) idempotent re-run → 'already-present', exactly one line"

# (4) drift contract: /idc:update §C must ALSO ensure the sidecar (a repo scaffolded before #150 learns
#     the ignore on update, else its first rotation strands an untracked .lock the janitor flags as
#     debris). Cheap prose-integrity grep — the scaffold covers new repos, §C covers existing ones.
UPDATE_MD="$GOV_PLUGIN/commands/update.md"
grep -qE 'idc_git_janitor\.py.*--ensure-gitignore' "$UPDATE_MD" \
  || gov_fail "/idc:update §C must call idc_git_janitor.py --ensure-gitignore (the existing-repo drift migration)"
echo "  ok (4) /idc:update §C wires the sidecar ensure-gitignore (existing-repo drift migration)"

echo "PASS: journal-lock sidecar is gitignored idempotently, non-destructively, governed-gated, the ignore pattern matches the locked sidecar path, and both scaffold + /idc:update migrate it."
