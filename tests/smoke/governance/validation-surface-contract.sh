#!/bin/bash
# idc-assert-class: behavior
# validation-surface-contract.sh — U6 surface/evidence validation-contract typing.
# Proves:
#   (a) a frozen contract records the declared surface/evidence pairing and the execution receipt carries
#       bounded/redacted declared evidence of that exact kind;
#   (b) a mismatched surface/evidence pair is refused BY THE PAIRING CHECK;
#   (c) `surface:none` without a one-line skip_reason is refused;
#   (d) an impossible evidence kind for the declared commands is refused;
#   (e) a WITNESSED execution receipt whose surface/evidence kind drifts from the frozen contract is
#       refused at receipt-mint time, and a drifted build receipt is refused at verify time;
#   (f) an omitted `--surface` is refused (an undeclared surface is not a declaration);
#   (g) an all-static CLI gate is refused — including the piped `cat file | grep -q x` shape — while a
#       static precondition guarding a real drive, and a real drive whose NAME contains "lint", are not;
#   (h) credential-shaped material a gate prints to STDOUT is redacted in both committed artifacts,
#       using the committed-evidence profile (vendor prefixes AND bare opaque runs in the REAL base64
#       alphabet, `+` and `/` included), inside a 400-character bound proven against a gate that
#       prints past it;
#   (h2) a private key whose `-----END …-----` footer never arrived is redacted out of both committed
#       artifacts, header and body — the shared two-delimiter rule cannot see that shape;
#   (i) a gate that never terminates is refused on a timeout rather than waited on;
#   (j) the 17 KB capture bound holds: the redaction pass never walks an unbounded capture, says so
#       with its marker, and is lossless at the stored excerpt width.
#
# RED-WHEN-BROKEN NOTES — the two cases below that were previously INERT and why:
#   * (B) used `--surface api --evidence-kind pane-capture` with `--verify 'bash verify.sh'`. With the
#     PAIRING check deleted the freeze still refused — for a different reason (`bash verify.sh` cannot
#     produce the table-derived `response-body`) — and the old loose grep `surface|evidence|pair`
#     matched that other refusal, so the case passed with its guard gone. It now picks a mismatch whose
#     TABLE-DERIVED kind the commands CAN produce, greps the specific sentence, and proves no contract
#     was written.
#   * (F) forged the execution receipt at a NEW path, so the witness store refused it before the drift
#     check ran, and the assertion's grep matched the word "surface" inside the fixture's own filename.
#     It now forges IN PLACE, re-records the machine witness, keeps the forgery self-consistent so it
#     survives `load_execution`, and greps the exact drift sentence.
#   * (A) asserted the 400-character evidence bound against a fixture gate that PRINTS NOTHING, so it
#     held with the clip deleted. The assertion moved to (G), whose gate prints well past the bound.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper: surface/evidence typing is still absent"
[ -f "$BR" ] || fail "missing build receipt helper: declared-evidence drift is still accepted"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

setup_repo() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
  mkdir -p "$repo/src/allowed" \
           "$repo/docs/workflow/build-validation" \
           "$repo/docs/workflow/build-validation-executions" \
           "$repo/docs/workflow/build-receipts" \
           "$repo/docs/workflow/code-reviews"
  cat > "$repo/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
  chmod +x "$repo/verify.sh"
  printf 'old behavior\n' > "$repo/src/allowed/feature.txt"
  git -C "$repo" add verify.sh src/allowed/feature.txt
  git -C "$repo" commit -qm init
}

write_verdict_from_execution() {
  local execution="$1" verdict="$2"
  python3 - "$execution" "$verdict" <<'PY'
import json, sys
exec_path, verdict_path = sys.argv[1:3]
receipt = json.load(open(exec_path, encoding='utf-8'))
verdict = {
    'verdict': 'PASS',
    'issue': receipt['issue'],
    'pr': receipt['pr'],
    'head': receipt['head'],
    'diff_digest': receipt['diff_digest'],
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  python3 "$CHECK" "$verdict" >/dev/null 2>&1 || fail "review verdict validator rejected the generated validation-surface verdict"
}

# (A) Good CLI contract + bounded declared evidence carried into the execution receipt.
REPO_GOOD="$WORK/repo-good"
setup_repo "$REPO_GOOD"
CONTRACT_GOOD="$REPO_GOOD/docs/workflow/build-validation/cli.json"
EXEC_GOOD="$REPO_GOOD/docs/workflow/build-validation-executions/cli.json"
VERDICT_GOOD="$REPO_GOOD/docs/workflow/code-reviews/2026-07-23-pr-401-cli.json"
RECEIPT_GOOD="$REPO_GOOD/docs/workflow/build-receipts/cli.json"
python3 "$VC" freeze \
  --repo "$REPO_GOOD" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label cli-surface \
  --out "$CONTRACT_GOOD" >/dev/null \
  || fail "a valid cli/pane-capture contract was rejected"
printf 'new behavior\n' > "$REPO_GOOD/src/allowed/feature.txt"
git -C "$REPO_GOOD" add src/allowed/feature.txt
git -C "$REPO_GOOD" commit -qm 'implement cli behavior'
python3 "$VC" run --repo "$REPO_GOOD" --contract "$CONTRACT_GOOD" --out "$EXEC_GOOD" >/dev/null \
  || fail "could not execute the frozen cli validation contract"
python3 - "$CONTRACT_GOOD" "$EXEC_GOOD" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
execution = json.load(open(sys.argv[2], encoding='utf-8'))
if contract.get('surface') != 'cli' or contract.get('evidence_kind') != 'pane-capture':
    raise SystemExit(f"FAIL: frozen contract did not record cli/pane-capture, got {contract.get('surface')!r} / {contract.get('evidence_kind')!r}")
if execution.get('surface') != 'cli' or execution.get('evidence_kind') != 'pane-capture':
    raise SystemExit(f"FAIL: execution receipt did not carry cli/pane-capture, got {execution.get('surface')!r} / {execution.get('evidence_kind')!r}")
declared = execution.get('declared_evidence') or {}
if declared.get('kind') != 'pane-capture':
    raise SystemExit(f"FAIL: execution receipt missing declared evidence kind, got {declared}")
records = declared.get('records') or []
if not records:
    raise SystemExit(f"FAIL: execution receipt must carry bounded evidence records, got {declared}")
# NO 400-character assertion here: this fixture's gate prints nothing, so the bound would hold with
# the clip deleted and the check would be inert. The bound is proven in case (G), against a gate that
# really does print past it.
print('ok: cli validation contract recorded its declared surface/evidence kind and bounded evidence')
PY
write_verdict_from_execution "$EXEC_GOOD" "$VERDICT_GOOD"
python3 "$BR" write \
  --repo "$REPO_GOOD" \
  --contract "$CONTRACT_GOOD" \
  --execution "$EXEC_GOOD" \
  --verdict "$VERDICT_GOOD" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT_GOOD" >/dev/null \
  || fail "the matching cli implementation receipt was rejected"

# (B) A mismatched surface/evidence pair is refused BY THE PAIRING CHECK — isolated.
# `gui` derives `screenshot-or-recording` from the table, and `playwright test` CAN produce that kind,
# so the producibility check is satisfied and the ONLY thing standing between this freeze and a
# silently normalized contract is the pairing equality. With that equality removed the freeze SUCCEEDS
# and rewrites `pane-capture` to `screenshot-or-recording` behind the author's back — which is why the
# case asserts the specific sentence AND that nothing was written to disk.
REPO_PAIR="$WORK/repo-pair"
setup_repo "$REPO_PAIR"
PAIR_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/pair-mismatch.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'playwright test' \
  --surface gui \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label pair-mismatch \
  --out "$PAIR_CONTRACT" 2>&1)" \
  && fail "a mismatched surface/evidence pair was accepted (silently normalized to the table kind)"
