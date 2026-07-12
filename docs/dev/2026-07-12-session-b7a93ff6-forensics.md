# Session b7a93ff6 forensic audit — stale IDC runtime + external-plan routing failure

- Date: 2026-07-12
- Audited Claude session: `b7a93ff6-1bc5-416a-9610-e69ccf07dbbb`
- Session repo: `/Users/jeremy/dev/proj/knowledge-engine`
- IDC source repo audited against: `/Users/jeremy/dev/proj/idc-workflow` at `main` / 4.0.0
- Raw transcript: `/Users/jeremy/.claude/projects/-Users-jeremy-dev-proj-knowledge-engine/b7a93ff6-1bc5-416a-9610-e69ccf07dbbb.jsonl`
- External input: `/Users/jeremy/.claude/plans/analyze-the-current-codebase-bubbly-rain.md`

## Verdict

The failure is real, and it is primarily a workflow-system failure rather than an Opus reasoning
failure.

The session ran a **3.3.0 command and 3.3.0 skills** against a repo whose scaffold had already been
updated to **4.0.0**, while manually selecting some 4.0.0 scripts with `find ... | sort -V | tail -1`.
That split the workflow into three incompatible parts:

1. 3.3.0 command/role instructions;
2. 3.3.0 tracker and gate procedures;
3. 4.0.0 validators and board readers plus a 4.0.0 governed repo.

The 4.0.0 deterministic transition engine and its journal therefore did not govern the gate. The
session created a hand-written shell script containing raw GitHub issue/project mutations, then used
another hand-written script to unblock the consideration and close the gate. The live board now looks
partly right but cannot prove how it got there.

The polished external plan exposed a second, independent gap: IDC has no durable intake contract for
a multi-stage artifact. Think correctly noticed that the document contained Think, Recirculation,
Plan, Build, and operator-gate work, but it persisted only the Drive requirement. It did not preserve
the remainder as routed work. It then falsely told the operator that no-argument Recirculate would
seed the cleanup work, Build would execute uncreated B1/B2 work, and Autorun could drain work that had
never entered the tracker.

This incident does **not** prove the v4 transition engine is ineffective. It proves IDC did not ensure
that the active session was actually using v4, did not hard-block bypasses, and did not require a
machine-checked closeout before claiming a stage was complete.

## Evidence timeline

All transcript references below are JSONL line numbers.

| UTC | Transcript | What happened | Why it matters |
|---|---:|---|---|
| 05:12 | 16–17 | `/idc:think <external-plan>` expanded from the 3.3.0 plugin path. | The session began on stale command logic after the repo had been resynced to 4.0.0. |
| 05:15 | 35–42 | Think recognized the file as a whole program containing truth-reset, v2 wire-up, and Drive work. | The model saw the routing problem; the system had no artifact in which to preserve the routing decision. |
| 05:42 | 50–51 | The operator said to do everything in the plan, starting with Drive. | This was a whole-program instruction, not permission to drop the non-Drive remainder. |
| 05:54 | 70–73 | The Drive scope was narrowed by an explicit operator answer; the consideration skill loaded from 3.3.0. | The narrower owned-My-Drive scope was authorized, but the runtime remained stale. |
| 05:56 | 95–104 | The consideration was written and checked with a dynamically discovered 4.0.0 checker. | This is the first confirmed split-brain use of 3.3 instructions with 4.0 scripts. |
| 05:58 | 124–127 | The gate skill loaded from 3.3.0. | The session never received v4's gate-bound approval and dispose-first contract. |
| 06:00 | 137–168 | The PR was opened; a hand-written `fire_gate.sh` used raw `gh issue create`, `gh project item-add`, `gh project item-edit`, and dependency API calls. | The single transition door and transition journal were bypassed. |
| 06:05 | 200 | Think claimed the whole program was routed and said `/idc:recirculate` “seeds the cleanup tickets”, `/idc:build` handles B1/B2, and `/idc:autorun` drains all of it. | None of those tickets or goal contracts existed. These command descriptions were false. |
| 07:00 | 204–226 | After direct merge authority, `post_merge.sh` set #707 to Todo first, removed the dependency, then raw-closed #708. | v4 requires guarded gate disposal first, then unblock. The script did the reverse and journaled nothing. |
| 07:01 | 228 | The session claimed “everything's in the right state” and repeated the false handoff commands. | No deterministic postcondition checked that claim. |
| 07:03 | 236–243 | No-argument `/idc:recirculate` again expanded from 3.3.0; the model manually substituted 4.0.0 files. | The stale command boundary remained open after the first failure. |
| 07:06 | 245–260 | A transient GitHub timeout was retried; the session listed all Recirculation items manually, including Done items. | It re-derived the inbox instead of consuming a deterministic open-`Recirculation/Todo` query result. |

