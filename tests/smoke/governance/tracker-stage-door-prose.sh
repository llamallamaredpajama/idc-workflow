#!/usr/bin/env bash
# idc-assert-class: doc
# tracker-stage-door-prose.sh — the tracker skills must name the REAL guarded Stage-write door
# (`move --to-stage`) and never route a role through a raw Stage write (Task 3, round-6 Fix 6 / #151).
#
# Round-6 reverses the round-5 "no Stage door" decision: `move` now accepts `--to-stage`, the guarded
# Stage-transition door that validates the Stage/Status pair against the machine and journals to_stage
# (Plan's Consideration -> Planning rides it). The shipped adapter/backends must (1) NAME that real
# door, (2) still forbid a raw `set --field Stage` for roles, and (3) keep `Stage` out of the adapter
# `setField` field set (set-field refuses it).
#
# Red-when-broken: drop the `move --to-stage` mention from a skill (the door goes unnamed again), or
# list `Stage` in the raw filesystem `set` recipe field set, or add `Stage` back to the adapter
# `setField` field set → a check FAILs.
#
# Usage: bash tests/smoke/governance/tracker-stage-door-prose.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ADAPTER="$GOV_PLUGIN/skills/idc-tracker-adapter/SKILL.md"
FS="$GOV_PLUGIN/skills/idc-tracker-filesystem/SKILL.md"
GH="$GOV_PLUGIN/skills/idc-tracker-github/SKILL.md"
for f in "$ADAPTER" "$FS" "$GH"; do [ -f "$f" ] || gov_fail "skill not found: $f"; done

# (1) Each skill must NAME the real guarded Stage door, `move --to-stage` (case-insensitive, tolerant
# of the `--to-stage <Stage>` form). A skill that omits it left Stage advances doorless again.
for f in "$ADAPTER" "$FS" "$GH"; do
  grep -Eqi 'move --to-stage' "$f" \
    || gov_fail "$(basename "$(dirname "$f")") never names the guarded Stage door \`move --to-stage\`"
done
echo "  ok every tracker skill names the guarded Stage door (move --to-stage)"

# (2) The filesystem skill's raw `set` recipe must NOT offer Stage as a settable field, and must
# explicitly forbid `--field Stage` for roles (the raw primitive stays for the engine/tests only).
if grep -E 'set --num N --field \{[^}]*Stage' "$FS" >/dev/null; then
  gov_fail "filesystem skill still lists Stage in the raw \`set\` recipe field set"
fi
grep -qi 'never .*--field Stage\|--field Status .*--field Stage\|--field Status\` or \`--field Stage' "$FS" \
  || gov_fail "filesystem skill must explicitly forbid a raw \`set --field Stage\` for roles (never found the prohibition)"
echo "  ok the filesystem raw \`set\` recipe excludes + forbids Stage for roles"

# (3) The adapter `setField` interface row must scope to the non-machine fields (no Stage/Status).
if grep -E '`setField`.*field ∈ \{[^}]*Stage' "$ADAPTER" >/dev/null; then
  gov_fail "adapter setField interface still lists Stage as a settable field"
fi
echo "  ok the adapter setField interface is scoped to non-machine fields (no Stage)"

echo "PASS: the tracker skills name the real guarded Stage door (move --to-stage); no role-facing raw Stage-write path remains"
