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
#   scenario 2 — the scanner snapshots the archive paths before rotation publishes its new archive,
#                then opens the live path after rotation has replaced it → records that moved to the
#                archive are absent from that stale path list. The first old read loses expected
#                state; its second, fresh path snapshot sees the archive watermark and reports a
#                false divergence against a board item whose history is actually in that archive.
#
# The fix is one locked, fail-closed snapshot (scan_journal_strict) feeding the reconstruction, the
# watermark and the carve-out guard. The lock is the journal's sidecar — the same one journal_append
# and rotation take — so the pass WAITS OUT a concurrent writer instead of reading through it.
#
# Both scenarios drive a REAL second process holding the REAL sidecar lock. Scenario 1 uses an
# explicit release handshake (no fixed sleep). Scenario 2 calls the REAL rotate_journal and only
# inserts a scheduling handoff after the REAL archive-path snapshot, so production's archive-first,
# live-second replacement order is preserved. Delete the lock from scan_journal_strict, or go back
# to two unlocked reads, and both scenarios FAIL. The final boundary check removes fcntl from the
# import table: the strict scanner must return an indeterminate reason, never read unlocked or crash.

. "$(dirname "$0")/lib.sh"

REPO="$(mktemp -d)"; trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/docs/workflow"

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || exit 1
import fcntl, json, os, pathlib, subprocess, sys, threading, time
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_git_janitor as JANITOR
import idc_journal_replay as REPLAY

journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
archive_dir = os.path.join(repo, "docs", "workflow", "journal-archive")
ready = os.path.join(repo, "writer-is-in-its-window")
release = os.path.join(repo, "release-writer")

# The engine's create record: it carries the target state, so a journaled item is reconciled.
def create(num, status="Todo"):
    return {"when": "2026-01-01T00:00:00Z", "who": "engine", "op": "create-ticket",
            "what": f"create-ticket 'item {num}'", "backend": "filesystem", "item": num,
            "to": {"stage": "Buildable", "status": status}}

def board(*nums, status="Todo"):
    return [{"number": n, "stage": "Buildable", "status": status} for n in nums]

def wait_for(path, proc, failure):
    deadline = time.time() + 20
    while not os.path.exists(path):
        if proc.poll() is not None:
            raise SystemExit(f"{failure}: writer exited {proc.returncode}")
        if time.time() > deadline:
            proc.kill()
            raise SystemExit(failure)
        time.sleep(0.01)

def run_writer(open_window, close_window):
    """Run a SECOND process that takes the journal's sidecar lock (LOCK_EX — the lock
    journal_append and the janitor's rotation take), opens its window, touches the ready file, and
    waits for an explicit release before closing the window and unlocking. Returns once the window
    is open, so the assertion below runs INSIDE it without relying on a fixed sleep."""
    for marker in (ready, release):
        if os.path.exists(marker):
            os.remove(marker)
    src = ("import fcntl, os, sys, time\n"
           "journal, archive_dir, ready, release = sys.argv[1:]\n"
           "lock = open(journal + '.lock', 'a')\n"
           "fcntl.flock(lock.fileno(), fcntl.LOCK_EX)\n"
           + open_window +
           "open(ready, 'w').close()\n"
           "deadline = time.time() + 20\n"
           "while not os.path.exists(release):\n"
           "    if time.time() > deadline: raise SystemExit('reader never released writer')\n"
           "    time.sleep(0.01)\n"
           + close_window +
           "fcntl.flock(lock.fileno(), fcntl.LOCK_UN)\n")
    proc = subprocess.Popen([sys.executable, "-c", src, journal, archive_dir, ready, release])
    wait_for(ready, proc, "the writer process never opened its window")
    return proc

# ── scenario 1: a half-written append must not read as a corrupt journal ───────────────────────────
# The engine appends one whole line under the sidecar lock. Mid-write, the file's last line is
# truncated JSON. An unlocked reader sees it and calls the journal malformed.
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(create(10)) + "\n")
if os.path.exists(journal + ".lock"):
    os.remove(journal + ".lock")

