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

# ── The honest-claim precondition (spec §2.1) ─────────────────────────────────────────────────────
# `controlled` and `app-locked` are HARD pathway-security claims: they promise that supported runtime
# hooks deny off-path mutations AND that a required deterministic GitHub check plus repository rules
# block off-path integration. A filesystem-backed repo has no integration boundary to enforce, so it
# can never honor that promise — it "remains useful for hermetic tests and local demonstrations" but
# "MUST NOT claim hard pathway security". Refuse the dishonest combination here, at the door that
# creates governed repos, instead of letting a repo advertise protection it does not have. Read the
# posture through the SHIPPED parser so this can never drift from what the Path Gate itself sees.
declared_pathway_mode() {
  PYTHONPATH="$PLUGIN_ROOT/scripts" python3 -c \
    'import sys; import idc_path_gate as G; print(G.pathway_mode(sys.argv[1]))' "$1"
}
if [ "$BACKEND" = "filesystem" ] && [ -f WORKFLOW-config.yaml ]; then
  claimed="$(declared_pathway_mode "$REPO_ROOT")"
  case "$claimed" in
    controlled|app-locked)
      echo "idc-init: refusing to scaffold the filesystem backend — WORKFLOW-config.yaml claims pathway_enforcement.mode: $claimed" >&2
      echo "idc-init: the filesystem tracker makes no hard pathway-security claim (spec §2.1); set 'mode: off', or select the github backend." >&2
      exit 2
      ;;
  esac
fi

mkdir -p docs/workflow

# Resolve every governed dest's template source through the shared resolver — the single source of
# truth /idc:update also uses, so the dest->template mapping can never drift between the two.
resolve() { python3 "$PLUGIN_ROOT/scripts/idc_template_for.py" --plugin-root "$PLUGIN_ROOT" "$1"; }

# Root + config files (idempotent: never clobber an operator's file).
[ -f WORKFLOW.md ]                        || cp "$(resolve WORKFLOW.md)" WORKFLOW.md
# Track whether THIS run created the config: the backend-aware pathway default below applies only to
# a config the scaffold itself laid down. A pre-existing WORKFLOW-config.yaml is operator data.
CONFIG_CREATED=no
if [ ! -f WORKFLOW-config.yaml ]; then
  cp "$(resolve WORKFLOW-config.yaml)" WORKFLOW-config.yaml
  CONFIG_CREATED=yes
fi
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

# ── Backend-aware pathway default (spec §2.1 default claim, enabled by §7.9 step 9) ───────────────
# `controlled` is the default security claim for governed GITHUB-backed repositories: the supported
# runtimes deny off-path mutations and the required `idc/pathway-integrity` check plus the repository
# ruleset block off-path integration. That default is only honest now that the integration-enforcement
# surface exists, which is why the flip is the LAST implementation step rather than part of the
# original contract change. The filesystem backend has no integration boundary, so it stays `off`.
#
# The default is applied HERE, in backend-aware code, and NOT by editing templates/WORKFLOW-config.yaml
# — one template serves both backends, so a blanket template edit would hand a filesystem scaffold a
# security claim it cannot honor. It is applied ONLY to a config this run created: a pre-existing
# WORKFLOW-config.yaml is operator data (`always_ask` in the install receipt), so an operator's
# explicit posture survives every re-scaffold and `/idc:init` stays idempotent.
if [ "$CONFIG_CREATED" = "yes" ]; then
  case "$BACKEND" in
    github)     PATHWAY_DEFAULT=controlled ;;
    *)          PATHWAY_DEFAULT=off ;;
  esac
  tmp="$(mktemp)"
  PATHWAY_DEFAULT="$PATHWAY_DEFAULT" python3 - WORKFLOW-config.yaml "$tmp" <<'PY'
import os
import re
import sys

src, dest = sys.argv[1], sys.argv[2]
want = os.environ["PATHWAY_DEFAULT"]

with open(src, encoding="utf-8") as fh:
    lines = fh.readlines()

out, in_block, block_indent, done = [], False, None, False
for raw in lines:
    if done:
        out.append(raw)
        continue
    code = raw.split("#", 1)[0].rstrip()
    stripped = code.strip()
    indent = len(code) - len(code.lstrip()) if stripped else None
    if not in_block:
        if stripped == "pathway_enforcement:":
            in_block, block_indent = True, indent
        out.append(raw)
        continue
    if stripped and indent is not None and indent <= block_indent:
        in_block = False                      # left the stanza without finding `mode:`
        out.append(raw)
        continue
    match = re.match(r"^(\s*)(mode:)(\s*)([^\s#]+)(.*)$", raw.rstrip("\n"))
    if not (match and stripped.startswith("mode:")):
        out.append(raw)
        continue
    lead, key, gap, old, rest = match.groups()
    # Keep any trailing inline comment anchored at its original column.
    comment_col = len(lead) + len(key) + len(gap) + len(old)
    if rest.strip():
        pad = max(1, comment_col + (len(rest) - len(rest.lstrip())) - (comment_col - len(old) + len(want)))
        rest = " " * pad + rest.lstrip()
    newline = "\n" if raw.endswith("\n") else ""
    out.append("%s%s%s%s%s%s" % (lead, key, gap, want, rest, newline))
    done = True

if not done:
    sys.exit("idc-init: could not find pathway_enforcement.mode in WORKFLOW-config.yaml")

with open(dest, "w", encoding="utf-8") as fh:
    fh.write("".join(out))
PY
  mv "$tmp" WORKFLOW-config.yaml
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

# Install/refresh the shared Path Gate git backstops when this scaffold target is a git repo. The hook
# files live in the repository Git dir (common hooks path), not the worktree, so this is the
# deterministic scaffold point that gives every governed git repo the pre-commit/pre-push deny path.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  python3 "$PLUGIN_ROOT/scripts/idc_git_path_gate.py" install-hooks --repo "$REPO_ROOT" --plugin-root "$PLUGIN_ROOT"
fi

echo "idc-init scaffold complete (backend=$BACKEND, project=$PROJECT_NAME)"
