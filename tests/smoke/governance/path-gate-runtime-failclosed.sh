#!/bin/bash
# path-gate-runtime-failclosed.sh — F57: the shared Path Gate transport REFUSES on an unusable
# runtime; it never allows silently.
#
# THE DEFECT THIS LANE LOCKS. `scripts/hooks/idc_interlock_gate_hook.sh` is the PreToolUse transport
# for the whole shared Path Gate (Bash + Write + Edit + NotebookEdit). Its runtime preflight used to
# read `sh idc_python_runtime.sh || exit 0` — exit 0 = ALLOW — reached AFTER the repo was confirmed
# governed and BEFORE the pathway mode was ever consulted. On any host whose python3 predates 3.10
# the entire enforcement leg silently permitted every mutation in `app-locked` mode, emitting zero
# bytes. Meanwhile this plugin's own git hooks (idc_git_pre_commit.sh / idc_git_pre_push.sh) fail
# CLOSED on the identical condition. This scenario is the standing proof that the transport now
# agrees with them.
#
# WHAT IT PROVES, per interpreter lane:
#   A. enforcing repo (app-locked, and controlled) + unusable python3  -> hard DENY, non-empty output
#   B. `off` repo + unusable python3                                   -> allow, but a LOUD stderr
#                                                                          line (never zero bytes)
#   C. enforcing repo + unusable python3 + IDC_HOOKS_OBSERVE_ONLY=1    -> the documented debug
#                                                                          downgrade, loud + allow
#   D. control, SUPPORTED python3                                      -> the wrapper still delegates
#                                                                          to the real gate (proves
#                                                                          the refusal did not
#                                                                          replace enforcement)
#   E. the posture probe agrees with the SHIPPED parser across the whole mode matrix, so the
#      fail-closed decision can never drift from `idc_path_gate.pathway_mode`.
#
# TWO INTERPRETER LANES, because "unusable python3" must be proven, not asserted:
#   * SHIM lane (always runs, hermetic): a `python3` on PATH that fails the shared runtime preflight
#     and refuses to run the 3.10-syntax gate, while ordinary scripts still execute — exactly how a
#     real 3.9 behaves. Refusing the gate is what makes this red-when-broken: restore `|| exit 0`
#     and case A produces zero bytes instead of a deny.
#   * REAL lane (opportunistic): a genuine < 3.10 interpreter discovered on the box (stock macOS
#     /usr/bin/python3 is 3.9.6). Skipped-with-a-printed-reason when the host has none, never
#     silently.
#
# Red-when-broken: revert the wrapper's runtime branch to `|| exit 0` and A/B/C all fail (A sees an
# empty allow, B/C see no stderr line). Break the probe's fail-closed default and A's `unknown` case
# fails. Diverge the probe from the parser and E fails.
#
# Usage: bash tests/smoke/governance/path-gate-runtime-failclosed.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

WRAPPER="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate_hook.sh"
PROBE="$GOV_PLUGIN/scripts/idc_pathway_posture_probe.py"
RUNTIME="$GOV_PLUGIN/scripts/idc_python_runtime.sh"
[ -f "$WRAPPER" ] || gov_fail "path gate transport wrapper not found at $WRAPPER"
[ -f "$PROBE" ] || gov_fail "pathway posture probe not found at $PROBE (the wrapper cannot decide posture without it)"
[ -f "$RUNTIME" ] || gov_fail "shared runtime preflight not found at $RUNTIME"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow" "$REPO/src"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
  git config user.email idc@example.test
  git config user.name 'IDC Path Gate Runtime'
) || gov_fail "could not init the fixture repo"
printf 'backend: github\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'export const x = 1;\n' > "$REPO/src/x.ts"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'pathway_enforcement:\n  mode: off\n' > "$REPO/WORKFLOW-config.yaml"
git -C "$REPO" add . >/dev/null 2>&1
git -C "$REPO" commit --no-verify -qm 'test: seed runtime-failclosed fixture' >/dev/null 2>&1 \
  || gov_fail "could not seed the fixture commit"

set_mode() { printf 'pathway_enforcement:\n  mode: %s\n' "$1" > "$REPO/WORKFLOW-config.yaml"; }

