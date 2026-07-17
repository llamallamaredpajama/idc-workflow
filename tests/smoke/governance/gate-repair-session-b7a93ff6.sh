#!/bin/bash
# gate-repair-session-b7a93ff6.sh — governance scenario: the CORRUPT gate shape observed in session
# b7a93ff6 is reconciled WITHOUT fabricating history.
#
# THE CORRUPTION (tests/smoke/fixtures/session-b7a93ff6/board-before.json — fixture numbers only,
# never the live repo): the Think PR #706 MERGED (a real operator approval), but gate #708 was closed
# OUTSIDE the guarded dispose door. So it carries NO journaled proof, its Stage was never set (""),
# its Status still reads `Todo` while the issue is CLOSED, and its body never got the reciprocal
# binding. The fixture is pre-bound the way `idc_pr_gate_bind.py` now requires before full repair;
# a separate refusal proves repair cannot write a marker itself. Pointer #707 is ALREADY `Todo`.
#
# THE HONEST REPAIR (scripts/idc_gate_repair.py): bind first through idc_pr_gate_bind.py, dry-run the
# repair, verify the PR really merged; repair Stage/Status through the existing board helpers while the issue
# stays closed; journal an `op=gate-reconciliation` record carrying the observed-before state and the
# merged-PR evidence — a record that says "reconciled, here is the evidence", never a back-dated
# `op=dispose` claiming the guarded door ran. For an already-unblocked pointer it records the
# OBSERVATION (`observed_already_unblocked`) and invents no transition; only a genuinely still-Blocked
# pointer gets the engine's REAL `unblock`, and only after the gate proof is journaled first.
#
# github isn't hermetic, so this is an in-process unit: idc_gh_board._gh / fetch_item /
# set_single_select / the dependency mutators and idc_gh_close._resolve_item_id are faked from the
# fixture; the JOURNAL WRITER (idc_transition.journal_append) and the PROOF READER
# (idc_gate_proof/idc_journal_replay.scan_journal_strict) are the REAL code against a real temp repo.
#
# Red-when-broken (each sabotage FAILs a named case):
#   * make proof_kind() always return "unproven"                    → cases 2f/3a FAIL
#   * let proof_kind() accept evidence without door/approval_state  → case 7c FAIL
#   * journal `op=dispose`/`disposition=gate-approved` instead of gate-reconciliation → case 2e FAILs
#   * invent an `unblock` for the already-Todo pointer              → case 2e FAILs
#   * append the pointer record WITH a `to` state                   → case 2d FAILs
#   * drop the dry-run default (write on a bare run)                → case 1b FAILs
#   * drop the >1-marker / foreign-marker / unmerged-PR / non-gate-title refusals → case 4* FAIL
#   * skip a readback after a write                                 → case 6 FAILs
#   * journal the gate proof AFTER the unblock (not before)         → case 5b FAILs
#   * double-stamp / re-journal on a rerun                          → case 3 FAILs
#   * ignore journal_append's False (a proof that never landed)     → case 9 FAILs
#   * unblock a pointer while ANOTHER blocker remains               → case 10 FAILs
#
# Usage: bash tests/smoke/governance/gate-repair-session-b7a93ff6.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

REPAIR="$GOV_PLUGIN/scripts/idc_gate_repair.py"
PROOF="$GOV_PLUGIN/scripts/idc_gate_proof.py"
FIXTURE="$GOV_PLUGIN/tests/smoke/fixtures/session-b7a93ff6/board-before.json"

[ -f "$FIXTURE" ] || gov_fail "tests/smoke/fixtures/session-b7a93ff6/board-before.json not found"
[ -f "$REPAIR" ] || gov_fail "scripts/idc_gate_repair.py not found"
[ -f "$PROOF" ] || gov_fail "scripts/idc_gate_proof.py not found"

python3 - "$GOV_PLUGIN/scripts" "$FIXTURE" <<'PY' || gov_fail "the session-b7a93ff6 gate-repair unit failed (see above)"
import copy, json, os, shutil, sys, tempfile

sys.path.insert(0, sys.argv[1])
FIXTURE = json.load(open(sys.argv[2], encoding="utf-8"))

import idc_gh_board as B
import idc_gh_close as GC
import idc_transition as E
import idc_journal_replay as RP
import idc_gate_proof as P
import idc_gate_repair as R

OWNER, PROJECT = "fixture-owner", "77"
GATE, POINTER, PR = 708, 707, 706


def die(msg):
    raise SystemExit(f"FAIL: {msg}")


def check(cond, msg):
    if not cond:
        die(msg)


class Fake:
    """The github surface, driven by the fixture. Every mutation is recorded in `calls` (ordered)."""

    def __init__(self, fx):
        self.pr = dict(fx["pr"])
        self.gate = dict(fx["gate"])
        self.pointer = dict(fx["pointer"])
        self.pointer.setdefault("title", "consideration pointer — Drive foundation")
        self.pointer.setdefault("body", "")
        self.pointer.setdefault("issue_state", "OPEN")
        self.calls = []
        self.sabotage = None   # (num, Field) whose write silently does not land

    # ── reads/writes ──────────────────────────────────────────────────────────────────────────
    def item(self, num):
        num = int(num)
        if num == self.gate["number"]:
            return self.gate
        if num == self.pointer["number"]:
            return self.pointer
        die(f"the unit asked for unknown issue #{num}")

    def gh(self, args, repo):
        self.calls.append(("gh", tuple(str(a) for a in args)))
        if args[0] == "pr" and args[1] == "view":
            check(int(args[2]) == self.pr["number"], f"repair read an unexpected PR #{args[2]}")
            merged = self.pr["state"] == "MERGED"
            return json.dumps({"state": self.pr["state"],
                               "mergedAt": "2026-07-09T00:00:00Z" if merged else None})
        if args[0] == "issue" and args[1] == "view":
            it = self.item(args[2])
            if "--jq" in args:                       # idc_gh_board._issue_state
                return it["issue_state"] + "\n"
            fields = args[args.index("--json") + 1].split(",")
            out = {}
            for f in fields:
                if f == "labels":
                    out["labels"] = []
                elif f == "comments":
                    out["comments"] = []
                elif f == "state":
                    out["state"] = it["issue_state"]
                else:
                    out[f] = it.get(f, "")
            return json.dumps(out)
        if args[0] == "issue" and args[1] == "edit":
            it = self.item(args[2])
            it["body"] = args[args.index("--body") + 1]
            return ""
        die(f"the repair made an unexpected gh call: {list(args)} "
            "(every board read/write must go through the existing helpers)")

    def fetch_item(self, item_id, repo="."):
        num = int(str(item_id).rsplit("_", 1)[-1])
        it = self.item(num)
        return {"stage": it.get("stage") or "", "status": it.get("status") or "",
                "id": item_id, "content": {"number": num}}

    def set_single_select(self, owner, project, repo, item_id, field, option):
        num = int(str(item_id).rsplit("_", 1)[-1])
        self.calls.append(("set", num, field, option))
        if self.sabotage == (num, field):
            return          # the write silently does not land → the readback must catch it
        self.item(num)[field.lower()] = option

    def blocked_by_numbers(self, child, repo="."):
        return list(self.item(child).get("blocked_by") or [])

    def remove_blocked_by(self, child, parent, repo="."):
        self.calls.append(("remove-dep", int(child), int(parent)))
        bb = self.item(child).get("blocked_by") or []
        self.item(child)["blocked_by"] = [b for b in bb if int(b) != int(parent)]

    def add_comment(self, num, body, repo="."):
        self.calls.append(("comment", int(num), body))

    def install(self):
        B._gh = self.gh
        B.fetch_item = self.fetch_item
        B.set_single_select = self.set_single_select
        B.blocked_by_numbers = self.blocked_by_numbers
        B.remove_blocked_by = self.remove_blocked_by
        B.blocked_by_comment_ids = lambda child, parent, repo=".": []
        B.add_comment = self.add_comment
        GC._resolve_item_id = lambda owner, project, issue, repo: f"PVTI_{int(issue)}"
        GC.close_issue = lambda *a, **k: die("the repair called close_issue — the gate issue is "
                                             "already CLOSED; the repair must never re-close it")
        return self

    def wrote(self):
        return [c for c in self.calls
                if c[0] in ("set", "remove-dep", "comment")
                or (c[0] == "gh" and c[1][:2] == ("issue", "edit"))]


