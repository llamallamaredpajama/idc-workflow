#!/bin/bash
# idc-assert-class: behavior
# finish-appends-verification-handle.sh — the COMPOUNDING half of the verification-handle design.
#
# Plan resolves reusable recipes by lookup; nothing ever wrote one back, so the registry could only
# ever hold what an operator hand-typed. Every triplet that figured out how to drive a new surface
# threw that knowledge away, and the next Plan re-derived it — the exact redundant-script failure the
# pilot-acceptance list worries about. `idc_verification_handles.py append` closes it as FIXED CODE
# writing IN PLACE on the ticket's branch, so the new recipe arrives as an ordinary tracked doc diff
# through the normal PR path, never a side-channel write.
#
# Proves:
#   (i)    after a handle-LESS contract executes green, `append --from-execution` records an entry
#          whose verify_commands are exactly the commands that were EXECUTED;
#   (ii)   the resulting file re-validates under `idc_schema_check.py registry` and resolves;
#   (iii)  every refusal — a caller-declared recipe with no execution receipt, an out-of-repo
#          `--registry`, a FAILING execution receipt, a receipt that already cites a handle, each
#          credential shape the write door recognizes, a private URL beside a placeholder, a missing
#          registry, a malformed id, a contradicted `--surface`/`--verify-command`, a duplicate id —
#          leaves the file byte-identical, and no refusal ever echoes the credential back;
#   (iv)   a crash between the candidate write and the swap leaves the operator's file untouched;
#   (v)    the write lands as an ordinary tracked file change (git sees a modified, staged-able file);
#   (vi)   agents/idc-finisher.md still names the append step, in the shipped order: append → re-run
#          the frozen gate → mint the build receipt, and BOTH Plan playbooks (agents/idc-plan.md,
#          templates/WORKFLOW.md) still carry the boundary obligation that step depends on — the
#          finisher cannot create it, because `touch`/`off-limits` are frozen at Plan;
#   (vii)  THE WHOLE PATH END TO END. Following the shipped ordering against a plan that put the
#          registry inside `touch`, the appended entry lands INSIDE the receipt-bound diff and the
#          implementation receipt mints and verifies. This is the case that would have caught the
#          dead-end: the previous playbook told the finisher to commit the append and then mint,
#          which the receipt writer refuses three separate ways (stale head, stale diff, off-limits
#          path), so the documented step could not be completed by anyone following it.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
VH="$PLUGIN/scripts/idc_verification_handles.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
RVC="$PLUGIN/scripts/idc_review_verdict_check.py"
SCHEMA="$PLUGIN/scripts/idc_schema_check.py"
FINISHER="$PLUGIN/agents/idc-finisher.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper at $VC"
[ -f "$VH" ] || fail "missing verification-handle helper at $VH"
[ -f "$BR" ] || fail "missing build receipt helper at $BR"
[ -f "$FINISHER" ] || fail "agents/idc-finisher.md not found at $FINISHER"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/src/allowed" "$REPO/docs/workflow/build-validation" \
         "$REPO/docs/workflow/build-validation-executions"
cat > "$REPO/drive-surface.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
# A gate whose own INVOCATION carries credential-shaped material — the realistic way a secret reaches
# the registry now that `append` derives commands from a proven run rather than from the caller. The
# script ignores its arguments; what matters is that the INVOCATION is what gets persisted.
cat > "$REPO/token-gate.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO/drive-surface.sh" "$REPO/token-gate.sh"
printf 'old behavior\n' > "$REPO/src/allowed/feature.txt"
# The scaffolded registry template: schema-valid, and EMPTY — the state every governed repo starts in.
cat > "$REPO/docs/workflow/verification-handles.yaml" <<'YAML'
# verification-handles.yaml — governed verification-surface registry
# (this header comment must survive an append)
schema_version: 1
handles: []
YAML
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

REG="$REPO/docs/workflow/verification-handles.yaml"
CONTRACT_DIR="$REPO/docs/workflow/build-validation"
EXEC_DIR="$REPO/docs/workflow/build-validation-executions"