printf '%s\n' "$out" | grep -qF 'pair mismatch' \
  || fail "the refusal must come from the surface/evidence PAIRING check ('pair mismatch'), not from some other rule; got: $out"
[ ! -e "$PAIR_CONTRACT" ] \
  || fail "a refused surface/evidence pairing still wrote a frozen contract to disk at $PAIR_CONTRACT"

# (B2) An omitted `--surface` is refused — an undeclared surface is not a declaration. Before this,
# omitting the flag silently stored the ticket as cli/pane-capture, which made the whole
# surface-typing scheme opt-in (declaring `gui` was strictly more work than saying nothing).
NOSURF_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/no-surface.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --baseline expected-red \
  --label no-surface \
  --out "$NOSURF_CONTRACT" 2>&1)" \
  && fail "a freeze with NO --surface was accepted and silently defaulted"
printf '%s\n' "$out" | grep -qF -- '--surface' \
  || fail "the missing-surface refusal must name --surface; got: $out"
[ ! -e "$NOSURF_CONTRACT" ] \
  || fail "a freeze with no declared surface still wrote a frozen contract at $NOSURF_CONTRACT"

# (B2b) The SAME requirement, reached through the library rather than the CLI. `_validation_surface` is
# the single enforcement point — it also runs on every re-read of a frozen contract, where no CLI is
# involved — so this case proves the rule holds for an in-process caller too, and it is the case that
# goes red when that one enforcement point is neutered. (Deliberately NOT backed by an argparse
# `required=True`: a second copy of the rule in front of the first is a guard no test can be red for,
# because removing it only lets the library refuse the same input one step later.)
python3 - "$PLUGIN/scripts" "$REPO_PAIR" "$GRAPH_DIGEST" "$PROJECTION_DIGEST" "$REPO_PAIR/docs/workflow/build-validation/lib-no-surface.json" <<'PY' || exit 1
import sys
scripts, repo, graph, projection, out = sys.argv[1:6]
sys.path.insert(0, scripts)
import idc_validation_contract as VC
try:
    VC.freeze_contract(repo=repo, issue=1, pr=401, graph_node='alpha', graph_digest=graph,
                       projection_digest=projection, planning_receipt=None,
                       touch=['src/allowed/'], off_limits=['docs/'],
                       verify_commands=['bash verify.sh'], baseline='expected-red',
                       label='lib-no-surface', out=out, surface=None)
except VC.ValidationError as exc:
    if 'declare its surface explicitly' not in str(exc):
        raise SystemExit(f"FAIL: the library refused a surface-less contract for the wrong reason: {exc}")
else:
    raise SystemExit(
        "FAIL: idc_validation_contract.freeze_contract accepted a contract with NO declared surface "
        "and silently defaulted one — the library layer of the requirement is gone")
import os
if os.path.exists(out):
    raise SystemExit(f"FAIL: a surface-less freeze still wrote {out}")
try:
    VC.freeze_contract(repo=repo, issue=1, pr=401, graph_node='alpha', graph_digest=graph,
                       projection_digest=projection, planning_receipt=None,
                       touch=['src/allowed/'], off_limits=['docs/'],
                       verify_commands=['bash verify.sh'], baseline='expected-red',
                       label='lib-bad-surface', out=out, surface='terminal')
except VC.ValidationError as exc:
    if 'surface must be one of' not in str(exc):
        raise SystemExit(f"FAIL: an off-table surface was refused for the wrong reason: {exc}")
else:
    raise SystemExit(
        "FAIL: idc_validation_contract.freeze_contract accepted a surface that is not in the fixed "
        "surface->evidence table")
print('ok: the library refuses a surface-less contract, and an off-table surface, on its own')
PY

# (B2c) ONE surface->evidence table, not two agreeing copies. There used to be a literal dict in
# idc_validation_contract.py AND another in idc_schema_check.py, with nothing asserting they matched:
# the registry resolver typed handles from the schema-check copy while freeze used its own, so a
# one-sided edit produced a registry-LEGAL handle that froze an ILLEGAL contract. An equality test only
# DETECTS that drift; sharing one object makes it impossible, so this asserts identity, not equality.
python3 - "$PLUGIN/scripts" <<'PY' || exit 1
import sys
sys.path.insert(0, sys.argv[1])
import idc_validation_contract as VC
import idc_schema_check as SC
import idc_verification_handles as VH
if VC.SURFACE_EVIDENCE_TABLE is not SC.SURFACE_EVIDENCE_TABLE:
    raise SystemExit(
        "FAIL: idc_validation_contract.py no longer shares idc_schema_check.py's SURFACE_EVIDENCE_TABLE "
        "— a second copy has been reintroduced and the two can drift apart unnoticed")
if VH.SC.SURFACE_EVIDENCE_TABLE is not VC.SURFACE_EVIDENCE_TABLE:
    raise SystemExit(
        "FAIL: the verification-handle resolver types handles from a DIFFERENT table object than the "
        "one contract freezing uses — a registry-legal handle can freeze an illegal contract")
print('ok: exactly one surface->evidence table backs freezing, schema-checking, and handle resolution')
PY

# (B3) An ALL-STATIC cli gate is refused — the review engine's prose rule, as a machine rule. Every
# declared command is a static check with nothing exercising the observable end-state, so an inert
# deliverable would sail through this gate.
STATIC_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/all-static.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'test -f src/allowed/feature.txt && false' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label all-static \
  --out "$STATIC_CONTRACT" 2>&1)" \
  && fail "an ALL-STATIC cli verification surface was accepted"