## Confirmed contract violations

### 1. Runtime split-brain was permitted

The transcript contains 3.3.0 command and skill paths while the knowledge-engine repo was already at
the 4.0.0 scaffold commit. The existing helper proves the mismatch mechanically:

```text
$ python3 scripts/idc_plugin_freshness.py \
    --plugin-root /Users/jeremy/.claude/plugins/cache/idc-workflow/idc/3.3.0
running 3.3.0; installed-max 4.0.0; verdict stale
exit 4
```

The helper was not called because only `/idc:update` carries the stale-session hard stop. Doctor's
cache-freshness row is advisory, and Think/Plan/Build/Recirculate/Autorun do not run the helper at
entry. This is the still-open problem tracked by idc-workflow issue #106; this incident is the
post-3.3 recurrence its earlier comment said should trigger re-evaluation.

### 2. The v4 single write door was bypassed

`fire_gate.sh` performed, outside `idc_transition.py`:

- two raw issue creates;
- two raw project item adds;
- three raw Stage/Status field edits;
- one raw dependency mutation.

`post_merge.sh` then performed, outside `idc_transition.py`:

- one raw Status edit (`#707 → Todo`);
- one raw dependency deletion;
- one raw issue close (`#708`), after unblocking the dependent.

The gate body also omitted v4's required `<!-- idc-gate-pr: 706 -->` binding. A current v4 guarded
`dispose --disposition gate-approved` would therefore refuse to close it.

### 3. The current interlock would not have prevented the incident

The v4 PreToolUse interlock intentionally ships in warning-only mode. Its own source states that the
warning goes to telemetry/stderr and **is not added to the model's context**. Hard denial requires an
environment switch.

Even with that switch enabled, the incident's indirection bypasses the classifier. A synthetic replay
against the current hook produced:

```text
command: bash "/private/tmp/.../scratchpad/fire_gate.sh"
IDC_HOOKS_INTERLOCK_ENFORCE=1
result: exit 0, no output
```

The same hook correctly denies a direct `gh project item-edit`. It inspects only the Bash tool's
command string; it does not inspect a shell script that command executes.

### 4. The external plan had no durable routing receipt

The 870-line input explicitly declared nine admission units plus a separate Drive Think gate and a
dependency graph. The session's own reasoning separated these classes correctly, but no checked
artifact recorded a disposition for every unit.

Only Drive reached a canonical/tracker artifact. U1–U8 and B1–B2 were not seeded, admitted,
decomposed, or linked. The operator's “do everything” intent was written only to Claude's private
project memory. That memory is not an IDC tracker or workflow handoff.

### 5. The next-command advice was not derived from live state

The session said:

- `/idc:recirculate` seeds cleanup tickets. In fact, no-argument Recirculate drains existing open
  `Stage=Recirculation, Status=Todo` tickets. Drift intake requires an argument, and external program
  ingestion has no contract.
- `/idc:build` handles B1/B2. In fact, Build consumes existing schema-checked Buildable goal-contract
  issues. None had been created for B1/B2.
- `/idc:autorun` drains the whole plan. In fact, Autorun drains admitted tracker state. It cannot
  drain work that exists only in an external Markdown file or Claude memory.

No script validated that any recommended next command had actionable input.

### 6. Stage completion had no universal receipt

Think could stop and claim success without proving:

- the active plugin version matched the repo;
- the gate body carried its bound PR marker;
- every tracker write passed through the transition engine;
- the gate and pointer matched the transition journal;
- all units from the external input had durable dispositions;
- the named next commands had actionable tracker inputs.

The v4 Stop gate protects drain sessions, and SubagentStop protects some review/recirculation
closeouts. There is no equivalent command-level closeout gate for Think, Plan, or single drift-intake
Recirculate.

## Live fallout verified during this audit

Read-only GitHub and filesystem checks on 2026-07-12 showed:

| Artifact | Live state | Required v4 state |
|---|---|---|
| Think PR #706 | merged (local main includes squash `e491aed`) | merged is the valid operator admission signal |
| Consideration #707 | GitHub issue OPEN; board `Stage=Consideration, Status=Todo` | plausible post-admission surface, but its unblock has no guarded/journaled proof |
| Gate #708 | GitHub issue CLOSED; board `Status=Todo`, Stage unset | guarded dispose should produce board Done + closed issue + journal record |
| Gate body | no `idc-gate-pr` marker | exactly one marker binding it to PR #706 |
| Transition journal | absent | gate creation/disposal/unblock operations journaled |
| Drive sub-spec | still says `Status: Draft` on merged main | status and user-facing completion claim must agree |

