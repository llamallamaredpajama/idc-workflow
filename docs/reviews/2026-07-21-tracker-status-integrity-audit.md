# Tracker-status integrity audit

- **Date:** 2026-07-21
- **Repository:** `idc-workflow`
- **Branch:** `main`
- **Audited commit:** `71d711ad6be9e5346597ddff8e7cf8dc8df94259`
- **Mode:** Read-only audit except for this report; synthetic mutations were confined to `/tmp`; no GitHub mutations were performed.

## Executive verdict

IDC has strong fail-closed checks **when callers use the sanctioned transition and finish paths**, but it is not an end-to-end status-integrity boundary. Direct filesystem mutation, out-of-envelope GitHub mutation, bounded Stop gates, mutable journals, and shape-valid fabricated receipts can still produce or certify false tracker states.

This matches the stated architectural boundary: IDC is a guardrail rather than a security boundary (`docs/architecture.md:363-366`).

| Threat | Classification | Result |
|---|---|---|
| **T1 — nonterminal operation writes terminal `Done`** | **HARD-BLOCKED** | The transition engine rejects terminal status except through typed terminal operations. |
| **T2 — terminal close/dispose without required receipt** | **HARD-BLOCKED** | Missing, malformed, failing, mismatched, or merge-condition-bearing receipts are refused—subject to T7 authenticity limits. |
| **T3 — raw GitHub mutation bypass** | **ADVISORY overall** | Hard-denied only during an active IDC command and only through recognized Bash commands; otherwise warning/fail-open. |
| **T4 — raw filesystem/TRACKER mutation** | **ADVISORY** | Mutation succeeds. Journal replay and Janitor can detect divergence afterward but do not block normal completion. |
| **T5 — premature lifecycle/Stop completion** | **ADVISORY** | Gates deny three times, then deliberately permit exit with `LOUD-FAIL`; ledger corruption also reads as empty. |
| **T6 — board/reality/recirculator divergence** | **ADVISORY** | Several checks report or checkpoint drift, but raw `Done` can still make drain and autorun closeout report complete. |
| **T7 — forged but concordant evidence/history** | **MISSED** | Schema-valid fake PASS receipts and hand-authored legal journal history are accepted. |

“HARD-BLOCKED” applies to the named sanctioned door. It does not mean an actor with repository or GitHub write access cannot route around that door through T3, T4, or T7.

## T1 — HARD-BLOCKED

The engine rejects terminal status through nonterminal operations:

- Terminal status recognized explicitly: `scripts/idc_transition.py:68-71`
- `create-ticket` cannot mint `Done`: `scripts/idc_transition.py:286-315`
- Generic field operations reject terminal status: `scripts/idc_transition.py:2092-2113`
- YAML policy makes `Done` terminal and legal only through `close` or terminal dispositions: `templates/workflow-machine.yaml:65-68`, `templates/workflow-machine.yaml:135-158`

Verbatim synthetic result:

```text
ENGINE_CREATE_DONE_EXIT=2
idc-transition: illegal transition: create-ticket may not set the terminal Status 'Done' — only a guarded `close` (with a valid, passing, item-owning verdict) may reach it
```

No item was created.

## T2 — HARD-BLOCKED, but only for structural validity

Terminal operations pass through `check_terminal_guards()`:

- Terminal-operation guard entry: `scripts/idc_transition.py:319-376`
- Review receipt loaded and checked: `scripts/idc_transition.py:1621-1650`
- Verdict must be PASS, own the issue/PR, have no merge conditions, and match route: `scripts/idc_transition.py:1651-1668`
- Verdict schema and field validation: `scripts/idc_review_verdict_check.py:79-154`
- Git finisher independently verifies branch, PR, and merge facts: `scripts/idc_git_finish.py:193-240`, `scripts/idc_git_finish.py:255-307`, `scripts/idc_git_finish.py:465-479`

Governance tests confirmed rejection of:

- verdict-free terminal writes
- FAIL verdicts
- wrong issue or PR ownership
- outstanding merge conditions
- readback mismatch
- terminal `Done` through creation or ordinary field operations

These checks establish **receipt consistency**, not that a genuine review happened. That becomes T7.

## T3 — ADVISORY overall

The interlock is effective in its intended active-command scope:

- Hook registered only for `PreToolUse` with matcher `Bash`: `hooks/hooks.json:4-14`
- Active-command raw mutations are denied: `scripts/hooks/idc_interlock_gate.py:1224-1246`
- Raw `gh issue edit/close`, `gh pr merge/edit`, and project mutations are recognized: `scripts/hooks/idc_interlock_gate.py:185-256`
- Outside an active IDC command, the same mutation only warns: `scripts/hooks/idc_interlock_gate.py:1241-1246`
- `IDC_HOOKS_OBSERVE_ONLY=1` disables enforcement: `scripts/hooks/idc_interlock_gate.py:1219-1221`
- Unexpected hook exceptions deliberately fail open: `scripts/hooks/idc_hook_lib.py:191-222`

Synthetic behavior during an active IDC command:

```text
HOOK_ACTIVE_EXIT=0
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "IDC interlock: BLOCKED a raw `gh issue close`. Route the mutation through the centralized transition engine instead: `python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py\" --repo . --op close …`. The current `/idc:*` command is still active and the attempted raw write was not executed."}}
```

Outside the lifecycle envelope:

```text
HOOK_OUTSIDE_EXIT=0
idc-interlock: raw governed mutation observed outside an active /idc:* lifecycle command: a raw `gh issue close`. Use the centralized transition engine: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py" --repo . --op close …`
```

A `Write` payload editing `TRACKER.md`, and a Bash command invoking `idc_tracker_fs.py`, produced no denial. The governance test explicitly expects non-Bash payloads to be ignored (`tests/smoke/governance/interlock-terminal-actions.sh:116-120`).

## T4 — ADVISORY

The filesystem adapter exposes direct mutation commands:

- Raw status move: `scripts/idc_tracker_fs.py:120-161`
- Raw close: `scripts/idc_tracker_fs.py:243-246`

The shipped prose prohibits direct use (`skills/idc-tracker-adapter/SKILL.md:34-40`), but that is an instruction rather than a capability restriction.

Synthetic raw mutation:

```text
RAW_MOVE_EXIT=0
{"issue": 1, "status": "Done"}
```

Replay detected the lie:

```text
REPLAY_EXIT=1
FAIL: Journal replay detected divergence from board state:
- Item #1 STATUS mismatch: journal says 'Todo', board says 'Done'
```

That detection is currently advisory:

- Replay reports but does not protect writes: `scripts/idc_journal_replay.py:386-411`
- Janitor classifies it `RISKY`: `scripts/idc_git_janitor.py:863-959`
- Doctor blocks only with explicit `--strict-journal`: `agents/idc-doctor.md:407-440`
- Strict lint mode is opt-in: `scripts/lint-references.sh:52`, `scripts/lint-references.sh:196-211`

A further concern: Janitor treats `Status=Done` plus an open issue as a safe `close-issue` repair (`scripts/idc_git_janitor.py:280-292`). Without a blocking divergence precondition, `--apply-safe` can convert an unsupported raw `Done` into a closed issue while merely retaining the journal warning.

## T5 — ADVISORY

The command contract is strong while it runs:

- Completion invariants: `scripts/idc_command_contract.py:2127-2150`
- `finish --status complete` refuses unmet obligations: `scripts/idc_command_contract.py:3114-3137`

Stop-related enforcement is deliberately bounded:

- Shared bound permits exit after three denials: `scripts/hooks/idc_hook_lib.py:257-270`
- Stop fixpoint gate: `scripts/hooks/idc_stop_fixpoint_gate.py:621-647`
- Command closeout gate: `scripts/hooks/idc_command_closeout_gate.py:57-81`
- Verdict gate: `scripts/hooks/idc_verdict_gate.py:139-158`

Synthetic Stop result:

```text
STOP attempt=1 exit=0
STOP attempt=2 exit=0
STOP attempt=3 exit=0
STOP attempt=4 exit=0
idc-fixpoint-gate: LOUD-FAIL (bound exhausted) — the durable orchestrator is stopping while the phase is not at a fixpoint: the board still has actionable items or unresolved merge work
```

The tests intentionally assert that the fourth attempt is allowed:

- `tests/smoke/governance/stop-fixpoint-nonempty-inbox.sh:68-96`
- `tests/smoke/governance/verdict-gate.sh:141-160`

Additionally, unreadable or corrupt ledger state becomes an empty state:

- Tolerant ledger read: `scripts/hooks/idc_ledger.py:247-262`
- Active-command query inherits it: `scripts/hooks/idc_ledger.py:504-510`
- Taint query inherits it: `scripts/hooks/idc_ledger.py:522-542`

Thus deleting or corrupting the local ledger can hide active commands and pending taints rather than fail closed.

## T6 — ADVISORY

Several mechanisms detect or report divergence:

- Acceptance and finish coherence are consulted by drain: `scripts/idc_autorun_drain.py:397-430`
- Finish coherence compares board status with issue state: `scripts/idc_finish_coherence.py:95-137`
- Recirculator closeout checkpoints uncovered work: `scripts/hooks/idc_recirc_closeout_gate.py:590-637`

Recirculator closeout explicitly fails open:

- `scripts/hooks/idc_recirc_closeout_gate.py:663-665`

More importantly, drain does **not** run journal replay. A raw filesystem `Done` state therefore certified completion:

```text
DRAIN_EXIT=0
acceptance: ok
finish-coherence: ok
live: not-declared
drain: complete
```

Autorun lifecycle closeout accepted it:

```text
CONTRACT_FINISH_EXIT=0
command-contract: finished idc:autorun as complete
```

The journal simultaneously remained red:

```text
REPLAY_AFTER_COMPLETE_EXIT=1
FAIL: Journal replay detected divergence from board state:
- Item #1 STATUS mismatch: journal says 'Todo', board says 'Done'
```

This is the most consequential demonstrated tracker-status bypass: an unsupported raw `Done` can become an accepted autorun completion while the only detector sits off the completion path.

## T7 — MISSED

### Fabricated review verdict

The validator accepts a well-shaped PASS receipt without proving that a review occurred:

```text
CHECK_EXIT=0
OK: PASS verdict for PR #77, issue #42
```

The same fabricated verdict closed an unreviewed and unmerged filesystem item through the sanctioned transition engine:

```text
CLOSE_EXIT=0
transition ok: close item 42: Status='In progress' → 'Done'
```

Afterward both replay and drain were clean:

```text
JOURNAL_EXIT=0
OK: Journal replay matches current board state.
DRAIN_EXIT=0
acceptance: ok
finish-coherence: ok
live: not-declared
drain: complete
```

This occurs because `idc_review_verdict_check.py:79-154` validates schema and internal consistency, while `idc_transition.py:1621-1668` compares it with caller-provided issue and PR values rather than independently reading PR or review state.

### Forged journal history

Journal replay checks legal sequence and board agreement, not provenance:

- Event replay: `scripts/idc_journal_replay.py:281-318`
- Final comparison: `scripts/idc_journal_replay.py:386-411`
- Pre-journal items are exempt below the watermark: `scripts/idc_journal_replay.py:481-489`

A raw board plus hand-authored `create-ticket` and `close` records passed:

```text
FORGED_REPLAY_EXIT=0
OK: Journal replay matches current board state.
```

A hand-authored gate reconciliation record also satisfied gate proof:

```text
FORGED_GATE_EXIT=0
{"gate_item": 5, "pr": 9, "source": "journal", "status": "approved"}
```

`idc_gate_proof.py:76-103` accepts the journal record’s shape; it does not re-read the live gate and PR.

### Gate-binding provenance gap

The reciprocal binder verifies both PR and gate bodies (`scripts/idc_pr_gate_bind.py:74-135`), but `check_gate_approved()` reads only the gate-body marker and confirms that the named PR is merged (`scripts/idc_transition.py:1426-1468`). It does not verify the reciprocal marker in the PR body.

Therefore, by code inspection, an actor able to edit a gate body outside the active interlock can point it at an unrelated merged PR and then invoke the sanctioned `gate-approved` disposition. This was not exercised live because GitHub mutation was prohibited.

### Important exception: live-surface evidence is stronger

Hand-writing a live-verification receipt alone no longer passes. It requires a matching witness under the Git directory:

- Security boundary and limitation: `scripts/idc_live_check.py:34-45`
- Witness design: `scripts/idc_live_check.py:717-745`
- Receipt and witness comparison: `scripts/idc_live_check.py:817-833`

That closes the cheap typed-receipt path, although the script explicitly acknowledges that an actor who can edit `.git` can still forge the local witness.

## Governance-test results

The audit ran **25 test invocations covering 24 distinct scripts**. All exited `0`, including:

- all terminal engine and receipt-ownership tests
- board lifecycle write-door tests
- interlock tests
- bounded Stop, verdict, and closeout tests
- journal replay and divergence tests
- finish receipt, PR finish, and PR/gate binding tests
- recirculator checkpointing
- filesystem and GitHub gate dispositions
- command-contract lifecycle
- phase 4 completion-honesty suite

Representative verbatim results:

```text
PASS: no create op mints a terminal Status on either backend
PASS: no verdict-free path to Done
PASS: every engine op reads back the written item
PASS: PreToolUse interlocks
PASS: SubagentStop verdict gate
--- All journal-divergence tests passed! ---
PASS: phase4-completion-honesty
```

Additional verification:

```text
lint-references: CLEAN (38 files scanned)
```

`git diff --check` exited `0` before this report was added.

These green tests confirm that intended assertions work. They do not contradict the audit: several gaps are explicitly encoded as bounded or advisory behavior, while provenance forgery is outside the current assertions.

### Missing negative coverage

1. No test requires direct `idc_tracker_fs.py` or non-Bash `TRACKER.md` edits to be denied.
2. No completion test requires journal replay to pass before drain or autorun says complete.
3. No negative test rejects a schema-valid PASS receipt that lacks an actual review.
4. No test rejects a forged but legal, board-concordant journal history.
5. No gate-proof test requires a fresh live GitHub read instead of journal shape.
6. Gate approval does not test that the PR body reciprocally names the gate.
7. Existing Stop tests affirm the fourth-attempt fail-open behavior rather than enforcing an absolute block.

## Should journal divergence become blocking?

**Yes. It would close a meaningful integrity gap, but only a limited one.**

It should block:

1. `idc_autorun_drain.py` from returning `drain: complete`
2. `idc_command_contract.py finish --status complete`
3. `idc_git_janitor.py --apply-safe` before any repair derived from a divergent board

That would prevent the demonstrated raw-`Done` mutation from becoming a clean lifecycle completion and prevent Janitor from laundering that status into a closed issue.

Before doing so, journal durability must be addressed:

- Transition journaling is currently best-effort and nonfatal: `scripts/idc_transition.py:959-972`
- Git finisher journaling is also best-effort: `scripts/idc_git_finish.py:582-640`
- The known transactionality limit is documented as issue `#154`: `docs/architecture.md:363-366`

