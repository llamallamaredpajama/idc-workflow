---
name: idc-adapter-pi
description: 'Use when an IDC role running under the pi / coms-net flat-peer runtime must turn an abstract runtime primitive (durable worker / bounded fan-out / goal loop) into concrete pi mechanics — standing coms-net residents, ephemeral child-process fan-out, and the board-backed merge lease.'
---
# idc-adapter-pi

The pi / coms-net runtime adapter. IDC process docs are written against three abstract
primitives (`WORKFLOW.md §5`); this skill maps each to concrete mechanics on the flat-peer
**coms-net** hub (an HTTP/SSE peer network of standing IDC role residents launched by the
vendored `idc-pi` launcher under Bun + the Pi coding agent). There is exactly one adapter per
runtime — this is the only place pi mechanics live, so the process docs stay runtime-neutral
and cannot drift per-runtime. The playbooks are single-source: each stage resident runs its
**whole** playbook (`think.md / plan.md / build.md / recirculator.md` + implementer / review-agent /
finisher); the adapter decides only how their **sessions** are realized, never forking a
playbook per runtime.

## Primitive → mechanic map

| Primitive | pi / coms-net mechanic | Fallback |
|---|---|---|
| **Durable worker** (Build implementer/finisher, autorun lane) | A **standing coms-net resident**: a long-lived role peer the `idc-pi` launcher opens with `--name <role>` (`think`, `plan`, `sequence`, `recirculator`, `build-impl`, `build-review`, `build-finish`); Build is a **pool of triplets** (one resident per triplet role, the hub uniquifies a duplicate role with a trailing `-<n>`). Residents are flat peers — **no master orchestrator** at the cross-stage level; the board is the authoritative cross-stage handoff. | No pi runtime / no Bun → run the work **serially in the main session**, one unit at a time. |
| **Bounded fan-out** (domain experts, drafters, clash pairs, reviewers) | An **ephemeral coms-net helper / isolated child-process** spawned off a resident — short-lived, outside the standing pool, deterministic. Review fan-out is always **fresh cold child-processes per PR** (cold read = adversarial independence, token-optimal), never a standing resident. | Child-process fan-out is available wherever the runtime is; no fallback needed. |
| **Goal loop** (issue execution) | The native `/fullauto-goal` loop with auto-goal discipline: render-before-run, record-and-vary iteration, evidence-before-assertion, the attempt ceiling, and the no-punt rule. The issue body IS the contract. | — |

### Durable-worker rules (load-bearing)

- **The board is the cross-stage source of truth; coms-net carries only liveness/notification
  + within-stage coordination.** Stage→stage handoffs (consideration → plan → buildable issue)
  flow through the GitHub Projects v2 board, not peer messages.
- **Flatness is cross-stage, not intra-playbook.** A resident running `build.md` may coordinate
  its own triplet — that is *inside* the playbook, not a global master (`§2 decision 2`).
- **Glass-wall ACL (fail-closed) governs every `coms_net_send`.** A resident may message only
  peers **strictly downstream** of it in the river order — `think → plan → sequence →
  build-impl → build-review → build-finish` — plus the **Recirculator** peer (the universal
  downstream sink). Upstream, self, an unknown sender, or an unmappable target is **denied
  fail-closed**. The rule is enforced in the client extension **and authoritatively re-enforced
  at the coms-net hub** (`handleSendMessage`) before any message is queued, so a direct
  `/v1/messages` POST by a token holder cannot bypass it. Work that must travel "back"
  (re-review, fix iteration) rides the **board + the role's own goal loop**, never an upstream send.
- **Governance is gated at resident spawn (fail-closed).** A long-lived resident consults the
  compiled governance sidecar (`docs/workflow/idc-governance-contract.yaml`) instead of
  re-reading `WORKFLOW.md`; the `idc-pi` launcher runs `idc_governance_check.py` before exec'ing
  any resident and **blocks the launch** on drift or a missing sidecar (recompile with
  `idc_governance_compile.py`, then relaunch; bypass: `PI_IDC_GOVERNANCE_CHECK=off`). A resident
  re-runs the same checker mid-life to detect drift while it is alive.
- **Never two residents on one surface.** One unit per resident; the planning matrix already
  guarantees same-wave issues own **disjoint** file surfaces. Each durable worker runs in a
  **pre-created worktree** (never an isolation param).

### The Build triplet as residents — worked example

