#!/bin/bash
# engine-github-link.sh — governance scenario: the github `link` op records the dependency durably.
#
# Stage 1b wires github `link` (was fail-closed). github has no first-class blocks field on the
# project board, so the dependency is recorded as a parseable comment marker on the CHILD (mirrors
# the filer's Blocks-parent body line; read by the recirculator/acceptance).
#
# In-process unit: idc_gh_board.add_comment is monkeypatched; assert the marker lands on the child
# with the parent recorded. Red-when-broken: neuter _gh_link (drop the add_comment) → no dependency
# recorded → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-github-link.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github link unit failed (see above)"
import sys, json
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

comments = []
B.add_comment = lambda n, body, r: comments.append((n, body))
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5", 7: "PVTI_7"})

# link: parent #7 blocks child #5 → a marker comment on the CHILD (#5) recording the parent.
E.run("link", ctx, parent=7, child=5, kind="blocks")
assert len(comments) == 1, f"expected exactly one comment, got {comments}"
child, body = comments[0]
assert child == 5, f"dependency marker landed on #{child}, expected the child #5"
assert "idc-blocked-by" in body, "comment is missing the idc-blocked-by marker"
# the marker is parseable JSON naming both ends of the edge.
import re
m = re.search(r"idc-blocked-by:\s*(\{.*?\})", body)
assert m, f"marker not parseable: {body!r}"
edge = json.loads(m.group(1))
assert edge["parent"] == 7 and edge["child"] == 5 and edge["kind"] == "blocks", f"edge wrong: {edge}"
print("  ok github link records a parseable blocked-by marker on the child (#5 blocked-by #7)")
PY

echo "PASS: github link records the dependency durably as a parseable blocked-by marker on the child issue"
