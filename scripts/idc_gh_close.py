#!/usr/bin/env python3
"""idc_gh_close.py — ATOMIC, read-back-verified issue close for the github tracker backend (#96, RC3).

The old close recipe was TWO non-atomic gh calls — set Status=Done, then `gh issue close` — with no
verification that the issue actually closed. A crash, a silent gh no-op, or a partial failure between
them left a Done-but-OPEN issue (the live board carried 10 such stragglers). This helper collapses
close into ONE fail-closed operation:

  1. resolve the issue's project item id (a single whole-board read, or --item-id if the caller already
     has it — e.g. the cached id from $IDC_ITEMID_CACHE — to skip the read),
  2. set Status=Done (updateProjectV2ItemFieldValue via `gh project item-edit`),
  3. `gh issue close`,
  4. READ BACK the issue state and REFUSE success unless it is CLOSED.

Any unverified/failed step exits 2 with a machine-readable `close: <step> failed` line on stderr, so a
caller never records a close that did not actually land. Verified success exits 0. Idempotent: a
re-close of an already-Done, already-CLOSED issue re-verifies and exits 0.

Reuses idc_gh_board's gh wrapper (`_gh` — rate-limit aware, #99), whole-board reader (`fetch_items`),
and project node-id resolver, so it inherits the same fail-closed posture and rate-limit detection: a
rate-limit exits 3 with `rate-limited until <reset>` (resumable), distinct from the exit-2 hard error.
The Status field id and its Done option id are resolved BY NAME from the project's field list at call
time (not from tracker-config.yaml), so this helper needs no config file.

Stdlib only (shells out to `gh` through the shared wrapper).

CLI:  idc_gh_close.py --owner <o> --project <n> --issue <m> [--repo <dir>] [--item-id PVTI_…]
      exit 0 = closed + verified; exit 2 = any unverified/failed step; exit 3 = rate-limited (resumable).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_gh_board  # noqa: E402 — sibling helper in scripts/; reuse its gh wrapper + board reader


class CloseError(Exception):
    """A close step that could not be verified. The CLI maps it to exit 2 + `close: <step> failed`.

    RateLimitError is deliberately NOT a CloseError — it propagates to the CLI's exit-3 (resumable)
    path so a rate-limit pause is never miscategorised as a hard close failure."""

    def __init__(self, step, detail=""):
        self.step = step
        self.detail = detail
        super().__init__(f"{step} failed" + (f": {detail}" if detail else ""))


def _guard(step, fn, *args):
    """Run a board call for `step`; a hard failure becomes CloseError(step); a rate-limit re-raises.

    RateLimitError subclasses BoardReadError, so its except clause MUST come first — this helper is the
    ONE place that ordering invariant lives (every fail-closed board call in this module routes through
    it, so a rate-limit pause is never miscategorised as a hard close failure)."""
    try:
        return fn(*args)
    except idc_gh_board.RateLimitError:
        raise
    except idc_gh_board.BoardReadError as e:
        raise CloseError(step, str(e))


def _resolve_item_id(owner, project, issue, repo):
    """The project item id for `issue` from a single whole-board read (fail-closed if not on the board)."""
    items = _guard("resolve-item-id", idc_gh_board.fetch_items, owner, project, repo)
    for it in items:
        if (it.get("content") or {}).get("number") == issue and it.get("id"):
            return it["id"]
    raise CloseError("resolve-item-id", f"#{issue} is not on the board")


def _status_field_and_done_option(owner, project, repo):
    """(Status field node id, Done option id) resolved BY NAME from the project's field list (one call)."""
    out = _guard("resolve-status-field", idc_gh_board._gh,
                 ["project", "field-list", str(project), "--owner", owner, "--format", "json"], repo)
    try:
        fields = (json.loads(out) or {}).get("fields") or []
    except json.JSONDecodeError as e:
        raise CloseError("resolve-status-field", f"unparseable field list ({e})")
    for f in fields:
        if f.get("name") == "Status":
            fid = f.get("id")
            oid = next((o.get("id") for o in (f.get("options") or []) if o.get("name") == "Done"), None)
            if fid and oid:
                return fid, oid
            raise CloseError("resolve-status-field", "Status field or its Done option is missing")
    raise CloseError("resolve-status-field", "no Status field on this board")


def close_issue(owner, project, issue, repo, item_id=None):
    """Set Status=Done, close the issue, then verify state==CLOSED. Raise CloseError on any unverified step."""
    iid = item_id or _resolve_item_id(owner, project, issue, repo)
    fid, oid = _status_field_and_done_option(owner, project, repo)
    # item-edit needs the project NODE id (PVT_…), not the integer project number
    pnode = _guard("resolve-project-node", idc_gh_board._resolve_project_node_id, owner, project, repo)

    _guard("set-status-done", idc_gh_board._gh,
           ["project", "item-edit", "--id", iid, "--project-id", pnode,
            "--field-id", fid, "--single-select-option-id", oid], repo)
    _guard("issue-close", idc_gh_board._gh, ["issue", "close", str(issue)], repo)
    # READ BACK — the historically-failing half. Refuse success unless the issue is actually CLOSED,
    # which is exactly what makes a Done-but-open straggler impossible going forward.
    state = _guard("verify-closed", idc_gh_board._gh,
                   ["issue", "view", str(issue), "--json", "state", "--jq", ".state"], repo).strip()
    if state != "CLOSED":
        raise CloseError("verify-closed", f"issue state is {state or 'unknown'!r}, not CLOSED")


def main():
    ap = argparse.ArgumentParser(
        description="Atomically close a github-tracker issue (Status=Done + close + read-back verify).")
    ap.add_argument("--owner", required=True, help="project owner login (user or org)")
    ap.add_argument("--project", required=True, help="integer project number")
    ap.add_argument("--issue", required=True, type=int, help="issue number to close")
    ap.add_argument("--repo", default=".", help="repo dir to run gh in (default: cwd)")
    ap.add_argument("--item-id", dest="item_id", default=None,
                    help="the project item id (PVTI_…), if already resolved (e.g. from $IDC_ITEMID_CACHE) "
                         "— skips the board read")
    args = ap.parse_args()
    try:
        close_issue(args.owner, args.project, args.issue, os.path.abspath(args.repo), args.item_id)
    except idc_gh_board.RateLimitError as e:
        idc_gh_board.emit_rate_limit_verdict(e)   # shared pinned verdict + exit 3 (resumable)
    except CloseError as e:
        # `e` already renders as `<step> failed[: <detail>]`, so this is the pinned `close: <step> failed` line.
        sys.stderr.write(f"close: {e}\n")
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
