#!/bin/bash
# idc-assert-class: behavior
# Phase 7 (update staleness guard) smoke — fix/update-data-config-preserve.
#
# /idc:update Phase 0 must halt when the running command body is OLDER than the newest plugin
# version in Claude Code's version-keyed cache (a mid-session update leaves the session running
# stale logic against a newer install — the trap that re-introduces just-fixed bugs). This tests
# scripts/idc_plugin_freshness.py against a fabricated cache tree. Hermetic; no GitHub, no network.
#
# Usage: bash tests/smoke/phase7-update-staleness-guard.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_plugin_freshness.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "freshness helper not found at $HELPER"

# Fabricate a version-keyed cache: .../idc/{2.1.3,2.1.4}, each with a manifest stating its version.
CACHE="$SBX/cache/idc-workflow/idc"
for v in 2.1.3 2.1.4 2.1.10; do
  mkdir -p "$CACHE/$v/.claude-plugin"
  printf '{\n  "name": "idc",\n  "version": "%s"\n}\n' "$v" > "$CACHE/$v/.claude-plugin/plugin.json"
done

verdict() { python3 "$HELPER" --plugin-root "$1"; }

# 1. Running an OLD version while newer ones are cached -> stale, exit 4.
out="$(verdict "$CACHE/2.1.3")"; rc=$?
[ "$rc" -eq 4 ] || fail "running 2.1.3 with 2.1.4/2.1.10 cached must exit 4 (stale); got $rc — [$out]"
printf '%s' "$out" | grep -q 'verdict stale' || fail "expected 'verdict stale'; got [$out]"
# 2.1.10 must sort ABOVE 2.1.3 numerically (not lexically) as installed-max.
printf '%s' "$out" | grep -q 'installed-max 2.1.10' || fail "version compare must be numeric (max 2.1.10); got [$out]"

# 2. Running the NEWEST cached version -> current, exit 0.
out="$(verdict "$CACHE/2.1.10")"; rc=$?
[ "$rc" -eq 0 ] || fail "running the newest cached version must exit 0 (current); got $rc — [$out]"
printf '%s' "$out" | grep -q 'verdict current' || fail "expected 'verdict current'; got [$out]"

# 3. A --plugin-dir-style dev root (no version siblings) -> unknown, exit 0 (never block dev runs).
DEV="$SBX/devcheckout"; mkdir -p "$DEV/.claude-plugin"
printf '{\n  "name": "idc",\n  "version": "9.9.9"\n}\n' > "$DEV/.claude-plugin/plugin.json"
out="$(verdict "$DEV")"; rc=$?
[ "$rc" -eq 0 ] || fail "a dev checkout with no cache siblings must exit 0 (unknown); got $rc — [$out]"
printf '%s' "$out" | grep -q 'verdict unknown' || fail "expected 'verdict unknown' for a dev root; got [$out]"

# 4. The real shipped helper resolves its own version from this checkout's manifest (smoke that
#    read_version works against a real manifest); verdict is current/unknown, never stale/error.
out="$(verdict "$PLUGIN")"; rc=$?
[ "$rc" -ne 2 ] || fail "freshness helper usage error against the real plugin root: [$out]"

# 5. Bind freshness to a repo's install receipt (--repo/--json): the running plugin version must
#    not be older than the repo's own receipt-recorded plugin_version, not just the cache siblings.
for v in 3.3.0 4.0.0; do
  mkdir -p "$CACHE/$v/.claude-plugin"
  printf '{\n  "name": "idc",\n  "version": "%s"\n}\n' "$v" \
    > "$CACHE/$v/.claude-plugin/plugin.json"
done

write_receipt() {
  mkdir -p "$1/docs/workflow"
  printf 'receipt_version: 2\nplugin_version: %s\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' "$2" \
    > "$1/docs/workflow/install-receipt.yaml"
}

# assert_field <json> <field-name-in-quotes-with-colon-value> <label> — exact key:value match,
# not a substring grep, so a legacy display collapse leaking into --json can never pass silently.
assert_field() {
  printf '%s' "$1" | grep -q "\"$2\"" || fail "$3 — got: $1"
}

REPO="$SBX/repo"
write_receipt "$REPO" 4.0.0

out="$(python3 "$HELPER" --plugin-root "$CACHE/3.3.0" --repo "$REPO" --json)"; rc=$?
[ "$rc" -eq 4 ] || fail "3.3.0 runtime against a 4.0.0 repo must be stale"
assert_field "$out" 'verdict": "stale' "3.3.0-vs-4.0.0-receipt verdict must be stale"
assert_field "$out" 'reason_code": "running-behind-receipt' "receipt mismatch reason missing"

write_receipt "$REPO" 4.1.0
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$REPO" --json)"; rc=$?
[ "$rc" -eq 4 ] || fail "4.0.0 runtime against a 4.1.0 repo must be stale"
assert_field "$out" 'verdict": "stale' "4.0.0-vs-4.1.0-receipt verdict must be stale"
assert_field "$out" 'reason_code": "running-behind-receipt' "4.0.0-vs-4.1.0-receipt reason_code must be running-behind-receipt"

write_receipt "$REPO" 4.0.0
out="$(python3 "$HELPER" --plugin-root "$DEV" --repo "$REPO" --json)"; rc=$?
[ "$rc" -eq 0 ] || fail "newer --plugin-dir checkout must be allowed"
printf '%s' "$out" | grep -q '"load_mode": "plugin-dir"' || fail "dev load not identified: $out"
assert_field "$out" 'verdict": "development-current' "a newer --plugin-dir dev load's verdict must be development-current, not the legacy-display collapse"
assert_field "$out" 'reason_code": "plugin-dir-current' "dev load reason_code must be plugin-dir-current"

