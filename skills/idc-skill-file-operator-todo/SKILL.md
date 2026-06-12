---
name: idc-skill-file-operator-todo
description: 'Use when an IDC role finds an operator-only action that must be recorded instead of performed by the agent.'
---
# IDC Skill — File Operator Todo (`idc:idc-skill-file-operator-todo`)

CUSTOM (cross-role substrate). Flagged primarily by Build but every IDC role files operator-todos when surfacing a manual gate. Codifies the "when in doubt, mark BLOCKING — demotion is cheap, a missed blocker wedges a deploy" classifier from `docs/workflow/CLAUDE.md §Operator-action filing (during builds)` and the atomic-with-surfacing-commit rule from `docs/workflow/operator-todos/README.md`.

**Scope (no-punt ladder, operator decision 2026-06-10):** markdown operator-todo filing is reserved for **operator-console-only actions** (creds, OAuth consents, web-UI rituals, billing, org policy) plus INFO notes. Agent-doable work is NEVER filed here — it routes up the side-issue ladder (canonical: `WORKFLOW.md §7.6`) instead: in-boundary → fixed in the same PR; out-of-boundary agent-doable → the parent orchestrator spawns an `/auto-goal` side-job teammate NOW; agent-doable-but-blocked → GitHub issue labeled `side-job` (open `side-job` issues block phase-close). This skill enforces that boundary via the redirect output below.

## When to invoke

Inside any IDC role at the moment work surfaces an operator-manual action:

- **Build (primary)** — a writer hits a missing OAuth consent; integration-verifier surfaces a fence that needs operator judgment; phase-close adversarial review surfaces an operator-console-only follow-up.
- **Plan** — admission audit surfaces a downstream-sync action requiring operator review, or plan polishing surfaces an operator decision the plan defers (e.g. domain ambiguity, scope-rejection candidate).
- **Sequence** — TRACKER admit surfaces a pending-pillar dependency the operator must clear.
- **Ripple** — change-order surfaces a `MAJOR_GATED` operator approval requirement.

The skill validates the **atomic-with-surfacing-commit rule** — the operator-todo append and the work that surfaced it MUST land in the same commit. The skill writes the append + emits the recommended commit-message suffix; the caller stages both in one commit.

## Input shape

Caller passes a single packet with:

- `action_description` — full prose description of the operator-manual action. Multi-line; markdown allowed. Required.
- `classification_hint` — one of `BLOCKING | side-job | INFO | uncertain`. Use `uncertain` when the caller can't decide; the skill applies the "when in doubt, mark BLOCKING" rule. Required.
- `agent_doable` — `true | false | uncertain`. `true` means an agent could implement this now (no operator console required). Required when `classification_hint == "side-job"`; defaults to `false` otherwise.
- `build_tag` — the per-build tag for the operator-todos filename. Format: `<YYYY-MM-DD-tag>` (e.g. `2026-05-07-phase-9-pillar-3` or `2026-05-07-phase-9-adversarial-followups`). Required for Build; other roles use the role's run_id slug.
- `surfacing_commit_intent` — one-line description of the work that's about to commit (e.g. `fix(auth): add bridge-mode exception for surface X`). The skill validates this is non-empty (atomic-rule precondition) and uses it to compose the recommended commit-message suffix.
- `phase_or_subphase_blocking` — boolean; `true` iff the action would block the active phase / subphase from transitioning. Drives `BLOCKING` classification AND tracker mirror.
- `repo_root` — optional; absolute path. Defaults to `git rev-parse --show-toplevel`.
- `caller_role` — exactly one of `think | plan | sequence | build | ripple` (legacy values `engineer | develop | deconflict` are accepted as aliases for `plan`). Required (drives tracker-mirror eligibility — only Build mirrors to TRACKER §Operator Actions).

## Output shape

A response packet plus side effects on disk:

- **File written / appended:** `docs/workflow/operator-todos/<build_tag>.md`. Atomic-create if file missing; append-with-divider if file exists. (Skipped entirely on the `redirect` branch — agent-doable actions produce NO markdown write; the return packet carries `redirect_action` instead.)
- **Return packet:**

