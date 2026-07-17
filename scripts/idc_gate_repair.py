#!/usr/bin/env python3
"""Reconcile a gate that was closed OUTSIDE the guarded dispose door — without fabricating history.

THE SHAPE THIS REPAIRS (observed in session b7a93ff6; frozen as
``tests/smoke/fixtures/session-b7a93ff6/board-before.json``): the operator really did approve — the
Think PR MERGED — but the gate issue was closed by hand, so the guarded door never ran. The gate is
left with no journaled proof, no `Stage`, a `Status` still reading `Todo` while the issue is CLOSED,
and no `idc-gate-pr` marker binding the approval PR to it. Everything downstream then reads the gate
as `unproven-gate-done`: `/idc:doctor` Row 9 flags it, and every recovery surface correctly refuses
to unblock behind it.

THE TEMPTING LIE, AND WHY THIS HELPER REFUSES IT: the "easy" repair is to re-run
`dispose --disposition gate-approved`, or to hand-write an `op=dispose` journal line, so the gate
reads `guarded-dispose` and everything goes quiet. Both are FALSE HISTORY. The guarded door did not
run at close time; claiming it did destroys the only signal that distinguishes a gate whose approval
was validated *before* `Done` was minted from one where a human closed a tab. (Re-disposing is not
even a clean re-proof: the terminal op has no already-terminal guard, so it re-closes and
DOUBLE-journals.) So this helper writes an `op=gate-reconciliation` record instead: a truthful,
auditable statement that says "the gate was found in this corrupt state; the approval PR was verified
merged AT REPAIR TIME; here is exactly what was repaired" — which `idc_gate_proof.py` recognizes as
the distinct, weaker kind ``verified-reconciliation``, never as a guarded dispose.

THE SAME DISCIPLINE FOR THE POINTER: the pointer this gate blocked may already be `Todo`. Then there
is NO missed transition to finish, and writing an `unblock` record would invent one — a transition
that never happened, attributed to a run that never made it. So an already-unblocked pointer gets an
OBSERVATION record (``observed_already_unblocked``) that deliberately carries no `to` state (replay
reads no transition out of it) and no approval triple (so it can never be mistaken for proof of the
POINTER — it is not a gate and has no approval of its own). Only a genuinely still-`Blocked` pointer
is finished, through the engine's REAL `unblock` op, and only AFTER the gate's proof is journaled —
never unblock on a gate that is not yet proven.

SAFETY POSTURE
  * DRY RUN IS THE DEFAULT. A bare run reads, validates, and prints a stable JSON plan. It writes
    nothing — no board field, no body edit, no journal line. `--apply` is the only door to a write.
  * Every precondition is validated BEFORE the first write, so a refusal never leaves a partial
    mutation behind.
  * `--apply` RE-READS each step's precondition immediately before performing it (the plan may be
    minutes stale) and READS BACK every write. A readback that diverges STOPS the run and names the
    exact readback that failed — it never reports a write that did not land, and never journals a
    proof for a repair that only half-landed.
  * Rerunning is the recovery: the plan is reconstructed from CURRENT state, so already-landed steps
    read `satisfied` and only the remainder runs. No double-stamp, no duplicate record.

Board writes go through the existing helpers (`idc_gh_board.set_single_select` / the engine's own
`unblock`), and the journal line through `idc_transition.journal_append` — this is the "explicitly
named reconciliation helper that journals itself as reconciliation" the plan's global constraints
admit alongside the engine, not a second write door improvising raw `gh` strings.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_gate_proof as P          # noqa: E402 — sibling scripts, path set above
import idc_gh_board as B            # noqa: E402
import idc_journal_replay as JR     # noqa: E402
import idc_transition as E          # noqa: E402

REPAIR_DOOR = P.REPAIR_DOOR         # "idc-gate-repair" — single-sourced from the proof reader
RECONCILIATION_OP = "gate-reconciliation"
REPAIR_AGENT = "gate-repair"
TARGET_STAGE = "Buildable"
TARGET_STATUS = "Done"


class GateRepairError(Exception):
    """A refusal or a stopped repair. Carries the operator-facing reason (and, for a stopped repair,
    the exact readback that failed) — the CLI turns it into exit 2."""


def _marker(pr):
    return f"<!-- idc-gate-pr: {int(pr)} -->"


# ── reads ────────────────────────────────────────────────────────────────────────────────────────
def _observe(ctx, gate, pointer, pr):
    """Everything the plan is derived from, read once, before any decision."""
    repo = ctx["repo"]
    info = E._gh_issue_json(repo, gate, ["title", "body"])
    gate_fields = E._gh_get_item(ctx, gate)
    pointer_fields = E._gh_get_item(ctx, pointer)
    return {
        "title": info.get("title") or "",
        "body": info.get("body") or "",
        "issue_state": B._issue_state(gate, repo),
        "gate": {"stage": gate_fields.get("stage") or "", "status": gate_fields.get("status") or ""},
        "pointer": {"stage": pointer_fields.get("stage") or "",
                    "status": pointer_fields.get("status") or "",
                    "blocked_by": [int(n) for n in B.blocked_by_numbers(pointer, repo)]},
        "pr_merged": E._pr_merged(repo, pr),
    }


def _validate(obs, gate, pr):
    """Every precondition, BEFORE the first write — so a refusal is always write-free.

    Returns the gate's currently-bound approval PR (int) or None when the body carries no marker.
    """
    from idc_board_lint import OPERATOR_GATE_PREFIX   # single-sourced gate marker

    # (1) Only an operator gate is reconciled. Build work closes through a verdict-guarded `close`;
    # reconciling a non-gate here would mint a Done for work whose verdict was never checked.
    if not obs["title"].startswith(OPERATOR_GATE_PREFIX):
        raise GateRepairError(
            f"gate-repair refused: #{gate} is not an {OPERATOR_GATE_PREFIX} gate item (title: "
            f"{obs['title']!r}) — only an operator gate is reconciled by this door")

    # (2) This door reconciles a gate ALREADY closed outside the guarded door. An OPEN gate has a
    # correct door of its own — the engine's guarded `dispose --disposition gate-approved`, which
    # validates the approval BEFORE minting Done. Sending an open gate through the repair path would
    # downgrade a gate that could still earn real `guarded-dispose` proof.
    if obs["issue_state"] != "CLOSED":
        raise GateRepairError(
            f"gate-repair refused: gate #{gate} issue is {obs['issue_state']} — this door only "
            "reconciles a gate already CLOSED outside the guarded door. Close an open gate through "
            "the engine's guarded `dispose --disposition gate-approved`, which validates the "
            "approval before minting Done (that earns real guarded-dispose proof).")

    # (3) The approval must be REAL and it must be real NOW — the whole point of the record is that
    # the merged PR was verified at repair time.
    if not obs["pr_merged"]:
        raise GateRepairError(
            f"gate-repair refused: PR #{pr} is not merged — a requirements gate is admitted only by "
            "its merged Think PR. Reconciling against an unmerged PR would record an approval that "
            "does not exist.")

    # (4) The body marker BINDS the approval to this gate, so its binding can never be ambiguous or
    # silently re-pointed. Exactly one marker may exist, and it must already name THIS PR.
    body_prs = E.GATE_PR_MARKER.findall(obs["body"])
    if len(body_prs) > 1:
        raise GateRepairError(
            f"gate-repair refused: gate #{gate} carries {len(body_prs)} idc-gate-pr markers in its "
            f"body ({', '.join('#' + p for p in body_prs)}) — the producer stamps exactly ONE. An "
            "ambiguous binding must never be resolved silently; leave exactly one marker, then re-run.")
    bound = int(body_prs[0]) if body_prs else None
    if bound is not None and bound != int(pr):
        raise GateRepairError(
            f"gate-repair refused: gate #{gate}'s body already binds approval PR #{bound}, not the "
            f"--pr #{pr} given — re-binding a gate's recorded approval to a different PR is exactly "
            "the forgery this door exists to avoid. Verify which PR truly approved this gate.")
    return bound


# ── the journal seams ────────────────────────────────────────────────────────────────────────────
def _entries(repo):
    entries, err = JR.scan_journal_strict(os.path.join(repo, JR.JOURNAL_REL))
    if err:
        raise GateRepairError(
            f"gate-repair refused: the transition journal cannot be read ({err}) — the gate's "
            "existing proof is INDETERMINATE, so a repair could duplicate a record or overwrite a "
            "real history. Repair/restore the journal first.")
    return entries


def _pointer_settled(entries, pointer, gate):
    """True iff the pointer's relationship to THIS gate is already journaled — either the observation
    record this helper writes, or the engine's real `unblock` naming the gate. Keeps a rerun a clean
    no-op, and (importantly) stops a rerun AFTER a real unblock from then writing an
    `observed_already_unblocked` record — which would read as "nothing ever needed unblocking" and
    quietly contradict the unblock record sitting right above it."""
    for entry in entries:
        if JR.journal_item_id(entry) != int(pointer):
            continue
        ev = entry.get("evidence") or {}
        if (entry.get("op") == RECONCILIATION_OP and isinstance(ev, dict)
                and ev.get("observed_already_unblocked") is True and ev.get("gate") == int(gate)):
            return True
        if entry.get("op") == "unblock" and entry.get("unblocked_by") == int(gate):
            return True
    return False


def _tracker_rel(ctx):
    return os.path.relpath(ctx["tracker"], ctx["repo"]) if ctx.get("tracker") else None


def _journal_gate_record(ctx, gate, pr, observed_before, repairs_applied):
    """The gate's reconciliation record — the evidence `idc_gate_proof.proof_kind` reads back as
    ``verified-reconciliation``. Written through the engine's own structured writer, never by hand."""
    E.journal_append(
        ctx["repo"], RECONCILIATION_OP, ctx["backend"], _tracker_rel(ctx),
        {"num": int(gate), "agent": REPAIR_AGENT, "to_stage": TARGET_STAGE, "to_status": TARGET_STATUS,
         "disposition_evidence": {"door": REPAIR_DOOR, "approval_pr": int(pr),
                                  "approval_state": "MERGED", "observed_before": observed_before,
                                  "repairs_applied": repairs_applied}},
    )


