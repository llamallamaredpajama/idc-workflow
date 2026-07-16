#!/usr/bin/env python3
"""idc_command_contract.py — the universal IDC command lifecycle contract (Task 2, command integrity).

A governed `/idc:*` command is an OBLIGATION: it is ENTERED (a lifecycle record opens in the session
ledger) and it must be CLOSED with a valid terminal status. This module is the runtime-neutral façade
over that contract — the same validation and the same single ledger write door whether the caller is a
Claude hook, a command's markdown tail, Codex, or Pi. It owns three responsibilities:

  * `start`  — open (idempotently upsert) the command's active record, AFTER a Task-1 freshness check:
               a stale plugin runtime must never open a record (exit 4, no write), because a stale
               command body would record an obligation it cannot honestly discharge.
  * `finish` — close an existing active record owned by this session with a validated terminal status
               + evidence envelope. Rejects an unknown command/status, malformed JSON, an invalid
               envelope, a missing active record, or a foreign session.
  * `status` — read the session's active + finished command records (for the Stop closeout gate's
               human remediation and for tests).

There is DELIBERATELY no `abort-stale` / erase op: an agent cannot make an obligation disappear
without a valid terminal status. The only way out of an open command is an honest `finish`.

ENVELOPE + COMMAND-SPECIFIC EVIDENCE (Task 2 shipped the envelope; Task 6 adds the per-command
matrix). `finish` first validates the COMMON envelope — `schema_version` == 1 and `refs` is an object
— then the per-command, per-status evidence matrix (`validate_closeout`): a think `complete` must carry
a MERGED Think PR + a disposed one-marker gate + an admitted pointer + valid intake coverage; a build
`complete` its per-issue STRUCTURED merged-PR receipts (or an oracle-backed empty ready frontier); an
autorun `complete` this session's PERSISTED `drain: complete` verdict; and so on. Evidence is a set of
REFERENCES to DURABLE artifacts the validator re-verifies for real — never a caller-supplied `passed:
true` or a `"pass"` string. Facts re-read from durable state rather than trusted: intake coverage is
re-read from the recorded manifest (finding 2); every `no_action`/empty-frontier close is checked
against a fresh read-only next-action oracle; the autorun `drain: complete` is read from
`.idc-drain-verdict.json` (session-scoped); the plan matrix is re-validated through `idc_matrix_check`;
and a `blocked_external` helper must be a REAL shipped deterministic script. `blocked_external` must
cite that helper's nonzero exit + a concise diagnostic; it is an honest blocked stop, never a disguised
success.
The legal terminal statuses are further narrowed PER COMMAND (a lifecycle/diagnostic command may not
claim a pipeline `waiting_gate`/`no_action`).

CLI:
  idc_command_contract.py start  --repo R --session S --command C --plugin-root P [--args T] [--source T]
  idc_command_contract.py finish --repo R --session S --command C --status STATUS --evidence-json JSON
  idc_command_contract.py status --repo R [--session S] [--json]
Exit codes: 0 = ok; 4 = stale runtime (start only, no record written); 2 = invalid input (unknown
command/status, malformed JSON, invalid evidence envelope, an invalid receipt, or a missing/foreign
active record on finish).
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                       # scripts/ — for idc_plugin_freshness
sys.path.insert(0, os.path.join(_HERE, "hooks"))  # scripts/hooks/ — for idc_ledger
import idc_plugin_freshness as freshness  # noqa: E402
import idc_ledger  # noqa: E402

# The eleven governed `/idc:*` entry points. Kept in lockstep with commands/*.md and the
# UserPromptExpansion matcher in hooks/hooks.json.
COMMANDS = {
    "autorun", "build", "doctor", "init", "intake", "janitor",
    "plan", "recirculate", "think", "uninstall", "update",
}
# The four honest ways a command lifecycle can END (the GLOBAL set). Task 6 narrows the legal subset
# PER COMMAND (LEGAL_STATUSES) and attaches command-specific evidence to each.
TERMINAL_STATUSES = {"complete", "waiting_gate", "no_action", "blocked_external"}

# Per-command legal terminal statuses (Task 6 matrix) are DERIVED from the claim table (`LEGAL_STATUSES`,
# defined just after `_CLAIM_TABLE` below): a command×status is legal IFF the table enumerates a
# non-empty claim list for it. "A claim with no derivable source means that terminal status is NOT
# claimable — fail closed." A pipeline command may wait behind a human gate; a planning/build command
# may honestly report no_action (oracle-backed); a lifecycle/diagnostic command either completes or is
# externally blocked — it may not claim a pipeline handoff it does not own. Every command may report
# `blocked_external` (a proven, allowlisted deterministic-helper failure).

# Valid durable dispositions an intake unit may carry after review (idc_intake_manifest). A think
# closeout's remainder units must sit in one of these — never `unclassified`.
_DURABLE_DISPOSITIONS = {"queued", "materialized", "verified_done", "ignored"}


@dataclasses.dataclass(frozen=True)
class CloseoutResult:
    ok: bool
    reason_code: str
    message: str
    normalized_evidence: dict


# ── command-specific evidence helpers ──────────────────────────────────────────────────────────────
def _fail(code: str, message: str) -> CloseoutResult:
    return CloseoutResult(False, code, message, {})


def _ne_str(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _present(value: object) -> bool:
    """A non-empty reference: a positive int or a non-empty string (an issue number or a locator)."""
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return value > 0
    return _ne_str(value)


def _known_helper(name: object) -> bool:
    """True iff `name` is a REAL deterministic helper shipped with the plugin — a basename that exists
    under `scripts/` or `scripts/hooks/`. A blocker must cite a helper that EXISTS (verify the
    referenced artifact for real), so a phantom helper name can never manufacture a blocked stop."""
    if not _ne_str(name):
        return False
    base = os.path.basename(str(name))
    if base != str(name) or not (base.endswith(".py") or base.endswith(".sh")):
        return False
    return os.path.isfile(os.path.join(_HERE, base)) or os.path.isfile(os.path.join(_HERE, "hooks", base))


# The autorun drain writes a NON-complete verdict (rate-limited/unknown/board-read-error/…) to the
# durable, session-scoped `.idc-drain-verdict.json` on EVERY blocked path — so a blocked_external that
# cites the drain can be RE-DERIVED from that artifact rather than a caller-typed exit/diagnostic, and
# its cited exit MATCHED against the persisted one (wave-3 finding 1: the r3 probe — a persisted exit 2
# closed with a caller exit 3 must refuse).
_DRAIN_HELPER = "idc_autorun_drain.py"
# The janitor scanner persists its exit to the durable session-scoped janitor report (idc_command_report),
# so a janitor blocked_external's cited exit is RE-DERIVED + MATCHED against that artifact too.
_JANITOR_HELPER = "idc_git_janitor.py"
# The provenance stamp the janitor SCANNER alone writes on its report (round-5 finding 7). The closeout
# requires it, so a hand-written report that omits it cannot be passed off as a real scan.
_JANITOR_PROVENANCE = "idc_git_janitor.py"
# The receipt checker is safely RE-RUNNABLE read-only (a fingerprint verify), so an init/update/uninstall
# blocker citing it is RE-DERIVED by re-running it — grounded only when the re-run actually FAILS.
_RECEIPT_HELPER = "idc_receipt_check.py"
# The janitor scanner's DOCUMENTED blocked exit (ground truth could not be established). Exit 1 is a
# COMPLETED scan with findings (a `complete`, not blocked); only exit 2 grounds `blocked_external`
# (wave-4 finding 1 — fix the exit map).
_JANITOR_BLOCKED_EXIT = 2

# Per-command allowlist of LEGITIMATE blocking helpers (wave-3 finding 1, tightened wave-4 finding 1).
# A `blocked_external` may cite ONLY a deterministic helper that BELONGS to the command AND is
# RE-DERIVABLE — one that either wrote a DURABLE failure receipt (the drain verdict, the janitor report)
# or is safely RE-RUNNABLE read-only (the receipt fingerprint checker). Helpers that write no receipt and
# cannot be re-run read-only (PR finishers, transition/board mutators, arg-hungry checkers) are OFF the
# allowlist (rule B): a caller `exit`/`diagnostic` for them is never accepted, so those commands cannot
# manufacture a blocked stop. Commands with NO re-derivable helper carry no `blocked_external` claim at
# all (see _CLAIM_TABLE — not claimable, fail closed).
_BLOCKER_HELPERS = {
    "build":       {_DRAIN_HELPER},
    "autorun":     {_DRAIN_HELPER},
    "janitor":     {_JANITOR_HELPER},
    "doctor":      {_JANITOR_HELPER},
    "init":        {_RECEIPT_HELPER},
    "update":      {_RECEIPT_HELPER},
    "uninstall":   {_RECEIPT_HELPER},
}


def _check_blocker(command: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    """`blocked_external` proof: a real shipped deterministic helper that BELONGS to THIS command (the
    per-command allowlist, finding 1a), its NONZERO exit, and a concise diagnostic. This is an honest
    blocked stop — never a disguised success. For a helper that wrote a DURABLE artifact (the drain
    verdict / the janitor report), the blocked evidence is additionally RE-DERIVED from that artifact
    and the cited exit MATCHED against the persisted one (finding 1b) — so an invented failure, or a
    real failure closed with a MISMATCHED exit, is refused."""
    blocker = refs.get("blocker")
    if not isinstance(blocker, dict):
        return _fail("blocked-external-no-blocker",
                     "blocked_external requires refs.blocker = {helper, exit, diagnostic}")
    if not _ne_str(blocker.get("helper")):
        return _fail("blocked-external-no-helper", "refs.blocker.helper must name the failing helper")
    if not _known_helper(blocker.get("helper")):
        return _fail("blocked-external-unknown-helper",
                     "refs.blocker.helper must name a real deterministic helper shipped under scripts/ "
                     "(a phantom helper cannot manufacture a blocked stop)")
    base = os.path.basename(str(blocker.get("helper")))
    if base not in _BLOCKER_HELPERS.get(command, set()):
        return _fail("blocked-external-helper-not-for-command",
                     f"{base!r} is not a legitimate blocking helper for /idc:{command} — a helper that "
                     "does not belong to this command cannot close it (a blocked stop must cite one of "
                     f"the command's own deterministic helpers: {sorted(_BLOCKER_HELPERS.get(command, set()))})")
    code = blocker.get("exit")
    if isinstance(code, bool) or not isinstance(code, int) or code == 0:
        return _fail("blocked-external-zero-exit",
                     "refs.blocker.exit must be the helper's NONZERO exit code (a blocker is not a success)")
    if not _ne_str(blocker.get("diagnostic")):
        return _fail("blocked-external-no-diagnostic", "refs.blocker.diagnostic must be a concise reason")
    if base == _DRAIN_HELPER:
        # RE-DERIVE + MATCH the drain blocker from the DURABLE artifact the drain wrote (session-scoped,
        # staleness-guarded) — never the caller's typed exit/diagnostic. The drain persists a
        # non-complete verdict + nonzero exit on every blocked path, so an invented drain failure (no
        # such verdict for THIS session) OR a real failure cited with a MISMATCHED exit is refused.
        verdict = _persisted_drain_verdict(repo, session)
        if verdict is None:
            return _fail("blocked-external-drain-unproven",
                         "blocked_external citing the drain requires THIS session's persisted drain "
                         "verdict (.idc-drain-verdict.json) — none found (absent, foreign, or stale)")
        token = verdict.get("verdict")
        vexit = verdict.get("exit")
        if token == "complete" or isinstance(vexit, bool) or vexit in (0, None):
            return _fail("blocked-external-drain-not-blocked",
                         "blocked_external citing the drain requires a NON-complete persisted verdict "
                         f"with a nonzero exit; got verdict={token!r} exit={vexit!r}")
        if code != vexit:
            return _fail("blocked-external-drain-exit-mismatch",
                         f"blocked_external cites exit {code} but the drain PERSISTED exit {vexit!r} "
                         f"(verdict {token!r}) — the cited exit must MATCH the durable artifact, not the "
                         "caller's typed value")
    elif base == _JANITOR_HELPER:
        # RE-DERIVE + MATCH the janitor blocker from THIS session's persisted janitor report: the
        # scanner records its exit there. Only the DOCUMENTED blocked exit (2 — ground truth could not
        # be established) grounds a blocked stop; a persisted exit 1 is a COMPLETED scan WITH FINDINGS
        # (a `complete`, not blocked — wave-4 finding 1). The report must be nonce-bound to this record.
        report = _command_report(repo, "janitor", session)
        rexit = report.get("scanner_exit") if isinstance(report, dict) else None
        if not isinstance(rexit, int) or isinstance(rexit, bool):
            return _fail("blocked-external-janitor-unproven",
                         "blocked_external citing the janitor scanner requires THIS session's persisted "
                         "janitor report (.idc-janitor-report.json) recording the scanner_exit — none found")
        if not _report_nonce_bound(repo, command, session, report):
            return _fail("blocked-external-janitor-nonce",
                         "blocked_external citing the janitor scanner requires the persisted report bound "
                         "to THIS command record's nonce (written by the scanner run of this invocation)")
        if report.get("produced_by") != _JANITOR_PROVENANCE:
            return _fail("blocked-external-janitor-provenance",
                         "blocked_external citing the janitor scanner requires the persisted report to "
                         "carry the scanner's provenance stamp (produced_by) — a hand-written report "
                         "cannot be passed off as a real scan (round-5 finding 7)")
        if rexit != _JANITOR_BLOCKED_EXIT:
            return _fail("blocked-external-janitor-not-blocked",
                         "blocked_external citing the janitor scanner requires the DOCUMENTED blocked "
                         f"exit {_JANITOR_BLOCKED_EXIT} (ground truth unestablished); the report records "
                         f"{rexit!r} — exit 1 is a completed scan with findings (that is `complete`, not blocked)")
        if code != rexit:
            return _fail("blocked-external-janitor-exit-mismatch",
                         f"blocked_external cites exit {code} but the janitor report PERSISTED "
                         f"scanner_exit {rexit!r} — the cited exit must MATCH the durable artifact")
    elif base == _RECEIPT_HELPER:
        # RE-RUN the receipt fingerprint checker READ-ONLY (safely re-runnable): the blocker is grounded
        # ONLY when the re-run actually FAILS (an invalid receipt, or a modified/missing stamped file).
        # A clean re-run refuses the blocker (a helper that succeeds cannot ground a blocked stop).
        fp = _receipt_fingerprints_ok(repo, refs.get("receipt"))
        if fp.ok:
            return _fail("blocked-external-receipt-not-failing",
                         "blocked_external citing the receipt checker requires a re-run to actually FAIL "
                         "(an invalid receipt or a modified/missing stamped file); the read-only re-run "
                         "passed — there is no deterministic failure to ground a blocked stop")
    else:
        # A helper on no re-derivation path (no durable receipt, not safely re-runnable) cannot ground a
        # blocked stop — a caller exit/diagnostic is never accepted as ground truth (wave-4 finding 1).
        return _fail("blocked-external-not-rederivable",
                     f"{base!r} writes no durable failure receipt and cannot be re-run read-only, so a "
                     "caller-supplied exit/diagnostic cannot prove it failed — this helper cannot ground "
                     "a blocked_external (fail closed)")
    return CloseoutResult(True, "ok", "blocked_external re-derived from a durable receipt or a read-only re-run", {})


def _command_report(repo: str, kind: str, session: str):
    """THIS session's persisted per-command diagnostic report payload (idc_command_report) for `kind`,
    or None (absent/foreign/stale). The durable artifact a doctor/janitor RUN wrote, session-scoped —
    read tolerantly (any failure → None → the closeout fails closed)."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        import idc_command_report as CR  # noqa: E402 — lazy (scripts/hooks is on sys.path)
        return CR.current_report(repo, kind, session)
    except Exception:  # noqa: BLE001 — a report read failure is fail-closed for the closeout
        return None


