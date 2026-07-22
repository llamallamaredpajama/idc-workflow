#!/bin/bash
# path-gate-git-backstops.sh — the shared Path Gate also gates git pre-commit/pre-push backstops:
# hooks install + verify cleanly, an authorized source-only change can commit/push, an unauthorized
# commit that bypasses pre-commit is still blocked at pre-push, failing child git stderr/stdout is
# scrubbed at the read, and deleted/divergent hook files are detected fail-closed.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
GIT_GATE="$GOV_PLUGIN/scripts/idc_git_path_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE (shared core not implemented yet)"
[ -f "$GIT_GATE" ] || gov_fail "idc_git_path_gate.py not found at $GIT_GATE (git backstop not implemented yet)"
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
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"

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

echo "PASS: git pre-commit/pre-push backstops install + verify, block unauthorized pushes, scrub child git diagnostics, and fail closed on deleted/divergent hook files"
