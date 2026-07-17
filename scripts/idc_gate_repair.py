#!/usr/bin/env python3
"""Reconcile a gate that was closed OUTSIDE the guarded dispose door — without fabricating history.

THE SHAPE THIS REPAIRS (observed in session b7a93ff6; frozen as
``tests/smoke/fixtures/session-b7a93ff6/board-before.json``): the operator really did approve — the
Think PR MERGED — but the gate issue was closed by hand, so the guarded door never ran. The gate is
left with no journaled proof, no `Stage`, a `Status` still reading `Todo` while the issue is CLOSED,
and no reciprocal `idc-gate-pr` binding. The sanctioned binder must establish that binding first;
this repair then handles only the board/journal corruption. Everything downstream otherwise reads
the gate as `unproven-gate-done` and correctly refuses to unblock behind it.

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

TWO DOORS, ONE RULE. The full repair above reconciles the corrupt gate AND finishes its pointer. Its
sibling `--finish-pointer` finishes a pointer behind a gate that is ALREADY proven (either kind) and
repairs nothing — it is what the stage playbooks' interrupted-run recovery calls instead of a raw
engine `unblock`. Both go through the same sole-blocker guard (`_refuse_other_blockers`), because
`unblock --by` drops only the NAMED edge before setting `Todo`: on a pointer held by `[gate, other]`
a raw unblock admits it past `other` without `other`'s proof, and Autorun treats an unblocked
Consideration pointer as approved work. A guard the helper keeps but the four recovery playbooks skip
is not a guard, so the rule lives HERE, once, and the prose routes through it.

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
    read `satisfied` and only the remainder runs. No duplicate record.

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
FULL_REPAIR_OP = "full-repair"      # reconcile a corrupt gate, then finish its pointer
FINISH_OP = "finish-pointer"        # finish a pointer behind an ALREADY-proven gate; repairs nothing
TARGET_STAGE = "Buildable"
TARGET_STATUS = "Done"


class GateRepairError(Exception):
    """A refusal or a stopped repair. Carries the operator-facing reason (and, for a stopped repair,
    the exact readback that failed) — the CLI turns it into exit 2."""


def _marker(pr):
    return P.format_gate_pr_marker(pr)


def format_issue_refs(nums):
    return " + ".join(f"#{int(n)}" for n in nums)


def _blocked_by(ctx, num):
    """`num`'s blockers, read through the backend's OWN existing seam — never a new read door.

    github keeps the edge in the native issue-dependencies relation (`_gh_get_item` reads item FIELDS,
    not dependencies); on filesystem it is a field of the item record, and `_fs_item_full` is the seam
    the engine's own disposition guards read it through.
    """
    if ctx["backend"] == "github":
        return [int(n) for n in B.blocked_by_numbers(int(num), ctx["repo"])]
    return [int(n) for n in (E._fs_item_full(ctx["tracker"], int(num)).get("blocked_by") or [])]


def _other_blockers(ctx, pointer, gate):
    """The pointer's remaining blockers BESIDES `gate`, re-read from the board.

    The engine's `unblock --by` removes the NAMED dependency edge and then sets `Todo` — it does not
    check whether anything ELSE still blocks the pointer (engine internals are out of scope for this
    door). So on a pointer held by several gates, repairing ONE of them and calling `unblock` would
    sail the pointer past the others WITHOUT their proof — and Autorun treats an unblocked
    Consideration pointer as approved work. This door therefore finishes a pointer only when the gate
    it just proved is the SOLE remaining blocker.
    """
    return sorted({n for n in _blocked_by(ctx, pointer) if n != int(gate)})


def _unblock_action(pointer, gate, others, proof, still_land=""):
    """The pointer step's plan line. ONE wording for both doors: the full repair and the
    pointer-finish must never describe this rule differently."""
    if not others:
        return (f"pointer #{pointer} is genuinely {E.BLOCKED_STATUS} behind gate #{gate} — finish it "
                f"through the engine's REAL journaled `unblock` ({proof}: never unblock behind an "
                "unproven gate)")
    return (f"REFUSE the unblock: pointer #{pointer} is {E.BLOCKED_STATUS} behind gate #{gate} AND "
            f"{format_issue_refs(others)}. The engine's `unblock --by` would drop only gate #{gate}'s edge and "
            f"then set Todo — admitting the pointer past {format_issue_refs(others)} without their proof. "
            f"{still_land}resolve {format_issue_refs(others)} through their own doors, then re-run to converge")


def _refuse_other_blockers(gate, pointer, others, preamble, converge):
    """The sole-blocker REFUSAL — raised by the repair's pointer step and by the pointer-finish door,
    written ONCE. This is the rule an operator most needs to trust, so the two callers must never
    drift on what it says or on when it fires."""
    raise GateRepairError(
        f"gate-repair stopped at unblock-pointer: {preamble} pointer #{pointer} is still "
        f"{E.BLOCKED_STATUS} behind {format_issue_refs(others)}. This door finishes a pointer ONLY when the proven "
        f"gate is the SOLE remaining blocker: the engine's `unblock --by` drops only gate #{gate}'s "
        f"edge and then sets Todo, which would admit #{pointer} past {format_issue_refs(others)} without their "
        "proof. Nothing was invented — no dependency was removed and no observation was recorded. "
        f"Resolve {format_issue_refs(others)} through their own doors (a gate's guarded "
        "`dispose --disposition gate-approved`, or this repair for a gate closed outside it), then "
        f"{converge}")


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

    Returns the gate's currently-bound approval PR. A markerless gate is routed through the one
    reciprocal binder before this repair may write anything.
    """
    from idc_board_lint import REQUIREMENTS_GATE_PREFIX, is_requirements_gate_title

    # (1) Only a requirements-change gate is reconciled. Decision gates and arbitrary operator
    # actions have different approval meaning; this door must not invent a requirements approval for
    # them. Build work closes through a verdict-guarded `close` and is excluded for the same reason.
    if not is_requirements_gate_title(obs["title"]):
        raise GateRepairError(
            f"gate-repair refused: #{gate} is not a {REQUIREMENTS_GATE_PREFIX!r} gate (title: "
            f"{obs['title']!r}) — full repair is requirements-change-only; decision gates and "
            "arbitrary operator-action items must use their own approval path")

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
    if bound is None:
        raise GateRepairError(
            f"gate-repair refused: gate #{gate} has no idc-gate-pr body marker — bind both reciprocal "
            "bodies first through `python3 <plugin-root>/scripts/idc_pr_gate_bind.py "
            f"--repo <repo> --pr {int(pr)} --gate {int(gate)}`, then rerun this repair; full repair "
            "never writes either marker itself")
    if bound != int(pr):
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


