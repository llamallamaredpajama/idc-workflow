#!/bin/bash
# idc-assert-class: behavior
# Phase 4 (completion honesty) smoke — the two gates that close the "merged + reviewed was read as
# finished" failure class. Real git repos, real merges, a real filesystem board, no GitHub.
#
# WHAT WENT WRONG (the failure this suite guards). A governed repo reported a phase complete while
#   (a) seven fully-merged, issue-closed items still showed `In Progress` on the board, and
#   (b) the deployed app could neither ingest nor open an item — its buckets were never created and a
#       runtime env var was never set, none of which appear in any reviewed diff.
# Both slipped because the pipe's definition of "finished" was "the build lane is empty". The
# detectors for (a) already existed (idc_git_janitor.board_coherence_verdict) but nothing consulted
# them on a path that could FAIL anything; nothing at all existed for (b).
#
# THE TWO GUARDS UNDER TEST
#   scripts/idc_finish_coherence.py — does the board still claim work that already shipped?
#   scripts/idc_live_check.py       — does the project's DECLARED live surface actually WORK, measured
#                                     by running the project's own verify command against the code
#                                     that is running now?
# plus their wiring into idc_autorun_drain.py's wave close, where exit 4 is already the code the Stop
# fixpoint gate refuses a stop on (so enforcement needs no new hook).
#
# THE SECOND GATE WAS REBUILT (section G). Its first cut required a HUMAN to drive the deployed app and
# hand-write an evidence note. That is wrong twice: it wakes an operator in the middle of an unattended
# run to answer a question the pipeline can answer itself, and a typed claim is not a measurement — the
# same optimism that read "merged" as "works" reads "I tested it" as "it works". The project now
# declares a `verify:` COMMAND per surface and IDC RUNS it; the verdict is that command's real exit
# code and the evidence is a machine-generated receipt. Sections B and G split along that seam: B
# audits the RECORD's rules, G proves the record comes from a real execution (every case there uses a
# verify script that leaves a filesystem sentinel, so "it ran" is observed, never inferred).
#
# RED-WHEN-BROKEN. Every guard below was broken in the real source, one at a time, and observed to turn
# this suite RED before it was committed (16 mutations for the original two gates; 19 more for the
# executable rebuild). That discipline paid again: G5 was written for a bounded-output rule and instead
# exposed a real hang — redaction ran over the WHOLE capture with an unbounded quantifier, so a verify
# script printing 400 KB wedged the gate for minutes AFTER its timeout could no longer save it. Fixed
# by truncating before redacting and bounding every quantifier.
#
# THREE HONEST EXCEPTIONS, stated rather than glossed:
#   1. The commit-EXISTENCE rule in idc_live_check.py cannot be shown red on its own, because any
#      commit that fails `rev-parse` also fails the `merge-base --is-ancestor` rule right after it. It
#      was verified functional in isolation (with the ancestor rule disabled it still rejects a
#      fabricated sha), and the ancestor rule IS individually proven by B7b. Treat the existence check
#      as a better error message for a case the ancestor rule already catches, not an independent guard.
#   2. G2 (the default AUDIT path must execute nothing) is NOT isolated. Making the audit execute turns
#      the suite red at B3 first, because section B's fixture declares a verify script that does not
#      exist on disk — the same defect, caught one section earlier. G2 states the property by mechanism
#      (the sentinel), and the mutation IS caught; it is simply not caught by G2's own line.
#   3. G0 (an undeclared repo executes nothing even under --run) cannot be shown red by a single edit:
#      with zero declared surfaces there is nothing to iterate over, so no one-line change makes it
#      execute. It is a guard against a future regression that synthesizes a default surface, and it is
#      asserted by mechanism — but nobody should read it as having been proven red.
#
# The single edit that makes each assertion fail:
#   * A1/A2  delete the `if f.get("op") not in STALE_OPS: continue` filter in idc_finish_coherence.py
#            → A2 still passes but A1 goes RED (unrelated janitor debris starts reporting as a gap).
#   * F1     drop the `board_scanned is not True` guard → F1 goes RED. The real janitor genuinely
#            exits 0 with `{"verdict":"coherent","board_scanned":false}` when given no board, so
#            without this guard a scan that never looked at a board reads as a clean bill of health.
#   * A2c    turn the not-applicable branch into an error → A2c goes RED (a non-git repo becomes
#            permanently unable to reach an honest `drain: complete`).
#   * B7b    disable the `merge-base --is-ancestor` rule → B7b goes RED (evidence taken on an
#            unmerged branch starts counting as proof of what shipped).
#   * E2/E3  delete the flags from the Stop gate's real argv / the playbooks' real command lines
#            → both go RED (they did NOT before these assertions were scoped to the invocation).
#   * A5     revert the verdict token from `gap` back to any other word → A5 and D1 go RED.
#   * B4     delete the `git log <commit>..HEAD -- <paths>` staleness branch in idc_live_check.py
#            → B4 goes RED (evidence never expires; the gate becomes a one-time checkbox).
#   * B6     change the corrupt-marker branch from `_fail` (exit 2) to a returned reason (exit 1)
#            → B6 goes RED (damaging an evidence file becomes a way to get a mere "gap", and via the
#            drain classifier a corrupted file would no longer be distinguishable from an honest one).
#   * B2     make `surfaces: []` parse as anything other than "not declared" → B2 goes RED (every
#            repo on earth, including libraries and CLIs, becomes gated on a live surface).
#   * C1/C2  remove `--coherence` / `--live` handling from idc_autorun_drain.py → those go RED.
#   * C4     re-order the gates so a would-be-`complete` skips them → C4 goes RED.
#   * E1     lower `_DRAIN_TIMEOUT` in the Stop gate to <= the drain's COHERENCE_TIMEOUT → E1 goes RED
#            (a slow scan would then wedge a stop instead of degrading to "allow and retry").
#   * E2     drop `--coherence`/`--live` from the Stop gate's drain re-run → E2 goes RED (the
#            filesystem stop path stops enforcing what the drain loop enforces).
#
# The executable rebuild's mutations (all run, all observed RED at the named assertion unless noted):
#   * G1      make `--run` skip run_verify/write_evidence → G1 RED (nothing is ever executed).
#   * G3      write the receipt only when the command passed → G3 RED (yesterday's PASS survives
#             today's failure, so the audit keeps reporting ok while the product is broken).
#   * G4      turn `redact()` into a passthrough → G4 RED (a real token lands in a COMMITTED file).
#   * G5      turn `_tail()` into a passthrough → G5 RED (an 800 KB evidence record).
#   * G6      drop the `timeout=` from the verify subprocess → G6 RED (a hung probe never returns).
#   * G7      delete the shell-126/127 branch → G7 RED (a deleted verify script starts reading as
#             "the product is broken" instead of "the check is broken").
#   * G8      print `live: ok` for an attested surface → G8 RED (an attestation becomes
#             indistinguishable from a measured run).
#   * G9      drop `live: ok (attested)` from the drain's clean set → G9 RED (an attesting repo can
#             never reach `drain: complete`).
#   * C3b     add `--run` to the drain's live-check argv → C3b RED (the stop path starts executing
#             browser suites inside two nested timeouts).
#   * B10     delete the `mode != executed` branch → B10 RED (a hand-written claim satisfies the gate
#             again — the exact behaviour this rebuild removes).
#   * B11     delete the recorded-vs-declared command comparison → B11 RED (swap the real probe for
#             `true` and inherit its green).
#   * B12/B12b/B12c  delete the no-`verify:` refusal / the both-declared refusal / the strict boolean
#             → each RED (an unverifiable declaration stops being INDETERMINATE).
#   * E4b     revert the Stop gate's live-gap cure to the human instruction → E4b RED.
#   * E5      put "drive the journey" back into commands/autorun.md → E5 RED.
#   * B2/B4   re-verified after the rebuild: still individually RED.
#
# Usage: bash tests/smoke/phase4-completion-honesty.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
COH="$PLUGIN/scripts/idc_finish_coherence.py"
LIVE="$PLUGIN/scripts/idc_live_check.py"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
JAN="$PLUGIN/scripts/idc_git_janitor.py"
GATE="$PLUGIN/scripts/hooks/idc_stop_fixpoint_gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

for f in "$COH" "$LIVE" "$DRAIN" "$TRK" "$JAN" "$GATE"; do
  [ -f "$f" ] || fail "missing helper: $f"
done

# `run <cmd…>` → sets $out (stdout) and $rc, discarding stderr (every verdict rides stdout by contract).
run() { out="$("$@" 2>/dev/null)"; rc=$?; }

