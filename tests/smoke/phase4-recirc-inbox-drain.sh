#!/bin/bash
# idc-assert-class: mixed
# Phase 4 smoke — /idc:recirculate BOARD-SCAN INBOX-DRAIN mode (Lane 4).
#
# The Recirculator gains an ADDITIVE second intake: besides today's operator/role-passed drift
# description, a no-argument (or --drain) run ENUMERATES every open `Stage=Recirculation` inbox
# ticket (scope discovered mid-build) and drains each through the EXISTING decision flow
# (idc:idc-recirculator-sync → idc_recirculator_layers.py — REUSED, not duplicated). Two paths:
#
#   PRD/TRD-worthy (gate: yes) → existing doc-sync + fire the ONE gate (idc:idc-gate-issue);
#       the ticket rides Status=Blocked behind that gate and PAUSES there (not retired).
#   Not gate-worthy (gate: no) → author a function-first ADMITTED consideration
#       (idc:idc-consideration-schema): a Stage=Consideration, Status=Todo pointer carrying the
#       discovered scope (admitted=Todo, distinct from Think's pending-admission pointer), then
#       RETIRE the Recirculation ticket (Status=Done) — preserving provenance.
#
# Two halves:
#   A. STRUCTURAL — red-when-broken greps over commands/recirculate.md + agents/idc-recirculator.md
#      assert the board-scan mode exists AND both paths are documented (gate→gate+Blocked;
#      not-gate→admitted consideration + retire + provenance). RED against the pre-Lane-4 wording
#      (which had no inbox-drain mode, no admitted-consideration path, no retire/provenance).
#   B. FUNCTIONAL — a real Stage=Recirculation round-trip on the filesystem backend driving the
#      shipped helpers: enumerate the open inbox, validate the recirc + consideration shapes, then
#      exercise the not-gate-worthy drain (admit a consideration pointer + retire the ticket) and
#      prove the inbox is emptied (idempotent) and neither artifact is ever build-eligible.
#
# Usage: bash tests/smoke/phase4-recirc-inbox-drain.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
RCMD="$PLUGIN/commands/recirculate.md"
RECIRC="$PLUGIN/agents/idc-recirculator.md"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
SCHEMA="$PLUGIN/scripts/idc_schema_check.py"
CONS="$PLUGIN/scripts/idc_consideration_check.py"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b, no PCRE).
has() { grep -qiE "$2" "$1"; }
# whitespace-flattened phrase check: markdown soft-wraps, so a chain could span lines and dodge a
# line-based grep. Flatten newlines to spaces first, then match (BSD/GNU-portable: tr only).
hasflat() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }

for f in "$RCMD" "$RECIRC" "$TRK" "$SCHEMA" "$CONS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# ============================ A. STRUCTURAL (both shipped playbooks) ============================
for f in "$RCMD" "$RECIRC"; do
  name="$(basename "$f")"

  # A1 — the BOARD-SCAN INBOX-DRAIN mode EXISTS (the additive second intake).
  has "$f" 'inbox.drain' \
    || fail "$name must document the board-scan INBOX-DRAIN mode (the additive second intake)"
  hasflat "$f" '(enumerate|every|each)[^.]*Stage.?=.?Recirculation|Stage.?=.?Recirculation[^.]*(inbox|enumerate|drain)' \
    || fail "$name must enumerate every Stage=Recirculation inbox ticket (the board scan)"

  # A2 — both modes REUSE the existing decision flow (sync skill + layers helper), not a new one.
  has "$f" 'idc:idc-recirculator-sync' \
    || fail "$name must reuse idc:idc-recirculator-sync (the existing highest-affected-layer step)"
  has "$f" 'idc_recirculator_layers\.py' \
    || fail "$name must reuse scripts/idc_recirculator_layers.py (the existing gate-decision helper)"

  # A3 — GATE-WORTHY path: PRD/TRD-worthy → fire the ONE gate + the ticket rides Status=Blocked
  #      behind it and PAUSES (not retired). RED if the gate path or the Blocked/pause wording drops.
  has "$f" 'prd.trd.worthy|gate.worthy' \
    || fail "$name must name the PRD/TRD-worthy (gate-worthy) path"
  has "$f" 'idc:idc-gate-issue' \
    || fail "$name must fire the one gate via idc:idc-gate-issue on the PRD/TRD-worthy path"
  hasflat "$f" '(rides|ride)[^.]*Status.?=.?Blocked|Status.?=.?Blocked[^.]*(behind|gate|paus)|blocked[^.]*behind that gate' \
    || fail "$name must state the Recirculation ticket rides Status=Blocked behind the gate (gate-worthy path)"
  hasflat "$f" 'paus[^.]*(there|gate|behind)|behind that gate[^.]*paus' \
    || fail "$name must state the gate-worthy ticket PAUSES behind the gate"

  # A4 — NOT-GATE-WORTHY path: author an ADMITTED consideration (consideration-schema) as a
  #      Stage=Consideration / Status=Todo pointer, then RETIRE the Recirculation ticket, preserving
  #      provenance. RED if any of the four sub-guards (schema / admitted-Todo / retire / provenance)
  #      is dropped.
  has "$f" 'idc:idc-consideration-schema' \
    || fail "$name must author the admitted consideration per idc:idc-consideration-schema (not-gate-worthy path)"
  hasflat "$f" 'admitted consideration' \
    || fail "$name must describe authoring an ADMITTED consideration (not-gate-worthy path)"
  hasflat "$f" 'Stage.?=.?Consideration' \
    || fail "$name must write the admitted pointer as Stage=Consideration"
  hasflat "$f" 'admitted[^.]*Status.?=.?Todo|Status.?=.?Todo[^.]*admitted|Status.?=.?Todo[^.]*distinct|admitted[^.]*todo' \
    || fail "$name must mark the admitted consideration Status=Todo (admitted — distinct from Think's pending pointer)"
  hasflat "$f" 'retire[^.]*recirculation ticket|retire the recirculation|Status.?=.?Done[^.]*retir|retir[^.]*Status.?=.?Done' \
    || fail "$name must RETIRE the Recirculation ticket (Status=Done) on the not-gate-worthy path"
  has "$f" 'preserve provenance' \
    || fail "$name must preserve provenance when retiring the Recirculation ticket"
  has "$f" 'discovered.scope' \
    || fail "$name must carry provenance via the discovered-scope label / origin marker"

  # A5 — Plan (unchanged) decomposes the drained considerations downstream.
  hasflat "$f" 'Plan[^.]*decompos|decompos[^.]*consideration' \
    || fail "$name must state Plan later decomposes the drained admitted considerations"
done

# ============================ B. FUNCTIONAL (filesystem round-trip) =============================
WORK="$(mktemp -d)"
T="$WORK/TRACKER.md"
trap 'rm -rf "$WORK"' EXIT
run() { python3 "$TRK" --tracker "$T" "$@"; }

run init >/dev/null || fail "tracker init failed"

# B1 — a Stage=Recirculation inbox ticket is created and ENUMERABLE as open inbox work
#      (Stage=Recirculation, Status=Todo) — what the board scan iterates.
recirc="$(run create --title 'recirc: discovered shared rate-limit middleware' \
            --stage Recirculation --phase 'Phase 1' --domain api)" \
  || fail "create Stage=Recirculation inbox ticket failed"
open_inbox="$(run query --stage Recirculation --status Todo)"
echo "$open_inbox" | grep -qw "$recirc" \
  || fail "the open inbox scan (Stage=Recirculation, Status=Todo) must enumerate ticket $recirc (got: '$open_inbox')"

# B2 — the recirc ticket body carries the five required scope fields (schema-valid recirc shape).
cat > "$WORK/recirc-body.md" <<'MD'
Stage: Recirculation
Discovered: build needs a shared rate-limit middleware the contract did not scope
Area: src/api/middleware
Suggested-scope: extract a reusable limiter + wire the two new routes through it
Provenance: discovered mid-build by idc-finisher on #42
PRD-TRD-impact: unknown
MD
python3 "$SCHEMA" "$WORK/recirc-body.md" >/dev/null \
  || fail "the discovered-scope recirc ticket body must validate as a Recirculation ticket"

