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

out="$(python3 - "$SKILL" 2>&1 <<'PY'
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
# Exercise EVERY alternation branch and tolerance of BOTH DRIFT regexes, so a break in ANY branch —
# not just the one an incidental fixture happens to hit — fails the lane (F37 closed the gaps below):
#   DRIFT[0] `(sous[- ]chef|finisher)\s+\*{0,2}merges` — both role forms, the `\s+` (a TAB must still
#     match, so a literal-space mutation is caught), and the `\*{0,2}` bold tolerance;
#   DRIFT[1] `\b(does|do)\s+the\s+finisher\s+\*{0,2}merge` — BOTH the `does` and the `do` branch, and
#     its `\*{0,2}` bold tolerance.
DRIFT_KNOWN_BAD = [
    (0, "On the Pi runtime the sous-chef merges the staging branch under the board-backed lease."),
    (0, "the sous chef **merges** that branch"),                 # space-form + bold variant of DRIFT[0]
    (0, "the finisher merges the integration branch"),           # the finisher branch of DRIFT[0]
    (0, "the sous-chef\tmerges the branch"),                     # TAB separator — guards DRIFT[0] `\s+`
    (1, "only then does the finisher merge the integration ref"),  # DRIFT[1] `does` branch
    (1, "do the finisher **merge** the branch"),                 # DRIFT[1] `do` branch + bold tolerance
]
for idx, sample in DRIFT_KNOWN_BAD:
    if not DRIFT[idx].search(sample):
        print(f"SELFTEST-FAIL: DRIFT[{idx}] no longer flags its known-bad line: {sample!r}")
# Assert EACH CARVEOUT alternative independently, so dropping any one alternation branch is caught (a
# single line carrying all three would keep passing even if two branches were deleted).
CARVEOUT_KNOWN_GOOD = [
    "the finisher does not self-merge",                          # alternative 1
    "the integration merge is operator-performed",               # alternative 2
    "the operator merge happens only after the lease is taken",  # alternative 3
]
for sample in CARVEOUT_KNOWN_GOOD:
    if not CARVEOUT.search(sample):
        print(f"SELFTEST-FAIL: CARVEOUT no longer matches its known carve-out: {sample!r}")

# The self-test ran to completion (no DRIFT regex failed to COMPILE — a compile error would have raised
# out of the `DRIFT = [...]` construction above and exited non-zero, which the harness treats as a
# crash). Emit an explicit sentinel the harness REQUIRES, so a python crash or an early exit that skips
# the fixtures can never be mistaken for a clean pass (F36).
print("SELFTEST-OK")

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
rc=$?
# F36: the self-test runs python under `$(...)` — capture its EXIT STATUS, not just its stdout. A DRIFT
# regex broken to a COMPILE error (or any python crash) raises out of the module-level `DRIFT = [...]`,
# yielding empty stdout and a NON-ZERO exit; without this check the empty stdout skipped both guards
# below and the lane printed PASS. The `2>&1` above folds the traceback into `$out` so the crash reason
# is visible. Any non-zero exit is a harness failure, not a clean pass.
if [ "$rc" -ne 0 ]; then
  echo "$out"
  fail "the F29 self-test harness crashed (exit $rc — a DRIFT regex that fails to COMPILE, or another python error)"
fi
# F36 (defense in depth): the self-test must have run to completion and emitted its sentinel. A python
# path that exits 0 but skips the fixtures (an early return, a swallowed exception) is caught here.
if ! printf '%s\n' "$out" | grep -q '^SELFTEST-OK$'; then
  echo "$out"
  fail "the F29 self-test did not run to completion (no SELFTEST-OK sentinel) — its regexes were never exercised"
fi
if printf '%s\n' "$out" | grep -q '^SELFTEST-FAIL:'; then
  echo "$out"
  fail "the F8 drift-detection regexes rotted — a known-bad fixture is no longer flagged (F29 silent-guard tripwire)"
fi
# Real-scan findings use explicit prefixes, so match those exactly rather than "any output" (the
# SELFTEST-OK sentinel is expected output and must not be mistaken for a drift finding).
if printf '%s\n' "$out" | grep -qE '^(UNGUARDED-MERGE|MISSING-CARVEOUT)'; then
  printf '%s\n' "$out" | grep -E '^(UNGUARDED-MERGE|MISSING-CARVEOUT)'
  fail "Pi adapter SKILL attributes a merge to the finisher/sous-chef without an operator-merge carve-out (F8)"
fi

echo "PASS: the Pi adapter SKILL carries the operator-merge carve-out and no finisher/sous-chef merge attribution stands without it (F8)"
