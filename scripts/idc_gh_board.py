#!/usr/bin/env python3
"""idc_gh_board.py — the shared GitHub Projects v2 board reader with TRUE cursor pagination.

Every github-backend board read in IDC needs the WHOLE board. `gh project item-list` returns only a
single 30-item page by default, and `--limit N` merely raises a fixed ceiling — the same truncation
bug at a larger N. A board grown past one page therefore silently truncates: the build-lane query
misses eligible `Stage=Buildable`/`Status=Todo` issues, considerations past the cut vanish, and
`itemid` returns blank for a high issue number (→ a mutation refuses on the empty id). This helper
pages the GraphQL `items(first:100, after:$cursor)` connection until `hasNextPage` is false, so
callers always see every item — no magic limit, no truncation frontier.

It emits the SAME flattened shape `gh project item-list --format json` produces — each single-select
field value flattened to a lowercased key (Status→`status`, Stage→`stage`, …), plus `id` (the
project item node id) and `content` (`{type, number, title}`) — so existing callers and their jq
filters keep working unchanged, including the `(.stage // "Buildable")` legacy-board default.

Control-char robust by construction: a GraphQL response is standard JSON with control characters
(U+0000–U+001F) escaped, so `json.loads` never chokes the way an external jq does on gh's raw
`--format json` TEXT path; and the emitted JSON is ASCII-escaped (json.dumps default), so a
downstream external jq over this helper's stdout is safe too.

Stdlib only (subprocess shells out to `gh`, like the sibling helpers).

CLI:  idc_gh_board.py --owner <o> --project <n> [--repo <dir>]   → prints {"items":[...]} to stdout
      idc_gh_board.py --owner <o> --project <n> --emit-idmap      → prints the item-id map (below)
      (exit 0 = ok; exit 2 = any gh / parse failure; exit 3 = rate-limited, with a stdout verdict).
API:  fetch_items(owner, project_number, repo=".") -> list[dict]  (raises BoardReadError on failure).
"""
import argparse
import json
import os
import subprocess
import sys

# Query the items connection by the project NODE id (resolved once) so this works for a user- OR an
# org-owned project without branching on owner type. `$cursor` is nullable: omitted on the first
# page (→ after: null), then set from the prior page's endCursor. pageInfo drives the loop.
ITEMS_QUERY = """
query($pid: ID!, $cursor: String) {
  node(id: $pid) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          fieldValues(first: 50) {
            nodes {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2FieldCommon { name } }
              }
            }
          }
          content {
            __typename
            ... on Issue       { number title }
            ... on PullRequest { number title }
            ... on DraftIssue  { title }
          }
        }
      }
    }
  }
}
"""

# A hard backstop on the page loop so a malformed `hasNextPage:true` / unchanging cursor can never
# spin forever. GitHub Projects v2 caps far below this (100 items/page × this many pages).
MAX_PAGES = 1000


class BoardReadError(Exception):
    """Any failure reading the board (missing gh, non-zero gh, unparseable response, unresolved id).

    Callers that must fail-closed catch this; the CLI maps it to exit 2 with a stderr diagnostic."""


class BoardWriteError(BoardReadError):
    """A board WRITE (create/mutate) failed — raised by create_item() on any unrecoverable failure,
    AFTER a best-effort discard of any partial item.

    A SUBCLASS of BoardReadError so a fail-closed `except BoardReadError` still catches it (the same
    posture the read path relies on): a caller can never mistake a failed atomic create for success."""


class RateLimitError(BoardReadError):
    """GitHub rate-limit exhaustion (GraphQL points / primary REST / secondary-abuse / 403-rate).

    A SUBCLASS of BoardReadError on purpose: an unaware caller's `except BoardReadError` still
    fail-closes (treats it as a hard error), while a rate-limit-aware caller (the autorun drain, Unit 4)
    catches RateLimitError specifically and reads `.reset` to pause-and-resume instead of dropping work.
    `reset` is the reset epoch from `gh api rate_limit` (or the literal 'unknown' if unreadable). The CLI
    maps this to exit 3 + the machine-readable `rate-limited until <reset>` verdict (distinct from the
    exit-2 hard-error path) — do NOT change that string/exit convention; downstream consumers pin it."""

    def __init__(self, reset=None):
        # Coerce a missing reset to 'unknown' HERE, once, so every caller just passes the raw value.
        self.reset = reset if reset is not None else "unknown"
        super().__init__(f"rate-limited until {self.reset}")


