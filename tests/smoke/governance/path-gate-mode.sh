#!/bin/bash
# path-gate-mode.sh — the shared Path Gate observes by default and enforces only when opted in.
# One fixture flips off -> controlled so the Claude and git transports prove both postures against
# the same would-be denials. The core scanner also fails soft to off for missing/unreadable/unknown
# configuration and keeps app-locked enforcement plus the observe-only override explicit.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
GIT_GATE="$GOV_PLUGIN/scripts/idc_git_path_gate.py"
INTERLOCK="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
HOOKS="$GOV_PLUGIN/hooks/hooks.json"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE"
[ -f "$GIT_GATE" ] || gov_fail "idc_git_path_gate.py not found at $GIT_GATE"
[ -f "$INTERLOCK" ] || gov_fail "idc_interlock_gate.py not found at $INTERLOCK"
[ -f "$HOOKS" ] || gov_fail "hooks.json not found at $HOOKS"

python3 - "$HOOKS" <<'PY' || gov_fail "NotebookEdit is not registered as a Path Gate PreToolUse transport"
import json, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]["PreToolUse"]
assert any(entry.get("matcher") == "NotebookEdit" for entry in hooks)
PY

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; REMOTE="$WORK/remote.git"
mkdir -p "$REPO/docs/workflow" "$REPO/src"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
  git config user.email idc@example.test
  git config user.name 'IDC Path Gate Mode'
)
git init --bare -q "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: off\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/x.ts"
git -C "$REPO" add .
git -C "$REPO" commit -qm 'test: seed mode fixture'
git -C "$REPO" push -u origin main >/dev/null 2>&1
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'ticket: committed bypass\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: seed pre-push denial'
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'ticket: staged bypass\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md

python3 "$GIT_GATE" install-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "git hook installation must remain unconditional in off mode"
python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "git hook verification must remain unconditional in off mode"

SID="pg-mode-$$-$(basename "$WORK")"
ERR="$WORK/interlock.err"
emit_tool() { TOOL="$1" VALUE="$2" SID="$SID" REPO="$REPO" python3 - <<'PY'
import json, os
tool = os.environ["TOOL"]
value = os.environ["VALUE"]
payload = {"cwd": os.environ["REPO"], "tool_name": tool, "session_id": os.environ["SID"]}
if tool == "Bash":
    payload["tool_input"] = {"command": value}
elif tool == "NotebookEdit":
    payload["tool_input"] = {"notebook_path": value}
else:
    payload["tool_input"] = {"file_path": value}
print(json.dumps(payload))
PY
}

gate() { OUT="$(emit_tool "$1" "$2" | python3 "$INTERLOCK" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }
is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }
observe_case() {
  gate "$1" "$2"
  [ "$RC" -eq 0 ] || gov_fail "off-mode $1 transport exited $RC for $2: $(cat "$ERR")"
  ! is_deny || gov_fail "off mode emitted a hard deny for $1:$2: $OUT"
  printf '%s' "$OUT" | grep -q '"additionalContext"' \
    || gov_fail "off mode did not use Claude additionalContext for $1:$2: stdout=[$OUT] stderr=[$(cat "$ERR")]"
  printf '%s' "$OUT" | grep -qi 'observe' \
    || gov_fail "off mode did not emit an observe line for $1:$2: $OUT"
}
deny_case() {
  gate "$1" "$2"
  [ "$RC" -eq 0 ] || gov_fail "controlled-mode $1 transport exited $RC for $2: $(cat "$ERR")"
  is_deny || gov_fail "controlled mode did not hard-deny $1:$2: stdout=[$OUT] stderr=[$(cat "$ERR")]"
}

core_eval() {
  OUT="$(printf '{"action":"write","paths":["TRACKER.md"]}\n' | \
    python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN" 2>"$WORK/core.err")"
  RC=$?
}

# Default/off: every representative would-be denial allows, with an observable reason.
core_eval
[ "$RC" -eq 0 ] || gov_fail "off-mode core evaluation did not allow: $OUT"
printf '%s' "$OUT" | grep -q '"allowed": *true' || gov_fail "off-mode core did not return allowed=true: $OUT"
printf '%s' "$OUT" | grep -q '"observe"' || gov_fail "off-mode core did not preserve the would-be-denial reason: $OUT"
observe_case Write "$REPO/TRACKER.md"
observe_case Edit "$REPO/src/x.ts"
observe_case NotebookEdit "$REPO/src/demo.ipynb"
observe_case Bash 'gh issue create --title gate --body x'

