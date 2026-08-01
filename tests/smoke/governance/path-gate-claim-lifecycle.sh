#!/bin/bash
# path-gate-claim-lifecycle.sh — V-AUTH stage 2: the claim transaction is the write-authority seam.
#
# The lifecycle this proves, end to end through the REAL doors (entry hook, transition engine,
# validation-contract freeze):
#   entry mint (build)     -> read-only-until-claim: a source write DENIES before any claim;
#   engine `claim`         -> mints the claim-scoped authorization (ticket-bound, mutations): ALLOW;
#   contract freeze        -> narrows the SAME authorization to touch/off-limits;
#   idempotent re-claim    -> the sanctioned RENEW door: a fresh TTL window is re-minted;
#   engine `close`         -> retires the authorization + live-contract pointer: DENY again.
#
# RED-WHEN-BROKEN (all probes executed 2026-07-31, under timeout):
#   * neuter the claim-time mint (`_mint_claim_authorization` body -> pass) → the post-claim ALLOW
#     arm FAILS (the write is still denied under the read-only entry mint), and the renew arm FAILS;
#   * neuter the shared retire (`retire_claim_authorization` body -> pass) → BOTH the ENGINE post-finish
#     DENY arm (§5) AND the FINISHER retire arm (§6) FAIL (writes stay allowed / auth stays bound);
#   * neuter ONLY the finisher's retire call (`idc_git_finish.py:653` -> a no-op) → the §6 FINISHER arm
#     FAILS while §5 (the engine door) stays GREEN — the second close door's own red-when-broken proof;
#   * delete the ticket≠issue refusal in `narrow_authorization_to_contract` (~idc_path_gate.py:679) →
#     the §7 A3 cross-unit freeze SUCCEEDS (no marker) → that arm FAILS;
#   * delete the `expected_issue` mismatch branch in `clear_live_contract` (~idc_path_gate.py:272) →
#     the §7 A2 retire of unit B CLEARS unit A's pointer → that arm FAILS.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/../lib/fail-closed.sh"

ENTRY="$GOV_PLUGIN/scripts/hooks/idc_command_entry_gate.py"
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
VAL="$GOV_PLUGIN/scripts/idc_validation_contract.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
for f in "$ENTRY" "$ENGINE" "$PATH_GATE" "$VAL" "$CONTRACT" "$CHECK"; do
  fc_require_file "$f" "$(basename "$f")"
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow/code-reviews" "$REPO/src/vendor" "$REPO/tests"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
  git config user.email idc@example.test
  git config user.name 'IDC Claim Lifecycle'
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"
printf 'vendored\n' > "$REPO/src/vendor/lib.ts"
printf 'test(1)\n' > "$REPO/tests/app.t"
printf 'exit 1\n' > "$REPO/verify.sh"
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$GOV_PLUGIN/.claude-plugin/plugin.json")"
printf 'receipt_version: 2\nplugin_version: %s\n' "$PLUGIN_VERSION" > "$REPO/docs/workflow/install-receipt.yaml"
python3 "$GOV_TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "tracker init failed"
NUM="$(gov_seed_item "$REPO/TRACKER.md" --title 'claim lifecycle unit' --stage Buildable --status Todo)" \
  || gov_fail "could not seed the Buildable item"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'test: seed claim-lifecycle fixture'

eng() { python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$REPO/TRACKER.md" "$@"; }
EVAL="$WORK/eval.sh"
cat > "$EVAL" <<SH
#!/bin/bash
printf '%s' "\$1" | python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN"
SH
chmod +x "$EVAL"
# Requests echo the ticket/graph-node identity the LIVE authorization carries — exactly what the
# runtime adapters do.
REQ_ENTRY='{"action":"write","paths":["src/app.ts"],"graph_node":"command:build"}'
REQ_CLAIMED='{"action":"write","paths":["src/app.ts"],"ticket":"'"$NUM"'","graph_node":"ticket:'"$NUM"'"}'
REQ_FROZEN_IN='{"action":"write","paths":["src/app.ts"],"ticket":"'"$NUM"'","graph_node":"unit-'"$NUM"'"}'
REQ_FROZEN_OUT='{"action":"write","paths":["tests/app.t"],"ticket":"'"$NUM"'","graph_node":"unit-'"$NUM"'"}'

# ── 1. entry mint: read-only-until-claim ─────────────────────────────────────────────────────────
SID="pg-claim-$$-$(basename "$WORK")"
ENTRY_OUT="$(SID="$SID" REPO="$REPO" python3 - <<'PY' | timeout 60 python3 "$ENTRY" "$GOV_PLUGIN" 2>"$WORK/entry.err"
import json, os
print(json.dumps({
    "session_id": os.environ["SID"], "cwd": os.environ["REPO"],
    "hook_event_name": "UserPromptExpansion", "expansion_type": "command",
    "command_name": "idc:build", "command_args": "demo", "command_source": "plugin",
    "prompt": "/idc:build demo"}))
PY
)"
printf '%s' "$ENTRY_OUT" | grep -q 'additionalContext' \
  || gov_fail "entry gate did not admit /idc:build: [$ENTRY_OUT] stderr=[$(cat "$WORK/entry.err")]"