printf '%s\n' "$out" | grep -qF 'all-static verification surface refused' \
  || fail "the all-static refusal must name the all-static rule; got: $out"
[ ! -e "$STATIC_CONTRACT" ] \
  || fail "an all-static verification surface still wrote a frozen contract at $STATIC_CONTRACT"

# (B4) POSITIVE TWIN — a static PRECONDITION guarding a real drive is NOT all-static. Without this the
# rule could be satisfied by refusing every command containing `test -f`, which would be a different
# (and wrong) rule.
MIXED_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/static-precondition.json"
python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'test -f verify.sh && bash verify.sh' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label static-precondition \
  --out "$MIXED_CONTRACT" >/dev/null \
  || fail "a static precondition guarding a REAL drive was wrongly refused as all-static"

# (B5) `cat file | grep -q x` is ALL-STATIC. `cat`/`printf` exercise nothing, but they classed OTHER,
# which satisfied the "something might drive the surface" clause on its own — so the two commonest
# piped shapes of a purely static gate passed a rule written to refuse exactly them.
PIPED_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/piped-static.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'cat src/allowed/feature.txt | grep -q behavior' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-green \
  --label piped-static \
  --out "$PIPED_CONTRACT" 2>&1)" \
  && fail "an ALL-STATIC piped gate (cat | grep) was accepted"
printf '%s\n' "$out" | grep -qF 'all-static verification surface refused' \
  || fail "the cat|grep refusal must come from the all-static rule; got: $out"
[ ! -e "$PIPED_CONTRACT" ] || fail "a refused piped-static gate still wrote a contract at $PIPED_CONTRACT"

# (B6) POSITIVE TWIN — a real drive whose NAME merely contains "lint" is NOT static. The rule used to
# be a free search over the whole segment, so `bash e2e/lint-fix-flow.sh` (a script that fixes and
# re-drives) and `npm run lint:e2e` were refused as inert with no override. It is now anchored to the
# tokens that NAME what the segment runs.
mkdir -p "$REPO_PAIR/e2e"
cat > "$REPO_PAIR/e2e/lint-fix-flow.sh" <<'SH'
#!/bin/bash
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO_PAIR/e2e/lint-fix-flow.sh"
LINTNAME_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/lint-named-drive.json"
python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash e2e/lint-fix-flow.sh' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label lint-named-drive \
  --out "$LINTNAME_CONTRACT" >/dev/null \
  || fail "a real drive whose script name merely CONTAINS 'lint' was wrongly refused as all-static"
# …and a task named exactly `lint` still classes static, so (B6) did not simply delete the rule.
LINT_CONTRACT="$REPO_PAIR/docs/workflow/build-validation/plain-lint.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'make lint' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label plain-lint \
  --out "$LINT_CONTRACT" 2>&1)" \
  && fail "a gate that is nothing but 'make lint' was accepted"
printf '%s\n' "$out" | grep -qF 'all-static verification surface refused' \
  || fail "'make lint' must still be refused BY THE ALL-STATIC RULE; got: $out"

# (C) `surface:none` without a one-line skip_reason is refused.
REPO_NONE="$WORK/repo-none"
git init -q -b main "$REPO_NONE"
git -C "$REPO_NONE" config user.email test@example.com
git -C "$REPO_NONE" config user.name tester
printf '# docs only\n' > "$REPO_NONE/README.md"
git -C "$REPO_NONE" add README.md
git -C "$REPO_NONE" commit -qm init
out="$(python3 "$VC" freeze \
  --repo "$REPO_NONE" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch README.md \
  --off-limits docs/ \
  --surface none \
  --evidence-kind none \
  --baseline expected-green \
  --label docs-only \
  --out "$REPO_NONE/docs/workflow/build-validation/none-missing-reason.json" 2>&1)" \
  && fail "surface:none without a skip_reason was accepted"
printf '%s\n' "$out" | grep -qiE 'skip_reason|surface:none|one-line' \
  || fail "surface:none refusal must name the missing skip_reason; got: $out"

# (D) A valid `surface:none` contract records the one-line reason and zero commands.
CONTRACT_NONE="$REPO_NONE/docs-only.json"
python3 "$VC" freeze \
  --repo "$REPO_NONE" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch README.md \
  --off-limits docs/ \
  --surface none \
  --evidence-kind none \
  --skip-reason 'docs-only change' \
  --baseline expected-green \
  --label docs-only \
  --out "$CONTRACT_NONE" >/dev/null \
  || fail "a valid surface:none contract was rejected"
python3 - "$CONTRACT_NONE" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
if contract.get('surface') != 'none' or contract.get('evidence_kind') != 'none':
    raise SystemExit(f"FAIL: surface:none contract recorded the wrong kind: {contract}")
if contract.get('skip_reason') != 'docs-only change':
    raise SystemExit(f"FAIL: surface:none contract lost its one-line skip_reason: {contract.get('skip_reason')!r}")
if contract.get('verification') not in ([], None):
    raise SystemExit(f"FAIL: surface:none contract must not carry runnable verification commands: {contract.get('verification')!r}")
print('ok: surface:none requires and preserves a one-line skip_reason')
PY

# (E) Declared commands that cannot produce the evidence kind are refused.
REPO_IMPOSSIBLE="$WORK/repo-impossible"
setup_repo "$REPO_IMPOSSIBLE"
out="$(python3 "$VC" freeze \
  --repo "$REPO_IMPOSSIBLE" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --surface gui \
  --evidence-kind screenshot-or-recording \
  --baseline expected-red \
  --label impossible-evidence \
  --out "$REPO_IMPOSSIBLE/docs/workflow/build-validation/impossible-evidence.json" 2>&1)" \
  && fail "an impossible evidence kind for the declared commands was accepted"
printf '%s\n' "$out" | grep -qiE 'cannot produce|evidence|screenshot|recording' \
  || fail "impossible-evidence refusal must explain the producibility failure; got: $out"

