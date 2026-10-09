/**
 * The buffer package (Node's Buffer for extensions and the engine) lacks the base64url encoding, which JWTs, WebAuthn,
 * and PKCE use everywhere: Buffer.from(text, "base64url"), buffer.toString("base64url"), Buffer.byteLength, and
 * Buffer.isEncoding get it here, once, on the package's Buffer.
 */
import { Buffer } from "buffer";

const toBase64 = (text: string) => {
	const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
	return base64 + "=".repeat((4 - (base64.length % 4)) % 4);
};
const toBase64url = (base64: string) => base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const isBase64url = (encoding: unknown) => typeof encoding === "string" && encoding.toLowerCase() === "base64url";

// biome-ignore lint/suspicious/noExplicitAny: patching the package's own methods.
const B = Buffer as any;
if (!B.isEncoding("base64url")) {
	const from = B.from;
	B.from = function (value: unknown, encodingOrOffset?: unknown, length?: unknown) {
		if (typeof value === "string" && isBase64url(encodingOrOffset)) return from.call(this, toBase64(value), "base64");
		return from.call(this, value, encodingOrOffset, length);
	};
	const toString = B.prototype.toString;
	B.prototype.toString = function (encoding?: unknown, start?: number, end?: number) {
		if (isBase64url(encoding)) return toBase64url(toString.call(this, "base64", start, end));
		return toString.call(this, encoding, start, end);
	};
	const byteLength = B.byteLength;
	B.byteLength = function (value: unknown, encoding?: unknown) {
		if (typeof value === "string" && isBase64url(encoding)) return byteLength.call(this, toBase64(value), "base64");
		return byteLength.call(this, value, encoding);
	};
	const isEncoding = B.isEncoding;
	B.isEncoding = (encoding: unknown) => isBase64url(encoding) || isEncoding(encoding);
}

export { Buffer };
