#!/bin/bash
# idc-assert-class: behavior
# teammate-idle-synth.sh — governance scenario: the DRAIN-LOOP phantom-idle-teammate synthesis
# (v4 Phase 3 Stage E4, plan §3.2 drop H — "Phantom-idle teammate (impl-235)").
#
# The invariant (plan §3.2 drop H): an implementer teammate can go IDLE without reporting — its board
# item sits Stage=Buildable ∧ Status=In Progress (claimed) but is never advanced. The drain LOOP is
# blind to this (it counts only Todo / merged-Done), so the wave closes `drain: complete` and autorun
# STOPS with the item STRANDED. scripts/idc_teammate_idle_synth.py closes that hole: run from the drain
# loop (top of each autorun pass, beside the E1 reconcile), for every Buildable ∧ In Progress item it
# SYNTHESIZES the teammate's real state from LOCAL git evidence and stamps ONE idempotent breadcrumb
# comment per (item, class) —
#   * synthesized-complete — a linked branch's tip is an ANCESTOR of base (work landed, board never
#     advanced): print `teammate-idle: <n> synthesized-complete branch <b>` so the ORCHESTRATOR
#     finishes via the sanctioned finisher (the synth NEVER closes/moves the item);
#   * in-flight-abandoned — a linked branch AHEAD of base but unmerged: a resume checkpoint
#     {branch, ahead, sha} so a resumed implementer picks it up;
#   * stalled-no-evidence — NO linked branch/commits: "reclaim or re-dispatch";
#   * the `idle_synth:<item>` ledger taint is the CLASS-KEYED idempotence latch — one breadcrumb per
#     (item, class); a CHANGED class re-stamps (new evidence); an item leaving In-Progress CLEARS it;
#   * an UNREADABLE board (still_open==None) FAILS SAFE: clears nothing, stamps nothing, reports
#     `teammate-idle: unknown` (never a false "none") — a stranded item is the loss.
# Branch discovery reuses Stage D's `_BRANCH_NUM_RE` (the item number in the branch name). It is a
# fail-SOFT drain-loop ACTION step (never crashes the loop) and is repo-gated.
#
# Red-when-broken (MANDATORY, reviewed) — each neuter is IN idc_teammate_idle_synth.py:
#   * neuter the SYNTHESIS scan (make `_read_in_progress` return `[], commenter` — an empty
#     In-Progress set) ⇒ cases 1-3's "every In-Progress item is synthesized (line + comment + taint)"
#     asserts go RED (nothing is stamped or printed);
#   * neuter the CLASS-KEYED LATCH (force `to_stamp = results` — stamp regardless of the stored class)
#     ⇒ case 2's "no duplicate comment on an idempotent re-run" assert goes RED (the count climbs to 2);
#   * neuter the CLEAR branch (force `clear_candidates = []`) ⇒ case 5's "an item that left
#     In-Progress has its taint CLEARED" assert goes RED;
#   * neuter the READ-FAILURE fail-safe (treat `in_progress is None` as `[]`) ⇒ case 7's "an
#     unreadable board reports unknown + preserves the taint" assert goes RED.
#
# Filesystem-backed + a real `git init` repo (hermetic, no gh). TRACKER.md + the ledger are gitignored
# so branch switches never reset them. Auto-discovered by the governance lane (phase-governance.sh);
# runnable standalone under BOTH python3 and `uv run --with pyyaml` (a clean no-pyyaml venv python).
#
# Usage: bash tests/smoke/governance/teammate-idle-synth.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

SYN="$GOV_PLUGIN/scripts/idc_teammate_idle_synth.py"
LEDGER="$GOV_PLUGIN/scripts/hooks/idc_ledger.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$SYN" ] || fail "idc_teammate_idle_synth.py not found at $SYN (not implemented yet)"
[ -f "$TRK" ] || fail "filesystem tracker helper not found at $TRK"
command -v git >/dev/null 2>&1 || fail "git not on PATH (this scenario needs a real git repo for branch evidence)"

# ── a governed filesystem repo WITH a real git base branch (main) → echoes the REPO dir ────────────
# TRACKER.md + the ledger are gitignored so a `git checkout` across branches never resets them.
new_repo() {
  local d; d="$(mktemp -d)" || return 1
  git -C "$d" init -q >/dev/null 2>&1 || return 1
  git -C "$d" config user.email idc@test.local; git -C "$d" config user.name idc-test
  mkdir -p "$d/docs/workflow"
  printf 'backend: filesystem\n' > "$d/docs/workflow/tracker-config.yaml"   # marks REPO IDC-governed
  python3 "$TRK" --tracker "$d/TRACKER.md" init >/dev/null || return 1
  printf 'TRACKER.md\n.idc-session-state.json*\ndocs/\n' > "$d/.gitignore"
  printf 'base\n' > "$d/README"
  git -C "$d" add .gitignore README >/dev/null 2>&1 || return 1
  git -C "$d" commit -qm base >/dev/null 2>&1 || return 1
  git -C "$d" branch -M main >/dev/null 2>&1 || return 1
  printf '%s' "$d"
}
seed()  { python3 "$TRK" --tracker "$1/TRACKER.md" create --title "$4" --stage "$2" --status "$3"; }
move()  { python3 "$TRK" --tracker "$1/TRACKER.md" move --num "$2" --status "$3" >/dev/null; }
comments() { python3 "$TRK" --tracker "$1/TRACKER.md" show --num "$2" --comments; }
led()      { python3 "$LEDGER" --cwd "$1" "${@:2}"; }
has_bc()   { comments "$1" "$2" | grep -q 'idc-idle-synth'; }
bc_count() { comments "$1" "$2" | grep -c 'idc-idle-synth'; }
has_taint() { led "$1" pending --session "$2" | grep -qx "idle_synth:$3"; }

# a work branch <n>-work committing ONE tracked file (never TRACKER.md); optionally merge it to main.
# The commit carries Stage D's trusted `Issue: #<n>` trailer so an ancestry-landed tip is provably
# THIS item's work (reviewer P1a — ancestry alone is not enough to classify synthesized-complete).
mk_branch() {  # mk_branch <repo> <n> <merge:yes|no>
  local d="$1" n="$2" mrg="$3"
  git -C "$d" checkout -q -b "${n}-work" main || return 1
  printf 'work for %s\n' "$n" > "$d/work-${n}.txt"
  git -C "$d" add "work-${n}.txt" >/dev/null 2>&1
  git -C "$d" commit -qm "work for #${n}" -m "Issue: #${n}" >/dev/null 2>&1 || return 1
  git -C "$d" checkout -q main || return 1
  if [ "$mrg" = "yes" ]; then git -C "$d" merge -q --no-ff "${n}-work" -m "merge #${n}" || return 1; fi
}

