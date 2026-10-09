/**
 * Routes every http(s) fetch through native URLSession via `pi://app/net`.
 *
 * WebKit applies CORS and drops forbidden request headers; several providers' endpoints (ChatGPT/Codex backend, OAuth
 * token endpoints) don't allow browser origins. Native replays the request exactly: the target URL travels in
 * `x-pi-target` and the original headers, base64 JSON encoded, in `x-pi-headers`. The response body streams back
 * through the scheme task, so SSE works, and aborting the fetch stops the native request.
 */

import { request } from "./bridge.ts";

export const NET_ENDPOINT = "pi://app/net";

type ClientKey = { extension: string; name: string };
type Options = { clientKey?: ClientKey; extension?: string };
let nativeFetch: ((input: RequestInfo | URL, init?: RequestInit, options?: Options) => Promise<Response>) | undefined;

/**
 * An extension's `fetch`: the engine's, plus `clientKey` (the name of one of its keys with a certificate, pi.keys),
 * whose certificate the request presents when the server asks for one (mTLS). Its requests name it to native, for the
 * vault's consent sheet when one carries `{{vault:…}}`.
 */
export function fetchFor(extension: string): typeof fetch {
	return ((input: RequestInfo | URL, init?: RequestInit & { clientKey?: string }) => {
		if (!nativeFetch) return globalThis.fetch(input, init);
		const { clientKey, ...rest } = init ?? {};
		return nativeFetch(input, rest, { extension, ...(clientKey ? { clientKey: { extension, name: String(clientKey) } } : {}) });
	}) as typeof fetch;
}

export function installNativeFetch(): void {
	const webkitFetch = globalThis.fetch.bind(globalThis);
	let counter = 0;

	nativeFetch = async (input: RequestInfo | URL, init?: RequestInit, options: Options = {}): Promise<Response> => {
		const { clientKey, extension } = options;
		const request = new Request(input, init);
		const protocol = new URL(request.url).protocol;
		if (protocol !== "http:" && protocol !== "https:") return webkitFetch(request);

		const originalHeaders: [string, string][] = [];
		request.headers.forEach((value, name) => originalHeaders.push([name, value]));
		const hasBody = request.method !== "GET" && request.method !== "HEAD";
		const id = `${Date.now().toString(36)}-${(++counter).toString(36)}`;

		let response: Response;
		try {
			response = await webkitFetch(NET_ENDPOINT, {
				method: request.method,
				headers: {
					"x-pi-target": request.url,
					"x-pi-headers": encodeHeaders(originalHeaders),
					"x-pi-request": id,
					...(clientKey ? { "x-pi-client-key": btoa(JSON.stringify(clientKey)) } : {}),
					...(extension ? { "x-pi-extension": extension } : {}),
					// fetch's redirect mode, which native honors: "error" fails on a redirect, "manual" returns it.
					...(request.redirect !== "follow" ? { "x-pi-redirect": request.redirect } : {}),
				},
				body: hasBody ? await request.arrayBuffer() : undefined,
				signal: request.signal,
				cache: "no-store",
			});
		} catch (error) {
			throw await explained(error, id, request.url);
		}
		if (!response.body || [101, 204, 205, 304].includes(response.status)) return response;

		// A stream cut off midway (a model's answer) fails with the same "Load failed": name the reason there too.
		const reader = response.body.getReader();
		const body = new ReadableStream<Uint8Array>({
			async pull(controller) {
				try {
					const { done, value } = await reader.read();
					if (done) controller.close();
					else controller.enqueue(value);
				} catch (error) {
					controller.error(await explained(error, id, request.url));
				}
			},
			cancel(reason) {
				return reader.cancel(reason);
			},
		});
		const wrapped = new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
		Object.defineProperty(wrapped, "url", { value: request.url });
		return wrapped;
	};
	globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => nativeFetch!(input, init);
}

/** WebKit's "Load failed" replaced by why native's request failed ("network error: …" for a dropped connection or
 * a timeout, which pi-ai's retry recognizes), or by "network error: the request was interrupted" when native saw no
 * failure (WebKit stopped it); an abort stays an abort. */
async function explained(error: unknown, id: string, url: string): Promise<unknown> {
	if (error instanceof DOMException && error.name === "AbortError") return error;
	const reason = await request<string | null>("net", "failure", { id }).catch(() => null);
	if (reason) return new TypeError(`${reason} (${new URL(url).host})`);
	// WebKit ended the request itself (as it can while iOS moves the app to the background): still a network failure.
	if (error instanceof TypeError) return new TypeError(`network error: the request was interrupted (${error.message}, ${new URL(url).host})`);
	return error;
}

function encodeHeaders(headers: [string, string][]): string {
	const bytes = new TextEncoder().encode(JSON.stringify(headers));
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary);
}
