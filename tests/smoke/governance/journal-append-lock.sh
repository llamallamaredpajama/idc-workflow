#!/bin/bash
# journal-append-lock.sh — governance scenario: the engine's APPENDER-side sidecar journal lock (#150).
#
# Rotation (idc_git_janitor) and append (idc_transition.journal_append) race: the janitor's
# read-then-os.replace rewrite can drop a concurrent append that lands between the read and the
# replace. W1 closed the ROTATION side by taking fcntl.flock(LOCK_EX) on the STABLE sidecar
# `<journal>.lock` (never the journal inode itself — os.replace swaps that out under a held lock).
# This scenario locks the APPENDER side of the same shared contract:
#   (1) journal_append acquires LOCK_EX on the sidecar BEFORE opening the journal, so an append can
#       never interleave a rotation's read-then-replace window; and
#   (2) locking stays FAIL-SOFT — a flock error warns to stderr and appends anyway (journaling is
#       best-effort by contract: it must never block or fail the board mutation it records).
#
# Red-when-broken (the mutation proof): remove the flock from journal_append → case 1 FAILs (the op
# completes while this test holds the sidecar). Make the lock fail-CLOSED on error → case 2 FAILs
# (no journal line after a forced flock failure). Drop the unlocked-branch inode verify/re-append
# (write blind to the opened fd) → case 3 FAILs (the line is lost on the rotation-replaced inode).
# Drop the pre-retry ordering check (_retry_would_regress; always re-append) → case 4a FAILs (a
# stale record lands after a newer same-item record); always SKIP the retry instead → case 4c FAILs
# (the over-skip control: a genuinely lost line must still be re-appended). Scan only the ACTIVE
# journal (drop the _journal_paths segment walk) → case 4d FAILs (a newer record already rotated
# into an archive is missed; replay reads archives first).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
LOCK="$JOURNAL.lock"
mkdir -p "$(dirname "$JOURNAL")" || fail "could not create the workflow dir"

# ── 1. While a rotation-style holder owns the sidecar LOCK_EX, an engine op's append WAITS ─────────
python3 - "$LOCK" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "a")
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(sys.argv[1] + ".held", "w").close()   # signal: the lock is genuinely held
time.sleep(15)                             # released early by kill (flock dies with the process)
PY
HOLDER=$!
for _ in $(seq 1 50); do [ -f "$LOCK.held" ] && break; sleep 0.1; done
[ -f "$LOCK.held" ] || fail "the lock-holder never acquired the sidecar lock (test harness problem)"

( eng create-ticket --title 'append under held sidecar lock' >/dev/null 2>&1; : > "$REPO/.op-done" ) &
OP=$!
sleep 2
if [ -f "$REPO/.op-done" ]; then
  kill "$HOLDER" 2>/dev/null
  fail "the engine op completed while the sidecar lock was held — journal_append is not serializing on the appender side (rotation can drop this append)"
fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
wait "$OP"
[ -f "$REPO/.op-done" ] || fail "the engine op did not complete after the sidecar lock was released"
grep -q 'append under held sidecar lock' "$JOURNAL" \
  || fail "the journal line is missing after the lock was released (append lost)"
echo "  ok (1) an append WAITS while the rotation sidecar lock is held, then lands once it is released"

# ── 2. FAIL-SOFT: a flock error warns and appends anyway (journaling never fails the mutation) ─────
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || exit 1
import io, contextlib, os, sys
sys.path.insert(0, sys.argv[1])
import idc_transition as E

repo = sys.argv[2]
if E.fcntl is None:
    print("FAIL: fcntl unavailable on a POSIX test host — the appender lock would never engage")
    sys.exit(1)

class _Raiser:
    LOCK_EX = getattr(E.fcntl, "LOCK_EX", 2)
    def flock(self, *a, **k):
        raise OSError("synthetic flock failure")

real = E.fcntl
E.fcntl = _Raiser()
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        E.journal_append(repo, "move", "filesystem", "TRACKER.md",
                         {"num": 1, "to_status": "Todo", "agent": "lock-test"},
                         cur={"status": "Blocked", "stage": "Buildable"})
finally:
    E.fcntl = real

journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
with open(journal, encoding="utf-8") as fh:
    text = fh.read()
if "lock-test" not in text:
    print("FAIL: a flock error suppressed the append — the lock must be FAIL-SOFT (warn + append anyway)")
    sys.exit(1)
if "lock" not in err.getvalue().lower():
    print("FAIL: a flock error did not warn on stderr (silent degradation)")
    sys.exit(1)