payload() {
  TOOL="$1" VALUE="$2" REPO="$REPO" python3 - <<'PY'
import json, os
tool = os.environ["TOOL"]
payload = {"cwd": os.environ["REPO"], "tool_name": tool, "session_id": "pg-runtime-failclosed"}
payload["tool_input"] = {"command": os.environ["VALUE"]} if tool == "Bash" else {"file_path": os.environ["VALUE"]}
print(json.dumps(payload))
PY
}

# --- the two interpreter lanes -------------------------------------------------------------------

# A shim dir whose `python3` behaves like an interpreter older than 3.10: the shared preflight
# rejects it, the 3.10-syntax gate refuses to run, and everything else (including the posture probe)
# executes for real — which is precisely a real 3.9's behavior.
SHIM="$WORK/shim-old"
mkdir -p "$SHIM"
REAL_PY="$(command -v python3)" || gov_fail "no python3 on PATH — cannot build the interpreter lanes"
cat > "$SHIM/python3" <<SHIMEOF
#!/bin/sh
# Emulates python3 < 3.10 for this lane: the shared runtime preflight fails, the gate (which uses
# 3.10-only \`X | Y\` annotations) raises on import, plain scripts still run.
for arg in "\$@"; do
  case "\$arg" in
    *version_info*) exit 1 ;;
    *idc_interlock_gate.py) echo "TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'" >&2; exit 1 ;;
  esac
done
exec "$REAL_PY" "\$@"
SHIMEOF
chmod +x "$SHIM/python3"

# A genuinely old interpreter, if the host has one. Symlinked into its own dir so PATH selection is
# the only thing that changes between lanes.
REAL_OLD=""
for candidate in /usr/bin/python3 python3.9 python3.8 python3.7; do
  cpath="$(command -v "$candidate" 2>/dev/null)" || continue
  "$cpath" -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 10) else 1)' >/dev/null 2>&1 || continue
  REAL_OLD="$WORK/shim-real"
  mkdir -p "$REAL_OLD"
  ln -sf "$cpath" "$REAL_OLD/python3"
  echo "note: real <3.10 interpreter lane using $cpath ($("$cpath" --version 2>&1))"
  break
done
[ -n "$REAL_OLD" ] || echo "note: no real <3.10 interpreter on this host — the shim lane carries the proof (never a silent skip)"

# Every probe below runs under an explicit `timeout`, because the guard under test is a fail-CLOSED
# bound: neutering it makes the hook HANG rather than redden, and a hang looks like a slow pass.
# `timeout` is NOT on stock macOS (coreutils installs it; some setups provide only `gtimeout`), and
# without it every probe returns EMPTY — which satisfies every `! is_deny` allow arm in this file.
# Refuse to run at all rather than emit a verdict whose meaning depends on the host.
command -v timeout >/dev/null 2>&1 || gov_fail "BLOCKED: \`timeout\` is not on PATH. This lane runs every probe under an explicit timeout so a hung hook REDS instead of looking like a slow pass; without it each probe returns empty, and empty output satisfies this file's allow assertions. Install coreutils and make sure \`timeout\` itself (not only \`gtimeout\`) is on PATH, then re-run."

# gate_via <shim-dir-or-empty> <tool> <value> -> sets OUT / ERRTXT / RC
gate_via() {
  local shim="$1" tool="$2" value="$3"
  local runpath="$PATH"
  [ -n "$shim" ] && runpath="$shim:$PATH"
  OUT="$(payload "$tool" "$value" | ( cd "$REPO" && PATH="$runpath" timeout 30 bash "$WRAPPER" "$GOV_PLUGIN" ) 2>"$WORK/err.txt")"
  RC=$?
  ERRTXT="$(cat "$WORK/err.txt")"
  # A transport that could not be INVOKED (127 not-found / 126 not-executable) or that was KILLED by
  # the timeout (124) must never reach an assertion: its empty stdout is indistinguishable from an
  # ALLOW at every `! is_deny` arm. Treat all three as RED here, at the source.
  case "$RC" in
    124) gov_fail "the gate transport was KILLED by the 30s timeout — treat a timeout as RED, never as a slow pass: stderr=[$ERRTXT]" ;;
    126|127) gov_fail "the gate transport could not be executed (exit $RC) — that is an environment failure, not an allow verdict; its empty output would otherwise read as ALLOW: stderr=[$ERRTXT]" ;;
  esac
}