def new_repo():
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "docs", "workflow"), exist_ok=True)
    return d


def journal(repo):
    entries, err = RP.scan_journal_strict(os.path.join(repo, RP.JOURNAL_REL))
    check(err is None, f"the journal written by the repair is unreadable: {err}")
    return entries


def fresh(mutate=None):
    fx = copy.deepcopy(FIXTURE)
    fx["gate"]["body"] = fx["gate"]["body"].rstrip() + f"\n\n<!-- idc-gate-pr: {PR} -->"
    fx["pr"]["body"] = f"Disposable Think PR\n\n<!-- idc-gate-pr: {GATE} -->"
    if mutate:
        mutate(fx)
    return Fake(fx).install(), new_repo()


def repair_argv(repo, apply=False, gate=GATE, pointer=POINTER, pr=PR):
    argv = ["--repo", repo, "--backend", "github", "--owner", OWNER, "--project", PROJECT,
            "--gate", str(gate), "--pointer", str(pointer), "--pr", str(pr)]
    if apply:
        argv.append("--apply")
    return argv


def repair(repo, apply=False, gate=GATE, pointer=POINTER, pr=PR):
    # main() RETURNS the plan dict (the CLI's --json is the same object serialized), so the unit
    # asserts on structure rather than re-parsing stdout.
    return R.main(repair_argv(repo, apply=apply, gate=gate, pointer=pointer, pr=pr))


def plan_of(result):
    check(isinstance(result, dict), f"the repair did not return a plan object: {result!r}")
    return result


def ids(plan):
    return [s["id"] for s in plan["steps"]]


def step(plan, sid):
    for s in plan["steps"]:
        if s["id"] == sid:
            return s
    die(f"the plan carries no {sid!r} step: {json.dumps(plan, indent=2)}")


EXPECTED_ORDER = ["verify-pr-merged", "verify-gate-pr-binding", "repair-gate-fields",
                  "journal-gate-reconciliation", "record-pointer-observed-already-unblocked"]

# ══ 1. DRY RUN — the default — reports the five steps IN ORDER and writes NOTHING ═══════════════
fake, repo = fresh()
prebound_body = fake.gate["body"]
plan = plan_of(repair(repo))
check(plan.get("mode") == "dry-run", f"a bare run is not a dry run: mode={plan.get('mode')!r}")
check(ids(plan) == EXPECTED_ORDER,
      f"the dry-run plan's step order is wrong:\n  got      {ids(plan)}\n  expected {EXPECTED_ORDER}")
check(step(plan, "verify-pr-merged")["status"] == "verified", "the dry run did not VERIFY PR #706 merged")
check(step(plan, "verify-pr-merged")["pr"] == PR, "the verify step names the wrong PR")
check(step(plan, "verify-gate-pr-binding")["marker"] == f"<!-- idc-gate-pr: {PR} -->",
      "the dry run does not plan the canonical single body marker for #706")
rg = step(plan, "repair-gate-fields")
check(rg["to"] == {"stage": "Buildable", "status": "Done"},
      f"the dry run does not plan Stage=Buildable + Status=Done: {rg.get('to')!r}")
check(rg.get("issue_state") == "CLOSED" and rg.get("keeps_issue_closed") is True,
      "the dry run does not state that the gate issue STAYS closed")
jr = step(plan, "journal-gate-reconciliation")
check(jr["evidence"]["observed_before"]["gate"] == {"stage": "", "status": "Todo", "issue_state": "CLOSED"},
      f"the planned record does not carry the OBSERVED-BEFORE gate state: {jr['evidence']['observed_before']!r}")
check(jr["evidence"]["approval_pr"] == PR and jr["evidence"]["approval_state"] == "MERGED"
      and jr["evidence"]["door"] == "idc-gate-repair",
      f"the planned record does not carry the merged-PR evidence: {jr['evidence']!r}")
po = step(plan, "record-pointer-observed-already-unblocked")
check(po.get("observed_already_unblocked") is True and po.get("invents_transition") is False,
      f"the dry run does not record #707 as observed-already-unblocked with NO invented transition: {po!r}")
check("unblock-pointer" not in ids(plan), "the dry run plans a FAKE unblock for an already-Todo pointer")
# The plan is the helper's STABLE contract — it must survive the --json surface intact.
check(json.loads(json.dumps(plan)) == plan, "the plan is not JSON-serializable (the --json contract)")
print("  ok (1) the dry run reports the five repair steps in the brief's order")

# 1b. …and it is a TRUE dry run: no board write, no body edit, no journal file.
check(fake.wrote() == [], f"the DRY RUN mutated the board: {fake.wrote()}")
check(not os.path.exists(os.path.join(repo, RP.JOURNAL_REL)),
      "the DRY RUN wrote a journal record (a dry run must never journal)")
check(fake.gate["body"] == prebound_body, "the DRY RUN edited the pre-bound gate body")
print("  ok (1b) the dry run is the DEFAULT and performs no write of any kind")
shutil.rmtree(repo)

# ══ 2. --apply — the honest repair ══════════════════════════════════════════════════════════════
fake, repo = fresh()
plan = plan_of(repair(repo, apply=True))
check(plan.get("mode") == "apply", f"--apply did not report apply mode: {plan.get('mode')!r}")

# 2a. exactly ONE canonical marker remains, and full repair never edits either reciprocal body.
check(fake.gate["body"].count("<!-- idc-gate-pr:") == 1,
      f"the gate body does not carry EXACTLY one idc-gate-pr marker: {fake.gate['body']!r}")