def _record_nonce(repo: str, command: str, session: str):
    """The per-invocation nonce stamped on THIS session's ACTIVE record for `command` at start
    (wave-4 finding 7), or None. A diagnostic report (doctor/janitor) must carry this nonce for its
    closeout to accept it, so a stale/foreign report cannot back a new run. Read tolerantly."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == command and rec.get("nonce"):
                return rec.get("nonce")
    except Exception:  # noqa: BLE001
        return None
    return None


def _report_nonce_bound(repo: str, command: str, session: str, report: dict) -> bool:
    """True iff the persisted report's `nonce` matches the active record's stamped nonce (wave-4
    finding 7). When the record carries NO nonce (an older record shape / a runtime with no record
    readback), fall back to session scoping alone (the report is already session-scoped) so a
    nonce-less honest run is not falsely refused — the nonce is defense-in-depth, not the only gate."""
    record_nonce = _record_nonce(repo, command, session)
    if record_nonce is None:
        return True
    return isinstance(report, dict) and report.get("nonce") == record_nonce


def _oracle_action(repo: str):
    """A fresh read-only next-action oracle result for `repo` (Task 5), or None if it could not be
    established (missing repo, invalid/unreadable state, or a throttle) — every such case fails the
    no_action check CLOSED, because an unproven fixpoint is never an honest no_action."""
    if not _ne_str(repo):
        return None
    try:
        import idc_next_action as NEXT  # noqa: E402 — lazy: keep start/status/envelope light
        action = NEXT.decide(repo)
    except Exception:  # noqa: BLE001 — any oracle failure is fail-closed for no_action
        return None
    if action.verdict == "invalid" or action.reason_code == "rate-limited":
        return None
    return action


def _check_no_action(command: str, repo: str) -> CloseoutResult:
    """`no_action` is legal ONLY when a fresh oracle proves this command's lane is empty. Plan needs
    zero admitted considerations; Build needs zero eligible Buildables."""
    action = _oracle_action(repo)
    if action is None:
        return _fail("no-action-unproven",
                     "no_action requires a fresh, valid next-action oracle result for this repo")
    counts = action.counts or {}
    if command == "plan" and counts.get("considerations", 0) != 0:
        return _fail("no-action-contradicted",
                     "no_action rejected — the oracle still reports admitted considerations to plan")
    if command == "build" and counts.get("eligible_buildables", 0) != 0:
        return _fail("no-action-contradicted",
                     "no_action rejected — the oracle still reports eligible Buildable work")
    return CloseoutResult(True, "ok", "no_action is oracle-backed", {})


# ── real GitHub-state reads (round-2 F1/F2): a PR merged-state / issue body is a claim that lives on
# GitHub, so the validator READS it for real (`gh pr view` / `gh issue view`) and never trusts a
# caller `state:"MERGED"`. Every read is fail-closed: gh missing, a nonzero exit, or unparseable JSON
# all yield None, and the caller treats None as "not proven". Hermetic tests inject a fake `gh` on PATH
# (the suite's established pattern), including a sabotage where the fake returns UNMERGED. ─────────────
_GH_TIMEOUT_S = 30


def _gh_capture(repo: str, args: list) -> str | None:
    """Run `gh <args>` in `repo`, returning stdout on a zero exit, else None (gh absent, nonzero, or
    a timeout). Read-only by contract — callers pass only `view`/read subcommands."""
    if not _ne_str(repo) or not os.path.isdir(repo):
        return None
    try:
        proc = subprocess.run(["gh", *args], cwd=repo, capture_output=True, text=True,
                              timeout=_GH_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def _gh_pr_state(repo: str, pr: object):
    """A REAL `gh pr view` read of `pr`'s state, returned as the enum `"MERGED"`/`"OPEN"`/`"CLOSED"`
    (a closed-unmerged PR), or None (could not establish — fail closed). The caller NEVER supplies the
    state; it is re-derived here (wave-4 finding 2: a dead CLOSED gate is operator-attention, not a
    valid wait, so the enum must distinguish CLOSED from OPEN — the old boolean collapsed both)."""
    if isinstance(pr, bool) or not _present(pr):
        return None
    try:
        pr_int = int(pr)
    except (TypeError, ValueError):
        return None
    out = _gh_capture(repo, ["pr", "view", str(pr_int), "--json", "state,mergedAt"])
    if out is None:
        return None
    try:
        info = json.loads(out)
    except ValueError:
        return None
    if not isinstance(info, dict):
        return None
    if info.get("state") == "MERGED" or info.get("mergedAt"):
        return "MERGED"
    return "CLOSED" if info.get("state") == "CLOSED" else "OPEN"


def _gh_pr_merged(repo: str, pr: object):
    """A REAL `gh pr view` read of `pr`'s merged-state. Returns True (MERGED), False (a real read
    proved NOT merged — OPEN or CLOSED), or None (could not establish — fail closed). Derived from the
    state enum so the merged fact and the OPEN/CLOSED distinction never drift."""
    state = _gh_pr_state(repo, pr)
    return None if state is None else (state == "MERGED")


def _gh_pr_closes_issue(repo: str, pr: object, issue: object):
    """True iff a REAL `gh pr view --json closingIssuesReferences` read shows PR `pr` closes issue
    `issue` — the PR↔issue linkage proven from the PR's OWN closing references, never receipt
    adjacency (wave-4 finding 5). None when the read cannot be established (fail closed)."""
    if isinstance(pr, bool) or not _present(pr) or not _present(issue):
        return None
    try:
        pr_int, issue_int = int(pr), int(_gate_key(issue))
    except (TypeError, ValueError):
        return None
    out = _gh_capture(repo, ["pr", "view", str(pr_int), "--json", "closingIssuesReferences"])
    if out is None:
        return None
    try:
        info = json.loads(out)
        refs = info.get("closingIssuesReferences") if isinstance(info, dict) else None
    except ValueError:
        return None
    if not isinstance(refs, list):
        return None
    return any(isinstance(r, dict) and r.get("number") == issue_int for r in refs)


def _issue_stage_status(repo: str, num: object):
    """The referenced issue's CURRENT board (`Stage`, `Status`) via the shared tracker reader, or
    (None, None) when it is absent from the board / the tracker cannot be read (fail closed). Round-5
    finding 3: a recirc ticket's closeout is re-derived from BOTH Stage and Status (a drained recirc
    ticket stays a `Recirculation`-stage Done item), not Status alone."""
    try:
        import idc_next_action as NEXT  # noqa: E402 — reuse the shared, constrained tracker reader
        key = _gate_key(num)
        for issue in NEXT._load_tracker_issues(repo):
            if _gate_key(issue.get("number")) == key:
                return issue.get("stage"), issue.get("status")
    except Exception:  # noqa: BLE001 — any tracker read failure fails the closeout closed
        return None, None
    return None, None


def _issue_status(repo: str, num: object):
    """The referenced issue's CURRENT board status (`Todo`/`Blocked`/`Done`/…), or None when it is
    absent / the tracker cannot be read (fail closed). Lets a waiting/closeout claim read the LIVE board
    state (the gate still open, the pointer genuinely Blocked/retired) rather than journal-absence alone."""
    return _issue_stage_status(repo, num)[1]


def _gh_issue_body(repo: str, num: object):
    """The LIVE github issue body for `num` via `gh issue view`, or None (missing/unreadable — fail
    closed). A successful read also PROVES the issue exists."""
    if isinstance(num, bool) or not _present(num):
        return None
    try:
        num_int = int(num)
    except (TypeError, ValueError):
        return None
    return _gh_capture(repo, ["issue", "view", str(num_int), "--json", "body", "-q", ".body"])


def _repo_backend(repo: str) -> str:
    """The repo's tracker backend (`github`/`filesystem`), tolerant: any read problem defaults to
    `filesystem` (the historical default) so a github-only re-verification is only DEMANDED where the
    config actually says github."""
    try:
        import idc_next_action as NEXT  # noqa: E402 — reuse the one constrained config reader
        backend, _ = NEXT._read_tracker_config(repo)
        return backend
    except Exception:  # noqa: BLE001
        return "filesystem"


def _load_issue_numbers(repo: str):
    """The set of live tracker issue numbers (as canonical strings) via the shared reader, or None on
    any read failure (fail closed). Used to verify decomposition children EXIST on the board."""
    try:
        import idc_next_action as NEXT  # noqa: E402
        return {_gate_key(i["number"]) for i in NEXT._load_tracker_issues(repo)}
    except Exception:  # noqa: BLE001
        return None


def _confined_repo_path(repo: str, rel: object) -> str | None:
    """Resolve a repo-relative locator strictly inside `repo` (no absolute path, no `..` escape)."""
    if not _ne_str(repo) or not _ne_str(rel) or os.path.isabs(str(rel)):
        return None
    root = os.path.realpath(os.path.abspath(repo))
    candidate = os.path.realpath(os.path.join(root, str(rel)))
    try:
        if os.path.commonpath((root, candidate)) != root or candidate == root:
            return None
    except ValueError:
        return None
    return candidate


# ── wave-3 derivation sources: each re-derives ONE terminal fact from durable state (never a caller
# assertion). A caller may supply only REFERENCE KEYS (a path, an issue/PR number, a unit id). ────────
_GATE_PR_MARKER_RE = re.compile(r"<!--\s*idc-gate-pr:\s*(\d+)\s*-->")


def _run_consideration_check(repo: str, rel: object) -> CloseoutResult:
    """RE-RUN the shipped consideration checker on the referenced consideration file (a repo-relative
    path Think wrote) — never a caller `consideration:"pass"` string (wave-3 finding 2). A
    missing/unreadable file or a failing check fails the closeout closed."""
    path = _confined_repo_path(repo, rel)
    if path is None or not os.path.isfile(path):
        return _fail("think-consideration-bad-ref",
                     "refs.consideration must be a repo-relative path to the consideration file Think "
                     "wrote (its PASS is RE-RUN, never a caller 'pass' string)")
    try:
        import idc_consideration_check as CONS  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            problems = CONS.check(handle.read())
    except Exception as exc:  # noqa: BLE001 — an unreadable consideration blocks the closeout
        return _fail("think-consideration-invalid", f"the consideration file could not be checked: {exc}")
    if problems:
        return _fail("think-consideration-fail",
                     f"the consideration file fails the consideration check: {problems[0]}")
    return CloseoutResult(True, "ok", "consideration re-checked PASS", {})


def _gate_marker_bound(repo: str, gate: object, think_pr: object) -> CloseoutResult:
    """Read the gate's LIVE body (real `gh issue view`) and re-derive the marker count/binding: EXACTLY
    ONE `<!-- idc-gate-pr: N -->` marker, bound to the Think PR (N == think_pr) — never a caller
    `gate_markers:1` (wave-3 finding 2). A nonexistent/unreadable gate (gh errors) fails closed. This
    mirrors idc_transition.check_gate_approved's exactly-one-body-marker rule."""
    body = _gh_issue_body(repo, gate)
    if body is None:
        return _fail("think-gate-unread",
                     "think closeout: the gate body could not be read (a nonexistent/unreadable gate "
                     "fails closed) — the marker count/binding is re-derived from the gate body, never trusted")
    markers = _GATE_PR_MARKER_RE.findall(body)
    if len(markers) != 1:
        return _fail("think-gate-markers",
                     f"think closeout requires EXACTLY ONE idc-gate-pr marker in the gate body, found "
                     f"{len(markers)} ({', '.join('#' + m for m in markers) or 'none'})")
    try:
        pr_int = int(think_pr)
    except (TypeError, ValueError):
        return _fail("think-gate-binding", "refs.think_pr must be a PR number to bind the gate marker")
    if int(markers[0]) != pr_int:
        return _fail("think-gate-binding",
                     f"the gate's idc-gate-pr marker binds PR #{markers[0]}, not the Think PR #{pr_int}")
    return CloseoutResult(True, "ok", "gate carries exactly one marker bound to the Think PR", {})


def _journal_records(repo: str):
    """Every parsed transition-journal record (FAIL-CLOSED via idc_journal_replay.scan_journal_strict),
    or None on any read error/corruption — a durable, backend-agnostic source. Used to re-derive a
    gate disposal / pointer admission from the sanctioned write door's own audit trail."""
    if not _ne_str(repo):
        return None
    try:
        import idc_journal_replay as RP  # noqa: E402 — lazy
        entries, err = RP.scan_journal_strict(os.path.join(repo, "docs", "workflow",
                                                             "transition-journal.ndjson"))
        if err:
            return None
        return entries, RP
    except Exception:  # noqa: BLE001 — a journal read failure fails the closeout closed
        return None


def _gate_disposed(repo: str, gate: object) -> CloseoutResult:
    """Re-derive gate DISPOSAL from the transition journal: a sanctioned `dispose` record naming THIS
    gate with `disposition == 'gate-approved'` (wave-3 finding 2) — never a caller
    `gate_disposition:"disposed"`. The journal is the ONLY clean proof a gate's Done came from the
    guarded door (see the re-dispose memory). A missing/corrupt journal or no such record fails closed."""
    scanned = _journal_records(repo)
    if scanned is None:
        return _fail("think-gate-journal-unread",
                     "think complete: the transition journal could not be read to re-derive the gate "
                     "disposal (fail closed)")
    entries, RP = scanned
    try:
        gate_num = int(_gate_key(gate))
    except (TypeError, ValueError):
        return _fail("think-gate-ref", "refs.gate must be a gate issue number")
    for e in entries:
        if e.get("op") == "dispose" and e.get("disposition") == "gate-approved" \
                and RP.journal_item_id(e) == gate_num:
            return CloseoutResult(True, "ok", "gate disposed (journal dispose/gate-approved record)", {})
    return _fail("think-gate-open",
                 f"think complete requires gate #{gate_num} disposed through the guarded door — no "
                 "`dispose`/`gate-approved` journal record names it (a gate-approved Done is proven "
                 "only by that record)")


def _gate_not_disposed(repo: str, gate: object) -> CloseoutResult:
    """The waiting_gate counterpart: the gate must EXIST but NOT yet be disposed. Re-derives from the
    journal (a readable journal with NO dispose/gate-approved record for this gate). A missing/corrupt
    journal fails closed (indeterminate)."""
    scanned = _journal_records(repo)
    if scanned is None:
        return _fail("think-gate-journal-unread",
                     "think waiting_gate: the transition journal could not be read to confirm the gate "
                     "is not yet disposed (fail closed)")
    entries, RP = scanned
    try:
        gate_num = int(_gate_key(gate))
    except (TypeError, ValueError):
        return _fail("think-gate-ref", "refs.gate must be a gate issue number")
    for e in entries:
        if e.get("op") == "dispose" and e.get("disposition") == "gate-approved" \
                and RP.journal_item_id(e) == gate_num:
            return _fail("think-gate-already-disposed",
                         f"think waiting_gate: gate #{gate_num} is ALREADY disposed (a dispose record "
                         "names it) — a disposed gate is not a wait; close as complete instead")
    return CloseoutResult(True, "ok", "gate not yet disposed (waiting)", {})


def _pointer_exists(repo: str, pointer: object) -> bool | None:
    """True iff the pointer's LIVE body reads (real `gh issue view` — a successful read proves it
    exists), None when it cannot be established (gh errors / a nonexistent pointer). Existence is what
    makes 'a nonexistent PR/gate/pointer must refuse' (finding 2) hold on both closeout paths."""
    body = _gh_issue_body(repo, pointer)
    return None if body is None else True


