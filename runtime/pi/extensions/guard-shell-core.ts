// ─────────────────────────────────────────────────────────────────────────────
// VENDORED from pi-harnesses · upstream path: extensions/guard-shell-core.ts
// Upstream license: MIT © 2026 IndyDevDan — preserved verbatim in
//   runtime/pi/LICENSE-pi-harnesses (no-edit). See repo-root ATTRIBUTIONS.md.
// Vendored into idc-workflow for the Phase-8 Pi runtime (issue #27, unit B1).
// Upstream source preserved byte-for-byte below; IDC-local additions are marked
// with an "IDC-LOCAL" banner comment.
// ─────────────────────────────────────────────────────────────────────────────

// Shared guard core for extensions/specialist-guard.ts and extensions/idc-role-harness.ts.
//
// This module holds the byte-identical, package-agnostic substrate the two guards
// used to keep in sync by hand: the bash mutation analyzer, the secret denylist,
// glob/path helpers, and the live-operation detector. It imports only node builtins
// (no pi package alias), so both guards — which load different aliases
// (@mariozechner vs @earendil-works) — can import it. The divergent layers
// (matchesRule / policy / evaluate* / the pi tool_call handler) stay in each guard.
//
// Loaded as a sibling extension module exactly like extensions/themeMap.ts, so it
// resolves under both bun (tests) and Pi's jiti runtime (`pi -e .../extensions/*.ts`).

import * as os from "node:os";
import * as path from "node:path";

export interface BashMutation {
	kind: string;
	paths: string[];
	unscoped?: boolean;
	// For `git <sub>` mutations: the parsed subcommand and the tokens after it, so
	// policy layers can tier flags (e.g. push --force) without re-parsing the
	// command string or deriving data from the display label.
	gitSubcommand?: string;
	gitArgs?: string[];
}

// git global options that consume the following token, so the subcommand finder
// must skip both the flag and its value before reading the subcommand.
const GIT_VALUE_OPTIONS = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace"]);

const GIT_ALWAYS_MUTATING_SUBCOMMANDS = new Set([
	"add",
	"am",
	"apply",
	"bisect",
	"checkout",
	"cherry-pick",
	"clean",
	"clone",
	"commit",
	"fetch",
	"filter-branch",
	"gc",
	"init",
	"maintenance",
	"merge",
	"mv",
	"pull",
	"push",
	"rebase",
	"reset",
	"restore",
	"revert",
	"rm",
	"switch",
	"update-index",
	"update-ref",
]);

const GIT_BRANCH_MUTATION_FLAGS = new Set([
	"-d", "-D", "-m", "-M", "-c", "-C",
	"--delete", "--move", "--copy", "--force", "--unset-upstream",
]);
const GIT_BRANCH_READ_VALUE_OPTIONS = new Set([
	"--contains", "--no-contains", "--merged", "--no-merged",
	"--points-at", "--format", "--sort", "--color", "--column",
]);

const GIT_TAG_MUTATION_FLAGS = new Set([
	"-a", "-s", "-u", "-f", "-d",
	"--annotate", "--sign", "--local-user", "--force", "--delete",
]);
const GIT_TAG_READ_VALUE_OPTIONS = new Set([
	"--contains", "--no-contains", "--points-at", "--format", "--sort", "--color", "--column",
]);

const GIT_REMOTE_MUTATING_SUBCOMMANDS = new Set(["add", "remove", "rm", "rename", "set-url", "set-branches", "set-head", "prune", "update"]);
const GIT_WORKTREE_MUTATING_SUBCOMMANDS = new Set(["add", "move", "remove", "rm", "prune", "repair"]);
const GIT_SUBMODULE_MUTATING_SUBCOMMANDS = new Set(["add", "update", "init", "deinit", "sync", "absorbgitdirs"]);
const GIT_REFLOG_MUTATING_SUBCOMMANDS = new Set(["delete", "expire"]);
const GIT_NOTES_MUTATING_SUBCOMMANDS = new Set(["add", "append", "copy", "edit", "merge", "prune", "remove"]);

// truncate/shred take value options whose argument must not be mistaken for a file
// target (e.g. the `0` in `truncate -s 0 file` or the `3` in `shred -n 3 file`).
const TRUNCATE_VALUE_OPTIONS = new Set(["-s", "--size", "-r", "--reference"]);
const SHRED_VALUE_OPTIONS = new Set(["-n", "--iterations", "-s", "--size", "--random-source"]);

