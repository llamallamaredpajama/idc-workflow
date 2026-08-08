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
#   * NAMING the module is not READING it. Three shipped sites must name it and none consults its
#     data: the scaffold's `ensure-gitignore` invocation and /idc:update's §C migration of the SAME
#     door (wiring the gitignore rule for a fresh repo and for an upgraded one — arm K asserts both
#     exist), and the interlock gate's `_SHIPPED_SCRIPTS` manifest entry, which EVERY shipped script
#     is required to carry (governance/interlock-scripts-manifest.sh fails the build without it).
#     All three are excluded by their exact line shape, so an `import idc_trace_mirror` — or any
#     other real consumption, including one added to those same three files — still trips this.
READERS="$(grep -rn "idc_trace_mirror" --exclude-dir=__pycache__ --exclude="*.pyc" \
            "$PLUGIN/scripts" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/commands" 2>/dev/null \
            | grep -v "/idc_trace_mirror\.py:" \
            | grep -v "/idc_init_scaffold\.sh:.*idc_trace_mirror\.py.*ensure-gitignore" \
            | grep -v "/update\.md:.*idc_trace_mirror\.py.*ensure-gitignore" \
            | grep -v "/idc_interlock_gate\.py:.*\"idc_trace_mirror\.py\",")"
[ -z "$READERS" ] || fail "the derived mirror must never be read by a gate/command, but it is referenced by:
$READERS"

# The doctrine is stated where a maintainer will actually see it.
head -40 "$SCRIPT" | grep -qi "never authoritative" \
  || fail "the script docstring must state that the mirror is NEVER authoritative"
head -40 "$SCRIPT" | grep -qi "disposable" \
  || fail "the script docstring must state that the mirror is disposable"

# =================================================================================================
# Codex review round 1 (PR #198): nine findings, each pinned below by the property it broke.
# =================================================================================================

# ---- M. THE CONVERGENCE INVARIANT — an incrementally-grown mirror == a rebuilt one ----------------
# Arm G proved a rebuild converges over an UNCHANGING repo. The P1 was the case where the raw record
# MOVES OR SHRINKS underneath rows already mirrored: the hook receipt sidecars are last-write-wins,
# so a normal multi-pass drain rewrites `.idc-drain-verdict.json` between polls. Keyed by content
# alone, the mirror kept BOTH versions while the sidecar kept only the newest — so `rebuild` (which
# can only see the newest) DELETED trace history, which means the db had been the only place that
# history existed. A disposable cache that is the sole holder of anything is not disposable.
#
# Red-when-broken: drop `_prune_vanished` (or key receipts by content alone without it) → the
# superseded verdict row survives an ingest, the rebuild does not have it, and (1) FAILs.
MR="$WORK/converge"
mkdir -p "$MR/docs/workflow/journal-archive"
cat > "$MR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$MR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":11,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'converge me'","when":"2026-08-06T09:00:00Z","who":"idc-think"}
{"item":11,"op":"move","to":{"status":"In Progress"},"what":"move #11 Todo -> In Progress","when":"2026-08-06T09:10:00Z","who":"idc-build"}
JSON
printf '{"version":2,"verdict":"incomplete","exit":1,"session_id":"S-drain","ts":1785974400.0}\n' \
  > "$MR/.idc-drain-verdict.json"
python3 "$SCRIPT" --repo "$MR" ingest >/dev/null 2>&1 || fail "(M) first ingest failed"
V1_ID="$(python3 - "$MR" "select id from events where op='drain-verdict'" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print("\n".join("|".join("" if c is None else str(c) for c in r) for r in con.execute(sys.argv[2])))
PY
)"

# The drain rewrites its verdict (pass 2 of the same run) — the raw sidecar now holds ONLY this.
printf '{"version":2,"verdict":"complete","exit":0,"session_id":"S-drain","ts":1785974500.0}\n' \
  > "$MR/.idc-drain-verdict.json"
python3 "$SCRIPT" --repo "$MR" ingest >/dev/null 2>&1 || fail "(M) ingest after the receipt rewrite failed"
cat >> "$MR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":11,"op":"close","to":{"stage":"Build","status":"Done"},"what":"close #11 In Progress -> Done","when":"2026-08-06T09:40:00Z","who":"idc-build"}
JSON
python3 "$SCRIPT" --repo "$MR" ingest >/dev/null 2>&1 || fail "(M) ingest after the journal append failed"
# ...and the janitor rotates #11's now-terminal history into the archive, under the mirror.
python3 - "$MR" "$PLUGIN" <<'PY' >/dev/null 2>&1 || fail "(M) the janitor rotation fixture failed"
import os, sys
repo, plugin = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts")); sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_git_janitor as J
J.rotate_journal({"repo": repo, "board": [{"number": 11, "status": "Done"}]},
                 os.path.join(repo, "docs/workflow/transition-journal.ndjson"))
PY
python3 "$SCRIPT" --repo "$MR" ingest >/dev/null 2>&1 || fail "(M) ingest after the rotation failed"

CONTENT_COLS="run_id,source,artifact,seq,ts,op,item,stage,status,who,summary,event_key,payload"
MQ() { python3 - "$MR" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
for r in con.execute(sys.argv[2]).fetchall():
    print("|".join("" if c is None else str(c) for c in r))
PY
}
INCR="$(MQ "select $CONTENT_COLS from events order by event_key")"
INCR_PH="$(MQ "select run_id,item,phase,stage,entered_ts,exited_ts,duration_s from phases order by id")"
V2_ID="$(MQ "select id from events where op='drain-verdict'")"
rm -f "$MR"/.idc-trace-mirror.db*
python3 "$SCRIPT" --repo "$MR" ingest >/dev/null 2>&1 || fail "(M) the rebuild-from-scratch ingest failed"
REBUILT="$(MQ "select $CONTENT_COLS from events order by event_key")"
REBUILT_PH="$(MQ "select run_id,item,phase,stage,entered_ts,exited_ts,duration_s from phases order by id")"

