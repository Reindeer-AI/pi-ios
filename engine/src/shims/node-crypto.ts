/** The part of node:crypto pi-ai's OAuth flows use: random bytes encoded as hex or base64url, over Web Crypto. */

class Bytes extends Uint8Array {
	override toString(encoding?: string): string {
		if (encoding === "hex") return Array.from(this, (byte) => byte.toString(16).padStart(2, "0")).join("");
		let binary = "";
		for (const byte of this) binary += String.fromCharCode(byte);
		const base64 = btoa(binary);
		if (encoding === "base64url") return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
		if (encoding === "base64") return base64;
		return super.toString();
	}
}

export function randomBytes(size: number): Bytes {
	const bytes = new Bytes(size);
	crypto.getRandomValues(bytes);
	return bytes;
}

export default { randomBytes };