is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision" *: *"deny"'; }

# --- A/B/C, run against every available "unusable runtime" lane ------------------------------------

assert_lane() {
  local lane="$1" shim="$2"

  # CONTROL DENIES FIRST. Every allow-shaped assertion in this lane is written `! is_deny`, and EMPTY
  # output satisfies it. So before any allow result is trusted, this lane must prove it can observe a
  # DENY through the exact same transport, with actual bytes behind it. Without this control, a
  # transport that emitted nothing at all — a missing `timeout`, a wrapper that exits 0 silently, a
  # broken shim — would report every allow arm as PASSING while nothing was enforced, which is the
  # F57 shape this file exists to pin. A control that cannot deny means the lane is INERT, and an
  # inert lane must fail rather than certify.
  set_mode app-locked
  gate_via "$shim" Write "$REPO/src/x.ts"
  [ -n "$OUT" ] || gov_fail "[$lane] CONTROL: the enforcing probe produced ZERO bytes — this lane cannot tell an allow from a transport that says nothing, so its allow arms would pass for the wrong reason: rc=$RC stderr=[$ERRTXT]"
  is_deny || gov_fail "[$lane] CONTROL: the enforcing probe did not DENY, so no allow result from this lane is trustworthy: rc=$RC stdout=[$OUT] stderr=[$ERRTXT]"

  # A. an enforcing repo hard-denies rather than silently allowing.
  for mode in app-locked controlled; do
    set_mode "$mode"
    for probe_case in "Write:$REPO/src/x.ts" "Bash:gh pr merge 12 --squash" "Edit:$REPO/src/x.ts"; do
      gate_via "$shim" "${probe_case%%:*}" "${probe_case#*:}"
      [ "$RC" -eq 0 ] || gov_fail "[$lane/$mode] transport exited $RC (a PreToolUse hook must exit 0 and speak JSON): $ERRTXT"
      [ -n "$OUT" ] || gov_fail "[$lane/$mode] SILENT ALLOW on an unusable runtime for ${probe_case%%:*} — this is exactly F57 (zero bytes, mutation permitted)"
      is_deny || gov_fail "[$lane/$mode] transport did not hard-deny on an unusable runtime for ${probe_case%%:*}: stdout=[$OUT] stderr=[$ERRTXT]"
      printf '%s' "$OUT" | grep -qi 'python 3.10' \
        || gov_fail "[$lane/$mode] the denial does not name the runtime remedy: $OUT"
    done
  done

  # A'. a posture that CANNOT be established is treated as enforcing, never as `off` (F10 parity).
  printf 'pathway_enforcement:\n  mode: controllled\n' > "$REPO/WORKFLOW-config.yaml"
  gate_via "$shim" Write "$REPO/src/x.ts"
  is_deny || gov_fail "[$lane] a declared-but-unrecognized mode did not fail closed on an unusable runtime: stdout=[$OUT] stderr=[$ERRTXT]"

  # B. `off` still allows — its published contract is observe-and-allow — but never silently.
  set_mode off
  gate_via "$shim" Write "$REPO/src/x.ts"
  [ "$RC" -eq 0 ] || gov_fail "[$lane/off] transport exited $RC: $ERRTXT"
  ! is_deny || gov_fail "[$lane/off] a non-enforcing (off) repo was hard-denied on an unusable runtime — that bricks ordinary work: $OUT"
  printf '%s' "$ERRTXT" | grep -qi 'NOT ENFORCING' \
    || gov_fail "[$lane/off] allowed SILENTLY on an unusable runtime — the operator must be told enforcement is not running: stderr=[$ERRTXT]"

  # C. the documented debug downgrade turns the deny into the same loud allow.
  set_mode app-locked
  OUT="$(payload Write "$REPO/src/x.ts" | ( cd "$REPO" && PATH="${shim:+$shim:}$PATH" IDC_HOOKS_OBSERVE_ONLY=1 timeout 30 bash "$WRAPPER" "$GOV_PLUGIN" ) 2>"$WORK/err.txt")"
  RC=$?; ERRTXT="$(cat "$WORK/err.txt")"
  [ "$RC" -eq 0 ] || gov_fail "[$lane] observe-only downgrade exited $RC: $ERRTXT"
  ! is_deny || gov_fail "[$lane] IDC_HOOKS_OBSERVE_ONLY=1 did not downgrade the runtime denial: $OUT"
  printf '%s' "$ERRTXT" | grep -qi 'NOT ENFORCING' \
    || gov_fail "[$lane] observe-only downgrade went silent: stderr=[$ERRTXT]"
}

