# Local end-to-end test setup for the IDC plugin

> **Operator-local note.** This describes a live test harness on **this machine** (absolute paths
> under `/Users/jeremy/dev/sandbox/`). It is a development aid for iterating on the plugin, not part
> of the shipped plugin. Paths are specific to this workstation.

There is a live, isolated harness for exercising the IDC plugin's full lifecycle
(`/idc:doctor → init → think → plan → build`, `/idc:update`, and `/idc:autorun`) against realistic
repos, with automatic observability — without touching any real project.

## The three sandbox repos

All three are throwaway clones of an unrelated real project (`knowledge-engine`), used purely as a
realistic codebase fixture. Each has its **own private GitHub repo** and **cannot reach** the
original project or its board.

| | Path | GitHub remote | IDC state | Tests |
|---|---|---|---|---|
| **Install** | `/Users/jeremy/dev/sandbox/ke-idc-test-repo-install` | `llamallamaredpajama/ke-idc-test-repo-install` (private) | **plugin NOT enabled** (blank slate) | from-scratch install: `claude plugin install idc@idc-workflow --scope project` → confirm `~/.claude/settings.json` has `idc@idc-workflow: false` (global off-switch) → `/idc:doctor` → `/idc:init` → `/idc:think` → `/idc:plan` → `/idc:build` |
| **Update** | `/Users/jeremy/dev/sandbox/ke-idc-test-repo-update` | `llamallamaredpajama/ke-idc-test-repo-update` (private) | **plugin enabled** | update path: `/idc:init` first (lays down scaffold + receipt), then `/idc:update` |
| **Autorun** | `/Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun` | `llamallamaredpajama/ke-idc-test-repo-autorun` (private); board = GitHub Project #10, **github backend** | **plugin enabled, seeded mid-lifecycle board** | autorun drain: starts on a populated board (both lanes carry work) → `/idc:autorun` drains the Planning + Build lanes to `drain: complete` |
| **Pi** | `/Users/jeremy/dev/sandbox/ke-idc-test-repo-pi` | `llamallamaredpajama/ke-idc-test-repo-pi` (private); **github backend** | **plugin enabled, clean Think-start** | **Pi runtime** e2e: real `pi` agent + real Gemini LLM drives Think→Plan→Build from one un-admitted idea. See [The Pi runtime e2e](#the-pi-runtime-e2e--4th-sandbox--real-pi--real-llm) below |

Each repo's own `CLAUDE.md` / `AGENTS.md` opens with a "IDC TEST SANDBOX" banner repeating this, so
any agent dropped into them is oriented automatically.

### The Autorun sandbox — seeded mid-lifecycle

Unlike Install (blank slate) and Update (just scaffolded), the **Autorun** sandbox starts on a
**populated mid-lifecycle board** so `/idc:autorun` has real work to drain in *both* lanes. The
seeded baseline is: ~2 approved + unplanned considerations (Planning lane) + a W1→W2 buildable chain
where W2 is natively `blocked_by` W1 (Build lane — proves the dependency gate) + 1 gated edge-case (a
Blocked consideration behind an OPEN `operator-action` gate whose Think PR stays unmerged, so autorun
must report-and-skip it). All buildable work is tiny additive files under `scratch/`, so the headless
`/idc:build` reliably completes. A clean drain ends both lanes at `drain: complete`.

- **Reset / re-seed (the reset mechanism):** `bash
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun/seed-autorun-board.sh` — full board wipe + `git
  reset --hard autorun-baseline` (the git tag on the post-`/idc:init` scaffold commit) + recreate the
  seeded considerations. Safety-guarded to refuse any repo but this one. (Backed up in
  `_idc-observability/bin/`.)
- **Run the e2e:** `bash /Users/jeremy/dev/sandbox/_idc-observability/bin/run-autorun-e2e.sh <label>`
  — spawns a sandbox-rooted `claude -p "/idc:autorun"`, handles the dead-key + MCP-hang traps, and
  captures to `_idc-observability/`.
- **Verify the drain:** `bash /Users/jeremy/dev/sandbox/_idc-observability/bin/verify-drain.sh`.

> **GraphQL-budget caveat.** This sandbox runs the **github backend**, which is GraphQL-heavy: a full
> seed + autorun drain costs ≈ 4.75k of GitHub's 5,000-per-hour GraphQL budget. **Budget one
> `/idc:autorun` e2e per GitHub API hour** — back-to-back runs will rate-limit. Poll `gh api
> rate_limit` (the `graphql` bucket) before re-running.

## The Pi runtime e2e — 4th sandbox — real `pi` + real LLM

The first three sandboxes are **claude-runtime only**. The IDC plugin also ships a **pi** runtime
adapter (experimental): long-lived IDC role *residents* on a coms-net hub under Bun + the `pi` coding
agent (`runtime/pi/scripts/idc-pi`). It has the most *automated* coverage of any runtime — the
`phase8-pi-*` smoke tests boot the real coms-net hub and drive the real launcher — but always
**hermetically with a fake `pi`** (no real agent, no LLM). The **Pi sandbox** closes the one untested
gap: a **real `pi` agent + real Gemini LLM** driving a real IDC stage end-to-end on a governed repo,
observed on real git/board.

Unlike the Autorun sandbox (which seeds *already-admitted* considerations), the Pi sandbox starts at a
**clean Think-start**: an empty board + `main` at the `pi-baseline` tag. The seeded "idea" is **one
crisp, un-admitted raw idea** (staged in `_idc-observability/ke-idc-test-repo-pi.seed-idea.md`) whose
buildable outcome is a tiny additive file under `scratch/`.

**The drive model (what the e2e actually established).** Under the production glass-wall guard
(`block`), an IDC pi role **authors content within its lane but cannot perform git finalization** —
that is reserved for the operator (see *Per-role authority* below). So the e2e runs each stage as a
single `idc-pi run <role> --print "<instruction>"` resident that does the **real LLM authoring**, and a
**scripted operator** (the harness) does the git/PR finalization the guard walls off — **loudly
labelled (`HARNESS-BRIDGE`) so the green drain is never oversold.** The GitHub board + files are the
handoff substrate between stages. The pipeline:

1. `run think` **drafts** the consideration + PRD + TRD (it correctly defers PR-opening to the operator).
2. **HARNESS-BRIDGE** commits those docs to a branch and opens the **Think PR** + the one `operator-action` gate.
3. The operator **merges** the Think PR (= admission) and closes the gate.
4. `run plan` **decomposes** the admitted consideration into a buildable goal-contract issue (native `gh issue`/`gh project`); **HARNESS-NORMALIZE** dedupes to one.
5. `run build-impl` **authors** the `scratch/` file + its test; **HARNESS-BRIDGE** opens the build PR; the operator merges it → the artifact lands on `main` → drain complete.

> **build-impl's language choice is stochastic** (~2:1 Python:shell vs the goal contract's POSIX
> shell). The `build-implementer.md` "Implement the goal contract's EXACT artifact" directive
> (shipped 3.2.0) improved it — the shell script landed in both green drains — but didn't determinize
> it; it still paired the shell script with a Python test in the dogfood (review passed on real
> verification).