```yaml
operator_todo_path: <abs path>
classification: BLOCKING | side-job | INFO
tracker_mirror_required: true | false
tracker_mirror_text: <one-line if mirror required>
atomic_commit_message_suffix: <text to append to surfacing commit's body>
file_action: created | appended
roll_up_count_delta: 0 | 1   # 1 if classification = side-job and Build is the caller
```

The `atomic_commit_message_suffix` is the literal text the caller appends to its commit body to satisfy the audit trail (e.g. `Operator-todo filed: <path>#<anchor>`). The caller stages BOTH the operator-todo file change AND the surfacing work in one commit; this skill enforces the disk write but never invokes git itself.

## Classification logic

```
if classification_hint == "uncertain":
    if phase_or_subphase_blocking == True:
        classification = "BLOCKING"
    elif action_description mentions: secret rotation / OAuth consent /
        production credential / billing gate / org-policy override:
        classification = "BLOCKING"   # canonical-blocker keywords
    else:
        classification = "BLOCKING"   # "when in doubt, mark BLOCKING" — demotion is cheap
elif classification_hint == "BLOCKING":
    classification = "BLOCKING"
elif classification_hint == "side-job":
    if agent_doable == True:
        # NO file write. No-punt ladder: this work belongs to an agent, not a todo file.
        return redirect:
          redirect_action: "spawn-auto-goal-teammate"   # parent orchestrator spawns it NOW
          fallback_if_blocked: "create GitHub issue labeled side-job (blocks phase-close)"
    elif agent_doable == "uncertain":
        classification = "BLOCKING"   # when in doubt, mark BLOCKING — operator triages
    else:
        classification = "side-job"   # operator-console-only, non-blocking → markdown
elif classification_hint == "INFO":
    classification = "INFO"

tracker_mirror_required = (classification == "BLOCKING" AND caller_role == "build")
roll_up_count_delta = (1 if classification == "side-job" AND caller_role == "build" else 0)
```

The "when in doubt mark BLOCKING" rule is load-bearing — the skill MUST escalate `uncertain` to `BLOCKING` when in doubt, never silently downgrade to `side-job`. The `redirect` branch is equally load-bearing in the other direction: an agent-doable action MUST NOT land in a markdown todo file — the queue of record for agent-doable-but-blocked work is GitHub `side-job` issues, and agent-doable-now work is implemented immediately by a spawned `/auto-goal` teammate (no queue at all).

## File shape (verbatim contract)

The operator-todos file format follows existing convention at `docs/workflow/operator-todos/`:

```markdown
# Operator Todos — <build_tag>

## BLOCKING

### <one-line action title>

- **Filed:** <ISO-8601 timestamp>
- **By:** <caller_role> via idc:idc-skill-file-operator-todo
- **Context:** <surfacing_commit_intent>
- **Action required:** <action_description>
- **Phase/subphase blocked:** <yes | no>

## Side-jobs

### <one-line action title>

- **Filed:** <ISO-8601 timestamp>
- **By:** <caller_role> via idc:idc-skill-file-operator-todo
- **Context:** <surfacing_commit_intent>
- **Action:** <action_description>

## INFO

### <one-line action title>

- **Filed:** <ISO-8601 timestamp>
- **By:** <caller_role>
- **Note:** <action_description>
```

If the file already exists, the skill appends under the matching section (BLOCKING / Side-jobs / INFO) with a `---` divider above the new entry. The skill never rewrites existing entries (atomic-create-or-append; never edit-in-place).

## TRACKER mirror (Build only)

When `tracker_mirror_required: true`, the skill returns `tracker_mirror_text` for Build to stage in the same commit. Format is backend-aware — Build dispatches the mirror through `idc:idc-skill-tracker-adapter` (resolved per `docs/workflow/tracker-config.yaml::backend`):

