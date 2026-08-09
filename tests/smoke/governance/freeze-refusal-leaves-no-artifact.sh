#!/bin/bash
# idc-assert-class: behavior
# freeze-refusal-leaves-no-artifact.sh — #200: a REFUSED contract freeze must leave the repository
# exactly as it was.
#
# THE DEFECT. `freeze_contract` performed three writes in order:
#     atomic_write_json(out, doc)          # the contract file appears in the worktree
#     _record_witness("contract", out, doc)  # may REFUSE
#     _publish_live_contract(...)            # may REFUSE
# The file landed unconditionally and first, so a refusal at either later step exited nonzero while
# leaving a frozen-looking contract on disk that nothing vouched for. The #197 reproduction printed
# exactly that pair: `contract written? yes` alongside the exit-2 refusal. An artifact that exists
# without its proof is the ambiguity the whole witness chain exists to remove — and the next reader
# cannot tell a refused freeze from a successful one by looking at the worktree.
#
# THE FORCING FUNCTIONS are the two real refusal paths, driven deterministically:
#   (1) WITNESS step — corrupt the out-of-tree witness store so `_read_witnesses` returns None and
#       the recorder raises "the validation witness store is unreadable".
#   (2) PUBLISH step — replace the live-contract pointer path with a DIRECTORY so the pointer write
#       fails and `_publish_live_contract` refuses (a freeze whose scope cannot be published must
#       never succeed, so this refusal is by design).
#
# What is asserted after each refusal: nonzero exit, AND no contract file left behind, AND — for a
# re-freeze over an existing contract — the previous contract's bytes byte-for-byte intact, AND no
# witness entry left pointing at bytes that are gone.
#
# Red-when-broken: restore the write-then-witness order (drop the `_freeze_rollback` wrapper) and
# case 1's "no contract file survives a refused freeze" assertion fails — the file is on disk.
#
# Usage: bash tests/smoke/governance/freeze-refusal-leaves-no-artifact.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing validation-contract helper: scripts/idc_validation_contract.py"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/docs/workflow/build-validation"
cat > "$REPO/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' feature.txt
SH
chmod +x "$REPO/verify.sh"
printf 'old behavior\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt verify.sh
git -C "$REPO" commit -qm init

GITDIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)"
STORE="$GITDIR/idc-build-validation-witnesses.json"
LIVE="$GITDIR/idc-path-gate/live-contract.json"

# One freeze invocation against $1 (the --out path), with $2 as the label (default `build-red`).
# The label is parameterized ONLY so case 2 can re-freeze with a DIFFERENT document: a re-freeze that
# serialized to identical bytes would make its byte-exactness assertion pass vacuously, since a
# missing restore and a correct restore would be indistinguishable.
do_freeze() {
  python3 "$VC" freeze \
    --surface cli \
    --repo "$REPO" \
    --issue 7 \
    --pr 70 \
    --graph-node alpha \
    --graph-digest "$GRAPH_DIGEST" \
    --projection-digest "$PROJECTION_DIGEST" \
    --touch feature.txt \
    --off-limits docs/ \
    --verify 'bash verify.sh' \
    --baseline expected-red \
    --label "${2:-build-red}" \
    --out "$1"
}

# ── control: a HEALTHY freeze still writes the contract and its witness ───────────────────────────
# Without this the "no file survives" assertions below could pass for the wrong reason (a freeze that
# never writes anything at all).
GOOD="$REPO/docs/workflow/build-validation/good.json"
do_freeze "$GOOD" >/dev/null 2>"$WORK/good.err" \
  || fail "control: a healthy freeze was refused — the fixture is wrong, not the code: $(cat "$WORK/good.err")"
[ -f "$GOOD" ] || fail "control: a SUCCESSFUL freeze must leave its contract on disk at $GOOD"
[ -f "$STORE" ] || fail "control: a successful freeze must record a witness in $STORE"
grep -q 'build-validation/good.json' "$STORE" \
  || fail "control: the witness store does not name the contract the successful freeze wrote"
GOOD_SHA="$(shasum -a 256 "$GOOD" | awk '{print $1}')"

