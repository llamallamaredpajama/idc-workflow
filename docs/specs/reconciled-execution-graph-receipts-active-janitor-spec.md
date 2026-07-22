# IDC Reconciled Execution Graph, Receipt-Backed Validation, and Active Janitor Specification

- **Status:** Proposed
- **Date:** 2026-07-21
- **Scope:** IDC plugin architecture and governed-repository contract
- **Upstream:** Extends `docs/specs/master-architectural-spec.md`, `docs/architecture.md`, and the existing Plan → Build → Recirculator → Autorun workflow
- **Research inputs:** CodeGraph, Graphify, GitNexus, and Fusion Harness; see §16

> This specification makes IDC's planning graph, tracker projection, implementation evidence, and
> reconciliation loop one enforceable system. It does not replace IDC's transition engine, review
> filter, finisher, Recirculator, or live verification. It connects them with a complete work graph,
> machine-owned receipts, gate-first validation, and an active Janitor.

Normative terms **MUST**, **MUST NOT**, **SHOULD**, and **MAY** have their usual RFC-style meanings.

---

## 1. Executive decision

IDC will add a deterministic **reconciled execution graph** covering all work in the current planning
horizon and its projection onto the live tracker. The graph will connect planned work to gates,
tracker state, Git/PR facts, implementation surfaces, verification evidence, and reconciliation
obligations.

The authoritative graph will be IDC-native and dependency-light. Source-code intelligence providers
such as CodeGraph or Graphify MAY enrich it, but they will remain optional evidence providers. Their
absence or incomplete language coverage MUST NOT prevent IDC from performing its core planning,
tracking, boundary, receipt, and reconciliation checks.

IDC will also:

1. derive Waves mechanically from dependencies and resource conflicts;
2. validate the intended tracker end state before mutating the board;
3. prove the live board equals that frozen intent after mutation;
4. produce implementation receipts bound to actual Git diffs and executed verification;
5. turn `/idc:janitor` from a primarily report-oriented scanner into the active reconciliation
   control plane;
6. establish a one-time adoption baseline when a governed repository upgrades to this receipt regime;
7. reconcile incrementally from that baseline rather than scanning arbitrary historical code forever.

The invariant is not “every historical action used IDC.” It is:

> Every fact after the adoption boundary is either backed by valid IDC evidence, repaired through a
> guarded door, or represented by a durable obligation routed into the correct IDC pathway.

---

## 2. Problem statement

IDC already has strong enforcement at several boundaries:

- the raw-mutation interlock;
- the `idc_transition.py` state machine, readback, and transition journal;
- Plan closeout checks over consideration coverage, schemas, and provenance;
- review-verdict validation;
- receipt-gated finish and tracker-close verification;
- acceptance, live-surface, finish-coherence, recovery, drain, and Stop gates;
- the existing Git/board Janitor scanner.

The remaining weaknesses are between those boundaries:

1. **No authoritative whole-planning-horizon graph.** Plan is instructed to compare new work against
   pending considerations, open/in-flight items, and the current codebase, but no single compiler
   proves that all of those facts were reconciled into one graph.
2. **Matrix validation is structurally incomplete.** Duplicate IDs, normalized/contained path
   overlaps, invalid Wave values, dependency/Wave contradictions, and graph↔board edge mismatches can
   escape current mechanical checks.
3. **Waves are model-authored.** The dependency graph and resource-conflict graph do not yet compile
   into reproducible Waves.
4. **Tracker application is not gate-first.** The same planning process helps define the desired
   state, applies it, and then verifies only selected properties. There is no frozen expected board
   projection checked before and after mutation.
5. **Implementation boundaries are not fully receipt-backed.** Review playbooks require workers to
   stay within `BOUNDARIES`, but the finisher does not yet mechanically prove that the actual PR diff
   is within the declared `touch` surfaces and outside every `off-limits` surface.
6. **Per-issue verification is less strongly witnessed than live verification.** Review evidence is
   validated, but a general machine-owned receipt does not yet bind the executed verification command
   to the final implementation commit.
7. **Janitor is too passive for its architectural role.** It can detect and safely repair selected
   board/Git drift, but it does not yet investigate ambiguous facts, reconstruct work done outside the
   pathway, or route that work back through Think, Plan, Build, or Recirculation.
8. **Legacy adoption is partial.** The transition journal already has a principled legacy watermark,
   but there is no repository-wide adoption receipt spanning tracker, Git, planning, and
   implementation evidence.

---

## 3. Goals and non-goals

### 3.1 Goals

The system MUST:

- represent every active planning-horizon work object exactly once;
- distinguish declared, observed, inferred, and adopted facts;
- validate graph structure and graph↔tracker parity deterministically;
- derive reproducible Waves while keeping native dependencies authoritative for readiness;
- validate proposed tracker mutations against a simulated end state before writing;
- validate the actual live tracker against the same frozen end state after writing;
- detect relevant concurrent tracker change and refuse stale application;
- bind completed implementation to its issue, PR, actual diff, verification, review, and merge;
- detect post-baseline repository/tracker facts without valid receipts;
- investigate ambiguous findings using bounded, read-only specialists;
- route discovered work to the correct IDC altitude;
- apply evidence-backed, non-destructive repair automatically through existing guarded doors;
- preserve ambiguous work and fail closed on indeterminate ground truth;
- remain idempotent and kill-recoverable;
- support filesystem and GitHub tracker backends;
- preserve IDC's runtime-neutral core and thin runtime adapters.