check(f"<!-- idc-gate-pr: {PR} -->" in fake.gate["body"], "the pre-bound marker does not bind PR #706")
check(not [c for c in fake.calls if c[0] == "gh" and c[1][:2] == ("issue", "edit")],
      "full repair bypassed idc_pr_gate_bind.py with a direct body edit")
print("  ok (2a) --apply requires the binder's marker and performs no body edit")

# 2b. Stage/Status repaired through the board helpers; the issue is never re-opened or re-closed.
check(fake.gate["stage"] == "Buildable" and fake.gate["status"] == "Done",
      f"the gate was not repaired to Buildable/Done: {fake.gate['stage']!r}/{fake.gate['status']!r}")
check(fake.gate["issue_state"] == "CLOSED", "the repair changed the gate's issue close state")
check(("set", GATE, "Stage", "Buildable") in fake.calls and ("set", GATE, "Status", "Done") in fake.calls,
      f"Stage/Status were not written through the board helpers: {fake.calls}")
print("  ok (2b) --apply repairs Stage/Status through the existing helpers, issue stays CLOSED")

# 2c. the gate's journal record: op/who/to/evidence exactly per the contract.
entries = journal(repo)
grecs = [e for e in entries if e.get("op") == "gate-reconciliation" and RP.journal_item_id(e) == GATE]
check(len(grecs) == 1, f"expected exactly ONE gate-reconciliation record for #708, got {len(grecs)}")
g = grecs[0]
check(g.get("who") == "gate-repair", f"the record's who is {g.get('who')!r}, expected 'gate-repair'")
check(g.get("to") == {"stage": "Buildable", "status": "Done"},
      f"the record's `to` is {g.get('to')!r}, expected Buildable/Done")
ev = g.get("evidence") or {}
for k in ("door", "approval_pr", "approval_state", "observed_before", "repairs_applied"):
    check(k in ev, f"the record's evidence lacks {k!r}: {ev!r}")
check(ev["door"] == "idc-gate-repair" and ev["approval_pr"] == PR and ev["approval_state"] == "MERGED",
      f"the record's evidence does not name the repair door + merged PR: {ev!r}")
check(ev["observed_before"]["gate"] == {"stage": "", "status": "Todo", "issue_state": "CLOSED"},
      f"the record does not preserve the observed-before CORRUPT state: {ev['observed_before']!r}")
check(sorted(ev["repairs_applied"]) == ["stage", "status"],
      f"repairs_applied does not list what this run actually repaired: {ev['repairs_applied']!r}")
print("  ok (2c) the gate record carries op=gate-reconciliation, who, to, and the full evidence")

# 2d. the pointer's record: an OBSERVATION — no `to` state, so replay can read no invented transition.
precs = [e for e in entries if e.get("op") == "gate-reconciliation" and RP.journal_item_id(e) == POINTER]
check(len(precs) == 1, f"expected exactly ONE gate-reconciliation record for pointer #707, got {len(precs)}")
p = precs[0]
check((p.get("evidence") or {}).get("observed_already_unblocked") is True,
      f"the pointer record does not carry observed_already_unblocked: {p.get('evidence')!r}")
check("to" not in p, f"the pointer record carries a `to` state — an INVENTED transition: {p.get('to')!r}")
check(RP._entry_to_state(p) == {},
      "replay can read a state transition out of the pointer record (it must establish none)")
print("  ok (2d) the pointer record is a pure observation — no `to`, no invented transition")

# 2e. NO fabricated history: no op=dispose, no op=unblock anywhere.
check(not [e for e in entries if e.get("op") == "dispose"],
      "the repair FABRICATED an op=dispose record (it must never claim the guarded door ran)")
check(not [e for e in entries if e.get("op") == "unblock"],
      "the repair FABRICATED an op=unblock for a pointer that was ALREADY Todo")
check(not [c for c in fake.calls if c[0] == "remove-dep"],
      "the repair removed a dependency for an already-unblocked pointer")
print("  ok (2e) no fabricated op=dispose and no fabricated op=unblock for the already-Todo pointer")

# 2f. the record is now the gate's PROOF — and the pointer's observation proves nothing.
check(P.proof_kind(entries, GATE) == "verified-reconciliation",
      f"the repaired gate does not read as verified-reconciliation: {P.proof_kind(entries, GATE)!r}")
check(P.proof_kind(entries, POINTER) == "unproven",
      "the POINTER's observation record launders a gate proof for #707 — an observation is not an approval")
print("  ok (2f) the gate reads verified-reconciliation; the pointer observation proves nothing")

# ══ 3. RERUN — reconstructs from CURRENT state: a full no-op, never a double-stamp/double-record ══
before = len(journal(repo))
plan = plan_of(repair(repo, apply=True))
check(step(plan, "verify-gate-pr-binding")["status"] == "satisfied",
      "a rerun re-stamps the body marker instead of reading it satisfied")
check(step(plan, "repair-gate-fields")["status"] == "satisfied",
      "a rerun re-writes Stage/Status instead of reading them satisfied")
check(step(plan, "journal-gate-reconciliation")["status"] == "satisfied",
      "a rerun re-journals the reconciliation instead of reading the existing proof satisfied")
check(fake.gate["body"].count("<!-- idc-gate-pr:") == 1,
      f"a rerun DOUBLE-STAMPED the body marker: {fake.gate['body']!r}")
check(len(journal(repo)) == before, "a rerun appended duplicate journal records")
print("  ok (3) a rerun reconstructs the remaining plan from current state — a clean no-op")

# 3a. a gate already proven by the GUARDED door needs no reconciliation record at all.
entries = journal(repo) + [{"op": "dispose", "disposition": "gate-approved", "item": 4242,
                            "what": "dispose #4242 Todo -> Done [gate-approved]"}]
check(P.proof_kind(entries, 4242) == "guarded-dispose",
      "a journaled guarded dispose no longer reads as guarded-dispose")
print("  ok (3a) a guarded dispose still reads guarded-dispose (the reconciliation kind is additive)")
shutil.rmtree(repo)

# ══ 4. REFUSALS — every precondition, and NOT ONE write on any of them ══════════════════════════
def refuses(mutate, needle, why, **kw):
    fake, repo = fresh(mutate)
    try:
        repair(repo, apply=True, **kw)
    except R.GateRepairError as exc:
        check(needle in str(exc), f"{why}: refused with the wrong reason: {exc}")
    else:
        die(f"{why}: the repair did NOT refuse")
    check(fake.wrote() == [], f"{why}: the repair mutated the board before refusing: {fake.wrote()}")
    check(not os.path.exists(os.path.join(repo, RP.JOURNAL_REL)), f"{why}: the refusal still journaled")
    shutil.rmtree(repo)

refuses(lambda fx: fx["gate"].update(title="implement the drive foundation"), "operator-action",
        "(4a) a NON-gate title")