// Any-depth secret-file denylist, shared so both guards block the same protected
// surfaces. Best-effort (honors guard modes), not a fail-closed sandbox. All patterns
// are `**/`-anchored so they match at any directory depth inside or outside a write root.
export const SECRET_DENYLIST = [
	"**/.env",
	"**/.env.*",
	"**/*.pem",
	"**/*.key",
	"**/*_rsa",
	"**/id_rsa",
	"**/id_ed25519",
	"**/id_ecdsa",
	"**/id_dsa",
	"**/credentials.json",
	"**/service-account*.json",
];

// Committed env templates are documentation, not secrets. This is the ONLY sanctioned
// exemption to the secret denylist (an explicit, named false-positive fix — the
// denylist patterns themselves must never be weakened). Consumers decide where to
// apply it; the specialist guard exempts these from the `.env.*` block only.
export const SECRET_TEMPLATE_EXEMPTIONS = [
	"**/.env.example",
	"**/.env.sample",
	"**/.env.template",
];

export function normalizeToolPath(rawPath: string, cwd: string): string {
	let cleaned = String(rawPath || "").trim();
	if (cleaned.startsWith("@")) cleaned = cleaned.slice(1);
	if (cleaned === "~") cleaned = os.homedir();
	else if (cleaned.startsWith("~/")) cleaned = path.join(os.homedir(), cleaned.slice(2));
	return path.normalize(path.isAbsolute(cleaned) ? cleaned : path.resolve(cwd, cleaned));
}

export function normalizeRelative(cwd: string, absPath: string): string {
	return path.relative(path.resolve(cwd), absPath).split(path.sep).join("/");
}

export function isInsideOrEqual(base: string, candidate: string): boolean {
	const rel = path.relative(path.normalize(base), path.normalize(candidate));
	return rel === "" || (!!rel && !rel.startsWith("..") && !path.isAbsolute(rel));
}

function escapeRegExp(value: string): string {
	return value.replace(/[\\^$+?.()|[\]{}]/g, "\\$&");
}

const globRegexCache = new Map<string, RegExp>();

export function globToRegExp(glob: string): RegExp {
	const cached = globRegexCache.get(glob);
	if (cached) return cached;
	let out = "";
	for (let i = 0; i < glob.length; i++) {
		const ch = glob[i];
		const next = glob[i + 1];
		if (ch === "*" && next === "*") {
			const after = glob[i + 2];
			if (after === "/") {
				out += "(?:.*/)?";
				i += 2;
			} else {
				out += ".*";
				i++;
			}
		} else if (ch === "*") {
			out += "[^/]*";
		} else {
			out += escapeRegExp(ch);
		}
	}
	const re = new RegExp(`^${out}$`);
	globRegexCache.set(glob, re);
	return re;
}

// Any-depth secret match against the absolute path's posix form. Used as a hard
// pre-check so a secret file is blocked even when it sits inside a write root.
export function matchesSecretDenylist(absPath: string): boolean {
	const subject = absPath.split(path.sep).join("/");
	return SECRET_DENYLIST.some((pattern) => globToRegExp(pattern).test(subject));
}

// Same absolute-path matcher for the named template exemption, kept beside the
// constant it interprets so any consumer applies identical semantics.
export function matchesSecretTemplateExemption(absPath: string): boolean {
	const subject = absPath.split(path.sep).join("/");
	return SECRET_TEMPLATE_EXEMPTIONS.some((pattern) => globToRegExp(pattern).test(subject));
}

// Wrapper commands whose real command follows after their own flags/values.
// Keeps `sudo rm`, `xargs rm`, `timeout 5 rm` visible to first-word dispatch.
const COMMAND_WRAPPERS = new Set([
	"sudo", "doas", "env", "nohup", "time", "nice", "ionice", "stdbuf", "timeout",
	"xargs", "command", "builtin", "exec",
]);

