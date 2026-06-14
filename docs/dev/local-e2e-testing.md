# Local end-to-end test setup for the IDC plugin

> **Operator-local note.** This describes a live test harness on **this machine** (absolute paths
> under `/Users/jeremy/dev/sandbox/`). It is a development aid for iterating on the plugin, not part
> of the shipped plugin. Paths are specific to this workstation.

There is a live, isolated harness for exercising the IDC plugin's full lifecycle
(`/idc:doctor → init → think → plan → build`, and `/idc:update`) against realistic repos, with
automatic observability — without touching any real project.

## The two sandbox repos

Both are throwaway clones of an unrelated real project (`knowledge-engine`), used purely as a
realistic codebase fixture. Each has its **own private GitHub repo** and **cannot reach** the
original project or its board.

| | Path | GitHub remote | IDC state | Tests |
|---|---|---|---|---|
| **Install** | `/Users/jeremy/dev/sandbox/ke-idc-test-repo-install` | `llamallamaredpajama/ke-idc-test-repo-install` (private) | **plugin NOT enabled** (blank slate) | from-scratch install: `claude plugin install idc@idc-workflow --scope project` → confirm `~/.claude/settings.json` has `idc@idc-workflow: false` (global off-switch) → `/idc:doctor` → `/idc:init` → `/idc:think` → `/idc:plan` → `/idc:build` |
| **Update** | `/Users/jeremy/dev/sandbox/ke-idc-test-repo-update` | `llamallamaredpajama/ke-idc-test-repo-update` (private) | **plugin enabled** | update path: `/idc:init` first (lays down scaffold + receipt), then `/idc:update` |

Each repo's own `CLAUDE.md` / `AGENTS.md` opens with a "IDC TEST SANDBOX" banner repeating this, so
any agent dropped into them is oriented automatically.

## Golden rule

**IDC commands act on the current session's working directory** (they run
`git rev-parse --show-toplevel` first; there is **no `--repo` flag**). The session must live in the
repo being scaffolded.

## Where to run Claude Code (the recommended dev loop)

**Run Claude Code _inside the sandbox repo_, and point it at your dev clone of the plugin.** You
cannot drive `/idc:*` from a session rooted in this plugin-source repo — it would scaffold *this*
repo, not the sandbox. So:

```bash
cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-install
claude --plugin-dir /Users/jeremy/dev/proj/idc-workflow      # load THIS dev checkout for the session
```

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

## Teardown / reset

Disposable. Reset a repo with `/idc:uninstall --delete-board` inside its session (reverses init +
removes its board), or delete the GitHub repo
(`gh repo delete llamallamaredpajama/ke-idc-test-repo-install --yes`) and the local folder and
re-clone.

## Guardrails

Throwaway — experiment freely. Do **not** deploy anything or touch real cloud resources; the cloned
project content below each sandbox's banner is fixture only. Neither sandbox can reach the real
`knowledge-engine` repo or its board.
