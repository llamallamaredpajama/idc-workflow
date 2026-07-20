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
# `_is_paused` is a BYPASS: True allows the stop BEFORE the drain check runs. The gate consulted only
# `state`, so a two-key file an agent can emit in a single Write bought an undrained walk-away. A real
# confirmed record carries the schema version, who asked, who confirmed, when, and the quiescence
# proof that earned it — all produced as a side-effect of `confirm` doing the actual work. Validating
# that shape costs no I/O and re-derives nothing, so the zero-GraphQL constraint is untouched.
#
# THE FORGERIES ARE DERIVED FROM A GENUINE RECORD, one broken field at a time, rather than
# hand-written. Two reasons. A forger who has SEEN a real record copies its shape, so the lazy one-key
# file is the LEAST interesting attack. And a hand-written "bad" record can fail for an accidental
# reason, which would leave the guard it is supposed to cover untested — an untested guard is one a
# later edit deletes with nothing going red. Every required field gets its own case, and the genuine
# record itself is the positive control on both ends.
R9B="$WORK/genuine"; mkrepo "$R9B"
SID9=repro9
open_record "$R9B" "$SID9" autorun
python3 "$PS" --cwd "$R9B" request --session "$SID9" >/dev/null || fail "R9: request failed"
python3 "$PS" --cwd "$R9B" confirm --session "$SID9" >/dev/null || fail "R9: a quiescent repo must be pausable"
R9="$WORK/forged"; mkrepo "$R9"
python3 - "$GATE" "$R9B" "$R9" <<'PY' || fail "R9: the Stop gate mis-graded a pause record"
import copy, importlib.util, json, os, sys
plugin = os.environ["IDC_PLUGIN"]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
spec = importlib.util.spec_from_file_location("G", sys.argv[1])
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)
genuine_repo, forged_repo = sys.argv[2], sys.argv[3]
name = ".idc-pause-state.json"

# POSITIVE CONTROL 1 — the record a REAL `/idc:pause` just wrote must be honoured. A gate that
# refuses everything is the same false verdict pointed the other way: it would silently disable the
# deliberate-pause path and make every honest pause look like a dishonest exit.
if not G._is_paused(genuine_repo):
    sys.exit("a real confirmed pause record was REFUSED — the guard is too strict")
with open(os.path.join(genuine_repo, name), encoding="utf-8") as fh:
    genuine = json.load(fh)

def plant(rec):
    with open(os.path.join(forged_repo, name), "w", encoding="utf-8") as fh:
        json.dump(rec, fh)

# POSITIVE CONTROL 2 — the SAME bytes in the other repo are still honoured. Without this, a forgery
# could be "refused" merely because this harness put it somewhere the gate never looks, and every
# assertion below would pass for the wrong reason.
plant(genuine)
if not G._is_paused(forged_repo):
    sys.exit("harness fault: a byte-identical copy of the genuine record was refused, so the "
             "forgery cases below would prove nothing")

def broken(label, mutate):
    rec = copy.deepcopy(genuine)
    mutate(rec)
    return (label, rec)

def drop(key):
    return lambda r: r.pop(key, None)

FORGERIES = [
    ("the lazy forgery — one key, one Write call", {"state": "paused"}),
    # One required field removed from an otherwise PERFECT copy. Each of these is the minimal
    # deviation that must still be refused, so each names exactly one guard.
    broken("no schema version",            drop("version")),
    broken("no session_id (who asked)",    drop("session_id")),
    broken("no confirmed_by (who confirmed)", drop("confirmed_by")),
    broken("no confirmed_ts (when)",       drop("confirmed_ts")),
    broken("no quiescence proof at all",   drop("quiescence")),
    # ...and the proof present but not actually a proof.
    broken("quiescence RECORDS ITS OWN REFUSAL (verdict: in-flight)",
           lambda r: r["quiescence"].update({"verdict": "in-flight"})),
    broken("quiescence block empty",       lambda r: r.update({"quiescence": {}})),
    broken("quiescence has no checked_ts", lambda r: r["quiescence"].pop("checked_ts", None)),
    broken("quiescence is not a mapping",  lambda r: r.update({"quiescence": "ok"})),
    # Wrong-typed identity: JSON `true` is an int in Python, so a bare isinstance check would pass it.
    broken("confirmed_ts is a boolean",    lambda r: r.update({"confirmed_ts": True})),
    broken("session_id is blank",          lambda r: r.update({"session_id": "   "})),
    broken("an unknown future schema version", lambda r: r.update({"version": 99})),
    # Not a forgery — the honest intermediate state. It must not read as a confirmed pause either.
    broken("merely pause-requested",       lambda r: r.update({"state": "pause-requested"})),
]
bad = [label for label, rec in FORGERIES if (plant(rec) or G._is_paused(forged_repo))]
if bad:
    sys.exit("these records bought an undrained stop: " + "; ".join(bad))