def _journal_pointer_record(ctx, gate, pointer, pr, observed_before):
    """The pointer's OBSERVATION record.

    Two deliberate omissions, both load-bearing:
      * NO `to_stage`/`to_status` → the record carries no `to` state, so replay's field-only skip
        reads no transition out of it. The pointer was already `Todo`; nothing moved it.
      * NO `approval_state` / `approval_pr` → `proof_kind` needs the full triple, so this record can
        never prove the POINTER. The pointer is not a gate and holds no approval of its own; the
        approving PR is recorded as `gate_approval_pr` — true provenance, unmistakable for approval.
    """
    E.journal_append(
        ctx["repo"], RECONCILIATION_OP, ctx["backend"], _tracker_rel(ctx),
        {"num": int(pointer), "agent": REPAIR_AGENT,
         "disposition_evidence": {"door": REPAIR_DOOR, "gate": int(gate), "gate_approval_pr": int(pr),
                                  "observed_already_unblocked": True,
                                  "observed_before": observed_before, "repairs_applied": []}},
    )


# ── writes (each re-reads its precondition, then reads back) ─────────────────────────────────────
def _stamp_marker(ctx, gate, pr):
    """Append the canonical marker to the gate body — the ONLY body edit this helper ever makes."""
    repo = ctx["repo"]
    body = (E._gh_issue_json(repo, gate, ["body"]).get("body") or "")   # re-read: the plan may be stale
    found = E.GATE_PR_MARKER.findall(body)
    if len(found) == 1 and int(found[0]) == int(pr):
        return False        # a concurrent stamp landed it — satisfied, not an error
    if found:
        raise GateRepairError(
            f"gate-repair stopped: gate #{gate}'s body changed under the plan — it now carries "
            f"{len(found)} idc-gate-pr marker(s) ({', '.join('#' + p for p in found)}). Re-run to "
            "rebuild the plan from current state.")
    B._gh(["issue", "edit", str(int(gate)), "--body", body.rstrip("\n") + "\n\n" + _marker(pr) + "\n"], repo)
    after = E.GATE_PR_MARKER.findall(E._gh_issue_json(repo, gate, ["body"]).get("body") or "")
    if len(after) != 1 or int(after[0]) != int(pr):
        raise GateRepairError(
            f"gate-repair stopped: body-marker read-back divergence on gate #{gate} — the body reads "
            f"{len(after)} idc-gate-pr marker(s) {['#' + p for p in after]} after the edit, expected "
            f"exactly one binding PR #{pr}. Refusing to report a stamp that did not land.")
    return True


