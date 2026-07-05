#!/usr/bin/env python3
"""idc_recirc_closeout_gate.py — the SubagentStop recirculator closeout-or-checkpoint gate
(v4 Phase 3, drop F, plan §3.4).

Fired on `SubagentStop`. When the stopping subagent is the IDC **recirculator** in a governed repo,
it closes forensic drop F — a recirculator subagent that **dies mid-drain and loses its state**. The
recirculator's job is to drain the Recirculation inbox: enumerate every open
`Stage=Recirculation ∧ Status=Todo` ticket and dispose each (admit → retire to Done, or park behind a
gate → Blocked), emitting a machine-readable `idc_recirc_closeout.py` closeout per ticket. If it is
truncated / crashes / OOMs partway, the tickets it never reached are still `Todo` on the board and the
branch/PR/dispositions it had accumulated in-context are LOST — a later drain re-does the work blind.

WHAT THIS GATE GUARANTEES. On the recirculator's stop, for **every still-open inbox ticket the
recirculator did NOT validly close out**, it stamps a **resume-checkpoint comment** recording
{branch, PR#, dispositions-so-far} — reconstructed DETERMINISTICALLY from the agent's own transcript
(never asking an LLM) — and sets a `recirc_checkpoint:<ticket>` obligation-ledger taint. A later
`/idc:recirculate` resumes from that checkpoint instead of starting cold. When the run DID produce a
valid closeout for every still-open ticket (the drain reached its handoff fixpoint), the gate allows
and clears this session's `recirc_checkpoint` taints — the obligation is satisfied.

THE DISCRIMINATOR IS PER-TICKET, NOT RUN-LEVEL (the key correctness decision). "Did the recirculator
produce a valid closeout?" is NOT a single yes/no for the run: it drains N tickets and emits N
closeouts, and the drop-F failure is precisely a run that closed out ticket #1 then died before #2/#3.
A naive run-level "any valid closeout ⇒ allow" would strand exactly the un-processed tickets this gate
exists to protect. So the gate checkpoints a still-open ticket T **iff** the transcript holds NO valid
closeout whose `ticket == T`. A valid closeout for T is authoritative for T (its board move may just
not have landed yet — a re-drain is idempotent), so T is left alone; a ticket with no valid closeout is
un-dispositioned and gets checkpointed. "A valid closeout ⇒ allow + clear taints" therefore means
"every still-open ticket is covered by a valid closeout" (the uncovered set is empty).

THE BOARD IS GROUND TRUTH (invariant #1). "Still-open" is read from the board (the sanctioned tracker
helper: `query --stage Recirculation --status Todo`), never inferred from the ledger. The
transcript-derived valid-closeout set and the reconstructed branch/PR/dispositions are HINTS used only
to (a) decide which open tickets are already covered and (b) enrich the checkpoint comment; the ledger
taint is a resume breadcrumb, not a gate. `idc_recirc_closeout.py` (the fail-closed closeout validator)
is the single source of "is this closeout valid" — the gate feeds each transcript closeout candidate to
it on stdin (`--closeout -`) and trusts only what it accepts.

FAIL MODE (P4) — a POST-HOC DETECTIVE, so FAIL-OPEN, ALWAYS. A dead subagent cannot be un-died; the
checkpoint is a repair, not a pre-action denial. A hook-internal error must NEVER break the stop — it
warns and allows (this script's own top-level guard fails open even under IDC_HOOKS_STRICT, unlike the
pre-action gates that fail closed). The gate never emits a block decision at all (there is nothing to
block on a stop that already happened), so there is no anti-nag bound to hit: the checkpoint+allow path
cannot nag. IDC_HOOKS_OBSERVE_ONLY still RECORDS the checkpoint (comment + taint) — observe-only exists
to SEE what would be lost, so suppressing the record would blind the very observation it collects.
Repo-gated (instant no-op outside an IDC-governed repo) and self-gated to the recirculator agent_type.

Invocation: idc_recirc_closeout_gate.py <PLUGIN_ROOT>   (SubagentStop payload on stdin).
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402
import idc_ledger  # noqa: E402  (import, never edit — Stage A ledger API)

# The recirculator's agent_type. Plugin agents are dispatched namespaced (`idc:idc-recirculator`, the
# Phase-0 spike / agents/idc-recirculator.md frontmatter `name`); idc_hook_lib.normalize_agent_type
# strips the `idc:` prefix, so we match the BARE flat name here — a wrong key silently disables the
# hook, so this is anchored on the frontmatter `name`, exactly as the verdict gate anchors on
# REVIEW_AGENT_TYPES = {"idc-review-agent", "idc-review-coordinator"}.
RECIRCULATOR_AGENT_TYPE = "idc-recirculator"
CHECKPOINT_TAINT = "recirc_checkpoint"
CLOSEOUT_VALIDATOR = "idc_recirc_closeout.py"   # scripts/ (fail-closed closeout validator; --closeout -)
TRACKER_FS = "idc_tracker_fs.py"                # scripts/ (sanctioned filesystem comment/query helper)
CHECKPOINT_MARKER = "[idc-recirc-checkpoint]"   # grep anchor on the stamped comment

# ── deterministic transcript reconstruction (never an LLM) ───────────────────────────────────────
# A branch the recirculator created/pushed for its drift-heal or gated Think PR.
_BRANCH_RES = (
    re.compile(r"\bgit\s+(?:checkout\s+-b|switch\s+-c)\s+([^\s;&|'\"]+)"),
    re.compile(r"\bgit\s+push\s+(?:-u\s+)?origin\s+([^\s;&|'\"]+)"),
    re.compile(r"--head[=\s]+([^\s;&|'\"]+)"),
)
# A PR number: a `.../pull/<n>` URL (gh pr create output / a closeout think_pr) — the robust anchor
# (a bare `#<n>` is ambiguous with ticket numbers, so it is NOT used).
_PR_RE = re.compile(r"/pull/(\d+)\b")


def _walk_strings(obj):
    """Yield every string leaf in a decoded transcript event (bounded one-object recursion). This
    captures branch/PR text and embedded closeout JSON wherever they live — a text block's `text`, a
    tool_use `input` (command / file_path / content), or a tool_result `content` — without the gate
    having to know each block's exact shape."""
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _walk_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk_strings(v)


