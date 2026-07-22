// Phase 8 smoke — exercises the REAL per-role guard (`evaluatePathForRole` /
// `evaluateBashForRole` from runtime/pi/extensions/idc-role-harness.ts) against the locks the
// pi-guard-fix branch adds + the fail-closed guarantees it must preserve. No GitHub, no agent
// binary — pure function calls.
//
// Red-when-broken: every assertion tagged [B1]/[B2]/[BR]/[M3]/[AUTH]/[GIT]/[FORCE]/[MERGE]/[DANGER]
// FAILS against the pre-fix guard (the guard-bypass review proved each bypass returns
// allowed:true end-to-end); the [PRESERVE] cases must stay green before AND after. U4's shared
// Path Gate hardens the raw tracker/merge surfaces too: `gh project` / raw blocked-by writes /
// `gh pr merge` are denied across Pi; merge stays operator-performed until a sanctioned helper lands.

import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import registerRoleHarness, { evaluateBashForRole, evaluatePathForRole, type IdcRole } from "../../runtime/pi/extensions/idc-role-harness.ts";

const PLUGIN = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CONTRACT = path.join(PLUGIN, "scripts", "idc_command_contract.py");
const PATH_GATE = path.join(PLUGIN, "scripts", "idc_path_gate.py");

// A fake run repo on disk so path-relative cases resolve against a real cwd.
const CWD = fs.mkdtempSync(path.join(os.tmpdir(), "pi-guard-acl-"));
execFileSync("git", ["init", "-q"], { cwd: CWD });
execFileSync("git", ["checkout", "-q", "-b", "main"], { cwd: CWD });
fs.mkdirSync(path.join(CWD, "docs", "workflow", "code-reviews"), { recursive: true });
fs.mkdirSync(path.join(CWD, "docs", "considerations"), { recursive: true });
fs.mkdirSync(path.join(CWD, "src"), { recursive: true });
fs.writeFileSync(path.join(CWD, "docs", "workflow", "tracker-config.yaml"), "backend: filesystem\n");
fs.writeFileSync(path.join(CWD, "WORKFLOW-config.yaml"), "pathway_enforcement:\n  mode: off\n");
fs.writeFileSync(path.join(CWD, "TRACKER.md"), "ticket: demo\n");
fs.writeFileSync(path.join(CWD, "src", "x.ts"), "export const x = 1;\n");

