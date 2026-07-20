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
# RED-WHEN-BROKEN — OBSERVED, not asserted. Every mutation below was APPLIED to the fixed source, the
# suite RUN, the case seen to fail, and the mutation reverted. A guard with no recorded mutation is
# not finished, and a green test is not evidence until it has been shown to go red.
#
# Two process notes, because both cost a wrong conclusion during this work:
#   1. A mutation that does not APPLY reads exactly like a mutation that did not break anything. The
#      driver asserts its anchor matched exactly once before trusting any result. One "GREEN" here
#      was a silently-unapplied edit, not a passing guard.
#   2. Three mutations came back genuinely GREEN, meaning the guard they broke had NO assertion
#      behind it. Those were treated as coverage gaps and CLOSED (the truncation marker in R1, the
#      quiescence proof in R9, the write readback in R2) — not written off as "the test still passes".
#
#   ROUND 3 — the boundaries the round-2 fixes still enumerated rather than derived. Every mutation
#   below was applied to the FIXED source with its anchor asserted to match EXACTLY ONCE, the phase
#   run, the failure read, and the mutation reverted (tree verified clean afterwards). TWO came back
#   GREEN first and neither was written off as a pass — both were coverage gaps and both were CLOSED:
#     * hard-coding the head quarantine to 32 bytes was green, because nothing asserted its SIZE —
#       only its existence. Closed by an auth header whose verb and token are separated by a run of
#       whitespace, where a quarantine cut back to the first whitespace hands the credential through.
#     * dropping `state` from `_COMMAND_IDENTITY` was green, because the case DERIVED ITS FIELD LIST
#       FROM THE TUPLE IT WAS MUTATING — shrink the tuple and the loop stops asking about the field
#       that was dropped. Closed by asking the READERS whether they can still see the record.
#   R18 a. skip the head quarantine entirely   ⇒ RED: `Authorization: Basic <secret>` cut inside the
#                                                 verb reaches the committed receipt verbatim.
#       b. cut back to the first whitespace (the token-sized repair) ⇒ RED: same leak — sizing the
#                                                 repair to an anchor is an enumeration of anchors.
#       c. drop the delimited-block arm        ⇒ RED: a severed PEM keeps its key body and loses the
#                                                 "a private key was here" marker.
#       d. hard-code the quarantine to 32 bytes ⇒ RED: a secret separated from its severed anchor by
#                                                 whitespace survives (the bound must be DERIVED).
#       e. accept an unbounded rule that declares no structural family ⇒ RED: a redactor nobody has
#                                                 sized is one the quarantine silently stops covering.
#   R19 f. probe attribution always attributable ⇒ RED: an uncommitted probe passes for HEAD.
#       g. go back to `git status --untracked-files=all` for the probe ⇒ RED: a GITIGNORED probe
#                                                 produces `live: ok` at a commit containing no probe.
#   R27 h. re-derive the watched set inline    ⇒ RED: a source added to the one door is watched by
#                                                 freshness and not by attribution.
#   R23 i. build the stderr tail from raw child output ⇒ RED: a `ghp_` token on a crashed checker's
#                                                 stderr reaches the drain line and the board comment.
#   R25 j. empty the per-command condition table ⇒ RED: uninstall's MANDATORY Phase-0 dirty-tree stop
#                                                 has no legal close and its record stays open.
#       k. assert the condition instead of re-deriving it ⇒ RED: an invented blocker closes a clean
#                                                 repo — the new door becomes a way to fake a stop.
#   R24 l. restore build.md's old `--status` menu ⇒ RED, naming the command and the missing terminal.
#   R26 m. drop `state` from the identity tuple ⇒ RED: a command record the Stop closeout gate cannot
#                                                 see is vouched for as trustworthy.
#
#   R1  (idc_live_check)
#     a. restore `redact(_tail(out, MAX_BODY_CHARS))`      ⇒ RED: `password=` cut mid-label, `hunter2`
#                                                             reaches the committed receipt.
#     b. drop the post-cut redaction pass                  ⇒ RED: a 17024-char opaque run survives.
#     c. decide truncation from the POST-redaction length  ⇒ RED: a truncated receipt loses its
#                                                             `…[truncated]…` marker.
#   R2  (idc_ledger / idc_git_finish)
#     a. `set_taint` discards the persisted bool again     ⇒ RED: the finish merges unprotected.
#     b. drop the write READBACK                           ⇒ RED (via fault injection: a write that
#                                                             reports success but stores nothing).
#     c. warn instead of refusing before `pr_merge`        ⇒ RED: the point of no return is crossed.
#     d. restore the best-effort taint in `close_only_recover`
#                                                          ⇒ RED: close-only deletes the branch its own
#                                                             ownership guard reads with no durable
#                                                             recovery record behind it.
#   R3  a. drop `render_cure` on the mid_finish finding    ⇒ RED: literal `${CLAUDE_PLUGIN_ROOT}`.
#   R4  a. drop the strict ledger probe                    ⇒ RED: a corrupt ledger certifies a pause.
#       b. probe non-dict-ness only, not the identity the tolerant readers key on
#                                                          ⇒ RED: a `mid_finish` entry that lost its
#                                                             `kind` is skipped by every reader and
#                                                             the probe still calls it readable.
#   R5  a. treat any nonzero `rev-parse` as not-applicable ⇒ RED: an unreadable repo reads clean.
#       b. look for `.git` at `--repo` only, not up the tree ⇒ RED: the hollow clean returns one
#                                                             directory down, which is where git
#                                                             itself looks.
#   R9  (idc_stop_fixpoint_gate `_is_paused` — one mutation per guard line, all eight observed RED)
#     a. state-only (the original defect)  b. drop the schema-version check  c. drop session_id
#     d. drop confirmed_by  e. drop confirmed_ts  f. accept any quiescence verdict
#     g. drop the checked_ts requirement  h. drop the whole quiescence-proof block
#     …and the PROVENANCE guard the shape checks could never provide (F9, reopened: six typed
#     constants cost a forger no more than two, so the record had to be corroborated):
#     i. drop the witness comparison entirely       ⇒ RED: "a byte-identical COPY of a genuine pause
#                                                      record bought the bypass in a repo that never
#                                                      confirmed a pause".
#     j. require a witness but not a MATCHING one   ⇒ RED: "a confirmation recorded for a DIFFERENT
#                                                      record vouched for this one".
#     k. stop recording the witness in `confirm`    ⇒ RED at POSITIVE CONTROL 1 — "a real confirmed
#                                                      pause record was REFUSED" — which is what
#                                                      proves the guard is not simply refusing all.
#   R21 (idc_pause_state.confirm / idc_command_contract — writer ⇔ strictest reader)
#     a. drop confirm's non-empty-session guard     ⇒ RED: `confirm --session ""` reports
#                                                      `pause: paused` while the Stop gate reads the
#                                                      same record as dishonest.
#     b. drop the closeout's corroboration check    ⇒ RED: an uncorroborated record closes a run as
#                                                      `paused`.
#   R10 a. drop the driver-record skip in close_open_commands ⇒ RED: every honest pause self-refuses.
#   R11 a. drop the dirty-tree refusal                     ⇒ RED: a run over uncommitted code is
#                                                             recorded against HEAD.
#       b. widen the dirty check to the whole repo         ⇒ RED: a run's own receipt blocks the run.
#   R12 a. watch only the declared `paths:`                ⇒ RED: a weakened probe keeps its receipt.
#   R13 a. restore the verbatim/join resolution            ⇒ RED: a receipt escapes the repo.
#       b. drop the absolute-destination refusal           ⇒ RED.
#       c. compare unresolved paths                        ⇒ RED: a symlinked evidence dir escapes.
#   R14 a. remove the genuineness check                    ⇒ RED: a forged receipt audits `live: ok`
#                                                             while the real verify command exits 1.
#       b. stop recording the witness on a real `--run`    ⇒ RED at the POSITIVE CONTROL — which is
#                                                             what proves the control has teeth and
#                                                             the gate is not just refusing all.
#       c. trust a witness without comparing what it recorded ⇒ RED: a genuine receipt's exit_code
#                                                             can be overwritten with 0.
#   R15 a. stop carrying the finding lines in `_drain_detail` ⇒ RED: the block names no items.
#       b. word the cure identically on both backends      ⇒ RED: the GITHUB block tells the operator
#                                                             to "see the `finish-coherence: gap <#s>`
#                                                             line", which the persisted verdict never
#                                                             carried and no re-read can produce.
#   R16 a. restore the generic `error (no verdict)`        ⇒ RED: exit code + cause lost.
#       b. keep the exit code but drop the stderr tail     ⇒ RED.
#   R17 a. revert the README table to ten entries          ⇒ RED.
#   R18 (idc_live_check — the RETENTION cut, the boundary R1 could not reach)
#     a. skip the severed-head redaction (`if False:`)    ⇒ RED: `word=hunter2xyzzy` — a credential
#                                                            whose label the cut severed — reaches the
#                                                            COMMITTED receipt.
#     b. decide truncation from this function's own input ⇒ RED: redacting a severed head shrinks 17 KB
#                                                            to ten characters, and the fragment then
#                                                            prints without `…[truncated]…`.
#     c. return the buffer when it holds NO whitespace    ⇒ RED: the severed head leaks in `;`-separated
#                                                            output, where there is no boundary to cut
#                                                            back to and the display cut never fires.
#   R19 (idc_live_check `_dirty_paths` — attribution must watch the same set freshness does)
#     a. drop the verifier files from the dirty set       ⇒ RED: an UNCOMMITTED probe edit yields
#                                                            `live: ok` for code HEAD never contained.
#     b. scan the probe with `--untracked-files=no`       ⇒ RED: a wholesale UNTRACKED replacement of
#                                                            the probe passes as a clean tree.
#     c. restore the fixed `line[3:]` porcelain slice     ⇒ RED: `_git` strips its stdout, so the first
#                                                            line loses its leading status space and
#                                                            the refusal names `cripts/verify.sh`.
#   R20 (idc_live_check `_witness_path` — the witness belongs to the repository)
#     a. restore `--absolute-git-dir`                     ⇒ RED: the witness is written inside the
#                                                            LINKED WORKTREE's private git dir, so the
#                                                            main checkout reports a false gap and
#                                                            `git worktree remove` destroys the proof.
#   R7  a. drop the pause-state helper from resume's blocker allowlist ⇒ RED: no legal outcome.
#       b. ground the blocker without re-deriving          ⇒ RED: "blocked" becomes a free pass.
#       c. stop re-deriving that the CLEAR would still fail ⇒ RED: a resume that never ran the clear
#                                                             closes as blocked — a surviving record
#                                                             is the ordinary pre-resume state.
#   R22 (idc_command_contract — a blocked pause/autorun must prove it was blocked)
#     a. stop re-deriving that the WRITE would still fail  ⇒ RED: `/idc:pause` closes as blocked in a
#                                                             repo where the pause was achievable.
#     b. probe only the repo root, not the git directory   ⇒ RED: a pause whose confirmation mark
#                                                             cannot be written has no legal outcome.
#     c. drop the pause-state helper from autorun's allowlist ⇒ RED: the close `commands/autorun.md`
#                                                             prescribes on `resume: error` is refused.
#   R8  a. drop the resume survey claim                    ⇒ RED: complete with no survey.
#       b. keep the claim but stop recording what it derived ⇒ RED: nothing proves it ran.
#       c. return the caller's evidence unchanged when a claim re-derived nothing (caught by R21)
#                                                          ⇒ RED: a hand-written `derived` block is
#                                                             persisted verbatim under the one key
#                                                             that exists to be unforgeable.

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
import idc_pause_state as PS
genuine_repo, forged_repo = sys.argv[2], sys.argv[3]
name = ".idc-pause-state.json"