// Best-effort denylist: recognizes the common mutating shell commands and writers below.
// This is an INTENTIONAL best-effort guardrail (no sandbox planned), NOT a sandbox.
// Unlisted mutators (rsync, chmod/chown, busybox applets, value options on rm/mkdir/
// touch, interpreter payloads, etc.) are NOT modeled and pass as non-mutating — an
// OS-level write sandbox is the deferred real fix. This analyzer is now the single
// shared model imported by both guards, so new write vectors only need to be added once.
//
// Pipeline: strip heredoc bodies (so `<<'EOF'` payload text is never tokenized as
// shell) → split into command segments (;, &&, ||, |, &, newline) → dispatch rules
// against the FIRST word of each segment (after env-assignment/wrapper skipping), so
// arguments like the `install` in `pnpm install` are never re-dispatched to coreutils
// rules → track literal `cd <dir>` prefixes so relative targets in later segments
// resolve against the directory the shell would actually be in.
export function analyzeBashCommand(command: string): BashMutation[] {
	const mutations: BashMutation[] = [];
	const segments = parseBashSegments(stripHeredocs(command));
	let cwdPrefix = "";

	const prefixPath = (raw: string): string => {
		if (!cwdPrefix || !raw) return raw;
		if (path.isAbsolute(raw) || raw === "~" || raw.startsWith("~/")) return raw;
		return `${cwdPrefix}/${raw}`;
	};
	const prefixAll = (paths: string[]): string[] => paths.map(prefixPath);

	for (const segment of segments) {
		for (const redir of segment.redirections) {
			mutations.push({
				kind: redir.kind,
				paths: redir.target ? [prefixPath(redir.target)] : [],
				unscoped: !redir.target,
			});
		}

		const cmdIndex = commandWordIndex(segment.words);
		if (cmdIndex === undefined) continue;
		const token = commandName(segment.words[cmdIndex]);
		if (!token) continue;
		const args = segment.words.slice(cmdIndex + 1);

		if (token === "cd") {
			cwdPrefix = nextCwdPrefix(cwdPrefix, args);
			continue;
		}

		if (["rm", "mkdir", "touch"].includes(token)) {
			mutations.push({ kind: token, paths: prefixAll(args.filter(isPathLikeArg)) });
			continue;
		}

		if (token === "shred") {
			// shred takes value options (-n/-s/--random-source) and honors a `--`
			// end-of-options marker; parse operands so the count/size is not flagged
			// as a stray target and every real file operand is detected.
			const targets = fileOperands(args, SHRED_VALUE_OPTIONS);
			mutations.push({ kind: token, paths: prefixAll(targets), unscoped: targets.length === 0 });
			continue;
		}

		if (token === "mv" || token === "ln") {
			// mv removes every source and writes the destination; ln creates the link
			// name and (for -s) may point outside authority. Either way every path
			// operand must be in role authority, not just the destination.
			const operands = args.filter(isPathLikeArg);
			mutations.push({ kind: token, paths: prefixAll(operands), unscoped: operands.length === 0 });
			continue;
		}

		if (token === "cp" || token === "install") {
			// cp/install only write the destination; sources are reads, which roles may do.
			// The destination is the trailing operand unless -t/--target-directory names it.
			const dest = copyDestination(args);
			mutations.push({ kind: token, paths: prefixAll(dest.paths), unscoped: dest.unscoped });
			continue;
		}

		if (token === "truncate") {
			// truncate resizes (and creates) every file operand, destroying contents.
			// All operands must be in authority; skip the -s/--size value so the size
			// is not mistaken for a file.
			const targets = fileOperands(args, TRUNCATE_VALUE_OPTIONS);
			mutations.push({ kind: token, paths: prefixAll(targets), unscoped: targets.length === 0 });
			continue;
		}

		if (token === "find") {
			// find -exec/-execdir/-ok run an arbitrary mutating command we cannot scope.
			// find -delete recursively deletes everything its predicates match, which we
			// cannot bound to the literal roots, so it is unscoped destruction too — the
			// roots are still reported for the block message.
			if (args.some((arg) => arg === "-exec" || arg === "-execdir" || arg === "-ok")) {
				mutations.push({ kind: "find -exec", paths: [], unscoped: true });
			} else if (args.includes("-delete")) {
				const roots: string[] = [];
				for (const arg of args) {
					if (arg.startsWith("-")) break;
					if (isPathLikeArg(arg)) roots.push(arg);
				}
				mutations.push({ kind: "find -delete", paths: prefixAll(roots), unscoped: true });
			}
			continue;
		}

		if (token === "dd") {
			// dd's write target is a key=value operand (of=<path>), which
			// isPathLikeArg rejects, so read it from the raw args instead.
			const ofArg = args.find((arg) => arg.startsWith("of="));
			const target = ofArg ? ofArg.slice(3) : undefined;
			mutations.push({ kind: token, paths: target ? [prefixPath(target)] : [], unscoped: !target });
			continue;
		}

		if (token === "tee") {
			const paths = args.filter(isPathLikeArg);
			mutations.push({ kind: "tee", paths: prefixAll(paths), unscoped: paths.length === 0 });
			continue;
		}

		if (token === "sed" && args.some((arg) => arg === "-i" || arg.startsWith("-i"))) {
			const pathGuess = lastPathLikeArg(args);
			mutations.push({ kind: "sed -i", paths: pathGuess ? [prefixPath(pathGuess)] : [], unscoped: !pathGuess });
			continue;
		}

		if (token === "perl" && args.some((arg) => /^-[A-Za-z]*p[A-Za-z]*i|^-[A-Za-z]*i[A-Za-z]*p/.test(arg))) {
			const pathGuess = lastPathLikeArg(args);
			mutations.push({ kind: "perl -pi", paths: pathGuess ? [prefixPath(pathGuess)] : [], unscoped: !pathGuess });
			continue;
		}

		if (token === "git") {
			const mutation = gitMutation(args);
			if (mutation) {
				mutations.push({ kind: `git ${mutation.subcommand}`, paths: [], unscoped: true, gitSubcommand: mutation.subcommand, gitArgs: mutation.args });
			}
			continue;
		}

		if (token === "gh") {
			if (args[0] === "pr" && args[1] === "merge") mutations.push({ kind: "gh pr merge", paths: [], unscoped: true });
			continue;
		}
	}

	if (hasUnscopedOneLinerWriter(command)) {
		mutations.push({ kind: "one-liner file writer", paths: [], unscoped: true });
	}

	return mutations;
}

