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
`Consideration | Planning | Buildable | Recirculation` — the column-grouping field), `Wave` (single-select
`Wave N`), `Phase` (single-select `Phase N`), `Domain` (single-select). Field **node IDs**
are cached in `tracker-config.yaml::field_ids`; option values are resolved **by name at call
time** (never cached). Plus: native blocked-by dependency links, one `attempt:<n>` label
(single-valued), and claim comments. There is no claim-state machine (removed), no lane, no
track, no pillar-trace-key field, and no bookend ceremony — a board item is workable cold by
any outside agent from its body + the plain GitHub API.

Upstream artifacts (considerations, in-flight plans, pillars) ride the board as lightweight
**pointer items**: an issue carrying `Stage = Consideration`/`Planning`, a repo-file
reference, and Phase/Domain — never a copy of canonical content (files stay the source of
truth). Scope discovered mid-build rides as a `Stage = Recirculation` inbox item (drained by
`/idc:recirculate`). Buildable issues carry `Stage = Buildable`, and Build queries
`Stage = Buildable`, so neither an upstream pointer nor a Recirculation item is ever scooped
(the glass wall). `Stage` is **additive** — existing 4-field boards keep working until
`/idc:init` (or `/idc:doctor`) provisions the field. Adding `Recirculation` to a board that
already has a `Stage` field is an **add-one-option migration**: append the new option to the
existing single-select option set (existing options keep their node ids, GitHub appends the
new one) — **never replace the option set**, which re-IDs every option and wipes existing item
values (see the provisioning caveat below).

## Preamble — resolve config once per op

```bash
CFG=docs/workflow/tracker-config.yaml
# Read the YAML with grep/sed (repo convention — no yq dependency):
PROJ=$(grep -E '^project_number:' "$CFG" | grep -oE '[0-9]+')   # integer
OWNER=$(gh repo view --json owner -q .owner.login)              # project owner (user/org)
fid()  { grep -E "^[[:space:]]+$1:" "$CFG" | head -1 \
           | sed -E 's/^[^:]*:[[:space:]]*"?([A-Za-z0-9_]+)"?.*/\1/'; }   # cached field node id, by name
# Read the WHOLE board — EVERY item, EVERY page — via the shared paginating reader. `gh project
# item-list` returns only its 30-item FIRST PAGE (and `--limit N` merely moves the ceiling — the same
# truncation bug at a larger N), so a board grown past 30 items truncates and the build lane,
# considerations, and `itemid` all go blind. `idc_gh_board.py` pages the GraphQL items() connection
# to completion and emits gh's flattened {"items":[...]} shape as ASCII-escaped JSON — so it returns
# ALL items AND a downstream `jq` stays control-char-SAFE (a raw issue-body control char U+0000–U+001F
# arrives over the GraphQL transport already escaped, and is re-emitted escaped, never round-tripped
# through a strict external jq that would reject it — `parse error: control characters … must be
# escaped` — and silently yield an EMPTY id). die_gh fires if the read fails (capture-then-jq, so a
# non-zero read is caught before the filter, never masked by the pipe).
board_json() { python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" --owner "$OWNER" --project "$PROJ"; }
# `optid` reads the field/option set — NOT paginated (a project has a handful of fields) — via gh's
# BUILT-IN `--jq`, same control-char robustness. Precondition (controlled inputs only): these
# resolvers interpolate their args into the jq program, so callers pass ONLY plugin-controlled values
# — issue numbers IDC resolved and the five fixed v2 field/enum names — never board-derived free text.
# `itemid` additionally hard-guards its number argument, so the one bare-interpolated value can never
# carry a raw jq fragment.
# Resolve a single-select option id BY NAME at call time (never cached):
optid() { gh project field-list "$PROJ" --owner "$OWNER" --format json \
  --jq ".fields[] | select(.name==\"$1\") | .options[] | select(.name==\"$2\") | .id"; }
# Map an issue number -> its project item id (board membership), over the WHOLE board:
itemid() { case "$1" in ''|*[!0-9]*) die_gh ;; esac   # $1 is interpolated BARE into the jq below
  IJ="$(board_json)" || die_gh
  printf '%s' "$IJ" | jq -r ".items[] | select(.content.number==$1) | .id"; }
