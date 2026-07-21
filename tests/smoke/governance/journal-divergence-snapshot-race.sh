#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken (#154, codex P2): the janitor's divergence pass used to read the journal TWICE,
# both times UNLOCKED — once to reconstruct expected state, once to derive the adoption watermark.
# `/idc:doctor` Row 10 runs that pass on every doctor run, on both backends, while the engine and
# the janitor's own rotation are free to be writing. Two unlocked reads of a file being written can
# see states that never existed as a whole:
#
#   scenario 1 — a half-written line from an in-flight append → "malformed journal" → the journal
#                dimension goes INDETERMINATE and Row 10 SKIPs. Nothing is wrong with the journal.
#   scenario 2 — a rotation caught between "the live segment has been replaced" and "the archive
#                segment has been written" → the create records are momentarily in NEITHER place →
#                no watermark → every board-only item is carved out as pre-journal legacy. A real
#                divergence goes unreported.
#
# The fix is one locked, fail-closed snapshot (scan_journal_strict) feeding the reconstruction, the
# watermark and the carve-out guard. The lock is the journal's sidecar — the same one journal_append
# and rotation take — so the pass WAITS OUT a concurrent writer instead of reading through it.
#
# Both scenarios drive a REAL second process holding the REAL sidecar lock; the only staged part is
# that the writer holds its window open for a fixed delay instead of by luck. Delete the lock from
# scan_journal_strict, or go back to two unlocked reads, and both scenarios FAIL.

. "$(dirname "$0")/lib.sh"

REPO="$(mktemp -d)"; trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/docs/workflow"

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || exit 1
import json, os, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
from idc_git_janitor import check_journal_divergence

journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
archive_dir = os.path.join(repo, "docs", "workflow", "journal-archive")
ready = os.path.join(repo, "writer-is-in-its-window")

# The engine's create record: it carries the target state, so a journaled item is reconciled.
def create(num, status="Todo"):
    return {"when": "2026-01-01T00:00:00Z", "who": "engine", "op": "create-ticket",
            "what": f"create-ticket 'item {num}'", "backend": "filesystem", "item": num,
            "to": {"stage": "Buildable", "status": status}}

def board(*nums):
    return [{"number": n, "stage": "Buildable", "status": "Todo"} for n in nums]

WINDOW = 1.5

def run_writer(open_window, close_window):
    """Run a SECOND process that takes the journal's sidecar lock (LOCK_EX — the lock
    journal_append and the janitor's rotation take), opens its window, touches the ready file,
    holds the window for WINDOW seconds, then closes it and releases. Returns once the window is
    open, so the assertion below runs INSIDE it."""
    if os.path.exists(ready):
        os.remove(ready)
    src = ("import fcntl, os, sys, time\n"
           "journal, archive_dir, ready, window = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])\n"
           "lock = open(journal + '.lock', 'a')\n"
           "fcntl.flock(lock.fileno(), fcntl.LOCK_EX)\n"
           + open_window +
           "open(ready, 'w').close()\n"
           "time.sleep(window)\n"
           + close_window +
           "fcntl.flock(lock.fileno(), fcntl.LOCK_UN)\n")
    proc = subprocess.Popen([sys.executable, "-c", src, journal, archive_dir, ready, str(WINDOW)])
    deadline = time.time() + 20
    while not os.path.exists(ready):
        if proc.poll() is not None:
            raise SystemExit("the writer process exited before it opened its window")
        if time.time() > deadline:
            proc.kill()
            raise SystemExit("the writer process never opened its window")
        time.sleep(0.01)
    return proc

# ── scenario 1: a half-written append must not read as a corrupt journal ───────────────────────────
# The engine appends one whole line under the sidecar lock. Mid-write, the file's last line is
# truncated JSON. An unlocked reader sees it and calls the journal malformed.
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(create(10)) + "\n")
if os.path.exists(journal + ".lock"):
    os.remove(journal + ".lock")

proc = run_writer(
    open_window=("open(journal, 'a').write('{\"op\": \"move\", \"item\": 10, \"to\": {\"stage\": \"Buil')\n"),
    close_window=("open(journal, 'a').write('dable\", \"status\": \"Todo\"}, \"what\": \"move #10\"}\\n')\n"),
)
started = time.time()
findings = []
indeterminate = check_journal_divergence({"board": board(10)}, findings, journal)
waited = time.time() - started
proc.wait()

if indeterminate:
    raise SystemExit("a half-written line from an in-flight append was read as a CORRUPT journal — "
                     "the pass must take the sidecar lock and wait the writer out, not report the "
                     "journal dimension indeterminate")
if [f for f in findings if f.get("dim") == "journal"]:
    raise SystemExit(f"the settled journal agrees with the board; no finding expected, got {findings}")
if waited < WINDOW / 2:
    raise SystemExit(f"the pass returned in {waited:.2f}s — it cannot have waited for the writer's "
                     f"{WINDOW}s window, so it did not read under the lock (non-vacuity check)")
with open(journal, encoding="utf-8") as fh:   # the writer's line did land, whole
    if len([l for l in fh if l.strip()]) != 2:
        raise SystemExit("the writer's append did not complete — the scenario staged nothing")
print(f"  ok (1) an in-flight append is waited out, not reported as corruption (blocked {waited:.2f}s)")

# ── scenario 2: a rotation caught mid-move must not erase the adoption watermark ───────────────────
# Rotation archives terminal records: it rewrites the live segment, then writes the archive segment.
# Between those two writes the create records exist in neither file. An unlocked reader that lands
# there sees an adoption-free journal and carves out the whole board — including #20, which has no
# journal history and is numbered ABOVE the real watermark (#10).
os.makedirs(archive_dir, exist_ok=True)
for stale in os.listdir(archive_dir):
    os.remove(os.path.join(archive_dir, stale))
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(create(10)) + "\n")
if os.path.exists(journal + ".lock"):
    os.remove(journal + ".lock")

proc = run_writer(
    open_window=("open(journal, 'w').close()\n"),                      # live segment replaced, empty
    close_window=("import json\n"
                  "rec = json.dumps({'when': '2026-01-01T00:00:00Z', 'who': 'engine', "
                  "'op': 'create-ticket', 'what': \"create-ticket 'item 10'\", "
                  "'backend': 'filesystem', 'item': 10, "
                  "'to': {'stage': 'Buildable', 'status': 'Todo'}})\n"
                  "os.makedirs(archive_dir, exist_ok=True)\n"
                  "open(os.path.join(archive_dir, '2026-01.ndjson'), 'w').write(rec + '\\n')\n"),
)
findings = []
indeterminate = check_journal_divergence({"board": board(10, 20)}, findings, journal)
proc.wait()

if indeterminate:
    raise SystemExit(f"the settled journal is readable; indeterminate not expected. findings={findings}")
journal_findings = [f for f in findings if f.get("dim") == "journal"]
if not any("#20" == f.get("name") for f in journal_findings):
    raise SystemExit("the pass read the journal mid-rotation, saw no create record, and carved out "
                     f"the whole board — #20 has no journal history and is above the watermark (#10), "
                     f"so it must be reported; got {journal_findings}")
if any("#10" == f.get("name") for f in journal_findings):
    raise SystemExit(f"#10's create record is in the archive segment and reconciles; got {journal_findings}")
print("  ok (2) a rotation's read→replace window cannot erase the adoption watermark")
PY

echo "PASS: the divergence pass takes ONE locked journal snapshot — a concurrent append cannot fake corruption and a concurrent rotation cannot fake a pre-journal board (#154 codex P2)"
