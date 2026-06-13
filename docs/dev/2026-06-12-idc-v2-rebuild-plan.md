# IDC v2 Rebuild — Execution Plan + /goal Contract

- **Spec (authoritative):** `docs/considerations/2026-06-12-idc-v2-overhaul-considerations.md` — read it in full before any work. Where this plan and the spec conflict, the spec wins. Where implementation reality and the spec conflict, halt and surface (blocked-stop), don't improvise design changes.
- **Authored by:** Fable 5 (grill-me interview + fullauto-goal contract authoring, 2026-06-12)
- **Executor:** Opus session running the contract at the bottom of this file as a native `/goal` payload (or via `/fullauto-goal` pointing at this file).
- **Repo state at authoring:** `main` @ `bd48f3c` (dogfood IDC installation removed; v1 plugin source intact and awaiting rewrite; phase-1 lifecycle issues parked on the GitHub board — do not touch them).

## Build order (encode as iteration phases; verify each phase before the next)

### Phase 0 — Clear the decks + canonical truth
- Create branch `idc-v2-rebuild` off `main`; all work on it; PR at the end.
- Delete v1 machinery outright: all `agents/*.md` (23 files), all v1 `skills/*/` directories, `commands/sequence.md`, stale `evals/*.evalset.json` that test deleted v1 behaviors (ClaimState, bookends, sequence admits, ripple verdict taxonomy, etc.). Git history is the archive — no legacy namespace, no commented-out remains.
- Rewrite `docs/prd/prd.md` and `docs/specs/master-architectural-spec.md` as the plugin's own v2 PRD and spec, derived from the consideration (PRD change was operator-approved during the interview). These are the north star for the rest of the build.
- Write the shared runtime-neutral core: v2 `templates/WORKFLOW.md` (short, guardrail-framed, written against the three primitives: durable worker / bounded fan-out / goal loop), v2 `templates/WORKFLOW-config.yaml` (domains section + tier-symbolic model routing table: reasoning=fable+max thinking, standard=opus+extra-high, utility=sonnet; codex untiered: highest model + highest effort), v2 `templates/tracker-config.yaml` (4-field board), updated `templates/docs-tree`.
- Write the two runtime adapter skills: `skills/idc-adapter-claude/` and `skills/idc-adapter-codex/` (primitives → mechanics maps; Codex side: named app-server threads / `spawn_agent` ≤6 / `codex exec --ephemeral` fan-out, per consideration §6).
- Phase verification: v1 vocabulary greps return nothing in machinery dirs; `scripts/lint-references.sh` passes (update the script itself if it hardcodes v1 paths — it must keep working as the repo's reference checker).

### Phase 1 — Tracker substrate + init/doctor
- Rewrite the tracker adapter skill pair: GitHub Projects backend (provision/use 4 fields: Status `Blocked|Todo|In Progress|Done`, Wave, Phase, Domain; native blocked-by; `attempt:<n>` label; claim = Status flip + claim comment) and filesystem backend (TRACKER.md equivalent, zero external setup — this is also the sandbox test substrate).
- Gate-issue helper skill: create the operator-todo gate issue (plain-terms PRD summary + diff link), chain affected issues Blocked behind it, push notification hook, unblock-on-approval flow.
- Rewrite `commands/init.md`: v2 scaffold (WORKFLOW.md, config with codebase-derived domains, 4-field board provisioning, install receipts for clean uninstall/upgrade — the folded lifecycle scope) and `commands/doctor.md` (read-only health check of the v2 surfaces).
- Phase verification: in a sandbox repo (via `scripts/materialize-sandbox.sh` or a fresh `git init` temp dir), init produces the v2 scaffold; doctor reports clean; filesystem-backend tracker ops round-trip (create/claim/block/close).

### Phase 2 — Think
- Rewrite `commands/think.md` + consideration-schema skill: free-form main-session brainstorm (grill-me style available, zero teammates, subagent research on demand) emitting a function-first consideration file; no PRD pre-clearing, no admission language.
- Phase verification: a sandbox think run produces a consideration that the schema check accepts.

### Phase 3 — Plan (the heart)
- Rewrite `commands/plan.md` + plan orchestrator playbook + skills: domain-expert dispatch (config-seeded planner-adjusted domains, read-only Workflow fan-out), doc-chain drafting (subagents write to disk, return digests; full five-layer chain, only PRD gated), goal-contract authoring (full 6-element contracts per pillar, complexity-adaptive, fullauto-goal shape, real-functional-test verification surfaces), pairwise clash/matrix analysis fan-out + synthesis, global re-sequencing against the live board (In Progress immutable), mechanical schema check, board admission, PRD-gate handling (always run to completion; PRD-dependent issues land Blocked behind the gate issue), planning PR with body-as-audit-trail, automerge.
- Phase verification: in the sandbox (filesystem backend), a plan run over a small test consideration emits the doc chain + ≥1 schema-valid contract issue + matrix artifacts, and a PRD-touching test consideration correctly produces a gate issue with dependent items Blocked while non-PRD items flow.

### Phase 4 — Build
- Rewrite `commands/build.md` + implementer agent + the merged review engine skill (all `code-review-custom` features + pi-idc-collab review agent: ~8 parallel specialist subagent reviewers across 13 dimensions, coordinator with fingerprint dedup, confidence ≥0.8, blocker/major/minor/nit, PASS/PASS-WITH-NITS/FAIL/FAIL-BLOCKED, evidence+attack+unblock per finding, test-genuineness as a dimension) + finisher/merge-queue logic in the orchestrator + wave close (full suite + board cleanup + promote; autowave default) + phase close (one delta review; findings filed as issues, non-blocking).
- Implementer = 1 teammate per parallel-safe issue in pre-created worktrees (teams env), serial in-session fallback otherwise; executes the issue contract as a /goal loop with auto-goal discipline incl. the no-punt rule; iterate on review findings → reverify → orchestrator automerges when all green.
- Phase verification: sandbox build run implements a trivial contract issue end-to-end — real failing test written first, goes green, review engine emits a structured verdict, merge + tracker close happen on PASS.

### Phase 5 — Ripple
- Rewrite `commands/ripple.md` + doc-sync skill: highest-affected-layer analysis; non-PRD → one PR syncing every affected doc down the chain, automerge, PR-body-as-change-order; PRD → the same gate-issue mechanism as plan. Verdict taxonomy and change-order files deleted.
- Phase verification: sandbox drift scenario produces one synchronized multi-doc PR; a PRD-touching drift produces a gate issue instead of an automerge.

### Phase 6 — Autorun
- Rewrite `commands/autorun.md` + orchestrator playbook: one-shot full-pipe drainer — unplanned considerations → parallel plan-run teammates (serialized board admission) → board hygiene fix in passing → build lane claiming waves as they land → exit report when nothing actionable remains. Skips empty stages; loopable.
- Phase verification: sandbox end-to-end — seed one consideration, run autorun, observe: issues admitted, trivial issue built green, board clean, clean exit report.

### Phase 7 — Docs, evals, release
- Rewrite `README.md`, `llms.txt`, `docs/architecture.md`, `docs/installing.md`; CHANGELOG entry; bump `.claude-plugin/plugin.json` to `2.0.0`.
- Reconcile `scripts/run-evals.sh` + `evals/` with the v2 surface: stale sets already deleted in Phase 0; add minimal v2 smoke evalsets only if the eval harness requires a non-empty set to pass. (A full v2 eval suite is explicitly out of scope — see contract ASSUMPTIONS.)
- Final verification: the complete VERIFICATION SURFACE below, then open the PR to `main`. Merge is the operator's call.

## The contract (native /goal payload — execute in the Opus session)

```
GOAL: The idc-workflow plugin implements IDC v2 exactly as specified by
docs/considerations/2026-06-12-idc-v2-overhaul-considerations.md — v1 machinery
(23 agents, ~38 v1 skills, sequence command, ClaimState/bookend ceremony, plan-review
suite, ripple verdict taxonomy, 5 codex-idc-* trees) deleted; v2 in place (7 commands:
init/doctor/think/plan/build/ripple/autorun; lean orchestrator playbooks + implementer
agent; ~10-14 skills incl. tracker adapters, goal-contract authoring, clash/matrix,
schema check, merged 13-dimension review engine, ripple doc-sync, gate-issue helper,
consideration schema, claude+codex runtime adapters; v2 templates with domain config and
tier-symbolic model routing; v2 PRD/spec for the plugin itself; docs + 2.0.0 manifest) —
all on branch idc-v2-rebuild with a PR open to main and the full verification surface
green.

VERIFICATION SURFACE:
  - rg -l "ClaimState|bookend-|idc-role-|codex-idc-|MINOR_AUTONOMOUS|MAJOR_GATED|Pillar trace key" commands/ agents/ skills/ templates/ README.md llms.txt → no matches (v1 vocabulary gone from machinery and docs)
  - ls commands/ → exactly: init, doctor, think, plan, build, ripple, autorun (no sequence); agents/ ≤ 8 files; skills/ ≤ 14 directories
  - bash scripts/lint-references.sh → exit 0 (script updated for v2 paths if needed; it must still genuinely check cross-references)
  - Run the plugin-dev:plugin-validator agent on the repo → no errors against .claude-plugin/plugin.json and component structure
  - Sandbox functional smoke (filesystem tracker backend, NO live GitHub mutations), evidence = actual artifacts + command output from a temp sandbox repo: (1) init scaffolds v2 + doctor clean; (2) plan over a seeded test consideration emits doc chain + ≥1 issue whose body passes the mechanical schema check (all 6 contract elements + ownership + dependencies + trace) + matrix artifacts; (3) a PRD-touching consideration yields a gate issue with dependents Blocked while non-PRD items flow; (4) build executes one trivial contract issue with a real failing test written first then green, review engine emits a structured verdict, merge+close on PASS; (5) ripple drift scenario yields one synchronized multi-doc PR, PRD drift yields a gate issue; (6) autorun drains the sandbox end-to-end and exits with a report
  - No existing test coverage exists for v2 behaviors (the v1 evalsets test deleted machinery) — the sandbox smoke scenarios above ARE the failing-tests-first: script/seed each scenario before implementing its phase, watch it fail, implement to green
  - git log on idc-v2-rebuild shows phased commits; gh pr view confirms an open PR to main whose body summarizes the build + verification evidence

CONSTRAINTS (must not regress):
  - The consideration file is the spec: every design decision (16 decisions + 6 assumptions in its §10-§11) is implemented as written; on discovered contradiction or infeasibility, blocked-stop and surface — do not silently redesign
  - v2 invariants hold everywhere: one-way flow; GitHub issues as the glass wall; exactly ONE gate (PRD user-facing function) using the tracker-native gate-issue mechanism; all other docs/PRs flow autonomously; full five-layer doc chain supported, only PRD gated; re-sequencing only through plan, In Progress issues immutable
  - Concurrency budget: think/plan/ripple = zero teammates (Workflow/Task fan-out only); build = 1 implementer teammate per parallel issue with serial in-session fallback; review = fresh-context subagent fan-out in every runtime
  - Model routing is tier-symbolic in WORKFLOW-config.yaml, resolved by runtime adapters (reasoning=fable/max-thinking: planning cognition, judgment review dims + coordinator, ripple analysis, deconfliction; standard=opus/extra-high: think, implementers, finisher, autorun parent; utility=sonnet execute-never-decide: research digestion, recon, templated emission, board mechanics, schema check, inventory review dims); Codex runtime untiered (highest model + effort); no hardcoded model IDs in process docs
  - Runtime-neutral core + thin adapters: process docs written against durable-worker/bounded-fan-out/goal-loop primitives; exactly one Claude adapter and one Codex adapter; no parallel per-runtime process trees
  - The parked GitHub board and its phase-1 lifecycle issues are not mutated; docs/considerations/**, docs/plans/** content is not deleted (planning seeds); LICENSE untouched; the plugin is NOT re-enabled in this repo's .claude/settings
  - No new external dependencies beyond what the plugin already uses (gh, git, shell); scripts stay zsh/bash-safe per repo conventions
  - Work only on branch idc-v2-rebuild; no direct commits to main; no --no-verify; PR opened but NOT merged (operator merges)
  - Any incidental issues needed to satisfy the outcome, verification surface, constraints, or boundaries are resolved in this same loop; no needed work is punted to future or other sessions

BOUNDARIES:
  - touch: commands/, agents/, skills/, templates/, scripts/, evals/, README.md, llms.txt, CHANGELOG.md, .claude-plugin/plugin.json (+marketplace.json if version-coupled), docs/prd/, docs/specs/, docs/architecture.md, docs/installing.md, docs/dev/2026-06-12-idc-v2-rebuild-plan.md (status notes only)
  - off-limits: docs/considerations/** (the spec — read-only), docs/plans/** and docs/dev/* history files (read-only seeds/records), .code-review/, .claude/ (repo stays un-enabled), LICENSE, the live GitHub Project board + its issues, ~/.claude/** and any user-level skills (the merged review engine is built INSIDE the plugin, not by editing code-review-custom)

ITERATION POLICY: record-and-vary — follow the 8-phase build order in
docs/dev/2026-06-12-idc-v2-rebuild-plan.md (Phase 0 deletion+truth → 1 tracker/init →
2 think → 3 plan → 4 build → 5 ripple → 6 autorun → 7 docs/release); write each phase's
sandbox smoke scenario first (red), implement to green, commit, then advance; each round
log {what changed, what the evidence showed, next experiment}; vary failed approaches
instead of repeating them.

BLOCKED-STOP: halt and surface {attempted paths, evidence, blocker, exact input needed}
on: a genuine contradiction or infeasibility in the consideration spec; gh auth/scope
missing for an operation the sandbox cannot substitute; a harness capability assumed by
the spec (Workflow tool, teams, push notifications) proving unavailable where required
with no documented fallback; or ~3 failures on the same hypothesis.

ASSUMPTIONS (inferred — veto before go):
  - Source/read status: full consideration file authored+read this session; repo recon done (plugin.json v0.1.0, scripts/{lint-references,run-evals,materialize-sandbox,install-codex}.sh, 15+ v1 evalsets, templates tree, branch=main @ bd48f3c)
  - Digest/gap compression: consideration §1-§11 → phased plan above; gaps filled: inventory ceilings (agents ≤8, skills ≤14) are targets from §8 set as hard caps; sandbox smoke = the failing-test-first surface since no v2 tests exist
  - Selective review gate: not triggered — the spec emerged from a 16-decision operator interview this session; contradictions would be self-inflicted and are covered by blocked-stop
  - Stale v1 evalsets are deleted with the machinery they test; a full v2 eval suite is deliberately OUT of scope (only minimal smoke evalsets if run-evals.sh needs a non-empty set) — veto if you want full evals now
  - Version bump to 2.0.0 (breaking); CHANGELOG entry written; marketplace.json touched only if it pins the version
  - Smoke tests use the filesystem tracker backend exclusively; GitHub-backend code is written + structurally validated but live board provisioning is verified later via /idc:init on a real repo (avoids creating throwaway GitHub Projects)
  - Push-notification hook implemented via the available notification surface (cmux notify / PushNotification tool) with a graceful no-op fallback when absent
  - The PR is opened but merging is the operator's decision (the v2 "automerge when green" doctrine applies to runs OF v2, not to this foundational rebuild)
  - Uninstall/upgrade (folded lifecycle scope) lands as init-written install receipts + an uninstall path documented in init/doctor; the parked phase-1 pillar docs are consulted as seeds but their issues are not built as-is
```

## Handoff notes for the executor (Opus)

- Load this file and the consideration file first; they are the complete brief.
- The contract above is a valid native `/goal` payload — run it as your goal loop.
- Commit in phase-sized increments on `idc-v2-rebuild`; keep commits traceable to phases.
- When the verification surface is green, open the PR and stop. The operator merges.
