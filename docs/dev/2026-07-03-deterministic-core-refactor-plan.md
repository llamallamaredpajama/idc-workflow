# IDC v4 — Deterministic-Core Refactor Plan ("the inversion")

**Date:** 2026-07-03 · **Status:** proposed (awaiting operator review) · **Scope:** plugin-wide
governance architecture

**One sentence:** invert IDC's control model — a deterministic core (transition engine + hook
suite + schema contracts + truthful exit codes) performs and enforces every workflow state
transition, while LLMs do only judgment work (think, plan, implement, review) inside
deterministically enforced envelopes.

**Three evidence streams feed this plan** (read them for the full detail):

1. **Incident forensics** — session `394ec6fe` (`/idc:autorun` on mdm-proj, IDC 3.3.0,
   2026-07-03): [`2026-07-03-autorun-394ec6fe-forensics.md`](2026-07-03-autorun-394ec6fe-forensics.md)
2. **Governance inventory** — every governance point in v3.3.0 classified by enforcement
   strength: [`2026-07-03-governance-inventory-v3.3.0.md`](2026-07-03-governance-inventory-v3.3.0.md)
3. **External research** — 11 talks + 3 OSS harness teardowns (July 2026), synthesized in the
   Research Wiki: `wiki/deterministic-agent-harness-engineering-synthesis` (+ 14 source pages,
   domain briefing `digest/agent-harness-engineering`)

---

## 1. The case for inversion

### What the incident proved (forensics, session 394ec6fe)

The run built and merged 8/8 issues correctly — the *judgment* work was fine. The *governance*
work failed in exactly the places where it was voluntary:

- **4 of 5 reviewer nits never became board items.** The lead session collapsed the build lane
  into itself (never spawned `idc:idc-build`, never any finisher), prompted reviewers ad-hoc
  ("your final message IS the verdict — return it as structured text"), and so **zero verdict
  JSONs** were written for PRs #237–#246 — breaking an until-then-consistent audit trail (every
  reviewed PR through #224 has one). With no machine-readable `deferrals[]`, the finisher's
  fail-closed deferral contract had no executor; nits became loose `gh issue create`
  improvisations seconds before their parents closed Done.
- **The deterministic paths that DID run, worked.** The recirc sweep converted both implementer
  discovery markers into proper `Stage=Recirculation` tickets (#251/#252). Janitor preflight ran
  and reported. Exit codes were obeyed all run.
- **The drain's green signal was truthful for one lane and false for the pipe.**
  `idc_autorun_drain.py` verifies only the build-lane conjunct of autorun.md's three-conjunct
  fixpoint; it printed `drain: complete` / exit 0 with 2 tickets sitting in the Recirculation
  inbox, and the LLM rationalized the contract away ("a future `/idc:autorun` drains them").
- **`idc_git_finish.py`: 0 invocations** (hand-rolled scripts instead); `idc_acceptance_check.py`
  ran only `--help`; a reviewer's explicit pre-merge condition was silently converted into a
  follow-up; the usage-window cut killed the recovery recirculator mid-drain with **no
  checkpoint**; and the recovery's hand-written pointers (#255/#256) were created with **empty
  Status**, which blinds the dropped-handoff detector. As of the audit, *no stranded nit has
  become buildable work.*

The forensic bottom line: **"exit codes are the one signal this session demonstrably obeyed."**
Where a deterministic signal existed, the model complied. Where governance was prose, it deviated.

### What the inventory proved (v3.3.0 census)

- **Exactly one harness-automatic enforcement point exists in the entire plugin** — the
  `SessionEnd` sweep hook — and it is cancelled in headless `-p`, the exact mode autorun runs in.
- ~27 governance points are PROMPT+SCRIPT (deterministic *once invoked*; invocation voluntary),
  ~31 are PROMPT-ONLY (pure prose).
- The asymmetry is structural: deterministic helpers guard **reads, validations, and the finish
  tail**; the **mid-pipeline write-side transitions** — filing nits, creating recirc tickets,
  advancing pointers, re-linking paused origins, unblocking gates — are almost all prose. Nits
  strand because no code *files* them; recirculation stalls because no code *performs*
  admit/retire/re-link (validators only check closeouts that presuppose the LLM already acted).

### What the research proved (14/14 sources, no dissent)

- Prose-encoded procedure loses the **march of nines**: at 90% per-step compliance a 10-step
  prompted workflow fails most days. Instructions are the **passive layer** — they cannot sense,
  verify, or enforce.
- Prompt rules **decay across compaction** (~15 context rebuilds on a long task); hook-injected
  checks re-fire every time. More governance prose makes compliance *worse* (measured:
  auto-generated AGENTS.md files reduce task completion).
- The harness, not the model, is decisive (same model: 95% vs 42% across harnesses). Long-horizon
  liveness must be code (Claude Code left alone renounces a goal every ~9–10h).
- The consensus architecture, stated near-identically by an XState creator, OpenAI/Stripe/
  Anthropic practitioners, the Databricks CTO, and three codebases: **programs call LLMs; code
  owns every transition; the model fills schema-validated judgment slots; humans hold a few
  parked authority gates.** Mature systems (Omnigent, Archon) that still keep sequencing in
  prompts fence it with DENY-until-compliant interlocks — enforcement they do NOT leave to prose.

### Answering the "50/50 think/script" question

The right split is **by responsibility type, not percentage**: 100% of state transitions become
code; ~0% of judgment becomes code. In line-count terms IDC may well land near 50/50, but the
load-bearing rule is: *an LLM is never the executor of a workflow transition; it proposes, code
disposes.* v1's mistake was enforcing via MORE prompts (rails made of prose); v3's mistake was
removing rails for governance too. v4's rails are made of code, cost zero model attention, and
leave judgment fully agentic.

---

## 2. Design principles (v4)

- **P1 — Code transitions, LLM judgment, human authority.** Every board/git/PR state transition
  is performed by a deterministic component. LLMs decide *what things mean* (verdicts, plans,
  code); humans decide *consequences* (scope admission, prod deploy) at parked gates.
- **P2 — Schema or it didn't happen.** Every machine-consumed LLM hand-back (verdict, closeout,
  plan handoff, finish report) is schema-validated fail-closed, with bounded re-ask and visible
  degradation. Free text never drives state.
