#!/bin/bash
# idc-assert-class: doc
# pi-plan-recirculator-merge-posture.sh — W4: the Pi PLAN and RECIRCULATOR personas must stop at an
# OPERATOR-PERFORMED merge, and must never instruct a raw or autonomous self-merge.
#
# Why this lane exists. The `agents/idc-*.md` playbooks legitimately automerge through the sanctioned
# finisher — that is the documented Claude/Codex-runtime contract (`docs/architecture.md` §Runtime
# model). The Pi runtime is deliberately DIFFERENT: its residents prepare, push, and report evidence,
# and the OPERATOR performs the merge. That difference lives entirely in prose in
# `runtime/pi/.pi/agents/idc/{plan,recirculator}.md`, and until now only the BUILD-FINISHER persona had
# a guard over it (`tests/smoke/phase8-pi-finish-gate.sh`). A reviewer reading only the Claude playbooks
# repeatedly (mis)reads the Pi personas as able to merge; an edit that actually GAVE them that power —
# pasting in a `gh pr merge`, or the autonomous finisher invocation the Claude playbooks use — would
# have shipped uncaught. This makes that a failing check instead of a reviewer's catch.
#
# The invariant, asserted for BOTH personas:
#   (1) HAVE operator-performed-merge language;
#   (2) HAVE a prohibition on a raw / self-directed / automatic merge command;
#   (3) ABSENT `gh pr merge`  — the raw merge command;
#   (4) ABSENT `idc_pr_finish.py … autonomous` — the autonomous finisher, which merges with no human
#       touchpoint and is the Claude/Codex-runtime door, not Pi's.
#
# Matching is done over the file's WHOLE TEXT with whitespace normalized to single spaces, NOT
# line-by-line: both personas wrap these exact sentences mid-clause (recirculator.md breaks between
# "self-directed" and "merge command"), so a line-oriented grep would miss the very sentences that
# carry the invariant and report a false MISSING.
#
# F29 (the silent-guard trap this repo has hit repeatedly): checks (3) and (4) are SCANNERS whose
# answer on a healthy tree is SILENCE, so a rotted FORBIDDEN regex would disable them undetected and
# the next drift would ship. Step 0 feeds every regex — FORBIDDEN and REQUIRED alike — a canned
# known-bad / known-good fixture, so a regex regression FAILS THIS LANE instead of going quiet.
#
# Red-when-broken: delete the operator-merge sentence from either persona -> MISSING fires; paste
# `gh pr merge --squash` or the `idc_pr_finish.py autonomous` invocation into either -> FORBIDDEN
# fires; break any regex -> SELFTEST-FAIL fires.
#
# Usage: bash tests/smoke/governance/pi-plan-recirculator-merge-posture.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
PERSONAS="$PLUGIN/runtime/pi/.pi/agents/idc"
fail() { echo "FAIL: $1"; exit 1; }
for p in plan recirculator; do
  [ -f "$PERSONAS/$p.md" ] || fail "missing Pi persona: runtime/pi/.pi/agents/idc/$p.md"
done

out="$(python3 - "$PERSONAS/plan.md" "$PERSONAS/recirculator.md" 2>&1 <<'PY'
import re, sys

# Patterns are defined ONCE and shared by BOTH the self-test and the real scan, so a self-test failure
# is faithful proof that the very regexes doing the real scan have rotted.
REQUIRED = [
    ("operator-performed merge",
     re.compile(r"(?i)operator[- ]performed|operator (performs|must perform|merges)")),
    ("prohibition on a raw/self-directed/automatic merge command",
     re.compile(r"(?i)(do not|don't|never)[^.]{0,120}\b(raw|self[- ]directed|automatic)\b"
                r"[^.]{0,80}\bmerge\b")),
]
FORBIDDEN = [
    ("the raw merge command `gh pr merge`", re.compile(r"(?i)\bgh\s+pr\s+merge\b")),
    ("the autonomous finisher (`idc_pr_finish.py … autonomous`)",
     re.compile(r"(?i)idc_pr_finish\.py.{0,80}?\bautonomous\b")),
]

