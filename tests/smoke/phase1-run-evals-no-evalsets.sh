#!/bin/bash
# idc-assert-class: behavior
# Phase 1 (run-evals retired-v2 no-op) smoke — the evalset harness is retired in v2, so when the
# repo has no evalsets the plain `bash scripts/run-evals.sh` entrypoint must exit 0 immediately and
# point operators at `bash tests/smoke/run-all.sh` instead of demanding a disposable sandbox.
#
# The regression this catches is load-bearing: the early clean-exit existed only behind `--all`, so a
# bare invocation fell through to the sandbox/tool preconditions and exited 2 on a clean v2 repo with
# no `evals/` tree at all. This test proves the no-arg path now short-circuits BEFORE those
# preconditions, without needing a real sandbox or agent tooling, and that a real evalset still keeps
# the command non-clean.
#
# Hermetic: runs a COPY of the shipped script from a throwaway repo root, with stub `claude`/`jq`
# binaries so the assertions never depend on locally installed agent tooling.
# Usage: bash tests/smoke/phase1-run-evals-no-evalsets.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
BIN="$WORK/bin"
mkdir -p "$REPO/scripts" "$BIN"
cp "$PLUGIN/scripts/run-evals.sh" "$REPO/scripts/run-evals.sh" \
  || fail "could not copy scripts/run-evals.sh into the fixture repo"

cat > "$BIN/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$BIN/jq" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN/claude" "$BIN/jq"
STUB_PATH="$BIN:/usr/bin:/bin"

run_case() {
  local name="$1"; shift
  local out="$WORK/$name.out"
  (
    cd "$REPO" || exit 99
    env PATH="$STUB_PATH" bash "$REPO/scripts/run-evals.sh" "$@"
  ) >"$out" 2>&1
  printf '%s' "$?" > "$WORK/$name.rc"
}

# No evalsets at all: the retired-v2 path must exit cleanly before sandbox/tool checks.
run_case no-evalsets
NO_RC="$(cat "$WORK/no-evalsets.rc")"
[ "$NO_RC" -eq 0 ] || {
  cat "$WORK/no-evalsets.out"
  fail "no-arg run-evals should exit 0 when no evalsets exist (got $NO_RC)"
}
grep -Fqx "run-evals: no evalsets in $REPO/evals." "$WORK/no-evalsets.out" \
  || fail "no-evalsets run did not report the retired evalset surface"
grep -Fqx "run-evals: v2 verification is the functional smoke suite — run: bash tests/smoke/run-all.sh" "$WORK/no-evalsets.out" \
  || fail "no-evalsets run did not point operators at the smoke suite"

# A real evalset must NOT be mistaken for the retired no-evalsets state.
mkdir -p "$REPO/evals"
cat > "$REPO/evals/present.evalset.json" <<'EOF'
{"eval_set_id":"present","eval_cases":[]}
EOF
run_case evalset-present
YES_RC="$(cat "$WORK/evalset-present.rc")"
[ "$YES_RC" -eq 2 ] || {
  cat "$WORK/evalset-present.out"
  fail "a present evalset must keep run-evals non-clean (expected exit 2, got $YES_RC)"
}
grep -Fqx "run-evals: sandbox not found at $REPO/.sandbox/idc-eval-sandbox" "$WORK/evalset-present.out" \
  || fail "present evalset run did not continue into the ordinary sandbox precondition"
if grep -Fq "run-evals: no evalsets in $REPO/evals." "$WORK/evalset-present.out"; then
  cat "$WORK/evalset-present.out"
  fail "a present evalset was mistaken for the retired no-evalsets state"
fi

echo "PASS: run-evals exits cleanly with no evalsets and stays non-clean when one exists"