print("  ok (4a) a non-gate title is refused (only an [operator-action] gate is reconciled)")

refuses(lambda fx: fx["gate"].update(title="[operator-action] Decision — choose a data store"),
        "Requirements change", "(4a-decision) a decision gate")
print("  ok (4a-decision) a decision gate is refused before any write (full repair is requirements-only)")

refuses(lambda fx: fx["gate"].update(title="[operator-action] Rotate the staging certificate"),
        "Requirements change", "(4a-arbitrary) an arbitrary operator-action gate")
print("  ok (4a-arbitrary) an arbitrary operator-action gate is refused before any write")

refuses(lambda fx: fx["pr"].update(state="OPEN"), "not merged", "(4b) an UNMERGED approval PR")
print("  ok (4b) an unmerged PR is refused (the approval must be real)")

refuses(lambda fx: fx["gate"].update(body="body\n<!-- idc-gate-pr: 999 -->"), "999",
        "(4c) a marker bound to a FOREIGN PR")
print("  ok (4c) an existing marker for another PR is refused (never re-bind an approval)")

refuses(lambda fx: fx["gate"].update(body=f"<!-- idc-gate-pr: {PR} -->\nx\n<!-- idc-gate-pr: {PR} -->"),
        "2 idc-gate-pr markers", "(4d) MORE THAN ONE body marker")
print("  ok (4d) more than one body marker is refused (an ambiguous binding never resolves silently)")

refuses(lambda fx: fx["gate"].update(body=FIXTURE["gate"]["body"]), "idc_pr_gate_bind.py",
        "(4d-markerless) a markerless legacy gate")
print("  ok (4d-markerless) a markerless gate is refused before writes and routed through the reciprocal binder")

refuses(lambda fx: fx["gate"].update(issue_state="OPEN"), "OPEN",
        "(4e) an OPEN gate (the guarded dispose door owns that, not this repair)")
print("  ok (4e) an OPEN gate is refused — the guarded dispose door owns an open gate")

# 4f. a marker ALREADY correctly bound to #706 is NOT a refusal — it is simply satisfied.
fake, repo = fresh(lambda fx: fx["gate"].update(body=f"TO APPROVE: merge the Think PR.\n<!-- idc-gate-pr: {PR} -->"))
plan = plan_of(repair(repo, apply=True))
check(step(plan, "verify-gate-pr-binding")["status"] == "satisfied",
      "an already-correct marker was not read as satisfied")
check(fake.gate["body"].count("<!-- idc-gate-pr:") == 1, "an already-correct marker was double-stamped")
print("  ok (4f) a marker already bound to the right PR is satisfied, not re-stamped")
shutil.rmtree(repo)

# ══ 5. A STILL-BLOCKED pointer: the gate proof is journaled FIRST, then the ENGINE's real unblock ═
def still_blocked(fx):
    fx["pointer"].update(status="Blocked", blocked_by=[GATE])

fake, repo = fresh(still_blocked)
plan = plan_of(repair(repo, apply=True))
check("unblock-pointer" in ids(plan),
      f"a still-Blocked pointer did not get the engine's real unblock step: {ids(plan)}")
check("record-pointer-observed-already-unblocked" not in ids(plan),
      "a still-BLOCKED pointer was recorded as observed-already-unblocked (a false observation)")
check(fake.pointer["status"] == "Todo", "the still-Blocked pointer was not unblocked to Todo")
check(fake.pointer["blocked_by"] == [], "the gate dependency edge was not removed by the engine unblock")

entries = journal(repo)
ops = [e.get("op") for e in entries]
check("unblock" in ops, f"the engine's REAL unblock was not journaled: {ops}")
check(not [e for e in entries if e.get("op") == "dispose"], "the repair fabricated an op=dispose")
print("  ok (5) a still-Blocked pointer is finished through the engine's REAL journaled unblock")

# 5b. ORDER: the gate's proof record precedes the unblock — never unblock on an unproven gate.
gate_at = next(i for i, e in enumerate(entries)
               if e.get("op") == "gate-reconciliation" and RP.journal_item_id(e) == GATE)
unblock_at = next(i for i, e in enumerate(entries) if e.get("op") == "unblock")
check(gate_at < unblock_at,
      f"the unblock (index {unblock_at}) was journaled BEFORE the gate proof (index {gate_at}) — "
      "the proof must be written FIRST")
print("  ok (5b) the gate proof is journaled BEFORE the unblock, never after")
shutil.rmtree(repo)

# ══ 6. PARTIAL FAILURE — a write whose readback diverges STOPS the run and NAMES the readback ════
fake, repo = fresh()
fake.sabotage = (GATE, "Status")          # the Status write silently does not land
try:
    repair(repo, apply=True)
except R.GateRepairError as exc:
    msg = str(exc)
    check("read-back" in msg or "readback" in msg, f"the partial failure does not name a readback: {msg}")
    check("Status" in msg, f"the partial failure does not name WHICH readback failed: {msg}")
    check("#708" in msg or "708" in msg, f"the partial failure does not name the item: {msg}")
else:
    die("(6) a write whose readback diverged did NOT stop the repair")
# The proof must NOT exist: we stopped before the record, so nothing claims a repair that half-landed.
check(P.proof_kind(journal(repo), GATE) == "unproven",
      "a PARTIAL repair still journaled a gate proof — a half-landed repair must never read as proven")
print("  ok (6) a diverged readback stops the repair, names the failed readback, and journals no proof")

# 6b. …and the RERUN reconstructs the remaining plan from current state and finishes the job.
fake.sabotage = None
plan = plan_of(repair(repo, apply=True))
check(step(plan, "verify-gate-pr-binding")["status"] == "satisfied",
      "the rerun after a partial failure re-stamped the already-landed marker")
check(step(plan, "repair-gate-fields")["status"] == "applied",
      "the rerun after a partial failure did not finish the unlanded Status write")
check(fake.gate["status"] == "Done", "the rerun did not land Status=Done")
check(P.proof_kind(journal(repo), GATE) == "verified-reconciliation",
      "the rerun did not journal the gate proof once the repair genuinely completed")
check(fake.gate["body"].count("<!-- idc-gate-pr:") == 1, "the rerun double-stamped the marker")
print("  ok (6b) the rerun reconstructs the remaining plan from current state and completes the repair")
shutil.rmtree(repo)

# ══ 7. proof_kind — the centralized reader's contract ════════════════════════════════════════════
REC = lambda **kw: dict({"op": "gate-reconciliation", "item": GATE,
                         "evidence": {"door": "idc-gate-repair", "approval_pr": PR,
                                      "approval_state": "MERGED"}}, **kw)
check(P.proof_kind([REC()], GATE) == "verified-reconciliation", "(7a) a full reconciliation record")
check(P.proof_kind([], GATE) == "unproven", "(7b) an empty journal must be unproven")
print("  ok (7a/7b) a complete record proves; an empty journal is unproven")