# `freeze_gate <name> <issue> <pr> <baseline> <verify-command>` — one frozen contract per case. Every
# freeze happens BEFORE the implementing commit so the declared `expected-red` baseline is honest.
freeze_gate() {
  local name="$1" issue="$2" pr="$3" baseline="$4" verify="$5"
  python3 "$VC" freeze \
    --repo "$REPO" --issue "$issue" --pr "$pr" --graph-node alpha \
    --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
    --touch src/allowed/ --off-limits docs/ \
    --surface cli --evidence-kind pane-capture --verify "$verify" \
    --baseline "$baseline" --label "$name" --out "$CONTRACT_DIR/$name.json" >/dev/null \
    || fail "could not freeze the '$name' contract"
}

# ── THE CREDENTIAL SHAPES THIS WRITE DOOR MUST REFUSE ────────────────────────────────────────────
# Each row is a REAL invocation shape, carrying material with the real alphabet of the thing it
# imitates — a fixture whose "secret" is a shape no credential has proves nothing about the rule. The
# LITERAL column is the material that must never appear in the refusal text, because that text is
# destined for a report (agents/idc-finisher.md: a refusal "is a finding to fix").
#
# Rows 1-4 are the shapes the SHARED table cannot see: its PEM rule needs a matching `-----END …-----`
# footer (a command that WRITES a key carries only the header), and its named-secret rule lists
# secret/password/token/api_key/apikey/credential/auth but not a bare `key`, so `private_key=` and
# `PRIVATE_KEY=` are not in it. Rows 5-6 are the registry-only pointer rules.
SHAPE_NAME=(
  "sec-pem-header"
  "sec-pem-ec-header"
  "sec-private-key-assign"
  "sec-private-key-env"
  "sec-op-reference"
  "sec-dotenv-pointer"
)
SHAPE_CMD=(
  "printf -- '-----BEGIN RSA PRIVATE KEY-----' > /dev/null && bash token-gate.sh"
  "echo '-----BEGIN EC PRIVATE KEY-----' | bash token-gate.sh"
  "bash token-gate.sh --config private_key=/home/fixture-user/id_rsa"
  "PRIVATE_KEY=NOTAREALPRIVATEKEYVALUE0123 bash token-gate.sh"
  "bash token-gate.sh --secrets op://fixture-vault/fixture-item/field"
  "bash token-gate.sh --env-file .env.fixtureonly"
)
SHAPE_LITERAL=(
  "-----BEGIN RSA PRIVATE KEY-----"
  "-----BEGIN EC PRIVATE KEY-----"
  "/home/fixture-user/id_rsa"
  "NOTAREALPRIVATEKEYVALUE0123"
  "op://fixture-vault/fixture-item/field"
  ".env.fixtureonly"
)
# Synthetic, matches no real credential, and deliberately unlike every path and filename in this
# fixture so no assertion below can be satisfied by the fixture's own scaffolding.
FAKE_TOKEN='ghp_EXAMPLENOTAREALTOKEN0123456789abcd'
SHAPE_NAME+=("sec-vendor-token"); SHAPE_CMD+=("bash token-gate.sh --auth-token $FAKE_TOKEN")
SHAPE_LITERAL+=("$FAKE_TOKEN")

# Two handle-LESS contracts drive the honest path: this triplet is the first to drive this surface, so
# there is nothing to cite.
freeze_gate first 7 707 expected-red 'bash drive-surface.sh'
CONTRACT="$CONTRACT_DIR/first.json"
EXEC="$EXEC_DIR/first.json"

i=0
while [ "$i" -lt "${#SHAPE_NAME[@]}" ]; do
  freeze_gate "${SHAPE_NAME[$i]}" $((20 + i)) $((720 + i)) expected-red "${SHAPE_CMD[$i]}"
  i=$((i + 1))
done

# A command carrying BOTH a benign placeholder word and a real private host. The placeholder check is
# PER-URL for exactly this shape: as a whole-value search, one `example.com` anywhere in the command
# switched the private-host rule off for every other URL in it.
freeze_gate sec-url-mix 40 740 expected-red \
  'bash token-gate.sh --note example.com --endpoint https://db.prod.internal/health'

