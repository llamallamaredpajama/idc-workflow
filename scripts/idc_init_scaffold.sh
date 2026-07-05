#!/bin/bash
# idc_init_scaffold.sh — the deterministic filesystem scaffold step of /idc:init.
#
# Copies the plugin templates into a target repo, substitutes {{PROJECT_NAME}}, lays down
# the lean v2 docs/workflow tree, sets the tracker backend, and (filesystem backend only)
# initializes TRACKER.md. It does NOT provision a GitHub board, derive domains, or write the
# install receipt — those are /idc:init's agent-driven phases (board provisioning needs live
# gh; domain derivation is a judgment step; the receipt fingerprints the final bytes). This
# helper is the mechanical, idempotent, testable core both /idc:init and the smoke tests use.
#
# Usage: idc_init_scaffold.sh PLUGIN_ROOT REPO_ROOT PROJECT_NAME [BACKEND]
#   BACKEND ∈ {github (default), filesystem}
set -euo pipefail

PLUGIN_ROOT="${1:?PLUGIN_ROOT required}"
REPO_ROOT="${2:?REPO_ROOT required}"
PROJECT_NAME="${3:?PROJECT_NAME required}"
BACKEND="${4:-github}"
T="$PLUGIN_ROOT/templates"

[ -d "$T" ] || { echo "idc-init: templates not found at $T" >&2; exit 2; }
case "$BACKEND" in github|filesystem) ;; *) echo "idc-init: BACKEND must be github|filesystem" >&2; exit 2 ;; esac

cd "$REPO_ROOT"
mkdir -p docs/workflow

# Resolve every governed dest's template source through the shared resolver — the single source of
# truth /idc:update also uses, so the dest->template mapping can never drift between the two.
resolve() { python3 "$PLUGIN_ROOT/scripts/idc_template_for.py" --plugin-root "$PLUGIN_ROOT" "$1"; }

# Root + config files (idempotent: never clobber an operator's file).
[ -f WORKFLOW.md ]                        || cp "$(resolve WORKFLOW.md)" WORKFLOW.md
[ -f WORKFLOW-config.yaml ]               || cp "$(resolve WORKFLOW-config.yaml)" WORKFLOW-config.yaml
[ -f docs/workflow/tracker-config.yaml ]  || cp "$(resolve docs/workflow/tracker-config.yaml)" docs/workflow/tracker-config.yaml
# The transition engine's legal-transition table (v4 Phase 2). Scaffolded into the governed repo so
# it is operator-visible + update-managed; the engine (idc_transition.machine_path_for) prefers this
# copy and falls back to the bundled template pre-scaffold. No {{PROJECT_NAME}} substitution (it is a
# repo-agnostic state machine).
[ -f docs/workflow/workflow-machine.yaml ] || cp "$(resolve docs/workflow/workflow-machine.yaml)" docs/workflow/workflow-machine.yaml

# docs/workflow tree from docs-tree/ (visible entries only; each absent entry resolved + copied).
shopt -s nullglob
for entry in "$T/docs-tree/"*; do
  name="$(basename "$entry")"
  [ -e "docs/workflow/$name" ] || cp -R "$(resolve "docs/workflow/$name")" "docs/workflow/$name"
done
shopt -u nullglob

# Substitute {{PROJECT_NAME}} (portable: temp file, no sed -i flavor split).
# Escape sed replacement metacharacters (\ & |) so any project name substitutes literally.
esc_name="$(printf '%s' "$PROJECT_NAME" | sed -e 's/[\\&|]/\\&/g')"
for f in WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml; do
  [ -f "$f" ] || continue
  tmp="$(mktemp)"; sed "s|{{PROJECT_NAME}}|$esc_name|g" "$f" > "$tmp" && mv "$tmp" "$f"
done

# Select the backend; for filesystem, initialize TRACKER.md.
if [ "$BACKEND" = "filesystem" ]; then
  tmp="$(mktemp)"
  sed "s|^backend: .*|backend: filesystem|" docs/workflow/tracker-config.yaml > "$tmp" \
    && mv "$tmp" docs/workflow/tracker-config.yaml
  python3 "$PLUGIN_ROOT/scripts/idc_tracker_fs.py" --tracker "$REPO_ROOT/TRACKER.md" init
fi

# Gitignore the per-session obligations ledger (.idc-session-state.json, v4 Phase 3): transient
# working state written only by hooks/scripts, never committed. The ledger module owns the filename
# + the ignore rule (single source of truth); the ensure step is idempotent + non-destructive
# (append-only, never clobbers the operator's .gitignore). Runs after tracker-config exists so the
# module's repo-gate sees a governed repo.
python3 "$PLUGIN_ROOT/scripts/hooks/idc_ledger.py" --cwd "$REPO_ROOT" ensure-gitignore

echo "idc-init scaffold complete (backend=$BACKEND, project=$PROJECT_NAME)"
