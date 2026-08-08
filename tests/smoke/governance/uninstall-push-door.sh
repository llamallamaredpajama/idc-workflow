#!/bin/bash
# uninstall-push-door.sh — issue #201: the sanctioned uninstall removal commit must be publishable,
# and NOTHING else that touches a protected machine surface may ride along with it.
#
# THE CONTRADICTION THIS PINS. `/idc:uninstall` lands the removal as one revertable commit that
# necessarily DELETES `TRACKER.md` (a protected machine-owned surface) together with the governance
# anchor `docs/workflow/tracker-config.yaml`. That commit itself lands because both git backstops go
# dormant the moment the anchor leaves the worktree. But the instant the repo is governed again — a
# fresh `/idc:init`, or a `git revert` — the pre-push backstop re-examines the WHOLE outgoing range
# under today's posture, finds the historical `TRACKER.md` deletion, and refuses the push forever.
# The uninstall commit poisons every later commit in the range and strands the repo permanently ahead
# of its remote, with no sanctioned recovery door.
#
# THE DOOR. `idc_git_path_gate.py witness-uninstall` is the only way a commit becomes push-admissible
# through this exemption. It records the commit's own OID in machine-owned state under the repository
# Git directory, and BOTH the door and the push-time gate independently re-derive the commit's shape
# from git before honoring it:
#   * exactly one parent, whose tree HAS the governance anchor, while the commit's own tree does NOT
#     (it is genuinely THE ungoverning commit — a stray edit to TRACKER.md can never be this shape);
#   * every protected machine surface it touches is touched by DELETION only.
# The exemption drops ONLY that commit's protected deletions. Every other path in it, and every path
# in every other commit of the range, stays under the ordinary live-authorization boundary.
#
# WHAT THIS LANE PROVES (red-when-broken for each fix point):
#   1. REPRO — uninstall + a fresh init is unpushable, with issue #201's verbatim refusal, while no
#      sanctioned witness exists.
#   2. RECOVERY — the door admits an ALREADY-STRANDED repo retroactively and the push then lands.
#   3. CONTROL — a hand-made commit that mutates TRACKER.md is STILL refused at push (the exemption
#      is not "the range contains a witnessed commit" and not "the path is TRACKER.md").
#   4. FORGERY — the door refuses a commit that leaves the repo governed, and one that re-adds a
#      protected surface; a hand-forged witness naming an ordinary commit is refused at push, because
#      the gate re-derives the shape and never takes the witness's word.
#   5. FORWARD — an uninstall that witnesses its own commit pushes with no recovery step at all.
#   6. PARTIAL — a commit that drops the anchor but leaves the rest of the footprint installed is
#      refused: witnessing is bound to a COMPLETED uninstall, not to "the anchor is gone".
#   7. MANIFEST — the receipt-derived removal set both refuses a partial removal in a receipt-backed
#      repo AND still admits a real uninstall that kept an operator-customized file.
#   8. WORKTREE — a witness written from a linked worktree is visible to a push from the primary
#      checkout and survives that worktree's removal (it is repository-wide evidence).
#   9. RETENTION — no fixed ceiling evicts a witness the outgoing range still needs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GIT_GATE="$GOV_PLUGIN/scripts/idc_git_path_gate.py"
PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
PG_AUTHORIZE="$GOV_PLUGIN/tests/smoke/lib/path_gate_authorize.py"
[ -f "$GIT_GATE" ]      || gov_fail "idc_git_path_gate.py not found at $GIT_GATE"
[ -f "$PATH_GATE" ]     || gov_fail "idc_path_gate.py not found at $PATH_GATE"
[ -f "$CONTRACT" ]      || gov_fail "idc_command_contract.py not found at $CONTRACT"
[ -f "$PG_AUTHORIZE" ]  || gov_fail "the scenario mint fixture not found at $PG_AUTHORIZE"
export IDC_SMOKE_FIXTURE=1

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The verbatim protected-surface refusal issue #201 reports. Asserting the exact sentence keeps this
# lane pinned to the reported failure rather than to "some push failure".
DENY_MARK='`TRACKER.md` is or contains a protected machine-owned surface'