# ---- a governed filesystem repo whose board is HONEST (the baseline every case starts from) -------
mkrepo() { # $1 = dir
  local r="$1"; mkdir -p "$r/services" "$r/infra" "$r/docs/workflow/live-verification"
  git -C "$r" init -q -b main . 2>/dev/null || { git init -q -b main "$r"; }
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo v1 > "$r/services/app.py"; echo tf > "$r/infra/main.tf"
  python3 "$TRK" --tracker "$r/TRACKER.md" init >/dev/null || fail "tracker init failed"
  git -C "$r" add -A; git -C "$r" commit -qm init
}

echo "== A. idc_finish_coherence.py — does the board still claim work that already shipped?"
R="$WORK/coh"; mkrepo "$R"
python3 "$TRK" --tracker "$R/TRACKER.md" create --title shipped --stage Buildable >/dev/null   # #1
python3 "$TRK" --tracker "$R/TRACKER.md" claim  --num 1 --agent bot >/dev/null                 # In Progress
python3 "$TRK" --tracker "$R/TRACKER.md" create --title foreign --stage Buildable >/dev/null   # #2
git -C "$R" add -A; git -C "$R" commit -qm board

# A0 — an honest board is clean. Establishes that the gate is not simply always-red.
run python3 "$COH" --repo "$R" --tracker "$R/TRACKER.md"
[ "$rc" = 0 ] && [ "$out" = "finish-coherence: ok" ] \
  || fail "A0: an honest board must be clean, got rc=$rc out=$out"

# A1 — a FOREIGN merged branch whose name contains an issue token must NOT make the board stale.
# The attribution guard is what keeps this gate from firing on other tools' debris; a gate that
# reports unrelated noise is a gate somebody turns off.
git -C "$R" checkout -q -b codex/xbuild-2; echo f > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm foreign
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff codex/xbuild-2 -m "merge foreign"
run python3 "$COH" --repo "$R" --tracker "$R/TRACKER.md"
[ "$rc" = 0 ] && [ "$out" = "finish-coherence: ok" ] \
  || fail "A1: a foreign merged branch must never be reported as board staleness, got rc=$rc out=$out"

# A2 — THE FAILURE ITSELF: #1's IDC build branch merges (the work shipped) but the board still says
# In Progress. This is the shape all seven stranded items were in.
git -C "$R" checkout -q -b worktree-build-1; echo z > "$R/z"; git -C "$R" add -A; git -C "$R" commit -qm w1
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff worktree-build-1 -m "merge 1"
run python3 "$COH" --repo "$R" --tracker "$R/TRACKER.md"
[ "$rc" = 1 ] || fail "A2: a shipped-but-not-Done item must exit 1, got rc=$rc out=$out"
[ "$out" = "finish-coherence: gap #1" ] \
  || fail "A2: the verdict must name the stranded item, got: $out"

# A2b — the WIRE CONTRACT this gate depends on: the janitor's JSON must expose `op`, the machine
# classification the filter selects on. Asserted HERE, against a board that really does carry a
# board-stale finding — asserting it over a clean board would pass for the wrong reason.
run python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md" --json
printf '%s' "$out" | grep -q '"op": *"set-done"\|"op":"set-done"\|"op": *"close-fs"\|"op":"close-fs"' \
  || fail "A2b: idc_git_janitor.py --json must expose the op key that idc_finish_coherence filters on; got: $out"

# A2c — INAPPLICABLE is not INDETERMINATE. A governed repo with no git has no branches, PRs or merges,
# so nothing can have shipped and the board cannot be stale about it. Answering "I cannot tell" there
# would pin the repo at a permanent `drain: unknown` — never able to honestly complete — which is how a
# gate that cries wolf gets switched off. (Caught by the full suite, not by reading the code: it broke
# governance/stop-ledger-alone-never-blocks.sh, whose fixture repo is deliberately not a git repo.)
NG="$WORK/nogit"; mkdir -p "$NG"
python3 "$TRK" --tracker "$NG/TRACKER.md" init >/dev/null
run python3 "$COH" --repo "$NG" --tracker "$NG/TRACKER.md"
[ "$rc" = 0 ] && [ "$out" = "finish-coherence: not-applicable" ] \
  || fail "A2c: a non-git repo must be not-applicable (clean), not indeterminate, got rc=$rc out=$out"
run python3 "$DRAIN" --tracker "$NG/TRACKER.md" --coherence --live
[ "$rc" = 0 ] || fail "A2c: a non-git repo must still reach a terminal drain verdict, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^drain: complete' \
  || fail "A2c: an inapplicable coherence check must not block completion, got: $out"

# A2d — THE REMEDIATION MUST BE A DOOR THAT OPENS. `idc_git_finish.py --close-only` resolves the
# merged PR's head branch through `gh`, so it exists only on the github backend — naming it to a
# filesystem repo hands the operator a command that dies before doing anything. A gate that reports a
# real problem and then points nowhere useful spends the operator's trust on the instruction instead
# of the finding. (Verified by running --close-only on a filesystem repo: it fails on a missing `gh`.)
git -C "$R" checkout -q -b worktree-build-3 2>/dev/null || true
python3 "$TRK" --tracker "$R/TRACKER.md" create --title again --stage Buildable >/dev/null   # #3
python3 "$TRK" --tracker "$R/TRACKER.md" claim --num 3 --agent bot >/dev/null
echo y > "$R/y"; git -C "$R" add -A; git -C "$R" commit -qm w3
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff worktree-build-3 -m "merge 3"
rem="$(python3 "$COH" --repo "$R" --tracker "$R/TRACKER.md" 2>&1 >/dev/null)"
printf '%s' "$rem" | grep -q 'apply-safe' \
  || fail "A2d: the filesystem remediation must name the batch door, got: $rem"
printf '%s' "$rem" | grep -q 'does not apply on the filesystem backend' \
  || fail "A2d: the filesystem remediation must say the per-item --close-only door does NOT apply here, got: $rem"
# Restore the honest board so the later assertions start from a known state.
python3 "$TRK" --tracker "$R/TRACKER.md" close --num 3 >/dev/null

# A3 — GROUND TRUTH FIRST: with no board arguments the gate cannot prove anything and must be
# INDETERMINATE. Reading "I did not look" as "ok" is the hollow clean this whole suite exists over.
run python3 "$COH" --repo "$R"
[ "$rc" = 2 ] || fail "A3: a board-less scan must be indeterminate (exit 2), got rc=$rc out=$out"
case "$out" in "finish-coherence: error"*) :;; *) fail "A3: expected an error verdict line, got: $out";; esac

# A4 — RE-RUNNABLE: after the board is repaired the gate goes green again. A gate that stays red
# after the fix cannot be used to gate anything.
python3 "$TRK" --tracker "$R/TRACKER.md" close --num 1 >/dev/null
run python3 "$COH" --repo "$R" --tracker "$R/TRACKER.md"
[ "$rc" = 0 ] && [ "$out" = "finish-coherence: ok" ] \
  || fail "A4: the gate must clear once the board is repaired, got rc=$rc out=$out"

# A5 — the WIRE CONTRACT with the drain's shared classifier. All three wave-close checks must use the
# same verdict word for a finding; a check that invents its own gets classified as an ERROR, i.e.
# reported as "I could not tell" when the truth is precisely known. (This is a real defect that was
# caught by running the drain, not by reading the code.)
grep -q 'finish-coherence: gap ' "$COH" \
  || fail 'A5: idc_finish_coherence.py must emit the shared gap verdict token, not a private word'

echo "== B. idc_live_check.py — was the declared live surface actually driven?"
L="$WORK/live"; mkrepo "$L"

# B1 — NO BURDEN: a repo with no config at all is never gated.
run python3 "$LIVE" --repo "$L"
[ "$rc" = 0 ] && [ "$out" = "live: not-declared" ] \
  || fail "B1: a repo with no config must be not-declared, got rc=$rc out=$out"

# B2 — NO BURDEN: the SHIPPED template (`surfaces: []`) must also be inert. Every governed repo gets
# this file, so if it gated by default, every library and CLI on the planet would be blocked.
cp "$PLUGIN/templates/WORKFLOW-config.yaml" "$L/WORKFLOW-config.yaml"
git -C "$L" add -A; git -C "$L" commit -qm tmpl
run python3 "$LIVE" --repo "$L"
[ "$rc" = 0 ] && [ "$out" = "live: not-declared" ] \
  || fail "B2: the shipped template must be inert (not-declared), got rc=$rc out=$out"