# ── (F) RECEIPT-SIDE CONTRACT DRIFT ──────────────────────────────────────────────────────────────
# The drift blocks in idc_build_receipt.py are only reachable by a forgery that (i) is WITNESSED, so
# the out-of-tree witness check passes, and (ii) is INTERNALLY SELF-CONSISTENT, so `load_execution` /
# `load_receipt` pass it through to the drift comparison. A self-inconsistent forgery, or one written
# to a fresh path, is refused EARLIER by a different guard — which is exactly how the previous fixture
# passed with all seven drift blocks deleted.
#
# The drift target is `ci`/`check-run`: the frozen gate command is `bash ci-verify.sh`, which the
# check-run producibility pattern accepts, so the forged pairing is legal in isolation and the ONLY
# thing that refuses it is its disagreement with the frozen contract.
REPO_DRIFT="$WORK/repo-drift"
setup_repo "$REPO_DRIFT"
cat > "$REPO_DRIFT/ci-verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO_DRIFT/ci-verify.sh"
git -C "$REPO_DRIFT" add ci-verify.sh
git -C "$REPO_DRIFT" commit -qm 'add ci gate'
CONTRACT_DRIFT="$REPO_DRIFT/docs/workflow/build-validation/drift.json"
EXEC_DRIFT="$REPO_DRIFT/docs/workflow/build-validation-executions/drift.json"
VERDICT_DRIFT="$REPO_DRIFT/docs/workflow/code-reviews/2026-07-27-pr-402-drift.json"
RECEIPT_DRIFT="$REPO_DRIFT/docs/workflow/build-receipts/drift.json"
python3 "$VC" freeze \
  --repo "$REPO_DRIFT" --issue 2 --pr 402 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --verify 'bash ci-verify.sh' --surface cli --evidence-kind pane-capture \
  --baseline expected-red --label drift --out "$CONTRACT_DRIFT" >/dev/null \
  || fail "could not freeze the cli contract used by the drift cases"
printf 'new behavior\n' > "$REPO_DRIFT/src/allowed/feature.txt"
git -C "$REPO_DRIFT" add src/allowed/feature.txt
git -C "$REPO_DRIFT" commit -qm 'implement drift-case behavior'
python3 "$VC" run --repo "$REPO_DRIFT" --contract "$CONTRACT_DRIFT" --out "$EXEC_DRIFT" >/dev/null \
  || fail "could not execute the drift-case validation contract"
write_verdict_from_execution "$EXEC_DRIFT" "$VERDICT_DRIFT"

# `retype <file> <kind> <python-expr-mutations>` — rewrite an artifact IN PLACE, re-sign its self
# digest, and re-record the machine witness, so the forgery is indistinguishable from a machine write
# right up until the drift comparison it is meant to trip.
retype() {
  local target="$1" kind="$2" mutation="$3"
  python3 - "$PLUGIN/scripts" "$target" "$kind" "$mutation" <<'PY' || fail "could not re-sign $target"
import json, sys
scripts, target, kind, mutation = sys.argv[1:5]
sys.path.insert(0, scripts)
import idc_validation_contract as VC
doc = json.load(open(target, encoding='utf-8'))
exec(mutation, {"doc": doc})
digest_field = {"execution": "execution_digest", "build-receipt": "receipt_digest"}[kind]
body = dict(doc)
body.pop(digest_field, None)
doc[digest_field] = VC.sha256_json(body)
VC.atomic_write_json(target, doc)
VC._record_witness(kind, target, doc)
PY
}

# (F1) write path — the EXECUTION receipt's surface/evidence kind no longer match the frozen contract.
cp "$EXEC_DRIFT" "$WORK/exec-drift.orig.json"
retype "$EXEC_DRIFT" execution \
  "doc['surface']='ci'; doc['evidence_kind']='check-run'; doc['declared_evidence']['surface']='ci'; doc['declared_evidence']['kind']='check-run'"
out="$(python3 "$BR" write \
  --repo "$REPO_DRIFT" --contract "$CONTRACT_DRIFT" --execution "$EXEC_DRIFT" --verdict "$VERDICT_DRIFT" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$REPO_DRIFT/docs/workflow/build-receipts/drift-forged.json" 2>&1)" \
  && fail "a witnessed, self-consistent execution receipt that drifted from the frozen contract was accepted"
printf '%s\n' "$out" | grep -qF "contract-drift refused: the execution receipt's declared surface/evidence kind no longer match the frozen validation contract" \
  || fail "the write-path drift refusal must be the frozen-contract surface/evidence sentence; got: $out"
[ ! -e "$REPO_DRIFT/docs/workflow/build-receipts/drift-forged.json" ] \
  || fail "a refused drift still minted a build receipt"

# (F1b) write path — a forgery that mutates ONLY `declared_evidence.kind`, leaving surface and
# evidence_kind agreeing with the frozen contract, so the comparison in (F1) cannot see it. It is
# refused at mint time and mints nothing.
#
# WHERE THE REFUSAL COMES FROM, and why this case asserts THAT sentence: the single enforcement point
# is `idc_validation_contract.load_execution`, which `write_receipt` calls before any of its own
# comparisons. `idc_build_receipt.py` used to repeat the same comparison a few lines later; neutering
# that copy to `if False:` produced the identical refusal, identical exit code and no receipt, i.e. it
# was a guard no input could ever reach. It has been removed and this case is red for the one that is
# real. (Its RECEIPT-side twin in `verify_receipt` is a different comparison — `load_receipt` does not
# make it — and is covered by "receipt declared-evidence" below.)
cp "$WORK/exec-drift.orig.json" "$EXEC_DRIFT"
retype "$EXEC_DRIFT" execution "doc['declared_evidence']['kind']='check-run'"
out="$(python3 "$BR" write \
  --repo "$REPO_DRIFT" --contract "$CONTRACT_DRIFT" --execution "$EXEC_DRIFT" --verdict "$VERDICT_DRIFT" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$REPO_DRIFT/docs/workflow/build-receipts/drift-declared.json" 2>&1)" \
  && fail "an execution receipt whose declared evidence contradicts its own recorded kind was accepted at mint time"
printf '%s\n' "$out" | grep -qF "execution receipt contract-drift: declared evidence no longer matches its recorded surface/evidence kind" \
  || fail "the mint-time declared-evidence refusal must be the verbatim single-enforcement-point sentence; got: $out"
[ ! -e "$REPO_DRIFT/docs/workflow/build-receipts/drift-declared.json" ] \
  || fail "a refused declared-evidence drift still minted a build receipt"

# Restore the honest execution receipt and mint the real build receipt the verify-path cases mutate.
cp "$WORK/exec-drift.orig.json" "$EXEC_DRIFT"
retype "$EXEC_DRIFT" execution "pass"
python3 "$BR" write \
  --repo "$REPO_DRIFT" --contract "$CONTRACT_DRIFT" --execution "$EXEC_DRIFT" --verdict "$VERDICT_DRIFT" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT_DRIFT" >/dev/null \
  || fail "the honest drift-case implementation receipt was rejected"
python3 "$BR" verify --repo "$REPO_DRIFT" --receipt "$RECEIPT_DRIFT" --issue 2 --pr 402 >/dev/null \
  || fail "the honest drift-case implementation receipt did not verify (the verify-path control)"
cp "$RECEIPT_DRIFT" "$WORK/receipt-drift.orig.json"

