// phase8-coms-net-probe.ts — Bun probe for the coms-net glass-wall ACL (issue #27, te-B1).
//
// Boots against an ALREADY-RUNNING vendored coms-net hub (the smoke wrapper starts it),
// registers four IDC role peers, then drives the REAL send path through the SAME decision
// function the production coms_net_send seam uses — runtime/pi/extensions/idc-role-harness.ts
// `evaluateComsNetSendForRole`. A send only reaches POST /v1/messages when the ACL allows it,
// exactly mirroring the wired seam. This proves the directional glass wall end-to-end:
//
//   build-impl → plan         (UPSTREAM)    must be DENIED  (never POSTed)
//   build-impl → build-finish (DOWNSTREAM)  must be ALLOWED (server queues a msg_id)
//   build-impl → ripple       (Ripple sink) must be ALLOWED (server queues a msg_id)
//   build-impl → ghost-peer   (unknown)     must be DENIED  (fail-closed)
//
// Usage: bun tests/smoke/phase8-coms-net-probe.ts <serverUrl> <token> [project]
// Exit 0 = all expectations met; exit 1 = at least one mismatch (printed).

import { evaluateComsNetSendForRole } from "../../runtime/pi/extensions/idc-role-harness.ts";

const [, , SERVER_URL, TOKEN, PROJECT_ARG] = process.argv;
const PROJECT = PROJECT_ARG || "default";

if (!SERVER_URL || !TOKEN) {
	console.error("probe: missing serverUrl/token args");
	process.exit(2);
}

const authHeaders = { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" };

async function http(method: string, urlPath: string, body?: unknown): Promise<{ status: number; json: any }> {
	const resp = await fetch(`${SERVER_URL}${urlPath}`, {
		method,
		headers: authHeaders,
		body: body === undefined ? undefined : JSON.stringify(body),
	});
	let json: any = null;
	try { json = await resp.json(); } catch { /* non-JSON */ }
	return { status: resp.status, json };
}

async function register(role: string): Promise<string> {
	const session_id = `sess-${role}-1`;
	const { status, json } = await http("POST", "/v1/agents/register", { session_id, project: PROJECT, name: role });
	if (status !== 200 || !json?.ok) throw new Error(`register(${role}) failed: status=${status} body=${JSON.stringify(json)}`);
	return session_id;
}

// The guarded send: identical gate to the production coms_net_send seam. The ACL decision
// is the single source of truth; only an allowed decision is POSTed to the hub.
async function guardedSend(
	senderRole: string,
	senderSession: string,
	target: string,
): Promise<{ allowed: boolean; reason: string; msgId: string | null; httpStatus: number | null }> {
	const acl = evaluateComsNetSendForRole(senderRole, target);
	if (!acl.allowed) {
		return { allowed: false, reason: acl.reason, msgId: null, httpStatus: null };
	}
	const { status, json } = await http("POST", "/v1/messages", {
		project: PROJECT,
		sender_session: senderSession,
		target,
		target_session: null,
		prompt: `probe ${senderRole}->${target}`,
		hops: 0,
	});
	return { allowed: true, reason: acl.reason, msgId: json?.msg_id ?? null, httpStatus: status };
}

type Case = { name: string; target: string; expectAllowed: boolean };

async function main() {
	const buildImpl = await register("build-impl");
	await register("plan");
	await register("build-finish");
	await register("ripple");

	const cases: Case[] = [
		{ name: "build-impl → plan (UPSTREAM)", target: "plan", expectAllowed: false },
		{ name: "build-impl → build-finish (DOWNSTREAM)", target: "build-finish", expectAllowed: true },
		{ name: "build-impl → ripple (Ripple sink)", target: "ripple", expectAllowed: true },
		{ name: "build-impl → ghost-peer (unknown)", target: "ghost-peer", expectAllowed: false },
	];

	let failures = 0;
	for (const c of cases) {
		const r = await guardedSend("build-impl", buildImpl, c.target);
		const ok =
			r.allowed === c.expectAllowed &&
			// an allowed send must actually reach the hub (msg_id); a denied send must not
			(c.expectAllowed ? !!r.msgId : r.msgId === null);
		console.log(
			`${ok ? "PASS" : "FAIL"}  ${c.name}: allowed=${r.allowed} ` +
				`msg_id=${r.msgId ?? "-"} reason="${r.reason}"`,
		);
		if (!ok) {
			failures++;
			console.log(`        expected allowed=${c.expectAllowed}, ${c.expectAllowed ? "with" : "without"} a server msg_id`);
		}
	}

	if (failures > 0) {
		console.error(`probe: ${failures} expectation(s) failed`);
		process.exit(1);
	}
	console.log("probe: glass-wall ACL deny/allow matrix holds");
	process.exit(0);
}

main().catch((err) => {
	console.error(`probe: error ${err?.message ?? err}`);
	process.exit(1);
});
