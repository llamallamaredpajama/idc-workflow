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
# Map an issue number -> its project item id (board membership). Item-id cache (design §C.1, RC4a):
# when the orchestrator has exported IDC_ITEMID_CACHE — a `NUM<TAB>item_id` table emitted once per wave
# by `idc_gh_board.py --emit-idmap` (ONE board read) — resolve from THAT file with NO board read, killing
# the O(waves×board) re-download this function used to do on every field mutation. A cache MISS (number
# not in the table), an unset cache, or an empty cache FILE falls through to the live whole-board read
# below — so a caller that never populated the cache still works, and a stale cache never mutates with a
# blank id (the empty-id die_gh guard in setField still holds on the fallback path):
itemid() { case "$1" in ''|*[!0-9]*) die_gh ;; esac   # $1 is interpolated BARE into the jq / awk below
  if [ -n "${IDC_ITEMID_CACHE:-}" ] && [ -s "${IDC_ITEMID_CACHE:-}" ]; then
    CID="$(awk -F'\t' -v n="$1" '$1==n {print $2; exit}' "$IDC_ITEMID_CACHE")"
    if [ -n "$CID" ]; then printf '%s\n' "$CID"; return; fi   # cache HIT — no board read
  fi
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

**Create AND status transitions route through the transition engine** — the single sanctioned write
door on this backend too:
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py" --backend github --owner "$OWNER" --project "$PROJ" <op>`
(`create-ticket` / `create-pointer` / `recirculate-intake` / `claim` / `move` / `unblock` / `close` /
`dispose` / `link`). It validates machine-legality, verifies the write's read-back, and journals
every op to `docs/workflow/transition-journal.ndjson` — the record the janitor's board↔journal
reconciliation replays. `Done` is reachable ONLY through a guarded terminal op — the verdict-guarded
`close`, or `dispose --disposition {gate-approved|retired|drained}` for the non-verdict terminal
dispositions (each with its own deterministic evidence guard). The raw recipes below are the
*mechanics* that door drives internally — invoke them directly only for non-Status fields and reads,
**never** to mint an item or change a Status by hand.

**createTicket(title, body, type, labels) -> issue#** — dispatch through the engine, which owns the
complete create + board-add + Stage + Status + read-back + journal sequence atomically:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py" --backend github \
  --owner "$OWNER" --project "$PROJ" create-ticket --title "$T" --body "$B"   # -> issue# on stdout
```
(Use `create-pointer` for a Consideration pointer and `recirculate-intake` for a Recirculation inbox
ticket.) The engine drives this raw `gh` mechanic **internally** — it is shown here only so the
backend is legible; a role **never** runs it by hand (a raw `gh issue create` + `gh project item-add`
mints an UNjournaled, possibly Stage-without-Status item and reads as replay divergence):
```bash
# ── engine-internal mechanic — NOT a role-facing recipe; do not run by hand ──
URL=$(gh issue create --title "$T" --body "$B" \
        ${TYPE:+--label "type:$TYPE"} ${LABELS:+--label "$LABELS"}) || die_gh
NUM=$(printf '%s\n' "$URL" | grep -oE '[0-9]+$')
gh project item-add "$PROJ" --owner "$OWNER" --url "$URL" || die_gh
printf '%s\n' "$NUM"
```

**setField(ticket, field, value)** — for the **non-Status fields** (`Stage`/`Wave`/`Phase`/
`Domain`; a `Status` write is a transition — route it through the engine's `move`, which journals
it; a raw Status `item-edit` bypasses the journal and reads as divergence): resolve the cached
field node id, the option id (by name), and the project **node id** (`item-edit --project-id`
needs the node id, NOT the integer `$PROJ`), then write the single-select value. Pre-seed the option first if it is new (see provisioning
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

**move(ticket, status)** — route through the engine:
`idc_transition.py … move --num "$NUM" --to-status "$STATUS"` (machine-legal, read-back-verified,
journaled; status must be one of the four).

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

- **claim(issue, agent)** — `idc_transition.py … claim --num "$NUM" --agent "$AGENT"`
  (Status→In Progress + the claim comment, journaled). No lock; the Build merge-queue serializes
  merges.
- **block(issue, by)** — `idc_transition.py … move --num "$NUM" --to-status Blocked` + the
  **native `link "$BY" "$NUM" blocks` recipe above** (the REST issue-dependencies edge, with its
  documented fallback). The native relation is the ONLY representation the autorun drain's
  dependency gate reads (`idc_autorun_drain._blocked_by_numbers`); the engine's
  `link --kind blocks` records the journaled marker edge but does **not** create it (#158) —
  substituting the engine link here leaves the child looking unblocked, claimable before its
  parent finishes.
- **close(issue)** — a verdict-backed close routes through the engine:
  `idc_transition.py … close --num "$NUM" --verdict <verdict.json> --pr <PR>` — the guarded,
  journaled path to `Done` (verdict must validate, pass, own the item and the PR, with every
  `merge_conditions[]` met); internally it performs the same **atomic**, read-back-verified close
  as the helper below (design §B.2, RC3), which replaced the old two-non-atomic-call recipe
  (`move "$NUM" Done` + `gh issue close`) that could leave a **Done-but-open** issue when the
  second call silently no-op'd (the live board carried 10 such stragglers). The raw helper
  invocation stays the mechanic the engine's `close`/`dispose` drive:
  resolve + guard the item id (cache-aware via `itemid`), then hand
  off to the helper — it sets Status→Done, closes the issue, and **reads back** the state, refusing
  success unless it is `CLOSED`:
  ```bash
  IID="$(itemid "$NUM")"; [ -n "$IID" ] || die_gh      # #NUM not on the board → never "close" a ghost
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_close.py" \
    --owner "$OWNER" --project "$PROJ" --issue "$NUM" --item-id "$IID" || die_gh
  ```
  Fail-closed: any unverified step exits non-zero with a machine-readable `close: <step> failed` line,
  so the caller never records a close that did not land; a rate-limit exits 3 (resumable —
  `rate-limited until <reset>`). Idempotent: re-closing an already-`Done`/closed issue re-verifies and
  exits 0. Passing `--item-id` (the cache-aware `itemid` result) lets the helper skip its own board read.
- **retire(pointer, reason)** — retire a consideration pointer that is fully decomposed + built
  through the engine's guarded terminal door:
  `idc_transition.py … dispose --disposition retired --num "$NUM" --child "$CHILD"` — the engine
  verifies the pointer is a `Consideration` item AND that `$CHILD` (a decomposition child) references
  it via the engine's own link record, then mints `Done`, closes the issue, and journals the
  disposition + evidence. An unlinked pointer is refused (the decomposition record is the receipt).
  Use this op — **never hand-roll the
  retire by capturing `gh project … --format json` into a shell var and re-parsing it with an
  external `jq`**: a raw control char (U+0000–U+001F) in any board title/body trips external jq
  (`parse error: control characters … must be escaped`), yields an **empty** item id, and the
  edit fails on the blank global id `''` (`Could not resolve to a node with the global id of ''`)
  while the loop reports "retired → Done" — the swallowed failure the contract forbids. The engine
  resolves the id **in-process** (cache-aware `itemid`) and guards the empty id, so the failure
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
