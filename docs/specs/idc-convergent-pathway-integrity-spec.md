# IDC Convergent Pathway Integrity and Auto-Validation Specification

- **Status:** Proposed synthesis for implementation
- **Date:** 2026-07-21
- **Scope:** IDC-controlled repositories, tracker integrity, validation, reconciliation, and runtime enforcement
- **Inputs:** `docs/reviews/2026-07-21-tracker-status-integrity-audit.md`, `docs/specs/reconciled-execution-graph-receipts-active-janitor-spec.md`, Fusion Harness's auto-validation loop, and the 2026-07-21 video discussion

> This specification combines the tracker-integrity audit fixes with the reconciled execution graph,
> receipt-backed validation, and Active Janitor design. Where it conflicts with the earlier graph
> specification, this document controls pathway enforcement, mandatory Build validation, receipt
> authenticity, and rollout order. The earlier specification remains the detailed source for the
> graph model and optional code-evidence providers.

Normative terms **MUST**, **MUST NOT**, **SHOULD**, and **MAY** have their usual requirements meaning.

---

## 1. Product decision

IDC will become the required change pathway for an IDC-controlled repository.

IDC does **not** decide how an agent should design, plan, or write code. It controls the route by
which repository work is admitted, claimed, changed, reviewed, merged, and reflected in the tracker.
The tracker is part of each route transition, not a report repaired after the work is over.

The governing invariant is:

> No repository-changing action becomes accepted repository state unless it has an active IDC
> authorization, follows an IDC-owned lifecycle transition, updates the tracker through the
> sanctioned transaction path, and produces machine-verifiable evidence of the resulting state.

This changes the meaning of “guardrails, not train tracks.” The replacement wording is:

> **Pathway guardrails, not coding prescriptions.** IDC does not dictate the agent's coding method or
> its substantive plan. It does require all governed work to enter through Think, Intake,
> Recirculation, Plan, Build, or an operational recovery route; it keeps tracker state synchronized
> as part of every transition and refuses unproven completion.

The PRD, `WORKFLOW.md`, architecture documentation, and README MUST stop claiming that IDC has
“exactly five guardrails” or is merely advisory around off-path work. They MUST state the honest
enforcement boundary described in §2.

### Success criteria

1. A supported agent cannot write source, tests, plans, tracker files, or Git state in a controlled
   repo without an active IDC route bound to that work.
2. The next lifecycle step is unavailable until its required tracker mutation has been applied,
   journaled, read back, and receipted.
3. Direct or forged tracker state cannot make Build, Autorun, Janitor, a Stop hook, or command
   closeout report completion.
4. Every code-changing ticket has a frozen, executable acceptance contract bound to the final diff;
   existing real tests are reused and new tests are created only when needed.
5. Useful off-path work is preserved and adopted through expanded Intake; it is never silently
   blessed, discarded, or given fabricated IDC history.
6. The system remains dependency-light: fixed IDC validators and declarative manifests do the core
   work. No remote validation agent or Fusion Harness runtime dependency is required.

---

## 2. Enforcement boundary and profiles

### 2.1 Controlled is the default security claim

`WORKFLOW-config.yaml` gains one configuration block:

```yaml
pathway_enforcement:
  mode: controlled       # off | controlled | app-locked
  attempt_ceiling: 3
```

- `off` preserves an explicitly non-enforcing development/test setup and makes no pathway-security
  claim.
- `controlled` is the default for governed GitHub-backed repositories. Supported runtime hooks deny
  local off-path mutations, and a required deterministic GitHub check plus repository rules block
  off-path integration.
- `app-locked` adds a GitHub App as the sole tracker writer and pins required checks to the trusted
  App source. This is the profile for repositories that must prevent a user or unrelated token with
  ordinary write access from directly changing the board.

The filesystem tracker remains useful for hermetic tests and local demonstrations. It MUST NOT claim
hard pathway security. `/idc:doctor` MUST fail a `controlled` or `app-locked` configuration that uses
the filesystem backend.

### 2.2 Honest threat model

