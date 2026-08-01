#!/bin/bash
# path-gate-contract-scoped-mint.sh — V-AUTH stage 1: the command-entry mint is CONTRACT-SCOPED.
#
# When a frozen Build validation contract is live, the entry gate mints the Path Gate authorization
# with allowed_paths = the contract's `touch` set and denied_paths = its `off_limits` set — so a
# write inside the repository but OUTSIDE `touch` (or inside `off_limits`) is DENIED at mutation
# time, instead of passing the gate and only failing the receipt diff later. With no live contract
# the command default applies, and an UNVERIFIABLE pointer fails the admission closed.
#
# RED-WHEN-BROKEN (both probes executed 2026-07-31, under timeout):
#   * revert the stage-1 mint change (drop `**profile` from _ensure_path_gate_auth so the entry mint
#     falls back to the bare default) → the entry auth is whole-repo again and the outside-`touch`
#     guarded arm FAILS (the write is allowed);
#   * delete the denied_paths enforcement loop in idc_path_gate._evaluate_request → the off-limits
#     guarded arm FAILS (the off-limits write inside `touch` is allowed).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/../lib/fail-closed.sh"

ENTRY="$GOV_PLUGIN/scripts/hooks/idc_command_entry_gate.py"
PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
VAL="$GOV_PLUGIN/scripts/idc_validation_contract.py"
fc_require_file "$ENTRY" "idc_command_entry_gate.py"
fc_require_file "$PATH_GATE" "idc_path_gate.py"
fc_require_file "$VAL" "idc_validation_contract.py"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src/vendor" "$REPO/tests"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
  git config user.email idc@example.test
  git config user.name 'IDC Contract Scoped Mint'
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"
printf 'vendored\n' > "$REPO/src/vendor/lib.ts"
printf 'test(1)\n' > "$REPO/tests/app.t"
printf 'exit 1\n' > "$REPO/verify.sh"
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$GOV_PLUGIN/.claude-plugin/plugin.json")"
printf 'receipt_version: 2\nplugin_version: %s\n' "$PLUGIN_VERSION" > "$REPO/docs/workflow/install-receipt.yaml"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'test: seed contract-scoped mint fixture'

# Freeze the REAL machine-owned validation contract (touch=src/, off-limits=src/vendor/) — the
# scope the entry mint must inherit comes from this frozen document, not a hand-fed list.
HEX64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
python3 "$VAL" freeze --repo "$REPO" --issue 7 --pr 7 --graph-node unit-7 \
  --graph-digest "$HEX64" --projection-digest "$HEX64" \
  --surface cli --verify 'bash verify.sh' --baseline expected-red \
  --touch src/ --off-limits src/vendor/ \
  --label vauth-scope --out "$REPO/docs/workflow/build-validation/vauth-scope.json" >/dev/null \
  || gov_fail "could not freeze the validation contract for the scoped-mint fixture"
LIVE_POINTER="$(python3 "$PATH_GATE" auth-path --repo "$REPO" | sed 's/authorization\.json$/live-contract.json/')"
[ -f "$LIVE_POINTER" ] \
  || gov_fail "freeze did not publish the live-contract pointer at $LIVE_POINTER — the minting side has no way to discover the frozen scope"

entry_payload() { SID="$1" REPO="$REPO" python3 - <<'PY'
import json, os
print(json.dumps({
    "session_id": os.environ["SID"], "cwd": os.environ["REPO"],
    "hook_event_name": "UserPromptExpansion", "expansion_type": "command",
    "command_name": "idc:build", "command_args": "demo", "command_source": "plugin",
    "prompt": "/idc:build demo"}))
PY
}

# ── the REAL entry-gate mint inherits the frozen contract's scope ────────────────────────────────
SID="pg-scope-$$-$(basename "$WORK")"
ENTRY_OUT="$(entry_payload "$SID" | timeout 60 python3 "$ENTRY" "$GOV_PLUGIN" 2>"$WORK/entry.err")"
printf '%s' "$ENTRY_OUT" | grep -q 'additionalContext' \
  || gov_fail "entry gate did not admit /idc:build over a live contract: [$ENTRY_OUT] stderr=[$(cat "$WORK/entry.err")]"
# POSITIVE CONTROL for the corrupt-pointer arm below: the clean admission does NOT block.
printf '%s' "$ENTRY_OUT" | grep -q '"decision": *"block"' \
  && gov_fail "clean admission unexpectedly blocked: $ENTRY_OUT"

AUTH_PATH="$(python3 "$PATH_GATE" auth-path --repo "$REPO")"
AUTH_PATH="$AUTH_PATH" python3 - <<'PY' || gov_fail "the entry mint did not inherit the frozen contract's touch/off-limits scope + identity"
import json, os, sys
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
problems = []
if auth.get("allowed_paths") != ["src"]:
    problems.append(f"allowed_paths={auth.get('allowed_paths')!r}, expected ['src'] (the contract's touch set)")
if auth.get("denied_paths") != ["src/vendor"]:
    problems.append(f"denied_paths={auth.get('denied_paths')!r}, expected ['src/vendor'] (the contract's off_limits set)")
if sorted(auth.get("allowed_actions") or []) != ["edit", "git", "write"]:
    problems.append(f"allowed_actions={auth.get('allowed_actions')!r}")