def _journal_path(ctx):
    return os.path.join(ctx["repo"], JR.JOURNAL_REL)


def _journal_or_stop(ctx, step_id, num, kw):
    """Append ONE record through the engine's structured writer, and STOP unless it landed DURABLY.

    `journal_append` is FAIL-SOFT BY DESIGN: it returns False when durability fails (permissions, a
    full disk, a lock/write error, an append that kept racing the janitor's rotation) and the ENGINE
    deliberately ignores that — a journal failure must never fail a board op, because reconciliation
    is the engine's own detector.

    This helper is the INVERSE case, and that is why it checks. Here the record IS the product: for
    the gate it is the ONLY proof that its `Done` was ever validated. Discarding the False would let
    a routine journal failure leave the gate `unproven` ON DISK while the run marches on to admit its
    pointer and reports success — breaking the one invariant this door exists to hold ("never unblock
    behind an unproven gate"). Proof must mean a proof that LANDED, not an append that was attempted.
    """
    if E.journal_append(ctx["repo"], RECONCILIATION_OP, ctx["backend"], _tracker_rel(ctx), kw):
        return
    raise GateRepairError(
        f"gate-repair stopped at {step_id}: the op={RECONCILIATION_OP} record for #{num} did NOT land "
        f"durably in {_journal_path(ctx)} — the journal writer reported the append failed or could "
        "not be confirmed (check the journal's permissions, disk space, and the janitor's rotation). "
        "Nothing beyond this step was attempted: a gate whose proof is not on disk must never admit "
        "its pointer. Board repairs already applied are idempotent and honest — fix the journal, then "
        "re-run to reconstruct the remaining plan from current state.")


