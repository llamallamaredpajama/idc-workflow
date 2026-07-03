# Handoff — IDC v4 Phase 2 ("the single door + terminal interlocks") — 2026-07-03

**Status:** ACTIVE / paused mid-execution · **Branch:** `main` @ `6613508` · **Run:** `/auto-goal-teams`
(sequential team relay) · **Paused because:** the shared Claude account hit its **weekly usage limit**
(teammates `engine` and `reviewer1` both died on it; **resets Jul 9 ~7am America/Chicago**). A fresh
session (or one after the reset) continues from here.

> Ephemeral run artifacts (a scratchpad LEDGER + per-stage briefs) do **not** survive the session —
> everything needed to resume is captured below. The authoritative design is
> [`2026-07-03-deterministic-core-refactor-plan.md`](2026-07-03-deterministic-core-refactor-plan.md)
> **§5 Phase 2** (the exact contract) + §3.1/§3.2/§3.3 + §6 (operator decisions).

---

## Pick up here (next actions, in order)

1. **Independently review PR #135 (Stage 2) — this review was CUT OFF when `reviewer1` died mid-review.**
   PR #135 (`feat(finish): --require-routed-findings + honor merge_conditions`, branch
   `worktree-p2-finish` @ `c18edba`) is **built, self-verified green, lead scope-checked clean — but NOT
   independently reviewed. Do not merge it until it is.** Review focus (verbatim from the dispatched-but-
   unfinished review): (a) headline negative test `tests/smoke/governance/finish-receipt-gate.sh`
   "unrouted findings ⇒ finish REFUSES" genuinely **red-when-broken** (neuter the routed sub-check → RED);
   (b) **no bypass** — no finish path may merge/close while a routable finding is unrouted OR a
   merge_condition unmet OR the verdict is non-owning/FAIL (gate runs before ANY mutation); (c) **reuse
   not duplication** — it must call `FF.work_items` + `FF._fs_existing_keys`/`_github_existing_keys` +
   `TE.load_verdict` + `TE.unmet_merge_conditions` + `VC.PASSING`; (d) **enforcement real** — `--verdict`
   is REQUIRED so no call site silently skips; confirm `agents/idc-finisher.md` passes `--verdict` and the
   3 smoke-fixture changes (phase4-git-finish, phase9-multiwave, phase9-realgit) don't mask the gate;
   (e) sanity-check the **deliberate `IDC_HOOKS_OBSERVE_ONLY`-NOT-honored** decision (correct for a hard
   finish-tail receipt; the debug escape is `--no-require-routed-findings`); (f) github fail-closed on
   unreadable board. Then **merge (squash) → integration-verify on merged main → clean up the worktree.**
2. **Stage 3** — PreToolUse interlocks (`gh pr merge` / `gh issue close` / state-closing `gh api` / raw
   board mutations `gh project item-edit/item-add`) in `scripts/hooks/*` + `hooks/hooks.json`, **shipping
   warn-inject** (deny path built behind the `IDC_HOOKS_OBSERVE_ONLY` mode switch and e2e-exercised) +
   the **NEW lint rule** in `scripts/lint-references.sh` banning raw board-mutation snippets in shipped
   prose (proven red-when-broken on a seeded violation). Every deny/warn message names the exact
   `idc_transition.py`/`idc_git_finish.py` remediation.
3. **Stage 4** — scaffold `templates/workflow-machine.yaml` into governed repos via
   `scripts/idc_init_scaffold.sh` + `scripts/idc_template_for.py` + `commands/init.md` +
   `commands/update.md`; `/idc:update`'s drift contract must recognize it.
4. **Stage 5** — top-level acceptance: full `run-all.sh` in the real checkout + **install-sandbox e2e**
   (lifecycle through the engine; a hand `gh pr merge` w/o receipts → corrective warn-inject naming the
   exact command, deny path exercised via the mode switch; a raw `gh project item-edit` → denied w/
   remediation) + **update-sandbox e2e** (`/idc:update` scaffolds workflow-machine.yaml). See CLAUDE.md
   "Local end-to-end testing" for the sandbox-rooted `claude -p` recipe.
5. **Task #7 (chronic CI)** — decide/fix (see "Known issues" below); a red CI can't catch regressions in
   the remaining stages.

---

## What just landed (this session)

Base was `main` @ `6530c8b` (Phase 0 + Phase 1 already merged — the old "Phase 1 uncommitted" memory was
STALE; Phase 1 = the verdict pipeline, was on main). Phase 2 execution shape chosen: **sequential team
relay** (the work is a tightly-coupled engine + narrow tail; wide parallelism buys little and risks
thrash). Each stage: build → dual review (standard + **adversarial/mutation-based**) → fix → `/simplify`
→ merge → integration verify.