# Resolve the project NODE id (`PVT_…`) — `gh project item-edit --project-id` requires the project's
# GraphQL NODE id, NOT the integer `project_number` (`$PROJ`): passing the integer fails with
# `Could not resolve to a node with the global id of '<n>'`. (item-add / item-list / field-list
# correctly take the integer `$PROJ` + `--owner`; ONLY item-edit's `--project-id` wants the node id.)
projnode() { gh project view "$PROJ" --owner "$OWNER" --format json --jq ".id"; }
```

`PROJ` is the integer `project_number` (resolved at the `PROJ=` line above): `gh project item-add`,
`item-list`, and `field-list` take it together with `--owner`. **`item-edit --project-id` is the
exception** — it needs the project **node id** (`PVT_…`), resolved by `projnode`, NOT the integer
`PROJ` (passing the integer fails with `Could not resolve to a node with the global id of '<n>'`).
The GraphQL board read resolves the same node id internally inside `idc_gh_board.py`. Resolve `PROJ`
and `OWNER` from config; never hardcode.

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

**setField(ticket, field, value)** — resolve the cached field node id, the option id (by name),
and the project **node id** (`item-edit --project-id` needs the node id, NOT the integer `$PROJ`),
then write the single-select value. Pre-seed the option first if it is new (see provisioning
caveat). **Guard every resolved id before the mutation** — an empty item, option, or project-node
id (issue not on the board, no such option, or an unresolvable project) would otherwise reach
`updateProjectV2ItemFieldValue` as `''` (`Could not resolve to a node with the global id of ''`),
so `die_gh` first rather than mutating with a blank id:
```bash
IID="$(itemid "$NUM")";            [ -n "$IID" ] || die_gh     # #NUM not on the board → never mutate with ''
OID="$(optid "$FIELD" "$VALUE")";  [ -n "$OID" ] || die_gh     # no such option for $FIELD=$VALUE → never mutate with ''
PNODE="$(projnode)";               [ -n "$PNODE" ] || die_gh   # project NODE id (PVT_…) — item-edit --project-id needs it, NOT the integer $PROJ
gh project item-edit --id "$IID" --project-id "$PNODE" \
  --field-id "$(fid "$FIELD")" --single-select-option-id "$OID" || die_gh
```

**link(parent, child, kind)** — `kind ∈ {sub, blocks}`.
- `sub` — parent/child grouping via a sub-issue (or `Tracked by` relation):
  `gh sub-issue add --issue "$CHILD" --parent "$PARENT"` (falls back to a `Tracked by:#<parent>`
  body line if sub-issues are unavailable).
- `blocks` — native GitHub **blocked-by** dependency (see below).

**move(ticket, status)** — convenience over `setField` for `Status`:
`setField "$NUM" Status "$STATUS"` (status must be one of the four).