# POSITIVE CONTROL 1 — the record a REAL `/idc:pause` just wrote must be honoured. A gate that
# refuses everything is the same false verdict pointed the other way: it would silently disable the
# deliberate-pause path and make every honest pause look like a dishonest exit.
if not G._is_paused(genuine_repo):
    sys.exit("a real confirmed pause record was REFUSED — the guard is too strict")
with open(os.path.join(genuine_repo, name), encoding="utf-8") as fh:
    genuine = json.load(fh)

def plant(rec, witness=True):
    """Put `rec` in the forged repo — and, unless we are testing provenance itself, give it a
    MATCHING witness. Without that every case below would be refused for the same one reason (no
    confirmation was recorded here) and not one of the shape guards would be under test."""
    with open(os.path.join(forged_repo, name), "w", encoding="utf-8") as fh:
        json.dump(rec, fh)
    if witness:
        PS._record_confirmation(forged_repo, rec)
    else:
        PS._clear_confirmation(forged_repo)

# THE PROVENANCE GUARD (F9 reopened). A record whose every field is a caller-typed value — the
# version and state are constants, the ids arbitrary strings, the timestamps arbitrary numbers — is
# not evidence, however many fields it has. So a byte-identical copy of the GENUINE record must be
# REFUSED in a repo where no confirmation was ever recorded: this is the case that used to pass, and
# passing it is what let one `Write` buy an undrained walk-away.
plant(genuine, witness=False)
if G._is_paused(forged_repo):
    sys.exit("a byte-identical COPY of a genuine pause record bought the bypass in a repo that never "
             "confirmed a pause — the record is typeable, so shape alone can never ground it")

# ...and a witness for a DIFFERENT record must not vouch for this one either.
other = copy.deepcopy(genuine); other["confirmed_ts"] = genuine["confirmed_ts"] + 1
plant(genuine, witness=False); PS._record_confirmation(forged_repo, other)
if G._is_paused(forged_repo):
    sys.exit("a confirmation recorded for a DIFFERENT record vouched for this one — the witness must "
             "name one exact record")

