#!/bin/bash
# idc-assert-class: behavior
# Phase 9 (multi-wave accumulation) smoke — the failure class the pre-#103 suite structurally could
# not see (design §E.2, audit RC6: "zero tests … run two waves"). A single-wave test proves a finish
# is clean ONCE; only running ≥2 consecutive waves in ONE repo can catch debris that ACCUMULATES —
# wave 1's leftover branch/worktree resurfacing as false debris in wave 2, or a stale item-id cache
# writing a wave-1 id in wave 2.
#
# PART A — debris non-accumulation (real git, filesystem backend): two consecutive build waves, each
#   issue driven implementer-branch → server-side merge → `idc_git_finish.py` tail → `git fetch
#   --prune`. After EACH wave the janitor is scanned; the load-bearing assertion is ZERO debris GROWTH
#   between waves (wave-2 finding count ≤ wave-1's, and both are 0). Red-when-broken by construction:
#   a leaked worktree injected between the waves makes wave-2's count exceed wave-1's → the zero-growth
#   assertion fails (demonstrated in the phase's own negative control below).
# PART B — item-id cache freshness across waves (github idmap): `idc_gh_board.py --emit-idmap` is
#   regenerated per wave against a GROWING board; assert each wave re-reads the board and its map
#   reflects that wave's board (wave 2 sees a new issue wave 1 did not). That fresh-per-wave
#   regeneration is the real "no stale-id write" guarantee — a write always resolves against the
#   current board, never a carried-over wave-1 map. (The resolve-path miss/blank-id guards are
#   exhaustively covered by phase4-itemid-cache.)
#
# Usage: bash tests/smoke/phase9-multiwave-accumulation.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
FIN="$PLUGIN/scripts/idc_git_finish.py"
JAN="$PLUGIN/scripts/idc_git_janitor.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
BOARD="$PLUGIN/scripts/idc_gh_board.py"
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "----- detail -----"; echo "$2"; }; exit 1; }
gitc() { git -C "$REPO" "$@"; }

for f in "$FIN" "$JAN" "$TRK" "$BOARD"; do [ -f "$f" ] || fail "helper not found: $f"; done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"

# ===================================================================================================
# PART A — debris non-accumulation across two real build waves (filesystem backend).
# ===================================================================================================

# gh stub: pr view + a faithful server-side merge of $BRANCH into origin/main, then delete $BRANCH.
# State is keyed per PR so a multi-issue wave never cross-contaminates.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys, tempfile
args = sys.argv[1:]
BRANCH = os.environ["BRANCH"]; ORIGIN = os.environ["ORIGIN"]
pr = next((a for a in args if a.isdigit()), "0")
STATE = os.path.join(os.environ["WORK"], "gh-pr-merged-" + pr)
if args[:2] == ["pr", "view"]:
    j = args[args.index("--json") + 1] if "--json" in args else ""
    print(BRANCH if j == "headRefName" else ("MERGED" if os.path.exists(STATE) else "OPEN"))
    sys.exit(0)
if args[:2] == ["pr", "merge"]:
    if "--delete-branch" not in args:
        sys.stderr.write("gh stub: pr merge missing --delete-branch\n"); sys.exit(1)
    tmp = tempfile.mkdtemp()
    def g(*a): subprocess.run(list(a), check=True, capture_output=True)
    g("git", "clone", "-q", ORIGIN, tmp)
    g("git", "-C", tmp, "config", "user.email", "bot@example.com")
    g("git", "-C", tmp, "config", "user.name", "merge-bot")
    g("git", "-C", tmp, "merge", "--no-ff", "-m", "Merge PR #" + pr, "origin/" + BRANCH)
    g("git", "-C", tmp, "push", "-q", "origin", "HEAD:main")
    g("git", "-C", ORIGIN, "branch", "-D", BRANCH)
    open(STATE, "w").close()
    sys.exit(0)
sys.stderr.write("gh stub: unhandled " + repr(args) + "\n"); sys.exit(99)
STUB
chmod +x "$WORK/bin/gh"

git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
gitc config user.email t@example.com; gitc config user.name tester
echo hello > "$REPO/README.md"; gitc add -A; gitc commit -qm init
BASE="$(gitc symbolic-ref --short HEAD)"
gitc push -q origin "HEAD:$BASE"
mkdir -p "$REPO/docs/workflow"; printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
TRACKER="$REPO/TRACKER.md"
python3 "$TRK" --tracker "$TRACKER" init >/dev/null || fail "tracker init failed"

