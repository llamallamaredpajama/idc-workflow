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
  checked individually **per file, not per directory** (a partial tree gets its missing entries
  filled, so `/idc:doctor` converges).
Anything present is left untouched.

Per-file is the granularity that matters because the Phase 7 receipt stamps each path **by name**: a
directory that exists but is missing its hidden `.gitkeep` would otherwise abort the run at the
receipt (`cannot stamp missing file`). The scaffold helper converges at that granularity.

## Phase 3 — Scaffold from templates
Run the deterministic scaffold helper. It copies the templates, substitutes
`{{PROJECT_NAME}}`, lays down the lean `docs/workflow/` tree (`pillar-matrices/`,
`code-reviews/`, `intakes/`, README), selects the backend, and — for the `filesystem` backend —
initializes `TRACKER.md`. It is idempotent: it never clobbers an existing operator file.
`intakes/` is the durable home for the manifests `/idc:intake` compiles; it ships as a tracked
`.gitkeep` so an empty intake home survives a fresh clone, and it is **not** gitignored — a manifest
is a durable record of what a foreign artifact compiled to, like a pillar matrix.
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

### Phase 3b — Open this command's lifecycle record (init registers itself)

Now that `docs/workflow/tracker-config.yaml` exists, the repo is **governed** — so open init's
lifecycle record here. The command entry gate **deferred** init's registration (at expansion the repo
was not yet governed and had no ledger), so init calls `start` itself, then verifies it:
```bash
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" start \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command init \
  --plugin-root "${CLAUDE_PLUGIN_ROOT}" --args "$ARGUMENTS" --source user
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```
A stale runtime is refused here too (`start` exits 4) — do not scaffold further on stale logic; run
`/reload-plugins`. From here init owes an honest closeout (Phase 8).

## Phase 4 — Provision (or link) the board (github backend)
Decide create-vs-link:
- `tracker-config.yaml` already carries a real integer `project_number` → **link**: reuse,
  assign it to `TRACKER_PROJECT_NUMBER`, set `PROJECT_ACTION=configured`, and verify it is reachable
  with `gh project view <n> --owner <owner>`.
- Otherwise use the GitHub tracker adapter's exact-title create/reuse door. It lists all boards
  (with an explicit 200-board limit), refuses duplicate title matches, creates only when none exists,
  and positively reads the selected board back:
  ```bash
  PROJECT_RECEIPT=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" ensure-project \
    --repo "$PWD" --owner "$OWNER" --title "$PROJECT_NAME IDC Tracker") || exit $?
  TRACKER_PROJECT_NUMBER=$(printf '%s' "$PROJECT_RECEIPT" | jq -er '.number') || exit $?
  PROJECT_ACTION=$(printf '%s' "$PROJECT_RECEIPT" | jq -er '.action') || exit $?
  ```
  Keep the receipt's `number`, node `id`, `url`, and `action` (`created` or
  `skipped-existing`). Derive `OWNER=$(gh repo view --json owner -q .owner.login)`.

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
see `idc:idc-tracker-github`). Run the adapter door before every other board mutation:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" reconcile-status \
  --repo "$PWD" --owner "$OWNER" --project "$TRACKER_PROJECT_NUMBER" || exit $?
```
The helper reads the current field and item count itself; it accepts no caller-supplied "created"
bypass. It then takes exactly one path:
- **Board created this run** (therefore still observed empty) → safe: replace the option set with the full desired list
  (`Blocked`, `Todo`, `In Progress`, `Done`) via the `updateProjectV2Field` GraphQL mutation.
- **Linked board, options already exactly those four** → no-op (`skipped-existing`); never
  re-send (same-name replacement still re-IDs + wipes).
- **Linked board, any other option set** → check item count
  (`gh project view <n> --owner "$OWNER" --format json` → `.items.totalCount`); zero → safe,
  proceed; ≥1 → **STOP** before any further mutation — leave the board untouched **and unlinked**
  (no fields added, not linked), record an operator action pointing at the snapshot→mutate→rebuild
  SOP in `idc:idc-tracker-github`.
After any update, the helper re-reads the options and accepts only the exact four-option result.
If the field cannot be updated or read back, **STOP** and record an operator action; never delete
the built-in `Status` or bypass the helper with a raw GraphQL mutation.

**Past the gate — add the other four fields** (`Stage`, `Wave`, `Phase`, `Domain`). **Idempotent —
create only what's missing.** The adapter refuses duplicate same-named fields and positively reads
every create back. Repeat `--option "<domain>"` once for each Phase-1 derived domain:
```bash
BOARD_DOOR="${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py"
python3 "$BOARD_DOOR" ensure-field --repo "$PWD" --owner "$OWNER" --project "$TRACKER_PROJECT_NUMBER" \
  --name Stage --option Consideration --option Planning --option Buildable --option Recirculation || exit $?
python3 "$BOARD_DOOR" ensure-field --repo "$PWD" --owner "$OWNER" --project "$TRACKER_PROJECT_NUMBER" \
  --name Wave --option "Wave 1" || exit $?
python3 "$BOARD_DOOR" ensure-field --repo "$PWD" --owner "$OWNER" --project "$TRACKER_PROJECT_NUMBER" \
  --name Phase --option "Phase 1" || exit $?
