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
    record cannot reproduce would mean it had quietly become a source of truth.
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
renumbers deterministically from the raw record) restarts it.

RUN IDENTITY, stated rather than guessed. A hook receipt carries its `session_id`, so it lands under
that `run_id`. A journal record carries NO session — `idc_transition.journal_append` never stamps one
— so journal events land under the sentinel run `unattributed`. Correlating them onto a session by
timestamp would be fabricated provenance, so the mirror does not do it.

FAIL MODES. Ingest is TOLERANT by design: a malformed or half-written journal line (a live append
caught mid-write) is SKIPPED and COUNTED in the run's summary, never a crash — a post-hoc observer
must never break, and the completed line is picked up on the next poll (records are content-keyed, so
nothing is double-counted). Ingest is REPO-GATED: outside an IDC-governed repo it refuses rather than
littering a directory that is none of IDC's business.

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

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY,   -- == rowid; THE CURSOR (mirror-arrival order)
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
CREATE INDEX IF NOT EXISTS phases_item_idx ON phases(item, entered_ts);
"""


# ── paths + db ───────────────────────────────────────────────────────────────────────────────────
def db_path(repo, override=None):
    return override or os.path.join(repo or ".", DB_FILENAME)


def connect(path):
    """Open (creating if needed) the mirror in WAL mode — a live reader must never block the writer,
    which is what makes polling a mirror that an ingest is actively appending to safe."""
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.executescript(SCHEMA)
    return con


def _sha(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def _iso(epoch):
    """A receipt's POSIX `ts` -> the same ISO-8601 UTC shape the journal writes, so one `ts` column
    is comparable across both sources."""
    try:
        return time.strftime(_TS_FMT, time.gmtime(float(epoch)))
    except (TypeError, ValueError):
        return None


def _duration_s(start, end):
    """Whole seconds between two journal timestamps, or None when either is unparseable (an
    unreadable time yields NO duration rather than a fabricated one)."""
    try:
        a = datetime.datetime.strptime(start, _TS_FMT)
        b = datetime.datetime.strptime(end, _TS_FMT)
    except (TypeError, ValueError):
        return None
    return int((b - a).total_seconds())


# ── reading the raw record ───────────────────────────────────────────────────────────────────────
def journal_segments(repo):
    """Every journal segment in REPLAY'S OWN ORDER — archived terminal segments first, then the live
    one — so the mirror's history reads exactly like a replay of the same repo."""
    return [p for p in RP._journal_paths(os.path.join(repo, JOURNAL_REL)) if os.path.exists(p)]


def journal_events(repo):
    """`(events, skipped)` from every journal segment. A malformed / half-written line is SKIPPED and
    counted, never fatal: ingest runs against a journal another process is appending to."""
    events, skipped = [], 0
    for path in journal_segments(repo):
        rel = os.path.relpath(path, repo)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                lines = fh.readlines()
        except (OSError, UnicodeDecodeError):
            skipped += 1
            continue
        for num, line in enumerate(lines, 1):
            line = line.strip()
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
            events.append({
                "run_id": UNATTRIBUTED,
                "source": "journal",
                "artifact": rel,
                "seq": num,
                "ts": str(rec.get("when") or "") or None,
                "op": str(rec.get("op") or "") or None,
                "item": RP.journal_item_id(rec),
                "stage": state.get("stage"),
                "status": state.get("status"),
                "who": str(rec.get("who") or "") or None,
                "summary": str(rec.get("what") or "") or None,
                "event_key": "journal:" + _sha(line),
                "payload": line,
            })
    return events, skipped


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
    per-record inside it — is NOT a run receipt and is left to its own module. Each distinct CONTENT
    of a receipt is one event, so the last-write-wins sidecars contribute one row per state they were
    actually observed in."""
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
    """Mirror every raw record not already present. Returns `(inserted, skipped)`.

    IDEMPOTENT by CONTENT: `event_key` is a hash of the record itself, so re-running is a no-op, a
    rotated line (moved from the live segment into the archive) is not re-ingested under its new
    path, and only genuinely new records advance the cursor. Insertion order is deterministic —
    journal segments in replay order, then receipts by filename — so two rebuilds of the same raw
    record assign identical cursor ids."""
    j_events, j_skipped = journal_events(repo)
    r_events, r_skipped = receipt_events(repo)
    inserted = 0
    with con:
        for ev in j_events + r_events:
            cur = con.execute(
                "INSERT OR IGNORE INTO events (%s) VALUES (%s)"
                % (", ".join(_COLS), ", ".join("?" * len(_COLS))),
                tuple(ev[c] for c in _COLS))
            inserted += cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0
        _rebuild_phases(con)
    return inserted, j_skipped + r_skipped


def _rebuild_phases(con):
    """Re-derive the phase spans wholesale from `events`.

    A PHASE IS A CONTIGUOUS INTERVAL AN ITEM SPENT IN ONE JOURNALED STATUS. Status — not Stage — is
    the dimension the journal tracks continuously: a mid-lifecycle op (move/claim/unblock) journals
    ONLY `to.status`, while Stage is asserted at create and at terminal ops. The stage last KNOWN at
    entry rides along as context, never carried past a later Stage assertion. A phase that has not
    been left has no `exited_ts` and no duration — the mirror does not close a span the record
    leaves open. Derived-of-derived and cheap, so it is rebuilt rather than incrementally patched."""
    con.execute("DELETE FROM phases")
    rows = con.execute(
        "SELECT id, run_id, item, stage, status, ts FROM events "
        "WHERE source = 'journal' AND item IS NOT NULL ORDER BY ts, id").fetchall()
    open_span = {}      # item -> the span currently accruing
    last_stage = {}     # item -> the most recent stage the record asserted
    out = []
    for ev_id, run_id, item, stage, status, ts in rows:
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
def cmd_ingest(args, con):
    inserted, skipped = ingest(args.repo, con)
    total = con.execute("SELECT count(*) FROM events").fetchone()[0]
    cursor = con.execute("SELECT coalesce(max(id), 0) FROM events").fetchone()[0]
    print("ingested: %d new · %d total · cursor %d" % (inserted, total, cursor))
    if skipped:
        # Never silent: a skipped line means the VIEW is incomplete, and the operator has to know
        # that rather than read a short trace as a quiet run.
        print("skipped: %d unparseable record(s) — half-written or damaged; re-run to pick them up"
              % skipped)
    return 0


def cmd_tail(args, con):
    ingest(args.repo, con)
    print_events(cursor_query(con, args.since, args.run), as_json=args.json)
    return 0


def cmd_watch(args, con):
    """The cursor query in a sleep loop — that is the entire live surface. Starts at the CURRENT end
    of the mirror (tail -f semantics) unless `--since` names a cursor to replay from. `--max-polls`
    bounds a run so a watch can be scripted; Ctrl-C exits cleanly."""
    cursor = args.since
    if cursor is None:
        cursor = con.execute("SELECT coalesce(max(id), 0) FROM events").fetchone()[0]
    polls = 0
    try:
        while True:
            ingest(args.repo, con)
            rows = cursor_query(con, cursor, args.run)
            if rows:
                print_events(rows, as_json=args.json)
                cursor = rows[-1][0]
            polls += 1
            if args.max_polls and polls >= args.max_polls:
                return 0
            time.sleep(args.interval)
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
    rows = con.execute(
        "SELECT phase, stage, entered_ts, exited_ts, duration_s FROM phases "
        "WHERE item = ? ORDER BY entered_ts, id", (args.item,)).fetchall()
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
    for suffix in ("", "-wal", "-shm"):
        try:
            os.remove(path + suffix)
        except OSError:
            pass
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
