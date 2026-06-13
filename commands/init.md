---
description: IDC Init — scaffold a repo for the v2 IDC pipeline (WORKFLOW.md, config with codebase-derived domains, 4-field board, install receipts)
argument-hint: "[PROJECT_NAME] [--codex]"
---

`/idc:init` installs the IDC v2 workflow into the current repository: it scaffolds the
governance contract and configs from the plugin templates (filling `domains` from a
codebase scan and the tier-symbolic `model_routing` table), provisions or links a GitHub
Projects v2 tracker board matching the **four-field** v2 schema (`Status` =
`Blocked|Todo|In Progress|Done`, `Wave`, `Phase`, `Domain`), enables the plugin for the
project, writes install receipts for clean uninstall/upgrade, and — with `--codex` — wires
the single Codex runtime adapter. Idempotent: anything already present is reported
`skipped-existing`. See the contract in `WORKFLOW.md §3`.

> v2 rebuild status: the full `/idc:init` playbook (board provisioning, receipts, the
> folded lifecycle scope) is authored in **Phase 1** of the IDC v2 rebuild. (stub)
