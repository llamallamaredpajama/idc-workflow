# Plan — Unify pi-harnesses + pi-idc-collab into the single idc-workflow plugin

**Status:** design-approved (via grill-me session 2026-06-13), ready for parallel teammate execution
**Home repo:** `idc-workflow` (this repo) — the single plugin and single maintenance surface
**Execution:** two parallel tracks via Claude teammates, lead session coordinating; every work
unit is rendered below as a `/fullauto-goal` contract.

---

## 1. Context — why this exists

Today there are three repos doing overlapping work:

- **idc-workflow** (this plugin, v2.0.0) — the published Claude Code plugin. Pipeline
  `Think → Plan → Build`, with `Ripple` as the only retrograde path and `Autorun` as the
  full-pipe drainer. 4-field GitHub Projects v2 board. Already multi-runtime via thin
  adapters (`idc-adapter-claude`, `idc-adapter-codex`). "Guardrails not train tracks."
- **pi-harnesses** — a flat, real-time collaborative agent runtime: `coms-net` (an HTTP/SSE
  peer hub), per-role guardrails (`idc-role-harness.ts`, `guard-shell-core.ts`), a review
  orchestrator extension, and an `idc-pi` launcher that opens a cmux network of standing IDC
  role peers. Depends on the Pi coding agent (`@mariozechner/pi-*`) + Bun.
- **pi-idc-collab** — a half-built standalone `pi-idc` CLI that tried to package the pi
  runtime separately (8-field board, separate Sequence stage, build triplets, a deterministic
  governance compiler). Phase 0 scaffold only; now superseded by this plan.

**The goal:** one plugin (idc-workflow) that installs only what a user needs — Claude Code,
Codex, and/or the flat pi/coms-net runtime — as **add/subtract features**, not three separately
maintained tools. The pi flat-peer environment becomes a **third runtime adapter** under the
*same* v2 contract, not a parallel system.

### The governing metaphor (operator's mental model)

A one-directional **river → lake**: ideas form in the boundary waters (Think), flow downstream
through the canonical docs (only the **PRD** is gated), and pour over the **glass wall** — the
one-way current — into the **lake** (the GitHub Projects v2 board), where issues float and are
scooped by **builder agents**. Builders can *see* upstream (read the codebase) but can only
*implement*, never change the plans. **Ripple** is the only salmon that swims back upstream.
v2's `autorun` (one process walking the whole pipe) and pi's standing residents (a resident
stationed at each bend) are two ways to make the *same* river flow continuously.

---

## 2. The unified architecture (decisions, locked)

1. **One plugin; pi is a third runtime adapter** under v2's existing contract. The work
   decomposition is already shared — v2's `build.md` literally "mimics the
   implementer→reviewer→finisher triplet," and `plan.md` is already multi-agent (domain
   experts, parallel doc-drafters, clash analyzers). Only the *process topology* differs.

2. **Single-source playbooks.** `think.md / plan.md / build.md / ripple.md` (+ implementer /
   finisher / review-agent) stay one source of truth. Each stage is a standing **resident** in
   pi that runs its whole playbook. "Flatness" lives at the **cross-stage** level (the river
   flows peer→peer with no master orchestrator), not inside playbooks.

3. **Glass wall enforced at the wire.** In pi, a resident may `coms_net_send` only to
   **downstream** peers and the **Ripple** peer — never arbitrary upstream. Enforced by
   extending pi's existing per-role ACL machinery (`idc-role-harness.ts`) to the coms-net send
   seam. The board remains authoritative for all cross-stage handoffs; coms-net carries
   liveness/notification + within-stage coordination only.

4. **The board = the lake = the work-discovery index.** Files stay the source of truth.
   **Lightweight labeled pointers** make the whole pipeline (considerations, in-flight plans,
   pillars, buildable issues) queryable on one board — replacing any semantic-memory/RAG layer
   with a plain labeled queue. The board tells any resident "here's the next to-do."

5. **It is GitHub *Projects v2 boards*, not bare issues.** Custom single-select fields drive
   board columns. Schema grows **4 → 5 fields**: add **`Stage`** (`Consideration | Planning |
   Buildable`) as the column-grouping field. Planning-side pointers and buildable issues live
   in visibly separate columns of the same Project; build residents filter `Stage=Buildable`.
   The old pi 8-field schema is dropped.