# (F2..F4) verify path — each mutation is witnessed + self-consistent and must be caught by ITS OWN
# drift comparison, named verbatim.
verify_drift_case() {  # $1 = label, $2 = python mutation over `doc`, $3 = the exact refusal sentence
  local label="$1" mutation="$2" sentence="$3"
  cp "$WORK/receipt-drift.orig.json" "$RECEIPT_DRIFT"
  retype "$RECEIPT_DRIFT" build-receipt "$mutation"
  local out
  out="$(python3 "$BR" verify --repo "$REPO_DRIFT" --receipt "$RECEIPT_DRIFT" --issue 2 --pr 402 2>&1)" \
    && fail "$label: a drifted implementation receipt verified clean"
  printf '%s\n' "$out" | grep -qF "$sentence" \
    || fail "$label: refusal must be '$sentence'; got: $out"
}
verify_drift_case "receipt-vs-contract surface" \
  "doc['surface']='ci'; doc['evidence_kind']='check-run'" \
  "contract-drift refused: the implementation receipt no longer matches the frozen surface/evidence kind"
verify_drift_case "receipt-vs-contract skip_reason" \
  "doc['skip_reason']='invented reason'" \
  "contract-drift refused: the implementation receipt no longer matches the frozen skip_reason"
verify_drift_case "receipt declared-evidence" \
  "doc['declared_evidence']['kind']='check-run'" \
  "contract-drift refused: the implementation receipt's declared evidence no longer matches its recorded surface/evidence kind"

# (F5) execution-vs-receipt drift: the execution AND the receipt's pointer to it both move, so the
# execution-digest guard is satisfied and the surface comparison at 251 is the only thing left.
cp "$WORK/exec-drift.orig.json" "$EXEC_DRIFT"
retype "$EXEC_DRIFT" execution \
  "doc['surface']='ci'; doc['evidence_kind']='check-run'; doc['declared_evidence']['surface']='ci'; doc['declared_evidence']['kind']='check-run'"
NEW_EXEC_DIGEST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["execution_digest"])' "$EXEC_DRIFT")"
cp "$WORK/receipt-drift.orig.json" "$RECEIPT_DRIFT"
retype "$RECEIPT_DRIFT" build-receipt "doc['execution_digest']='$NEW_EXEC_DIGEST'"
out="$(python3 "$BR" verify --repo "$REPO_DRIFT" --receipt "$RECEIPT_DRIFT" --issue 2 --pr 402 2>&1)" \
  && fail "an execution receipt that drifted away from its implementation receipt verified clean"
printf '%s\n' "$out" | grep -qF "contract-drift refused: the execution receipt no longer matches the implementation receipt's surface/evidence kind" \
  || fail "execution-vs-receipt drift must name that comparison; got: $out"

# (F6) execution-vs-receipt SKIP_REASON drift. Only reachable on a `surface:none` chain: for every
# other surface `_validation_surface` refuses a skip_reason outright, so the drifted execution never
# survives `load_execution` to reach this comparison. It is the honest-SKIP path's version of the same
# guard — a docs-only ticket whose execution receipt quietly rewrites WHY the gate was skipped.
REPO_SKIP="$WORK/repo-skip"
git init -q -b main "$REPO_SKIP"
git -C "$REPO_SKIP" config user.email test@example.com
git -C "$REPO_SKIP" config user.name tester
mkdir -p "$REPO_SKIP/docs/workflow/build-validation" \
         "$REPO_SKIP/docs/workflow/build-validation-executions" \
         "$REPO_SKIP/docs/workflow/build-receipts" \
         "$REPO_SKIP/docs/workflow/code-reviews" "$REPO_SKIP/notes"
printf '# docs\n' > "$REPO_SKIP/notes/README.md"
git -C "$REPO_SKIP" add -A
git -C "$REPO_SKIP" commit -qm init
CONTRACT_SKIP="$REPO_SKIP/docs/workflow/build-validation/skip.json"
EXEC_SKIP="$REPO_SKIP/docs/workflow/build-validation-executions/skip.json"
VERDICT_SKIP="$REPO_SKIP/docs/workflow/code-reviews/2026-07-27-pr-404-skip.json"
RECEIPT_SKIP="$REPO_SKIP/docs/workflow/build-receipts/skip.json"
python3 "$VC" freeze \
  --repo "$REPO_SKIP" --issue 4 --pr 404 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch notes/ --off-limits src/ \
  --surface none --evidence-kind none --skip-reason 'docs-only change, no behavioral diff' \
  --baseline expected-green --label skip-drift --out "$CONTRACT_SKIP" >/dev/null \
  || fail "could not freeze the surface:none contract used by the skip_reason drift case"
printf '# docs, revised\n' > "$REPO_SKIP/notes/README.md"
git -C "$REPO_SKIP" add notes/README.md
git -C "$REPO_SKIP" commit -qm 'revise the docs'
python3 "$VC" run --repo "$REPO_SKIP" --contract "$CONTRACT_SKIP" --out "$EXEC_SKIP" >/dev/null \
  || fail "could not execute the surface:none contract"
write_verdict_from_execution "$EXEC_SKIP" "$VERDICT_SKIP"
python3 "$BR" write \
  --repo "$REPO_SKIP" --contract "$CONTRACT_SKIP" --execution "$EXEC_SKIP" --verdict "$VERDICT_SKIP" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT_SKIP" >/dev/null \
  || fail "the honest surface:none implementation receipt was rejected"
python3 "$BR" verify --repo "$REPO_SKIP" --receipt "$RECEIPT_SKIP" --issue 4 --pr 404 >/dev/null \
  || fail "the honest surface:none implementation receipt did not verify (control)"
retype "$EXEC_SKIP" execution \
  "doc['skip_reason']='a different reason invented after the fact'; doc['declared_evidence']['skip_reason']=doc['skip_reason']"
SKIP_EXEC_DIGEST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["execution_digest"])' "$EXEC_SKIP")"
retype "$RECEIPT_SKIP" build-receipt "doc['execution_digest']='$SKIP_EXEC_DIGEST'"
out="$(python3 "$BR" verify --repo "$REPO_SKIP" --receipt "$RECEIPT_SKIP" --issue 4 --pr 404 2>&1)" \
  && fail "an execution receipt that rewrote its skip_reason verified clean"
printf '%s\n' "$out" | grep -qF "contract-drift refused: the execution receipt no longer matches the implementation receipt's skip_reason" \
  || fail "skip_reason drift must name that comparison; got: $out"

