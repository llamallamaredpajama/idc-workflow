// phase8-coms-net-session-auth-probe.ts — every session-scoped hub endpoint binds to the
// per-session token, and duplicate role residents stay ACL-resolvable (codex round-2 findings).
//
// Boots against the already-running hub. Covers:
//   1. SSE hijack: a foreign token cannot open another session's /v1/events stream (403); the
//      session's own token can (200).
//   2. Response forge: a sender cannot submit the terminal response as the target (403); the
//      real target (its own token) can (200).
//   3. Duplicate resident: a second `build-impl` is uniquified to `build-impl-2` (hyphenated) and
//      still resolves to its IdcRole, so it can send downstream to build-review (200).
//
// Usage: bun phase8-coms-net-session-auth-probe.ts <serverUrl> <token> [project]
// Exit 0 = all bound; exit 1 = a gap (printed).

import { makeHttp, registerPeer, sendAs } from "./coms-net-probe-lib.ts";

const [, , SERVER_URL, TOKEN, PROJECT_ARG] = process.argv;
const PROJECT = `${PROJECT_ARG || "default"}-sessauth`;
if (!SERVER_URL || !TOKEN) {
	console.error("session-auth-probe: missing serverUrl/token args");
	process.exit(2);
}
const http = makeHttp(SERVER_URL, TOKEN);
const register = (role: string, sid: string) => registerPeer(http, role, sid, PROJECT);

let failures = 0;
const expect = (cond: boolean, label: string, detail: string) => {
	if (cond) { console.log(`ok      ${label}`); }
	else { failures++; console.error(`GAP     ${label}: ${detail}`); }
};

// Open an SSE stream and return only its HTTP status (then cancel the body — we don't consume it).
async function sseStatus(sessionId: string, sessionToken: string): Promise<number> {
	const headers: Record<string, string> = {
		Authorization: `Bearer ${TOKEN}`,
		Accept: "text/event-stream",
	};
	if (sessionToken) headers["x-coms-session-token"] = sessionToken;
	const resp = await fetch(`${SERVER_URL}/v1/events?project=${encodeURIComponent(PROJECT)}&session_id=${encodeURIComponent(sessionId)}`, { method: "GET", headers });
	try { await resp.body?.cancel(); } catch { /* ignore */ }
	return resp.status;
}

async function main() {
	const buildImpl = await register("build-impl", "sa-build-impl-1");
	const buildReview = await register("build-review", "sa-build-review-1");
	const buildFinish = await register("build-finish", "sa-build-finish-1");
	const think = await register("think", "sa-think-1");

	// (1) SSE hijack — a foreign token can't open think's stream; think's own token can.
	expect(await sseStatus(think.sessionId, buildFinish.token) === 403, "SSE: foreign token cannot open think's stream", "expected 403");
	expect(await sseStatus(think.sessionId, "") === 403, "SSE: no session token cannot open think's stream", "expected 403");
	expect(await sseStatus(think.sessionId, think.token) === 200, "SSE: think's own token opens think's stream", "expected 200");

	// (2) Response forge — build-impl sends to build-review (allowed), then tries to submit the
	//     terminal response AS build-review using its OWN token; the hub must reject. The real
	//     target (build-review's token) is accepted.
	const sent = await sendAs(http, buildImpl.token, {
		project: PROJECT, sender_session: buildImpl.sessionId, target: "build-review", target_session: null,
		prompt: "review please", hops: 0,
	});
	const msgId = sent.json?.msg_id;
	expect(typeof msgId === "string" && msgId.length > 0, "setup: build-impl->build-review send queued", `got status=${sent.status}`);

	const forge = await http("POST", `/v1/messages/${msgId}/response`,
		{ project: PROJECT, responder_session: buildReview.sessionId, response: "FORGED", error: null },
		{ "x-coms-session-token": buildImpl.token });
	expect(forge.status === 403, "RESPONSE: sender's token cannot forge the target's reply", `expected 403, got ${forge.status}`);

	const realReply = await http("POST", `/v1/messages/${msgId}/response`,
		{ project: PROJECT, responder_session: buildReview.sessionId, response: "real", error: null },
		{ "x-coms-session-token": buildReview.token });
	expect(realReply.status === 200, "RESPONSE: the real target submits its reply", `expected 200, got ${realReply.status}`);

	// (3) Duplicate resident — a second build-impl uniquifies to build-impl-2 and can still send
	//     downstream (resolves to the build-impl IdcRole).
	const dup = await register("build-impl", "sa-build-impl-2");  // hub uniquifies the name -> build-impl-2
	const dupSend = await sendAs(http, dup.token, {
		project: PROJECT, sender_session: dup.sessionId, target: "build-review", target_session: null,
		prompt: "dup downstream", hops: 0,
	});
	expect(dupSend.status === 200 && typeof dupSend.json?.msg_id === "string",
		"DUPLICATE: a second build-impl (uniquified, hyphenated) can send downstream",
		`expected 200+msg_id, got status=${dupSend.status} body=${JSON.stringify(dupSend.json)}`);

	if (failures > 0) { console.error(`${failures} session-auth gap(s)`); process.exit(1); }
	console.log("every session-scoped endpoint is token-bound; duplicate residents stay ACL-resolvable");
}

main().catch((e) => { console.error(`session-auth-probe error: ${e?.message ?? e}`); process.exit(2); });
