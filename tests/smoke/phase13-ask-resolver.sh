#!/usr/bin/env bash
# idc-assert-class: behavior
# phase13-ask-resolver.sh — the /idc:ask intent resolver decision table.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$REPO_ROOT" <<'PY' || fail "resolver decision table"
import os, sys
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
]
for text, verdict, command, reason in CASES:
    got = R.resolve_keywords(text)
    assert got["verdict"] == verdict, (text, got)
    assert got["command"] == command, (text, got)
    if reason is not None:
        assert got["reason_code"] == reason, (text, got)

# --- the structural backstop: nothing may ever route to a lifecycle command ---
for cmd in R.LIFECYCLE_ONLY:
    assert cmd not in R.ROUTABLE, cmd
PY

echo "PASS: phase13-ask-resolver"
