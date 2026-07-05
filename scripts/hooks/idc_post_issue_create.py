#!/usr/bin/env python3
"""idc_post_issue_create.py — the PostToolUse issue-create-add board-coherence observer
(v4 Phase 3 Stage D, plan §3.2 "PostToolUse (gh issue create)").

Fires on PostToolUse for the Bash tool. After a SUCCESSFUL `gh issue create`, checks whether the SAME
shell command also routed the new issue onto the project board with Stage+Status (through the single
write door, `idc_transition.py`, or a direct `gh project item-add`) — and if not, injects the exact
remediation naming the door command. This closes the other half of the 394ec6fe "loose gh
improvisation" class (#242/#243/#247-#250): a raw `gh issue create` typed by hand mints an issue that
is invisible to every board-driven gate (autorun, recirculate, acceptance) until someone notices and
manually adds it.

DETECTING A SUCCESSFUL CREATE FROM THE PAYLOAD (no `exit_code` exists): the real Claude Code Bash
PostToolUse `tool_response` carries only `{stdout, stderr, interrupted, ...}` — there is NO `exit_code`
field. So success is inferred from the command's own output: a successful `gh issue create` prints the
new issue's URL. An interrupted run, or output with no parseable issue URL (a failed/aborted create),
yields no number → the observer stays silent (fail-open by omission — nothing provable is asserted).

WHY "WITHIN THE SAME COMMAND", NOT A LIVE BOARD CHECK: the sanctioned create ops
(create-ticket/create-pointer/recirculate-intake) create the backing issue AND add it to the board as
ONE atomic operation (idc_gh_board.create_item) — so an issue-create that happened *through* the door
never reaches this observer's classifier at all (it never ran a raw `gh issue create`). The only way
this hook's matcher fires is a RAW `gh issue create` bypassing the door — and the cheapest, zero-
GraphQL way to tell whether that raw create was immediately followed by a compensating board-add is a
STRING check on the command Claude actually ran (e.g. `gh issue create --title … && python3
idc_transition.py … recirculate-intake …`), not a live board query per create (no new expensive board
GraphQL on this hook path — plan §3.2 / P4 contract). A false negative here (the agent added it to the
board in a LATER, separate Bash call) is possible and accepted: this observer is a nudge, not a
guarantee, and a later legitimate board-add is harmless — it just means this one warning was
unnecessary noise, never a wrongly-suppressed one.

KNOWN GAP THIS REMEDIATION IS HONEST ABOUT: `idc_transition.py`'s create ops always mint a NEW backing
issue (idc_gh_board.create_item) — there is currently no sanctioned "attach this EXISTING issue number
to the board" op. So the remediation names the real, available options rather than inventing a door
command that doesn't exist: attach the issue that was just created via `gh project item-add` (a raw
board mutation the PreToolUse interlock gate ALSO flags independently — the two observers are allowed
to overlap; this one is scoped to "was it added at all", not "was the write sanctioned") and then set
its Stage+Status through the engine's `move` op (with the github project coordinates on the github
backend — omitting them makes the move fail), OR prefer `idc_transition.py create-ticket` /
`create-pointer` next time so create + board-add happen atomically and this observer never fires.

FAIL MODE (P4): a post-hoc observer, so fail-OPEN, ALWAYS (idc_hook_lib.guard_post_observer) — any
internal error here warns and exits 0, never touching the outcome of the `gh issue create` that
already ran.

Invocation: idc_post_issue_create.py <PLUGIN_ROOT>   (PostToolUse payload on stdin).
Self-gated: no-op outside a governed repo, for a non-Bash tool, for a command that isn't a `gh issue
create`, for a create that did not land, or when the SAME command already routes through a board-add.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402
import idc_interlock_gate as IG  # noqa: E402 — reuse the whitespace-flexible command matcher (_has)

_ISSUE_URL_RE = re.compile(r"/issues/(\d+)\b")

# Substrings that mean "this same shell command ALSO routed the new issue onto the board" — either the
# sanctioned door (any idc_transition.py create/add op) or a raw board mutation (still counts as
# "added", even though the PreToolUse interlock separately flags the raw form as unsanctioned — that is
# a different concern from THIS observer's narrower "was it added at all" check).
_BOARD_ADD_MARKERS = (
    "idc_transition.py",   # create-ticket / create-pointer / recirculate-intake / move, in one chain
    "gh project item-add",  # a raw (but still board-adding) attach
)


def _is_issue_create(command):
    """A raw `gh issue create` (any flags) — same whitespace-flexible, word-boundary matcher the
    PreToolUse interlock gate uses (imported, not re-derived)."""
    return IG._has(command, "gh issue create")


def _same_command_added_to_board(command):
    """True iff the SAME shell command string also carries a board-add marker (a `&&`-chained
    idc_transition.py call, or a raw `gh project item-add`). A pure substring check — no shell parse —
    same documented posture as the interlock gate's classifier: harmless false-negative bias (an
    unrelated string match would suppress a warning that was needed, but the marker strings here are
    specific enough that this is very unlikely in practice)."""
    return any(marker in command for marker in _BOARD_ADD_MARKERS)


def _parse_created_issue_number(text):
    """The issue number from `gh issue create`'s own output (it prints the new issue's URL), or None
    if unparseable. Purely a string parse of output already produced by the command — no extra call."""
    if not isinstance(text, str):
        return None
    m = _ISSUE_URL_RE.search(text)
    return int(m.group(1)) if m else None


def _created_issue_number(tool_response):
    """The new issue's number iff `gh issue create` actually succeeded, else None. The real PostToolUse
    Bash tool_response has NO exit_code (only stdout/stderr/interrupted), so success == the command's
    output carries the new issue URL and the run wasn't interrupted."""
    if not isinstance(tool_response, dict):
        return None
    if tool_response.get("interrupted"):
        return None
    text = (tool_response.get("stdout") or "") + "\n" + (tool_response.get("stderr") or "")
    return _parse_created_issue_number(text)