In `controlled` mode, IDC MUST block normal supported Claude, Codex, and Pi agent pathways and MUST
block merge when pathway evidence is missing or inconsistent. It cannot stop a machine administrator
from removing hooks, editing `.git`, or disabling GitHub rules. It also cannot prevent an authorized
GitHub user from making a raw tracker API mutation; it detects that mutation and blocks completion or
merge until reconciled.

`app-locked` closes the ordinary-token tracker-write gap. Neither profile claims protection against
GitHub organization/repository administrators who can remove the rules or App.

### 2.3 Protected acceptance boundary

Every controlled repository MUST install a required check named `idc/pathway-integrity` and a ruleset
that:

- requires pull requests for protected branches;
- requires the IDC check at the exact proposed head commit;
- prevents force pushes and protected-branch deletion;
- protects IDC workflow, hook, validation, and receipt surfaces with review/ownership rules;
- refuses a merge when tracker, graph, journal, authorization, validation, review, or finish evidence
  is missing, stale, corrupt, or divergent.

The standard workflow is same-repository and version-pinned. The App-locked profile additionally
requires the expected check source and makes the App the only credential allowed to mutate tracker
state.

---

## 3. Minimal architecture

The design uses five focused parts. They share existing readers, the transition engine, the review
engine, Finisher, and current recovery doors rather than creating a second workflow.

### 3.1 Reconciled execution graph

IDC MUST compile one authoritative graph for the active planning horizon. It contains:

- considerations, canonical requirements/specs/plans, pillars, and Buildable work;
- gates, dependencies, deterministic Waves, and file/resource ownership;
- tracker items and their exact projected fields and blocker links;
- branches, commits, pull requests, actual changed paths, and merge state;
- validation, review, finish, adoption, and reconciliation receipts;
- unresolved recirculation, recovery, and Janitor obligations.

The graph is derived from authoritative inputs; agents do not hand-edit it as truth. Optional tools
such as CodeGraph MAY enrich code-impact evidence but never become admission, scheduling, or
completion authority. The same inputs MUST produce the same graph, projection, and Waves.

### 3.2 Path Gate

Every supported runtime MUST call one shared deterministic Path Gate before a repository mutation.
The runtime adapter only translates its hook payload into the shared request.

The active authorization is untracked state under the repository Git directory and is created only
by an IDC command entry/transition. It contains:

```json
{
  "schema": 1,
  "command": "idc:build",
  "ticket": "<tracker-id-or-null>",
  "graph_node": "<stable-node-id>",
  "branch": "<exact-branch>",
  "allowed_paths": ["<normalized-path-or-directory>"],
  "allowed_actions": ["write", "git", "tracker-read"],
  "issued_at": "<UTC timestamp>",
  "expires_at": "<UTC timestamp>",
  "nonce": "<random-id>",
  "contract_digest": "<validation-and-goal-contract-digest>"
}
```

The Path Gate MUST deny when the authorization is missing, expired, corrupt, on the wrong branch,
bound to the wrong ticket/graph node, outside the declared paths/actions, or inconsistent with the
live tracker. Denial MUST explain the correct IDC route. The agent then asks the operator to confirm
the relevant existing command—Think, Intake, Plan, Build, or Recirculate—rather than inventing a new
escape hatch.

Coverage is mandatory for:

- Claude: Bash, Write, and Edit;
- Codex: shell and every available write/edit tool, including `apply_patch` aliases;
- Pi: its existing write, edit, and shell surfaces;
- Git: pre-commit and pre-push backstops;
- GitHub: the required `idc/pathway-integrity` merge check.

Raw tracker writes, raw merge/close operations, and edits to machine-owned tracker/receipt surfaces
MUST always be denied in controlled modes, even during an active command. Only the sanctioned IDC
executor may perform them.

### 3.3 Tracker transaction

Tracker maintenance is a synchronous part of the pathway. Every mutation follows exactly this order:

1. read and digest the relevant live tracker/graph state;
2. persist an in-flight obligation before the first write;
3. build the expected end-state projection and ordered operations;
4. validate the projection with a pure in-memory simulation;
5. freeze the projection and operation set;
6. apply only those operations through `idc_transition.py` or an existing guarded recovery/finish
   door;
7. append mandatory source-owned journal evidence for each operation;
8. read the live tracker back and compare it exactly with the frozen projection;
9. issue a machine-owned receipt and discharge the obligation.

A journal append or readback failure makes the transaction incomplete. It MUST NOT be treated as
best-effort. IDC does not blindly roll back a partly applied remote transaction; it preserves the
obligation, blocks the affected graph region, and routes idempotent recovery through Janitor.

No source-write authorization is issued before a Build claim is proven `In Progress`. No finish is
complete until merge and terminal tracker state are both read back. Thus the tracker stays true
because its updates are prerequisites for movement along the path.

### 3.4 Ticket validation contract and auto-validation loop

After matrix analysis, Plan MUST emit a machine-readable validation contract for every Buildable
ticket and bind its digest into the goal contract, graph, and tracker projection. The contract
declares:

- ticket and graph-node identity;
- the observable goal;
- the declared user/system surface: `cli | api | gui | library | agent | ci | none`;
- the declared evidence kind, fixed by the surface table: `cli→pane-capture`, `api→response-body`, `gui→screenshot-or-recording`, `library→public-import-sample`, `agent→agent-run-capture`, `ci→check-run`, `none→none`;
- a one-line `skip_reason` when `surface:none` is the honest no-behavioral-diff case;
- existing verification commands to reuse, including any cited `handle_id` resolved from the governed verification-handle registry;
- whether the baseline is `expected-red` or a proven idempotent `expected-green`;
- declared `touch` and `off-limits` paths;
- required tracker pre-state, lifecycle transitions, and terminal post-state;
- attempt ceiling, defaulting to `pathway_enforcement.attempt_ceiling`;
- freshness inputs: base/head/diff, relevant path digests, and validator version.

The contract is declarative. IDC MUST use one fixed tracker/pathway validator; Plan MUST NOT generate
an arbitrary tracker-mutation script for every ticket. Fixed validators MUST reject any impossible
surface/evidence pairing, any command set that cannot produce the declared evidence kind, and any
`surface:none` contract lacking its one-line `skip_reason`.

Reusable verification recipes live in one governed per-repo registry,
`docs/workflow/verification-handles.yaml`. Fixed code schema-checks that registry before any entry is
cited, resolved, or used; malformed, missing, unknown-field, invalid-shape, schema-version-mismatched,
or secret-bearing entries fail closed. Commands, fixtures, emulators, and account identifiers or
placeholders are allowed there; inline credentials, auth material, `.env` content, key material, and
private URLs are rejected before use. A missing handle creates a named Recirculation or
blocked-dependency obligation; a warning-only downgrade is forbidden.

At Build claim, an independent local validator performs the Fusion-inspired loop:

1. reuse the existing real functional test when it proves the goal;
2. if the behavior is untested, create the smallest executable failing test before implementation;
3. run the frozen gate against the baseline;
4. require the declared red result, or an explicitly justified green no-delta result;
5. freeze the gate digest and exclude it from the builder's allowed paths;
6. let the builder implement freely inside the ticket boundaries;
7. run the frozen gate and feed exact failures back to the same Build attempt record;
8. repeat with varied implementation attempts up to the ceiling;
9. run the gate again against the final proposed PR commit and actual diff;
10. require the existing review engine and Finisher evidence before completion.

An unexpected green baseline, timeout, execution error, changed gate, stale diff, or indeterminate
result stops the loop. A PASS string or shaped JSON is never sufficient evidence.

A genuine task-specific gate defect MAY receive one independent audited repair. The old gate remains
in evidence and the repaired gate runs immediately. Fixed IDC invariants—path authorization,
tracker transaction legality, journal integrity, receipt binding, and merge protection—cannot be
repaired or weakened at runtime.

