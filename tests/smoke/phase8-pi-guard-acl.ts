// Phase 8 smoke — exercises the REAL per-role guard (`evaluatePathForRole` /
// `evaluateBashForRole` from runtime/pi/extensions/idc-role-harness.ts) against the locks the
// pi-guard-fix branch adds + the fail-closed guarantees it must preserve. No GitHub, no agent
// binary — pure function calls. Run via tests/smoke/phase8-pi-guard-acl.sh (exit 0 = pass).
//
// Red-when-broken: every assertion tagged [B1]/[B2]/[BR]/[M3]/[GIT]/[FORCE]/[MERGE]/[DANGER]/
// [MGB] FAILS against the pre-fix guard (the guard-bypass review proved each bypass returns
// allowed:true end-to-end); the [PRESERVE] cases must stay green before AND after.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { evaluateBashForRole, evaluatePathForRole, type IdcRole } from "../../runtime/pi/extensions/idc-role-harness.ts";

// A fake run repo on disk so the MG-B verdict reader has real files to consult.
const CWD = fs.mkdtempSync(path.join(os.tmpdir(), "pi-guard-acl-"));
const reviews = path.join(CWD, "docs/workflow/code-reviews");
fs.mkdirSync(reviews, { recursive: true });
fs.writeFileSync(path.join(reviews, "pr-7.verdict.json"), JSON.stringify({ pr: 7, verdict: "PASS" }));
fs.writeFileSync(path.join(reviews, "pr-9.verdict.json"), JSON.stringify({ pr: 9, verdict: "FAIL" }));
fs.writeFileSync(path.join(reviews, "pr-13.verdict.json"), JSON.stringify({ pr: 13, verdict: "PASS-WITH-NITS" }));
// (no pr-11.verdict.json — the "absent → fail-closed" case)

const inRepo = (rel: string) => path.join(CWD, rel);

type Case = { tag: string; role: IdcRole; kind: "bash" | "write"; input: string; allow: boolean; note: string };

