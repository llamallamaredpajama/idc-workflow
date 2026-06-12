# Changelog

All notable changes to the IDC Workflow plugin are documented in this file.

## Unreleased

- Docs: hardened `/idc:init` and `/idc:doctor` from first live-install field evidence
  (2026-06-12, two clean installs). `init.md` Phase 3 now ships a tested zsh-safe
  docs-tree copy loop (an improvised loop hit zsh's unmatched-glob abort in the field);
  `gh project list` carries `--limit 200` so a >30-board account can't silently create
  a duplicate tracker; both `gh project field-list` calls carry `--limit 50` (a fresh
  board already has 20 fields vs the gh default limit of 30). `doctor.md` check 5 now
  names the five Codex adapter links explicitly instead of relying on wildcard matching.
- Docs: fixed the first-run bootstrap deadlock. With the plugin disabled at user scope
  (the per-project scoping model), a never-initialized repo has no `/idc:*` commands —
  so `/idc:init` could not be the documented first step. `README.md` and
  `docs/installing.md` now bootstrap each project with
  `claude plugin enable idc@idc-workflow --scope project` from the terminal before the
  first `/idc:init`, and `/idc:doctor` troubleshooting covers the
  "no `/idc:*` commands at all" state.

## 0.1.0 — 2026-06-11

Initial public release: the IDC workflow (Think → Plan → Sequence → Build → Ripple),
migrated from a local `~/.claude` installation into a standalone, installable Claude
Code plugin.

- Slash surfaces: `/idc:think`, `/idc:plan`, `/idc:sequence`, `/idc:build`,
  `/idc:ripple`, `/idc:autorun`, plus `/idc:init` (idempotent per-repo scaffold +
  tracker provisioning) and `/idc:doctor` (five-check install verifier).
- Role orchestrator agents, roleplayer agents, and the `idc-skill-*` substrate skills,
  all namespaced under `idc:`.
- Codex runtime adapters (`codex-idc-*`) with `scripts/install-codex.sh` managing the
  `~/.agents/skills` resolution view.
- Per-repo governance scaffold templates (`WORKFLOW.md`, `WORKFLOW-config.yaml` with
  `workflow.schema`/`workflow.version` + optional external-harness compatibility keys,
  tracker config, `docs/workflow/` tree).
- Behavioral eval suite (19 evalsets / 24 cases) with a disposable governed sandbox,
  deterministic token gate + LLM-judge scoring, and infra-error-aware exit codes.