proc = run_writer(
    open_window=("partial = open(journal, 'a')\n"
                 "partial.write('{\"op\": \"move\", \"item\": 10, \"to\": {\"stage\": \"Buil')\n"
                 "partial.flush()\n"),
    close_window=("partial.write('dable\", \"status\": \"Todo\"}, \"what\": \"move #10\"}\\n')\n"
                  "partial.close()\n"),
)
lock_attempt = os.path.join(repo, "reader-attempted-shared-lock")
observed = {}
real_flock = fcntl.flock

def observing_flock(fd, operation):
    if operation == fcntl.LOCK_SH:
        lock_stat, fd_stat = os.stat(journal + ".lock"), os.fstat(fd)
        observed["same_sidecar"] = ((lock_stat.st_dev, lock_stat.st_ino) ==
                                    (fd_stat.st_dev, fd_stat.st_ino))
        try:
            real_flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            observed["writer_excluded_reader"] = True
        else:
            observed["writer_excluded_reader"] = False
            real_flock(fd, fcntl.LOCK_UN)
        pathlib.Path(lock_attempt).touch()
    return real_flock(fd, operation)

result = {}
def read_during_append():
    try:
        findings = []
        result["indeterminate"] = JANITOR.check_journal_divergence(
            {"board": board(10)}, findings, journal)
        result["findings"] = findings
    except BaseException as exc:  # keep the writer releasable even if the reader crashes
        result["error"] = exc

fcntl.flock = observing_flock
reader = threading.Thread(target=read_during_append, daemon=True)
try:
    reader.start()
    deadline = time.time() + 20
    while not os.path.exists(lock_attempt):
        if not reader.is_alive():
            raise SystemExit("the reader returned before attempting the journal's shared sidecar "
                             "lock — it read through the writer's half-written line")
        if proc.poll() is not None:
            raise SystemExit(f"the append writer exited unexpectedly ({proc.returncode})")
        if time.time() > deadline:
            raise SystemExit("the reader never attempted the journal's shared sidecar lock")
        time.sleep(0.01)
finally:
    pathlib.Path(release).touch()
    proc.wait(timeout=20)
    reader.join(timeout=20)
    fcntl.flock = real_flock

if reader.is_alive():
    raise SystemExit("the reader never completed after the writer released the sidecar lock")
if result.get("error") is not None:
    raise result["error"]
if not observed.get("same_sidecar") or not observed.get("writer_excluded_reader"):
    raise SystemExit(f"the scan did not contend on the writer's exact sidecar inode: {observed}")
if result["indeterminate"]:
    raise SystemExit("a half-written line from an in-flight append was read as a CORRUPT journal — "
                     "the pass must take the sidecar lock and wait the writer out, not report the "
                     "journal dimension indeterminate")
if [f for f in result["findings"] if f.get("dim") == "journal"]:
    raise SystemExit(f"the settled journal agrees with the board; no finding expected, got "
                     f"{result['findings']}")
with open(journal, encoding="utf-8") as fh:   # the writer's line did land, whole
    if len([l for l in fh if l.strip()]) != 2:
        raise SystemExit("the writer's append did not complete — the scenario staged nothing")
print("  ok (1) an in-flight append is waited out on the exact sidecar, not reported as corruption")

# ── scenario 2: the REAL rotation must not create a false divergence ───────────────────────────────
# Production rotation publishes the archive FIRST, then replaces the live journal. The old unlocked
# reader can snapshot archive paths before the new archive exists, let rotation complete, and then
# open the now-empty live path from that stale snapshot. Its first read loses BOTH journaled items;
# its second fresh snapshot sees the archive watermark (#10), so it falsely reports journaled #20 as
# missing history. The scheduling hook below runs only after the REAL _journal_paths result is built;
# the writer calls the REAL rotate_journal, preserving production's exact replacement order.
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(create(10, "Done")) + "\n")
    fh.write(json.dumps(create(20, "Done")) + "\n")