# (0) SELF-TEST against PLANTED fixtures (F29). Every REQUIRED regex gets a known-GOOD line it must
# match; every FORBIDDEN regex gets a known-BAD line it must flag. Each alternation branch is
# exercised separately, so dropping ANY branch is caught — a single fixture carrying them all would
# keep passing with two of three branches deleted.
REQUIRED_KNOWN_GOOD = [
    (0, "the integration merge is operator-performed"),          # `operator[- ]performed` (hyphen)
    (0, "the integration merge is operator performed"),           # ... and the space form
    (0, "the operator performs the merge"),                       # `operator (performs`
    (0, "the operator must perform the merge"),                   # `operator (must perform`
    (0, "the operator merges the planning PR"),                   # `operator (merges`
    (1, "do not run a raw or self-directed merge command"),       # plan.md's wording
    (1, "do not run a raw, automatic, or self-directed merge command"),   # recirculator.md's wording
    (1, "never run an automatic merge"),                          # `never` + `automatic` branches
    (1, "don't run a self directed merge"),                       # `don't` + space-form branch
]
FORBIDDEN_KNOWN_BAD = [
    (0, "then run `gh pr merge --squash --delete-branch` to land it"),
    (0, "gh   pr   merge"),                                       # guards the `\s+` tolerance
    (1, 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pr_finish.py" autonomous --repo "$PWD"'),
    (1, "run idc_pr_finish.py with the autonomous subcommand"),
]
for idx, sample in REQUIRED_KNOWN_GOOD:
    if not REQUIRED[idx][1].search(sample):
        print("SELFTEST-FAIL: REQUIRED[%d] (%s) no longer matches its known-good line: %r"
              % (idx, REQUIRED[idx][0], sample))
for idx, sample in FORBIDDEN_KNOWN_BAD:
    if not FORBIDDEN[idx][1].search(sample):
        print("SELFTEST-FAIL: FORBIDDEN[%d] (%s) no longer flags its known-bad line: %r"
              % (idx, FORBIDDEN[idx][0], sample))
# A REQUIRED regex loose enough to match anything proves nothing — assert each rejects a near-miss
# that omits the load-bearing word, so a regex degraded to `.*` is caught too.
REQUIRED_KNOWN_BAD = [
    (0, "the finisher merges the branch when green"),             # no operator anywhere
    (1, "do not force-push the branch"),                          # a prohibition, but not about merge
]
for idx, sample in REQUIRED_KNOWN_BAD:
    if REQUIRED[idx][1].search(sample):
        print("SELFTEST-FAIL: REQUIRED[%d] (%s) matched a line it must NOT: %r"
              % (idx, REQUIRED[idx][0], sample))

# The self-test ran to completion. Emit a sentinel the harness REQUIRES, so a python crash or an early
# exit that skips the fixtures can never be mistaken for a clean pass (F36).
print("SELFTEST-OK")

for path in sys.argv[1:]:
    name = path.rsplit("/", 1)[-1]
    raw = open(path, encoding="utf-8").read()
    # Normalize ALL whitespace (including newlines) to single spaces: both personas wrap these
    # sentences mid-clause, so a line-oriented match would false-report MISSING.
    text = re.sub(r"\s+", " ", raw)
    for label, rx in REQUIRED:
        if not rx.search(text):
            print("MISSING:%s: %s" % (name, label))
    for label, rx in FORBIDDEN:
        hit = rx.search(text)
        if hit:
            print("FORBIDDEN:%s: %s — found %r" % (name, label, hit.group(0)[:80]))
PY
)"
rc=$?
# F36: the self-test runs python under `$(...)` — capture its EXIT STATUS, not just its stdout. A regex
# broken to a COMPILE error raises out of the module-level pattern construction, yielding empty stdout
# and a NON-ZERO exit; without this check the empty stdout would skip both guards below and print PASS.
if [ "$rc" -ne 0 ]; then
  echo "$out"
  fail "the W4 self-test harness crashed (exit $rc — a regex that fails to COMPILE, or another python error)"
fi
if ! printf '%s\n' "$out" | grep -q '^SELFTEST-OK$'; then
  echo "$out"
  fail "the W4 self-test did not run to completion (no SELFTEST-OK sentinel) — its regexes were never exercised"
fi
if printf '%s\n' "$out" | grep -q '^SELFTEST-FAIL:'; then
  printf '%s\n' "$out" | grep '^SELFTEST-FAIL:'
  fail "the Pi merge-posture regexes rotted — a planted fixture is no longer classified correctly (F29 silent-guard tripwire)"
fi
if printf '%s\n' "$out" | grep -qE '^(MISSING|FORBIDDEN):'; then
  printf '%s\n' "$out" | grep -E '^(MISSING|FORBIDDEN):'
  fail "the Pi plan/recirculator personas no longer stop at an operator-performed merge (W4)"
fi

echo "PASS: the Pi plan + recirculator personas mandate an operator-performed merge, forbid a raw/self-directed/automatic merge command, and instruct neither \`gh pr merge\` nor the autonomous finisher (W4)"
