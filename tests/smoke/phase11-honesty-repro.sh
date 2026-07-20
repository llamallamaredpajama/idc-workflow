#!/bin/bash
# idc-assert-class: behavior
# Phase 11 (PR #163 completion-honesty repro) — the defects the static review of PR #163 named, each
# reproduced against the REAL shipped helpers so the fix has something that can go from red to green.
#
# WHY A SEPARATE SUITE. Every assertion below was RED at aa4879f while `bash tests/smoke/run-all.sh`
# reported ALL GREEN. That gap is the point: the existing suites cover the happy path and ordinary
# failures of the completion-honesty work, so "smoke is green" was not evidence that these hold. Each
# case here executes a real helper and asserts on its real output — no prose greps.
#
# RED-WHEN-BROKEN. Each case states the single source edit that turns it red again once fixed. These
# were observed red on the base commit BEFORE any fix existed (that is what a repro suite is), so the
# direction proven here is "red without the fix"; the implementer must additionally observe each case
# go red under its named mutation AFTER the fix lands, and record that in this header.
#
#   * R1  restore truncate-then-redact in idc_live_check.run_verify (`redact(_tail(out, …))`)
#            ⇒ R1 RED (a named credential straddling the 4 KB display cut reaches the receipt).
#   * R3  drop the plugin-root resolution in idc_pause_check's cure strings
#            ⇒ R3 RED (the printed recovery command points at `/scripts/...`).
#   * R9  relax the Stop gate's pause-record check back to `rec.get("state") == "paused"`
#            ⇒ R9 RED (a one-key handwritten file buys an undrained stop).
#   * R10 drop the "skip the current pause lifecycle record" rule in close_open_commands
#            ⇒ R10 RED (every honest pause reports a REFUSED line about itself and exits 1).
#   * R13 accept an absolute / traversing `evidence:` destination in surface_spec
#            ⇒ R13 RED (a receipt can truncate a file outside the repo).
#   * R17 revert the README command table to ten entries
#            ⇒ R17 RED (the public table disagrees with the shipped command set).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/smoke-path-preflight.sh"
PLUGIN="$(cd "$HERE/../.." && pwd)"

LIVE="$PLUGIN/scripts/idc_live_check.py"
PC="$PLUGIN/scripts/idc_pause_check.py"
PS="$PLUGIN/scripts/idc_pause_state.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
GATE="$PLUGIN/scripts/hooks/idc_stop_fixpoint_gate.py"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
for f in "$LIVE" "$PC" "$PS" "$TRK" "$GATE"; do
  [ -f "$f" ] || fail "missing helper: $f"
done
export IDC_PLUGIN="$PLUGIN"

# A governed filesystem repo with real git — the substrate a real run has.
mkrepo() { # $1 = dir
  local r="$1"; mkdir -p "$r/docs/workflow"
  git init -q -b main "$r" || fail "git init failed"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf 'backend: filesystem\n' > "$r/docs/workflow/tracker-config.yaml"
  python3 "$TRK" --tracker "$r/TRACKER.md" init >/dev/null || fail "tracker init failed"
  echo v1 > "$r/app.py"; git -C "$r" add -A; git -C "$r" commit -qm init
}
open_record() { # repo, session, command — exactly as the entry gate does
  python3 - "$1" "$2" "$3" <<'PY' || fail "could not open the command record"
import sys, os
sys.path.insert(0, os.path.join(os.environ["IDC_PLUGIN"], "scripts", "hooks"))
import idc_ledger
sys.exit(0 if idc_ledger.command_start(*sys.argv[1:4], "0.0.0", "d", "user") else 1)
PY
}

echo "== R1. REDACTION MUST NOT BE DEFEATED BY THE DISPLAY TRUNCATION"
# The capture handed to run_verify is ALREADY bounded by _drain_bounded (_MAX_RETAINED_BYTES), so
# redacting it whole costs a bounded pass — measured at ~32 ms on the worst-case 17 KB buffer. Taking
# the 4 KB display tail FIRST can cut through a `password=` label, leaving a short value that no
# longer matches the named-secret rule nor the 40-char opaque backstop, and that value is then
# written into the COMMITTED evidence file.
python3 - "$LIVE" "$WORK" <<'PY' || fail "R1: a credential straddling the display-tail boundary survives redaction"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("L", sys.argv[1])
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
work = sys.argv[2]

def body_of(payload_py):
    """The redacted body the REAL run_verify hands to the evidence writer."""
    spec_ = {"name": "web", "verify_raw": f"python3 -c {payload_py!r}",
             "verify": "probe", "timeout": 60}
    rc, out, _ = L.run_verify(work, spec_, "0" * 40)
    if rc != 0:
        sys.exit(f"precondition: the probe must succeed, got rc={rc} out={out[:200]!r}")
    return out