def _set_and_verify(ctx, num, field, value):
    """One single-select write through the existing board helper, then a POSITIVE read-back.

    Returns True iff a write happened (already-correct is a silent no-op, which is what makes a rerun
    after a partial failure land only the remainder)."""
    current = E._gh_get_item(ctx, num)
    if (current.get(field.lower()) or "") == value:
        return False
    item_id = E._gh_item_id(ctx, num)
    B.set_single_select(ctx["owner"], ctx["project"], ctx["repo"], item_id, field, value)
    observed = E._gh_get_item(ctx, num)
    if (observed.get(field.lower()) or "") != value:
        raise GateRepairError(
            f"gate-repair stopped: read-back divergence on #{num} — {field} reads "
            f"{observed.get(field.lower())!r} after the write, expected {value!r}. Refusing to report "
            "a write that did not land; nothing was journaled. Re-run to reconstruct the remaining "
            "plan from current state.")
    return True


# ── the plan ─────────────────────────────────────────────────────────────────────────────────────
def build_and_run(ctx, gate, pointer, pr, apply_):
    obs = _observe(ctx, gate, pointer, pr)
    bound = _validate(obs, gate, pr)          # every refusal happens here — before any write

    observed_before = {
        "gate": {"stage": obs["gate"]["stage"], "status": obs["gate"]["status"],
                 "issue_state": obs["issue_state"]},
        "pointer": {"stage": obs["pointer"]["stage"], "status": obs["pointer"]["status"],
                    "blocked_by": obs["pointer"]["blocked_by"]},
        "pr": {"number": int(pr), "state": "MERGED"},
    }
    entries = _entries(ctx["repo"])
    already_proven = P.proof_kind(entries, gate) in P.PROVEN_KINDS
    pointer_blocked = obs["pointer"]["status"] == E.BLOCKED_STATUS
    settled = _pointer_settled(entries, pointer, gate)

    def state(done, applied):
        return "satisfied" if done else ("applied" if applied else "planned")

    steps = []
    repairs_applied = []

    # 1 — verify the approval PR really merged (a read; the whole record rests on it).
    steps.append({"id": "verify-pr-merged", "status": "verified", "pr": int(pr), "state": "MERGED",
                  "action": f"verified PR #{pr} is MERGED — the operator's real approval"})

    # 2 — stamp exactly one body marker binding the approval PR to THIS gate.
    marker_done = bound == int(pr)
    step2 = {"id": "stamp-gate-pr-marker", "marker": _marker(pr), "gate": int(gate),
             "action": (f"gate #{gate}'s body already binds approval PR #{pr}" if marker_done else
                        f"append exactly one {_marker(pr)} to gate #{gate}'s body, binding the "
                        "approval PR to this gate (the rest of the body is preserved)")}
    if apply_ and not marker_done:
        if _stamp_marker(ctx, gate, pr):
            repairs_applied.append("gate-pr-marker")
    step2["status"] = state(marker_done, apply_)
    steps.append(step2)

    # 3 — repair the board fields the hand-close skipped; the ISSUE's closed state is left alone.
    needs = [f for f, v in (("Stage", TARGET_STAGE), ("Status", TARGET_STATUS))
             if (obs["gate"][f.lower()] or "") != v]
    step3 = {"id": "repair-gate-fields", "gate": int(gate),
             "to": {"stage": TARGET_STAGE, "status": TARGET_STATUS},
             "from": {"stage": obs["gate"]["stage"], "status": obs["gate"]["status"]},
             "issue_state": obs["issue_state"], "keeps_issue_closed": True, "fields": needs,
             "action": (f"gate #{gate} already reads Stage={TARGET_STAGE} / Status={TARGET_STATUS}"
                        if not needs else
                        f"set {' + '.join(needs)} on gate #{gate} through the board helpers "
                        f"(Stage={TARGET_STAGE}, Status={TARGET_STATUS}); the issue stays CLOSED — "
                        "this repair never re-opens or re-closes it")}
    if apply_:
        for field, value in (("Stage", TARGET_STAGE), ("Status", TARGET_STATUS)):
            if _set_and_verify(ctx, gate, field, value):
                repairs_applied.append(field.lower())
    step3["status"] = state(not needs, apply_)
    steps.append(step3)

    # 4 — the reconciliation record: the gate's proof. Never an op=dispose.
    step4 = {"id": "journal-gate-reconciliation", "gate": int(gate), "op": RECONCILIATION_OP,
             "who": REPAIR_AGENT, "to": {"stage": TARGET_STAGE, "status": TARGET_STATUS},
             "evidence": {"door": REPAIR_DOOR, "approval_pr": int(pr), "approval_state": "MERGED",
                          "observed_before": observed_before, "repairs_applied": repairs_applied},
             "fabricates_dispose": False,
             "action": (f"gate #{gate}'s Done is already journaled as proven — no record needed"
                        if already_proven else
                        f"append one op={RECONCILIATION_OP} record for gate #{gate} carrying the "
                        f"observed-before state and the merged-PR evidence (reads back as "
                        f"{P.VERIFIED_RECONCILIATION}); never an op=dispose — the guarded door did "
                        "not run, and this record must not claim it did")}
    if apply_ and not already_proven:
        _journal_gate_record(ctx, gate, pr, observed_before, repairs_applied)
    step4["status"] = state(already_proven, apply_)
    steps.append(step4)

    # 5 — the pointer. Either it is genuinely still Blocked (finish it through the engine's REAL
    # unblock, only now that the gate's proof is on disk), or it is already Todo (record the
    # OBSERVATION; invent nothing).
    if pointer_blocked:
        step5 = {"id": "unblock-pointer", "pointer": int(pointer), "by": int(gate),
                 "via": "idc_transition.run('unblock')", "invents_transition": False,
                 "action": (f"pointer #{pointer} is genuinely {E.BLOCKED_STATUS} behind gate #{gate} "
                            "— finish it through the engine's REAL journaled `unblock` (the gate's "
                            "proof is journaled FIRST, above: never unblock behind an unproven gate)")}
        if apply_ and not settled:
            E.run("unblock", ctx, num=int(pointer), to_status="Todo", by=int(gate))
        step5["status"] = state(settled, apply_)
    else:
        step5 = {"id": "record-pointer-observed-already-unblocked", "pointer": int(pointer),
                 "gate": int(gate), "observed_already_unblocked": True, "invents_transition": False,
                 "observed": observed_before["pointer"],
                 "action": (f"pointer #{pointer} is already {obs['pointer']['status']} — record the "
                            "OBSERVATION only. No unblock ever ran, so no unblock is invented: the "
                            "record carries no `to` state and no approval of its own")}
        if apply_ and not settled:
            _journal_pointer_record(ctx, gate, pointer, pr, observed_before["pointer"])
        step5["status"] = state(settled, apply_)
    steps.append(step5)

    return {"mode": "apply" if apply_ else "dry-run", "gate": int(gate), "pointer": int(pointer),
            "pr": int(pr), "door": REPAIR_DOOR, "observed_before": observed_before,
            "repairs_applied": repairs_applied, "steps": steps}