REPO=""; REMOTE=""      # set by new_governed_repo; every helper below acts on the current pair

# The governed scaffold, mirroring what `/idc:init` leaves on the filesystem backend. TRACKER.md is
# written here but deliberately NOT part of any init commit: it is runtime-created and not
# receipt-listed (commands/uninstall.md Phase 1), so only the baseline — seeded before the backstops
# exist, exactly as governance/path-gate-git-backstops.sh does — ever tracks it.
SCAFFOLD_RECEIPT=0      # 1 → also stamp a real install receipt over the scaffold (see new_receipt_repo)
write_scaffold() {
  mkdir -p "$REPO/docs/workflow" "$REPO/.claude"
  printf 'backend: filesystem\n'                          > "$REPO/docs/workflow/tracker-config.yaml"
  printf 'pathway_enforcement:\n  mode: controlled\n'     > "$REPO/WORKFLOW-config.yaml"
  printf '# IDC workflow\n'                               > "$REPO/WORKFLOW.md"
  printf '# workflow docs\n'                              > "$REPO/docs/workflow/README.md"
  printf 'ticket: demo\n'                                 > "$REPO/TRACKER.md"
  printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO/.claude/settings.json"
  [ "$SCAFFOLD_RECEIPT" = "1" ] || return 0
  python3 "$GOV_PLUGIN/scripts/idc_receipt_check.py" stamp --repo "$REPO" \
    --plugin-version 9.9.9 --out "$REPO/docs/workflow/install-receipt.yaml" \
    WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml docs/workflow/README.md \
    >/dev/null 2>&1 || gov_fail "could not stamp the install receipt over the scaffold"
}

# A governed repo published to a bare origin, with the real backstops installed afterwards.
new_governed_repo() {
  REPO="$WORK/$1"; REMOTE="$WORK/$1.git"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    git init -q
    git checkout -q -b main
    git config user.email idc@example.test
    git config user.name 'IDC Uninstall Door'
  )
  git init --bare -q "$REMOTE"
  git -C "$REPO" remote add origin "$REMOTE"
  write_scaffold
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm 'test: governed baseline'
  git -C "$REPO" push -q -u origin main >/dev/null 2>&1 \
    || gov_fail "could not publish the governed baseline for $1"
  python3 "$GIT_GATE" install-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
    || gov_fail "could not install the git backstops in $1"
  python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
    || gov_fail "freshly-installed git backstops did not verify in $1"
}

# The uninstall removal commit, exactly as commands/uninstall.md Phase 3c lands it: every footprint
# removed (governance anchor last), the enablement key stripped, one revertable commit. No
# --no-verify — the point is that this commit is legitimately admissible when it is made.
# $1 (optional) — the worktree to commit in, so arm 8 can run the same removal from a LINKED one.
make_uninstall_commit() {
  local dir="${1:-$REPO}"
  git -C "$dir" rm -q TRACKER.md WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/README.md docs/workflow/tracker-config.yaml
  printf '{"enabledPlugins":{}}\n' > "$dir/.claude/settings.json"
  git -C "$dir" add .claude/settings.json
  git -C "$dir" commit -q -m 'idc: uninstall — remove IDC footprints (revert this commit to reinstate)' \
    || gov_fail "the uninstall removal commit was refused at pre-commit (it must land: the anchor is already gone)"
}

# A governed repo whose scaffold is covered by a REAL install receipt — the MODERN install shape,
# where the removal manifest is derived from the receipt rather than from the legacy fixed list. The
# receipt rides the BASELINE, seeded before the backstops exist, for the same reason TRACKER.md does:
# it is a protected machine surface, so a later commit of it would be gated on its own account and
# the arm would stop being about the manifest.
new_receipt_repo() {
  SCAFFOLD_RECEIPT=1
  new_governed_repo "$1"
  SCAFFOLD_RECEIPT=0
  git -C "$REPO" cat-file -e HEAD:docs/workflow/install-receipt.yaml \
    || gov_fail "the receipt-backed baseline for $1 does not actually track an install receipt"
}