// First non-assignment, non-wrapper word of a segment — the only token dispatched
// to a command rule. Wrapper flags, env assignments, timeout durations, and xargs
// `{}` placeholders are skipped so the wrapped command stays visible.
function commandWordIndex(words: string[]): number | undefined {
	let i = 0;
	while (i < words.length) {
		const word = words[i];
		if (isAssignmentWord(word)) {
			i++;
			continue;
		}
		const name = commandName(word);
		if (name && COMMAND_WRAPPERS.has(name)) {
			i++;
			while (
				i < words.length &&
				(words[i].startsWith("-") || isAssignmentWord(words[i]) || /^\d+[smhd]?$/.test(words[i]) || words[i] === "{}")
			) {
				i++;
			}
			continue;
		}
		return i;
	}
	return undefined;
}

// Fold a literal `cd <dir>` into the effective directory prefix for later segments.
// Static best-effort only: substitutions, variables, globs, `cd -`, and multi-operand
// forms reset to untracked (= today's resolve-against-session-cwd behavior).
function nextCwdPrefix(current: string, args: string[]): string {
	const operands = args.filter((arg) => !arg.startsWith("-") || arg === "-");
	if (operands.length === 0) return "~";
	const target = operands[0];
	if (operands.length > 1 || target === "-" || /[$`*?[\]]/.test(target)) return "";
	if (path.isAbsolute(target) || target === "~" || target.startsWith("~/")) return target;
	if (!current) return target;
	return `${current.replace(/\/+$/, "")}/${target}`;
}

// Detect cloud/infra verbs directly. We deliberately do NOT exempt commands
// that merely contain read words like list/get/describe/--dry-run, because those
// words can appear in flag values (e.g. --format='get(name)'), comments, or
// chained reads and would otherwise de-arm a real delete/apply/destroy in the
// same command. The verb regexes therefore key off the mutating verb only.
export function looksLikeReleaseLiveOperation(command: string): boolean {
	const trimmed = command.trim();
	return (
		/\bgcloud\b.*\bbuilds\s+submit\b/.test(trimmed) ||
		/\bgcloud\b.*\brun\s+(?:jobs\s+)?deploy\b/.test(trimmed) ||
		/\bgcloud\b.*\bfunctions\s+deploy\b/.test(trimmed) ||
		/\bgcloud\b.*\bapp\s+deploy\b/.test(trimmed) ||
		/\bgcloud\b.*\bworkflows\s+deploy\b/.test(trimmed) ||
		/\bfirebase\b.*\bdeploy\b/.test(trimmed)
	);
}

export function looksLikeNonReleaseLiveOperation(command: string): boolean {
	const trimmed = command.trim();
	return (
		/\bgcloud\b.*\b(delete|update|patch|create|set-iam-policy|add-iam-policy-binding|remove-iam-policy-binding|services\s+replace)\b/.test(trimmed) ||
		/\bbq\b.*\b(rm|mk|cp|load|query)\b/.test(trimmed) ||
		/\bfirebase\b.*\b(target:apply|apps:create|hosting:disable)\b/.test(trimmed) ||
		/\bterraform\b.*\b(apply|destroy|import|taint|untaint)\b/.test(trimmed) ||
		/\bkubectl\b.*\b(apply|delete|replace|scale|patch|edit|rollout\s+restart)\b/.test(trimmed) ||
		/\bhelm\b.*\b(install|upgrade|uninstall|rollback|delete)\b/.test(trimmed) ||
		/\bpsql\b.*\b(drop|delete|truncate|update|insert|alter)\b/i.test(trimmed) ||
		/\basc\b.*\b(auth\s+login|add|add-groups|add-testers|apply|archive|attach|cancel|create|delete|disable|edit|expire|export|import|invite|login|migrate|notariz(?:e|ation)|pause|publish|push|register|remove|replace|resume|revoke|run|send|set|stage|staple|submit|sync|update|upload|web)\b/i.test(trimmed)
	);
}

export function looksLikeLiveOperation(command: string): boolean {
	return looksLikeReleaseLiveOperation(command) || looksLikeNonReleaseLiveOperation(command);
}

export function isGitMutation(mutation: BashMutation): boolean {
	return mutation.kind.startsWith("git ") || mutation.kind === "gh pr merge";
}

export function isGitFinalizationMutation(mutation: BashMutation): boolean {
	return mutation.kind === "git commit" || mutation.kind === "git merge" || mutation.kind === "gh pr merge";
}

export function collectMutationPaths(mutations: BashMutation[], cwd: string): string[] {
	return mutations.flatMap((mutation) => mutation.paths.map((raw) => (isAlwaysAllowedDevice(raw) ? raw : normalizeToolPath(raw, cwd))));
}

export function isAlwaysAllowedDevice(rawPath: string): boolean {
	return rawPath === "/dev/null";
}

interface ParsedSegment {
	words: string[];
	redirections: Array<{ kind: string; target: string | null }>;
}

// Split a (heredoc-stripped) command string into shell command segments at the
// unquoted separators `;`, `&&`, `||`, `|`, `&`, and newline. Each segment carries
// its word list (quote/escape-aware, with redirection operators and their targets
// removed) plus the output redirections found in it. Redirections to always-allowed
// devices (/dev/null) and fd duplications (2>&1, >&2) are dropped at the source so
// they never surface as mutations. Input redirections (<, <<<) are reads and dropped.
function parseBashSegments(command: string): ParsedSegment[] {
	const segments: ParsedSegment[] = [];
	let words: string[] = [];
	let redirections: Array<{ kind: string; target: string | null }> = [];
	let current = "";
	let quote: "'" | '"' | null = null;
	let escaped = false;

	const flushWord = () => {
		if (current.length > 0) words.push(current);
		current = "";
	};
	const flushSegment = () => {
		flushWord();
		if (words.length > 0 || redirections.length > 0) segments.push({ words, redirections });
		words = [];
		redirections = [];
	};

	for (let i = 0; i < command.length; i++) {
		const ch = command[i];
		const next = command[i + 1];
		if (escaped) {
			current += ch;
			escaped = false;
			continue;
		}
		if (ch === "\\") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (ch === quote) quote = null;
			else current += ch;
			continue;
		}
		if (ch === "'" || ch === '"') {
			quote = ch;
			continue;
		}
		if (ch === "\n" || ch === ";") {
			flushSegment();
			continue;
		}
		if (ch === "&" || ch === "|") {
			flushSegment();
			if (next === ch) i++;
			continue;
		}
		if (/\s/.test(ch)) {
			flushWord();
			continue;
		}
		if (ch === "<") {
			// Input redirection (`<`) or here-string (`<<<`); heredocs (`<<`) were
			// already stripped. Reads are not mutations — consume operator + target.
			if (/^\d+$/.test(current)) current = "";
			else flushWord();
			let j = i + 1;
			while (command[j] === "<") j++;
			while (j < command.length && /[ \t]/.test(command[j])) j++;
			const { end } = readShellToken(command, j);
			i = Math.max(end - 1, i);
			continue;
		}
		if (ch === ">") {
			// An attached pure-digit prefix is the fd (2>/dev/null), not an operand.
			if (/^\d+$/.test(current)) current = "";
			else flushWord();
			let kind = "redirection";
			let j = i + 1;
			if (command[j] === ">") {
				kind = "append redirection";
				j++;
			} else if (command[j] === "|") {
				j++; // `>|` clobber-override is still a write
			}
			if (command[j] === "&") {
				// fd duplication (2>&1, >&2) or close (>&-): targets a descriptor, not a file
				i = j;
				continue;
			}
			while (j < command.length && /[ \t]/.test(command[j])) j++;
			const { token, end } = readShellToken(command, j);
			if (!token || !isAlwaysAllowedDevice(token)) {
				redirections.push({ kind, target: token || null });
			}
			i = end - 1;
			continue;
		}
		current += ch;
	}
	flushSegment();
	return segments;
}

// Remove heredoc operators (<<DELIM / <<'DELIM' / <<-DELIM) and their body lines so
// payload text (TypeScript arrows, comments, shell-looking prose) is never tokenized
// as shell. The command line itself is preserved — `cat > file <<'EOF'` still yields
// the `file` redirection target.
function stripHeredocs(command: string): string {
	if (!command.includes("<<")) return command;
	let out = "";
	let quote: "'" | '"' | null = null;
	let escaped = false;
	let pending: Array<{ delim: string; stripTabs: boolean }> = [];
	let i = 0;
	while (i < command.length) {
		const ch = command[i];
		if (escaped) {
			out += ch;
			escaped = false;
			i++;
			continue;
		}
		if (ch === "\\") {
			out += ch;
			escaped = true;
			i++;
			continue;
		}
		if (quote) {
			if (ch === quote) quote = null;
			out += ch;
			i++;
			continue;
		}
		if (ch === "'" || ch === '"') {
			quote = ch;
			out += ch;
			i++;
			continue;
		}
		if (ch === "<" && command[i + 1] === "<" && command[i + 2] !== "<") {
			let j = i + 2;
			let stripTabs = false;
			if (command[j] === "-") {
				stripTabs = true;
				j++;
			}
			while (j < command.length && /[ \t]/.test(command[j])) j++;
			let delim = "";
			if (command[j] === "'" || command[j] === '"') {
				const q = command[j];
				j++;
				while (j < command.length && command[j] !== q) {
					delim += command[j];
					j++;
				}
				j++;
			} else {
				if (command[j] === "\\") j++;
				while (j < command.length && /[^\s;|&<>()`]/.test(command[j])) {
					delim += command[j];
					j++;
				}
			}
			if (delim) {
				pending.push({ delim, stripTabs });
				i = j;
				continue;
			}
			out += "<<";
			i += 2;
			continue;
		}
		if (ch === "\n" && pending.length > 0) {
			out += "\n";
			i++;
			for (const { delim, stripTabs } of pending) {
				while (i < command.length) {
					let lineEnd = command.indexOf("\n", i);
					if (lineEnd === -1) lineEnd = command.length;
					let line = command.slice(i, lineEnd);
					if (stripTabs) line = line.replace(/^\t+/, "");
					i = lineEnd + 1;
					if (line === delim) break;
				}
			}
			pending = [];
			continue;
		}
		out += ch;
		i++;
	}
	return out;
}