# run_synth <repo> <session> -> stdout in $OUT, exit in $RC, stderr in $ERRFILE
ERRFILE=""
run_synth() { OUT="$(python3 "$SYN" --repo "$1" --session-id "$2" 2>"$ERRFILE")"; RC=$?; }
val() { printf '%s\n' "$OUT" | grep -E "^$1:" | head -1 | sed -E "s/^$1:[[:space:]]*//"; }

WORK="$(mktemp -d)"; ERRFILE="$WORK/err.log"; trap 'rm -rf "$WORK" "${REPOS[@]:-}"' EXIT
REPOS=()

# ══ Cases 1-3 — SYNTHESIZE every phantom-idle In-Progress item from git evidence ════════════════════
# Three Buildable ∧ In Progress items whose teammates went idle: #1's branch MERGED (complete), #2's
# branch AHEAD + unmerged (in-flight), #3 has NO branch (no-evidence). The synth must print the class
# line + stamp ONE class-appropriate breadcrumb + set an idle_synth taint on EACH.
# Red-when-broken: neuter `_read_in_progress` to return an empty set ⇒ none printed/stamped ⇒ RED.
R1="$(new_repo)" || fail "new_repo 1 failed"; REPOS+=("$R1")
I1="$(seed "$R1" Buildable 'In Progress' 'impl: work landed, board never advanced')" || fail "seed I1"
I2="$(seed "$R1" Buildable 'In Progress' 'impl: went idle mid-work')"                 || fail "seed I2"
I3="$(seed "$R1" Buildable 'In Progress' 'impl: claimed, no discoverable work')"      || fail "seed I3"
mk_branch "$R1" "$I1" yes || fail "(1) could not build+merge #$I1's branch"
mk_branch "$R1" "$I2" no  || fail "(2) could not build #$I2's unmerged branch"
# #I3 intentionally gets no branch.
SID1="sid1-$$-$(basename "$WORK")"
run_synth "$R1" "$SID1"
[ "$RC" -eq 0 ] || fail "(1) synth exit $RC (a fail-soft drain-loop step must exit 0; err: $(cat "$ERRFILE"))"
# #I1 — synthesized-complete
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $I1 synthesized-complete branch ${I1}-work" \
  || fail "(1) #$I1 must print 'synthesized-complete branch ${I1}-work' (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $I1 ")) [neuter the scan ⇒ RED]"
has_bc "$R1" "$I1"    || fail "(1) #$I1 was NOT stamped a breadcrumb [neuter the scan ⇒ RED]"
has_taint "$R1" "$SID1" "$I1" || fail "(1) #$I1 has no idle_synth taint [neuter the scan ⇒ RED]"
comments "$R1" "$I1" | grep -qi 'SYNTHESIZED-COMPLETE' || fail "(1) #$I1 breadcrumb must name the synthesized-complete class"
comments "$R1" "$I1" | grep -qiE 'trailer|declares this item' || fail "(1) #$I1 breadcrumb must cite the item-declaring-trailer landing evidence (P1a)"
comments "$R1" "$I1" | grep -qi 'finisher'             || fail "(1) #$I1 breadcrumb must point at the sanctioned finisher (orchestrator owns the transition)"
comments "$R1" "$I1" | grep -qiE 'closes? the item|never closes' || fail "(1) #$I1 breadcrumb must state the synth does not close the item"
# #I2 — in-flight-abandoned
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $I2 in-flight branch ${I2}-work ahead 1" \
  || fail "(2) #$I2 must print 'in-flight branch ${I2}-work ahead 1' (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $I2 ")) [neuter the scan ⇒ RED]"
has_bc "$R1" "$I2"    || fail "(2) #$I2 was NOT stamped a breadcrumb [neuter the scan ⇒ RED]"
has_taint "$R1" "$SID1" "$I2" || fail "(2) #$I2 has no idle_synth taint"
comments "$R1" "$I2" | grep -qiE 'IN-FLIGHT|RESUME' || fail "(2) #$I2 breadcrumb must name the in-flight/resume class"
comments "$R1" "$I2" | grep -qi 'ahead'             || fail "(2) #$I2 breadcrumb must record the ahead-count"
# #I3 — stalled-no-evidence
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $I3 no-evidence" \
  || fail "(3) #$I3 must print 'no-evidence' (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $I3 ")) [neuter the scan ⇒ RED]"
has_bc "$R1" "$I3"    || fail "(3) #$I3 was NOT stamped a breadcrumb [neuter the scan ⇒ RED]"
has_taint "$R1" "$SID1" "$I3" || fail "(3) #$I3 has no idle_synth taint"
comments "$R1" "$I3" | grep -qiE 'NO EVIDENCE|STALLED' || fail "(3) #$I3 breadcrumb must name the stalled/no-evidence class"
comments "$R1" "$I3" | grep -qiE 'reclaim|re-dispatch' || fail "(3) #$I3 breadcrumb must name the reclaim/re-dispatch remediation"
echo "  ok (1-3) synthesize: complete (merged) / in-flight (ahead) / no-evidence (no branch) — each printed + one breadcrumb + one taint"

# ══ Case 3b — SQUASH-MERGE detection (codex P1): landed-but-not-an-ancestor ⇒ synthesized-complete ══
# IDC's default finisher SQUASH-merges, so landed work is NOT an ancestor of base (the squash is a NEW
# commit with a different sha). An ancestry-only test would misread this as `in-flight` and autorun
# would RE-DISPATCH already-shipped work. The synth must fall through to `git cherry <base> <tip>`:
# every ahead-commit is PATCH-EQUIVALENT to a commit already in base ⇒ synthesized-complete. The
# breadcrumb must also point at the CLOSE-ONLY finisher (the plain finisher hard-fails on a merged PR).
# Red-when-broken: neuter the cherry patch-equivalence branch in _classify_branch (fall straight to the
# ahead>0 in-flight path) ⇒ this item is misclassified `in-flight` ⇒ these asserts go RED.
RSQ="$(new_repo)" || fail "new_repo 3b failed"; REPOS+=("$RSQ")
S1="$(seed "$RSQ" Buildable 'In Progress' 'impl: squash-merged, board never advanced')" || fail "seed S1"
git -C "$RSQ" checkout -q -b "${S1}-work" main || fail "(3b) branch"
printf 'squash work for %s\n' "$S1" > "$RSQ/sq-${S1}.txt"
git -C "$RSQ" add "sq-${S1}.txt" >/dev/null 2>&1; git -C "$RSQ" commit -qm "sq work item: #${S1}" >/dev/null 2>&1 || fail "(3b) commit"
git -C "$RSQ" checkout -q main || fail "(3b) checkout main"
git -C "$RSQ" merge --squash "${S1}-work" >/dev/null 2>&1 || fail "(3b) squash stage"
git -C "$RSQ" commit -qm "squash-merge #${S1} (new sha, patch-equivalent)" >/dev/null 2>&1 || fail "(3b) squash commit"
# Precondition: the branch tip is NOT an ancestor of main (proves this is the squash shape, not ff/merge).
git -C "$RSQ" merge-base --is-ancestor "${S1}-work" main \
  && fail "(3b) precondition: a squash-merge must leave ${S1}-work NON-ancestor of main (else it's not the squash shape)"
