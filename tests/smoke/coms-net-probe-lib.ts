// coms-net-probe-lib.ts — shared HTTP plumbing for the coms-net smoke probes.
//
// The hub's wire contract (bearer auth header, /v1/agents/register body shape, JSON-or-null
// parse) lives here once so the ACL probe and the bypass probe can't drift if it changes.

export type HttpResult = { status: number; json: any };
export type Http = (method: string, urlPath: string, body?: unknown, extraHeaders?: Record<string, string>) => Promise<HttpResult>;

export function makeHttp(serverUrl: string, token: string): Http {
	const base = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
	return async (method, urlPath, body, extraHeaders) => {
		const resp = await fetch(`${serverUrl}${urlPath}`, {
			method,
			headers: { ...base, ...(extraHeaders ?? {}) },
			body: body === undefined ? undefined : JSON.stringify(body),
		});
		let json: any = null;
		try { json = await resp.json(); } catch { /* non-JSON */ }
		return { status: resp.status, json };
	};
}

export type Peer = { sessionId: string; token: string };

// The launcher-issued role capability = HMAC(K, role). The smoke provisions the hub master key K
// via PI_COMS_NET_ROLE_HMAC_KEY (env), and here we compute each role's cap to simulate what idc-pi
// hands a resident. Empty when K is unset (unconfigured hub — no cap enforcement).
import { createHmac } from "node:crypto";
export function roleCapFor(role: string): string {
	const k = process.env.PI_COMS_NET_ROLE_HMAC_KEY ?? "";
	return k ? createHmac("sha256", k).update(role).digest("hex") : "";
}

// Register a role peer under an explicit session id; presents its launcher-issued role cap (when a
// hub master key is configured) so a role-shaped registration is accepted. Returns its per-session
// token (the credential the hub binds sends to). Throws on a non-ok hub response.
export async function registerPeer(http: Http, role: string, sessionId: string, project: string): Promise<Peer> {
	const cap = roleCapFor(role);
	const headers = cap ? { "x-coms-role-cap": cap } : undefined;
	const { status, json } = await http("POST", "/v1/agents/register", { session_id: sessionId, project, name: role }, headers);
	if (status !== 200 || !json?.ok) throw new Error(`register(${role}) failed: status=${status} body=${JSON.stringify(json)}`);
	return { sessionId, token: json.session_token };
}

// A send carrying the sender's per-session token (the x-coms-session-token credential header).
export function sendAs(http: Http, token: string, body: Record<string, unknown>): Promise<HttpResult> {
	return http("POST", "/v1/messages", body, token ? { "x-coms-session-token": token } : undefined);
}
