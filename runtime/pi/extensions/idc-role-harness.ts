// ─────────────────────────────────────────────────────────────────────────────
// VENDORED from pi-harnesses · upstream path: extensions/idc-role-harness.ts
// Upstream license: MIT © 2026 IndyDevDan — preserved verbatim in
//   runtime/pi/LICENSE-pi-harnesses (no-edit). See repo-root ATTRIBUTIONS.md.
// Vendored into idc-workflow for the Phase-8 Pi runtime (issue #27, unit B1).
// Upstream source preserved byte-for-byte below; IDC-local additions are marked
// with an "IDC-LOCAL" banner comment.
// ─────────────────────────────────────────────────────────────────────────────

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as path from "node:path";
import type { BashMutation } from "./guard-shell-core.ts";
import {
	analyzeBashCommand,
	collectMutationPaths,
	compactRoots,
	gitGlobalPathOutsideCwd,
	isAlwaysAllowedDevice,
	isGitForcePush,
	isGitMutation,
	isInsideOrEqual,
	looksLikeLiveOperation,
	matchesSecretDenylist,
	normalizeRelative,
	normalizeToolPath,
} from "./guard-shell-core.ts";

// Re-export the shared helpers external importers (tests) consume from this module.
export { analyzeBashCommand, normalizeToolPath } from "./guard-shell-core.ts";

export type IdcRole =
	| "think"
	| "plan"
	| "sequence"
	| "recirculator"
	| "build-impl"
	| "build-review"
	| "build-finish";

type GuardMode = "off" | "warn" | "block";

export interface GuardOptions {
	recirculatorAllowCanonical?: boolean;
	liveOpsApproved?: boolean;
}

export interface GuardEvaluation {
	allowed: boolean;
	reason: string;
	allowedRoots: string[];
	blockedSurfaces: string[];
	attemptedPaths?: string[];
}

interface PathPolicy {
	allowedRoots: string[];
	blockedSurfaces: string[];
	allowRepoImplementation?: boolean;
	readOnly?: boolean;
}

const IDC_ROLES = new Set<IdcRole>([
	"think",
	"plan",
	"sequence",
	"recirculator",
	"build-impl",
	"build-review",
	"build-finish",
]);

// v3 gate-at-Think model: Think authors AND gates the PRD + TRD (the `docs/specs`
// layer) at the end of Think, so the canonical requirements docs are Think's write
// authority — not Plan's. Plan becomes pure decomposition (no requirements authoring,
// no gate). See docs/architecture.md "Runtime model".
const THINK_ALLOWED = [
	"docs/considerations/**",
	"docs/prd/**",
	"docs/specs/**",
	"/tmp/pi-idc/think/**",
	"/tmp/ke-idc-think/**",
];

const PLAN_ALLOWED = [
	"docs/plans/**",
	"docs/workflow/pillar-conflicts/**",
	"docs/workflow/pillar-matrices/**",
	"docs/workflow/phase-planning/**",
	"docs/workflow/audits/**",
	"docs/workflow/handoffs/**",
	"/tmp/pi-idc/plan/**",
	"/tmp/ke-idc-plan/**",
];

const SEQUENCE_ALLOWED = [
	"TRACKER.md",
	"TRACKER-archive.md",
	"docs/workflow/pillar-matrices/**",
	"docs/workflow/audits/**",
	"docs/workflow/code-reviews/**",
	"docs/workflow/handoffs/waves/**",
	"/tmp/pi-idc/sequence/**",
	"/tmp/ke-idc-sequence/**",
];

const RECIRCULATOR_ALLOWED_BASE = [
	"docs/workflow/recirculator/**",
	"docs/workflow/audits/**",
	"docs/workflow/handoffs/recirculations/**",
	"/tmp/pi-idc/recirculator/**",
	"/tmp/ke-idc-recirculator/**",
];

const RECIRCULATOR_CANONICAL_ALLOWED = [
	"docs/prd/**",
	"docs/specs/**",
	"docs/plans/**",
	"CLAUDE.md",
	"AGENTS.md",
	"**/CLAUDE.md",
];

const BUILD_ALLOWED_EXPLICIT = [
	"docs/workflow/operator-todos/**",
	"docs/workflow/code-reviews/**",
	"docs/workflow/handoffs/builds/**",
];

