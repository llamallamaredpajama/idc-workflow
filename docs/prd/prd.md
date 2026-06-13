# Product Requirements — IDC Workflow Plugin (v2)

**Upstream trace:** derived from `docs/considerations/2026-06-12-idc-v2-overhaul-considerations.md`
(operator interview, 16 decisions). The v2 PRD rewrite was operator-approved live during
that interview — it is admitted work, not a pending gate.

> This PRD states what the IDC v2 plugin does for its users. The architecture that realizes
> it is `docs/specs/master-architectural-spec.md`.

## 1. Purpose

The IDC Workflow plugin packages **IDC** — the Iterative Development Cycle — as an
installable Claude Code plugin: a guardrail-framed, tracker-driven, goal-contract pipeline
that carries software work from a raw idea to merged, reviewed code. Its defining property
is **autonomy with one consent point**: the operator casts an idea into the stream and it
flows to merged, tested code on its own; the stream stops to ask exactly once — when the
product's user-facing function is about to change.

v2 is **guardrails, not train tracks**. v1 hand-held a weaker model with standing
reviewer/fixer/researcher roles, multi-pass plan reviews, a claim-state machine, and
per-edit gates. v2 trusts the model and keeps only the guardrails that catch real
derailments.

## 2. Users

The plugin's users are **operators** — the engineer who installs IDC into a repository and
runs the pipeline. Operators consume the shipped commands; they are not the plugin's
developers. The operator's whole job is to think, occasionally approve a product-function
change from their phone, and let the pipeline run.

## 3. What v2 does (requirements)

### R1 — Think (`/idc:think`)
A free-form brainstorm/interview in the main session (zero teammates; research on demand).
Emits one **function-first consideration file** under `docs/considerations/` — what the
code should do for the user and how it behaves. No gates, no admission language.

### R2 — Plan (`/idc:plan`)
Turns one consideration into **goal-contract issues** on the tracker board, in a single
zero-teammate run: domain-expert fan-out → the five-layer doc chain (PRD → spec → master →
subphase → pillar, only the PRD gated) → a 6-element goal contract per pillar → pairwise
matrix deconfliction → global re-sequencing against the live board → a mechanical schema
check → board admission, with a planning PR whose body is the audit trail.

### R3 — Build (`/idc:build`)
Executes eligible issues as goal loops (one durable worker per parallel-safe issue), each
PR reviewed by the **merged review engine** (13 dimensions, fresh-context fan-out, with
test-genuineness as a dimension). Iterate → reverify real tests green → **automerge on
PASS** → close. Nothing merges that isn't green on genuine functional tests.

### R4 — Ripple (`/idc:ripple`)
Heals drift between docs and reality in **one PR** (the PR body is the change order),
automerged — unless user-facing product function changes, in which case it takes the same
PRD gate as Plan.

### R5 — Autorun (`/idc:autorun`)
The one button: a one-shot drainer that plans every unplanned consideration, heals board
hygiene, and builds eligible work, exiting when nothing actionable remains. Loopable via
`/loop` for standing operation.

### R6 — The one gate (PRD)
When planning or ripple determines the PRD must change, affected issues land **Blocked**
behind a single approval issue with a plain-terms summary ("here's what your app will do
differently") + the PRD diff. The operator gets a **push notification** and approves from
the GitHub web UI on their phone; approval flips the status and builders proceed.
**Nothing else in the system asks for permission.**

### R7 — Install & health (`/idc:init`, `/idc:doctor`)
`/idc:init` scaffolds a repo for IDC v2: the governance contract, config with
codebase-derived domains + tier-symbolic model routing, a four-field tracker board, and
install receipts enabling clean uninstall/upgrade. `/idc:doctor` is a read-only health
check of those surfaces.

### R8 — Runtime-neutral
The pipeline runs on Claude Code or Codex through **one thin adapter per runtime** over a
shared runtime-neutral core. Model selection is tier-symbolic and operator-tunable; the
Codex runtime runs untiered at highest effort.

## 4. Out of scope (this rebuild)

- A full v2 evaluation suite — only minimal smoke evalsets if the eval harness requires a
  non-empty set (a real v2 eval suite is deferred).
- Board **migration** machinery — `/idc:doctor` reports board-schema drift but no command
  mutates a live board's schema.
- Re-enabling the plugin inside this repo's own `.claude/settings` (the rebuild stays a
  branch + PR; the operator merges).
