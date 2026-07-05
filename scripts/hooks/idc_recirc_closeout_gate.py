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

SCOPE — WIDE BY DEFAULT, NARROWED ONLY BY AN EXPLICIT DISPATCH (the second correctness decision, and
an ASYMMETRIC one). This SubagentStop hook fires for the recirculator dispatched as a Task subagent in
TWO shapes: the Build larger-loop "recirc-consultant per event" (`agents/idc-build.md`, a sous-chef
spawned over ONE explicitly-named ticket) AND a board-scan inbox-drainer (a generic "drain the
recirculation inbox" dispatch that enumerates no ticket #s). The safe bias is ASYMMETRIC (invariant #1
/ drop-F): UNDER-checkpointing a ticket the subagent owned IS the state loss this hook exists to
prevent, whereas OVER-checkpointing is only a recoverable spurious breadcrumb (the board is ground
truth; a re-drain is idempotent). So the default is WIDE, and NARROW needs an explicit dispatch to
pass a THREE-PART trigger — dispatch text is LLM-composed English, so a bare "any `#N` anywhere"
parse is NOT a safe narrow signal (a stray PR#/project# reference, or an injected mid-run reminder
containing `#1.`, must never flip a whole-inbox drainer into a scope that checkpoints nothing):
  * FIRST-TURN ONLY — dispatch scope is parsed from the FIRST user event of the transcript (the
    dispatch prompt the parent handed the subagent). Later user-role text (injected system-reminders,
    task lists, teammate messages) is NOT the dispatch and never narrows scope;
  * GENERIC LANGUAGE DOMINATES — a dispatch whose text carries inbox-wide drainer language (the
    shipped phrasing: "recirculation inbox", "inbox-drain", "board-scan", "drain the inbox",
    "every open …") is GENERIC even if it also name-drops a `#N` ("drain the inbox; #5 is oldest"
    owns the whole inbox, not just #5);
  * CORROBORATION — a numbered, non-generic dispatch is EXPLICIT only if at least one parsed number
    is recirc-REAL (an open inbox ticket ∪ a closeout-candidate ticket ∪ a just-handled Done/Blocked
    recirc ticket). A dispatch whose only numbers are noise (a PR#, a board/project#, an unrelated
    issue) is UNDETERMINABLE, not explicit.
An EXPLICIT dispatch NARROWS scope to exactly its ticket(s) ∪ the tickets its closeout candidates
reference — a single-ticket sous-chef never stamps #1's branch/PR breadcrumb onto a stranger's open
#2/#3 it never touched (P2-1). A GENERIC or undeterminable dispatch DEFAULTS to the WHOLE still-open
`Stage=Recirculation ∧ Status=Todo` inbox — a board-scan drainer owns every open ticket, so a death
before it reaches #2/#3 CHECKPOINTS them, never silently drops them (defaulting to nothing is the
exact drop-F loss this hook prevents). Either way `covered` (a ticket with a valid closeout) is
subtracted, so a ticket the subagent actually finished is never checkpointed.

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
# The ticket(s) named in the DISPATCH PROMPT — parsed from the FIRST user event ONLY (the dispatch
# the parent handed the subagent; a later user-role text block is an injected reminder/tool_result,
# never the dispatch). Here a bare `#<n>` IS used (unlike the PR anchor above), but a match alone
# never narrows scope: the numbers must also pass the three-part explicit-dispatch trigger in _gate
# (no generic drainer language + at least one number is recirc-REAL), because a stray PR#/project#
# in LLM-composed dispatch English must not flip a whole-inbox drainer into a nothing-scope.
_DISPATCH_TICKET_RES = (
    re.compile(r"#(\d+)\b"),
    re.compile(r"\b(?:ticket|issue)\s+#?(\d+)\b", re.I),
)
# Inbox-wide drainer language (grounded in the shipped dispatch phrasing: commands/autorun.md +
# commands/recirculate.md "drain the Recirculation inbox" / "Board-scan inbox-drain" / "Enumerate
# every open Stage=Recirculation inbox ticket"). When the dispatch says it owns the INBOX, it owns
# every open ticket — a name-dropped `#N` alongside it must not narrow scope (wide = the safe bias).
_GENERIC_DISPATCH_RE = re.compile(
    r"recirculation\s+inbox|inbox[-\s]+drain|board[-\s]+scan|drain\s+the\s+inbox|\bevery\s+open\b",
    re.I,
)
# A `--closeout <path>` argument to idc_recirc_closeout.py — the DOCUMENTED closeout flow (the agent
# writes the closeout to a FILE, then validates it with `--closeout <path>`), as opposed to an inline
# `--closeout -` here-string. Captures the path so the harvester can read that file (best-effort).
_CLOSEOUT_PATH_RE = re.compile(r"--closeout(?:=|\s+)([^\s;&|'\"]+)")


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