### 3.2 Non-goals

The system MUST NOT:

- infer functional correctness from a source graph alone;
- use CodeGraph, Graphify, GitNexus, or any other code index as scheduling authority;
- require complete symbol-level analysis for every language;
- infer future semantic work dependencies solely from current code calls/imports;
- allow Janitor to author requirements, sequence plans, or modify source code directly;
- bypass Think's requirements gate;
- bypass Plan's ownership of decomposition and graph admission;
- replace real functional tests or the review engine;
- automatically delete dirty/unmerged work or other ambiguous data;
- scan the repository's entire pre-adoption history on every Janitor run;
- treat a legacy adoption receipt as proof that historical implementation was tested or reviewed.

---

## 4. Design principles

### 4.1 One graph, multiple authority classes

All related facts share one interchange graph, but not every edge has equal authority. A native
blocked-by relationship observed on the tracker is different from an inferred call edge produced by
an optional indexer. Consumers MUST filter by authority and evidence class.

### 4.2 Complete work graph, explicitly partial code evidence

“Complete graph” means complete over IDC's planning horizon: no admitted, buildable, in-flight,
gated, recirculating, or reconciliation work is silently omitted. Code-impact evidence MAY be
partial. Partial coverage MUST be disclosed in a coverage manifest; “unsupported” MUST never be
reported as “no impact.”

### 4.3 Gate first, then mutate, then prove

For both planning application and Janitor repair, IDC MUST define the expected end state before live
mutation, validate it against a pure simulation, freeze it, apply only its allowed operations, and
then prove the live state equals the frozen expectation.

### 4.4 Source-owned evidence

An agent-authored claim such as `exit: 0`, `merged: true`, or `board coherent` is not a receipt. A
receipt MUST be produced by the script that executed or re-derived the fact, carry its provenance,
and be independently re-checkable where the underlying system permits.

### 4.5 Existing write doors remain authoritative

The graph compiler, investigators, validators, and code-intelligence providers are read-only. All
tracker writes MUST continue through the transition engine, sanctioned finishers, or existing
special-purpose guarded repair doors. The raw-mutation interlock remains in force.

### 4.6 Preservation before cleanup

Janitor first preserves and accounts for work, then routes or repairs it. Destructive cleanup is a
separate, explicit action after evidence proves the work is merged or otherwise disposable.

### 4.7 Checkpoints accelerate; they do not prove

A local scan cursor MAY reduce repeated work, but deleting it MUST only cause a deeper rescan. It MUST
NOT erase obligations or manufacture a clean verdict. Durable evidence remains reconstructable from
the adoption baseline, tracker/Git facts, journals, and receipts.

---

## 5. Reconciled execution graph

### 5.1 Planning horizon

Every compilation MUST include:

- admitted and pending considerations in the current Plan batch;
- all `Stage=Buildable` items in `Todo`, `Blocked`, or `In Progress`;
- `In Progress` work as immutable planning occupancy;
- requirements and operator-decision gates affecting open work;
- open `Stage=Recirculation` items;
- active Janitor reconciliation obligations;
- canonical plan and provenance references needed by those items;
- native tracker dependency edges;
- declared `touch` and `off-limits` resource surfaces;
- relevant branches, commits, PRs, merge states, and receipts;
- optional code-impact evidence with coverage metadata.

Closed historical work MAY be represented by compact evidence references rather than expanded nodes,
unless it affects an active dependency, deferral, provenance chain, or reconciliation finding.

### 5.2 Core node kinds

The normalized schema MUST support at least:

| Node kind | Examples |
|---|---|
| canonical | PRD section, TRD section, master/subphase/pillar plan |
| consideration | admitted or gate-pending input to Plan |
| work | logical pillar, tracker Buildable, reconciliation-audit obligation |
| gate | requirements gate or operator-decision gate |
| tracker | issue/project item and its live fields |
| git | branch, worktree, commit, PR, merged commit |
| resource | file, normalized directory surface, named exclusive resource |
| code | optional symbol/module/test/config node |
| evidence | planning, implementation, verification, review, finish, adoption, reconciliation receipt |
| obligation | recirculation, deferral, missing evidence, repair, or indeterminate-state obligation |

A logical work node and its tracker item are distinct identities connected by projection/provenance;
this permits pre-creation simulation before an issue number exists.

### 5.3 Core edge kinds

The schema MUST support at least:

| Edge | Meaning |
|---|---|
| `TRACES_TO` | work derives from a canonical requirement/plan |
| `DECOMPOSES_TO` | consideration/plan decomposes into work |
| `BLOCKS` | semantic/native prerequisite ordering |
| `GATED_BY` | work waits for a proven human-gate outcome |
| `CONFLICTS_WITH` | two work nodes share a normalized exclusive surface |
| `PROJECTS_TO` | logical work is represented by a tracker item |
| `CLAIMED_BY` | work is owned by a session/branch/worktree |
| `IMPLEMENTED_BY` | work is implemented by a commit or PR |
| `TOUCHES` | declared or observed work/PR surface |
| `IMPACTS` | code evidence suggests a related surface/symbol/test |
| `VALIDATED_BY` | work is covered by verification/review evidence |
| `MERGED_AS` | PR landed as a concrete merged commit |
| `CLOSES` | PR or reconciliation closes a tracker item |
| `ROUTED_TO` | anomaly is routed to an IDC stage or obligation |
| `ADOPTED_AT` | pre-receipt fact was accepted at the adoption boundary |
| `SUPERSEDES` | newer evidence replaces a stale receipt/projection |

