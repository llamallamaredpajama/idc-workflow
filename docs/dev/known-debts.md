# Known workflow debts (to seed as GitHub issues at publish)

Pre-existing issues in the workflow definition discovered during migration. These are
NOT migration regressions — they were latent in the `~/.claude` originals. Each becomes
a GitHub issue when the repo publishes; the `lint-allow` markers in the files reference
this list.

## Dangling skill/agent references (never existed in any source)

Found by the B5 sweep in the Codex adapter skills:

1. `idc-skill-run-audit` (CS-1 closeout audit) — referenced by codex-idc-ripple, codex-idc-sequence. The closeout-audit *procedure* is described inline but the dedicated skill was never authored.
2. `idc-skill-role-handoff` (CS-2 closeout handoff) — referenced by codex-idc-ripple, codex-idc-sequence. Same situation.
3. `idc-skill-tracker-wave-queue-edit` (QS-1) — referenced by codex-idc-sequence.
4. `idc-skill-engineering-admission-audit-write` — retired; functionality folded into `idc:idc-skill-canonical-admission-audit`. References should eventually be rewritten to the successor skill.
5. `idc-role-closeout-author` — forward reference ("when Codex parity lands"); the role was never created. Also referenced by idc-role-change-order-author.
6. `idc-skill-run-ledger` — referenced by idc-role-integration-verifier (L29, L104, L146) as the ledger-update substrate; the dedicated skill was never authored.

## Retired/folded names (historical mentions only — no issue needed; either bare + lint-allow, or de-prefixed with a "now idc:…" annotation per B4's convention)

- `idc-skill-engineering-admission-audit-write` — folded into `idc:idc-skill-canonical-admission-audit`.
- `idc-role-pr-deconflict` (CR-9) — folded into `idc:idc-role-merge-deconflictor` per its own description.
- `idc-skill-think-output-contract` — appears only in "formerly `…`" clauses of idc-role-think-investigator.
- `idc-skill-canonical-doc-review`, `idc-skill-governance-verdict`, `idc-skill-impact-classifier`, `idc-skill-canonical-gate-enforcement`, `idc-skill-engineer-anti-pattern-check` — folded into surviving skills (see annotations at mention sites).
- `idc-skill-pillar-matrix-dag-synth`, `idc-skill-pillar-matrix-wave-synth`, `idc-skill-pillar-matrix-parallel-safety-synth` (WM-3/4/5) — folded into `idc:idc-skill-pillar-matrix-synth`; mentioned in its "Replaces former" lines and in idc-skill-clash-evidence.
- `codex-idc-engineer`, `codex-idc-develop`, `codex-idc-deconflict` — consolidated into `idc:codex-idc-plan`.
- `idc-develop`, `idc-deconflict`, `idc-engineer` orchestrators — absorbed into `idc:idc-plan` (Plan owns the former Engineer/Develop/Deconflict cognitive surfaces).
- `idc-skill-tracker-wave-queue-edit` (QS-1) — never authored; sequence-side references are debt item-like but queue edits are covered by `idc:idc-skill-tracker-adapter` ops.

## Pre-publish polish list (orchestrator pass at Phase E, before the public flip)

- Replace project-abbreviation "KE" tokens (e.g. "KE inference", "KE-fit") with "the governed repo"/"the project" where they denote the original project — heaviest in idc-skill-think-research-archive, idc-skill-think-brainstorming-substrate.
- Rename `/tmp/ke-idc-<role>/` scratch-path conventions to `/tmp/idc-<role>/`.
- Eyeball remaining literal `~/.claude/` governance-surface descriptions (idc-skill-ripple-verdict, idc-workflow) — harness-standard paths (`~/.claude/CLAUDE.md`, `~/.claude/hooks/`, `~/.claude/teams|tasks`) stay; stale self-edit-surface doctrine gets T11 treatment.

## Other known debts (from pre-migration review)

6. Dangling `architecture.md §Cross-runtime substrate model` reference (noted in the migration plan as a known debt).
7. `agents/idc-ripple.md` (~L46) still describes the OLD 7-role chain (Think → Engineer → Develop → Deconflict → Sequence → Build → Ripple) while every other surface uses the consolidated 5-role chain — pre-existing content inconsistency, found by B1.
8. Codex adapter closeout drift: `codex-idc-sequence` / `codex-idc-ripple` closeout steps still call the CS-1 `idc-skill-run-audit` / CS-2 `idc-skill-role-handoff` procedures that the Claude agent layer refactored out — the Codex skills are semantically stale relative to the agents (found by B5; aligns with the Phase F Codex-parity work).
9. GUARD-RAIL (do not "fix"): the eval sandbox's WORKFLOW §6.6 (scripts/materialize-sandbox.sh heredoc) DELIBERATELY diverges from templates/WORKFLOW.md §6.6 — the sandbox grants wave-promotion to Sequence only, so `build-refuse-forbidden-tool` measures reasoning rather than doctrine recall. Aligning the two will silently break that eval (auditor-confirmed; comment at the heredoc site).

## Post-v0.1.0 audit residue (2026-06-11 fidelity-audit triage)

