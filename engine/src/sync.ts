/**
 * Calls a native service synchronously: a synchronous XMLHttpRequest to `pi://app/sync`, which native answers with
 * the service's result (EngineSchemeHandler). For the blocking APIs extension code expects from Node, such as
 * `fs.readFileSync`. Native never needs the page to answer, so the page waiting cannot deadlock.
 */
export function syncRequest<T = unknown>(service: string, method: string, params?: unknown): T {
	const request = new XMLHttpRequest();
	request.open("POST", "pi://app/sync", false);
	request.setRequestHeader("Content-Type", "application/json");
	request.send(JSON.stringify({ service, method, params }));
	if (request.status !== 200) throw new Error(`${service}.${method}: HTTP ${request.status}`);
	const reply = JSON.parse(request.responseText) as { ok: boolean; value?: T; error?: string };
	if (!reply.ok) throw new Error(reply.error ?? `${service}.${method} failed`);
	return reply.value as T;
}
