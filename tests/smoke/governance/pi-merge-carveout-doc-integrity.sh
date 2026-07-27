#!/bin/bash
# idc-assert-class: doc-integrity
# pi-merge-carveout-doc-integrity.sh — F8 (durable guard): the Pi adapter SKILL is the single source of
# truth for Pi merge behavior (it declares "this is the only place pi mechanics live"), yet F8 has
# reopened repeatedly because a surface in it attributes the integration merge to the finisher/sous-chef
# without the Pi operator-merge carve-out. This makes that drift a FAILING governance check rather than
# a reviewer's catch.
#
# The invariant: in skills/idc-adapter-pi/SKILL.md,
#   (1) the operator-merge carve-out MUST exist (`does not self-merge` AND `operator-performed`); and
#   (2) NO line may attribute the ACT of merging to the finisher/sous-chef ("the sous-chef merges…",
#       "…does the finisher merge") without an operator-merge carve-out within a few lines of it.
# The wording "does not self-merge", the lease name `leaseAcquire(merge, …)`, and other-runtime rows
# ("the orchestrator merges") are deliberately NOT flagged — only a finisher/sous-chef merge-as-verb
# claim standing without its carve-out.
#
# Red-when-broken: the round-3 topology paragraph ("the sous-chef **merges** that staging branch",
# "only then does the finisher merge") had its carve-out ~40 lines away in §5, so this guard fails on it.
#
# F29: this scanner is SILENT on a clean tree, so a rotted DRIFT regex would disable it undetected (the
# recurring silent-guard trap). An embedded self-test (step 0 below) feeds each DRIFT regex — every
# alternation branch — a canned known-bad line and the CARVEOUT regex a canned carve-out, so a regex
# regression fails THIS lane instead of shipping the next F8 drift uncaught.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$PLUGIN/skills/idc-adapter-pi/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$SKILL" ] || fail "missing Pi adapter skill: skills/idc-adapter-pi/SKILL.md"

out="$(python3 - "$SKILL" <<'PY'
import re, sys
path = sys.argv[1]

# The patterns are defined ONCE and shared by BOTH the embedded self-test and the real-file scan, so a
# self-test failure is a faithful proof that the very regexes doing the real scan have rotted.
DRIFT = [
    re.compile(r"(?i)(sous[- ]chef|finisher)\s+\*{0,2}merges\b"),      # "the sous-chef merges …"
    re.compile(r"(?i)\b(does|do)\s+the\s+finisher\s+\*{0,2}merge\b"),  # "…does the finisher merge"
]
CARVEOUT = re.compile(r"(?i)does not self-merge|operator-performed|operator merge")
WINDOW = 6

# (0) SELF-TEST against a PLANTED positive fixture (F29). A real-tree-silence scanner passes on a clean
# tree whether or not its regexes still work, so a later edit that breaks/loosens a DRIFT regex (a typo
# in the `sous[- ]chef|finisher` alternation, a dropped `\*{0,2}`) would silently disable the guard and
# the NEXT F8 drift would ship uncaught — the silent-guard trap this repo has hit repeatedly. Feeding
# each DRIFT regex a canned known-bad line (and CARVEOUT a canned carve-out) makes a regex regression
# FAIL THE LANE here, not slip past a reviewer.
# Exercise BOTH alternation branches of DRIFT[0] (sous-chef AND finisher) plus the space/bold variants,
# so a break in EITHER branch — not just the one an incidental fixture happens to hit — fails the lane.
DRIFT_KNOWN_BAD = [
    (0, "On the Pi runtime the sous-chef merges the staging branch under the board-backed lease."),
    (0, "the sous chef **merges** that branch"),                 # space-form + bold variant of DRIFT[0]
    (0, "the finisher merges the integration branch"),           # the finisher branch of DRIFT[0]
    (1, "only then does the finisher merge the integration ref"),
]
for idx, sample in DRIFT_KNOWN_BAD:
    if not DRIFT[idx].search(sample):
        print(f"SELFTEST-FAIL: DRIFT[{idx}] no longer flags its known-bad line: {sample!r}")
CARVEOUT_KNOWN_GOOD = "the finisher does not self-merge; the integration merge is operator-performed"
if not CARVEOUT.search(CARVEOUT_KNOWN_GOOD):
    print(f"SELFTEST-FAIL: CARVEOUT no longer matches its known carve-out: {CARVEOUT_KNOWN_GOOD!r}")

text = open(path, encoding="utf-8").read()
lines = text.splitlines()

# (1) the operator-merge carve-out must be present at all.
if "does not self-merge" not in text or "operator-performed" not in text:
    print("MISSING-CARVEOUT: the Pi operator-merge carve-out ('does not self-merge' + "
          "'operator-performed') is not present in the skill")

# (2) a finisher/sous-chef MERGE-AS-VERB claim must have an operator-merge carve-out nearby.
for i, line in enumerate(lines):
    if not any(rx.search(line) for rx in DRIFT):
        continue
    lo, hi = max(0, i - WINDOW), min(len(lines), i + WINDOW + 1)
    if not any(CARVEOUT.search(lines[j]) for j in range(lo, hi)):
        print(f"UNGUARDED-MERGE:{i+1}: {line.strip()}")
PY
)"
if printf '%s\n' "$out" | grep -q '^SELFTEST-FAIL:'; then
  echo "$out"
  fail "the F8 drift-detection regexes rotted — a known-bad fixture is no longer flagged (F29 silent-guard tripwire)"
fi
if [ -n "$out" ]; then
  echo "$out"
  fail "Pi adapter SKILL attributes a merge to the finisher/sous-chef without an operator-merge carve-out (F8)"
fi

echo "PASS: the Pi adapter SKILL carries the operator-merge carve-out and no finisher/sous-chef merge attribution stands without it (F8)"