# 7c. every evidence field is LOAD-BEARING — drop or corrupt any one and the proof collapses.
for bad, why in (
    ({"door": "somewhere-else", "approval_pr": PR, "approval_state": "MERGED"}, "a foreign door"),
    ({"approval_pr": PR, "approval_state": "MERGED"}, "a missing door"),
    ({"door": "idc-gate-repair", "approval_pr": PR, "approval_state": "OPEN"}, "an UNMERGED approval"),
    ({"door": "idc-gate-repair", "approval_pr": PR}, "a missing approval_state"),
    ({"door": "idc-gate-repair", "approval_pr": 0, "approval_state": "MERGED"}, "a zero approval_pr"),
    ({"door": "idc-gate-repair", "approval_pr": True, "approval_state": "MERGED"}, "a boolean approval_pr"),
    ({"door": "idc-gate-repair", "approval_pr": 77.5, "approval_state": "MERGED"}, "a float approval_pr"),
    ({"door": "idc-gate-repair", "approval_pr": "77", "approval_state": "MERGED"}, "a string approval_pr"),
    ({"door": "idc-gate-repair", "approval_state": "MERGED"}, "a missing approval_pr"),
    ({}, "empty evidence"),
):
    got = P.proof_kind([REC(evidence=bad)], GATE)
    check(got == "unproven", f"(7c) {why} still proved the gate: {got!r}")
print("  ok (7c) every evidence field is load-bearing — a partial/forged record proves nothing")

# 7d. a record for ANOTHER gate never proves this one.
check(P.proof_kind([REC(item=4242)], GATE) == "unproven",
      "(7d) a reconciliation record for another gate proved this gate")
print("  ok (7d) a record naming another gate never proves this one")

# 7e. a MALFORMED journal is an ERROR, never `unproven` (a damaged journal must not read as a clean
#     negative either — the caller must distinguish "no proof" from "cannot tell").
repo = new_repo()
open(os.path.join(repo, RP.JOURNAL_REL), "w").write("NOT-JSON {\n")
kind, err = P.read_proof(repo, GATE)
check(err is not None and kind is None,
      f"a MALFORMED journal did not ERROR: kind={kind!r} err={err!r} (it must never read as unproven)")
print("  ok (7e) a malformed journal is an ERROR, never a silent `unproven`")
shutil.rmtree(repo)

# ══ 9. A PROOF THAT DID NOT LAND DURABLY STOPS THE REPAIR ════════════════════════════════════════
# `journal_append` is FAIL-SOFT BY DESIGN — it returns False when durability fails and the ENGINE
# ignores that (a journal failure must never fail a board op; reconciliation is the engine's
# detector). For THIS helper the record IS the product: the gate's only proof. Ignoring the False
# would leave the gate `unproven` ON DISK while its pointer is admitted — and report success.
# Probe (real writer, real failure): make the journal file unwritable, so the append genuinely
# fails and returns False. A still-Blocked pointer makes a wrongly-run unblock OBSERVABLE.
fake, repo = fresh(still_blocked)
jpath = os.path.join(repo, RP.JOURNAL_REL)
open(jpath, "w").close()
os.chmod(jpath, 0o444)
if os.geteuid() == 0 or os.access(jpath, os.W_OK):
    # root ignores the mode bits, so the failure cannot be staged — say so LOUDLY rather than
    # reporting a pass that never exercised the guard.
    print("  SKIP (9) journal-durability: the journal is STILL WRITABLE after chmod 444 "
          "(running as root?) — the failed-append probe could not be staged in this environment")
else:
    try:
        repair(repo, apply=True)
    except R.GateRepairError as exc:
        msg = str(exc)
        check("transition-journal" in msg,
              f"(9) the stop does not name the JOURNAL that failed: {msg}")
        check("gate-reconciliation" in msg,
              f"(9) the stop does not name the STEP that failed: {msg}")
    else:
        die("(9) a gate proof that did NOT land durably did not stop the repair — the gate is "
            "unproven on disk while the helper reports success")
    # the unblock NEVER ran: the pointer is untouched behind its still-unproven gate.
    check(fake.pointer["status"] == "Blocked",
          f"(9) the pointer was UNBLOCKED behind a gate whose proof never landed: "
          f"{fake.pointer['status']!r}")
    check(fake.pointer["blocked_by"] == [GATE],
          f"(9) the gate dependency edge was removed despite the unlanded proof: "
          f"{fake.pointer['blocked_by']!r}")
    check(not [c for c in fake.calls if c[0] == "remove-dep"],
          "(9) the repair removed a dependency behind a gate whose proof never landed")
    check(journal(repo) == [],
          f"(9) a record landed in a journal that cannot be written: {journal(repo)!r}")
    check(R.cli(repair_argv(repo, apply=True)) != 0, "(9) the stopped repair did not exit NONZERO")
    print("  ok (9) a gate proof that did not land durably STOPS the repair before the unblock")

    # 9b. restore write permission → the rerun converges (the stop is recoverable, per the brief's
    #     partial-failure contract: a rerun reconstructs the remainder from current state).
    os.chmod(jpath, 0o644)
    plan = plan_of(repair(repo, apply=True))
    check(P.proof_kind(journal(repo), GATE) == "verified-reconciliation",
          "(9b) the rerun did not journal the gate proof once the journal was writable again")
    check(fake.pointer["status"] == "Todo", "(9b) the rerun did not finish the unblock")
    check(fake.gate["body"].count("<!-- idc-gate-pr:") == 1, "(9b) the rerun double-stamped the marker")
    print("  ok (9b) once the journal is writable again, a rerun converges")
shutil.rmtree(repo)

# ══ 10. OTHER BLOCKERS REMAIN — the gate-side repairs land, the POINTER step REFUSES ═════════════
# The engine's `unblock --by` removes the NAMED dependency and then sets Todo; it does not check
# whether OTHER blockers remain (engine internals are out of scope here). So repairing one gate of a
# multi-gate pointer would sail the pointer past gate #999 without its proof — and Autorun treats an
# unblocked Consideration pointer as approved work. This helper must never mint that.
SECOND = 999


def multi_blocked(fx):
    fx["pointer"].update(status="Blocked", blocked_by=[GATE, SECOND])


# 10a. the DRY RUN must SHOW the refusal — a dry run must never promise an apply that would refuse.
fake, repo = fresh(multi_blocked)
plan = plan_of(repair(repo))
s5 = step(plan, "unblock-pointer")
check(str(SECOND) in json.dumps(s5),
      f"(10a) the dry-run pointer step does not NAME the remaining blocker #999: {s5!r}")
check(s5.get("status") == "refused",
      f"(10a) the dry run PROMISES an unblock it would refuse on apply: status={s5.get('status')!r}")
check(fake.wrote() == [], f"(10a) the dry run mutated the board: {fake.wrote()}")
print("  ok (10a) the dry run SHOWS the pointer refusal pending the other blockers")
shutil.rmtree(repo)