`CONFLICTS_WITH` is a resource constraint, not automatically a semantic `BLOCKS` edge. Build's area
packing and merge leases consume conflicts without lying about task dependencies.

### 5.4 Evidence envelope

Every node and edge MUST carry or reference:

- stable identity;
- origin/provider;
- observed repository commit when relevant;
- tracker snapshot/digest when relevant;
- source location or remote object identity;
- fact class: `declared`, `observed`, `inferred`, or `adopted`;
- confidence: `exact`, `high`, `ambiguous`, or `unknown`;
- authority: `core`, `provider`, or `advisory`;
- freshness/staleness metadata;
- evidence references.

The compiler MUST reject an inferred/provider edge presented as core authority.

### 5.5 Code-evidence provider protocol

IDC MUST always provide a dependency-free native provider for:

- tracked files;
- Git diffs;
- branches/commits/PRs;
- declared path surfaces;
- repository-native test/config references IDC already knows.

Optional providers MAY add file, symbol, import, call, route, or test-impact evidence. Provider output
MUST include:

- provider name and version;
- indexed HEAD;
- indexed file count and repository tracked-file count;
- covered and unsupported languages/file types;
- unresolved-reference count;
- node/edge evidence with confidence;
- a clear status: `complete-for-declared-scope`, `partial`, `stale`, `failed`, or `unavailable`.

Provider failure MUST NOT disable the native work/tracker/resource graph. It MUST be reported and MUST
prevent any claim that code evidence was complete.

---

## 6. Graph validation and sequencing

### 6.1 Structural validation

Before tracker mutation, the compiler MUST reject:

- duplicate logical/pillar IDs;
- duplicate tracker projection identities;
- missing dependency or gate targets;
- dependency cycles;
- invalid domain, phase, stage, status, or Wave values;
- non-positive or non-integral Waves where a Wave is required;
- dependency order that contradicts the projected Wave order;
- normalized path aliases;
- directory/file containment treated as disjoint;
- same-Wave resource conflicts;
- missing consideration coverage;
- missing goal-contract/provenance/schema evidence;
- unauthorized mutation of `In Progress` work;
- graph members absent from the expected tracker projection;
- live tracker members that should be in the planning horizon but are absent from the graph;
- graph dependency/gate edges that do not equal expected native tracker blockers;
- tracker blockers with no graph justification;
- matrix, issue body, provenance, Wave, Phase, Domain, or boundary mismatch.

Path normalization MUST account for at least `.` components, repeated separators, repository-root
anchoring, trailing directory separators, and directory containment. Paths escaping repository root
MUST fail closed.

### 6.2 Derived Waves

Models MUST NOT be the final author of Wave numbers. Plan remains responsible for semantic
`BLOCKS` relationships and declared ownership surfaces; the compiler derives Waves.

For every not-yet-started Buildable, the compiler MUST:

1. treat satisfied/Done predecessors as complete;
2. treat `In Progress` nodes as immutable, currently occupied work;
3. calculate the dependency-ready frontier;
4. exclude nodes conflicting with occupied resources;
5. order the remaining frontier by descending critical-path priority, then stable graph identity;
6. choose a deterministic maximal resource-disjoint subset;
7. assign that subset to the next Wave;
8. repeat until all schedulable nodes are ranked;
9. retain explicit blockers for unschedulable/gated nodes rather than inventing readiness.

The same input snapshot MUST always yield the same Waves.

### 6.3 Readiness versus Wave

Native dependency/gate edges remain authoritative for Build readiness. `Wave` is the deterministic
planning projection and operator visualization, not a runtime readiness gate. Whole-board area
packing and surface-keyed merge leases remain the runtime collision defenses.

### 6.4 Tracker projection

The compiler MUST emit an exact expected projection containing:

- logical work ID → tracker item identity (or a pre-creation identity placeholder);
- Stage, Status, Wave, Phase, and Domain;
- native blocked-by relationships;
- goal-contract/provenance/body digest;
- normalized owned and off-limits surfaces;
- matrix membership and upstream trace;
- allowed creates, field changes, links, pointer retirements, and no-op items;
- fields/items that MUST remain unchanged.

The projection, not model prose, is the input to tracker application and postcondition validation.

---

## 7. Gate-first validation for Plan and tracker writes

IDC will adapt Fusion Harness's validator-before-builder method to tracker mutation. IDC will adopt
the pattern, not its literal arbitrary-script implementation.

### 7.1 Planning obligation gate at entry

At Plan entry, before board mutation, IDC MUST capture:

- the exact admitted consideration set and content hashes;
- the start-time planning horizon;
- the start board digest;
- immutable `In Progress` facts;
- gates and reconciliation obligations;
- required structural and coverage assertions.

This gate defines what Plan must account for independently of Plan's later claim that it succeeded.

### 7.2 Baseline semantics

The planning gate MUST run against the initial state.

- `expected-red`: new admitted work is not yet decomposed/projected; a red gate proves the check is
  live.
