#!/usr/bin/env python3
"""idc_transition.py — THE single sanctioned write door to IDC tracker state (v4 Phase 2, plan §3.1).

Every mutation of board state routes through this engine. It wraps BOTH existing backends —
`idc_gh_board.py` (github Projects v2) and `idc_tracker_fs.py` (the filesystem TRACKER.md) — behind
a fixed set of TYPED ops:

    create-ticket | create-pointer | claim | move | close | dispose | recirculate-intake | link | unblock

and enforces a legal-transition table declared AS DATA in `templates/workflow-machine.yaml`
(scaffolded into a governed repo at docs/workflow/workflow-machine.yaml; the engine falls back to
the bundled template until that wiring lands). The engine is a generic interpreter of that table —
workflow rules live in the data, not here.

Three load-bearing invariants, every op:
  * ATOMIC — one op per call; a validation/guard failure mutates nothing.
  * READ-BACK VERIFIED — after a write the engine reads the item back and refuses success unless the
    observed (Stage, Status) matches the intended target (extends idc_gh_close.py's read-back
    semantics to every op). A divergence raises TransitionError — a write that did not land is never
    reported as success.
  * NORMALIZED — an op can NEVER leave a Stage set without a Status (the #255/#256 bug class). Create
    targets are checked before the write; the read-back re-checks after.

THE terminal invariant: the terminal Status (Done) is reachable ONLY through a GUARDED terminal op
whose deterministic evidence guard passes — `close` for BUILT work (a VALID, PASSING, item-owning,
pr-bound verdict) or `dispose` for a NON-verdict terminal disposition (an approved operator gate, a
decomposed pointer, a drained recirc-inbox item — each with its own per-disposition evidence guard).
Every OTHER op — create, move, claim, unblock, recirculate-intake — is refused from minting a
terminal Status, and a terminal op that resolves to NO guards (a `dispose` with a missing/unknown
disposition, or a hand-authored `guards: []` op) is FAIL-CLOSED. Everything else that touches
Status/Stage is bounded by the machine table's declared domains (a single `validate_target` gate).

Guards (close): a `close` requires a validated, passing, item-owning review verdict for the linked PR
(idc_review_verdict_check passes) AND every merge_conditions[] entry in that verdict marked met.
Guards (dispose): each disposition names a deterministic board/disk artifact — a real approval
artifact for gate-approved, a decomposition link for retired, the idc-recirc-source marker for
drained. Guards read artifacts on disk/board, not prose claims; both backends share the guard path.

Journaling is STUBBED here (one best-effort line per op to docs/workflow/transition-journal.ndjson);
the full event-sourced journal + reconciliation is Phase 4 — not built here.

Both backends are supported; semantics are proven on the FILESYSTEM backend first (hermetic smoke).
Stdlib only (github ops shell out through idc_gh_board / gh, like the sibling helpers).

CLI:  idc_transition.py --repo <dir> [--backend filesystem|github] [--tracker <TRACKER.md>]
                        [--machine <workflow-machine.yaml>] <op> <op-args…>
      exit 0 = op applied + verified; exit 2 = illegal transition / guard denied / read-back failed;
      exit 3 = rate-limited (github, resumable).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

try:
    import fcntl  # POSIX advisory file locks (macOS/Linux — IDC's platforms); appends stay lock-free elsewhere
except ImportError:  # pragma: no cover — non-POSIX
    fcntl = None

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_review_verdict_check as VC  # noqa: E402 — the verdict validator (close guard)
import idc_tracker_fs                  # noqa: E402 — filesystem backend (read-back seam)
import idc_gh_board                    # noqa: E402 — github backend (referenced by attribute so tests monkeypatch)
import idc_gh_close as GC              # noqa: E402 — atomic github close (Status=Done + close + verify)

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLED_MACHINE = os.path.join(HERE, "..", "templates", "workflow-machine.yaml")
TRK = os.path.join(HERE, "idc_tracker_fs.py")
JOURNAL_REL = os.path.join("docs", "workflow", "transition-journal.ndjson")


def _journal_item(value):
    """Return an issue number safe for replay, or None when the backend returned a non-issue id."""
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def _github_created_issue_number(item_id, repo):
    """Best-effort issue-number read-back for a newly created GitHub project item."""
    try:
        item = idc_gh_board.fetch_item(item_id, repo)
    except Exception as e:  # noqa: BLE001 — journaling is best-effort; the create already succeeded
        sys.stderr.write(f"idc-transition: could not resolve created github issue number for journal: {e}\n")
        return None
    return _journal_item((item.get("content") or {}).get("number"))


class TransitionError(Exception):
    """An op the engine refuses: an illegal transition, an unmet guard, or a read-back divergence.
    The CLI maps it to exit 2. RateLimitError (github, resumable) is deliberately NOT a subclass —
    it propagates to the CLI's exit-3 path so a throttle is never miscategorised as a hard denial."""


# ── machine table (data) ─────────────────────────────────────────────────────────────────────────
def _mini_yaml(text):
    """A tiny stdlib parser for the CONSTRAINED YAML subset workflow-machine.yaml uses (this repo
    ships no PyYAML). Handles: `key: scalar`, nested `key:` block maps by 2-space indent, inline flow
    lists `[a, b, c]` and inline flow maps `{k: v, k: v}` of flat scalars, `#` comments, blanks.
    Deliberately NOT a general YAML parser — it round-trips exactly the machine table's shape."""
    def coerce(s):
        """Coerce a bare scalar token to the SAME Python type PyYAML's safe_load produces, so the
        stdlib fallback and PyYAML parse the machine table IDENTICALLY (engine-machine-table.sh C2).
        Minimal + safe: bool / null / bare-int only; every other unquoted token (Done, "In Progress",
        stage/status names) stays a string, and explicit quotes force a string. (No yes/no/on/off —
        over-coercion could turn a legit string into a bool.)"""
        s = s.strip()
        if len(s) >= 2 and s[0] in "\"'" and s[-1] == s[0]:
            return s[1:-1]                                   # explicit quotes → always a string
        if s in ("true", "True", "TRUE"):
            return True
        if s in ("false", "False", "FALSE"):
            return False
        if s in ("null", "Null", "NULL", "~"):
            return None
        body = s[1:] if s[:1] == "-" else s                  # bare integer (PyYAML → int)
        if body.isdigit() and body != "":
            return int(s)
        return s

    def parse_scalar(s):
        s = s.strip()
        if s.startswith("[") and s.endswith("]"):
            inner = s[1:-1].strip()
            return [parse_scalar(p) for p in inner.split(",")] if inner else []
        if s.startswith("{") and s.endswith("}"):
            inner = s[1:-1].strip()
            out = {}
            if inner:
                for pair in inner.split(","):
                    k, _, v = pair.partition(":")
                    out[k.strip()] = parse_scalar(v)
            return out
        return coerce(s)

    # (indent, key, inline-value-or-None) for every non-blank, non-comment line. Unsupported YAML
    # shapes are REJECTED LOUDLY (not silently misparsed) — the machine table is operator-visible and
    # hand-editable, so a block-style list or a keyless line must fail with a clear message rather
    # than silently collapse to a dict that denies every op.
    lines = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            raise TransitionError(
                f"machine table: block-style list ('{stripped}') is unsupported by the stdlib "
                "fallback parser — use an inline flow list [a, b, c] (or install PyYAML)")
        if ":" not in stripped:
            raise TransitionError(
                f"machine table: unsupported line {stripped!r} — the stdlib fallback parser expects "
                "`key: value` (or install PyYAML)")
        indent = len(raw) - len(raw.lstrip(" "))
        key, _, val = stripped.partition(":")
        lines.append((indent, key.strip(), val.strip()))

    def build(idx, indent):
        """Return (dict, next_idx) for the block at column `indent` starting at line idx."""
        out = {}
        i = idx
        while i < len(lines):
            ind, key, val = lines[i]
            if ind < indent:
                break
            if ind > indent:  # defensive — should be consumed by the recursion below
                i += 1
                continue
            if val == "":  # a nested block map follows
                child, i = build(i + 1, indent + 2)
                out[key] = child
            else:
                out[key] = parse_scalar(val)
                i += 1
        return out, i

    doc, _ = build(0, 0)
    return doc


def validate_machine(machine, path):
    """Cross-check the table's Status/Stage domains against the filesystem backend's canonical enums
    (idc_tracker_fs) and REFUSE on any drift — so an operator edit that adds a Status the backend
    rejects (or vice-versa) fails loudly at load, not mid-op. This is the check the header comment
    promises; keep them in lockstep."""
    for field, want, key in (("Status", set(idc_tracker_fs.STATUSES), "statuses"),
                             ("Stage", set(idc_tracker_fs.STAGES), "stages")):
        got = set(machine.get(key) or [])
        if got != want:
            raise TransitionError(
                f"machine table {path}: `{key}` {sorted(got)} != backend {field} enum {sorted(want)} "
                "— the machine table and idc_tracker_fs have drifted (fix one)")


