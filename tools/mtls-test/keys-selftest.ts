/**
 * A pi extension that tests pi.keys end to end against tools/mtls-test/server.py: a key, a signature checked with
 * Web Crypto, a certificate from the test CA, mTLS with `fetch(url, { clientKey })` and `pi.keys.fetch`, a refusal
 * without it, and (with biometric: true) a Face ID key. Its tool `keys_selftest` answers one line per check.
 */
import { Type } from "@earendil-works/pi-ai";

const ISSUER = "http://127.0.0.1:8770/issue";
const WHOAMI = "https://127.0.0.1:8771/whoami";

const bytes = (base64: string) => Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
const hex = (buffer: ArrayBuffer) => [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** DER ECDSA signature → the r ‖ s form Web Crypto verifies. */
function derToRaw(der: Uint8Array): Uint8Array {
	let offset = 2;
	const integer = () => {
		const length = der[offset + 1];
		let value = der.slice(offset + 2, offset + 2 + length);
		offset += 2 + length;
		while (value.length > 32 && value[0] === 0) value = value.slice(1);
		const padded = new Uint8Array(32);
		padded.set(value, 32 - value.length);
		return padded;
	};
	const r = integer();
	const s = integer();
	return new Uint8Array([...r, ...s]);
}

async function verify(publicKey: string, signature: string, message: string): Promise<boolean> {
	const key = await crypto.subtle.importKey("spki", bytes(publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
	return crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, derToRaw(bytes(signature)), new TextEncoder().encode(message));
}

export default function (pi: any) {
	pi.registerTool({
		name: "keys_selftest",
		label: "Keys self-test",
		description: "Tests pi.keys (Secure Enclave keys, signatures, client certificates, mTLS) against the local mTLS test server, and reports one line per check.",
		parameters: Type.Object({
			biometric: Type.Optional(Type.Boolean({ description: "Also test a Face ID key" })),
			network: Type.Optional(Type.Boolean({ description: "false: skip the certificate and mTLS checks (no local test server, as on a phone)" })),
		}),
		async execute(_id: string, params: { biometric?: boolean; network?: boolean }) {
			const lines: string[] = [];
			const check = async (label: string, run: () => Promise<string>) => {
				try {
					lines.push(`✓ ${label}: ${await run()}`);
				} catch (error) {
					lines.push(`✗ ${label}: ${error instanceof Error ? error.message : String(error)}`);
				}
			};
			const keys = pi.keys;
			await keys.delete("device").catch(() => {});
			await keys.delete("approve").catch(() => {});

			let device: any;
			await check("create a key", async () => {
				device = await keys.create("device");
				return `${device.hardware ? "Secure Enclave" : "software (simulator)"}, biometry ${device.biometry}, x=${device.publicKey.x.slice(0, 8)}…`;
			});
			await check("sign and verify", async () => {
				const signature = await keys.sign("device", "hello pi");
				if (!(await verify(device.publicKey.spkiDerBase64, signature, "hello pi"))) throw new Error("the signature does not verify");
				if (await verify(device.publicKey.spkiDerBase64, signature, "hello other")) throw new Error("a wrong message verifies");
				return "verifies with Web Crypto, and only for the signed message";
			});
			if (params.network !== false) {
			await check("get a certificate", async () => {
				const response = await fetch(ISSUER, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ publicKey: device.publicKey.spkiDerBase64 }) });
				const { certificate } = await response.json();
				const info = await keys.setCertificate("device", certificate);
				return `set (${info.certificate})`;
			});
			const ownKey = hex(await crypto.subtle.digest("SHA-256", bytes(device?.publicKey?.spkiDerBase64 ?? "")));
			await check("mTLS with fetch(url, { clientKey })", async () => {
				const response = await fetch(WHOAMI, { clientKey: "device" } as RequestInit);
				const seen = await response.json();
				if (seen.publicKeySha256 !== ownKey) throw new Error(`the server saw another key (${seen.publicKeySha256.slice(0, 12)})`);
				return `${response.status}, the server saw this key (${seen.subject})`;
			});
			await check("mTLS with pi.keys.fetch", async () => {
				const seen = await (await keys.fetch("device", WHOAMI)).json();
				if (seen.publicKeySha256 !== ownKey) throw new Error("the server saw another key");
				return "the server saw this key";
			});
			await check("redirects: followed by default, refused with redirect: error", async () => {
				const followed = await (await fetch(ISSUER.replace("/issue", "/redirect"))).json();
				if (followed.reached !== "target") throw new Error("not followed");
				try {
					await fetch(ISSUER.replace("/issue", "/redirect"), { redirect: "error" });
				} catch (error) {
					return `followed, and refused: ${error instanceof Error ? error.message.slice(0, 70) : error}`;
				}
				throw new Error("redirect: error followed the redirect");
			});
			await check("refused without the key", async () => {
				try {
					const response = await fetch(WHOAMI);
					throw new Error(`answered ${response.status}`);
				} catch (error) {
					if (error instanceof Error && error.message.startsWith("answered")) throw error;
					return `refused (${error instanceof Error ? error.message.slice(0, 80) : error})`;
				}
			});
			}
			if (params.biometric) {
				await check("Face ID key", async () => {
					const approve = await keys.create("approve", { biometry: "current-set" });
					const signature = await keys.sign("approve", "approve access", { reason: "Approve access to the self-test" });
					if (!(await verify(approve.publicKey.spkiDerBase64, signature, "approve access"))) throw new Error("the signature does not verify");
					return `${approve.hardware ? "Secure Enclave" : "software"} key signed after Face ID, verifies`;
				});
			}
			await check("list", async () => (await keys.list()).map((key: any) => `${key.name}${key.certificate ? " (certificate)" : ""}`).join(", "));
			return { content: [{ type: "text", text: lines.join("\n") }], details: null };
		},
	});
}
