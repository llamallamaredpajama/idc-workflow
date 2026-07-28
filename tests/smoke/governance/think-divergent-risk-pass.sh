#!/bin/bash
# idc-assert-class: doc
# think-divergent-risk-pass.sh — prose invariants for Think's OPT-IN divergent risk pass (Part 3a)
# and the recorded model-authored-orchestration boundary in docs/architecture.md (Part 3b).
#
# This pass is deliberately UNENFORCED code-wise: it is human-invoked and its whole output is
# human-gated, so it ships as playbook prose with NO script, NO validator, and NO trigger predicate
# (the Plan-stage sibling `scripts/idc_validation_risk_gate.py` is the enforced one). Prose with no
# code behind it rots silently, so these greps are its only regression guard — each one is
# red-when-broken: delete or reword the invariant line in the shipped markdown and the matching
# assertion FAILs.
#
# Proves commands/think.md states:
#   (A) the pass is OPT-IN — never run by default, only when the operator asks, no trigger predicate;
#   (B) all four lens names stay on the menu a branch draws its distinct lens from (user-confusion,
#       broken-expectation, churn, promised-but-missing), and the 3–5 branch bound on the fan-out;
#   (C) the fixed four-field candidate shape, cross-checked BYTE-IDENTICAL against the Plan-stage
#       falsifier's CANDIDATE_KEYS so the two surfaces cannot drift apart in either direction;
#   (D) the branch DIGESTS feed the PRD draft BEFORE the human gate;
#   (E) the branches are READ-ONLY and spawn ZERO DURABLE WORKERS;
# and that docs/architecture.md records:
#   (F) the standing boundary — model-authored orchestration is welcome for read-only fan-outs, while
#       admission/scheduling/tracker-mutation/completion always go through fixed validators, never a
#       generated script — placed inside the load-bearing "Write-authority boundaries" section.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
THINK="$PLUGIN/commands/think.md"
RISK="$PLUGIN/scripts/idc_validation_risk_gate.py"
ARCH="$PLUGIN/docs/architecture.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$THINK" ] || fail "commands/think.md missing"
[ -f "$RISK" ] || fail "scripts/idc_validation_risk_gate.py missing (the Plan-stage falsifier this pass keeps schema parity with)"
[ -f "$ARCH" ] || fail "docs/architecture.md missing"

# The invariants below span wrapped markdown lines and carry ** emphasis, so a line-anchored grep
# would be brittle: extract the divergent-pass step, flatten whitespace, and strip emphasis markers
# first. Scoping to the STEP (not the whole file) is what keeps each assertion honest — a phrase that
# happens to appear elsewhere in think.md cannot satisfy it.
#
# The '## How to run it' SECTION is carved out FIRST and the step is anchored as a numbered list item
# INSIDE it. A file-wide search would let the whole step be lifted out of the numbered playbook and
# pasted anywhere in think.md — as loose prose above the heading, or under Boundaries — byte-identical
# and still green, while the operator-facing procedure silently lost the step. Placement IS the
# invariant here: an instruction that is not in the list Think executes is not an instruction.
SECTION="$WORK/think-divergent-step.txt"
python3 - "$THINK" > "$SECTION" <<'PY' || fail "commands/think.md no longer contains an opt-in 'Divergent risk pass' step in its How-to-run-it list"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec = re.search(r'^## How to run it\s*$(.*?)(?=^## |\Z)', text, re.M | re.S)
if not sec:
    sys.exit("could not locate the '## How to run it' section of commands/think.md")
m = re.search(r'^\s*\d+\.\s+\*\*Divergent risk pass(.*?)Crystallize', sec.group(1), re.M | re.S)
if not m:
    sys.exit("could not locate a NUMBERED 'Divergent risk pass' step inside '## How to run it' "
             "(anchored between the numbered step heading and 'Crystallize') — a step that lives "
             "outside the how-to-run-it list is not part of the procedure Think executes")
body = re.sub(r'\s+', ' ', m.group(1)).replace('*', '').strip()
if not body:
    sys.exit("the 'Divergent risk pass' step in commands/think.md's '## How to run it' list is empty "
             "— the anchors matched back-to-back, so every invariant below would be vacuously checked")
print(body)
PY
insection() { grep -qiE "$1" "$SECTION"; }

# --- (A) opt-in trigger: never by default, only on operator request, no trigger predicate ----------
insection 'never run by default' \
  || fail "think.md's divergent risk pass must state it is NEVER run by default (an always-on fan-out exceeds Think's zero-durable-worker conversational budget)"
# Matched as "fires only when the operator asks", not the bare phrase: the step's own bold heading
# already reads "opt-in, and only when the operator asks", so a loose grep would be satisfied by the
# heading and would stay GREEN even after the body stopped requiring an operator request.
insection 'fires only when the operator asks' \
  || fail "think.md's divergent risk pass must state it FIRES ONLY when the operator asks (it is human-invoked, not inferred from the topic)"
insection 'no trigger predicate' \
  || fail "think.md's divergent risk pass must state it has NO trigger predicate (the deliberate difference from Plan's deterministically-gated falsifier)"

