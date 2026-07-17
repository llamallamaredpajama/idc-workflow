#!/bin/bash
# engine-github-link.sh — governance scenario: the github `link` op records the dependency durably.
#
# A github `blocks` edge has TWO representations, and `link --kind blocks` writes BOTH (Task 3, Fix 2):
#   * the NATIVE GitHub issue-dependencies `blocked_by` relation — the ONLY one the autorun drain's
#     dependency gate reads — created through the sanctioned engine subprocess (idc_gh_board), NEVER a
#     raw `gh api …/dependencies/blocked_by` POST typed into Bash (the interlock now denies that);
#   * the engine's parseable comment marker on the CHILD (read by the dispose guards / recirculator).
#
# In-process unit: idc_gh_board.add_comment + the native-edge helpers are monkeypatched; assert BOTH
# the native edge and the marker land, and that a still-absent native edge fail-closes. Red-when-broken:
# neuter _gh_link (drop the add_blocked_by OR the add_comment) → a representation is missing → FAILs.
#
# Usage: bash tests/smoke/governance/engine-github-link.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github link unit failed (see above)"
import sys, json, re
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

# Simulate the native blocked_by store: add_blocked_by inserts, blocked_by_numbers reads it back.
native = {}   # child -> set(parent)
B.add_blocked_by = lambda child, parent, r: native.setdefault(int(child), set()).add(int(parent))
B.blocked_by_numbers = lambda child, r: sorted(native.get(int(child), set()))
comments = []
B.add_comment = lambda n, body, r: comments.append((n, body))
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5", 7: "PVTI_7"})

# link: parent #7 blocks child #5 → the NATIVE edge lands on #5 AND a marker comment on #5.
E.run("link", ctx, parent=7, child=5, kind="blocks")
assert native.get(5) == {7}, f"native blocked-by edge missing/wrong: {native}"
assert len(comments) == 1, f"expected exactly one comment, got {comments}"
child, body = comments[0]
assert child == 5, f"dependency marker landed on #{child}, expected the child #5"
assert "idc-blocked-by" in body, "comment is missing the idc-blocked-by marker"
m = re.search(r"idc-blocked-by:\s*(\{.*?\})", body)
assert m, f"marker not parseable: {body!r}"
edge = json.loads(m.group(1))
assert edge["parent"] == 7 and edge["child"] == 5 and edge["kind"] == "blocks", f"edge wrong: {edge}"
print("  ok github link records BOTH the native blocked-by edge AND the marker on the child (#5 blocked-by #7)")

# A native POST that does NOT land (edge still absent on read-back) must fail-closed — never record a
# block the drain would not see.
native.clear()
comments.clear()
B.add_blocked_by = lambda child, parent, r: None   # POST silently no-ops → edge stays absent
try:
    E.run("link", ctx, parent=7, child=5, kind="blocks")
    print("FAIL: link accepted a native edge that never landed"); sys.exit(1)
except E.TransitionError:
    pass
assert not comments, "link wrote the marker even though the native edge never landed (should fail-closed first)"
print("  ok github link fail-closes when the native blocked-by edge does not land (no phantom block)")
PY

echo "PASS: github link records the dependency durably through BOTH the native blocked-by edge and the child marker, and fail-closes when the native edge does not land"