SIDSQ="sidsq-$$-$(basename "$WORK")"
run_synth "$RSQ" "$SIDSQ"
[ "$RC" -eq 0 ] || fail "(3b) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $S1 synthesized-complete branch ${S1}-work" \
  || fail "(3b) a SQUASH-merged item #$S1 must classify synthesized-complete, not in-flight (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $S1 ")) [neuter the cherry check ⇒ RED as in-flight]"
comments "$RSQ" "$S1" | grep -qi 'patch-equivalent' \
  || fail "(3b) #$S1 breadcrumb must cite the squash/patch-equivalent evidence [neuter the cherry check ⇒ RED]"
comments "$RSQ" "$S1" | grep -qi -- '--close-only' \
  || fail "(3b) #$S1 breadcrumb must point at the CLOSE-ONLY finisher (the plain finisher hard-fails on a merged PR)"
comments "$RSQ" "$S1" | grep -qiE 'hard-fail|already merged' \
  || fail "(3b) #$S1 breadcrumb must explain WHY close-only (the merge already happened)"
echo "  ok (3b) squash-merge detection: patch-equivalent ahead-commits ⇒ synthesized-complete + close-only remediation (not a false in-flight re-dispatch)"

# ══ Case 3c — ZERO-COMMIT branch at base ⇒ NOT synthesized-complete (reviewer MAJOR-1) ══════════════
# A commit is its OWN ancestor, so a branch created at claim time and NEVER committed (tip == base) is
# trivially an ancestor of base — an ancestry-only test would call it synthesized-complete and route a
# board-advancing FINISH on an EMPTY item (the dangerous direction). The zero-commit guard (tip must
# DIFFER from base) must fall it through to no-evidence (a created-but-idle claim, nothing landed).
# Red-when-broken: drop the `tip != base_sha` guard ⇒ this item flips to synthesized-complete ⇒ RED.
RZ="$(new_repo)" || fail "new_repo 3c failed"; REPOS+=("$RZ")
Z1="$(seed "$RZ" Buildable 'In Progress' 'impl: claimed, branch created but never committed')" || fail "seed Z1"
git -C "$RZ" checkout -q -b "${Z1}-work" main || fail "(3c) branch"   # NO commit — tip == main
git -C "$RZ" checkout -q main || fail "(3c) checkout main"
# Precondition: the zero-commit branch tip EQUALS main (proves the trivial-ancestor trap).
[ "$(git -C "$RZ" rev-parse "${Z1}-work")" = "$(git -C "$RZ" rev-parse main)" ] \
  || fail "(3c) precondition: a zero-commit branch must have tip == main"
SIDZ="sidz-$$-$(basename "$WORK")"
run_synth "$RZ" "$SIDZ"
[ "$RC" -eq 0 ] || fail "(3c) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $Z1 synthesized-complete" \
  && fail "(3c) a ZERO-COMMIT branch must NOT be synthesized-complete (would finish an empty item) [drop the tip!=base guard ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $Z1 no-evidence" \
  || fail "(3c) a zero-commit branch (nothing landed) must classify no-evidence (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $Z1 ")) [drop the tip!=base guard ⇒ RED]"
echo "  ok (3c) zero-commit branch at base ⇒ no-evidence, never a false synthesized-complete (no empty-item finish)"

# ══ Case 3d — STALE empty branch + base ADVANCED ⇒ NOT complete (reviewer P1a — the deeper trap) ════
# The zero-commit guard (tip == base) is DEFEATED once base advances: a stale empty claim branch's tip
# is STILL an ancestor of base AND now DIFFERS from base HEAD — ancestry cannot tell it from ff/merge-
# landed work. Classifying it complete would finish an EMPTY item (the forbidden direction). So the
# ancestry fast-path requires POSITIVE evidence (the tip commit's Issue/Item trailer names this item);
# an already-in-base tip WITHOUT that declaration is AMBIGUOUS ⇒ no-evidence + check-history breadcrumb.
# Red-when-broken: drop the trailer requirement (ancestor + tip!=base ⇒ complete) ⇒ this flips to
# synthesized-complete ⇒ RED.
RADV="$(new_repo)" || fail "new_repo 3d failed"; REPOS+=("$RADV")
D1="$(seed "$RADV" Buildable 'In Progress' 'impl: empty claim branch, base advanced past it')" || fail "seed D1"
git -C "$RADV" checkout -q -b "${D1}-work" main || fail "(3d) branch"   # ZERO commits, tip == main
git -C "$RADV" checkout -q main || fail "(3d) checkout main"
printf 'unrelated advance\n' > "$RADV/unrelated.txt"    # base moves forward on UNRELATED work (no trailer for D1)
git -C "$RADV" add unrelated.txt >/dev/null 2>&1; git -C "$RADV" commit -qm "unrelated base advance" >/dev/null 2>&1 || fail "(3d) advance"
git -C "$RADV" merge-base --is-ancestor "${D1}-work" main \
  || fail "(3d) precondition: a stale empty branch tip must remain an ancestor of the advanced base"
[ "$(git -C "$RADV" rev-parse "${D1}-work")" != "$(git -C "$RADV" rev-parse main)" ] \
  || fail "(3d) precondition: after base advanced, the tip must DIFFER from base HEAD (defeats the tip==base guard)"
SIDADV="sidadv-$$-$(basename "$WORK")"
run_synth "$RADV" "$SIDADV"
[ "$RC" -eq 0 ] || fail "(3d) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $D1 synthesized-complete" \
  && fail "(3d) a stale empty branch whose base advanced must NOT be synthesized-complete (would finish an empty item) [drop the trailer requirement ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $D1 no-evidence" \
  || fail "(3d) an ambiguous already-in-base tip must classify no-evidence (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $D1 ")) [drop the trailer requirement ⇒ RED]"
comments "$RADV" "$D1" | grep -qi 'landed or stale' \
  || fail "(3d) the no-evidence breadcrumb must carry the ambiguous 'landed or stale — check history' evidence (LLM judges before reclaiming)"
echo "  ok (3d) stale empty branch + advanced base ⇒ no-evidence (ancestry needs a trailer declaration; never a false empty-item finish)"

