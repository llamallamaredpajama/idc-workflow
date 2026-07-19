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

# docs/workflow tree from docs-tree/ (visible top-level entries only; each absent FILE resolved +
# copied). The gap-fill is per FILE, not per directory: an existing docs/workflow/<dir>/ must still
# receive any template file it is missing. Guarding at directory granularity was a real defect (the
# Task-8 incident e2e, run-t8e2e.txt "Setup findings" 2) — a repo whose docs/workflow/pillar-matrices/
# already existed without its hidden .gitkeep never got the keepfile, while commands/init.md's Phase 7
# stamps that path BY NAME, so /idc:init died at the receipt with "cannot stamp missing file". The
# receipt is a per-file contract, so the scaffold must converge per file. This also makes real
# init.md Phase 2's promise that "a partial tree gets its missing entries filled". Idempotent +
# non-destructive: an existing file is never re-copied, so operator content (a matrix, an intake
# manifest) is untouched.
shopt -s nullglob
for entry in "$T/docs-tree/"*; do
  name="$(basename "$entry")"
  if [ -f "$entry" ]; then
    [ -e "docs/workflow/$name" ] || cp "$(resolve "docs/workflow/$name")" "docs/workflow/$name"
    continue
  fi
  mkdir -p "docs/workflow/$name"
  while IFS= read -r src; do
    rel="${src#"$T/docs-tree/"}"
    dest="docs/workflow/$rel"
    [ -e "$dest" ] || { mkdir -p "$(dirname "$dest")"; cp "$(resolve "$dest")" "$dest"; }
  done < <(find "$entry" -type f)
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

# Gitignore the persisted drain verdict (.idc-drain-verdict.json, v4 Phase 3 Stage E2): the same
# transient per-session sidecar treatment as the ledger. The drain writes it each pass so the Stop
# fixpoint gate can read the github board conjunct locally (zero GraphQL on the stop path); it is
# working state, never committed. Module owns the filename + ignore rule; idempotent + append-only.
python3 "$PLUGIN_ROOT/scripts/hooks/idc_drain_verdict.py" --cwd "$REPO_ROOT" ensure-gitignore

# Gitignore the persisted per-command diagnostic reports (.idc-<kind>-report.json, Task 6 wave 3): the
# same transient per-session sidecar treatment. /idc:doctor + /idc:janitor write their run's result
# there so the command contract's finish re-reads the run's OWN report instead of a caller integer;
# working state, never committed. Module owns the filename glob + ignore rule; idempotent + append-only.
python3 "$PLUGIN_ROOT/scripts/hooks/idc_command_report.py" --cwd "$REPO_ROOT" ensure-gitignore

# Gitignore the transition-journal advisory-lock sidecar (docs/workflow/transition-journal.ndjson.lock,
# v4 Phase 4 #150): the runtime-only flock token rotation + journal_append create on a stable sidecar so
# the journal↔rotation lock survives os.replace — working state, never committed. The janitor owns the
# lock-path convention + ignore rule (single source); idempotent + append-only, same as the ledger.
python3 "$PLUGIN_ROOT/scripts/idc_git_janitor.py" --repo "$REPO_ROOT" --ensure-gitignore

# Gitignore the durable pause record (.idc-pause-state.json): the local statement that this repo's
# pipeline run was deliberately paused, written only by /idc:pause and cleared by /idc:resume (or the
# next /idc:autorun's preflight). Local run state, never committed — the WORK's durable state stays the
# board. Module owns the filename + ignore rule; idempotent + append-only, same as the ledger.
python3 "$PLUGIN_ROOT/scripts/idc_pause_state.py" --cwd "$REPO_ROOT" ensure-gitignore

echo "idc-init scaffold complete (backend=$BACKEND, project=$PROJECT_NAME)"