function commandName(token: string): string | null {
	if (!token) return null;
	const cleaned = token.replace(/^[(]+/, "");
	return cleaned.split("/").pop() || null;
}

function isAssignmentWord(word: string): boolean {
	return /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);
}

function isPathLikeArg(arg: string): boolean {
	if (!arg || arg.startsWith("-")) return false;
	if (isAssignmentWord(arg)) return false;
	return true;
}

// Collect file operands for a command, skipping known value-taking options (and the
// value they consume) and treating everything after a `--` end-of-options marker as
// an operand. Best-effort: only the listed value options are modeled.
function fileOperands(args: string[], valueOptions: Set<string>): string[] {
	const operands: string[] = [];
	for (let i = 0; i < args.length; i++) {
		const arg = args[i];
		if (arg === "--") {
			for (let j = i + 1; j < args.length; j++) {
				if (isPathLikeArg(args[j])) operands.push(args[j]);
			}
			break;
		}
		if (valueOptions.has(arg)) {
			i++;
			continue;
		}
		if (isPathLikeArg(arg)) operands.push(arg);
	}
	return operands;
}

// Resolve a git subcommand, skipping global options (and any value they consume)
// such as `-C <path>` or `-c <name=value>` so they cannot mask mutating verbs.
function parseGitInvocation(args: string[]): { subcommand: string; args: string[] } | undefined {
	for (let i = 0; i < args.length; i++) {
		const arg = args[i];
		if (GIT_VALUE_OPTIONS.has(arg)) {
			i++;
			continue;
		}
		if (arg.startsWith("-C") && arg.length > 2) continue;
		if (arg.startsWith("-c") && arg.length > 2) continue;
		if (
			arg.startsWith("--git-dir=") ||
			arg.startsWith("--work-tree=") ||
			arg.startsWith("--namespace=")
		) {
			continue;
		}
		if (arg.startsWith("-")) continue;
		return { subcommand: arg, args: args.slice(i + 1) };
	}
	return undefined;
}

