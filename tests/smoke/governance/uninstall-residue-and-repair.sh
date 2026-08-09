#!/bin/bash
# idc-assert-class: behavior
# uninstall-residue-and-repair.sh — the uninstall/doctor completeness cluster: #209 (residue),
# #203 (a push-stranded repo is invisible until a push fails) and #204 (recovery has no closable
# command record).
#
# ── #209 — RESIDUE ────────────────────────────────────────────────────────────────────────────────
# `/idc:init` deliberately GITIGNORES IDC's machine-written sidecars, and the uninstall removal
# commit's only deletion verb is `git rm --ignore-unmatch`, which removes what git TRACKS. So every
# ignored sidecar survives an otherwise-complete uninstall. Two of them do real damage:
#   * `docs/workflow/install-receipt.yaml` — doctor then reports the repo as still carrying an IDC
#     footprint, so a completed removal reads as incomplete (both 2026-08-08/09 e2e runs deleted it
#     by hand after doctor exposed it);
#   * `.idc-session-state.json` — the obligations LEDGER, which is where command lifecycle records
#     live. A Plan record naming a board that `--delete-board` had just deleted survived into the
#     NEXT install and collided with its plan. That is #209's second half, and it needs no separate
#     mechanism: purging the ledger purges the stale records with it.
#
# ── #203 — INVISIBLE STRANDING ───────────────────────────────────────────────────────────────────
# A repo stranded by a pre-6.0.1 uninstall (its removal commit unwitnessed in the outgoing range) is
# indistinguishable from a healthy one until `git push` fails — and the refusal then reads as if
# whatever was just committed were at fault. `audit-outgoing` walks the range through the SAME code
# path the hook uses, so the diagnosis cannot disagree with the thing that actually refuses.
#
# ── #204 — UNCLOSABLE RECOVERY ───────────────────────────────────────────────────────────────────
# `--repair-push` was built during the #202 wave and REVERTED: the closeout validator accepted only
# `applied` / `no-action`, and a re-governed repo (the normal state when recovery is needed) is
# neither — so the flag would have stranded a command record. The third outcome `repaired-push`
# closes that, with the witness itself as its evidence contract.
#
# Red-when-broken: see the per-case notes; each assertion names the specific defect it pins.
#
# Usage: bash tests/smoke/governance/uninstall-residue-and-repair.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
CC="$PLUGIN/scripts/idc_command_contract.py"
GPG="$PLUGIN/scripts/idc_git_path_gate.py"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

for f in "$CC" "$GPG" "$SCAFFOLD"; do
  [ -f "$f" ] || fail "missing shipped helper: $f"
done

# BOUND EVERY PROBE (phase-governance rule 5): a hang must read as RED, never as a slow pass.
T_S="${T_S:-120}"
command -v timeout >/dev/null 2>&1 \
  || fail "BLOCKED: \`timeout\` is not on PATH. Every probe here runs under an explicit bound so a
hung helper REDS instead of looking like a slow pass. Run via tests/smoke/run-all.sh (which sources
tests/smoke/smoke-path-preflight.sh), or install coreutils, then re-run."

# ══ #209 ═════════════════════════════════════════════════════════════════════════════════════════
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
timeout "$T_S" bash "$SCAFFOLD" "$PLUGIN" "$REPO" "Residue Proj" filesystem >/dev/null 2>&1 \
  || fail "the scaffold helper failed on the fixture repo"

# CONTROL FIRST — the sidecars must really be gitignored here, or "git rm cannot reach them" would
# hold for the wrong reason and the whole case would be vacuous.
git -C "$REPO" check-ignore -q docs/workflow/install-receipt.yaml \
  || fail "control: docs/workflow/install-receipt.yaml is NOT gitignored in a freshly scaffolded
repo, so this lane's premise is wrong — re-derive the sidecar list from what the scaffold ignores"

# Create the two sidecars that carry the observed damage, plus one per-session glob shape.
printf 'receipt_version: 2\nfingerprint_method: sha256\nfiles: []\n' \
  > "$REPO/docs/workflow/install-receipt.yaml"
printf '{"version":2,"commands":[{"session_id":"s1","command":"plan","project":23}],"taints":[]}\n' \
  > "$REPO/.idc-session-state.json"
printf '{}\n' > "$REPO/.idc-doctor-report.json"