const cases: Case[] = [
	// ── [PRESERVE] file-write fail-closed — must be green before AND after ──────────────
	{ tag: "PRESERVE", role: "think", kind: "write", input: inRepo("docs/considerations/x.md"), allow: true, note: "think writes its considerations" },
	{ tag: "PRESERVE", role: "think", kind: "write", input: inRepo("src/x.ts"), allow: false, note: "think cannot write source" },
	{ tag: "PRESERVE", role: "build-impl", kind: "write", input: inRepo("src/x.ts"), allow: true, note: "build-impl writes source" },
	{ tag: "PRESERVE", role: "build-impl", kind: "write", input: inRepo("docs/prd/x.md"), allow: false, note: "build-impl cannot write the PRD" },
	{ tag: "PRESERVE", role: "build-impl", kind: "write", input: inRepo("scripts/.env"), allow: false, note: "secret denylist inside a write root" },

	// ── [B1] spaced subshell / brace group must not hide the inner command ──────────────
	{ tag: "B1", role: "build-review", kind: "bash", input: `( rm -rf ${inRepo("src")} )`, allow: false, note: "subshell rm — read-only role" },
	{ tag: "B1", role: "build-review", kind: "bash", input: `{ rm -rf ${inRepo("src")}; }`, allow: false, note: "brace-group rm — read-only role" },
	{ tag: "B1", role: "sequence", kind: "bash", input: "( git checkout -b x )", allow: false, note: "subshell git — sequence has no git" },
	{ tag: "B1", role: "think", kind: "bash", input: "( git push --force )", allow: false, note: "subshell force-push" },

	// ── [B2] git -C / --git-dir / --work-tree pointing outside the run repo ─────────────
	{ tag: "B2", role: "build-finish", kind: "bash", input: "git -C /other/repo commit -m x", allow: false, note: "commit into another repo" },
	{ tag: "B2", role: "build-finish", kind: "bash", input: "git -C /other/repo merge evil", allow: false, note: "merge into another repo" },
	{ tag: "B2", role: "build-finish", kind: "bash", input: "git --git-dir=/other/.git commit -m x", allow: false, note: "--git-dir escape" },
	{ tag: "B2", role: "build-finish", kind: "bash", input: "git commit -m x", allow: true, note: "in-repo commit is fine" },

	// ── [BR] build-review is read-only on the board (reads + comment only) ──────────────
	{ tag: "BR", role: "build-review", kind: "bash", input: "gh issue create --title x", allow: false, note: "reviewer cannot create issues" },
	{ tag: "BR", role: "build-review", kind: "bash", input: "gh project item-edit --id X --field-id F", allow: false, note: "reviewer cannot edit board fields" },
	{ tag: "BR", role: "build-review", kind: "bash", input: "gh issue close 5", allow: false, note: "reviewer cannot close issues" },
	{ tag: "BR", role: "build-review", kind: "bash", input: "gh project item-list --owner o", allow: true, note: "reviewer may read the board" },
	{ tag: "BR", role: "build-review", kind: "bash", input: "gh issue comment 5 --body hi", allow: true, note: "reviewer may comment findings" },

	// ── [M3] case-variant paths still hit the governance + secret denylists (APFS) ──────
	{ tag: "M3", role: "build-impl", kind: "write", input: inRepo(".ENV"), allow: false, note: "case-variant secret file" },
	{ tag: "M3", role: "build-impl", kind: "write", input: inRepo("claude.md"), allow: false, note: "case-variant CLAUDE.md" },
	{ tag: "M3", role: "build-impl", kind: "write", input: inRepo(".PI/agents/x.md"), allow: false, note: "case-variant .pi/agents" },

	// ── [GIT] scoped git-lifecycle grant (mirrors the Claude per-role surface) ──────────
	{ tag: "GIT", role: "think", kind: "bash", input: "git checkout -b think/x", allow: true, note: "think branches the Think PR" },
	{ tag: "GIT", role: "think", kind: "bash", input: "git commit -m x", allow: true, note: "think commits" },
	{ tag: "GIT", role: "think", kind: "bash", input: "git push -u origin think/x", allow: true, note: "think pushes" },
	{ tag: "GIT", role: "think", kind: "bash", input: "gh pr create --title x --body y", allow: true, note: "think opens its PR" },
	{ tag: "GIT", role: "sequence", kind: "bash", input: "git checkout -b x", allow: false, note: "sequence stays git-less" },
	{ tag: "GIT", role: "build-review", kind: "bash", input: "git checkout -b x", allow: false, note: "reviewer stays git-less" },
	{ tag: "GIT", role: "build-impl", kind: "bash", input: "gh pr create --title x", allow: true, note: "implementer opens the build PR" },

	// ── [FORCE] force-push blocked for every role (incl. the git-authoring ones) ────────
	{ tag: "FORCE", role: "build-impl", kind: "bash", input: "git push --force origin x", allow: false, note: "--force blocked" },
	{ tag: "FORCE", role: "build-finish", kind: "bash", input: "git push -f", allow: false, note: "-f blocked" },
	{ tag: "FORCE", role: "build-finish", kind: "bash", input: "git push --force-with-lease origin x", allow: false, note: "--force-with-lease blocked" },

	// ── [MERGE] gh pr merge is role-scoped + --auto blocked ─────────────────────────────
	{ tag: "MERGE", role: "think", kind: "bash", input: "gh pr merge 5", allow: false, note: "think never merges (admission is operator-merged)" },
	{ tag: "MERGE", role: "build-impl", kind: "bash", input: "gh pr merge 7", allow: false, note: "implementer never merges" },
	{ tag: "MERGE", role: "plan", kind: "bash", input: "gh pr merge 5 --squash", allow: true, note: "plan automerges its planning PR" },
	{ tag: "MERGE", role: "recirculator", kind: "bash", input: "gh pr merge 5 --squash", allow: true, note: "recirculator automerges its sync PR" },
	{ tag: "MERGE", role: "build-finish", kind: "bash", input: "gh pr merge 7 --auto", allow: false, note: "--auto blocked even with a PASS verdict" },

	// ── [MGB] build-finish merge is hard-gated on the PR-keyed review verdict ───────────
	{ tag: "MGB", role: "build-finish", kind: "bash", input: "gh pr merge 7 --squash --delete-branch", allow: true, note: "PR #7 verdict = PASS → merge allowed" },
	{ tag: "MGB", role: "build-finish", kind: "bash", input: "gh pr merge 13 --squash", allow: true, note: "PR #13 verdict = PASS-WITH-NITS → allowed" },
	{ tag: "MGB", role: "build-finish", kind: "bash", input: "gh pr merge 9 --squash", allow: false, note: "PR #9 verdict = FAIL → blocked" },
	{ tag: "MGB", role: "build-finish", kind: "bash", input: "gh pr merge 11 --squash", allow: false, note: "PR #11 verdict absent → fail-closed block" },

	// ── [MGB] only build-review may author the verdict (anti-forgery) ───────────────────
	{ tag: "MGB", role: "build-review", kind: "write", input: inRepo("docs/workflow/code-reviews/pr-7.verdict.json"), allow: true, note: "reviewer is the sole verdict author" },
	{ tag: "MGB", role: "build-review", kind: "write", input: inRepo("src/x.ts"), allow: false, note: "reviewer cannot write source" },
	{ tag: "MGB", role: "build-finish", kind: "write", input: inRepo("docs/workflow/code-reviews/pr-7.verdict.json"), allow: false, note: "finisher cannot forge a verdict" },
	{ tag: "MGB", role: "build-impl", kind: "write", input: inRepo("docs/workflow/code-reviews/pr-7.verdict.json"), allow: false, note: "implementer cannot forge a verdict" },

	// ── [DANGER] non-tracker gh verbs denied for all roles ──────────────────────────────
	{ tag: "DANGER", role: "think", kind: "bash", input: "gh release create v1", allow: false, note: "release blocked" },
	{ tag: "DANGER", role: "build-finish", kind: "bash", input: "gh secret set X --body y", allow: false, note: "secret blocked" },
	{ tag: "DANGER", role: "plan", kind: "bash", input: "gh repo delete owner/repo --yes", allow: false, note: "repo delete blocked" },
	{ tag: "DANGER", role: "plan", kind: "bash", input: "gh repo view", allow: true, note: "repo view is a read" },

	// ── [M1b] command-substitution / backtick bodies still see the inner command ────────────
	{ tag: "M1b", role: "build-review", kind: "bash", input: `$( rm -rf ${inRepo("src")} )`, allow: false, note: "$( … ) cmdsubst rm" },
	{ tag: "M1b", role: "build-review", kind: "bash", input: "`rm -rf " + inRepo("src") + "`", allow: false, note: "backtick rm" },
	{ tag: "M1b", role: "build-review", kind: "bash", input: `>( rm -rf ${inRepo("src")} )`, allow: false, note: "process-subst rm" },

	// ── [M2] gh api implicit-POST / graphql is a tracker write (build-review read-only) ──────
	{ tag: "M2", role: "build-review", kind: "bash", input: "gh api graphql -f query='mutation{ x }'", allow: false, note: "graphql is always POST" },
	{ tag: "M2", role: "build-review", kind: "bash", input: "gh api repos/o/r/issues -f title=pwn", allow: false, note: "-f implies POST" },
	{ tag: "M2", role: "build-review", kind: "bash", input: "gh api repos/o/r/issues", allow: true, note: "bare gh api is a GET read" },
	{ tag: "M2", role: "build-review", kind: "bash", input: "gh api repos/o/r/issues -X GET", allow: true, note: "explicit GET stays a read" },
	{ tag: "M2", role: "plan", kind: "bash", input: "gh project item-edit --id X --field-id F --single-select-option-id O", allow: true, note: "plan does tracker writes via the bounded gh project surface" },
	{ tag: "M2", role: "plan", kind: "bash", input: "gh api graphql -f query='mutation{ x }'", allow: false, note: "gh api graphql is an unbounded raw surface — denied for all" },
	{ tag: "M2", role: "plan", kind: "bash", input: "gh api --method POST repos/o/r/issues/5/dependencies/blocked_by -F issue_id=9", allow: true, note: "the bounded blocked-by dependency endpoint is the one safelisted gh-api write" },

	// ── [M3b] $VAR-bearing cross-repo target refused fail-closed ─────────────────────────────
	{ tag: "M3b", role: "build-finish", kind: "bash", input: "git --git-dir=$PWD/../other/.git --work-tree=$PWD/../other commit -m x", allow: false, note: "$PWD indirection" },
	{ tag: "M3b", role: "build-finish", kind: "bash", input: 'git -C "$HOME/victim" commit -m x', allow: false, note: "$HOME indirection" },
	{ tag: "M3b", role: "build-finish", kind: "bash", input: "git -C ../../x commit -m x", allow: false, note: "literal ../../ escape" },

	// ── [WIDEN] git must respect the path ACL (B-2: no widening file authority) ──────────────
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git rm docs/specs/x.md", allow: false, note: "git rm of a blocked spec" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git checkout HEAD -- docs/prd/x.md", allow: false, note: "git checkout overwrites the PRD" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git restore --source=HEAD CLAUDE.md", allow: false, note: "git restore overwrites CLAUDE.md" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git checkout other -- docs/workflow/code-reviews/pr-7.verdict.json", allow: false, note: "git checkout forges the verdict" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git rm src/old.test.ts", allow: true, note: "git rm of a source file is fine" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git checkout -b build/wave1", allow: true, note: "branch creation is not a targeted file write" },

	// ── [PARENT] cannot rm/redirect a dir that contains a protected surface (B-1/M-4) ────────
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "rm -rf docs", allow: false, note: "rm of docs (contains prd/specs/…)" },
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "rm -rf docs/workflow", allow: false, note: "rm of docs/workflow (contains code-reviews)" },
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "ln -s /tmp/pi-idc/build-finish/wf docs/workflow", allow: false, note: "redirect docs/workflow" },
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "rm -rf src/legacy", allow: true, note: "rm of a source subdir is fine" },

	// ── [PUSH] remote-ref destruction is blocked for all (m-1) ──────────────────────────────
	{ tag: "PUSH", role: "build-impl", kind: "bash", input: "git push origin :main", allow: false, note: "empty-source refspec deletes the ref" },
	{ tag: "PUSH", role: "build-impl", kind: "bash", input: "git push origin --delete main", allow: false, note: "--delete remote ref" },
	{ tag: "PUSH", role: "build-impl", kind: "bash", input: "git push --mirror origin", allow: false, note: "--mirror overwrites all refs" },

	// ── [ADMIN] gh pr merge --admin bypasses branch protection — blocked even with PASS ──────
	{ tag: "ADMIN", role: "build-finish", kind: "bash", input: "gh pr merge 7 --admin --squash", allow: false, note: "--admin blocked even with a PASS verdict" },

	// ── [SAFELIST] git is a SAFELIST — every non-listed worktree/history op is denied (B-4) ──
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git apply /tmp/evil.patch", allow: false, note: "git apply writes the worktree" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git am /tmp/x.patch", allow: false, note: "git am" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git reset --hard origin/main", allow: false, note: "git reset --hard overwrites the worktree" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git cherry-pick deadbeef", allow: false, note: "git cherry-pick" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git stash pop", allow: false, note: "git stash pop" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git revert HEAD", allow: false, note: "git revert" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git rebase main", allow: false, note: "git rebase" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git merge other", allow: false, note: "git merge (local) — merges go through gh pr merge" },
	// the `<ref> <pathspec>` checkout form WITHOUT `--` is now path-checked
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git checkout HEAD~1 docs/prd/x.md", allow: false, note: "checkout <ref> <pathspec> overwrites the PRD" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git checkout other docs/workflow/code-reviews/pr-7.verdict.json", allow: false, note: "checkout <ref> <verdict> forges the verdict" },

	// ── [APIMERGE] every merge goes through the gated `gh pr merge` — not via raw gh api (B-3) ─
	{ tag: "APIMERGE", role: "build-finish", kind: "bash", input: "gh api -X PUT repos/o/r/pulls/8/merge", allow: false, note: "api REST merge bypasses MG-B" },
	{ tag: "APIMERGE", role: "build-impl", kind: "bash", input: "gh api -X PUT repos/o/r/pulls/8/merge", allow: false, note: "api merge for a non-merge role" },
	{ tag: "APIMERGE", role: "build-impl", kind: "bash", input: "gh api graphql -f query='mutation{ mergePullRequest(input:{pullRequestId:\"X\"}){clientMutationId} }'", allow: false, note: "graphql merge mutation" },

	// ── [GLOB] glob destruction across a protected surface is refused (M-5) ──────────────────
	{ tag: "GLOB", role: "build-finish", kind: "bash", input: "rm -rf *", allow: false, note: "rm -rf * unbounded" },
	{ tag: "GLOB", role: "build-finish", kind: "bash", input: "rm -rf docs/*", allow: false, note: "rm -rf docs/* unbounded" },

	// ── [REG3] class-level fixes must NOT over-block the legit git lifecycle ─────────────────
	{ tag: "REG3", role: "think", kind: "bash", input: "git checkout -b think/x", allow: true, note: "branch creation (operand is a ref, not a pathspec)" },
	{ tag: "REG3", role: "build-impl", kind: "bash", input: "git switch -c build/x", allow: true, note: "switch -c branch creation" },
	{ tag: "REG3", role: "build-impl", kind: "bash", input: "git restore src/x.ts", allow: true, note: "restore a source file (in authority)" },
	{ tag: "REG3", role: "build-impl", kind: "bash", input: "git add src/x.ts", allow: true, note: "staging is safe + needed" },
	{ tag: "REG3", role: "build-finish", kind: "bash", input: "git fetch origin", allow: true, note: "fetch updates refs, no worktree write" },
];