def _journal_gate_record(ctx, gate, pr, observed_before, repairs_applied):
    """The gate's reconciliation record — the evidence `idc_gate_proof.proof_kind` reads back as
    ``verified-reconciliation``. Written through the engine's own structured writer, never by hand.

    Then READ BACK, the same positive-readback discipline every board write in this helper follows: a
    True return says the WRITER believes the line landed, while re-scanning the journal through the
    centralized reader makes "the gate's proof is on disk" LITERAL — which is the condition the
    unblock below actually depends on.
    """
    _journal_or_stop(
        ctx, "journal-gate-reconciliation", gate,
        {"num": int(gate), "agent": REPAIR_AGENT, "to_stage": TARGET_STAGE, "to_status": TARGET_STATUS,
         "disposition_evidence": {"door": REPAIR_DOOR, "approval_pr": int(pr),
                                  "approval_state": "MERGED", "observed_before": observed_before,
                                  "repairs_applied": repairs_applied}},
    )
    kind, err = P.read_proof(ctx["repo"], gate)
    if err:
        raise GateRepairError(
            f"gate-repair stopped at journal-gate-reconciliation: the {RECONCILIATION_OP} record for "
            f"gate #{gate} was appended, but {_journal_path(ctx)} cannot be re-read to CONFIRM it "
            f"({err}) — the gate's proof is INDETERMINATE, which is not proof. Repair/restore the "
            "journal, then re-run.")
    if kind not in P.PROVEN_KINDS:
        raise GateRepairError(
            f"gate-repair stopped at journal-gate-reconciliation: the journal writer reported the "
            f"{RECONCILIATION_OP} record for gate #{gate} appended OK, but re-reading "
            f"{_journal_path(ctx)} still reads the gate as {kind!r} — the append was CLAIMED but the "
            "proof is not on disk, so the gate is not proven and its pointer must not be admitted. "
            "Re-run once the journal is healthy to reconstruct the remaining plan.")


def _journal_pointer_record(ctx, gate, pointer, pr, observed_before):
    """The pointer's OBSERVATION record.

    Two deliberate omissions, both load-bearing:
      * NO `to_stage`/`to_status` → the record carries no `to` state, so replay's field-only skip
        reads no transition out of it. The pointer was already `Todo`; nothing moved it.
      * NO `approval_state` / `approval_pr` → `proof_kind` needs the full triple, so this record can
        never prove the POINTER. The pointer is not a gate and holds no approval of its own; the
        approving PR is recorded as `gate_approval_pr` — true provenance, unmistakable for approval.
    """
    _journal_or_stop(
        ctx, "record-pointer-observed-already-unblocked", pointer,
        {"num": int(pointer), "agent": REPAIR_AGENT,
         "disposition_evidence": {"door": REPAIR_DOOR, "gate": int(gate), "gate_approval_pr": int(pr),
                                  "observed_already_unblocked": True,
                                  "observed_before": observed_before, "repairs_applied": []}},
    )


