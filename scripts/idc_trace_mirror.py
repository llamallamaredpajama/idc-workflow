#!/usr/bin/env python3
"""idc_trace_mirror.py — the live, queryable run trace (issue #195).

WHAT THIS IS. An idempotent ingester that mirrors IDC's RAW record — the engine's transition journal
(`docs/workflow/transition-journal.ndjson` + its rotated `journal-archive/` segments) and the hook
receipt sidecars (`.idc-drain-verdict.json`, `.idc-<kind>-report.json`, …) — into a local WAL SQLite
view, so a run can be WATCHED WHILE IT IS LIVE and audited afterwards through ONE cursor query
instead of tailing NDJSON and cross-reading the board.

THE DOCTRINE, and it is the whole reason a derived cache is safe here:

  * DERIVED. Every row is rebuilt from the raw artifacts. The mirror parses; it never invents. A
    journal record that asserts no Stage produces a row with no Stage — carrying one forward would
    be the mirror claiming board state the record never made.
  * DISPOSABLE. Deleting the db loses NOTHING. `rebuild` (or `rm` + `ingest`) converges to the same
    content, which is the property that keeps the mirror honest: anything it holds that the raw
    record cannot reproduce would mean it had quietly become a source of truth. THE INVARIANT,
    enforced on every ingest and asserted by the lane: after any ingest over a CLEANLY READ source,
    the mirror's content is exactly what a rebuild-from-scratch would produce. So a row is dropped
    when the record behind it is gone — a receipt sidecar rewritten (last-write-wins: the previous
    content no longer exists anywhere) or deleted, a journal line no longer in any segment — and a
    journal row's `artifact`/`seq` FOLLOW their record when a rotation moves it into the archive.
    The mirror shows the last observed state of each sidecar, never a history the sidecar itself
    does not keep.
  * NEVER AUTHORITATIVE, AND NO GATE MAY READ IT. Gates, guards, the janitor's divergence pass and
    every closeout keep reading the RAW artifacts (`idc_journal_replay`, `idc_ledger`,
    `idc_drain_verdict`, the board). This module is an OPERATOR SURFACE only — a read-only lens.
    `tests/smoke/phase12-trace-mirror.sh` asserts that mechanically: nothing else in the plugin may
    reference this file, so the day a gate starts consulting the derived view, that lane goes red.

THE ONE CURSOR-POLL CONTRACT — live view and history are the SAME query at different cadence:

    select * from events where run_id = ? and rowid > ? order by rowid

No server, no websocket, no ingest endpoint: `watch` is that query in a sleep loop, and a poll is
`ingest` (cheap, incremental) followed by the same read. `id` IS the rowid and is MIRROR-ARRIVAL
order, not record time — so a cursor is valid for the lifetime of one mirror, and a rebuild (which
renumbers deterministically from the raw record) restarts it. Ids are AUTOINCREMENT, hence never
reused: a superseded receipt version is really deleted, and the row that replaces it lands ABOVE
every cursor a watcher can be holding, so the new state is delivered rather than silently swapped in
under an id the watcher has already passed.

RUN IDENTITY, stated rather than guessed. A hook receipt carries its `session_id`, so it lands under
that `run_id`. A journal record carries NO session — `idc_transition.journal_append` never stamps one
— so journal events land under the sentinel run `unattributed`. Correlating them onto a session by
timestamp would be fabricated provenance, so the mirror does not do it.

FAIL MODES. Ingest is TOLERANT by design: a malformed or half-written journal line (a live append
caught mid-write) — including one that PARSES but asserts a non-scalar stage/status the mirror
cannot honestly store — is SKIPPED and COUNTED in the run's summary, never a crash: a post-hoc
observer must never break, and the completed line is picked up on the next poll (records are
content-keyed, so nothing is double-counted). Every surface that ingests REPORTS that count —
`ingest`, `tail` and `watch` alike — because a short trace must never read as a quiet one; `tail`
and `watch` report on stderr so a `--json` stdout stays machine-readable, and `watch` reports only
when the count CHANGES so a poll loop neither spams nor goes quiet. Ingest is REPO-GATED: outside an
IDC-governed repo it refuses rather than littering a directory that is none of IDC's business. The
journal is read through the SAME sidecar-lock discipline the guards use (`idc_journal_replay.
read_journal_locked`): an unlocked scan racing a rotation reads the pre-rotation archive and the
post-rotation live segment, and the records moved in between appear in NEITHER — a silent hole in
a trace whose whole job is to be complete. Damage is bounded to the damaged THING: one undecodable
line costs that line and not its segment, an unstorable item number or timestamp costs that record,
and a corrupt mirror db is discarded and re-derived rather than raising out of every door (including
the `rebuild` that is meant to BE the recovery). And only the segment BYTES are read under the
journal's lock — the parse happens after it is released, so the observer never makes the watched
run's own writers queue behind its bookkeeping.

USAGE:
    python3 idc_trace_mirror.py --repo <root> ingest                 # idempotent; safe to re-run
    python3 idc_trace_mirror.py --repo <root> tail --since N [--run ID] [--json]
    python3 idc_trace_mirror.py --repo <root> watch [--run ID] [--interval S] [--max-polls N]
    python3 idc_trace_mirror.py --repo <root> sessions               # canned: runs + counts + span
    python3 idc_trace_mirror.py --repo <root> timeline --item N      # canned: one item's phases
    python3 idc_trace_mirror.py --repo <root> timing                 # canned: per-phase durations
    python3 idc_trace_mirror.py --repo <root> rebuild                # drop + re-ingest (disposable)
    python3 idc_trace_mirror.py --repo <root> path | ensure-gitignore
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import sqlite3
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "hooks"))
import idc_hook_lib  # noqa: E402  (is_governed_repo / ensure_gitignored — the ONE repo-gate, shared)
# The journal's meaning is defined ONCE, by the replay module every guard already uses. Re-deriving
# "which item is this record about" / "what state does it assert" here is how a mirror drifts from
# the thing it mirrors, so the ingester borrows replay's own parsers instead.
import idc_journal_replay as RP  # noqa: E402

DB_FILENAME = ".idc-trace-mirror.db"
# One glob covers the db AND its WAL/SHM sidecars (`-wal`, `-shm`) — in gitignore `*` also matches the
# empty string, so the db file itself is ignored too. Same convention as the report sidecar's glob.
GITIGNORE_LINE = DB_FILENAME + "*"
JOURNAL_REL = os.path.join("docs", "workflow", "transition-journal.ndjson")
# A journal record carries no session identity; this is the declared sentinel run it lands under.
UNATTRIBUTED = "unattributed"
_TS_FMT = "%Y-%m-%dT%H:%M:%SZ"

# Bump on ANY change to SCHEMA below — or to the IDENTITY of what it stores (the `event_key`
# encoding), since a mirror keyed the old way would have every journal row pruned and re-inserted on
# first contact, which a live watcher reads as a burst of brand-new events that never happened. A
# mirror carrying another version is DROPPED and re-derived (see `connect`) — a DISPOSABLE cache
# never needs a migration path, and writing one would be the first step toward treating its contents
# as something that must survive.
# v3: journal event_key gained its occurrence ordinal (identical lines are distinct records).
SCHEMA_VERSION = 3
SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,   -- == rowid; THE CURSOR (mirror-arrival order,
                                        -- never reused: a replaced receipt row must land ABOVE a
                                        -- live watcher's cursor, not back under it)
    run_id     TEXT    NOT NULL,      -- receipt session_id, or 'unattributed' for journal records
    source     TEXT    NOT NULL,      -- 'journal' | 'receipt'
    artifact   TEXT    NOT NULL,      -- repo-relative path of the raw file this came from
    seq        INTEGER,               -- line number within that file (journal), else NULL
    ts         TEXT,                  -- the record's OWN time, normalized to ISO-8601 UTC
    op         TEXT,                  -- journal op, or the receipt kind ('drain-verdict', …)
    item       INTEGER,               -- issue number when the record names one
    stage      TEXT,                  -- ONLY when the record itself asserts one (often absent)
    status     TEXT,                  -- ONLY when the record itself asserts one
    who        TEXT,
    summary    TEXT,                  -- the journal `what` line, or a receipt one-liner
    event_key  TEXT    NOT NULL UNIQUE,  -- content identity -> re-ingest is a no-op
    payload    TEXT    NOT NULL       -- the raw record, verbatim
);
CREATE INDEX IF NOT EXISTS events_run_id_idx ON events(run_id, id);
CREATE INDEX IF NOT EXISTS events_item_idx   ON events(item, id);

CREATE TABLE IF NOT EXISTS phases (
    id               INTEGER PRIMARY KEY,
    run_id           TEXT    NOT NULL,
    item             INTEGER NOT NULL,
    phase            TEXT    NOT NULL,  -- the journaled Status: the dimension the journal tracks
                                        -- continuously (a mid-lifecycle op journals status only)
    stage            TEXT,              -- the last stage the record KNEW at entry, as context
    entered_ts       TEXT,
    exited_ts        TEXT,              -- NULL while the item is still in this phase
    duration_s       INTEGER,           -- NULL while open
    entered_event_id INTEGER NOT NULL,
    exited_event_id  INTEGER
);
CREATE INDEX IF NOT EXISTS phases_item_idx ON phases(item, id);
"""


