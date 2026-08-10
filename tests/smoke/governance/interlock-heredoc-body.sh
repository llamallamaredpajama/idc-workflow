#!/bin/bash
# idc-assert-class: behavior
# interlock-heredoc-body.sh — a here-document BODY is data, not shell syntax.
#
# `shlex` knows nothing about here-documents, so the interlock used to lex the BODY as shell text. A
# `git commit -F - <<'EOF'` message is ordinary prose, and one apostrophe in "don't" is an unterminated
# quote to the lexer: the commit was then refused as unparseable — surfacing as
# `[opaque-shell-indirection]` when the prose ALSO happened to contain a word like "source" or "sh"
# (`_mentions_interpreter_form` reads the same text), else as an unprovable mutation target. Under
# `controlled` that denied an ordinary commit for having an apostrophe in its message.
#
# Proves, driving the real interlock module:
#   1. the reported shape (apostrophe + the word "source" in the body) is ALLOWED — no finding, no deny;
#   2. an apostrophe alone in the body is ALLOWED (the second, differently-worded denial path);
#   3. an INTERPRETER here-document is STILL denied — the guard that actually covers a mutation hidden
#      in a body survives, because the `<<DELIM` operator token is preserved;
#   4. a redirect target on the opener line is STILL collected (`cat > TRACKER.md <<'EOF'`);
#   5. a genuinely unbalanced quote OUTSIDE any here-document still fails closed;
#   6. an UNTERMINATED here-document is left byte-for-byte alone — the stripper never truncates a
#      command into looking clean;
#   7. a command AFTER a terminated here-document is still analyzed (its redirect target collected), so
#      removing a body cannot hide what follows it.
#
# Red-when-broken (reviewed): delete the `_strip_heredoc_bodies` call in `_analyze_shell_mutations` =>
# 2 flips; delete it in `collect_findings` => 1 flips; make `_strip_heredoc_bodies` drop the `<<DELIM`
# operator => 3 flips; make it strip to end-of-text when no terminator is found => 6 flips; make it
# also consume the opener line => 4 flips.
#
# Usage: bash tests/smoke/governance/interlock-heredoc-body.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
[ -f "$GATE" ] || gov_fail "scripts/hooks/idc_interlock_gate.py not found"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# The probe prints one line per case: "<name> findings=<n> deny=<0|1> paths=<basenames>". Driving the
# module directly (rather than the hook transport) keeps the assertions about the CLASSIFIER, which is
# where the defect lived; path-gate-interlock-denial.sh already covers the transport.
PYTHONPATH="$GOV_PLUGIN/scripts:$GOV_PLUGIN/scripts/hooks" python3 - "$WORK" >"$WORK/probe.out" 2>"$WORK/probe.err" <<'PY' \
  || { echo "FAIL: could not drive the interlock classifier"; cat "$WORK/probe.err"; exit 1; }
import os, sys
import idc_interlock_gate as IG

cwd = sys.argv[1]
cases = {
    "reported_shape": "git add app.py && git commit -F - <<'EOF'\nfix: don't drop the row\n\nTRACKER.md is the source of truth.\nEOF",
    "apostrophe_only": "git add app.py && git commit -F - <<'EOF'\nfix: don't drop the row\nEOF",
    "interpreter_heredoc": "python3 - <<'EOF'\nimport os\nos.system(\"gh issue create --title x\")\nEOF",
    "redirect_target": "cat > TRACKER.md <<'EOF'\nticket: hand-written\nEOF",
    "unbalanced_outside": "bash -c 'echo unterminated",
    "command_after_body": "git commit -F - <<'EOF'\nmsg\nEOF\ncat > TRACKER.md",
}
for name, command in cases.items():
    findings = IG.collect_findings(command, cwd, "")
    analysis = IG._analyze_shell_mutations(command, cwd, cwd, "")
    names = ",".join(sorted(os.path.basename(p) for p in analysis.paths)) or "-"
    print(f"{name} findings={len(findings)} deny={1 if analysis.deny_reason else 0} paths={names}")

# An UNTERMINATED here-document must come back byte-for-byte: the stripper may never decide, on its
# own, that the rest of a command is a body it can delete.
unterminated = "git commit -F - <<'EOF'\nmsg\nrm -rf TRACKER.md"
print(f"unterminated_unchanged verdict={1 if IG._strip_heredoc_bodies(unterminated) == unterminated else 0}")
PY

probe() { grep -E "^$1 " "$WORK/probe.out" || gov_fail "probe produced no line for case '$1'"; }

# 1 + 2 — the false positives are gone: no finding AND no mutation-analysis denial.
for case_name in reported_shape apostrophe_only; do
  line="$(probe "$case_name")"
  case "$line" in
    *"findings=0 deny=0"*) : ;;
    *) gov_fail "an ordinary heredoc commit is still refused ($case_name): $line" ;;
  esac
done

# 3 — the real guard survives: an interpreter here-document is still denied.
line="$(probe interpreter_heredoc)"
case "$line" in
  *"deny=1"*) : ;;
  *) gov_fail "an interpreter here-document is no longer denied — stripping opened a smuggling hole: $line" ;;
esac

# 4 — the opener line's redirect target is still collected for the write door.
line="$(probe redirect_target)"
case "$line" in
  *"paths=TRACKER.md"*) : ;;
  *) gov_fail "a heredoc redirect target is no longer collected: $line" ;;
esac

# 5 — a genuine unbalanced quote outside a here-document still fails closed.
line="$(probe unbalanced_outside)"
case "$line" in
  *"deny=1"*) : ;;
  *) gov_fail "an unparseable non-heredoc command no longer fails closed: $line" ;;
esac

# 6 — an unterminated here-document is returned byte-for-byte unchanged.
line="$(probe unterminated_unchanged)"
case "$line" in
  *"verdict=1"*) : ;;
  *) gov_fail "an unterminated here-document was altered by the stripper — it may truncate a command into looking clean: $line" ;;
esac

# 7 — what FOLLOWS a stripped body is still analyzed.
line="$(probe command_after_body)"
case "$line" in
  *"paths=TRACKER.md"*) : ;;
  *) gov_fail "removing a here-document body hid the command after it: $line" ;;
esac

echo "PASS: interlock-heredoc-body"