### The harness scripts (operator-local, in `_idc-observability/bin/`)

- **`seed-pi-board.sh`** — repo-locked reset to clean Think-start: wipe board/PRs/branches + `git
  reset --hard pi-baseline` (+ `git clean -fd` to clear a prior run's untracked drafts), and (re)write
  the canonical raw-idea sidecar. Refuses any repo but `ke-idc-test-repo-pi`.
- **`run-pi-e2e.sh <label> [rung]`** — pins the environment, seeds the credential (value-blind), drives
  the run, captures to `_idc-observability/run-<label>.txt`. The derisking ladder of rungs:
  `think` (draft + bridge Think PR) → `think-plan` (+ merge + `run plan`) → `plan` (reuse an open Think
  PR) → `build` (build stage against an already-admitted consideration) → **`full`** (the whole drain) →
  `fleet` (the cooperative-peer stretch).
- **`verify-pi-drain.sh`** — read-only github-native assertions: Think PR **merged** (admission), build
  PR merged + `scratch/` file on `main`, build + planning lanes drained, gate closed, no orphan branches.

> **3.2.0 one-pin config — `PI_IDC_MODEL` umbrella + `PI_E2E_UMBRELLA=1`.** The launcher now takes a
> single `PI_IDC_MODEL` umbrella var (one provider-qualified string fills every role; precedence is
> per-role `PI_IDC_<ROLE>_MODEL` > umbrella > stock default), and `run-pi-e2e.sh` exposes a
> `PI_E2E_UMBRELLA=1` toggle that `unset`s the 7 per-role vars and sets only `PI_IDC_MODEL` — the
> dogfood proving a one-pin config boots the whole drain. Run it:
> `PI_E2E_UMBRELLA=1 PI_E2E_MODEL=google/gemini-2.5-pro bash …/run-pi-e2e.sh pi-umbrella full`.
>
> **Per-role-override gotcha.** The umbrella only fills a role if **no** per-role
> `PI_IDC_<ROLE>_MODEL` is set. Operator shells often carry `PI_IDC_THINK_MODEL` (etc.) → it
> overrides the umbrella → that role boots on a provider with no key → fails. That's why
> `PI_E2E_UMBRELLA=1` unsets them (and why `phase8-pi-model-umbrella.sh` uses
> `env -u PI_IDC_THINK_MODEL`). Real users hit this only if they already pin a per-role model.

### Why the env pins are mandatory (each verified 2026-06-19)

The launcher runs every resident under `env -i` + a `SAFE_ENV` allow-list (a role-cap isolation
measure — `idc-pi:35-42`), which **strips `GEMINI_API_KEY`**. So a present key in your shell never
reaches the resident `pi`. The pins handle this:

| Pin | Why |
|-----|-----|
| `PI_CODING_AGENT_DIR=<obs>/…/_pi-agent` | **The auth fix.** This var *is* allow-listed, so it survives `env -i`. `run-pi-e2e.sh` seeds `<dir>/auth.json` = `{"google":{"type":"api_key","key":"<GEMINI_API_KEY>"}}` (value-blind, mode 0600) and the resident reads its credential from there. The user's **global `~/.pi/agent/auth.json` is never touched**; the dir is deleted at teardown. |
| `PI_IDC_<ROLE>_MODEL` (all 7 roles) | **Provider-QUALIFY the string** (`google/gemini-2.5-flash`): a *bare* `gemini-2.5-pro` mis-resolves to the `github-copilot` provider and fails-closed. The launcher hardcodes claude/openai/deepseek defaults — not google — so pin every role (`THINK`/`PLAN`/`SEQUENCE`/`RECIRCULATOR`/`BUILD_IMPL`/`BUILD_REVIEW`/`BUILD_FINISH`). |
| `PI_E2E_PLAN_MODEL=google/gemini-2.5-pro` | **Plan is the unreliable run-mode stage** (below); pin it to a stronger model while think stays on cheap flash. |
| `PI_IDC_BUILD_REVIEW_PROVIDER=google` | `build-review` is the only role that gets a `--provider` flag and it defaults to `openai`; without this it would route a gemini model to the wrong provider. |
| `PI_IDC_GUARD_MODE` (default `block`) | Keep the **production** guard (faithful); the harness bridges the git finalization it reserves for the operator. (`PI_E2E_GUARD_MODE` overrides.) |
| `PI_IDC_HARNESS_REPO=<idc>/runtime/pi` | Test the **vendored** runtime (extensions/prompts/server), not the installed `~/dev/proj/pi-harnesses` symlink. |
| `PI_IDC_SESSION_DIR=<obs>/…/_pi-sessions/<label>` | Capture per-resident transcripts into the snapshot tree. |

> **flash is unreliable for build-impl — pin the build roles to pro.** `gemini-2.5-flash` repeatedly
> returns `stopReason=error` / `output=0` ("An unknown error occurred") at build-impl's claim step
> (~20k ctx); plan/sequence/think ran fine on flash, but build did not. Set
> `PI_E2E_MODEL=google/gemini-2.5-pro` — `run-pi-e2e.sh` uses it as `DRAIN_MODEL`, which fills every
> role, build included (`run-pi-e2e.sh:47`). This is exactly the friction the `PI_IDC_MODEL` umbrella
> (3.2.0) smooths.

> The adapter skill (`skills/idc-adapter-pi/SKILL.md`) is now truthful about this: `idc-pi`'s
> `role_model()` (`runtime/pi/scripts/idc-pi:899-907`) **hardcodes a per-role stock default,
> overridable per role via `PI_IDC_<ROLE>_MODEL`** — exactly the mechanism these pins use.

### Per-role authority under the production guard (run-mode A) — the load-bearing finding

Verified empirically + in `runtime/pi/extensions/idc-role-harness.ts:352-371`. Under `idc-pi run
<role>` (a single docs/source-scoped resident, guard `block`):

- **The git lifecycle is walled.** `think`/`plan`/`sequence`/`recirculator`/`build-impl` have **all**
  git ops blocked (`git checkout -b` → *"outside think authority"*); `build-review` is fully read-only;
  **`build-finish`** is the *only* role with git authority — `git commit`/`git merge`/`gh pr merge`
  (finalization) are allowed, but `git push` / branch-create are **not**. So **no single role can do the
  full open-a-PR lifecycle** (branch+push is blocked for everyone, build-finish included) — the
  operator/harness bridges it.
- **But the GitHub tracker is native.** `gh issue create` / `gh project item-*` are a **separate
  category, NOT guard-blocked** (one plan run drove 20 issue-creates + 100 project calls, zero blocks).
  The seam is precise: *the git/PR lifecycle is walled; the GitHub tracker is free.*
- **Plan is the unreliable run-mode stage.** Same prompt, run to run: flash produced **5 duplicate**
  unfielded issues one run and **0** the next (it narrated its tracker commands instead of executing
  them; a body control-char escaping error). Pinning plan to `google/gemini-2.5-pro` produced **exactly
  one** properly-fielded buildable issue. The harness **dedupes** plan-authored duplicates but **never
  fabricates** a buildable issue when plan made none — that would be doing plan's job, not git mechanics
  (a zero is a clean blocked-stop).

This is direct evidence for the **#66 L1/L4** debts (no parallel build pool; no autonomous drain loop):
a run-mode resident can operate the tracker but cannot self-drive the git/PR lifecycle, nor do it
reliably/idempotently, headlessly. **Scope:** all of the above is `idc-pi run <role>` (mode A); whether
the `fleet` topology wires a git-capable finalizer is a separate question (the `fleet` rung / mode B).

### The captured green drain

3.2.0 produced **two captured green drains, both on `google/gemini-2.5-pro`**:

- **`pi-base6`** — `run-pi-e2e.sh pi-base6 build` (the **build** rung, pro): build-impl + build-review
  against an already-admitted consideration → harness-opened build PR → merged →
  `verify-pi-drain.sh` **PASS (7/7)**; the `scratch/` artifact runs and prints `ke-idc-test-repo-pi`
  (exit 0).
- **`pi-umbrella2`** — `PI_E2E_UMBRELLA=1 PI_E2E_MODEL=google/gemini-2.5-pro run-pi-e2e.sh
  pi-umbrella2 full` (the **full** drain, one-pin umbrella config): un-admitted idea → pi-drafted,
  harness-opened Think PR → merged (admission) → pro-Plan created the buildable issue → pro build-impl
  authored `scratch/print_repo_name.sh` + its test → harness-opened build PR → merged →
  `verify-pi-drain.sh` **PASS (7/7)**.

Both audited against the full capture + per-resident transcripts + live git/board (no hidden failures,
no orphans). The audit also caught + fixed three real harness bugs (untracked-draft cleanup in the
seed; a `verify` orphan-count `grep -vc … || echo 0` that emitted `0\n0` and false-FAILed a clean
drain; a field-id regex that truncated hyphenated node ids and silently dropped board field-writes) —
a reminder to keep harness assertions red-when-broken.

> **Audit verdict logs — build-review can confabulate.** `build-review` may narrate `git mv` / `edit`
> / test-runs in its verdict `verification_log` that it never ran (it's read-only on source/tests and
> can't). On a good artifact the PASS was still correct, but a confabulated log can yield a **false
> PASS on a bad artifact** → a bad merge through the MG-B gate. The `build-reviewer.md` "Verification
> evidence must be REAL — never confabulate" directive (shipped 3.2.0) forbids it (validated: the
> dogfood's review actually ran `uv run pytest`); still, **audit verdict logs against the transcript**
> — don't trust them blind.

### Fleet teardown + the headless-fleet limitation (mode B, the stretch)

- **Fleet teardown.** `idc-pi fleet` **does not self-terminate on board drain** — the supervisor races
  child exits and stops only on a child exit or a signal. The harness owns completion-detection (poll
  until the `scratch/` artifact is on `origin/main`) then **SIGTERMs the supervisor** (the backgrounded
  `idc-pi fleet` pid, which `exec`s the bun supervisor in place → clean `teardown(0)`).
- **Completion predicate is github-native.** `idc_autorun_drain.py` reads a filesystem `TRACKER.md` and
  is **useless against a github-backend board**; the run/verify scripts query GitHub directly.
- **Headless-fleet idea delivery — blocked-stop (live-confirmed).** A headless `idc-pi fleet think`
  **boots correctly** (the hub comes up and the `think` resident registers on coms-net), but then `think`
  **idles with no reachable input source**, so a headless fleet cannot be handed a raw idea:
  - no stdin/pane headlessly (the interactive operator path);
  - coms-net inbound-to-`think` is **structurally blocked** — `think` is the river HEAD
    (`RIVER_ORDER[0]`, `idc-role-harness.ts`), the glass-wall ACL allows sends **downstream only** (so
    nothing may send *to* think), an external "operator" is a non-role **"unknown sender" → fail-closed
    deny**, and registering *as* a river role requires the launcher's in-memory **HMAC role-cap**.
  - **What a live operator would need:** drive the fleet **interactively** — `idc-pi open-all` (or
    `idc-pi open think …`) in cmux/iTerm panes — and type the idea into the `think` pane's TUI; the
    coms-net peers then handle the downstream Think→Plan→Build handoffs. The fully-headless drain path
    is **mode A** (per-stage `run <role> --print` + board handoff), which is what the captured green
    drain used. (Whether the fleet's cooperative build phase wires a git-capable finalizer that mode A's
    single residents lack is a separate, still-open question that needs the interactive path to test.)

> **GraphQL-budget caveat.** The github backend is GraphQL-heavy. Budget **one Pi drain per GitHub API
> hour**; poll `gh api rate_limit` (the `graphql` bucket) before re-running.

## Golden rule

**IDC commands act on the current session's working directory** (they run
`git rev-parse --show-toplevel` first; there is **no `--repo` flag**). The session must live in the
repo being scaffolded.

## Where to run Claude Code (the recommended dev loop)

**Run Claude Code _inside the sandbox repo_, and point it at your dev clone of the plugin.** An
*inline* `/idc:*` from a session rooted in this plugin-source repo would scaffold *this* repo, not
the sandbox — so the sandbox session must be rooted in the sandbox:

```bash
cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-install
claude --plugin-dir /Users/jeremy/dev/proj/idc-workflow      # load THIS dev checkout for the session
```

> **The lead agent drives this itself — no human needs to open the sandbox.** A separate `claude`
> process whose cwd IS the sandbox targets the sandbox, so spawn it headlessly from anywhere (incl.
> a session rooted in this plugin repo, or a teammate/Codex):
> ```bash
> # one-time: printf '{"mcpServers":{}}' > /tmp/empty-mcp.json
> (
>   # Inherit auth by default: this machine runs the nested claude via a VALID
>   # ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL, so stripping it forces a fallback to a stale
>   # OAuth cache → 401. Set IDC_STRIP_AUTH=1 ONLY on a stale-key "Invalid API key" death.
>   [ "${IDC_STRIP_AUTH:-0}" = "1" ] && unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
>   cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-install && \
>   claude --plugin-dir /Users/jeremy/dev/proj/idc-workflow \
>          --strict-mcp-config --mcp-config /tmp/empty-mcp.json \
>          --permission-mode bypassPermissions -p "/idc:doctor" < /dev/null
> ) > /Users/jeremy/dev/sandbox/_idc-observability/run-<label>.txt 2>&1
> ```
> **Two spawn traps** (handled in the command above): **(1) auth** — which credential is valid flips
> over time (rotations vs OAuth refresh), so the nested session inherits auth by default; set
> `IDC_STRIP_AUTH=1` to opt back into the old strip-to-OAuth fallback ONLY on a stale-key `Invalid API
> key` death (the inline comment in the block above explains why a blanket `unset` *causes* the 401 on
> this machine). **(2) MCP** — without `--strict-mcp-config --mcp-config /tmp/empty-mcp.json` it hangs
> ~6 min booting your full global MCP set (IDC never uses MCP). Capture with `> file 2>&1` and check
> `wc -c` > 0; `tee` buffers until the session exits, so a live capture reads 0 bytes mid-run.
>
> Each `-p` run is a fresh session (edited markdown loads automatically; put interactive choices in
> the prompt). See the root `CLAUDE.md` "Local end-to-end testing" section for the full loop.

- `--plugin-dir` loads the plugin straight from your working tree, so you test the code you're
  editing — not the installed marketplace copy (`~/.claude/plugins/marketplaces/idc-workflow`, a
  separate clone).
- Convenience alternative for sustained dev: symlink the marketplace path to this checkout once
  (`ln -s /Users/jeremy/dev/proj/idc-workflow ~/.claude/plugins/marketplaces/idc-workflow`, after
  moving the original aside), then plain `cd <sandbox> && claude` always runs dev code. Revert when
  done.
- Caveat: `--plugin-dir` (and the symlink) load the plugin directly, which **sidesteps the per-repo
  install step**. To faithfully test the *released* from-scratch install — the
  `claude plugin install idc@idc-workflow --scope project` path this hardening changed — run the
  **release-fidelity lane** instead: from the sandbox, `claude plugin install idc@idc-workflow
  --scope project`, then `/idc:doctor`, and confirm `~/.claude/settings.json` has the `idc` key set
  to `false` (the install registers it disabled there, not `true`). Use the installed marketplace
  copy, not `--plugin-dir`, for that lane.

Use a session **in this plugin-source repo** only for *editing* the plugin and running its hermetic
unit suite `bash tests/smoke/run-all.sh` (filesystem backend, no GitHub, fast). After editing
**command/skill markdown**, restart the sandbox session (or refresh the plugin cache) so new
definitions load — Claude caches those at session start. Python under `scripts/` is read fresh each
call, so script edits are picked up live.

## Why the version-keyed cache can serve stale code (and how to dodge it)

Claude Code keeps **three** copies of the plugin, and they do not move in lockstep:

- the **marketplace clone** (`~/.claude/plugins/marketplaces/idc-workflow`) — a git clone that
  `claude plugin marketplace update` fast-forwards to `main` HEAD;
- the **version-keyed cache** (`~/.claude/plugins/cache/idc-workflow/idc/<version>/`) — the copy
  that `/idc:*` commands and `${CLAUDE_PLUGIN_ROOT}` actually run from, rebuilt **only when the
  `plugin.json` version string changes**;
- your **dev checkout** (this repo), loaded only via `claude --plugin-dir`.

Consequence: pulling `main` into the marketplace clone does **not** refresh the cache when the
version is unchanged, so `${CLAUDE_PLUGIN_ROOT}` can resolve to **stale cached code** even though
the clone is current — and in a single session it can resolve to the stale cache for one command
and the fresh tree for another. This is exactly what invalidated the 2026-06-14 install test
(cached `2.0.0` templates vs a fast-forwarded clone). Only `claude --plugin-dir <this-checkout>`
reliably loads uncached latest code for a dev loop.

**Releasing (maintainer note).** Because of the above, a `main`-branch merge does **not** reach
installed users until the plugin **version is bumped and republished**: bump
`.claude-plugin/plugin.json` *and* the matching `.claude-plugin/marketplace.json` entry in
lockstep (the `scripts/idc_release_check.py` guard, run by `lint-references.sh`, fails the build
otherwise), then cut the tag with `claude plugin tag` — it creates `idc--v<version>` and
validates that `plugin.json` and the enclosing marketplace entry agree (add `--push` to publish).
An unchanged version makes `claude plugin update` a silent no-op.

In short: **every shippable change (`commands/`, `skills/`, `agents/`, `scripts/`, `templates/`,
`.claude-plugin/`) MUST bump the version** — without it the version-keyed cache serves stale code
and install/update tests lie. Verify a release actually took: after the version is on `main` and
you run `claude plugin marketplace update`, a fresh
`~/.claude/plugins/cache/idc-workflow/idc/<new-version>/` directory appears (the cache is keyed by
version — you can confirm by `ls`-ing that path and checking its `templates/tracker-config.yaml`
carries the new contract). The shipped `/idc:doctor` check 7 surfaces this staleness to end users.

## Observability — the "flight recorder"

Lives **outside** the sandboxes at `/Users/jeremy/dev/sandbox/_idc-observability/` so
teardown/uninstall/revert never wipe the evidence.

- **Automatic:** each sandbox repo has a `.git/hooks/post-commit` that snapshots **every commit**
  (label `auto`). Since IDC commits once per command, you get one snapshot per command for free. The
  hook always exits 0 — it can never block a commit.
- **Snapshots** land in `_idc-observability/<repo-name>/NNN-<label>-<shortsha>/`, numbered in order.
  Each contains:
  - `meta.txt` — timestamp, label, branch, sha, commit subject
  - `change.patch` (`git show HEAD`) and `uncommitted.diff` (`git diff`)
  - `status.txt`, `tracked-files.txt`
  - `receipt-verify.json` (+ `.err`) — drift vs `docs/workflow/install-receipt.yaml`, via the
    plugin's own `idc_receipt_check.py verify`
  - `github/{issues,prs,board}.json` — GitHub state (board only once a github-backend
    `tracker-config.yaml` exists)
  - `transcript.txt` — path to that session's full Claude Code JSONL transcript (complete agent trace)
- **Three helper commands** in `/Users/jeremy/dev/sandbox/_idc-observability/bin/` (full path, or add
  to `PATH`):
  - `ke-snap <repo> baseline` — capture the clean state **before** the first IDC command
  - `ke-snap <repo> failure` — capture state when a command errors **without** committing
  - `ke-snap-diff <snapshotA> <snapshotB>` — what changed between two snapshots (meta, added/removed
    files, receipt drift, issue/PR deltas)

## Conformance checks (the plugin's own — reused, not reinvented)

```bash
PLUGIN=~/.claude/plugins/marketplaces/idc-workflow    # or your --plugin-dir checkout
/idc:doctor                                           # in-session PASS/FAIL/SKIP table
python3 "$PLUGIN/scripts/idc_receipt_check.py" verify --repo . --json
bash "$PLUGIN/tests/smoke/run-all.sh"                 # hermetic filesystem-backend suite
```

## A typical "validate a change" loop

1. Edit plugin code in this repo; run `bash tests/smoke/run-all.sh` for a fast hermetic check.
2. `cd` into the relevant sandbox; open a session with `--plugin-dir` at this checkout.
3. `ke-snap . baseline`.
4. Run the IDC command(s) under test — each commit auto-snapshots.
5. `ke-snap-diff <pre> <post>` to see exactly what changed; open `change.patch` / the `transcript.txt`
   path for detail.
6. On a mid-run error: `ke-snap . failure`, then read the transcript.

## The e2e post-condition gate (janitor scan + API-cost delta)

Every spawned e2e wave should end with a **post-condition gate** so "the drain finished" also means
"the finished board↔git state is coherent" and "the API cost was in budget" — the two guarantees the
pre-#103 loop lacked (design §E.3, audit RC6). The dev helper
[`docs/dev/e2e-postcondition-gate.sh`](e2e-postcondition-gate.sh) wraps any wave:

```bash
# github-backend sandbox (drives the wave, then gates it):
bash docs/dev/e2e-postcondition-gate.sh \
  --repo /Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun \
  --backend github --owner llamallamaredpajama --project 10 \
  --report /Users/jeremy/dev/sandbox/_idc-observability/run-<label>-gate.json --label <label> \
  -- bash /Users/jeremy/dev/sandbox/_idc-observability/bin/run-autorun-e2e.sh <label>

# bare post-condition check on the CURRENT state (no wave) — omit everything after `--`.
```

It snapshots `gh api rate_limit` (graphql + core) before and after, runs the shipped
`scripts/idc_git_janitor.py` (the same reconciler `/idc:janitor` uses) as the coherence oracle,
`git fetch --prune`s first so the scan sees **live** remote reality (an un-pruned clone carries stale
`origin/*` tracking refs for branches already deleted on the remote — those would otherwise show as
phantom remote-branch findings), writes a combined JSON report, and **exits non-zero on incoherence or
a wave failure** — so a bad drain fails the run instead of looking green. The `graphql_delta` in the
report is the per-run API cost (regression-catches the §C item-id-cache / rate-limit fixes; a healthy
drain's per-status-write board-read cost is ~0 with the item-id cache on — see
`run-u6-e2e-rebuild-summary.md`).

> **GraphQL-budget caveat still applies:** the gate itself is cheap (~5 graphql/scan), but the *wave*
> it wraps is not — budget one full `/idc:autorun` drain per GitHub API hour (§ the autorun sandbox).

## Teardown / reset

Disposable. Reset a repo with `/idc:uninstall --delete-board` inside its session (reverses init +
removes its board), or delete the GitHub repo
(`gh repo delete llamallamaredpajama/ke-idc-test-repo-install --yes`) and the local folder and
re-clone.

## Guardrails

Throwaway — experiment freely. Do **not** deploy anything or touch real cloud resources; the cloned
project content below each sandbox's banner is fixture only. Neither sandbox can reach the real
`knowledge-engine` repo or its board.