**query(filter) -> [#...]** — list board items and filter by field value(s). Reads the WHOLE board
via the paginating `board_json` helper (so a board past 30 items is never truncated — the exact
defect that blinded the build lane); the controlled filter values interpolate as jq string literals
over `board_json`'s ASCII-escaped output (control-char-safe). Capture-then-`jq` so a failed read
`die_gh`s before the filter rather than being masked by the pipe.
```bash
IJ="$(board_json)" || die_gh
printf '%s' "$IJ" | jq -r "
    .items[]
    | select(\"${STATUS:-}\"==\"\" or .status==\"${STATUS:-}\")
    | select(\"${STAGE:-}\"==\"\" or (.stage // \"Buildable\")==\"${STAGE:-}\")
    | select(\"${WAVE:-}\"==\"\" or .wave==\"${WAVE:-}\")
    | select(\"${PHASE:-}\"==\"\" or .phase==\"${PHASE:-}\")
    | select(\"${DOMAIN:-}\"==\"\" or .domain==\"${DOMAIN:-}\")
    | .content.number"
```
A legacy 4-field board has no `Stage` set, so `.stage` is null; `(.stage // "Buildable")`
reads an absent Stage as `Buildable` — matching the filesystem backend and the additive promise
above (existing boards keep surfacing under `--stage Buildable` with no migration step).

**comment(ticket, body)** — `gh issue comment "$NUM" --body "$BODY" || die_gh`.

## Blocked-by mechanism (native, with documented fallback)

`blocks` uses the native GitHub **issue dependencies** "blocked by" relation through the REST
API, so the dependency is first-class on the issue and surfaces in the §2 requirements gate chain.
The endpoint keys the blocking issue by its **database id** (`issue_id`), **not** its issue number —
passing the number returns a `422`, so resolve the number to the id first:
```bash
PARENT_ID=$(gh api "repos/{owner}/{repo}/issues/$PARENT" --jq '.id')  # number → database id
gh api --method POST \
  "repos/{owner}/{repo}/issues/$CHILD/dependencies/blocked_by" \
  -F issue_id="$PARENT_ID" || blocks_fallback "$CHILD" "$PARENT"
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
- **retire(pointer, reason)** — retire a consideration pointer that is fully decomposed +
  built: `setField "$NUM" Status Done` then `gh issue close "$NUM" --reason completed --comment
  "$REASON" || die_gh`. Use this op (or `setField`/`close` above) — **never hand-roll the
  retire by capturing `gh project … --format json` into a shell var and re-parsing it with an
  external `jq`**: a raw control char (U+0000–U+001F) in any board title/body trips external jq
  (`parse error: control characters … must be escaped`), yields an **empty** item id, and the
  edit fails on the blank global id `''` (`Could not resolve to a node with the global id of ''`)
  while the loop reports "retired → Done" — the swallowed failure the contract forbids. `setField`
  resolves the id **in-process via `itemid` (gh `--jq`)** and guards the empty id, so the failure
  surfaces non-zero instead.
  *Stage on a retired pointer is intentionally left at its last value (`Planning`), not cleared or
  advanced* — clearing was evaluated and rejected as NOT a clean fix: (1) the sibling **filesystem**
  backend's `setField Stage` rejects any non-enum value (`scripts/idc_tracker_fs.py`), so a
  cleared/empty `Stage` is not expressible there — clearing would make `retire` diverge by backend
  and break the adapter's backend-blindness; (2) a cleared `Stage` reads as `Buildable` via the
  `(.stage // "Buildable")` legacy default shared by both backends, so it drops the drain's
  stage-based exclusion (`idc_autorun_drain.py` excludes `Consideration`/`Planning`) — reduced
  defense-in-depth; (3) there is no terminal `Stage` option and adding one is a forbidden destructive
  option-set mutation. The retired pointer is `Status=Done` + **closed**, so it is filtered from
  active board views and no consumer acts on a `Done`+`Planning` item (Build/drain pair `Stage` with
  `Status=Todo`) — leaving `Stage` is the correct, backend-consistent, doubly-guarded terminal state.

## Provisioning caveat (read before any option write)

Board + the four fields are provisioned by `/idc:init`, **not** here — this skill assumes the
board exists and `field_ids` are cached. This skill never mutates the option **set** of a
field: GitHub re-IDs every option when a single-select's option list is replaced, which wipes
existing item values. Adding a new `Wave`/`Phase`/`Domain` option (the only sanctioned option
mutation) is done with snapshot-safe care and **pre-seeded** before a `setField` that needs
it — never inline during the value write.

## Fail-closed posture

`die_gh` is the only error path: on any `gh` exit ≠ 0, GraphQL error, **or an empty resolved
item/option id** (refuse to mutate with a blank global id — see `setField`), it emits a structured
error (`{"backend":"github","op":"<op>","ticket":"<n>","error":"<gh stderr>"}`) and **exits
non-zero, halting the op** (`die_gh() { …; exit 1; }`) — so a mid-recipe guard like
`[ -n "$IID" ] || die_gh` actually stops before the next line rather than falling through. Never
silently degrade, never invent a value, never swallow a non-zero exit. The caller
(`idc:idc-tracker-adapter`, then the role) sees the non-zero exit and decides retry vs. halt.

## Authority boundaries

- **Read + route only** — executes the six tracker ops + the convenience wrappers against an
  existing board. Never decides the backend (the adapter does).
- **Never provisions** the project or its fields (that is `/idc:init`); never mutates a
  field's option set destructively.
- **Never writes canonical docs** (PRD/specs/plans/`WORKFLOW.md`) and never edits
  `tracker-config.yaml` — it only reads `field_ids`/`project_number` from it.
- **Never spawns teammates or durable workers** — it is a synchronous mechanic the caller
  invokes; concurrency is the orchestrator's concern.