For the minority of tickets where choosing the wrong gate is consequential, Plan runs a deterministic
risk-gated read-only discovery/falsification pass before the frozen gate is written. Only named fixed
risk inputs may trigger it: `security-sensitive-path`, `cross-cutting-surface`,
`new-runtime-dependency`, `expected-green-baseline`, and `large-touch-set`; trivial tickets
skip deterministically. Candidate branches use the exact schema `{promise, failure_mode,
observable_evidence, executable_check}`. Independent skeptics ask exactly `show how this check passes
while the goal is actually broken`; any gate defeated by a majority is discarded or repaired before
survivors inform the frozen gate. Discovery never mutates tracker state, never owns the validator, and
must preserve the fixed validator, frozen-gate digest, path exclusions, and attempt ceiling unchanged.

This augments IDC's existing failing-test-first goal contracts. It does not replace or duplicate
ordinary TDD, and it does not tell the builder how to code.

### 3.5 Source-owned receipts

Every receipt MUST be written by the component that executed or freshly re-derived the claimed fact.
Receipts bind at least the producing command/version, repository identity, ticket/graph node, exact
commit or tracker snapshot, inputs, outcome, the declared surface/evidence kind, and bounded redacted
evidence of that declared kind. Any receipt whose declared evidence no longer matches the frozen
contract's surface/evidence pair is a deterministic contract-drift failure.

For facts not reproducible from committed/remote state, the receipt also requires a witness outside
the agent-authored artifact: Git-directory evidence, a trusted CI/check-run identity, or the
App-locked service. Caller-authored `PASS`, `exit: 0`, journal entries, or gate markers are not proof.

Review approval MUST bind reciprocally to the live PR, issue, diff, review execution, and gate. Gate
approval MUST use a fresh live read; journal shape alone is insufficient.

---

## 4. IDC route behavior

### 4.1 Plan

Plan remains pure decomposition. It performs the full-horizon deduplication and matrix analysis,
declares semantic dependencies and resource ownership, emits each validation contract, resolves and
cites any reusable verification `handle_id`, routes missing handles into named existing-door
obligations, runs the deterministic risk-gated falsifier when and only when the named fixed risk inputs
say it must, compiles the graph, derives Waves deterministically, simulates the complete tracker
projection, and applies it as one guarded transaction. The Planning PR cannot close without a valid
planning-application receipt.

### 4.2 Build and Finisher

Build entry verifies graph readiness, goal/validation contract identity, current tracker state,
branch ownership, and reconciliation blockers. A successful claim transaction issues the limited
Path Gate authorization.

Before merge, IDC MUST prove:

- the actual PR diff stays within `touch` and outside `off-limits`;
- the frozen acceptance gate ran against the final diff and commit;
- the merge/close path received the mandatory source-owned build receipt for that exact issue/PR/diff;
- the execution receipt's declared surface/evidence kind still matches the frozen contract;
- existing and new functional verification passed;
- review executed against that same diff and has no unrouted findings or merge conditions;
- graph, tracker projection, and authorization remain current;
- the merge and close transaction can be completed through Finisher.

The authorization expires after finish or block. It cannot be reused for another ticket.

### 4.3 Expanded Intake for off-path work

Intake remains the existing admission surface and gains three source forms:

```text
/idc:intake <markdown-artifact>
/idc:intake --pr <number>
/idc:intake --branch <name>
```

PR and branch Intake MUST pin the source repository, head commit, base commit, and diff digest before
analysis. It treats all source text as untrusted evidence and does not execute it.

Intake routes each unit to Think, Recirculation, an existing ticket, a newly planned ticket, a
reconciliation audit, or quarantine. It never directly mints or executes a Buildable. Once the
upstream route exists, Build MAY adopt the pinned diff and must record an explicit adoption receipt.
IDC never invents earlier tracker transitions to make outside work appear on-path.

Unmerged outside work is preserved and routed to normal Plan/Build adoption. Already-merged outside
work receives a distinct reconciliation-audit obligation; only independent validation can yield
`verified-reconciliation`, which is not the same as normal `verified-implementation`.

### 4.4 Active Janitor

Janitor becomes the convergence controller for facts that escape or interrupt the normal path:

```text
observe → match → investigate → propose → validate → apply → read back → rescan
```

It MUST detect post-adoption unreceipted source/Git/tracker work, journal/board divergence, incomplete
tracker transactions, stale receipts, orphaned branches/PRs/worktrees, graph projection gaps, and
canonical drift. It preserves work first, invokes Intake for outside artifacts, invokes
Recirculation for scope/canonical drift, and uses existing guarded doors for non-destructive repair.

Janitor persists a durable seen-finding ledger across passes and deduplicates against all previously
seen findings, including rejected: every finding is recorded before disposition, and a resurfaced
seen finding is recognized rather than counted as new — it cannot reset the three-pass counter,
duplicate a routed obligation, or advance a checkpoint as if it were new. Fixed code alone validates
and writes the ledger; model-authored report text never mutates it, and invalid direct ledger writes
fail closed. The per-PR review→fix→re-review path keeps the same convergence discipline: seen
fingerprints are persisted before flooring/rejection/refutation, so a resurfaced rejected, refuted,
or below-floor finding cannot recycle the review attempt counter or re-file duplicate routed work.

Janitor does not write product code, author requirements, create arbitrary Buildables, hand-edit the
tracker, or fabricate history. Repairs are frozen, simulated, idempotent, read back, and receipted.
After three non-converging passes it stops with exact blockers; it never advances a clean checkpoint
over unresolved facts.

### 4.5 Autorun, Doctor, and Stop

- Doctor remains read-only and reports Path Gate, graph, journal, receipt, ruleset, and baseline
  health. Controlled-mode failures are blocking, not warnings.
- Autorun runs a cheap deterministic reconciliation preflight on every pass and cannot report
  `drain: complete` while any graph, journal, receipt, tracker, Intake, Recirculation, recovery, or
  baseline obligation is unresolved.
- Stop and command closeout fail closed without a valid terminal command receipt. The current
  fourth-attempt `LOUD-FAIL` allow is removed. The attempt ceiling controls autonomous repair/retry,
  not permission to falsely finish.
- Missing, corrupt, or unreadable ledger/journal/receipt state is `indeterminate`, never an empty or
  clean state. Recovery commands remain available so the repository cannot be permanently wedged.

---

## 5. Audit remediation map

| Audit threat | Required correction | Blocking surfaces |
|---|---|---|
| T1 — nonterminal `Done` | Preserve typed terminal operations and add Path Gate/CI coverage around the existing engine. | Transition, hooks, CI |
| T2 — close/dispose without evidence | Preserve structural checks; require source-owned execution/review witnesses and exact live bindings. | Transition, Finisher, CI |
| T3 — raw GitHub bypass | Deny outside active commands too; cover all write tools; require Path Gate authorization; protect merge with deterministic CI; optionally make the App sole tracker writer. | Runtime hooks, Git hooks, ruleset, CI/App |
| T4 — raw filesystem/TRACKER mutation | Make filesystem explicitly non-secure; deny supported-runtime writes; require journal parity for every completion/repair; prohibit Janitor from laundering raw `Done`. | Hooks, replay, Janitor, drain |
| T5 — premature Stop | Remove fail-open exhaustion; treat corrupt ledger as indeterminate; preserve recovery-only access. | Stop, closeout, command contract |
| T6 — divergence accepted as complete | Run graph/journal parity in drain, Autorun closeout, Finisher, terminal transitions, and Janitor apply. | Drain, Autorun, Finisher, Janitor |
| T7 — forged concordant evidence | Mandatory source-owned journals, external execution witnesses, reciprocal live PR/gate/review binding, version/diff freshness, and optional App authority. | Receipts, gate proof, transition, CI |

T1 and T2 are retained as foundations. T3–T7 are release blockers for the new controlled profile.

---

## 6. Adoption, failure handling, and recovery

Upgrading an existing repository creates `reconciliation-baseline-required`. `/idc:update` installs
the new deterministic machinery, then delegates to `/idc:janitor --bootstrap`. Until bootstrap is
complete, ordinary mutating workflow commands are blocked while Doctor, Intake, Janitor, update,
and recovery remain available.