def build_parser():
    p = argparse.ArgumentParser(
        description="Reconcile a gate closed outside the guarded dispose door — dry-run first, and "
                    "without fabricating history (never a back-dated op=dispose, never an invented "
                    "unblock).")
    p.add_argument("--repo", default=".", help="the governed repo root")
    p.add_argument("--backend", choices=["github"], default="github",
                   help="github only: the corrupt shape (a merged PR + a closed issue) is a github "
                        "artifact; the filesystem backend has neither")
    p.add_argument("--owner", default=None, help="github project owner")
    p.add_argument("--project", default=None, help="github project number")
    p.add_argument("--gate", type=int, required=True, help="the gate issue number")
    p.add_argument("--pointer", type=int, required=True, help="the pointer the gate blocked")
    p.add_argument("--pr", type=int, required=True, help="the merged approval (Think) PR")
    p.add_argument("--apply", action="store_true",
                   help="perform the plan (default: DRY RUN — read, validate, print the plan, write "
                        "nothing)")
    p.add_argument("--json", action="store_true", help="emit the plan as JSON")
    return p


def main(argv=None):
    """Run the repair and RETURN the plan dict (raises GateRepairError). `cli` owns the exit codes."""
    args = build_parser().parse_args(argv)
    repo = os.path.abspath(args.repo)
    if not (args.owner and args.project):
        raise GateRepairError("gate-repair refused: --owner and --project are required (github backend)")
    ctx = E.github_ctx(repo, args.owner, args.project, E.load_machine(E.machine_path_for(repo)))
    plan = build_and_run(ctx, args.gate, args.pointer, args.pr, args.apply)
    if args.json:
        print(json.dumps(plan, indent=2, sort_keys=True))
    else:
        print(f"gate-repair [{plan['mode']}] gate #{plan['gate']} / pointer #{plan['pointer']} "
              f"/ approval PR #{plan['pr']}")
        for step in plan["steps"]:
            print(f"  [{step['status']:>9}] {step['id']}: {step['action']}")
    return plan


def cli(argv=None):
    try:
        main(argv)
    except GateRepairError as exc:
        sys.stderr.write(f"idc-gate-repair: {exc}\n")
        return 2
    except B.RateLimitError as exc:
        B.emit_rate_limit_verdict(exc)          # exit 3 (resumable), pinned verdict
    except (B.BoardReadError, E.TransitionError) as exc:
        sys.stderr.write(f"idc-gate-repair: board/engine error: {exc}\n")
        return 3                                 # resumable — never a silent partial success
    return 0


if __name__ == "__main__":
    sys.exit(cli())
