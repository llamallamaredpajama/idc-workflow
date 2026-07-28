#!/usr/bin/env python3
"""idc_review_seen_ledger.py — the fixed per-PR review-round seen-fingerprint ledger (U7 Item 1).

The review→fix→re-review loop converges only when new findings are deduplicated against everything
ever SEEN — including rejected, refuted, and below-floor candidates — otherwise a finding dropped in
round 1 resurfaces in round 3 as "new", recycles the attempt counter, and re-files duplicate routed
board work. This module owns the durable per-PR ledger that closes that loop:

    docs/workflow/code-reviews/pr-<pr>-seen-fingerprints.json

Write-ownership contract (spec §4.4/§8): FIXED CODE alone validates and writes this ledger — the
coordinator records candidate rounds through the `record-round` CLI below, and the deterministic
filer (`idc_file_findings.py`) records verdict observations through `record_observations()`.
Model-authored verdict/report text never mutates it directly; a ledger that does not validate is
refused fail-closed (`SeenLedgerError`), never silently rebuilt or treated as empty.

CLI:
    idc_review_seen_ledger.py record-round --repo <dir> --round <round.json> [--tracker <TRACKER.md>]

where round.json is the coordinator's pre-floor candidate record:
    {"schema_version": 1, "pr": <int>,
     "candidates": [{"fingerprint": "<dim:file:line:gist>", "disposition": "below-floor", ...}]}
recorded BEFORE flooring/rejection/refutation, so a floored candidate is still seen later.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import stat
import sys
import tempfile
from typing import Any

SCHEMA_VERSION = 1
LEDGER_DIR_RELPATH = os.path.join("docs", "workflow", "code-reviews")
# Every way an observation can leave a round; "suppressed-seen" is the resurfaced-duplicate outcome.
DISPOSITIONS = ("filed", "confirmed", "suppressed-seen", "below-floor", "rejected", "refuted")
# The model-observable subset a coordinator round record may claim. The rest — filed / confirmed /
# suppressed-seen — are decided and written by the fixed-code filer only; "suppressed-seen" in
# particular buys a routing-gap exemption at finish, so a model-authored round must not mint it.
ROUND_DISPOSITIONS = ("below-floor", "rejected", "refuted")
# Prior dispositions that make a resurfaced fingerprint suppressible: terminal, non-routable
# outcomes only. "filed" is deliberately absent — it records a routing ATTEMPT, so a fingerprint
# whose filing failed stays retryable on the next run; actually-filed items remain idempotent via
# the filer's board-key dedupe, which reads the board itself, not this ledger.
TERMINAL_NON_ROUTABLE = ("suppressed-seen", "below-floor", "rejected", "refuted", "confirmed")
# The one disposition that records an OWED routing attempt rather than a settled outcome. An entry
# sitting at "filed" whose ticket is not on the board is a PENDING RETRY: the next filer run owes it
# a real board item. Overwriting it with any terminal disposition converts that owed work into a
# routing-gap exemption at finish — so the model-authored `record-round` door may not do it (see
# record_observations' model_authored guard).
PENDING_RETRY = "filed"


class SeenLedgerError(RuntimeError):
    """Malformed, unreadable, or non-fixed-code seen-fingerprint ledger state (fail closed)."""


def _utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")


def ledger_relpath(pr: int) -> str:
    return os.path.join(LEDGER_DIR_RELPATH, f"pr-{int(pr)}-seen-fingerprints.json")


def ledger_path(repo: str, pr: int) -> str:
    return os.path.join(os.path.abspath(repo), ledger_relpath(pr))


def _atomic_write_json(path: str, value: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    fd = -1
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(prefix=".seen-fingerprints-", suffix=".tmp", dir=parent)
        if os.path.exists(path):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        tmp = ""
    except OSError as exc:
        raise SeenLedgerError(f"could not write seen-fingerprint ledger {path}: {exc}") from exc
    finally:
        if fd != -1:
            os.close(fd)
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _validate_entry(entry: Any) -> dict[str, Any]:
    if not isinstance(entry, dict):
        raise SeenLedgerError(
            "seen-fingerprint ledger entries must be fixed-code-written objects "
            "(fingerprint/seen_count) — refusing a direct model-authored ledger write")
    fingerprint = entry.get("fingerprint")
    if not isinstance(fingerprint, str) or not fingerprint.strip():
        raise SeenLedgerError("seen-fingerprint ledger entry fingerprint must be a non-empty string")
    seen_count = entry.get("seen_count")
    if isinstance(seen_count, bool) or not isinstance(seen_count, int) or seen_count < 1:
        raise SeenLedgerError("seen-fingerprint ledger entry seen_count must be an integer >= 1")
    disposition = entry.get("last_disposition")
    if not isinstance(disposition, str) or not disposition.strip():
        raise SeenLedgerError("seen-fingerprint ledger entry last_disposition must be a non-empty string")
    for key in ("first_seen", "last_seen"):
        if key in entry and not isinstance(entry.get(key), str):
            raise SeenLedgerError(f"seen-fingerprint ledger entry {key} must be a string when present")
    return entry


def validate_ledger(value: Any, pr: int | None = None) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SeenLedgerError("seen-fingerprint ledger must be a JSON object")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise SeenLedgerError("seen-fingerprint ledger schema_version must be 1")
    ledger_pr = value.get("pr")
    if isinstance(ledger_pr, bool) or not isinstance(ledger_pr, int):
        raise SeenLedgerError("seen-fingerprint ledger pr must be an integer")
    if pr is not None and ledger_pr != int(pr):
        raise SeenLedgerError(f"seen-fingerprint ledger pr {ledger_pr} does not match PR {pr}")
    entries = value.get("entries")
    if not isinstance(entries, list):
        raise SeenLedgerError("seen-fingerprint ledger entries must be a list")
    fingerprints = set()
    for entry in entries:
        validated = _validate_entry(entry)
        if validated["fingerprint"] in fingerprints:
            raise SeenLedgerError(
                f"seen-fingerprint ledger holds duplicate entries for {validated['fingerprint']!r}")
        fingerprints.add(validated["fingerprint"])
    return value


def read_ledger(repo: str, pr: int) -> dict[str, Any] | None:
    """The validated ledger for this PR, or None when no ledger exists yet. Unreadable or invalid
    ledger state raises SeenLedgerError — fail closed, never an empty/clean default."""
    path = ledger_path(repo, pr)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SeenLedgerError(f"could not read seen-fingerprint ledger {path}: {exc}") from exc
    return validate_ledger(value, pr)


def seen_fingerprints(ledger: dict[str, Any] | None) -> set[str]:
    if not ledger:
        return set()
    return {entry["fingerprint"] for entry in ledger.get("entries", [])}


def suppressible_fingerprints(ledger: dict[str, Any] | None) -> set[str]:
    """The fingerprints a filer run may suppress as resurfaced: seen before AND last recorded in a
    terminal non-routable disposition. A bare "filed" never suppresses — otherwise a failed filing
    plus its own prescribed retry would permanently strand the finding as never-routed while the
    routing gap reads it as converged."""
    if not ledger:
        return set()
    return {entry["fingerprint"] for entry in ledger.get("entries", [])
            if entry.get("last_disposition") in TERMINAL_NON_ROUTABLE}


def _refuse_pending_retry_downgrade(by_fingerprint: dict[str, Any],
                                    observations: list[dict[str, Any]],
                                    routed_lookup: Any) -> None:
    """Fail-closed guard on the MODEL-AUTHORED write door (`record-round`).

    Write-ownership contract, stated as a state-transition rule instead of a value rule: restricting
    WHICH dispositions a round may claim is not enough, because the damage is done by WHICH ENTRY it
    overwrites. An entry at `filed` whose recirculation ticket is NOT on the board is a pending
    retry — the filer still owes it a board item. Letting a round record flip it to any terminal
    disposition (`rejected`/`refuted`/`below-floor`) makes the next filer run suppress it as
    resurfaced, and `idc_git_finish.routing_gap` then exempts `suppressed-seen` — a real finding is
    stranded forever while the finish gate reports converged and the merge proceeds.

    Corroboration, not a blanket refusal: when the ticket IS on the board the flip is harmless (the
    routed work survives in the tracker), and the legitimate "round-1 nit filed, round-2 coordinator
    rejects the re-raise" flow needs it to stay legal. So the refusal is exactly: downgrade a `filed`
    entry that the board does not corroborate. An unreadable board yields an empty corroboration set
    → refuse (fail closed), never a silent allow.

    `routed_lookup` is a zero-arg callable resolved AT MOST ONCE and ONLY when a round actually
    touches a pending-retry entry, so the ordinary round — which touches none — costs no board read
    (on the github backend that read is a metered API call)."""
    routed: frozenset[str] | None = None
    for obs in observations:
        fingerprint = str(obs.get("fingerprint", "")).strip()
        entry = by_fingerprint.get(fingerprint)
        if entry is None or entry.get("last_disposition") != PENDING_RETRY:
            continue
        if routed is None:
            routed = frozenset(routed_lookup() if callable(routed_lookup) else (routed_lookup or ()))
        if fingerprint in routed:
            continue
        raise SeenLedgerError(
            f"round record may not overwrite the PENDING-RETRY seen entry {fingerprint!r} "
            f"(last_disposition={PENDING_RETRY!r}) with "
            f"{str(obs.get('disposition', '')).strip()!r}: its recirculation ticket is not on the "
            "board, so the filing is still owed and a retry must be able to file it. Route the "
            "finding first (re-run idc_file_findings.py), then record the round.")


def record_observations(repo: str, pr: int, observations: list[dict[str, Any]],
                        model_authored: bool = False,
                        routed_lookup: Any = None) -> set[str]:
    """Record one observation per (fingerprint, disposition) into the per-PR ledger — seen_count
    increments, dispositions update, new fingerprints append. Returns the set of fingerprints that
    were already seen BEFORE this recording (the dedupe set callers suppress against). The load
    validates first, so an invalid ledger refuses the whole recording fail-closed.

    `model_authored=True` marks the coordinator's `record-round` door and enables the pending-retry
    downgrade guard above; `routed_lookup` supplies (as a set or a zero-arg callable) the
    board-corroborated fingerprints that exempt it. The guard runs BEFORE any mutation, so a refused
    round leaves the ledger byte-for-byte unchanged."""
    ledger = read_ledger(repo, pr)
    if ledger is None:
        ledger = {"schema_version": SCHEMA_VERSION, "pr": int(pr), "entries": []}
    prior = seen_fingerprints(ledger)
    by_fingerprint = {entry["fingerprint"]: entry for entry in ledger["entries"]}
    if model_authored:
        _refuse_pending_retry_downgrade(by_fingerprint, observations, routed_lookup)
    now = _utc_now()
    for obs in observations:
        fingerprint = str(obs.get("fingerprint", "")).strip()
        disposition = str(obs.get("disposition", "")).strip()
        if not fingerprint:
            raise SeenLedgerError("seen-fingerprint observation fingerprint must be non-empty")
        if disposition not in DISPOSITIONS:
            raise SeenLedgerError(
                f"seen-fingerprint observation disposition {disposition!r} is not one of {DISPOSITIONS}")
        entry = by_fingerprint.get(fingerprint)
        if entry is None:
            entry = {"fingerprint": fingerprint, "seen_count": 1,
                     "first_seen": now, "last_seen": now, "last_disposition": disposition}
            by_fingerprint[fingerprint] = entry
        else:
            entry["seen_count"] = int(entry["seen_count"]) + 1
            entry["last_seen"] = now
            entry["last_disposition"] = disposition
    ledger["entries"] = [by_fingerprint[key] for key in sorted(by_fingerprint)]
    _atomic_write_json(ledger_path(repo, pr), ledger)
    return prior


def _validate_round(value: Any) -> tuple[int, list[dict[str, Any]]]:
    if not isinstance(value, dict):
        raise SeenLedgerError("round record must be a JSON object")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise SeenLedgerError("round record schema_version must be 1")
    pr = value.get("pr")
    if isinstance(pr, bool) or not isinstance(pr, int):
        raise SeenLedgerError("round record pr must be an integer")
    candidates = value.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise SeenLedgerError("round record candidates must be a non-empty list")
    observations = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise SeenLedgerError("round record candidates must be objects")
        fingerprint = candidate.get("fingerprint")
        if not isinstance(fingerprint, str) or not fingerprint.strip():
            raise SeenLedgerError("round candidate fingerprint must be a non-empty string")
        disposition = candidate.get("disposition")
        if disposition not in ROUND_DISPOSITIONS:
            raise SeenLedgerError(
                f"round candidate disposition {disposition!r} is not one of {ROUND_DISPOSITIONS} — "
                "filed/confirmed/suppressed-seen are reserved for the fixed-code filer")
        observations.append({"fingerprint": fingerprint.strip(), "disposition": disposition})
    return pr, observations


def _board_routed_fingerprints(repo: str, tracker: str | None) -> frozenset[str]:
    """The fingerprints whose recirculation ticket the BOARD actually carries — the corroboration
    set for the pending-retry guard. Delegates to the filer's existing dedupe-key readers (one
    implementation of "what is already routed", shared with idc_git_finish.routing_gap); imported
    lazily because the filer imports this module. Any read failure ⇒ empty set ⇒ the guard refuses
    (fail closed), never a downgrade granted on an unverifiable board."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import idc_file_findings as FF  # noqa: PLC0415 — lazy: FF imports this module at load
        return FF.routed_finding_fingerprints(repo, tracker)
    # Deliberately broad, and safe BECAUSE it is broad: every outcome of this handler REFUSES the
    # downgrade (empty corroboration set), so no failure mode here can widen what a round may do.
    except (Exception, SystemExit) as exc:  # noqa: BLE001 — fail CLOSED on any read/import failure
        print(f"idc-review-seen-ledger: could not read the board to corroborate routed findings "
              f"({str(exc)[:160]}) — treating nothing as routed (fail closed)", file=sys.stderr)
        return frozenset()


def _cmd_record_round(args: argparse.Namespace) -> int:
    try:
        with open(args.round, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SeenLedgerError(f"could not read round record {args.round}: {exc}") from exc
    pr, observations = _validate_round(value)
    prior = record_observations(
        args.repo, pr, observations, model_authored=True,
        routed_lookup=lambda: _board_routed_fingerprints(args.repo, args.tracker))
    resurfaced = sum(1 for obs in observations if obs["fingerprint"] in prior)
    print(f"idc-review-seen-ledger: recorded {len(observations)} candidate(s) for PR #{pr} "
          f"({resurfaced} previously seen) at {ledger_relpath(pr)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("record-round",
                       help="record a review round's candidate fingerprints (pre-floor) into the ledger")
    r.add_argument("--repo", required=True, help="the governed repo root")
    r.add_argument("--round", required=True, help="path to the round-record JSON")
    r.add_argument("--tracker", default=None,
                   help="TRACKER.md path (filesystem backend; default <repo>/TRACKER.md) — read to "
                        "corroborate which findings are already routed to the board")
    r.set_defaults(func=_cmd_record_round)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except SeenLedgerError as exc:
        print(f"idc-review-seen-ledger: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
