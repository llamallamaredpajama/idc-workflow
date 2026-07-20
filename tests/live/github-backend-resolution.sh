#!/bin/bash
# idc-assert-class: behavior
# LIVE GitHub-backend coverage — the owner / project / project-item resolution branches, exercised
# against a REAL board with a REAL `gh`. Read-only: it creates, mutates and deletes nothing.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# THIS IS OPT-IN, AND IT IS *NOT* PART OF `tests/smoke/run-all.sh`.
#
# WHY IT LIVES OUTSIDE THE SMOKE SUITE. CI runs `run-all.sh` on a clean ubuntu runner
# (`.github/workflows/ci.yml`) with no `gh` credential and no sandbox repos. A live test in there
# would turn the build red for everyone, permanently, for a reason unrelated to their change.
#
# THE ROT RISK, STATED PLAINLY: **nothing runs this automatically.** It can therefore decay silently
# — a refactor that breaks one of these resolution branches will not be caught here until a human
# remembers to run it. That is a real, accepted cost, not an oversight. The alternative is putting a
# GitHub credential into CI, which is a separate operator decision that has deliberately NOT been
# taken. Run this by hand whenever `scripts/idc_gh_board.py`, `scripts/idc_pause_check.py`'s github
# branch, or the tracker config contract changes.
#
# WHY IT EXISTS AT ALL. The three GitHub phases inside the smoke suite
# (`phase4-tracker-github-recipe.sh`, `phase4-github-pagination.sh`, `phase1-recirc-sweep-github.sh`)
# put a `gh` STUB on PATH. That is the right trade for CI — they prove the plugin builds the right
# command lines — but a stub cannot prove the plugin can read a real board: not the OWNER/REPO shape
# `gh repo view` actually returns, not that a project NUMBER resolves to the `PVT_…` node id the
# mutations require (a number where a node id belongs fails only against the live API), and not that
# a project ITEM carries the fields every board read assumes. Those three branches were covered by
# nothing executable. This closes exactly that gap and nothing more.
#
# BUDGET. Roughly 5–8 GraphQL/REST calls total, all reads. This is deliberately NOT a lifecycle
# drain: a full github drain costs about one API hour and proves something else.
#
# SANDBOXES ONLY. It refuses to run anywhere but `/Users/jeremy/dev/sandbox/ke-idc-test-repo-*`,
# which are disposable and git-tracked. It must never point at a live or production repo.
#
# Usage:
#   bash tests/live/github-backend-resolution.sh                 # default sandbox (install)
#   IDC_LIVE_SANDBOX=/Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun \
#     bash tests/live/github-backend-resolution.sh
#   exit 0 = every branch resolved against the real board.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# Teammate/agent panes start with a reduced PATH, and the failure presents as "gh is not installed"
# — which is false, and has cost this project a wrong conclusion before. Fix it up front.
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"

PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="${IDC_LIVE_SANDBOX:-/Users/jeremy/dev/sandbox/ke-idc-test-repo-install}"

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
skip() { printf 'SKIP: %s\n' "$1"; exit 0; }

echo "== live github-backend resolution — READ-ONLY, sandbox only"

# ── guards, in order of how badly getting them wrong would end ───────────────────────────────────
case "$SANDBOX" in
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-*) ;;
  *) fail "REFUSING to run against $SANDBOX — this test may only touch a disposable sandbox repo
       (/Users/jeremy/dev/sandbox/ke-idc-test-repo-*), never a live or production repo" ;;
esac
[ -d "$SANDBOX" ] || skip "sandbox $SANDBOX is not present on this machine"
command -v gh >/dev/null 2>&1 || skip "gh is not on PATH — this test needs the real CLI"
gh auth status >/dev/null 2>&1 || skip "gh is not authenticated — run \`gh auth login\` first"
CFG="$SANDBOX/docs/workflow/tracker-config.yaml"
[ -f "$CFG" ] || skip "$SANDBOX has no tracker config — nothing to resolve"
grep -qE '^\s*backend:\s*github' "$CFG" || skip "$SANDBOX is not on the github backend"

echo "   sandbox: $SANDBOX"
echo "   plugin:  $PLUGIN"