def _iter_json_objects(s):
    """Yield every JSON object embedded in `s` (raw_decode scan from each `{`, so nested braces — the
    `trivial` closeout's `grant:{…}` — are handled correctly, unlike a `[^{}]*` regex)."""
    dec = json.JSONDecoder()
    i, n = 0, len(s)
    while i < n:
        if s[i] == "{":
            try:
                obj, end = dec.raw_decode(s, i)
            except ValueError:
                i += 1
                continue
            if isinstance(obj, dict):
                yield obj
                i = end
                continue
        i += 1


def _scan_transcript(transcript_path):
    """One pass over the recirculator transcript → (branch, prs, closeout_candidates).

    branch: the first git branch it created/pushed (or None). prs: the sorted PR numbers referenced
    (pull/<n> URLs). closeout_candidates: every JSON object shaped like a closeout (has BOTH `ticket`
    and `outcome`) — later fed to the fail-closed validator to decide which tickets are covered."""
    branch, prs, candidates = None, set(), []
    seen_candidate = set()
    for evt in H.iter_transcript_events(transcript_path):
        for s in _walk_strings(evt):
            if branch is None:
                for rgx in _BRANCH_RES:
                    m = rgx.search(s)
                    if m:
                        branch = m.group(1)
                        break
            for m in _PR_RE.finditer(s):
                prs.add(int(m.group(1)))
            if "ticket" in s and "outcome" in s:  # cheap prefilter before the raw_decode scan
                for obj in _iter_json_objects(s):
                    if "ticket" in obj and "outcome" in obj:
                        key = json.dumps(obj, sort_keys=True)
                        if key not in seen_candidate:
                            seen_candidate.add(key)
                            candidates.append(obj)
    return branch, sorted(prs), candidates


