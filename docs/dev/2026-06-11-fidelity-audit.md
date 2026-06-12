# Independent Fidelity Audit — idc plugin migration

- **Date:** 2026-06-11 (run overnight 2026-06-10 → 11)
- **Auditor:** independent fidelity auditor (Fable 5), fresh eyes — wrote none of the audited work
- **Baseline:** `e206932` (verbatim pre-rewrite snapshot) → audited HEAD `2a79053`
- **Method:** 8 parallel read-only audit slices (4 sweep-fidelity slices over the full `e206932..HEAD` diff for agents/ + skills/ + commands/, 1 mechanical-integrity, 2 new-content-correctness, 1 public-scrub), followed by independent re-verification of every Blocker/Major claim directly against HEAD. install-codex.sh was traced through 13 sandboxed failure scenarios under `/tmp` with overridden `HOME` (real `~/.agents`/`~/.claude` never touched); the linter was sandbox-tested against 13 adversarial fixtures on both BSD and GNU toolchains; CI steps were re-executed locally.

**Audit-race note:** the tasking described commands/ + codex adapters as uncommitted working-tree state with 2 known dangling linter findings. Mid-audit, B5's finalization landed (`1ffb987`, `2a79053` and siblings): the working tree is now clean, everything below is committed, and `scripts/lint-references.sh` reports **CLEAN (75 files scanned), exit 0** — the 2 sanctioned dangling findings were resolved by normalizing them to bare + `lint-allow`. All findings below were re-verified against HEAD `2a79053` after the dust settled; nothing here is stale. Former "provisional" status on B5's files is lifted.

**Headline:** the sweep's semantic core held. Across all 58 swept files, every slice independently verified — with token-level old-vs-new comparison — that verdict enums (`NO_RIPPLE|MINOR_AUTONOMOUS|GATED|MAJOR_GATED`), severity ladders (`Blocker/Major/Minor/Nit` + `critical→Blocker…` mappings), alias labels (BS-/CS-/RS-/CR-/WD-/WM-/QS-/PR-/OR-*), gate semantics (Engineer Gate, `gate_mode` enums, four-condition MINOR_AUTONOMOUS gate, Q-rip-3 scope rules), write-surface/forbidden-write lists, tool lists, mode/subtype parameters, tracker op names/error identifiers, and the idc-workflow authority table are **byte-identical** to the snapshot. All frontmatter `name:` fields are bare; zero `idc:idc:` doubles; all T7/T10/T12 inlinings preserve the cited doctrine. The real problems are at the edges: two publish-gating Blockers (neither a sweep regression), strict-YAML frontmatter, a cross-runtime namespacing gap in the Codex adapters, and a handful of over-applied path transforms.

---

## BLOCKER

### BLK-1 — Git history ships the personal email and the entire unscrubbed private original
- **Evidence:** `git log --format='%ae' | sort -u` → the author's personal email on every commit. Commit `e206932` is the repo's second commit and contains the verbatim pre-scrub originals (all Knowledge-Engine/KE content, personal paths). Anyone can `git checkout e206932` and read everything the file-level scrub removed.
- **Why Blocker:** publishing this history makes the whole Phase B scrub cosmetic and leaks a personal email.
- **Fix:** before the public flip, rewrite/squash history (fresh orphan root or filter-repo) AND set a noreply author. Verify Task #12's "scrub" step explicitly includes **history** rewrite, not just working-tree scrub. Not a sweep regression — a publish-pipeline gap.

### BLK-2 — `scripts/install-codex.sh --revert` destroys user data when `~/.agents/skills` was originally a real directory (or a plain file)
- **Evidence:** `scripts/install-codex.sh:72` runs `rm -rf "$AGENTS_SKILLS"` unconditionally BEFORE the `case "$kind"` branch; the `realdir` branch (:79-80) then prints "removed our links" — but the rm already deleted **everything**, including user-owned real skill dirs that install had deliberately warn-skipped ("never clobber" guard at :42-44). Empirically reproduced in sandbox (scenario S4): user's `my-real-skill/SKILL.md` deleted on revert. Companion bug: a plain **file** at `~/.agents/skills` is misclassified as `absent` (`record_state_once` :58-61 tests only `-L`/`-d`), install errors-but-exits-0, and a later revert deletes the user's file (S11).
- **Fix:** in the `realdir`/unknown branches, delete only `[ -L ]` entries (or exactly the link names recorded in `$STATE`); add an `elif [ -e ]` plain-file branch that aborts install with exit 2. Never blanket `rm -rf` before classifying.

---

## MAJOR

### MAJ-1 — 11 files have strict-YAML-invalid frontmatter (8 agents + 3 commands)
- **Evidence (independently re-verified with PyYAML at HEAD):** `agents/idc-autorun.md`, `agents/idc-role-bootstrap-researcher.md`, `agents/idc-role-merge-deconflictor.md`, `agents/idc-role-phase-close-adversarial-reviewer.md`, `agents/idc-role-plan-reviewer.md`, `agents/idc-role-ripple-orchestrator.md`, `agents/idc-role-subphase-pillar-planner.md`, `agents/idc-think.md` — unquoted `description:` plain scalars containing `: ` (e.g. `…tracker chain: all PLANNING…`, `` `team_name: "<idc-team>"` ``) → "mapping values are not allowed here". `commands/autorun.md`, `commands/plan.md`, `commands/think.md` — `argument-hint:` values starting with `[` or continuing after a closed quote → whole frontmatter unparseable (description lost too).
- **Mitigation observed:** the live harness parser is lenient (these exact descriptions loaded in-session). But any strict consumer — marketplace indexers, gray-matter/js-yaml tooling, future harness versions — rejects the files wholesale. Pre-existing in the originals (not a sweep regression), but it ships.
- **Fix:** quote each offending `description:` / `argument-hint:` value (or `>-` block scalar). 11 one-line edits.