// `git apply` flags that make the invocation a read-only inspection (dry run / diffstat).
const GIT_APPLY_READ_FLAGS = new Set(["--check", "--stat", "--numstat", "--summary"]);

function gitMutation(args: string[]): { subcommand: string; args: string[] } | undefined {
	const parsed = parseGitInvocation(args);
	if (!parsed) return undefined;
	const { subcommand, args: subArgs } = parsed;
	if (subcommand === "apply" && subArgs.some((arg) => GIT_APPLY_READ_FLAGS.has(arg))) return undefined;
	if (GIT_ALWAYS_MUTATING_SUBCOMMANDS.has(subcommand)) return parsed;
	if (subcommand === "branch" && gitBranchMutates(subArgs)) return parsed;
	if (subcommand === "tag" && gitTagMutates(subArgs)) return parsed;
	if (subcommand === "remote" && GIT_REMOTE_MUTATING_SUBCOMMANDS.has(firstGitSubArg(subArgs) ?? "")) return parsed;
	if (subcommand === "worktree" && GIT_WORKTREE_MUTATING_SUBCOMMANDS.has(firstGitSubArg(subArgs) ?? "")) return parsed;
	if (subcommand === "submodule" && GIT_SUBMODULE_MUTATING_SUBCOMMANDS.has(firstGitSubArg(subArgs) ?? "")) return parsed;
	if (subcommand === "reflog" && GIT_REFLOG_MUTATING_SUBCOMMANDS.has(firstGitSubArg(subArgs) ?? "")) return parsed;
	if (subcommand === "notes" && GIT_NOTES_MUTATING_SUBCOMMANDS.has(firstGitSubArg(subArgs) ?? "")) return parsed;
	if (subcommand === "stash" && gitStashMutates(subArgs)) return parsed;
	if (subcommand === "replace" && gitReplaceMutates(subArgs)) return parsed;
	return undefined;
}

