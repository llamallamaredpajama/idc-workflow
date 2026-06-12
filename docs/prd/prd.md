# Product Requirements — IDC Workflow Plugin

**Upstream trace:** lifecycle requirements (§4 below) are admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at `main` 95d7ab4, PR #12). The v0.1.0 baseline (§3) is summarized from `README.md` and `CHANGELOG.md`, not re-litigated.

> This is the first PRD authored for this repository (chain-bootstrap admission). It states what the IDC Workflow plugin is, who it serves, the existing shipped surface as a fixed baseline, and the new plugin-lifecycle requirements this admission adds.

## 1. Purpose

The IDC Workflow plugin packages **IDC** — the Iterative Development Chain — as an installable [Claude Code](https://claude.com/claude-code) plugin: a governed, tracker-driven, multi-agent workflow that carries software work from a raw idea to merged, reviewed code (per `README.md`). Its defining property is **traceability**: every line of built code walks back through a pillar plan, a master plan, an architecture spec, and a product requirement, and nothing in the plan drifts silently out of sync (per `README.md`; `docs/architecture.md §Required trace`).

The product's job is to install that workflow **cleanly and per-project** into a target repository and to keep it auditable over the repository's life. Today the plugin can be installed (`/idc:init`) but has **no exit path and no update path** (per consideration §Frame). This PRD adds those two lifecycle capabilities plus the shared substrate they require.

## 2. Users

The plugin's users are **operators** — the engineer who installs IDC into a repository and runs the role commands. Operators are not the plugin's developers; they consume the shipped commands, agents, and skills. The product's lifecycle obligations are written from the operator's seat:

- An operator must be able to install IDC into a repo, **remove it cleanly later**, and **update it safely** after a new plugin version ships, without hand-editing scaffold files or guessing which files IDC owns.
- Destructive steps must never surprise the operator: removals are announced, reversible where possible, and gated on explicit confirmation where permanent (per consideration §Named Ideas: uninstall).

## 3. Existing surface — v0.1.0 baseline (summarized, not re-litigated)

The shipped v0.1.0 surface is the fixed baseline this admission builds on. It is **not** reopened here (per `CHANGELOG.md` 0.1.0; `README.md`):

- **8 commands** — five role entry points (`/idc:think`, `/idc:plan`, `/idc:sequence`, `/idc:build`, `/idc:ripple`) plus `/idc:autorun`, `/idc:init` (idempotent per-repo scaffold + tracker provisioning), and `/idc:doctor` (read-only five-check verifier).
- **23 agents** and **38 skills** — role orchestrators, teammate roleplayers, and the reusable `idc-skill-*` substrate, including Codex-native adapters.
- **Per-project install model** — `/idc:init` scaffolds `WORKFLOW.md` + `docs/workflow/` from `templates/`, provisions (or links) a GitHub Projects v2 board with the eight IDC tracker fields, and enables the plugin **for that project only** by writing `enabledPlugins["idc@idc-workflow"]=true` into `.claude/settings.json` (per `commands/init.md`; `docs/installing.md`).
- **Two tracker backends** — `github` (Projects v2 board) and `filesystem` (a root `TRACKER.md`), hidden behind the tracker-adapter dispatch skill (per `docs/architecture.md §The tracker contract`).
- **Codex runtime support** — five `codex-idc-*` adapters wired by `scripts/install-codex.sh`, which records prior state and offers `--revert` (per `README.md §Codex support`).

`/idc:init` already carries an **idempotency contract** (anything present is left untouched and reported `skipped-existing`) that the new lifecycle commands inherit and extend (per `commands/init.md`).

## 4. Lifecycle requirements (this admission)

All requirements below are admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md`. Operator sequencing preference (consideration §Next Role Questions) is **two trains, uninstall first**; the master plan realizes this as Phase 1 (R1 + R2) and Phase 2 (R3 + R4).

### R1 — Install receipt (shared substrate)

`/idc:init` MUST write a **committed repo file** that lists every file it stamps plus a content fingerprint of each file **as written** (post token-substitution, not the template) (per consideration §Named Ideas: install receipt; §Engineering Implications). The receipt is the shared substrate both later commands consume: `/idc:upgrade` uses it to prove a file untouched; `/idc:uninstall` uses it as the removal manifest ("only delete what you created"). A committed file (rejected alternative: an untracked machine-local file) is required so the substrate travels with clones and is covered by git state checks.

### R2 — `/idc:uninstall`

A new command MUST remove all of IDC's repo footprints safely (per consideration §Named Ideas: uninstall):

- **Phased, idempotent mirror of `/idc:init`.** Re-runs report `skipped-absent`; nothing is half-removed.
- **Work products archived first** to an untracked repo-root `idc-archive-<date>.tar.gz`, whose path is always announced.
- **All repo footprints removed in ONE revertable commit** — scaffold, configs, `TRACKER.md` (filesystem backend only), and the `enabledPlugins` key stripped while preserving every other key in `.claude/settings.json`. The removal list is **receipt-driven**, with a hardcoded footprint list as fallback.
- **GitHub untouched by default.** Opt-in `--close-issues` (reversible) and `--delete-board` (permanent; requires typed confirmation). **Issue deletion is never offered.**
- **Two-layer preflight.** (a) Clean git state for tracked files, exempting prior `idc-archive-*.tar.gz` so re-runs don't self-block; (b) a board in-flight check that reports orphaning plainly and requires explicit confirmation (warn-and-confirm, not a hard block).
- **Machine-global surfaces are out of scope.** The closing summary names `claude plugin uninstall` and `scripts/install-codex.sh --revert` for the operator to run separately (per consideration §Context Notes).

### R3 — `/idc:upgrade`

A new command MUST refresh stamped files after a plugin update, safely (per consideration §Named Ideas: upgrade):

- **Receipt-only detection (v1).** Silently re-stamp ONLY files the receipt proves untouched; any customized file gets **show-diff-and-ask**. Pre-receipt installs get diff-and-ask for every file, **one time**, then the run ends by writing a fresh receipt (**receipt graduation**).
- **Files only; never mutates the board.** Upgrade MUST compare the live board schema against the new plugin version's expected schema and **report drift explicitly** — never silently, and never via board-migration machinery (rejected).
- **Re-run to repair.** Each step checks current state; re-runs report `skipped-already-current`. The receipt is rewritten ONLY at the end of a successful run, so a half-done upgrade can never look finished.
- **Surfaces the plugin cache-refresh advisory.** Upgrade MUST NOT silently assume the running plugin is the newest version; it surfaces the known cache quirk (a repo-edited plugin needs `claude plugin uninstall && install` because the install cache does not track the working tree — per `docs/dev/2026-06-12-v0.1.0-release-report.md` line ~140).

### R4 — `docs/installing.md` "Updating" section

`docs/installing.md` has no updating section today (per consideration §Context Notes). This admission's Train 2 MUST add one documenting `/idc:upgrade` and the cache-refresh advisory.

## 5. Out of scope

- Machine-global plugin removal and Codex-link revert (operator runs `claude plugin uninstall` / `install-codex.sh --revert` separately — per consideration §Context Notes).
- Board **migration** machinery — upgrade reports schema drift but does not mutate the live board (real risk to in-flight waves; rejected — per consideration §Named Ideas: upgrade scope).
- GitHub issue **deletion** — never offered by uninstall.
- Compare-against-prior-version-templates and layered all-three upgrade detection — rejected for v1 (per consideration §Named Ideas: upgrade).

## 6. Cross-cutting safety requirement

The fingerprint compare that both upgrade and receipt-driven uninstall depend on is **safety-critical**: it MUST fail toward **asking** (show-diff-and-ask / confirm), never toward a silent re-stamp or silent delete (per consideration §Engineering Implications). The architectural invariants that make this true — receipt location, fingerprint method, customized-file semantics, and failure-path postures — are specified in `docs/specs/master-architectural-spec.md §3` (this admission).