AUTH_PATH="$(python3 "$PATH_GATE" auth-path --repo "$REPO")"
AUTH_PATH="$AUTH_PATH" python3 - <<'PY' || gov_fail "the build entry mint is not read-only-until-claim"
import json, os, sys
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
if auth.get("allowed_actions") != [] or auth.get("ticket") is not None:
    print(f"FAIL: entry mint granted actions={auth.get('allowed_actions')!r} "
          f"ticket={auth.get('ticket')!r}, expected no mutation actions and no ticket before a "
          "claim", file=sys.stderr)
    sys.exit(1)
PY

# Pre-claim, a source write DENIES — and the claim is what flips it, so the post-claim ALLOW below
# is this assertion's positive control (the fail-closed.sh discriminating-marker rule).
PRE_OUT="$(timeout 60 bash "$EVAL" "$REQ_ENTRY")"; PRE_RC=$?
[ "$PRE_RC" -ne 0 ] || gov_fail "a source write was ALLOWED before any claim: $PRE_OUT"
printf '%s' "$PRE_OUT" | grep -q 'not in the live authorization' \
  || gov_fail "the pre-claim denial did not key on the action grant (read-only-until-claim): $PRE_OUT"

# ── 2. the claim transaction mints write authority ───────────────────────────────────────────────
eng claim --num "$NUM" --agent lifecycle-tester >/dev/null \
  || gov_fail "engine claim failed"
AUTH_PATH="$AUTH_PATH" NUM="$NUM" python3 - <<'PY' || gov_fail "the claim did not mint the claim-scoped authorization"
import json, os, sys
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
num = os.environ["NUM"]
problems = []
if auth.get("ticket") != num:
    problems.append(f"ticket={auth.get('ticket')!r}, expected {num!r}")
if auth.get("graph_node") != f"ticket:{num}":
    problems.append(f"graph_node={auth.get('graph_node')!r}, expected 'ticket:{num}'")
if sorted(auth.get("allowed_actions") or []) != ["edit", "git", "write"]:
    problems.append(f"allowed_actions={auth.get('allowed_actions')!r}")
if auth.get("allowed_paths") != ["."]:
    problems.append(f"allowed_paths={auth.get('allowed_paths')!r} (pre-freeze claim is repo-wide)")
