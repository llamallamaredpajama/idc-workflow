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
# ...and REMOVE them.
timeout "$T_S" python3 "$CC" uninstall-sidecars --repo "$REPO" --remove >/dev/null 2>&1 \
  || fail "the sidecar removal door exited non-zero"
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

fake = "0" * 40
res = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": [fake]}}, repo, "s1")
print("ok=%s code=%s detail=%s" % (res.ok, res.reason_code, res.message))
res2 = CC._claim_uninstall({"outcome": "repaired-push", "repaired": {"commits": []}}, repo, "s1")
print("empty ok=%s code=%s" % (res2.ok, res2.reason_code))
res3 = CC._claim_uninstall({"outcome": "repaired-push"}, repo, "s1")
print("shape ok=%s code=%s" % (res3.ok, res3.reason_code))
res4 = CC._claim_uninstall(
    {"outcome": "repaired-push", "repaired": {"commits": [fake], "removed": ["WORKFLOW.md"]}},
    repo, "s1")
print("removed ok=%s code=%s" % (res4.ok, res4.reason_code))
res5 = CC._claim_uninstall({"outcome": "nonsense"}, repo, "s1")
print("bogus ok=%s code=%s detail=%s" % (res5.ok, res5.reason_code, res5.message))
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