SECRET = "hunter2"
# Place the credential so the MAX_BODY_CHARS display cut falls INSIDE the word "password", leaving
# `word=hunter2` — which matches neither the named-secret rule (its label is gone) nor the 40-char
# opaque backstop (the value is 7 chars).
head, cred = "A" * 1000, f"password={SECRET}"
filler_len = L.MAX_BODY_CHARS + 4 - len(cred)
payload = (f"print({head!r} + {cred!r} + 'x\\n' * {filler_len // 2})")
body = body_of(payload)
if SECRET in body:
    sys.exit(f"the credential survived into the evidence body: {body[:80]!r}")

# ...and the fix must NOT be a bare reorder. The opaque-run backstop is `\b[A-Za-z0-9_-]{40,4096}\b`:
# a run LONGER than 4096 chars has no internal word boundary, so the pattern cannot match it at all.
# Truncating first used to shrink such a run back into range by accident. Redacting ONLY before the
# cut therefore lets a >4096-char opaque token through into the receipt — trading one leak for
# another. Redaction has to run on BOTH sides of the cut (it is idempotent; the second pass is 4 KB).
huge = body_of(f"print('x' * {L._MAX_RETAINED_BYTES})")
if "[REDACTED]" not in huge:
    sys.exit(f"a {L._MAX_RETAINED_BYTES}-char opaque run reached the receipt unredacted "
             f"({len(huge)} chars kept) — redaction must ALSO run after the display cut")

# ...and the fix must not silently drop the `…[truncated]…` signal. Redaction SHRINKS text, so a
# capture that really WAS cut can fall under MAX_BODY_CHARS once redacted. 200 lines of
# `token=<41 opaque chars>` is ~9.6 KB raw but ~3.4 KB redacted: deciding truncation from the
# redacted length marks a genuinely partial receipt as complete, and a reviewer reads a fragment as
# the whole story. The decision has to come from the PRE-redaction length.
shrunk = body_of("print(200 * ('token=' + 'A' * 41 + chr(10)), end='')")
if "…[truncated]…" not in shrunk:
    sys.exit(f"a capture that WAS truncated lost its `…[truncated]…` marker because redaction shrank "
             f"it back under the bound ({len(shrunk)} chars kept) — decide truncation from the "
             f"pre-redaction length")
PY
echo "  ok R1: credentials survive neither the display cut nor the opaque-run bound"

echo "== R3. EVERY PRINTED CURE MUST BE RUNNABLE AS WRITTEN"
# `${CLAUDE_PLUGIN_ROOT}` text-substitutes only in command/agent/skill MARKDOWN. Emitted from Python
# it is an ordinary shell expansion of an unset variable, so the operator is handed
# `python3 /scripts/idc_git_finish.py`. idc_pause_check.py lives at <plugin>/scripts/, so it can
# resolve its own root from __file__ with no new argument.
R3="$WORK/cures"; mkrepo "$R3"
python3 - "$R3" <<'PY' || fail "R3: could not plant the half-done obligation"
import sys, os
sys.path.insert(0, os.path.join(os.environ["IDC_PLUGIN"], "scripts", "hooks"))
import idc_ledger
idc_ledger.set_taint(sys.argv[1], "mid_finish", key="42", session_id="s1", pr="7", branch="b")
PY
cures="$(python3 "$PC" --repo "$R3" --tracker "$R3/TRACKER.md" 2>&1)"
printf '%s' "$cures" | grep -q 'mid_finish:#42' \
  || fail "R3: precondition — the checker must report the planted obligation, got: $cures"
printf '%s' "$cures" | grep -q 'CLAUDE_PLUGIN_ROOT' \
  && fail "R3: the printed cure contains a literal \${CLAUDE_PLUGIN_ROOT}, which is EMPTY in a shell — the operator is told to run \`python3 /scripts/...\`. Got: $cures"
# and the resolved path must actually name a helper that exists
printf '%s' "$cures" | tr ' ' '\n' | grep -o '/[^ ]*/scripts/[A-Za-z_/]*\.py' | sort -u | while read -r p; do
  [ -f "$p" ] || { printf 'FAIL: R3: emitted cure names a helper that does not exist: %s\n' "$p"; exit 1; }
done || exit 1
echo "  ok R3: emitted cures resolve to real helper paths"

echo "== R9. THE STOP GATE MUST NOT TRUST A HANDWRITTEN PAUSE RECORD"
# A real confirmed record carries version/session_id/confirmed_by/confirmed_ts and the quiescence
# proof that earned it. The gate consulted only `state`, and it does so BEFORE the drain check, so a
# two-key file bought an undrained walk-away. Validating the full shape costs no I/O and does not
# re-derive anything, so the zero-GraphQL constraint on the stop path is untouched.
R9="$WORK/forged"; mkrepo "$R9"
printf '{"state":"paused"}' > "$R9/.idc-pause-state.json"
python3 - "$GATE" "$R9" <<'PY' || fail "R9: the Stop gate accepted a forged one-key pause record"
import importlib.util, sys, os
plugin = os.environ["IDC_PLUGIN"]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
spec = importlib.util.spec_from_file_location("G", sys.argv[1])
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)
if G._is_paused(sys.argv[2]):
    sys.exit("a handwritten {\"state\":\"paused\"} file was accepted as a CONFIRMED pause")