def _pointer_admitted(repo: str, pointer: object) -> CloseoutResult:
    """Re-derive pointer ADMISSION: the pointer EXISTS (real read) AND a sanctioned `unblock` journal
    record names it — the guarded door that admits a consideration pointer past its Think gate (wave-3
    finding 2). Never a caller `pointer_state:"admitted"`. A nonexistent pointer, or no unblock record,
    fails closed."""
    if _pointer_exists(repo, pointer) is None:
        return _fail("think-pointer-missing",
                     "think complete: the consideration pointer could not be read (a nonexistent pointer "
                     "fails closed)")
    scanned = _journal_records(repo)
    if scanned is None:
        return _fail("think-pointer-journal-unread",
                     "think complete: the transition journal could not be read to re-derive the pointer "
                     "admission (fail closed)")
    entries, RP = scanned
    try:
        ptr_num = int(_gate_key(pointer))
    except (TypeError, ValueError):
        return _fail("think-pointer-ref", "refs.pointer must be a pointer issue number")
    for e in entries:
        if e.get("op") == "unblock" and RP.journal_item_id(e) == ptr_num:
            return CloseoutResult(True, "ok", "pointer admitted (journal unblock record)", {})
    return _fail("think-pointer",
                 f"think complete requires the consideration pointer #{ptr_num} admitted through the "
                 "guarded door — no `unblock` journal record names it (admission is not a caller string)")


def _pointer_blocked(repo: str, pointer: object) -> CloseoutResult:
    """The waiting_gate counterpart: the pointer must EXIST but NOT yet be admitted (no unblock
    record) — still blocked behind its Think gate. A nonexistent pointer, or an already-admitted
    pointer, fails closed."""
    if _pointer_exists(repo, pointer) is None:
        return _fail("think-pointer-missing",
                     "think waiting_gate: the consideration pointer could not be read (a nonexistent "
                     "pointer fails closed)")
    scanned = _journal_records(repo)
    if scanned is None:
        return _fail("think-pointer-journal-unread",
                     "think waiting_gate: the transition journal could not be read (fail closed)")
    entries, RP = scanned
    try:
        ptr_num = int(_gate_key(pointer))
    except (TypeError, ValueError):
        return _fail("think-pointer-ref", "refs.pointer must be a pointer issue number")
    for e in entries:
        if e.get("op") == "unblock" and RP.journal_item_id(e) == ptr_num:
            return _fail("think-pointer-already-admitted",
                         f"think waiting_gate: pointer #{ptr_num} is ALREADY admitted (an unblock record "
                         "names it) — an admitted pointer is not a wait; close as complete instead")
    return CloseoutResult(True, "ok", "pointer still blocked (waiting)", {})


def _remaining_admitted_considerations(repo: str):
    """The set of admitted considerations STILL awaiting Plan (Consideration/Todo non-gate issues), via
    the shared oracle reader — or None when the tracker cannot be read (fail closed). This is the
    independent 'required admitted set' derivation (wave-3 finding 3): if Plan claims `complete` while
    one admitted consideration was never planned, that consideration is still on this lane."""
    if not _ne_str(repo):
        return None
    try:
        import idc_next_action as NEXT  # noqa: E402 — lazy (reuses the oracle's tracker read)
        state, _ = NEXT._collect_workflow_state(os.path.realpath(os.path.abspath(repo)))
        return {_gate_key(n) for n in state.considerations}
    except Exception:  # noqa: BLE001 — any tracker read failure fails Plan complete closed
        return None


# The durable manifest dispositions a PROCESSED intake unit may carry (never `queued` = unprocessed).
_MANIFEST_PROCESSED = {"materialized", "verified_done", "ignored"}


def _manifest_unit_processed(repo: str, manifest_rel: object, unit: str, claimed: object) -> CloseoutResult:
    """Re-check a recirculate-requested intake unit against durable manifest state: the unit exists in
    the referenced manifest, its disposition is a PROCESSED state (not `queued`), AND the caller's
    CLAIMED disposition EQUALS the durable manifest disposition (wave-4 finding 4 — manifest-state
    equality, not merely non-queued). Never trusts the caller's disposition string as ground truth."""
    path = _confined_repo_path(repo, manifest_rel)
    if path is None or not os.path.isfile(path):
        return _fail("recirc-unit-bad-manifest",
                     f"recirculate requested unit references manifest {manifest_rel!r} which is not a "
                     "repo-relative manifest path")
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        units = {u["id"]: u for u in manifest["units"]} if isinstance(manifest, dict) else {}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return _fail("recirc-unit-manifest-invalid", f"the referenced manifest is unreadable: {exc}")
    u = units.get(unit)
    if not isinstance(u, dict):
        return _fail("recirc-unit-absent", f"requested unit {unit!r} is not in manifest {manifest_rel!r}")
    state = (u.get("disposition") or {}).get("state")
    if state not in _MANIFEST_PROCESSED:
        return _fail("recirc-unit-unprocessed",
                     f"requested unit {unit!r} is {state!r} in the manifest — recirculate cannot claim it "
                     f"closed until it was processed into a durable route (one of {sorted(_MANIFEST_PROCESSED)})")
    if claimed != state:
        return _fail("recirc-unit-disposition-mismatch",
                     f"recirculate claims disposition {claimed!r} for unit {unit!r} but the durable "
                     f"manifest disposition is {state!r} — the claimed disposition must EQUAL the durable one")
    return CloseoutResult(True, "ok", f"requested unit {unit} processed (state {state})", {})


# The claimed bare-#ticket dispositions that are TERMINAL (the ticket was processed + closed → the
# board must read Done) vs NON-TERMINAL (paused/gated behind its own gate → the ticket is still open).
_RECIRC_TERMINAL_DISPOSITIONS = {"admitted", "drained", "materialized"}
_RECIRC_OPEN_DISPOSITIONS = {"gated", "paused"}
# The Stage a recirc inbox ticket carries, and the ONE guarded recirc-retirement journal disposition
# (idc_transition's `dispose --disposition drained` door). Round-5 finding 3: a bare ticket that
# legitimately reached Done as a recirc item did so THROUGH that door, which the journal records — the
# only durable evidence that distinguishes a real retirement from a raw-closed Done.
_RECIRC_STAGE = "Recirculation"
_RECIRC_RETIREMENT_DISPOSITION = "drained"
_JOURNAL_UNREADABLE = object()  # sentinel: the journal could not be read (rule B → refuse, never None-pass)


def _ticket_dispose_disposition(repo: str, ticket: object):
    """How ticket `ticket` reached its terminal state, re-derived from the transition journal: the
    `disposition` of the guarded `dispose` record naming it, or None when no `dispose` record names it
    (a raw-closed Done). Returns the `_JOURNAL_UNREADABLE` sentinel when the journal cannot be read — an
    unreadable truth is a refusal (rule B), never a silent None-pass."""
    scanned = _journal_records(repo)
    if scanned is None:
        return _JOURNAL_UNREADABLE
    entries, RP = scanned
    try:
        tnum = int(_gate_key(ticket))
    except (TypeError, ValueError):
        return None
    for e in entries:
        if e.get("op") == "dispose" and RP.journal_item_id(e) == tnum:
            return e.get("disposition")
    return None


def _ticket_board_consistent(repo: str, ticket: object, claimed: object) -> CloseoutResult:
    """Per-ticket re-derivation from DURABLE evidence (round-5 finding 3): a bare `#<ticket>` requested
    item is re-read against the board Stage AND Status PLUS the transition journal (how it reached its
    state). A non-terminal disposition (gated/paused) requires the ticket still open (not Done). A
    terminal disposition requires the ticket Done AND a guarded `dispose disposition=drained` journal
    record with the ticket still a `Recirculation`-stage item — the ONE recirc-retirement door. Because
    that door is the only durably-distinguishable terminal, only `drained` is claimable on a bare Done
    ticket; `admitted`/`materialized` cannot be told apart from a plain drained retirement, so a
    mismatched terminal disposition is refused. A ticket absent from the board, an unreadable journal,
    or a raw-closed Done (no dispose/drained record) all fail closed (rule B)."""
    stage, status = _issue_stage_status(repo, ticket)
    if status is None:
        return _fail("recirc-ticket-board-missing",
                     f"recirculate requested ticket {ticket!r} could not be read from the CURRENT board "
                     "(a nonexistent/unreadable ticket fails closed)")
    if claimed in _RECIRC_OPEN_DISPOSITIONS:
        if status == "Done":
            return _fail("recirc-ticket-not-open",
                         f"recirculate claims disposition {claimed!r} (paused/gated) for ticket {ticket!r} "
                         "but the board reads Done — a paused/gated ticket must still be open")
        return CloseoutResult(True, "ok", f"ticket {ticket} still open (consistent with {claimed})", {})
    # A terminal disposition: the board must read Done AND the guarded recirc-retirement door must have
    # journaled it (proving how it reached Done — never a raw-closed Done, never a caller assertion).
    if status != "Done":
        return _fail("recirc-ticket-not-terminal",
                     f"recirculate claims a terminal disposition {claimed!r} for ticket {ticket!r} but the "
                     f"board reads status {status!r}, not Done — a processed ticket must be closed")
    disposition = _ticket_dispose_disposition(repo, ticket)
    if disposition is _JOURNAL_UNREADABLE:
        return _fail("recirc-ticket-journal-unread",
                     f"recirculate: the transition journal could not be read to re-derive how ticket "
                     f"{ticket!r} reached Done — an unreadable truth is a refusal (rule B)")
    if disposition != _RECIRC_RETIREMENT_DISPOSITION:
        return _fail("recirc-ticket-unproven-retirement",
                     f"recirculate claims a terminal disposition {claimed!r} for ticket {ticket!r} but no "
                     "guarded `dispose disposition=drained` journal record proves it reached Done through "
                     f"the recirc-retirement door (the journal records {disposition!r}) — a raw-closed Done "
                     "is not a proven retirement (rule B)")
    if stage != _RECIRC_STAGE:
        return _fail("recirc-ticket-not-recirc-stage",
                     f"recirculate ticket {ticket!r} reads Stage {stage!r}, not {_RECIRC_STAGE!r} — a "
                     "drained recirc ticket stays a Recirculation-stage Done item")
    if claimed != _RECIRC_RETIREMENT_DISPOSITION:
        return _fail("recirc-ticket-disposition-indistinguishable",
                     f"recirculate claims disposition {claimed!r} for ticket {ticket!r}, but the durable "
                     "evidence (a guarded `dispose disposition=drained` retirement) proves only `drained` "
                     "— admitted/materialized cannot be distinguished from a plain drained retirement on a "
                     "bare Done ticket, so a mismatched terminal disposition is refused (rule B)")
    return CloseoutResult(True, "ok", f"ticket {ticket} drained (journal-corroborated Recirculation Done)", {})


_RECEIPT_RELPATH = "docs/workflow/install-receipt.yaml"


def _receipt_document(repo: str, receipt_rel: object = None):
    """Parse the repo's install receipt (idc_receipt_check) → (top-metadata, entries), or None on any
    read/parse failure (fail closed). `receipt_rel` defaults to the canonical install-receipt path."""
    rel = receipt_rel if _ne_str(receipt_rel) else _RECEIPT_RELPATH
    path = _confined_repo_path(repo, rel)
    if path is None or not os.path.isfile(path):
        return None
    try:
        import idc_receipt_check as RC  # noqa: E402 — lazy
        return RC.parse_receipt_document(path)
    except Exception:  # noqa: BLE001 — an invalid receipt fails the closeout closed (never trusted)
        return None


def _receipt_fingerprints_ok(repo: str, receipt_rel: object) -> CloseoutResult:
    """RUN the real receipt FINGERPRINT verification (idc_receipt_check.verify_receipt_fingerprints —
    not a syntax parse): every stamped file's current on-disk bytes must match its recorded SHA-256
    (wave-4 finding 7). A modified or missing stamped file — or an invalid/unreadable receipt — fails
    the closeout closed. This is what proves the scaffold actually landed intact, which the old
    version/syntax parse never checked."""
    rel = receipt_rel if _ne_str(receipt_rel) else _RECEIPT_RELPATH
    path = _confined_repo_path(repo, rel)
    if path is None or not os.path.isfile(path):
        return _fail("receipt-fingerprint-bad-ref",
                     "the install receipt could not be resolved to run the fingerprint verification")
    try:
        import idc_receipt_check as RC  # noqa: E402 — lazy
        ok, counts = RC.verify_receipt_fingerprints(repo, path)
    except SystemExit as exc:  # parse_receipt_document dies (invalid receipt) with SystemExit
        return _fail("receipt-fingerprint-invalid",
                     f"the install receipt is invalid, so the fingerprint check could not run ({exc})")
    except Exception as exc:  # noqa: BLE001 — any verification failure fails closed
        return _fail("receipt-fingerprint-error", f"the receipt fingerprint verification failed: {exc}")
    if not ok:
        return _fail("receipt-fingerprint-mismatch",
                     f"the receipt fingerprint verification found drift ({counts['modified']} modified, "
                     f"{counts['missing']} missing) — the scaffold is not intact at the stamped version")
    return CloseoutResult(True, "ok", "receipt fingerprints verify (scaffold intact)", {})


def _running_plugin_version():
    """The RUNNING plugin's version, read live from THIS plugin's own `.claude-plugin/plugin.json` (the
    plugin root is the parent of scripts/) — the ground truth /idc:update's 'running version equals the
    receipt version' check compares against, never a caller-typed version."""
    manifest = os.path.join(os.path.dirname(_HERE), ".claude-plugin", "plugin.json")
    try:
        with open(manifest, encoding="utf-8") as handle:
            data = json.load(handle)
        version = data.get("version")
        return version if _ne_str(version) else None
    except (OSError, ValueError, AttributeError):
        return None


def _check_intake_coverage(repo: str, manifest_rel: object, selected: object) -> CloseoutResult:
    """Re-read the referenced intake manifest from durable state and confirm the WHOLE manifest is
    honestly accounted for: every SELECTED unit is `materialized`, and every OTHER expected unit sits
    in a valid durable disposition. Reading the manifest (not trusting a caller flag) is what blocks a
    closeout that materializes one unit but drops the rest of the exact-once set."""
    path = _confined_repo_path(repo, manifest_rel)
    if path is None or not os.path.isfile(path):
        return _fail("intake-coverage-bad-ref",
                     "refs.intake_manifest must be a repo-relative path to the consumed manifest")
    if not isinstance(selected, list) or not selected or any(not _ne_str(s) for s in selected):
        return _fail("intake-coverage-bad-selected",
                     "refs.intake_selected must be a non-empty list of unit ids")
    try:
        import idc_intake_manifest as INTAKE  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        if not isinstance(manifest, dict):
            raise INTAKE.IntakeError("manifest must be a JSON object")
        INTAKE.validate_manifest(manifest)          # exact-once — a dropped unit fails HERE
        INTAKE._resolve_stamped_review(path, manifest)  # requires an independent PASS review
    except Exception as exc:  # noqa: BLE001 — any invalid manifest/review blocks the closeout
        return _fail("intake-coverage-invalid", f"consumed intake manifest is not valid: {exc}")

    expected = set(manifest["expected_unit_ids"])
    selected_set = set(selected)
    if not selected_set <= expected:
        return _fail("intake-coverage-unknown-unit",
                     "refs.intake_selected names units absent from the manifest expected set")
    by_id = {unit["id"]: unit for unit in manifest["units"]}
    for unit_id in expected:
        state = by_id[unit_id]["disposition"]["state"]
        if unit_id in selected_set:
            if state != "materialized":
                return _fail("intake-coverage-unmaterialized",
                             f"selected intake unit {unit_id} is not materialized (state {state!r})")
        elif state not in _DURABLE_DISPOSITIONS:
            return _fail("intake-coverage-remainder",
                         f"unselected expected unit {unit_id} lacks a durable disposition (state {state!r})")
    return CloseoutResult(True, "ok", "intake coverage is complete", {})


