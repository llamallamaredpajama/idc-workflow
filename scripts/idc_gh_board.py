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
project item node id) and `content` (`{type, number, title, repository}`) — so existing callers and their jq
filters keep working unchanged, including the `(.stage // "Buildable")` legacy-board default.

Control-char robust by construction: a GraphQL response is standard JSON with control characters
(U+0000–U+001F) escaped, so `json.loads` never chokes the way an external jq does on gh's raw
`--format json` TEXT path; and the emitted JSON is ASCII-escaped (json.dumps default), so a
downstream external jq over this helper's stdout is safe too.

Stdlib only (subprocess shells out to `gh`, like the sibling helpers).

CLI:  idc_gh_board.py --owner <o> --project <n> [--repo <dir>]   → prints {"items":[...]} to stdout
      idc_gh_board.py --owner <o> --project <n> --emit-idmap      → prints the item-id map (below)
      idc_gh_board.py ensure-project|reconcile-status|ensure-field|ensure-link ...
      idc_gh_board.py close-project-issues|delete-project ...      → validating lifecycle writes
      (exit 0 = ok; exit 2 = any gh / parse failure; exit 3 = rate-limited, with a stdout verdict).
API:  fetch_items(owner, project_number, repo=".") -> list[dict]  (raises BoardReadError on failure).
"""
import argparse
import json
import os
import re
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
            ... on Issue       { number title repository { nameWithOwner } }
            ... on PullRequest { number title repository { nameWithOwner } }
            ... on DraftIssue  { title }
          }
        }
      }
    }
  }
}
"""