Findings from `docs/dev/2026-06-11-fidelity-audit.md` that were deliberately triaged to
this register instead of fixed in the audit-repair pass (everything not listed here was
fixed). One line of rationale each; nothing silently dropped.

- **MIN-8 (deliberate drop, was `commands/autorun.md` dispatch list):** the original
  listed `idc-role-tracker-adapter`, a role that never existed (only the *skill*
  `idc:idc-skill-tracker-adapter` does). The name stays dropped rather than restored —
  re-adding a never-existent role name + lint-allow would only add noise.
- **MIN-9 residual linter blind spots** (the ruled fixes — Rule 6 path-existence,
  Rule 7 frontmatter-name bareness, Rule 5 bypass documentation — landed): `idc:idc:`
  doubles; unknown `/idc:<command>` typos never extracted; an orchestrator-name rule
  (bare `idc-plan`/`idc-build` etc. prose refs are unlinted by design — revisit together
  with the six `Task(subagent_type: idc-<role>)` agent self-check lines, which may be
  semantically stale for installed-plugin spawns arriving as `idc:idc-<role>`);
  `idc-skill` split across a linebreak; `~/.claude/agents` without trailing slash;
  `/Users/<Capitalized>` usernames.
- **MIN-14 (install-codex / doctor drift):** no mirror pruning/re-sync — a skill
  added/removed in `~/.claude/skills` after install stays invisible/dangling in the
  Codex view, and `/idc:doctor` checks only the 5 adapter links so the drift is
  undetectable. Re-running install is the manual workaround. Also: `plugin.json` says
  `0.1.0` while CHANGELOG has only `## Unreleased` — converts at publish (Task #12).
- **Nit (idc-plan ~L388):** the dropped "(~/.claude/plans/ is historical fallback
  only)" clause stays dropped — defensible under R7/R8 (personal-path genericization).
- **Nit (autorun prose spawn refs):** prose refs to `idc-sequence` stay bare while
  machine-readable `subagent_type` strings are namespaced — deliberate convention;
  revisit if the orchestrator-name lint rule ever lands.
- **Nit (merge-deconflictor description):** the folded CR-9 name appears de-prefixed
  (`pr-deconflict`) in the YAML description — frontmatter can't carry lint-allow
  comments; the body site uses the sanctioned form.
- **Nit (canonical-admission-audit ~L390):** rename target rendered
  `idc:codex-idc-plan` where the literal dir rename target is bare — cosmetic, matches
  the "now `idc:…`" convention.
- **Nit (GFM phantom cell):** `lint-allow` HTML comments appended after a table row's
  closing `|` render as a spurious 4th cell — cosmetic, convention-wide; a rendering
  polish pass can move the markers inside the last cell.
- **Nit (file-operator-todo):** the emitted-record byte format carries the
  `idc:`-prefixed generator skill name — meaning preserved; consumers don't match on it.
- **Nit (codex-idc-ripple substrate intro):** the rewrite dropped the explicit
  `idc-role-<name>.md` / `idc-skill-<name>/SKILL.md` filename-pattern examples —
  meaning preserved; optional reinstate.
- **Nit (anchorless provenance pointers):** `appendices/codex-drift-ripple.md` (8 refs)
  and `docs/workflow/audits/2026-05-07-…/open-questions.md` Q-cross pointers cite the
  original project's audit tree, which does not ship with the plugin. Historical
  provenance only — now registered here as the audit asked.
- **Nit (CI hardening):** `bash -n` can't catch bash-3.2-only incompatibilities
  (shellcheck adoption is a candidate); the linter's Rule-4 header comment names the
  original project (it is the rule's own description; the regex must keep the literal).
- **Runtime-tooling references (recorded for completeness, not an audit finding):**
  several Build-side surfaces reference `scripts/sync_github_tracker.py` /
  `docs/workflow/scripts/pillar_matrix.py` — governed-repo-side runtime tooling the
  plugin does not ship; a fresh scaffold lacks them until the planned tracker-runtime
  CLI lands.
- **EVAL nit (`--keep`):** stale sandbox mutations from a prior case can false-FAIL a
  later case's `no_forbidden_source_writes` gate — use `--keep` for debugging only.
- **EVAL nit (dead schema fields):** `session_input` ADK ceremony, always-empty
  `all_of`, and `headless_note` (read only when `headless=="skip"`, which no set
  currently sets) are inert schema carried for ADK fidelity — docs-only.
- **EVAL note (fixture token mentions):** `fixture-build-empty-recipe.md` and the
  frozen `test-cases/role-build-pillar/rubric.yaml` mention their cases' expected
  tokens in fixture prose — defused by the anchored det gate (the runner only reads the
  agent's structured final `verdict:`/`refusal:` line), so no fixture scrub needed.
- **EVAL note (agent-side `bypassPermissions`):** retained by design and now documented
  in `run-evals.sh`'s header + `docs/dev/evals.md` §Permissions caveat (the judge-side
  grant was dropped).

## Handling policy during migration

Sweep teammates keep these references textually intact (bare, un-namespaced — there is
nothing to namespace to) with an HTML comment marker on the line:
`<!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->`
Fixing them is deliberate post-v0.1.0 work, not sweep scope.