# POSITIVE CONTROL 3 — after all that, the genuine record is STILL honoured. Proves the loop above
# did not simply drive the gate into refusing everything.
plant(genuine)
if not G._is_paused(forged_repo):
    sys.exit("the genuine record stopped being honoured once the forgeries had been tried")
PY
echo "  ok R9: 14 forged/incomplete records refused, the genuine one still honoured"

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
# A SYMLINKED evidence directory is the vector a pure string check misses: every component of
# `docs/workflow/live-verification/web.md` is an innocent relative segment, and only resolving the
# link shows it landing in /tmp. The link is planted where the DEFAULT destination points, so this
# case needs no unusual declaration at all.
linkdir = os.path.join(repo, "docs", "workflow")
os.makedirs(linkdir, exist_ok=True)
elsewhere = tempfile.mkdtemp(prefix="idc-repro-symlink-")
os.symlink(elsewhere, os.path.join(linkdir, "live-verification"))

cases = [
    ("absolute destination",        {"name": "web", "paths": "app.py", "verify": "true", "evidence": outside}),
    ("traversing destination",      {"name": "web", "paths": "app.py", "verify": "true", "evidence": "../../escape.md"}),
    # The default destination is DEFAULT_EVIDENCE_DIR/<name>.md, so a name only escapes once it climbs
    # past that directory — two `..` land in docs/, which is still inside. Four is a real escape.
    ("traversal via surface name",  {"name": "../../../../escape", "paths": "app.py", "verify": "true"}),
    ("symlinked evidence directory", {"name": "web", "paths": "app.py", "verify": "true"}),
    ("symlink reached explicitly",  {"name": "web", "paths": "app.py", "verify": "true",
                                     "evidence": "docs/workflow/live-verification/web.md"}),
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

# POSITIVE CONTROL — confinement must not become "refuse every destination", which would take the
# whole live gate offline while looking like a hardening win. An ordinary in-repo destination, and
# the shipped DEFAULT, must both still resolve, and must resolve to the file the writer will open.
os.remove(os.path.join(linkdir, "live-verification"))
for label, surface, expected in [
    ("an ordinary declared destination",
     {"name": "web", "paths": "app.py", "verify": "true", "evidence": "docs/evidence/web.md"},
     os.path.join(repo, "docs", "evidence", "web.md")),
    ("the shipped default destination",
     {"name": "web", "paths": "app.py", "verify": "true"},
     os.path.join(repo, L.DEFAULT_EVIDENCE_DIR, "web.md")),
]:
    try:
        got = L.surface_spec(repo, surface)["evidence_path"]
    except ValueError as e:
        sys.exit(f"{label} was REFUSED — confinement must not disable the gate: {e}")
    if os.path.realpath(got) != os.path.realpath(expected):
        sys.exit(f"{label} resolved to {got!r}, not the expected {expected!r}")
PY
echo "  ok R13: absolute, traversing, name-derived and symlinked destinations refused; in-repo ones still resolve"

echo "== R17. THE PUBLIC COMMAND TABLE MUST MATCH THE SHIPPED COMMAND SET"
# Derived from the shipped files BOTH WAYS rather than from a hand-listed set of three, so the next
# command to ship cannot quietly go undocumented and a removed one cannot linger. The count word is
# checked against the same source, because "Ten slash entry points" above a 13-row table is exactly
# the drift this row is about.
python3 - "$PLUGIN" <<'PY' || fail "R17: the README command table does not match the shipped command set"
import os, re, sys
plugin = sys.argv[1]
shipped = {os.path.splitext(f)[0] for f in os.listdir(os.path.join(plugin, "commands"))
           if f.endswith(".md")}
readme = open(os.path.join(plugin, "README.md"), encoding="utf-8").read()
# The table rows only — `| `/idc:x` | … |` — not every mention of a command in the prose.
documented = set(re.findall(r"^\|\s*`/idc:([a-z-]+)`\s*\|", readme, re.M))
missing, extra = sorted(shipped - documented), sorted(documented - shipped)
problems = []
if missing:
    problems.append("the table omits " + ", ".join(f"/idc:{c}" for c in missing)
                    + f" but commands/{missing[0]}.md ships")
if extra:
    problems.append("the table lists " + ", ".join(f"/idc:{c}" for c in extra) + " which ship no command file")
WORDS = {10: "Ten", 11: "Eleven", 12: "Twelve", 13: "Thirteen", 14: "Fourteen", 15: "Fifteen"}
want = WORDS.get(len(shipped))
m = re.search(r"^([A-Z][a-z]+) slash entry points", readme, re.M)
if not m:
    problems.append("the `<N> slash entry points` line is gone — the count is no longer stated at all")
elif want and m.group(1) != want:
    problems.append(f"the README says {m.group(1)!r} slash entry points but {len(shipped)} commands ship "
                    f"(expected {want!r})")
if problems:
    sys.exit("; ".join(problems))
PY
echo "  ok R17: the README table matches the shipped command set exactly, and states the right count"

echo "== R14. A FORGED RECEIPT THAT MIMICS A REAL ONE MUST BE REFUSED"
# `agents/idc-build.md` tells the implementing agent "never hand-write an evidence record — a typed
# claim does not satisfy this gate, by construction". That was FALSE as written: every field the audit
# read is one anyone can type. The declared command and its sha256 come straight out of the config,
# the commit is `git rev-parse HEAD`, and `exit_code: 0` is just a character. A receipt carrying all
# of them passed with `live: ok` WHILE THE SURFACE'S REAL VERIFY COMMAND EXITED 1 — the gate built to
# refuse "I tested it" accepting exactly that, about itself.
#
# It cannot be fixed by checking the receipt harder: the receipt is committed and portable, so every
# value in it must be recomputable by any reader, and whatever a reader can recompute a forger can
# write. The proof of a run therefore lives where git cannot carry it (the git directory), and the
# audit requires the two to agree.
R14="$WORK/forged-receipt"; mkrepo "$R14"; mkdir -p "$R14/scripts" "$R14/services"
echo x > "$R14/services/app.py"
cat > "$R14/WORKFLOW-config.yaml" <<'EOF'
project:
  name: demo
live_verification:
  surfaces:
    - name: web
      verify: bash scripts/verify.sh
      paths: [services/]
EOF
# THE PRODUCT IS BROKEN: the real verify command exits 1. Any verdict other than a refusal is the gate
# telling a lie about a deployment that does not work.
printf '#!/bin/bash\necho "journey failed: open returned 500"\nexit 1\n' > "$R14/scripts/verify.sh"
git -C "$R14" add -A; git -C "$R14" commit -qm declare
SHA14="$(git -C "$R14" rev-parse HEAD)"
CMD14="bash scripts/verify.sh"
CMDSHA14="$(printf '%s' "$CMD14" | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -n "$CMDSHA14" ] || CMDSHA14="$(printf '%s' "$CMD14" | sha256sum | awk '{print $1}')"

# The forgery: precisely the record a successful run would have produced, hand-written.
mkdir -p "$R14/docs/workflow/live-verification"
printf '<!-- idc-live-evidence: {"surface":"web","mode":"executed","command":"%s","command_sha256":"%s","exit_code":0,"commit":"%s","ran_at":"2026-07-19T04:11:07Z","duration_s":12.4,"observed":"signed in; ingest 200; open 200; chat 200"} -->\n' \
  "$CMD14" "$CMDSHA14" "$SHA14" > "$R14/docs/workflow/live-verification/web.md"
git -C "$R14" add -A; git -C "$R14" commit -qm "evidence"
out14="$(python3 "$LIVE" --repo "$R14" 2>&1)"; rc14=$?
[ "$rc14" = 0 ] \
  && fail "R14: a hand-written receipt mimicking a real run was ACCEPTED (rc=0) while the surface's own verify command exits 1 — a typed claim satisfied the gate. Got: $out14"
printf '%s' "$out14" | grep -qE 'live: (gap|error)' \
  || fail "R14: the forged receipt was refused, but not with a live: gap/error verdict. Got: $out14"

# POSITIVE CONTROL — MANDATORY. A gate that refuses every receipt is the same false verdict pointed
# the other way: it would silently disable the live gate while looking like a hardening win. A receipt
# produced by a REAL `--run` must still audit clean, through the ordinary read-only audit path.
printf '#!/bin/bash\necho "signed in; ingest 200; open 200; chat 200"\nexit 0\n' > "$R14/scripts/verify.sh"
git -C "$R14" add -A; git -C "$R14" commit -qm "fix the product"
run14="$(python3 "$LIVE" --repo "$R14" --run 2>&1)"; rrc14=$?
[ "$rrc14" = 0 ] || fail "R14 positive control: a real --run over a PASSING verify command must be clean, got rc=$rrc14 out=$run14"
git -C "$R14" add -A; git -C "$R14" commit -qm "real evidence"
aud14="$(python3 "$LIVE" --repo "$R14" 2>&1)"; arc14=$?
[ "$arc14" = 0 ] && [ "$aud14" = "live: ok" ] \
  || fail "R14 positive control: the receipt a REAL --run just produced must audit clean, got rc=$arc14 out=$aud14"

# ...and the forgery must still be refused in the very repo where a genuine run has happened, so the
# refusal is about the RECEIPT's provenance and not about the repo being untouched. Re-plant the
# forged exit_code over the genuine receipt: the run this working copy really did says exit 1.
printf '#!/bin/bash\necho "journey failed again"\nexit 1\n' > "$R14/scripts/verify.sh"
git -C "$R14" add -A; git -C "$R14" commit -qm "product breaks again"
python3 "$LIVE" --repo "$R14" --run >/dev/null 2>&1   # a real run; records exit 1 both places
SHA14B="$(git -C "$R14" rev-parse HEAD)"
printf '<!-- idc-live-evidence: {"surface":"web","mode":"executed","command":"%s","command_sha256":"%s","exit_code":0,"commit":"%s","ran_at":"2026-07-19T04:11:07Z","duration_s":12.4,"observed":"all green, honest"} -->\n' \
  "$CMD14" "$CMDSHA14" "$SHA14B" > "$R14/docs/workflow/live-verification/web.md"
git -C "$R14" add -A; git -C "$R14" commit -qm "overwrite the receipt with a passing claim"
out14b="$(python3 "$LIVE" --repo "$R14" 2>&1)"; rc14b=$?
[ "$rc14b" = 0 ] \
  && fail "R14: overwriting a genuine receipt's exit_code with 0 was ACCEPTED — the audit trusts the receipt over what this working copy actually ran. Got: $out14b"
echo "  ok R14: a shape-mimicking forged receipt is refused; a receipt from a real --run still audits clean"

echo "== R2. A MERGE MUST NOT PROCEED ON AN UNPERSISTED RECOVERY OBLIGATION  [T1]"
# The `mid_finish` taint is written immediately before `pr_merge` — an irreversible action that also
# closes the linked issue. It is the ONLY record telling a later session that a close is half-done.
# The write was best-effort AND its result discarded (`set_taint`'s own docstring said "the persisted
# bool is ignored here"), so a ledger that could not be written produced a warning and the merge went
# ahead anyway, re-opening the exact window the taint exists to close.
R2="$WORK/obligation"; mkrepo "$R2"
python3 - "$PLUGIN" "$R2" <<'PY' || fail "R2: the finish crossed the point of no return without a durable obligation"
import importlib.util, os, stat, sys
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_ledger
spec = importlib.util.spec_from_file_location("GF", os.path.join(plugin, "scripts", "idc_git_finish.py"))
GF = importlib.util.module_from_spec(spec); spec.loader.exec_module(GF)

# PRECONDITION — a writable repo really does persist the obligation, so the refusal below cannot be
# passing merely because this helper never works.
if not idc_ledger.set_taint(repo, "mid_finish", key="1", session_id="s1", pr="7"):
    sys.exit("precondition: a writable repo must persist the obligation and report that it did")
if not any(t.get("kind") == "mid_finish" for t in idc_ledger.pending_taints(repo)):
    sys.exit("precondition: the persisted obligation must be readable back")

# THE FAILURE: the ledger cannot be written. A read-only repo root is the realistic shape of it (a
# full disk and a permissions problem land in the same place).
idc_ledger.clear_taint(repo, "mid_finish", key="1")
mode = os.stat(repo).st_mode
os.chmod(repo, mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
try:
    if idc_ledger.set_taint(repo, "mid_finish", key="2", session_id="s1", pr="7"):
        sys.exit("set_taint reported a DURABLE obligation on a ledger it could not write")
    if GF._mid_finish_set(repo, "2", "s1", pr="7", branch="b"):
        sys.exit("_mid_finish_set reported success when the obligation did not persist")
    # ...and the finish must REFUSE. `_require_mid_finish_obligation` is the statement immediately
    # before `pr_merge`, so exiting the process here is exactly what proves the merge is never
    # reached — there is no path from a raised SystemExit to the next line.
    try:
        GF._require_mid_finish_obligation(repo, "2", "s1", pr="7", branch="b")
    except SystemExit as e:
        if e.code in (0, None):
            sys.exit(f"the finish stopped, but reported SUCCESS (exit {e.code})")
    else:
        sys.exit("the finish continued to the merge with no durable recovery record")
finally:
    os.chmod(repo, mode)

# THE READBACK, covered on its own. A successful `os.replace` is not proof that a LATER reader will
# find the taint — a full disk, a truncating filesystem or a racing writer all produce a "successful"
# write whose result is not there — and surviving a process that dies seconds later is the entire
# point of this record. That failure cannot be produced with permissions, so it is INJECTED: the
# atomic write reports success and writes nothing.
real_write = idc_ledger._atomic_write_state
idc_ledger._atomic_write_state = lambda *a, **k: True
try:
    if idc_ledger.set_taint(repo, "mid_finish", key="3", session_id="s1", pr="7"):
        sys.exit("set_taint reported a DURABLE obligation that is not readable back — a write that "
                 "returns success is not proof the record survived")
finally:
    idc_ledger._atomic_write_state = real_write
# ...and the positive control for the injection itself: with the real writer restored, the same call
# succeeds. Otherwise the assertion above could be passing because set_taint is simply broken.
if not idc_ledger.set_taint(repo, "mid_finish", key="3", session_id="s1", pr="7"):
    sys.exit("harness fault: set_taint failed even with the real writer restored")
PY
echo "  ok R2: an unpersistable obligation stops the finish BEFORE the irreversible merge"

echo "== R4. A CORRUPT OBLIGATIONS LEDGER MUST NOT CERTIFY A CLEAN PAUSE  [T5]"
# Every ledger reader is deliberately tolerant — a corrupt file reads as empty so a damaged ledger
# cannot brick a gate. That is right for a hint and wrong for a CERTIFICATE: `/idc:pause` reports its
# empty answer as `pause-ready: ok` and writes a durable pause record on it, so the tolerant read
# turned "I cannot tell" into "nothing is half-done" directly over a live mid_finish obligation.
R4="$WORK/corrupt-ledger"; mkrepo "$R4"
python3 - "$R4" <<'PY' || fail "R4: could not plant the half-done obligation"
import sys, os
sys.path.insert(0, os.path.join(os.environ["IDC_PLUGIN"], "scripts", "hooks"))
import idc_ledger
idc_ledger.set_taint(sys.argv[1], "mid_finish", key="42", session_id="s1", pr="7", branch="b")
PY
out4="$(python3 "$PC" --repo "$R4" --tracker "$R4/TRACKER.md" 2>&1)"; rc4=$?
[ "$rc4" = 1 ] || fail "R4: precondition — a live mid_finish must report in-flight (exit 1), got rc=$rc4 out=$out4"
# Now DAMAGE the ledger that held it. The obligation is still real; the file just cannot be read.
LEDGER4="$(python3 -c 'import sys,os; sys.path.insert(0, os.path.join(os.environ["IDC_PLUGIN"], "scripts", "hooks")); import idc_ledger; print(idc_ledger.ledger_path(sys.argv[1]))' "$R4")"
[ -f "$LEDGER4" ] || fail "R4: precondition — the ledger file must exist at $LEDGER4"
printf '{"version": 2, "taints": [ THIS IS NOT JSON' > "$LEDGER4"
out4b="$(python3 "$PC" --repo "$R4" --tracker "$R4/TRACKER.md" 2>&1)"; rc4b=$?
[ "$rc4b" = 0 ] \
  && fail "R4: an UNREADABLE obligations ledger was certified as a clean stopping point (exit 0) — the half-done work is still there, it just cannot be seen. Got: $out4b"
printf '%s' "$out4b" | grep -q 'pause-ready: error' \
  || fail "R4: an unreadable ledger must be INDETERMINATE (pause-ready: error), not a gap or a pass. Got: $out4b"
# ...and an ABSENT ledger is honestly empty, so it must still be clean — the strictness must not
# collapse into "every repo without a ledger cannot pause".
rm -f "$LEDGER4"
out4c="$(python3 "$PC" --repo "$R4" --tracker "$R4/TRACKER.md" 2>&1)"; rc4c=$?
[ "$rc4c" = 0 ] || fail "R4: a repo with NO ledger has nothing half-done and must pause cleanly, got rc=$rc4c out=$out4c"
echo "  ok R4: an unreadable ledger is indeterminate, an absent one is still clean"

echo "== R5. AN OPERATIONAL GIT FAILURE IS NOT \"NOT APPLICABLE\"  [T8]"
# `git rev-parse --git-dir` exits nonzero for far more than "there is no repo here": dubious
# ownership, an unreadable .git, a permission error, a broken worktree link. Those are states where
# work CAN have shipped and the board CAN be stale about it, and mapping them to exit 0
# `not-applicable` silently switched the shipped-vs-board check off.
COH="$PLUGIN/scripts/idc_finish_coherence.py"
R5="$WORK/nongit"; mkdir -p "$R5/docs/workflow"; printf 'backend: filesystem\n' > "$R5/docs/workflow/tracker-config.yaml"
out5="$(python3 "$COH" --repo "$R5" --tracker "$R5/TRACKER.md" 2>&1)"; rc5=$?
[ "$rc5" = 0 ] && printf '%s' "$out5" | grep -q 'not-applicable' \
  || fail "R5: precondition — a genuinely non-git directory must be not-applicable (exit 0), got rc=$rc5 out=$out5"
# THE OPERATIONAL FAILURE: a repo whose .git exists but cannot be read. git exits nonzero with a
# message that is NOT "not a git repository".
R5B="$WORK/brokengit"; mkrepo "$R5B"
chmod 000 "$R5B/.git"
out5b="$(python3 "$COH" --repo "$R5B" --tracker "$R5B/TRACKER.md" 2>&1)"; rc5b=$?
chmod 755 "$R5B/.git"
[ "$rc5b" = 0 ] \
  && fail "R5: a repo git could not read was reported as \`not-applicable\` (exit 0), disabling the shipped-vs-board check. Got: $out5b"
[ "$rc5b" = 2 ] \
  || fail "R5: an unreadable git repo must be INDETERMINATE (exit 2), got rc=$rc5b out=$out5b"
echo "  ok R5: a non-git dir is not-applicable, an unreadable one is indeterminate"

echo "== R11/R12. A RECEIPT MUST NAME THE CODE THAT ACTUALLY RAN  [T7]"
# R11 — the command executes the WORKING TREE while the receipt records HEAD, so a run started over
# uncommitted surface code claims a code state that was never exercised.
# R12 — the expiry rule watched `paths:` only. The verify SCRIPT is code too: weakening the probe
# (deleting a step, commenting out an assertion) left every receipt it had produced looking current.
# `command_sha256` only notices a change to the declared STRING, never to the file that string runs.
R11="$WORK/attribution"; mkrepo "$R11"; mkdir -p "$R11/scripts" "$R11/services"
echo v1 > "$R11/services/app.py"
cat > "$R11/WORKFLOW-config.yaml" <<'EOF'
project:
  name: demo
live_verification:
  surfaces:
    - name: web
      verify: bash scripts/verify.sh
      paths: [services/]
EOF
printf '#!/bin/bash\necho "journey ok"\nexit 0\n' > "$R11/scripts/verify.sh"
git -C "$R11" add -A; git -C "$R11" commit -qm declare
# Baseline: a clean tree runs and audits clean, so the refusals below are not simply "always red".
out11="$(python3 "$LIVE" --repo "$R11" --run 2>&1)"; rc11=$?
[ "$rc11" = 0 ] || fail "R11: precondition — a clean tree must run and pass, got rc=$rc11 out=$out11"
git -C "$R11" add -A; git -C "$R11" commit -qm evidence
[ "$(python3 "$LIVE" --repo "$R11" 2>&1)" = "live: ok" ] \
  || fail "R11: precondition — the receipt from that run must audit clean"

# R11 — dirty the SURFACE'S OWN code and re-run. The run cannot be attributed to any commit.
echo v2-uncommitted >> "$R11/services/app.py"
out11b="$(python3 "$LIVE" --repo "$R11" --run 2>&1)"; rc11b=$?
[ "$rc11b" = 0 ] \
  && fail "R11: a run over UNCOMMITTED surface code was recorded against HEAD — the receipt names a code state that was never exercised. Got: $out11b"
[ "$rc11b" = 2 ] \
  || fail "R11: an unattributable run is INDETERMINATE (exit 2), not a product finding, got rc=$rc11b out=$out11b"
git -C "$R11" checkout -- services/app.py
# ...and unrelated dirt must NOT block a run: the scope is the surface's own paths, and a run always
# dirties the tree by writing its own receipt.
echo scratch > "$R11/notes.txt"
out11c="$(python3 "$LIVE" --repo "$R11" --run 2>&1)"; rc11c=$?
[ "$rc11c" = 0 ] \
  || fail "R11: unrelated uncommitted files blocked a run — the dirty check must be scoped to the surface's own paths, got rc=$rc11c out=$out11c"
rm -f "$R11/notes.txt"; git -C "$R11" add -A; git -C "$R11" commit -qm evidence2 2>/dev/null

# R12 — change ONLY the verify script and commit it. `paths:` is untouched and the declared command
# string is identical, so nothing but the probe itself has changed.
[ "$(python3 "$LIVE" --repo "$R11" 2>&1)" = "live: ok" ] \
  || fail "R12: precondition — the receipt must be clean before the verifier is weakened"
printf '#!/bin/bash\n# the chat step was deleted\nexit 0\n' > "$R11/scripts/verify.sh"
git -C "$R11" add -A; git -C "$R11" commit -qm "weaken the probe"
out12="$(python3 "$LIVE" --repo "$R11" 2>&1)"; rc12=$?
[ "$rc12" = 0 ] \
  && fail "R12: the verify SCRIPT was rewritten and committed, and its old receipt still audits clean — a receipt outlived the probe that produced it. Got: $out12"
printf '%s' "$out12" | grep -q 'live: gap' \
  || fail "R12: a weakened verifier must expire its receipt as a GAP, got rc=$rc12 out=$out12"
echo "  ok R11/R12: an unattributable run is refused; editing the probe expires its receipts"

echo "== R15/R16. A DIAGNOSTIC MUST CARRY THE FACT SOMEBODY NEEDS TO ACT ON IT"
# R15 — the Stop block tells the operator to "see the `finish-coherence: gap <#s>` line", but
# `_drain_detail` kept only the verdict token and the two counts, so the sentence pointed at output
# that had already been discarded. Naming the items is the difference between a cure they can run and
# a re-run they must do first just to find out what broke.
# R16 — a wave-close checker that CRASHES reported the bare `error (no verdict)`, identical whether it
# hit a traceback, an unreadable config or a bad argument. `r` was in scope and dropped.
python3 - "$GATE" <<'PY' || fail "R15: the Stop block discards the finding line it tells the operator to read"
import importlib.util, os, sys
plugin = os.environ["IDC_PLUGIN"]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
spec = importlib.util.spec_from_file_location("G", sys.argv[1])
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)
STDOUT = "\n".join([
    "eligible: ",
    "recirc_inbox: 0",
    "unplanned_considerations: 0",
    "finish-coherence: gap #41 #42",
    "live: gap web",
    "drain: recirc-pending",
])
detail = G._drain_detail(STDOUT)
for needed in ("#41", "#42", "live: gap web"):
    if needed not in detail:
        sys.exit(f"the drain detail drops {needed!r}, which the block reason tells the operator to "
                 f"read: {detail!r}")
# ...and the reason built from it must actually carry them through to the operator.
reason = G._block_reason(detail, [], "/plugin/root")
for needed in ("#41", "#42"):
    if needed not in reason:
        sys.exit(f"the block reason drops {needed!r}: {reason!r}")
PY
echo "  ok R15: the Stop block names the items the operator is told to inspect"

# R16 — drive the REAL checker runner against a checker that crashes.
R16="$WORK/crashing-checker"; mkrepo "$R16"
python3 - "$PLUGIN" "$R16" <<'PY' || fail "R16: a crashed checker's return code and stderr are lost behind a generic 'no verdict'"
import importlib.util, os, sys, tempfile
plugin, repo = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("D", os.path.join(plugin, "scripts", "idc_autorun_drain.py"))
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)