# Now DECLARE a surface — opting in is the only way to be gated. The declaration names the COMMAND that
# drives the real deployment; IDC runs it and never learns what a browser or an HTTP client is.
cat > "$L/WORKFLOW-config.yaml" <<'EOF'
project:
  name: demo
live_verification:
  surfaces:
    - name: web
      verify: bash scripts/verify-live-web.sh
      journey: sign in -> ingest text -> open the item -> chat
      paths: [services/, infra/]
EOF
git -C "$L" add -A; git -C "$L" commit -qm declare

# B3 — declared but never verified is a GAP. This is the state the real repo shipped in.
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B3: a declared surface with no evidence must be a gap, got rc=$rc out=$out"

# Section B audits the RECORD's rules, so it writes receipts of exactly the shape `--run` generates
# (section G is what proves `--run` really produces this shape, by running a real command). A receipt
# that is missing the executed provenance is B10's case, not this one.
SHA="$(git -C "$L" rev-parse HEAD)"
# The declared command's digest, DERIVED (never pasted) so these fixtures cannot drift from the real
# rule. A receipt must identify the command it ran by hash, because the redacted display string it
# also carries is lossy and can collide across different commands.
CMD="bash scripts/verify-live-web.sh"
CMDSHA="$(printf '%s' "$CMD" | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -n "$CMDSHA" ] || CMDSHA="$(printf '%s' "$CMD" | sha256sum | awk '{print $1}')"
ev() { printf '<!-- idc-live-evidence: %s -->\n' "$1" > "$L/docs/workflow/live-verification/web.md"; }
ev_ok() { # $1 = commit, $2 = observed
  ev "{\"surface\":\"web\",\"mode\":\"executed\",\"command\":\"$CMD\",\"command_sha256\":\"$CMDSHA\",\"exit_code\":0,\"commit\":\"$1\",\"observed\":\"$2\"}"
}
ev_ok "$SHA" "ingest 200; open 200 signed URL; chat 200"
git -C "$L" add -A; git -C "$L" commit -qm evidence
run python3 "$LIVE" --repo "$L"
[ "$rc" = 0 ] && [ "$out" = "live: ok" ] \
  || fail "B3b: current evidence must pass, got rc=$rc out=$out"

# B4 — THE TEETH: a change to the surface's INFRASTRUCTURE expires the evidence. This is the exact
# provisioning hole — a Terraform change that alters what is deployed while the app's last "I tested
# it" note stays green. Without this rule the gate is a one-time checkbox.
echo 'resource "bucket" "evidence" {}' >> "$L/infra/main.tf"
git -C "$L" add -A; git -C "$L" commit -qm provisioning
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B4: a change under the surface's paths must EXPIRE its evidence, got rc=$rc out=$out"

# B5 — but an UNRELATED change must not. Evidence that expires on every commit is noise, and noise
# gets suppressed.
ev_ok "$(git -C "$L" rev-parse HEAD)" "re-run: all green"
git -C "$L" add -A; git -C "$L" commit -qm re-evidence
mkdir -p "$L/docs/notes"; echo note > "$L/docs/notes/x.md"
git -C "$L" add -A; git -C "$L" commit -qm unrelated
run python3 "$LIVE" --repo "$L"
[ "$rc" = 0 ] && [ "$out" = "live: ok" ] \
  || fail "B5: a change OUTSIDE the surface's paths must not expire its evidence, got rc=$rc out=$out"

# B6 — a CORRUPT marker is INDETERMINATE (exit 2), not a mere gap. Damaging an evidence file must
# never be a cheaper answer than driving the surface, and the drain must be able to tell "this file is
# broken" from "nobody has verified this yet".
ev '{not json}'
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B6: a corrupt evidence marker must be indeterminate (exit 2), got rc=$rc out=$out"

# B7 — evidence naming a commit that does not exist proves nothing.
ev_ok "0123456789abcdef0123456789abcdef01234567" "x"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B7: a fabricated commit must not satisfy the gate, got rc=$rc out=$out"

# B7b — evidence taken on an UNMERGED branch proves nothing about what shipped. This is the case that
# independently exercises the ancestor rule: B7's fabricated sha is caught by the existence check AND
# would be caught by this one, so B7 alone cannot prove the ancestor rule is live.
git -C "$L" checkout -q -b side
echo experiment >> "$L/services/app.py"; git -C "$L" add -A; git -C "$L" commit -qm side
SIDE="$(git -C "$L" rev-parse HEAD)"
git -C "$L" checkout -q main
ev_ok "$SIDE" "looked fine on my branch"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B7b: evidence from an unmerged commit must not satisfy the gate, got rc=$rc out=$out"

# B8 — an empty `observed` is not evidence.
ev "{\"surface\":\"web\",\"mode\":\"executed\",\"command\":\"bash scripts/verify-live-web.sh\",\"exit_code\":0,\"commit\":\"$SHA\",\"observed\":\"   \"}"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B8: a blank observed field must fail closed (exit 2), got rc=$rc out=$out"

# B10 — THE CENTRAL RULE OF THIS GATE: A TYPED CLAIM IS NOT A RUN. A record with no executed
# provenance — the exact shape a human (or an agent taking the cheap path) hand-writes — must be
# reported as never executed, however confident its prose. Before this rule, "I drove it and it worked"
# in a committed file WAS the gate's pass condition, which is the same optimism that read "merged" as
# "works" one layer up.
ev "{\"surface\":\"web\",\"commit\":\"$(git -C "$L" rev-parse HEAD)\",\"observed\":\"I signed in and drove the whole journey, all green\"}"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B10: a hand-written record must NOT satisfy a surface that declares a verify command, got rc=$rc out=$out"
det="$(python3 "$LIVE" --repo "$L" 2>&1 >/dev/null)"
printf '%s' "$det" | grep -q 'no EXECUTED verification' \
  || fail "B10: the gap must say the surface was never executed, got: $det"

# B11 — SWAPPING THE CHECK EXPIRES ITS RECEIPTS. Without this, a surface could be re-declared to run
# `true` — or any weaker probe — and inherit the green of the real command it replaced, with no commit
# landing on any watched path to expire it.
ev_ok "$(git -C "$L" rev-parse HEAD)" "all green"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 0 ] || fail "B11: precondition — the current receipt must pass, got rc=$rc out=$out"
sed -i.bak 's|verify: bash scripts/verify-live-web.sh|verify: true|' "$L/WORKFLOW-config.yaml"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B11: changing the declared verify command must expire its receipts, got rc=$rc out=$out"
git -C "$L" checkout -q -- WORKFLOW-config.yaml 2>/dev/null || true
rm -f "$L/WORKFLOW-config.yaml.bak"

# B9 — a surface declared WITHOUT paths would have evidence that never expires, so the declaration
# itself is refused rather than silently accepted as a permanent pass.
printf 'live_verification:\n  surfaces:\n    - name: web\n      verify: true\n' > "$L/WORKFLOW-config.yaml"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B9: a surface with no paths must be refused (exit 2), got rc=$rc out=$out"

# B12 — AND A SURFACE WITH NO WAY TO DRIVE IT IS INDETERMINATE, NEVER A PASS. This is the fail-closed
# half of "verification is executed": a declaration IDC cannot execute must not resolve to silence.
printf 'live_verification:\n  surfaces:\n    - name: web\n      paths: [services/]\n' > "$L/WORKFLOW-config.yaml"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B12: a surface with no verify command must be refused (exit 2), got rc=$rc out=$out"
# B12b — and declaring BOTH is an ambiguity the gate refuses rather than resolving in either direction.
printf 'live_verification:\n  surfaces:\n    - name: web\n      verify: true\n      attested: true\n      paths: [services/]\n' \
  > "$L/WORKFLOW-config.yaml"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B12b: declaring both verify and attested must be refused (exit 2), got rc=$rc out=$out"
# B12c — a mistyped `attested:` must not be read as either answer. Declared WITH a `verify:` command on
# purpose, so this case can only be reached through the boolean rule: without the `verify:` it would
# also trip B12's no-command refusal and would prove nothing on its own.
printf 'live_verification:\n  surfaces:\n    - name: web\n      verify: true\n      attested: yep\n      paths: [services/]\n' \
  > "$L/WORKFLOW-config.yaml"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B12c: a non-boolean attested value must be refused (exit 2), got rc=$rc out=$out"