PY
# ...and a genuine confirmed record must still be honoured (the guard must not be a blanket refusal).
R9B="$WORK/genuine"; mkrepo "$R9B"
SID9=repro9
open_record "$R9B" "$SID9" autorun
python3 "$PS" --cwd "$R9B" request --session "$SID9" >/dev/null || fail "R9b: request failed"
python3 "$PS" --cwd "$R9B" confirm --session "$SID9" >/dev/null || fail "R9b: a quiescent repo must be pausable"
python3 - "$GATE" "$R9B" <<'PY' || fail "R9b: the Stop gate rejected a GENUINE confirmed pause record"
import importlib.util, sys, os
plugin = os.environ["IDC_PLUGIN"]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
spec = importlib.util.spec_from_file_location("G", sys.argv[1])
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)
if not G._is_paused(sys.argv[2]):
    sys.exit("a real confirmed pause record was refused — the guard is too strict")
PY
echo "  ok R9: forged pause record refused, genuine one still honoured"

echo "== R10. THE NORMAL PAUSE JOURNEY MUST NOT REFUSE ITSELF"
# The entry gate opens a lifecycle record for EVERY command but `init`, so a real `/idc:pause` has an
# active `pause` record when commands/pause.md step 4 runs `close-open`. `pause` is not a pausable
# stage, so the walk refused the very command doing the pausing: exit 1 plus a REFUSED line telling
# the operator to "finish or abandon" the pause itself. phase10's A5 passes only because it opens the
# `autorun` record alone.
R10="$WORK/journey"; mkrepo "$R10"
SID10=repro10
open_record "$R10" "$SID10" autorun
open_record "$R10" "$SID10" pause          # what a REAL /idc:pause has open
python3 "$PS" --cwd "$R10" request --session "$SID10" >/dev/null || fail "R10: request failed"
python3 "$PS" --cwd "$R10" confirm --session "$SID10" >/dev/null || fail "R10: a quiescent repo must be pausable"
out10="$(python3 "$PS" --cwd "$R10" close-open --session "$SID10" 2>&1)"; rc10=$?
printf '%s' "$out10" | grep -q '/idc:autorun closed as paused' \
  || fail "R10: precondition — the interrupted autorun must still close as paused, got: $out10"
printf '%s' "$out10" | grep -q '/idc:pause REFUSED' \
  && fail "R10: close-open REFUSED the pause command's own lifecycle record — every honest pause reports a spurious refusal. Got: $out10"
[ "$rc10" = 0 ] \
  || fail "R10: a clean pause must exit 0 from close-open, got rc=$rc10 out=$out10"
echo "  ok R10: a clean pause closes its interrupted runs and exits 0"

echo "== R13. AN EVIDENCE DESTINATION MUST STAY INSIDE THE REPO"
# surface_spec used `rel` verbatim when absolute and os.path.join(repo, rel) otherwise, and the
# DEFAULT destination interpolates an unvalidated surface `name`. Later writes create parents and
# TRUNCATE the resolved target, so a typo'd or hostile destination silently destroys a file.
R13="$WORK/paths"; mkrepo "$R13"
python3 - "$LIVE" "$R13" <<'PY' || fail "R13: an evidence destination can resolve outside the repo"
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("L", sys.argv[1])
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
repo = os.path.realpath(sys.argv[2])
outside = os.path.join(tempfile.gettempdir(), "idc-repro-outside.md")
cases = [
    ("absolute destination",        {"name": "web", "paths": "app.py", "verify": "true", "evidence": outside}),
    ("traversing destination",      {"name": "web", "paths": "app.py", "verify": "true", "evidence": "../../escape.md"}),
    # The default destination is DEFAULT_EVIDENCE_DIR/<name>.md, so a name only escapes once it climbs
    # past that directory — two `..` land in docs/, which is still inside. Four is a real escape.
    ("traversal via surface name",  {"name": "../../../../escape", "paths": "app.py", "verify": "true"}),
]
bad = []
for label, surface in cases:
    try:
        got = L.surface_spec(repo, surface)["evidence_path"]
    except ValueError:
        continue                      # refused at declaration time — the correct behaviour
    resolved = os.path.realpath(got)
    if os.path.commonpath([resolved, repo]) != repo:
        bad.append(f"{label}: resolved to {resolved}, outside {repo}")
if bad:
    sys.exit("; ".join(bad))
PY
echo "  ok R13: absolute, traversing, and name-derived destinations stay inside the repo or are refused"

echo "== R17. THE PUBLIC COMMAND TABLE MUST MATCH THE SHIPPED COMMAND SET"
shipped_n="$(ls "$PLUGIN"/commands/*.md | wc -l | tr -d ' ')"
for c in intake pause resume; do
  grep -q "/idc:$c" "$PLUGIN/README.md" \
    || fail "R17: README.md's command table omits /idc:$c, but commands/$c.md ships ($shipped_n commands in all)"
done
grep -qi '^Ten slash entry points' "$PLUGIN/README.md" \
  && fail "R17: README.md still says 'Ten slash entry points' — $shipped_n commands ship"
echo "  ok R17: the README table covers all $shipped_n shipped commands"

echo "phase11-honesty-repro: OK"