# janitor finding count (JSON counts.total) — the debris measure.
jcount() { python3 "$JAN" --repo "$REPO" --tracker "$TRACKER" --json \
             | python3 -c 'import json,sys;print(json.load(sys.stdin)["counts"]["total"])'; }

# One issue's full lifecycle: create buildable → claim → real worktree+commit+push → finish tail → prune.
run_issue() {  # $1 = issue/PR number
  local n="$1" br="build-$1" wt="$REPO/.claude/worktrees/build-$1"
  python3 "$TRK" --tracker "$TRACKER" create --title "feature $n" >/dev/null
  python3 "$TRK" --tracker "$TRACKER" claim --num "$n" --agent tester >/dev/null || fail "claim #$n failed"
  gitc worktree add -q -b "$br" "$wt" "$BASE" || fail "worktree add $br failed"
  printf 'work %s\n' "$n" > "$wt/feature-$n.txt"
  git -C "$wt" add -A; git -C "$wt" commit -qm "implement $n"
  git -C "$wt" push -q origin "$br" || fail "push $br failed"
  # Receipt gate: a clean PASS verdict owning PR/issue #n (no nits, no merge_conditions) so the tail
  # runs its git mechanics — this phase exercises debris accumulation, not the gate itself.
  printf '{"verdict":"PASS","pr":%s,"issue":%s,"findings":[]}\n' "$n" "$n" > "$REPO/verdict-$n.json"
  local out; out="$( cd "$REPO" && env PATH="$WORK/bin:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" BRANCH="$br" \
    python3 "$FIN" --pr "$n" --issue "$n" --worktree "$wt" --repo "$REPO" --tracker "$TRACKER" \
      --verdict "$REPO/verdict-$n.json" 2>&1 )"
  printf '%s\n' "$out" | grep -qx 'finish: ok' || fail "finish of #$n did not report ok" "$out"
  gitc fetch -q --prune origin
}

# ---- WAVE 1: issues #1, #2 ----
run_issue 1; run_issue 2
w1="$(jcount)"
[ "$w1" -eq 0 ] || fail "after wave 1 the janitor must report ZERO debris (got $w1)" \
  "$(python3 "$JAN" --repo "$REPO" --tracker "$TRACKER")"

# ---- WAVE 2: issues #3, #4 (same repo, board + git state carried over) ----
run_issue 3; run_issue 4
w2="$(jcount)"
[ "$w2" -eq 0 ] || fail "after wave 2 the janitor must STILL report ZERO debris (got $w2)" \
  "$(python3 "$JAN" --repo "$REPO" --tracker "$TRACKER")"

# THE load-bearing multi-wave assertion: debris did not GROW between waves.
[ "$w2" -le "$w1" ] || fail "debris GREW across waves ($w1 → $w2) — wave 1 artifacts leaked into wave 2"

# All four issues closed, no build branches/worktrees anywhere (the accumulated end-state is clean).
for n in 1 2 3 4; do
  [ "$(python3 "$TRK" --tracker "$TRACKER" show --num "$n" --field Status)" = "Done" ] \
    || fail "issue #$n should be Done after its wave"
