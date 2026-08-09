#!/bin/bash
# idc-assert-class: behavior
# worktree-claim-evidence.sh — #210: a Build claim in a LINKED WORKTREE must see the same evidence
# the governed checkout holds.
#
# THE DEFECT. Build gives each durable worker its own linked worktree BY DESIGN. Two pieces of
# claim-side evidence resolved per-worktree, so neither was visible there:
#   * the OBLIGATIONS LEDGER (`.idc-session-state.json`) — resolved at the worktree root, which has
#     no ledger, so the Build command lifecycle record stored in the governed checkout was invisible;
#   * the INSTALL RECEIPT (`docs/workflow/install-receipt.yaml`) — GITIGNORED, so it exists only in
#     the checkout that was scaffolded and a linked worktree never carries one.
# The 2026-08-09 release e2e (run rel600-install-3) worked around both by hand: an auxiliary Init
# self-mint authorization inside the worktree, plus an exact copy of the ignored receipt. Every
# headless build in a worktree needed the same bridging — the exact toil the worktree fixes exist to
# remove. #197/#199 made the witness chain and finish tail worktree-correct; this is the claim side.
#
# THE PATTERN. Both now resolve through the COMMON git dir, the same way the validation witness store
# and the uninstall witness already do: `--git-dir` is per-worktree, `--git-common-dir` is shared, and
# its parent is the governed checkout. Nothing is copied.
#
# Red-when-broken: revert either resolver to the worktree-local path and its case fails.
#
# Usage: bash tests/smoke/governance/worktree-claim-evidence.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

T_S="${T_S:-120}"
command -v timeout >/dev/null 2>&1 \
  || fail "BLOCKED: \`timeout\` is not on PATH. Every probe here runs under an explicit bound so a
hung helper REDS instead of looking like a slow pass. Run via tests/smoke/run-all.sh, or install
coreutils, then re-run."

# A governed checkout with a real linked worktree beside it.
REPO="$WORK/governed"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
mkdir -p "$REPO/docs/workflow"
# The receipt's plugin_version is deliberately a value the PLUGIN itself can never carry: the
# freshness verdict also echoes the running plugin's own version, so a marker like "6.0.1" would match
# whether or not the receipt was ever read — a self-satisfying grep that proves nothing.
printf 'receipt_version: 2\nplugin_version: "9.9.9-fixture-receipt"\nfingerprint_method: sha256\nfiles: []\n' \
  > "$REPO/docs/workflow/install-receipt.yaml"
# The governance anchor: `command_start` is repo-GATED (a silent no-op outside a governed repo), so
# without this every ledger assertion below would pass for the wrong reason — on an empty ledger.
printf 'backend: filesystem\nproject_number: ""\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'docs/workflow/install-receipt.yaml\n.idc-session-state.json*\n' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore docs/workflow/tracker-config.yaml && git -C "$REPO" commit -qm init
WT="$WORK/wt-build-55"
git -C "$REPO" worktree add -q -b build/55 "$WT" 2>/dev/null \
  || fail "could not create the linked worktree the fixture needs"

# CONTROLS FIRST — both premises must really hold in a linked worktree, or every assertion below
# would pass for the wrong reason.
[ ! -e "$WT/docs/workflow/install-receipt.yaml" ] \
  || fail "control: the linked worktree unexpectedly HAS its own install receipt, so '#210's premise
(a gitignored receipt never reaches a worktree) does not hold here and the fallback proves nothing"
[ "$(git -C "$WT" rev-parse --git-dir)" != "$(git -C "$WT" rev-parse --git-common-dir)" ] \
  || fail "control: the fixture's worktree is not a LINKED one (its git dir equals the common dir)"

# ── 1. the obligations ledger is REPOSITORY-WIDE ─────────────────────────────────────────────────
# A Build lifecycle record opened in the governed checkout must be readable from the worktree the
# claim actually runs in — that record is what the claim's authorization is bound to.
timeout "$T_S" python3 - "$PLUGIN/scripts/hooks" "$REPO" "$WT" <<'PY' >"$WORK/ledger.out" 2>&1
import sys
hooks, repo, wt = sys.argv[1:4]
sys.path.insert(0, hooks)
import idc_ledger as L

