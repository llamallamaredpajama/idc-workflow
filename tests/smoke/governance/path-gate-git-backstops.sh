#!/bin/bash
# path-gate-git-backstops.sh — the shared Path Gate also gates git pre-commit/pre-push backstops:
# hooks install + verify cleanly, an authorized source-only change can commit/push, an unauthorized
# commit that bypasses pre-commit is still blocked at pre-push, generic Bash writers are stopped
# before a `--no-verify` commit+push can bypass BOTH git hooks, explicit `git commit/push --no-verify`
# is denied at PreToolUse, failing child git stderr/stdout is scrubbed at the read, and
# deleted/divergent hook files are detected fail-closed.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
GIT_GATE="$GOV_PLUGIN/scripts/idc_git_path_gate.py"
INTERLOCK="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE (shared core not implemented yet)"
[ -f "$GIT_GATE" ] || gov_fail "idc_git_path_gate.py not found at $GIT_GATE (git backstop not implemented yet)"
[ -f "$INTERLOCK" ] || gov_fail "idc_interlock_gate.py not found at $INTERLOCK (Bash transport not implemented yet)"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; REMOTE="$WORK/remote.git"
mkdir -p "$REPO/docs/workflow" "$REPO/src"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
  git config user.email idc@example.test
  git config user.name 'IDC Path Gate'
)
git init --bare -q "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"
WRITER_SCRIPT="$WORK/write-tracker.sh"
cat > "$WRITER_SCRIPT" <<'SH'
cp src/app.ts TRACKER.md
SH
STARTUP_SCRIPT="$WORK/startup-writer.sh"
cat > "$STARTUP_SCRIPT" <<'SH'
cp src/app.ts TRACKER.md
SH

python3 "$GIT_GATE" install-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "could not install git backstops"
python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "freshly-installed git backstops did not verify"

SID="pg-git-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SID" --command build \
  --plugin-root "$GOV_PLUGIN" --args 'demo' --source user >/dev/null \
  || gov_fail "could not open the active /idc:build command record for $SID"
BRANCH="$(git -C "$REPO" branch --show-current)"
python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch "$BRANCH" --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git --allow-path src >/dev/null \
  || gov_fail "could not write a shared Path Gate authorization"

emit_bash() { VALUE="$1" SID="$2" REPO="$REPO" python3 - <<'PY'
import json, os
print(json.dumps({
    "cwd": os.environ["REPO"],
    "tool_name": "Bash",
    "session_id": os.environ["SID"],
    "tool_input": {"command": os.environ["VALUE"]},
}))
PY
}

gate_bash() { OUT="$(emit_bash "$1" "$2" | python3 "$INTERLOCK" "$GOV_PLUGIN" 2>"$WORK/interlock.err")"; RC=$?; }
is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }

deny_gate() {
  gate_bash "$1" "$SID"
  [ "$RC" -eq 0 ] || gov_fail "expected a deny decision for: $1 :: $(cat "$WORK/interlock.err")"
  is_deny || gov_fail "expected PreToolUse to deny: [$1] stdout=[$OUT] stderr=[$(cat "$WORK/interlock.err")]"
}

reset_repo_to_origin() {
  git -C "$REPO" reset --hard -q origin/main
  printf 'ticket: demo\n' > "$REPO/TRACKER.md"
  printf 'export const x = 2;\n' > "$REPO/src/app.ts"
}

deny_or_exploit() {
  local label="$1" cmd="$2"
  reset_repo_to_origin
  gate_bash "$cmd" "$SID"
  [ "$RC" -eq 0 ] || gov_fail "$label crashed the interlock (expected a decision): $(cat "$WORK/interlock.err")"
  if is_deny; then
    return 0
  fi
  (
    cd "$REPO"
    eval "$cmd"
    git add -A TRACKER.md src/app.ts
    git commit --no-verify -qm "test: $label bypass"
    git push --no-verify origin main >/dev/null 2>&1
  ) || gov_fail "$label slipped past PreToolUse, but the follow-on --no-verify bypass did not complete"
  REMOTE_TRACKER="$(git --git-dir="$REMOTE" show main:TRACKER.md)"
  gov_fail "$label slipped past the pre-mutation gate and both git backstops via --no-verify (remote TRACKER.md = $REMOTE_TRACKER)"
}

# Authorized source-only commit/push passes both backstops.
printf 'export const x = 2;\n' > "$REPO/src/app.ts"
git -C "$REPO" add src/app.ts
git -C "$REPO" commit -qm 'feat: authorized source change' \
  || gov_fail "authorized source commit was blocked by pre-commit"
git -C "$REPO" push -u origin main >/dev/null 2>&1 \
  || gov_fail "authorized source push was blocked by pre-push"

# Unauthorized change bypasses pre-commit with --no-verify but is still blocked at pre-push.
printf 'ticket: bypass\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: unauthorized tracker mutation' \
  || gov_fail "could not create the unauthorized no-verify commit needed for the pre-push proof"
if git -C "$REPO" push origin main >"$WORK/push.out" 2>&1; then
  gov_fail "pre-push allowed an unauthorized tracker mutation after a --no-verify commit"
fi
grep -qi 'path gate' "$WORK/push.out" || gov_fail "pre-push failure did not mention the Path Gate: $(cat "$WORK/push.out")"