done
[ -z "$(gitc branch --list 'build-*')" ] || fail "a build-* local branch survived across the waves"
[ "$(gitc worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] \
  || fail "a linked worktree survived across the waves (only the main worktree should remain)"

# ---- NEGATIVE CONTROL (red-when-broken by construction): a leaked worktree between the waves makes
#      the debris count exceed wave 1's. Injected then removed in place, so the zero end-state above is
#      restored before Part B. ----
LEAK="$WORK/leak-wt"
gitc worktree add -q "$LEAK" -b "worktree-build-leak" "$BASE"     # unmerged IDC worktree → RISKY debris
leaked="$(jcount)"
[ "$leaked" -gt "$w1" ] \
  || fail "negative control broken: a leaked worktree must raise the debris count above wave 1's ($w1 → $leaked)"
gitc worktree remove --force "$LEAK" >/dev/null 2>&1; gitc branch -D worktree-build-leak >/dev/null 2>&1
[ "$(jcount)" -eq 0 ] || fail "removing the leaked worktree must restore ZERO debris"

# ===================================================================================================
# PART B — item-id cache freshness across waves (github idmap regenerated per wave). Hermetic: a PATH
# `gh` stub serves the board; the real jq is never reached (the stub short-circuits every `gh` call).
# ===================================================================================================
export FIX="$WORK"

# gh stub (written straight onto the emit PATH dir): `project view` → node id; `api graphql` → the
# CURRENT board fixture (rewritten between waves), logged; `api rate_limit` → benign (the #99 preflight
# must not block this test).
mkdir -p "$WORK/gh-board-bin"
cat > "$WORK/gh-board-bin/gh" <<'STUB'
#!/bin/bash
sub="$1"
if [ "$sub" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$sub" = "api" ] && [ "$2" = "graphql" ]; then
  echo "graphql" >> "$FIX/board.log"; cat "$FIX/board-current.json"; exit 0
fi
if [ "$sub" = "api" ]; then for a in "$@"; do case "$a" in rate_limit) echo '{}'; exit 0 ;; esac; done; fi
echo "gh-board stub: unhandled $*" >&2; exit 99
STUB
chmod +x "$WORK/gh-board-bin/gh"

# Build a single-page board fixture from a list of issue numbers.
write_board() {  # $@ = issue numbers
  python3 - "$WORK/board-current.json" "$@" <<'PY'
import json, sys
out = sys.argv[1]; nums = [int(n) for n in sys.argv[2:]]
def node(n): return {"id": f"PVTI_{n}", "fieldValues": {"nodes": []},
                     "content": {"__typename": "Issue", "number": n, "title": f"issue {n}"}}
page = {"data": {"node": {"items": {
    "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [node(n) for n in nums]}}}}
open(out, "w").write(json.dumps(page))
PY
}
emit() {  # emit-idmap against the current board fixture, using the board gh stub
  PATH="$WORK/gh-board-bin:$PATH" python3 "$BOARD" --owner tester --project 7 --repo "$WORK" --emit-idmap
}

# WAVE 1 board: {#101, #201}. Regenerate the cache from a fresh board read.
write_board 101 201
: > "$WORK/board.log"
MAP1="$(emit)" || fail "wave-1 --emit-idmap failed"
[ "$(grep -c graphql "$WORK/board.log")" -ge 1 ] || fail "wave-1 emit-idmap must do a real board read (fresh cache)"
id101_w1="$(printf '%s\n' "$MAP1" | awk -F'\t' '$1==101{print $2}')"
[ "$id101_w1" = "PVTI_101" ] || fail "wave-1 map must resolve #101 → PVTI_101 (got '$id101_w1')"
printf '%s\n' "$MAP1" | grep -qE '^301[[:space:]]' \
  && fail "wave-1 map must NOT yet contain #301 (it does not exist in wave 1)"

# WAVE 2 board GROWS: {#101, #201, #301}. The orchestrator regenerates the cache → it reflects wave 2.
write_board 101 201 301
: > "$WORK/board.log"
MAP2="$(emit)" || fail "wave-2 --emit-idmap failed"
[ "$(grep -c graphql "$WORK/board.log")" -ge 1 ] || fail "wave-2 emit-idmap must do a fresh board read (not reuse wave-1's cache)"
printf '%s\n' "$MAP2" | grep -qE '^301[[:space:]]' \
  || fail "wave-2 map must contain the new #301 (fresh cache per wave — the multi-wave invariant)"

# No cross-wave id-equality assertion here: the hermetic fixture mints each id as PVTI_<number>, so
# "#101's id is identical in both waves" is guaranteed by the fixture, not by the code under test — a
# vacuous (always-green) check. The load-bearing "no stale-id write" guarantee is the fresh-read-per-
# wave property proven above (each emit re-reads the board; wave 2's map reflects the grown board), so a
# write always resolves against the current board. The resolve-path miss/blank-id guards are covered by
# phase4-itemid-cache.

echo "PART A: two consecutive real-git build waves finish clean with ZERO debris growth ($w1 → $w2); a leaked worktree between waves raises the count (negative control) and its removal restores zero."
echo "PART B: --emit-idmap regenerates a FRESH board-reflecting map per wave (each emit re-reads; #301 appears only in wave 2's map) — the cache reflects the current board every wave, so no write resolves against a stale wave-1 map."
echo "PASS: multi-wave accumulation — zero debris growth across waves + fresh-per-wave item-id cache regeneration"
