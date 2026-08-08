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
write_scaffold() {
  mkdir -p "$REPO/docs/workflow" "$REPO/.claude"
  printf 'backend: filesystem\n'                          > "$REPO/docs/workflow/tracker-config.yaml"
  printf 'pathway_enforcement:\n  mode: controlled\n'     > "$REPO/WORKFLOW-config.yaml"
  printf '# IDC workflow\n'                               > "$REPO/WORKFLOW.md"
  printf '# workflow docs\n'                              > "$REPO/docs/workflow/README.md"
  printf 'ticket: demo\n'                                 > "$REPO/TRACKER.md"
  printf '{"enabledPlugins":{"idc@idc-workflow":true}}\n' > "$REPO/.claude/settings.json"
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
make_uninstall_commit() {
  git -C "$REPO" rm -q TRACKER.md WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/README.md docs/workflow/tracker-config.yaml
  printf '{"enabledPlugins":{}}\n' > "$REPO/.claude/settings.json"
  git -C "$REPO" add .claude/settings.json
  git -C "$REPO" commit -q -m 'idc: uninstall — remove IDC footprints (revert this commit to reinstate)' \
    || gov_fail "the uninstall removal commit was refused at pre-commit (it must land: the anchor is already gone)"
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

echo "PASS: the sanctioned uninstall removal commit is publishable through a witnessed, shape-verified door; stray protected mutations, non-ungoverning commits, protected re-additions and forged witnesses are all still refused"
