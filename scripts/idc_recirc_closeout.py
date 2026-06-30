#!/usr/bin/env python3
"""Validate a recirc-consultant CLOSEOUT and emit the Build orchestrator's next action.

The "larger loop" (`WORKFLOW.md §4.3/§4.4`): when a running Build surfaces a recirc event it spawns a
fresh specialist recirc-consultant (via the runtime adapter) and then acts on the consultant's
*closeout* — a small machine-readable handoff naming exactly what to do next. The orchestrator is a
dumb router: it does NOT re-derive the gate decision, it just dispatches on the validated closeout.

This helper is the FAIL-CLOSED guarantee that a handoff can never be silently dropped (the b985c1e7
failure, where two recirc tickets were filed and abandoned). A malformed or incomplete closeout exits
2 and prints NO dispatch line, so the orchestrator halts-and-surfaces instead of stranding the ticket.

The dispatch is a STRUCTURED JSON OBJECT (one line), not a whitespace-delimited line protocol: the
parent routes on the *parsed* value, so a control character / delimiter inside a scalar is JSON-escaped
and can never spoof a token (the injection risk of a dumb router consuming `key=value key=value` tokens).

Closeout schema (JSON object on stdin or a file):
    ticket       (required, positive int) the Stage=Recirculation ticket the consultant processed
    outcome      (required) one of: pass-through | gated | trivial
    provenance   (required, non-empty) the discovered-scope provenance stamp ("originated from #N …")
    recirc_count (required, non-negative int) the issue's consultant-bumped recirc count — the
                 authoritative source for idc_recirc_caps.py (the per-issue recirc ceiling)
    cascade_depth(required, non-negative int) the recirc-originated cascade depth — the authoritative
                 source for idc_recirc_caps.py (the cascade-depth cap)
  outcome-specific:
    pass-through  consideration (required, non-empty)  -> launch a (batched) Plan worker
    gated         think_pr      (required, non-empty)  -> cmux/push ping; NO Plan; ticket parks
    trivial       grant: {issue:int(>0), paths:[repo-relative subordinate canonical-doc], change:str(non-empty)}
                                                       -> grant Build permission for that exact
                                                          canonical-doc change as a SEPARATE tiny doc
                                                          PR through staging; NO Plan, NO re-sequence.
                                                          Each path is SCOPE-CHECKED: a repo-relative
                                                          (no leading '/', no '..' segment, no trailing
                                                          '/') SUBORDINATE canonical-doc FILE under
                                                          docs/ — NOT a governing instruction surface
                                                          (docs/workflow, docs/plans, …; a root/governing
                                                          *.md) and not a source extension — a source
                                                          path, a directory, or a repo escape fails closed.

On a valid closeout, prints ONE deterministic JSON dispatch line and exits 0, e.g.:
    {"verb":"launch-plan","ticket":559,"consideration":"docs/…","recirc_count":1,"cascade_depth":0}
    {"verb":"notify-gated","ticket":561,"think_pr":"https://…","recirc_count":0,"cascade_depth":0}
    {"verb":"grant-build","ticket":562,"issue":393,"paths":["docs/specs/x.schema.json"],"change":"…","recirc_count":2,"cascade_depth":1}

Exit codes:
    0  valid closeout — the JSON dispatch line is printed to stdout (the orchestrator acts on it).
    2  fail-closed: bad args, missing/unreadable file, malformed JSON, or a schema violation —
       nothing is printed to stdout (no dispatch ⇒ the orchestrator halts, never strands).
"""
import argparse
import json
import sys

OUTCOMES = ("pass-through", "gated", "trivial")

# A trivial grant path must be a SUBORDINATE canonical-doc FILE. The `trivial` outcome grants Build
# write permission for the named paths, so an unconstrained or governing path is a fail-OPEN in a
# fail-closed gate. These are the GOVERNING instruction surfaces the trivial path must NEVER bypass
# (they are the recirc/gate-disciplined layers — editing them through the tiny doc-PR path would
# subvert the normal sync/gate flow). The basename set is case-insensitive at any depth.
GOV_BASENAMES = ("workflow.md", "agents.md", "claude.md", "readme.md", "tracker.md")
GOV_SUBDIRS = (
    "docs/workflow/", "docs/plans/", "docs/prd/", "docs/trd/",
    "docs/handoffs/", "docs/reviews/", "docs/dev/",
)
# Permitted subordinate-doc / artifact extensions. A source extension (.py/.ts/.sh/…) is rejected even
# if it somehow lives under docs/ (defense — the trivial grant is for docs, never source).
DOC_EXTS = (".md", ".json", ".schema.json")


def _die(msg):
    sys.stderr.write(f"idc_recirc_closeout: {msg}\n")
    sys.exit(2)


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def _int_min(name, v, bound):
    """Validate a required integer >= bound (bool excluded — bool is an int subclass in Python);
    _die (exit 2) otherwise. `bound` is the inclusive lower bound: 1 for a ticket/issue number,
    0 for the runaway-cap counts."""
    if isinstance(v, bool) or not isinstance(v, int) or v < bound:
        _die(f"{name} must be an integer >= {bound}, got {v!r}")
    return v