assert_lane shim "$SHIM"
[ -n "$REAL_OLD" ] && assert_lane real-old "$REAL_OLD"

# --- D. control: with a SUPPORTED interpreter the wrapper still delegates to the real gate ---------
# THE SUBSTANTIVE PROOF IS ALREADY DONE (A/B/C above): the transport fail-closes on an unusable
# runtime, on both interpreter lanes. What remains are CONTROL arms, and a control needs an ambient
# python3 the real gate can actually run. `run-all.sh` is this project's declared pre-commit gate, so
# on a host whose python3 predates 3.10 (stock macOS /usr/bin/python3 is 3.9.6, and reduced-PATH agent
# panes hit it routinely) these arms SKIP with a printed reason rather than redding the whole suite
# for a reason unrelated to the change under test (F65). Only 2 of the shipped modules require 3.10,
# so a red here would be an environment verdict, not a code verdict. The skip is loud and never
# silent, and it never relaxes an assertion that did run.
SKIPPED_CONTROL=""
if sh "$RUNTIME"; then
  AMBIENT_SUPPORTED=1
else
  AMBIENT_SUPPORTED=0
  SKIPPED_CONTROL=" (supported-interpreter control arms SKIPPED — see the SKIP line above)"
  echo "SKIP: the ambient python3 ($(python3 --version 2>&1)) predates 3.10, so the real gate cannot run here; sections D and F's honest-claim control are skipped. The fail-closed proof itself (A/B/C on both interpreter lanes, E, and F's unusable-runtime rows) DID run and passed above."
fi

if [ "$AMBIENT_SUPPORTED" -eq 1 ]; then
  set_mode app-locked
  gate_via "" Write "$REPO/src/x.ts"
  [ "$RC" -eq 0 ] || gov_fail "[supported] transport exited $RC: $ERRTXT"
  is_deny || gov_fail "[supported] the real gate no longer denies an unauthorized app-locked write — the runtime refusal must not have replaced enforcement: stdout=[$OUT] stderr=[$ERRTXT]"
  printf '%s' "$OUT" | grep -qi 'python 3.10' \
    && gov_fail "[supported] a runtime-refusal denial was emitted on a SUPPORTED interpreter (the preflight is misfiring): $OUT"

  set_mode off
  gate_via "" Write "$REPO/src/x.ts"
  [ "$RC" -eq 0 ] || gov_fail "[supported/off] transport exited $RC: $ERRTXT"
  ! is_deny || gov_fail "[supported/off] off mode hard-denied through the real gate: $OUT"
  printf '%s' "$ERRTXT" | grep -qi 'NOT ENFORCING' \
    && gov_fail "[supported/off] the runtime-refusal warning fired on a SUPPORTED interpreter: stderr=[$ERRTXT]"
fi

# --- E. the probe never drifts from the shipped parser --------------------------------------------
for mode_case in off controlled app-locked; do
  set_mode "$mode_case"
  got="$(cd "$REPO" && python3 "$PROBE" "$REPO")"
  parsed="$(PYTHONPATH="$GOV_PLUGIN/scripts" python3 -c 'import sys, idc_path_gate as G; print(G.pathway_mode(sys.argv[1]))' "$REPO")"
  [ "$got" = "$mode_case" ] || gov_fail "posture probe read '$got' for declared mode '$mode_case'"
  [ "$got" = "$parsed" ] || gov_fail "posture probe ('$got') disagrees with the shipped parser ('$parsed') for mode '$mode_case'"