echo "== G. idc_live_check.py --run — the gate EXECUTES the project's own check"
# WHY THIS SECTION EXISTS. Section B audits RECORDS; this one proves the records come from a real
# execution. The gate's first cut asked a HUMAN to drive the app and type up what they saw — which
# wakes an operator at 2am and accepts a claim in place of a measurement. Everything below asserts the
# replacement: the project declares a COMMAND, IDC runs it, and the verdict is that command's real exit
# code. Each case uses a verify script that leaves a filesystem SENTINEL, so "it ran" is observed, not
# inferred from the verdict the run is supposed to produce.
G="$WORK/run"; mkrepo "$G"; mkdir -p "$G/scripts"
declare_surface() { # $1 = verify command, $2 = extra key line (may be empty)
  { printf 'live_verification:\n  surfaces:\n    - name: web\n'
    [ -n "$1" ] && printf '      verify: %s\n' "$1"
    [ -n "${2:-}" ] && printf '      %s\n' "$2"
    printf '      paths: [services/]\n'
  } > "$G/WORKFLOW-config.yaml"
}
verify_script() { # $1 = body
  printf '#!/bin/bash\ntouch "$PWD/ran.sentinel"\n%s\n' "$1" > "$G/scripts/verify.sh"
}

# G0 — THE FREE PATH IS FREE EVEN UNDER --run. A repo that declares nothing must not execute anything,
# ever. Asserted by MECHANISM: the sentinel a run would leave is absent afterwards.
verify_script 'exit 0'
rm -f "$G/ran.sentinel"
run python3 "$LIVE" --repo "$G" --run
[ "$rc" = 0 ] && [ "$out" = "live: not-declared" ] \
  || fail "G0: an undeclared repo must be not-declared even under --run, got rc=$rc out=$out"
[ -e "$G/ran.sentinel" ] && fail "G0: --run executed something in a repo that declares no surface"

# G1 — THE CORE: --run executes the declared command and the verdict is its real exit code.
declare_surface 'bash scripts/verify.sh'
git -C "$G" add -A; git -C "$G" commit -qm declare
run python3 "$LIVE" --repo "$G" --run
[ "$rc" = 0 ] && [ "$out" = "live: ok" ] || fail "G1: a passing verify command must be ok, got rc=$rc out=$out"
[ -e "$G/ran.sentinel" ] || fail "G1: the verify command was never actually executed (no sentinel)"
EV="$G/docs/workflow/live-verification/web.md"
[ -f "$EV" ] || fail "G1: --run must generate the evidence record at $EV"
for k in '"mode": "executed"' '"command": "bash scripts/verify.sh"' '"exit_code": 0' '"ran_at"'; do
  grep -q "$k" "$EV" || fail "G1: the generated record must carry $k; got: $(cat "$EV")"
done
grep -q "\"commit\": \"$(git -C "$G" rev-parse HEAD)\"" "$EV" \
  || fail "G1: the record must name the commit it ran against"

# G2 — the fast AUDIT path then passes on that record and EXECUTES NOTHING. This is what the drain and
# the Stop hook call; if it re-ran the command, every stop attempt would sit through a browser suite.
rm -f "$G/ran.sentinel"
run python3 "$LIVE" --repo "$G"
[ "$rc" = 0 ] && [ "$out" = "live: ok" ] || fail "G2: the audit must pass on a fresh receipt, got rc=$rc out=$out"
[ -e "$G/ran.sentinel" ] && fail "G2: the default (audit) path must NEVER execute the verify command"

# G3 — A FAILING COMMAND IS A FINDING, and it INVALIDATES the green receipt it replaces. Writing only
# on success would leave yesterday's passing record in place after today's run failed — the audit would
# keep reporting ok while the command that just ran said the product was broken.
verify_script 'exit 7'
run python3 "$LIVE" --repo "$G" --run
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "G3: a failing verify command must be a gap (exit 1), got rc=$rc out=$out"
grep -q '"exit_code": 7' "$EV" || fail "G3: the record must be regenerated with the FAILING exit code"
run python3 "$LIVE" --repo "$G"
[ "$rc" = 1 ] || fail "G3: the audit must agree with the failing run, got rc=$rc out=$out"

# G4 — NO SECRET EVER REACHES THE COMMITTED RECORD. A verify script drives a real deployment, so it
# holds real credentials; the evidence file is committed. Redaction is asserted against the literal
# values, in the file AND on the operator-facing stderr.
verify_script 'echo "Authorization: Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
echo "API_KEY=sk-abcdefghijklmnopqrstuvwxyz012345"
echo "url=https://user:hunter2@example.test/x"
exit 0'
err="$(python3 "$LIVE" --repo "$G" --run 2>&1 >/dev/null)"
for secret in 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345' 'sk-abcdefghijklmnopqrstuvwxyz012345' 'hunter2'; do
  grep -q "$secret" "$EV" && fail "G4: the generated evidence record leaked a credential ($secret)"
  printf '%s' "$err" | grep -q "$secret" && fail "G4: stderr leaked a credential ($secret)"
done
grep -q 'REDACTED' "$EV" || fail "G4: the record must show the redaction, not silently drop the output"

# G5 — the record stays BOUNDED. An unbounded capture is both a review burden and more surface for a
# leak to hide in.
verify_script 'head -c 400000 /dev/zero | tr "\0" "x"
exit 0'
run python3 "$LIVE" --repo "$G" --run
[ "$rc" = 0 ] || fail "G5: precondition — the noisy command must still pass, got rc=$rc out=$out"
sz="$(wc -c < "$EV" | tr -d ' ')"
[ "$sz" -lt 20000 ] || fail "G5: the evidence record must be bounded, got $sz bytes"

# G6 — A HUNG PROBE IS INDETERMINATE, NOT A PASS, and it must not leave the child running. An
# unbounded verify command would hang the wave close forever; an orphaned browser/dev-server would
# outlive the run on the operator's machine.
declare_surface 'bash scripts/verify.sh' 'timeout: 2'
verify_script 'sleep 43'
t0=$SECONDS
run python3 "$LIVE" --repo "$G" --run
el=$(( SECONDS - t0 ))
[ "$rc" = 2 ] || fail "G6: a verify command that overruns its timeout must be indeterminate, got rc=$rc out=$out"
[ "$el" -lt 25 ] || fail "G6: the timeout was not enforced (took ${el}s for a 2s ceiling)"
sleep 1
pgrep -f 'sleep 43' >/dev/null 2>&1 && fail "G6: the timed-out verify command's child process was orphaned"

# G7 — A CHECK THAT CANNOT RUN AT ALL IS INDETERMINATE, NEVER A GAP AND NEVER A PASS. Deleting the
# verify script must not read as "the product is broken" (which would send the pipeline to fix the
# wrong thing) and must certainly not read as clean.
declare_surface 'bash scripts/definitely-not-here.sh'
run python3 "$LIVE" --repo "$G" --run
[ "$rc" = 2 ] || fail "G7: an unexecutable verify command must be indeterminate (exit 2), got rc=$rc out=$out"

# G8 — THE ATTESTED ESCAPE HATCH IS VISIBLE. Some surfaces genuinely cannot be automated, so the
# hand-written path survives — but on its OWN verdict line, so a typed claim can never be read as a
# measurement by anything downstream.
declare_surface '' 'attested: true'
git -C "$G" add -A; git -C "$G" commit -qm attested
printf '<!-- idc-live-evidence: {"surface":"web","mode":"attested","commit":"%s","observed":"drove the kiosk by hand"} -->\n' \
  "$(git -C "$G" rev-parse HEAD)" > "$EV"
rm -f "$G/ran.sentinel"
run python3 "$LIVE" --repo "$G" --run
[ "$rc" = 0 ] && [ "$out" = "live: ok (attested)" ] \
  || fail "G8: an attested surface must report its own clean line, got rc=$rc out=$out"
[ "$out" = "live: ok" ] && fail "G8: an attestation must never print the same verdict as an executed run"
[ -e "$G/ran.sentinel" ] && fail "G8: an attested surface must execute nothing"

# G9 — and the drain must ACCEPT that distinct line as clean. A verdict the gate calls clean but the
# shared classifier calls unrecognized would pin an attesting repo at `drain: unknown` forever — the
# cry-wolf failure that gets a gate switched off.
python3 "$TRK" --tracker "$G/TRACKER.md" init >/dev/null 2>&1 || true
run python3 "$DRAIN" --tracker "$G/TRACKER.md" --coherence --live
[ "$rc" = 0 ] || fail "G9: an attested-clean repo must reach a terminal drain verdict, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^drain: complete' \
  || fail "G9: the drain must accept `live: ok (attested)` as clean, got: $out"

