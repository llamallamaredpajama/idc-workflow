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

### Two levels of test — know which one you can run from here

- **Smoke suite (fast, hermetic) — you CAN run this yourself, right here.** `bash tests/smoke/run-all.sh`
  exercises the whole lifecycle in its own throwaway temp repos (filesystem backend, no GitHub). This
  is the inner loop; run it from this repo, no sandbox needed.
- **Full GitHub-fidelity e2e — must execute in a separate session INSIDE a sandbox.** You cannot run
  the interactive `/idc:*` flow against a sandbox from this repo: IDC commands act on the **session's
  own working directory**, so a session rooted here would target *this* repo, not the sandbox. This
  repo's agent **sets it up and reads the results** — it does not run the e2e inline.

### When the user asks to "test this" / iterate

1. **Pick the sandbox by what you changed:** install / scaffold / `init` / `doctor` / `think` /
   `plan` / `build` → the **install** sandbox (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-install`);
   `update` / receipt-resync / drift → the **update** sandbox
   (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-update`).
2. **Smoke-gate here first:** `bash tests/smoke/run-all.sh`. Fix failures before spending an e2e run.
3. **Run the full e2e in a sandbox session** (open it; this repo's agent can't run it inline):
   ```bash
   cd <sandbox-path>
   claude --plugin-dir /Users/jeremy/dev/proj/idc-workflow   # runs your EDITED code, not the installed copy
   ```
4. **Read what happened from here:** the snapshots live OUTSIDE the sandboxes at
   `/Users/jeremy/dev/sandbox/_idc-observability/`, so inspect them from this repo's session —
   `ke-snap-diff <pre> <post>` for the delta, the `transcript.txt` pointer for the full trace — and
   iterate on the plugin code.

### Teammates & Codex (cmux)

The spawn tools (TeamCreate / Agent) have **no "different directory" option** — a teammate inherits
**this** repo as its working dir (and `isolation: worktree` is same-repo-only and unreliable here).
So a teammate can run the **smoke suite** from here, but it **cannot aim `/idc:*` at a sandbox** —
even after a Bash `cd`, its slash-commands still target this repo. Likewise Codex runs in its own
launch directory, and the `/idc:*` lifecycle is Claude-Code-only.

Don't try to make a teammate "be" the sandbox. The **shared snapshot dir (`_idc-observability/`) is
the integration point**: run the full e2e in a separate sandbox session (you / another window), and
the lead — or any teammate, or Codex — reads those snapshot files **from anywhere** and iterates on
the code here. Run the test wherever it must run; analyze the results here.

### Iterative loop

Edit here → `tests/smoke/run-all.sh` → (sandbox session) re-run the IDC command → read the snapshot
diff here → repeat. After editing **command/skill markdown**, restart the sandbox session so new
definitions load; `scripts/*.py` edits apply live. Reset a sandbox with `/idc:uninstall --delete-board`.
