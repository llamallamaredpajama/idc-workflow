#!/usr/bin/env bash
# idc-assert-class: behavior
# phase13-ask-resolver.sh — the /idc:ask intent resolver decision table.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$REPO_ROOT" <<'PY' || fail "resolver decision table"
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_ask_resolve as R

# --- pure keyword decisions (oracle never consulted; repo may be anything) ---
CASES = [
    ("stop work here",                 "route",    "pause",   "keyword-pause"),
    ("I'm done for now",               "route",    "pause",   "keyword-pause"),
    ("pick up where we left off",      "route",    "resume",  "keyword-resume"),
    ("carry on",                       "route",    "resume",  "keyword-resume"),
    ("is anything broken?",            "route",    "doctor",  "keyword-doctor"),
    ("tidy up the board",              "route",    "janitor", "keyword-janitor"),
    # conflict -> never guess
    ("stop and then pick up later",    "advisory", None,      "ambiguous"),
    # lifecycle -> never routed, and lifecycle wins over a co-occurring cue
    ("uninstall idc",                  "advisory", None,      "lifecycle-command"),
    ("update idc and then stop",       "advisory", None,      "lifecycle-command"),
    # substring safety
    ("this is a stopgap measure for the driftwood",
                                       "advisory", None,      None),
    # An explicit rejection is never a route to the rejected command.
    ("do not resume",                "advisory", None,      None),
]
for text, verdict, command, reason in CASES:
    got = R.resolve_keywords(text)
    assert got["verdict"] == verdict, (text, got)
    assert got["command"] == command, (text, got)
    if reason is not None:
        assert got["reason_code"] == reason, (text, got)

# --- the structural backstop: even a future keyword cannot route to a lifecycle command ---
original_keywords = R.KEYWORDS
try:
    R.KEYWORDS = dict(R.KEYWORDS, init=("initialize",))
    got = R.resolve_keywords("initialize")
    assert got["verdict"] == "advisory", got
    assert got["command"] is None, got
finally:
    R.KEYWORDS = original_keywords

# --- full resolver decision table: oracle action, safe parsing, and exception fallback ---
def action(verdict, command=None):
    return R.NEXT.NextAction(verdict, "test-" + verdict, command, ("#1",), {"items": 1})

ORACLE_CASES = [
    (action("action", "/idc:build --unit U1"), "route", "build", "--unit U1", "oracle-action"),
    # The final backstop must also reject a forbidden command from the oracle.
    (action("action", "/idc:update --force"), "advisory", None, "", "no-match"),
    (action("waiting"), "advisory", None, "", "oracle-waiting"),
    (action("no_action"), "advisory", None, "", "oracle-fixpoint"),
    (action("invalid"), "advisory", None, "", "oracle-invalid"),
    (action("blocked_external"), "advisory", None, "", "oracle-rate-limited"),
]
original_decide = R.NEXT.decide
try:
    for oracle_action, verdict, command, command_args, reason in ORACLE_CASES:
        R.NEXT.decide = lambda repo, value=oracle_action: value
        got = R.resolve("/ignored-by-keywords", "please tell me what is next")
        assert (got["verdict"], got["command"], got["command_args"], got["reason_code"]) == (
            verdict, command, command_args, reason
        ), got

    def broken_decide(repo):
        raise RuntimeError("oracle unavailable")

    R.NEXT.decide = broken_decide
    got = R.resolve("/ignored-by-keywords", "please tell me what is next")
    assert (got["verdict"], got["command"], got["reason_code"]) == (
        "advisory", None, "oracle-invalid"
    ), got
finally:
    R.NEXT.decide = original_decide

# --- CLI failure contract: an unreadable/non-directory repo is a deliberate exit 2 ---
with tempfile.TemporaryDirectory() as work:
    missing = os.path.join(work, "not-a-directory")
    completed = subprocess.run(
        [sys.executable, os.path.join(sys.argv[1], "scripts", "idc_ask_resolve.py"),
         "--repo", missing, "--text", "stop", "--json"],
        text=True, capture_output=True,
    )
    assert completed.returncode == 2, (completed.returncode, completed.stdout, completed.stderr)
    assert "--repo must be a readable directory" in completed.stderr, completed.stderr
PY

echo "PASS: phase13-ask-resolver"