// IDC-LOCAL: roles granted the in-repo git lifecycle (branch/commit/push/`gh pr create`),
// mirroring their Claude counterparts. force-push and cross-repo `-C` are blocked for ALL of
// them; build-review + sequence get NO git authority.
const GIT_ROLES = new Set<IdcRole>(["think", "plan", "build-impl", "build-finish", "recirculator"]);
// Roles that may `gh pr merge`: build-finish (the build PR), plan (its planning PR),
// recirculator (its doc-sync PR). Each merges its own PR on the role's BEHAVIORAL green/PASS
// decision (the prompt's /fullauto-goal contract), mirroring the Claude finisher/recirculator —
// no hard interlock. force-push and cross-repo `-C` stay blocked for all roles.
const MERGE_ROLES = new Set<IdcRole>(["build-finish", "plan", "recirculator"]);

// IDC-LOCAL (guard-bypass B-4, class-level): the git subcommands an IDC git-role may run. A
// SAFELIST, not a denylist — every OTHER worktree-rewriting/history subcommand (apply, am,
// cherry-pick, revert, reset, merge, rebase, pull, stash, clean, …) is DENIED by default, so a
// new dangerous subcommand can't slip through. The path-bearing members (rm/mv/restore/checkout)
// are ADDITIONALLY path-checked via gitTouchedPaths; commit/add/push/fetch/switch/branch/tag carry
// no targeted worktree-file write (push force/ref-delete is caught separately by isGitForcePush).
const GIT_SAFE_SUBCOMMANDS = new Set(["commit", "add", "push", "fetch", "switch", "checkout", "restore", "rm", "mv", "branch", "tag"]);

const BUILD_IMPL_ALLOWED = [
	"repo source/tests/implementation files except blocked governance surfaces",
	...BUILD_ALLOWED_EXPLICIT,
	"/tmp/pi-idc/build-impl/**",
	"/tmp/ke-idc-build/**",
];

const BUILD_FINISH_ALLOWED = [
	"repo source/tests/implementation files except blocked governance surfaces",
	...BUILD_ALLOWED_EXPLICIT,
	"/tmp/pi-idc/build-finish/**",
	"/tmp/ke-idc-build/**",
];

const BUILD_REVIEW_ALLOWED = [
	"docs/workflow/code-reviews/**",
	"/tmp/pi-idc/build-review/**",
	"/tmp/ke-idc-build/**",
];

const BUILD_BLOCKED = [
	"docs/prd/**",
	"docs/specs/**",
	"docs/plans/**",
	"docs/workflow/recirculator/**",
	"docs/workflow/pillar-matrices/**",
	"docs/workflow/pillar-conflicts/**",
	"TRACKER.md",
	"TRACKER-archive.md",
	".pi/agents/**",
	"WORKFLOW.md",
	"WORKFLOW-config.yaml",
	"CLAUDE.md",
	"AGENTS.md",
	"**/CLAUDE.md",
];

// IDC roles arm the live-operation approval gate (A1) only via opt-in: this set is
// empty by default (no IDC role does cloud/infra live ops), and PI_IDC_LIVE_OP_ROLES
// can arm specific roles at runtime. The gate is inert until a role is armed, so it
// is parity-complete with specialist-guard without changing default IDC behavior.
const LIVE_OP_ROLES = new Set<IdcRole>([]);
const LIVE_OP_APPROVAL_ENV = "PI_IDC_ALLOW_LIVE_OPS";

export function isIdcRole(role: string): role is IdcRole {
	return IDC_ROLES.has(role as IdcRole);
}

// ─────────────────────────────────────────────────────────────────────────────
// IDC-LOCAL — glass-wall directional ACL for the coms_net_send seam (absorbs
// source contract B3). Extends the per-role guard machinery from the path/bash
// seams to the coms-net send seam: a role resident may message only peers
// STRICTLY DOWNSTREAM of it in the IDC river, plus the Recirculator peer — never
// an upstream peer. Fail-closed: an unknown sender or unmappable target denies.
//
// The IDC river is a linear order — think → plan → sequence → build-impl →
// build-review → build-finish — with the Recirculator a universal DOWNSTREAM sink
// reachable from any role. A send is allowed iff the target is strictly later in
// this order than the sender, OR the target is the Recirculator. Everything else
// (upstream, self, an unknown sender, or an unmappable target) is denied
// fail-closed. The Recirculator as a SOURCE has no non-Recirculator downstream,
// so it may only target the Recirculator.
// ─────────────────────────────────────────────────────────────────────────────

const RIVER_ORDER: IdcRole[] = ["think", "plan", "sequence", "build-impl", "build-review", "build-finish"];

