#!/bin/bash
# idc-assert-class: behavior
# engine-backend-failclosed.sh — governance scenario: backend resolution FAILS CLOSED on a
# tracker-config.yaml that exists but cannot be trusted (#153).
#
# resolve_backend used to wrap its config read in a broad `except → "filesystem"` (and the sweep's
# read_backend swallowed OSError): a repo whose docs/workflow/tracker-config.yaml was momentarily
# unreadable or corrupt was silently retargeted to the filesystem backend, so a github-configured
# repo's CREATE landed in TRACKER.md — a quiet misroute the operator only notices by absence.
# This pins the fix:
#   * NO config file at all (the genuinely pre-scaffold repo) → the filesystem default stands;
#   * a config that EXISTS but declares no usable backend (unknown token, or no `backend:` line)
#     → REFUSED, exit 2, NOTHING written to the board;
#   * a config that EXISTS but is unreadable (permissions) → REFUSED, exit 2, nothing written;
#   * a config that declares `backend: filesystem` → honored;
#   * an explicit --backend always wins (resolution is never consulted).
#
# Red-when-broken: restore the broad-except filesystem fallback in resolve_backend → the
# corrupt-config create exits 0 and its title lands in TRACKER.md → the refusal assert AND the
# board-unchanged assert FAIL.
#
# Usage: bash tests/smoke/governance/engine-backend-failclosed.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/../lib/fail-closed.sh"
gov_engine_env

# `eng` pins --backend filesystem, which BYPASSES resolution; this scenario exercises the RESOLVER,
# so the guarded invocations drive the engine WITHOUT --backend.
CFG_DIR="$REPO/docs/workflow"
CFG="$CFG_DIR/tracker-config.yaml"
mkdir -p "$CFG_DIR"

echo "== absent config: the pre-scaffold filesystem default stands (no refusal) =="
python3 "$ENGINE" --repo "$REPO" --tracker "$T" create-ticket --title 'no config: default create' >/dev/null \
  || fail "with NO tracker-config.yaml, the filesystem default must let the create proceed"
grep -q 'no config: default create' "$T" \
  || fail "the pre-scaffold default create did not land in TRACKER.md"
echo "  ok absent config keeps the filesystem default"

echo "== a config declaring an UNKNOWN backend is a refusal, never a filesystem retarget =="
printf 'backend: gremlin\n' > "$CFG"
assert_fail_closed \
  "unknown-backend config must refuse, not retarget" \
  "declares no usable backend" \
  -- python3 "$ENGINE" --repo "$REPO" --tracker "$T" create-ticket --title 'corrupt config: must not land' \
  -- python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" create-ticket --title 'explicit backend: control create'
[ "$FC_GUARDED_RC" -eq 2 ] \
  || fail "the unknown-backend refusal must exit 2 (the engine denial contract), got $FC_GUARDED_RC"
if grep -q 'corrupt config: must not land' "$T"; then
  fail "the refused create still landed in TRACKER.md — the silent filesystem retarget is back (#153)"
fi
grep -q 'explicit backend: control create' "$T" \
  || fail "the explicit --backend control create did not land (control is broken)"
echo "  ok unknown backend token refuses (exit 2) and writes nothing"

echo "== a config with NO backend line refuses the same way =="
printf 'project_number: 5\n' > "$CFG"
assert_fail_closed \
  "backend-less config must refuse, not retarget" \
  "declares no usable backend" \
  -- python3 "$ENGINE" --repo "$REPO" --tracker "$T" create-ticket --title 'backendless config: must not land' \
  -- python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" create-ticket --title 'backendless control create'
[ "$FC_GUARDED_RC" -eq 2 ] \
  || fail "the backend-less refusal must exit 2, got $FC_GUARDED_RC"
if grep -q 'backendless config: must not land' "$T"; then
  fail "the refused create (no backend line) still landed in TRACKER.md"
fi
echo "  ok missing backend line refuses (exit 2) and writes nothing"

echo "== an UNREADABLE config (present, permissions-denied) refuses, never guesses =="
printf 'backend: filesystem\n' > "$CFG"
chmod 000 "$CFG"
assert_fail_closed \
  "unreadable config must refuse, not retarget" \
  "exists but is unreadable" \
  -- python3 "$ENGINE" --repo "$REPO" --tracker "$T" create-ticket --title 'unreadable config: must not land' \
  -- python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" create-ticket --title 'unreadable-window control create'
[ "$FC_GUARDED_RC" -eq 2 ] \
  || fail "the unreadable-config refusal must exit 2, got $FC_GUARDED_RC"
chmod 644 "$CFG"
if grep -q 'unreadable config: must not land' "$T"; then
  fail "the refused create (unreadable config) still landed in TRACKER.md"
fi
echo "  ok unreadable config refuses (exit 2) and writes nothing"

echo "== a config declaring backend: filesystem is honored =="
printf 'backend: filesystem\n' > "$CFG"
python3 "$ENGINE" --repo "$REPO" --tracker "$T" create-ticket --title 'declared filesystem: create lands' >/dev/null \
  || fail "a valid 'backend: filesystem' config must let the create proceed"
grep -q 'declared filesystem: create lands' "$T" \
  || fail "the declared-filesystem create did not land in TRACKER.md"
echo "  ok declared filesystem backend is honored"

echo "PASS: backend resolution fails closed on a present-but-unreadable/corrupt tracker-config.yaml (refusal, exit 2, no board write) and keeps the filesystem default only for the genuinely pre-scaffold repo"
