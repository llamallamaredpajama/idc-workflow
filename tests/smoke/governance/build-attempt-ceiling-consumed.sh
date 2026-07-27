#!/bin/bash
# idc-assert-class: behavior
# build-attempt-ceiling-consumed.sh — F21: ONE resolved-ceiling source threads consistently through the
# build machinery. idc_validation_contract.py exposes the RESOLVED-ceiling reader the build playbook
# feeds to the risk gate's --attempt-ceiling and that the implementer reads back from the frozen
# contract, so a single config value produces (a) the reader's output, (b) the value the risk gate
# RECORDS when fed it, and (c) the frozen contract's attempt_ceiling — all identically, from one source.
#
# HONEST SCOPE (F24): this proves the value THREADS consistently; it does not prove the ceiling bounds
# anything on its own. The risk gate merely ECHOES attempt_ceiling into its output (after a >0 check) —
# leg (2) is therefore a threading/echo assertion, not a "governance" one. The genuinely behavioral leg
# is config -> frozen-contract default (leg (3) here; also covered by build-attempt-ceiling-config.sh).
# The actual retry-loop consumer that BOUNDS the loop lives in agents/idc-implementer.md prose, which is
# outside hermetic smoke coverage — no test here claims to exercise it.
#
# Red-when-broken: without the `attempt-ceiling` reader subcommand, step (1) errors on an unknown command;
# and if the risk gate / contract stopped THREADING the reader's value, (2)/(3) fire.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
RG="$PLUGIN/scripts/idc_validation_risk_gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$VC" ] || fail "missing build validation-contract helper"
[ -f "$RG" ] || fail "missing risk-gate helper"

HEX='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
GRAPH_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
PROJ_DIGEST='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
mkdir -p "$REPO/src/allowed" "$REPO/docs/workflow/build-validation"
printf '#!/bin/bash\nexit 0\n' > "$REPO/verify.sh"; chmod +x "$REPO/verify.sh"
printf 'pathway_enforcement:\n  mode: controlled\n  attempt_ceiling: 5\n' > "$REPO/WORKFLOW-config.yaml"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

reader() { python3 "$VC" attempt-ceiling --repo "$REPO"; }
rg_ceiling() {  # the ceiling the risk gate records when fed the resolved value $1
  python3 "$RG" evaluate --validator-digest "$HEX" --frozen-gate-digest "$HEX" \
    --attempt-ceiling "$1" --touch src/allowed/ --off-limits docs/ \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["attempt_ceiling"])'
}
freeze_ceiling() {  # the attempt_ceiling the freeze records when NO --attempt-ceiling flag is given
  local out="$1"
  python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
    --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJ_DIGEST" \
    --touch src/allowed/ --off-limits docs/ --verify 'bash verify.sh' \
    --surface cli --evidence-kind pane-capture --baseline expected-green --label c --out "$out" >/dev/null \
    || fail "freeze without --attempt-ceiling failed"
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["attempt_ceiling"])' "$out"
}

# (1) config sets 5 -> the reader resolves 5.
CEIL="$(reader)" || fail "the attempt-ceiling reader subcommand is missing"
[ "$CEIL" = "5" ] || fail "reader did not resolve the config ceiling 5; got $CEIL"

# (2) THREADING/ECHO (not governance): the resolved value the build playbook feeds the risk gate is the
#     value the risk gate records verbatim. The risk gate echoes attempt_ceiling into its output after a
#     >0 check — it does not itself loop or bound on it — so this asserts the wiring threads the value,
#     nothing more. The retry-loop consumer is idc-implementer.md prose, outside smoke.
got="$(rg_ceiling "$CEIL")"
[ "$got" = "5" ] || fail "risk gate did not record (echo) the resolved ceiling 5; got $got"

# (3) the SAME config value freezes into the contract with no explicit flag — one source, one value.
got="$(freeze_ceiling "$REPO/docs/workflow/build-validation/c5.json")"
[ "$got" = "5" ] || fail "frozen contract did not inherit the config ceiling 5; got $got"
[ "$got" = "$CEIL" ] || fail "contract ceiling ($got) disagrees with the reader ($CEIL)"

# (4) with no config value, the reader AND the risk gate fall back to the built-in default 3.
rm -f "$REPO/WORKFLOW-config.yaml"
CEIL="$(reader)"; [ "$CEIL" = "3" ] || fail "reader did not fall back to the built-in default 3; got $CEIL"
got="$(rg_ceiling "$CEIL")"; [ "$got" = "3" ] || fail "risk gate did not record the default ceiling 3; got $got"

echo "PASS: one resolved-ceiling source threads identically into the reader, the risk gate's recorded (echoed) value, and the frozen contract (default 3 when unset); the retry-loop consumer that BOUNDS the loop is idc-implementer.md prose, outside smoke — not claimed here"