def _claim_intake_manifest_reviewed(refs: dict, repo: str, session: str) -> CloseoutResult:
    # An intake COMPILATION legitimately leaves every unit queued (nothing materialized yet), so this
    # demands a VALID independently-reviewed manifest (re-validated durable artifact), not materialization.
    if not _present(refs.get("manifest")) or not _ne_str(refs.get("review")):
        return _fail("intake-refs", "intake complete needs refs.manifest and refs.review")
    return _valid_reviewed_manifest(repo, refs.get("manifest"))


def _claim_intake_pr_merged(refs: dict, repo: str, session: str) -> CloseoutResult:
    # The intake PR merged-state is a GitHub claim — RE-READ it (real `gh pr view`, the shared
    # _gh_pr_merged path), never a caller `intake_pr_state:"MERGED"` (wave-3 finding 6).
    if not _present(refs.get("intake_pr")):
        return _fail("intake-pr-ref", "intake complete requires refs.intake_pr (the operational intake PR number)")
    merged = _gh_pr_merged(repo, refs.get("intake_pr"))
    if merged is None:
        return _fail("intake-pr-unverified",
                     "intake complete: the intake PR merged-state could not be verified by a real gh read "
                     "(a caller state is never trusted) — fail closed")
    if not merged:
        return _fail("intake-pr-unmerged", "intake complete requires the intake PR MERGED (real gh read)")
    return CloseoutResult(True, "ok", "intake PR merged (real gh read)", {})


def _valid_reviewed_manifest(repo: str, manifest_rel: object) -> CloseoutResult:
    path = _confined_repo_path(repo, manifest_rel)
    if path is None or not os.path.isfile(path):
        return _fail("intake-bad-ref", "refs.manifest must be a repo-relative path to the manifest")
    try:
        import idc_intake_manifest as INTAKE  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        if not isinstance(manifest, dict):
            raise INTAKE.IntakeError("manifest must be a JSON object")
        INTAKE.validate_manifest(manifest)
        INTAKE._resolve_stamped_review(path, manifest)
    except Exception as exc:  # noqa: BLE001
        return _fail("intake-invalid", f"intake manifest is not independently reviewed/valid: {exc}")
    return CloseoutResult(True, "ok", "manifest reviewed + valid", {})


def _think_record_intake(repo: str, session: str):
    """The intake manifest + selected units recorded on THIS session's ACTIVE think record at start
    (finding 2), or (None, None). This is the DURABLE source of intake mode: a finish that omits the
    intake fields can no longer make an intake-mode run look non-intake and slip a dropped-unit close
    past coverage. Read tolerantly — any read failure yields (None, None) and the finish falls back to
    the caller-supplied ref (belt-and-suspenders for a runtime with no record readback)."""
    if not _ne_str(repo) or not _ne_str(session):
        return None, None
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "think" and rec.get("intake_manifest"):
                return rec.get("intake_manifest"), rec.get("intake_units") or []
    except Exception:  # noqa: BLE001 — a ledger read failure must not brick the closeout
        return None, None
    return None, None


def _claim_think_refs_present(refs: dict, repo: str, session: str) -> CloseoutResult:
    if not _present(refs.get("think_pr")) or not _present(refs.get("gate")) \
            or not _present(refs.get("pointer")):
        return _fail("think-refs", "think closeout needs refs.think_pr, refs.gate, refs.pointer (reference keys)")
    return CloseoutResult(True, "ok", "think reference keys present", {})


def _claim_think_consideration(refs: dict, repo: str, session: str) -> CloseoutResult:
    # RE-RUN the consideration checker on the referenced file — never a caller `consideration:"pass"`.
    return _run_consideration_check(repo, refs.get("consideration"))


