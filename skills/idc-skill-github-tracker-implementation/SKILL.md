---
name: idc-skill-github-tracker-implementation
description: 'Use when an IDC tracker operation must read or mutate the GitHub Projects backed tracker.'
---
# idc:idc-skill-github-tracker-implementation

GitHub Projects V2 backend implementation of the portable Tracker interface. Pairs with `idc:idc-skill-filesystem-tracker-implementation` (filesystem backend) under the dispatch surface `idc:idc-skill-tracker-adapter`. Per `WORKFLOW.md §6.2 Six core operations`, the github backend wires the interface to `gh issue` / `gh project item-*` / GraphQL mutations.

This skill is the surface that `tracker-config.yaml::backend = github` resolves through. The adapter is the entry point; this skill is never called directly from an IDC role — always go through `idc:idc-skill-tracker-adapter` so backend swaps remain transparent.

## When to invoke

- ONLY from inside `idc:idc-skill-tracker-adapter` after the adapter has resolved `<repo_root>/docs/workflow/tracker-config.yaml::backend` to `github`.
- NEVER from inside an IDC role directly (Sequence Wave admission, Build matrix dispatch-check, Engineer §Phase 1 bootstrap, Ripple drift detection, etc.) — those callers go through the adapter so the filesystem⇄github backend flip remains transparent.
- NEVER for ad-hoc gh CLI operations outside the six-method interface — those belong inline to the calling role's authority surface, not this skill.

## Prereq — `gh` auth scope

GitHub Projects V2 GraphQL requires the `project` OAuth scope. Standard `gh auth login` does not request it; the operator must run:

```bash
gh auth refresh -h github.com -s project
gh auth status     # verify "Token scopes: ... project"
```

Without the `project` scope, every dispatch returns the structured fail-closed error `gh_auth_missing_project_scope` and Build halts before any source-code commit (per `WORKFLOW.md §6.8 Fail-closed posture`). The skill does NOT auto-refresh — token mutation is operator-gated.

The skill itself never reads or transmits the gh token; it relies on ambient `gh` CLI auth state per `scripts/CLAUDE.md §Secret-handling rules`.

## Input contract

| Field | Shape |
|-------|-------|
| `repo_root` | absolute path to the IDC-governed repo root (must contain `docs/workflow/tracker-config.yaml`) |
| `operation` | one of the six core ops or three operational ops (table below) |
| `args` | per-operation argument bag (signatures below) |
| `output_path` | optional — present for `export-state` (state.json target) and `flip-to-filesystem` (audit-log target) |

The skill loads `<repo_root>/docs/workflow/tracker-config.yaml` via the project's stdlib YAML reader (`docs/workflow/scripts/pillar_matrix.py::parse_matrix_yaml`) and reads:

- `project_number` — the GitHub Project number (cached at Phase 1 bootstrap; null pre-bootstrap → returns `gh_project_not_bootstrapped`).
- `field_ids` — mapping of `{field_name: graphql_node_id}` for the eight custom fields enumerated in `WORKFLOW.md §6.3 Project schema` (Status / ClaimState / Wave / Phase / Track / Lane / Pillar trace key / Domain). Pre-bootstrap, the scaffolded `tracker-config.yaml` ships the eight keys with empty-string values (an empty map / `[]` is equivalent); any missing or empty node id → returns `gh_field_ids_not_cached`.

## Six core operations