# PreToolUse must refuse explicit hook-suppression attempts, not leave git hooks as the primary gate.
deny_gate "git commit --no-verify -m bypass"
deny_gate "git commit -n -m bypass"
deny_gate "git push --no-verify origin main"

# Git-only enforcement is insufficient: if a generic Bash writer slips past PreToolUse, an agent can
# mutate the repo and bypass BOTH git hooks with commit+push --no-verify. Each representative route
# below must deny BEFORE execution.
deny_or_exploit "cp->TRACKER" "cp src/app.ts TRACKER.md"
deny_or_exploit "dynamic mutation target" 'T=TRACKER.md; cp src/app.ts $T'
deny_or_exploit "dynamic no-verify flag" 'G=--no-verify; git commit $G -m x'
deny_or_exploit "mv->TRACKER" "mv src/app.ts TRACKER.md"
deny_or_exploit "bash-c nested writer" "bash -c 'cp src/app.ts TRACKER.md'"
deny_or_exploit "dynamic bash-c writer" 'CMD="cp src/app.ts TRACKER.md"; bash -c "$CMD"'
deny_or_exploit "sh-c nested writer" "sh -c 'mv src/app.ts TRACKER.md'"
deny_or_exploit "env-S nested writer" "env -S 'bash -c \"cp src/app.ts TRACKER.md\"'"
deny_or_exploit "dynamic env-S writer" 'CMD="bash -c \"cp src/app.ts TRACKER.md\""; env -S "$CMD"'
deny_or_exploit "command substitution writer" ': $(cp src/app.ts TRACKER.md)'
deny_or_exploit "cd-chain writer" "cd src && cp app.ts ../TRACKER.md"
deny_or_exploit "script-file writer" "bash '$WRITER_SCRIPT'"
deny_or_exploit "source-file writer" "source '$WRITER_SCRIPT'"
deny_or_exploit "nested BASH_ENV writer" "BASH_ENV='$STARTUP_SCRIPT' env -S 'bash -c \"echo hi\"'"

PRE_COMMIT_HOOK="$(git -C "$REPO" rev-parse --git-path hooks/pre-commit)"
PRE_PUSH_HOOK="$(git -C "$REPO" rev-parse --git-path hooks/pre-push)"
case "$PRE_COMMIT_HOOK" in /*) : ;; *) PRE_COMMIT_HOOK="$REPO/$PRE_COMMIT_HOOK" ;; esac
case "$PRE_PUSH_HOOK" in /*) : ;; *) PRE_PUSH_HOOK="$REPO/$PRE_PUSH_HOOK" ;; esac
[ -f "$PRE_COMMIT_HOOK" ] || gov_fail "installed pre-commit hook missing at $PRE_COMMIT_HOOK"
[ -f "$PRE_PUSH_HOOK" ] || gov_fail "installed pre-push hook missing at $PRE_PUSH_HOOK"

rm -f "$PRE_COMMIT_HOOK"
if python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null 2>&1; then
  gov_fail "verify-hooks passed after the pre-commit backstop was deleted"
fi

python3 "$GIT_GATE" install-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "could not reinstall git backstops after deletion"
printf '# divergent\nexit 0\n' > "$PRE_PUSH_HOOK"
chmod +x "$PRE_PUSH_HOOK"
if python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null 2>&1; then
  gov_fail "verify-hooks passed after the pre-push backstop diverged"
fi

FAKE_GIT_DIR="$WORK/fake-git-stdout"; mkdir -p "$FAKE_GIT_DIR"
cat >"$FAKE_GIT_DIR/git" <<'SH'
#!/bin/sh
printf 'fatal: password=hunter2xyzzy while listing staged files\n'
exit 1
SH
chmod +x "$FAKE_GIT_DIR/git"
PATH="$FAKE_GIT_DIR:$PATH" \
  python3 "$GIT_GATE" pre-commit --repo "$REPO" --plugin-root "$GOV_PLUGIN" >"$WORK/git-helper.out" 2>"$WORK/git-helper.err"
RC=$?
[ "$RC" -ne 0 ] || gov_fail "pre-commit unexpectedly succeeded through a failing git child"
! grep -Fq 'hunter2xyzzy' "$WORK/git-helper.out" \
  || gov_fail "git helper leaked a named secret from child stdout on stdout: $(cat "$WORK/git-helper.out")"
! grep -Fq 'hunter2xyzzy' "$WORK/git-helper.err" \
  || gov_fail "git helper leaked a named secret from child stdout on stderr: $(cat "$WORK/git-helper.err")"
grep -Fq 'IDC Path Gate git helper failed:' "$WORK/git-helper.err" \
  || gov_fail "git helper hid the infrastructure failure context: $(cat "$WORK/git-helper.err")"
grep -Fq '[REDACTED]' "$WORK/git-helper.err" \
  || gov_fail "git helper did not preserve a scrubbed diagnostic marker: $(cat "$WORK/git-helper.err")"
grep -Fq 'while listing staged files' "$WORK/git-helper.err" \
  || gov_fail "git helper lost the useful git failure detail after scrubbing: $(cat "$WORK/git-helper.err")"

echo "PASS: git pre-commit/pre-push backstops install + verify, block unauthorized pushes, deny explicit --no-verify suppression, prove generic Bash mutations are denied before a commit+push --no-verify bypass, scrub child git diagnostics, and fail closed on deleted/divergent hook files"
