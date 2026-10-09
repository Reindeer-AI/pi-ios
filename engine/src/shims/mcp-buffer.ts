/**
 * The part of Node's Buffer pi-mcp uses (its OAuth flow and Streamable HTTP transport): `Buffer.from(...)` with
 * `toString("base64" | "base64url" | "hex" | "utf8")`, and `Buffer.byteLength`. The buffer package covers all but
 * base64url (PKCE's encoding), added here.
 */
import { Buffer as Base } from "buffer";

type Encoding = "base64" | "base64url" | "hex" | "utf8" | "utf-8" | undefined;

export const Buffer = {
	from(value: string | ArrayBuffer | ArrayBufferView | number[], encoding?: "utf8" | "base64" | "hex") {
		const bytes =
			value instanceof ArrayBuffer
				? Base.from(new Uint8Array(value))
				: ArrayBuffer.isView(value)
					? Base.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))
					: typeof value === "string"
						? Base.from(value, encoding)
						: Base.from(value);
		const toString = bytes.toString.bind(bytes);
		return Object.assign(bytes, {
			toString(as?: Encoding) {
				if (as === "base64url") return toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
				return toString(as);
			},
		});
	},
	byteLength(value: string) {
		return new TextEncoder().encode(value).length;
	},
};
