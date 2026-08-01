# Known workflow debts

Latent issues in the workflow definition, found during the v1→v2 migration (NOT migration
regressions — they predate it in the `~/.claude` originals). These were seeded as GitHub issues
at publish.

**Reconciled 2026-06-19 (leftover-issues sweep).** The v2 5-role consolidation + pi-unification +
Build-pillar shipping resolved the bulk of this register: issues **#1, #2, #3, #4, #7, #8, #9, #16,
#17** were verified already-resolved (the surfaces they named were deleted — `lint-references.sh` is
CLEAN and zero `lint-allow` dangling-ref markers remain in shipped files), **#5** (MIN-9 lint
blind-spots) and **#6** (MIN-14 mirror prune + doctor drift) were FIXED in this sweep, and **#10** was
closed as superseded by pi-unification. Their register entries are struck below; what remains is the
GUARD-RAIL, out-of-scope nits, and the new Pi-runtime-maturity debt (#66 L1/L3/L4). Full provenance:
git history + `docs/dev/2026-06-11-fidelity-audit.md`.

## Retired/folded names (historical mentions only — no issue needed; either bare + lint-allow, or de-prefixed with a "now idc:…" annotation per B4's convention)

- `idc-skill-engineering-admission-audit-write` — folded into `idc:idc-skill-canonical-admission-audit`.
- `idc-role-pr-deconflict` (CR-9) — folded into `idc:idc-role-merge-deconflictor` per its own description.
- `idc-skill-think-output-contract` — appears only in "formerly `…`" clauses of idc-role-think-investigator.
- `idc-skill-canonical-doc-review`, `idc-skill-governance-verdict`, `idc-skill-impact-classifier`, `idc-skill-canonical-gate-enforcement`, `idc-skill-engineer-anti-pattern-check` — folded into surviving skills (see annotations at mention sites).
- `idc-skill-pillar-matrix-dag-synth`, `idc-skill-pillar-matrix-wave-synth`, `idc-skill-pillar-matrix-parallel-safety-synth` (WM-3/4/5) — folded into `idc:idc-skill-pillar-matrix-synth`; mentioned in its "Replaces former" lines and in idc-skill-clash-evidence.
- `codex-idc-engineer`, `codex-idc-develop`, `codex-idc-deconflict` — consolidated into `idc:codex-idc-plan`.
- `idc-develop`, `idc-deconflict`, `idc-engineer` orchestrators — absorbed into `idc:idc-plan` (Plan owns the former Engineer/Develop/Deconflict cognitive surfaces).
- `idc-skill-tracker-wave-queue-edit` (QS-1) — never authored; sequence-side references are debt item-like but queue edits are covered by `idc:idc-skill-tracker-adapter` ops.

## Other known debts (from pre-migration review)

- **GUARD-RAIL (do not "fix"):** the eval sandbox's WORKFLOW §6.6 (scripts/materialize-sandbox.sh heredoc) DELIBERATELY diverges from templates/WORKFLOW.md §6.6 — the sandbox grants wave-promotion to Sequence only, so `build-refuse-forbidden-tool` measures reasoning rather than doctrine recall. Aligning the two will silently break that eval (auditor-confirmed; comment at the heredoc site).

## Open debts (post-2026-06-19 sweep)

- **Fixed-profile Path Gate self-mints remain self-servable (V-DOOR residual) — TWO paths.** Deleting
  the public `idc_path_gate.py authorize` verb removed every *caller-chosen-scope* minting door. It
  did not remove every minting door; two FIXED-profile ones remain, each self-servable from raw Bash
  in any governed session:
  1. `idc_command_contract.py start --command init` mints init's fixed default profile
     (`write`/`edit`/`git` over the whole repository); its only precondition is that the repository is
     governed.
  2. **(added by V-AUTH stage 2)** `idc_command_contract.py start --command build` opens a build
     record (which mints *nothing* on its own), then `idc_transition.py claim --num N` mints the
     claim-scoped grant: `write`/`edit`/`git` over the whole repository (`.`), bound to ticket N.
     Its extra precondition over path 1 is a claimable board item N; the scope is still FIXED (the
     ticket's own whole-repo grant), never the caller's to choose. Once the unit's contract is frozen
     the grant narrows to `touch` − `off_limits`, but the pre-freeze claim window is repo-wide.
  Neither is a regression (init's route predates V-DOOR; the build claim is the sanctioned write seam
  itself), and both are materially narrower than the deleted verb — no scope, no ticket/graph/branch
  of the caller's choosing (path 2's ticket must be a real claimable item), and the read-only role
  ceiling still applies. They are ACCEPTED residuals, documented here honestly, not closed.
  **Why it is not closed here.** The natural fix is a single-use admission token issued by
  `scripts/hooks/idc_command_entry_gate.py`, which DOES run on `/idc:init`'s expansion. But that gate
  is a Claude `UserPromptExpansion` hook and neither Codex nor Pi runs Claude hooks, while
  `idc_path_gate.write_authorization`'s production callers are all fixed admission/transition code —
  that hook, both self-mints above, and (since V-AUTH stage 2) the claim-time mint/narrow/retire in
  `idc_path_gate.py`, which requires an ACTIVE build/autorun command record to bind. A Codex/Pi run
  therefore has two runtime-neutral self-serve paths (open an init record, or open a build record and
  claim a board item — both above), each granting a FIXED whole-repo profile, and
  github-backed repositories scaffold `pathway_enforcement.mode: controlled` by default with the
  git pre-commit/pre-push backstops installed. Gating the self-mint on a Claude-only token would
  therefore deny every Codex/Pi commit in a default governed repository (verified directly: with no
  authorization present and `mode: controlled`, `git commit` is refused by the backstop with "the live
  authorization is absent"; after `start --command init` the same commit succeeds).
  **What closing it needs:** a runtime-neutral admission signal — e.g. the entry gate issues the token
  when it runs, and the Codex/Pi adapters gain an equivalent admission step of their own — so the
  token requirement can be made unconditional without stranding those runtimes.
  Characterized (not claimed away) by `tests/smoke/governance/path-gate-boundaries.sh` D2 §3c.

- **Experimental Pi runtime maturity — L1 / L3 / L4 (issue #66).** The autonomous-IDC-lifecycle gaps
  that need a live multi-provider Pi runtime to build and verify, so they were NOT closed in the sweep.
  Only **L2** (model-selection doc-truth) was fixed — `skills/idc-adapter-pi/SKILL.md` now describes the
  hardcoded `role_model()` reality (per-role stock defaults overridable by `PI_IDC_<ROLE>_MODEL`) instead
  of the aspirational "resolves from `WORKFLOW-config.yaml::model_routing`" claim. The load-bearing gaps:
  - **L1 — no parallel Build pool:** `runtime/pi/scripts/idc-pi` opens one resident per role; the
    N-resident Build triplet pool is unwired, so Build is serial on Pi.
  - **L3 — stock role-model defaults assume providers a default `pi` install lacks:** the per-role
    defaults span anthropic + deepseek + openai, so out of the box every role fails unless the operator
    pre-auths those providers in `pi` or overrides every `PI_IDC_<ROLE>_MODEL`.
  - **L4 — no `--pi` runtime in `/idc:init`, and no autonomous drain loop:** a full lifecycle under Pi
    must be manually orchestrated stage-by-stage; nothing on Pi reads the board and self-advances.
  - **Test vehicle:** the Pi-runtime e2e harness (plan `to-figure-out-how-splendid-waterfall`;
    `_idc-observability/bin/run-pi-e2e.sh` + the `ke-idc-test-repo-pi` sandbox) is being built to exercise
    these — `idc-pi fleet` against L1, single-provider Gemini env-pins sidestepping L3,
    harness-as-scripted-operator working around L4 — and is the path to eventually closing them. See
    `docs/dev/local-e2e-testing.md`.

## Post-v0.1.0 audit residue (2026-06-11 fidelity-audit triage)

Remaining findings from `docs/dev/2026-06-11-fidelity-audit.md` deliberately triaged to this register
(deliberate keeps, not tied to a closed sweep issue). One line of rationale each.

- **MIN-8 (deliberate drop, was `commands/autorun.md` dispatch list):** the original
  listed `idc-role-tracker-adapter`, a role that never existed (only the *skill*
  `idc:idc-skill-tracker-adapter` does). The name stays dropped rather than restored —
  re-adding a never-existent role name + lint-allow would only add noise.
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
- **Nit (CI hardening):** `bash -n` can't catch bash-3.2-only incompatibilities
  (shellcheck adoption is a candidate); the linter's Rule-4 header comment names the
  original project (it is the rule's own description; the regex must keep the literal).
