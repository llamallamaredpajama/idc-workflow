#!/bin/bash
# idc-assert-class: behavior
# doctor-honest-claim.sh — U10: /idc:doctor must FAIL a filesystem-backed repo that claims hard
# pathway security.
#
# Spec §2.1, final sentence: "The filesystem tracker remains useful for hermetic tests and local
# demonstrations. It MUST NOT claim hard pathway security. `/idc:doctor` MUST fail a `controlled` or
# `app-locked` configuration that uses the filesystem backend."
#
# U9 already refuses to SCAFFOLD such a repo (idc_init_scaffold.sh), but a scaffold door only guards
# creation time: a repo whose WORKFLOW-config.yaml is hand-edited to `controlled` after the fact —
# or one adopted from elsewhere — sails past it and then reads as fully governed. Doctor is the
# standing diagnostic, so doctor is where the claim gets re-checked on every run.
#
# What this scenario proves, on hermetic throwaway repos (no git, no network, no board):
#   1. the deterministic door `scripts/idc_doctor_pathway_check.py` classifies a repo honestly —
#      0 honest, 1 dishonest (filesystem + controlled/app-locked), 2 INDETERMINATE;
#   2. indeterminate is NEVER an honest PASS. This is the sharp edge: the shipped Path Gate parser
#      (idc_path_gate.pathway_mode) returns "off" when the config cannot be opened at all
#      (scripts/idc_path_gate.py `except OSError: return "off"`), so a door that simply asks the
#      parser reports a MISSING config as the honest `off` posture. The door must therefore do its
#      OWN existence/readability check first and answer "cannot tell" — never "honest";
#   3. commands/doctor.md actually WIRES that door into a check row that maps exit 1 AND exit 2 to
#      FAIL with a fix hint. A door nobody calls diagnoses nothing.
#
# Red-when-broken (each mutation was run):
#   * delete the honest-claim row from commands/doctor.md (leaving the script) => the doctor.md
#     wiring assertions fail;
#   * neuter the door's filesystem+controlled branch (always exit 0) => cases 4/5 fail;
#   * collapse indeterminate to honest (exit 2 -> 0 on a missing/unreadable config) => cases 6-10 and
#     the never-honest assertions fail.
#
# Usage: bash tests/smoke/governance/doctor-honest-claim.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DOOR="$GOV_PLUGIN/scripts/idc_doctor_pathway_check.py"
DOCTOR_MD="$GOV_PLUGIN/commands/doctor.md"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
# u+rwX first: one fixture deliberately chmod 000s a file, which would otherwise defeat rm -rf.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ── the doctor.md row, extracted by its own header ────────────────────────────────────────────────
# Numbering is doctor.md's business (it uses 1..10 with lettered sub-rows 5b/9b/9c), so match the row
# by NAME, not by a hardcoded number: any `**<n>[a-z]? — …pathway enforcement claim…**` header.
extract_row() {
  python3 - "$DOCTOR_MD" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError as exc:
    sys.exit(f"commands/doctor.md unreadable: {exc}")
heads = list(re.finditer(r'^\*\*(\d+[a-z]?) — .*$', text, re.M))
hits = [i for i, m in enumerate(heads) if re.search(r'pathway enforcement claim', m.group(0), re.I)]
if not hits:
    sys.exit(1)
i = hits[0]
end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
sys.stdout.write(text[heads[i].start():end])
PY
}

# ── existence gate: report BOTH halves of the surface, so a RED run names the whole gap ───────────
GAPS=""
[ -f "$DOOR" ] || GAPS="$GAPS
        - scripts/idc_doctor_pathway_check.py is missing (the deterministic honest-claim door)"
ROW="$(extract_row)" || GAPS="$GAPS
        - commands/doctor.md carries no pathway-enforcement honest-claim check row"
[ -n "$GAPS" ] && gov_fail "the doctor honest-claim surface (spec §2.1) is not implemented:$GAPS"

# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
# mkfixture <name> <backend|-> <mode|->  -> echoes the repo path ('-' omits that config file)
mkfixture() {
  local name="$1" backend="$2" mode="$3" d="$WORK/$1"
  mkdir -p "$d/docs/workflow" || return 1
  [ "$backend" = "-" ] || printf 'backend: %s\nproject_number: 7\n' "$backend" \
    > "$d/docs/workflow/tracker-config.yaml" || return 1
  [ "$mode" = "-" ] || printf 'pathway_enforcement:\n  mode: %s\n  attempt_ceiling: 3\n' "$mode" \
    > "$d/WORKFLOW-config.yaml" || return 1
  printf '%s' "$d"
}

# door <repo> -> sets RC / OUT / ERR
door() {
  OUT="$(python3 "$DOOR" --repo "$1" 2>"$WORK/.err")"; RC=$?
  ERR="$(cat "$WORK/.err" 2>/dev/null)"
  return 0
}

