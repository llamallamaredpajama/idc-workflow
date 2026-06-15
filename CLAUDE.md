# idc-workflow — IDC plugin source

This repo is the **source of the IDC Claude Code plugin** (`idc@idc-workflow`) — a
guardrail-framed, tracker-driven pipeline (Think → Plan → Build, healed by Ripple, drained by
Autorun). See `README.md` for what the plugin does and `docs/architecture.md` for how the pieces
fit.

## Commands

```bash
bash scripts/lint-references.sh   # reference integrity — MUST exit 0 before every commit
bash tests/smoke/run-all.sh       # full-lifecycle smoke suite (hermetic temp repos, no GitHub)
bash scripts/run-evals.sh         # headless eval runner (resets the disposable sandbox per case)
```

`scripts/install-codex.sh` / `scripts/install-pi.sh` wire the optional Codex / Pi runtimes
(`--revert` / `--check`). The `scripts/idc_*.py` helpers are called by the commands, not by hand.
Live-loading the EDITED plugin against a sandbox is the e2e loop below.

## Repo layout

| Path | What |
|------|------|
| `.claude-plugin/` | `plugin.json` (manifest) + `marketplace.json` (self-hosted marketplace) |
| `commands/*.md` | 9 slash entry points (`think · plan · build · ripple · autorun · init · doctor · update · uninstall`) |
| `agents/*.md` | stage orchestrators + the durable-worker implementer + finisher + review coordinator/agent |
| `skills/<name>/SKILL.md` | reusable procedures — runtime adapters (claude/codex/pi), tracker adapter + backends, review engine, gate-issue, goal-contract, matrix, schema, ripple-sync |
| `templates/` | per-project scaffold `/idc:init` copies into a governed repo |
| `scripts/` | `lint-references.sh`, filesystem tracker + plan/review/ripple/autorun helpers, installers |
| `tests/smoke/` | the phase1–8 functional verification suite (`run-all.sh` drives it) |
| `docs/` | `architecture.md`, `installing.md`, PRD/specs/plans, `dev/` notes |

## Conventions (read before editing shipped files)

Shipped files = `commands/`, `agents/`, `skills/`, `templates/`, `scripts/`. All enforced by
`scripts/lint-references.sh` — run it before every commit (exit 0):

- **Namespacing.** Reference skills/agents/commands as `idc:<name>` (e.g.
  `idc:idc-tracker-adapter`, `subagent_type: "idc:idc-build"`). Files are flat `idc-<thing>`; the
  harness adds the `idc:` prefix. A bare `idc-skill-x` reference is a lint failure.