# (iii-f, pre-implementation) A FAILING run of the honest gate. Only a PROVEN recipe earns an entry,
# and "proven" means the recorded run PASSED — this receipt is witnessed, source-owned and internally
# valid in every other way, so the passing check is the only thing standing between a gate that does
# not work and a registry entry every later Plan would resolve as a working recipe.
EXEC_FAIL="$EXEC_DIR/first-failing.json"
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXEC_FAIL" >/dev/null \
  || fail "could not execute the handle-less contract against the unimplemented code"
python3 - "$EXEC_FAIL" <<'PY' || exit 1
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
if doc.get('result') != 'fail':
    raise SystemExit("FAIL: the pre-implementation run was supposed to record a FAILING gate, got "
                     f"{doc.get('result')!r} — the refusal case below would prove nothing")
PY

printf 'new behavior\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add src/allowed/feature.txt
git -C "$REPO" commit -qm 'implement the behavior'

python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXEC" >/dev/null \
  || fail "could not execute the handle-less contract"
i=0
while [ "$i" -lt "${#SHAPE_NAME[@]}" ]; do
  python3 "$VC" run --repo "$REPO" --contract "$CONTRACT_DIR/${SHAPE_NAME[$i]}.json" \
    --out "$EXEC_DIR/${SHAPE_NAME[$i]}.json" >/dev/null \
    || fail "could not execute the '${SHAPE_NAME[$i]}' contract"
  i=$((i + 1))
done
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT_DIR/sec-url-mix.json" \
  --out "$EXEC_DIR/sec-url-mix.json" >/dev/null || fail "could not execute the url-mix contract"

# ── (iii) Refusals FIRST, against the pre-append file, so a refusal can never be mistaken for a side
#         effect of the successful append below. Every one re-checks the bytes on disk.
cp "$REG" "$WORK/registry.before"
unchanged() { cmp -s "$REG" "$WORK/registry.before" || fail "$1"; }

# `refuses <sentence> <why> -- <append args…>` — every refusal case is the same four assertions:
# non-zero exit, the SPECIFIC sentence (not merely "some refusal"), and a byte-identical registry.
refuses() {
  local sentence="$1" why="$2" out rc
  shift 3
  set +e
  out="$(python3 "$VH" append --repo "$REPO" "$@" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$why (the append SUCCEEDED)"
  printf '%s\n' "$out" | grep -qF -- "$sentence" \
    || fail "$why: the refusal must say '$sentence'; got: $out"
  unchanged "$why: a REFUSED append still modified the registry on disk"
  REFUSAL_OUT="$out"
}

# (iii-a) NO --from-execution. Spec §3.4 requires the registry to record "the commands that were
# actually executed rather than commands re-declared by the caller"; a second, caller-declared mode
# did exactly what that forbids, writing an unproven recipe every later freeze/run would then execute
# through `/bin/bash -lc`.
refuses '--from-execution' \
  "a caller-DECLARED recipe with no execution receipt was appended" -- \
  --handle-id 'retyped-recipe' --surface cli --verify-command 'bash never-ran-anywhere.sh'
grep -qF 'never-ran-anywhere.sh' "$REG" \
  && fail "an unproven, never-executed command was written into the governed registry"

# (iii-b) An out-of-repo `--registry`. The append is documented — here and in spec §3.4 — as writing
# IN PLACE on the ticket's own branch. Unchecked, `--registry <anywhere>` made fixed code mutate an
# operator file with NO tracked diff in the governed repo at all.
OUTSIDE_DIR="$WORK/outside-the-repo"
mkdir -p "$OUTSIDE_DIR"
OUTSIDE_REG="$OUTSIDE_DIR/other.yaml"
cat > "$OUTSIDE_REG" <<'YAML'
schema_version: 1
handles: []
YAML
cp "$OUTSIDE_REG" "$WORK/outside.before"
refuses 'outside the governed repo root' \
  "an append targeting a registry OUTSIDE the governed repo was accepted" -- \
  --registry "$OUTSIDE_REG" --handle-id 'side-channel' --from-execution "$EXEC"
cmp -s "$OUTSIDE_REG" "$WORK/outside.before" \
  || fail "a refused out-of-repo append still wrote to $OUTSIDE_REG"