if auth.get("ticket") != "7":
    problems.append(f"ticket={auth.get('ticket')!r}, expected '7' (the contract's issue)")
if auth.get("graph_node") != "unit-7":
    problems.append(f"graph_node={auth.get('graph_node')!r}, expected 'unit-7'")
if problems:
    print("FAIL: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
PY

# ── boundary enforcement AT MUTATION TIME (the stage-1 headline) ─────────────────────────────────
# Requests carry the contract identity the authorization is bound to (ticket 7 / unit-7).
EVAL="$WORK/eval.sh"
cat > "$EVAL" <<SH
#!/bin/bash
printf '%s' "\$1" | python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN"
SH
chmod +x "$EVAL"
REQ_INSIDE='{"action":"write","paths":["src/app.ts"],"ticket":"7","graph_node":"unit-7"}'
REQ_OUTSIDE='{"action":"write","paths":["tests/app.t"],"ticket":"7","graph_node":"unit-7"}'
REQ_OFFLIMITS='{"action":"write","paths":["src/vendor/lib.ts"],"ticket":"7","graph_node":"unit-7"}'

assert_fail_closed "a write inside the repo but OUTSIDE the frozen touch set is denied at mutation time" \
  "outside the live authorization boundary" \
  -- bash "$EVAL" "$REQ_OUTSIDE" \
  -- bash "$EVAL" "$REQ_INSIDE"
assert_fail_closed "a write inside touch but INSIDE the frozen off-limits set is denied at mutation time (deny wins)" \
  "off-limits set" \
  -- bash "$EVAL" "$REQ_OFFLIMITS" \
  -- bash "$EVAL" "$REQ_INSIDE"

# ── an UNVERIFIABLE live contract fails the admission CLOSED (never a silent broad mint) ─────────
# The entry hook signals via block-JSON on exit 0, so this arm keys on the block decision plus the
# admission-refusal marker, with the CLEAN admission above as the positive control (no block, no
# marker) — the fail-closed.sh discriminating-artifact rule, applied to an exit-0 surface.
cp "$LIVE_POINTER" "$WORK/live-pointer.good"
printf 'not json at all\n' > "$LIVE_POINTER"
rm -f "$AUTH_PATH"
CORRUPT_OUT="$(entry_payload "$SID" | timeout 60 python3 "$ENTRY" "$GOV_PLUGIN" 2>"$WORK/corrupt.err")"
printf '%s' "$CORRUPT_OUT" | grep -q '"decision": *"block"' \
  || gov_fail "a corrupt live-contract pointer did not block the admission — the entry mint would silently fall back: [$CORRUPT_OUT]"
printf '%s' "$CORRUPT_OUT" | grep -q 'could not write the shared Path Gate authorization' \
  || gov_fail "the corrupt-pointer block did not carry the authorization-refusal marker: [$CORRUPT_OUT]"
[ ! -f "$AUTH_PATH" ] \
  || gov_fail "a BLOCKED admission still minted an authorization over the corrupt pointer: $(cat "$AUTH_PATH")"
cp "$WORK/live-pointer.good" "$LIVE_POINTER"

# ── fallback: with NO live contract, the entry mint applies the command default profile ──────────
REPO2="$WORK/repo2"; mkdir -p "$REPO2/docs/workflow" "$REPO2/src"
(
  cd "$REPO2"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO2/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO2/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO2/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO2/src/app.ts"
printf 'receipt_version: 2\nplugin_version: %s\n' "$PLUGIN_VERSION" > "$REPO2/docs/workflow/install-receipt.yaml"
SID2="pg-scope2-$$-$(basename "$WORK")"
ENTRY2_OUT="$(REPO="$REPO2" entry_payload "$SID2" | timeout 60 python3 "$ENTRY" "$GOV_PLUGIN" 2>"$WORK/entry2.err")"
printf '%s' "$ENTRY2_OUT" | grep -q 'additionalContext' \
  || gov_fail "entry gate did not admit /idc:build with no live contract: [$ENTRY2_OUT] stderr=[$(cat "$WORK/entry2.err")]"
AUTH2_PATH="$(python3 "$PATH_GATE" auth-path --repo "$REPO2")"
AUTH2_PATH="$AUTH2_PATH" GOV_PLUGIN="$GOV_PLUGIN" timeout 60 python3 - <<'PY' \
  || gov_fail "with no live contract the entry mint did not apply the command default profile"
import json, os, sys
sys.path.insert(0, os.environ["GOV_PLUGIN"] + "/scripts")
import idc_path_gate as PG
auth = json.load(open(os.environ["AUTH2_PATH"], encoding="utf-8"))
paths, actions = PG._default_profile("build")
if auth.get("allowed_paths") != PG._normalize_allowed_paths(".", list(paths)) \
        or sorted(auth.get("allowed_actions") or []) != sorted(actions) \
        or auth.get("denied_paths") != []:
    print(f"FAIL: no-contract entry mint granted paths={auth.get('allowed_paths')!r} "
          f"denied={auth.get('denied_paths')!r} actions={auth.get('allowed_actions')!r}, expected "
          f"the build default profile {paths!r}/{actions!r}", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: the command-entry mint is contract-scoped (allowed=touch, denied=off_limits, contract identity), outside-touch and off-limits writes are denied at mutation time with distinct markers, an unverifiable live-contract pointer fails the admission closed without minting, and a repo with no live contract falls back to the command default profile"