const inRepo = (rel: string) => path.join(CWD, rel);
const runPy = (args: string[]) => execFileSync("python3", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

const AUTH_SESSION = "pi-auth-session";
runPy([CONTRACT, "start", "--repo", CWD, "--session", AUTH_SESSION, "--command", "build", "--plugin-root", PLUGIN, "--args", "demo", "--source", "user"]);
runPy([
	PATH_GATE,
	"authorize",
	"--repo",
	CWD,
	"--session",
	AUTH_SESSION,
	"--command",
	"build",
	"--branch",
	"main",
	"--allow-action",
	"write",
	"--allow-action",
	"edit",
	"--allow-action",
	"git",
	"--allow-path",
	".",
]);

const AUTH_PATH = runPy([PATH_GATE, "auth-path", "--repo", CWD]).trim();
const SESSION_STATE = inRepo(".idc-session-state.json");
const GOOD_AUTH = fs.readFileSync(AUTH_PATH, "utf8");
const GOOD_STATE = fs.readFileSync(SESSION_STATE, "utf8");

function restoreAuthState() {
	fs.writeFileSync(AUTH_PATH, GOOD_AUTH, "utf8");
	fs.writeFileSync(SESSION_STATE, GOOD_STATE, "utf8");
}

function mutateAuth(mutator: (value: Record<string, unknown>) => void) {
	const value = JSON.parse(fs.readFileSync(AUTH_PATH, "utf8")) as Record<string, unknown>;
	mutator(value);
	fs.writeFileSync(AUTH_PATH, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function expectPathAction(tag: string, action: "write" | "edit", allow: boolean) {
	const evaluation = evaluatePathForRole("build-impl", inRepo("src/x.ts"), CWD, {}, action);
	if (evaluation.allowed !== allow) {
		throw new Error(`[${tag}] expected ${action} to ${allow ? "ALLOW" : "BLOCK"}, got ${evaluation.allowed ? "ALLOW" : "BLOCK"} :: ${evaluation.reason}`);
	}
}

function authorizeActions(actions: Array<"write" | "edit">) {
	runPy([
		PATH_GATE,
		"authorize",
		"--repo",
		CWD,
		"--session",
		AUTH_SESSION,
		"--command",
		"build",
		"--branch",
		"main",
		"--allow-path",
		".",
		...actions.flatMap((action) => ["--allow-action", action]),
	]);
}

async function expectRegisteredHandlerPreservesAction() {
	type Handler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<{ block?: boolean; reason?: string } | undefined>;
	const handlers = new Map<string, Handler>();
	const fakePi = {
		registerFlag: () => undefined,
		getFlag: (name: string) => name === "idc-role" ? "build-impl" : name === "idc-guard-mode" ? "block" : undefined,
		on: (event: string, handler: Handler) => handlers.set(event, handler),
	};
	await registerRoleHarness(fakePi as never);
	const handler = handlers.get("tool_call");
	if (!handler) throw new Error("[ACTION-HANDLER] idc-role-harness did not register a tool_call handler");

	authorizeActions(["edit"]);
	const ctx = { cwd: CWD, hasUI: false, ui: { notify: () => undefined } };
	const editResult = await handler({ toolName: "edit", toolCallId: "edit-only", input: { path: inRepo("src/x.ts"), oldText: "x", newText: "y" } }, ctx);
	if (editResult?.block) {
		throw new Error(`[ACTION-HANDLER] edit-only authorization should ALLOW the registered Edit event, got BLOCK :: ${editResult.reason}`);
	}
	const writeResult = await handler({ toolName: "write", toolCallId: "write-denied", input: { path: inRepo("src/x.ts"), content: "x" } }, ctx);
	if (writeResult?.block !== true) {
		throw new Error("[ACTION-HANDLER] edit-only authorization should BLOCK the registered Write event");
	}
	restoreAuthState();
}

function expectPath(tag: string, attemptedPath: string, allow: boolean, reasonNeedle: string) {
	const evaluation = evaluatePathForRole("build-impl", attemptedPath, CWD);
	if (evaluation.allowed !== allow || (reasonNeedle && !evaluation.reason.includes(reasonNeedle))) {
		throw new Error(`[${tag}] expected ${allow ? "ALLOW" : "BLOCK"} for ${attemptedPath} with reason containing ${JSON.stringify(reasonNeedle)}, got ${evaluation.allowed ? "ALLOW" : "BLOCK"} :: ${evaluation.reason}`);
	}
}

// [MODE] Core observe posture must travel through the Pi call chain as ALLOW. Pi does not read
// pathway mode itself: it consumes the shared core's `observe` result, then controlled mode restores
// the hard-deny assertions below.
fs.rmSync(AUTH_PATH);
expectPath("MODE-OFF", inRepo("src/x.ts"), true, "path is inside role implementation authority");
const observedTrackerWrite = evaluateBashForRole("plan", "gh project item-edit --id X --field-id F --single-select-option-id O", CWD);
if (!observedTrackerWrite.allowed) {
	throw new Error(`[MODE-OFF] expected shared-core observe to ALLOW raw tracker write, got BLOCK :: ${observedTrackerWrite.reason}`);
}
fs.writeFileSync(path.join(CWD, "WORKFLOW-config.yaml"), "pathway_enforcement:\n  mode: controlled\n");
restoreAuthState();

// [ACTION] Pi must preserve the actual Write/Edit tool action when consulting the shared gate.
// An action-specific grant is not interchangeable with the other mutation transport.
authorizeActions(["edit"]);
expectPathAction("ACTION-EDIT-ONLY", "edit", true);
expectPathAction("ACTION-EDIT-ONLY", "write", false);
restoreAuthState();
authorizeActions(["write"]);
expectPathAction("ACTION-WRITE-ONLY", "write", true);
expectPathAction("ACTION-WRITE-ONLY", "edit", false);
restoreAuthState();
await expectRegisteredHandlerPreservesAction();

// [AUTH] Pi must translate into the SAME shared Path Gate policy: removing or corrupting the
// authorization / active-command evidence now blocks even otherwise-allowed source writes.
fs.rmSync(AUTH_PATH);
expectPath("AUTH", inRepo("src/x.ts"), false, "authorization is absent");
restoreAuthState();
mutateAuth((value) => { delete value.nonce; });
expectPath("AUTH", inRepo("src/x.ts"), false, "missing `nonce`");
restoreAuthState();
mutateAuth((value) => { value.contract_digest = "deadbeef"; });
expectPath("AUTH", inRepo("src/x.ts"), false, "contract digest is corrupt or stale");
restoreAuthState();
mutateAuth((value) => { value.expires_at = "2000-01-01T00:00:00Z"; });
expectPath("AUTH", inRepo("src/x.ts"), false, "authorization is expired or unreadable");
restoreAuthState();
fs.writeFileSync(SESSION_STATE, JSON.stringify({ version: 2, commands: [], taints: [] }, null, 2) + "\n", "utf8");
expectPath("AUTH", inRepo("src/x.ts"), false, "bound command record is no longer active");
restoreAuthState();

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

	// ── [MERGE] raw gh pr merge is denied; the operator merges until a sanctioned helper lands ──
	{ tag: "MERGE", role: "think", kind: "bash", input: "gh pr merge 5", allow: false, note: "think never merges (admission is operator-merged)" },
	{ tag: "MERGE", role: "build-impl", kind: "bash", input: "gh pr merge 7", allow: false, note: "implementer never merges" },
	{ tag: "MERGE", role: "plan", kind: "bash", input: "gh pr merge 5 --squash", allow: false, note: "raw gh pr merge is denied — operator performs the merge until the helper lands" },
	{ tag: "MERGE", role: "recirculator", kind: "bash", input: "gh pr merge 5 --squash", allow: false, note: "raw gh pr merge is denied — operator performs the merge until the helper lands" },
	{ tag: "MERGE", role: "build-finish", kind: "bash", input: "gh pr merge 7 --squash --delete-branch", allow: false, note: "raw gh pr merge is denied — operator performs the merge until the helper lands" },
	{ tag: "MERGE", role: "build-finish", kind: "bash", input: "gh pr merge 7 --auto", allow: false, note: "--auto blocked for every merge role" },

	// ── [REVIEW-ARTIFACT] build-review may write ONLY durable review artifacts ─────────────
	{ tag: "REVIEW-ARTIFACT", role: "build-review", kind: "write", input: inRepo("docs/workflow/code-reviews/pr-7.verdict.json"), allow: true, note: "reviewer may write its durable verdict artifact" },
	{ tag: "REVIEW-ARTIFACT", role: "build-review", kind: "write", input: inRepo("src/x.ts"), allow: false, note: "reviewer cannot write source" },

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
	{ tag: "M2", role: "plan", kind: "bash", input: "gh project item-edit --id X --field-id F --single-select-option-id O", allow: false, note: "raw tracker writes are denied — use the sanctioned transition/helper path" },
	{ tag: "M2", role: "plan", kind: "bash", input: "gh api graphql -f query='mutation{ x }'", allow: false, note: "gh api graphql is an unbounded raw surface — denied for all" },
	{ tag: "M2", role: "plan", kind: "bash", input: "gh api --method POST repos/o/r/issues/5/dependencies/blocked_by -F issue_id=9", allow: false, note: "raw blocked-by writes are denied — use the sanctioned transition/helper path" },

	// ── [M3b] $VAR-bearing cross-repo target refused fail-closed ─────────────────────────────
	{ tag: "M3b", role: "build-finish", kind: "bash", input: "git --git-dir=$PWD/../other/.git --work-tree=$PWD/../other commit -m x", allow: false, note: "$PWD indirection" },
	{ tag: "M3b", role: "build-finish", kind: "bash", input: 'git -C "$HOME/victim" commit -m x', allow: false, note: "$HOME indirection" },
	{ tag: "M3b", role: "build-finish", kind: "bash", input: "git -C ../../x commit -m x", allow: false, note: "literal ../../ escape" },

	// ── [WIDEN] git must respect the path ACL (B-2: no widening file authority) ──────────────
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git rm docs/specs/x.md", allow: false, note: "git rm of a blocked spec" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git checkout HEAD -- docs/prd/x.md", allow: false, note: "git checkout overwrites the PRD" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git restore --source=HEAD CLAUDE.md", allow: false, note: "git restore overwrites CLAUDE.md" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git rm src/old.test.ts", allow: true, note: "git rm of a source file is fine" },
	{ tag: "WIDEN", role: "build-finish", kind: "bash", input: "git checkout -b build/wave1", allow: true, note: "branch creation is not a targeted file write" },

	// ── [PARENT] cannot rm/redirect a dir that contains a protected surface (B-1/M-4) ────────
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "rm -rf docs", allow: false, note: "rm of docs (contains prd/specs/…)" },
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "rm -rf docs/workflow", allow: false, note: "rm of docs/workflow (contains recirculator/pillar-matrices)" },
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "ln -s /tmp/pi-idc/build-finish/wf docs/workflow", allow: false, note: "redirect docs/workflow" },
	{ tag: "PARENT", role: "build-finish", kind: "bash", input: "rm -rf src/legacy", allow: true, note: "rm of a source subdir is fine" },

	// ── [PUSH] remote-ref destruction is blocked for all (m-1) ──────────────────────────────
	{ tag: "PUSH", role: "build-impl", kind: "bash", input: "git push origin :main", allow: false, note: "empty-source refspec deletes the ref" },
	{ tag: "PUSH", role: "build-impl", kind: "bash", input: "git push origin --delete main", allow: false, note: "--delete remote ref" },
	{ tag: "PUSH", role: "build-impl", kind: "bash", input: "git push --mirror origin", allow: false, note: "--mirror overwrites all refs" },

	// ── [ADMIN] gh pr merge --admin bypasses branch protection — blocked for all merge roles ──
	{ tag: "ADMIN", role: "build-finish", kind: "bash", input: "gh pr merge 7 --admin --squash", allow: false, note: "--admin blocked (bypasses branch protection / the green-gate)" },

	// ── [SAFELIST] git is a SAFELIST — every non-listed worktree/history op is denied (B-4) ──
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git apply /tmp/evil.patch", allow: false, note: "git apply writes the worktree" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git am /tmp/x.patch", allow: false, note: "git am" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git reset --hard origin/main", allow: false, note: "git reset --hard overwrites the worktree" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git cherry-pick deadbeef", allow: false, note: "git cherry-pick" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git stash pop", allow: false, note: "git stash pop" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git revert HEAD", allow: false, note: "git revert" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git rebase main", allow: false, note: "git rebase" },
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git merge other", allow: false, note: "git merge (local) — merge is operator-performed until the sanctioned helper lands" },
	// the `<ref> <pathspec>` checkout form WITHOUT `--` is now path-checked
	{ tag: "SAFELIST", role: "build-finish", kind: "bash", input: "git checkout HEAD~1 docs/prd/x.md", allow: false, note: "checkout <ref> <pathspec> overwrites the PRD" },

	// ── [APIMERGE] every merge goes through the gated `gh pr merge` — not via raw gh api (B-3) ─
	{ tag: "APIMERGE", role: "build-finish", kind: "bash", input: "gh api -X PUT repos/o/r/pulls/8/merge", allow: false, note: "api REST merge bypasses the gated gh pr merge" },
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

	// ── [B5] inline `-c` config (alias→shell) + UNKNOWN subcommand denied fail-closed ────────
	{ tag: "B5", role: "build-finish", kind: "bash", input: "git -c alias.pwn='!rm -rf docs' pwn", allow: false, note: "inline -c alias runs arbitrary shell" },
	{ tag: "B5", role: "build-review", kind: "bash", input: "git -c alias.pwn='!rm -rf docs' pwn", allow: false, note: "inline -c blocked even for the read-only reviewer" },
	{ tag: "B5", role: "build-finish", kind: "bash", input: "git -c alias.co=checkout co -- docs/specs/x.md", allow: false, note: "inline -c blocked regardless of payload" },
	{ tag: "B5", role: "build-finish", kind: "bash", input: "git frobnicate --force", allow: false, note: "unknown subcommand denied fail-closed" },
	{ tag: "B5", role: "build-review", kind: "bash", input: "git mergetool", allow: false, note: "unknown/unsafe subcommand for read-only role" },
	{ tag: "B5", role: "build-finish", kind: "bash", input: "git status", allow: true, note: "a recognized read is still allowed" },
	{ tag: "B5", role: "sequence", kind: "bash", input: "git log --oneline", allow: true, note: "reads are allowed for every role" },

	// ── [B6] --pathspec-from-file reads an unbounded pathspec set → denied ───────────────────
	{ tag: "B6", role: "build-finish", kind: "bash", input: "git rm --pathspec-from-file=/tmp/x.txt", allow: false, note: "pathspec-from-file is unbounded" },
	{ tag: "B6", role: "build-finish", kind: "bash", input: "git restore --pathspec-from-file /tmp/x.txt", allow: false, note: "space form" },

	// ── [M7] single-operand / no-`--` checkout + restore are path-checked ────────────────────
	{ tag: "M7", role: "build-finish", kind: "bash", input: "git checkout docs/specs/x.md", allow: false, note: "1-operand checkout of a blocked path" },
	{ tag: "M7", role: "build-finish", kind: "bash", input: "git checkout .", allow: false, note: "whole-tree discard hits a protected ancestor" },
	{ tag: "M7", role: "build-finish", kind: "bash", input: "git restore docs/specs/x.md", allow: false, note: "1-operand restore of a blocked path" },

	// ── [M6g] glob pathspec on a git op → refused ───────────────────────────────────────────
	{ tag: "M6g", role: "build-finish", kind: "bash", input: "git rm -r 'docs/*'", allow: false, note: "glob pathspec" },
	{ tag: "M6g", role: "build-finish", kind: "bash", input: "git checkout HEAD -- 'docs/*'", allow: false, note: "glob pathspec after --" },

	// ── [B7] gh-api blocked-by exception matches the POSITIONAL endpoint only ────────────────
	{ tag: "B7", role: "build-finish", kind: "bash", input: "gh api -X PUT repos/o/r/pulls/8/merge -f x=dependencies/blocked_by", allow: false, note: "marker smuggled in a -f value cannot unlock a merge" },
	{ tag: "B7", role: "build-finish", kind: "bash", input: "gh api -X DELETE repos/o/r/releases/1 -f junk=dependencies/blocked_by", allow: false, note: "marker cannot unlock a release delete" },
	{ tag: "B7", role: "build-review", kind: "bash", input: "gh api -X POST repos/o/r/issues/5/dependencies/blocked_by -f issue=1", allow: false, note: "even the blocked-by write is denied for the read-only reviewer" },

	// ── [JUDGE] reset/pull/stash deliberately DENIED (loop unstages via `git restore --staged`) ─
	{ tag: "JUDGE", role: "build-impl", kind: "bash", input: "git reset HEAD src/x.ts", allow: false, note: "reset not safelisted — unstage via restore --staged" },
	{ tag: "JUDGE", role: "build-finish", kind: "bash", input: "git pull origin main", allow: false, note: "pull merges remote into the worktree — not in the IDC flow" },
	{ tag: "JUDGE", role: "build-impl", kind: "bash", input: "git stash", allow: false, note: "stash not in the IDC flow" },
	{ tag: "JUDGE", role: "build-impl", kind: "bash", input: "git restore --staged src/x.ts", allow: true, note: "the safelisted unstage path" },
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

fs.rmSync(CWD, { recursive: true, force: true });

if (failures === 0) {
	console.log(`PASS: per-role guard ACL holds (${cases.length} cases: file-write fail-closed preserved; shared Path Gate auth state is mandatory for Pi writes; B1/B2/BR/M3 bypasses closed; build-review durable artifact lane scoped; scoped git grant preserved; raw tracker/merge surfaces now fail closed through the shared Path Gate)`);
	process.exit(0);
}
console.log(`FAIL: ${failures}/${cases.length} guard ACL assertions failed`);
process.exit(1);
