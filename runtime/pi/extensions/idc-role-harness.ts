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
import {
	analyzeBashCommand,
	collectMutationPaths,
	compactRoots,
	isAlwaysAllowedDevice,
	isGitFinalizationMutation,
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

	if (role === "build-review") {
		return {
			allowed: false,
			reason: `build-review is read-only; mutating bash blocked (${mutations.map((m) => m.kind).join(", ")})`,
			allowedRoots: policy.allowedRoots,
			blockedSurfaces: policy.blockedSurfaces,
			attemptedPaths: collectMutationPaths(mutations, cwd),
		};
	}

	for (const mutation of mutations) {
		if (isGitMutation(mutation)) {
			if (role === "build-finish" && isGitFinalizationMutation(mutation)) continue;
			return {
				allowed: false,
				reason: `${mutation.kind} is outside ${role} authority`,
				allowedRoots: policy.allowedRoots,
				blockedSurfaces: policy.blockedSurfaces,
				attemptedPaths: collectMutationPaths([mutation], cwd),
			};
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
				allowedRoots: ["none (read-only role)"],
				blockedSurfaces: ["all file writes", "all mutating bash"],
				readOnly: true,
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

function matchesRule(absPath: string, cwd: string, rule: string): boolean {
	if (!rule || rule.includes("source/tests/implementation")) return false;
	if (rule.startsWith("**/")) {
		const suffix = rule.slice(3);
		const rel = normalizeRelative(cwd, absPath);
		return rel === suffix || rel.endsWith(`/${suffix}`);
	}

	if (rule.endsWith("/**")) {
		const baseRule = rule.slice(0, -3);
		const base = path.isAbsolute(baseRule) ? path.normalize(baseRule) : path.resolve(cwd, baseRule);
		return isInsideOrEqual(base, absPath);
	}

	const exact = path.isAbsolute(rule) ? path.normalize(rule) : path.resolve(cwd, rule);
	return path.normalize(absPath) === exact;
}
