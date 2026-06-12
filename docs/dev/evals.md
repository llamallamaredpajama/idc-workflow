# IDC plugin evals

A behavioral eval suite for the `idc` plugin's IDC roles (Think → Plan → Sequence →
Build → Ripple, plus Autorun and the Subphase Pillar Planner). The evals measure whether
each role *makes the right governed decision* — classifies drift, admits a pillar, runs a
diff-gate, refuses an out-of-boundary write — against a disposable IDC-governed sandbox.

## TL;DR

```bash
# 1. build the throwaway governed sandbox (.sandbox/ is gitignored)
scripts/materialize-sandbox.sh --fresh

# 2. run everything (LLM-judged, faithful to the original autorater)
scripts/run-evals.sh --all

# fast deterministic smoke (refusal/verdict cases only; no judge calls)
scripts/run-evals.sh --all --no-judge

# one set, with explicit sandbox + model
scripts/run-evals.sh role-ripple-no-ripple --sandbox /tmp/sbx --model sonnet
```

`run-evals.sh` prints a pass/fail table and exits 1 if any case FAILs (exit 3 = no FAILs
but at least one infra error, judge-side or agent-side — those cases score `ERR`, not
`FAIL`, so a red suite always means real behavioral failures; rerun the `ERR` cases). Per-case agent and judge outputs are saved under
`.sandbox/eval-results/<timestamp>/`.

## Where these came from (and what changed)

The evalsets were migrated from `idc-test-repo`, a polyglot fixture that fed the original
**Google ADK runtime** (`idc-workflow-runtime`). In that world:

- Each `*.evalset.json` was an ADK eval (prompt + provenance) run against a single Python
  *role agent* module (e.g. `think_role.py`, `ripple_role.py`).
- Scoring was two-layer, defined in a sibling `test-cases/<id>/rubric.yaml`: a **binary**
  keep/revert gate (required refusal reason codes present / forbidden ones absent) plus a
  **rubric** quality scalar judged by an LLM autorater.
- Reason codes (`scope_invention_denied`, `forbidden_glob_hit`, …) and verdicts
  (`NO_RIPPLE | MINOR_AUTONOMOUS | GATED | MAJOR_GATED`) were the runtime's vocabulary.

The plugin has **no ADK runtime**. The roles are now Claude Code markdown
agents/skills/commands run inside Claude Code. Three things follow:

1. **No team-orchestrator invocation.** The `/idc:*` commands are Claude-Teams
   *orchestrators* — they require `TeamCreate` and explicitly refuse `Task` dispatch, so
   they cannot run under headless `claude -p`. The original evals ran a *single role
   agent*, not a team. So the runner enacts each case as a **single role session**: a
   harness system prompt tells Claude to act as the IDC role, consult the doctrine, and
   answer as text — no teammates, no file writes, no git/gh.
2. **The sandbox carries the vocabulary.** The sandbox `WORKFLOW.md` (`§1`–`§7`) embeds the
   canonical role boundaries *and* the refusal-code / verdict tokens. Because each role
   cites its governing repo's `WORKFLOW.md`, the role's output uses the canonical tokens.
   To keep that from being gameable (the doctrine *menus* contain every token), the
   harness demands a structured final line (`verdict: <TOKEN>` / `refusal: <code>`) and
   the deterministic gate reads ONLY that line, with word-boundary matching.
3. **The evalsets are self-contained.** The `rubric.yaml` scoring was folded into each
   migrated evalset (the `scoring` block), so `evals/` needs nothing from `test-cases/`.

## Evalset schema (augmented)

Each `evals/<id>.evalset.json` preserves the original ADK fields (`eval_set_id`, `name`,
`description`, `needs_llm`, `eval_cases[].{eval_id, provenance, conversation,
session_input}`) and adds:

| Field | Meaning |
|---|---|
| `role` | IDC role the harness enacts (e.g. `Ripple`, `Build`, `Sequence`). |
| `doctrine_ref` | `idc:`-namespaced skill/agent the harness tells the role to consult. |
| `headless` | `"skip"` ⇒ the runner skips the set (none currently). |
| `headless_note` | Fidelity caveat for cases that normally fan out to teammates. |
| `eval_cases[].scoring.expect_refusal` | Whether a correct answer refuses the request. |
| `eval_cases[].scoring.binary.any_of` | Refusal codes / verdict tokens, ≥1 must appear on the structured final line. |
| `eval_cases[].scoring.binary.all_of` | Tokens that must all appear on the structured final line. |
| `eval_cases[].scoring.binary.none_of` | Forbidden tokens — the original gate's "forbidden ones absent" half; the case FAILs if any appears on the structured final line. |
| `eval_cases[].scoring.binary.no_forbidden_source_writes` | Hard gate: the role must not mutate the sandbox. |
| `eval_cases[].scoring.rubric[]` | Weighted criteria (weights sum to 1.0) for the judge. |

## How scoring works

Two layers, mirroring the original binary keep/revert gate + autorater design:

- **Deterministic token gate (both modes, when the case defines tokens).** The harness
  prompt requires the agent to end with one structured line — `verdict: <TOKEN>` or
  `refusal: <code>` — and the gate matches `any_of` / `all_of` / `none_of` against that
  line only, with word boundaries (`GATED` does not match `MAJOR_GATED` or "delegated";
  doctrine-menu quotes elsewhere in the answer can neither pass nor fail it). A failed
  gate FAILs the case in BOTH modes — required tokens present, forbidden (`none_of`)
  tokens absent, exactly the original binary keep/revert semantics.
- **LLM judge (default).** Autorater-equivalent. A second `claude -p` call (no plugin,
  default permissions) scores the agent output against the weighted `rubric` criteria +
  the required refusal/classification, and returns `pass` when the weighted score ≥ `0.7`
  (and the agent refused, for refusal cases). The judge decides PASS/FAIL once the
  deterministic gate passes. A transient judge infra error retries once, then scores the
  case `ERR` (reported separately; exit 3, never exit 1). Agent-side infra errors score
  `ERR` the same way: a usage-limit banner in place of an answer, or empty agent output
  (timeout/crash/limit) — those cases need a rerun, not a code fix.
- **`--no-judge`.** The deterministic gate alone is authoritative for refusal/verdict
  cases; generative/quality cases (no tokens) become `SKIP(needs-judge)`. Useful as a
  fast smoke test — especially for the Ripple verdict ladder and the refusal-code cases.
- **`no_forbidden_source_writes` (always).** After the run, the sandbox is checked with
  `git status --porcelain`. If the role mutated the sandbox despite the no-write boundary,
  the case FAILS regardless of the judge.

The result table columns: `CASE | ROLE | RESULT | det:<PASS|FAIL|na|ERR> judge:<score>`.

**Permissions caveat.** The agent under test runs with `--permission-mode
bypassPermissions` inside the sandbox. The write-gate only checks the sandbox git tree —
writes outside it, `gh`, or network calls are constrained by the harness instructions
alone. That is acceptable for a dev harness; do not point the runner at untrusted
evalsets. The judge runs with default permissions and no plugin.

## What migrated, what was excluded

**19 evalsets migrated** (24 cases) — every IDC-role / orchestration / refusal case that
maps to a plugin surface:

- Think: `role-think-consideration`
- Plan: `role-plan-chain`, `plan-prd-spec-chain`, `plan-multi-subphase`,
  `role-subphase-pillar-plan`
- Sequence: `role-sequence-admit-happy` / `-lane` / `-missing-ref` / `-scope`
- Build: `role-build-pillar`, `build-refuse-diff-gate`, `build-refuse-forbidden-glob`,
  `build-refuse-forbidden-tool`, `build-refuse-goal-recipe`
- Ripple: `role-ripple-drift`, `role-ripple-no-ripple`, `role-ripple-minor-autonomous`,
  `role-ripple-major-gated`
- Autorun: `orchestrate-autorun-chain`

**4 evalsets excluded — runtime-only (no plugin surface).** These test the ADK runtime's
**coding-fleet orchestrator** (`coding_orchestrator` / `build_orchestrator_agent` and its
domain→specialist routing with `transfer_to_agent`). The `idc` plugin has no coding-fleet
/ domain-routing concept (verified: zero matches across `agents/`, `skills/`, `commands/`),
so there is nothing to evaluate:

- `orchestrate-domain-routing`
- `orchestrate-domain-not-provided`
- `orchestrate-specialist-not-found`
- `orchestrate-specialist-handoff` (also needs a *live* multi-teammate `transfer_to_agent`
  handoff, impossible headlessly)

**Degraded-fidelity cases (run, with a `headless_note`).** A few cases normally fan out to
Claude-Teams teammates; under the headless harness the role produces the gradeable
artifacts/decisions *inline* in one session. The decision is still scorable; full team
fan-out fidelity needs an interactive cmux Teams run. These are: `plan-multi-subphase`,
`role-subphase-pillar-plan`, and `orchestrate-autorun-chain` (a contract Q&A).

## The sandbox

`scripts/materialize-sandbox.sh` creates a generic, multi-domain, IDC-governed project at
`.sandbox/idc-eval-sandbox` (override with a positional path arg; `--fresh` wipes and
recreates; idempotent). It is git-init'd so the runner can reset it to a clean commit
between cases and detect stray writes. It contains:

- Source surfaces: `services/api/` (Python, route auto-discovery in `app/main.py`, a
  planted comment typo + a `db/CLAUDE.md` for Ripple cases, a shipped `tests/` suite),
  `web/`, `mobile/`, `game/`, `ml/`, `infra/` (Terraform), `bq/`, `contracts/`, `protos/`.
- Governance: `WORKFLOW.md` (`§1`–`§7`, stable section numbers cited by `provenance`;
  §6 Tracker substrate carries the same anchor numbering as `templates/WORKFLOW.md` so
  the skills' `§6.x` citations resolve in both governed-repo variants),
  `WORKFLOW-config.yaml`, `CONVENTIONS.md`, `TRACKER.md` (filesystem tracker), root
  `CLAUDE.md` / `AGENTS.md`.
- Fixture docs the prompts reference: `docs/considerations/*`, `docs/plans/pillars/fixture-*`,
  `docs/plans/subphases/subphase-1-data-layer.md`, `docs/prd/fixture-prd.md`,
  `docs/workflow/ripple/fixture-ripple-input.md`.
- The frozen-evaluator stub `test-cases/role-build-pillar/rubric.yaml` (so the Build
  diff-gate refusal has a real forbidden target).

It is suitable for running `/idc:init` and `/idc:doctor` against, too.

## Using these evals to improve skills

`run-evals.sh` is a measurement harness: it turns "does role X behave correctly" into a
pass/fail score. To use it as the objective for skill improvement:

1. Pick a skill that drives a role decision — e.g. `idc:idc-skill-ripple-verdict` (Ripple
   classification) or `idc:idc-skill-tracker-adapter` (Sequence admission).
2. Identify the evalsets that exercise it — e.g. the four `role-ripple-*` sets for the
   verdict skill, the four `role-sequence-admit-*` sets for admission.
3. Baseline: `scripts/run-evals.sh role-ripple-drift role-ripple-no-ripple
   role-ripple-minor-autonomous role-ripple-major-gated` and record pass/fail + judge
   scores.
4. Edit `skills/<skill>/SKILL.md`, then re-run the same subset. Because `--plugin-dir`
   points at this repo, edits take effect immediately; compare the new table to the
   baseline to confirm an improvement and catch regressions.

This is the bridge to the skill-improver tooling (`skill-improve-api`, `skill-improve-sub`,
`skill-improver-codex`): point the improver at `skills/<skill>` and use the relevant
evalset subset as its measurement set, with `run-evals.sh`'s pass-rate (and mean judge
score) as the metric to maximize. Keep the eval semantics frozen while iterating — improve
the skill to pass the eval, never weaken the eval to pass the skill.

## Requirements

- `claude` CLI (the runner uses `claude -p --plugin-dir`).
- `jq` (evalset parsing).
- `python3` (judge JSON extraction; absent ⇒ the runner falls back to `--no-judge`).
- `git` (sandbox reset + stray-write detection).
- Optional `timeout` / `gtimeout` for a per-agent-run cap (`--timeout`, default 360s).
