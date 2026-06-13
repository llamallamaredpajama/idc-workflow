// fleet-supervisor.ts — the SECURE fleet supervisor (codex round-5 fix).
//
// Spawns the coms-net hub and each role resident as a child, setting per-child env via execve maps
// (Bun.spawn `env`), so the role-cap master key K and the per-role caps NEVER appear in any process
// argv / command string. (The bash `env -i VAR=val …` and `openssl … -macopt key:K` forms both put
// secrets in a `ps`-visible argv during startup — this process eliminates that.)
//
// Secrets arrive via THIS process's environment: PI_COMS_NET_ROLE_HMAC_KEY (K) and optional
// PI_COMS_NET_AUTH_TOKEN — set by the parent via a shell `VAR=val` assignment (execve env, never
// argv). The NON-secret spec (each child's argv + base env) is read from PI_IDC_FLEET_SPEC, a dir of
// NUL-delimited files the launcher wrote. K never touches disk; the caps are computed here in memory.

import { createHmac } from "node:crypto";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const SPEC = process.env.PI_IDC_FLEET_SPEC ?? "";
const K = process.env.PI_COMS_NET_ROLE_HMAC_KEY ?? "";
const BEARER = process.env.PI_COMS_NET_AUTH_TOKEN ?? "";
if (!SPEC || !existsSync(SPEC)) { console.error("fleet-supervisor: missing/invalid PI_IDC_FLEET_SPEC"); process.exit(2); }
if (!K) { console.error("fleet-supervisor: missing PI_COMS_NET_ROLE_HMAC_KEY"); process.exit(2); }

function readNul(file: string): string[] {
	const p = join(SPEC, file);
	if (!existsSync(p)) return [];
	const parts = readFileSync(p, "utf8").split("\0");
	if (parts.length && parts[parts.length - 1] === "") parts.pop();
	return parts;
}
function envMap(pairs: string[]): Record<string, string> {
	const m: Record<string, string> = {};
	for (const kv of pairs) { const i = kv.indexOf("="); if (i > 0) m[kv.slice(0, i)] = kv.slice(i + 1); }
	return m;
}
const withBearer = (e: Record<string, string>) => (BEARER ? { ...e, PI_COMS_NET_AUTH_TOKEN: BEARER } : e);

const roles = readNul("roles");
const hubArgv = readNul("hub.argv");
const hubEnv = envMap(readNul("hub.env"));

const children: Array<{ kill: () => void; exited: Promise<number> }> = [];
let torn = false;
function teardown(code = 0): never {
	if (!torn) { torn = true; for (const c of children) { try { c.kill(); } catch { /* noop */ } } try { rmSync(SPEC, { recursive: true, force: true }); } catch { /* noop */ } }
	process.exit(code);
}
process.on("SIGINT", () => teardown(0));
process.on("SIGTERM", () => teardown(0));

// Hub child — K via the env MAP (execve), never argv. Bearer stays its existing 0600-file channel
// unless an explicit token was supplied.
const hub = Bun.spawn(hubArgv, { env: withBearer({ ...hubEnv, PI_COMS_NET_ROLE_HMAC_KEY: K }), stdout: "inherit", stderr: "inherit", stdin: "inherit" });
children.push(hub);

const HOME = hubEnv.HOME ?? process.env.HOME ?? "";
const PROJECT = hubEnv.PI_COMS_NET_PROJECT ?? "default";
const serverJson = join(HOME, ".pi", "coms-net", "projects", PROJECT, "server.json");
async function waitForServer(): Promise<void> {
	for (let i = 0; i < 60; i++) {
		if (existsSync(serverJson)) {
			try {
				const url = JSON.parse(readFileSync(serverJson, "utf8")).local_url;
				if (url) { const r = await fetch(`${url}/health`).catch(() => null); if (r && r.ok) return; }
			} catch { /* not ready */ }
		}
		await new Promise((r) => setTimeout(r, 250));
	}
	console.error("fleet-supervisor: hub did not become healthy in time");
}
await waitForServer();

// Resident children — each gets ONLY its own cap (computed here, in memory) via the env MAP.
for (const role of roles) {
	const argv = readNul(`${role}.argv`);
	if (argv.length === 0) continue;
	const cap = createHmac("sha256", K).update(role).digest("hex");
	const child = Bun.spawn(argv, { env: withBearer({ ...envMap(readNul(`${role}.env`)), PI_COMS_NET_ROLE_CAP: cap }), stdout: "inherit", stderr: "inherit", stdin: "inherit" });
	children.push(child);
}

// Supervise: exit (and tear the fleet down) when any child exits.
await Promise.race(children.map((c) => c.exited));
teardown(0);