# ── paths + db ───────────────────────────────────────────────────────────────────────────────────
def db_path(repo, override=None):
    return override or os.path.join(repo or ".", DB_FILENAME)


def _create_private(path):
    """Make the mirror db OWNER-ONLY before SQLite opens it.

    The rows carry the verbatim payloads of receipt sidecars whose own writers create them 0600
    (`idc_hook_lib.atomic_write_json` → `mkstemp`). A db created at the ambient umask (0644 under the
    common 022) would mirror those same bytes to every account on the machine — a derived view must
    never be a wider door onto its source than the source is. SQLite creates `-wal`/`-shm` with the
    database file's own mode, so tightening the db tightens the sidecars with it.

    BEST-EFFORT: on any failure the mirror still works, it is simply no tighter than the umask —
    an observer must never break the run it is watching over its own bookkeeping."""
    try:
        if os.path.exists(path):
            os.chmod(path, 0o600)
        else:
            os.close(os.open(path, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o600))
    except OSError:
        pass   # a racing creator already made it, or the fs has no say — SQLite proceeds either way


def discard(path):
    """Delete the mirror and its WAL/SHM sidecars. Safe by doctrine: nothing here was ever the
    record, so the worst case is the next ingest re-deriving it."""
    for suffix in ("", "-wal", "-shm"):
        try:
            os.remove(path + suffix)
        except OSError:
            pass