# ── case 1: a refusal at the WITNESS step leaves NO contract behind ───────────────────────────────
cp "$STORE" "$WORK/store.bak"
printf 'not json at all {{{\n' > "$STORE"
NEW="$REPO/docs/workflow/build-validation/refused.json"
if do_freeze "$NEW" >/dev/null 2>"$WORK/refused.err"; then
  fail "case 1: a freeze whose witness could not be recorded must FAIL, not succeed"
fi
grep -qi 'witness' "$WORK/refused.err" \
  || fail "case 1: the refusal must name the witness step (got: $(cat "$WORK/refused.err"))"
[ ! -e "$NEW" ] \
  || fail "case 1: THE #200 DEFECT — a refused freeze left an unwitnessed contract on disk at $NEW.
The write must be undone when any later step refuses; an artifact without its proof is exactly what
the witness chain exists to prevent."

# ── case 2: a refused RE-freeze must not damage the contract already on disk ──────────────────────
# The rollback restores prior BYTES, not a re-serialization: the existing witness keys on the file's
# sha256, so a byte-different restore would leave a valid contract its own witness rejects. The
# re-freeze carries a DIFFERENT label, so its document differs from the one on disk — without that,
# "the bytes are unchanged" would hold even if nothing were restored at all.
if do_freeze "$GOOD" build-red-v2 >/dev/null 2>"$WORK/refreeze.err"; then
  fail "case 2: a re-freeze whose witness could not be recorded must FAIL, not succeed"
fi
[ -f "$GOOD" ] || fail "case 2: a REFUSED re-freeze deleted the contract a previous successful freeze left behind"
[ "$GOOD_SHA" = "$(shasum -a 256 "$GOOD" | awk '{print $1}')" ] \
  || fail "case 2: a refused re-freeze rewrote the existing contract's bytes — the prior contract's
witness keys on its sha256, so anything but a byte-exact restore leaves it unverifiable"
grep -q '"label": "build-red"' "$GOOD" \
  || fail "case 2: the contract on disk is no longer the ORIGINAL document — the refused re-freeze's
label survived, so the rollback restored nothing"
grep -q 'build-red-v2' "$GOOD" \
  && fail "case 2: the REFUSED re-freeze's document is what is on disk — a refused freeze must not
publish its contract"
cp "$WORK/store.bak" "$STORE"

# ── case 3: a refusal at the PUBLISH step also leaves nothing behind, witness included ────────────
# `_publish_live_contract` refuses when the live-contract pointer cannot be written (a freeze whose
# mint scope cannot be published must never succeed). Making the pointer path a directory forces it.
rm -f "$LIVE"; mkdir -p "$LIVE"
PUB="$REPO/docs/workflow/build-validation/publish-refused.json"
if do_freeze "$PUB" >/dev/null 2>"$WORK/pub.err"; then
  fail "case 3: a freeze whose live contract could not be published must FAIL, not succeed"
fi
[ ! -e "$PUB" ] \
  || fail "case 3: a freeze refused at the PUBLISH step left a contract on disk at $PUB — the same
#200 defect one step later (the witness was already recorded, so the file is not even unwitnessed:
it is a fully-formed frozen gate whose freeze reported failure)"
python3 - "$STORE" <<'PY' || exit 1
import json, sys
store = json.load(open(sys.argv[1], encoding="utf-8"))
stale = [k for k in store if "publish-refused" in k]
if stale:
    print("FAIL: case 3 left witness entries %r for a contract that no longer exists — a rolled-back "
          "freeze must undo its witness too, or the store accumulates records pointing at nothing" % stale)
    raise SystemExit(1)
PY
rmdir "$LIVE"

# ── case 4: the door still works after all that — no rollback wedged the repo ─────────────────────
AFTER="$REPO/docs/workflow/build-validation/after.json"
do_freeze "$AFTER" >/dev/null 2>"$WORK/after.err" \
  || fail "case 4: a healthy freeze was refused AFTER the rollback paths ran — rollback wedged the
repository or the witness store: $(cat "$WORK/after.err")"
[ -f "$AFTER" ] || fail "case 4: the recovered freeze wrote no contract"

echo "PASS: a refused contract freeze leaves no artifact behind — no unwitnessed contract at the witness step, no published-gate contract at the publish step, an existing contract byte-intact, and the door still works afterwards"
