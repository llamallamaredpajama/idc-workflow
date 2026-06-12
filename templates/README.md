# templates/ — per-project IDC scaffold

`/idc:init` copies these files into a target repository to make it IDC-governed,
substituting the placeholder tokens below with values for that repo. Nothing here is
plugin runtime — it is the scaffold a governed repo carries.

## Placeholder tokens

`/idc:init` replaces every occurrence of these tokens. In the YAML files the tokens are
written as quoted strings so the templates stay valid YAML; `init` substitutes the token
text and, for numeric values, drops the surrounding quotes.

| Token | Meaning | Example | Appears in |
|---|---|---|---|
| `{{PROJECT_NAME}}` | Human-readable name of the governed repo. | `acme-data-platform` | `WORKFLOW.md`, `WORKFLOW-config.yaml` |
| `{{GITHUB_OWNER}}` | GitHub user or org that owns the repo and its Project board. | `acme-co` | `WORKFLOW.md` |
| `{{GITHUB_REPO}}` | Repository name (without the owner prefix). | `data-platform` | `WORKFLOW.md` |
| `{{TRACKER_PROJECT_NUMBER}}` | GitHub Projects v2 board number, from `gh project create`. Only used by the `github` tracker backend; leave the token in place (or switch `backend: filesystem`) until the board exists. | `7` | `WORKFLOW.md`, `WORKFLOW-config.yaml`, `tracker-config.yaml` |

## Harness compatibility keys (`WORKFLOW-config.yaml` → `workflow:`)

`WORKFLOW-config.yaml` opens with a static `workflow:` block: `schema: idc` identifies
the governance contract family, and `version: 1` is the schema version external tools
can key on. Two optional keys ship commented out — `contract_profile` and
`min_harness_version` — for repos whose governance is consumed by an external,
governance-compiling agent harness (for example `pi-idc-collab`): uncomment and set them
when such a harness executes the repo, so it can validate which contract profile and
minimum harness version the repo expects. They are not template tokens; `/idc:init` does
not substitute or manage them.

## What `/idc:init` places where

| Template file | Destination in the governed repo | Notes |
|---|---|---|
| `WORKFLOW.md` | `<repo>/WORKFLOW.md` | The governance contract. Hard requirement — marks the repo as IDC-governed; section numbers are stable for citation. |
| `WORKFLOW-config.yaml` | `<repo>/WORKFLOW-config.yaml` | IDC contract sidecar. Only `project.name` is a hard requirement. |
| `tracker-config.yaml` | `<repo>/docs/workflow/tracker-config.yaml` | The live tracker contract. Fill `field_ids` after `gh project create` (github backend) or switch `backend: filesystem`. |
| `docs-tree/` | `<repo>/docs/workflow/` | The standard IDC process-artifact directories (each with a `.gitkeep`) plus a README describing them. See `docs-tree/README.md`. |

After `/idc:init`, run `/idc:doctor` to verify the scaffold resolves and the tracker
backend is reachable.