# THE DEFECT, reproduced with uninstall's own removal verb: `git rm` cannot touch an untracked file.
git -C "$REPO" rm --quiet --ignore-unmatch \
  docs/workflow/install-receipt.yaml docs/workflow/tracker-config.yaml >/dev/null 2>&1
[ -f "$REPO/docs/workflow/install-receipt.yaml" ] \
  || fail "fixture: \`git rm --ignore-unmatch\` unexpectedly removed the IGNORED receipt, so the
residue this lane pins cannot be reproduced — re-check whether init still gitignores it"

# The door must SEE them...
LIST="$(timeout "$T_S" python3 "$CC" uninstall-sidecars --repo "$REPO" 2>&1)" \
  || fail "the sidecar listing door exited non-zero: $LIST"
for want in docs/workflow/install-receipt.yaml .idc-session-state.json .idc-doctor-report.json; do
  printf '%s\n' "$LIST" | grep -qxF "$want" \
    || fail "#209: the sidecar door does not enumerate '$want', so an applied uninstall leaves it
behind as residue for the next install. Listing was:
$LIST"
done
# The BASELINE MARKER must NOT be in this set: the scaffold does not gitignore it, so it is durable
# clone-portable state that CAN be tracked. Purging it here would remove it only AFTER the removal
# commit, leaving a tracked deletion in the worktree and breaking the one-commit uninstall contract.
printf '{}\n' > "$REPO/docs/workflow/reconciliation-baseline-required.json"
git -C "$REPO" check-ignore -q docs/workflow/reconciliation-baseline-required.json \
  && fail "control: the baseline marker is now gitignored, so this assertion's premise changed —
re-decide whether it belongs to the ignored-sidecar sweep or the tracked manifest"
timeout "$T_S" python3 "$CC" uninstall-sidecars --repo "$REPO" 2>&1 \
  | grep -q 'reconciliation-baseline-required' \
  && fail "#209: the ignored-sidecar sweep claims the baseline marker, which git can TRACK — it must
be handled by the tracked removal manifest before the commit, not purged after it"

# THE REMOVAL GATE. `.idc-session-state.json` is the obligations LEDGER: it holds the ACTIVE command
# records the Stop closeout gate reads, and a missing ledger reads as "no obligations". So a removal
# verb callable at any time could erase the current command's obligation and let a session walk away
# from an unfinished command — strictly worse than the residue it cleans. The gate is the ordering
# requirement made mechanical: refuse while the governance anchor is still present.
[ -f "$REPO/docs/workflow/tracker-config.yaml" ] \
  || fail "control: the fixture must still be GOVERNED here, or the refusal below proves nothing"
timeout "$T_S" python3 "$CC" uninstall-sidecars --repo "$REPO" --remove >"$WORK/gated.out" 2>&1
RC=$?
[ "$RC" -eq 2 ] \
  || fail "#209: purging sidecars in a repo that is STILL GOVERNED must be refused (exit 2), got
$RC. An ungated removal verb deletes the obligations ledger mid-command and lets the session stop
without finishing: $(cat "$WORK/gated.out")"
[ -f "$REPO/.idc-session-state.json" ] \
  || fail "#209: the refused purge deleted the ledger anyway — a refusal must change nothing"
grep -qi 'still governed' "$WORK/gated.out" \
  || fail "#209: the refusal must name the condition (still governed): $(cat "$WORK/gated.out")"

# SYMLINK SAFETY: a sidecar NAME pointing at an operator file must never delete that file.
printf 'operator data\n' > "$REPO/operator-notes.md"
mv "$REPO/.idc-drain-verdict.json" "$WORK/dv.bak" 2>/dev/null || true
ln -s operator-notes.md "$REPO/.idc-drain-verdict.json"

# Now ungovern the repo (what 3c's commit does) so the purge is legitimately allowed.
rm -f "$REPO/docs/workflow/tracker-config.yaml"
timeout "$T_S" python3 "$CC" uninstall-sidecars --repo "$REPO" --remove >/dev/null 2>&1 \
  || fail "the sidecar removal door exited non-zero once the repo was ungoverned"
[ -f "$REPO/operator-notes.md" ] \
  || fail "#209: the purge followed a symlink and deleted the operator file it pointed at. A sidecar