rec = L.command_start(repo, session_id="s-build", command="build", plugin_version="test",
                      args_sha256="x", source="user")
print("opened=%s" % bool(rec))
print("primary_sees=%d" % len(L.active_commands(repo, "s-build")))
print("worktree_sees=%d" % len(L.active_commands(wt, "s-build")))
print("same_path=%s" % (L.ledger_path(repo) == L.ledger_path(wt)))
PY
RC=$?
[ "$RC" -ne 124 ] || fail "the ledger probe hung (RED)"
grep -q "opened=True" "$WORK/ledger.out" \
  || fail "fixture: the ledger refused to open the Build record: $(cat "$WORK/ledger.out")"
grep -q "worktree_sees=1" "$WORK/ledger.out" \
  || fail "#210: a claim running in the LINKED WORKTREE cannot see the Build lifecycle record the
governed checkout holds. That is what forced the e2e to hand-mint an auxiliary authorization inside
the worktree. The obligations ledger is repository-wide session state and must resolve through the
COMMON git dir, not per worktree. Got:
$(cat "$WORK/ledger.out")"
grep -q "same_path=True" "$WORK/ledger.out" \
  || fail "#210: the worktree and the governed checkout resolve DIFFERENT ledger paths, so a record
written by one is invisible to the other — there must be exactly one ledger per repository. Got:
$(cat "$WORK/ledger.out")"
# ...and the ledger really lives in the governed checkout, not duplicated into the worktree.
[ ! -e "$WT/.idc-session-state.json" ] \
  || fail "#210: a SECOND ledger appeared in the linked worktree — the fix must RELOCATE the read,
never copy state into the worktree (copies are what the e2e had to do by hand)"

# ── 2. the gitignored install receipt is visible from the worktree ───────────────────────────────
timeout "$T_S" python3 - "$PLUGIN/scripts" "$REPO" "$WT" <<'PY' >"$WORK/receipt.out" 2>&1
import os, sys
scripts, repo, wt = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_receipt_check as RC

print("primary=%s" % os.path.exists(RC.receipt_path(repo)))
print("worktree=%s" % os.path.exists(RC.receipt_path(wt)))
print("no_copy=%s" % (not os.path.exists(os.path.join(wt, RC.RECEIPT_RELPATH))))
PY
RC2=$?
[ "$RC2" -ne 124 ] || fail "the receipt probe hung (RED)"
grep -q "worktree=True" "$WORK/receipt.out" \
  || fail "#210: the install receipt is invisible from the linked worktree. It is GITIGNORED, so a
worktree never carries one — the read must fall back to the governed checkout's copy, which is what
the e2e had to supply by hand. Got:
$(cat "$WORK/receipt.out")"
grep -q "no_copy=True" "$WORK/receipt.out" \
  || fail "#210: the resolver COPIED the receipt into the worktree; it must only resolve the read"

# ── 3. the freshness gate — the claim-time consumer — agrees ─────────────────────────────────────
# This is the gate a claim actually hits, so proving the resolver in isolation is not enough.
timeout "$T_S" python3 "$PLUGIN/scripts/idc_plugin_freshness.py" \
  --plugin-root "$PLUGIN" --repo "$WT" --json >"$WORK/fresh.out" 2>&1
FRC=$?
[ "$FRC" -ne 124 ] || fail "the freshness probe hung (RED)"
grep -q '9.9.9-fixture-receipt' "$WORK/fresh.out" \
  || fail "#210: the plugin-freshness gate run from the LINKED WORKTREE did not read the governed
checkout's receipt (its plugin_version 9.9.9-fixture-receipt is absent from the verdict), so a claim there is judged
against a repo it cannot see. Got (exit $FRC):
$(cat "$WORK/fresh.out")"

# ── 4. a NON-worktree repo is completely unaffected ──────────────────────────────────────────────
# The resolver must be a no-op everywhere except a linked worktree, or it silently relocates state
# for every ordinary governed repo.
PLAIN="$WORK/plain"
git init -q -b main "$PLAIN"
timeout "$T_S" python3 - "$PLUGIN/scripts/hooks" "$PLAIN" <<'PY' >"$WORK/plain.out" 2>&1
import os, sys
hooks, repo = sys.argv[1:3]
sys.path.insert(0, hooks)
import idc_ledger as L
print("at_root=%s" % (os.path.realpath(L.ledger_path(repo))
                      == os.path.realpath(os.path.join(repo, L.LEDGER_FILENAME))))
