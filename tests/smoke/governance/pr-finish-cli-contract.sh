#!/bin/bash
# pr-finish-cli-contract.sh — the documented idc_pr_finish.py invocations must PARSE (Task 3, Fix 1).
#
# The brief + shipped Plan/Recirculator prose invoke the finisher subcommand-FIRST:
#   idc_pr_finish.py autonomous   --repo R --pr N --kind planning
#   idc_pr_finish.py requirements --repo R --pr N --gate G --pointer P
# If the shared options live only on the PARENT parser, argparse exits 2 with
# `unrecognized arguments: --repo` — and under the hardened interlock (which now DENIES a raw
# `gh pr merge` during an active command) Plan/Recirculation could not finish at all.
#
# This executes BOTH forms far enough to prove argparse ACCEPTS them: a stub `gh` on PATH fails the
# first PR/issue read, so each run fail-closes at its gh call (exit 2) — but NOT with an argparse
# "unrecognized arguments" / "usage:" error. Red-when-broken: move the shared opts back to the parent
# parser → argparse rejects `--repo` after the subcommand → this FAILs.
#
# Usage: bash tests/smoke/governance/pr-finish-cli-contract.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

FIN="$GOV_PLUGIN/scripts/idc_pr_finish.py"
[ -f "$FIN" ] || gov_fail "idc_pr_finish.py not found at $FIN"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# A stub `gh` that always fails: guarantees each run reaches (and stops at) its FIRST gh call, so a
# clean result here means argparse accepted the args and control reached cmd_* — never a live network
# op against a real repo.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "stub gh: no such object" >&2\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"

run_finish() { OUT="$(PATH="$WORK/bin:$PATH" python3 "$FIN" "$@" 2>&1)"; RC=$?; }

assert_parsed() {  # $1 = label; reads $OUT/$RC
  printf '%s' "$OUT" | grep -q 'unrecognized arguments' \
    && gov_fail "($1) argparse REJECTED the documented invocation: $OUT"
  printf '%s' "$OUT" | grep -qi 'usage:.*idc_pr_finish' \
    && gov_fail "($1) argparse emitted a usage error (bad subcommand/option wiring): $OUT"
  [ "$RC" -eq 2 ] || gov_fail "($1) expected fail-closed exit 2 at the gh call, got $RC: $OUT"
  printf '%s' "$OUT" | grep -q 'idc-pr-finish:' \
    || gov_fail "($1) did not reach the finisher's own gh failure (argparse likely intercepted): $OUT"
  echo "  ok ($1) parses + reaches finisher logic (fail-closed at the stubbed gh)"
}

echo "== the documented autonomous invocation parses and reaches finisher logic =="
run_finish autonomous --repo "$WORK" --pr 12 --kind planning
assert_parsed "autonomous --repo … --pr … --kind planning"

echo "== the documented requirements invocation parses and reaches finisher logic =="
run_finish requirements --repo "$WORK" --pr 12 --gate 5 --pointer 7
assert_parsed "requirements --repo … --pr … --gate … --pointer …"

echo "PASS: both documented idc_pr_finish.py invocations parse (shared opts on the subparsers) and reach finisher logic"