def _is_canonical_doc_path(p):
    """A trivial grant path must be a repo-relative SUBORDINATE canonical-doc FILE. The `trivial`
    outcome grants Build write permission for the named paths, so an unconstrained or governing path
    would let a "tiny doc PR" touch a gate-disciplined surface or write outside the doc layer — a
    fail-OPEN in a fail-closed gate. A path passes only when it is:

      * a single FILE — non-empty, no trailing '/' (not a bare directory), no backslash;
      * repo-relative — no leading '/' (not absolute), no `..` segment (no parent escape), and no
        embedded NUL / newline / tab / CR control characters (never a real path; injection risk);
      * a canonical doc UNDER `docs/` (the doc layer) — NOT a root file, NOT outside docs/;
      * NOT a governing instruction surface — its basename is not WORKFLOW/AGENTS/CLAUDE/README/
        TRACKER .md (case-insensitive, at any depth) AND it does not sit under a governing subdir
        (docs/workflow, docs/plans, docs/prd, docs/trd, docs/handoffs, docs/reviews, docs/dev);
      * a doc/artifact extension — `.md` / `.json` / `.schema.json` (a source extension is rejected).

    (Symlink / realpath resolution against the repo root is Build's WRITE-TIME responsibility — the
    grantor enforces the grant at the write; this validator enforces the contract on the handoff.)"""
    if not _nonempty_str(p):
        return False
    s = p.strip()
    if s.startswith("/"):                         # absolute path — outside the repo
        return False
    if s.endswith("/"):                           # a directory, not a file
        return False
    if "\\" in s:                                 # backslash — reject (POSIX repo paths only)
        return False
    if any(c in s for c in "\x00\n\r\t"):         # control chars — never a real path, injection risk
        return False
    segs = s.split("/")
    if ".." in segs:                              # parent-dir escape
        return False
    if not s.startswith("docs/"):                 # must live in the doc layer
        return False
    if segs[-1].lower() in GOV_BASENAMES:         # governing instruction file at any depth
        return False
    low = s.lower()
    if any(low.startswith(d) for d in GOV_SUBDIRS):  # governing (gate-disciplined) subdir
        return False
    if not s.endswith(DOC_EXTS):                  # not a doc/artifact extension
        return False
    return True


def _load(path):
    try:
        raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    except OSError as e:
        _die(f"cannot read closeout: {e}")
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        _die(f"closeout JSON is malformed: {e}")
    if not isinstance(data, dict):
        _die("closeout must be a JSON object")
    return data


def _dispatch(d):
    """Serialize the validated dispatch object as ONE compact JSON line."""
    return json.dumps(d, separators=(",", ":"), ensure_ascii=False)


def _validate(co):
    """Return the JSON dispatch line for a valid closeout; _die (exit 2) on any violation."""
    ticket = _int_min("ticket", co.get("ticket"), 1)
    if not _nonempty_str(co.get("provenance")):
        _die("closeout missing required non-empty 'provenance' stamp")
    outcome = co.get("outcome")
    if outcome not in OUTCOMES:
        _die(f"'outcome' must be one of {OUTCOMES}, got {outcome!r}")
    # The runaway-cap counts (idc_recirc_caps.py consumes these). The consultant is the designated
    # owner that bumps them, so the closeout is the authoritative producer-side source — Build never
    # invents them. Required + validated so a handoff missing them halts rather than running unbounded.
    recirc_count = _int_min("recirc_count", co.get("recirc_count"), 0)
    cascade_depth = _int_min("cascade_depth", co.get("cascade_depth"), 0)

    if outcome == "pass-through":
        if not _nonempty_str(co.get("consideration")):
            _die("pass-through closeout missing non-empty 'consideration'")
        return _dispatch({"verb": "launch-plan", "ticket": ticket,
                          "consideration": co["consideration"],
                          "recirc_count": recirc_count, "cascade_depth": cascade_depth})

    if outcome == "gated":
        if not _nonempty_str(co.get("think_pr")):
            _die("gated closeout missing non-empty 'think_pr'")
        return _dispatch({"verb": "notify-gated", "ticket": ticket,
                          "think_pr": co["think_pr"],
                          "recirc_count": recirc_count, "cascade_depth": cascade_depth})

    # trivial
    grant = co.get("grant")
    if not isinstance(grant, dict):
        _die("trivial closeout missing 'grant' object")
    issue = _int_min("grant.issue", grant.get("issue"), 1)
    paths = grant.get("paths")
    if not isinstance(paths, list) or not paths:
        _die("trivial grant must carry a non-empty 'paths' list (an unscoped permission grant is unsafe)")
    if not all(_is_canonical_doc_path(p) for p in paths):
        _die("trivial grant 'paths' must each be a repo-relative SUBORDINATE canonical-doc file "
             "(under docs/, .md/.json/.schema.json; not a governing surface like docs/workflow or a "
             "root CLAUDE.md; no absolute path, no '..' escape, no directory) — the trivial outcome "
             "must not grant Build write permission over a gate-disciplined or non-doc surface")
    if not _nonempty_str(grant.get("change")):
        _die("trivial grant missing non-empty 'change' description")
    # Carry the validated `change` through (Major 3): Build may only make the ONE specific edit the
    # consultant authorized, so the dispatch must name it, not just the path list.
    return _dispatch({"verb": "grant-build", "ticket": ticket, "issue": issue,
                      "paths": list(paths), "change": grant["change"],
                      "recirc_count": recirc_count, "cascade_depth": cascade_depth})


def main():
    p = argparse.ArgumentParser(description="Validate a recirc-consultant closeout; emit the next action (fail-closed).")
    p.add_argument("--closeout", required=True, help="path to the closeout JSON, or - for stdin")
    args = p.parse_args()
    print(_validate(_load(args.closeout)))
    sys.exit(0)


if __name__ == "__main__":
    main()