# 10b. --apply: the gate-side repairs land (independently true), the pointer step REFUSES.
fake, repo = fresh(multi_blocked)
try:
    repair(repo, apply=True)
except R.GateRepairError as exc:
    msg = str(exc)
    check(str(SECOND) in msg, f"(10b) the refusal does not NAME the remaining blocker #999: {msg}")
else:
    die("(10b) the repair proceeded on a pointer that gate #999 still blocks — it would sail past "
        "#999 without its proof")
check(fake.pointer["status"] == "Blocked",
      f"(10b) the pointer left Blocked while #999 still blocks it: {fake.pointer['status']!r}")
check(SECOND in fake.pointer["blocked_by"],
      f"(10b) the remaining blocker's dependency edge was removed: {fake.pointer['blocked_by']!r}")
check(not [c for c in fake.calls if c[0] == "remove-dep"],
      "(10b) the repair invented a dependency removal — no sanctioned dependency-only door exists")
entries = journal(repo)
check(not [e for e in entries if e.get("op") == "unblock"],
      "(10b) the repair journaled an unblock for a pointer another gate still blocks")
check(not [e for e in entries if (e.get("evidence") or {}).get("observed_already_unblocked")],
      "(10b) the repair recorded observed_already_unblocked for a pointer that is still BLOCKED — "
      "nothing was observed unblocked")
# …while the gate-side repairs DID land: they are independently true, and a rerun converges.
check(fake.gate["stage"] == "Buildable" and fake.gate["status"] == "Done",
      f"(10b) the gate-side repairs did not land: {fake.gate['stage']!r}/{fake.gate['status']!r}")
check(P.proof_kind(entries, GATE) == "verified-reconciliation",
      "(10b) the gate's own reconciliation record did not land — it is true regardless of the pointer")
check(R.cli(repair_argv(repo, apply=True)) != 0, "(10b) the pointer refusal did not exit NONZERO")
print("  ok (10b) other blockers ⇒ gate repairs land, the pointer step refuses naming #999, exit nonzero")

# 10c. once #999 is resolved through its OWN door (its edge removed, the pointer still Blocked), a
#      rerun converges — the gate is now the SOLE remaining blocker.
fake.pointer["blocked_by"] = [GATE]
plan = plan_of(repair(repo, apply=True))
check(fake.pointer["status"] == "Todo",
      f"(10c) the rerun did not finish the unblock once the gate was the sole blocker: "
      f"{fake.pointer['status']!r}")
check(fake.pointer["blocked_by"] == [], "(10c) the gate's dependency edge was not removed")
check("unblock" in [e.get("op") for e in journal(repo)],
      "(10c) the engine's real unblock was not journaled on the converging rerun")
print("  ok (10c) once the other blockers are resolved, a rerun converges through the engine's unblock")
shutil.rmtree(repo)

# ══ 11. THE POINTER-FINISH DOOR — the recovery the FOUR stage playbooks instruct ═════════════════
# Wave 1 sealed THIS helper's own pointer step, but the interrupted-run recovery in agents/idc-plan,
# idc-recirculator, idc-autorun + skills/idc-gate-issue still said "verify the gate's proof, then
# finish the unblock through the engine's journaled `unblock`" — and the engine's `unblock --by`
# drops only the NAMED edge before setting Todo. Reviewer probe (round 2, verbatim): gate #708 proven,
# pointer #707 Blocked by [708, 999] → the playbook-instructed raw unblock produced
# `status='Todo', blocked_by=[999], journal op='unblock'` — #707 admitted past gate #999 without its
# proof, the round-1 incident resurfacing through the normal recovery surface. So the playbooks route
# that finish through THIS door instead, and the door enforces both halves of the contract: the gate's
# proof must be ON DISK, and the proven gate must be the SOLE remaining blocker.
#
# Red-when-broken: drop the sole-blocker re-read → 11b FAILs (the reviewer's probe goes green again).
def proven(repo, kind="verified-reconciliation", gate=GATE):
    """Journal `gate`'s proof through the REAL writer — the state a completed repair leaves on disk."""
    if kind == "verified-reconciliation":
        kw = {"num": gate, "agent": "gate-repair", "to_stage": "Buildable", "to_status": "Done",
              "disposition_evidence": {"door": "idc-gate-repair", "approval_pr": PR,
                                       "approval_state": "MERGED"}}
        E.journal_append(repo, "gate-reconciliation", "github", None, kw)
    else:                                    # the guarded door's own record — the stronger kind
        E.journal_append(repo, "dispose", "github", None,
                         {"num": gate, "agent": "gate", "disposition": "gate-approved"})
    check(P.proof_kind(journal(repo), gate) in P.PROVEN_KINDS, "the probe did not seed a proven gate")


def finish_argv(repo, apply=False, gate=GATE, pointer=POINTER, pr=None):
    argv = ["--repo", repo, "--backend", "github", "--owner", OWNER, "--project", PROJECT,
            "--finish-pointer", "--gate", str(gate), "--pointer", str(pointer)]
    if pr is not None:
        argv += ["--pr", str(pr)]
    if apply:
        argv.append("--apply")
    return argv


def finish(repo, apply=False, gate=GATE, pointer=POINTER, pr=None):
    return R.main(finish_argv(repo, apply=apply, gate=gate, pointer=pointer, pr=pr))


# 11a. the sole-blocker case: a DRY RUN plans it and writes nothing; --apply finishes it through the
#      engine's REAL journaled unblock — and this door journals NO record of its own.
fake, repo = fresh(still_blocked)
proven(repo)
before = len(journal(repo))
plan = plan_of(finish(repo))
check(plan.get("mode") == "dry-run", f"(11a) a bare --finish-pointer run is not a dry run: {plan.get('mode')!r}")
check(step(plan, "verify-gate-proof")["proof_kind"] == "verified-reconciliation",
      f"(11a) the door does not report the gate's proof kind: {step(plan, 'verify-gate-proof')!r}")
check(step(plan, "unblock-pointer")["status"] == "planned",
      f"(11a) the dry run does not PLAN the sole-blocker unblock: {step(plan, 'unblock-pointer')!r}")
check(fake.wrote() == [] and len(journal(repo)) == before, f"(11a) the DRY RUN wrote: {fake.wrote()}")

plan = plan_of(finish(repo, apply=True))
check(step(plan, "unblock-pointer")["status"] == "applied", "(11a) --apply did not finish the pointer")
check(fake.pointer["status"] == "Todo", f"(11a) the pointer was not unblocked: {fake.pointer['status']!r}")
check(fake.pointer["blocked_by"] == [], "(11a) the gate's dependency edge was not removed")
entries = journal(repo)
check([e.get("op") for e in entries if RP.journal_item_id(e) == POINTER] == ["unblock"],
      f"(11a) the engine's REAL unblock is not the pointer's only record: {[e.get('op') for e in entries]}")
