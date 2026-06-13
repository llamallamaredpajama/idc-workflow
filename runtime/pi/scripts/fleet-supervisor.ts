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

const HOME = hubEnv.HOME ?? process.env.HOME ?? "";
const PROJECT = hubEnv.PI_COMS_NET_PROJECT ?? "default";
const serverJson = join(HOME, ".pi", "coms-net", "projects", PROJECT, "server.json");
// IDC-LOCAL (codex round-7): remove any STALE server.json from a prior hub for this project BEFORE
// spawning, so the health wait can't accept an old hub's file and let residents register with the
// wrong hub. (Defense in depth: the wait also requires server.json.pid === our hub's pid.)
try { rmSync(serverJson, { force: true }); } catch { /* noop */ }

// Hub child — K via the env MAP (execve), never argv. Bearer stays its existing 0600-file channel
// unless an explicit token was supplied.
const hub = Bun.spawn(hubArgv, { env: withBearer({ ...hubEnv, PI_COMS_NET_ROLE_HMAC_KEY: K }), stdout: "inherit", stderr: "inherit", stdin: "inherit" });
children.push(hub);

async function waitForServer(): Promise<boolean> {
	const ticks = Number(process.env.PI_IDC_FLEET_HEALTH_TICKS ?? 60);
	for (let i = 0; i < ticks; i++) {
		if (hub.exitCode !== null) return false;   // hub died during startup
		if (existsSync(serverJson)) {
			try {
				const j = JSON.parse(readFileSync(serverJson, "utf8"));
				// Only accept the hub WE spawned — a stale/other hub's server.json has a different pid.
				if (Number(j.pid) === hub.pid && j.local_url) {
					const r = await fetch(`${j.local_url}/health`).catch(() => null);
					if (r && r.ok) return true;
				}
			} catch { /* not ready */ }
		}
		await new Promise((r) => setTimeout(r, 250));
	}
	return false;
}
// Fail-closed: a hub that never becomes healthy aborts the fleet — do NOT spawn residents against
// a dead hub and report success (codex round-6 finding 2).
if (!(await waitForServer())) {
	console.error("fleet-supervisor: hub did not become healthy — aborting fleet");
	teardown(1);
}

// Resident children — each gets ONLY its own cap (computed here, in memory) via the env MAP.
for (const role of roles) {
	const argv = readNul(`${role}.argv`);
	if (argv.length === 0) continue;
	const cap = createHmac("sha256", K).update(role).digest("hex");
	const child = Bun.spawn(argv, { env: withBearer({ ...envMap(readNul(`${role}.env`)), PI_COMS_NET_ROLE_CAP: cap }), stdout: "inherit", stderr: "inherit", stdin: "inherit" });
	children.push(child);
}

// Supervise: the fleet is healthy only while every child runs. When ANY child exits, tear down and
// PROPAGATE its exit code — a hub/resident crash must surface as a non-zero fleet exit, not a clean
// one (codex round-6 finding 2).
const firstExit = await Promise.race(children.map((c) => c.exited));
const code = typeof firstExit === "number" ? firstExit : 1;
if (code !== 0) console.error(`fleet-supervisor: a fleet child exited with code ${code} — tearing down`);
teardown(code);