# ══ Case 3e — MULTI-commit branch squash-merged as ONE base commit ⇒ synthesized-complete (P2a) ══════
# Per-commit `git cherry` can't see this: N branch commits collapse into ONE base commit whose combined
# patch-id matches none of the N individual patch-ids ⇒ a false in-flight on LANDED work (re-dispatch).
# The AGGREGATE patch-id check (branch diff vs each base commit since the merge-base) catches it.
# Red-when-broken: drop the aggregate check ⇒ this reverts to in-flight ⇒ RED.
RMS="$(new_repo)" || fail "new_repo 3e failed"; REPOS+=("$RMS")
M1="$(seed "$RMS" Buildable 'In Progress' 'impl: two commits squash-merged as one')" || fail "seed M1"
git -C "$RMS" checkout -q -b "${M1}-work" main || fail "(3e) branch"
printf 'aaa\n' > "$RMS/a-${M1}.txt"; git -C "$RMS" add "a-${M1}.txt" >/dev/null 2>&1; git -C "$RMS" commit -qm "c1" >/dev/null 2>&1 || fail "(3e) c1"
printf 'bbb\n' > "$RMS/b-${M1}.txt"; git -C "$RMS" add "b-${M1}.txt" >/dev/null 2>&1; git -C "$RMS" commit -qm "c2" >/dev/null 2>&1 || fail "(3e) c2"
git -C "$RMS" checkout -q main || fail "(3e) checkout main"
git -C "$RMS" merge --squash "${M1}-work" >/dev/null 2>&1 || fail "(3e) squash stage"
git -C "$RMS" commit -qm "squash-merge #${M1} (2 commits collapsed into 1)" >/dev/null 2>&1 || fail "(3e) squash commit"
git -C "$RMS" merge-base --is-ancestor "${M1}-work" main \
  && fail "(3e) precondition: a squash-merge must leave ${M1}-work NON-ancestor of main"
# Precondition: per-commit cherry sees BOTH commits as unmerged (proves the per-commit path fails here).
[ "$(git -C "$RMS" cherry main "${M1}-work" | grep -c '^+')" -eq 2 ] \
  || fail "(3e) precondition: per-commit cherry must report 2 unmerged commits (the multi-commit-squash trap)"
SIDMS="sidms-$$-$(basename "$WORK")"
run_synth "$RMS" "$SIDMS"
[ "$RC" -eq 0 ] || fail "(3e) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $M1 synthesized-complete branch ${M1}-work" \
  || fail "(3e) a 2-commit squash-merge must classify synthesized-complete via aggregate patch-equivalence, not in-flight (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $M1 ")) [drop the aggregate check ⇒ RED as in-flight]"
comments "$RMS" "$M1" | grep -qi 'aggregate' \
  || fail "(3e) #$M1 breadcrumb must cite the aggregate patch-equivalent (squash-landed) evidence"
echo "  ok (3e) multi-commit squash-merge ⇒ synthesized-complete via aggregate patch-id (not a false in-flight re-dispatch)"

# ══ Case 3f — STALE LOCAL BASE: work landed on origin/main while local main lags ⇒ complete (P2-2) ═══
# If the operator fetched WITHOUT fast-forwarding local main, merged work sits in origin/main while
# local main lags — measuring only against the stale LOCAL ref reports a false in-flight (re-dispatch).
# The base CANDIDATE LIST (local base + origin/<base> + origin/HEAD) fixes it: complete vs ANY candidate.
# Red-when-broken: drop the remote candidate (classify vs local main only) ⇒ RED as in-flight.
RREM="$(new_repo)" || fail "new_repo 3f failed"; REPOS+=("$RREM")
ORIG3F="$WORK/orig-3f.git"; git init -q --bare "$ORIG3F" || fail "(3f) bare origin"
git -C "$RREM" remote add origin "$ORIG3F" || fail "(3f) remote add"
BASE0="$(git -C "$RREM" rev-parse main)"
git -C "$RREM" push -q origin main || fail "(3f) push base"
F1="$(seed "$RREM" Buildable 'In Progress' 'impl: landed on origin/main, local main lags')" || fail "seed F1"
git -C "$RREM" checkout -q -b "${F1}-work" main || fail "(3f) branch"
printf 'landed work\n' > "$RREM/landed-${F1}.txt"
git -C "$RREM" add "landed-${F1}.txt" >/dev/null 2>&1
git -C "$RREM" commit -qm "work for #${F1}" -m "Issue: #${F1}" >/dev/null 2>&1 || fail "(3f) commit"
git -C "$RREM" checkout -q main || fail "(3f) checkout main"
git -C "$RREM" merge -q --no-ff "${F1}-work" -m "merge #${F1}" || fail "(3f) merge"
git -C "$RREM" push -q origin main || fail "(3f) push landed"    # origin/main NOW contains the work
git -C "$RREM" fetch -q origin || fail "(3f) fetch"              # refresh origin/main tracking ref
git -C "$RREM" reset -q --hard "$BASE0" || fail "(3f) reset local main to lag"
# Preconditions: local main LAGS (== base), the work is NOT in local main but IS in origin/main.
[ "$(git -C "$RREM" rev-parse main)" = "$BASE0" ] || fail "(3f) precondition: local main must lag at base"
git -C "$RREM" merge-base --is-ancestor "${F1}-work" main \
  && fail "(3f) precondition: the work must NOT be in the stale local main"
git -C "$RREM" merge-base --is-ancestor "${F1}-work" origin/main \
  || fail "(3f) precondition: the work MUST be in origin/main (landed authoritatively)"
SIDREM="sidrem-$$-$(basename "$WORK")"
run_synth "$RREM" "$SIDREM"
[ "$RC" -eq 0 ] || fail "(3f) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $F1 synthesized-complete branch ${F1}-work" \
  || fail "(3f) work landed on origin/main (local main stale) must classify synthesized-complete, not in-flight (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $F1 ")) [drop the remote base candidate ⇒ RED as in-flight]"
echo "  ok (3f) stale local base: complete measured against the origin/<base> candidate (fetch-no-ff safe)"

# ══ Case 3g — REAL adapter branch naming worktree-build-<n> is matched (P2-1) ════════════════════════
# The claude adapter names build branches `worktree-build-<n>` / `impl-<n>` (impl-235 IS the drop-H
# incident). Stage D's STRICT regex (number must LEAD a path segment) matches NONE of these — so the
# strict extractor would no-evidence the exact case the synth exists for. The WIDENED token extractor
# links them. Red-when-broken: swap the extractor back to the strict regex ⇒ the branch is unmatched
# ⇒ RED as no-evidence.
RBN="$(new_repo)" || fail "new_repo 3g failed"; REPOS+=("$RBN")
W1="$(seed "$RBN" Buildable 'In Progress' 'impl: real worktree-build-N branch, went idle mid-work')" || fail "seed W1"
git -C "$RBN" checkout -q -b "worktree-build-${W1}" main || fail "(3g) branch"
printf 'wip\n' > "$RBN/wip-${W1}.txt"; git -C "$RBN" add "wip-${W1}.txt" >/dev/null 2>&1
git -C "$RBN" commit -qm "wip on worktree-build-${W1}" >/dev/null 2>&1 || fail "(3g) commit"
git -C "$RBN" checkout -q main || fail "(3g) checkout main"
SIDBN="sidbn-$$-$(basename "$WORK")"
run_synth "$RBN" "$SIDBN"
[ "$RC" -eq 0 ] || fail "(3g) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $W1 in-flight branch worktree-build-${W1} ahead 1" \
  || fail "(3g) a real worktree-build-${W1} branch must be MATCHED + classified in-flight (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $W1 ")) [swap to the strict regex ⇒ RED as no-evidence]"