- `expected-green`: a proven idempotent/no-op rerun whose expected delta is empty.
- `unexpected-green`: expected delta is non-empty but the gate passes; this is a weak/defective gate
  and MUST stop before mutation.
- execution error/timeout: indeterminate and MUST stop before mutation.

This is intentionally stricter than Fusion Harness's current “warn and continue” posture on a
baseline pass.

### 7.3 Candidate build and pure simulation

Plan authors candidate canonical plan artifacts, goal contracts, semantic dependencies, and declared
surfaces without mutating the board. The compiler derives the graph, Waves, expected tracker
projection, and an ordered action plan.

A pure simulator MUST apply the proposed action plan to the start snapshot in memory. The full graph
and projection validators MUST pass against the simulated state before any live write. Failures feed
back to Plan as exact expected-versus-actual corrections.

### 7.4 Frozen gate

Once the simulated end state passes, IDC MUST freeze:

- input obligation manifest;
- candidate graph digest;
- expected board projection;
- allowed action plan;
- immutable/no-touch set;
- validator version and digest.

Plan and the tracker executor MUST NOT be able to modify the frozen gate. Fixed core invariants are
shipped code and MUST NOT be weakened or repaired at runtime.

Task-specific semantic assertions MAY be repaired only when an independent validator demonstrates a
gate defect. The previous assertion set MUST be preserved, the repair MUST be audited, and legitimate
checks MUST NOT be removed.

### 7.5 Optimistic concurrency before apply

Immediately before applying, IDC MUST reread relevant tracker state. If it changed since the frozen
snapshot:

- unrelated changes MAY be rebased by recompiling against the new snapshot;
- changes touching a projected/immutable item or edge MUST invalidate the gate;
- IDC MUST rerun simulation and freeze a new projection before writing;
- it MUST NOT apply operations against stale assumptions.

### 7.6 Guarded apply

The executor applies only frozen operations through existing sanctioned doors. Every successful
operation MUST be journaled and read back. Operations MUST be idempotent.

Because GitHub Projects does not offer one transaction across all items/fields/links, partial failure
MUST NOT trigger a blind rollback. The unapplied or divergent remainder becomes a named Janitor
obligation tied to the frozen projection.

### 7.7 Live postcondition gate

After application, IDC MUST reread the live board and require exact normalized equality with the
frozen projection, including:

- item existence and logical-ID mapping;
- fields;
- native blockers;
- provenance/body digests;
- pointer disposition;
- immutable items;
- absence of mutations outside the allowed action set.

Failure lines MUST be specific enough for deterministic repair. Semantic failures return to Plan;
partial-application/state failures route to Janitor.

### 7.8 Planning application receipt

A green postcondition produces a source-owned planning receipt containing at least:

- planning command/session identity;
- start board digest;
- input consideration IDs and hashes;
- gate/validator digest;
- expected graph/projection digest;
- applied operations and transition-journal references;
- final board digest;
- final live validation result;
- optional provider coverage manifest.

Plan cannot close its command lifecycle without this receipt.

### 7.9 Build acceptance gate

Build SHOULD use the same validator-before-implementation pattern at issue start, complementary to
Plan's tracker-projection gate:

1. bind the issue's goal contract, upstream trace, graph node, predicted surfaces, and current code
   commit;
2. have an independent read-only validator materialize the task-specific acceptance gate before the
   implementer changes source;
3. require every explicit outcome/constraint/verification obligation to map to an objective check;
4. run the baseline and classify it as expected-red, proven already-complete, unexpected-green, or
   indeterminate;
5. freeze the gate outside the implementer's write authority and record its digest;
6. let the implementer iterate against exact gate failures;
7. escalate repeated failures to independent triage;
8. allow only the validator to repair a demonstrated task-specific gate defect, preserving the old
   gate and never weakening a legitimate check;
9. halt at a bounded attempt cap;
10. feed the final execution result and gate digest into the implementation receipt.

A proven already-complete baseline is not permission to invent a no-op implementation. Build MUST
hand it to Janitor/Plan for classification as prior accounted work, outside-path work needing a
reconciliation audit, or an idempotent already-satisfied obligation.

The Build acceptance gate augments rather than replaces the issue's declared verification surface,
TDD, the review engine, CI, boundary validation, and live-surface checks. Fixed security, schema,
receipt, and boundary invariants remain shipped IDC code; task-specific executable checks may be
validator-authored under the frozen-gate contract.

---

## 8. Receipt architecture

### 8.1 Receipt classes

IDC MUST support at least:

| Receipt | Claim |
|---|---|
| `planning-application` | a frozen graph projection was applied and proven live |
| `verified-implementation` | a work item is bound to a real diff, tests, review, and merge path |
| `verification-execution` | named commands executed against named code and produced observed results |
| `verified-reconciliation` | Janitor independently validated pre-existing/outside-path work |
| `legacy-adopted` | fact existed before the adoption boundary; no historical quality claim |
| `routed-obligation` | anomaly is accounted for but still requires pipeline work |
| `finish` | merge and tracker terminal state were verified |
| `attested` | explicit exceptional human evidence; visibly weaker than execution |

A weaker receipt MUST never be silently upgraded into a stronger claim.

### 8.2 Implementation receipt

Every normal Build completion MUST bind at least:

