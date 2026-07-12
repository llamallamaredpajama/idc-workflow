#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: journal rotation reads the active journal, partitions terminal vs live lines, then
# atomically os.replace's the active journal with the kept lines. A journal_append landing BETWEEN the
# read and the replace would be silently DROPPED (issue #150 round-10 residual P2) — a lost obligation.
# Rotation must fold in any bytes a concurrent append wrote after its read (re-check-after-replace),
# while remaining a single atomic rewrite. It must ALSO split records only on the newline byte (not
# str.splitlines(), which mis-splits valid records carrying U+2028/U+2029). Both are driven in-process.

. "$(dirname "$0")/lib.sh"

REPO="$(mktemp -d)"; trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/docs/workflow"
JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

# ── scenario 1: a concurrent append landing during rotation must not be lost ────────────────────
python3 - "$GOV_PLUGIN/scripts" "$REPO" "$JOURNAL" <<'PY' || { echo "FAIL: rotation dropped a concurrent append (or archive/keep partition wrong)"; exit 1; }
import json, os, sys
sys.path.insert(0, sys.argv[1])
repo, journal = sys.argv[2], sys.argv[3]
import idc_git_janitor as J

def rec(item, status, op="move"):
    return json.dumps({"item": item, "op": op, "to": {"stage": "Buildable", "status": status},
                       "what": f"{op} #{item}", "when": "2026-01-01T00:00:00Z", "who": "t",
                       "backend": "filesystem"}, sort_keys=True)

# Seed: a LIVE item (100) to keep + a TERMINAL item (200) to archive.
with open(journal, "w", encoding="utf-8") as f:
    f.write(rec(100, "Todo") + "\n")
    f.write(rec(200, "Done", op="close") + "\n")

# The race: a concurrent journal_append for a LIVE item (300) lands RIGHT AFTER rotation's read, via the
# read seam. A correct rotation folds the post-read tail into the rewritten journal before os.replace.
CONCURRENT = rec(300, "In Progress", op="claim")
def racing_read(path):
    with open(path, "rb") as f:
        data = f.read()
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(CONCURRENT + "\n")   # the append landing DURING rotation, after the read
    return data
J._read_journal_bytes = racing_read

ctx = {"repo": repo, "board": [
    {"number": 100, "status": "Todo"},
    {"number": 200, "status": "Done"},
    {"number": 300, "status": "In Progress"},
]}
J.rotate_journal(ctx, journal)

items = [json.loads(l)["item"] for l in open(journal, encoding="utf-8") if l.strip()]
if 100 not in items:
    raise SystemExit(f"live item 100 must remain in the active journal; saw {items}")
if 300 not in items:
    raise SystemExit(f"the concurrent append (300) landing during rotation was DROPPED; saw {items} "
                     "— rotation must fold in bytes appended after its read")
if 200 in items:
    raise SystemExit(f"terminal item 200 should have been archived, not kept; saw {items}")

archive_dir = os.path.join(repo, "docs", "workflow", "journal-archive")
archived = []
for fn in os.listdir(archive_dir):
    with open(os.path.join(archive_dir, fn), encoding="utf-8") as fh:
        archived += [json.loads(l)["item"] for l in fh if l.strip()]
if 200 not in archived:
    raise SystemExit(f"terminal item 200 must be archived; saw {archived}")
if 300 in archived or 100 in archived:
    raise SystemExit(f"only the terminal item may be archived; saw {archived}")
print("  ok: rotation folds a concurrent append, archives only terminal entries")
PY

# ── scenario 3: an append landing in the READ→REPLACE window is recovered ───────────────────────
# The pre-replace tail-fold approach could not see an append that lands AT os.replace time (after the
# read+partition). Draining the pre-rotation inode after the replace recovers it. Inject the append at
# the exact os.replace moment. Red-when-broken: without the drain, item 300 is dropped.
REPO3="$(mktemp -d)"
JOURNAL3="$REPO3/docs/workflow/transition-journal.ndjson"
mkdir -p "$REPO3/docs/workflow"
python3 - "$GOV_PLUGIN/scripts" "$REPO3" "$JOURNAL3" <<'PY' || { echo "FAIL: rotation dropped an append landing in the read->replace window"; rm -rf "$REPO3"; exit 1; }
import json, os, sys
sys.path.insert(0, sys.argv[1])
repo, journal = sys.argv[2], sys.argv[3]
import idc_git_janitor as J

