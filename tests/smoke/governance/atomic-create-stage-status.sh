#!/bin/bash
# atomic-create-stage-status.sh — governance scenario: board-item CREATE is atomic in Stage+Status.
#
# The invariant this proves (both backends): a create can NEVER yield a Stage-without-Status item —
# Stage and Status are set together, and a partial failure leaves NO half-created item on the board.
# That empty-Status shape is exactly the #255/#256 bug that blinds a downstream detector.
#
# Two halves, both red-when-broken:
#   (A) FILESYSTEM — scripts/idc_tracker_fs.py::op_create builds the whole issue (always writing a
#       non-empty Status, default Todo, AND the requested Stage) and does ONE atomic save(). We seed
#       via the shared lib.sh helper at a chosen Stage WITHOUT a --status and assert Status came back
#       non-empty (Todo). Break op_create's Status write → this half FAILs.
#   (B) GITHUB — scripts/idc_gh_board.py::create_item creates the issue, adds it to the board, then
#       sets Stage AND Status, DISCARDING (delete board item + close issue) on any partial failure.
#       github is not exercisable hermetically (no live gh), so it is UNIT-TESTED in-process by
#       monkeypatching the module's single gh seam (`_gh`) — the create/add/Stage steps succeed but
#       the Status-set step FAILs, and we assert the helper discarded and raised (never left a
#       Stage-without-Status item). Remove the discard/Status-set logic → this half FAILs.
#
# Usage: bash tests/smoke/governance/atomic-create-stage-status.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

# ── (A) FILESYSTEM: a create with a Stage but no explicit Status still yields a non-empty Status ──
T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
trap 'rm -rf "$(dirname "$T")"' EXIT

# Consideration pointer, --status OMITTED → must default to a non-empty Todo (never a blank Status).
n1="$(gov_seed_item "$T" --title 'p' --stage Consideration)" \
  || fail "fs create (Consideration, no --status) failed"
[ -n "$n1" ] || fail "fs create returned an empty issue number"
[ "$(gov_field "$T" "$n1" Stage)"  = "Consideration" ] || fail "fs Stage did not round-trip to Consideration"
s1="$(gov_field "$T" "$n1" Status)"
[ -n "$s1" ]      || fail "fs create left an EMPTY Status with a set Stage (#255/#256 shape)"
[ "$s1" = "Todo" ] || fail "fs create default Status was $s1, expected Todo"

# Recirculation pointer, --status OMITTED → same invariant on the other non-Buildable Stage.
n2="$(gov_seed_item "$T" --title 'r' --stage Recirculation)" \
  || fail "fs create (Recirculation, no --status) failed"
[ "$(gov_field "$T" "$n2" Stage)"  = "Recirculation" ] || fail "fs Stage did not round-trip to Recirculation"
[ -n "$(gov_field "$T" "$n2" Status)" ] || fail "fs create left an EMPTY Status with a set Stage (Recirculation)"

echo "  ok (A) filesystem: create --stage <X> (no --status) always yields a non-empty Status"

# ── (B) GITHUB: create_item sets Stage+Status atomically and DISCARDS on a partial (Status) failure ──
SCRIPTS="$GOV_PLUGIN/scripts"
python3 - "$SCRIPTS" <<'PY' || fail "github create_item unit tests failed (see assertion above)"
import json
import sys
sys.path.insert(0, sys.argv[1])
import idc_gh_board as B

# Fake ids the stubbed gh "returns"; the real gh call shapes are mirrored so create_item is exercised
# exactly as in production — only the process boundary (_gh) is replaced.
PNODE = "PVT_test"
FIELDS = {"fields": [
    {"name": "Stage",  "id": "FID_stage",  "options": [
        {"name": "Consideration", "id": "OID_consideration"},
        {"name": "Recirculation", "id": "OID_recirc"}]},
    {"name": "Status", "id": "FID_status", "options": [
        {"name": "Todo", "id": "OID_todo"},
        {"name": "Done", "id": "OID_done"}]},
]}
URL = "https://github.com/o/r/issues/42"


def make_stub(mode="ok"):
    """Build a _gh replacement + a call log, driving one of several partial-failure `mode`s:
      ok                     — every step succeeds.
      status_fail            — the item-edit that sets Status raises (a partial AFTER Stage was set).
      status_ratelimit       — the Status-set raises a RateLimitError (a mid-create throttle).
      empty_item_id          — item-add returns an empty id (no board-item handle to delete).
      status_fail_delete_fail — Status-set fails AND the discard's own item-delete then fails too.
    The item-delete branch asserts the EXACT gh argv: `project item-delete <number> --owner <o> --id
    <item>` — there is NO --project-id flag on item-delete (only item-edit). A wrong invocation raises
    AssertionError (NOT a BoardReadError), so create_item cannot swallow it → the scenario FAILs."""
    calls = []

    def stub(args, repo):
        calls.append(list(args))
        verb = (args[0], args[1]) if len(args) > 1 else (args[0], "")
        if verb == ("project", "view"):
            return PNODE + "\n"
        if verb == ("project", "field-list"):
            return json.dumps(FIELDS)
        if verb == ("issue", "create"):
            return URL + "\n"
        if verb == ("project", "item-add"):
            return "\n" if mode == "empty_item_id" else "PVTI_item\n"
        if verb == ("project", "item-edit"):
            fid = args[args.index("--field-id") + 1]
            if fid == "FID_status":
                if mode in ("status_fail", "status_fail_delete_fail"):
                    raise B.BoardReadError("simulated Status-set failure")
                if mode == "status_ratelimit":
                    raise B.RateLimitError("1999999999")
            return ""
        if verb == ("project", "item-delete"):
            if "--project-id" in args:
                raise AssertionError(f"item-delete has NO --project-id flag: {args}")
            expected = ["project", "item-delete", "1", "--owner", "o", "--id", "PVTI_item"]
            if list(args) != expected:
                raise AssertionError(f"item-delete argv {args} != expected {expected}")
            if mode == "status_fail_delete_fail":
                raise B.BoardReadError("simulated item-delete failure")
            return ""
        if verb == ("issue", "close"):
            return ""
        raise AssertionError(f"unexpected gh call: {args}")

    return stub, calls


