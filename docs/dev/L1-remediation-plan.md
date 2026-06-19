# Loop 1 remediation plan (overnight e2e hardening) — fixer

Branch: `overnight-e2e-hardening` (stay on it; NO version bump). Gate EVERY commit on both
`bash scripts/lint-references.sh` (exit 0) AND `bash tests/smoke/run-all.sh` (all green).
Surgical: every changed line traces to a finding. No unrelated refactors.

## F1 (PRIORITY · BUG) — swallowed GraphQL failure during consideration retirement

**Root cause (confirmed from transcript `5a5a9f85…jsonl`, lines 166/167/170/171):**
the github backend resolves project-item / option / query ids by piping
`gh project … --format json | jq` to **external jq**. GitHub emits issue-body text with raw
control characters (U+0000–U+001F); external jq (1.7+) rejects them
(`jq: parse error: … control characters … must be escaped`), so the id resolves **empty**, and
`gh project item-edit` / `updateProjectV2ItemFieldValue` then fails on the empty global id `''`.

**Open question — RESOLVED (not masked):** the considerations ended up `Done` via a **recovered
retry**, not coincidence. Run 1 (external jq, captured var) failed with empty ids + GraphQL
errors + shell exit 1. The agent self-corrected and re-ran (run 2) using gh's **built-in `--jq`**
flag, which succeeded. The skill recipe *taught the fragile pattern*; a non-retrying / headless
drain would report "retired → Done" while the items stayed un-retired — the swallow risk the
contract forbids.

**Fix — `skills/idc-tracker-github/SKILL.md` (root cause, all three call sites):**
1. `itemid()` — replace `… --format json | jq -r --argjson n "$1" '…'` with gh's built-in
   `--jq` (gh applies the filter to live data and never round-trips body text through strict
   external jq):
   `gh project item-list "$PROJ" --owner "$OWNER" --format json --jq ".items[] | select(.content.number==$1) | .id"`
2. `optid()` — same conversion: `gh project field-list … --format json --jq ".fields[] | select(.name==\"$1\") | .options[] | select(.name==\"$2\") | .id"`
3. `query()` — same conversion: move the multi-field filter into gh's `--jq` (interpolate the
   controlled `$STATUS/$STAGE/$WAVE/$PHASE/$DOMAIN` values as jq string literals; keep the
   `(.stage // "Buildable")` legacy default). Keep `|| die_gh`.