# A fresh `/idc:init` on top: the scaffold returns, the repo is governed again, and from here every
# push is inspected over the whole outgoing range — the uninstall commit included. The authorization
# is minted BEFORE the commit because the pre-commit backstop gates the scaffold write too, exactly
# as a real init does.
make_init_commit() {
  write_scaffold
  mint_init_auth
  git -C "$REPO" add .claude/settings.json WORKFLOW.md WORKFLOW-config.yaml docs/workflow
  git -C "$REPO" commit -q -m 'chore: initialize IDC workflow' \
    || gov_fail "the fresh init commit was refused at pre-commit"
}

# A live init authorization, so the ordinary (non-protected) paths in the range sit inside a real
# boundary. Without it every push below would deny for a second, unrelated reason and the lane could
# not tell the protected-surface refusal apart from a missing authorization.
SID_SEQ=0
mint_init_auth() {
  SID_SEQ=$((SID_SEQ + 1))
  local sid="uninstall-door-$$-$SID_SEQ"
  python3 "$CONTRACT" start --repo "$REPO" --session "$sid" --command init \
    --plugin-root "$GOV_PLUGIN" --args 'demo' --source user >/dev/null \
    || gov_fail "could not open the active /idc:init command record for $sid"
  python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$sid" --command init \
    --branch "$(git -C "$REPO" branch --show-current)" --graph-node NODE-INIT \
    --allow-action write --allow-action edit --allow-action git --allow-path . >/dev/null \
    || gov_fail "could not write the init Path Gate authorization for $sid"
}