6. **Review: skill → a combined agent.** Promote `idc-review-engine` to a first-class review
   **agent** that is a *standing service* (queryable) but always spawns **fresh, cold reviewers
   per PR** (adversarial independence). Combines pi's **risk-tiering** (trivial/lite/full) +
   **sanitized packets** + **isolation**, with idc's **13 dimensions** + **fingerprint dedup**
   + **0.8 confidence floor** + **verdict ladder** + **automerge hook** + **test-genuineness =
   FAIL**. Reviewer fan-out isolation is **adapter-decided** (Claude subagents / Codex ephemeral
   / pi isolated child-processes); the packet + verdict report is identical everywhere.

7. **Build is the real triplet** — three single-source playbooks acting as one logical worker:
   - **Implementer** — the engine: selects/claims an eligible issue, runs the small loop
     (`/fullauto-goal`) to implement, hands off to review.
   - **Reviewer** — the independent combined review agent (decision 6); finds *all* issues
     including side issues.
   - **Finisher** — runs its **own** `/fullauto-goal` loop to fix *every* reviewer finding
     (incl. side issues), then `/simplify` (Claude; adapter maps/【skips for Codex) and all git
     finalization (merge, tidy). Kicks the unsolvable upstream via **Ripple**.

   The adapter sets session count: **pi** = standing residents (a pool of triplets); **Claude
   Teams** = teammates; **Codex** = app-server **threads**. Collapsing to one sequential session
   is the **last-resort fallback only** (e.g., Claude with no team env), never the Codex default.

8. **Nested loops are the spine** (most already exist):

   | Loop | What it is | Status |
   |---|---|---|
   | Small | implementer's `/fullauto-goal` per issue | exists |
   | Small (fix) | finisher's `/fullauto-goal` over reviewer findings | new (decision 7) |
   | Triplet | impl → review → finish, iterate until clean | exists (expand to 3 roles) |
   | Ripple | build hits an upstream problem → re-plan → back down | exists |
   | Full drain | run the whole pipe once | exists (`/idc:autorun`) |
   | Biggest | the drain on a schedule | exists (`/loop`, `/schedule`) |
   | Intake | external feeds (feedback/bugs/monitoring) → considerations | future |

9. **Packaging (industry-normal pattern).** The plugin **vendors the pi source** (~6.1k lines
   TS: coms-net client/server, guard-shell-core, role-harness, review-orchestrator, launcher)
   into this one repo. `/idc:install-pi` (mirroring the existing `install-codex.sh`) wires it
   up; **Bun + the Pi agent are install-time deps**; `/idc:doctor` version-checks them. The
   standalone `pi-idc` CLI **dissolves** into plugin scripts/commands. Footprint stays small —
   idc-workflow grows by <1MB, still a fraction of Anthropic's 50MB official bundle.