def _iter_tool_uses(evt):
    """Yield (tool_name, input_dict) for each assistant `tool_use` block in a transcript event — the
    ACTIONS the agent itself took, as opposed to a tool_result it READ or prose it wrote. Closeout
    harvesting anchors here (never on arbitrary strings) so an EXAMPLE closeout the recirculator merely
    read, quoted, or embedded in a doc is never mistaken for a real disposition (MAJOR-2)."""
    msg = evt.get("message")
    blocks = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(blocks, list):
        return
    for b in blocks:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            inp = b.get("input")
            yield (b.get("name") or ""), (inp if isinstance(inp, dict) else {})


def _is_closeout_shape(obj):
    """A closeout object at minimum carries BOTH `ticket` and `outcome` (the validator enforces the
    rest). This is only a SHAPE prefilter — `_covered_tickets` still runs the fail-closed validator."""
    return isinstance(obj, dict) and "ticket" in obj and "outcome" in obj


def _positive_int(v):
    """v as a positive int, or None (bool excluded — bool is an int subclass)."""
    if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
        return None
    return v


def _dispatch_tickets_from_text(text):
    """Ticket number(s) named in a dispatch-prompt text block (bare `#<n>` + `ticket/issue <n>`). Used
    only against the first user turn; the SCOPE it feeds is intersected with the still-open inbox, so
    over-broad here is harmless."""
    out = set()
    if not isinstance(text, str):
        return out
    for rgx in _DISPATCH_TICKET_RES:
        for m in rgx.finditer(text):
            out.add(int(m.group(1)))
    return out


def _read_closeout_file(cwd, path):
    """A closeout object read from a `--closeout <path>` FILE the agent validated, or None. The path is
    resolved relative to the subagent's cwd (best-effort — an absolute path is used as-is). BEST-EFFORT
    on every failure (`-`/stdin, a path gone at hook time, unreadable, non-JSON, non-object → None): a
    missing closeout file is a DOCUMENTED limitation of post-hoc reconstruction, never a crash. Anchored
    on a REAL `idc_recirc_closeout.py --closeout <path>` invocation (see `_scan_transcript`), so this
    reads only a file the agent actually ran the validator on — NOT an example it merely quoted (MAJOR-2)."""
    if not path or path == "-":
        return None
    fp = path if os.path.isabs(path) else os.path.join(cwd or ".", path)
    try:
        with open(fp, encoding="utf-8") as fh:
            obj = json.loads(fh.read().strip())
    except (OSError, ValueError):
        return None
    return obj if isinstance(obj, dict) else None


def _candidate_tickets(candidates):
    """The ticket number(s) any closeout candidate references (valid OR invalid — a disposition the
    subagent ATTEMPTED). The other half of this subagent's SCOPE, alongside its dispatch tickets."""
    out = set()
    for co in candidates:
        t = _positive_int(co.get("ticket"))
        if t is not None:
            out.add(t)
    return out