def rec(item, status, op="move"):
    return json.dumps({"item": item, "op": op, "to": {"stage": "Buildable", "status": status},
                       "what": f"{op} #{item}", "when": "2026-01-01T00:00:00Z", "who": "t",
                       "backend": "filesystem"}, sort_keys=True)

with open(journal, "w", encoding="utf-8") as f:
    f.write(rec(100, "Todo") + "\n")
    f.write(rec(200, "Done", op="close") + "\n")

# Inject the concurrent append at os.replace time — AFTER rotation read+partitioned, at the very moment
# it swaps the journal (the window a pre-replace tail-fold cannot see). It lands on the OLD inode.
WINDOW = rec(300, "In Progress", op="claim")
real_replace = os.replace
def racing_replace(src, dst):
    if os.path.abspath(dst) == os.path.abspath(journal):
        with open(journal, "a", encoding="utf-8") as fh:
            fh.write(WINDOW + "\n")
    return real_replace(src, dst)
J.os.replace = racing_replace

ctx = {"repo": repo, "board": [
    {"number": 100, "status": "Todo"},
    {"number": 200, "status": "Done"},
    {"number": 300, "status": "In Progress"},
]}
try:
    J.rotate_journal(ctx, journal)
finally:
    J.os.replace = real_replace

items = [json.loads(l)["item"] for l in open(journal, encoding="utf-8") if l.strip()]
if 300 not in items:
    raise SystemExit(f"an append landing in the read->replace window was DROPPED; saw {items}")
if 100 not in items:
    raise SystemExit(f"live item 100 must remain in the active journal; saw {items}")
print("  ok: an append in the read->replace window is recovered by draining the replaced inode")
PY
rm -rf "$REPO3"

# ── scenario 2: a valid record with a Unicode line separator (U+2028) must NOT be rejected ──────
# json.dumps(ensure_ascii=False) emits U+2028/U+2029 UNescaped (issue titles flow into `what`), and
# str.splitlines() would split the record there → rotation would wrongly reject a VALID journal as
# malformed (exit 2). Rotation must split only on the newline BYTE. Red-when-broken: a
# str.splitlines()-based rotation exits 2 here and drops the live record.
REPO2="$(mktemp -d)"
JOURNAL2="$REPO2/docs/workflow/transition-journal.ndjson"
mkdir -p "$REPO2/docs/workflow"
python3 - "$GOV_PLUGIN/scripts" "$REPO2" "$JOURNAL2" <<'PY' || { echo "FAIL: rotation rejected a valid U+2028 record"; rm -rf "$REPO2"; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[1])
repo, journal = sys.argv[2], sys.argv[3]
import idc_git_janitor as J

# The title carries a literal U+2028 (Unicode LINE SEPARATOR), built here so no separator byte sits in
# the test file itself. json.dumps(ensure_ascii=False) leaves it UNescaped in the record.
live = {"item": 10, "op": "move", "what": "fix a" + chr(0x2028) + "b",
        "to": {"stage": "Buildable", "status": "Todo"},
        "when": "2026-01-01T00:00:00Z", "who": "t", "backend": "filesystem"}
term = {"item": 20, "op": "close", "what": "close #20", "to": {"stage": "Buildable", "status": "Done"},
        "when": "2026-01-01T00:00:00Z", "who": "t", "backend": "filesystem"}
with open(journal, "w", encoding="utf-8") as f:
    f.write(json.dumps(live, ensure_ascii=False) + "\n")
    f.write(json.dumps(term, ensure_ascii=False) + "\n")

