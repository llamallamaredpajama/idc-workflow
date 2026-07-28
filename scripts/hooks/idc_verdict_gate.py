#!/usr/bin/env python3
"""idc_verdict_gate.py — the SubagentStop verdict gate (v4 Phase 1, plan §3.2/§3.3).

Fired on SubagentStop. When the stopping subagent is an IDC review agent in a governed repo, it
enforces the review engine's ONE output contract: a review agent may not stop without having
produced a VALIDATED verdict JSON for *this* review run under docs/workflow/code-reviews/. If it
did, the stop is allowed (and — task 3 — the filer routes the verdict's nits/deferrals to the
board). If it did not, the stop is blocked with the exact missing-artifact remediation, bounded
N=3 then a loud-fail that STILL blocks (never an infinite nag, never permission to stop without a
verdict).

Why "this run" and not "any verdict": the code-reviews/ dir accumulates verdicts from prior PRs
(the 394ec6fe board had verdicts through #224 lying around). A naive "a valid verdict exists"
check is satisfied by a months-old file and enforces nothing. So the gate anchors on the review
agent's OWN transcript: it locates the verdict path the agent wrote/validated this run and, as a
freshness backstop, requires the file's mtime to be at/after the agent's first transcript event.

Invocation: idc_verdict_gate.py <PLUGIN_ROOT>   (SubagentStop payload on stdin).
Self-gated: no-op (exit 0) outside a governed repo or for non-review agents.
"""
import datetime
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402

CODE_REVIEWS = os.path.join("docs", "workflow", "code-reviews")
# A code-reviews verdict path as it appears in a Write file_path or a Bash command string.
VERDICT_PATH_RE = re.compile(r"docs/workflow/code-reviews/[^\s\"'`)\\]+\.json")
# The coordinator's PRE-FLOOR round record, `docs/workflow/code-reviews/pr-<pr>-round-<n>.json`
# (agents/idc-review-coordinator.md step 3). Named distinctly so this gate can tell a round record
# apart from a verdict: it is never a verdict candidate, and it is what the round recorder fires on.
ROUND_PATH_RE = re.compile(r"(?:^|/)pr-\d+-round-[^/]*\.json$")


def _scan_transcript(transcript_path):
    """One pass over the agent transcript → (start_epoch, referenced_verdict_paths). start_epoch is
    the first event's timestamp (the agent's start, 0 if unknown); the paths are every
    code-reviews/*.json the agent touched (Write/Edit file_path or a Bash command), repo-relative,
    de-duplicated in first-seen order."""
    start, paths, first = 0.0, [], True
    for evt in H.iter_transcript_events(transcript_path):
        if first:
            first = False
            ts = evt.get("timestamp")
            if ts:
                try:
                    start = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    start = 0.0
        msg = evt.get("message")
        blocks = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(blocks, list):
            continue
        for b in blocks:
            if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                continue
            inp = b.get("input") or {}
            for val in (inp.get("file_path"), inp.get("command")):
                if isinstance(val, str):
                    for m in VERDICT_PATH_RE.findall(val):
                        if m not in paths:
                            paths.append(m)
    return start, paths


def _validate(plugin_root, path):
    """(ok, problems_text) from idc_review_verdict_check.py — the single source of verdict truth."""
    checker = os.path.join(plugin_root, "scripts", "idc_review_verdict_check.py")
    try:
        r = subprocess.run([sys.executable, checker, path], capture_output=True, text=True, timeout=30)
        return (r.returncode == 0, H.scrub((r.stdout + r.stderr).strip()))
    except (OSError, subprocess.SubprocessError) as e:
        return (False, f"validator could not run: {e}")


def _fresh_round_records(cwd, start, referenced):
    """The pre-floor round records this review run left on disk, freshness-anchored exactly like the
    verdict. Same evidence source (the agent's own transcript), same staleness rule — a round file
    from a previous run must not be re-recorded."""
    out = []
    for tail in referenced:
        if not ROUND_PATH_RE.search(tail):
            continue
        path = os.path.join(cwd, tail)
        if not os.path.isfile(path):
            continue
        try:
            if os.path.getmtime(path) < start:
                continue
        except OSError:
            continue
        out.append(path)
    return out