- **P3 — Enforce at tool boundaries.** Hooks are the transport: PreToolUse interlocks
  (deny-until-compliant, with the deny message naming the exact remediation), PostToolUse
  side-band actions (run governance scripts after the event, outside the model's token stream),
  Stop/SubagentStop obligation gates (bounded, anti-nag).
- **P4 — Fail-closed before the act, fail-open after.** Pre-action gates that error → deny.
  Post-hoc observers that error → warn and continue. Defined once, shared by all gates.
- **P5 — Receipts before transitions.** Done/close/merge require machine-checkable evidence
  artifacts. Narrow the API so skipping is unrepresentable: `close(item, verdict_artifact)`, not
  `close(item)` + an instruction.
- **P6 — Truthful signals.** A green exit code must mean the WHOLE contract holds (the session
  obeyed exit codes; it was the drain's partial `complete` that lied). Every deterministic
  checker reports all conjuncts it is responsible for, and "indeterminate" is never "clean."
- **P7 — Prose carries knowledge, never control flow.** After a rule is enforced in code, its
  imperative prose is deleted or demoted to advisory context (ablation-tested). Thin routers +
  just-in-time injection beat monolithic governance files.
- **P8 — Every governance miss is a harness bug.** The fix for a skipped step is a new
  gate/check/eval — never another paragraph. Each incident adds a governance eval that would have
  caught it (red-when-broken).

---

## 3. Target architecture

Seven components. Existing v3.3.0 assets are reused everywhere — this is a completion of the
trajectory (sweep, drain, finish tail, verdict checker, closeout validator all survive), not a
rewrite.

### 3.1 The transition engine — one door to the board

`scripts/idc_transition.py` becomes the **only sanctioned write path** to tracker state, wrapping
the existing backends (`idc_gh_board.py` mutations, `idc_tracker_fs.py`) behind typed operations:

```
create-ticket | create-pointer | claim | move | close | retire | recirculate-intake | link | unblock
```

- **Legal-transition table as data**: `templates/workflow-machine.yaml` (scaffolded into governed
  repos) declares states (`Stage`×`Status`), events, and **guards** — the receipts each
  transition requires (e.g. `close` requires: validated verdict artifact for the linked PR +
  every minor/nit/deferral in it resolved-or-routed + PR merged). Illegal transitions error;
  guards evaluate against artifacts on disk/board, not prose claims.
- **Atomic + verified + normalized**: single op per call, read-back verification (extends
  `idc_gh_close.py` semantics to all ops), atomic discard on validation failure, post-op
  invariant normalization (never Stage without Status — the #255/#256 bug class dies here).
- **Journaled**: every op appends one line to `docs/workflow/transition-journal.ndjson`
  (event-sourced audit; §3.5).
- Fields like `Wave`/`Phase`/`Domain` set only through ops whose caller role is allowed to
  (write-authority boundaries move from prose into the op table).

### 3.2 The hook suite — enforcement transport

`hooks/hooks.json` grows from 1 registration to ~7 (all `command` hooks; auto-discovered —
**do not** also list them in plugin.json, the 3.1.1 duplicate-hooks lesson). Hook scripts live in
`scripts/hooks/`, are repo-gated (no-op outside IDC-governed repos, same guard as the existing
wrapper), and share the P4 fail-mode helper.

| Event | Gate | Forensic drop point it kills |
|---|---|---|
| **SubagentStop** (matcher: review agents) | A validated verdict JSON for the reviewed PR must exist at the canonical path (`docs/workflow/code-reviews/`), passing `idc_review_verdict_check.py`; else block stop with the exact missing-artifact message (bounded, N=3, then loud fail). On success, **the hook itself runs the filer** (§3.3). | A, B (nits leave reviewer as prose) |
| **SubagentStop** (matcher: recirculator) | Valid closeout (`idc_recirc_closeout.py`) or the hook stamps each still-open inbox ticket with a resume-checkpoint comment (branch, PR#, dispositions so far). | F (mid-drain truncation loses state) |
| **PreToolUse** (Bash matcher: `gh pr merge`, `gh issue close`, `gh api …state=closed`, `gh project item-edit/item-add`, GraphQL board mutations) | Deny unless the transition engine pre-authorized this terminal action (guard receipts present). Deny message names the exact `idc_transition.py`/`idc_git_finish.py` command to run instead. Raw board mutations outside the engine: always deny (warn-only during rollout, §6). | C (close-with-unrouted-nits), D (loose improvisations), plus the whole "hand-rolled finish" class |
| **PostToolUse** (Bash matcher: `git commit`) | Run board-coherence sync: linked item claimed/In-Progress, branch↔item linkage recorded; auto-repair or inject corrective context. Side-band, zero tokens. | claim/status drift |
| **PostToolUse** (Bash matcher: `gh issue create`/REST issue POST) | If the new issue isn't board-added with Stage+Status within the same command, inject the exact remediation (or auto-add via the engine). | D |
| **Stop** (autorun/build orchestrator sessions) | The fixpoint gate: block stop while `drain --fixpoint` reports pending conjuncts (recirc inbox, unplanned admitted considerations, mid-finish items), bounded reminders then loud fail with board annotation. Reads the obligations ledger (§3.4). | E (exit with non-empty inbox) |
| **TeammateIdle** | Synthesize completion from worktree/branch/PR state when a teammate goes idle without a report (exactly what the lead did by hand at L591–598). | H (phantom-idle implementer) |
| **SessionEnd** (existing sweep) | Unchanged — belt-and-braces detective. | — |

**Spike required first** (Phase 1 step 0): verify which hook events fire in headless `-p` and in
subagent contexts on current Claude Code (docs + our own memory say PermissionRequest doesn't
fire in `-p` and SessionEnd is cancelled; PreToolUse/PostToolUse/Stop/SubagentStop are expected
to fire — prove it with a disposable hook that touches a marker file, before building on them).

### 3.3 The verdict→filer pipeline (kills symptom 1 end-to-end)

- Review agents keep exactly one output contract: **write the verdict JSON to the canonical
  path** (already specified; now enforced by the SubagentStop gate). Their prompts LOSE all
  tracker instructions.
- New `scripts/idc_file_findings.py` (the "filer"): consumes a validated verdict, and for every
  `minor`/`nit` finding and every `deferrals[]` entry, **creates the board ticket itself** via the
  transition engine — `Stage=Recirculation`, `Status=Todo`, provenance label + origin line +
  `idc-recirc-source` dedupe key (idempotent re-runs), `blocks_goal:true` deferrals get the
  dependency link that blocks parent Done. Fired by the SubagentStop hook — not by instruction.
- The finisher's job shrinks to judgment (drive findings to green, `/simplify`) — the routing of
  surviving findings is code. `idc_git_finish.py` gains a `--require-routed-findings` guard so
  the finish tail refuses to merge/close while the verdict's findings are unrouted (P5 receipt).

### 3.4 Truthful loop signals + the obligations ledger

- `idc_autorun_drain.py` verifies **all three fixpoint conjuncts**: build lane drained,
  `Stage=Recirculation ∧ Status=Todo` inbox empty, no admitted-but-unplanned considerations.
  Output gains `recirc_inbox: N` / `unplanned_considerations: M`; non-empty ⇒
  `drain: recirc-pending` with a distinct non-zero exit. autorun.md already binds the LLM to
  treat non-zero as not-complete — now the signal is truthful (P6), and the Stop gate (§3.2)
  backstops the prose.
- **Obligations ledger**: a per-session state file (`.idc-session-state.json` in the workspace,
  written only by hooks/scripts) recording taints: `unfiled_findings`, `mid_finish:<item>`,
  `recirc_checkpoint:<ticket>`. Stop/SubagentStop gates read it; hooks clear taints when the
  deterministic action completes. This is Omnigent's stateful-policy pattern with file-backed
  labels.

### 3.5 Event journal + reconciliation

- The transition engine appends every op (who/what/when/guard-evidence hash) to
  `docs/workflow/transition-journal.ndjson`. The journal is the audit spine: `idc_git_janitor.py`
  and doctor reconcile **board ↔ journal ↔ git** (today they reconcile board ↔ git only);
  autorun resume and forensics read the journal instead of transcript archaeology. Rotation:
  janitor archives closed-out segments.

### 3.6 Governance evals as a release gate

- New smoke lane `tests/smoke/governance/`: seeded-board scenarios with **rule-based judges
  asserting post-state**, e.g. "review verdict with 3 nits ⇒ 3 Recirculation items exist,
  idempotent on re-run"; "drain with non-empty inbox ⇒ non-zero exit"; "close without verdict ⇒
  denied"; "recirculator killed mid-drain ⇒ tickets carry resume checkpoints." Each is
  red-when-broken (delete the enforcing line, watch it fail) per the existing testing doctrine,
  and `run-all.sh` + the release checklist gate on it. Every future governance incident adds a
  scenario (P8).

### 3.7 Prose demotion (after enforcement exists)

- Sweep `commands/ agents/ skills/` for imperative control-flow prose now enforced by code;
  delete or demote to short advisory pointers ("transitions are performed by the engine; you will
  be blocked if you bypass it"). Keep judgment knowledge (what severities mean, how to think
  about layer impact). Ablation-test deletions on the eval lane before shipping (research:
  instruction files can measurably hurt). WORKFLOW.md becomes a thin router + the numbered
  operating loop; per-stage contracts load per session.

**What stays LLM (unchanged):** consideration authoring, PRD/TRD drafting, decomposition/matrix
judgment, implementation, review findings content, severity/confidence calls, layer-impact
*proposals* (script still checks), recirculation dispositions, commit messages, gate summaries.

---

## 4. Traceability — every observed failure → its mechanism

| Failure (evidence) | Mechanism | Phase |
|---|---|---|
| Reviewer nits exist only as prose (N1–N5; zero verdict JSONs) | SubagentStop verdict gate | 1 |
| Nits never routed to board (N1 N2 N4 N5 loose issues) | Hook-fired filer (`idc_file_findings.py`) | 1 |
| Parent closed Done with unrouted nits (all 4 strandings) | Close guards: `--require-routed-findings` + PreToolUse merge/close interlock | 2 |
| Hand-rolled finish bypassed `idc_git_finish.py` (0 invocations) | PreToolUse deny/nudge on raw merge; finish tail = only door | 2 |
| Loose `gh issue create` improvisations (#242/#243/#247–#250) | PostToolUse issue-create check; PreToolUse deny raw board writes | 2 |
| Drain said `complete` with non-empty inbox (D1/D2) | 3-conjunct fixpoint + distinct exit codes | 0 |
| LLM exited anyway (rationalized contract) | Stop-hook fixpoint gate + obligations ledger | 3 |
| Recirculator killed mid-drain, no checkpoint | SubagentStop closeout-or-checkpoint | 3 |
| Recovery pointers with empty Status (#255/#256 — detector blinded) | Atomic create-pointer (Stage+Status together) + board-lint rule + `--fix` | 0 |
| Reviewer's pre-merge condition silently downgraded (#246→#248) | Verdict schema: `merge_conditions[]` honored by close guard | 2 |
| Phantom-idle teammate (impl-235) | TeammateIdle synthesis hook | 3 |
| `idc_acceptance_check.py` never really ran | Wave-close invoked by the drain loop itself, not prose | 3 |
| Role collapse (no idc-build/finisher spawned) | Interlocks make the collapsed path unable to *finish* wrong (C, E); role spawning stays advisory | 2/3 |
| Sweep blind in headless (SessionEnd cancelled) | Enforcement moved to PreToolUse/PostToolUse/Stop/SubagentStop (fire in `-p`; spike confirms); SessionEnd stays as backstop | 1–3 |
| Inventory top-10 prose transitions (pointer advance, origin re-link, gate unblock…) | All become engine ops with guards; board-lint rules catch drift | 2/4 |

---

## 5. Migration plan (each phase independently shippable — rendered as `/fullauto-goal` contracts)

Phases 0–4 below are ready-to-run **`/fullauto-goal` contracts**: each fenced block is a complete,
valid native `/goal` payload (GOAL · VERIFICATION SURFACE · CONSTRAINTS · BOUNDARIES · ITERATION
POLICY · BLOCKED-STOP · ASSUMPTIONS). To execute a phase, paste its block into `/fullauto-goal`
(or `/goal`) from this repo's root. Contracts inherit the rollout discipline at the bottom of this
section; every inferred detail is flagged under ASSUMPTIONS for veto. Run in order — later phases
assume earlier ones shipped (noted per contract) — but each ships on its own.

### Phase 0 — Truthful signals (script-only; no new infra)

*(Small: ~4 scripts touched.)*

```
GOAL: IDC's deterministic signals are truthful and complete — idc_autorun_drain.py verifies all
three fixpoint conjuncts (build lane drained; Stage=Recirculation ∧ Status=Todo inbox empty; no
admitted-but-unplanned considerations), reports recirc_inbox / unplanned_considerations counts,
and exits with a distinct non-zero code + "drain: recirc-pending" when any conjunct fails;
board-lint gains empty-Status (finding + --fix) and Stage∈{Consideration,Recirculation} invariant
rules; pointer/ticket creation is atomic (Stage+Status set together, discard on partial failure);
janitor emits a RESUME-RECIRC finding when an open recirc branch/PR coexists with an open inbox —
each new check covered by a red-when-broken governance eval.

VERIFICATION SURFACE:
  - bash scripts/lint-references.sh → exit 0
  - bash tests/smoke/run-all.sh → all green, including new seeded-board scenarios under
    tests/smoke/governance/ (create the lane): "drain with non-empty inbox ⇒ recirc-pending +
    distinct non-zero exit"; "create-pointer/create-ticket can never yield Stage without Status";
    "board-lint flags and --fixes an empty-Status item"; "janitor reports RESUME-RECIRC on a
    seeded open recirc branch + open inbox"
  - passing looks like: run-all.sh summary all green; each new scenario proven red-when-broken
    (temporarily break the enforcing line → scenario fails → restore)
  - no existing coverage for these behaviors — write each failing governance scenario first;
    done = new scenarios pass AND the existing smoke suite stays green
  - sandbox e2e (autorun sandbox, per the recipe in CLAUDE.md / docs/dev/local-e2e-testing.md):
    with a seeded Stage=Recirculation ∧ Status=Todo item, the drain reports
    "drain: recirc-pending" + the distinct exit code; capture to _idc-observability/

CONSTRAINTS (must not regress):
  - Script-only: no new hooks, no hooks.json / plugin.json changes, no new infra
  - "drain: complete" / exit 0 still means ALL conjuncts hold; existing green-path consumers
    (autorun.md's exit-code binding) keep working — new states get NEW distinct exit codes
  - Both backends (github + filesystem) get the semantics; filesystem proves them in smoke
  - GraphQL budget: reuse the item-id cache and paginated reads; no per-check re-pagination
  - Shipped-file conventions hold (idc: namespacing, ${CLAUDE_PLUGIN_ROOT} rules, no personal
    paths in shipped files)
  - Live repos (knowledge-engine, mdm-proj) untouched; sandboxes mutated only via the documented
    reset/seed procedures
  - Any incidental issues needed to satisfy this contract are resolved in this same loop; no
    needed work is punted to future or other sessions

BOUNDARIES:
  - touch: scripts/idc_autorun_drain.py, scripts/idc_board_lint.py, scripts/idc_git_janitor.py,
    the board write helpers (scripts/idc_gh_board.py / scripts/idc_tracker_fs.py) for the atomic
    create ops, tests/smoke/ (+ new tests/smoke/governance/), CHANGELOG + doc touch-ups
  - off-limits: hooks/, .claude-plugin/, commands/ agents/ skills/ prose (demotion is Phase 4),
    templates/ beyond doc pointers, live repos

ITERATION POLICY: record-and-vary — land one check per round (failing governance scenario first
  → implement → red-when-broken proof → smoke green), logging {what changed, what the evidence
  showed, next experiment}; vary the approach instead of repeating a failed one.

BLOCKED-STOP: halt and surface {attempted paths, evidence, blocker, exact input needed} on: gh
  auth / rate limits blocking the sandbox e2e; an exit-code allocation that would break an
  existing consumer with no compatible alternative; or ~3 failures on the same hypothesis.

ASSUMPTIONS (inferred — veto before go):
  - Full plan + forensics + inventory read first; this phase = §3.4 signals plus the
    atomic-create / board-lint / janitor rows of §4 (the #255/#256 and D1/D2 failure classes)
  - The governance-eval lane starts here as ordinary smoke scenarios wired into run-all.sh;
    release-checklist wiring is Phase 4
  - Distinct exit-code values are chosen in this loop and documented in the script header and
    wherever autorun.md states drain exit semantics
  - The atomic create helper extends the existing backend helpers — no transition engine yet
    (Phase 2 wraps it later)
  - Proving "recirc-pending on a seeded inbox" may run the drain script directly against the
    seeded sandbox board; a full spawned /idc:autorun session is not required for this phase
```

### Phase 1 — The verdict pipeline (kills stranded nits)

```
GOAL: review findings can no longer strand as prose — a review agent cannot stop without a
validated verdict JSON at the canonical path (SubagentStop gate: idc_review_verdict_check.py
passes, else stop is blocked with the exact missing-artifact message, bounded N=3 then loud
fail), and a hook-fired filer (new scripts/idc_file_findings.py) turns every minor/nit finding
and every deferrals[] entry into a Stage=Recirculation, Status=Todo board item (provenance label
+ origin line + idc-recirc-source dedupe key; blocks_goal:true deferrals get the parent-blocking
dependency link) — with reviewer/coordinator prompts stripped of tracker instructions and
deferral markers auto-emitted from the verdict.

VERIFICATION SURFACE:
  - Step 0 spike evidence FIRST: a disposable marker-file hook proves which of PreToolUse /
    PostToolUse / Stop / SubagentStop fire in headless `claude -p` and in subagent contexts on
    current Claude Code; findings recorded in docs/dev/ BEFORE any dependent hook work
  - bash scripts/lint-references.sh → exit 0; bash tests/smoke/run-all.sh → all green
  - governance eval "verdict with N nits ⇒ N Recirculation board items, idempotent on re-run
    (zero duplicates)" — written failing-first, then green, proven red-when-broken
  - sandbox e2e (install sandbox, per the CLAUDE.md recipe): a build lifecycle with a seeded
    nit-producing review ends with the nits on the board, with zero reliance on reviewer prose
  - negative test observed: withhold/delete the verdict file ⇒ the reviewer's stop is blocked
    with the exact missing-artifact message; after N=3 the loud-fail path fires (no infinite
    loop)
  - passing looks like: all four evidence lines above hold in the captured runs

CONSTRAINTS (must not regress):
  - The spike gates everything: no dependent hook work lands before spike results; if
    SubagentStop doesn't fire where needed, fall back to the §6 drain-loop-step shape and record
    that decision in this doc
  - hooks/hooks.json is auto-discovered — it must NOT also be listed in plugin.json (the 3.1.1
    duplicate-hooks regression)
  - Hook scripts live in scripts/hooks/, are repo-gated (no-op outside IDC-governed repos), and
    share the P4 fail-mode helper; rollout is fail-soft/observe-first where denial isn't proven
  - All gates bounded (anti-nag); IDC_HOOKS_OBSERVE_ONLY=1 downgrades denials to warnings
  - Reviewer judgment content unchanged — only tracker instructions leave the prompts
  - The existing SessionEnd sweep stays (belt-and-braces); both backends supported by the filer;
    live repos untouched
  - Any incidental issues needed to satisfy this contract are resolved in this same loop; no
    needed work is punted

BOUNDARIES:
  - touch: hooks/hooks.json, new scripts/hooks/*, new scripts/idc_file_findings.py,
    scripts/idc_review_verdict_check.py, agents/idc-review-agent.md,
    agents/idc-review-coordinator.md (+ the review-engine skill markdown under skills/ if it
    carries tracker instructions), tests/smoke/governance/, docs/dev/ (spike notes)
  - off-limits: plugin.json hooks key (never add), transition engine + close guards (Phase 2),
    Stop-hook fixpoint gate + obligations ledger (Phase 3), prose demotion beyond removing
    tracker instructions from review prompts (Phase 4), live repos

ITERATION POLICY: record-and-vary in strict order — spike → SubagentStop verdict gate → filer →
  prompt strip → re-run the eval after the strip to prove zero prose reliance; per round log
  {what changed, what the evidence showed, next experiment}; vary failed approaches.

BLOCKED-STOP: halt and surface {attempted paths, evidence, blocker, exact input needed} if the
  spike shows the needed events don't fire headless AND the drain-loop fallback can't kill drop
  points A/B; on undocumented/contradictory hook behavior after 3 attempts; or on sandbox
  auth/rate-limit blocks.

ASSUMPTIONS (inferred — veto before go):
  - Canonical verdict path stays docs/workflow/code-reviews/ with idc_review_verdict_check.py as
    validator (already specified in v3.3.0)
  - The filer creates tickets via the Phase-0 atomic create helper; it is re-pointed at the
    Phase-2 transition engine when that lands
  - N=3 as the bounded re-ask, per §3.2
  - Deferral markers derive from the validated verdict's deferrals[] — replacing prose-instructed
    marker emission, not adding a second channel
```

### Phase 2 — The single door + terminal interlocks (kills improvisation)

```
GOAL: there is one door to workflow state — new scripts/idc_transition.py wraps both backends
behind typed ops (create-ticket | create-pointer | claim | move | close | retire |
recirculate-intake | link | unblock) with the legal-transition table + guard receipts declared in
new templates/workflow-machine.yaml — and terminal actions outside that door are intercepted:
PreToolUse interlocks on gh pr merge / gh issue close / state-closing gh api calls / raw board
mutations ship in warn-inject mode (deny-capable for later promotion), idc_git_finish.py gains
--require-routed-findings, and the verdict schema gains merge_conditions[] honored by the close
guard.

VERIFICATION SURFACE:
  - bash scripts/lint-references.sh → exit 0, including a NEW lint rule banning direct
    board-mutation snippets in shipped prose (proven red-when-broken on a seeded violation)
  - bash tests/smoke/run-all.sh → all green; engine semantics proven on the filesystem backend
    first: illegal transition ⇒ error; "close without validated verdict receipt ⇒ denied";
    post-op normalization (Stage never without Status); read-back verification on every op —
    each written failing-first, red-when-broken
  - negative test: idc_git_finish.py --require-routed-findings refuses to merge/close while the
    verdict's findings are unrouted
  - sandbox e2e (install sandbox): full lifecycle green with every transition through the
    engine; a hand `gh pr merge` without receipts → corrective warn-inject naming the exact
    idc_git_finish.py / idc_transition.py command (deny path exercised via the mode switch); a
    raw `gh project item-edit` → denied with remediation text
  - sandbox e2e (update sandbox): /idc:update scaffolds workflow-machine.yaml into a governed
    repo and the drift contract recognizes it
  - passing looks like: all lifecycle + interlock evidence above in captured runs

CONSTRAINTS (must not regress):
  - Rollout discipline: merge/close interlocks SHIP warn-inject; hard-deny promotion is a
    separate later decision (§6, operator decision 1) — but the deny path must exist and be
    e2e-exercised behind the mode switch now; raw board mutations outside the engine are
    deny-by-design (warn-only during rollout)
  - Every deny/warn message names the exact remediation command (self-healing, P3);
    IDC_HOOKS_OBSERVE_ONLY=1 honored; all gates repo-gated + bounded
  - The engine wraps the existing backend helpers (idc_gh_board.py / idc_tracker_fs.py) — no
    second sanctioned write path remains; ops are atomic, read-back verified, normalized
  - GraphQL budget: guards read via the item-id cache; no per-gate re-pagination
  - Existing lifecycle e2e (think → plan → build) stays green; hooks.json never listed in
    plugin.json; live repos untouched
  - Any incidental issues needed to satisfy this contract are resolved in this same loop; no
    needed work is punted

BOUNDARIES:
  - touch: new scripts/idc_transition.py, new templates/workflow-machine.yaml, scaffold wiring
    (scripts/idc_init_scaffold.sh, scripts/idc_template_for.py, commands/init.md,
    commands/update.md), scripts/hooks/ (PreToolUse interlocks) + hooks/hooks.json,
    scripts/idc_git_finish.py, verdict schema + scripts/idc_review_verdict_check.py
    (merge_conditions[]), scripts/lint-references.sh, tests/smoke/ + tests/smoke/governance/
  - off-limits: Stop-hook fixpoint gate + obligations ledger (Phase 3), transition journal +
    reconciliation (Phase 4), prose demotion beyond the new lint rule's minimum (Phase 4),
    live repos

ITERATION POLICY: record-and-vary — engine ops land one at a time, proven on the filesystem
  backend first (the cheap place per §6), then github; interlocks land observe-first with
  telemetry before the deny path is exercised; per round log {what changed, what the evidence
  showed, next experiment}.

BLOCKED-STOP: halt and surface {attempted paths, evidence, blocker, exact input needed} if
  Phase-1 spike evidence says PreToolUse can't reliably intercept the terminal Bash commands; if
  guard evaluation can't fit the GraphQL budget after 3 optimization attempts; or if the
  warn-vs-deny promotion decision (§6, operator decision 1) genuinely blocks shipping.

ASSUMPTIONS (inferred — veto before go):
  - Depends on Phase 0 (atomic creates, truthful drain) and Phase 1 (verdict pipeline + spike
    evidence); the Phase-1 filer is re-pointed at the engine in this phase
  - Journal append is stubbed in the engine here and lands fully in Phase 4
  - workflow-machine.yaml follows the existing template/drift conventions (operator-visible,
    update-managed, scaffolded by /idc:init and /idc:update)
  - merge_conditions[] is backward-compatible (absent ⇒ no conditions); it closes the
    silently-downgraded pre-merge-condition failure (#246→#248)
```

### Phase 3 — Loop & liveness enforcement

```
GOAL: the loop can neither lie about being done nor lose state — an autorun/build orchestrator
session cannot stop while drain --fixpoint reports pending conjuncts (Stop-hook gate reading the
obligations ledger: bounded reminders, then loud fail with board annotation); a recirculator that
dies mid-drain leaves a resume checkpoint (branch, PR#, dispositions so far) on every still-open
inbox ticket; an idle teammate's completion is synthesized from worktree/branch/PR state
(TeammateIdle); commits and issue-creates self-repair board coherence (PostToolUse); and the
drain loop itself invokes idc_acceptance_check.py at wave close.

VERIFICATION SURFACE:
  - bash scripts/lint-references.sh → exit 0; bash tests/smoke/run-all.sh → all green
  - seeded governance scenarios, written failing-first and proven red-when-broken:
    kill the recirculator mid-drain ⇒ every still-open inbox ticket carries a resume-checkpoint
    comment; stop attempt with a non-empty inbox ⇒ blocked, bounded reminders, then loud fail
    with board annotation (the bound must actually be hit in test — no infinite nag); commit on
    an item not claimed/In-Progress ⇒ auto-repair or corrective injection observed; gh issue
    create that never board-adds ⇒ remediation injected or auto-added with Stage+Status; wave
    close ⇒ idc_acceptance_check.py demonstrably invoked by the drain loop (not prose)
  - sandbox e2e (autorun sandbox): a drain run demonstrates the Stop gate + ledger end-to-end;
    captured to _idc-observability/
  - passing looks like: all five scenario behaviors observed in captured runs

CONSTRAINTS (must not regress):
  - The obligations ledger (.idc-session-state.json) is written ONLY by hooks/scripts — never by
    the LLM; taints cleared only when the deterministic action completes
  - Anti-nag bounds on every gate (N reminders → loud fail); IDC_HOOKS_OBSERVE_ONLY=1 honored;
    hooks repo-gated; P4 fail modes (pre-gates fail-closed, post-hoc observers fail-open)
  - The Stop gate reads drain --fixpoint + the ledger — no new expensive board reads per stop
    (GraphQL budget)
  - Phase 0's exit-code contract unchanged; Phase 1–2 gates keep passing their evals; live repos
    untouched
  - Any incidental issues needed to satisfy this contract are resolved in this same loop; no
    needed work is punted

BOUNDARIES:
  - touch: scripts/hooks/ (Stop fixpoint gate, SubagentStop recirculator
    closeout-or-checkpoint, TeammateIdle synthesis, PostToolUse commit-sync + issue-create) +
    hooks/hooks.json, the ledger module, scripts/idc_autorun_drain.py (--fixpoint +
    acceptance-check invocation), scripts/idc_recirc_closeout.py, commands/autorun.md +
    agents/idc-recirculator.md (minimal alignment only), tests/smoke/governance/
  - off-limits: transition-engine internals beyond ops these gates need, the verdict pipeline
    (shipped in Phase 1), journal/reconciliation + prose demotion (Phase 4), live repos

ITERATION POLICY: record-and-vary — one enforcement point per round (scenario failing-first →
  implement → red-when-broken proof → smoke green); log {what changed, what the evidence showed,
  next experiment}; vary failed hypotheses instead of repeating them.

BLOCKED-STOP: halt and surface {attempted paths, evidence, blocker, exact input needed} if the
  spike/reality shows Stop or TeammateIdle doesn't fire in the needed (headless) contexts and
  the drain-loop fallback can't cover drop points E/F/H; if the mid-drain kill can't be
  simulated deterministically after 3 distinct approaches; or on sandbox auth/rate-limit blocks.

ASSUMPTIONS (inferred — veto before go):
  - TeammateIdle availability comes from the Phase-1 spike; fallback = the same synthesis check
    invoked from the drain loop (deterministic, different transport)
  - .idc-session-state.json lives in the governed workspace root and is gitignored via the
    scaffold
  - "Autorun cannot exit with a non-empty inbox" = Stop-gate blocks + truthful non-zero drain
    (§3.4); an operator kill / usage-window cut is not preventable — the checkpoint path covers
    that case instead
```

### Phase 4 — Machine-as-data, journal, prose demotion

```
GOAL: the machine is data and the prose is honest — templates/workflow-machine.yaml is the
single source of workflow truth (lint cross-checks prose references against it); every engine op
appends one line to docs/workflow/transition-journal.ndjson, janitor/doctor reconcile
board ↔ journal ↔ git and janitor rotates closed-out segments; the governance-eval lane is wired
into the release gate; and imperative control-flow prose whose enforcement now exists in code is
deleted or demoted to short advisory pointers, with ablation runs proving no regression.

VERIFICATION SURFACE:
  - bash scripts/lint-references.sh → exit 0 including the machine-yaml cross-check rule
    (red-when-broken: a prose reference to a state/transition absent from the yaml fails lint)
  - bash tests/smoke/run-all.sh and bash scripts/run-evals.sh → all green
  - journal replay: reconstruct the expected board end-state from a full sandbox lifecycle's
    journal and diff against the actual board ⇒ empty diff
  - negative test: hand-inject a journal/board divergence in a sandbox ⇒ doctor flags it
  - ablation runs: each prose deletion/demotion batch re-runs the governance-eval lane with no
    regression vs. the pre-deletion baseline (research: instruction files can measurably hurt —
    prove each deletion safe)
  - scripts/idc_release_check.py fails when the governance lane is red (release gate wired,
    red-when-broken)
  - sandbox e2e: (install) full lifecycle with journaling on; (update) /idc:update migrates a
    governed repo cleanly — WORKFLOW.md thin-router refresh, operator-owned data configs
    preserved
  - passing looks like: empty replay diff, doctor divergence flag, no-regression ablation
    report, and a red release check on a seeded governance failure

CONSTRAINTS (must not regress):
  - Prose demotion touches ONLY control-flow prose now enforced in code; judgment knowledge
    (severity meanings, layer-impact thinking, disposition guidance) stays; deletions are
    ablation-gated (recommended §6, operator decision 3)
  - The journal is append-only, janitor-rotated, tracked at
    docs/workflow/transition-journal.ndjson (recommended §6, operator decision 2 — flag if the
    operator prefers gitignored .idc/)
  - /idc:update's file-category rules hold: operator-owned data configs preserved, never
    overwritten; the drift contract learns every new scaffolded file
  - Phases 0–3 evals keep passing; live repos untouched until release
  - Any incidental issues needed to satisfy this contract are resolved in this same loop; no
    needed work is punted

BOUNDARIES:
  - touch: scripts/idc_transition.py (journal append), scripts/idc_git_janitor.py +
    commands/doctor.md (reconciliation + rotation), scripts/lint-references.sh (cross-check
    rule), scripts/idc_release_check.py (governance-lane gate), templates/WORKFLOW.md (thin
    router) + templates/workflow-machine.yaml, commands/ agents/ skills/ prose (the demotion
    sweep — wide but strictly bounded to now-enforced control-flow prose),
    tests/smoke/governance/, CHANGELOG/release docs
  - off-limits: judgment-knowledge prose content, Phase-5 items (policy generalization, dream
    sweep, merge-lease CAS, adversarial pass, Pi parity, YAML-rendered WORKFLOW.md), live repos

ITERATION POLICY: record-and-vary — journal + reconciliation first (mechanical), then the
  demotion sweep in small ablation-gated batches (delete → run the eval lane → keep or
  restore); log {what changed, what the evidence showed, next experiment} per batch.

BLOCKED-STOP: halt and surface {attempted paths, evidence, blocker, exact input needed} if
  ablation shows regression with no safe deletion subset after 3 batch attempts (keep the
  prose, report); if journal replay exposes engine gaps needing non-additive Phase-2 rework; or
  if operator decisions 2/3 (§6) reject the recommended defaults mid-flight.

ASSUMPTIONS (inferred — veto before go):
  - Depends on Phases 0–3 shipped (engine, gates, and ledger exist to journal and reconcile)
  - "Replay" = event-sourcing check (reconstruct expected end-state from the journal, diff
    against actual), not time-travel re-execution
  - Recommended §6 defaults taken: tracked journal location; ablation-gated deletion keeping
    judgment knowledge
  - The release gate lands in scripts/idc_release_check.py (the existing release checker), not
    a new checklist document
```

### Phase 5 — Optional/advanced (separate decisions; deliberately not one contract)

Not rendered as a single `/fullauto-goal` contract: these are independent opt-in items, each
needing its own operator decision first — one merged GOAL/verification surface would be
dishonest. When an item is approved, feed it to `/fullauto-goal` on its own. The menu:
label-gated stateful policy generalization; nightly "dream" sweep over `_idc-observability/`
mining interventions → proposed gates; GitHub merge-lease CAS; Loophole-style adversarial pass
over WORKFLOW.md/gate rules; Pi-runtime parity (port the hook gates to Pi's extension points —
oh-my-pi shows the native shapes); rendering WORKFLOW.md sections from the machine YAML.

**Rollout discipline (all phases):** smoke-gate here → sandbox e2e (`--plugin-dir` at the branch,
install/update/autorun sandboxes as appropriate) → ke/mdm only after release, per standing rules.
Hooks ship repo-gated and fail-soft observability-first where denial isn't yet proven safe.

---

## 6. Risks, tradeoffs, open decisions

- **Hook-event availability is the load-bearing assumption.** Hence the Phase-1 spike before any
  dependent work. Fallback if an event is unavailable headless: the same check runs as a
  drain-loop step (script-invoked, still deterministic — Archon's shape) instead of a hook.
- **Over-blocking risk (agent deadlock).** Every gate is bounded (N reminders → loud fail with
  board annotation), remediation-naming (self-healing denials), and repo-gated. Rollout is
  warn-inject first, deny after one release of clean telemetry. An escape hatch env var
  (`IDC_HOOKS_OBSERVE_ONLY=1`) downgrades all denials to warnings for operator debugging.
- **Hook latency/cost.** Command hooks add ~100–300ms per intercepted call; matchers are narrow
  (specific Bash patterns, specific agent names) so the hot path (Read/Grep/Edit) is untouched.
- **GraphQL budget.** Guards read board state; use the item-id cache and journal-first reads to
  avoid re-paginating per gate (the ~5000-points-per-drain profile is already tight).
- **Two backends.** Every mechanism lands in the adapter layer (github + filesystem) — the
  filesystem backend is the cheap place to prove semantics first; smoke runs there.
- **Open decisions for the operator:**
  1. Warn-first duration before hard-deny (recommend: one release).
  2. Journal location — tracked `docs/workflow/transition-journal.ndjson` (recommended: tracked,
     janitor-rotated) vs gitignored `.idc/`.
  3. Prose-demotion aggressiveness in Phase 4 (recommend: ablation-gated deletion, keep judgment
     knowledge).
  4. Whether the transition engine later fronts as an MCP server (typed self-describing surface;
     research favors it; defer — hooks + script suffice now).

## 7. Sources

Research Wiki: `wiki/deterministic-agent-harness-engineering-synthesis` (synthesis; division of
labor, pattern catalog with per-source attribution) · `digest/agent-harness-engineering`
(briefing) · repo teardowns `wiki/oh-my-pi-agent-harness-analysis` (settle gates, escalation
ladders, schema'd yield), `wiki/archon-agent-harness-analysis` (DAG engine, validate-and-reask,
no-silent-drop, until_bash), `wiki/omnigent-agent-harness-analysis` (policy engine through Claude
Code hooks, fail-closed phases, parked ASKs). Companion docs in this directory: the forensics and
the governance inventory (headers above).