# (iii-c) SECRET-BEARING PROVEN RECIPES, one per shape the write door recognizes. The commands come
# from real passing executions, so this is the gate doing its job on the WRITE path onto a committed
# repo file — not on a retyped string. Each case asserts the specific credential sentence (a
# neighbouring rule refusing for a DIFFERENT reason must not satisfy it) and that the refusal never
# echoes the material back.
i=0
while [ "$i" -lt "${#SHAPE_NAME[@]}" ]; do
  refuses 'contains secret/credential/auth material' \
    "the '${SHAPE_NAME[$i]}' credential shape reached the governed registry" -- \
    --handle-id "${SHAPE_NAME[$i]}" --from-execution "$EXEC_DIR/${SHAPE_NAME[$i]}.json"
  printf '%s\n' "$REFUSAL_OUT" | grep -qF -- "${SHAPE_LITERAL[$i]}" \
    && fail "the '${SHAPE_NAME[$i]}' refusal PRINTED the material verbatim into a string destined for a report"
  i=$((i + 1))
done

# (iii-c2) The private-URL twin: a placeholder elsewhere in the command must not disarm the host check
# for a REAL host. Asserting the URL sentence (not the credential one) is what makes this case red for
# the per-URL loop rather than for any rule that happens to fire first.
refuses 'contains a private URL host' \
  "a placeholder word elsewhere in the command disarmed the private-host check" -- \
  --handle-id 'url-mix' --from-execution "$EXEC_DIR/sec-url-mix.json"

# (iii-d) A FAILING execution receipt. "Proven" means the run passed; without this the registry
# publishes a recipe for a gate that does not work, and every later Plan resolves it by lookup.
refuses 'did not record a passing run' \
  "a FAILING execution receipt was published to the registry as a proven recipe" -- \
  --handle-id 'unproven-recipe' --from-execution "$EXEC_FAIL"

# (iii-e) A MISSING registry. The scaffold creates it; a repo that predates the scaffold must be told
# to run /idc:init rather than have fixed code conjure a governed operator file out of nowhere.
NO_REGISTRY_REPO="$WORK/repo-without-registry"
mkdir -p "$NO_REGISTRY_REPO"
set +e
out="$(python3 "$VH" append --repo "$NO_REGISTRY_REPO" --handle-id 'no-registry' \
        --from-execution "$EXEC" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an append against a repo with NO registry silently created one"
printf '%s\n' "$out" | grep -qF 'no verification-handle registry at' \
  || fail "the missing-registry refusal must name the absent registry; got: $out"
printf '%s\n' "$out" | grep -qF '/idc:init' \
  || fail "the missing-registry refusal must route the operator to the scaffold; got: $out"
[ -e "$NO_REGISTRY_REPO/docs/workflow/verification-handles.yaml" ] \
  && fail "the refused append created a registry file at a repo that had none"

# (iii-f) A malformed handle_id. The id is a lookup key Plan cites from an issue body and fixed code
# resolves; an id with spaces, slashes or shell metacharacters is not addressable.
#
# THE SENTENCE HAS TO PIN THE EARLY DOOR, NOT JUST "SOME REFUSAL ABOUT ids". `idc_schema_check.py`
# enforces the same id shape over the CANDIDATE file, so with `append`'s own precondition deleted the
# malformed id still gets refused — by the candidate re-validation, wrapped as "appending … would
# leave … invalid". Asserting only `handle_id must match` therefore stayed green with the precondition
# gone. This asserts the precondition's OWN sentence (it quotes the offending id back with `got …`)
# and that the wrapped late refusal is NOT what fired, so deleting the early door is red.
refuses "handle_id must match [a-z0-9][a-z0-9-]*, got 'Not A Valid Id!'" \
  "a malformed handle_id was written into the governed registry" -- \
  --handle-id 'Not A Valid Id!' --from-execution "$EXEC"
printf '%s\n' "$REFUSAL_OUT" | grep -qF 'would leave' \
  && fail "the malformed handle_id was caught only by the candidate re-validation — the append's own precondition (the cheap refusal that never builds a candidate at all) is gone"

# (iii-g / iii-h) The two optional CROSS-CHECKS. Both flags exist so a caller can state what it
# believes it proved; when the belief contradicts the receipt the append is refused rather than
# silently recording the receipt's version, because a caller that is wrong about WHAT it proved is
# also making a claim in its report.
refuses 'does not match the executed surface' \
  "a --surface contradicting the executed surface was silently overwritten" -- \
  --handle-id 'surface-mismatch' --surface api --from-execution "$EXEC"
