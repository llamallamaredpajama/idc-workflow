#!/bin/bash
# idc-assert-class: behavior
# build-risk-gate-binding.sh — F64: the risk-gate verdict is DIGEST-BOUND into the frozen contract.
#
# The risk gate derives requiredness from the touch set IT IS GIVEN (F59, proven by
# plan-risk-gate-authoritative.sh) — but `--touch` there is a plain flag, so nothing in that process
# stopped a builder from judging a NARROWED set (or never running the gate) and freezing the real
# one. The freeze door closes that: `idc_validation_contract.py freeze` re-derives risk from the
# facts being FROZEN and
#   * REFUSES a risk-deriving freeze with no `--risk-gate-result`;
#   * digest-verifies the supplied result (`result_digest`, stamped by the gate itself);
#   * REFUSES a result judged on a different touch set or baseline than the frozen ones;
#   * REFUSES a result missing anything fixed code derives from the frozen facts;
#   * freezes the passing verdict INSIDE the contract, under `contract_digest`.
#
# Red-when-broken: make `_risk_gate_binding` return None unconditionally and (B) freezes without a
# result while (C)'s contract carries no risk_gate block; drop the digest compare and (D) accepts a
# tampered result; drop the touch/baseline equality and (E)/(F) accept mismatched results; drop the
# derived-subset check and (G) accepts a forged all-clear.
#
# Usage: bash tests/smoke/governance/build-risk-gate-binding.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
RG="$PLUGIN/scripts/idc_validation_risk_gate.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$VC" ] || fail "missing helper: scripts/idc_validation_contract.py"
[ -f "$RG" ] || fail "missing helper: scripts/idc_validation_risk_gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init

python3 - "$PLUGIN/scripts" "$REPO" <<'PY' || fail "F64 binding assertions failed (see above)"
import json, os, sys
scripts, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_validation_contract as VC
import idc_validation_risk_gate as RG

os.chdir(repo)
COMMON = dict(repo=repo, issue=1, pr=2, graph_node="n1",
              graph_digest="a" * 64, projection_digest="b" * 64, planning_receipt=None,
              off_limits=["docs/"], verify_commands=None, baseline="expected-green",
              label="t", surface="none", evidence_kind=None, skip_reason="docs only",
              attempt_ceiling=3)
RISKY = ["scripts/hooks/x.py"]        # derives security-sensitive-path in fixed code
BENIGN = ["src/allowed/"]

def freeze(touch, out, result=None):
    return VC.freeze_contract(touch=touch, out=out, risk_gate_result=result, **COMMON)

def must_refuse(label, needle, **kw):
    try:
        freeze(**kw)
    except VC.ValidationError as exc:
        if needle not in str(exc):
            print("%s: refused, but not on the arm under test (wanted %r): %s" % (label, needle, exc))
            sys.exit(1)
        return str(exc)
    print("%s: the freeze was NOT refused" % label)
    sys.exit(1)

# (A) CONTROL — a benign touch set freezes with no result and records risk_gate: null. This is what
#     keeps the binding from being a blanket everything-needs-a-scenario change.
doc = freeze(BENIGN, "c-benign.json")
if doc["risk_gate"] is not None:
    print("A: a benign touch set recorded a risk_gate block: %r" % (doc["risk_gate"],)); sys.exit(1)
print("A ok: benign touch freezes with risk_gate: null")

# (B) a RISK-DERIVING touch set with NO result REFUSES, naming the derived risk and the flag.
msg = must_refuse("B", "no risk-gate result was supplied", touch=RISKY, out="c-none.json")
if "security-sensitive-path" not in msg or "--risk-gate-result" not in msg:
    print("B: the refusal must name the derived risk and the flag; got: %s" % msg); sys.exit(1)
print("B ok: risk-deriving freeze without a result refuses")

# A REAL gate result for the risky touch set (scenario satisfied), used by C-F below.
scen = {"candidates": [{"promise": "p", "failure_mode": "f",
                        "observable_evidence": "o", "executable_check": "c"}],
        "skeptic_results": [{"question": RG.SKEPTIC_QUESTION, "majority_defeated": False}]}
json.dump(scen, open("scen.json", "w"))
res = RG.evaluate(validator_digest="c" * 64, frozen_gate_digest="d" * 64, attempt_ceiling=3,
                  touch=list(RISKY), off_limits=["docs/"], risk_inputs=[],
                  scenario_path="scen.json", baseline="expected-green")
if res.get("result_digest") != RG.result_digest(res):
    print("the gate's own stamp does not verify against its recompute"); sys.exit(1)
json.dump(res, open("risk.json", "w"), sort_keys=True)

# (C) the bound freeze: the contract embeds the verdict UNDER contract_digest, and editing the
#     embedded block after issuance is caught by the ordinary digest check.
doc = freeze(RISKY, "c-bound.json", result="risk.json")
rg = doc["risk_gate"]
if not rg or rg["result_digest"] != res["result_digest"]:
    print("C: the contract does not embed the verified result digest: %r" % (rg,)); sys.exit(1)
if "security-sensitive-path" not in rg["risk_inputs"] or rg["required"] is not True:
    print("C: the embedded verdict is wrong: %r" % (rg,)); sys.exit(1)