write_receipt "$REPO" 9.9.10
out="$(python3 "$HELPER" --plugin-root "$DEV" --repo "$REPO" --json)"; rc=$?
[ "$rc" -eq 4 ] || fail "a dev checkout older than the repo receipt must still be refused"
assert_field "$out" 'verdict": "stale' "a dev checkout older than the repo receipt must verdict stale"
assert_field "$out" 'reason_code": "running-behind-receipt' "a dev checkout older than the repo receipt must reason_code running-behind-receipt"

# 6. Running the newest cached version against a receipt that requires no more than that -> the
#    plain "current" verdict, asserted exactly (not just "not stale") so a legacy-display leak
#    into --json (which prints "unknown" for anything but current/stale) can never pass silently.
write_receipt "$REPO" 4.0.0
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$REPO" --json)"; rc=$?
[ "$rc" -eq 0 ] || fail "running the newest cached + receipt-satisfying version must exit 0; got $rc — [$out]"
assert_field "$out" 'verdict": "current' "running the newest cached + receipt-satisfying version must verdict current"
assert_field "$out" 'reason_code": "versions-current' "that case's reason_code must be versions-current"

# 7. A receipt_version: 2 receipt with NO plugin_version is an INVALID RECEIPT, not "no
#    requirement recorded" — it must exit 2 (never fail open to 0/stale). This is Finding 1: the
#    v1-vs-v2 distinction must be read from receipt_version BEFORE deciding, so a broken v2
#    receipt can never silently behave like a pre-guard v1 one.
BADREPO="$SBX/bad-repo"
mkdir -p "$BADREPO/docs/workflow"
printf 'receipt_version: 2\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
  > "$BADREPO/docs/workflow/install-receipt.yaml"
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$BADREPO" --json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "a v2 receipt missing plugin_version must exit 2 (invalid receipt), not fail open; got $rc — [$out]"

# 8. A receipt_version: 2 receipt with a NON-SEMVER plugin_version is equally invalid -> exit 2.
printf 'receipt_version: 2\nplugin_version: not-semver\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
  > "$BADREPO/docs/workflow/install-receipt.yaml"
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$BADREPO" --json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "a v2 receipt with a non-semver plugin_version must exit 2 (invalid receipt); got $rc — [$out]"

# 8b. A v2 receipt with a NUMERIC BUT MALFORMED plugin_version — not exactly X.Y.Z (three
#     components) — is equally invalid -> exit 2. The version pattern must match the writer rule
#     in idc_receipt_check.py exactly, not any loose dotted-numeric run (round-2 review Finding 1).
for bad in 4.1 4.1.0.0; do
  printf 'receipt_version: 2\nplugin_version: %s\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' "$bad" \
    > "$BADREPO/docs/workflow/install-receipt.yaml"
  out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$BADREPO" --json 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] || fail "a v2 receipt with plugin_version=$bad (not exactly X.Y.Z) must exit 2 (invalid receipt); got $rc — [$out]"
done

# 9. A well-formed v1 receipt (receipt_version: 1, no plugin_version) is NOT invalid — it's the
#    documented pre-guard migration path: required_version stays None and the load is allowed.
#    Distinct from the intentionally-INVALID v1 receipt exercised in phase7-lifecycle.sh (bad
#    fingerprint_method + non-list files:) — this one is well-formed and must parse clean.
V1REPO="$SBX/v1-repo"
mkdir -p "$V1REPO/docs/workflow"
printf 'receipt_version: 1\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
  > "$V1REPO/docs/workflow/install-receipt.yaml"
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$V1REPO" --json)"; rc=$?
[ "$rc" -eq 0 ] || fail "a well-formed v1 receipt must not block (required_version=None); got $rc — [$out]"
printf '%s' "$out" | grep -q '"required_version": null' \
  || fail "a v1 receipt must yield required_version=null (no requirement recorded yet) — got: $out"
assert_field "$out" 'verdict": "current' "v1 receipt + the newest cached running version should still verdict current"
assert_field "$out" 'reason_code": "versions-current' "v1 receipt case reason_code must be versions-current"

# 10. A receipt_version NOT in {1, 2} — e.g. 3 — is an INVALID receipt, not "no requirement
#     recorded". The ONLY legitimate "allowed migration -> required_version=None" cases are no
#     receipt at all and a valid receipt_version: 1 (round-2 review Finding 2). Must exit 2, never
#     fail open to 0/stale.
printf 'receipt_version: 3\nplugin_version: 4.0.0\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
  > "$BADREPO/docs/workflow/install-receipt.yaml"
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$BADREPO" --json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "a receipt_version: 3 receipt must exit 2 (invalid receipt), not fail open; got $rc — [$out]"

# 11. A receipt file that exists but has NO receipt_version field at all must be equally invalid
#     -> exit 2 (must not silently fall through to the v1/no-receipt migration path).
printf 'fingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
  > "$BADREPO/docs/workflow/install-receipt.yaml"
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$BADREPO" --json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "a receipt with no receipt_version field must exit 2 (invalid receipt); got $rc — [$out]"

# 12. A receipt_version key present but BLANK (empty value) must also be exit 2, not treated as v1.
printf 'receipt_version:\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' \
  > "$BADREPO/docs/workflow/install-receipt.yaml"
out="$(python3 "$HELPER" --plugin-root "$CACHE/4.0.0" --repo "$BADREPO" --json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "a blank receipt_version must exit 2 (invalid receipt); got $rc — [$out]"

echo "PASS: idc_plugin_freshness.py flags a stale-session load (numeric compare) and never blocks dev/unknown"
