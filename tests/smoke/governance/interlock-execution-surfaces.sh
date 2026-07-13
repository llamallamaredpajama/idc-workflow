#!/bin/bash
# interlock-execution-surfaces.sh — every statically visible shell execution surface reaches the
# same normalized classifier; opaque executable surfaces fail closed without turning ordinary data
# arguments or heredoc documentation into commands.
#
# Red-when-broken: break the shared surface construction or restore raw API flag scans, one-word-only
# quote roles, non-recursive deferred/file execution, or all-parenthesis group parsing. The denials
# below then escape and the paired formatting/array/data controls become false hard denials.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/../../.." && pwd)"
GATE="$PLUGIN/scripts/hooks/idc_interlock_gate.py"
[ -f "$GATE" ] || { echo "FAIL: interlock gate missing at $GATE"; exit 1; }

python3 - "$GATE" "$PLUGIN" <<'PY'
import importlib.util
import os
import shlex
import sys
import tempfile

gate_path, plugin_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_interlock_execution_surfaces_test", gate_path)
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)

tmp = tempfile.TemporaryDirectory(prefix="idc-direct-exec-")
direct_write = os.path.join(tmp.name, "direct-write.sh")
with open(direct_write, "w") as fh:
    fh.write("#!/bin/bash\ngh issue create --title x --body x\n")
os.chmod(direct_write, 0o700)

direct_nested = os.path.join(tmp.name, "direct-nested.sh")
with open(direct_nested, "w") as fh:
    fh.write("#!/bin/bash\n{}\n".format(shlex.quote(direct_write)))
os.chmod(direct_nested, 0o700)

direct_binary = os.path.join(tmp.name, "direct-binary")
with open(direct_binary, "wb") as fh:
    fh.write(b"\x7fELF\x00gh issue create --title inert --body inert\x00")
os.chmod(direct_binary, 0o700)

sensitive_direct = os.path.join(tmp.name, "secret-handler.sh")
os.mkfifo(sensitive_direct)
os.chmod(sensitive_direct, 0o700)

must_deny = (
    # API endpoints are classified from the same dequoted token the shell executes; write indicators
    # remain order-robust in the raw surface.
    "gh api graph\"ql\" -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}}'",
    "gh api graph\\ql -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}}'",
    "gh api repos/o/r/iss\"ues\"/7 -X PATCH -f state=closed",
    "gh api repos/o/r/iss\\ues/7 -X PATCH -f state=closed",

    # REST policy consumes the shell-normalized option argv, not raw formatting text. Quote removal
    # may assemble a real method/body flag; every method occurrence and dynamic option role remains
    # fail-closed on a protected endpoint.
    "gh api repos/o/r/issues/7 --meth\"od\" DELETE",
    "gh api repos/o/r/issues/7 -\"\"X GET --meth\"od\" PATCH",
    "gh api repos/o/r/issues/7 --raw-\"field\" state=closed",
    "gh api repos/o/r/issues/7 --meth\"od\"=DELETE",
    "OPT=--method; gh api repos/o/r/issues/7 \"$OPT\" DELETE",
    "gh api repos/o/r/issues/7 --meth\"od\" \"$METHOD\"",
    "gh api repos/o/r/issues/7 --jq \"$@\"",
    "gh api repos/o/r/issues/7 --jq $FILTER",
    "PART='7 --method DELETE'; gh api repos/o/r/issues/$PART",
    "gh api \"repos/o/r/issues/$@\"",

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

    # Double quotes do not always prove one argv word: "$@" and all-elements array expansions retain
    # their many-word cardinality when used as the executable head.
    '"$@" --title x --body x',
    '"${args[@]}" --title x --body x',
    '"${!args[@]}" --title x --body x',
    '"${args[@]/x/y}" --title x --body x',

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

    # Trap handlers are deferred shell programs. Every static executable registration recurses
    # through the same model, while an expansion-computed handler is opaque executable code.
    "trap 'gh issue create --title x --body x' EXIT",
    "trap 'gh issue close 7' 0",
    "trap 'gh project item-delete 8 --owner o --id X' INT TERM",
    'trap "$HANDLER" EXIT',
    "bash -c \"trap 'gh issue create --title x --body x' EXIT\"",

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

    # An explicit executable path is itself a file execution surface, even without a `bash FILE`
    # wrapper. Nested direct shell files stay bounded by the same recursive inspector.
    shlex.quote(direct_write),
    shlex.quote(direct_nested),
    shlex.quote(sensitive_direct),

    # Array literals are data, but substitutions inside them still execute in the assigning shell.
    "args=($(gh issue create --title x --body x))",
    "args=(<(gh issue close 7))",

    # Parenthesized command groups remain executable; array masking must not hide real groups.
    "(gh issue create --title x --body x)",
    "x=1; (gh issue close 7)",
)

must_allow = (
    # Quoting proves the computed executable is exactly one word, so a read-shaped argv stays allowed.
    'G=gh; "$G" issue view 7',
    '"$(printf gh)" issue view 7',
    '"${cmd[0]}" issue view 7',
    '"${cmd[*]}" issue view 7',

    # Multiword expansions in ordinary argument position are data, not executable heads.
    "printf '%s\\n' \"$@\" gh issue create",

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

    # Method-looking text owned by read-only formatting/header/template options is inert data. A
    # dequoted literal GET remains a provable protected-endpoint read.
    "gh api repos/o/r/issues/7 --meth\"od\" GET",
    "gh api repos/o/r/issues/7 --jq '\"-X DELETE\"'",
    "gh api repos/o/r/issues/7 -H 'X-Note: --method DELETE'",
    "gh api repos/o/r/issues/7 --template '{{printf \"-f state=closed\"}}'",
    "gh api repos/o/r/issues/7 --jq \"$FILTER\"",
    "gh api \"repos/o/r/issues/$NUM\"",
    "gh api graphql -f query='query{viewer{login}}' --jq '\"--input mutation.json\"'",
    "gh api graphql --jq '\"-f query={viewer{id}}\"' -f query='query{viewer{login}}'",

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

    # Only explicit shell-file execution is inspected: binaries and arbitrary PATH command names are
    # not opened, and direct plugin helpers retain the sanctioned scripts boundary.
    shlex.quote(direct_binary),
    "direct-write.sh",
    '"{}/scripts/run-evals.sh"'.format(plugin_root),

    # Shell array assignment parentheses contain data rather than a command group. Quote-aware
    # substitution extraction above still owns any executable substitutions inside these values.
    "args=(gh issue create --title x --body x)",
    "args+=(gh issue close 7)",
    "declare -a args=(gh project item-delete 8 --owner o --id X)",
    "declare -A docs=([command]='gh issue create' [finish]='gh pr merge')",

    # Trap list/reset/ignore forms do not register executable code; ordinary handler arguments remain
    # data unless their handler itself executes a protected command.
    "trap",
    "trap -p EXIT",
    "trap -l",
    "trap - EXIT",
    "trap '' EXIT",
    "trap ':' EXIT",
    "trap 'echo gh issue create' EXIT",
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