# --- (B) the four distinct lenses, and the bound on how many branches carry them -------------------
for lens in user-confusion broken-expectation churn promised-but-missing; do
  insection "(^|[^a-z-])$lens([^a-z-]|$)" \
    || fail "think.md's divergent risk pass must name the '$lens' lens — all four lenses must stay on the menu, or the fan-out stops being perspective-diverse"
done
# The shipped text writes the range with a U+2013 EN DASH, not an ASCII hyphen, so the dash is matched
# as an explicit two-character alternation. A literal '-' here would never match and the assertion
# would ship inert — green no matter what the branch count became.
insection '3(–|-)5 bounded branches' \
  || fail "think.md's divergent risk pass must bound the fan-out at 3–5 BOUNDED BRANCHES (the one numeric limit in the step; an unbounded 'as many branches as the topic needs' fan-out breaks Think's conversational budget)"

# --- (C) the fixed four-field candidate shape, byte-identical to Plan's CANDIDATE_KEYS -------------
KEYS="$(python3 - "$RISK" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^CANDIDATE_KEYS\s*=\s*\[(.*?)\]', src, re.M | re.S)
if not m:
    sys.exit("could not read CANDIDATE_KEYS from scripts/idc_validation_risk_gate.py")
print("\n".join(re.findall(r'"([^"]+)"', m.group(1))))
PY
)" || fail "could not read CANDIDATE_KEYS out of scripts/idc_validation_risk_gate.py (the Plan-stage schema this pass mirrors)"
nkeys="$(printf '%s\n' "$KEYS" | grep -c .)"
[ "$nkeys" -eq 4 ] \
  || fail "expected exactly 4 CANDIDATE_KEYS in scripts/idc_validation_risk_gate.py, read $nkeys — Think's four-field shape and Plan's have diverged"
while read -r key; do
  [ -n "$key" ] || continue
  insection "(^|[^a-z_])$key([^a-z_]|$)" \
    || fail "think.md's divergent risk pass must return the '$key' field — the candidate shape must stay byte-identical to Plan's CANDIDATE_KEYS so a Think-found risk carries into a Plan gate untranslated"
done <<<"$KEYS"

# --- (D) the digests feed the PRD draft BEFORE the human gate --------------------------------------
insection 'digests?[^.]{0,160}PRD draft before the human gate' \
  || fail "think.md's divergent risk pass must fold the branch DIGESTS into the PRD draft BEFORE the human gate (findings that land after the gate route around the operator's one checkpoint)"

# --- (E) read-only branches, zero durable workers --------------------------------------------------
insection 'read-only' \
  || fail "think.md's divergent risk pass must declare the branches READ-ONLY (a writing branch would give discovery authority)"
insection 'zero durable workers' \
  || fail "think.md's divergent risk pass must declare ZERO DURABLE WORKERS (Think's standing budget is no teammates)"

# --- (F) the recorded model-authored-orchestration boundary, in Write-authority boundaries ---------
# Scoped to that section for the same reason as above: recording the refusal in a stray appended
# section is exactly the placement that future sessions fail to find and then relitigate.
DOCTRINE="$WORK/arch-write-authority.txt"
python3 - "$ARCH" > "$DOCTRINE" <<'PY' || fail "docs/architecture.md no longer has a '## Write-authority boundaries' section to carry the model-authored-orchestration boundary"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# `\Z` in the lookahead so the section is still found when it is the LAST one in the file. With a
# bare `(?=^## )` this fail-closes on a correct document with the wrong reason ("could not locate
# the section"), which sends the next reader hunting for a deletion that never happened.
m = re.search(r'^## Write-authority boundaries\s*$(.*?)(?=^## |\Z)', text, re.M | re.S)
if not m:
    sys.exit("could not locate the '## Write-authority boundaries' section")
body = re.sub(r'\s+', ' ', m.group(1)).replace('*', '').strip()
if not body:
    sys.exit("the '## Write-authority boundaries' section of docs/architecture.md is empty — the "
             "heading survived but its body did not, so every invariant below would be vacuously checked")
print(body)
PY
indoctrine() { grep -qiE "$1" "$DOCTRINE"; }
indoctrine 'model-authored orchestration is welcome for read-only fan-outs' \
  || fail "docs/architecture.md's Write-authority boundaries section must record that model-authored orchestration IS welcome for read-only fan-outs (the permitted half of the boundary)"
indoctrine 'admission, scheduling, tracker mutation, and completion always go through fixed validators' \
  || fail "docs/architecture.md's Write-authority boundaries section must record that admission, scheduling, tracker mutation, and completion always go through FIXED VALIDATORS (the refused half of the boundary)"
indoctrine 'never through a script the model generated' \
  || fail "docs/architecture.md's Write-authority boundaries section must record that authority never runs through a model-generated script (the explicit refusal, so future sessions do not relitigate it)"

echo "PASS: Think's divergent risk pass is a numbered step of '## How to run it' — opt-in, four-lensed, bounded at 3–5 branches, schema-parity with Plan's falsifier, digest-fed before the human gate, read-only with zero durable workers; and the model-authored-orchestration boundary is recorded under Write-authority boundaries"