if problems:
    print("FAIL: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
PY
POST_OUT="$(timeout 60 bash "$EVAL" "$REQ_CLAIMED")"; POST_RC=$?
[ "$POST_RC" -eq 0 ] || gov_fail "a source write inside scope was DENIED after the claim: $POST_OUT"
printf '%s' "$POST_OUT" | grep -q 'not in the live authorization' \
  && gov_fail "the post-claim allow still carried the read-only marker: $POST_OUT"

# ── 3. the freeze narrows the claim authorization to touch/off-limits ────────────────────────────
HEX64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
python3 "$VAL" freeze --repo "$REPO" --issue "$NUM" --pr "$NUM" --graph-node "unit-$NUM" \
  --graph-digest "$HEX64" --projection-digest "$HEX64" \
  --surface cli --verify 'bash verify.sh' --baseline expected-red \
  --touch src/ --off-limits src/vendor/ \
  --label vauth-lifecycle --out "$REPO/docs/workflow/build-validation/vauth-lifecycle.json" >/dev/null \
  || gov_fail "could not freeze the validation contract post-claim"
AUTH_PATH="$AUTH_PATH" NUM="$NUM" python3 - <<'PY' || gov_fail "the freeze did not narrow the live claim authorization to the contract boundary"
import json, os, sys
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
num = os.environ["NUM"]
if auth.get("allowed_paths") != ["src"] or auth.get("denied_paths") != ["src/vendor"] \
        or auth.get("ticket") != num or auth.get("graph_node") != f"unit-{num}":
    print(f"FAIL: post-freeze auth is paths={auth.get('allowed_paths')!r} "
          f"denied={auth.get('denied_paths')!r} ticket={auth.get('ticket')!r} "
          f"graph_node={auth.get('graph_node')!r}", file=sys.stderr)
    sys.exit(1)
PY
assert_fail_closed "post-freeze, a write outside the frozen touch set denies while in-touch writes stay allowed" \
  "outside the live authorization boundary" \
  -- bash "$EVAL" "$REQ_FROZEN_OUT" \
  -- bash "$EVAL" "$REQ_FROZEN_IN"

# ── 3b. the authorization is BOUND to the frozen contract (V-AUTH stage 3) ───────────────────────
# The post-freeze authorization carries the frozen contract's own digest; if a DIFFERENT contract
# becomes the live one (here: the pointer's digest is swapped), the authorization dies — even
# though every other field still verifies. The in-touch ALLOW above/below is the positive control.
LIVE_POINTER="$(printf '%s' "$AUTH_PATH" | sed 's/authorization\.json$/live-contract.json/')"
cp "$LIVE_POINTER" "$WORK/pointer.good"
LIVE_POINTER="$LIVE_POINTER" python3 - <<'PY'
import json, os
path = os.environ["LIVE_POINTER"]
doc = json.load(open(path, encoding="utf-8"))
doc["contract_digest"] = "f" * 64
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
# The positive control restores the true pointer FIRST, then re-runs the identical request — the
# marker must vanish with the tamper, proving it discriminates the binding, not the request shape.
assert_fail_closed "an authorization minted under one frozen contract dies when a different contract becomes the live one" \
  "no longer the live contract" \
  -- bash "$EVAL" "$REQ_FROZEN_IN" \
  -- bash -c "cp '$WORK/pointer.good' '$LIVE_POINTER' && bash '$EVAL' '$REQ_FROZEN_IN'"

# ── 4. renewal: the idempotent re-claim re-mints a fresh TTL window ──────────────────────────────
EXPIRES_BEFORE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["expires_at"])' "$AUTH_PATH")"
sleep 1
eng claim --num "$NUM" --agent lifecycle-tester >/dev/null \
  || gov_fail "idempotent re-claim (the renew door) failed"
EXPIRES_AFTER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["expires_at"])' "$AUTH_PATH")"
[ "$EXPIRES_AFTER" \> "$EXPIRES_BEFORE" ] \
  || gov_fail "the idempotent re-claim did not renew the authorization TTL (before=$EXPIRES_BEFORE after=$EXPIRES_AFTER)"
# The renewed mint keeps the frozen contract's narrowed scope (renewal never widens).
python3 -c '
import json, sys
auth = json.load(open(sys.argv[1]))
assert auth["allowed_paths"] == ["src"] and auth["denied_paths"] == ["src/vendor"], auth
' "$AUTH_PATH" || gov_fail "the renewal widened the narrowed scope"

# ── 5. the terminal close retires the authorization and the live contract ────────────────────────
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
VERDICT_PATH="$REPO/docs/workflow/code-reviews/2026-07-31-pr-$NUM-review.json"
NUM="$NUM" HEAD_SHA="$HEAD_SHA" HEX64="$HEX64" VERDICT_PATH="$VERDICT_PATH" python3 - <<'PY'
import json, os
verdict = {
    "verdict": "PASS",
    "pr": int(os.environ["NUM"]),
    "issue": int(os.environ["NUM"]),
    "head": os.environ["HEAD_SHA"],
    "diff_digest": os.environ["HEX64"],
    "findings": [],
}
with open(os.environ["VERDICT_PATH"], "w", encoding="utf-8") as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
python3 "$CHECK" "$VERDICT_PATH" >/dev/null || gov_fail "the PASS verdict did not validate (witness not recorded)"
eng close --num "$NUM" --verdict "$VERDICT_PATH" --pr "$NUM" >/dev/null \
  || gov_fail "engine close failed"