print("  ok (2) a flock error warns and appends anyway (fail-soft; journaling never fails the mutation)")
PY
[ $? -eq 0 ] || exit 1

# ── 3. An UNLOCKED append verifies its inode survived a rotation replace (codex round-10 P2) ───────
# The fail-soft unlocked branch can open the pre-rotation journal inode, get paused while the
# janitor's rotation replaces AND drains it, then write to the unlinked inode — a line the drain
# safety net never sees (the drain read happens before the write). After an unlocked write the
# appender must verify the inode it wrote to is still the journal path (fstat vs stat) and
# re-append to the CURRENT path on a mismatch (a drain-duplicated line is benign; a lost record is
# not). Simulated deterministically: the module's `open` is shadowed so the first journal open
# returns a handle to the OLD inode while the path is atomically replaced — exactly the post-drain
# race window.
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || exit 1
import contextlib, io, os, sys
sys.path.insert(0, sys.argv[1])
import idc_transition as E

repo = sys.argv[2]
jp = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
os.makedirs(os.path.dirname(jp), exist_ok=True)

class _Raiser:                       # force the fail-soft UNLOCKED branch
    LOCK_EX = getattr(E.fcntl, "LOCK_EX", 2)
    def flock(self, *a, **k):
        raise OSError("synthetic flock failure")

real_open, state = open, {"rotated": False}
def rotating_open(p, mode="r", *a, **k):
    fh = real_open(p, mode, *a, **k)
    if p == jp and "a" in mode and not state["rotated"]:
        state["rotated"] = True      # the rotation replaces the path AFTER this appender opened the old inode
        tmp = jp + ".rotation-tmp"
        real_open(tmp, "w").close()
        os.replace(tmp, jp)
    return fh

real_fcntl, E.fcntl = E.fcntl, _Raiser()
E.open = rotating_open               # shadow the builtin inside the module under test
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        E.journal_append(repo, "move", "filesystem", "TRACKER.md",
                         {"num": 2, "to_status": "Todo", "agent": "inode-race-test"},
                         cur={"status": "Blocked", "stage": "Buildable"})
finally:
    E.fcntl = real_fcntl
    del E.open

assert state["rotated"], "test harness: the simulated rotation never fired"
with open(jp, encoding="utf-8") as fh:
    text = fh.read()
if "inode-race-test" not in text:
    print("FAIL: an unlocked append wrote to the rotation-replaced inode and the line was LOST — "
          "the appender must verify its inode is still the journal path and re-append")
    sys.exit(1)
if "rotated during an unlocked append" not in err.getvalue():
    print("FAIL: the re-append did not disclose the rotation race on stderr")
    sys.exit(1)
print("  ok (3) an unlocked append that raced a rotation re-appends to the CURRENT journal (no lost line)")
PY
[ $? -eq 0 ] || exit 1

# ── 4. The unlocked re-append never lands an OLDER record after a NEWER same-item record ──────────
# (codex round-11 P2): rotation drains our first write into the new journal, ANOTHER writer journals
# a newer same-item transition, then our delayed retry lands last — replay reconstructs an item's
# state from its LAST record, so the stale retry would rewind reconstruction (a false divergence).
# Before retrying, the appender scans the current journal: our exact line already present (4b), or
# a same-item record timestamped at/after ours (4a) → SKIP the retry; an OLDER same-item record must
# NOT suppress it (4c — the over-skip control). Unit-tests _unlocked_append directly with the same
# open-shadow rotation simulation as case 3, parameterized by the replacement journal's content.
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || exit 1
import contextlib, io, json, os, sys
sys.path.insert(0, sys.argv[1])
import idc_transition as E

repo = sys.argv[2]
jp = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
os.makedirs(os.path.dirname(jp), exist_ok=True)

OURS = json.dumps({"when": "2026-07-10T00:00:00Z", "who": "a", "what": "move #7 Blocked -> Todo",
                   "op": "move", "item": 7, "to": {"status": "Todo"}}, sort_keys=True, ensure_ascii=False)
NEWER = json.dumps({"when": "2026-07-10T00:00:05Z", "who": "b", "what": "dispose #7 Todo -> Done",
                    "op": "dispose", "item": 7, "to": {"status": "Done"}}, sort_keys=True, ensure_ascii=False)
OLDER = json.dumps({"when": "2026-07-09T23:59:00Z", "who": "c", "what": "claim #7 Todo -> In Progress",
                    "op": "claim", "item": 7, "to": {"status": "In Progress"}}, sort_keys=True, ensure_ascii=False)

