#!/usr/bin/env python3
"""Validate a recirc-consultant CLOSEOUT and emit the Build orchestrator's next action.

The "larger loop" (`WORKFLOW.md §4.3/§4.4`): when a running Build surfaces a recirc event it spawns a
fresh specialist recirc-consultant (via the runtime adapter) and then acts on the consultant's
*closeout* — a small machine-readable handoff naming exactly what to do next. The orchestrator is a
dumb router: it does NOT re-derive the gate decision, it just dispatches on the validated closeout.

This helper is the FAIL-CLOSED guarantee that a handoff can never be silently dropped (the b985c1e7
failure, where two recirc tickets were filed and abandoned). A malformed or incomplete closeout exits
2 and prints NO dispatch line, so the orchestrator halts-and-surfaces instead of stranding the ticket.

Closeout schema (JSON object on stdin or a file):
    ticket       (required) the Stage=Recirculation ticket the consultant processed
    outcome      (required) one of: pass-through | gated | trivial
    provenance   (required, non-empty) the discovered-scope provenance stamp ("originated from #N …")
  outcome-specific:
    pass-through  consideration (required, non-empty)  -> launch a (batched) Plan worker
    gated         think_pr      (required, non-empty)  -> cmux/push ping; NO Plan; ticket parks
    trivial       grant: {issue:int, paths:[non-empty], change:str(non-empty)}
                                                       -> grant Build permission for that exact
                                                          canonical-doc change as a SEPARATE tiny doc
                                                          PR through staging; NO Plan, NO re-sequence

On a valid closeout, prints ONE deterministic dispatch line and exits 0:
    dispatch: launch-plan  consideration=<ref> ticket=<n>
    dispatch: notify-gated think_pr=<ref> ticket=<n>
    dispatch: grant-build  issue=<n> paths=<p1,p2,...> ticket=<n>

Exit codes:
    0  valid closeout — the dispatch line is printed to stdout (the orchestrator acts on it).
    2  fail-closed: bad args, missing/unreadable file, malformed JSON, or a schema violation —
       nothing is printed to stdout (no dispatch ⇒ the orchestrator halts, never strands).
"""
import argparse
import json
import sys

OUTCOMES = ("pass-through", "gated", "trivial")


def _die(msg):
    sys.stderr.write(f"idc_recirc_closeout: {msg}\n")
    sys.exit(2)


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


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


def _validate(co):
    """Return the dispatch line for a valid closeout; _die (exit 2) on any violation."""
    if "ticket" not in co or co["ticket"] in (None, ""):
        _die("closeout missing required 'ticket'")
    ticket = co["ticket"]
    if not _nonempty_str(co.get("provenance")):
        _die("closeout missing required non-empty 'provenance' stamp")
    outcome = co.get("outcome")
    if outcome not in OUTCOMES:
        _die(f"'outcome' must be one of {OUTCOMES}, got {outcome!r}")

    if outcome == "pass-through":
        if not _nonempty_str(co.get("consideration")):
            _die("pass-through closeout missing non-empty 'consideration'")
        return f"dispatch: launch-plan consideration={co['consideration']} ticket={ticket}"

    if outcome == "gated":
        if not _nonempty_str(co.get("think_pr")):
            _die("gated closeout missing non-empty 'think_pr'")
        return f"dispatch: notify-gated think_pr={co['think_pr']} ticket={ticket}"

    # trivial
    grant = co.get("grant")
    if not isinstance(grant, dict):
        _die("trivial closeout missing 'grant' object")
    if not isinstance(grant.get("issue"), int):
        _die("trivial grant missing integer 'issue'")
    paths = grant.get("paths")
    if not isinstance(paths, list) or not paths or not all(_nonempty_str(p) for p in paths):
        _die("trivial grant must carry a non-empty 'paths' list (an unscoped permission grant is unsafe)")
    if not _nonempty_str(grant.get("change")):
        _die("trivial grant missing non-empty 'change' description")
    return f"dispatch: grant-build issue={grant['issue']} paths={','.join(paths)} ticket={ticket}"


def main():
    p = argparse.ArgumentParser(description="Validate a recirc-consultant closeout; emit the next action (fail-closed).")
    p.add_argument("--closeout", required=True, help="path to the closeout JSON, or - for stdin")
    args = p.parse_args()
    print(_validate(_load(args.closeout)))
    sys.exit(0)


if __name__ == "__main__":
    main()