ctx = {"repo": repo, "board": [{"number": 10, "status": "Todo"}, {"number": 20, "status": "Done"}]}
J.rotate_journal(ctx, journal)   # must NOT sys.exit(2) on the valid U+2028 record

items = [json.loads(l)["item"] for l in open(journal, encoding="utf-8") if l.strip()]
if items != [10]:
    raise SystemExit(f"the U+2028 live record must survive rotation intact; active items = {items}")
print("  ok: a valid U+2028 record is not mis-split into 'malformed' by rotation")
PY
rm -rf "$REPO2"

# ── scenario 4: rotation holds an exclusive flock on the STABLE SIDECAR across its critical section ─
# The race is FULLY closed by both rotation and the engine's journal_append taking flock(LOCK_EX) on
# the journal's stable sidecar (`<journal>.lock`, never replaced — so the lock survives os.replace; the
# appender half lands with W2). Prove rotation's half: while rotation is mid-flight (inside its read,
# under the lock), a NON-blocking LOCK_EX on the SIDECAR from a separate fd must FAIL — i.e. rotation
# holds it. Red-when-broken: a rotation that does not lock the sidecar lets the probe acquire it.
REPO4="$(mktemp -d)"
JOURNAL4="$REPO4/docs/workflow/transition-journal.ndjson"
mkdir -p "$REPO4/docs/workflow"
python3 - "$GOV_PLUGIN/scripts" "$REPO4" "$JOURNAL4" <<'PY' || { echo "FAIL: rotation did not hold an exclusive lock during its critical section"; rm -rf "$REPO4"; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[1])
repo, journal = sys.argv[2], sys.argv[3]
import idc_git_janitor as J

if J.fcntl is None:
    print("  ok: fcntl unavailable on this platform — rotation falls back to the drain (lock N/A)")
    sys.exit(0)

def rec(item, status, op="move"):
    return json.dumps({"item": item, "op": op, "to": {"stage": "Buildable", "status": status},
                       "what": f"{op} #{item}", "when": "2026-01-01T00:00:00Z", "who": "t",
                       "backend": "filesystem"}, sort_keys=True)
with open(journal, "w", encoding="utf-8") as f:
    f.write(rec(100, "Todo") + "\n")
    f.write(rec(200, "Done", op="close") + "\n")

# Probe from INSIDE rotation's critical section (the seam runs while rotation holds the sidecar lock):
# a separate fd's NON-blocking LOCK_EX on the SIDECAR must fail (flock conflicts per open-file-description,
# even in-process). The sidecar is `journal_lock_path(journal)` — the shared convention with the appender.
sidecar = J.journal_lock_path(journal)
observed = {}
real_read = J._read_journal_bytes
def probing_read(path):
    probe = open(sidecar, "w")
    try:
        J.fcntl.flock(probe.fileno(), J.fcntl.LOCK_EX | J.fcntl.LOCK_NB)
        observed["locked_by_rotation"] = False   # we acquired the sidecar → rotation was NOT holding it
        J.fcntl.flock(probe.fileno(), J.fcntl.LOCK_UN)
    except OSError:
        observed["locked_by_rotation"] = True    # blocked → rotation holds the sidecar LOCK_EX (expected)
    finally:
        probe.close()
    return real_read(path)
J._read_journal_bytes = probing_read

ctx = {"repo": repo, "board": [{"number": 100, "status": "Todo"}, {"number": 200, "status": "Done"}]}
J.rotate_journal(ctx, journal)

if observed.get("locked_by_rotation") is not True:
    raise SystemExit("rotation must hold an exclusive flock on the journal SIDECAR during its critical "
                     f"section (probe observed {observed})")
print("  ok: rotation holds an exclusive flock on the journal sidecar across the read->replace critical section")
PY
rm -rf "$REPO4"

echo "PASS: rotation locks the STABLE SIDECAR (flock LOCK_EX) across its rewrite, drains a concurrent unlocked append (no lost line), archives only terminal entries, and splits NDJSON on the newline byte only (U+2028-safe)."
