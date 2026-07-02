#!/bin/bash
# idc-assert-class: behavior
# Phase 1 (brownfield) smoke — /idc:init's requirements-doc scan SCANS + CONFIRMS, never INVENTS.
# Two real surfaces are checked:
#   (a) the shipped scan helper (scripts/idc_brownfield_scan.py) against throwaway repos:
#       - a BROWNFIELD repo (a PRD + a stack manifest) is classified brownfield, its TRD-gating
#         default is `on`, and the found PRD path is REPORTED — and the scan writes NOTHING
#         (the no-invent constraint, asserted OBSERVABLY: the repo's full file set + per-file
#         checksums are byte-identical before and after the scan);
#       - a GREENFIELD repo (empty) is classified greenfield with TRD-gating default `off`.
#   (b) command-prose invariants on commands/init.md — init runs the scan, confirms found docs
#       (offering scaffold-from-repo / from-scratch / a mix), states the no-invent HARD constraint,
#       sets the type-aware TRD-gating default, and writes no starter PRD/spec for greenfield.
# Failing-test-first: fails until scripts/idc_brownfield_scan.py exists.
#
# Usage: bash tests/smoke/phase1-brownfield-scan.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCAN="$PLUGIN/scripts/idc_brownfield_scan.py"
INIT_MD="$PLUGIN/commands/init.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
has()  { grep -qiE "$2" "$1"; }   # file, regex

[ -f "$SCAN" ] || fail "brownfield scan helper not found at $SCAN (not implemented yet)"

# A repo's full file set + per-file content checksum — changes if ANY file is added, removed, or
# modified. This is how we assert the read-only / no-invent contract observably.
snapshot() { (cd "$1" && find . -type f | sort | while IFS= read -r p; do
  printf '%s:' "$p"; cksum <"$p" | cut -d' ' -f1; done); }

# ---- (a) brownfield repo: classified + PRD reported + NOTHING written --------------
BROWN="$WORK/brown"
mkdir -p "$BROWN/docs/prd" "$BROWN/src"
printf '# Existing PRD\n\nThis repo already has a PRD.\n' > "$BROWN/docs/prd/prd.md"
printf '{ "name": "legacy-app" }\n' > "$BROWN/package.json"

pre="$(snapshot "$BROWN")"
out="$(python3 "$SCAN" "$BROWN")" || fail "scan helper failed on the brownfield repo"
post="$(snapshot "$BROWN")"

# NO-INVENT (observable): the scanned repo is byte-identical before and after — the scan authored,
# overwrote, or fabricated nothing. Break it (give the scanner a write path) and this fails red.
[ "$pre" = "$post" ] || fail "the scan MUST NOT write/invent any file — repo changed during scan:
$(diff <(printf '%s\n' "$pre") <(printf '%s\n' "$post"))"

echo "$out" | grep -qx "type: brownfield"          || fail "brownfield repo not classified brownfield: $out"
echo "$out" | grep -qx "gating-trd-default: on"     || fail "brownfield TRD-gating default must be on: $out"
# the found PRD is REPORTED back (so init can confirm it with the operator, not overwrite it)
echo "$out" | grep -qx "prd: docs/prd/prd.md"       || fail "scan must REPORT the existing PRD it found: $out"

# ---- greenfield repo: classified greenfield, TRD gate off, no docs found -----------
GREEN="$WORK/green"; ( mkdir -p "$GREEN" && cd "$GREEN" && git init -q 2>/dev/null )
out="$(python3 "$SCAN" "$GREEN")" || fail "scan helper failed on the greenfield repo"
echo "$out" | grep -qx "type: greenfield"           || fail "empty repo not classified greenfield: $out"
echo "$out" | grep -qx "gating-trd-default: off"     || fail "greenfield TRD-gating default must be off: $out"
echo "$out" | grep -qx "prd: <none>"                || fail "greenfield repo must report no PRD: $out"

# ---- (b) command-prose invariants on commands/init.md ------------------------------
[ -f "$INIT_MD" ] || fail "commands/init.md missing"
grep -qF 'idc_brownfield_scan.py' "$INIT_MD" \
  || fail "init.md must run the brownfield scan helper (scripts/idc_brownfield_scan.py)"
has "$INIT_MD" 'never invent' \
  || fail "init.md must state the no-invent HARD constraint (confirm what exists, never invent)"
has "$INIT_MD" 'scaffold-from-repo' \
  || fail "init.md must offer scaffold-from-repo when it finds existing requirements docs"
has "$INIT_MD" 'from-scratch' \
  || fail "init.md must offer a from-scratch option for the requirements docs"
grep -qF 'TRD_GATING_DEFAULT' "$INIT_MD" \
  || fail "init.md must set the type-aware TRD-gating default from the scan"
has "$INIT_MD" 'no\*{0,2} starter PRD/spec' \
  || fail "init.md must keep the greenfield invariant: no starter PRD/spec written at init"

echo "PASS: init's brownfield scan reports existing docs + sets the type-aware gate, and never invents"