- **Stage 1 — the transition engine — MERGED** (`d59b98f`, PR #133). New `scripts/idc_transition.py`
  (single sanctioned write door; 9 typed ops; data-driven legal-transition table
  `templates/workflow-machine.yaml`; atomic + read-back + normalized so **Stage is never set without
  Status**), backward-compatible `merge_conditions[]` in `scripts/idc_review_verdict_check.py` honored by
  the close guard, and `scripts/idc_file_findings.py` **re-pointed through the engine**. Review found &
  fixed **2 fail-open BLOCKERs** (create could mint `Status=Done`; close accepted a verdict not bound to
  the item → one PASS could close the whole board) + a **PyYAML/stdlib parser-parity** bug. Root-cause
  fix: one `validate_target()` choke point — **the ONLY path to a terminal Status is a guarded `close`
  with a valid + PASSING + item-owning + `--pr`-bound verdict.**
- **Stage 1b — github move/close/link ops — MERGED** (`6613508`, PR #134). The engine is now the single
  door on the **github** backend too (was fail-closed); github ops route through the SAME guard code as
  fs (only read/write primitives differ); item ids resolve via the shared item-id cache (GraphQL budget);
  github board errors map to clean **exit 3** (drain 0/2/3 contract intact). Review nit fixed: the
  close-ownership tests now use a **no-`pr`-field** verdict so the mandatory-`--pr` guard is genuinely
  red-when-broken (was masked).
- **Stage 2 — the finish receipt gate — BUILT, PR #135 OPEN, NOT MERGED (review unfinished).** Adds a
  default-ON `enforce_receipt_gate` to `scripts/idc_git_finish.py` (validate + PASSING + owns-item +
  routed + merge_conditions-met, before any mutation). "Routed" = each routable finding's dedupe key ∈
  the board's filed `idc-recirc-source` keys. Self-verified: lint 0, governance 24/24 both parser paths,
  full run-all ALL GREEN, headline scenario red-when-broken. **Needs independent review then merge.**

---

## Verification (how to check state on resume — CRITICAL, non-obvious)

- **The verification GATE is LOCAL, not CI.** Run in the **real checkout** (`/Users/jeremy/dev/proj/idc-workflow`,
  which has the gitignored Pi runtime — a bare `git worktree` FALSE-fails `phase8-pi*`):
  - `bash scripts/lint-references.sh` → exit 0
  - `bash tests/smoke/run-all.sh` → "idc smoke: ALL GREEN"
  - **BOTH parser paths for the governance lane** — system `python3` has NO PyYAML → the machine-table
    parity check AUTO-SKIPS (a *false* all-clear that hides parser divergence). The user's homebrew
    `python3` HAS PyYAML 6.0.3. So ALSO run:
    `uv run --with pyyaml bash tests/smoke/phase-governance.sh` → ALL GREEN.
- **Governance scenarios are glob-discovered** under `tests/smoke/governance/*.sh` — add new ones as files
  (no `run-all.sh` edit needed). Mirror `lib.sh` + existing `engine-*.sh`.
- **HARD user requirement (non-negotiable): every governance scenario must be red-when-broken** — mutation-
  verify it (neuter the enforcing line → scenario FAILs → restore). "Tests aren't trusted until
  red-when-broken." This session's reviews caught two BLOCKERs, a parity bug, and a masked test precisely
  by mutation testing — keep doing it.
- **main HEAD:** `6613508` ("...github move/close/link...(#134)"). **Last PR merged:** #134. **Open PR:**
  #135 (Stage 2, MERGEABLE / UNSTABLE — UNSTABLE = the pre-existing phase9 CI red, see below).
- **Worktrees:** main checkout @ `6613508`; `.claude/worktrees/p2-finish` (branch `worktree-p2-finish`
  @ `c18edba`, the Stage-2 PR #135 branch — keep until #135 merges, then remove). NOTE: an orphaned
  detached-HEAD scratch worktree (`wt-s2` @ `c18edba`, in teammate builder2's ephemeral session
  scratchpad) may linger — `git worktree prune` after builder2's session ends.
- **Teammates:** all should be gone on resume (session-scoped). `engine` + `reviewer1` died on the weekly
  limit; `builder2` was stood down. **codex-review** never delivered (idled empty; no artifacts) — a real
  Codex adversarial pass on the engine was NOT completed (optional to redo).
- **Memory written this session:** none yet (update `project-deterministic-core-refactor-v4.md` +
  MEMORY.md on resume to record Phase-2 progress).
- **Architectural fitness / CI:** NOT green — chronic pre-existing CI red (below); local suite IS green.

---

## Known issues / deferrals carried forward

- **CHRONIC CI RED (task #7, pre-existing, NOT this work).** `ci.yml`'s job has been FAILURE on EVERY
  recent `main` commit on `phase9-realgit-lifecycle` + `phase9-multiwave-accumulation`. Both **pass
  locally** (baseline main AND every branch) — they fail ONLY in GitHub Actions: the rebuilt real-git
  smoke phase (commits `4854d4f`/`acb0ba0`) isn't hermetic from the Actions git environment (janitor
  classifies `origin/main` as a "non-IDC foreign" remote → lifecycle exits 1; the fake-`gh` shim's
  `git push origin HEAD:main` fails). The engine PRs added ZERO new CI failures. **A red CI can't catch
  real regressions in Stages 3–5** → fix it (make the real-git tests hermetic from the Actions
  checkout's remote/git-config) OR knowingly rely on the local gate. **Merges this session used
  reviewer PASS + the local gate, since CI red is pre-existing & unrelated (verified by diff + baseline).**
- **retire is fail-closed** (raises) — the board has one terminal Status (Done) and "no verdict-free Done"
  is absolute, so retire can't safely terminalize yet. Proper fix = a non-Done "closed-not-planned"
  disposition = a **Phase-4 board-schema change** (TODO already in `workflow-machine.yaml`). Nothing in
  think→plan→build depends on retire terminalizing.
- **github `link` idempotency** — a repeated link posts a duplicate `idc-blocked-by` marker comment
  (harmless; a native GitHub issue-dependency edge would be better). Defer.
- **`BoardWriteError` exit-2-vs-3** — a config-broken board (e.g. missing Status option) is now
  exit-3/resumable alongside transient errors (strictly safer than the old exit-1 traceback). Possible
  future split if the drain needs "retry" vs "fix the board". Non-blocking.
- **filer's pre-existing double `TRACKER.md` read** — out of scope this phase; minor cleanup follow-up.

---

## Rollout discipline & conventions (keep consistent across remaining stages)

- **Stage 3 interlocks SHIP warn-inject** (honor `IDC_HOOKS_OBSERVE_ONLY=1` → downgrade deny to warn);
  the deny path must EXIST and be e2e-exercised behind the mode switch now (hard-deny promotion is a
  later operator decision, §6 decision 1: recommend one release warn-first). Raw board mutations outside
  the engine are deny-by-design (warn-only during rollout). **Contrast:** the Stage-2 finish receipt gate
  is a HARD gate and deliberately does NOT honor `OBSERVE_ONLY` (downgrading a merge gate to "merge
  anyway" defeats it; its debug escape is `--no-require-routed-findings`).
- `hooks/hooks.json` is **auto-discovered — NEVER also list it in `plugin.json`** (the 3.1.1
  duplicate-hooks regression). Hook scripts live in `scripts/hooks/`, are repo-gated, share the P4
  fail-mode helper (`scripts/hooks/idc_hook_lib.py`). PreToolUse/PostToolUse/Stop/SubagentStop are
  PROVEN to fire in headless `-p` (Phase-1 spike, `2026-07-03-phase1-hook-availability-spike.md`).
- Shipped-file conventions (lint-enforced): `idc:` namespacing; `${CLAUDE_PLUGIN_ROOT}` is markdown
  text-substitution, NOT a shell env var (scripts take the root as an argument); no personal paths.
- Journal append is STUBBED in the engine (`docs/workflow/transition-journal.ndjson`); the real
  event-sourced journal + reconciliation is **Phase 4** (off-limits now).
- **Never touch live repos** (knowledge-engine, mdm-proj) — sandboxes only.

---

## Task board snapshot (this run)

1. ✅ Stage 1 — transition engine + machine table + merge_conditions + re-point filer (MERGED #133)
2. 🔶 Stage 2 — idc_git_finish --require-routed-findings + merge_conditions (PR #135 OPEN — needs review+merge)
3. ⬜ Stage 3 — PreToolUse interlocks + hooks.json + new lint rule
4. ⬜ Stage 4 — scaffold wiring for workflow-machine.yaml
5. ⬜ Stage 5 — integration + sandbox e2e (top-level acceptance)
6. ✅ Stage 1b — wire github move/close/link engine ops (MERGED #134)
7. ⬜ Fix chronic CI red (phase9-realgit non-hermetic in Actions; pre-existing, not the engine)