- issue and logical graph-node identity;
- PR and base/head/implementation commit identities;
- actual changed paths and diff digest;
- normalized boundary check result;
- verification commands, exit codes, bounded redacted output references, and code commit tested;
- review verdict identity/digest and PR/issue ownership;
- findings/deferrals/merge-condition routing;
- provider coverage used for impact evidence;
- final merge and tracker-close evidence or references to the finish receipt.

The actual PR diff is stronger evidence than predicted surfaces. The finisher MUST refuse when:

- actual changed paths exceed declared `touch` surfaces;
- any actual changed path intersects `off-limits` surfaces;
- the receipt names a different issue, PR, or diff;
- verification predates relevant final code changes;
- the review verdict covers a different diff;
- the graph/projection is stale for the work being closed;
- routed obligations or merge conditions remain unmet.

### 8.3 Execution witnesses

Where a command result cannot be recomputed from committed/remote state, IDC MUST use the same
principle as live verification: a machine-generated receipt plus a non-self-authored execution
witness. Valid witness sources MAY include:

- local repository-Git-directory evidence;
- CI/check-run identity and result;
- a trusted remote artifact store;
- an explicit `attested` exception when automation is genuinely impossible.

A committed JSON file containing a typed `exit: 0` is insufficient by itself.

### 8.4 Freshness and supersession

Receipts MUST carry the facts that make them stale: commit/diff digests, command text, relevant paths,
tracker projection, and validator version. A later relevant change MUST invalidate or supersede the
receipt. Supersession MUST preserve the old evidence for audit.

### 8.5 Durable versus cached storage

The adoption baseline and evidence required to reconstruct obligations MUST be durable and
clone-portable. Local cursors, compiled graph caches, and performance indexes MAY be ignored working
state. Loss of a cache MUST never lose a receipt or obligation.

Exact receipt storage layout is an implementation-plan decision, but it MUST avoid self-referential
commit hashes, concurrent-writer collisions, and agent-selectable alternate receipt paths.

---

## 9. Active Janitor

### 9.1 Command role

`/idc:janitor` becomes the active reconciliation control plane.

Proposed command surface:

| Invocation | Behavior |
|---|---|
| `/idc:janitor` | investigate, route, apply non-destructive evidence-backed repair, read back, rescan |
| `/idc:janitor --report` | read-only full report |
| `/idc:janitor --bootstrap` | create the one-time adoption baseline |
| `/idc:janitor --cleanup` | additionally perform explicitly authorized proven-safe cleanup |

The existing `--apply-safe` behavior MAY remain as a backward-compatible alias/subset during
migration, but useful non-destructive reconciliation is the new default.

### 9.2 Reconciliation loop

Janitor MUST run:

```text
observe → match → investigate → propose → validate → apply → read back → rescan
```

1. **Observe:** compile one consistent graph/snapshot.
2. **Match:** connect every post-baseline fact to valid evidence.
3. **Group:** deduplicate multiple symptoms with the same root fact/surface.
4. **Investigate:** use bounded read-only specialists only where deterministic classification is
   insufficient.
5. **Propose:** emit a structured route/repair plan with stable finding identity.
6. **Validate:** independently challenge evidence, classification, altitude, and safety.
7. **Check:** deterministic allowlist validation of every proposed operation.
8. **Apply:** use existing guarded doors in preservation-first order.
9. **Read back:** verify actual Git/tracker state.
10. **Rescan:** prove convergence or name remaining obligations.

### 9.3 Investigator roles

Bounded fan-out MAY include:

- Git/PR investigator;
- tracker/state investigator;
- canonical-plan/provenance investigator;
- implementation/test validator;
- independent adversarial route validator.

Investigators and validators MUST be read-only. Runtime adapters map bounded fan-out to the concrete
runtime without changing this process.

### 9.4 Structured finding/repair contract

Every proposed repair MUST include:

- stable finding/dedupe ID;
- observed facts and evidence references;
- classification;
- affected graph nodes/surfaces;
- proposed IDC route;
- exact operations;
- expected end-state assertions;
- verification steps;
- confidence and indeterminate facts;
- destructive/non-destructive classification.

The executor MUST refuse an operation absent from the validated frozen repair plan.

### 9.5 Routing matrix

| Observed state | Required route |
|---|---|
| PR merged, tracker stale | existing finish recovery or guarded tracker repair |
| planned pillar exists, tracker projection missing | Plan reconciliation |
| requirement already covers work, but plan does not | Recirculation → consideration → Plan |
| new/changed product behavior exceeds requirements | Think's existing requirements gate |
| unmerged outside-workflow implementation | preserve branch/PR; route to Plan/Build adoption and full review |
| merged outside-workflow implementation | reconciliation-audit obligation; validate, then receipt or corrective Build work |
| Buildable with incomplete implementation | Resume/Build |
| undocumented dependency or canonical drift | Recirculation |
| tracker item edited/created outside IDC | validate schema/provenance/state; backfill only proven evidence, otherwise route |
| dirty/ambiguous worktree or branch | preserve and investigate; never auto-delete |
| foreign-tool work affecting the repository | investigate and route; origin limits cleanup authority, not governance relevance |

Janitor does not directly create arbitrary Buildables. It invokes or records work for the stage that
owns that altitude.

### 9.6 Already-merged outside-path work

Already-merged code MUST NOT be relabeled as normal Build. Janitor MUST create or route a
reconciliation-audit obligation that:

- binds the existing commit/diff;
- compares behavior with requirements and plans;
- runs applicable functional verification;
- evaluates boundaries and affected surfaces;
- routes requirement/documentation drift;
- creates corrective Build work when necessary.

