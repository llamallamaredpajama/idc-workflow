#!/usr/bin/env python3
"""Replay IDC's canonical transition journal and compare it with the current board.

The transition engine appends best-effort NDJSON records to
``docs/workflow/transition-journal.ndjson``.  Replay is deliberately fail-closed: an unreadable or
malformed journal is indeterminate (exit 2), while a readable journal that disagrees with the board is
a real divergence (exit 1).
"""
import argparse
import glob
import json
import os
import re
import sys

JOURNAL_REL = os.path.join("docs", "workflow", "transition-journal.ndjson")
_ITEM_RE = re.compile(r"#(\d+)\b")
_ARROW_RE = re.compile(r"->\s*(.+)$")


def _coerce_item_id(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def journal_item_id(entry):
    """Return the issue number named by a journal entry, if recoverable.

    New Phase-4 records carry a structured ``item`` field.  Older journal-spine records only carried
    prose in ``what``; parse ``#<n>`` from operation-shaped lines only, so a create title mentioning
    ``#123`` is not misread as the created issue.
    """
    item_id = _coerce_item_id(entry.get("item"))
    if item_id is not None:
        return item_id
    what = str(entry.get("what") or "")
    op = str(entry.get("op") or "")
    ref_ops = ("move", "claim", "unblock", "close", "retire", "link")
    ref_prefixes = tuple(f"{name} #" for name in ref_ops)
    if op not in ref_ops and not what.startswith(ref_prefixes):
        return None
    match = _ITEM_RE.search(what)
    return int(match.group(1)) if match else None


def _legacy_to_state(entry):
    """Best-effort target-state extraction for old unstructured journal-spine records."""
    what = str(entry.get("what") or "")
    op = str(entry.get("op") or "")
    state = {}
    status_ops = ("move", "claim", "unblock", "close", "retire")
    status_prefixes = tuple(f"{name} #" for name in status_ops)
    if op not in status_ops and not what.startswith(status_prefixes):
        # `link #parent -> #child` has an arrow, but it is not a Status transition.
        return state

    arrow = _ARROW_RE.search(what)
    if arrow:
        state["status"] = arrow.group(1).strip()
    elif op in ("close", "retire") or what.startswith(("close #", "retire #")):
        state["status"] = "Done"

    return state


def _entry_to_state(entry):
    to_state = entry.get("to")
    if isinstance(to_state, dict):
        state = {}
        if "stage" in to_state:
            state["stage"] = to_state.get("stage")
        if "status" in to_state:
            state["status"] = to_state.get("status")
        return state
    return _legacy_to_state(entry)


def _journal_paths(journal_path):
    """Replay archived terminal segments first, then the active journal segment."""
    workflow_dir = os.path.dirname(os.path.abspath(journal_path))
    archive_dir = os.path.join(workflow_dir, "journal-archive")
    paths = sorted(glob.glob(os.path.join(archive_dir, "*.ndjson"))) if os.path.isdir(archive_dir) else []
    paths.append(journal_path)
    return paths


def reconstruct_state_from_journal(journal_path):
    """Read NDJSON journal segments and reconstruct the final known state for each item.

    Returns ``(state, None)`` on success.  Returns ``(None, reason)`` when the journal cannot be trusted
    (missing or malformed), because a replay that skips corruption can produce a false clean result.
    """
    expected_state = {}
    if not os.path.exists(journal_path):
        print(f"Journal file not found: {journal_path}", file=sys.stderr)
        return None, "journal_not_found"

    for path in _journal_paths(journal_path):
        try:
            fh = open(path, "r", encoding="utf-8")
        except OSError as exc:
            print(f"Journal file unreadable: {path}: {exc}", file=sys.stderr)
            return None, "journal_unreadable"

        with fh:
            for line_num, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError as exc:
                    msg = f"Malformed journal line {line_num} in {path}: {exc.msg}"
                    print(msg, file=sys.stderr)
                    return None, msg
                if not isinstance(entry, dict):
                    msg = f"Malformed journal line {line_num} in {path}: expected object"
                    print(msg, file=sys.stderr)
                    return None, msg

                item_id = journal_item_id(entry)
                if item_id is None:
                    # A create-ticket line from the old journal spine did not include the created issue
                    # number. It cannot contribute to replay, but later structured/move/close lines for
                    # the same item can still establish state.
                    continue

                expected_state.setdefault(item_id, {})
                state = _entry_to_state(entry)
                expected_state[item_id].update(state)

    return expected_state, None


# Board loading is intentionally local to stay inside Issue #142's admitted file surface.  The janitor
# owns the same helpers in its own file; this script does not introduce a new production helper module.
def load_board_github(owner, project, repo):
    """All issue-backed board items via the paginating reader."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_gh_board  # noqa: E402 — github-only dependency, imported lazily
    try:
        items = idc_gh_board.fetch_items(owner, project, repo)
    except idc_gh_board.BoardReadError as exc:
        sys.stderr.write(f"idc-journal-replay: could not read the github board: {exc}\n")
        sys.exit(2)
    except Exception as exc:  # noqa: BLE001 — fail closed on unexpected board-read failure
        sys.stderr.write(f"idc-journal-replay: unexpected error reading the github board: {exc}\n")
        sys.exit(2)
    board = []
    for it in items:
        content = it.get("content") or {}
        number = content.get("number")
        if number is None:
            continue
        board.append({
            "number": number,
            "status": it.get("status"),
            "stage": it.get("stage"),
            "title": content.get("title") or "",
            "item_id": it.get("id"),
        })
    return board


def load_board_filesystem(path):
    """Read the filesystem TRACKER.md state block → list of {number,status,stage,title}."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_autorun_drain  # noqa: E402 — sibling helper, imported lazily
    issues = idc_autorun_drain.load_filesystem(path)  # exits 2 itself on corruption
    return [{"number": it["number"], "status": it.get("status"),
             "stage": it.get("stage"), "title": it.get("title") or ""} for it in issues]


def get_actual_state(args):
    """Load the actual board state from the specified backend."""
    if args.backend == "filesystem":
        if not args.tracker:
            print("Error: --tracker is required for filesystem backend.", file=sys.stderr)
            return None
        board = load_board_filesystem(args.tracker)
    elif args.backend == "github":
        if not args.owner or not args.project:
            print("Error: --owner and --project are required for github backend.", file=sys.stderr)
            return None
        board = load_board_github(args.owner, args.project, ".")
    else:
        return None

    actual_state = {}
    for item in board:
        item_id = item.get("number")
        if item_id is not None:
            actual_state[item_id] = {
                "stage": item.get("stage") or "",
                "status": item.get("status"),
            }
    return actual_state


def compare_states(expected, actual):
    """Compare expected and actual states; return human-readable differences."""
    diffs = []
    all_item_ids = set(expected.keys()) | set(actual.keys())

    for item_id in sorted(all_item_ids):
        expected_item = expected.get(item_id)
        actual_item = actual.get(item_id)

        if expected_item is None:
            diffs.append(f"Item #{item_id}: present on board but not in journal history.")
            continue
        if actual_item is None:
            diffs.append(f"Item #{item_id}: in journal history but not on board.")
            continue

        if "stage" in expected_item and expected_item.get("stage") != actual_item.get("stage"):
            diffs.append(
                f"Item #{item_id} STAGE mismatch: journal says '{expected_item.get('stage')}', "
                f"board says '{actual_item.get('stage')}'"
            )
        if "status" in expected_item and expected_item.get("status") != actual_item.get("status"):
            diffs.append(
                f"Item #{item_id} STATUS mismatch: journal says '{expected_item.get('status')}', "
                f"board says '{actual_item.get('status')}'"
            )
    return diffs


def main():
    parser = argparse.ArgumentParser(description="Rebuild expected board state from journal and diff against actual.")
    parser.add_argument("--journal", default=JOURNAL_REL, help="Path to transition journal file.")
    parser.add_argument("--backend", choices=("filesystem", "github"), default="filesystem", help="Tracker backend.")
    parser.add_argument("--tracker", help="TRACKER.md path (filesystem backend).")
    parser.add_argument("--owner", help="Project owner (github backend).")
    parser.add_argument("--project", help="Project number (github backend).")
    args = parser.parse_args()

    expected_state, error = reconstruct_state_from_journal(args.journal)
    if error:
        sys.exit(2)

    actual_state = get_actual_state(args)
    if actual_state is None:
        sys.exit(2)

    diffs = compare_states(expected_state, actual_state)

    if not diffs:
        print("OK: Journal replay matches current board state.", file=sys.stdout)
        sys.exit(0)

    print("FAIL: Journal replay detected divergence from board state:", file=sys.stderr)
    for diff in diffs:
        print(f"- {diff}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