def _open(path):
    _create_private(path)
    con = sqlite3.connect(path)
    try:
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("PRAGMA synchronous=NORMAL")
        if con.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
            con.executescript("DROP TABLE IF EXISTS events; DROP TABLE IF EXISTS phases;")
            con.execute("PRAGMA user_version = %d" % SCHEMA_VERSION)
        con.executescript(SCHEMA)
    except sqlite3.DatabaseError:
        con.close()          # release the handle before the caller discards the file
        raise
    return con


def connect(path):
    """Open (creating if needed) the mirror in WAL mode — a live reader must never block the writer,
    which is what makes polling a mirror that an ingest is actively appending to safe.

    A db written by a DIFFERENT schema version is dropped and re-derived rather than migrated: the
    mirror is disposable, so "throw it away and rebuild from the raw record" is always available and
    is the only reconciliation that cannot invent state.

    A db that is CORRUPT — truncated by a full disk, half-written by a killed process, or simply not
    a SQLite file at all — takes the same road, and must, because the alternative is worse than it
    sounds: SQLite raises at the first PRAGMA, i.e. before any subcommand dispatches, so EVERY door
    including `rebuild` — the advertised recovery — died with the same traceback and the operator's
    only way out was knowing to `rm` a file the tool never named. Damage to a derived, disposable
    cache has exactly one correct answer, and the mirror can always take it itself. Reported on
    stderr, never silently: the operator is told their trace restarted (cursors reset with it)."""
    try:
        return _open(path)
    except sqlite3.DatabaseError as exc:
        discard(path)
        sys.stderr.write(
            "idc-trace-mirror: the mirror db at %s was unreadable (%s) — discarded and re-derived "
            "from the raw record. Nothing is lost (the mirror is derived); cursors restart.\n"
            % (path, exc))
        sys.stderr.flush()
        return _open(path)   # a second failure is the filesystem's, not the mirror's — let it raise