Only a successful independent audit may produce `verified-reconciliation`. That receipt remains
semantically distinct from `verified-implementation`.

### 9.7 Repair order and destructive boundary

Janitor applies in this order:

1. preserve evidence/work;
2. create/link reconciliation obligations;
3. add justified blockers to affected active work;
4. route into the proper stage;
5. apply non-destructive tracker/state corrections;
6. rerun validation and readback;
7. write reconciliation evidence/checkpoint;
8. optionally clean proven-safe artifacts under explicit cleanup authorization.

Janitor MUST NOT automatically force-delete branches, discard dirty changes, remove ambiguous
worktrees, rewrite history, close unproven work, or weaken gates/tests/security.

### 9.8 Bounded convergence

Repairs MUST be idempotent and deduplicated. A finding already represented by a durable obligation is
not filed again. After three non-converging passes, Janitor MUST stop with exact blockers and MUST NOT
advance the clean checkpoint past unresolved facts.

---

## 10. Adoption baseline and upgrade migration

### 10.1 Purpose

Repositories upgraded into the receipt regime contain legitimate pre-receipt tracker and Git state.
IDC MUST not flag every historical object forever, nor may it silently treat all existing state as
verified.

The one-time bootstrap creates an **adoption boundary**:

> IDC observed and accounted for this legacy state at this version and commit. Missing pre-boundary
> receipts are tolerated; every post-boundary change requires normal evidence.

### 10.2 Upgrade flow

The receipt-enabled `/idc:update` MUST:

1. install/resync the new scaffold and deterministic machinery;
2. write a durable `reconciliation-baseline-required` state;
3. delegate to `/idc:janitor --bootstrap`;
4. leave the marker present after any interruption or indeterminate scan;
5. permit recovery/diagnostic commands while the marker is present;
6. prevent ordinary mutating workflow commands from silently creating more unbaselined state;
7. clear the marker only after every observed fact is either coherent, repaired, or durably routed;
8. write the adoption receipt last.

The plugin update may be installed even if bootstrap is blocked; the repository is then explicitly
`baseline-pending`, not falsely current.

### 10.3 Bootstrap scan

Bootstrap MUST inspect current state rather than arbitrary full history:

- current board and all active items;
- open PRs;
- relevant recent merges and closing references;
- all local/remote non-default branches;
- linked worktrees;
- canonical plans/matrices/provenance;
- existing journal/receipts;
- current default-branch commit;
- detectable outside-path or unaccounted implementation facts.

Investigators handle ambiguous current facts. A separate explicit full-history audit MAY exist, but
is not part of normal bootstrap.

### 10.4 Adoption receipt semantics

The adoption receipt MUST include at least:

- repository identity;
- IDC and receipt schema versions;
- creation time and producing command;
- baseline default-branch commit;
- tracker and graph digests;
- per-item legacy adoption identity/state/evidence class;
- adopted open refs/worktrees that remain relevant;
- routed obligations and their tracker references;
- code-provider coverage;
- unresolved list, which MUST be empty for completion.

To avoid board spam, per-item adoption MAY be stored in one durable manifest rather than comments on
every issue.

`legacy-adopted` means only that missing earlier receipts are tolerated. Janitor MUST continue to
check the item's current state, future changes, blockers, implementation links, and contradictions.

### 10.5 Incremental reconciliation after adoption

Normal Janitor scans start from:

- the adoption baseline;
- current board/open refs/worktrees;
- transition journal;
- planning/implementation/review/finish/reconciliation receipts;
- facts since the last proven reconciliation checkpoint;
- current optional provider evidence.

A new fact with no matching receipt is an investigation candidate. A checkpoint advances only after
the fact is matched, repaired, or durably routed. Deleting a local cursor causes a rescan from durable
evidence; it does not grant amnesty.

---

## 11. Command integration

### 11.1 Doctor

`/idc:doctor` remains read-only. It runs the shared graph/receipt/Janitor validators, reports their
verdicts, and directs repair to Janitor. It MUST NOT mutate or spawn repair executors.

### 11.2 Plan

Plan owns semantic decomposition and dependency declarations. It consumes the whole-horizon compiler,
gate-first validation, simulated projection, guarded apply, live postcondition, and planning receipt.
Plan cannot close on a model-authored “done” claim.

### 11.3 Build

At claim, Build MUST verify graph readiness, current goal-contract/provenance identity, reconciliation
blockers, and resource availability. Before source mutation it SHOULD establish the frozen Build
acceptance gate in §7.9. At completion, Build/Finisher MUST require that gate's current execution
receipt, actual-diff boundary validation, and a fresh implementation/verification receipt.

### 11.4 Autorun

Autorun runs a cheap deterministic reconciliation preflight on every pass:

- clean: continue immediately;
- simple non-destructive drift: repair and continue;
- unmatched/ambiguous work: launch bounded Janitor investigation;
- routed obligation: re-enter the normal pipeline;
- affected work: block only the affected graph region where safe;
- unresolved reconciliation work: prevent a false `drain: complete`.

Janitor investigation SHOULD be demand-triggered by findings rather than paid on every clean pass.

### 11.5 Recirculator

The Recirculator remains the only retrograde path for scope/menu/canonical drift. Janitor routes to it
rather than editing canonical layers itself. Requirements-changing findings still reuse the one Think
PR gate.