# Rate-limit signatures in `gh` stderr (#99, design §C.3). Lowercased substring match — covers the
# primary REST/GraphQL limit ("API rate limit exceeded"), the secondary/abuse limit ("secondary rate
# limit"), the GraphQL error type (RATE_LIMITED), and older abuse-detection wording. A bare "403" is
# deliberately NOT a marker: a 403 is only a rate-limit when paired with this wording (else it is a
# permissions error → a hard failure). Detection must be SPECIFIC, not "any failure is a rate-limit".
_RATE_LIMIT_MARKERS = (
    "rate limit exceeded",
    "secondary rate limit",
    "exceeded a secondary rate",
    "rate_limited",
    "retry your request again later",
)

# Once-per-process latch for the preflight (below). Module-scoped so it runs a single free rate_limit
# check per board-read process, not per `_gh` call.
_PREFLIGHT_DONE = False


def _is_rate_limit_stderr(text):
    low = (text or "").lower()
    return any(m in low for m in _RATE_LIMIT_MARKERS)


def _rate_limit_info(repo):
    """Best-effort `(remaining, reset)` for the relevant quota from `gh api rate_limit`.

    RAW subprocess (NOT `_gh`) so it never re-enters the preflight / detection below. Returns None if gh
    is missing, exits non-zero, or the payload is unparseable — the caller then does NOT block (fail-open
    on an unknowable quota; reactive detection still guards the real call). Prefers the GraphQL resource
    (IDC's heavy path) and falls back to core. `gh api rate_limit` does not itself consume quota."""
    try:
        p = subprocess.run(["gh", "api", "rate_limit"], cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError):
        return None
    if p.returncode != 0:
        return None
    try:
        resources = (json.loads(p.stdout) or {}).get("resources") or {}
    except json.JSONDecodeError:
        return None
    r = resources.get("graphql") or resources.get("core") or {}
    remaining, reset = r.get("remaining"), r.get("reset")
    if remaining is None and reset is None:
        return None
    return remaining, reset


def _preflight_rate_limit(repo):
    """Once per process, before the first real gh call: if the relevant quota is ALREADY exhausted, raise
    RateLimitError up-front (a clean resumable pause) rather than fire a doomed query. Free (`gh api
    rate_limit` consumes no quota) and best-effort — an unknowable quota never blocks."""
    global _PREFLIGHT_DONE
    if _PREFLIGHT_DONE:
        return
    _PREFLIGHT_DONE = True
    info = _rate_limit_info(repo)
    if info is None:
        return
    remaining, reset = info
    if isinstance(remaining, int) and remaining <= 0:
        raise RateLimitError(reset)


def _gh(args, repo):
    """Run `gh <args>` in `repo`; return stdout. Raise on failure.

    Rate-limit aware (#99, design §C.3): a once-per-process preflight fail-closes up-front on an already
    exhausted quota, and a 403 / secondary-rate / RATE_LIMITED failure on the call becomes a
    RateLimitError carrying the reset from `gh api rate_limit` — so a caller can pause-and-resume instead
    of treating a resumable throttle as a hard error. Any OTHER non-zero exit is a hard BoardReadError."""
    _preflight_rate_limit(repo)
    try:
        p = subprocess.run(["gh"] + args, cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError) as e:
        raise BoardReadError(f"gh invocation failed: {e}")
    if p.returncode != 0:
        if _is_rate_limit_stderr(p.stderr):
            info = _rate_limit_info(repo)
            raise RateLimitError(info[1] if info else None)
        raise BoardReadError(f"gh {' '.join(args[:2])} failed: {p.stderr.strip()[:200]}")
    return p.stdout


def _resolve_project_node_id(owner, project_number, repo):
    """Map (owner, integer project number) -> the project node id (PVT_…) the GraphQL query needs."""
    out = _gh(["project", "view", str(project_number), "--owner", owner,
               "--format", "json", "--jq", ".id"], repo)
    pid = out.strip()
    if not pid:
        raise BoardReadError(
            f"could not resolve project node id for {owner}/#{project_number}")
    return pid


