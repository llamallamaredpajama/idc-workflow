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
    ref_ops = ("move", "claim", "unblock", "close", "dispose", "retire", "link")
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
    status_ops = ("move", "claim", "unblock", "close", "dispose", "retire")
    status_prefixes = tuple(f"{name} #" for name in status_ops)
    if op not in status_ops and not what.startswith(status_prefixes):
        # `link #parent -> #child` has an arrow, but it is not a Status transition.
        return state

    arrow = _ARROW_RE.search(what)
    if arrow:
        # A dispose `what` ends "… -> Done [drained]"; strip a trailing "[disposition]" tag so the
        # legacy-path status is the bare "Done" (new dispose records carry structured `to` anyway).
        state["status"] = re.sub(r"\s*\[[^\]]*\]\s*$", "", arrow.group(1)).strip()
    elif op in ("close", "dispose", "retire") or what.startswith(("close #", "dispose #", "retire #")):
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


_CREATE_OPS = ("create-ticket", "create-pointer", "recirculate-intake")


def earliest_journaled_create(journal_path):
    """Smallest item number among journaled create records, or None when there is none.

    Item numbers are monotonic on both backends, so this is a DERIVED adoption watermark: any board
    item numbered above it was created after create-journaling began and must therefore have journal
    history — a board-only item above the watermark means its history was lost (truncation) or the
    create bypassed the engine. Items below the watermark predate the journal (legacy) and are
    tolerated. Returns None (no watermark → tolerate everything) on any read problem: corruption is
    reconstruct_state_from_journal's fail-closed job, not this helper's.
    """
    watermark = None
    for path in _journal_paths(journal_path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        return None
                    if not isinstance(entry, dict) or entry.get("op") not in _CREATE_OPS:
                        continue
                    item_id = _coerce_item_id(entry.get("item"))
                    if item_id is not None and (watermark is None or item_id < watermark):
                        watermark = item_id
        except (OSError, UnicodeDecodeError):
            return None
    return watermark


def scan_journal_strict(journal_path):
    """``(entries, error)``: every parsed record across archived + live segments, FAIL-CLOSED.

    The dispose corroboration guards (idc_transition) consume this: a corrupt or unreadable journal
    must DENY a corroboration-guarded disposition (``error`` is a reason string), never silently
    tolerate it — unlike ``earliest_journaled_create``, whose lenient ``None`` is calibrated for
    replay's own division of labor (corruption is reconstruct's job there). A journal that simply
    does not exist yet is NOT an error: ``([], None)`` — a pre-adoption board (journaling has not
    begun) is the caller's principled legacy carve-out, not damage.
    """
    # Take the journal's STABLE sidecar lock (`<journal>.lock` — the shared convention with
    # journal_append and the janitor's rotation) across the path snapshot AND all reads: an
    # unlocked scan racing a rotation's read-then-os.replace can miss records mid-move between the
    # live segment and the archive, see no creates, and hand the caller the pre-journal carve-out —
    # a fail-OPEN guard (codex round-9 P1). Unlike the fail-soft appender, a guard's lock failure
    # DENIES (returns an error), never proceeds unlocked. LOCK_SH: scans may share; rotation and
    # appends hold LOCK_EX and are excluded.
    #
    # But a READ-ONLY scan must never CREATE the lock sidecar (mode "a" would MINT it — a doctor Row 9
    # `--journal` read mutating the governed repo, and littering older installs whose gitignore
    # predates the lock rule; codex round-16 P2). So open it "r" (no create):
    #   * lock EXISTS → a writer has run — take LOCK_SH (the round-9 discipline; waits out a rotation).
    #   * lock ABSENT → NO writer has created it yet (journal_append `open(…, "a")` and the janitor
    #     rotation `open(…, "w")` both MINT it as their FIRST act, before touching the journal). Read
    #     unlocked, then RE-CHECK: a writer that starts mid-scan mints the lock first, so the lock
    #     APPEARING is the race signal. On it, loop to read through the now-present shared lock (which
    #     blocks until the writer finishes). No mint; no fail-open — a legitimate lockless legacy board
    #     still reads (never denied), so the dispose corroboration guards keep working on upgraded repos.
    import fcntl
    if not os.path.isdir(os.path.dirname(journal_path)):
        return [], None   # no workflow dir → no journal, and no rotation to race
    lock_path = journal_path + ".lock"
    for _ in (1, 2):
        try:
            lock_fh = open(lock_path, "r")
        except FileNotFoundError:
            lock_fh = None   # absent lock → the unlocked read + lock-appearance race check below
        except OSError as exc:
            return None, f"journal sidecar lock unavailable: {exc}"
        if lock_fh is not None:
            try:
                try:
                    fcntl.flock(lock_fh.fileno(), fcntl.LOCK_SH)
                except OSError as exc:
                    return None, f"journal sidecar lock unavailable: {exc}"
                return _read_journal_segments(journal_path)
            finally:
                lock_fh.close()   # closing the fd releases the flock
        entries, err = _read_journal_segments(journal_path)
        if not os.path.exists(lock_path):
            # No writer intervened during the unlocked read → trust its result: the entries, or a
            # GENUINE corruption error (not a transient partial line, since no writer was active).
            return entries, err
        # A writer minted the lock mid-scan (its first act): the unlocked read may have raced a
        # rotation's record-move (fail-open, round-9) OR read a partial line from an in-flight append,
        # so its result — entries OR error — is untrustworthy. Loop to read through the now-present
        # shared lock (which blocks until the writer finishes), then trust that consistent read.
    return None, ("the transition journal was being written concurrently (its lock sidecar appeared "
                  "mid-scan) — indeterminate; re-run once the writer settles")


def _read_journal_segments(journal_path):
    """Parse every record across the archived + live segments, FAIL-CLOSED → ``(entries, error)``.
    The read primitive ONLY — the caller establishes the sidecar-lock discipline (a held LOCK_SH, or
    the absent-lock lock-appearance race check in scan_journal_strict)."""
    entries = []
    paths = [p for p in _journal_paths(journal_path) if os.path.exists(p)]
    if not paths:
        return [], None
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line_num, line in enumerate(fh, 1):
                    if not line.strip():
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError as exc:
                        return None, f"malformed journal line {line_num} in {path}: {exc.msg}"
                    if not isinstance(entry, dict):
                        return None, f"malformed journal line {line_num} in {path}: expected object"
                    entries.append(entry)
        except (OSError, UnicodeDecodeError) as exc:
            return None, f"journal segment unreadable: {path}: {exc}"
    return entries, None


def journal_adopted(entries):
    """True iff journaling has BEGUN: ANY create record exists — numbered or not. A numberless
    github create (the issue-number read-back failed; the record carries only project_item_id)
    still marks adoption: treating a none-because-numberless watermark as pre-journal would grant
    the legacy carve-out to EVERY item and fail the corroboration guard open (codex round-8 P2)."""
    return any(isinstance(e, dict) and e.get("op") in _CREATE_OPS for e in entries)


def has_numberless_create(entries):
    """True iff any create record carries NO resolvable item number (the github read-back gap: the
    record has only project_item_id). The NUMBERED watermark is then unreliable as an adoption
    lower bound — the true first create may be the numberless one, so items numbered between it and
    the first NUMBERED create would be misclassified as pre-journal legacy. Callers must disable
    the below-watermark carve-out whenever this is true (fail closed; codex round-9 P1)."""
    return any(isinstance(e, dict) and e.get("op") in _CREATE_OPS and journal_item_id(e) is None
               for e in entries)


def watermark_from(entries):
    """The adoption watermark over already-scanned entries: smallest item number among create
    records, or None when no NUMBERED create is journaled (see earliest_journaled_create for the
    semantics — this is the strict-scan twin so corroboration callers do not re-read the segments).
    None does NOT by itself mean pre-journal: check journal_adopted first (numberless creates)."""
    watermark = None
    for entry in entries:
        if isinstance(entry, dict) and entry.get("op") in _CREATE_OPS:
            item_id = _coerce_item_id(entry.get("item"))
            if item_id is not None and (watermark is None or item_id < watermark):
                watermark = item_id
    return watermark


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
            try:
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

                    state = _entry_to_state(entry)
                    if not state:
                        # A FIELD-ONLY record (a `set-field` Wave/Phase/Domain write, or a `link`
                        # edge) carries NEITHER to_stage NOR to_status, so it establishes no Stage/
                        # Status expectation. It must NOT seed an expected-state entry (round-5 Fix
                        # 3): an empty `{item: {}}` seed compares clean against ANY board item, so a
                        # field-only write for an item with NO create/transition history would mask
                        # the missing history and look falsely reconciled. Skipping it leaves such an
                        # item ABSENT from expected state → reported as a real divergence (present on
                        # board, not in journal history). A record that DOES carry Stage/Status still
                        # seeds/updates the entry below, so a genuinely-created item is unaffected.
                        continue

                    expected_state.setdefault(item_id, {})
                    expected_state[item_id].update(state)
            except UnicodeDecodeError as exc:
                # Undecodable bytes raise during line iteration, BEFORE json.loads — without this
                # the replay crashes unclassified instead of the documented fail-closed result.
                msg = f"Malformed journal segment {path}: undecodable bytes: {exc}"
                print(msg, file=sys.stderr)
                return None, msg

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