# The honest verdict token the door prints on stdout when the claim checks out. An indeterminate run
# must never emit it on EITHER stream — "cannot tell" read as "clean" is the exact false-green this
# scenario exists to prevent.
HONEST_TOKEN='pathway-claim: honest'

assert_rc() {  # <expected> <label>
  [ "$RC" = "$1" ] \
    || gov_fail "$2: expected exit $1, got $RC — stdout=[$OUT] stderr=[$ERR]"
}

assert_not_honest() {  # <label>  (never an honest verdict, on either stream)
  printf '%s\n%s\n' "$OUT" "$ERR" | grep -qF "$HONEST_TOKEN" \
    && gov_fail "$1: an INDETERMINATE run emitted the honest verdict token '$HONEST_TOKEN' — \
'could not determine' must never read as a clean pathway claim (stdout=[$OUT] stderr=[$ERR])"
  return 0
}

# ── 1-2. github backend: an enforcing claim is honest ─────────────────────────────────────────────
d="$(mkfixture gh-controlled github controlled)" || gov_fail "fixture gh-controlled failed"
door "$d"; assert_rc 0 "github backend claiming controlled"
printf '%s' "$OUT" | grep -qF "$HONEST_TOKEN" \
  || gov_fail "an honest run must print the '$HONEST_TOKEN' verdict on stdout, got [$OUT]"

d="$(mkfixture gh-applocked github app-locked)" || gov_fail "fixture gh-applocked failed"
door "$d"; assert_rc 0 "github backend claiming app-locked"

# ── 3. filesystem backend declaring `off` is honest — it claims nothing ───────────────────────────
d="$(mkfixture fs-off filesystem off)" || gov_fail "fixture fs-off failed"
door "$d"; assert_rc 0 "filesystem backend declaring off"

# ── 4. filesystem + controlled: the dishonest claim spec §2.1 names ───────────────────────────────
d="$(mkfixture fs-controlled filesystem controlled)" || gov_fail "fixture fs-controlled failed"
door "$d"; assert_rc 1 "filesystem backend claiming controlled"
printf '%s' "$ERR" | grep -qi 'filesystem' \
  || gov_fail "the refusal must NAME the filesystem backend so the operator knows which half is \
wrong, got stderr=[$ERR]"
printf '%s' "$ERR" | grep -qi 'controlled' \
  || gov_fail "the refusal must name the claimed mode ('controlled'), got stderr=[$ERR]"
[ -n "$ERR" ] \
  || gov_fail "the refusal must be a NAMED one-line diagnostic on stderr, not a silent exit 1"
printf '%s\n%s\n' "$OUT" "$ERR" | grep -qF "$HONEST_TOKEN" \
  && gov_fail "a dishonest repo must never emit the honest verdict token (stdout=[$OUT])"

# the door is a read-only diagnostic: it must not repair, rewrite or create anything
BEFORE="$(cd "$d" && find . -type f | sort | xargs cksum 2>/dev/null)"
door "$d"
AFTER="$(cd "$d" && find . -type f | sort | xargs cksum 2>/dev/null)"
[ "$BEFORE" = "$AFTER" ] \
  || gov_fail "the door mutated the repo it inspected — doctor's contract is strictly read-only"
# and it is deterministic: same repo, same answer, same text
RC1="$RC"; OUT1="$OUT"; ERR1="$ERR"
door "$d"
[ "$RC" = "$RC1" ] && [ "$OUT" = "$OUT1" ] && [ "$ERR" = "$ERR1" ] \
  || gov_fail "the door is not deterministic: run1=($RC1)[$OUT1][$ERR1] run2=($RC)[$OUT][$ERR]"

# ── 5. filesystem + app-locked: the same refusal ──────────────────────────────────────────────────
d="$(mkfixture fs-applocked filesystem app-locked)" || gov_fail "fixture fs-applocked failed"
door "$d"; assert_rc 1 "filesystem backend claiming app-locked"
printf '%s' "$ERR" | grep -qi 'app-locked' \
  || gov_fail "the refusal must name the claimed mode ('app-locked'), got stderr=[$ERR]"

# ── 6. MISSING WORKFLOW-config.yaml => indeterminate, never honest ────────────────────────────────
# The trap: idc_path_gate.pathway_mode() returns "off" for a config it cannot open, so a door that
# only asks the parser reports this repo as the honest `off` posture.
d="$(mkfixture fs-noconfig filesystem -)" || gov_fail "fixture fs-noconfig failed"
door "$d"; assert_rc 2 "filesystem backend with NO WORKFLOW-config.yaml"
assert_not_honest "missing WORKFLOW-config.yaml"
[ -n "$ERR" ] || gov_fail "an indeterminate verdict must carry a named diagnostic on stderr"