def _field_and_option(fields, field_name, option_name):
    """(field node id, option id) for a single-select field's named option, from a `field-list` payload.
    Returns (None, None) if the field or the option is absent — the caller fails closed on that."""
    for f in fields:
        if f.get("name") == field_name:
            fid = f.get("id")
            oid = next((o.get("id") for o in (f.get("options") or [])
                        if o.get("name") == option_name), None)
            return fid, oid
    return None, None


def create_item(owner, project, repo, title, body, stage, status):
    """Create a board item with Stage AND Status set together — ATOMICALLY.

    Creates the backing issue, adds it to project #<project>, then sets Stage and Status as one
    logical unit. If ANY step after issue creation fails, DISCARDS the partial item (deletes the
    board item AND closes the backing issue), so a create can NEVER leave a Stage-without-Status
    item on the board — the empty-Status shape that blinds a downstream detector (#255/#256).

    Returns the new item node id (PVTI_…) on success. Raises BoardWriteError (a BoardReadError
    subclass, so fail-closed callers still catch it) on any failure. Fail-closed BEFORE creating
    anything: an unresolvable project id / Stage / Status leaves no dangling issue.

    Every gh call routes through `_gh` — the single seam a unit test monkeypatches to simulate a
    partial (Status-set) failure and assert the discard fires. NOTE: this is the sanctioned atomic
    github create primitive; re-pointing the shipped `idc_recirc_sweep.py` create path at it is
    deferred to a later phase (that module is intentionally not touched here)."""
    # Resolve the project node id + Stage/Status field+option ids up front (item-edit needs the PVT_
    # node id, not the integer project number — the documented gotcha). Any unresolved id → refuse to
    # create, so we never leave a dangling issue behind.
    pnode = _resolve_project_node_id(owner, project, repo)
    fields_out = _gh(["project", "field-list", str(project), "--owner", owner, "--format", "json"], repo)
    try:
        fields = (json.loads(fields_out) or {}).get("fields") or []
    except json.JSONDecodeError as e:
        raise BoardWriteError(f"unparseable field list ({e}) — refusing to create")
    stage_fid, stage_oid = _field_and_option(fields, "Stage", stage)
    status_fid, status_oid = _field_and_option(fields, "Status", status)
    if not (stage_fid and stage_oid):
        raise BoardWriteError(f"Stage field or option {stage!r} not on the board — refusing to create")
    if not (status_fid and status_oid):
        raise BoardWriteError(f"Status field or option {status!r} not on the board — refusing to create")

    # 1. Create the backing issue. Nothing to discard yet, so a failure here just propagates.
    url = _gh(["issue", "create", "--title", title, "--body", body], repo).strip()
    url = url.splitlines()[-1] if url else ""
    if not url:
        raise BoardWriteError("issue create returned no URL — refusing to continue")
    issue_num = url.rstrip("/").split("/")[-1]

    def _discard(item_id):
        # Best-effort teardown so no half-created (Stage-without-Status) item survives. Each step is
        # guarded independently (a partly-failing discard still tries the rest). Returns None on a
        # CLEAN teardown, or a string naming the step(s) that themselves failed — so the caller reports
        # the discard TRUTHFULLY ("discard INCOMPLETE …") instead of asserting a rollback that never
        # happened. `item-delete` takes the project number positionally + --owner + --id (there is NO
        # --project-id flag on item-delete — only item-edit has one).
        problems = []
        if item_id:
            try:
                _gh(["project", "item-delete", str(project), "--owner", owner, "--id", item_id], repo)
            except BoardReadError as e:
                problems.append(f"item-delete failed ({e})")
        else:
            # item-add gave us no id, yet it may have created the board item server-side — we have no
            # handle to delete it. Surface the possible orphan rather than silently claim it was cleaned.
            problems.append("no board-item id captured — a possibly-orphaned board item could survive")
        try:
            _gh(["issue", "close", str(issue_num)], repo)
        except BoardReadError as e:
            problems.append(f"issue close failed ({e})")
        return "; ".join(problems) if problems else None

    item_id = None
    try:
        # 2. Add the issue to the board.
        item_id = _gh(["project", "item-add", str(project), "--owner", owner, "--url", url,
                       "--format", "json", "--jq", ".id"], repo).strip()
        if not item_id:
            raise BoardReadError("item-add returned no item id")
        # 3. Set Stage, then Status — the two fields that MUST land together. If the Status-set fails
        #    here, we have a Stage-without-Status item (the bug), so the discard below undoes it.
        _gh(["project", "item-edit", "--id", item_id, "--project-id", pnode,
             "--field-id", stage_fid, "--single-select-option-id", stage_oid], repo)
        _gh(["project", "item-edit", "--id", item_id, "--project-id", pnode,
             "--field-id", status_fid, "--single-select-option-id", status_oid], repo)
    except RateLimitError:
        # A throttle mid-create is RESUMABLE: re-raise it UNCHANGED so the rate-limit-aware drain reads
        # `.reset` and pauses/resumes, instead of flattening it to a hard BoardWriteError and dropping
        # the work. We do NOT attempt a discard here — every teardown gh call would hit the same live
        # limit and fail; pause-and-resume is the recovery path, not a best-effort rollback under throttle.
        raise
    except BoardReadError as e:                   # any OTHER gh failure after add → discard + fail closed
        incomplete = _discard(item_id)            # None if teardown was clean, else what still failed
        why = f"create step failed ({e})"
        if incomplete:
            raise BoardWriteError(f"{why} — discard INCOMPLETE: {incomplete} (#{issue_num})")
        raise BoardWriteError(f"{why} — discarded the partial item (#{issue_num})")
    return item_id


