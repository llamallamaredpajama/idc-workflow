#!/bin/bash
# path-gate-overhead.sh — clean Path Gate checks stay local: no model/agent binary is invoked on the
# hot path for a simple allow/deny decision.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE (shared core not implemented yet)"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"
SID="pg-fast-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SID" --command build \
  --plugin-root "$GOV_PLUGIN" --args 'demo' --source user >/dev/null \
  || gov_fail "could not open the active /idc:build command record for $SID"
BRANCH="$(git -C "$REPO" branch --show-current)"
python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch "$BRANCH" --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git --allow-path src >/dev/null \
  || gov_fail "could not write a shared Path Gate authorization"

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for bin in claude codex pi; do
  cat > "$FAKEBIN/$bin" <<'SH'
#!/bin/sh
printf '%s\n' "$0" >> "$IDC_PATH_GATE_MODEL_LOG"
exit 97
SH
  chmod +x "$FAKEBIN/$bin"
done
MODEL_LOG="$WORK/model.log"
export IDC_PATH_GATE_MODEL_LOG="$MODEL_LOG"
PATH="$FAKEBIN:$PATH"

emit_req() { ACTION="$1" PATHS="$2" python3 - <<'PY'
import json, os
print(json.dumps({"action": os.environ["ACTION"], "paths": [p for p in os.environ["PATHS"].split(":") if p], "ticket": "T-42", "graph_node": "NODE-7"}))
PY
}

ALLOW_OUT="$(emit_req write src/app.ts | python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN")" \
  || gov_fail "authorized hot-path evaluation failed"
printf '%s' "$ALLOW_OUT" | grep -q '"allowed": *true' || gov_fail "authorized hot-path evaluation was not allowed: $ALLOW_OUT"
DENY_OUT="$(emit_req write TRACKER.md | python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN" 2>"$WORK/deny.err"; printf 'rc=%s' "$?")"
printf '%s' "$DENY_OUT" | grep -q 'rc=0' && gov_fail "protected-path hot-path evaluation unexpectedly exited 0: $DENY_OUT"
[ ! -s "$MODEL_LOG" ] || gov_fail "Path Gate hot path invoked a model/agent binary: $(cat "$MODEL_LOG")"

echo "PASS: the Path Gate hot path stays local (no claude/codex/pi invocation on a simple allow/deny)"