[ "$(gov_field "$REPO/TRACKER.md" "$NUM" Status)" = "Done" ] || gov_fail "close did not land Done"
LIVE_POINTER="$(printf '%s' "$AUTH_PATH" | sed 's/authorization\.json$/live-contract.json/')"
[ ! -f "$LIVE_POINTER" ] \
  || gov_fail "the terminal close left the live-contract pointer in place: $(cat "$LIVE_POINTER")"
AUTH_PATH="$AUTH_PATH" python3 - <<'PY' || gov_fail "the terminal close did not retire the claim authorization to the read-only entry posture"
import json, os, sys
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
if auth.get("allowed_actions") != [] or auth.get("ticket") is not None:
    print(f"FAIL: post-finish auth still grants actions={auth.get('allowed_actions')!r} "
          f"ticket={auth.get('ticket')!r}", file=sys.stderr)
    sys.exit(1)
PY
# Post-finish, a source write DENIES again — the post-claim ALLOW above is the positive control.
FIN_OUT="$(timeout 60 bash "$EVAL" "$REQ_ENTRY")"; FIN_RC=$?
[ "$FIN_RC" -ne 0 ] || gov_fail "a source write was still ALLOWED after the terminal close: $FIN_OUT"
printf '%s' "$FIN_OUT" | grep -q 'not in the live authorization' \
  || gov_fail "the post-finish denial did not key on the retired action grant: $FIN_OUT"

# ── shared helpers for the fresh-repo arms below (§6, §7) ────────────────────────────────────────
scaffold_governed() {   # <repo-dir> — a minimal governed filesystem-backend repo, tracker init'd
  local R="$1"; mkdir -p "$R/docs/workflow" "$R/src/vendor" "$R/tests"
  ( cd "$R"; git init -q; git checkout -q -b main
    git config user.email idc@example.test; git config user.name 'IDC Claim Lifecycle' )
  printf 'backend: filesystem\n' > "$R/docs/workflow/tracker-config.yaml"
  printf 'pathway_enforcement:\n  mode: controlled\n' > "$R/WORKFLOW-config.yaml"
  printf 'export const x = 1;\n' > "$R/src/app.ts"
  printf 'vendored\n' > "$R/src/vendor/lib.ts"
  printf 'exit 1\n' > "$R/verify.sh"
  printf 'receipt_version: 2\nplugin_version: %s\n' "$PLUGIN_VERSION" > "$R/docs/workflow/install-receipt.yaml"
  python3 "$GOV_TRK" --tracker "$R/TRACKER.md" init >/dev/null || gov_fail "scaffold: tracker init failed for $R"
}
open_build_record() {   # <repo-dir> <session-id> — opens an ACTIVE build record (mints NOTHING itself)
  python3 "$CONTRACT" start --repo "$1" --session "$2" --command build --plugin-root "$GOV_PLUGIN" >/dev/null 2>&1 \
    || gov_fail "could not open the build command record in $1"
}

# ── 6. the FINISHER close is the SECOND sanctioned retire door (review finding A1) ────────────────
# §5 proved the ENGINE close retires. The finisher (idc_git_finish.tracker_close) is the OTHER
# sanctioned close door; spec §4.2 claims BOTH retire, but only the engine had red-when-broken
# evidence. This arm mints a fresh claim, freezes so a live-contract pointer exists to retire, runs
# the REAL finisher close, and asserts the authorization AND the pointer are retired. Neuter
# idc_git_finish.py:653 → this arm reds while §5 stays green (the finisher's own coverage).
REPO_FIN="$WORK/repo-fin"; scaffold_governed "$REPO_FIN"
FIN_NUM="$(gov_seed_item "$REPO_FIN/TRACKER.md" --title 'finisher retire unit' --stage Buildable --status Todo)" \
  || gov_fail "could not seed the finisher-arm item"
git -C "$REPO_FIN" add -A; git -C "$REPO_FIN" commit -qm 'test: seed finisher-arm fixture'
open_build_record "$REPO_FIN" "pg-fin-$$-$(basename "$WORK")"
python3 "$ENGINE" --repo "$REPO_FIN" --backend filesystem --tracker "$REPO_FIN/TRACKER.md" \
  claim --num "$FIN_NUM" --agent finisher-arm >/dev/null || gov_fail "finisher-arm claim failed"