echo "== C. drain wiring — the gates must change the pipe's verdict, not just print a line"
D="$WORK/drain"; mkrepo "$D"
T="$D/TRACKER.md"
python3 "$TRK" --tracker "$T" create --title stranded --stage Buildable >/dev/null
python3 "$TRK" --tracker "$T" claim --num 1 --agent bot >/dev/null
git -C "$D" add -A; git -C "$D" commit -qm board
git -C "$D" checkout -q -b worktree-build-1; echo z > "$D/z"; git -C "$D" add -A; git -C "$D" commit -qm w1
git -C "$D" checkout -q main; git -C "$D" merge -q --no-ff worktree-build-1 -m "merge 1"

# C0 — THE REGRESSION THE FIX EXISTS FOR: without the flag the drain still calls this board complete.
# Asserted deliberately, so the suite documents the old behaviour it replaced rather than merely
# asserting the new one.
run python3 "$DRAIN" --tracker "$T"
[ "$rc" = 0 ] || fail "C0: the default drain must be unchanged (exit 0), got rc=$rc"
printf '%s' "$out" | grep -q '^drain: complete' \
  || fail "C0: without --coherence the drain reports complete over a stale board (the documented old behaviour)"
printf '%s' "$out" | grep -q 'finish-coherence' \
  && fail "C0: the DEFAULT drain must not run the coherence check (opt-in; default output byte-identical)"

# C1 — with --coherence the same board is NON-TERMINAL, on the existing exit 4 the Stop gate refuses.
run python3 "$DRAIN" --tracker "$T" --coherence
[ "$rc" = 4 ] || fail "C1: a coherence gap must be non-terminal exit 4, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^drain: coherence-gap' \
  || fail "C1: expected the drain: coherence-gap verdict token, got: $out"

# C2 — repair the board through the tracker and the pipe reports complete again.
python3 "$TRK" --tracker "$T" close --num 1 >/dev/null
run python3 "$DRAIN" --tracker "$T" --coherence --live
[ "$rc" = 0 ] || fail "C2: a repaired board must reach complete, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^drain: complete' || fail "C2: expected drain: complete, got: $out"
printf '%s' "$out" | grep -q '^live: not-declared' \
  || fail "C2: --live on a repo declaring no surface must report not-declared (free), got: $out"

# C3 — declaring a live surface with no evidence makes the SAME clean board non-terminal.
mkdir -p "$D/scripts"
printf '#!/bin/bash\ntouch "$PWD/drain-executed.sentinel"\nexit 0\n' > "$D/scripts/verify.sh"
cat > "$D/WORKFLOW-config.yaml" <<'EOF'
live_verification:
  surfaces:
    - name: web
      verify: bash scripts/verify.sh
      paths: [services/]
EOF
git -C "$D" add -A; git -C "$D" commit -qm declare
run python3 "$DRAIN" --tracker "$T" --coherence --live

# C3b — THE DRAIN AUDITS, IT DOES NOT EXECUTE. Asserted FIRST, before the verdict, deliberately: the
# Stop fixpoint gate re-runs this very drain on the stop path, so if `--live` executed the surface's
# verify command, every stop attempt would sit through a browser suite inside two nested timeouts, and
# a slow probe would become `drain: unknown` instead of an honest verdict. Asserted by MECHANISM (the
# sentinel the command would leave behind), not by reading the flag list — and asserted ahead of C3 so
# that the mechanism, not a downstream verdict, is what names the defect.
# The single edit that makes this fail: add `--run` to the drain's `_run_wave_close_live` argv.
[ -e "$D/drain-executed.sentinel" ] \
  && fail "C3b: the drain's --live must NEVER execute a verify command (the stop path must stay fast)"

[ "$rc" = 4 ] || fail "C3: a live gap must be non-terminal exit 4, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^drain: live-gap' \
  || fail "C3: expected the drain: live-gap verdict token, got: $out"

# C4 — both gates fire only at WAVE CLOSE. While build work is still eligible the drain must report
# `continue` untouched: these gates answer "is the pipe finished", not "may I keep working".
python3 "$TRK" --tracker "$T" create --title more --stage Buildable >/dev/null
run python3 "$DRAIN" --tracker "$T" --coherence --live
[ "$rc" = 0 ] || fail "C4: with eligible work the drain must still exit 0, got rc=$rc out=$out"
printf '%s' "$out" | grep -q '^drain: continue' || fail "C4: expected drain: continue, got: $out"
printf '%s' "$out" | grep -q 'live: ' \
  && fail "C4: the wave-close gates must not run while build work is still eligible"

echo "== D. the shared classifier — one vocabulary across all three wave-close checks"
# D1 — all three publish `<token>: gap` for a finding. The drain reads them through ONE classifier;
# a check that drifts to its own word is silently downgraded to "indeterminate".
for pair in "idc_acceptance_check.py:acceptance" "idc_finish_coherence.py:finish-coherence" "idc_live_check.py:live"; do
  s="${pair%%:*}"; t="${pair##*:}"
  grep -q "\"$t: gap" "$PLUGIN/scripts/$s" || grep -q "'$t: gap" "$PLUGIN/scripts/$s" \
    || grep -q "$t: gap " "$PLUGIN/scripts/$s" \
    || fail "D1: scripts/$s must emit the shared verdict token $t: gap"
done

echo "== F. the coherence gate's fail-closed contract against a HOSTILE janitor report"
# The gate trusts one input: the janitor's JSON. These cases drive that input directly, via a stub
# janitor placed next to a copy of the gate (it resolves its sibling by directory), because the real
# janitor cannot be made to emit these shapes on demand — and a guard no test can reach is a guard
# nobody knows is broken.
#
# THE CASE THAT MATTERS MOST: `idc_git_janitor.py --json` with no board arguments really does exit 0
# with `{"verdict": "coherent", "board_scanned": false}`. Without the board_scanned guard the gate
# would read that as "ok" — a clean bill of health from a scan that never looked at a board. That is
# precisely the hollow clean this whole change set exists to remove.
STUB="$WORK/stub"; mkdir -p "$STUB"
cp "$COH" "$STUB/idc_finish_coherence.py"
# The stub replays a payload + exit code from sidecar files, so no shell quoting ever touches the JSON.
cat > "$STUB/idc_git_janitor.py" <<'PYEOF'
#!/usr/bin/env python3
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
sys.stdout.write(open(os.path.join(d, "payload")).read())
sys.exit(int(open(os.path.join(d, "code")).read().strip()))
PYEOF
stub_says() { printf '%s' "$1" > "$STUB/payload"; printf '%s' "$2" > "$STUB/code"; }
stub_run() { run python3 "$STUB/idc_finish_coherence.py" --repo "$WORK/coh" --tracker "$WORK/coh/TRACKER.md"; }

# F1 — coherent + exit 0 but NO board was scanned ⇒ INDETERMINATE, never ok.
stub_says '{"verdict": "coherent", "counts": {}, "board_scanned": false, "findings": []}' 0
stub_run
[ "$rc" = 2 ] || fail "F1: a report with board_scanned=false must be indeterminate, got rc=$rc out=$out"

# F2 — the same report WITH a board scanned is legitimately clean (proves F1 fails for the right
# reason, not because the stub path is broken).
stub_says '{"verdict": "coherent", "counts": {}, "board_scanned": true, "findings": []}' 0
stub_run
[ "$rc" = 0 ] && [ "$out" = "finish-coherence: ok" ] \
  || fail "F2: a scanned, coherent board must be ok, got rc=$rc out=$out"

# F3 — the janitor's own INDETERMINATE verdict must never be downgraded to clean: a capped or degraded
# read may be masking exactly the stale items this gate is looking for.
stub_says '{"verdict": "indeterminate", "counts": {}, "board_scanned": true, "findings": []}' 2
stub_run
[ "$rc" = 2 ] || fail "F3: an indeterminate janitor verdict must stay indeterminate, got rc=$rc out=$out"

# F4 — a stale-class finding with no usable item number cannot be named, and dropping it would
# UNDER-report staleness. Fail closed rather than silently skip it.
stub_says '{"verdict": "findings", "counts": {}, "board_scanned": true, "findings": [{"tier": "SAFE-FIX", "dim": "board", "op": "set-done", "detail": "x"}]}' 1
stub_run
[ "$rc" = 2 ] || fail "F4: a numberless stale finding must fail closed, got rc=$rc out=$out"

# F5 — a janitor that CRASHES (an exit outside its documented 0/1/2 contract) has produced no
# trustworthy verdict at all.
stub_says 'Traceback (most recent call last):' 3
stub_run
[ "$rc" = 2 ] || fail "F5: an out-of-contract janitor exit must be indeterminate, got rc=$rc out=$out"

# F6 — unparseable output is not an empty findings list.
stub_says 'not json at all' 0
stub_run
[ "$rc" = 2 ] || fail "F6: unparseable janitor JSON must be indeterminate, got rc=$rc out=$out"