def _flatten(node):
    """Flatten one GraphQL item node into gh's `project item-list` shape.

    Single-select field values become lowercased-field-name keys (Status→`status`); absent fields
    are simply OMITTED (never set to ""), so `(.stage // "Buildable")` still reads an unset Stage as
    Buildable. `id` is the project item node id; `content` mirrors gh (`type`/`number`/`title`)."""
    item = {}
    for fv in ((node.get("fieldValues") or {}).get("nodes") or []):
        if fv.get("__typename") != "ProjectV2ItemFieldSingleSelectValue":
            continue
        name = (fv.get("field") or {}).get("name")
        if not name:
            continue
        item[name.lower()] = fv.get("name")
    item["id"] = node.get("id")
    content = node.get("content")
    if isinstance(content, dict) and content:
        c = {"type": content.get("__typename")}
        number, title = content.get("number"), content.get("title")
        if number is not None:
            c["number"] = number
        if title is not None:
            c["title"] = title
            item["title"] = title   # gh surfaces a top-level title too (content/draft title)
        item["content"] = c
    return item


def fetch_items(owner, project_number, repo="."):
    """Return ALL project items (every page), each flattened to gh's item-list shape.

    Raises BoardReadError on any gh / parse failure — fail-closed, never a silent partial board."""
    pid = _resolve_project_node_id(owner, project_number, repo)
    items = []
    cursor = None
    for _ in range(MAX_PAGES):
        args = ["api", "graphql", "-f", f"query={ITEMS_QUERY}", "-f", f"pid={pid}"]
        if cursor:
            args += ["-f", f"cursor={cursor}"]
        out = _gh(args, repo)
        try:
            data = json.loads(out)
        except json.JSONDecodeError as e:
            raise BoardReadError(f"unparseable graphql response: {e}")
        # Fail CLOSED on any anomalous response rather than coerce a missing shape to an empty board —
        # an empty/partial board recreates the silent "blind drain: complete" this reader exists to
        # kill. (gh usually exits non-zero on a GraphQL `errors` response; double-guard here.)
        if data.get("errors"):
            raise BoardReadError(f"graphql errors: {str(data['errors'])[:200]}")
        node = (data.get("data") or {}).get("node")
        if not isinstance(node, dict) or not isinstance(node.get("items"), dict):
            raise BoardReadError("graphql response missing node.items — refusing a partial/empty board")
        conn = node["items"]
        nodes = conn.get("nodes")
        if not isinstance(nodes, list):
            raise BoardReadError("graphql response missing items.nodes — refusing a partial board")
        for n in nodes:
            items.append(_flatten(n))
        page = conn.get("pageInfo")
        if not isinstance(page, dict):
            # A connection always returns pageInfo when requested; a missing/non-dict one means we
            # can't tell whether more pages remain → fail CLOSED rather than treat this as the final
            # page (which could silently truncate). Completes the malformed-shape closure.
            raise BoardReadError("graphql response missing items.pageInfo — refusing a partial board")
        has_next = page.get("hasNextPage")
        if not isinstance(has_next, bool):
            # pageInfo present but hasNextPage missing/non-bool: a bare `if page.get("hasNextPage")`
            # would read a missing/null/non-bool as falsy → treat THIS as the last page → silently
            # truncate a board that may have more. A connection's hasNextPage is always a bool when
            # requested, so anything else is anomalous → fail CLOSED (same posture as the branches above).
            raise BoardReadError(
                "graphql response pageInfo.hasNextPage missing or non-bool — refusing a partial board")
        if has_next:
            cursor = page.get("endCursor")
            if not cursor:
                # hasNextPage=true with no endCursor is anomalous (GitHub always pairs them); fail
                # CLOSED rather than silently return a PARTIAL board.
                raise BoardReadError(
                    "paginated board read: hasNextPage=true but no endCursor — refusing a partial board")
            continue
        break
    else:
        # The loop exhausted MAX_PAGES without ever seeing hasNextPage=false — anomalous (a real board
        # is far smaller). Refuse a possibly-partial board rather than return what we happened to get.
        raise BoardReadError(
            f"paginated board read exceeded {MAX_PAGES} pages — refusing a possibly-partial board")
    return items


