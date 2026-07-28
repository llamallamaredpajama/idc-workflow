#!/bin/bash
# idc-assert-class: behavior
# build-attempt-ceiling-config.sh — F11: a frozen Build contract defaults its attempt_ceiling from the
# repo's WORKFLOW-config.yaml (`pathway_enforcement.attempt_ceiling`) when the CLI flag is omitted, and
# an explicit --attempt-ceiling still overrides it. The spec (§2.1) says the config owns the ceiling.
#
# Red-when-broken: with the function + CLI hard-coding 3, freezing without --attempt-ceiling in a repo
# whose config sets 5 records 3, and the (A) assertion fires.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$VC" ] || fail "missing build validation-contract helper"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
mkdir -p "$REPO/src/allowed" "$REPO/docs/workflow/build-validation"
cat > "$REPO/verify.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$REPO/verify.sh"
# A non-default attempt_ceiling in the repo config the spec says owns it.
printf 'pathway_enforcement:\n  mode: controlled\n  attempt_ceiling: 5\n' > "$REPO/WORKFLOW-config.yaml"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

freeze() {
  local out="$1"; shift
  python3 "$VC" freeze \
    --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
    --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
    --touch src/allowed/ --off-limits docs/ --verify 'bash verify.sh' \
    --surface cli --evidence-kind pane-capture \
    --baseline expected-green --label ceiling --out "$out" "$@" >/dev/null
}
ceiling_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["attempt_ceiling"])' "$1"; }

# (A) No CLI flag -> the contract inherits the config's 5.
freeze "$REPO/docs/workflow/build-validation/from-config.json" \
  || fail "freeze without --attempt-ceiling failed"
got="$(ceiling_of "$REPO/docs/workflow/build-validation/from-config.json")"
[ "$got" = "5" ] \
  || fail "attempt_ceiling did not default from the repo config (pathway_enforcement.attempt_ceiling: 5); got $got"

# (B) An explicit flag still overrides the config.
freeze "$REPO/docs/workflow/build-validation/override.json" --attempt-ceiling 7 \
  || fail "freeze with --attempt-ceiling 7 failed"
got="$(ceiling_of "$REPO/docs/workflow/build-validation/override.json")"
[ "$got" = "7" ] \
  || fail "explicit --attempt-ceiling 7 did not override the config; got $got"

# (C) No flag and no config value -> the built-in default (3).
rm -f "$REPO/WORKFLOW-config.yaml"
freeze "$REPO/docs/workflow/build-validation/default.json" \
  || fail "freeze without config or flag failed"
got="$(ceiling_of "$REPO/docs/workflow/build-validation/default.json")"
[ "$got" = "3" ] \
  || fail "attempt_ceiling did not fall back to the built-in default 3 with no config/flag; got $got"

# (D) F23 — a DECLARED but malformed ceiling (a typo / non-positive) errs to the safe default 3 AND
# surfaces a warning to the operator, instead of being silently swallowed like an ABSENT value (which
# would be asymmetric with the F10 mode hardening in this same effort). Red-when-broken: before the fix
# a malformed value returned None indistinguishably from absent, so no warning was ever emitted.
printf 'pathway_enforcement:\n  mode: controlled\n  attempt_ceiling: banana\n' > "$REPO/WORKFLOW-config.yaml"
err="$WORK/ceil-warn.txt"
out="$(python3 "$VC" attempt-ceiling --repo "$REPO" 2>"$err")" \
  || fail "attempt-ceiling reader errored on a malformed config value (must err to the default, not crash)"
[ "$out" = "3" ] \
  || fail "malformed attempt_ceiling did not err to the safe built-in default 3; got $out"
grep -qiE 'attempt_ceiling|positive integer|malformed' "$err" \
  || fail "malformed attempt_ceiling was swallowed silently — no operator warning (F23); stderr: $(cat "$err")"

# A WELL-FORMED value emits NO warning (the signal is specific to malformed, not noise on every read).
printf 'pathway_enforcement:\n  mode: controlled\n  attempt_ceiling: 5\n' > "$REPO/WORKFLOW-config.yaml"
err2="$WORK/ceil-nowarn.txt"
out="$(python3 "$VC" attempt-ceiling --repo "$REPO" 2>"$err2")" || fail "reader errored on a valid config"
[ "$out" = "5" ] || fail "valid attempt_ceiling 5 not resolved; got $out"
grep -qiE 'WARNING' "$err2" \
  && fail "a valid attempt_ceiling wrongly emitted a warning; stderr: $(cat "$err2")"

echo "PASS: build contract attempt_ceiling defaults from pathway_enforcement.attempt_ceiling, honors an explicit override, falls back to 3, and warns (not swallows) on a declared-but-malformed value"
