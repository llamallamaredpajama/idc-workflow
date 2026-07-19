# idc-workflow — IDC plugin source

This repo is the **source of the IDC Claude Code plugin** (`idc@idc-workflow`) — a
guardrail-framed, tracker-driven pipeline (Think → Plan → Build, healed by the Recirculator, drained by
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
| `commands/*.md` | 13 slash entry points (`think · intake · plan · build · recirculate · autorun · pause · resume · janitor · init · doctor · update · uninstall`) |
| `agents/*.md` | stage orchestrators + the durable-worker implementer + finisher + review coordinator/agent |
| `skills/<name>/SKILL.md` | reusable procedures — runtime adapters (claude/codex/pi), tracker adapter + backends, review engine, gate-issue, goal-contract, matrix, schema, recirculator-sync |
| `templates/` | per-project scaffold `/idc:init` copies into a governed repo |
| `scripts/` | `lint-references.sh`, filesystem tracker + plan/review/recirculator/autorun helpers, installers |
| `tests/smoke/` | the phase1–9 functional verification suite (`run-all.sh` drives it) |
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
- **Full GitHub-fidelity e2e (against a sandbox) — DEFAULT DRIVER = CODEX, not a nested claude.**
  (Operator policy 2026-07-06: sandbox e2e must not spend Anthropic credit; the Codex-driven Phase-3
  E5 run proved equal effectiveness — it even recovered a genuine mid-drain kill and caught a real
  doc bug.) Drive the sandbox with a direct `codex exec` whose cwd IS the sandbox:
  ```bash
  export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"
  nohup codex exec --cd /Users/jeremy/dev/sandbox/<sandbox-repo> \
    --dangerously-bypass-approvals-and-sandbox \
    "<orchestrator prompt — see below>" \
    > /Users/jeremy/dev/sandbox/_idc-observability/run-<label>.txt 2>&1 &
  echo "codex pid $!"   # poll: ps -p <pid>; read the capture as it grows
  ```
  - **The orchestrator prompt must inline what a claude session would get from the plugin loader**,
    because Codex loads no Claude plugins: (1) name the sandbox + backend + project/owner and that it
    is ISOLATED; (2) `PLUGIN_ROOT=/Users/jeremy/dev/proj/idc-workflow` (or the candidate worktree) and
    "read PLUGIN_ROOT/commands/<cmd>.md + agents/idc-<cmd>.md FIRST and follow that playbook,
    substituting PLUGIN_ROOT for `${CLAUDE_PLUGIN_ROOT}`"; (3) "every board read/mutation goes through
    the plugin's python scripts, never raw `gh project` improvisations"; (4) "export
    `CLAUDE_CODE_SESSION_ID=<label>` for every script call and pass `--session-id <label>` where
    accepted" (the persisted-verdict chain stays testable); (5) the drain/exit contract + any
    interactive decisions, since it can't stop to ask; (6) demand a final report with verbatim script
    outputs. The Phase-3 E5 prompt in `docs/dev/2026-07-05-phase3-handoff.md` is the worked example.
  - **Do NOT use the codex-companion `task` wrapper for sandbox e2e** — it network-sandboxes the job,
    so `gh` dies with `unknown owner type` / connection failures and the run fail-closes at zero work.
    Direct `codex exec --dangerously-bypass-approvals-and-sandbox` is required (sandboxes are
    disposable + git-tracked, so it's safe). `codex review --base main` stays the review lens — that
    part is unchanged.
  - **Hook-fidelity caveat (state it in your report):** Claude Code hooks (Stop/SubagentStop/
    PreToolUse…) do NOT fire inside a Codex process. Assert hook behavior against the REAL artifacts
    the run leaves (ledger, `.idc-drain-verdict.json`, board) by invoking the hook scripts directly
    with synthetic payloads — e.g. pipe a Stop payload into `scripts/hooks/idc_stop_fixpoint_gate.py`
    and assert allow/defer/block. Same code, same artifacts, deterministic invocation.
  - **Fallback (spend-cap-gated): the nested `claude -p` recipe below.** It is the only FULL
    hook-fidelity path, but every nested claude bills Anthropic and **dies instantly once the monthly
    spend cap is hit** (the tell: a ~232-byte capture ending `You've hit your monthly spend limit`).
    Use it only when the operator confirms the cap has headroom or asks for hook fidelity:
  ```bash
  # one-time setup: printf '{"mcpServers":{}}' > /tmp/empty-mcp.json
  (
    # Inherit auth by default: this machine runs the nested claude via a VALID
    # ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL, so the old `unset` strips a working
    # credential and falls back to a stale OAuth cache → 401. Set IDC_STRIP_AUTH=1 ONLY
    # if the nested session dies with "Invalid API key" (a stale rotated key) — then it
    # falls back to your claude.ai OAuth login.
    [ "${IDC_STRIP_AUTH:-0}" = "1" ] && unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-update && \
    claude --plugin-dir /Users/jeremy/dev/proj/idc-workflow-2.1.1 \
           --strict-mcp-config --mcp-config /tmp/empty-mcp.json \
           --permission-mode bypassPermissions -p "/idc:update" < /dev/null
  ) > /Users/jeremy/dev/sandbox/_idc-observability/run-<label>.txt 2>&1
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
  - **Two spawn traps you MUST handle, or the run silently hangs / dies at 0 bytes:**
    1. **Auth.** The nested session inherits this shell's env; a stale or rotated `ANTHROPIC_API_KEY`
       / `ANTHROPIC_AUTH_TOKEN` makes it die instantly with `Invalid API key · Fix external API key`.
       `unset` both at the front of the subshell so it falls back to your subscription OAuth login.
       (Don't `echo`/print those var names — the secret-guard hook blocks it.)
    2. **MCP startup hang.** Otherwise it boots your full global MCP set (firecrawl/github/playwright/…)
       and hangs ~6 min at ~0 CPU / 0 bytes out. `--strict-mcp-config --mcp-config /tmp/empty-mcp.json`
       (create once: `printf '{"mcpServers":{}}' > /tmp/empty-mcp.json`) disables MCP — IDC uses `gh`
       + python, never MCP, so it's safe.
    Also `< /dev/null` (skips the 3s stdin wait) and capture with `> file 2>&1`, then verify `wc -c` > 0
    — `tee` buffers all stdout until the session exits, so a live capture reads 0 bytes mid-run and looks dead.

### The loop you run when asked to "test this"

1. **Pick the sandbox by what you changed:** install / scaffold / `init` / `doctor` / `think` /
   `plan` / `build` → the **install** sandbox (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-install`);
   `update` / receipt-resync / drift → the **update** sandbox
   (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-update`); `autorun` / autorun-drain → the
   **autorun** sandbox (`/Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun`, a seeded
   mid-lifecycle board — see `docs/dev/local-e2e-testing.md`).
2. **Smoke-gate here first:** `bash tests/smoke/run-all.sh`. Fix failures before spending an e2e run.
3. **Sync the baseline, then drive the run(s)** — all from here, via sandbox-rooted **`codex exec`**
   (the default driver above; nested `claude -p` only as the spend-cap-gated hook-fidelity fallback),
   snapshotting pre/post with `ke-snap`:
   - **Reset / baseline / version-sync is YOUR job.** A clean start is `git -C <sandbox> reset --hard
     <baseline-commit>`, or a spawned `/idc:uninstall --delete-board` to wipe; re-scaffold to the
     target version with a spawned `/idc:init` or `/idc:update` using `--plugin-dir` at the matching
     checkout. The sandbox carries **no version number** — its install receipt is fingerprint-only —
     so "sync to version X" = "its scaffold files match what checkout X produces," achieved by an
     `/idc:update` from that checkout.
   - **Run the candidate:** drive the command playbook(s) via `codex exec` with `PLUGIN_ROOT` at the
     candidate checkout (or, fallback path, `claude -p --plugin-dir <candidate>`), capturing each
     to `_idc-observability/`.
4. **Read + iterate from here:** snapshots live OUTSIDE the sandboxes at
   `/Users/jeremy/dev/sandbox/_idc-observability/` — `ke-snap-diff <pre> <post>` for the delta, the
   captured `run-*.txt` / `transcript.txt` for the full trace — then fix the plugin code here and
   re-spawn. **Only ask the user to run something in the sandbox if a spawned `claude -p` genuinely
   can't do it (e.g. an interactive `gh auth` / login step).**

### Teammates & Codex (cmux)

A teammate's *inline* `/idc:*` still can't aim at a sandbox (its cwd is this repo) — but ANY agent
(lead, teammate, or Codex) can spawn the **sandbox-rooted `codex exec`** (or the fallback `claude
-p`) via Bash exactly as above, so sandbox e2e is fully delegable. The **shared snapshot dir
(`_idc-observability/`)** stays the read-side integration point: whoever spawns the run captures
output there; the lead reads it anywhere.

### Iterative loop

Edit here → `bash tests/smoke/run-all.sh` → spawn the sandbox-rooted `codex exec` (fallback: `claude
-p "/idc:<cmd>"`) → `ke-snap-diff` the result here → fix → re-spawn. Each run is fresh, so edited
command/skill markdown loads automatically every run; `scripts/*.py` apply live. Reset between runs
with `git -C <sandbox> reset --hard <baseline>` or a spawned `/idc:uninstall --delete-board`.