> **Launcher status (codex round-4 reconcile):** the coms-net hub *supports* a multi-resident pool
> — duplicate role names uniquify to a resolvable `build-impl-2` (hyphenated) and the role
> capability is keyed on the **role**, so every pool member shares one `build-impl` cap. But the
> vendored **reference** `idc-pi` launcher currently opens **one resident per role**
> (`--session-id idc-<role>` / `--name <role>`); spawning the N-resident pool below is the Pi
> adapter's (B2) wiring, not yet produced by `idc-pi run`. The model here is the design + is
> hub-supported; treat the pool fan-out as adapter-driven.

Build is the explicit three-role triplet realized as a standing **resident pool** (`§2
decision 7`, `agents/idc-build.md`). Worked example for one wave:

1. **1 build resident runs `build.md`.** It polls the board for `Stage=Buildable`,
   `Status=Todo` issues whose blocked-by upstreams are `Done`, and coordinates the wave
   (within-stage only — no cross-stage master).
2. **It dispatches N implementer residents** (`build-impl`, …`build-impl-<n>`), one per
   parallel-safe issue, each running the **whole** `idc:idc-implementer`: claim the issue, run
   its `/fullauto-goal` loop to a green implementation, hand off to review. (The engine never
   fixes findings or merges.)
3. **Review fan-out** is bounded fan-out, not a resident: each implementer's PR goes to
   **fresh cold child-processes** (the combined review agent, A1) → deduped, confidence-floored,
   fail-closed verdict.
4. **A finisher resident** (`build-finish`) runs the **whole** `idc:idc-finisher`: its **own**
   `/fullauto-goal` loop over **all** reviewer findings (incl. side issues) → `/simplify` → git
   finalization → recirculation on the unsolvable.
5. **Merge-serialization mechanism = a tracker-backed merge lease.** Two layers, both required:
   **(a) matrix-disjoint surfaces** make parallel diffs content-commutative (primary defense);
   **(b) a single-holder merge lease, fail-closed (no lease → no merge).** Because the pi pool
   is flat with **no master orchestrator**, the finisher resident proves exclusive ownership
   through the tracker adapter's lease primitive (`leaseAcquire(merge, owner, ttl) → token`)
   before it merges **only** the integration-ref update (never content), then releases
   (`leaseRelease(merge, token)`); coms-net carries only the liveness/notification. The lease is
   a real, atomic primitive — **on the filesystem backend** it is `lease-acquire`/`lease-release`
   (flock-backed acquire-if-empty-or-expired, opaque token, TTL expiry, release-by-token; see
   `idc:idc-tracker-filesystem`); **on the GitHub backend** there is no native compare-and-set
   lease yet, so the interim is **single-holder fail-closed** — exactly one orchestrator merges,
   a finisher never self-merges concurrently (a native Projects-field CAS lease is a tracked
   follow-up). This is the **pi row** of the one A2 merge contract (Claude Teams / collapsed: the
   sole Build orchestrator merges; Codex: the app-server serially merges finisher threads).

The forward triplet notifications — `build-impl → build-review → build-finish` — are all
downstream-legal under the glass-wall ACL; the Recirculator is reachable from any of them.

## Model selection

pi residents run the **Pi coding agent**. Process docs name only the **tier** (`WORKFLOW.md §6`).
The tier-symbolic contract is the target end-state, but on the **experimental Pi runtime it is not
yet wired**: the `idc-pi` launcher picks each role's model from `role_model()`
(`runtime/pi/scripts/idc-pi`) — a per-role **hardcoded stock default** (an Anthropic Opus tier for
think / plan / build-impl / build-finish, a DeepSeek tier for sequence / recirculator, an OpenAI tier
for build-review; see `role_model()` for the exact ids), each overridable per role via a
`PI_IDC_<ROLE>_MODEL` environment variable. It does **not** read
`WORKFLOW-config.yaml::model_routing`, so the governed repo's tier table is bypassed on Pi — unlike
`idc:idc-adapter-claude`, which is tier-resolved. Wiring `role_model()` to read `model_routing` is a
known experimental-runtime maturity gap; until then this launcher is the documented carve-out. The
general rule still holds everywhere else: never hardcode a model id in a command, agent, or
non-adapter skill; the Recirculator maintains the tier table when models change. `WORKFLOW-config.yaml`
also carries the `gating:` requirements-gate toggle (`gating.prd` / `gating.trd`), read by the gate
predicate (`scripts/idc_recirculator_layers.py`) for Plan and the Recirculator — not by tier resolution.

## Authority boundaries

- Maps primitives to coms-net mechanics (residents / child-process fan-out / `/fullauto-goal`)
  only — never authors contracts, makes judgment calls, or issues verdicts.
- Never forks a playbook per runtime (single-source), never mutates the tracker, the canonical
  docs, the vendored runtime internals, or `WORKFLOW-config.yaml` (the Recirculator owns the model table).