# F7 — and the positive control: a well-formed stale finding is reported, so the gate is not simply
# always-red under the stub.
stub_says '{"verdict": "findings", "counts": {}, "board_scanned": true, "findings": [{"op": "set-done", "number": 7}, {"op": "reconcile", "number": 9}]}' 1
stub_run
[ "$rc" = 1 ] && [ "$out" = "finish-coherence: gap #7" ] \
  || fail "F7: a well-formed stale finding must be reported, and the RISKY reconcile op excluded; got rc=$rc out=$out"

echo "== E. Stop-gate wiring — the enforcement seam"
# E1 — TIMEOUT ORDERING. The gate's own ceiling must stay strictly ABOVE the drain's coherence
# ceiling, so a slow scan times out INSIDE the drain (→ `drain: unknown`, which the gate allows)
# rather than out in the gate (→ a raise, which fails CLOSED and wedges the stop over a slow git scan
# instead of over a real finding).
inner="$(grep -oE '^COHERENCE_TIMEOUT = [0-9]+' "$DRAIN" | grep -oE '[0-9]+')"
outer="$(grep -oE '^_DRAIN_TIMEOUT = [0-9]+' "$GATE" | grep -oE '[0-9]+')"
[ -n "$inner" ] || fail "E1: idc_autorun_drain.py must define COHERENCE_TIMEOUT"
[ -n "$outer" ] || fail "E1: the Stop gate must define _DRAIN_TIMEOUT"
[ "$outer" -gt "$inner" ] \
  || fail "E1: the Stop gate's _DRAIN_TIMEOUT ($outer) must exceed the drain's COHERENCE_TIMEOUT ($inner) — otherwise a slow scan wedges the stop instead of degrading to allow"

# E2 — the Stop gate's live re-run must ask the SAME questions the drain loop asks, or the filesystem
# stop path silently enforces less than the drain does.
#
# ASSERTED AGAINST THE ACTUAL CALL, not the file. A bare `grep -- --coherence "$GATE"` passes on the
# surrounding comments alone, so it stayed GREEN when the flag was deleted from the real subprocess
# argv — a test that cannot fail is worse than no test, because it is believed. Scoped to the three
# lines of the invocation instead.
gate_call="$(grep -A2 'subprocess\.run(\[sys\.executable, drain' "$GATE")"
[ -n "$gate_call" ] || fail "E2: could not locate the Stop gate's drain invocation"
printf '%s' "$gate_call" | grep -q -- '"--coherence"' \
  || fail "E2: the Stop gate's drain INVOCATION must pass --coherence (not merely mention it in prose)"
printf '%s' "$gate_call" | grep -q -- '"--live"' \
  || fail "E2: the Stop gate's drain INVOCATION must pass --live (not merely mention it in prose)"

# E3 — the playbooks that actually invoke the drain must pass both flags, on the SAME line as the
# drain command (same anti-prose-grep discipline as E2: the surrounding explanation names the flags
# too, so a file-wide grep would pass even with the commands stripped).
for f in "$PLUGIN/commands/autorun.md" "$PLUGIN/agents/idc-autorun.md"; do
  n="$(grep -c 'idc_autorun_drain\.py[^`]*--coherence[^`]*--live' "$f")"
  [ "${n:-0}" -ge 2 ] \
    || fail "E3: $(basename "$f") must pass --coherence --live ON the drain command line for BOTH backends (found $n)"
done
# Build's wave close is the GitHub backend's own path to both gates (it has no on-disk TRACKER.md), so
# assert the real invocation form, not a bare mention of the filename.
grep -q 'python3 "\${CLAUDE_PLUGIN_ROOT}/scripts/idc_finish_coherence\.py"' "$PLUGIN/agents/idc-build.md" \
  || fail "E3: agents/idc-build.md wave close must INVOKE idc_finish_coherence.py"
grep -q 'python3 "\${CLAUDE_PLUGIN_ROOT}/scripts/idc_live_check\.py"[^`]*--run' "$PLUGIN/agents/idc-build.md" \
  || fail "E3: agents/idc-build.md wave close must INVOKE idc_live_check.py WITH --run (the seam where the declared command is actually executed)"

# E5 — VERIFICATION IS EXECUTED, AND FAILURE IS PIPELINE WORK. The playbooks are the only thing that
# tells an agent what to DO about `drain: live-gap`, and the first cut of this gate told it to go and
# drive the app by hand and, failing that, to report that it could not — which either stalls an
# unattended run or wakes the operator. Both halves are asserted: the executable cure must be ON the
# remediation line, and no shipped file may still hand the journey to a human.
#
# The single edit that makes this fail: put "drive the journey" back into either autorun playbook, or
# drop `--run` from the live-gap remediation.
for f in "$PLUGIN/commands/autorun.md" "$PLUGIN/agents/idc-autorun.md" "$PLUGIN/agents/idc-build.md"; do
  grep -q 'idc_live_check\.py[^`]*--run' "$f" \
    || fail "E5: $(basename "$f") must name the EXECUTABLE cure \`idc_live_check.py … --run\` on the command line"
done
for f in "$PLUGIN/commands/autorun.md" "$PLUGIN/agents/idc-autorun.md" "$PLUGIN/agents/idc-build.md" \
         "$PLUGIN/templates/WORKFLOW.md" "$PLUGIN/templates/WORKFLOW-config.yaml"; do
  grep -niE 'drive the (declared )?journey|drive it and commit|if you cannot drive' "$f" \
    && fail "E5: $(basename "$f") still instructs a HUMAN to drive the live surface — the pipeline executes the project's verify command instead"
done

# E4 — A BLOCK MUST NAME A CURE THAT CAN ACTUALLY CLEAR IT. The four non-terminal verdicts share one
# block/allow decision but NOT one remedy, and the reason string is the operator's ONLY instruction.
# Found live (2026-07-19, autorun sandbox, real board): a coherence-gap block told the operator the
# inbox owed work and to run `/idc:recirculate` — which cannot flip a stale board card. They would run
# it, nothing would change, and they would re-block until the anti-nag bound forced the exit, teaching
# them the gate cries wolf. A gate that fires correctly and misdirects is worse than one that stays
# quiet, so the remedy is asserted per verdict, not just the decision.
#
# The single edit that makes this fail: collapse any branch of _block_reason back into the generic
# `/idc:recirculate` else-arm → E4 goes RED for that verdict.
reason_for() { # $1 = detail string → the gate's operator-facing reason
  python3 -c "
import sys; sys.path.insert(0, '$PLUGIN/scripts/hooks')
import idc_stop_fixpoint_gate as G
print(G._block_reason(sys.argv[1], []))
" "$1" 2>/dev/null
}
coh_reason="$(reason_for 'github (persisted: drain: coherence-gap, exit 4)')"
[ -n "$coh_reason" ] || fail "E4: could not obtain a block reason from the Stop gate"
printf '%s' "$coh_reason" | grep -q 'janitor --apply-safe\|--close-only' \
  || fail "E4: a coherence-gap block must name the board-repair door, got: $coh_reason"
printf '%s' "$coh_reason" | grep -q '/idc:recirculate' \
  && fail "E4: a coherence-gap block must NOT prescribe /idc:recirculate — it cannot flip a stale board card"

live_reason="$(reason_for 'github (persisted: drain: live-gap, exit 4)')"
printf '%s' "$live_reason" | grep -q 'evidence' \
  || fail "E4: a live-gap block must tell the operator to record fresh evidence, got: $live_reason"
printf '%s' "$live_reason" | grep -q '/idc:recirculate' \
  && fail "E4: a live-gap block must NOT prescribe /idc:recirculate — it cannot produce live evidence"
# E4b — AND THE CURE MUST BE A COMMAND THE PIPELINE RUNS, NOT AN ERRAND FOR A PERSON. This gate fires
# in the middle of an unattended overnight drain. "Go and drive the app" there is not a remedy, it is a
# phone call at 2am — and the pipeline is perfectly capable of running the project's own check itself.
printf '%s' "$live_reason" | grep -q -- '--run' \
  || fail "E4b: a live-gap block must name the executable cure (idc_live_check.py --run), got: $live_reason"

# The two inbox-class verdicts must still prescribe the recirculate door — proving the branching above
# narrowed the advice rather than simply deleting it.
for d in 'acceptance-gap' 'recirc-pending'; do
  r="$(reason_for "github (persisted: drain: $d, exit 4)")"
  printf '%s' "$r" | grep -q '/idc:recirculate' \
    || fail "E4: a $d block must still prescribe /idc:recirculate, got: $r"
done