check(len([e for e in entries if e.get("op") == "gate-reconciliation"]) == 1,
      "(11a) the pointer-finish door wrote a reconciliation record of its own — it repairs nothing "
      "and observes nothing new; only the engine's unblock may journal here")
print("  ok (11a) pointer-finish: dry-run-first, then the engine's REAL unblock on a sole-blocker gate")
shutil.rmtree(repo)

# 11b. THE REVIEWER'S PROBE: other blockers remain ⇒ REFUSE, naming them. Nothing written.
fake, repo = fresh(multi_blocked)
proven(repo)
before = journal(repo)
plan = plan_of(finish(repo))
check(step(plan, "unblock-pointer")["status"] == "refused",
      f"(11b) the dry run PROMISES an unblock it would refuse on apply: {step(plan, 'unblock-pointer')!r}")
check(str(SECOND) in json.dumps(step(plan, "unblock-pointer")),
      "(11b) the dry-run pointer step does not NAME the remaining blocker #999")
try:
    finish(repo, apply=True)
except R.GateRepairError as exc:
    check(str(SECOND) in str(exc), f"(11b) the refusal does not NAME the remaining blocker #999: {exc}")
else:
    die("(11b) the pointer-finish door freed #707 past gate #999 without its proof — the reviewer's "
        "round-2 probe (status='Todo', blocked_by=[999], journal op='unblock')")
check(fake.pointer["status"] == "Blocked",
      f"(11b) the pointer was admitted past #999: {fake.pointer['status']!r}")
check(SECOND in fake.pointer["blocked_by"], "(11b) the remaining blocker's edge was removed")
check(not [c for c in fake.calls if c[0] == "remove-dep"],
      "(11b) the door invented a dependency removal — no sanctioned dependency-only door exists")
check(journal(repo) == before, f"(11b) the refusal journaled a record: {journal(repo)!r}")
check(R.cli(finish_argv(repo, apply=True)) != 0, "(11b) the pointer refusal did not exit NONZERO")
print("  ok (11b) pointer-finish REFUSES while another blocker remains — the reviewer's probe, sealed")
shutil.rmtree(repo)

# 11c. an UNPROVEN gate is refused, pointing at the full repair door (never a bare unblock).
fake, repo = fresh(still_blocked)
open(os.path.join(repo, RP.JOURNAL_REL), "w").close()          # readable, but holds no proof
try:
    finish(repo, apply=True)
except R.GateRepairError as exc:
    check("unproven" in str(exc), f"(11c) the refusal does not name the UNPROVEN gate: {exc}")
    check("idc_gate_repair.py" in str(exc) or "--apply" in str(exc),
          f"(11c) the refusal does not point at the full repair door: {exc}")
else:
    die("(11c) the pointer-finish door unblocked behind an UNPROVEN gate")
check(fake.pointer["status"] == "Blocked", "(11c) the pointer moved behind an unproven gate")
check(fake.wrote() == [] and journal(repo) == [], f"(11c) the refusal wrote: {fake.wrote()}")
print("  ok (11c) pointer-finish refuses behind an unproven gate and points at the full repair door")
shutil.rmtree(repo)

# 11d. an already-Todo pointer is an HONEST NO-OP: exit 0, say so, write NOTHING (this door observes
#      nothing new — the observation record belongs to the full repair, which reads the corrupt shape).
fake, repo = fresh()                                            # the fixture's pointer is already Todo
proven(repo)
before = journal(repo)
plan = plan_of(finish(repo, apply=True))
check(step(plan, "unblock-pointer")["status"] == "satisfied",
      f"(11d) an already-Todo pointer is not reported satisfied: {step(plan, 'unblock-pointer')!r}")
check(fake.wrote() == [], f"(11d) the no-op wrote to the board: {fake.wrote()}")
check(journal(repo) == before, f"(11d) the no-op journaled a record: {journal(repo)!r}")
check(R.cli(finish_argv(repo, apply=True)) == 0, "(11d) the honest no-op did not exit 0")
print("  ok (11d) an already-Todo pointer is an honest no-op: exit 0, nothing written")
shutil.rmtree(repo)

# 11e. an INDETERMINATE journal is never a clean negative — and never an unblock.
fake, repo = fresh(still_blocked)
open(os.path.join(repo, RP.JOURNAL_REL), "w").write("NOT-JSON {\n")
try:
    finish(repo, apply=True)
except R.GateRepairError as exc:
    check("cannot be read" in str(exc) or "INDETERMINATE" in str(exc),
          f"(11e) an unreadable journal did not raise the indeterminate refusal: {exc}")
else:
    die("(11e) the pointer-finish door acted on a journal it could not read")
check(fake.pointer["status"] == "Blocked", "(11e) the pointer moved on an indeterminate proof")
print("  ok (11e) pointer-finish fails closed on an unreadable journal — indeterminate is not proof")
shutil.rmtree(repo)

# 11f. this mode repairs NOTHING, so it takes no --pr: an approval PR here could only mislead.
fake, repo = fresh(still_blocked)
proven(repo)
try:
    finish(repo, apply=True, pr=PR)
except R.GateRepairError as exc:
    check("--pr" in str(exc), f"(11f) the refusal does not name --pr: {exc}")
else:
    die("(11f) the pointer-finish door accepted a --pr — it repairs nothing and verifies no approval")
check(fake.pointer["status"] == "Blocked", "(11f) the rejected invocation still moved the pointer")
print("  ok (11f) pointer-finish takes no --pr — it finishes an ALREADY-proven gate's pointer")
shutil.rmtree(repo)

# 11g. the GUARDED-DISPOSE kind is proof too (the fs/github mainline): both proven kinds finish.
fake, repo = fresh(still_blocked)
proven(repo, kind="guarded-dispose")
plan = plan_of(finish(repo, apply=True))
check(step(plan, "verify-gate-proof")["proof_kind"] == "guarded-dispose",
      "(11g) the door does not report the guarded-dispose kind")
check(fake.pointer["status"] == "Todo", "(11g) a guarded-dispose gate's pointer was not finished")
print("  ok (11g) either proven kind finishes the pointer — guarded-dispose and verified-reconciliation")
shutil.rmtree(repo)

# 11h. Todo plus residual blocked_by is internally inconsistent, not an honest no-op/observation.
def todo_with_stale_edges(fx):
    fx["pointer"].update(status="Todo", blocked_by=[GATE, SECOND])

fake, repo = fresh(todo_with_stale_edges)
proven(repo)
before = journal(repo)
try:
    finish(repo, apply=True)
except R.GateRepairError as exc:
    check("Todo" in str(exc) and "block" in str(exc), f"(11h) unclear pointer-finish refusal: {exc}")
else:
    die("(11h) pointer-finish accepted Todo with residual blocked_by edges")
check(journal(repo) == before and fake.wrote() == [], "(11h) pointer-finish wrote despite inconsistent state")
shutil.rmtree(repo)