done
printf 'pathway_enforcement:\n  mode: controllled\n' > "$REPO/WORKFLOW-config.yaml"
got="$(cd "$REPO" && python3 "$PROBE" "$REPO")"
[ "$got" = "unknown" ] || gov_fail "posture probe reported '$got' for a malformed mode — it must be 'unknown' so the caller fails closed"
rm -f "$REPO/WORKFLOW-config.yaml"
got="$(cd "$REPO" && python3 "$PROBE" "$REPO")"
[ "$got" = "off" ] || gov_fail "posture probe reported '$got' for a missing config — the shipped parser says 'off'"
got="$(python3 "$PROBE" "$WORK/no-such-repo-$$")"
[ "$got" = "off" ] || [ "$got" = "unknown" ] || gov_fail "posture probe emitted an unusable token '$got' for a nonexistent repo"

# --- F. the condition is DETECTED, not just refused: /idc:doctor row 4b calls it dishonest --------
# Before F57 nothing in the tree looked at the hook runtime — idc_python_runtime.sh was referenced
# only by the wrappers that consume it — so a repo could report itself fully wired while enforcing
# nothing. The doctor door asks the SAME preflight the wrappers ask, against the `python3` on PATH.
DOCTOR="$GOV_PLUGIN/scripts/idc_doctor_pathway_check.py"
[ -f "$DOCTOR" ] || gov_fail "doctor pathway door not found at $DOCTOR"

doctor_on() { ( cd "$REPO" && PATH="${1:+$1:}$PATH" timeout 30 python3 "$DOCTOR" --repo "$REPO" ) >"$WORK/doc.out" 2>"$WORK/doc.err"; }

# F's honest-claim CONTROL needs the ambient interpreter to be one the gate can run (F65 — same
# reasoning as D). Its substantive rows, the unusable-runtime lanes below, run unconditionally.
if [ "$AMBIENT_SUPPORTED" -eq 1 ]; then
  set_mode controlled
  doctor_on "" && DRC=0 || DRC=$?
  [ "$DRC" -eq 0 ] || gov_fail "doctor refused a github+controlled repo on a SUPPORTED interpreter (exit $DRC): $(cat "$WORK/doc.err")"
  grep -q 'pathway-claim: honest' "$WORK/doc.out" \
    || gov_fail "doctor did not report an honest claim for github+controlled on a supported interpreter: $(cat "$WORK/doc.out")"
fi

for lane_dir in "$SHIM" ${REAL_OLD:+"$REAL_OLD"}; do
  for mode_case in controlled app-locked; do
    set_mode "$mode_case"
    doctor_on "$lane_dir" && DRC=0 || DRC=$?
    [ "$DRC" -eq 1 ] \
      || gov_fail "doctor exited $DRC for a '$mode_case' repo whose python3 cannot run the gate — an undetectable unrunnable enforcement leg is exactly F57's third leg: out=[$(cat "$WORK/doc.out")] err=[$(cat "$WORK/doc.err")]"
    grep -qi 'python 3.10' "$WORK/doc.err" \
      || gov_fail "doctor's refusal does not name the runtime as the cause: $(cat "$WORK/doc.err")"
    grep -q 'pathway-claim: honest' "$WORK/doc.out" \
      && gov_fail "doctor printed the honest token while the enforcement leg cannot run: $(cat "$WORK/doc.out")"
  done
  # `off` claims nothing, so an old interpreter is not a dishonest claim there.
  set_mode off
  doctor_on "$lane_dir" && DRC=0 || DRC=$?
  [ "$DRC" -eq 0 ] || gov_fail "doctor failed an 'off' repo purely for an old interpreter (exit $DRC) — off makes no enforcement claim: $(cat "$WORK/doc.err")"
done

echo "PASS: the Path Gate transport hard-denies on an unusable runtime in enforcing modes (and on an unreadable posture), stays loud-but-allowing in off mode, honors the observe-only downgrade, still delegates to the real gate on a supported interpreter, its posture probe tracks the shipped parser, and /idc:doctor row 4b reports the unrunnable enforcement leg as a dishonest claim${SKIPPED_CONTROL}"