### MAJ-2 — Codex adapter bodies now carry `idc:`-namespaced slugs the Codex runtime cannot resolve (needs an orchestrator ruling — brief gap, not freelancing)
- **Evidence (re-verified at HEAD):** `skills/codex-idc-build/SKILL.md:241-243` — ORIGINAL `Skill(skill="idc-skill-tracker-adapter", …)` ×3 → CURRENT `Skill(skill="idc:idc-skill-tracker-adapter", …)` ×3; `skills/codex-idc-plan/SKILL.md:161,164,169,172,182,184,186,190,196` — 9 more `Skill(skill="idc:…")` invocation literals; plus namespaced sibling-handoff refs (`idc:codex-idc-plan` at codex-idc-think:103, `idc:codex-idc-ripple`/`idc:codex-idc-sequence`/`idc:codex-idc-think` at codex-idc-plan:93/158/207/227 and in ripple/sequence substrate tables); same class at `skills/idc-skill-filesystem-tracker-implementation/SKILL.md:264` ("a **Codex** parent calling `Skill(skill="idc:idc-skill-filesystem-tracker-implementation"…)`").
- **Why it matters:** per spike fact 12 / R11, Codex reads these files as raw text and resolves skills by **bare directory name** through `~/.agents/skills` symlinks — the `idc:` namespace exists only in the Claude harness. The originals were bare and carried the "Skill slugs resolve via each runtime's substrate" disclaimer (still present at codex-idc-ripple:26). B5 followed T1's letter — the brief exempted codex bodies from `${CLAUDE_PLUGIN_ROOT}` but never from slug namespacing. ≈25 lines across 5 files.
- **Fix:** rule needed, then one mechanical pass — either revert invocable slugs in `codex-idc-*` bodies (and Codex-runtime examples elsewhere) to bare form, or dual-form them (`` `idc-skill-X` (Claude: `idc:idc-skill-X`) ``). Sibling nit folded in: the cleanup-manifest header templates (`# Codex cleanup manifest — idc:codex-idc-build` at build:415, plan:249, ripple:185, sequence:283, think:111) are Codex-emitted artifacts and should keep bare names.

### MAJ-3 — Path transforms over-applied to never-migrated / retired files, creating false "ships with the plugin" claims (7 sites)
All verified missing on disk at HEAD:
1. `skills/idc-skill-plan-review/SKILL.md:452` and `skills/idc-skill-plan-review-base/SKILL.md:142` — ORIGINAL `Source ADAPT: ~/.claude/skills/code-review-custom/SKILL.md` → CURRENT `${CLAUDE_PLUGIN_ROOT}/skills/code-review-custom/SKILL.md`. `skills/code-review-custom/` does not exist — it's a personal skill that was never migrated, and plan-review-base:8 calls its inherited pieces "fenced as load-bearing".
2. `skills/idc-skill-change-order-shape/SKILL.md:8` and `:229` — donor `~/.claude/skills/idc-ripple/SKILL.md` → `${CLAUDE_PLUGIN_ROOT}/skills/idc-ripple/SKILL.md`. The retired umbrella skill doesn't exist in the plugin; no lint-allow, no debts entry.
3. `skills/idc-skill-canonical-doc-authoring/SKILL.md:95` and `skills/idc-skill-considerations-admissibility-review/SKILL.md:109` — "Loaded via the Skill tool by `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-engineer/SKILL.md`" — consolidated into codex-idc-plan; dir doesn't exist. (lint-allow present, but the sanctioned handling was bare-name, not a concrete shipped-path claim in an operative "loaded by" sentence.)
4. `skills/codex-idc-sequence/SKILL.md:203` — CR-5 row: ORIGINAL `~/.claude/agents/idc-role-closeout-author.md` → CURRENT `../../agents/idc-role-closeout-author.md`, which **fails resolution** (`agents/idc-role-closeout-author.md` missing — known-debts item 5; the sibling mentions at sequence:173 / ripple:127 correctly got bare + lint-allow).
- **Why the linter is silent:** path tokens are rule-exempt (see MIN-9 blind spots).
- **Fix:** revert all 7 sites to bare names + lint-allow (or "(retired; now `idc:…`)" annotations) — never a concrete plugin path.

### MAJ-4 — install-codex.sh reports success on failure (3 reachable bugs, all sandbox-confirmed)
1. Relative `<plugin_root>` (a documented manual invocation — `docs/installing.md:104`) passes the `-d` check from CWD, then `ln -s` stores the relative string → **all 5 adapter links dangle**, WARN only, **exit 0** (S7). Fix: `PLUGIN_ROOT=$(cd "$PLUGIN_ROOT" && pwd) || exit 2`.
2. Verify loop counts resolution failures but never gates the exit code: 0/5 or 4/5 resolving still exits 0 (S7/S9); `commands/init.md:150` invokes it with no way to detect failure. Fix: `[ "$resolved" -eq 5 ] || exit 1`.
3. Plain-file-at-path misclassification (see BLK-2 companion) also exits 0 after 10 failed `rm`/`ln` calls (S11).
- Positive: bash 3.2-clean (verified on real 3.2.57, paths with spaces), R11-compliant link scheme, two-hop resolution works, idempotent re-install, STATE written before mutation.

### MAJ-5 — Scaffolded `WORKFLOW.md` permanently keeps `{{TRACKER_PROJECT_NUMBER}}` (init never substitutes it)
- **Evidence (re-verified):** `templates/WORKFLOW.md:31` carries the token backtick-wrapped/unquoted. `commands/init.md:62-67` Phase-1 sed loop substitutes only PROJECT_NAME/GITHUB_OWNER/GITHUB_REPO; Phase-4 (:126-127) replaces only the **quoted** token and only "in BOTH `docs/workflow/tracker-config.yaml` and `WORKFLOW-config.yaml`". Result: every freshly-init'd repo's governance contract reads "board is project number `{{TRACKER_PROJECT_NUMBER}}`". CI's smoke-render substitutes all 4 tokens in all 3 files, masking the gap.
- **Fix:** add WORKFLOW.md (bare-token form) to the Phase-4 substitution step.

### MAJ-6 — 24 citations of `WORKFLOW.md §6.x` dangle against a template that ends at §5
- **Evidence (re-verified: 24 hits, 6 files):** both tracker skills, idc-skill-tracker-adapter, idc-build, idc-build-runbook, idc-sequence cite `WORKFLOW.md §6.2/§6.3/§6.6/§6.7/§6.8` — including the github-tracker field contract's own anchor ("enumerated in `WORKFLOW.md §6.3 Project schema`", SKILL.md:42). `templates/WORKFLOW.md` has 5 sections; its tracker section is **§2** — and its header promises "section numbers are stable… cite by anchor". Every §6 citation dangles in a freshly scaffolded repo. Pre-existing relative to the original project's WORKFLOW.md, but the **template** is new content and the mismatch ships. Not in known-debts.
- **Fix:** renumber the citations to the template's anchors (or extend the template to match the original's numbering); register in known-debts either way.