python3 "$GIT_GATE" pre-commit --repo "$REPO" --plugin-root "$GOV_PLUGIN" >"$WORK/off-pre-commit.out" 2>"$WORK/off-pre-commit.err"
[ "$?" -eq 0 ] || gov_fail "off-mode pre-commit hard-denied"
grep -qi 'Path Gate denied' "$WORK/off-pre-commit.err" || gov_fail "off-mode pre-commit did not print its would-be-denial reason"
printf 'refs/heads/main %s refs/heads/main %s\n' "$HEAD_SHA" "$BASE_SHA" | \
  python3 "$GIT_GATE" pre-push --repo "$REPO" --plugin-root "$GOV_PLUGIN" >"$WORK/off-pre-push.out" 2>"$WORK/off-pre-push.err"
[ "$?" -eq 0 ] || gov_fail "off-mode pre-push hard-denied"
grep -qi 'Path Gate denied' "$WORK/off-pre-push.err" || gov_fail "off-mode pre-push did not print its would-be-denial reason"

# The same repo flips to controlled: the same requests now hard-deny.
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
core_eval
[ "$RC" -ne 0 ] || gov_fail "controlled-mode core evaluation allowed a protected write: $OUT"
printf '%s' "$OUT" | grep -q '"allowed": *false' || gov_fail "controlled-mode core did not preserve hard denial: $OUT"
deny_case Write "$REPO/TRACKER.md"
deny_case Edit "$REPO/src/x.ts"
deny_case NotebookEdit "$REPO/src/demo.ipynb"
deny_case Bash 'gh issue create --title gate --body x'

python3 "$GIT_GATE" pre-commit --repo "$REPO" --plugin-root "$GOV_PLUGIN" >"$WORK/controlled-pre-commit.out" 2>"$WORK/controlled-pre-commit.err"
[ "$?" -ne 0 ] || gov_fail "controlled-mode pre-commit did not hard-deny"
grep -qi 'Path Gate denied' "$WORK/controlled-pre-commit.err" || gov_fail "controlled-mode pre-commit lost the denial reason"
printf 'refs/heads/main %s refs/heads/main %s\n' "$HEAD_SHA" "$BASE_SHA" | \
  python3 "$GIT_GATE" pre-push --repo "$REPO" --plugin-root "$GOV_PLUGIN" >"$WORK/controlled-pre-push.out" 2>"$WORK/controlled-pre-push.err"
[ "$?" -ne 0 ] || gov_fail "controlled-mode pre-push did not hard-deny"
grep -qi 'Path Gate denied' "$WORK/controlled-pre-push.err" || gov_fail "controlled-mode pre-push lost the denial reason"

# app-locked enforces too; the independent debug override observes in every enforcing mode.
printf 'pathway_enforcement:\n  mode: app-locked\n' > "$REPO/WORKFLOW-config.yaml"
core_eval
[ "$RC" -ne 0 ] || gov_fail "app-locked core evaluation did not hard-deny"
IDC_HOOKS_OBSERVE_ONLY=1 core_eval
[ "$RC" -eq 0 ] || gov_fail "observe-only override did not force observe in app-locked mode: $OUT"
printf '%s' "$OUT" | grep -q '"observe"' || gov_fail "observe-only override lost the underlying denial: $OUT"

# Missing, unknown, and unreadable config all fail soft to off.
for config_case in unknown missing unreadable; do
  case "$config_case" in
    unknown) printf 'pathway_enforcement:\n  mode: surprising\n' > "$REPO/WORKFLOW-config.yaml" ;;
    missing) rm -f "$REPO/WORKFLOW-config.yaml" ;;
    unreadable) printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"; chmod 000 "$REPO/WORKFLOW-config.yaml" ;;
  esac
  core_eval
  [ "$RC" -eq 0 ] || gov_fail "$config_case config did not fall back to off: $OUT"
  printf '%s' "$OUT" | grep -q '"observe"' || gov_fail "$config_case config lost the would-be denial: $OUT"
  [ "$config_case" = unreadable ] && chmod 600 "$REPO/WORKFLOW-config.yaml"
done

echo "PASS: Path Gate off mode observes across core/Claude/git (including NotebookEdit); controlled and app-locked hard-deny; observe-only and safe config fallbacks remain non-blocking"
