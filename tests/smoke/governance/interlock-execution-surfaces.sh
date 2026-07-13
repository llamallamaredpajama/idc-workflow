#!/bin/bash
# interlock-execution-surfaces.sh — every statically visible shell execution surface reaches the
# same normalized classifier; opaque executable surfaces fail closed without turning ordinary data
# arguments or heredoc documentation into commands.
#
# Red-when-broken: restore the pre-round-19 split between raw segments, token heads, substitutions,
# groups, and redirected files. The quoted/escaped API endpoints, stdin-fed interpreters, computed
# heads, eval payloads, compound-command stdin, or interpreter heredocs below then escape; the data
# consumers also become false denies.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/../../.." && pwd)"
GATE="$PLUGIN/scripts/hooks/idc_interlock_gate.py"
[ -f "$GATE" ] || { echo "FAIL: interlock gate missing at $GATE"; exit 1; }

python3 - "$GATE" "$PLUGIN" <<'PY'
import importlib.util
import sys

gate_path, plugin_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_interlock_execution_surfaces_test", gate_path)
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)

must_deny = (
    # API endpoints are classified from the same dequoted token the shell executes; write indicators
    # remain order-robust in the raw surface.
    "gh api graph\"ql\" -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}}'",
    "gh api graph\\ql -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}}'",
    "gh api repos/o/r/iss\"ues\"/7 -X PATCH -f state=closed",
    "gh api repos/o/r/iss\\ues/7 -X PATCH -f state=closed",

    # A shell with no argv script still executes stdin. Static producers may be inspected; otherwise
    # the executable surface must fail closed rather than being waved through as a bare interpreter.
    "printf '%s\\n' 'gh issue create --title x --body x' | bash",
    "echo 'gh issue close 7' | sh",
    "bash <<< 'gh issue create --title x --body x'",
    "printf '%s\\n' 'gh issue create --title x --body x' | (bash)",

    # A quoted one-word computed write is protected by its following gh shape; an unquoted command
    # substitution is split-capable and therefore fails closed regardless of the apparent inner text.
    'G=gh; "$G" issue create --title x --body x',
    '$(printf gh) issue create --title x --body x',

    # An UNQUOTED expansion in command position undergoes field splitting. It may therefore supply
    # the complete protected command, not merely one computed executable word.
    "CMD='gh issue create'; $CMD --title x --body x",
    "$(printf 'gh issue create') --title x --body x",
    "$(printf gh) issue view 7",
    "printf() { command printf 'gh issue create'; }; $(printf gh) --title x --body x",

    # Static eval payloads recurse through the same surface model; dynamic payloads are opaque.
    "eval 'gh issue create --title x --body x'",
    "eval \"$CMD\"",
    "bash -c \"eval 'gh issue create --title x --body x'\"",
    "bash -c 'eval \"$CMD\"'",

    # Whitespace before a redirect keeps the numeric word as argv, so bash would execute file `2`.
    # The missing target is opaque; an adjacent `2>` below is syntax and remains allowed.
    "bash 2 > /dev/null",

    # Heredoc bodies become stdin data. They execute only when the consumer is a shell; delimiter
    # quoting and tab-stripping do not change that execution boundary.
    "bash <<'EOF'\ngh issue create --title x --body x\nEOF",
    "sh <<EOF\ngh issue close 7\nEOF",
    "zsh <<-'EOF'\n\tgh project item-delete 8 --owner o --id X\n\tEOF",

    # `-s` explicitly selects stdin as the shell program. Every later positional is an argument to
    # that program, so even a sanctioned plugin-script pathname cannot masquerade as the script file.
    "bash -s -- '{}/scripts/idc_transition.py' <<< 'gh issue create --title x --body x'".format(plugin_root),
    "printf '%s\\n' 'gh issue create --title x --body x' | sh -s -- '{}/scripts/idc_transition.py'".format(plugin_root),
    "zsh -s -- '{}/scripts/idc_transition.py' <<'EOF'\ngh issue create --title x --body x\nEOF".format(plugin_root),

    # A compound command owns pipe/redirection stdin for every command inside it. Parentheses and
    # braces share the same invariant, including a left pipeline and every trailing stdin form.
    "(bash) <<< 'gh issue create --title x --body x'",
    "{ bash; } <<< 'gh issue create --title x --body x'",
    "printf '%s\\n' 'gh issue create --title x --body x' | { :; bash; }",
    "(bash) < '{}/tests/smoke/fixtures/session-b7a93ff6/fire_gate.sh'".format(plugin_root),
    "{ bash; } <<'EOF'\ngh issue create --title x --body x\nEOF",

    # An unquoted data-consumer heredoc still performs parent-shell substitutions.
    "cat <<EOF\n$(gh issue create --title x --body x)\nEOF",
)

must_allow = (
    # Quoting proves the computed executable is exactly one word, so a read-shaped argv stays allowed.
    'G=gh; "$G" issue view 7',
    '"$(printf gh)" issue view 7',

    # Quoting suppresses field splitting: these are single executable names containing spaces, not
    # a `gh issue create` command assembled from several words.
    "CMD='gh issue create'; \"$CMD\" --title x --body x",
    '"$(printf \'gh issue create\')" --title x --body x',

    # Protected words in ordinary argv stay data.
    "echo 'gh issue create --title example'",
    "git commit -m 'docs: explain gh issue create'",
    "printf '%s\\n' gh issue create",
    "grep -F gh issue create README.md",
    "echo '>' '<' '<<' '<<<'",
    "bash 2>/dev/null",

    # Heredoc content sent to a data consumer is not an executable surface, for every delimiter class.
    "cat <<'EOF'\ngh issue create --title x --body x\nEOF",
    "cat <<EOF\ngh issue close 7\nEOF",
    "cat <<-'EOF'\n\tgh project item-delete 8 --owner o --id X\n\tEOF",
    "cat <<'EOF'\n$(gh issue create --title x --body x)\nEOF",
    "(cat) <<< 'gh issue create --title x --body x'",
    "{ cat; } <<'EOF'\ngh issue create --title x --body x\nEOF",
    "printf '%s\\n' 'gh issue create --title x --body x' | { :; cat; }",

    # The existing sanctioned plugin-script boundary remains intact.
    'bash "{}/scripts/idc_transition.py"'.format(plugin_root),
    'bash < "{}/scripts/idc_transition.py"'.format(plugin_root),
    'bash 0< "{}/scripts/idc_transition.py"'.format(plugin_root),
)

failures = []
for command in must_deny:
    if gate.classify(command, plugin_root, plugin_root, True) is None:
        failures.append("executable surface escaped: " + command)
for command in must_allow:
    finding = gate.classify(command, plugin_root, plugin_root, True)
    if finding is not None:
        failures.append("data/read surface was classified: {} => {}".format(command, finding.subject))

if failures:
    for failure in failures:
        print("FAIL: " + failure)
    raise SystemExit(1)

print("PASS: normalized executable surfaces deny protected writes and opaque execution while preserving data arguments")
PY