python3 "$VAL" freeze --repo "$REPO_FIN" --issue "$FIN_NUM" --pr "$FIN_NUM" --graph-node "unit-$FIN_NUM" \
  --graph-digest "$HEX64" --projection-digest "$HEX64" --surface cli --verify 'bash verify.sh' \
  --baseline expected-red --touch src/ --off-limits src/vendor/ \
  --label finisher-arm --out "$REPO_FIN/docs/workflow/build-validation/finisher-arm.json" >/dev/null \
  || gov_fail "finisher-arm: could not freeze the validation contract"
FIN_AUTH="$(python3 "$PATH_GATE" auth-path --repo "$REPO_FIN")"
FIN_POINTER="$(printf '%s' "$FIN_AUTH" | sed 's/authorization\.json$/live-contract.json/')"
# Precondition — the setup REACHES the retire door: the grant is bound to this ticket AND a live
# pointer exists, so a working retire has something to clear and a broken one leaves both behind.
FIN_AUTH="$FIN_AUTH" FIN_NUM="$FIN_NUM" python3 - <<'PY' || gov_fail "finisher-arm: the claim+freeze did not leave a ticket-bound grant (the retire would prove nothing)"
import json, os, sys
a = json.load(open(os.environ["FIN_AUTH"], encoding="utf-8"))
if a.get("ticket") != os.environ["FIN_NUM"] or sorted(a.get("allowed_actions") or []) != ["edit", "git", "write"]:
    print(f"FAIL: pre-close auth ticket={a.get('ticket')!r} actions={a.get('allowed_actions')!r}", file=sys.stderr); sys.exit(1)
PY
[ -f "$FIN_POINTER" ] || gov_fail "finisher-arm: the freeze did not publish a live-contract pointer to retire"
# Drive the REAL finisher close door (idc_git_finish.tracker_close, filesystem backend).
timeout 60 python3 - "$GOV_PLUGIN/scripts" "$REPO_FIN" "$FIN_NUM" <<'PY' || gov_fail "the finisher tracker_close raised or timed out"
import sys
sys.path.insert(0, sys.argv[1])
import idc_git_finish as GF
scripts, repo, num = sys.argv[1:4]
GF.tracker_close("filesystem", repo, int(num), repo + "/TRACKER.md", None, None, None, None)
PY
[ "$(gov_field "$REPO_FIN/TRACKER.md" "$FIN_NUM" Status)" = "Done" ] || gov_fail "the finisher close did not land Done"
[ ! -f "$FIN_POINTER" ] \
  || gov_fail "the FINISHER close left the live-contract pointer in place (idc_git_finish.py:653 uncovered): $(cat "$FIN_POINTER")"
FIN_AUTH="$FIN_AUTH" python3 - <<'PY' || gov_fail "the FINISHER close did not retire the claim authorization to the read-only posture (idc_git_finish.py:653 uncovered)"
import json, os, sys
a = json.load(open(os.environ["FIN_AUTH"], encoding="utf-8"))
if a.get("allowed_actions") != [] or a.get("ticket") is not None:
    print(f"FAIL: post-finisher-close auth still grants actions={a.get('allowed_actions')!r} ticket={a.get('ticket')!r}", file=sys.stderr); sys.exit(1)
PY
echo "  ok the FINISHER close (idc_git_finish.tracker_close) retires the claim authorization + live-contract pointer — the SECOND sanctioned close door has its own red-when-broken evidence"

# ── 7. CROSS-UNIT isolation: the freeze/retire doors REFUSE to act across unit boundaries (A2/A3) ─
# Two units A and B share ONE worktree's single authorization + live-contract pointer. Two guards keep
# one unit's freeze/terminal op from corrupting the OTHER unit's live state:
#   A3 (narrow_authorization_to_contract): a freeze for unit B while the live authorization is bound to
#      unit A REFUSES — a cross-unit narrowing is unit-identity confusion, not a legal narrowing;
#   A2 (clear_live_contract): retiring unit B while the live-contract pointer belongs to unit A LEAVES
#      A's pointer in place — a terminal op never clears another unit's live contract.
REPO_XU="$WORK/repo-xunit"; scaffold_governed "$REPO_XU"
XU_A="$(gov_seed_item "$REPO_XU/TRACKER.md" --title 'cross-unit A' --stage Buildable --status Todo)" || gov_fail "seed cross-unit A"
XU_B="$(gov_seed_item "$REPO_XU/TRACKER.md" --title 'cross-unit B' --stage Buildable --status Todo)" || gov_fail "seed cross-unit B"
git -C "$REPO_XU" add -A; git -C "$REPO_XU" commit -qm 'test: seed cross-unit fixture'
open_build_record "$REPO_XU" "pg-xunit-$$-$(basename "$WORK")"
python3 "$ENGINE" --repo "$REPO_XU" --backend filesystem --tracker "$REPO_XU/TRACKER.md" \
  claim --num "$XU_A" --agent xunit >/dev/null || gov_fail "cross-unit claim of A failed"