The adoption receipt records the current default-branch commit, tracker and graph digests, active
items, open PRs/branches/worktrees, existing receipts/journal, routed obligations, and an empty
unresolved list. `legacy-adopted` means only that missing pre-boundary receipts are tolerated; it is
not proof that old code was correctly planned, tested, or reviewed.

Failure rules are fixed:

- relevant concurrent tracker change invalidates the frozen projection and requires recompile;
- partial remote application preserves applied/unapplied operations and creates a recovery
  obligation; it is never blindly rolled back;
- loss of a local cache triggers reconstruction from durable evidence, not amnesty;
- a stale or malformed receipt is rerun or reconciled, never replaced by hand;
- optional code-provider failure reduces stated coverage but does not disable the core graph;
- destructive cleanup always requires explicit operator authority and is separate from repair.

---

## 7. Implementation sequence

Each step must land with focused negative tests and remain compatible with repositories that have not
yet entered the new adoption baseline.

1. **Correct the contract language.** Update the PRD, master architecture, `WORKFLOW.md`, README, and
   config schema to define pathway guardrails, enforcement profiles, and the honest threat model.
2. **Fix the audit foundation.** Make journaling/obligations mandatory, make corrupt state
   indeterminate, block completion on divergence, require live reciprocal gate/review binding, and
   remove bounded Stop/closeout permission to finish falsely.
3. **Build the authoritative graph.** Compile the full planning horizon, normalize resources,
   validate graph↔tracker parity, derive deterministic Waves, and produce a frozen tracker
   projection and pure simulator.
4. **Add the shared Path Gate.** Implement one policy engine plus thin Claude, Codex, and Pi adapters;
   add Git backstops and protect raw tracker/merge/receipt surfaces.
5. **Add tracker transactions.** Convert every sanctioned mutation path to obligation → simulate →
   apply → mandatory journal → exact readback → receipt, including recovery and terminal operations.
6. **Add Build auto-validation.** Emit ticket contracts after matrix analysis, materialize/freeze only
   missing behavior gates at Build entry, bind them to the actual diff, and feed deterministic
   failures through the existing record-and-vary attempt loop.
7. **Expand Intake and activate Janitor.** Add PR/branch pinning, explicit adoption/reconciliation
   receipts, bounded investigation, guarded repair, dedupe, and bootstrap migration.
8. **Enforce at integration.** Ship the version-pinned `idc/pathway-integrity` GitHub workflow and
   ruleset installer/checker; add the optional App-locked tracker writer without making it a normal
   dependency.
9. **Pilot and enable by default.** Run the adoption flow in sandbox repositories, then one real
   GitHub-backed pilot. Enable `controlled` by default only after pathway false positives and Janitor
   convergence are within the acceptance limits below.

No remote LLM validator, arbitrary generated tracker script, mandatory code-index service, new
top-level workflow stage, or destructive automatic cleanup is part of this implementation.

---

## 8. Verification and release acceptance

### Deterministic tests

Tests MUST prove at least:

- shell, Write/Edit, `apply_patch`, direct `TRACKER.md`, raw GitHub tracker, and raw merge mutations
  are denied without the correct live authorization;
- an authorization cannot cross ticket, branch, graph node, path, action, expiry, or contract digest;
- a tracker transition is not usable until its journal and exact readback succeed;
- partial tracker application persists a recoverable obligation and cannot report completion;
- unexpected-green and indeterminate baselines stop before implementation/mutation;
- the builder cannot modify the frozen gate;
- the fixed surface/evidence table is enforced mechanically, `surface:none` requires a one-line reason, and impossible evidence kinds are refused;
- the governed verification-handle registry is schema-checked and secret-free before citation/use, missing handles create named obligations, and doctor warns on nonexistent citations;
- only named fixed risk inputs trigger divergent discovery, trivial tickets skip, majority-defeated gates are discarded or repaired, and discovery preserves the fixed validator/frozen-gate/path/attempt inputs;
- a final diff outside `touch`, inside `off-limits`, or different from the tested/reviewed diff fails;
- shaped PASS, forged journal, one-sided gate marker, stale witness, and wrong-source check fail;
- graph omissions, dependency cycles, normalized path collisions, Wave contradictions, and live board
  projection drift fail;
