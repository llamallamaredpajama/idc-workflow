#!/bin/bash
# janitor-resume-recirc.sh — governance scenario for the janitor RESUME-RECIRC finding (U4).
#
# A recirculator killed mid-drain (usage-window truncation) leaves BOTH an OPEN recirc branch/PR AND
# an OPEN recirculation inbox (a `Stage=Recirculation, Status != Done` ticket). That correlation is
# the signature the next session must resume. `scripts/idc_git_janitor.py` emits a RISKY
# **RESUME-RECIRC** finding when — and ONLY when — BOTH sets are non-empty. It composes from the
# already-loaded board + branch lists (no extra board read / gh call).
#
# BEHAVIOR proven (red-when-broken via two in-scenario contrasts that each drop ONE condition):
#   * POSITIVE: an unmerged `recirculate/*` branch + an open Stage=Recirculation ticket → RESUME-RECIRC
#     (RISKY), exit 1.
#   * CONTRAST 1 (drop the open-inbox condition): retire the ticket (Status=Done) with the branch still
#     open → RESUME-RECIRC DISAPPEARS.
#   * CONTRAST 2 (drop the open-branch condition): a fresh open Stage=Recirculation ticket but the
#     recirc branch now MERGED into main → RESUME-RECIRC DISAPPEARS.
# The two contrasts together prove the finding needs BOTH conditions.
#
# The scenario is filesystem-backed + hermetic (real git, no GitHub), mirroring phase1-git-janitor.sh:
# the tracker lives INSIDE the repo ($R/TRACKER.md) because the janitor is invoked with --tracker.
#
# Usage: bash tests/smoke/governance/janitor-resume-recirc.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
JAN="$PLUGIN/scripts/idc_git_janitor.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; R="$WORK/repo"; O="$WORK/origin.git"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "----- report -----"; echo "$2"; }; exit 1; }
gitc() { git -C "$R" "$@"; }

[ -f "$JAN" ] || fail "janitor scanner not found at $JAN"
[ -f "$TRK" ] || fail "tracker helper not found at $TRK"

# ---- hermetic repo + bare origin ------------------------------------------------------------------
git init -q -b main "$O" --bare || fail "bare origin init failed (git too old for -b?)"
git init -q -b main "$R"        || fail "repo init failed"
gitc config user.email t@t.t; gitc config user.name t
gitc remote add origin "$O"
printf base > "$R/base.txt"; gitc add -A; gitc commit -qm base
gitc push -q -u origin main     || fail "initial push to origin failed"
python3 "$TRK" --tracker "$R/TRACKER.md" init >/dev/null || fail "tracker init failed"
# The board is seeded directly via the tracker (no engine transitions), so create the (empty)
# transition journal explicitly: a non-empty board with a MISSING journal is indeterminate (exit 2,
# fail-closed journal dimension) and would mask this scenario's exit-1 assertion.
mkdir -p "$R/docs/workflow" && : > "$R/docs/workflow/transition-journal.ndjson" \
  || fail "seeding the empty transition journal failed"

# ---- seed: an OPEN recirculation inbox item (Stage=Recirculation, Status=Todo) --------------------
python3 "$TRK" --tracker "$R/TRACKER.md" create --title 'recirc: drain the inbox' \
  --stage Recirculation --status Todo >/dev/null || fail "seeding the recirc ticket failed"  # #1

# ---- an OPEN (unmerged) recirc branch — the mid-drain artifact ------------------------------------
gitc checkout -q -b recirculate/drain-inbox main
# stage ONLY drain.txt — never `add -A` (that would commit the untracked TRACKER.md onto this branch,
# and checking out main, which lacks it, would then delete it from the working tree).
printf w > "$R/drain.txt"; gitc add drain.txt; gitc commit -qm "wip: recirc drain"
gitc checkout -q main

# ================================================================================================
# CASE A (POSITIVE): open recirc branch + open inbox → RESUME-RECIRC (RISKY), exit 1
rep="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"; rc=$?
[ "$rc" -eq 1 ] || fail "positive case must exit 1 (findings present), got $rc" "$rep"
printf '%s\n' "$rep" | grep -qE 'RISKY recirc RESUME-RECIRC' \
  || fail "positive: expected a RISKY recirc RESUME-RECIRC finding" "$rep"

# ================================================================================================
# CASE B (CONTRAST 1 — drop the open-inbox condition): retire the ticket (Status=Done), branch still
# open → RESUME-RECIRC must DISAPPEAR (the branch alone is not enough).
python3 "$TRK" --tracker "$R/TRACKER.md" close --num 1 >/dev/null || fail "retiring ticket #1 failed"
[ "$(python3 "$TRK" --tracker "$R/TRACKER.md" show --num 1 --field Status)" = "Done" ] \
  || fail "test setup: ticket #1 should now be Done"
rep="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"
printf '%s\n' "$rep" | grep -qE 'RESUME-RECIRC' \
  && fail "contrast 1: RESUME-RECIRC must DISAPPEAR when the inbox is drained (branch still open)" "$rep"

# ================================================================================================
# CASE C (CONTRAST 2 — drop the open-branch condition): a fresh OPEN Stage=Recirculation ticket, but
# the recirc branch now MERGED into main → RESUME-RECIRC must DISAPPEAR (the inbox alone is not enough).
python3 "$TRK" --tracker "$R/TRACKER.md" create --title 'recirc: another inbox' \
  --stage Recirculation --status Todo >/dev/null || fail "seeding ticket #2 failed"  # #2 open
gitc merge -q --no-ff recirculate/drain-inbox -m "merge recirc drain"   # branch now merged (closed)
rep="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"
printf '%s\n' "$rep" | grep -qE 'RESUME-RECIRC' \
  && fail "contrast 2: RESUME-RECIRC must DISAPPEAR when the recirc branch is merged (inbox still open)" "$rep"

# ================================================================================================
# CASE D (Fix 7 — the `recirc/*` prefix is recognized too): #2 is still an OPEN Stage=Recirculation
# inbox; add an OPEN (unmerged) `recirc/<slug>` branch → RESUME-RECIRC must FIRE. Red-when-broken: the
# detector filtering only `recirculate/*` misses `recirc/*` → RESUME-RECIRC never fires → this FAILs.
gitc checkout -q -b recirc/short-slug main
printf y > "$R/recirc2.txt"; gitc add recirc2.txt; gitc commit -qm "wip: recirc short-slug drain"
gitc checkout -q main
rep="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"; rc=$?
[ "$rc" -eq 1 ] || fail "case D must exit 1 (findings present), got $rc" "$rep"
printf '%s\n' "$rep" | grep -qE 'RESUME-RECIRC' \
  || fail "case D: an open recirc/ branch + open Stage=Recirculation inbox must trigger RESUME-RECIRC" "$rep"

echo "PASS: janitor emits RISKY RESUME-RECIRC iff an open recirc branch (recirculate/* OR recirc/*) coexists with an open Stage=Recirculation inbox; retiring the ticket OR merging the branch each makes it disappear (both conditions required)"
