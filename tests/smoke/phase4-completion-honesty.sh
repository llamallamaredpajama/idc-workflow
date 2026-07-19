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
#   scripts/idc_live_check.py       — was the project's DECLARED live surface actually driven, on the
#                                     code that is running now?
# plus their wiring into idc_autorun_drain.py's wave close, where exit 4 is already the code the Stop
# fixpoint gate refuses a stop on (so enforcement needs no new hook).
#
# RED-WHEN-BROKEN (each assertion below names the single edit that makes it fail; all were executed
# and observed RED before this suite was committed — see the branch's verification receipts):
#   * A1/A2  delete the `if f.get("op") not in STALE_OPS: continue` filter in idc_finish_coherence.py
#            → A2 still passes but A1 goes RED (unrelated janitor debris starts reporting as a gap).
#   * A3     drop the `board_scanned is not True` guard → A3 goes RED (a board-less scan reads "ok",
#            the hollow clean this gate exists to prevent).
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

# Now DECLARE a surface — opting in is the only way to be gated.
cat > "$L/WORKFLOW-config.yaml" <<'EOF'
project:
  name: demo
live_verification:
  surfaces:
    - name: web
      journey: sign in -> ingest text -> open the item -> chat
      paths: [services/, infra/]
EOF
git -C "$L" add -A; git -C "$L" commit -qm declare

# B3 — declared but never driven is a GAP. This is the state the real repo shipped in.
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B3: a declared surface with no evidence must be a gap, got rc=$rc out=$out"

# Record honest evidence for exactly what is running now.
SHA="$(git -C "$L" rev-parse HEAD)"
ev() { printf '<!-- idc-live-evidence: %s -->\n' "$1" > "$L/docs/workflow/live-verification/web.md"; }
ev "{\"surface\":\"web\",\"commit\":\"$SHA\",\"observed\":\"ingest 200; open 200 signed URL; chat 200\"}"
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
ev "{\"surface\":\"web\",\"commit\":\"$(git -C "$L" rev-parse HEAD)\",\"observed\":\"re-driven: all green\"}"
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
ev '{"surface":"web","commit":"0123456789abcdef0123456789abcdef01234567","observed":"x"}'
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
ev "{\"surface\":\"web\",\"commit\":\"$SIDE\",\"observed\":\"looked fine on my branch\"}"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 1 ] && [ "$out" = "live: gap web" ] \
  || fail "B7b: evidence from an unmerged commit must not satisfy the gate, got rc=$rc out=$out"

# B8 — an empty `observed` is not evidence.
ev "{\"surface\":\"web\",\"commit\":\"$SHA\",\"observed\":\"   \"}"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B8: a blank observed field must fail closed (exit 2), got rc=$rc out=$out"

# B9 — a surface declared WITHOUT paths would have evidence that never expires, so the declaration
# itself is refused rather than silently accepted as a permanent pass.
printf 'live_verification:\n  surfaces:\n    - name: web\n' > "$L/WORKFLOW-config.yaml"
run python3 "$LIVE" --repo "$L"
[ "$rc" = 2 ] || fail "B9: a surface with no paths must be refused (exit 2), got rc=$rc out=$out"

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
cat > "$D/WORKFLOW-config.yaml" <<'EOF'
live_verification:
  surfaces:
    - name: web
      paths: [services/]
EOF
git -C "$D" add -A; git -C "$D" commit -qm declare
run python3 "$DRAIN" --tracker "$T" --coherence --live
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
grep -q 'python3 "\${CLAUDE_PLUGIN_ROOT}/scripts/idc_live_check\.py"' "$PLUGIN/agents/idc-build.md" \
  || fail "E3: agents/idc-build.md wave close must INVOKE idc_live_check.py"

echo "PASS: phase4-completion-honesty"