# ── (G) credential-shaped material on the gate's STDOUT is redacted in BOTH committed artifacts ───
# `stderr` was scrubbed at the read from the start; `stdout` was passed through raw and bounded, so a
# gate that printed a token wrote it verbatim into the frozen contract AND the execution receipt —
# both committed repo files.
#
# THE PROFILE MATTERS AS MUCH AS THE DOOR. The shared floor catches what NAMES itself a secret or
# carries a vendor's documented prefix; it does NOT catch a bare AWS secret access key, an Azure
# `AccountKey=…`, or any other long opaque blob. A gate's stdout is an unpredictable capture from a
# project's own probe — the one case `idc_credential_shapes` names as affordable for the opaque-run
# backstop, and the profile `idc_live_check.py` (the repo's other committed-evidence writer) applies.
# So this case asserts THREE shapes, not one. Every literal is synthetic and matches no real
# credential.
#
# THE ALPHABET IS THE WHOLE PROPERTY, AND THE FIRST VERSION OF THIS FIXTURE HAD IT WRONG. Its two
# opaque literals were pure `[A-Za-z0-9]`, and it asserted only that they were 40+ characters long.
# That is the alphabet of a git sha, not of a credential: REAL base64 carries `+` and `/`, and each of
# those splits a run into sub-40 fragments that a `[A-Za-z0-9_-]{40,}` guard cannot see. So the fixture
# passed for a shape no real credential has, while an actual Azure account key walked into both
# committed artifacts. The literals below therefore carry `+`, `/` and `=`, and the checker asserts
# that property directly — including that NO `[A-Za-z0-9_-]` sub-run in them reaches 40 characters, so
# the old guard provably could not have caught them.
FAKE_TOKEN='ghp_EXAMPLENOTAREALTOKEN0123456789abcd'
FAKE_OPAQUE='EXAMPLEONLY/not+a/real+secret/access+key/00000000000'
FAKE_AZURE='EXAMPLEONLYnotarealazure+storage/account+key/value000000000000000=='
REPO_LEAK="$WORK/repo-leak"
setup_repo "$REPO_LEAK"
# The gate also prints WELL OVER the 400-character evidence bound, so the "bounded evidence"
# assertion below is not satisfied by a fixture that simply prints nothing.
cat > "$REPO_LEAK/leaky-verify.sh" <<SH
#!/bin/bash
echo "gate output: $FAKE_TOKEN"
echo "aws-ish: $FAKE_OPAQUE"
echo "azure-ish: AccountKey=$FAKE_AZURE"
for i in \$(seq 1 40); do echo "evidence line \$i of the gate's ordinary chatter"; done
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO_LEAK/leaky-verify.sh"
git -C "$REPO_LEAK" add leaky-verify.sh
git -C "$REPO_LEAK" commit -qm 'add leaky gate'
CONTRACT_LEAK="$REPO_LEAK/docs/workflow/build-validation/leak.json"
EXEC_LEAK="$REPO_LEAK/docs/workflow/build-validation-executions/leak.json"
python3 "$VC" freeze \
  --repo "$REPO_LEAK" --issue 3 --pr 403 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --verify 'bash leaky-verify.sh' --surface cli --evidence-kind pane-capture \
  --baseline expected-red --label leak --out "$CONTRACT_LEAK" >/dev/null \
  || fail "could not freeze the stdout-redaction contract"
printf 'new behavior\n' > "$REPO_LEAK/src/allowed/feature.txt"
git -C "$REPO_LEAK" add src/allowed/feature.txt
git -C "$REPO_LEAK" commit -qm 'implement leak-case behavior'
python3 "$VC" run --repo "$REPO_LEAK" --contract "$CONTRACT_LEAK" --out "$EXEC_LEAK" >/dev/null \
  || fail "could not execute the stdout-redaction contract"
python3 - "$CONTRACT_LEAK" "$EXEC_LEAK" "$FAKE_TOKEN" "$FAKE_OPAQUE" "$FAKE_AZURE" <<'PY' || exit 1
import json, re, sys
contract_path, exec_path = sys.argv[1:3]
literals = {"vendor-prefixed token": sys.argv[3],
            "bare opaque secret run": sys.argv[4],
            "Azure AccountKey value": sys.argv[5]}
# ── THE FIXTURE MUST FIRST PROVE ITSELF ──────────────────────────────────────────────────────────
# Two properties, and the second is the one that was missing:
#   1. each OPAQUE literal is at least as long as the backstop's own 40-character bound — otherwise it
#      would be caught by some other rule, or not at all, and the case would prove nothing;
#   2. each one uses the BASE64 alphabet, and no `[A-Za-z0-9_-]` sub-run inside it reaches 40. That is
#      what makes these literals real: a guard written against the `\w` alphabet is arithmetically
#      incapable of matching them, so a green here is the widened alphabet doing the work and nothing
#      else. Without (2) the fixture certifies a shape no credential has.
for name in ("bare opaque secret run", "Azure AccountKey value"):
    literal = literals[name]
    if len(literal) < 40:
        raise SystemExit(f"FAIL: the {name} fixture literal is shorter than the backstop's own bound "
                         f"({len(literal)}); the case would prove nothing")
    if not set('+/=') & set(literal):
        raise SystemExit(
            f"FAIL: the {name} fixture literal {literal!r} uses only the `\\w` alphabet. No real "
            "base64 credential does — rebuild it with `+`, `/` and `=` or this case certifies a shape "
            "that does not occur")
    longest = max(len(part) for part in re.split(r'[^A-Za-z0-9_-]', literal))
    if longest >= 40:
        raise SystemExit(
            f"FAIL: the {name} fixture literal {literal!r} still contains a {longest}-character "
            "`[A-Za-z0-9_-]` sub-run, so the ORIGINAL narrow backstop would have caught it too. This "
            "case must be red for the alphabet, not for the length")
for label, path in (("frozen contract", contract_path), ("execution receipt", exec_path)):
    raw = open(path, encoding='utf-8').read()
    for name, literal in literals.items():
        if literal in raw:
            raise SystemExit(
                f"FAIL: the gate's stdout {name} reached the committed {label} VERBATIM ({path})")
    if '[REDACTED]' not in raw:
        raise SystemExit(f"FAIL: the {label} carries no redaction marker — the excerpt was dropped, not scrubbed ({path})")
