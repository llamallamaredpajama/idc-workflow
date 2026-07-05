#!/usr/bin/env python3
"""idc_post_commit_sync.py — the PostToolUse commit-sync board-coherence observer
(v4 Phase 3 Stage D, plan §3.2 "PostToolUse (git commit)").

Fires on PostToolUse for the Bash tool. After a SUCCESSFUL `git commit`, checks whether the commit's
linked board item is `In Progress` (the shape a claimed, actively-worked item should be in) and, if
not, either auto-repairs it through the single write door (`idc_transition.py move`) or — when the
repair itself isn't possible/safe — injects the exact remediation as model-visible context. This is
the self-repair half of forensic drops #242/#243/#247-#250 ("loose gh improvisation" / claim-drift):
an agent that committed work without claiming the item first leaves the board out of sync with
reality; this observer closes that gap the moment it happens, side-band, at zero added workflow
latency.

DETECTING A LANDED COMMIT FROM THE PAYLOAD (no `exit_code` exists): the real Claude Code Bash
PostToolUse `tool_response` carries only `{stdout, stderr, interrupted, isImage, ...}` — there is NO
`exit_code` field (verified against real transcripts and the official security-guidance
PostToolUse[Bash] commit-review hook, which infers success from output text for exactly this reason).
So success is inferred from the command's own output: a landed `git commit` prints a `[<branch> <sha>]`
header plus a diffstat/create-mode/root-commit line; an interrupted or rejected run does not.

LINKAGE CONVENTION (no prior scheme exists in this codebase — this is a new, deliberately simple,
deliberately documented one, cheap to compute from data already on disk at commit time, no board read
required). Only signals reliable enough to safely drive board coherence are trusted:
  1. An explicit trailer/keyword in the commit message: `(?i)^\\s*(?:issue|item)\\s*:\\s*#?(\\d+)\\s*$`
     on its own line (e.g. `Issue: #42`) — a deliberate declaration.
  2. Else, a leading numeric token in the current branch name: `(?:^|/)(?:issue-)?(\\d+)(?:[-_]|$)`
     (e.g. `42-fix-thing`, `build/42-fix-thing`, `issue-42`) — the developer's working branch.
A bare `#N` elsewhere in the message is DELIBERATELY NOT used as a linkage source: it is too often an
incidental cross-reference (`refs #12`, "follow-up to #7") or a squash PR number (`(#140)`) to safely
name the worked item — and a wrong-item repair MUTATION is not fail-open-safe (reviewer finding; the
"a wrong guess is worse than saying nothing" principle). If neither trusted signal matches, the linked
item is UNDETERMINABLE and this observer stays silent (fail-open by omission).

BACKEND SPLIT (no new expensive board GraphQL on this hook path — plan §3.2 / P4 contract):
  * filesystem — a local TRACKER.md read is cheap (no GraphQL analog), so this path does the REAL
    coherence check (read the item's Status) and, on drift, tries a REAL repair (`idc_transition.py
    move --to-status "In Progress"` — status-only; the fs tracker has no owner field, so nothing is
    clobbered) before falling back to inject. The hermetically-tested, load-bearing path.
  * github — reading true board state costs a live GraphQL call per commit, which this hook must never
    do. So the github path does the coherence check from CHEAP LOCAL STATE ONLY (the linkage
    derivation above) and injects a reminder naming the door command — never querying or mutating the
    live board — and does so AT MOST ONCE per (session, item), so it never nags after every commit.

IDC_HOOKS_OBSERVE_ONLY=1: the auto-repair mutation (a real board write) is the ENFORCEMENT half of
this hook — observe-only suppresses it (mirrors bounded_block's downgrade-to-warn posture) and injects
the remediation instead, so the operator can see what WOULD have been repaired without any board
mutation actually happening.

FAIL MODE (P4): a post-hoc observer, so fail-OPEN, ALWAYS (idc_hook_lib.guard_post_observer) — any
internal error here (git subprocess failure, unreadable tracker, engine spawn failure) warns and exits
0, never touching the outcome of the commit that already landed.

Invocation: idc_post_commit_sync.py <PLUGIN_ROOT>   (PostToolUse payload on stdin).
Self-gated: no-op outside a governed repo, for a non-Bash tool, for a non-`git commit` command, for a
commit that did not land, or when the linked item is undeterminable.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402

CLAIMED_STATUS = "In Progress"

_WS = r"\s+"


def _has(command, *word_seqs):
    """True iff `command` contains a run of whitespace-separated words for EVERY seq in `word_seqs`
    (mirrors idc_interlock_gate._has — the same whitespace-flexible, word-boundary command matcher)."""
    for seq in word_seqs:
        pat = _WS.join(re.escape(w) for w in seq.split())
        if not re.search(r"(?<![\w-])" + pat + r"(?![\w-])", command):
            return False
    return True


def _is_git_commit(command):
    """A raw `git commit` (any flags) — same known limitation as the interlock gate's classifier: a
    pure string match with no shell parse, so an echoed/quoted occurrence also matches. Harmless here
    (the worst case is one extra, silently-no-op'd check when the linked item still resolves fine)."""
    return _has(command, "git commit")


# A landed `git commit` prints a `[<branch> <sha>]` header (`[main 1a2b3c4] msg`, `[main (root-commit)
# 1a2b3c4] …`, `[detached HEAD 1a2b3c4] …`) AND a diffstat/create-mode/root-commit line. Require BOTH
# (mirrors the official security commit-review hook): the header alone can be emitted by a pre-commit
# tool label (`[pre-commit 1a2b3c4]`), so the diffstat is the anti-false-positive belt. (An
# `--allow-empty` commit prints no diffstat and is intentionally not detected — an empty commit rarely
# represents claimable work, so skipping it is a harmless fail-open-by-omission.)
_COMMIT_HEADER_RE = re.compile(r"\[[^\]]*\b[0-9a-f]{7,40}\b[^\]]*\]")
_COMMIT_DIFFSTAT_RE = re.compile(
    r"\b\d+ files? changed\b|\binsertions?\b|\bdeletions?\b|\bcreate mode\b|\broot-commit\b")


def _bash_committed(tool_response):
    """A `git commit` that actually landed, inferred from the Bash tool_response TEXT (the real
    PostToolUse Bash response has NO exit_code — only stdout/stderr/interrupted). Never acts on an
    interrupted or rejected run (e.g. an empty-diff no-op, a pre-commit hook rejection)."""
    if not isinstance(tool_response, dict):
        return False
    if tool_response.get("interrupted"):
        return False
    text = (tool_response.get("stdout") or "") + "\n" + (tool_response.get("stderr") or "")
    return _COMMIT_HEADER_RE.search(text) is not None and _COMMIT_DIFFSTAT_RE.search(text) is not None


_ISSUE_TRAILER_RE = re.compile(r"(?im)^\s*(?:issue|item)\s*:\s*#?(\d+)\s*$")
_BRANCH_NUM_RE = re.compile(r"(?:^|/)(?:issue-)?(\d+)(?:[-_]|$)")


def _run_git(cwd, *args, timeout=10):
    """One git subprocess call, best-effort. Returns stripped stdout on success, None on ANY failure
    (spawn error, non-zero exit, timeout) — a git hiccup is undeterminable linkage, not a crash."""
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def resolve_linked_item(cwd):
    """The linked board item number per the LINKAGE CONVENTION above, or None if not determinable with
    a trusted signal. Reads the just-landed HEAD commit's message + the current branch name — both
    local, cheap git calls (no board read of any kind). A bare `#N` in the message is intentionally not
    trusted (see the module docstring)."""
    msg = _run_git(cwd, "log", "-1", "--format=%B") or ""
    m = _ISSUE_TRAILER_RE.search(msg)
    if m:
        return int(m.group(1))
    branch = _run_git(cwd, "rev-parse", "--abbrev-ref", "HEAD") or ""
    m = _BRANCH_NUM_RE.search(branch)
    if m:
        return int(m.group(1))
    return None


def _read_backend(cwd, plugin_root):
    """The governed repo's tracker backend, reusing the SAME helper the recirc-sweep + closeout gate
    already use (idc_recirc_sweep.read_backend) rather than re-deriving the tracker-config.yaml parse
    a third time. Defaults to filesystem when undeterminable."""
    scripts = os.path.join(plugin_root or "", "scripts")
    if os.path.isdir(scripts) and scripts not in sys.path:
        sys.path.insert(0, scripts)
    try:
        import idc_recirc_sweep as SW
        return SW.read_backend(cwd) or "filesystem"
    except Exception:  # noqa: BLE001 — undeterminable backend defaults to filesystem
        return "filesystem"


def _fs_status(trk, tracker, num):
    """The item's current Status via the sanctioned filesystem tracker helper, or None on ANY failure
    (not found / corrupt / helper missing) — undeterminable, not an error to surface."""
    try:
        r = subprocess.run([sys.executable, trk, "--tracker", tracker, "show",
                            "--num", str(num), "--field", "Status"],
                           capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    out = r.stdout.strip()
    return out or None


def _fs_move_in_progress(engine, cwd, tracker, num):
    """Auto-repair via the single write door: `idc_transition.py move --to-status "In Progress"`.
    Status-only — the filesystem tracker has no owner field, so this restores coherence without any
    ownership write (so a repair can never clobber an owner). Returns True iff the engine reports
    success; a refused move (e.g. the item is terminal/Done — the engine refuses to resurrect it)
    returns False so the caller falls back to inject."""
    try:
        r = subprocess.run([sys.executable, engine, "--repo", cwd, "--backend", "filesystem",
                            "--tracker", tracker, "move", "--num", str(num),
                            "--to-status", CLAIMED_STATUS],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"post-commit-sync: move engine call errored: {e}")
        return False
    return r.returncode == 0


def _fs_remediation(num, status, engine, repo):
    return (
        f"IDC board-coherence: a commit just landed but linked item #{num} is Status={status!r} "
        f"(expected {CLAIMED_STATUS!r}). Bring the board in sync through the single write door: "
        f"`python3 {engine} --repo {repo} move --num {num} --to-status \"{CLAIMED_STATUS}\"`."
    )


def _github_reminder(num, engine, repo):
    return (
        f"IDC board-coherence (github, local-only check — no live board read performed): a commit "
        f"just landed referencing item #{num}. Verify the board shows it Status={CLAIMED_STATUS!r}; "
        f"if not, sync it through the single write door: `python3 {engine} --repo {repo} "
        f"--backend github --owner <owner> --project <n> move --num {num} "
        f"--to-status \"{CLAIMED_STATUS}\"`."
    )


def _already_reminded_github(payload, num):
    """Once per (session, item): the github reminder can't verify status without a GraphQL call, so
    firing it on every commit would train the agent to ignore it. A one-shot latch keyed by
    session+item using the shared bounded counter (per-user temp state)."""
    sid = payload.get("session_id") or "nosession"
    key = f"post-commit-ghnag:{sid}:{num}"
    if H.counter_get(key) > 0:
        return True
    H.counter_set(key, 1)
    return False


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    if not H.is_governed_repo(cwd):
        return
    if payload.get("tool_name") != "Bash":
        return
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip() or not _is_git_commit(command):
        return
    if not _bash_committed(payload.get("tool_response")):
        return

    item = resolve_linked_item(cwd)
    if item is None:
        return  # undeterminable linkage — nothing provable, stay silent (fail-open by omission)

    engine = os.path.join(plugin_root or "", "scripts", "idc_transition.py")

    if _read_backend(cwd, plugin_root) == "github":
        # No live board GraphQL on this hook path — cheap local check only, remind once per (session,item).
        if _already_reminded_github(payload, item):
            return
        H.post_tool_inject(_github_reminder(item, engine, cwd))
        return

    trk = os.path.join(plugin_root or "", "scripts", "idc_tracker_fs.py")
    tracker = os.path.join(cwd, "TRACKER.md")
    status = _fs_status(trk, tracker, item)
    if status is None:
        return  # item not found / tracker unreadable — undeterminable, stay silent
    if status == CLAIMED_STATUS:
        return  # coherent — nothing to do

    if H.observe_only():
        # observe-only suppresses the real board mutation (the enforcement half); report only.
        H.post_tool_inject(_fs_remediation(item, status, engine, cwd))
        return

    if _fs_move_in_progress(engine, cwd, tracker, item):
        return  # auto-repaired silently — coherence restored, nothing further to say
    H.post_tool_inject(_fs_remediation(item, status, engine, cwd))  # refused (e.g. terminal) — name it


if __name__ == "__main__":
    H.guard_post_observer(_gate)
