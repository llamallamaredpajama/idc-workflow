#!/usr/bin/env python3
"""idc_transition.py — THE single sanctioned write door to IDC tracker state (v4 Phase 2, plan §3.1).

Every mutation of board state routes through this engine. It wraps BOTH existing backends —
`idc_gh_board.py` (github Projects v2) and `idc_tracker_fs.py` (the filesystem TRACKER.md) — behind
a fixed set of TYPED ops:

    create-ticket | create-pointer | claim | move | close | retire | recirculate-intake | link | unblock

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

THE terminal invariant: the ONLY path to a terminal Status (Done) is a guarded terminal `close`
whose verdict is VALID, PASSING (PASS/PASS-WITH-NITS), and OWNS the item (verdict.issue == the item
being closed, verdict.pr == the mandatory --pr). Every OTHER op — create, move, claim, unblock,
recirculate-intake, retire — is refused from minting a terminal Status. Everything else that touches
Status/Stage is bounded by the machine table's declared domains (a single `validate_target` gate).

Guards (close): a `close` requires a validated, passing, item-owning review verdict for the linked PR
(idc_review_verdict_check passes) AND every merge_conditions[] entry in that verdict marked met.
Guards read artifacts on disk, not prose claims.

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
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_review_verdict_check as VC  # noqa: E402 — the verdict validator (close guard)
import idc_tracker_fs                  # noqa: E402 — filesystem backend (read-back seam)
import idc_gh_board                    # noqa: E402 — github backend (referenced by attribute so tests monkeypatch)

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLED_MACHINE = os.path.join(HERE, "..", "templates", "workflow-machine.yaml")
TRK = os.path.join(HERE, "idc_tracker_fs.py")
JOURNAL_REL = os.path.join("docs", "workflow", "transition-journal.ndjson")


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
    def parse_scalar(s):
        s = s.strip()
        if s.startswith("[") and s.endswith("]"):
            inner = s[1:-1].strip()
            return [p.strip() for p in inner.split(",")] if inner else []
        if s.startswith("{") and s.endswith("}"):
            inner = s[1:-1].strip()
            out = {}
            if inner:
                for pair in inner.split(","):
                    k, _, v = pair.partition(":")
                    out[k.strip()] = parse_scalar(v)
            return out
        return s

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
        return  # a terminal op with no verdict guard (none ship in this stage — retire is fail-closed)
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


# ── journal stub (Phase 4 builds the real thing) ─────────────────────────────────────────────────
def journal_append(repo, op, fields):
    """Append ONE minimal line per op. Best-effort — a journal failure never fails the op (the full
    event-sourced journal + rotation + reconciliation is Phase 4). A real timestamp is fine here
    (an ordinary python script, not a workflow harness)."""
    try:
        path = os.path.join(repo, JOURNAL_REL)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        args_hash = hashlib.sha1(
            json.dumps(fields, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()[:12]
        line = json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "op": op, "args_hash": args_hash, "stub": True,
        }, ensure_ascii=False)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


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


def _fs_comment(tracker, num, body):
    r = _trk(tracker, "comment", "--num", str(num), "--body", body)
    if r.returncode != 0:
        raise TransitionError(f"comment on #{num} failed: {r.stderr.strip()[:160]}")


def _fs_link(tracker, parent, child, kind):
    r = _trk(tracker, "link", "--parent", str(parent), "--child", str(child), "--kind", kind)
    if r.returncode != 0:
        raise TransitionError(f"link #{parent}->#{child} ({kind}) failed: {r.stderr.strip()[:160]}")


# ── github backend ─────────────────────────────────────────────────────────────────────────────
def _gh_create(machine, op, owner, project, repo, spec, title, body, stage_over, status_over):
    target = spec.get("target") or {}
    stage = stage_over or target.get("stage") or ""
    status = status_over or target.get("status") or ""
    validate_target(machine, op, stage, status)  # SAME gate as fs — github stage/terminal/worked checks too
    # create_item is the ATOMIC github primitive: it sets Stage AND Status together and DISCARDS a
    # partial (Stage-without-Status) create, returning the item id only once both landed. That
    # atomic-verified return IS the create read-back for github — no extra whole-board fetch (which
    # would burn GraphQL budget and defeat the item-id cache).  Referenced by attribute so the
    # verdict-filer unit test's monkeypatch of idc_gh_board.create_item still intercepts it.
    return idc_gh_board.create_item(owner, project, repo, title, body, stage, status)


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

    result = None
    if kind == "create":
        if backend == "github":
            result = _gh_create(machine, op, ctx["owner"], ctx["project"], ctx["repo"], spec,
                                 kw["title"], kw.get("body", ""), kw.get("stage"), kw.get("status"))
        else:
            result = _fs_create(machine, op, ctx["tracker"], spec, kw["title"], kw.get("body", ""),
                                kw.get("stage"), kw.get("status"))

    elif kind == "transition":
        num = kw["num"]
        to_status = spec.get("to_status")
        if to_status == "any":
            to_status = kw.get("to_status")
            if not to_status:
                raise TransitionError(f"{op}: --to-status is required")
        if backend == "github":
            raise TransitionError(f"{op}: github transition ops are not wired in this stage "
                                  "(filesystem-proven first; github move/claim land with the interlocks)")
        cur = fs_get_item(ctx["tracker"], num)
        # Done is terminal — no transition resurrects it (kills the unblock/move-out-of-Done class).
        if cur["status"] == machine.get("terminal_status"):
            raise TransitionError(
                f"illegal transition: #{num} is {cur['status']!r} (terminal) — {op} cannot resurrect it")
        # Op-specific source-Status constraint (e.g. unblock only lifts a Blocked item).
        allowed_from = spec.get("from_status")
        if allowed_from and cur["status"] not in allowed_from:
            raise TransitionError(
                f"illegal transition: {op} requires source Status in {allowed_from}, "
                f"but #{num} is {cur['status']!r}")
        # No transition may MINT the terminal Status (only a guarded close reaches Done) nor drive a
        # non-build item into the worked Status — both checked ENGINE-wide, same as the create gate.
        refuse_terminal(machine, op, to_status)
        check_worked_state(machine, op, cur["stage"], to_status)
        _fs_set_status(machine, ctx["tracker"], num, to_status)
        if spec.get("records_agent") and kw.get("agent"):  # ownership recording is DATA-driven, not op==claim
            _fs_comment(ctx["tracker"], num, f"claimed by {kw['agent']}")

    elif kind == "terminal":
        num = kw["num"]
        if backend == "github":
            raise TransitionError(f"{op}: github terminal ops route through idc_gh_close in this stage")
        guards = spec.get("guards") or []
        if not guards:
            # A guard-free terminal op would be a verdict-free path to Done — forbidden. The ONLY path
            # to a terminal Status is a guarded `close` (valid, passing, item-owning verdict). `retire`
            # has no verdict, and the board has just one terminal Status (Done), so it is fail-closed
            # here. TODO(Phase 4): a distinct non-Done "closed-not-planned" disposition (board-schema
            # change) would let retire terminalize a non-build item without minting an unaccepted Done.
            raise TransitionError(
                f"{op}: refused — a verdict-free terminal op cannot reach the terminal Status "
                "(only a guarded `close` may). Awaiting a non-Done terminal disposition (Phase 4).")
        fs_get_item(ctx["tracker"], num)  # read-back existence before guarded close (fails closed if absent)
        check_close_guards(spec, num, kw.get("verdict"), kw.get("pr"))  # valid + passing + item-owning verdict
        _fs_set_status(machine, ctx["tracker"], num, spec.get("to_status"))

    elif kind == "link":
        if backend == "github":
            raise TransitionError("link: github native links are not wired in this stage")
        _fs_link(ctx["tracker"], kw["parent"], kw["child"], kw.get("kind", "blocks"))

    else:
        raise TransitionError(f"machine table declares unknown kind {kind!r} for op {op!r}")

    journal_append(ctx["repo"], op, kw)
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


def github_ctx(repo, owner, project, machine=None):
    if machine is None:
        machine = load_machine(machine_path_for(repo))
    return {"backend": "github", "repo": repo, "tracker": None,
            "owner": owner, "project": project, "machine": machine}


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

    cl = sub.add_parser("claim")
    cl.add_argument("--num", type=int, required=True)
    cl.add_argument("--agent", default="")

    mv = sub.add_parser("move")
    mv.add_argument("--num", type=int, required=True)
    mv.add_argument("--to-status", dest="to_status", required=True)

    ub = sub.add_parser("unblock")
    ub.add_argument("--num", type=int, required=True)

    for name in ("close", "retire"):
        t = sub.add_parser(name)
        t.add_argument("--num", type=int, required=True)
        t.add_argument("--verdict", default=None, help="path to the review verdict JSON (close guard)")
        t.add_argument("--pr", type=int, default=None, help="the PR the verdict must be for")

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
        kw = {"title": args.title, "body": args.body, "stage": args.stage, "status": args.status}
    elif op == "claim":
        kw = {"num": args.num, "agent": args.agent}
    elif op == "move":
        kw = {"num": args.num, "to_status": args.to_status}
    elif op == "unblock":
        kw = {"num": args.num, "to_status": "Todo"}
    elif op in ("close", "retire"):
        kw = {"num": args.num, "verdict": args.verdict, "pr": args.pr}
    elif op == "link":
        kw = {"parent": args.parent, "child": args.child, "kind": args.kind}

    # `claim`/`unblock` are transitions whose to_status is fixed by the machine spec, not the CLI.
    try:
        result = run(op, ctx, **kw)
    except idc_gh_board.RateLimitError as e:
        idc_gh_board.emit_rate_limit_verdict(e)  # exit 3 (resumable), pinned verdict
    except TransitionError as e:
        sys.stderr.write(f"idc-transition: {e}\n")
        sys.exit(2)
    if result is not None:
        print(result)
    sys.exit(0)


if __name__ == "__main__":
    main()
