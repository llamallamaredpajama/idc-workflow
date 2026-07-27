#!/bin/bash
# idc-assert-class: behavior
# build-attempt-ceiling-consumed.sh — F21: the configured pathway_enforcement.attempt_ceiling must
# actually GOVERN behavior, not merely be serialized into the frozen contract. idc_validation_contract.py
# exposes the RESOLVED-ceiling reader the build playbook feeds to the risk gate's --attempt-ceiling and
# that the implementer reads from the frozen contract, so ONE config value drives (a) the reader, (b) the
# risk gate's recorded ceiling, and (c) the frozen contract's ceiling identically — a non-default operator
# ceiling is no longer inert.
#
# Red-when-broken: without the `attempt-ceiling` reader subcommand, step (1) errors on an unknown command;
# and if the risk gate / contract stopped agreeing with the reader, (2)/(3) fire.
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

# (2) the resolved value the build playbook feeds the risk gate becomes the risk gate's recorded ceiling.
got="$(rg_ceiling "$CEIL")"
[ "$got" = "5" ] || fail "risk gate did not record the resolved ceiling 5; got $got"

# (3) the SAME config value freezes into the contract with no explicit flag — one source, one value.
got="$(freeze_ceiling "$REPO/docs/workflow/build-validation/c5.json")"
[ "$got" = "5" ] || fail "frozen contract did not inherit the config ceiling 5; got $got"
[ "$got" = "$CEIL" ] || fail "contract ceiling ($got) disagrees with the reader ($CEIL)"

# (4) with no config value, the reader AND the risk gate fall back to the built-in default 3.
rm -f "$REPO/WORKFLOW-config.yaml"
CEIL="$(reader)"; [ "$CEIL" = "3" ] || fail "reader did not fall back to the built-in default 3; got $CEIL"
got="$(rg_ceiling "$CEIL")"; [ "$got" = "3" ] || fail "risk gate did not record the default ceiling 3; got $got"

echo "PASS: the configured attempt_ceiling flows from one resolved-ceiling source into the risk gate AND the frozen contract identically (default 3 when unset) — it governs behavior, it is not inert"