XU_AUTH="$(python3 "$PATH_GATE" auth-path --repo "$REPO_XU")"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ticket"))' "$XU_AUTH")" = "$XU_A" ] \
  || gov_fail "cross-unit setup: the live authorization is not bound to unit A (the narrow guard would be unreached)"
FREEZE_XU="$WORK/freeze-xu.sh"
cat > "$FREEZE_XU" <<SH
#!/bin/bash
python3 "$VAL" freeze --repo "$REPO_XU" --issue "\$1" --pr "\$1" --graph-node "unit-\$1" --graph-digest "$HEX64" --projection-digest "$HEX64" --surface cli --verify 'bash verify.sh' --baseline expected-red --touch src/ --off-limits src/vendor/ --label "xu-\$1" --out "$REPO_XU/docs/workflow/build-validation/xu-\$1.json"
SH
chmod +x "$FREEZE_XU"
# A3: the freeze for unit B refuses (bound to A); the freeze for unit A (positive control) does not —
# proving the marker keys the cross-unit BINDING, not "any freeze fails".
assert_fail_closed "a validation-contract freeze for unit B refuses while the live authorization is bound to unit A" \
  "refusing the cross-unit narrowing" \
  -- bash "$FREEZE_XU" "$XU_B" \
  -- bash "$FREEZE_XU" "$XU_A"
# The control freeze for A left the live-contract pointer belonging to unit A — the A2 setup.
XU_POINTER="$(printf '%s' "$XU_AUTH" | sed 's/authorization\.json$/live-contract.json/')"
[ -f "$XU_POINTER" ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("issue"))' "$XU_POINTER")" = "$XU_A" ] \
  || gov_fail "cross-unit A2 setup: the live-contract pointer does not belong to unit A (the clear guard would be unreached)"
retire_unit() {   # <num> — the EXACT retire door idc_git_finish.py:653 / the engine terminal op call
  timeout 60 python3 - "$GOV_PLUGIN/scripts" "$REPO_XU" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import idc_path_gate as PG
ok, detail = PG.retire_claim_authorization(sys.argv[2], int(sys.argv[3]))
print(f"retire #{sys.argv[3]}: ok={ok} detail={detail!r}")
PY
}
# A2 guarded: retiring unit B must LEAVE unit A's live contract in place.
retire_unit "$XU_B" >/dev/null || gov_fail "cross-unit retire of B raised or timed out"
[ -f "$XU_POINTER" ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("issue"))' "$XU_POINTER")" = "$XU_A" ] \
  || gov_fail "retiring unit B CLEARED unit A's live contract — the cross-unit clear guard is defeated"
# A2 positive control: retiring unit A (its OWN contract) removes the pointer — so the survival above
# was the guard refusing, not a retire that cannot remove anything.
retire_unit "$XU_A" >/dev/null || gov_fail "same-unit retire of A raised or timed out"
[ ! -f "$XU_POINTER" ] \
  || gov_fail "retiring unit A (its OWN contract) did NOT remove the pointer — the retire is inert, so A2's survival proves nothing"
echo "  ok cross-unit isolation holds: a freeze for another unit REFUSES (narrow), and a terminal retire never clears another unit's live contract (clear) — each with its own positive control"

echo "PASS: build's entry mint is read-only-until-claim; the engine claim mints the ticket-bound mutation grant (proven In Progress + journaled first); the contract freeze narrows the SAME authorization to touch/off-limits; the idempotent re-claim renews the TTL without widening; the ENGINE and FINISHER close doors BOTH retire the authorization and live-contract pointer so writes deny again; and the freeze/retire doors refuse to act across unit boundaries (cross-unit narrow + clear)"
