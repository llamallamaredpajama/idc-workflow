---
name: idc-tracker-github
description: 'Use when an IDC tracker operation must read or mutate the GitHub Projects v2 board (the github backend).'
---
# idc-tracker-github

The GitHub Projects v2 backend of the IDC v2 tracker interface (`WORKFLOW.md §3`). It is
dispatched **only** by `idc:idc-tracker-adapter` when
`docs/workflow/tracker-config.yaml::backend = github`; this skill never reads `backend`
and never decides routing. Its op surface mirrors the sibling filesystem backend
`idc:idc-tracker-filesystem` (`scripts/idc_tracker_fs.py`) so callers stay backend-blind.

The board carries exactly **five** custom fields and nothing else: `Status` (single-select:
`Blocked | Todo | In Progress | Done`), `Stage` (single-select:
`Consideration | Planning | Buildable` — the column-grouping field), `Wave` (single-select
`Wave N`), `Phase` (single-select `Phase N`), `Domain` (single-select). Field **node IDs**
are cached in `tracker-config.yaml::field_ids`; option values are resolved **by name at call
time** (never cached). Plus: native blocked-by dependency links, one `attempt:<n>` label
(single-valued), and claim comments. There is no claim-state machine (removed), no lane, no
track, no pillar-trace-key field, and no bookend ceremony — a board item is workable cold by
any outside agent from its body + the plain GitHub API.

Upstream artifacts (considerations, in-flight plans, pillars) ride the board as lightweight
**pointer items**: an issue carrying `Stage = Consideration`/`Planning`, a repo-file
reference, and Phase/Domain — never a copy of canonical content (files stay the source of
truth). Buildable issues carry `Stage = Buildable`, and Build queries `Stage = Buildable`, so
an upstream pointer is never scooped (the glass wall). `Stage` is **additive** — existing
4-field boards keep working until `/idc:init` (or `/idc:doctor`) provisions the field.

## Preamble — resolve config once per op

```bash
CFG=docs/workflow/tracker-config.yaml
# Read the YAML with grep/sed (repo convention — no yq dependency):
PROJ=$(grep -E '^project_number:' "$CFG" | grep -oE '[0-9]+')   # integer
OWNER=$(gh repo view --json owner -q .owner.login)              # project owner (user/org)
fid()  { grep -E "^[[:space:]]+$1:" "$CFG" | head -1 \
           | sed -E 's/^[^:]*:[[:space:]]*"?([A-Za-z0-9_]+)"?.*/\1/'; }   # cached field node id, by name
# Resolve a single-select option id BY NAME at call time (never cached):
optid() { gh project field-list "$PROJ" --owner "$OWNER" --format json \
  | jq -r --arg f "$1" --arg v "$2" \
    '.fields[] | select(.name==$f) | .options[] | select(.name==$v) | .id'; }
# Map an issue number -> its project item id (board membership):
itemid() { gh project item-list "$PROJ" --owner "$OWNER" --format json \
  | jq -r --argjson n "$1" '.items[] | select(.content.number==$n) | .id'; }
```

`PROJ` is the project node id (`PVT_…`) where GraphQL is used; `gh project` subcommands
take the integer `project_number` + `--owner`. Resolve both from config; never hardcode.

## Six core ops (the portable interface)

**createTicket(title, body, type, labels) -> issue#** — create the issue, add it to the
board, then set initial fields via `setField`/`move`. Returns the issue number on stdout.
```bash
URL=$(gh issue create --title "$T" --body "$B" \
        ${TYPE:+--label "type:$TYPE"} ${LABELS:+--label "$LABELS"}) || die_gh
NUM=$(printf '%s\n' "$URL" | grep -oE '[0-9]+$')
gh project item-add "$PROJ" --owner "$OWNER" --url "$URL" || die_gh
printf '%s\n' "$NUM"
```

**setField(ticket, field, value)** — resolve the cached field node id + the option id (by
name) and write the single-select value. Pre-seed the option first if it is new (see
provisioning caveat).
```bash
gh project item-edit --id "$(itemid "$NUM")" --project-id "$PROJ" \
  --field-id "$(fid "$FIELD")" --single-select-option-id "$(optid "$FIELD" "$VALUE")" || die_gh
```