refuses 'does not match the executed commands' \
  "a --verify-command contradicting the executed commands was silently overwritten" -- \
  --handle-id 'command-mismatch' --verify-command 'bash something-else.sh' --from-execution "$EXEC"

# (iii-i) A crash BETWEEN the candidate write and the swap. The first design truncated the operator's
# file and restored it from memory inside `except HandleError`, so anything else — a signal, a
# MemoryError, a future non-HandleError raise — left the governed file mutated with the only good copy
# in a dead process. Injecting an OSError at the swap is that class, reproduced.
python3 - "$PLUGIN/scripts" "$REPO" "$REG" "$EXEC" <<'PY' || exit 1
import os, sys
scripts, repo, reg, execution = sys.argv[1:5]
sys.path.insert(0, scripts)
import idc_verification_handles as VH
before = open(reg, encoding='utf-8').read()
real_replace = os.replace
def boom(src, dst):
    raise OSError("simulated crash between the candidate write and the atomic swap")
os.replace = boom
try:
    VH.append_handle(repo, handle_id='crash-case', from_execution=execution)
except OSError:
    pass
except VH.HandleError as exc:
    raise SystemExit(f"FAIL: the injected fault was converted into a HandleError instead of propagating: {exc}")
else:
    raise SystemExit("FAIL: the injected OSError never propagated — the fault injection did not take")
finally:
    os.replace = real_replace
if open(reg, encoding='utf-8').read() != before:
    raise SystemExit("FAIL: FILE LEFT MUTATED — a fault outside HandleError left the operator's registry rewritten")
if os.path.exists(reg + '.append.tmp'):
    raise SystemExit("FAIL: the candidate temp file was left beside the operator's registry")
print("ok: a fault at the swap leaves the operator's registry byte-identical and no temp file behind")
PY
unchanged "the fault-injection case left the registry modified"

# ── (i) The real append: surface, evidence kind and verify_commands all derived from the PROVEN run.
python3 "$VH" append --repo "$REPO" --handle-id 'cli-first-drive' --from-execution "$EXEC" \
  --fixture 'seed:none' >/dev/null \
  || fail "appending a newly-proven recipe from a passing execution receipt failed"

grep -qF 'this header comment must survive an append' "$REG" \
  || fail "the append rewrote the whole file and destroyed the operator's header comments"

python3 - "$PLUGIN/scripts" "$REG" "$EXEC" <<'PY' || exit 1
import json, sys
scripts, reg_path, exec_path = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_schema_check as SC
doc = SC.load_verification_registry(reg_path)
execution = json.load(open(exec_path, encoding='utf-8'))
executed = [row['command'] for row in execution['verification']]
handles = {h['handle_id']: h for h in doc['handles']}
if 'cli-first-drive' not in handles:
    raise SystemExit(f"FAIL: the proven recipe was not appended: {sorted(handles)}")
entry = handles['cli-first-drive']
if entry['verify_commands'] != executed:
    raise SystemExit(
        f"FAIL: the appended recipe does not record the EXECUTED commands "
        f"{executed!r}; got {entry['verify_commands']!r}")
if entry['surface'] != execution['surface'] or entry['evidence_kind'] != execution['evidence_kind']:
    raise SystemExit(
        f"FAIL: the appended recipe lost the proven surface/evidence pairing: {entry!r}")
print("ok: the appended recipe records exactly the commands the frozen gate actually ran")
PY

# (ii) The whole file re-validates through the fixed schema checker AND resolves through fixed code.
python3 "$SCHEMA" registry "$REG" >/dev/null \
  || fail "the registry no longer passes its own schema check after an append"
python3 "$VH" resolve --repo "$REPO" --handle-id 'cli-first-drive' --surface cli >/dev/null \
  || fail "the appended handle does not resolve through the fixed resolver"

cp "$REG" "$WORK/registry.before"

# (iii-j) A duplicate id is refused, and the refusal leaves the file byte-identical.
refuses 'already exists' \
  "a duplicate handle_id silently replaced an existing registry entry" -- \
  --handle-id 'cli-first-drive' --from-execution "$EXEC"

