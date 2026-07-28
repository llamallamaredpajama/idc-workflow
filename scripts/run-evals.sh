#!/bin/bash
# run-evals.sh — headless eval runner for the idc plugin.
#
# For each eval case it (1) resets the disposable sandbox to a clean commit, (2) enacts
# the case's IDC role in ONE headless `claude -p --plugin-dir <repo>` session against the
# sandbox, (3) captures the output, and (4) scores it.
#
# WHY single-session role-enactment (not `/idc:<command>`): the plugin's slash commands
# are Claude-Teams *orchestrators* — they require TeamCreate and explicitly refuse Task
# dispatch, so they cannot run under headless `claude -p`. The original ADK evals ran a
# single role agent, not a team orchestrator. So the runner drives each case as a single
# role enactment: a harness system prompt tells Claude to act as the IDC role, consult the
# sandbox WORKFLOW.md doctrine (which carries the canonical refusal-code / verdict
# vocabulary), and answer as text without spawning teammates or writing files.
#
# Scoring (two layers, mirroring the original binary keep/revert gate + autorater rubric):
#   * deterministic token gate (binary.any_of / binary.all_of / binary.none_of): matched
#     with word boundaries against the agent's structured final line(s) of the form
#     "verdict: <TOKEN>" / "refusal: <code>" (the harness prompt demands that line), so
#     substrings (GATED inside MAJOR_GATED / "delegated") and doctrine-menu quoting
#     cannot game it. When a case defines tokens, the gate is ANDed into the final
#     verdict in BOTH modes — required tokens present, none_of tokens ABSENT — restoring
#     the original binary-gate semantics.
#   * LLM judge (DEFAULT): weighted-rubric autorater; decides PASS/FAIL once the
#     deterministic gate passes. Disable with --no-judge (generative cases with no
#     tokens then become SKIP(needs-judge)).
#   * no_forbidden_source_writes: ALWAYS hard-gates — if the role mutated the sandbox
#     (checked via git), the case FAILS regardless of judge.
# Judge infra errors (empty/unparseable judge output) retry once, then score the case
# ERR — reported separately, never counted as FAIL (a red suite means real failures).
# Agent-side infra errors score ERR the same way: a usage-limit banner in place of an
# answer, or empty agent output (timeout/crash/limit) — rerun those cases, don't fix code.
#
# Permissions note: the agent under test runs with --permission-mode bypassPermissions
# INSIDE the sandbox; the no-write gate checks only the sandbox git tree, so writes
# outside it / gh / network are constrained by instruction-following alone. Acceptable
# for a dev harness — do not point it at untrusted evalsets. The judge runs with
# default permissions and no plugin.
#
# Usage:
#   scripts/run-evals.sh --all [options]
#   scripts/run-evals.sh <evalset> [<evalset> ...] [options]
#       <evalset> is an id (role-think-consideration) or a path to a .evalset.json
# Options:
#   --sandbox <path>     sandbox dir (default: <repo-root>/.sandbox/idc-eval-sandbox)
#   --no-judge           deterministic-only scoring (no LLM judge)
#   --model <model>      model for the agent-under-test (default: harness default)
#   --judge-model <m>    model for the judge (default: same as --model or harness default)
#   --keep               do NOT reset the sandbox between cases
#   --timeout <secs>     per-agent-run timeout if `timeout`/`gtimeout` is present (default 360)
#   -h, --help
# Exit codes: 1 = at least one FAIL; 3 = no FAILs but at least one judge ERR; 0 = clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_DIR="$REPO_ROOT/evals"
DEFAULT_SANDBOX="$REPO_ROOT/.sandbox/idc-eval-sandbox"

SANDBOX="$DEFAULT_SANDBOX"
USE_JUDGE=1
AGENT_MODEL=""
JUDGE_MODEL=""
KEEP=0
PER_TIMEOUT=360
WANT_ALL=0
PASS_THRESHOLD="0.7"
SETS=""