def _read_backend(cwd, plugin_root):
    """The governed repo's tracker backend (reuses idc_recirc_sweep.read_backend). Defaults to
    filesystem when undeterminable — mirrors the commit-sync observer's helper."""
    scripts = os.path.join(plugin_root or "", "scripts")
    if os.path.isdir(scripts) and scripts not in sys.path:
        sys.path.insert(0, scripts)
    try:
        import idc_recirc_sweep as SW
        return SW.read_backend(cwd) or "filesystem"
    except Exception:  # noqa: BLE001 — undeterminable backend defaults to filesystem
        return "filesystem"


def _remediation(issue_num, repo, engine, backend):
    coords = " --backend github --owner <owner> --project <n>" if backend == "github" else ""
    return (
        f"IDC board-coherence: `gh issue create` (issue #{issue_num}) succeeded, but this same command "
        "did not also add the new issue to the project board with Stage+Status — it is invisible to "
        "every board-driven gate (autorun/recirculate/acceptance) until it's added. There is no "
        "sanctioned \"attach an existing issue\" op yet, so: attach it (`gh project item-add <project> "
        "--owner <owner> --url <issue-url>`) then set Stage+Status through the engine (`python3 "
        f"{engine} --repo {repo}{coords} move --num {issue_num} --to-status Todo`) — or next time prefer "
        "`idc_transition.py create-ticket`/`create-pointer`/`recirculate-intake`, which create the "
        "issue AND add it to the board atomically, so this observer never fires."
    )


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    if not H.is_governed_repo(cwd):
        return
    if payload.get("tool_name") != "Bash":
        return
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip() or not _is_issue_create(command):
        return
    issue_num = _created_issue_number(payload.get("tool_response") or {})
    if issue_num is None:
        return  # not a confirmed successful create — nothing provable, stay silent (fail-open)
    if _same_command_added_to_board(command):
        return  # this command chain already routes through a board-add — coherent

    engine = os.path.join(plugin_root or "", "scripts", "idc_transition.py")
    backend = _read_backend(cwd, plugin_root)
    H.post_tool_inject(_remediation(issue_num, cwd, engine, backend))


if __name__ == "__main__":
    H.guard_post_observer(_gate)