# (iii-k) An execution receipt that ALREADY CITES a handle. A handle-backed run re-proves the recipe
# it looked up, so persisting it again is a second copy of an existing entry under a new id — the
# registry decays into near-duplicates and the lookup stops being a lookup. Reachable only now, since
# citing a handle requires the entry appended above to exist.
python3 "$VC" freeze \
  --repo "$REPO" --issue 41 --pr 741 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --surface cli --handle-id 'cli-first-drive' \
  --baseline expected-green --label handle-backed --out "$CONTRACT_DIR/handle-backed.json" >/dev/null \
  || fail "could not freeze a contract citing the newly appended handle"
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT_DIR/handle-backed.json" \
  --out "$EXEC_DIR/handle-backed.json" >/dev/null \
  || fail "could not execute the handle-backed contract"
refuses 'already cites handle_id' \
  "a handle-BACKED run was persisted again as if it were a newly proven recipe" -- \
  --handle-id 'cli-second-copy' --from-execution "$EXEC_DIR/handle-backed.json"

# (v) The write is an ORDINARY TRACKED FILE CHANGE on the ticket's branch — reviewable and merged
#     through the normal PR path, not a side-channel write outside the diff.
status="$(git -C "$REPO" status --porcelain -- docs/workflow/verification-handles.yaml)"
printf '%s\n' "$status" | grep -qE '^ ?M' \
  || fail "the append did not show up as a modified TRACKED file (git status: '${status:-<empty>}')"
git -C "$REPO" add docs/workflow/verification-handles.yaml
git -C "$REPO" diff --cached --name-only | grep -qxF 'docs/workflow/verification-handles.yaml' \
  || fail "the appended registry cannot be staged into the ticket's own commit"

# ── (vii) END TO END, in the SHIPPED ORDER, against a plan that allows the path ───────────────────
# The append is only useful if a finisher following the playbook can actually complete it. The
# previous playbook said: append → commit → mint. Every exit from that was closed — committing moved
# the head (`verification run against stale code`), leaving it uncommitted made `git worktree remove`
# refuse a dirty tree, and `docs/` in `off-limits` refused the path outright — so the documented step
# dead-ended whoever followed it. The shipped order is now append → COMMIT → RE-RUN the frozen gate →
# review → mint, and the plan-side half (registry inside `touch`, `docs/` not off-limits) is a Plan
# obligation in agents/idc-plan.md. This case walks exactly that, and the mint is the proof.
E2E="$WORK/repo-e2e"
git init -q -b main "$E2E"
git -C "$E2E" config user.email test@example.com
git -C "$E2E" config user.name tester
mkdir -p "$E2E/src/allowed" "$E2E/docs/workflow/build-validation" \
         "$E2E/docs/workflow/build-validation-executions" "$E2E/docs/workflow/build-receipts" \
         "$E2E/docs/workflow/code-reviews"
cp "$REPO/drive-surface.sh" "$E2E/drive-surface.sh"
chmod +x "$E2E/drive-surface.sh"
printf 'old behavior\n' > "$E2E/src/allowed/feature.txt"
cat > "$E2E/docs/workflow/verification-handles.yaml" <<'YAML'
schema_version: 1
handles: []
YAML
git -C "$E2E" add -A
git -C "$E2E" commit -qm init

E2E_CONTRACT="$E2E/docs/workflow/build-validation/e2e.json"
E2E_EXEC1="$E2E/docs/workflow/build-validation-executions/e2e-1.json"
E2E_EXEC2="$E2E/docs/workflow/build-validation-executions/e2e-2.json"
E2E_VERDICT="$E2E/docs/workflow/code-reviews/2026-07-27-pr-801-e2e.json"
E2E_RECEIPT="$E2E/docs/workflow/build-receipts/e2e.json"
# THE PLAN-SIDE HALF: the registry path is inside `touch`, and `off-limits` does not cover `docs/`.
python3 "$VC" freeze \
  --repo "$E2E" --issue 8 --pr 801 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --touch docs/workflow/verification-handles.yaml \
  --off-limits src/forbidden/ \
  --surface cli --evidence-kind pane-capture --verify 'bash drive-surface.sh' \
  --baseline expected-red --label e2e --out "$E2E_CONTRACT" >/dev/null \
  || fail "could not freeze the end-to-end contract"
