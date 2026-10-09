/**
 * Hardware-backed keys for extensions (`pi.keys`, also on `ctx`), held by the app's native `keys` service
 * (ExtensionKeysService): P-256 in the Secure Enclave, optionally behind Face ID, and usable as a TLS client identity
 * once given a certificate (`fetch(url, { clientKey })`). Each extension sees only its own keys.
 */
import { request } from "./bridge.ts";
import { fetchFor } from "./net.ts";

export type KeyInfo = {
	name: string;
	publicKey: {
		/** SubjectPublicKeyInfo DER, base64. */
		spkiDerBase64: string;
		/** The point's coordinates, x ‖ y, base64. */
		rawXYBase64: string;
		/** The coordinates, base64url (as in a JWK). */
		x: string;
		y: string;
	};
	biometry: "none" | "current-set";
	/** In the Secure Enclave (false in the simulator, which has none). */
	hardware: boolean;
	/** The certificate's subject, once set. */
	certificate: string | null;
};

function base64(data: string | ArrayBuffer | ArrayBufferView): string {
	const bytes =
		typeof data === "string"
			? new TextEncoder().encode(data)
			: data instanceof ArrayBuffer
				? new Uint8Array(data)
				: new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
	let binary = "";
	for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	return btoa(binary);
}

export function keysApi(extension: string) {
	const call = <T>(method: string, params: Record<string, unknown> = {}) => request<T>("keys", method, { extension, ...params });
	return {
		/** A new key; `biometry: "current-set"` makes every use ask for Face ID (and the key goes when biometrics change). */
		create: (name: string, options: { biometry?: "none" | "current-set" } = {}) => call<KeyInfo>("create", { name, biometry: options.biometry ?? "none" }),
		get: async (name: string) => (await call<KeyInfo | null>("get", { name })) ?? undefined,
		list: () => call<KeyInfo[]>("list"),
		delete: (name: string) => call<null>("delete", { name }).then(() => undefined),
		/** ECDSA P-256/SHA-256 over `data` (a string is UTF-8; `{ base64 }` is bytes): the DER signature, base64. */
		sign: async (name: string, data: string | ArrayBuffer | ArrayBufferView | { base64: string }, options: { reason?: string } = {}) =>
			(
				await call<{ signature: string }>("sign", {
					name,
					data: typeof data === "object" && "base64" in data ? data.base64 : base64(data as string | ArrayBuffer | ArrayBufferView),
					reason: options.reason ?? "",
				})
			).signature,
		/** PEM certificates, the key's own first: the key becomes a TLS client identity. */
		setCertificate: (name: string, chain: string | string[]) => call<KeyInfo>("setCertificate", { name, chain: Array.isArray(chain) ? chain : [chain] }),
		/** `fetch` presenting the key's certificate (the same as `fetch(url, { ...init, clientKey: name })`). */
		fetch: (name: string, input: RequestInfo | URL, init?: RequestInit) => fetchFor(extension)(input, { ...init, clientKey: name } as RequestInit),
	};
}