contract = json.load(open(contract_path, encoding='utf-8'))
execution = json.load(open(exec_path, encoding='utf-8'))
baseline = [row.get('stdout_excerpt') or '' for row in contract['baseline']['results']]
runs = [row.get('stdout_excerpt') or '' for row in execution['verification']]
declared = [row.get('stdout_excerpt') or '' for row in execution['declared_evidence']['records']]
for label, rows in (("baseline.results", baseline), ("verification", runs),
                    ("declared_evidence.records", declared)):
    if not any('[REDACTED]' in row for row in rows):
        raise SystemExit(f"FAIL: {label} carries no redacted stdout excerpt: {rows!r}")
    if any('gate output' not in row for row in rows):
        raise SystemExit(f"FAIL: {label} lost the surrounding stdout evidence entirely: {rows!r}")
    # The BOUND, asserted against a gate that really does print past it: over-long output is CUT, and
    # the cut is visible. With the clip removed these rows run to thousands of characters.
    for row in rows:
        if len(row) > 400:
            raise SystemExit(f"FAIL: {label} exceeded the 400-character evidence bound ({len(row)})")
        if not row.endswith('...'):
            raise SystemExit(
                f"FAIL: {label} was not actually clipped — the gate printed well past the bound, so a "
                f"row that does not end in the truncation marker means the bound never fired: {row!r}")
print('ok: gate stdout is redacted (vendor prefix, opaque run, Azure key) in the frozen contract AND '
      'the execution receipt, bounded at 400 characters, evidence preserved')
PY

# ── (G2) A PRIVATE KEY WHOSE FOOTER NEVER ARRIVED ────────────────────────────────────────────────
# The shared `PEM_PRIVATE_KEY_BLOCK` rule is anchored on BOTH delimiters, deliberately: it rewrites a
# capture in place and must never run away past the key it is destroying. So a gate that printed a
# BEGIN line and a key body but no `-----END …-----` — a truncated dump, a probe that died mid-write —
# passed the shared floor untouched, and the key body reached the frozen contract AND the execution
# receipt VERBATIM. Both are committed repo files: that is a private key in git history.
#
# This case is deliberately its own repo and its own gate. The unterminated-PEM arm redacts to the END
# of the capture (there is no right-hand anchor to stop at), so mixing it into (G) would swallow that
# case's length/clip evidence and make its assertions vacuous.
FAKE_PEM_BODY='MIIEXAMPLEONLYnotarealprivatekeybody+abc/def+ghi/jkl0000000000=='
REPO_PEM="$WORK/repo-pem"
setup_repo "$REPO_PEM"
cat > "$REPO_PEM/pem-verify.sh" <<SH
#!/bin/bash
echo "gate output: dumping the key it just generated"
echo '-----BEGIN RSA PRIVATE KEY-----'
echo "$FAKE_PEM_BODY"
echo "trailing chatter printed after the key"
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO_PEM/pem-verify.sh"
git -C "$REPO_PEM" add pem-verify.sh
git -C "$REPO_PEM" commit -qm 'add a gate that dumps an unterminated key'
CONTRACT_PEM="$REPO_PEM/docs/workflow/build-validation/pem.json"
EXEC_PEM="$REPO_PEM/docs/workflow/build-validation-executions/pem.json"
python3 "$VC" freeze \
  --repo "$REPO_PEM" --issue 6 --pr 406 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --verify 'bash pem-verify.sh' --surface cli --evidence-kind pane-capture \
  --baseline expected-red --label pem --out "$CONTRACT_PEM" >/dev/null \
  || fail "could not freeze the unterminated-PEM contract"
printf 'new behavior\n' > "$REPO_PEM/src/allowed/feature.txt"
git -C "$REPO_PEM" add src/allowed/feature.txt
git -C "$REPO_PEM" commit -qm 'implement pem-case behavior'
python3 "$VC" run --repo "$REPO_PEM" --contract "$CONTRACT_PEM" --out "$EXEC_PEM" >/dev/null \
  || fail "could not execute the unterminated-PEM contract"
python3 - "$CONTRACT_PEM" "$EXEC_PEM" "$FAKE_PEM_BODY" <<'PY' || exit 1
import json, sys
contract_path, exec_path, body = sys.argv[1:4]
HEADER = '-----BEGIN RSA PRIVATE KEY-----'
for label, path in (("frozen contract", contract_path), ("execution receipt", exec_path)):
    raw = open(path, encoding='utf-8').read()
    if body in raw:
        raise SystemExit(
            f"FAIL: the unterminated private-key BODY reached the committed {label} VERBATIM "
            f"({path}) — that is a key in git history")
    if HEADER in raw:
        raise SystemExit(
            f"FAIL: the private-key header survived into the committed {label} ({path}); the arm must "
            "redact from the BEGIN line, header included")
    if '[REDACTED PRIVATE KEY]' not in raw:
        raise SystemExit(
            f"FAIL: the {label} carries no private-key marker ({path}) — the key was dropped by some "
            "other rule, or not seen at all; this case must be green for the unterminated-PEM arm")
contract = json.load(open(contract_path, encoding='utf-8'))
execution = json.load(open(exec_path, encoding='utf-8'))
rows = ([row.get('stdout_excerpt') or '' for row in contract['baseline']['results']]
        + [row.get('stdout_excerpt') or '' for row in execution['verification']]
        + [row.get('stdout_excerpt') or '' for row in execution['declared_evidence']['records']])
for row in rows:
    if '[REDACTED PRIVATE KEY]' not in row:
        raise SystemExit(f"FAIL: a stored stdout excerpt carries no private-key marker: {row!r}")
    # The evidence BEFORE the key survives — the arm redacts a key, it does not blank the capture.
    if 'gate output' not in row:
        raise SystemExit(f"FAIL: the arm destroyed the evidence preceding the key: {row!r}")
    # …and the documented COST is real and asserted, not assumed: with no closing delimiter the only
    # safe right-hand boundary is the end of the capture, so everything after the header is lost.
    if 'trailing chatter' in row:
        raise SystemExit(
            f"FAIL: output printed AFTER the private-key header survived: {row!r}. With no footer "
            "there is no anchor to stop at, so the arm must redact to the end of the capture")
print('ok: an unterminated private key is redacted out of the frozen contract AND the execution '
      'receipt, header and body, with the preceding evidence intact')
PY

# ── (H) A GATE THAT NEVER TERMINATES IS REFUSED, NOT WAITED ON ───────────────────────────────────
# Spec §3.4 names "timeout" as a stopping condition; this runner had none, so a hanging gate hung the
# freeze forever. THIS IS A BOUND, so a broken guard does not go red on its own — it hangs, and a hang
# reads like a slow pass. The probe therefore runs under an OUTER `timeout` and treats the outer
# timeout firing as the failure signal, by name.
#
# A timeout is a REFUSAL, not a red baseline: a gate that could not finish established nothing, and
# recording that as `expected-red` would let a hanging command freeze as a legitimate baseline.
REPO_HANG="$WORK/repo-hang"
setup_repo "$REPO_HANG"
cat > "$REPO_HANG/hang.sh" <<'SH'
#!/bin/bash
sleep 300
SH
chmod +x "$REPO_HANG/hang.sh"
git -C "$REPO_HANG" add hang.sh
git -C "$REPO_HANG" commit -qm 'add a gate that never returns'
HANG_CONTRACT="$REPO_HANG/docs/workflow/build-validation/hang.json"
set +e
out="$(IDC_VERIFY_TIMEOUT=2 timeout 60 python3 "$VC" freeze \
  --repo "$REPO_HANG" --issue 5 --pr 405 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --verify 'bash hang.sh' --surface cli --evidence-kind pane-capture \
  --baseline expected-red --label hang --out "$HANG_CONTRACT" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 124 ] \
  && fail "the freeze did not stop on its own — the OUTER timeout had to kill it, i.e. the verification-command timeout is gone"