4. Add a one-line **why** comment on the preamble helpers ("use gh's built-in `--jq`; piping gh
   project JSON to external jq breaks on control chars in issue bodies").
5. **Empty-id guard (defense-in-depth) in `setField`:** resolve the item id AND the option id into
   vars and `die_gh` if either is empty BEFORE the mutation — so a blank id never reaches
   `item-edit` and the failure surfaces non-zero per the contract:
   ```bash
   IID="$(itemid "$NUM")";          [ -n "$IID" ] || die_gh   # #NUM not on board → never mutate with ''
   OID="$(optid "$FIELD" "$VALUE")"; [ -n "$OID" ] || die_gh   # no such option → never mutate with ''
   gh project item-edit --id "$IID" --project-id "$PROJ" \
     --field-id "$(fid "$FIELD")" --single-select-option-id "$OID" || die_gh
   ```
6. Update the **Fail-closed posture** section so `die_gh` explicitly covers "an empty resolved
   item/option id — refuse to mutate with a blank global id."

**Red-when-broken hermetic coverage — new `tests/smoke/phase4-tracker-github-recipe.sh`
(add to `run-all.sh`):**
- **Red baseline (the bug is real):** build a fixture mimicking `gh project item-list --format
  json` output whose one item's `content.body` carries a raw control char; assert the OLD pattern
  (`printf '%s' "$FIXTURE" | jq -r '…'`) FAILS / yields empty (documents the exact failure class).
- **Behavioral guard test (coupled to the shipped recipe):** EXTRACT the actual `itemid`/`optid`
  helper defs + the `setField` guard from `SKILL.md` and EXECUTE them against a `gh` stub on PATH:
  - stub `gh project item-list/field-list … --format json --jq <expr>` = apply the expr to a clean
    fixture (emulating gh applying jq to live data) → `itemid 31` returns the right `PVTI_…` id.
  - stub `gh project item-edit` = FAIL if `--id` is empty (mimics the GraphQL '' error).
  - case A: `setField` for an issue ON the board → item-edit called with the real id, exit 0.
  - case B: `setField` for an issue NOT on the board → `itemid` empty → the guard fires `die_gh`
    (non-zero) and item-edit is NEVER invoked with ''. 
  Prove red-when-broken: removing the guard line (or reverting `--jq`→`| jq`) makes the test fail.
- **Prose lock:** assert `SKILL.md` no longer uses `--format json | jq` for gh project reads and
  the setField recipe contains the empty-id guard.

### F1 addendum (authoritative scope update) — explicit retire helper

The autorun agent **hand-rolled** the retire (captured `gh project item-list --format json` into a
var, re-parsed with external jq) instead of using the skill ops — which is exactly how the
store-and-reparse fragility reached the live board. Op-level robustness (above) is necessary but
not sufficient; the skill also ships an explicit **`retire(pointer, reason)`** convenience that
resolves ids in-process via `itemid` (gh `--jq`) + the guard, and a prose warning to **never
hand-roll** the store-and-reparse pattern. Locked by phase4-tracker-github-recipe.sh (asserts the
retire op exists, the warning is present, and no board read pipes `--format json` to external jq).

## F2 (review-report artifacts) — SHIPS (lead decision): gitignore as local scratch

The review-report files ARE real plugin output (the review agent writes them to
`docs/workflow/code-reviews/`) and ARE left untracked — not snapshot residue. The README tension
(`"a PR body is the audit trail"` → scratch, vs. `"referenced from issues"` / `.gitkeep` "real
content" → durable) is a product decision; the **lead resolved it: review reports are local working
artifacts, gitignore them.** Fix (commit `66889f7`): scaffold
`templates/docs-tree/code-reviews/.gitignore` (`*`, keep `.gitkeep`+`.gitignore`) so a fresh
`/idc:init` ignores reports/verdicts → no untracked litter at a clean drain exit; rides the existing
`cp -R` scaffold (no scaffold-script change). `pillar-matrices` gets NO ignore (matrices are the
durable record). Locked red-when-broken by `phase1-init-doctor.sh` (deleting the template
`.gitignore` fails the test). *(History note: an earlier autonomous reversion of this fix was
restored by the lead via cherry-pick once the scratch-vs-durable call was made.)*

## F2b (NEW · substantive) — orphaned plan/build branch after a merged PR

`plan/sandbox-version-stamp-32` (merged PR #41) survived while its peers were deleted. Repo
`deleteBranchOnMerge=false`, so branch cleanup is the plugin's job — but it was **soft prose**:
`agents/idc-plan.md` automerged the planning PR with **no** branch-delete step at all, and
`agents/idc-finisher.md:55` only said "tidy (delete the merged branch/worktree)" parenthetically →
applied non-deterministically. **Fix:** both the plan automerge and the finisher merge now delete
the merged branch **atomically with the merge** (`gh pr merge … --delete-branch`), called out as a
required step (not best-effort), noting `deleteBranchOnMerge` may be off. Locked red-when-broken by
phase3-plan.sh (plan) + phase4-triplet.sh (finisher).

### Optional nits — documented, not changed
- **#3 (Stage=Planning on Done pointers):** SKIPPED. The `Stage` enum has no terminal value
  (`Consideration|Planning|Buildable`); a retired pointer is **closed** (`gh issue close`), so it
  drops off the active board regardless of Stage. Adding a "done" Stage option is a destructive
  option-set mutation the skill explicitly forbids. Left as-is (low value, no safe target).
  *(See L2-2 below for the strengthened FINAL determination — clearing is also unsafe.)*
- **#4 (phantom "heal board hygiene" task), #5/#6/F4 (harness):** out of scope — not shipped-plugin
  behavior / harness-only.

---

## Loop 2 (L2-discovery) — `docs/dev/L2-findings.md`; both friction/nit

L2 verified both L1 substantive bugs FIXED live (F1: zero jq/empty-id errors; F2b: zero orphaned
`plan/*`/`build/*` branches). Two new items, no blockers:

### L2-1 (friction) — autorun exit report under-counted untracked litter — FIXED
The exit report's working-tree claim was sourced from a **session-START** `git status` (the build
lane then wrote 8 review files it never re-counted → claimed "2 stale" vs. 10 actual). There was no
litter prose in the plugin — the agent improvised a stale-snapshot claim. **Fix:** both
`commands/autorun.md` and `agents/idc-autorun.md` now spec the exit report's working-tree state from
a **final post-build `git status --porcelain`** (never a start-of-run snapshot). Locked
red-when-broken by `phase6-autorun.sh`.

### L2-2 (nit) — retired pointer ends `Status=Done` but `Stage=Planning` — FINAL: WON'T-FIX
Final determination (the candidate "clear the Stage field" fix was evaluated and **rejected as
unsafe**): clearing `Stage` makes the item read as **`Buildable`** via the `(.stage // "Buildable")`
legacy default in `query` — a latent glass-wall footgun (a retired pointer masquerading as buildable
work). Setting a terminal `Stage` needs a forbidden destructive option-set mutation. The retired
pointer is `Status=Done` + **closed** → filtered from active board views, and no query acts on a
`Done`+`Planning` item, so the current terminal state is correct and footgun-free. Documented at the
retire code site (`skills/idc-tracker-github/SKILL.md`). No code change.

## F2 (original investigation notes — the gitignore approach that SHIPPED; see F2 above)

**Finding premise is FALSE:** no review artifact was ever committed by ANY wave
(`git log --all -- 'docs/workflow/code-reviews/*report*'` is empty); only the final wave's
`pr-45-…report.md`/`.verdict.json` sit untracked. `templates/docs-tree/README.md` is decisive:
**"a PR body is the audit trail"** and the *matrix YAML* (not code-reviews) is "the durable
deconfliction record." So review reports are **local working artifacts**, not committed content;
the finisher merge flow has no commit-the-report step (correctly). The only real friction: a clean
autorun exit leaves untracked litter in the operator's repo.

**Fix (consistent-scratch, lowest risk — the brief's sanctioned "gitignore" option):** add a
per-directory ignore that rides the existing scaffold copy mechanism:
`templates/docs-tree/code-reviews/.gitignore` containing:
```gitignore
# Review-engine reports are local working artifacts — the PR body is the audit trail
# (see ../README.md). Ignore reports/verdicts so a clean autorun exit leaves no untracked litter.
*
!.gitkeep
!.gitignore
```
`pillar-matrices/` gets NO ignore (matrices are the durable, committed record). The scaffold loop
(`idc_init_scaffold.sh`) copies `code-reviews/` via `cp -R`, which carries dotfiles, so a fresh
`/idc:init` scaffolds the ignore automatically — no scaffold-script change needed.

**Red-when-broken coverage — extend `tests/smoke/phase1-init-doctor.sh`:** after the scaffold,
assert `docs/workflow/code-reviews/.gitignore` exists; create a fake `pr-X.report.md` +
`pr-X.verdict.json` there and assert `git status --porcelain` does NOT list them and
`git check-ignore` matches them, while `.gitkeep` stays tracked/un-ignored. Removing the template
`.gitignore` makes the assertion fail.

## F3 (VERIFY → NON-ISSUE, document only) — operator next-step guidance

`skills/idc-gate-issue/SKILL.md` is explicit: "TO APPROVE: **merge the Think PR**. Merge =
admission" and merging is "the single, durable block-clearing signal"; step 4 has autorun/plan
**auto-remove the blocks link** and set the chained issue to `Todo` once it detects the merge.
So the exit-report guidance ("merge Think PR #35 — that unblocks #37") is **correct and complete**:
merging the Think PR IS the only operator action; the operator-action gate #36 is the findable
marker and is auto-resolved by the system on detecting the merge. **No change.** (F4 is a
test-harness nit — out of scope.)