def _scan_transcript(transcript_path, cwd):
    """One pass over the recirculator transcript →
    (branch, prs, closeout_candidates, dispatch_tickets, generic_dispatch).

    branch / prs are reconstruction HINTS for the checkpoint comment, harvested BROADLY (any string in
    the event — a `gh pr create` URL living in a tool_result is fair game, and over-broad here is
    harmless).

    dispatch_tickets / generic_dispatch come from the FIRST user event ONLY — the dispatch prompt the
    parent handed the subagent. A subagent's later user-role events are tool_results OR injected text
    (system-reminders, task lists — which DO carry `#N`-shaped noise), never the dispatch, so parsing
    them would let a mid-run reminder silently NARROW a whole-inbox drainer's scope (the drop-F
    under-checkpoint; the case-L red-when-broken). dispatch_tickets is one HALF of the explicit
    scope (the tickets it was dispatched over); the other half is the tickets its closeout candidates
    reference. generic_dispatch is True when the dispatch text carries inbox-wide drainer language
    (_GENERIC_DISPATCH_RE) — it dominates any name-dropped `#N` (the case-K1 red-when-broken).

    closeout_candidates are harvested NARROWLY — ONLY from a REAL closeout ACTION the agent authored,
    NOT mere JSON presence anywhere (MAJOR-2):
      * a `Write`/`Edit` whose WHOLE (stripped) content parses as a closeout object — the closeout
        ARTIFACT the recirculator emitted (a doc that merely *contains* an example won't parse whole); or
      * a `Bash` command that RUNS `idc_recirc_closeout.py` with an inline (`--closeout -`) closeout — the
        recirculator actually validating one; or
      * a `Bash` command that RUNS `idc_recirc_closeout.py --closeout <path>` — the DOCUMENTED file-based
        flow (write the closeout to a file, then validate it): the referenced FILE is read (best-effort).
    A closeout-shaped JSON in a tool_result (a doc it Read), in a text/prose block, or buried in a
    larger file is IGNORED, so a quoted EXAMPLE can never suppress a needed checkpoint. The bias is
    SAFE: an un-anchored real closeout at worst yields a harmless extra (idempotent) checkpoint, never a
    lost one."""
    branch, prs, candidates, seen = None, set(), [], set()
    dispatch_tickets, generic_dispatch, dispatch_seen = set(), False, False

    def _add(obj):
        if _is_closeout_shape(obj):
            key = json.dumps(obj, sort_keys=True)
            if key not in seen:
                seen.add(key)
                candidates.append(obj)

    for evt in H.iter_transcript_events(transcript_path):
        # HINTS (broad): branch + PR from any string in the event.
        for s in _walk_strings(evt):
            if branch is None:
                for rgx in _BRANCH_RES:
                    m = rgx.search(s)
                    if m:
                        branch = m.group(1)
                        break
            for m in _PR_RE.finditer(s):
                prs.add(int(m.group(1)))
        # DISPATCH SCOPE (narrow): the FIRST user event is the dispatch prompt — and ONLY it. A later
        # user-role event is a tool_result or injected text (a system-reminder's `#1.` task list),
        # which must never narrow a drainer's scope (case L). If the first user event carries no text,
        # the dispatch is undeterminable → dispatch_tickets stays empty → the caller defaults WIDE.
        if not dispatch_seen and ((evt.get("type") == "user")
                                  or (isinstance(evt.get("message"), dict)
                                      and evt["message"].get("role") == "user")):
            dispatch_seen = True
            msg = evt.get("message")
            blocks = msg.get("content") if isinstance(msg, dict) else None
            texts = []
            if isinstance(blocks, str):
                texts.append(blocks)
            elif isinstance(blocks, list):
                texts.extend(b.get("text") for b in blocks
                             if isinstance(b, dict) and b.get("type") == "text"
                             and isinstance(b.get("text"), str))
            for text in texts:
                dispatch_tickets |= _dispatch_tickets_from_text(text)
                if _GENERIC_DISPATCH_RE.search(text):
                    generic_dispatch = True
        # COVERED closeouts (narrow): only from a real closeout action the agent authored.
        for name, inp in _iter_tool_uses(evt):
            if name in ("Write", "Edit"):
                content = inp.get("content") if name == "Write" else inp.get("new_string")
                if isinstance(content, str):
                    try:
                        _add(json.loads(content.strip()))   # the WHOLE file content must BE the closeout
                    except ValueError:
                        pass
            elif name == "Bash":
                cmd = inp.get("command")
                if isinstance(cmd, str) and CLOSEOUT_VALIDATOR in cmd:
                    for obj in _iter_json_objects(cmd):   # inline (`--closeout -`) closeout JSON
                        _add(obj)
                    for m in _CLOSEOUT_PATH_RE.finditer(cmd):   # file-based (`--closeout <path>`) closeout
                        obj = _read_closeout_file(cwd, m.group(1))
                        if obj is not None:
                            _add(obj)
    return branch, sorted(prs), candidates, dispatch_tickets, generic_dispatch


