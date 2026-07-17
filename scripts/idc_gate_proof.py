#!/usr/bin/env python3
"""The ONE reader that answers "is this gate's `Done` backed by proof, and of what kind?"

A `Done` gate does not by itself prove anything: a legacy/manual close, a raw `Status` edit, or a
janitor repair all mint `Done` without ever validating the operator's approval. Unblocking a
dependent behind a raw-closed REQUIREMENTS gate would admit requirements that are still only draft in
an open PR. So every recovery surface — `idc:idc-gate-issue` step 4, the `/idc:plan`,
`/idc:recirculate` and `/idc:autorun` Blocked-scans, `/idc:doctor` Row 9 — must consult the JOURNAL,
and they must all consult it the SAME way. This module is that single source; the surfaces call it
instead of each re-implementing an inline scan (which is how they drift apart).

Two kinds count as proof, and they are NOT interchangeable in what they claim:

  * ``guarded-dispose``          — the engine's guarded door ran: an `op=dispose` /
                                   `disposition=gate-approved` record naming the gate. The guard
                                   re-verified the gate's own bound approval artifact BEFORE minting
                                   `Done`, so the close RECORDS the operator's approval.
  * ``verified-reconciliation``  — the gate was closed OUTSIDE the guarded door and later reconciled
                                   by `idc_gate_repair.py`, which verified the merged approval PR at
                                   repair time and journaled the evidence. Weaker provenance than a
                                   guarded dispose (the original close was never guarded) but a REAL,
                                   auditable verification — not a back-dated claim that the guarded
                                   door ran. The repair helper deliberately never forges an
                                   `op=dispose`; this kind is how an honest reconciliation is
                                   recognized without that lie.
  * ``unproven``                 — neither. The caller must NOT auto-unblock: leave the dependent
                                   `Blocked` and surface the anomaly.

FAIL-CLOSED, and the distinction matters: a journal that cannot be READ is an ERROR, never
``unproven``. "No proof exists" and "I cannot tell whether proof exists" are different answers — the
first is a finding, the second is indeterminate — and collapsing the second into the first would let
damaging the journal quietly manufacture a clean negative. ``read_proof`` returns ``(None, reason)``
there and the CLI exits 2; only a READABLE journal ever yields a kind.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_journal_replay as JR  # noqa: E402 — sibling script, path set above

# The three answers. PROVEN_KINDS is the allowlist a recovery surface tests against: recovery may
# finish a still-blocked pointer on EITHER proven kind, and never on `unproven`.
GUARDED_DISPOSE = "guarded-dispose"
VERIFIED_RECONCILIATION = "verified-reconciliation"
UNPROVEN = "unproven"
PROVEN_KINDS = (GUARDED_DISPOSE, VERIFIED_RECONCILIATION)

# The reconciliation door's name, stamped into every record idc_gate_repair writes. A record whose
# evidence names any OTHER door is not this door's record and never proves a gate.
REPAIR_DOOR = "idc-gate-repair"


def _positive_int(value):
    """`value` as a positive int, else None — a malformed evidence field must never raise."""
    try:
        num = int(value)
    except (TypeError, ValueError):
        return None
    return num if num > 0 else None


def proof_kind(entries, gate):
    """The proof kind for `gate` over already-scanned journal `entries` (archives + live segment).

    `entries` must come from ``JR.scan_journal_strict`` — the caller owns its fail-closed error, so a
    kind returned here always describes a journal that was genuinely READ. A record that parses but
    carries partial/garbage evidence is simply not proof (`unproven`); it never raises, and it never
    counts. Every evidence field is load-bearing: the door (this record came from the repair helper),
    the approval state (the PR really merged), and a real PR number (an approval was actually bound).
    """
    gate = _positive_int(gate)
    if gate is None:
        return UNPROVEN
    for entry in entries or ():
        if not isinstance(entry, dict) or JR.journal_item_id(entry) != gate:
            continue
        if entry.get("op") == "dispose" and entry.get("disposition") == "gate-approved":
            return GUARDED_DISPOSE
        if entry.get("op") == "gate-reconciliation":
            evidence = entry.get("evidence") or {}
            if not isinstance(evidence, dict):
                continue
            if (evidence.get("approval_state") == "MERGED"
                    and _positive_int(evidence.get("approval_pr")) is not None
                    and evidence.get("door") == REPAIR_DOOR):
                return VERIFIED_RECONCILIATION
    return UNPROVEN


def read_proof(repo, gate):
    """``(kind, None)`` for a readable journal, ``(None, reason)`` when it cannot be read.

    The seam every surface should use: it owns the archive-aware, lock-safe strict scan so a caller
    never re-derives the journal path or re-invents the fail-closed branch.
    """
    entries, err = JR.scan_journal_strict(os.path.join(repo, JR.JOURNAL_REL))
    if err:
        return None, err
    return proof_kind(entries, gate), None


def proven(repo, gate):
    """``(True/False, None)`` — is `gate`'s Done backed by EITHER proven kind? ``(None, reason)`` when
    the journal cannot be read (indeterminate is not False)."""
    kind, err = read_proof(repo, gate)
    if err:
        return None, err
    return kind in PROVEN_KINDS, None


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Report the journaled proof kind for a gate's Done (fail-closed: an unreadable "
                    "journal is an error, never `unproven`).")
    p.add_argument("--repo", default=".", help="the governed repo root (holds docs/workflow/)")
    p.add_argument("--gate", type=int, required=True, help="the gate issue number")
    p.add_argument("--json", action="store_true", help="emit the verdict as JSON")
    args = p.parse_args(argv)

    kind, err = read_proof(os.path.abspath(args.repo), args.gate)
    if err:
        # Exit 2 = indeterminate. Deliberately NOT the word `unproven` on any stream: a surface that
        # greps this output must never read "cannot tell" as a clean negative.
        msg = (f"idc-gate-proof: the transition journal cannot be read ({err}) — the proof for gate "
               f"#{args.gate} is INDETERMINATE; repair/restore the journal before acting on it")
        if args.json:
            print(json.dumps({"gate": args.gate, "error": err, "indeterminate": True}, sort_keys=True))
        sys.stderr.write(msg + "\n")
        return 2

    if args.json:
        print(json.dumps({"gate": args.gate, "proof_kind": kind, "proven": kind in PROVEN_KINDS},
                         indent=2, sort_keys=True))
    else:
        print(kind)
    return 0


if __name__ == "__main__":
    sys.exit(main())