# ── writes (each re-reads its precondition, then reads back) ─────────────────────────────────────
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
    if obs["pointer"]["status"] != E.BLOCKED_STATUS:
        if obs["pointer"]["status"] != "Todo" or obs["pointer"]["blocked_by"]:
            raise GateRepairError(
                f"gate-repair refused: pointer #{pointer} reads Status={obs['pointer']['status']!r} "
                f"with blocked_by={obs['pointer']['blocked_by']!r}. Only Blocked may transition and "
                "only blocker-free Todo may be recorded as already unblocked; repair the inconsistent "
                "dependency state, then re-run.")

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

    # 2 — verify the one reciprocal binder already bound this gate. Full repair owns no body write.
    step2 = {"id": "verify-gate-pr-binding", "marker": _marker(pr), "gate": int(gate),
             "action": (f"gate #{gate}'s body already binds approval PR #{pr} through the "
                        "reciprocal idc_pr_gate_bind.py door"),
             "status": "satisfied"}
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
        proof_clause = "the gate's proof is journaled FIRST, above"
        still_land = (f"Gate #{gate}'s own repairs above still land (they are independently true); ")

        # What the observation saw. `--apply` RE-READS below before acting on it: the sole-blocker
        # condition is a precondition like any other, and the plan may be minutes stale.
        planned_others = [int(b) for b in obs["pointer"]["blocked_by"] if int(b) != int(gate)]
        step5 = {"id": "unblock-pointer", "pointer": int(pointer), "by": int(gate),
                 "via": "idc_transition.run('unblock')", "invents_transition": False,
                 "other_blockers": planned_others,
                 "action": _unblock_action(pointer, gate, planned_others, proof_clause, still_land)}
        if settled:
            step5["status"] = "satisfied"
        elif apply_:
            others = _other_blockers(ctx, pointer, gate)
            if others:
                _refuse_other_blockers(
                    gate, pointer, others,
                    f"gate #{gate} is repaired and its {RECONCILIATION_OP} is journaled, but",
                    "re-run: the plan reconstructs from current state and only the pointer step "
                    "remains.")
            E.run("unblock", ctx, num=int(pointer), to_status="Todo", by=int(gate))
            # the re-read agreed the gate was the sole blocker — report what actually happened.
            step5["other_blockers"] = []
            step5["action"] = _unblock_action(pointer, gate, [], proof_clause)
            step5["status"] = "applied"
        else:
            step5["status"] = "refused" if planned_others else "planned"
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

    return {"mode": "apply" if apply_ else "dry-run", "op": FULL_REPAIR_OP, "gate": int(gate),
            "pointer": int(pointer), "pr": int(pr), "door": REPAIR_DOOR,
            "observed_before": observed_before, "repairs_applied": repairs_applied, "steps": steps}


