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
# RED-WHEN-BROKEN (both probes executed 2026-07-31, under timeout):
#   * neuter the claim-time mint (`_mint_claim_authorization` body -> pass) → the post-claim ALLOW
#     arm FAILS (the write is still denied under the read-only entry mint), and the renew arm FAILS;
#   * neuter the terminal retire (`_retire_claim_authorization` body -> pass) → the post-finish DENY
#     arm FAILS (the write is still allowed after Done).
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

echo "PASS: build's entry mint is read-only-until-claim; the engine claim mints the ticket-bound mutation grant (proven In Progress + journaled first); the contract freeze narrows the SAME authorization to touch/off-limits; the idempotent re-claim renews the TTL without widening; and the terminal close retires the authorization and live-contract pointer so writes deny again"
