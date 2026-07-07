#!/usr/bin/env python3
import argparse
import json
import sys
import os

# Allow importing from sibling scripts
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from idc_git_janitor import load_board_filesystem, load_board_github

def reconstruct_state_from_journal(journal_path):
    """Reads an NDJSON journal and reconstructs the final state of each item."""
    expected_state = {}
    if not os.path.exists(journal_path):
        print(f"Journal file not found: {journal_path}", file=sys.stderr)
        return None, "journal_not_found"

    with open(journal_path, "r") as f:
        for line_num, line in enumerate(f, 1):
            try:
                entry = json.loads(line)
                op = entry.get("op")
                if op == "transition":
                    item_id = entry.get("item")
                    to_state = entry.get("to")
                    if item_id is not None and to_state is not None:
                        if item_id not in expected_state:
                            expected_state[item_id] = {}
                        expected_state[item_id]["stage"] = to_state.get("stage")
                        expected_state[item_id]["status"] = to_state.get("status")
                elif op == "create": # Assumes items can be created
                    item_id = entry.get("item")
                    if item_id is not None:
                        expected_state[item_id] = {"stage": None, "status": None}

            except json.JSONDecodeError:
                print(f"Skipping malformed line {line_num} in journal: {line.strip()}", file=sys.stderr)
                continue
    return expected_state, None

def get_actual_state(args):
    """Loads the actual board state from the specified backend."""
    if args.backend == "filesystem":
        if not args.tracker:
            print("Error: --tracker is required for filesystem backend.", file=sys.stderr)
            return None
        board = load_board_filesystem(args.tracker)
    elif args.backend == "github":
        if not args.owner or not args.project:
            print("Error: --owner and --project are required for github backend.", file=sys.stderr)
            return None
        # Note: idc_git_janitor.load_board_github takes repo path as 3rd arg.
        # Assuming current dir is ok.
        board = load_board_github(args.owner, args.project, ".")
    else:
        return None

    actual_state = {}
    for item in board:
        item_id = item.get("number")
        if item_id is not None:
            actual_state[item_id] = {
                "stage": item.get("stage"),
                "status": item.get("status")
            }
    return actual_state

def compare_states(expected, actual):
    """Compares expected and actual states and returns a list of differences."""
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

        if expected_item.get("stage") != actual_item.get("stage"):
            diffs.append(
                f"Item #{item_id} STAGE mismatch: journal says '{expected_item.get('stage')}', "
                f"board says '{actual_item.get('stage')}'"
            )
        if expected_item.get("status") != actual_item.get("status"):
            diffs.append(
                f"Item #{item_id} STATUS mismatch: journal says '{expected_item.get('status')}', "
                f"board says '{actual_item.get('status')}'"
            )
    return diffs

def main():
    parser = argparse.ArgumentParser(description="Rebuild expected board state from journal and diff against actual.")
    parser.add_argument("--journal", default=".idc/journal.ndjson", help="Path to journal file.")
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
    else:
        print("FAIL: Journal replay detected divergence from board state:", file=sys.stderr)
        for d in diffs:
            print(f"- {d}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