# ── the pointer-finish door ──────────────────────────────────────────────────────────────────────
def finish_pointer(ctx, gate, pointer, apply_):
    """Finish a pointer behind an ALREADY-proven gate. The ONE door the stage playbooks' recovery
    calls — so the rule lives in code, not in four prose copies that drift.

    WHY IT EXISTS. `/idc:plan`, `/idc:recirculate`, `/idc:autorun` and `idc:idc-gate-issue` all carry
    the interrupted-run recovery: a still-`Blocked` pointer whose gate reads `Done` may be a prior
    run's dispose that never reached its unblock, so the next run finishes the job. Verifying the
    gate's journaled proof is only HALF of that check. The engine's `unblock --by` removes the NAMED
    edge and then sets `Todo` — it never looks at what ELSE blocks the pointer — so the recovery's
    "then finish the unblock through the engine's `unblock`" frees a pointer Blocked by
    `[gate, other]` past `other` WITHOUT `other`'s proof, and Autorun then treats that unblocked
    Consideration pointer as approved work. That is precisely the admission the repair's own pointer
    step refuses; a guard that lives in the helper but not in the recovery the playbooks actually
    instruct is not a guard. Routing all four through here means it cannot be kept by three surfaces
    and forgotten by the fourth.

    WHAT IT IS NOT. It repairs NOTHING — hence no `--pr`: the gate must ALREADY be proven ON DISK, by
    either kind (`guarded-dispose` or `verified-reconciliation`). An unproven gate belongs at the full
    repair door, which verifies a merged approval PR at repair time and journals that evidence; this
    door must never become a way to walk past a gate whose approval nobody checked.

    WHAT IT WRITES. Nothing of its own. The engine's `unblock` journals itself (op=unblock), which is
    the only transition here that ever happens. A pointer that is not `Blocked` is an honest no-op: no
    unblock was missed, and this door OBSERVED nothing new — the full repair owns the observation
    record, because it is the one that reads the corrupt shape.
    """
    repo = ctx["repo"]
    kind, err = P.read_proof(repo, int(gate))
    if err:
        raise GateRepairError(
            f"pointer-finish refused: the transition journal cannot be read ({err}) — gate #{gate}'s "
            f"proof is INDETERMINATE, and 'I cannot tell whether this gate was approved' must never "
            f"admit #{pointer}. Repair/restore the journal, then re-run.")
    if kind not in P.PROVEN_KINDS:
        raise GateRepairError(
            f"pointer-finish refused: gate #{gate}'s Done reads {kind!r} — this door only finishes a "
            f"pointer behind a gate whose approval is already journaled "
            f"({' or '.join(P.PROVEN_KINDS)}). A `Done` gate alone proves nothing: a legacy/manual "
            f"close, a raw Status edit, or a janitor repair all mint `Done` without ever validating "
            f"the operator's approval. Leave #{pointer} {E.BLOCKED_STATUS} and surface the anomaly. If "
            f"the gate really was approved (its Think PR merged), reconcile it honestly FIRST through "
            f"the full repair door — `idc_gate_repair.py --gate {gate} --pointer {pointer} --pr "
            f"<merged-PR#>`, dry-run first — which verifies the merged PR at repair time and journals "
            "the evidence; never hand-write a journal record to make this door pass.")

    cur = E.get_item(ctx, int(pointer))
    status = cur.get("status") or ""
    blockers = sorted(_blocked_by(ctx, int(pointer)))
    if status != E.BLOCKED_STATUS and (status != "Todo" or blockers):
        raise GateRepairError(
            f"pointer-finish refused: pointer #{pointer} reads Status={status!r} with "
            f"blocked_by={blockers!r}. Only Blocked may transition and only blocker-free Todo is an "
            "honest no-op; repair the inconsistent dependency state, then re-run.")
    planned_others = [n for n in blockers if n != int(gate)]
    observed_before = {"gate": {"num": int(gate), "proof_kind": kind},
                       "pointer": {"status": status, "blocked_by": blockers}}

    steps = [{"id": "verify-gate-proof", "gate": int(gate), "proof_kind": kind, "status": "verified",
              "action": (f"gate #{gate}'s Done is journaled as {kind} — a real approval was verified, "
                         "so this gate may finish its pointer")}]

    step = {"id": "unblock-pointer", "pointer": int(pointer), "by": int(gate),
            "via": "idc_transition.run('unblock')", "invents_transition": False,
            "journals_own_record": False, "other_blockers": planned_others,
            "action": _unblock_action(pointer, gate, planned_others,
                                      f"gate #{gate}'s proof is on disk — {kind}")}
    if status != E.BLOCKED_STATUS:
        # Nothing to finish, so nothing is written — not even an observation. Whatever moved this
        # pointer did so before this run; this door watched none of it and must claim none of it.
        step["status"] = "satisfied"
        step["action"] = (f"pointer #{pointer} already reads Status={status!r}, not "
                          f"{E.BLOCKED_STATUS} — no unblock was missed, so there is nothing to finish "
                          "and NOTHING is recorded (this door observed no transition of its own)")
    elif apply_:
        others = _other_blockers(ctx, pointer, gate)   # re-read: the plan may be minutes stale
        if others:
            _refuse_other_blockers(
                gate, pointer, others, f"gate #{gate}'s Done is proven ({kind}), but",
                "re-run this pointer-finish: it converges once the proven gate is the last blocker "
                "standing.")
        E.run("unblock", ctx, num=int(pointer), to_status="Todo", by=int(gate))
        observed = E.get_item(ctx, int(pointer))
        if (observed.get("status") or "") != "Todo":
            raise GateRepairError(
                f"pointer-finish stopped: read-back divergence on #{pointer} — Status reads "
                f"{observed.get('status')!r} after the engine's unblock, expected 'Todo'. Refusing to "
                "report a finish that did not land; re-run to reconstruct from current state.")
        step["other_blockers"] = []
        step["action"] = _unblock_action(pointer, gate, [], f"gate #{gate}'s proof is on disk — {kind}")
        step["status"] = "applied"
    else:
        step["status"] = "refused" if planned_others else "planned"
    steps.append(step)

    return {"mode": "apply" if apply_ else "dry-run", "op": FINISH_OP, "gate": int(gate),
            "pointer": int(pointer), "pr": None, "door": REPAIR_DOOR,
            "observed_before": observed_before, "repairs_applied": [], "steps": steps}