def _claim_think_intake_coverage(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Intake coverage is enforced from the DURABLE record on EVERY closeout path (finding 2). If the
    # active record says this run is intake-mode (started with --doc/--unit), coverage is MANDATORY and
    # re-read from the RECORDED manifest + selected units — a finish that omits the intake fields cannot
    # bypass it. Only when no record marker exists do we fall back to a caller-supplied intake ref
    # (still verified, never trusted). A non-intake run has neither → nothing to cover (pass).
    rec_manifest, rec_units = _think_record_intake(repo, session)
    if rec_manifest is not None:
        return _check_intake_coverage(repo, rec_manifest, rec_units)
    if refs.get("intake_manifest") is not None:
        return _check_intake_coverage(repo, refs.get("intake_manifest"), refs.get("intake_selected"))
    return CloseoutResult(True, "ok", "no intake coverage obligation on this run", {})


def _claim_think_pr_merged(refs: dict, repo: str, session: str) -> CloseoutResult:
    # The Think PR merged-state is a GitHub claim — RE-READ it (real gh, never a caller state:"MERGED").
    merged = _gh_pr_merged(repo, refs.get("think_pr"))
    if merged is None:
        return _fail("think-pr-unverified",
                     "think complete: the Think PR merged-state could not be verified by a real gh read "
                     "(a caller state is never trusted) — fail closed")
    if not merged:
        return _fail("think-pr-unmerged", "think complete requires the Think PR MERGED (real gh read)")
    return CloseoutResult(True, "ok", "Think PR merged (real gh read)", {})


def _claim_think_pr_open(refs: dict, repo: str, session: str) -> CloseoutResult:
    # waiting_gate: the Think PR must READ exactly OPEN (wave-4 finding 2). The real PR-state enum
    # distinguishes CLOSED (a dead, operator-abandoned gate — NOT a valid wait) from OPEN (a live gate
    # pending admission); the old boolean collapsed both to "not merged" and let a CLOSED-unmerged PR
    # satisfy waiting_gate. A nonexistent/unreadable PR fails closed.
    state = _gh_pr_state(repo, refs.get("think_pr"))
    if state is None:
        return _fail("think-pr-unverified",
                     "think waiting_gate: the Think PR could not be read (a nonexistent/unreadable PR "
                     "fails closed) — the OPEN state is re-derived, never a caller string")
    if state == "MERGED":
        return _fail("think-pr-merged",
                     "think waiting_gate: the Think PR reads MERGED — a merged PR is not a wait; close as "
                     "complete instead")
    if state == "CLOSED":
        return _fail("think-pr-dead-gate",
                     "think waiting_gate: the Think PR reads CLOSED (unmerged) — a dead gate is "
                     "operator-attention, not a valid wait; it must be OPEN to wait behind it")
    return CloseoutResult(True, "ok", "Think PR open (real gh read)", {})


def _claim_think_gate_marker(refs: dict, repo: str, session: str) -> CloseoutResult:
    return _gate_marker_bound(repo, refs.get("gate"), refs.get("think_pr"))


def _claim_think_gate_disposed(refs: dict, repo: str, session: str) -> CloseoutResult:
    return _gate_disposed(repo, refs.get("gate"))


def _claim_think_gate_not_disposed(refs: dict, repo: str, session: str) -> CloseoutResult:
    # waiting_gate: re-derive from CURRENT board state (wave-4 finding 2) — the referenced gate is on
    # the board and still OPEN (status != Done), not merely journal-absence. A manually-closed gate
    # (Done on the board with no journal record) is no longer a valid wait; a gate absent from the
    # board fails closed. The journal-absence check stays as an additional guard.
    status = _issue_status(repo, refs.get("gate"))
    if status is None:
        return _fail("think-gate-board-missing",
                     "think waiting_gate: the referenced gate could not be read from the CURRENT board "
                     "(a nonexistent/unreadable gate fails closed) — a wait requires a live, open gate")
    if status == "Done":
        return _fail("think-gate-board-closed",
                     "think waiting_gate: the referenced gate reads Done on the board — a closed gate is "
                     "not a wait; close as complete instead")
    return _gate_not_disposed(repo, refs.get("gate"))


def _claim_think_pointer_admitted(refs: dict, repo: str, session: str) -> CloseoutResult:
    return _pointer_admitted(repo, refs.get("pointer"))


def _claim_think_pointer_blocked(refs: dict, repo: str, session: str) -> CloseoutResult:
    # waiting_gate: re-derive from CURRENT board state (wave-4 finding 2) — the pointer is genuinely
    # Blocked on the board, not merely un-admitted in the journal. A manually-advanced pointer (Todo on
    # the board with no unblock record) is no longer a valid wait; a pointer absent from the board fails
    # closed. The journal-absence check stays as an additional guard.
    status = _issue_status(repo, refs.get("pointer"))
    if status is None:
        return _fail("think-pointer-board-missing",
                     "think waiting_gate: the consideration pointer could not be read from the CURRENT "
                     "board (a nonexistent/unreadable pointer fails closed)")
    if status != "Blocked":
        return _fail("think-pointer-board-unblocked",
                     f"think waiting_gate: the consideration pointer reads {status!r} on the board, not "
                     "Blocked — a pointer already advanced past its gate is not a wait")
    return _pointer_blocked(repo, refs.get("pointer"))


def _valid_matrix(repo: str, matrix_rel: object) -> CloseoutResult:
    """Re-validate the referenced deconfliction matrix — a DURABLE repo artifact Plan wrote — through
    idc_matrix_check, rather than trusting a caller `matrix: "pass"` string. A missing file or a matrix
    that fails deconfliction (e.g. same-wave pillars sharing a surface) fails the closeout closed."""
    path = _confined_repo_path(repo, matrix_rel)
    if path is None or not os.path.isfile(path):
        return _fail("plan-matrix-bad-ref",
                     "refs.matrix must be a repo-relative path to the deconfliction matrix Plan wrote")
    try:
        import idc_matrix_check as MX  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            problems = MX.check(handle.read())
    except Exception as exc:  # noqa: BLE001 — an unreadable/unparseable matrix blocks the closeout
        return _fail("plan-matrix-invalid", f"the referenced matrix could not be validated: {exc}")
    if problems:
        return _fail("plan-matrix-fail", f"the referenced matrix fails deconfliction: {problems[0]}")
    return CloseoutResult(True, "ok", "matrix re-validated", {})


def _verify_decomposition(repo: str, matrix_rel: object, children: list) -> CloseoutResult:
    """Re-verify Plan's decomposition CHILDREN from durable state (round-2 F2). On the github backend
    the children are live issues: RE-RUN the shipped schema check on each child's live body AND
    re-derive its `idc-provenance` marker against the matrix Plan authored (both are github-only by
    the shipped helpers' own design) — a missing child, a schema-invalid body, or an absent/mismatched
    provenance marker fails closed. On the filesystem backend (no issue bodies) the children are
    verified to EXIST via the shared tracker reader. Either way a caller can no longer assert
    'children exist / schema+provenance pass' — the validator re-derives it."""
    backend = _repo_backend(repo)
    if backend == "github":
        matrix_path = _confined_repo_path(repo, matrix_rel)
        if matrix_path is None or not os.path.isfile(matrix_path):
            return _fail("plan-matrix-bad-ref", "plan complete requires a repo-relative matrix path")
        try:
            import idc_matrix_check as MX  # noqa: E402
            import idc_schema_check as SCHEMA  # noqa: E402
            import idc_recirc_sweep as SWEEP  # noqa: E402
            with open(matrix_path, encoding="utf-8") as handle:
                pillar_ids = {p["id"] for p in MX.parse_matrix(handle.read()) if p.get("id")}
        except Exception as exc:  # noqa: BLE001
            return _fail("plan-matrix-invalid", f"could not load the matrix pillar ids: {exc}")
        matrix_name = os.path.basename(str(matrix_rel))
        for child in children:
            body = _gh_issue_body(repo, child)
            if body is None:
                return _fail("plan-child-missing",
                             f"decomposition child #{child} could not be read from the board (fail closed)")
            problems = SCHEMA.check(body)
            if problems:
                return _fail("plan-child-schema",
                             f"decomposition child #{child} fails the issue-body schema check: {problems[0]}")
            prov = SWEEP.provenance_of(body)
            if not prov or prov.get("matrix") != matrix_name or prov.get("pillar") not in pillar_ids:
                return _fail("plan-child-provenance",
                             f"decomposition child #{child} lacks a valid idc-provenance marker for "
                             f"the authored matrix (re-run provenance check)")
        return CloseoutResult(True, "ok", "decomposition children re-verified (schema + provenance)", {})
    # filesystem: no issue bodies to schema/provenance-check — verify the children EXIST on the board.
    numbers = _load_issue_numbers(repo)
    if numbers is None:
        return _fail("plan-children-unreadable",
                     "plan complete could not read the tracker to verify decomposition children (fail closed)")
    missing = sorted(_gate_key(c) for c in children if _gate_key(c) not in numbers)
    if missing:
        return _fail("plan-child-missing",
                     f"decomposition children not present in the tracker: {', '.join('#' + m for m in missing)}")
    return CloseoutResult(True, "ok", "decomposition children exist on the tracker", {})


def _claim_plan_no_action(refs: dict, repo: str, session: str) -> CloseoutResult:
    return _check_no_action("plan", repo)


def _claim_plan_matrix(refs: dict, repo: str, session: str) -> CloseoutResult:
    # The deconfliction matrix is a DURABLE artifact — re-validate the referenced file (never a caller "pass").
    return _valid_matrix(repo, refs.get("matrix"))


def _claim_plan_pr_merged(refs: dict, repo: str, session: str) -> CloseoutResult:
    merged = _gh_pr_merged(repo, refs.get("planning_pr"))
    if merged is None:
        return _fail("plan-pr-unverified",
                     "plan complete: the planning PR merged-state could not be verified by a real gh "
                     "read (a caller state is never trusted) — fail closed")
    if not merged:
        return _fail("plan-pr-unmerged", "plan complete requires the planning PR MERGED (real gh read)")
    return CloseoutResult(True, "ok", "planning PR merged (real gh read)", {})


def _claim_plan_decomposition(refs: dict, repo: str, session: str) -> CloseoutResult:
    decompositions = refs.get("decompositions")
    if not isinstance(decompositions, dict) or not decompositions \
            or any(not _present(v) for v in decompositions.values()):
        return _fail("plan-decomposition",
                     "plan complete requires refs.decompositions {consideration: child} (non-empty)")
    # pointers_retired must EQUAL the decomposed set (wave-4 finding 3): every decomposed consideration
    # has its pointer retired AND no EXTRA pointer is retired. `retired == decomposed` — an empty list
    # is valid only when nothing was decomposed, and an extra retired pointer (retiring a consideration
    # that was never decomposed, the retire-then-omit bypass) is refused.
    pointers = refs.get("pointers_retired")
    if not isinstance(pointers, list):
        return _fail("plan-pointers", "plan complete requires refs.pointers_retired (a list)")
    retired = {_gate_key(p) for p in pointers}
    decomposed = {_gate_key(k) for k in decompositions}
    if decomposed - retired:
        missing = sorted(decomposed - retired)
        return _fail("plan-pointers-open",
                     "plan complete requires every decomposed consideration's pointer retired; "
                     f"still-open: {', '.join('#' + m for m in missing)}")
    if retired - decomposed:
        extra = sorted(retired - decomposed)
        return _fail("plan-pointers-extra",
                     "plan complete retired pointer(s) for consideration(s) that were NOT decomposed: "
                     f"{', '.join('#' + m for m in extra)} — retiring a consideration's pointer without "
                     "decomposing it (the retire-then-omit bypass) drops its child obligation; retired "
                     "must EQUAL the decomposed set")
    # ROUND-5 F2: each claimed-retired pointer's retirement is proven by reading its LIVE board status
    # (genuinely retired = Done), NEVER by comparing two caller-supplied maps. A pointer moved to Blocked
    # (or still Todo) but claimed retired is refused; an unreadable pointer status is a refusal (rule B).
    for p in sorted(retired):
        status = _issue_status(repo, p)
        if status is None:
            return _fail("plan-pointer-status-unread",
                         f"plan complete: pointer #{p}'s live board status could not be read to confirm it "
                         "is genuinely retired — an unreadable pointer status is a refusal (rule B), not a pass")
        if status != "Done":
            return _fail("plan-pointer-not-retired",
                         f"plan complete claims pointer #{p} retired but its LIVE board status is {status!r}, "
                         "not Done — a pointer moved to Blocked/Todo is not genuinely retired (comparing two "
                         "caller-supplied maps is not proof of retirement)")
    # Re-verify the decomposition children (existence + schema + provenance) from durable state.
    return _verify_decomposition(repo, refs.get("matrix"), list(decompositions.values()))


def _plan_record_admitted(repo: str, session: str):
    """The admitted-consideration set STAMPED on THIS session's ACTIVE plan record at start (rule A,
    wave-4 finding 3), or None when no stamp exists. Captured at start so a consideration the plan
    itself RETIRES stays in the required set — a retire-then-omit that drops it off the live board
    cannot make the obligation disappear. Read tolerantly (any failure → None)."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "plan" and rec.get("plan_admitted") is not None:
                return {_gate_key(p) for p in (rec.get("plan_admitted") or [])}
    except Exception:  # noqa: BLE001 — a ledger read failure falls back to the live derivation
        return None
    return None


def _claim_plan_admitted_set_covered(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Two independent checks re-derive plan completeness (wave-4 finding 3), never the caller's keys:
    #   (1) NO admitted consideration may still be on the board (live Consideration/Todo) — one still
    #       there was never acted on (the old check; also catches a consideration ADDED after start).
    #   (2) EVERY consideration admitted AT START (the rule-A stamp) must be decomposed — a
    #       retire-then-omit that moves a consideration off the board without decomposing it (its
    #       pointer retired but no child planned) is caught by the stamp, which remembers it.
    # ROUND-5 F2 (rule B): the LIVE board read must SUCCEED — an unreadable board is a refusal, never a
    # pass, and the start stamp ALONE never suffices. (Wave-4 proceeded on a stamp when the live read
    # failed; that let a github plan claim completeness with the board unavailable.)
    live = _remaining_admitted_considerations(repo)
    if live is None:
        return _fail("plan-admitted-live-unread",
                     "plan complete: the live board could not be read to confirm no admitted consideration "
                     "remains — an unreadable truth is a refusal (rule B); the start stamp alone never "
                     "suffices to prove completeness")
    stamped = _plan_record_admitted(repo, session)
    if live:
        return _fail("plan-admitted-remaining",
                     "plan complete rejected — the tracker still shows admitted consideration(s) not "
                     f"acted on: {', '.join('#' + n for n in sorted(live))} (plan + retire every one)")
    decompositions = refs.get("decompositions")
    decomposed = {_gate_key(k) for k in decompositions} if isinstance(decompositions, dict) else set()
    uncovered = set(stamped or set()) - decomposed
    if uncovered:
        return _fail("plan-admitted-retired-not-decomposed",
                     "plan complete rejected — consideration(s) admitted at start were retired off the "
                     f"board but NOT decomposed: {', '.join('#' + n for n in sorted(uncovered))} (the "
                     "retire-then-omit bypass drops their child obligations; decompose EVERY one)")
    return CloseoutResult(True, "ok", "every admitted consideration acted on + decomposed (re-derived)", {})


def _reconciliation_verdict(repo: str, session: str):
    """RE-DERIVE the recirculation reconciliation verdict from durable state by RE-RUNNING the
    deterministic reconciliation READ-ONLY (round-2 F5-r2) — never a caller `reconciliation:"ran"`
    string. Forces `IDC_HOOKS_OBSERVE_ONLY=1` so the re-run is a pure dry run (no board comment, no
    ledger taint) that still reads the inbox/board and returns the same verdict the drain would. A
    nonexistent/ungoverned/unreadable repo yields `ungoverned`/`unknown` → None (fail-closed). Returns
    the verdict string only when it is a settled `reconciled`/`complete`, else None."""
    if not _ne_str(repo):
        return None
    prev = os.environ.get("IDC_HOOKS_OBSERVE_ONLY")
    try:
        import idc_recirc_reconcile as RC  # noqa: E402 — lazy
        import idc_recirc_closeout_gate as RG  # noqa: E402 — for its backend reader
        os.environ["IDC_HOOKS_OBSERVE_ONLY"] = "1"   # force a side-effect-free re-run
        backend = RG._read_backend(repo) or "filesystem"
        verdict = RC.reconcile(repo, backend, session or None)[0]
    except Exception:  # noqa: BLE001 — any reconciliation failure fails the closeout closed
        return None
    finally:
        if prev is None:
            os.environ.pop("IDC_HOOKS_OBSERVE_ONLY", None)
        else:
            os.environ["IDC_HOOKS_OBSERVE_ONLY"] = prev
    return verdict if verdict in ("reconciled", "complete") else None


# The CLOSED recirculation disposition vocabulary — exactly the documented values (commands/recirculate.md;
# wave-3 finding 4: the prose and the validator MUST agree). Any other string (the old test's
# undocumented "absorbed") is refused.
_RECIRC_DISPOSITIONS = {"admitted", "drained", "gated", "paused", "materialized"}


def _recirc_requested_from_record(repo: str, session: str):
    """The recirculate requested-item set recorded on THIS session's ACTIVE recirculate record at
    start (from a `<manifest>#<unit>` / `#<ticket>` invocation), or []. The DURABLE source of the
    requested set (finding 4) — a finish that omits a requested item cannot make it disappear. Read
    tolerantly (any failure → [])."""
    if not _ne_str(repo) or not _ne_str(session):
        return []
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "recirculate" and rec.get("recirc_requested"):
                return list(rec.get("recirc_requested") or [])
    except Exception:  # noqa: BLE001
        return []
    return []


def _claim_recirc_gate(refs: dict, repo: str, session: str) -> CloseoutResult:
    # waiting_gate: the referenced gate must be REAL and still blocking (wave-4 finding 4) — a nonempty
    # ref is not proof. A Think PR ref reads OPEN (real gh); a gate issue ref reads present + not Done
    # on the CURRENT board. A nonexistent/closed/merged gate fails closed (a dead gate is not a wait).
    gate = refs.get("gate")
    if not _present(gate):
        return _fail("recirc-gate", "recirculate waiting_gate requires a valid requirements gate/Think PR ref")
    think_pr = refs.get("think_pr")
    if _present(think_pr):
        state = _gh_pr_state(repo, think_pr)
        if state is None:
            return _fail("recirc-gate-pr-unread",
                         "recirculate waiting_gate: the requirements Think PR could not be read (fail closed)")
        if state != "OPEN":
            return _fail("recirc-gate-pr-not-open",
                         f"recirculate waiting_gate: the requirements Think PR reads {state} — a "
                         "merged/closed PR is not a wait")
        return CloseoutResult(True, "ok", "recirculation waiting on an open requirements Think PR", {})
    status = _issue_status(repo, gate)
    if status is None:
        return _fail("recirc-gate-board-missing",
                     "recirculate waiting_gate: the requirements gate could not be read from the CURRENT "
                     "board (a nonexistent/unreadable gate fails closed)")
    if status == "Done":
        return _fail("recirc-gate-board-closed",
                     "recirculate waiting_gate: the requirements gate reads Done on the board — a closed "
                     "gate is not a wait")
    return CloseoutResult(True, "ok", "recirculation waiting on the open requirements gate", {})


def _claim_recirc_reconciled(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Reconciliation is RE-DERIVED from durable state (a read-only re-run of the deterministic
    # reconciliation — never a caller `reconciliation:"ran"` string). A nonexistent/unreadable repo
    # fails closed.
    if _reconciliation_verdict(repo, session) is None:
        return _fail("recirc-reconcile",
                     "recirculate complete requires the reconciliation to RE-DERIVE as "
                     "reconciled/complete from durable state (a read-only re-run) — a caller "
                     "'reconciliation:\"ran\"' is not proof, and a nonexistent/unreadable repo fails closed")
    return CloseoutResult(True, "ok", "reconciliation re-derived reconciled/complete", {})


def _is_manifest_unit_ref(ref: str) -> bool:
    """A `<manifest>#<unit>` intake-recirc token (a path with a `#unit` suffix), vs a bare `#<ticket>`."""
    return "#" in ref and not ref.lstrip().startswith("#")


def _claim_recirc_closeouts(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Every closeout disposition must be in the CLOSED documented vocabulary (a manifest unit carries a
    # durable manifest disposition; a bare ticket carries a recirc-board disposition), and EVERY
    # requested item (re-derived from the durable start record) must carry a validated closeout whose
    # disposition is RE-CHECKED against durable state (wave-4 finding 4): a `<manifest>#<unit>` closeout
    # must EQUAL the manifest disposition, a bare `#<ticket>` closeout must be board-consistent.
    # `closeouts:{}` passes only when the re-derived requested set is empty (a bare full-inbox drain).
    closeouts = refs.get("closeouts")
    if not isinstance(closeouts, dict):
        return _fail("recirc-closeouts", "recirculate complete requires refs.closeouts {ticket/unit: disposition}")
    for item, disp in closeouts.items():
        vocab = _MANIFEST_PROCESSED if _is_manifest_unit_ref(str(item)) else _RECIRC_DISPOSITIONS
        if disp not in vocab:
            return _fail("recirc-disposition-vocab",
                         f"recirculate closeout for {item!r} has disposition {disp!r} — not one of the "
                         f"documented dispositions {sorted(vocab)}")
    requested = _recirc_requested_from_record(repo, session)
    if not requested:
        # No named requested items (a bare full-inbox drain) — reconciliation already proved the inbox
        # settled; any recorded closeouts are vocabulary-checked above. `closeouts:{}` is valid here.
        return CloseoutResult(True, "ok", "recirculation inbox drained + reconciled (no named items)", {})
    for ref in requested:
        if ref not in closeouts:
            return _fail("recirc-requested-uncovered",
                         f"recirculate complete: requested item {ref!r} has no closeout — every requested "
                         "item needs a validated closeout (a full-inbox drain claim cannot silently drop it)")
        disp = closeouts[ref]
        if _is_manifest_unit_ref(ref):
            manifest_rel, unit = ref.rsplit("#", 1)
            check = _manifest_unit_processed(repo, manifest_rel, unit, disp)
        else:
            check = _ticket_board_consistent(repo, ref, disp)
        if not check.ok:
            return check
    return CloseoutResult(True, "ok", "every requested recirc item processed + reconciled (re-derived)", {})


def _valid_build_receipt(issue: object, receipt: object, repo: str) -> CloseoutResult:
    """A build receipt references a merged PR by NUMBER — `{pr: <n>}` — and the validator RE-READS the
    PR's merged-state for real (`gh pr view`), never trusting a caller `state:"MERGED"` (round-2 F1).
    It ALSO proves the PR↔issue linkage from the PR's OWN closing references (wave-4 finding 5), never
    receipt adjacency — a merged PR that does not close THIS issue fails the receipt closed. A
    merged-state that cannot be proven by a real read (gh absent/errored, or the PR reads NOT merged)
    fails closed."""
    if not _present(issue):
        return _fail("build-receipt-issue", "each build receipt must be keyed by a real issue reference")
    if not isinstance(receipt, dict):
        return _fail("build-receipt-shape",
                     f"build receipt for {issue} must be {{pr}} referencing a MERGED PR "
                     f"(an arbitrary receipt string is not proof)")
    pr = receipt.get("pr")
    if not _present(pr):
        return _fail("build-receipt-pr", f"build receipt for {issue} must cite a real PR (refs.receipts.{issue}.pr)")
    merged = _gh_pr_merged(repo, pr)
    if merged is None:
        return _fail("build-receipt-unverified",
                     f"build receipt for {issue}: PR #{pr}'s merged-state could not be verified by a "
                     f"real gh read (a caller state is never trusted) — fail closed")
    if not merged:
        return _fail("build-receipt-unmerged",
                     f"build receipt for {issue}: the real gh read shows PR #{pr} is NOT merged")
    closes = _gh_pr_closes_issue(repo, pr, issue)
    if closes is None:
        return _fail("build-receipt-linkage-unverified",
                     f"build receipt for {issue}: PR #{pr}'s closing references could not be read "
                     "(fail closed) — the PR↔issue linkage is proven from the PR's own closing refs")
    if not closes:
        return _fail("build-receipt-wrong-issue",
                     f"build receipt for {issue}: merged PR #{pr} does NOT close issue #{_gate_key(issue)} "
                     "(its closing references name a different issue) — a receipt cannot borrow an "
                     "unrelated merged PR")
    return CloseoutResult(True, "ok", "receipt ok", {})


def _build_requested_from_record(repo: str, session: str):
    """The build requested-issue set STAMPED on THIS session's ACTIVE build record at start (rule A,
    wave-4 finding 5), or None when no explicit issue set was named (a whole-frontier build). Read
    tolerantly (any failure → None)."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "build" and rec.get("build_requested"):
                return {_gate_key(b) for b in (rec.get("build_requested") or [])}
    except Exception:  # noqa: BLE001
        return None
    return None


