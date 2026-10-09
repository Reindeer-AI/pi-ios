import { Type } from "@earendil-works/pi-ai";
/** For the vault test: reveal a card number (its result must come back masked) and send one with a placeholder. */
export default function (pi: any) {
	const card = async () => (await pi.vault.list({ kind: "card" }))[0];
	pi.registerTool({
		name: "vault_probe_reveal",
		label: "Vault probe: reveal",
		description: "Test tool: reveals the first card's number and returns it as is.",
		parameters: Type.Object({}),
		async execute() {
			const item = await card();
			const { number } = await pi.vault.get(item.id, { fields: ["number"], reason: "Testing the vault" });
			return { content: [{ type: "text", text: `The card number is ${number} (${number.length} characters).` }], details: null };
		},
	});
	pi.registerTool({
		name: "vault_probe_send",
		label: "Vault probe: send",
		description: "Test tool: posts the first card's number to the test server with a vault placeholder.",
		parameters: Type.Object({}),
		async execute() {
			const item = await card();
			const response = await fetch("http://127.0.0.1:8781/charge", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ card: pi.vault.placeholder(item.id, "number") }),
			});
			return { content: [{ type: "text", text: `The server answered ${response.status}: ${await response.text()}` }], details: null };
		},
	});
}
