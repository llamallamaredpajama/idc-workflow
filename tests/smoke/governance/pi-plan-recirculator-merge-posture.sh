#!/bin/bash
# idc-assert-class: doc
# pi-plan-recirculator-merge-posture.sh — W4: the Pi PLAN and RECIRCULATOR personas must stop at an
# OPERATOR-PERFORMED merge, and must never instruct a raw or autonomous self-merge.
#
# Why this lane exists. The `agents/idc-*.md` playbooks legitimately automerge through the sanctioned
# finisher — that is the documented Claude/Codex-runtime contract (`docs/architecture.md` §Runtime
# model). The Pi runtime is deliberately DIFFERENT: its residents prepare, push, and report evidence,
# and the OPERATOR performs the merge. That difference lives entirely in prose in
# `runtime/pi/.pi/agents/idc/{plan,recirculator}.md`, and a reviewer reading only the Claude playbooks
# repeatedly (mis)reads the Pi personas as able to merge.
#
# WHAT WAS ALREADY COVERED, stated honestly. `tests/smoke/phase8-pi-finish-gate.sh` guards the
# BUILD-FINISHER persona, and `tests/smoke/phase8-pi-prompt-alignment.sh` ALREADY asserted
# operator-performed-merge language and the ABSENCE of `gh pr merge` on BOTH of these personas. So
# "pasting in a `gh pr merge` would have shipped uncaught" — which this header used to claim — is
# FALSE, and the earlier lane is what makes it false.
#
# WHAT IS GENUINELY NEW HERE, and why the lane is still worth its weight:
#   * the AUTONOMOUS FINISHER invocation (`idc_pr_finish.py … autonomous`) — the Claude/Codex-runtime
#     door that merges with no human touchpoint — was not asserted absent anywhere;
#   * raw `git merge`, the local merge command that trips none of the prose checks (see (5) below);
#   * WHOLE-TEXT matching with whitespace normalized, which catches the invariant sentences these two
#     personas wrap mid-clause and a line-oriented grep reports as falsely MISSING;
#   * the regex SELF-TEST (F29 shape): every pattern is proven to match a planted positive and reject
#     a planted negative, so a pattern that silently stopped matching cannot leave the lane green.
#
# The invariant, asserted for BOTH personas:
#   (1) HAVE operator-performed-merge language;
#   (2) HAVE a prohibition on a raw / self-directed / automatic merge command;
#   (3) ABSENT `gh pr merge`  — the raw merge command;
#   (4) ABSENT `idc_pr_finish.py … autonomous` — the autonomous finisher, which merges with no human
#       touchpoint and is the Claude/Codex-runtime door, not Pi's;
#   (5) ABSENT `git merge` — the raw LOCAL merge command. (1)+(2) are prose checks, and prose is not
#       semantics: a sentence can promise an operator-performed merge, forbid a "raw" merge command,
#       and still instruct `git merge --ff-only` + push. That near-miss trips neither (3) nor (4), so
#       it is planted as a known-bad fixture and (5) is what catches it.
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
    # EVERY branch must tie the operator to a MERGE (F46). The original first branch was a bare
    # `operator[- ]performed`, and `operator (performs|must perform)` was equally unanchored, so any
    # unrelated "the operator-performed review is required" / "the operator performs the verification"
    # satisfied this check. A persona that lost its operator-merge handoff but kept some other
    # operator-performed phrase would still have passed REQUIRED[0]. Proximity is bounded by
    # `[^.]{0,80}` (sentence-local, like REQUIRED[1]) and asserted in BOTH orders, because the real
    # personas write it both ways ("the integration merge is operator-performed" and "the operator
    # performs the merge"). The known-BAD fixtures below pin the tightening.
    ("operator-performed merge",
     re.compile(r"(?i)\bmerge\b[^.]{0,80}operator[- ]performed"
                r"|operator[- ]performed[^.]{0,80}\bmerge\b"
                r"|operator (performs|must perform)[^.]{0,80}\bmerge\b"
                r"|operator merges")),
    ("prohibition on a raw/self-directed/automatic merge command",
     re.compile(r"(?i)(do not|don't|never)[^.]{0,120}\b(raw|self[- ]directed|automatic)\b"
                r"[^.]{0,80}\bmerge\b")),
]
FORBIDDEN = [
    ("the raw merge command `gh pr merge`", re.compile(r"(?i)\bgh\s+pr\s+merge\b")),
    ("the autonomous finisher (`idc_pr_finish.py … autonomous`)",
     re.compile(r"(?i)idc_pr_finish\.py.{0,80}?\bautonomous\b")),
    # `git merge` is the OTHER way to land the branch yourself, and the original spec named only
    # `gh pr merge` + the autonomous finisher. That left a real gap: a persona sentence can satisfy
    # BOTH required regexes (it says the merge is operator-performed, and it forbids a "raw" merge
    # command) while still instructing a local `git merge --ff-only` + push — a self-merge by another
    # name, which neither FORBIDDEN pattern saw. The near-miss is planted below as a known-bad line.
    ("the raw local merge command `git merge`", re.compile(r"(?i)\bgit\s+merge\b")),
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
    (2, "run `git merge --ff-only integration/x` and push"),
    (2, "git   merge"),                                           # guards the `\s+` tolerance
    # THE NEAR-MISS that motivated FORBIDDEN[2] (reviewer-crafted, verified): it satisfies BOTH
    # REQUIRED regexes and trips NEITHER of the original two FORBIDDEN patterns, yet directs a
    # self-merge. Planting it here means the gap stays closed — if FORBIDDEN[2] is ever dropped or
    # loosened, this line stops being flagged and the self-test fails.
    (2, "the integration merge is operator-performed: do not run a raw or automatic merge command; "
        "when CI is green, run git merge --ff-only and push the result yourself"),
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
    # F46: an operator phrase with NO merge in it must NOT satisfy REQUIRED[0]. These are the exact
    # shapes the pre-F46 regex waved through — a persona could drop its merge handoff entirely, keep
    # one of these sentences, and still pass. One fixture per unanchored branch that was tightened.
    (0, "the operator-performed review is required before the gate closes"),
    (0, "the operator performs the verification and records the receipts"),
    (0, "the operator must perform the checks listed above"),
    # The proximity bound is load-bearing too: a merge mentioned in a DIFFERENT sentence is not the
    # operator-merge mandate. A period ends the `[^.]{0,80}` run, so this must not match either.
    (0, "the operator performs the review. the finisher handles the merge"),
    (1, "do not force-push the branch"),                          # a prohibition, but not about merge
]
for idx, sample in REQUIRED_KNOWN_BAD:
    if REQUIRED[idx][1].search(sample):
        print("SELFTEST-FAIL: REQUIRED[%d] (%s) matched a line it must NOT: %r"
              % (idx, REQUIRED[idx][0], sample))

# The near-miss is only a NEAR-miss if the REQUIRED checks genuinely wave it through — that is exactly
# why a FORBIDDEN command scanner has to catch it. Assert both halves, so this stays a proof that the
# REQUIRED prose checks CANNOT stand in for the command scanners rather than a bare extra fixture.
NEAR_MISS = ("the integration merge is operator-performed: do not run a raw or automatic merge "
             "command; when CI is green, run git merge --ff-only and push the result yourself")
for idx in (0, 1):
    if not REQUIRED[idx][1].search(NEAR_MISS):
        print("SELFTEST-FAIL: the near-miss no longer satisfies REQUIRED[%d] (%s), so it no longer "
              "demonstrates that prose checks cannot catch a self-merge instruction" % (idx, REQUIRED[idx][0]))
if not any(rx.search(NEAR_MISS) for _label, rx in FORBIDDEN):
    print("SELFTEST-FAIL: NO FORBIDDEN pattern flags the near-miss self-merge instruction — a persona "
          "could mandate an operator-performed merge and still direct a `git merge` self-merge")

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