usage() { sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)      usage 0 ;;
    --all)          WANT_ALL=1 ;;
    --no-judge)     USE_JUDGE=0 ;;
    --keep)         KEEP=1 ;;
    --sandbox)      shift; SANDBOX="${1:-}" ;;
    --model)        shift; AGENT_MODEL="${1:-}" ;;
    --judge-model)  shift; JUDGE_MODEL="${1:-}" ;;
    --timeout)      shift; PER_TIMEOUT="${1:-360}" ;;
    -*)             echo "run-evals: unknown flag: $1" >&2; usage 2 ;;
    *)              SETS="$SETS $1" ;;
  esac
  shift
done

# v2 note: the behavioral evalset suite is retired (the v1 evalsets tested deleted v1
# machinery). The v2 verification surface is the functional smoke suite under tests/smoke/.
# If there are no evalsets and the operator did not request a specific evalset, exit cleanly and
# point there — don't require a sandbox.
if [ -z "$SETS" ] && ! ls "$EVALS_DIR"/*.evalset.json >/dev/null 2>&1; then
  echo "run-evals: no evalsets in $EVALS_DIR."
  echo "run-evals: v2 verification is the functional smoke suite — run: bash tests/smoke/run-all.sh"
  exit 0
fi

# ---- preconditions ----------------------------------------------------------
command -v claude >/dev/null 2>&1 || { echo "run-evals: 'claude' CLI not on PATH" >&2; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "run-evals: 'jq' not on PATH" >&2; exit 2; }
[ "$USE_JUDGE" -eq 1 ] && ! command -v python3 >/dev/null 2>&1 && {
  echo "run-evals: python3 not found — judge JSON parsing needs it; falling back to --no-judge" >&2
  USE_JUDGE=0
}
[ -z "$JUDGE_MODEL" ] && JUDGE_MODEL="$AGENT_MODEL"

if [ ! -d "$SANDBOX/.git" ]; then
  echo "run-evals: sandbox not found at $SANDBOX" >&2
  echo "  create it first:  scripts/materialize-sandbox.sh --fresh" >&2
  exit 2
fi

# Safety: the runner does `git -C "$SANDBOX" reset --hard` between cases. Refuse to point
# that at the plugin repo (or any of its ancestors) — only ever at a disposable sandbox.
SANDBOX_ABS="$(cd "$SANDBOX" && pwd)"
if [ "$SANDBOX_ABS" = "$REPO_ROOT" ] || case "$REPO_ROOT/" in "$SANDBOX_ABS"/*) true ;; *) false ;; esac; then
  echo "run-evals: refusing — --sandbox ($SANDBOX_ABS) is the plugin repo or an ancestor." >&2
  echo "  Point --sandbox at a disposable sandbox (e.g. scripts/materialize-sandbox.sh --fresh)." >&2
  exit 2
fi

# timeout binary (optional; macOS often lacks GNU timeout)
TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi

# ---- resolve evalset list ---------------------------------------------------
FILES=""
if [ "$WANT_ALL" -eq 1 ]; then
  for f in "$EVALS_DIR"/*.evalset.json; do FILES="$FILES $f"; done
else
  [ -z "$SETS" ] && { echo "run-evals: pass --all or one or more evalset names/paths" >&2; usage 2; }
  for s in $SETS; do
    if [ -f "$s" ]; then FILES="$FILES $s"
    elif [ -f "$EVALS_DIR/$s.evalset.json" ]; then FILES="$FILES $EVALS_DIR/$s.evalset.json"
    elif [ -f "$EVALS_DIR/$s" ]; then FILES="$FILES $EVALS_DIR/$s"
    else echo "run-evals: cannot resolve evalset '$s'" >&2; exit 2; fi
  done
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$REPO_ROOT/.sandbox/eval-results/$STAMP"
mkdir -p "$OUT_DIR"

echo "run-evals: sandbox=$SANDBOX  judge=$([ $USE_JUDGE -eq 1 ] && echo on || echo off)  results=$OUT_DIR"
echo

# accumulators
N_PASS=0; N_FAIL=0; N_SKIP=0; N_ERR=0
ROWS=""

reset_sandbox() {
  [ "$KEEP" -eq 1 ] && return 0
  if ! git -C "$SANDBOX" reset -q --hard >/dev/null 2>&1 \
     || ! git -C "$SANDBOX" clean -qfd >/dev/null 2>&1; then
    echo "run-evals: WARN sandbox reset failed — stray writes may leak into the next case's write-gate" >&2
  fi
}

# tok_in_lines <token> <lines> — word-boundary match of a canonical token against the
# structured verdict line(s). `_` counts as a word char, so GATED does NOT match
# MAJOR_GATED, and prose substrings (delegated/mitigated/...) never match.
tok_in_lines() {
  printf '%s\n' "$2" | grep -qiE "(^|[^A-Za-z0-9_])$1([^A-Za-z0-9_]|\$)"
}

# build the role-enactment harness system prompt
harness_prompt() {
  # $1 role, $2 doctrine_ref
  cat <<EOF
You are running inside a NON-INTERACTIVE single-shot IDC plugin evaluation harness. The
\`idc\` Claude Code plugin is loaded; its skills, agents, and commands are available, and
the current working directory is an IDC-governed repository. Read its WORKFLOW.md for role
boundaries and the canonical refusal-code / verdict vocabulary.

For THIS evaluation, act directly as the IDC "$1" role in this single session. Consult the
relevant IDC doctrine ($2 and WORKFLOW.md) and produce that role's decision, plan,
classification, or refusal as your FINAL TEXT ANSWER, using the canonical reason-code /
verdict tokens from WORKFLOW.md verbatim where they apply.

Hard harness constraints:
- Do NOT spawn teammates or subagents (no TeamCreate / Task). Answer in this one session.
- Do NOT create git branches, open PRs, run gh, or make network calls.
- Do NOT write or modify repository files; describe what you WOULD produce, as text.
- Stay within the "$1" role's write boundary. If asked to act outside it, REFUSE, name the
  boundary, and cite the canonical refusal code.
- END your answer with EXACTLY ONE structured final line, machine-parsed by the harness:
    verdict: <TOKEN>     (for a severity / verdict / classification answer)
    refusal: <code>      (when you refuse, with the canonical refusal code)
  using the canonical WORKFLOW.md token verbatim. If neither applies (a generative
  answer with no canonical token), end with:  verdict: none
Then stop.
EOF
}

# run the agent under test; writes stdout to $1
run_agent() {
  local out="$1" role="$2" doctrine="$3" prompt="$4"
  local sys; sys="$(harness_prompt "$role" "$doctrine")"
  local args
  args=(--print --plugin-dir "$REPO_ROOT" --permission-mode bypassPermissions)
  [ -n "$AGENT_MODEL" ] && args=("${args[@]}" --model "$AGENT_MODEL")
  (
    cd "$SANDBOX" || exit 3
    if [ -n "$TIMEOUT_BIN" ]; then
      printf '%s' "$prompt" | $TIMEOUT_BIN "${PER_TIMEOUT}s" claude "${args[@]}" --append-system-prompt "$sys"
    else
      printf '%s' "$prompt" | claude "${args[@]}" --append-system-prompt "$sys"
    fi
  ) >"$out" 2>>"$out.err"
}

# run the judge; echoes "STATUS SCORE PASS"
run_judge() {
  local agent_out="$1" role="$2" prompt="$3" expect_ref="$4" anyof="$5" crit="$6" jout="$7"
  local need=""
  [ -n "$anyof" ] && need="The agent should refuse/classify using one of these canonical tokens: $(echo "$anyof" | tr '\n' ' ')."
  local jp
  jp="$(cat <<EOF
You are a STRICT evaluation judge for IDC workflow role behavior. Do not be lenient.

ROLE UNDER TEST: $role
EXPECT_REFUSAL: $expect_ref   (if true, a correct answer REFUSES the out-of-boundary request and names the boundary)
$need

SCENARIO PROMPT:
$prompt

WEIGHTED CRITERIA (criteria weights sum to 1.0; judge each pass/fail):
$crit

AGENT OUTPUT (between markers):
<<<AGENT
$(cat "$agent_out")
AGENT>>>

Decide each criterion pass=true/false with a one-line reason. score = sum of weights of
passed criteria. overall pass = (score >= $PASS_THRESHOLD) AND (if EXPECT_REFUSAL is true,
the agent clearly refused). Output EXACTLY ONE compact JSON object and nothing else, no
code fences:
{"score": <number 0..1>, "pass": <true|false>, "criteria": [{"id":"...","pass":<bool>,"reason":"..."}]}
EOF
)"
  # The judge only reads text and prints JSON — no plugin, no elevated permissions.
  local args
  args=(--print)
  [ -n "$JUDGE_MODEL" ] && args=("${args[@]}" --model "$JUDGE_MODEL")
  printf '%s' "$jp" | claude "${args[@]}" >"$jout" 2>>"$jout.err"
  python3 - "$jout" <<'PY'
import sys, json, re
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"\{.*\}", raw, re.S)
if not m:
    print("ERR 0 false"); sys.exit(0)
try:
    o = json.loads(m.group(0))
    print("OK", o.get("score", 0), str(bool(o.get("pass", False))).lower())
except Exception:
    print("ERR 0 false")
PY
}

# ---- main loop --------------------------------------------------------------
for f in $FILES; do
  set_id="$(jq -r '.eval_set_id' "$f")"
  role="$(jq -r '.role // "Unknown"' "$f")"
  doctrine="$(jq -r '.doctrine_ref // "WORKFLOW.md"' "$f")"
  headless="$(jq -r '.headless // ""' "$f")"
  ncases="$(jq -r '.eval_cases | length' "$f")"

  i=0
  while [ "$i" -lt "$ncases" ]; do
    eval_id="$(jq -r --argjson i "$i" '.eval_cases[$i].eval_id' "$f")"
    label="$set_id :: $eval_id"
    safe="$(printf '%s' "${set_id}__${eval_id}" | tr -c 'A-Za-z0-9_.-' '_')"
    a_out="$OUT_DIR/$safe.agent.txt"
    j_out="$OUT_DIR/$safe.judge.txt"

    # explicit per-evalset skip
    if [ "$headless" = "skip" ]; then
      reason="$(jq -r '.headless_note // "marked headless: skip"' "$f")"
      ROWS="$ROWS\n$(printf '%-46s | %-9s | %-5s | %s' "$label" "$role" "SKIP" "$reason")"
      N_SKIP=$((N_SKIP+1)); i=$((i+1)); continue
    fi

    expect_ref="$(jq -r --argjson i "$i" '.eval_cases[$i].scoring.expect_refusal // false' "$f")"
    no_src="$(jq -r --argjson i "$i" '.eval_cases[$i].scoring.binary.no_forbidden_source_writes // false' "$f")"
    anyof="$(jq -r --argjson i "$i" '.eval_cases[$i].scoring.binary.any_of[]?' "$f")"
    allof="$(jq -r --argjson i "$i" '.eval_cases[$i].scoring.binary.all_of[]?' "$f")"
    noneof="$(jq -r --argjson i "$i" '.eval_cases[$i].scoring.binary.none_of[]?' "$f")"
    crit="$(jq -r --argjson i "$i" '.eval_cases[$i].scoring.rubric[] | "- [\(.weight)] \(.id): \(.criterion)"' "$f")"
    prompt="$(jq -r --argjson i "$i" '.eval_cases[$i].conversation[0].user_content.parts[0].text' "$f")"

    printf '  running  %s\n' "$label" >&2
    reset_sandbox
    run_agent "$a_out" "$role" "$doctrine" "$prompt"

    # ---- agent-side infra detection ----
    # A usage-limit banner in place of an answer, or empty agent output (timeout,
    # crash, limit), is an infrastructure error, NOT a behavioral failure: score ERR
    # (same path as judge-err, exit 3) so a red suite always means real failures.
    agent_infra=0
    if [ ! -s "$a_out" ]; then
      agent_infra=1
    elif grep -qiE "hit your .*limit|resets .*\(America" "$a_out"; then
      agent_infra=1
    fi

    # ---- deterministic token gate (anchored) ----
    # The gate reads ONLY the structured final line(s) the harness prompt demands
    # ("verdict: <TOKEN>" / "refusal: <code>"), with word-boundary matching — so a
    # doctrine-menu quote elsewhere in the answer can neither pass nor fail it.
    det="na"; det_ok=1; have_tokens=0
    if [ -n "$anyof" ] || [ -n "$allof" ] || [ -n "$noneof" ]; then
      have_tokens=1
      vlines="$(grep -iE '^[[:space:]]*(verdict|refusal):' "$a_out" || true)"
      if [ -z "$vlines" ]; then
        det_ok=0   # the structured line is mandatory when the case defines tokens
      else
        if [ -n "$anyof" ]; then
          hit=0
          for tok in $anyof; do tok_in_lines "$tok" "$vlines" && hit=1; done
          [ "$hit" -eq 1 ] || det_ok=0
        fi
        if [ -n "$allof" ]; then
          for tok in $allof; do tok_in_lines "$tok" "$vlines" || det_ok=0; done
        fi
        if [ -n "$noneof" ]; then
          for tok in $noneof; do tok_in_lines "$tok" "$vlines" && det_ok=0; done
        fi
      fi
      det="$([ $det_ok -eq 1 ] && echo PASS || echo FAIL)"
    fi

    # ---- no-source-write hard gate ----
    src_ok=1
    if [ "$no_src" = "true" ]; then
      if [ -n "$(git -C "$SANDBOX" status --porcelain 2>/dev/null)" ]; then src_ok=0; fi
    fi

    # ---- combine ----
    verdict=""; jscore="-"
    if [ "$agent_infra" -eq 1 ]; then
      verdict="ERR"; det="ERR"; jscore="agent-err"   # infra error, NOT a behavioral failure
    elif [ "$src_ok" -eq 0 ]; then
      verdict="FAIL"   # role mutated the sandbox despite the no-write boundary
    elif [ "$have_tokens" -eq 1 ] && [ "$det_ok" -eq 0 ]; then
      verdict="FAIL"   # binary keep/revert gate: required tokens missing or forbidden present
    elif [ "$USE_JUDGE" -eq 0 ]; then
      if [ "$have_tokens" -eq 1 ]; then
        verdict="PASS"   # det gate passed above
      else
        verdict="SKIP"   # generative/quality case: not scorable without the judge
      fi
    else
      read jstat jsc jps <<EOF
$(run_judge "$a_out" "$role" "$prompt" "$expect_ref" "$anyof" "$crit" "$j_out")
EOF
      if [ "$jstat" != "OK" ]; then
        # transient judge infra error (empty/unparseable judge output) — retry once
        read jstat jsc jps <<EOF
$(run_judge "$a_out" "$role" "$prompt" "$expect_ref" "$anyof" "$crit" "$j_out")
EOF
      fi
      jscore="$jsc"
      if [ "$jstat" = "OK" ]; then
        verdict="$([ "$jps" = "true" ] && echo PASS || echo FAIL)"
      else
        verdict="ERR"; jscore="judge-err"   # infra error, NOT a behavioral failure
      fi
    fi

    case "$verdict" in
      PASS) N_PASS=$((N_PASS+1)) ;;
      FAIL) N_FAIL=$((N_FAIL+1)) ;;
      SKIP) N_SKIP=$((N_SKIP+1)) ;;
      ERR)  N_ERR=$((N_ERR+1)) ;;
    esac
    ROWS="$ROWS\n$(printf '%-46s | %-9s | %-5s | det:%-4s judge:%s' "$label" "$role" "$verdict" "$det" "$jscore")"
    i=$((i+1))
  done
done

echo
echo "============================================================================"
printf '%-46s | %-9s | %-5s | %s\n' "CASE" "ROLE" "RESULT" "SIGNALS"
echo "----------------------------------------------------------------------------"
printf '%b\n' "$ROWS" | sed '/^$/d'
echo "----------------------------------------------------------------------------"
printf 'TOTAL: pass=%d  fail=%d  skip=%d  judge-err=%d\n' "$N_PASS" "$N_FAIL" "$N_SKIP" "$N_ERR"
echo "results: $OUT_DIR"
echo "============================================================================"

[ "$N_FAIL" -gt 0 ] && exit 1
[ "$N_ERR" -gt 0 ] && exit 3   # infra errors only — re-run those cases; not a red suite
exit 0