fake, repo = fresh(todo_with_stale_edges)
try:
    repair(repo, apply=True)
except R.GateRepairError as exc:
    check("Todo" in str(exc) and "block" in str(exc), f"(11h) unclear full-repair refusal: {exc}")
else:
    die("(11h) full repair recorded an observation for Todo with residual blockers")
check(not any((e.get("evidence") or {}).get("observed_already_unblocked") for e in journal(repo)),
      "(11h) full repair journaled a false already-unblocked observation")
print("  ok (11h) Todo with residual blockers is refused; only blocker-free Todo is observable/no-op")
shutil.rmtree(repo)

print("  ok — the session-b7a93ff6 unit is green")
PY

# ── 8. the CLI contracts the brief names (the surfaces the playbooks call) ──────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs/workflow"

# 8a. proof CLI on a journal with NO proof → unproven, exit 0 (a clean, readable negative).
: > "$TMP/docs/workflow/transition-journal.ndjson"
OUT="$(python3 "$PROOF" --repo "$TMP" --gate 708 --json)"; RC=$?
[ $RC -eq 0 ] || gov_fail "idc_gate_proof.py exited $RC on a readable journal: $OUT"
echo "$OUT" | grep -q '"proof_kind": *"unproven"' \
  || gov_fail "the proof CLI did not report unproven on a journal with no proof: $OUT"
echo "  ok (8a) idc_gate_proof.py --repo R --gate G --json reports unproven on a readable journal"

# 8b. proof CLI on a MALFORMED journal → non-zero + an explicit error, NEVER a quiet `unproven`.
printf 'NOT-JSON {\n' > "$TMP/docs/workflow/transition-journal.ndjson"
OUT="$(python3 "$PROOF" --repo "$TMP" --gate 708 --json 2>&1)"; RC=$?
[ $RC -ne 0 ] || gov_fail "the proof CLI exited 0 on a MALFORMED journal (it must fail closed): $OUT"
echo "$OUT" | grep -q 'unproven' \
  && gov_fail "the proof CLI reported 'unproven' for a MALFORMED journal (an error is not a negative): $OUT"
echo "  ok (8b) a malformed journal fails the proof CLI closed — never a quiet 'unproven'"

# 8c. the repair CLI defaults to a DRY RUN: no --apply anywhere in its own usage default.
python3 "$REPAIR" --help 2>&1 | grep -q -- '--apply' \
  || gov_fail "idc_gate_repair.py exposes no --apply flag (dry-run-first is the whole contract)"
echo "  ok (8c) idc_gate_repair.py exposes the dry-run-first --apply contract"

# ── 12. the pointer-finish door on the FILESYSTEM backend — no fakes, a REAL TRACKER.md ─────────
# The four playbooks this door now backs are backend-agnostic, and a filesystem gate earns REAL
# `guarded-dispose` proof through its own guarded door (on fs the operator's approval signal IS the
# gate reaching `Done` through `dispose --disposition gate-approved` — idc-gate-issue/SKILL.md,
# "Approval signal by backend"). So this recovery is reachable on fs, and the sole-blocker guard must
# hold there too, against the real engine and a real tracker.
T3="$(gov_new_tracker)" || gov_fail "could not mint the fs tracker"
FSREPO="$(dirname "$T3")"
trap 'rm -rf "$TMP" "$FSREPO"' EXIT
mkdir -p "$FSREPO/docs/workflow"
FS_GATE="$(gov_seed_item "$T3" --title '[operator-action] Requirements — fs gate' --stage Buildable --status Done)" \
  || gov_fail "could not seed the fs gate"
FS_DEP="$(gov_seed_item "$T3" --title 'fs consideration pointer' --stage Consideration --status Blocked \
  --blocked-by "$FS_GATE,999")" || gov_fail "could not seed the fs dependent"
# the fs gate's proof, through the engine's REAL journal writer (what its guarded dispose leaves).
python3 - "$GOV_PLUGIN/scripts" "$FSREPO" "$FS_GATE" <<'PY' || gov_fail "could not journal the fs gate's proof"
import sys
sys.path.insert(0, sys.argv[1])
import idc_transition as E
ok = E.journal_append(sys.argv[2], "dispose", "filesystem", "TRACKER.md",
                      {"num": int(sys.argv[3]), "agent": "gate", "disposition": "gate-approved"})
raise SystemExit(0 if ok else 1)
PY

# 12a. the sole-blocker guard holds on fs: #999 still blocks → REFUSE, naming it; nothing moves.
OUT="$(python3 "$REPAIR" --repo "$FSREPO" --backend filesystem --tracker "$T3" --finish-pointer \
  --gate "$FS_GATE" --pointer "$FS_DEP" --apply 2>&1)"; RC=$?
[ $RC -ne 0 ] || gov_fail "(12a) the fs pointer-finish freed #$FS_DEP past gate #999 without its proof: $OUT"
echo "$OUT" | grep -q '999' || gov_fail "(12a) the fs refusal does not NAME the remaining blocker #999: $OUT"
[ "$(gov_field "$T3" "$FS_DEP" Status)" = "Blocked" ] \
  || gov_fail "(12a) the fs pointer left Blocked while #999 still blocks it"
echo "  ok (12a) the fs pointer-finish refuses while another blocker remains, naming #999"

# 12b. …and once #999 is resolved through its own door, the same command converges on fs.
python3 "$GOV_TRK" --tracker "$T3" unlink --parent 999 --child "$FS_DEP" --kind blocks >/dev/null \
  || gov_fail "could not resolve the second fs blocker"
OUT="$(python3 "$REPAIR" --repo "$FSREPO" --backend filesystem --tracker "$T3" --finish-pointer \
  --gate "$FS_GATE" --pointer "$FS_DEP" --apply 2>&1)"; RC=$?
[ $RC -eq 0 ] || gov_fail "(12b) the fs pointer-finish did not converge once the gate was sole blocker: $OUT"
[ "$(gov_field "$T3" "$FS_DEP" Status)" = "Todo" ] \
  || gov_fail "(12b) the fs pointer was not finished through the engine's unblock: $OUT"
grep -q '"op": "unblock"' "$FSREPO/docs/workflow/transition-journal.ndjson" \
  || gov_fail "(12b) the engine's real unblock was not journaled on fs"
echo "  ok (12b) once the other blocker is resolved, the fs pointer-finish converges through the engine"

echo "PASS: the corrupt session-b7a93ff6 gate shape (merged PR #706, gate #708 closed outside the guarded door with no Stage and a Todo Status, pointer #707 already unblocked) is reconciled dry-run-first through the existing board helpers — one bound body marker, Stage/Status repaired with the issue left closed, an op=gate-reconciliation record carrying the observed-before state + merged-PR evidence that reads back as verified-reconciliation — while FABRICATING nothing: no back-dated op=dispose, and no invented op=unblock for a pointer that was already Todo (only a genuinely still-Blocked pointer gets the engine's real unblock, and only after the proof lands first)"