### 11.6 Finisher and Stop gates

The finisher consumes implementation/verification receipts in addition to the current review receipt.
The drain and Stop fixpoint gates MUST treat unresolved graph-parity, missing-receipt, partial-apply,
and baseline-pending obligations as non-terminal work.

---

## 12. Failure handling and recovery

### 12.1 Indeterminate truth

Unreadable tracker state, corrupt baseline/journal/receipt, unresolved repository identity, stale
provider data presented as current, or an execution-gate error MUST be `indeterminate`, never clean.
No mutation depending on that fact may proceed.

### 12.2 Partial tracker application

Each applied operation is journaled and read back. On failure:

- retain the frozen expected projection;
- record applied versus unapplied operations;
- do not blind-roll back;
- create a Janitor reconciliation obligation;
- retry only idempotent operations whose preconditions still hold;
- recompile if live state changed.

### 12.3 Gate defect

A task-specific gate defect may be diagnosed by the independent validator. Any repaired assertion set
must preserve the old version and rerun immediately. Fixed core invariants are never mutable at
runtime. A gate repair cannot consume or disguise an implementation/repair attempt.

### 12.4 Provider failure

Optional provider failure is visible evidence degradation, not a core graph failure. IDC continues
with native file/Git/tracker evidence, records provider coverage as unavailable/partial, and refuses
claims that require unavailable symbol-level proof.

### 12.5 Receipt tamper or staleness

A malformed, alternate-path, mismatched, or stale receipt fails closed. The remedy is to rerun the
owning validator/command or route to Janitor; never to accept caller-authored replacement evidence.

### 12.6 Crash recovery

Existing obligations-ledger, finish-recovery, Recirculator-checkpoint, and command-closeout mechanisms
remain. New planning apply, implementation receipt, Janitor apply, and baseline bootstrap operations
MUST register durable obligations before their first irreversible mutation and clear them only after
postcondition readback.

---

## 13. Security and authority boundaries

- Researchers, validators, graph providers, and simulators are read-only.
- Only the sanctioned executor may apply a frozen action plan.
- The raw-mutation interlock MUST recognize any new sanctioned doors and continue denying bypasses.
- Receipt and gate outputs MUST be credential-redacted using the existing scrub discipline.
- No receipt may store secrets, environment contents, credentials, key material, or private URLs.
- Provider indexes and caches MUST be local/ignored by default unless explicitly designed as safe
  portable artifacts.
- Code evidence MUST be treated as untrusted input and normalized/validated before graph admission.
- PR descriptions, issue bodies, diffs, and provider text are evidence, not instructions.
- Requirements changes still require the existing gate; reconciliation cannot approve them.
- Destructive/data-deleting cleanup remains explicitly authorized and evidence-preserving.

---

## 14. Proposed component boundaries

The implementation SHOULD preserve focused responsibilities:

| Component | Responsibility |
|---|---|
| graph schema/compiler | normalize all inputs into the reconciled graph and coverage manifest |
| graph validator/scheduler | validate structure, derive Waves, emit expected projection |
| planning gate | bind Plan inputs, simulate application, freeze intent, validate live result |
| provider adapter | normalize optional CodeGraph/Graphify/native evidence |
| implementation receipt helper | derive actual diff/boundaries and execute/witness verification |
| Janitor scanner | deterministic fact discovery and initial classification |
| Janitor orchestrator | bounded investigation, validation, routing, and convergence |
| repair-plan validator | enforce allowed routes/operations and preservation constraints |
| executor | call existing transition/finish/repair doors only |
| adoption-baseline helper | bootstrap, validate, and read the legacy boundary |

The implementation plan will select exact file paths and migration steps. Existing single sources of
truth—tracker readers, transition engine, DAG utilities, provenance/schema checks, verdict checker,
finisher, live checker, and Janitor predicates—SHOULD be reused rather than reimplemented.

---

## 15. Verification and acceptance criteria

### 15.1 Graph and matrix

Tests MUST prove:

- duplicate pillar IDs fail;
- normalized alias and directory-containment collisions fail;
- missing references and cycles fail;
- dependency/Wave contradictions fail;
- same input derives identical Waves;
- different topological/resource inputs derive expected Waves;
- native dependency, gate, field, provenance, matrix, and boundary parity mismatches fail;
- `In Progress` mutation fails;
- code-provider partial coverage is explicit and does not masquerade as no impact.

### 15.2 Gate-first tracker application

Tests MUST prove:

- expected-red baseline fails before new work exists;
- an idempotent empty-delta baseline is explicitly expected-green;
- unexpected-green refuses mutation;
- invalid simulated state writes nothing;
- a frozen gate cannot be changed by the planner/executor;
- relevant concurrent board change invalidates/rebases before apply;
- partial application persists a repair obligation;
- exact live projection produces a valid planning receipt;
- extra/unexpected live mutation fails the postcondition.

### 15.3 Implementation receipts

Tests MUST prove refusal for:

- wrong issue or PR;
- diff digest mismatch;
- actual path outside `touch`;
- actual path under `off-limits`;
- verification run against stale code;
- review of a different diff;
- caller-typed/forged execution result;
- missing routed finding or unmet merge condition;
- stale graph/projection evidence.

A valid receipt MUST proceed through the existing merge/close verification tail.

### 15.4 Janitor and adoption