PY
grep -q "at_root=True" "$WORK/plain.out" \
  || fail "#210: an ordinary (non-worktree) governed repo no longer resolves its ledger at its own
root — the fix must change nothing outside a linked worktree. Got: $(cat "$WORK/plain.out")"

# ── 4b. SIBLING SUBMODULES must never share a ledger ─────────────────────────────────────────────
# The obvious resolver — `dirname(--git-common-dir)` — is the checkout root ONLY for the ordinary
# `<root>/.git` layout. For a submodule git reports `super/.git/modules/<name>`, whose parent is
# `super/.git/modules`, SHARED by every sibling. That would merge two INDEPENDENT repositories'
# lifecycle records into one ledger and send their receipt lookups to a directory that is not a
# checkout at all. `git worktree list --porcelain` names the real main worktree in every layout.
SUPER="$WORK/super"
git init -q -b main "$SUPER"
git -C "$SUPER" config user.email t@t; git -C "$SUPER" config user.name t
git -C "$SUPER" commit -q --allow-empty -m init
for name in suba subb; do
  SRC="$WORK/src-$name"
  git init -q -b main "$SRC"
  git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
  mkdir -p "$SRC/docs/workflow"
  printf 'backend: filesystem\n' > "$SRC/docs/workflow/tracker-config.yaml"
  git -C "$SRC" add -A && git -C "$SRC" commit -qm init
  git -C "$SUPER" -c protocol.file.allow=always submodule add -q "$SRC" "$name" 2>/dev/null
done
git -C "$SUPER" commit -qm "add submodules" >/dev/null 2>&1
if [ -d "$SUPER/suba/.git" ] || [ -f "$SUPER/suba/.git" ]; then
  timeout "$T_S" python3 - "$PLUGIN/scripts/hooks" "$SUPER/suba" "$SUPER/subb" <<'PY' >"$WORK/sub.out" 2>&1
import os, sys
hooks, a, b = sys.argv[1:4]
sys.path.insert(0, hooks)
import idc_ledger as L
pa, pb = L.ledger_path(a), L.ledger_path(b)
print("distinct=%s" % (os.path.realpath(pa) != os.path.realpath(pb)))
print("a_in_checkout=%s" % (os.path.realpath(os.path.dirname(pa)) == os.path.realpath(a)))
print("a=%s" % pa)
print("b=%s" % pb)
PY
  grep -q "distinct=True" "$WORK/sub.out" \
    || fail "#210: two SIBLING SUBMODULES resolved to the SAME ledger. They are independent
repositories; sharing one ledger merges their lifecycle records and lets one repo's obligations gate
the other. Got:
$(cat "$WORK/sub.out")"
  grep -q "a_in_checkout=True" "$WORK/sub.out" \
    || fail "#210: a submodule's ledger resolved OUTSIDE its own checkout (git reports its common dir
as super/.git/modules/<name>, whose parent is not a checkout at all). Got:
$(cat "$WORK/sub.out")"
else
  echo "note: submodule fixture unavailable in this environment — 4b skipped" >&2
fi

# ── 5. a non-git directory still resolves, fail-soft ─────────────────────────────────────────────
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
timeout "$T_S" python3 - "$PLUGIN/scripts/hooks" "$NOGIT" <<'PY' >"$WORK/nogit.out" 2>&1
import os, sys
hooks, d = sys.argv[1:3]
sys.path.insert(0, hooks)
import idc_ledger as L
print("path=%s" % L.ledger_path(d))
PY
grep -q "path=$NOGIT/" "$WORK/nogit.out" \
  || fail "#210: a non-git directory must resolve to itself (fail-soft) — the resolver runs inside
gates that must never break on an odd layout. Got: $(cat "$WORK/nogit.out")"

echo "PASS: a claim in a linked worktree sees the governed checkout's lifecycle record and gitignored install receipt through the common git dir, with no copies, ordinary repos are unaffected, and sibling submodules keep separate ledgers"