is a machine-written REGULAR file; a symlink at that name must be left alone, never resolved and
unlinked at its target."
rm -f "$REPO/.idc-drain-verdict.json"
for gone in docs/workflow/install-receipt.yaml .idc-session-state.json .idc-doctor-report.json; do
  [ ! -e "$REPO/$gone" ] \
    || fail "#209: '$gone' survived the removal door — an ignored sidecar that outlives uninstall is
exactly the residue that collided with the next install's plan"
done
# Idempotent: a second pass is a clean no-op, not an error (uninstall re-runs are ordinary).
OUT2="$(timeout "$T_S" python3 "$CC" uninstall-sidecars --repo "$REPO" --remove 2>&1)" \
  || fail "#209: a second removal pass must be a clean no-op, not an error: $OUT2"
printf '%s\n' "$OUT2" | grep -qi 'no ignored' \
  || fail "#209: a no-op removal pass must say so plainly; got: $OUT2"

# ══ #203 ═════════════════════════════════════════════════════════════════════════════════════════
# A repo whose outgoing range is clean must audit as publishable; the fixture repo has a remote with
# nothing unusual in it.
BARE="$WORK/remote.git"
git init -q --bare "$BARE"
SREPO="$WORK/stranded"
git init -q -b main "$SREPO"
git -C "$SREPO" config user.email t@t
git -C "$SREPO" config user.name t
git -C "$SREPO" remote add origin "$BARE"
git -C "$SREPO" commit -q --allow-empty -m init
git -C "$SREPO" push -q origin main 2>/dev/null
# GOVERNED, because that is the state a repair actually runs in (recovery is needed precisely when a
# later /idc:init has re-armed the gate over the historical removal) — and because the ledger's
# command_start is repo-gated: an ungoverned fixture would silently record no flags at all, so every
# "the mode was stamped" assertion below would pass for the wrong reason.
timeout "$T_S" bash "$SCAFFOLD" "$PLUGIN" "$SREPO" "Repair Proj" filesystem >/dev/null 2>&1 \
  || fail "the scaffold helper failed on the repair fixture"

# CONTROL: a clean range audits ok (exit 0). Without this, the "would-refuse" arm below could pass
# because the auditor reports trouble for everything.
timeout "$T_S" python3 "$GPG" audit-outgoing --repo "$SREPO" --plugin-root "$PLUGIN" \
  --remote origin >"$WORK/a1.out" 2>&1
RC=$?
[ "$RC" -ne 124 ] || fail "#203: the audit probe hung (RED, never a slow pass)"
[ "$RC" -eq 0 ] \
  || fail "#203 control: a repo with a clean outgoing range must audit as publishable (exit 0), got
$RC. A diagnosis that reports trouble for everything cannot discriminate anything:
$(cat "$WORK/a1.out")"

# An UNREACHABLE remote must be SKIP-shaped (exit 2), never a hollow "ok": "we could not tell" is not
# the same as "fine", and this is the arm that keeps the row honest on a disconnected machine.
timeout "$T_S" python3 "$GPG" audit-outgoing --repo "$SREPO" --plugin-root "$PLUGIN" \
  --remote definitely-no-such-remote >"$WORK/a2.out" 2>&1
RC=$?
[ "$RC" -ne 124 ] || fail "#203: the unreachable-remote probe hung (RED)"
[ "$RC" -eq 2 ] \
  || fail "#203: an unresolvable remote must be INDETERMINATE (exit 2), never reported as
publishable — an unknown range is not a clean one. Got exit $RC:
$(cat "$WORK/a2.out")"
grep -qi 'indeterminate' "$WORK/a2.out" \
  || fail "#203: the indeterminate verdict must say so in its own output: $(cat "$WORK/a2.out")"

# A remote that HANGS must become an honest indeterminate, not a wedged /idc:doctor. Driven by
# forcing the timeout the bounded probe uses, rather than by waiting on a real unreachable host:
# a lane that actually blocks for the bound would be indistinguishable from the hang it tests.
timeout "$T_S" python3 - "$PLUGIN" "$SREPO" <<'PY' >"$WORK/a3.out" 2>&1
import subprocess, sys
plugin, repo = sys.argv[1:3]
sys.path.insert(0, plugin + "/scripts")
import idc_git_path_gate as G

real_run = subprocess.run
def hang(cmd, *a, **kw):
    if isinstance(cmd, list) and "ls-remote" in cmd:
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout", 1))
    return real_run(cmd, *a, **kw)
subprocess.run = hang

