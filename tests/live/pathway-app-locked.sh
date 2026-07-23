#!/bin/bash
# idc-assert-class: behavior
# pathway-app-locked.sh — LIVE App-locked lane (spec §2.1 `app-locked`, §2.2 ordinary-token gap).
#
# The `app-locked` profile makes a GitHub App the SOLE tracker writer: an ordinary write token must be
# DENIED a direct tracker mutation, while the App-sanctioned transaction succeeds. Proving that needs
# a real, operator-provisioned GitHub App (App id + installation id + private key) with tracker write
# and required-check-source rights on a sandbox board.
#
# CURRENT HONEST STATE: no such App exists. Creating one is a blocked-stop reserved to the operator
# (it provisions credentials and grants write scope). So this lane does NOT fabricate a pass: with no
# App configured it FAILS FAST with a precise provisioning ask and a non-zero exit. When the operator
# has provisioned the App and exported its (secret-free-in-repo) handles, the guarded assertions below
# run for real.
#
# This test NEVER reads, prints, or stores secret material. It only checks that the handle ENV VARS
# are present (by name) and delegates all credential handling to `gh`'s own App auth.
#
# Required env (operator-provisioned; values live in the operator's secret store, never in the repo):
#   IDC_PATHWAY_APP_ID              — the GitHub App id
#   IDC_PATHWAY_APP_INSTALLATION_ID — its installation id on the sandbox org/user
#   IDC_PATHWAY_APP_PRIVATE_KEY     — path to the App private-key PEM (a path, not the key)
#
# Usage: bash tests/live/pathway-app-locked.sh
set -uo pipefail
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"

SANDBOX="${IDC_LIVE_SANDBOX:-/Users/jeremy/dev/sandbox/ke-idc-test-repo-install}"

fail()    { printf 'FAIL: %s\n' "$1"; exit 1; }
skip()    { printf 'SKIP: %s\n' "$1"; exit 0; }
blocked() { printf 'BLOCKED (awaiting operator): %s\n' "$1"; exit 3; }

# ── sandbox-only hard guard (same as the integration lane) ────────────────────────────────────────
case "$SANDBOX" in
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-install|\
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-update|\
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun) ;;
  *) fail "REFUSING to run against $SANDBOX — this test may only touch a disposable sandbox repo
       (/Users/jeremy/dev/sandbox/ke-idc-test-repo-*), never a live or production repo" ;;
esac
[ -d "$SANDBOX" ]              || skip "sandbox $SANDBOX is not present on this machine"
command -v gh >/dev/null 2>&1  || skip "gh is not on PATH — this test needs the real CLI"

# ── App-credential presence check (names only — no value is ever read or echoed) ──────────────────
missing=""
for var in IDC_PATHWAY_APP_ID IDC_PATHWAY_APP_INSTALLATION_ID IDC_PATHWAY_APP_PRIVATE_KEY; do
  eval "val=\${$var:-}"
  [ -n "$val" ] || missing="$missing $var"
done
if [ -n "$missing" ]; then
  blocked "the app-locked lane requires an operator-provisioned GitHub App. Missing config:$missing.
       The operator must: (1) create a GitHub App with 'Projects: read & write' (tracker) and the
       right to be the required-check source; (2) install it on the sandbox
       (llamallamaredpajama/ke-idc-test-repo-*); (3) export IDC_PATHWAY_APP_ID,
       IDC_PATHWAY_APP_INSTALLATION_ID, and IDC_PATHWAY_APP_PRIVATE_KEY (a PEM path). No App exists
       yet, so this lane is intentionally BLOCKED, not passing — creating the App is an operator
       blocked-stop (it mints credentials and grants write scope)."
fi

# Only a path is referenced; the key contents are handed to gh, never read here.
[ -f "$IDC_PATHWAY_APP_PRIVATE_KEY" ] \
  || fail "IDC_PATHWAY_APP_PRIVATE_KEY does not point at a readable PEM file"

NWO="$( (cd "$SANDBOX" && gh repo view --json nameWithOwner --jq .nameWithOwner) 2>/dev/null )" \
  || skip "could not resolve $SANDBOX to OWNER/REPO"
case "$NWO" in
  llamallamaredpajama/ke-idc-test-repo-*) ;;
  *) fail "resolved repo $NWO is not a disposable sandbox — refusing to mutate it" ;;
esac

echo "== live app-locked lane — sandbox only ($NWO)"

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# From here down runs ONLY when the operator has provisioned the App. It is written so that, once the
# App exists, it proves both halves of §2.2 without any change:
#   (a) an ORDINARY token attempting a direct tracker mutation is DENIED;
#   (b) the APP-sanctioned transaction SUCCEEDS.
# It is not executed today because the credential check above blocks first. Do NOT fabricate either
# result — if a step cannot be proven live, it must fail, never print a green it did not earn.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
fail "app-locked live assertions are not yet implemented against a real App — provision the App and
       extend this lane to prove (a) ordinary-token tracker write is denied and (b) the App-sanctioned
       transaction succeeds. Until then this lane must not report success."