has_taint "$RBN" "$SIDBN" "$W1" || fail "(3g) the matched worktree-build branch must set an idle_synth taint"
echo "  ok (3g) real adapter naming worktree-build-<n>/impl-<n> is matched by the widened extractor (Stage D's strict regex would miss it)"

# ══ Case 3m — a DATE/parent-PREFIXED adapter branch links the UNIT, not the prefix (round-8 micro-fix) ═
# `2026-07/worktree-build-<n>` must resolve to <n> (the end-anchored adapter unit), NOT 2026 (the strict
# leading-segment date prefix) — consulting the strict regex first let the prefix win via short-circuit,
# a WRONG-item stamp. The adapter shape is consulted FIRST now.
# Red-when-broken: restore strict-first ⇒ the branch links 2026 ⇒ item <n> reads no-evidence ⇒ RED.
RPFX="$(new_repo)" || fail "new_repo 3m failed"; REPOS+=("$RPFX")
PX="$(seed "$RPFX" Buildable 'In Progress' 'impl: date-prefixed adapter branch, went idle mid-work')" || fail "seed PX"
git -C "$RPFX" checkout -q -b "2026-07/worktree-build-${PX}" main || fail "(3m) branch"
printf 'wip\n' > "$RPFX/wip.txt"; git -C "$RPFX" add wip.txt >/dev/null 2>&1
git -C "$RPFX" commit -qm "wip on 2026-07/worktree-build-${PX}" >/dev/null 2>&1 || fail "(3m) commit"
git -C "$RPFX" checkout -q main || fail "(3m) co main"
SIDPFX="sidpfx-$$-$(basename "$WORK")"
run_synth "$RPFX" "$SIDPFX"
[ "$RC" -eq 0 ] || fail "(3m) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $PX in-flight branch 2026-07/worktree-build-${PX} ahead 1" \
  || fail "(3m) a date-prefixed adapter branch must link the UNIT #$PX (adapter shape), not the 2026 prefix (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $PX ")) [restore strict-first ⇒ RED as no-evidence]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: 2026 " \
  && fail "(3m) the date prefix 2026 must NOT be linked as an item [restore strict-first ⇒ RED]"
echo "  ok (3m) date/parent-prefixed adapter branch links the unit via the adapter shape (never the leading date/prefix number)"

# ══ Case 3h — AMBIGUOUS linkage must not STEER an unrelated item (reviewer P2-A) ═════════════════════
# The resolved item STEERS a close/re-dispatch, so a branch with MULTIPLE numbers must link ONLY when
# unambiguous: a supported SHAPE wins even if other numbers appear elsewhere; else exactly one number;
# else link NOTHING (warned). Here `phase-3/worktree-build-1` links to 1 (shape) NOT 3; `cleanup-2-3`
# (no shape, two numbers) links to NEITHER 2 nor 3 and is warned — so items 2 and 3 stay no-evidence.
# Red-when-broken: revert to link-ALL-numbers ⇒ items 3 (from phase-3 / cleanup) and 2 (from cleanup)
# get a FALSE in-flight steer from another item's branch ⇒ their no-evidence asserts go RED.
RAMB="$(new_repo)" || fail "new_repo 3h failed"; REPOS+=("$RAMB")
A1="$(seed "$RAMB" Buildable 'In Progress' 'impl: shape-matched branch, item 1')" || fail "seed A1"
A2="$(seed "$RAMB" Buildable 'In Progress' 'impl: only an ambiguous branch names it, item 2')" || fail "seed A2"
A3="$(seed "$RAMB" Buildable 'In Progress' 'impl: appears in two other branches, item 3')" || fail "seed A3"
git -C "$RAMB" checkout -q -b "phase-${A3}/worktree-build-${A1}" main || fail "(3h) shape branch"
printf 'wip1\n' > "$RAMB/w1.txt"; git -C "$RAMB" add w1.txt >/dev/null 2>&1; git -C "$RAMB" commit -qm "wip 1" >/dev/null 2>&1 || fail "(3h) c1"
git -C "$RAMB" checkout -q main || fail "(3h) co main"
git -C "$RAMB" checkout -q -b "cleanup-${A2}-${A3}" main || fail "(3h) ambiguous branch"
printf 'wip2\n' > "$RAMB/w2.txt"; git -C "$RAMB" add w2.txt >/dev/null 2>&1; git -C "$RAMB" commit -qm "wip 2" >/dev/null 2>&1 || fail "(3h) c2"
git -C "$RAMB" checkout -q main || fail "(3h) co main 2"
SIDAMB="sidamb-$$-$(basename "$WORK")"
run_synth "$RAMB" "$SIDAMB"
[ "$RC" -eq 0 ] || fail "(3h) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $A1 in-flight branch phase-${A3}/worktree-build-${A1} ahead 1" \
  || fail "(3h) #$A1 must link via the SHAPE (worktree-build-$A1), not be lost to the phase-$A3 token (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $A1 "))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $A2 no-evidence" \
  || fail "(3h) #$A2 must be no-evidence — its only branch cleanup-$A2-$A3 is AMBIGUOUS (not linked) (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $A2 ")) [link-all ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $A3 no-evidence" \
  || fail "(3h) #$A3 must be no-evidence — it only appears as a NON-shape token in others' branches (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $A3 ")) [link-all ⇒ RED]"
grep -qE "skipped ambiguous ref cleanup-${A2}-${A3} \(numbers ${A2}, ${A3}" "$ERRFILE" \
  || fail "(3h) an ambiguous ref must be WARNED (visible, never a silent drop): $(cat "$ERRFILE")"
echo "  ok (3h) ambiguous multi-number ref links nothing (warned); a supported shape wins — no false steer of an unrelated item"