# Single-item field read by project-item node id — the budget-friendly way for the transition engine
# to read ONE item's current (Stage, Status) for a guard/read-back WITHOUT re-paginating the whole
# board. The item id comes from the shared item-id cache; this is exactly one gh GraphQL call.
ITEM_QUERY = """
query($id: ID!) {
  node(id: $id) {
    ... on ProjectV2Item {
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
        ... on Issue       { number title repository { nameWithOwner } }
        ... on PullRequest { number title repository { nameWithOwner } }
        ... on DraftIssue  { title }
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
    """A board write failed or was refused by a validating adapter guard.

    A SUBCLASS of BoardReadError so a fail-closed `except BoardReadError` still catches it (the same
    posture the read path relies on): a caller can never mistake a failed mutation for success."""


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


def _norm_labels(labels):
    """Normalize a labels argument (a list, a single string, a comma-list, or None) to a de-duped list
    of non-empty label names — so `--labels operator-action`, `--labels a,b`, and a repeated `--labels`
    all resolve the same way. Order-preserving."""
    if not labels:
        return []
    if isinstance(labels, str):
        labels = [labels]
    out = []
    for item in labels:
        for part in str(item).split(","):
            part = part.strip()
            if part and part not in out:
                out.append(part)
    return out


def discard_partial_item(owner, project, repo, item_id, issue_num):
    """Best-effort teardown of a half-created item so no partial (Stage-without-Status, or a
    readback-mismatch) item survives — delete the board item AND close the backing issue. Each step is
    guarded independently (a partly-failing discard still tries the rest). Returns None on a CLEAN
    teardown, or a string naming the step(s) that themselves failed — so the caller reports the discard
    TRUTHFULLY ("discard INCOMPLETE …") instead of asserting a rollback that never happened.

    Module-level (not a create_item closure) so the ENGINE's post-return create read-back
    (idc_transition) can invoke the SAME atomic cleanup on a Stage/Status mismatch (round-5 Fix 5),
    not just failures inside create_item. `item-delete` takes the project number positionally +
    --owner + --id (there is NO --project-id flag on item-delete — only item-edit has one)."""
    problems = []
    if item_id:
        try:
            _gh(["project", "item-delete", str(project), "--owner", owner, "--id", item_id], repo)
        except BoardReadError as e:
            problems.append(f"item-delete failed ({e})")
    else:
        # No board-item id, yet the item may exist server-side — we have no handle to delete it.
        # Surface the possible orphan rather than silently claim it was cleaned.
        problems.append("no board-item id captured — a possibly-orphaned board item could survive")
    if issue_num:
        try:
            _gh(["issue", "close", str(issue_num)], repo)
        except BoardReadError as e:
            problems.append(f"issue close failed ({e})")
    else:
        # No issue number to close (a read-back that couldn't resolve it) — we can only delete the
        # board item. Report the possibly-surviving backing issue LOUDLY so the caller never treats a
        # discard that closed NO issue as a clean teardown (round-6 Fix 5).
        problems.append("no issue number to close — a backing issue may survive; close it by hand")
    return "; ".join(problems) if problems else None


def create_item(owner, project, repo, title, body, stage, status, labels=None, issue_type=None):
    """Create a board item with Stage AND Status set together — ATOMICALLY.

    `labels` (a list / comma-list / single string) are applied to the backing issue at create time;
    `issue_type` is applied as a `type:<issue_type>` label (the adapter's `type` input). Both are how a
    gate issue carries its `operator-action` label through the sanctioned door.

    Creates the backing issue, adds it to project #<project>, then sets Stage and Status as one
    logical unit. If ANY step after issue creation fails, DISCARDS the partial item (deletes the
    board item AND closes the backing issue), so a create can NEVER leave a Stage-without-Status
    item on the board — the empty-Status shape that blinds a downstream detector (#255/#256).

    Returns the new item node id (PVTI_…) on success. Raises BoardWriteError (a BoardReadError
    subclass, so fail-closed callers still catch it) on any failure. Fail-closed BEFORE creating
    anything: an unresolvable project id / Stage / Status leaves no dangling issue.

    Every gh call routes through `_gh` — the single seam a unit test monkeypatches to simulate a
    partial (Status-set) failure and assert the discard fires. This is the sanctioned atomic github
    create primitive; `idc_recirc_sweep.py`'s ticket-filing path mints Recirculation tickets through
    it (issue #130), so a filed ticket can never be the empty-Status pointer the old chain left."""
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

    # 1. Create the backing issue (with any labels / type label). Nothing to discard yet, so a failure
    #    here just propagates.
    issue_args = ["issue", "create", "--title", title, "--body", body]
    for lbl in _norm_labels(labels):
        issue_args += ["--label", lbl]
    if issue_type:
        issue_args += ["--label", f"type:{issue_type}"]
    url = _gh(issue_args, repo).strip()
    url = url.splitlines()[-1] if url else ""
    if not url:
        raise BoardWriteError("issue create returned no URL — refusing to continue")
    issue_num = url.rstrip("/").split("/")[-1]

    def _discard(item_id):
        return discard_partial_item(owner, project, repo, item_id, issue_num)

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
    Buildable. `id` is the project item node id; `content` mirrors gh and adds the issue/PR repository
    identity used to keep lifecycle closes inside the selected repo."""
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
        repository = (content.get("repository") or {}).get("nameWithOwner")
        if repository:
            c["repository"] = repository
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


def fetch_item(item_id, repo="."):
    """Return ONE project item's flattened fields ({status, stage, …, id, content}) via a single
    node(id:) GraphQL query — the transition engine's read-back / current-state read for a github op.
    The item id comes from the shared item-id cache, so this costs one gh call and NO pagination.

    Raises BoardReadError on any gh / parse / anomalous-shape failure — fail-closed (never a silent
    empty item, which would let a guard read a wrong current state)."""
    out = _gh(["api", "graphql", "-f", f"query={ITEM_QUERY}", "-f", f"id={item_id}"], repo)
    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        raise BoardReadError(f"unparseable graphql response for item {item_id}: {e}")
    if data.get("errors"):
        raise BoardReadError(f"graphql errors reading item {item_id}: {str(data['errors'])[:200]}")
    node = (data.get("data") or {}).get("node")
    if not isinstance(node, dict) or not node:
        raise BoardReadError(f"item {item_id} not found (graphql node missing) — refusing a blind read")
    return _flatten(node)


def set_single_select(owner, project, repo, item_id, field_name, option_name):
    """Set ANY single-select field (`Status`, `Wave`, `Phase`, `Domain`, `Stage`) on a project item to
    an option BY NAME — the one sanctioned github field-write primitive. Resolves the project node id +
    the field/option ids (item-edit --project-id needs the PVT_ node id, NOT the integer number), then
    one item-edit. Raises BoardWriteError if the field/option is absent, BoardReadError/RateLimitError
    on gh failure. Read-back is the caller's job (the engine re-reads via fetch_item). This is the door
    the engine's `move` (Status) and `set-field` (non-Status) ops drive — no role-facing recipe runs a
    raw `gh project item-edit`, so the interlock's deny of that raw command never bricks Plan."""
    pnode = _resolve_project_node_id(owner, project, repo)
    fields_out = _gh(["project", "field-list", str(project), "--owner", owner, "--format", "json"], repo)
    try:
        fields = (json.loads(fields_out) or {}).get("fields") or []
    except json.JSONDecodeError as e:
        raise BoardWriteError(f"unparseable field list ({e}) — refusing to set {field_name}")
    fid, oid = _field_and_option(fields, field_name, option_name)
    if not (fid and oid):
        raise BoardWriteError(f"{field_name} field or option {option_name!r} not on the board "
                              f"— refusing to set {field_name}")
    _gh(["project", "item-edit", "--id", item_id, "--project-id", pnode,
         "--field-id", fid, "--single-select-option-id", oid], repo)


def set_status(owner, project, repo, item_id, status):
    """Set a project item's Status single-select field to `status` (by name) — the github `move`/
    terminal write primitive; a thin alias over set_single_select for the Status field."""
    set_single_select(owner, project, repo, item_id, "Status", status)


def add_comment(issue_num, body, repo="."):
    """Post a comment on an issue — the github `link` / ownership-recording write. A real, durable
    mutation (raises BoardReadError/RateLimitError on failure), monkeypatchable by attribute in tests."""
    _gh(["issue", "comment", str(issue_num), "--body", body], repo)


# ── dependency mutation (the engine's `unblock --by` door, github backend) ────────────────────────
# On github a `blocks` edge has TWO representations: the NATIVE GitHub issue-dependencies
# `dependencies/blocked_by` relation (the ONLY one the autorun drain's dependency gate reads,
# idc_autorun_drain._blocked_by_numbers) and the engine's parseable comment marker on the CHILD
# (`<!-- idc-blocked-by: {child, parent, kind} -->`, read by the dispose guards). `unblock --by`
# removes BOTH and reads BOTH back absent before the engine may change Status. A partial removal is
# intentionally resumable: the next run skips the already-absent representation and finishes the rest.
# Every REST call runs through the SANCTIONED engine subprocess (never the Bash tool, so the interlock
# never sees a raw `gh api …/dependencies/blocked_by … -X DELETE`); no role-facing recipe names them.
def issue_database_id(num, repo="."):
    """The issue's REST database id (the key the dependencies endpoint uses — NOT the issue number)."""
    out = _gh(["api", f"repos/{{owner}}/{{repo}}/issues/{int(num)}", "--jq", ".id"], repo)
    try:
        return int(out.strip())
    except ValueError as e:
        raise BoardReadError(f"could not resolve issue #{num} database id ({e})")


def blocked_by_numbers(child, repo="."):
    """The issue NUMBERS of every native `blocked_by` dependency on `child` — the representation the
    drain reads, and the read-back that proves an `unblock --by` removal landed."""
    out = _gh(["api", f"repos/{{owner}}/{{repo}}/issues/{int(child)}/dependencies/blocked_by",
               "--paginate", "--jq", ".[].number"], repo)
    return [int(x) for x in out.split() if x.strip().lstrip("-").isdigit()]


def add_blocked_by(child, parent, repo="."):
    """CREATE the native `parent blocks child` dependency — a POST to `child`'s dependencies/blocked_by
    keyed by `parent`'s DATABASE id (the endpoint keys the blocker by database id, not issue number).
    The mirror of remove_blocked_by, and the representation the autorun drain's dependency gate reads.
    IDEMPOTENT: if the edge is already present it is a no-op (a rerun after a partial link never 422s on
    a duplicate). A real mutation (raises BoardReadError/RateLimitError on failure). Runs through `_gh`
    (the engine subprocess), never the Bash tool — the interlock never sees a raw `blocked_by` POST."""
    if int(parent) in blocked_by_numbers(int(child), repo):
        return
    pid = issue_database_id(int(parent), repo)
    _gh(["api", "--method", "POST",
         f"repos/{{owner}}/{{repo}}/issues/{int(child)}/dependencies/blocked_by",
         "-F", f"issue_id={pid}"], repo)


def remove_blocked_by(child, parent, repo="."):
    """DELETE the native `parent blocks child` dependency (keyed by `parent`'s DATABASE id). A real
    mutation (raises BoardReadError/RateLimitError on failure)."""
    pid = issue_database_id(int(parent), repo)
    _gh(["api", "--method", "DELETE",
         f"repos/{{owner}}/{{repo}}/issues/{int(child)}/dependencies/blocked_by/{pid}"], repo)


def blocked_by_comment_ids(child, parent, repo="."):
    """The REST comment ids on `child` whose idc-blocked-by marker names `parent` (the engine's marker
    edge, cleaned up after the native edge is removed). Reads via `gh api …/issues/<n>/comments` so the
    numeric REST id comment-delete needs is available (`gh issue view --json comments` gives only node
    ids). BoardReadError/RateLimitError propagate (resumable)."""
    out = _gh(["api", f"repos/{{owner}}/{{repo}}/issues/{int(child)}/comments", "--paginate",
               "--jq", ".[] | {id: .id, body: .body}"], repo)
    ids = []
    marker = re.compile(r"<!--\s*idc-blocked-by:\s*(.*?)\s*-->", re.S)
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        for m in marker.finditer(obj.get("body") or ""):
            try:
                rec = json.loads(m.group(1))
            except ValueError:
                continue
            if isinstance(rec, dict) and rec.get("parent") == int(parent) \
                    and rec.get("child") == int(child) and rec.get("kind") == "blocks":
                ids.append(obj.get("id"))
                break
    return [i for i in ids if i is not None]


def delete_comment(comment_id, repo="."):
    """Delete one issue comment by its REST id — the durable removal of a blocks-edge marker. A real
    mutation (raises BoardReadError/RateLimitError on failure)."""
    _gh(["api", "--method", "DELETE",
         f"repos/{{owner}}/{{repo}}/issues/comments/{int(comment_id)}"], repo)


# ── Init/Uninstall lifecycle mutation doors ─────────────────────────────────────────────────
# These commands are part of the EXISTING github tracker adapter, the Global Constraints' sanctioned
# write surface. They replace the interlock's former command-name carve-outs: every raw issue/project
# mutation is denied during an active IDC command, while this adapter performs the same operation via
# its own gh subprocess only after validating scope, then positively reads the result back. Each op is
# idempotent/resumable: a landed state is a no-op on rerun; a partial failure is retried from observed
# server state rather than assumed state.

_STATUS_OPTIONS = ["Blocked", "Todo", "In Progress", "Done"]


def _json_object(raw, what):
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as e:
        raise BoardReadError(f"{what} returned malformed JSON ({e})")
    if not isinstance(value, dict):
        raise BoardReadError(f"{what} returned a non-object JSON value")
    return value


def _project_list(owner, repo):
    data = _json_object(_gh(["project", "list", "--owner", owner, "--limit", "200",
                             "--format", "json"], repo), "project list")
    rows = data.get("projects")
    if not isinstance(rows, list):
        raise BoardReadError("project list JSON has no `projects` array")
    return rows


def _project_view(owner, project, repo):
    data = _json_object(_gh(["project", "view", str(int(project)), "--owner", owner,
                             "--format", "json"], repo), "project view")
    try:
        data["number"] = int(data["number"])
    except (KeyError, TypeError, ValueError):
        raise BoardReadError("project view did not return an integer project number")
    if data["number"] != int(project) or not data.get("id") or not data.get("title"):
        raise BoardReadError(f"project #{project} readback is incomplete or mismatched")
    return data


def ensure_project(owner, title, repo="."):
    """Reuse exactly one title match or create the project, then positively read it back."""
    matches = [p for p in _project_list(owner, repo) if p.get("title") == title]
    if len(matches) > 1:
        raise BoardWriteError(f"{len(matches)} projects are titled {title!r}; refusing an ambiguous create/reuse")
    if matches:
        try:
            num = int(matches[0]["number"])
        except (KeyError, TypeError, ValueError):
            raise BoardReadError(f"the existing {title!r} project has no integer number")
        observed = _project_view(owner, num, repo)
        if observed.get("title") != title:
            raise BoardReadError(f"project #{num} title changed during readback")
        return {"action": "skipped-existing", "number": num, "id": observed["id"],
                "title": title, "url": observed.get("url")}

    created = _json_object(_gh(["project", "create", "--owner", owner, "--title", title,
                                "--format", "json"], repo), "project create")
    try:
        num = int(created["number"])
    except (KeyError, TypeError, ValueError):
        raise BoardWriteError("project create returned no integer project number")
    observed = _project_view(owner, num, repo)
    if observed.get("title") != title:
        raise BoardWriteError(f"project #{num} readback title is {observed.get('title')!r}, expected {title!r}")
    return {"action": "created", "number": num, "id": observed["id"], "title": title,
            "url": observed.get("url")}


def _fields(owner, project, repo):
    data = _json_object(_gh(["project", "field-list", str(int(project)), "--owner", owner,
                             "--limit", "50", "--format", "json"], repo), "project field-list")
    rows = data.get("fields")
    if not isinstance(rows, list):
        raise BoardReadError("project field-list JSON has no `fields` array")
    return rows


def _one_field(owner, project, name, repo):
    matches = [f for f in _fields(owner, project, repo) if f.get("name") == name]
    if len(matches) != 1:
        raise BoardReadError(f"expected exactly one {name!r} field on project #{project}, found {len(matches)}")
    return matches[0]


def _option_names(field):
    options = field.get("options") or []
    if not isinstance(options, list):
        raise BoardReadError(f"field {field.get('name')!r} has a malformed options value")
    names = [o.get("name") for o in options if isinstance(o, dict)]
    if len(names) != len(options) or any(not isinstance(n, str) or not n for n in names):
        raise BoardReadError(f"field {field.get('name')!r} has an option without a name")
    return names


def reconcile_status(owner, project, repo="."):
    """Replace nonconforming Status options only on an observed-empty board, then read them back."""
    field = _one_field(owner, project, "Status", repo)
    current = _option_names(field)
    if current == _STATUS_OPTIONS:
        return {"action": "skipped-existing", "project": int(project), "options": current}

    info = _project_view(owner, project, repo)
    total = ((info.get("items") or {}).get("totalCount"))
    if isinstance(total, bool) or not isinstance(total, int):
        raise BoardReadError(f"project #{project} item count is unavailable; refusing destructive Status reconcile")
    if total != 0:
        raise BoardWriteError(
            f"project #{project} has {total} item(s) and nonconforming Status options; refusing to replace them")
    field_id = field.get("id")
    if not field_id:
        raise BoardReadError("Status field has no node id")
    opts = ",".join("{name:%s,color:GRAY,description:\"\"}" % json.dumps(name)
                    for name in _STATUS_OPTIONS)
    mutation = (
        "mutation{updateProjectV2Field(input:{fieldId:%s,singleSelectOptions:[%s]})"
        "{projectV2Field{... on ProjectV2SingleSelectField{id options{id name}}}}}" %
        (json.dumps(field_id), opts))
    _gh(["api", "graphql", "-f", "query=" + mutation], repo)
    observed = _one_field(owner, project, "Status", repo)
    got = _option_names(observed)
    if got != _STATUS_OPTIONS:
        raise BoardWriteError(f"Status readback is {got!r}, expected {_STATUS_OPTIONS!r}")
    return {"action": "updated", "project": int(project), "options": got}


def ensure_single_select_field(owner, project, name, options, repo="."):
    """Create one missing single-select field; never duplicate; positively read a create back."""
    wanted = [str(o).strip() for o in options if str(o).strip()]
    if not name or not wanted or len(set(wanted)) != len(wanted):
        raise BoardWriteError("ensure-field requires a name and distinct non-empty options")
    matches = [f for f in _fields(owner, project, repo) if f.get("name") == name]
    if len(matches) > 1:
        raise BoardWriteError(f"project #{project} already has duplicate {name!r} fields")
    if matches:
        if matches[0].get("dataType") not in (None, "SINGLE_SELECT"):
            raise BoardWriteError(f"existing {name!r} field is not SINGLE_SELECT")
        return {"action": "skipped-existing", "project": int(project), "field": name,
                "options": _option_names(matches[0])}

    _gh(["project", "field-create", str(int(project)), "--owner", owner, "--name", name,
         "--data-type", "SINGLE_SELECT", "--single-select-options", ",".join(wanted)], repo)
    observed = _one_field(owner, project, name, repo)
    got = _option_names(observed)
    if observed.get("dataType") not in (None, "SINGLE_SELECT") or any(v not in got for v in wanted):
        raise BoardWriteError(f"field {name!r} readback did not contain the requested single-select options")
    return {"action": "created", "project": int(project), "field": name, "options": got}


def _linked_project_numbers(repository, repo):
    try:
        owner, name = repository.split("/", 1)
    except ValueError:
        raise BoardWriteError("--repository must be OWNER/REPO")
    if not owner or not name or "/" in name:
        raise BoardWriteError("--repository must be exactly OWNER/REPO")
    query = ("query($owner:String!,$name:String!){repository(owner:$owner,name:$name)"
             "{projectsV2(first:100){nodes{number}}}}")
    data = _json_object(_gh(["api", "graphql", "-f", "query=" + query,
                             "-f", "owner=" + owner, "-f", "name=" + name], repo),
                        "repository project-link readback")
    try:
        nodes = data["data"]["repository"]["projectsV2"]["nodes"]
        return [int(n["number"]) for n in nodes]
    except (KeyError, TypeError, ValueError):
        raise BoardReadError(f"could not read linked projects for {repository}")


def ensure_project_link(owner, project, repository, repo="."):
    """Link a project to exactly one repository, with before/after readback."""
    _project_view(owner, project, repo)  # verify the requested project first
    if int(project) in _linked_project_numbers(repository, repo):
        return {"action": "skipped-existing", "project": int(project), "repository": repository}
    _gh(["project", "link", str(int(project)), "--owner", owner, "--repo", repository], repo)
    if int(project) not in _linked_project_numbers(repository, repo):
        raise BoardWriteError(f"project #{project} is still not linked to {repository} after the write")
    return {"action": "linked", "project": int(project), "repository": repository}


def _issue_state(num, repo):
    state = _gh(["issue", "view", str(int(num)), "--json", "state", "--jq", ".state"], repo).strip().upper()
    if state not in ("OPEN", "CLOSED"):
        raise BoardReadError(f"issue #{num} returned unknown state {state!r}")
    return state


def _current_repository(repo):
    """The exact OWNER/REPO selected by ``repo``; lifecycle issue closes never cross this boundary."""
    value = _gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], repo).strip()
    if not re.match(r"^[^/\s]+/[^/\s]+$", value):
        raise BoardReadError("could not resolve the lifecycle repository as OWNER/REPO")
    return value


def close_project_issues(owner, project, repo="."):
    """Close only issue-backed items on the requested project AND selected repo; verify every close."""
    items = fetch_items(owner, int(project), repo)
    target_repo = _current_repository(repo)
    nums, external = [], []
    for item in items:
        content = item.get("content") or {}
        if content.get("type") == "Issue" and isinstance(content.get("number"), int):
            content_repo = content.get("repository")
            if not isinstance(content_repo, str) or not content_repo:
                raise BoardReadError(
                    f"project #{project} issue #{content['number']} has no repository identity; refusing closes")
            if content_repo != target_repo:
                external.append(f"{content_repo}#{content['number']}")
                continue
            if content["number"] not in nums:
                nums.append(content["number"])
    states = {num: _issue_state(num, repo) for num in nums}  # scope/read preflight before any mutation
    closed, skipped = [], []
    for num in nums:
        if states[num] == "CLOSED":
            skipped.append(num)
            continue
        _gh(["issue", "close", str(num)], repo)
        if _issue_state(num, repo) != "CLOSED":
            raise BoardWriteError(f"issue #{num} did not read back CLOSED")
        closed.append(num)
    return {"action": "closed-project-issues", "closed": closed, "skipped_closed": skipped,
            "skipped_external": external}


def delete_project(owner, project, confirmation, repo="."):
    """Permanently delete exactly the confirmed project and verify its captured node id is absent."""
    listed = [p for p in _project_list(owner, repo) if str(p.get("number")) == str(int(project))]
    if not listed:
        return {"action": "skipped-absent", "number": int(project)}
    info = _project_view(owner, project, repo)
    if str(confirmation) not in (str(int(project)), info["title"]):
        raise BoardWriteError("delete confirmation must exactly match the project number or title")
    node_id = info["id"]
    _gh(["project", "delete", str(int(project)), "--owner", owner], repo)
    query = "query($id:ID!){node(id:$id){id}}"
    data = _json_object(_gh(["api", "graphql", "-f", "query=" + query, "-f", "id=" + node_id], repo),
                        "project delete readback")
    try:
        node = data["data"]["node"]
    except (KeyError, TypeError):
        raise BoardReadError("project delete readback did not return data.node")
    if node is not None:
        raise BoardWriteError(f"project #{project} node {node_id} still exists after delete")
    return {"action": "deleted", "number": int(project), "id": node_id, "title": info["title"]}


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


def _read_main():
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


_LIFECYCLE_COMMANDS = {
    "ensure-project", "reconcile-status", "ensure-field", "ensure-link",
    "close-project-issues", "delete-project",
}


def _lifecycle_main(argv):
    ap = argparse.ArgumentParser(
        description="Validated, read-back-verified Init/Uninstall GitHub lifecycle writes.")
    sub = ap.add_subparsers(dest="command", required=True)

    def common(name, help_text, needs_project=True):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--repo", default=".", help="repo dir the gh calls run in")
        p.add_argument("--owner", required=True)
        if needs_project:
            p.add_argument("--project", required=True, type=int)
        return p

    p = common("ensure-project", "reuse one exact-title project or create + read back", False)
    p.add_argument("--title", required=True)
    p.set_defaults(run=lambda a: ensure_project(a.owner, a.title, a.repo))

    p = common("reconcile-status", "empty-board-gated built-in Status option reconcile")
    p.set_defaults(run=lambda a: reconcile_status(a.owner, a.project, a.repo))

    p = common("ensure-field", "create one missing single-select field + read back")
    p.add_argument("--name", required=True)
    p.add_argument("--option", action="append", required=True,
                   help="one single-select option; repeat for each option")
    p.set_defaults(run=lambda a: ensure_single_select_field(a.owner, a.project, a.name, a.option, a.repo))

    p = common("ensure-link", "idempotently link the project to OWNER/REPO + read back")
    p.add_argument("--repository", required=True)
    p.set_defaults(run=lambda a: ensure_project_link(a.owner, a.project, a.repository, a.repo))

    p = common("close-project-issues", "close only issue-backed items on the verified project")
    p.set_defaults(run=lambda a: close_project_issues(a.owner, a.project, a.repo))

    p = common("delete-project", "typed-confirmed permanent project delete + node absence readback")
    p.add_argument("--confirm", required=True)
    p.set_defaults(run=lambda a: delete_project(a.owner, a.project, a.confirm, a.repo))

    args = ap.parse_args(argv)
    try:
        receipt = args.run(args)
    except RateLimitError as e:
        emit_rate_limit_verdict(e)
    except BoardReadError as e:
        sys.stderr.write(f"idc-gh-board: {e}\n")
        sys.exit(2)
    json.dump(receipt, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(0)


def main():
    # Preserve the long-shipped flag-first board-reader CLI while adding explicit lifecycle
    # subcommands. A first token not in this fixed set follows the legacy parser unchanged.
    if len(sys.argv) > 1 and sys.argv[1] in _LIFECYCLE_COMMANDS:
        _lifecycle_main(sys.argv[1:])
    _read_main()


if __name__ == "__main__":
    main()