def load_machine(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # prefer PyYAML where present; fall back to the stdlib mini-parser
        doc = yaml.safe_load(text)
    except ImportError:
        doc = _mini_yaml(text)
    if not isinstance(doc, dict) or "ops" not in doc:
        raise TransitionError(f"machine table {path} is malformed (no `ops:`)")
    validate_machine(doc, path)
    return doc


def machine_path_for(repo, explicit=None):
    """Resolve the machine table: an explicit --machine wins; else the governed repo's scaffolded
    copy (docs/workflow/workflow-machine.yaml); else the bundled template (pre-scaffold fallback)."""
    if explicit:
        return explicit
    scaffolded = os.path.join(repo, "docs", "workflow", "workflow-machine.yaml")
    if os.path.isfile(scaffolded):
        return scaffolded
    return os.path.normpath(BUNDLED_MACHINE)


# ── invariants shared by every op ──────────────────────────────────────────────────────────────
def assert_normalized(stage, status):
    """The #255/#256 killer: a Stage set with an empty Status is an illegal shape — refuse to write
    it. (An item with neither is fine — it just isn't staged yet.)"""
    if stage and not status:
        raise TransitionError(
            f"normalization: refusing to write Stage={stage!r} with an empty Status (#255/#256)")


def verify_readback(num, want_stage, want_status, observed_stage, observed_status):
    """Refuse success unless the item read back matches the intended target (extends the
    idc_gh_close read-back posture to every op). want_stage=None means "this op did not set Stage"."""
    if want_stage is not None and observed_stage != want_stage:
        raise TransitionError(
            f"read-back: #{num} Stage is {observed_stage!r}, expected {want_stage!r} — write did not land")
    if want_status is not None and observed_status != want_status:
        raise TransitionError(
            f"read-back: #{num} Status is {observed_status!r}, expected {want_status!r} — write did not land")
    # A landed write must still be normalized (belt-and-braces after the backend mutation).
    assert_normalized(observed_stage, observed_status)


def op_spec(machine, op):
    spec = (machine.get("ops") or {}).get(op)
    if not isinstance(spec, dict):
        raise TransitionError(f"illegal transition: op {op!r} is not in the machine table")
    return spec


def check_status_legal(machine, status):
    if status not in (machine.get("statuses") or []):
        raise TransitionError(f"illegal transition: Status {status!r} is not a legal state")


def check_stage_legal(machine, stage):
    """A --stage must be within the machine's declared `stages:` domain — enforced ENGINE-side on BOTH
    backends, so github create no longer relies on the fs backend's incidental validation."""
    if stage and stage not in (machine.get("stages") or []):
        raise TransitionError(f"illegal transition: Stage {stage!r} is not a legal state")


def refuse_terminal(machine, op, status):
    """THE invariant: the terminal Status (Done) is reachable ONLY through a guarded terminal `close`
    (valid, PASSING, item-owning verdict). Every OTHER op — create/move/claim/unblock/recirculate —
    is refused from minting it. Applies to both backends."""
    if status == machine.get("terminal_status"):
        raise TransitionError(
            f"illegal transition: {op} may not set the terminal Status {status!r} — only a guarded "
            "`close` (with a valid, passing, item-owning verdict) may reach it")


def check_worked_state(machine, op, stage, status):
    """The engine-wide worked-state invariant: the worked Status (In Progress) is illegal on the
    non-build Stages, so NO op (create, claim, move, …) may drive OR mint an item there. Closes every
    path — a transition AND a direct `create --stage Recirculation --status "In Progress"`."""
    if status == machine.get("worked_status") and stage in (machine.get("worked_forbidden_stages") or []):
        raise TransitionError(
            f"illegal transition: {op} would set Status={status!r} on a Stage={stage!r} item "
            "— a non-build item is never worked (drain/decompose it, don't claim it)")


def validate_target(machine, op, stage, status):
    """The single pre-write gate every write's target (stage, status) passes, on BOTH backends: within
    the declared Stage/Status domains, normalized (never Stage-without-Status), non-terminal (only a
    guarded close reaches Done), and not a forbidden worked state. One choke point — no op can slip a
    target past it."""
    check_stage_legal(machine, stage)
    check_status_legal(machine, status)
    assert_normalized(stage, status)
    refuse_terminal(machine, op, status)
    check_worked_state(machine, op, stage, status)


# ── close guard ────────────────────────────────────────────────────────────────────────────────
def load_verdict(verdict_path):
    if not verdict_path:
        raise TransitionError("close denied: no --verdict receipt supplied (guard verdict-validated)")
    if not os.path.isfile(verdict_path):
        raise TransitionError(f"close denied: verdict receipt {verdict_path} does not exist")
    try:
        with open(verdict_path, encoding="utf-8") as fh:
            verdict = json.load(fh)
    except (OSError, ValueError) as e:
        raise TransitionError(f"close denied: verdict receipt {verdict_path} is unreadable ({e})")
    problems = VC.check(verdict)
    if problems:
        raise TransitionError(
            f"close denied: verdict does not validate — {'; '.join(problems[:3])} (guard verdict-validated)")
    return verdict


def unmet_merge_conditions(verdict):
    """The merge_conditions[] entries NOT marked met. Backward-compatible: absent ⇒ [] ⇒ no
    conditions ⇒ nothing blocks close."""
    return [c for c in (verdict.get("merge_conditions") or [])
            if not (isinstance(c, dict) and c.get("met") is True)]


def check_close_guards(spec, num, verdict_path, pr):
    """Evaluate a terminal op's declared guards against the verdict receipt on disk. THE close
    invariant: the verdict must be valid, PASSING, and OWN the item being closed — so no unbound or
    failing verdict can ever close anything (nor a verdict for a different item/PR)."""
    guards = spec.get("guards") or []
    if not guards:
        return  # defensive: `close` always declares verdict guards; a guard-free terminal op is
                # refused upstream in run() before reaching here (the fail-closed terminal invariant)
    if pr is None:
        raise TransitionError(
            "close denied: --pr is required — the verdict must be bound to the closing PR (no unbound close)")
    verdict = load_verdict(verdict_path)  # guard: verdict-validated (raises if missing/invalid)
    # "Validated" means PASSING, not merely schema-valid: a well-formed FAIL / FAIL-BLOCKED verdict is
    # a review that must be FIXED, never closed to Done.
    disposition = verdict.get("verdict")
    if disposition not in VC.PASSING:
        raise TransitionError(
            f"close denied: verdict disposition is {disposition!r} — only {sorted(VC.PASSING)} may "
            "close (a FAIL/FAIL-BLOCKED must be fixed, not closed) (guard verdict-validated)")
    # OWNERSHIP: the verdict must be FOR this item and this PR — a verdict for #888/PR-999 can never
    # close #2 (the unbound-verdict class). Both bindings are mandatory for a close.
    if verdict.get("issue") != num:
        raise TransitionError(
            f"close denied: verdict is for issue #{verdict.get('issue')}, not the closing item #{num} "
            "— a verdict must OWN the item it closes (unbound verdict)")
    if verdict.get("pr") != pr:
        raise TransitionError(
            f"close denied: verdict is for PR #{verdict.get('pr')}, not the closing PR #{pr}")
    if "merge-conditions-met" in guards:
        unmet = unmet_merge_conditions(verdict)
        if unmet:
            ids = ", ".join(str(c.get("id", "?")) for c in unmet)
            raise TransitionError(
                f"close denied: {len(unmet)} merge_conditions unmet [{ids}] (guard merge-conditions-met)")


# ── dispose guards (the non-verdict terminal doors — #150 journal door unification) ───────────────
# `dispose` closes a NON-build item that carries no review verdict: an approved operator gate, a
# decomposed Consideration pointer, or a drained Recirculation-inbox item. Each disposition names ONE
# deterministic, board/disk-checkable evidence guard (declared in the machine table, evaluated here) —
# so no disposition is a verdict-free backdoor to Done. The SAME guard code runs on both backends
# (only the read primitive differs); a github board-read failure raises BoardReadError/RateLimitError,
# which propagates to the CLI's resumable exit-3 path — a board glitch is never a silent guard pass.
GATE_DECISION_LABEL = "decision-approved"   # the github operator-decision GO signal (idc:idc-gate-issue)
DECISION_REJECTED_LABEL = "decision-rejected"  # the operator-decision NO-GO signal — an explicit rejection
DECISION_GATE_LABEL = "decision"            # pairs with decision-approved as the operator's GO signal on a
                                            # DECISION gate — NEVER the gate KIND (labels are any adapter
                                            # caller's door; the kind is the producer-stamped title below)
# The gate KIND signal: the producer (idc:idc-gate-issue) titles an operator-DECISION gate
# `[operator-action] Decision — …` at creation. The title, like the body, has NO adapter door
# (createTicket sets it once; setField/comment cannot edit it), so the kind cannot be retyped by
# labeling a requirements gate `decision`+`decision-approved` (codex round-10 P1). Any other
# `[operator-action]` title — the requirements template or a hand-filed gate — takes the STRICTEST
# path: only its merged bound idc-gate-pr approves it. Matched after OPERATOR_GATE_PREFIX is
# stripped; \b keeps `Decisions…`/`Decisive…` out. Residual: an out-of-adapter writer (`gh issue
# edit`) can retitle — producer authenticity is #151.
DECISION_KIND_RE = re.compile(r"\s*Decision\b")
CONSIDERATION_STAGE = "Consideration"       # a pointer Stage (mirrors idc_tracker_fs.STAGES)
PLANNING_STAGE = "Planning"                 # a pointer's in-flight Stage (Plan advances Consideration → Planning)
BUILDABLE_STAGE = "Buildable"               # a real build-work Stage (a decomposition child)
RECIRC_STAGE = "Recirculation"              # the recirc-inbox Stage
POINTER_STAGES = (CONSIDERATION_STAGE, PLANNING_STAGE)  # a pointer rides Consideration or (in flight) Planning
BLOCKED_STATUS = "Blocked"                  # a gate-parked Status (a Blocked recirc ticket is not drainable)
# The github link record `_gh_link` writes on the CHILD (`<!-- idc-blocked-by: {child,parent,kind} -->`).
BLOCKED_BY_MARKER = re.compile(r"<!--\s*idc-blocked-by:\s*(.*?)\s*-->", re.S)
# The gate's OWN recorded approval PR (`idc:idc-gate-issue` stamps it in the gate body) — binds the
# approval artifact to THIS gate so an unrelated merged PR can never terminalize it.
GATE_PR_MARKER = re.compile(r"<!--\s*idc-gate-pr:\s*(\d+)\s*-->")
# A pre-structured link record's `what` line (journal records written before parent/child fields).
LINK_WHAT_RE = re.compile(r"^link #(\d+) -> #(\d+)$")


def _parse_markers(text, pattern):
    """Parsed JSON objects for each `pattern` marker in `text`; an unparseable marker is skipped
    (fail-soft — mirrors idc_recirc_sweep.parse_markers so a hand-edited comment never crashes a guard)."""
    out = []
    for m in pattern.finditer(text or ""):
        try:
            obj = json.loads(m.group(1))
        except ValueError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def _fs_item_full(tracker, num):
    """One filesystem item's full record (title/stage/status/comments/blocked_by/parent) — the read
    seam a disposition guard uses on the filesystem backend."""
    it = next((i for i in idc_tracker_fs.load(tracker).get("issues", []) if i.get("number") == int(num)), None)
    if it is None:
        raise TransitionError(f"disposition denied: #{num} not found on the board")
    return it


def _gh_issue_json(repo, num, fields):
    """One `gh issue view --json <fields>` read → parsed dict. BoardReadError/RateLimitError propagate
    (→ the CLI's resumable exit-3 path), so a board glitch is never miscategorised as a guard denial."""
    out = idc_gh_board._gh(["issue", "view", str(int(num)), "--json", ",".join(fields)], repo)
    try:
        return json.loads(out)
    except ValueError as e:
        raise idc_gh_board.BoardReadError(f"could not parse issue #{num} json ({e})")


def _pr_merged(repo, pr):
    """True iff PR #pr is merged (github approval artifact for a requirements/decision gate)."""
    out = idc_gh_board._gh(["pr", "view", str(int(pr)), "--json", "state,mergedAt"], repo)
    try:
        data = json.loads(out)
    except ValueError as e:
        raise idc_gh_board.BoardReadError(f"could not parse PR #{pr} json ({e})")
    return data.get("state") == "MERGED" or bool(data.get("mergedAt"))


def _recirc_evidence(text):
    """The provenance evidence for a DRAINABLE recirc-inbox item, or None when there is none. An
    `idc-recirc-source` ticket carries a non-empty `what` (the discovered scope) — BOTH producers set
    it: the filer (idc_file_findings, which also adds a dedupe `key`) and the sweep
    (idc_recirc_sweep.recirc_ticket_body, `{origin, what}`, no key). A finisher-posted, sweep-restaged
    rogue instead carries an `idc-discovery` / `idc-deferral` marker with a non-empty `what`. An empty
    `{}` marker is NOT provenance — since a Stage move and a comment are both writable through the
    normal adapter, a presence-only check would let an ordinary item be forged into the no-verdict
    `drained` door; requiring the `what` scope closes that while accepting every legitimate ticket."""
    import idc_recirc_sweep as SW   # RECIRC_SOURCE_MARKER / DISCOVERY_MARKER / DEFERRAL_MARKER + parse_markers
    for obj in SW.parse_markers(text, SW.RECIRC_SOURCE_MARKER):
        if str(obj.get("what") or "").strip():
            ev = {"marker": "idc-recirc-source"}
            if str(obj.get("key") or "").strip():
                ev["key"] = obj["key"]   # the filer's dedupe key, when present
            return ev
    for name, mk in (("idc-discovery", SW.DISCOVERY_MARKER), ("idc-deferral", SW.DEFERRAL_MARKER)):
        for obj in SW.parse_markers(text, mk):
            if str(obj.get("what") or "").strip():
                return {"marker": name}
    return None


# ── journal corroboration (#150 W2 close-out; residual #151) ──────────────────────────────────────
# The `drained`/`retired` board evidence (markers, link records) rides item bodies/comments — all
# writable through the sanctioned adapter — so marker shape alone cannot prove a sanctioned producer
# wrote it. These helpers ADDITIONALLY require the item's sanctioned JOURNAL record (the sweep's
# re-stage / the engine's intake for drained; the engine's link record for retired): a forger must
# now also fabricate journal lines, and an unjournaled raw Stage flip surfaces as replay divergence
# once the janitor's replay check defaults on (W3). HONEST RESIDUAL: this proves provenance SHAPE +
# journal corroboration, NOT producer authenticity — a writer with repo+board access can forge both.
# Closing the raw setField-Stage door itself (a guarded stage-transition engine op) is issue #151.
def _entry_names_item(entry, num, node=None):
    """True iff a journal entry is about item #num — by its issue number (`item`, or the parsed
    operation-shaped `what`), or by github project-item node id for the documented best-effort gap
    where a create's issue-number read-back failed and the record carries only `project_item_id`."""
    import idc_journal_replay as RP
    if RP.journal_item_id(entry) == int(num):
        return True
    return node is not None and entry.get("project_item_id") == node


def _link_record_matches(entry, parent, child):
    """True iff a journal entry is the engine's DECOMPOSITION link record naming BOTH this parent and
    this child — structured `parent`/`child` fields, with a fallback parse of the pre-structured
    `what` line. The decomposition contract is kind=sub (codex round-13 P2): an engine blocks-edge
    (gate chaining, dependency ordering) is a relationship, never a decomposition — so a record that
    CARRIES a `kind` must say "sub". A record with NO kind field predates kind journaling and is
    tolerated (the legacy carve-out: its shape cannot distinguish, and the Plan playbook has always
    linked decompositions `--kind sub`)."""
    if entry.get("op") != "link":
        return False
    kind = entry.get("kind")
    if kind is not None and kind != "sub":
        return False
    p, c = _journal_item(entry.get("parent")), _journal_item(entry.get("child"))
    if p is None or c is None:
        m = LINK_WHAT_RE.match(str(entry.get("what") or ""))
        if not m:
            return False
        p, c = int(m.group(1)), int(m.group(2))
    return p == int(parent) and c == int(child)


def _journal_corroboration(ctx, num, predicate, denial):
    """The corroboration gate a forgeable dispose guard calls AFTER its board checks pass. Semantics:
      * journal absent entirely, or NO create record journaled at all, or #num below the NUMBERED
        adoption watermark (the earliest numbered create; item numbers are monotonic on both
        backends) → PRE-JOURNAL LEGACY: the board evidence stands alone — tolerated, still
        marker/link-guarded, never guard-free (the documented #151 residual; a new item can never
        reach this branch, its number is above every existing create's).
      * journal corrupt/unreadable → FAIL CLOSED — damaging the journal must deny, never unlock the
        carve-out (scan_journal_strict, unlike replay's lenient watermark helper).
      * adopted journal whose creates are ALL numberless (the github read-back gap) → watermark is
        None but the carve-out is NOT granted: corroboration is REQUIRED (the project_item_id
        fallback matches genuine numberless records) — else a first-create read-back failure would
        fail the guard open for every item on the board (codex round-8 P2).
      * #num at/above the watermark with no record matching `predicate` → FAIL CLOSED with `denial`
        (a remediation-naming message).
    Returns the matching record, or None on the legacy carve-out (callers DISCLOSE that in the
    dispose evidence, so every carve-out use is visible in the journal line it writes)."""
    import idc_journal_replay as RP
    entries, err = RP.scan_journal_strict(os.path.join(ctx["repo"], JOURNAL_REL))
    if err:
        raise TransitionError(
            f"disposition denied: the transition journal cannot be read for corroboration ({err}) — "
            "repair/restore the journal (janitor replay reconciliation) before disposing")
    if not RP.journal_adopted(entries):
        return None  # true pre-journal legacy — no create record at all (residual: #151)
    watermark = RP.watermark_from(entries)
    # A numberless create VOIDS the numbered watermark as an adoption lower bound: the true first
    # create may be the numberless one, so an item numbered between it and the first NUMBERED
    # create is post-adoption, not legacy — the carve-out is disabled and corroboration is
    # required for every item (fail closed; codex round-9 P1).
    if watermark is not None and int(num) < watermark and not RP.has_numberless_create(entries):
        return None  # below the numbered adoption watermark — pre-journal legacy (residual: #151)
    for entry in entries:
        if predicate(entry):
            return entry
    raise TransitionError(denial)


def _gh_node_for_corroboration(ctx, num):
    """The project-item node id used ONLY as a fallback matcher for numberless github create records.
    Best-effort: an ORDINARY resolve failure degrades to issue-number matching, never to a guard
    error (the rare cost: a numberless record + a failed lookup denies with a remediation message).
    A RATE LIMIT is different — transient and run-global — so it re-raises to the CLI's resumable
    exit-3 contract; swallowing it here turned a throttle into a missing-corroboration denial
    (exit 2), mis-signaling a permanent guard failure to the drain (codex round-10 P2)."""
    if ctx["backend"] != "github":
        return None
    try:
        return _gh_item_id(ctx, num)
    except idc_gh_board.RateLimitError:
        raise
    except Exception:  # noqa: BLE001 — fallback matcher only; the primary item match still applies
        return None


def check_gate_approved(ctx, num, kw):
    """gate-approval-artifact: the item is an `[operator-action]` gate AND the backend's real approval
    artifact is present, BOUND to this gate. github — the gate's OWN recorded approval PR (the
    `idc-gate-pr` marker the gate body carries) is merged, OR — only on an operator-DECISION gate,
    whose KIND is read from the producer-stamped `[operator-action] Decision — …` TITLE, never from
    labels — the decision/decision-approved label pair is present. An unrelated merged PR, a stray
    label, or a relabeled requirements gate can never approve. filesystem — no PRs/labels exist, so
    the operator's own explicit Done-move via THIS op is the approval (PR #73 gate-item semantics);
    the gate marker confines it to a genuine gate so it can never mint a verdict-free Done for build
    work."""
    from idc_board_lint import OPERATOR_GATE_PREFIX   # single-sourced gate marker
    if ctx["backend"] != "github":
        it = _fs_item_full(ctx["tracker"], num)
        if not (it.get("title") or "").startswith(OPERATOR_GATE_PREFIX):
            raise TransitionError(
                f"gate-approved denied: #{num} is not an {OPERATOR_GATE_PREFIX} gate item — only an "
                "operator gate is closed as gate-approved (build work closes via a verdict-guarded `close`)")
        return {"approval": "operator-done-move"}  # fs: the operator's explicit Done-move IS the approval
    info = _gh_issue_json(ctx["repo"], num, ["title", "labels", "body", "comments"])
    title = info.get("title") or ""
    labels = {(lbl or {}).get("name") for lbl in (info.get("labels") or [])}
    # Where the idc-gate-pr marker LIVES decides how much it proves (codex round-8 P1): the gate
    # BODY is stamped by the producer at creation (idc:idc-gate-issue) and the adapter exposes no
    # body edit, so a body marker is the gate's own record. A COMMENT is the adapter's cheap
    # any-caller door — kept ONLY as the legacy-migration path — so a comment-sourced marker must
    # ALSO be corroborated by the gate body's own prose Think-PR pointer naming the SAME PR (#N or
    # a /pull/N link, which the gate body template always carries): a forger can comment a marker
    # naming any merged PR, but has no adapter door to make the gate body reference it.
    gate_body = info.get("body") or ""
    comments_text = "\n".join((c or {}).get("body") or "" for c in (info.get("comments") or []))
    if not title.startswith(OPERATOR_GATE_PREFIX):
        raise TransitionError(
            f"gate-approved denied: #{num} is not an {OPERATOR_GATE_PREFIX} gate item — only an operator "
            "gate is closed as gate-approved (build work closes via a verdict-guarded `close`)")
    # An explicit NO-GO overrides everything: a gate carrying `decision-rejected` is never approved,
    # even if a stale `decision-approved` label was left behind (fail-closed on a rejection).
    if DECISION_REJECTED_LABEL in labels:
        raise TransitionError(
            f"gate-approved denied: gate #{num} carries a {DECISION_REJECTED_LABEL!r} (NO-GO) label — an "
            "explicit rejection is never approved (drop the dependents per the operator's note instead)")
    # The gate KIND comes from the producer-stamped TITLE (see DECISION_KIND_RE): deriving it from
    # the mutable `decision` label let any adapter caller RETYPE a requirements gate into the
    # label-approval path — add decision+decision-approved to a gate whose Think PR never merged and
    # close it, bypassing the merged-Think-PR rule (codex round-10 P1).
    is_decision = DECISION_KIND_RE.match(title[len(OPERATOR_GATE_PREFIX):]) is not None
    # (1) the gate's OWN recorded approval PR, stamped as an idc-gate-pr marker in the gate BODY and
    # bound to THIS gate. Two hardenings (codex round-14):
    #   P1 — EXACTLY ONE body marker may bind. The producer stamps one (the canonical footer); a
    #        SECOND marker (e.g. one embedded in an inline PRD/TRD diff, before the footer) is an
    #        ambiguity a bare .search() would silently resolve to the FIRST — letting an embedded
    #        marker naming an already-merged PR bind while the real Think PR stays open. Fail closed.
    #   P2 — the marker is required in the BODY, NEVER a comment. The gate body has no adapter door
    #        (createTicket stamps it once; setField/comment cannot edit it), so a body marker IS the
    #        gate's own record; a comment is any adapter caller's door. The old comment-migration path
    #        corroborated a comment marker by a body-wide "PR #N" match — but that matched ANYWHERE in
    #        the body (incl. inside an embedded diff that merely mentions some already-merged PR), and
    #        the canonical gate template's approval line ("TO APPROVE: merge the Think PR.") carries no
    #        PR number to anchor to. So a legacy gate is migrated by stamping the marker in the gate
    #        BODY (a one-line body edit the operator can make), not a comment. Residual: an
    #        out-of-adapter body writer (`gh issue edit`) is producer-authenticity — #151.
    body_prs = GATE_PR_MARKER.findall(gate_body)
    if len(body_prs) > 1:
        raise TransitionError(
            f"gate-approved denied: gate #{num} carries {len(body_prs)} idc-gate-pr markers in its body "
            f"({', '.join('#' + p for p in body_prs)}) — the producer stamps exactly ONE (the canonical "
            "footer); a second marker (e.g. embedded in an inline PRD/TRD diff) is ambiguous and could "
            "bind an already-merged PR while the real Think PR stays open. Keep exactly one idc-gate-pr "
            "marker in the gate body.")
    if body_prs:
        bound_pr = int(body_prs[0])
        if kw.get("gate_pr") is not None and int(kw["gate_pr"]) != bound_pr:
            raise TransitionError(
                f"gate-approved denied: --gate-pr #{kw['gate_pr']} is not gate #{num}'s recorded approval "
                f"PR #{bound_pr} — the approval artifact must be bound to THIS gate")
        if _pr_merged(ctx["repo"], bound_pr):
            return {"approval": "gate-pr", "gate_pr": bound_pr}
        # The recorded PR is not merged. A REQUIREMENTS gate admits ONLY via its merged Think PR, so it
        # is refused here; a DECISION gate has the `decision-approved` label as a documented ALTERNATIVE
        # signal, so fall through to (2) rather than blocking a valid label approval.
        if not is_decision:
            raise TransitionError(
                f"gate-approved denied: gate #{num}'s recorded approval PR #{bound_pr} is not merged "
                "(a requirements gate admits only via its merged Think PR)")
    elif not is_decision and GATE_PR_MARKER.search(comments_text):
        # A marker ONLY in a comment is not the gate's own record (a comment is any adapter caller's
        # door), so it cannot bind a REQUIREMENTS gate's approval PR (codex round-14 P2). Name the
        # body-stamp remediation. A DECISION gate is NOT raised here — it still has its label pair, so
        # a comment marker there is simply ignored (it never approves on its own) and we fall through.
        raise TransitionError(
            f"gate-approved denied: gate #{num}'s only idc-gate-pr marker rides a COMMENT — a comment is "
            "any adapter caller's door, so it cannot bind the gate's approval PR. Migrate a legacy gate "
            "by stamping the `<!-- idc-gate-pr: <PR#> -->` marker in the gate BODY (a one-line body "
            "edit), then dispose.")
    # A gate with NO body idc-gate-pr marker is NOT approvable by a caller-supplied --gate-pr: that
    # would bind approval to any merged PR, not to THIS gate's own Think PR (the gate-bound invariant).
    # A legacy gate (created before the marker) must first be MIGRATED — stamp its `idc-gate-pr` marker
    # in the BODY (a one-line body edit) — so its recorded PR is verified above. --gate-pr is only ever
    # a confirming cross-check of the body marker, never an approval source on its own.
    # (2) an operator-DECISION gate approved by label — ONLY on a decision-TITLED gate that carries
    # the documented decision/decision-approved label PAIR (the operator's explicit GO act; the
    # close-time recheck re-proves that same pair still holds). A requirements gate must approve via
    # its merged Think PR — whatever labels it carries.
    if is_decision and DECISION_GATE_LABEL in labels and GATE_DECISION_LABEL in labels:
        return {"approval": "decision-label"}
    raise TransitionError(
        f"gate-approved denied: gate #{num} carries no bound approval artifact — no merged `idc-gate-pr` "
        f"approval PR (stamp the marker in the gate BODY to migrate a legacy gate), and no {DECISION_GATE_LABEL!r}+"
        f"{GATE_DECISION_LABEL!r} label pair on an operator-DECISION gate (kind = the producer-stamped "
        f"`{OPERATOR_GATE_PREFIX} Decision — …` title; labels never retype a gate — approval is the "
        "operator's act, bound to this gate, never the caller's)")


def check_retired(ctx, num, kw):
    """pointer-decomposition-record: the item is a Consideration/Planning pointer (Plan advances a
    decomposed pointer Consideration → Planning before retiring it) AND the named --child is a real
    Buildable decomposition result on the board that references the pointer through the engine's own
    DECOMPOSITION link — the kind=sub contract (codex round-13 P2): child.parent == pointer on
    filesystem (a blocks-edge lands in blocked_by and is a dependency, never a decomposition); a
    kind=sub idc-blocked-by marker naming BOTH this child and this pointer, or the portable
    adapter's native `Tracked by:#<pointer>` sub-issue line, on github — AND (above the journal
    adoption watermark) the engine's JOURNALED kind=sub link record corroborates that board
    relation, because board link records are adapter-writable and forgeable alone (#151). Returns
    the decomposition evidence."""
    child = kw.get("child")
    if child is None:
        raise TransitionError(
            "retired denied: --child is required — name a Buildable decomposition child that references "
            "the pointer being retired (the decomposition record the guard verifies)")
    pointer = get_item(ctx, num)
    if pointer["stage"] not in POINTER_STAGES:
        raise TransitionError(
            f"retired denied: #{num} is Stage={pointer['stage']!r}, not a {'/'.join(POINTER_STAGES)} "
            "pointer — only a decomposed pointer is retired (build work closes via a verdict-guarded `close`)")
    if pointer["status"] == BLOCKED_STATUS:
        # A pointer still Blocked behind an unmerged Think gate is UN-admitted. Retiring it mints a
        # terminal Done, after which the gate-unblock can never advance it — the pending consideration
        # is silently dropped. An admitted pointer rides Todo; refuse the un-admitted one.
        raise TransitionError(
            f"retired denied: pointer #{num} is {BLOCKED_STATUS} (pending its Think gate, un-admitted) — "
            "it must be unblocked (admitted) before it can be retired, never terminalized behind its gate")
    if get_item(ctx, child)["stage"] != BUILDABLE_STAGE:
        raise TransitionError(
            f"retired denied: child #{child} is not a {BUILDABLE_STAGE} decomposition result — retire on "
            "a real build child, not another pointer / inbox item")
    if ctx["backend"] == "github":
        info = _gh_issue_json(ctx["repo"], child, ["body", "comments"])
        text = (info.get("body") or "") + "\n" + "\n".join(
            (c or {}).get("body") or "" for c in (info.get("comments") or []))
        # The engine's `link` writes an idc-blocked-by marker naming BOTH ends AND its kind; the
        # portable adapter's native `link(kind=sub)` records a `Tracked by:#<parent>` line (its
        # sub-issue fallback). Only the kind=sub shapes are DECOMPOSITION evidence (codex round-13
        # P2): a kind=blocks marker is a dependency/gate edge and must never retire a pointer.
        refs = (any(m.get("parent") == int(num) and m.get("child") == int(child)
                    and m.get("kind") == "sub"
                    for m in _parse_markers(text, BLOCKED_BY_MARKER))
                or re.search(rf"Tracked by:\s*#{int(num)}\b", text) is not None)
    else:
        # filesystem: `link --kind sub` sets child.parent; `--kind blocks` appends child.blocked_by.
        # Only the parent field is decomposition evidence — a blocks-edge (gate chaining, dependency
        # ordering) naming the pointer must never retire it (codex round-13 P2).
        c_it = _fs_item_full(ctx["tracker"], child)
        refs = c_it.get("parent") == int(num)
    if not refs:
        raise TransitionError(
            f"retired denied: child #{child} does not reference pointer #{num} through a kind=sub "
            "decomposition link (a blocks-edge is a dependency, not a decomposition) — link the "
            f"decomposition child through the engine first (`link --parent {num} --child {child} "
            "--kind sub`)")
    # Journal corroboration (#150 W2): the board relation above is adapter-writable, so it must be
    # backed by the engine's own journaled link record (legacy pointers below the adoption watermark
    # keep board-only semantics — disclosed in the evidence; residual #151).
    corroborating = _journal_corroboration(
        ctx, num, lambda e: _link_record_matches(e, num, child),
        f"retired denied: pointer #{num}'s decomposition link to child #{child} is not journaled — "
        f"board link records alone do not prove an engine decomposition (#151): re-link through the "
        f"engine (`link --parent {num} --child {child} --kind sub`), then retire")
    # Return the GUARD-VALIDATED Stage: the terminal journal records the final Stage only from a
    # disposition that validated it, so a retired pointer's Consideration → Planning advance replays
    # coherently while an unvalidated (e.g. gate) Stage drift is never laundered.
    return {"child": int(child), "stage": pointer["stage"],
            "corroboration": corroborating.get("op") if corroborating else "pre-journal-legacy"}


def check_drained(ctx, num, kw):
    """recirc-provenance: the item is a Stage=Recirculation inbox ticket that is NOT gate-parked
    (Status != Blocked — a Blocked recirc ticket is pending a human gate and must not be discarded)
    AND carries a VALID recirc-provenance marker (an `idc-recirc-source` with a non-empty `what` from
    the filer/sweep, or an `idc-discovery` / `idc-deferral` with a non-empty `what` from a
    finisher-posted, sweep-restaged rogue) AND (above the journal adoption watermark) a corroborating
    journal record proves a sanctioned door put it on the inbox — the sweep's re-stage or the engine's
    intake — because Stage moves and markers are both adapter-writable and forgeable alone (#151).
    Returns the provenance evidence. Both body AND comments are scanned (the finisher posts
    discovery/deferral markers as comments, mirroring idc_recirc_sweep)."""
    if ctx["backend"] == "github":
        cur = get_item(ctx, num)
        stage, status = cur["stage"], cur["status"]
        info = _gh_issue_json(ctx["repo"], num, ["body", "comments"])
        text = (info.get("body") or "") + "\n" + "\n".join(
            (c or {}).get("body") or "" for c in (info.get("comments") or []))
    else:
        it = _fs_item_full(ctx["tracker"], num)
        stage, status = it.get("stage") or "", it.get("status") or ""
        text = "\n".join(it.get("comments") or [])
    if stage != RECIRC_STAGE:
        raise TransitionError(
            f"drained denied: #{num} is Stage={stage!r}, not {RECIRC_STAGE} — only a recirc-inbox item "
            "is drained")
    if status == BLOCKED_STATUS:
        raise TransitionError(
            f"drained denied: #{num} is {BLOCKED_STATUS} (parked behind a human gate) — a gate-blocked "
            "recirc ticket is not drainable until its gate clears (do not discard pending work)")
    ev = _recirc_evidence(text)
    if ev is None:
        raise TransitionError(
            f"drained denied: #{num} carries no VALID recirc-provenance marker (an idc-recirc-source, "
            "idc-discovery, or idc-deferral marker with a non-empty `what` scope — an empty {} marker is "
            "not provenance and a bare Recirculation item is not a drainable inbox ticket)")
    # Journal corroboration (#150 W2): the marker above is adapter-writable, so a sanctioned journal
    # record must ALSO name this item — the sweep's re-stage or the engine's intake (legacy items
    # below the adoption watermark keep marker-only semantics — disclosed; residual #151).
    import idc_recirc_sweep as SW
    node = _gh_node_for_corroboration(ctx, num)
    sanctioned = (SW.RESTAGE_JOURNAL_OP, SW.INTAKE_JOURNAL_OP)
    corroborating = _journal_corroboration(
        ctx, num,
        lambda e: e.get("op") in sanctioned and _entry_names_item(e, num, node),
        f"drained denied: #{num} has no corroborating journal record (a sweep re-stage "
        f"`{SW.RESTAGE_JOURNAL_OP}` or an engine intake `{SW.INTAKE_JOURNAL_OP}`) — board markers "
        f"alone do not prove a sanctioned re-stage (#151): route the item through the engine "
        f"(`recirculate-intake`) or let the sweep re-stage it (both journal), then dispose; if the "
        f"item is ALREADY Stage=Recirculation and its original record was lost, the sweep's next "
        f"--auto-correct run backfills the record (a disclosed journal-heal), after which this "
        f"dispose succeeds")
    ev["corroboration"] = corroborating.get("op") if corroborating else "pre-journal-legacy"
    ev["stage"] = stage   # the GUARD-VALIDATED Stage (Recirculation) — journaled as the terminal Stage
    return ev


# The machine table declares a guard NAME per disposition; the engine maps each to its evaluator.
# A disposition whose guard has no evaluator here is refused (never silently allowed).
DISPOSITION_GUARDS = {
    "gate-approval-artifact": check_gate_approved,
    "pointer-decomposition-record": check_retired,
    "recirc-provenance": check_drained,
}


def run_disposition_guards(ctx, num, kw, guards, disposition):
    """Evaluate every declared guard for `disposition`, returning the merged evidence they verified.
    Guards are READ-ONLY and idempotent, so the dispatcher runs this TWICE per dispose: once up
    front (fail fast before any further work) and once immediately before the terminal write — the
    round-11 full re-proof that re-validates every mutable guard input in the narrowest window the
    missing compare-and-set (#104) allows. A guard with no engine evaluator is refused (never
    silently allowed)."""
    evidence = {}
    for g in guards:
        evaluator = DISPOSITION_GUARDS.get(g)
        if evaluator is None:
            raise TransitionError(
                f"{disposition} denied: machine table names guard {g!r} with no engine evaluator")
        found = evaluator(ctx, num, kw)   # the guard returns the evidence it actually verified
        if found:
            evidence.update(found)
    return evidence


def resolve_terminal_guards(spec, kw):
    """Resolve a terminal op's applicable guards. A `close`-style op uses `spec['guards']`; a
    `dispose`-style op (declares a `dispositions` table) resolves the named --disposition's guards —
    a missing/unknown disposition yields NO guards (the caller then fails it closed). Returns
    (guards, disposition_or_None). The machine table is the source of truth for the valid dispositions,
    so an unknown value is refused by the engine, not by the CLI."""
    def _guards(value, label):
        # An operator-visible machine file is hand-editable, so a mis-authored `guards` (a scalar, a
        # non-string element) must fail closed with a clear TransitionError (→ exit 2), never a
        # TypeError traceback when run() iterates it. None/[] → [] (a guard-free terminal, refused above).
        if value in (None, []):
            return []
        if not isinstance(value, list) or not all(isinstance(g, str) for g in value):
            raise TransitionError(f"machine table: {label} `guards` must be a list of strings, got {value!r}")
        return value
    dispositions = spec.get("dispositions")
    if dispositions is not None:
        # `dispositions` must be a mapping; fail closed rather than AttributeError on `.get` below.
        if not isinstance(dispositions, dict):
            raise TransitionError(
                f"machine table: op `dispositions` must be a mapping, got {type(dispositions).__name__}")
        disp = kw.get("disposition")
        entry = dispositions.get(disp) if disp else None
        if not isinstance(entry, dict):
            return [], disp
        return _guards(entry.get("guards"), f"disposition {disp!r}"), disp
    return _guards(spec.get("guards"), "terminal op"), None


# ── journal stub (Phase 4 builds the real thing) ─────────────────────────────────────────────────
def _retry_would_regress(path, line):
    """True when re-appending `line` to the CURRENT journal would harm rather than heal:
      * the rotation's drain already preserved this exact line (a retry would only duplicate it), or
      * a record for the SAME item timestamped at/after ours already landed — another writer
        journaled a newer transition between our lost write and this retry, and replay reconstructs
        an item's state from its LAST record, so landing our OLDER record after the newer one would
        rewind reconstruction to stale state: a false divergence (codex round-11 P2). Losing one
        audit line on this triply-degraded path (unlocked append + rotation race + concurrent
        writer) is the better failure, and the skip warning names it.
    Ordering uses the records' `when` (UTC, second resolution, lexicographically ordered); an
    equal-second tie skips too — erring toward no-false-divergence. The scan covers EVERY journal
    segment (the rotation archives first, then the active journal — RP._journal_paths, the same
    order replay reads): a newer same-item record the rotation already archived would otherwise be
    missed and the stale re-append would still rewind reconstruction (codex round-12 P2). A segment
    that cannot be read means ordering cannot be established — DECLINE the retry (return True): a
    skipped audit line on this triply-degraded path beats a false divergence."""
    try:
        import idc_journal_replay as RP
        record = json.loads(line)
        item = RP.journal_item_id(record)
        when = str(record.get("when") or "")
        for seg in RP._journal_paths(path):
            if not os.path.exists(seg):
                continue
            with open(seg, encoding="utf-8") as fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    if raw == line:
                        return True   # the drain already preserved this exact line
                    if item is None or not when:
                        continue      # no item/timestamp to order by — only the exact-line check applies
                    try:
                        other = json.loads(raw)
                    except ValueError:
                        continue
                    if (isinstance(other, dict) and RP.journal_item_id(other) == item
                            and str(other.get("when") or "") >= when):
                        return True   # a same-item record at/after ours — ours must never land after it
    except OSError:
        return True   # ordering not establishable — decline the retry rather than risk a stale re-append
    return False


def _unlocked_append(path, line):
    """The UNLOCKED journal append (fcntl absent, or the sidecar flock failed) — with a rotation-race
    inode check. The janitor's rotation os.replace-s the journal under ITS held lock and then drains
    the replaced inode; that drain recovers only unlocked appends that landed BEFORE its read — a
    write landing AFTER it sits on the unlinked old inode and is silently lost (codex round-10 P2).
    So after writing, verify the inode written to is still the journal path's inode (the replace is
    the only thing that changes it) and re-append to the CURRENT path on a mismatch — UNLESS the
    current journal shows the retry would REGRESS replay ordering (_retry_would_regress: the drain
    already preserved the line, or a newer same-item record landed first — codex round-11 P2).
    Bounded to one retry: two rotations inside one append is not a live case, and the final mismatch
    warns naming the janitor replay check rather than looping. A drain-DUPLICATED line (the write
    landed before the drain read AND is re-appended here) is benign — replay applies per-item state
    idempotently — a lost record is not. Fail-soft is preserved by the caller: any OSError here is
    swallowed by journal_append's outer best-effort handler.

    Returns ``True`` iff the line durably landed on the current journal inode (or is already present —
    the regress-skip), ``False`` iff it kept racing rotations and may be lost (so a caller that must
    confirm the record — the sweep's journal-backfill heal — never counts an unconfirmed append)."""
    for attempt in (1, 2):
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
            written = os.fstat(fh.fileno())
        current = os.stat(path)
        if (written.st_dev, written.st_ino) == (current.st_dev, current.st_ino):
            return True
        if attempt == 1:
            if _retry_would_regress(path, line):
                sys.stderr.write("idc-transition: journal rotated during an unlocked append and the "
                                 "current journal segments already carry this line or a newer "
                                 "same-item record (or could not be read to establish ordering) — "
                                 "skipping the re-append (an older record must never land after a "
                                 "newer one)\n")
                return True   # already present — the record is durable, just not via this write
            sys.stderr.write("idc-transition: journal rotated during an unlocked append; "
                             "re-appending to the current journal\n")
    sys.stderr.write("idc-transition: unlocked append kept racing rotations — the journal line may "
                     "be lost; reconcile via the janitor's replay check\n")
    return False


def journal_append(repo, op, backend, tracker_rel, kw, cur=None):
    """Append ONE line per op. Best-effort — a journal failure never fails the op.

    The original journal-spine contract required the durable audit fields (who/what/when/guard hash /
    backend/tracker).  U2 adds replayable structure on the same line — ``op``, ``item`` when the
    issue number is known, and a target ``to`` state when the operation changes board state — so the
    reconciler consumes the engine's canonical journal instead of a synthetic side journal.

    Returns ``True`` iff the record was durably appended (or already present via the unlocked
    rotation-race regress-skip), ``False`` iff the append failed (a caught exception — permissions, a
    full disk, a lock/write error) or could not be confirmed (the unlocked path kept racing a
    rotation). Engine callers IGNORE the return — the fail-soft contract is unchanged — but a caller
    for which the journal record IS the whole point (the sweep's journal-backfill heal, codex round-14
    P2) checks it so a swallowed failure is never counted as a landed record.
    """
    try:
        path = os.path.join(repo, JOURNAL_REL)
        os.makedirs(os.path.dirname(path), exist_ok=True)

        num = kw.get("num")
        what = f"{op} #{num}" if num else op
        if op in ("move", "claim", "unblock") and cur:
            what += f" {cur.get('status')} -> {kw.get('to_status')}"
        elif op in ("close", "dispose") and cur:
            what += f" {cur.get('status')} -> {kw.get('to_status')}"
            if op == "dispose" and kw.get("disposition"):
                what += f" [{kw['disposition']}]"
        elif op == "link":
            what = f"link #{kw.get('parent')} -> #{kw.get('child')}"
        elif op in ("create-ticket", "recirculate-intake", "create-pointer"):
            what = f"{op} '{kw.get('title')}'"

        guard_hash = None
        if kw.get("verdict"):
            try:
                with open(kw["verdict"], "rb") as f:
                    guard_hash = hashlib.sha1(f.read()).hexdigest()[:12]
            except (OSError, TypeError):
                guard_hash = "unreadable-verdict"

        record = {
            "when": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "who": kw.get("agent", "unattributed"),
            "what": what,
            "guard_evidence_hash": guard_hash,
            "backend": backend,
            "repo-relative tracker": tracker_rel,
            "op": op,
        }

        item = _journal_item(num)
        if item is not None:
            record["item"] = item
        if kw.get("project_item_id"):
            record["project_item_id"] = kw["project_item_id"]
        # Structured link fields (round-13): `parent`/`child` let the corroboration predicate match
        # without parsing `what`, and `kind` lets it require the DECOMPOSITION contract (kind=sub) —
        # an engine blocks-edge must never corroborate a pointer retirement. Absent on pre-round-13
        # records (the what-parse fallback tolerates those; kind unknown → legacy carve-out).
        if op == "link":
            for key in ("parent", "child", "kind"):
                if kw.get(key) is not None:
                    record[key] = kw[key]
        # A dispose close records which door (op=dispose) + disposition + the evidence the guard
        # actually VERIFIED (the merged approval PR / approval label, the decomposition child, or the
        # recirc-provenance marker+key) — the "which door + disposition + evidence" audit the terminal
        # invariant requires, independent of which optional caller args were passed.
        if kw.get("disposition"):
            record["disposition"] = kw["disposition"]
        if kw.get("disposition_evidence"):
            record["evidence"] = kw["disposition_evidence"]
        # A journal-BACKFILL record (the sweep ratifying a board mutation whose original best-effort
        # append was lost) DISCLOSES itself — audit lines must never pretend the original append
        # happened (codex round-11 P2; the sweep's heal_unjournaled_inbox is the only producer).
        if kw.get("heal"):
            record["heal"] = kw["heal"]
        # `unblock --by GATE` records the gate whose dependency was removed — the audit line that
        # proves the block was cleared through the guarded door, not a raw dependency DELETE.
        if op == "unblock" and kw.get("by") is not None:
            record["unblocked_by"] = _journal_item(kw["by"]) or kw["by"]

        to_state = {}
        if kw.get("to_stage") is not None:
            to_state["stage"] = kw.get("to_stage")
        # A MID-lifecycle status-only op (move/claim/unblock) journals ONLY status — stamping the
        # current board Stage would canonize an out-of-band Stage edit as expected state on the item's
        # NEXT sanctioned op, silencing the reconciliation gate. A TERMINAL op (close/dispose) is the
        # item's LAST op — there is no next op to silence — so it DOES journal the final Stage (passed
        # as to_stage=cur["stage"]); this keeps replay coherent for a pointer whose Stage legitimately
        # advanced Consideration → Planning (a raw setField, no Stage engine op) before it was retired,
        # and the disposal guard already verified that Stage. The prior stage-setting record (create /
        # explicit stage target) stays the Stage expectation for every non-terminal op.
        if kw.get("to_status") is not None:
            to_state["status"] = kw.get("to_status")
        if to_state:
            record["to"] = to_state

        line = json.dumps(record, sort_keys=True, ensure_ascii=False)
        # Serialize against the janitor's rotation rewrite (#150 W1): BOTH sides take
        # fcntl.flock(LOCK_EX) on the STABLE sidecar `<journal>.lock` — never the journal inode
        # itself, which the rotation's os.replace swaps out under a held lock. The journal is opened
        # only AFTER the lock is held, so this append can never land inside a rotation's
        # read-then-replace window (where it would be silently dropped). FAIL-SOFT like the rest of
        # journaling: a lock failure warns and appends UNLOCKED — the rotation side's drain of the
        # replaced inode recovers an unlocked write that landed before the drain read, and the
        # unlocked path's own inode verify + re-append (_unlocked_append) covers one that landed
        # after it (codex round-10 P2).
        lock_fh = None
        if fcntl is not None:
            try:
                lock_fh = open(path + ".lock", "a")
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
            except OSError as le:
                sys.stderr.write(f"idc-transition: journal sidecar lock unavailable ({le}); appending unlocked\n")
                if lock_fh is not None:
                    try:
                        lock_fh.close()
                    except OSError:
                        pass
                    lock_fh = None
        try:
            if lock_fh is not None:
                # LOCKED append: the rotation holds the same sidecar LOCK_EX across its whole
                # read → replace → drain, so the journal inode cannot be swapped out mid-append.
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
                appended = True
            else:
                appended = _unlocked_append(path, line)
        finally:
            if lock_fh is not None:
                try:
                    lock_fh.close()   # closing the fd releases the flock
                except OSError:
                    pass
        return appended
    except Exception as e:
        sys.stderr.write(f"idc-transition: journal_append failed: {e}\n")
        return False


# ── filesystem backend ───────────────────────────────────────────────────────────────────────────
def _trk(tracker, *args):
    return subprocess.run([sys.executable, TRK, "--tracker", tracker, *args],
                          capture_output=True, text=True)


def fs_get_item(tracker, num):
    """Read one item back as {stage, status}. A single seam so a read-back divergence is testable by
    monkeypatch (mirrors idc_gh_board._gh being the github seam)."""
    state = idc_tracker_fs.load(tracker)
    it = next((i for i in state.get("issues", []) if i.get("number") == int(num)), None)
    if it is None:
        raise TransitionError(f"read-back: #{num} not found after write")
    return {"stage": it.get("stage") or "", "status": it.get("status") or ""}


def _fs_create(machine, op, tracker, spec, title, body, stage_over, status_over):
    target = spec.get("target") or {}
    stage = stage_over or target.get("stage") or ""
    status = status_over or target.get("status") or ""
    validate_target(machine, op, stage, status)            # one pre-write gate (domains/normalized/terminal/worked)
    # ATOMIC: the item AND its marker comment land in ONE idc_tracker_fs save (fsync+os.replace) via
    # --comment — no create-then-comment window that could strand an UNMARKED item (filer dedupe risk).
    args = ["create", "--title", title, "--stage", stage, "--status", status]
    if body:
        args += ["--comment", body]
    r = _trk(tracker, *args)
    if r.returncode != 0:
        raise TransitionError(f"create failed: {r.stderr.strip()[:160]}")
    num = r.stdout.strip()
    # Read back the FINAL state — Stage+Status match the target AND (if any) the marker durably landed.
    state = idc_tracker_fs.load(tracker)
    it = next((i for i in state.get("issues", []) if str(i.get("number")) == str(num)), None)
    if it is None:
        raise TransitionError(f"read-back: created #{num} not found after write")
    verify_readback(num, stage, status, it.get("stage") or "", it.get("status") or "")
    if body and body not in (it.get("comments") or []):
        raise TransitionError(f"read-back: created #{num} is missing its marker comment (strand risk)")
    return num


def _fs_set_status(machine, tracker, num, status):
    check_status_legal(machine, status)
    r = _trk(tracker, "move", "--num", str(num), "--status", status)
    if r.returncode != 0:
        raise TransitionError(f"status write failed for #{num}: {r.stderr.strip()[:160]}")
    obs = fs_get_item(tracker, num)
    verify_readback(num, None, status, obs["stage"], obs["status"])   # Stage untouched; verify Status landed


def _fs_set_field(tracker, num, field, value):
    """Set a NON-machine single-select field (`Wave`/`Phase`/`Domain`) on the filesystem tracker via its `set`
    op, then POSITIVELY READ THE VALUE BACK and confirm it landed — the fs analogue of _gh_set_field
    (read-back parity). (Field-name / Status validation happens in the dispatcher BEFORE this.)"""
    r = _trk(tracker, "set", "--num", str(num), "--field", field, "--value", value)
    if r.returncode != 0:
        raise TransitionError(f"set-field {field}={value!r} on #{num} failed: {r.stderr.strip()[:160]}")
    rb = _trk(tracker, "show", "--num", str(num), "--field", field)
    if rb.returncode != 0:
        raise TransitionError(f"set-field read-back of #{num} {field} failed: {rb.stderr.strip()[:160]}")
    got = rb.stdout.strip()
    if got != value:
        raise TransitionError(
            f"set-field read-back divergence: #{num} {field} is {got!r} after the write, "
            f"expected {value!r} — refusing to report a write that did not land")


def _fs_comment(tracker, num, body):
    r = _trk(tracker, "comment", "--num", str(num), "--body", body)
    if r.returncode != 0:
        raise TransitionError(f"comment on #{num} failed: {r.stderr.strip()[:160]}")


def _fs_link(tracker, parent, child, kind):
    r = _trk(tracker, "link", "--parent", str(parent), "--child", str(child), "--kind", kind)
    if r.returncode != 0:
        raise TransitionError(f"link #{parent}->#{child} ({kind}) failed: {r.stderr.strip()[:160]}")


def _fs_remove_dep(tracker, child, parent):
    """Remove the `parent blocks child` dependency and VERIFY it is absent (the `unblock --by` first
    step). Raises on a failed removal or a still-present edge so the caller leaves Status Blocked."""
    r = _trk(tracker, "unlink", "--parent", str(parent), "--child", str(child), "--kind", "blocks")
    if r.returncode != 0:
        raise TransitionError(
            f"unblock: could not remove the #{parent} blocks #{child} dependency: {r.stderr.strip()[:160]}")
    it = _fs_item_full(tracker, child)
    if int(parent) in [int(b) for b in (it.get("blocked_by") or [])]:
        raise TransitionError(
            f"unblock: #{parent} still blocks #{child} after removal — refusing to unblock (Status stays Blocked)")


# ── github backend ─────────────────────────────────────────────────────────────────────────────
def _gh_create(machine, op, owner, project, repo, spec, title, body, stage_over, status_over,
               labels=None, issue_type=None):
    target = spec.get("target") or {}
    stage = stage_over or target.get("stage") or ""
    status = status_over or target.get("status") or ""
    validate_target(machine, op, stage, status)  # SAME gate as fs — github stage/terminal/worked checks too
    # create_item is the ATOMIC github primitive: it sets Stage AND Status together and DISCARDS a
    # partial (Stage-without-Status) create, returning the PROJECT-ITEM id only once both landed. That
    # atomic-verified return IS the create read-back for github — no extra whole-board fetch (which
    # would burn GraphQL budget and defeat the item-id cache).  Referenced by attribute so the
    # verdict-filer unit test's monkeypatch of idc_gh_board.create_item still intercepts it.
    # labels/type are passed ONLY when present, so a create with neither still calls create_item with
    # its original 7-positional signature (unchanged for every existing caller/test double).
    extra = {}
    if labels:
        extra["labels"] = labels
    if issue_type:
        extra["issue_type"] = issue_type
    return idc_gh_board.create_item(owner, project, repo, title, body, stage, status, **extra)


def _discard_created(ctx, item_id, issue_num):
    """Tear down a just-created github item that failed its post-return read-back (round-5 Fix 5) —
    delete the board item + close the backing issue via the SAME sanctioned discard create_item uses,
    so create is atomic on a mismatch too. Best-effort: a discard failure is reported (never masks the
    original divergence), and a throttle mid-discard is swallowed (the pause/resume path re-runs)."""
    try:
        incomplete = idc_gh_board.discard_partial_item(ctx["owner"], ctx["project"], ctx["repo"],
                                                       item_id, issue_num)
        if incomplete:
            sys.stderr.write(f"idc-transition: create read-back discard INCOMPLETE: {incomplete}\n")
    except idc_gh_board.BoardReadError as e:
        sys.stderr.write(f"idc-transition: create read-back discard failed (item may survive): {e}\n")


def _gh_item_id(ctx, num):
    """The project-item node id for issue `num`, from the shared item-id cache (GraphQL-budget: a
    cache hit costs ZERO board reads). Only on a cache MISS does it fall back to a single whole-board
    resolve — the pagination the cache exists to avoid, so that path is the exception, not the norm."""
    iid = (ctx.get("itemid_cache") or {}).get(int(num))
    if iid:
        return iid
    return GC._resolve_item_id(ctx["owner"], ctx["project"], int(num), ctx["repo"])


def _gh_get_item(ctx, num):
    """One item's current {stage, status} via a single node(id:) read (fetch_item) — the github
    analogue of fs_get_item. Item id from the cache; no pagination."""
    it = idc_gh_board.fetch_item(_gh_item_id(ctx, num), ctx["repo"])
    return {"stage": it.get("stage") or "", "status": it.get("status") or ""}


def _gh_set_status(ctx, machine, num, status):
    """Set Status on github, then READ BACK and verify it landed (extends fs read-back to github)."""
    check_status_legal(machine, status)
    iid = _gh_item_id(ctx, num)
    idc_gh_board.set_status(ctx["owner"], ctx["project"], ctx["repo"], iid, status)
    obs = idc_gh_board.fetch_item(iid, ctx["repo"])
    verify_readback(num, None, status, obs.get("stage") or "", obs.get("status") or "")


def _gh_close(ctx, num):
    """Drive a github item to Done via idc_gh_close.close_issue — itself ATOMIC + read-back verified
    (Status=Done + `gh issue close` + refuse success unless the issue reads back CLOSED). Item id from
    the cache. The close GUARDS (valid + passing + item-owning + pr-bound verdict) run in the
    dispatcher BEFORE this, so no unguarded terminal write exists on github."""
    GC.close_issue(ctx["owner"], ctx["project"], int(num), ctx["repo"], item_id=_gh_item_id(ctx, num))


def _gh_link(ctx, parent, child, kind):
    """Record a `parent blocks child` dependency on github durably, through BOTH representations of a
    blocks edge: (1) the NATIVE GitHub issue-dependencies `blocked_by` relation — the ONLY one the
    autorun drain's dependency gate reads — created + verified-present FIRST (fail-closed on a
    still-absent edge so the caller never believes a block landed when it didn't); (2) the engine's
    parseable comment marker on the CHILD (read by the dispose guards / recirculator). Every REST call
    runs through idc_gh_board (the engine subprocess), never the Bash tool — so no role-facing recipe
    runs a raw `blocked_by` POST and the interlock's deny of that raw command never bricks Plan. A
    non-blocks kind (`sub`) records only the marker (grouping, no dependency edge)."""
    if kind == "blocks":
        idc_gh_board.add_blocked_by(int(child), int(parent), ctx["repo"])
        if int(parent) not in idc_gh_board.blocked_by_numbers(int(child), ctx["repo"]):
            raise TransitionError(
                f"link: native blocked-by edge #{parent}->#{child} did not land after the POST "
                "— refusing to record a block that the drain would not see")
    marker = json.dumps({"child": int(child), "parent": int(parent), "kind": kind}, ensure_ascii=False)
    idc_gh_board.add_comment(int(child), f"Blocked-by: #{int(parent)} ({kind})\n"
                             f"<!-- idc-blocked-by: {marker} -->", ctx["repo"])


def _gh_set_field(ctx, num, field, value):
    """Set a NON-machine single-select field (`Wave`/`Phase`/`Domain`) on github, then POSITIVELY
    READ THE VALUE BACK and confirm it landed — the sanctioned `set-field` write primitive (replaces the
    raw `gh project item-edit` recipe the interlock now denies), with the same read-back parity as
    `move`. (Field-name / Status validation happens in the backend-agnostic dispatcher BEFORE this.) The
    option value is validated board-side by set_single_select (an option not defined for the field
    raises). A read-back that cannot be read (BoardReadError) propagates → resumable, never a blind
    success; a read-back that does not equal the request is a hard divergence."""
    iid = _gh_item_id(ctx, num)
    idc_gh_board.set_single_select(ctx["owner"], ctx["project"], ctx["repo"], iid, field, value)
    obs = idc_gh_board.fetch_item(iid, ctx["repo"])
    got = obs.get(field.lower())
    if got != value:
        raise TransitionError(
            f"set-field read-back divergence: #{num} {field} is {got!r} after the write, "
            f"expected {value!r} — refusing to report a write that did not land")


def _gh_remove_dep(ctx, child, parent):
    """Remove the `parent blocks child` dependency and VERIFY it is absent (the `unblock --by` first
    step). Removes the NATIVE GitHub blocked_by edge first (the representation the drain reads), then
    verifies via a native read-back, then best-effort cleans the engine's marker comment. Raises on a
    still-present native edge so the caller leaves Status Blocked. Every REST call runs through
    idc_gh_board (the engine subprocess), never the Bash tool — the interlock never sees a raw
    dependency DELETE.

    IDEMPOTENT rerun (Fix 5): checks ABSENCE FIRST — if the edge is already gone (a rerun after "edge
    removed but the Status write failed"), it SKIPS the DELETE (which GitHub may 404) and proceeds, so
    the rerun deterministically completes the remaining Blocked->Todo Status move. Only a still-present
    edge is DELETEd; a still-present edge after the DELETE still raises (Status stays Blocked)."""
    if int(parent) in idc_gh_board.blocked_by_numbers(int(child), ctx["repo"]):
        idc_gh_board.remove_blocked_by(int(child), int(parent), ctx["repo"])
    if int(parent) in idc_gh_board.blocked_by_numbers(int(child), ctx["repo"]):
        raise TransitionError(
            f"unblock: #{parent} still blocks #{child} after removal — refusing to unblock (Status stays Blocked)")
    # Best-effort marker cleanup (the native edge is authoritative for the drain; a leftover marker is
    # harmless but tidy to remove). A cleanup failure never fails the unblock.
    try:
        for cid in idc_gh_board.blocked_by_comment_ids(int(child), int(parent), ctx["repo"]):
            idc_gh_board.delete_comment(cid, ctx["repo"])
    except (idc_gh_board.BoardReadError, idc_gh_board.RateLimitError) as e:
        sys.stderr.write(f"idc-transition: unblock marker-comment cleanup skipped (non-fatal): {e}\n")


# ── backend-agnostic dispatch (the guard path is SHARED; only the read/write primitives differ) ──
def get_item(ctx, num):
    if ctx["backend"] == "github":
        return _gh_get_item(ctx, num)
    return fs_get_item(ctx["tracker"], num)


def set_status(ctx, machine, num, status):
    if ctx["backend"] == "github":
        _gh_set_status(ctx, machine, num, status)
    else:
        _fs_set_status(machine, ctx["tracker"], num, status)


# The NON-machine single-select fields set-field owns. Stage AND Status are MACHINE-governed
# (the machine table enforces the legal Stage/Status pairing + terminal/worked invariants), so
# set-field must NEVER write them — a raw Stage write reads neither the item's current Status nor
# those invariants and can mint the machine-illegal pair the shared guard forbids (Fix 2). Both are
# routed to `move`, the transition door that enforces the invariants and journals to_stage/to_status.
SETTABLE_FIELDS = ("Wave", "Phase", "Domain")
MACHINE_FIELDS = ("Stage", "Status")


def set_field(ctx, num, field, value):
    """Set a NON-machine single-select field (Wave/Phase/Domain) — the `set-field` op, both backends.
    VALIDATES the field name BEFORE any write, then writes and positively reads the value back.

    Stage and Status are MACHINE-governed and REFUSED (a Stage/Status change is a transition — use
    `move`, which enforces the machine invariants and journals to_stage/to_status); an unknown field
    is refused before touching the board. set-field's journal record therefore never carries a
    to_stage/to_status, so replay/reconciliation never sees a field-only write as a transition."""
    if field in MACHINE_FIELDS:
        raise TransitionError(
            f"set-field: {field} is a machine-governed field — a {field} change is a transition. Use "
            f"`move` (it enforces the legal Stage/Status pairing and journals it), not set-field.")
    if field not in SETTABLE_FIELDS:
        raise TransitionError(
            f"set-field: {field!r} is not a settable single-select field "
            f"(expected one of {list(SETTABLE_FIELDS)}) — refusing before any write")
    if ctx["backend"] == "github":
        _gh_set_field(ctx, num, field, value)
    else:
        _fs_set_field(ctx["tracker"], num, field, value)


def record_owner(ctx, num, agent):
    if ctx["backend"] == "github":
        idc_gh_board.add_comment(int(num), f"claimed by {agent}", ctx["repo"])
    else:
        _fs_comment(ctx["tracker"], num, f"claimed by {agent}")


def do_link(ctx, parent, child, kind):
    if ctx["backend"] == "github":
        _gh_link(ctx, parent, child, kind)
    else:
        _fs_link(ctx["tracker"], parent, child, kind)


def remove_dependency(ctx, child, parent):
    """Remove the `parent blocks child` dependency and verify it is absent (the `unblock --by` first
    step, both backends). Raises TransitionError if the edge cannot be removed / still present."""
    if ctx["backend"] == "github":
        _gh_remove_dep(ctx, child, parent)
    else:
        _fs_remove_dep(ctx["tracker"], child, parent)


def close_terminal(ctx, machine, num, to_status):
    if ctx["backend"] == "github":
        _gh_close(ctx, num)
    else:
        _fs_set_status(machine, ctx["tracker"], num, to_status)


# ── the op dispatcher ──────────────────────────────────────────────────────────────────────────
def run(op, ctx, **kw):
    """Execute one typed op end-to-end (validate → mutate → read-back → normalize → journal).
    `ctx` = {backend, repo, tracker, owner, project, machine}. Returns the created item id/number for
    create ops, else None. Raises TransitionError (illegal transition / guard denial / read-back
    divergence) or RateLimitError (github throttle, resumable)."""
    machine = ctx["machine"]
    spec = op_spec(machine, op)
    kind = spec.get("kind")
    backend = ctx["backend"]
    tracker_rel = os.path.relpath(ctx["tracker"], ctx["repo"]) if ctx.get("tracker") else None


    result = None
    if kind == "create":
        target = spec.get("target") or {}
        to_stage = kw.get("stage") or target.get("stage") or ""
        to_status = kw.get("status") or target.get("status") or ""
        if backend == "github":
            # The door RETURNS the integer ISSUE NUMBER (the adapter contract), not the PVTI
            # project-item id. create_item mints the item (applying labels/type) and returns the PVTI;
            # we resolve number → journal (keeping the PVTI internally) → return the number. A board
            # error while resolving propagates (resumable exit 3); a genuinely absent number refuses.
            item_id = _gh_create(machine, op, ctx["owner"], ctx["project"], ctx["repo"], spec,
                                 kw["title"], kw.get("body", ""), kw.get("stage"), kw.get("status"),
                                 labels=kw.get("labels"), issue_type=kw.get("type"))
            item = idc_gh_board.fetch_item(item_id, ctx["repo"])
            content_num = (item.get("content") or {}).get("number")
            issue_num = _journal_item(content_num)
            if issue_num is None:
                # ATOMIC on failure (round-5 Fix 5): a create whose number cannot be resolved is a
                # partial item — delete the board item + close the backing issue before raising, so no
                # orphan survives. content_num (may be None) is the best issue handle we have to close.
                _discard_created(ctx, item_id, content_num)
                raise TransitionError(
                    f"create: could not resolve the issue number for new item {item_id} "
                    "— refusing to return a non-issue id (the door's contract is the issue number)")
            # POSITIVE Stage/Status read-back (Fix 3): confirm the created item actually carries the
            # REQUESTED Stage AND Status — the same read-back parity every other op has. A no-op field
            # setter (or a partial create the discard missed) must never be journaled as a successful
            # create. fetch_item already surfaced these fields; comparing them here is the whole read-back.
            obs_stage, obs_status = item.get("stage"), item.get("status")
            if obs_stage != to_stage or obs_status != to_status:
                # ATOMIC on a post-return readback mismatch (round-5 Fix 5): the create_item discard
                # only covers failures INSIDE create_item; a mismatch surfaced AFTER it returned used
                # to raise leaving the malformed item alive. Delete the board item + close the issue
                # through the SAME sanctioned cleanup before raising, so create stays atomic.
                _discard_created(ctx, item_id, issue_num)
                raise TransitionError(
                    f"create read-back divergence: new item #{issue_num} is "
                    f"Stage={obs_stage!r}/Status={obs_status!r}, expected {to_stage!r}/{to_status!r} "
                    "— refusing to journal a create whose fields did not land (item discarded)")
            journal_append(ctx["repo"], op, backend, tracker_rel,
                           dict(kw, num=issue_num, to_stage=to_stage, to_status=to_status,
                                project_item_id=item_id))
            return issue_num
        result = _fs_create(machine, op, ctx["tracker"], spec, kw["title"], kw.get("body", ""),
                            kw.get("stage"), kw.get("status"))
        journal_append(ctx["repo"], op, backend, tracker_rel,
                       dict(kw, num=result, to_stage=to_stage, to_status=to_status))
        return result

    elif kind == "transition":
        num = kw["num"]
        to_status = spec.get("to_status")
        if to_status == "any":
            to_status = kw.get("to_status")
            if not to_status:
                raise TransitionError(f"{op}: --to-status is required")
        cur = get_item(ctx, num)
        is_unblock_by = (op == "unblock" and kw.get("by") is not None)
        # `unblock --by GATE`: ALWAYS remove-and-verify the `GATE blocks #num` dependency FIRST
        # (idempotent — already-absent is treated as done), regardless of the pointer's current Status,
        # and BEFORE the idempotent-Status short-circuit below — so a pointer that is already Todo but
        # still carries a STALE blocked_by edge still gets the edge removed (the Fix-5 gap: the old
        # dispatcher early-returned on Status==Todo before ever removing the dependency). A terminal
        # (Done) item is never unblockable, so guard that before the removal. If removal (or its verify)
        # fails, it raises BEFORE any Status write (the pointer stays Blocked); a rerun re-removes
        # (no-op) and completes the remaining Blocked->Todo move.
        if is_unblock_by:
            if cur["status"] == machine.get("terminal_status"):
                raise TransitionError(
                    f"illegal transition: #{num} is {cur['status']!r} (terminal) — {op} cannot resurrect it")
            remove_dependency(ctx, num, kw["by"])
        if cur["status"] == to_status:
            # Idempotent Status: a plain transition already at target is a silent no-op. For unblock --by
            # the guarded dependency removal above DID run, so journal the real operation (unblocked_by).
            if is_unblock_by:
                journal_append(ctx["repo"], op, backend, tracker_rel,
                               dict(kw, to_status=to_status), cur=cur)
            return
        if cur["status"] == machine.get("terminal_status"):
            raise TransitionError(
                f"illegal transition: #{num} is {cur['status']!r} (terminal) — {op} cannot resurrect it")
        allowed_from = spec.get("from_status")
        if allowed_from and cur["status"] not in allowed_from:
            raise TransitionError(
                f"illegal transition: {op} requires source Status in {allowed_from}, "
                f"but #{num} is {cur['status']!r}")
        refuse_terminal(machine, op, to_status)
        check_worked_state(machine, op, cur["stage"], to_status)
        set_status(ctx, machine, num, to_status)
        if spec.get("records_agent") and kw.get("agent"):
            record_owner(ctx, num, kw["agent"])
        journal_append(ctx["repo"], op, backend, tracker_rel, dict(kw, to_status=to_status), cur=cur)

    elif kind == "terminal":
        num = kw["num"]
        guards, disposition = resolve_terminal_guards(spec, kw)
        # THE terminal invariant: a terminal op that resolves to NO guards (a `dispose` with a
        # missing/unknown disposition, or a hand-authored `guards: []` op) is fail-closed — refused
        # BEFORE any board read, so no verdict-free write ever lands.
        if not guards:
            raise TransitionError(
                f"{op}: refused — a verdict-free terminal op cannot reach the terminal Status "
                "(only a guarded `close`, or a `dispose` with a valid --disposition, may reach Done).")
        cur = get_item(ctx, num)
        evidence = {}   # a close records none; each disposition guard returns what it verified
        if disposition is None:
            check_close_guards(spec, num, kw.get("verdict"), kw.get("pr"))
        else:
            evidence = run_disposition_guards(ctx, num, kw, guards, disposition)
        # Pre-close re-proof (codex rounds 8/9, generalized in round 11): the guards READ board
        # state and close_terminal WRITES Done, with no compare-and-set on either backend (the
        # github merge-lease gap is #104) — so in the narrowest window before the irreversible
        # write:
        #   (1) the item's own Stage/Status must still be the guard-time snapshot — any drift (a
        #       mid-flight park, a concurrent claim) refuses. This is the only board re-proof a
        #       verdict `close` needs: its guard reads the on-disk verdict, not board evidence.
        #   (2) a dispose RE-RUNS its disposition guards in full — they are read-only and
        #       idempotent — so EVERY mutable guard input (labels, markers, the retirement child's
        #       Stage, the journal) is re-proved, not the hand-picked stage/label subset rounds 8/9
        #       rechecked (which missed e.g. a retirement child restaged out of Buildable
        #       mid-disposition — round-11 P1). The re-run's evidence is what was true AT the
        #       close, so it is what the terminal journal records. Terminal ops are rare; the
        #       second read pass is the price of the missing compare-and-set.
        # Residual: the re-proof→write gap itself — #104's compare-and-set class, not closable here.
        recheck = get_item(ctx, num)
        if (recheck.get("stage"), recheck.get("status")) != (cur.get("stage"), cur.get("status")):
            raise TransitionError(
                f"{op} denied: #{num} moved during the disposition — the guards validated "
                f"{cur.get('stage')!r}/{cur.get('status')!r} but the item is now "
                f"{recheck.get('stage')!r}/{recheck.get('status')!r}; re-run against the current state")
        if disposition is not None:
            evidence = run_disposition_guards(ctx, num, kw, guards, disposition)
            kw = dict(kw, disposition_evidence=evidence)   # journal the evidence, not just caller args
        close_terminal(ctx, machine, num, spec.get("to_status"))
        # Journal the FINAL Stage ONLY when a disposition guard actually VALIDATED the item's Stage —
        # it returns that Stage in its evidence (retired: the Consideration/Planning pointer; drained:
        # the Recirculation ticket). A `close` and a `gate-approved` disposition do NOT validate Stage,
        # so they record NONE (the create-time Stage expectation stands) — otherwise an out-of-band
        # Stage drift its guards never checked would be laundered into a clean reconciliation. An
        # empty/unset validated Stage (legacy github) is omitted (→ None) so replay's absent-field None
        # matches instead of a false "" ≠ None divergence.
        term_stage = evidence.get("stage") or None
        journal_append(ctx["repo"], op, backend, tracker_rel,
                       dict(kw, to_status=spec.get("to_status"), to_stage=term_stage), cur=cur)

    elif kind == "field":
        num = kw["num"]
        field = kw["field"]
        value = kw["value"]
        # A non-machine single-select field write (Wave/Phase/Domain) through the sanctioned door,
        # so no role runs a raw `gh project item-edit` (now denied by the interlock during a command).
        set_field(ctx, num, field, value)
        journal_append(ctx["repo"], op, backend, tracker_rel, kw)

    elif kind == "link":
        do_link(ctx, kw["parent"], kw["child"], kw.get("kind", "blocks"))
        journal_append(ctx["repo"], op, backend, tracker_rel, kw)

    else:
        raise TransitionError(f"machine table declares unknown kind {kind!r} for op {op!r}")

    return result


# ── importable convenience API (used by idc_file_findings.py — the re-pointed filer) ─────────────
def recirculate_intake(ctx, title, body):
    """create-ticket variant for the Recirculation inbox — the filer's create door. Returns the new
    item id (github) / number (filesystem)."""
    return run("recirculate-intake", ctx, title=title, body=body)


def link_blocks(ctx, parent, child):
    """A blocks edge: `parent` blocks `child` (child.blocked_by += parent)."""
    return run("link", ctx, parent=parent, child=child, kind="blocks")


def fs_ctx(repo, tracker, machine=None):
    if machine is None:
        machine = load_machine(machine_path_for(repo))
    return {"backend": "filesystem", "repo": repo, "tracker": tracker,
            "owner": None, "project": None, "machine": machine}


def load_itemid_cache(path=None):
    """The issue# -> project-item-id map (`NUM<TAB>item_id` lines) the tracker recipe maintains in
    $IDC_ITEMID_CACHE (idc_gh_board.idmap_lines). Loaded ONCE per ctx so every github op resolves an
    item id with zero board reads — the GraphQL-budget contract (no per-op re-pagination). Absent /
    unreadable cache → empty map (each op then falls back to a single resolve; see _gh_item_id)."""
    cache = {}
    path = path if path is not None else os.environ.get("IDC_ITEMID_CACHE")
    if path and os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 2 and parts[0].isdigit() and parts[1]:
                        cache[int(parts[0])] = parts[1]
        except OSError:
            pass
    return cache


def github_ctx(repo, owner, project, machine=None, itemid_cache=None):
    if machine is None:
        machine = load_machine(machine_path_for(repo))
    if itemid_cache is None:
        itemid_cache = load_itemid_cache()
    return {"backend": "github", "repo": repo, "tracker": None,
            "owner": owner, "project": project, "machine": machine, "itemid_cache": itemid_cache}


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────────
def build_parser():
    p = argparse.ArgumentParser(description="The single sanctioned write door to IDC tracker state.")
    p.add_argument("--repo", default=".", help="the governed repo root")
    p.add_argument("--backend", choices=["filesystem", "github"], default=None,
                   help="override the backend (default: read from tracker-config.yaml, else filesystem)")
    p.add_argument("--tracker", default=None, help="TRACKER.md path (filesystem; default <repo>/TRACKER.md)")
    p.add_argument("--machine", default=None, help="workflow-machine.yaml path (default: scaffolded, else bundled)")
    p.add_argument("--owner", default=None, help="github project owner (github backend)")
    p.add_argument("--project", default=None, help="github project number (github backend)")
    sub = p.add_subparsers(dest="op", required=True)

    for name in ("create-ticket", "create-pointer", "recirculate-intake"):
        c = sub.add_parser(name)
        c.add_argument("--title", required=True)
        c.add_argument("--body", default="")
        c.add_argument("--stage", default=None, help="override the machine default target Stage")
        c.add_argument("--status", default=None, help="override the machine default target Status")
        c.add_argument("--type", default=None, dest="type",
                       help="issue type — applied as a `type:<T>` label (adapter's `type` input)")
        c.add_argument("--labels", action="append", default=None,
                       help="label(s) to apply to the created issue (repeatable or a comma-list, "
                            "e.g. --labels operator-action)")

    cl = sub.add_parser("claim")
    cl.add_argument("--num", type=int, required=True)
    cl.add_argument("--agent", default="")

    mv = sub.add_parser("move")
    mv.add_argument("--num", type=int, required=True)
    mv.add_argument("--to-status", dest="to_status", required=True)

    # `set-field` — the sanctioned NON-machine single-select field write (Wave/Phase/Domain). Stage/
    # Status change is a transition — use `move`; set-field refuses Status.
    sf = sub.add_parser("set-field")
    sf.add_argument("--num", type=int, required=True)
    sf.add_argument("--field", required=True, help="Wave | Phase | Domain (NOT Stage/Status — use move)")
    sf.add_argument("--value", required=True)

    ub = sub.add_parser("unblock")
    ub.add_argument("--num", type=int, required=True)
    ub.add_argument("--by", type=int, default=None,
                    help="the GATE whose `GATE blocks <num>` dependency to remove before unblocking "
                         "(removed + verified absent FIRST, then Status Blocked -> Todo)")

    cls = sub.add_parser("close")
    cls.add_argument("--num", type=int, required=True)
    cls.add_argument("--verdict", default=None, help="path to the review verdict JSON (close guard)")
    cls.add_argument("--pr", type=int, default=None, help="the PR the verdict must be for")

    # `dispose` is the guarded NON-verdict terminal door (#150): --disposition names one of the
    # machine table's dispositions (gate-approved | retired | drained); the engine — not argparse — is
    # the source of truth, so an unknown value is refused with the fail-closed terminal message.
    dp = sub.add_parser("dispose")
    dp.add_argument("--num", type=int, required=True)
    dp.add_argument("--disposition", default=None,
                    help="the non-verdict terminal disposition: gate-approved | retired | drained")
    dp.add_argument("--gate-pr", dest="gate_pr", type=int, default=None,
                    help="gate-approved (github): the merged Think/decision PR that approves the gate")
    dp.add_argument("--child", type=int, default=None,
                    help="retired: a decomposition child that references the pointer being retired")

    lk = sub.add_parser("link")
    lk.add_argument("--parent", type=int, required=True)
    lk.add_argument("--child", type=int, required=True)
    lk.add_argument("--kind", default="blocks")
    return p


def resolve_backend(args):
    if args.backend:
        return args.backend
    try:
        import idc_recirc_sweep as SW
        return SW.read_backend(os.path.abspath(args.repo)) or "filesystem"
    except Exception:
        return "filesystem"


def main():
    args = build_parser().parse_args()
    repo = os.path.abspath(args.repo)
    machine = load_machine(machine_path_for(repo, args.machine))
    backend = resolve_backend(args)
    tracker = args.tracker or os.path.join(repo, "TRACKER.md")
    if backend == "github":
        ctx = github_ctx(repo, args.owner, args.project, machine)
    else:
        ctx = fs_ctx(repo, tracker, machine)

    kw = {}
    op = args.op
    if op in ("create-ticket", "create-pointer", "recirculate-intake"):
        kw = {"title": args.title, "body": args.body, "stage": args.stage, "status": args.status,
              "type": args.type, "labels": args.labels}
    elif op == "claim":
        kw = {"num": args.num, "agent": args.agent}
    elif op == "move":
        kw = {"num": args.num, "to_status": args.to_status}
    elif op == "set-field":
        kw = {"num": args.num, "field": args.field, "value": args.value}
    elif op == "unblock":
        kw = {"num": args.num, "to_status": "Todo", "by": args.by}
    elif op == "close":
        kw = {"num": args.num, "verdict": args.verdict, "pr": args.pr}
    elif op == "dispose":
        kw = {"num": args.num, "disposition": args.disposition,
              "gate_pr": args.gate_pr, "child": args.child}
    elif op == "link":
        kw = {"parent": args.parent, "child": args.child, "kind": args.kind}

    # `claim`/`unblock` are transitions whose to_status is fixed by the machine spec, not the CLI.
    try:
        result = run(op, ctx, **kw)
    except idc_gh_board.RateLimitError as e:
        idc_gh_board.emit_rate_limit_verdict(e)  # exit 3 (resumable), pinned verdict
    except (idc_gh_board.BoardReadError, GC.CloseError) as e:
        # A github board read/write/close-verify failure on the now-wired github path (BoardReadError
        # covers BoardWriteError too). Fail-closed and RESUMABLE — never a Python traceback / exit 1,
        # which would break the drain's 0-applied / 2-denied / 3-resumable exit-code contract.
        sys.stderr.write(f"idc-transition: github board error: {e}\n")
        sys.exit(3)
    except TransitionError as e:
        sys.stderr.write(f"idc-transition: {e}\n")
        sys.exit(2)
    if result is not None:
        print(result)
    sys.exit(0)


if __name__ == "__main__":
    main()