Tests MUST cover:

- bootstrap adoption of coherent legacy items without claiming historical verification;
- pre-boundary legacy items not generating permanent missing-receipt findings;
- post-boundary unreceipted tracker mutation detected;
- post-boundary direct/default-branch or PR work detected and routed;
- unmerged outside-path implementation preserved and adopted into Build;
- merged outside-path implementation creates a reconciliation audit;
- foreign-tool work affecting the repo is investigated but not auto-deleted;
- findings deduplicate across passes;
- checkpoint refuses to advance over unresolved facts;
- lost local cache causes rescan, not data loss;
- three non-converging passes halt with named blockers;
- filesystem and GitHub backend parity;
- kill/restart resumes bootstrap or repair without false completion.

### 15.5 End-to-end gates

Before release:

- `bash scripts/lint-references.sh` exits 0;
- `bash tests/smoke/run-all.sh` exits 0;
- existing Plan/DAG/frontier/provenance/finish/governance tests remain green;
- a hermetic real-Git lifecycle demonstrates planning receipt → implementation receipt → merge →
  Janitor coherent;
- sandbox GitHub-fidelity runs demonstrate bootstrap migration, tracker projection, outside-path
  routing, partial-apply recovery, and clean rerun;
- optional provider absence is tested;
- at least one source-heavy pilot repository measures provider usefulness.

### 15.6 Operational success metrics

The pilot SHOULD measure:

- planning-horizon omissions;
- dependency/order corrections before build;
- graph↔board divergence frequency;
- merge/file-surface conflicts;
- missing-boundary detections;
- outside-path work found and correctly routed;
- recirculation rate and repeated recirculation;
- Janitor convergence passes and false positives;
- planning time/API cost;
- optional impact-provider precision/recall for affected surfaces/tests.

---

## 16. External-tool assessment and reuse policy

### 16.1 CodeGraph

CodeGraph is MIT-licensed and provides useful multi-language symbol/call/import indexing, impact
queries, and incremental analysis. It is not a suitable mandatory IDC dependency or sequencing
authority because repository-language coverage can be incomplete—especially for Markdown/shell-heavy
workflow repositories—and source dependencies do not encode future semantic task ordering.

IDC MAY support CodeGraph through the provider protocol.

### 16.2 Graphify

Graphify is MIT-licensed and is architecturally closer to IDC's evidence needs: Tree-sitter-based
multi-language extraction, Bash and Markdown support, plain node/edge models, and confidence-aware
relationships. Its dependency and grammar footprint remains too large for the mandatory core.

IDC MAY reuse selected MIT-licensed extraction concepts or code with attribution, or support Graphify
as an optional provider. Any vendored code must retain the required license notice and pass IDC's
portability/security review.

### 16.3 GitNexus

GitNexus uses the PolyForm Noncommercial license, not a permissive open-source license compatible
with unrestricted IDC distribution. IDC MUST NOT copy or vendor GitNexus implementation code unless
the licensing constraint is explicitly accepted for the project. Its phase-DAG, scoped resolution,
typed-edge, and process-graph ideas MAY inform a clean-room implementation.

### 16.4 Fusion Harness

Fusion Harness is MIT-licensed. IDC adopts its gate-first principles:

- independent validator before implementation/mutation;
- baseline integrity check;
- immutable/frozen acceptance criteria;
- exact failure feedback;
- bounded correction;
- independent triage and audited gate repair.

IDC does not need a runtime dependency on Fusion Harness. The tracker gate SHOULD be a fixed IDC
validator consuming a frozen data manifest, not an arbitrary LLM-generated Python program. Fusion
Harness's own included artifacts demonstrate why: generated acceptance gates can contain defects, so
core invariants must remain fixed and gate repair must be explicit and audited.

Research was inspected at these upstream projects on 2026-07-21:

- <https://github.com/colbymchenry/codegraph>
- <https://github.com/Graphify-Labs/graphify>
- <https://github.com/abhigyanpatwari/GitNexus>
- <https://github.com/disler/fusion-harness> (inspected commit
  `5852f2ed4f5f064a368d83d2dabad84fe6bfa0b4`)

---

## 17. Rollout order

Implementation SHOULD land in independently verifiable slices:

1. harden matrix validation and add deterministic path normalization;
2. compile the authoritative whole-horizon work/resource graph;
3. derive Waves and validate graph↔board parity without mutation;
4. add planning-gate simulation, frozen projection, and live postcondition receipt;
5. add actual-diff boundary validation and implementation/verification receipts;
6. add active Janitor investigation/routing while retaining current scanner behavior;
7. add adoption-baseline migration through `/idc:update` + Janitor bootstrap;
8. wire reconciliation obligations into Autorun, finish, command closeout, and Stop gates;
9. add optional code-evidence provider adapters and run a source-heavy pilot;
10. only then consider selective MIT code reuse based on measured provider gaps.

Each slice MUST remain compatible with repositories not yet migrated to the next receipt schema until
the explicit adoption step runs.

---

## 18. Final invariant

IDC may report the governed repository reconciled only when:

```text
canonical intent
    = complete authoritative work graph
    = frozen tracker projection
    = live tracker state
    = Git/PR implementation relationships
    = current validation/review/finish evidence
    + every known drift represented by a routed obligation
```

Optional code intelligence strengthens the evidence around that equality. It never substitutes for
it.