- **`${CLAUDE_PLUGIN_ROOT}`** text-substitutes to the install path inside command/agent/skill
  *markdown*, but is **NOT a shell env var** (empty inside a Bash snippet). A script that needs the
  root takes it as an argument: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<helper>.sh ${CLAUDE_PLUGIN_ROOT}`.
- **No personal paths** in shipped files — portable tokens only (`${CLAUDE_PLUGIN_ROOT}/…`,
  `<repo-root>/…`, `$HOME`), never `/Users/<name>/…`. (Personal sandbox paths ARE fine in this file
  and `docs/dev/` — they aren't shipped.)
- **Opt-in per repo.** IDC installs at `--scope project`
  (`claude plugin install idc@idc-workflow --scope project`), never the default `user` scope, which
  surfaces `/idc:*` in every repo on the machine. `/idc:doctor`'s first check FAILs on a user-scope leak.

## Local end-to-end testing — how to drive it

A live, isolated harness exists on this machine for running the plugin's full lifecycle against
realistic sandbox repos, with automatic observability. **The mechanics — repo paths, snapshot
contents, the `ke-snap` commands, teardown — live in
[`docs/dev/local-e2e-testing.md`](docs/dev/local-e2e-testing.md); read it before an e2e run.** This
section is the *how-to-drive-it* playbook for when the user asks to test a change.

### YOU drive the sandbox e2e yourself — the user never has to open a sandbox

When the user asks to test a change, **run the full lifecycle against the sandbox yourself and
report results.** Do **not** tell the user to go run `/idc:*` in the sandbox. Two test levels, both
runnable from here:

- **Smoke suite (fast, hermetic).** `bash tests/smoke/run-all.sh` exercises the whole lifecycle in
  its own throwaway temp repos (filesystem backend, no GitHub). The inner loop; no sandbox needed.
- **Full GitHub-fidelity e2e (against a sandbox).** The old caveat was over-stated: *inline* `/idc:*`
  slash commands in THIS session act on THIS repo's cwd, so they can't target a sandbox — but a
  **separate `claude` process whose cwd IS the sandbox does** (verified: it reads the sandbox's board
  + install-receipt, not this repo's). So you spawn that session from the shell:
  ```bash
  ( cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-update && \
    claude --plugin-dir /Users/jeremy/dev/proj/idc-workflow-2.1.1 \
           --permission-mode bypassPermissions -p "/idc:update" ) \
    2>&1 | tee /Users/jeremy/dev/sandbox/_idc-observability/run-<label>.txt
  ```
  - `--plugin-dir <checkout>` selects **which code version runs** (it bypasses the version-keyed
    cache). For a version-accurate **update** test, keep two checkouts side by side via a `git
    worktree` — `main` (= current production) and the candidate branch — and point `--plugin-dir` at
    whichever a step needs (resync-to-prod uses `main`; the candidate test uses the branch worktree).
  - `--permission-mode bypassPermissions` so the headless run never hangs on a prompt (sandboxes are
    disposable + git-tracked, so it's safe).
  - `-p "<command + any decisions>"`: each run is a **fresh non-interactive session**, so edited
    command/skill markdown loads **every run automatically** (no restart; `scripts/*.py` apply live
    too). It can't stop to ask, so put any interactive choice **in the prompt**, e.g.
    `-p "/idc:update — apply the safe path: refresh WORKFLOW.md only, keep the configs, re-stamp them --customized"`.

### The loop you run when asked to "test this"

1. **Pick the sandbox by what you changed:** install / scaffold / `init` / `doctor` / `think` /
   `plan` / `build` → the **install** sandbox (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-install`);
   `update` / receipt-resync / drift → the **update** sandbox
   (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-update`).
2. **Smoke-gate here first:** `bash tests/smoke/run-all.sh`. Fix failures before spending an e2e run.
3. **Sync the baseline, then drive the run(s)** — all from here, by spawning sandbox-rooted `claude
   -p` calls (snapshot pre/post with `ke-snap`):
   - **Reset / baseline / version-sync is YOUR job.** A clean start is `git -C <sandbox> reset --hard
     <baseline-commit>`, or a spawned `/idc:uninstall --delete-board` to wipe; re-scaffold to the
     target version with a spawned `/idc:init` or `/idc:update` using `--plugin-dir` at the matching
     checkout. The sandbox carries **no version number** — its install receipt is fingerprint-only —
     so "sync to version X" = "its scaffold files match what checkout X produces," achieved by an
     `/idc:update` from that checkout.
   - **Run the candidate:** spawn the command(s) with `--plugin-dir` at the candidate, capturing each
     to `_idc-observability/`.
4. **Read + iterate from here:** snapshots live OUTSIDE the sandboxes at
   `/Users/jeremy/dev/sandbox/_idc-observability/` — `ke-snap-diff <pre> <post>` for the delta, the
   captured `run-*.txt` / `transcript.txt` for the full trace — then fix the plugin code here and
   re-spawn. **Only ask the user to run something in the sandbox if a spawned `claude -p` genuinely
   can't do it (e.g. an interactive `gh auth` / login step).**

### Teammates & Codex (cmux)

A teammate's *inline* `/idc:*` still can't aim at a sandbox (its cwd is this repo) — but ANY agent
(lead, teammate, or Codex) can spawn a **sandbox-rooted `claude -p`** via Bash exactly as above, so
sandbox e2e is fully delegable. The **shared snapshot dir (`_idc-observability/`)** stays the
read-side integration point: whoever spawns the run captures output there; the lead reads it anywhere.

### Iterative loop

Edit here → `bash tests/smoke/run-all.sh` → spawn the sandbox-rooted `claude -p "/idc:<cmd>"` →
`ke-snap-diff` the result here → fix → re-spawn. Each `-p` run is a fresh session, so edited
command/skill markdown loads automatically every run; `scripts/*.py` apply live. Reset between runs
with `git -C <sandbox> reset --hard <baseline>` or a spawned `/idc:uninstall --delete-board`.
