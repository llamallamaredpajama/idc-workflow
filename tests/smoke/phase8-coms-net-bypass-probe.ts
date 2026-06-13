// phase8-coms-net-bypass-probe.ts — proves the HUB enforces the glass-wall ACL (codex F2).
//
// The companion phase8-coms-net-probe.ts evaluates the ACL in the CLIENT and only POSTs an
// allowed send — so it never exercises whether the hub itself rejects a forbidden one. This
// probe POSTs straight to POST /v1/messages WITHOUT any client-side gate, exactly as a
// compromised resident or any holder of the shared bearer token could. The hub must be the
// authoritative gate: an upstream or fail-closed send must be rejected (403) and never queued.
//
//   build-impl → plan         (UPSTREAM)        hub must REJECT (403), no msg_id
//   build-impl → build-finish (DOWNSTREAM)      hub must ACCEPT (200 + msg_id)
//   build-impl → ripple       (Ripple sink)     hub must ACCEPT (200 + msg_id)
//   ghost      → build-finish (unknown sender)  hub must REJECT (403, fail-closed)
//
// Usage: bun phase8-coms-net-bypass-probe.ts <serverUrl> <token> [project]
// Exit 0 = hub enforced every case; exit 1 = at least one bypass (printed).

import { makeHttp, registerPeer } from "./coms-net-probe-lib.ts";

const [, , SERVER_URL, TOKEN, PROJECT_ARG] = process.argv;
// Isolate in a dedicated project so these peers never collide with the companion probe's peers
// in the shared hub (a collision would trigger the hub's no-hyphen uniquifier, e.g. build-impl2,
// which is a separate latent edge unrelated to the server-side ACL under test here).
const PROJECT = `${PROJECT_ARG || "default"}-bypass`;
if (!SERVER_URL || !TOKEN) {
	console.error("bypass-probe: missing serverUrl/token args");
	process.exit(2);
}
const http = makeHttp(SERVER_URL, TOKEN);
const register = (role: string) => registerPeer(http, role, `bypass-${role}-1`, PROJECT);

// Raw direct POST — the bypass attempt. No ACL evaluation here on purpose.
async function rawSend(senderSession: string, target: string): Promise<{ status: number; msgId: string | null }> {
	const { status, json } = await http("POST", "/v1/messages", {
		project: PROJECT,
		sender_session: senderSession,
		target,
		target_session: null,
		prompt: `bypass attempt ${senderSession} -> ${target}`,
		hops: 0,
	});
	return { status, msgId: json?.msg_id ?? null };
}

type Case = { name: string; sender: string; target: string; mustReject: boolean };

async function main() {
	const buildImpl = await register("build-impl");
	await register("plan");
	const buildFinish = await register("build-finish");
	await register("ripple");
	const ghost = await register("ghost");

	const cases: Case[] = [
		{ name: "build-impl → plan (UPSTREAM)", sender: buildImpl, target: "plan", mustReject: true },
		{ name: "build-impl → build-finish (DOWNSTREAM)", sender: buildImpl, target: "build-finish", mustReject: false },
		{ name: "build-impl → ripple (Ripple sink)", sender: buildImpl, target: "ripple", mustReject: false },
		{ name: "ghost → build-finish (unknown sender, fail-closed)", sender: ghost, target: "build-finish", mustReject: true },
	];

	let failures = 0;
	for (const c of cases) {
		const { status, msgId } = await rawSend(c.sender, c.target);
		if (c.mustReject) {
			// The hub must reject BEFORE queuing: a forbidden POST gets a 4xx and NO msg_id.
			const rejected = status === 403 && msgId === null;
			if (!rejected) {
				failures++;
				console.error(`BYPASS  ${c.name}: hub did NOT reject (status=${status}, msg_id=${msgId}) — expected 403 + no msg_id`);
			} else {
				console.log(`ok      ${c.name}: hub rejected (403)`);
			}
		} else {
			const accepted = status === 200 && typeof msgId === "string" && msgId.length > 0;
			if (!accepted) {
				failures++;
				console.error(`DENIED  ${c.name}: hub did NOT accept a legal send (status=${status}, msg_id=${msgId}) — expected 200 + msg_id`);
			} else {
				console.log(`ok      ${c.name}: hub accepted (200, msg_id)`);
			}
		}
	}

	if (failures > 0) {
		console.error(`${failures} hub ACL failure(s) — the glass wall is not enforced server-side`);
		process.exit(1);
	}
	console.log("hub enforces the glass-wall ACL on every direct POST (no client gate)");
}

main().catch((e) => { console.error(`bypass-probe error: ${e?.message ?? e}`); process.exit(2); });