| Operation | Signature | gh CLI / GraphQL implementation |
|-----------|-----------|---------------------------------|
| `createTicket` | `(title, body, type, labels) → ticket_id` | `gh issue create --repo <owner/repo> --title "<title>" --body "<body>" --label <labels>` then `gh project item-add <project_number> --owner <owner> --url <issue_url>`. Returns the GitHub issue number (or project-item node id) as `ticket_id`. |
| `setField` | `(ticket_id, field, value)` | `gh project item-edit --id <project_item_node_id> --field-id <field_ids[field]> --project-id <project_node_id> --<typed_value_flag>`. Allowlisted fields are the eight enumerated in `WORKFLOW.md §6.3 Project schema`: Status / **ClaimState** / Wave / Phase / Track / Lane / Pillar trace key / Domain. ClaimState carries the runtime claim (Build-only writer; enum `Unclaimed \| Claimed \| Running \| RetryQueued \| Released`) separately from Status's queue-state meaning (Sequence-only writer); both must agree at known transitions per §Writer authority matrix. |
| `link` | `(parent_id, child_id, kind ∈ {sub, blocks})` | `kind = sub` → `gh api graphql` mutation `addSubIssue(input: {issueId, subIssueId})`; `kind = blocks` → `gh issue comment <child_id> --body "Blocked by #<parent_id>"` (advisory blocked-by reference per source plan). **Dependency cap: GitHub Projects V2 enforces a 50-item per-issue cap on sub-issues / blocked-by edges** — this skill raises the structured error `gh_dependency_cap_exceeded` BEFORE issuing the gh call when the count would breach 50, so callers see a deterministic refusal rather than a partial commit. |
| `move` | `(ticket_id, status ∈ {Pending, Active, Blocked, Complete})` | `gh project item-edit --id <project_item_node_id> --field-id <field_ids[Status]> --project-id <project_node_id> --single-select-option-id <status_option_id>`. Status transitions are mirrored to issue lifecycle: `Complete` also runs `gh issue close <ticket_id>`; `Active` re-opens via `gh issue reopen <ticket_id>` if the issue was previously closed. |
| `query` | `(filter) → [ticket_id, ...]` | `gh project item-list <project_number> --owner <owner> --format json --limit <N>` then jq-shaped post-filter against the eight custom fields. Returns the list of `ticket_id` values matching the filter. |
| `comment` | `(ticket_id, body)` | `gh issue comment <ticket_id> --body "<body>"`. |

### Implementation notes

- The skill chains the two-step `createTicket` (`gh issue create` → `gh project item-add`) inside an idempotency-key guard so a partial failure between the two calls is recovered by re-running with the same key, not by leaving an issue stranded outside the project. The idempotency key shape + crash-window recovery semantics are admitted by Engineer's §Phase 1.
- `setField` requires both `--field-id` (cached from `tracker-config.yaml::field_ids`) and `--project-id` (the project's GraphQL node id); both come from `gh project view <project_number> --owner <owner> --format json` cached at bootstrap.
- `link(kind=sub)` uses the `addSubIssue` GraphQL mutation explicitly rather than `gh issue` flags — sub-issues are a Projects V2 graph relation, not a v3 REST issue field.
- `move` sets `Status` AND mirrors issue state because the operator's "where am I?" scan reads either surface; mirroring keeps them aligned. ClaimState is mutated via `setField` (Build's bookend-open / fix-loop / bookend-close transitions), NOT through `move` — `move` is the queue-state surface; ClaimState is the runtime-claim surface.
- `query` does NOT cache or paginate beyond the `--limit` flag; callers needing >`--limit` items pass an explicit higher limit. Pagination semantics are admitted by Engineer's §Phase 1.

### Batched admission (Sequence `admit_polished_pillars` waves)

Sequence's admit pass historically issued every write serially — per pillar: `gh issue create` + `gh project item-add` + 5 `setField` calls + `move` ≈ 8 round-trips, ~81 calls for a 10-pillar wave. The batched form is the DEFAULT for wave admission:

1. **Issue creation stays per-pillar** (`gh issue create`, REST/CLI) inside the existing idempotency-key guard — N calls for N pillars.
2. **ONE aliased GraphQL document adds all N issues to the project** — N `addProjectV2ItemById` aliases in a single `gh api graphql` call; collect the returned item node ids per alias.
3. **ONE aliased GraphQL document carries ALL field writes for the wave** — per pillar, 5 `updateProjectV2ItemFieldValue` aliases (Wave / Phase / Track-or-Domain / Lane / Pillar trace key) plus the Status write (`move` semantics) = 6N aliases in one document. Chunk into multiple documents only if the API rejects the document size; chunk by pillar, never by field.
4. **One `export-state` round-trip verifies every admitted `pillar_trace_key`** (Sequence Phase 4 step 1.5 admission verification, unchanged).

