# scripts/idc_board_util.py
"""
Board loading utilities shared by janitor, replay, and other scripts.
"""
import json
import os
import sys

def load_board_github(owner, project, repo):
    """All issue-backed board items via the paginating reader. Returns list of
    {number,status,stage,title,item_id}. Exits 2 on an unreadable board (fail-closed, no hollow clean)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_gh_board  # noqa: E402 — github-only dependency, imported lazily
    try:
        items = idc_gh_board.fetch_items(owner, project, repo)
    except idc_gh_board.BoardReadError as e:
        sys.stderr.write(f"idc-board-util: could not read the github board: {e}\\n")
        sys.exit(2)
    except Exception as e:  # noqa: BLE001 — ANY unexpected board-read failure fail-CLOSES to exit 2
        sys.stderr.write(f"idc-board-util: unexpected error reading the github board: {e}\\n")
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
    """Read the filesystem TRACKER.md state block → list of {number,status,stage,title}.

    Reuses `idc_autorun_drain.load_filesystem` — the ONE owner of the state-block fence + the
    fail-closed corruption contract."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_autorun_drain  # noqa: E402 — sibling helper, imported lazily
    issues = idc_autorun_drain.load_filesystem(path)  # exits 2 itself on any corruption
    return [{"number": it["number"], "status": it.get("status"),
             "stage": it.get("stage"), "title": it.get("title") or ""} for it in issues]
