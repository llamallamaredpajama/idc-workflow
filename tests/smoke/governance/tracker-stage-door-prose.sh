#!/usr/bin/env bash
# idc-assert-class: doc
# tracker-stage-door-prose.sh — the tracker skills must name a Stage-write door that EXISTS, never the
# nonexistent "Stage -> move" one, and no role-facing recipe may set Stage through an unguarded raw
# path (Task 3, round-5 Fix 4).
#
# `move` accepts only `--to-status`; it has NO Stage target. Stage is machine-governed and owned by
# the create ops (initial Stage) + the terminal dispositions (final Stage) — there is no standalone
# Stage-write door, and `set-field` refuses Stage. The shipped adapter/backends must say exactly that.
#
# Red-when-broken: re-introduce a "Stage ... use/route ... move" claim, or list `Stage` in the raw
# filesystem `set` recipe, or add `Stage` back to the adapter `setField` field set → a check FAILs.
#
# Usage: bash tests/smoke/governance/tracker-stage-door-prose.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ADAPTER="$GOV_PLUGIN/skills/idc-tracker-adapter/SKILL.md"
FS="$GOV_PLUGIN/skills/idc-tracker-filesystem/SKILL.md"
GH="$GOV_PLUGIN/skills/idc-tracker-github/SKILL.md"
for f in "$ADAPTER" "$FS" "$GH"; do [ -f "$f" ] || gov_fail "skill not found: $f"; done

# (1) No skill may claim a Stage change goes through `move` (a door that does not exist). Match a
# Stage-and-move claim on one line, tolerant of wording (use/route/via + `move`), case-insensitive.
for f in "$ADAPTER" "$FS" "$GH"; do
  if grep -Eni 'stage[^.]*\b(use|route|routed|via|through|dispatch)[^.]*\bmove\b' "$f" >/dev/null; then
    gov_fail "$(basename "$(dirname "$f")") still claims a Stage change routes through \`move\` (nonexistent door): $(grep -Eni 'stage[^.]*\b(use|route|routed|via|through|dispatch)[^.]*\bmove\b' "$f")"
  fi
done
echo "  ok no skill claims the nonexistent Stage -> move door"

# (2) The filesystem skill's raw `set` recipe must NOT offer Stage as a settable field, and must
# explicitly forbid `--field Stage`.
if grep -E 'set --num N --field \{[^}]*Stage' "$FS" >/dev/null; then
  gov_fail "filesystem skill still lists Stage in the raw \`set\` recipe field set"
fi
grep -qi 'never .*--field Stage\|--field Status .*--field Stage\|--field Status\` or \`--field Stage' "$FS" \
  || gov_fail "filesystem skill must explicitly forbid a raw \`set --field Stage\` (never found the prohibition)"
echo "  ok the filesystem raw \`set\` recipe excludes + forbids Stage"

# (3) The adapter `setField` interface row must scope to the non-machine fields (no Stage/Status).
if grep -E '`setField`.*field ∈ \{[^}]*Stage' "$ADAPTER" >/dev/null; then
  gov_fail "adapter setField interface still lists Stage as a settable field"
fi
echo "  ok the adapter setField interface is scoped to non-machine fields (no Stage)"

echo "PASS: the tracker skills name only real Stage-owning doors; no role-facing raw Stage-write path remains"
