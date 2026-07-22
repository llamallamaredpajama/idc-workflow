#!/bin/bash
# path-gate-boundaries.sh — the shared Path Gate core enforces auth-object integrity:
# missing auth denies, allowed paths/actions admit, protected machine-owned files stay denied,
# subprocess failures scrub child stderr at the read, and branch / ticket / graph-node /
# contract-digest / expiry mismatches all fail closed.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE (shared core not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src" "$REPO/tests"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"
printf 'test(1)\n' > "$REPO/tests/app.t"
SID="pg-boundary-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SID" --command build \
  --plugin-root "$GOV_PLUGIN" --args 'demo' --source user >/dev/null \
  || gov_fail "could not open the active /idc:build command record for $SID"
BRANCH="$(git -C "$REPO" branch --show-current)"

AUTH_PATH="$(python3 "$PATH_GATE" auth-path --repo "$REPO")" || gov_fail "could not locate the auth-object path"

emit_req() { ACTION="$1" PATHS="$2" TICKET="$3" GRAPH="$4" python3 - <<'PY'
import json, os
payload = {
    "action": os.environ["ACTION"],
    "paths": [p for p in os.environ["PATHS"].split(":") if p],
}
if os.environ["TICKET"]:
    payload["ticket"] = os.environ["TICKET"]
if os.environ["GRAPH"]:
    payload["graph_node"] = os.environ["GRAPH"]
print(json.dumps(payload))
PY
}

eval_gate() {
  OUT="$(emit_req "$1" "$2" "$3" "$4" | python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN" 2>"$WORK/err")"
  RC=$?
}
allow_case() {
  eval_gate "$1" "$2" "$3" "$4"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0, got $RC for action=$1 paths=$2 :: $(cat "$WORK/err")"
  printf '%s' "$OUT" | grep -q '"allowed": *true' || gov_fail "ALLOW expected allowed=true, got: $OUT"
}
deny_case() {
  eval_gate "$1" "$2" "$3" "$4"
  [ "$RC" -ne 0 ] || gov_fail "DENY expected non-zero exit for action=$1 paths=$2, got 0 with: $OUT"
  printf '%s' "$OUT" | grep -q '"allowed": *false' || gov_fail "DENY expected allowed=false, got: $OUT"
}

mutate_auth() { AUTH_PATH="$AUTH_PATH" MODE="$1" VALUE="${2:-}" python3 - <<'PY'
import json, os, datetime
path = os.environ["AUTH_PATH"]
mode = os.environ["MODE"]
value = os.environ.get("VALUE", "")
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
if mode == "branch":
    data["branch"] = value
elif mode == "contract_digest":
    data["contract_digest"] = value
elif mode == "expires_past":
    data["expires_at"] = "2000-01-01T00:00:00Z"
elif mode == "allowed_paths":
    data["allowed_paths"] = [value]
else:
    raise SystemExit(f"unknown mode: {mode}")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

authorize() {
  python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
    --branch "$BRANCH" --ticket T-42 --graph-node NODE-7 \
    --allow-action write --allow-action edit --allow-action git \
    --allow-path src --allow-path tests >/dev/null \
    || gov_fail "could not write a shared Path Gate authorization"
}

# Missing auth denies.
deny_case write src/app.ts T-42 NODE-7

authorize
allow_case write src/app.ts T-42 NODE-7
deny_case write docs/notes.md T-42 NODE-7
deny_case write TRACKER.md T-42 NODE-7

authorize
mutate_auth branch wrong/branch
deny_case write src/app.ts T-42 NODE-7

authorize
deny_case write src/app.ts WRONG-TICKET NODE-7

authorize
deny_case write src/app.ts T-42 WRONG-NODE

authorize
mutate_auth contract_digest deadbeef
deny_case write src/app.ts T-42 NODE-7

authorize
mutate_auth expires_past
deny_case write src/app.ts T-42 NODE-7

python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch "$BRANCH" --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git \
  --allow-path tests >/dev/null \
  || gov_fail "could not narrow the shared Path Gate authorization to tests/**"
deny_case write src/app.ts T-42 NODE-7
allow_case write tests/app.t T-42 NODE-7

FAKE_GIT_DIR="$WORK/fake-git-stderr"; mkdir -p "$FAKE_GIT_DIR"
cat >"$FAKE_GIT_DIR/git" <<'SH'
#!/bin/sh
printf 'fatal: Authorization: Basic QWxhZGRpbjpvcGVuc2VzYW1l while opening repo\n' >&2
exit 1
SH
chmod +x "$FAKE_GIT_DIR/git"
PATH="$FAKE_GIT_DIR:$PATH" \
  python3 "$PATH_GATE" auth-path --repo "$REPO" >"$WORK/auth-path.out" 2>"$WORK/auth-path.err"
RC=$?
[ "$RC" -ne 0 ] || gov_fail "auth-path unexpectedly succeeded through a failing git child"
! grep -Fq 'QWxhZGRpbjpvcGVuc2VzYW1l' "$WORK/auth-path.out" \
  || gov_fail "auth-path leaked a Basic credential from child stderr: $(cat "$WORK/auth-path.out")"
grep -Fq 'IDC Path Gate infrastructure error:' "$WORK/auth-path.out" \
  || gov_fail "auth-path hid the infrastructure error context: $(cat "$WORK/auth-path.out")"
grep -Fq '[REDACTED]' "$WORK/auth-path.out" \
  || gov_fail "auth-path did not preserve a scrubbed diagnostic marker: $(cat "$WORK/auth-path.out")"
grep -Fq 'while opening repo' "$WORK/auth-path.out" \
  || gov_fail "auth-path lost the useful git failure detail after scrubbing: $(cat "$WORK/auth-path.out")"

echo "PASS: shared Path Gate boundaries hold (missing auth, protected paths, branch/ticket/graph-node/contract-digest/expiry mismatches all fail closed)"
