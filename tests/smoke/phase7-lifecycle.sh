#!/bin/bash
# idc-assert-class: behavior
# Phase 7 smoke — the install-receipt helper that /idc:uninstall and /idc:update consume.
# REAL round-trip of scripts/idc_receipt_check.py in a throwaway sandbox (no live GitHub):
# stamp writes an init.md-compatible receipt; verify classifies on-disk drift; an invalid
# receipt fails loud. This is the safety-critical fingerprint compare both lifecycle commands
# rely on ("only re-stamp / only delete what the receipt proves").
# Failing-test-first: fails until scripts/idc_receipt_check.py exists.
#
# Usage: bash tests/smoke/phase7-lifecycle.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_receipt_check.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "receipt helper not found at $HELPER (not implemented yet)"

RECEIPT="$SBX/docs/workflow/install-receipt.yaml"
mkdir -p "$SBX/docs/workflow" "$SBX/sub" "$SBX/.claude"

# IDC-owned scaffold files (the stampable footprint) ...
printf 'workflow contract\n'      > "$SBX/WORKFLOW.md"
printf 'backend: filesystem\n'    > "$SBX/docs/workflow/tracker-config.yaml"
printf 'nested\n'                 > "$SBX/sub/nested.txt"
# ... plus the three files the receipt must NEVER list (self / runtime / operator-owned).
printf 'idc-tracker-state:begin\n' > "$SBX/TRACKER.md"
printf '{"enabledPlugins":{}}\n'   > "$SBX/.claude/settings.json"
printf 'placeholder\n'             > "$RECEIPT"

# --- stamp: compute fingerprints + emit the receipt -----------------------------------------
python3 "$HELPER" stamp --repo "$SBX" --out "$RECEIPT" --written-by idc:update \
  --plugin-version 4.1.0 \
  WORKFLOW.md docs/workflow/tracker-config.yaml sub/nested.txt \
  TRACKER.md .claude/settings.json docs/workflow/install-receipt.yaml \
  || fail "stamp exited non-zero"

# receipt shape mirrors commands/init.md:137-151
grep -Eq '^receipt_version:[[:space:]]*2$'            "$RECEIPT" || fail "receipt_version not 2"
grep -Eq '^plugin_version:[[:space:]]*4\.1\.0$'       "$RECEIPT" || fail "plugin_version missing from v2 receipt"
grep -Eq '^fingerprint_method:[[:space:]]*sha256$'    "$RECEIPT" || fail "fingerprint_method not sha256"
grep -Eq '^written_by:[[:space:]]*idc:update$'        "$RECEIPT" || fail "written_by not recorded"
grep -q  'path: WORKFLOW.md'                          "$RECEIPT" || fail "WORKFLOW.md not stamped"
grep -q  'path: docs/workflow/tracker-config.yaml'    "$RECEIPT" || fail "tracker-config.yaml not stamped"
grep -q  'path: sub/nested.txt'                       "$RECEIPT" || fail "sub/nested.txt not stamped"
grep -q  'state: stamped'                             "$RECEIPT" || fail "state: stamped missing"
# fingerprints are 64 lowercase hex chars
grep -Eq 'fingerprint:[[:space:]]*[0-9a-f]{64}$'      "$RECEIPT" || fail "fingerprint not 64 lowercase hex"
# the three excluded files must NOT appear
grep -q  'path: TRACKER.md'                  "$RECEIPT" && fail "receipt must not list TRACKER.md (runtime footprint)"
grep -q  'path: .claude/settings.json'       "$RECEIPT" && fail "receipt must not list .claude/settings.json (operator-owned)"
grep -q  'path: docs/workflow/install-receipt.yaml' "$RECEIPT" && fail "receipt must not list itself"
# files are sorted by path (WORKFLOW.md < docs/... < sub/... by byte order)
paths="$(grep -oE 'path: .*' "$RECEIPT" | sed 's/path: //')"
[ "$paths" = "$(printf '%s\n' "$paths" | LC_ALL=C sort)" ] || fail "receipt files not sorted by path"

# --- verify: clean tree → everything unchanged ----------------------------------------------
out="$(python3 "$HELPER" verify --repo "$SBX")" || fail "verify exited non-zero on a clean tree"
echo "$out" | grep -Eq 'unchanged[[:space:]]+WORKFLOW.md'                       || fail "WORKFLOW.md not reported unchanged"
echo "$out" | grep -Eq 'unchanged[[:space:]]+docs/workflow/tracker-config.yaml' || fail "tracker-config.yaml not reported unchanged"
echo "$out" | grep -Eq 'unchanged[[:space:]]+sub/nested.txt'                    || fail "sub/nested.txt not reported unchanged"

# --- verify: a customized file → modified ---------------------------------------------------
printf 'operator edit\n' >> "$SBX/WORKFLOW.md"
out="$(python3 "$HELPER" verify --repo "$SBX")" || fail "verify exited non-zero with a modified file"
echo "$out" | grep -Eq 'modified[[:space:]]+WORKFLOW.md' || fail "edited WORKFLOW.md not reported modified"

# --- verify: a removed file → missing -------------------------------------------------------
rm -f "$SBX/sub/nested.txt"
out="$(python3 "$HELPER" verify --repo "$SBX")" || fail "verify exited non-zero with a missing file"
echo "$out" | grep -Eq 'missing[[:space:]]+sub/nested.txt' || fail "removed sub/nested.txt not reported missing"

# --- verify: an invalid receipt fails loud (never silently treats files as untouched) -------
printf 'receipt_version: 1\nfingerprint_method: md5\nfiles: not-a-list\n' > "$RECEIPT"
python3 "$HELPER" verify --repo "$SBX" >/dev/null 2>&1 && fail "verify must exit non-zero on an invalid receipt"

# --- verify: a missing receipt fails loud ---------------------------------------------------
rm -f "$RECEIPT"
python3 "$HELPER" verify --repo "$SBX" >/dev/null 2>&1 && fail "verify must exit non-zero on a missing receipt"

# --- stamp --customized: /idc:update marks operator-kept files so the NEXT update asks --------
# (resolves the considerations open-decision: kept customizations must never be silently re-stamped)
printf 'restored\n' > "$SBX/sub/nested.txt"   # re-create the file removed above
CUSTRECEIPT="$SBX/custom-receipt.yaml"
python3 "$HELPER" stamp --repo "$SBX" --out "$CUSTRECEIPT" --written-by idc:update \
  --plugin-version 4.1.0 \
  --customized WORKFLOW.md \
  WORKFLOW.md docs/workflow/tracker-config.yaml sub/nested.txt \
  || fail "stamp --customized exited non-zero"
# the customized file is marked state: customized; the others stay state: stamped
awk '/path: WORKFLOW.md/{f=1} f&&/state:/{print; exit}' "$CUSTRECEIPT" | grep -q 'customized' \
  || fail "--customized WORKFLOW.md did not record state: customized"
awk '/path: sub\/nested.txt/{f=1} f&&/state:/{print; exit}' "$CUSTRECEIPT" | grep -q 'stamped' \
  || fail "non-customized file should keep state: stamped"

echo "PASS: receipt helper stamps an init-compatible receipt + verify classifies drift (fail-loud)"