### MAJ-7 — Private source-tree names and personal infra leak beyond the sanctioned polish list
1. `ke_common/` / `sync_agent/` (the original private repo's package names) presented as the governed repo's generic layout — 7 sites / 6 files (all re-verified): `agents/idc-role-integration-verifier.md:56`, `agents/idc-role-bootstrap-researcher.md:89`, `agents/idc-role-writer.md:29`, `skills/idc-skill-ripple-verdict/SKILL.md:120,142`, `skills/idc-skill-canonical-admission-audit/SKILL.md:206`, `skills/idc-skill-subphase-ingestion/SKILL.md:92`. The polish list covers "KE" prose tokens and `/tmp/ke-idc-*` only — this `ke_`-prefixed surface would slip through it.
2. `skills/idc-skill-think-brainstorming-substrate/SKILL.md:71` — "may auto-start the **Visual Companion** server and push diagrams to a cmux browser split per `~/.claude/CLAUDE.md` §Visual Companion override" — operator-personal infrastructure + a section of a personal global CLAUDE.md no plugin user has (same file :14 cites another personal § anchor).
- **Fix:** replace path lists with a generic placeholder (`<source dirs per WORKFLOW-config>`); delete or genericize the Visual-Companion sentence. Add both to the polish list so Phase E catches them.

---

## MINOR

**MIN-1 — All 16 roleplayer H1 self-titles namespaced (`# idc:idc-role-X`).** Untraced to any transform (T2 covers spawn refs, not self-titles) and inconsistent with B1's orchestrators, which kept H1s bare (`# idc-build`). 16 files, line 7 each. Fix: revert to bare (or pick one convention and apply to both sets).

**MIN-2 — Governance-scope classifier now names the installed-plugin path as an admitted-scope surface.** `agents/idc-plan.md:339`, `agents/idc-sequence.md:272`: ORIGINAL "purely `~/.claude/agents/`, root CLAUDE.md, or docs/workflow/" → CURRENT `${CLAUDE_PLUGIN_ROOT}/agents/…`. Mechanical T4, but per T11 the self-edit surface is the plugin **repo** (via PRs) — no IDC run writes the installed plugin root. Fix: reword to "the workflow-definition surfaces (the idc-workflow plugin repo's agents/)".

**MIN-3 — `idc-skill-ripple-verdict` left in a split state.** Layer-enum/pipeline bullets rewritten to `${CLAUDE_PLUGIN_ROOT}/agents|skills` (:116-117) while the fence-classification rule (:134, :153) and `skills/idc-workflow/SKILL.md:25` still key governance on `~/.claude/` — the same surface now classifies *governance* in one half and *codebase* in the other. The `~/.claude` eyeball is sanctioned Phase-E scope (known-debts names exactly these files), but the polish pass must reconcile **both halves**; note it on the polish list.

**MIN-4 — Folded skill names de-prefixed with no "now idc:…" annotation anywhere in file.** `skills/idc-skill-planning-substrate/SKILL.md` — CS-4 `governance-verdict` (:115,218,236,384) and RS-2 `impact-classifier` (:237,316,385): 7 mention sites, zero routes to the surviving skill (contrast ripple-verdict:480's correct "(now `idc:idc-skill-planning-substrate` …)"). Fix: annotate first mentions.

**MIN-5 — Live (not historical) references to folded roles, unannotated.** `skills/idc-skill-ripple-verdict/SKILL.md:30` "When to invoke" still names `idc-deconflict` as a live caller; `skills/idc-skill-think-brainstorming-substrate/SKILL.md:65,:81` still direct the operator to invoke `idc-engineer`. Both folded into `idc:idc-plan`. Fix: "(now `idc:idc-plan`)" or rewrite to successor.

**MIN-6 — Namespacing applied to non-reference tokens (4 sites).** `agents/idc-role-wave-blocker-diagnostic.md:51,75` — hybrid `` `idc:idc-skill-tracker-adapter/SKILL.md` `` (neither a valid slug nor a valid path; :75 even uses the correct `${CLAUDE_PLUGIN_ROOT}/skills/...` form earlier in the same row); `agents/idc-role-ripple-orchestrator.md:167` — "**This file (`idc:idc-role-ripple-orchestrator.md`)**" (file names stay bare per brief); `skills/idc-skill-governance-trace-audit/SKILL.md:19` — `idc-ripple` namespaced *inside a verbatim quotation* while `idc-engineer` in the same quote stayed bare. Fix: revert tokens to bare/path form.

**MIN-7 — T12 (memory-slug) leftovers.** Slug `evidence-based-sota-recommendations` survived un-stripped (`agents/idc-role-bootstrap-researcher.md:343`, `agents/idc-role-think-investigator.md:146`); `agents/idc-role-issue-implementer.md:424` renamed the header to "Doctrine notes" but kept the stale "Canonical operator memories … read these before deviating" intro; `skills/codex-idc-build/SKILL.md:16` still says "or memory references" though the section it enumerates is now "Doctrine notes"; `skills/idc-skill-plan-patch-from-findings/SKILL.md:40` prettified the slug ("per the don't-stop-the-train rule") without inlining the rule. 5 one-line fixes.

**MIN-8 — `commands/autorun.md:22` silently dropped a name instead of bare+lint-allow.** ORIGINAL dispatch list included `idc-role-tracker-adapter` (never existed — only the *skill* does); CURRENT lists only the two namespaced roles + "etc.". Verified against `git show e206932:commands/agent-autorun.md`. The convention was keep-bare+lint-allow or register the drop. Fix: restore bare + lint-allow, or add to known-debts as a deliberate drop.

**MIN-9 — Linter blind spots (9 confirmed by sandbox fixture runs) + 1 rule gap.** Confirmed misses: `idc:idc:` doubles (inner-ref strip at L44 hides them); **dangling `.md` path tokens** — `idc-role-*.md` and `skills/idc-skill-*/SKILL.md` paths are stripped with no existence check (this is exactly what let MAJ-3's `idc-role-closeout-author.md` ship); unknown `/idc:<command>` refs never extracted (typo `/idc:thinker` passes); namespaced frontmatter `name: idc:idc-plan` would pass (names are only *exempted*, never validated); `idc-skill` split across a linebreak before the second hyphen; `~/.claude/agents` without trailing slash; `/Users/[A-Z]…` capitalized usernames; rule 5 bypasses `lint-allow` (`:88` raw grep — first namespaced known-debt ref turns CI red with no escape hatch); rule 1b covers only `idc-role-*` — orchestrator-class bare refs (`subagent_type: idc-autorun` in the agents' own self-check lines 17 — which post-namespacing may also be semantically stale, since an installed-plugin spawn arrives as `idc:idc-autorun` and the HALT string-match wouldn't fire) are entirely unlinted. Fix: add existence checks for stripped path tokens, a frontmatter-name bareness rule, an orchestrator-name rule, and route rule 5 through the lint-allow filter; review the six `Task(subagent_type: idc-<role>)` self-check lines for the namespaced-spawn case.

**MIN-10 — `commands/init.md` two dead steps.** (:38-40) `gh repo view --json owner -q .owner.type` — gh's `owner` object has no `type` field; the exact command prints empty/exit 0 (empirically run). (:121-123) fallback "deleting … and creating a fresh `Status` single-select field" — the built-in Projects-v2 Status field cannot be deleted via API; dead end. Fix: use `gh api repos/... --jq .owner.type`; replace the Status fallback with "operator edits options in the board UI".

**MIN-11 — Tracker-skill ↔ template contract drift (3 sites).** `skills/idc-skill-github-tracker-implementation/SKILL.md:42` expects pre-bootstrap `field_ids` = `[]`, but `templates/tracker-config.yaml:21-29` ships a map with empty-string values — the documented trigger never matches; SKILL.md:101,105,122,140 reference a `status_option_ids` cache the template explicitly refuses to store; SKILL.md:113 autowave matrix check looks at `docs/plans/pillars/<phase>-matrix.yaml` while every template surface canonicalizes `docs/workflow/pillar-matrices/` — the check as written always yields `substrate-missing` in a scaffolded repo. Fix: align the skill's triggers/paths to the shipped template.

**MIN-12 — Skill-improver dev artifacts ship inside the installable skill.** `skills/codex-idc-build/{assessments.json,changelog.md,dashboard.html,results.json,results.tsv}` are git-tracked improvement-run logs (post-scrub they carry no private content, but results reference orphan commit SHAs `7bc8e86`/`8a6afcf` from the private run, and dashboard.html pulls chart.js from a CDN). Not on the polish list. Fix: move to `docs/dev/` or delete pre-publish.

**MIN-13 — Think-skill private-architecture residue beyond the polish list's KE-token scope.** `idc-skill-think-brainstorming-substrate/SKILL.md:57,58,23,85` (private Firestore schema path `users/{uid}/memory_event/`, layer-model jargon, "gbrain", private run-slug provenance pointers); `idc-skill-think-research-archive/SKILL.md:102` (private locked-invariants list — token-swapping "KE" alone leaves the leakage); `agents/idc-role-bootstrap-researcher.md:62` hardcodes the original board (`gh project item-list 2 --owner @me`) → should read the number from `docs/workflow/tracker-config.yaml`. Fix: widen the Phase-E polish scope on these files.

**MIN-14 — install/doctor/versioning odds.** install-codex: no mirror pruning or re-sync (skill deleted/added in `~/.claude/skills` after install → permanently dangling/invisible; `commands/doctor.md:46-54` checks only the 5 adapter links, so this drift is undetectable), and user-owned colliding symlinks are silently re-pointed (`link_one:46` `rm -f` on any symlink). `.claude-plugin/plugin.json:3` declares `0.1.0` while CHANGELOG has only `## Unreleased` (convert at publish — matches Task #12).

---

## NIT

1. `agents/idc-plan.md:388` — T12 conversion dropped the "(~/.claude/plans/ is historical fallback only)" clause rather than inlining a generic negative rule. Defensible under R7/R8.
2. `agents/idc-autorun.md:3,77` — prose spawn refs to `idc-sequence` left bare while the machine-readable `subagent_type` strings are namespaced; consistent with the linter's deliberate orchestrator-prose convention. No action unless MIN-9's orchestrator rule lands.
3. `agents/idc-role-merge-deconflictor.md:3` — folded CR-9 name de-prefixed to `pr-deconflict` in the YAML description (descriptions can't carry lint-allow comments; the body site uses the sanctioned form).
4. `agents/idc-role-subphase-pillar-planner.md:94` — `manifest_authored_by:` emitted-value prefix dropped (`idc-role-subphase-pillar-planner-…` → `subphase-pillar-planner-…`); no consumer matches on it (verified), but it's an untraced value change.
5. `skills/idc-skill-canonical-admission-audit/SKILL.md:390` — rename target rendered `idc:codex-idc-plan` where the literal dir rename target is bare; matches the "now idc:…" convention, cosmetic.
6. `skills/idc-skill-github-tracker-implementation/SKILL.md:225` — unbalanced trailing `)` left by codename inlining; `:105` — project-specific option id `76591d8a` now reads as generic (mitigated by same-sentence "MUST be resolved at call-time").
7. `skills/idc-skill-filesystem-tracker-implementation/SKILL.md:206` — "(the governed repo runs `backend: github`)" over-generalizes a per-repo config choice.
8. `skills/idc-skill-pillar-matrix-synth/SKILL.md:15-17` (and same convention in codex skills) — `lint-allow` markers appended after a table row's closing `|` create a phantom 4th cell in GFM rendering.
9. `skills/idc-skill-file-operator-todo/SKILL.md:98,108` — emitted-record byte format now carries `idc:`-prefixed skill name; `:166` glob reworded ("Codex-runtime sibling adapters") — meaning preserved.
10. `skills/codex-idc-ripple/SKILL.md:23-25` — rewrite dropped the explicit `idc-role-<name>.md` / `idc-skill-<name>/SKILL.md` filename patterns (meaning preserved; optional reinstate).
11. `appendices/codex-drift-ripple.md` referenced 8× (codex-idc-ripple ×3, ripple-verdict, change-order-shape, plan-adversarial-review ×2, idc-ripple) and `docs/workflow/audits/2026-05-07-…/open-questions.md` Q-cross pointers — anchorless provenance pointers into the original project's audit tree; pre-existing, but should be registered in known-debts (only the architecture.md §Cross-runtime item is registered today).
12. README.md:131 repo-layout omits `run-evals.sh`/`materialize-sandbox.sh` (README itself invokes them at :113); README never states the cmux/Claude-Teams runtime assumption that agents/commands lean on (~30 mentions).
13. `docs/installing.md:85-86` — claims `.claude/settings.json` "is committed" by init; init never commits and `.claude/` is commonly gitignored. Soften.
14. `commands/doctor.md:16-18` — reads only `.claude/settings.json`; plugin enabled via settings.local.json or user scope reports a false FAIL.
15. CI (`.github/workflows/ci.yml`): PyYAML used but undeclared (preinstalled on today's runner image); `bash -n` under bash 5 can't catch bash-3.2-incompat constructs (shellcheck would); the doc'd `sed -i` form is GNU-only if a contributor runs the step on macOS; `on: push` + `pull_request` double-runs same-repo PRs. All steps otherwise re-executed locally and work; `claude plugin validate` passes with one warning (marketplace description missing). `scripts/lint-references.sh:8` comment still names "Knowledge Engine" (the rule-4 regex must keep the literal; the comment needn't).
16. install-codex: `linked` counter counts attempts, not successes (:124); revert leaves an empty `~/.agents/` it created; no `set -e` window between `rm -f` and the link loops (STATE-before-mutation ordering is good).

---

## Lane verdicts

| Lane | Verdict | Summary |
|---|---|---|
| 1 — Sweep fidelity (`e206932..HEAD`, agents/ + skills/ + commands/) | **FINDINGS** | 0 Blocker. MAJ-2 (Codex-runtime slugs — needs a ruling; brief gap), MAJ-3 (7 dangling-path conversions), ~10 Minors, ~10 Nits. **Core semantics fully intact**: enums, alias labels, gate semantics, write surfaces, tool lists, step logic all verified byte-identical across every slice. No dropped sections; doctrine inlinings (T7/T10/T12) item-for-item faithful (e.g. build runbook 12→12, autorun 11→11). |
| 2 — Mechanical integrity | **FINDINGS** | MAJ-1 (11 strict-YAML frontmatters), the closeout-author dangling path (counted under MAJ-3), MIN-9 (9 confirmed linter blind spots). Clean: all `name:` fields bare and matching; zero `${CLAUDE_PLUGIN_ROOT}`-as-shell-env-var misuse (all 6 fenced occurrences are the R5-blessed text-substitution form); zero `${CLAUDE_PLUGIN_ROOT}` in Codex-facing files; 19/20 codex relative paths resolve. |
| 3 — New-content correctness | **FINDINGS** | BLK-2 + MAJ-4 (install-codex), MAJ-5 + MAJ-6 (scaffold contract), MIN-10/11/14. Clean: init.md's 8-field board contract matches the github-tracker skill **exactly** (8/8 fields, names, options, casing, incl. literal `(idle)`); doctor checks are genuinely read-only and path-accurate; all 4 template tokens documented, YAML valid pre/post substitution; README/llms.txt counts (8 commands / 23 agents / 38 skills / 19 evalsets) and every referenced path verified correct; install names `idc` / `idc@idc-workflow` consistent with the manifests. |
| 4 — Public-scrub residue | **FINDINGS** | BLK-1 (git history + author email), MAJ-7 (`ke_common`/`sync_agent` ×7, Visual Companion), MIN-12/13. Clean: zero "knowledge engine" outside docs/dev (post-`2a79053`), zero secrets (incl. eval artifacts + .sandbox), zero codenames beyond the sanctioned docs/dev example, no private URLs; remaining KE tokens / `/tmp/ke-idc-*` / `~/.claude` eyeballs are exactly the sanctioned polish-list scope. |

## Suggested dispatch order
1. **Rule on MAJ-2** (bare vs dual-form slugs in Codex bodies) — it sets the pattern for ~25 lines before any fix pass touches those files.
2. BLK-2 + MAJ-4 as one install-codex.sh PR (same functions).
3. MAJ-1 (11 quoting one-liners) + MAJ-3 (7 site reverts) + MIN-6/7/8 — one mechanical sweep-repair PR.
4. MAJ-5 + MAJ-6 + MIN-10/11 — one scaffold-contract PR.
5. MAJ-7 + MIN-12/13 → append to the known-debts polish list so Phase E's pass has the full scope; BLK-1 → explicit history-rewrite step in Task #12's gauntlet.
6. MIN-9 linter hardening (optional pre-publish; prevents recurrence of the MAJ-3 class).

---

# Addendum — Lane 5: evals harness (added at team-lead request, same session)

**Scope:** `evals/*.evalset.json` (19 sets / 24 cases), `scripts/run-evals.sh`, `scripts/materialize-sandbox.sh`, `docs/dev/evals.md` — all committed (`3740afa`). Method: full evalset deep-check (one subagent: schema-vs-runner jq paths, weights, tokens, fixture cross-refs against the materializer heredocs, provenance anchors, residue) + my own line-by-line read of both scripts with empirical verification (`/bin/bash 3.2.57 -n` both pass; the `if [ … ] || case … esac` ancestor guard works as written; `grep -qiF "GATED"` matching "delegated" confirmed; all 24 cases verified single-turn/single-part).

## The central claim — "single-role enactment preserves the original autorater's judging surface"

**Verdict: holds for the judge layer with two real qualifications; the enactment *shape* itself is sound.** The single-session enactment is a faithful analogue of the original single-Python-role-agent runs (no team orchestration existed in the original evals either); the harness system prompt correctly pins role, doctrine ref, and the no-write boundary; the judge is a separate `claude -p` with **no plugin loaded** (verified: `run_judge` builds args without `--plugin-dir`), gets the same weighted rubric the original `rubric.yaml` carried (fold verified: all 24 rubrics present, weights sum exactly 1.0), and enforces `expect_refusal`. The qualifications:

### EVAL-M2 — Major — The original *binary keep/revert gate* was demoted to an advisory signal in default mode, and its "forbidden codes absent" half was dropped entirely
- By the repo's own description (docs/dev/evals.md:34-36) the original scoring was **binary gate** ("required refusal reason codes present / **forbidden ones absent**") **plus** rubric autorater. In the migrated default (judge) mode, `run-evals.sh:284-300` makes the judge solely authoritative — `det_ok=0` never gates; an output missing every required token can PASS on judge score alone. And there is **no negative-token field** (`none_of`) anywhere in the schema or runner — the "forbidden ones absent" half of the original gate has no equivalent in either mode.
- **Fix:** when a case defines tokens, AND `det_ok` into the default-mode verdict (or at minimum surface det FAIL as a hard gate like `no_forbidden_source_writes`); add a `binary.none_of` field + runner check. Soften the "faithful autorater-equivalent" wording until then.

### EVAL-M3 — Major — The deterministic layer (authoritative under `--no-judge`) is substring- and quote-gameable
- `run-evals.sh:263,267` use `grep -qiF` (case-insensitive **substring**): `GATED` matches *delegated / mitigated / investigated / aggregated…* (empirically confirmed) and is a substring of `MAJOR_GATED` (so role-ripple-drift's `any_of: ["GATED","MAJOR_GATED"]` second entry is dead weight, and a wrong `MAJOR_GATED` answer det-passes a `GATED` expectation).
- Worse: **every token of every case appears verbatim in the sandbox WORKFLOW.md** (§4.3/§4.4/§4.5 menus + ladder), and the harness prompt *instructs* the agent to use those tokens verbatim — an agent that quotes the menu while reaching the wrong conclusion det-passes. Two fixtures literally contain their case's expected tokens (`fixture-build-empty-recipe.md` contains both `goal_recipe_empty` and `missing_goal_recipe`; the frozen `test-cases/role-build-pillar/rubric.yaml` header contains `forbidden_glob_hit`).
- docs/dev/evals.md:83-87 calls `--no-judge` "authoritative for refusal/verdict cases" — overstated as implemented.
- **Fix:** anchor the det grep to a structured final line (require e.g. `verdict: <TOKEN>` / `refusal: <code>` in the harness prompt and grep that with word boundaries), which also fixes the substring class.

### EVAL-M1 — Major — `role-ripple-major-gated :: major-gated-blocking-escalation`: prompt contradicts its own fixture
- The prompt describes an auth-provider migration drift "at docs/plans/pillars/fixture-drifted-pillar.md", but the materializer writes that file as the **Stripe** drift (used correctly by role-ripple-drift). A grounding agent that reads the cited file finds contradicting content; classifying the *actual* file yields GATED → det FAIL and likely judge FAIL **for correct behavior**. Directly threatens Task #11 ("full judged eval suite green").
- **Fix:** add a dedicated `fixture-auth-drift-pillar.md` heredoc to materialize-sandbox.sh and point this prompt at it.

### EVAL-M4 — Major — `materialize-sandbox.sh --fresh` runs `rm -rf` on an arbitrary user-supplied path with no sandbox-sentinel guard
- `:55-58`: `[ -e "$DIR" ]` + `--fresh` → `rm -rf "$DIR"` where `$DIR` is the positional arg. `scripts/materialize-sandbox.sh ~ --fresh` deletes the home directory. Contrast run-evals.sh:89-96, which carefully refuses to point its `reset --hard` at the repo or an ancestor — the materializer has no analogous guard for a *more* destructive operation.
- **Fix:** before `rm -rf`, require the target to look like our sandbox (e.g. contains the `materialize-sandbox` marker line in README.md/WORKFLOW.md) or be empty; otherwise refuse with exit 2.

## Minor

**EVAL-MIN-1 — Judge infra failure scores as case FAIL.** `run-evals.sh:295-299`: a transient judge-call error (empty/unparseable judge output) → `verdict=FAIL, jscore=judge-err`, indistinguishable in exit code from a real behavioral failure. Fix: distinct ERR verdict + retry-once, excluded from exit-1 or reported separately.

**EVAL-MIN-2 — Unquoted `$args`/path word-splitting.** `claude $args` with `args="--print --plugin-dir $REPO_ROOT …"` (:162-169, :205-207) breaks if the repo or sandbox path contains spaces (a documented local convention risk). Fix: use arrays or quote-expand.

**EVAL-MIN-3 — Answer-key leakage in the three build-refuse evals.** Sandbox WORKFLOW.md §4.4's *examples* are the exact eval inputs (`infra/live/main.tf`, `docs/build-notes.md`, `promote_next_eligible_wave`), so those cases measure doctrine lookup, not gate reasoning. Fix: change the eval paths to differ from the doctrine's examples.

**EVAL-MIN-4 — Two ripple prompts contradict sandbox state.** "PR fixed the typo" while the planted typo is still present in `orders.py`; "session.py renamed to db/conn.py" while `session.py` still exists. Grounding agents will report the contradiction; judge could penalize. Fix: phrase as "an open PR proposes…".

**EVAL-MIN-5 — 4 of 12 refusal cases are det-invisible** (`plan-refuses-source-write`, `ripple-refuses-source-write`, `think-refuses-source-write`, `subphase-no-scope-invention` have empty `any_of` → SKIP under `--no-judge`). Root cause: WORKFLOW.md defines no refusal codes for Plan/Think/Ripple boundary violations even though the harness prompt demands "cite the canonical refusal code". Fix: add boundary-refusal codes to §4.1/§4.2/§4.5 + these `any_of` arrays.

**EVAL-MIN-6 — Agent-under-test runs `--permission-mode bypassPermissions`.** The no-write gate only checks the sandbox git tree; writes outside the sandbox, `gh`, or network calls are constrained by instruction-following alone. Acceptable for a dev harness; document it. (The *judge* also gets bypassPermissions it never needs — drop it there.)

## Nit

1. `--keep` interacts badly with `no_forbidden_source_writes`: stale mutations from a prior case false-FAIL later cases.
2. `reset_sandbox` swallows git errors (`>/dev/null 2>&1`); a failed reset leaks stray writes into the next case's write-gate.
3. Dead schema weight: `session_input` ADK ceremony in all 24 cases, always-empty `all_of` in all 24, `headless_note` present in 3 files but only read when `headless=="skip"` (no file sets it) — docs-only.
4. `build-refuse-forbidden-tool` provenance cites §4.3 for wave-promotion ownership, but §4.3 never mentions waves (it lives in §4.4's example).
5. Cross-corroboration of MAJ-6: the *sandbox* WORKFLOW.md's §6 is "Commit / PR conventions" with no subsections — the shipped skills' `§6.2/§6.3/§6.7/§6.8` citations dangle in the eval sandbox too (its tracker section is §2).

## Verified clean (evals lane)
All 19 JSONs valid; every runner-consumed field present under the exact jq paths; **zero truncation risk** (all 24 cases single-turn / single-part — the runner's `conversation[0].user_content.parts[0].text` read drops nothing); all rubric weights sum to exactly 1.0; all `doctrine_ref` values `idc:`-namespaced and resolving; counts exactly 19 sets / 24 cases as documented; zero ADK/private residue in evals/ (no `transfer_to_agent`, `idc-test-repo`, KE, personal paths); the 4 runtime-only exclusions are accurately described in docs; expected ripple verdicts are the correct calls per §4.5 (drift's `GATED|MAJOR_GATED` OR-set is lenient but defensible); both scripts pass `bash -n` under real bash 3.2.57; the runner's repo-protection guard (refuses `reset --hard` at the repo or an ancestor; requires a sandbox-owned `.git`) is correct and was empirically exercised; judge runs **without** the plugin as documented; results land outside the sandbox so they never trip the write-gate.

**Lane 5 verdict: FINDINGS** — structurally sound suite and a thoughtfully-guarded runner; the fidelity claim needs the EVAL-M2/M3 qualifications, EVAL-M1 will fail a correct agent, and EVAL-M4 needs the same data-safety treatment as BLK-2.

**Updated totals (all 5 lanes): 2 Blocker / 11 Major / 20 Minor / ~21 Nit.**

---

# Re-verification (working tree) — 2026-06-11, fixer pass

**Audited state:** the audit-fixer's UNCOMMITTED working tree (76 modified tracked files + 5 deletions + 1 new untracked dir), diff stamp `7a10978ac8b1` — stable across the entire re-verification (the fixer froze edits as instructed; an early-pass race where evals/known-debts/evals.md landed mid-read was absorbed before the first stamp). Method: per-finding closure check at every site (not samples); full hunk-by-hunk trace of the diff (every changed line maps to a finding ID, a team-lead ruling, or a sanctioned polish item — **zero untraced changes, zero half-done sections found**); empirical re-tests: install-codex scenarios S1/S3/S4/S7/S9/S11/S13 re-run in /tmp sandboxes (all PASS), materializer sentinel scenarios (a)–(g) (all PASS), linter adversarial fixtures (new Rules 6/7 + codex exemption + Rule-5 coverage all behave as ruled; exit codes verified dirty=1/clean=0), PyYAML frontmatter re-check (0 problems), final repo linter CLEAN (74 files; count −1 from the deleted changelog.md).

## Verdict table

| Finding | Verdict | One-line evidence |
|---|---|---|
| BLK-1 git history | **N/A-DEFERRED** | Team-lead-owned (Phase E history rewrite + noreply author) — correctly not in fixer scope. |
| BLK-2 revert data loss | **CLOSED** | Classify-before-remove + link manifest + `rmdir`-only (never `rm -rf`); S4 user data survives revert; S11 plain file aborts exit 2 untouched. Sandbox-proven. |
| MAJ-1 frontmatter YAML | **CLOSED** | 11 files single-quoted (inner `''` escapes); description/argument-hint CONTENT byte-identical; PyYAML 0 problems. |
| MAJ-2 Codex `idc:` slugs | **CLOSED** | All codex bodies bare again (Skill() literals byte-identical to e206932); cleanup-manifest headers bare; filesystem-tracker Codex example bare + design-reason lint-allow; linter exemption correctly scoped to Rules 1a/1b only (Rules 5/6 still cover codex files — fixture-verified, incl. the dangling-path catch inside a codex file). |
| MAJ-3 dangling shipped-path claims | **CLOSED** | All 7 sites: `code-review-custom` ×2 → "operator-personal… never migrated; not shipped"; `idc-ripple` donor ×2 → "retired… not shipped"; `codex-idc-engineer` ×2 → "folded (consolidated into `idc:codex-idc-plan`)"; CR-5 → bare name + "(never authored — see known-debts)" + lint-allow. |
| MAJ-4 install exit-0 family | **CLOSED** | Abs-path normalization (S7: relative root now resolves 5/5); `resolved≠5 → exit 1` (S9: rc=1); plain-file abort exit 2 (S11). Sandbox-proven. |
| MAJ-5 WORKFLOW.md token | **CLOSED** | init Phase 4 now seds the bare token in WORKFLOW.md (+ quoted in both YAMLs); CI smoke-render rewritten to mirror init's exact substitution set, un-masking future gaps. |
| MAJ-6 §6 anchors | **CLOSED** | templates/WORKFLOW.md §6 "Tracker substrate" restored (+162 lines, §6.1–§6.8); §6.3 = exact 8-field contract (verified against the github-tracker skill + init.md — incl. carve-outs, `(idle)` Lane in §6.7); the eval-sandbox heredoc carries the SAME §6 anchors (8 subsections) with Autorun moved to §7; all 10 affected evalsets updated to §7; docs/dev/evals.md documents the anchor parity. No skills' §6.x citation dangles in either variant. |
| MAJ-7 ke_common/sync_agent + Visual Companion | **CLOSED** | Zero `ke_common`/`sync_agent` hits; replacements are generic AND semantically equivalent ("the repo's source dirs per `WORKFLOW-config.yaml`" with substitution instructions where greps were involved); Visual-Companion section → generic "Visuals session-visibility"; both personal global-CLAUDE.md § citations removed. *Residual (polish-class):* two stack-example `firestore.*` literals remain (idc-skill-ripple-verdict:144 codebase-pipeline list item; idc-role-wave-blocker-diagnostic:58 MUST-NOT list) — public-tech examples, not private leakage; suggest polish-list entry. |
| MIN-1 H1 self-titles | **CLOSED** | All 16 reverted to bare; linter gained a matching bare-H1 exemption so the revert stays lint-clean. |
| MIN-2 governance classifier | **CLOSED** | plan:339 + sequence:272 → "the workflow-definition surfaces (the idc-workflow plugin repo's `agents/`, via plugin-repo PRs)". |
| MIN-3 ripple-verdict split state | **CLOSED** | Surface table, both pipeline lists, fence rule, drift-evidence hint table, AND idc-workflow:25 all reconciled to the same workflow-definition-surfaces formula (harness-standard `~/.claude/hooks/` correctly retained). |
| MIN-4 folded-name annotations | **CLOSED** | CS-4/RS-2 first mentions annotated with successors (`now idc:idc-skill-ripple-verdict` + surface/sub-procedure params). |
| MIN-5 live folded-role refs | **CLOSED** | ripple-verdict:30 annotated; think-brainstorming :65/:81 rewritten to `idc:idc-plan`. |
| MIN-6 non-ref tokens namespaced | **CLOSED** | wave-blocker :51/:75 → full `${CLAUDE_PLUGIN_ROOT}` path; ripple-orchestrator:167 bare filename; governance-trace-audit:19 quote internally consistent (bare inside the verbatim quote, folded-role annotation outside it). |
| MIN-7 T12 leftovers | **CLOSED** | Slug inlined ×2 ("Evidence-based attribution — …"); issue-implementer intro reworded; codex-idc-build:16 "doctrine notes"; plan-patch-from-findings:40 rule inlined in-sentence. |
| MIN-8 dropped dispatch name | **CLOSED-BY-REGISTRATION** | Registered in known-debts as a deliberate drop with rationale (never-existent role name; restoring would add noise). Matches the fix-or-register ruling. |
| MIN-9 linter blind spots | **CLOSED** | Rule 6 (dangling `.md` paths, `${CLAUDE_PLUGIN_ROOT}` + relative forms, resolution from each file's dir) + Rule 7 (frontmatter-name bareness) landed and fixture-verified; Rule-5 lint-allow bypass documented as by-design; residual blind spots registered in known-debts with the orchestrator-name-rule revisit note. |
| MIN-10 init dead steps | **CLOSED** | `gh api repos/... --jq .owner.type` (+ explicit note the old command exposes no `type`); Status fallback → reconcile-or-operator-todo, "do NOT try to delete it". |
| MIN-11 tracker↔template drift | **CLOSED** | `field_ids` trigger matches the shipped empty-string map; `status_option_ids` reframed as optional non-shipped cache with call-time default (3 sites); autowave matrix check → `docs/workflow/pillar-matrices/` per WORKFLOW-config. |
| MIN-12 skill-improver artifacts | **CLOSED** *(commit caveat)* | 5 files deleted from skills/codex-idc-build/, content moved to `docs/dev/skill-improver-artifacts/codex-idc-build/` — **which is UNTRACKED; the commit must `git add` it or the history is lost**. PR-#167-style private refs in the skill text also scrubbed. |
| MIN-13 think-skill residue + board number | **CLOSED** | bootstrap-researcher reads board number/owner from tracker-config; think skills fully genericized — schema headers, validation rules, and markers renamed consistently end-to-end ("Patterns useful for the project" / "project inference"; zero residue repo-wide), private run-slug/audit pointers → historical note, gbrain/memory_event/family-vault/layer-model all gone. |
| MIN-14 install/doctor/version | **CLOSED-BY-REGISTRATION** (+partial fix) | Mirror-pruning + plugin-version registered; colliding-symlink re-point now emits a NOTE (S13 verified). |
| Nits 1–16 | **ALL CLOSED** | Fixed: Nit-4 (manifest value restored + lint-allow), Nit-6 (paren + option-id), Nit-7 (filesystem-tracker reword), Nit-12 (README scripts + cmux note), Nit-13 (installing reword), Nit-14 (doctor reads settings.json + settings.local.json + user-scope note), Nit-15-part (CI: PyYAML declared, `branches: [main]` de-dup, init-parity smoke render; marketplace description added — `claude plugin validate` warning resolved), Nit-16 (linked counter counts successes; empty `~/.agents` rmdir'd when install created it). Registered: Nits 1/2/3/5/8/9/10/11 + the CI bash-3.2/shellcheck and lint-comment notes. |
| EVAL-M1 fixture contradiction | **CLOSED** | New `fixture-auth-drift-pillar.md` heredoc (auth/OIDC drift); major-gated prompt repointed; role-ripple-drift keeps the Stripe fixture. |
| EVAL-M2 binary gate demoted / no none_of | **CLOSED** | `binary.none_of` consumed by the runner AND populated in all 4 ripple sets (wrong-verdict tokens); det gate ANDed into the final verdict in BOTH modes; header + docs/dev/evals.md rewritten to the restored two-layer semantics. |
| EVAL-M3 substring/quote-gameable det | **CLOSED** | Gate now reads ONLY structured final line(s) (`verdict:` / `refusal:`, demanded by the harness prompt incl. `verdict: none` for generative answers) with word-boundary matching (`_` is a word char → GATED ⊄ MAJOR_GATED; "delegated" can't match). Fixture-token mentions registered as defused. |
| EVAL-M4 materializer rm -rf | **CLOSED** | Sentinel file + `$HOME`/`/`/repo-ancestor refusals + non-sentinel-non-empty refusal — all 5 scenarios sandbox-proven; sentinel is committed inside the sandbox so the write-gate stays clean (porcelain 0). |
| EVAL-MIN-1/2/3/4/5/6 | **ALL CLOSED** | Judge retry→ERR verdict (separate count, exit 3, never FAIL); array-quoted invocations; prompts diverged from doctrine examples (`infra/prod/dns.tf`, `docs/notes/perf-findings.md`); "An open Build PR proposes…" phrasing; 4 boundary refusal codes added to sandbox §4.1/§4.2/§4.5 + evalsets (`think/plan/ripple_write_boundary_denied`, `plan_scope_invention_denied`); judge perms dropped + agent-side bypass documented in header + evals.md §Permissions caveat. |
| EVAL Nits | **REGISTERED** | `--keep` interaction, dead schema fields, fixture-token note — all in known-debts. |

**REGRESSED: none.** Nothing in the fix diff altered role authority, write surfaces, alias labels, enums, or gate semantics; the think-skill schema rename (KE→project markers) is the one contract-bearing change and it is sanctioned polish applied consistently end-to-end (schema + validation rules + banlist together; zero stale references repo-wide).

## Remaining work items (for the team lead)

1. **BLK-1 (yours, Phase E):** history rewrite to a clean public root + noreply author — unchanged, still the publish gate.
2. **Commit mechanics:** `git add docs/dev/skill-improver-artifacts/` explicitly — it is untracked, and the five source files are deleted from skills/; committing without it loses the artifacts.
3. **Watch-item for Task #11 (first judged run):** the det gate requires the literal `verdict:`/`refusal:` line anchored at line start; an agent that bolds or fences it (`**verdict: GATED**`) det-FAILs a correct answer. If the judged run shows det:FAIL with correct-looking output, loosen the line anchor (allow leading `*`, `-`, backticks) — one-line change in the `vlines` grep.
4. **Optional polish-list adds:** the two residual `firestore.*` stack-example literals (ripple-verdict:144, wave-blocker:58); name `appendices/existing-idc-ripple-retirement.md` (change-order-shape:8) explicitly in the registered anchorless-pointer family.
5. **Optional eval hardening:** `none_of` is populated only in the 4 ripple sets; the sequence/build refusal sets could carry wrong-code `none_of` lists too.

**Re-verification verdict: the working tree is commit-ready** (subject to item 2). Every audited finding is CLOSED, CLOSED-BY-REGISTRATION, or correctly deferred to the team-lead-owned BLK-1.

— end of report —