def idmap_lines(items):
    """Return `issue#<TAB>item_id` lines for every issue-backed item on the board.

    The item-id cache the tracker recipe consumes via $IDC_ITEMID_CACHE (design §C.1, RC4a): ONE
    wave-scoped board read feeds every later id lookup, replacing itemid()'s per-mutation whole-board
    re-download (graphql-cost.md sink #1: ~120 board reads/wave → ~2). Draft items (no issue number)
    are skipped; the item id (`PVTI_…`) is control-char-free, so a bare TAB-delimited table is safe and
    trivially parsed by the recipe's `awk -F'\\t'` lookup. Emitted in board order (lookup is by key)."""
    lines = []
    for it in items:
        num = (it.get("content") or {}).get("number")
        iid = it.get("id")
        if num is not None and iid:
            lines.append(f"{num}\t{iid}")
    return lines


def emit_rate_limit_verdict(err):
    """Print the pinned `rate-limited until <reset>` verdict and exit 3 (the resumable-pause convention
    shared by every CLI that reads the board — do NOT change the string or the exit code; downstream
    consumers, e.g. the autorun drain, pin them). Owned here so the two `main()`s never drift."""
    sys.stdout.write(f"rate-limited until {err.reset}\n")
    sys.exit(3)


def main():
    ap = argparse.ArgumentParser(
        description="Read ALL items of a GitHub Projects v2 board (true cursor pagination).")
    ap.add_argument("--owner", required=True, help="project owner login (user or org)")
    ap.add_argument("--project", required=True, help="integer project number")
    ap.add_argument("--repo", default=".", help="repo dir to run gh in (default: cwd)")
    ap.add_argument("--emit-idmap", action="store_true",
                    help="emit a NUM<TAB>item_id table (one line per issue-backed item) from the single "
                         "paginated read, for $IDC_ITEMID_CACHE — instead of the full {\"items\":[…]} JSON")
    args = ap.parse_args()
    try:
        items = fetch_items(args.owner, args.project, os.path.abspath(args.repo))
    except RateLimitError as e:
        emit_rate_limit_verdict(e)   # distinct resumable exit 3 + pinned verdict (see the helper)
    except BoardReadError as e:
        sys.stderr.write(f"idc-gh-board: {e}\n")
        sys.exit(2)
    if args.emit_idmap:
        sys.stdout.write("".join(f"{ln}\n" for ln in idmap_lines(items)))
        sys.exit(0)
    json.dump({"items": items}, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


if __name__ == "__main__":
    main()