def field_set(calls, fid):
    """True iff an item-edit call set the given field id."""
    return any(c[:2] == ["project", "item-edit"] and "--field-id" in c
               and c[c.index("--field-id") + 1] == fid for c in calls)


def called(calls, verb):
    return any(c[:2] == list(verb) for c in calls)


orig = B._gh
try:
    # ---- SUCCESS path: every step ok → returns the item id, and BOTH Stage and Status were set. ----
    stub, calls = make_stub("ok")
    B._gh = stub
    iid = B.create_item("o", "1", ".", "t", "b", "Consideration", "Todo")
    if iid != "PVTI_item":
        print(f"FAIL: create_item returned {iid!r}, expected 'PVTI_item'"); sys.exit(1)
    if not field_set(calls, "FID_stage"):
        print("FAIL: success path never set Stage"); sys.exit(1)
    if not field_set(calls, "FID_status"):
        print("FAIL: success path never set Status (would leave a Stage-without-Status item)"); sys.exit(1)
    if called(calls, ("issue", "close")) or called(calls, ("project", "item-delete")):
        print("FAIL: success path wrongly discarded the item"); sys.exit(1)

    # ---- PARTIAL FAILURE: Stage set, Status-set FAILS → helper must DISCARD and RAISE. ----
    # The stub asserts the EXACT item-delete argv, so a wrong `gh` invocation (e.g. the non-existent
    # --project-id flag) raises AssertionError here and FAILs the scenario (B1 red-when-broken).
    stub, calls = make_stub("status_fail")
    B._gh = stub
    try:
        B.create_item("o", "1", ".", "t", "b", "Consideration", "Todo")
        print("FAIL: create_item did not raise on a partial (Status-set) failure"); sys.exit(1)
    except B.BoardReadError:
        pass  # BoardWriteError is a BoardReadError subclass — a fail-closed caller still catches it
    # The Stage-set landed but Status-set failed: the item MUST have been discarded (both the board
    # item deleted AND the backing issue closed), or a Stage-without-Status item would survive.
    if not called(calls, ("project", "item-delete")):
        print("FAIL: partial failure did not delete the half-created board item"); sys.exit(1)
    if not called(calls, ("issue", "close")):
        print("FAIL: partial failure did not close the backing issue"); sys.exit(1)

    # ---- M2: a RATE-LIMIT mid-create must propagate as RateLimitError (type + .reset), NOT be
    #      flattened to a hard BoardWriteError, and must NOT fire a doomed discard under the throttle. ----
    stub, calls = make_stub("status_ratelimit")
    B._gh = stub
    try:
        B.create_item("o", "1", ".", "t", "b", "Consideration", "Todo")
        print("FAIL: create_item did not raise on a mid-create rate-limit"); sys.exit(1)
    except B.RateLimitError as e:
        if e.reset != "1999999999":
            print(f"FAIL: rate-limit reset was {e.reset!r}, expected '1999999999' (resume info lost)"); sys.exit(1)
    except B.BoardReadError:
        print("FAIL: mid-create rate-limit was flattened to a hard error (pause/resume lost)"); sys.exit(1)
    if called(calls, ("project", "item-delete")) or called(calls, ("issue", "close")):
        print("FAIL: rate-limit path attempted a discard under the live throttle"); sys.exit(1)

    # ---- M3: item-add returns an EMPTY id → no board-item handle to delete. Must fail closed, close
    #      the backing issue, NOT call item-delete, and report the discard as INCOMPLETE (honest). ----
    stub, calls = make_stub("empty_item_id")
    B._gh = stub
    try:
        B.create_item("o", "1", ".", "t", "b", "Consideration", "Todo")
        print("FAIL: create_item did not raise on an empty item-add id"); sys.exit(1)
    except B.BoardReadError as e:
        if "INCOMPLETE" not in str(e):
            print(f"FAIL: empty-item-id discard not reported as INCOMPLETE: {e}"); sys.exit(1)
    if called(calls, ("project", "item-delete")):
        print("FAIL: empty-item-id path called item-delete with no id"); sys.exit(1)
    if not called(calls, ("issue", "close")):
        print("FAIL: empty-item-id path did not close the backing issue"); sys.exit(1)

    # ---- M1: when the discard's OWN item-delete fails, the raised error must say so (INCOMPLETE),
    #      not falsely claim a clean rollback. ----
    stub, calls = make_stub("status_fail_delete_fail")
    B._gh = stub
    try:
        B.create_item("o", "1", ".", "t", "b", "Consideration", "Todo")
        print("FAIL: create_item did not raise when discard's item-delete failed"); sys.exit(1)
    except B.BoardReadError as e:
        if "INCOMPLETE" not in str(e) or "item-delete failed" not in str(e):
            print(f"FAIL: failed teardown not surfaced honestly: {e}"); sys.exit(1)
finally:
    B._gh = orig

print("  ok (B) github: create_item sets Stage+Status atomically; discards + raises on partial failure")
PY

echo "PASS: atomic Stage+Status create — fs op_create always writes a non-empty Status with a set Stage; github create_item sets both atomically and discards (delete item + close issue) on a partial Status-set failure, so a create can never yield a Stage-without-Status item (#255/#256)"