# ══ Case 3i — a FAILED breadcrumb write must NOT latch the taint (reviewer P2-B) ═════════════════════
# The idle_synth taint is the idempotence latch: if it is set when the comment write FAILED (a transient
# gh rate-limit / fs error), the next pass SKIPS the commenter and the durable breadcrumb never lands —
# cross-session recovery depends on it. The taint must be set ONLY after a CONFIRMED write. The comment
# is failed in ISOLATION via a monkeypatched `_fs_comment_ok` (a temp driver importing the real module),
# so the LEDGER stays writable — proving the taint is withheld by the fix, not merely because writes are
# blocked (a whole-dir chmod would fail the ledger write too and mask the neuter).
# Red-when-broken: latch the taint regardless of the write result ⇒ the "no taint on a failed write"
# assert goes RED, AND the breadcrumb would never land on a later pass.
RFAIL="$(new_repo)" || fail "new_repo 3i failed"; REPOS+=("$RFAIL")
P1="$(seed "$RFAIL" Buildable 'In Progress' 'impl: breadcrumb write fails this pass')" || fail "seed P1"
SIDFAIL="sidfail-$$-$(basename "$WORK")"
cat > "$WORK/failcomment.py" <<PYEOF
import sys
sys.path.insert(0, "$GOV_PLUGIN/scripts")
import idc_teammate_idle_synth as S
S._fs_comment_ok = lambda *a, **k: False   # simulate a transient failed comment write (ledger untouched)
sys.argv = ["idc_teammate_idle_synth.py", "--repo", "$RFAIL", "--session-id", "$SIDFAIL"]
sys.exit(S.main())
PYEOF
OUT="$(python3 "$WORK/failcomment.py" 2>"$ERRFILE")"; RC=$?
[ "$RC" -eq 0 ] || fail "(3i) synth must fail-soft on a write error (exit 0), got $RC (err: $(cat "$ERRFILE"))"
has_bc "$RFAIL" "$P1" && fail "(3i) precondition: the monkeypatched comment must NOT have landed a breadcrumb"
has_taint "$RFAIL" "$SIDFAIL" "$P1" \
  && fail "(3i) a FAILED breadcrumb write must NOT latch the idle_synth taint (ledger was writable) [latch-anyway ⇒ RED]"
grep -qiE "breadcrumb write for #$P1 FAILED" "$ERRFILE" \
  || fail "(3i) a failed breadcrumb write must WARN (observability-first): $(cat "$ERRFILE")"
# The write is restored (real commenter) → the next pass MUST land the breadcrumb + latch (recovery).
run_synth "$RFAIL" "$SIDFAIL"
has_bc "$RFAIL" "$P1"   || fail "(3i) after the write recovered, the breadcrumb MUST land on the retry pass [latch-anyway ⇒ RED: it would stay skipped]"
has_taint "$RFAIL" "$SIDFAIL" "$P1" || fail "(3i) the taint is set on the CONFIRMED write of the retry pass"
echo "  ok (3i) a failed breadcrumb write is not latched (warned) and lands on the next pass once the write recovers"

# ══ Case 3j — a STALE merged ref must NOT mask a sibling AHEAD ref of the same item (reviewer P2) ═════
# Merged evidence must never mask CURRENT unmerged work: an item with a merged branch (`<n>-work`,
# complete) AND a still-ahead sibling (`<n>-fix`, in-flight) must classify IN-FLIGHT — the old
# complete short-circuit would report synthesized-complete and steer a close while work remains.
# Red-when-broken: restore the complete short-circuit ⇒ this reverts to synthesized-complete ⇒ RED.
RSIB="$(new_repo)" || fail "new_repo 3j failed"; REPOS+=("$RSIB")
S1="$(seed "$RSIB" Buildable 'In Progress' 'impl: one branch merged, a sibling still ahead')" || fail "seed S1"
git -C "$RSIB" checkout -q -b "${S1}-work" main || fail "(3j) work branch"
printf 'landed\n' > "$RSIB/work.txt"; git -C "$RSIB" add work.txt >/dev/null 2>&1
git -C "$RSIB" commit -qm "work for #${S1}" -m "Issue: #${S1}" >/dev/null 2>&1 || fail "(3j) work commit"
git -C "$RSIB" checkout -q main || fail "(3j) co main"
git -C "$RSIB" merge -q --no-ff "${S1}-work" -m "merge #${S1}" || fail "(3j) merge work"   # <n>-work → complete
git -C "$RSIB" checkout -q -b "${S1}-fix" main || fail "(3j) fix branch"
printf 'still ahead\n' > "$RSIB/fix.txt"; git -C "$RSIB" add fix.txt >/dev/null 2>&1
git -C "$RSIB" commit -qm "more work for #${S1}" >/dev/null 2>&1 || fail "(3j) fix commit"   # <n>-fix → ahead
git -C "$RSIB" checkout -q main || fail "(3j) co main 2"
SIDSIB="sidsib-$$-$(basename "$WORK")"
run_synth "$RSIB" "$SIDSIB"
[ "$RC" -eq 0 ] || fail "(3j) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $S1 in-flight branch ${S1}-fix ahead 1" \
  || fail "(3j) an item with a still-AHEAD sibling must classify in-flight (branch ${S1}-fix), not be masked by the merged ${S1}-work (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $S1 ")) [restore the complete short-circuit ⇒ RED as synthesized-complete]"
echo "  ok (3j) a stale merged ref never masks a sibling ahead ref — in-flight dominates (merged evidence can't hide current unmerged work)"

# ══ Case 3k — UNCOMMITTED work in the idle teammate's worktree ⇒ in-flight-resumable, NOT no-evidence ══
# The drop-H incident's MOST COMMON shape (the relay's own lesson: teammates reliably go idle WITHOUT
# committing): a zero-commit branch whose worktree holds uncommitted changes. Reading it as no-evidence
# would RECLAIM it and abandon recoverable local work. The synth must probe the linked worktree's
# `git status --porcelain` and classify in-flight (resume, do not reclaim).
# Red-when-broken: drop the dirty-worktree probe ⇒ this reverts to no-evidence ⇒ RED.
RDIRTY="$(new_repo)" || fail "new_repo 3k failed"; REPOS+=("$RDIRTY")
DW="$(seed "$RDIRTY" Buildable 'In Progress' 'impl: went idle with uncommitted worktree changes')" || fail "seed DW"
git -C "$RDIRTY" worktree add -q -b "${DW}-work" "$RDIRTY/.claude/worktrees/${DW}-work" main || fail "(3k) worktree add"
printf 'work in progress, never committed\n' > "$RDIRTY/.claude/worktrees/${DW}-work/scratch.txt"   # dirty, uncommitted
git -C "$RDIRTY/.claude/worktrees/${DW}-work" status --porcelain | grep -q . || fail "(3k) precondition: the worktree must be DIRTY"
[ "$(git -C "$RDIRTY" rev-parse "${DW}-work")" = "$(git -C "$RDIRTY" rev-parse main)" ] || fail "(3k) precondition: a ZERO-commit branch (tip == main)"
SIDDW="siddw-$$-$(basename "$WORK")"
run_synth "$RDIRTY" "$SIDDW"
[ "$RC" -eq 0 ] || fail "(3k) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $DW in-flight branch ${DW}-work ahead 0" \
  || fail "(3k) a zero-commit branch with a DIRTY worktree must classify in-flight (ahead 0), not no-evidence (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $DW ")) [drop the dirty-worktree probe ⇒ RED as no-evidence]"