def _covered_tickets(plugin_root, candidates):
    """The set of ticket numbers for which the transcript holds a VALID closeout. Each candidate is
    fed to the fail-closed validator (`idc_recirc_closeout.py --closeout -`); only a candidate it
    ACCEPTS (exit 0) counts, and the covered ticket is read from the validator's own dispatch line —
    so an invalid/truncated closeout can never mark a ticket covered (that would strand it)."""
    checker = os.path.join(plugin_root or "", "scripts", CLOSEOUT_VALIDATOR)
    if not os.path.isfile(checker):
        # No validator ⇒ we cannot prove ANY ticket is covered ⇒ every open ticket is treated as
        # uncovered (checkpointed) — the SAFE bias. Warn so the missing helper is visible (MINOR-3).
        if candidates:
            H.warn(f"recirc-checkpoint: closeout validator not found at {checker} — treating all open "
                   f"tickets as uncovered (safe bias; will checkpoint)")
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
        # The validator's dispatch line is a JSON OBJECT carrying `ticket`; guard the degenerate cases
        # (non-JSON / non-object stdout → AttributeError on .get) so one bad line never sinks the loop (NIT-5).
        try:
            covered.add(int(json.loads(r.stdout).get("ticket")))
        except (ValueError, TypeError, AttributeError):
            continue
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
    """Issue numbers at (stage, status) via the sanctioned tracker helper, or **None on ANY failure**
    (spawn error / timeout / non-zero exit — a corrupt/locked/half-written TRACKER.md makes the helper
    `die` rc=1). None is NOT the same as `[]` (MAJOR-1): a FAILED read is UNKNOWN inbox state, which
    the caller must be able to tell apart from a genuinely empty inbox — else a read failure would look
    like 'nothing owed' and the gate would clear the checkpoint ledger, silently WIPING state (the very
    drop-F loss this hook exists to prevent). Warns on the degraded path (observability-first)."""
    try:
        r = subprocess.run([sys.executable, trk, "--tracker", tracker, "query",
                            "--stage", stage, "--status", status],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"recirc-checkpoint: tracker query ({stage}/{status}) could not run: {e}")
        return None
    if r.returncode != 0:
        H.warn(f"recirc-checkpoint: tracker query ({stage}/{status}) failed (rc={r.returncode}): "
               f"{(r.stderr or '').strip()[:200]}")
        return None
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def _fs_comment(trk, tracker, cwd, num, body):
    """Stamp `body` on ticket <num> through the sanctioned filesystem comment op (NEVER a raw board
    mutation — the Phase-2 interlock flags those). Best-effort (never raises), but a DROPPED comment is
    a lost checkpoint, so a non-zero exit or spawn error WARNS loudly (MINOR-4) rather than silently
    vanishing — the taint still records the obligation so the loss stays visible."""
    try:
        r = subprocess.run([sys.executable, trk, "--tracker", tracker, "comment",
                            "--num", str(num), "--body", body],
                           cwd=cwd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"recirc-checkpoint: could not stamp checkpoint on #{num}: {e}")
        return
    if r.returncode != 0:
        H.warn(f"recirc-checkpoint: checkpoint comment on #{num} failed (rc={r.returncode}): "
               f"{(r.stderr or '').strip()[:200]}")