def _build_frontier_from_record(repo: str, session: str):
    """The eligible-frontier issue set STAMPED on THIS session's ACTIVE build record at start (rule A,
    round-5 finding 4), or None when no frontier was stamped (an explicit `#issue` build, or the board
    was unreadable at start). A stamped EMPTY set is returned as an empty set (distinct from None). Read
    tolerantly."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "build" and rec.get("build_frontier") is not None:
                return {_gate_key(b) for b in (rec.get("build_frontier") or [])}
    except Exception:  # noqa: BLE001
        return None
    return None


def _claim_build_no_action(refs: dict, repo: str, session: str) -> CloseoutResult:
    return _check_no_action("build", repo)


def _claim_build_receipts(refs: dict, repo: str, session: str) -> CloseoutResult:
    receipts = refs.get("receipts")
    if not isinstance(receipts, dict):
        receipts = {}
    # The REQUIRED issue set is STAMPED at start (rule A, wave-4 finding 5): a `/idc:build #1 #2` run
    # records {1,2}, so `complete` requires ONE verified merged-PR receipt PER requested issue — a
    # request for two issues cannot close with one receipt.
    requested = _build_requested_from_record(repo, session)
    if requested:
        missing = sorted(str(i) for i in requested if _gate_key(i) not in {_gate_key(k) for k in receipts})
        if missing:
            return _fail("build-requested-uncovered",
                         "build complete: requested issue(s) have no merged-PR receipt: "
                         f"{', '.join('#' + m for m in missing)} — every requested issue needs one "
                         "verified merged PR that closes it (a partial close is not complete)")
        for issue in requested:
            key = _gate_key(issue)
            receipt = next((v for k, v in receipts.items() if _gate_key(k) == key), None)
            result = _valid_build_receipt(issue, receipt, repo)
            if not result.ok:
                return result
        return CloseoutResult(True, "ok", "every requested build issue has a linked merged-PR receipt", {})
    # WHOLE-FRONTIER build (round-5 finding 4): no explicit issue set. `complete` requires EITHER a
    # verified merged receipt for EVERY issue stamped in the eligible frontier at start, OR an
    # oracle-confirmed empty remaining frontier (all eligible Buildable work is drained). An
    # arbitrary-subset close — receipts for some frontier issues while others remain eligible — refuses.
    oracle_empty = _check_no_action("build", repo)
    if oracle_empty.ok:
        # nothing eligible remains: either the frontier was empty, or every eligible item was drained.
        # Any receipts supplied are still verified for real (a receipt must reference a real merged PR).
        for issue, receipt in receipts.items():
            result = _valid_build_receipt(issue, receipt, repo)
            if not result.ok:
                return result
        return CloseoutResult(True, "ok", "whole-frontier build: oracle confirms no eligible Buildable remains", {})
    # The oracle still reports eligible Buildable work → require a merged receipt per stamped-frontier
    # issue. Without a stamped frontier the subset coverage cannot be proven → refuse (rule B).
    frontier = _build_frontier_from_record(repo, session)
    if frontier is None:
        return _fail("build-frontier-unproven",
                     "build complete: no eligible frontier was stamped at start AND the oracle still "
                     "reports eligible Buildable work — a whole-frontier build cannot prove it covered "
                     "the frontier (rule B; drain the frontier to empty or build each stamped issue)")
    receipt_keys = {_gate_key(k) for k in receipts}
    missing = sorted(f for f in frontier if f not in receipt_keys)
    if missing:
        return _fail("build-frontier-uncovered",
                     "build complete: the whole ready frontier stamped at start still has eligible "
                     f"issue(s) with no merged-PR receipt: {', '.join('#' + m for m in missing)} — an "
                     "arbitrary-subset close is not complete (build every stamped-frontier issue, or "
                     "drain the frontier to an oracle-confirmed empty)")
    for issue in sorted(frontier):
        receipt = next((v for k, v in receipts.items() if _gate_key(k) == issue), None)
        result = _valid_build_receipt(issue, receipt, repo)
        if not result.ok:
            return result
    return CloseoutResult(True, "ok", "whole-frontier build: every stamped-frontier issue has a linked merged-PR receipt", {})


def _persisted_drain_verdict(repo: str, session: str):
    """THIS session's PERSISTED drain verdict (`.idc-drain-verdict.json`, Stage E2) via
    idc_drain_verdict.current_verdict — a DURABLE artifact the drain wrote, session-scoped and
    staleness-guarded by that reader. None when there is no fresh verdict for THIS session (absent,
    foreign, or stale). Read tolerantly: any failure yields None → the autorun complete fails closed."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        import idc_drain_verdict as DV  # noqa: E402 — lazy (scripts/hooks is already on sys.path)
        return DV.current_verdict(repo, session)
    except Exception:  # noqa: BLE001 — a verdict read failure is fail-closed for autorun complete
        return None


def _gate_key(ref: object) -> str:
    """Canonicalize a gate reference for comparison: an int, `708`, or `#708` all key on `708`."""
    return str(ref).lstrip("#").strip()


def _claim_autorun_waiting_gate(refs: dict, repo: str, session: str) -> CloseoutResult:
    gates = refs.get("gates")
    if not isinstance(gates, list) or not gates or any(not _present(g) for g in gates):
        return _fail("autorun-gates", "autorun waiting_gate requires a non-empty refs.gates list")
    # CONSULT THE ORACLE: a nonempty caller list is not proof. The oracle must report a human-gate wait
    # as the live blocking state, and every NAMED gate must be one of the oracle's live gates. A
    # nonexistent/unreadable repo cannot establish the oracle → fail closed.
    action = _oracle_action(repo)
    if action is None:
        return _fail("autorun-gate-unproven",
                     "autorun waiting_gate requires a fresh, valid next-action oracle result for this repo")
    if action.reason_code != "waiting-human-gate":
        return _fail("autorun-gate-contradicted",
                     f"autorun waiting_gate rejected — the oracle reports {action.reason_code!r}, "
                     "not a human-gate wait (there is still actionable pipeline work or a fixpoint)")
    oracle_gates = {_gate_key(r) for r in (action.refs or ())}
    if not {_gate_key(g) for g in gates} <= oracle_gates:
        return _fail("autorun-gate-mismatch",
                     "autorun waiting_gate names gate(s) that are not among the oracle's live blocking gates")
    return CloseoutResult(True, "ok", "autorun paused behind the oracle's live human gate(s)", {})


def _claim_autorun_drain(refs: dict, repo: str, session: str) -> CloseoutResult:
    # complete: THIS session's PERSISTED drain verdict must read exactly `complete` (the DURABLE
    # artifact, never a caller-supplied drain string).
    verdict = _persisted_drain_verdict(repo, session)
    if verdict is None:
        return _fail("autorun-drain",
                     "autorun complete requires THIS session's persisted drain verdict "
                     "(.idc-drain-verdict.json) — none found (absent, foreign, or stale)")
    if verdict.get("verdict") != "complete":
        return _fail("autorun-drain-incomplete",
                     f"autorun complete requires the persisted drain verdict to be 'complete', "
                     f"got {verdict.get('verdict')!r}")
    return CloseoutResult(True, "ok", "autorun drained to fixpoint this session (persisted verdict)", {})


