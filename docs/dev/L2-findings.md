# Loop 2 — E2E verify-drain findings (autorun sandbox, FIXED code, branch overnight-e2e-hardening)

**Run:** `run-L2-discovery.txt` · L2 session JSONL `d6137ee6-…` · snapshot `020-auto-9ace74c`.
**Gates:** lint 0 · smoke 30/30 ALL GREEN · DRAIN VERIFY PASS 5/5.

## L1 fixes — VERIFIED FIXED LIVE (no action)
- **F1** (retire jq/empty-id crash): FIXED ✓ — L2 JSONL has ZERO `global id of ''` / `control characters from U+0000` / `jq: parse error`, no blank-id `(item )`, no retry; IDs resolved in-process first try. Bonus: the blank-id guard **fail-closed under a real mid-drain rate-limit** (refused to mutate, then recovered) — guard works under load. (Error signatures appear ONLY in the L1 transcript `5a5a9f85`.)
- **F2b** (branch orphans): FIXED ✓ — `git ls-remote 'plan/*' 'build/*'` = ZERO; all 6 PRs merged via direct `gh pr merge --squash --delete-branch` (not `--auto`); branches deleted. L1's orphan class eliminated.
- **F2** (review-report litter): fix CORRECT + smoke-proven; e2e structurally blind because `seed` restores `autorun-baseline` which predates the `.gitignore` (tag has only `code-reviews/.gitkeep`). HARNESS gap, not a regression.
- **Gate** (#50/#51/#52): untouched ✓ — all read-only; Think PR #50 never merged.

## NEW — Loop 2 fixer scope (both friction/nit, no blockers)

### L2-1 — [friction][PLUGIN] autorun exit report under-counts its own untracked litter
Exit report claimed *"two stale untracked files predate this run,"* but the tree had **10** untracked
review files, **8 written by THIS run** (pr-57/58/59/60 `.report.md`+`.verdict.json`). **Root cause:**
the run's only `git status` executes at session START (pre-build); the review artifacts the build lane
emits are never reconciled into the exit count. **Fix:** reconcile working-tree state with a
**post-build `git status`** for the exit report so the litter/clean claim is accurate. (Lower urgency
because it's moot once the F2 `.gitignore` ships — no litter to miscount — but the stale-status logic
is a genuine accuracy bug worth correcting at root.) Add hermetic coverage if feasible.

### L2-2 — [nit][PLUGIN] retired pointers end Status=Done but Stage=Planning (carried over from L1)
Final board: `#46/#47 Status=Done Stage=Planning`. The github retire helper advances Status but never
moves Stage to a terminal value. **L1 history:** the fixer consciously SKIPPED this, reasoning "the
Stage enum has no terminal value and retire CLOSES the issue (drops off the active board); adding a
Stage option is a destructive option-set mutation the skill forbids." **Loop 2 task:** make a FINAL
determination — is there a SAFE fix (e.g. CLEAR the Stage field on the retired item — an item-field
update like Status already does, NOT an option-set mutation), or is it genuinely won't-fix? If safe,
do it; if not, document the definitive won't-fix + reason. **Do NOT** add/alter the project's Stage
field options (destructive, forbidden).

## HARNESS items (NOT shipped plugin — for the morning / harness owner)
- Re-cut `autorun-baseline` from a fresh fixed `/idc:init` so F2 becomes e2e-verifiable and future
  drains are litter-clean. (Costs a fresh init + re-seed; F2 is already validated by smoke + code.)
- L2-3 transient TLS timeout + GraphQL rate-limit inside the build subagent — **recovered by retry**
  (fail-closed + poll-to-reset). Robustness POSITIVE, not a defect; confirms a full drain exhausts a
  GraphQL window (keep the full-budget-start discipline).
- L2-4 one lead-side `python3 -c` SyntaxError (escaped quotes in an f-string), self-corrected via
  heredoc. Cosmetic, one wasted call.

**Bottom line:** both substantive L1 bugs fixed + verified live; Loop 2 is friction/nit only.