def _fs_still_open_and_handled(plugin_root, cwd):
    """(still_open, handled) for the filesystem backend. still_open = Stage=Recirculation ∧
    Status=Todo (the tickets whose state is at risk). handled = the Stage=Recirculation tickets
    already moved off Todo this drain (Done = admitted/retired, Blocked = parked behind a gate) —
    enriches the checkpoint's "dispositions so far".

    still_open is **None** when the inbox cannot be determined (the tracker helper/file is missing, or
    the Todo query FAILED — see _fs_query) so the caller PRESERVES the checkpoint ledger instead of
    wiping it (MAJOR-1). The Done/Blocked enrichment queries are best-effort — a None there degrades to
    an empty disposition list, never to a lost checkpoint."""
    trk = os.path.join(plugin_root or "", "scripts", TRACKER_FS)
    tracker = os.path.join(cwd, "TRACKER.md")
    if not (os.path.isfile(trk) and os.path.isfile(tracker)):
        H.warn(f"recirc-checkpoint: tracker helper/file missing (trk={os.path.isfile(trk)}, "
               f"TRACKER.md={os.path.isfile(tracker)}) — inbox undeterminable; preserving checkpoints")
        return None, []
    still_open = _fs_query(trk, tracker, "Recirculation", "Todo")
    if still_open is None:
        return None, []   # UNKNOWN inbox (failed/corrupt read) — the caller must NOT clear taints
    handled = [(n, "done") for n in (_fs_query(trk, tracker, "Recirculation", "Done") or [])]
    handled += [(n, "blocked") for n in (_fs_query(trk, tracker, "Recirculation", "Blocked") or [])]
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
        H.warn(f"recirc-checkpoint: github owner/project undeterminable (owner={owner!r}, "
               f"project={project_number!r}) — inbox undeterminable; preserving checkpoints")
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