# A checker that dies the way a real one does: a traceback on stderr and a nonzero exit, no verdict
# line at all. Placed beside the drain, which is where `_run_checker` looks for it.
name = "idc_zz_repro_crashing_checker.py"
path = os.path.join(plugin, "scripts", name)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("import sys\n"
             "sys.stderr.write('Traceback (most recent call last):\\n"
             "KeyError: \\'DISTINCTIVE-CAUSE\\'\\n')\n"
             "sys.exit(3)\n")
try:
    verdict, line = D._run_wave_close_check(name, [], "acceptance", ("acceptance: ok",), 60)
finally:
    os.remove(path)
if verdict != "error":
    sys.exit(f"a crashed checker must classify as error, got {verdict!r}")
if "exit 3" not in (line or ""):
    sys.exit(f"the checker's return code is lost: {line!r}")
if "DISTINCTIVE-CAUSE" not in (line or ""):
    sys.exit(f"the checker's stderr tail — the only thing naming the cause — is lost: {line!r}")
PY
echo "  ok R16: a crashed checker reports its exit code and the stderr tail that names the cause"

echo "== R7/R8. /idc:resume MUST HAVE A LEGAL OUTCOME, AND MUST PROVE ITS OWN SURVEY  [T4]"
# R7 — when the pause record cannot be REMOVED, resume.md correctly says STOP. But `complete` requires
# the record to be gone, and `blocked_external` had no grounding path for the pause-state helper, so
# the honest outcome was unreachable: three Stop blocks, the anti-nag bound loud-fail-allows, and the
# record is stranded with nothing recording why.
# R8 — `complete` required only record-absent + oracle-readable, so an agent that skipped the
# half-done survey resume.md tells it to run closed exactly like one that ran it.
R7="$WORK/resume-outcomes"; mkrepo "$R7"
python3 - "$PLUGIN" "$R7" <<'PY' || fail "R7/R8: resume's closeout does not hold"
import importlib.util, os, sys
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_command_contract as C

