# Changelog

All notable changes to the IDC Workflow plugin are documented in this file.

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
