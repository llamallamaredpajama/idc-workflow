#!/usr/bin/env python3
"""idc_command_report.py — the persisted per-command diagnostic report (Task 6 wave 3, finding 6).

WHAT THIS IS. A tiny, dependency-free sidecar to the obligations ledger, a sibling of
`idc_drain_verdict.py`. A DIAGNOSTIC command that produces no tracker mutation and no PR — `/idc:doctor`
and `/idc:janitor` — has no durable artifact its closeout can be re-derived from, so its terminal
evidence was self-reported (a caller `rows:[…]`/`scanner_exit:0` the validator merely shape-checked).
This helper is the artifact those runs now WRITE, so the command contract's `finish` re-reads the
run's OWN report instead of trusting the caller (finding 6):

  * `/idc:doctor`  — writes `{rows, verdict, nonce}` through `write_doctor_report`.
  * `/idc:janitor` — writes `{scanner_exit, clean, nonce}` through `write_janitor_report`.
  * `/idc:intake`  — its failing helper writes a nonce-bound failure receipt, cleared by a retry.

THE FILE. One JSON file per KIND at the governed workspace root, `.idc-<kind>-report.json`
(`report_path(cwd, kind)`). Transient working state, gitignored via the scaffold + /idc:update
(`ensure_gitignored()`), so a clean doctor/janitor exit never leaves committed litter. Shape:

    {"version": 2, "kind": "doctor", "session_id": "<sid>", "producer": "doctor-command", "ts": 1720137600.0,
     "payload": {"rows": ["1..10"], "verdict": "FAIL"}}

INVARIANT — ONLY THIS SESSION'S OWN REPORT BACKS ITS OWN CLOSEOUT (session scoping, mirrors the drain
verdict's invariant). `current_report(cwd, kind, session_id)` returns the payload ONLY when its
`session_id` EQUALS session_id AND the report is not clearly-stale (`ts` within `_STALE_AFTER_S`). A
foreign session's report, an absent file, or a blank session → None → the closeout fails closed (a
diagnostic that produced no report for THIS session cannot claim `complete`).

FAIL MODES (mirror the drain verdict / ledger). Reads are TOLERANT (missing/corrupt → None, never
throws). Writes are ATOMIC (temp-file + os.replace) and BEST-EFFORT (an OSError warns/degrades, never
raises — persisting a report must not break the diagnostic). Writes are REPO-GATED (a no-op outside a
governed repo, so a non-IDC dir is never littered).

USAGE (import — source-owned writers only):
    import idc_command_report
    idc_command_report.write_doctor_report(root, rows, sid, nonce)
    idc_command_report.write_janitor_report(root, scanner_exit, sid, nonce)
    idc_command_report.write_intake_failure(root, sid, nonce, helper, operation, exit, diagnostic)

USAGE (CLI — Doctor is the only report whose command markdown needs a writer):
    python3 idc_command_report.py --cwd <repo> write-doctor --session S --nonce N --rows-json '[...]'
    python3 idc_command_report.py --cwd <repo> read  --kind doctor --session S   # prints the JSON, or nothing
    python3 idc_command_report.py --cwd <repo> path  --kind doctor
    python3 idc_command_report.py --cwd <repo> ensure-gitignore
"""
import argparse
import json
import os
import re
import sys
import time

# Same-dir import: idc_command_report lives beside idc_hook_lib in scripts/hooks/.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib  # noqa: E402  (is_governed_repo — the ONE repo-gate, shared)

# The gitignore glob covers EVERY per-kind report file (the trailing `*` matches the empty string, so
# the file itself is ignored, plus any future sidecar), mirroring the drain verdict's ignore line.
GITIGNORE_GLOB = ".idc-*-report.json*"
_REPORT_VERSION = 2
# A report older than this is treated as clearly-abandoned (None → fail closed). A run→finish window is
# seconds; 24h is deliberately vast slack — its only job is to distrust a file from a since-gone
# session id, never to false-refuse a real run.
_STALE_AFTER_S = 24 * 60 * 60
# A kind is a short lowercase token — one report file per kind, no path traversal in the filename.
_KIND_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")


def _valid_kind(kind):
    return isinstance(kind, str) and bool(_KIND_RE.fullmatch(kind))