printf 'new behavior\n' > "$E2E/src/allowed/feature.txt"
git -C "$E2E" add src/allowed/feature.txt
git -C "$E2E" commit -qm 'implement the behavior'
# 1. the gate runs green → the recipe is PROVEN
python3 "$VC" run --repo "$E2E" --contract "$E2E_CONTRACT" --out "$E2E_EXEC1" >/dev/null \
  || fail "the end-to-end gate did not execute"
# 2. append + commit, BEFORE the final gate run and the final review pass
python3 "$VH" append --repo "$E2E" --handle-id 'e2e-cli-drive' --from-execution "$E2E_EXEC1" >/dev/null \
  || fail "the end-to-end append was refused"
git -C "$E2E" add docs/workflow/verification-handles.yaml
git -C "$E2E" commit -qm 'persist the proven verification recipe'
# 3. re-run the frozen gate against the post-append commit — this is what re-binds head + diff
python3 "$VC" run --repo "$E2E" --contract "$E2E_CONTRACT" --out "$E2E_EXEC2" >/dev/null \
  || fail "the frozen gate did not re-run against the post-append commit"
# 4. the review pass binds the same head/diff (the existing review-until-PASS loop), then the mint
python3 - "$E2E_EXEC2" "$E2E_VERDICT" <<'PY' || fail "could not generate the end-to-end review verdict"
import json, sys
receipt = json.load(open(sys.argv[1], encoding='utf-8'))
verdict = {'verdict': 'PASS', 'issue': receipt['issue'], 'pr': receipt['pr'], 'head': receipt['head'],
           'diff_digest': receipt['diff_digest'], 'findings': []}
with open(sys.argv[2], 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
python3 "$RVC" "$E2E_VERDICT" >/dev/null 2>&1 \
  || fail "the generated end-to-end review verdict does not validate"
out="$(python3 "$BR" write \
  --repo "$E2E" --contract "$E2E_CONTRACT" --execution "$E2E_EXEC2" --verdict "$E2E_VERDICT" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$E2E_RECEIPT" 2>&1)" \
  || fail "THE SHIPPED ORDERING DEAD-ENDS: the implementation receipt refused the run that followed
  agents/idc-finisher.md step by step: $out"
python3 "$BR" verify --repo "$E2E" --receipt "$E2E_RECEIPT" --issue 8 --pr 801 >/dev/null \
  || fail "the end-to-end implementation receipt did not verify"
python3 - "$E2E_RECEIPT" <<'PY' || exit 1
import json, sys
receipt = json.load(open(sys.argv[1], encoding='utf-8'))
changed = receipt.get('changed_paths') or []
if 'docs/workflow/verification-handles.yaml' not in changed:
    raise SystemExit(
        "FAIL: the appended registry is NOT inside the receipt-bound diff — the whole point of the "
        f"ordering is that it is: {changed!r}")
print('ok: the appended recipe landed inside the receipt-bound diff and the receipt minted + verified')
PY
# …and the git state a finisher hands to `idc_git_finish.py` is CLEAN, which is the other exit the old
# ordering closed: an uncommitted append makes `git worktree remove` refuse a dirty worktree.
[ -z "$(git -C "$E2E" status --porcelain -- docs/workflow/verification-handles.yaml)" ] \
  || fail "the registry is still dirty after the append+commit step — git finalization would refuse the worktree"

# (vi) The shipped finisher playbook still names the append step, and names it in the order that
#      actually completes: append → re-run the frozen gate → mint the build receipt.
grep -qF 'idc_verification_handles.py' "$FINISHER" \
  || fail "agents/idc-finisher.md no longer names idc_verification_handles.py — the compounding step is gone"
grep -qE 'idc_verification_handles\.py"? append' "$FINISHER" \
  || fail 'agents/idc-finisher.md must name the append subcommand, not merely the helper'
grep -qF -- '--from-execution' "$FINISHER" \
  || fail 'agents/idc-finisher.md must invoke the append with --from-execution — the only mode the helper has'
python3 - "$FINISHER" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
def at(pattern):
    m = re.search(pattern, text)
    return m.start() if m else -1