export interface ComsNetSendEvaluation {
	allowed: boolean;
	reason: string;
	senderRole?: IdcRole;
	targetRole?: IdcRole;
}

// Peer names on the coms-net hub are the role names themselves (idc-pi launches
// each role with `--name <role>`); the hub may uniquify a duplicate with a
// trailing "-<n>". Map a peer name (or raw role) back to its IdcRole, else undefined.
export function resolveComsNetPeerRole(nameOrRole: string): IdcRole | undefined {
	const raw = (nameOrRole ?? "").trim();
	if (!raw) return undefined;
	if (isIdcRole(raw)) return raw;
	const stripped = raw.replace(/-\d+$/, "");
	return isIdcRole(stripped) ? stripped : undefined;
}

export function evaluateComsNetSendForRole(senderRaw: string, targetRaw: string): ComsNetSendEvaluation {
	const senderRole = resolveComsNetPeerRole(senderRaw);
	const targetRole = resolveComsNetPeerRole(targetRaw);

	// Fail-closed: an unidentifiable sender or target denies.
	if (!senderRole) {
		return { allowed: false, reason: `coms-net glass-wall: unknown sender '${senderRaw}' — fail-closed deny` };
	}
	if (!targetRole) {
		return { allowed: false, reason: `coms-net glass-wall: unknown target '${targetRaw}' — fail-closed deny`, senderRole };
	}

	// The Recirculator is the universal downstream sink — always an allowed target.
	if (targetRole === "recirculator") {
		return { allowed: true, reason: "target is the Recirculator peer (universal downstream sink)", senderRole, targetRole };
	}
	// The Recirculator as a source: no non-Recirculator peer is downstream of the sink.
	if (senderRole === "recirculator") {
		return { allowed: false, reason: "coms-net glass-wall: recirculator is a sink; no downstream non-Recirculator peer", senderRole, targetRole };
	}

	const si = RIVER_ORDER.indexOf(senderRole);
	const ti = RIVER_ORDER.indexOf(targetRole);
	if (si < 0 || ti < 0) {
		return { allowed: false, reason: "coms-net glass-wall: role not in river order — fail-closed deny", senderRole, targetRole };
	}
	if (ti > si) {
		return { allowed: true, reason: `target ${targetRole} is downstream of ${senderRole}`, senderRole, targetRole };
	}
	return {
		allowed: false,
		reason: `coms-net glass-wall: ${targetRole} is upstream of or equal to ${senderRole} — send denied`,
		senderRole,
		targetRole,
	};
}

export function evaluatePathForRole(
	role: IdcRole,
	attemptedPath: string,
	cwd: string,
	options: GuardOptions = {},
): GuardEvaluation {
	const absPath = path.normalize(path.isAbsolute(attemptedPath) ? attemptedPath : normalizeToolPath(attemptedPath, cwd));
	const policy = pathPolicyFor(role, options);

	if (policy.readOnly) {
		return {
			allowed: false,
			reason: `${role} is read-only; file writes are not allowed`,
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
			attemptedPaths: [absPath],
		};
	}

	// A2: any-depth secret denylist. A secret-bearing file is blocked even when it
	// sits inside an otherwise-writable authority root (e.g. scripts/.env, deep/key.pem).
	if (matchesSecretDenylist(absPath)) {
		return {
			allowed: false,
			reason: `path is a protected secret file blocked for ${role}`,
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
			attemptedPaths: [absPath],
		};
	}

	if (policy.allowRepoImplementation) {
		if (matchesAny(absPath, cwd, policy.blockedSurfaces)) {
			return {
				allowed: false,
				reason: `path is on a blocked governance/canonical surface for ${role}`,
				allowedRoots: policy.allowedRoots,
				blockedSurfaces: policy.blockedSurfaces,
				attemptedPaths: [absPath],
			};
		}

		// IDC-LOCAL (guard-bypass B-1/M-4): deny operating on a PARENT directory of a protected
		// surface (e.g. `rm -rf docs/workflow`, `ln -s scratch docs/workflow`). The blocked
		// surfaces are leaf patterns, so without this a role could delete/redirect the ancestor
		// dir and thereby destroy or forge the protected files (e.g. the PRD or specs).
		if (isAncestorOfBlockedSurface(absPath, cwd, policy.blockedSurfaces)) {
			return {
				allowed: false,
				reason: `path is an ancestor of a blocked governance/canonical surface for ${role} (cannot rm/redirect a directory that contains protected files)`,
				allowedRoots: policy.allowedRoots,
				blockedSurfaces: policy.blockedSurfaces,
				attemptedPaths: [absPath],
			};
		}

		const explicitAllowed = policy.allowedRoots.filter((rule) => rule !== "repo source/tests/implementation files except blocked governance surfaces");
		if (matchesAny(absPath, cwd, explicitAllowed) || isInsideOrEqual(path.resolve(cwd), absPath)) {
			return {
				allowed: true,
				reason: "path is inside role implementation authority",
				allowedRoots: policy.allowedRoots,
				blockedSurfaces: policy.blockedSurfaces,
				attemptedPaths: [absPath],
			};
		}

		return {
			allowed: false,
			reason: `path is outside ${role} repo/scratch authority`,
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
			attemptedPaths: [absPath],
		};
	}

	if (matchesAny(absPath, cwd, policy.allowedRoots)) {
		return {
			allowed: true,
			reason: "path is inside role write authority",
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
			attemptedPaths: [absPath],
		};
	}

	return {
		allowed: false,
		reason: `path is outside ${role} write authority`,
		allowedRoots: policy.allowedRoots,
		blockedSurfaces: policy.blockedSurfaces,
		attemptedPaths: [absPath],
	};
}

