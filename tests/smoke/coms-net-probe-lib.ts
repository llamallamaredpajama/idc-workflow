// coms-net-probe-lib.ts — shared HTTP plumbing for the coms-net smoke probes.
//
// The hub's wire contract (bearer auth header, /v1/agents/register body shape, JSON-or-null
// parse) lives here once so the ACL probe and the bypass probe can't drift if it changes.

export type HttpResult = { status: number; json: any };
export type Http = (method: string, urlPath: string, body?: unknown) => Promise<HttpResult>;

export function makeHttp(serverUrl: string, token: string): Http {
	const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
	return async (method, urlPath, body) => {
		const resp = await fetch(`${serverUrl}${urlPath}`, {
			method,
			headers,
			body: body === undefined ? undefined : JSON.stringify(body),
		});
		let json: any = null;
		try { json = await resp.json(); } catch { /* non-JSON */ }
		return { status: resp.status, json };
	};
}

// Register a role peer under an explicit session id; throws on a non-ok hub response.
export async function registerPeer(http: Http, role: string, sessionId: string, project: string): Promise<string> {
	const { status, json } = await http("POST", "/v1/agents/register", { session_id: sessionId, project, name: role });
	if (status !== 200 || !json?.ok) throw new Error(`register(${role}) failed: status=${status} body=${JSON.stringify(json)}`);
	return sessionId;
}
