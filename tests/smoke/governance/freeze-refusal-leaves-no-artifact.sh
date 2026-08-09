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
# BOUND EVERY PROBE (phase-governance rule 5): a regression that deadlocks the witness-store lock
# would otherwise wedge the whole glob-driven lane instead of reddening. Exit 124 is RED, checked by
# `freeze_rc` below — never treated as a slow pass.
FREEZE_TIMEOUT_S="${FREEZE_TIMEOUT_S:-120}"
# `timeout` is NOT on stock macOS (coreutils provides it; tests/smoke/smoke-path-preflight.sh puts it
# on PATH for the suite). REFUSE to run rather than emit an unbounded verdict — without the bound a
# hung witness lock reads as a slow pass, which is exactly the failure this rule exists to prevent.
# Same hard-block idiom as governance/path-gate-runtime-failclosed.sh.
command -v timeout >/dev/null 2>&1 \
  || fail "BLOCKED: \`timeout\` is not on PATH. Every freeze probe here runs under an explicit bound so a
deadlocked witness-store lock REDS instead of looking like a slow pass. Install coreutils, or run via
tests/smoke/run-all.sh (which sources tests/smoke/smoke-path-preflight.sh), then re-run."
do_freeze() {
  timeout "$FREEZE_TIMEOUT_S" python3 "$VC" freeze \
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

# run_freeze <out> [label] <stderr-file> — run one probe, set FRC, and treat the bound as RED.
run_freeze() {
  local out="$1" label="$2" errf="$3"
  do_freeze "$out" "$label" >/dev/null 2>"$errf"
  FRC=$?
  [ "$FRC" -ne 124 ] \
    && return 0
  fail "the freeze probe for $out did not terminate within ${FREEZE_TIMEOUT_S}s — a neutered witness
lock or verifier HANGS instead of reddening, and a hang reads as a slow pass; treat it as RED"
}

# ── control: a HEALTHY freeze still writes the contract and its witness ───────────────────────────
# Without this the "no file survives" assertions below could pass for the wrong reason (a freeze that
# never writes anything at all).
GOOD="$REPO/docs/workflow/build-validation/good.json"
run_freeze "$GOOD" "" "$WORK/good.err"
[ "$FRC" -eq 0 ] \
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
run_freeze "$NEW" "" "$WORK/refused.err"
[ "$FRC" -ne 0 ] \
  || fail "case 1: a freeze whose witness could not be recorded must FAIL, not succeed"
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
run_freeze "$GOOD" build-red-v2 "$WORK/refreeze.err"
[ "$FRC" -ne 0 ] \
  || fail "case 2: a re-freeze whose witness could not be recorded must FAIL, not succeed"
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
run_freeze "$PUB" "" "$WORK/pub.err"
[ "$FRC" -ne 0 ] \
  || fail "case 3: a freeze whose live contract could not be published must FAIL, not succeed"
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
run_freeze "$AFTER" "" "$WORK/after.err"
[ "$FRC" -eq 0 ] \
  || fail "case 4: a healthy freeze was refused AFTER the rollback paths ran — rollback wedged the
repository or the witness store: $(cat "$WORK/after.err")"
[ -f "$AFTER" ] || fail "case 4: the recovered freeze wrote no contract"

# ── case 5: the LIVE-CONTRACT POINTER is part of the transaction ──────────────────────────────────
# `_publish_live_contract` writes the pointer FIRST and only then narrows the authorization, and only
# the narrowing can refuse. Rolling back the contract file while leaving the pointer aims it at a
# contract that no longer exists — `contract_scope()` then fail-closes for every later authorization
# mint until some unrelated freeze happens to repair it. Forced by making the AUTHORIZATION state
# unreadable while the pointer path itself stays writable.
AUTHDIR="$GITDIR/idc-path-gate"
mkdir -p "$AUTHDIR"
LIVE_BEFORE=""
[ -f "$LIVE" ] && LIVE_BEFORE="$(shasum -a 256 "$LIVE" | awk '{print $1}')"
# A directory where the narrowing step expects a readable authorization file.
rm -rf "$AUTHDIR/authorization.json"; mkdir -p "$AUTHDIR/authorization.json"
P5="$REPO/docs/workflow/build-validation/pointer.json"
run_freeze "$P5" "" "$WORK/p5.err"
if [ "$FRC" -ne 0 ]; then
  [ ! -e "$P5" ] \
    || fail "case 5: a refused freeze left its contract on disk at $P5"
  NOW=""; [ -f "$LIVE" ] && NOW="$(shasum -a 256 "$LIVE" | awk '{print $1}')"
  [ "$LIVE_BEFORE" = "$NOW" ] \
    || fail "case 5: the refused freeze left the LIVE-CONTRACT POINTER changed while rolling its
contract back — the pointer now names a contract that does not exist, and contract_scope() fail-closes
on that for every later authorization mint"
fi
rmdir "$AUTHDIR/authorization.json" 2>/dev/null || rm -rf "$AUTHDIR/authorization.json"

# ── case 6: rollback is COMPARE-AND-SWAP, never a blind restore ───────────────────────────────────
# Two linked worktrees can freeze the same LOGICAL path concurrently, so their witness entries share
# one `rel` key. If THIS freeze refuses after a SECOND one has recorded its own witness for that key,
# a blind restore of the snapshot deletes a witness belonging to a freeze that SUCCEEDED, leaving its
# contract unverifiable.
#
# Staged deterministically rather than raced: enter the real `_freeze_rollback`, let it take its
# snapshot, then replace the store entry from inside the context (standing in for the second freeze
# recording its own witness) and raise. Only a compare-and-swap leaves the second entry alone — note
# the snapshot and the planted entry DIFFER, which is what makes a blind restore observable.
timeout "$FREEZE_TIMEOUT_S" python3 - "$PLUGIN/scripts" "$REPO" "$GOOD" "$STORE" <<'PY'
import json, sys
scripts, repo, out, store_path = sys.argv[1:5]
sys.path.insert(0, scripts)
import idc_validation_contract as VC

OTHER = "OTHER-FREEZE-WITNESS"
_, common, rel = VC._repo_context(out)

def load():
    return json.load(open(store_path, encoding="utf-8"))

before = load()
assert rel in before, f"fixture: no witness entry for {rel} to contend over"

class Boom(Exception):
    pass

try:
    # owner names a digest that is NOT what will be in the store at rollback time.
    with VC._freeze_rollback(out, repo, {"digest": "THIS-FREEZE-WROTE-THIS"}):
        store = load()
        entry = dict(store[rel])
        entry["digest"] = OTHER
        entry["validator"] = OTHER
        store[rel] = entry
        json.dump(store, open(store_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
        raise Boom("forced refusal after another freeze recorded its witness")
except Boom:
    pass

after = load()
got = (after.get(rel) or {}).get("digest")
if got != OTHER:
    print("FAIL: case 6: the rollback CLOBBERED a witness entry it did not write (digest is now %r, "
          "expected the other freeze's %r). Two worktrees freezing the same logical path share one "
          "witness key; a blind restore by the REFUSING freeze destroys the witness of one that "
          "SUCCEEDED, leaving that contract unverifiable. Roll back only OUR entry." % (got, OTHER))
    raise SystemExit(1)
PY
rc=$?
[ "$rc" -eq 124 ] && fail "case 6 probe did not terminate within ${FREEZE_TIMEOUT_S}s (a hang is RED)"
[ "$rc" -eq 0 ] || exit 1
cp "$WORK/store.bak" "$STORE"

# ── case 7: a REFUSED first freeze into a not-yet-created output directory ────────────────────────
# `_repo_context` runs git WITH CWD at the artifact's parent. When that directory does not exist yet
# — the ordinary case for the first freeze in a freshly scaffolded repo — the lookup failed, the
# rollback silently lost its witness context, and a later refusal left a STALE WITNESS behind
# pointing at a contract it had just removed. `atomic_write_json` creates the directory on its way
# past, so a SUCCESSFUL freeze hides this entirely: only a refused one shows it, which is why this
# case forces a publish-step refusal rather than asserting a happy path.
FRESH="$REPO/docs/workflow/build-validation/nested/deeper/fresh.json"
[ ! -d "$(dirname "$FRESH")" ] || fail "case 7 fixture: the nested output dir must NOT exist yet"
rm -f "$LIVE"; mkdir -p "$LIVE"
run_freeze "$FRESH" fresh-dir "$WORK/fresh.err"
rmdir "$LIVE" 2>/dev/null || rm -rf "$LIVE"
[ "$FRC" -ne 0 ] \
  || fail "case 7: the freeze should have been refused at the publish step; the fixture is wrong"
[ ! -e "$FRESH" ] \
  || fail "case 7: a refused freeze into a fresh directory left its contract on disk at $FRESH"
python3 - "$STORE" <<'PY' || exit 1
import json, sys
store = json.load(open(sys.argv[1], encoding="utf-8"))
stale = [k for k in store if "nested/deeper/fresh.json" in k]
if stale:
    print("FAIL: case 7 left witness entries %r for a contract that was rolled back. The witness "
          "context must resolve from the nearest EXISTING ancestor — resolving it from a directory "
          "nothing has created yet fails, the rollback silently loses its store handle, and the "
          "stale entry survives." % stale)
    raise SystemExit(1)
PY

echo "PASS: a refused contract freeze leaves no artifact behind — no unwitnessed contract at the witness step, no published-gate contract at the publish step, an existing contract byte-intact, the live-contract pointer untouched, a concurrent worktree's witness never clobbered, and the door
still works afterwards — including a first freeze into a directory that does not exist yet"