echo "== H. the false-green paths an independent review found in this release"
# WHY THIS SECTION EXISTS. Sections B/G prove the gate says the right thing when everything WORKS. An
# independent read-only review of this branch found the opposite class: seven ways the gate could be
# talked into saying "fine". Three of them let a failed or unrunnable verification read as `live: ok`;
# one let a pause that was never lifted excuse an undrained stop. A gate that can be talked into a
# clean answer is worse than no gate, because it is believed — so each of those paths gets a case
# here, and each was observed RED against the real source before it was committed (the mutation is
# named on the case).

echo "-- H1/H2: a run that established NOTHING must invalidate the receipt it could not replace"
# THE HOLE. Every indeterminate path (timeout, a verify command that cannot be executed) exited 2
# BEFORE write_evidence ran, so yesterday's PASSING receipt stayed on disk untouched. The fast AUDIT
# is a separate process that reads only that file — so the drain and the Stop gate went on certifying
# `live: ok` from a receipt whose command had just failed to produce any verdict at all.
# MUTATION (both cases): drop the `_invalidate(...)` call from that branch of run_verify → RED.
H="$WORK/indeterminate"; mkrepo "$H"; mkdir -p "$H/scripts"
printf '#!/bin/bash\nexit 0\n' > "$H/scripts/verify.sh"
printf 'live_verification:\n  surfaces:\n    - name: web\n      verify: bash scripts/verify.sh\n      timeout: 5\n      paths: [services/]\n' \
  > "$H/WORKFLOW-config.yaml"
git -C "$H" add -A; git -C "$H" commit -qm declare
run python3 "$LIVE" --repo "$H" --run
[ "$rc" = 0 ] && [ "$out" = "live: ok" ] || fail "H1 setup: the passing baseline run must be ok, got rc=$rc out=$out"
run python3 "$LIVE" --repo "$H"
[ "$rc" = 0 ] || fail "H1 setup: the audit must pass on the fresh receipt, got rc=$rc out=$out"

# H1 — TIMEOUT. The declared command is unchanged, so nothing else can explain a changed verdict.
printf '#!/bin/bash\nsleep 30\n' > "$H/scripts/verify.sh"
run python3 "$LIVE" --repo "$H" --run
[ "$rc" = 2 ] || fail "H1: a verify command that times out must be INDETERMINATE (exit 2), got rc=$rc out=$out"
run python3 "$LIVE" --repo "$H"
[ "$rc" = 2 ] \
  || fail "H1: after a TIMED-OUT run the read-only audit must NOT inherit the old passing receipt (expected exit 2), got rc=$rc out=$out"
grep -q '"mode": "indeterminate"' "$H/docs/workflow/live-verification/web.md" \
  || fail "H1: the receipt must be REPLACED with an indeterminate record, not left as the old pass"

# H2 — THE COMMAND CANNOT BE EXECUTED AT ALL (shell 127). Deleting the verify script must not be a
# cheaper route to a clean bill of health than running it.
printf '#!/bin/bash\nexit 0\n' > "$H/scripts/verify.sh"
run python3 "$LIVE" --repo "$H" --run
[ "$rc" = 0 ] || fail "H2 setup: restoring the passing script must return to ok, got rc=$rc out=$out"
rm -f "$H/scripts/verify.sh"
run python3 "$LIVE" --repo "$H" --run
[ "$rc" = 2 ] || fail "H2: an unrunnable verify command must be INDETERMINATE (exit 2), got rc=$rc out=$out"
run python3 "$LIVE" --repo "$H"
[ "$rc" = 2 ] \
  || fail "H2: after an UNRUNNABLE command the audit must NOT inherit the old passing receipt (expected exit 2), got rc=$rc out=$out"

echo "-- H3: a verify script must not be able to FORGE the verdict of its own receipt"
# THE EXPLOIT, found by hand in review. The generated record puts the command's own output in the same
# file as the marker carrying the verdict — and the reader took the FIRST marker. So a script that
# FAILS can simply print a marker claiming exit 0, and the audit reads the forgery instead of the
# truth. `commit: "HEAD"` completes it: git resolves it, it is trivially an ancestor of HEAD, and
# `HEAD..HEAD` is empty, so every freshness rule in the file agrees the forged receipt is current.
# MUTATION: revert read_evidence to `EVIDENCE_MARKER.search(text)` AND drop the neutralize() calls in
# write_evidence → RED (both must be reverted; that is the point of having two defenses).
F="$WORK/forge"; mkrepo "$F"; mkdir -p "$F/scripts"
cat > "$F/scripts/verify.sh" <<'EOF'
#!/bin/bash
# A failing probe that tries to talk the gate into a pass by printing its own evidence marker. It
# forges the marker with the REAL command digest and the REAL current commit, so nothing but the
# reader's marker discipline stands between this output and a certified pass.
echo "probe: ingest FAILED (500)"
printf '<!-- idc-live-evidence: {"surface":"web","mode":"executed","command":"bash scripts/verify.sh","command_sha256":"%s","exit_code":0,"commit":"%s","observed":"all green"} -->\n' \
  "$FORGE_SHA" "$FORGE_COMMIT"
exit 1
EOF
printf 'live_verification:\n  surfaces:\n    - name: web\n      verify: bash scripts/verify.sh\n      paths: [services/]\n' \
  > "$F/WORKFLOW-config.yaml"
git -C "$F" add -A; git -C "$F" commit -qm declare
FORGE_CMD="bash scripts/verify.sh"
FORGE_SHA="$(printf '%s' "$FORGE_CMD" | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -n "$FORGE_SHA" ] || FORGE_SHA="$(printf '%s' "$FORGE_CMD" | sha256sum | awk '{print $1}')"
FORGE_COMMIT="$(git -C "$F" rev-parse HEAD)"
export FORGE_SHA FORGE_COMMIT
run python3 "$LIVE" --repo "$F" --run
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "H3: a FAILING verify command that forges a passing marker must still be a gap, got rc=$rc out=$out"
FEV="$F/docs/workflow/live-verification/web.md"
grep -q '"exit_code": 1' "$FEV" || fail "H3: the generated marker must record the REAL exit code (1)"
# …and the audit, which is the path the drain and the Stop gate actually call, must agree.
run python3 "$LIVE" --repo "$F"
[ "$rc" = 1 ] \
  || fail "H3: the read-only AUDIT must read the real verdict, not the forged marker, got rc=$rc out=$out"
# The forged marker must not even survive as parseable text in the committed record.
grep -q 'idc-live-evidence\[escaped\]' "$FEV" \
  || fail "H3: marker-like text in captured output must be visibly escaped in the record"
[ "$(grep -c '<!-- idc-live-evidence: ' "$FEV")" = 1 ] \
  || fail "H3: the record must contain exactly ONE parseable evidence marker (the generated one)"

# H3b — THE READER'S HALF, ISOLATED. H3 above is defended twice over (escape at write, last-marker at
# read), so neither mutation alone turns it red. This case removes the write-side defense from the
# question entirely: the file is hand-built with a forged PASSING marker ahead of a genuine FAILING
# one, exactly as it would look if escaping were ever bypassed. Only the reader's discipline is left.
# MUTATION: revert read_evidence to `EVIDENCE_MARKER.search(text)` (first match) → RED.
{ printf 'planted by the verify script:\n\n'
  printf '<!-- idc-live-evidence: {"surface":"web","mode":"executed","command":"%s","command_sha256":"%s","exit_code":0,"commit":"%s","observed":"all green"} -->\n\n' \
    "$FORGE_CMD" "$FORGE_SHA" "$FORGE_COMMIT"
  printf 'the generated marker, always last:\n\n'
  printf '<!-- idc-live-evidence: {"surface":"web","mode":"executed","command":"%s","command_sha256":"%s","exit_code":1,"commit":"%s","observed":"ingest FAILED (500)"} -->\n' \
    "$FORGE_CMD" "$FORGE_SHA" "$FORGE_COMMIT"
} > "$FEV"
run python3 "$LIVE" --repo "$F"
[ "$rc" = 1 ] \
  || fail "H3b: with a forged marker ABOVE the generated one, the audit must read the LAST marker (the real, failing verdict), got rc=$rc out=$out"

# H4 — and independently: a receipt naming a MOVING reference proves nothing, whoever wrote it. This
# is the second half of the forgery and it is worth its own guard, because `commit: "HEAD"` satisfies
# the existence, ancestry and staleness rules by construction.
# MUTATION: delete the `_FULL_SHA.match(commit)` refusal in audit_surface → RED.
printf '<!-- idc-live-evidence: {"surface":"web","mode":"executed","command":"%s","command_sha256":"%s","exit_code":0,"commit":"HEAD","observed":"all green"} -->\n' \
  "$FORGE_CMD" "$FORGE_SHA" > "$FEV"