v = G.audit_outgoing(repo, plugin, "origin")
print("status=%s" % v["status"])
if not isinstance(getattr(G, "AUDIT_REMOTE_TIMEOUT_S", None), int):
    print("NO-BOUND: the remote probe declares no timeout constant")
PY
RC=$?
[ "$RC" -ne 124 ] || fail "#203: the timeout-mapping probe itself hung — the bound is not applied"
grep -q 'status=indeterminate' "$WORK/a3.out"   || fail "#203: a remote probe that TIMES OUT must map to indeterminate, never to a clean range —
otherwise a slow or prompting remote either wedges /idc:doctor or reports the range publishable
without ever having read it. Got:
$(cat "$WORK/a3.out")"
grep -q 'NO-BOUND' "$WORK/a3.out"   && fail "#203: the remote probe must declare an explicit timeout bound"

# The audit is READ-ONLY: it must never witness anything on the operator's behalf.
WITNESS_DIR="$(git -C "$SREPO" rev-parse --path-format=absolute --git-common-dir)/idc-path-gate"
[ ! -f "$WITNESS_DIR/uninstall-witness.json" ] \
  || fail "#203: the read-only audit recorded an uninstall witness — a diagnosis must never make the
condition it diagnoses go away"

# ══ #204 ═════════════════════════════════════════════════════════════════════════════════════════
# The closeout outcome, exercised through the shipped validator (not a mock). A repaired-push claim
# naming a commit that no witness records must be REFUSED — the evidence is the witness, re-derived,
# never the caller's word.
timeout "$T_S" python3 - "$PLUGIN/scripts" "$SREPO" <<'PY' >"$WORK/r1.out" 2>&1
import sys
scripts, repo = sys.argv[1:3]
sys.path.insert(0, scripts)
import idc_command_contract as CC
sys.path.insert(0, scripts + "/hooks")
import idc_ledger

fake = "0" * 40                       # resolves to nothing at all
import subprocess
real = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                      capture_output=True, text=True).stdout.strip()   # exists, but unwitnessed
assert len(real) == 40, "fixture: could not read the fixture repo's HEAD"

# (a) UNREQUESTED: no --repair-push stamped. The witness store is repository-WIDE, so without this
# gate an ordinary uninstall could cite some earlier repair's commit and close as a repair.
res0 = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": [real]}}, repo, "s0")
print("unrequested ok=%s code=%s" % (res0.ok, res0.reason_code))

# Stamp the mode for every case below.
rec = idc_ledger.command_start(repo, session_id="s1", command="uninstall", plugin_version="test",
                               args_sha256="x", source="user", uninstall_flags=["repair-push"])
assert rec, "fixture: the ledger refused the --repair-push stamp (is the fixture repo governed?)"
res = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": [real]}}, repo, "s1")
print("ok=%s code=%s detail=%s" % (res.ok, res.reason_code, res.message))
resU = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": [fake]}}, repo, "s1")
print("unresolvable ok=%s code=%s" % (resU.ok, resU.reason_code))
# An ABBREVIATED sha must reach the witness check, not die on a literal string compare: the
# documented recovery reads candidates from `git log --oneline`, which prints short ones.
resA = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": [real[:8]]}},
                           repo, "s1")
print("abbrev ok=%s code=%s" % (resA.ok, resA.reason_code))
res2 = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": []}}, repo, "s1")
print("empty ok=%s code=%s" % (res2.ok, res2.reason_code))
res3 = CC._claim_uninstall({"outcome": "repaired-push"}, repo, "s1")
print("shape ok=%s code=%s" % (res3.ok, res3.reason_code))
res4 = CC._claim_uninstall(
    {"outcome": "repaired-push", "repaired": {"commits": [real], "removed": ["WORKFLOW.md"]}},
    repo, "s1")
print("removed ok=%s code=%s" % (res4.ok, res4.reason_code))
res5 = CC._claim_uninstall({"outcome": "nonsense"}, repo, "s1")
print("bogus ok=%s code=%s detail=%s" % (res5.ok, res5.reason_code, res5.message))

# (b) BOARD FLAGS alongside the repair mode: one record cannot owe two outcomes.
rec2 = idc_ledger.command_start(repo, session_id="s2", command="uninstall", plugin_version="test",
                                args_sha256="x", source="user",
                                uninstall_flags=["repair-push", "delete-board"])