comments "$RDIRTY" "$DW" | grep -qi 'uncommitted changes in worktree' \
  || fail "(3k) the breadcrumb must cite the uncommitted-worktree evidence"
comments "$RDIRTY" "$DW" | grep -qiE 'resume.*do not reclaim|do not reclaim' \
  || fail "(3k) the breadcrumb must say resume, do NOT reclaim (recover the local work)"
echo "  ok (3k) uncommitted worktree changes ⇒ in-flight-resumable (recover the local work, never reclaim) — the drop-H common shape"

# ══ Case 3l — a LANDED branch + a still-DIRTY worktree ⇒ in-flight, NOT complete (round-8 P2 ordering) ═
# A branch merged into base is `complete`, but if its worktree STILL has uncommitted edits the item is
# NOT done — reporting complete would steer cleanup over recoverable local changes. The dirty-worktree
# probe must DOMINATE the complete return (run before it), exactly as committed in-flight does.
# Red-when-broken: restore the early complete return (probe only on the no-evidence path) ⇒ RED as complete.
RLDW="$(new_repo)" || fail "new_repo 3l failed"; REPOS+=("$RLDW")
LC="$(seed "$RLDW" Buildable 'In Progress' 'impl: branch merged but worktree still dirty')" || fail "seed LC"
git -C "$RLDW" worktree add -q -b "${LC}-work" "$RLDW/.claude/worktrees/${LC}-work" main || fail "(3l) worktree add"
printf 'landed work\n' > "$RLDW/.claude/worktrees/${LC}-work/f.txt"
git -C "$RLDW/.claude/worktrees/${LC}-work" add f.txt >/dev/null 2>&1
git -C "$RLDW/.claude/worktrees/${LC}-work" commit -qm "work for #${LC}" -m "Issue: #${LC}" >/dev/null 2>&1 || fail "(3l) commit"
git -C "$RLDW" merge -q --no-ff "${LC}-work" -m "merge #${LC}" || fail "(3l) merge (landed)"   # <n>-work → complete
git -C "$RLDW" merge-base --is-ancestor "${LC}-work" main || fail "(3l) precondition: the branch must be landed (ancestor of main)"
printf 'still editing, uncommitted\n' > "$RLDW/.claude/worktrees/${LC}-work/scratch.txt"   # worktree now DIRTY
git -C "$RLDW/.claude/worktrees/${LC}-work" status --porcelain | grep -q . || fail "(3l) precondition: the worktree must be DIRTY"
SIDLDW="sidldw-$$-$(basename "$WORK")"
run_synth "$RLDW" "$SIDLDW"
[ "$RC" -eq 0 ] || fail "(3l) synth exit $RC (err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $LC synthesized-complete" \
  && fail "(3l) a landed branch with a still-DIRTY worktree must NOT be synthesized-complete (would clean up over local edits) [restore the early complete return ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $LC in-flight branch ${LC}-work ahead 0" \
  || fail "(3l) it must classify in-flight (uncommitted) instead (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $LC ")) [restore the early complete return ⇒ RED]"
comments "$RLDW" "$LC" | grep -qi 'uncommitted changes in worktree' \
  || fail "(3l) the breadcrumb must cite the uncommitted-worktree evidence (resume, not clean up)"
echo "  ok (3l) a landed branch with a dirty worktree ⇒ in-flight (uncommitted dominates complete — never clean up over recoverable local edits)"

# ══ Case 4 — IDEMPOTENT RE-RUN ⇒ no duplicate comments, taints unchanged (the class-keyed latch) ════
# The synth re-runs at the TOP OF EVERY autorun pass. The idle_synth taint's stored CLASS is the latch:
# an item whose synthesis class is UNCHANGED is skipped (no second comment).
# Red-when-broken: force `to_stamp = results` ⇒ each item re-commented ⇒ the count climbs to 2 ⇒ RED.
run_synth "$R1" "$SID1"
[ "$RC" -eq 0 ] || fail "(4) re-run exit $RC (err: $(cat "$ERRFILE"))"
for t in "$I1" "$I2" "$I3"; do
  c="$(bc_count "$R1" "$t")"
  [ "$c" -eq 1 ] || fail "(4) #$t has $c breadcrumb comments after an idempotent re-run — must be exactly 1 [force to_stamp=results ⇒ RED]"
done
printf '%s\n' "$OUT" | grep -qE "^teammate-idle-summary: verdict=synthesized synthesized= " \
  || fail "(4) an idempotent re-run must synthesize NOTHING new (summary should show 'synthesized=' empty; got: $(val teammate-idle-summary)) [force to_stamp=results ⇒ RED]"
echo "  ok (4) idempotent re-run: no duplicate comments (the class-keyed latch holds)"

# ══ Case 5 — CLASS CHANGE re-stamps (in-flight → synthesized-complete) — the latch is class-keyed ═══
# #I2 was in-flight; now its branch MERGES into main. The class changes, so the latch must RE-STAMP a
# SECOND (synthesized-complete) breadcrumb — not treat #I2 as already-latched.
# Red-when-broken: key the latch on the item only (ignore the class) ⇒ #I2 stays at 1 comment ⇒ RED.
git -C "$R1" merge -q --no-ff "${I2}-work" -m "merge #${I2}" || fail "(5) could not merge #$I2's branch"
run_synth "$R1" "$SID1"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $I2 synthesized-complete branch ${I2}-work" \
  || fail "(5) after its branch merged, #$I2 must re-print as synthesized-complete (got: $(printf '%s' "$OUT" | grep "^teammate-idle: $I2 "))"
c="$(bc_count "$R1" "$I2")"; [ "$c" -eq 2 ] \
  || fail "(5) #$I2 must gain a SECOND breadcrumb on its class change (in-flight → complete) — got $c [key the latch on item only ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle-summary:.* synthesized=.*\b$I2\b" \
  || fail "(5) the summary must list #$I2 as re-synthesized on its class change"
echo "  ok (5) class change re-stamps: in-flight → synthesized-complete adds a second breadcrumb (latch is class-keyed, not once-ever)"