# ── the doctor report schema (round-5 finding 6) ──────────────────────────────────────────────────
# A doctor run's persisted report must record ALL ten checks with a consistent verdict, so a forged
# 2-row / arbitrary-JSON report cannot pass the closeout. The schema is enforced in ONE place, used
# BOTH here (the writer refuses to persist a non-conforming doctor payload — finding 6f) AND by the
# command contract's closeout (which re-reads + re-validates via this same function — finding 6e).
_DOCTOR_ROW_IDS = list(range(1, 11))                 # rows 1..10, each present exactly once
_DOCTOR_RESULTS = {"PASS", "FAIL", "SKIP"}
_DOCTOR_SCRIPT_ROWS = {10}                           # rows doctor drives via a deterministic script + exit
_DOCTOR_HELPER_RE = re.compile(r"^[A-Za-z0-9_.-]+\.(py|sh)$")


def doctor_verdict_aggregate(rows):
    """The verdict DERIVED from the row outcomes: FAIL if any row FAILed, else PASS. A SKIP row (a check
    that could not be established) never drives the verdict. A doctor run completing with a FAIL verdict
    is still a complete run — the verdict describes the REPO, not whether the run finished."""
    return "FAIL" if any(isinstance(r, dict) and r.get("result") == "FAIL" for r in rows) else "PASS"


def validate_doctor_payload(payload):
    """Validate a doctor report payload against the doctor row contract (round-5 finding 6). Returns
    (True, "") when it conforms, else (False, reason). Requirements: a non-empty `nonce`; `rows` a list
    carrying EXACTLY ids 1..10 (each once, unique) with each `result` in {PASS,FAIL,SKIP}; a
    script-backed row (id in _DOCTOR_SCRIPT_ROWS) additionally carrying a `script` naming a helper
    basename (.py/.sh) + an integer `exit`; and a `verdict` in {PASS,FAIL,SKIP} EQUAL to the derived
    aggregation of the row outcomes. A 2-row / arbitrary-JSON report fails."""
    if not isinstance(payload, dict):
        return False, "payload must be a JSON object"
    nonce = payload.get("nonce")
    if not (isinstance(nonce, str) and nonce.strip()):
        return False, "doctor payload requires a non-empty `nonce` bound to the command record"
    rows = payload.get("rows")
    if not isinstance(rows, list):
        return False, "doctor payload requires `rows` (a list)"
    ids = []
    for row in rows:
        if not isinstance(row, dict):
            return False, "each doctor row must be an object {id, result, ...} (a bare string is not a row)"
        rid = row.get("id")
        if isinstance(rid, bool) or not isinstance(rid, int):
            return False, "each doctor row requires an integer `id`"
        if row.get("result") not in _DOCTOR_RESULTS:
            return False, f"doctor row {rid}: `result` must be one of {sorted(_DOCTOR_RESULTS)}"
        if rid in _DOCTOR_SCRIPT_ROWS:
            script = row.get("script")
            if not (isinstance(script, str) and _DOCTOR_HELPER_RE.match(script)):
                return False, f"doctor row {rid} is script-backed and must name its `script` helper (.py/.sh)"
            if isinstance(row.get("exit"), bool) or not isinstance(row.get("exit"), int):
                return False, f"doctor row {rid} is script-backed and must record the integer `exit`"
        ids.append(rid)
    if sorted(ids) != _DOCTOR_ROW_IDS:
        return False, f"doctor rows must be EXACTLY ids {_DOCTOR_ROW_IDS} each once (got {sorted(ids)})"
    verdict = payload.get("verdict")
    if verdict not in _DOCTOR_RESULTS:
        return False, f"doctor `verdict` must be one of {sorted(_DOCTOR_RESULTS)}"
    expected = doctor_verdict_aggregate(rows)
    if verdict != expected:
        return False, f"doctor verdict {verdict!r} != the derived aggregation of the row outcomes ({expected!r})"
    return True, ""


# ── paths ──────────────────────────────────────────────────────────────────────────────────────────
def report_path(cwd, kind):
    """The `.idc-<kind>-report.json` path at the governed workspace root `cwd`."""
    if not _valid_kind(kind):
        raise ValueError(f"invalid report kind {kind!r} (expected a short lowercase token)")
    return os.path.join(cwd or ".", f".idc-{kind}-report.json")