[ "$rc" -ne 0 ] || fail "a gate that never terminates was accepted: $out"
printf '%s\n' "$out" | grep -qF 'timed out after 2s and established nothing' \
  || fail "the refusal must name the timeout as the reason, not some later failure; got: $out"
[ ! -e "$HANG_CONTRACT" ] || fail "a timed-out gate still wrote a frozen contract at $HANG_CONTRACT"

# ── (I) THE 17 KB CAPTURE BOUND ON THE REDACTION PASS ────────────────────────────────────────────
# THIS IS A BOUND, so a removed guard does not go red on its own — the redaction pass simply runs over
# however much output the gate produced, which reads as a slow pass, not a failure. So the probe runs
# under an EXPLICIT OUTER TIMEOUT and names the outer timeout firing as the failure signal, exactly
# like the hang case above.
#
# WHAT IS ASSERTED, AND WHAT IS NOT. The stored excerpt is clipped to 400 characters regardless, so the
# bound is invisible in the artifacts and there is nothing to assert there — saying otherwise would be
# a fixture that cannot fail. The bound's real guarantees are (1) the redaction rules never walk an
# unbounded capture, announced by the `[capture bounded at …]` marker on the function's own output, and
# (2) the cut is LOSSLESS at the stored width, because it takes the HEAD and `_clip` keeps the head
# too. Both are asserted directly against `_gate_evidence`, which is where they live. The final arm
# then drives a real gate printing well past the bound through the live freeze path, so the bound is
# proven to be ON that path and not merely a constant somebody could delete unnoticed.
set +e
timeout 120 python3 - "$PLUGIN/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import idc_validation_contract as VC

bound = VC.MAX_CAPTURE_CHARS
if bound != 17 * 1024:
    raise SystemExit(f"FAIL: the capture bound is {bound}, not the documented 17 KB; the assertions "
                     "below were written against 17 KB and would silently mean something else")
head = "gate chatter that says nothing in particular\n" * 600
if len(head) <= bound:
    raise SystemExit(f"FAIL: the probe capture ({len(head)}) does not exceed the bound ({bound}); "
                     "the case would prove nothing")
capture = head + "PAST-THE-BOUND-MARKER\n"
out = VC._gate_evidence(capture)
marker = f"[capture bounded at {bound} characters]"
if marker not in out:
    raise SystemExit(
        f"FAIL: a {len(capture)}-character capture came back with no {marker!r} — the redaction pass "
        "walked the WHOLE capture. Nothing about a gate's output is bounded upstream of here")
if "PAST-THE-BOUND-MARKER" in out:
    raise SystemExit("FAIL: content from beyond the bound survived into the returned evidence")
if len(out) > bound + len(marker) + 1:
    raise SystemExit(f"FAIL: the returned evidence is {len(out)} characters, past bound+marker "
                     f"({bound + len(marker) + 1}) — the cut did not hold")
# LOSSLESS AT THE STORED WIDTH: cutting the head is what makes the bound free. Nothing that reaches the
# stored 400-character excerpt was ever outside it, so bounding first must not change that excerpt.
if VC._clip(out) != VC._clip(VC._gate_evidence(capture[:bound])):
    raise SystemExit("FAIL: the bound changed the STORED excerpt — it is cutting the head, which is "
                     "the part `_clip` keeps, so it is no longer lossless")
print(f"ok: a {len(capture)}-character capture is bounded at {bound} before redaction, marked, and "
      "lossless at the stored width")
PY
rc=$?
set -e
[ "$rc" -eq 124 ] \
  && fail "the capture-bound probe had to be killed by the OUTER timeout — redaction over an oversized capture no longer terminates promptly, i.e. the bound is gone"
[ "$rc" -eq 0 ] || fail "the 17 KB capture bound is not holding (exit $rc)"

# …and the bound is on the LIVE path: a real gate printing far past it freezes without the outer
# timeout firing, and the stored excerpt is still the clipped head with its evidence intact.
REPO_BIG="$WORK/repo-big"
setup_repo "$REPO_BIG"
cat > "$REPO_BIG/big-verify.sh" <<'SH'
#!/bin/bash
for i in $(seq 1 900); do echo "evidence line $i of a gate that prints far past the capture bound"; done
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO_BIG/big-verify.sh"
git -C "$REPO_BIG" add big-verify.sh
git -C "$REPO_BIG" commit -qm 'add a gate that prints past the capture bound'
BIG_CONTRACT="$REPO_BIG/docs/workflow/build-validation/big.json"
set +e
timeout 120 python3 "$VC" freeze \
  --repo "$REPO_BIG" --issue 7 --pr 407 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --verify 'bash big-verify.sh' --surface cli --evidence-kind pane-capture \
  --baseline expected-red --label big --out "$BIG_CONTRACT" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ] && fail "freezing a gate that prints past the capture bound had to be killed by the OUTER timeout"
[ "$rc" -eq 0 ] || fail "could not freeze the oversized-capture contract (exit $rc)"
python3 - "$BIG_CONTRACT" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
rows = [row.get('stdout_excerpt') or '' for row in contract['baseline']['results']]
if not rows:
    raise SystemExit("FAIL: the oversized-capture freeze recorded no baseline results at all")
for row in rows:
    if len(row) > 400:
        raise SystemExit(f"FAIL: an oversized capture stored a {len(row)}-character excerpt")
    if 'evidence line 1 of a gate' not in row:
        raise SystemExit(f"FAIL: the oversized capture lost its head evidence entirely: {row!r}")
print('ok: the live freeze path bounds an oversized gate capture and still stores its head evidence')
PY

echo "PASS: validation contracts require an explicit surface, type the fixed surface/evidence table, refuse all-static gates (including piped cat|grep) without refusing lint-NAMED drives, require surface:none reasons, reject impossible evidence, refuse witnessed receipt-side contract drift on both write and verify paths, redact gate stdout with the committed-evidence profile (base64-alphabet opaque runs and unterminated private keys included) inside a 400-character bound over a 17 KB-bounded capture, and refuse a gate that never terminates"