function firstGitSubArg(args: string[]): string | undefined {
	return args.find((arg) => !arg.startsWith("-"));
}

function gitBranchMutates(args: string[]): boolean {
	if (args.length === 0) return false;
	let listMode = false;
	for (let i = 0; i < args.length; i++) {
		const arg = args[i];
		if (arg === "--") return args.slice(i + 1).length > 0;
		if (GIT_BRANCH_MUTATION_FLAGS.has(arg) || arg.startsWith("--set-upstream-to=")) return true;
		if (arg === "--list" || arg === "--all" || arg === "--remotes" || arg === "-a" || arg === "-r") {
			listMode = true;
			continue;
		}
		if (GIT_BRANCH_READ_VALUE_OPTIONS.has(arg)) {
			i++;
			continue;
		}
		if ([...GIT_BRANCH_READ_VALUE_OPTIONS].some((opt) => arg.startsWith(`${opt}=`))) continue;
		if (arg.startsWith("-")) continue;
		if (!listMode) return true;
	}
	return false;
}

function gitTagMutates(args: string[]): boolean {
	if (args.length === 0) return false;
	let listMode = false;
	for (let i = 0; i < args.length; i++) {
		const arg = args[i];
		if (arg === "--") return args.slice(i + 1).length > 0 && !listMode;
		if (GIT_TAG_MUTATION_FLAGS.has(arg)) return true;
		if (arg === "--list" || arg === "-l") {
			listMode = true;
			continue;
		}
		if (GIT_TAG_READ_VALUE_OPTIONS.has(arg)) {
			i++;
			continue;
		}
		if ([...GIT_TAG_READ_VALUE_OPTIONS].some((opt) => arg.startsWith(`${opt}=`))) continue;
		if (arg.startsWith("-")) continue;
		if (!listMode) return true;
	}
	return false;
}