def _sha(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def _iso(epoch):
    """A receipt's POSIX `ts` -> the same ISO-8601 UTC shape the journal writes, so one `ts` column
    is comparable across both sources. An unusable time yields None — the receipt still mirrors,
    simply without a normalized timestamp; its verbatim `payload` keeps whatever was written.

    OverflowError/OSError are caught alongside the obvious two because a time can be VALID JSON and
    still be outside the platform's `time_t`: `1e999` parses to `inf`, and `time.gmtime(inf)` raises
    OverflowError on macOS/Linux (OSError on some platforms) rather than ValueError. One damaged
    receipt must never take the ingest — or a live `watch` poll — down with it."""
    try:
        return time.strftime(_TS_FMT, time.gmtime(float(epoch)))
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def _duration_s(start, end):
    """Whole seconds between two journal timestamps, or None when either is unparseable (an
    unreadable time yields NO duration rather than a fabricated one).

    A span whose recorded exit PRECEDES its entry also yields None. Spans are ordered by CANONICAL
    journal order, not by clock, so a clock that moved backwards between two journaled ops leaves
    the sequence correct while the timestamps simply cannot express its length — and "no duration"
    is the honest answer, where a negative one would be arithmetic presented as a measurement."""
    try:
        a = datetime.datetime.strptime(start, _TS_FMT)
        b = datetime.datetime.strptime(end, _TS_FMT)
    except (TypeError, ValueError):
        return None
    seconds = int((b - a).total_seconds())
    return seconds if seconds >= 0 else None


# ── reading the raw record ───────────────────────────────────────────────────────────────────────
def journal_segments(journal_path):
    """Every journal segment in REPLAY'S OWN ORDER — archived terminal segments first, then the live
    one — so the mirror's history reads exactly like a replay of the same repo.

    Enumerated INSIDE the sidecar lock (see `journal_events`): globbing the archive outside it is
    half the rotation race — the other half is reading the live segment after the rotation lands."""
    return [p for p in RP._journal_paths(journal_path) if os.path.exists(p)]


_INVALID = object()   # "the record asserts something the mirror cannot honestly store" sentinel


def _state_scalar(value):
    """A stage/status the mirror can store, or `_INVALID`.

    Replay's parser hands back whatever the record's `to` block held. A malformed record can put a
    list or an object there (`{"to": {"status": []}}`) — parseable JSON, but not a state. Binding it
    raises deep inside SQLite and takes the ingest down, so the observer would CRASH on exactly the
    damaged input its contract promises to skip-and-count. NULL is a real answer (the record asserted
    an empty stage); a container is not."""
    if value is None or isinstance(value, str):
        return value
    return _INVALID


def _snapshot_segments(repo, journal_path):
    """`((blobs, unreadable), None)` — the READER half of the locked read, and NOTHING ELSE.

    THE LOCK IS THE RUN'S, NOT THE OBSERVER'S. `read_journal_locked` holds the journal's SHARED
    sidecar lock across this call, and `journal_append` / the janitor's rotation need the EXCLUSIVE
    one — so every microsecond spent in here is a microsecond the watched run's own writers may sit
    blocked. A `watch` polls every couple of seconds forever, so whatever this does is paid again and
    again against a journal that only grows.

    So it does the one thing that genuinely HAS to happen inside the lock — enumerate the segments
    and slurp their raw bytes, which is what makes the read atomic with respect to a rotation — and
    hands the bytes back. Decoding, JSON, the per-line hashing and every parse decision happen in
    `_parse_snapshot`, OUTSIDE the lock, where they block nobody. Measured on a 60k-line journal that
    moves ~99% of the hold out (0.125s -> ~0.001s per poll).

    RESIDUAL, stated rather than papered over: the mirror still RE-READS every segment's bytes on
    every poll — this is a shorter lock, not an incremental reader — so the hold still grows with
    total journal history, just with a ~100x smaller constant. Holding the bytes is also the cost of
    moving the parse out: peak memory is now the segments PLUS the event list they parse into, both
    bounded by total journal size. A real incremental reader (per-segment offsets, or skipping
    unchanged segments by size/mtime) is a cache with its own staleness failure mode, and a derived
    view earns none of that risk for a sequential byte read.

    An unreadable segment is counted, not raised: the parser turns the count into skips, so the
    tolerant contract is unchanged."""
    blobs, unreadable = [], 0
    for path in journal_segments(journal_path):
        rel = os.path.relpath(path, repo)
        try:
            with open(path, "rb") as fh:
                blobs.append((rel, fh.read()))
        except OSError:
            unreadable += 1
        # NOTE: bytes, not text. A segment is decoded PER LINE in the parser, so one undecodable line
        # costs that line — a whole-file `read(encoding="utf-8")` here would raise on it and take
        # every valid record in the segment with it.
    return (blobs, unreadable), None


# SQLite stores integers as signed 64-bit. A journal record naming an item outside that range is
# damage (no tracker mints one), but `json.loads` will happily hand back a 26-digit int, and binding
# it raises OverflowError from deep inside the INSERT — taking down the whole poll, including the
# good events sharing its transaction. Range-checked at parse time so it is skipped and counted like
# any other unstorable record.
_INT64_MIN, _INT64_MAX = -(2 ** 63), 2 ** 63 - 1


def _parse_snapshot(snapshot):
    """`(events, skipped)` from the raw segment bytes — every parse decision, OUTSIDE the lock.

    A malformed / half-written line is SKIPPED and counted, never fatal: ingest runs against a
    journal another process is appending to."""
    blobs, unreadable = snapshot
    events, skipped = [], unreadable
    # OCCURRENCE ORDINAL — see the event_key below.
    occurrences = {}
    for rel, blob in blobs:
        for num, raw in enumerate(blob.split(b"\n"), 1):
            try:
                line = raw.decode("utf-8").strip()
            except UnicodeDecodeError:
                skipped += 1   # THIS line is damaged; its neighbours in the segment still land
                continue
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                skipped += 1   # a partial append mid-write; the finished line lands next poll
                continue
            if not isinstance(rec, dict):
                skipped += 1
                continue
            # Replay's own parsers decide what the record MEANS (item, asserted stage/status), so the
            # mirror can never disagree with the guards about a record it is showing the operator.
            state = RP._entry_to_state(rec)
            stage = _state_scalar(state.get("stage"))
            status = _state_scalar(state.get("status"))
            if stage is _INVALID or status is _INVALID:
                skipped += 1   # parseable, but its asserted state is not a state — see _state_scalar
                continue
            item = RP.journal_item_id(rec)
            if item is not None and not (_INT64_MIN <= item <= _INT64_MAX):
                skipped += 1   # unstorable item number — see _INT64_MIN/_INT64_MAX
                continue
            # IDENTITY = CONTENT + OCCURRENCE ORDINAL. Content alone is not an identity: the engine
            # deliberately journals a RECLAIM of an already-In-Progress item (idc_transition), and two
            # of them inside one timestamp second are BYTE-IDENTICAL lines. Keyed by content alone the
            # second real claim collided with the first and INSERT OR IGNORE silently dropped it — the
            # mirror showing one claim where the record holds two.
            #
            # The ordinal is "the Nth line with this content, in CANONICAL replay order" — archived
            # segments then the live one, by line within each. It is deliberately NOT per-segment
            # position: a rotation MOVES lines between segments, and a key that moved with them would
            # re-ingest the same record under its new path, breaking the rotation no-re-ingest
            # property. A rotation preserves the MULTISET of lines, so the ordinal of each identical
            # line is stable across one — the set of keys is unchanged, and only `artifact`/`seq`
            # follow the record (`_refresh_provenance`). Rebuild walks the same order and assigns the
            # same ordinals, so convergence holds.
            digest = _sha(line)
            ordinal = occurrences.get(digest, 0)
            occurrences[digest] = ordinal + 1
            events.append({
                "run_id": UNATTRIBUTED,
                "source": "journal",
                "artifact": rel,
                "seq": num,
                "ts": str(rec.get("when") or "") or None,
                "op": str(rec.get("op") or "") or None,
                "item": item,
                "stage": stage,
                "status": status,
                "who": str(rec.get("who") or "") or None,
                "summary": str(rec.get("what") or "") or None,
                "event_key": "journal:%s:%d" % (digest, ordinal),
                "payload": line,
            })
    return events, skipped


def journal_events(repo):
    """`(events, skipped, note)` from every journal segment, read under the journal's OWN sidecar
    lock — the same discipline `scan_journal_strict` uses, borrowed rather than re-rolled.

    WHY THE LOCK. The janitor's rotation moves terminal records out of the live segment into an
    archive one with two `os.replace`s. An UNLOCKED scan can read the archive before the first and
    the live segment after the second, and the moved records are then in neither read — the mirror
    reports a clean, complete-looking trace with a run's history silently missing from it.

    A lock that cannot be taken (or a writer that keeps racing) yields NO journal rows this pass and
    a NOTE saying so, counted as a skip: an incomplete view the operator is told about, never a
    partial view presented as whole.

    ONLY THE BYTES ARE READ UNDER THE LOCK (`_snapshot_segments`); the parse runs after it is
    released (`_parse_snapshot`). The lock exists to make the segment set atomic against a rotation,
    which the read achieves — holding it through the parse as well would just make the run's own
    writers queue behind the observer's bookkeeping."""
    journal_path = os.path.join(repo, JOURNAL_REL)
    snapshot, error = RP.read_journal_locked(
        journal_path, lambda path: _snapshot_segments(repo, path))
    if error:
        return [], 1, ("the transition journal could not be read consistently (%s) — no journal "
                       "records mirrored this pass; re-run once the writer settles" % error)
    events, skipped = _parse_snapshot(snapshot)
    return events, skipped, None


def _receipt_summary(rec):
    """A receipt's scalar fields as one readable line (containers are already in `payload`)."""
    parts = ["%s=%s" % (k, rec[k]) for k in sorted(rec)
             if k not in ("version", "session_id", "ts", "producer")
             and not isinstance(rec[k], (dict, list))]
    return " ".join(parts) or None


def receipt_events(repo):
    """`(events, skipped)` from the repo-root hook receipt sidecars.

    THE RULE, declared rather than hard-coded per file: a root-level `.idc-*.json` whose top-level
    object carries a `session_id` IS a per-run receipt (`.idc-drain-verdict.json`,
    `.idc-<kind>-report.json`, …). One that does not — the obligations ledger, whose session ids live
    per-record inside it — is NOT a run receipt and is left to its own module.

    ONE ROW PER SIDECAR, HOLDING ITS CURRENT CONTENT. The key is content-based so a re-ingest of an
    unchanged receipt is a no-op; when the content DOES change, `ingest` inserts the new state and
    prunes the old row, because these sidecars are last-write-wins and the previous version no longer
    exists in the raw record. Retaining both would give the mirror a history nothing else can
    reproduce — the exact shape of a derived cache becoming a source of truth, and a `rebuild` (which
    can only ever see the current content) would then silently DELETE trace the operator had come to
    rely on. A live watcher still sees each change: the replacement row is appended at a fresh
    cursor id rather than edited in place."""
    events, skipped = [], 0
    for path in sorted(glob.glob(os.path.join(repo, ".idc-*.json"))):
        base = os.path.basename(path)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                raw = fh.read()
            rec = json.loads(raw)
        except (OSError, UnicodeDecodeError, ValueError):
            skipped += 1
            continue
        if not isinstance(rec, dict):
            skipped += 1
            continue
        session = rec.get("session_id")
        if not isinstance(session, str) or not session.strip():
            continue   # not a per-run receipt (see the rule above) — silently out of scope
        kind = base[len(".idc-"):-len(".json")] if base.endswith(".json") else base
        events.append({
            "run_id": session,
            "source": "receipt",
            "artifact": base,
            "seq": None,
            "ts": _iso(rec.get("ts")),
            "op": kind,
            "item": None,
            "stage": None,
            "status": None,
            "who": str(rec.get("producer") or "") or None,
            "summary": _receipt_summary(rec),
            "event_key": "receipt:%s:%s" % (base, _sha(raw)),
            "payload": raw.strip(),
        })
    return events, skipped


# ── ingest (idempotent) ──────────────────────────────────────────────────────────────────────────
_COLS = ("run_id", "source", "artifact", "seq", "ts", "op", "item",
         "stage", "status", "who", "summary", "event_key", "payload")


def ingest(repo, con):
    """Mirror the raw record as it stands NOW. Returns `(inserted, skipped, note)`.

    IDEMPOTENT by CONTENT: `event_key` is a hash of the record itself, so re-running is a no-op, a
    rotated line (moved from the live segment into the archive) is not re-ingested under its new
    path, and only genuinely new records advance the cursor. Insertion order is deterministic —
    journal segments in replay order, then receipts by filename — so two rebuilds of the same raw
    record assign identical cursor ids.

    CONVERGENT, which is the disposability doctrine made operational: what stands here after any
    number of incremental ingests equals what a rebuild-from-scratch produces. Two things beyond the
    insert are needed for that, both of them cases where the raw record MOVED or SHRANK under a row
    that was already mirrored — see `_refresh_provenance` and `_prune_vanished`."""
    j_events, j_skipped, note = journal_events(repo)
    r_events, r_skipped = receipt_events(repo)
    inserted = 0
    with con:
        # INSERT FIRST, prune second. A replaced receipt's new row must be allocated while the old
        # one is still present, so it can never be handed the id the pruned row just freed (belt to
        # AUTOINCREMENT's braces) — a live watcher advances its cursor past ids, never back to them.
        for ev in j_events + r_events:
            cur = con.execute(
                "INSERT OR IGNORE INTO events (%s) VALUES (%s)"
                % (", ".join(_COLS), ", ".join("?" * len(_COLS))),
                tuple(ev[c] for c in _COLS))
            if cur.rowcount and cur.rowcount > 0:
                inserted += 1
            elif ev["source"] == "journal":
                _refresh_provenance(con, ev)
        _prune_vanished(con, "journal", j_events, j_skipped)
        _prune_vanished(con, "receipt", r_events, r_skipped)
        _rebuild_phases(con)
    return inserted, j_skipped + r_skipped, note


def _refresh_provenance(con, ev):
    """Point an already-mirrored journal row at where its record ACTUALLY IS NOW.

    A rotation moves a line from the live segment into an archive segment and renumbers the lines
    that stay behind. The row is content-keyed, so it is correctly NOT re-inserted — but its
    `artifact`/`seq` still name the pre-rotation location, sending an auditor to a file and line
    that no longer hold the record, and disagreeing with what a rebuild would derive from the same
    repo. The content, the identity and the cursor id are untouched: only the pointer follows."""
    con.execute(
        "UPDATE events SET artifact = ?, seq = ? "
        "WHERE event_key = ? AND (artifact IS NOT ? OR seq IS NOT ?)",
        (ev["artifact"], ev["seq"], ev["event_key"], ev["artifact"], ev["seq"]))


def _prune_vanished(con, source, events, skipped):
    """Drop mirrored rows whose record the raw artifacts NO LONGER HOLD — a receipt sidecar that has
    been rewritten (last-write-wins: its previous content is gone) or deleted, a journal line no
    longer present in any segment. Without this the mirror accumulates state that only IT has, which
    is precisely the point at which a derived view stops being disposable and starts being a source.

    ONLY ON A CLEAN READ of that source (`skipped == 0`). A pass that could not parse everything has
    not established that a missing row is really gone: a half-written line or a momentarily
    unreadable sidecar would otherwise delete a good row and re-insert it on the next poll, which a
    watcher reads as a brand-new event that never happened."""
    if skipped:
        return
    con.execute("CREATE TEMP TABLE IF NOT EXISTS _seen (event_key TEXT PRIMARY KEY)")
    con.execute("DELETE FROM _seen")
    con.executemany("INSERT OR IGNORE INTO _seen (event_key) VALUES (?)",
                    [(ev["event_key"],) for ev in events])
    con.execute("DELETE FROM events WHERE source = ? "
                "AND event_key NOT IN (SELECT event_key FROM _seen)", (source,))


def _canonical_key(artifact, seq, ev_id):
    """A journal row's position in CANONICAL replay order, read off its own provenance: archived
    segments (sorted by name — the order `RP._journal_paths` replays them in) before the live
    segment, then line number. Derived from the record's location, not from when the mirror happened
    to see it, so an incrementally-grown mirror and a fresh rebuild order identically."""
    return (1 if artifact == JOURNAL_REL else 0,
            artifact, seq if seq is not None else 0, ev_id)


def _rebuild_phases(con):
    """Re-derive the phase spans wholesale from `events`.

    A PHASE IS A CONTIGUOUS INTERVAL AN ITEM SPENT IN ONE JOURNALED STATUS. Status — not Stage — is
    the dimension the journal tracks continuously: a mid-lifecycle op (move/claim/unblock) journals
    ONLY `to.status`, while Stage is asserted at create and at terminal ops. The stage last KNOWN at
    entry rides along as context, never carried past a later Stage assertion. A phase that has not
    been left has no `exited_ts` and no duration — the mirror does not close a span the record
    leaves open. Derived-of-derived and cheap, so it is rebuilt rather than incrementally patched.

    THE ORDER IS CANONICAL JOURNAL ORDER — archived segments then the live one, by line within each,
    exactly what a replay reads — and NOT wall-clock `ts`. The journal is an append log, so its own
    order IS the sequence of state changes; a clock that steps backwards between two ops (or an
    out-of-order legacy timestamp) would otherwise sort them the wrong way round and leave an
    EARLIER status standing as the item's open phase. Timestamps are used for durations only."""
    con.execute("DELETE FROM phases")
    rows = con.execute(
        "SELECT id, run_id, item, stage, status, ts, artifact, seq FROM events "
        "WHERE source = 'journal' AND item IS NOT NULL").fetchall()
    rows.sort(key=lambda r: _canonical_key(r[6], r[7], r[0]))
    open_span = {}      # item -> the span currently accruing
    last_stage = {}     # item -> the most recent stage the record asserted
    out = []
    for ev_id, run_id, item, stage, status, ts, _artifact, _seq in rows:
        if stage:
            last_stage[item] = stage
        if not status:
            continue    # a field-only / link record asserts no phase at all
        cur = open_span.get(item)
        if cur is not None and cur["phase"] == status:
            continue    # a re-assertion of the same status is not a new span
        if cur is not None:
            cur["exited_ts"] = ts
            cur["exited_event_id"] = ev_id
            cur["duration_s"] = _duration_s(cur["entered_ts"], ts)
        open_span[item] = {
            "run_id": run_id, "item": item, "phase": status, "stage": last_stage.get(item),
            "entered_ts": ts, "exited_ts": None, "duration_s": None,
            "entered_event_id": ev_id, "exited_event_id": None,
        }
        out.append(open_span[item])
    cols = ("run_id", "item", "phase", "stage", "entered_ts", "exited_ts",
            "duration_s", "entered_event_id", "exited_event_id")
    con.executemany(
        "INSERT INTO phases (%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))),
        [tuple(sp[c] for c in cols) for sp in out])


# ── the cursor query (the one contract) ──────────────────────────────────────────────────────────
def cursor_query(con, since, run=None):
    """THE contract: `where run_id = ? and rowid > ? order by rowid`. The run filter is omitted only
    when the caller watches every run at once; the cursor half is never optional."""
    if run:
        return con.execute(
            "SELECT id, ts, run_id, source, op, item, who, summary FROM events "
            "WHERE run_id = ? AND id > ? ORDER BY id", (run, since)).fetchall()
    return con.execute(
        "SELECT id, ts, run_id, source, op, item, who, summary FROM events "
        "WHERE id > ? ORDER BY id", (since,)).fetchall()


def _fmt_event(row):
    ev_id, ts, run_id, source, op, item, who, summary = row
    return "%-6s %-21s %-14s %-8s %-18s %-6s %s" % (
        ev_id, ts or "-", run_id, source, op or "-",
        ("#%s" % item) if item is not None else "-", summary or "")


def print_events(rows, as_json=False):
    for row in rows:
        if as_json:
            keys = ("id", "ts", "run_id", "source", "op", "item", "who", "summary")
            print(json.dumps(dict(zip(keys, row)), sort_keys=True), flush=True)
        else:
            print(_fmt_event(row), flush=True)


# ── subcommands ──────────────────────────────────────────────────────────────────────────────────
_SKIP_MSG = "skipped: %d unparseable record(s) — half-written or damaged; re-run to pick them up"


def report_skipped(skipped, note, last=None):
    """Tell the operator THE VIEW IS INCOMPLETE. Returns the state to pass back as `last`.

    On STDERR, so `tail --json` / `watch --json` stdout stays a clean stream of records for whatever
    is parsing it. Only when the count or the note CHANGES: a poll loop that reprinted the same
    warning every two seconds would train the operator to ignore it, and one that printed it only
    once would let a later skip pass unnoticed. A count that falls back to zero is reported too —
    "the trace is whole again" is news, and silence there reads as an unresolved gap."""
    if (skipped, note) == last:
        return last
    if skipped:
        sys.stderr.write((_SKIP_MSG + "\n") % skipped)
    elif last is not None and last[0]:
        sys.stderr.write("skipped: 0 — the previously unreadable record(s) parsed cleanly\n")
    if note:
        sys.stderr.write("note: %s\n" % note)
    sys.stderr.flush()
    return (skipped, note)


def cmd_ingest(args, con):
    inserted, skipped, note = ingest(args.repo, con)
    total = con.execute("SELECT count(*) FROM events").fetchone()[0]
    cursor = con.execute("SELECT coalesce(max(id), 0) FROM events").fetchone()[0]
    print("ingested: %d new · %d total · cursor %d" % (inserted, total, cursor))
    if skipped:
        # Never silent: a skipped line means the VIEW is incomplete, and the operator has to know
        # that rather than read a short trace as a quiet run.
        print(_SKIP_MSG % skipped)
    if note:
        print("note: %s" % note)
    return 0


def cmd_tail(args, con):
    _, skipped, note = ingest(args.repo, con)
    print_events(cursor_query(con, args.since, args.run), as_json=args.json)
    # AFTER the rows, where a terminal reader will actually see it: a tail that returned three lines
    # because two records were unreadable must not look like a tail that returned three lines.
    report_skipped(skipped, note)
    return 0


def cmd_watch(args, con):
    """The cursor query in a sleep loop — that is the entire live surface. Starts at the CURRENT end
    of the mirror (tail -f semantics) unless `--since` names a cursor to replay from. `--max-polls`
    bounds a run so a watch can be scripted; Ctrl-C exits cleanly."""
    # INGEST BEFORE TAKING THE DEFAULT CURSOR. On the first watch of a repo that already has history
    # but no mirror yet, an end-of-mirror cursor read from the still-empty db is 0, and the ingest
    # that follows then replays every record the repo has ever had as though it had just happened —
    # the opposite of the tail-follow default. An explicit `--since` is the operator's own choice and
    # is left exactly as given.
    _, skipped, note = ingest(args.repo, con)
    reported = report_skipped(skipped, note)
    cursor = args.since
    if cursor is None:
        cursor = con.execute("SELECT coalesce(max(id), 0) FROM events").fetchone()[0]
    polls = 0
    try:
        while True:
            rows = cursor_query(con, cursor, args.run)
            if rows:
                print_events(rows, as_json=args.json)
                cursor = rows[-1][0]
            polls += 1
            if args.max_polls and polls >= args.max_polls:
                return 0
            time.sleep(args.interval)
            _, skipped, note = ingest(args.repo, con)
            reported = report_skipped(skipped, note, reported)
    except KeyboardInterrupt:
        print("", flush=True)
        return 0


def cmd_sessions(args, con):
    rows = con.execute(
        "SELECT run_id, count(*), min(ts), max(ts), max(id) FROM events "
        "GROUP BY run_id ORDER BY max(id) DESC").fetchall()
    if not rows:
        print("no events mirrored yet — run `ingest`")
        return 0
    print("%-24s %7s  %-21s %-21s %s" % ("RUN", "EVENTS", "FIRST", "LAST", "CURSOR"))
    for run_id, n, first, last, cursor in rows:
        print("%-24s %7d  %-21s %-21s %s" % (run_id, n, first or "-", last or "-", cursor))
    return 0


def cmd_timeline(args, con):
    # ORDER BY id — the spans were written in canonical journal order, so this displays the item's
    # phases in the order the record puts them in, not in whatever order the clocks suggest.
    rows = con.execute(
        "SELECT phase, stage, entered_ts, exited_ts, duration_s FROM phases "
        "WHERE item = ? ORDER BY id", (args.item,)).fetchall()
    if not rows:
        print("no phases mirrored for item %s" % args.item)
        return 0
    print("phase timeline for item %s" % args.item)
    print("%-16s %-16s %-21s %-21s %s" % ("PHASE", "STAGE", "ENTERED", "EXITED", "SECONDS"))
    for phase, stage, entered, exited, dur in rows:
        print("%-16s %-16s %-21s %-21s %s" % (
            phase, stage or "-", entered or "-", exited or "(open)",
            "(open)" if dur is None else dur))
    return 0


def cmd_timing(args, con):
    rows = con.execute(
        "SELECT phase, count(*), sum(duration_s), avg(duration_s) FROM phases "
        "WHERE duration_s IS NOT NULL GROUP BY phase ORDER BY sum(duration_s) DESC").fetchall()
    if not rows:
        print("no completed phases mirrored yet")
        return 0
    print("%-16s %7s %12s %12s" % ("PHASE", "CLOSED", "TOTAL_S", "AVG_S"))
    for phase, n, total, avg in rows:
        print("%-16s %7d %12d %12d" % (phase, n, int(total), int(avg)))
    open_n = con.execute("SELECT count(*) FROM phases WHERE duration_s IS NULL").fetchone()[0]
    if open_n:
        print("(%d phase(s) still open — not counted)" % open_n)
    return 0


def cmd_rebuild(args, con):
    """Prove the disposability claim on demand: drop the mirror and re-derive it from the raw
    record. Nothing is lost, because nothing here was ever the record."""
    con.close()
    path = db_path(args.repo, args.db)
    discard(path)
    fresh = connect(path)
    try:
        return cmd_ingest(args, fresh)
    finally:
        fresh.close()


def ensure_gitignored(repo_root):
    """Ensure the repo-root `.gitignore` ignores the mirror db + its WAL sidecars, idempotently and
    non-destructively. REPO-GATED (a no-op outside a governed repo) exactly like the other transient
    machine-local sidecars — the mirror is working state and must never be committed."""
    return idc_hook_lib.ensure_gitignored(
        repo_root, GITIGNORE_LINE, label="trace-mirror",
        created_comment="# IDC derived run-trace mirror — disposable, rebuildable, never committed.",
        appended_comment="# IDC derived run-trace mirror (disposable; do not commit)")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="IDC derived run-trace mirror — a read-only operator lens over the raw record. "
                    "Derived, disposable, NEVER authoritative; no gate reads it.")
    ap.add_argument("--repo", default=".", help="governed repo root (default: cwd)")
    ap.add_argument("--db", default=None, help="mirror db path (default: <repo>/" + DB_FILENAME + ")")
    sub = ap.add_subparsers(dest="op", required=True)

    sub.add_parser("ingest", help="mirror new raw records (idempotent)")
    sub.add_parser("rebuild", help="delete the mirror and re-derive it from the raw record")
    sub.add_parser("sessions", help="canned query: runs, event counts, time span")
    sub.add_parser("timing", help="canned query: per-phase durations")
    sub.add_parser("path", help="print the mirror db path")
    sub.add_parser("ensure-gitignore", help="idempotently ignore the mirror db (+ WAL sidecars)")

    tp = sub.add_parser("tail", help="the cursor query: rows after --since")
    tp.add_argument("--since", type=int, default=0, help="cursor (exclusive); default 0 = from start")
    tp.add_argument("--run", default=None, help="scope to one run_id")
    tp.add_argument("--json", action="store_true", help="one JSON object per row")

    wp = sub.add_parser("watch", help="poll the cursor query for a live run")
    wp.add_argument("--since", type=int, default=None,
                    help="cursor to replay from (default: the current end of the mirror)")
    wp.add_argument("--run", default=None, help="scope to one run_id")
    wp.add_argument("--interval", type=float, default=2.0, help="poll interval seconds (default 2)")
    wp.add_argument("--max-polls", type=int, default=0, dest="max_polls",
                    help="stop after N polls (default 0 = until Ctrl-C)")
    wp.add_argument("--json", action="store_true", help="one JSON object per row")

    tlp = sub.add_parser("timeline", help="canned query: one item's phase timeline")
    tlp.add_argument("--item", type=int, required=True, help="issue number")

    args = ap.parse_args(argv)
    repo = args.repo

    if args.op == "path":
        print(db_path(repo, args.db))
        return 0
    if args.op == "ensure-gitignore":
        ensure_gitignored(repo)
        return 0

    if not idc_hook_lib.is_governed_repo(repo):
        sys.stderr.write(
            "idc-trace-mirror: %s is not an IDC-governed repo (no docs/workflow/tracker-config.yaml)"
            " — refusing to mirror a repo that is none of IDC's business.\n" % os.path.abspath(repo))
        return 2

    con = connect(db_path(repo, args.db))
    try:
        handler = {
            "ingest": cmd_ingest, "tail": cmd_tail, "watch": cmd_watch,
            "sessions": cmd_sessions, "timeline": cmd_timeline, "timing": cmd_timing,
            "rebuild": cmd_rebuild,
        }[args.op]
        return handler(args, con)
    finally:
        try:
            con.close()
        except sqlite3.Error:
            pass


if __name__ == "__main__":
    sys.exit(main())
