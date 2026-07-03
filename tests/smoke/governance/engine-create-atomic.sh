#!/bin/bash
# engine-create-atomic.sh — governance scenario: a filesystem create with a marker body is ATOMIC —
# the item and its marker land in ONE write, so a create can never strand an UNMARKED item.
#
# The gap this closes (PR #133 review): _fs_create was create-THEN-comment; a failed 2nd (comment)
# call left an item on the board WITHOUT its idc-recirc-source marker before the read-back — which the
# filer's dedupe can't see, risking duplicate tickets. The create now passes the marker to
# idc_tracker_fs `create --comment` (one fsync+os.replace); there is no separate comment step.
#
# Red-when-broken (in-process): _trk is monkeypatched to FAIL any `comment` subcommand AND to log
# every call. A create with a body must (a) issue NO `comment` subcommand (it is atomic), and (b)
# leave the created item carrying its marker. Revert _fs_create to create-then-comment → a `comment`
# call appears (and fails), stranding a marker-less item → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-create-atomic.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" "$T" <<'PY' || fail "atomic-create assertions failed (see above)"
import sys
scripts, repo, tracker = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, scripts)
import idc_transition as E
import idc_tracker_fs as FS

calls = []
orig = E._trk
def logging_trk(trk, *args):
    calls.append(args[0] if args else "")
    if args and args[0] == "comment":
        # simulate a failed separate comment step — an atomic create never reaches here.
        class R:  # minimal CompletedProcess stand-in
            returncode = 1; stderr = "simulated comment failure"; stdout = ""
        return R()
    return orig(trk, *args)
E._trk = logging_trk
try:
    machine = E.load_machine(E.machine_path_for(repo))
    spec = machine["ops"]["recirculate-intake"]
    num = E._fs_create(machine, "recirculate-intake", tracker, spec, "nit", "MARKER-XYZ", None, None)
    # (a) atomic: NO separate `comment` subcommand was ever issued.
    assert "comment" not in calls, f"create issued a separate `comment` step (not atomic): {calls}"
    # (b) the created item carries its marker (nothing stranded unmarked).
    st = FS.load(tracker)
    it = next((i for i in st["issues"] if str(i["number"]) == str(num)), None)
    assert it is not None, "created item not found"
    assert "MARKER-XYZ" in (it.get("comments") or []), "created item is missing its marker (stranded)"
    print("  ok create is atomic: item + marker in one write, no separate comment step to fail")

    # Belt-and-braces: no item anywhere has a Recirculation stage + Status but lacks a marker.
    for i in st["issues"]:
        if (i.get("stage") == "Recirculation") and i.get("status"):
            assert i.get("comments"), f"a Recirculation/{i['status']} item #{i['number']} has NO marker (strand)"
    print("  ok no Recirculation item is left status-set-but-marker-less")
finally:
    E._trk = orig
PY

echo "PASS: filesystem create is atomic — item + marker land together, so a create can never strand an unmarked item"