function gitStashMutates(args: string[]): boolean {
	const sub = firstGitSubArg(args);
	if (!sub) return true; // `git stash` defaults to `push`.
	return sub !== "list" && sub !== "show";
}

function gitReplaceMutates(args: string[]): boolean {
	if (args.length === 0) return false;
	if (args.some((arg) => arg === "-d" || arg === "--delete" || arg === "--edit" || arg === "--graft" || arg === "--convert-graft-file")) return true;
	return args.some((arg) => !arg.startsWith("-"));
}

function lastPathLikeArg(args: string[]): string | undefined {
	// The `s/` skip keeps a sed substitution expr (s/a/b/) from being mistaken for the
	// edited file; it only covers substitutions, not y/// transliteration or line-address forms.
	const candidates = args.filter((arg) => isPathLikeArg(arg) && !arg.startsWith("s/"));
	return candidates[candidates.length - 1];
}

// cp/install write the destination directory named by -t/--target-directory when
// present, otherwise the trailing path operand. Sources are reads and ignored.
function copyDestination(args: string[]): { paths: string[]; unscoped: boolean } {
	for (let i = 0; i < args.length; i++) {
		const arg = args[i];
		if (arg === "-t" || arg === "--target-directory") {
			const dir = args[i + 1];
			return dir ? { paths: [dir], unscoped: false } : { paths: [], unscoped: true };
		}
		if (arg.startsWith("--target-directory=")) {
			return { paths: [arg.slice("--target-directory=".length)], unscoped: false };
		}
	}
	const pathArgs = args.filter(isPathLikeArg);
	return pathArgs.length > 0 ? { paths: [pathArgs[pathArgs.length - 1]], unscoped: false } : { paths: [], unscoped: true };
}

function readShellToken(command: string, start: number): { token: string; end: number } {
	let token = "";
	let quote: "'" | '"' | null = null;
	let escaped = false;
	let i = start;
	for (; i < command.length; i++) {
		const ch = command[i];
		if (escaped) {
			token += ch;
			escaped = false;
			continue;
		}
		if (ch === "\\") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (ch === quote) quote = null;
			else token += ch;
			continue;
		}
		if (ch === "'" || ch === '"') {
			quote = ch;
			continue;
		}
		if (/\s/.test(ch) || ch === ";" || ch === "|" || ch === "&" || ch === ">" || ch === "<") break;
		token += ch;
	}
	return { token, end: i };
}

function hasUnscopedOneLinerWriter(command: string): boolean {
	if (!/\b(?:python3?|node|bun|deno|perl|ruby)\s+-(?:e|c)\b/.test(command)) return false;
	return /(writeFileSync|appendFileSync|writeFile\b|appendFile\b|createWriteStream|rmSync|rmdirSync|unlinkSync|fs\.(?:write|append|rm|unlink|rmdir)|\.write_text\s*\(|\.write_bytes\s*\(|open\s*\([^)]*,\s*['"](?:w|a|x)|os\.(?:remove|unlink|rmdir|truncate)|shutil\.(?:rmtree|move|copy)|\.unlink\s*\(|\.rmtree\s*\()/.test(command);
}

// Compact an allowed-roots list for a one-line status notification.
export function compactRoots(roots: string[]): string {
	if (roots.length === 0) return "none";
	if (roots.length <= 4) return roots.join(", ");
	return `${roots.slice(0, 4).join(", ")}, +${roots.length - 4} more`;
}