def build_parser():
    p = argparse.ArgumentParser(
        description="Reconcile a gate closed outside the guarded dispose door — dry-run first, and "
                    "without fabricating history (never a back-dated op=dispose, never an invented "
                    "unblock).")
    p.add_argument("--repo", default=".", help="the governed repo root")
    p.add_argument("--backend", choices=["github", "filesystem"], default=None,
                   help="default: read from tracker-config.yaml, else filesystem. The full repair is "
                        "github-only (the corrupt shape it reconciles — a merged PR + a hand-closed "
                        "issue — is a github artifact); --finish-pointer works on both backends")
    p.add_argument("--tracker", default=None,
                   help="TRACKER.md path (filesystem; default <repo>/TRACKER.md)")
    p.add_argument("--owner", default=None, help="github project owner")
    p.add_argument("--project", default=None, help="github project number")
    p.add_argument("--gate", type=int, required=True, help="the gate issue number")
    p.add_argument("--pointer", type=int, required=True, help="the pointer the gate blocked")
    p.add_argument("--pr", type=int, default=None,
                   help="the merged approval (Think) PR — the full repair only")
    p.add_argument("--finish-pointer", dest="finish_pointer", action="store_true",
                   help="POINTER-FINISH mode: finish a pointer behind an ALREADY-proven gate (repairs "
                        "nothing, takes no --pr). Requires the gate's journaled proof on disk AND the "
                        "proven gate to be the pointer's SOLE remaining blocker — the guarded door the "
                        "stage playbooks' interrupted-run recovery calls instead of a raw engine "
                        "`unblock`, which would drop only the named edge and admit the pointer past "
                        "its other gates without their proof")
    p.add_argument("--apply", action="store_true",
                   help="perform the plan (default: DRY RUN — read, validate, print the plan, write "
                        "nothing)")
    p.add_argument("--json", action="store_true", help="emit the plan as JSON")
    return p


def main(argv=None):
    """Run the repair and RETURN the plan dict (raises GateRepairError). `cli` owns the exit codes."""
    args = build_parser().parse_args(argv)
    repo = os.path.abspath(args.repo)
    backend = E.resolve_backend(args)         # the engine's own resolver: --backend, else the config
    machine = E.load_machine(E.machine_path_for(repo))
    if backend == "github":
        if not (args.owner and args.project):
            raise GateRepairError(
                "gate-repair refused: --owner and --project are required (github backend)")
        ctx = E.github_ctx(repo, args.owner, args.project, machine)
    else:
        ctx = E.fs_ctx(repo, args.tracker or os.path.join(repo, "TRACKER.md"), machine)

    if args.finish_pointer:
        if args.pr is not None:
            raise GateRepairError(
                f"gate-repair refused: --finish-pointer takes no --pr. This mode REPAIRS NOTHING and "
                f"verifies no approval of its own — it finishes a pointer behind a gate whose approval "
                f"is ALREADY journaled ({' or '.join(P.PROVEN_KINDS)}), so an approval PR here could "
                f"only imply a verification that never happened. To reconcile an unproven gate AND "
                f"finish its pointer, run the full repair: --gate {args.gate} --pointer "
                f"{args.pointer} --pr {args.pr} (dry-run first).")
        plan = finish_pointer(ctx, args.gate, args.pointer, args.apply)
    else:
        if backend != "github":
            raise GateRepairError(
                f"gate-repair refused: the full repair is github-only (--backend {backend}) — the "
                "corrupt shape it reconciles (a MERGED approval PR + a hand-CLOSED gate issue) is a "
                "github artifact and the filesystem backend has neither. A filesystem gate is approved "
                "through the engine's guarded `dispose --disposition gate-approved`, which earns real "
                "`guarded-dispose` proof. (`--finish-pointer` runs on both backends.)")
        if args.pr is None:
            raise GateRepairError(
                "gate-repair refused: --pr is required — the full repair records the approval PR it "
                "verified MERGED at repair time, and that evidence IS the gate's proof. To finish a "
                "pointer behind an ALREADY-proven gate, use --finish-pointer (it repairs nothing and "
                "takes no --pr).")
        plan = build_and_run(ctx, args.gate, args.pointer, args.pr, args.apply)

    if args.json:
        print(json.dumps(plan, indent=2, sort_keys=True))
    else:
        head = (f"gate-repair [{plan['mode']}] {plan['op']}: gate #{plan['gate']} "
                f"/ pointer #{plan['pointer']}")
        if plan.get("pr"):
            head += f" / approval PR #{plan['pr']}"
        print(head)
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