def _clear_session_checkpoints(cwd, sid, scope=None):
    """Clear this session's `recirc_checkpoint` taints — the obligation is satisfied. Scoped to what
    pending_taints(sid) surfaces (this session's + unattributed), so a DIFFERENT live session's
    checkpoint obligation is never cleared out from under it.

    `scope` narrows this further to the tickets THIS subagent actually handled: when a value is passed,
    only checkpoints whose ticket is IN scope are cleared, so a sous-chef that completed ITS ticket #1
    never clears a *sibling* consultant's #2 taint (they can share the parent session_id). `scope=None`
    is the whole-board-drained signal (a PROVEN-empty inbox — every open recirc ticket is gone, so every
    checkpoint is stale) and clears all of this session's checkpoints."""
    for t in idc_ledger.pending_taints(cwd, session_id=sid):
        if t.get("kind") != CHECKPOINT_TAINT:
            continue
        if scope is not None:
            try:
                if int(t.get("key")) not in scope:
                    continue
            except (TypeError, ValueError):
                continue   # a non-numeric key can't be matched to a numeric scope — leave it
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

    if still_open is None:
        # UNKNOWN inbox — the tracker/board could not be read (missing/corrupt/locked/timed-out). We
        # CANNOT prove the inbox is empty, so we must NOT clear the checkpoint obligations: clearing on
        # an unproven-empty inbox is the exact drop-F state loss (MAJOR-1). Preserve every existing
        # taint, stamp nothing new (we don't know which tickets), warn, and allow (fail-open detective).
        H.warn("recirc-checkpoint: could not determine the recirculation inbox (tracker/board "
               "unreadable) — preserving existing checkpoint taints, stamping nothing (state NOT wiped)")
        H.allow()
    if not still_open:
        # PROVEN-empty inbox (a clean, complete drain — the board really has no open Recirculation ∧
        # Todo ticket) → the obligation is satisfied → clear this session's checkpoint taints.
        _clear_session_checkpoints(cwd, sid)
        H.allow()

    # This subagent's SCOPE — the ticket(s) it is responsible for checkpointing. The rule is ASYMMETRIC
    # by design (invariant #1 / drop-F): UNDER-checkpointing a ticket the subagent owned IS the state
    # loss this hook prevents, while OVER-checkpointing is only a recoverable spurious breadcrumb (the
    # board is ground truth; a re-drain is idempotent). So the default is WIDE, and NARROW requires the
    # dispatch to pass the three-part EXPLICIT trigger (header §SCOPE): first-turn ticket #s, AND no
    # inbox-wide drainer language, AND at least one # that is recirc-REAL. Dispatch text is LLM-composed
    # English — a stray PR#/project# or an injected reminder's `#1.` must never flip a whole-inbox
    # drainer into a nothing-scope (the fable-audit under-checkpoint fix; cases K1/K2/L).
    branch, prs, candidates, dispatch_tickets, generic_dispatch = _scan_transcript(
        payload.get("agent_transcript_path", ""), cwd)
    covered = _covered_tickets(plugin_root, candidates)
    cand_tickets = _candidate_tickets(candidates)
    # Recirc-REAL numbers this stop can corroborate a narrow dispatch against: the open inbox, the
    # tickets the subagent attempted a closeout for, and the recirc tickets already moved off Todo
    # (a completed sous-chef's ticket lives HERE when its board move landed before the stop).
    recirc_real = set(still_open) | cand_tickets | {n for n, _ in handled}
    if dispatch_tickets and not generic_dispatch and (dispatch_tickets & recirc_real):
        # EXPLICIT enumeration → the Build larger-loop sous-chef dispatched over specific ticket(s).
        # Narrow to exactly those ∪ the tickets it produced a closeout candidate for, so it never stamps
        # a false breadcrumb on a stranger's open ticket (P2-1). NEUTERING the `t in scope` filter here
        # widens it back to the whole inbox — the P2-1 red-when-broken (case H). NEUTERING the
        # `not generic_dispatch` term ⇒ case K1 RED; NEUTERING the `& recirc_real` corroboration ⇒
        # case K2 RED; parsing dispatch #s from ALL user turns instead of the first ⇒ case L RED.
        scope = dispatch_tickets | cand_tickets
        uncovered = [t for t in still_open if t in scope and t not in covered]
    else:
        # GENERIC inbox-drain dispatch (inbox-wide language, or no enumerated #s — the board-scan
        # drainer) OR an undeterminable one (only noise #s that corroborate against nothing recirc-real)
        # → the drop-F-SAFE default is the WHOLE still-open inbox: a board-scan drainer owns every open
        # ticket, so a mid-drain death before it reaches #2/#3 must CHECKPOINT them, not skip them.
        # Defaulting to nothing here silently loses their state — the exact drop-F failure.
        # NEUTERING this to `[]` / scope-only is the P1 (whole-inbox-default) red-when-broken (case J).
        scope = None   # None == the whole still-open inbox (see _clear_session_checkpoints)
        uncovered = [t for t in still_open if t not in covered]

    if not uncovered:
        # Every still-open ticket in this subagent's scope is covered by a valid closeout ⇒ its drain is
        # complete ⇒ allow + clear its checkpoint taints. Scope-narrowed in the explicit case so a
        # sibling consultant's taint is never wiped; the whole-inbox default (scope=None) clears all —
        # the board is fully drained.
        _clear_session_checkpoints(cwd, sid, scope=scope)
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
    # the stop, even under IDC_HOOKS_STRICT, unlike the pre-action gates). Everything — even reading the
    # payload / argv (NIT-6) — runs inside the guard; _gate exits via H.allow() (SystemExit) on every
    # path, and any OTHER exception warns and allows.
    try:
        _gate(H.read_payload(), _plugin_root_from_argv())
    except SystemExit:
        raise
    except Exception as _e:  # noqa: BLE001 — infra bug, never a reason to break a stop
        H.warn(f"recirc-closeout gate errored, failing open (allow): {_e}")
        sys.exit(0)
    sys.exit(0)