EV = {"schema_version": 1, "refs": {}}

def blocker_ev(helper, exit_code, diagnostic):
    return {"schema_version": 1,
            "refs": {"blocker": {"helper": helper, "exit": exit_code, "diagnostic": diagnostic}}}

# R7 — a SURVIVING pause record is what "the clear failed" means, so it grounds the blocker.
with open(os.path.join(repo, ".idc-pause-state.json"), "w", encoding="utf-8") as fh:
    fh.write('{"version":1,"state":"paused","session_id":"s1","requested_ts":1.0,'
             '"confirmed_by":"s1","confirmed_ts":2.0,'
             '"quiescence":{"verdict":"ok","checked_ts":2.0}}')
v = C.validate_closeout("resume", "complete", EV, repo=repo, session="s1")
if v.ok:
    sys.exit("resume closed COMPLETE while the pause record still exists")
v = C.validate_closeout("resume", "blocked_external",
                        blocker_ev("idc_pause_state.py", 2, "could not remove the pause record"),
                        repo=repo, session="s1")
if not v.ok:
    sys.exit(f"a resume whose pause-record clear FAILED has no legal terminal outcome: "
             f"blocked_external was refused with {v.reason_code!r} ({v.message})")

# ...and the blocker must be REFUSED once the record is actually gone — otherwise "blocked" becomes a
# free pass rather than a re-derived fact.
os.remove(os.path.join(repo, ".idc-pause-state.json"))
v = C.validate_closeout("resume", "blocked_external",
                        blocker_ev("idc_pause_state.py", 2, "could not remove the pause record"),
                        repo=repo, session="s1")
if v.ok:
    sys.exit("blocked_external was accepted although the pause record is gone — the clear succeeded, "
             "so the honest close is complete")

# R8 — the half-done survey must be RE-DERIVED at closeout, not taken on trust. Plant a real
# obligation: the survey now has a finding, and `complete` must carry it rather than ignore it.
import idc_ledger
idc_ledger.set_taint(repo, "mid_finish", key="99", session_id="s1", pr="7", branch="b")
v = C.validate_closeout("resume", "complete", EV, repo=repo, session="s1")
survey = ((v.normalized_evidence or {}).get("derived") or {}).get("resume_survey") if v.ok else None
if not v.ok:
    sys.exit(f"resume over a NOT-cleanly-stopped run must still be closeable — that is what resume is "
             f"for — but complete was refused with {v.reason_code!r}")
if not survey:
    sys.exit("resume closed complete with NO record that the half-done survey ever ran")
if survey.get("exit") != 1 or "#99" not in (survey.get("findings") or []):
    sys.exit(f"the recorded survey does not reflect the real half-done work: {survey!r}")
PY
echo "  ok R7/R8: a failed record-clear is a grounded blocker; complete carries a re-derived survey"

echo "phase11-honesty-repro: OK"
