---
description: IDC Init — scaffold a repo for the v2 IDC pipeline (WORKFLOW.md, config with codebase-derived domains, 5-field board, install receipts)
argument-hint: "[PROJECT_NAME] [--codex] [--pi]"
---

You are running `/idc:init`. Install the IDC v2 workflow into the **current repository**:
scaffold the governance contract from the plugin templates, derive the repo's standing
domains, provision (or link) a GitHub Projects v2 board matching the **five-field** v2
contract, enable the plugin for the project, write an install receipt, and — with
`--codex` — wire the Codex adapter; with `--pi` — wire the Pi runtime adapter.

**Idempotent.** Anything already present is left untouched and reported `skipped-existing`;
never overwrite an operator's `WORKFLOW.md`, `WORKFLOW-config.yaml`, `docs/workflow/`, or
`tracker-config.yaml`. The board contract + destructive single-select caveat live in
`idc:idc-tracker-github`; the templates you copy from are under
`${CLAUDE_PLUGIN_ROOT}/templates/`. Work the phases in order, from the target repo root.

## Phase 0 — Preconditions
1. Confirm the cwd is a git repo (`git rev-parse --show-toplevel`); else stop and tell the
   operator to `cd` in.
2. Decide the backend. Default `github`; if the operator wants zero setup, `filesystem`.
   For `github`, confirm `gh` is authenticated **with the `project` scope**
   (`gh auth status` lists `project`). If missing, stop and tell the operator to run
   `gh auth refresh -h github.com -s project`, then re-run. Do not mutate auth yourself.

## Phase 1 — Derive tokens + domains
- `PROJECT_NAME` — first non-flag word of `$ARGUMENTS`; default `basename "$(git rev-parse --show-toplevel)"`.
- `TRACKER_PROJECT_NUMBER` — set in Phase 4 (github backend only).
- **Domains** — scan the repo's source layout (top-level source dirs, language manifests,
  existing module boundaries) and derive 2–6 standing domains, each a short name + one-line
  brief + primary surfaces. These seed `WORKFLOW-config.yaml::domains` (Phase 3) and the
  board's `Domain` field options (Phase 4). Plan prunes/extends them per run; the Recirculator
  maintains them. Keep them coarse — a domain is a slice a domain-expert reviewer owns.

### Phase 1b — Requirements-doc scan + repo type (brownfield vs greenfield)

Before Phase 3 lays down the tree, run the bounded **read-only** scan that finds any PRD / TRD /
spec / consideration docs the repo already carries and classifies it brownfield vs greenfield:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_brownfield_scan.py" "$(git rev-parse --show-toplevel)"
```
It prints `type:` (brownfield|greenfield), `gating-trd-default:` (on|off), and the found `prd:` /
`trd:` / `considerations:` / `stack:` paths (`<none>` when empty). Capture `type` (→ `REPO_TYPE`)
and `gating-trd-default` (→ `TRD_GATING_DEFAULT`, consumed in Phase 3).

- **HARD CONSTRAINT — confirm what exists, never invent.** The scan is strictly read-only and the
  command must stay that way at this step: **do not author, fabricate, or overwrite any PRD/TRD/spec
  doc here.** When the scan finds existing requirements docs, **report them to the operator** (list
  the found `prd:`/`trd:`/spec paths) and **confirm** how to proceed — offer **scaffold-from-repo**
  (keep + reference the found docs), **from-scratch** (author fresh later, in Think), or a **mix**.
  Authoring a full architecture doc at setup is explicitly out of scope: the PRD-then-TRD
  conversation happens in `/idc:think` (`commands/think.md`), not here.
- **Greenfield** (`type: greenfield`) → init writes **no** starter PRD/spec. Confirm the
  PRD-then-TRD conversation is deferred to the first `/idc:think`, and leave the TRD gate off.
- The scan's `gating-trd-default` encodes the type-aware default Phase 3 writes: **brownfield → TRD
  gate on** (protect an established stack from silent re-architecture), **greenfield → off** (let
  architecture flex). The PRD always gates by default (`gating.prd: on`).

## Phase 2 — Detect-and-skip (idempotency)
Check each target independently, recording `created` / `skipped-existing`:
- `WORKFLOW.md`, `WORKFLOW-config.yaml` at repo root
- `docs/workflow/tracker-config.yaml`
- each entry of `${CLAUDE_PLUGIN_ROOT}/templates/docs-tree/` inside `docs/workflow/`,
  checked individually (a partial tree gets its missing entries filled, so `/idc:doctor`
  converges).
Anything present is left untouched.

## Phase 3 — Scaffold from templates
Run the deterministic scaffold helper. It copies the templates, substitutes
`{{PROJECT_NAME}}`, lays down the lean `docs/workflow/` tree (`pillar-matrices/`,
`code-reviews/`, README), selects the backend, and — for the `filesystem` backend —
initializes `TRACKER.md`. It is idempotent: it never clobbers an existing operator file.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/idc_init_scaffold.sh" \
  "${CLAUDE_PLUGIN_ROOT}" "$(git rev-parse --show-toplevel)" "$PROJECT_NAME" <github|filesystem>
```
Then write the Phase-1 derived domains into `WORKFLOW-config.yaml::domains` (replace the
empty `domains: []` with the list, each `- name: / brief: / surfaces: [...]`).

