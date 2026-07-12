#!/bin/bash
# gate-skill-dispose-order.sh — governance scenario (doc invariant): idc:idc-gate-issue's step 4
# runs the engine's GUARDED dispose BEFORE unblocking dependents, in BOTH gate procedures
# (requirements admission AND the operator-decision gate).
#
# WHY (codex round-10 P2): the old order — unblock dependents first, dispose second — validated the
# approval only AFTER the dependents were already `Todo`. If the approval was revoked between
# detection and the dispose (label pulled, decision-rejected added), the dispose correctly refused —
# but the already-unblocked work stayed eligible and could proceed with no current GO signal. The
# guarded dispose IS the validation, so it must go first; a refused dispose leaves the chain Blocked.
#
# Deterministic order-of-phrase check on the shipped skill prose (the executing agent's playbook),
# mirroring phase7-command-prose-invariants.sh: in each step-4 block the dispose instruction must
# precede the dependent-unblock instruction, the unblock must be explicitly conditioned on the
# dispose succeeding, and the interrupted-run recovery (a Done gate with still-Blocked dependents)
# must be named so dispose-first cannot strand dependents.
#
# Red-when-broken: swap the order back (unblock prose before the dispose sentence), drop the
# "after the dispose succeeds" condition, or drop the Done-gate recovery line → this FAILs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

SKILL="$GOV_PLUGIN/skills/idc-gate-issue/SKILL.md"
[ -f "$SKILL" ] || gov_fail "skills/idc-gate-issue/SKILL.md missing"

python3 - "$SKILL" <<'PY' || gov_fail "gate-skill dispose-before-unblock prose invariant broken (see above)"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

# The two step-4 blocks: requirements admission ("4 — Detect admission…" up to the next "##"
# heading) and the decision gate ("4. **Detect the decision…" up to the next "##" heading).
def section(start_pat, name):
    m = re.search(start_pat, text)
    if not m:
        raise SystemExit(f"FAIL: could not locate the {name} step-4 block ({start_pat!r})")
    end = text.find("\n## ", m.start())
    return text[m.start():end if end != -1 else len(text)], name

blocks = [section(r"\*\*4 — Detect admission", "requirements-gate"),
          section(r"4\.\s+\*\*Detect the decision", "decision-gate")]

DISPOSE = "dispose --disposition gate-approved"
UNBLOCK = "`Status=Todo`"
for block, name in blocks:
    d, u = block.find(DISPOSE), block.find(UNBLOCK)
    if d == -1:
        raise SystemExit(f"FAIL: {name} step 4 never names the guarded dispose ({DISPOSE})")
    if u == -1:
        raise SystemExit(f"FAIL: {name} step 4 never names the dependent unblock ({UNBLOCK})")
    if not d < u:
        raise SystemExit(f"FAIL: {name} step 4 unblocks dependents BEFORE the guarded dispose — "
                         "a revoked approval then leaves work unblocked (codex round-10 P2)")
    if "after the dispose succeeds" not in block:
        raise SystemExit(f"FAIL: {name} step 4 does not condition the unblock on the dispose "
                         "succeeding ('after the dispose succeeds')")
    print(f"  ok {name}: guarded dispose precedes the dependent unblock, and the unblock is "
          "conditioned on it succeeding")

# dispose-first must not strand dependents when a run dies between the dispose and the unblock:
# the recovery (a Done gate whose dependents are still Blocked → finish the unblock) must be named.
if "still-`Blocked` dependents" not in text:
    raise SystemExit("FAIL: the skill never names the interrupted-run recovery (a Done gate with "
                     "still-Blocked dependents must have its unblock finished on the next re-check)")
print("  ok interrupted-run recovery (Done gate, still-Blocked dependents) is named")
PY

echo "PASS: idc:idc-gate-issue step 4 (both gate kinds) runs the guarded dispose FIRST and unblocks dependents only after it succeeds, with the interrupted-run recovery named — a revoked approval can no longer leave dependents unblocked"