# ── tolerant read ────────────────────────────────────────────────────────────────────────────────
def read_report(cwd, kind):
    """The persisted report dict, or None. TOLERANT: a missing or corrupt file reads as None and
    NEVER throws. Returns None unless the payload is a dict carrying the matching `kind` and a
    `payload` object."""
    if not _valid_kind(kind):
        return None
    try:
        with open(report_path(cwd, kind), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("kind") != kind or not isinstance(data.get("payload"), dict):
        return None
    return data


def current_report(cwd, kind, session_id):
    """The persisted report payload for THIS session, or None (session scoping — the invariant).

    Returns the `payload` dict ONLY when session_id is truthy AND the persisted `session_id` EQUALS it
    AND the report is not clearly-stale. A foreign-session report, an absent file, a mismatched kind,
    or a blank session_id → None, and the closeout then fails closed."""
    r = current_report_record(cwd, kind, session_id)
    return r.get("payload") if isinstance(r, dict) else None


def current_report_record(cwd, kind, session_id):
    """The complete fresh, session-scoped report envelope, or None."""
    if not session_id:
        return None
    r = read_report(cwd, kind)
    if r is None or r.get("version") != _REPORT_VERSION or r.get("session_id") != session_id:
        return None
    ts = r.get("ts")
    if isinstance(ts, (int, float)) and (time.time() - ts) > _STALE_AFTER_S:
        return None
    return r


# ── atomic, best-effort write ────────────────────────────────────────────────────────────────────
def _atomic_write(path, payload):
    """Write the report atomically via the shared sidecar writer. BEST-EFFORT: a failure warns and
    returns False (never raises) so persisting a report can never break the diagnostic run. Returns
    True only after the replacement has landed."""
    return idc_hook_lib.atomic_write_json(path, payload, prefix=".idc-command-report.",
                                          label="command-report")


def _write_report(cwd, kind, payload, session_id, producer, ts=None):
    """Private envelope writer used only by the typed source-owned interfaces below."""
    if not _valid_kind(kind):
        idc_hook_lib.warn(f"command-report: refusing an invalid report kind {kind!r}")
        return False
    if not isinstance(payload, dict):
        idc_hook_lib.warn("command-report: refusing a non-object payload")
        return False
    if kind == "doctor":
        ok, reason = validate_doctor_payload(payload)
        if not ok:
            idc_hook_lib.warn(f"command-report: refusing a doctor payload that fails the doctor schema: {reason}")
            return False
    if not idc_hook_lib.is_governed_repo(cwd):
        return False
    ensure_gitignored(cwd)
    body = {
        "version": _REPORT_VERSION,
        "kind": kind,
        "session_id": session_id or None,
        "producer": producer,
        "ts": float(ts) if ts is not None else time.time(),
        "payload": payload,
    }
    return _atomic_write(report_path(cwd, kind), body)


def write_doctor_report(cwd, rows, session_id, nonce, ts=None):
    """Persist Doctor's fully-derived ten-row report."""
    payload = {"rows": rows, "verdict": doctor_verdict_aggregate(rows), "nonce": nonce}
    return _write_report(cwd, "doctor", payload, session_id, "doctor-command", ts)


def write_janitor_report(cwd, scanner_exit, session_id, nonce, ts=None):
    """Persist Janitor's own scanner result; callers cannot supply its payload or provenance."""
    if isinstance(scanner_exit, bool) or not isinstance(scanner_exit, int):
        return False
    payload = {"scanner_exit": scanner_exit, "clean": scanner_exit == 0, "nonce": nonce}
    return _write_report(cwd, "janitor", payload, session_id, "idc_git_janitor.py", ts)


def write_intake_failure(cwd, session_id, nonce, helper, operation, exit_code, diagnostic, ts=None):
    """Persist the exact failure produced by an Intake helper invocation."""
    if (not session_id or not nonce or not helper or not operation or
            isinstance(exit_code, bool) or not isinstance(exit_code, int) or exit_code == 0 or
            not isinstance(diagnostic, str) or not diagnostic.strip()):
        return False
    stamp = float(ts) if ts is not None else time.time()
    payload = {"session_id": session_id, "nonce": nonce, "helper": os.path.basename(helper),
               "operation": operation, "exit": exit_code, "diagnostic": diagnostic, "ts": stamp}
    return _write_report(cwd, "intake-failure", payload, session_id, os.path.basename(helper), stamp)


def clear_intake_failure(cwd, session_id, nonce):
    """Clear only THIS invocation's failure receipt after its helper succeeds on retry."""
    record = read_report(cwd, "intake-failure")
    payload = record.get("payload") if isinstance(record, dict) else None
    if (not isinstance(payload, dict) or record.get("version") != _REPORT_VERSION or
            record.get("session_id") != session_id or payload.get("nonce") != nonce):
        return False
    try:
        os.unlink(report_path(cwd, "intake-failure"))
        return True
    except OSError:
        return False


# ── the gitignore scaffold hook (idempotent, non-destructive) ────────────────────────────────────
def ensure_gitignored(repo_root):
    """Ensure the repo-root `.gitignore` contains `.idc-*-report.json*`, idempotently and
    NON-DESTRUCTIVELY (create if absent; else APPEND only if missing). REPO-GATED. Returns True iff
    the line is present afterward. Mirrors idc_drain_verdict.ensure_gitignored exactly."""
    return idc_hook_lib.ensure_gitignored(
        repo_root, GITIGNORE_GLOB, label="command-report",
        created_comment="# IDC command reports — transient per-session diagnostics, never committed.",
        appended_comment="# IDC command reports (per-session diagnostics; do not commit)")


# ── CLI (command markdown tail + governance test driver; NOT an LLM-facing judgement surface) ─────
def main(argv=None):
    ap = argparse.ArgumentParser(description="IDC persisted per-command diagnostic report (scripts/hooks only)")
    ap.add_argument("--cwd", default=".", help="governed workspace root (default: cwd)")
    sub = ap.add_subparsers(dest="op", required=True)

    pp = sub.add_parser("path", help="print the report file path for a kind")
    pp.add_argument("--kind", required=True)
    sub.add_parser("ensure-gitignore", help="idempotently add the report glob to the repo-root .gitignore")

    wp = sub.add_parser("write-doctor", help="persist Doctor's source-owned ten-row report")
    wp.add_argument("--session", default=None)
    wp.add_argument("--nonce", required=True)
    wp.add_argument("--rows-json", required=True, help="Doctor's ten row objects")
    wp.add_argument("--ts", type=float, default=None, help="POSIX timestamp override (staleness tests)")

    # Backward-compatible spelling for already-generated Doctor command tails.  It is deliberately
    # constrained to Doctor; the former arbitrary --kind door no longer exists for Janitor/Intake.
    legacy = sub.add_parser("write", help="persist a Doctor report (legacy Doctor-only spelling)")
    legacy.add_argument("--kind", required=True, choices=["doctor"])
    legacy.add_argument("--session", default=None)
    legacy.add_argument("--payload-json", required=True)
    legacy.add_argument("--ts", type=float, default=None)

    rp = sub.add_parser("read", help="print the persisted report JSON (session-scoped with --session)")
    rp.add_argument("--kind", required=True)
    rp.add_argument("--session", default=None,
                    help="scope to this session (prints only THIS session's fresh payload)")

    args = ap.parse_args(argv)
    cwd = args.cwd
    if args.op == "path":
        print(report_path(cwd, args.kind))
    elif args.op == "ensure-gitignore":
        ensure_gitignored(cwd)
    elif args.op == "write-doctor":
        try:
            rows = json.loads(args.rows_json)
        except ValueError as e:
            print(f"idc-command-report: malformed --rows-json: {e}", file=sys.stderr)
            return 2
        if not isinstance(rows, list):
            print("idc-command-report: --rows-json must be a JSON list", file=sys.stderr)
            return 2
        return 0 if write_doctor_report(cwd, rows, args.session, args.nonce, args.ts) else 1
    elif args.op == "write":
        try:
            payload = json.loads(args.payload_json)
        except ValueError as e:
            print(f"idc-command-report: malformed --payload-json: {e}", file=sys.stderr)
            return 2
        ok, reason = validate_doctor_payload(payload)
        if not ok:
            print(f"idc-command-report: refusing Doctor report: {reason}", file=sys.stderr)
            return 2
        return 0 if _write_report(cwd, "doctor", payload, args.session, "doctor-command", args.ts) else 1
    elif args.op == "read":
        if args.session:
            p = current_report(cwd, args.kind, args.session)
            if p is not None:
                print(json.dumps(p, sort_keys=True))
        else:
            r = read_report(cwd, args.kind)
            if r is not None:
                print(json.dumps(r, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