def _claim_janitor_report(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Re-read the scan result from THIS session's persisted janitor report (idc_command_report) — the
    # DURABLE artifact the scanner run wrote — never a caller `scanner_exit` integer (wave-3 finding 6).
    report = _command_report(repo, "janitor", session)
    if not isinstance(report, dict):
        return _fail("janitor-report-unproven",
                     "janitor complete requires THIS session's persisted janitor report "
                     "(.idc-janitor-report.json recording the scan) — none found (the scan writes it)")
    if not _report_nonce_bound(repo, "janitor", session, report):
        return _fail("janitor-report-nonce",
                     "janitor complete: the persisted janitor report is not bound to THIS command "
                     "record's nonce — the report must be written BY the scanner run of this invocation")
    if report.get("produced_by") != _JANITOR_PROVENANCE:
        return _fail("janitor-report-provenance",
                     "janitor complete: the persisted report lacks the scanner's provenance stamp "
                     "(produced_by) — a hand-written report cannot be passed off as a real scan "
                     "(round-5 finding 7); run the real scanner with --report-session/--report-nonce")
    code = report.get("scanner_exit")
    if isinstance(code, bool) or code not in (0, 1):
        return _fail("janitor-scan",
                     "janitor complete requires a persisted scanner_exit of 0 (coherent) or 1 (findings) "
                     f"— the report records {code!r} (a nonzero-establish exit is blocked_external, not complete)")
    if code == 1 and report.get("clean") is not False:
        return _fail("janitor-hollow-clean",
                     "janitor findings (exit 1) must not claim clean — the report's `clean` must be false")
    return CloseoutResult(True, "ok", "janitor scan re-read from the durable report", {})


def _claim_init_scaffolded(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Re-derive from the SCAFFOLD RECEIPT + presence checks (wave-3 finding 6) — never three caller
    # "ok" strings. The install receipt must be a valid v2 receipt; the governance anchor
    # (tracker-config.yaml) must exist; and a settings file must have the IDC plugin enabled (the hooks
    # switch). The caller supplies at most a reference to the receipt/settings path.
    doc = _receipt_document(repo, refs.get("receipt"))
    if doc is None:
        return _fail("init-receipt",
                     "init complete requires a valid v2 install receipt (docs/workflow/install-receipt.yaml) "
                     "— none found or it does not parse (re-derived, never a caller 'ok' string)")
    top, _entries = doc
    if top.get("receipt_version") != "2":
        return _fail("init-receipt-version",
                     f"init complete requires a v2 install receipt, got receipt_version {top.get('receipt_version')!r}")
    fp = _receipt_fingerprints_ok(repo, refs.get("receipt"))
    if not fp.ok:
        return fp
    anchor = _confined_repo_path(repo, _GOVERNANCE_ANCHOR)
    if anchor is None or not os.path.exists(anchor):
        return _fail("init-anchor-missing",
                     "init complete requires the governance anchor (docs/workflow/tracker-config.yaml) present")
    settings_rel = refs.get("settings") if _ne_str(refs.get("settings")) else ".claude/settings.json"
    spath = _confined_repo_path(repo, settings_rel)
    if spath is None or not os.path.isfile(spath) or not _plugin_still_enabled(spath):
        return _fail("init-not-enabled",
                     "init complete requires the IDC plugin enabled in the repo settings (the opt-in "
                     "the scaffold writes) — re-derived from the settings file, not a caller 'ok'")
    return CloseoutResult(True, "ok", "init scaffold re-derived (v2 receipt + anchor + enablement)", {})


def _claim_doctor_report(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Re-read the run's OWN report (idc_command_report) — the DURABLE artifact the doctor RUN wrote —
    # never a caller-forged rows/verdict (wave-3 finding 6). A FAIL verdict is still a complete run.
    report = _command_report(repo, "doctor", session)
    if not isinstance(report, dict):
        return _fail("doctor-report-unproven",
                     "doctor complete requires THIS session's persisted doctor report "
                     "(.idc-doctor-report.json recording the rows + verdict) — none found (the run writes it)")
    if not _report_nonce_bound(repo, "doctor", session, report):
        return _fail("doctor-report-nonce",
                     "doctor complete: the persisted doctor report is not bound to THIS command "
                     "record's nonce — the report must be written BY the doctor run of this invocation")
    # ROUND-5 F6: re-validate the persisted report against the FULL doctor row contract (all rows 1..10,
    # unique ids, legal outcomes, script-backed rows carry {script,exit}, verdict == the derived
    # aggregation of the row outcomes). A 2-row / arbitrary-JSON / inconsistent-verdict report is refused
    # by the SAME schema the writer enforces — the closeout re-checks it in case a report reached disk by
    # a path other than the guarded writer.
    try:
        import idc_command_report as CR  # noqa: E402 — lazy (scripts/hooks on sys.path)
        schema_ok, reason = CR.validate_doctor_payload(report)
    except Exception:  # noqa: BLE001 — an unvalidatable report fails closed
        return _fail("doctor-report-schema-unread", "doctor complete: the persisted report could not be schema-validated (fail closed)")
    if not schema_ok:
        return _fail("doctor-report-schema",
                     f"doctor complete requires the persisted report to satisfy the full doctor row "
                     f"contract (all rows 1..10, legal outcomes, verdict == aggregation): {reason}")
    # SPOT RE-RUN a cheap, read-only, deterministic doctor check — the install-receipt presence+parse
    # (doctor row 5) — and cross-check the reported outcome: a forged row 5 PASS on a repo whose receipt
    # is ABSENT or does NOT parse is refused (rule B — a reported outcome must survive re-derivation).
    # The re-derivation matches doctor row 5's OWN semantics (presence+parse, NOT fingerprints — that is
    # update's job), so it never false-refuses a legitimate PASS whose scaffold merely drifted; row 5
    # SKIP/FAIL is left alone (a non-PASS is consistent with a repo that has no valid receipt).
    row5 = next((r for r in report["rows"] if isinstance(r, dict) and r.get("id") == 5), None)
    if row5 is not None and row5.get("result") == "PASS" and _receipt_document(repo, None) is None:
        return _fail("doctor-row5-inconsistent",
                     "doctor complete: the persisted report claims row 5 (install receipt) PASS, but a "
                     "read-only re-run finds no install receipt that parses — a reported row outcome that "
                     "disagrees with its deterministic re-run is refused (rule B)")
    return CloseoutResult(True, "ok", "doctor report re-read, schema-validated, row-5 spot-re-run consistent", {})


def _claim_update_resynced(refs: dict, repo: str, session: str) -> CloseoutResult:
    # Re-derive from the UPDATE RECEIPT + live plugin.json (wave-3 finding 6) — never two caller
    # versions. The install receipt must be a valid v2 receipt, and its plugin_version must equal the
    # RUNNING plugin's version (read live from this plugin's own plugin.json).
    doc = _receipt_document(repo, refs.get("receipt"))
    if doc is None:
        return _fail("update-receipt",
                     "update complete requires a valid v2 install receipt — none found or it does not parse "
                     "(re-derived from the receipt, never a caller version)")
    top, _entries = doc
    if top.get("receipt_version") != "2":
        return _fail("update-receipt-version",
                     f"update complete requires a v2 receipt, got receipt_version {top.get('receipt_version')!r}")
    running = _running_plugin_version()
    if running is None:
        return _fail("update-running-unread",
                     "update complete could not read the running plugin version from plugin.json (fail closed)")
    receipt_version = top.get("plugin_version")
    if receipt_version != running:
        return _fail("update-version-mismatch",
                     f"update complete requires the receipt's plugin_version ({receipt_version!r}) to equal "
                     f"the RUNNING plugin version ({running!r}) — the repo was not resynced to this version")
    fp = _receipt_fingerprints_ok(repo, refs.get("receipt"))
    if not fp.ok:
        return fp
    return CloseoutResult(True, "ok", "update resynced: receipt plugin_version == running version + fingerprints verify", {})


_IDC_PLUGIN_NAME = "idc@idc-workflow"
_GOVERNANCE_ANCHOR = "docs/workflow/tracker-config.yaml"


def _plugin_still_enabled(settings_path: str) -> bool:
    """True iff the IDC plugin is STILL enabled in the settings file (round-2 F4-r2 'settings
    mutated' check). Fail-closed: an unreadable/unparseable settings file reads as still-enabled, so
    an applied uninstall cannot claim the key was stripped without a readable, stripped file."""
    try:
        with open(settings_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, UnicodeError, ValueError):
        return True
    plugins = data.get("enabledPlugins") if isinstance(data, dict) else None
    if isinstance(plugins, dict):
        return _IDC_PLUGIN_NAME in plugins
    if isinstance(plugins, list):
        return _IDC_PLUGIN_NAME in plugins
    return False


# Runtime-created IDC artifacts the receipt deliberately does NOT list (idc_receipt_check excludes
# TRACKER.md as a runtime footprint), but which an applied uninstall must STILL remove (wave-4 finding
# 6): the removal set is the receipt footprints UNION these documented runtime artifacts.
_RUNTIME_UNINSTALL_ARTIFACTS = {"TRACKER.md"}


def _receipt_removal_set(repo: str, refs: dict):
    """The removal set DERIVED from the install receipt (never the caller's `removed` list — wave-3
    finding 5) UNION the playbook's documented runtime-created artifacts (`TRACKER.md` — wave-4 finding
    6), minus the governance anchor (removed only post-finish). Returns (footprints_set, None) or
    (None, CloseoutResult-failure)."""
    doc = _receipt_document(repo, refs.get("receipt"))
    if doc is None:
        return None, _fail("uninstall-no-receipt",
                           "an applied uninstall must derive its removal set from the install receipt "
                           "(docs/workflow/install-receipt.yaml) — none found or it does not parse; the "
                           "caller's `removed` list is never authoritative")
    _top, entries = doc
    footprints = ({e["path"] for e in entries} | _RUNTIME_UNINSTALL_ARTIFACTS) - {_GOVERNANCE_ANCHOR}
    return footprints, None


def _uninstall_flags_from_record(repo: str, session: str):
    """The opt-in board flags (`--close-issues` / `--delete-board`) STAMPED on THIS session's ACTIVE
    uninstall record at start (rule A, wave-4 finding 6), or an empty set. Read tolerantly."""
    if not _ne_str(repo) or not _ne_str(session):
        return set()
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "uninstall" and rec.get("uninstall_flags"):
                return set(rec.get("uninstall_flags") or [])
    except Exception:  # noqa: BLE001
        return set()
    return set()


def _open_issues(repo: str):
    """The set of live NON-Done tracker issue numbers (canonical strings) via the shared reader, or
    None on any read failure / an unreadable board (round-5 finding 5: None is UNPROVEN, never "no open
    issues"). Used to verify a stamped `--close-issues` was actually honored."""
    try:
        import idc_next_action as NEXT  # noqa: E402
        return {_gate_key(i["number"]) for i in NEXT._load_tracker_issues(repo)
                if i.get("status") != "Done"}
    except Exception:  # noqa: BLE001 — an unreadable board is UNPROVEN (the caller fails closed on None)
        return None


def _github_board_absent(repo: str):
    """github board-absence probe (round-5 finding 5): True (a REAL `gh project view` proves the project
    genuinely GONE), False (present), or None (indeterminate — no owner/project, gh absent/errored, or an
    ambiguous failure). NEVER infers deletion from a local `TRACKER.md` (github boards have none). A
    `--delete-board` is honored ONLY on a positive True."""
    try:
        import idc_next_action as NEXT  # noqa: E402
        backend, project = NEXT._read_tracker_config(repo)
    except Exception:  # noqa: BLE001
        return None
    if backend != "github" or not _ne_str(project):
        return None
    owner = _gh_capture(repo, ["repo", "view", "--json", "owner", "-q", ".owner.login"])
    if not _ne_str(owner):
        return None
    try:
        proc = subprocess.run(["gh", "project", "view", str(project), "--owner", owner.strip(),
                               "--format", "json"], cwd=repo, capture_output=True, text=True,
                              timeout=_GH_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode == 0:
        return False   # a readable project → present
    err = (proc.stderr or "").lower()
    # A POSITIVE "the project does not exist" signal → genuinely absent. Any other failure (auth,
    # network, rate-limit) is ambiguous → None (rule B: an unreadable board is never proof of deletion).
    if "could not resolve to a projectv2" in err or "not found" in err or "no project" in err:
        return True
    return None


def _board_absent(repo: str):
    """Whether the tracker board is GENUINELY GONE (round-5 finding 5): True (a real read proves it
    absent), False (present + readable), or None (could not determine — an unreadable board is NEVER
    proof of deletion; rule B). On `filesystem` the board IS `TRACKER.md` at the repo root, so its
    absence is a real board-absence read and a present-but-corrupt one is indeterminate. On `github` the
    board is the project — a real `gh project view` probe, never a local TRACKER.md."""
    if _repo_backend(repo) == "github":
        return _github_board_absent(repo)
    tracker = _confined_repo_path(repo, "TRACKER.md")
    if tracker is None:
        return None
    if not os.path.exists(tracker):
        return True
    try:
        import idc_next_action as NEXT  # noqa: E402
        NEXT._load_tracker_issues(repo)
        return False
    except Exception:  # noqa: BLE001 — present on disk but unreadable → indeterminate (rule B)
        return None


def _claim_uninstall(refs: dict, repo: str, session: str) -> CloseoutResult:
    outcome = refs.get("outcome")
    if outcome not in ("applied", "no-action"):
        return _fail("uninstall-outcome", "uninstall complete requires refs.outcome of 'applied' or 'no-action'")
    anchor = _confined_repo_path(repo, _GOVERNANCE_ANCHOR)
    anchor_present = anchor is not None and os.path.exists(anchor)
    flags = _uninstall_flags_from_record(repo, session)
    if outcome == "no-action":
        # A no-action must be PROVEN, never asserted (finding 5): there is nothing to do. Round-5 finding
        # 5 adds two gates BEFORE the footprint check: (1) NO board flag may have been stamped — a
        # --close-issues/--delete-board run REQUESTED board work, so it can never be a no-action; and (2)
        # the documented runtime artifacts (TRACKER.md) must ALSO already be absent (they are not receipt
        # footprints, but a no-action means nothing is left to remove). Then a receipt is REQUIRED to
        # enumerate the footprints and EVERY non-anchor footprint must already be ABSENT.
        if flags:
            return _fail("uninstall-no-action-flags-stamped",
                         "uninstall no-action rejected — this run was invoked with board flag(s) "
                         f"{sorted(flags)} that requested board work; a run that requested "
                         "--close-issues/--delete-board is an 'applied', never a no-action")
        for rel in sorted(_RUNTIME_UNINSTALL_ARTIFACTS):
            p = _confined_repo_path(repo, rel)
            if p is not None and os.path.exists(p):
                return _fail("uninstall-no-action-runtime-artifact",
                             f"uninstall no-action rejected — a runtime artifact {rel!r} is still present "
                             "(there IS work to remove; record 'applied', not 'no-action')")
        doc = _receipt_document(repo, refs.get("receipt"))
        if doc is None:
            return _fail("uninstall-no-action-no-receipt",
                         "uninstall no-action requires an install receipt to prove there is nothing to "
                         "remove — none found or it does not parse (fail closed; a caller assertion is "
                         "never proof that the filesystem is clean)")
        _top, entries = doc
        for e in entries:
            if e["path"] == _GOVERNANCE_ANCHOR:
                continue
            p = _confined_repo_path(repo, e["path"])
            if p is not None and os.path.exists(p):
                return _fail("uninstall-no-action-footprint",
                             f"uninstall no-action rejected — receipt footprint {e['path']!r} is still "
                             "present (there IS work to remove; record 'applied', not 'no-action')")
        return CloseoutResult(True, "ok", "uninstall no-action (verified: no flags, runtime artifacts + footprints all absent)", {})
    # applied: FIRST verify the stamped opt-in board flags were actually honored by REAL reads (finding
    # 6, hardened round-5 finding 5 to fail closed on an unreadable board — rule B). The flags are
    # re-derived from the start record, never caller-supplied.
    if "close-issues" in flags:
        # Honored iff the board is genuinely GONE (no issues can remain open) OR present with zero open
        # issues. An unreadable/indeterminate board is a REFUSAL — never "no open issues" (rule B).
        absent = _board_absent(repo)
        if absent is None:
            return _fail("uninstall-close-issues-unread",
                         "uninstall --close-issues could not confirm the board's open-issue state — the "
                         "board could not be read (an unreadable board is a refusal, not proof the issues "
                         "were closed; rule B)")
        if absent is False:
            open_issues = _open_issues(repo)
            if open_issues is None:
                return _fail("uninstall-close-issues-unread",
                             "uninstall --close-issues could not read the board to confirm no open issue "
                             "remains (rule B)")
            if open_issues:
                return _fail("uninstall-close-issues-open",
                             "uninstall was invoked with --close-issues but the board still shows open "
                             f"issue(s): {', '.join('#' + n for n in sorted(open_issues))} — the requested "
                             "close was not honored (close them before finishing)")
    if "delete-board" in flags:
        # Honored ONLY by a REAL board-absence read proving the project is genuinely gone — never an
        # unreadable board (None) and never a local TRACKER.md absence on a github repo (finding 5).
        if _board_absent(repo) is not True:
            return _fail("uninstall-delete-board-present",
                         "uninstall was invoked with --delete-board but the board's deletion could not be "
                         "PROVEN by a real board-absence read (the project is still present, or its "
                         "absence is indeterminate) — an unreadable board / a missing local TRACKER.md is "
                         "not proof the remote board was deleted (rule B)")
    # the destructive work must have ACTUALLY HAPPENED — validate it by INDEPENDENT checks against the
    # receipt-DERIVED removal set (never the caller's `removed` list — finding 5).
    footprints, err = _receipt_removal_set(repo, refs)
    if err is not None:
        return err
    if not footprints:
        return _fail("uninstall-empty-removal",
                     "an applied uninstall's receipt lists no removable footprint (only the anchor) — "
                     "nothing to apply")
    for rel in sorted(footprints):
        path = _confined_repo_path(repo, rel)
        if path is None:
            continue  # an excluded/odd receipt path — the receipt parser already validated shape
        if os.path.exists(path):
            return _fail("uninstall-not-removed",
                         f"receipt footprint {rel!r} is STILL PRESENT — the uninstall work did not "
                         "complete (a closeout cannot record 'applied' before removing every receipt "
                         "footprint; the caller's `removed` list is not authoritative)")
    # The governance anchor + ledger substrate must STILL be present at finish: their removal is the
    # single documented POST-finish step, so a finish that runs after the anchor is gone is refused.
    if not anchor_present:
        return _fail("uninstall-anchor-gone",
                     "the governance anchor (docs/workflow/tracker-config.yaml) must still be present "
                     "at finish — it is removed only AFTER a successful finish")
    # settings mutated: the enablement key must be stripped (default .claude/settings.json).
    settings_rel = refs.get("settings") if _ne_str(refs.get("settings")) else ".claude/settings.json"
    spath = _confined_repo_path(repo, settings_rel)
    if spath is None or not os.path.isfile(spath):
        return _fail("uninstall-settings-missing", "an applied uninstall requires the repo settings file")
    if _plugin_still_enabled(spath):
        return _fail("uninstall-settings-enabled",
                     "the IDC enablement key was NOT stripped from the settings file")
    # the work-product archive must exist (the archive receipt).
    archive_rel = refs.get("archive")
    if not _ne_str(archive_rel):
        return _fail("uninstall-archive", "an applied uninstall requires refs.archive (the work-product archive path)")
    apath = _confined_repo_path(repo, archive_rel)
    if apath is None or not os.path.exists(apath):
        return _fail("uninstall-archive-missing",
                     "refs.archive must reference the work-product archive file, and it must exist")
    return CloseoutResult(True, "ok",
                          "uninstall work independently verified (receipt footprints gone, settings stripped, "
                          "archive present, anchor present)", {})


# ── THE EVIDENCE CONTRACT (wave-3 structural requirement) ────────────────────────────────────────────
# ONE explicit, enumerated per-command × per-terminal-status claim table. Each Claim names the ONE
# terminal fact it proves and the derivation function that RE-DERIVES that fact from durable state
# (never a caller assertion — a caller may supply only REFERENCE KEYS: a path, an issue/PR number, a
# unit id). The generic walker (`_walk_claim_table`) evaluates every claim for the (command, status)
# in order and fails on the first that cannot be derived. A (command, status) NOT enumerated here is
# NOT claimable — the walker fails it closed. `LEGAL_STATUSES` is DERIVED from this table's keys, so
# the legal-status set and the evidence contract can never drift apart.
@dataclasses.dataclass(frozen=True)
class Claim:
    name: str                        # the terminal fact this claim proves (a stable machine id)
    derive: object                   # callable(refs, repo, session) -> CloseoutResult (re-derives it)


def _claim_blocker_for(command: str):
    """The blocked_external claim for `command`: an allowlisted deterministic-helper failure, artifact-
    matched where the helper wrote one (drain verdict / janitor report). Bound to the command so the
    per-command allowlist applies."""
    return Claim("blocked-external",
                 lambda refs, repo, session: _check_blocker(command, refs, repo, session))


# A `blocked_external` claim is enumerated ONLY for commands with a RE-DERIVABLE deterministic-helper
# blocker (a durable receipt or a safe read-only re-run — see _BLOCKER_HELPERS): build/autorun (drain
# verdict), janitor/doctor (janitor report), init/update/uninstall (receipt fingerprint re-run). The
# pipeline commands intake/think/plan/recirculate have NO such helper (their would-be blockers are PR
# finishers / board mutators / arg-hungry checkers that write no receipt and cannot be re-run), so per
# rule B they carry NO `blocked_external` entry — it is not claimable (fail closed), never a self-report.
_CLAIM_TABLE = {
    "intake": {
        "complete": (Claim("intake-manifest-reviewed", _claim_intake_manifest_reviewed),
                     Claim("intake-pr-merged", _claim_intake_pr_merged)),
    },
    "think": {
        "complete": (Claim("think-refs-present", _claim_think_refs_present),
                     Claim("think-consideration-pass", _claim_think_consideration),
                     Claim("think-intake-coverage", _claim_think_intake_coverage),
                     Claim("think-pr-merged", _claim_think_pr_merged),
                     Claim("think-gate-marker-bound", _claim_think_gate_marker),
                     Claim("think-gate-disposed", _claim_think_gate_disposed),
                     Claim("think-pointer-admitted", _claim_think_pointer_admitted)),
        "waiting_gate": (Claim("think-refs-present", _claim_think_refs_present),
                         Claim("think-consideration-pass", _claim_think_consideration),
                         Claim("think-intake-coverage", _claim_think_intake_coverage),
                         Claim("think-pr-open", _claim_think_pr_open),
                         Claim("think-gate-marker-bound", _claim_think_gate_marker),
                         Claim("think-gate-not-disposed", _claim_think_gate_not_disposed),
                         Claim("think-pointer-blocked", _claim_think_pointer_blocked)),
    },
    "plan": {
        "complete": (Claim("plan-matrix-revalidated", _claim_plan_matrix),
                     Claim("plan-pr-merged", _claim_plan_pr_merged),
                     Claim("plan-decomposition-children", _claim_plan_decomposition),
                     Claim("plan-admitted-set-covered", _claim_plan_admitted_set_covered)),
        "no_action": (Claim("plan-oracle-no-admitted", _claim_plan_no_action),),
    },
    "recirculate": {
        "complete": (Claim("recirc-reconciled", _claim_recirc_reconciled),
                     Claim("recirc-requested-closeouts", _claim_recirc_closeouts)),
        "waiting_gate": (Claim("recirc-gate", _claim_recirc_gate),),
    },
    "build": {
        "complete": (Claim("build-receipts-merged", _claim_build_receipts),),
        "no_action": (Claim("build-oracle-no-eligible", _claim_build_no_action),),
        "blocked_external": (_claim_blocker_for("build"),),
    },
    "autorun": {
        "complete": (Claim("autorun-drain-complete", _claim_autorun_drain),),
        "waiting_gate": (Claim("autorun-oracle-human-gate", _claim_autorun_waiting_gate),),
        "blocked_external": (_claim_blocker_for("autorun"),),
    },
    "janitor": {
        "complete": (Claim("janitor-report", _claim_janitor_report),),
        "blocked_external": (_claim_blocker_for("janitor"),),
    },
    "init": {
        "complete": (Claim("init-scaffolded", _claim_init_scaffolded),),
        "blocked_external": (_claim_blocker_for("init"),),
    },
    "doctor": {
        "complete": (Claim("doctor-report", _claim_doctor_report),),
        "blocked_external": (_claim_blocker_for("doctor"),),
    },
    "update": {
        "complete": (Claim("update-resynced", _claim_update_resynced),),
        "blocked_external": (_claim_blocker_for("update"),),
    },
    "uninstall": {
        "complete": (Claim("uninstall-work-verified", _claim_uninstall),),
        "blocked_external": (_claim_blocker_for("uninstall"),),
    },
}

# Every command must appear (kept in lockstep with COMMANDS). A terminal status is LEGAL for a command
# IFF the claim table enumerates a non-empty claim list for it — so the legal-status set is DERIVED,
# never a second source of truth that could drift from the evidence contract.
assert set(_CLAIM_TABLE) == COMMANDS, "claim table must enumerate exactly the governed commands"
LEGAL_STATUSES = {cmd: frozenset(statuses) for cmd, statuses in _CLAIM_TABLE.items()}


def _walk_claim_table(command: str, status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    """Walk the enumerated claim list for (command, status): evaluate each claim's derivation in order,
    failing on the first that cannot be re-derived. A (command, status) with NO claim list is NOT
    claimable — fail closed (a terminal status with no derivable evidence source can never clear an
    obligation)."""
    claims = _CLAIM_TABLE.get(command, {}).get(status)
    if not claims:
        return CloseoutResult(
            False, "status-not-claimable",
            f"/idc:{command} {status!r} has no evidence-derivation contract — not claimable (fail closed)", {})
    for claim in claims:
        result = claim.derive(refs, repo, session)
        if not result.ok:
            return result
    return CloseoutResult(True, "ok", f"{command} {status} closeout re-derived from durable state", {})


def args_digest(text: str) -> str:
    """The lowercase-hex SHA-256 of the command's raw argument text — a stable, non-reversible
    fingerprint recorded on the lifecycle record (so a closeout can be tied to the exact invocation
    without persisting the possibly-sensitive argument text itself)."""
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


_DOC_ARG_RE = re.compile(r"(?:^|\s)--doc(?:=|\s+)(\S+)")
_UNIT_ARG_RE = re.compile(r"(?:^|\s)--unit(?:=|\s+)(\S+)")


def intake_ref_from_args(command: str, args_text: str):
    """Extract a Think run's intake manifest + selected units from its raw arg text, so intake mode is
    recorded DURABLY on the command record at start (finding 2). Intake mode is stamped IF AND ONLY IF
    the invocation binds a manifest per the brief's argument contract — BOTH `--doc <manifest>` AND a
    NON-EMPTY `--unit <ids>` (round-2 F3-r2). A plain anchor-doc Think (`--doc <anchor>` with no
    `--unit`) is an ordinary, non-intake run and MUST NOT be intake-stamped — stamping it would leave
    an empty selection that the closeout's coverage check rejects, so an honest anchor-doc Think could
    never close. Every other command / arg shape yields (None, None). Storing this on the record (not
    inferring it from caller-supplied finish input) is what stops an intake-mode run from dropping
    units by simply omitting the intake fields at finish."""
    if command != "think" or not args_text:
        return None, None
    doc = _DOC_ARG_RE.search(args_text)
    unit = _UNIT_ARG_RE.search(args_text)
    if not doc or not unit:
        return None, None
    units = [u for u in unit.group(1).split(",") if u]
    if not units:  # `--unit` present but empty/comma-only is not a real intake selection
        return None, None
    return doc.group(1), units


# A recirculate `<manifest>#<unit>` intake-recirc token (the oracle's `intake-needs-recirculation`
# handoff shape), or a bare `#<ticket>` — the NAMED requested item(s) recorded durably at start.
_RECIRC_UNIT_RE = re.compile(r"(\S+\.json#[^\s,]+)")
_RECIRC_TICKET_RE = re.compile(r"(?:^|\s)(#\d+)\b")


def recirc_requested_from_args(command: str, args_text: str):
    """The recirculate requested-item set from its raw arg text (wave-3 finding 4): a
    `<manifest>#<unit>` token, or bare `#<ticket>` numbers. Recorded durably on the record at start so
    the closeout re-verifies EVERY requested item got a validated, tracker-checked disposition — never
    inferable only from caller-supplied finish input. A bare `/idc:recirculate` (full-inbox drain,
    no named item) yields [] (an empty requested set). Every other command yields None."""
    if command != "recirculate" or not args_text:
        return None
    requested = list(_RECIRC_UNIT_RE.findall(args_text))
    requested += [t for t in _RECIRC_TICKET_RE.findall(args_text)]
    return requested


_ISSUE_REF_RE = re.compile(r"(?:^|\s)#(\d+)\b")
_UNINSTALL_FLAG_RE = re.compile(r"(?:^|\s)--(close-issues|delete-board)\b")


def build_requested_from_args(command: str, args_text: str):
    """The Build requested-issue set from its raw arg text (wave-4 finding 5): the explicit `#<issue>`
    references a `/idc:build #1 #2` names. Recorded durably at start so `complete` requires ONE verified
    merged-PR receipt PER requested issue. A whole-board-frontier build (a scope summary / no `#issue`)
    yields None (no stamped set → the oracle-backed frontier path). Every other command yields None."""
    if command != "build" or not args_text:
        return None
    issues = _ISSUE_REF_RE.findall(args_text)
    return issues or None


def uninstall_flags_from_args(command: str, args_text: str):
    """The Uninstall opt-in board flags (`--close-issues` / `--delete-board`) from its raw arg text
    (wave-4 finding 6). Recorded durably at start so the closeout verifies each was actually honored
    (issues closed / board gone) by a real read BEFORE finish. Every other command yields None."""
    if command != "uninstall" or not args_text:
        return None
    flags = _UNINSTALL_FLAG_RE.findall(args_text)
    return flags or None


def _make_nonce():
    """A short, unguessable per-invocation nonce (wave-4 finding 7) that binds a diagnostic report to
    the command record it was opened with. Uses os.urandom (available to the deterministic hook), never
    Math.random-style state that would break resume."""
    return os.urandom(8).hex()


def _plan_admitted_at_start(command: str, repo: str):
    """The admitted-consideration set to STAMP on a Plan record at start (rule A, wave-4 finding 3):
    the live Consideration/Todo set read deterministically from the tracker, or None when it cannot be
    read. Captured at start so a consideration Plan itself retires stays in the required set."""
    if command != "plan":
        return None
    remaining = _remaining_admitted_considerations(repo)
    return sorted(remaining) if remaining is not None else None


def _eligible_buildables(repo: str):
    """The live eligible-Buildable frontier (canonical drain predicate) via the shared oracle reader, or
    None when the tracker cannot be read (fail closed). The independent 'required frontier' derivation
    for a whole-frontier build (round-5 finding 4)."""
    if not _ne_str(repo):
        return None
    try:
        import idc_next_action as NEXT  # noqa: E402 — lazy (reuses the oracle's tracker read)
        state, _ = NEXT._collect_workflow_state(os.path.realpath(os.path.abspath(repo)))
        return {_gate_key(n) for n in state.eligible_buildables}
    except Exception:  # noqa: BLE001 — any tracker read failure yields None (no stamp)
        return None


def _build_frontier_at_start(command: str, repo: str, build_requested):
    """The eligible-frontier set to STAMP on a WHOLE-FRONTIER Build record at start (rule A, round-5
    finding 4): the live eligible-Buildable set, sorted, or None. Stamped ONLY when NO explicit issue
    set was named (a `/idc:build` with `#issues` uses the requested-set path instead). None when the
    board cannot be read at start."""
    if command != "build" or build_requested:
        return None
    frontier = _eligible_buildables(repo)
    return sorted(frontier) if frontier is not None else None


def validate_closeout(command: str, status: str, evidence: object,
                      repo: str | None = None, session: str | None = None) -> CloseoutResult:
    """Validate a closeout's command, terminal status, COMMON envelope, and per-command EVIDENCE
    CONTRACT (the wave-3 claim table). Returns a CloseoutResult; ok=False carries a machine reason_code
    + a human message.

    Order: (1) known command; (2) globally-known status; (3) common envelope (schema_version == 1 and
    refs an object); (4) the status is LEGAL for this command (DERIVED from the claim table); (5) walk
    the enumerated claim table for (command, status) — each claim RE-DERIVES its one terminal fact from
    durable state (a re-run helper, a durable receipt/report/journal, a tracker/oracle read, or a real
    gh read), never a caller assertion. A (command, status) with no claim list is NOT claimable — fail
    closed. `repo` and `session` feed every re-derivation; the caller supplies only reference keys."""
    if command not in COMMANDS:
        return CloseoutResult(False, "unknown-command", f"unknown command {command!r}", {})
    if status not in TERMINAL_STATUSES:
        return CloseoutResult(
            False, "unknown-status",
            f"unknown terminal status {status!r} (expected one of {sorted(TERMINAL_STATUSES)})", {})
    if not isinstance(evidence, dict):
        return CloseoutResult(False, "evidence-not-object", "evidence must be a JSON object", {})
    schema_version = evidence.get("schema_version")
    # STRICT: the INTEGER 1 only. Python's `True == 1` and `1.0 == 1`, so a bare `!= 1` would admit
    # JSON `true` (bool) and `1.0` (float). Reject bool explicitly (bool is a subclass of int) and
    # any non-int type, so only a genuine integer 1 passes.
    if isinstance(schema_version, bool) or not isinstance(schema_version, int) or schema_version != 1:
        return CloseoutResult(
            False, "bad-schema-version",
            f"evidence.schema_version must be the integer 1, got {schema_version!r}", {})
    refs = evidence.get("refs")
    if not isinstance(refs, dict):
        return CloseoutResult(False, "refs-not-object", "evidence.refs must be an object", {})

    # (4) the status must be LEGAL for this specific command — DERIVED from the claim table, so a
    # lifecycle/diagnostic command cannot claim a pipeline waiting_gate/no_action it does not own.
    if status not in LEGAL_STATUSES[command]:
        return CloseoutResult(
            False, "status-not-legal-for-command",
            f"{status!r} is not a legal terminal status for /idc:{command} "
            f"(legal: {sorted(LEGAL_STATUSES[command])})", {})

    # (5) walk the enumerated evidence contract: every claim re-derives its terminal fact for real.
    result = _walk_claim_table(command, status, refs, repo or "", session or "")
    if not result.ok:
        return result
    return CloseoutResult(True, "ok", "closeout valid", evidence)


def register_start(cwd: str, session_id: str, command: str, plugin_version: str,
                   args_text: str, source: str) -> dict:
    """Open (idempotently upsert) the command's active lifecycle record — the entry gate's helper.
    Computes the argument digest and delegates the single ledger write. Assumes freshness/admission
    was already decided by the caller (the entry gate). Returns the record dict when the write
    PERSISTED, `{}` outside a governed repo, or None when the ledger write FAILED (Fix 2).

    A Think run started with `--doc/--unit` durably stamps its intake manifest + selected units on the
    record (finding 2); a recirculate run started with a `<manifest>#<unit>` / `#<ticket>` stamps its
    requested item(s) (finding 4). Either way the closeout enforces coverage from the RECORD on every
    path — a finish that omits those fields cannot make the run look like it had no obligation."""
    intake_manifest, intake_units = intake_ref_from_args(command, args_text or "")
    recirc_requested = recirc_requested_from_args(command, args_text or "")
    build_requested = build_requested_from_args(command, args_text or "")
    uninstall_flags = uninstall_flags_from_args(command, args_text or "")
    plan_admitted = _plan_admitted_at_start(command, cwd)
    build_frontier = _build_frontier_at_start(command, cwd, build_requested)
    return idc_ledger.command_start(
        cwd, session_id, command, plugin_version, args_digest(args_text or ""), source or "",
        intake_manifest=intake_manifest, intake_units=intake_units, recirc_requested=recirc_requested,
        build_requested=build_requested, plan_admitted=plan_admitted, uninstall_flags=uninstall_flags,
        nonce=_make_nonce(), build_frontier=build_frontier)


def active_records(cwd: str, session_id: str) -> list:
    """The active command records for `session_id` — the SAME read path `status` reports from
    (idc_ledger.active_commands). Exposed so the entry gate can READ BACK after a start and CONFIRM
    the record actually persisted, rather than trusting the writer's return (Fix 2)."""
    return idc_ledger.active_commands(cwd, session_id)


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
def _cmd_start(args) -> int:
    if args.command not in COMMANDS:
        print(f"idc-command-contract: unknown command {args.command!r}", file=sys.stderr)
        return 2
    # A REAL, non-empty session identity is required (finding 5). Codex/Pi fire no Claude
    # UserPromptExpansion, so a bare `$CLAUDE_CODE_SESSION_ID` can be empty; refuse it here with a
    # precise message rather than opening an anonymous obligation that another session-less run could
    # collide with on (session="", command).
    if not (args.session or "").strip():
        print("idc-command-contract: refusing to open a command record without a session identity "
              "(the runtime must supply a real, non-empty --session — Codex: its thread/run label; "
              "Pi: the resident's idc-<role> id).", file=sys.stderr)
        return 2
    try:
        result = freshness.evaluate(args.plugin_root, repo=args.repo)
    except freshness.InvalidReceiptError as exc:
        print(f"idc-command-contract: invalid receipt: {exc}", file=sys.stderr)
        return 2
    # A stale runtime must never OPEN an obligation: a stale command body would record work it cannot
    # honestly discharge. Exit 4 without writing a record (the admission gate has already refused the
    # expansion; this is the second, write-side guard for any non-hook caller).
    if result.verdict == "stale":
        print("idc-command-contract: refusing to open a command record on a stale plugin runtime "
              f"(running {result.running_version}, required {result.required_version}); "
              "run /reload-plugins, then retry.", file=sys.stderr)
        return 4
    rec = register_start(args.repo, args.session, args.command, result.running_version or "",
                         args.args or "", args.source or "")
    if rec is None:
        # A governed repo where the ledger write did NOT persist. Never report success for an
        # obligation that was not recorded (Fix 2) — the Stop gate could not enforce its closeout.
        print("idc-command-contract: could not persist the command record (the session state "
              "ledger write failed — check that the repo root is writable), so no obligation was "
              "opened.", file=sys.stderr)
        return 1
    return 0


def _cmd_finish(args) -> int:
    if not (args.session or "").strip():
        print("idc-command-contract: refusing to finish a command record without a session identity "
              "(a blank --session could close another anonymous session's record).", file=sys.stderr)
        return 2
    try:
        evidence = json.loads(args.evidence_json)
    except ValueError as exc:
        print(f"idc-command-contract: malformed --evidence-json: {exc}", file=sys.stderr)
        return 2
    verdict = validate_closeout(args.command, args.status, evidence, repo=args.repo, session=args.session)
    if not verdict.ok:
        print(f"idc-command-contract: rejected closeout [{verdict.reason_code}]: {verdict.message}",
              file=sys.stderr)
        return 2
    rec = idc_ledger.command_finish(
        args.repo, args.session, args.command, args.status, verdict.normalized_evidence)
    if rec is None:
        print(f"idc-command-contract: no active {args.command!r} command record owned by session "
              f"{args.session!r} to finish (a foreign session cannot finish another's record)",
              file=sys.stderr)
        return 2
    return 0


def _cmd_status(args) -> int:
    active = idc_ledger.active_commands(args.repo, args.session)
    finished = [c for c in idc_ledger.read_state(args.repo)["commands"]
                if c.get("state") != "active"]
    if args.session:
        finished = [c for c in finished if c.get("session_id") == args.session]
    if args.json:
        print(json.dumps({"active": active, "finished": finished}, indent=2, sort_keys=True))
    else:
        for c in active:
            print(f"active  {c.get('session_id')}  {c.get('command')}")
        for c in finished:
            closeout = c.get("closeout") or {}
            print(f"done    {c.get('session_id')}  {c.get('command')}  {closeout.get('status')}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="IDC command lifecycle contract (runtime-neutral)")
    sub = ap.add_subparsers(dest="op", required=True)

    sp = sub.add_parser("start", help="open (upsert) a command's active lifecycle record")
    sp.add_argument("--repo", required=True)
    sp.add_argument("--session", required=True)
    sp.add_argument("--command", required=True)
    sp.add_argument("--plugin-root", required=True)
    sp.add_argument("--args", default="")
    sp.add_argument("--source", default="")

    fp = sub.add_parser("finish", help="close an active command with a validated terminal status")
    fp.add_argument("--repo", required=True)
    fp.add_argument("--session", required=True)
    fp.add_argument("--command", required=True)
    fp.add_argument("--status", required=True)
    fp.add_argument("--evidence-json", required=True)

    tp = sub.add_parser("status", help="show the session's active + finished command records")
    tp.add_argument("--repo", required=True)
    tp.add_argument("--session", default=None)
    tp.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    if args.op == "start":
        return _cmd_start(args)
    if args.op == "finish":
        return _cmd_finish(args)
    if args.op == "status":
        return _cmd_status(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