witness_path() {
  local p; p="$(git -C "$REPO" rev-parse --git-path idc-path-gate/uninstall-witness.json)"
  case "$p" in /*) printf '%s' "$p" ;; *) printf '%s' "$REPO/$p" ;; esac
}

# ── 1. REPRO: uninstall + re-init is unpushable while no sanctioned witness exists ────────────────
new_governed_repo stranded
make_uninstall_commit
UNINSTALL_SHA="$(git -C "$REPO" rev-parse HEAD)"
make_init_commit

if git -C "$REPO" push origin main >"$WORK/stranded.out" 2>&1; then
  gov_fail "pre-push published an unwitnessed uninstall commit — the exemption is not door-bound"
fi
grep -qF "$DENY_MARK" "$WORK/stranded.out" \
  || gov_fail "the stranded push failed for some OTHER reason than issue #201's protected-surface refusal: $(cat "$WORK/stranded.out")"
[ "$(git -C "$REPO" rev-parse origin/main)" != "$(git -C "$REPO" rev-parse HEAD)" ] \
  || gov_fail "the remote advanced despite the refusal"

# ── 2. RECOVERY: the door admits an already-stranded uninstall commit, retroactively ──────────────
# This is the path a repo stranded by an older plugin version needs: the commit already exists, no
# witness was ever written, and the operator must still be able to publish it.
python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$UNINSTALL_SHA" >"$WORK/witness.out" 2>&1 \
  || gov_fail "the sanctioned recovery door refused a genuine uninstall commit: $(cat "$WORK/witness.out")"
[ -f "$(witness_path)" ] || gov_fail "witness-uninstall reported success but wrote no witness"

git -C "$REPO" push origin main >"$WORK/recovered.out" 2>&1 \
  || gov_fail "the witnessed uninstall commit is still unpushable: $(cat "$WORK/recovered.out")"
[ "$(git -C "$REPO" rev-parse origin/main)" = "$(git -C "$REPO" rev-parse HEAD)" ] \
  || gov_fail "push reported success but the remote did not advance to the init commit"
git --git-dir="$REMOTE" cat-file -e main:WORKFLOW.md 2>/dev/null \
  || gov_fail "the published history is missing the re-initialized scaffold"
if git --git-dir="$REMOTE" cat-file -e main:TRACKER.md 2>/dev/null; then
  gov_fail "the published history still carries TRACKER.md — the uninstall removal did not land"
fi

# ── 3. CONTROL: an ordinary hand-made TRACKER.md mutation is STILL refused at push ────────────────
# The exemption must bind to the uninstall SHAPE, not to "this range contains a witnessed commit".
# This stray commit rides the very range that just published successfully.
printf 'ticket: HAND-EDITED\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: stray hand edit of the tracker' \
  || gov_fail "could not create the stray-edit control commit"
if git -C "$REPO" push origin main >"$WORK/control.out" 2>&1; then
  gov_fail "pre-push published a stray hand edit of TRACKER.md — the uninstall exemption opened a hole"
fi
grep -qF "$DENY_MARK" "$WORK/control.out" \
  || gov_fail "the stray-edit refusal did not cite the protected surface: $(cat "$WORK/control.out")"

# ── 4. FORGERY: the door refuses everything that is not the ungoverning shape ─────────────────────
# (a) A commit that DELETES TRACKER.md while leaving the repo governed is not an uninstall — it is an
#     agent "tidying up" without running the playbook, the likeliest accidental near-miss. It is
#     deletion-only ON PURPOSE, so the protected-surface clause is satisfied and ONLY the governance
#     anchor clause can refuse it; that keeps this fixture discriminating for that one check.
git -C "$REPO" rm -q TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: hand-deleted tracker while the repo stays governed'
GOVERNED_SHA="$(git -C "$REPO" rev-parse HEAD)"
if python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$GOVERNED_SHA" >"$WORK/forge-a.out" 2>&1; then
  gov_fail "witness-uninstall recorded a commit that leaves the repository governed"
fi
grep -qF 'docs/workflow/tracker-config.yaml' "$WORK/forge-a.out" \
  || gov_fail "the non-ungoverning refusal did not name the governance anchor: $(cat "$WORK/forge-a.out")"
git -C "$REPO" reset --hard -q origin/main

# (b) A commit that ungoverns the repo but RE-ADDS a protected surface is not an uninstall either —
#     otherwise "delete the anchor" would be a universal key for writing machine-owned state.
git -C "$REPO" rm -q docs/workflow/tracker-config.yaml
printf 'archived: yes\n' > "$REPO/TRACKER-archive.md"
git -C "$REPO" add TRACKER-archive.md
git -C "$REPO" commit -qm 'test: ungoverns but plants a protected surface'
PLANT_SHA="$(git -C "$REPO" rev-parse HEAD)"
if python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$PLANT_SHA" >"$WORK/forge-b.out" 2>&1; then
  gov_fail "witness-uninstall recorded a commit that ADDS a protected machine surface"
fi
grep -qF 'TRACKER-archive.md' "$WORK/forge-b.out" \
  || gov_fail "the protected-addition refusal did not name the offending surface: $(cat "$WORK/forge-b.out")"
git -C "$REPO" reset --hard -q origin/main

# (c) The push-time gate re-derives the shape and never takes the witness's word: a hand-forged
#     witness entry naming an ordinary protected mutation buys nothing.
printf 'ticket: FORGED-WITNESS\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: mutation behind a forged witness'
FORGED_SHA="$(git -C "$REPO" rev-parse HEAD)"
python3 - "$(witness_path)" "$FORGED_SHA" <<'PY'
import json, sys
path, sha = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
doc["uninstall_commits"].append(sha)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
if git -C "$REPO" push origin main >"$WORK/forge-c.out" 2>&1; then
  gov_fail "a hand-forged witness entry published a protected mutation — the gate trusts the witness's word"
fi
grep -qF "$DENY_MARK" "$WORK/forge-c.out" \
  || gov_fail "the forged-witness refusal did not cite the protected surface: $(cat "$WORK/forge-c.out")"

# ── 5. FORWARD PATH: uninstall witnesses its own commit, and the next push just works ─────────────
# What commands/uninstall.md Phase 3c now does: commit, then hand the door that commit's own SHA. A
# fresh repo, so the tracked TRACKER.md is seeded the same way a real governed repo carries it.
new_governed_repo forward
make_uninstall_commit
FORWARD_SHA="$(git -C "$REPO" rev-parse HEAD)"
python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$FORWARD_SHA" >"$WORK/forward-witness.out" 2>&1 \
  || gov_fail "the uninstall door could not witness its own fresh removal commit: $(cat "$WORK/forward-witness.out")"
make_init_commit

# RIDE-ALONG CONTROL — the exemption is per COMMIT, not per range. A stray hand mutation sitting in
# the SAME outgoing range as a witnessed uninstall commit must still be refused; only the witnessed
# commit's own protected deletions are dropped from the gated set.
printf 'ticket: RIDE-ALONG\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: stray mutation riding a witnessed range' \
  || gov_fail "could not create the ride-along control commit"
if git -C "$REPO" push origin main >"$WORK/ride-along.out" 2>&1; then
  gov_fail "a witnessed uninstall commit in the range exempted an UNRELATED protected mutation"
fi
grep -qF "$DENY_MARK" "$WORK/ride-along.out" \
  || gov_fail "the ride-along refusal did not cite the protected surface: $(cat "$WORK/ride-along.out")"
git -C "$REPO" reset --hard -q HEAD~1

git -C "$REPO" push origin main >"$WORK/forward.out" 2>&1 \
  || gov_fail "a witnessed uninstall followed by a fresh init is still unpushable: $(cat "$WORK/forward.out")"
[ "$(git -C "$REPO" rev-parse origin/main)" = "$(git -C "$REPO" rev-parse HEAD)" ] \
  || gov_fail "the forward-path push reported success but the remote did not advance"

# ── 6. PARTIAL REMOVAL: dropping the anchor is not, by itself, an uninstall ───────────────────────
# The near-miss the shape checks alone could not tell from the real thing: a hand-made commit that
# deletes the governance anchor AND a protected surface, deletion-only, single parent — while leaving
# every other IDC footprint installed. It satisfies every structural clause, so ONLY the
# receipt-derived removal manifest can refuse it. Without that clause this commit is witnessed, and
# its protected deletion is then exempt at every push the repo ever makes.
new_governed_repo partial-legacy
git -C "$REPO" rm -q docs/workflow/tracker-config.yaml TRACKER.md
git -C "$REPO" commit -q -m 'chore: drop the tracker config and the tracker file'
PARTIAL_SHA="$(git -C "$REPO" rev-parse HEAD)"
if python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$PARTIAL_SHA" >"$WORK/partial.out" 2>&1; then
  gov_fail "witness-uninstall recorded a PARTIAL removal that left the rest of the IDC footprint installed"
fi
grep -qF 'WORKFLOW.md' "$WORK/partial.out" \
  || gov_fail "the partial-removal refusal did not name a surviving footprint: $(cat "$WORK/partial.out")"
# ...and the push gate refuses it independently. The re-init is what makes this assertion mean
# anything: while the anchor is gone the repo is ungoverned and the hook exits before gating at all,
# so a partial removal is only ever re-litigated once the repo is governed again — which is also why
# an `/idc:*` command is always available in the state that actually needs repairing.
make_init_commit
if git -C "$REPO" push origin main >"$WORK/partial-push.out" 2>&1; then
  gov_fail "a partial removal published without any witness at all"
fi
grep -qF "$DENY_MARK" "$WORK/partial-push.out" \
  || gov_fail "the partial-removal push refusal did not cite the protected surface: $(cat "$WORK/partial-push.out")"

# ── 7. RECEIPT-DERIVED MANIFEST: the modern install shape, both directions ────────────────────────
# The manifest is re-derived from the install receipt in the PARENT tree, so it must (a) refuse a
# removal that leaves a receipt-listed file behind and (b) still admit a real uninstall that KEPT an
# operator-customized file — which `/idc:uninstall` Phase 1 explicitly asks about and defaults to
# keeping. (b) is the false-refusal guard: over-tightening here would break every real uninstall of a
# repo whose operator ever edited a scaffold file.
new_receipt_repo receipt-manifest
git -C "$REPO" rm -q docs/workflow/tracker-config.yaml TRACKER.md
git -C "$REPO" commit -q -m 'chore: drop the anchor while the receipt-listed scaffold stays'
RECEIPT_PARTIAL_SHA="$(git -C "$REPO" rev-parse HEAD)"
if python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$RECEIPT_PARTIAL_SHA" >"$WORK/receipt-partial.out" 2>&1; then
  gov_fail "witness-uninstall recorded a partial removal in a RECEIPT-backed repo"
fi
grep -qF 'install receipt' "$WORK/receipt-partial.out" \
  || gov_fail "the receipt-backed refusal did not cite the receipt-derived manifest: $(cat "$WORK/receipt-partial.out")"
git -C "$REPO" reset --hard -q origin/main

# (b) An operator-customized file diverges from its stamped fingerprint, the operator keeps it at the
#     Phase-1 ask, and the uninstall commit removes everything else. This MUST still be witnessable.
printf '# IDC workflow — locally edited by the operator\n' > "$REPO/WORKFLOW.md"
git -C "$REPO" add WORKFLOW.md
git -C "$REPO" commit -q --no-verify -m 'test: operator customizes a scaffold file'
git -C "$REPO" rm -q TRACKER.md WORKFLOW-config.yaml docs/workflow/README.md \
  docs/workflow/tracker-config.yaml docs/workflow/install-receipt.yaml
printf '{"enabledPlugins":{}}\n' > "$REPO/.claude/settings.json"
git -C "$REPO" add .claude/settings.json
git -C "$REPO" commit -q -m 'idc: uninstall — remove IDC footprints (revert this commit to reinstate)' \
  || gov_fail "the customized-keep uninstall commit was refused at pre-commit"
KEEP_SHA="$(git -C "$REPO" rev-parse HEAD)"
python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$KEEP_SHA" >"$WORK/receipt-keep.out" 2>&1 \
  || gov_fail "the door refused a real uninstall that kept an operator-customized file: $(cat "$WORK/receipt-keep.out")"
git -C "$REPO" cat-file -e "$KEEP_SHA:WORKFLOW.md" \
  || gov_fail "the customized-keep fixture is not discriminating — WORKFLOW.md was removed after all"

# (c) The OTHER keep signal: `state: customized`, which /idc:update stamps for a file the operator
#     kept at its diff-and-ask. Its fingerprint is taken from those kept bytes, so it still MATCHES
#     and reads as `unchanged` by bytes alone — uninstall Phase 1 nonetheless asks and defaults to
#     keeping it. Requiring its removal would refuse a genuine uninstall of any repo whose operator
#     ever kept a scaffold file through an update.
SCAFFOLD_RECEIPT=0
new_governed_repo customized-state
python3 "$GOV_PLUGIN/scripts/idc_receipt_check.py" stamp --repo "$REPO" \
  --plugin-version 9.9.9 --out "$REPO/docs/workflow/install-receipt.yaml" \
  --customized WORKFLOW.md \
  WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml docs/workflow/README.md \
  >/dev/null 2>&1 || gov_fail "could not stamp a receipt marking WORKFLOW.md customized"
grep -q 'state: customized' "$REPO/docs/workflow/install-receipt.yaml" \
  || gov_fail "the customized-state fixture is not discriminating — no entry was stamped customized"
git -C "$REPO" add docs/workflow/install-receipt.yaml
git -C "$REPO" commit -q --no-verify -m 'test: stamp a receipt with a customized entry'
git -C "$REPO" rm -q TRACKER.md WORKFLOW-config.yaml docs/workflow/README.md \
  docs/workflow/tracker-config.yaml docs/workflow/install-receipt.yaml
printf '{"enabledPlugins":{}}\n' > "$REPO/.claude/settings.json"
git -C "$REPO" add .claude/settings.json
git -C "$REPO" commit -q -m 'idc: uninstall — remove IDC footprints (revert this commit to reinstate)' \
  || gov_fail "the customized-state uninstall commit was refused at pre-commit"
CUSTOM_SHA="$(git -C "$REPO" rev-parse HEAD)"
python3 "$GIT_GATE" witness-uninstall --repo "$REPO" --commit "$CUSTOM_SHA" >"$WORK/receipt-custom.out" 2>&1 \
  || gov_fail "the door refused a real uninstall that kept a state:customized file: $(cat "$WORK/receipt-custom.out")"
git -C "$REPO" cat-file -e "$CUSTOM_SHA:WORKFLOW.md" \
  || gov_fail "the customized-state fixture is not discriminating — WORKFLOW.md was removed after all"

# ── 8. LINKED WORKTREE: repository-wide evidence, resolved through the COMMON git dir ─────────────
# `/idc:uninstall` may run in a linked worktree while the push happens from the primary checkout.
# Under a per-worktree resolution the witness lands in that worktree's private git dir — invisible to
# the primary, and DELETED with the worktree — so the genuine uninstall commit is refused again.
new_governed_repo worktree-door
WT="$WORK/worktree-door-wt"
git -C "$REPO" worktree add -q -b teardown "$WT" >/dev/null 2>&1 \
  || gov_fail "could not create the linked worktree"
make_uninstall_commit "$WT"
WT_SHA="$(git -C "$WT" rev-parse HEAD)"
python3 "$GIT_GATE" witness-uninstall --repo "$WT" --commit "$WT_SHA" >"$WORK/wt-witness.out" 2>&1 \
  || gov_fail "the door refused a genuine uninstall commit made in a linked worktree: $(cat "$WORK/wt-witness.out")"
# The witness must be readable from the PRIMARY checkout, and must survive the worktree's removal.
git -C "$REPO" worktree remove --force "$WT" \
  || gov_fail "could not remove the linked worktree"
python3 - "$GOV_PLUGIN" "$REPO" "$WT_SHA" <<'PY' || gov_fail "the uninstall witness is not repository-wide evidence"
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import idc_path_gate as PG
repo, sha = sys.argv[2], sys.argv[3].lower()
seen = PG.read_uninstall_witness(repo)
if sha not in seen:
    print(f"the primary checkout cannot see the witness written from the linked worktree: {sorted(seen)}")
    raise SystemExit(1)
PY
# End to end: fast-forward the removal into main, re-govern with a fresh init, and push from primary.
git -C "$REPO" merge -q --ff-only teardown || gov_fail "could not fast-forward the removal into main"
make_init_commit
git -C "$REPO" push origin main >"$WORK/wt-push.out" 2>&1 \
  || gov_fail "an uninstall witnessed in a linked worktree is unpushable from the primary checkout: $(cat "$WORK/wt-push.out")"
[ "$(git -C "$REPO" rev-parse origin/main)" = "$(git -C "$REPO" rev-parse HEAD)" ] \
  || gov_fail "the linked-worktree push reported success but the remote did not advance"

# ── 9. RETENTION: every still-outgoing witness is kept, with no fixed ceiling ─────────────────────
# Pre-push inspects EVERY commit of the outgoing range, so a store that remembers only the last N
# makes a range carrying more than N genuine uninstall commits permanently unpushable — re-witnessing
# an evicted entry just evicts another one the same range needs. This drives the REAL storage door
# (`record_uninstall_commit`, real OIDs, the real witness file), which is where the ceiling lived.
new_governed_repo retention
python3 - "$GOV_PLUGIN" "$REPO" <<'PY' || gov_fail "the witness store evicts entries an outgoing range still needs"
import subprocess, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import idc_path_gate as PG
repo = sys.argv[2]
oids = []
for i in range(70):
    subprocess.run(["git", "-C", repo, "commit", "-q", "--no-verify", "--allow-empty",
                    "-m", f"test: witness fodder {i}"], check=True)
    oid = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                         capture_output=True, text=True, check=True).stdout.strip()
    oids.append(oid.lower())
    PG.record_uninstall_commit(repo, oid)
stored = PG.ordered_uninstall_witness(repo)
missing = [o for o in oids if o not in stored]
if missing:
    print(f"{len(missing)} of {len(oids)} witnesses were evicted (store holds {len(stored)})")
    raise SystemExit(1)
print(f"all {len(oids)} witnesses retained")
PY

echo "PASS: the sanctioned uninstall removal commit is publishable through a witnessed, shape-verified, receipt-bound door; partial removals, stray protected mutations, non-ungoverning commits, protected re-additions and forged witnesses are all still refused; the witness is repository-wide and uncapped"
