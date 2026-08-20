# PR #183 review-findings fix plan — 2026-07-27

Verified by the lead against head `97f6da3` of `fix/pr-182-pathway-integrity` (PR #183 →
`integration/idc-pathway-integrity`, which is PR #182's head branch). Work happens in the EXISTING
worktree `/Users/jeremy/dev/proj/idc-workflow/.claude/worktrees/fix-pr-182-pathway-integrity` on the
EXISTING branch `fix/pr-182-pathway-integrity` — do NOT create a new worktree or branch.

## Finding verdicts (lead's verification, all confirmed against code)

| # | Reviewer finding | Verdict |
|---|---|---|
| W1 | Checker accepts a >3 MB CODEOWNERS GitHub will not load | REAL — no size check anywhere in `scripts/idc_ruleset_check.py` / installer path |
| W2 | Owner principals never verified against the target repo | REAL gap — checker is hermetic by design; nothing at install time confirms owners exist + have write access |
| W3 | `--default-branch` accepts any locally-resolving commit-ish | REAL — `scripts/idc_ruleset_install.py:163-173` only checks `rev-parse --verify REF^{commit}`; stale `origin/HEAD` also unguarded |
| W4 | Pi can merge in Plan/Recirculator without operator checkpoint | REFUTED as stated — Pi residents run `runtime/pi/.pi/agents/idc/plan.md` (lines 34-38, 53-56) and `recirculator.md` (lines 31-35, 52), which already mandate operator-performed merge and forbid self-merge; nothing in `runtime/pi/` references `idc_pr_finish.py`. The `agents/idc-*.md` automerge steps are Claude/Codex playbooks where automerge is the documented contract (docs/architecture.md ~line 116). REAL RESIDUE: only the build-finisher persona has a red-when-broken smoke guard (`tests/smoke/phase8-pi-finish-gate.sh`); the plan/recirculator personas' merge posture is unguarded. |
| W5 | Witness retention (cap 8) can strand an in-flight Build | REAL — documented fail-closed tradeoff in `_evict_stale_versions` (`scripts/idc_validation_contract.py:322-352`), but the window is real: `planning_witness_problem` is checked exactly once, at Build contract freeze (`_planning_receipt_info`, line 681), so 8+ same-label Plan re-applies between a Build claiming work and freezing strand a legitimate receipt. P2, proportionate fix only. |

## Work items

### W1 — Reject CODEOWNERS files GitHub will not load (3 MB limit)

GitHub documents: a CODEOWNERS file ≥ 3 MB is not loaded at all → installed protection would have
no code owners despite a green receipt. Fail-closed rule: refuse when the file's RAW BYTE size
≥ 3*1024*1024.

- Measure BYTES, never decoded text length: the working-tree read (`_read_codeowners`) uses text
  mode (universal newlines collapse CRLF → undercount); the committed read
  (`_committed_codeowners` in the installer) has raw `git show` stdout bytes. Thread a byte size
  from both read sites into the shared `validate_codeowners_content` (new optional parameter or
  readers return size — implementer's choice, keep churn minimal), so BOTH the checker
  (`validate_codeowners`) and the installer's committed-content gate refuse.
- Refusal message: actual size, the 3 MB limit, and that GitHub will not load the file.
- Tests (hermetic, in `tests/smoke/governance/ruleset-checker-local.sh` or a sibling): oversized
  file → REFUSE naming the limit; just-under file → still certifiable; installer committed-path
  case (commit an oversized CODEOWNERS in the temp repo → installer refuses). Every new guard
  proven red-when-broken.

### W2 — Live principal verification at install time (installer `--apply` path)

The checker stays hermetic (document that). The INSTALLER, at `--apply`, after the ownership gate
and before any mutation, verifies every DISTINCT owner token in the COMMITTED CODEOWNERS:

- `@user` → `gh api repos/{repo}/collaborators/{user}/permission`; require an effective
  write-or-better grant (accept `permission` ∈ {admin, write, maintain}; be robust to `maintain`
  surfacing via `role_name`). Missing/404 → refuse.
- `@org/team` → `gh api orgs/{org}/teams/{team}/repos/{owner}/{repo}` with
  `Accept: application/vnd.github.v3.repository+json`; require `permissions.push` or `.maintain`
  or `.admin` true. 404 (team absent, invisible, or no access) → refuse.
- Email owner → refuse at apply as live-unverifiable, message suggests @handles (fail closed,
  consistent with the module's F41 philosophy).
- ANY gh failure / non-JSON / network error → refuse (fail closed); scrub child stderr via
  `CS.scrub` at the read, like every other subprocess read in these modules (R28 census).
- Dry-run makes NO network calls (preserve that contract); print a note that principals are
  live-verified at apply.
- Tests: stub `gh` on PATH serving canned responses (follow the existing stub pattern in
  `tests/smoke/governance/*`): all-green pass; nonexistent user; read-only user; missing team;
  email owner; gh hard-failure → each refuses. Red-when-broken proof for the central guard.

### W3 — Bind validation to GitHub's actual default branch (installer `--apply` path)

- At apply, fetch `gh api repos/{owner}/{repo}` → `.default_branch` = D.
  - With `--default-branch REF`: REF must NAME D (accept exactly `D` or `origin/D`); a SHA, PR
    head, or any other branch → refuse, naming D. REF must still resolve locally.
  - Without override: the `origin/HEAD` short name's branch must equal D; mismatch → refuse with
    `git remote set-head origin -a` guidance (stale origin/HEAD).
  - Staleness guard: `gh api repos/{repo}/branches/{D}` → `.commit.sha` must equal the local
    `rev-parse` of the validation ref; mismatch → refuse ("checkout is stale — git fetch first").
    This pins `git show` to the exact bytes GitHub enforces.
- Dry-run keeps today's local-only resolution; print a note that apply binds to the live default
  branch.
- Tests: stubbed-gh cases — override names non-default → refuse; override names default → pass;
  origin/HEAD ≠ live default → refuse; local SHA ≠ remote SHA → refuse; clean pass. Existing
  local-mode (dry-run) tests must keep passing unchanged.

### W4 — Red-when-broken guard for the Pi plan/recirculator merge posture

- New smoke test (or extend `tests/smoke/phase8-pi-finish-gate.sh`, same have/absent helper
  style) asserting for BOTH `runtime/pi/.pi/agents/idc/plan.md` AND `recirculator.md`:
  - HAVE operator-performed-merge language (`operator[- ]performed|operator (performs|must perform|merges)`);
  - HAVE a prohibition on raw/self-directed merge commands;
  - ABSENT `gh pr merge` and ABSENT any instruction to run the autonomous finisher
    (`idc_pr_finish.py autonomous`).
- Confirm how `tests/smoke/run-all.sh` discovers tests so the new file actually runs.
- Adjacent doc clarity (small): one sentence in `agents/idc-plan.md` (near line 181) and
  `agents/idc-recirculator.md` (near line 77) noting the automerge step is Claude/Codex-runtime
  behavior and that the Pi runtime's personas stop at an operator-performed merge
  (cross-ref docs/architecture.md). Keep `scripts/lint-references.sh` green.

### W5 — Age-aware witness retention (proportionate P2 fix)

Replace the pure count-8 eviction in `_evict_stale_versions` with count+age hybrid retention:

- Always keep: (a) the receipt's current on-disk digest; (b) the newest `PLANNING_WITNESS_RETAIN`
  (8) versions by `validated_at`; (c) ANY version whose `validated_at` is within a grace window
  (`PLANNING_WITNESS_GRACE_SECONDS`, propose 7 days) — bounded by a hard cap
  (`PLANNING_WITNESS_HARD_CAP`, propose 64: beyond it evict oldest-first even inside grace, so
  the F31 boundedness guarantee survives).
- Rationale: a real Build claims and freezes within days; re-apply churn inside the grace window
  can no longer evict the version a pre-freeze Build holds. Residual (document honestly in the
  docstring): a Build slower than grace/cap still re-anchors fail-closed via the existing
  recovery message.
- Timestamps: `validated_at` is ISO-8601 from `_now()`; compare lexically or parse — but NEVER
  call wall-clock-free assumptions; ambient Python 3.9 must parse whatever format `_now()` emits.
- Tests: update `tests/smoke/governance/build-planning-witness-retention.sh` — keep proving
  boundedness (hard cap enforced, oldest evicted) AND add: a version inside the grace window
  survives >8 newer re-applies (simulate age by rewriting `validated_at` in the store JSON — it
  lives in the git common dir). Both directions red-when-broken.

## Run constraints (binding)

- Worktree/branch: the EXISTING `/Users/jeremy/dev/proj/idc-workflow/.claude/worktrees/fix-pr-182-pathway-integrity`
  on branch `fix/pr-182-pathway-integrity` (PR #183). Do not create a new worktree/branch; push
  commits to the same branch so PR #183 updates.
- Python: ambient 3.9 compatibility everywhere in `scripts/` (no 3.10+ syntax; `from __future__
  import annotations` is already in use for `X | None` annotations).
- Every commit preceded by `bash scripts/lint-references.sh` (must exit 0). Full gate =
  `bash tests/smoke/run-all.sh` fully green.
- Shipped files (`commands/ agents/ skills/ templates/ scripts/`): portable paths only, `idc:`
  namespacing rules — see repo CLAUDE.md.
- Test shell portability: write grep/awk against `/usr/bin/grep` + `/usr/bin/awk` semantics (the
  interactive default grep here is ugrep and is more permissive).
- Never weaken an existing gate or test to go green.
- Codex reviews run at xhigh reasoning effort, not max.
- Review loop: two-bucket severity (blockers must be fixed; nits recorded, fixed only when
  trivial). Hard cap: if after 2 full review rounds new blockers still appear, STOP and surface
  to the operator instead of looping.

## DONE contract (declared up front)

1. `bash scripts/lint-references.sh` exit 0.
2. `bash tests/smoke/run-all.sh` fully green (all phases, including the new/updated tests).
3. Latest codex review AND latest custom review each report 0 new blockers.
4. Every new/changed guard demonstrated red-when-broken (receipts in the run ledger).
5. Commits pushed to `fix/pr-182-pathway-integrity`; both GitHub checks green on PR #183.

## Merge instructions (operator pre-authorized — do not re-ask)

On DONE: squash-merge PR #183 into `integration/idc-pathway-integrity`
(`gh pr merge 183 --squash`). Do NOT `--delete-branch` (the branch is checked out in a live
worktree). Do NOT merge PR #182 — the operator reviews that personally.
