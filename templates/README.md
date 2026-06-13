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
| `{{TRACKER_PROJECT_NUMBER}}` | GitHub Projects v2 board number, from `gh project create`. Only used by the `github` tracker backend; leave the token in place (or switch `backend: filesystem`) until the board exists. | `7` | `tracker-config.yaml` |

## What `/idc:init` places where

| Template file | Destination in the governed repo | Notes |
|---|---|---|
| `WORKFLOW.md` | `<repo>/WORKFLOW.md` | The governance contract. Hard requirement — marks the repo as IDC-governed; section numbers are stable for citation. |
| `WORKFLOW-config.yaml` | `<repo>/WORKFLOW-config.yaml` | IDC contract sidecar: `project.name` (hard requirement), the codebase-derived `domains`, and the tier-symbolic `model_routing` table. |
| `tracker-config.yaml` | `<repo>/docs/workflow/tracker-config.yaml` | The live tracker contract (4-field board). Fill `field_ids` after `gh project create` (github backend) or switch `backend: filesystem`. |
| `docs-tree/` | `<repo>/docs/workflow/` | The lean v2 process-artifact tree (`pillar-matrices/`, `code-reviews/`, each with a `.gitkeep`) plus a README. See `docs-tree/README.md`. |

After `/idc:init`, run `/idc:doctor` to verify the scaffold resolves and the tracker
backend is reachable.