python3 "$BOARD_DOOR" ensure-field --repo "$PWD" --owner "$OWNER" --project "$TRACKER_PROJECT_NUMBER" \
  --name Domain --option "<domain1>" --option "<domain2>" || exit $?
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
# Read the Stage field via GraphQL (a read query — ALLOWED by the mutation interlock; not `field-list`):
# the non-destructive append must re-send each existing option's color + description, which
# `gh project field-list` omits (it returns only id+name).
STAGE_FIELD=$(gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{field(name:"Stage"){... on ProjectV2SingleSelectField{id options{id name color description}}}}}}' -f p="$PID" --jq '.data.node.field')
if [ -n "$STAGE_FIELD" ]; then
  # APPLY the append through the SANCTIONED PYTHON DOOR — `idc_stage_options.py apply` reads the field
  # id straight out of $STAGE_FIELD, assembles AND runs the `updateProjectV2Field` mutation via its OWN
  # gh subprocess. Do NOT run the mutation with a raw `gh api graphql -f query="$MUT"`: the interlock
  # hard-DENIES a raw GraphQL mutation during this active /idc:init command.
  printf '%s' "$STAGE_FIELD" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_stage_options.py" apply --ensure-option Recirculation --options-json - --repo "$(pwd)"; RC=$?
  case "$RC" in
    0) : ;;   # appended → existing option ids + item values preserved
    3) : ;;   # already present → idempotent no-op
    *) echo "Stage reconcile: could not apply the append (fail-closed) — record an operator action to add the Recirculation option" ;;
  esac
fi
```

**Link the board to this repo** (both paths) so it surfaces on the repo's **Projects tab** and
issue sidebar — a v2 board is owned by the user/org and is invisible from the repo until linked.
This is the **last** post-gate mutation — linking is what publishes the board to the repo, so on
the ≥1-item STOP the board is deliberately left *unlinked*: init couldn't complete the tracker
contract, so it must not publish a half-provisioned, non-conforming board to the repo. The board number is resolved by now regardless of create-vs-link, so one idempotent
step covers both. Check first; skip if already linked (re-link errors on some `gh` versions);
report `linked` / `skipped-existing`. The adapter verifies the project, reads the repo's links,
writes only when absent, and reads the link back:
```bash
OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" ensure-link \
  --repo "$PWD" --owner "$OWNER" --project "$TRACKER_PROJECT_NUMBER" \
  --repository "$OWNER/$REPO" || exit $?
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
`--customized` (see the data-loss guard below). The receipt is v2: it records `plugin_version`
— the version stamping this repo right now — so a later stale session can be caught before it
runs old logic against a newer repo (see `/idc:update` Phase 0). Resolve the version from the
running plugin's own manifest and pass it explicitly:
```bash
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" stamp \
  --repo "$(git rev-parse --show-toplevel)" \
  --out docs/workflow/install-receipt.yaml \
  --plugin-version "$PLUGIN_VERSION" --written-by idc:init \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  WORKFLOW.md WORKFLOW-config.yaml \
  docs/workflow/tracker-config.yaml docs/workflow/workflow-machine.yaml docs/workflow/README.md \
  docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep \
  docs/workflow/code-reviews/.gitignore docs/workflow/intakes/.gitkeep
```
Pass **every** file the scaffold laid down: a governed file the stamp list omits is left `unrecorded`
(`idc_receipt_check.py verify --json`), which is the migration gap `/idc:update` §B then has to
clean up after — at install time it is simply a bug. `docs/workflow/intakes/.gitkeep` is the durable
home `/idc:intake` writes its manifests into; the **keepfile is the only intake path the receipt ever
lists**. A compiled intake manifest is a work product, not scaffold IDC installed, so it is never
stamped — which is exactly what keeps `/idc:uninstall` (whose removal manifest *is* this receipt)
from deleting an operator's manifest as if it were pristine scaffold.
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

## Closeout — finish the init lifecycle record

Close the record opened in Phase 3b with a validated terminal status (the Stop closeout gate refuses a
walk-away from an open command). Init is a **scaffold/setup** command — no pipeline oracle handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command init \
  --status <complete|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — the tracker config, the scaffold, the plugin enablement, and a **v2 install
  receipt** all verify. The closeout **re-derives** this from durable state — it parses the install
  receipt (must be `receipt_version: 2`), **RUNS the real fingerprint verification** (every stamped
  file's current bytes match its recorded SHA-256 — a modified or missing scaffold file fails closed,
  not just a syntax parse), confirms the governance anchor (`docs/workflow/tracker-config.yaml`) exists,
  and confirms the settings file has the IDC plugin enabled — **never three caller `"ok"` strings**.
  Evidence refs: `refs:{}` (optionally `receipt:"<repo-rel receipt path>"` /
  `settings:"<repo-rel settings path>"` if non-default).
- **`blocked_external`** — a deterministic init helper failure the validator can RE-DERIVE by a
  read-only re-run: cite `idc_receipt_check.py` (the receipt fingerprint re-run must actually find drift
  — an invalid receipt or a modified/missing stamped file): `blocker:{helper:"idc_receipt_check.py",
  exit (nonzero), diagnostic}`. A caller exit/diagnostic alone is never accepted.
