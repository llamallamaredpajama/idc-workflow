// phase8-coms-net-session-auth-probe.ts — every session-scoped hub endpoint binds to the
// per-session token; role identity is bound to a launcher capability; duplicate role residents
// stay ACL-resolvable (codex round-2..4 findings).
//
// Boots against the already-running hub. Covers (each foreign/no token -> 403, own token -> 200):
//   1. SSE stream (/v1/events) hijack.
//   2. Response forge (terminal response submit, bound to the TARGET's token).
//   2b/2c. Message GET + AWAIT (bound to the SENDER's token).
//   2d/2e. Heartbeat + Delete (session-mutation endpoints).
//   3. Duplicate resident: a second `build-impl` uniquifies to `build-impl-2` and still resolves
//      to its IdcRole, so it can send downstream (200).
//   4. Role-cap: registering an IDC role WITHOUT / with a WRONG launcher cap is rejected (403) —
//      role-minting is blocked at registration.
//
// Usage: bun phase8-coms-net-session-auth-probe.ts <serverUrl> <token> [project]
// Exit 0 = all bound; exit 1 = a gap (printed).

import { makeHttp, registerPeer, sendAs, roleCapFor } from "./coms-net-probe-lib.ts";

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

	// (2b) GET message must be sender-token-bound (a bearer holder can't poll another's response).
	const getPath = `/v1/messages/${msgId}?project=${encodeURIComponent(PROJECT)}&sender_session=${encodeURIComponent(buildImpl.sessionId)}`;
	const getForeign = await http("GET", getPath, undefined, { "x-coms-session-token": buildReview.token });
	expect(getForeign.status === 403, "GET message: foreign token rejected", `expected 403, got ${getForeign.status}`);
	const getNoTok = await http("GET", getPath, undefined, {});
	expect(getNoTok.status === 403, "GET message: missing token rejected", `expected 403, got ${getNoTok.status}`);
	const getOwn = await http("GET", getPath, undefined, { "x-coms-session-token": buildImpl.token });
	expect(getOwn.status === 200, "GET message: sender's own token accepted", `expected 200, got ${getOwn.status}`);

	// (2c) AWAIT must be sender-token-bound too (the round-4 /await fix).
	const awaitPath = `/v1/messages/${msgId}/await?project=${encodeURIComponent(PROJECT)}&sender_session=${encodeURIComponent(buildImpl.sessionId)}`;
	const awaitForeign = await http("GET", awaitPath, undefined, { "x-coms-session-token": buildReview.token });
	expect(awaitForeign.status === 403, "AWAIT message: foreign token rejected", `expected 403, got ${awaitForeign.status}`);
	const awaitOwn = await http("GET", awaitPath, undefined, { "x-coms-session-token": buildImpl.token });
	expect(awaitOwn.status === 200, "AWAIT message: sender's own token accepted", `expected 200, got ${awaitOwn.status}`);

	// (2d) HEARTBEAT must be session-token-bound (forging another peer's liveness/context).
	const hbPath = `/v1/agents/${encodeURIComponent(buildImpl.sessionId)}/heartbeat`;
	const hbForeign = await http("POST", hbPath, { project: PROJECT, status: "online" }, { "x-coms-session-token": buildReview.token });
	expect(hbForeign.status === 403, "HEARTBEAT: foreign token rejected", `expected 403, got ${hbForeign.status}`);
	const hbOwn = await http("POST", hbPath, { project: PROJECT, status: "online" }, { "x-coms-session-token": buildImpl.token });
	expect(hbOwn.status === 200, "HEARTBEAT: own token accepted", `expected 200, got ${hbOwn.status}`);

	// (2e) DELETE must be session-token-bound (forced-offline / unregister of another peer).
	const sacrificial = await register("ripple", "sa-ripple-victim");
	const delPath = (sid: string) => `/v1/agents/${encodeURIComponent(sid)}?project=${encodeURIComponent(PROJECT)}`;
	const delForeign = await http("DELETE", delPath(sacrificial.sessionId), undefined, { "x-coms-session-token": buildImpl.token });
	expect(delForeign.status === 403, "DELETE: foreign token cannot unregister another peer", `expected 403, got ${delForeign.status}`);
	const delOwn = await http("DELETE", delPath(sacrificial.sessionId), undefined, { "x-coms-session-token": sacrificial.token });
	expect(delOwn.status === 200, "DELETE: own token unregisters self", `expected 200, got ${delOwn.status}`);

	// (2f) TOMBSTONE (codex round-4 Layer 1): when a target is deleted/expires, its in-flight
	//      messages are terminated — so a later registrant of the same session_id can't inherit or
	//      answer them (closes the session-resurrection residue).
	const victim = await register("ripple", "sa-tomb-victim");
	const tomb = await sendAs(http, buildImpl.token, {
		project: PROJECT, sender_session: buildImpl.sessionId, target_session: victim.sessionId, target: null,
		prompt: "to be orphaned", hops: 0,
	});
	const tombId = tomb.json?.msg_id;
	expect(typeof tombId === "string" && tombId.length > 0, "TOMBSTONE setup: message queued to victim", `got status=${tomb.status}`);
	await http("DELETE", `/v1/agents/${encodeURIComponent(victim.sessionId)}?project=${encodeURIComponent(PROJECT)}`, undefined, { "x-coms-session-token": victim.token });
	const afterDel = await http("GET", `/v1/messages/${tombId}?project=${encodeURIComponent(PROJECT)}&sender_session=${encodeURIComponent(buildImpl.sessionId)}`, undefined, { "x-coms-session-token": buildImpl.token });
	expect(afterDel.json?.status === "error" || afterDel.json?.status === "timeout",
		"TOMBSTONE: orphaned message is terminal after target removal",
		`expected error/timeout, got ${JSON.stringify(afterDel.json)}`);

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

	// (4) ROLE-CAP (codex round-4): minting a role is rejected. A fresh session claiming an IDC role
	//     without the launcher-issued cap (or with a wrong one) cannot register — so it can never
	//     reach the ACL as that role. The honest registrations above already prove a VALID cap works.
	const noCap = await http("POST", "/v1/agents/register", { session_id: "sa-mint-1", project: PROJECT, name: "think" }, {});
	expect(noCap.status === 403, "ROLE-CAP: registering 'think' WITHOUT a cap is rejected (mint blocked)", `expected 403, got ${noCap.status}`);
	const badCap = await http("POST", "/v1/agents/register", { session_id: "sa-mint-2", project: PROJECT, name: "think" }, { "x-coms-role-cap": "deadbeef" });
	expect(badCap.status === 403, "ROLE-CAP: registering 'think' with a WRONG cap is rejected", `expected 403, got ${badCap.status}`);
	// Caps are ROLE-SPECIFIC: a resident's valid cap for its own role can't register as another role.
	const crossRole = await http("POST", "/v1/agents/register", { session_id: "sa-mint-3", project: PROJECT, name: "think" }, { "x-coms-role-cap": roleCapFor("build-impl") });
	expect(crossRole.status === 403, "ROLE-CAP: a valid build-impl cap cannot register as think (role-specific)", `expected 403, got ${crossRole.status}`);

	if (failures > 0) { console.error(`${failures} session-auth gap(s)`); process.exit(1); }
	console.log("every session-scoped endpoint is token-bound; role-mint blocked; duplicate residents stay ACL-resolvable");
}

main().catch((e) => { console.error(`session-auth-probe error: ${e?.message ?? e}`); process.exit(2); });