**link(parent, child, kind)** — `kind ∈ {sub, blocks}`.
- `sub` — parent/child grouping via a sub-issue (or `Tracked by` relation):
  `gh sub-issue add --issue "$CHILD" --parent "$PARENT"` (falls back to a `Tracked by:#<parent>`
  body line if sub-issues are unavailable).
- `blocks` — native GitHub **blocked-by** dependency (see below).

**move(ticket, status)** — convenience over `setField` for `Status`:
`setField "$NUM" Status "$STATUS"` (status must be one of the four).

**query(filter) -> [#...]** — list board items and filter by field value(s).
```bash
gh project item-list "$PROJ" --owner "$OWNER" --format json \
  | jq -r --arg s "${STATUS:-}" --arg st "${STAGE:-}" --arg w "${WAVE:-}" \
          --arg p "${PHASE:-}" --arg d "${DOMAIN:-}" '
    .items[]
    | select($s=="" or .status==$s) | select($st=="" or .stage==$st)
    | select($w=="" or .wave==$w) | select($p=="" or .phase==$p)
    | select($d=="" or .domain==$d) | .content.number' || die_gh
```

**comment(ticket, body)** — `gh issue comment "$NUM" --body "$BODY" || die_gh`.

## Blocked-by mechanism (native, with documented fallback)

`blocks` uses the native GitHub **issue dependencies** "blocked by" relation through the REST
API, so the dependency is first-class on the issue and surfaces in the §2 PRD gate chain:
```bash
gh api --method POST \
  "repos/{owner}/{repo}/issues/$CHILD/dependencies/blocked_by" \
  -f blocked_by_issue_number="$PARENT" || blocks_fallback "$CHILD" "$PARENT"
```
**Fallback** (`blocks_fallback`) — if the dependencies endpoint is unavailable (404/501),
record the relation as a tracked `blocks-on:#<parent>` line appended to the child's body and
a `blocks-on:#<parent>` label, so the link is still queryable. The fallback is a documented
degradation of the *link representation only* — it never silently drops the dependency.

## Convenience ops

- **claim(issue, agent)** — `move "$NUM" "In Progress"` + `comment "$NUM" "claimed by $AGENT"`.
  No lock; the Build merge-queue serializes merges.
- **block(issue, by)** — `move "$NUM" Blocked` + `link "$BY" "$NUM" blocks` (native blocked-by).
- **close(issue)** — `move "$NUM" Done` + `gh issue close "$NUM"`. Idempotent: a re-close is a
  no-op (already-`Done` / already-closed exits 0).

## Provisioning caveat (read before any option write)

Board + the four fields are provisioned by `/idc:init`, **not** here — this skill assumes the
board exists and `field_ids` are cached. This skill never mutates the option **set** of a
field: GitHub re-IDs every option when a single-select's option list is replaced, which wipes
existing item values. Adding a new `Wave`/`Phase`/`Domain` option (the only sanctioned option
mutation) is done with snapshot-safe care and **pre-seeded** before a `setField` that needs
it — never inline during the value write.

## Fail-closed posture

`die_gh` is the only error path: on any `gh` exit ≠ 0 or GraphQL error, emit a structured
error (`{"backend":"github","op":"<op>","ticket":"<n>","error":"<gh stderr>"}`) and return
non-zero. Never silently degrade, never invent a value, never swallow a non-zero exit. The
caller (`idc:idc-tracker-adapter`, then the role) decides retry vs. halt.

## Authority boundaries

- **Read + route only** — executes the six tracker ops + the convenience wrappers against an
  existing board. Never decides the backend (the adapter does).
- **Never provisions** the project or its fields (that is `/idc:init`); never mutates a
  field's option set destructively.
- **Never writes canonical docs** (PRD/specs/plans/`WORKFLOW.md`) and never edits
  `tracker-config.yaml` — it only reads `field_ids`/`project_number` from it.
- **Never spawns teammates or durable workers** — it is a synchronous mechanic the caller
  invokes; concurrency is the orchestrator's concern.