- **Filesystem backend** — line appended to `TRACKER.md ## Operator Actions BLOCKING` matching the existing shape:

  ```
  - BLOCKING: <one-line action title> — see `docs/workflow/operator-todos/<build_tag>.md#<anchor>`
  ```

- **GitHub backend** — issue title + body matching the labeling convention (label `operator-actions-blocking`, scoped to the active-build run); `tracker_mirror_text` carries both fields so Build can hand them to `gh issue create` (or `idc:idc-skill-tracker-adapter`'s mutation surface) verbatim:

  ```
  title: BLOCKING: <one-line action title>
  body:  see `docs/workflow/operator-todos/<build_tag>.md#<anchor>`
  labels: operator-actions-blocking, build:<build_tag>
  ```

This skill does NOT write to the Tracker substrate directly (GitHub backend: Projects V2 / `gh issue` mutations; filesystem backend: `TRACKER.md` body edits) — that is Build's bookend-write authority via `idc:idc-skill-tracker-adapter`. The skill returns the text; Build stages the Tracker edit + the operator-todo file in the same commit alongside the surfacing work.

For Build's side-jobs roll-up count, this skill returns `roll_up_count_delta: 1`. Build stages the increment in the Tracker substrate via `idc:idc-skill-tracker-adapter` in the same commit — backend-aware:

- **Filesystem backend** — increments the count on the `TRACKER.md §Operator Actions Side-jobs (count: N)` line.
- **GitHub backend** — increments the count via `gh issue edit` on a side-jobs-count tracking issue (or `gh project item-edit` on a count field on the active-build run's project item), per `docs/workflow/tracker-config.yaml::backend`.

## Single-process confirmation

Single-input → single-output: caller hands one packet, skill writes one file (create or append) and returns one response packet. No state across invocations. Each call is independent. The skill never invokes git, never spawns teammates / Task subagents, never reads canonical docs (PRD / arch-spec / master-plan / subphase / pillar plans).

## Banlist

Load-bearing forbiddens:

- **No edit-in-place.** Existing operator-todo entries are never rewritten. Append-with-divider only — preserves the operator's filing history.
- **No silent classification downgrade.** When `classification_hint == "uncertain"`, always escalate to `BLOCKING`. The "when in doubt, mark BLOCKING" rule is load-bearing per `docs/workflow/CLAUDE.md`.
- **No TRACKER writes.** This skill emits the mirror text; the caller (Build only) writes TRACKER. Other roles never mirror to TRACKER §Operator Actions.
- **No git invocation.** The skill writes to disk. The caller stages + commits the file alongside surfacing work. Atomic-with-surfacing-commit is the caller's contract; this skill enforces the file existence but does not enforce the commit.
- **No canonical-doc reads.** The skill is purely a filing primitive; it does NOT read pillar plans / subphase plans / PRD to decide classification. Classification comes from the input packet only.
- **No cross-build aggregation.** Each invocation files to ONE operator-todo file (per `build_tag`); the skill never reads or aggregates other build tags.
- **No `--no-verify`.** The caller must commit through hooks; this skill never bypasses.

## Codex parity note

Codex roles file operator-todos identically — the file format + classification logic + atomic-with-surfacing-commit rule are runtime-portable. Inline-read this SKILL.md from the Codex-runtime sibling adapters to load the contract; the disk-write primitive (Write tool / `cat > file` / `>>` append) is identical across runtimes.

## See also

- `WORKFLOW.md §7.6 Side-issue ladder + operator-action filing` — canonical for the no-punt routing this skill's redirect branch enforces (Build mechanics in `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Side-issue ladder`; mirrored in `idc-plan.md §Side-issue policy`).
- `docs/workflow/CLAUDE.md §Operator-action filing (during builds)` — canonical operator-action filing rule including the "when in doubt, mark BLOCKING" classifier.
- `docs/workflow/operator-todos/README.md` — filing rule + closeout policy (operator-console-only scope).
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Operator-todo filing` — Build-side primary caller.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-phase-close-adversarial-reviewer.md` (BR-4) — phase-close gate routes medium/low + Codex `next_steps` per the ladder; operator-console-only items land here.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-integration-verifier.md` (BR-3) — verifier routes medium-severity findings per the ladder; operator-console-only items land here.