Otherwise a legitimate remote mutation followed by a failed local journal append would permanently wedge completion. A blocking policy needs a sanctioned reconciliation operation that re-derives live truth and records an explicit reconciliation—not hand-authored fake history.

Blocking replay still would **not** catch:

- forged concordant board and journal history
- a fake but well-shaped PASS accepted and journaled through the engine
- a forged gate-body marker followed by a legitimate terminal journal event
- legacy pre-journal items below the watermark

It is therefore valuable defense-in-depth, not proof of authenticity.

## Audit limitations and repository state

- CodeGraph reachability analysis was unavailable because no `.codegraph/` index exists.
- No live GitHub mutations or real GitHub board/PR transitions were performed.
- Hook behavior was tested with synthetic hook payloads and governance fixtures, not a live Claude sandbox session.
- The branch, index, tracked files, and pre-existing untracked-file inventory were not changed during the audit itself.
- Python imports refreshed two ignored bytecode cache files: `scripts/__pycache__/idc_git_janitor.cpython-314.pyc` and `scripts/__pycache__/idc_journal_replay.cpython-314.pyc`. They were not deleted because their pre-audit existence could not be established and cleanup of pre-existing files was prohibited.
- All synthetic tracker mutations and test repositories were under `/tmp`.

At the start and end of the read-only audit, the visible repository state was:

```text
## main...origin/main
?? docs/dev/2026-07-21-ast-census-proposal.md
?? docs/reviews/2026-07-19-pr-163-completion-honesty-review.md
```

This report is the sole intended repository addition from the audit follow-up.
