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
      (exit 0 = ok; exit 2 = any gh / parse failure, with a stderr diagnostic).
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


def _gh(args, repo):
    """Run `gh <args>` in `repo`; return stdout. Raise BoardReadError on missing gh or non-zero."""
    try:
        p = subprocess.run(["gh"] + args, cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError) as e:
        raise BoardReadError(f"gh invocation failed: {e}")
    if p.returncode != 0:
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
        page = conn.get("pageInfo") or {}
        if page.get("hasNextPage"):
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


def main():
    ap = argparse.ArgumentParser(
        description="Read ALL items of a GitHub Projects v2 board (true cursor pagination).")
    ap.add_argument("--owner", required=True, help="project owner login (user or org)")
    ap.add_argument("--project", required=True, help="integer project number")
    ap.add_argument("--repo", default=".", help="repo dir to run gh in (default: cwd)")
    args = ap.parse_args()
    try:
        items = fetch_items(args.owner, args.project, os.path.abspath(args.repo))
    except BoardReadError as e:
        sys.stderr.write(f"idc-gh-board: {e}\n")
        sys.exit(2)
    json.dump({"items": items}, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


if __name__ == "__main__":
    main()