real_open = open
def run_case(replacement_lines):
    """Drive _unlocked_append(jp, OURS) while a simulated rotation replaces jp (content =
    replacement_lines) right after the appender opened the OLD inode. Returns (journal_text, stderr)."""
    with real_open(jp, "w", encoding="utf-8") as fh:
        fh.write("")                        # the pre-rotation inode
    state = {"rotated": False}
    def rotating_open(p, mode="r", *a, **k):
        fh = real_open(p, mode, *a, **k)
        if p == jp and "a" in mode and not state["rotated"]:
            state["rotated"] = True
            tmp = jp + ".rotation-tmp"
            with real_open(tmp, "w", encoding="utf-8") as t:
                t.write("".join(l + "\n" for l in replacement_lines))
            os.replace(tmp, jp)
        return fh
    E.open = rotating_open
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            E._unlocked_append(jp, OURS)
    finally:
        del E.open
    assert state["rotated"], "test harness: the simulated rotation never fired"
    with real_open(jp, encoding="utf-8") as fh:
        return fh.read(), err.getvalue()

# 4a — a NEWER same-item record already landed: the retry is SKIPPED, ours never lands after it.
text, err = run_case([NEWER])
if OURS in text:
    print("FAIL: the unlocked retry re-appended an OLDER record AFTER a newer same-item record — "
          "replay's last-record-wins reconstruction now reads stale state (false divergence)")
    sys.exit(1)
if "skipping the re-append" not in err:
    print("FAIL: the skipped retry did not disclose itself on stderr")
    sys.exit(1)
print("  ok (4a) a newer same-item record in the current journal suppresses the stale retry (disclosed)")

# 4b — the rotation's drain already preserved OUR EXACT line: the retry is skipped, no duplicate.
text, err = run_case([OURS])
if text.count(OURS) != 1:
    print(f"FAIL: the drain-preserved line should appear exactly once, got {text.count(OURS)}")
    sys.exit(1)
print("  ok (4b) a drain-preserved exact line suppresses the retry (no duplicate)")

# 4c — the over-skip control: only an OLDER same-item record exists → the retry MUST land (the line
# was genuinely lost; an older record can never be regressed by appending a newer one after it).
text, err = run_case([OLDER])
if OURS not in text:
    print("FAIL: the retry was suppressed by an OLDER same-item record — the ordering check "
          "over-skips and loses a recoverable journal line")
    sys.exit(1)
if text.find(OLDER) > text.find(OURS):
    print("FAIL: the re-appended line landed BEFORE the older record (ordering broken)")
    sys.exit(1)
print("  ok (4c) an older same-item record does NOT suppress the retry (the lost line is recovered, in order)")

# 4d — the ordering scan covers ARCHIVE segments (codex round-12 P2): replay reads archives first,
# so a NEWER same-item record the rotation already archived regresses just the same if the stale
# retry lands in the (empty) active journal. The retry must be skipped.
arch_dir = os.path.join(os.path.dirname(jp), "journal-archive")
os.makedirs(arch_dir, exist_ok=True)
arch = os.path.join(arch_dir, "0001.ndjson")
with real_open(arch, "w", encoding="utf-8") as fh:
    fh.write(NEWER + "\n")
text, err = run_case([])                     # active journal replaced EMPTY; the newer record is archived
if OURS in text:
    print("FAIL: a newer same-item record in an ARCHIVE segment did not suppress the stale retry — "
          "the ordering scan is blind to rotated segments (replay reads archives first)")
    sys.exit(1)
if "skipping the re-append" not in err:
    print("FAIL: the archive-suppressed retry did not disclose itself on stderr")
    sys.exit(1)
print("  ok (4d) a newer same-item record in a rotation ARCHIVE suppresses the stale retry")

# 4e — the archive over-skip control: an archive holding only an OLDER same-item record must not
# suppress the retry (mirror of 4c across segments).
with real_open(arch, "w", encoding="utf-8") as fh:
    fh.write(OLDER + "\n")
text, err = run_case([])
if OURS not in text:
    print("FAIL: an OLDER archived record suppressed the retry (archive over-skip)")
    sys.exit(1)
print("  ok (4e) an older archived record does NOT suppress the retry")
PY
[ $? -eq 0 ] || exit 1

echo "PASS: journal_append serializes on the STABLE sidecar <journal>.lock (LOCK_EX before opening the journal), stays fail-soft on lock errors, an UNLOCKED append that raced a rotation replace re-appends to the current journal (inode-verified; no lost line), and the re-append is ORDER-SAFE across ALL journal segments (archives included) — skipped (disclosed) when the drain already preserved the line or a newer same-item record landed first, never suppressed by an older one"