A 10-pillar wave runs in ~13-17 calls instead of ~81. Aliased mutations within one document execute serially and are NOT transactional — on partial failure, re-run the same document; every write is a same-value set on the already-landed rows (idempotent), and the idempotency-key guard recovers the create/item-add seam exactly as in the serial form. Mutation results may not feed later mutations in the same document, which is why item-add (step 2) and field writes (step 3) are separate documents.

**Option-add SOP (labels-first + one controlled janitor rebuild).** When an admission needs NEW single-select options (e.g. new `Wave N` values), do NOT interleave option mutation with admission writes. SOP: (a) write the independent label encodings FIRST (`wave:N` / `phase:N` labels survive the wipe); (b) run ONE controlled option-add mutation per the destructive-mutation procedure below; (c) re-fetch option ids; (d) janitor-rebuild field values from the labels in one batched field-write document; (e) verify zero value-less items. Never run an option-add mid-wave without the label snapshot in place.

### Single-select option mutation (safe form)

The GraphQL `updateProjectV2Field(singleSelectOptions: [...])` mutation is **DESTRUCTIVE**: it does NOT append. It replaces the entire option set, **regenerates every option's ID**, and **wipes that field's value on every existing item** in the project. "Match-by-name preserves IDs" is FALSE. (Observed 2026-05-29: adding Wave options 19–26 wiped the Wave value on all 52 existing tracker items.)

Safe procedure for ANY option add/rename on a single-select field:

1. **Snapshot first.** `gh project item-list <project_number> --owner <owner> --format json --limit 200` → save every item's current value for the target field (plus any independent label encoding, e.g. `wave:N` labels, which are NOT project fields and survive the wipe).
2. **Send the FULL desired option list** — every existing option name (with current IDs where the API accepts them) PLUS the new options — never just the additions.
3. **Expect the wipe anyway.** After the mutation, every item's value for that field is gone and every option ID is new. This is the API's behavior, not an error.
4. **Re-fetch option IDs** via `gh project field-list <project_number> --owner <owner> --format json` — all cached IDs for that field (e.g. `tracker-config.yaml` caches) are now stale and MUST be refreshed.
5. **Rebuild item values from the snapshot** (step 1) or from the independent label encoding, via `gh project item-edit ... --single-select-option-id <new-id>` per item.
6. **Verify zero items left value-less** for the field (e.g. `gh project item-list ... | jq '<filter for affected items with null field>'` must be empty) before reporting success.

Fields NOT touched by the mutation keep their option IDs — only the mutated field re-IDs.

## Operational ops

The four operational ops surround the six core ops and ride the same dispatch path:

- **`export-state(--output <state.json>)`** — invokes `gh project item-list <project_number> --owner <owner> --format json` and emits a JSON state file with shape `{pillar_id: status}` (string-keyed dict per `WORKFLOW.md §6.2 Operational ops`). Build's matrix dispatch-check chain consumes this via `pillar_matrix.py::_load_tracker_state`. The skill writes to `output_path` atomically (write to temp, fsync, rename) so partial writes do not corrupt downstream parsers.
- **`acquire-lane-lock(--lane=<lane>, --ticket=<id>, --idempotency-key=<sha>)`** — atomic lane-lock primitive backing the bookend-open transaction. The Ripple admits the FENCE (one-active-per-lane invariant — fence-pinned at `tests/test_arch_claim_state_invariants.py` LANDED LATER by Engineer's §Phase 1); the §Phase admits the ALGORITHM (comment-CAS on a per-lane lane-lock issue, optimistic-locking via field versioning, file-based locking, advisory blocked-by chains, or alternative real-API serialization mechanism). Pre-§Phase-1, this op returns `gh_lane_lock_algorithm_deferred` so callers halt deterministically rather than racing.
- **`flip-to-filesystem(--reason=<text>, --audit-log=<path>)`** — explicit operator-gated fallback for gh-outage scenarios. Mutates `tracker-config.yaml::backend` from `github` to `filesystem`, writes an audit-log entry to the supplied path, and returns control to the caller (which re-invokes the adapter; the adapter then resolves to the filesystem implementation skill). Operator-gated; never auto-invoked.
- **`promote_wave_status(wave=<wave-id>, phase=<phase-tag>)`** — Build's §Phase 4.5 next-wave rollover op. Flips every item in the named wave from `Status=Pending` to `Status=Active`. Implementation procedure:
  1. Run `gh project item-list <project_number> --owner <owner> --format json --limit 200` and filter to items where `Wave == <wave-id>` AND `Phase == <phase-tag>` AND `Status == "Pending"`. (Filter is the same shape `query` accepts; substring containment on the three single-select-field display names.)
  2. For each filtered item, verify the issue's `blocks_on` upstream is fully satisfied — every issue referenced via a `Blocked by #<N>` comment (advisory) or `addSubIssue` graph edge MUST be closed. If any upstream is open → return `no_candidate` with the unsatisfied upstream list (no partial promotion).
  3. Resolve the `Active` option id once via a `gh project field-list <project_number> --owner <owner> --format json --limit 50`-style one-shot index; a repo MAY cache option ids under `tracker-config.yaml::status_option_ids` and that cache is preferred when present, but the shipped template deliberately does NOT store option ids — call-time resolution is the default path.
  4. For each item, issue `gh project item-edit --id <item-node-id> --project-id <project-node-id> --field-id <field_ids[Status]> --single-select-option-id <Active-option-id>`. The op is idempotent — re-running against an already-`Active` item is a same-value `setField` and silently succeeds.
  5. Return `promoted: wave=<wave-id>, items=[<comma-separated ticket_ids>]` on success.

  The `Status` field id resolves from `tracker-config.yaml::field_ids.Status` (cached when `/idc:init` provisions the board). The `Active` option id is project-specific (option ids differ on every board); it MUST be resolved at call-time via `gh project field-list <project_number> --owner <owner>` rather than baked into the skill or this doc.

  Authority anchor: this op exists for one caller (`idc:idc-build` §Phase 4.5). Calls from any other surface fail-closed with `promote_wave_status_unauthorized_caller`. See `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out` for the full scope rule.
- **`promote_next_eligible_wave()`** — universal-scope wave-discovery-and-promote. Implementation procedure:
  1. **Enumerate Pending items.** Run `gh project item-list <project_number> --owner <owner> --format json --limit 200` and filter to items where `Status == "Pending"`. Group by `Wave` field value. Result is a `{wave_id: [items]}` map.
  2. **Sort waves by numeric prefix** (e.g. `Wave 1.2` < `Wave 2.1`). Iterate in sorted order so the lowest-numbered Pending wave is examined first.
  3. **Per candidate wave, run the eligibility check** in this order:
     a. **`blocks_on` upstream check.** For every item in the candidate wave, walk the issue's `Blocked by #<N>` advisory comments and `addSubIssue` graph edges. If any upstream issue is open → record `eligible-blocked` and CONTINUE to the next wave.
     b. **Matrix YAML existence check.** Resolve the wave's `Phase` field value to a tag (e.g. `Phase 12.1` → `phase-12-1`), then check that `<repo_root>/docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml` exists (the canonical matrix path per `WORKFLOW-config.yaml::pillar_matrix`). If missing → record `substrate-missing` and CONTINUE (do NOT promote a wave whose matrix YAML is absent).
     c. **All checks pass** → this is the target wave. Break out of the loop.
  4. **If no eligible wave was found**, return one of:
     - `no_candidate (tracker-exhausted)` — zero Pending items at all (every item is Active or Complete).
     - `no_candidate (eligible-blocked)` — at least one Pending wave exists but every one has unsatisfied upstream.
     - `no_candidate (substrate-missing)` — at least one Pending wave is upstream-clear but the matrix YAML for its phase is missing. Include the missing-YAML path in the recovery hint.
  5. **Promote the target wave.** Resolve the `Active` option id (optional `status_option_ids[Active]` cache preferred when a repo carries one; default path is one-shot `_load_field_option_index` call-time resolution — the shipped template stores no option ids). For each item in the target wave, issue `gh project item-edit --id <item-node-id> --project-id <project-node-id> --field-id <field_ids[Status]> --single-select-option-id <Active-option-id>`. The op is idempotent — same-value `setField` silently succeeds.
  6. Return `promoted: wave=<wave-id>, phase=<phase-tag>, items=[<comma-separated ticket_ids>]` on success.

  The `Active` option id resolution and the `Status` field id source are identical to `promote_wave_status` (cached in `tracker-config.yaml`; resolved at call-time if cache is empty).

  Authority anchor: this op exists for one caller (`idc:idc-build` §Phase 7 autowave loop driver, plus `idc:idc-build` §Phase 4.5 next-wave rollover when invoked from autowave-aware Phase 4.5). Calls from any other surface fail-closed with `promote_next_eligible_wave_unauthorized_caller`. See `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out` for the full scope rule.
- **`complete_claimed_item(issue, claim_handle)`** — atomically marks one wave-completed item Complete after Build's PR merges to main. Inputs: `issue` (one project-item / GitHub issue identifier), `claim_handle` (the lane-lock token Build acquired at bookend-open via `acquire-lane-lock`). Mutations: `Status: Active → Complete`, `ClaimState: → Released`, `Lane: → (idle)`, close GitHub issue. Idempotent. Refuses: no lane lock / PR not merged to main / `Status == Pending`.

  Implementation status: **spec-only (deferred implementation)** — the actual GraphQL invocation lives in the planned future tracker-runtime CLI; this section documents the contract that runtime must honor. Same spec-first / impl-later posture as `acquire-lane-lock` pre-§Phase-1. Pre-runtime, this op returns `gh_complete_claimed_item_runtime_deferred` so callers halt deterministically rather than half-mutating the project board.

  Implementation procedure:

  1. **Pre-flight (verification before any mutation).** All checks below run read-only; the slightest mismatch refuses the call with no project-board side effect.
     a. **Fetch issue state.** Run a single `gh api graphql` read returning `issue.assignees`, `issue.state` (OPEN / CLOSED), and `issue.timelineItems(itemTypes: [CONNECTED_EVENT, CROSS_REFERENCED_EVENT]) { ... ConnectedEvent { source { ... PullRequest { number, merged, mergeCommit { oid } } } } }` (the GraphQL surface for linked PRs — Projects V2 surfaces linked PRs through issue timeline `ConnectedEvent` / `CrossReferencedEvent` nodes, not a top-level `linkedPullRequests` field).
     b. **Fetch project-item field values.** From the same GraphQL response (or a paired `gh project item-list` + jq filter on `id == <project_item_node_id>`), read the item's current `Status`, `ClaimState`, and `Lane` field values.
     c. **Short-circuit: already Complete.** If `Status == "Complete"` AND `ClaimState == "Released"` AND `Lane == "(idle)"` AND `issue.state == "CLOSED"` → return `result.return_value: already_complete` with `gh_command_audit.exit_code: 0`. No mutation issued. Idempotency contract per `idc:idc-skill-tracker-adapter §Operational ops`.
     d. **Refuse: Status is Pending.** If `Status == "Pending"` → return structured error `gh_complete_claimed_item_status_pending` (the op only legitimizes the `Active → Complete` transition; `Pending → Complete` must route through Sequence per `WORKFLOW.md §6.6 Writer authority matrix`).
     e. **Verify lane-lock match.** The `claim_handle` arg MUST match the lane-lock token Build acquired at bookend-open. Per `acquire-lane-lock` (above), the lock-token shape + scheme (comment-CAS on a per-lane lane-lock issue, optimistic-locking via field versioning, or alternative serialization) is admitted by Engineer's §Phase 1; the implementation MUST cite the algorithm that landed there. Pre-§Phase-1, this verification falls back to the same `gh_lane_lock_algorithm_deferred` envelope `acquire-lane-lock` emits — `complete_claimed_item` is fail-closed on the same deferred-algorithm gate. Caller (Build) MUST hold a current lane lock on `issue` before invoking; if the token does not match the `Lane` field's current encoded value → return `gh_complete_claimed_item_lane_lock_mismatch`.
     f. **Verify all linked PRs merged to main.** For each linked PR returned by step (a), check `merged == true` and `mergeCommit.oid` is non-null. Then for each merge-commit SHA, verify `git merge-base --is-ancestor <sha> origin/main` returns exit code 0. (This is a local `git` invocation against the operator's checkout; the gh CLI does not expose a remote equivalent. The skill assumes ambient `repo_root` is a current checkout of the same repository the project board belongs to.) If any linked PR is unmerged, has a null merge commit, or has a merge commit not reachable from `origin/main` → return `gh_complete_claimed_item_pr_not_on_main` with the offending PR list + SHA list in the recovery hint. This is the same main-reachability gate Fix B2 admits at bookend-close (see authorizing plan §Wave B Fix B2); duplicating the check here keeps the op self-contained even if the bookend-close annotation drift occurs. **§6.7 deferral carve-out (Ripple 2026-06-10-fence-deferred-exclusion):** when the issue carries a `deferred_to_phase_close=<phase-tag>` label, the main-reachability refusal is WAIVED — per WORKFLOW.md §6.7, a mid-phase wave whose session PR is deferred to phase-close may pass this check with the recorded annotation. The annotation MUST clear once the SHAs become main-reachable; `tests/test_arch_claim_state_invariants.py::test_closed_items_reachable_from_main`'s stale-annotation arm turns red on any label that outlives its deferral, so the waiver cannot become a permanent bypass.

  2. **Mutation (single GraphQL batch where the API allows).** All three field writes target the same project item and use the same `updateProjectV2ItemFieldValue` mutation shape; a multi-mutation GraphQL document with three aliased mutations + a fourth `closeIssue` mutation is the preferred invocation so the four writes ride one HTTP round-trip and fail-or-commit together at the GraphQL transport layer (GraphQL itself does not provide transactional rollback across mutations; the implementation MUST be idempotent on retry per step 1c).
     a. **`Status → Complete`.** `updateProjectV2ItemFieldValue(input: {projectId, itemId, fieldId: <field_ids[Status]>, value: {singleSelectOptionId: <Complete-option-id>}})`. The `Complete` option id resolves at call-time via one-shot `_load_field_option_index` resolution per the same pattern `promote_wave_status` uses for `Active` (an optional `tracker-config.yaml::status_option_ids[Complete]` cache is honored when a repo carries one; the shipped template stores no option ids).
     b. **`ClaimState → Released`.** `updateProjectV2ItemFieldValue(input: {projectId, itemId, fieldId: <field_ids[ClaimState]>, value: {singleSelectOptionId: <Released-option-id>}})`. ClaimState enum is `Unclaimed | Claimed | Running | RetryQueued | Released` per the `setField` row above; the `Released` option id resolves via the same cached / fallback path.
     c. **`Lane → (idle)`.** `updateProjectV2ItemFieldValue(input: {projectId, itemId, fieldId: <field_ids[Lane]>, value: {singleSelectOptionId: <idle-option-id>}})`. The canonical idle value is the Lane enum option named `(idle)` per the project's Lane schema; implementation MUST resolve the option id at call-time rather than baking it into the skill (option ids change across projects, per the `promote_wave_status` note above).
     d. **Close the GitHub issue.** `closeIssue(input: {issueId: <issue-node-id>, stateReason: COMPLETED})`. This mirrors the `move(status=Complete)` issue-lifecycle alignment documented in the `move` row above — keeping `Status=Complete` and `issue.state=CLOSED` in lockstep so the operator's "where am I?" scan reads consistent state on either surface.

  3. **Audit emission.** On success, emit a single `gh_command_audit` block enumerating the four mutations (or the chained gh-CLI equivalents if the implementation degrades to per-mutation invocations); on failure at any mutation, emit the audit block up to the failing call + the failing call's raw error.

  Authority anchor: this op exists for one caller (`idc:idc-build` §Phase 4.5 and §Phase 7 — Build invokes `complete_claimed_item` per wave-close before `promote_next_eligible_wave`, per authorizing plan §Wave B Fix B1). Calls from any other surface fail-closed with `complete_claimed_item_unauthorized_caller`. Build's admission as a Status writer is narrowly scoped to this op only; Sequence retains `Pending → Active` initial admission, retroactive corrections, and janitor `Active → Complete` for items Build did not claim (per `WORKFLOW.md §6.6 Writer authority matrix` Fix B1 admission). See `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out` for the full scope rule.

## Output contract

On dispatched-operation success, the skill returns the typed result directly:

```yaml
result:
  operation: <core_op | operational_op>
  return_value: <ticket_id (str) | [ticket_id, ...] | unit | state.json path>
  gh_command_audit:
    command: <gh ... shell-quoted>
    exit_code: 0
    stdout_excerpt: <first 200 chars>
```

On failure, the skill returns a structured fail-closed error envelope (no automatic retry):

```yaml
error:
  error_kind: <enum>
  raw_error: <gh stderr or graphql error string>
  retried: false
  recovery_hint: <one-line: "operator runs `gh auth refresh -h github.com -s project`" | "invoke flip-to-filesystem op" | ...>
```

### Error kind enum

| `error_kind` | Trigger | Recovery hint |
|--------------|---------|---------------|
| `gh_auth_missing_project_scope` | `gh auth status` shows no `project` scope | Operator runs `gh auth refresh -h github.com -s project` |
| `gh_project_not_bootstrapped` | `tracker-config.yaml::project_number == null` | Run `scripts/sync_github_tracker.py bootstrap` (Engineer §Phase 1) |
| `gh_field_ids_not_cached` | `tracker-config.yaml::field_ids == []` | Run `scripts/sync_github_tracker.py bootstrap` (Engineer §Phase 1) |
| `gh_dependency_cap_exceeded` | Adding sub-issue / blocked-by would exceed 50 | Surface to the calling role — re-shape the dependency graph |
| `gh_cli_exit_nonzero` | `gh` CLI returned non-zero exit code | Caller decides: continue waiting, or invoke `flip-to-filesystem` |
| `gh_graphql_error` | GraphQL mutation returned an `errors` array | Caller decides: continue waiting, or invoke `flip-to-filesystem` |
| `gh_network_timeout` | gh CLI / GraphQL request timed out | Caller decides: continue waiting, or invoke `flip-to-filesystem` |
| `gh_lane_lock_algorithm_deferred` | `acquire-lane-lock` invoked pre-§Phase-1 | Wait for Engineer §Phase 1 admission |
| `promote_wave_status_unauthorized_caller` | `promote_wave_status` invoked from a surface other than `idc:idc-build` §Phase 4.5 | Surface the call site — only Build's §Phase 4.5 rollover is admitted (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out`) |
| `promote_wave_status_no_candidate` | Target wave has no `Pending` item OR every candidate has an unsatisfied `blocks_on` upstream | Caller (Build) skips rollover and routes `next_role: sequence` per `idc-build-runbook.md §Phase 4.5 Handoff `next_role` matrix` |
| `promote_next_eligible_wave_unauthorized_caller` | `promote_next_eligible_wave` invoked from a surface other than `idc:idc-build` §Phase 7 / §Phase 4.5 | Surface the call site — only Build's autowave loop driver is admitted (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out`) |
| `promote_next_eligible_wave_no_candidate_eligible_blocked` | All Pending waves have unsatisfied `blocks_on` upstream | Caller spawns `idc:idc-role-wave-blocker-diagnostic` per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Phase 7` |
| `promote_next_eligible_wave_no_candidate_substrate_missing` | Upstream-clear Pending wave's phase matrix YAML is missing | Caller spawns `idc:idc-role-wave-blocker-diagnostic` per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Phase 7`; matrix YAML must be authored via Plan/Sequence before autowave can progress |
| `gh_complete_claimed_item_runtime_deferred` | `complete_claimed_item` invoked pre-tracker-runtime-CLI landing | Wait for tracker-runtime CLI admission (authorizing plan §Wave B Fix B1); spec-only until then |
| `gh_complete_claimed_item_status_pending` | `complete_claimed_item` called with `Status == Pending` | Surface to Sequence — `Pending → Complete` is Sequence's admission/janitor authority, not Build's |
| `gh_complete_claimed_item_lane_lock_mismatch` | `claim_handle` arg does not match the `Lane` field's currently-encoded lock token | Build did not acquire (or already released) the lane lock on `issue`; re-run `acquire-lane-lock` if the wave is still in flight, otherwise route to Sequence janitor |
| `gh_complete_claimed_item_pr_not_on_main` | One or more linked PRs unmerged, missing merge-commit, or merge-commit not reachable from `origin/main`, AND no `deferred_to_phase_close=<phase-tag>` label on the issue (step 1f §6.7 carve-out) | Wait for PR merge to `origin/main`, or — for a mid-phase wave whose session PR is deferred to phase-close — apply the `deferred_to_phase_close=<phase-tag>` label per WORKFLOW.md §6.7 (annotation MUST clear at phase-close; fence-guarded) |
| `complete_claimed_item_unauthorized_caller` | `complete_claimed_item` invoked from a surface other than `idc:idc-build` §Phase 4.5 / §Phase 7 | Surface the call site — only Build's per-wave-close path is admitted (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out` Fix B1 carve-out) |

## Fail-closed posture

The skill inherits the fail-closed posture documented at `WORKFLOW.md §6.8 Fail-closed posture`:

1. Implementation failure (gh CLI exit code ≠ 0, GraphQL error, network timeout) → emit a structured failure event to the run ledger with the failing operation + raw error.
2. Refuse dispatch (return non-zero envelope so Build halts before any source-code commit).
3. Surface an operator decision: continue waiting, or invoke `flip-to-filesystem` for gh-outage scenarios.

The fail-closed posture is fence-pinned at `tests/test_arch_tracker_adapter_offline.py` (LANDED LATER by Engineer's §Phase 1).

## Authority boundaries

- Read+invoke-only on the gh side — issues `gh` CLI / GraphQL calls, never mutates `tracker-config.yaml::backend` outside the explicit `flip-to-filesystem` op.
- Never writes to TRACKER.md — that surface is owned by `idc:idc-skill-filesystem-tracker-implementation`.
- Never decides backend selection — the adapter does, reading `tracker-config.yaml::backend`.
- Never spawns teammates.
- Never reads or writes canonical docs (PRD, master architectural spec, master implementation plan, subphase plans, pillar plans).
- Never accepts inline gh tokens / API keys via flags or env vars (per `scripts/CLAUDE.md §Secret-handling rules`); relies on ambient `gh` CLI auth state.

## Citations

- Portable interface spec: `WORKFLOW.md §6 Tracker substrate` (six-method contract, project schema, label namespace, bookend mechanics, fail-closed posture, cutover runbook reference).
- Per-repo backend selector: `docs/workflow/tracker-config.yaml` (P1 — `backend: filesystem`; Engineer §Phase 5 cutover flips to `github`; field_ids cached at Phase 1 bootstrap).
- Project bootstrap helper: `scripts/sync_github_tracker.py` (P1 lands the CLI scaffolding — `bootstrap` / `export-state` / `mirror-blocking-todos` / `mirror-tracker-units`; per-subcommand algorithm semantics deferred to Engineer's §Phase 1 / §Phase 5).
- Adapter dispatch surface: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-tracker-adapter/SKILL.md` (governance-pipeline edit; landed at OR-A1).
- Filesystem implementation: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-filesystem-tracker-implementation/SKILL.md` (renamed from `idc-skill-tracker-wave-queue-edit` at OR-A3). <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- Source plan: `docs/workflow/plans/workflow-changes/2026-05-08-tracker-github-migration-plan.md` (50-item dependency cap, GraphQL schema, `gh auth refresh -s project` prereq, fail-closed posture).
- Ripple change order: `docs/workflow/ripple/2026-05-08-tracker-github-migration-ripple.md`.
- Autowave loop driver source plan: `docs/workflow/ripple/2026-05-15-autowave-carve-out-widening-ripple.md` (NEW — admits `promote_next_eligible_wave` as Build's universal-scope Status write surface).
- `complete_claimed_item` authorizing plan (Wave B, Fix B1) — admits the new op + Build's narrow Status-writer carve-out for `Active → Complete` on Build-claimed items; spec-only / impl-later per IDC contract pattern.