# ══ Case 6 — AN ITEM LEAVES In-Progress ⇒ its taint is CLEARED; still-open ones keep theirs ═════════
# Move #I1 to Done (finished/reclaimed). It leaves the Buildable ∧ In Progress set → its obligation is
# satisfied → the synth must CLEAR its idle_synth taint (board-proven) and stamp it no more.
# Red-when-broken: force `clear_candidates=[]` ⇒ #I1's taint survives ⇒ RED.
move "$R1" "$I1" Done || fail "(6) could not move #$I1 to Done"
run_synth "$R1" "$SID1"
[ "$RC" -eq 0 ] || fail "(6) reconcile exit $RC (err: $(cat "$ERRFILE"))"
has_taint "$R1" "$SID1" "$I1" \
  && fail "(6) #$I1 left In-Progress (Done) but still carries its idle_synth taint [force clear_candidates=[] ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle-summary:.* cleared=.*\b$I1\b" \
  || fail "(6) the summary must name the cleared item #$I1 (got: $(val teammate-idle-summary)) [force clear_candidates=[] ⇒ RED]"
printf '%s\n' "$OUT" | grep -qE "^teammate-idle: $I1 " \
  && fail "(6) a departed item #$I1 must NOT be re-synthesized (it is off In-Progress)"
has_taint "$R1" "$SID1" "$I2" || fail "(6) a STILL-open item #$I2 must KEEP its taint (over-cleared)"
echo "  ok (6) an item that left In-Progress has its taint cleared; the still-open item keeps its own"

# ══ Case 7 — READ-FAILURE FAIL-SAFE ⇒ preserve the taint, report unknown, never a false 'none' ══════
# An unreadable board (corrupt TRACKER.md → the query helper dies rc=1) is UNKNOWN state, NOT an empty
# board. The synth must NOT clear the taint (clearing on an unproven-empty board is the exact drop-H
# strand) and must report `teammate-idle: unknown`, never a false "none". Pre-seed a taint, corrupt
# the tracker, assert it SURVIVES.
# Red-when-broken: treat `in_progress is None` as [] ⇒ board looks proven-empty ⇒ the taint is WIPED ⇒ RED.
R7="$(new_repo)" || fail "new_repo 7 failed"; REPOS+=("$R7")
SID7="sid7-$$-$(basename "$WORK")"
led "$R7" set --kind idle_synth --key 88 --session "$SID7" >/dev/null || fail "(7) pre-seed taint failed"
has_taint "$R7" "$SID7" 88 || fail "(7) pre-seeded taint did not take"
printf 'corrupt tracker — no idc-tracker-state JSON block, the query helper dies rc=1\n' > "$R7/TRACKER.md"
python3 "$TRK" --tracker "$R7/TRACKER.md" query --stage Buildable --status 'In Progress' >/dev/null 2>&1 \
  && fail "(7) precondition: the corrupt TRACKER.md must make the query FAIL (rc!=0)"
run_synth "$R7" "$SID7"
[ "$RC" -eq 0 ] || fail "(7) synth exit $RC (a fail-soft step must still exit 0; err: $(cat "$ERRFILE"))"
printf '%s\n' "$OUT" | grep -qxE "teammate-idle: unknown" \
  || fail "(7) an unreadable board must print exactly 'teammate-idle: unknown' (got: '$OUT') [treat None as [] ⇒ RED]"
has_taint "$R7" "$SID7" 88 \
  || fail "(7) an UNREADABLE board WIPED the idle_synth taint — state loss [treat in_progress None as [] ⇒ RED]"
grep -qi 'could not determine the board' "$ERRFILE" \
  || fail "(7) the degraded (unreadable-board) path must WARN (observability-first)"
echo "  ok (7) an unreadable/corrupt tracker read PRESERVES the taint (never wiped), reports unknown + warns [safe-bias]"

# ══ Case 8 — OBSERVE-ONLY is a PURE DRY RUN: no taint, no comment, and it does NOT trap the latch ═══
# IDC_HOOKS_OBSERVE_ONLY=1 must warn what it WOULD do and mutate NEITHER the board NOR the ledger — in
# particular it must NOT pre-write the taint, or a later ENFORCE pass would find the item already
# latched and NEVER write its breadcrumb.
# Red-when-broken: make observe set the taint ⇒ the enforce pass finds it latched ⇒ no comment ⇒ RED.
R8="$(new_repo)" || fail "new_repo 8 failed"; REPOS+=("$R8")
O1="$(seed "$R8" Buildable 'In Progress' 'impl: seen first under observe-only')" || fail "seed O1"
SID8="sid8-$$-$(basename "$WORK")"
OUT="$(IDC_HOOKS_OBSERVE_ONLY=1 python3 "$SYN" --repo "$R8" --session-id "$SID8" 2>"$ERRFILE")"; RC=$?
[ "$RC" -eq 0 ] || fail "(8) observe-only exit $RC (err: $(cat "$ERRFILE"))"
has_taint "$R8" "$SID8" "$O1" && fail "(8) observe-only must NOT write the taint (it would trap the latch) [observe sets taint ⇒ RED]"
has_bc "$R8" "$O1" && fail "(8) observe-only must NOT stamp a board comment"
grep -qi 'OBSERVE-ONLY: would stamp' "$ERRFILE" || fail "(8) observe-only must WARN what it would stamp"
# Now ENFORCE (no observe): the item was NOT latched under observe, so this pass MUST write the breadcrumb.
run_synth "$R8" "$SID8"
has_bc "$R8" "$O1" || fail "(8) an ENFORCE pass after observe MUST write the breadcrumb (observe must not trap the latch) [observe sets taint ⇒ RED]"
has_taint "$R8" "$SID8" "$O1" || fail "(8) the enforce pass must set the taint"
echo "  ok (8) observe-only is a pure dry run (no taint/comment, warns) and never traps a later enforce pass"

# ══ Case 9 — REPO-GATE: a non-IDC-governed repo is an instant no-op ═════════════════════════════════
NONGOV="$WORK/nongov"; mkdir -p "$NONGOV"
run_synth "$NONGOV" "sid9-$$"
[ "$RC" -eq 0 ] || fail "(9) repo-gate exit $RC"
printf '%s\n' "$OUT" | grep -qxE "teammate-idle: ungoverned" || fail "(9) a non-governed repo must print 'teammate-idle: ungoverned' (got '$OUT')"
echo "  ok (9) repo-gate: a non-IDC-governed repo → instant no-op (ungoverned)"

echo "PASS: the drain-loop phantom-idle-teammate synthesis — every Buildable ∧ In Progress item's real state is synthesized from LOCAL git evidence (synthesized-complete when its branch merged / in-flight-abandoned when ahead+unmerged / stalled-no-evidence when no branch), each printed + stamped ONE class-appropriate breadcrumb via the sanctioned comment helper + an idle_synth taint; the taint is a CLASS-KEYED idempotence latch so a re-run never duplicates a comment but a class change re-stamps; an item that leaves In-Progress has its taint cleared; an UNREADABLE board reports unknown + preserves taints (never a false none / strand); observe-only is a pure dry run; repo-gated; fail-SOFT (never crashes the drain loop); the synth never closes/moves the item — the orchestrator owns the transition"