VC.load_contract("c-bound.json")                     # round-trips clean
frozen = json.load(open("c-bound.json"))
frozen["risk_gate"]["risk_inputs"] = []              # post-issuance edit of the embedded verdict
json.dump(frozen, open("c-edited.json", "w"))
try:
    VC.load_contract("c-edited.json")
    print("C: an edited embedded risk_gate block loaded clean — the block is not digest-bound"); sys.exit(1)
except VC.ValidationError as exc:
    if "digest mismatch" not in str(exc):
        print("C: wrong refusal for the edited block: %s" % exc); sys.exit(1)
print("C ok: the verdict freezes into the contract and is sealed by contract_digest")

# (D) a TAMPERED result file (digest no longer matches its content) REFUSES.
bad = dict(res); bad["risk_inputs"] = []; bad["required"] = False
json.dump(bad, open("risk-tampered.json", "w"), sort_keys=True)
must_refuse("D", "digest mismatch", touch=RISKY, out="c-tampered.json", result="risk-tampered.json")
print("D ok: a tampered result refuses")

# (E) a result judged on a DIFFERENT touch set (here: a superset) REFUSES — equality, not subset.
other = RG.evaluate(validator_digest="c" * 64, frozen_gate_digest="d" * 64, attempt_ceiling=3,
                    touch=["src/other.py"] + list(RISKY), off_limits=["docs/"], risk_inputs=[],
                    scenario_path="scen.json", baseline="expected-green")
json.dump(other, open("risk-other.json", "w"), sort_keys=True)
must_refuse("E", "DIFFERENT touch set", touch=RISKY, out="c-other.json", result="risk-other.json")
print("E ok: a result judged on different facts refuses")

# (F) a BASELINE mismatch REFUSES (judged unknown, frozen expected-green).
unk = RG.evaluate(validator_digest="c" * 64, frozen_gate_digest="d" * 64, attempt_ceiling=3,
                  touch=list(RISKY), off_limits=["docs/"], risk_inputs=[],
                  scenario_path="scen.json", baseline="unknown")
json.dump(unk, open("risk-unknown.json", "w"), sort_keys=True)
must_refuse("F", "baseline", touch=RISKY, out="c-unknown.json", result="risk-unknown.json")
print("F ok: a baseline mismatch refuses")

# (G) a FORGED all-clear — right touch set, right baseline, self-consistent digest, but risk_inputs
#     emptied — REFUSES on the derived-subset arm. The digest is tamper-evidence, not authentication,
#     so this arm is what stops a hand-built result from blessing a risky freeze.
forged = {"required": False, "risk_inputs": [], "declared_risk_inputs": [],
          "derived_risk_inputs": [], "baseline": "expected-green",
          "touch": list(RISKY), "off_limits": ["docs/"],
          "validator_digest": "c" * 64, "frozen_gate_digest": "d" * 64,
          "attempt_ceiling": 3, "selected": [], "discarded_indexes": [],
          "skeptic_question": RG.SKEPTIC_QUESTION, "derivation": {}}
forged["result_digest"] = RG.result_digest(forged)
json.dump(forged, open("risk-forged.json", "w"), sort_keys=True)
must_refuse("G", "fixed code derives", touch=RISKY, out="c-forged.json", result="risk-forged.json")
print("G ok: a forged all-clear refuses on the derived-subset arm")
PY

# (H) the CLI door is wired: `freeze --risk-gate-result` round-trips end to end (so the binding is
#     reachable from the playbooks, not only from the library).
python3 - "$PLUGIN/scripts" "$WORK" <<'PY' || fail "H fixture: could not build the CLI-case result"
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_validation_risk_gate as RG
scen = {"candidates": [{"promise": "p", "failure_mode": "f",
                        "observable_evidence": "o", "executable_check": "c"}],
        "skeptic_results": [{"question": RG.SKEPTIC_QUESTION, "majority_defeated": False}]}
json.dump(scen, open(sys.argv[2] + "/cli-scen.json", "w"))
res = RG.evaluate(validator_digest="c" * 64, frozen_gate_digest="d" * 64, attempt_ceiling=3,
                  touch=["scripts/hooks/x.py"], off_limits=["docs/"], risk_inputs=[],
                  scenario_path=sys.argv[2] + "/cli-scen.json", baseline="expected-green")
json.dump(res, open(sys.argv[2] + "/cli-risk.json", "w"), sort_keys=True)
PY
( cd "$REPO" && python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 2 --graph-node n1 \
    --graph-digest "$(printf 'a%.0s' $(seq 64))" --projection-digest "$(printf 'b%.0s' $(seq 64))" \
    --touch scripts/hooks/x.py --off-limits docs/ \
    --surface none --skip-reason "docs only" --baseline expected-green --label t \
    --attempt-ceiling 3 --risk-gate-result "$WORK/cli-risk.json" --out "$REPO/cli-contract.json" ) \
  || fail "H: the CLI freeze with --risk-gate-result refused a correctly bound result"
grep -Fq '"result_digest"' "$REPO/cli-contract.json" \
  || fail "H: the CLI-frozen contract does not embed the risk-gate result digest"

echo "PASS: the risk-gate verdict is digest-bound into the frozen contract (F64) — a benign touch set freezes with risk_gate: null, a risk-deriving freeze REFUSES without a result, a bound result is digest-verified and sealed under contract_digest (post-issuance edits are caught), and a tampered result, a result judged on a different touch set or baseline, and a forged all-clear each refuse — reachable through the CLI's --risk-gate-result"