let failures = 0;
for (const c of cases) {
	const evaluation = c.kind === "bash" ? evaluateBashForRole(c.role, c.input, CWD) : evaluatePathForRole(c.role, c.input, CWD);
	const ok = evaluation.allowed === c.allow;
	if (!ok) {
		failures++;
		console.log(`FAIL [${c.tag}] ${c.role} ${c.kind} "${c.input}" — expected ${c.allow ? "ALLOW" : "BLOCK"}, got ${evaluation.allowed ? "ALLOW" : "BLOCK"} :: ${evaluation.reason}`);
	}
}

// ── [MGB-symlink] a docs→attacker symlink supplying a forged PASS must NOT unlock the merge ──
{
	const sCwd = fs.mkdtempSync(path.join(os.tmpdir(), "pi-guard-sym-"));
	const fake = path.join(sCwd, "fakewf");
	fs.mkdirSync(path.join(fake, "workflow/code-reviews"), { recursive: true });
	fs.writeFileSync(path.join(fake, "workflow/code-reviews", "pr-8.verdict.json"), JSON.stringify({ pr: 8, verdict: "PASS" }));
	fs.symlinkSync(fake, path.join(sCwd, "docs"), "dir"); // docs -> attacker tree holding a forged PASS
	const e = evaluateBashForRole("build-finish", "gh pr merge 8 --squash", sCwd);
	if (e.allowed) {
		failures++;
		console.log(`FAIL [MGB-symlink] build-finish gh pr merge 8 — symlinked docs supplied a forged PASS, got ALLOW :: ${e.reason}`);
	}
	fs.rmSync(sCwd, { recursive: true, force: true });
}

fs.rmSync(CWD, { recursive: true, force: true });

if (failures === 0) {
	console.log(`PASS: per-role guard ACL holds (${cases.length} cases: file-write fail-closed preserved; B1/B2/BR/M3 bypasses closed; git grant + force-push/merge scoping + MG-B verdict interlock enforced)`);
	process.exit(0);
}
console.log(`FAIL: ${failures}/${cases.length} guard ACL assertions failed`);
process.exit(1);