export function evaluateBashForRole(
	role: IdcRole,
	command: string,
	cwd: string,
	options: GuardOptions = {},
): GuardEvaluation {
	const policy = pathPolicyFor(role, options);

	const liveOp = analyzeLiveOperation(role, command, options);
	if (liveOp) {
		return {
			allowed: false,
			reason: liveOp.reason,
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
		};
	}

	const mutations = analyzeBashCommand(command);
	if (mutations.length === 0) {
		return {
			allowed: true,
			reason: "no obvious mutating bash detected",
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
		};
	}

	for (const mutation of mutations) {
		// IDC-LOCAL: GitHub-CLI ACL. gh WRITES are gated per role — build-review is read-only
		// on the board, dangerous non-tracker verbs are denied for all, and pr-create/merge are
		// role-scoped (the merge-on-green/PASS decision is behavioral, in the role prompt). gh
		// reads + `issue/pr comment` never reach here (classifyGhCommand emits no mutation for
		// them), so they stay allowed for every role.
		if (mutation.ghOp) {
			const ghEval = evaluateGhForRole(role, mutation, policy);
			if (!ghEval.allowed) return ghEval;
			continue;
		}

		// IDC-LOCAL: git ACL. Role-scoped in-repo lifecycle; force-push and a cross-repo `-C`
		// target are blocked for ALL roles (guard-bypass B2). build-review + sequence get no git.
		if (isGitMutation(mutation)) {
			const gitEval = evaluateGitForRole(role, mutation, cwd, policy);
			if (!gitEval.allowed) return gitEval;
			continue;
		}

		if (mutation.unscoped || mutation.paths.length === 0) {
			return {
				allowed: false,
				reason: `${mutation.kind} has no safely extractable path`,
				allowedRoots: policy.allowedRoots,
				blockedSurfaces: policy.blockedSurfaces,
			};
		}

		for (const rawPath of mutation.paths) {
			if (isAlwaysAllowedDevice(rawPath)) continue;
			// IDC-LOCAL (guard-bypass M-5): a glob operand (`rm -rf *`, `rm -rf docs/*`) can expand
			// across a protected surface, which the static guard cannot enumerate — refuse it.
			if (/[*?[]/.test(rawPath)) {
				return {
					allowed: false,
					reason: `${mutation.kind} uses a glob (${rawPath}) that cannot be statically bounded against protected surfaces`,
					allowedRoots: policy.allowedRoots,
					blockedSurfaces: policy.blockedSurfaces,
					attemptedPaths: [rawPath],
				};
			}
			const normalized = normalizeToolPath(rawPath, cwd);
			const pathEval = evaluatePathForRole(role, normalized, cwd, options);
			if (!pathEval.allowed) {
				return {
					allowed: false,
					reason: `${mutation.kind} targets ${normalized}: ${pathEval.reason}`,
					allowedRoots: policy.allowedRoots,
					blockedSurfaces: policy.blockedSurfaces,
					attemptedPaths: [normalized],
				};
			}
		}
	}

	return {
		allowed: true,
		reason: "mutating bash targets are inside role authority",
		allowedRoots: policy.allowedRoots,
		blockedSurfaces: policy.blockedSurfaces,
		attemptedPaths: collectMutationPaths(mutations, cwd),
	};
}

// IDC-LOCAL: per-role git ACL. The grant mirrors each role's Claude counterpart (GIT_ROLES);
// force-push and a cross-repo `-C`/`--git-dir`/`--work-tree` target are blocked for ALL roles
// (the latter is guard-bypass B2). build-review + sequence hold no git authority at all.
function evaluateGitForRole(role: IdcRole, mutation: BashMutation, cwd: string, policy: PathPolicy): GuardEvaluation {
	const deny = (reason: string): GuardEvaluation => ({
		allowed: false,
		reason,
		allowedRoots: policy.allowedRoots,
		blockedSurfaces: policy.blockedSurfaces,
		attemptedPaths: collectMutationPaths([mutation], cwd),
	});
	// IDC-LOCAL (guard-bypass B-5): inline `-c`/`--config-env` can define an alias that runs
	// arbitrary shell (`git -c alias.x='!rm -rf docs' x`) — total guard evasion — so it is refused
	// for EVERY role (placed before the role gate so the read-only reviewer is covered too).
	if (mutation.gitInlineConfig) return deny("git inline -c/--config-env is blocked (it can define an alias that runs arbitrary shell)");
	if (isGitForcePush(mutation)) return deny(`force/destructive push is blocked for all roles (${mutation.kind})`);
	if (gitGlobalPathOutsideCwd(mutation, cwd)) return deny(`${mutation.kind} targets a repo outside the run repo via -C/--git-dir/--work-tree (or an unresolvable $VAR)`);
	if (!GIT_ROLES.has(role)) return deny(`${mutation.kind} is outside ${role} git authority`);
	if (!GIT_SAFE_SUBCOMMANDS.has(mutation.gitSubcommand ?? "")) {
		return deny(`git ${mutation.gitSubcommand || "(unknown)"} is not in the IDC git safelist (a worktree-rewriting/history/unknown op that could reach a protected surface)`);
	}
	// IDC-LOCAL (guard-bypass B-6): `--pathspec-from-file` / `--pathspec-file-nul` read the
	// pathspecs from a FILE the static guard cannot see → the touched set is unbounded → refuse.
	if ((mutation.gitArgs ?? []).some((a) => a === "--pathspec-from-file" || a.startsWith("--pathspec-from-file=") || a === "--pathspec-file-nul")) {
		return deny(`git ${mutation.gitSubcommand} --pathspec-from-file reads pathspecs from a file the guard cannot bound`);
	}
	// IDC-LOCAL (guard-bypass B-2): git must NOT widen the file-write ACL. A `git rm`/`checkout`/
	// `restore`/`mv` that names a path overwrites/deletes that WORKING-TREE file, so each named
	// pathspec is re-checked against the role's path authority — a blocked governance/canonical
	// surface (PRD/spec/plans/CLAUDE.md) is DENIED exactly as a direct write is.
	for (const touched of gitTouchedPaths(mutation)) {
		// (M-6) a glob pathspec (`git rm 'docs/*'`) can expand across a protected surface → refuse.
		if (/[*?[]/.test(touched)) return deny(`git ${mutation.gitSubcommand} pathspec '${touched}' uses a glob that cannot be statically bounded`);
		const abs = normalizeToolPath(touched, cwd);
		const pathEval = evaluatePathForRole(role, abs, cwd);
		if (!pathEval.allowed) return deny(`git ${mutation.gitSubcommand} would touch ${abs}: ${pathEval.reason}`);
	}
	return { allowed: true, reason: `${mutation.kind} is within ${role} git authority`, allowedRoots: policy.allowedRoots, blockedSurfaces: policy.blockedSurfaces };
}

// IDC-LOCAL (B-2): the working-tree file operands of a git subcommand that writes/deletes/moves
// specific files. Operands after a `--` separator are always pathspecs; for rm/mv/restore the
// bare non-flag operands are pathspecs too (skipping the `-s`/`--source` value). A bare `git
// checkout <ref>` / `git checkout -b X` (no `--`) is a branch/ref op with no targeted file write,
// so it contributes no pathspec — only the explicit `checkout … -- <paths>` form does.
function gitTouchedPaths(mutation: BashMutation): string[] {
	const sub = mutation.gitSubcommand ?? "";
	if (!["rm", "mv", "restore", "checkout"].includes(sub)) return [];
	const args = mutation.gitArgs ?? [];
	const dd = args.indexOf("--");
	// Everything after a `--` separator is an explicit pathspec, for every form.
	if (dd >= 0) return args.slice(dd + 1).filter((a) => a.length > 0);

	const valueFlags = new Set(["-s", "--source", "--pathspec-from-file"]);
	const operands = (list: string[]): string[] => {
		const out: string[] = [];
		for (let i = 0; i < list.length; i++) {
			const arg = list[i];
			if (valueFlags.has(arg)) {
				i++;
				continue;
			}
			if (arg.startsWith("-")) continue;
			out.push(arg);
		}
		return out;
	};

	// rm/mv/restore are always pathspec-oriented — every bare operand is a file.
	if (sub === "rm" || sub === "mv" || sub === "restore") return operands(args);

	// checkout: branch CREATION (`-b`/`-B`) names a ref, never a file → nothing to path-check.
	// Otherwise path-check EVERY operand (M-7): a leading ref (HEAD~1/main) resolves to a benign
	// in-repo path for the build roles, while a pathspec operand (`docs/specs/x.md`, `.`, a
	// `<ref> <path>` form, or a bare `git checkout <path>`) that reaches a protected surface is
	// caught — closing the single-operand and no-`--` checkout holes.
	if (args.includes("-b") || args.includes("-B")) return [];
	return operands(args);
}

// IDC-LOCAL: per-role GitHub-CLI ACL for the gated gh ops.
function evaluateGhForRole(role: IdcRole, mutation: BashMutation, policy: PathPolicy): GuardEvaluation {
	const deny = (reason: string): GuardEvaluation => ({ allowed: false, reason, allowedRoots: policy.allowedRoots, blockedSurfaces: policy.blockedSurfaces });
	const allow = (reason: string): GuardEvaluation => ({ allowed: true, reason, allowedRoots: policy.allowedRoots, blockedSurfaces: policy.blockedSurfaces });
	switch (mutation.ghOp) {
		case "dangerous":
			return deny(`${mutation.kind} is outside every IDC role authority (not a tracker op)`);
		case "tracker-write":
			if (role === "build-review") return deny(`build-review is read-only on the tracker; ${mutation.kind} blocked (reads + comment only)`);
			return allow(`${mutation.kind} is within ${role} tracker authority`);
		case "pr-create":
			if (!GIT_ROLES.has(role)) return deny(`gh pr create is outside ${role} authority`);
			return allow(`gh pr create is within ${role} authority`);
		case "merge": {
			if (!MERGE_ROLES.has(role)) return deny(`gh pr merge is outside ${role} authority`);
			if (mutation.ghAuto) return deny("gh pr merge --auto is blocked; IDC uses a direct blocking merge");
			if (mutation.ghAdmin) return deny("gh pr merge --admin is blocked; it bypasses branch protection / the green-gate");
			// The merge-on-green + review-PASS decision is BEHAVIORAL — it lives in the role
			// prompt's /fullauto-goal contract (mirroring the Claude finisher), not a hard guard
			// interlock. The guard enforces only role-scope + the --auto/--admin/force-push bounds.
			return allow(`gh pr merge is within ${role} authority`);
		}
		default:
			return allow("gh op not gated");
	}
}

export default async function (pi: ExtensionAPI) {
	const { isToolCallEventType } = await import("@earendil-works/pi-coding-agent");

	pi.registerFlag("idc-role", {
		description: "IDC role name for hard path/bash guardrails",
		type: "string",
		default: undefined,
	});
	pi.registerFlag("idc-guard-mode", {
		description: "IDC guard mode: off, warn, or block",
		type: "string",
		default: process.env.PI_IDC_GUARD_MODE || "block",
	});

	let warnedMissingRole = false;
	let warnedInvalidRole = false;

	pi.on("session_start", async (_event, ctx) => {
		const rawRole = readRawRole(pi);
		if (!rawRole) {
			if (!warnedMissingRole && ctx.hasUI) {
				warnedMissingRole = true;
				ctx.ui.notify("IDC guard loaded without --idc-role; no role path guard active.", "warning");
			}
			return;
		}
		if (!isIdcRole(rawRole)) {
			if (!warnedInvalidRole && ctx.hasUI) {
				warnedInvalidRole = true;
				ctx.ui.notify(`IDC guard role '${rawRole}' is unknown; no role path guard active.`, "error");
			}
			return;
		}

		const mode = readGuardMode(pi);
		const policy = pathPolicyFor(rawRole, readGuardOptions());
		if (ctx.hasUI) {
			ctx.ui.setStatus("idc-role", `IDC: ${rawRole} guard:${mode}`);
			ctx.ui.setTitle(`pi idc:${rawRole}`);
			ctx.ui.notify(`IDC ${rawRole} guard:${mode}. Writes: ${compactRoots(policy.allowedRoots)}`, "info");
		}
	});

	pi.on("tool_call", async (event, ctx) => {
		const rawRole = readRawRole(pi);
		if (!rawRole || !isIdcRole(rawRole)) return undefined;

		const mode = readGuardMode(pi);
		if (mode === "off") return undefined;

		if (isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
			const attempted = normalizeToolPath(event.input.path, ctx.cwd);
			const evaluation = evaluatePathForRole(rawRole, attempted, ctx.cwd, readGuardOptions());
			return enforceEvaluation({ role: rawRole, mode, tool: event.toolName, attempted, evaluation, ctx });
		}

		if (isToolCallEventType("bash", event)) {
			const command = event.input.command;
			const evaluation = evaluateBashForRole(rawRole, command, ctx.cwd, readGuardOptions());
			return enforceEvaluation({ role: rawRole, mode, tool: "bash", attempted: command, evaluation, ctx });
		}

		return undefined;
	});
}

function pathPolicyFor(role: IdcRole, options: GuardOptions): PathPolicy {
	switch (role) {
		case "think":
			return {
				allowedRoots: THINK_ALLOWED,
				blockedSurfaces: ["master/subphase/pillar plans", "TRACKER.md", "source/tests", "release/merge artifacts"],
			};
		case "plan":
			return {
				allowedRoots: PLAN_ALLOWED,
				blockedSurfaces: ["PRD/TRD requirements docs (Think authors + gates them)", "source/tests", "TRACKER ordering/status", "Build runtime state"],
			};
		case "sequence":
			return {
				allowedRoots: SEQUENCE_ALLOWED,
				blockedSurfaces: ["PRD/spec/master/subphase/pillar plans", "source/tests", "new product scope"],
			};
		case "recirculator":
			return {
				allowedRoots: options.recirculatorAllowCanonical ? [...RECIRCULATOR_ALLOWED_BASE, ...RECIRCULATOR_CANONICAL_ALLOWED] : RECIRCULATOR_ALLOWED_BASE,
				blockedSurfaces: ["source/tests", "tracker scope/order", "ungated canonical edits"],
			};
		case "build-impl":
			return {
				allowedRoots: BUILD_IMPL_ALLOWED,
				blockedSurfaces: BUILD_BLOCKED,
				allowRepoImplementation: true,
			};
		case "build-finish":
			return {
				allowedRoots: BUILD_FINISH_ALLOWED,
				blockedSurfaces: BUILD_BLOCKED,
				allowRepoImplementation: true,
			};
		case "build-review":
			return {
				allowedRoots: BUILD_REVIEW_ALLOWED,
				blockedSurfaces: ["source/tests", "tracker/board state", "git writes", "canonical docs/plans"],
			};
	}
}

function readRawRole(pi: ExtensionAPI): string | undefined {
	const role = pi.getFlag("idc-role") as string | undefined;
	return role && role.trim().length > 0 ? role.trim() : undefined;
}

function readGuardMode(pi: ExtensionAPI): GuardMode {
	const mode = String(pi.getFlag("idc-guard-mode") || process.env.PI_IDC_GUARD_MODE || "block").trim();
	return mode === "off" || mode === "warn" || mode === "block" ? mode : "block";
}

function readGuardOptions(): GuardOptions {
	return {
		recirculatorAllowCanonical: process.env.PI_IDC_RECIRCULATOR_ALLOW_CANONICAL === "1",
		liveOpsApproved: process.env[LIVE_OP_APPROVAL_ENV] === "1",
	};
}

// A1: live-operation approval gate, mirroring specialist-guard (inert/opt-in). Returns
// a block reason only when the role is armed (LIVE_OP_ROLES or PI_IDC_LIVE_OP_ROLES),
// the operator has not approved (options.liveOpsApproved / PI_IDC_ALLOW_LIVE_OPS=1), and
// the command matches a destructive cloud/infra verb. The shared detector keys off the
// destructive verb only, so a benign read word in a flag value/comment cannot de-arm it.
function analyzeLiveOperation(role: IdcRole, command: string, options: GuardOptions): { reason: string } | null {
	if (!armedLiveOpRoles().has(role)) return null;
	if (options.liveOpsApproved === true || process.env[LIVE_OP_APPROVAL_ENV] === "1") return null;
	if (!looksLikeLiveOperation(command)) return null;
	return {
		reason: `live operation requires explicit operator approval for ${role}; preview the command and set ${LIVE_OP_APPROVAL_ENV}=1 only after approval`,
	};
}

function armedLiveOpRoles(): Set<string> {
	const armed = new Set<string>(LIVE_OP_ROLES);
	const raw = process.env.PI_IDC_LIVE_OP_ROLES;
	if (raw) {
		for (const role of raw.split(",")) {
			const trimmed = role.trim();
			if (trimmed) armed.add(trimmed);
		}
	}
	return armed;
}

function enforceEvaluation(args: {
	role: IdcRole;
	mode: Exclude<GuardMode, "off">;
	tool: string;
	attempted: string;
	evaluation: GuardEvaluation;
	ctx: { hasUI: boolean; ui: { notify(message: string, type?: "info" | "warning" | "error"): void } };
}) {
	if (args.evaluation.allowed) return undefined;
	const message = formatGuardMessage(args.role, args.mode, args.tool, args.attempted, args.evaluation);
	if (args.mode === "warn") {
		if (args.ctx.hasUI) args.ctx.ui.notify(message, "warning");
		return undefined;
	}
	if (args.ctx.hasUI) args.ctx.ui.notify(message, "error");
	return { block: true, reason: message };
}

function formatGuardMessage(role: IdcRole, mode: GuardMode, tool: string, attempted: string, evaluation: GuardEvaluation): string {
	return [
		`IDC guard blocked ${tool} for role ${role}.`,
		`Attempted path/command: ${attempted}`,
		`Guard mode: ${mode}`,
		`Reason: ${evaluation.reason}`,
		`Allowed roots: ${evaluation.allowedRoots.join(", ")}`,
		`Blocked surfaces: ${evaluation.blockedSurfaces.join(", ")}`,
	].join("\n");
}

function matchesAny(absPath: string, cwd: string, rules: string[]): boolean {
	return rules.some((rule) => matchesRule(absPath, cwd, rule));
}

// IDC-LOCAL (guard-bypass B-1/M-4): true when `absPath` is an ancestor-or-equal of the base
// directory of any `…/**` blocked surface — i.e. operating on `absPath` (rm/ln/mv of a dir)
// would reach into a protected surface. Case-folded to match the M3 host semantics.
function isAncestorOfBlockedSurface(absPath: string, cwd: string, blockedSurfaces: string[]): boolean {
	const lc = (value: string): string => value.toLowerCase();
	const target = lc(path.normalize(absPath));
	return blockedSurfaces.some((rule) => {
		if (!rule.endsWith("/**")) return false;
		const baseRule = rule.slice(0, -3);
		const base = lc(path.isAbsolute(baseRule) ? path.normalize(baseRule) : path.resolve(cwd, baseRule));
		return isInsideOrEqual(target, base);
	});
}

function matchesRule(absPath: string, cwd: string, rule: string): boolean {
	if (!rule || rule.includes("source/tests/implementation")) return false;
	// IDC-LOCAL (guard-bypass M3 fix): compare case-INSENSITIVELY. The primary deployment
	// host is case-insensitive APFS, where `.PI/agents`, `claude.md`, and `docs/PRD` resolve
	// to the same protected files as their canonical-case rules — a case-sensitive compare
	// let a case-variant path slip past the governance blocklist. Folding is safe-erring on a
	// case-sensitive FS (it can only over-match a look-alike path, never under-match a real one).
	const lc = (value: string): string => value.toLowerCase();
	if (rule.startsWith("**/")) {
		const suffix = lc(rule.slice(3));
		const rel = lc(normalizeRelative(cwd, absPath));
		return rel === suffix || rel.endsWith(`/${suffix}`);
	}

	if (rule.endsWith("/**")) {
		const baseRule = rule.slice(0, -3);
		const base = path.isAbsolute(baseRule) ? path.normalize(baseRule) : path.resolve(cwd, baseRule);
		return isInsideOrEqual(lc(base), lc(absPath));
	}

	const exact = path.isAbsolute(rule) ? path.normalize(rule) : path.resolve(cwd, rule);
	return lc(path.normalize(absPath)) === lc(exact);
}
