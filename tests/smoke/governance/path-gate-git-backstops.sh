#!/bin/bash
# path-gate-git-backstops.sh — the shared Path Gate also gates git pre-commit/pre-push backstops:
# hooks install + verify cleanly, chained pre-push stdin/status are preserved, multi-commit new refs
# cannot smuggle a protected lower commit, staged deletions are gated, generic Bash writers are stopped
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

# Seed a remote baseline before the backstops exist. The later allowed push then exercises a normal
# existing-ref record, while TRACKER.md is genuinely tracked for the staged-deletion scenario.
git -C "$REPO" add docs/workflow/tracker-config.yaml WORKFLOW-config.yaml TRACKER.md src/app.ts
git -C "$REPO" commit -qm 'test: baseline'
git -C "$REPO" push -u origin main >/dev/null 2>&1
BASE_REMOTE_SHA="$(git -C "$REPO" rev-parse HEAD)"

HOOKS_DIR="$(git -C "$REPO" rev-parse --git-path hooks)"
case "$HOOKS_DIR" in /*) : ;; *) HOOKS_DIR="$REPO/$HOOKS_DIR" ;; esac
PRE_COMMIT_HOOK="$HOOKS_DIR/pre-commit"
PRE_PUSH_HOOK="$HOOKS_DIR/pre-push"
cat > "$PRE_PUSH_HOOK" <<'SH'
#!/bin/sh
HOOK_DIR="$(dirname "$0")"
printf '%s\n%s\n' "$1" "$2" > "$HOOK_DIR/chained.args"
cat > "$HOOK_DIR/chained.stdin"
[ ! -f "$HOOK_DIR/chained.fail" ] || exit 23
SH
chmod +x "$PRE_PUSH_HOOK"

python3 "$GIT_GATE" install-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "could not install git backstops"
python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "freshly-installed git backstops did not verify"

# Verification must prove Git will execute both the managed wrapper and its chained predecessor.
chmod -x "$PRE_COMMIT_HOOK"
if python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null 2>&1; then
  gov_fail "verify-hooks certified a non-executable managed pre-commit hook"
fi
chmod +x "$PRE_COMMIT_HOOK"
CHAINED_PRE_PUSH="$PRE_PUSH_HOOK.idc-path-gate-original"
chmod -x "$CHAINED_PRE_PUSH"
if python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null 2>&1; then
  gov_fail "verify-hooks certified a non-executable chained pre-push hook"
fi
chmod +x "$CHAINED_PRE_PUSH"
python3 "$GIT_GATE" verify-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null \
  || gov_fail "restored executable Git backstops did not verify"

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
LOCAL_SHA="$(git -C "$REPO" rev-parse HEAD)"
RUNTIME_TMP="$WORK/runtime-tmp"; mkdir -p "$RUNTIME_TMP"
TMPDIR="$RUNTIME_TMP" git -C "$REPO" push -u origin main >/dev/null 2>&1 \
  || gov_fail "authorized source push was blocked by pre-push"
printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_SHA" "$BASE_REMOTE_SHA" > "$WORK/expected.stdin"
cmp -s "$WORK/expected.stdin" "$HOOKS_DIR/chained.stdin" \
  || gov_fail "chained pre-push hook did not receive the exact pushed-ref stdin record"
printf 'origin\n%s\n' "$REMOTE" > "$WORK/expected.args"
cmp -s "$WORK/expected.args" "$HOOKS_DIR/chained.args" \
  || gov_fail "chained pre-push hook did not receive the original hook arguments"
[ -z "$(find "$RUNTIME_TMP" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || gov_fail "managed pre-push hook left its stdin buffer behind"

# Existing refs need commit-by-commit inspection too. Commit A mutates TRACKER.md; commit B restores
# its final tree and changes only authorized source. A tip-to-tip diff sees only src/app.ts, but the
# pushed history still contains the protected mutation and must be refused.
EXISTING_REMOTE_SHA="$(git -C "$REPO" rev-parse origin/main)"
printf 'ticket: HIDDEN-IN-HISTORY\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: protected existing-ref lower commit'
git -C "$REPO" checkout -q "$EXISTING_REMOTE_SHA" -- TRACKER.md
printf 'export const x = 4;\n' > "$REPO/src/app.ts"
git -C "$REPO" add TRACKER.md src/app.ts
git -C "$REPO" commit --no-verify -qm 'test: restore protected tree at existing-ref tip'
if git -C "$REPO" push origin main >"$WORK/existing-history-push.out" 2>&1; then
  gov_fail "pre-push allowed a protected lower commit on an existing ref whose tip restored the protected tree"
fi
grep -qi 'path gate' "$WORK/existing-history-push.out" \
  || gov_fail "existing-ref history denial did not mention the Path Gate: $(cat "$WORK/existing-history-push.out")"
git -C "$REPO" reset --hard -q origin/main

# A chained hook's failure status propagates exactly after both hooks see the same stdin bytes.
touch "$HOOKS_DIR/chained.fail"
printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_SHA" "$BASE_REMOTE_SHA" \
  | TMPDIR="$RUNTIME_TMP" "$PRE_PUSH_HOOK" origin "$REMOTE" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 23 ] || gov_fail "managed pre-push hook changed chained hook status 23 to $RC"
cmp -s "$WORK/expected.stdin" "$HOOKS_DIR/chained.stdin" \
  || gov_fail "chained failing pre-push hook did not receive exact replayed stdin"
rm -f "$HOOKS_DIR/chained.fail"

# A new branch must inspect every newly reachable commit, not only the tip: the protected mutation
# below is deliberately in the lower commit while the tip changes only an authorized source path.
git -C "$REPO" checkout -qb smuggled
printf 'ticket: SMUGGLED\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: protected lower commit'
printf 'export const x = 3;\n' > "$REPO/src/app.ts"
git -C "$REPO" add src/app.ts
git -C "$REPO" commit --no-verify -qm 'test: ordinary tip commit'
python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch smuggled --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git --allow-path src >/dev/null \
  || gov_fail "could not authorize the new-branch smuggling fixture's ordinary source path"
if git -C "$REPO" push origin smuggled >"$WORK/smuggled-push.out" 2>&1; then
  REMOTE_TRACKER="$(git --git-dir="$REMOTE" show refs/heads/smuggled:TRACKER.md 2>/dev/null || true)"
  gov_fail "pre-push allowed a protected lower commit on a new ref (remote TRACKER.md = $REMOTE_TRACKER)"
fi
if git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/smuggled; then
  REMOTE_TRACKER="$(git --git-dir="$REMOTE" show refs/heads/smuggled:TRACKER.md 2>/dev/null || true)"
  [ "$REMOTE_TRACKER" != 'ticket: SMUGGLED' ] \
    || gov_fail "remote received ticket: SMUGGLED despite the controlled pre-push gate"
fi
grep -qi 'path gate' "$WORK/smuggled-push.out" \
  || gov_fail "new-ref smuggling denial did not mention the Path Gate: $(cat "$WORK/smuggled-push.out")"
git -C "$REPO" checkout -q main
git -C "$REPO" reset --hard -q origin/main
python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch main --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git --allow-path src >/dev/null \
  || gov_fail "could not restore the main-branch Path Gate authorization"

# Local remote-tracking refs are not authoritative for the server being pushed to. A stale local
# origin/ghost points at the protected lower commit, but no corresponding server ref exists. The
# actual server ref set must still leave both new commits visible to the gate and block the push.
git -C "$REPO" checkout -qb ghost-smuggled
printf 'ticket: GHOST-SMUGGLED\n' > "$REPO/TRACKER.md"
git -C "$REPO" add TRACKER.md
git -C "$REPO" commit --no-verify -qm 'test: protected lower commit behind stale ghost'
GHOST_LOWER_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'export const x = 4;\n' > "$REPO/src/app.ts"
git -C "$REPO" add src/app.ts
git -C "$REPO" commit --no-verify -qm 'test: innocent tip behind stale ghost'
git -C "$REPO" update-ref refs/remotes/origin/ghost "$GHOST_LOWER_SHA"
git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/ghost \
  && gov_fail "stale-ghost fixture accidentally created a real server ghost ref"
python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch ghost-smuggled --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git --allow-path src >/dev/null \
  || gov_fail "could not authorize the stale-ghost fixture's ordinary source path"
if git -C "$REPO" push origin ghost-smuggled >"$WORK/ghost-push.out" 2>&1; then
  REMOTE_TRACKER="$(git --git-dir="$REMOTE" show refs/heads/ghost-smuggled:TRACKER.md 2>/dev/null || true)"
  gov_fail "stale local remote-tracking ref hid a protected lower commit (remote TRACKER.md = $REMOTE_TRACKER)"
fi
if git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/ghost-smuggled; then
  REMOTE_TRACKER="$(git --git-dir="$REMOTE" show refs/heads/ghost-smuggled:TRACKER.md 2>/dev/null || true)"
  [ "$REMOTE_TRACKER" != 'ticket: GHOST-SMUGGLED' ] \
    || gov_fail "remote received ticket: GHOST-SMUGGLED through a stale local ref exclusion"
fi
grep -qi 'path gate' "$WORK/ghost-push.out" \
  || gov_fail "stale-ghost denial did not mention the Path Gate: $(cat "$WORK/ghost-push.out")"
git -C "$REPO" update-ref -d refs/remotes/origin/ghost
git -C "$REPO" checkout -q main
git -C "$REPO" reset --hard -q origin/main
python3 "$PATH_GATE" authorize --repo "$REPO" --session "$SID" --command build \
  --branch main --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git --allow-path src >/dev/null \
  || gov_fail "could not restore main authorization after the stale-ghost proof"

# Deletion-only staged changes are mutations too. Protected deletion denies; an authorized source
# deletion remains allowed so the diff-filter cannot simply reject every D record.
git -C "$REPO" rm -q TRACKER.md
if git -C "$REPO" commit -qm 'test: protected deletion' >"$WORK/delete-protected.out" 2>&1; then
  gov_fail "pre-commit allowed deletion-only removal of protected TRACKER.md"
fi
grep -qi 'path gate' "$WORK/delete-protected.out" \
  || gov_fail "protected deletion denial did not mention the Path Gate: $(cat "$WORK/delete-protected.out")"
git -C "$REPO" reset --hard -q HEAD
printf 'remove me\n' > "$REPO/src/remove.ts"
git -C "$REPO" add src/remove.ts
git -C "$REPO" commit -qm 'test: add authorized deletion fixture' \
  || gov_fail "could not add the ordinary authorized deletion fixture"
git -C "$REPO" rm -q src/remove.ts
git -C "$REPO" commit -qm 'test: ordinary authorized deletion' \
  || gov_fail "pre-commit blocked an ordinary authorized source deletion"

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

# A shared/global hooksPath is outside this repository's own common Git directory. Installation must
# fail before writing either managed hook there. A separate linked-worktree positive is in the focused
# Python companion so this check cannot be weakened to a literal <worktree>/.git/hooks requirement.
EXTERNAL_REPO="$WORK/external-repo"; EXTERNAL_HOOKS="$WORK/shared-hooks"
mkdir -p "$EXTERNAL_REPO" "$EXTERNAL_HOOKS"
git -C "$EXTERNAL_REPO" init -q
git -C "$EXTERNAL_REPO" config core.hooksPath "$EXTERNAL_HOOKS"
if python3 "$GIT_GATE" install-hooks --repo "$EXTERNAL_REPO" --plugin-root "$GOV_PLUGIN" \
  >"$WORK/external-hooks.out" 2>&1; then
  gov_fail "install-hooks accepted a hooksPath outside the repository common Git directory"
fi
[ -z "$(find "$EXTERNAL_HOOKS" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || gov_fail "install-hooks wrote into the refused shared hooksPath"

python3 "$(dirname "$0")/_path_gate_git_backstops_unit.py" \
  || gov_fail "focused Git backstop unit/integration checks failed"

echo "PASS: git backstops preserve chained hooks, inspect full new-ref history, gate deletions, install atomically only inside the common Git directory, scrub diagnostics, and fail closed on tampering"