def _covered_tickets(plugin_root, candidates):
    """The set of ticket numbers for which the transcript holds a VALID closeout. Each candidate is
    fed to the fail-closed validator (`idc_recirc_closeout.py --closeout -`); only a candidate it
    ACCEPTS (exit 0) counts, and the covered ticket is read from the validator's own dispatch line —
    so an invalid/truncated closeout can never mark a ticket covered (that would strand it)."""
    checker = os.path.join(plugin_root or "", "scripts", CLOSEOUT_VALIDATOR)
    if not os.path.isfile(checker):
        return set()
    covered = set()
    for obj in candidates:
        try:
            r = subprocess.run([sys.executable, checker, "--closeout", "-"],
                               input=json.dumps(obj), capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode != 0:
            continue
        try:
            covered.add(int(json.loads(r.stdout).get("ticket")))
        except (ValueError, TypeError):
            pass
    return covered


# ── backend config (grep parse, no PyYAML on the hook path) ──────────────────────────────────────
def _read_backend(cwd):
    """The `backend:` value from <cwd>/docs/workflow/tracker-config.yaml (regex parse — the repo's
    no-yq convention), or None. Defaults to filesystem at the call site when absent."""
    cfg = os.path.join(cwd, "docs", "workflow", "tracker-config.yaml")
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"""^\s*backend:\s*["']?([A-Za-z0-9_-]+)""", line)
                if m:
                    return m.group(1).strip()
    except OSError:
        return None
    return None


# ── filesystem backend (the hermetically-tested, load-bearing path) ──────────────────────────────
def _fs_query(trk, tracker, stage, status):
    """Issue numbers at (stage, status) via the sanctioned tracker helper. [] on any failure."""
    try:
        r = subprocess.run([sys.executable, trk, "--tracker", tracker, "query",
                            "--stage", stage, "--status", status],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def _fs_comment(trk, tracker, cwd, num, body):
    """Stamp `body` on ticket <num> through the sanctioned filesystem comment op (NEVER a raw board
    mutation — the Phase-2 interlock flags those). Best-effort: a failure warns, never raises."""
    try:
        subprocess.run([sys.executable, trk, "--tracker", tracker, "comment",
                        "--num", str(num), "--body", body],
                       cwd=cwd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"recirc-checkpoint: could not stamp checkpoint on #{num}: {e}")


def _fs_still_open_and_handled(plugin_root, cwd):
    """(still_open, handled) for the filesystem backend. still_open = Stage=Recirculation ∧
    Status=Todo (the tickets whose state is at risk). handled = the Stage=Recirculation tickets
    already moved off Todo this drain (Done = admitted/retired, Blocked = parked behind a gate) —
    enriches the checkpoint's "dispositions so far". Returns (None, []) if the tracker is absent."""
    trk = os.path.join(plugin_root or "", "scripts", TRACKER_FS)
    tracker = os.path.join(cwd, "TRACKER.md")
    if not (os.path.isfile(trk) and os.path.isfile(tracker)):
        return None, []
    still_open = _fs_query(trk, tracker, "Recirculation", "Todo")
    handled = [(n, "done") for n in _fs_query(trk, tracker, "Recirculation", "Done")]
    handled += [(n, "blocked") for n in _fs_query(trk, tracker, "Recirculation", "Blocked")]
    return still_open, handled


# ── github backend (sanctioned helpers; best-effort, not hermetically tested) ────────────────────
def _gh_still_open_and_handled_and_commenter(cwd):
    """(still_open, handled, commenter) for the github backend via the SANCTIONED helpers
    (idc_gh_board.fetch_items to enumerate, idc_gh_board.add_comment — `gh issue comment`, NOT a raw
    board mutation — to stamp). Reads owner via `gh repo view` and project_number from the config.
    Fail-OPEN: any failure returns (None, [], None) so the caller warns and never crashes the stop."""
    scripts = os.path.join(_plugin_root_from_argv(), "scripts")
    if os.path.isdir(scripts):
        sys.path.insert(0, scripts)
    try:
        import idc_gh_board  # noqa: E402 — lazy: only the github path pays this import
    except ImportError:
        return None, [], None
    project_number = _read_project_number(cwd)
    owner = _gh_owner(cwd)
    if not (owner and project_number):
        return None, [], None
    try:
        items = idc_gh_board.fetch_items(owner, project_number, cwd)
    except Exception as e:  # noqa: BLE001 — a board read failure must not break the stop (fail-open)
        H.warn(f"recirc-checkpoint: github board read failed, cannot enumerate open tickets: {e}")
        return None, [], None
    still_open, handled = [], []
    for it in items:
        if (it.get("stage") or "Buildable") != "Recirculation":
            continue
        num = (it.get("content") or {}).get("number")
        if num is None:  # a draft item has no issue to comment on
            continue
        status = it.get("status")
        if status == "Todo":
            still_open.append(int(num))
        elif status == "Done":
            handled.append((int(num), "done"))
        elif status == "Blocked":
            handled.append((int(num), "blocked"))

    def commenter(n, body):
        try:
            idc_gh_board.add_comment(n, body, cwd)
        except Exception as e:  # noqa: BLE001 — best-effort stamp
            H.warn(f"recirc-checkpoint: could not stamp checkpoint on #{n} (github): {e}")

    return still_open, handled, commenter


def _read_project_number(cwd):
    cfg = os.path.join(cwd, "docs", "workflow", "tracker-config.yaml")
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r'^\s*project_number:\s*"?([^"#\n]*)"?', line)
                if m and m.group(1).strip():
                    return m.group(1).strip()
    except OSError:
        return None
    return None