# (1) THE INVARIANT itself — every mirrored column, events AND derived phases.
[ "$INCR" = "$REBUILT" ] || fail "(M1) an incrementally-grown mirror DIVERGED from a rebuild — it is
holding state the raw record cannot reproduce, i.e. it has become a source of truth.
  incremental: $INCR
  rebuilt:     $REBUILT"
[ "$INCR_PH" = "$REBUILT_PH" ] || fail "(M1) the derived phase spans diverged from a rebuild's.
  incremental: $INCR_PH
  rebuilt:     $REBUILT_PH"

# (2) concretely: ONE receipt row, holding the sidecar's CURRENT content — not a private history.
VN="$(MQ "select count(*) from events where op='drain-verdict'")"
[ "$VN" = "1" ] || fail "(M2) a rewritten receipt must leave exactly ONE row (its current content), got: $VN"
MQ "select payload from events where op='drain-verdict'" | grep -q '"verdict": *"complete"' \
  || fail "(M2) the surviving receipt row is not the sidecar's current content: $(MQ "select payload from events where op='drain-verdict'")"

# (3) the replacement row lands ABOVE the old cursor id, so a live `watch` DELIVERS the new state
#     instead of swapping it in under an id the watcher has already passed.
[ "$V2_ID" -gt "$V1_ID" ] \
  || fail "(M3) the replacement receipt row reused/undercut the old cursor id ($V1_ID -> $V2_ID) — a
watcher past that cursor would never see the drain's new verdict"
echo "  ok (M) convergence: incremental == rebuild across a receipt rewrite, an append and a rotation"