- corrupt ledger/journal/receipt state fails closed while recovery commands remain usable;
- repeated Stop attempts never convert unresolved work into a successful finish;
- outside PR/branch work is preserved, pinned, and routed; merged outside work receives reconciliation
  rather than forged implementation history;
- Janitor deduplicates against all previously seen findings, including rejected, refuses
  unvalidated operations, and halts after three non-converging passes;
- seen-finding ledgers are persisted before disposition across Janitor passes and review→fix→
  re-review rounds — covering rejected, refuted, below-floor, and filed findings — and a resurfaced
  seen finding cannot recycle the Janitor pass counter or the review attempt counter, cannot re-file
  duplicate routed work, and an unvalidated direct (model-authored) ledger write fails closed;
- adoption tolerates pre-boundary missing receipts but detects all post-boundary unreceipted facts;
- filesystem mode remains functional for hermetic tests while refusing the controlled security claim.

### Repository gates

Before release:

```bash
bash scripts/lint-references.sh
bash tests/smoke/run-all.sh
bash scripts/run-evals.sh
```

All MUST exit 0. The smoke suite must include kill/restart and partial-application cases. Separate
GitHub-fidelity sandbox runs must demonstrate controlled-mode hook denial, required-check merge
blocking, tracker transaction recovery, outside-path Intake, bootstrap adoption, and a clean
rerun. App-locked mode requires one live test showing an ordinary write token cannot mutate the
tracker while the App can complete the sanctioned transaction.

### Pilot acceptance

The pilot is acceptable only when:

- zero known unreceipted mutations can produce `Done`, `drain: complete`, or a mergeable check;
- tracker/graph divergence is blocking and every injected divergence has a working recovery route;
- clean Path Gate checks add negligible interaction overhead and no extra model call;
- the common ticket reuses its existing tests without generating a redundant script;
- off-path work is preserved and routed without data loss;
- optional code-intelligence absence does not block normal Plan/Build operation.

---

## 9. Research basis

Fusion Harness supplies the useful pattern—validator before builder, baseline proof, frozen gate,
exact failure feedback, independent repair, and bounded attempts—but IDC will implement the pattern
with its own fixed validators and manifests. Its current reference implementation warns and
continues on an unexpectedly green baseline, which is too weak for IDC's tracker authority.

- [Fusion Harness auto-validation loop](https://github.com/disler/fusion-harness/blob/5852f2ed4f5f064a368d83d2dabad84fe6bfa0b4/README.md#the-auto-validation-loop)
- [Fusion Harness validator prompt](https://github.com/disler/fusion-harness/blob/5852f2ed4f5f064a368d83d2dabad84fe6bfa0b4/extensions/fusion-harness/SYSTEM_PROMPT_VALIDATOR.md)
- [Fusion Harness runtime](https://github.com/disler/fusion-harness/blob/5852f2ed4f5f064a368d83d2dabad84fe6bfa0b4/extensions/fusion-harness/fusion-harness.ts)
- [Video discussion that motivated the comparison](https://www.youtube.com/watch?v=AQl5Q-0l7FQ)
- [OpenAI: Harness engineering](https://openai.com/index/harness-engineering/)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Codex hooks](https://learn.chatgpt.com/docs/hooks)
- [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [GitHub workflow execution protections](https://docs.github.com/en/organizations/managing-organization-settings/actions-policies/workflow-execution-protections)

---

## 10. Final invariant

IDC may call a controlled repository coherent only when:

```text
admitted intent
    = authoritative execution graph
    = frozen tracker projection
    = live tracker state
    = authorized Git/PR diff
    = current validation + review + finish evidence
    + every known exception represented by a routed obligation
```

If any term is missing, stale, corrupt, forged, or indeterminate, the affected work does not advance.