10. **Governance compiler = a pi-mode capability.** Long-lived pi residents consume a compiled,
    hash-pinned sidecar of `WORKFLOW.md` + configs and get a **reload-on-drift** signal
    (fail-closed if stale). Episodic Claude/Codex runs keep reading `WORKFLOW.md` directly
    (they can't go stale within a run). Adapter-decided, like everything else.

### Repo strategy

- **idc-workflow** — the single home; all new work lands here.
- **pi-harnesses** — upstream runtime source + proving ground; vendor from it (with
  attribution); keep until the vendored copy is proven.
- **pi-idc-collab** — superseded. Harvest its assets (governance-compiler design, architecture
  spec, `.code-review/` packets) into this plan, then **archive** it. Do **not** finish its
  blocked Phase 0 commits.

---

## 3. Execution model — two parallel teammate tracks

The lead session (user-facing) coordinates; it first spawns a **bootstrap teammate** to absorb
the three repos and own the team plan, then dispatches the tracks. Each work unit below is a
`/fullauto-goal` contract a teammate runs to verifiable completion. Tracks A and B run
concurrently; the marked sync points are the only cross-track dependencies.

- **Track A — Canonical v2 upgrades** (no pi runtime; benefits Claude+Codex immediately):
  A1 review agent · A2 triplet · A3 tracker pointers + `Stage` field.
- **Track B — pi runtime + adapter** (the new capability): B1 vendor runtime · B2 `idc-adapter-pi`
  · B3 glass-wall ACL · B4 governance compiler.
- **Convergence:** C1 end-to-end pi proof · C2 harvest + archive pi-idc-collab · C3 ship update.

**Parallel-safety:** A-units own disjoint files (review / build+finisher / tracker+autorun).
B-units run after B1 vendors the source (B3 edits vendored files). **Sync point:** A2 (triplet
playbooks) and B2 (adapter that maps the triplet onto residents) must agree on the triplet's
role contract — lead reconciles before B2 merges.

---

## 4. Track A — `/fullauto-goal` contracts

### A1 — Promote the review engine to a combined review agent

```
GOAL: A first-class review AGENT exists in idc-workflow that runs as a standing service yet
spawns fresh, cold reviewers per PR, combining pi's risk-tiering + sanitized packets + isolation
with idc's 13 dimensions + fingerprint dedup + 0.8 confidence floor + verdict ladder +
automerge hook + test-genuineness-as-FAIL. Build invokes it; an operator can invoke it directly.

VERIFICATION SURFACE:
- New/updated agent file (agents/idc-review-agent.md) + skills/idc-review-engine updated, passing
  the repo's existing review-verdict validator: `python3 scripts/idc_review_verdict_check.py <out>`.
- A fixture review run over a known-bad diff yields the correct verdict ladder
  (blocker→FAIL-BLOCKED, major→FAIL, minor/nit→PASS-WITH-NITS, clean→PASS) and a shallow/
  placeholder test in the fixture is flagged FAIL (not nit). Add this as a test under tests/.
- Risk-tiering selects the documented reviewer set per tier (trivial/lite/full) — assert in test.
- `bun test` / existing smoke suite green; the new fixture test passes.

CONSTRAINTS: No regression to existing build automerge wiring or the verdict JSON schema.
Reviewer fan-out must route through the runtime adapter's bounded-fan-out primitive (do not
hard-code Claude subagents). Packet-on-disk + durable report under docs/workflow/code-reviews/
stays identical across runtimes. No-punt rule: incidental wiring fixes land in this loop.

BOUNDARIES:
  touch: agents/idc-review-agent.md (new), agents/idc-review-coordinator.md,
         skills/idc-review-engine/**, scripts/idc_review_verdict_check.py (if needed), tests/**
  off-limits: agents/idc-build.md & agents/idc-implementer.md & agents/idc-finisher.md (A2),
              any tracker skill / Stage-field work (A3), the pi adapter/runtime (Track B)

ITERATION POLICY: record-and-vary — log each fixture verdict vs expected; vary the dimension
prompts/tiering rules on mismatch.

BLOCKED-STOP: halt after ~3 attempts if the verdict ladder can't be made deterministic on the
fixture; surface the failing dimension. Halt if promoting skill→agent would break build automerge
— flag for lead before changing the build interface.

ASSUMPTIONS: the existing 13-dimension engine content is the baseline to wrap, not rewrite;
"isolation adapter-decided" means the agent calls the adapter, which chooses subagent vs process.

Dependencies: none (Track A entry point).
Trace: this plan §2 decision 6 · pi-idc-collab .code-review/ packets · pi review-orchestrator.
```

### A2 — Make the impl→review→finish triplet canonical (single-source, three roles)

```
GOAL: Build is explicitly the three-role triplet. agents/idc-implementer.md = engine (select +
/fullauto-goal). The review agent (A1) = independent reviewer. A NEW agents/idc-finisher.md runs
its own /fullauto-goal loop over ALL reviewer findings (incl. side issues), then /simplify + git
finalization, and files a Ripple on the unsolvable. agents/idc-build.md orchestrates the lane/pool
and documents adapter-decided session realization (pi residents / Teams teammates / Codex threads;
collapse only as last-resort fallback).

VERIFICATION SURFACE:
- agents/idc-finisher.md exists with the 6-element posture and the /simplify + git-finalization
  steps named; agents/idc-build.md references all three roles + the fallback-collapse rule.
- A markdown/structure test (or scripts check) asserts the three role files exist and that
  build.md names implementer, reviewer-agent, finisher and the per-runtime session mapping.
- `bun test` / smoke suite green.

CONSTRAINTS: build.md stays single-source (no per-runtime forks of the playbook). The finisher,
not the implementer, owns fix-application + merge. Merge across parallel finishers must be
serialized (document the mechanism: matrix-disjoint surfaces + a merge lock/queue) — no silent
race. Don't change the review agent internals (A1 owns those).

BOUNDARIES:
  touch: agents/idc-build.md, agents/idc-implementer.md, agents/idc-finisher.md (new),
         commands/build.md, tests/**
  off-limits: skills/idc-review-engine & agents/idc-review-agent.md (A1), tracker/Stage (A3),
              Track B

ITERATION POLICY: record-and-vary — log each structural assertion outcome.

BLOCKED-STOP: halt if the merge-serialization design is ambiguous for the pi pool case — surface
to lead (this is the A2↔B2 sync point). ~3-attempt ceiling on the structure test.

ASSUMPTIONS: v2's "collapsed triplet" becomes the explicit three-role model; collapse is a
fallback the adapter performs, not the default.

Dependencies: coordinate with A1 (reviewer role) and B2 (adapter session mapping) — lead syncs.
Trace: this plan §2 decisions 7-8 · pi-harnesses build-impl/review/finish · v2 build.md line 8.
```

### A3 — Tracker pointers + the `Stage` field (Projects v2, 4→5 fields)

```
GOAL: The GitHub Projects v2 board gains a 5th single-select field `Stage`
(Consideration | Planning | Buildable). Upstream artifacts (considerations, in-flight plans,
pillars) get lightweight pointer items that reference their repo file and carry Stage + Phase +
Domain; buildable issues carry Stage=Buildable. Autorun and build residents query the board by
Stage instead of scanning the filesystem. Files remain the source of truth.

VERIFICATION SURFACE:
- templates/tracker-config.yaml documents the 5th field; the github tracker skill
  (skills/idc-tracker-github) reads/writes Stage; skills/idc-tracker-adapter routes it.
- scripts/idc_schema_check.py (or a new check) validates a pointer item shape (must reference a
  repo file path + Stage/Phase/Domain) distinct from a full buildable goal-contract.
- A fixture: creating a consideration pointer then querying Stage=Buildable excludes it; a
  buildable issue is included. Add as a test.
- /idc:init provisioning docs/scripts updated to create the 5-field board; doctor checks for it.
- `bun test` / smoke suite green.

CONSTRAINTS: stay at exactly 5 fields (no field creep beyond Stage). Pointers must NOT duplicate
canonical file content (pointer = reference + labels only). Don't break existing 4-field repos —
provide a migration note (additive field). Glass wall intact: a pointer being upstream-staged
means build never scoops it.

BOUNDARIES:
  touch: skills/idc-tracker-github/**, skills/idc-tracker-adapter/**, templates/tracker-config.yaml,
         skills/idc-schema-check/** & scripts/idc_schema_check.py, agents/idc-autorun.md,
         commands/init.md & commands/doctor.md (provisioning/check only), tests/**
  off-limits: agents/idc-build.md (A2), review (A1), Track B

ITERATION POLICY: record-and-vary — log each query-filter fixture result.

BLOCKED-STOP: halt if exact Stage values need a product call beyond
Consideration|Planning|Buildable — surface to lead. ~3-attempt ceiling on the query fixture.

ASSUMPTIONS: pointers are written by the stage that produces the artifact (Think writes a
consideration pointer, Plan writes plan/pillar pointers) — a small, additive tracker-write
authority for those roles, documented in WORKFLOW.md template.

Dependencies: none (Track A, parallel to A1/A2).
Trace: this plan §2 decisions 4-5 · operator "one-stop to-do index" intent.
```

---

## 5. Track B — `/fullauto-goal` contracts

### B1 — Vendor the pi runtime + install/doctor wiring

```
GOAL: The idc-workflow plugin repo contains the pi runtime source (coms-net client + server,
guard-shell-core, idc-role-harness, review-orchestrator, the idc-pi launcher) with attribution,
plus scripts/install-pi.sh (mirroring install-codex.sh) that wires it up, and a /idc:doctor
check that verifies Bun + the Pi agent (@mariozechner/pi-*) are present and version-compatible.

VERIFICATION SURFACE:
- Vendored files present under a clear dir (e.g. runtime/pi/) with a top-of-file attribution
  header citing pi-harnesses + preserved license; ATTRIBUTIONS.md updated.
- `bash scripts/install-pi.sh --check` (dry run) reports what it would install and detects
  Bun/Pi presence without mutating; `--revert` documented.
- /idc:doctor gains a pi section: reports present/absent/version for Bun + Pi, fail-closed on
  incompatibility. Add a doctor test/fixture.
- The vendored coms-net server starts and answers a health request in a smoke test (bun).

CONSTRAINTS: vendor source only — do NOT bundle the Pi agent binary (install-time dep). Keep the
vendored copy buildable/runnable under Bun. No changes to Track A files. Preserve license notices.

BOUNDARIES:
  touch: runtime/pi/** (new), scripts/install-pi.sh (new), scripts/idc-pi (vendored),
         commands/doctor.md (pi section), ATTRIBUTIONS.md, tests/**
  off-limits: skills/idc-adapter-pi (B2), all Track A files

ITERATION POLICY: record-and-vary — log each install --check / health-probe result.

BLOCKED-STOP: halt if a vendored extension needs Pi-internal APIs not available standalone —
list them for lead. ~3-attempt ceiling on the coms-net health smoke test.

ASSUMPTIONS: the pi-harnesses working tree is the source of truth to copy from; only IDC-relevant
extensions are vendored (not all 27).

Dependencies: none (Track B entry point). B3 depends on this.
Trace: this plan §2 decision 9 · CLAUDE.md attribution rule · install-codex.sh precedent.
```

### B2 — Write `idc-adapter-pi`

```
GOAL: A new skill skills/idc-adapter-pi maps the three abstract primitives onto the coms-net
flat-peer runtime, in the same shape as idc-adapter-claude/codex: durable worker → standing
coms-net resident (a pool of build triplets); bounded fan-out → ephemeral coms-net helper /
isolated child-process; goal loop → /fullauto-goal. It documents how each stage resident runs
its whole single-source playbook and how the triplet (A2) is realized as residents.

VERIFICATION SURFACE:
- skills/idc-adapter-pi/SKILL.md exists and parallels the other two adapters' primitive table
  (a structure test asserts the three primitives are each mapped).
- A documented worked example: Build stage → 1 build resident running build.md spawning N impl
  residents (idc-implementer.md) + review fan-out + finisher, with the merge-serialization
  mechanism from A2 named.
- `bun test` / smoke suite green.

CONSTRAINTS: must not fork the playbooks (single-source). Must honor the glass-wall ACL (B3) and
the standing-pool build model. Mirror the existing adapters' interface exactly so callers stay
runtime-blind.

BOUNDARIES:
  touch: skills/idc-adapter-pi/** (new), tests/**
  off-limits: the other adapters' files, Track A files, vendored runtime internals (B1/B3)

ITERATION POLICY: record-and-vary — log primitive-mapping structure assertions.

BLOCKED-STOP: halt until A2's triplet role contract and B3's ACL are merged (sync point) — the
adapter must describe the agreed shape. ~3-attempt ceiling on the structure test.

ASSUMPTIONS: residents are launched by the vendored idc-pi launcher; the adapter describes
mapping/contract, not new runtime code.

Dependencies: A2 (triplet shape), B1 (runtime present), B3 (ACL) — lead syncs before merge.
Trace: this plan §2 decisions 2,7,9 · idc-adapter-claude/codex precedent.
```

### B3 — Glass-wall coms-net directional ACL

```
GOAL: The vendored coms-net send path enforces the glass wall by direction: a role resident may
message only downstream peers and the Ripple peer; never arbitrary upstream. Built by extending
the existing per-role ACL machinery (idc-role-harness) to the coms_net_send seam, fail-closed.

VERIFICATION SURFACE:
- A policy table maps each role → allowed message targets (downstream set + ripple).
- Tests: a build resident sending upstream to plan is REJECTED; sending to ripple or downstream
  is ALLOWED; think→plan downstream ALLOWED. Cover each role's matrix.
- The vendored coms-net send path consults the policy before delivering (a denied send returns a
  structured error, logged).

CONSTRAINTS: enforcement is fail-closed (unknown target → deny). Do not weaken existing
path/bash/secret guardrails in role-harness. Reuse the existing ACL structures (don't add a
parallel system).

BOUNDARIES:
  touch: runtime/pi/idc-role-harness.* , runtime/pi/coms-net* (the vendored copies), tests/**
  off-limits: skills/idc-adapter-pi (B2), Track A files

ITERATION POLICY: record-and-vary — log each role-pair allow/deny test result.

BLOCKED-STOP: halt if the role→downstream topology is ambiguous (who is "downstream" of whom) —
surface the role graph to lead. ~3-attempt ceiling on the ACL matrix test.

ASSUMPTIONS: the river order is Think→Plan→Build with Ripple reachable from any builder; the
downstream set derives from that order.

Dependencies: B1 (vendored files exist).
Trace: this plan §2 decision 3 · pi guard-shell-core/idc-role-harness ACL model.
```

### B4 — Governance compiler (pi-mode)

```
GOAL: A scripts/idc_governance_compile.py (+ a check) produces a compact, hash-pinned sidecar of
WORKFLOW.md + WORKFLOW-config.yaml + tracker-config.yaml that long-lived pi residents consume
instead of re-reading prose, with a reload-on-drift signal (fail-closed if source hashes don't
match the sidecar). Episodic Claude/Codex runs are unaffected (they read WORKFLOW.md directly).

VERIFICATION SURFACE:
- `python3 scripts/idc_governance_compile.py --repo <r>` emits a deterministic YAML sidecar with
  sha256 source_hashes; byte-stable across runs on unchanged inputs (test asserts determinism).
- `python3 scripts/idc_governance_check.py --repo <r>` returns 0 on match, non-zero on a mutated
  WORKFLOW.md (drift) — test both.
- Docs: the pi adapter/launcher consume the sidecar + reload on drift; doctor reports staleness.
- `bun test` / smoke suite green.

CONSTRAINTS: deterministic, dependency-light (stable YAML + raw-byte hashes). Never auto-compile
inside a run (fail-closed + signal instead). Pi-mode only — do not gate Claude/Codex on it.

BOUNDARIES:
  touch: scripts/idc_governance_compile.py (new), scripts/idc_governance_check.py (new),
         skills/idc-governance-* (new, optional), commands/doctor.md (staleness check), tests/**
  off-limits: Track A files, B2/B3 files

ITERATION POLICY: record-and-vary — log determinism + drift-detection test outcomes.

BLOCKED-STOP: halt if the sidecar schema needs fields beyond hashes + tracker/glass-wall summary
— surface to lead. ~3-attempt ceiling on the determinism test.

ASSUMPTIONS: pi-idc-collab's compiled-contract sketch is the design baseline to adapt (harvested,
not copied wholesale).

Dependencies: none for authoring; consumed by B2/launcher at convergence.
Trace: this plan §2 decision 10 · pi-idc-collab governance-compile design + spec §4.
```

---

## 6. Convergence & cutover

- **C1 — End-to-end pi proof.** On a real IDC repo, install pi mode (`/idc:install-pi`), launch
  the resident network, and drive one consideration → plan → buildable issue → triplet build →
  merge, with the glass-wall ACL and governance sidecar active. Capture evidence.
- **C2 — Harvest + archive pi-idc-collab.** Confirm the governance-compiler design, architecture
  spec insights, and `.code-review/` packets are reflected here; then archive pi-idc-collab
  (stop new work; do not finish its blocked Phase 0 commits).
- **C3 — Ship.** Release the plugin update with pi as an opt-in feature; `/idc:update` + doctor
  guidance for existing repos (the additive `Stage` field is backward-safe).

## 7. Open implementation items (resolve during execution, not blocking)

- Exact `Stage` field values + whether considerations get a pointer at creation or at Plan pickup.
- Merge-serialization mechanism across parallel finishers (lock vs queue) — A2/B2 sync.
- coms-net reload-on-drift trigger (poll vs push) for the governance sidecar.
- cmux pane topology for the resident network (how many panes, layout).
- Precise list of pi extensions to vendor vs leave behind.
- Codex mapping of `/simplify` (equivalent pass vs skip).

## 8. How to run this plan

1. Lead spawns a **bootstrap teammate** to absorb the three repos + this plan and own the team plan.
2. Lead pre-creates worktrees per work unit (native `claude --worktree` / `EnterWorktree`; not the
   Agent `isolation` param) and dispatches **Track A** (A1, A2, A3 — disjoint files, parallel)
   and **Track B** (B1 first, then B2/B3/B4) teammates, each running its contract via `/fullauto-goal`.
3. Lead holds the **A2↔B2 sync** (triplet shape) and the single **merge queue** (no teammate
   merges another's surface). Each unit: PR → combined review agent → finisher fixes → merge.
4. Converge on C1–C3.
```