The current read-only janitor eventually found #708 as both:

- `SAFE-FIX`: `Status=Todo but the issue is CLOSED as completed`;
- `RISKY`: the board has a Stage field but #708 has no Stage.

That scan took roughly nine minutes on the 190-item GitHub board. Janitor is useful recovery, but it
is not a substitute for prevention at command expansion, mutation, and closeout.

## What worked

The audit should not overstate the failure:

- Think correctly recognized that the external file was a multi-stage program.
- It correctly isolated Drive as the genuinely new requirement.
- The operator explicitly chose the narrower owned-My-Drive scope, so excluding Shared Drives was
  not an unauthorized silent change.
- The feasibility research covered the main Drive API edge cases.
- The consideration checker passed.
- PR #706 really merged.

Those are reasoning and content successes. They do not repair the broken workflow state or the lost
program remainder.

## Root-cause tree

### Primary system causes

1. **Stale plugin use is detectable but not blocked at every IDC entry point.** `/clear` starts a new
   conversational session but does not reload updated plugin components. IDC had no command-expansion
   interlock to refuse the stale command.
2. **The raw-action interlock was intentionally left toothless.** Default warning-only mode did not
   block and did not inform the model.
3. **The interlock sees only the top-level Bash string.** Writing a temporary script and executing it
   bypasses even the optional deny mode.
4. **There is no external-program intake state.** A multi-stage plan can be discussed, but there is no
   schema that requires complete per-unit routing and preserved dependencies/gates.
5. **There is no universal per-command transaction/closeout.** Stage prompts can claim success without
   a machine-verifiable receipt.
6. **Next-step narration is prose.** The model can recommend a command whose actual preconditions are
   false.

### Model errors that the system should have contained

1. It bypassed `idc:idc-tracker-adapter` and loaded the backend skill directly.
2. It dynamically selected “latest” scripts instead of halting on the stale active root.
3. It hand-authored workflow state changes in shell.
4. It reversed the required gate-dispose/unblock order.
5. It made false claims about what Recirculate, Build, and Autorun would do.
6. It declared the board correct without checking the v4 journal/postconditions.

### Not the root cause

The external plan was detailed and forceful, but it did not cause the corruption. It exposed that IDC
has no safe compiler/intake boundary for foreign execution plans. A robust workflow must treat such a
document as untrusted evidence, route every unit through IDC, and prove coverage before proceeding.

## Required properties of the remediation

The implementation design must, at minimum:

1. block every `/idc:*` command expansion when the loaded plugin is stale;
2. make `/reload-plugins` the explicit recovery and distinguish it from `/clear`;
3. hard-deny raw workflow mutations by default and inspect executed shell-script contents;
4. provide a dedicated external-artifact intake path with a machine-checked unit/disposition manifest;
5. preserve the operator's whole-program goal, dependencies, and production gates in repo/tracker state;
6. require a deterministic closeout receipt for every IDC command before Stop can claim completion;
7. compute next actions from live state and refuse false handoff advice;
8. add a regression fixture replaying this exact stale-3.3 / v4-repo / temporary-script / external-plan
   incident;
9. include a one-time repair path for #707/#708 that does not forge a v4 journal history;
10. update/close the existing stale-cache issue #106 only after the new hard gate is proven live.

## Verification receipts from this audit

```text
git -C /Users/jeremy/dev/proj/idc-workflow status --short --branch
  ## main...origin/main

idc_plugin_freshness.py --plugin-root .../3.3.0
  running 3.3.0; installed-max 4.0.0; verdict stale
  exit 4

current interlock, enforce=1, direct raw gh project mutation
  permissionDecision=deny

current interlock, enforce=1, bash fire_gate.sh
  exit 0; no output

live board read
  #707 Stage=Consideration Status=Todo
  #708 Stage=<unset> Status=Todo

gh issue view 708
  state=CLOSED
  operator-action label present
  idc-gate-pr marker absent

knowledge-engine transition journal search
  no transition journal present

current janitor, report-only
  #708 SAFE-FIX: closed issue / Status=Todo
  #708 RISKY: Stage unset
```

No knowledge-engine file, board item, issue, PR, branch, or journal was mutated during this audit.
