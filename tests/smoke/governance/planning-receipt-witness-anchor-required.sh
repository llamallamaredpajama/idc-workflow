#!/bin/bash
# idc-assert-class: behavior
# planning-receipt-witness-anchor-required.sh — F25: write_receipt must SURFACE (not swallow) a witness
# anchor failure whenever the repo carries git metadata, so a receipt never persists witness-less while
# Plan reports success — which a later Build freeze would then refuse with a confusing "no witness".
#
# The "is anchoring required?" decision is FILESYSTEM-based (a `.git` entry present at the repo or an
# ancestor) rather than shelling `git`, so a repo whose git is broken/unavailable is NOT mistaken for a
# non-git repo. We simulate that with a BOGUS `.git` file: git metadata is present, but `git` cannot
# resolve a common dir, so anchoring must fail LOUDLY.
#
# Red-when-broken: the pre-fix code probed with `git rev-parse` (which fails on the bogus .git), decided
# "not a git repo", and swallowed the error — the receipt was written and write_receipt returned ok.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
PR="$PLUGIN/scripts/idc_planning_receipt.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$PR" ] || fail "missing planning-receipt helper: scripts/idc_planning_receipt.py"

run_write() {  # $1 = repo dir ; $2 = receipt path  -> prints RAISED | NO_RAISE (+ any error text)
  python3 - "$PLUGIN/scripts" "$1" "$2" <<'PY' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import idc_planning_receipt as PR
repo, receipt_path = sys.argv[2], sys.argv[3]
try:
    PR.write_receipt(repo, receipt_path, {"kind": "planning-application"})
    print("NO_RAISE")
except PR.ReceiptError as exc:
    print("RAISED: %s" % exc)
PY
}

# (A) git metadata PRESENT but unanchorable (a bogus `.git` file) -> write_receipt must RAISE.
BOGUS="$WORK/bogus"; mkdir -p "$BOGUS"
printf 'not a gitfile\n' > "$BOGUS/.git"
out="$(run_write "$BOGUS" "$BOGUS/receipt.json")"
printf '%s\n' "$out" | grep -q "RAISED" \
  || fail "write_receipt swallowed an anchor failure in a repo carrying git metadata (F25); got: $out"

# (B) a genuinely NON-git dir (no `.git` here or in an ancestor) legitimately skips witnessing -> ok.
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"
# Guard the assumption that no ancestor of the temp dir carries a `.git`, or (B) would false-fail.
anc="$PLAIN"; while [ "$anc" != "/" ]; do
  [ -e "$anc/.git" ] && fail "test precondition: an ancestor of the temp dir has a .git ($anc)"
  anc="$(dirname "$anc")"
done
out="$(run_write "$PLAIN" "$PLAIN/receipt.json")"
printf '%s\n' "$out" | grep -q "NO_RAISE" \
  || fail "write_receipt refused to write a receipt in a legitimate non-git governed repo; got: $out"
[ -f "$PLAIN/receipt.json" ] || fail "non-git write_receipt did not write the receipt file"

echo "PASS: write_receipt surfaces a witness anchor failure whenever git metadata is present, and skips only for a genuinely non-git repo"