assert rec2, "fixture: the ledger refused the two-flag stamp"
res6 = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": [real]}}, repo, "s2")
print("boardflags ok=%s code=%s" % (res6.ok, res6.reason_code))
PY
RC=$?
[ "$RC" -ne 124 ] || fail "#204: the closeout probe hung (RED)"
grep -q 'ok=False code=uninstall-repair-unwitnessed' "$WORK/r1.out" \
  || fail "#204: a repaired-push claim naming a commit NO witness records must be refused — the
evidence contract is the machine-owned witness, re-derived at close time, never the caller's word.
Got:
$(cat "$WORK/r1.out")"
grep -q 'empty ok=False code=uninstall-repair-empty' "$WORK/r1.out" \
  || fail "#204: a repaired-push with an empty commit list must be refused — a repair that witnessed
nothing repaired nothing. Got:
$(cat "$WORK/r1.out")"
grep -q 'shape ok=False code=uninstall-repair-shape' "$WORK/r1.out" \
  || fail "#204: a repaired-push with no refs.repaired at all must be refused. Got:
$(cat "$WORK/r1.out")"
grep -q 'removed ok=False code=uninstall-repair-removed' "$WORK/r1.out" \
  || fail "#204: a repaired-push that ALSO reports removals must be refused — a run that removed
footprints is an 'applied' uninstall and has to be validated as one. Got:
$(cat "$WORK/r1.out")"
# ...and the outcome enumeration must NAME the new outcome, or an agent reading the refusal cannot
# discover the terminal its own record is allowed to take.
grep -q "bogus ok=False" "$WORK/r1.out" \
  || fail "#204: an unknown outcome must still be refused. Got: $(cat "$WORK/r1.out")"
grep -q "repaired-push" "$WORK/r1.out" \
  || fail "#204: the outcome refusal must NAME 'repaired-push' among the legal outcomes — a
validator that refuses without naming the legal set leaves the caller guessing. Got:
$(cat "$WORK/r1.out")"
grep -q 'unrequested ok=False code=uninstall-repair-unrequested' "$WORK/r1.out" \
  || fail "#204: repaired-push must be UNAVAILABLE to a run that was not invoked with --repair-push.
The uninstall witness is repository-wide, so an ordinary uninstall could otherwise cite an older
repair's commit and close as a repair while the repo stayed installed. Got:
$(cat "$WORK/r1.out")"
grep -q 'unresolvable ok=False code=uninstall-repair-unresolvable' "$WORK/r1.out" \
  || fail "#204: a sha that resolves to no commit here must be refused as unresolvable. Got:
$(cat "$WORK/r1.out")"
grep -q 'abbrev ok=False code=uninstall-repair-unwitnessed' "$WORK/r1.out" \
  || fail "#204: an ABBREVIATED sha must be resolved to its full OID before the witness lookup — the
documented recovery reads candidates from \`git log --oneline\`, which prints short shas, while the
witness door stores full ones. A literal string compare makes a genuine repair unclosable. Got:
$(cat "$WORK/r1.out")"
grep -q 'boardflags ok=False code=uninstall-repair-board-flags' "$WORK/r1.out" \
  || fail "#204: --repair-push combined with a board flag must be refused — recovery removes nothing
and touches no board, and one command record cannot owe two outcomes. Got:
$(cat "$WORK/r1.out")"

# ══ prose contracts ══════════════════════════════════════════════════════════════════════════════
U="$PLUGIN/commands/uninstall.md"
D="$PLUGIN/commands/doctor.md"
grep -q 'uninstall-sidecars' "$U" \
  || fail "#209: commands/uninstall.md must RUN the sidecar purge door, not merely describe residue"
grep -qi 'AFTER the 3b .finish.' "$U" \
  || fail "#209: uninstall.md must state that the sidecar purge runs AFTER the closeout finish — the
ledger substrate is what finish closes the record against, so an earlier purge strips the run's own
lifecycle record out from under it"
grep -q 'repaired-push' "$U" \
  || fail "#204: uninstall.md must document the repaired-push closeout outcome"
grep -q 'repair-push' "$U" \
  || fail "#204: uninstall.md must document the --repair-push entry point"
grep -q 'audit-outgoing' "$D" \
  || fail "#203: commands/doctor.md must run the read-only outgoing-range audit"

echo "PASS: uninstall purges its ignored sidecars (receipt + ledger, so stale lifecycle records go with them), doctor can name a push-stranded range before a push fails, and recovery closes through a witness-verified repaired-push outcome"