python3 - "$PLUGIN" "$SANDBOX" <<'PY' || exit 1
import os, re, sys

plugin, sandbox = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_gh_board as GH
import idc_pause_check as PC

failures = []
def check(label, fn):
    try:
        value = fn()
    except Exception as exc:                                    # noqa: BLE001 — report, keep going
        failures.append(f"{label}: raised {type(exc).__name__}: {exc}")
        return None
    print(f"   ok  {label}: {value}")
    return value

print("-- 1/3 OWNER resolution (`gh repo view` → OWNER/REPO)")
# The shape matters, not the value: every lifecycle close is scoped by this string, and a stub can
# only ever return what the stub was told to return.
nwo = check("_current_repository", lambda: GH._current_repository(sandbox))
if nwo is not None and not re.match(r"^[^/\s]+/[^/\s]+$", nwo):
    failures.append(f"_current_repository returned {nwo!r}, which is not OWNER/REPO")

# ...and the pause checker's own github branch must resolve the SAME owner. It has its own resolver,
# and a drift between the two would scope a quiescence check to a different account than the closes.
owner = check("idc_pause_check._github_owner", lambda: PC._github_owner(sandbox))
if nwo and owner and nwo.split("/", 1)[0] != owner:
    failures.append(f"owner drift: board reader says {nwo.split('/', 1)[0]!r}, "
                    f"pause checker says {owner!r}")

print("-- 2/3 PROJECT resolution (project NUMBER → `PVT_…` node id)")
# The failure this covers is invisible to a stub and to the filesystem backend: every field mutation
# takes the project's NODE ID, and passing the human-facing number instead fails only against the
# live API. A resolver that silently returns the number would look fine everywhere but production.
backend, project_number = PC._repo_backend(sandbox)
if backend != "github":
    failures.append(f"the config reader reports backend {backend!r} for a github sandbox")
print(f"   ..  configured project number: {project_number}")
node = check("_resolve_project_node_id",
             lambda: GH._resolve_project_node_id(owner, int(project_number), sandbox))
if node is not None and not str(node).startswith("PVT_"):
    failures.append(f"_resolve_project_node_id returned {node!r} — a field mutation needs the "
                    f"`PVT_…` node id, and the project NUMBER in its place fails only live")

print("-- 3/3 PROJECT-ITEM resolution (board read → items with the assumed fields)")
items = check("fetch_items", lambda: GH.fetch_items(owner, int(project_number), sandbox))
if items is not None:
    if not isinstance(items, list):
        failures.append(f"fetch_items returned {type(items).__name__}, not a list")
    elif not items:
        # Not a failure of the CODE, but it means this run proved nothing about item shape — say so
        # rather than exiting 0 on an empty board and calling the branch covered.
        failures.append("the sandbox board is EMPTY, so the project-item branch was not exercised — "
                        "seed the board (or point IDC_LIVE_SANDBOX at one with items) and re-run")
    else:
        print(f"   ..  {len(items)} item(s) on the board")
        first = items[0]
        for field in ("id", "content"):
            if field not in first:
                failures.append(f"a board item is missing {field!r}, which every board read assumes: "
                                f"{sorted(first)}")
        item_id = first.get("id")
        if item_id:
            one = check("fetch_item (single project item)", lambda: GH.fetch_item(item_id, sandbox))
            if isinstance(one, dict) and one.get("id") not in (None, item_id):
                failures.append(f"fetch_item returned a different item: asked {item_id!r}, "
                                f"got {one.get('id')!r}")

print()
print("COVERED:   owner resolution (both resolvers, cross-checked) · project number → PVT_ node id ·"
      " project-item board read + single-item read")
print("NOT COVERED: any WRITE path (create/update/close), pagination beyond the first page, the "
      "recirculation sweep, and the full lifecycle drain — a github drain costs roughly one API "
      "hour and is a different test.")
if failures:
    print()
    for f in failures:
        print(f"FAIL: {f}")
    sys.exit(1)
PY
rc=$?
[ "$rc" = 0 ] || fail "one or more github-backend resolution branches did not hold (see above)"
echo "github-backend-resolution: OK"
