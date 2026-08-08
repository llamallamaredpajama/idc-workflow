#!/bin/bash
# idc-assert-class: behavior
# Phase 12 (trace mirror) smoke — scripts/idc_trace_mirror.py mirrors the RAW record (the engine's
# transition journal + the hook receipt sidecars) into a DERIVED, DISPOSABLE WAL SQLite view, so a
# live autorun drain can be watched — and a finished run audited — with ONE cursor-poll query
# instead of tailing NDJSON and cross-reading the board (issue #195).
#
# THE DOCTRINE THIS LANE PINS (the mirror is only safe because of it):
#   * derived      — every row is rebuilt from the raw artifacts; the mirror invents nothing.
#   * disposable   — deleting the db loses NOTHING; a rebuild converges to the same content.
#   * never authoritative, and NO GATE MAY READ IT — gates keep reading the raw artifacts.
# The last line is asserted mechanically (arm L), not just documented, because it is the property
# that keeps a derived cache from quietly becoming a second source of truth.
#
# Ingest is exercised against the REAL artifact shapes, not invented ones:
#   - journal records as `idc_transition.journal_append` writes them (when/who/what/op/item/to{...})
#     at docs/workflow/transition-journal.ndjson, plus rotated segments in journal-archive/.
#     NOTE the real sparseness this fixture reproduces deliberately: a MID-lifecycle op (move/claim/
#     unblock) journals ONLY `to.status` — stamping the current Stage there would canonize an
#     out-of-band Stage edit — while create and TERMINAL ops (close/dispose) carry a Stage too. So
#     STATUS is the dimension the journal tracks continuously, and phases are derived from it.
#   - hook receipts as their owner modules write them: `.idc-drain-verdict.json`
#     (idc_drain_verdict) and `.idc-<kind>-report.json` (idc_command_report)
# so drift between a writer and this ingester turns the lane red rather than silently mis-parsing.
#
# Hermetic: no GitHub, no network — a governed temp repo and the shipped helper, exercised directly.
# Usage: bash tests/smoke/phase12-trace-mirror.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN/scripts/idc_trace_mirror.py"
fail() { echo "FAIL: $1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"

[ -f "$SCRIPT" ] || fail "scripts/idc_trace_mirror.py not found (not implemented yet)"

# ---- a governed repo carrying the real raw artifacts --------------------------------------------
mkdir -p "$REPO/docs/workflow/journal-archive" || fail "could not scaffold the temp repo"
# `is_governed_repo` keys on this file; without it every repo-gated door is a silent no-op.
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML

# A ROTATED segment: the janitor moves terminal records here, and replay reads archive-then-live.
# The mirror must ingest both, or a rotated run's history silently disappears from the trace.
cat > "$REPO/docs/workflow/journal-archive/2026-08-01.ndjson" <<'JSON'
{"backend":"filesystem","guard_evidence_hash":null,"item":4,"op":"create-ticket","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'rotated legacy ticket'","when":"2026-08-01T09:00:00Z","who":"idc-think"}
JSON

# The LIVE segment, in `journal_append`'s exact serialization (sorted keys, one JSON object a line).
cat > "$REPO/docs/workflow/transition-journal.ndjson" <<'JSON'
{"backend":"filesystem","guard_evidence_hash":null,"item":7,"op":"create-ticket","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'add jittered retry backoff'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
{"backend":"filesystem","guard_evidence_hash":"a1b2c3d4e5f6","item":7,"op":"move","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"status":"In Progress"},"what":"move #7 Todo -> In Progress","when":"2026-08-06T10:05:00Z","who":"idc-build"}
{"backend":"filesystem","guard_evidence_hash":"a1b2c3d4e5f6","item":7,"op":"close","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"stage":"Build","status":"Done"},"what":"close #7 In Progress -> Done","when":"2026-08-06T10:25:00Z","who":"idc-build"}
JSON

# Hook receipts, in their owner modules' exact shapes (idc_drain_verdict / idc_command_report).
cat > "$REPO/.idc-drain-verdict.json" <<'JSON'
{"version": 2, "verdict": "complete", "exit": 0, "session_id": "S-live", "gates": ["coherence", "live"], "ts": 1785974400.0}
JSON
cat > "$REPO/.idc-doctor-report.json" <<'JSON'
{"version": 2, "kind": "doctor", "session_id": "S-live", "producer": "doctor-command", "ts": 1785974460.0, "payload": {"rows": ["1..10"], "verdict": "PASS"}}
JSON

q() {  # one-shot read-only query against the mirror -> stdout, pipe-joined
  python3 - "$REPO" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
for r in con.execute(sys.argv[2]).fetchall():
    print("|".join("" if c is None else str(c) for c in r))
PY
}

# ---- A. the CLI parses ---------------------------------------------------------------------------
python3 "$SCRIPT" --help >/dev/null 2>&1 || fail "--help should parse"

# ---- B. ingest lands every raw record, with the real field names parsed -------------------------
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "ingest failed on a clean governed repo"
[ -f "$REPO/.idc-trace-mirror.db" ] || fail "ingest did not create .idc-trace-mirror.db at the repo root"

N="$(q "select count(*) from events")"
[ "$N" = "6" ] || fail "expected 6 events (1 archived + 3 live journal + 2 receipts), got: $N"

# The journal fields must be PARSED into columns, not just blobbed: an ingester that stored the raw
# line and nothing else would pass a row count and fail every canned query. The EMPTY stage here is
# the real record's sparseness (a `move` journals status only) faithfully preserved — a mirror that
# carried a stage forward here would be inventing board state the journal never asserted.
ROW="$(q "select op,item,stage,status,who,ts from events where source='journal' and ts='2026-08-06T10:05:00Z'")"
[ "$ROW" = "move|7||In Progress|idc-build|2026-08-06T10:05:00Z" ] \
  || fail "journal record not parsed into columns as expected, got: $ROW"

# The rotated archive segment must be in there too.
ARCH="$(q "select count(*) from events where item=4")"
[ "$ARCH" = "1" ] || fail "the rotated journal-archive segment was not ingested (item 4 rows: $ARCH)"

# The raw record is preserved verbatim alongside the parsed columns (the mirror is a VIEW of the
# record, so an auditor can always get back to exactly what was written).
python3 - "$REPO" <<'PY' || fail "raw payload not preserved verbatim"
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
(raw,) = con.execute("select payload from events where op='close'").fetchone()
rec = json.loads(raw)
assert rec["what"] == "close #7 In Progress -> Done", rec
assert rec["guard_evidence_hash"] == "a1b2c3d4e5f6", rec
assert rec["to"] == {"stage": "Build", "status": "Done"}, rec
PY

# ---- C. receipts carry the session identity as run_id -------------------------------------------
RUN="$(q "select count(*) from events where source='receipt' and run_id='S-live'")"
[ "$RUN" = "2" ] || fail "expected both receipts under run_id S-live, got: $RUN"
KINDS="$(q "select op from events where source='receipt' order by op")"
printf '%s\n' "$KINDS" | grep -qx "drain-verdict" || fail "the drain verdict receipt was not ingested: $KINDS"
printf '%s\n' "$KINDS" | grep -qx "doctor-report" || fail "the doctor report receipt was not ingested: $KINDS"

# A journal record carries NO session identity (journal_append never stamps one), so it must land
# under the declared sentinel — NEVER invented/correlated attribution, which would be the mirror
# fabricating provenance the raw record does not have.
UNATT="$(q "select count(*) from events where source='journal' and run_id='unattributed'")"
[ "$UNATT" = "4" ] || fail "journal events must be run_id='unattributed' (no session in the record), got: $UNATT"

# ---- D. WAL mode (a live reader must never block the writer) ------------------------------------
MODE="$(python3 - "$REPO" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db").execute("pragma journal_mode").fetchone()[0])
PY
)"
[ "$MODE" = "wal" ] || fail "the mirror db must be in WAL mode, got: $MODE"

# ---- E. idempotent re-ingest: no duplicates ------------------------------------------------------
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "second ingest failed"
N2="$(q "select count(*) from events")"
[ "$N2" = "6" ] || fail "re-ingesting unchanged artifacts duplicated rows: $N2 (expected 6)"
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "third ingest failed"
N3="$(q "select count(*) from events")"
[ "$N3" = "6" ] || fail "third ingest duplicated rows: $N3 (expected 6)"

# ---- F. incremental append: only the new record lands, and the cursor advances -------------------
CUR="$(q "select max(id) from events")"
cat >> "$REPO/docs/workflow/transition-journal.ndjson" <<'JSON'
{"backend":"filesystem","guard_evidence_hash":null,"item":9,"op":"create-ticket","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'second ticket'","when":"2026-08-06T11:00:00Z","who":"idc-think"}
JSON
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "incremental ingest failed"
N4="$(q "select count(*) from events")"
[ "$N4" = "7" ] || fail "incremental append should add exactly one row, got: $N4"
CUR2="$(q "select max(id) from events")"
[ "$CUR2" -gt "$CUR" ] || fail "the cursor did not advance on an incremental append ($CUR -> $CUR2)"

# THE CURSOR-POLL CONTRACT ITSELF: `where run_id = ? and rowid > ? order by rowid` — live view and
# history are the same query at different cadence. `tail --since` is that query and nothing else.
TAIL="$(python3 "$SCRIPT" --repo "$REPO" tail --since "$CUR" 2>&1)" || fail "tail --since failed: $TAIL"
printf '%s\n' "$TAIL" | grep -q "second ticket" || fail "tail --since <cursor> did not return the new record: $TAIL"
printf '%s\n' "$TAIL" | grep -q "jittered retry backoff" \
  && fail "tail --since <cursor> re-returned records at/below the cursor (not a cursor query)"

# ...and scoped to one run, it returns only that run's rows.
SCOPED="$(python3 "$SCRIPT" --repo "$REPO" tail --since 0 --run S-live 2>&1)" || fail "tail --run failed: $SCOPED"
printf '%s\n' "$SCOPED" | grep -q "drain-verdict" || fail "tail --run S-live lost that run's rows: $SCOPED"
printf '%s\n' "$SCOPED" | grep -q "second ticket" \
  && fail "tail --run S-live leaked another run's rows: $SCOPED"

# ---- G. DISPOSABLE: delete the db, rebuild, converge to identical content ------------------------
# This is the whole safety argument for a derived mirror — if a rebuild did not converge, the db
# would be holding state the raw record cannot reproduce, i.e. it would have become authoritative.
BEFORE="$(q "select run_id,source,op,item,stage,status,who,ts,event_key,payload from events order by event_key")"
rm -f "$REPO"/.idc-trace-mirror.db*
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "rebuild-from-scratch ingest failed"
AFTER="$(q "select run_id,source,op,item,stage,status,who,ts,event_key,payload from events order by event_key")"
[ "$BEFORE" = "$AFTER" ] || fail "a rebuild from the raw record did NOT converge to the same content"

# Cursor assignment is DETERMINISTIC: two rebuilds of the same raw record agree row-for-row. (Ids
# are mirror-ARRIVAL order, so an incrementally-grown mirror and a fresh rebuild may number the same
# events differently — a cursor is valid for the lifetime of one mirror, and a rebuild restarts it.)
IDS1="$(q "select id,event_key from events order by id")"
rm -f "$REPO"/.idc-trace-mirror.db*
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "second rebuild failed"
IDS2="$(q "select id,event_key from events order by id")"
[ "$IDS1" = "$IDS2" ] || fail "two rebuilds assigned different cursor ids (ingest order is not deterministic)"

# ---- H. phases: per-item spans derived from the journal's continuous dimension -------------------
# The phase table is DERIVED-of-derived: it is rebuilt wholesale on every ingest, so a re-ingest
# must not accumulate duplicate spans. This ingests a SECOND time first, deliberately: arm G leaves
# a freshly-rebuilt (single-ingest) mirror behind, and against that a rebuild that never clears the
# old spans is invisible — every assertion below would read a clean table. The guard only bites when
# it is exercised against a mirror that has ingested more than once.
PHN="$(q "select count(*) from phases")"
python3 "$SCRIPT" --repo "$REPO" ingest >/dev/null 2>&1 || fail "the re-ingest before the phase assertions failed"
PHN2="$(q "select count(*) from phases")"
[ "$PHN" = "$PHN2" ] || fail "a re-ingest duplicated the derived phase rows: $PHN -> $PHN2"

# Item 7 ran Todo (10:00) -> In Progress (10:05) -> Done (10:25). So Todo is a CLOSED 300s span,
# In Progress a CLOSED 1200s span, and Done the OPEN (current) one.
SPAN="$(q "select phase,entered_ts,exited_ts,duration_s from phases where item=7 order by entered_ts")"
EXPECT_SPAN="Todo|2026-08-06T10:00:00Z|2026-08-06T10:05:00Z|300
In Progress|2026-08-06T10:05:00Z|2026-08-06T10:25:00Z|1200
Done|2026-08-06T10:25:00Z||"
[ "$SPAN" = "$EXPECT_SPAN" ] || fail "per-item phase spans wrong.
  got:      $SPAN
  expected: $EXPECT_SPAN"

# An item with a single record has ONE open span (nothing invented to close it).
OPEN="$(q "select phase,exited_ts,duration_s from phases where item=9")"
[ "$OPEN" = "Todo||" ] || fail "a single-record item should have one OPEN span, got: $OPEN"

# The stage last KNOWN at entry rides along as context (sparse in the record, never carried past a
# later stage assertion) — so a timeline can say which stage a phase belonged to without inventing one.
CTX="$(q "select stage from phases where item=7 and phase='In Progress'")"
[ "$CTX" = "Consideration" ] || fail "phase stage-context should be the last KNOWN stage at entry, got: $CTX"

# ---- I. the canned operator queries --------------------------------------------------------------
SESS="$(python3 "$SCRIPT" --repo "$REPO" sessions 2>&1)" || fail "sessions query failed: $SESS"
printf '%s\n' "$SESS" | grep -q "S-live" || fail "sessions did not list the receipt run: $SESS"
printf '%s\n' "$SESS" | grep -q "unattributed" || fail "sessions did not list the journal run: $SESS"

TL="$(python3 "$SCRIPT" --repo "$REPO" timeline --item 7 2>&1)" || fail "timeline query failed: $TL"
printf '%s\n' "$TL" | grep -q "In Progress" || fail "timeline --item 7 lost the In Progress phase: $TL"
printf '%s\n' "$TL" | grep -q "1200" || fail "timeline --item 7 lost the phase duration: $TL"
printf '%s\n' "$TL" | grep -q "item=9\|#9" && fail "timeline --item 7 leaked another item's phases: $TL"

TIMING="$(python3 "$SCRIPT" --repo "$REPO" timing 2>&1)" || fail "timing query failed: $TIMING"
printf '%s\n' "$TIMING" | grep -q "In Progress" || fail "timing lost the In Progress phase: $TIMING"
printf '%s\n' "$TIMING" | grep -q "1200" || fail "timing did not report the 1200s In Progress total: $TIMING"

# ---- J. --watch picks up a record written WHILE it is polling -------------------------------------
# The headline: live, not post-hoc. Bounded by --max-polls so a broken watch can never hang the
# lane (a hang reads as a slow pass, which is worse than a red).
WOUT="$WORK/watch.out"
( python3 "$SCRIPT" --repo "$REPO" watch --interval 0.2 --max-polls 15 > "$WOUT" 2>&1 ) &
WPID=$!
sleep 1
cat >> "$REPO/docs/workflow/transition-journal.ndjson" <<'JSON'
{"backend":"filesystem","guard_evidence_hash":null,"item":9,"op":"move","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"status":"In Progress"},"what":"move #9 Todo -> In Progress","when":"2026-08-06T11:30:00Z","who":"idc-build"}
JSON
wait "$WPID" || fail "watch exited non-zero; output: $(cat "$WOUT" 2>/dev/null)"
grep -q "move #9" "$WOUT" || fail "watch did not surface a record appended DURING the poll loop: $(cat "$WOUT")"
[ "$(grep -c "move #9" "$WOUT" | tr -d ' ')" = "1" ] \
  || fail "watch re-emitted an already-seen record (its cursor does not advance): $(cat "$WOUT")"

# ---- K. the mirror is gitignored, and the scaffold wires that door --------------------------------
python3 "$SCRIPT" --repo "$REPO" ensure-gitignore >/dev/null 2>&1 || fail "ensure-gitignore failed"
grep -q '^\.idc-trace-mirror\.db\*$' "$REPO/.gitignore" \
  || fail "ensure-gitignore did not ignore the mirror db (+ its -wal/-shm sidecars): $(cat "$REPO/.gitignore")"
python3 "$SCRIPT" --repo "$REPO" ensure-gitignore >/dev/null 2>&1 || fail "second ensure-gitignore failed"
[ "$(grep -c 'idc-trace-mirror' "$REPO/.gitignore" | tr -d ' ')" = "1" ] \
  || fail "ensure-gitignore is not idempotent: $(cat "$REPO/.gitignore")"
grep -q "idc_trace_mirror.py" "$PLUGIN/scripts/idc_init_scaffold.sh" \
  || fail "the scaffold does not wire the mirror's ensure-gitignore door (a governed repo would commit the db)"

# A NON-governed dir must never be littered — the same repo-gate every sidecar honors.
mkdir -p "$WORK/plain" || fail "could not create the non-governed dir"
python3 "$SCRIPT" --repo "$WORK/plain" ensure-gitignore >/dev/null 2>&1
[ -f "$WORK/plain/.gitignore" ] && fail "ensure-gitignore littered a NON-governed directory"

# ---- L. DOCTRINE: nothing else in the plugin reads the mirror -------------------------------------
# The mirror is never authoritative and NO GATE MAY READ IT. That is only true while nothing imports
# it, so assert it mechanically: the day a gate starts consulting the derived view instead of the raw
# artifact, this lane goes red and the doctrine gets an explicit decision instead of a silent drift.
# Matched per LINE, not per file, and only over SOURCE surfaces. Two distinctions make this precise
# enough to stay meaningful instead of becoming a file-level allowlist that hides real reads:
#   * `__pycache__` holds compiled bytecode of these same sources — a `.pyc` of the mirror IS the
#     mirror, not a reader, and those dirs exist in any checkout where the suite has run.
#   * NAMING the module is not READING it. Two shipped sites must name it and neither consults its
#     data: the scaffold's `ensure-gitignore` invocation (wiring the gitignore door) and the
#     interlock gate's `_SHIPPED_SCRIPTS` manifest entry, which EVERY shipped script is required to
#     carry (governance/interlock-scripts-manifest.sh fails the build without it). Both are excluded
#     by their exact line shape, so an `import idc_trace_mirror` — or any other real consumption,
#     including one added to those same two files — still trips this.
READERS="$(grep -rn "idc_trace_mirror" --exclude-dir=__pycache__ --exclude="*.pyc" \
            "$PLUGIN/scripts" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/commands" 2>/dev/null \
            | grep -v "/idc_trace_mirror\.py:" \
            | grep -v "/idc_init_scaffold\.sh:.*idc_trace_mirror\.py.*ensure-gitignore" \
            | grep -v "/idc_interlock_gate\.py:.*\"idc_trace_mirror\.py\",")"
[ -z "$READERS" ] || fail "the derived mirror must never be read by a gate/command, but it is referenced by:
$READERS"

# The doctrine is stated where a maintainer will actually see it.
head -40 "$SCRIPT" | grep -qi "never authoritative" \
  || fail "the script docstring must state that the mirror is NEVER authoritative"
head -40 "$SCRIPT" | grep -qi "disposable" \
  || fail "the script docstring must state that the mirror is disposable"

echo "PASS: phase12-trace-mirror"