# ── 7. UNREADABLE WORKFLOW-config.yaml => indeterminate ───────────────────────────────────────────
# Two shapes: a directory in its place (deterministic everywhere, and the parser's own open() raises
# IsADirectoryError there — an OSError it swallows into "off"), and a chmod 000 file (skipped when
# the test user can read it anyway, e.g. running as root).
d="$(mkfixture fs-dirconfig filesystem -)" || gov_fail "fixture fs-dirconfig failed"
mkdir -p "$d/WORKFLOW-config.yaml" || gov_fail "could not seed the directory-shaped config"
door "$d"; assert_rc 2 "WORKFLOW-config.yaml is a directory"
assert_not_honest "directory-shaped WORKFLOW-config.yaml"

d="$(mkfixture fs-chmodconfig filesystem controlled)" || gov_fail "fixture fs-chmodconfig failed"
chmod 000 "$d/WORKFLOW-config.yaml" || gov_fail "chmod 000 failed"
if head -c 1 "$d/WORKFLOW-config.yaml" >/dev/null 2>&1; then
  echo "  note: chmod 000 is still readable by this user (root?) — the directory-shaped arm above covers unreadable"
else
  door "$d"; assert_rc 2 "unreadable (chmod 000) WORKFLOW-config.yaml"
  assert_not_honest "unreadable WORKFLOW-config.yaml"
fi
chmod 644 "$d/WORKFLOW-config.yaml" 2>/dev/null

# ── 8-10. an undeterminable BACKEND is indeterminate too ──────────────────────────────────────────
d="$(mkfixture no-tracker-config - controlled)" || gov_fail "fixture no-tracker-config failed"
door "$d"; assert_rc 2 "no docs/workflow/tracker-config.yaml"
assert_not_honest "missing tracker-config.yaml"

d="$(mkfixture backendless - controlled)" || gov_fail "fixture backendless failed"
printf 'project_number: 7\nfield_ids:\n  Status: ""\n' > "$d/docs/workflow/tracker-config.yaml" \
  || gov_fail "could not seed a backendless tracker-config.yaml"
door "$d"; assert_rc 2 "tracker-config.yaml carrying no backend: key"
assert_not_honest "tracker-config.yaml with no backend key"

d="$(mkfixture unknown-backend notion controlled)" || gov_fail "fixture unknown-backend failed"
door "$d"; assert_rc 2 "an unrecognized backend value"
assert_not_honest "unrecognized backend value"

# ── 11. commands/doctor.md wires the door into a real check row ───────────────────────────────────
printf '%s' "$ROW" | grep -qF 'idc_doctor_pathway_check.py' \
  || gov_fail "doctor.md's pathway honest-claim row does not RUN the door \
(scripts/idc_doctor_pathway_check.py) — a row that asserts the rule in prose only diagnoses nothing"
printf '%s' "$ROW" | grep -qF -- '--repo' \
  || gov_fail "doctor.md's honest-claim row must run the door against the governed repo (--repo)"

ROW_TEXT="$ROW" python3 - <<'PY' || gov_fail "doctor.md's honest-claim row does not map the door's exits to FAIL (see above)"
import os, re, sys
row = os.environ["ROW_TEXT"]
# Each exit bullet: from `- exit **N**` to the next top-level `- ` bullet (or the end of the row).
bullets = re.split(r'\n(?=- )', row)
def bullet_for(code):
    hits = [b for b in bullets if re.search(r'exit\s+\*\*%s\*\*' % code, b)]
    return hits[0] if hits else None
problems = []
for code, why in ((1, "a filesystem repo claiming controlled/app-locked"),
                  (2, "an indeterminate claim (missing/unreadable config or backend)")):
    b = bullet_for(code)
    if b is None:
        problems.append(f"the row has no `exit **{code}**` bullet ({why})")
        continue
    if "FAIL" not in b:
        problems.append(f"the `exit **{code}**` bullet ({why}) does not map to FAIL: {b.strip()!r}")
    if not re.search(r'fix hint', b, re.I):
        problems.append(f"the `exit **{code}**` bullet carries no one-line fix hint: {b.strip()!r}")
b2 = bullet_for(2)
if b2 and re.search(r'\bPASS\b', b2) and not re.search(r'never\s+(a\s+)?PASS|not\s+(a\s+)?PASS', b2, re.I):
    problems.append("the `exit **2**` bullet mentions PASS without saying indeterminate is NEVER a PASS")
b0 = bullet_for(0)
if b0 is None or "PASS" not in b0:
    problems.append("the row has no `exit **0**` -> PASS bullet (the honest case is unstated)")
if problems:
    sys.stderr.write("\n".join("        " + p for p in problems) + "\n")
    sys.exit(1)
PY

echo "PASS: the doctor honest-claim door classifies filesystem/controlled as dishonest, never reads \
an unreadable config as honest, and commands/doctor.md maps its exits 1/2 to FAIL"
