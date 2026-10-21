/**
 * The vault (`VaultService.swift`): the user's sensitive values (card numbers and security codes; passport, ID,
 * license and social security numbers; secure notes) behind Face ID on this device. Items have public names
 * ("Chase Sapphire Preferred", "My passport") and hints ("Visa •• 4242"); their values come only through the app's
 * consent sheet and Face ID.
 *
 * - `pi.vault` for extensions (`vaultApi`): list, add (the app's secure sheet, so the extension never sees what is
 *   typed), set (values it has), delete (its own items), choose (the app's picker), get (reveal, with consent), fill (into
 *   the session's browser page, natively), and placeholders (`{{vault:ID/FIELD}}` in a fetch, substituted natively).
 * - The agent's `vault_list`; `browser_fill_from_vault` is with the browser tools.
 * - `redact`: a value revealed to an extension is masked in what its tools return, before the model sees it.
 */
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { request } from "./bridge.ts";

export type VaultItem = { id: string; kind: string; label: string; hint: string; fields: string[]; domains: string[]; owner: string | null };
type FieldSpec = { key: string; label?: string; placeholder?: string; secret?: boolean };

/** Values revealed to extensions this run of the engine, masked in tool results (`redact`). */
const revealed = new Set<string>();

const mask = (value: string) => {
	const compact = value.replace(/[\s-]/g, "");
	return compact.length >= 8 ? `•••• ${compact.slice(-4)}` : "••••";
};

/** A text with any value revealed to an extension masked. */
export function redact(text: string): string {
	let result = text;
	for (const value of revealed) if (result.includes(value)) result = result.split(value).join(mask(value));
	return result;
}

/** `pi.vault` (and `ctx.vault`) for an extension, in a session (for `fill`, its browser). */
export function vaultApi(extension: string, sessionId?: number) {
	const call = <T>(method: string, params: Record<string, unknown> = {}) => request<T>("vault", method, { requester: extension, ...params });
	return {
		/** The items (names and hints, never values), optionally of one kind. */
		list: (options: { kind?: string } = {}) => call<VaultItem[]>("list", options),
		/** The app's secure sheet for an item's values (a new item, or with `id` new values for one of yours); null if cancelled. */
		add: (options: { kind?: string; label?: string; fields?: FieldSpec[]; hint?: string; id?: string } = {}) => call<VaultItem | null>("add", options),
		/** Stores values you have (or, without values, a new name, hint or domains for one of your items). */
		set: (options: { id?: string; kind?: string; label?: string; values?: Record<string, string>; hint?: string; domains?: string[] }) =>
			call<VaultItem>("set", options),
		/** Deletes one of your items. */
		delete: (id: string) => call<null>("delete", { id }),
		/** The app's picker: the id of the item the user chose (or added), or null. */
		choose: (options: { kind?: string; reason?: string } = {}) => call<string | null>("choose", options),
		/** Reveals values (the consent sheet and Face ID, unless allowed for a while); masked in what your tools return. */
		get: async (id: string, options: { fields?: string[]; reason?: string } = {}) => {
			const values = await call<Record<string, string>>("get", { id, ...options });
			for (const value of Object.values(values)) if (value.length >= 4) revealed.add(value);
			return values;
		},
		/** Types a value into a field of the session's browser page (a ref from a snapshot), without revealing it to you. */
		fill: async (id: string, options: { field: string; ref: string; reason?: string }) => {
			if (sessionId === undefined) throw new Error("vault.fill needs a session (its browser)");
			const reply = await request<{ text: string; isError?: boolean }>("browser", "fillSecret", {
				sessionId,
				ref: options.ref,
				item: id,
				field: options.field,
				reason: options.reason,
				requester: extension,
			});
			if (reply.isError) throw new Error(reply.text);
			return reply.text;
		},
		/** A value's placeholder for a fetch's body or headers, which native replaces (to the item's domains). */
		placeholder: (id: string, field: string) => `{{vault:${id}/${field}}}`,
	};
}

export const VaultTools = defineExtension({
	name: "vault",
	sections: [
		section(
			"vault",
			() =>
				`The user's vault keeps sensitive values (card numbers and security codes; passport, ID, driver's license and social security numbers; secure notes) on this phone behind Face ID. vault_list shows its items by name ("Chase Sapphire Preferred", "My passport") with a hint ("Visa •• 4242") and their fields, never the values: when the user names one ("fill in my passport", "pay with my Chase card"), find it there. To put a value into a web page, use browser_fill_from_vault with the field's ref, the item's id and the field; the user approves with Face ID, and you never see the value. Never ask the user to type such values in the chat, and never repeat one.`,
		),
	],
	tools: [
		defineTool({
			name: "vault_list",
			description:
				"List the user's vault items: each one's id, name, kind, hint (like Visa •• 4242) and fields (like number, cvv). Values are never shown; fill them into a page with browser_fill_from_vault.",
			parameters: Type.Object({
				kind: Type.Optional(Type.String({ description: "Only this kind: card, passport, id, license, ssn, note" })),
			}),
			replay: "safe",
			execute: async (args) => {
				const items = await request<VaultItem[]>("vault", "list", { requester: "the agent", ...args });
				if (items.length === 0) return { output: [{ type: "text", text: "The vault is empty." }] };
				const lines = items.map((item) => `- ${item.label} (${item.kind}${item.hint ? `, ${item.hint}` : ""}): id ${item.id}, fields ${item.fields.join(", ")}`);
				return { output: [{ type: "text", text: lines.join("\n") }] };
			},
		}),
	],
});
