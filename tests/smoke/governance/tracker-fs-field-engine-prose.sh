#!/usr/bin/env bash
# idc-assert-class: doc
# tracker-fs-field-engine-prose.sh — the filesystem backend skill must route role-facing
# Wave/Phase/Domain writes through the transition engine's `set-field` op (journaled), NOT the raw
# `idc_tracker_fs.py set` primitive (Task 3 round-9 Fix C / review finding 5).
#
# The adapter's binding rule (skills/idc-tracker-adapter/SKILL.md) is that BOTH backends dispatch
# `setField(ticket, Wave|Phase|Domain, value)` through `idc_transition.py … set-field` — which
# resolves ids, writes the single-select value, reads it back, and JOURNALS it. The github backend
# already says exactly this. The filesystem prose previously told roles to run raw
# `idc_tracker_fs.py set --field {Wave|Phase|Domain}` for those fields — an executable escape around
# the journal, contradicting the adapter. The raw `set` primitive may remain ONLY as the low-level
# mechanic the engine calls internally / the journal-replay drift-simulation tests drive directly,
# NEVER as a role recipe.
#
# Red-when-broken: revert the filesystem skill to route Wave/Phase/Domain through the raw
# `idc_tracker_fs.py set` role recipe (drop the engine `set-field` row, or re-add the raw
# `set --num N --field {Wave|Phase|Domain}` role recipe) → a check FAILs.
#
# Usage: bash tests/smoke/governance/tracker-fs-field-engine-prose.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

FS="$GOV_PLUGIN/skills/idc-tracker-filesystem/SKILL.md"
[ -f "$FS" ] || gov_fail "filesystem skill not found: $FS"

# markdown wraps unpredictably; flatten newlines to spaces before matching so a soft-wrapped recipe
# row can't dodge a line-based grep (BSD/GNU-portable: tr only).
flat="$(tr '\n' ' ' < "$FS" | tr -s ' ')"

# (1) The filesystem skill must name the ENGINE `set-field` op for the non-machine fields — the
# journaled write door both backends share. Red-when-broken: revert the createTicket/setField prose to
# "via the raw helper" and this row disappears.
printf '%s' "$flat" | grep -qiE 'set-field --num N --field \{[^}]*Wave' \
  || gov_fail "filesystem skill must route Wave/Phase/Domain through the engine \`set-field\` op (engine row not found)"

# (2) The raw `idc_tracker_fs.py set` primitive must NOT be presented as the ROLE recipe for those
# fields. The exact raw role-recipe form `set --num N --field {Wave|Phase|Domain}` must be ABSENT
# from the filesystem prose (the engine's `set-field` form above carries the hyphen and does not match).
if printf '%s' "$flat" | grep -qiE '`set --num N --field \{[^}]*(Wave|Phase|Domain)'; then
  gov_fail "filesystem skill still presents the raw \`set --num N --field {Wave|Phase|Domain}\` role recipe (must route through the engine \`set-field\` op instead)"
fi

# (3) A surviving mention of the raw `set` primitive for those fields must be explicitly demoted to an
# engine-internal / test-only mechanic that a role never invokes directly. Assert the demotion language
# is present so the primitive can't silently re-become a role recipe.
printf '%s' "$flat" | grep -qiE '(no role|never).{0,140}(raw )?`?set`?.{0,140}(engine|internal|journal-replay|drift|test)|(engine[- ]internal|journal-replay|drift).{0,140}(raw )?`?set`?' \
  || gov_fail "filesystem skill must explicitly demote the raw \`set\` primitive to an engine-internal/test mechanic a role never runs"

echo "PASS: the filesystem backend skill routes role-facing Wave/Phase/Domain writes through the engine set-field op (raw set demoted to an engine-internal/test mechanic)"