def _find_fresh_valid_verdict(cwd, plugin_root, start, referenced):
    """Return (path, ok, detail) for the verdict this review run produced. `ok` is True only for a
    file that exists, is at/after the agent's start (fresh), AND validates.

    Anchored STRICTLY on the review agent's own transcript: the engine's contract is "write AND
    validate the verdict" (idc-review-agent.md step 6 / coordinator step 5), so a compliant review
    always leaves the verdict path in its transcript. Requiring that reference — rather than
    scanning the dir — is what defeats BOTH a stale prior-PR verdict and a concurrent review's
    verdict from being counted as this run's artifact."""
    candidates = [os.path.join(cwd, tail) for tail in referenced
                  if not ROUND_PATH_RE.search(tail)]   # a round record is never a verdict
    last_detail = ""
    for path in candidates:
        if not os.path.isfile(path):
            continue
        try:
            fresh = os.path.getmtime(path) >= start
        except OSError:
            fresh = False
        if not fresh:
            last_detail = f"the verdict at {os.path.relpath(path, cwd)} predates this review run (stale)"
            continue
        ok, detail = _validate(plugin_root, path)
        if ok:
            return (path, True, "")
        last_detail = f"the verdict at {os.path.relpath(path, cwd)} failed validation: {detail}"
    return (None, False, last_detail)


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    if not H.is_governed_repo(cwd):
        H.allow()
    if H.normalize_agent_type(payload.get("agent_type")) not in H.REVIEW_AGENT_TYPES:
        H.allow()

    start, referenced = _scan_transcript(payload.get("agent_transcript_path", ""))
    path, ok, detail = _find_fresh_valid_verdict(cwd, plugin_root, start, referenced)
    key = f"verdict-gate.{payload.get('session_id', '?')}.{payload.get('agent_id', '?')}"
    if ok:
        H.counter_clear(key)
        # On a valid verdict, fire the filer to route its nits/deferrals to the board, THEN persist
        # the round's pre-floor candidates. That order is the coordinator's documented ordering
        # (record after the filer, so first-time findings are not marked already-seen) — enforced
        # here by fixed code instead of relying on the coordinator to run both commands itself.
        _run_filer(plugin_root, cwd, path)
        _run_round_recorder(plugin_root, cwd, _fresh_round_records(cwd, start, referenced))
        H.allow()

    detail = detail or "no verdict file was produced this review run"
    # `${CLAUDE_PLUGIN_ROOT}` resolves only in command/agent/skill MARKDOWN; from Python it is an unset
    # shell variable, so the blocked agent is told to run `python3 /scripts/idc_review_verdict_check.py`
    # and gets "No such file". The token stays in the literal so `lint-references.sh` rule B keeps
    # proving it names a real helper, and is resolved against the root this gate already holds.
    reason = (
        "IDC verdict gate: a review agent may not stop without a validated verdict JSON for this "
        f"review under docs/workflow/code-reviews/. Problem: {detail}. Write the structured JSON "
        "verdict, then validate it with "
        "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_review_verdict_check.py <verdict.json>` "
        "(exit 0) before you stop."
    ).replace("${CLAUDE_PLUGIN_ROOT}", plugin_root or "${CLAUDE_PLUGIN_ROOT}")
    H.bounded_block_fail_closed(key, reason)


def _run_filer(plugin_root, cwd, verdict_path):
    """On a valid verdict, fire the filer to route nits/deferrals to the board. Best-effort: a filer
    failure must never block the (already-valid) stop — it fails open. Runs synchronously so the
    nits are on the board by the time the review's stop finalizes (the downstream finisher/close
    guard can then rely on them), bounded by the subprocess timeout."""
    filer = os.path.join(plugin_root, "scripts", "idc_file_findings.py")
    if not os.path.isfile(filer):
        return
    try:
        subprocess.run([sys.executable, filer, "--repo", cwd, "--verdict", verdict_path],
                       capture_output=True, text=True, timeout=120, cwd=cwd)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"filer did not complete (verdict still valid, stop allowed): {e}")


def _run_round_recorder(plugin_root, cwd, round_paths):
    """Persist this round's PRE-FLOOR candidates (below-floor / rejected / refuted) into the per-PR
    seen-fingerprint ledger, from fixed code, for every round record the review left on disk.

    Why this exists: claim (b) of the convergence contract — a candidate rejected or floored in
    round 1 must be *seen*, or it resurfaces in round 3 as new work and recycles the review attempt
    counter. Until now the only thing that fired `record-round` was a prose instruction in
    agents/idc-review-coordinator.md step 3; a round that skipped the command left no ledger entry
    and nothing detected it. Firing it here — the same SubagentStop trigger that already fires the
    filer — makes persistence a property of the review COMPLETING, not of the model remembering.

    What fixed code still cannot do (deliberate, and the reason this is a trigger rather than a
    gate): which candidates were floored/rejected/refuted is model judgment that appears in no
    machine-checkable artifact — the verdict carries only post-floor findings. So the gate can
    guarantee that a round record the reviewer produced is actually persisted; it cannot synthesize
    one the reviewer never wrote, and it must not block a legitimate review that had no pre-floor
    candidates at all (`record-round` requires a non-empty candidate list).

    Best-effort, exactly like the filer: the verdict is already valid, so a recorder failure —
    including the pending-retry downgrade refusal — must surface loudly and never block the stop."""
    recorder = os.path.join(plugin_root, "scripts", "idc_review_seen_ledger.py")
    if not (round_paths and os.path.isfile(recorder)):
        return
    for round_path in round_paths:
        try:
            r = subprocess.run(
                [sys.executable, recorder, "record-round", "--repo", cwd, "--round", round_path],
                capture_output=True, text=True, timeout=120, cwd=cwd)
        except (OSError, subprocess.SubprocessError) as e:
            H.warn(f"round recorder did not complete (verdict still valid, stop allowed): {e}")
            continue
        if r.returncode != 0:
            H.warn("round recorder refused "
                   f"{os.path.relpath(round_path, cwd)}: {H.scrub((r.stdout + r.stderr).strip())}")


if __name__ == "__main__":
    H.guard_pre_action(_gate)