# POSITIVE CONTROL 2 — with a MATCHING witness the same bytes are honoured again. Without this, every
# forgery below could be "refused" merely because the harness left it uncorroborated, and not one of
# the shape guards would actually be under test.
plant(genuine)
if not G._is_paused(forged_repo):
    sys.exit("harness fault: a corroborated copy of the genuine record was refused, so the "
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
echo "  ok R9: an uncorroborated copy and 14 forged/incomplete records refused, the genuine one honoured"

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

# THE CLOSE-ONLY PATH OWES THE SAME OBLIGATION. It does not merge, so it cannot CREATE the
# shipped-but-not-flipped state — but it DELETES the branch its own ownership guard reads, so dying
# after that and before the board flip leaves the item unrecoverable. Its taint write was still
# best-effort, so a ledger that could not be written produced a warning and the deletions went ahead.
import types
idc_ledger.clear_taint(repo, "mid_finish", key="3")
did = []
def _mark(label, retval=None):
    def f(*a, **k):
        did.append(label)
        return retval
    return f
GF.resolve_branch = lambda *a, **k: "feat/2-thing"
GF.verify_pr_merged = _mark("verify_pr_merged")
GF._resolve_branch_item = lambda *a, **k: ("2", ["2"])   # must EQUAL args.issue, or the ownership
                                                         # guard fails first and nothing below runs
GF.refuse_if_head_advanced = _mark("containment")
GF.worktree_for_branch = lambda *a, **k: None
GF.worktree_remove = _mark("DESTRUCTIVE:worktree_remove")
GF.live_remote_tip_deletable = _mark("DESTRUCTIVE:remote_tip_probe", False)
GF.branch_delete_local = _mark("DESTRUCTIVE:branch_delete")
GF.tracker_close = _mark("DESTRUCTIVE:tracker_close")
args = types.SimpleNamespace(pr=9, issue="2", worktree=None)
os.chmod(repo, mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
try:
    try:
        GF.close_only_recover(args, repo, None, os.path.join(repo, "TRACKER.md"), "filesystem",
                              None, None, None, None, session_id="s1")
    except SystemExit as e:
        if e.code in (0, None):
            sys.exit(f"close-only stopped, but reported SUCCESS (exit {e.code})")
    else:
        sys.exit("close-only ran to completion with no durable recovery record")
finally:
    os.chmod(repo, mode)
destructive = [c for c in did if c.startswith("DESTRUCTIVE")]
if destructive:
    sys.exit("close-only destroyed state with no durable recovery record — the branch deletion "
             "removes the evidence its own ownership guard needs: " + ", ".join(destructive))
if "containment" not in did:
    sys.exit(f"harness fault: close-only did not reach its containment gate at all ({did}), so the "
             f"absence of destructive calls proves nothing")
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
# ...and the probe must ask the SAME question its tolerant readers answer. They skip an entry that
# has lost its identity fields, not one that is merely not an object — so a `mid_finish` entry
# missing its `kind` (a hand-edited ledger) was invisible to every reader AND pronounced readable.
printf '{"version":2,"taints":[{"key":"42","session_id":"s1","fields":{"pr":"9"}}],"commands":[]}' \
  > "$LEDGER4"
out4d="$(python3 "$PC" --repo "$R4" --tracker "$R4/TRACKER.md" 2>&1)"; rc4d=$?
[ "$rc4d" = 0 ] \
  && fail "R4: a ledger entry that lost its \`kind\` is skipped by every reader, yet the strict probe called the ledger trustworthy and certified a clean pause over it. Got: $out4d"
printf '%s' "$out4d" | grep -q 'pause-ready: error' \
  || fail "R4: an entry with no identity must be INDETERMINATE (pause-ready: error), got rc=$rc4d out=$out4d"
rm -f "$LEDGER4"

# R26 — THE INVARIANT ITSELF, over every reader, rather than the two fields that were reported. The
# identity tuple was written from the readers somebody had looked at, and `active_commands` — the
# reader the Stop CLOSEOUT gate consults — skips on a THIRD field (`state`). So a command record with
# no `state` was invisible to that gate while the probe vouched for the ledger: the same hidden
# obligation as the `kind`-less taint above, one field over. What has to hold is the implication, and
# this asserts it directly in both directions.
python3 - "$PLUGIN" "$R4" <<'PY' || fail "R26: the strict probe vouches for a ledger whose records a reader cannot see"
import json, os, sys
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_ledger as L

path = L.ledger_path(repo)

def write(ledger):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(ledger, fh)

# (1) NEGATIVE — derived from the READERS, deliberately NOT from the identity declaration. Reading
#     the declaration would make this test grade itself: shrink it and the loop simply stops asking
#     about the field that was damaged, which is a GREEN that proves nothing. So: DAMAGE each field
#     of a full record in turn, ASK THE READERS whether they can still see it, and require probe() to
#     refuse whenever any of them cannot.
#
#     THREE DAMAGE CLASSES, and that is the second half of this case's history. The first version
#     mutated ONE WAY — it dropped whole fields — so it could only ever discover a PRESENCE bug. The
#     readers do not key on presence: `active_commands` and `_prune_finished` compare `state` to a
#     constant. `{"state": "actve"}` is present, truthy, invisible to both, and sailed through a
#     probe that called the ledger readable (F37, reopened). A one-shape mutation set manufactures
#     false confidence, so the shapes here are derived from the damage a HAND-EDITED JSON file can
#     actually take: a field DELETED, a value CORRUPTED into a near-miss of a legal one, and a value
#     SUBSTITUTED for a different type that is still truthy.
full_cmd = {"session_id": "s1", "command": "/idc:build", "issue": 42, "state": "active"}
#     THE READERS ARE ASKED UNSCOPED. `active_commands(repo, "s1")` also returns [] when the record
#     names a DIFFERENT session — which is the reader doing its job, not an obligation hiding — so
#     scoping the query here would report a fault for a free-form field that has no fault. The
#     session-scoped view is asserted in the POSITIVE half below, where the record really is s1's.
READERS = {
    "read_state.commands": lambda: L.read_state(repo)["commands"],
    "active_commands (the Stop closeout gate's reader)": lambda: L.active_commands(repo),
}
write({"version": 2, "taints": [], "commands": [dict(full_cmd)]})
if any(len(fn()) != 1 for fn in READERS.values()):
    sys.exit("precondition: every reader must see a FULL command record before this can discriminate")


def typo(value):
    """A plausible near-miss of `value` — the shape a hand-edit produces, not a wild value."""
    if isinstance(value, str) and len(value) > 4:
        return value[:3] + value[4:]        # "active" -> "actve"
    if isinstance(value, int) and not isinstance(value, bool):
        return value + 1
    return f"{value}-typo"


DAMAGE = {
    "deleted": lambda rec, f: {k: v for k, v in rec.items() if k != f},
    "corrupted to a near-miss value": lambda rec, f: {**rec, f: typo(rec[f])},
    "substituted for a truthy value of another type": lambda rec, f: {**rec, f: True},
}
for field in sorted(full_cmd):
    for how, damage in sorted(DAMAGE.items()):
        write({"version": 2, "taints": [], "commands": [damage(dict(full_cmd), field)]})
        blind = sorted(name for name, fn in READERS.items() if len(fn()) == 0)
        ok, detail = L.probe(repo)
        if blind and ok:
            sys.exit(f"a command record whose {field!r} was {how} is INVISIBLE to "
                     f"{', '.join(blind)}, yet probe() called the ledger trustworthy ({detail!r}) — "
                     f"a real open command hides behind it while the gate that must close it is told "
                     f"there is nothing to close")
        if blind and field not in detail:
            sys.exit(f"the refusal must NAME the field so an operator can repair the file by hand; "
                     f"{field!r} {how} said: {detail!r}")

# (2) POSITIVE — a record carrying exactly the identity is VISIBLE TO EVERY READER. This is the half
#     that keeps the predicate honest: a tuple that refused everything would pass (1) trivially.
write({"version": 2, "taints": [{"kind": "mid_finish", "key": "42"}], "commands": [full_cmd]})
ok, detail = L.probe(repo)
if not ok:
    sys.exit(f"a well-formed ledger was refused: {detail!r}")
if not L.read_taints(repo):
    sys.exit("probe() vouched for a ledger whose taint `read_taints` cannot see")
if not L.pending_taints(repo):
    sys.exit("probe() vouched for a ledger whose taint `pending_taints` cannot see")
if not L.read_state(repo)["commands"]:
    sys.exit("probe() vouched for a ledger whose command `read_state` cannot see")
if not L.active_commands(repo, "s1"):
    sys.exit("probe() vouched for a ledger whose ACTIVE command `active_commands` cannot see — that "
             "is the reader the Stop closeout gate uses, so the obligation is hidden from the gate")
os.remove(path)
PY
echo "  ok R4/R26: an unreadable ledger and an identity-less entry are indeterminate; what the probe vouches for, every reader sees"

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
# ...and the SAME repo addressed one directory down. Git walks UP to find a repository, so it prints
# the identical "not a git repository" here while the subdirectory has no `.git` of its own — the
# hollow clean came straight back for any caller passing a path below the root.
mkdir -p "$R5B/sub"
chmod 000 "$R5B/.git"
out5c="$(python3 "$COH" --repo "$R5B/sub" --tracker "$R5B/TRACKER.md" 2>&1)"; rc5c=$?
chmod 755 "$R5B/.git"
[ "$rc5c" = 0 ] \
  && fail "R5: a SUBDIRECTORY of a repo git could not read was reported as \`not-applicable\` (exit 0) — the unreadable .git is one level up, which is where git looks. Got: $out5c"
[ "$rc5c" = 2 ] \
  || fail "R5: an unreadable git repo must be INDETERMINATE (exit 2) from a subdirectory too, got rc=$rc5c out=$out5c"
# ...and a genuinely non-git subdirectory must still be not-applicable, so this is not "every path is
# now indeterminate".
mkdir -p "$R5/sub"
out5d="$(python3 "$COH" --repo "$R5/sub" --tracker "$R5/TRACKER.md" 2>&1)"; rc5d=$?
[ "$rc5d" = 0 ] && printf '%s' "$out5d" | grep -q 'not-applicable' \
  || fail "R5: a genuinely non-git subdirectory must stay not-applicable, got rc=$rc5d out=$out5d"
echo "  ok R5: a non-git dir is not-applicable; an unreadable one is indeterminate from root and below"

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
# The FILESYSTEM path re-runs the drain and has its stdout, so when the verdict is the coherence gap
# the block both carries the checker's line and tells the operator to read it.
fs_detail = "drain: coherence-gap, recirc_inbox=0, finish-coherence: gap #41 #42"
fs_reason = G._block_reason(fs_detail, [], "/plugin/root")
if "#41" not in fs_reason or "see the `finish-coherence: gap <#s>` line above" not in fs_reason:
    sys.exit(f"the block carries the finding line but does not tell the operator to read it: {fs_reason!r}")

# ...and on the GITHUB path it must not point at output that cannot exist. There the block is raised
# from the persisted verdict, which records {verdict, exit} and no checker lines at all — so "see the
# `finish-coherence: gap <#s>` line" sends the operator looking for something they cannot get, the
# same unrunnable-cure defect as an unresolved ${CLAUDE_PLUGIN_ROOT}.
gh_detail = "github (persisted: drain: coherence-gap, exit 4)"
gh_reason = G._block_reason(gh_detail, [], "/plugin/root")
if "see the `finish-coherence: gap <#s>` line" in gh_reason:
    sys.exit("the github-path block tells the operator to read a checker line the persisted verdict "
             "never carried: " + gh_reason)
if "finish-coherence: gap <#s>" not in gh_reason or "idc_autorun_drain.py" not in gh_reason:
    sys.exit(f"the github-path block must still name the line AND how to get it: {gh_reason!r}")
for token, detail_ in (("live", "github (persisted: drain: live-gap, exit 4)"),
                       ("acceptance", "github (persisted: drain: acceptance-gap, exit 4)")):
    r = G._block_reason(detail_, [], "/plugin/root")
    if "line above" in r:
        sys.exit(f"the github-path {token} block points at output it does not carry: {r!r}")
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
echo "  ok R16: a crashed checker's verdict line names its exit code and the cause on its stderr"

echo "== R23. AND THAT TAIL MUST NOT CARRY A CREDENTIAL — WHICHEVER SHAPE IT IS"
# ITS OWN CASE AND ITS OWN BANNER, deliberately. R23 used to live inside R16's heredoc, so both were
# guarded by one shell `fail` string: dropping the scrub at the drain door printed "a crashed
# checker's return code and stderr are lost", while what had actually tripped was a token reaching
# the verdict line. An operator was told the wrong thing about the wrong defect.
#
# THE FIXTURE SET IS THE POINT. The first version of this case used ONLY `ghp_…` — the one shape the
# PROSE-SAFE table already knew — so it passed against a door wired to the wrong profile and proved
# nothing: `password=…`, `Authorization: Basic …` and `Authorization: token …` all walked straight
# through. Every shape in the MACHINE-OUTPUT profile is driven here, from LITERAL samples — never
# derived from the patterns, which is what would make the case grade itself.
#
# The tail travels: the drain prints it, the Stop gate scrapes it back with `_drain_detail`, and
# `_annotate_forced_exit_once` interpolates it into a TRACKER.md comment — an ordinary TRACKED file,
# so the destination is committed git history.
R23="$WORK/leaking-checker"; mkrepo "$R23"
python3 - "$PLUGIN" "$R23" <<'PYR23' || fail "R23: a credential on a crashed checker's stderr reaches the drain verdict line and the Stop gate's board comment"
import importlib.util, os, sys
plugin, repo = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("D", os.path.join(plugin, "scripts", "idc_autorun_drain.py"))
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
gate_spec = importlib.util.spec_from_file_location(
    "G", os.path.join(plugin, "scripts", "hooks", "idc_stop_fixpoint_gate.py"))
G = importlib.util.module_from_spec(gate_spec); gate_spec.loader.exec_module(G)

name = "idc_zz_repro_leaking_checker.py"
path = os.path.join(plugin, "scripts", name)

# (label, the stderr line the checker dies printing, the exact substring that must NOT survive).
# Every one is a LITERAL. The `ghs_` token is deliberately too short for the bare-token rule, so the
# `token <secret>` header arm is the only thing that can catch it.
CASES = [
    ("a git remote whose URL carries a token",
     "fatal: unable to access 'https://git-user:{s}@github.com/o/r': 403",
     "ghp_" + "A1b2C3d4E5f6G7h8I9j0"),
    ("a named secret in the config the checker dumped",
     "KeyError while reading config: password={s} DISTINCTIVE-CAUSE",
     "hunter2xyzzy"),
    ("a Basic auth header echoed by a failing request",
     "request failed: Authorization: Basic {s} DISTINCTIVE-CAUSE",
     "QWxhZGRpbjpvcGVuc2VzYW1l"),
    ("a `token` auth header echoed by a failing request",
     "request failed: Authorization: token {s} DISTINCTIVE-CAUSE",
     "ghs_shortonehere"),
    ("a bearer header echoed by a failing request",
     "request failed: Authorization: Bearer {s} DISTINCTIVE-CAUSE",
     "abcdefghijklmnop"),
]
for label, template, secret in CASES:
    body = "import sys\nsys.stderr.write(%r)\nsys.exit(3)\n" % (template.format(s=secret) + "\n")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    try:
        verdict, line = D._run_wave_close_check(name, [], "acceptance", ("acceptance: ok",), 60)
    finally:
        os.remove(path)
    if verdict != "error":
        sys.exit(f"precondition [{label}]: the leaking checker must still classify as error, "
                 f"got {verdict!r}")
    if secret in (line or ""):
        sys.exit(f"[{label}] a credential on a crashed checker's stderr reached the drain verdict "
                 f"line, which is printed, scraped by the Stop gate and committed into a TRACKER.md "
                 f"comment: {line!r}")
    # …and the same string at the sink the gate actually writes: `_drain_detail` scrapes the drain's
    # stdout, and its output is what lands in the board comment body.
    detail = G._drain_detail("drain: unknown\n" + (line or "") + "\n")
    if secret in (detail or ""):
        sys.exit(f"[{label}] the credential survived into the Stop gate's board-comment detail: "
                 f"{detail!r}")

# FALSE-POSITIVE CONTROL — the scrub must not eat the diagnostic. A tail that names nothing is the
# defect R16 exists to prevent, so "redact everything" would trade one finding for the other.
with open(path, "w", encoding="utf-8") as fh:
    fh.write("import sys\n"
             "sys.stderr.write('fatal: DISTINCTIVE-CAUSE while opening TRACKER.md\\n')\n"
             "sys.exit(3)\n")
try:
    verdict, line = D._run_wave_close_check(name, [], "acceptance", ("acceptance: ok",), 60)
finally:
    os.remove(path)
if "DISTINCTIVE-CAUSE" not in (line or "") or "TRACKER.md" not in (line or ""):
    sys.exit(f"the scrub ate the diagnostic instead of a credential — the tail exists to name the "
             f"cause an operator has to act on: {line!r}")
PYR23
echo "  ok R23: five credential shapes on a crashed checker's stderr are scrubbed at the door; the diagnostic survives"

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

# R7 — a resume whose clear FAILED must have a legal outcome, and the blocker must be RE-DERIVED: a
# surviving pause record is present before EVERY ordinary resume, so grounding on it alone certifies
# "I was blocked" for a session that never ran the clear at all.
with open(os.path.join(repo, ".idc-pause-state.json"), "w", encoding="utf-8") as fh:
    fh.write('{"version":1,"state":"paused","session_id":"s1","requested_ts":1.0,'
             '"confirmed_by":"s1","confirmed_ts":2.0,'
             '"quiescence":{"verdict":"ok","checked_ts":2.0}}')
v = C.validate_closeout("resume", "complete", EV, repo=repo, session="s1")
if v.ok:
    sys.exit("resume closed COMPLETE while the pause record still exists")

# THE INVENTED BLOCKER — the record is there, and nothing is stopping the clear from succeeding.
v = C.validate_closeout("resume", "blocked_external",
                        blocker_ev("idc_pause_state.py", 2, "could not remove the pause record"),
                        repo=repo, session="s1")
if v.ok:
    sys.exit("a resume closed as blocked_external in a repo where the clear would SUCCEED — the "
             "surviving record is the ordinary pre-resume state, so it cannot distinguish a failed "
             "attempt from a session that walked away")

# ...and when the removal really is impossible, the honest outcome is reachable. This is driven
# through the REAL helper, not a planted artifact: the repo root is made unwritable, which is what
# makes `os.remove` fail in the first place.
os.chmod(repo, 0o555)
try:
    import subprocess
    r = subprocess.run([sys.executable, os.path.join(plugin, "scripts", "idc_pause_state.py"),
                        "--cwd", repo, "resume", "--session", "s1"],
                       capture_output=True, text=True)
    if r.returncode != 2:
        sys.exit(f"precondition: an unremovable pause record must exit 2, got {r.returncode}: {r.stdout}{r.stderr}")
    v = C.validate_closeout("resume", "blocked_external",
                            blocker_ev("idc_pause_state.py", 2, "could not remove the pause record"),
                            repo=repo, session="s1")
    if not v.ok:
        sys.exit(f"a resume whose pause-record clear FAILED has no legal terminal outcome: "
                 f"blocked_external was refused with {v.reason_code!r} ({v.message})")
finally:
    os.chmod(repo, 0o755)

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

# ...and a caller cannot smuggle its OWN `derived` block into the record. `derived` means "this was
# proven at closeout"; a claim list that re-derived nothing used to return the caller's evidence
# untouched, so a hand-written block was persisted verbatim under the one key that is supposed to be
# unforgeable by construction.
forged = {"schema_version": 1, "refs": {},
          "derived": {"resume_survey": {"exit": 0, "findings": [], "note": "nothing to see here"}}}
v = C.validate_closeout("resume", "complete", forged, repo=repo, session="s1")
if not v.ok:
    sys.exit(f"precondition: this closeout must still be valid, got {v.reason_code}")
got = (v.normalized_evidence or {}).get("derived", {}).get("resume_survey", {})
if got.get("note") == "nothing to see here":
    sys.exit(f"a caller-supplied `derived` block was persisted verbatim: {got!r}")
# ...and on the path where nothing is re-derived at all, it must be stripped rather than passed through.
v = C.validate_closeout("janitor", "no_action",
                        {"schema_version": 1, "refs": {}, "derived": {"anything": 1}},
                        repo=repo, session="s1")
if v.ok and "anything" in (v.normalized_evidence or {}).get("derived", {}):
    sys.exit("a caller-supplied `derived` survived on a closeout that re-derived nothing")
PY
echo "  ok R7/R8: a failed record-clear is a grounded blocker; complete carries a re-derived survey"

echo "== R22. A BLOCKED PAUSE/AUTORUN MUST PROVE IT WAS BLOCKED  [F24, F23]"
# F24 — `/idc:pause` writes its record in step 1, BEFORE anything can fail, so grounding its
# pause-state blocker on "a record still exists" was satisfied for the entire life of every honest
# invocation: a session could walk away from a pause it could have taken and call itself blocked.
# F23 — `commands/autorun.md` tells a run whose preflight resume exits 2 to close as blocked_external
# citing this helper, but autorun's allowlist did not list it, so on the exact failure path the
# instruction was written for the command could not close at all.
R22="$WORK/blocked-proof"; mkrepo "$R22"
python3 - "$PLUGIN" "$R22" <<'PY' || fail "R22: a blocked pause/autorun closeout is not grounded in what actually failed"
import os, sys
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_command_contract as C

def blocker_ev(exit_code, diagnostic="the pause record did not persist"):
    return {"schema_version": 1,
            "refs": {"blocker": {"helper": "idc_pause_state.py", "exit": exit_code,
                                 "diagnostic": diagnostic}}}

# THE INVENTED BLOCKER: a healthy, quiescent repo where an honest pause was fully achievable, and
# `commands/pause.md` step 1 has already written the record — which is why the record's own presence
# could never ground this.
v = C.validate_closeout("pause", "blocked_external", blocker_ev(1), repo=repo, session="s1")
if v.ok:
    sys.exit("/idc:pause closed as blocked_external in a repo where the pause could be recorded — a "
             "session can walk away from a pause it could have taken honestly, claiming it was denied")

# THE UNATTEMPTED PAUSE (F45). Making recording impossible is a fact about the REPO, not about this
# run: if permissions alone grounded the blocker, any /idc:pause could skip `idc_pause_state.py
# confirm` entirely, type an exit and a diagnostic, and close as blocked without ever trying. So the
# same unwritable git directory, with NO attempt behind it, must still be refused.
gitdir = os.path.join(repo, ".git")
os.chmod(gitdir, 0o555)
try:
    v = C.validate_closeout("pause", "blocked_external", blocker_ev(1), repo=repo, session="s1")
    if v.ok:
        sys.exit("/idc:pause closed as blocked citing a failed record WRITE it never attempted — the "
                 "repo's permissions were the only evidence, and those are true of every run in this "
                 "repo, including the ones that walked away")
finally:
    os.chmod(gitdir, 0o755)

# ...and when the run really DID try and recording really IS impossible, the honest outcome is
# reachable. `commands/pause.md` step 1 runs `request` before anything can fail, and a `confirm` that
# cannot write its mark leaves that record at `pause-requested` — the one artifact the attempt
# produces in the very state being claimed. The git directory is where the confirmation mark goes, so
# a repo whose git dir cannot be written to genuinely cannot record a pause even though its root is fine.
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_pause_state as PAUSE
rec, created = PAUSE.request(repo, "s1", command="pause")
if not created:
    sys.exit("precondition: the pause request must be recorded before the attempt can be witnessed")
os.chmod(gitdir, 0o555)
try:
    _rec, code, _verdict, _findings = PAUSE.confirm(repo, "s1")
    if code == 0:
        sys.exit("precondition: `confirm` must FAIL with an unwritable git directory, or this case is "
                 "not testing the state it claims")
    v = C.validate_closeout("pause", "blocked_external", blocker_ev(1), repo=repo, session="s1")
    if not v.ok:
        sys.exit(f"a pause that was really attempted and whose confirmation could not be recorded has "
                 f"no legal terminal outcome: {v.reason_code} ({v.message})")
    # ...and another session's abandoned attempt is not this one's evidence.
    v = C.validate_closeout("pause", "blocked_external", blocker_ev(1), repo=repo, session="s-other")
    if v.ok:
        sys.exit("a `pause-requested` record left by a DIFFERENT session grounded this run's blocked "
                 "stop — an attempt is evidence only for the session that made it")
finally:
    os.chmod(gitdir, 0o755)
os.remove(os.path.join(repo, ".idc-pause-state.json"))

# F23 — /idc:autorun's preflight runs the SAME clear /idc:resume does, so it must be able to close on
# it. This is the close `commands/autorun.md` prescribes verbatim on `resume: error` (exit 2).
with open(os.path.join(repo, ".idc-pause-state.json"), "w", encoding="utf-8") as fh:
    fh.write('{"version":1,"state":"paused","session_id":"s2","requested_ts":1.0,'
             '"confirmed_by":"s2","confirmed_ts":2.0,"quiescence":{"verdict":"ok","checked_ts":2.0}}')
ev = blocker_ev(2, "the pause record could not be removed")
os.chmod(repo, 0o555)
try:
    v = C.validate_closeout("autorun", "blocked_external", ev, repo=repo, session="s2")
    if not v.ok:
        sys.exit(f"/idc:autorun cannot close with the outcome commands/autorun.md prescribes on "
                 f"`resume: error`: {v.reason_code} ({v.message})")
finally:
    os.chmod(repo, 0o755)

# ...and once the root is writable again the same claim is refused: the clear can simply be run.
v = C.validate_closeout("autorun", "blocked_external", ev, repo=repo, session="s2")
if v.ok:
    sys.exit("/idc:autorun closed as blocked on a pause record it could have cleared")
PY
echo "  ok R22: an invented pause blocker is refused; pause and autorun can close on a real one"

echo "== R21. THE PAUSE WRITER MUST ENFORCE WHAT ITS STRICTEST READER REQUIRES  [F28]"
# `_is_paused` refuses a record with a blank `session_id`/`confirmed_by`, but `confirm` — unlike
# `request` — had no such guard. `confirm --session ""` therefore printed `pause: paused` /
# `pause-ready: ok` and exited 0 while writing a record the Stop gate reads as dishonest: the operator
# is told the pause succeeded, and the gate then blocks their stop three times before loud-failing.
R21="$WORK/writer-reader"; mkrepo "$R21"
out21="$(python3 "$PS" --cwd "$R21" confirm --session "" 2>&1)"; rc21=$?
[ "$rc21" = 0 ] \
  && fail "R21: confirm --session \"\" reported a successful pause, but the Stop gate refuses a record with no session identity. Got: $out21"
printf '%s' "$out21" | grep -q 'pause-ready: ok' \
  && fail "R21: a refused pause must not print a clean readiness line. Got: $out21"
python3 "$PS" --cwd "$R21" status | grep -q '^pause: none' \
  || fail "R21: a refused confirm must leave NO pause record, got: $(python3 "$PS" --cwd "$R21" status)"
# ...and after a REAL confirm the writer and the strictest reader must agree, in both directions.
python3 - "$PS" "$GATE" "$R21" <<'PY' || fail "R21: the pause writer and the Stop gate disagree about the same record"
import importlib.util, os, sys
plugin = os.environ["IDC_PLUGIN"]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_pause_state as PS
gspec = importlib.util.spec_from_file_location("G", sys.argv[2])
G = importlib.util.module_from_spec(gspec); gspec.loader.exec_module(G)
repo = sys.argv[3]
rec, code, verdict, findings = PS.confirm(repo, "r21-session")
if code != 0:
    sys.exit(f"precondition: a quiescent repo must be pausable, got exit {code} ({verdict})")
if not PS.is_paused(repo):
    sys.exit("the writer does not consider its own confirmed record a pause")
if not G._is_paused(repo):
    sys.exit("the writer recorded a pause the Stop gate refuses — the operator would be told the "
             "pause succeeded and then blocked from stopping")
# The closeout is the third reader of the same record, and it must agree too.
import idc_command_contract as C
v = C.validate_closeout("build", "paused", {"schema_version": 1, "refs": {}}, repo=repo, session="r21-session")
if not v.ok:
    sys.exit(f"a real pause cannot close a run as paused: {v.reason_code} ({v.message})")

# ...and a caller cannot smuggle its own `derived` block through a claim that re-derives nothing.
# `derived` means "this was PROVEN at closeout"; when the claim list produced nothing the caller's
# evidence used to be returned untouched, so a hand-written block was persisted verbatim under the
# one key that exists to be unforgeable. `/idc:pause complete` is exactly such a claim.
forged = {"schema_version": 1, "refs": {}, "derived": {"pause": {"note": "nothing to see here"}}}
v = C.validate_closeout("pause", "complete", forged, repo=repo, session="r21-session")
if not v.ok:
    sys.exit(f"precondition: a real pause must close /idc:pause as complete: {v.reason_code} ({v.message})")
if "derived" in (v.normalized_evidence or {}):
    sys.exit(f"a caller-supplied `derived` block was persisted verbatim into the lifecycle record: "
             f"{(v.normalized_evidence or {}).get('derived')!r}")
# ...and a record with no confirmation behind it cannot, even in a perfectly quiescent repo — which is
# the case that makes the corroboration a guard rather than a formality.
PS._clear_confirmation(repo)
v = C.validate_closeout("build", "paused", {"schema_version": 1, "refs": {}}, repo=repo, session="r21-session")
if v.ok:
    sys.exit("an uncorroborated pause record closed a run as `paused` — a typed record is not a pause")
PY
echo "  ok R21: a session-less confirm is refused; writer, Stop gate and closeout agree on a real one"

echo "== R18. THE RETENTION CUT MUST NOT SEVER A CREDENTIAL'S LABEL  [F20]"
# R1 fixed the DISPLAY cut. `_drain_bounded` takes an EARLIER cut, over raw bytes, before any
# redaction has run: it keeps only the last `_MAX_RETAINED_BYTES`, so the buffer's first token is a
# fragment whenever the probe printed more than that. A cut through `password=` leaves
# `word=hunter2xyzzy`, which the named-secret rule can no longer match (its label is gone) and the
# opaque-run backstop is too short to catch — and the display cut does not save it, because a buffer
# full of long tokens REDACTS below MAX_BODY_CHARS, so no second cut ever happens and the whole
# fragment-headed buffer is written to the COMMITTED receipt.
python3 - "$LIVE" "$WORK" <<'PY' || fail "R18: a credential whose label the RETENTION cut severed reaches the committed receipt"
import importlib.util, os, re, shlex, sys
spec = importlib.util.spec_from_file_location("L", sys.argv[1])
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
work = sys.argv[2]
keep = L._MAX_RETAINED_BYTES

# A probe whose output is built so the retention cut lands at a CHOSEN offset inside `password=`.
# `sever` is how many bytes of the credential survive the cut: 17 leaves `word=hunter2xyzzy`.
probe = os.path.join(work, "r18-probe.py")
with open(probe, "w", encoding="utf-8") as fh:
    fh.write(
        "import sys\n"
        "keep, sever, cred = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]\n"
        # `sep` is what separates the filler tokens. '\\n' is the ordinary chatty-probe shape; ';' is
        # the buffer that contains NO WHITESPACE AT ALL, where there is no boundary to cut back to.
        "sep = sys.argv[4].replace('NL', '\\n')\n"
        # The leading separator keeps the marker OFF the end of the filler run — glued on, the two
        # form a 40-char opaque token and the backstop legitimately redacts the marker itself.
        "marker = sep + 'TAIL-MARKER' + sep\n"
        # Long opaque runs, so the RETAINED buffer redacts BELOW MAX_BODY_CHARS and no display cut
        # occurs — which is what lets the severed head reach the receipt in the first place.
        "line = 'Z' * 64 + sep\n"
        "after = sep + (line * (keep // len(line) + 2))\n"
        "after = after[:keep - sever - len(marker)] + marker\n"
        # The leading noise must be LARGER THAN THE WHOLE RETAINED WINDOW, or a `sever` past the head
        # quarantine makes the total output shorter than `keep`, nothing overflows, and the case
        # silently stops exercising the retention cut it was written for.
        "sys.stdout.write(('startup noise' + sep) * (keep // 13 + 40) + cred + after)\n")

def body(sever, cred, sep="NL"):
    # SHELL-QUOTED: an auth header carries spaces, and unquoted it would arrive as three argv words.
    s = {"name": "web", "verify_raw": f"python3 {probe} {keep} {sever} {shlex.quote(cred)} {sep!r}",
         "verify": "probe", "timeout": 60}
    rc, out, _ = L.run_verify(work, s, "0" * 40)
    if rc != 0:
        sys.exit(f"precondition: the probe must succeed, got rc={rc} out={out[:200]!r}")
    return out

# THE LEAK: the cut falls after `pass`, so only `word=hunter2xyzzy` is retained.
leaked = body(17, "password=hunter2xyzzy")
if "hunter2xyzzy" in leaked:
    sys.exit("a credential whose LABEL was severed by the retention cut survived redaction and was "
             "written to the receipt: " + leaked[:160].replace("\n", " "))
# ...and the receipt must still be USABLE — dropping the severed head must not empty it.
if "TAIL-MARKER" not in leaked:
    sys.exit(f"the receipt lost the end of the capture, which is where a failure's reason is: {leaked[:200]!r}")
if "…[truncated]…" not in leaked:
    sys.exit(f"a genuinely partial capture lost its truncation marker: {leaked[:200]!r}")

# THE SAME LEAK WITH NO WHITESPACE ANYWHERE in the retained buffer — `;`-separated output, which a
# probe piping JSON or a `set -x` trace really does produce. There is no boundary to cut back to, so
# the whole tail is one severed token and none of it can be attributed. The display cut does not save
# this either: the filler redacts far below MAX_BODY_CHARS, so no second cut ever happens.
dense = body(17, "password=hunter2xyzzy", sep=";")
if "hunter2xyzzy" in dense:
    sys.exit("a severed credential survived in a capture with NO whitespace boundary — there is "
             "nothing to cut back to, so the unattributable tail must not be shown: " + dense[:160])
if "[REDACTED]" not in dense:
    sys.exit(f"the unattributable tail was silently deleted rather than marked: {dense[:200]!r}")

# ...AND A CREDENTIAL WHOSE ANCHOR IS A SEPARATE WORD, not part of the same token. This is the case
# the token-sized repair could not reach: severing `Basic` destroys the rule's anchor and leaves the
# credential standing as the very next token, verbatim, in the COMMITTED receipt. One case per rule
# family whose anchor is whitespace-separated, each with the anchor-INTACT control below.
AUTH_SECRET = "QWxhZGRpbjpvcGVuc2VzYW1l"          # 24 chars: too short for the 40-char backstop
for verb in ("Basic", "token", "Bearer"):
    header = f"Authorization: {verb} {AUTH_SECRET}"
    # keep the last `len(secret) + 4` bytes of the header, so the cut lands INSIDE the verb
    cut_inside_verb = body(len(AUTH_SECRET) + 4, header)
    if AUTH_SECRET in cut_inside_verb:
        sys.exit(f"a credential whose `{verb}` anchor the retention cut severed reached the receipt "
                 f"verbatim: {cut_inside_verb[:160]!r}")
    # the anchor-INTACT control for the same rule, beyond the quarantine: still redacted, by its rule
    whole = body(len(header) + L._HEAD_QUARANTINE_BYTES + 50, header)
    if AUTH_SECRET in whole:
        sys.exit(f"an INTACT `{verb}` header was not redacted by its own rule: {whole[:200]!r}")

# THE QUARANTINE'S SIZE IS LOAD-BEARING, not just its existence. A straddling match's remnant can be
# thousands of bytes long with the secret at the END of it — an auth header whose verb and token are
# separated by a run of whitespace, which wrapped or pretty-printed header output produces, is the
# ordinary shape. A quarantine sized by anything other than the rules' own reach cuts back to the
# first whitespace INSIDE that run and hands the credential straight through.
padded = "Authorization: Basic" + " " * 40 + AUTH_SECRET
spread = body(len("sic") + 40 + len(AUTH_SECRET), padded)
if AUTH_SECRET in spread:
    sys.exit(f"a credential separated from its severed anchor by whitespace survived — the head "
             f"quarantine is not sized by the redaction table's own reach: {spread[:200]!r}")

# ...and a PEM block cut through its BEGIN line: the header the rule anchors on is gone, so the key
# body survives as base64 the opaque backstop cannot fully match — and the receipt loses the one
# thing a reviewer needs, which is that a PRIVATE KEY was here rather than an unnamed token.
KEY_LINE = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ+/"
pem_probe = os.path.join(work, "r18-pem.py")
with open(pem_probe, "w", encoding="utf-8") as fh:
    fh.write(
        "import sys\n"
        "keep, line = int(sys.argv[1]), sys.argv[2]\n"
        "pem = ('-----BEGIN RSA PRIVATE KEY-----\\n' + (line + '\\n') * 30\n"
        "       + '-----END RSA PRIVATE KEY-----\\n')\n"
        # Size everything AFTER the BEGIN line to exactly `keep + 8`, so the retention cut lands 8
        # bytes into the header: the rule's anchor is destroyed and its footer is still in the buffer.
        # The filler is long opaque runs so the retained buffer REDACTS below MAX_BODY_CHARS and no
        # display cut happens — otherwise the receipt shown to a reviewer is the last 4 KB and the
        # marker at the head of the buffer is never in it, which is not what this case is asking.
        "marker = 'PEM-TAIL-MARKER\\n'\n"
        "filler = 'Z' * 64 + '\\n'\n"
        "rest = (pem + filler * (keep // len(filler) + 2))[:keep + 8]\n"
        "sys.stdout.write('n' * 5000 + rest[:-len(marker)] + marker)\n")
s_pem = {"name": "web", "verify_raw": f"python3 {pem_probe} {keep} {KEY_LINE}",
         "verify": "probe", "timeout": 60}
rc, pem_body, _ = L.run_verify(work, s_pem, "0" * 40)
if rc != 0:
    sys.exit(f"precondition: the PEM probe must succeed, got rc={rc}")
if KEY_LINE in pem_body:
    sys.exit(f"private-key body survived a cut through the BEGIN line: {pem_body[:200]!r}")
if "[REDACTED PRIVATE KEY]" not in pem_body:
    sys.exit("a severed PEM block lost the one fact a reviewer needs — that a PRIVATE KEY was here, "
             f"not an unnamed token: {pem_body[:200]!r}")
if "PEM-TAIL-MARKER" not in pem_body:
    sys.exit(f"the severed-block rule ate the output AFTER the key: {pem_body[:200]!r}")

# POSITIVE CONTROL 1 — an INTACT label BEYOND THE HEAD QUARANTINE is still redacted by name, so this
# is not "everything is always redacted" passing for a fix. The boundary is the module's own derived
# constant, not a magic number: past `_HEAD_QUARANTINE_BYTES` no straddling match can reach, so the
# left context is genuinely restored and the named rule is expected to do its own work.
intact = body(len("password=hunter2xyzzy") + L._HEAD_QUARANTINE_BYTES + 50, "password=hunter2xyzzy")
if "hunter2xyzzy" in intact:
    sys.exit(f"an intact `password=` was not redacted: {intact[:200]!r}")
if "password=[REDACTED]" not in intact:
    sys.exit(f"the intact credential was not redacted BY NAME (its label should survive): {intact[:200]!r}")

# ...and the converse, which is the F33 rule itself: an INTACT credential sitting INSIDE the
# quarantine is destroyed anyway, because the cut could equally have severed the anchor of a rule
# that would have matched it, and nothing in that region can be told apart.
inside = body(len("password=hunter2xyzzy") + 50, "password=hunter2xyzzy")
if "hunter2xyzzy" in inside:
    sys.exit(f"a credential inside the head quarantine survived: {inside[:200]!r}")

# POSITIVE CONTROL 2 — the truncation signal must SURVIVE the head redaction. A capture that is one
# huge token redacts to a handful of characters, so deciding the marker from what is left declares a
# 17 KB fragment complete: the same lost-signal defect as deciding it from the post-redaction length,
# one boundary earlier. The overflow has to travel with the text.
s = {"name": "web", "verify_raw": f"python3 -c \"print('x' * {keep})\"", "verify": "probe", "timeout": 60}
rc, one_token, _ = L.run_verify(work, s, "0" * 40)
if rc != 0:
    sys.exit(f"precondition: the one-token probe must succeed, got rc={rc}")
if "[REDACTED]" not in one_token:
    sys.exit(f"a {keep}-char opaque run reached the receipt unredacted: {one_token[:120]!r}")
if "…[truncated]…" not in one_token:
    sys.exit(f"a capture the RETENTION cut truncated lost its `…[truncated]…` marker once the severed "
             f"head was redacted — a fragment now reads as the whole story: {one_token[:120]!r}")

# POSITIVE CONTROL 3 — a capture that never overflowed must keep its FIRST line: the head redaction
# fires only when bytes were actually discarded.
s = {"name": "web", "verify_raw": "python3 -c \"print('FIRST-LINE'); print('second')\"",
     "verify": "probe", "timeout": 60}
rc, short, _ = L.run_verify(work, s, "0" * 40)
if rc != 0 or "FIRST-LINE" not in short:
    sys.exit(f"a short capture lost its first line — the head-drop must fire only on overflow: {short!r}")

# THE DERIVATION'S TEETH. The quarantine is only a closed answer if it is COMPUTED from the redaction
# table — typed, it is one more thing to forget when a rule changes, which is how this defect reached
# its third boundary. Two properties, asserted rather than asserted-in-a-comment:
#   (a) a rule with a LONGER bound raises the quarantine by itself;
#   (b) a rule nobody can MEASURE, and that declares no structural family, refuses to load at all —
#       fail-closed, because a redactor nobody has sized is one the quarantine cannot promise to cover.
saved = L._REDACTORS
try:
    L._REDACTORS = saved + ((re.compile(r"ZZ-[A-Za-z]{1,9000}"), "[REDACTED]"),)
    grown = L._head_quarantine_bytes()
    if grown < 9000:
        sys.exit(f"a redaction rule that can match 9000 characters did not raise the head quarantine "
                 f"({grown}) — the bound is not derived from the table, so the next rule with a longer "
                 f"reach will silently outrun it")
    L._REDACTORS = saved + ((re.compile(r"ZZ-[A-Za-z]+"), "[REDACTED]"),)
    try:
        L._head_quarantine_bytes()
        sys.exit("a redaction rule with an UNMEASURABLE reach, registered in no structural family, "
                 "was accepted — the quarantine silently stops covering it and nothing says so")
    except RuntimeError:
        pass
finally:
    L._REDACTORS = saved
PY
echo "  ok R18: a severed credential head is dropped, an intact one is redacted, short output is intact"

echo "== R19. AN UNCOMMITTED PROBE MUST NOT PRODUCE A RECEIPT NAMING HEAD  [F21]"
# F11 refused a run over a dirty tree but scoped it to `paths:`; F12 added the verifier's own files to
# the FRESHNESS set only. So the probe itself was unguarded on the ATTRIBUTION side: weaken the verify
# script, leave the edit UNCOMMITTED, and the run records `live: ok` against a HEAD that never
# contained that probe — `git log` cannot see an uncommitted change, so freshness never fires either.
R19="$WORK/probe-attribution"; mkrepo "$R19"; mkdir -p "$R19/scripts" "$R19/services"
echo v1 > "$R19/services/app.py"
cat > "$R19/WORKFLOW-config.yaml" <<'EOF'
project:
  name: demo
live_verification:
  surfaces:
    - name: web
      verify: bash scripts/verify.sh
      paths: [services/]
EOF
# The COMMITTED probe reports the product broken, which is the honest verdict for this repo.
printf '#!/bin/bash\necho "the chat step failed"\nexit 1\n' > "$R19/scripts/verify.sh"
git -C "$R19" add -A; git -C "$R19" commit -qm declare
out19a="$(python3 "$LIVE" --repo "$R19" --run 2>&1)"; rc19a=$?
[ "$rc19a" = 1 ] \
  || fail "R19: precondition — a committed, FAILING probe must report a product gap (exit 1), got rc=$rc19a out=$out19a"
git -C "$R19" add -A; git -C "$R19" commit -qm evidence

# Weaken the probe and DO NOT COMMIT IT. The product is untouched and still broken.
printf '#!/bin/bash\nexit 0\n' > "$R19/scripts/verify.sh"
out19b="$(python3 "$LIVE" --repo "$R19" --run 2>&1)"; rc19b=$?
[ "$rc19b" = 0 ] \
  && fail "R19: an UNCOMMITTED edit to the verify script produced a passing receipt for code HEAD never contained. Got: $out19b"
[ "$rc19b" = 2 ] \
  || fail "R19: an unattributable run is INDETERMINATE (exit 2), got rc=$rc19b out=$out19b"
printf '%s' "$out19b" | grep -q 'scripts/verify.sh' \
  || fail "R19: the refusal must NAME the probe file that is uncommitted, got: $out19b"
# ...and the read-only audit must not report the pre-existing receipt as clean either.
out19c="$(python3 "$LIVE" --repo "$R19" 2>&1)"; rc19c=$?
[ "$rc19c" = 0 ] \
  && fail "R19: the read-only audit reported live: ok off a receipt produced by an uncommitted probe. Got: $out19c"
git -C "$R19" checkout -- scripts/verify.sh

# The WHOLESALE replacement: `--untracked-files=no` hides it. Untrack the probe, leave the file in
# place — git reports a clean tracked tree while the thing that runs is code no commit contains.
git -C "$R19" rm -q --cached scripts/verify.sh
git -C "$R19" commit -qm "untrack the probe"
printf '#!/bin/bash\nexit 0\n' > "$R19/scripts/verify.sh"
out19d="$(python3 "$LIVE" --repo "$R19" --run 2>&1)"; rc19d=$?
[ "$rc19d" = 0 ] \
  && fail "R19: an UNTRACKED verify script produced a passing receipt — the -uno scan hid a wholesale probe replacement. Got: $out19d"
[ "$rc19d" = 2 ] \
  || fail "R19: an untracked probe must be INDETERMINATE (exit 2), got rc=$rc19d out=$out19d"

# THE IGNORED PROBE — `git status` NEVER reports an ignored file, in ANY untracked mode, so scanning
# harder could not have caught this: one `.gitignore` line (or a probe living under an already-ignored
# `node_modules/.bin`, which is where half of them live) reproduces the wholesale replacement with the
# tree reading perfectly clean. The receipt would say `live: ok` at a commit that contains no probe.
printf 'scripts/verify.sh\n' >> "$R19/.gitignore"
git -C "$R19" add .gitignore; git -C "$R19" commit -qm "ignore the probe"
git -C "$R19" status --porcelain --untracked-files=all -- scripts/verify.sh | grep -q . \
  && fail "R19: precondition — an ignored probe must be INVISIBLE to git status, or this case is not testing what it claims"
out19e="$(python3 "$LIVE" --repo "$R19" --run 2>&1)"; rc19e=$?
[ "$rc19e" = 0 ] \
  && fail "R19: a GITIGNORED verify script produced a passing receipt — git status cannot see an ignored file, so attribution must not be asking it. Got: $out19e"
[ "$rc19e" = 2 ] \
  || fail "R19: an ignored probe must be INDETERMINATE (exit 2), got rc=$rc19e out=$out19e"
printf '%s' "$out19e" | grep -q 'scripts/verify.sh' \
  || fail "R19: the refusal must NAME the ignored probe, got: $out19e"

# POSITIVE CONTROL — the same repo, probe COMMITTED and matching HEAD byte for byte, must run clean.
# Without this, "refuse everything" passes every case above while silently disabling the live gate.
printf '#!/bin/bash\nexit 0\n' > "$R19/scripts/verify.sh"
git -C "$R19" rm -q --cached .gitignore >/dev/null 2>&1 || true
rm -f "$R19/.gitignore"
git -C "$R19" add -f scripts/verify.sh; git -C "$R19" add -A
git -C "$R19" commit -qm "re-commit the probe"
out19f="$(python3 "$LIVE" --repo "$R19" --run 2>&1)"; rc19f=$?
[ "$rc19f" = 0 ] \
  || fail "R19: POSITIVE CONTROL — a probe COMMITTED and identical to HEAD must audit clean, got rc=$rc19f out=$out19f"
echo "  ok R19: an uncommitted, untracked or ignored probe cannot be attributed to HEAD; a committed one runs"

# R27 — `watched_paths` says it is THE ONE DEFINITION both rules read. It had ONE caller, and the
# attribution rule re-derived the identical composition inline: the two agreed by coincidence of
# authorship, which is precisely the drift the function was introduced to end. A docstring asserting a
# property the code does not have is the defect, in a PR about not overstating. So: add a source to
# the door and require the consumer to see it — an inline re-derivation cannot.
python3 - "$LIVE" "$R19" <<'PY' || fail "R27: a consumer re-derives the watched set instead of reading it from the one door"
import importlib.util, os, subprocess, sys
spec_ = importlib.util.spec_from_file_location("L", sys.argv[1])
L = importlib.util.module_from_spec(spec_); spec_.loader.exec_module(L)
repo = sys.argv[2]
surface = {"name": "web", "paths": ["services/"], "verify_raw": "bash scripts/verify.sh",
           "verify": "bash scripts/verify.sh", "timeout": 60}
# a TRACKED, committed file that is now dirty — invisible to the rule unless the door reports it
extra = os.path.join(repo, "extra_source.py")
open(extra, "w", encoding="utf-8").write("v1\n")
subprocess.run(["git", "-C", repo, "add", "extra_source.py"], check=True)
subprocess.run(["git", "-C", repo, "commit", "-qm", "extra"], check=True)
open(extra, "w", encoding="utf-8").write("v2 — uncommitted\n")
if "extra_source.py" in L._dirty_paths(repo, surface):
    sys.exit("precondition: the extra path must NOT be watched until the door reports it")
door = L.watched_paths
L.watched_paths = lambda r, s: L.Watched(door(r, s).declared + ["extra_source.py"], door(r, s).probe)
try:
    if "extra_source.py" not in L._dirty_paths(repo, surface):
        sys.exit("the attribution rule did not see a source ADDED TO `watched_paths` — it is "
                 "re-deriving the set itself, so the two rules agree only by coincidence and the "
                 "next source added to the door will be watched by one of them and not the other")
finally:
    L.watched_paths = door
os.remove(extra)
subprocess.run(["git", "-C", repo, "rm", "-q", "--cached", "extra_source.py"], check=True)
PY
echo "  ok R27: both rules read the watched set from the one function that defines it"

echo "== R20. THE RUN WITNESS BELONGS TO THE REPOSITORY, NOT THE CHECKOUT  [F22]"
# `--absolute-git-dir` resolves inside a LINKED WORKTREE to `<main>/.git/worktrees/<name>`, which is
# private to that worktree and deleted with it. IDC's own build topology makes that the normal case:
# the wave-close `--run` happens in a per-item worktree and `idc_autorun_drain.py` audits from the
# MAIN checkout after the merge. The genuine measurement then read as "hand-written, or arrived in a
# commit", and `git worktree remove` destroyed the proof for good.
R20="$WORK/worktree-witness"; mkrepo "$R20"; mkdir -p "$R20/scripts" "$R20/services"
echo v1 > "$R20/services/app.py"
cat > "$R20/WORKFLOW-config.yaml" <<'EOF'
project:
  name: demo
live_verification:
  surfaces:
    - name: web
      verify: bash scripts/verify.sh
      paths: [services/]
EOF
printf '#!/bin/bash\necho "journey ok"\nexit 0\n' > "$R20/scripts/verify.sh"
git -C "$R20" add -A; git -C "$R20" commit -qm declare
WT20="$WORK/worktree-witness-wt"
git -C "$R20" worktree add -q -b feat "$WT20" || fail "R20: could not create the linked worktree"

# The wave-close run happens INSIDE the linked worktree, exactly as agents/idc-build.md drives it.
out20="$(python3 "$LIVE" --repo "$WT20" --run 2>&1)"; rc20=$?
[ "$rc20" = 0 ] || fail "R20: precondition — the run inside the worktree must pass, got rc=$rc20 out=$out20"
[ -f "$R20/.git/idc/live-runs.json" ] \
  || fail "R20: the witness was not written to the SHARED git directory — a worktree-private witness dies with the worktree"

# Merge the wave back and audit from the MAIN checkout, which is where the drain audits from.
git -C "$WT20" add -A; git -C "$WT20" commit -qm evidence
git -C "$R20" merge -q --no-edit feat || fail "R20: could not merge the wave back"
out20b="$(python3 "$LIVE" --repo "$R20" 2>&1)"; rc20b=$?
[ "$rc20b" = 0 ] \
  || fail "R20: a genuine worktree-built run audits as a GAP from the main checkout — the drain would refuse a wave that really was verified. Got: $out20b"

# ...and it must SURVIVE teardown: `git worktree remove` deletes the worktree's private git dir.
git -C "$R20" worktree remove --force "$WT20" || fail "R20: could not remove the worktree"
out20c="$(python3 "$LIVE" --repo "$R20" 2>&1)"; rc20c=$?
[ "$rc20c" = 0 ] \
  || fail "R20: the run witness was DESTROYED by worktree teardown, so a verified wave became unprovable. Got: $out20c"
echo "  ok R20: the witness lives in the shared git dir, is visible from main, and survives teardown"

echo "== R24. THE ENFORCING TABLE AND THE SHIPPED PLAYBOOK, FOR EVERY COMMAND  [F36, F39]"
# THE THIRD INSTANCE of one defect. A command's terminal statuses live in TWO artifacts — the claim
# table the validator enforces, and the `--status <…>` menu the agent reads — and they were compared
# only where a drift had been REPORTED: `autorun`/`pause`/`resume` were brought back into line, and
# nothing looked at the other ten. `/idc:uninstall` documented a `blocked_external` its allowlist
# refused BY NAME, so on the exact Phase-0 stop the playbook makes MANDATORY the prescribed close was
# rejected and the lifecycle record stayed open. `build`/`autorun`/`recirculate` had the mirror
# defect: a legal `paused` terminal an agent reading only its own playbook could never discover.
#
# So this case is EXHAUSTIVE over the commands rather than over the drifts somebody noticed. It is
# the only durable answer to "why are the two artifacts duplicated": both are real (one validates,
# one instructs) and neither can be deleted, so the check has to cover all of them.
python3 - "$PLUGIN" <<'PY' || fail "R24: a shipped playbook and the enforcing table disagree about a command's closeout"
import os, re, sys
plugin = sys.argv[1]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_command_contract as C

problems = []
for cmd in sorted(C.COMMANDS):
    path = os.path.join(plugin, "commands", f"{cmd}.md")
    if not os.path.isfile(path):
        problems.append(f"/idc:{cmd} has no shipped playbook at commands/{cmd}.md")
        continue
    md = open(path, encoding="utf-8").read()
    menu = re.search(r"--status <([^>]+)>", md)
    if not menu:
        problems.append(f"/idc:{cmd} prints no `--status <…>` menu, so an agent cannot discover its "
                        f"legal terminals at all")
        continue
    documented, enforced = set(menu.group(1).split("|")), set(C.LEGAL_STATUSES[cmd])
    for extra in sorted(documented - enforced):
        problems.append(f"/idc:{cmd} DOCUMENTS the terminal {extra!r} that the claim table refuses — "
                        f"the playbook prescribes a close the validator rejects, so that stop has no "
                        f"legal outcome and its lifecycle record stays open")
    for missing in sorted(enforced - documented):
        problems.append(f"/idc:{cmd} may legally close as {missing!r} and its own playbook never says "
                        f"so — an agent reading it cannot discover an outcome its record can take")
    # ...and the same question for HOW a blocked stop is cited. Every helper the allowlist grants must
    # be NAMED in the command's own playbook, and every condition it may cite likewise: a citation the
    # agent cannot look up is a close it will not make.
    for helper in sorted(C._BLOCKER_HELPERS.get(cmd, set())):
        if helper not in md:
            problems.append(f"/idc:{cmd} may cite the blocking helper {helper!r} and its playbook "
                            f"never names it")
    for cond in sorted(C._CONDITIONS_FOR_COMMAND.get(cmd, set())):
        if cond not in md:
            problems.append(f"/idc:{cmd} may cite the blocking condition {cond!r} and its playbook "
                            f"never names it")
    if "blocked_external" in enforced and not (C._BLOCKER_HELPERS.get(cmd)
                                               or C._CONDITIONS_FOR_COMMAND.get(cmd)):
        problems.append(f"/idc:{cmd} may close as blocked_external with nothing it is allowed to "
                        f"cite — every blocked stop would be refused")
if problems:
    sys.exit("\n".join("  - " + p for p in problems))
PY
echo "  ok R24: all 13 playbooks and the claim table agree on terminals and on what a blocker may cite"

echo "== R25. A MANDATED PHASE-0 STOP MUST HAVE A LEGAL CLOSE  [F36]"
# The substance behind R24 for the case that was actually deadlocked: `/idc:uninstall` Phase 0 makes a
# dirty working tree a hard STOP, and the entry gate has already opened the lifecycle record by then.
# A dirty tree is not any helper's exit code, so no helper citation could ground it honestly — the
# close is grounded by RE-DERIVING the condition read-only, and refused when it no longer holds.
R25="$WORK/uninstall-dirty"; mkrepo "$R25"
python3 - "$PLUGIN" "$R25" <<'PY' || fail "R25: uninstall's mandated dirty-tree stop has no legal close"
import os, subprocess, sys
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_command_contract as C

def ev(**blocker):
    return {"schema_version": 1, "refs": {"blocker": blocker}}


# The ledger file is transient working state and a governed repo gitignores it (the scaffold wires
# `idc_ledger.ensure_gitignored`). Do the same here, and COMMIT it, or opening a record would itself
# dirty the tree — which would make every case below reason about the test harness's own footprint
# instead of about the operator's changes.
import idc_ledger
idc_ledger.ensure_gitignored(repo)
subprocess.run(["git", "-C", repo, "add", ".gitignore"], check=True)
subprocess.run(["git", "-C", repo, "commit", "-qm", "ignore the ledger"], check=True)


def open_uninstall_record(session):
    """Open the lifecycle record exactly as the entry gate does — which is what stamps the
    entry-condition snapshot the closeout reads."""
    rec = C.register_start(repo, session, "uninstall", "0.0.0", "", "user")
    if not rec:
        sys.exit(f"precondition: could not open the /idc:uninstall record for {session!r}")
    return rec


# Session s1 opens its record while the repo is CLEAN — the ordinary case, and the one the
# self-manufactured blocker below depends on.
open_uninstall_record("s1")

# A CLEAN repo: the claim is refused, because the condition it names does not hold. This is the half
# that keeps the new door from becoming a way to invent a blocked stop.
clean = C.validate_closeout("uninstall", "blocked_external",
                            ev(condition="dirty_tree", diagnostic="uncommitted operator changes"),
                            repo=repo, session="s1")
if clean.ok:
    sys.exit("an invented dirty-tree blocker CLOSED a uninstall run in a clean repo — the condition "
             "must be re-derived, not asserted")
if clean.reason_code != "blocked-external-condition-not-blocked":
    sys.exit(f"the refusal must name the re-derivation, got {clean.reason_code!r}: {clean.message}")

# THE SELF-MANUFACTURED BLOCKER (F47). s1 started in a clean repo and now dirties a tracked file — as
# /idc:uninstall genuinely does while it works. Re-deriving the condition read-only says only that it
# holds NOW, which is equally true of a tree the operator dirtied and of one the command dirtied
# itself, so per-command narrowing does not stop a command manufacturing its own stop. The record
# carries what the re-derivation cannot: whether the condition was already there when the run opened.
with open(os.path.join(repo, "app.py"), "w", encoding="utf-8") as fh:
    fh.write("edited by the command itself\n")
selfmade = C.validate_closeout("uninstall", "blocked_external",
                               ev(condition="dirty_tree", diagnostic="uncommitted changes"),
                               repo=repo, session="s1")
if selfmade.ok:
    sys.exit("a /idc:uninstall run that started CLEAN and dirtied a tracked file as part of its own "
             "work closed as blocked_external on the tree it had just dirtied — the command "
             "manufactured the condition it then cited")
if selfmade.reason_code != "blocked-external-condition-not-at-entry":
    sys.exit(f"the refusal must name the entry snapshot, got {selfmade.reason_code!r}: "
             f"{selfmade.message}")

# ...now the real stop the playbook mandates: a run that finds the tree ALREADY dirty when it opens.
open_uninstall_record("s2")
blocked = C.validate_closeout("uninstall", "blocked_external",
                              ev(condition="dirty_tree", diagnostic="uncommitted operator changes"),
                              repo=repo, session="s2")
if not blocked.ok:
    sys.exit(f"the Phase-0 dirty-tree stop the playbook MANDATES has no legal close: "
             f"{blocked.reason_code} — {blocked.message}")

# ...and the snapshot is taken ONCE, at the start of the obligation. If re-entry re-took it, s1 could
# simply run /idc:uninstall again and inherit the tree its first pass dirtied.
open_uninstall_record("s1")
reentered = C.validate_closeout("uninstall", "blocked_external",
                                ev(condition="dirty_tree", diagnostic="uncommitted changes"),
                                repo=repo, session="s1")
if reentered.ok:
    sys.exit("re-entering /idc:uninstall RE-TOOK the entry snapshot, so the run inherited the dirty "
             "tree its own first pass created — the snapshot belongs to the obligation, not to the "
             "latest invocation")

# The archive exemption Phase 0 prints: a re-run must not self-block on its own backup tarball.
subprocess.run(["git", "-C", repo, "checkout", "--", "app.py"], check=True)
with open(os.path.join(repo, "idc-archive-2026.tar.gz"), "w", encoding="utf-8") as fh:
    fh.write("backup")
exempt = C.validate_closeout("uninstall", "blocked_external",
                             ev(condition="dirty_tree", diagnostic="uncommitted operator changes"),
                             repo=repo, session="s1")
if exempt.ok:
    sys.exit("a previous run's untracked idc-archive tarball counted as a dirty tree, so a re-run "
             "self-blocks — Phase 0 exempts it by name")

# ...and the condition is not a skeleton key: a command whose playbook mandates no such stop is refused.
for other in ("build", "janitor", "init"):
    r = C.validate_closeout(other, "blocked_external",
                            ev(condition="dirty_tree", diagnostic="d"), repo=repo, session="s1")
    if r.ok:
        sys.exit(f"/idc:{other} closed as blocked citing a condition its playbook does not mandate a "
                 f"stop for — any command could then touch a file and manufacture a blocked stop")
PY
echo "  ok R25: uninstall's mandated dirty-tree stop closes; an invented one, an exempt one and a foreign one do not"

echo "== R29. LIFTING A PAUSE MEANS LIFTING BOTH HALVES OF IT, AND EVERY READER AGREES  [F50, F51]"
# TWO NEIGHBOURS OF THE SAME FIX. Round 2 made a pause record UNFORGEABLE by corroborating it against
# a witness in the git directory, and applied that at ONE writer and ONE reader.
#   F50 — `clear()` removed the record and dropped the witness BEST-EFFORT, reporting success even
#         when the witness survived. The witness is what makes the record unforgeable, so one that
#         outlives its record means a later hand-written COPY of that same record is honoured again,
#         with no new confirmation and no quiescence check: the replay the witness exists to prevent,
#         re-armed by the clear that was supposed to end it.
#   F51 — `is_paused()` and `--status` still answered from the record ALONE, so the operator was told
#         the repo was paused about a record the Stop gate refuses to honour. A reader that answers a
#         different question from the gate is a reader that lies to whoever asks it.
R29="$WORK/pause-witness"; mkrepo "$R29"
python3 - "$PLUGIN" "$R29" <<'PYR29' || fail "R29: a lifted pause leaves a witness that re-arms the replay, or a reader disagrees with the Stop gate about the same record"
import importlib.util, json, os, shutil, stat, sys
plugin, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_pause_state as PAUSE
gate_spec = importlib.util.spec_from_file_location(
    "G", os.path.join(plugin, "scripts", "hooks", "idc_stop_fixpoint_gate.py"))
G = importlib.util.module_from_spec(gate_spec); gate_spec.loader.exec_module(G)

PAUSE.request(repo, "s1", command="pause")
rec, code, verdict, _findings = PAUSE.confirm(repo, "s1")
if code != 0 or not rec:
    sys.exit(f"precondition: a quiescent repo must be pausable, got code={code} verdict={verdict!r}")
witness = PAUSE.witness_path(repo)
if not os.path.exists(witness):
    sys.exit("precondition: a real confirm must record its witness in the git directory")

# (1) EVERY READER AGREES ON THE GENUINE PAUSE — the positive control, first, so a guard that simply
#     refused everything could not pass this case.
if not (PAUSE.is_paused(repo) and G._is_paused(repo)):
    sys.exit(f"a genuinely confirmed pause is not seen as paused by both readers: "
             f"is_paused={PAUSE.is_paused(repo)} stop_gate={G._is_paused(repo)}")

# (2) F51 — STRIP THE WITNESS, KEEP THE RECORD. The Stop gate refuses it; every other reader must
#     refuse it too, and `--status` must SAY SO rather than printing a confident "paused".
saved = open(witness, "rb").read()
os.remove(witness)
if G._is_paused(repo):
    sys.exit("precondition: the Stop gate must refuse an uncorroborated record, or this case cannot "
             "discriminate")
if PAUSE.is_paused(repo):
    sys.exit("`is_paused` reports PAUSED for a record the Stop gate refuses — the operator is told "
             "the run is safely stopped while the gate is about to block their stop")
described = PAUSE._describe(repo, PAUSE.read_record(repo))
if "UNCORROBORATED" not in described:
    sys.exit(f"`--status` must name the uncorroborated record so the operator can act on it, "
             f"got: {described!r}")
with open(witness, "wb") as fh:
    fh.write(saved)

# (3) F50 — A CLEAR THAT CANNOT REMOVE THE WITNESS MUST NOT REPORT SUCCESS. Make the witness's
#     directory unwritable, keeping the repo root writable, and lift the pause.
wdir = os.path.dirname(witness)
mode = stat.S_IMODE(os.stat(wdir).st_mode)
os.chmod(wdir, 0o555)
try:
    try:
        PAUSE.clear(repo)
        failed = False
    except PAUSE.ClearFailed:
        failed = True
    if not failed:
        sys.exit("`clear` reported the pause LIFTED while its confirmation witness survived. "
                 "Re-planting a copy of that record is then honoured again with no new confirmation "
                 "and no quiescence check — the replay the witness exists to prevent, re-armed by "
                 "the clear that was supposed to end it")
finally:
    os.chmod(wdir, mode)

# ...and the replay it protects against is real: with the witness still present, put the record back
# by hand and the Stop gate honours it — which is why the failed clear had to be reported.
if os.path.exists(witness):
    with open(PAUSE.pause_path(repo), "w", encoding="utf-8") as fh:
        json.dump(rec, fh)
    if not G._is_paused(repo):
        sys.exit("precondition: a re-planted record matching a surviving witness must be honoured, "
                 "or the surviving witness costs nothing and F50 is not a finding")

# (4) POSITIVE CONTROL — an ordinary clear, with both halves writable, still succeeds and leaves the
#     checkout witness-free. Confinement must not become "refuse every clear".
lifted = PAUSE.clear(repo)
if lifted is None:
    sys.exit("a clean clear reported that nothing was paused")
if os.path.exists(witness):
    sys.exit("a successful clear left the witness behind")
if PAUSE.is_paused(repo) or G._is_paused(repo):
    sys.exit("the pause survived a successful clear")
PYR29
echo "  ok R29: an uncorroborated record is refused by every reader and named by --status; a clear that cannot drop the witness fails loudly; a clean clear still lifts the pause"

echo "== R28. THE CREDENTIAL SCRUB IS A PROPERTY OF THE TEXT, NOT A HABIT OF THE CALLER"
# THE FINDING THIS CLOSES, and why the previous four fixes could not. F1 → F20 → F33 → F35 → F40 are
# one finding reported five times: a credential reaches a persisted artifact because the module that
# read it did not scrub it. Each round scrubbed the site that had just been reported. The reason the
# next site always existed is that `idc_credential_shapes.py` told every caller to "keep its own
# context-sensitive rules" — so which rules ran was an unaided judgement call taken once per caller,
# with nothing checking the answer. The drain answered it wrong (it wired the PROSE profile through a
# door built for machine output, F46) and `idc_pr_finish.py` never answered it at all (F40).
#
# So this case asserts the two halves that make "every producer is covered" checkable:
#   (1) the MACHINE-OUTPUT profile really redacts every shape it claims to, at all three consumers —
#       driven by LITERAL samples, never derived from the patterns, which is what made the old R23
#       grade itself; and the PROSE profile is genuinely still the narrower one.
#   (2) a CENSUS over every module in scripts/: each read of a child process's stderr passes through
#       the scrub at the read, or is named in the registry below with a reason. Fail-closed BOTH
#       ways — a new unscrubbed read fails, and a registry entry that no longer matches a real line
#       fails too, so the list cannot rot into a blanket exemption.
python3 - "$PLUGIN" <<'PYR28' || fail "R28: a child process's stderr can reach a persisted artifact unscrubbed, or the machine-output profile does not cover what it claims"
import glob, importlib.util, os, re, shutil, subprocess, sys, tempfile
plugin = sys.argv[1]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_credential_shapes as CS


def load(rel, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(plugin, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── (1) THE PROFILE, DRIVEN BY LITERAL SAMPLES ───────────────────────────────────────────────────
D = load("scripts/idc_autorun_drain.py", "D")
L = load("scripts/idc_live_check.py", "L")
# (rule it exercises, a sample line, the substring that must not survive)
SAMPLES = [
    ("url userinfo",   "fatal: unable to access 'https://u:{s}@github.com/o/r': 403",
     "ghp_" + "A1b2C3d4E5f6G7h8I9j0"),
    ("bearer header",  "request failed: Authorization: Bearer {s} while reading",
     "abcdefghijklmnop"),
    ("basic header",   "request failed: Authorization: Basic {s} while reading",
     "QWxhZGRpbjpvcGVuc2VzYW1l"),
    ("token header",   "request failed: Authorization: token {s} while reading",
     "ghs_shortonehere"),
    ("named secret",   "config load failed: password={s} at line 3",
     "hunter2xyzzy"),
    ("bare token run", "gh: bad credentials for {s} (401)",
     "github_pat_" + "11ABCDEFG0abcdefghijklmno"),
    ("pem block",
     "-----BEGIN RSA PRIVATE KEY-----\n{s}\n-----END RSA PRIVATE KEY-----",
     "MIIEowIBAAKCAQEAsecretkeymaterialhere"),
]
CONSUMERS = {
    "idc_credential_shapes.scrub (the door)": CS.scrub,
    "idc_autorun_drain._scrub (the drain's checker output)": D._scrub,
    "idc_live_check.redact (the committed evidence receipt)": L.redact,
}
for rule, template, secret in SAMPLES:
    text = template.format(s=secret)
    for who, fn in CONSUMERS.items():
        if secret in (fn(text) or ""):
            sys.exit(f"the {rule} rule does not cover {who}: {secret!r} survived {fn(text)!r}. "
                     f"A door is only as good as the profile wired through it — see F46, where the "
                     f"drain's door was real and its rule set was the prose-safe one.")

# …and the PROSE profile must still be the NARROWER one, or "two profiles" is a distinction with no
# difference and intake has silently inherited rules that mangle a human-authored document. These are
# intake's own documented false-positive controls.
def prose_scrub(text):
    for pattern, repl in CS.bake(CS.SHAPES, "[REDACTED]"):
        text = pattern.sub(repl, text)
    return text

for survivor in ("TOKENIZER_MODEL=gpt-4", "KEYBOARD_LAYOUT=dvorak", "COMPASS_MODE=true",
                 "Authorization: Basic understanding of the pipeline"):
    if prose_scrub(survivor) != survivor:
        sys.exit(f"the PROSE-safe profile now mangles {survivor!r} — intake's false-positive controls "
                 f"exist because a human-authored document is not machine output, and intake HARD "
                 f"REJECTS where the live check merely redacts")
# …and the widening is real, on the two samples that separate the profiles: a substring "token", and
# an auth verb that is also an ordinary English word.
for widened in ("TOKENIZER_MODEL=gpt-4", "Authorization: Basic understanding of the pipeline"):
    if CS.scrub(widened) == widened:
        sys.exit(f"the MACHINE-OUTPUT profile left {widened!r} intact, so it is not actually wider "
                 f"than the prose floor — the named-secret rule or the Basic/token arms are missing "
                 f"from it, which is exactly the gap F46 found inside the drain's own door")

# ── (2) THE CENSUS ───────────────────────────────────────────────────────────────────────────────
# A read of a completed child process's stderr. `sys.stderr`, a `stderr=` keyword and comments are not
# reads of child output.
READ = re.compile(r"(?<![\w.])(\w+)\.stderr\b")
# (module, the exact stripped source line) -> why this read may stay raw. Both entries CLASSIFY the
# text (a substring match that decides which exception to raise); neither puts it into a message, and
# both feed sites that DO scrub before the text escapes.
ALLOWED_RAW = {
    ("scripts/idc_gh_board.py", "if _is_rate_limit_stderr(p.stderr):"):
        "rate-limit detection: matches fixed markers to choose RateLimitError over BoardReadError; "
        "the message built two lines down is scrubbed",
    ("scripts/idc_command_contract.py",
     'if _github_project_absence_error(proc.stderr or "", project):'):
        "absence detection: decides present/absent/indeterminate from fixed gh wording; the text is "
        "never carried into the result",
}
bare, seen_allowed = [], set()
for path in sorted(glob.glob(os.path.join(plugin, "scripts", "*.py"))
                   + glob.glob(os.path.join(plugin, "scripts", "hooks", "*.py"))):
    rel = os.path.relpath(path, plugin)
    for lineno, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        if line.startswith("#") or "stderr=" in line:
            continue
        m = READ.search(line)
        if not m or m.group(1) == "sys":
            continue
        if (rel, line) in ALLOWED_RAW:
            seen_allowed.add((rel, line))
            continue
        if "scrub" not in line:
            bare.append(f"{rel}:{lineno}: {line}")
if bare:
    sys.exit("a child process's stderr is read WITHOUT passing through the scrub at the read. Every "
             "one of these travels into a message that is printed, persisted, or committed — which "
             "is the whole of F1/F20/F33/F35/F40. Scrub it at the read (`CS.scrub` in scripts/, "
             "`H.scrub` in scripts/hooks/), or register it in ALLOWED_RAW with a reason:\n  "
             + "\n  ".join(bare))
stale = sorted(set(ALLOWED_RAW) - seen_allowed)
if stale:
    sys.exit("ALLOWED_RAW names a line that no longer exists — an exemption that outlives its site is "
             "how an allowlist rots into a blanket pass. Remove or re-point it:\n  "
             + "\n  ".join(f"{mod}: {ln}" for mod, ln in stale))

# ── (3) THE FALLBACK CANNOT DRIFT INTO A PASS-THROUGH ────────────────────────────────────────────
# The scrub-door import is TOLERANT (several of these modules run as lone relocated copies — see
# phase1-pipe-safety F) and therefore carries a fallback. A fallback that returns the text unchanged
# would disable the scrub everywhere the table is missing, silently. So every copy must be BYTE
# IDENTICAL to the canonical one, and the canonical one must WITHHOLD.
MARK = "# THE CREDENTIAL SCRUB DOOR"
blocks = {}
for path in sorted(glob.glob(os.path.join(plugin, "scripts", "*.py"))):
    text = open(path, encoding="utf-8").read()
    if MARK not in text:
        continue
    start = text.index(MARK)
    end = text.index("is not importable]", start)
    blocks[os.path.relpath(path, plugin)] = text[start:end]
if len(blocks) < 2:
    sys.exit(f"expected the tolerant scrub-door import in several modules, found {sorted(blocks)}")
canon_name, canon = sorted(blocks.items())[0]
for name, block in sorted(blocks.items()):
    if block != canon:
        sys.exit(f"the scrub-door import block in {name} differs from {canon_name}. It is duplicated "
                 f"on purpose (these modules must stay runnable as lone relocated copies), and the "
                 f"only thing keeping that duplication safe is that every copy is identical — a "
                 f"divergent fallback is a silent pass-through")
# …and the fallback is asserted by BEHAVIOUR, not by reading it: relocate a module away from the
# table exactly as the governance suites do, and ask it what it does with a credential. This runs in a
# SUBPROCESS with cwd at the temp directory, because this process already has scripts/ on sys.path and
# would import the real table and prove nothing.
probe = os.path.join(tempfile.mkdtemp(prefix="idc-r28-reloc-"), "idc_gh_board.py")
shutil.copyfile(os.path.join(plugin, "scripts", "idc_gh_board.py"), probe)
proc = subprocess.run(
    [sys.executable, "-c",
     "import idc_gh_board as M; print(M.CS.scrub('password=hunter2xyzzy'))"],
    cwd=os.path.dirname(probe), capture_output=True, text=True,
    env={**os.environ, "PYTHONPATH": ""})
if proc.returncode != 0:
    sys.exit(f"a lone RELOCATED copy of idc_gh_board.py no longer imports — the scrub-door import "
             f"must stay tolerant (phase1-pipe-safety F): {proc.stderr.strip()[:300]}")
if "hunter2xyzzy" in proc.stdout:
    sys.exit("with the credential table absent, the tolerant import's fallback PASSED THE TEXT "
             "THROUGH. It must WITHHOLD: a withheld diagnostic costs one re-run by hand, an "
             f"unscrubbed one costs a credential rotation. Got: {proc.stdout.strip()!r}")
PYR28
echo "  ok R28: the machine-output profile covers all three consumers, the prose floor stays narrower, and no module reads a child's stderr unscrubbed"

echo "phase11-honesty-repro: OK"