def _gh_owner(cwd):
    try:
        r = subprocess.run(["gh", "repo", "view", "--json", "owner", "-q", ".owner.login"],
                           cwd=cwd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def _plugin_root_from_argv():
    return sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")


# ── the checkpoint comment ───────────────────────────────────────────────────────────────────────
def _checkpoint_body(ticket, branch, prs, handled):
    br = branch or "unknown"
    pr = ", ".join(f"#{n}" for n in prs) if prs else "none"
    if handled:
        disp = "handled " + str(len(handled)) + " (" + ", ".join(f"#{n}->{d}" for n, d in handled) + ")"
    else:
        disp = "none recorded"
    return (
        f"{CHECKPOINT_MARKER} RESUME — the recirculator subagent stopped mid-drain WITHOUT a valid "
        f"closeout for this ticket; its state was reconstructed deterministically from the agent "
        f"transcript. branch={br} pr={pr} dispositions-so-far={disp}. This ticket #{ticket} is "
        f"UNFINISHED (Stage=Recirculation ∧ Status=Todo) — re-run /idc:recirculate to resume the "
        f"drain (idempotent; already-dispositioned tickets are skipped)."
    )


def _clear_session_checkpoints(cwd, sid):
    """Clear this session's `recirc_checkpoint` taints — the obligation is satisfied (every still-open
    ticket is covered by a valid closeout). Scoped to what pending_taints(sid) surfaces (this session's
    + unattributed), so a DIFFERENT live session's checkpoint obligation is never cleared out from
    under it."""
    for t in idc_ledger.pending_taints(cwd, session_id=sid):
        if t.get("kind") == CHECKPOINT_TAINT:
            idc_ledger.clear_taint(cwd, CHECKPOINT_TAINT, key=t.get("key"))


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    sid = payload.get("session_id")

    # Repo-gate + self-gate: an instant no-op outside a governed repo or for any non-recirculator
    # subagent (the hook is matcher-less, so it fires for EVERY subagent stop and self-gates here).
    if not H.is_governed_repo(cwd):
        H.allow()
    if H.normalize_agent_type(payload.get("agent_type")) != RECIRCULATOR_AGENT_TYPE:
        H.allow()

    # Which still-open inbox tickets (board = ground truth) + what was already handled (for the comment).
    backend = _read_backend(cwd) or "filesystem"
    commenter = None
    if backend == "github":
        still_open, handled, commenter = _gh_still_open_and_handled_and_commenter(cwd)
    else:
        still_open, handled = _fs_still_open_and_handled(plugin_root, cwd)
        trk = os.path.join(plugin_root or "", "scripts", TRACKER_FS)
        tracker = os.path.join(cwd, "TRACKER.md")
        commenter = lambda n, body: _fs_comment(trk, tracker, cwd, n, body)  # noqa: E731

    if not still_open:
        # No open inbox tickets (a clean/complete drain, or the board is unreadable) → nothing to
        # checkpoint. Treat a proven-empty inbox as the obligation satisfied and clear the taints.
        if still_open is not None:
            _clear_session_checkpoints(cwd, sid)
        H.allow()

    # Which of the still-open tickets already have a VALID closeout in the transcript (covered) — those
    # are authoritatively closed out and must NOT be checkpointed; the rest are un-dispositioned.
    branch, prs, candidates = _scan_transcript(payload.get("agent_transcript_path", ""))
    covered = _covered_tickets(plugin_root, candidates)
    uncovered = [t for t in still_open if t not in covered]

    if not uncovered:
        # Every still-open ticket is covered by a valid closeout ⇒ the drain's handoff is complete ⇒
        # allow + clear this session's checkpoint taints. NEUTERING the `t not in covered` filter (or
        # forcing covered empty) makes uncovered == still_open, so a clean valid-closeout run WRONGLY
        # checkpoints every open ticket — the closeout-valid short-circuit's red-when-broken proof.
        _clear_session_checkpoints(cwd, sid)
        H.allow()

    # CHECKPOINT: for each un-dispositioned still-open ticket, stamp the resume comment (sanctioned
    # helper) + set the `recirc_checkpoint:<ticket>` taint. Recorded even under observe-only (the
    # record IS what observe-only exists to see). NEUTERING the stamp makes the "every open ticket has
    # a checkpoint" assert go red.
    if H.observe_only():
        H.warn(f"OBSERVE-ONLY: recirculator stopped mid-drain; would checkpoint {uncovered} "
               f"(branch={branch or 'unknown'}, prs={prs or 'none'}) — recording taints only")
    for t in uncovered:
        if not H.observe_only():
            commenter(t, _checkpoint_body(t, branch, prs, handled))
        # The taint is written by this hook (never the LLM), keyed by ticket, scoped to this session;
        # it clears on a later valid closeout (Stage-A ledger semantics).
        idc_ledger.set_taint(cwd, CHECKPOINT_TAINT, key=t, session_id=sid,
                             branch=(branch or ""), prs=",".join(str(p) for p in prs))

    # POST-HOC DETECTIVE: allow the stop unconditionally (a dead subagent can't be un-died; the
    # checkpoint is the repair). We never block, so there is nothing to nag and no bound to hit.
    H.allow()


if __name__ == "__main__":
    # FAIL-OPEN top-level guard (this is a post-hoc detective — a hook-internal error must NEVER break
    # the stop, even under IDC_HOOKS_STRICT, unlike the pre-action gates). _gate exits via H.allow()
    # (SystemExit) on every path; any OTHER exception warns and allows.
    _payload = H.read_payload()
    _root = _plugin_root_from_argv()
    try:
        _gate(_payload, _root)
    except SystemExit:
        raise
    except Exception as _e:  # noqa: BLE001 — infra bug, never a reason to break a stop
        H.warn(f"recirc-closeout gate errored, failing open (allow): {_e}")
        sys.exit(0)
    sys.exit(0)