# ---- N. the journal is read under its OWN sidecar lock (the rotation race) ------------------------
# A rotation moves terminal records with two os.replace calls (archive first, live second). An
# UNLOCKED scan can read the archive BEFORE the first and the live segment AFTER the second — the
# moved records are then in NEITHER read, and the mirror reports a complete-looking trace with a
# run's history silently missing. The mirror must borrow the guards' discipline
# (idc_journal_replay.read_journal_locked), not re-roll a lockless read.
#
# Deterministic, not timing-hopeful: the mirror's archive read is paused (patched `open`) and a REAL
# janitor rotation runs in a subprocess during exactly that pause. Bounded by a wait timeout so a
# blocked rotation can never hang the lane.
# Red-when-broken: call `_snapshot_segments` directly instead of through `read_journal_locked` →
# item 4 vanishes from the mirror and this FAILs.
NR="$WORK/lockrace"
mkdir -p "$NR/docs/workflow/journal-archive"
cat > "$NR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$NR/docs/workflow/journal-archive/2026-07-01.ndjson" <<'JSON'
{"item":1,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'ancient'","when":"2026-07-01T09:00:00Z","who":"idc-think"}
JSON
cat > "$NR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":4,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'about to rotate'","when":"2026-08-01T09:00:00Z","who":"idc-think"}
{"item":4,"op":"close","to":{"stage":"Build","status":"Done"},"what":"close #4 In Progress -> Done","when":"2026-08-01T09:30:00Z","who":"idc-build"}
{"item":7,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'stays live'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
JSON
# The lock sidecar EXISTS, as it does in any repo that has journaled (journal_append mints it as its
# first act) — so this exercises the shared-lock path a real governed repo takes.
: > "$NR/docs/workflow/transition-journal.ndjson.lock"
python3 - "$NR" "$PLUGIN" <<'PY' || fail "(N) the mirror lost records to a concurrent journal rotation"
import builtins, os, subprocess, sys, sqlite3
repo, plugin = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_trace_mirror as TM

journal = os.path.join(repo, "docs/workflow/transition-journal.ndjson")
rotator = (
    "import sys\n"
    "sys.path.insert(0, %r); sys.path.insert(0, %r)\n"
    "import idc_git_janitor as J\n"
    "J.rotate_journal({'repo': %r, 'board': [{'number': 4, 'status': 'Done'}]}, %r)\n"
) % (os.path.join(plugin, "scripts"), os.path.join(plugin, "scripts", "hooks"), repo, journal)

state = {"fired": False, "proc": None}
real_open = builtins.open
def slow_open(path, *a, **k):
    # Pause INSIDE the segment scan, at the archive read, and let a real rotation try to run.
    if not state["fired"] and "journal-archive" in str(path):
        state["fired"] = True
        fh = real_open(path, *a, **k)
        state["proc"] = subprocess.Popen([sys.executable, "-c", rotator],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            state["proc"].wait(timeout=1.5)   # a LOCKED mirror keeps it waiting; an unlocked one does not
        except subprocess.TimeoutExpired:
            pass
        return fh
    return real_open(path, *a, **k)

builtins.open = slow_open
try:
    con = TM.connect(TM.db_path(repo))
    TM.ingest(repo, con)
finally:
    builtins.open = real_open
    con.close()
    if state["proc"] is not None:
        state["proc"].wait()

assert state["fired"], "test setup: the archive read was never reached"
con = sqlite3.connect(os.path.join(repo, ".idc-trace-mirror.db"))
items = sorted(r[0] for r in con.execute("select distinct item from events where item is not null"))
assert items == [1, 4, 7], (
    "an ingest racing a rotation lost records: mirrored items %s, expected [1, 4, 7] — item 4's "
    "history was mid-move between the live segment and the archive and landed in neither read" % items)
PY
echo "  ok (N) an ingest racing a journal rotation loses nothing (the read holds the sidecar lock)"

# ---- O. provenance FOLLOWS the record across a rotation -------------------------------------------
# Rows are content-keyed, so a rotated line is correctly not re-inserted — but `artifact`/`seq` must
# then be re-pointed at where the record ACTUALLY is, or the mirror sends an auditor to a file and
# line that no longer hold it. (Arm M catches the resulting divergence; this names the symptom.)
# Red-when-broken: drop `_refresh_provenance` → the archived record still claims the live segment.
ARCH_ART="$(MQ "select artifact from events where source='journal' and op='close' and item=11")"
case "$ARCH_ART" in
  docs/workflow/journal-archive/*.ndjson) : ;;
  *) fail "(O) a rotated record still points at its pre-rotation location: $ARCH_ART" ;;
esac
echo "  ok (O) a rotated record's artifact/seq follow it into the archive segment"

# ---- P. watch's default cursor is the CURRENT end, taken AFTER the first ingest -------------------
# `watch` documents tail-follow semantics. On the first watch of a repo that already has history but
# no mirror yet, an end-of-mirror cursor read from the still-EMPTY db is 0 — and the ingest that
# follows then replays the repo's entire history as though it had just happened.
# Red-when-broken: move the initial ingest back inside/after the cursor read → (P1) FAILs.
PR2="$WORK/watchcursor"
mkdir -p "$PR2/docs/workflow"
cat > "$PR2/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$PR2/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":21,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'ancient history'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
JSON
WOUT2="$(python3 "$SCRIPT" --repo "$PR2" watch --interval 0.1 --max-polls 1 2>/dev/null)"
printf '%s\n' "$WOUT2" | grep -q "ancient history" \
  && fail "(P1) the first watch replayed pre-existing history instead of following from the current end: $WOUT2"
# ...while an EXPLICIT --since is the operator's own choice and is honored verbatim.
WOUT3="$(python3 "$SCRIPT" --repo "$PR2" watch --since 0 --interval 0.1 --max-polls 1 2>/dev/null)"
printf '%s\n' "$WOUT3" | grep -q "ancient history" \
  || fail "(P2) watch --since 0 must replay from the start, got: $WOUT3"
echo "  ok (P) watch follows from the current end by default, and honors an explicit --since"

# ---- Q. tail and watch REPORT the skipped count ---------------------------------------------------
# "a short trace must never read as a quiet one" — `ingest` said so, but `tail` discarded the count
# and exited 0 with a short trace, and `watch` discarded it on every poll. On stderr, so a --json
# stdout stays parseable; once per CHANGE, so a poll loop neither spams nor goes silent.
# Red-when-broken: drop the `report_skipped` call from cmd_tail/cmd_watch → (Q1)/(Q3) FAIL.
QR="$WORK/skipreport"
mkdir -p "$QR/docs/workflow"
cat > "$QR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$QR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":31,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'good line'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
{"item":32,"op":"move","to":{"status":"In Pro
JSON
TERR="$WORK/tail.err"; TJSON="$WORK/tail.out"
python3 "$SCRIPT" --repo "$QR" tail --since 0 --json > "$TJSON" 2> "$TERR" \
  || fail "(Q1) tail must not fail on a half-written line: $(cat "$TERR")"
grep -q "skipped: 1" "$TERR" \
  || fail "(Q1) tail returned a SHORT trace without reporting the skipped record: $(cat "$TERR")"
# stdout stays machine-readable — the warning must not be mixed into the JSON stream.
python3 - "$TJSON" <<'PY' || fail "(Q2) tail --json stdout is not clean JSON (the warning leaked into it)"
import json, sys
for line in open(sys.argv[1]):
    if line.strip():
        json.loads(line)
PY
WERR="$WORK/watch.err"
python3 "$SCRIPT" --repo "$QR" watch --interval 0.1 --max-polls 3 >/dev/null 2> "$WERR"
[ "$(grep -c "skipped: 1" "$WERR" | tr -d ' ')" = "1" ] \
  || fail "(Q3) watch must report the skipped count exactly once per change across 3 polls, got: $(cat "$WERR")"
echo "  ok (Q) tail and watch report skipped records on stderr, once per change"

# ---- R. a parseable record asserting a NON-SCALAR state is skipped, not fatal ---------------------
# `{"to":{"status":[]}}` parses as JSON and reaches the replay parser, which faithfully hands back a
# list — which SQLite then refuses to bind, crashing ingest (and every watch poll) with a traceback.
# The observer's contract is skip-and-count, and it must hold for damage that parses too.
# Red-when-broken: remove the `_state_scalar` guard → ingest exits non-zero with ProgrammingError.
RR="$WORK/nonscalar"
mkdir -p "$RR/docs/workflow"
cat > "$RR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$RR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":41,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'good'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
{"item":42,"op":"move","to":{"status":[]},"what":"move #42","when":"2026-08-06T10:05:00Z","who":"idc-build"}
{"item":43,"op":"move","to":{"stage":{"nested":1},"status":"Todo"},"what":"move #43","when":"2026-08-06T10:06:00Z","who":"idc-build"}
JSON
ROUT="$(python3 "$SCRIPT" --repo "$RR" ingest 2>&1)" \
  || fail "(R1) ingest CRASHED on a parseable record with a non-scalar state: $ROUT"
printf '%s\n' "$ROUT" | grep -q "skipped: 2" \
  || fail "(R1) the two non-scalar records must be counted as skipped: $ROUT"
RGOOD="$(python3 - "$RR" "select count(*) from events where item=41" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print(con.execute(sys.argv[2]).fetchone()[0])
PY
)"
[ "$RGOOD" = "1" ] || fail "(R2) the good record next to the damaged ones was lost: $RGOOD"
echo "  ok (R) a non-scalar stage/status is skipped and counted, and its neighbours still land"

# ---- S. phases follow CANONICAL journal order, not the wall clock ---------------------------------
# The journal is an append log: its own order IS the sequence of state changes. Ordering spans by
# `ts` lets a clock that steps backwards between two ops (or an out-of-order legacy timestamp)
# reverse them — leaving an EARLIER status standing as the item's open phase, which is the one thing
# an operator reads a timeline to learn. Timestamps are for durations only.
# Red-when-broken: restore `ORDER BY ts, id` in _rebuild_phases → (S1) FAILs.
SR="$WORK/clockskew"
mkdir -p "$SR/docs/workflow"
cat > "$SR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$SR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":51,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'skewed'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
{"item":51,"op":"move","to":{"status":"In Progress"},"what":"move #51 Todo -> In Progress","when":"2026-08-06T09:55:00Z","who":"idc-build"}
{"item":51,"op":"move","to":{"status":"In Review"},"what":"move #51 In Progress -> In Review","when":"2026-08-06T10:25:00Z","who":"idc-build"}
JSON
python3 "$SCRIPT" --repo "$SR" ingest >/dev/null 2>&1 || fail "(S) ingest failed on the skewed journal"
SQ() { python3 - "$SR" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
for r in con.execute(sys.argv[2]).fetchall():
    print("|".join("" if c is None else str(c) for c in r))
PY
}
SORDER="$(SQ "select phase from phases where item=51 order by id" | tr '\n' '>')"
[ "$SORDER" = "Todo>In Progress>In Review>" ] \
  || fail "(S1) phases must follow the journal's own order, got: $SORDER (expected Todo>In Progress>In Review>)"
# The open phase is the LAST one the record establishes — the skewed clock must not hand that role
# to an earlier status.
SOPEN="$(SQ "select phase from phases where item=51 and exited_ts is null")"
[ "$SOPEN" = "In Review" ] || fail "(S2) the open phase should be the journal's last status, got: $SOPEN"
# A span whose recorded exit precedes its entry has NO duration — never a negative one presented as
# a measurement. (Todo: entered 10:00, left at the backwards-stamped 09:55.)
SDUR="$(SQ "select duration_s from phases where item=51 and phase='Todo'")"
[ -z "$SDUR" ] || fail "(S3) a backwards-stamped span must yield NO duration, got: $SDUR"
echo "  ok (S) phase spans follow canonical journal order; a backwards clock yields no duration"

# ---- T. the ignore door is wired for UPGRADED repos too, not just fresh ones ----------------------
# The scaffold (arm K) covers `/idc:init`. An existing governed repo upgrades through `/idc:update`,
# whose §C additive-sidecar migration is a SEPARATE list — so a door added only to the scaffold
# leaves every already-governed repo to strand an untracked db + two WAL sidecars on first ingest.
# Asserted as PARITY rather than as one grep, because this is a class of miss, not one instance:
# every ensure-gitignore door the scaffold wires must also appear in update.md's migration.
# Red-when-broken: delete the mirror's line from commands/update.md → (T) FAILs and names it.
SCAFFOLD_DOORS="$(grep 'ensure-gitignore' "$PLUGIN/scripts/idc_init_scaffold.sh" \
                  | grep '^python3' | grep -oE '[A-Za-z0-9_]+\.(py|sh)' | sort -u)"
[ -n "$SCAFFOLD_DOORS" ] || fail "(T) could not extract the scaffold's ensure-gitignore doors — the guard would pass vacuously"
MISSING=""
for door in $SCAFFOLD_DOORS; do
  grep -q "$door.*ensure-gitignore" "$PLUGIN/commands/update.md" || MISSING="${MISSING} ${door}"
done
[ -z "${MISSING}" ] || fail "(T) ensure-gitignore door(s) wired into /idc:init's scaffold but MISSING from
/idc:update's section C migration:${MISSING} — so an already-governed repo never gets the ignore rule
and strands untracked machine-local state on its first run"
echo "  ok (T) every scaffold ensure-gitignore door is also in /idc:update's migration ($(printf '%s' "$SCAFFOLD_DOORS" | wc -w | tr -d ' ') doors)"

# ---- U. the mirror db is owner-only, like the sidecars whose payloads it holds --------------------
# The rows carry the verbatim content of receipts their own writers create 0600 (mkstemp). A db left
# at the ambient umask (0644) re-publishes those same bytes to every account on the machine — a
# derived view must never be a wider door onto its source than the source is.
# Red-when-broken: drop `_create_private` from connect() → the db is 0644 under umask 022 and (U) FAILs.
UR="$WORK/perms"
mkdir -p "$UR/docs/workflow"
cat > "$UR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
printf '{"version":2,"verdict":"complete","exit":0,"session_id":"S-perm","ts":1785974400.0}\n' \
  > "$UR/.idc-drain-verdict.json"
( umask 022; python3 "$SCRIPT" --repo "$UR" ingest >/dev/null 2>&1 ) || fail "(U) ingest failed"
UMODE="$(python3 - "$UR/.idc-trace-mirror.db" <<'PY'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[-3:])
PY
)"
[ "$UMODE" = "600" ] \
  || fail "(U) the mirror db is $UMODE under umask 022 — it mirrors 0600 receipt payloads and must not widen access to them"
# The WAL/SHM sidecars inherit the db's mode, so a live watch never leaks through them either.
python3 - "$UR" "$SCRIPT" <<'PY' || fail "(U) the WAL sidecar is not owner-only while the mirror is open"
import os, stat, subprocess, sys
repo, script = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(script))
sys.path.insert(0, os.path.join(os.path.dirname(script), "hooks"))
os.umask(0o022)
import idc_trace_mirror as TM
con = TM.connect(TM.db_path(repo))
TM.ingest(repo, con)          # a live WAL exists while the connection is open
wal = TM.db_path(repo) + "-wal"
assert os.path.exists(wal), "test setup: no WAL sidecar to inspect"
mode = oct(stat.S_IMODE(os.stat(wal).st_mode))[-3:]
con.close()
assert mode == "600", "the WAL sidecar is %s, not owner-only — it holds the same mirrored payloads" % mode
PY
echo "  ok (U) the mirror db and its WAL sidecar are owner-only (0600)"

# ---- V. a mirror written by another schema version is DROPPED and re-derived ----------------------
# The disposability doctrine's practical payoff: a derived cache never needs a migration path, and
# writing one would be the first step toward treating its contents as something that must survive.
# Red-when-broken: remove the user_version check from connect() → the stale-shaped table survives and
# ingest fails (or serves rows from a schema the queries no longer match).
VR="$WORK/staleschema"
mkdir -p "$VR/docs/workflow"
cat > "$VR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$VR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":61,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'after the schema change'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
JSON
python3 - "$VR" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")   # a db from an OLDER mirror version
con.executescript("CREATE TABLE events (id INTEGER PRIMARY KEY, event_key TEXT UNIQUE);"
                  "INSERT INTO events (event_key) VALUES ('stale-shaped-row');")
con.commit(); con.close()
PY
python3 "$SCRIPT" --repo "$VR" ingest >/dev/null 2>&1 \
  || fail "(V) ingest failed against a db written by an older schema version instead of re-deriving it"
VSTALE="$(python3 - "$VR" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print(con.execute("select count(*) from events where event_key = 'stale-shaped-row'").fetchone()[0])
PY
)"
[ "$VSTALE" = "0" ] || fail "(V) the stale-schema rows survived the version bump: $VSTALE"
VNEW="$(python3 - "$VR" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print(con.execute("select count(*) from events where item = 61").fetchone()[0])
PY
)"
[ "$VNEW" = "1" ] || fail "(V) the re-derived mirror is missing the raw record: $VNEW"
echo "  ok (V) a mirror at another schema version is dropped and re-derived from the raw record"

# =================================================================================================
# Codex review round 2 (PR #198): one P1 + seven P2s, each pinned below by the property it broke.
# Every one of them pokes a hole in a promise the doctrine above makes — never committed, never
# lying about the record, never crashing on damage, never breaking the run it watches.
# =================================================================================================

# ---- W. [P1] the mirror db is a PROTECTED MACHINE PATH, not an ordinary file ----------------------
# The db is gitignored (arm K) — but an ignore rule is ADVISORY. `git add -f`, or a db already
# tracked from before the rule existed, walks straight past it, and the repo-wide claim window would
# then treat it as an ordinary allowed path and COMMIT it: a file whose rows hold the verbatim
# payloads of receipt sidecars their own writers create 0600 (arm U). "Never committed" has to be
# enforced by the gate that enforces it for every other .idc-* machine file, not by gitignore alone.
# Red-when-broken: drop `.idc-trace-mirror.db*` from PROTECTED_MACHINE_RULES → (W1) FAILs.
python3 - "$PLUGIN" <<'PY' || fail "(W) the trace-mirror db is not a protected machine-owned path"
import os, sys, tempfile
plugin = sys.argv[1]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_path_gate as G

repo = os.path.join(tempfile.mkdtemp(), "r")
os.makedirs(os.path.join(repo, "docs/workflow"))
open(os.path.join(repo, "docs/workflow/tracker-config.yaml"), "w").write("backend: filesystem\n")

def verdict(path, action="git"):
    d = G._evaluate_request(repo, plugin, {"action": action, "paths": [path]})
    return bool(d.get("allowed")), str(d.get("reason") or "")

# (W1) the db AND its WAL/SHM sidecars are hard-denied, for the machine-owned reason — on every
# mutating action, since a `write`/`edit` of the db is as much a forgery as a commit of it.
for path in (".idc-trace-mirror.db", ".idc-trace-mirror.db-wal", ".idc-trace-mirror.db-shm"):
    for action in ("git", "write", "edit"):
        allowed, reason = verdict(path, action)
        assert not allowed, (
            "(W1) `%s` is ALLOWED for action `%s` — the derived mirror holds verbatim 0600 receipt "
            "payloads and must never be committable/hand-editable: %s" % (path, action, reason))
        assert "protected machine-owned surface" in reason, (
            "(W1) `%s` was denied, but not as a protected machine-owned path (%s) — a deny for an "
            "incidental reason would evaporate the moment that reason did" % (path, reason))

# (W2) the guard is not vacuous: an established peer denies the same way, and an ORDINARY repo file
# still gets past this check (the deny is specific to machine-owned state, not a blanket refusal).
allowed, reason = verdict(".idc-drain-verdict.json")
assert not allowed and "protected machine-owned surface" in reason, \
    "(W2) test setup: the peer machine file is not denied as protected — the assertion above proves nothing"
allowed, _ = verdict("README.md")
assert allowed, "(W2) an ordinary repo file must not be caught by the protected-machine rule"
PY
echo "  ok (W) the mirror db + its WAL/SHM sidecars are protected machine paths (git/write/edit denied)"

# ---- X. [P2] two BYTE-IDENTICAL journal lines are two records, not one ----------------------------
# The engine deliberately journals a RECLAIM of an already-In-Progress item (idc_transition), and
# `when` has one-second granularity with no nonce — so a session that reclaims twice inside one
# second writes two byte-identical NDJSON lines, both of them REAL claims. Keyed by content alone the
# second collided with the first and INSERT OR IGNORE dropped it: the mirror showing one claim where
# the record holds two, which is the mirror disagreeing with the raw record it exists to reflect.
#
# The fix cannot be per-segment position, because a rotation MOVES lines between segments — so this
# arm pins the whole property triangle at once: distinct rows, NO re-ingest across a rotation, and
# convergence with a rebuild. Red-when-broken: key journal rows by content alone → (X1) FAILs;
# key them by (artifact, seq) → (X3) FAILs with 4 rows where the record has 2.
XR="$WORK/identical"
mkdir -p "$XR/docs/workflow/journal-archive"
cat > "$XR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
# Exactly what idc_transition's reclaim path writes, twice inside one timestamp second.
CLAIM='{"backend":"filesystem","guard_evidence_hash":null,"item":71,"op":"claim","repo-relative tracker":"docs/workflow/TRACKER.md","to":{"status":"In Progress"},"what":"claim #71 In Progress -> In Progress","when":"2026-08-06T10:05:00Z","who":"idc-build"}'
{ printf '%s\n' "$CLAIM"; printf '%s\n' "$CLAIM"; } > "$XR/docs/workflow/transition-journal.ndjson"
python3 "$SCRIPT" --repo "$XR" ingest >/dev/null 2>&1 || fail "(X) ingest failed on identical lines"
XQ() { python3 - "$XR" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
for r in con.execute(sys.argv[2]).fetchall():
    print("|".join("" if c is None else str(c) for c in r))
PY
}
X1="$(XQ "select count(*) from events where source='journal'")"
[ "$X1" = "2" ] \
  || fail "(X1) two byte-identical journal lines are two REAL records (a double reclaim), but the
mirror stored $X1 — the second claim was silently dropped by a content-only event key"

# (X2) still IDEMPOTENT: re-ingesting the unchanged journal must not grow it to 4.
python3 "$SCRIPT" --repo "$XR" ingest >/dev/null 2>&1 || fail "(X) re-ingest failed"
X2="$(XQ "select count(*) from events where source='journal'")"
[ "$X2" = "2" ] || fail "(X2) re-ingesting unchanged identical lines duplicated them: $X2 (expected 2)"

# (X3) THE ROTATION TRAP the occurrence identity has to survive: the janitor moves #71's records into
# an archive segment. Their content is unchanged, so they must NOT re-ingest under the new path.
#
# The ROW COUNT alone cannot see this, and that matters: a positional identity DOES re-ingest, but
# `_prune_vanished` then deletes the pre-rotation rows in the same pass, leaving the count at 2 and
# the bug invisible. The visible damage is to the CURSOR — the same two records are deleted and
# re-inserted at fresh ids, which every live watcher reads as two brand-new claims that never
# happened. So the assertion is that a rotation leaves the already-mirrored rows' IDS UNTOUCHED.
XIDS_BEFORE="$(XQ "select id from events where source='journal' order by id" | tr '\n' ',')"
python3 - "$XR" "$PLUGIN" <<'PY' >/dev/null 2>&1 || fail "(X) the janitor rotation fixture failed"
import os, sys
repo, plugin = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts")); sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_git_janitor as J
J.rotate_journal({"repo": repo, "board": [{"number": 71, "status": "Done"}]},
                 os.path.join(repo, "docs/workflow/transition-journal.ndjson"))
PY
python3 "$SCRIPT" --repo "$XR" ingest >/dev/null 2>&1 || fail "(X) ingest after the rotation failed"
X3="$(XQ "select count(*) from events where source='journal'")"
[ "$X3" = "2" ] \
  || fail "(X3) a rotation re-ingested the identical lines under their new path: $X3 rows for 2
records — the occurrence identity is positional and moved with them instead of staying stable"
XIDS_AFTER="$(XQ "select id from events where source='journal' order by id" | tr '\n' ',')"
[ "$XIDS_BEFORE" = "$XIDS_AFTER" ] \
  || fail "(X3) a rotation RE-DELIVERED the identical lines at fresh cursor ids ($XIDS_BEFORE ->
$XIDS_AFTER) — the occurrence identity moved with the record instead of staying stable, so every
live watcher sees two brand-new claims that never happened"
# ...and their provenance still followed the record into the archive (arm O's property, here on the
# pair that shares a content hash).
X3A="$(XQ "select count(*) from events where source='journal' and artifact like 'docs/workflow/journal-archive/%'")"
[ "$X3A" = "2" ] || fail "(X3) the rotated identical lines' artifact did not follow them: $X3A of 2"

# (X4) a THIRD identical claim, appended live, is a THIRD record — delivered ABOVE the old cursor so
# a watcher sees it, rather than vanishing into the two keys that already exist.
XCUR="$(XQ "select max(id) from events")"
printf '%s\n' "$CLAIM" >> "$XR/docs/workflow/transition-journal.ndjson"
python3 "$SCRIPT" --repo "$XR" ingest >/dev/null 2>&1 || fail "(X) ingest of the third claim failed"
X4="$(XQ "select count(*) from events where source='journal'")"
[ "$X4" = "3" ] || fail "(X4) a third identical claim did not land as its own record: $X4 (expected 3)"
X4ID="$(XQ "select max(id) from events")"
[ "$X4ID" -gt "$XCUR" ] \
  || fail "(X4) the third claim did not land above the live cursor ($XCUR -> $X4ID) — a watcher would never see it"

# (X5) CONVERGENCE still holds over identical lines: incremental == rebuild (arm M's invariant, on
# the one input where a naive occurrence identity would renumber between the two).
XCOLS="run_id,source,artifact,seq,ts,op,item,stage,status,who,summary,event_key,payload"
XINCR="$(XQ "select $XCOLS from events order by event_key")"
rm -f "$XR"/.idc-trace-mirror.db*
python3 "$SCRIPT" --repo "$XR" ingest >/dev/null 2>&1 || fail "(X) the rebuild-from-scratch ingest failed"
XREBUILT="$(XQ "select $XCOLS from events order by event_key")"
[ "$XINCR" = "$XREBUILT" ] || fail "(X5) with identical lines present, an incrementally-grown mirror
DIVERGED from a rebuild.
  incremental: $XINCR
  rebuilt:     $XREBUILT"
echo "  ok (X) byte-identical journal lines are distinct records, survive a rotation without re-ingest, and converge"

# ---- Y. [P2] a DAMAGED mirror db is discarded and re-derived, not fatal ---------------------------
# SQLite raises at the first PRAGMA on a corrupt/foreign file — which is BEFORE any subcommand
# dispatches, so a truncated db (killed process, full disk) killed every door with the same
# traceback, INCLUDING `rebuild`, the advertised recovery. The operator's only way out was knowing to
# `rm` a file the tool never named. Damage to a derived, disposable cache has exactly one right
# answer and the mirror can always take it itself.
# Red-when-broken: remove the DatabaseError recovery from connect() → (Y1) FAILs with rc!=0.
YR="$WORK/corruptdb"
mkdir -p "$YR/docs/workflow"
cat > "$YR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$YR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":72,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'survives corruption'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
JSON
# Not a SQLite file at all — the shape a killed writer or a full disk leaves behind.
printf 'PLAIN TEXT, DEFINITELY NOT A DATABASE\n' > "$YR/.idc-trace-mirror.db"
YOUT="$(python3 "$SCRIPT" --repo "$YR" rebuild 2>&1)" \
  || fail "(Y1) \`rebuild\` — the advertised recovery — could not run against a damaged mirror: $YOUT"
printf '%s\n' "$YOUT" | grep -qi "unreadable" \
  || fail "(Y1) the mirror was silently re-derived; the operator must be TOLD their trace restarted: $YOUT"
YN="$(python3 - "$YR" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print(con.execute("select count(*) from events where item = 72").fetchone()[0])
PY
)"
[ "$YN" = "1" ] || fail "(Y1) the re-derived mirror is missing the raw record: $YN"
# ...and the ordinary doors recover too, not just `rebuild`.
printf 'CORRUPT AGAIN\n' > "$YR/.idc-trace-mirror.db"
python3 "$SCRIPT" --repo "$YR" ingest >/dev/null 2>&1 || fail "(Y2) ingest could not recover a damaged mirror"
printf 'CORRUPT ONCE MORE\n' > "$YR/.idc-trace-mirror.db"
python3 "$SCRIPT" --repo "$YR" tail --since 0 >/dev/null 2>&1 || fail "(Y2) tail could not recover a damaged mirror"
# The re-derived db is still owner-only — recovery must not quietly widen access (arm U's property).
printf 'CORRUPT YET AGAIN\n' > "$YR/.idc-trace-mirror.db"
( umask 022; python3 "$SCRIPT" --repo "$YR" ingest >/dev/null 2>&1 ) || fail "(Y3) the umask-022 recovery ingest failed"
YMODE="$(python3 - "$YR/.idc-trace-mirror.db" <<'PY'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[-3:])
PY
)"
[ "$YMODE" = "600" ] || fail "(Y3) the mirror re-derived after corruption is $YMODE, not owner-only"
echo "  ok (Y) a corrupt mirror db is discarded, re-derived and reported — by every door, still 0600"

# ---- Z. [P2] one undecodable LINE costs that line, not its whole segment --------------------------
# `readlines()` decodes the entire file, so a single invalid UTF-8 byte raised — the handler counted
# ONE skip and every valid record in that segment was silently omitted. A trace that drops a whole
# segment while reporting "skipped: 1" is worse than a crash: it reads as an almost-complete view.
# Red-when-broken: restore the whole-file text read → (Z1) FAILs with 0 mirrored records.
ZR="$WORK/badutf8"
mkdir -p "$ZR/docs/workflow"
cat > "$ZR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
python3 - "$ZR" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], "docs/workflow/transition-journal.ndjson")
before = b'{"item":81,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket good-before","when":"2026-08-06T10:00:00Z","who":"idc-think"}\n'
bad    = b'{"item":82,"op":"move","to":{"status":"In Progress"},"what":"move \xff\xfe damaged","when":"2026-08-06T10:05:00Z","who":"idc-build"}\n'
after  = b'{"item":83,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket good-after","when":"2026-08-06T10:10:00Z","who":"idc-think"}\n'
open(p, "wb").write(before + bad + after)
PY
ZOUT="$(python3 "$SCRIPT" --repo "$ZR" ingest 2>&1)" || fail "(Z) ingest crashed on an undecodable line: $ZOUT"
ZQ() { python3 - "$ZR" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print(con.execute(sys.argv[2]).fetchone()[0])
PY
}
Z1="$(ZQ "select count(*) from events where item in (81,83)")"
[ "$Z1" = "2" ] \
  || fail "(Z1) an undecodable line took its segment's VALID records with it: $Z1 of 2 mirrored"
printf '%s\n' "$ZOUT" | grep -q "skipped: 1" \
  || fail "(Z1) exactly the damaged line must be counted as skipped: $ZOUT"
# The damaged record is genuinely absent — skipped means skipped, not half-stored.
Z2="$(ZQ "select count(*) from events where item = 82")"
[ "$Z2" = "0" ] || fail "(Z2) the undecodable line was stored anyway: $Z2"
echo "  ok (Z) one undecodable line is skipped and counted; its neighbours in the segment still land"

# ---- AA. [P2] an item number outside SQLite's integer range is skipped, not fatal -----------------
# SQLite stores signed 64-bit integers. `json.loads` hands back a 26-digit int quite happily, and
# binding it raised OverflowError from inside the INSERT — so a single damaged record terminated
# `watch` and rolled back every good event sharing that poll's transaction.
# Red-when-broken: drop the _INT64 range check → (AA1) FAILs with a non-zero exit.
AR="$WORK/bigitem"
mkdir -p "$AR/docs/workflow"
cat > "$AR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$AR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":91,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'good neighbour'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
{"item":99999999999999999999999999,"op":"move","to":{"status":"In Progress"},"what":"move #huge","when":"2026-08-06T10:05:00Z","who":"idc-build"}
{"item":-99999999999999999999999999,"op":"move","to":{"status":"In Progress"},"what":"move #hugeneg","when":"2026-08-06T10:06:00Z","who":"idc-build"}
JSON
AOUT="$(python3 "$SCRIPT" --repo "$AR" ingest 2>&1)" \
  || fail "(AA1) ingest CRASHED on a journal item beyond signed 64-bit: $AOUT"
printf '%s\n' "$AOUT" | grep -q "skipped: 2" \
  || fail "(AA1) the out-of-range items must be counted as skipped: $AOUT"
AGOOD="$(python3 - "$AR" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
print(con.execute("select count(*) from events where item = 91").fetchone()[0])
PY
)"
[ "$AGOOD" = "1" ] || fail "(AA2) the good record sharing the poll's transaction was rolled back: $AGOOD"
echo "  ok (AA) an item number outside SQLite's range is skipped and counted, and its neighbours land"

# ---- AB. [P2] an out-of-range receipt timestamp is tolerated, not fatal ---------------------------
# `1e999` is VALID JSON and parses to inf; `time.gmtime(inf)` raises OverflowError — neither of the
# two exceptions `_iso` caught. One damaged receipt sidecar therefore crashed ingest and every watch
# poll, in a module whose entire contract is that it never breaks the run it observes.
# Red-when-broken: narrow the catch back to (TypeError, ValueError) → (AB1) FAILs with a traceback.
BR="$WORK/bigts"
mkdir -p "$BR/docs/workflow"
cat > "$BR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
printf '{"version":2,"verdict":"complete","exit":0,"session_id":"S-inf","ts":1e999}\n' \
  > "$BR/.idc-drain-verdict.json"
printf '{"version":2,"kind":"doctor","session_id":"S-ok","producer":"doctor-command","ts":1785974460.0}\n' \
  > "$BR/.idc-doctor-report.json"
BOUT="$(python3 "$SCRIPT" --repo "$BR" ingest 2>&1)" \
  || fail "(AB1) ingest CRASHED on a receipt whose ts is out of the platform's range: $BOUT"
BQ() { python3 - "$BR" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/.idc-trace-mirror.db")
for r in con.execute(sys.argv[2]).fetchall():
    print("|".join("" if c is None else str(c) for c in r))
PY
}
# The receipt still mirrors — only its unusable timestamp is dropped (NULL), never invented, and its
# verbatim payload keeps whatever was actually written.
BTS="$(BQ "select count(*) from events where op='drain-verdict' and ts is null")"
[ "$BTS" = "1" ] || fail "(AB2) the out-of-range ts should mirror as NULL on an otherwise-intact receipt: $BTS"
BQ "select payload from events where op='drain-verdict'" | grep -q '1e999' \
  || fail "(AB2) the receipt's verbatim payload was not preserved: $(BQ "select payload from events where op='drain-verdict'")"
BOK="$(BQ "select count(*) from events where op='doctor-report'")"
[ "$BOK" = "1" ] || fail "(AB3) the healthy receipt beside the damaged one was lost: $BOK"
echo "  ok (AB) an out-of-range receipt ts mirrors as NULL instead of crashing ingest"

# ---- AC. [P2] the journal's lock is released BEFORE the parse ------------------------------------
# THE OBSERVER MUST NOT DELAY THE RUN IT WATCHES. Every watch poll re-read AND re-parsed all segments
# while holding the journal's SHARED sidecar lock — and `journal_append` / the janitor's rotation need
# the EXCLUSIVE one, so the run's own writers queued behind the observer's full historical scan, for
# a time that grows with total history (measured: 11ms/41ms/125ms of lock at 5k/20k/60k lines, ~99%
# of it parsing). Only the raw byte read has to be inside the lock; everything else is bookkeeping.
#
# Asserted DETERMINISTICALLY (no timing threshold, which would flake on a loaded runner): the two
# dominant costs — JSON decoding and per-line hashing — must not be called at all while the locked
# reader is running. Red-when-broken: parse inside the locked reader again → (AC1) FAILs.
CR="$WORK/lockhold"
mkdir -p "$CR/docs/workflow/journal-archive"
cat > "$CR/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
tracker: docs/workflow/TRACKER.md
YAML
cat > "$CR/docs/workflow/journal-archive/2026-07-01.ndjson" <<'JSON'
{"item":101,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'archived'","when":"2026-07-01T09:00:00Z","who":"idc-think"}
JSON
cat > "$CR/docs/workflow/transition-journal.ndjson" <<'JSON'
{"item":102,"op":"create-ticket","to":{"stage":"Consideration","status":"Todo"},"what":"create-ticket 'live'","when":"2026-08-06T10:00:00Z","who":"idc-think"}
{"item":102,"op":"move","to":{"status":"In Progress"},"what":"move #102 Todo -> In Progress","when":"2026-08-06T10:05:00Z","who":"idc-build"}
JSON
: > "$CR/docs/workflow/transition-journal.ndjson.lock"
python3 - "$CR" "$PLUGIN" <<'PY' || fail "(AC) the mirror parses the journal while holding its lock"
import json, os, sqlite3, sys
repo, plugin = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_trace_mirror as TM

state = {"locked": False, "parsed": [], "read_bytes": False}

real_locked = TM.RP.read_journal_locked
def watched_locked(path, reader):
    state["locked"] = True
    try:
        return real_locked(path, reader)
    finally:
        state["locked"] = False
TM.RP.read_journal_locked = watched_locked

real_loads = TM.json.loads
def watched_loads(*a, **k):
    if state["locked"]:
        state["parsed"].append("json.loads")
    return real_loads(*a, **k)
TM.json.loads = watched_loads

real_sha = TM._sha
def watched_sha(text):
    if state["locked"]:
        state["parsed"].append("_sha")
    return real_sha(text)
TM._sha = watched_sha

real_snapshot = TM._snapshot_segments
def watched_snapshot(r, p):
    out = real_snapshot(r, p)
    state["read_bytes"] = bool(out[0][0])
    return out
TM._snapshot_segments = watched_snapshot

con = TM.connect(TM.db_path(repo))
TM.ingest(repo, con)
con.close()

# (AC1) nothing but the raw read happened under the lock.
assert not state["parsed"], (
    "(AC1) the locked reader still does %d parse/hash call(s) (%s) — the watched run's own "
    "journal_append/rotation wait behind ALL of it, on every poll, forever"
    % (len(state["parsed"]), sorted(set(state["parsed"]))))
# (AC2) the guard is not vacuous: the lock WAS taken, bytes WERE read inside it, and the parse
# really did happen (just afterwards) — so a mirror that simply stopped reading cannot pass this.
assert state["read_bytes"], "(AC2) test setup: no segment bytes were read inside the lock"
con = sqlite3.connect(os.path.join(repo, ".idc-trace-mirror.db"))
items = sorted(r[0] for r in con.execute("select distinct item from events where item is not null"))
assert items == [101, 102], "(AC2) the ingest did not mirror both segments' records: %s" % items
PY
echo "  ok (AC) only the raw byte read happens under the journal's lock; the parse runs after release"

echo "PASS: phase12-trace-mirror"