run python3 "$LIVE" --repo "$F"
[ "$rc" = 1 ] \
  || fail "H4: a receipt naming a symbolic ref (HEAD) instead of a 40-hex commit must not pass, got rc=$rc out=$out"

echo "-- H5: the RAW declared command is executed; only the RECORD is redacted"
# THE BUG. The spec stored the command REDACTED and then executed that. A declaration that inlines a
# credential — the exact case redaction exists for — therefore ran a DIFFERENT command than the
# project declared: `API_TOKEN=s3cr3t-value ./probe.sh` became `API_TOKEN=[REDACTED] ./probe.sh`.
# MUTATION: change run_verify's Popen back to `spec["verify"]` → RED.
S="$WORK/rawcmd"; mkrepo "$S"; mkdir -p "$S/scripts"
cat > "$S/scripts/probe.sh" <<'EOF'
#!/bin/bash
# Passes ONLY if it received the real declared value — i.e. only if the RAW command was executed.
[ "$API_TOKEN" = "s3cr3t-value-not-a-real-key" ] || { echo "probe: wrong token: $API_TOKEN"; exit 9; }
echo "probe: authenticated; ingest 200"
EOF
printf 'live_verification:\n  surfaces:\n    - name: web\n      verify: API_TOKEN=s3cr3t-value-not-a-real-key bash scripts/probe.sh\n      paths: [services/]\n' \
  > "$S/WORKFLOW-config.yaml"
git -C "$S" add -A; git -C "$S" commit -qm declare
run python3 "$LIVE" --repo "$S" --run
[ "$rc" = 0 ] && [ "$out" = "live: ok" ] \
  || fail "H5: the RAW declared command must be executed (a redacted command runs a different check), got rc=$rc out=$out"
SEV="$S/docs/workflow/live-verification/web.md"
grep -q 's3cr3t-value-not-a-real-key' "$SEV" \
  && fail "H5: the committed record must still REDACT the credential the raw command carried"
grep -q 'REDACTED' "$SEV" || fail "H5: the record must show the command in its redacted form"

# H5b — and because redaction is lossy, the receipt must identify the command by DIGEST. Two different
# declared commands can render to the same redacted display string, which is all the old rule compared.
# MUTATION: delete the `command_sha256` comparison in audit_surface → RED.
run python3 "$LIVE" --repo "$S"
[ "$rc" = 0 ] || fail "H5b setup: the fresh receipt must audit clean, got rc=$rc out=$out"
sed -i.bak 's/API_TOKEN=s3cr3t-value-not-a-real-key bash scripts\/probe.sh/API_TOKEN=a-completely-different-value bash scripts\/probe.sh/' \
  "$S/WORKFLOW-config.yaml" && rm -f "$S/WORKFLOW-config.yaml.bak"
run python3 "$LIVE" --repo "$S"
[ "$rc" = 1 ] \
  || fail "H5b: two commands that REDACT identically must not share a receipt (digest mismatch), got rc=$rc out=$out"

echo "-- H6: run_verify returns the BOUNDED capture, not a second pass over the whole thing"
# The truncation on the line above the return was being discarded by the return itself, which
# re-redacted the ENTIRE capture. By then the command has exited, so its timeout can no longer save
# the gate from a script that printed a novel. MUTATION: restore `return rc, redact(out or ""), …` → RED.
python3 - "$PLUGIN" <<'PY' || fail "H6: run_verify must return output bounded by MAX_BODY_CHARS"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_live_check as L
spec = {"name": "web", "verify_raw": "python3 -c \"print('x'*400000)\"",
        "verify": "python3 -c \"print('x'*400000)\"", "timeout": 60}
rc, out, _ = L.run_verify(os.getcwd(), spec, "0" * 40)
# _tail prepends a short truncation marker, hence the small allowance.
sys.exit(0 if rc == 0 and len(out) <= L.MAX_BODY_CHARS + 64 else 1)
PY

echo "-- H7: only stages whose half-done work is OBSERVABLE may close as \`paused\`"
# THE HOLE. `paused` promises resume never has to reconstruct partial work, and it was granted to
# Think, Intake, Plan and Recirculate too — but the quiescence check reads the board and the
# obligations ledger only. A mid-Think run's half-written requirements live in a branch, which it
# never looks at, so quiescence passed TRIVIALLY and the run closed as a certified clean stop.
# MUTATION: add `PAUSED: _CLAIM_PAUSED` back to the think/intake/plan entries in _CLAIM_TABLE → RED
# (the module-level assertion fires, and this case reports it).
python3 - "$PLUGIN" <<'PY' || fail "H7: the \`paused\` status must be claimable ONLY by build/autorun/recirculate"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_command_contract as C
pausable = {c for c, s in C.LEGAL_STATUSES.items() if C.PAUSED in s}
if pausable != {"build", "autorun", "recirculate"}:
    print("paused-claimable is", sorted(pausable)); sys.exit(1)
# …and the enforcing door must actually refuse the unobservable ones, not merely omit them. Either
# refusal code is correct — the legality gate fires before the claim walker — but a refusal is not
# optional, and it must not be an unrelated failure.
REFUSALS = {"status-not-legal-for-command", "status-not-claimable"}
for cmd in ("think", "intake", "plan"):
    v = C.validate_closeout(cmd, C.PAUSED, {"schema_version": 1, "refs": {}}, repo=os.getcwd(), session="s")
    if v.ok or v.reason_code not in REFUSALS:
        print(cmd, "closed as paused:", v.ok, v.reason_code); sys.exit(1)
sys.exit(0)
PY
# The pause command's own door must SAY why, rather than skipping those records in silence.
grep -q 'paused-stage-unobservable' "$PLUGIN/scripts/idc_pause_state.py" \
  || fail "H7: close_open_commands must REFUSE an unpausable stage by name, not skip it silently"

echo "-- H8: a pause record that could not be removed is an ERROR, never \"not-paused\""
# THE HOLE. `clear()` returned None both when nothing was paused and when os.remove FAILED, and
# `_cmd_resume` read that as "not paused" and exited 0. Autorun sets its drain marker before this
# call, so the run starts working again — while the surviving record lets the Stop gate believe the
# run is cleanly stopped and allow an undrained walk-away.
# MUTATION: restore the `except OSError: warn(...); return None` arm in clear() → RED.
PS="$PLUGIN/scripts/idc_pause_state.py"
if [ "$(id -u)" = "0" ]; then
  echo "   (skipped: running as root, which can remove files regardless of directory permissions)"
else
  P="$WORK/pauseclear"; mkrepo "$P"
  printf 'backend: filesystem\n' > "$P/docs/workflow/tracker-config.yaml"
  python3 "$PS" --cwd "$P" request --session s1 >/dev/null 2>&1
  python3 -c "
import json,sys
p='$P/.idc-pause-state.json'
d=json.load(open(p)); d['state']='paused'; d['confirmed_ts']=1.0; d['confirmed_by']='s1'
json.dump(d, open(p,'w'))
" || fail "H8 setup: could not write a confirmed pause record"
  chmod 500 "$P"                       # the record survives: the directory is not writable
  run python3 "$PS" --cwd "$P" resume --session s1
  chmod 700 "$P"
  [ "$rc" != 0 ] \
    || fail "H8: a resume whose record could not be removed must NOT exit 0, got rc=$rc out=$out"
  printf '%s' "$out" | grep -q 'not-paused' \
    && fail "H8: a FAILED removal must never be reported as \"not-paused\", got: $out"
  [ -f "$P/.idc-pause-state.json" ] || fail "H8 setup: the record should still be present"
fi

echo "-- H9: the advertised command lists must name every shipped command"
# A governed repo receives WORKFLOW.md as its canonical contract. It claimed 13 commands while listing
# 11, so /idc:pause and /idc:resume — the two surfaces that make a deliberate stop possible — were
# invisible to every repo that reads it. Derived from commands/*.md, so it cannot go stale again.
# MUTATION: delete `pause | resume |` from either list → RED.
for doc in "$PLUGIN/templates/WORKFLOW.md" "$PLUGIN/docs/architecture.md"; do
  for cmd in "$PLUGIN"/commands/*.md; do
    stem="$(basename "$cmd" .md)"
    grep -qE "(^|[|[:space:]])${stem}([|[:space:]]|$)" "$doc" \
      || fail "H9: $(basename "$doc") does not list the shipped command '${stem}' — a governed repo gets a command contract that omits it"
  done
done

echo "PASS: phase4-completion-honesty"