# B3 — NOT-GATE-WORTHY drain: author an ADMITTED consideration FILE (function-first), with a
#      provenance line preserving its origin, and validate it with the considerations checker.
cat > "$WORK/consideration.md" <<'MD'
# Shared rate-limit middleware — Consideration

- Date: 2026-06-27
- Status: Active
- PRD impact: no — no user-facing behavior change; an internal reliability guardrail
- TRD impact: no — fits the existing API middleware approach
- Origin: originated as discovered scope (recirculation ticket #1 — discovered mid-build by idc-finisher on #42)

## What this does for the user
Requests stay responsive under load; abusive bursts are throttled instead of degrading the app.

## Behavior by domain
API: a reusable limiter wraps the new routes; over-limit callers get a clear 429.

## Open questions
What per-route limits does Plan set, and are they configurable?
MD
python3 "$CONS" "$WORK/consideration.md" >/dev/null \
  || fail "the admitted consideration authored on the not-gate-worthy path must validate (consideration shape)"

# B4 — write the admitted consideration POINTER (Stage=Consideration, Status=Todo) — its board body
#      is a valid pointer (File/Phase/Domain, no goal-contract).
cons="$(run create --title 'consideration: shared rate-limit middleware (from discovered scope)' \
          --stage Consideration --status Todo --phase 'Phase 1' --domain api)" \
  || fail "create admitted Stage=Consideration pointer failed"
cat > "$WORK/pointer-body.md" <<'MD'
Stage: Consideration
File: docs/considerations/2026-06-27-rate-limit-middleware-considerations.md
Phase: Phase 1
Domain: api
Origin: originated as discovered scope (recirculation ticket #1)
MD
python3 "$SCHEMA" "$WORK/pointer-body.md" >/dev/null \
  || fail "the admitted consideration pointer body must validate as a pointer"
[ "$(run show --num "$cons" --field Stage)"  = "Consideration" ] || fail "admitted pointer Stage must be Consideration"
[ "$(run show --num "$cons" --field Status)" = "Todo" ]          || fail "admitted pointer Status must be Todo (admitted, not behind a gate)"

# B5 — RETIRE the Recirculation ticket (Status=Done) and prove the inbox is EMPTIED (idempotent:
#      a re-scan of the open inbox no longer returns it).
run close --num "$recirc" >/dev/null || fail "retiring (closing) the recirc ticket failed"
[ "$(run show --num "$recirc" --field Status)" = "Done" ] \
  || fail "the retired Recirculation ticket must be Status=Done"
open_inbox_after="$(run query --stage Recirculation --status Todo)"
echo "$open_inbox_after" | grep -qw "$recirc" \
  && fail "the retired ticket $recirc must NOT reappear in the open inbox scan (drain must be idempotent) (got: '$open_inbox_after')"

# B6 — the GLASS WALL holds throughout: neither the retired recirc ticket nor the admitted
#      consideration pointer is ever build-eligible — Plan decomposes the consideration, no builder
#      ever claims either.
if [ -f "$DRAIN" ]; then
  elig="$(python3 "$DRAIN" --tracker "$T")" || fail "drain helper errored"
  echo "$elig" | grep -qE "(^| )$cons( |$)" \
    && fail "the admitted Consideration pointer $cons must NEVER be build-eligible — the glass wall (got: '$elig')"
  echo "$elig" | grep -qE "(^| )$recirc( |$)" \
    && fail "the retired Recirculation ticket $recirc must NEVER be build-eligible — the glass wall (got: '$elig')"
fi

echo "PASS: board-scan inbox-drain mode documented (both paths) in commands/recirculate.md + agents/idc-recirculator.md; functional Stage=Recirculation round-trip drains the inbox (admit consideration + retire ticket, idempotent) with the glass wall intact"