append_at = at(r'idc_verification_handles\.py"?\s+append\b')
rerun_at = at(r'idc_validation_contract\.py"?\s+run\b')
mint_at = at(r'idc_build_receipt\.py"?\s+write\b')
if append_at < 0 or mint_at < 0:
    raise SystemExit(f"FAIL: could not locate both steps in the finisher playbook "
                     f"(append={append_at}, mint={mint_at})")
if rerun_at < 0:
    raise SystemExit(
        "FAIL: the finisher playbook never re-runs the frozen gate after the append. Without that "
        "re-run the execution receipt is bound to the pre-append head and the build receipt refuses "
        "it ('verification run against stale code'), which is the dead end this ordering exists to "
        "avoid")
if not (append_at < rerun_at < mint_at):
    raise SystemExit(
        f"FAIL: the finisher's steps are out of order (append={append_at}, gate re-run={rerun_at}, "
        f"receipt mint={mint_at}); the only ordering that completes is append -> re-run the frozen "
        f"gate -> mint")
# The escape hatch that described an impossible state. The receipt-bound diff IS `base_commit..HEAD`,
# so every commit on the ticket's branch is inside it; there is no "outside" to land in. A playbook
# sentence telling the finisher to aim for one sent it down a path with no exit.
dead = 'outside the receipt-bound diff'
if dead in text:
    raise SystemExit(
        f"FAIL: agents/idc-finisher.md still tells the finisher its append can land {dead!r}. The "
        "receipt-bound diff is base_commit..HEAD — a commit on the branch is always inside it")
print("ok: the finisher appends the proven recipe, re-runs the frozen gate, then mints the receipt")
PY

# (vi-b) THE PLAN-SIDE HALF, in the shipped playbooks. The end-to-end case above only completes
#        because the frozen contract put the registry inside `touch` and kept `docs/` out of
#        `off-limits`. The finisher cannot create that state — `--touch`/`--off-limits` are frozen at
#        Plan — so if the Plan playbooks do not carry the obligation, the finisher step above is
#        unreachable in every real repo and case (vii) is testing a state nobody can produce. BOTH
#        halves must be stated, because `off-limits` beats `touch`.
PLAN="$PLUGIN/agents/idc-plan.md"
WF="$PLUGIN/templates/WORKFLOW.md"
[ -f "$PLAN" ] || fail "agents/idc-plan.md not found at $PLAN"
[ -f "$WF" ] || fail "templates/WORKFLOW.md not found at $WF"
python3 - "$PLAN" "$WF" <<'PY' || exit 1
import sys
# SCOPED TO ONE PARAGRAPH, AND THE IMPERATIVE IS PART OF WHAT IS ASSERTED. Two weaker versions of
# this check were both satisfied by prose that states no obligation at all: a whole-FILE search hits
# `--touch` and the registry path in the unrelated RESOLVE-side text, and a paragraph search for the
# three nouns alone is still satisfied by the paragraph's trailing RATIONALE ("… outside `touch` or
# inside `off-limits` …") after the requirement sentence itself is deleted. Requiring `MUST NOT` in
# the same paragraph is what pins the second half of the obligation — the half that is easy to drop,
# because `touch` alone reads sufficient until you know `off-limits` beats it.
for path in sys.argv[1:]:
    paragraphs = open(path, encoding='utf-8').read().split('\n\n')
    if not any('docs/workflow/verification-handles.yaml' in p and 'touch' in p and 'off-limits' in p
               and 'MUST NOT' in p
               for p in paragraphs):
        raise SystemExit(
            f"FAIL: {path} never states the Plan-side boundary obligation in one place. A contract "
            "that cites no handle_id with surface != none must put "
            "docs/workflow/verification-handles.yaml in `touch` AND keep `docs/` out of `off-limits`; "
            "without BOTH halves stated together, the finisher's append step cannot be completed in "
            "any repo planned from this playbook")
print('ok: both Plan playbooks carry the touch/off-limits obligation the append step depends on')
PY

echo "PASS: a newly-proven recipe is appended back to the governed registry by fixed code, records the executed commands, re-validates, refuses retyped/out-of-repo/failing/handle-backed/secret-bearing/private-URL/missing-registry/malformed/contradicted/duplicate appends without touching the file, survives a fault at the swap, lands as a tracked diff, mints a bound implementation receipt end to end, and is wired into the finisher in the order that completes"