**Type-aware TRD-gating default.** The scaffolded `WORKFLOW-config.yaml` ships the greenfield
default (`gating.prd: on`, `gating.trd: off`). If Phase 1b classified the repo **brownfield**
(`TRD_GATING_DEFAULT=on`), flip the TRD gate on so an established stack can't be silently
re-architected (the predicate in `scripts/idc_recirculator_layers.py` reads it); greenfield leaves
it off. Rewrite the one `trd:` line under `gating:` — value **and** its inline comment, so the
comment doesn't keep saying "greenfield default: off" next to a `trd: on`:
```bash
if [ "$TRD_GATING_DEFAULT" = "on" ]; then
  tmp="$(mktemp)"
  sed "s|^  trd: off.*|  trd: on     # TRD/spec changes gate (brownfield default: on)|" \
    WORKFLOW-config.yaml > "$tmp" && mv "$tmp" WORKFLOW-config.yaml
fi
```
`gating.prd` stays `on` for both repo types. The operator can toggle either gate anytime.

For the **filesystem** backend the board is now ready (`TRACKER.md` initialized) — skip
Phase 4. For **github**, the `{{TRACKER_PROJECT_NUMBER}}` token stays until Phase 4 fills
it. (The helper does only the mechanical, testable scaffold; domain derivation, board
provisioning, and the receipt are this command's agent-driven phases.)

## Phase 4 — Provision (or link) the board (github backend)
Decide create-vs-link:
- `tracker-config.yaml` already carries a real integer `project_number` → **link**: reuse,
  verify reachable with `gh project view <n> --owner <owner>`.
- Else find an existing board titled `"<PROJECT_NAME> IDC Tracker"` via
  `gh project list --owner <owner> --format json --limit 200` (always pass `--limit`; the
  default 30 can silently truncate and create a duplicate). Otherwise **create**:
  ```bash
  gh project create --owner "$OWNER" --title "$PROJECT_NAME IDC Tracker" --format json
  ```
  Capture `number` (→ `TRACKER_PROJECT_NUMBER`) and the node `id`/`url`. Derive
  `OWNER=$(gh repo view --json owner -q .owner.login)`.

Provision the **five** v2 fields — but **gate every board mutation behind the provenance check
first**. The destructive risk is concentrated in one place (reconciling the built-in single-select
`Status`), so resolve that gate **before** any other mutation: the four added fields and the repo
link all run **only past it**, so a STOP on someone else's populated board leaves it exactly as
found — no fields added, not linked. Single-selects need ≥1 option at creation:

| Field | Type | Options |
|-------|------|---------|
| `Status` | SINGLE_SELECT (reconcile built-in) | `Blocked`, `Todo`, `In Progress`, `Done` |
| `Stage` | SINGLE_SELECT (create) | `Consideration`, `Planning`, `Buildable`, `Recirculation` |
| `Wave` | SINGLE_SELECT (create) | seed `Wave 1` |
| `Phase` | SINGLE_SELECT (create) | seed `Phase 1` |
| `Domain` | SINGLE_SELECT (create) | seed with the Phase-1 derived domain names |

**Provenance gate (run first — it decides whether this board is safe to provision at all).**
Reconcile the built-in `Status` to the four v2 values — **gated by board provenance** (the
option-replacement mutation is destructive: it re-IDs every option and wipes item values;
see `idc:idc-tracker-github`). Get the `Status` field node id + current options from
`gh project field-list <n> --owner "$OWNER" --format json --limit 50`, then take exactly one:
- **Board created this run** → safe: replace the option set with the full desired list
  (`Blocked`, `Todo`, `In Progress`, `Done`) via the `updateProjectV2Field` GraphQL mutation.
- **Linked board, options already exactly those four** → no-op (`skipped-existing`); never
  re-send (same-name replacement still re-IDs + wipes).
- **Linked board, any other option set** → check item count
  (`gh project view <n> --owner "$OWNER" --format json` → `.items.totalCount`); zero → safe,
  proceed; ≥1 → **STOP** before any further mutation — leave the board untouched **and unlinked**
  (no fields added, not linked), record an operator action pointing at the snapshot→mutate→rebuild
  SOP in `idc:idc-tracker-github`.
If the built-in field cannot be updated by your gh version, do not delete it (the API forbids
deleting the built-in `Status`); record an operator action to set the four options in the web UI,
then continue (not a STOP — the board is conformant enough to provision).

**Past the gate — add the other four fields** (`Stage`, `Wave`, `Phase`, `Domain`). **Idempotent —
create only what's missing:** `gh project field-create` does *not* dedupe, so on a linked board that
already carries these a blind re-create would add a second same-named field. Re-read the field list
and skip names that already exist:
```bash
existing=$(gh project field-list <n> --owner "$OWNER" --format json --limit 50 --jq '.fields[].name')
have() { printf '%s\n' "$existing" | grep -qx "$1"; }
have Stage  || gh project field-create <n> --owner "$OWNER" --name "Stage"  --data-type SINGLE_SELECT --single-select-options "Consideration,Planning,Buildable,Recirculation"
have Wave   || gh project field-create <n> --owner "$OWNER" --name "Wave"   --data-type SINGLE_SELECT --single-select-options "Wave 1"
have Phase  || gh project field-create <n> --owner "$OWNER" --name "Phase"  --data-type SINGLE_SELECT --single-select-options "Phase 1"
have Domain || gh project field-create <n> --owner "$OWNER" --name "Domain" --data-type SINGLE_SELECT --single-select-options "<domain1>,<domain2>,..."
```

**Reconcile the `Stage` options — append `Recirculation` to a pre-3.1.0 board (additive,
non-destructive).** `field-create` above seeds a *new* `Stage` field with all four options, but a
board that predates 3.1.0 already has a `Stage` field carrying only the old three — `have Stage`
short-circuited the create, so its option set stays stale and `/idc:recirculate` has nowhere to
file (this is what makes `/idc:doctor` 9c's "run `/idc:init`" remediation real). Append the 4th
option by **re-sending every existing option by node id** plus the new one — **never replace the
option set** (a replace re-IDs every option and wipes existing item values; see
`idc:idc-tracker-github`). The shared helper assembles that exact mutation; it is idempotent
(exit 3 = already present → skip) and fail-closed (exit 2 → leave the board as-is, record an
operator action):
```bash
PID=$(gh project view <n> --owner "$OWNER" --format json --jq '.id')   # PVT_… project node id
# Read the Stage field via GraphQL (not `field-list`): the non-destructive append must re-send each
# existing option's color + description, which `gh project field-list` omits (it returns only id+name).
STAGE_FIELD=$(gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{field(name:"Stage"){... on ProjectV2SingleSelectField{id options{id name color description}}}}}}' -f p="$PID" --jq '.data.node.field')
if [ -n "$STAGE_FIELD" ]; then
  # The helper reads the field id straight out of $STAGE_FIELD; no separate extraction needed.
  MUT=$(printf '%s' "$STAGE_FIELD" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_stage_options.py" append --ensure-option Recirculation --options-json -); RC=$?
  case "$RC" in
    0) gh api graphql -f query="$MUT" >/dev/null ;;   # appended → existing option ids + item values preserved
    3) : ;;                                            # already present → idempotent no-op
    *) echo "Stage reconcile: could not assemble the append (fail-closed) — record an operator action to add the Recirculation option" ;;
  esac
fi
```

**Link the board to this repo** (both paths) so it surfaces on the repo's **Projects tab** and
issue sidebar — a v2 board is owned by the user/org and is invisible from the repo until linked.
This is the **last** post-gate mutation — linking is what publishes the board to the repo, so on
the ≥1-item STOP the board is deliberately left *unlinked*: init couldn't complete the tracker
contract, so it must not publish a half-provisioned, non-conforming board to the repo. The board number is resolved by now regardless of create-vs-link, so one idempotent
step covers both. Check first; skip if already linked (re-link errors on some `gh` versions);
report `linked` / `skipped-existing`:
```bash
OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)
# Repo-rooted probe: is THIS board already among the repo's linked projects?
linked=$(gh api graphql -f query='query($o:String!,$r:String!){repository(owner:$o,name:$r){projectsV2(first:100){nodes{number}}}}' \
  -f o="$OWNER" -f r="$REPO" --jq '.data.repository.projectsV2.nodes[].number' 2>/dev/null)
if printf '%s\n' "$linked" | grep -qx "$TRACKER_PROJECT_NUMBER"; then
  :  # already linked → skipped-existing
else
  gh project link "$TRACKER_PROJECT_NUMBER" --owner "$OWNER" --repo "$OWNER/$REPO"  # → linked
fi
```

Cache the contract: substitute the project number, then write each field's node `id` into
`tracker-config.yaml::field_ids` (`Status`, `Stage`, `Wave`, `Phase`, `Domain`) with precise
edits so the inline comments survive:
```bash
# portable in-place edit: temp file + mv, no BSD/GNU `sed -i` flavor split
tmp="$(mktemp)"
sed -e "s|\"{{TRACKER_PROJECT_NUMBER}}\"|$TRACKER_PROJECT_NUMBER|g" docs/workflow/tracker-config.yaml > "$tmp" \
  && mv "$tmp" docs/workflow/tracker-config.yaml
gh project field-list <n> --owner "$OWNER" --format json --limit 50   # → field node ids
```

## Phase 5 — Enable the plugin for this project
Merge the enablement key into `.claude/settings.json`, preserving every existing key, via
the shipped safe-write helper (same-directory temp file + atomic replace):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_settings_json.py" \
  enable .claude/settings.json idc@idc-workflow
```
If the settings file contains invalid JSON, stop and report the parse error; never replace,
truncate, or drop existing settings. `.claude/settings.json` remains operator-owned — IDC
manages only the `enabledPlugins["idc@idc-workflow"]` key.

## Phase 6 — Codex adapter (only with `--codex`)
If `$ARGUMENTS` contains `--codex`, wire the single v2 Codex runtime adapter:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh" "${CLAUDE_PLUGIN_ROOT}"
```

## Phase 6b — Pi adapter (only with `--pi`)
If `$ARGUMENTS` contains `--pi`, wire the Pi runtime adapter — the launcher symlink (the
adapter skill ships with the plugin, so this is the only install action):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-pi.sh" "${CLAUDE_PLUGIN_ROOT}"
```

## Phase 6c — Offer: enable delete-branch-on-merge (operator consent, surfaced not silent)
The finisher merges each triplet's PR directly (`gh pr merge --squash --delete-branch`) and its
own deterministic finish tail verifies the branch is actually gone — but if a session dies
mid-finish before that tail runs, the branch can survive as debris for the janitor
(`/idc:janitor`) to sweep up later. GitHub's own `deleteBranchOnMerge` repo setting is a
platform-level backstop for that same case: it deletes a PR's source branch on **any** merge,
including one done outside IDC entirely (e.g. a human merging in the web UI). Check the current
setting and, if off, **offer** to flip it — **never flip it silently**:
```bash
gh repo view --json deleteBranchOnMerge --jq .deleteBranchOnMerge 2>/dev/null
```
- Already `true` → `skipped-existing`, no prompt.
- `false` → **ask the operator's consent**: "Enable `deleteBranchOnMerge` on this repo? It
  auto-deletes a PR's branch on any merge — a platform-level backstop for orphaned branches, on
  top of IDC's own cleanup." On explicit **yes**:
  ```bash
  gh repo edit --delete-branch-on-merge
  ```
  → `enabled`. On **no**, or with no operator to ask (a headless/non-interactive run) → leave the
  setting untouched → `declined`; never auto-enable.
- The probe errors (no GitHub remote, or `gh` lacks repo-admin scope) → there is nothing to offer
  consent over, so **do not prompt**; leave the setting untouched and report `n/a (probe failed:
  <reason>)` — a distinct outcome from `declined`, never silently folded into it.

This is the **only** repo-setting mutation `/idc:init` performs, and it never runs without that
consent.

## Phase 7 — Write the install receipt
After Phases 2–6 complete successfully, write `docs/workflow/install-receipt.yaml` — the
manifest that `/idc:doctor` checks and a future uninstall/update consumes. Don't hand-roll the
YAML or compute fingerprints by hand: call the shipped deterministic writer, which sorts by
path, fingerprints each file's final on-disk bytes (after token substitution) with SHA-256,
excludes the receipt itself / `TRACKER.md` / `.claude/settings.json`, and atomic-writes. Pass
exactly the scaffold files Phase 2/3 created or gap-filled, marking the two operator-data files
`--customized` (see the data-loss guard below):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" stamp \
  --repo "$(git rev-parse --show-toplevel)" \
  --out docs/workflow/install-receipt.yaml \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  WORKFLOW.md WORKFLOW-config.yaml \
  docs/workflow/tracker-config.yaml docs/workflow/workflow-machine.yaml docs/workflow/README.md \
  docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep \
  docs/workflow/code-reviews/.gitignore
```
`docs/workflow/workflow-machine.yaml` is the transition engine's legal-transition table (v4 Phase 2),
scaffolded so it is operator-visible + update-managed. It is **pristine** (no operator data written
into it — unlike the two `--customized` files below), so it is stamped plain and `/idc:update`
silently refreshes it from the template like any other pristine scaffold file.
Never add a receipt to `templates/`. The helper omits the receipt itself, `TRACKER.md`
(runtime footprint), and `.claude/settings.json` (operator-owned — IDC manages only its one
enablement key) even if those paths are passed.

**Data-loss guard — stamp operator-data files `customized`.** Two scaffold files get real
operator/board data written into them *after* the template is copied: `WORKFLOW-config.yaml`
(the Phase-1 derived `domains:` list + the type-aware `gating.trd` default) and
`docs/workflow/tracker-config.yaml` (the
`project_number` + board `field_ids` node IDs from Phase 4). Stamped plain `state: stamped`,
`/idc:update` would class them pristine and silently overwrite them from the template —
wiping `domains` back to `[]` and the board wiring back to empty. Stamping them `--customized`
routes them to update's **show-diff-and-ask** instead, so those values are never silently
lost. Pass both flags on every backend (the `filesystem` backend simply has nothing in the
board half yet).

**Gap-fill re-run (idempotency).** `stamp` rewrites the receipt from the paths you pass — it
does **not** append to an existing one. So on a re-run pass the **full** final set of
receipt-listed files, not just the newly-created ones: a file untouched since the last run
re-fingerprints to identical bytes, so its entry is preserved exactly. Carry forward any
`state: customized` entries by reading them out of the current `install-receipt.yaml` first and
re-passing each with `--customized <path>`, so a file the operator kept at `/idc:update`'s
diff-and-ask is never silently re-stamped. If nothing was created or changed, the rewritten
receipt is byte-identical — report `skipped-existing`.

## Phase 8 — Summary
Print a table of every target (`created` / `skipped-existing`), the receipt status, the
board number + URL with the repo-link outcome (`linked` / `skipped-existing`) for github, or
`TRACKER.md` (filesystem), whether the Codex adapter was installed, and the
`deleteBranchOnMerge` outcome (`enabled` / `declined` / `skipped-existing` / `n/a`). End by
suggesting `/idc:doctor`, and — if any scope/probe was skipped — name exactly what remains.

| Item | Status |
|------|--------|