rotate_ready = os.path.join(repo, "rotation-writer-ready")
rotate_now = os.path.join(repo, "rotate-now")
rotation_done = os.path.join(repo, "rotation-done")
rotate_src = ("import os, pathlib, sys, time\n"
              "scripts, repo, journal, ready, trigger, done = sys.argv[1:]\n"
              "sys.path.insert(0, scripts)\n"
              "import idc_git_janitor as janitor\n"
              "pathlib.Path(ready).touch()\n"
              "deadline = time.time() + 20\n"
              "while not os.path.exists(trigger):\n"
              "    if time.time() > deadline: raise SystemExit('reader never triggered rotation')\n"
              "    time.sleep(0.01)\n"
              "janitor.rotate_journal({'repo': repo, 'board': ["
              "{'number': 10, 'status': 'Done'}, {'number': 20, 'status': 'Done'}]}, journal)\n"
              "pathlib.Path(done).touch()\n")
proc = subprocess.Popen([sys.executable, "-c", rotate_src, sys.argv[1], repo, journal,
                         rotate_ready, rotate_now, rotation_done], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True)
wait_for(rotate_ready, proc, "the real rotation process never became ready")

real_paths = REPLAY._journal_paths
path_calls = 0
scan_held_lock = None

def rotate_after_snapshot(path):
    global path_calls, scan_held_lock
    paths = real_paths(path)
    path_calls += 1
    if path_calls == 1:
        with open(journal + ".lock", "a") as probe:
            try:
                fcntl.flock(probe.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                scan_held_lock = True
            else:
                scan_held_lock = False
                fcntl.flock(probe.fileno(), fcntl.LOCK_UN)
        pathlib.Path(rotate_now).touch()
        if not scan_held_lock:
            # Old reader: let the REAL archive-first/live-second rotation finish, then return the
            # stale pre-archive path snapshot so it opens the newly-empty live journal.
            wait_for(rotation_done, proc, "the real rotation did not complete")
    return paths

REPLAY._journal_paths = rotate_after_snapshot
try:
    findings = []
    indeterminate = JANITOR.check_journal_divergence(
        {"board": board(10, 20, status="Done")}, findings, journal)
finally:
    REPLAY._journal_paths = real_paths
stdout, stderr = proc.communicate(timeout=20)
if proc.returncode:
    raise SystemExit(f"the real rotation process failed ({proc.returncode}): {stderr or stdout}")

if indeterminate:
    raise SystemExit(f"the settled journal is readable; indeterminate not expected. findings={findings}")
journal_findings = [f for f in findings if f.get("dim") == "journal"]
if not scan_held_lock:
    raise SystemExit("the journal path snapshot was not covered by the shared sidecar lock — a real "
                     f"rotation can invalidate that snapshot (findings={journal_findings})")
if journal_findings:
    raise SystemExit(f"both #10 and #20 have create history moved by the real rotation; no false "
                     f"divergence expected, got {journal_findings}")
print("  ok (2) a real archive-first/live-second rotation cannot invalidate the locked path snapshot")

# ── boundary: no fcntl means fail closed with a reason, not an unlocked read or a traceback ─────────
# IDC's supported macOS/Linux platforms provide fcntl. Still, scan_journal_strict's contract is an
# (entries, error) result on lock failure, and Row 10 maps that error to advisory SKIP. Simulate an
# unavailable module so a platform gap cannot turn that ordinary fail-closed path into an exception.
saved_fcntl = sys.modules.get("fcntl")
sys.modules["fcntl"] = None
try:
    entries, error = REPLAY.scan_journal_strict(journal)
finally:
    sys.modules["fcntl"] = saved_fcntl
if entries is not None or not error or "locking unavailable" not in error:
    raise SystemExit(f"fcntl unavailable must return a fail-closed lock error, got {entries}, {error}")
print("  ok (3) fcntl unavailable: strict scan returns indeterminate instead of reading unlocked/crashing")
PY

echo "PASS: the divergence pass takes ONE locked journal snapshot — concurrent append/rotation cannot fake a result, and an unavailable lock primitive fails closed (#154 codex P2)"
